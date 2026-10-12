# Read-only binding and short-lived loopback WebMail handoff for a run-scoped
# Mailpit receiver.  The UI password is deliberately never part of the DTO.
function Get-LabSmtpTestServiceWebMailBinding {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunId,[string]$StateRoot)

    if ($RunId -notmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') { throw 'SMTP_WEBMAIL_RUN_INVALID' }
    $root = Get-LabStateRoot -ExplicitPath $StateRoot
    $run = Get-LabRunState -RunId $RunId -StateRoot $root
    $runDirectory = Join-Path (Join-Path $root 'runs') $RunId
    $connectionPath = Join-Path $runDirectory 'connection-info.json'
    if (-not (Test-Path -LiteralPath $connectionPath -PathType Leaf)) { throw 'SMTP_WEBMAIL_NOT_CONFIGURED' }
    $connection = Get-Content -LiteralPath $connectionPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 20
    $service = $connection.smtpTestService
    if ($null -eq $service -or $service.ServiceId -isnot [string] -or $service.ServiceId -cnotmatch '^[a-z][a-z0-9-]{0,31}$' -or
        $service.Receiver.Host -cne '127.0.0.1' -or [int]$service.Receiver.Port -lt 1 -or [int]$service.Receiver.Port -gt 65535) { throw 'SMTP_WEBMAIL_NOT_CONFIGURED' }
    $providers = @($run.providerSubRuns | ForEach-Object { [string]$_.provider } | Select-Object -Unique)
    if ($providers.Count -ne 1 -or $providers[0] -cnotin @('docker','podman')) { throw 'SMTP_WEBMAIL_SCOPE_UNSUPPORTED' }
    $journalPath = Join-Path (Join-Path $runDirectory 'smtp-test-service') (([string]$run.scopeId)+'-'+([string]$service.ServiceId)+'.json')
    if (-not (Test-Path -LiteralPath $journalPath -PathType Leaf)) { throw 'SMTP_WEBMAIL_JOURNAL_MISSING' }
    $journal = Get-Content -LiteralPath $journalPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 20
    if ($journal.ContractVersion -cne 'SqlServerLab.SmtpTestServiceJournal/1.0' -or $journal.Status -cne 'READY' -or
        $journal.RunId -cne $RunId -or $journal.ScopeId -cne [string]$run.scopeId -or $journal.Provider -cne $providers[0] -or
        $journal.ServiceId -cne [string]$service.ServiceId -or $journal.Resources.ReceiverContainerName -isnot [string]) { throw 'SMTP_WEBMAIL_BINDING_INVALID' }
    [pscustomobject]@{ RunId=$RunId; ScopeId=[string]$run.scopeId; RunState=[string]$run.state; StateRoot=$root; RunDirectory=$runDirectory
        Provider=$providers[0]; ServiceId=[string]$service.ServiceId; ReceiverPort=[int]$service.Receiver.Port; ReceiverContainerName=[string]$journal.Resources.ReceiverContainerName
        ReceiverContainerId=[string]$journal.Resources.ReceiverContainerId; SenderInstanceIds=@($service.SenderInstanceIds | ForEach-Object {[string]$_}) }
}

function Get-LabSmtpTestServiceWebMailRuntimeStatus {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Binding)
    $status = [pscustomobject][ordered]@{ Status='UNAVAILABLE'; ReceiverStatus='UNAVAILABLE'; GatewayStatus='NOT_OBSERVED'; Reason='SMTP_WEBMAIL_RUNTIME_UNAVAILABLE' }
    try {
        $result = Invoke-LabSmtpRuntime -Provider $Binding.Provider -StateRoot $Binding.StateRoot -RunId $Binding.RunId -Arguments @('inspect',$Binding.ReceiverContainerName)
        $items = @((($result.Output -join "`n") | ConvertFrom-Json -Depth 30))
        if ($items.Count -ne 1) { throw 'SMTP_WEBMAIL_RUNTIME_UNAVAILABLE' }
        $item = $items[0]; $labels = $item.Config.Labels; $ports = @($item.NetworkSettings.Ports.'8025/tcp')
        if ([string]$item.Id -cne $Binding.ReceiverContainerId -or [string]$labels.'sql-server-lab.run-id' -cne $Binding.RunId -or
            [string]$labels.'sql-server-lab.scope-id' -cne $Binding.ScopeId -or [string]$labels.'sql-server-lab.smtp-service-id' -cne $Binding.ServiceId -or
            $ports.Count -ne 1 -or [string]$ports[0].HostIp -cne '127.0.0.1' -or [int]$ports[0].HostPort -ne $Binding.ReceiverPort) { throw 'SMTP_WEBMAIL_RUNTIME_BINDING_INVALID' }
        if ($item.State.Running -eq $true) { $status.Status='READY'; $status.ReceiverStatus='RUNNING'; $status.Reason='NONE' }
        else { $status.Status='STOPPED'; $status.ReceiverStatus='STOPPED'; $status.Reason='SMTP_WEBMAIL_RECEIVER_STOPPED' }
    } catch {
        $code=[string]$_.Exception.Message
        if ($code -in @('SMTP_WEBMAIL_RUNTIME_BINDING_INVALID','SMTP_WEBMAIL_RUNTIME_UNAVAILABLE')) { $status.Reason=$code }
    }
    $status
}

function Start-LabSmtpTestServiceWebMailProxy {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Binding,[Parameter(Mandatory)][ValidateRange(1,60)][int]$LifetimeMinutes)
    if (-not $script:SmtpTestServiceWebMailJobs) { $script:SmtpTestServiceWebMailJobs = @{} }
    foreach($key in @($script:SmtpTestServiceWebMailJobs.Keys)) { if ($script:SmtpTestServiceWebMailJobs[$key].State -notin @('Running','NotStarted')) { Remove-Job -Job $script:SmtpTestServiceWebMailJobs[$key] -Force -ErrorAction SilentlyContinue; $script:SmtpTestServiceWebMailJobs.Remove($key) } }
    $port = Invoke-LabPortAllocationLock -Action { Find-LabAvailablePort -RangeStart 18125 -RangeEnd 18224 }
    $launchToken = [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(32)).ToLowerInvariant()
    $sessionToken = [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(32)).ToLowerInvariant()
    $job = Start-ThreadJob -Name ('sql-lab-smtp-webmail-'+$Binding.RunId.Substring(0,8)) -ArgumentList $script:ModuleRoot,$Binding.RunDirectory,$Binding.ServiceId,$Binding.ReceiverPort,$port,$launchToken,$sessionToken,$LifetimeMinutes -ScriptBlock {
        param($moduleRoot,$runDirectory,$serviceId,$receiverPort,$proxyPort,$launchToken,$sessionToken,$lifetimeMinutes)
        $ErrorActionPreference='Stop'; $loaded=Import-Module (Join-Path $moduleRoot 'SqlServerLab.psd1') -Force -PassThru 6>$null
        $secret=& $loaded {param($path,$name)Get-LabSecret -Path $path -Name $name} $runDirectory ('smtp-'+$serviceId+'-ui-password')
        if ($null -eq $secret) { throw 'SMTP_WEBMAIL_SECRET_UNAVAILABLE' }
        $plain=& $loaded {param($value)ConvertFrom-LabSecureString -SecureString $value} $secret
        $listener=[Net.HttpListener]::new(); $listener.Prefixes.Add(('http://127.0.0.1:'+$proxyPort+'/')); $listener.Start()
        Write-Output ([pscustomobject]@{Ready=$true;Url=('http://127.0.0.1:'+$proxyPort+'/launch/'+$launchToken);ExpiresAt=(Get-Date).ToUniversalTime().AddMinutes($lifetimeMinutes).ToString('o')})
        $until=[datetime]::UtcNow.AddMinutes($lifetimeMinutes)
        try {
            while($listener.IsListening -and [datetime]::UtcNow -lt $until) {
                $pending=$listener.BeginGetContext($null,$null)
                if(-not $pending.AsyncWaitHandle.WaitOne(500)){continue}
                $context=$listener.EndGetContext($pending); $request=$context.Request; $response=$context.Response
                try {
                    $path=[string]$request.Url.AbsolutePath
                    if($path -eq ('/launch/'+$launchToken)) { $response.StatusCode=302; $response.RedirectLocation='/'; $response.AppendCookie([Net.Cookie]::new('sql_lab_smtp_webmail',$sessionToken,'/','127.0.0.1')); $response.Close(); continue }
                    $cookie=$request.Cookies['sql_lab_smtp_webmail']
                    if($null -eq $cookie -or $cookie.Value -cne $sessionToken) { $response.StatusCode=403; $response.Close(); continue }
                    if($request.HttpMethod -cnotin @('GET','HEAD','DELETE')) { $response.StatusCode=405; $response.Close(); continue }
                    if($path -notmatch '^/' -or $path.StartsWith('//') -or $path.Contains('\')) { $response.StatusCode=400; $response.Close(); continue }
                    $target=[Uri]::new('http://127.0.0.1:'+$receiverPort+$request.RawUrl)
                    $handler=[Net.Http.SocketsHttpHandler]::new();$handler.UseProxy=$false;$handler.AllowAutoRedirect=$false;$handler.UseCookies=$false
                    $client=[Net.Http.HttpClient]::new($handler,$true);$client.Timeout=[TimeSpan]::FromSeconds(15)
                    $out=[Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::new($request.HttpMethod),$target)
                    $auth=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('smtp-reader:'+$plain));$out.Headers.Authorization=[Net.Http.Headers.AuthenticationHeaderValue]::new('Basic',$auth)
                    $upstream=$client.Send($out,[Net.Http.HttpCompletionOption]::ResponseHeadersRead);$response.StatusCode=[int]$upstream.StatusCode
                    foreach($header in $upstream.Headers){ if($header.Key -notin @('Connection','Transfer-Encoding','Keep-Alive','Proxy-Authenticate','Proxy-Authorization','TE','Trailer','Upgrade','Set-Cookie')){$response.Headers[$header.Key]=$header.Value -join ','} }
                    foreach($header in $upstream.Content.Headers){ if($header.Key -notin @('Content-Length','Transfer-Encoding')){$response.Headers[$header.Key]=$header.Value -join ','} }
                    if($request.HttpMethod -ne 'HEAD'){ $stream=$upstream.Content.ReadAsStream(); try{$stream.CopyTo($response.OutputStream)}finally{$stream.Dispose()} }
                    $upstream.Dispose();$out.Dispose();$response.Close()
                } catch { try{$response.StatusCode=502;$response.Close()}catch{} }
            }
        } finally { $plain=$null; $secret.Dispose(); $listener.Stop();$listener.Close() }
    }
    $deadline=(Get-Date).AddSeconds(20);$ready=$null
    while((Get-Date)-lt$deadline -and $job.State -in @('NotStarted','Running')) { $ready=@(Receive-Job -Job $job -Keep -ErrorAction SilentlyContinue | Where-Object {$_.Ready}) | Select-Object -First 1; if($ready){break}; Start-Sleep -Milliseconds 100 }
    if(-not $ready){Remove-Job -Job $job -Force -ErrorAction SilentlyContinue;throw 'SMTP_WEBMAIL_PROXY_START_FAILED'}
    $script:SmtpTestServiceWebMailJobs[$job.Id]=$job
    [pscustomobject]@{Url=$ready.Url;ExpiresAt=$ready.ExpiresAt;JobId=$job.Id}
}
