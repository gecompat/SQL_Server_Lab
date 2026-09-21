#Requires -Version 7.2
<#
.SYNOPSIS
    Flüchtiger Loopback-Gateway für die private SQL-HTTPS-Referenzabnahme.
.DESCRIPTION
    Konfiguration und Authentisierung ausschließlich über stdin. Drei eigene
    Listener erlauben unabhängige TLS-Handshakes für gültige CA, falsche CA und SAN.
    Keine Hosttrust-, Dienst-, Firewall- oder Modell-Lifecycleänderung.
#>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Root)
$ErrorActionPreference='Stop'
$module=$null;$certificates=[Collections.Generic.List[IDisposable]]::new();$servers=@();$receipt=$null;$failure=$false;$controlReader=$null
$readyPath=Join-Path $Root 'ready.json';$receiptPath=Join-Path $Root 'gateway.json'

function New-BridgeCertificate {
    param([string]$Name,$Issuer,[switch]$Authority)
    $rsa=[Security.Cryptography.RSA]::Create(2048);$certificates.Add($rsa)
    $request=[Security.Cryptography.X509Certificates.CertificateRequest]::new("CN=$Name",$rsa,[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $request.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new([bool]$Authority,$false,0,$true))
    $usage=if($Authority){[Security.Cryptography.X509Certificates.X509KeyUsageFlags]::KeyCertSign}else{[Security.Cryptography.X509Certificates.X509KeyUsageFlags]::DigitalSignature -bor [Security.Cryptography.X509Certificates.X509KeyUsageFlags]::KeyEncipherment}
    $request.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509KeyUsageExtension]::new($usage,$true))
    if(-not $Authority){
        $oids=[Security.Cryptography.OidCollection]::new();$null=$oids.Add([Security.Cryptography.Oid]::new('1.3.6.1.5.5.7.3.1'))
        $request.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]::new($oids,$true))
        $san=[Security.Cryptography.X509Certificates.SubjectAlternativeNameBuilder]::new();$san.AddDnsName($Name);$request.CertificateExtensions.Add($san.Build())
    }
    if($Authority){$generated=$request.CreateSelfSigned([DateTimeOffset]::UtcNow.AddMinutes(-5),[DateTimeOffset]::UtcNow.AddHours(1))}
    else{
        $serial=[Security.Cryptography.RandomNumberGenerator]::GetBytes(16);$serial[0]=$serial[0] -band 127
        $signed=$request.Create($Issuer,[DateTimeOffset]::UtcNow.AddMinutes(-1),[DateTimeOffset]::UtcNow.AddMinutes(45),$serial)
        try{$generated=[Security.Cryptography.X509Certificates.RSACertificateExtensions]::CopyWithPrivateKey($signed,$rsa)}finally{$signed.Dispose()}
    }
    # Wie beim bestehenden TLS-Stub: temporärer Benutzerschlüssel für Windows SslStream.
    $pfx=$null
    try{
        $pfx=$generated.Export([Security.Cryptography.X509Certificates.X509ContentType]::Pfx,[string]::Empty)
        $result=[Security.Cryptography.X509Certificates.X509Certificate2]::new($pfx,[string]::Empty,[Security.Cryptography.X509Certificates.X509KeyStorageFlags]::DefaultKeySet)
    }finally{$generated.Dispose();if($pfx){[Array]::Clear($pfx,0,$pfx.Length)}}
    $certificates.Add($result);return $result
}

function Save-BridgeReceipt {
    & $module {param($Path,$Value)
        Assert-LabAiPersistentPath $Path
        if(-not($Value|ConvertTo-Json -Depth 8|Test-Json -SchemaFile (Join-Path $script:SchemasPath 'ai-sql-https-bridge-receipt.schema.json') -ErrorAction Stop)){throw 'AI_SQL_HTTPS_RECEIPT_INVALID'}
        Write-LabArtifactJsonAtomic -Path $Path -InputObject $Value
    } $receiptPath $receipt
}

try{
    $module=Import-Module (Join-Path $PSScriptRoot '../../../SqlServerLab.psd1') -Force -PassThru
    & $module {param($Root)Assert-LabAiPersistentPath $Root} $Root
    if(-not(Test-Path -LiteralPath $Root -PathType Container) -or (Test-Path -LiteralPath $readyPath) -or (Test-Path -LiteralPath $receiptPath)){throw 'AI_SQL_HTTPS_ROOT_INVALID'}
    # Console.In synchronisiert auch ReadLineAsync und würde bis STOP den Listener blockieren.
    # Derselbe StreamReader behält gepufferte Bytes zwischen Konfiguration und Stoppsignal.
    $controlReader=[IO.StreamReader]::new([Console]::OpenStandardInput(),[Console]::InputEncoding)
    $configuration=[Text.StringBuilder]::new()
    while($configuration.Length -lt 8192){$value=$controlReader.Read();if($value -eq 10){break};if($value -lt 0){throw 'AI_SQL_HTTPS_CONFIG_INVALID'};$null=$configuration.Append([char]$value)}
    if($configuration.Length -ge 8192){throw 'AI_SQL_HTTPS_CONFIG_INVALID'}
    $config=$configuration.ToString()|ConvertFrom-Json -Depth 8;$configuration.Clear()|Out-Null
    if($config.Token -cnotmatch '^[a-f0-9]{64}$' -or ([guid]$config.OperationId).ToString('D') -cne $config.OperationId -or $config.LocalPort -lt 1024 -or $config.LocalPort -gt 65535){throw 'AI_SQL_HTTPS_CONFIG_INVALID'}
    $parent=Get-Process -Id $config.ParentPid -ErrorAction Stop
    if($parent.StartTime.ToUniversalTime().Ticks -ne $config.ParentStartTicks){throw 'AI_SQL_HTTPS_PARENT_INVALID'}
    $receipt=[ordered]@{contract='SqlServerLab.AiSqlHttpsBridgeReceipt/1.1';operationId=$config.OperationId;status='STARTING';connections=0;negativeTlsConnections=0;tlsRejected=0;closedBeforeHttp=0;requests=0;rejected=0;upstreamRequests=0;successfulEmbeddings=0;modelBindingHash=$null;caSha256=$null;failure=$null}
    Save-BridgeReceipt
    $plan=& $module {param($Port)New-LabAiEndpointPlan -ModelKey ollama-embeddinggemma-latest -EndpointRef ollama-local -Lane local -LocalPort $Port -RetryCount 0 -TimeoutSeconds 16} $config.LocalPort
    $receipt.modelBindingHash=& $module {param($Binding)Get-LabAiPlanKey $Binding} $config.Binding
    $ca=New-BridgeCertificate -Name SqlLabBridgeRoot -Authority
    $wrongCa=New-BridgeCertificate -Name SqlLabWrongRoot -Authority
    $public=$ca.Export([Security.Cryptography.X509Certificates.X509ContentType]::Cert)
    $receipt.caSha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($public)).ToLowerInvariant()
    $certs=@{Good=(New-BridgeCertificate -Name host.docker.internal -Issuer $ca);WrongSan=(New-BridgeCertificate -Name invalid.example -Issuer $ca);WrongCa=(New-BridgeCertificate -Name host.docker.internal -Issuer $wrongCa)}
    foreach($kind in @('Good','WrongSan','WrongCa')){
        $listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0);$listener.Start(1)
        $servers+=,[pscustomobject]@{Kind=$kind;Listener=$listener;Certificate=$certs[$kind];Accept=$listener.AcceptTcpClientAsync()}
    }
    $ports=@{};foreach($server in $servers){$ports[$server.Kind]=$server.Listener.LocalEndpoint.Port}
    $receipt.status='ACTIVE';Save-BridgeReceipt
    & $module {param($Path,$Value)Write-LabArtifactJsonAtomic -Path $Path -InputObject $Value} $readyPath @{OperationId=$config.OperationId;ProcessId=$PID;StartTicks=(Get-Process -Id $PID).StartTime.ToUniversalTime().Ticks;Ports=$ports;CaBase64=[Convert]::ToBase64String($public);CaSha256=$receipt.caSha256}
    $stop=$controlReader.ReadLineAsync();$deadline=[DateTime]::UtcNow.AddMinutes(15)
    while([DateTime]::UtcNow -lt $deadline -and -not $stop.IsCompleted){
        $parent.Refresh();if($parent.HasExited){break}
        $pending=@($servers|Where-Object {$_.Accept.IsCompleted}|Select-Object -First 1)
        if(-not $pending.Count){Start-Sleep -Milliseconds 25;continue}
        $server=$pending[0];$peer=$server.Accept.GetAwaiter().GetResult();$ssl=$null;$authenticated=$false
        $progress=@{HeaderBytes=0;HttpRequest=$false};$requestCounted=$false
        try{
            $receipt.connections++;if($receipt.connections -gt 20){throw 'AI_SQL_HTTPS_CONNECTION_BUDGET'}
            if($server.Kind -cne 'Good'){$receipt.negativeTlsConnections++}
            $peer.ReceiveTimeout=5000;$peer.SendTimeout=5000
            $ssl=[Net.Security.SslStream]::new($peer.GetStream(),$false);$ssl.ReadTimeout=5000;$ssl.WriteTimeout=5000
            $options=[Net.Security.SslServerAuthenticationOptions]::new();$options.ServerCertificate=$server.Certificate;$options.EnabledSslProtocols=[Security.Authentication.SslProtocols]::Tls12 -bor [Security.Authentication.SslProtocols]::Tls13
            $cancel=[Threading.CancellationTokenSource]::new(5000)
            try{$ssl.AuthenticateAsServerAsync($options,$cancel.Token).GetAwaiter().GetResult();$authenticated=$true}finally{$cancel.Dispose()}
            $text=& $module {param($Stream,$Token,$Progress)Read-LabAiSqlHttpsRequest -Stream $Stream -Token $Token -Progress $Progress} $ssl $config.Token $progress
            $receipt.requests++;$requestCounted=$true
            if($server.Kind -cne 'Good'){throw 'AI_SQL_HTTPS_NEGATIVE_CERT_ACCEPTED'}
            if($receipt.upstreamRequests -ge 8){throw 'AI_SQL_HTTPS_REQUEST_BUDGET'}
            # Der Zähler erfasst versuchte Embeddings, auch wenn die Bindungsprüfung blockiert.
            $receipt.upstreamRequests++;Save-BridgeReceipt
            $body=& $module {param($Plan,$Binding,$Text)Invoke-LabAiSqlHttpsEmbedding -Plan $Plan -Expected $Binding -InputText $Text} $plan $config.Binding $text
            & $module {param($Stream,$Body)Write-LabAiSqlHttpsResponse -Stream $Stream -StatusCode 200 -Body $Body} $ssl $body
            $receipt.successfulEmbeddings++
        }catch{
            if(-not $authenticated){$receipt.tlsRejected++}
            elseif($progress.HeaderBytes -gt 0){
                $receipt.rejected++
                $code=if($_.Exception.Message -ceq 'AI_SQL_HTTPS_AUTH_FAILED'){401}else{400}
                try{& $module {param($Stream,$Code)Write-LabAiSqlHttpsResponse -Stream $Stream -StatusCode $Code -Body '{"error":"REQUEST_REJECTED"}'} $ssl $code}catch{}
            }
        }finally{
            if($progress.HttpRequest -and -not $requestCounted){$receipt.requests++}
            if($ssl){$ssl.Dispose()};$peer.Dispose()
            # Lokale Beobachtung: geschlossen ohne Anwendungsbytes, keine behauptete Zertifikatsursache.
            if($progress.HeaderBytes -eq 0){$receipt.closedBeforeHttp++}
            Save-BridgeReceipt;$server.Accept=$server.Listener.AcceptTcpClientAsync()
        }
        if($receipt.connections -ge 20){break}
    }
    $receipt.status='STOPPED'
}catch{$failure=$true;if($receipt){$receipt.status='FAILED';$receipt.failure='AI_SQL_HTTPS_GATEWAY_FAILED'}}
finally{
    foreach($server in $servers){$server.Listener.Stop()}
    foreach($certificate in $certificates){$certificate.Dispose()}
    if($controlReader){$controlReader.Dispose()}
    if($receipt){try{Save-BridgeReceipt}catch{$failure=$true}}
    if($config){$config.Token=$null};if($module){Remove-Module $module -Force}
}
if($failure){exit 1}
