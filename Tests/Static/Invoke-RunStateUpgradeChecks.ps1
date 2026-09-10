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
    $unmarkedRunId = 'unmarked-legacy-run'
    foreach ($run in @(
            [PSCustomObject]@{ RunId = $legacyRunId; State = [PSCustomObject]@{ runId = $legacyRunId; scopeId = 'legacy-scope'; state = 'STOPPED'; metadata = [PSCustomObject]@{ syntheticStateFixture = $true }; instances = @(); errors = @() } },
            [PSCustomObject]@{ RunId = $currentRunId; State = [PSCustomObject]@{ contractVersion = 'SqlServerLab.RunState/1.0'; runId = $currentRunId; scopeId = 'current-scope'; state = 'STOPPED'; providerSubRuns = @(); metadata = [PSCustomObject]@{}; instances = @(); errors = @() } },
            [PSCustomObject]@{ RunId = $blockedRunId; State = [PSCustomObject]@{ runId = $blockedRunId; state = 'UNSUPPORTED'; metadata = [PSCustomObject]@{} } },
            [PSCustomObject]@{ RunId = $unmarkedRunId; State = [PSCustomObject]@{ runId = $unmarkedRunId; scopeId = 'unmarked-scope'; state = 'STOPPED'; metadata = [PSCustomObject]@{}; instances = @(); errors = @() } }
        )) {
        $runDirectory = Join-Path (Join-Path $temporaryRoot 'runs') $run.RunId
        New-Item -ItemType Directory -Path $runDirectory -Force | Out-Null
        $run.State | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $runDirectory 'run-state.json') -Encoding utf8
    }

    Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
    $module = Import-Module $modulePath -Force -PassThru
    $results = & $module {
        param($StateRoot, $LegacyRunId, $CurrentRunId, $BlockedRunId, $UnmarkedRunId)
        $legacy = Get-SqlServerLabRunStateUpgradePlan -RunId $LegacyRunId -StateRoot $StateRoot
        $current = Get-SqlServerLabRunStateUpgradePlan -RunId $CurrentRunId -StateRoot $StateRoot
        $blocked = Get-SqlServerLabRunStateUpgradePlan -RunId $BlockedRunId -StateRoot $StateRoot
        $unmarked = Get-SqlServerLabRunStateUpgradePlan -RunId $UnmarkedRunId -StateRoot $StateRoot
        $legacyWhatIf = Invoke-SqlServerLabRunStateUpgrade -RunId $LegacyRunId -StateRoot $StateRoot -WhatIf
        $legacyExecution = Invoke-SqlServerLabRunStateUpgrade -RunId $LegacyRunId -StateRoot $StateRoot -Confirm:$false
        $legacyAfter = Get-SqlServerLabRunStateUpgradePlan -RunId $LegacyRunId -StateRoot $StateRoot
        $legacyJournal = Get-ChildItem -LiteralPath (Join-Path (Join-Path $StateRoot 'runs') $LegacyRunId) -Filter 'run-state-upgrade-*.journal.json' | Select-Object -First 1 | Get-Content -Raw | ConvertFrom-Json
        $unsupportedPath = Join-Path (Join-Path (Join-Path $StateRoot 'runs') $CurrentRunId) 'run-state.json'
        $unsupported = Get-Content -LiteralPath $unsupportedPath -Raw | ConvertFrom-Json
        $unsupported.contractVersion = 'SqlServerLab.RunState/9.9'
        $unsupported | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $unsupportedPath -Encoding utf8
        $unsupportedPlan = Get-SqlServerLabRunStateUpgradePlan -RunId $CurrentRunId -StateRoot $StateRoot
        [PSCustomObject]@{ Legacy=$legacy;Current=$current;Blocked=$blocked;Unmarked=$unmarked;LegacyWhatIf=$legacyWhatIf;LegacyExecution=$legacyExecution;LegacyAfter=$legacyAfter;LegacyJournal=$legacyJournal;Unsupported=$unsupportedPlan }
    } $temporaryRoot $legacyRunId $currentRunId $blockedRunId $unmarkedRunId

    Add-CheckResult -Name 'Legacy-Run-State erhält einen stabilen read-only Upgrade-Plan' -Success (
        $results.Legacy.ContractVersion -eq 'SqlServerLab.RunStateUpgradePlan/1.0' -and
        $results.Legacy.Status -eq 'READY' -and $results.Legacy.Action -eq 'EXECUTE_SYNTHETIC_UPGRADE' -and
        $results.Legacy.ExecutionImplemented -and $results.Legacy.SyntheticFixture -and
        @($results.Legacy.Changes.Kind) -contains 'SET_CONTRACT_VERSION' -and
        @($results.Legacy.Changes.Kind) -contains 'ADD_PROVIDER_SUBRUNS')
    Add-CheckResult -Name 'Aktueller Run-State bleibt als No-op ohne Migrationsausführung klassifiziert' -Success (
        $results.Current.Status -eq 'NO_ACTION' -and $results.Current.Action -eq 'NO_ACTION' -and
        @($results.Current.Changes).Count -eq 0 -and $results.Current.ExecutionImplemented)
    Add-CheckResult -Name 'Unvollständiger oder unbekannter Run-State bleibt fail-closed blockiert' -Success (
        $results.Blocked.Status -eq 'BLOCKED' -and $results.Blocked.Action -eq 'MANUAL_REVIEW_REQUIRED' -and
        @($results.Blocked.Blockers) -contains 'RUN_STATE_REQUIRED_FIELD_MISSING:scopeId' -and
        @($results.Blocked.Blockers) -contains 'RUN_STATE_STATE_UNSUPPORTED')
    Add-CheckResult -Name 'WhatIf plant die Upgrade-Mutation ohne State-Commit' -Success (
        $results.LegacyWhatIf.Status -eq 'PLAN_ONLY' -and $results.LegacyWhatIf.RollbackStatus -eq 'NOT_STARTED')
    Add-CheckResult -Name 'Synthetischer Legacy-State wird atomar migriert und anschließend No-op' -Success (
        $results.LegacyExecution.Status -eq 'UPGRADED' -and $results.LegacyExecution.RollbackStatus -eq 'NOT_REQUIRED' -and
        $results.LegacyAfter.Status -eq 'NO_ACTION' -and $results.LegacyJournal.Status -eq 'COMPLETED')
    Add-CheckResult -Name 'Unbekannte Vertragsversion bleibt vor Ausführung fail-closed blockiert' -Success (
        $results.Unsupported.Status -eq 'BLOCKED' -and @($results.Unsupported.Blockers) -contains 'RUN_STATE_CONTRACT_UNSUPPORTED:SqlServerLab.RunState/9.9')
    Add-CheckResult -Name 'Unmarkierter Legacy-State bleibt vor automatischer Migration blockiert' -Success (
        $results.Unmarked.Status -eq 'BLOCKED' -and @($results.Unmarked.Blockers) -contains 'RUN_STATE_UPGRADE_SYNTHETIC_FIXTURE_REQUIRED')
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
