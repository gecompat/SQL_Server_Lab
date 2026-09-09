#Requires -Version 7.2
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$modulePath = Join-Path $repoRoot 'SqlServerLab.psd1'
$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) "run-state-upgrade-$([guid]::NewGuid().ToString('N'))"
$failures = [Collections.Generic.List[string]]::new()
$passed = 0
. (Join-Path $PSScriptRoot '..\Common\CheckResult.ps1')

try {
    $legacyRunId = 'legacy-run'
    $currentRunId = 'current-run'
    $blockedRunId = 'blocked-run'
    foreach ($run in @(
            [PSCustomObject]@{ RunId = $legacyRunId; State = [PSCustomObject]@{ runId = $legacyRunId; scopeId = 'legacy-scope'; state = 'STOPPED'; metadata = [PSCustomObject]@{}; instances = @(); errors = @() } },
            [PSCustomObject]@{ RunId = $currentRunId; State = [PSCustomObject]@{ contractVersion = 'SqlServerLab.RunState/1.0'; runId = $currentRunId; scopeId = 'current-scope'; state = 'STOPPED'; providerSubRuns = @(); metadata = [PSCustomObject]@{}; instances = @(); errors = @() } },
            [PSCustomObject]@{ RunId = $blockedRunId; State = [PSCustomObject]@{ runId = $blockedRunId; state = 'UNSUPPORTED'; metadata = [PSCustomObject]@{} } }
        )) {
        $runDirectory = Join-Path (Join-Path $temporaryRoot 'runs') $run.RunId
        New-Item -ItemType Directory -Path $runDirectory -Force | Out-Null
        $run.State | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $runDirectory 'run-state.json') -Encoding utf8
    }

    Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
    $module = Import-Module $modulePath -Force -PassThru
    $results = & $module {
        param($StateRoot, $LegacyRunId, $CurrentRunId, $BlockedRunId)
        [PSCustomObject]@{
            Legacy = Get-SqlServerLabRunStateUpgradePlan -RunId $LegacyRunId -StateRoot $StateRoot
            Current = Get-SqlServerLabRunStateUpgradePlan -RunId $CurrentRunId -StateRoot $StateRoot
            Blocked = Get-SqlServerLabRunStateUpgradePlan -RunId $BlockedRunId -StateRoot $StateRoot
        }
    } $temporaryRoot $legacyRunId $currentRunId $blockedRunId

    Add-CheckResult -Name 'Legacy-Run-State erhält einen stabilen read-only Upgrade-Plan' -Success (
        $results.Legacy.ContractVersion -eq 'SqlServerLab.RunStateUpgradePlan/1.0' -and
        $results.Legacy.Status -eq 'READY' -and $results.Legacy.Action -eq 'MANUAL_UPGRADE_REQUIRED' -and
        -not $results.Legacy.ExecutionImplemented -and
        @($results.Legacy.Changes.Kind) -contains 'SET_CONTRACT_VERSION' -and
        @($results.Legacy.Changes.Kind) -contains 'ADD_PROVIDER_SUBRUNS')
    Add-CheckResult -Name 'Aktueller Run-State bleibt als No-op ohne Migrationsausführung klassifiziert' -Success (
        $results.Current.Status -eq 'NO_ACTION' -and $results.Current.Action -eq 'NO_ACTION' -and
        @($results.Current.Changes).Count -eq 0 -and -not $results.Current.ExecutionImplemented)
    Add-CheckResult -Name 'Unvollständiger oder unbekannter Run-State bleibt fail-closed blockiert' -Success (
        $results.Blocked.Status -eq 'BLOCKED' -and $results.Blocked.Action -eq 'MANUAL_REVIEW_REQUIRED' -and
        @($results.Blocked.Blockers) -contains 'RUN_STATE_REQUIRED_FIELD_MISSING:scopeId' -and
        @($results.Blocked.Blockers) -contains 'RUN_STATE_STATE_UNSUPPORTED')
    Add-CheckResult -Name 'Upgrade-Plan gibt keinen lokalen State-Root aus' -Success (
        ($results | ConvertTo-Json -Depth 20) -notmatch [regex]::Escape($temporaryRoot))
}
finally {
    Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures.Count -gt 0) {
    Write-Error "$($failures.Count) Checks fehlgeschlagen."
    exit 1
}
Write-Host "$passed Checks bestanden." -ForegroundColor Green