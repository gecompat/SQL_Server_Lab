#Requires -Version 7.2
[CmdletBinding()] param()
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$path = Join-Path $repoRoot 'Tests/Integration/Invoke-HyperVLegacySqlMigrationBootstrap.ps1'
$failures = [Collections.Generic.List[string]]::new(); $passed = 0
. (Join-Path $PSScriptRoot '..' 'Common' 'CheckResult.ps1')
Write-Host ''; Write-Host 'SQL_Server_Lab - Hyper-V Legacy SQL Migration Bootstrap Checks' -ForegroundColor Cyan

$text = Get-Content -LiteralPath $path -Raw -Encoding utf8
Add-CheckResult -Name 'Bootstrap verlangt genau einen bereiten geschuetzten Windows-SQL-2022-Slot' -Success (
    $text -match "GroupStatus\s+-ne\s+'READY'" -and
    $text -match "platform\s+-eq\s+'windows'" -and $text -match "sqlVersion\s+-eq\s+'2022'" -and
    $text -match 'sources\.Count\s+-ne\s+1'
)
Add-CheckResult -Name 'Quelle wird nur ausgeschaltet und der Gruppenstart ist finally-geschuetzt' -Success (
    $text -match 'Stop-SqlServerLabAutomatedTestEnvironment' -and
    ([regex]::Matches($text, 'Start-SqlServerLabAutomatedTestEnvironment')).Count -ge 2 -and
    $text -match 'finally\s*\{[\s\S]+\$groupStopped'
)
Add-CheckResult -Name 'Gruppen-Timeout wird auf den oeffentlichen 600-Sekunden-Vertrag begrenzt' -Success (
    $text -match 'groupTimeoutSeconds\s*=\s*\[Math\]::Min\(600,\s*\$TimeoutSeconds\)' -and
    ([regex]::Matches($text, '-TimeoutSeconds \$groupTimeoutSeconds')).Count -eq 2
)
Add-CheckResult -Name 'Nicht isolierter Kandidat wird vor dem Gruppen-Restore ausgeschaltet' -Success (
    $text -match '-not \$candidateNetworkIsolated[\s\S]+Stop-VM[\s\S]+-TurnOff'
)
Add-CheckResult -Name 'Clone ist eigenstaendig und vor Provider-Mutation im Cleanup-Plan erfasst' -Success (
    $text.IndexOf('Add-CleanupStep') -lt $text.IndexOf('Convert-VHD -Path') -and
    $text -match 'Convert-VHD[\s\S]+-VHDType Dynamic' -and
    $text -match 'CLONE_NOT_STANDALONE'
)
Add-CheckResult -Name 'Legacy-Identitaet enthaelt absichtlich nur alte Windows- und Host-SQL-Evidence' -Success (
    $text -match "windowsProvisioning=\[PSCustomObject\]" -and
    $text -match "hostSqlAccess=\[PSCustomObject\]" -and
    $text -notmatch 'sqlReadiness=\[PSCustomObject\]'
)
Add-CheckResult -Name 'Migration verlangt SQL-Adoption, zwei SQL-Restarts und committed Binding' -Success (
    $text -match '-RequireSqlReadiness' -and $text -match '-ExpectedSqlMajorVersion 16' -and
    $text -match '-AdoptLegacySqlIdentity' -and
    $text -match 'SqlRestartEvidenceCount\s+-ne\s+2' -and $text -match 'BindingCommitted'
)
Add-CheckResult -Name 'Erfolgs-Cleanup validiert exakten temporaeren Root und entfernt Kandidat sowie State' -Success (
    $text -match 'Assert-LegacySqlBootstrapStateRoot' -and
    $text -match "\^SqlServerLab-Legacy-Sql-Acceptance-\[a-f0-9\]\{8\}\$" -and
    $text -match 'Remove-SqlServerLab[\s\S]+Remove-Item -LiteralPath \$validatedLegacyRoot'
)

Write-Host ''; Write-Host "Ergebnis: $passed PASS, $($failures.Count) FAIL" -ForegroundColor Cyan
if ($failures.Count) { exit 1 }; exit 0
