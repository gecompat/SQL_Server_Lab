#Requires -Version 7.2

$script:HyperVExternalRuntimeAcceptanceStages = @(
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

function Test-HyperVExternalRuntimeAcceptanceStage {
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()][object]$Stage)

    return $Stage -is [string] -and $Stage -cin $script:HyperVExternalRuntimeAcceptanceStages
}

function New-HyperVExternalRuntimeAcceptanceStageFailure {
    [CmdletBinding()]
    [OutputType([System.Management.Automation.ErrorRecord])]
    param(
        [Parameter(Mandatory)][string]$Stage,
        [Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    if (-not (Test-HyperVExternalRuntimeAcceptanceStage -Stage $Stage)) {
        throw 'HYPERV_EXTERNAL_RUNTIME_ACCEPTANCE_STAGE_INVALID'
    }

    $exception = [System.InvalidOperationException]::new('HYPERV_EXTERNAL_RUNTIME_ACCEPTANCE_STAGE_FAILURE')
    $exception.Data['SqlServerLab.ExternalRuntimeAcceptanceStage'] = $Stage
    # Der Originalfehler bleibt ausschließlich am ErrorRecord für den privaten
    # Wrapperzugriff; die öffentliche CI-Ausgabe erhält nur die feste Stage.
    $exception.Data['SqlServerLab.ExternalRuntimeAcceptanceOriginalErrorRecord'] = $ErrorRecord
    return [System.Management.Automation.ErrorRecord]::new(
        $exception,
        'HYPERV_EXTERNAL_RUNTIME_ACCEPTANCE_STAGE_FAILURE',
        [System.Management.Automation.ErrorCategory]::InvalidOperation,
        $null
    )
}
