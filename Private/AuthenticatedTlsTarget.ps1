#Requires -Version 7.2
# Private lesende Metadatenbindung; keine Live-Runtime- oder PKI-Autorisierung.

function Get-LabAuthenticatedTlsTargetMetadata {
    [CmdletBinding()]
    param([object]$Request, [object]$InstanceId, [object]$DataRoot)

    $ErrorActionPreference = 'Stop'
    $rejected = [pscustomobject][ordered]@{ Success = $false; Value = $null; ErrorCode = 'TLS_TARGET_REQUEST_INVALID' }
    $checked = Test-LabAuthenticatedTlsRequest -Request $Request
    if (-not $checked.Success -or -not (Test-LabTlsRequestEnum $checked.Value.Kind @('LEAF_PROFILE'))) { return $rejected }
    $leaf = $checked.Value
    if ($InstanceId -isnot [string] -or $InstanceId -cnotmatch '\A[A-Za-z][A-Za-z0-9_-]{0,63}\z' -or
        $DataRoot -isnot [string] -or [string]::IsNullOrWhiteSpace($DataRoot)) {
        $rejected.ErrorCode = 'TLS_TARGET_SELECTOR_INVALID'; return $rejected
    }
    if (-not (Test-LabTlsRequestEnum $leaf.Provider @('docker','podman'))) {
        $rejected.ErrorCode = 'TLS_TARGET_PROVIDER_UNSUPPORTED'; return $rejected
    }
    try {
        # TargetRef ist hier die vorhandene RunId, keine neue Registry oder freie StateRoot.
        # Der Reader bindet Controller, registrierten Root, Scope und Sollinstanzen.
        $binding = Get-LabDiagnosticBinding -RunId $leaf.TargetRef -InstanceId $InstanceId -DataRoot $DataRoot -Provider $leaf.Provider
        $actual = @($binding.Run.instances | Where-Object { [string]::Equals($_.id, $InstanceId, [StringComparison]::Ordinal) })
        if ($actual.Count -ne 1 -or
            -not (Test-LabTlsRequestEnum $binding.Instance.Id @($InstanceId)) -or
            -not (Test-LabTlsRequestEnum $binding.Instance.Provider @($leaf.Provider)) -or
            -not (Test-LabTlsRequestEnum $binding.Instance.Version @($leaf.SqlVersion))) {
            $rejected.ErrorCode = 'TLS_TARGET_METADATA_MISMATCH'; return $rejected
        }
        $instance = $actual[0]
        $subRun = @($binding.Run.providerSubRuns | Where-Object { [string]::Equals($_.provider, $leaf.Provider, [StringComparison]::Ordinal) })
        if (-not (Test-LabTlsRequestEnum $binding.Run.state @('RUNNING')) -or $subRun.Count -ne 1 -or
            -not (Test-LabTlsRequestEnum $subRun[0].state @('RUNNING'))) {
            $rejected.ErrorCode = 'TLS_TARGET_STATE_UNSUPPORTED'; return $rejected
        }
        if (-not (Test-LabTlsRequestEnum $binding.Run.runId @($leaf.TargetRef)) -or
            -not (Test-LabTlsRequestReference $binding.Run.scopeId) -or
            -not (Test-LabTlsRequestEnum $instance.id @($InstanceId)) -or
            -not (Test-LabTlsRequestEnum $instance.provider @($leaf.Provider)) -or
            -not (Test-LabTlsRequestEnum $instance.version @($leaf.SqlVersion)) -or
            $instance.containerId -isnot [string] -or $instance.containerId -cnotmatch '\A[0-9a-f]{64}\z' -or
            ($instance.port -isnot [int] -and $instance.port -isnot [long]) -or $instance.port -ne $leaf.Port -or
            -not (Test-LabTlsRequestEnum $instance.host @($leaf.Identity.Value))) {
            $rejected.ErrorCode = 'TLS_TARGET_METADATA_MISMATCH'; return $rejected
        }
        # Ausschliesslich frische private Projektion, keine Run-/Sollzustandsobjekte weiterreichen.
        $value = [pscustomobject][ordered]@{
            ContractVersion = 'SqlServerLab.AuthenticatedTlsTargetMetadata/0.1'
            Status = 'RECORDED'; TargetRef = $leaf.TargetRef; InstanceId = $InstanceId; ScopeId = $binding.Run.scopeId
            Provider = $leaf.Provider; SqlVersion = $leaf.SqlVersion; ContainerId = $instance.containerId
            Port = $leaf.Port; Identity = [pscustomobject][ordered]@{ Kind = $leaf.Identity.Kind; Value = $leaf.Identity.Value }
            RuntimeStatus = 'NOT_EXECUTED'; AuthorizationStatus = 'NOT_EVALUATED'; MutationAllowed = $false
        }
        return [pscustomobject][ordered]@{ Success = $true; Value = $value; ErrorCode = $null }
    }
    catch {
        # Fehlende Felder, unlesbare/inkonsistente Dateien und Rohfehler bleiben geschlossen.
        $rejected.ErrorCode = 'TLS_TARGET_METADATA_UNAVAILABLE'; return $rejected
    }
}
