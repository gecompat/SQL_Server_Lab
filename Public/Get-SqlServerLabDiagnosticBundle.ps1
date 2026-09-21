<#
.SYNOPSIS
    Liefert begrenzte, sanitisierte Diagnose-Evidence für genau eine eigene Instanz.
.DESCRIPTION
    Prüft einen modernen Run ausschließlich unter einem registrierten,
    controller-markierten LabDataRoot/State. Gibt keine Run-/Instanznamen,
    Runtime-IDs, Pfade, Ports, Secrets, Connection-Dateien oder Rohlogs aus.
    Historische Zustände beweisen weder SQL-Bereitschaft noch Restfreiheit.
    Readiness läuft nach bestätigter Ownership in einem begrenzten Kindprozess.
    Kein Bundle wird gespeichert, exportiert oder hochgeladen.
.PARAMETER RunId
    Kanonische UUID des ausdrücklich angeforderten Runs; wird nicht ausgegeben.
.PARAMETER InstanceId
    Exakte Instanz-ID im persistierten Sollzustand; wird nicht ausgegeben.
.PARAMETER DataRoot
    Bereits registrierter lokaler Lab_Data-Root. Kein freier StateRoot-Fallback.
.PARAMETER Provider
    Optional erwarteter Provider docker, podman oder hyperv. Abweichungen blockieren.
.PARAMETER Operation
    Feste Diagnosekategorie Inspect, Validate, Create, Start, Stop, Remove oder PrepareImage.
.PARAMETER SkipReadiness
    Liefert historische Evidence ohne Providerprobe; Readiness bleibt NOT_EXECUTED.
.OUTPUTS
    SqlServerLab.DiagnosticBundle/1.0 mit geschlossenen Abschnitten und Reason Codes.
.EXAMPLE
    Get-SqlServerLabDiagnosticBundle -RunId $runId -InstanceId primary -DataRoot $dataRoot -Operation Inspect -SkipReadiness
#>
function Get-SqlServerLabDiagnosticBundle {
    [CmdletBinding()]
    param($RunId,$InstanceId,$DataRoot,$Provider,
        $Operation='Inspect',[switch]$SkipReadiness)
    # Validate inside the privacy boundary: parameter binding must not echo inputs.
    $result=[pscustomobject]@{
        ContractVersion='SqlServerLab.DiagnosticBundle/1.0';ResultVersion='1.0';Status='BLOCKED'
        Request=[pscustomobject]@{EvidenceStatus='BLOCKED';Operation='UNKNOWN';Target='SINGLE_RUN_INSTANCE'}
        Binding=[pscustomobject]@{EvidenceStatus='BLOCKED';Reason='DIAGNOSTIC_REQUEST_INVALID';Provider='UNKNOWN';SqlVersion='UNKNOWN';OperatingSystem='UNKNOWN';Persistence='UNKNOWN';ProvisioningMode='UNKNOWN'}
        History=[pscustomobject]@{EvidenceStatus='NOT_EXECUTED';RunState='UNKNOWN';RecoveryStatus='UNKNOWN';ErrorCount=0;RuntimeStatus='NOT_EXECUTED'}
        Cleanup=[pscustomobject]@{EvidenceStatus='NOT_EXECUTED';Reason='DIAGNOSTIC_BINDING_REQUIRED';Status='UNKNOWN';PendingSteps=0;CompletedSteps=0;FailedSteps=0;LiveResidueStatus='NOT_EXECUTED'}
        Operation=[pscustomobject]@{EvidenceStatus='NOT_EXECUTED';Reason='DIAGNOSTIC_BINDING_REQUIRED';Status='UNKNOWN';StepCount=0;CleanupRequested=$false}
        Readiness=[pscustomobject]@{EvidenceStatus='NOT_EXECUTED';Reason='DIAGNOSTIC_BINDING_REQUIRED';Status='UNKNOWN';Checks=@()}
        Capabilities=[pscustomobject]@{EvidenceStatus='OBSERVED';Scope='REGISTERED_MODERN_RUN';MutationAllowed=$false;SqlProbe='NOT_EXECUTED';ClientReadiness='UNSUPPORTED';ProviderReadiness='BOUNDED_READ_ONLY'}
        SpecializedRecovery=[pscustomobject]@{EvidenceStatus='UNSUPPORTED';Reason='DIAGNOSTIC_SPECIALIZED_JOURNALS_EXCLUDED'}
        Reproduction=[pscustomobject]@{EvidenceStatus='NOT_EXECUTED';Reason='DIAGNOSTIC_BINDING_REQUIRED';VersionCatalogSha256=$null}
        Exclusions=@('SECRETS','CONNECTION_INFO','SQL_CONTENT','RAW_LOGS','HOST_LOCATORS','RUNTIME_IDENTIFIERS',
            'RUN_AND_INSTANCE_IDENTIFIERS','DISPLAY_NAMES','SPECIALIZED_JOURNALS','UNBOUND_INVENTORIES','GLOBAL_STORAGE_CONFIGURATION','AUTOMATIC_EXPORT')
    }
    if ($RunId -isnot [string] -or $RunId.Length -ne 36 -or $InstanceId -isnot [string] -or
        $InstanceId.Length -gt 64 -or $DataRoot -isnot [string] -or $DataRoot.Length -gt 4096 -or
        $Operation -isnot [string] -or $Operation -cnotin @('Inspect','Validate','Create','Start','Stop','Remove','PrepareImage') -or
        ($null -ne $Provider -and ($Provider -isnot [string] -or $Provider -cnotin @('docker','podman','hyperv'))) -or -not $DataRoot) { return $result }
    $result.Request.EvidenceStatus='OBSERVED'
    $result.Request.Operation=$Operation
    try {
        $evidence=& { Get-LabDiagnosticTargetEvidence -RunId $RunId -InstanceId $InstanceId -DataRoot $DataRoot -Provider $Provider } `
            2>$null 3>$null 4>$null 5>$null 6>$null
        $result.Binding=$evidence.Binding;$result.History=$evidence.History
        $result.Cleanup=$evidence.Cleanup;$result.Operation=$evidence.Operation
        $result.Readiness=Get-LabDiagnosticReadiness -Provider $evidence.Binding.Provider -Operation $Operation -Skip:$SkipReadiness `
            2>$null 3>$null 4>$null 5>$null 6>$null
        # This repository catalog is public input; no private state or connection hash.
        try {
            $catalogHash=& {
                Get-FileHash -LiteralPath (Join-Path $script:ModuleRoot 'Catalogs/sql-server-versions.json') -Algorithm SHA256 -ErrorAction Stop
            } 2>$null 3>$null 4>$null 5>$null 6>$null
            if ($catalogHash.Hash -isnot [string] -or $catalogHash.Hash -notmatch '^[a-fA-F0-9]{64}$') { throw 'DIAGNOSTIC_CATALOG_UNAVAILABLE' }
            $result.Reproduction=[pscustomobject]@{EvidenceStatus='OBSERVED';Reason='NONE';VersionCatalogSha256=$catalogHash.Hash.ToLowerInvariant()}
        }
        catch {
            $result.Reproduction=[pscustomobject]@{EvidenceStatus='UNAVAILABLE';Reason='DIAGNOSTIC_CATALOG_UNAVAILABLE';VersionCatalogSha256=$null}
        }
        $result.Status='OBSERVED'
    }
    catch {
        $allowed=@('DIAGNOSTIC_ROOT_INVALID','DIAGNOSTIC_LINK_BLOCKED','DIAGNOSTIC_EVIDENCE_MISSING','DIAGNOSTIC_SIZE_LIMIT',
            'DIAGNOSTIC_METADATA_INVALID','DIAGNOSTIC_TARGET_INVALID','DIAGNOSTIC_CONTROLLER_MISMATCH','DIAGNOSTIC_ROOT_MISMATCH',
            'DIAGNOSTIC_COUNT_LIMIT','DIAGNOSTIC_ROOT_UNREGISTERED','DIAGNOSTIC_RUN_CONTRACT_UNSUPPORTED','DIAGNOSTIC_RUN_SCOPE_MISMATCH',
            'DIAGNOSTIC_DESIRED_BINDING_INVALID','DIAGNOSTIC_PERSISTENT_ROOT_MISMATCH','DIAGNOSTIC_INSTANCE_BINDING_INVALID',
            'DIAGNOSTIC_PROVIDER_BINDING_INVALID','DIAGNOSTIC_INSTANCE_UNAVAILABLE','DIAGNOSTIC_PROVIDER_MISMATCH',
            'DIAGNOSTIC_SQL_VERSION_UNSUPPORTED','DIAGNOSTIC_STATE_INVALID')
        $reason=if($_.Exception.Message -cin $allowed){$_.Exception.Message}else{'DIAGNOSTIC_EVIDENCE_UNVERIFIABLE'}
        $result.Binding.Reason=$reason
        if ($reason -cin @('DIAGNOSTIC_EVIDENCE_MISSING','DIAGNOSTIC_INSTANCE_UNAVAILABLE')) { $result.Status='UNAVAILABLE';$result.Binding.EvidenceStatus='UNAVAILABLE' }
    }
    return $result
}
