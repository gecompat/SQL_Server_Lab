#Requires -Version 7.2
[CmdletBinding()]param()
$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$module=Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru
$root=Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-ai-bridge-check-'+[guid]::NewGuid().ToString('N'))
$bridge=$null;$cleanupSafe=$true
function Wait-BridgeCounters {
    param([int]$Connections,[int]$Requests,[int]$Rejected,[int]$TlsRejected=-1,[int]$ClosedBeforeHttp=-1)
    $deadline=[DateTime]::UtcNow.AddSeconds(6)
    do {
        $observed=Get-Content -LiteralPath (Join-Path $bridge.Root 'gateway.json') -Raw|ConvertFrom-Json
        if($observed.status -ceq 'ACTIVE' -and $observed.connections -eq $Connections -and $observed.requests -eq $Requests -and
            $observed.rejected -eq $Rejected -and ($TlsRejected -lt 0 -or $observed.tlsRejected -eq $TlsRejected) -and
            ($ClosedBeforeHttp -lt 0 -or $observed.closedBeforeHttp -eq $ClosedBeforeHttp) -and $observed.upstreamRequests -eq 0){return}
        Start-Sleep -Milliseconds 25
    }while([DateTime]::UtcNow -lt $deadline)
    throw 'GATEWAY_BEFORE_STOP_PROGRESS_FAILED'
}
function Invoke-BridgeTlsProbe {
    param($Certificate,[string]$Kind='Good',[Security.Authentication.SslProtocols]$Protocol,[switch]$CloseBeforeHttp)
    $probe=[Net.Sockets.TcpClient]::new();$ssl=$null;$reader=$null
    try{
        $probe.ConnectAsync([Net.IPAddress]::Loopback,[int]$bridge.Ready.Ports.$Kind).WaitAsync([TimeSpan]::FromSeconds(3)).GetAwaiter().GetResult()
        $ssl=[Net.Security.SslStream]::new($probe.GetStream(),$false)
        $options=[Net.Security.SslClientAuthenticationOptions]::new();$options.TargetHost='host.docker.internal';$options.EnabledSslProtocols=$Protocol
        $options.CertificateChainPolicy=[Security.Cryptography.X509Certificates.X509ChainPolicy]::new()
        $options.CertificateChainPolicy.TrustMode=[Security.Cryptography.X509Certificates.X509ChainTrustMode]::CustomRootTrust
        $options.CertificateChainPolicy.CustomTrustStore.Add($Certificate)
        $options.CertificateChainPolicy.RevocationMode=[Security.Cryptography.X509Certificates.X509RevocationMode]::NoCheck
        $cancel=[Threading.CancellationTokenSource]::new(5000);$authRejected=$false
        try{$ssl.AuthenticateAsClientAsync($options,$cancel.Token).GetAwaiter().GetResult()}
        catch{
            $failure=$_.Exception
            while($failure){if($failure -is [Security.Authentication.AuthenticationException]){$authRejected=$true};$failure=$failure.InnerException}
            if(-not $authRejected){throw 'TLS_PROBE_UNEXPECTED_FAILURE'}
        }finally{$cancel.Dispose()}
        if($Kind -cne 'Good'){if(-not $authRejected){throw 'NEGATIVE_CERTIFICATE_ACCEPTED'};return}
        if($authRejected -or $ssl.SslProtocol -ne $Protocol){throw 'POSITIVE_TLS_PROTOCOL_FAILED'}
        if($CloseBeforeHttp){return}
        $ssl.WriteTimeout=3000
        $wire=[Text.Encoding]::ASCII.GetBytes("POST /api/embed HTTP/1.1`r`nHost: host.docker.internal`r`nContent-Type: application/json`r`nContent-Length: 2`r`n`r`n{}")
        $ssl.Write($wire,0,$wire.Length);$ssl.Flush()
        $reader=[IO.StreamReader]::new($ssl)
        $response=$reader.ReadToEndAsync().WaitAsync([TimeSpan]::FromSeconds(5)).GetAwaiter().GetResult()
        if(-not $response.StartsWith("HTTP/1.1 401 Result`r`n",[StringComparison]::Ordinal)){throw 'LIVE_AUTH_REJECTION_FAILED'}
    }finally{if($reader){$reader.Dispose()};if($ssl){$ssl.Dispose()};$probe.Dispose()}
}
try{
    $checks=& $module {
        $checks=[Collections.Generic.List[object]]::new()
        function Check {param($Name,$Success)$checks.Add([pscustomobject]@{Name=$Name;Success=[bool]$Success})}
        function Reject {param([scriptblock]$Action,[string]$Code)try{& $Action|Out-Null;$false}catch{$_.Exception.Message -match $Code}}
        $token='a'*64;$fixture=Get-LabAiSqlHttpsFixture
        function Read-Wire {
            param([string]$Body,[string]$Headers="X-SqlLab-Token: $token`r`n",[string]$RequestLine='POST /api/embed HTTP/1.1',[hashtable]$Progress=@{})
            $bytes=[Text.Encoding]::UTF8.GetBytes($Body)
            $header=[Text.Encoding]::ASCII.GetBytes("$RequestLine`r`n${Headers}Content-Type: application/json`r`nContent-Length: $($bytes.Length)`r`n`r`n")
            $stream=[IO.MemoryStream]::new();$stream.Write($header,0,$header.Length);$stream.Write($bytes,0,$bytes.Length);$stream.Position=0
            try{Read-LabAiSqlHttpsRequest -Stream $stream -Token $token -Progress $Progress}finally{$stream.Dispose()}
        }
        $body=@{model='embeddinggemma:latest';input=@($fixture.Documents[0].Content)}|ConvertTo-Json -Compress
        Check 'Einzelarray aus SQL wird exakt aufgelöst' ((Read-Wire $body) -ceq $fixture.Documents[0].Content)
        $scalar=@{model='embeddinggemma:latest';input=$fixture.Questions[0].Content}|ConvertTo-Json -Compress
        Check 'Skalarer Input erhält dieselbe Fixturegrenze' ((Read-Wire $scalar) -ceq $fixture.Questions[0].Content)
        Check 'Fehlende Authentisierung blockiert' (Reject {Read-Wire $body -Headers ''} 'AUTH_FAILED')
        Check 'Abweichende Authentisierung blockiert' (Reject {Read-Wire $body -Headers "X-SqlLab-Token: other`r`n"} 'AUTH_FAILED')
        Check 'Doppelter Authheader blockiert' (Reject {Read-Wire $body -Headers "X-SqlLab-Token: $token`r`nx-sqllab-token: $token`r`n"} 'REQUEST_INVALID')
        Check 'GET blockiert' (Reject {Read-Wire $body -RequestLine 'GET /api/embed HTTP/1.1'} 'REQUEST_INVALID')
        Check 'Andere Route blockiert' (Reject {Read-Wire $body -RequestLine 'POST /api/generate HTTP/1.1'} 'REQUEST_INVALID')
        Check 'Absolute Request-URL blockiert' (Reject {Read-Wire $body -RequestLine 'POST https://remote.example/api/embed HTTP/1.1'} 'REQUEST_INVALID')
        Check 'Chunked Encoding blockiert' (Reject {Read-Wire $body -Headers "X-SqlLab-Token: $token`r`nTransfer-Encoding: chunked`r`n"} 'REQUEST_INVALID')
        Check 'Doppelte Content-Length blockiert' (Reject {Read-Wire $body -Headers "X-SqlLab-Token: $token`r`nContent-Length: 1`r`n"} 'REQUEST_INVALID')
        Check 'Expect blockiert' (Reject {Read-Wire $body -Headers "X-SqlLab-Token: $token`r`nExpect: 100-continue`r`n"} 'REQUEST_INVALID')
        Check 'Freier Text blockiert' (Reject {Read-Wire '{"model":"embeddinggemma:latest","input":"not in fixture"}'} 'PAYLOAD_INVALID')
        Check 'Anderes Modell blockiert' (Reject {Read-Wire '{"model":"remote:cloud","input":"none"}'} 'PAYLOAD_INVALID')
        Check 'Zusätzliche Optionen blockieren' (Reject {Read-Wire '{"model":"embeddinggemma:latest","input":"none","options":{}}'} 'PAYLOAD_INVALID')
        Check 'Doppelte JSON-Property blockiert' (Reject {Read-Wire '{"model":"other","model":"embeddinggemma:latest","input":"none"}'} 'PAYLOAD_INVALID')
        Check 'Übergroßer Body blockiert' (Reject {Read-Wire ('x'*4097)} 'REQUEST_INVALID')
        $vector=@(1..768|ForEach-Object {0.01})
        Check 'Endliche 768 Dimensionen akzeptiert' ((ConvertTo-LabAiSqlHttpsResponse @{embeddings=@(,$vector)}|ConvertFrom-Json).embeddings[0].Count -eq 768)
        Check 'Fehlende Dimension blockiert' (Reject {ConvertTo-LabAiSqlHttpsResponse @{embeddings=@(,@(1..767))}} 'RESPONSE_INVALID')
        Check 'Mehrere Vektoren blockieren' (Reject {ConvertTo-LabAiSqlHttpsResponse @{embeddings=@($vector,$vector)}} 'RESPONSE_INVALID')
        $bad=$vector.Clone();$bad[4]=[double]::NaN
        Check 'NaN blockiert' (Reject {ConvertTo-LabAiSqlHttpsResponse @{embeddings=@(,$bad)}} 'RESPONSE_INVALID')
        $bad=$vector.Clone();$bad[4]=[double]::PositiveInfinity
        Check 'Unendlichkeit blockiert' (Reject {ConvertTo-LabAiSqlHttpsResponse @{embeddings=@(,$bad)}} 'RESPONSE_INVALID')
        $bad=$vector.Clone();$bad[4]='0.1'
        Check 'Numerischer String blockiert' (Reject {ConvertTo-LabAiSqlHttpsResponse @{embeddings=@(,$bad)}} 'RESPONSE_INVALID')
        Check 'Abweichende Response-Modellidentität blockiert' (Reject {ConvertTo-LabAiSqlHttpsResponse @{model='other';embeddings=@(,$vector)}} 'RESPONSE_INVALID')
        $plan=New-LabAiEndpointPlan -ModelKey ollama-embeddinggemma-latest -EndpointRef ollama-local -Lane local -LocalPort 11434
        $binding=[pscustomobject]@{ModelKey='ollama-embeddinggemma-latest';Model='embeddinggemma:latest';Digest='a'*64;Version='0.34.2';Dimension=768}
        $script:requests=[Collections.Generic.List[string]]::new();$script:drift=$false;$script:remote=$false;$script:driftAfter=$false
        $transport={param($Path,$Body,$Timeout)
            $script:requests.Add($Path)
            if($Timeout -le 0 -or $Timeout -gt 16000){throw 'timeout'}
            switch($Path){
                /api/version {@{version='0.34.2'}}
                /api/tags {@{models=@([pscustomobject]@{name='embeddinggemma:latest';digest=$(if($script:drift){'b'*64}else{'a'*64});remote_host=$(if($script:remote){'remote.example'}else{''})})}}
                /api/show {@{capabilities=@('embedding');model_info=[pscustomobject]@{'gemma.embedding_length'=768}}}
                /api/embed {if($script:driftAfter){$script:drift=$true};@{model='embeddinggemma:latest';embeddings=@(,@(1..768|ForEach-Object {0.01}))}}
            }
        }
        $null=Invoke-LabAiSqlHttpsEmbedding -Plan $plan -Expected $binding -InputText $fixture.Documents[0].Content -HttpTransport $transport
        Check 'Ein Payload zwischen zwei vollständigen Bindungsprüfungen' (($script:requests -join ',') -ceq '/api/version,/api/tags,/api/show,/api/embed,/api/version,/api/tags,/api/show')
        $script:requests.Clear();$script:drift=$true
        Check 'Digestdrift blockiert vor Payload' ((Reject {Invoke-LabAiSqlHttpsEmbedding -Plan $plan -Expected $binding -InputText $fixture.Documents[0].Content -HttpTransport $transport} 'MODEL_DRIFT') -and $script:requests -cnotcontains '/api/embed')
        $script:requests.Clear();$script:drift=$false;$script:driftAfter=$true
        Check 'Digestdrift nach Payload blockiert Response' (Reject {Invoke-LabAiSqlHttpsEmbedding -Plan $plan -Expected $binding -InputText $fixture.Documents[0].Content -HttpTransport $transport} 'MODEL_DRIFT')
        $script:requests.Clear();$script:drift=$false;$script:driftAfter=$false;$script:remote=$true
        Check 'Remote-Modell blockiert vor Payload' ((Reject {Invoke-LabAiSqlHttpsEmbedding -Plan $plan -Expected $binding -InputText $fixture.Documents[0].Content -HttpTransport $transport} 'REMOTE_MODEL_FORBIDDEN') -and $script:requests -cnotcontains '/api/embed')
        $script:requests.Clear()
        Check 'Freier Input blockiert selbst vor Metadaten' ((Reject {Invoke-LabAiSqlHttpsEmbedding -Plan $plan -Expected $binding -InputText arbitrary -HttpTransport $transport} 'PAYLOAD_INVALID') -and $script:requests.Count -eq 0)
        Check 'Freier Upstreampfad blockiert vor Netzwerk' (Reject {Invoke-LabAiSqlHttpsHttp -Port 11434 -Path /api/generate -TimeoutMilliseconds 1000} 'UPSTREAM_INVALID')
        Check 'Nullbudget blockiert vor Netzwerk' (Reject {Invoke-LabAiSqlHttpsHttp -Port 11434 -Path /api/embed -TimeoutMilliseconds 0} 'UPSTREAM_INVALID')
        $progress=@{}
        $rejected=Reject {Read-Wire $body -Headers '' -Progress $progress} 'AUTH_FAILED'
        Check 'Authnegative zählt empfangenen HTTP-Header' ($rejected -and $progress.HttpRequest -and $progress.HeaderBytes -gt 0)
        foreach($prefix in @('','P')){
            $stream=[IO.MemoryStream]::new([Text.Encoding]::ASCII.GetBytes($prefix));$progress=@{}
            try{$rejected=Reject {Read-LabAiSqlHttpsRequest -Stream $stream -Token $token -Progress $progress} 'REQUEST_INVALID'}finally{$stream.Dispose()}
            Check ('Unvollständiger Header bleibt ohne HTTP-Request: '+$prefix.Length) ($rejected -and -not $progress.HttpRequest -and $progress.HeaderBytes -eq $prefix.Length)
        }
        return @($checks)
    }
    foreach($check in $checks){Write-Host "$(if($check.Success){'PASS'}else{'FAIL'}): $($check.Name)"}
    if(@($checks|Where-Object {-not $_.Success}).Count){throw 'AI_SQL_HTTPS_CHECKS_FAILED'}
    $listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0);$client=$null;$peer=$null
    try{
        $listener.Start(1);$accept=$listener.AcceptTcpClientAsync();$client=[Net.Sockets.TcpClient]::new();$client.Connect([Net.IPAddress]::Loopback,$listener.LocalEndpoint.Port);$peer=$accept.GetAwaiter().GetResult()
        $client.GetStream().WriteByte(80)
        $timer=[Diagnostics.Stopwatch]::StartNew();$timedOut=$false
        try{& $module {param($Stream)Read-LabAiSqlHttpsRequest -Stream $Stream -Token ('a'*64)} $peer.GetStream()|Out-Null}catch{$timedOut=$true}
        if(-not $timedOut -or $timer.Elapsed.TotalSeconds -lt 4.5 -or $timer.Elapsed.TotalSeconds -gt 10){throw 'REAL_REQUEST_DEADLINE_FAILED'}
        Write-Host 'PASS: Echter langsamer eigener Loopback-Read endet am gemeinsamen 5s-Budget'
    }finally{if($peer){$peer.Dispose()};if($client){$client.Dispose()};$listener.Stop()}
    # Echter eigener Zertifikat-/Prozesszyklus ohne SQL oder Modellaufruf.
    $null=New-Item -ItemType Directory -Path $root
    $cleanupSafe=$false
    try{$bridge=& $module {param($Root)Start-LabAiSqlHttpsBridge -Root $Root -OperationId ([guid]::NewGuid().ToString('D')) -Token ('a'*64) -Binding @{ModelKey='ollama-embeddinggemma-latest';Model='embeddinggemma:latest';Digest=('a'*64);Version='0.34.2';Dimension=768} -LocalPort 11434} $root;$cleanupSafe=$true}
    catch{if($_.Exception.Message -ceq 'AI_SQL_HTTPS_GATEWAY_START_FAILED_CLEANED'){$cleanupSafe=$true};throw}
    $certificate=[Security.Cryptography.X509Certificates.X509Certificate2]::new([Convert]::FromBase64String($bridge.Ready.CaBase64))
    try{
        if($certificate.HasPrivateKey){throw 'PRIVATE_KEY_EXPOSED'}
        # Der Server muss schon vor STOP arbeiten; bloßes Start/Stop findet blockierendes stdin nicht.
        $probe=[Net.Sockets.TcpClient]::new()
        try{$probe.ConnectAsync([Net.IPAddress]::Loopback,[int]$bridge.Ready.Ports.Good).WaitAsync([TimeSpan]::FromSeconds(3)).GetAwaiter().GetResult()}finally{$probe.Dispose()}
        Wait-BridgeCounters -Connections 1 -Requests 0 -Rejected 0 -TlsRejected 1 -ClosedBeforeHttp 1
        Write-Host 'PASS: Gateway verarbeitet TCP-Abbruch vor STOP ohne Upstreamrequest'
        $probe=[Net.Sockets.TcpClient]::new();$ssl=$null;$reader=$null
        try{
            $probe.ConnectAsync([Net.IPAddress]::Loopback,[int]$bridge.Ready.Ports.Good).WaitAsync([TimeSpan]::FromSeconds(3)).GetAwaiter().GetResult()
            $ssl=[Net.Security.SslStream]::new($probe.GetStream(),$false)
            $options=[Net.Security.SslClientAuthenticationOptions]::new();$options.TargetHost='host.docker.internal'
            $options.CertificateChainPolicy=[Security.Cryptography.X509Certificates.X509ChainPolicy]::new()
            $options.CertificateChainPolicy.TrustMode=[Security.Cryptography.X509Certificates.X509ChainTrustMode]::CustomRootTrust
            $options.CertificateChainPolicy.CustomTrustStore.Add($certificate)
            $options.CertificateChainPolicy.RevocationMode=[Security.Cryptography.X509Certificates.X509RevocationMode]::NoCheck
            $cancel=[Threading.CancellationTokenSource]::new(5000)
            try{$ssl.AuthenticateAsClientAsync($options,$cancel.Token).GetAwaiter().GetResult()}finally{$cancel.Dispose()}
            $ssl.WriteTimeout=3000
            $wire=[Text.Encoding]::ASCII.GetBytes("POST /api/embed HTTP/1.1`r`nHost: host.docker.internal`r`nContent-Type: application/json`r`nContent-Length: 2`r`n`r`n{}")
            $ssl.Write($wire,0,$wire.Length);$ssl.Flush()
            $reader=[IO.StreamReader]::new($ssl)
            $response=$reader.ReadToEndAsync().WaitAsync([TimeSpan]::FromSeconds(5)).GetAwaiter().GetResult()
            if(-not $response.StartsWith("HTTP/1.1 401 Result`r`n",[StringComparison]::Ordinal)){throw 'LIVE_AUTH_REJECTION_FAILED'}
        }finally{if($reader){$reader.Dispose()};if($ssl){$ssl.Dispose()};$probe.Dispose()}
        Wait-BridgeCounters -Connections 2 -Requests 1 -Rejected 1 -TlsRejected 1 -ClosedBeforeHttp 1
        Write-Host 'PASS: Eigene CA und SAN validiert; Live-TLS-Authnegative antwortet vor STOP ohne Upstreamrequest'
        $connectionCount=2;$requestCount=1;$closedCount=1
        foreach($protocol in @([Security.Authentication.SslProtocols]::Tls12,[Security.Authentication.SslProtocols]::Tls13)){
            Invoke-BridgeTlsProbe -Certificate $certificate -Protocol $protocol
            $connectionCount++;$requestCount++
            Wait-BridgeCounters -Connections $connectionCount -Requests $requestCount -Rejected $requestCount -ClosedBeforeHttp $closedCount
            Write-Host "PASS: $protocol positive CA und SAN validiert; HTTP-Authnegative ohne Upstream"
            foreach($kind in @('WrongCa','WrongSan')){
                Invoke-BridgeTlsProbe -Certificate $certificate -Protocol $protocol -Kind $kind
                $connectionCount++;$closedCount++
                Wait-BridgeCounters -Connections $connectionCount -Requests $requestCount -Rejected $requestCount -ClosedBeforeHttp $closedCount
                Write-Host "PASS: $protocol $kind clientseitig strikt abgewiesen ohne HTTP oder Upstream"
            }
            Invoke-BridgeTlsProbe -Certificate $certificate -Protocol $protocol -CloseBeforeHttp
            $connectionCount++;$closedCount++
            Wait-BridgeCounters -Connections $connectionCount -Requests $requestCount -Rejected $requestCount -ClosedBeforeHttp $closedCount
            Write-Host "PASS: $protocol gültige TLS-Verbindung ohne HTTP erzeugt keinen Request"
        }
    }finally{$certificate.Dispose()}
    $receipt=& $module {param($Bridge)Stop-LabAiSqlHttpsBridge $Bridge} $bridge;$bridge=$null
    if($receipt.upstreamRequests -ne 0 -or $receipt.connections -ne 10 -or $receipt.requests -ne 3 -or $receipt.closedBeforeHttp -ne 7 -or $receipt.negativeTlsConnections -ne 4 -or $receipt.status -cne 'STOPPED'){throw 'OFFLINE_PROCESS_LIFECYCLE_INVALID'}
    Write-Host 'PASS: Eigener Gateway-Zertifikat-/Prozesszyklus; kein privater CA-Key im Readyrecord, keine Modellrequests'
    $eofRoot=Join-Path $root 'eof';$null=New-Item -ItemType Directory -Path $eofRoot;$cleanupSafe=$false
    try{$bridge=& $module {param($Root)Start-LabAiSqlHttpsBridge -Root $Root -OperationId ([guid]::NewGuid().ToString('D')) -Token ('a'*64) -Binding @{} -LocalPort 11434} $eofRoot;$cleanupSafe=$true}
    catch{if($_.Exception.Message -ceq 'AI_SQL_HTTPS_GATEWAY_START_FAILED_CLEANED'){$cleanupSafe=$true};throw}
    $bridge.Process.StandardInput.Close()
    if(-not $bridge.Process.WaitForExit(5000)){throw 'GATEWAY_EOF_STOP_FAILED'}
    $receipt=& $module {param($Bridge)Stop-LabAiSqlHttpsBridge $Bridge} $bridge;$bridge=$null
    if($receipt.connections -ne 0 -or $receipt.upstreamRequests -ne 0 -or $receipt.status -cne 'STOPPED'){throw 'GATEWAY_EOF_RECEIPT_INVALID'}
    Write-Host 'PASS: EOF beendet eigenen Gateway kooperativ ohne Requests'
    $faultRoot=Join-Path $root 'start-fault';$null=New-Item -ItemType Directory -Path $faultRoot;$cleanupSafe=$false
    $fault=& $module {
        param($Root)
        $script:faultPid=$null;$caught=$null
        try{Start-LabAiSqlHttpsBridge -Root $Root -OperationId ([guid]::NewGuid().ToString('D')) -Token ('a'*64) -Binding @{} -LocalPort 11434 -FaultInjector {param($ChildId)$script:faultPid=$ChildId;throw 'synthetic start failure'}|Out-Null}catch{$caught=$_.Exception.Message}
        $record=Get-Content -LiteralPath (Join-Path $Root 'process.json') -Raw|ConvertFrom-Json
        [pscustomobject]@{Confirmed=($caught -ceq 'AI_SQL_HTTPS_GATEWAY_START_FAILED_CLEANED');Reached=($script:faultPid -gt 0);Stopped=($record.Status -ceq 'STOPPED' -and $record.ProcessId -eq $script:faultPid -and -not(Get-Process -Id $script:faultPid -ErrorAction SilentlyContinue))}
    } $faultRoot
    if($fault.Confirmed -and $fault.Stopped){$cleanupSafe=$true}
    if(-not $cleanupSafe -or -not $fault.Reached){throw 'DYNAMIC_START_FAILURE_CLEANUP_FAILED'}
    Write-Host 'PASS: Injizierter Fehler nach realem Prozessstart bestätigt Exit und STOPPED vor Dateicleanup'
    Write-Host "AI SQL HTTPS BRIDGE CHECKS: PASS ($($checks.Count+14) assertions)"
}finally{
    if($bridge){& $module {param($Bridge)Stop-LabAiSqlHttpsBridge $Bridge} $bridge|Out-Null}
    if($cleanupSafe -and (Test-Path -LiteralPath $root)){$resolved=[IO.Path]::GetFullPath($root);$boundary=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar;if(-not $resolved.StartsWith($boundary,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notlike 'sql-lab-ai-bridge-check-*'){throw 'TEST_CLEANUP_SCOPE_INVALID'};Remove-Item -LiteralPath $resolved -Recurse -Force}
    Remove-Module $module -Force
}
