#Requires -Version 7.2
[CmdletBinding()]param()
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
. (Join-Path $repoRoot 'Private/SqlFeatureConsole.ps1')
$script:featureCalls = @()
$script:chosenTarget = 'container'
$script:accepted = $false

function Get-LabActiveRuns { [pscustomobject]@{ state = 'RUNNING'; runId = '11111111-1111-1111-1111-111111111111' } }
function Select-LabRun {
    param($Runs,$Prompt,[switch]$DisableAutomatedTestEnvironments,[switch]$DisableSystemServices)
    if (-not $DisableAutomatedTestEnvironments -or -not $DisableSystemServices) { throw 'SQL_FEATURE_TEST_SCOPE_NOT_PROTECTED' }
    $Runs[0].runId
}
function Get-LabResourceChangeTargets {
    [pscustomobject]@{ InstanceId = 'container'; Provider = 'podman' }
    [pscustomobject]@{ InstanceId = 'windows'; Provider = 'hyperv' }
}
function New-LabConsoleItem {
    param($Id,$Label,$Value,$Data,$Shortcut)
    [pscustomobject]@{ Id = $Id; Label = $Label; Data = $Data }
}
function Invoke-LabConsoleMenu {
    param($ScreenId,$Title,$Items,$Subtitle)
    if ($ScreenId -ceq 'sql-feature-target') { $selected = $script:chosenTarget }
    elseif ($script:chosenTarget -ceq 'container') {
        if ('filestream-on' -cin $Items.Id) { throw 'SQL_FEATURE_TEST_FILESTREAM_IN_CONTAINER' }
        $selected = 'fulltext-off'
    } else {
        $selected = 'filestream-on'
    }
    [pscustomobject]@{ Status = 'Selected'; SelectedItem = ($Items | Where-Object Id -CEQ $selected) }
}
function Read-LabConfirm {
    param($Prompt,$Default)
    if ($Default -or $Prompt -notmatch 'SQL Server') { throw 'SQL_FEATURE_TEST_CONFIRMATION_INVALID' }
    $script:accepted
}
function Set-SqlServerLabFeature {
    [CmdletBinding(SupportsShouldProcess)]param($RunId,$InstanceId,$Feature,[bool]$Enabled)
    $script:featureCalls += [pscustomobject]@{ RunId = $RunId; InstanceId = $InstanceId; Feature = $Feature; Enabled = $Enabled }
    [pscustomobject]@{ Status = 'VERIFIED'; Changed = $true }
}
function Write-LabSuccess {}
function Write-LabError { param($Message) throw $Message }
function Wait-LabConsoleAcknowledgement {}

Invoke-LabSqlFeatureInteractive
if ($script:featureCalls.Count) { throw 'SQL_FEATURE_TEST_DECLINE_MUTATED' }
$script:accepted = $true
Invoke-LabSqlFeatureInteractive
$script:chosenTarget = 'windows'
Invoke-LabSqlFeatureInteractive
if ($script:featureCalls.Count -ne 2 -or $script:featureCalls[0].InstanceId -cne 'container' -or
    $script:featureCalls[0].Feature -cne 'FullText' -or $script:featureCalls[0].Enabled -or
    $script:featureCalls[1].InstanceId -cne 'windows' -or $script:featureCalls[1].Feature -cne 'FileStream' -or
    -not $script:featureCalls[1].Enabled) {
    throw 'SQL_FEATURE_TEST_DISPATCH_MISMATCH'
}
Write-Host 'SQL FEATURE CONSOLE: PASS'
