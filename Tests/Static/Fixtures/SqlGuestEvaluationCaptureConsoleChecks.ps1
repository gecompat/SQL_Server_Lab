#Requires -Version 7.2
[CmdletBinding()]param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../../../Private/SqlGuestEvaluationCaptureConsole.ps1')
$script:accepted = $false
$script:calls = @()
function Get-LabActiveRuns {
    foreach ($definition in @(@('eligible','RUNNING','hyperv-lab'), @('old','RUNNING','hyperv-lab'), @('stopped','STOPPED','hyperv-lab'), @('container','RUNNING','container'))) {
        [pscustomobject]@{runId=$definition[0]; state=$definition[1]; metadata=[pscustomobject]@{workflowKind=$definition[2]}}
    }
}
function Get-HyperVLabWorkflowRun {
    param($RunId)
    $version = if ($RunId -ceq 'eligible') { '2025' } else { '2022' }
    [pscustomobject]@{Connection=[pscustomobject]@{instances=@([pscustomobject]@{workload='sql';sqlVersion=$version;sqlReadiness=[pscustomobject]@{status='SQL_READY_RUN'}})}}
}
function Select-LabRun {
    param($Runs,$Prompt,[switch]$DisableAutomatedTestEnvironments,[switch]$DisableSystemServices)
    if ($Runs.Count -ne 1 -or $Runs[0].runId -cne 'eligible' -or -not $DisableAutomatedTestEnvironments -or -not $DisableSystemServices) {
        throw 'SQL_GUEST_CAPTURE_CONSOLE_SCOPE_INVALID'
    }
    $Runs[0].runId
}
function Read-LabConfirm { param($Prompt,$Default) if ($Default) { throw 'SQL_GUEST_CAPTURE_CONSOLE_DEFAULT_CONFIRM' }; $script:accepted }
function Update-SqlServerLabSqlGuestEvaluationEvidence {
    [CmdletBinding(SupportsShouldProcess)]param($RunId)
    $script:calls += $RunId
    [pscustomobject]@{Status='UPDATED'}
}
function Write-LabInfo {}
function Write-LabSuccess {}
function Write-LabError {param($Message) throw $Message}
function Wait-LabConsoleAcknowledgement {}

Invoke-LabSqlGuestEvaluationCaptureInteractive
if ($script:calls.Count) { throw 'SQL_GUEST_CAPTURE_CONSOLE_DECLINE_MUTATED' }
$script:accepted = $true
Invoke-LabSqlGuestEvaluationCaptureInteractive
if ($script:calls.Count -ne 1 -or $script:calls[0] -cne 'eligible') { throw 'SQL_GUEST_CAPTURE_CONSOLE_DISPATCH_INVALID' }
Write-Host 'SQL GUEST EVALUATION CONSOLE: PASS'
