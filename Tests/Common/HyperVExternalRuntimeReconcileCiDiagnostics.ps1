$script:HyperVExternalRuntimeCiAcceptanceStages = @(
    'SQL_MEDIA_PREFLIGHT',
    'RUNTIME_MEDIA_PREFLIGHT',
    'LAB_RESOLUTION',
    'WINDOWS_PROVISIONING',
    'SQL_SLOT_INSTALL',
    'SQL_CREDENTIAL',
    'RECONCILE_BASELINE',
    'RECONCILE_MANIFEST',
    'RECONCILE_PLAN',
    'RECONCILE_WHATIF',
    'RECONCILE_APPLY',
    'RECONCILE_POSTCONDITION',
    'DIRECT_RUNTIME_INSTALL',
    'RECEIPT_VALIDATION',
    'COLD_START_RESTART',
    'COLD_START_GUEST_READY',
    'COLD_START_SQL_READY',
    'COLD_START_PROBES',
    'EVIDENCE_WRITE',
    'DIRECT_CLEANUP'
)

$script:HyperVExternalRuntimeCiExactFailureCodes = @(
    'HYPERV_EXTERNAL_RUNTIME_CI_OPERATION_CONTEXT_INVALID',
    'HYPERV_EXTERNAL_RUNTIME_CI_MEDIA_ROOT_INVALID',
    'HYPERV_EXTERNAL_RUNTIME_CI_HOST_LOCK_TIMEOUT',
    'HYPERV_EXTERNAL_RUNTIME_CI_RUNNER_NOT_ELEVATED',
    'HYPERV_EXTERNAL_RUNTIME_CI_OS_SEALED_ARTIFACT_INVALID',
    'HYPERV_EXTERNAL_RUNTIME_CI_MANIFEST_INVALID',
    'HYPERV_EXTERNAL_RUNTIME_CI_CREATED_RUN_OWNERSHIP_INVALID',
    'HYPERV_EXTERNAL_RUNTIME_CI_OWNED_RUN_STATE_INVALID',
    'HYPERV_EXTERNAL_RUNTIME_CI_OWNED_RUN_PROVIDER_INVALID',
    'HYPERV_EXTERNAL_RUNTIME_CI_OWNED_RUN_CLEANUP_PLAN_INVALID',
    'HYPERV_EXTERNAL_RUNTIME_CI_OWNED_RUN_CONNECTION_INVALID',
    'HYPERV_EXTERNAL_RUNTIME_CI_OWNED_VM_OWNERSHIP_INVALID',
    'HYPERV_EXTERNAL_RUNTIME_CI_OWNED_RUN_CLEANUP_FAILED',
    'HYPERV_EXTERNAL_RUNTIME_CI_CLEANUP_VM_POSTCONDITION_FAILED',
    'HYPERV_EXTERNAL_RUNTIME_CI_CLEANUP_VHDX_POSTCONDITION_FAILED',
    'HYPERV_EXTERNAL_RUNTIME_CI_CLEANUP_IPAM_POSTCONDITION_FAILED'
)

function Get-HyperVExternalRuntimeCiFailureCode {
    <#
    .SYNOPSIS
        Classifies a captured acceptance failure without returning raw output.
    .DESCRIPTION
        A stage may originate only from the private ErrorRecord metadata created
        by the native runner. Free text, partial matches and unknown metadata
        never become public diagnostics. The finite exact-code fallback is for
        CI boundary and cleanup failures that do not execute the native runner.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [object[]]$InputObject
    )

    foreach ($item in @($InputObject)) {
        if ($item -isnot [System.Management.Automation.ErrorRecord]) { continue }
        $exception = $item.Exception
        if (-not $exception) { continue }
        $data = $exception.Data
        if ($data -and $data.Contains('SqlServerLab.ExternalRuntimeAcceptanceStage')) {
            $stage = $data['SqlServerLab.ExternalRuntimeAcceptanceStage']
            if ($stage -isnot [string] -or $stage -cnotin $script:HyperVExternalRuntimeCiAcceptanceStages) {
                return 'UNCLASSIFIED'
            }
            return "HYPERV_EXTERNAL_RUNTIME_STAGE_${stage}_FAILED"
        }

        foreach ($candidate in @([string]$item.FullyQualifiedErrorId, [string]$exception.Message)) {
            if ($candidate -cin $script:HyperVExternalRuntimeCiExactFailureCodes) {
                return $candidate
            }
        }
    }
    return 'UNCLASSIFIED'
}

function Test-HyperVExternalRuntimeCiRunnerOutputFailure {
    <#
    .SYNOPSIS
        Detects an error record captured from the private acceptance runner.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()]
        [object[]]$InputObject
    )

    return @($InputObject | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }).Count -gt 0
}

function Get-HyperVExternalRuntimeCiFailureDiagnosticLine {
    <#
    .SYNOPSIS
        Produces the sole public diagnostic line for a classified CI failure.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('PRIMARY', 'CLEANUP')]
        [string]$FailureKind,

        [Parameter(Mandatory)]
        [string]$FailureCode
    )

    $safeCode = if ($FailureCode -in @('UNCLASSIFIED') -or
        $FailureCode -cin $script:HyperVExternalRuntimeCiExactFailureCodes -or
        $FailureCode -cmatch '^HYPERV_EXTERNAL_RUNTIME_STAGE_(?:SQL_MEDIA_PREFLIGHT|RUNTIME_MEDIA_PREFLIGHT|LAB_RESOLUTION|WINDOWS_PROVISIONING|SQL_SLOT_INSTALL|SQL_CREDENTIAL|RECONCILE_BASELINE|RECONCILE_MANIFEST|RECONCILE_PLAN|RECONCILE_WHATIF|RECONCILE_APPLY|RECONCILE_POSTCONDITION|DIRECT_RUNTIME_INSTALL|RECEIPT_VALIDATION|COLD_START_RESTART|COLD_START_GUEST_READY|COLD_START_SQL_READY|COLD_START_PROBES|EVIDENCE_WRITE|DIRECT_CLEANUP)_FAILED$') {
        $FailureCode
    }
    else {
        'UNCLASSIFIED'
    }
    return "HYPERV_EXTERNAL_RUNTIME_CI_${FailureKind}_FAILURE_CODE=$safeCode"
}
