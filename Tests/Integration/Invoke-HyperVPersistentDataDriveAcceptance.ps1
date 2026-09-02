#Requires -Version 7.2
<#
.SYNOPSIS
    Belegt Clone, Reattach und Release einer katalogisierten Hyper-V-Daten-VHDX nativ.
.DESCRIPTION
    Erzeugt unter einem eindeutigen temporaeren Lab_Data eine kleine test-eigene
    VHDX und eine ausgeschaltete Generation-2-Test-VM. Der Test klont die
    ungebundene Quelle, bindet den eigenstaendigen Clone an und gibt ihn wieder
    frei. Quelle, DiskIdentifier, VM-Identitaet, Attachments und Checkpoints
    werden real geprüft. SQL-/Gast-Evidenz wird als Voraussetzung modelliert,
    aber ohne Windows-Gast ausdrücklich nicht als nativ ausgeführt behauptet.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$modulePath = Join-Path $repoRoot 'SqlServerLab.psd1'
$token = [guid]::NewGuid().ToString('N').Substring(0,10)
$acceptanceParent = Join-Path ([IO.Path]::GetTempPath()) "SqlServerLab-HyperVPersistent-$token"
$dataRoot = Join-Path $acceptanceParent 'Lab_Data'
$vmPath = Join-Path $dataRoot 'HyperV\Acceptance\VM'
$sourceRelativePath = 'HyperV\Persistent\source-data.vhdx'
$targetRelativePath = 'HyperV\Persistent\clone-data.vhdx'
$sourcePath = Join-Path $dataRoot $sourceRelativePath
$targetPath = Join-Path $dataRoot $targetRelativePath
$operationRoot = Join-Path $dataRoot 'Catalog\operations'
$vmName = "SqlLab-Persistent-$token"
$phase = 'initialize'

try {
    if (Get-VM -Name $vmName -ErrorAction SilentlyContinue) { throw 'HYPERV_PERSISTENT_DATA_ACCEPTANCE_VM_COLLISION' }
    if (Test-Path -LiteralPath $acceptanceParent) { throw 'HYPERV_PERSISTENT_DATA_ACCEPTANCE_PATH_COLLISION' }
    New-Item -ItemType Directory -Path (Split-Path -Parent $sourcePath) -Force | Out-Null
    New-Item -ItemType Directory -Path $vmPath -Force | Out-Null
    New-Item -ItemType Directory -Path $operationRoot -Force | Out-Null
    Import-Module $modulePath -Force -ErrorAction Stop
    $module = Get-Module SqlServerLab

    $phase = 'initialize-managed-storage'
    $runId=[guid]::NewGuid().ToString('D'); $scopeId=[guid]::NewGuid().ToString('D')
    $controllerId=[guid]::NewGuid().ToString('D'); $cloneId=[guid]::NewGuid().ToString('D')
    $configuration = & $module {
        param($Root,$ControllerId)
        $null=Initialize-LabManagedDataRoot -DataRoot $Root -ControllerId $ControllerId -Confirm:$false
        Get-LabStorageConfiguration -DataRoot $Root
    } $dataRoot $controllerId
    $locationId=[string]$configuration.LabDataLocations[0].LocationId

    $phase = 'create-test-assets'
    $reservation = & $module {
        param($RunId,$ScopeId,$Root,$RelativePath,$Configuration)
        Register-LabHyperVInstanceStoreReservation -RunId $RunId -ScopeId $ScopeId -DisplayName 'Native acceptance source' `
            -DataRoot $Root -RelativePath $RelativePath -Configuration $Configuration
    } $runId $scopeId $dataRoot $sourceRelativePath $configuration
    $sourceId=[string]$reservation.Store.PersistentStorageId
    $null = New-VHD -Path $sourcePath -Dynamic -SizeBytes 64MB -ErrorAction Stop
    $sourceVhd = Get-VHD -Path $sourcePath -ErrorAction Stop
    $sourceHash = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
    $vm = New-VM -Name $vmName -Generation 2 -MemoryStartupBytes 256MB -NoVHD -Path $vmPath -ErrorAction Stop
    $notes = & $module {
        param($RunId,$ScopeId,$ChildPath)
        ConvertTo-HyperVLabNotes -RunId $RunId -ScopeId $ScopeId -InstanceId primary -ChildVhdxPath $ChildPath
    } $runId $scopeId (Join-Path $vmPath 'os-placeholder.vhdx')
    $null = Set-VM -VM $vm -Notes $notes -AutomaticCheckpointsEnabled $false -ErrorAction Stop
    $null = Add-VMHardDiskDrive -VMName $vmName -ControllerType SCSI -ControllerNumber 0 -ControllerLocation 1 -Path $sourcePath -ErrorAction Stop
    $null = & $module {
        param($StorageId,$RunId,$ScopeId,$DiskIdentifier,$Configuration,$ExpectedRevision)
        Complete-LabHyperVInstanceStoreReservation -PersistentStorageId $StorageId -RunId $RunId -ScopeId $ScopeId `
            -DiskIdentifier $DiskIdentifier -Configuration $Configuration -ExpectedRevision $ExpectedRevision
    } $sourceId $runId $scopeId ([string]$sourceVhd.DiskIdentifier) $configuration ([int]$reservation.CatalogRevision)
    $targetEvidence=[PSCustomObject]@{ VMId=[string]$vm.Id; SqlMajorVersion='2025'; GuestPath='S:\SQLData'; GuestPathAvailable=$true; ObservedAt=(Get-Date).ToUniversalTime().ToString('o') }
    $sourceDetach=[PSCustomObject]@{ Status='CLEAN_DETACHED'; DirtyState='CLEAN'; DiskIdentifier=([string]$sourceVhd.DiskIdentifier).ToUpperInvariant(); SqlMajorVersion='2025'; GuestPath='S:\SQLData'; DatabasesState='NO_DATABASE_FILES'; ObservedAt=(Get-Date).ToUniversalTime().ToString('o') }

    $phase = 'release-source'
    $sourceCatalog = & $module { param($Configuration) Get-LabPersistentStorageCatalog -Configuration $Configuration } $configuration
    $sourceInspection = & $module { param($Path,$VMName) Get-LabHyperVPersistentDataRuntimeInspection -Path $Path -TargetVMName $VMName } $sourcePath $vmName
    $sourceReleaseIntent=[PSCustomObject]@{
        ContractVersion='SqlServerLab.HyperVPersistentDataIntent/1.0'; OperationId=[guid]::NewGuid().ToString('D'); Action='RELEASE'
        SourcePersistentStorageId=$sourceId; TargetPersistentStorageId=$null; TargetLocationId=$null; TargetRelativePath=$null
        TargetRunId=$runId; TargetScopeId=$scopeId; TargetVMName=$vmName; TargetSqlMajorVersion='2025'; TargetGuestPath='S:\SQLData'
        DetachEvidence=$sourceDetach; TargetEvidence=$targetEvidence; DatabaseDisposition='EXPLICIT_RESTORE_OR_ATTACH_REQUIRED'
    }
    $sourceReleasePlan = & $module { param($Intent,$Catalog,$Configuration,$Inspection) Get-LabHyperVPersistentDataPlan -Intent $Intent -Catalog $Catalog -Configuration $Configuration -RuntimeInspection $Inspection } $sourceReleaseIntent $sourceCatalog $configuration $sourceInspection
    if ([string]$sourceReleasePlan.Status -ne 'READY') { throw "HYPERV_PERSISTENT_DATA_ACCEPTANCE_SOURCE_RELEASE_BLOCKED: $($sourceReleasePlan.Blockers -join ',')" }
    $sourceReleaseJournal = & $module { param($Plan,$Root,$Configuration) Invoke-LabHyperVPersistentDataPlan -Plan $Plan -OperationDirectory $Root -Configuration $Configuration } $sourceReleasePlan (Join-Path $operationRoot 'source-release') $configuration
    if ([string]$sourceReleaseJournal.Status -ne 'COMPLETED' -or -not [bool]$sourceReleaseJournal.CatalogCommitted) {
        throw 'HYPERV_PERSISTENT_DATA_ACCEPTANCE_SOURCE_RELEASE_FAILED'
    }

    $phase = 'clone'
    $inspection = & $module { param($Path,$VMName) Get-LabHyperVPersistentDataRuntimeInspection -Path $Path -TargetVMName $VMName } $sourcePath $vmName
    $catalog = & $module { param($Configuration) Get-LabPersistentStorageCatalog -Configuration $Configuration } $configuration
    $cloneIntent=[PSCustomObject]@{
        ContractVersion='SqlServerLab.HyperVPersistentDataIntent/1.0'; OperationId=[guid]::NewGuid().ToString('D'); Action='CLONE'
        SourcePersistentStorageId=$sourceId; TargetPersistentStorageId=$cloneId; TargetLocationId=$locationId; TargetRelativePath=$targetRelativePath
        TargetRunId=$runId; TargetScopeId=$scopeId; TargetVMName=$vmName; TargetSqlMajorVersion='2025'; TargetGuestPath='S:\SQLData'
        DetachEvidence=$sourceDetach; TargetEvidence=$targetEvidence; DatabaseDisposition='EXPLICIT_RESTORE_OR_ATTACH_REQUIRED'
    }
    $clonePlan = & $module { param($Intent,$Catalog,$Configuration,$Inspection) Get-LabHyperVPersistentDataPlan -Intent $Intent -Catalog $Catalog -Configuration $Configuration -RuntimeInspection $Inspection } $cloneIntent $catalog $configuration $inspection
    if ([string]$clonePlan.Status -ne 'READY') { throw "HYPERV_PERSISTENT_DATA_ACCEPTANCE_CLONE_BLOCKED: $($clonePlan.Blockers -join ',')" }
    $cloneJournal = & $module { param($Plan,$Root,$Configuration) Invoke-LabHyperVPersistentDataPlan -Plan $Plan -OperationDirectory $Root -Configuration $Configuration } $clonePlan (Join-Path $operationRoot 'clone') $configuration
    $cloneVhd = Get-VHD -Path $targetPath -ErrorAction Stop
    $cloneDetachReceipt = & $module {
        param($Path,$PersistentStorageId,$ControllerId,$DiskIdentifier)
        Get-LabHyperVPersistentDataDetachEvidence -Path $Path -PersistentStorageId $PersistentStorageId `
            -ControllerId $ControllerId -DiskIdentifier $DiskIdentifier
    } $targetPath $cloneId $controllerId ([string]$cloneVhd.DiskIdentifier)
    if ([string]$cloneJournal.Status -ne 'COMPLETED' -or -not [bool]$cloneJournal.CatalogCommitted -or [string]$cloneVhd.DiskIdentifier -eq [string]$sourceVhd.DiskIdentifier -or
        [long]$cloneVhd.Size -ne [long]$sourceVhd.Size -or (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $sourceHash -or
        -not $cloneDetachReceipt -or [string]$cloneDetachReceipt.ContractVersion -ne 'SqlServerLab.HyperVPersistentDataDetachEvidence/1.0') {
        throw 'HYPERV_PERSISTENT_DATA_ACCEPTANCE_CLONE_POSTCONDITION_FAILED'
    }

    $phase = 'reattach'
    $cloneCatalog = & $module { param($Configuration) Get-LabPersistentStorageCatalog -Configuration $Configuration } $configuration
    $cloneDetach=$cloneDetachReceipt.DetachEvidence
    $reattachIntent=$cloneIntent | ConvertTo-Json -Depth 30 | ConvertFrom-Json -Depth 30
    $reattachIntent.OperationId=[guid]::NewGuid().ToString('D'); $reattachIntent.Action='REATTACH'; $reattachIntent.SourcePersistentStorageId=$cloneId
    $reattachIntent.TargetPersistentStorageId=$null; $reattachIntent.TargetLocationId=$null; $reattachIntent.TargetRelativePath=$null; $reattachIntent.DetachEvidence=$cloneDetach
    $cloneInspection = & $module { param($Path,$VMName) Get-LabHyperVPersistentDataRuntimeInspection -Path $Path -TargetVMName $VMName } $targetPath $vmName
    $reattachPlan = & $module { param($Intent,$Catalog,$Configuration,$Inspection) Get-LabHyperVPersistentDataPlan -Intent $Intent -Catalog $Catalog -Configuration $Configuration -RuntimeInspection $Inspection } $reattachIntent $cloneCatalog $configuration $cloneInspection
    if ([string]$reattachPlan.Status -ne 'READY') { throw "HYPERV_PERSISTENT_DATA_ACCEPTANCE_REATTACH_BLOCKED: $($reattachPlan.Blockers -join ',')" }
    $reattachJournal = & $module { param($Plan,$Root,$Configuration) Invoke-LabHyperVPersistentDataPlan -Plan $Plan -OperationDirectory $Root -Configuration $Configuration } $reattachPlan (Join-Path $operationRoot 'reattach') $configuration
    $attached = @(Get-VMHardDiskDrive -VMName $vmName -ErrorAction Stop | Where-Object { $_.Path -and [string]::Equals([IO.Path]::GetFullPath([string]$_.Path), [IO.Path]::GetFullPath($targetPath), [StringComparison]::OrdinalIgnoreCase) })
    if ([string]$reattachJournal.Status -ne 'COMPLETED' -or -not [bool]$reattachJournal.CatalogCommitted -or $attached.Count -ne 1) { throw 'HYPERV_PERSISTENT_DATA_ACCEPTANCE_REATTACH_POSTCONDITION_FAILED' }

    $phase = 'release'
    $releaseCatalog = & $module { param($Configuration) Get-LabPersistentStorageCatalog -Configuration $Configuration } $configuration
    $releaseIntent=$reattachIntent | ConvertTo-Json -Depth 30 | ConvertFrom-Json -Depth 30
    $releaseIntent.OperationId=[guid]::NewGuid().ToString('D'); $releaseIntent.Action='RELEASE'
    $releaseInspection = & $module { param($Path,$VMName) Get-LabHyperVPersistentDataRuntimeInspection -Path $Path -TargetVMName $VMName } $targetPath $vmName
    $releasePlan = & $module { param($Intent,$Catalog,$Configuration,$Inspection) Get-LabHyperVPersistentDataPlan -Intent $Intent -Catalog $Catalog -Configuration $Configuration -RuntimeInspection $Inspection } $releaseIntent $releaseCatalog $configuration $releaseInspection
    if ([string]$releasePlan.Status -ne 'READY') { throw "HYPERV_PERSISTENT_DATA_ACCEPTANCE_RELEASE_BLOCKED: $($releasePlan.Blockers -join ',')" }
    $releaseJournal = & $module { param($Plan,$Root,$Configuration) Invoke-LabHyperVPersistentDataPlan -Plan $Plan -OperationDirectory $Root -Configuration $Configuration } $releasePlan (Join-Path $operationRoot 'release') $configuration
    $remainingAttachments = @(Get-VMHardDiskDrive -VMName $vmName -ErrorAction Stop | Where-Object Path -eq $targetPath)
    $finalCatalog = & $module { param($Configuration) Get-LabPersistentStorageCatalog -Configuration $Configuration } $configuration
    $finalSource=@($finalCatalog.Document.Stores | Where-Object PersistentStorageId -eq $sourceId)[0]
    $finalClone=@($finalCatalog.Document.Stores | Where-Object PersistentStorageId -eq $cloneId)[0]
    if ([string]$releaseJournal.Status -ne 'COMPLETED' -or -not [bool]$releaseJournal.CatalogCommitted -or
        $remainingAttachments.Count -ne 0 -or -not (Test-Path -LiteralPath $targetPath -PathType Leaf) -or
        [string]$finalSource.State -ne 'DETACHED' -or $finalSource.Lease -or
        [string]$finalClone.State -ne 'DETACHED' -or $finalClone.Lease -or
        @($finalCatalog.Document.Stores).Count -ne 2) {
        throw 'HYPERV_PERSISTENT_DATA_ACCEPTANCE_RELEASE_POSTCONDITION_FAILED'
    }

    $phase = 'cleanup'
    Remove-VM -Name $vmName -Force -ErrorAction Stop
    $vmName = $null
    Remove-Item -LiteralPath $acceptanceParent -Recurse -Force -ErrorAction Stop
    Write-Host 'PASS: Native Hyper-V-Daten-VHDX wurde quellenunveraendert geklont, reattached und sauber freigegeben; SQL-/Gastnachweis bleibt separat.' -ForegroundColor Green
    exit 0
}
catch {
    Write-Host "FAIL [$phase]: $($_.Exception.Message)" -ForegroundColor Red
    if ($vmName -and (Get-VM -Name $vmName -ErrorAction SilentlyContinue)) {
        try { Remove-VM -Name $vmName -Force -ErrorAction Stop } catch { Write-Warning "Test-VM-Cleanup fehlgeschlagen: $($_.Exception.Message)" }
    }
    if (Test-Path -LiteralPath $acceptanceParent) {
        try { Remove-Item -LiteralPath $acceptanceParent -Recurse -Force -ErrorAction Stop } catch { Write-Warning "Testpfad-Cleanup fehlgeschlagen: $($_.Exception.Message)" }
    }
    exit 1
}
