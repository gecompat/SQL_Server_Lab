<#
.SYNOPSIS
    Projiziert Cleanup-Audit-Befunde in getrennte, nicht mutierende Kategorien.
.DESCRIPTION
    Trennt bewusst bewahrte Ressourcen, unerwartete Residuen, notwendige
    Recovery-Arbeit und unverifizierbare Evidence. Die Projektion enthält nur
    stabile Identitäten und sanitisierte Handlungshinweise; sie erteilt keine
    Lösch- oder Reparaturautorität.
#>

function New-LabCleanupAuditFinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('RETAINED','UNEXPECTED_RESIDUAL','RECOVERY_REQUIRED','UNVERIFIABLE')][string]$Category,
        [Parameter(Mandatory)][ValidateSet('STORAGE_OBJECT','PERSISTENT_STORAGE','CONTAINER','HYPERV_RUN')][string]$SubjectKind,
        [Parameter(Mandatory)][ValidatePattern('^[A-Z][A-Z0-9_]{2,127}$')][string]$ObjectType,
        [Parameter(Mandatory)][string]$SubjectId,
        [Parameter(Mandatory)][ValidateSet('core','docker','podman','hyperv','external')][string]$Provider,
        [Parameter(Mandatory)][string]$DisplayName,
        [Parameter(Mandatory)][ValidatePattern('^[A-Z][A-Z0-9_]{2,127}$')][string]$ReasonCode,
        [Parameter(Mandatory)][string]$Guidance
    )

    [PSCustomObject]@{
        Category = $Category
        SubjectKind = $SubjectKind
        ObjectType = $ObjectType
        SubjectId = $SubjectId
        Provider = $Provider
        DisplayName = $DisplayName
        ReasonCode = $ReasonCode
        Guidance = $Guidance
        Recommendation = switch ($Category) {
            'UNEXPECTED_RESIDUAL' { 'REVIEW_FOR_SCOPED_REMOVAL' }
            'RETAINED' { 'PRESERVE_DO_NOT_DELETE' }
            'RECOVERY_REQUIRED' { 'RECOVER_BEFORE_REMOVAL' }
            default { 'DO_NOT_DELETE_UNTIL_VERIFIED' }
        }
        AutomaticMutationAllowed = $false
    }
}

function Get-LabCleanupAuditFindings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$ResidencyInventory,
        [AllowNull()]$PersistentStorageCatalog,
        [AllowEmptyCollection()][object[]]$HyperVRunScopes = @(),
        [AllowEmptyCollection()][object[]]$Containers = @()
    )

    $retained = [Collections.Generic.List[object]]::new()
    $unexpected = [Collections.Generic.List[object]]::new()
    $recovery = [Collections.Generic.List[object]]::new()
    $unverifiable = [Collections.Generic.List[object]]::new()

    foreach ($object in @($ResidencyInventory.Objects)) {
        $provider = ([string]$object.Provider).ToLowerInvariant()
        if ($provider -notin @('core','docker','podman','hyperv','external')) { $provider = 'external' }
        $subjectId = [string]$object.ObjectId
        $displayName = [string]$object.LogicalName

        if ([string]$object.CleanupPolicy -in @('PRESERVE_RETAINED','PRESERVE_SHARED')) {
            $reason = if ([string]$object.CleanupPolicy -eq 'PRESERVE_RETAINED') {
                'PRESERVE_RETAINED_POLICY'
            }
            else { 'PRESERVE_SHARED_RESOURCE' }
            $guidance = if ([string]$object.CleanupPolicy -eq 'PRESERVE_RETAINED') {
                'Bewusst behalten; nur über eine getrennte referenz- und leasegeprüfte Storage-Aktion freigeben.'
            }
            else {
                'Geteilte Ressource bewahren; Consumer und Ownership vor jeder getrennten Änderung prüfen.'
            }
            $retained.Add((New-LabCleanupAuditFinding -Category RETAINED -SubjectKind STORAGE_OBJECT -ObjectType ([string]$object.ObjectClass) `
                -SubjectId $subjectId -Provider $provider -DisplayName $displayName -ReasonCode $reason -Guidance $guidance))
        }

        if ([string]$object.AuditStatus -eq 'RESIDUAL') {
            $referenceState = if ($object.Details -and $object.Details.PSObject.Properties['ReferenceState']) {
                [string]$object.Details.ReferenceState
            }
            else { $null }
            $reason = if ($referenceState -eq 'ORPHAN_CANDIDATE') { 'ORPHAN_CANDIDATE' }
                elseif ([string]$object.ObjectClass -eq 'EXTERNAL_REFERENCE') { 'EXTERNAL_REFERENCE_REVIEW' }
                elseif ([string]$object.ObjectClass -eq 'REPOSITORY_RESIDUE') { 'REPOSITORY_RESIDUE_REVIEW' }
                elseif ([string]$object.ObjectClass -eq 'LEGACY_STATE') { 'LEGACY_STATE_REVIEW' }
                elseif ([string]$object.ObjectClass -eq 'HYPERV_RUN_RESOURCE') { 'UNTRACKED_HYPERV_RESOURCE' }
                else { 'UNEXPECTED_STORAGE_RESIDUAL' }
            $guidance = if ([string]$object.ObjectClass -eq 'REPOSITORY_RESIDUE') {
                'Dateien im genannten Repository-Verzeichnis prüfen, reproduzierbare Testreste scopegebunden entfernen und Runtime-State außerhalb des Checkouts halten.'
            }
            elseif ([string]$object.CleanupPolicy -eq 'RUN_CLEANUP') {
                'Zugehörigen Run- und Cleanup-Plan revalidieren und ausschließlich scopegebunden fortsetzen.'
            }
            else {
                'Ownership, Referenzen und physischen Scope prüfen; keine automatische Löschung aus dem Audit.'
            }
            $unexpected.Add((New-LabCleanupAuditFinding -Category UNEXPECTED_RESIDUAL -SubjectKind STORAGE_OBJECT -ObjectType ([string]$object.ObjectClass) `
                -SubjectId $subjectId -Provider $provider -DisplayName $displayName -ReasonCode $reason -Guidance $guidance))
        }

        if ([string]$object.AuditStatus -eq 'UNVERIFIABLE') {
            $unverifiable.Add((New-LabCleanupAuditFinding -Category UNVERIFIABLE -SubjectKind STORAGE_OBJECT -ObjectType ([string]$object.ObjectClass) `
                -SubjectId $subjectId -Provider $provider -DisplayName $displayName `
                -ReasonCode 'STORAGE_EVIDENCE_UNVERIFIABLE' `
                -Guidance 'Providerzugriff, Ownership und physische Evidence herstellen; bis dahin keine Mutation ableiten.'))
        }
    }

    foreach ($container in @($Containers | Where-Object Orphan)) {
        $provider = ([string]$container.Provider).ToLowerInvariant()
        if ($provider -notin @('docker','podman')) { $provider = 'external' }
        $subjectId = if ($container.Id) { [string]$container.Id } else { [string]$container.Name }
        $unexpected.Add((New-LabCleanupAuditFinding -Category UNEXPECTED_RESIDUAL -SubjectKind CONTAINER -ObjectType CONTAINER `
            -SubjectId $subjectId -Provider $provider -DisplayName ([string]$container.Name) `
            -ReasonCode 'ORPHAN_CONTAINER' `
            -Guidance 'Run-Zuordnung und Runtime-Labels prüfen; nur über einen bestätigten scopegebundenen Cleanup entfernen.'))
    }

    $catalogDocument = if ($PersistentStorageCatalog -and $PersistentStorageCatalog.PSObject.Properties['Document']) {
        $PersistentStorageCatalog.Document
    }
    else { $null }
    foreach ($store in @($(if ($catalogDocument) { $catalogDocument.Stores } else { @() })) | Where-Object {
        [string]$_.State -in @('INCOMPLETE','RECOVERY_REQUIRED','DELETE_PENDING')
    }) {
        $state = [string]$store.State
        $reason = "PERSISTENT_STORAGE_$state"
        $objectType = if ($store.StorageClass) { ([string]$store.StorageClass).ToUpperInvariant() } else { 'PERSISTENT_STORAGE' }
        $recovery.Add((New-LabCleanupAuditFinding -Category RECOVERY_REQUIRED -SubjectKind PERSISTENT_STORAGE -ObjectType $objectType `
            -SubjectId ([string]$store.PersistentStorageId) -Provider ([string]$store.Provider) `
            -DisplayName ([string]$store.DisplayName) -ReasonCode $reason `
            -Guidance 'Persistierte Operation und Evidence revalidieren; denselben Recovery-Pfad fortsetzen oder kontrolliert zurückrollen.'))
    }
    $catalogStatus = if ($PersistentStorageCatalog -and $PersistentStorageCatalog.PSObject.Properties['Status']) {
        [string]$PersistentStorageCatalog.Status
    }
    else { 'UNAVAILABLE' }
    if ($catalogStatus -in @('INVALID','DIVERGED','UNAVAILABLE')) {
        $recovery.Add((New-LabCleanupAuditFinding -Category RECOVERY_REQUIRED -SubjectKind PERSISTENT_STORAGE -ObjectType PERSISTENT_STORAGE_CATALOG `
            -SubjectId 'persistent-storage-catalog' -Provider core -DisplayName 'Persistent Storage Catalog' `
            -ReasonCode "PERSISTENT_STORAGE_CATALOG_$catalogStatus" `
            -Guidance 'Katalogspiegel und Controller-Bindung prüfen; vor der Reparatur keine Storage-Mutation ausführen.'))
    }

    foreach ($scope in @($HyperVRunScopes)) {
        $runId = [string]$scope.RunId
        if ([string]$scope.MigrationStatus -in @('RECOVERY_REQUIRED','INVALID')) {
            $reason = if ([string]$scope.MigrationStatus -eq 'RECOVERY_REQUIRED') {
                'HYPERV_MIGRATION_RECOVERY_REQUIRED'
            }
            else { 'HYPERV_MIGRATION_JOURNAL_INVALID' }
            $recovery.Add((New-LabCleanupAuditFinding -Category RECOVERY_REQUIRED -SubjectKind HYPERV_RUN -ObjectType HYPERV_RUN `
                -SubjectId $runId -Provider hyperv -DisplayName $runId -ReasonCode $reason `
                -Guidance 'Hyper-V-Migrationsjournal prüfen und denselben journalisierten Resume-Pfad fortsetzen.'))
        }
        if ([string]$scope.BindingStatus -in @('INVALID','IDENTITY_MISMATCH')) {
            $recovery.Add((New-LabCleanupAuditFinding -Category RECOVERY_REQUIRED -SubjectKind HYPERV_RUN -ObjectType HYPERV_RUN `
                -SubjectId $runId -Provider hyperv -DisplayName $runId `
                -ReasonCode 'HYPERV_BINDING_REVALIDATION_REQUIRED' `
                -Guidance 'Run-State und Ressourcenbinding gemeinsam revalidieren; keine Hostressource vorher verändern.'))
        }
        if (@($scope.CleanupResources | Where-Object ProtectionStatus -eq 'UNSAFE').Count -gt 0) {
            $recovery.Add((New-LabCleanupAuditFinding -Category RECOVERY_REQUIRED -SubjectKind HYPERV_RUN -ObjectType HYPERV_RUN `
                -SubjectId $runId -Provider hyperv -DisplayName $runId `
                -ReasonCode 'HYPERV_CLEANUP_PROTECTION_REQUIRED' `
                -Guidance 'Cleanup-SafetyRoot und Besitznachweis reparieren; bis dahin bleibt der gesamte Cleanup blockiert.'))
        }
    }

    $retainedArray = @($retained | Sort-Object Provider, SubjectKind, SubjectId, ReasonCode)
    $unexpectedArray = @($unexpected | Sort-Object Provider, SubjectKind, SubjectId, ReasonCode)
    $recoveryArray = @($recovery | Sort-Object Provider, SubjectKind, SubjectId, ReasonCode)
    $unverifiableArray = @($unverifiable | Sort-Object Provider, SubjectKind, SubjectId, ReasonCode)
    [PSCustomObject]@{
        ContractVersion = 'SqlServerLab.CleanupFindings/1.1'
        Retained = $retainedArray
        UnexpectedResiduals = $unexpectedArray
        RecoveryRequired = $recoveryArray
        Unverifiable = $unverifiableArray
        Summary = [PSCustomObject]@{
            Retained = $retainedArray.Count
            UnexpectedResiduals = $unexpectedArray.Count
            RecoveryRequired = $recoveryArray.Count
            Unverifiable = $unverifiableArray.Count
        }
    }
}
