#Requires -Version 7.2
[CmdletBinding()]param()
$ErrorActionPreference='Stop';$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
. (Join-Path $PSScriptRoot '../Common/CheckResult.ps1')
$failures=[Collections.Generic.List[string]]::new();$passed=0
$testRoot=[IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-shared-gateway-storage-'+[guid]::NewGuid().ToString('N'))))
$tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
if(-not $testRoot.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($testRoot) -notmatch '^sql-lab-shared-gateway-storage-[a-f0-9]{32}$'){throw 'Unsafe synthetic test root'}
$null=[IO.Directory]::CreateDirectory($testRoot);$disposable=[Collections.Generic.List[IDisposable]]::new();$module=$null
function New-TestCa {
    $rsa=[Security.Cryptography.RSA]::Create(2048);$script:disposable.Add($rsa)
    $request=[Security.Cryptography.X509Certificates.CertificateRequest]::new('CN=SQL Server Lab Storage Test CA',$rsa,[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $request.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new($true,$false,0,$true))
    $request.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509KeyUsageExtension]::new([Security.Cryptography.X509Certificates.X509KeyUsageFlags]::KeyCertSign -bor [Security.Cryptography.X509Certificates.X509KeyUsageFlags]::CrlSign,$true))
    $certificate=$request.CreateSelfSigned([datetimeoffset]::UtcNow.AddDays(-1),[datetimeoffset]::UtcNow.AddDays(3));$script:disposable.Add($certificate);$certificate
}
function New-TestLeaf($Ca) {
    $rsa=[Security.Cryptography.RSA]::Create(2048);$script:disposable.Add($rsa)
    $request=[Security.Cryptography.X509Certificates.CertificateRequest]::new('CN=host.docker.internal',$rsa,[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $request.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new($false,$false,0,$true))
    $request.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509KeyUsageExtension]::new([Security.Cryptography.X509Certificates.X509KeyUsageFlags]::DigitalSignature -bor [Security.Cryptography.X509Certificates.X509KeyUsageFlags]::KeyEncipherment,$true))
    $eku=[Security.Cryptography.OidCollection]::new();$null=$eku.Add([Security.Cryptography.Oid]::new('1.3.6.1.5.5.7.3.1'));$request.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]::new($eku,$true))
    $san=[Security.Cryptography.X509Certificates.SubjectAlternativeNameBuilder]::new();$san.AddDnsName('host.docker.internal');$request.CertificateExtensions.Add($san.Build())
    $serial=[byte[]]::new(16);[Security.Cryptography.RandomNumberGenerator]::Fill($serial)
    $public=$request.Create($Ca,[datetimeoffset]::UtcNow.AddHours(-1),[datetimeoffset]::UtcNow.AddDays(1),$serial);$script:disposable.Add($public)
    $certificate=[Security.Cryptography.X509Certificates.RSACertificateExtensions]::CopyWithPrivateKey($public,$rsa);$script:disposable.Add($certificate)
    [pscustomobject]@{Certificate=$certificate;PrivateKey=$rsa}
}
function Reject([scriptblock]$Action,[string]$Code){try{& $Action|Out-Null;$false}catch{$_.Exception.Message -ceq $Code}}
try {
    $runtime=Join-Path $testRoot 'source-runtime.bin';$model=Join-Path $testRoot 'source-model.gguf';$cert=Join-Path $testRoot 'source-cert.pem';$key=Join-Path $testRoot 'source-key.pem';$caPath=Join-Path $testRoot 'source-ca.pem'
    [IO.File]::WriteAllText($runtime,'synthetic runtime');[IO.File]::WriteAllText($model,'synthetic model')
    $ca=New-TestCa;$leaf=New-TestLeaf $ca
    [IO.File]::WriteAllText($cert,$leaf.Certificate.ExportCertificatePem());[IO.File]::WriteAllText($key,$leaf.PrivateKey.ExportPkcs8PrivateKeyPem());[IO.File]::WriteAllText($caPath,$ca.ExportCertificatePem())
    $runtimeHash=(Get-FileHash $runtime -Algorithm SHA256).Hash.ToLowerInvariant();$modelHash=(Get-FileHash $model -Algorithm SHA256).Hash.ToLowerInvariant()
    $consumer=[pscustomobject]@{RunId='11111111-1111-4111-8111-111111111111';InstanceId='primary';DatabaseId='22222222-2222-4222-8222-222222222222';ExternalModelName='SharedEmbedding';ApiKeyReference='SQL_SERVER_LAB_SECRET_SHARED_AI_A'}
    $module=Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru
    $plan=Get-SqlServerLabAiSharedGatewayPlan -GatewayId shared-ai -Location 'https://host.docker.internal:18443/v1/embeddings' -UpstreamBackend LlamaCppCuda -UpstreamLocation 'http://127.0.0.1:18080/v1/embeddings' -RuntimeModel bound-model -Dimension 768 -InputProfile nomic-search -ModelSha256 $modelHash -RuntimeSha256 $runtimeHash -ServerCertificateSha256 $leaf.Certificate.GetCertHashString([Security.Cryptography.HashAlgorithmName]::SHA256).ToLowerInvariant() -CertificateAuthoritySha256 $ca.GetCertHashString([Security.Cryptography.HashAlgorithmName]::SHA256).ToLowerInvariant() -Consumer $consumer
    $previewRoot=Join-Path $testRoot 'preview-state';$preview=$plan|Register-SqlServerLabAiSharedGatewayStorage -RuntimePath $runtime -ModelPath $model -CertificatePath $cert -PrivateKeyPath $key -CertificateAuthorityPath $caPath -StateRoot $previewRoot -WhatIf
    Add-CheckResult 'WhatIf prüft den Aufruf ohne StateRoot-Mutation' ($null -eq $preview -and -not(Test-Path -LiteralPath $previewRoot))

    $stateRoot=Join-Path $testRoot 'state';$receipt=$plan|Register-SqlServerLabAiSharedGatewayStorage -RuntimePath $runtime -ModelPath $model -CertificatePath $cert -PrivateKeyPath $key -CertificateAuthorityPath $caPath -StateRoot $stateRoot -Confirm:$false
    $gatewayRoot=Join-Path $stateRoot 'shared-ai-gateways/shared-ai'
    Add-CheckResult 'Registrierung liefert ein schema-validiertes Storage-Receipt' ($receipt.Status -ceq 'REGISTERED' -and ($receipt|ConvertTo-Json -Depth 20|Test-Json -SchemaFile (Join-Path $repoRoot 'Schemas/ai-shared-gateway-storage-receipt.schema.json')))
    $names=@(Get-ChildItem -LiteralPath $gatewayRoot -File|Sort-Object Name|ForEach-Object Name)
    Add-CheckResult 'Gemeinsamer Store enthält nur den festen gebundenen Dateisatz' (($names -join ',') -ceq 'certificate-authority.pem,model.gguf,plan.json,preflight.json,registration.json,runtime.bin,server-certificate.pem,server-private-key.pem')
    $receiptJson=$receipt|ConvertTo-Json -Depth 20;$registrationJson=Get-Content (Join-Path $gatewayRoot 'registration.json') -Raw
    Add-CheckResult 'Receipts und State enthalten weder Quellpfade noch Schlüsselinhalt' ($receiptJson -notmatch [regex]::Escape($testRoot) -and $registrationJson -notmatch [regex]::Escape($testRoot) -and $registrationJson -notmatch 'BEGIN PRIVATE KEY')
    $protected=& $module {param($root)$ok=Test-LabAiSharedGatewayStorageProtection $root;foreach($item in Get-ChildItem $root -File){$ok=$ok -and (Test-LabAiSharedGatewayStorageProtection $item.FullName -File -Executable:($item.Name -ceq 'runtime.bin'))};$ok} $gatewayRoot
    Add-CheckResult 'Gatewayverzeichnis und jede Datei sind benutzerexklusiv geschützt' $protected
    $before=@(Get-ChildItem $gatewayRoot -File|Sort-Object Name|ForEach-Object{"$($_.Name):$((Get-FileHash $_.FullName -Algorithm SHA256).Hash)"}) -join '|'
    $again=$plan|Register-SqlServerLabAiSharedGatewayStorage -RuntimePath $runtime -ModelPath $model -CertificatePath $cert -PrivateKeyPath $key -CertificateAuthorityPath $caPath -StateRoot $stateRoot -Confirm:$false
    $after=@(Get-ChildItem $gatewayRoot -File|Sort-Object Name|ForEach-Object{"$($_.Name):$((Get-FileHash $_.FullName -Algorithm SHA256).Hash)"}) -join '|'
    Add-CheckResult 'Identische Wiederholung ist idempotent und ändert keine Bytes' ($again.Status -ceq 'ALREADY_REGISTERED' -and $before -ceq $after -and $again.RegisteredAtUtc -ceq $receipt.RegisteredAtUtc)

    $otherConsumer=[pscustomobject]@{RunId='33333333-3333-4333-8333-333333333333';InstanceId='primary';DatabaseId='44444444-4444-4444-8444-444444444444';ExternalModelName='OtherEmbedding';ApiKeyReference='SQL_SERVER_LAB_SECRET_SHARED_AI_B'}
    $conflict=Get-SqlServerLabAiSharedGatewayPlan -GatewayId shared-ai -Location $plan.Location -UpstreamBackend $plan.UpstreamBackend -UpstreamLocation $plan.UpstreamLocation -RuntimeModel $plan.RuntimeModel -Dimension $plan.Dimension -InputProfile $plan.InputProfile -ModelSha256 $plan.ModelSha256 -RuntimeSha256 $plan.RuntimeSha256 -ServerCertificateSha256 $plan.ServerCertificateSha256 -CertificateAuthoritySha256 $plan.CertificateAuthoritySha256 -Consumer $otherConsumer
    Add-CheckResult 'Widersprüchlicher Plan desselben Gatewaynamens wird abgewiesen' (Reject {$conflict|Register-SqlServerLabAiSharedGatewayStorage -RuntimePath $runtime -ModelPath $model -CertificatePath $cert -PrivateKeyPath $key -CertificateAuthorityPath $caPath -StateRoot $stateRoot -Confirm:$false} 'AI_SHARED_GATEWAY_STORAGE_CONFLICT')

    $storedModel=Join-Path $gatewayRoot 'model.gguf';$storedModelBytes=[IO.File]::ReadAllBytes($storedModel);[IO.File]::AppendAllText($storedModel,'tampered')
    Add-CheckResult 'Inhaltsdrift im gemeinsamen Store scheitert geschlossen' (Reject {$plan|Register-SqlServerLabAiSharedGatewayStorage -RuntimePath $runtime -ModelPath $model -CertificatePath $cert -PrivateKeyPath $key -CertificateAuthorityPath $caPath -StateRoot $stateRoot -Confirm:$false} 'AI_SHARED_GATEWAY_STORAGE_DRIFT')
    [IO.File]::WriteAllBytes($storedModel,$storedModelBytes)

    $registrationPath=Join-Path $gatewayRoot 'registration.json';$registrationBytes=[IO.File]::ReadAllBytes($registrationPath)
    $tamperedRegistration=Get-Content -LiteralPath $registrationPath -Raw|ConvertFrom-Json -Depth 30;$tamperedRegistration.StateKey='0'*64
    [IO.File]::WriteAllText($registrationPath,($tamperedRegistration|ConvertTo-Json -Depth 30))
    Add-CheckResult 'Manipulierter StateKey scheitert geschlossen' (Reject {$plan|Register-SqlServerLabAiSharedGatewayStorage -RuntimePath $runtime -ModelPath $model -CertificatePath $cert -PrivateKeyPath $key -CertificateAuthorityPath $caPath -StateRoot $stateRoot -Confirm:$false} 'AI_SHARED_GATEWAY_STORAGE_DRIFT')
    [IO.File]::WriteAllBytes($registrationPath,$registrationBytes)

    $unexpected=Join-Path $gatewayRoot 'unexpected.txt';[IO.File]::WriteAllText($unexpected,'unexpected')
    & $module {param($path)Protect-LabAiSharedGatewayStoragePath $path -File} $unexpected
    Add-CheckResult 'Unerwartete Datei im gemeinsamen Store gilt als Drift' (Reject {$plan|Register-SqlServerLabAiSharedGatewayStorage -RuntimePath $runtime -ModelPath $model -CertificatePath $cert -PrivateKeyPath $key -CertificateAuthorityPath $caPath -StateRoot $stateRoot -Confirm:$false} 'AI_SHARED_GATEWAY_STORAGE_DRIFT')
    Remove-Item -LiteralPath $unexpected -Force

    $failureRoot=Join-Path $testRoot 'failure-state'
    & $module {function script:Write-LabArtifactJsonAtomic {param($Path,$InputObject)throw 'synthetic write failure'}}
    Add-CheckResult 'Publikationsfehler wird ohne interne Details gemeldet' (Reject {$plan|Register-SqlServerLabAiSharedGatewayStorage -RuntimePath $runtime -ModelPath $model -CertificatePath $cert -PrivateKeyPath $key -CertificateAuthorityPath $caPath -StateRoot $failureRoot -Confirm:$false} 'AI_SHARED_GATEWAY_STORAGE_REGISTRATION_FAILED')
    $failureShared=Join-Path $failureRoot 'shared-ai-gateways'
    Add-CheckResult 'Fehlercleanup entfernt ausschließlich den unveröffentlichten Stagingzustand' (-not(Test-Path (Join-Path $failureShared 'shared-ai')) -and @((Get-ChildItem $failureShared -Force -ErrorAction SilentlyContinue)|Where-Object Name -Like '.register-*').Count -eq 0)
    Remove-Module $module -Force;$module=Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru

    $parallelRoot=Join-Path $testRoot 'parallel-state';$planJson=$plan|ConvertTo-Json -Depth 30 -Compress
    $jobScript={param($manifest,$json,$runtime,$model,$cert,$key,$caPath,$root)Import-Module $manifest -Force;$p=$json|ConvertFrom-Json -Depth 30;$p|Register-SqlServerLabAiSharedGatewayStorage -RuntimePath $runtime -ModelPath $model -CertificatePath $cert -PrivateKeyPath $key -CertificateAuthorityPath $caPath -StateRoot $root -Confirm:$false}
    $jobs=@(1..2|ForEach-Object{Start-Job -ScriptBlock $jobScript -ArgumentList (Join-Path $repoRoot 'SqlServerLab.psd1'),$planJson,$runtime,$model,$cert,$key,$caPath,$parallelRoot})
    $null=$jobs|Wait-Job -Timeout 60;$outputs=@($jobs|Receive-Job -ErrorAction Stop);$states=@($jobs.State);$jobs|Remove-Job -Force
    Add-CheckResult 'Zwei Prozesse veröffentlichen genau eine Registrierung idempotent' (($states|Where-Object{$_ -ne 'Completed'}).Count -eq 0 -and (@($outputs.Status|Sort-Object) -join ',') -ceq 'ALREADY_REGISTERED,REGISTERED')
    Add-CheckResult 'Öffentlicher Registrierungsbefehl ist manifestexportiert' ((Get-Command Register-SqlServerLabAiSharedGatewayStorage).ModuleName -ceq 'SqlServerLab')
}
finally {
    if($module){Remove-Module $module -Force -ErrorAction SilentlyContinue}
    foreach($item in @($disposable)){try{$item.Dispose()}catch{}}
    if(Test-Path -LiteralPath $testRoot){Remove-Item -LiteralPath $testRoot -Recurse -Force}
}
if($failures.Count){throw ($failures -join '; ')}
Write-Host "AI SHARED GATEWAY STORAGE: PASS ($passed)"
