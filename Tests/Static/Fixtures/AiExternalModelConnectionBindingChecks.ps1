#Requires -Version 7.2
[CmdletBinding()]
param([Management.Automation.PSModuleInfo]$Module)
$ErrorActionPreference='Stop'
$ownModule=$null
if (-not $Module) {
    $core=Join-Path $PSScriptRoot '../../../Private/AiExternalModelAcceleration.ps1'
    $ownModule=New-Module -ScriptBlock {param($path). $path} -ArgumentList $core
    $Module=$ownModule
}
$connectionPassed=0
function Check-Connection([string]$Name,[bool]$Passed) {
    if (-not $Passed) {throw ('EXTERNAL_CONNECTION_CHECK_FAILED: '+$Name)}
    $script:connectionPassed++
}
function Error-Connection([scriptblock]$Action,[string]$Code,[type]$Type) {
    try {& $Action | Out-Null; return $false}
    catch {
        $cause=$_.Exception
        while ($cause) {
            if (($Code -and $cause.Message -ceq $Code) -or ($Type -and $cause -is $Type)) {return $true}
            $cause=$cause.InnerException
        }
        return $false
    }
}
function Invoke-ConnectionWorker($Callback,$Context,[Threading.CancellationToken]$Token=[Threading.CancellationToken]::None) {
    $invoke=[Linq.Expressions.Expression]::Invoke([Linq.Expressions.Expression]::Constant($Callback),[Linq.Expressions.Expression[]]@(
        [Linq.Expressions.Expression]::Constant($Context),[Linq.Expressions.Expression]::Constant($Token)))
    $worker=[Linq.Expressions.Expression]::Lambda([Func[Threading.Tasks.ValueTask[IO.Stream]]],$invoke,[Linq.Expressions.ParameterExpression[]]@()).Compile()
    $run=@([Threading.Tasks.Task].GetMethods() | Where-Object {$_.Name -eq 'Run' -and $_.IsGenericMethodDefinition -and
        $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.GetGenericArguments()[0].IsGenericParameter})[0]
    $task=$run.MakeGenericMethod([Threading.Tasks.ValueTask[IO.Stream]]).Invoke($null,[object[]]@($worker))
    return ,$task.WaitAsync([TimeSpan]::FromSeconds(3)).GetAwaiter().GetResult().GetAwaiter().GetResult()
}
$cts=[Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds(10))
$streams=[Collections.Generic.List[IO.Stream]]::new()
$messages=[Collections.Generic.List[Net.Http.HttpRequestMessage]]::new()
$listener=$null;$tcp=$null;$accepted=$null;$secret=$null;$cancelled=$null
try {
    $calls=[Runtime.CompilerServices.StrongBox[int]]::new(0)
    $never={param($hostName,$token)$calls.Value++;throw 'SYNTHETIC_UNEXPECTED_DNS'}.GetNewClosure()
    foreach ($location in @('https://127.0.0.1:18443/v1/embeddings','https://[::1]:18443/v1/embeddings')) {
        $resolved=& $Module {param($uri,$token,$resolver)Resolve-LabAiExternalModelConnectAddress -Uri $uri -CancellationToken $token -Resolver $resolver} ([Uri]$location) $cts.Token $never
        Check-Connection 'Numeric address uses no resolver' ($calls.Value -eq 0 -and [Net.IPAddress]::IsLoopback($resolved))
    }
    $cases=@(
        @{Name='Empty';Values=@();Valid=$false},
        @{Name='Mixed';Values=@([Net.IPAddress]::Loopback,[Net.IPAddress]::Parse('192.0.2.1'));Valid=$false},
        @{Name='Nonloopback';Values=@([Net.IPAddress]::Parse('192.0.2.1'));Valid=$false},
        @{Name='Null';Values=@($null);Valid=$false},
        @{Name='Malformed text';Values=@('127.0.0.1');Valid=$false},
        @{Name='Malformed member';Values=@([Net.IPAddress]::Loopback,[pscustomobject]@{Address='127.0.0.1'});Valid=$false},
        @{Name='Scoped IPv6';Values=@([Net.IPAddress]::Parse('::1%1'));Valid=$false},
        @{Name='IPv4 preferred';Values=@([Net.IPAddress]::IPv6Loopback,[Net.IPAddress]::Parse('127.0.0.2'),[Net.IPAddress]::Loopback);Valid=$true}
    )
    foreach ($case in $cases) {
        $calls.Value=0
        $valueBox=[Runtime.CompilerServices.StrongBox[object[]]]::new([object[]]$case.Values)
        $resolver={param($hostName,$token)
            $calls.Value++
            $completion=[Threading.Tasks.TaskCompletionSource[object[]]]::new()
            $completion.SetResult($valueBox.Value)
            return $completion.Task
        }.GetNewClosure()
        if ($case.Valid) {
            $address=& $Module {param($token,$resolver)Resolve-LabAiExternalModelConnectAddress -Uri ([Uri]'https://localhost:18443/v1/embeddings') -CancellationToken $token -Resolver $resolver} $cts.Token $resolver
            Check-Connection 'Complete snapshot selects deterministic IPv4' ($address.Equals([Net.IPAddress]::Loopback))
            Check-Connection 'Selected address is detached from resolver object' (-not [object]::ReferenceEquals($address,$case.Values[2]))
        } else {
            Check-Connection ($case.Name+' snapshot veto') (Error-Connection {
                & $Module {param($token,$resolver)Resolve-LabAiExternalModelConnectAddress -Uri ([Uri]'https://localhost:18443/v1/embeddings') -CancellationToken $token -Resolver $resolver} $cts.Token $resolver
            } 'AI_EXTERNAL_MODEL_DNS_SNAPSHOT_INVALID' $null)
        }
        Check-Connection ($case.Name+' resolves exactly once') ($calls.Value -eq 1)
    }
    # Welsh DD collation must not affect numeric address order. Change only
    # this caller's culture, and restore it even if a characterization fails.
    $originalCulture=[Globalization.CultureInfo]::CurrentCulture
    try {
        foreach ($cultureName in @('en-US','cy-GB')) {
            [Globalization.CultureInfo]::CurrentCulture=[Globalization.CultureInfo]::GetCultureInfo($cultureName)
            foreach ($orderCase in @(
                @{Name='Same-family ordinal minimum';Values=@([Net.IPAddress]::Parse('127.0.0.221'),[Net.IPAddress]::Parse('127.0.0.223'))},
                @{Name='IPv4 rank before IPv6';Values=@([Net.IPAddress]::IPv6Loopback,[Net.IPAddress]::Parse('127.0.0.223'),[Net.IPAddress]::Parse('127.0.0.221'))})) {
                foreach ($reverse in @($false,$true)) {
                    $calls.Value=0
                    $orderedValues=[object[]]@($orderCase.Values)
                    if ($reverse) {[Array]::Reverse($orderedValues)}
                    $valueBox=[Runtime.CompilerServices.StrongBox[object[]]]::new($orderedValues)
                    $resolver={param($hostName,$token)
                        $calls.Value++
                        $completion=[Threading.Tasks.TaskCompletionSource[object[]]]::new()
                        $completion.SetResult($valueBox.Value)
                        return $completion.Task
                    }.GetNewClosure()
                    $address=& $Module {param($token,$resolver)Resolve-LabAiExternalModelConnectAddress -Uri ([Uri]'https://localhost:18443/v1/embeddings') -CancellationToken $token -Resolver $resolver} $cts.Token $resolver
                    $caseName=$cultureName+' '+$orderCase.Name+' reversed='+$reverse
                    Check-Connection ($caseName+' selects exact minimum in caller culture') (
                        [Globalization.CultureInfo]::CurrentCulture.Name -ceq $cultureName -and
                        $address.Equals([Net.IPAddress]::Parse('127.0.0.221')))
                    Check-Connection ($caseName+' resolves exactly once') ($calls.Value -eq 1)
                    $borrowed=@($orderedValues | Where-Object {[object]::ReferenceEquals($address,$_)})
                    Check-Connection ($caseName+' selects a detached address') ($borrowed.Count -eq 0)
                }
            }
            if ($cultureName -ceq 'cy-GB') {
                $calls.Value=0
                $valueBox=[Runtime.CompilerServices.StrongBox[object[]]]::new([object[]]@(
                    [Net.IPAddress]::Parse('127.0.0.221'),[Net.IPAddress]::Parse('127.0.0.223'),[Net.IPAddress]::Parse('192.0.2.1')))
                $resolver={param($hostName,$token)
                    $calls.Value++
                    $completion=[Threading.Tasks.TaskCompletionSource[object[]]]::new()
                    $completion.SetResult($valueBox.Value)
                    return $completion.Task
                }.GetNewClosure()
                Check-Connection 'Welsh invalid tail vetoes the full snapshot before selection' (Error-Connection {
                    & $Module {param($token,$resolver)Resolve-LabAiExternalModelConnectAddress -Uri ([Uri]'https://localhost:18443/v1/embeddings') -CancellationToken $token -Resolver $resolver} $cts.Token $resolver
                } 'AI_EXTERNAL_MODEL_DNS_SNAPSHOT_INVALID' $null)
                Check-Connection 'Welsh invalid tail resolves exactly once' ($calls.Value -eq 1)
            }
        }
    } finally {[Globalization.CultureInfo]::CurrentCulture=$originalCulture}
    Check-Connection 'Ordinal cases restore the caller culture' ([object]::ReferenceEquals([Globalization.CultureInfo]::CurrentCulture,$originalCulture))
    $late=[Threading.Tasks.TaskCompletionSource[object[]]]::new()
    $lateResolver={param($hostName,$token)$late.Task}.GetNewClosure()
    $short=[Threading.CancellationTokenSource]::new([TimeSpan]::FromMilliseconds(50))
    try {
        Check-Connection 'DNS wait uses caller deadline' (Error-Connection {
            & $Module {param($token,$resolver)Resolve-LabAiExternalModelConnectAddress -Uri ([Uri]'https://localhost:18443/v1/embeddings') -CancellationToken $token -Resolver $resolver} $short.Token $lateResolver
        } 'AI_EXTERNAL_MODEL_ENDPOINT_TIMEOUT' $null)
        $late.SetResult([object[]]@([Net.IPAddress]::Loopback))
    } finally {$short.Dispose()}

    $constructor=@([Net.Http.SocketsHttpConnectionContext].GetConstructors([Reflection.BindingFlags]'Public,NonPublic,Instance'))[0]
    foreach ($location in @('https://localhost:18443/v1/embeddings','https://127.0.0.1:18443/v1/embeddings','https://[::1]:18443/v1/embeddings')) {
        $uri=[Uri]$location
        $message=[Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Post,$uri);$messages.Add($message)
        $callbackHosts=@($uri.IdnHost)
        if($uri.HostNameType -eq [UriHostNameType]::IPv6){$callbackHosts+=@('['+$uri.IdnHost+']')}
        foreach($callbackHost in $callbackHosts){
            $context=$constructor.Invoke([object[]]@([Net.DnsEndPoint]::new($callbackHost,$uri.Port),$message))
            $stream=[IO.MemoryStream]::new([byte[]]@(1));$streams.Add($stream)
            $callback=& $Module {param($uri,$stream)New-LabAiExternalModelConnectCallback -Uri $uri -Stream $stream} $uri $stream
            Check-Connection 'CLR worker receives exact stream for original authority' ([object]::ReferenceEquals((Invoke-ConnectionWorker $callback $context),$stream))
            Check-Connection 'Second CLR worker handoff is refused' (Error-Connection {Invoke-ConnectionWorker $callback $context} 'AI_EXTERNAL_MODEL_CONNECT_HANDOFF_REQUIRED' $null)
            $stream.Dispose()
            Check-Connection 'Caller keeps disposal custody after handoff' (-not $stream.CanRead)
        }
    }
    $goodMessage=[Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Post,[Uri]'https://localhost:18443/v1/embeddings');$messages.Add($goodMessage)
    $good=$constructor.Invoke([object[]]@([Net.DnsEndPoint]::new('localhost',18443),$goodMessage))
    foreach ($case in @(
        @{Host='other.invalid';Port=18443;Uri='https://localhost:18443/v1/embeddings'},
        @{Host='localhost';Port=18444;Uri='https://localhost:18443/v1/embeddings'},
        @{Host='localhost';Port=18443;Uri='https://other.invalid:18443/v1/embeddings'})) {
        $stream=[IO.MemoryStream]::new();$streams.Add($stream)
        $callback=& $Module {param($stream)New-LabAiExternalModelConnectCallback -Uri ([Uri]'https://localhost:18443/v1/embeddings') -Stream $stream} $stream
        $message=[Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Post,[Uri]$case.Uri);$messages.Add($message)
        $bad=$constructor.Invoke([object[]]@([Net.DnsEndPoint]::new($case.Host,$case.Port),$message))
        Check-Connection 'Wrong callback authority is refused' (Error-Connection {Invoke-ConnectionWorker $callback $bad} 'AI_EXTERNAL_MODEL_CONNECT_HANDOFF_REQUIRED' $null)
        Check-Connection 'Rejected authority does not consume the sole stream' ([object]::ReferenceEquals((Invoke-ConnectionWorker $callback $good),$stream))
    }
    $cancelled=[Threading.CancellationTokenSource]::new();$cancelled.Cancel()
    $stream=[IO.MemoryStream]::new();$streams.Add($stream)
    $callback=& $Module {param($stream)New-LabAiExternalModelConnectCallback -Uri ([Uri]'https://localhost:18443/v1/embeddings') -Stream $stream} $stream
    Check-Connection 'Canceled CLR callback refuses handoff' (Error-Connection {Invoke-ConnectionWorker $callback $good $cancelled.Token} $null ([OperationCanceledException]))
    Check-Connection 'Cancellation preserves caller custody' ([object]::ReferenceEquals((Invoke-ConnectionWorker $callback $good),$stream))

    foreach($case in @(
        @{Name='Nested IPv6 brackets';Expected='https://[::1]:18443/v1/embeddings';Host='[[::1]]';Port=18443;Uri='https://[::1]:18443/v1/embeddings'},
        @{Name='Different IPv6 address';Expected='https://[::1]:18443/v1/embeddings';Host='[::2]';Port=18443;Uri='https://[::1]:18443/v1/embeddings'},
        @{Name='Different IPv6 port';Expected='https://[::1]:18443/v1/embeddings';Host='[::1]';Port=18444;Uri='https://[::1]:18443/v1/embeddings'},
        @{Name='Different IPv6 request authority';Expected='https://[::1]:18443/v1/embeddings';Host='[::1]';Port=18443;Uri='https://[::2]:18443/v1/embeddings'},
        @{Name='Bracketed DNS name';Expected='https://localhost:18443/v1/embeddings';Host='[localhost]';Port=18443;Uri='https://localhost:18443/v1/embeddings'},
        @{Name='Bracketed IPv4 address';Expected='https://127.0.0.1:18443/v1/embeddings';Host='[127.0.0.1]';Port=18443;Uri='https://127.0.0.1:18443/v1/embeddings'})){
        $expectedUri=[Uri]$case.Expected
        $stream=[IO.MemoryStream]::new();$streams.Add($stream)
        $callback=& $Module {param($uri,$stream)New-LabAiExternalModelConnectCallback -Uri $uri -Stream $stream} $expectedUri $stream
        $message=[Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Post,[Uri]$case.Uri);$messages.Add($message)
        $bad=$constructor.Invoke([object[]]@([Net.DnsEndPoint]::new($case.Host,$case.Port),$message))
        $matchingMessage=[Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Post,$expectedUri);$messages.Add($matchingMessage)
        $matching=$constructor.Invoke([object[]]@([Net.DnsEndPoint]::new($expectedUri.IdnHost,$expectedUri.Port),$matchingMessage))
        Check-Connection ($case.Name+' is refused') (Error-Connection {Invoke-ConnectionWorker $callback $bad} 'AI_EXTERNAL_MODEL_CONNECT_HANDOFF_REQUIRED' $null)
        Check-Connection ($case.Name+' veto preserves the sole handoff') ([object]::ReferenceEquals((Invoke-ConnectionWorker $callback $matching),$stream))
        Check-Connection ($case.Name+' recovery cannot hand off twice') (Error-Connection {Invoke-ConnectionWorker $callback $matching} 'AI_EXTERNAL_MODEL_CONNECT_HANDOFF_REQUIRED' $null)
    }
    foreach($callbackHost in @('::1','[::1]')){
        $stream=[IO.MemoryStream]::new();$streams.Add($stream)
        $callback=& $Module {param($stream)New-LabAiExternalModelConnectCallback -Uri ([Uri]'https://[::1]:18443/v1/embeddings') -Stream $stream} $stream
        $message=[Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Post,[Uri]'https://[::1]:18443/v1/embeddings');$messages.Add($message)
        $matching=$constructor.Invoke([object[]]@([Net.DnsEndPoint]::new($callbackHost,18443),$message))
        Check-Connection 'Canceled IPv6 CLR callback refuses handoff' (Error-Connection {Invoke-ConnectionWorker $callback $matching $cancelled.Token} $null ([OperationCanceledException]))
        Check-Connection 'IPv6 cancellation preserves the sole stream' ([object]::ReferenceEquals((Invoke-ConnectionWorker $callback $matching),$stream))
        Check-Connection 'IPv6 cancellation recovery cannot hand off twice' (Error-Connection {Invoke-ConnectionWorker $callback $matching} 'AI_EXTERNAL_MODEL_CONNECT_HANDOFF_REQUIRED' $null)
    }

    # Genuine numeric TCP only: private connector seam deliberately returns a
    # connection to our own wrong port. No TLS or application bytes are sent.
    $listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0);$listener.Start()
    $port=$listener.LocalEndpoint.Port
    $tcp=& $Module {param($port,$token)Connect-LabAiExternalModelPeer -Address ([Net.IPAddress]::Loopback) -Port $port -CancellationToken $token} $port $cts.Token
    $accepted=$listener.AcceptTcpClient()
    $peerVerified=& $Module {param($tcp,$port)
        Assert-LabAiExternalModelPeer -Client $tcp -Address ([Net.IPAddress]::Loopback) -Port $port
        $true
    } $tcp $port
    $nativePeer=$tcp.Client.RemoteEndPoint
    Check-Connection 'Native connected endpoint has exact IP and port' ($peerVerified -ceq $true -and
        $nativePeer -is [Net.IPEndPoint] -and $nativePeer.Address.Equals([Net.IPAddress]::Loopback) -and $nativePeer.Port -eq $port)
    $openCount=[Runtime.CompilerServices.StrongBox[int]]::new(0)
    $transportModule=New-Module -ScriptBlock {
        param($core,$counter)
        . $core
        $script:counter=$counter
        function ConvertFrom-LabSecureString {param([SecureString]$SecureString)$script:counter.Value++;throw 'SYNTHETIC_SECRET_MUST_NOT_OPEN'}
    } -ArgumentList (Join-Path $PSScriptRoot '../../../Private/AiExternalModelAcceleration.ps1'),$openCount
    $secret=[SecureString]::new();$secret.AppendChar('x');$secret.MakeReadOnly()
    $connector={param($address,$targetPort,$token)$tcp}.GetNewClosure()
    $expectedPort=if($port -eq 65535){$port-1}else{$port+1}
    try {
        $connectCount=[Runtime.CompilerServices.StrongBox[int]]::new(0)
        $blockedConnector={param($address,$targetPort,$token)$connectCount.Value++;throw 'SYNTHETIC_UNEXPECTED_CONNECT'}.GetNewClosure()
        foreach ($case in $cases | Where-Object {-not $_.Valid}) {
            $calls.Value=0
            $valueBox=[Runtime.CompilerServices.StrongBox[object[]]]::new([object[]]$case.Values)
            $resolver={param($hostName,$token)
                $calls.Value++
                $completion=[Threading.Tasks.TaskCompletionSource[object[]]]::new()
                $completion.SetResult($valueBox.Value)
                $completion.Task
            }.GetNewClosure()
            Check-Connection ($case.Name+' transport rejects snapshot before dispatch') (Error-Connection {
                & $transportModule {param($secret,$resolver,$connector)Invoke-LabAiExternalModelHttpTransport -Location 'https://localhost:18443/v1/embeddings' -ExpectedServerCertificateSha256 ('a'*64) -Request @{Method='POST';TimeoutSeconds=2;RuntimeModel='synthetic'} -ApiKey $secret -Resolver $resolver -Connector $connector} $secret $resolver $blockedConnector
            } 'AI_EXTERNAL_MODEL_DNS_SNAPSHOT_INVALID' $null)
            Check-Connection ($case.Name+' transport resolves once without connect or key') ($calls.Value -eq 1 -and $connectCount.Value -eq 0 -and $openCount.Value -eq 0)
        }
        $late=[Threading.Tasks.TaskCompletionSource[object[]]]::new()
        $lateResolver={param($hostName,$token)$late.Task}.GetNewClosure()
        Check-Connection 'Transport DNS wait expires under the sole request deadline' (Error-Connection {
            & $transportModule {param($secret,$resolver,$connector)Invoke-LabAiExternalModelHttpTransport -Location 'https://localhost:18443/v1/embeddings' -ExpectedServerCertificateSha256 ('a'*64) -Request @{Method='POST';TimeoutSeconds=1;RuntimeModel='synthetic'} -ApiKey $secret -Resolver $resolver -Connector $connector} $secret $lateResolver $blockedConnector
        } 'AI_EXTERNAL_MODEL_ENDPOINT_TIMEOUT' $null)
        $late.SetResult([object[]]@([Net.IPAddress]::Loopback))
        Check-Connection 'Late DNS completion cannot trigger later connection or key work' ($connectCount.Value -eq 0 -and $openCount.Value -eq 0)
        $calls.Value=0
        $bothLoopback={param($hostName,$token)
            $calls.Value++
            $completion=[Threading.Tasks.TaskCompletionSource[object[]]]::new()
            $completion.SetResult([object[]]@([Net.IPAddress]::IPv6Loopback,[Net.IPAddress]::Loopback))
            $completion.Task
        }.GetNewClosure()
        Check-Connection 'Connector failure has a fixed sanitized failure' (Error-Connection {
            & $transportModule {param($secret,$resolver,$connector)Invoke-LabAiExternalModelHttpTransport -Location 'https://localhost:18443/v1/embeddings' -ExpectedServerCertificateSha256 ('a'*64) -Request @{Method='POST';TimeoutSeconds=2;RuntimeModel='synthetic'} -ApiKey $secret -Resolver $resolver -Connector $connector} $secret $bothLoopback $blockedConnector
        } 'AI_EXTERNAL_MODEL_ENDPOINT_NETWORK_FAILURE' $null)
        Check-Connection 'Connector failure never tries the second address' ($calls.Value -eq 1 -and $connectCount.Value -eq 1 -and $openCount.Value -eq 0)
        Check-Connection 'Wrong native port fails before request and key' (Error-Connection {
            & $transportModule {param($port,$secret,$connector)Invoke-LabAiExternalModelHttpTransport -Location "https://127.0.0.1:$port/v1/embeddings" -ExpectedServerCertificateSha256 ('a'*64) -Request @{Method='POST';TimeoutSeconds=2;Body=@{model='synthetic'}} -ApiKey $secret -Connector $connector} $expectedPort $secret $connector
        } 'AI_EXTERNAL_MODEL_PEER_MISMATCH' $null)
        Check-Connection 'Wrong peer causes no key conversion' ($openCount.Value -eq 0)
        Check-Connection 'Wrong peer closes only caller-owned client' (-not $tcp.Connected)
        $accepted.GetStream().ReadTimeout=1000
        Check-Connection 'Wrong peer transmits no application bytes' ($accepted.GetStream().ReadByte() -eq -1)
    } finally {Remove-Module $transportModule -Force -ErrorAction SilentlyContinue}
    $validator=[SqlServerLab.AiExternalModelCertificateValidatorV1]::new(('a'*64),$null)
    $tls=& $Module {param($v)New-LabAiExternalModelTlsCallback -Validator $v} $validator
    Check-Connection 'TLS adapter retains missing-certificate failure' (-not $tls.Invoke($null,$null,$null,[Net.Security.SslPolicyErrors]::RemoteCertificateNotAvailable) -and $validator.FailureCode -ceq 'AI_EXTERNAL_MODEL_TLS_CERTIFICATE_MISSING')
}
finally {
    foreach($message in $messages){$message.Dispose()}
    foreach($stream in $streams){$stream.Dispose()}
    if($accepted){$accepted.Dispose()};if($tcp){$tcp.Dispose()};if($listener){$listener.Stop()}
    if($secret){$secret.Dispose()};if($cancelled){$cancelled.Dispose()};$cts.Dispose()
    if($ownModule){Remove-Module $ownModule -Force -ErrorAction SilentlyContinue}
}
Write-Host ('EXTERNAL_MODEL_CONNECTION_CHECKS: '+$connectionPassed+' PASS; synthetic DNS, CLR worker, own numeric TCP; TLS/HTTP/SQL/provider NOT_EXECUTED; own resources disposed')
$true
