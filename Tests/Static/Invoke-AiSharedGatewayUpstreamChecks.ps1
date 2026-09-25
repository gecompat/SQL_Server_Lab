#Requires -Version 7.2
[CmdletBinding()]param()
$ErrorActionPreference='Stop';$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
. (Join-Path $PSScriptRoot '../Common/CheckResult.ps1')
$failures=[Collections.Generic.List[string]]::new();$passed=0
$testRoot=[IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-shared-gateway-upstream-'+[guid]::NewGuid().ToString('N'))))
$tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
if(-not $testRoot.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($testRoot) -notmatch '^sql-lab-shared-gateway-upstream-[a-f0-9]{32}$'){throw 'Unsafe synthetic test root'}
$null=[IO.Directory]::CreateDirectory($testRoot);$disposable=[Collections.Generic.List[IDisposable]]::new();$module=$null
function New-TestCa {
    $rsa=[Security.Cryptography.RSA]::Create(2048);$script:disposable.Add($rsa)
    $request=[Security.Cryptography.X509Certificates.CertificateRequest]::new('CN=SQL Server Lab Upstream Test CA',$rsa,[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $request.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new($true,$false,0,$true));$request.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509KeyUsageExtension]::new([Security.Cryptography.X509Certificates.X509KeyUsageFlags]::KeyCertSign -bor [Security.Cryptography.X509Certificates.X509KeyUsageFlags]::CrlSign,$true))
    $certificate=$request.CreateSelfSigned([datetimeoffset]::UtcNow.AddDays(-1),[datetimeoffset]::UtcNow.AddDays(3));$script:disposable.Add($certificate);$certificate
}
function New-TestLeaf($Ca) {
    $rsa=[Security.Cryptography.RSA]::Create(2048);$script:disposable.Add($rsa)
    $request=[Security.Cryptography.X509Certificates.CertificateRequest]::new('CN=host.docker.internal',$rsa,[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $request.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new($false,$false,0,$true));$request.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509KeyUsageExtension]::new([Security.Cryptography.X509Certificates.X509KeyUsageFlags]::DigitalSignature -bor [Security.Cryptography.X509Certificates.X509KeyUsageFlags]::KeyEncipherment,$true))
    $eku=[Security.Cryptography.OidCollection]::new();$null=$eku.Add([Security.Cryptography.Oid]::new('1.3.6.1.5.5.7.3.1'));$request.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]::new($eku,$true));$san=[Security.Cryptography.X509Certificates.SubjectAlternativeNameBuilder]::new();$san.AddDnsName('host.docker.internal');$request.CertificateExtensions.Add($san.Build())
    $serial=[byte[]]::new(16);[Security.Cryptography.RandomNumberGenerator]::Fill($serial);$public=$request.Create($Ca,[datetimeoffset]::UtcNow.AddHours(-1),[datetimeoffset]::UtcNow.AddDays(1),$serial);$script:disposable.Add($public)
    $certificate=[Security.Cryptography.X509Certificates.RSACertificateExtensions]::CopyWithPrivateKey($public,$rsa);$script:disposable.Add($certificate);[pscustomobject]@{Certificate=$certificate;PrivateKey=$rsa}
}
function Reject([scriptblock]$Action,[string]$Code){try{& $Action|Out-Null;$false}catch{$_.Exception.Message -ceq $Code}}
try {
    $runtime=Join-Path $testRoot 'runtime.bin';$model=Join-Path $testRoot 'model.gguf';$cert=Join-Path $testRoot 'cert.pem';$key=Join-Path $testRoot 'key.pem';$caPath=Join-Path $testRoot 'ca.pem'
    [IO.File]::WriteAllText($runtime,'synthetic runtime');[IO.File]::WriteAllText($model,'synthetic model');$ca=New-TestCa;$leaf=New-TestLeaf $ca
    [IO.File]::WriteAllText($cert,$leaf.Certificate.ExportCertificatePem());[IO.File]::WriteAllText($key,$leaf.PrivateKey.ExportPkcs8PrivateKeyPem());[IO.File]::WriteAllText($caPath,$ca.ExportCertificatePem())
    $runtimeHash=(Get-FileHash $runtime -Algorithm SHA256).Hash.ToLowerInvariant();$modelHash=(Get-FileHash $model -Algorithm SHA256).Hash.ToLowerInvariant();$consumer=[pscustomobject]@{RunId='11111111-1111-4111-8111-111111111111';InstanceId='primary';DatabaseId='22222222-2222-4222-8222-222222222222';ExternalModelName='SharedEmbedding';ApiKeyReference='SQL_SERVER_LAB_SECRET_SHARED_AI_A'}
    $module=Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru;$stateRoot=Join-Path $testRoot 'state'
    $common=@{Location='https://host.docker.internal:18443/v1/embeddings';RuntimeModel='bound-model';Dimension=3;InputProfile='raw';ModelSha256=$modelHash;RuntimeSha256=$runtimeHash;ServerCertificateSha256=$leaf.Certificate.GetCertHashString([Security.Cryptography.HashAlgorithmName]::SHA256).ToLowerInvariant();CertificateAuthoritySha256=$ca.GetCertHashString([Security.Cryptography.HashAlgorithmName]::SHA256).ToLowerInvariant();Consumer=$consumer}
    $plan=Get-SqlServerLabAiSharedGatewayPlan @common -GatewayId shared-ai -UpstreamBackend LlamaCppCuda -UpstreamLocation 'http://127.0.0.1:18080/v1/embeddings'
    $null=$plan|Register-SqlServerLabAiSharedGatewayStorage -RuntimePath $runtime -ModelPath $model -CertificatePath $cert -PrivateKeyPath $key -CertificateAuthorityPath $caPath -StateRoot $stateRoot -Confirm:$false
    $script:captured=$null;$transport={param($request)$script:captured=$request;[pscustomobject]@{StatusCode=200;Body=[pscustomobject]@{model='bound-model';data=@([pscustomobject]@{embedding=@(0.1,0.2,0.3)})}}}
    $receipt=& $module {param($plan,$root,$transport)Test-LabAiSharedGatewayUpstream -Plan $plan -StateRoot $root -Transport $transport} $plan $stateRoot $transport
    Add-CheckResult 'Llama-Upstream bindet Storage und Antwort schema-valide' ($receipt.Status -ceq 'UPSTREAM_VERIFIED' -and $receipt.Backend -ceq 'LlamaCppCuda' -and ($receipt|ConvertTo-Json -Depth 20|Test-Json -SchemaFile (Join-Path $repoRoot 'Schemas/ai-shared-gateway-upstream-receipt.schema.json')))
    Add-CheckResult 'Probe sendet genau einen festen v1-Embeddingrequest' ($script:captured.Path -ceq '/v1/embeddings' -and $script:captured.Body.model -ceq 'bound-model' -and @($script:captured.Body.input).Count -eq 1 -and $script:captured.Body.encoding_format -ceq 'float')
    $receiptJson=$receipt|ConvertTo-Json -Depth 20
    Add-CheckResult 'Upstream-Receipt enthält weder Pfad, Secret noch Vektor' ($receiptJson -notmatch [regex]::Escape($testRoot) -and $receiptJson -notmatch 'synthetic shared gateway probe' -and $receiptJson -notmatch '0\.1')
    $badModel={param($request)[pscustomobject]@{StatusCode=200;Body=[pscustomobject]@{model='other';data=@([pscustomobject]@{embedding=@(0.1,0.2,0.3)})}}}
    Add-CheckResult 'Abweichendes Modell wird abgewiesen' (Reject {& $module {param($p,$r,$t)Test-LabAiSharedGatewayUpstream $p $r -Transport $t} $plan $stateRoot $badModel} 'AI_SHARED_GATEWAY_UPSTREAM_MODEL_MISMATCH')
    $badDimension={param($request)[pscustomobject]@{StatusCode=200;Body=[pscustomobject]@{model='bound-model';data=@([pscustomobject]@{embedding=@(0.1,0.2)})}}}
    Add-CheckResult 'Abweichende Dimension wird abgewiesen' (Reject {& $module {param($p,$r,$t)Test-LabAiSharedGatewayUpstream $p $r -Transport $t} $plan $stateRoot $badDimension} 'AI_SHARED_GATEWAY_UPSTREAM_DIMENSION_MISMATCH')
    $badVector={param($request)[pscustomobject]@{StatusCode=200;Body=[pscustomobject]@{model='bound-model';data=@([pscustomobject]@{embedding=@(0.1,[double]::NaN,0.3)})}}}
    Add-CheckResult 'Nicht endlicher Vektor wird abgewiesen' (Reject {& $module {param($p,$r,$t)Test-LabAiSharedGatewayUpstream $p $r -Transport $t} $plan $stateRoot $badVector} 'AI_SHARED_GATEWAY_UPSTREAM_VECTOR_INVALID')
    $httpError={param($request)[pscustomobject]@{StatusCode=503;Body=$null}}
    Add-CheckResult 'HTTP-Fehler bleibt stabil und ohne Payload' (Reject {& $module {param($p,$r,$t)Test-LabAiSharedGatewayUpstream $p $r -Transport $t} $plan $stateRoot $httpError} 'AI_SHARED_GATEWAY_UPSTREAM_HTTP_503')
    $tampered=$plan.PSObject.Copy();$tampered.RuntimeModel='other'
    Add-CheckResult 'Manipulierter Plan blockiert vor Transport' (Reject {& $module {param($p,$r,$t)Test-LabAiSharedGatewayUpstream $p $r -Transport $t} $tampered $stateRoot {throw 'transport called'}} 'AI_SHARED_GATEWAY_PLAN_INVALID')
    $storedModel=Join-Path $stateRoot 'shared-ai-gateways/shared-ai/model.gguf';$storedBytes=[IO.File]::ReadAllBytes($storedModel);[IO.File]::AppendAllText($storedModel,'tampered')
    Add-CheckResult 'Storage-Drift blockiert vor Transport' (Reject {& $module {param($p,$r,$t)Test-LabAiSharedGatewayUpstream $p $r -Transport $t} $plan $stateRoot {throw 'transport called'}} 'AI_SHARED_GATEWAY_STORAGE_DRIFT');[IO.File]::WriteAllBytes($storedModel,$storedBytes)
    $ovms=Get-SqlServerLabAiSharedGatewayPlan @common -GatewayId shared-ovms -UpstreamBackend OpenVinoModelServer -UpstreamLocation 'http://127.0.0.1:19000/v3/embeddings'
    $null=$ovms|Register-SqlServerLabAiSharedGatewayStorage -RuntimePath $runtime -ModelPath $model -CertificatePath $cert -PrivateKeyPath $key -CertificateAuthorityPath $caPath -StateRoot $stateRoot -Confirm:$false
    $script:captured=$null;$ovmsReceipt=& $module {param($plan,$root,$transport)Test-LabAiSharedGatewayUpstream -Plan $plan -StateRoot $root -Transport $transport} $ovms $stateRoot $transport
    Add-CheckResult 'OVMS-Upstream verwendet den gebundenen v3-Pfad' ($script:captured.Path -ceq '/v3/embeddings' -and $ovmsReceipt.Backend -ceq 'OpenVinoModelServer')
    $source=Get-Content (Join-Path $repoRoot 'Private/AiSharedGatewayUpstream.ps1') -Raw
    Add-CheckResult 'Realer Transport deaktiviert Proxy und Redirects' ($source -match '\.UseProxy=\$false' -and $source -match '\.AllowAutoRedirect=\$false')
    Add-CheckResult 'Öffentliche Probe exportiert keinen Testtransport' ((Get-Command Test-SqlServerLabAiSharedGatewayUpstream).ModuleName -ceq 'SqlServerLab' -and (Get-Command Test-SqlServerLabAiSharedGatewayUpstream).Parameters.Keys -notcontains 'Transport')
}
finally {
    if($module){Remove-Module $module -Force -ErrorAction SilentlyContinue};foreach($item in @($disposable)){try{$item.Dispose()}catch{}}
    if(Test-Path -LiteralPath $testRoot){Remove-Item -LiteralPath $testRoot -Recurse -Force}
}
if($failures.Count){throw ($failures -join '; ')}
Write-Host "AI SHARED GATEWAY UPSTREAM: PASS ($passed)"
