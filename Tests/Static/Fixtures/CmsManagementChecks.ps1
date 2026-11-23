$sourceRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
. (Join-Path $sourceRoot 'Private/CmsManagement.ps1')

$cmsLockEvents = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
$cmsLockGate = [Threading.ManualResetEventSlim]::new($false)
$cmsLockRoot = Join-Path ([IO.Path]::GetTempPath()) ('synthetic-cms-management-' + [guid]::NewGuid().ToString('N'))
$cmsLockJobs = @(
    Start-ThreadJob -ArgumentList $sourceRoot,$cmsLockRoot,$cmsLockEvents,$cmsLockGate -ScriptBlock {
        param($Root,$StateRoot,$Events,$Gate)
        . (Join-Path $Root 'Private/CmsManagement.ps1')
        $Gate.Wait()
        Invoke-WithLabCmsManagementLock -StateRoot $StateRoot -ScriptBlock {
            $Events.Enqueue('start')
            Start-Sleep -Milliseconds 75
            $Events.Enqueue('end')
        }
    }
    Start-ThreadJob -ArgumentList $sourceRoot,$cmsLockRoot,$cmsLockEvents,$cmsLockGate -ScriptBlock {
        param($Root,$StateRoot,$Events,$Gate)
        . (Join-Path $Root 'Private/CmsManagement.ps1')
        $Gate.Wait()
        Invoke-WithLabCmsManagementLock -StateRoot $StateRoot -ScriptBlock {
            $Events.Enqueue('start')
            Start-Sleep -Milliseconds 75
            $Events.Enqueue('end')
        }
    }
)
try {
    $cmsLockGate.Set()
    $null = Wait-Job -Job $cmsLockJobs -Timeout 10
    foreach ($cmsLockJob in $cmsLockJobs) { if ($cmsLockJob.State -cne 'Completed') { throw 'CMS_MANAGEMENT_MUTEX_TEST_TIMEOUT' } }
    $null = Receive-Job -Job $cmsLockJobs -ErrorAction Stop
    $cmsLockEventValues = @($cmsLockEvents.ToArray())
    if ($cmsLockEventValues.Count -ne 4 -or ($cmsLockEventValues -join ',') -cne 'start,end,start,end') { throw 'CMS_MANAGEMENT_MUTEX_NOT_SERIALIZED' }
}
finally {
    $cmsLockGate.Dispose()
    Remove-Job -Job $cmsLockJobs -Force -ErrorAction SilentlyContinue
}

$script:cmsManagementRoot = $cmsLockRoot
$script:cmsManagementConfiguration = $null
$script:cmsManagementProviders = @('docker','podman')
$script:cmsManagementCandidates = @([pscustomobject]@{
    RunId = '11111111-2222-4333-8444-555555555555'
    Name = 'synthetic-environment'
    Provider = 'docker'
    Run = [pscustomobject]@{ state='RUNNING' }
})
function Get-LabStateRoot { $script:cmsManagementRoot }
function Get-LabConnectionCenterCmsConfiguration { $script:cmsManagementConfiguration }
function Get-LabConnectionCenterCmsEnvironmentCandidates { $script:cmsManagementCandidates }
function Get-LabTestEnvironmentRegistry { [pscustomobject]@{ environments=@() } }
function Get-AvailableLabProviders { $script:cmsManagementProviders }
function Get-LabDataRootDefault { 'C:\synthetic\private-data-root' }
function Get-LabRunState { [pscustomobject]@{ state='RUNNING' } }
. (Join-Path $sourceRoot 'Private/CmsInspection.ps1')
$fixtureRun = $script:cmsManagementCandidates[0].RunId
$runDirectory = Join-Path $script:cmsManagementRoot ('runs/' + $fixtureRun)
$secretDirectory = Join-Path $runDirectory 'secrets'
$null = [IO.Directory]::CreateDirectory($secretDirectory)
$files = [ordered]@{
    'run-state.json' = @{ runId=$fixtureRun; scopeId='synthetic-scope'; state='RUNNING' }
    'connection-info.json' = @{ runId=$fixtureRun; scopeId='synthetic-scope'; instances=@(@{ id='primary'; provider='docker'; version='2025'; containerId=('a'*64); host='127.0.0.1'; port=14330 }) }
    'secrets/sa-password.secret' = 'synthetic-marker'
}
foreach ($entry in $files.GetEnumerator()) { $entry.Value | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $runDirectory $entry.Key) }

try {
$state = Get-LabCmsManagementState
$serialized = $state | ConvertTo-Json -Depth 8 -Compress
if ($state.ContractVersion -cne 'SqlServerLab.CmsManagement/1.0' -or $state.Status -cne 'NOT_CONFIGURED' -or
    -not $state.CanCreate -or -not $state.CanAdopt -or $state.Candidates.Count -ne 1 -or
    $serialized.Contains($script:cmsManagementRoot) -or $serialized.Contains('private-data-root') -or
    $state.PSObject.Properties.Name -contains 'SaPassword') { throw 'CMS_MANAGEMENT_SAFE_STATE_PROJECTION_FAILED' }

$same = Assert-LabCmsManagementPlanKey -ExpectedPlanKey $state.PlanKey
if ($same.PlanKey -cne $state.PlanKey) { throw 'CMS_MANAGEMENT_PLAN_KEY_STABILITY_FAILED' }
$script:cmsManagementProviders = @('docker')
$changed = Get-LabCmsManagementState
if ($changed.PlanKey -ceq $state.PlanKey) { throw 'CMS_MANAGEMENT_PLAN_KEY_DID_NOT_BIND_PROVIDER_STATE' }
try { Assert-LabCmsManagementPlanKey -ExpectedPlanKey $state.PlanKey; throw 'CMS_MANAGEMENT_STALE_KEY_ACCEPTED' }
catch { if ($_.Exception.Message -cne 'CMS_MANAGEMENT_STATE_CHANGED') { throw } }
$files['connection-info.json'].instances[0].port = 14331
$files['connection-info.json'] | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $runDirectory 'connection-info.json')
$rebound = Get-LabCmsManagementState
if ($rebound.PlanKey -ceq $changed.PlanKey -or $rebound.Candidates.Count -ne 1) { throw 'CMS_MANAGEMENT_CANDIDATE_DRIFT_UNBOUND' }

$script:cmsProbes = 0
$script:cmsRegistrations = 0
function Get-LabContainerResourceLockName { param($StateRoot,$RunId) 'SqlServerLab.CmsManagement.Test.' + [IO.Path]::GetFileName($StateRoot) + '.' + $RunId }
function Get-LabConnectionCenterConfiguration { [pscustomobject]@{ CmsUseRootGroup=$true } }
function Get-LabCmsInspectionRuntimeBinding {
    param($Selection)
    if ($Selection.RunId -cne $fixtureRun -or $Selection.Instance.port -ne 14331) { throw 'CMS_MANAGEMENT_RUNTIME_TARGET_MISMATCH' }
    $script:cmsProbes++
}
function Register-SqlServerLabCmsEnvironment {
    [CmdletBinding()]param($RunId,$StateRoot)
    if ($RunId -cne $fixtureRun -or $StateRoot -cne $script:cmsManagementRoot) { throw 'CMS_MANAGEMENT_REGISTER_TARGET_MISMATCH' }
    $script:cmsRegistrations++
    [pscustomobject]@{ Configuration=[pscustomobject]@{ RunId=$RunId; Provider='docker' } }
}
try {
    $null = Invoke-LabCmsManagementAdoption -RunId $fixtureRun -ExpectedPlanKey $changed.PlanKey
    throw 'CMS_MANAGEMENT_STALE_ADOPTION_EXECUTED'
} catch { if ($_.Exception.Message -cne 'CMS_MANAGEMENT_STATE_CHANGED') { throw } }
if ($script:cmsProbes -or $script:cmsRegistrations) { throw 'CMS_MANAGEMENT_STALE_ADOPTION_PROBED' }
$adoption = Invoke-LabCmsManagementAdoption -RunId $fixtureRun -ExpectedPlanKey $rebound.PlanKey
if ($script:cmsProbes -ne 1 -or $script:cmsRegistrations -ne 1 -or $adoption.Configuration.RunId -cne $fixtureRun) {
    throw 'CMS_MANAGEMENT_ADOPTION_UNCONFIRMED'
}

$validInitialize = '{"action":"InitializeCms","parameters":{"Provider":"docker","LabName":"sql-server-lab-cms","ExpectedPlanKey":"' + $changed.PlanKey + '","ConfirmCmsOperation":true,"ReplaceRemovedCms":false}}'
if (-not (Assert-LabCmsManagementWorkflowJsonShape -Json $validInitialize -Action InitializeCms)) { throw 'CMS_MANAGEMENT_VALID_CREATE_REJECTED' }
$validAdopt = '{"action":"AdoptCms","parameters":{"RunId":"11111111-2222-4333-8444-555555555555","ExpectedPlanKey":"' + $changed.PlanKey + '","ConfirmCmsOperation":true}}'
if (-not (Assert-LabCmsManagementWorkflowJsonShape -Json $validAdopt -Action AdoptCms)) { throw 'CMS_MANAGEMENT_VALID_ADOPT_REJECTED' }

$invalidRequests = @(
    ('{"action":"InitializeCms","parameters":{"Provider":"docker","ExpectedPlanKey":"' + $changed.PlanKey + '","ConfirmCmsOperation":false}}'),
    ('{"action":"SyncCms","parameters":{"ExpectedPlanKey":"' + $changed.PlanKey + '","ConfirmCmsOperation":true,"Unexpected":"x"}}'),
    ('{"action":"AdoptCms","parameters":{"RunId":"bad","ExpectedPlanKey":"' + $changed.PlanKey + '","ConfirmCmsOperation":true}}'),
    ('{"action":"AdoptCms","parameters":{"RunId":"11111111-2222-4333-8444-555555555555","ExpectedPlanKey":"' + $changed.PlanKey + '","ConfirmCmsOperation":true,"SaPassword":""}}')
)
foreach ($invalid in $invalidRequests) {
    $rejected = $false
    try { $null = Assert-LabCmsManagementWorkflowJsonShape -Json $invalid -Action ((ConvertFrom-Json $invalid).action) }
    catch { $rejected = $true }
    if (-not $rejected) { throw 'CMS_MANAGEMENT_INVALID_REQUEST_ACCEPTED' }
}

$script:cmsManagementConfiguration = [pscustomobject]@{ RunId=$fixtureRun; Provider='docker'; ContractVersion='SqlServerLab.ConnectionCenterCms/1.1' }
$configured = Get-LabCmsManagementState
if ($configured.Status -cne 'CONFIGURED' -or $configured.Cms.State -cne 'RUNNING' -or
    $configured.Cms.PSObject.Properties.Name -contains 'Password' -or
    $configured.PSObject.Properties.Name -contains 'StateRoot') { throw 'CMS_MANAGEMENT_CONFIGURED_STATE_NOT_MINIMIZED' }
} finally {
    foreach ($key in $files.Keys) { [IO.File]::Delete((Join-Path $runDirectory $key)) }
    foreach ($directory in @($secretDirectory,$runDirectory,(Join-Path $script:cmsManagementRoot 'runs'),$script:cmsManagementRoot)) {
        [IO.Directory]::Delete($directory, $false)
    }
}
