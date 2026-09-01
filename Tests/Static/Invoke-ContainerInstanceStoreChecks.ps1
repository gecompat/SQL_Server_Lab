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
            TargetRunId=$runId; TargetScopeId=$scopeId; TargetSqlMajorVersion='2025'; HelperImage=$null
        }
        $cloneIntent=[PSCustomObject]@{
            ContractVersion='SqlServerLab.ContainerInstanceStoreIntent/1.0'; OperationId=$operationId; Action='CLONE'
            SourcePersistentStorageId=$sourceId; TargetPersistentStorageId=$targetId; TargetVolumeName='sql-lab-persistent-clone-target'; Provider='docker'
            TargetRunId=$runId; TargetScopeId=$scopeId; TargetSqlMajorVersion='2025'; HelperImage='mcr.microsoft.com/mssql/server:2025-latest'
        }
        $continuePlan=Get-LabContainerInstanceStorePlan -Intent $continueIntent -Catalog $catalog -RuntimeInspection $inspection
        $clonePlan=Get-LabContainerInstanceStorePlan -Intent $cloneIntent -Catalog $catalog -RuntimeInspection $inspection
        $drive=Get-LabContainerInstanceStoreDriveBinding -Plan $continuePlan

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
            $firstFailure=$null
            try { $null=Invoke-LabContainerInstanceStoreClone -Plan $clonePlan -OperationDirectory $Root -Configuration $configuration }
            catch { $firstFailure=$_.Exception.Message }
            $failedJournal=Get-Content -LiteralPath (Get-LabContainerInstanceStoreJournalPath -OperationDirectory $Root) -Raw -Encoding utf8 | ConvertFrom-Json -Depth 40
            $script:instanceStoreFailCopy=$false
            $script:instanceStoreFailCatalog=$true
            $catalogFailure=$null
            try { $null=Invoke-LabContainerInstanceStoreClone -Plan $clonePlan -OperationDirectory $Root -Configuration $configuration }
            catch { $catalogFailure=$_.Exception.Message }
            $failedCatalogJournal=Get-Content -LiteralPath (Get-LabContainerInstanceStoreJournalPath -OperationDirectory $Root) -Raw -Encoding utf8 | ConvertFrom-Json -Depth 40
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
            ContinuePlan=$continuePlan; ClonePlan=$clonePlan; Drive=$drive; AttachedPlan=$attachedPlan; VersionPlan=$versionPlan; LeasedPlan=$leasedPlan
            FirstFailure=$firstFailure; FailedJournal=$failedJournal; CatalogFailure=$catalogFailure; FailedCatalogJournal=$failedCatalogJournal
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
    Add-CheckResult -Name 'Wiederaufnahme revalidiert und beendet denselben journalisierten Clone' -Success (
        $evidence.CompletedJournal.Status -eq 'COMPLETED' -and $evidence.CompletedJournal.Recovery.Attempts -eq 3 -and
        $evidence.CompletedJournal.Source.Evidence.Sha256 -eq $evidence.CompletedJournal.Target.Evidence.Sha256)
    $targetStores=@($evidence.CatalogAfter.Document.Stores | Where-Object PersistentStorageId -eq $evidence.ClonePlan.Target.PersistentStorageId)
    Add-CheckResult -Name 'Katalogfehler verhindert COMPLETED und bleibt als wiederaufnehmbarer Recovery-Zustand sichtbar' -Success (
        $evidence.CatalogFailure -match '^CONTAINER_INSTANCE_STORE_RECOVERY_REQUIRED: SYNTHETIC_INSTANCE_STORE_CATALOG_FAILURE' -and
        $evidence.FailedCatalogJournal.Status -eq 'RECOVERY_REQUIRED' -and $evidence.FailedCatalogJournal.Recovery.Status -eq 'RETRY_CLONE')
    Add-CheckResult -Name 'Verifiziertes Clone-Ziel wird atomar und idempotent auf alle Katalogspiegel committed' -Success (
        $evidence.CatalogAfter.Status -eq 'AVAILABLE' -and @($evidence.CatalogAfter.Sources).Count -eq 2 -and
        $evidence.CatalogAfter.Document.Revision -eq 2 -and $targetStores.Count -eq 1 -and
        $targetStores[0].State -eq 'DETACHED' -and -not $targetStores[0].Lease -and
        $targetStores[0].LocationBinding.ProviderResourceId -eq $evidence.ClonePlan.Target.VolumeName -and
        $targetStores[0].LocationBinding.InventoryObjectId -match '^storage-object-[a-f0-9]{24}$' -and
        @($targetStores[0].References | Where-Object { $_.State -eq 'RELEASED' -and $_.TargetId -eq $evidence.ClonePlan.Target.RunId }).Count -eq 1 -and
        $evidence.CompletedAgain.Status -eq 'COMPLETED')
    Add-CheckResult -Name 'Runtime-Befehle mounten die Quelle read-only und entfernen kein Volume' -Success (
        (@($evidence.Commands | Where-Object { $_ -match ':/source:ro' }).Count -ge 1) -and
        (@($evidence.Commands | Where-Object { $_ -match '(^| )volume rm( |$)' }).Count -eq 0))
    Add-CheckResult -Name 'Strikter Intent bleibt schema-valide und geheimnisfrei' -Success (
        $evidence.IntentValid -and (($evidence.ClonePlan | ConvertTo-Json -Depth 30) -notmatch '(?i)password|secret|credential'))
}
finally {
    Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''; Write-Host "Ergebnis: $passed PASS, $($failures.Count) FAIL" -ForegroundColor Cyan
if ($failures.Count) { exit 1 }; exit 0
