<#
.SYNOPSIS
    Versionierter Storage-Contract fuer verwaltete Lab_Data-Wurzeln.
#>

function Get-LabDataRootMarkerPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DataRoot)

    return Join-Path ([System.IO.Path]::GetFullPath($DataRoot)) '.sql-server-lab-root.json'
}

function Get-LabDataRootMarker {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DataRoot)

    $path = Get-LabDataRootMarkerPath -DataRoot $DataRoot
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    try { return Get-Content -LiteralPath $path -Raw -Encoding utf8 | ConvertFrom-Json -Depth 8 }
    catch { throw "LAB_DATA_ROOT_MARKER_INVALID: $path - $($_.Exception.Message)" }
}

function Get-LabVolumeIdentity {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $volumeRoot = [System.IO.Path]::GetPathRoot($fullPath)
    $driveLetter = if ($IsWindows -and $volumeRoot -match '^[A-Za-z]:') { $volumeRoot.Substring(0, 2).ToUpperInvariant() } else { $volumeRoot }
    $volumeId = $volumeRoot
    if ($IsWindows -and $driveLetter -match '^[A-Z]:$' -and (Get-Command Get-Volume -ErrorAction SilentlyContinue)) {
        try {
            $volume = Get-Volume -DriveLetter $driveLetter.Substring(0, 1) -ErrorAction Stop
            if (-not [string]::IsNullOrWhiteSpace([string]$volume.UniqueId)) { $volumeId = [string]$volume.UniqueId }
        }
        catch { }
    }
    return [PSCustomObject]@{ VolumeId = $volumeId; DriveLetter = $driveLetter; VolumeRoot = $volumeRoot }
}

function Initialize-LabManagedDataRoot {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$DataRoot,
        [string]$ControllerId
    )

    $root = [System.IO.Path]::GetFullPath($DataRoot).TrimEnd('\', '/')
    if (-not [string]::Equals((Split-Path -Leaf $root), 'Lab_Data', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'LAB_DATA_ROOT_NAME_REQUIRED: Der verwaltete Root muss Lab_Data heissen.'
    }
    if ($script:ModuleRoot) {
        $repositoryRoot = [System.IO.Path]::GetFullPath($script:ModuleRoot).TrimEnd('\', '/')
        $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
        if ($root.StartsWith($repositoryRoot + [System.IO.Path]::DirectorySeparatorChar, $comparison)) {
            throw 'LAB_DATA_ROOT_INSIDE_REPOSITORY'
        }
    }
    $existingMarker = Get-LabDataRootMarker -DataRoot $root
    if ($existingMarker) {
        if ([string]$existingMarker.ManagedBy -ne 'SQL_Server_Lab') { throw 'LAB_DATA_ROOT_FOREIGN_OWNER' }
        if ($ControllerId -and [string]$existingMarker.ControllerId -ne $ControllerId) { throw 'LAB_DATA_ROOT_CONTROLLER_MISMATCH' }
        $ControllerId = [string]$existingMarker.ControllerId
    }
    if ([string]::IsNullOrWhiteSpace($ControllerId)) { $ControllerId = [Guid]::NewGuid().ToString('D') }

    $directories = @('Backups/Incoming', 'Backups/Verified', 'Labs', 'Catalog', 'Exports', 'State', 'Temp')
    foreach ($path in @($root) + @($directories | ForEach-Object { Join-Path $root $_ })) {
        if (-not (Test-Path -LiteralPath $path -PathType Container) -and $PSCmdlet.ShouldProcess($path, 'Verwaltetes Storage-Verzeichnis erstellen')) {
            New-Item -Path $path -ItemType Directory -Force | Out-Null
        }
    }
    $volume = Get-LabVolumeIdentity -Path $root
    $marker = [PSCustomObject]@{
        ContractVersion = 'SqlServerLab.DataRoot/2.0'
        ManagedBy = 'SQL_Server_Lab'
        ControllerId = $ControllerId
        VolumeId = $volume.VolumeId
        CreatedAt = if ($existingMarker -and $existingMarker.CreatedAt) { [string]$existingMarker.CreatedAt } else { Get-LabTimestamp }
        DataRoot = $root
    }
    if ($PSCmdlet.ShouldProcess((Get-LabDataRootMarkerPath -DataRoot $root), 'Data-Root-Marker schreiben')) {
        Write-LabArtifactJsonAtomic -Path (Get-LabDataRootMarkerPath -DataRoot $root) -InputObject $marker
    }
    return $marker
}

function Test-LabDataRootOwnership {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DataRoot, [string]$ControllerId)

    $marker = Get-LabDataRootMarker -DataRoot $DataRoot
    if (-not $marker -or [string]$marker.ContractVersion -ne 'SqlServerLab.DataRoot/2.0' -or [string]$marker.ManagedBy -ne 'SQL_Server_Lab') { return $false }
    return (-not $ControllerId -or [string]$marker.ControllerId -eq $ControllerId)
}

function Get-LabStorageConfiguration {
    [CmdletBinding()]
    param([string]$DataRoot)

    if (-not $DataRoot) { $DataRoot = Get-LabDataRootDefault }
    $empty = [PSCustomObject]@{ ContractVersion = 'SqlServerLab.Storage/2.0'; ControllerId = $null; DefaultDataRoot = $null; LabDataLocations = @() }
    if (-not $DataRoot) { return $empty }
    $path = Join-Path (Join-Path $DataRoot 'Catalog') 'storage-locations.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        $marker = Get-LabDataRootMarker -DataRoot $DataRoot
        if (-not $marker) { return $empty }
        $volume = Get-LabVolumeIdentity -Path $DataRoot
        return [PSCustomObject]@{
            ContractVersion = 'SqlServerLab.Storage/2.0'; ControllerId = [string]$marker.ControllerId; DefaultDataRoot = $DataRoot
            LabDataLocations = @([PSCustomObject]@{ VolumeId=$volume.VolumeId; DriveLetter=$volume.DriveLetter; LabDataParent=(Split-Path -Parent $DataRoot); LabDataRoot=$DataRoot })
        }
    }
    try { return Get-Content -LiteralPath $path -Raw -Encoding utf8 | ConvertFrom-Json -Depth 12 }
    catch { throw "LAB_STORAGE_CONFIGURATION_INVALID: $($_.Exception.Message)" }
}

function Register-LabDataRoot {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DataRoot, [switch]$SetDefault)

    $root = (Resolve-Path -LiteralPath $DataRoot -ErrorAction Stop).Path.TrimEnd('\', '/')
    $currentDefault = Get-LabDataRootDefault
    $configuration = Get-LabStorageConfiguration -DataRoot $currentDefault
    $controllerId = [string]$configuration.ControllerId
    $marker = Get-LabDataRootMarker -DataRoot $root
    if (-not $marker) { throw 'LAB_DATA_ROOT_MARKER_REQUIRED: Root zuerst ueber die Storage-Verwaltung initialisieren.' }
    if ($controllerId -and [string]$marker.ControllerId -ne $controllerId) { throw 'LAB_DATA_ROOT_CONTROLLER_MISMATCH' }
    if (-not $controllerId) { $controllerId = [string]$marker.ControllerId }
    $volume = Get-LabVolumeIdentity -Path $root
    $locations = @($configuration.LabDataLocations)
    $existingVolume = @($locations | Where-Object { [string]$_.VolumeId -eq [string]$volume.VolumeId } | Select-Object -First 1)
    if ($existingVolume.Count -gt 0 -and -not [string]::Equals([string]$existingVolume[0].LabDataRoot, $root, [StringComparison]::OrdinalIgnoreCase)) {
        throw "LAB_DATA_ROOT_MIGRATION_REQUIRED: Volume $($volume.DriveLetter) ist bereits mit $($existingVolume[0].LabDataRoot) registriert. Parent-Wechsel nur ueber eine Storage-Migration."
    }
    if ($existingVolume.Count -eq 0) {
        $locations += [PSCustomObject]@{ VolumeId=$volume.VolumeId; DriveLetter=$volume.DriveLetter; LabDataParent=(Split-Path -Parent $root); LabDataRoot=$root }
    }
    $defaultRoot = if ($SetDefault -or -not $configuration.DefaultDataRoot) { $root } else { [string]$configuration.DefaultDataRoot }
    $targetConfigRoot = $defaultRoot
    $document = [PSCustomObject]@{
        ContractVersion = 'SqlServerLab.Storage/2.0'; ControllerId = $controllerId; DefaultDataRoot = $defaultRoot
        LabDataLocations = @($locations | Sort-Object DriveLetter); UpdatedAt = Get-LabTimestamp
    }
    Write-LabArtifactJsonAtomic -Path (Join-Path (Join-Path $targetConfigRoot 'Catalog') 'storage-locations.json') -InputObject $document
    if ($SetDefault -or -not $currentDefault) {
        $env:SQL_SERVER_LAB_DATA_ROOT = $root
        [Environment]::SetEnvironmentVariable('SQL_SERVER_LAB_DATA_ROOT', $root, 'User')
        $env:SQL_SERVER_LAB_CONTROLLER_ID = $controllerId
        [Environment]::SetEnvironmentVariable('SQL_SERVER_LAB_CONTROLLER_ID', $controllerId, 'User')
        Set-LabProjectPreferenceValue -Name dataRoot -Value $root
        $null = Set-LabTestEnvironmentDiscoveryEnvironment -DataRoot $root
    }
    return $root
}

function Set-LabDataLocation {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$LabDataParent, [switch]$SetDefault)

    $parentPath = [System.IO.Path]::GetFullPath($LabDataParent)
    $volumeRoot = [System.IO.Path]::GetPathRoot($parentPath)
    $parent = if ($parentPath.TrimEnd('\', '/') -eq $volumeRoot.TrimEnd('\', '/')) { $volumeRoot } else { $parentPath.TrimEnd('\', '/') }
    $dataRoot = Join-Path $parent 'Lab_Data'
    $configuration = Get-LabStorageConfiguration
    $marker = Initialize-LabManagedDataRoot -DataRoot $dataRoot -ControllerId ([string]$configuration.ControllerId)
    $null = Register-LabDataRoot -DataRoot $dataRoot -SetDefault:$SetDefault
    return [PSCustomObject]@{ LabDataParent=$parent; LabDataRoot=$dataRoot; ControllerId=$marker.ControllerId; Volume=(Get-LabVolumeIdentity -Path $dataRoot) }
}

function Resolve-LabDataRootForUse {
    [CmdletBinding()]
    param([string]$DataRoot)

    $configuration = Get-LabStorageConfiguration
    $candidate = if ($DataRoot) { [System.IO.Path]::GetFullPath($DataRoot).TrimEnd('\', '/') } else { [string]$configuration.DefaultDataRoot }
    if (-not $candidate) { throw 'LAB_DATA_ROOT_REQUIRED: Zuerst eine Lab_Data-Ablage konfigurieren.' }
    $registered = @($configuration.LabDataLocations | Where-Object { [string]::Equals([string]$_.LabDataRoot, $candidate, [StringComparison]::OrdinalIgnoreCase) })
    if ($registered.Count -eq 0) { throw "LAB_DATA_ROOT_NOT_REGISTERED: $candidate" }
    if (-not (Test-LabDataRootOwnership -DataRoot $candidate -ControllerId ([string]$configuration.ControllerId))) { throw "LAB_DATA_ROOT_OWNERSHIP_INVALID: $candidate" }
    return (Resolve-Path -LiteralPath $candidate -ErrorAction Stop).Path
}

function New-LabDataMigrationPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceDataRoot,
        [Parameter(Mandatory)][string]$TargetParent
    )

    $configuration = Get-LabStorageConfiguration
    $sourceRoot = Resolve-LabDataRootForUse -DataRoot $SourceDataRoot
    $sourceLocation = @($configuration.LabDataLocations | Where-Object { [string]::Equals([string]$_.LabDataRoot, $sourceRoot, [StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1)
    if ($sourceLocation.Count -eq 0) { throw "LAB_DATA_ROOT_NOT_REGISTERED: $sourceRoot" }

    $targetParentPath = [System.IO.Path]::GetFullPath($TargetParent)
    $targetVolumeRoot = [System.IO.Path]::GetPathRoot($targetParentPath)
    $normalizedTargetParent = if ($targetParentPath.TrimEnd('\', '/') -eq $targetVolumeRoot.TrimEnd('\', '/')) { $targetVolumeRoot } else { $targetParentPath.TrimEnd('\', '/') }
    $targetRoot = Join-Path $normalizedTargetParent 'Lab_Data'
    $sourceVolume = Get-LabVolumeIdentity -Path $sourceRoot
    $targetVolume = Get-LabVolumeIdentity -Path $targetRoot
    $blockers = [System.Collections.Generic.List[string]]::new()
    if ([string]$sourceVolume.VolumeId -ne [string]$targetVolume.VolumeId) {
        $blockers.Add('TARGET_VOLUME_DIFFERS: Ein anderes Volume wird als eigene Lab_Data-Location registriert, nicht als Parent-Migration behandelt.')
    }
    if ([string]::Equals($sourceRoot, $targetRoot, [StringComparison]::OrdinalIgnoreCase)) { $blockers.Add('SOURCE_EQUALS_TARGET') }

    $targetMarker = Get-LabDataRootMarker -DataRoot $targetRoot
    if ($targetMarker -and [string]$targetMarker.ControllerId -ne [string]$configuration.ControllerId) { $blockers.Add('TARGET_CONTROLLER_MISMATCH') }
    if ((Test-Path -LiteralPath $targetRoot -PathType Container) -and -not $targetMarker) {
        $targetContent = Get-ChildItem -LiteralPath $targetRoot -Force -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($targetContent) { $blockers.Add('TARGET_NOT_EMPTY_OR_UNMANAGED') }
    }

    $files = @(Get-ChildItem -LiteralPath $sourceRoot -File -Recurse -Force -ErrorAction Stop)
    $totalBytes = [long](($files | Measure-Object -Property Length -Sum).Sum)
    $driveInfo = [System.IO.DriveInfo]::new($targetVolume.VolumeRoot)
    $availableBytes = [long]$driveInfo.AvailableFreeSpace
    $requiredBytes = [long][Math]::Ceiling($totalBytes * 1.1)
    if ($availableBytes -lt $requiredBytes) { $blockers.Add('TARGET_CAPACITY_INSUFFICIENT') }

    $affectedRuns = @()
    foreach ($run in @(Get-LabActiveRuns)) {
        $runDataRoot = [string]$run.metadata.dataRoot
        if ($runDataRoot -and [string]::Equals([System.IO.Path]::GetFullPath($runDataRoot).TrimEnd('\', '/'), $sourceRoot.TrimEnd('\', '/'), [StringComparison]::OrdinalIgnoreCase)) {
            $runState = [string]$run.state
            $providers = @(
                @($run.instances | ForEach-Object { [string]$_.provider })
                @($run.providerSubRuns.PSObject.Properties | ForEach-Object { [string]$_.Name })
            ) | Where-Object { $_ } | Sort-Object -Unique
            $affectedRuns += [PSCustomObject]@{ RunId=[string]$run.runId; Name=[string]$run.metadata.name; State=$runState; Providers=@($providers) }
            if ($runState -notin @('STOPPED', 'REMOVED', 'FAILED')) { $blockers.Add("RUN_NOT_STOPPED:$($run.runId)") }
            if (@($providers | Where-Object { $_ -in @('docker', 'podman') }).Count -gt 0) { $blockers.Add("CONTAINER_REBIND_REQUIRED:$($run.runId)") }
        }
    }
    $stateRoot = Get-LabStateRoot
    if (@($affectedRuns).Count -gt 0 -and -not [string]::Equals([System.IO.Path]::GetFullPath($stateRoot).TrimEnd('\', '/'), (Join-Path $sourceRoot 'State').TrimEnd('\', '/'), [StringComparison]::OrdinalIgnoreCase)) {
        $blockers.Add('STATE_ROOT_OUTSIDE_SOURCE')
    }

    $planId = [Guid]::NewGuid().ToString('D')
    $plan = [PSCustomObject]@{
        ContractVersion = 'SqlServerLab.StorageMigrationPlan/1.0'
        PlanId = $planId
        CreatedAt = Get-LabTimestamp
        ControllerId = [string]$configuration.ControllerId
        Status = if ($blockers.Count -eq 0) { 'READY' } else { 'BLOCKED' }
        Source = [PSCustomObject]@{ VolumeId=$sourceVolume.VolumeId; DriveLetter=$sourceVolume.DriveLetter; LabDataRoot=$sourceRoot }
        Target = [PSCustomObject]@{ VolumeId=$targetVolume.VolumeId; DriveLetter=$targetVolume.DriveLetter; LabDataParent=$normalizedTargetParent; LabDataRoot=$targetRoot }
        Inventory = [PSCustomObject]@{ FileCount=$files.Count; TotalBytes=$totalBytes; RequiredBytes=$requiredBytes; AvailableBytes=$availableBytes }
        AffectedRuns = @($affectedRuns)
        RequiredActions = @('Stop affected environments', 'Create migration journal', 'Copy and verify data', 'Update provider and state references', 'Switch authoritative storage catalog', 'Remove empty managed source root')
        Blockers = @($blockers | Sort-Object -Unique)
        ExecutionImplemented = $true
    }
    $planDirectory = Join-Path (Join-Path $sourceRoot 'Catalog') 'storage-migrations'
    if (-not (Test-Path -LiteralPath $planDirectory -PathType Container)) { New-Item -Path $planDirectory -ItemType Directory -Force | Out-Null }
    $planPath = Join-Path $planDirectory "$planId.plan.json"
    Write-LabArtifactJsonAtomic -Path $planPath -InputObject $plan
    return [PSCustomObject]@{ Path=$planPath; Plan=$plan }
}

function Write-LabDataMigrationJournal {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Journal, [string]$MirrorPath)

    $Journal.UpdatedAt = Get-LabTimestamp
    Write-LabArtifactJsonAtomic -Path $Path -InputObject $Journal
    if ($MirrorPath) { Write-LabArtifactJsonAtomic -Path $MirrorPath -InputObject $Journal }
}

function Get-LabHyperVHardDiskDriveInventory {
    [CmdletBinding()]
    param()

    $getVmCommand = Get-Command Get-VM -ErrorAction SilentlyContinue
    $getDriveCommand = Get-Command Get-VMHardDiskDrive -ErrorAction SilentlyContinue
    if (-not $getVmCommand -or -not $getDriveCommand) { return @() }

    $drives = [System.Collections.Generic.List[object]]::new()
    foreach ($vm in @(Get-VM -ErrorAction Stop)) {
        foreach ($drive in @(Get-VMHardDiskDrive -VMName ([string]$vm.Name) -ErrorAction Stop)) {
            $drives.Add($drive)
        }
    }
    return @($drives)
}

function Update-LabMigratedJsonReferences {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$SourceRoot, [Parameter(Mandatory)][string]$TargetRoot)

    $changed = [System.Collections.Generic.List[string]]::new()
    $sourceEscaped = $SourceRoot.Replace('\', '\\')
    $targetEscaped = $TargetRoot.Replace('\', '\\')
    foreach ($path in @(Get-ChildItem -LiteralPath $Root -Filter '*.json' -File -Recurse -Force -ErrorAction Stop)) {
        $content = Get-Content -LiteralPath $path.FullName -Raw -Encoding utf8
        $updated = $content.Replace($sourceEscaped, $targetEscaped, [StringComparison]::OrdinalIgnoreCase)
        $updated = $updated.Replace($SourceRoot, $TargetRoot, [StringComparison]::OrdinalIgnoreCase)
        if ($updated -ne $content) {
            [System.IO.File]::WriteAllText($path.FullName, $updated, [System.Text.UTF8Encoding]::new($false))
            $changed.Add($path.FullName)
        }
    }
    return @($changed)
}

function Invoke-LabDataMigration {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='High')]
    param([Parameter(Mandatory)][string]$PlanPath, [switch]$ProcessEnvironmentOnly)

    $resolvedPlanPath = (Resolve-Path -LiteralPath $PlanPath -ErrorAction Stop).Path
    $plan = Get-Content -LiteralPath $resolvedPlanPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 20
    if ([string]$plan.ContractVersion -ne 'SqlServerLab.StorageMigrationPlan/1.0' -or -not [bool]$plan.ExecutionImplemented) { throw 'LAB_STORAGE_MIGRATION_PLAN_NOT_EXECUTABLE' }
    if ([string]$plan.Status -ne 'READY' -or @($plan.Blockers).Count -gt 0) { throw "LAB_STORAGE_MIGRATION_PLAN_BLOCKED: $(@($plan.Blockers) -join ', ')" }
    $sourceRoot = (Resolve-Path -LiteralPath ([string]$plan.Source.LabDataRoot) -ErrorAction Stop).Path.TrimEnd('\', '/')
    $targetRoot = [System.IO.Path]::GetFullPath([string]$plan.Target.LabDataRoot).TrimEnd('\', '/')
    $configuration = Get-LabStorageConfiguration -DataRoot $sourceRoot
    if ([string]$configuration.ControllerId -ne [string]$plan.ControllerId) { throw 'LAB_STORAGE_MIGRATION_CONTROLLER_MISMATCH' }
    if (-not (Test-LabDataRootOwnership -DataRoot $sourceRoot -ControllerId ([string]$plan.ControllerId))) { throw 'LAB_STORAGE_MIGRATION_SOURCE_OWNERSHIP_INVALID' }
    if (-not $PSCmdlet.ShouldProcess("$sourceRoot -> $targetRoot", 'Lab_Data journalisiert migrieren')) { return $null }

    $planHash = (Get-FileHash -LiteralPath $resolvedPlanPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $journalDirectory = Split-Path -Parent $resolvedPlanPath
    $journalPath = Join-Path $journalDirectory "$($plan.PlanId).journal.json"
    $targetJournalPath = Join-Path (Join-Path (Join-Path $targetRoot 'Catalog') 'storage-migrations') "$($plan.PlanId).journal.json"
    $journal = if (Test-Path -LiteralPath $journalPath -PathType Leaf) {
        Get-Content -LiteralPath $journalPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 30
    }
    else {
        [PSCustomObject]@{
            ContractVersion='SqlServerLab.StorageMigrationJournal/1.0'; PlanId=[string]$plan.PlanId; PlanSha256=$planHash
            Status='PREPARING'; CreatedAt=Get-LabTimestamp; UpdatedAt=Get-LabTimestamp; CurrentStep='validate'
            CompletedAt=$null; CopiedFiles=@(); ReboundResources=@(); UpdatedReferences=@(); Errors=@()
        }
    }
    if ([string]$journal.PlanSha256 -ne $planHash) { throw 'LAB_STORAGE_MIGRATION_PLAN_CHANGED' }

    try {
        if ($IsWindows) {
            foreach ($drive in @(Get-LabHyperVHardDiskDriveInventory | Where-Object {
                if (-not $_.Path) { return $false }
                $drivePath = [System.IO.Path]::GetFullPath([string]$_.Path)
                return $drivePath.Equals($sourceRoot, [StringComparison]::OrdinalIgnoreCase) -or $drivePath.StartsWith($sourceRoot + [System.IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
            })) {
                $vm = Get-VM -Name ([string]$drive.VMName) -ErrorAction Stop
                if ([string]$vm.State -ne 'Off') { throw "LAB_STORAGE_MIGRATION_HYPERV_VM_NOT_OFF: $($drive.VMName)" }
            }
        }
        foreach ($runtime in @('docker', 'podman')) {
            if (-not (Get-Command $runtime -ErrorAction SilentlyContinue)) { continue }
            $containerIds = & $runtime ps -a -q --filter 'label=sql-server-lab.run-id' 2>$null
            if ($LASTEXITCODE -ne 0) { continue }
            foreach ($containerId in @($containerIds)) {
                $inspect = @(& $runtime inspect ([string]$containerId) 2>$null | ConvertFrom-Json -Depth 30)[0]
                foreach ($mount in @($inspect.Mounts | Where-Object { $_.Type -eq 'bind' -and $_.Source })) {
                    $mountSource = [System.IO.Path]::GetFullPath([string]$mount.Source)
                    if ($mountSource.Equals($sourceRoot, [StringComparison]::OrdinalIgnoreCase) -or $mountSource.StartsWith($sourceRoot + [System.IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
                        throw "LAB_STORAGE_MIGRATION_CONTAINER_REBIND_REQUIRED: $runtime/$containerId"
                    }
                }
            }
        }

        $journal.Status = 'COPYING'; $journal.CurrentStep = 'copy-and-verify'
        Write-LabDataMigrationJournal -Path $journalPath -Journal $journal
        if (-not (Test-Path -LiteralPath $targetRoot -PathType Container)) { New-Item -Path $targetRoot -ItemType Directory -Force | Out-Null }
        $targetJournalDirectory = Split-Path -Parent $targetJournalPath
        if (-not (Test-Path -LiteralPath $targetJournalDirectory -PathType Container)) { New-Item -Path $targetJournalDirectory -ItemType Directory -Force | Out-Null }
        foreach ($sourceFile in @(Get-ChildItem -LiteralPath $sourceRoot -File -Recurse -Force -ErrorAction Stop | Where-Object { $_.FullName -ne $journalPath })) {
            $relativePath = [System.IO.Path]::GetRelativePath($sourceRoot, $sourceFile.FullName)
            $destination = Join-Path $targetRoot $relativePath
            $destinationDirectory = Split-Path -Parent $destination
            if (-not (Test-Path -LiteralPath $destinationDirectory -PathType Container)) { New-Item -Path $destinationDirectory -ItemType Directory -Force | Out-Null }
            $sourceHash = (Get-FileHash -LiteralPath $sourceFile.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            $alreadyCopied = (Test-Path -LiteralPath $destination -PathType Leaf) -and ((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant() -eq $sourceHash)
            if (-not $alreadyCopied) {
                $temporaryDestination = "$destination.sql-lab-migrating"
                Copy-Item -LiteralPath $sourceFile.FullName -Destination $temporaryDestination -Force
                $targetHash = (Get-FileHash -LiteralPath $temporaryDestination -Algorithm SHA256).Hash.ToLowerInvariant()
                if ($targetHash -ne $sourceHash) { throw "LAB_STORAGE_MIGRATION_HASH_MISMATCH: $relativePath" }
                Move-Item -LiteralPath $temporaryDestination -Destination $destination -Force
            }
            if ($relativePath -notin @($journal.CopiedFiles)) { $journal.CopiedFiles += $relativePath }
            Write-LabDataMigrationJournal -Path $journalPath -Journal $journal -MirrorPath $targetJournalPath
        }

        $journal.Status = 'REBINDING'; $journal.CurrentStep = 'provider-rebind'
        Write-LabDataMigrationJournal -Path $journalPath -Journal $journal -MirrorPath $targetJournalPath
        if ($IsWindows) {
            foreach ($drive in @(Get-LabHyperVHardDiskDriveInventory | Where-Object {
                if (-not $_.Path) { return $false }
                $drivePath = [System.IO.Path]::GetFullPath([string]$_.Path)
                return $drivePath.Equals($sourceRoot, [StringComparison]::OrdinalIgnoreCase) -or $drivePath.StartsWith($sourceRoot + [System.IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
            })) {
                $vm = Get-VM -Name ([string]$drive.VMName) -ErrorAction Stop
                if ([string]$vm.State -ne 'Off') { throw "LAB_STORAGE_MIGRATION_HYPERV_VM_NOT_OFF: $($drive.VMName)" }
                $newPath = Join-Path $targetRoot ([System.IO.Path]::GetRelativePath($sourceRoot, [string]$drive.Path))
                Set-VMHardDiskDrive -VMHardDiskDrive $drive -Path $newPath -ErrorAction Stop
                $journal.ReboundResources += [PSCustomObject]@{ Provider='hyperv'; VMName=[string]$drive.VMName; PreviousPath=[string]$drive.Path; Path=$newPath }
            }
        }

        $journal.Status = 'SWITCHING'; $journal.CurrentStep = 'references-and-catalog'
        $journal.UpdatedReferences = @(Update-LabMigratedJsonReferences -Root $targetRoot -SourceRoot $sourceRoot -TargetRoot $targetRoot)
        $locations = @($configuration.LabDataLocations | ForEach-Object {
            if ([string]::Equals([string]$_.LabDataRoot, $sourceRoot, [StringComparison]::OrdinalIgnoreCase)) {
                [PSCustomObject]@{ VolumeId=[string]$plan.Target.VolumeId; DriveLetter=[string]$plan.Target.DriveLetter; LabDataParent=[string]$plan.Target.LabDataParent; LabDataRoot=$targetRoot }
            }
            else { $_ }
        })
        $newConfiguration = [PSCustomObject]@{
            ContractVersion='SqlServerLab.Storage/2.0'; ControllerId=[string]$configuration.ControllerId
            DefaultDataRoot=if ([string]::Equals([string]$configuration.DefaultDataRoot, $sourceRoot, [StringComparison]::OrdinalIgnoreCase)) { $targetRoot } else { [string]$configuration.DefaultDataRoot }
            LabDataLocations=$locations; UpdatedAt=Get-LabTimestamp
        }
        $null = Initialize-LabManagedDataRoot -DataRoot $targetRoot -ControllerId ([string]$configuration.ControllerId) -Confirm:$false
        Write-LabArtifactJsonAtomic -Path (Join-Path (Join-Path $targetRoot 'Catalog') 'storage-locations.json') -InputObject $newConfiguration
        if ([string]::Equals([string]$newConfiguration.DefaultDataRoot, $targetRoot, [StringComparison]::OrdinalIgnoreCase)) {
            $env:SQL_SERVER_LAB_DATA_ROOT = $targetRoot
            if (-not $ProcessEnvironmentOnly) { [Environment]::SetEnvironmentVariable('SQL_SERVER_LAB_DATA_ROOT', $targetRoot, 'User') }
            Set-LabProjectPreferenceValue -Name dataRoot -Value $targetRoot
            $null = Set-LabTestEnvironmentDiscoveryEnvironment -DataRoot $targetRoot -ProcessEnvironmentOnly:$ProcessEnvironmentOnly
        }

        $journal.Status = 'CLEANING'; $journal.CurrentStep = 'remove-verified-source'
        Write-LabDataMigrationJournal -Path $journalPath -Journal $journal -MirrorPath $targetJournalPath
        foreach ($sourceFile in @(Get-ChildItem -LiteralPath $sourceRoot -File -Recurse -Force -ErrorAction Stop)) {
            $relativePath = [System.IO.Path]::GetRelativePath($sourceRoot, $sourceFile.FullName)
            $destination = Join-Path $targetRoot $relativePath
            if (-not (Test-Path -LiteralPath $destination -PathType Leaf)) { throw "LAB_STORAGE_MIGRATION_TARGET_FILE_MISSING: $relativePath" }
            if ($sourceFile.FullName -ne $journalPath) { Remove-Item -LiteralPath $sourceFile.FullName -Force }
        }
        if (Test-Path -LiteralPath $journalPath -PathType Leaf) { Remove-Item -LiteralPath $journalPath -Force }
        foreach ($directory in @(Get-ChildItem -LiteralPath $sourceRoot -Directory -Recurse -Force | Sort-Object FullName -Descending)) {
            if (-not (Get-ChildItem -LiteralPath $directory.FullName -Force -ErrorAction SilentlyContinue | Select-Object -First 1)) { Remove-Item -LiteralPath $directory.FullName -Force }
        }
        if (-not (Get-ChildItem -LiteralPath $sourceRoot -Force -ErrorAction SilentlyContinue | Select-Object -First 1)) { Remove-Item -LiteralPath $sourceRoot -Force }

        $journal.Status = 'COMPLETED'; $journal.CurrentStep = 'complete'; $journal.CompletedAt = Get-LabTimestamp
        Write-LabDataMigrationJournal -Path $targetJournalPath -Journal $journal
        return [PSCustomObject]@{ Status='COMPLETED'; PlanId=[string]$plan.PlanId; DataRoot=$targetRoot; JournalPath=$targetJournalPath }
    }
    catch {
        $journal.Status = 'RECOVERY_REQUIRED'; $journal.CurrentStep = 'failed'
        $journal.Errors += [PSCustomObject]@{ At=Get-LabTimestamp; Message=$_.Exception.Message }
        try { Write-LabDataMigrationJournal -Path $journalPath -Journal $journal -MirrorPath $(if (Test-Path -LiteralPath $targetRoot -PathType Container) { $targetJournalPath } else { $null }) } catch { }
        throw "LAB_STORAGE_MIGRATION_RECOVERY_REQUIRED: $($_.Exception.Message)"
    }
}

function Invoke-LabStorageInteractive {
    [CmdletBinding()]
    param()

    $configuration = Get-LabStorageConfiguration
    Write-Host '  Storage-Verwaltung' -ForegroundColor Cyan
    Write-Host '  ---------------------------------------------------------------------' -ForegroundColor DarkCyan
    Write-Host "    Standard: $(if ($configuration.DefaultDataRoot) { $configuration.DefaultDataRoot } else { '<nicht konfiguriert>' })"
    foreach ($location in @($configuration.LabDataLocations)) {
        Write-Host ("    {0} -> {1}" -f $location.DriveLetter, $location.LabDataRoot) -ForegroundColor DarkGray
    }
    Write-Host '    [1] Lab_Data-Parent eines Volumes konfigurieren'
    Write-Host '    [2] Storage-Konfiguration erneut anzeigen'
    Write-Host '    [3] Parent-Wechsel als Migrationsplan pruefen'
    Write-Host '    [4] Freigegebenen Migrationsplan ausfuehren'
    Write-Host '    [0] Zurueck'
    $choice = Read-Host '  Auswahl'
    if ($choice -eq '1') {
        $parent = Read-Host '  Fester Parent auf dem Zielvolume (Volume-Root ist erlaubt)'
        if ([string]::IsNullOrWhiteSpace($parent)) { return }
        try {
            $setDefault = -not $configuration.DefaultDataRoot -or (Read-LabConfirm -Prompt '  Diese Lab_Data-Wurzel als Standard verwenden?' -Default $false)
            $result = Set-LabDataLocation -LabDataParent $parent -SetDefault:$setDefault
            Write-LabSuccess "Lab_Data registriert: $($result.LabDataRoot)"
        }
        catch { Write-LabError $_.Exception.Message }
    }
    elseif ($choice -eq '3') {
        $locations = @($configuration.LabDataLocations)
        if ($locations.Count -eq 0) { Write-LabWarning 'Keine Lab_Data-Wurzel registriert.'; return }
        for ($index = 0; $index -lt $locations.Count; $index++) { Write-Host ('    [{0}] {1}' -f ($index + 1), $locations[$index].LabDataRoot) }
        $selection = Read-Host '  Quell-Root [1]'
        if (-not $selection) { $selection = '1' }
        $number = 0
        if (-not [int]::TryParse($selection, [ref]$number) -or $number -lt 1 -or $number -gt $locations.Count) { Write-LabWarning 'Ungueltige Auswahl.'; return }
        $targetParent = Read-Host '  Neuer fester Parent auf demselben Volume'
        if (-not $targetParent) { return }
        try {
            $result = New-LabDataMigrationPlan -SourceDataRoot ([string]$locations[$number - 1].LabDataRoot) -TargetParent $targetParent
            Write-LabInfo "Migrationsplan: $($result.Path)"
            Write-Host ("    Status={0}, Dateien={1}, Bytes={2}, Blocker={3}" -f $result.Plan.Status, $result.Plan.Inventory.FileCount, $result.Plan.Inventory.TotalBytes, @($result.Plan.Blockers).Count) -ForegroundColor DarkGray
            foreach ($blocker in @($result.Plan.Blockers)) { Write-LabWarning $blocker }
        }
        catch { Write-LabError $_.Exception.Message }
    }
    elseif ($choice -eq '4') {
        $planPath = Read-Host '  Vollstaendiger Pfad zur *.plan.json'
        if (-not $planPath) { return }
        Write-LabWarning 'Die Migration kopiert und prueft alle Dateien, bindet Hyper-V-VHDX um und schaltet erst danach den Katalog um.'
        if (-not (Read-LabConfirm -Prompt '  Migrationsplan jetzt ausfuehren?' -Default $false)) { return }
        try {
            $result = Invoke-LabDataMigration -PlanPath $planPath -Confirm:$false
            Write-LabSuccess "Storage-Migration abgeschlossen: $($result.DataRoot)"
            Write-LabInfo "Journal: $($result.JournalPath)"
        }
        catch { Write-LabError $_.Exception.Message }
    }
}
