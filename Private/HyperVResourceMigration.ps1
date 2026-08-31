<#
.SYNOPSIS
    Journalisierte Migration vorhandener Hyper-V-Run-Ressourcen aus einem
    Legacy-State-Root in eine registrierte Lab_Data-Ressourcenbindung.
.DESCRIPTION
    Der Plan ist read-only. Die Ausfuehrung stoppt die verwalteten VMs,
    kopiert und verifiziert ausschliesslich run-lokale VHDX, bindet VM-State
    und Disks um, aktualisiert Notes und lokalen State atomar, prueft Gast- und
    optionale SQL-Readiness ueber einen vollstaendigen Restart und entfernt
    die Quelle erst danach. Selectorgebundene externe SQL-Lanes bleiben
    unveraendert.
#>

function Get-LabHyperVResourceMigrationPaths {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunDirectory)

    $root = [IO.Path]::GetFullPath($RunDirectory)
    return [PSCustomObject]@{
        Plan = Join-Path $root 'hyperv-resource-migration.local.plan.json'
        Journal = Join-Path $root 'hyperv-resource-migration.local.journal.json'
        Binding = Join-Path $root 'hyperv-resource-binding.local.json'
        LegacyRoot = Join-Path (Join-Path $root 'resources') 'hyperv'
    }
}

function Get-LabHyperVResourceMigrationLifecycleGuard {
    <#
    .SYNOPSIS
        Prueft read-only, ob Lifecycle- und Repair-Mutationen mit dem Run-Migrationszustand vereinbar sind.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [string]$StateRoot
    )

    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
    $run = Get-LabRunState -RunId $RunId -StateRoot $StateRoot
    if ([string]$run.metadata.workflowKind -ne 'hyperv-lab') {
        return [PSCustomObject]@{
            Contract=[PSCustomObject]@{ Name='SqlServerLab.HyperVResourceMigrationLifecycleGuard'; Version='1.0' }
            Applies=$false; Allowed=$true; Status='NOT_APPLICABLE'; JournalStatus='ABSENT'
            BindingStatus='NOT_APPLICABLE'; ReasonCode=$null; Reason=$null
        }
    }

    $runDirectory = Join-Path (Join-Path $StateRoot 'runs') $RunId
    $paths = Get-LabHyperVResourceMigrationPaths -RunDirectory $runDirectory
    $binding = $null
    $bindingStatus = 'ABSENT_LEGACY'
    $bindingPath = Join-Path $runDirectory 'hyperv-resource-binding.local.json'
    if (Test-Path -LiteralPath $bindingPath -PathType Leaf) {
        try {
            $bindingDocument = Get-Content -LiteralPath $bindingPath -Raw -Encoding utf8 |
                ConvertFrom-Json -Depth 12 -ErrorAction Stop
            $binding = Read-LabHyperVResourceBinding -StateDirectory $runDirectory `
                -DataRoot ([string]$bindingDocument.LabDataRoot)
            if ([string]$binding.ResourceClass -ne 'Run' -or
                -not [string]::Equals([string]$binding.ResourceId, $RunId, [StringComparison]::OrdinalIgnoreCase)) {
                throw 'HYPERV_RESOURCE_MIGRATION_BINDING_IDENTITY_MISMATCH'
            }
            $bindingStatus = 'VALID'
        }
        catch {
            return [PSCustomObject]@{
                Contract=[PSCustomObject]@{ Name='SqlServerLab.HyperVResourceMigrationLifecycleGuard'; Version='1.0' }
                Applies=$true; Allowed=$false; Status='BLOCKED'; JournalStatus='UNKNOWN'
                BindingStatus='INVALID'; ReasonCode='HYPERV_RESOURCE_MIGRATION_BINDING_INVALID'
                Reason=$_.Exception.Message
            }
        }
    }

    if ($binding) {
        $storageMigrationGuard = Get-LabStorageMigrationLifecycleGuard `
            -DataRoot ([string]$binding.LabDataRoot) -LocationId ([string]$binding.LocationId)
        if (-not $storageMigrationGuard.Allowed) {
            return [PSCustomObject]@{
                Contract=[PSCustomObject]@{ Name='SqlServerLab.HyperVResourceMigrationLifecycleGuard'; Version='1.0' }
                Applies=$true; Allowed=$false; Status='BLOCKED'; JournalStatus='ABSENT'
                BindingStatus=$bindingStatus; ReasonCode='HYPERV_STORAGE_MIGRATION_LIFECYCLE_BLOCKED'
                Reason=[string]$storageMigrationGuard.ReasonCode
            }
        }
    }

    if (-not (Test-Path -LiteralPath $paths.Journal -PathType Leaf)) {
        return [PSCustomObject]@{
            Contract=[PSCustomObject]@{ Name='SqlServerLab.HyperVResourceMigrationLifecycleGuard'; Version='1.0' }
            Applies=$true; Allowed=$true; Status='ALLOWED'; JournalStatus='ABSENT'
            BindingStatus=$bindingStatus; ReasonCode=$null; Reason=$null
        }
    }

    try {
        $journal = Get-Content -LiteralPath $paths.Journal -Raw -Encoding utf8 |
            ConvertFrom-Json -Depth 50 -ErrorAction Stop
    }
    catch {
        return [PSCustomObject]@{
            Contract=[PSCustomObject]@{ Name='SqlServerLab.HyperVResourceMigrationLifecycleGuard'; Version='1.0' }
            Applies=$true; Allowed=$false; Status='BLOCKED'; JournalStatus='INVALID'
            BindingStatus=$bindingStatus; ReasonCode='HYPERV_RESOURCE_MIGRATION_JOURNAL_INVALID'
            Reason=$_.Exception.Message
        }
    }

    $journalStatus = [string]$journal.Status
    if ([string]$journal.ContractVersion -ne 'SqlServerLab.HyperVResourceMigrationJournal/1.0' -or
        -not [string]::Equals([string]$journal.RunId, $RunId, [StringComparison]::OrdinalIgnoreCase)) {
        return [PSCustomObject]@{
            Contract=[PSCustomObject]@{ Name='SqlServerLab.HyperVResourceMigrationLifecycleGuard'; Version='1.0' }
            Applies=$true; Allowed=$false; Status='BLOCKED'; JournalStatus='INVALID'
            BindingStatus=$bindingStatus; ReasonCode='HYPERV_RESOURCE_MIGRATION_JOURNAL_IDENTITY_INVALID'
            Reason='Vertragsversion oder RunId des Migrationsjournals stimmt nicht.'
        }
    }
    if ($journalStatus -ne 'COMPLETED') {
        return [PSCustomObject]@{
            Contract=[PSCustomObject]@{ Name='SqlServerLab.HyperVResourceMigrationLifecycleGuard'; Version='1.0' }
            Applies=$true; Allowed=$false; Status='BLOCKED'; JournalStatus=$journalStatus
            BindingStatus=$bindingStatus; ReasonCode='HYPERV_RESOURCE_MIGRATION_LIFECYCLE_BLOCKED'
            Reason="Migrationsjournal ist nicht terminal abgeschlossen: $journalStatus"
        }
    }
    if (-not $binding -or $bindingStatus -ne 'VALID' -or $journal.BindingCommitted -ne $true) {
        return [PSCustomObject]@{
            Contract=[PSCustomObject]@{ Name='SqlServerLab.HyperVResourceMigrationLifecycleGuard'; Version='1.0' }
            Applies=$true; Allowed=$false; Status='BLOCKED'; JournalStatus=$journalStatus
            BindingStatus=$bindingStatus; ReasonCode='HYPERV_RESOURCE_MIGRATION_COMMIT_INVALID'
            Reason='Abgeschlossenes Journal besitzt kein konsistentes, committed Run-Binding.'
        }
    }
    return [PSCustomObject]@{
        Contract=[PSCustomObject]@{ Name='SqlServerLab.HyperVResourceMigrationLifecycleGuard'; Version='1.0' }
        Applies=$true; Allowed=$true; Status='ALLOWED'; JournalStatus=$journalStatus
        BindingStatus=$bindingStatus; ReasonCode=$null; Reason=$null
    }
}

function Assert-LabHyperVResourceMigrationLifecycleAllowed {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$Operation,
        [string]$StateRoot
    )

    $guard = Get-LabHyperVResourceMigrationLifecycleGuard -RunId $RunId -StateRoot $StateRoot
    if (-not $guard.Allowed) {
        throw "$([string]$guard.ReasonCode): operation=$Operation; journal=$([string]$guard.JournalStatus); $([string]$guard.Reason)"
    }
    return $guard
}

function Get-LabHyperVLegacyRunInventory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [string]$StateRoot,
        [string]$LocationId,
        [string]$DataRoot
    )

    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
    $run = Get-LabRunState -RunId $RunId -StateRoot $StateRoot
    $runDirectory = Join-Path (Join-Path $StateRoot 'runs') $RunId
    $paths = Get-LabHyperVResourceMigrationPaths -RunDirectory $runDirectory
    $targetBinding = Resolve-LabHyperVResourceBinding -ResourceId $RunId -ResourceClass Run `
        -LocationId $LocationId -DataRoot $DataRoot
    $storageConfiguration = Get-LabStorageConfiguration -DataRoot $DataRoot
    $existingBinding = Read-LabHyperVResourceBinding -StateDirectory $runDirectory -DataRoot $DataRoot
    $blockers = [Collections.Generic.List[string]]::new()
    if ($existingBinding) { $blockers.Add('HYPERV_RESOURCE_MIGRATION_ALREADY_BOUND') }

    $connectionPath = Join-Path $runDirectory 'connection-info.json'
    if (-not (Test-Path -LiteralPath $connectionPath -PathType Leaf)) {
        throw 'HYPERV_RESOURCE_MIGRATION_CONNECTION_INFO_REQUIRED'
    }
    $connection = Get-Content -LiteralPath $connectionPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 30
    $hyperVInstances = @($connection.instances | Where-Object { [string]$_.provider -eq 'hyperv' })
    if ($hyperVInstances.Count -eq 0) { throw 'HYPERV_RESOURCE_MIGRATION_HYPERV_INSTANCE_REQUIRED' }

    $seenTargets = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $vmInventory = @()
    foreach ($instance in $hyperVInstances) {
        $vmName = [string]$instance.vmName
        if (-not $vmName) { $blockers.Add("HYPERV_RESOURCE_MIGRATION_VM_NAME_MISSING: $([string]$instance.id)"); continue }
        $managed = Get-HyperVManagedVM -VMName $vmName -ExpectedRunId $RunId `
            -ExpectedScopeId ([string]$run.scopeId)
        if (-not $managed) { $blockers.Add("HYPERV_RESOURCE_MIGRATION_VM_MISSING: $vmName"); continue }
        $snapshots = @(Get-VMSnapshot -VM $managed.VM -ErrorAction Stop)
        if ($snapshots.Count -gt 0) { $blockers.Add("HYPERV_RESOURCE_MIGRATION_CHECKPOINTS_PRESENT: $vmName") }

        $configurationPaths = @(
            [PSCustomObject]@{ Kind='Configuration'; Path=[string]$managed.VM.Path }
            [PSCustomObject]@{ Kind='SmartPaging'; Path=[string]$managed.VM.SmartPagingFilePath }
            [PSCustomObject]@{ Kind='Snapshot'; Path=[string]$managed.VM.SnapshotFileLocation }
        )
        foreach ($entry in $configurationPaths) {
            if (-not $entry.Path -or -not (Test-LabPathWithinRoot -Root $paths.LegacyRoot -Path (Join-Path $entry.Path '.path-check')).Valid) {
                $blockers.Add("HYPERV_RESOURCE_MIGRATION_CONFIG_OUTSIDE_LEGACY_ROOT: $vmName/$($entry.Kind)")
            }
        }

        $legacyDisks = @(); $externalDisks = @()
        foreach ($drive in @(Get-VMHardDiskDrive -VM $managed.VM -ErrorAction Stop)) {
            if (-not $drive.Path) { continue }
            $sourcePath = [IO.Path]::GetFullPath([string]$drive.Path)
            $insideLegacy = (Test-LabPathWithinRoot -Root $paths.LegacyRoot -Path $sourcePath).Valid
            if (-not $insideLegacy) {
                $identityDrive = @($managed.Identity.additionalDrives | Where-Object {
                    $_.path -and [string]::Equals([IO.Path]::GetFullPath([string]$_.path), $sourcePath, [StringComparison]::OrdinalIgnoreCase)
                })
                $location = if ($identityDrive.Count -eq 1 -and $identityDrive[0].locationId) {
                    @($storageConfiguration.LabDataLocations | Where-Object {
                        [string]$_.LocationId -eq [string]$identityDrive[0].locationId
                    })
                } else { @() }
                $selectorBound = $identityDrive.Count -eq 1 -and [string]$identityDrive[0].selector -and
                    $location.Count -eq 1 -and [string]$identityDrive[0].selector -in @($location[0].Selectors) -and
                    (Test-LabPathWithinRoot -Root ([string]$location[0].LabDataRoot) -Path $sourcePath).Valid
                if (-not $selectorBound) {
                    $blockers.Add("HYPERV_RESOURCE_MIGRATION_EXTERNAL_DISK_NOT_SELECTOR_BOUND: $sourcePath")
                }
                $externalDisks += [PSCustomObject]@{
                    Path=$sourcePath; ControllerType=[string]$drive.ControllerType
                    ControllerNumber=[int]$drive.ControllerNumber; ControllerLocation=[int]$drive.ControllerLocation
                    LocationId=if ($identityDrive.Count -eq 1) { [string]$identityDrive[0].locationId } else { $null }
                    Selector=if ($identityDrive.Count -eq 1) { [string]$identityDrive[0].selector } else { $null }
                }
                continue
            }
            if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
                $blockers.Add("HYPERV_RESOURCE_MIGRATION_SOURCE_DISK_MISSING: $sourcePath")
                continue
            }
            $destinationPath = Assert-LabHyperVBoundPath -Binding $targetBinding `
                -Path (Join-Path ([string]$targetBinding.HyperVResourceRoot) (Split-Path -Leaf $sourcePath)) -DataRoot $DataRoot
            if (-not $seenTargets.Add($destinationPath)) {
                $blockers.Add("HYPERV_RESOURCE_MIGRATION_TARGET_COLLISION: $destinationPath")
            }
            if (Test-Path -LiteralPath $destinationPath) {
                $blockers.Add("HYPERV_RESOURCE_MIGRATION_TARGET_EXISTS: $destinationPath")
            }
            $vhd = Get-VHD -Path $sourcePath -ErrorAction Stop
            $parentPath = if ($vhd.ParentPath) { [IO.Path]::GetFullPath([string]$vhd.ParentPath) } else { $null }
            $parentLocation = if ($parentPath) {
                @($storageConfiguration.LabDataLocations | Where-Object {
                    (Test-LabPathWithinRoot -Root ([string]$_.LabDataRoot) -Path $parentPath).Valid
                })
            } else { @() }
            $parentMigration = $null
            if ($parentPath -and (Test-Path -LiteralPath $parentPath -PathType Leaf) -and $parentLocation.Count -ne 1) {
                try { $parentMigration = Resolve-LabHyperVMigratedParentImage -ParentPath $parentPath -StateRoot $StateRoot -DataRoot $DataRoot }
                catch { $blockers.Add($_.Exception.Message) }
            }
            if ($parentPath -and (-not (Test-Path -LiteralPath $parentPath -PathType Leaf) -or ($parentLocation.Count -ne 1 -and -not $parentMigration))) {
                $blockers.Add("HYPERV_RESOURCE_MIGRATION_PARENT_IMAGE_NOT_REGISTERED: $parentPath")
            }
            $file = Get-Item -LiteralPath $sourcePath -Force -ErrorAction Stop
            $legacyDisks += [PSCustomObject]@{
                SourcePath=$sourcePath; DestinationPath=$destinationPath; Length=[long]$file.Length
                Sha256=(Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash.ToLowerInvariant()
                VhdType=[string]$vhd.VhdType; Size=[long]$vhd.Size; FileSize=[long]$vhd.FileSize
                DiskIdentifier=[string]$vhd.DiskIdentifier; ParentPath=$parentPath
                ParentLocationId=if ($parentLocation.Count -eq 1) { [string]$parentLocation[0].LocationId } else { $null }
                TargetParentPath=if ($parentMigration) { [string]$parentMigration.DestinationParentPath } else { $parentPath }
                ParentMigrationArtifactId=if ($parentMigration) { [string]$parentMigration.ArtifactId } else { $null }
                ParentMigrationPlanPath=if ($parentMigration) { [string]$parentMigration.PlanPath } else { $null }
                ControllerType=[string]$drive.ControllerType; ControllerNumber=[int]$drive.ControllerNumber
                ControllerLocation=[int]$drive.ControllerLocation
            }
        }
        if ($legacyDisks.Count -eq 0) { $blockers.Add("HYPERV_RESOURCE_MIGRATION_NO_LEGACY_DISKS: $vmName") }
        $vmInventory += [PSCustomObject]@{
            VMName=$vmName; InstanceId=[string]$instance.id; InitialState=[string]$managed.VM.State
            ConfigurationPaths=$configurationPaths; LegacyDisks=$legacyDisks; ExternalDisks=$externalDisks
            CheckpointCount=$snapshots.Count
        }
    }

    $legacyFiles = if (Test-Path -LiteralPath $paths.LegacyRoot -PathType Container) {
        @(Get-ChildItem -LiteralPath $paths.LegacyRoot -File -Recurse -Force -ErrorAction Stop | Where-Object {
            # VMMS hält diese Konfigurationsartefakte auch bei ausgeschalteten VMs
            # exklusiv geöffnet. Sie werden durch Move-VMStorage verschoben und
            # anschließend über die VM-Pfadpostconditions verifiziert; ein
            # direkter Dateihash ist weder zuverlässig noch erforderlich.
            [string]$_.Extension -notin @('.vmcx', '.vmrs', '.vmgs')
        })
    } else { @() }
    $legacyFileInventory = @($legacyFiles | ForEach-Object {
        [PSCustomObject]@{
            RelativePath=[IO.Path]::GetRelativePath($paths.LegacyRoot, $_.FullName)
            Length=[long]$_.Length
            Sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    })
    $totalBytes = [long](($legacyFileInventory | Measure-Object -Property Length -Sum).Sum)
    $requiredBytes = Get-LabHyperVMigrationRequiredBytes -ContentBytes $totalBytes
    if ([long]$targetBinding.ObservedFreeBytes -lt $requiredBytes) {
        $blockers.Add("HYPERV_RESOURCE_MIGRATION_INSUFFICIENT_SPACE: required=$requiredBytes; available=$([long]$targetBinding.ObservedFreeBytes)")
    }
    return [PSCustomObject]@{
        RunId=$RunId; ScopeId=[string]$run.scopeId; RunDirectory=$runDirectory
        LegacyRoot=[IO.Path]::GetFullPath($paths.LegacyRoot); TargetBinding=$targetBinding
        VMs=$vmInventory; Files=$legacyFileInventory; FileCount=$legacyFiles.Count; TotalBytes=$totalBytes; RequiredBytes=$requiredBytes
        AvailableBytes=[long]$targetBinding.ObservedFreeBytes; Blockers=@($blockers)
    }
}

function New-LabHyperVResourceMigrationPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [string]$StateRoot,
        [string]$LocationId,
        [string]$DataRoot
    )

    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
    $inventory = Get-LabHyperVLegacyRunInventory -RunId $RunId -StateRoot $StateRoot `
        -LocationId $LocationId -DataRoot $DataRoot
    $paths = Get-LabHyperVResourceMigrationPaths -RunDirectory $inventory.RunDirectory
    $plan = [PSCustomObject]@{
        ContractVersion='SqlServerLab.HyperVResourceMigrationPlan/1.0'
        PlanId=[Guid]::NewGuid().ToString('D'); CreatedAt=Get-LabTimestamp
        RunId=$RunId; ScopeId=[string]$inventory.ScopeId
        Status=if (@($inventory.Blockers).Count -eq 0) { 'READY' } else { 'BLOCKED' }
        Source=[PSCustomObject]@{ Kind='LEGACY_STATE_ROOT'; Root=[string]$inventory.LegacyRoot }
        Target=[PSCustomObject]@{
            ResourceKey=[string]$inventory.TargetBinding.ResourceKey
            ControllerId=[string]$inventory.TargetBinding.ControllerId
            LocationId=[string]$inventory.TargetBinding.LocationId
            VolumeId=[string]$inventory.TargetBinding.VolumeId
            LabDataRoot=[string]$inventory.TargetBinding.LabDataRoot
            ResourceRoot=[string]$inventory.TargetBinding.HyperVResourceRoot
        }
        Inventory=[PSCustomObject]@{
            FileCount=[int]$inventory.FileCount; TotalBytes=[long]$inventory.TotalBytes
            RequiredBytes=[long]$inventory.RequiredBytes; AvailableBytes=[long]$inventory.AvailableBytes
            VMs=@($inventory.VMs); Files=@($inventory.Files)
        }
        RequiredActions=@('stop','copy-and-verify','parent-reparent','rebind','state-commit','guest-readiness','restart','source-cleanup','image-cleanup-resume')
        Blockers=@($inventory.Blockers); ExecutionImplemented=$true
    }
    Write-LabArtifactJsonAtomic -Path $paths.Plan -InputObject $plan
    return [PSCustomObject]@{ Path=$paths.Plan; Plan=$plan }
}

function Write-LabHyperVResourceMigrationJournal {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Journal)

    $Journal.UpdatedAt = Get-LabTimestamp
    Write-LabArtifactJsonAtomic -Path $Path -InputObject $Journal
}

function Update-LabHyperVResourceMigrationReferences {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunDirectory,
        [Parameter(Mandatory)][hashtable]$PathMap
    )

    $changed = [Collections.Generic.List[string]]::new()
    foreach ($fileName in @('run-state.json','connection-info.json','cleanup-plan.json')) {
        $path = Join-Path $RunDirectory $fileName
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        $content = Get-Content -LiteralPath $path -Raw -Encoding utf8
        $updated = $content
        foreach ($source in $PathMap.Keys) {
            $target = [string]$PathMap[$source]
            $updated = $updated.Replace(([string]$source).Replace('\','\\'), $target.Replace('\','\\'), [StringComparison]::OrdinalIgnoreCase)
            $updated = $updated.Replace([string]$source, $target, [StringComparison]::OrdinalIgnoreCase)
        }
        if ($updated -ne $content) {
            $document = $updated | ConvertFrom-Json -Depth 40 -ErrorAction Stop
            Write-LabArtifactJsonAtomic -Path $path -InputObject $document
            $changed.Add($fileName)
        }
    }
    return @($changed)
}

function Invoke-LabHyperVResourceMigration {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='High')]
    param(
        [Parameter(Mandatory)][string]$PlanPath,
        [PSCredential]$Credential,
        [SecureString]$SaPassword,
        [ValidateRange(30, 3600)][int]$ReadinessTimeoutSeconds = 600,
        [string]$DataRoot
    )

    $resolvedPlanPath = (Resolve-Path -LiteralPath $PlanPath -ErrorAction Stop).Path
    $plan = Get-Content -LiteralPath $resolvedPlanPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 40
    if ([string]$plan.ContractVersion -ne 'SqlServerLab.HyperVResourceMigrationPlan/1.0' -or -not [bool]$plan.ExecutionImplemented) {
        throw 'HYPERV_RESOURCE_MIGRATION_PLAN_NOT_EXECUTABLE'
    }
    if ([string]$plan.Status -ne 'READY' -or @($plan.Blockers).Count -gt 0) {
        throw "HYPERV_RESOURCE_MIGRATION_PLAN_BLOCKED: $(@($plan.Blockers) -join ', ')"
    }
    $runDirectory = Split-Path -Parent $resolvedPlanPath
    $paths = Get-LabHyperVResourceMigrationPaths -RunDirectory $runDirectory
    if (-not [string]::Equals((Split-Path -Leaf $runDirectory), [string]$plan.RunId, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'HYPERV_RESOURCE_MIGRATION_RUN_DIRECTORY_MISMATCH'
    }
    if (-not [string]::Equals($paths.Plan, $resolvedPlanPath, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'HYPERV_RESOURCE_MIGRATION_PLAN_LOCATION_INVALID'
    }
    if (-not [string]::Equals([IO.Path]::GetFullPath([string]$plan.Source.Root), $paths.LegacyRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'HYPERV_RESOURCE_MIGRATION_SOURCE_ROOT_CHANGED'
    }
    $mutexName = 'SqlServerLab.HyperVMigration.' + [string]$plan.RunId
    $mutex = [Threading.Mutex]::new($false, $mutexName)
    $mutexAcquired = $false
    try {
        try { $mutexAcquired = $mutex.WaitOne([TimeSpan]::FromSeconds(30)) }
        catch [Threading.AbandonedMutexException] { $mutexAcquired = $true }
        if (-not $mutexAcquired) { throw 'HYPERV_RESOURCE_MIGRATION_LOCK_TIMEOUT' }
    $journalWasPresent = Test-Path -LiteralPath $paths.Journal -PathType Leaf
    $binding = Resolve-LabHyperVResourceBinding -ResourceId ([string]$plan.RunId) -ResourceClass Run `
        -LocationId ([string]$plan.Target.LocationId) -DataRoot $DataRoot
    foreach ($property in @('ResourceKey','ControllerId','LocationId','VolumeId','LabDataRoot')) {
        if (-not [string]::Equals([string]$binding.$property, [string]$plan.Target.$property, [StringComparison]::OrdinalIgnoreCase)) {
            throw "HYPERV_RESOURCE_MIGRATION_TARGET_CHANGED: $property"
        }
    }
    if (-not [string]::Equals([string]$binding.HyperVResourceRoot, [string]$plan.Target.ResourceRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'HYPERV_RESOURCE_MIGRATION_TARGET_CHANGED: ResourceRoot'
    }
    $stateRoot = Split-Path -Parent (Split-Path -Parent $runDirectory)
    foreach ($vmPlan in @($plan.Inventory.VMs)) {
        foreach ($disk in @($vmPlan.LegacyDisks)) {
            $source = [IO.Path]::GetFullPath([string]$disk.SourcePath)
            if (-not (Test-LabPathWithinRoot -Root $paths.LegacyRoot -Path $source).Valid) {
                throw "HYPERV_RESOURCE_MIGRATION_SOURCE_SCOPE_INVALID: $source"
            }
            $expectedDestination = Assert-LabHyperVBoundPath -Binding $binding `
                -Path (Join-Path ([string]$binding.HyperVResourceRoot) (Split-Path -Leaf $source)) -DataRoot $DataRoot
            if (-not [string]::Equals($expectedDestination, [IO.Path]::GetFullPath([string]$disk.DestinationPath), [StringComparison]::OrdinalIgnoreCase)) {
                throw "HYPERV_RESOURCE_MIGRATION_DESTINATION_CHANGED: $($disk.DestinationPath)"
            }
            $relativeSource = [IO.Path]::GetRelativePath($paths.LegacyRoot, $source)
            $fileReceipt = @($plan.Inventory.Files | Where-Object {
                [string]::Equals([string]$_.RelativePath, $relativeSource, [StringComparison]::OrdinalIgnoreCase)
            })
            if ($fileReceipt.Count -ne 1 -or [string]$fileReceipt[0].Sha256 -ne [string]$disk.Sha256) {
                throw "HYPERV_RESOURCE_MIGRATION_DISK_INVENTORY_MISMATCH: $source"
            }
            if ($disk.ParentMigrationPlanPath) {
                $parentMapping = Resolve-LabHyperVMigratedParentImage -ParentPath ([string]$disk.ParentPath) -StateRoot $stateRoot -DataRoot $DataRoot
                if (-not $parentMapping -or
                    -not [string]::Equals([IO.Path]::GetFullPath([string]$disk.TargetParentPath), [string]$parentMapping.DestinationParentPath, [StringComparison]::OrdinalIgnoreCase) -or
                    -not [string]::Equals([IO.Path]::GetFullPath([string]$disk.ParentMigrationPlanPath), [string]$parentMapping.PlanPath, [StringComparison]::OrdinalIgnoreCase) -or
                    [string]$disk.ParentMigrationArtifactId -ne [string]$parentMapping.ArtifactId) {
                    throw "HYPERV_RESOURCE_MIGRATION_PARENT_MAPPING_CHANGED: $source"
                }
            } elseif ($disk.TargetParentPath -and -not [string]::Equals([string]$disk.TargetParentPath, [string]$disk.ParentPath, [StringComparison]::OrdinalIgnoreCase)) {
                throw "HYPERV_RESOURCE_MIGRATION_PARENT_MAPPING_CHANGED: $source"
            }
        }
    }
    foreach ($file in @($plan.Inventory.Files)) {
        $source = [IO.Path]::GetFullPath((Join-Path $paths.LegacyRoot ([string]$file.RelativePath)))
        $boundary = Test-LabPathWithinRoot -Root $paths.LegacyRoot -Path $source
        if (-not $boundary.Valid) { throw "HYPERV_RESOURCE_MIGRATION_SOURCE_SCOPE_INVALID: $source" }
        if (Test-Path -LiteralPath $source -PathType Leaf) {
            $currentHash=(Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($currentHash -ne [string]$file.Sha256) { throw "HYPERV_RESOURCE_MIGRATION_SOURCE_CHANGED: $source" }
        }
        elseif (-not $journalWasPresent) { throw "HYPERV_RESOURCE_MIGRATION_SOURCE_FILE_MISSING: $source" }
    }

    if (-not $Credential) {
        $guestPassword = Get-LabSecret -Path $runDirectory -Name 'guest-administrator-password'
        if ($guestPassword) { $Credential = [PSCredential]::new('Administrator', $guestPassword) }
    }
    if (-not $Credential) { throw 'HYPERV_RESOURCE_MIGRATION_GUEST_CREDENTIAL_REQUIRED' }
    $requiresSqlReadiness = @($plan.Inventory.VMs | Where-Object {
        $managed = Get-HyperVManagedVM -VMName ([string]$_.VMName) -ExpectedRunId ([string]$plan.RunId) -ExpectedScopeId ([string]$plan.ScopeId)
        [string]$managed.Identity.sqlReadiness.status -eq 'SQL_READY_RUN'
    }).Count -gt 0
    if ($requiresSqlReadiness -and -not $SaPassword) {
        $SaPassword = Get-LabSecret -Path $runDirectory -Name 'generated-sql-sa-password'
        if (-not $SaPassword) { $SaPassword = Get-LabSecret -Path $runDirectory -Name 'sa-password' }
    }
    if ($requiresSqlReadiness -and -not $SaPassword) { throw 'HYPERV_RESOURCE_MIGRATION_SQL_CREDENTIAL_REQUIRED' }
    if (-not $PSCmdlet.ShouldProcess("Run $($plan.RunId)", "Hyper-V-Ressourcen nach $($plan.Target.ResourceRoot) migrieren")) { return $null }

    $planHash = (Get-FileHash -LiteralPath $resolvedPlanPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $journal = if (Test-Path -LiteralPath $paths.Journal -PathType Leaf) {
        Get-Content -LiteralPath $paths.Journal -Raw -Encoding utf8 | ConvertFrom-Json -Depth 50
    } else {
        [PSCustomObject]@{
            ContractVersion='SqlServerLab.HyperVResourceMigrationJournal/1.0'; PlanId=[string]$plan.PlanId
            PlanSha256=$planHash; RunId=[string]$plan.RunId; Status='PREPARING'; CurrentStep='validate'
            CreatedAt=Get-LabTimestamp; UpdatedAt=Get-LabTimestamp; CompletedAt=$null
            InitialVMStates=@(); CopiedDisks=@(); ParentReparents=@(); ReboundDisks=@(); UpdatedReferences=@()
            BindingCommitted=$false; ReadinessReceipts=@(); SourceCleanup=@(); ImageMigrationResumes=@(); Errors=@()
        }
    }
    if (-not $journal.PSObject.Properties['ParentReparents']) { $journal | Add-Member -NotePropertyName ParentReparents -NotePropertyValue @() }
    if (-not $journal.PSObject.Properties['ImageMigrationResumes']) { $journal | Add-Member -NotePropertyName ImageMigrationResumes -NotePropertyValue @() }
    if ([string]$journal.PlanSha256 -ne $planHash -or [string]$journal.PlanId -ne [string]$plan.PlanId) {
        throw 'HYPERV_RESOURCE_MIGRATION_PLAN_CHANGED'
    }
    if ([string]$journal.Status -eq 'COMPLETED') {
        return [PSCustomObject]@{ Status='COMPLETED'; RunId=[string]$plan.RunId; JournalPath=$paths.Journal; ResourceRoot=[string]$binding.HyperVResourceRoot }
    }

    try {
        if (@($journal.InitialVMStates).Count -eq 0) {
            $journal.InitialVMStates = @($plan.Inventory.VMs | ForEach-Object {
                $managed = Get-HyperVManagedVM -VMName ([string]$_.VMName) -ExpectedRunId ([string]$plan.RunId) -ExpectedScopeId ([string]$plan.ScopeId)
                [PSCustomObject]@{ VMName=[string]$_.VMName; State=[string]$managed.VM.State }
            })
        }
        $journal.Status='STOPPING'; $journal.CurrentStep='stop-vms'
        Write-LabHyperVResourceMigrationJournal -Path $paths.Journal -Journal $journal
        foreach ($vmState in @($journal.InitialVMStates)) {
            $managed = Get-HyperVManagedVM -VMName ([string]$vmState.VMName) -ExpectedRunId ([string]$plan.RunId) -ExpectedScopeId ([string]$plan.ScopeId)
            if ([string]$managed.VM.State -ne 'Off') {
                $null = Stop-HyperVInstance -VMName ([string]$vmState.VMName) -ExpectedRunId ([string]$plan.RunId) -ExpectedScopeId ([string]$plan.ScopeId)
            }
            if (@(Get-VMSnapshot -VM $managed.VM -ErrorAction Stop).Count -gt 0) { throw "HYPERV_RESOURCE_MIGRATION_CHECKPOINTS_PRESENT: $($vmState.VMName)" }
        }

        $journal.Status='COPYING'; $journal.CurrentStep='copy-and-verify-vhdx'
        Write-LabHyperVResourceMigrationJournal -Path $paths.Journal -Journal $journal
        $pathMap = @{}
        foreach ($vmPlan in @($plan.Inventory.VMs)) {
            foreach ($disk in @($vmPlan.LegacyDisks)) {
                $source = [IO.Path]::GetFullPath([string]$disk.SourcePath)
                $destination = Assert-LabHyperVBoundPath -Binding $binding -Path ([string]$disk.DestinationPath) -DataRoot $DataRoot
                $pathMap[$source] = $destination
                $destinationDirectory = Split-Path -Parent $destination
                if (-not (Test-Path -LiteralPath $destinationDirectory -PathType Container)) { New-Item -Path $destinationDirectory -ItemType Directory -Force | Out-Null }
                $sourceHash = if (Test-Path -LiteralPath $source -PathType Leaf) { (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant() } else { $null }
                $destinationHash = if (Test-Path -LiteralPath $destination -PathType Leaf) { (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant() } else { $null }
                $copyReceipt = @($journal.CopiedDisks | Where-Object { [string]::Equals([string]$_.DestinationPath, $destination, [StringComparison]::OrdinalIgnoreCase) }) | Select-Object -First 1
                $reparentReceipt = @($journal.ParentReparents | Where-Object { [string]::Equals([string]$_.DestinationPath, $destination, [StringComparison]::OrdinalIgnoreCase) }) | Select-Object -First 1
                $reboundReceipt = @($journal.ReboundDisks | Where-Object { [string]::Equals([string]$_.DestinationPath, $destination, [StringComparison]::OrdinalIgnoreCase) }) | Select-Object -First 1
                $targetParent = if ($disk.TargetParentPath) { [IO.Path]::GetFullPath([string]$disk.TargetParentPath) } else { [string]$disk.ParentPath }
                $reparentRequired = $disk.ParentPath -and -not [string]::Equals([string]$disk.ParentPath, $targetParent, [StringComparison]::OrdinalIgnoreCase)
                if ($sourceHash -and $sourceHash -ne [string]$disk.Sha256) { throw "HYPERV_RESOURCE_MIGRATION_SOURCE_CHANGED: $source" }
                if ($destinationHash -and -not $journalWasPresent) { throw "HYPERV_RESOURCE_MIGRATION_TARGET_CONFLICT: $destination" }
                if ($destinationHash -and $copyReceipt) {
                    $recordedTargetHash = if ($copyReceipt.TargetSha256) { [string]$copyReceipt.TargetSha256 } else { [string]$copyReceipt.Sha256 }
                    # Nach Rebind und Gast-Readiness ist ein geänderter Child-
                    # Hash erwartetes Laufzeitverhalten. Vor dem Rebind bleibt
                    # jede Abweichung ein harter Zielkonflikt.
                    if ($recordedTargetHash -and $destinationHash -ne $recordedTargetHash -and -not $reboundReceipt) {
                        throw "HYPERV_RESOURCE_MIGRATION_TARGET_CONFLICT: $destination"
                    }
                }
                if (-not $destinationHash) {
                    if (-not $sourceHash) { throw "HYPERV_RESOURCE_MIGRATION_SOURCE_DISK_MISSING: $source" }
                    $temporary = "$destination.sql-lab-migrating"
                    Copy-Item -LiteralPath $source -Destination $temporary -Force -ErrorAction Stop
                    $copiedHash = (Get-FileHash -LiteralPath $temporary -Algorithm SHA256).Hash.ToLowerInvariant()
                    if ($copiedHash -ne $sourceHash) { throw "HYPERV_RESOURCE_MIGRATION_HASH_MISMATCH: $source" }
                    Move-Item -LiteralPath $temporary -Destination $destination -Force -ErrorAction Stop
                    $destinationHash = $copiedHash
                }
                $targetVhd = Get-VHD -Path $destination -ErrorAction Stop
                if ([string]$targetVhd.VhdType -ne [string]$disk.VhdType -or [long]$targetVhd.Size -ne [long]$disk.Size -or
                    ([string]$disk.DiskIdentifier -and [string]$targetVhd.DiskIdentifier -ne [string]$disk.DiskIdentifier)) {
                    throw "HYPERV_RESOURCE_MIGRATION_VHD_INTEGRITY_MISMATCH: $destination"
                }
                if ($reparentRequired) {
                    $currentParent = if ($targetVhd.ParentPath) { [IO.Path]::GetFullPath([string]$targetVhd.ParentPath) } else { $null }
                    if ([string]::Equals($currentParent, $targetParent, [StringComparison]::OrdinalIgnoreCase) -and -not $reparentReceipt -and -not $copyReceipt) {
                        throw "HYPERV_RESOURCE_MIGRATION_TARGET_CONFLICT: $destination"
                    }
                    if (-not [string]::Equals($currentParent, $targetParent, [StringComparison]::OrdinalIgnoreCase)) {
                        if (-not [string]::Equals($currentParent, [string]$disk.ParentPath, [StringComparison]::OrdinalIgnoreCase) -or ($sourceHash -and $destinationHash -ne $sourceHash)) {
                            throw "HYPERV_RESOURCE_MIGRATION_VHD_PARENT_MISMATCH: $destination"
                        }
                        if (-not $reparentReceipt) {
                            $journal.ParentReparents += [PSCustomObject]@{
                                VMName=[string]$vmPlan.VMName; DestinationPath=$destination; State='PENDING'
                                SourceParentPath=[string]$disk.ParentPath; TargetParentPath=$targetParent; SourceSha256=[string]$disk.Sha256; TargetSha256=$null
                            }
                            Write-LabHyperVResourceMigrationJournal -Path $paths.Journal -Journal $journal
                        }
                        Set-VHD -Path $destination -ParentPath $targetParent -ErrorAction Stop
                        $targetVhd = Get-VHD -Path $destination -ErrorAction Stop
                    }
                    if (-not [string]::Equals([IO.Path]::GetFullPath([string]$targetVhd.ParentPath), $targetParent, [StringComparison]::OrdinalIgnoreCase)) {
                        throw "HYPERV_RESOURCE_MIGRATION_VHD_REPARENT_FAILED: $destination"
                    }
                    $destinationHash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant()
                    $reparentReceipt = @($journal.ParentReparents | Where-Object { [string]::Equals([string]$_.DestinationPath, $destination, [StringComparison]::OrdinalIgnoreCase) }) | Select-Object -First 1
                    if (-not $reparentReceipt) {
                        $journal.ParentReparents += [PSCustomObject]@{ VMName=[string]$vmPlan.VMName; DestinationPath=$destination; State='COMPLETED'; SourceParentPath=[string]$disk.ParentPath; TargetParentPath=$targetParent; SourceSha256=[string]$disk.Sha256; TargetSha256=$destinationHash }
                    } else {
                        $reparentReceipt.State='COMPLETED'; $reparentReceipt.TargetSha256=$destinationHash
                    }
                } elseif (-not [string]::Equals([string]$targetVhd.ParentPath, [string]$disk.ParentPath, [StringComparison]::OrdinalIgnoreCase) -or ($sourceHash -and $destinationHash -ne $sourceHash)) {
                    throw "HYPERV_RESOURCE_MIGRATION_VHD_INTEGRITY_MISMATCH: $destination"
                }
                if (-not $copyReceipt) {
                    $journal.CopiedDisks += [PSCustomObject]@{ VMName=[string]$vmPlan.VMName; SourcePath=$source; DestinationPath=$destination; SourceSha256=[string]$disk.Sha256; TargetSha256=$destinationHash; Sha256=$destinationHash }
                } else {
                    $copyReceipt | Add-Member -NotePropertyName SourceSha256 -NotePropertyValue ([string]$disk.Sha256) -Force
                    $copyReceipt | Add-Member -NotePropertyName TargetSha256 -NotePropertyValue $destinationHash -Force
                    $copyReceipt.Sha256=$destinationHash
                }
                Write-LabHyperVResourceMigrationJournal -Path $paths.Journal -Journal $journal
            }
        }

        $journal.Status='REBINDING'; $journal.CurrentStep='provider-rebind'
        Write-LabHyperVResourceMigrationJournal -Path $paths.Journal -Journal $journal
        foreach ($vmPlan in @($plan.Inventory.VMs)) {
            $managed = Get-HyperVManagedVM -VMName ([string]$vmPlan.VMName) -ExpectedRunId ([string]$plan.RunId) -ExpectedScopeId ([string]$plan.ScopeId)
            foreach ($disk in @($vmPlan.LegacyDisks)) {
                $source = [IO.Path]::GetFullPath([string]$disk.SourcePath); $destination = [IO.Path]::GetFullPath([string]$disk.DestinationPath)
                $drive = @(Get-VMHardDiskDrive -VM $managed.VM -ErrorAction Stop | Where-Object {
                    $_.Path -and ([IO.Path]::GetFullPath([string]$_.Path) -in @($source,$destination)) -and
                    [int]$_.ControllerNumber -eq [int]$disk.ControllerNumber -and [int]$_.ControllerLocation -eq [int]$disk.ControllerLocation
                })
                if ($drive.Count -ne 1) { throw "HYPERV_RESOURCE_MIGRATION_DISK_ATTACHMENT_AMBIGUOUS: $($vmPlan.VMName)/$($disk.ControllerLocation)" }
                if ([IO.Path]::GetFullPath([string]$drive[0].Path) -ne $destination) {
                    Set-VMHardDiskDrive -VMHardDiskDrive $drive[0] -Path $destination -ErrorAction Stop
                }
                if ($destination -notin @($journal.ReboundDisks | ForEach-Object DestinationPath)) {
                    $journal.ReboundDisks += [PSCustomObject]@{ VMName=[string]$vmPlan.VMName; SourcePath=$source; DestinationPath=$destination }
                }
            }
            $vm = Get-VM -Name ([string]$vmPlan.VMName) -ErrorAction Stop
            $configBound = @('Path','SmartPagingFilePath','SnapshotFileLocation') | ForEach-Object {
                [bool](Test-LabHyperVBoundPath -Binding $binding -Path (Join-Path ([string]$vm.$_) '.path-check') -DataRoot $DataRoot).Valid
            }
            if ($false -in $configBound) {
                Move-VMStorage -VM $vm -VirtualMachinePath ([string]$binding.HyperVResourceRoot) `
                    -SnapshotFilePath ([string]$binding.HyperVResourceRoot) -SmartPagingFilePath ([string]$binding.HyperVResourceRoot) -ErrorAction Stop
            }
            $managed = Get-HyperVManagedVM -VMName ([string]$vmPlan.VMName) -ExpectedRunId ([string]$plan.RunId) -ExpectedScopeId ([string]$plan.ScopeId)
            $identity = $managed.Identity
            foreach ($property in @('childVhdxPath','additionalVhdxPaths')) {
                if (-not $identity.PSObject.Properties[$property]) { continue }
                if ($property -eq 'childVhdxPath' -and $pathMap.ContainsKey([IO.Path]::GetFullPath([string]$identity.$property))) {
                    $identity.$property = [string]$pathMap[[IO.Path]::GetFullPath([string]$identity.$property)]
                }
                elseif ($property -eq 'additionalVhdxPaths') {
                    $identity.$property = @($identity.$property | ForEach-Object {
                        $value=[IO.Path]::GetFullPath([string]$_); if ($pathMap.ContainsKey($value)) { [string]$pathMap[$value] } else { $value }
                    })
                }
            }
            foreach ($driveIdentity in @($identity.additionalDrives)) {
                if ($driveIdentity.path) { $value=[IO.Path]::GetFullPath([string]$driveIdentity.path); if ($pathMap.ContainsKey($value)) { $driveIdentity.path=[string]$pathMap[$value] } }
            }
            $identity.contractVersion='0.7'
            $identity | Add-Member -NotePropertyName resourceMigration -NotePropertyValue ([PSCustomObject]@{
                status='BOUND'; locationId=[string]$binding.LocationId; resourceKey=[string]$binding.ResourceKey; migratedAt=Get-LabTimestamp
            }) -Force
            Set-VM -VM $managed.VM -Notes ($script:HyperVLabNotesPrefix + ($identity | ConvertTo-Json -Compress -Depth 15)) -ErrorAction Stop | Out-Null
            $null = Assert-HyperVVMResourceBinding -VMName ([string]$vmPlan.VMName) -ResourceBinding $binding -DataRoot $DataRoot
        }

        $journal.Status='COMMITTING'; $journal.CurrentStep='binding-and-state-commit'
        $journal.UpdatedReferences = @(Update-LabHyperVResourceMigrationReferences -RunDirectory $runDirectory -PathMap $pathMap)
        $null = Write-LabHyperVResourceBinding -Binding $binding -StateDirectory $runDirectory -DataRoot $DataRoot
        $journal.BindingCommitted=$true
        Write-LabHyperVResourceMigrationJournal -Path $paths.Journal -Journal $journal

        $journal.Status='VERIFYING'; $journal.CurrentStep='guest-readiness-and-restart'
        Write-LabHyperVResourceMigrationJournal -Path $paths.Journal -Journal $journal
        foreach ($vmState in @($journal.InitialVMStates)) {
            for ($cycle=1; $cycle -le 2; $cycle++) {
                $completedReceipt = @($journal.ReadinessReceipts | Where-Object {
                    [string]$_.VMName -eq [string]$vmState.VMName -and [int]$_.Cycle -eq $cycle -and [bool]$_.GuestReady
                }) | Select-Object -First 1
                if ($completedReceipt) { continue }
                $null = Start-HyperVInstance -VMName ([string]$vmState.VMName) -ExpectedRunId ([string]$plan.RunId) -ExpectedScopeId ([string]$plan.ScopeId)
                $ready = Wait-HyperVPowerShellDirect -VMName ([string]$vmState.VMName) -ExpectedRunId ([string]$plan.RunId) `
                    -ExpectedScopeId ([string]$plan.ScopeId) -Credential $Credential -TimeoutSeconds $ReadinessTimeoutSeconds
                if (-not $ready.Ready) { throw "HYPERV_RESOURCE_MIGRATION_GUEST_READINESS_FAILED: $($vmState.VMName)" }
                $sqlReceipt = $null
                $managed = Get-HyperVManagedVM -VMName ([string]$vmState.VMName) -ExpectedRunId ([string]$plan.RunId) -ExpectedScopeId ([string]$plan.ScopeId)
                if ([string]$managed.Identity.sqlReadiness.status -eq 'SQL_READY_RUN') {
                    $sqlReceipt = Wait-HyperVGuestSqlReady -VMName ([string]$vmState.VMName) -ExpectedRunId ([string]$plan.RunId) `
                        -ExpectedScopeId ([string]$plan.ScopeId) -Credential $Credential -SaPassword $SaPassword `
                        -ExpectedMajorVersion ([int]$managed.Identity.sqlReadiness.majorVersion) -TimeoutSeconds $ReadinessTimeoutSeconds
                }
                $journal.ReadinessReceipts += [PSCustomObject]@{
                    VMName=[string]$vmState.VMName; Cycle=$cycle; GuestReady=$true
                    SqlReady=[bool]($sqlReceipt -and [string]$sqlReceipt.Status -eq 'SQL_READY_RUN'); At=Get-LabTimestamp
                }
                Write-LabHyperVResourceMigrationJournal -Path $paths.Journal -Journal $journal
                if ($cycle -eq 1) { $null = Stop-HyperVInstance -VMName ([string]$vmState.VMName) -ExpectedRunId ([string]$plan.RunId) -ExpectedScopeId ([string]$plan.ScopeId) }
            }
            if ([string]$vmState.State -eq 'Off') {
                $null = Stop-HyperVInstance -VMName ([string]$vmState.VMName) -ExpectedRunId ([string]$plan.RunId) -ExpectedScopeId ([string]$plan.ScopeId)
            }
        }

        $journal.Status='CLEANING'; $journal.CurrentStep='remove-verified-source'
        Write-LabHyperVResourceMigrationJournal -Path $paths.Journal -Journal $journal
        foreach ($copy in @($journal.CopiedDisks)) {
            $source=[string]$copy.SourcePath; $destination=[string]$copy.DestinationPath
            if (Test-Path -LiteralPath $source -PathType Leaf) {
                $sourceHash=(Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()
                $expectedSourceHash = if ($copy.SourceSha256) { [string]$copy.SourceSha256 } else { [string]$copy.Sha256 }
                if ($sourceHash -ne $expectedSourceHash) { throw "HYPERV_RESOURCE_MIGRATION_SOURCE_CLEANUP_HASH_MISMATCH: $source" }
                $diskPlans = @(
                    foreach ($vmPlan in @($plan.Inventory.VMs)) {
                        foreach ($disk in @($vmPlan.LegacyDisks)) {
                            if ([string]::Equals([IO.Path]::GetFullPath([string]$disk.SourcePath), [IO.Path]::GetFullPath($source), [StringComparison]::OrdinalIgnoreCase) -and
                                [string]::Equals([IO.Path]::GetFullPath([string]$disk.DestinationPath), [IO.Path]::GetFullPath($destination), [StringComparison]::OrdinalIgnoreCase)) {
                                [PSCustomObject]@{ VMPlan=$vmPlan; Disk=$disk }
                            }
                        }
                    }
                )
                if ($diskPlans.Count -ne 1 -or -not (Test-Path -LiteralPath $destination -PathType Leaf)) {
                    throw "HYPERV_RESOURCE_MIGRATION_TARGET_CLEANUP_INTEGRITY_FAILED: $destination"
                }
                $diskPlan = $diskPlans[0].Disk
                $managedTarget = Get-HyperVManagedVM -VMName ([string]$diskPlans[0].VMPlan.VMName) `
                    -ExpectedRunId ([string]$plan.RunId) -ExpectedScopeId ([string]$plan.ScopeId)
                $attachedTarget = @(Get-VMHardDiskDrive -VM $managedTarget.VM -ErrorAction Stop | Where-Object {
                    $_.Path -and [string]::Equals([IO.Path]::GetFullPath([string]$_.Path), [IO.Path]::GetFullPath($destination), [StringComparison]::OrdinalIgnoreCase) -and
                    [int]$_.ControllerNumber -eq [int]$diskPlan.ControllerNumber -and [int]$_.ControllerLocation -eq [int]$diskPlan.ControllerLocation
                })
                $targetVhd = Get-VHD -Path $destination -ErrorAction Stop
                $targetParent = if ($targetVhd.ParentPath) { [IO.Path]::GetFullPath([string]$targetVhd.ParentPath) } else { $null }
                $expectedParent = if ($diskPlan.TargetParentPath) { [IO.Path]::GetFullPath([string]$diskPlan.TargetParentPath) } else { $null }
                if ($attachedTarget.Count -ne 1 -or [string]$targetVhd.VhdType -ne [string]$diskPlan.VhdType -or
                    [long]$targetVhd.Size -ne [long]$diskPlan.Size -or
                    ([string]$diskPlan.DiskIdentifier -and [string]$targetVhd.DiskIdentifier -ne [string]$diskPlan.DiskIdentifier) -or
                    -not [string]::Equals([string]$targetParent, [string]$expectedParent, [StringComparison]::OrdinalIgnoreCase)) {
                    throw "HYPERV_RESOURCE_MIGRATION_TARGET_CLEANUP_INTEGRITY_FAILED: $destination"
                }
                $attached = @(Get-VM -ErrorAction SilentlyContinue | Get-VMHardDiskDrive -ErrorAction SilentlyContinue | Where-Object {
                    $_.Path -and [IO.Path]::GetFullPath([string]$_.Path).Equals([IO.Path]::GetFullPath($source), [StringComparison]::OrdinalIgnoreCase)
                })
                if ($attached.Count -gt 0) { throw "HYPERV_RESOURCE_MIGRATION_SOURCE_STILL_ATTACHED: $source" }
                Remove-Item -LiteralPath $source -Force -ErrorAction Stop
            }
            if ($source -notin @($journal.SourceCleanup)) { $journal.SourceCleanup += $source }
        }
        $copiedSourcePaths = @($journal.CopiedDisks | ForEach-Object { [IO.Path]::GetFullPath([string]$_.SourcePath) })
        foreach ($file in @($plan.Inventory.Files)) {
            $source = [IO.Path]::GetFullPath((Join-Path $paths.LegacyRoot ([string]$file.RelativePath)))
            if ($source -in $copiedSourcePaths -or -not (Test-Path -LiteralPath $source -PathType Leaf)) { continue }
            $boundary = Test-LabPathWithinRoot -Root $paths.LegacyRoot -Path $source
            if (-not $boundary.Valid) { throw "HYPERV_RESOURCE_MIGRATION_SOURCE_CLEANUP_SCOPE_INVALID: $source" }
            $sourceHash=(Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($sourceHash -ne [string]$file.Sha256) { throw "HYPERV_RESOURCE_MIGRATION_SOURCE_CHANGED: $source" }
            Remove-Item -LiteralPath $source -Force -ErrorAction Stop
            if ($source -notin @($journal.SourceCleanup)) { $journal.SourceCleanup += $source }
        }
        if (Test-Path -LiteralPath $paths.LegacyRoot -PathType Container) {
            foreach ($directory in @(Get-ChildItem -LiteralPath $paths.LegacyRoot -Directory -Recurse -Force -ErrorAction SilentlyContinue | Sort-Object FullName -Descending)) {
                if (-not (Get-ChildItem -LiteralPath $directory.FullName -Force -ErrorAction SilentlyContinue | Select-Object -First 1)) { Remove-Item -LiteralPath $directory.FullName -Force }
            }
            if (-not (Get-ChildItem -LiteralPath $paths.LegacyRoot -Force -ErrorAction SilentlyContinue | Select-Object -First 1)) { Remove-Item -LiteralPath $paths.LegacyRoot -Force }
        }
        if (Test-Path -LiteralPath $paths.LegacyRoot -PathType Container) {
            throw 'HYPERV_RESOURCE_MIGRATION_LEGACY_ROOT_NOT_EMPTY'
        }
        $imagePlanPaths = @($plan.Inventory.VMs | ForEach-Object { @($_.LegacyDisks) } | Where-Object { $_.ParentMigrationPlanPath } | ForEach-Object { [string]$_.ParentMigrationPlanPath } | Select-Object -Unique)
        foreach ($imagePlanPath in $imagePlanPaths) {
            $imageResult = Invoke-LabHyperVImageMigration -PlanPath $imagePlanPath -DataRoot $DataRoot -Confirm:$false
            $resumeReceipt = @($journal.ImageMigrationResumes | Where-Object { [string]::Equals([string]$_.PlanPath, $imagePlanPath, [StringComparison]::OrdinalIgnoreCase) }) | Select-Object -First 1
            if ($resumeReceipt) { $resumeReceipt.Status=[string]$imageResult.Status; $resumeReceipt.At=Get-LabTimestamp }
            else { $journal.ImageMigrationResumes += [PSCustomObject]@{ PlanPath=$imagePlanPath; Status=[string]$imageResult.Status; At=Get-LabTimestamp } }
        }
        $journal.Status='COMPLETED'; $journal.CurrentStep='complete'; $journal.CompletedAt=Get-LabTimestamp
        Write-LabHyperVResourceMigrationJournal -Path $paths.Journal -Journal $journal
        return [PSCustomObject]@{ Status='COMPLETED'; RunId=[string]$plan.RunId; JournalPath=$paths.Journal; ResourceRoot=[string]$binding.HyperVResourceRoot }
    }
    catch {
        $journal.Status='RECOVERY_REQUIRED'; $journal.CurrentStep='failed'
        $journal.Errors += [PSCustomObject]@{ At=Get-LabTimestamp; Message=$_.Exception.Message }
        try { Write-LabHyperVResourceMigrationJournal -Path $paths.Journal -Journal $journal } catch { }
        throw "HYPERV_RESOURCE_MIGRATION_RECOVERY_REQUIRED: $($_.Exception.Message)"
    }
    }
    finally {
        if ($mutexAcquired) { try { $mutex.ReleaseMutex() } catch { } }
        $mutex.Dispose()
    }
}
