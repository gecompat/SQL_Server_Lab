#Requires -Version 7.2
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText','',Justification='Ausschliesslich festes synthetisches Fixture-Secret innerhalb des isolierten Offline-Checks.')]
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repoRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$root=Join-Path ([IO.Path]::GetTempPath()) ('smtp-webmail-'+[guid]::NewGuid().ToString('N'))
$runId='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';$scopeId='bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';$serviceId='smtp'
$module=Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru
try {
    $runDirectory=Join-Path (Join-Path $root 'runs') $runId;New-Item -ItemType Directory -Path (Join-Path $runDirectory 'smtp-test-service') -Force|Out-Null
    [pscustomobject]@{runId=$runId;scopeId=$scopeId;state='RUNNING';metadata=@{name='SMTP fixture'};providerSubRuns=@([pscustomobject]@{provider='docker'})}|ConvertTo-Json -Depth 8|Set-Content (Join-Path $runDirectory 'run-state.json') -Encoding utf8
    [pscustomobject]@{smtpTestService=[pscustomobject]@{ServiceId=$serviceId;SenderInstanceIds=@('primary');Receiver=[pscustomobject]@{Host='127.0.0.1';Port=18025}}}|ConvertTo-Json -Depth 8|Set-Content (Join-Path $runDirectory 'connection-info.json') -Encoding utf8
    [pscustomobject]@{ContractVersion='SqlServerLab.SmtpTestServiceJournal/1.0';Status='READY';RunId=$runId;ScopeId=$scopeId;Provider='docker';ServiceId=$serviceId;Resources=[pscustomobject]@{ReceiverContainerName='receiver';ReceiverContainerId='receiver-id'}}|ConvertTo-Json -Depth 8|Set-Content (Join-Path (Join-Path $runDirectory 'smtp-test-service') ($scopeId+'-'+$serviceId+'.json')) -Encoding utf8
    & $module {param($path,$name)$secret=ConvertTo-SecureString 'synthetic-password' -AsPlainText -Force;try{Save-LabSecret -Path $path -Name $name -Secret $secret}finally{$secret.Dispose()}} $runDirectory ('smtp-'+$serviceId+'-ui-password')
    $inspect=[pscustomobject]@{Id='receiver-id';Config=[pscustomobject]@{Labels=[pscustomobject]@{'sql-server-lab.run-id'=$runId;'sql-server-lab.scope-id'=$scopeId;'sql-server-lab.smtp-service-id'=$serviceId}};NetworkSettings=[pscustomobject]@{Ports=[pscustomobject]@{'8025/tcp'=@([pscustomobject]@{HostIp='127.0.0.1';HostPort=18025})}};State=[pscustomobject]@{Running=$true}}|ConvertTo-Json -Depth 12 -Compress
    & $module {param($json)Set-Item -Path function:Invoke-LabSmtpRuntime -Value {param($Provider,$StateRoot,$RunId,$Arguments)[pscustomobject]@{ExitCode=0;Output=@($json)}}.GetNewClosure()} $inspect
    $status=Get-SqlServerLabSmtpTestServiceStatus -RunId $runId -StateRoot $root
    $guided = & $module {
        param($path,$target)
        function Get-LabStateRoot { param($ExplicitPath) if ($ExplicitPath) { $ExplicitPath } else { $path } }
        function Select-LabConsoleDataItem { param($ScreenId,$Title,$Items) $Items[0].Data }
        function Wait-LabConsoleAcknowledgement {}
        $listing = Get-LabSmtpStatusGuidance -StateRoot $path
        $receipt = Get-LabSmtpStatusGuidance -StateRoot $path -RunId $target
        $console = @(Invoke-LabMenuAction -ActionName SmtpStatusGuidance 6>&1) -join [Environment]::NewLine
        $query = [Collections.Specialized.NameValueCollection]::new()
        $httpList = Invoke-LabSmtpStatusGuidanceRequest -Method GET -Query $query
        $query.Add('runId',$target)
        $httpStatus = Invoke-LabSmtpStatusGuidanceRequest -Method GET -Query $query
        $httpPost = Invoke-LabSmtpStatusGuidanceRequest -Method POST -Query $query
        $query.Add('runId',$target)
        $httpDuplicate = Invoke-LabSmtpStatusGuidanceRequest -Method GET -Query $query
        $stale = try {
            Get-LabSmtpStatusGuidance -StateRoot $path -RunId 'dddddddd-dddd-dddd-dddd-dddddddddddd' | Out-Null
            $false
        } catch { $_.Exception.Message -ceq 'SMTP_STATUS_SELECTION_UNAVAILABLE' }
        [pscustomobject]@{Listing=$listing; Receipt=$receipt; Console=$console; StaleBlocked=$stale
            HttpList=$httpList; HttpStatus=$httpStatus; HttpPost=$httpPost.StatusCode; HttpDuplicate=$httpDuplicate.StatusCode}
    } $root $runId
    $binding=& $module {param($id,$state)Get-LabSmtpTestServiceWebMailBinding -RunId $id -StateRoot $state} $runId $root
    $wrongScope=$false;$wrong=$inspect.Replace($scopeId,'cccccccc-cccc-cccc-cccc-cccccccccccc')
    & $module {param($json)Set-Item -Path function:Invoke-LabSmtpRuntime -Value {param($Provider,$StateRoot,$RunId,$Arguments)[pscustomobject]@{ExitCode=0;Output=@($json)}}.GetNewClosure()} $wrong
    $wrongStatus=Get-SqlServerLabSmtpTestServiceStatus -RunId $runId -StateRoot $root
    & $module {param($json)Set-Item -Path function:Invoke-LabSmtpRuntime -Value {param($Provider,$StateRoot,$RunId,$Arguments)[pscustomobject]@{ExitCode=0;Output=@($json)}}.GetNewClosure()} $inspect
    $access=Open-SqlServerLabSmtpTestServiceWebMail -RunId $runId -StateRoot $root -NoBrowser -Confirm:$false -LifetimeMinutes 1
    Start-Sleep -Milliseconds 1300
    $httpSettings = [Net.Http.HttpClientHandler]::new()
    $httpSettings.AllowAutoRedirect = $false
    $httpSettings.UseProxy = $false
    $http = [Net.Http.HttpClient]::new($httpSettings)
    $http.Timeout = [TimeSpan]::FromSeconds(4)
    try {
        try { $entry = $http.GetAsync([uri]$access.Url).GetAwaiter().GetResult() }
        catch { throw 'SMTP_WEBMAIL_IDLE_ENTRY_NOT_CONFIRMED' }
        try { $idleEntry = [int]$entry.StatusCode -eq 302 -and $entry.Headers.Contains('Set-Cookie') }
        finally { $entry.Dispose() }
    }
    finally { $http.Dispose() }
    Get-Job -ErrorAction SilentlyContinue|Where-Object Name -like 'sql-lab-smtp-webmail-*'|ForEach-Object {Stop-Job -Job $_ -ErrorAction SilentlyContinue;Remove-Job -Job $_ -Force -ErrorAction SilentlyContinue}
    $checks=@(
        ([string]$binding.Provider -ceq 'docker')
        ([string]$status.Status -ceq 'READY')
        ([bool]$status.WebMailAvailable)
        ([string]$status.WebMailKind -ceq 'Mailpit')
        (@($guided.Listing.Candidates).Count -eq 1 -and $guided.Listing.Candidates[0].RunId -ceq $runId -and $guided.Listing.Candidates[0].Name -ceq 'SMTP fixture')
        ($guided.Receipt.Status -ceq 'READY' -and $guided.Receipt.RunId -ceq $runId -and
            ($guided | ConvertTo-Json -Depth 6 -Compress) -cnotmatch 'synthetic-password|127\.0\.0\.1|ScopeId|ReceiverContainerId|ExpiresAt')
        ($guided.StaleBlocked)
        ($guided.Console -match 'Mailpit: RUNNING' -and $guided.Console -match 'Zustellung von Testmails')
        ($guided.HttpList.StatusCode -eq 200 -and $guided.HttpList.View.Candidates[0].RunId -ceq $runId)
        ($guided.HttpStatus.StatusCode -eq 200 -and $guided.HttpStatus.View.Status -ceq 'READY' -and $guided.HttpStatus.View.RunId -ceq $runId)
        ($guided.HttpPost -eq 405 -and $guided.HttpDuplicate -eq 400)
        (@($status.SupportedActions).Count -eq 2)
        ([string]$wrongStatus.Reason -ceq 'SMTP_WEBMAIL_RUNTIME_BINDING_INVALID')
        ([string]$access.Status -ceq 'OPENED')
        ([string]$access.Url -match '^http://127\.0\.0\.1:\d+/launch/[a-f0-9]{64}$')
        ($idleEntry)
    )
    if(@($checks|Where-Object {$_}).Count-ne$checks.Count){throw 'SMTP_WEBMAIL_CHECK_FAILED'}
    Write-Host "SMTP WebMail und Statusführung: PASS ($($checks.Count)/$($checks.Count))"
} finally {Get-Job -ErrorAction SilentlyContinue|Where-Object Name -like 'sql-lab-smtp-webmail-*'|ForEach-Object {Stop-Job -Job $_ -ErrorAction SilentlyContinue;Remove-Job -Job $_ -Force -ErrorAction SilentlyContinue};Remove-Item -LiteralPath $root -Force -Recurse -ErrorAction SilentlyContinue}
