<#
.SYNOPSIS
    Bewertet die Upgrade-Fähigkeit eines lokalen Run-State.
.DESCRIPTION
    Der erste Upgrade-Slice erzeugt ausschließlich einen sanitierten,
    nicht ausführbaren Plan. Er verändert weder Run-State noch Runtime.
#>

function Get-LabRunStateUpgradePlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [string]$StateRoot
    )

    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
    $runDirectory = Join-Path (Join-Path $StateRoot 'runs') $RunId
    $statePath = Join-Path $runDirectory 'run-state.json'
    $sourceJson = Get-Content -LiteralPath $statePath -Raw -Encoding utf8
    $sourceStateSha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($sourceJson))).ToLowerInvariant()
    $state = $sourceJson | ConvertFrom-Json -Depth 20
    $blockers = [System.Collections.Generic.List[string]]::new()
    foreach ($fieldName in @('runId', 'scopeId', 'state')) {
        if (-not $state.PSObject.Properties[$fieldName] -or [string]::IsNullOrWhiteSpace([string]$state.$fieldName)) {
            $blockers.Add("RUN_STATE_REQUIRED_FIELD_MISSING:$fieldName")
        }
    }
    if ($state.PSObject.Properties['runId'] -and [string]$state.runId -ne $RunId) {
        $blockers.Add('RUN_STATE_ID_MISMATCH')
    }
    if ($state.PSObject.Properties['state'] -and -not (Get-LabStateTransitionMap).ContainsKey([string]$state.state)) {
        $blockers.Add('RUN_STATE_STATE_UNSUPPORTED')
    }

    $targetContractVersion = 'SqlServerLab.RunState/1.0'
    $sourceContractVersion = if ($state.PSObject.Properties['contractVersion']) {
        [string]$state.contractVersion
    }
    else {
        'UNVERSIONED_LEGACY'
    }
    $syntheticLegacy = $false
    if ($state.PSObject.Properties['metadata'] -and $state.metadata -and
        $state.metadata.PSObject.Properties['syntheticStateFixture']) {
        $syntheticLegacy = [bool]$state.metadata.syntheticStateFixture
    }
    if ($sourceContractVersion -notin @('UNVERSIONED_LEGACY', $targetContractVersion)) {
        $blockers.Add("RUN_STATE_CONTRACT_UNSUPPORTED:$sourceContractVersion")
    }
    if ($sourceContractVersion -eq 'UNVERSIONED_LEGACY' -and -not $syntheticLegacy) {
        $blockers.Add('RUN_STATE_UPGRADE_SYNTHETIC_FIXTURE_REQUIRED')
    }

    $changes = [System.Collections.Generic.List[object]]::new()
    if ($sourceContractVersion -eq 'UNVERSIONED_LEGACY') {
        $changes.Add([PSCustomObject]@{ Kind = 'SET_CONTRACT_VERSION'; Status = 'PENDING' })
    }
    if (-not $state.PSObject.Properties['providerSubRuns']) {
        $changes.Add([PSCustomObject]@{ Kind = 'ADD_PROVIDER_SUBRUNS'; Status = 'PENDING' })
    }

    $status = if ($blockers.Count -gt 0) { 'BLOCKED' } elseif ($changes.Count -gt 0) { 'READY' } else { 'NO_ACTION' }
    $fingerprint = "$RunId|$sourceContractVersion|$targetContractVersion|$sourceStateSha256"
    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($fingerprint))).ToLowerInvariant()
    return [PSCustomObject]@{
        ContractVersion = 'SqlServerLab.RunStateUpgradePlan/1.0'
        PlanId = "run-state-upgrade-$hash"
        RunId = [string]$state.runId
        SourceContractVersion = $sourceContractVersion
        TargetContractVersion = $targetContractVersion
        Status = $status
        Action = if ($status -eq 'READY') { 'EXECUTE_SYNTHETIC_UPGRADE' } elseif ($status -eq 'BLOCKED') { 'MANUAL_REVIEW_REQUIRED' } else { 'NO_ACTION' }
        ExecutionImplemented = $true
        SourceStateSha256 = $sourceStateSha256
        SyntheticFixture = $syntheticLegacy
        Changes = @($changes)
        Blockers = @($blockers)
    }
}

function Write-LabRunStateUpgradeRawAtomic {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Content
    )

    $temporaryPath = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($temporaryPath, $Content, [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temporaryPath, $Path, $true)
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }
}

function Resume-LabRunStateUpgrade {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [string]$StateRoot
    )

    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
    $runDirectory = Join-Path (Join-Path $StateRoot 'runs') $RunId
    $journals = @(
        Get-ChildItem -LiteralPath $runDirectory -Filter 'run-state-upgrade-*.journal.json' -File |
            ForEach-Object {
                try { [PSCustomObject]@{ Path = $_.FullName; Journal = Get-Content -LiteralPath $_.FullName -Raw -Encoding utf8 | ConvertFrom-Json -Depth 20 } }
                catch { $null }
            } | Where-Object { $_ -and [string]$_.Journal.Status -eq 'PENDING' }
    )
    if ($journals.Count -ne 1) { throw 'RUN_STATE_UPGRADE_RESUME_JOURNAL_AMBIGUOUS_OR_MISSING' }
    $entry = $journals[0]
    $journal = $entry.Journal
    if ([string]$journal.ContractVersion -ne 'SqlServerLab.RunStateUpgradeJournal/1.0' -or
        [string]$journal.RunId -ne $RunId -or [string]::IsNullOrWhiteSpace([string]$journal.PlanId) -or
        [string]::IsNullOrWhiteSpace([string]$journal.SourceStateSha256) -or
        [string]::IsNullOrWhiteSpace([string]$journal.TargetContractVersion)) {
        throw 'RUN_STATE_UPGRADE_RESUME_JOURNAL_INVALID'
    }
    $sourcePath = Join-Path $runDirectory "run-state-upgrade-$($journal.PlanId).source.json"
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) { throw 'RUN_STATE_UPGRADE_RESUME_SOURCE_MISSING' }
    $sourceJson = Get-Content -LiteralPath $sourcePath -Raw -Encoding utf8
    $sourceHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($sourceJson))).ToLowerInvariant()
    if ($sourceHash -ne [string]$journal.SourceStateSha256) { throw 'RUN_STATE_UPGRADE_RESUME_SOURCE_CHANGED' }
    $statePath = Join-Path $runDirectory 'run-state.json'
    $currentJson = Get-Content -LiteralPath $statePath -Raw -Encoding utf8
    $currentHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($currentJson))).ToLowerInvariant()
    if ($currentHash -eq $sourceHash) { throw 'RUN_STATE_UPGRADE_RESUME_MUTATION_NOT_OBSERVED' }
    try { $current = $currentJson | ConvertFrom-Json -Depth 20 } catch { throw 'RUN_STATE_UPGRADE_RESUME_STATE_INVALID' }
    if ([string]$current.runId -ne $RunId -or [string]$current.contractVersion -ne [string]$journal.TargetContractVersion -or
        -not $current.PSObject.Properties['providerSubRuns']) { throw 'RUN_STATE_UPGRADE_RESUME_POSTCONDITION_FAILED' }
    $journal.Status = 'COMPLETED'; $journal.RollbackStatus = 'NOT_REQUIRED'; $journal.CompletedAt = Get-LabTimestamp
    Write-LabArtifactJsonAtomic -Path $entry.Path -InputObject $journal
    return [PSCustomObject]@{
        ContractVersion = 'SqlServerLab.RunStateUpgradeResult/1.0'; RunId = $RunId; PlanId = [string]$journal.PlanId
        Status = 'RESUMED'; SourceStateSha256 = [string]$journal.SourceStateSha256; TargetContractVersion = [string]$journal.TargetContractVersion
        RollbackStatus = 'NOT_REQUIRED'; Blockers = @()
    }
}

function Invoke-LabRunStateUpgrade {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [switch]$Resume,
        [string]$StateRoot
    )

    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
    if ($Resume) { return Resume-LabRunStateUpgrade -RunId $RunId -StateRoot $StateRoot }
    $plan = Get-LabRunStateUpgradePlan -RunId $RunId -StateRoot $StateRoot
    if ($plan.Status -eq 'BLOCKED') {
        return [PSCustomObject]@{
            ContractVersion = 'SqlServerLab.RunStateUpgradeResult/1.0'; RunId = $plan.RunId
            PlanId = $plan.PlanId; Status = 'BLOCKED'; SourceStateSha256 = $plan.SourceStateSha256
            TargetContractVersion = $plan.TargetContractVersion; RollbackStatus = 'NOT_STARTED'; Blockers = @($plan.Blockers)
        }
    }
    if ($plan.Status -eq 'NO_ACTION') {
        return [PSCustomObject]@{
            ContractVersion = 'SqlServerLab.RunStateUpgradeResult/1.0'; RunId = $plan.RunId
            PlanId = $plan.PlanId; Status = 'NO_ACTION'; SourceStateSha256 = $plan.SourceStateSha256
            TargetContractVersion = $plan.TargetContractVersion; RollbackStatus = 'NOT_REQUIRED'; Blockers = @()
        }
    }

    $runDirectory = Join-Path (Join-Path $StateRoot 'runs') $RunId
    $statePath = Join-Path $runDirectory 'run-state.json'
    $journalPath = Join-Path $runDirectory "run-state-upgrade-$($plan.PlanId).journal.json"
    $sourcePath = Join-Path $runDirectory "run-state-upgrade-$($plan.PlanId).source.json"
    $originalJson = Get-Content -LiteralPath $statePath -Raw -Encoding utf8
    $observedHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($originalJson))).ToLowerInvariant()
    if ($observedHash -ne $plan.SourceStateSha256) { throw 'RUN_STATE_UPGRADE_SOURCE_CHANGED' }

    $journal = [ordered]@{
        ContractVersion = 'SqlServerLab.RunStateUpgradeJournal/1.0'; PlanId = $plan.PlanId; RunId = $RunId
        SourceStateSha256 = $plan.SourceStateSha256; TargetContractVersion = $plan.TargetContractVersion
        Status = 'PENDING'; RollbackStatus = 'NOT_STARTED'; StartedAt = Get-LabTimestamp; CompletedAt = $null
    }
    Write-LabRunStateUpgradeRawAtomic -Path $sourcePath -Content $originalJson
    Write-LabArtifactJsonAtomic -Path $journalPath -InputObject ([PSCustomObject]$journal)

    $stateMutated = $false
    try {
        $migrated = $originalJson | ConvertFrom-Json -Depth 20
        $migrated | Add-Member -NotePropertyName contractVersion -NotePropertyValue $plan.TargetContractVersion -Force
        if (-not $migrated.PSObject.Properties['providerSubRuns']) {
            $migrated | Add-Member -NotePropertyName providerSubRuns -NotePropertyValue @()
        }
        Write-LabArtifactJsonAtomic -Path $statePath -InputObject $migrated
        $stateMutated = $true
        $verified = Get-LabRunState -RunId $RunId -StateRoot $StateRoot
        if ([string]$verified.contractVersion -ne $plan.TargetContractVersion -or -not $verified.PSObject.Properties['providerSubRuns']) {
            throw 'RUN_STATE_UPGRADE_POSTCONDITION_FAILED'
        }
        $journal.Status = 'COMPLETED'; $journal.RollbackStatus = 'NOT_REQUIRED'; $journal.CompletedAt = Get-LabTimestamp
        Write-LabArtifactJsonAtomic -Path $journalPath -InputObject ([PSCustomObject]$journal)
        return [PSCustomObject]@{
            ContractVersion = 'SqlServerLab.RunStateUpgradeResult/1.0'; RunId = $RunId; PlanId = $plan.PlanId
            Status = 'UPGRADED'; SourceStateSha256 = $plan.SourceStateSha256; TargetContractVersion = $plan.TargetContractVersion
            RollbackStatus = 'NOT_REQUIRED'; Blockers = @()
        }
    }
    catch {
        $failure = $_
        $rollbackStatus = 'NOT_REQUIRED'
        if ($stateMutated) {
            try { Write-LabRunStateUpgradeRawAtomic -Path $statePath -Content $originalJson; $rollbackStatus = 'RESTORED' }
            catch { $rollbackStatus = 'RECOVERY_REQUIRED' }
        }
        $journal.Status = if ($rollbackStatus -eq 'RECOVERY_REQUIRED') { 'RECOVERY_REQUIRED' } else { 'ROLLED_BACK' }
        $journal.RollbackStatus = $rollbackStatus; $journal.CompletedAt = Get-LabTimestamp
        try { Write-LabArtifactJsonAtomic -Path $journalPath -InputObject ([PSCustomObject]$journal) } catch {}
        throw $failure
    }
}
