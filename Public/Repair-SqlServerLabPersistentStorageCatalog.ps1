<#
.SYNOPSIS
    Stellt einen nachweisbar eigenen, abgetrennten Runtime-Store im Katalog wieder her.
.DESCRIPTION
    Die Wiederherstellung übernimmt ausschließlich einen bereits mit der erwarteten
    PersistentStorageId markierten Docker-/Podman-Store. Sie ändert weder Volume,
    Labels noch SQL-Daten und speichert nur eine frische Runtime-Beobachtung.
.PARAMETER OriginalRunId
    Run, dessen persistierter Sollzustand und Connection-Evidence den Store belegen.
.PARAMETER InstanceId
    Instanz-ID aus dem persistierten Sollzustand des ursprünglichen Runs.
.PARAMETER ExpectedPersistentStorageId
    Unveränderliche UUID aus dem Runtime-Volume-Label.
.PARAMETER ExpectedRuntimeScopeId
    Aktuelle providergebundene Runtime-ID (runtime-scope-...), unabhängig von der ursprünglichen Run-Scope-ID.
.PARAMETER DataRoot
    Registrierter Lab_Data-Root des controllergebundenen Katalogs.
.PARAMETER StateRoot
    Optionaler Root der ursprünglichen Run-Evidence.
.OUTPUTS
    PSCustomObject mit Status, PersistentStorageId und Katalogrevision.
#>
function Repair-SqlServerLabPersistentStorageCatalog {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='High')]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F-]{36}$')][string]$OriginalRunId,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$')][string]$InstanceId,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F-]{36}$')][string]$ExpectedPersistentStorageId,
        [Parameter(Mandatory)][ValidatePattern('^runtime-scope-[a-f0-9]{24}$')][string]$ExpectedRuntimeScopeId,
        [Parameter(Mandatory)][string]$DataRoot,
        [string]$StateRoot
    )
    if (-not $StateRoot) { $StateRoot=Get-LabStateRoot }
    $DataRoot=Resolve-LabDataRootForUse -DataRoot $DataRoot
    $configuration=Get-LabStorageConfiguration -DataRoot $DataRoot
    $source=Get-LabContainerStoreRecoverySource -OriginalRunId $OriginalRunId -InstanceId $InstanceId `
        -PersistentStorageId $ExpectedPersistentStorageId -StateRoot $StateRoot -Configuration $configuration
    $arguments=@{Source=$source;StateRoot=$StateRoot;RuntimeScopeId=$ExpectedRuntimeScopeId;Configuration=$configuration}
    $preview=Repair-LabContainerStoreCatalog @arguments -Preview
    $status='NO_CHANGE'; $changed=$false; $wouldChange=[bool]$preview.Changed; $revision=$preview.CatalogRevision
    if ($preview.Changed) {
        if ($PSCmdlet.ShouldProcess("$OriginalRunId/$InstanceId",'eigenen retained Instanzstore im Katalog wiederherstellen')) {
            $result=Repair-LabContainerStoreCatalog @arguments -ExpectedRevision ([int]$preview.CatalogRevision)
            $status=if($result.Changed){'RECOVERED'}else{'NO_CHANGE'}
            $changed=[bool]$result.Changed; $revision=$result.CatalogRevision
        }
        else { $status=if($WhatIfPreference){'PLANNED'}else{'CANCELLED'} }
    }
    [pscustomobject]@{Status=$status;Changed=$changed;WouldChange=$wouldChange;PersistentStorageId=$ExpectedPersistentStorageId;CatalogRevision=[int]$revision}
}