param([Parameter(Mandatory)][string]$RequestPath)
$ErrorActionPreference='Stop'
$operationRoot=Split-Path -Parent $RequestPath
$receiptPath=Join-Path $operationRoot 'receipt.json'
$request=$null;$listener=$null;$client=$null;$certificate=$null;$consumerSecrets=@();$upstreamSecret=$null

function Write-SessionReceipt([string]$Status,[string]$Code) {
    $record=[ordered]@{OperationId=[string]$request.OperationId;OwnerNonce=[string]$request.OwnerNonce;Status=$Status;Code=$Code;ProcessId=$PID}
    $temporary=$receiptPath+'.tmp';[IO.File]::WriteAllText($temporary,($record|ConvertTo-Json -Compress));[IO.File]::Move($temporary,$receiptPath,$true)
}
function Write-SessionHttpResponse([IO.Stream]$Stream,[int]$Status,[string]$Body) {
    $reason=switch($Status){200{'OK'}401{'Unauthorized'}404{'Not Found'}413{'Content Too Large'}502{'Bad Gateway'}default{'Bad Request'}}
    $bytes=[Text.Encoding]::UTF8.GetBytes($Body);$header=[Text.Encoding]::ASCII.GetBytes("HTTP/1.1 $Status $reason`r`nContent-Type: application/json`r`nContent-Length: $($bytes.Length)`r`nConnection: close`r`nCache-Control: no-store`r`n`r`n")
    $Stream.Write($header,0,$header.Length);$Stream.Write($bytes,0,$bytes.Length);$Stream.Flush()
}
function Read-SessionExact([IO.Stream]$Stream,[int]$Length) {
    $buffer=[byte[]]::new($Length);$offset=0
    while($offset -lt $Length){$count=$Stream.Read($buffer,$offset,$Length-$offset);if($count -le 0){throw 'AI_SHARED_GATEWAY_SESSION_REQUEST_TRUNCATED'};$offset+=$count}
    return $buffer
}
function Invoke-SessionRequest([Net.Sockets.TcpClient]$TcpClient) {
    $stream=[Net.Security.SslStream]::new($TcpClient.GetStream(),$false);$stage='TLS'
    try {
        $stream.ReadTimeout=15000;$stream.WriteTimeout=15000
        $stream.AuthenticateAsServer($certificate,$false,[Security.Authentication.SslProtocols]::Tls12 -bor [Security.Authentication.SslProtocols]::Tls13,$false)
        $stage='HEADERS';$headerBytes=[Collections.Generic.List[byte]]::new();$match=0
        while($headerBytes.Count -lt 16384 -and $match -lt 4){$value=$stream.ReadByte();if($value -lt 0){throw 'AI_SHARED_GATEWAY_SESSION_REQUEST_TRUNCATED'};$headerBytes.Add([byte]$value);$expected=@(13,10,13,10)[$match];if($value -eq $expected){$match++}elseif($value -eq 13){$match=1}else{$match=0}}
        if($match -ne 4){Write-SessionHttpResponse $stream 413 '{"error":"request_rejected"}';return}
        $lines=[Text.Encoding]::ASCII.GetString($headerBytes.ToArray()).Split(@("`r`n"),[StringSplitOptions]::None)
        if($lines[0] -cne 'POST /v1/embeddings HTTP/1.1'){Write-SessionHttpResponse $stream 404 '{"error":"route_not_found"}';return}
        $headers=@{}
        foreach($line in $lines[1..($lines.Count-3)]){$separator=$line.IndexOf(':');if($separator -le 0){Write-SessionHttpResponse $stream 400 '{"error":"request_rejected"}';return};$name=$line.Substring(0,$separator).Trim().ToLowerInvariant();$value=$line.Substring($separator+1).Trim();if($headers.ContainsKey($name)){Write-SessionHttpResponse $stream 400 '{"error":"request_rejected"}';return};$headers[$name]=$value}
        if($headers.ContainsKey('transfer-encoding') -or $headers.ContainsKey('expect') -or -not $headers.ContainsKey('content-length') -or -not $headers.ContainsKey('content-type') -or $headers['content-type'] -notmatch '^application/json(?:\s*;\s*charset=utf-8)?$'){Write-SessionHttpResponse $stream 400 '{"error":"request_rejected"}';return}
        $length=0;if(-not [int]::TryParse($headers['content-length'],[Globalization.NumberStyles]::None,[Globalization.CultureInfo]::InvariantCulture,[ref]$length) -or $length -lt 1 -or $length -gt 65536){Write-SessionHttpResponse $stream 413 '{"error":"request_rejected"}';return}
        $stage='AUTH';if(-not $headers.ContainsKey('authorization') -or -not (Test-LabAiSharedGatewaySessionBearer -Authorization $headers['authorization'] -Secrets $consumerSecrets)){Write-SessionHttpResponse $stream 401 '{"error":"unauthorized"}';return}
        $body=[Text.UTF8Encoding]::new($false,$true).GetString((Read-SessionExact $stream $length))
        try{$upstreamBody=ConvertTo-LabAiSharedGatewaySessionUpstreamBody -Json $body -ExpectedModel ([string]$request.RuntimeModel)}catch{Write-SessionHttpResponse $stream 400 '{"error":"request_rejected"}';return}
        $stage='UPSTREAM';$handler=[Net.Http.HttpClientHandler]::new();$handler.UseProxy=$false;$handler.AllowAutoRedirect=$false;$http=[Net.Http.HttpClient]::new($handler);$http.Timeout=[TimeSpan]::FromSeconds(15);$content=$null;$response=$null;$message=$null;$upstreamStream=$null;$upstreamOutput=$null
        try {
            $message=[Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Post,[string]$request.UpstreamLocation);$content=[Net.Http.StringContent]::new($upstreamBody,[Text.Encoding]::UTF8,'application/json');$message.Content=$content
            if($upstreamSecret){$message.Headers.Authorization=[Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer',$upstreamSecret)}
            $response=$http.SendAsync($message,[Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
            if(-not $response.IsSuccessStatusCode){Write-SessionHttpResponse $stream 502 '{"error":"upstream_rejected"}';return}
            if($response.Content.Headers.ContentLength -gt 1MB){Write-SessionHttpResponse $stream 502 '{"error":"upstream_invalid"}';return}
            $upstreamStream=$response.Content.ReadAsStreamAsync().GetAwaiter().GetResult();$upstreamOutput=[IO.MemoryStream]::new();$upstreamBuffer=[byte[]]::new(8192)
            do{$upstreamRead=$upstreamStream.Read($upstreamBuffer,0,$upstreamBuffer.Length);if($upstreamOutput.Length+$upstreamRead -gt 1MB){Write-SessionHttpResponse $stream 502 '{"error":"upstream_invalid"}';return};if($upstreamRead){$upstreamOutput.Write($upstreamBuffer,0,$upstreamRead)}}while($upstreamRead)
            $upstreamResponse=[Text.UTF8Encoding]::new($false,$true).GetString($upstreamOutput.ToArray())
            try{$safeBody=ConvertFrom-LabAiSharedGatewaySessionUpstreamResponse -Json $upstreamResponse -ExpectedModel ([string]$request.RuntimeModel) -Dimension ([int]$request.Dimension)}catch{Write-SessionHttpResponse $stream 502 '{"error":"upstream_invalid"}';return}
            $stage='RESPONSE';Write-SessionHttpResponse $stream 200 $safeBody
        }
        finally{if($upstreamOutput){$upstreamOutput.Dispose()};if($upstreamStream){$upstreamStream.Dispose()};if($response){$response.Dispose()};if($message){$message.Dispose()}elseif($content){$content.Dispose()};$http.Dispose();$handler.Dispose()}
    }
    catch{$inner=if($_.Exception.InnerException){$_.Exception.InnerException}else{$_.Exception};[Console]::Error.WriteLine(('AI_SHARED_GATEWAY_SESSION_REQUEST_FAILED:{0}:{1}:{2}' -f $stage,$inner.GetType().FullName,$inner.HResult));try{Write-SessionHttpResponse $stream 400 '{"error":"request_rejected"}'}catch{}}
    finally{$stream.Dispose()}
}

try {
    $request=Get-Content -LiteralPath $RequestPath -Raw -Encoding utf8|ConvertFrom-Json
    $operationId=[guid]::Empty;$upstreamUri=$null;$address=$null
    try{$upstreamUri=[Uri]::new([string]$request.UpstreamLocation,[UriKind]::Absolute)}catch{throw 'AI_SHARED_GATEWAY_SESSION_REQUEST_INVALID'}
    $expectedPath=if([string]$request.UpstreamBackend -ceq 'OpenVinoModelServer'){'/v3/embeddings'}elseif([string]$request.UpstreamBackend -in @('LlamaCppCpu','LlamaCppCuda','LlamaCppOpenVino','LlamaCppRocm','LlamaCppVulkan','LlamaCppSycl')){'/v1/embeddings'}else{throw 'AI_SHARED_GATEWAY_SESSION_REQUEST_INVALID'}
    if([string]$request.Contract -cne 'SqlServerLab.AiSharedGatewaySessionRequest/1.0' -or -not [guid]::TryParseExact([string]$request.OperationId,'D',[ref]$operationId) -or [string]$request.OwnerNonce -cnotmatch '^[a-f0-9]{64}$' -or [int]$request.Port -lt 1024 -or [int]$request.Port -gt 65535 -or [int]$request.LeaseSeconds -lt 30 -or [int]$request.LeaseSeconds -gt 3600 -or [string]$request.RuntimeModel -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._:/+-]{0,255}$' -or [int]$request.Dimension -lt 1 -or [int]$request.Dimension -gt 1998 -or [string]$request.ServerCertificateSha256 -cnotmatch '^[a-f0-9]{64}$' -or $upstreamUri.Scheme -cne 'http' -or $upstreamUri.AbsolutePath -cne $expectedPath -or $upstreamUri.Port -lt 1024 -or -not [string]::IsNullOrEmpty($upstreamUri.UserInfo) -or -not [string]::IsNullOrEmpty($upstreamUri.Query) -or -not [string]::IsNullOrEmpty($upstreamUri.Fragment) -or -not [Net.IPAddress]::TryParse($upstreamUri.Host,[ref]$address) -or -not [Net.IPAddress]::IsLoopback($address)){throw 'AI_SHARED_GATEWAY_SESSION_REQUEST_INVALID'}
    . (Join-Path (Split-Path -Parent $PSScriptRoot) 'Private/AiOvmsHttpsGateway.ps1')
    . (Join-Path (Split-Path -Parent $PSScriptRoot) 'Private/AiSharedGatewaySession.ps1')
    $keyPath=Join-Path $operationRoot 'consumer-keys.json';$consumerSecrets=@(Get-Content -LiteralPath $keyPath -Raw -Encoding utf8|ConvertFrom-Json)
    if(-not $consumerSecrets.Count -or @($consumerSecrets|Where-Object {$_ -isnot [string] -or $_ -cnotmatch '^[A-Za-z0-9_-]{24,256}$'}).Count -or @($consumerSecrets|Sort-Object -Unique).Count -ne $consumerSecrets.Count){throw 'AI_SHARED_GATEWAY_SESSION_SECRET_STATE_INVALID'}
    Remove-Item -LiteralPath $keyPath -Force
    $upstreamKeyPath=Join-Path $operationRoot 'upstream-key.txt';if(Test-Path -LiteralPath $upstreamKeyPath){$upstreamSecret=[IO.File]::ReadAllText($upstreamKeyPath);Remove-Item -LiteralPath $upstreamKeyPath -Force;if($upstreamSecret -cnotmatch '^[A-Za-z0-9_-]{24,256}$'){throw 'AI_SHARED_GATEWAY_SESSION_SECRET_STATE_INVALID'}}
    $pem=[Security.Cryptography.X509Certificates.X509Certificate2]::CreateFromPemFile([string]$request.CertificatePath,[string]$request.PrivateKeyPath)
    try{if($pem.GetCertHashString([Security.Cryptography.HashAlgorithmName]::SHA256).ToLowerInvariant() -cne [string]$request.ServerCertificateSha256){throw 'AI_SHARED_GATEWAY_SESSION_CERTIFICATE_MISMATCH'};$pfx=$pem.Export([Security.Cryptography.X509Certificates.X509ContentType]::Pkcs12);$certificate=[Security.Cryptography.X509Certificates.X509Certificate2]::new($pfx,'',[Security.Cryptography.X509Certificates.X509KeyStorageFlags]::UserKeySet)}finally{$pem.Dispose();if($pfx){[Array]::Clear($pfx,0,$pfx.Length)}}
    $listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,[int]$request.Port);$listener.Start(16)
    $stopBuffer=[byte[]]::new(1);$stopSignal=[Console]::OpenStandardInput().ReadAsync($stopBuffer,0,1);Write-SessionReceipt 'RUNNING' 'LOOPBACK_LISTENER_READY';$watch=[Diagnostics.Stopwatch]::StartNew()
    while($watch.Elapsed.TotalSeconds -lt [int]$request.LeaseSeconds -and -not $stopSignal.IsCompleted){$accept=$listener.AcceptTcpClientAsync();while(-not $accept.Wait(100)){if($stopSignal.IsCompleted -or $watch.Elapsed.TotalSeconds -ge [int]$request.LeaseSeconds){break}};if($accept.IsCompletedSuccessfully){$client=$accept.Result;Invoke-SessionRequest $client;$client.Dispose();$client=$null}}
    Write-SessionReceipt 'STOPPED' $(if($stopSignal.IsCompleted){'OWNER_CLOSED'}else{'LEASE_EXPIRED'})
}
catch{[Console]::Error.WriteLine(('AI_SHARED_GATEWAY_SESSION_WORKER_FAILED:{0}:{1}' -f $_.Exception.GetType().FullName,$_.Exception.HResult));if($request){Write-SessionReceipt 'FAILED' 'AI_SHARED_GATEWAY_SESSION_WORKER_FAILED'}}
finally{if($client){$client.Dispose()};if($listener){$listener.Stop()};if($certificate){$certificate.Dispose()};$consumerSecrets=@();$upstreamSecret=$null;foreach($name in @('consumer-keys.json','upstream-key.txt')){$path=Join-Path $operationRoot $name;if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path -Force}}}
