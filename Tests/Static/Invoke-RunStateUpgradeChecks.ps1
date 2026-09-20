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
    $explicitLegacyRunId = 'explicit-legacy-run'
    $missingVersionRunId = 'missing-version-run'
    $malformedVersionRunId = 'malformed-version-run'
    $alternateCurrentRunId = 'alternate-current-run'
    foreach ($run in @(
            [PSCustomObject]@{ RunId = $legacyRunId; State = [PSCustomObject]@{ runId = $legacyRunId; scopeId = 'legacy-scope'; state = 'STOPPED'; metadata = [PSCustomObject]@{ syntheticStateFixture = $true }; instances = @(); errors = @() } },
            [PSCustomObject]@{ RunId = $currentRunId; State = [PSCustomObject]@{ contractVersion = 'SqlServerLab.RunState/1.0'; runId = $currentRunId; scopeId = 'current-scope'; state = 'STOPPED'; providerSubRuns = @(); metadata = [PSCustomObject]@{}; instances = @(); errors = @() } },
            [PSCustomObject]@{ RunId = $blockedRunId; State = [PSCustomObject]@{ runId = $blockedRunId; state = 'UNSUPPORTED'; metadata = [PSCustomObject]@{} } },
            [PSCustomObject]@{ RunId = $unmarkedRunId; State = [PSCustomObject]@{ runId = $unmarkedRunId; scopeId = 'unmarked-scope'; state = 'STOPPED'; metadata = [PSCustomObject]@{}; instances = @(); errors = @() } },
            [PSCustomObject]@{ RunId = $explicitLegacyRunId; State = [PSCustomObject]@{ contractVersion = 'UNVERSIONED_LEGACY'; runId = $explicitLegacyRunId; scopeId = 'explicit-legacy-scope'; state = 'STOPPED'; metadata = [PSCustomObject]@{ syntheticStateFixture = $true }; instances = @(); errors = @() } },
            [PSCustomObject]@{ RunId = $missingVersionRunId; State = [PSCustomObject]@{ runId = $missingVersionRunId; scopeId = 'missing-version-scope'; state = 'STOPPED'; metadata = [PSCustomObject]@{}; instances = @(); errors = @() } },
            [PSCustomObject]@{ RunId = $malformedVersionRunId; State = [PSCustomObject]@{ contractVersion = [PSCustomObject]@{ major = 1 }; runId = $malformedVersionRunId; scopeId = 'malformed-version-scope'; state = 'STOPPED'; metadata = [PSCustomObject]@{ syntheticStateFixture = $true }; instances = @(); errors = @() } },
            [PSCustomObject]@{ RunId = $alternateCurrentRunId; State = [PSCustomObject]@{ contractVersion = 'SqlServerLab.RunState/1.0'; runId = $alternateCurrentRunId; scopeId = 'alternate-current-scope'; state = 'STOPPED'; providerSubRuns = @(); metadata = [PSCustomObject]@{}; instances = @(); errors = @() } }
        )) {
        $runDirectory = Join-Path (Join-Path $temporaryRoot 'runs') $run.RunId
        New-Item -ItemType Directory -Path $runDirectory -Force | Out-Null
        $run.State | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $runDirectory 'run-state.json') -Encoding utf8
    }

    Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
    $module = Import-Module $modulePath -Force -PassThru
    $results = & $module {
        param($StateRoot, $LegacyRunId, $CurrentRunId, $BlockedRunId, $UnmarkedRunId, $ExplicitLegacyRunId, $MissingVersionRunId, $MalformedVersionRunId, $AlternateCurrentRunId)
        $getStateSnapshot = {
            param($Root)
            @(
                Get-ChildItem -LiteralPath $Root -File -Recurse |
                    Sort-Object FullName |
                    ForEach-Object {
                        $relativePath = [IO.Path]::GetRelativePath($Root, $_.FullName).Replace('\', '/')
                        $hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
                        "$relativePath|$hash|$($_.LastWriteTimeUtc.Ticks)"
                    }
            )
        }
        $freshRun = New-LabRunState -StateRoot $StateRoot -Metadata @{ name = 'synthetic-fresh-run' }
        $freshState = Get-LabRunState -RunId $freshRun.RunId -StateRoot $StateRoot
        $snapshotBeforePlanning = & $getStateSnapshot $StateRoot
        $freshPlan = Get-SqlServerLabRunStateUpgradePlan -RunId $freshRun.RunId -StateRoot $StateRoot
        $freshExecution = Invoke-SqlServerLabRunStateUpgrade -RunId $freshRun.RunId -StateRoot $StateRoot -Confirm:$false
        $freshRepeat = Get-SqlServerLabRunStateUpgradePlan -RunId $freshRun.RunId -StateRoot $StateRoot
        $legacy = Get-SqlServerLabRunStateUpgradePlan -RunId $LegacyRunId -StateRoot $StateRoot
        $current = Get-SqlServerLabRunStateUpgradePlan -RunId $CurrentRunId -StateRoot $StateRoot
        $currentRepeat = Get-SqlServerLabRunStateUpgradePlan -RunId $CurrentRunId -StateRoot $StateRoot
        $explicitLegacy = Get-SqlServerLabRunStateUpgradePlan -RunId $ExplicitLegacyRunId -StateRoot $StateRoot
        $missingVersion = Get-SqlServerLabRunStateUpgradePlan -RunId $MissingVersionRunId -StateRoot $StateRoot
        $malformedVersion = Get-SqlServerLabRunStateUpgradePlan -RunId $MalformedVersionRunId -StateRoot $StateRoot
        $alternateCurrent = Get-SqlServerLabRunStateUpgradePlan -RunId $AlternateCurrentRunId -StateRoot $StateRoot
        $blocked = Get-SqlServerLabRunStateUpgradePlan -RunId $BlockedRunId -StateRoot $StateRoot
        $unmarked = Get-SqlServerLabRunStateUpgradePlan -RunId $UnmarkedRunId -StateRoot $StateRoot
        $snapshotAfterPlanning = & $getStateSnapshot $StateRoot
        $expectedCurrentSourceHash = (Get-Content -LiteralPath (Join-Path (Join-Path (Join-Path $StateRoot 'runs') $CurrentRunId) 'run-state.json') -Raw -Encoding utf8)
        $expectedCurrentSourceHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($expectedCurrentSourceHash))).ToLowerInvariant()
        $expectedCurrentPlanFingerprint = "$CurrentRunId|SqlServerLab.RunState/1.0|SqlServerLab.RunState/1.0|$expectedCurrentSourceHash"
        $expectedCurrentPlanId = 'run-state-upgrade-' + [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($expectedCurrentPlanFingerprint))).ToLowerInvariant()
        $expectedAlternateSourceHash = (Get-Content -LiteralPath (Join-Path (Join-Path (Join-Path $StateRoot 'runs') $AlternateCurrentRunId) 'run-state.json') -Raw -Encoding utf8)
        $expectedAlternateSourceHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($expectedAlternateSourceHash))).ToLowerInvariant()
        $legacyWhatIf = Invoke-SqlServerLabRunStateUpgrade -RunId $LegacyRunId -StateRoot $StateRoot -WhatIf
        $legacyExecution = Invoke-SqlServerLabRunStateUpgrade -RunId $LegacyRunId -StateRoot $StateRoot -Confirm:$false
        $legacyAfter = Get-SqlServerLabRunStateUpgradePlan -RunId $LegacyRunId -StateRoot $StateRoot
        $legacyRunDirectory = Join-Path (Join-Path $StateRoot 'runs') $LegacyRunId
        $legacyJournalPath = Get-ChildItem -LiteralPath $legacyRunDirectory -Filter 'run-state-upgrade-*.journal.json' | Select-Object -First 1 -ExpandProperty FullName
        $legacyJournal = Get-Content -LiteralPath $legacyJournalPath -Raw | ConvertFrom-Json
        $legacyCompletedJournal = $legacyJournal | ConvertTo-Json -Depth 20 | ConvertFrom-Json
        $legacyJournal.Status = 'PENDING'; $legacyJournal.RollbackStatus = 'NOT_STARTED'; $legacyJournal.CompletedAt = $null
        $legacyJournal | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $legacyJournalPath -Encoding utf8
        $legacyResume = Invoke-SqlServerLabRunStateUpgrade -RunId $LegacyRunId -StateRoot $StateRoot -Resume -Confirm:$false
        $legacyResumedJournal = Get-Content -LiteralPath $legacyJournalPath -Raw | ConvertFrom-Json
        $legacyCompletedResumeJournal = $legacyResumedJournal | ConvertTo-Json -Depth 20 | ConvertFrom-Json
        $legacySourcePath = Join-Path $legacyRunDirectory "run-state-upgrade-$($legacyJournal.PlanId).source.json"
        Set-Content -LiteralPath $legacySourcePath -Value '{"tampered":true}' -Encoding utf8
        $legacyResumedJournal.Status = 'PENDING'; $legacyResumedJournal.RollbackStatus = 'NOT_STARTED'; $legacyResumedJournal.CompletedAt = $null
        $legacyResumedJournal | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $legacyJournalPath -Encoding utf8
        $resumeSourceChanged = try { Invoke-SqlServerLabRunStateUpgrade -RunId $LegacyRunId -StateRoot $StateRoot -Resume -Confirm:$false; $false } catch { $_.Exception.Message -eq 'RUN_STATE_UPGRADE_RESUME_SOURCE_CHANGED' }
        $unsupportedPath = Join-Path (Join-Path (Join-Path $StateRoot 'runs') $CurrentRunId) 'run-state.json'
        $unsupported = Get-Content -LiteralPath $unsupportedPath -Raw | ConvertFrom-Json
        $unsupported.contractVersion = 'SqlServerLab.RunState/9.9'
        $unsupported | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $unsupportedPath -Encoding utf8
        $unsupportedPlan = Get-SqlServerLabRunStateUpgradePlan -RunId $CurrentRunId -StateRoot $StateRoot
        [PSCustomObject]@{
            FreshState=$freshState;FreshPlan=$freshPlan;FreshExecution=$freshExecution;FreshRepeat=$freshRepeat
            Legacy=$legacy;Current=$current;CurrentRepeat=$currentRepeat;ExplicitLegacy=$explicitLegacy;MissingVersion=$missingVersion;MalformedVersion=$malformedVersion;AlternateCurrent=$alternateCurrent;SnapshotBeforePlanning=$snapshotBeforePlanning;SnapshotAfterPlanning=$snapshotAfterPlanning;ExpectedCurrentSourceHash=$expectedCurrentSourceHash;ExpectedCurrentPlanId=$expectedCurrentPlanId;ExpectedAlternateSourceHash=$expectedAlternateSourceHash;Blocked=$blocked;Unmarked=$unmarked;LegacyWhatIf=$legacyWhatIf;LegacyExecution=$legacyExecution;LegacyAfter=$legacyAfter;LegacyJournal=$legacyCompletedJournal;LegacyResume=$legacyResume;LegacyResumedJournal=$legacyCompletedResumeJournal;ResumeSourceChanged=$resumeSourceChanged;Unsupported=$unsupportedPlan
        }
    } $temporaryRoot $legacyRunId $currentRunId $blockedRunId $unmarkedRunId $explicitLegacyRunId $missingVersionRunId $malformedVersionRunId $alternateCurrentRunId

    Add-CheckResult -Name 'Frisch erzeugter Run-State persistiert den aktuellen Vertrag ohne Legacy-Markierung' -Success (
        $results.FreshState.contractVersion -eq 'SqlServerLab.RunState/1.0' -and
        $results.FreshState.state -eq 'INITIALIZING' -and
        $null -ne $results.FreshState.PSObject.Properties['providerSubRuns'] -and
        $null -eq $results.FreshState.metadata.PSObject.Properties['syntheticStateFixture'])
    Add-CheckResult -Name 'Frisch erzeugter Run-State wird ohne Upgradebedarf klassifiziert' -Success (
        $results.FreshPlan.SourceContractVersion -eq 'SqlServerLab.RunState/1.0' -and
        $results.FreshPlan.TargetContractVersion -eq 'SqlServerLab.RunState/1.0' -and
        $results.FreshPlan.Status -eq 'NO_ACTION' -and $results.FreshPlan.Action -eq 'NO_ACTION' -and
        -not $results.FreshPlan.SyntheticFixture -and
        @($results.FreshPlan.Changes).Count -eq 0 -and @($results.FreshPlan.Blockers).Count -eq 0)
    Add-CheckResult -Name 'Upgrade-Aufruf auf frischem State bleibt stabiler No-op ohne Schreibzugriff' -Success (
        $results.FreshExecution.Status -eq 'NO_ACTION' -and
        $results.FreshExecution.RollbackStatus -eq 'NOT_REQUIRED' -and
        $results.FreshRepeat.Status -eq 'NO_ACTION' -and
        $results.FreshRepeat.SourceContractVersion -eq $results.FreshPlan.SourceContractVersion -and
        $results.FreshRepeat.PlanId -eq $results.FreshPlan.PlanId -and
        $results.FreshRepeat.SourceStateSha256 -eq $results.FreshPlan.SourceStateSha256 -and
        (@($results.SnapshotBeforePlanning) -join "`n") -eq (@($results.SnapshotAfterPlanning) -join "`n"))
    Add-CheckResult -Name 'Legacy-Run-State erhält einen stabilen read-only Upgrade-Plan' -Success (
        $results.Legacy.ContractVersion -eq 'SqlServerLab.RunStateUpgradePlan/1.0' -and
        $results.Legacy.Status -eq 'READY' -and $results.Legacy.Action -eq 'EXECUTE_SYNTHETIC_UPGRADE' -and
        $results.Legacy.ExecutionImplemented -and $results.Legacy.SyntheticFixture -and
        @($results.Legacy.Changes.Kind) -contains 'SET_CONTRACT_VERSION' -and
        @($results.Legacy.Changes.Kind) -contains 'ADD_PROVIDER_SUBRUNS')
    Add-CheckResult -Name 'Aktueller Run-State bleibt als No-op ohne Migrationsausführung klassifiziert' -Success (
        $results.Current.Status -eq 'NO_ACTION' -and $results.Current.Action -eq 'NO_ACTION' -and
        @($results.Current.Changes).Count -eq 0 -and $results.Current.ExecutionImplemented)
    Add-CheckResult -Name 'Explizite Legacy-Vertragsversion bleibt für die synthetische Upgrade-Planung gültig' -Success (
        $results.ExplicitLegacy.SourceContractVersion -eq 'UNVERSIONED_LEGACY' -and
        $results.ExplicitLegacy.Status -eq 'READY' -and $results.ExplicitLegacy.SyntheticFixture)
    Add-CheckResult -Name 'Fehlende Vertragsversion bleibt ohne synthetische Fixture fail-closed blockiert' -Success (
        $results.MissingVersion.SourceContractVersion -eq 'UNVERSIONED_LEGACY' -and
        $results.MissingVersion.Status -eq 'BLOCKED' -and
        @($results.MissingVersion.Blockers) -contains 'RUN_STATE_UPGRADE_SYNTHETIC_FIXTURE_REQUIRED')
    Add-CheckResult -Name 'Fehlgeformte Vertragsversion bleibt vor Ausführung fail-closed blockiert' -Success (
        $results.MalformedVersion.Status -eq 'BLOCKED' -and
        (@($results.MalformedVersion.Blockers) | Where-Object { $_ -like 'RUN_STATE_CONTRACT_UNSUPPORTED:*' }).Count -eq 1)
    Add-CheckResult -Name 'Read-only Versionsplanung verändert weder State-Dateien noch erzeugt sie Upgrade-Artefakte' -Success (
        @($results.SnapshotBeforePlanning) -join "`n" -eq (@($results.SnapshotAfterPlanning) -join "`n"))
    Add-CheckResult -Name 'Source-Hash und Plan-ID sind für identische State-Bytes deterministisch' -Success (
        $results.Current.SourceStateSha256 -eq $results.ExpectedCurrentSourceHash -and
        $results.Current.PlanId -eq $results.ExpectedCurrentPlanId -and
        $results.Current.PlanId -eq $results.CurrentRepeat.PlanId -and
        $results.Current.SourceStateSha256 -eq $results.CurrentRepeat.SourceStateSha256)
    Add-CheckResult -Name 'Plan-ID bleibt an die unveränderten Source-Bytes gebunden' -Success (
        $results.AlternateCurrent.SourceStateSha256 -eq $results.ExpectedAlternateSourceHash -and
        $results.Current.SourceStateSha256 -ne $results.AlternateCurrent.SourceStateSha256 -and
        $results.Current.PlanId -ne $results.AlternateCurrent.PlanId)
    Add-CheckResult -Name 'Unvollständiger oder unbekannter Run-State bleibt fail-closed blockiert' -Success (
        $results.Blocked.Status -eq 'BLOCKED' -and $results.Blocked.Action -eq 'MANUAL_REVIEW_REQUIRED' -and
        @($results.Blocked.Blockers) -contains 'RUN_STATE_REQUIRED_FIELD_MISSING:scopeId' -and
        @($results.Blocked.Blockers) -contains 'RUN_STATE_STATE_UNSUPPORTED')
    Add-CheckResult -Name 'WhatIf plant die Upgrade-Mutation ohne State-Commit' -Success (
        $results.LegacyWhatIf.Status -eq 'PLAN_ONLY' -and $results.LegacyWhatIf.RollbackStatus -eq 'NOT_STARTED')
    Add-CheckResult -Name 'Synthetischer Legacy-State wird atomar migriert und anschließend No-op' -Success (
        $results.LegacyExecution.Status -eq 'UPGRADED' -and $results.LegacyExecution.RollbackStatus -eq 'NOT_REQUIRED' -and
        $results.LegacyAfter.Status -eq 'NO_ACTION' -and $results.LegacyJournal.Status -eq 'COMPLETED')
    Add-CheckResult -Name 'PENDING-Upgrade-Journal wird nach atomarem Zielcommit ohne zweite Mutation finalisiert' -Success (
        $results.LegacyResume.Status -eq 'RESUMED' -and $results.LegacyResume.RollbackStatus -eq 'NOT_REQUIRED' -and
        $results.LegacyResumedJournal.Status -eq 'COMPLETED')
    Add-CheckResult -Name 'Resume blockiert eine geänderte gesicherte Source-Revision fail-closed' -Success $results.ResumeSourceChanged
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
