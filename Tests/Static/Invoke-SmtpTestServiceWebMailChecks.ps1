#Requires -Version 7.2
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repoRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$root=Join-Path ([IO.Path]::GetTempPath()) ('smtp-webmail-'+[guid]::NewGuid().ToString('N'))
$runId='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';$scopeId='bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';$serviceId='smtp'
$module=Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru
try {
    $runDirectory=Join-Path (Join-Path $root 'runs') $runId;New-Item -ItemType Directory -Path (Join-Path $runDirectory 'smtp-test-service') -Force|Out-Null
    [pscustomobject]@{runId=$runId;scopeId=$scopeId;state='RUNNING';providerSubRuns=@([pscustomobject]@{provider='docker'})}|ConvertTo-Json -Depth 8|Set-Content (Join-Path $runDirectory 'run-state.json') -Encoding utf8
    [pscustomobject]@{smtpTestService=[pscustomobject]@{ServiceId=$serviceId;SenderInstanceIds=@('primary');Receiver=[pscustomobject]@{Host='127.0.0.1';Port=18025}}}|ConvertTo-Json -Depth 8|Set-Content (Join-Path $runDirectory 'connection-info.json') -Encoding utf8
    [pscustomobject]@{ContractVersion='SqlServerLab.SmtpTestServiceJournal/1.0';Status='READY';RunId=$runId;ScopeId=$scopeId;Provider='docker';ServiceId=$serviceId;Resources=[pscustomobject]@{ReceiverContainerName='receiver';ReceiverContainerId='receiver-id'}}|ConvertTo-Json -Depth 8|Set-Content (Join-Path (Join-Path $runDirectory 'smtp-test-service') ($scopeId+'-'+$serviceId+'.json')) -Encoding utf8
    & $module {param($path,$name)$secret=ConvertTo-SecureString 'synthetic-password' -AsPlainText -Force;try{Save-LabSecret -Path $path -Name $name -Secret $secret}finally{$secret.Dispose()}} $runDirectory ('smtp-'+$serviceId+'-ui-password')
    $inspect=[pscustomobject]@{Id='receiver-id';Config=[pscustomobject]@{Labels=[pscustomobject]@{'sql-server-lab.run-id'=$runId;'sql-server-lab.scope-id'=$scopeId;'sql-server-lab.smtp-service-id'=$serviceId}};NetworkSettings=[pscustomobject]@{Ports=[pscustomobject]@{'8025/tcp'=@([pscustomobject]@{HostIp='127.0.0.1';HostPort=18025})}};State=[pscustomobject]@{Running=$true}}|ConvertTo-Json -Depth 12 -Compress
    & $module {param($json)Set-Item -Path function:Invoke-LabSmtpRuntime -Value {param($Provider,$StateRoot,$RunId,$Arguments)[pscustomobject]@{ExitCode=0;Output=@($json)}}.GetNewClosure()} $inspect
    $status=Get-SqlServerLabSmtpTestServiceStatus -RunId $runId -StateRoot $root
    $binding=& $module {param($id,$state)Get-LabSmtpTestServiceWebMailBinding -RunId $id -StateRoot $state} $runId $root
    $wrongScope=$false;$wrong=$inspect.Replace($scopeId,'cccccccc-cccc-cccc-cccc-cccccccccccc')
    & $module {param($json)Set-Item -Path function:Invoke-LabSmtpRuntime -Value {param($Provider,$StateRoot,$RunId,$Arguments)[pscustomobject]@{ExitCode=0;Output=@($json)}}.GetNewClosure()} $wrong
    $wrongStatus=Get-SqlServerLabSmtpTestServiceStatus -RunId $runId -StateRoot $root
    & $module {param($json)Set-Item -Path function:Invoke-LabSmtpRuntime -Value {param($Provider,$StateRoot,$RunId,$Arguments)[pscustomobject]@{ExitCode=0;Output=@($json)}}.GetNewClosure()} $inspect
    $access=Open-SqlServerLabSmtpTestServiceWebMail -RunId $runId -StateRoot $root -NoBrowser -Confirm:$false -LifetimeMinutes 1
    Get-Job -ErrorAction SilentlyContinue|Where-Object Name -like 'sql-lab-smtp-webmail-*'|ForEach-Object {Stop-Job -Job $_ -ErrorAction SilentlyContinue;Remove-Job -Job $_ -Force -ErrorAction SilentlyContinue}
    $checks=@(
        ([string]$binding.Provider -ceq 'docker')
        ([string]$status.Status -ceq 'READY')
        ([bool]$status.WebMailAvailable)
        ([string]$status.WebMailKind -ceq 'Mailpit')
        (@($status.SupportedActions).Count -eq 2)
        ([string]$wrongStatus.Reason -ceq 'SMTP_WEBMAIL_RUNTIME_BINDING_INVALID')
        ([string]$access.Status -ceq 'OPENED')
        ([string]$access.Url -match '^http://127\.0\.0\.1:\d+/launch/[a-f0-9]{64}$')
    )
    if(@($checks|Where-Object {$_}).Count-ne$checks.Count){throw 'SMTP_WEBMAIL_CHECK_FAILED'}
    Write-Host 'SMTP WebMail: PASS (8/8)'
} finally {Get-Job -ErrorAction SilentlyContinue|Where-Object Name -like 'sql-lab-smtp-webmail-*'|ForEach-Object {Stop-Job -Job $_ -ErrorAction SilentlyContinue;Remove-Job -Job $_ -Force -ErrorAction SilentlyContinue};Remove-Item -LiteralPath $root -Force -Recurse -ErrorAction SilentlyContinue}
