# Ausschließlich synthetische Loopback-HTTP-Prüfung; kein Mailpit-/Provider-/SQL-Nachweis.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$source = Join-Path $root 'Private/SmtpTestServiceReceiverRead.ps1'
$before = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
. $source
$cases = [Collections.Generic.List[object]]::new()
$fixtureClock=[Diagnostics.Stopwatch]::StartNew()
$credential = [Management.Automation.PSCredential]::new('synthetic',[Security.SecureString]::new())
foreach ($c in 'synthetic-test-only'.ToCharArray()) { $credential.Password.AppendChar($c) }
$credential.Password.MakeReadOnly()
$disposedPassword=[Security.SecureString]::new(); $disposedPassword.AppendChar('x')
$disposedCredential=[Management.Automation.PSCredential]::new('synthetic',$disposedPassword)
$disposedPassword.Dispose()
$messageId = '0123456789ABCDEFGHIJKL'
$payload = [byte[]]@(70,114,111,109,58,32,115,121,110,116,104,101,116,105,99,13,10,13,10,0,255,128)
$expectedAuth = 'Basic '+[Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes('synthetic:synthetic-test-only'))
function Add-ReceiverCase([string]$Id,[bool]$Passed) {
    $cases.Add([pscustomobject]@{Id=$Id;Status=$(if($Passed){'PASS'}else{'FAIL'})})
}

# Ein invalides Input darf weder einen Socket öffnen noch Secretkonvertierung erreichen.
$invalids = @(
    @{Id='INPUT_ADDRESS_STRING';Address='127.0.0.1';Port=1;Message=$messageId;Credential=$credential},
    @{Id='INPUT_ADDRESS_REMOTE';Address=[Net.IPAddress]::Parse('192.0.2.1');Port=1;Message=$messageId;Credential=$credential},
    @{Id='INPUT_ADDRESS_NULL';Address=$null;Port=1;Message=$messageId;Credential=$credential},
    @{Id='INPUT_PORT_STRING';Address=[Net.IPAddress]::Loopback;Port='1';Message=$messageId;Credential=$credential},
    @{Id='INPUT_PORT_ZERO';Address=[Net.IPAddress]::Loopback;Port=0;Message=$messageId;Credential=$credential},
    @{Id='INPUT_PORT_OVERFLOW';Address=[Net.IPAddress]::Loopback;Port=65536;Message=$messageId;Credential=$credential},
    @{Id='INPUT_ID_LATEST';Address=[Net.IPAddress]::Loopback;Port=1;Message='latest';Credential=$credential},
    @{Id='INPUT_ID_QUERY';Address=[Net.IPAddress]::Loopback;Port=1;Message='0123456789ABCDEFGHIJ?L';Credential=$credential},
    @{Id='INPUT_ID_ARRAY';Address=[Net.IPAddress]::Loopback;Port=1;Message=@($messageId);Credential=$credential},
    @{Id='INPUT_CREDENTIAL_NULL';Address=[Net.IPAddress]::Loopback;Port=1;Message=$messageId;Credential=$null},
    @{Id='INPUT_CREDENTIAL_DISPOSED';Address=[Net.IPAddress]::Loopback;Port=1;Message=$messageId;Credential=$disposedCredential}
)
foreach ($v in $invalids) {
    $caught = $null
    try { $unexpected = Read-LabSmtpTestServiceReceiverRaw $v.Address $v.Port $v.Message $v.Credential }
    catch { $caught = $_.Exception }
    Add-ReceiverCase $v.Id ($null -ne $caught -and $caught.Message -ceq 'SMTP_RECEIVER_INPUT_INVALID')
}

# Server liest lediglich den eigenen synthetischen Request. Nur Counts/Booleans verlassen den Job.
$server = {
    param($Listener,$Mode,$Payload,$ExpectedAuth,$MessageId)
    $ErrorActionPreference = 'Stop'
    $accepted = $null; $stream = $null; $requestBuffer = [byte[]]::new(16384)
    $tcpCount=0; $requests=0; $authEvents=0; $pathOk=$false; $authOk=$false; $headersOk=$false
    $fault=$false; $disposed=$false
    try {
        $accept = $Listener.AcceptTcpClientAsync()
        if (-not $accept.Wait(12000)) { throw 'SYNTHETIC_ACCEPT_TIMEOUT' }
        $accepted = $accept.GetAwaiter().GetResult(); $tcpCount++
        $stream = $accepted.GetStream(); $stream.ReadTimeout=12000; $stream.WriteTimeout=12000
        $n=0
        while ($n -lt $requestBuffer.Length) {
            $b=$stream.ReadByte(); if($b -lt 0){break}; $requestBuffer[$n]=[byte]$b; $n++
            if($n -ge 4 -and $requestBuffer[$n-4] -eq 13 -and $requestBuffer[$n-3] -eq 10 -and
                $requestBuffer[$n-2] -eq 13 -and $requestBuffer[$n-1] -eq 10){break}
        }
        $text=[Text.Encoding]::ASCII.GetString($requestBuffer,0,$n)
        $lines=$text.Split([string[]]@("`r`n"),[StringSplitOptions]::None)
        $requests=[int]($text.EndsWith("`r`n`r`n",[StringComparison]::Ordinal))
        $pathOk=$lines[0] -ceq ('GET /api/v1/message/'+$MessageId+'/raw HTTP/1.1')
        $authLines=@($lines|Where-Object{ $_.StartsWith('Authorization:',[StringComparison]::OrdinalIgnoreCase) })
        $authEvents=$authLines.Count; $authOk=$authEvents -eq 1 -and $authLines[0] -ceq ('Authorization: '+$ExpectedAuth)
        $headersOk=@($lines|Where-Object{$_ -ieq 'Connection: close'}).Count -eq 1 -and
            @($lines|Where-Object{$_ -ieq 'Accept-Encoding: identity'}).Count -eq 1
        $text=$null; $lines=$null; $authLines=$null
        if ($Mode -eq 'Drop') {
            $stream.Dispose(); $stream=$null; $accepted.Dispose(); $accepted=$null
            $second=$Listener.AcceptTcpClientAsync()
            if ($second.Wait(1000)) { $other=$second.GetAwaiter().GetResult(); $tcpCount++; $other.Dispose() }
        } elseif ($Mode -eq 'HoldHeaders') {
            [Threading.Thread]::Sleep(11000)
        } else {
            $status='200 OK'; $encoding=''; $length='Content-Length: '+$Payload.Length+"`r`n"
            if($Mode -eq 'Redirect'){$status='302 Found'}
            if($Mode -eq 'Unauthorized'){$status='401 Unauthorized'}
            if($Mode -eq 'NotFound'){$status='404 Not Found'}
            if($Mode -eq 'Encoding'){$encoding="Content-Encoding: gzip`r`n"}
            if($Mode -eq 'DeclaredOverflow'){$length="Content-Length: 8388609`r`n"}
            if($Mode -eq 'Chunked' -or $Mode -eq 'StreamOverflow'){$length="Transfer-Encoding: chunked`r`n"}
            if($Mode -eq 'UnknownLength'){$length=''}
            if($Mode -eq 'HoldBody'){$length="Content-Length: 1`r`n"}
            if($Mode -eq 'HeaderOverflow'){$encoding='X-Synthetic: '+('x'*17000)+"`r`n"}
            $header=[Text.Encoding]::ASCII.GetBytes('HTTP/1.1 '+$status+"`r`nContent-Type: text/plain; charset=utf-8`r`n"+$encoding+$length+"Connection: close`r`n`r`n")
            $stream.Write($header,0,$header.Length); [Array]::Clear($header,0,$header.Length)
            if($Mode -eq 'HoldBody'){[Threading.Thread]::Sleep(11000)}
            elseif($Mode -eq 'Chunked'){
                $prefix=[Text.Encoding]::ASCII.GetBytes($Payload.Length.ToString('X')+"`r`n")
                $stream.Write($prefix,0,$prefix.Length); $stream.Write($Payload,0,$Payload.Length)
                $end=[Text.Encoding]::ASCII.GetBytes("`r`n0`r`n`r`n"); $stream.Write($end,0,$end.Length)
            } elseif($Mode -eq 'StreamOverflow'){
                $chunk=[byte[]]::new(65536); $prefix=[Text.Encoding]::ASCII.GetBytes("10000`r`n"); $suffix=[byte[]]@(13,10)
                try { for($i=0;$i -lt 129;$i++) { $stream.Write($prefix,0,$prefix.Length); $stream.Write($chunk,0,$chunk.Length); $stream.Write($suffix,0,2) } }
                catch { } finally { [Array]::Clear($chunk,0,$chunk.Length) }
            } elseif($Mode -notin @('DeclaredOverflow','Redirect','Unauthorized','NotFound','Encoding')){
                $stream.Write($Payload,0,$Payload.Length)
            }
        }
    } catch { $fault=$true }
    finally {
        [Array]::Clear($requestBuffer,0,$requestBuffer.Length)
        try { if($null -ne $stream){$stream.Dispose()} } catch {$fault=$true}
        try { if($null -ne $accepted){$accepted.Dispose()} } catch {$fault=$true}
        try { $Listener.Stop(); $disposed=$true } catch {$fault=$true}
    }
    [pscustomobject]@{Tcp=$tcpCount;Requests=$requests;AuthEvents=$authEvents;PathOk=$pathOk;AuthOk=$authOk;HeadersOk=$headersOk;Fault=$fault;Disposed=$disposed}
}
$httpCases=@(
    @{Id='RAW_BINARY';Mode='Length';Code=$null},
    @{Id='RAW_EMPTY';Mode='Length';Code=$null},
    @{Id='RAW_LIMIT_EXACT';Mode='Length';Code=$null},
    @{Id='RAW_CHUNKED';Mode='Chunked';Code=$null},
    @{Id='RAW_UNKNOWN_LENGTH';Mode='UnknownLength';Code=$null},
    @{Id='DECLARED_OVERFLOW';Mode='DeclaredOverflow';Code='SMTP_RECEIVER_OUTPUT_LIMIT'},
    @{Id='STREAM_OVERFLOW';Mode='StreamOverflow';Code='SMTP_RECEIVER_OUTPUT_LIMIT'},
    @{Id='REDIRECT_VETO';Mode='Redirect';Code='SMTP_RECEIVER_HTTP_STATUS_INVALID'},
    @{Id='AUTH_STATUS_VETO';Mode='Unauthorized';Code='SMTP_RECEIVER_HTTP_STATUS_INVALID'},
    @{Id='NOT_FOUND_VETO';Mode='NotFound';Code='SMTP_RECEIVER_HTTP_STATUS_INVALID'},
    @{Id='ENCODING_VETO';Mode='Encoding';Code='SMTP_RECEIVER_RESPONSE_INVALID'},
    @{Id='HEADER_OVERFLOW';Mode='HeaderOverflow';Code='SMTP_RECEIVER_NETWORK_FAILURE'},
    @{Id='DROP_NO_REPLAY';Mode='Drop';Code='SMTP_RECEIVER_NETWORK_FAILURE'},
    @{Id='DEADLINE_HEADERS';Mode='HoldHeaders';Code='SMTP_RECEIVER_DEADLINE_EXCEEDED'},
    @{Id='DEADLINE_BODY';Mode='HoldBody';Code='SMTP_RECEIVER_DEADLINE_EXCEEDED'},
    @{Id='FRESH_READ_AFTER_FAILURE';Mode='Length';Code=$null}
)
foreach($case in $httpCases){
    if($fixtureClock.ElapsedMilliseconds -ge 240000){Add-ReceiverCase $case.Id $false;continue}
    $listener=$null; $job=$null; $bytes=$null; $caught=$null; $record=$null; $cleanup=$true
    $casePayload=$payload
    if($case.Id -eq 'RAW_EMPTY'){$casePayload=[byte[]]::new(0)}
    if($case.Id -eq 'RAW_LIMIT_EXACT'){$casePayload=[byte[]]::new(8388608)}
    try {
        $listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0); $listener.Start()
        $port=[int]$listener.LocalEndpoint.Port
        $job=Start-ThreadJob -ScriptBlock $server -ArgumentList $listener,$case.Mode,$casePayload,$expectedAuth,$messageId
        try { $bytes=Read-LabSmtpTestServiceReceiverRaw ([Net.IPAddress]::Loopback) $port $messageId $credential }
        catch { $caught=$_.Exception }
        if($null -eq (Wait-Job -Job $job -Timeout 15)){throw 'SYNTHETIC_SERVER_TIMEOUT'}
        $record=Receive-Job -Job $job -ErrorAction Stop
    } catch { $cleanup=$false }
    finally {
        if($null -ne $listener){try{$listener.Stop()}catch{$cleanup=$false}}
        if($null -ne $job){try{if($job.State -notin @('Completed','Failed','Stopped')){Stop-Job -Job $job}; Remove-Job -Job $job -Force}catch{$cleanup=$false}}
        if($null -ne $job -and $null -ne (Get-Job -Id $job.Id -ErrorAction SilentlyContinue)){$cleanup=$false}
    }
    $ok=$cleanup -and $null -ne $record -and -not $record.Fault -and $record.Disposed -and
        $record.Tcp -eq 1 -and $record.Requests -eq 1 -and $record.AuthEvents -eq 1 -and
        $record.PathOk -and $record.AuthOk -and $record.HeadersOk
    if($null -eq $case.Code){
        $ok=$ok -and $null -eq $caught -and $bytes -is [byte[]] -and
            [Convert]::ToBase64String($bytes) -ceq [Convert]::ToBase64String($casePayload)
    } else {
        $ok=$ok -and $null -eq $bytes -and $null -ne $caught -and $caught.Message -ceq $case.Code -and
            $caught.Data['SmtpReceiverCleanupConfirmed'] -eq $true -and $caught.Data['SmtpReceiverRecoveryRequired'] -eq $false
    }
    Add-ReceiverCase $case.Id $ok
    if($null -ne $bytes){[Array]::Clear($bytes,0,$bytes.Length)}
    if($case.Id -eq 'RAW_LIMIT_EXACT'){[Array]::Clear($casePayload,0,$casePayload.Length)}
}
[Array]::Clear($payload,0,$payload.Length); $expectedAuth=$null; $credential.Password.Dispose(); $credential=$null
$after=(Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
$sourceStable=$before -ceq $after
$failed=@($cases|Where-Object Status -eq 'FAIL').Count
if(-not $sourceStable){$failed++}
[pscustomobject]@{Schema='SMTP_RECEIVER_READ_CHECKS/v1';Status=$(if($failed -eq 0){'PASS'}else{'FAIL'});
    Passed=@($cases|Where-Object Status -eq 'PASS').Count;Failed=$failed;Cases=$cases.ToArray();
    SourceStable=$sourceStable;ProviderCalls=0;MailpitRuntimeCalls=0}
