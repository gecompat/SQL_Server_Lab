#Requires -Version 7.2
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$failures = [Collections.Generic.List[string]]::new()
$passed = 0
. (Join-Path $PSScriptRoot '..\Common\CheckResult.ps1')

Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
$module = Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru -ErrorAction Stop

$result = & $module {
    $calls = [pscustomobject]@{ Confirm = 0; Process = 0 }
    $confirmNo = { $calls.Confirm++; $false }.GetNewClosure()
    $confirmYes = { $calls.Confirm++; $true }.GetNewClosure()
    $startProcess = { param($FilePath,$Arguments) $calls.Process++ }.GetNewClosure()

    $alreadyElevated = Start-LabElevatedAction -Action Image -AssumeWindows `
        -AdministratorProbe { $true } -ConfirmationAction $confirmYes -ProcessStarter $startProcess
    $declined = Start-LabElevatedAction -Action Image -AssumeWindows `
        -AdministratorProbe { $false } -ConfirmationAction $confirmNo -ProcessStarter $startProcess
    $approved = Start-LabElevatedAction -Action Image -AssumeWindows `
        -AdministratorProbe { $false } -ConfirmationAction $confirmYes -ProcessStarter $startProcess

    $privileges = [pscustomobject]@{
        Status = Get-LabActionPrivilegeClass -Action Status
        ContainerLifecycle = Get-LabActionPrivilegeClass -Action Start
        HyperVImage = Get-LabActionPrivilegeClass -Action Image
    }

    [pscustomobject]@{ AlreadyElevated=$alreadyElevated; Declined=$declined; Approved=$approved; Calls=$calls; Privileges=$privileges }
}

Add-CheckResult -Name 'Bereits erhöhte Sitzung startet keinen zweiten Prozess und benötigt keine Bestätigung' -Success (
    $result.AlreadyElevated.Status -eq 'NoChange' -and -not $result.AlreadyElevated.Started -and
    $result.AlreadyElevated.Reason -eq 'ALREADY_ELEVATED'
)
Add-CheckResult -Name 'Standardmäßig abgelehnte UAC-Vorschau bleibt Cancelled und prozessfrei' -Success (
    $result.Declined.SchemaVersion -eq 'SqlServerLab.ActionResult/1.0' -and
    $result.Declined.Status -eq 'Cancelled' -and -not $result.Declined.Started -and
    $result.Declined.ConnectionCenterImpact -eq 'None'
)
Add-CheckResult -Name 'Ausdrückliche UAC-Zustimmung startet genau einen erhöhten Folgeprozess' -Success (
    $result.Approved.Status -eq 'Changed' -and $result.Approved.Started -and
    $result.Approved.Reason -eq 'UAC_PROMPTED' -and $result.Calls.Confirm -eq 2 -and $result.Calls.Process -eq 1
)
Add-CheckResult -Name 'Read-only, Runtimezugriff und Administratoraktion sind explizit getrennt' -Success (
    $result.Privileges.Status -eq 'User' -and
    $result.Privileges.ContainerLifecycle -eq 'RuntimeAccess' -and
    $result.Privileges.HyperVImage -eq 'Administrator'
)

$source = Get-Content -LiteralPath (Join-Path $repoRoot 'Private\Elevation.ps1') -Raw -Encoding utf8
Add-CheckResult -Name 'Echte Elevation bleibt explizit an RunAs und eine ablehnende Vorschau gebunden' -Success (
    $source -match 'Start-Process[\s\S]+-Verb RunAs' -and
    $source -match 'function Get-LabActionPrivilegeClass' -and
    $source -match 'Read-LabConfirm[\s\S]+-Default \$false' -and
    $source.IndexOf('Read-LabConfirm') -lt $source.IndexOf('Start-Process')
)

if ($failures.Count -gt 0) {
    Write-Host "Elevation Checks: $passed PASS, $($failures.Count) FAIL" -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
Write-Host "Elevation Checks: $passed PASS" -ForegroundColor Green
