#Requires -Version 7.2
<#
.SYNOPSIS
    Prüft den eigenen OVMS-HTTPS-Gateway-Lifecycle ohne SQL oder Provider.
.DESCRIPTION
    Verwendet ausschließlich kurzlebige Loopbackports, einen synthetischen HTTP-
    Upstream und eine temporäre CA-/Leaf-Kette. Start, TLS-Probe, Binding, Stop,
    Secret-Löschung und Listenerabbau werden gemeinsam bestätigt.
#>
if(-not $IsWindows){throw 'AI_OVMS_GATEWAY_ACCEPTANCE_WINDOWS_REQUIRED'}
$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
function Get-FreePort { $l=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0);$l.Start();try{return ([Net.IPEndPoint]$l.LocalEndpoint).Port}finally{$l.Stop()} }
$upstreamPort=Get-FreePort;$gatewayPort=Get-FreePort
$fixture=Join-Path $env:TEMP ('sql-lab-ovms-proof-'+[guid]::NewGuid().ToString('N'));$null=[IO.Directory]::CreateDirectory($fixture)
$upstream=$null;$gateway=$null
try {
    $upstream=Start-ThreadJob -ArgumentList $upstreamPort -ScriptBlock {
        param($port);$listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,$port);$listener.Start(4)
        try {$deadline=[DateTime]::UtcNow.AddSeconds(30);for($n=0;$n -lt 4 -and [DateTime]::UtcNow -lt $deadline;$n++){$accept=$listener.AcceptTcpClientAsync();while(-not $accept.Wait(100) -and [DateTime]::UtcNow -lt $deadline){};if(-not $accept.IsCompletedSuccessfully){break};$client=$accept.Result;$stream=$client.GetStream();try{$bytes=[Collections.Generic.List[byte]]::new();$match=0;while($match -lt 4){$v=$stream.ReadByte();if($v -lt 0){break};$bytes.Add([byte]$v);$expected=@(13,10,13,10)[$match];if($v -eq $expected){$match++}elseif($v -eq 13){$match=1}else{$match=0}};$head=[Text.Encoding]::ASCII.GetString($bytes.ToArray());$length=[int]([regex]::Match($head,'(?im)^Content-Length:\s*([0-9]+)\s*$').Groups[1].Value);$body=[byte[]]::new($length);$offset=0;while($offset -lt $length){$offset+=$stream.Read($body,$offset,$length-$offset)};$json='{"object":"list","data":[{"object":"embedding","index":0,"embedding":[0.25,-0.5,1.0]}],"model":"ovms-proof","usage":{"secret":"strip"}}';$payload=[Text.Encoding]::UTF8.GetBytes($json);$header=[Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`nContent-Type: application/json`r`nContent-Length: $($payload.Length)`r`nConnection: close`r`n`r`n");$stream.Write($header);$stream.Write($payload);$stream.Flush()}finally{$stream.Dispose();$client.Dispose()}}}finally{$listener.Stop()}
    }
    $caRsa=[Security.Cryptography.RSA]::Create(2048);$caRequest=[Security.Cryptography.X509Certificates.CertificateRequest]::new('CN=SQL Lab OVMS Proof CA',$caRsa,[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pkcs1);$caRequest.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new($true,$false,0,$true));$caRequest.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509KeyUsageExtension]::new([Security.Cryptography.X509Certificates.X509KeyUsageFlags]::KeyCertSign -bor [Security.Cryptography.X509Certificates.X509KeyUsageFlags]::CrlSign,$true));$ca=$caRequest.CreateSelfSigned([DateTimeOffset]::UtcNow.AddMinutes(-2),[DateTimeOffset]::UtcNow.AddHours(1))
    $rsa=[Security.Cryptography.RSA]::Create(2048);$request=[Security.Cryptography.X509Certificates.CertificateRequest]::new('CN=127.0.0.1',$rsa,[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pkcs1);$san=[Security.Cryptography.X509Certificates.SubjectAlternativeNameBuilder]::new();$san.AddIpAddress([Net.IPAddress]::Loopback);$request.CertificateExtensions.Add($san.Build());$request.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new($false,$false,0,$true));$request.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509KeyUsageExtension]::new([Security.Cryptography.X509Certificates.X509KeyUsageFlags]::DigitalSignature -bor [Security.Cryptography.X509Certificates.X509KeyUsageFlags]::KeyEncipherment,$true));$eku=[Security.Cryptography.OidCollection]::new();$null=$eku.Add([Security.Cryptography.Oid]::new('1.3.6.1.5.5.7.3.1'));$request.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]::new($eku,$true));$serial=[byte[]]::new(16);[Security.Cryptography.RandomNumberGenerator]::Fill($serial);$publicCert=$request.Create($ca,[DateTimeOffset]::UtcNow.AddMinutes(-1),[DateTimeOffset]::UtcNow.AddMinutes(30),$serial);$cert=[Security.Cryptography.X509Certificates.RSACertificateExtensions]::CopyWithPrivateKey($publicCert,$rsa);$publicCert.Dispose()
    $certPath=Join-Path $fixture 'cert.pem';$keyPath=Join-Path $fixture 'key.pem';$rootPath=Join-Path $fixture 'root.pem';[IO.File]::WriteAllText($certPath,$cert.ExportCertificatePem());[IO.File]::WriteAllText($rootPath,$ca.ExportCertificatePem());[IO.File]::WriteAllText($keyPath,$rsa.ExportPkcs8PrivateKeyPem())
    Start-Sleep -Milliseconds 300
    if($upstream.State -ne 'Running'){throw 'UPSTREAM_NOT_READY'}
    Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force
    $secret=[Security.SecureString]::new();1..32|ForEach-Object{$secret.AppendChar('a')};$secret.MakeReadOnly()
    $gateway=Start-SqlServerLabOvmsHttpsGateway -UpstreamLocation "http://127.0.0.1:$upstreamPort/v3/embeddings" -RuntimeModel ovms-proof -Dimension 3 -Port $gatewayPort -CertificatePath $certPath -PrivateKeyPath $keyPath -TrustedRootPath $rootPath -ApiKey $secret -StartTimeoutSeconds 10 -LeaseSeconds 60 -Confirm:$false
    if($gateway.Status -cne 'ENDPOINT_VERIFIED'){throw 'GATEWAY_NOT_VERIFIED'}
    if([string]$gateway.BindingKey -cnotmatch '^[a-f0-9]{64}$'){throw 'GATEWAY_BINDING_INVALID'}
    if([string]$gateway.UpstreamBindingKey -cnotmatch '^[a-f0-9]{64}$'){throw 'UPSTREAM_BINDING_INVALID'}
    if(($gateway|ConvertTo-Json -Depth 5) -match '(?i)(api-key|cert\.pem|key\.pem|sql-lab-ovms-proof)'){throw 'GATEWAY_OUTPUT_NOT_SANITIZED'}
    $hash='a'*64
    $plan=Get-SqlServerLabAiExternalModelPlan -Backend OpenVinoModelServer -Accelerator NPU -TlsMode Gateway -Location $gateway.Location -ExternalModelName OvmsProof -RuntimeModel ovms-proof -Dimension 3 -ModelSha256 $hash -RuntimeSha256 $hash -ServerCertificateSha256 $gateway.ServerCertificateSha256 -GatewayBinding $gateway
    if($plan.Status -cne 'NOT_PROBED' -or $plan.GatewayBindingKey -cne $gateway.BindingKey){throw 'GATEWAY_PLAN_NOT_BOUND'}
    $endpointReceipt=$plan|Test-SqlServerLabAiExternalModelEndpoint -ApiKey $secret -TrustedRootCertificate $ca -TimeoutSeconds 5
    if($endpointReceipt.Status -cne 'ENDPOINT_VERIFIED' -or $endpointReceipt.PlanKey -cne $plan.PlanKey){throw 'GATEWAY_PLAN_ENDPOINT_NOT_VERIFIED'}
    $operationRoot=Join-Path $env:TEMP ('sql-lab-ovms-gateway-'+$gateway.OperationId)
    if(-not (Test-Path (Join-Path $operationRoot 'api-key.txt'))){throw 'SECRET_NOT_PRESENT_WHILE_RUNNING'}
    $cleanup=Stop-SqlServerLabOvmsHttpsGateway -OperationId $gateway.OperationId -Confirm:$false;$gateway=$null
    if($cleanup.Status -cne 'CLEANUP_SUCCEEDED'){throw 'CLEANUP_NOT_CONFIRMED'}
    if(Test-Path (Join-Path $operationRoot 'api-key.txt')){throw 'SECRET_REMAINS'}
    if(@(Get-NetTCPConnection -LocalPort $gatewayPort -State Listen -ErrorAction SilentlyContinue).Count){throw 'LISTENER_REMAINS'}
    [PSCustomObject]@{Status='PASS';GatewayPort=$gatewayPort;UpstreamPort=$upstreamPort;PlanBound=$true;EndpointVerified=$true;SecretRemoved=$true;ListenerRemoved=$true;BindingKeyLength=64}
}
finally {
    if($gateway){try{Stop-SqlServerLabOvmsHttpsGateway -OperationId $gateway.OperationId -Confirm:$false|Out-Null}catch{}}
    if($upstream){Stop-Job $upstream -ErrorAction SilentlyContinue;Remove-Job $upstream -Force -ErrorAction SilentlyContinue}
    if($cert){$cert.Dispose()};if($rsa){$rsa.Dispose()};if($ca){$ca.Dispose()};if($caRsa){$caRsa.Dispose()};if(Test-Path $fixture){Remove-Item -LiteralPath $fixture -Recurse -Force}
}
