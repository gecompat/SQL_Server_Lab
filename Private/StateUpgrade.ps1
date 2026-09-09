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
    $state = Get-LabRunState -RunId $RunId -StateRoot $StateRoot
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
    $changes = [System.Collections.Generic.List[object]]::new()
    if ($sourceContractVersion -ne $targetContractVersion) {
        $changes.Add([PSCustomObject]@{ Kind = 'SET_CONTRACT_VERSION'; Status = 'PENDING' })
    }
    if (-not $state.PSObject.Properties['providerSubRuns']) {
        $changes.Add([PSCustomObject]@{ Kind = 'ADD_PROVIDER_SUBRUNS'; Status = 'PENDING' })
    }

    $status = if ($blockers.Count -gt 0) { 'BLOCKED' } elseif ($changes.Count -gt 0) { 'READY' } else { 'NO_ACTION' }
    $fingerprint = "$RunId|$sourceContractVersion|$targetContractVersion"
    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($fingerprint))).ToLowerInvariant()
    return [PSCustomObject]@{
        ContractVersion = 'SqlServerLab.RunStateUpgradePlan/1.0'
        PlanId = "run-state-upgrade-$hash"
        RunId = [string]$state.runId
        SourceContractVersion = $sourceContractVersion
        TargetContractVersion = $targetContractVersion
        Status = $status
        Action = if ($status -eq 'READY') { 'MANUAL_UPGRADE_REQUIRED' } elseif ($status -eq 'BLOCKED') { 'MANUAL_REVIEW_REQUIRED' } else { 'NO_ACTION' }
        ExecutionImplemented = $false
        Changes = @($changes)
        Blockers = @($blockers)
    }
}