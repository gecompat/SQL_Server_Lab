<#
.SYNOPSIS
    Plant und fuehrt den sicheren Lifecycle katalogisierter Hyper-V-Daten-VHDX aus.
.DESCRIPTION
    Die stabile PersistentStorageId wird gegen Katalog, registriertes Lab_Data,
    VHDX-DiskIdentifier, Attachments, Checkpoints, VM-Identitaet und explizite
    Clean-Detach-/Gastpfad-Evidenz revalidiert. REATTACH und RELEASE mutieren nur
    eine ausgeschaltete, eindeutig gebundene Ziel-VM. CLONE konvertiert eine
    ungebundene Quelle in eine eigenstaendige VHDX und veraendert die Quelle nie.
    Vorhandene Datenbankdateien werden ausdruecklich nicht als online ausgegeben.
#>

function Test-LabHyperVPersistentDataIntent {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Intent)

    $schemaPath = Join-Path $script:SchemasPath 'hyperv-persistent-data-intent.schema.json'
    try {
        $valid = $Intent | ConvertTo-Json -Depth 40 | Test-Json -SchemaFile $schemaPath -ErrorAction Stop
    }
    catch { throw "HYPERV_PERSISTENT_DATA_INTENT_SCHEMA_INVALID: $($_.Exception.Message)" }
    if (-not $valid) { throw 'HYPERV_PERSISTENT_DATA_INTENT_SCHEMA_INVALID' }
    return $true
}

function Test-LabHyperVPathWithinRoot {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Root)

    $resolvedPath = [IO.Path]::GetFullPath($Path)
    $resolvedRoot = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    return $resolvedPath.StartsWith("$resolvedRoot$([IO.Path]::DirectorySeparatorChar)", [StringComparison]::OrdinalIgnoreCase)
}

function Get-LabHyperVPersistentDataRuntimeInspection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$TargetVMName
    )

    $resolvedPath = [IO.Path]::GetFullPath($Path)
    $vhd = $null
    if (Test-Path -LiteralPath $resolvedPath -PathType Leaf) {
        try { $vhd = Get-VHD -Path $resolvedPath -ErrorAction Stop }
        catch { throw "HYPERV_PERSISTENT_DATA_VHD_INSPECTION_FAILED: $($_.Exception.Message)" }
    }

    $attachments = [Collections.Generic.List[object]]::new()
    $checkpointReferences = [Collections.Generic.List[object]]::new()
    foreach ($vm in @(Get-VM -ErrorAction SilentlyContinue)) {
        foreach ($drive in @($vm | Get-VMHardDiskDrive -ErrorAction SilentlyContinue)) {
            if ($drive.Path -and [string]::Equals([IO.Path]::GetFullPath([string]$drive.Path), $resolvedPath, [StringComparison]::OrdinalIgnoreCase)) {
                $attachments.Add([PSCustomObject]@{
                    VMName=[string]$vm.Name; VMId=[string]$vm.Id; VMState=[string]$vm.State
                    ControllerType=[string]$drive.ControllerType; ControllerNumber=[int]$drive.ControllerNumber
                    ControllerLocation=[int]$drive.ControllerLocation
                })
            }
        }
        foreach ($snapshot in @(Get-VMSnapshot -VM $vm -ErrorAction SilentlyContinue)) {
            foreach ($drive in @($snapshot | Get-VMHardDiskDrive -ErrorAction SilentlyContinue)) {
                if ($drive.Path -and [string]::Equals([IO.Path]::GetFullPath([string]$drive.Path), $resolvedPath, [StringComparison]::OrdinalIgnoreCase)) {
                    $checkpointReferences.Add([PSCustomObject]@{ VMName=[string]$vm.Name; VMId=[string]$vm.Id; CheckpointId=[string]$snapshot.Id })
                }
            }
        }
    }

    $targetMatches = @(Get-VM -Name $TargetVMName -ErrorAction SilentlyContinue)
    $target = if ($targetMatches.Count -eq 1) { $targetMatches[0] } else { $null }
    $targetIdentity = if ($target) { ConvertFrom-HyperVLabNotes -Notes ([string]$target.Notes) } else { $null }
    $targetDrives = if ($target) { @($target | Get-VMHardDiskDrive -ErrorAction SilentlyContinue) } else { @() }
    $targetCheckpoints = if ($target) { @(Get-VMSnapshot -VM $target -ErrorAction SilentlyContinue) } else { @() }

    [PSCustomObject]@{
        Status=if ($vhd) { 'AVAILABLE' } else { 'MISSING' }
        Path=$resolvedPath
        DiskIdentifier=if ($vhd) { ([string]$vhd.DiskIdentifier).ToUpperInvariant() } else { $null }
        VhdType=if ($vhd) { [string]$vhd.VhdType } else { $null }
        SizeBytes=if ($vhd) { [long]$vhd.Size } else { 0 }
        FileSizeBytes=if ($vhd) { [long]$vhd.FileSize } else { 0 }
        ParentPath=if ($vhd) { [string]$vhd.ParentPath } else { $null }
        Attachments=@($attachments)
        CheckpointReferences=@($checkpointReferences)
        Target=[PSCustomObject]@{
            Status=if ($targetMatches.Count -eq 1) { 'AVAILABLE' } elseif ($targetMatches.Count -gt 1) { 'AMBIGUOUS' } else { 'MISSING' }
            VMName=$TargetVMName; VMId=if ($target) { [string]$target.Id } else { $null }
            State=if ($target) { [string]$target.State } else { $null }
            AutomaticCheckpointsEnabled=if ($target) { [bool]$target.AutomaticCheckpointsEnabled } else { $null }
            RunId=if ($targetIdentity) { [string]$targetIdentity.runId } else { $null }
            ScopeId=if ($targetIdentity) { [string]$targetIdentity.scopeId } else { $null }
            InstanceId=if ($targetIdentity) { [string]$targetIdentity.instanceId } else { $null }
            GuestPaths=if ($targetIdentity) { @($targetIdentity.additionalDrives | ForEach-Object { [string]$_.guestPath } | Where-Object { $_ }) } else { @() }
            CheckpointCount=$targetCheckpoints.Count
            Attachments=@($targetDrives | ForEach-Object {
                [PSCustomObject]@{ Path=[string]$_.Path; ControllerType=[string]$_.ControllerType; ControllerNumber=[int]$_.ControllerNumber; ControllerLocation=[int]$_.ControllerLocation }
            })
        }
    }
}

function Resolve-LabHyperVPersistentDataCatalogBinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Intent,
        [Parameter(Mandatory)]$Catalog,
        [Parameter(Mandatory)]$Configuration,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[string]]$Issues
    )

    $catalogStatus = if ($Catalog.PSObject.Properties['Status']) { [string]$Catalog.Status } else { 'AVAILABLE' }
    $document = if ($Catalog.PSObject.Properties['Document']) { $Catalog.Document } else { $Catalog }
    if ($catalogStatus -ne 'AVAILABLE') { $Issues.Add("CATALOG_$catalogStatus") }
    if (-not $document -or [string]$document.ContractVersion -ne 'SqlServerLab.PersistentStorageCatalog/1.0') { $Issues.Add('CATALOG_CONTRACT_INVALID') }
    elseif ([string]$document.ControllerId -ne [string]$Configuration.ControllerId) { $Issues.Add('CATALOG_CONTROLLER_MISMATCH') }

    $stores = @($document.Stores | Where-Object { [string]$_.PersistentStorageId -eq [string]$Intent.SourcePersistentStorageId })
    if ($stores.Count -ne 1) { $Issues.Add('SOURCE_STORAGE_NOT_FOUND'); return $null }
    $store = $stores[0]
    if ([string]$store.StorageClass -ne 'INSTANCE_STORE') { $Issues.Add('SOURCE_STORAGE_CLASS_INVALID') }
    if ([string]$store.Provider -ne 'hyperv') { $Issues.Add('SOURCE_PROVIDER_MISMATCH') }
    if ([string]$store.LocationBinding.Residency -ne 'LAB_DATA' -or -not $store.LocationBinding.LocationId -or -not $store.LocationBinding.RelativePath) {
        $Issues.Add('SOURCE_LAB_DATA_BINDING_INVALID')
        return [PSCustomObject]@{ Store=$store; Path=$null; Root=$null }
    }
    $locations = @($Configuration.LabDataLocations | Where-Object { [string]$_.LocationId -eq [string]$store.LocationBinding.LocationId })
    if ($locations.Count -ne 1) { $Issues.Add('SOURCE_LOCATION_NOT_REGISTERED'); return [PSCustomObject]@{ Store=$store; Path=$null; Root=$null } }
    $root = [IO.Path]::GetFullPath([string]$locations[0].LabDataRoot)
    $path = [IO.Path]::GetFullPath((Join-Path $root ([string]$store.LocationBinding.RelativePath)))
    if (-not (Test-LabHyperVPathWithinRoot -Path $path -Root $root)) { $Issues.Add('SOURCE_PATH_OUTSIDE_LAB_DATA') }
    return [PSCustomObject]@{ Store=$store; Path=$path; Root=$root; Document=$document }
}

function Get-LabHyperVPersistentDataPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Intent,
        [Parameter(Mandatory)]$Catalog,
        [Parameter(Mandatory)]$Configuration,
        [Parameter(Mandatory)]$RuntimeInspection
    )

    $null = Test-LabHyperVPersistentDataIntent -Intent $Intent
    $issues = [Collections.Generic.List[string]]::new()
    $binding = Resolve-LabHyperVPersistentDataCatalogBinding -Intent $Intent -Catalog $Catalog -Configuration $Configuration -Issues $issues
    $store = if ($binding) { $binding.Store } else { $null }
    $action = [string]$Intent.Action

    if ($store) {
        if ($action -eq 'RELEASE') {
            if ([string]$store.State -ne 'IN_USE') { $issues.Add('SOURCE_STATE_NOT_IN_USE') }
            if (-not $store.Lease -or [string]$store.Lease.RunId -ne [string]$Intent.TargetRunId -or [string]$store.Lease.ScopeId -ne [string]$Intent.TargetScopeId) { $issues.Add('SOURCE_LEASE_TARGET_MISMATCH') }
        }
        else {
            if ([string]$store.State -notin @('AVAILABLE','DETACHED')) { $issues.Add('SOURCE_STATE_NOT_DETACHED') }
            if ($store.Lease) { $issues.Add('SOURCE_LEASE_ACTIVE') }
            if (@($store.References | Where-Object State -eq 'ACTIVE').Count -gt 0) { $issues.Add('SOURCE_REFERENCE_ACTIVE') }
        }
        if ([string]$store.Retention -ne 'RETAINED' -or [string]$store.CleanupDisposition -ne 'PRESERVE') { $issues.Add('SOURCE_RETENTION_NOT_PERSISTENT') }
    }

    if ([string]$RuntimeInspection.Status -ne 'AVAILABLE') { $issues.Add('SOURCE_VHDX_NOT_OBSERVED') }
    if ($binding -and $binding.Path -and -not [string]::Equals([string]$RuntimeInspection.Path, [string]$binding.Path, [StringComparison]::OrdinalIgnoreCase)) { $issues.Add('SOURCE_PATH_BINDING_MISMATCH') }
    if ([string]$RuntimeInspection.DiskIdentifier -notmatch '^[A-Fa-f0-9]{8}(?:-[A-Fa-f0-9]{4}){3}-[A-Fa-f0-9]{12}$') { $issues.Add('SOURCE_DISK_IDENTIFIER_INVALID') }
    if ($store -and [string]$store.LocationBinding.ProviderResourceId -ne [string]$RuntimeInspection.DiskIdentifier) { $issues.Add('SOURCE_DISK_IDENTIFIER_MISMATCH') }
    if ([string]$RuntimeInspection.ParentPath) { $issues.Add('SOURCE_DIFFERENCING_VHDX_UNSUPPORTED') }
    if (@($RuntimeInspection.CheckpointReferences).Count -gt 0) { $issues.Add('SOURCE_CHECKPOINT_REFERENCE_ACTIVE') }

    $detach = $Intent.DetachEvidence
    if ([string]$detach.Status -ne 'CLEAN_DETACHED' -or [string]$detach.DirtyState -ne 'CLEAN') { $issues.Add('SOURCE_CLEAN_DETACH_UNVERIFIED') }
    if ([string]$detach.DiskIdentifier -ne [string]$RuntimeInspection.DiskIdentifier) { $issues.Add('SOURCE_DETACH_DISK_IDENTIFIER_MISMATCH') }
    if ([string]$detach.SqlMajorVersion -ne [string]$Intent.TargetSqlMajorVersion) { $issues.Add('SOURCE_SQL_VERSION_INCOMPATIBLE') }
    if ([string]$detach.GuestPath -ne [string]$Intent.TargetGuestPath) { $issues.Add('SOURCE_GUEST_PATH_MISMATCH') }

    $target = $RuntimeInspection.Target
    if ([string]$target.Status -ne 'AVAILABLE') { $issues.Add('TARGET_VM_NOT_FOUND') }
    if ([string]$target.State -ne 'Off') { $issues.Add('TARGET_VM_MUST_BE_OFF') }
    if ([string]$target.RunId -ne [string]$Intent.TargetRunId -or [string]$target.ScopeId -ne [string]$Intent.TargetScopeId) { $issues.Add('TARGET_VM_IDENTITY_MISMATCH') }
    if ([string]$Intent.TargetEvidence.VMId -ne [string]$target.VMId) { $issues.Add('TARGET_VM_EVIDENCE_MISMATCH') }
    if ([string]$Intent.TargetEvidence.SqlMajorVersion -ne [string]$Intent.TargetSqlMajorVersion) { $issues.Add('TARGET_SQL_VERSION_UNVERIFIED') }
    if (-not [bool]$Intent.TargetEvidence.GuestPathAvailable -or [string]$Intent.TargetEvidence.GuestPath -ne [string]$Intent.TargetGuestPath) { $issues.Add('TARGET_GUEST_PATH_NOT_FREE') }
    if ($action -ne 'RELEASE' -and [string]$Intent.TargetGuestPath -in @($target.GuestPaths | ForEach-Object { [string]$_ })) { $issues.Add('TARGET_GUEST_PATH_ALREADY_BOUND') }
    if ([int]$target.CheckpointCount -gt 0) { $issues.Add('TARGET_VM_CHECKPOINTS_PRESENT') }
    if ([bool]$target.AutomaticCheckpointsEnabled) { $issues.Add('TARGET_AUTOMATIC_CHECKPOINTS_ENABLED') }

    $sourceAttachments = @($RuntimeInspection.Attachments)
    if ($action -eq 'RELEASE') {
        if ($sourceAttachments.Count -ne 1 -or [string]$sourceAttachments[0].VMId -ne [string]$target.VMId) { $issues.Add('SOURCE_NOT_EXCLUSIVELY_ATTACHED_TO_TARGET') }
    }
    elseif ($sourceAttachments.Count -gt 0) { $issues.Add('SOURCE_VHDX_ATTACHED') }

    $occupied = @(
        $target.Attachments |
            Where-Object { [string]$_.ControllerType -eq 'SCSI' -and [int]$_.ControllerNumber -eq 0 } |
            ForEach-Object { [int]$_.ControllerLocation }
    )
    $availableSlots = @(1..63 | Where-Object { $_ -notin $occupied })
    $controllerLocation = if ($action -eq 'RELEASE' -and $sourceAttachments.Count -eq 1) { [int]$sourceAttachments[0].ControllerLocation } elseif ($availableSlots.Count -gt 0) { [int]$availableSlots[0] } else { $null }
    if ($null -eq $controllerLocation) { $issues.Add('TARGET_SCSI_SLOT_UNAVAILABLE') }

    $targetPath = $null
    if ($action -eq 'CLONE') {
        $targetIds = if ($binding -and $binding.Document) { @($binding.Document.Stores | Where-Object { [string]$_.PersistentStorageId -eq [string]$Intent.TargetPersistentStorageId }) } else { @() }
        if ($targetIds.Count -gt 0 -or [string]$Intent.TargetPersistentStorageId -eq [string]$Intent.SourcePersistentStorageId) { $issues.Add('TARGET_STORAGE_ID_ALREADY_USED') }
        $targetLocation = @($Configuration.LabDataLocations | Where-Object { [string]$_.LocationId -eq [string]$Intent.TargetLocationId })
        if ($targetLocation.Count -ne 1) { $issues.Add('TARGET_LOCATION_NOT_REGISTERED') }
        else {
            $targetRoot = [IO.Path]::GetFullPath([string]$targetLocation[0].LabDataRoot)
            $targetPath = [IO.Path]::GetFullPath((Join-Path $targetRoot ([string]$Intent.TargetRelativePath)))
            if (-not (Test-LabHyperVPathWithinRoot -Path $targetPath -Root $targetRoot)) { $issues.Add('TARGET_PATH_OUTSIDE_LAB_DATA') }
            if (Test-Path -LiteralPath $targetPath) { $issues.Add('TARGET_VHDX_ALREADY_EXISTS') }
            if (-not $targetLocation[0].PSObject.Properties['FreeBytes']) { $issues.Add('TARGET_FREE_SPACE_UNVERIFIED') }
            elseif ([long]$targetLocation[0].FreeBytes -lt ([long]$RuntimeInspection.FileSizeBytes + 64MB)) { $issues.Add('TARGET_CAPACITY_INSUFFICIENT') }
        }
    }

    $blockers = @($issues | Sort-Object -Unique)
    $steps = switch ($action) {
        'REATTACH' { @('REVALIDATE_SOURCE_AND_TARGET','ATTACH_EXISTING_VHDX','UPDATE_VM_IDENTITY','VERIFY_HOST_ATTACHMENT','REQUIRE_EXPLICIT_DATABASE_RESTORE_OR_ATTACH') }
        'RELEASE' { @('REVALIDATE_CLEAN_RELEASE','DETACH_VHDX','UPDATE_VM_IDENTITY','VERIFY_HOST_DETACH','RELEASE_CATALOG_LEASE_REQUIRED') }
        'CLONE' { @('REVALIDATE_DETACHED_SOURCE','CONVERT_SOURCE_TO_INDEPENDENT_VHDX','VERIFY_SOURCE_UNCHANGED','VERIFY_TARGET_IDENTITY','REGISTER_TARGET_CANDIDATE') }
    }
    $plan = [PSCustomObject]@{
        ContractVersion='SqlServerLab.HyperVPersistentDataPlan/1.0'; OperationId=[string]$Intent.OperationId
        Status=if ($blockers.Count -eq 0) { 'READY' } else { 'BLOCKED' }; Action=$action
        Source=[PSCustomObject]@{
            PersistentStorageId=[string]$Intent.SourcePersistentStorageId; Path=if ($binding) { [string]$binding.Path } else { $null }
            LocationId=if ($store) { [string]$store.LocationBinding.LocationId } else { $null }
            DiskIdentifier=[string]$RuntimeInspection.DiskIdentifier; VhdType=[string]$RuntimeInspection.VhdType
            SizeBytes=[long]$RuntimeInspection.SizeBytes; SqlMajorVersion=[string]$detach.SqlMajorVersion; GuestPath=[string]$detach.GuestPath
            Retention=if ($store) { [string]$store.Retention } else { $null }; CleanupDisposition=if ($store) { [string]$store.CleanupDisposition } else { $null }
        }
        Target=[PSCustomObject]@{
            PersistentStorageId=if ($action -eq 'CLONE') { [string]$Intent.TargetPersistentStorageId } else { $null }; Path=$targetPath
            VMName=[string]$Intent.TargetVMName; VMId=[string]$target.VMId; RunId=[string]$Intent.TargetRunId; ScopeId=[string]$Intent.TargetScopeId
            InstanceId=[string]$target.InstanceId; SqlMajorVersion=[string]$Intent.TargetSqlMajorVersion; GuestPath=[string]$Intent.TargetGuestPath
            ControllerNumber=0; ControllerLocation=$controllerLocation
        }
        Steps=@($steps | ForEach-Object -Begin { $order=0 } -Process { $order++; [PSCustomObject]@{ Order=$order; Action=$_ } })
        Blockers=$blockers
        Preview=[PSCustomObject]@{ SourceMutation=$false; SourceDeletion=$false; RequiresCleanDetach=$true; RequiresTargetVMOff=$true; DatabaseFilesOnline=$false; DatabaseActionRequired='EXPLICIT_RESTORE_OR_ATTACH'; CatalogCommitRequired=$true }
    }
    $schemaPath = Join-Path $script:SchemasPath 'hyperv-persistent-data-plan.schema.json'
    if (-not (($plan | ConvertTo-Json -Depth 40) | Test-Json -SchemaFile $schemaPath -ErrorAction SilentlyContinue)) { throw 'HYPERV_PERSISTENT_DATA_PLAN_SCHEMA_INVALID' }
    return $plan
}

function Get-LabHyperVPersistentDataJournalPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$OperationDirectory)
    return (Join-Path $OperationDirectory 'hyperv-persistent-data-journal.json')
}

function Write-LabHyperVPersistentDataJournal {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Journal, [Parameter(Mandatory)][string]$Path)
    $Journal.UpdatedAt = Get-LabTimestamp
    Write-LabArtifactJsonAtomic -Path $Path -InputObject $Journal
    return $Journal
}

function Set-LabHyperVPersistentDataVMIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)][ValidateSet('ATTACH','RELEASE')][string]$Action
    )

    $managed = Get-HyperVManagedVM -VMName ([string]$Plan.Target.VMName) -ExpectedRunId ([string]$Plan.Target.RunId) -ExpectedScopeId ([string]$Plan.Target.ScopeId)
    if (-not $managed -or [string]$managed.VM.State -ne 'Off') { throw 'HYPERV_PERSISTENT_DATA_MANAGED_VM_REVALIDATION_FAILED' }
    $sourcePath = [IO.Path]::GetFullPath([string]$Plan.Source.Path)
    $drives = @($managed.Identity.additionalDrives | Where-Object {
        -not $_.path -or -not [string]::Equals([IO.Path]::GetFullPath([string]$_.path), $sourcePath, [StringComparison]::OrdinalIgnoreCase)
    })
    if ($Action -eq 'ATTACH') {
        $driveLetter = ([string]$Plan.Target.GuestPath).Substring(0,1).ToUpperInvariant()
        $drives += [PSCustomObject]@{
            id="persistent-$(([string]$Plan.Source.PersistentStorageId).Substring(0,8))"; role='sqlData'
            sizeBytes=[long]$Plan.Source.SizeBytes; vhdType=([string]$Plan.Source.VhdType).ToLowerInvariant(); path=$sourcePath
            diskIdentifier=[string]$Plan.Source.DiskIdentifier; controllerNumber=[int]$Plan.Target.ControllerNumber
            controllerLocation=[int]$Plan.Target.ControllerLocation; guestPath=[string]$Plan.Target.GuestPath; driveLetter=$driveLetter
            fileSystem='NTFS'; allocationUnitKB=64; volumeLabel='SQLLAB_DATA'; maximumIops=0
            hostRoot=(Split-Path -Parent $sourcePath); locationId=[string]$Plan.Source.LocationId; selector=$null
            persistentStorageId=[string]$Plan.Source.PersistentStorageId; retention=[string]$Plan.Source.Retention
            cleanupDisposition=[string]$Plan.Source.CleanupDisposition
        }
    }
    $managed.Identity | Add-Member -NotePropertyName additionalDrives -NotePropertyValue @($drives) -Force
    $managed.Identity | Add-Member -NotePropertyName additionalVhdxPaths -NotePropertyValue @($drives | ForEach-Object { [IO.Path]::GetFullPath([string]$_.path) }) -Force
    $managed.Identity | Add-Member -NotePropertyName contractVersion -NotePropertyValue '0.7' -Force
    $notes = $script:HyperVLabNotesPrefix + ($managed.Identity | ConvertTo-Json -Compress -Depth 12)
    $null = Set-VM -VM $managed.VM -Notes $notes -AutomaticCheckpointsEnabled $false -ErrorAction Stop
    return @($drives)
}

function Invoke-LabHyperVPersistentDataPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)][string]$OperationDirectory
    )

    if ([string]$Plan.Status -ne 'READY') { throw 'HYPERV_PERSISTENT_DATA_READY_PLAN_REQUIRED' }
    if (-not (Test-Path -LiteralPath $OperationDirectory -PathType Container)) { $null = New-Item -ItemType Directory -Path $OperationDirectory -Force }
    $journalPath = Get-LabHyperVPersistentDataJournalPath -OperationDirectory $OperationDirectory
    $journal = if (Test-Path -LiteralPath $journalPath -PathType Leaf) {
        Get-Content -LiteralPath $journalPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 40
    }
    else {
        [PSCustomObject]@{
            ContractVersion='SqlServerLab.HyperVPersistentDataJournal/1.0'; OperationId=[string]$Plan.OperationId
            Action=[string]$Plan.Action; Status='PREPARED'; Source=$Plan.Source; Target=$Plan.Target
            SourceSha256=$null; TargetDiskIdentifier=$null; TargetOwnedByOperation=$false
            Recovery=[PSCustomObject]@{ Status='RETRY'; Attempts=0; ErrorCode=$null }; UpdatedAt=Get-LabTimestamp
        }
    }
    if ([string]$journal.OperationId -ne [string]$Plan.OperationId -or [string]$journal.Action -ne [string]$Plan.Action -or
        [string]$journal.Source.PersistentStorageId -ne [string]$Plan.Source.PersistentStorageId) { throw 'HYPERV_PERSISTENT_DATA_JOURNAL_IDENTITY_MISMATCH' }
    if ([string]$journal.Status -eq 'COMPLETED') { return $journal }
    $journal.Recovery.Attempts = [int]$journal.Recovery.Attempts + 1

    try {
        $inspection = Get-LabHyperVPersistentDataRuntimeInspection -Path ([string]$Plan.Source.Path) -TargetVMName ([string]$Plan.Target.VMName)
        if ([string]$inspection.Status -ne 'AVAILABLE' -or [string]$inspection.DiskIdentifier -ne [string]$Plan.Source.DiskIdentifier -or
            [string]$inspection.Target.VMId -ne [string]$Plan.Target.VMId -or [string]$inspection.Target.State -ne 'Off' -or
            [int]$inspection.Target.CheckpointCount -gt 0 -or [bool]$inspection.Target.AutomaticCheckpointsEnabled -or
            @($inspection.CheckpointReferences).Count -gt 0) {
            throw 'HYPERV_PERSISTENT_DATA_EXECUTION_REVALIDATION_FAILED'
        }
        switch ([string]$Plan.Action) {
            'CLONE' {
                if (@($inspection.Attachments).Count -gt 0) { throw 'HYPERV_PERSISTENT_DATA_CLONE_PRECONDITION_FAILED' }
                if (Test-Path -LiteralPath ([string]$Plan.Target.Path)) {
                    if (-not [bool]$journal.TargetOwnedByOperation) { throw 'HYPERV_PERSISTENT_DATA_CLONE_TARGET_OWNERSHIP_UNVERIFIED' }
                    $targetAttachments = @(
                        Get-VM -ErrorAction SilentlyContinue | Get-VMHardDiskDrive -ErrorAction SilentlyContinue | Where-Object {
                            $_.Path -and [string]::Equals([IO.Path]::GetFullPath([string]$_.Path), [IO.Path]::GetFullPath([string]$Plan.Target.Path), [StringComparison]::OrdinalIgnoreCase)
                        }
                    )
                    if ($targetAttachments.Count -gt 0) { throw 'HYPERV_PERSISTENT_DATA_CLONE_TARGET_ATTACHED' }
                    Remove-Item -LiteralPath ([string]$Plan.Target.Path) -Force -ErrorAction Stop
                }
                $journal.SourceSha256 = (Get-FileHash -LiteralPath ([string]$Plan.Source.Path) -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
                $targetParent = Split-Path -Parent ([string]$Plan.Target.Path)
                if (-not (Test-Path -LiteralPath $targetParent -PathType Container)) { $null = New-Item -ItemType Directory -Path $targetParent -Force }
                $targetDrive = [IO.DriveInfo]::new([IO.Path]::GetPathRoot([string]$Plan.Target.Path))
                if ([long]$targetDrive.AvailableFreeSpace -lt ([long]$inspection.FileSizeBytes + 64MB)) { throw 'HYPERV_PERSISTENT_DATA_CLONE_CAPACITY_INSUFFICIENT' }
                $journal.TargetOwnedByOperation=$true; $journal.Status='TARGET_CREATING'
                $null = Write-LabHyperVPersistentDataJournal -Journal $journal -Path $journalPath
                $null = Convert-VHD -Path ([string]$Plan.Source.Path) -DestinationPath ([string]$Plan.Target.Path) -VHDType Dynamic -ErrorAction Stop
                $null = Set-VHD -Path ([string]$Plan.Target.Path) -ResetDiskIdentifier -Force -ErrorAction Stop
                $sourceAfter = (Get-FileHash -LiteralPath ([string]$Plan.Source.Path) -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
                $targetVhd = Get-VHD -Path ([string]$Plan.Target.Path) -ErrorAction Stop
                if ($sourceAfter -ne [string]$journal.SourceSha256 -or [long]$targetVhd.Size -ne [long]$inspection.SizeBytes -or
                    [string]$targetVhd.DiskIdentifier -eq [string]$Plan.Source.DiskIdentifier) { throw 'HYPERV_PERSISTENT_DATA_CLONE_POSTCONDITION_FAILED' }
                $journal.TargetDiskIdentifier = ([string]$targetVhd.DiskIdentifier).ToUpperInvariant()
                $journal.Status = 'TARGET_VERIFIED'
            }
            'REATTACH' {
                $attachments=@($inspection.Attachments)
                if ($attachments.Count -eq 0) {
                    $null = Add-VMHardDiskDrive -VMName ([string]$Plan.Target.VMName) -ControllerType SCSI -ControllerNumber 0 -ControllerLocation ([int]$Plan.Target.ControllerLocation) -Path ([string]$Plan.Source.Path) -ErrorAction Stop
                }
                elseif ($attachments.Count -ne 1 -or [string]$attachments[0].VMId -ne [string]$Plan.Target.VMId -or
                    [int]$attachments[0].ControllerNumber -ne [int]$Plan.Target.ControllerNumber -or [int]$attachments[0].ControllerLocation -ne [int]$Plan.Target.ControllerLocation) {
                    throw 'HYPERV_PERSISTENT_DATA_ATTACH_PRECONDITION_FAILED'
                }
                $null = Set-LabHyperVPersistentDataVMIdentity -Plan $Plan -Action ATTACH
                $post = Get-LabHyperVPersistentDataRuntimeInspection -Path ([string]$Plan.Source.Path) -TargetVMName ([string]$Plan.Target.VMName)
                if (@($post.Attachments).Count -ne 1 -or [string]$post.Attachments[0].VMId -ne [string]$Plan.Target.VMId) { throw 'HYPERV_PERSISTENT_DATA_ATTACH_POSTCONDITION_FAILED' }
                $journal.Status = 'ATTACHED_FILES_OFFLINE'
            }
            'RELEASE' {
                $drive = @($inspection.Target.Attachments | Where-Object { $_.Path -and [string]::Equals([IO.Path]::GetFullPath([string]$_.Path), [IO.Path]::GetFullPath([string]$Plan.Source.Path), [StringComparison]::OrdinalIgnoreCase) })
                if ($drive.Count -gt 1) { throw 'HYPERV_PERSISTENT_DATA_RELEASE_PRECONDITION_FAILED' }
                if ($drive.Count -eq 1) {
                    Get-VMHardDiskDrive -VMName ([string]$Plan.Target.VMName) -ControllerType SCSI -ControllerNumber ([int]$drive[0].ControllerNumber) -ControllerLocation ([int]$drive[0].ControllerLocation) -ErrorAction Stop | Remove-VMHardDiskDrive -ErrorAction Stop
                }
                $null = Set-LabHyperVPersistentDataVMIdentity -Plan $Plan -Action RELEASE
                $post = Get-LabHyperVPersistentDataRuntimeInspection -Path ([string]$Plan.Source.Path) -TargetVMName ([string]$Plan.Target.VMName)
                if (@($post.Attachments).Count -gt 0) { throw 'HYPERV_PERSISTENT_DATA_RELEASE_POSTCONDITION_FAILED' }
                $journal.Status = 'CLEAN_DETACHED'
            }
        }
        $journal.Recovery.Status='NOT_REQUIRED'; $journal.Recovery.ErrorCode=$null; $journal.Status='COMPLETED'
        return (Write-LabHyperVPersistentDataJournal -Journal $journal -Path $journalPath)
    }
    catch {
        $code = if ($_.Exception.Message -cmatch '[A-Z][A-Z0-9_]{5,127}') { [string]$Matches[0] } else { 'HYPERV_PERSISTENT_DATA_EXECUTION_FAILED' }
        $journal.Status='RECOVERY_REQUIRED'; $journal.Recovery.Status='RETRY'; $journal.Recovery.ErrorCode=$code
        $null = Write-LabHyperVPersistentDataJournal -Journal $journal -Path $journalPath
        throw "HYPERV_PERSISTENT_DATA_RECOVERY_REQUIRED: $code"
    }
}
