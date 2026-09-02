<#
.SYNOPSIS
    Erzeugt eine read-only Matrix der logischen und physischen Storage-Residency.
.DESCRIPTION
    Fuehrt bekannte Lab_Data-Roots, aktive Run-Bindings, native Runtime-Volumes,
    Hyper-V-Ressourcen und externe beziehungsweise Legacy-Reste zusammen. Nicht
    durch die Provider-API aufloesbares physisches Backing bleibt ausdruecklich
    UNVERIFIABLE und wird nicht als Lab_Data-Ablage ausgegeben.
#>

function Get-LabStorageResidencyObjectId {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Key)

    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Key.ToLowerInvariant())
        $hash = [BitConverter]::ToString($algorithm.ComputeHash($bytes)).Replace('-', '').ToLowerInvariant()
        return "storage-object-$($hash.Substring(0, 24))"
    }
    finally { $algorithm.Dispose() }
}

function Get-LabStoragePathRelation {
    [CmdletBinding()]
    param(
        [string]$Path,
        [AllowEmptyCollection()][string[]]$KnownRoots = @(),
        [switch]$RuntimeNamespace
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { return 'UNKNOWN' }
    if ($RuntimeNamespace) { return 'RUNTIME_INTERNAL' }
    if (-not [IO.Path]::IsPathFullyQualified($Path)) { return 'UNKNOWN' }

    try { $resolvedPath = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/') }
    catch { return 'UNKNOWN' }
    foreach ($root in @($KnownRoots | Where-Object { $_ })) {
        try { $resolvedRoot = [IO.Path]::GetFullPath($root).TrimEnd('\', '/') }
        catch { continue }
        if ($resolvedPath.Equals($resolvedRoot, [StringComparison]::OrdinalIgnoreCase) -or
            $resolvedPath.StartsWith($resolvedRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
            return 'INSIDE'
        }
    }
    return 'OUTSIDE'
}

function New-LabStorageResidencyObject {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][ValidateSet('CONTROL_STATE','LAB_DATA_ROOT','INSTANCE_STORE','DATABASE_PACKAGE','BACKUP_SET','BACKUP_WORKSPACE','EXCHANGE_WORKSPACE','RUNTIME_BACKING_STORE','RUNTIME_CONFIGURATION','RUNTIME_IMAGE','RUNTIME_IMAGE_STORE','RUNTIME_CONTAINER_STORE','RUNTIME_VOLUME_STORE','RUNTIME_BUILD_CACHE','HYPERV_RUN_RESOURCE','HYPERV_SHARED_RESOURCE','EXTERNAL_REFERENCE','REPOSITORY_RESIDUE','LEGACY_STATE')][string]$ObjectClass,
        [Parameter(Mandatory)][ValidateSet('core','docker','podman','hyperv','external')][string]$Provider,
        [Parameter(Mandatory)][ValidateSet('CONTROLLER','RUN_SCOPED','RETAINED','SHARED','UNMANAGED_OR_UNKNOWN')][string]$Lifecycle,
        [Parameter(Mandatory)][ValidateSet('LAB_DATA','NATIVE_RUNTIME','EXTERNAL_HOST','REPOSITORY','LEGACY_PROFILE','UNKNOWN')][string]$Residency,
        [Parameter(Mandatory)][ValidateSet('HOST_VISIBLE','RUNTIME_NAMESPACE','NOT_APPLICABLE','UNKNOWN')][string]$PathVisibility,
        [Parameter(Mandatory)][ValidateSet('INSIDE','OUTSIDE','RUNTIME_INTERNAL','UNKNOWN')][string]$LabDataRelation,
        [Parameter(Mandatory)][string]$LogicalName,
        [AllowNull()][string]$Path,
        [AllowEmptyCollection()][string[]]$RunIds = @(),
        [Parameter(Mandatory)][ValidateSet('RUN_CLEANUP','PRESERVE_RETAINED','PRESERVE_SHARED','REPORT_ONLY')][string]$CleanupPolicy,
        [Parameter(Mandatory)][ValidateSet('VERIFIED','DECLARED','RESIDUAL','UNVERIFIABLE')][string]$AuditStatus,
        [hashtable]$Details = @{}
    )

    [PSCustomObject]@{
        ObjectId = Get-LabStorageResidencyObjectId -Key $Key
        ObjectClass = $ObjectClass
        Provider = $Provider
        Lifecycle = $Lifecycle
        Residency = $Residency
        PathVisibility = $PathVisibility
        LabDataRelation = $LabDataRelation
        LogicalName = $LogicalName
        Path = if ($Path) { $Path } else { $null }
        RunIds = @($RunIds | Where-Object { $_ } | Sort-Object -Unique)
        CleanupPolicy = $CleanupPolicy
        AuditStatus = $AuditStatus
        Details = [PSCustomObject]$Details
    }
}

function Get-LabRuntimeStorageRoot {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('docker','podman')][string]$Provider)

    $template = if ($Provider -eq 'docker') { '{{.DockerRootDir}}' } else { '{{.Store.GraphRoot}}' }
    $invocation = Get-LabHostToolInvocation -Name $Provider
    $output = @(& $invocation info --format $template 2>$null | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
    if ($LASTEXITCODE -ne 0 -or $output.Count -ne 1) { return $null }
    return [string]$output[0]
}

function Get-LabRuntimeVolumeInspection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('docker','podman')][string]$Provider,
        [Parameter(Mandatory)][string]$Name
    )

    $invocation = Get-LabHostToolInvocation -Name $Provider
    $raw = @(& $invocation volume inspect $Name 2>$null)
    if ($LASTEXITCODE -ne 0 -or $raw.Count -eq 0) { return $null }
    try {
        $parsed = @((($raw -join "`n") | ConvertFrom-Json -Depth 20 -ErrorAction Stop))[0]
        if (-not $parsed) { return $null }
        $labels = if ($parsed.Labels) { $parsed.Labels } else { $parsed.labels }
        return [PSCustomObject]@{
            Mountpoint = if ($parsed.Mountpoint) { [string]$parsed.Mountpoint } else { [string]$parsed.mountpoint }
            RunId = if ($labels) { [string]$labels.'sql-server-lab.run-id' } else { $null }
            ScopeId = if ($labels) { [string]$labels.'sql-server-lab.scope-id' } else { $null }
        }
    }
    catch { return $null }
}

function Get-LabRuntimeStorageUsage {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('docker','podman')][string]$Provider)

    $invocation = Get-LabHostToolInvocation -Name $Provider
    try {
        $raw = if ($Provider -eq 'docker') {
            @(& $invocation system df --format '{{json .}}' 2>$null)
        }
        else { @(& $invocation system df --format json 2>$null) }
        if ($LASTEXITCODE -ne 0 -or $raw.Count -eq 0) { throw 'RUNTIME_STORAGE_USAGE_UNAVAILABLE' }
        $rows = if ($Provider -eq 'docker') {
            @($raw | ForEach-Object { $_ | ConvertFrom-Json -Depth 10 -ErrorAction Stop })
        }
        else { @((($raw -join "`n") | ConvertFrom-Json -Depth 10 -ErrorAction Stop)) }
    }
    catch { $rows = @() }

    $categories = [ordered]@{
        'Images'='IMAGES'; 'Containers'='CONTAINERS'; 'Local Volumes'='LOCAL_VOLUMES'; 'Build Cache'='BUILD_CACHE'
    }
    foreach ($entry in $categories.GetEnumerator()) {
        $row = @($rows | Where-Object { [string]$_.Type -eq [string]$entry.Key })[0]
        $notApplicable = $Provider -eq 'podman' -and [string]$entry.Value -eq 'BUILD_CACHE' -and -not $row
        [PSCustomObject]@{
            Provider=$Provider; Category=[string]$entry.Value
            Status=if ($row) { 'AVAILABLE' } elseif ($notApplicable) { 'NOT_APPLICABLE' } else { 'UNVERIFIABLE' }
            TotalCount=if ($row) { [int]$(if ($null -ne $row.TotalCount) { $row.TotalCount } else { $row.Total }) } else { 0 }
            ActiveCount=if ($row) { [int]$row.Active } else { 0 }
            ReportedSize=if ($row) { [string]$row.Size } else { $null }
            ReportedReclaimable=if ($row) { [string]$row.Reclaimable } else { $null }
            RawSizeBytes=if ($row -and $null -ne $row.RawSize) { [long]$row.RawSize } else { $null }
            RawReclaimableBytes=if ($row -and $null -ne $row.RawReclaimable) { [long]$row.RawReclaimable } else { $null }
        }
    }
}

function Get-LabManagedRuntimeImageInventory {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('docker','podman')][string]$Provider)

    $invocation = Get-LabHostToolInvocation -Name $Provider
    $raw = @(& $invocation image ls --filter 'label=sql-server-lab.external-runtime.image-key' --format '{{json .}}' 2>$null)
    if ($LASTEXITCODE -ne 0) { return @() }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($line in $raw) {
        try { $row = $line | ConvertFrom-Json -Depth 10 -ErrorAction Stop } catch { continue }
        $reference = if ([string]$row.Repository -and [string]$row.Tag -and [string]$row.Tag -ne '<none>') {
            "$([string]$row.Repository):$([string]$row.Tag)"
        }
        else { [string]$row.ID }
        $inspectRaw = @(& $invocation image inspect $reference 2>$null)
        if ($LASTEXITCODE -ne 0 -or $inspectRaw.Count -eq 0) { continue }
        try { $inspect = @((($inspectRaw -join "`n") | ConvertFrom-Json -Depth 30 -ErrorAction Stop))[0] } catch { continue }
        $imageId = [string]$inspect.Id
        if (-not $imageId -or -not $seen.Add($imageId)) { continue }
        $imageKey = [string]$inspect.Config.Labels.'sql-server-lab.external-runtime.image-key'
        if ($imageKey -notmatch '^[a-f0-9]{64}$') { continue }
        [PSCustomObject]@{
            Provider=$Provider; RuntimeImageId=$imageId; ImageKey=$imageKey; Reference=$reference
            ReportedSize=[string]$row.Size; CreatedAt=[string]$row.CreatedAt
        }
    }
}

function Get-LabStorageResidencyInventory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Configuration,
        [Parameter(Mandatory)][string]$StateRoot,
        [AllowEmptyCollection()][object[]]$DataRoots = @(),
        [AllowEmptyCollection()][object[]]$ActiveRuns = @(),
        [AllowEmptyCollection()][object[]]$RuntimeResults = @(),
        [AllowEmptyCollection()][object[]]$RuntimeHostBackings = @(),
        [AllowEmptyCollection()][object[]]$RuntimeStorageUsage = @(),
        [AllowEmptyCollection()][object[]]$ManagedImages = @(),
        [AllowEmptyCollection()][object[]]$ManagedVolumes = @(),
        [AllowEmptyCollection()][object[]]$PersistentStorageStores = @(),
        [string]$HyperVStatus = 'NOT_INSTALLED',
        [AllowEmptyCollection()][object[]]$HyperVResources = @(),
        [AllowEmptyCollection()][object[]]$HyperVRunScopes = @(),
        [AllowEmptyCollection()][object[]]$HyperVSharedRoots = @(),
        [AllowEmptyCollection()][object[]]$HyperVUntrackedFiles = @(),
        [AllowEmptyCollection()][object[]]$ExternalReferences = @(),
        [AllowEmptyCollection()][object[]]$RepositoryResidues = @(),
        [AllowEmptyCollection()][object[]]$LegacyStateRoots = @()
    )

    $objects = [Collections.Generic.List[object]]::new()
    $knownRoots = @($Configuration.LabDataLocations | ForEach-Object { [string]$_.LabDataRoot } | Where-Object { $_ })
    $volumeReferences = @{}
    $hostBindings = [Collections.Generic.List[object]]::new()

    foreach ($run in @($ActiveRuns)) {
        foreach ($instance in @($run.instances)) {
            $provider = ([string]$instance.provider).ToLowerInvariant()
            foreach ($drive in @($instance.drives)) {
                if ($drive.volumeName -and $provider -in @('docker','podman')) {
                    $key = "$provider|$([string]$drive.volumeName)"
                    if (-not $volumeReferences.ContainsKey($key)) { $volumeReferences[$key] = [Collections.Generic.List[string]]::new() }
                    $volumeReferences[$key].Add([string]$run.runId)
                }
                if ($drive.hostPath) {
                    $hostBindings.Add([PSCustomObject]@{
                        Provider=$provider; RunId=[string]$run.runId; Name=[string]$drive.id; Path=[string]$drive.hostPath
                        Class=if ([string]$drive.containerPath -match '/backup$') { 'BACKUP_WORKSPACE' } else { 'INSTANCE_STORE' }
                        Persistence=[string]$drive.persistence; InventoryKey=$null
                    })
                }
            }
            if ($instance.persistentStorage) {
                foreach ($property in @('hostPath','root','backupHostPath','vhdxPath')) {
                    if (-not $instance.persistentStorage.PSObject.Properties[$property] -or -not $instance.persistentStorage.$property) { continue }
                    $hostBindings.Add([PSCustomObject]@{
                        Provider=$provider; RunId=[string]$run.runId; Name="persistentStorage.$property"
                        Path=[string]$instance.persistentStorage.$property
                        Class=if ($property -eq 'backupHostPath') { 'BACKUP_WORKSPACE' } else { 'INSTANCE_STORE' }
                        Persistence='declared-persistent-storage'
                        InventoryKey=if ($provider -eq 'hyperv' -and $property -eq 'hostPath' -and
                            $instance.persistentStorage.locationId -and $instance.persistentStorage.relativePath) {
                            "hyperv-instance-store|$([string]$Configuration.ControllerId)|$([string]$instance.persistentStorage.locationId)|$([string]$instance.persistentStorage.relativePath)"
                        } else { $null }
                    })
                }
            }
        }
    }

    $stateRelation = Get-LabStoragePathRelation -Path $StateRoot -KnownRoots $knownRoots
    $objects.Add((New-LabStorageResidencyObject -Key "control-state|$StateRoot" -ObjectClass CONTROL_STATE -Provider core `
        -Lifecycle CONTROLLER -Residency $(if ($stateRelation -eq 'INSIDE') { 'LAB_DATA' } else { 'EXTERNAL_HOST' }) `
        -PathVisibility HOST_VISIBLE -LabDataRelation $stateRelation -LogicalName 'StateRoot' -Path $StateRoot `
        -CleanupPolicy REPORT_ONLY -AuditStatus $(if (Test-Path -LiteralPath $StateRoot -PathType Container) { 'VERIFIED' } else { 'UNVERIFIABLE' })))

    foreach ($root in @($DataRoots)) {
        $status = if ($root.Exists -and $root.Owned) { 'VERIFIED' } else { 'UNVERIFIABLE' }
        $objects.Add((New-LabStorageResidencyObject -Key "lab-data-root|$([string]$root.VolumeId)" -ObjectClass LAB_DATA_ROOT -Provider core `
            -Lifecycle CONTROLLER -Residency LAB_DATA -PathVisibility HOST_VISIBLE -LabDataRelation INSIDE `
            -LogicalName ([string]$root.DriveLetter) -Path ([string]$root.LabDataRoot) -CleanupPolicy REPORT_ONLY -AuditStatus $status `
            -Details @{ LocationId=if ($root.PSObject.Properties['LocationId']) { [string]$root.LocationId } else { $null }; FileCount=[int]$root.FileCount; TotalBytes=[long]$root.TotalBytes }))
    }

    foreach ($location in @($Configuration.LabDataLocations)) {
        $root = [string]$location.LabDataRoot
        if (-not $root -or -not (Test-LabDataRootOwnership -DataRoot $root -ControllerId ([string]$Configuration.ControllerId))) { continue }
        $paths = Get-LabBackupLibraryPaths -DataRoot $root
        try { $library = Get-LabBackupLibraryDocument -Paths $paths }
        catch { $library = $null }
        foreach ($backup in @($library.Backups)) {
            $objectPath = Join-Path $paths.LibraryRoot ([string]$backup.Artifact.RelativePath)
            $exists = Test-Path -LiteralPath $objectPath -PathType Leaf
            $sizeMatches = $exists -and (Get-Item -LiteralPath $objectPath).Length -eq [long]$backup.Artifact.Bytes
            $auditStatus = if ([string]$backup.Status -eq 'REUSABLE' -and $sizeMatches) { 'VERIFIED' } else { 'UNVERIFIABLE' }
            $provider = ([string]$backup.Source.Provider).ToLowerInvariant()
            if ($provider -notin @('docker','podman','hyperv')) { $provider = 'external' }
            $objects.Add((New-LabStorageResidencyObject `
                -Key "backup-set|$([string]$Configuration.ControllerId)|$([string]$backup.BackupSetId)" `
                -ObjectClass BACKUP_SET -Provider $provider -Lifecycle RETAINED -Residency LAB_DATA `
                -PathVisibility HOST_VISIBLE -LabDataRelation INSIDE -LogicalName ([string]$backup.BackupSetId) `
                -Path $objectPath -RunIds @([string]$backup.Source.RunId) -CleanupPolicy PRESERVE_RETAINED `
                -AuditStatus $auditStatus -Details @{
                    LocationId=[string]$location.LocationId; DatabaseName=[string]$backup.DatabaseName
                    Bytes=[long]$backup.Artifact.Bytes; LibraryStatus=[string]$backup.Status
                }))
        }
        $packagePaths = Get-LabDatabasePackagePaths -DataRoot $root
        try { $packageLibrary = Get-LabDatabasePackageDocument -Paths $packagePaths }
        catch { $packageLibrary = $null }
        foreach ($package in @($packageLibrary.Packages)) {
            $objectPath = Join-Path $packagePaths.ObjectsRoot ([string]$package.ManifestSha256)
            $objectsPresent = (Test-Path -LiteralPath $objectPath -PathType Container) -and
                @($package.Objects | Where-Object {
                    -not (Test-Path -LiteralPath (Join-Path $objectPath ([string]$_.RelativePath)) -PathType Leaf)
                }).Count -eq 0
            $auditStatus = if ([string]$package.Status -eq 'REUSABLE' -and $objectsPresent) { 'VERIFIED' } else { 'UNVERIFIABLE' }
            $provider = ([string]$package.Source.Provider).ToLowerInvariant()
            if ($provider -notin @('docker','podman','hyperv')) { $provider = 'external' }
            $objects.Add((New-LabStorageResidencyObject `
                -Key "database-package|$([string]$Configuration.ControllerId)|$([string]$package.DatabasePackageId)" `
                -ObjectClass DATABASE_PACKAGE -Provider $provider -Lifecycle RETAINED -Residency LAB_DATA `
                -PathVisibility HOST_VISIBLE -LabDataRelation INSIDE -LogicalName ([string]$package.DatabasePackageId) `
                -Path $objectPath -RunIds @([string]$package.Source.RunId) -CleanupPolicy PRESERVE_RETAINED `
                -AuditStatus $auditStatus -Details @{
                    LocationId=[string]$location.LocationId; DatabaseName=[string]$package.DatabaseName
                    ObjectCount=@($package.Objects).Count; LibraryStatus=[string]$package.Status
                }))
        }
    }

    foreach ($store in @($PersistentStorageStores | Where-Object StorageClass -eq 'EXCHANGE_WORKSPACE')) {
        $activeArtifactReferences = @($store.References | Where-Object {
            [string]$_.Kind -eq 'ARTIFACT' -and [string]$_.State -eq 'ACTIVE'
        })
        $workspaceId = if ($activeArtifactReferences.Count -eq 1) {
            [string]$activeArtifactReferences[0].TargetId
        }
        else { [string]$store.PersistentStorageId }
        $locations = @($Configuration.LabDataLocations | Where-Object {
            [string]$_.LocationId -eq [string]$store.LocationBinding.LocationId
        })
        $path = $null; $pathValid = $false; $fileCount = 0; $totalBytes = [long]0
        if ($locations.Count -eq 1 -and $store.LocationBinding.RelativePath) {
            $path = Join-Path ([string]$locations[0].LabDataRoot) (([string]$store.LocationBinding.RelativePath).Replace('/',[IO.Path]::DirectorySeparatorChar))
            $containment = Test-LabPathWithinRoot -Root ([string]$locations[0].LabDataRoot) -Path $path
            $pathValid = $containment.Valid -and (Test-Path -LiteralPath $path -PathType Container)
            if ($pathValid) {
                $files = @(Get-ChildItem -LiteralPath $path -File -Recurse -Force -ErrorAction SilentlyContinue)
                $fileCount = $files.Count
                $totalBytes = [long](($files | Measure-Object Length -Sum).Sum)
            }
        }
        $expectedObjectId = Get-LabStorageResidencyObjectId -Key "exchange-workspace|$([string]$Configuration.ControllerId)|$workspaceId"
        $identityValid = [string]$store.Provider -eq 'core' -and
            [string]$store.LocationBinding.Residency -eq 'LAB_DATA' -and
            [string]$store.LocationBinding.InventoryObjectId -eq $expectedObjectId
        $objects.Add((New-LabStorageResidencyObject `
            -Key "exchange-workspace|$([string]$Configuration.ControllerId)|$workspaceId" `
            -ObjectClass EXCHANGE_WORKSPACE -Provider core -Lifecycle RETAINED -Residency LAB_DATA `
            -PathVisibility HOST_VISIBLE -LabDataRelation $(if ($pathValid) { 'INSIDE' } else { 'UNKNOWN' }) `
            -LogicalName ([string]$store.DisplayName) -Path $path -CleanupPolicy PRESERVE_RETAINED `
            -AuditStatus $(if ($pathValid -and $identityValid) { 'VERIFIED' } else { 'UNVERIFIABLE' }) `
            -Details @{ PersistentStorageId=[string]$store.PersistentStorageId; WorkspaceId=$workspaceId; FileCount=$fileCount; TotalBytes=$totalBytes }))
    }

    $seenHostBindings = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($binding in @($hostBindings)) {
        $key = "$([string]$binding.Provider)|$([string]$binding.Path)|$([string]$binding.RunId)"
        if (-not $seenHostBindings.Add($key)) { continue }
        $objectKey = if ($binding.InventoryKey) { [string]$binding.InventoryKey } else { "host-binding|$key" }
        $relation = Get-LabStoragePathRelation -Path ([string]$binding.Path) -KnownRoots $knownRoots
        $residency = if ($relation -eq 'INSIDE') { 'LAB_DATA' } elseif ($relation -eq 'OUTSIDE') { 'EXTERNAL_HOST' } else { 'UNKNOWN' }
        $objects.Add((New-LabStorageResidencyObject -Key $objectKey -ObjectClass ([string]$binding.Class) `
            -Provider $(if ([string]$binding.Provider -in @('docker','podman','hyperv')) { [string]$binding.Provider } else { 'external' }) `
            -Lifecycle $(if ([string]$binding.Persistence -match 'persistent|data-root') { 'RETAINED' } else { 'RUN_SCOPED' }) `
            -Residency $residency -PathVisibility HOST_VISIBLE -LabDataRelation $relation -LogicalName ([string]$binding.Name) `
            -Path ([string]$binding.Path) -RunIds @([string]$binding.RunId) `
            -CleanupPolicy $(if ([string]$binding.Persistence -match 'persistent|data-root') { 'PRESERVE_RETAINED' } else { 'RUN_CLEANUP' }) `
            -AuditStatus $(if ($relation -eq 'UNKNOWN') { 'UNVERIFIABLE' } else { 'DECLARED' }) `
            -Details @{ Persistence=[string]$binding.Persistence }))
    }

    foreach ($runtime in @($RuntimeResults)) {
        $provider = ([string]$runtime.Provider).ToLowerInvariant()
        if ($provider -notin @('docker','podman')) { continue }
        $rootPath = if ([string]$runtime.Status -eq 'AVAILABLE') { Get-LabRuntimeStorageRoot -Provider $provider } else { $null }
        $relation = Get-LabStoragePathRelation -Path $rootPath -KnownRoots $knownRoots -RuntimeNamespace
        $objects.Add((New-LabStorageResidencyObject -Key "runtime-root|$provider" -ObjectClass RUNTIME_BACKING_STORE -Provider $provider `
            -Lifecycle SHARED -Residency NATIVE_RUNTIME -PathVisibility RUNTIME_NAMESPACE -LabDataRelation $relation `
            -LogicalName "$provider runtime storage" -Path $rootPath -CleanupPolicy REPORT_ONLY `
            -AuditStatus $(if ($rootPath) { 'DECLARED' } else { 'UNVERIFIABLE' }) `
            -Details @{ RuntimeStatus=[string]$runtime.Status; PhysicalHostBacking=if ($rootPath) { 'RUNTIME_NAMESPACE_ONLY' } else { 'NOT_EXPOSED_BY_RUNTIME_API' } }))
    }

    foreach ($backing in @($RuntimeHostBackings)) {
        foreach ($item in @($backing.Items)) {
            $objectClass = if ([string]$item.Kind -eq 'CONFIGURATION') { 'RUNTIME_CONFIGURATION' } else { 'RUNTIME_BACKING_STORE' }
            $relation = [string]$item.LabDataRelation
            $objects.Add((New-LabStorageResidencyObject `
                -Key "runtime-host-backing|$([string]$backing.Provider)|$([string]$backing.RuntimeId)|$([string]$item.Path)" `
                -ObjectClass $objectClass -Provider ([string]$backing.Provider) -Lifecycle SHARED `
                -Residency $(if ($relation -eq 'INSIDE') { 'LAB_DATA' } elseif ($relation -eq 'OUTSIDE') { 'EXTERNAL_HOST' } else { 'UNKNOWN' }) `
                -PathVisibility HOST_VISIBLE -LabDataRelation $relation -LogicalName ([IO.Path]::GetFileName([string]$item.Path)) `
                -Path ([string]$item.Path) -CleanupPolicy REPORT_ONLY -AuditStatus VERIFIED `
                -Details @{ RuntimeId=[string]$backing.RuntimeId; Role=[string]$item.Role; Bytes=$item.Bytes; LastWriteTimeUtc=([datetime]$item.LastWriteTimeUtc).ToString('o'); Ownership='SHARED_EXTERNAL' }))
        }
        if (@($backing.Items | Where-Object Kind -eq 'BACKING_STORE').Count -eq 0) {
            $remote = [string]$backing.Status -eq 'REMOTE_EXTERNAL'
            $objects.Add((New-LabStorageResidencyObject `
                -Key "runtime-host-backing|$([string]$backing.Provider)|$([string]$backing.RuntimeId)|unresolved" `
                -ObjectClass RUNTIME_BACKING_STORE -Provider ([string]$backing.Provider) -Lifecycle SHARED `
                -Residency $(if ($remote) { 'EXTERNAL_HOST' } else { 'UNKNOWN' }) `
                -PathVisibility $(if ($remote) { 'NOT_APPLICABLE' } else { 'UNKNOWN' }) -LabDataRelation UNKNOWN `
                -LogicalName "$([string]$backing.Provider) physical runtime backing" -Path $null `
                -CleanupPolicy REPORT_ONLY -AuditStatus $(if ($remote) { 'DECLARED' } else { 'UNVERIFIABLE' }) `
                -Details @{ RuntimeId=[string]$backing.RuntimeId; BackingStatus=[string]$backing.Status; Ownership='SHARED_EXTERNAL' }))
        }
    }

    $usageClasses = @{ IMAGES='RUNTIME_IMAGE_STORE'; CONTAINERS='RUNTIME_CONTAINER_STORE'; LOCAL_VOLUMES='RUNTIME_VOLUME_STORE'; BUILD_CACHE='RUNTIME_BUILD_CACHE' }
    foreach ($usage in @($RuntimeStorageUsage)) {
        if (-not $usageClasses.ContainsKey([string]$usage.Category)) { continue }
        $objects.Add((New-LabStorageResidencyObject `
            -Key "runtime-usage|$([string]$usage.Provider)|$([string]$usage.Category)" `
            -ObjectClass ([string]$usageClasses[[string]$usage.Category]) -Provider ([string]$usage.Provider) -Lifecycle SHARED `
            -Residency NATIVE_RUNTIME -PathVisibility RUNTIME_NAMESPACE -LabDataRelation RUNTIME_INTERNAL `
            -LogicalName "$([string]$usage.Provider) $([string]$usage.Category.ToLowerInvariant())" -Path $null `
            -CleanupPolicy REPORT_ONLY -AuditStatus $(if ([string]$usage.Status -eq 'UNVERIFIABLE') { 'UNVERIFIABLE' } else { 'DECLARED' }) `
            -Details @{ Status=[string]$usage.Status; TotalCount=[int]$usage.TotalCount; ActiveCount=[int]$usage.ActiveCount; ReportedSize=[string]$usage.ReportedSize; ReportedReclaimable=[string]$usage.ReportedReclaimable; RawSizeBytes=$usage.RawSizeBytes; RawReclaimableBytes=$usage.RawReclaimableBytes }))
    }

    foreach ($image in @($ManagedImages)) {
        $objects.Add((New-LabStorageResidencyObject `
            -Key "runtime-image|$([string]$image.Provider)|$([string]$image.RuntimeImageId)" `
            -ObjectClass RUNTIME_IMAGE -Provider ([string]$image.Provider) -Lifecycle SHARED `
            -Residency NATIVE_RUNTIME -PathVisibility RUNTIME_NAMESPACE -LabDataRelation RUNTIME_INTERNAL `
            -LogicalName ([string]$image.Reference) -Path $null -CleanupPolicy PRESERVE_SHARED -AuditStatus VERIFIED `
            -Details @{ RuntimeImageId=[string]$image.RuntimeImageId; ImageKey=[string]$image.ImageKey; ReportedSize=[string]$image.ReportedSize; CreatedAt=[string]$image.CreatedAt }))
    }

    foreach ($volume in @($ManagedVolumes)) {
        $provider = ([string]$volume.Provider).ToLowerInvariant(); $name = [string]$volume.Name
        $inspection = Get-LabRuntimeVolumeInspection -Provider $provider -Name $name
        $referenceKey = "$provider|$name"; $runIds = if ($volumeReferences.ContainsKey($referenceKey)) { @($volumeReferences[$referenceKey]) } else { @() }
        $persistent = $name -match '^sql-lab-persistent-'
        $relation = if ($inspection) { Get-LabStoragePathRelation -Path ([string]$inspection.Mountpoint) -KnownRoots $knownRoots -RuntimeNamespace } else { 'UNKNOWN' }
        $referenceState = if ($runIds.Count -gt 0) { 'ACTIVE_REFERENCE' } elseif ($persistent) { 'RETAINED_UNBOUND' } else { 'ORPHAN_CANDIDATE' }
        $auditStatus = if (-not $inspection) { 'UNVERIFIABLE' } elseif ($referenceState -eq 'ORPHAN_CANDIDATE') { 'RESIDUAL' } else { 'VERIFIED' }
        $objects.Add((New-LabStorageResidencyObject -Key "runtime-volume|$provider|$name" -ObjectClass INSTANCE_STORE -Provider $provider `
            -Lifecycle $(if ($persistent) { 'RETAINED' } else { 'RUN_SCOPED' }) -Residency NATIVE_RUNTIME `
            -PathVisibility RUNTIME_NAMESPACE -LabDataRelation $relation -LogicalName $name `
            -Path $(if ($inspection) { [string]$inspection.Mountpoint } else { $null }) -RunIds $runIds `
            -CleanupPolicy $(if ($persistent) { 'PRESERVE_RETAINED' } else { 'RUN_CLEANUP' }) -AuditStatus $auditStatus `
            -Details @{ ReferenceState=$referenceState; DeclaredRunId=if ($inspection) { [string]$inspection.RunId } else { $null }; DeclaredScopeId=if ($inspection) { [string]$inspection.ScopeId } else { $null } }))
    }

    $seenHyperVPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($scope in @($HyperVRunScopes)) {
        foreach ($resource in @($scope.CleanupResources)) {
            $relation = Get-LabStoragePathRelation -Path ([string]$resource.Path) -KnownRoots $knownRoots
            if ($resource.Path) { $null = $seenHyperVPaths.Add([string]$resource.Path) }
            $objects.Add((New-LabStorageResidencyObject -Key "hyperv-run|$([string]$scope.RunId)|$([string]$resource.Path)" `
                -ObjectClass HYPERV_RUN_RESOURCE -Provider hyperv -Lifecycle RUN_SCOPED `
                -Residency $(if ($relation -eq 'INSIDE') { 'LAB_DATA' } elseif ($relation -eq 'OUTSIDE') { 'EXTERNAL_HOST' } else { 'UNKNOWN' }) `
                -PathVisibility HOST_VISIBLE -LabDataRelation $relation -LogicalName ([IO.Path]::GetFileName([string]$resource.Path)) `
                -Path ([string]$resource.Path) -RunIds @([string]$scope.RunId) -CleanupPolicy RUN_CLEANUP `
                -AuditStatus $(if ([string]$resource.ProtectionStatus -eq 'PROTECTED') { 'VERIFIED' } else { 'UNVERIFIABLE' }) `
                -Details @{ ProtectionStatus=[string]$resource.ProtectionStatus; State=[string]$resource.State; ScopeKind=[string]$resource.ScopeKind }))
        }
    }
    foreach ($resource in @($HyperVResources)) {
        foreach ($binding in @($resource.StorageBindings)) {
            if (-not $binding.Path -or -not $seenHyperVPaths.Add([string]$binding.Path)) { continue }
            $relation = Get-LabStoragePathRelation -Path ([string]$binding.Path) -KnownRoots $knownRoots
            $hasRun = -not [string]::IsNullOrWhiteSpace([string]$resource.RunId)
            $objects.Add((New-LabStorageResidencyObject -Key "hyperv-runtime|$([string]$resource.RunId)|$([string]$binding.ResourceKind)|$([string]$binding.Path)" `
                -ObjectClass HYPERV_RUN_RESOURCE -Provider hyperv `
                -Lifecycle $(if ($hasRun) { 'RUN_SCOPED' } else { 'UNMANAGED_OR_UNKNOWN' }) `
                -Residency $(if ($relation -eq 'INSIDE') { 'LAB_DATA' } elseif ($relation -eq 'OUTSIDE') { 'EXTERNAL_HOST' } else { 'UNKNOWN' }) `
                -PathVisibility HOST_VISIBLE -LabDataRelation $relation -LogicalName ([string]$binding.ResourceKind) `
                -Path ([string]$binding.Path) -RunIds $(if ($hasRun) { @([string]$resource.RunId) } else { @() }) `
                -CleanupPolicy REPORT_ONLY `
                -AuditStatus $(if ([string]$resource.StorageStatus -ne 'VERIFIED' -or $relation -eq 'UNKNOWN') { 'UNVERIFIABLE' } elseif ($resource.Orphan) { 'RESIDUAL' } else { 'VERIFIED' }) `
                -Details @{ ResourceKind=[string]$binding.ResourceKind; VmState=[string]$resource.State; Orphan=[bool]$resource.Orphan }))
        }
    }
    foreach ($root in @($HyperVSharedRoots)) {
        $relation = Get-LabStoragePathRelation -Path ([string]$root.Path) -KnownRoots $knownRoots
        $objects.Add((New-LabStorageResidencyObject -Key "hyperv-shared|$([string]$root.ResourceClass)|$([string]$root.Path)" `
            -ObjectClass HYPERV_SHARED_RESOURCE -Provider hyperv -Lifecycle SHARED `
            -Residency $(if ($relation -eq 'INSIDE') { 'LAB_DATA' } elseif ($relation -eq 'OUTSIDE') { 'EXTERNAL_HOST' } else { 'UNKNOWN' }) `
            -PathVisibility HOST_VISIBLE -LabDataRelation $relation -LogicalName ([string]$root.ResourceClass) -Path ([string]$root.Path) `
            -CleanupPolicy PRESERVE_SHARED -AuditStatus $(if ($root.Exists) { 'VERIFIED' } else { 'DECLARED' }) `
            -Details @{ RootKind=[string]$root.RootKind; FileCount=[int]$root.FileCount }))
    }
    foreach ($file in @($HyperVUntrackedFiles)) {
        $relation = Get-LabStoragePathRelation -Path ([string]$file.Path) -KnownRoots $knownRoots
        $objects.Add((New-LabStorageResidencyObject -Key "hyperv-untracked|$([string]$file.RunId)|$([string]$file.Path)" `
            -ObjectClass HYPERV_RUN_RESOURCE -Provider hyperv -Lifecycle UNMANAGED_OR_UNKNOWN `
            -Residency $(if ($relation -eq 'INSIDE') { 'LAB_DATA' } elseif ($relation -eq 'OUTSIDE') { 'EXTERNAL_HOST' } else { 'UNKNOWN' }) `
            -PathVisibility HOST_VISIBLE -LabDataRelation $relation -LogicalName ([IO.Path]::GetFileName([string]$file.Path)) `
            -Path ([string]$file.Path) -RunIds @([string]$file.RunId) -CleanupPolicy REPORT_ONLY -AuditStatus RESIDUAL `
            -Details @{ Preservation=[string]$file.Preservation; RootKind=[string]$file.RootKind }))
    }

    foreach ($reference in @($ExternalReferences)) {
        $objects.Add((New-LabStorageResidencyObject -Key "external|$([string]$reference.RunId)|$([string]$reference.Path)" `
            -ObjectClass EXTERNAL_REFERENCE -Provider external -Lifecycle UNMANAGED_OR_UNKNOWN -Residency EXTERNAL_HOST `
            -PathVisibility HOST_VISIBLE -LabDataRelation OUTSIDE -LogicalName 'External run reference' -Path ([string]$reference.Path) `
            -RunIds @([string]$reference.RunId) -CleanupPolicy REPORT_ONLY -AuditStatus RESIDUAL))
    }
    foreach ($residue in @($RepositoryResidues)) {
        $objects.Add((New-LabStorageResidencyObject -Key "repository|$([string]$residue.Path)" -ObjectClass REPOSITORY_RESIDUE `
            -Provider core -Lifecycle UNMANAGED_OR_UNKNOWN -Residency REPOSITORY -PathVisibility HOST_VISIBLE -LabDataRelation OUTSIDE `
            -LogicalName 'Repository residue' -Path ([string]$residue.Path) -CleanupPolicy REPORT_ONLY -AuditStatus RESIDUAL `
            -Details @{ FileCount=[int]$residue.FileCount }))
    }
    foreach ($legacy in @($LegacyStateRoots)) {
        $objects.Add((New-LabStorageResidencyObject -Key "legacy|$([string]$legacy.Path)" -ObjectClass LEGACY_STATE -Provider core `
            -Lifecycle UNMANAGED_OR_UNKNOWN -Residency LEGACY_PROFILE -PathVisibility HOST_VISIBLE -LabDataRelation OUTSIDE `
            -LogicalName 'Legacy state root' -Path ([string]$legacy.Path) -CleanupPolicy REPORT_ONLY `
            -AuditStatus $(if ([int]$legacy.RunCount -gt 0) { 'RESIDUAL' } else { 'DECLARED' }) -Details @{ RunCount=[int]$legacy.RunCount }))
    }

    $coverage = @(
        [PSCustomObject]@{ Provider='core'; Status='AVAILABLE' }
        @($RuntimeResults | ForEach-Object { [PSCustomObject]@{ Provider=[string]$_.Provider; Status=[string]$_.Status } })
        [PSCustomObject]@{ Provider='hyperv'; Status=$HyperVStatus }
    )
    $objectArray = @($objects)
    $unverifiableCount = @($objectArray | Where-Object AuditStatus -eq 'UNVERIFIABLE').Count
    $unavailableProviderCount = @($coverage | Where-Object Status -in @('UNAVAILABLE','NOT_INSTALLED')).Count
    [PSCustomObject]@{
        ContractVersion='SqlServerLab.StorageResidencyInventory/1.0'
        Status=if ($unverifiableCount -gt 0 -or $unavailableProviderCount -gt 0) { 'PARTIAL' } else { 'COMPLETE' }
        ProviderCoverage=$coverage
        Objects=$objectArray
        Summary=[PSCustomObject]@{
            ObjectCount=$objectArray.Count
            LabDataObjects=@($objectArray | Where-Object LabDataRelation -eq 'INSIDE').Count
            NativeRuntimeObjects=@($objectArray | Where-Object Residency -eq 'NATIVE_RUNTIME').Count
            ExternalObjects=@($objectArray | Where-Object LabDataRelation -eq 'OUTSIDE').Count
            RetainedObjects=@($objectArray | Where-Object Lifecycle -eq 'RETAINED').Count
            RunScopedObjects=@($objectArray | Where-Object Lifecycle -eq 'RUN_SCOPED').Count
            ResidualObjects=@($objectArray | Where-Object AuditStatus -eq 'RESIDUAL').Count
            UnverifiableObjects=$unverifiableCount
        }
    }
}
