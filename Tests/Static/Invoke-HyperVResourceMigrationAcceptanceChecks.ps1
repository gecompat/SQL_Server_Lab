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
    Add-CheckResult -Name 'HVR-008-Runner verlangt Elevation, getrennte Roots und exakten VM-Ausgangszustand' -Success (
        $text -match 'HVR008_ACCEPTANCE_ELEVATION_REQUIRED' -and
        $text -match 'HVR008_ACCEPTANCE_DISTINCT_ROOTS_REQUIRED' -and
        $text -match '\[ValidateSet\(''Off'', ''Running''\)\]\[string\]\$ExpectedInitialVMState' -and
        $text -match 'HVR008_ACCEPTANCE_CANDIDATE_STATE_MISMATCH'
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
    Add-CheckResult -Name 'HVR-008-Runner kann SQL-Readiness für beide Restarts fail-closed verlangen' -Success (
        $text -match '\[switch\]\$RequireSqlReadiness' -and
        $text -match '\$ExpectedSqlMajorVersion' -and
        $text -match 'HVR008_ACCEPTANCE_SQL_IDENTITY_REQUIRED' -and
        $text -match 'HVR008_ACCEPTANCE_SQL_RESTART_EVIDENCE_INVALID' -and
        $text -match 'SqlRestartEvidenceCount'
    )
    Add-CheckResult -Name 'HVR-008-Runner adoptiert Legacy-SQL nur aus persistierter Windows- und Live-SQL-Evidence' -Success (
        $text -match '\[switch\]\$AdoptLegacySqlIdentity' -and
        $text -match 'SQL_IDENTITY_ADOPTION_REQUIRES_RUNNING_VM' -and
        $text -match 'LEGACY_SQL_ADOPTION_EVIDENCE_INVALID' -and
        $text -match 'Wait-HyperVGuestSqlReady' -and
        $text -match 'legacy-connection-and-live-sql-acceptance'
    )
    Add-CheckResult -Name 'HVR-008-Runner stoppt laufende Kandidaten vor dem Hashplan geordnet und stellt sie bei Preflightfehler wieder her' -Success (
        $text -match 'Stop-VM -VM \$managedForPlan\.VM -Shutdown' -and
        $text -match 'HVR008_ACCEPTANCE_GRACEFUL_SHUTDOWN_TIMEOUT' -and
        $text -match 'New-LabHyperVResourceMigrationPlan' -and
        $text -match 'HVR008_ACCEPTANCE_RUN_PLAN_REQUIRES_OFF_STATE' -and
        $text -match 'HVR008_ACCEPTANCE_PREFLIGHT_FAILED_AND_RESTORE_FAILED'
    )
    Add-CheckResult -Name 'HVR-008-Runner stellt den laufenden Ausgangszustand mit Gast- und SQL-Readiness wieder her' -Success (
        $text -match '\$restoreExpectedRunningState' -and
        $text -match 'HVR008_ACCEPTANCE_FINAL_GUEST_READINESS_FAILED' -and
        $text -match 'HVR008_ACCEPTANCE_FINAL_SQL_READINESS_FAILED' -and
        $text -match 'MigrationPlanInitialVMState' -and
        $text -match 'FinalRestorationSqlReady'
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
