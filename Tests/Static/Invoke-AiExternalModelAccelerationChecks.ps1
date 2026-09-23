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
    Add-CheckResult 'OVMS-Gateway bleibt ohne gebundenen Lifecycle explizit blockiert' (
        $ovmsGateway.Status -eq 'BLOCKED' -and
        'AI_EXTERNAL_MODEL_OVMS_GATEWAY_BINDING_REQUIRED' -in $ovmsGateway.Blockers -and
        'AI_EXTERNAL_MODEL_OVMS_GATEWAY_REQUIRED' -notin $ovmsGateway.Blockers -and
        $ovmsGateway.EndpointPath -eq '/v3/embeddings')
    $gatewayLocation='https://127.0.0.1:18443/v3/embeddings';$upstreamBindingKey='d'*64;$gatewayOperationId=[guid]::NewGuid().ToString('D')
    $gatewayIdentity=[ordered]@{Contract='SqlServerLab.AiOvmsHttpsGatewayBinding/1.0';OperationId=$gatewayOperationId;LeaseSeconds=900;UpstreamBindingKey=$upstreamBindingKey;Location=$gatewayLocation;RuntimeModel='bound-ovms-model';Dimension=3;ServerCertificateSha256=$c}
    $gatewayBindingKey=& $module {param($i)Get-LabAiPlanKey -InputObject $i} $gatewayIdentity
    $gatewayBinding=[PSCustomObject]@{Contract='SqlServerLab.AiOvmsHttpsGateway/1.0';OperationId=$gatewayOperationId;Status='ENDPOINT_VERIFIED';Location=$gatewayLocation;RuntimeModel='bound-ovms-model';Dimension=3;ServerCertificateSha256=$c;UpstreamBindingKey=$upstreamBindingKey;LeaseSeconds=900;BindingKey=$gatewayBindingKey}
    $boundOvms=Get-SqlServerLabAiExternalModelPlan -Backend OpenVinoModelServer -Accelerator NPU -TlsMode Gateway -Location $gatewayLocation -ExternalModelName OvmsNpu -RuntimeModel bound-ovms-model -Dimension 3 -ModelSha256 $h -RuntimeSha256 $h -ServerCertificateSha256 $c -GatewayBinding $gatewayBinding
    Add-CheckResult 'OVMS-Plan übernimmt nur eine kanonisch passende Gateway-Bindung' (
        $boundOvms.Status -eq 'NOT_PROBED' -and $boundOvms.GatewayBindingKey -ceq $gatewayBindingKey -and
        'HTTPS_GATEWAY_BINDING' -in $boundOvms.RequiredEvidence -and 'GATEWAY_PROCESS_OWNERSHIP' -in $boundOvms.RequiredEvidence -and
        ($boundOvms|ConvertTo-Json -Depth 10|Test-Json -SchemaFile (Join-Path $repoRoot 'Schemas/ai-external-model-plan.schema.json')))
    $resolvedBoundOvms=& $module {param($p)Resolve-LabAiExternalModelPlan -Plan $p} $boundOvms
    Add-CheckResult 'Gebundener OVMS-Plan bleibt bei Revalidierung hashstabil' ($resolvedBoundOvms.PlanKey -ceq $boundOvms.PlanKey -and $resolvedBoundOvms.GatewayBindingKey -ceq $gatewayBindingKey)
    $tamperedBinding=$gatewayBinding.PSObject.Copy();$tamperedBinding.BindingKey='e'*64
    $tamperedPlan=Get-SqlServerLabAiExternalModelPlan -Backend OpenVinoModelServer -Accelerator NPU -TlsMode Gateway -Location $gatewayLocation -ExternalModelName OvmsNpu -RuntimeModel bound-ovms-model -Dimension 3 -ModelSha256 $h -RuntimeSha256 $h -ServerCertificateSha256 $c -GatewayBinding $tamperedBinding
    Add-CheckResult 'OVMS-Plan blockiert manipulierten Gateway-Binding-Key' ($tamperedPlan.Status -eq 'BLOCKED' -and @($tamperedPlan.Blockers) -join ',' -eq 'AI_EXTERNAL_MODEL_OVMS_GATEWAY_BINDING_INVALID')
    $tamperedOperation=$gatewayBinding.PSObject.Copy();$tamperedOperation.OperationId=[guid]::NewGuid().ToString('D')
    $tamperedOperationPlan=Get-SqlServerLabAiExternalModelPlan -Backend OpenVinoModelServer -Accelerator NPU -TlsMode Gateway -Location $gatewayLocation -ExternalModelName OvmsNpu -RuntimeModel bound-ovms-model -Dimension 3 -ModelSha256 $h -RuntimeSha256 $h -ServerCertificateSha256 $c -GatewayBinding $tamperedOperation
    Add-CheckResult 'OVMS-Plan blockiert manipulierte Gateway-Operation' ($tamperedOperationPlan.Status -eq 'BLOCKED' -and @($tamperedOperationPlan.Blockers) -join ',' -eq 'AI_EXTERNAL_MODEL_OVMS_GATEWAY_BINDING_INVALID')
    $tamperedLease=$gatewayBinding.PSObject.Copy();$tamperedLease.LeaseSeconds=901
    $tamperedLeasePlan=Get-SqlServerLabAiExternalModelPlan -Backend OpenVinoModelServer -Accelerator NPU -TlsMode Gateway -Location $gatewayLocation -ExternalModelName OvmsNpu -RuntimeModel bound-ovms-model -Dimension 3 -ModelSha256 $h -RuntimeSha256 $h -ServerCertificateSha256 $c -GatewayBinding $tamperedLease
    Add-CheckResult 'OVMS-Plan blockiert manipulierte Gateway-Lease' ($tamperedLeasePlan.Status -eq 'BLOCKED' -and @($tamperedLeasePlan.Blockers) -join ',' -eq 'AI_EXTERNAL_MODEL_OVMS_GATEWAY_BINDING_INVALID')
    $mismatchPlan=Get-SqlServerLabAiExternalModelPlan -Backend OpenVinoModelServer -Accelerator NPU -TlsMode Gateway -Location $gatewayLocation -ExternalModelName OvmsNpu -RuntimeModel other-model -Dimension 3 -ModelSha256 $h -RuntimeSha256 $h -ServerCertificateSha256 $c -GatewayBinding $gatewayBinding
    Add-CheckResult 'OVMS-Plan blockiert Modellabweichung zur Gateway-Bindung' ($mismatchPlan.Status -eq 'BLOCKED' -and 'AI_EXTERNAL_MODEL_OVMS_GATEWAY_BINDING_MISMATCH' -in $mismatchPlan.Blockers)
    $unsupportedBinding=Get-SqlServerLabAiExternalModelPlan -Backend LlamaCppOpenVino -Accelerator NPU -Location 'https://localhost:11435/v1/embeddings' -ExternalModelName WrongBinding -RuntimeModel bound-model -Dimension 3 -ModelSha256 $h -RuntimeSha256 $h -ServerCertificateSha256 $c -GatewayBinding $gatewayBinding
    Add-CheckResult 'Nicht-OVMS-Plan blockiert fremde Gateway-Bindung' ($unsupportedBinding.Status -eq 'BLOCKED' -and 'AI_EXTERNAL_MODEL_GATEWAY_BINDING_UNSUPPORTED' -in $unsupportedBinding.Blockers)
    $ovmsCapture=[Runtime.CompilerServices.StrongBox[object]]::new()
    $ovmsTransport={param($request)$ovmsCapture.Value=$request;[PSCustomObject]@{
        StatusCode=200;Body=[PSCustomObject]@{model='bound-ovms-model';data=@([PSCustomObject]@{embedding=@(1.0,-0.25,0)})}
    }}.GetNewClosure()
    $ovmsReceipt=& $module {param($t)Invoke-LabAiOvmsUpstreamProbe -Location 'http://127.0.0.1:9000/v3/embeddings' -RuntimeModel bound-ovms-model -Dimension 3 -Transport $t} $ovmsTransport
    Add-CheckResult 'OVMS-Upstream-Probe bindet genau einen Loopback-v3-Request' (
        $ovmsCapture.Value.Method -eq 'POST' -and $ovmsCapture.Value.Path -eq '/v3/embeddings' -and
        $ovmsCapture.Value.Body.model -eq 'bound-ovms-model' -and
        @($ovmsCapture.Value.Body.input).Count -eq 1 -and $ovmsCapture.Value.Body.encoding_format -eq 'float')
    Add-CheckResult 'OVMS-Upstream-Receipt ist schema-valide, sanitisiert und lässt Gateway-Evidence offen' (
        ($ovmsReceipt|ConvertTo-Json -Depth 10|Test-Json -SchemaFile (Join-Path $repoRoot 'Schemas/ai-ovms-upstream-receipt.schema.json')) -and
        $ovmsReceipt.Status -eq 'UPSTREAM_VERIFIED' -and 'HTTPS_GATEWAY_BINDING' -in $ovmsReceipt.PendingEvidence -and
        ($ovmsReceipt|ConvertTo-Json -Depth 10) -notmatch '(?i)(bound-ovms-model|synthetic|127\.0\.0\.1|v3/embeddings)')
    foreach($invalidLocation in @(
        'https://127.0.0.1:9000/v3/embeddings','http://localhost:9000/v3/embeddings',
        'http://192.0.2.1:9000/v3/embeddings','http://127.0.0.1:9000/v1/embeddings',
        'http://127.0.0.1:80/v3/embeddings','http://user@127.0.0.1:9000/v3/embeddings')) {
        $locationCode=$null
        try{& $module {param($l,$t)Invoke-LabAiOvmsUpstreamProbe -Location $l -RuntimeModel bound-ovms-model -Dimension 3 -Transport $t} $invalidLocation $ovmsTransport;$locationCode='NO_ERROR'}catch{$locationCode=$_.Exception.Message}
        Add-CheckResult "OVMS-Upstream blockiert fremde Transportgrenze: $invalidLocation" ($locationCode -eq 'AI_OVMS_UPSTREAM_LOCATION_INVALID')
    }
    $ovmsFailureCases=@(
        @{Name='HTTP-Fehler';Code='AI_OVMS_UPSTREAM_HTTP_503';StatusCode=503;Body=$null},
        @{Name='falsches Modell';Code='AI_OVMS_UPSTREAM_RUNTIME_MODEL_MISMATCH';Body=[PSCustomObject]@{model='other';data=@([PSCustomObject]@{embedding=@(1,2,3)})}},
        @{Name='falsche Dimension';Code='AI_OVMS_UPSTREAM_DIMENSION_MISMATCH';Body=[PSCustomObject]@{model='bound-ovms-model';data=@([PSCustomObject]@{embedding=@(1,2)})}},
        @{Name='nicht endlichen Vektor';Code='AI_OVMS_UPSTREAM_VECTOR_INVALID';Body=[PSCustomObject]@{model='bound-ovms-model';data=@([PSCustomObject]@{embedding=@(1,[double]::NaN,3)})}},
        @{Name='Vektorwert ausserhalb float32';Code='AI_OVMS_UPSTREAM_VECTOR_INVALID';Body=[PSCustomObject]@{model='bound-ovms-model';data=@([PSCustomObject]@{embedding=@(1,[double]::MaxValue,3)})}},
        @{Name='mehrere Vektoren';Code='AI_OVMS_UPSTREAM_RESPONSE_INVALID';Body=[PSCustomObject]@{model='bound-ovms-model';data=@([PSCustomObject]@{embedding=@(1,2,3)},[PSCustomObject]@{embedding=@(1,2,3)})}}
    )
    foreach($case in $ovmsFailureCases){
        $body=$case.Body;$statusCode=if($case.StatusCode){$case.StatusCode}else{200};$failureTransport={param($request)$null=$request;[PSCustomObject]@{StatusCode=$statusCode;Body=$body}}.GetNewClosure();$actual=$null
        try{& $module {param($t)Invoke-LabAiOvmsUpstreamProbe -Location 'http://127.0.0.1:9000/v3/embeddings' -RuntimeModel bound-ovms-model -Dimension 3 -Transport $t} $failureTransport;$actual='NO_ERROR'}catch{$actual=$_.Exception.Message}
        Add-CheckResult "OVMS-Upstream blockiert $($case.Name)" ($actual -eq $case.Code)
    }
    Add-CheckResult 'Öffentliche OVMS-Upstream-Prüfung ist exportiert und verbirgt den Testtransport' (
        (Get-Command Test-SqlServerLabOvmsUpstreamEndpoint -Module $module.Name).Parameters.ContainsKey('Location') -and
        -not (Get-Command Test-SqlServerLabOvmsUpstreamEndpoint -Module $module.Name).Parameters.ContainsKey('Transport'))
    $gatewayBody=& $module {ConvertTo-LabAiOvmsGatewayUpstreamBody -Json '{"model":"bound-ovms-model","input":"synthetic","encoding_format":"float"}' -ExpectedModel bound-ovms-model}
    $gatewayRequest=$gatewayBody|ConvertFrom-Json
    Add-CheckResult 'OVMS-Gatewaykern rekonstruiert genau den erlaubten Einzelrequest' (
        $gatewayRequest.model -ceq 'bound-ovms-model' -and @($gatewayRequest.input).Count -eq 1 -and
        $gatewayRequest.input[0] -ceq 'synthetic' -and $gatewayRequest.encoding_format -ceq 'float')
    $gatewayResponse=& $module {ConvertFrom-LabAiOvmsGatewayUpstreamResponse -Json '{"object":"list","data":[{"object":"embedding","index":0,"embedding":[1,-0.25,0]}],"model":"bound-ovms-model","usage":{"prompt_tokens":1}}' -ExpectedModel bound-ovms-model -Dimension 3}
    $gatewayResult=$gatewayResponse|ConvertFrom-Json
    Add-CheckResult 'OVMS-Gatewaykern rekonstruiert genau eine float32-sichere Antwort' (
        $gatewayResult.model -ceq 'bound-ovms-model' -and @($gatewayResult.data).Count -eq 1 -and
        @($gatewayResult.data[0].embedding).Count -eq 3 -and $gatewayResult.data[0].index -eq 0 -and
        -not $gatewayResult.PSObject.Properties['usage'])
    $gatewayRequestFailures=@(
        @{Name='fremdes Modell';Code='AI_OVMS_GATEWAY_RUNTIME_MODEL_MISMATCH';Json='{"model":"other","input":"synthetic"}'},
        @{Name='doppeltes Modellfeld';Code='AI_OVMS_GATEWAY_PAYLOAD_INVALID';Json='{"model":"bound-ovms-model","model":"bound-ovms-model","input":"synthetic"}'},
        @{Name='mehrere Inputs';Code='AI_OVMS_GATEWAY_PAYLOAD_INVALID';Json='{"model":"bound-ovms-model","input":["one","two"]}'},
        @{Name='fremdes Payloadfeld';Code='AI_OVMS_GATEWAY_PAYLOAD_INVALID';Json='{"model":"bound-ovms-model","input":"synthetic","user":"foreign"}'}
    )
    foreach($case in $gatewayRequestFailures){$actual=$null;try{& $module {param($j)ConvertTo-LabAiOvmsGatewayUpstreamBody -Json $j -ExpectedModel bound-ovms-model} $case.Json;$actual='NO_ERROR'}catch{$actual=$_.Exception.Message};Add-CheckResult "OVMS-Gatewaykern blockiert $($case.Name)" ($actual -eq $case.Code)}
    $gatewayResponseFailures=@(
        @{Name='Antwortmodellabweichung';Code='AI_OVMS_GATEWAY_RUNTIME_MODEL_MISMATCH';Json='{"model":"other","data":[{"embedding":[1,2,3]}]}'},
        @{Name='Antwortdimension';Code='AI_OVMS_GATEWAY_DIMENSION_MISMATCH';Json='{"model":"bound-ovms-model","data":[{"embedding":[1,2]}]}'},
        @{Name='Antwortwert ausserhalb float32';Code='AI_OVMS_GATEWAY_VECTOR_INVALID';Json='{"model":"bound-ovms-model","data":[{"embedding":[1,3.4028236e38,3]}]}'},
        @{Name='doppelten Antwortindex';Code='AI_OVMS_GATEWAY_RESPONSE_INVALID';Json='{"model":"bound-ovms-model","data":[{"index":0,"index":0,"embedding":[1,2,3]}]}'},
        @{Name='doppeltes Antwortmodell';Code='AI_OVMS_GATEWAY_RESPONSE_INVALID';Json='{"model":"bound-ovms-model","model":"bound-ovms-model","data":[{"embedding":[1,2,3]}]}'}
    )
    foreach($case in $gatewayResponseFailures){$actual=$null;try{& $module {param($j)ConvertFrom-LabAiOvmsGatewayUpstreamResponse -Json $j -ExpectedModel bound-ovms-model -Dimension 3} $case.Json;$actual='NO_ERROR'}catch{$actual=$_.Exception.Message};Add-CheckResult "OVMS-Gatewaykern blockiert $($case.Name)" ($actual -eq $case.Code)}
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
        'ACCELERATOR_RUNTIME_ATTESTATION' -in $receipt.PendingEvidence -and $receipt.ReceiptKey -match '^[a-f0-9]{64}$' -and
        [DateTimeOffset]::Parse($receipt.VerifiedAtUtc).Offset -eq [TimeSpan]::Zero)
    $receiptJson=$receipt|ConvertTo-Json -Depth 10
    Add-CheckResult 'Endpoint-Receipt enthält weder Vektor, Payload, Secret noch Hostpfad' (
        $receiptJson -notmatch '(?i)("Vector"|synthetic|"Input"|secret|bearer|localhost|C:\\|/home/)')
    $sqlPlan=Get-SqlServerLabAiExternalModelSqlPlan -Plan $probePlan -EndpointReceipt $receipt -DatabaseName AiLab
    Add-CheckResult 'SQL-Plan bindet frische Endpoint-Evidence ohne Mutation' (
        $sqlPlan.Status -eq 'PLANNED' -and $sqlPlan.EvidenceStatus -eq 'LIVE_ENDPOINT_BOUND' -and
        $sqlPlan.SourcePlanKey -ceq $probePlan.PlanKey -and $sqlPlan.EndpointReceiptKey -ceq $receipt.ReceiptKey -and
        @($sqlPlan.MutationSequence) -join ',' -eq 'PREFLIGHT_DATABASE_VERSION_PERMISSIONS_AND_MASTER_KEY,CREATE_OWNERSHIP_RECEIPT,CREATE_DATABASE_SCOPED_CREDENTIAL,CREATE_EXTERNAL_MODEL,VERIFY_EXTERNAL_MODEL_CATALOG' -and
        @($sqlPlan.RequiredPermissions) -join ',' -eq 'CONTROL_DATABASE,CREATE_EXTERNAL_MODEL' -and
        $sqlPlan.OwnershipTableName -ceq ('SqlServerLabAiOwner_'+$sqlPlan.SqlPlanKey.Substring(0,24)) -and
        ($sqlPlan|ConvertTo-Json -Depth 10|Test-Json -SchemaFile (Join-Path $repoRoot 'Schemas/ai-external-model-sql-plan.schema.json')))
    Add-CheckResult 'SQL-Plan bleibt geheimnisfrei und lässt SQL, Restart, Accelerator und Cleanup offen' (
        (($sqlPlan|ConvertTo-Json -Depth 10) -notmatch '(?i)(bearer|password|api.?key|secret.{0,3}:|C:\\|/home/)') -and
        @($sqlPlan.PendingEvidence) -join ',' -eq 'SQL_EXTERNAL_MODEL_CREATED,SQL_EMBEDDING_VERIFIED,SQL_RESTART_VERIFIED,ACCELERATOR_RUNTIME_ATTESTATION,SQL_CLEANUP_VERIFIED')
    $runId=[guid]::NewGuid().ToString('D');$scopeId=[guid]::NewGuid().ToString('D');$databaseGuid=[guid]::NewGuid().ToString('D')
    $bindingIdentity=[ordered]@{RunId=$runId;ScopeId=$scopeId;InstanceId='primary';Provider='docker';ResourceId='owned-container'}
    $validSqlRow=[PSCustomObject]@{
        SqlMajorVersion=17;DatabaseId=5;DatabaseName='AiLab';DatabaseStatus='ONLINE';IsReadWrite=$true;DatabaseGuid=$databaseGuid
        HasDatabaseMasterKey=$true;HasControlDatabase=$true;HasCreateExternalModel=$true;CredentialExists=$false;ExternalModelExists=$false;OwnershipTableExists=$false
    }
    $sqlRow=[Runtime.CompilerServices.StrongBox[object]]::new($validSqlRow.PSObject.Copy())
    $sqlCapture=[Runtime.CompilerServices.StrongBox[object]]::new()
    $sqlExecutor={param($query,$parameters,$database)$sqlCapture.Value=[PSCustomObject]@{Query=$query;Parameters=$parameters;Database=$database};$sqlRow.Value}.GetNewClosure()
    $preflight=& $module {param($p,$run,$executor,$identity)Invoke-LabAiExternalModelSqlPreflight -SqlPlan $p -RunId $run -SqlExecutor $executor -Binding ([PSCustomObject]@{}) -BindingIdentity $identity} $sqlPlan $runId $sqlExecutor $bindingIdentity
    Add-CheckResult 'SQL-Preflight bindet eigenen Run an SQL-Plan und Datenbankidentität' (
        $preflight.Status -ceq 'SQL_PREFLIGHT_VERIFIED' -and $preflight.SqlPlanKey -ceq $sqlPlan.SqlPlanKey -and
        $preflight.RunId -ceq $runId -and $preflight.ScopeId -ceq $scopeId -and $preflight.DatabaseGuid -ceq $databaseGuid)
    Add-CheckResult 'SQL-Preflight prüft Zielscope ausschließlich lesend und parametrisiert' (
        $sqlCapture.Value.Database -ceq 'AiLab' -and $sqlCapture.Value.Parameters.credential -ceq $sqlPlan.CredentialName -and
        $sqlCapture.Value.Parameters.ownerTable -ceq ('dbo.'+$sqlPlan.OwnershipTableName) -and
        $sqlCapture.Value.Query -match 'sys\.fn_my_permissions' -and $sqlCapture.Value.Query -notmatch '(?im)^\s*(CREATE|ALTER|DROP|INSERT|UPDATE|DELETE)\s')
    Add-CheckResult 'SQL-Preflight-Receipt ist schema-valide, hashgebunden und geheimnisfrei' (
        ($preflight|ConvertTo-Json -Depth 10|Test-Json -SchemaFile (Join-Path $repoRoot 'Schemas/ai-external-model-sql-preflight-receipt.schema.json')) -and
        $preflight.ReceiptKey -match '^[a-f0-9]{64}$' -and
        (($preflight|ConvertTo-Json -Depth 10) -notmatch '(?i)(password|api.?key|secret|query|credential.{0,3}:|C:\\|/home/)'))
    $preflightFailures=@(
        @{Name='SQL-Version';Code='AI_EXTERNAL_MODEL_SQL_VERSION_UNSUPPORTED';Property='SqlMajorVersion';Value=16},
        @{Name='Systemdatenbank';Code='AI_EXTERNAL_MODEL_SQL_DATABASE_MISMATCH';Property='DatabaseId';Value=1},
        @{Name='Datenbankzustand';Code='AI_EXTERNAL_MODEL_SQL_DATABASE_UNAVAILABLE';Property='DatabaseStatus';Value='OFFLINE'},
        @{Name='Database Master Key';Code='AI_EXTERNAL_MODEL_SQL_MASTER_KEY_REQUIRED';Property='HasDatabaseMasterKey';Value=$false},
        @{Name='CONTROL-Berechtigung';Code='AI_EXTERNAL_MODEL_SQL_PERMISSION_DENIED';Property='HasControlDatabase';Value=$false},
        @{Name='CREATE-EXTERNAL-MODEL-Berechtigung';Code='AI_EXTERNAL_MODEL_SQL_PERMISSION_DENIED';Property='HasCreateExternalModel';Value=$false},
        @{Name='Credential-Kollision';Code='AI_EXTERNAL_MODEL_SQL_OBJECT_COLLISION';Property='CredentialExists';Value=$true},
        @{Name='External-Model-Kollision';Code='AI_EXTERNAL_MODEL_SQL_OBJECT_COLLISION';Property='ExternalModelExists';Value=$true},
        @{Name='Ownership-Tabellen-Kollision';Code='AI_EXTERNAL_MODEL_SQL_OBJECT_COLLISION';Property='OwnershipTableExists';Value=$true}
    )
    foreach($case in $preflightFailures){
        $changed=$validSqlRow.PSObject.Copy();$changed.($case.Property)=$case.Value;$sqlRow.Value=$changed;$actual=$null
        try{& $module {param($p,$run,$executor,$identity)Invoke-LabAiExternalModelSqlPreflight -SqlPlan $p -RunId $run -SqlExecutor $executor -Binding ([PSCustomObject]@{}) -BindingIdentity $identity} $sqlPlan $runId $sqlExecutor $bindingIdentity|Out-Null;$actual='NO_ERROR'}catch{$actual=$_.Exception.Message}
        Add-CheckResult "SQL-Preflight blockiert $($case.Name)" ($actual -eq $case.Code)
    }
    $sqlRow.Value=$validSqlRow.PSObject.Copy()
    $tamperedSqlPlan=$sqlPlan.PSObject.Copy();$tamperedSqlPlan.DatabaseName='OtherDb';$sqlCallsBefore=$sqlCapture.Value
    $tamperedSqlPlanCode=$null;try{& $module {param($p,$run,$executor,$identity)Invoke-LabAiExternalModelSqlPreflight -SqlPlan $p -RunId $run -SqlExecutor $executor -Binding ([PSCustomObject]@{}) -BindingIdentity $identity} $tamperedSqlPlan $runId $sqlExecutor $bindingIdentity|Out-Null;$tamperedSqlPlanCode='NO_ERROR'}catch{$tamperedSqlPlanCode=$_.Exception.Message}
    Add-CheckResult 'SQL-Preflight blockiert manipulierten SQL-Plan vor SQL-Zugriff' ($tamperedSqlPlanCode -eq 'AI_EXTERNAL_MODEL_SQL_PLAN_INVALID' -and $sqlCapture.Value -eq $sqlCallsBefore)
    $tamperedOwnerPlan=$sqlPlan.PSObject.Copy();$tamperedOwnerPlan.OwnershipTableName='SqlServerLabAiOwner_'+('e'*24)
    $tamperedOwnerCode=$null;try{& $module {param($p,$run,$executor,$identity)Invoke-LabAiExternalModelSqlPreflight -SqlPlan $p -RunId $run -SqlExecutor $executor -Binding ([PSCustomObject]@{}) -BindingIdentity $identity} $tamperedOwnerPlan $runId $sqlExecutor $bindingIdentity|Out-Null;$tamperedOwnerCode='NO_ERROR'}catch{$tamperedOwnerCode=$_.Exception.Message}
    Add-CheckResult 'SQL-Preflight blockiert abweichenden Ownership-Tabellennamen vor SQL-Zugriff' ($tamperedOwnerCode -eq 'AI_EXTERNAL_MODEL_SQL_PLAN_INVALID' -and $sqlCapture.Value -eq $sqlCallsBefore)
    $tamperedReceipt=$receipt.PSObject.Copy();$tamperedReceipt.ReceiptKey='e'*64
    $tamperedReceiptCode=$null;try{Get-SqlServerLabAiExternalModelSqlPlan -Plan $probePlan -EndpointReceipt $tamperedReceipt -DatabaseName AiLab|Out-Null;$tamperedReceiptCode='NO_ERROR'}catch{$tamperedReceiptCode=$_.Exception.Message}
    Add-CheckResult 'SQL-Plan blockiert manipuliertes Endpoint-Receipt' ($tamperedReceiptCode -eq 'AI_EXTERNAL_MODEL_ENDPOINT_RECEIPT_INVALID')
    $otherPlan=Get-SqlServerLabAiExternalModelPlan -Backend LlamaCppOpenVino -Accelerator NPU -Location 'https://localhost:11435/v1/embeddings' -ExternalModelName OtherModel -RuntimeModel bound-model -Dimension 3 -ModelSha256 $h -RuntimeSha256 $h -ServerCertificateSha256 $c
    $mismatchedReceiptCode=$null;try{Get-SqlServerLabAiExternalModelSqlPlan -Plan $otherPlan -EndpointReceipt $receipt -DatabaseName AiLab|Out-Null;$mismatchedReceiptCode='NO_ERROR'}catch{$mismatchedReceiptCode=$_.Exception.Message}
    Add-CheckResult 'SQL-Plan blockiert planfremdes Endpoint-Receipt' ($mismatchedReceiptCode -eq 'AI_EXTERNAL_MODEL_ENDPOINT_RECEIPT_MISMATCH')
    $expiredReceipt=$receipt.PSObject.Copy();$expiredReceipt.VerifiedAtUtc=[DateTime]::UtcNow.AddSeconds(-301).ToString('o',[Globalization.CultureInfo]::InvariantCulture)
    $expiredIdentity=[ordered]@{Contract='SqlServerLab.AiExternalModelEndpointReceiptBinding/1.0';PlanKey=$expiredReceipt.PlanKey;Backend=$expiredReceipt.Backend;Dimension=[int]$expiredReceipt.Dimension;HttpStatus=[int]$expiredReceipt.HttpStatus;ServerCertificateSha256=$expiredReceipt.ServerCertificateSha256;DurationMilliseconds=[int64]$expiredReceipt.DurationMilliseconds;VerifiedAtUtc=$expiredReceipt.VerifiedAtUtc}
    $expiredReceipt.ReceiptKey=& $module {param($i)Get-LabAiPlanKey -InputObject $i} $expiredIdentity
    $expiredReceiptCode=$null;try{Get-SqlServerLabAiExternalModelSqlPlan -Plan $probePlan -EndpointReceipt $expiredReceipt -DatabaseName AiLab -MaxEndpointAgeSeconds 300|Out-Null;$expiredReceiptCode='NO_ERROR'}catch{$expiredReceiptCode=$_.Exception.Message}
    Add-CheckResult 'SQL-Plan blockiert abgelaufene Endpoint-Evidence' ($expiredReceiptCode -eq 'AI_EXTERNAL_MODEL_ENDPOINT_RECEIPT_EXPIRED')

    $failureCases=@(
        @{Name='Zertifikatabweichung';Code='AI_EXTERNAL_MODEL_TLS_CERTIFICATE_MISMATCH';Transport={param($request)[PSCustomObject]@{StatusCode=200;ServerCertificateSha256=('d'*64);Body=[PSCustomObject]@{model='bound-model';data=@([PSCustomObject]@{embedding=@(1,2,3)})}}}},
        @{Name='leere Antwort';Code='AI_EXTERNAL_MODEL_RESPONSE_INVALID';Transport={param($request)$null=$request;[PSCustomObject]@{StatusCode=200;ServerCertificateSha256=$c;Body=$null}}.GetNewClosure()},
        @{Name='abweichenden Runtime-Modellnamen';Code='AI_EXTERNAL_MODEL_RUNTIME_MODEL_MISMATCH';Transport={param($request)$null=$request;[PSCustomObject]@{StatusCode=200;ServerCertificateSha256=$c;Body=[PSCustomObject]@{model='other-model';data=@([PSCustomObject]@{embedding=@(1,2,3)})}}}.GetNewClosure()},
        @{Name='fehlenden Runtime-Modellnamen';Code='AI_EXTERNAL_MODEL_RUNTIME_MODEL_MISMATCH';Transport={param($request)$null=$request;[PSCustomObject]@{StatusCode=200;ServerCertificateSha256=$c;Body=[PSCustomObject]@{data=@([PSCustomObject]@{embedding=@(1,2,3)})}}}.GetNewClosure()},
        @{Name='mehrere Vektoren';Code='AI_EXTERNAL_MODEL_RESPONSE_INVALID';Transport={param($request)[PSCustomObject]@{StatusCode=200;ServerCertificateSha256=$c;Body=[PSCustomObject]@{model='bound-model';data=@([PSCustomObject]@{embedding=@(1,2,3)},[PSCustomObject]@{embedding=@(1,2,3)})}}}.GetNewClosure()},
        @{Name='falsche Dimension';Code='AI_EXTERNAL_MODEL_DIMENSION_MISMATCH';Transport={param($request)[PSCustomObject]@{StatusCode=200;ServerCertificateSha256=$c;Body=[PSCustomObject]@{model='bound-model';data=@([PSCustomObject]@{embedding=@(1,2)})}}}.GetNewClosure()},
        @{Name='nicht endlichen Vektor';Code='AI_EXTERNAL_MODEL_VECTOR_INVALID';Transport={param($request)[PSCustomObject]@{StatusCode=200;ServerCertificateSha256=$c;Body=[PSCustomObject]@{model='bound-model';data=@([PSCustomObject]@{embedding=@(1,[double]::NaN,3)})}}}.GetNewClosure()},
        @{Name='Vektorwert ausserhalb float32';Code='AI_EXTERNAL_MODEL_VECTOR_INVALID';Transport={param($request)$null=$request;[PSCustomObject]@{StatusCode=200;ServerCertificateSha256=$c;Body=[PSCustomObject]@{model='bound-model';data=@([PSCustomObject]@{embedding=@(1,[double]::MaxValue,3)})}}}.GetNewClosure()},
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
    $sqlPlanCommand=Get-Command Get-SqlServerLabAiExternalModelSqlPlan -Module $module.Name
    Add-CheckResult 'Öffentlicher SQL-Planer verlangt Plan, Receipt und Datenbank ohne Apply-Parameter' (
        $sqlPlanCommand.Parameters.ContainsKey('Plan') -and $sqlPlanCommand.Parameters.ContainsKey('EndpointReceipt') -and
        $sqlPlanCommand.Parameters.ContainsKey('DatabaseName') -and -not $sqlPlanCommand.Parameters.ContainsKey('ApiKey') -and
        -not $sqlPlanCommand.Parameters.ContainsKey('SqlExecutor'))
    $sqlPreflightCommand=Get-Command Test-SqlServerLabAiExternalModelSqlPreflight -Module $module.Name
    Add-CheckResult 'Öffentlicher SQL-Preflight bindet Run und verbirgt Executor und Secret' (
        $sqlPreflightCommand.Parameters.ContainsKey('SqlPlan') -and $sqlPreflightCommand.Parameters.ContainsKey('RunId') -and
        $sqlPreflightCommand.Parameters.ContainsKey('InstanceId') -and -not $sqlPreflightCommand.Parameters.ContainsKey('SqlExecutor') -and
        -not $sqlPreflightCommand.Parameters.ContainsKey('SaPassword'))
    Add-CheckResult 'Öffentliche Artifact-Prüfung ist exportiert und verlangt beide lokalen Dateien' (
        (Get-Command Test-SqlServerLabAiExternalModelArtifact -Module $module.Name).Parameters.ContainsKey('RuntimePath') -and
        (Get-Command Test-SqlServerLabAiExternalModelArtifact -Module $module.Name).Parameters.ContainsKey('ModelPath'))
    $gatewayStartCommand=Get-Command Start-SqlServerLabOvmsHttpsGateway -Module $module.Name
    $gatewayStopCommand=Get-Command Stop-SqlServerLabOvmsHttpsGateway -Module $module.Name
    Add-CheckResult 'Öffentlicher OVMS-Gateway-Lifecycle ist explizit und WhatIf-fähig' (
        $gatewayStartCommand.Parameters.ContainsKey('UpstreamLocation') -and $gatewayStartCommand.Parameters.ContainsKey('CertificatePath') -and
        $gatewayStartCommand.Parameters.ContainsKey('ApiKey') -and $gatewayStartCommand.Parameters.ContainsKey('WhatIf') -and
        $gatewayStopCommand.Parameters.ContainsKey('OperationId') -and $gatewayStopCommand.Parameters.ContainsKey('WhatIf'))
    $whatIfSecret=[Security.SecureString]::new();1..24|ForEach-Object{$whatIfSecret.AppendChar('a')};$whatIfSecret.MakeReadOnly()
    $gatewayWhatIf=Start-SqlServerLabOvmsHttpsGateway -UpstreamLocation 'http://127.0.0.1:19000/v3/embeddings' -RuntimeModel model -Dimension 3 -Port 19001 -CertificatePath missing -PrivateKeyPath missing -ApiKey $whatIfSecret -WhatIf
    Add-CheckResult 'OVMS-Gateway-WhatIf startet weder Probe noch Worker' ($null -eq $gatewayWhatIf)
    $foreignStop=$null;try{Stop-SqlServerLabOvmsHttpsGateway -OperationId ([guid]::NewGuid().ToString('D')) -Confirm:$false;$foreignStop='NO_ERROR'}catch{$foreignStop=$_.Exception.Message}
    Add-CheckResult 'OVMS-Gateway-Stop blockiert fremde Operationen' ($foreignStop -eq 'AI_OVMS_GATEWAY_OWNERSHIP_NOT_FOUND')
    $workerSource=Get-Content -LiteralPath (Join-Path $repoRoot 'Tools/Invoke-OvmsHttpsGatewayWorker.ps1') -Raw
    Add-CheckResult 'OVMS-Gateway-Worker bindet Loopback, deaktiviert Proxy und begrenzt Eingaben' (
        $workerSource -match '\[Net\.IPAddress\]::Loopback' -and $workerSource -match '\$handler\.UseProxy=\$false' -and
        $workerSource -match '16384' -and $workerSource -match '65536' -and $workerSource -match 'FixedTimeEquals')
}
finally {
    Remove-Module $module -Force -ErrorAction SilentlyContinue
    if(Test-Path -LiteralPath $artifactRoot){Remove-Item -LiteralPath $artifactRoot -Recurse -Force}
}
Write-Host "`nAI external model acceleration checks: $passed passed, $($failures.Count) failed"
if($failures.Count){$failures|ForEach-Object{Write-Host " - $_" -ForegroundColor Red};exit 1}
