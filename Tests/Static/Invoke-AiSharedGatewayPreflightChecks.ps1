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

    $paths = @($runtimePath,$modelPath,$files.CertificatePath,$files.PrivateKeyPath,$files.CertificateAuthorityPath)
    $guided = & $module {
        param($Plan,$Paths)
        & {
            $command = ${function:Test-SqlServerLabAiSharedGatewayPreflight}
            $calls = [Collections.Generic.List[string]]::new()
            $messages = [Collections.Generic.List[string]]::new()
            $masked = [Collections.Generic.List[int]]::new()
            $inputs = [Collections.Generic.Queue[string]]::new()
            function Read-LabConsoleTextInput {
                param($Prompt,[switch]$MaskInput)
                if ($MaskInput) { $masked.Add($inputs.Count) }
                [pscustomobject]@{Status='Confirmed';Value=$inputs.Dequeue()}
            }
            function New-LabConsoleItem { param($Id,$Label) [pscustomobject]@{Id=$Id;Label=$Label} }
            function Invoke-LabConsoleMenu {
                param($ScreenId,$Title,$Subtitle,$Items)
                [pscustomobject]@{Status='Selected';SelectedItem=($Items | Where-Object Id -CEQ $choice)}
            }
            function Write-LabInfo { param($Message) $messages.Add($Message) }
            function Write-LabWarning { param($Message) $messages.Add($Message) }
            function Wait-LabConsoleAcknowledgement {}
            function Test-SqlServerLabAiSharedGatewayPreflight {
                param($Plan,$RuntimePath,$ModelPath,$CertificatePath,$PrivateKeyPath,$CertificateAuthorityPath)
                $calls.Add($Plan.PlanKey)
                & $command @PSBoundParameters
            }
            $choice = 'back'
            foreach ($path in $Paths) { $inputs.Enqueue($path) }
            Invoke-LabAiSharedGatewayPreflightInteractive -Plan $Plan
            $cancelSafe = $calls.Count -eq 0 -and $messages.Count -eq 0

            $choice = 'verify'
            $inputs.Enqueue('//invalid-fixture-share/runtime.bin')
            Invoke-LabAiSharedGatewayPreflightInteractive -Plan $Plan
            $badPathSafe = $calls.Count -eq 0 -and $messages.Count -eq 1 -and $messages[0] -notmatch 'invalid-fixture-share'
            $messages.Clear()

            foreach ($path in $Paths) { $inputs.Enqueue($path) }
            Invoke-LabAiSharedGatewayPreflightInteractive -Plan $Plan
            [pscustomobject]@{CancelSafe=$cancelSafe;BadPathSafe=$badPathSafe;Calls=$calls.ToArray();Messages=$messages.ToArray();Masked=$masked.ToArray()}
        }
    } $plan $paths
    Add-CheckResult 'Abbruch und Netzpfad lesen keine Artefakte' ($guided.CancelSafe -and $guided.BadPathSafe)
    Add-CheckResult 'Bestätigung prüft genau einmal den gebundenen Plan mit echten synthetischen Dateien' (
        $guided.Calls.Count -eq 1 -and $guided.Calls[0] -ceq $plan.PlanKey -and $guided.Messages.Count -eq 2 -and
        ($guided.Messages[1] | ConvertFrom-Json).Status -ceq 'PREFLIGHT_VERIFIED')
    Add-CheckResult 'Schlüsselpfad wird verdeckt und Pfade fehlen im Ergebnis' (
        ($guided.Masked -join ',') -ceq '2,2' -and -not @($paths | Where-Object { ($guided.Messages -join "`n").Contains($_) }).Count)

    $browserArguments = @{
        Plan = $plan
        RuntimePath = $runtimePath
        ModelPath = $modelPath
        CertificatePath = $files.CertificatePath
        PrivateKeyPath = $files.PrivateKeyPath
        CertificateAuthorityPath = $files.CertificateAuthorityPath
    }
    $browser = & $module {
        param($Parameters)
        $commandName = 'Test-SqlServerLabAiSharedGatewayPreflight'
        $request = @{CommandName=$commandName; ParameterSetName='__AllParameterSets'; Parameters=$Parameters}
        $catalog = Get-LabPublicCommandWebCatalog | Where-Object Name -CEQ $commandName
        $keyDescriptor = $catalog.ParameterSets[0].Parameters | Where-Object Name -CEQ 'PrivateKeyPath'
        $unconfirmed = try { Invoke-LabPublicCommandWebRequest @request | Out-Null; $false }
                       catch { $_.Exception.Message -ceq 'PUBLIC_COMMAND_UI_CONFIRMATION_REQUIRED' }
        $receipt = Invoke-LabPublicCommandWebRequest @request -Confirmed
        $invalid = @{} + $Parameters
        $invalid.RuntimePath = '//invalid-fixture-share/runtime.bin'
        $request.Parameters = $invalid
        $badPath = try { Invoke-LabPublicCommandWebRequest @request -Confirmed | Out-Null; $false }
                   catch { $_.Exception.Message -ceq 'AI_SHARED_GATEWAY_GUIDED_PATH_INVALID' }
        [pscustomobject]@{Unconfirmed=$unconfirmed;InvalidPath=$badPath;Receipt=$receipt;Sensitive=$keyDescriptor.Sensitive}
    } $browserArguments
    Add-CheckResult 'Browser verlangt Bestätigung, verdeckt den Schlüsselpfad und lehnt Netzpfade ab' (
        $browser.Unconfirmed -and $browser.InvalidPath -and $browser.Sensitive)
    $browserJson = $browser.Receipt | ConvertTo-Json -Depth 15
    Add-CheckResult 'Browser bestätigt denselben Plan auf echten synthetischen Dateien ohne Pfade im Ergebnis' (
        $browser.Receipt.Result.Count -eq 1 -and $browser.Receipt.Result[0].PlanKey -ceq $plan.PlanKey -and
        $browser.Receipt.Result[0].Status -ceq 'PREFLIGHT_VERIFIED' -and
        -not @($paths | Where-Object { $browserJson.Contains(($_ | ConvertTo-Json -Compress)) }).Count)
}
finally{if($module){Remove-Module $module -Force -ErrorAction SilentlyContinue};foreach($item in @($disposable)){try{$item.Dispose()}catch{}};if(Test-Path -LiteralPath $testRoot){Remove-Item -LiteralPath $testRoot -Recurse -Force}}
if($failures.Count){throw ($failures -join '; ')}
Write-Host "AI SHARED GATEWAY PREFLIGHT: PASS ($passed)"
