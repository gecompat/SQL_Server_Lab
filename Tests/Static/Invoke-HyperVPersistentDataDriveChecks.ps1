#Requires -Version 7.2
<#
.SYNOPSIS
    Prueft den Storage-ID-, Reattach-, Release-, Clone- und Recovery-Vertrag fuer Hyper-V-Daten-VHDX.
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
Write-Host 'SQL_Server_Lab - Hyper-V Persistent Data Drive Checks' -ForegroundColor Cyan
Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
Import-Module $modulePath -Force -ErrorAction Stop
$module = Get-Module SqlServerLab
$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) "sql-lab-hyperv-persistent-$([guid]::NewGuid().ToString('N'))"
$dataRoot = Join-Path $temporaryRoot 'Lab_Data'
$sourceRelativePath = Join-Path (Join-Path 'HyperV' 'Persistent') 'source-data.vhdx'
$sourcePath = Join-Path $dataRoot $sourceRelativePath
New-Item -ItemType Directory -Path (Split-Path -Parent $sourcePath) -Force | Out-Null
try {
    $evidence = & $module {
        param($Root,$SourceRelativePath,$OperationRoot)
        $sourceId=[guid]::NewGuid().ToString('D'); $targetId=[guid]::NewGuid().ToString('D')
        $controllerId=[guid]::NewGuid().ToString('D'); $locationId=[guid]::NewGuid().ToString('D')
        $runId=[guid]::NewGuid().ToString('D'); $scopeId=[guid]::NewGuid().ToString('D'); $vmId=[guid]::NewGuid().ToString('D')
        $diskId=[guid]::NewGuid().ToString('D').ToUpperInvariant(); $sourcePath=[IO.Path]::GetFullPath((Join-Path $Root $SourceRelativePath))
        $configuration=[PSCustomObject]@{ ControllerId=$controllerId; LabDataLocations=@([PSCustomObject]@{ LocationId=$locationId; LabDataRoot=$Root; FreeBytes=10GB }) }
        $store=[PSCustomObject]@{
            PersistentStorageId=$sourceId; DisplayName='Hyper-V SQL data'; StorageClass='INSTANCE_STORE'; State='DETACHED'; Provider='hyperv'
            LocationBinding=[PSCustomObject]@{ Residency='LAB_DATA'; LocationId=$locationId; ProviderResourceId=$diskId; InventoryObjectId='storage-object-111111111111111111111111'; RelativePath=$SourceRelativePath }
            References=@(); Lease=$null; Retention='RETAINED'; CleanupDisposition='PRESERVE'; CreatedAt='2026-09-01T00:00:00Z'; UpdatedAt='2026-09-01T00:00:00Z'
        }
        $catalog=[PSCustomObject]@{ Status='AVAILABLE'; Document=[PSCustomObject]@{ ContractVersion='SqlServerLab.PersistentStorageCatalog/1.0'; ControllerId=$controllerId; Revision=1; Stores=@($store) } }
        $inspection=[PSCustomObject]@{
            Status='AVAILABLE'; Path=$sourcePath; DiskIdentifier=$diskId; VhdType='Dynamic'; SizeBytes=1GB; FileSizeBytes=4MB; ParentPath=$null
            Attachments=@(); CheckpointReferences=@()
            Target=[PSCustomObject]@{
                Status='AVAILABLE'; VMName='sql-lab-target'; VMId=$vmId; State='Off'; AutomaticCheckpointsEnabled=$false
                RunId=$runId; ScopeId=$scopeId; InstanceId='primary'; GuestPaths=@(); CheckpointCount=0
                Attachments=@([PSCustomObject]@{ Path='C:\Lab_Data\HyperV\Runs\os.vhdx'; ControllerType='SCSI'; ControllerNumber=0; ControllerLocation=0 })
            }
        }
        $detach=[PSCustomObject]@{ Status='CLEAN_DETACHED'; DirtyState='CLEAN'; DiskIdentifier=$diskId; SqlMajorVersion='2025'; GuestPath='S:\SQLData'; DatabasesState='OFFLINE_OR_DETACHED'; ObservedAt='2026-09-01T00:00:00Z' }
        $targetEvidence=[PSCustomObject]@{ VMId=$vmId; SqlMajorVersion='2025'; GuestPath='S:\SQLData'; GuestPathAvailable=$true; ObservedAt='2026-09-01T00:01:00Z' }
        $baseIntent=[ordered]@{
            ContractVersion='SqlServerLab.HyperVPersistentDataIntent/1.0'; OperationId=[guid]::NewGuid().ToString('D'); Action='REATTACH'
            SourcePersistentStorageId=$sourceId; TargetPersistentStorageId=$null; TargetLocationId=$null; TargetRelativePath=$null
            TargetRunId=$runId; TargetScopeId=$scopeId; TargetVMName='sql-lab-target'; TargetSqlMajorVersion='2025'; TargetGuestPath='S:\SQLData'
            DetachEvidence=$detach; TargetEvidence=$targetEvidence; DatabaseDisposition='EXPLICIT_RESTORE_OR_ATTACH_REQUIRED'
        }
        $reattachIntent=[PSCustomObject]$baseIntent
        $reattachPlan=Get-LabHyperVPersistentDataPlan -Intent $reattachIntent -Catalog $catalog -Configuration $configuration -RuntimeInspection $inspection

        $cloneIntent=$reattachIntent | ConvertTo-Json -Depth 30 | ConvertFrom-Json -Depth 30
        $cloneIntent.OperationId=[guid]::NewGuid().ToString('D'); $cloneIntent.Action='CLONE'; $cloneIntent.TargetPersistentStorageId=$targetId
        $cloneIntent.TargetLocationId=$locationId
        $cloneIntent.TargetRelativePath=Join-Path (Join-Path 'HyperV' 'Persistent') 'clone-data.vhdx'
        $clonePlan=Get-LabHyperVPersistentDataPlan -Intent $cloneIntent -Catalog $catalog -Configuration $configuration -RuntimeInspection $inspection

        $attachedInspection=$inspection | ConvertTo-Json -Depth 30 | ConvertFrom-Json -Depth 30
        $attachedInspection.Attachments=@([PSCustomObject]@{ VMName='foreign'; VMId=[guid]::NewGuid().ToString('D'); VMState='Off'; ControllerType='SCSI'; ControllerNumber=0; ControllerLocation=1 })
        $attachedPlan=Get-LabHyperVPersistentDataPlan -Intent $reattachIntent -Catalog $catalog -Configuration $configuration -RuntimeInspection $attachedInspection

        $checkpointInspection=$inspection | ConvertTo-Json -Depth 30 | ConvertFrom-Json -Depth 30
        $checkpointInspection.Target.CheckpointCount=1
        $checkpointPlan=Get-LabHyperVPersistentDataPlan -Intent $reattachIntent -Catalog $catalog -Configuration $configuration -RuntimeInspection $checkpointInspection

        $versionIntent=$reattachIntent | ConvertTo-Json -Depth 30 | ConvertFrom-Json -Depth 30
        $versionIntent.TargetSqlMajorVersion='2022'; $versionIntent.TargetEvidence.SqlMajorVersion='2022'
        $versionPlan=Get-LabHyperVPersistentDataPlan -Intent $versionIntent -Catalog $catalog -Configuration $configuration -RuntimeInspection $inspection

        $releaseCatalog=$catalog | ConvertTo-Json -Depth 30 | ConvertFrom-Json -Depth 30
        $releaseCatalog.Document.Stores[0].State='IN_USE'
        $releaseCatalog.Document.Stores[0].References=@([PSCustomObject]@{ ReferenceId=[guid]::NewGuid().ToString('D'); Kind='RUN'; State='ACTIVE'; TargetId=$runId })
        $releaseCatalog.Document.Stores[0].Lease=[PSCustomObject]@{ LeaseId=[guid]::NewGuid().ToString('D'); RunId=$runId; ScopeId=$scopeId; Mode='EXCLUSIVE'; AcquiredAt='2026-09-01T00:00:00Z'; ExpiresAt=$null }
        $releaseIntent=$reattachIntent | ConvertTo-Json -Depth 30 | ConvertFrom-Json -Depth 30
        $releaseIntent.OperationId=[guid]::NewGuid().ToString('D'); $releaseIntent.Action='RELEASE'
        $releaseInspection=$inspection | ConvertTo-Json -Depth 30 | ConvertFrom-Json -Depth 30
        $releaseInspection.Attachments=@([PSCustomObject]@{ VMName='sql-lab-target'; VMId=$vmId; VMState='Off'; ControllerType='SCSI'; ControllerNumber=0; ControllerLocation=1 })
        $releaseInspection.Target.Attachments += [PSCustomObject]@{ Path=$sourcePath; ControllerType='SCSI'; ControllerNumber=0; ControllerLocation=1 }
        $releasePlan=Get-LabHyperVPersistentDataPlan -Intent $releaseIntent -Catalog $releaseCatalog -Configuration $configuration -RuntimeInspection $releaseInspection

        $originalInspection=(Get-Command Get-LabHyperVPersistentDataRuntimeInspection).ScriptBlock
        $originalHash=(Get-Command Get-FileHash).ScriptBlock
        $originalConvert=(Get-Command Convert-VHD -ErrorAction SilentlyContinue).ScriptBlock
        $originalSetVhd=(Get-Command Set-VHD -ErrorAction SilentlyContinue).ScriptBlock
        $originalGetVhd=(Get-Command Get-VHD -ErrorAction SilentlyContinue).ScriptBlock
        try {
            $script:hvpInspection=$inspection; $script:hvpSourceHash=('a' * 64); $script:hvpConvertAttempts=0; $script:hvpTargetDiskId=[guid]::NewGuid().ToString('D').ToUpperInvariant()
            Set-Item Function:Get-LabHyperVPersistentDataRuntimeInspection -Value { param($Path,$TargetVMName) $script:hvpInspection }
            Set-Item Function:Get-FileHash -Value { param($LiteralPath,$Algorithm) [PSCustomObject]@{ Hash=$script:hvpSourceHash } }
            Set-Item Function:Convert-VHD -Value {
                param($Path,$DestinationPath,$VHDType)
                $script:hvpConvertAttempts++
                $null=New-Item -ItemType File -Path $DestinationPath -Force
                if ($script:hvpConvertAttempts -eq 1) { throw 'HYPERV_PERSISTENT_DATA_SYNTHETIC_COPY_FAILURE' }
            }
            Set-Item Function:Set-VHD -Value { param($Path,[switch]$ResetDiskIdentifier,[switch]$Force) }
            Set-Item Function:Get-VHD -Value { param($Path) [PSCustomObject]@{ Size=1GB; DiskIdentifier=$script:hvpTargetDiskId } }
            $firstFailure=$null
            try { $null=Invoke-LabHyperVPersistentDataPlan -Plan $clonePlan -OperationDirectory $OperationRoot } catch { $firstFailure=$_.Exception.Message }
            $failedJournal=Get-Content -LiteralPath (Get-LabHyperVPersistentDataJournalPath -OperationDirectory $OperationRoot) -Raw | ConvertFrom-Json -Depth 30
            $completedJournal=Invoke-LabHyperVPersistentDataPlan -Plan $clonePlan -OperationDirectory $OperationRoot
        }
        finally {
            Set-Item Function:Get-LabHyperVPersistentDataRuntimeInspection -Value $originalInspection
            if ($originalHash) { Set-Item Function:Get-FileHash -Value $originalHash } else { Remove-Item Function:Get-FileHash -ErrorAction SilentlyContinue }
            if ($originalConvert) { Set-Item Function:Convert-VHD -Value $originalConvert } else { Remove-Item Function:Convert-VHD -ErrorAction SilentlyContinue }
            if ($originalSetVhd) { Set-Item Function:Set-VHD -Value $originalSetVhd } else { Remove-Item Function:Set-VHD -ErrorAction SilentlyContinue }
            if ($originalGetVhd) { Set-Item Function:Get-VHD -Value $originalGetVhd } else { Remove-Item Function:Get-VHD -ErrorAction SilentlyContinue }
            Remove-Variable hvpInspection,hvpSourceHash,hvpConvertAttempts,hvpTargetDiskId -Scope Script -ErrorAction SilentlyContinue
        }
        [PSCustomObject]@{
            ReattachPlan=$reattachPlan; ClonePlan=$clonePlan; ReleasePlan=$releasePlan; AttachedPlan=$attachedPlan
            CheckpointPlan=$checkpointPlan; VersionPlan=$versionPlan; IntentValid=(Test-LabHyperVPersistentDataIntent -Intent $cloneIntent)
            FirstFailure=$firstFailure; FailedJournal=$failedJournal; CompletedJournal=$completedJournal
        }
    } $dataRoot $sourceRelativePath $temporaryRoot

    Add-CheckResult -Name 'Stabile Storage-ID bindet exakt die katalogisierte Lab_Data-VHDX' -Success (
        $evidence.ReattachPlan.Status -eq 'READY' -and $evidence.ReattachPlan.Source.PersistentStorageId -and
        [IO.Path]::GetFullPath($evidence.ReattachPlan.Source.Path) -eq [IO.Path]::GetFullPath($sourcePath))
    Add-CheckResult -Name 'Reattach verlangt ausgeschaltete VM, freien Gastpfad und explizite Datenbankaktion' -Success (
        $evidence.ReattachPlan.Preview.RequiresTargetVMOff -and $evidence.ReattachPlan.Preview.RequiresCleanDetach -and
        -not $evidence.ReattachPlan.Preview.DatabaseFilesOnline -and $evidence.ReattachPlan.Preview.DatabaseActionRequired -eq 'EXPLICIT_RESTORE_OR_ATTACH')
    Add-CheckResult -Name 'Clone bleibt eigenständig, quellenunverändernd und katalogpflichtig' -Success (
        $evidence.ClonePlan.Status -eq 'READY' -and -not $evidence.ClonePlan.Preview.SourceMutation -and -not $evidence.ClonePlan.Preview.SourceDeletion -and
        $evidence.ClonePlan.Target.Path -match 'clone-data\.vhdx$' -and $evidence.ClonePlan.Preview.CatalogCommitRequired)
    Add-CheckResult -Name 'Release erfordert passende aktive Lease und exklusives Ziel-VM-Attachment' -Success (
        $evidence.ReleasePlan.Status -eq 'READY' -and @($evidence.ReleasePlan.Steps | Where-Object Action -eq 'VERIFY_HOST_DETACH').Count -eq 1)
    Add-CheckResult -Name 'Fremdes Attachment blockiert Reattach vor jeder Mutation' -Success (
        $evidence.AttachedPlan.Status -eq 'BLOCKED' -and 'SOURCE_VHDX_ATTACHED' -in @($evidence.AttachedPlan.Blockers))
    Add-CheckResult -Name 'Vorhandene Checkpoints blockieren den Lifecycle fail-closed' -Success (
        $evidence.CheckpointPlan.Status -eq 'BLOCKED' -and 'TARGET_VM_CHECKPOINTS_PRESENT' -in @($evidence.CheckpointPlan.Blockers))
    Add-CheckResult -Name 'Neuer-zu-aelter SQL-Wechsel bleibt blockiert' -Success (
        $evidence.VersionPlan.Status -eq 'BLOCKED' -and 'SOURCE_SQL_VERSION_INCOMPATIBLE' -in @($evidence.VersionPlan.Blockers))
    Add-CheckResult -Name 'Clone-Fehler persistiert RECOVERY_REQUIRED und ist wiederaufnehmbar' -Success (
        $evidence.FirstFailure -match '^HYPERV_PERSISTENT_DATA_RECOVERY_REQUIRED' -and $evidence.FailedJournal.Status -eq 'RECOVERY_REQUIRED' -and
        $evidence.FailedJournal.TargetOwnedByOperation -and $evidence.CompletedJournal.Status -eq 'COMPLETED' -and $evidence.CompletedJournal.Recovery.Attempts -eq 2)
    Add-CheckResult -Name 'Target-DiskIdentifier unterscheidet sich nach Clone von der Quelle' -Success (
        $evidence.CompletedJournal.TargetDiskIdentifier -and $evidence.CompletedJournal.TargetDiskIdentifier -ne $evidence.ClonePlan.Source.DiskIdentifier)
    Add-CheckResult -Name 'Intent und Plan bleiben schema-valide und geheimnisfrei' -Success (
        $evidence.IntentValid -and (($evidence.ClonePlan | ConvertTo-Json -Depth 30) -notmatch '(?i)password|secret|credential'))
}
catch {
    Add-CheckResult -Name 'Hyper-V Persistent Data Drive Testausfuehrung' -Success $false -Message $_.Exception.Message
}
finally {
    Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $temporaryRoot) { Remove-Item -LiteralPath $temporaryRoot -Recurse -Force }
}

Write-Host ''
Write-Host "Ergebnis: $passed PASS, $($failures.Count) FAIL" -ForegroundColor Cyan
if ($failures.Count) { exit 1 }
exit 0
