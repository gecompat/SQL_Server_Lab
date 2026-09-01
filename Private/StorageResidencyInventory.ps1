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
        [Parameter(Mandatory)][ValidateSet('CONTROL_STATE','LAB_DATA_ROOT','INSTANCE_STORE','BACKUP_WORKSPACE','RUNTIME_BACKING_STORE','HYPERV_RUN_RESOURCE','HYPERV_SHARED_RESOURCE','EXTERNAL_REFERENCE','REPOSITORY_RESIDUE','LEGACY_STATE')][string]$ObjectClass,
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
    $output = @(& $Provider info --format $template 2>$null | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
    if ($LASTEXITCODE -ne 0 -or $output.Count -ne 1) { return $null }
    return [string]$output[0]
}

function Get-LabRuntimeVolumeInspection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('docker','podman')][string]$Provider,
        [Parameter(Mandatory)][string]$Name
    )

    $raw = @(& $Provider volume inspect $Name 2>$null)
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

function Get-LabStorageResidencyInventory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Configuration,
        [Parameter(Mandatory)][string]$StateRoot,
        [AllowEmptyCollection()][object[]]$DataRoots = @(),
        [AllowEmptyCollection()][object[]]$ActiveRuns = @(),
        [AllowEmptyCollection()][object[]]$RuntimeResults = @(),
        [AllowEmptyCollection()][object[]]$ManagedVolumes = @(),
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
                        Persistence=[string]$drive.persistence
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

    $seenHostBindings = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($binding in @($hostBindings)) {
        $key = "$([string]$binding.Provider)|$([string]$binding.Path)|$([string]$binding.RunId)"
        if (-not $seenHostBindings.Add($key)) { continue }
        $relation = Get-LabStoragePathRelation -Path ([string]$binding.Path) -KnownRoots $knownRoots
        $residency = if ($relation -eq 'INSIDE') { 'LAB_DATA' } elseif ($relation -eq 'OUTSIDE') { 'EXTERNAL_HOST' } else { 'UNKNOWN' }
        $objects.Add((New-LabStorageResidencyObject -Key "host-binding|$key" -ObjectClass ([string]$binding.Class) `
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
