param([Parameter(Mandatory)][string]$RequestPath)
$ErrorActionPreference='Stop'
$operationRoot=Split-Path -Parent $RequestPath
$request=Get-Content -LiteralPath $RequestPath -Raw|ConvertFrom-Json
$receiptPath=Join-Path $operationRoot 'receipt.json'
$listener=$null;$certificate=$null;$client=$null

function Write-Receipt([string]$Status,[string]$Code) {
    $record=[ordered]@{OperationId=$request.OperationId;Status=$Status;Code=$Code;ProcessId=$PID;StartedAtUtcTicks=(Get-Process -Id $PID).StartTime.ToUniversalTime().Ticks}
    $temporary=$receiptPath+'.tmp'
    [IO.File]::WriteAllText($temporary,($record|ConvertTo-Json -Compress))
    [IO.File]::Move($temporary,$receiptPath,$true)
}
function Write-HttpResponse([IO.Stream]$Stream,[int]$Status,[string]$Body) {
    $reason=if($Status -eq 200){'OK'}elseif($Status -eq 401){'Unauthorized'}elseif($Status -eq 404){'Not Found'}elseif($Status -eq 413){'Content Too Large'}elseif($Status -eq 502){'Bad Gateway'}else{'Bad Request'}
    $bytes=[Text.Encoding]::UTF8.GetBytes($Body)
    $header=[Text.Encoding]::ASCII.GetBytes("HTTP/1.1 $Status $reason`r`nContent-Type: application/json`r`nContent-Length: $($bytes.Length)`r`nConnection: close`r`nCache-Control: no-store`r`n`r`n")
    $Stream.Write($header,0,$header.Length);$Stream.Write($bytes,0,$bytes.Length);$Stream.Flush()
}
function Test-FixedSecret([string]$Actual,[string]$Expected) {
    $a=[Text.Encoding]::UTF8.GetBytes($Actual);$b=[Text.Encoding]::UTF8.GetBytes($Expected)
    try { return $a.Length -eq $b.Length -and [Security.Cryptography.CryptographicOperations]::FixedTimeEquals($a,$b) }
    finally {[Array]::Clear($a,0,$a.Length);[Array]::Clear($b,0,$b.Length)}
}
function Read-Exact([IO.Stream]$Stream,[int]$Length) {
    $buffer=[byte[]]::new($Length);$offset=0
    while($offset -lt $Length){$count=$Stream.Read($buffer,$offset,$Length-$offset);if($count -le 0){throw 'AI_OVMS_GATEWAY_REQUEST_TRUNCATED'};$offset+=$count}
    return $buffer
}
function Invoke-OneRequest([Net.Sockets.TcpClient]$TcpClient,[Security.Cryptography.X509Certificates.X509Certificate2]$Certificate) {
    $stream=[Net.Security.SslStream]::new($TcpClient.GetStream(),$false)
    $stage='TLS'
    try {
        $stream.ReadTimeout=15000;$stream.WriteTimeout=15000
        $stream.AuthenticateAsServer($Certificate,$false,[Security.Authentication.SslProtocols]::Tls12 -bor [Security.Authentication.SslProtocols]::Tls13,$false)
        $stage='HEADERS'
        $headerBytes=[Collections.Generic.List[byte]]::new();$match=0
        while($headerBytes.Count -lt 16384 -and $match -lt 4) {
            $value=$stream.ReadByte();if($value -lt 0){throw 'AI_OVMS_GATEWAY_REQUEST_TRUNCATED'}
            $headerBytes.Add([byte]$value)
            $expected=@(13,10,13,10)[$match]
            if($value -eq $expected){$match++}elseif($value -eq 13){$match=1}else{$match=0}
        }
        if($match -ne 4){Write-HttpResponse $stream 413 '{"error":"request_rejected"}';return}
        $lines=[Text.Encoding]::ASCII.GetString($headerBytes.ToArray()).Split(@("`r`n"),[StringSplitOptions]::None)
        if($lines[0] -cne 'POST /v3/embeddings HTTP/1.1'){Write-HttpResponse $stream 404 '{"error":"route_not_found"}';return}
        $headers=@{}
        foreach($line in $lines[1..($lines.Count-3)]) {
            $separator=$line.IndexOf(':');if($separator -le 0){Write-HttpResponse $stream 400 '{"error":"request_rejected"}';return}
            $name=$line.Substring(0,$separator).Trim().ToLowerInvariant();$value=$line.Substring($separator+1).Trim()
            if($headers.ContainsKey($name)){Write-HttpResponse $stream 400 '{"error":"request_rejected"}';return};$headers[$name]=$value
        }
        if($headers.ContainsKey('transfer-encoding') -or -not $headers.ContainsKey('content-length')){Write-HttpResponse $stream 400 '{"error":"request_rejected"}';return}
        $length=0;if(-not [int]::TryParse($headers['content-length'],[Globalization.NumberStyles]::None,[Globalization.CultureInfo]::InvariantCulture,[ref]$length) -or $length -lt 1 -or $length -gt 65536){Write-HttpResponse $stream 413 '{"error":"request_rejected"}';return}
        $key=[IO.File]::ReadAllText((Join-Path $operationRoot 'api-key.txt'))
        $stage='AUTH'
        if(-not $headers.ContainsKey('authorization') -or -not (Test-FixedSecret $headers['authorization'] ('Bearer '+$key))){Write-HttpResponse $stream 401 '{"error":"unauthorized"}';return}
        $body=[Text.Encoding]::UTF8.GetString((Read-Exact $stream $length))
        try {$upstreamBody=ConvertTo-LabAiOvmsGatewayUpstreamBody -Json $body -ExpectedModel $request.ModelName}catch{Write-HttpResponse $stream 400 '{"error":"request_rejected"}';return}
        $stage='UPSTREAM'
        $handler=[Net.Http.HttpClientHandler]::new();$handler.UseProxy=$false;$handler.AllowAutoRedirect=$false
        $http=[Net.Http.HttpClient]::new($handler);$http.Timeout=[TimeSpan]::FromSeconds(15)
        try {
            $content=[Net.Http.StringContent]::new($upstreamBody,[Text.Encoding]::UTF8,'application/json')
            $response=$http.PostAsync([string]$request.UpstreamLocation,$content).GetAwaiter().GetResult()
            $upstreamResponse=$response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            if(-not $response.IsSuccessStatusCode){Write-HttpResponse $stream 502 '{"error":"upstream_rejected"}';return}
            try {$safeBody=ConvertFrom-LabAiOvmsGatewayUpstreamResponse -Json $upstreamResponse -ExpectedModel $request.ModelName -Dimension ([int]$request.Dimension)}catch{Write-HttpResponse $stream 502 '{"error":"upstream_invalid"}';return}
            $stage='RESPONSE'
            Write-HttpResponse $stream 200 $safeBody
        }
        finally {if($content){$content.Dispose()};if($response){$response.Dispose()};$http.Dispose();$handler.Dispose()}
    }
    catch {$inner=$_.Exception.InnerException;if(-not $inner){$inner=$_.Exception};$detail=($inner.Message -replace '[\r\n]+',' ');if($detail.Length -gt 256){$detail=$detail.Substring(0,256)};[Console]::Error.WriteLine(('AI_OVMS_GATEWAY_REQUEST_FAILED:{0}:{1}:{2}:{3}' -f $stage,$inner.GetType().FullName,$inner.HResult,$detail));try{Write-HttpResponse $stream 400 '{"error":"request_rejected"}'}catch{}}
    finally {$stream.Dispose()}
}

try {
    if(-not $IsWindows){throw 'AI_OVMS_GATEWAY_WINDOWS_REQUIRED'}
    . (Join-Path (Split-Path -Parent $PSScriptRoot) 'Private/AiOvmsHttpsGateway.ps1')
    $pemCertificate=[Security.Cryptography.X509Certificates.X509Certificate2]::CreateFromPemFile([string]$request.CertificatePath,[string]$request.PrivateKeyPath)
    try {$pfxBytes=$pemCertificate.Export([Security.Cryptography.X509Certificates.X509ContentType]::Pkcs12);$certificate=[Security.Cryptography.X509Certificates.X509Certificate2]::new($pfxBytes,'',[Security.Cryptography.X509Certificates.X509KeyStorageFlags]::UserKeySet)}
    finally {$pemCertificate.Dispose();if($pfxBytes){[Array]::Clear($pfxBytes,0,$pfxBytes.Length)}}
    $listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,[int]$request.Port);$listener.Start(8)
    $stopBuffer=[byte[]]::new(1);$stopSignal=[Console]::OpenStandardInput().ReadAsync($stopBuffer,0,1)
    Write-Receipt 'RUNNING' 'LISTENER_READY'
    $watch=[Diagnostics.Stopwatch]::StartNew()
    while($watch.Elapsed.TotalSeconds -lt [int]$request.LeaseSeconds -and -not $stopSignal.IsCompleted) {
        $accept=$listener.AcceptTcpClientAsync()
        while(-not $accept.Wait(100)) {if($stopSignal.IsCompleted -or $watch.Elapsed.TotalSeconds -ge [int]$request.LeaseSeconds){break}}
        if($accept.IsCompletedSuccessfully){$client=$accept.Result;Invoke-OneRequest $client $certificate;$client.Dispose();$client=$null}
    }
    Write-Receipt 'STOPPED' $(if($stopSignal.IsCompleted){'OWNER_CLOSED'}else{'LEASE_EXPIRED'})
}
catch {[Console]::Error.WriteLine(('AI_OVMS_GATEWAY_WORKER_FAILED:{0}:{1}' -f $_.Exception.GetType().FullName,$_.Exception.HResult));Write-Receipt 'FAILED' 'AI_OVMS_GATEWAY_WORKER_FAILED'}
finally {if($client){$client.Dispose()};if($listener){$listener.Stop()};if($certificate){$certificate.Dispose()};$keyPath=Join-Path $operationRoot 'api-key.txt';if(Test-Path -LiteralPath $keyPath){Remove-Item -LiteralPath $keyPath -Force}}
