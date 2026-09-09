<#
.SYNOPSIS
    Erstellt einen read-only Inventarplan für bestehende Hyper-V-Recovery-Points.
.DESCRIPTION
    Der erste Recovery-Point-Slice liest ausschließlich eindeutig an einen Run
    gebundene Hyper-V-Checkpoints. Er erzeugt keinen Checkpoint, verändert keine
    VM und führt weder SQL-Quiesce noch Restore aus.
#>

function Get-LabHyperVRecoveryPointContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$InstanceId,
        [string]$StateRoot
    )

    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
    $run = Get-LabRunState -RunId $RunId -StateRoot $StateRoot
    if ([string]$run.metadata.workflowKind -ne 'hyperv-lab') { throw 'HYPERV_RECOVERY_POINT_HYPERV_RUN_REQUIRED' }

    $connectionPath = Join-Path (Join-Path (Join-Path $StateRoot 'runs') $RunId) 'connection-info.json'
    if (-not (Test-Path -LiteralPath $connectionPath -PathType Leaf)) { throw 'HYPERV_RECOVERY_POINT_CONNECTION_MISSING' }
    $connection = Get-Content -LiteralPath $connectionPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 30
    $instances = @($connection.instances | Where-Object { [string]$_.id -eq $InstanceId -and [string]$_.provider -eq 'hyperv' })
    if ($instances.Count -ne 1 -or [string]::IsNullOrWhiteSpace([string]$instances[0].vmName)) {
        throw 'HYPERV_RECOVERY_POINT_CONNECTION_INSTANCE_NOT_UNIQUE'
    }

    $managed = Get-HyperVManagedVM -VMName ([string]$instances[0].vmName) -ExpectedRunId $RunId -ExpectedScopeId ([string]$run.scopeId)
    if (-not $managed) { throw 'HYPERV_RECOVERY_POINT_VM_NOT_FOUND' }
    if ($instances[0].vmId -and [string]$instances[0].vmId -ne [string]$managed.VM.Id) { throw 'HYPERV_RECOVERY_POINT_VM_IDENTITY_MISMATCH' }

    return [PSCustomObject]@{ RunId=$RunId; InstanceId=$InstanceId; Managed=$managed }
}

function Get-LabHyperVRecoveryPointCandidates {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context)

    try {
        return @(Get-VMSnapshot -VM $Context.Managed.VM -ErrorAction Stop | ForEach-Object {
            $kind = switch -Regex ([string]$_.CheckpointType) {
                '^Production$' { 'PRODUCTION'; break }
                '^Standard$' { 'STANDARD'; break }
                default { 'UNKNOWN' }
            }
            [PSCustomObject][ordered]@{
                RecoveryPointId = [string]$_.Id
                Kind = $kind
                CreatedAt = ([datetime]$_.CreationTime).ToUniversalTime().ToString('o')
            }
        })
    }
    catch { throw 'HYPERV_RECOVERY_POINT_SNAPSHOT_QUERY_FAILED' }
}

function Get-LabHyperVRecoveryPointPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$InstanceId,
        [string]$StateRoot
    )

    $allowedBlockers = @(
        'HYPERV_RECOVERY_POINT_HYPERV_RUN_REQUIRED',
        'HYPERV_RECOVERY_POINT_CONNECTION_MISSING',
        'HYPERV_RECOVERY_POINT_CONNECTION_INSTANCE_NOT_UNIQUE',
        'HYPERV_RECOVERY_POINT_VM_NOT_FOUND',
        'HYPERV_RECOVERY_POINT_VM_IDENTITY_MISMATCH',
        'HYPERV_RECOVERY_POINT_SNAPSHOT_QUERY_FAILED',
        'HYPERV_RECOVERY_POINT_CONTEXT_UNAVAILABLE'
    )
    $blockers = [Collections.Generic.List[string]]::new()
    $recoveryPoints = @()
    try {
        $context = Get-LabHyperVRecoveryPointContext -RunId $RunId -InstanceId $InstanceId -StateRoot $StateRoot
        $recoveryPoints = @(Get-LabHyperVRecoveryPointCandidates -Context $context)
    }
    catch {
        $code = if ($_.Exception.Message -cmatch 'HYPERV_RECOVERY_POINT_[A-Z_]+') { [string]$Matches[0] } else { 'HYPERV_RECOVERY_POINT_CONTEXT_UNAVAILABLE' }
        if ($code -notin $allowedBlockers) { $code = 'HYPERV_RECOVERY_POINT_CONTEXT_UNAVAILABLE' }
        $blockers.Add($code)
    }

    $status = if ($blockers.Count -gt 0) { 'BLOCKED' } elseif ($recoveryPoints.Count -gt 0) { 'READY' } else { 'NO_ACTION' }
    $fingerprint = "$RunId|$InstanceId|$(@($recoveryPoints.RecoveryPointId) -join '|')"
    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($fingerprint))).ToLowerInvariant()
    $plan = [PSCustomObject][ordered]@{
        ContractVersion = 'SqlServerLab.HyperVRecoveryPointPlan/1.0'
        PlanId = "hyperv-recovery-point-$hash"
        RunId = $RunId
        InstanceId = $InstanceId
        Provider = 'hyperv'
        Status = $status
        Action = if ($status -eq 'READY') { 'REVIEW_RECOVERY_POINTS' } elseif ($status -eq 'NO_ACTION') { 'NO_RECOVERY_POINTS' } else { 'MANUAL_REVIEW_REQUIRED' }
        ExecutionImplemented = $false
        RecoveryPoints = @($recoveryPoints)
        Blockers = @($blockers | Sort-Object -Unique)
        PlannedAt = Get-LabTimestamp
    }
    try { $valid = $plan | ConvertTo-Json -Depth 20 | Test-Json -SchemaFile (Join-Path $script:SchemasPath 'hyperv-recovery-point-plan.schema.json') -ErrorAction Stop }
    catch { throw "HYPERV_RECOVERY_POINT_PLAN_INVALID: $($_.Exception.Message)" }
    if (-not $valid) { throw 'HYPERV_RECOVERY_POINT_PLAN_INVALID' }
    return $plan
}