#Requires -Version 7.2
<#
.SYNOPSIS
    Prueft Auswahl-, Continue-, Clone- und Recovery-Vertrag fuer Container-Instanzstores.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$modulePath = Join-Path $repoRoot 'SqlServerLab.psd1'
$newLabText = Get-Content -LiteralPath (Join-Path $repoRoot 'Public/New-SqlServerLab.ps1') -Raw -Encoding utf8
$dockerText = Get-Content -LiteralPath (Join-Path $repoRoot 'Providers/Docker/DockerProvider.ps1') -Raw -Encoding utf8
$podmanText = Get-Content -LiteralPath (Join-Path $repoRoot 'Providers/Podman/PodmanProvider.ps1') -Raw -Encoding utf8
$failures = [Collections.Generic.List[string]]::new()
$passed = 0
. (Join-Path $PSScriptRoot '..' 'Common' 'CheckResult.ps1')

Write-Host ''
Write-Host 'SQL_Server_Lab - Container Instance Store Checks' -ForegroundColor Cyan
Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
Import-Module $modulePath -Force -ErrorAction Stop
$module = Get-Module SqlServerLab
$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) "sql-lab-instance-store-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $temporaryRoot -Force | Out-Null
try {
    $evidence = & $module {
        param($Root)
        $sourceId=[guid]::NewGuid().ToString('D'); $targetId=[guid]::NewGuid().ToString('D')
        $runId=[guid]::NewGuid().ToString('D'); $scopeId=[guid]::NewGuid().ToString('D'); $operationId=[guid]::NewGuid().ToString('D')
        $controllerId=[guid]::NewGuid().ToString('D')
        $catalogRoot1=Join-Path $Root 'one/Lab_Data'; $catalogRoot2=Join-Path $Root 'two/Lab_Data'
        $null=Initialize-LabManagedDataRoot -DataRoot $catalogRoot1 -ControllerId $controllerId -Confirm:$false
        $null=Initialize-LabManagedDataRoot -DataRoot $catalogRoot2 -ControllerId $controllerId -Confirm:$false
        $configuration=[PSCustomObject]@{
            ControllerId=$controllerId
            LabDataLocations=@(
                [PSCustomObject]@{ LocationId=[guid]::NewGuid().ToString('D'); LabDataRoot=$catalogRoot1 },
                [PSCustomObject]@{ LocationId=[guid]::NewGuid().ToString('D'); LabDataRoot=$catalogRoot2 }
            )
        }
        $volumeName='sql-lab-persistent-selected-source'
        $store=[PSCustomObject]@{
            PersistentStorageId=$sourceId; DisplayName='Selected SQL 2025'; StorageClass='INSTANCE_STORE'; State='DETACHED'; Provider='docker'
            LocationBinding=[PSCustomObject]@{ Residency='NATIVE_RUNTIME'; LocationId=$null; ProviderResourceId=$volumeName; InventoryObjectId='storage-object-111111111111111111111111'; RelativePath=$null }
            References=@(); Lease=$null; Retention='RETAINED'; CleanupDisposition='PRESERVE'; CreatedAt='2026-09-01T00:00:00Z'; UpdatedAt='2026-09-01T00:00:00Z'
        }
        $document=[PSCustomObject]@{ ContractVersion='SqlServerLab.PersistentStorageCatalog/1.0'; ControllerId=$controllerId; Revision=1; Stores=@($store) }
        $null=Write-LabPersistentStorageCatalogDocument -Document $document -Configuration $configuration
        $catalog=Get-LabPersistentStorageCatalog -Configuration $configuration
        $inspection=[PSCustomObject]@{
            Status='AVAILABLE'; Provider='docker'; VolumeName=$volumeName; VolumeId=$volumeName; AttachedContainers=@()
            Labels=[PSCustomObject]@{ 'sql-server-lab.persistent-storage-id'=$sourceId; 'sql-server-lab.sql-major-version'='2025' }
        }
        $continueIntent=[PSCustomObject]@{
            ContractVersion='SqlServerLab.ContainerInstanceStoreIntent/1.0'; OperationId=[guid]::NewGuid().ToString('D'); Action='CONTINUE'
            SourcePersistentStorageId=$sourceId; TargetPersistentStorageId=$null; TargetVolumeName=$null; Provider='docker'
            TargetRunId=$runId; TargetScopeId=$scopeId; TargetSqlMajorVersion='2025'; HelperImage=$null; IncludeExternalRuntimeSidecars=$false
        }
        $cloneIntent=[PSCustomObject]@{
            ContractVersion='SqlServerLab.ContainerInstanceStoreIntent/1.0'; OperationId=$operationId; Action='CLONE'
            SourcePersistentStorageId=$sourceId; TargetPersistentStorageId=$targetId; TargetVolumeName='sql-lab-persistent-clone-target'; Provider='docker'
            TargetRunId=$runId; TargetScopeId=$scopeId; TargetSqlMajorVersion='2025'; HelperImage='mcr.microsoft.com/mssql/server:2025-latest'; IncludeExternalRuntimeSidecars=$false
        }
        $continuePlan=Get-LabContainerInstanceStorePlan -Intent $continueIntent -Catalog $catalog -RuntimeInspection $inspection
        $clonePlan=Get-LabContainerInstanceStorePlan -Intent $cloneIntent -Catalog $catalog -RuntimeInspection $inspection
        $drive=Get-LabContainerInstanceStoreDriveBinding -Plan $continuePlan
        $storage=[PSCustomObject]@{ BackupRoot=(Join-Path $Root 'backups') }
        $continueInstance=[PSCustomObject]@{ drives=@() }
        $cloneInstance=[PSCustomObject]@{ drives=@() }
        $null=Add-LabSelectedPersistentContainerDrive -Instance $continueInstance -Plan $continuePlan -Storage $storage
        $null=Add-LabSelectedPersistentContainerDrive -Instance $cloneInstance -Plan $clonePlan -Storage $storage

        $sidecarInspections=@(
            [PSCustomObject]@{
                Status='AVAILABLE'; Provider='docker'; VolumeName="${volumeName}-external-languages"; VolumeId="${volumeName}-external-languages"; AttachedContainers=@()
                Labels=[PSCustomObject]@{ 'sql-server-lab.persistent-storage-id'=$sourceId; 'sql-server-lab.sql-major-version'='2025'; 'sql-server-lab.storage-role'='EXTERNAL_LANGUAGES' }
            },
            [PSCustomObject]@{
                Status='AVAILABLE'; Provider='docker'; VolumeName="${volumeName}-external-libraries"; VolumeId="${volumeName}-external-libraries"; AttachedContainers=@()
                Labels=[PSCustomObject]@{ 'sql-server-lab.persistent-storage-id'=$sourceId; 'sql-server-lab.sql-major-version'='2025'; 'sql-server-lab.storage-role'='EXTERNAL_LIBRARIES' }
            }
        )
        $sidecarContinueIntent=$continueIntent | ConvertTo-Json -Depth 20 | ConvertFrom-Json -Depth 20
        $sidecarContinueIntent.IncludeExternalRuntimeSidecars=$true
        $sidecarCloneIntent=$cloneIntent | ConvertTo-Json -Depth 20 | ConvertFrom-Json -Depth 20
        $sidecarCloneIntent.IncludeExternalRuntimeSidecars=$true
        $sidecarContinuePlan=Get-LabContainerInstanceStorePlan -Intent $sidecarContinueIntent -Catalog $catalog `
            -RuntimeInspection $inspection -SidecarRuntimeInspection $sidecarInspections
        $sidecarClonePlan=Get-LabContainerInstanceStorePlan -Intent $sidecarCloneIntent -Catalog $catalog `
            -RuntimeInspection $inspection -SidecarRuntimeInspection $sidecarInspections
        $legacySidecarPlan=Get-LabContainerInstanceStorePlan -Intent $sidecarContinueIntent -Catalog $catalog `
            -RuntimeInspection $inspection -SidecarRuntimeInspection @($sidecarInspections[0])
        $sidecarContinueInstance=[PSCustomObject]@{ drives=@() }
        $sidecarCloneInstance=[PSCustomObject]@{ drives=@() }
        $null=Add-LabSelectedPersistentContainerDrive -Instance $sidecarContinueInstance -Plan $sidecarContinuePlan `
            -Storage $storage -IncludeExternalRuntimeState
        $null=Add-LabSelectedPersistentContainerDrive -Instance $sidecarCloneInstance -Plan $sidecarClonePlan `
            -Storage $storage -IncludeExternalRuntimeState

        $attachedInspection=$inspection | ConvertTo-Json -Depth 20 | ConvertFrom-Json -Depth 20
        $attachedInspection.AttachedContainers=@('foreign-container')
        $attachedPlan=Get-LabContainerInstanceStorePlan -Intent $cloneIntent -Catalog $catalog -RuntimeInspection $attachedInspection
        $versionInspection=$inspection | ConvertTo-Json -Depth 20 | ConvertFrom-Json -Depth 20
        $versionInspection.Labels.'sql-server-lab.sql-major-version'='2022'
        $versionPlan=Get-LabContainerInstanceStorePlan -Intent $cloneIntent -Catalog $catalog -RuntimeInspection $versionInspection
        $leasedCatalog=$catalog | ConvertTo-Json -Depth 30 | ConvertFrom-Json -Depth 30
        $leasedCatalog.Document.Stores[0].State='IN_USE'
        $leasedCatalog.Document.Stores[0].Lease=[PSCustomObject]@{ LeaseId=[guid]::NewGuid().ToString('D'); RunId=[guid]::NewGuid().ToString('D'); ScopeId=[guid]::NewGuid().ToString('D'); Mode='EXCLUSIVE'; AcquiredAt='2026-09-01T00:00:00Z'; ExpiresAt=$null }
        $leasedPlan=Get-LabContainerInstanceStorePlan -Intent $cloneIntent -Catalog $leasedCatalog -RuntimeInspection $inspection

        $originalInspection=(Get-Command Get-LabContainerInstanceStoreRuntimeInspection).ScriptBlock
        $originalEvidence=(Get-Command Get-LabContainerVolumeContentEvidence).ScriptBlock
        $originalCommand=(Get-Command Invoke-LabContainerInstanceStoreRuntimeCommand).ScriptBlock
        $originalRegistration=(Get-Command Register-LabContainerInstanceStoreClone).ScriptBlock
        try {
            $script:instanceStoreSourceId=$sourceId; $script:instanceStoreTargetId=$targetId; $script:instanceStoreOperationId=$operationId
            $script:instanceStoreTargetCreated=$false; $script:instanceStoreFailCopy=$true; $script:instanceStoreFailCatalog=$false
            $script:instanceStoreOriginalRegistration=$originalRegistration
            $script:instanceStoreCommands=[Collections.Generic.List[string]]::new()
            Set-Item Function:Get-LabContainerInstanceStoreRuntimeInspection -Value {
                param($Provider,$VolumeName)
                if ($VolumeName -eq 'sql-lab-persistent-selected-source') {
                    return [PSCustomObject]@{ Status='AVAILABLE'; Provider='docker'; VolumeName=$VolumeName; VolumeId=$VolumeName; AttachedContainers=@(); Labels=[PSCustomObject]@{ 'sql-server-lab.persistent-storage-id'=$script:instanceStoreSourceId; 'sql-server-lab.sql-major-version'='2025' } }
                }
                if (-not $script:instanceStoreTargetCreated) { return [PSCustomObject]@{ Status='MISSING'; Provider='docker'; VolumeName=$VolumeName; VolumeId=$null; AttachedContainers=@(); Labels=[PSCustomObject]@{} } }
                return [PSCustomObject]@{ Status='AVAILABLE'; Provider='docker'; VolumeName=$VolumeName; VolumeId=$VolumeName; AttachedContainers=@(); Labels=[PSCustomObject]@{ 'sql-server-lab.persistent-storage-id'=$script:instanceStoreTargetId; 'sql-server-lab.operation-id'=$script:instanceStoreOperationId; 'sql-server-lab.sql-major-version'='2025' } }
            }
            Set-Item Function:Get-LabContainerVolumeContentEvidence -Value { param($Provider,$VolumeName,$HelperImage) [PSCustomObject]@{ FileCount=7; TotalBytes=4096; Sha256=('a' * 64) } }
            Set-Item Function:Invoke-LabContainerInstanceStoreRuntimeCommand -Value {
                param($Provider,$Arguments,$ErrorCode)
                $script:instanceStoreCommands.Add(($Arguments -join ' '))
                if ($Arguments[0] -eq 'volume' -and $Arguments[1] -eq 'create') { $script:instanceStoreTargetCreated=$true; return @('created') }
                if ($script:instanceStoreFailCopy -and $Arguments[0] -eq 'run') { throw 'CONTAINER_INSTANCE_STORE_COPY_FAILED' }
                return @('ok')
            }
            Set-Item Function:Register-LabContainerInstanceStoreClone -Value {
                param($Plan,$Journal,$Configuration)
                if ($script:instanceStoreFailCatalog) { throw 'SYNTHETIC_INSTANCE_STORE_CATALOG_FAILURE' }
                & $script:instanceStoreOriginalRegistration -Plan $Plan -Journal $Journal -Configuration $Configuration
            }
            $selectionContinuePlan=New-LabContainerInstanceStoreSelectionPlan -SourcePersistentStorageId $sourceId `
                -Action CONTINUE -Provider docker -TargetRunId $runId -TargetScopeId $scopeId `
                -TargetSqlVersion 2025 -Configuration $configuration
            $selectionClonePlan=New-LabContainerInstanceStoreSelectionPlan -SourcePersistentStorageId $sourceId `
                -Action CLONE -Provider docker -TargetRunId $runId -TargetScopeId $scopeId `
                -TargetSqlVersion 2025 -Configuration $configuration
            $firstFailure=$null
            try { $null=Invoke-LabContainerInstanceStoreClone -Plan $clonePlan -OperationDirectory $Root -Configuration $configuration }
            catch { $firstFailure=$_.Exception.Message }
            $failedJournal=Get-Content -LiteralPath (Get-LabContainerInstanceStoreJournalPath -OperationDirectory $Root) -Raw -Encoding utf8 | ConvertFrom-Json -Depth 40
            $legacyJournal=$failedJournal | ConvertTo-Json -Depth 40 | ConvertFrom-Json -Depth 40
            $legacyJournal.PSObject.Properties.Remove('Sidecars')
            $null=Write-LabArtifactJsonAtomic -Path (Get-LabContainerInstanceStoreJournalPath -OperationDirectory $Root) -InputObject $legacyJournal
            $catalogAfterCopyFailure=Get-LabPersistentStorageCatalog -Configuration $configuration
            $resumePlan=Get-LabContainerInstanceStorePlan -Intent $cloneIntent -Catalog $catalogAfterCopyFailure -RuntimeInspection $inspection
            $competingIntent=$cloneIntent | ConvertTo-Json -Depth 20 | ConvertFrom-Json -Depth 20
            $competingIntent.OperationId=[guid]::NewGuid().ToString('D')
            $competingIntent.TargetPersistentStorageId=[guid]::NewGuid().ToString('D')
            $competingIntent.TargetVolumeName='sql-lab-persistent-competing-target'
            $competingPlan=Get-LabContainerInstanceStorePlan -Intent $competingIntent -Catalog $catalogAfterCopyFailure -RuntimeInspection $inspection
            $script:instanceStoreFailCopy=$false
            $script:instanceStoreFailCatalog=$true
            $catalogFailure=$null
            try { $null=Invoke-LabContainerInstanceStoreClone -Plan $clonePlan -OperationDirectory $Root -Configuration $configuration }
            catch { $catalogFailure=$_.Exception.Message }
            $failedCatalogJournal=Get-Content -LiteralPath (Get-LabContainerInstanceStoreJournalPath -OperationDirectory $Root) -Raw -Encoding utf8 | ConvertFrom-Json -Depth 40
            $catalogAfterCatalogFailure=Get-LabPersistentStorageCatalog -Configuration $configuration
            $script:instanceStoreFailCatalog=$false
            $completedJournal=Invoke-LabContainerInstanceStoreClone -Plan $clonePlan -OperationDirectory $Root -Configuration $configuration
            $completedAgain=Invoke-LabContainerInstanceStoreClone -Plan $clonePlan -OperationDirectory $Root -Configuration $configuration
            $catalogAfter=Get-LabPersistentStorageCatalog -Configuration $configuration
            $commands=@($script:instanceStoreCommands)
        }
        finally {
            Set-Item Function:Get-LabContainerInstanceStoreRuntimeInspection -Value $originalInspection
            Set-Item Function:Get-LabContainerVolumeContentEvidence -Value $originalEvidence
            Set-Item Function:Invoke-LabContainerInstanceStoreRuntimeCommand -Value $originalCommand
            Set-Item Function:Register-LabContainerInstanceStoreClone -Value $originalRegistration
            Remove-Variable instanceStoreSourceId,instanceStoreTargetId,instanceStoreOperationId,instanceStoreTargetCreated,instanceStoreFailCopy,instanceStoreFailCatalog,instanceStoreOriginalRegistration,instanceStoreCommands -Scope Script -ErrorAction SilentlyContinue
        }
        [PSCustomObject]@{
            ContinuePlan=$continuePlan; ClonePlan=$clonePlan; Drive=$drive; ContinueInstance=$continueInstance; CloneInstance=$cloneInstance
            SidecarContinuePlan=$sidecarContinuePlan; SidecarClonePlan=$sidecarClonePlan; LegacySidecarPlan=$legacySidecarPlan
            SidecarContinueInstance=$sidecarContinueInstance; SidecarCloneInstance=$sidecarCloneInstance
            AttachedPlan=$attachedPlan; VersionPlan=$versionPlan; LeasedPlan=$leasedPlan
            FirstFailure=$firstFailure; FailedJournal=$failedJournal; CatalogFailure=$catalogFailure; FailedCatalogJournal=$failedCatalogJournal
            CatalogAfterCopyFailure=$catalogAfterCopyFailure; CatalogAfterCatalogFailure=$catalogAfterCatalogFailure
            ResumePlan=$resumePlan; CompetingPlan=$competingPlan
            SelectionContinuePlan=$selectionContinuePlan; SelectionClonePlan=$selectionClonePlan
            CompletedJournal=$completedJournal; CompletedAgain=$completedAgain; CatalogAfter=$catalogAfter; Commands=$commands
            IntentValid=(Test-LabContainerInstanceStoreIntent -Intent $cloneIntent)
        }
    } $temporaryRoot

    Add-CheckResult -Name 'Stable Storage-ID waehlt den katalogisierten Runtime-Store eindeutig' -Success (
        $evidence.ContinuePlan.Status -eq 'READY' -and $evidence.ContinuePlan.Source.PersistentStorageId -eq $evidence.Drive.persistentStorageId -and
        $evidence.Drive.volumeName -eq 'sql-lab-persistent-selected-source')
    Add-CheckResult -Name 'Continue bindet dasselbe Volume und plant SQL-Readiness plus Datenpruefung' -Success (
        @($evidence.ContinuePlan.Steps | Where-Object Action -eq 'BIND_EXISTING_VOLUME').Count -eq 1 -and
        @($evidence.ContinuePlan.Steps | Where-Object Action -eq 'VERIFY_SQL_READINESS_AND_DATA').Count -eq 1)
    Add-CheckResult -Name 'Continue und Clone liefern nur die jeweils katalogisierte Zielbindung an die Provisionierung' -Success (
        @($evidence.ContinueInstance.drives | Where-Object {
            $_.id -eq 'persistent-mssql' -and $_.persistentStorageId -eq $evidence.ContinuePlan.Source.PersistentStorageId -and
            $_.persistence -eq 'cataloged-runtime-volume'
        }).Count -eq 1 -and
        @($evidence.CloneInstance.drives | Where-Object {
            $_.id -eq 'persistent-mssql' -and $_.persistentStorageId -eq $evidence.ClonePlan.Target.PersistentStorageId -and
            $_.persistence -eq 'cataloged-runtime-volume'
        }).Count -eq 1)
    Add-CheckResult -Name 'External-Runtime-Mehr-Volume-Plan bindet Continue und Clone rollenfest' -Success (
        $evidence.SidecarContinuePlan.Status -eq 'READY' -and $evidence.SidecarClonePlan.Status -eq 'READY' -and
        @($evidence.SidecarContinuePlan.Source.Sidecars).Count -eq 2 -and @($evidence.SidecarClonePlan.Target.Sidecars).Count -eq 2 -and
        @($evidence.SidecarContinueInstance.drives | Where-Object {
            $_.persistentStorageRole -in @('EXTERNAL_LANGUAGES','EXTERNAL_LIBRARIES') -and
            $_.persistentStorageId -eq $evidence.SidecarContinuePlan.Source.PersistentStorageId -and
            $_.persistence -eq 'cataloged-runtime-volume'
        }).Count -eq 2 -and
        @($evidence.SidecarCloneInstance.drives | Where-Object {
            $_.persistentStorageRole -in @('EXTERNAL_LANGUAGES','EXTERNAL_LIBRARIES') -and
            $_.persistentStorageId -eq $evidence.SidecarClonePlan.Target.PersistentStorageId -and
            $_.persistence -eq 'cataloged-runtime-volume'
        }).Count -eq 2)
    Add-CheckResult -Name 'Unvollstaendige oder ungelabelte Sidecar-Gruppe bleibt fail-closed' -Success (
        $evidence.LegacySidecarPlan.Status -eq 'BLOCKED' -and
        'SOURCE_SIDECAR_EXTERNAL_LIBRARIES_NOT_OBSERVED' -in @($evidence.LegacySidecarPlan.Blockers))
    Add-CheckResult -Name 'Oeffentlicher Erstellungsflow leitet Runtimebindung und Clone-Ziel aus stabilen IDs ab' -Success (
        $evidence.SelectionContinuePlan.Status -eq 'READY' -and
        $evidence.SelectionContinuePlan.Source.PersistentStorageId -eq $evidence.ClonePlan.Source.PersistentStorageId -and
        $evidence.SelectionClonePlan.Status -eq 'READY' -and
        $evidence.SelectionClonePlan.Target.PersistentStorageId -match '^[0-9a-f-]{36}$' -and
        $evidence.SelectionClonePlan.Target.VolumeName -eq "sql-lab-persistent-clone-$($evidence.SelectionClonePlan.Target.PersistentStorageId.Replace('-',''))")
    Add-CheckResult -Name 'Clone-Plan mutiert und loescht die Quelle nie' -Success (
        $evidence.ClonePlan.Status -eq 'READY' -and -not $evidence.ClonePlan.Preview.SourceMutation -and -not $evidence.ClonePlan.Preview.SourceDeletion -and
        @($evidence.ClonePlan.Steps | Where-Object Action -eq 'COPY_SOURCE_READ_ONLY').Count -eq 1)
    Add-CheckResult -Name 'Angehängte Quelle blockiert vor jeder Clone-Mutation' -Success (
        $evidence.AttachedPlan.Status -eq 'BLOCKED' -and 'SOURCE_VOLUME_ATTACHED' -in @($evidence.AttachedPlan.Blockers))
    Add-CheckResult -Name 'Abweichende SQL-Major-Version blockiert fail-closed' -Success (
        $evidence.VersionPlan.Status -eq 'BLOCKED' -and 'SOURCE_SQL_VERSION_INCOMPATIBLE' -in @($evidence.VersionPlan.Blockers))
    Add-CheckResult -Name 'Aktive Lease und IN_USE-Zustand blockieren Clone' -Success (
        $evidence.LeasedPlan.Status -eq 'BLOCKED' -and 'SOURCE_LEASE_ACTIVE' -in @($evidence.LeasedPlan.Blockers) -and 'SOURCE_STATE_NOT_DETACHED' -in @($evidence.LeasedPlan.Blockers))
    Add-CheckResult -Name 'Clone-Fehler bleibt als sichtbarer RECOVERY_REQUIRED-Zustand erhalten' -Success (
        $evidence.FirstFailure -match '^CONTAINER_INSTANCE_STORE_RECOVERY_REQUIRED' -and $evidence.FailedJournal.Status -eq 'RECOVERY_REQUIRED' -and
        $evidence.FailedJournal.Recovery.Status -eq 'RETRY_CLONE')
    $leasedSource=@($evidence.CatalogAfterCopyFailure.Document.Stores | Where-Object PersistentStorageId -eq $evidence.ClonePlan.Source.PersistentStorageId)
    Add-CheckResult -Name 'Clone reserviert die Quelle vor der ersten Kopie operationsgebunden' -Success (
        $leasedSource.Count -eq 1 -and $leasedSource[0].State -eq 'IN_USE' -and
        $leasedSource[0].Lease.LeaseId -eq $evidence.ClonePlan.OperationId -and
        @($leasedSource[0].References | Where-Object { $_.ReferenceId -eq $evidence.ClonePlan.OperationId -and $_.State -eq 'ACTIVE' }).Count -eq 1)
    Add-CheckResult -Name 'Nur dieselbe Recovery-Operation darf die aktive Clone-Lease fortsetzen' -Success (
        $evidence.ResumePlan.Status -eq 'READY' -and $evidence.CompetingPlan.Status -eq 'BLOCKED' -and
        'SOURCE_LEASE_ACTIVE' -in @($evidence.CompetingPlan.Blockers))
    Add-CheckResult -Name 'Wiederaufnahme revalidiert und beendet denselben journalisierten Clone' -Success (
        $evidence.CompletedJournal.Status -eq 'COMPLETED' -and $evidence.CompletedJournal.Recovery.Attempts -eq 3 -and
        $evidence.CompletedJournal.Source.Evidence.Sha256 -eq $evidence.CompletedJournal.Target.Evidence.Sha256 -and
        @($evidence.CompletedJournal.Sidecars).Count -eq 0)
    $targetStores=@($evidence.CatalogAfter.Document.Stores | Where-Object PersistentStorageId -eq $evidence.ClonePlan.Target.PersistentStorageId)
    Add-CheckResult -Name 'Katalogfehler verhindert COMPLETED und bleibt als wiederaufnehmbarer Recovery-Zustand sichtbar' -Success (
        $evidence.CatalogFailure -match '^CONTAINER_INSTANCE_STORE_RECOVERY_REQUIRED: SYNTHETIC_INSTANCE_STORE_CATALOG_FAILURE' -and
        $evidence.FailedCatalogJournal.Status -eq 'RECOVERY_REQUIRED' -and $evidence.FailedCatalogJournal.Recovery.Status -eq 'RETRY_CLONE' -and
        @($evidence.CatalogAfterCatalogFailure.Document.Stores | Where-Object {
            $_.PersistentStorageId -eq $evidence.ClonePlan.Source.PersistentStorageId -and $_.Lease.LeaseId -eq $evidence.ClonePlan.OperationId
        }).Count -eq 1)
    Add-CheckResult -Name 'Verifiziertes Clone-Ziel wird atomar und idempotent auf alle Katalogspiegel committed' -Success (
        $evidence.CatalogAfter.Status -eq 'AVAILABLE' -and @($evidence.CatalogAfter.Sources).Count -eq 2 -and
        $evidence.CatalogAfter.Document.Revision -eq 3 -and $targetStores.Count -eq 1 -and
        $targetStores[0].State -eq 'DETACHED' -and -not $targetStores[0].Lease -and
        $targetStores[0].LocationBinding.ProviderResourceId -eq $evidence.ClonePlan.Target.VolumeName -and
        $targetStores[0].LocationBinding.InventoryObjectId -match '^storage-object-[a-f0-9]{24}$' -and
        @($targetStores[0].References | Where-Object { $_.State -eq 'RELEASED' -and $_.TargetId -eq $evidence.ClonePlan.Target.RunId }).Count -eq 1 -and
        $evidence.CompletedAgain.Status -eq 'COMPLETED')
    $releasedSource=@($evidence.CatalogAfter.Document.Stores | Where-Object PersistentStorageId -eq $evidence.ClonePlan.Source.PersistentStorageId)
    Add-CheckResult -Name 'Zielcommit und Quellfreigabe erfolgen in derselben Katalogrevision' -Success (
        $releasedSource.Count -eq 1 -and $releasedSource[0].State -eq 'DETACHED' -and -not $releasedSource[0].Lease -and
        @($releasedSource[0].References | Where-Object {
            $_.ReferenceId -eq $evidence.ClonePlan.OperationId -and $_.State -eq 'RELEASED'
        }).Count -eq 1)
    Add-CheckResult -Name 'Runtime-Befehle mounten die Quelle read-only und entfernen kein Volume' -Success (
        (@($evidence.Commands | Where-Object { $_ -match ':/source:ro' }).Count -ge 1) -and
        (@($evidence.Commands | Where-Object { $_ -match '(^| )volume rm( |$)' }).Count -eq 0))
    Add-CheckResult -Name 'Strikter Intent bleibt schema-valide und geheimnisfrei' -Success (
        $evidence.IntentValid -and (($evidence.ClonePlan | ConvertTo-Json -Depth 30) -notmatch '(?i)password|secret|credential'))
    Add-CheckResult -Name 'Oeffentliche Lab-Erstellung und Provider binden stabile Sidecar-Rollen' -Success (
        $newLabText -match '\[string\]\$PersistentStorageId' -and
        $newLabText -match '\[string\]\$PersistentStorageAction' -and
        $newLabText -match 'New-LabContainerInstanceStoreSelectionPlan' -and
        $newLabText -match 'Invoke-LabContainerInstanceStoreClone' -and
        $newLabText -match 'Sync-LabContainerInstanceStoreDatabaseReference' -and
        $newLabText -match 'IncludeExternalRuntimeSidecars:\$hasExternalRuntime' -and
        $newLabText -match 'persistentStorageRole' -and
        $newLabText -match "persistence -notin @\('data-root-runtime-volume','cataloged-runtime-volume'\)" -and
        $dockerText -match 'sql-server-lab\.storage-role' -and $podmanText -match 'sql-server-lab\.storage-role')
}
finally {
    Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''; Write-Host "Ergebnis: $passed PASS, $($failures.Count) FAIL" -ForegroundColor Cyan
if ($failures.Count) { exit 1 }; exit 0
