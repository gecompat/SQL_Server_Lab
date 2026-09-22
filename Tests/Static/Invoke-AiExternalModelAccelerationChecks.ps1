#Requires -Version 7.2
[CmdletBinding()]param()
$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
. (Join-Path $PSScriptRoot '../Common/CheckResult.ps1')
$failures=[Collections.Generic.List[string]]::new();$passed=0
$module=Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru
$h='a'*64;$c='b'*64
$artifactRoot=Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-ai-artifacts-'+[guid]::NewGuid().ToString('N'))
try {
    $plan=Get-SqlServerLabAiExternalModelPlan -Backend LlamaCppOpenVino -Accelerator NPU -Location 'https://host.docker.internal:11435/v1/embeddings' -ExternalModelName LocalNpuEmbedding -RuntimeModel bound-model -Dimension 768 -ModelSha256 $h -RuntimeSha256 $h -ServerCertificateSha256 $c
    Add-CheckResult 'OpenVINO-NPU-Plan bleibt bis zur Live-Evidence NOT_PROBED' ($plan.Status -eq 'NOT_PROBED' -and $plan.EvidenceStatus -eq 'CONFIGURATION_ONLY' -and $plan.ApiFormat -eq 'OpenAI')
    Add-CheckResult 'Plan ist schema-valide, hash- und Runtime-Modell-gebunden' (($plan|ConvertTo-Json -Depth 10|Test-Json -SchemaFile (Join-Path $repoRoot 'Schemas/ai-external-model-plan.schema.json')) -and $plan.PlanKey -match '^[a-f0-9]{64}$' -and 'RUNTIME_MODEL_MATCH' -in $plan.RequiredEvidence)
    Add-CheckResult 'Plan enthält keine Secretwerte oder Hostpfade' (($plan|ConvertTo-Json -Depth 10) -notmatch '(?i)(Bearer|secret|C:\\|/home/)')
    $ovms=Get-SqlServerLabAiExternalModelPlan -Backend OpenVinoModelServer -Accelerator NPU -Location 'https://localhost:8443/v3/embeddings' -ExternalModelName OvmsNpu -RuntimeModel model -Dimension 1024 -ModelSha256 $h -RuntimeSha256 $h -ServerCertificateSha256 $c
    Add-CheckResult 'OVMS verlangt den separaten TLS-Gateway' ($ovms.Status -eq 'BLOCKED' -and 'AI_EXTERNAL_MODEL_OVMS_GATEWAY_REQUIRED' -in $ovms.Blockers)
    $ovmsGateway=Get-SqlServerLabAiExternalModelPlan -Backend OpenVinoModelServer -Accelerator NPU -TlsMode Gateway -Location 'https://localhost:8443/v3/embeddings' -ExternalModelName OvmsNpu -RuntimeModel model -Dimension 1024 -ModelSha256 $h -RuntimeSha256 $h -ServerCertificateSha256 $c
    Add-CheckResult 'OVMS-Gateway bleibt bis zum gebundenen Lifecycle explizit blockiert' (
        $ovmsGateway.Status -eq 'BLOCKED' -and
        'AI_EXTERNAL_MODEL_OVMS_GATEWAY_NOT_IMPLEMENTED' -in $ovmsGateway.Blockers -and
        'AI_EXTERNAL_MODEL_OVMS_GATEWAY_REQUIRED' -notin $ovmsGateway.Blockers -and
        $ovmsGateway.EndpointPath -eq '/v3/embeddings')
    $rocm=Get-SqlServerLabAiExternalModelPlan -Backend LlamaCppRocm -Accelerator NPU -Location 'https://localhost:11435/v1/embeddings' -ExternalModelName RocmNpu -RuntimeModel model -Dimension 768 -ModelSha256 $h -RuntimeSha256 $h -ServerCertificateSha256 $c
    Add-CheckResult 'ROCm wird nicht fälschlich als NPU-Nachweis behandelt' ($rocm.Status -eq 'BLOCKED' -and 'AI_EXTERNAL_MODEL_ACCELERATOR_UNSUPPORTED' -in $rocm.Blockers)
    $wrongPath=Get-SqlServerLabAiExternalModelPlan -Backend LlamaCppOpenVino -Accelerator NPU -Location 'https://localhost:11435/v3/embeddings' -ExternalModelName WrongPath -RuntimeModel model -Dimension 768 -ModelSha256 $h -RuntimeSha256 $h -ServerCertificateSha256 $c
    Add-CheckResult 'Backendfremder Embeddingpfad blockiert' ($wrongPath.Status -eq 'BLOCKED' -and 'AI_EXTERNAL_MODEL_ENDPOINT_PATH_MISMATCH' -in $wrongPath.Blockers)
    Add-CheckResult 'Beschleunigernachweis bleibt explizit offen' ('ACCELERATOR_RUNTIME_ATTESTATION' -in $plan.RequiredEvidence)

    $null=New-Item -ItemType Directory -Path $artifactRoot -Force
    $runtimePath=Join-Path $artifactRoot 'llama-server.exe'
    $modelPath=Join-Path $artifactRoot 'embedding.gguf'
    $wrongModelPath=Join-Path $artifactRoot 'wrong.gguf'
    [IO.File]::WriteAllBytes($runtimePath,[byte[]](1,2,3,4,5))
    [IO.File]::WriteAllBytes($modelPath,[byte[]](6,7,8,9))
    [IO.File]::WriteAllBytes($wrongModelPath,[byte[]](9,8,7,6))
    $runtimeHash=(Get-FileHash -LiteralPath $runtimePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $modelHash=(Get-FileHash -LiteralPath $modelPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $artifactPlan=Get-SqlServerLabAiExternalModelPlan -Backend LlamaCppOpenVino -Accelerator NPU `
        -Location 'https://localhost:11435/v1/embeddings' -ExternalModelName LocalNpuEmbedding `
        -RuntimeModel bound-model -Dimension 3 -ModelSha256 $modelHash -RuntimeSha256 $runtimeHash `
        -ServerCertificateSha256 $c
    $artifactReceipt=$artifactPlan | Test-SqlServerLabAiExternalModelArtifact -RuntimePath $runtimePath -ModelPath $modelPath
    Add-CheckResult 'Lokale Runtime- und Modelldateien werden gegen den Plan verifiziert' (
        $artifactReceipt.Status -eq 'ARTIFACTS_VERIFIED' -and
        @($artifactReceipt.VerifiedEvidence) -join ',' -eq 'RUNTIME_BINARY_MATCH,MODEL_FILE_MATCH' -and
        'ACCELERATOR_RUNTIME_ATTESTATION' -in $artifactReceipt.PendingEvidence)
    Add-CheckResult 'Artifact-Receipt ist schema-valide und enthält keine lokalen Pfade' (
        ($artifactReceipt|ConvertTo-Json -Depth 10|Test-Json -SchemaFile (Join-Path $repoRoot 'Schemas/ai-external-model-artifact-receipt.schema.json')) -and
        ($artifactReceipt|ConvertTo-Json -Depth 10) -notmatch '(?i)(llama-server|embedding\.gguf|C:\\|/home/)' -and
        'RUNTIME_MODEL_MATCH' -in $artifactReceipt.PendingEvidence)
    $modelMismatch=$null
    try{$artifactPlan|Test-SqlServerLabAiExternalModelArtifact -RuntimePath $runtimePath -ModelPath $wrongModelPath;$modelMismatch='NO_ERROR'}catch{$modelMismatch=$_.Exception.Message}
    Add-CheckResult 'Abweichende Modelldatei scheitert geschlossen' ($modelMismatch -eq 'AI_EXTERNAL_MODEL_MODEL_HASH_MISMATCH')
    $runtimeMissing=$null
    try{$artifactPlan|Test-SqlServerLabAiExternalModelArtifact -RuntimePath (Join-Path $artifactRoot 'missing.exe') -ModelPath $modelPath;$runtimeMissing='NO_ERROR'}catch{$runtimeMissing=$_.Exception.Message}
    Add-CheckResult 'Fehlende Runtime scheitert ohne Pfadleak mit stabilem Fehlercode' ($runtimeMissing -eq 'AI_EXTERNAL_MODEL_RUNTIME_FILE_UNREADABLE')
    $samePath=$null
    try{$artifactPlan|Test-SqlServerLabAiExternalModelArtifact -RuntimePath $runtimePath -ModelPath $runtimePath;$samePath='NO_ERROR'}catch{$samePath=$_.Exception.Message}
    Add-CheckResult 'Runtime und Modell müssen getrennte Dateien sein' ($samePath -eq 'AI_EXTERNAL_MODEL_ARTIFACT_PATHS_MUST_DIFFER')

    $requestCapture=[Runtime.CompilerServices.StrongBox[object]]::new()
    $transport={param($request)$requestCapture.Value=$request;[PSCustomObject]@{
        StatusCode=200;ServerCertificateSha256=$c;Body=[PSCustomObject]@{model='bound-model';data=@([PSCustomObject]@{embedding=@(1.0,-0.25,0)})}
    }}.GetNewClosure()
    $probePlan=Get-SqlServerLabAiExternalModelPlan -Backend LlamaCppOpenVino -Accelerator NPU -Location 'https://localhost:11435/v1/embeddings' -ExternalModelName LocalNpuEmbedding -RuntimeModel bound-model -Dimension 3 -ModelSha256 $h -RuntimeSha256 $h -ServerCertificateSha256 $c
    $receipt=& $module {param($p,$t)Invoke-LabAiExternalModelEndpointProbe -Plan $p -Transport $t} $probePlan $transport
    Add-CheckResult 'Read-only Probe sendet genau den festen OpenAI-Embeddingrequest' (
        $requestCapture.Value.Method -eq 'POST' -and $requestCapture.Value.Path -eq '/v1/embeddings' -and
        $requestCapture.Value.Body.model -eq 'bound-model' -and @($requestCapture.Value.Body.input).Count -eq 1 -and
        $requestCapture.Value.Body.input[0] -eq 'SQL Server Lab synthetic embedding probe' -and $requestCapture.Value.Body.encoding_format -eq 'float')
    Add-CheckResult 'Endpoint-Receipt ist schema-valide und lässt Runtime-/Accelerator-Evidence offen' (
        ($receipt|ConvertTo-Json -Depth 10|Test-Json -SchemaFile (Join-Path $repoRoot 'Schemas/ai-external-model-endpoint-receipt.schema.json')) -and
        $receipt.Status -eq 'ENDPOINT_VERIFIED' -and 'RUNTIME_MODEL_MATCH' -in $receipt.VerifiedEvidence -and
        'ACCELERATOR_RUNTIME_ATTESTATION' -in $receipt.PendingEvidence)
    $receiptJson=$receipt|ConvertTo-Json -Depth 10
    Add-CheckResult 'Endpoint-Receipt enthält weder Vektor, Payload, Secret noch Hostpfad' (
        $receiptJson -notmatch '(?i)("Vector"|synthetic|"Input"|secret|bearer|localhost|C:\\|/home/)')

    $failureCases=@(
        @{Name='Zertifikatabweichung';Code='AI_EXTERNAL_MODEL_TLS_CERTIFICATE_MISMATCH';Transport={param($request)[PSCustomObject]@{StatusCode=200;ServerCertificateSha256=('d'*64);Body=[PSCustomObject]@{model='bound-model';data=@([PSCustomObject]@{embedding=@(1,2,3)})}}}},
        @{Name='leere Antwort';Code='AI_EXTERNAL_MODEL_RESPONSE_INVALID';Transport={param($request)$null=$request;[PSCustomObject]@{StatusCode=200;ServerCertificateSha256=$c;Body=$null}}.GetNewClosure()},
        @{Name='abweichenden Runtime-Modellnamen';Code='AI_EXTERNAL_MODEL_RUNTIME_MODEL_MISMATCH';Transport={param($request)$null=$request;[PSCustomObject]@{StatusCode=200;ServerCertificateSha256=$c;Body=[PSCustomObject]@{model='other-model';data=@([PSCustomObject]@{embedding=@(1,2,3)})}}}.GetNewClosure()},
        @{Name='fehlenden Runtime-Modellnamen';Code='AI_EXTERNAL_MODEL_RUNTIME_MODEL_MISMATCH';Transport={param($request)$null=$request;[PSCustomObject]@{StatusCode=200;ServerCertificateSha256=$c;Body=[PSCustomObject]@{data=@([PSCustomObject]@{embedding=@(1,2,3)})}}}.GetNewClosure()},
        @{Name='mehrere Vektoren';Code='AI_EXTERNAL_MODEL_RESPONSE_INVALID';Transport={param($request)[PSCustomObject]@{StatusCode=200;ServerCertificateSha256=$c;Body=[PSCustomObject]@{model='bound-model';data=@([PSCustomObject]@{embedding=@(1,2,3)},[PSCustomObject]@{embedding=@(1,2,3)})}}}.GetNewClosure()},
        @{Name='falsche Dimension';Code='AI_EXTERNAL_MODEL_DIMENSION_MISMATCH';Transport={param($request)[PSCustomObject]@{StatusCode=200;ServerCertificateSha256=$c;Body=[PSCustomObject]@{model='bound-model';data=@([PSCustomObject]@{embedding=@(1,2)})}}}.GetNewClosure()},
        @{Name='nicht endlichen Vektor';Code='AI_EXTERNAL_MODEL_VECTOR_INVALID';Transport={param($request)[PSCustomObject]@{StatusCode=200;ServerCertificateSha256=$c;Body=[PSCustomObject]@{model='bound-model';data=@([PSCustomObject]@{embedding=@(1,[double]::NaN,3)})}}}.GetNewClosure()},
        @{Name='textuellen Vektorwert';Code='AI_EXTERNAL_MODEL_VECTOR_INVALID';Transport={param($request)[PSCustomObject]@{StatusCode=200;ServerCertificateSha256=$c;Body=[PSCustomObject]@{model='bound-model';data=@([PSCustomObject]@{embedding=@(1,'2',3)})}}}.GetNewClosure()}
    )
    foreach($case in $failureCases){
        $actual=$null
        try{& $module {param($p,$t)Invoke-LabAiExternalModelEndpointProbe -Plan $p -Transport $t} $probePlan $case.Transport; $actual='NO_ERROR'}catch{$actual=$_.Exception.Message}
        Add-CheckResult "Probe blockiert $($case.Name)" ($actual -eq $case.Code)
    }
    $blockedCode=$null
    try{& $module {param($p,$t)Invoke-LabAiExternalModelEndpointProbe -Plan $p -Transport $t} $rocm $transport; $blockedCode='NO_ERROR'}catch{$blockedCode=$_.Exception.Message}
    Add-CheckResult 'Blockierter Plan führt keinen Endpointrequest aus' ($blockedCode -eq 'AI_EXTERNAL_MODEL_PLAN_BLOCKED')
    $mutatedPlan=$probePlan.PSObject.Copy();$mutatedPlan.Dimension=2
    $integrityCode=$null
    try{& $module {param($p,$t)Invoke-LabAiExternalModelEndpointProbe -Plan $p -Transport $t} $mutatedPlan $transport; $integrityCode='NO_ERROR'}catch{$integrityCode=$_.Exception.Message}
    Add-CheckResult 'Nachträglich veränderter Plan wird vor dem Request verworfen' ($integrityCode -eq 'AI_EXTERNAL_MODEL_PLAN_INVALID')
    Add-CheckResult 'Öffentliche Probe ist exportiert und verbirgt den Testtransport' (
        (Get-Command Test-SqlServerLabAiExternalModelEndpoint -Module $module.Name).Parameters.ContainsKey('TrustedRootCertificate') -and
        -not (Get-Command Test-SqlServerLabAiExternalModelEndpoint -Module $module.Name).Parameters.ContainsKey('Transport'))
    Add-CheckResult 'Öffentliche Artifact-Prüfung ist exportiert und verlangt beide lokalen Dateien' (
        (Get-Command Test-SqlServerLabAiExternalModelArtifact -Module $module.Name).Parameters.ContainsKey('RuntimePath') -and
        (Get-Command Test-SqlServerLabAiExternalModelArtifact -Module $module.Name).Parameters.ContainsKey('ModelPath'))
}
finally {
    Remove-Module $module -Force -ErrorAction SilentlyContinue
    if(Test-Path -LiteralPath $artifactRoot){Remove-Item -LiteralPath $artifactRoot -Recurse -Force}
}
Write-Host "`nAI external model acceleration checks: $passed passed, $($failures.Count) failed"
if($failures.Count){$failures|ForEach-Object{Write-Host " - $_" -ForegroundColor Red};exit 1}
