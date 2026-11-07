#Requires -Version 7.2
$ErrorActionPreference='Stop'
$repo=Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
$groupsPath=Join-Path $repo 'Private/EnvironmentGroupsBrowserHttp.ps1'
$serverPath=Join-Path $repo 'Tools/Start-SqlServerLabUi.ps1'
$script:checks=0
function Check([bool]$Value,[string]$Name) { if(-not $Value){throw "ENVIRONMENT_GROUPS_BROWSER_HTTP_CHECK_FAILED: $Name"};$script:checks++;Write-Host "PASS: $Name" }
$script:groupReads=0
$script:throwRead=$false
$script:fixtureGroups=@([pscustomobject]@{
    groupId='11111111-2222-4333-8444-555555555555';name='<img src=x onerror=alert(1)>';stateRootKey='PRIVATE_STATE_ROOT_KEY_CANARY';createdAt='2026-11-07T12:00:00Z';lifecycleState='ACTIVE'
    operation=[pscustomobject]@{operationId='22222222-3333-4444-8555-666666666666';action='Start';state='COMPLETED';startedAt='2026-11-07T12:00:00Z';updatedAt='2026-11-07T12:01:00Z';members=@()}
    members=@([pscustomobject]@{runId='33333333-4444-4555-8666-777777777777';scopeId='44444444-5555-4666-8777-888888888888';instanceIds=@('MSSQLSERVER');connectionInfoSha256=('a'*64);assignedAt='2026-11-07T12:00:00Z'})
})
function Get-SqlServerLabEnvironmentGroup {
    param([string]$GroupId,[string]$StateRoot)
    $script:groupReads++
    if($PSBoundParameters.Count -gt 0){throw 'UNEXPECTED_PRIVATE_ARGUMENT'}
    if($script:throwRead){throw 'PRIVATE_ERROR_CANARY'}
    return $script:fixtureGroups
}
. $groupsPath
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($serverPath,[ref]$tokens,[ref]$errors)
$route=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.IfStatementAst] -and $node.Clauses[0].Item1.Extent.Text -ceq "`$path -eq '/api/environment-groups'"},$true))
Check ($errors.Count -eq 0 -and $route.Count -eq 1) 'one actual environment group browser route parses'
$script:response=$null
function Write-UiResponse { param($Context,$Body,$ContentType='text/plain; charset=utf-8',[int]$StatusCode=200);$script:response=[pscustomobject]@{Status=$StatusCode;Body=$Body;ContentType=$ContentType} }
$dispatch=[scriptblock]::Create('foreach($iteration in 1){'+$route[0].Extent.Text+"`nthrow 'FALLTHROUGH'"+'}')
function Send([string]$Method) {
    $script:response=$null;$path='/api/environment-groups'
    $context=[pscustomobject]@{Request=[pscustomobject]@{HttpMethod=$Method}}
    & $dispatch
    return $script:response
}
$response=Send 'GET';$view=$response.Body|ConvertFrom-Json
Check ($response.Status -eq 200 -and $response.ContentType -ceq 'application/json; charset=utf-8' -and $view.contractVersion -ceq 'SqlServerLab.EnvironmentGroups.BrowserView/1.0') 'GET returns versioned view'
Check ($script:groupReads -eq 1 -and $view.groups.Count -eq 1 -and $view.groups[0].members[0].runId -ceq '33333333-4444-4555-8666-777777777777') 'GET reads registry through public reader and includes stored member references'
Check ($response.Body -notmatch 'stateRootKey|scopeId|connectionInfoSha256|PRIVATE_STATE_ROOT_KEY_CANARY|PRIVATE_ERROR_CANARY') 'private state bindings and hashes are omitted'
$readsBefore=$script:groupReads;$response=Send 'POST'
Check ($response.Status -eq 405 -and $script:groupReads -eq $readsBefore -and $response.Body -ceq '{"code":"UI_METHOD_NOT_ALLOWED"}') 'non-GET method has no reader call'
$script:throwRead=$true;$response=Send 'GET'
Check ($response.Status -eq 500 -and $response.Body -ceq '{"code":"ENVIRONMENT_GROUPS_READ_UNCONFIRMED"}' -and $response.Body -notmatch 'PRIVATE_ERROR_CANARY') 'read failure returns a fixed body-free code'
Write-Host "ENVIRONMENT GROUPS BROWSER HTTP CHECKS: $script:checks PASS; actual route/helper, synthetic public reader"
