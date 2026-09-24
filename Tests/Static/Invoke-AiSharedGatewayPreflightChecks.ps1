#Requires -Version 7.2
[CmdletBinding()]param()
$ErrorActionPreference='Stop';$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
. (Join-Path $PSScriptRoot '../Common/CheckResult.ps1')
$failures=[Collections.Generic.List[string]]::new();$passed=0
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-shared-gateway-preflight-'+[guid]::NewGuid().ToString('N'))
$testRoot=[IO.Path]::GetFullPath($testRoot);$tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
if(-not $testRoot.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($testRoot) -notmatch '^sql-lab-shared-gateway-preflight-[a-f0-9]{32}$'){throw 'Unsafe synthetic test root'}
$null=[IO.Directory]::CreateDirectory($testRoot)
$disposable=[Collections.Generic.List[IDisposable]]::new()
function New-TestCa([string]$Name){
    $rsa=[Security.Cryptography.RSA]::Create(2048);$script:disposable.Add($rsa)
    $request=[Security.Cryptography.X509Certificates.CertificateRequest]::new("CN=$Name",$rsa,[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $request.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new($true,$false,0,$true))
    $request.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509KeyUsageExtension]::new([Security.Cryptography.X509Certificates.X509KeyUsageFlags]::KeyCertSign -bor [Security.Cryptography.X509Certificates.X509KeyUsageFlags]::CrlSign,$true))
    $certificate=$request.CreateSelfSigned([datetimeoffset]::UtcNow.AddDays(-1),[datetimeoffset]::UtcNow.AddDays(3));$script:disposable.Add($certificate);$certificate
}
function New-TestLeaf([Security.Cryptography.X509Certificates.X509Certificate2]$Ca,[string]$DnsName){
    $rsa=[Security.Cryptography.RSA]::Create(2048);$script:disposable.Add($rsa)
    $request=[Security.Cryptography.X509Certificates.CertificateRequest]::new("CN=$DnsName",$rsa,[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $request.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new($false,$false,0,$true))
    $request.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509KeyUsageExtension]::new([Security.Cryptography.X509Certificates.X509KeyUsageFlags]::DigitalSignature -bor [Security.Cryptography.X509Certificates.X509KeyUsageFlags]::KeyEncipherment,$true))
    $eku=[Security.Cryptography.OidCollection]::new();$null=$eku.Add([Security.Cryptography.Oid]::new('1.3.6.1.5.5.7.3.1'));$request.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]::new($eku,$true))
    $san=[Security.Cryptography.X509Certificates.SubjectAlternativeNameBuilder]::new();$san.AddDnsName($DnsName);$request.CertificateExtensions.Add($san.Build())
    $serial=[byte[]]::new(16);[Security.Cryptography.RandomNumberGenerator]::Fill($serial)
    $public=$request.Create($Ca,[datetimeoffset]::UtcNow.AddHours(-1),[datetimeoffset]::UtcNow.AddDays(1),$serial);$script:disposable.Add($public)
    $certificate=[Security.Cryptography.X509Certificates.RSACertificateExtensions]::CopyWithPrivateKey($public,$rsa);$script:disposable.Add($certificate)
    [pscustomobject]@{Certificate=$certificate;PrivateKey=$rsa}
}
function Write-TestCertificateSet($Ca,$Leaf,[string]$Prefix){
    $certPath=Join-Path $testRoot "$Prefix-cert.pem";$keyPath=Join-Path $testRoot "$Prefix-key.pem";$caPath=Join-Path $testRoot "$Prefix-ca.pem"
    [IO.File]::WriteAllText($certPath,$Leaf.Certificate.ExportCertificatePem());[IO.File]::WriteAllText($keyPath,$Leaf.PrivateKey.ExportPkcs8PrivateKeyPem());[IO.File]::WriteAllText($caPath,$Ca.ExportCertificatePem())
    [pscustomobject]@{CertificatePath=$certPath;PrivateKeyPath=$keyPath;CertificateAuthorityPath=$caPath;ServerHash=$Leaf.Certificate.GetCertHashString([Security.Cryptography.HashAlgorithmName]::SHA256).ToLowerInvariant();CaHash=$Ca.GetCertHashString([Security.Cryptography.HashAlgorithmName]::SHA256).ToLowerInvariant()}
}
function Reject([scriptblock]$Action,[string]$Code){try{& $Action|Out-Null;$false}catch{$_.Exception.Message -ceq $Code}}
$module=$null
try {
    $runtimePath=Join-Path $testRoot 'runtime.bin';$modelPath=Join-Path $testRoot 'model.gguf';[IO.File]::WriteAllText($runtimePath,'synthetic runtime');[IO.File]::WriteAllText($modelPath,'synthetic model')
    $runtimeHash=(Get-FileHash -LiteralPath $runtimePath -Algorithm SHA256).Hash.ToLowerInvariant();$modelHash=(Get-FileHash -LiteralPath $modelPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $ca=New-TestCa 'SQL Server Lab Test CA';$leaf=New-TestLeaf $ca 'host.docker.internal';$files=Write-TestCertificateSet $ca $leaf 'valid'
    $consumer=[pscustomobject]@{RunId='11111111-1111-4111-8111-111111111111';InstanceId='primary';DatabaseId='22222222-2222-4222-8222-222222222222';ExternalModelName='SharedEmbedding';ApiKeyReference='SQL_SERVER_LAB_SECRET_SHARED_AI_A'}
    $module=Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru
    $plan=Get-SqlServerLabAiSharedGatewayPlan -GatewayId shared-ai -Location 'https://host.docker.internal:18443/v1/embeddings' -UpstreamBackend LlamaCppCuda -UpstreamLocation 'http://127.0.0.1:18080/v1/embeddings' -RuntimeModel bound-model -Dimension 768 -InputProfile nomic-search -ModelSha256 $modelHash -RuntimeSha256 $runtimeHash -ServerCertificateSha256 $files.ServerHash -CertificateAuthoritySha256 $files.CaHash -Consumer $consumer
    $receipt=$plan|Test-SqlServerLabAiSharedGatewayPreflight -RuntimePath $runtimePath -ModelPath $modelPath -CertificatePath $files.CertificatePath -PrivateKeyPath $files.PrivateKeyPath -CertificateAuthorityPath $files.CertificateAuthorityPath
    Add-CheckResult 'Preflight bindet Artefakte, Zertifikatskette und SAN schema-valide' ($receipt.Status -ceq 'PREFLIGHT_VERIFIED' -and ($receipt|ConvertTo-Json -Depth 12|Test-Json -SchemaFile (Join-Path $repoRoot 'Schemas/ai-shared-gateway-preflight-receipt.schema.json')))
    $json=$receipt|ConvertTo-Json -Depth 12
    Add-CheckResult 'Receipt enthält weder Pfade noch Schlüsselmaterial' ($json -notmatch [regex]::Escape($testRoot) -and $json -notmatch 'PrivateKey')
    $tampered=$plan.PSObject.Copy();$tampered.RuntimeModel='other-model'
    Add-CheckResult 'Manipulierter Plan wird vor Dateiprüfung abgewiesen' (Reject {$tampered|Test-SqlServerLabAiSharedGatewayPreflight -RuntimePath missing -ModelPath missing -CertificatePath missing -PrivateKeyPath missing -CertificateAuthorityPath missing} 'AI_SHARED_GATEWAY_PLAN_INVALID')
    $wrongRuntime=Join-Path $testRoot 'wrong-runtime.bin';[IO.File]::WriteAllText($wrongRuntime,'wrong')
    Add-CheckResult 'Falsche Runtime scheitert geschlossen' (Reject {$plan|Test-SqlServerLabAiSharedGatewayPreflight -RuntimePath $wrongRuntime -ModelPath $modelPath -CertificatePath $files.CertificatePath -PrivateKeyPath $files.PrivateKeyPath -CertificateAuthorityPath $files.CertificateAuthorityPath} 'AI_SHARED_GATEWAY_RUNTIME_HASH_MISMATCH')
    Add-CheckResult 'Doppelte Eingabepfade werden abgewiesen' (Reject {$plan|Test-SqlServerLabAiSharedGatewayPreflight -RuntimePath $runtimePath -ModelPath $runtimePath -CertificatePath $files.CertificatePath -PrivateKeyPath $files.PrivateKeyPath -CertificateAuthorityPath $files.CertificateAuthorityPath} 'AI_SHARED_GATEWAY_INPUT_PATHS_MUST_DIFFER')
    $otherKey=[Security.Cryptography.RSA]::Create(2048);$disposable.Add($otherKey);$otherKeyPath=Join-Path $testRoot 'other-key.pem';[IO.File]::WriteAllText($otherKeyPath,$otherKey.ExportPkcs8PrivateKeyPem())
    Add-CheckResult 'Falscher privater Schlüssel wird abgewiesen' (Reject {$plan|Test-SqlServerLabAiSharedGatewayPreflight -RuntimePath $runtimePath -ModelPath $modelPath -CertificatePath $files.CertificatePath -PrivateKeyPath $otherKeyPath -CertificateAuthorityPath $files.CertificateAuthorityPath} 'AI_SHARED_GATEWAY_CERTIFICATE_KEY_MISMATCH')
    $wrongPinPlan=Get-SqlServerLabAiSharedGatewayPlan -GatewayId shared-ai -Location 'https://host.docker.internal:18443/v1/embeddings' -UpstreamBackend LlamaCppCuda -UpstreamLocation 'http://127.0.0.1:18080/v1/embeddings' -RuntimeModel bound-model -Dimension 768 -ModelSha256 $modelHash -RuntimeSha256 $runtimeHash -ServerCertificateSha256 ('c'*64) -CertificateAuthoritySha256 $files.CaHash -Consumer $consumer
    Add-CheckResult 'Falscher Serverzertifikat-Pin wird abgewiesen' (Reject {$wrongPinPlan|Test-SqlServerLabAiSharedGatewayPreflight -RuntimePath $runtimePath -ModelPath $modelPath -CertificatePath $files.CertificatePath -PrivateKeyPath $files.PrivateKeyPath -CertificateAuthorityPath $files.CertificateAuthorityPath} 'AI_SHARED_GATEWAY_SERVER_CERTIFICATE_HASH_MISMATCH')
    $wrongHostLeaf=New-TestLeaf $ca 'other.internal';$wrongHostFiles=Write-TestCertificateSet $ca $wrongHostLeaf 'wrong-host'
    $wrongHostPlan=Get-SqlServerLabAiSharedGatewayPlan -GatewayId shared-ai -Location 'https://host.docker.internal:18443/v1/embeddings' -UpstreamBackend LlamaCppCuda -UpstreamLocation 'http://127.0.0.1:18080/v1/embeddings' -RuntimeModel bound-model -Dimension 768 -ModelSha256 $modelHash -RuntimeSha256 $runtimeHash -ServerCertificateSha256 $wrongHostFiles.ServerHash -CertificateAuthoritySha256 $files.CaHash -Consumer $consumer
    Add-CheckResult 'Falscher Zertifikat-SAN wird abgewiesen' (Reject {$wrongHostPlan|Test-SqlServerLabAiSharedGatewayPreflight -RuntimePath $runtimePath -ModelPath $modelPath -CertificatePath $wrongHostFiles.CertificatePath -PrivateKeyPath $wrongHostFiles.PrivateKeyPath -CertificateAuthorityPath $files.CertificateAuthorityPath} 'AI_SHARED_GATEWAY_CERTIFICATE_HOST_MISMATCH')
    $otherCa=New-TestCa 'Other Test CA';$otherCaPath=Join-Path $testRoot 'other-ca.pem';[IO.File]::WriteAllText($otherCaPath,$otherCa.ExportCertificatePem())
    $chainPlan=Get-SqlServerLabAiSharedGatewayPlan -GatewayId shared-ai -Location 'https://host.docker.internal:18443/v1/embeddings' -UpstreamBackend LlamaCppCuda -UpstreamLocation 'http://127.0.0.1:18080/v1/embeddings' -RuntimeModel bound-model -Dimension 768 -ModelSha256 $modelHash -RuntimeSha256 $runtimeHash -ServerCertificateSha256 $files.ServerHash -CertificateAuthoritySha256 ($otherCa.GetCertHashString([Security.Cryptography.HashAlgorithmName]::SHA256).ToLowerInvariant()) -Consumer $consumer
    Add-CheckResult 'Fremde Zertifikatskette wird abgewiesen' (Reject {$chainPlan|Test-SqlServerLabAiSharedGatewayPreflight -RuntimePath $runtimePath -ModelPath $modelPath -CertificatePath $files.CertificatePath -PrivateKeyPath $files.PrivateKeyPath -CertificateAuthorityPath $otherCaPath} 'AI_SHARED_GATEWAY_CERTIFICATE_CHAIN_INVALID')
    $expiredAt=$leaf.Certificate.NotAfter.ToUniversalTime().AddMinutes(1)
    $timeRejected=& $module {param($p,$runtime,$model,$cert,$key,$caPath,$now) try{Test-LabAiSharedGatewayPreflight -Plan $p -RuntimePath $runtime -ModelPath $model -CertificatePath $cert -PrivateKeyPath $key -CertificateAuthorityPath $caPath -VerifiedAtUtc $now|Out-Null;$false}catch{$_.Exception.Message -ceq 'AI_SHARED_GATEWAY_CERTIFICATE_TIME_INVALID'}} $plan $runtimePath $modelPath $files.CertificatePath $files.PrivateKeyPath $files.CertificateAuthorityPath $expiredAt
    Add-CheckResult 'Abgelaufenes Zertifikat wird abgewiesen' $timeRejected
    Add-CheckResult 'Öffentlicher Preflight ist manifestexportiert' ((Get-Command Test-SqlServerLabAiSharedGatewayPreflight).ModuleName -ceq 'SqlServerLab')
}
finally{if($module){Remove-Module $module -Force -ErrorAction SilentlyContinue};foreach($item in @($disposable)){try{$item.Dispose()}catch{}};if(Test-Path -LiteralPath $testRoot){Remove-Item -LiteralPath $testRoot -Recurse -Force}}
if($failures.Count){throw ($failures -join '; ')}
Write-Host "AI SHARED GATEWAY PREFLIGHT: PASS ($passed)"
