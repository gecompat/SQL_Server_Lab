# Privater Raw-MIME-Transport. Kein Eigentumsnachweis und keine öffentliche SMTP-API.
# Ein zukünftiger Core-Aufrufer muss die echte Komponenten-/CID-/Runtime-/Portbindung
# vor Credentials und nach dem Read erneut prüfen. Typisierte Eingaben ersetzen das nicht.
# Mailpit ccb524a62b3a14b6a3fd55c1275a16945d10e36b: DownloadRaw/GetMessageRaw.
# Der Body bleibt binär; GetMessageRaw aktualisiert dbLastAction, setzt aber kein Read-Marker.
# Einmaliger CLR-Streamhandoff nach dem bestehenden AiExternalModel-Transportmuster.

function New-LabSmtpReceiverExpressionNode {
    param([Reflection.ConstructorInfo]$Constructor, [Linq.Expressions.Expression[]]$Arguments)
    # PowerShell reserves Type::new, including Expression.New's factory name.
    $factory = [Linq.Expressions.Expression].GetMethod('New', [type[]]@([Reflection.ConstructorInfo],[Linq.Expressions.Expression[]]))
    return $factory.Invoke($null, [object[]]@($Constructor,$Arguments))
}

function Read-LabSmtpTestServiceReceiverRaw {
    [CmdletBinding()]
    param([object]$NumericLoopbackAddress, [object]$NumericLoopbackPort,
        [object]$OpaqueMessageId, [object]$UiCredential)

    # Auch vorhandene Credentials können bereits freigegeben sein: Getterfehler
    # bleiben vor jeder Wirkung unter derselben festen Input-Fehlergrenze.
    try {
        if ($NumericLoopbackAddress -isnot [Net.IPAddress] -or
        -not [Net.IPAddress]::IsLoopback($NumericLoopbackAddress) -or
        ($NumericLoopbackAddress.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetworkV6 -and $NumericLoopbackAddress.ScopeId -ne 0) -or
        $NumericLoopbackPort -isnot [int] -or $NumericLoopbackPort -lt 1 -or $NumericLoopbackPort -gt 65535 -or
        $OpaqueMessageId -isnot [string] -or $OpaqueMessageId.Length -ne 22 -or
        $OpaqueMessageId -cnotmatch '\A[0-9A-Za-z]{22}\z' -or
        $UiCredential -isnot [Management.Automation.PSCredential] -or
        $UiCredential.UserName -cnotmatch '\A[0-9A-Za-z_-]{1,64}\z' -or
        $UiCredential.Password.Length -lt 1 -or $UiCredential.Password.Length -gt 256) {
            throw [InvalidOperationException]::new('SMTP_RECEIVER_INPUT_INVALID')
        }
    } catch {
        throw [InvalidOperationException]::new('SMTP_RECEIVER_INPUT_INVALID')
    }

    $limit = 8388608 # Raw-MIME-Grenze; unabhängig von der SMTP-DATA-Config.
    $tcp = $null; $network = $null; $handler = $null; $client = $null
    $request = $null; $response = $null; $body = $null; $cts = $null; $connectTask = $null
    $scratch = $null; $output = $null; $result = $null; $authBytes = $null
    $password = $null; $authorization = $null; $secretPointer = [IntPtr]::Zero
    $code = 'SMTP_RECEIVER_NETWORK_FAILURE'; $primary = $null; $cleanupFailed = $false
    $success = $false; $clock = [Diagnostics.Stopwatch]::StartNew()
    try {
        $cts = [Threading.CancellationTokenSource]::new(10000)
        $tcp = [Net.Sockets.TcpClient]::new($NumericLoopbackAddress.AddressFamily)
        # TcpClient bleibt auch bei einer späten Connect-Vervollständigung in eigener Custody.
        $connectTask = $tcp.ConnectAsync($NumericLoopbackAddress,$NumericLoopbackPort,$cts.Token).AsTask()
        $connectTask.GetAwaiter().GetResult() | Out-Null
        $cts.Token.ThrowIfCancellationRequested()
        $peer = $tcp.Client.RemoteEndPoint
        if ($peer -isnot [Net.IPEndPoint] -or -not $peer.Address.Equals($NumericLoopbackAddress) -or
            $peer.Port -ne $NumericLoopbackPort) {
            $code = 'SMTP_RECEIVER_PEER_INVALID'; throw [InvalidOperationException]::new($code)
        }
        $network = $tcp.GetStream()
        $hostPart = $NumericLoopbackAddress.ToString()
        if ($NumericLoopbackAddress.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetworkV6) { $hostPart = '['+$hostPart+']' }
        $uri = [Uri]::new('http://'+$hostPart+':'+$NumericLoopbackPort+'/api/v1/message/'+$OpaqueMessageId+'/raw')
        $handler = [Net.Http.SocketsHttpHandler]::new()
        $handler.UseProxy = $false; $handler.AllowAutoRedirect = $false; $handler.UseCookies = $false
        $handler.Credentials = $null; $handler.PreAuthenticate = $false
        $handler.AutomaticDecompression = [Net.DecompressionMethods]::None
        $handler.MaxResponseHeadersLength = 16 # KiB; native HTTP-Parsergrenze.
        $handler.MaxResponseDrainSize = 0
        $handler.ResponseDrainTimeout = [TimeSpan]::Zero
        $handler.ConnectCallback = New-LabSmtpReceiverConnectCallback -Uri $uri -Stream $network
        $client = [Net.Http.HttpClient]::new($handler,$false)
        $client.Timeout = [Threading.Timeout]::InfiniteTimeSpan
        $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get,$uri)
        $request.Version = [Version]::new(1,1)
        $request.VersionPolicy = [Net.Http.HttpVersionPolicy]::RequestVersionExact
        $request.Headers.ConnectionClose = $true
        $request.Headers.AcceptEncoding.ParseAdd('identity')
        $cts.Token.ThrowIfCancellationRequested()
        # Erst nach Input-/Peerprüfung öffnen; Strings lassen sich nicht physisch löschen.
        $secretPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($UiCredential.Password)
        $password = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($secretPointer)
        if ($password.IndexOfAny([char[]]@([char]0,[char]10,[char]13)) -ge 0) {
            $code = 'SMTP_RECEIVER_INPUT_INVALID'; throw [InvalidOperationException]::new($code)
        }
        $authBytes = [Text.Encoding]::UTF8.GetBytes($UiCredential.UserName+':'+$password)
        $authorization = [Convert]::ToBase64String($authBytes)
        $request.Headers.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new('Basic',$authorization)
        $cts.Token.ThrowIfCancellationRequested()
        $response = $client.SendAsync($request,[Net.Http.HttpCompletionOption]::ResponseHeadersRead,$cts.Token).GetAwaiter().GetResult()
        $cts.Token.ThrowIfCancellationRequested()
        if ([int]$response.StatusCode -ne 200) {
            $code = 'SMTP_RECEIVER_HTTP_STATUS_INVALID'; throw [InvalidOperationException]::new($code)
        }
        $type = $response.Content.Headers.ContentType
        if ($null -eq $type -or -not [string]::Equals($type.MediaType,'text/plain',[StringComparison]::OrdinalIgnoreCase) -or
            @($response.Content.Headers.ContentEncoding | Where-Object { -not [string]::Equals($_,'identity',[StringComparison]::OrdinalIgnoreCase) }).Count -ne 0) {
            $code = 'SMTP_RECEIVER_RESPONSE_INVALID'; throw [InvalidOperationException]::new($code)
        }
        $length = $response.Content.Headers.ContentLength
        if ($null -ne $length -and ($length -lt 0 -or $length -gt $limit)) {
            $code = 'SMTP_RECEIVER_OUTPUT_LIMIT'; throw [InvalidOperationException]::new($code)
        }
        $body = $response.Content.ReadAsStreamAsync($cts.Token).GetAwaiter().GetResult()
        $scratch = [byte[]]::new(65536); $output = [IO.MemoryStream]::new()
        while ($true) {
            $count = $body.ReadAsync($scratch,0,$scratch.Length,$cts.Token).GetAwaiter().GetResult()
            $cts.Token.ThrowIfCancellationRequested()
            if ($count -eq 0) { break }
            if ($output.Length + $count -gt $limit) {
                $code = 'SMTP_RECEIVER_OUTPUT_LIMIT'; throw [InvalidOperationException]::new($code)
            }
            $output.Write($scratch,0,$count)
        }
        if ($null -ne $length -and $output.Length -ne $length) {
            $code = 'SMTP_RECEIVER_RESPONSE_INVALID'; throw [InvalidOperationException]::new($code)
        }
        $cts.Token.ThrowIfCancellationRequested()
        $result = $output.ToArray(); $success = $true
    } catch {
        if ($null -ne $cts -and $cts.IsCancellationRequested) { $code = 'SMTP_RECEIVER_DEADLINE_EXCEEDED' }
        $primary = [InvalidOperationException]::new($code)
    } finally {
        if ($null -ne $connectTask -and -not $connectTask.IsCompleted) { $cleanupFailed = $true }
        if ($null -ne $request) { try { $request.Headers.Authorization = $null } catch { $cleanupFailed = $true } }
        if ($secretPointer -ne [IntPtr]::Zero) { try { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($secretPointer) } catch { $cleanupFailed = $true } }
        $password = $null; $authorization = $null; $peer = $null; $type = $null
        foreach ($buffer in @($scratch,$authBytes)) {
            if ($null -ne $buffer) { try { [Array]::Clear($buffer,0,$buffer.Length) } catch { $cleanupFailed = $true } }
        }
        if ($null -ne $output) {
            try { $segment = [Activator]::CreateInstance([ArraySegment[byte]])
                if ($output.TryGetBuffer([ref]$segment)) { [Array]::Clear($segment.Array,$segment.Offset,$segment.Count) }
                $segment = $null
            } catch { $cleanupFailed = $true }
        }
        # Jeder Dispose bleibt unabhängig erreichbar; ein Fehler vetoisiert die Ausgabe.
        foreach ($resource in @($body,$response,$request,$client,$handler,$network,$tcp,$output,$cts)) {
            if ($null -ne $resource) { try { $resource.Dispose() } catch { $cleanupFailed = $true } }
        }
        $scratch = $null; $authBytes = $null; $body = $null; $response = $null; $request = $null
        $client = $null; $handler = $null; $network = $null; $tcp = $null; $output = $null; $cts = $null; $connectTask = $null
    }
    if ($clock.ElapsedMilliseconds -ge 10000) {
        $success = $false; $primary = [InvalidOperationException]::new('SMTP_RECEIVER_DEADLINE_EXCEEDED')
    }
    $clock.Stop()
    if (-not $success -or $cleanupFailed) {
        if ($null -ne $result) { [Array]::Clear($result,0,$result.Length); $result = $null }
        if ($null -eq $primary) { $primary = [InvalidOperationException]::new('SMTP_RECEIVER_CLEANUP_FAILURE') }
        try { $primary.Data['SmtpReceiverCleanupConfirmed'] = -not $cleanupFailed
            $primary.Data['SmtpReceiverRecoveryRequired'] = $cleanupFailed } catch { }
        throw $primary
    }
    # Genau ein Payload-Owner: der private Aufrufer übernimmt und löscht die Rückgabe.
    Write-Output -NoEnumerate $result
}

function New-LabSmtpReceiverConnectCallback {
    [CmdletBinding()]
    param([Parameter(Mandatory)][Uri]$Uri, [Parameter(Mandatory)][IO.Stream]$Stream)

    # This CLR-only callback can run without a PowerShell runspace. Caller
    # retains independent stream/socket disposal custody even after handoff.
    $box = [Runtime.CompilerServices.StrongBox[IO.Stream]]::new($Stream)
    $context = [Linq.Expressions.Expression]::Parameter([Net.Http.SocketsHttpConnectionContext],'context')
    $cancel = [Linq.Expressions.Expression]::Parameter([Threading.CancellationToken],'cancel')
    $localStream = [Linq.Expressions.Expression]::Variable([IO.Stream],'stream')
    $endpoint = [Linq.Expressions.Expression]::Property($context,'DnsEndPoint')
    $request = [Linq.Expressions.Expression]::Property($context,'InitialRequestMessage')
    $requestUri = [Linq.Expressions.Expression]::Property($request,'RequestUri')
    $equals = [string].GetMethod('Equals',[type[]]@([string],[string],[StringComparison]))
    $hostMatch = [Linq.Expressions.Expression]::Call($equals,[Linq.Expressions.Expression[]]@(
        [Linq.Expressions.Expression]::Property($endpoint,'Host'),[Linq.Expressions.Expression]::Constant($Uri.IdnHost),
        [Linq.Expressions.Expression]::Constant([StringComparison]::OrdinalIgnoreCase)))
    if ($Uri.HostNameType -eq [UriHostNameType]::IPv6) {
        # .NET 6 HttpAuthority preserves IPv6 brackets while Uri.IdnHost
        # omits them. Permit only these two exact forms for this same URI.
        $bracketedHostMatch = [Linq.Expressions.Expression]::Call($equals,[Linq.Expressions.Expression[]]@(
            [Linq.Expressions.Expression]::Property($endpoint,'Host'),[Linq.Expressions.Expression]::Constant('['+$Uri.IdnHost+']'),
            [Linq.Expressions.Expression]::Constant([StringComparison]::OrdinalIgnoreCase)))
        $hostMatch = [Linq.Expressions.Expression]::OrElse($hostMatch,$bracketedHostMatch)
    }
    $portMatch = [Linq.Expressions.Expression]::Equal([Linq.Expressions.Expression]::Property($endpoint,'Port'),[Linq.Expressions.Expression]::Constant($Uri.Port))
    $authority = [Linq.Expressions.Expression]::Call($requestUri,[Uri].GetMethod('GetLeftPart',[type[]]@([UriPartial])),[Linq.Expressions.Expression]::Constant([UriPartial]::Authority))
    $uriMatch = [Linq.Expressions.Expression]::Call($equals,[Linq.Expressions.Expression[]]@($authority,
        [Linq.Expressions.Expression]::Constant($Uri.GetLeftPart([UriPartial]::Authority)),[Linq.Expressions.Expression]::Constant([StringComparison]::Ordinal)))
    $matching = [Linq.Expressions.Expression]::AndAlso(
        [Linq.Expressions.Expression]::NotEqual($endpoint,[Linq.Expressions.Expression]::Constant($null,[Net.DnsEndPoint])),
        [Linq.Expressions.Expression]::AndAlso([Linq.Expressions.Expression]::NotEqual($request,[Linq.Expressions.Expression]::Constant($null,[Net.Http.HttpRequestMessage])),
        [Linq.Expressions.Expression]::AndAlso([Linq.Expressions.Expression]::NotEqual($requestUri,[Linq.Expressions.Expression]::Constant($null,[Uri])),
        [Linq.Expressions.Expression]::AndAlso($hostMatch,[Linq.Expressions.Expression]::AndAlso($portMatch,$uriMatch)))))
    $exception = New-LabSmtpReceiverExpressionNode ([InvalidOperationException].GetConstructor([type[]]@([string]))) `
        ([Linq.Expressions.Expression[]]@([Linq.Expressions.Expression]::Constant('SMTP_RECEIVER_HANDOFF_REQUIRED')))
    $failure = [Linq.Expressions.Expression]::Throw($exception)
    $cancelGuard = [Linq.Expressions.Expression]::Call($cancel,[Threading.CancellationToken].GetMethod('ThrowIfCancellationRequested'))
    $guard = [Linq.Expressions.Expression]::IfThen([Linq.Expressions.Expression]::Not($matching),$failure)
    $exchange = @([Threading.Interlocked].GetMethods() | Where-Object {$_.Name -eq 'Exchange' -and $_.IsGenericMethodDefinition})[0].MakeGenericMethod([IO.Stream])
    $consume = [Linq.Expressions.Expression]::Assign($localStream,[Linq.Expressions.Expression]::Call($exchange,[Linq.Expressions.Expression[]]@(
        [Linq.Expressions.Expression]::Field([Linq.Expressions.Expression]::Constant($box),'Value'),[Linq.Expressions.Expression]::Constant($null,[IO.Stream]))))
    $once = [Linq.Expressions.Expression]::IfThen([Linq.Expressions.Expression]::Equal($localStream,[Linq.Expressions.Expression]::Constant($null,[IO.Stream])),$failure)
    $output = New-LabSmtpReceiverExpressionNode ([Threading.Tasks.ValueTask[IO.Stream]].GetConstructor([type[]]@([IO.Stream]))) ([Linq.Expressions.Expression[]]@($localStream))
    $body = [Linq.Expressions.Expression]::Block([Linq.Expressions.ParameterExpression[]]@($localStream),[Linq.Expressions.Expression[]]@($cancelGuard,$guard,$consume,$once,$output))
    return [Linq.Expressions.Expression]::Lambda([Net.Http.SocketsHttpHandler].GetProperty('ConnectCallback').PropertyType,
        $body,[Linq.Expressions.ParameterExpression[]]@($context,$cancel)).Compile()
}
