#Requires -Version 7.2
$ErrorActionPreference='Stop'
$repo=Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
$groupsPath=Join-Path $repo 'Private/EnvironmentGroupsBrowserHttp.ps1'
$serverPath=Join-Path $repo 'Tools/Start-SqlServerLabUi.ps1'
$script:checks=0
function Check([bool]$Value,[string]$Name) { if(-not $Value){throw "ENVIRONMENT_GROUPS_BROWSER_HTTP_CHECK_FAILED: $Name"};$script:checks++;Write-Host "PASS: $Name" }
$script:groupReads=0
$script:throwRead=$false
$script:runtimeCalls=0
$script:throwRuntime=$false
$script:staleAfterRuntime=$false
$script:transitionDuringRuntime=$false
$script:recoveryDuringRuntime=$false
$script:runtimeRaw='exited'
$script:runtimeRoot=$null
$script:runId='33333333-4444-4555-8666-777777777777'
$script:scopeId='44444444-5555-4666-8777-888888888888'
$script:fixtureRun=[pscustomobject][ordered]@{
    contractVersion='SqlServerLab.RunState/1.0';runId=$script:runId;scopeId=$script:scopeId;state='RUNNING'
    stateHistory=@([pscustomobject][ordered]@{state='RUNNING';timestamp='2026-11-07T12:00:00Z';reason='synthetic initial state'})
    createdAt='2026-11-07T12:00:00Z';updatedAt='2026-11-07T12:00:00Z';instances=@();providerSubRuns=@();metadata=[pscustomobject]@{};errors=@()
}
$script:fixtureGroups=@([pscustomobject]@{
    groupId='11111111-2222-4333-8444-555555555555';name='<img src=x onerror=alert(1)>';stateRootKey='PRIVATE_STATE_ROOT_KEY_CANARY';createdAt='2026-11-07T12:00:00Z';lifecycleState='ACTIVE'
    operation=[pscustomobject]@{operationId='22222222-3333-4444-8555-666666666666';action='Start';state='COMPLETED';startedAt='2026-11-07T12:00:00Z';updatedAt='2026-11-07T12:01:00Z';members=@([pscustomobject]@{runId='33333333-4444-4555-8666-777777777777';action='START';status='STARTED';reasonCode='PRIVATE_REASON_CANARY'})}
    members=@([pscustomobject]@{runId=$script:runId;scopeId=$script:scopeId;instanceIds=@('MSSQLSERVER');connectionInfoSha256=('a'*64);bindingStatus='CURRENT';assignedAt='2026-11-07T12:00:00Z'})
})
function Get-SqlServerLabEnvironmentGroup {
    param([string]$GroupId,[string]$StateRoot,[switch]$IncludeBindingStatus)
    $script:groupReads++
    if(-not $IncludeBindingStatus -or $PSBoundParameters.Keys -notcontains 'GroupId' -and $PSBoundParameters.Keys -notcontains 'IncludeBindingStatus'){throw 'UNEXPECTED_PRIVATE_ARGUMENT'}
    if($script:throwRead){throw 'PRIVATE_ERROR_CANARY'}
    if($GroupId){return $script:fixtureGroups[0]}
    return $script:fixtureGroups
}
function Get-LabStateRoot { if($script:runtimeRoot){return $script:runtimeRoot}; throw 'RUNTIME_ROOT_NOT_SET' }
function Get-LabRunState { param([string]$RunId,[string]$StateRoot); $script:fixtureRun }
function Get-DockerInstanceStatus { param([string]$ContainerIdOrName,[string]$StateRoot); $script:runtimeCalls++;if($script:throwRuntime){throw 'PRIVATE_RUNTIME_CANARY'};if($script:staleAfterRuntime){$script:fixtureGroups[0].members[0].connectionInfoSha256=('b'*64);$script:fixtureGroups[0].members[0].bindingStatus='STALE'};if($script:transitionDuringRuntime){$script:fixtureRun.updatedAt='2026-11-07T12:02:00Z';$script:fixtureRun.stateHistory+=@([pscustomobject][ordered]@{state='STOPPED';timestamp='2026-11-07T12:02:00Z';reason='synthetic concurrent lifecycle stop'},[pscustomobject][ordered]@{state='RUNNING';timestamp='2026-11-07T12:02:01Z';reason='synthetic concurrent lifecycle restart'})};if($script:recoveryDuringRuntime){$script:fixtureRun.state='RECOVERY_REQUIRED';$script:fixtureRun.updatedAt='2026-11-07T12:04:00Z';$script:fixtureRun.stateHistory+=@([pscustomobject][ordered]@{state='RECOVERY_REQUIRED';timestamp='2026-11-07T12:04:00Z';reason='synthetic concurrent recovery transition'});$script:fixtureGroups[0].members[0].bindingStatus='STALE'};[pscustomobject]@{Available=$true;Exists=$true;Running=($script:runtimeRaw -ceq 'running');Raw=$script:runtimeRaw} }
function Get-PodmanInstanceStatus { param([string]$ContainerIdOrName,[string]$StateRoot); throw 'UNEXPECTED_PROVIDER_READER' }
function Get-HyperVInstanceStatus { param([string]$VMName,[string]$ExpectedRunId,[string]$ExpectedScopeId); throw 'UNEXPECTED_PROVIDER_READER' }
. $groupsPath
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($serverPath,[ref]$tokens,[ref]$errors)
$route=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.IfStatementAst] -and $node.Clauses[0].Item1.Extent.Text -ceq "`$path -eq '/api/environment-groups'"},$true))
Check ($errors.Count -eq 0 -and $route.Count -eq 1) 'one actual environment group browser route parses'
$runtimeRoute=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.IfStatementAst] -and $node.Clauses[0].Item1.Extent.Text -ceq "`$path -eq '/api/environment-groups/runtime'"},$true))
Check ($errors.Count -eq 0 -and $runtimeRoute.Count -eq 1) 'one explicit runtime observation route parses'
$script:response=$null
function Write-UiResponse { param($Context,$Body,$ContentType='text/plain; charset=utf-8',[int]$StatusCode=200,[switch]$NoStore);$script:response=[pscustomobject]@{Status=$StatusCode;Body=$Body;ContentType=$ContentType;NoStore=[bool]$NoStore} }
$dispatch=[scriptblock]::Create('foreach($iteration in 1){'+$route[0].Extent.Text+"`nthrow 'FALLTHROUGH'"+'}')
$runtimeDispatch=[scriptblock]::Create('foreach($iteration in 1){'+$runtimeRoute[0].Extent.Text+"`nthrow 'FALLTHROUGH'"+'}')
function Send([string]$Method) {
    $script:response=$null;$path='/api/environment-groups'
    $context=[pscustomobject]@{Request=[pscustomobject]@{HttpMethod=$Method}}
    & $dispatch
    return $script:response
}
function SendRuntime([string]$Method,$Query) {
    $script:response=$null;$path='/api/environment-groups/runtime'
    $context=[pscustomobject]@{Request=[pscustomobject]@{HttpMethod=$Method;QueryString=$Query}}
    & $runtimeDispatch
    return $script:response
}
$response=Send 'GET';$view=$response.Body|ConvertFrom-Json
Check ($response.Status -eq 200 -and $response.ContentType -ceq 'application/json; charset=utf-8' -and $view.contractVersion -ceq 'SqlServerLab.EnvironmentGroups.BrowserView/1.2') 'GET returns versioned binding and operation-result view'
Check ($script:groupReads -eq 1 -and $view.groups.Count -eq 1 -and $view.groups[0].members[0].runId -ceq '33333333-4444-4555-8666-777777777777') 'GET reads registry through public reader and includes stored member references'
Check ($view.groups[0].members[0].bindingStatus -ceq 'CURRENT') 'GET includes only the public current/stale binding result'
Check ($view.groups[0].operation.members[0].status -ceq 'STARTED' -and $view.groups[0].operation.members[0].action -ceq 'START') 'GET includes stored per-run operation result'
Check ($response.Body -notmatch 'stateRootKey|scopeId|connectionInfoSha256|operationId|reasonCode|PRIVATE_REASON_CANARY|PRIVATE_STATE_ROOT_KEY_CANARY|PRIVATE_ERROR_CANARY') 'private state bindings, operation details and hashes are omitted'
$readsBefore=$script:groupReads;$response=Send 'POST'
Check ($response.Status -eq 405 -and $script:groupReads -eq $readsBefore -and $response.Body -ceq '{"code":"UI_METHOD_NOT_ALLOWED"}') 'non-GET method has no reader call'
$script:throwRead=$true;$response=Send 'GET'
Check ($response.Status -eq 500 -and $response.Body -ceq '{"code":"ENVIRONMENT_GROUPS_READ_UNCONFIRMED"}' -and $response.Body -notmatch 'PRIVATE_ERROR_CANARY') 'read failure returns a fixed body-free code'
$runtimeCallsBeforeRoute=$script:runtimeCalls
$response=SendRuntime 'POST' ([System.Collections.Specialized.NameValueCollection]::new())
Check ($response.Status -eq 405 -and $response.Body -ceq '{"code":"UI_METHOD_NOT_ALLOWED"}' -and $response.NoStore -and $script:runtimeCalls -eq $runtimeCallsBeforeRoute) 'runtime route rejects mutation methods without observation and disables caching'
$invalidRuntimeQuery=[System.Collections.Specialized.NameValueCollection]::new();$invalidRuntimeQuery.Add('runId',$script:runId)
$response=SendRuntime 'GET' $invalidRuntimeQuery
Check ($response.Status -eq 400 -and $response.Body -ceq '{"code":"ENVIRONMENT_GROUP_RUNTIME_REQUEST_INVALID"}' -and $response.NoStore -and $script:runtimeCalls -eq $runtimeCallsBeforeRoute) 'runtime route rejects incomplete query without provider calls and disables caching'

$tempRoot=[System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
$runtimePath=Join-Path $tempRoot ('SqlServerLabEnvironmentGroupsBrowserHttp-'+[guid]::NewGuid().ToString('N'))
$script:runtimeRoot=$runtimePath
try {
    $runDirectory=Join-Path (Join-Path $runtimePath 'runs') $script:runId
    New-Item -ItemType Directory -Path $runDirectory -Force | Out-Null
    $connection=[ordered]@{runId=$script:runId;scopeId=$script:scopeId;instances=@([ordered]@{id='MSSQLSERVER';provider='docker';containerId='SYNTHETIC_CONTAINER_ID'})}
    $connectionBytes=[System.Text.UTF8Encoding]::new($false).GetBytes(($connection|ConvertTo-Json -Depth 8 -Compress))
    [System.IO.File]::WriteAllBytes((Join-Path $runDirectory 'connection-info.json'),$connectionBytes)
    $script:fixtureGroups[0].members[0].connectionInfoSha256=[Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($connectionBytes))
    $script:currentConnectionHash=$script:fixtureGroups[0].members[0].connectionInfoSha256
    $script:throwRead=$false
    $runtimeView=Get-LabEnvironmentGroupRuntimeObservation -GroupId $script:fixtureGroups[0].groupId -RunId $script:runId
    Check ($runtimeView.savedState -ceq 'RUNNING' -and $runtimeView.runtimeState -ceq 'STOPPED' -and $runtimeView.reconciliation -ceq 'DRIFT') 'runtime reader compares saved and live state without mutation'
    Check ($runtimeView.instances[0].state -ceq 'STOPPED' -and $script:runtimeCalls -eq 1) 'runtime reader queries only the selected bound provider member'
    $runtimeBody=$runtimeView|ConvertTo-Json -Depth 8 -Compress
    Check ($runtimeBody -notmatch 'SYNTHETIC_CONTAINER_ID|containerId|scopeId|connectionInfoSha256|PRIVATE_RUNTIME_CANARY') 'runtime observation omits provider IDs, binding data and raw errors'
    $script:runtimeRaw='paused'
    $pausedRuntime=Get-LabEnvironmentGroupRuntimeObservation -GroupId $script:fixtureGroups[0].groupId -RunId $script:runId
    Check ($pausedRuntime.runtimeState -ceq 'OTHER' -and $pausedRuntime.reconciliation -ceq 'INDETERMINATE' -and $pausedRuntime.instances[0].state -ceq 'OTHER') 'non-terminal container state is not misreported as stopped'
    $script:runtimeRaw='exited'
    $script:transitionDuringRuntime=$true
    $transitionedRuntime=Get-LabEnvironmentGroupRuntimeObservation -GroupId $script:fixtureGroups[0].groupId -RunId $script:runId
    Check ($transitionedRuntime.savedState -ceq 'UNKNOWN' -and $transitionedRuntime.runtimeState -ceq 'UNKNOWN' -and $transitionedRuntime.reconciliation -ceq 'INDETERMINATE' -and $transitionedRuntime.instances.Count -eq 0) 'stop and restart during provider read discards the observation even when the coarse state returns to RUNNING'
    $script:transitionDuringRuntime=$false
    $script:fixtureRun.state='RUNNING'
    $script:fixtureRun.updatedAt='2026-11-07T12:03:00Z'
    $script:fixtureRun.stateHistory+=@([pscustomobject][ordered]@{state='RUNNING';timestamp='2026-11-07T12:03:00Z';reason='synthetic lifecycle resumed'})
    $script:fixtureGroups[0].members[0].bindingStatus='CURRENT'
    $script:recoveryDuringRuntime=$true
    $recoveryTransitionRuntime=Get-LabEnvironmentGroupRuntimeObservation -GroupId $script:fixtureGroups[0].groupId -RunId $script:runId
    Check ($recoveryTransitionRuntime.savedState -ceq 'UNKNOWN' -and $recoveryTransitionRuntime.runtimeState -ceq 'UNKNOWN' -and $recoveryTransitionRuntime.reconciliation -ceq 'INDETERMINATE' -and $recoveryTransitionRuntime.instances.Count -eq 0) 'recovery transition is not misclassified as a stale binding when the structural binding is unchanged'
    $script:recoveryDuringRuntime=$false
    $script:fixtureRun.state='RUNNING'
    $script:fixtureRun.updatedAt='2026-11-07T12:05:00Z'
    $script:fixtureRun.stateHistory+=@([pscustomobject][ordered]@{state='RUNNING';timestamp='2026-11-07T12:05:00Z';reason='synthetic recovery complete'})
    $script:fixtureGroups[0].members[0].bindingStatus='CURRENT'
    $script:staleAfterRuntime=$true
    $racedRuntime=Get-LabEnvironmentGroupRuntimeObservation -GroupId $script:fixtureGroups[0].groupId -RunId $script:runId
    Check ($racedRuntime.runtimeState -ceq 'STALE_BINDING' -and $racedRuntime.reconciliation -ceq 'INDETERMINATE' -and $racedRuntime.instances.Count -eq 0) 'binding changed during provider read is discarded after fresh recheck'
    $script:staleAfterRuntime=$false
    $script:fixtureGroups[0].members[0].connectionInfoSha256=$script:currentConnectionHash
    $script:fixtureGroups[0].members[0].bindingStatus='CURRENT'
    $bytesBefore=$script:runtimeCalls
    $script:fixtureGroups[0].members[0].bindingStatus='STALE'
    $staleRuntime=Get-LabEnvironmentGroupRuntimeObservation -GroupId $script:fixtureGroups[0].groupId -RunId $script:runId
    Check ($staleRuntime.runtimeState -ceq 'STALE_BINDING' -and $script:runtimeCalls -eq $bytesBefore) 'stale member binding prevents provider observation'
    $script:fixtureGroups[0].members[0].bindingStatus='CURRENT'
    $script:throwRuntime=$true
    $failedRuntime=Get-LabEnvironmentGroupRuntimeObservation -GroupId $script:fixtureGroups[0].groupId -RunId $script:runId
    Check ($failedRuntime.runtimeState -ceq 'UNAVAILABLE' -and ($failedRuntime|ConvertTo-Json -Depth 8) -notmatch 'PRIVATE_RUNTIME_CANARY') 'provider reader failure is sanitized'
}
finally {
    $tempPrefix=$tempRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar,[System.IO.Path]::AltDirectorySeparatorChar)+[System.IO.Path]::DirectorySeparatorChar
    if (([System.IO.Path]::GetFullPath($runtimePath)).StartsWith($tempPrefix,[System.StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $runtimePath -Recurse -Force -ErrorAction SilentlyContinue
    }
}
Write-Host "ENVIRONMENT GROUPS BROWSER HTTP CHECKS: $script:checks PASS; actual route/helper, synthetic public reader"
