#Requires -Version 7.2
[CmdletBinding()] param()

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$runnerPath = Join-Path $repoRoot 'Tests/Integration/Invoke-HyperVResourceMigrationAcceptance.ps1'
$failures = [Collections.Generic.List[string]]::new(); $passed = 0
. (Join-Path $PSScriptRoot '..' 'Common' 'CheckResult.ps1')

Write-Host ''; Write-Host 'SQL_Server_Lab - Hyper-V Resource Migration Acceptance Checks' -ForegroundColor Cyan
try {
    $text = Get-Content -LiteralPath $runnerPath -Raw -Encoding utf8
    $tokens = $null; $parseErrors = $null
    [Management.Automation.Language.Parser]::ParseFile($runnerPath, [ref]$tokens, [ref]$parseErrors) | Out-Null
    Add-CheckResult -Name 'HVR-008-Runner ist syntaktisch gültig und verlangt exakte Run-/VM-Identität' -Success (
        @($parseErrors).Count -eq 0 -and $text -match '\[string\]\$RunId' -and
        $text -match '\[string\]\$ExpectedVMName' -and $text -match 'CANDIDATE_IDENTITY_MISMATCH'
    )
    Add-CheckResult -Name 'HVR-008-Runner verlangt Elevation, getrennte Roots und abgeschaltete VM' -Success (
        $text -match 'HVR008_ACCEPTANCE_ELEVATION_REQUIRED' -and
        $text -match 'HVR008_ACCEPTANCE_DISTINCT_ROOTS_REQUIRED' -and
        $text -match 'HVR008_ACCEPTANCE_CANDIDATE_MUST_BE_OFF'
    )
    Add-CheckResult -Name 'HVR-008-Runner koppelt Image- und Run-Migration resumierbar' -Success (
        $text -match 'Invoke-LabHyperVImageMigration' -and
        $text -match 'Invoke-LabHyperVResourceMigration' -and
        $text -match 'PLAN_REQUIRED_FOR_RESUME' -and
        $text -match "resourceJournalBefore\.Status -eq 'COMPLETED'"
    )
    Add-CheckResult -Name 'HVR-008-Runner prüft Binding, Parent, zwei Restarts und Quell-Cleanup' -Success (
        $text -match 'Assert-HyperVVMResourceBinding' -and
        $text -match 'PARENT_REBIND_INVALID' -and
        $text -match 'ReadinessReceipts\)\.Count -ne 2' -and
        $text -match 'LEGACY_RUN_ROOT_REMAINS'
    )
    Add-CheckResult -Name 'HVR-008-Evidence ist versioniert und enthält keine Secretwerte' -Success (
        $text -match 'SqlServerLab\.HVR008Acceptance/1\.0' -and
        $text -notmatch 'ConvertFrom-SecureString|NetworkCredential|Password\s*='
    )
}
catch { Add-CheckResult -Name 'HVR-008-Acceptance-Vertragsprüfung' -Success $false -Message $_.Exception.Message }

Write-Host ''; Write-Host "Ergebnis: $passed PASS, $($failures.Count) FAIL" -ForegroundColor Cyan
if ($failures.Count) { exit 1 }
exit 0
