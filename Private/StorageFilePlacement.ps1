<#
.SYNOPSIS
    Bindet portable SQL-Storage-Intents an lokale Locations, Geräte und Gastpfade.
#>

function ConvertTo-LabStorageCanonicalValue {
    [CmdletBinding()]
    param([Parameter(Mandatory, ValueFromPipeline)]$InputObject)

    process {
        if ($null -eq $InputObject) { return $null }
        if ($InputObject -is [string] -or $InputObject -is [ValueType]) { return $InputObject }
        if ($InputObject -is [Collections.IDictionary]) {
            $ordered = [ordered]@{}
            foreach ($key in @($InputObject.Keys | ForEach-Object { [string]$_ } | Sort-Object)) {
                $ordered[$key] = ConvertTo-LabStorageCanonicalValue -InputObject $InputObject[$key]
            }
            return [PSCustomObject]$ordered
        }
        if ($InputObject -is [Collections.IEnumerable]) {
            return @($InputObject | ForEach-Object { ConvertTo-LabStorageCanonicalValue -InputObject $_ })
        }
        $properties = @($InputObject.PSObject.Properties | Where-Object MemberType -in @('NoteProperty', 'Property') | Sort-Object Name)
        $ordered = [ordered]@{}
        foreach ($property in $properties) {
            $ordered[$property.Name] = ConvertTo-LabStorageCanonicalValue -InputObject $property.Value
        }
        return [PSCustomObject]$ordered
    }
}

function Get-LabStorageIntentSha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$StorageIntent)

    $canonicalJson = ConvertTo-LabStorageCanonicalValue -InputObject $StorageIntent | ConvertTo-Json -Depth 40 -Compress
    $bytes = [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($canonicalJson))
    return [Convert]::ToHexString($bytes).ToLowerInvariant()
}

function Assert-LabStorageIntent {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$StorageIntent)

    $schemaPath = Join-Path $script:SchemasPath 'lab-storage-intent.schema.json'
    $json = $StorageIntent | ConvertTo-Json -Depth 40
    if (-not ($json | Test-Json -SchemaFile $schemaPath -ErrorAction SilentlyContinue)) {
        throw 'LAB_STORAGE_INTENT_SCHEMA_INVALID'
    }
    $tempDb = $StorageIntent.TempDb
    $distribution = [string]$tempDb.Distribution
    $count = [int]$tempDb.DataFileCount
    $selectors = @($tempDb.DataLocationSelectors)
    if ($distribution -eq 'single-location' -and $selectors.Count -ne 1) {
        throw 'LAB_STORAGE_INTENT_SINGLE_LOCATION_REQUIRES_ONE_SELECTOR'
    }
    if ($distribution -eq 'explicit') {
        if (@($tempDb.DataFiles).Count -ne $count) { throw 'LAB_STORAGE_INTENT_EXPLICIT_FILE_COUNT_MISMATCH' }
        $unknownSelectors = @($tempDb.DataFiles | Where-Object { [string]$_.Selector -notin $selectors })
        if ($unknownSelectors.Count -gt 0) { throw 'LAB_STORAGE_INTENT_EXPLICIT_SELECTOR_NOT_DECLARED' }
    }
    if ($distribution -in @('one-file-per-volume', 'one-file-per-physical-device') -and $selectors.Count -lt $count) {
        throw 'LAB_STORAGE_INTENT_DISTINCT_SELECTOR_COUNT_INSUFFICIENT'
    }
    $minimumPhysicalDeviceProperty = $tempDb.PSObject.Properties['MinimumPhysicalDeviceCount']
    if ($minimumPhysicalDeviceProperty) {
        $minimumPhysicalDeviceCount = [int]$minimumPhysicalDeviceProperty.Value
        if ($minimumPhysicalDeviceCount -gt $count) {
            throw 'LAB_STORAGE_INTENT_MINIMUM_PHYSICAL_DEVICE_COUNT_EXCEEDS_FILE_COUNT'
        }
        if ($minimumPhysicalDeviceCount -gt $selectors.Count) {
            throw 'LAB_STORAGE_INTENT_MINIMUM_PHYSICAL_DEVICE_COUNT_EXCEEDS_SELECTOR_COUNT'
        }
    }
    return $true
}

function Get-LabStorageGuestChildPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root, [string]$Child)

    if (-not $Child) { return $Root }
    if ($Root -match '^[A-Za-z]:\\') { return "$($Root.TrimEnd('\'))\$($Child.TrimStart('\'))" }
    return "$($Root.TrimEnd('/'))/$($Child.TrimStart('/'))"
}

function Get-LabStorageBindingRuntimeSizeBytes {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$SqlFiles)

    $explicitSizeMB = [long](($SqlFiles | Where-Object { $null -ne $_.SizeMB } | Measure-Object SizeMB -Sum).Sum)
    $hasOpenEndedRole = @($SqlFiles | Where-Object Role -in @(
        'default-data','default-log','backup','database-data','database-log','restore-data-rule','restore-log-rule'
    )).Count -gt 0
    $minimumBytes = if ($hasOpenEndedRole) { [long]32GB } else { [long]4GB }
    $requiredBytes = [long][Math]::Ceiling(([double]($explicitSizeMB + 1024) * 1MB) / 1GB) * 1GB
    return [long][Math]::Max([double]$minimumBytes, [double]$requiredBytes)
}

function New-LabStorageBoundPlan {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification='Erzeugt ausschließlich einen in-memory Bound Plan.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$StorageIntent,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F-]{36}$')][string]$RunId,
        [Parameter(Mandatory)][string]$LabName,
        [Parameter(Mandatory)][string]$InstanceId,
        [Parameter(Mandatory)][ValidateSet('docker', 'podman', 'hyperv')][string]$Provider,
        $StorageConfiguration
    )

    $null = Assert-LabStorageIntent -StorageIntent $StorageIntent
    if (-not $StorageConfiguration) { $StorageConfiguration = Get-LabStorageConfiguration }
    if (-not $StorageConfiguration.ControllerId -or @($StorageConfiguration.LabDataLocations).Count -eq 0) {
        throw 'LAB_STORAGE_CONFIGURATION_REQUIRED'
    }

    $blockers = [Collections.Generic.List[string]]::new()
    $selectorNames = [Collections.Generic.List[string]]::new()
    foreach ($roleName in @('DefaultData', 'DefaultLog', 'Backup')) {
        $role = $StorageIntent.Roles.PSObject.Properties[$roleName].Value
        if ($role -and $role.Selector -and [string]$role.Selector -notin $selectorNames) { $selectorNames.Add([string]$role.Selector) }
    }
    foreach ($selector in @($StorageIntent.TempDb.DataLocationSelectors) + @([string]$StorageIntent.TempDb.LogPlacement.Selector) +
        @($StorageIntent.DatabaseFiles | ForEach-Object { [string]$_.Selector }) +
        @($StorageIntent.RestoreRules | ForEach-Object { @([string]$_.DataSelector, [string]$_.LogSelector) })) {
        if ($selector -and $selector -notin $selectorNames) { $selectorNames.Add($selector) }
    }

    $locationsBySelector = @{}
    foreach ($selector in @($selectorNames | Sort-Object)) {
        $matches = if ($selector -eq 'default') {
            @($StorageConfiguration.LabDataLocations | Where-Object LocationId -eq [string]$StorageConfiguration.DefaultLocationId)
        }
        else {
            @($StorageConfiguration.LabDataLocations | Where-Object { @($_.Selectors) -contains $selector })
        }
        if ($matches.Count -eq 0) {
            $blockers.Add("SELECTOR_UNRESOLVED:$selector")
            continue
        }
        if ($matches.Count -gt 1) {
            $blockers.Add("SELECTOR_AMBIGUOUS:$selector")
            continue
        }
        $locationsBySelector[$selector] = $matches[0]
    }

    $guestLetters = @('T','U','V','W','X','Y','Z','P','Q','R','N','O','J','K','L','M','G','H','I')
    $safeLabName = ($LabName -replace '[^A-Za-z0-9_.-]', '-').Trim('-')
    $safeInstanceId = ($InstanceId -replace '[^A-Za-z0-9_.-]', '-').Trim('-')
    $bindings = [Collections.Generic.List[object]]::new()
    $bindingBySelector = @{}
    $bindingIndex = 0
    foreach ($selector in @($locationsBySelector.Keys | Sort-Object)) {
        $location = $locationsBySelector[$selector]
        $guestRoot = if ($Provider -eq 'hyperv') {
            if ($bindingIndex -ge $guestLetters.Count) {
                $blockers.Add('HYPERV_GUEST_DRIVE_LETTERS_EXHAUSTED')
                'UNASSIGNED'
            }
            else { "$($guestLetters[$bindingIndex]):\SQLLab" }
        }
        else { "/var/opt/mssql/lab-storage/lane-$('{0:d2}' -f ($bindingIndex + 1))" }
        $hostPath = Join-Path ([string]$location.LabDataRoot) "Labs/$safeLabName/Instances/$Provider/$safeInstanceId/Storage/$selector"
        $binding = [PSCustomObject]@{
            Selector = $selector; LocationId = [string]$location.LocationId; VolumeId = [string]$location.VolumeId
            BackingDeviceIds = @($location.BackingDeviceIds); TopologyStatus = [string]$location.TopologyStatus
            HostRoot = [string]$location.LabDataRoot; HostPath = $hostPath; GuestRoot = $guestRoot
            RuntimeStorageSizeBytes = [long]0
        }
        $bindings.Add($binding); $bindingBySelector[$selector] = $binding; $bindingIndex++
    }

    $sqlFiles = [Collections.Generic.List[object]]::new()
    function Add-SqlFileBinding {
        param(
            [string]$Role, [string]$Database, [string]$LogicalName, [AllowNull()][string]$FileName,
            [string]$Selector, [string]$Subdirectory, [AllowNull()][Nullable[int]]$SizeMB,
            [AllowNull()][string]$Growth
        )
        $binding = $bindingBySelector[$Selector]
        if (-not $binding) { return }
        $directory = Get-LabStorageGuestChildPath -Root ([string]$binding.GuestRoot) -Child $Subdirectory
        $guestPath = if ($FileName) { Get-LabStorageGuestChildPath -Root $directory -Child $FileName } else { $directory }
        $sqlFiles.Add([PSCustomObject]@{
            Role=$Role; Database=$(if ($Database) { $Database } else { $null }); LogicalName=$LogicalName
            FileName=$(if ($FileName) { $FileName } else { $null }); Selector=$Selector
            LocationId=[string]$binding.LocationId; GuestPath=$guestPath
            SizeMB=$(if ($null -ne $SizeMB) { [int]$SizeMB } else { $null })
            Growth=$(if ($Growth) { $Growth } else { $null })
        })
    }

    if ($StorageIntent.Roles.DefaultData) { Add-SqlFileBinding -Role 'default-data' -LogicalName 'INSTANCE_DEFAULT_DATA' -Selector ([string]$StorageIntent.Roles.DefaultData.Selector) -Subdirectory 'Data' }
    if ($StorageIntent.Roles.DefaultLog) { Add-SqlFileBinding -Role 'default-log' -LogicalName 'INSTANCE_DEFAULT_LOG' -Selector ([string]$StorageIntent.Roles.DefaultLog.Selector) -Subdirectory 'Log' }
    if ($StorageIntent.Roles.Backup) { Add-SqlFileBinding -Role 'backup' -LogicalName 'INSTANCE_DEFAULT_BACKUP' -Selector ([string]$StorageIntent.Roles.Backup.Selector) -Subdirectory 'Backup' }

    $tempDb = $StorageIntent.TempDb
    $dataFileSpecs = if ([string]$tempDb.Distribution -eq 'explicit') {
        @($tempDb.DataFiles)
    }
    else {
        @(
            for ($index = 0; $index -lt [int]$tempDb.DataFileCount; $index++) {
                $logicalName = if ($index -eq 0) { 'tempdev' } else { "temp$($index + 1)" }
                $fileName = if ($index -eq 0) { 'tempdev.mdf' } else { "temp$($index + 1).ndf" }
                [PSCustomObject]@{
                    LogicalName=$logicalName; FileName=$fileName
                    Selector=[string]@($tempDb.DataLocationSelectors)[$index % @($tempDb.DataLocationSelectors).Count]
                    SizeMB=256; Growth='64MB'
                }
            }
        )
    }
    foreach ($file in $dataFileSpecs) {
        Add-SqlFileBinding -Role 'tempdb-data' -LogicalName ([string]$file.LogicalName) -FileName ([string]$file.FileName) `
            -Selector ([string]$file.Selector) -Subdirectory 'TempDB' -SizeMB ([int]$file.SizeMB) -Growth ([string]$file.Growth)
    }
    $tempLog = $tempDb.LogPlacement
    Add-SqlFileBinding -Role 'tempdb-log' -LogicalName ([string]$tempLog.LogicalName) -FileName ([string]$tempLog.FileName) `
        -Selector ([string]$tempLog.Selector) -Subdirectory 'TempDBLog' -SizeMB ([int]$tempLog.SizeMB) -Growth ([string]$tempLog.Growth)

    foreach ($file in @($StorageIntent.DatabaseFiles)) {
        Add-SqlFileBinding -Role $(if ([string]$file.FileType -eq 'log') { 'database-log' } else { 'database-data' }) `
            -Database ([string]$file.Database) -LogicalName ([string]$file.LogicalName) -FileName ([string]$file.FileName) `
            -Selector ([string]$file.Selector) -Subdirectory $(if ([string]$file.FileType -eq 'log') { 'Log' } else { 'Data' })
    }
    foreach ($rule in @($StorageIntent.RestoreRules)) {
        Add-SqlFileBinding -Role 'restore-data-rule' -Database ([string]$rule.Database) -LogicalName 'RESTORE_DATA_FILES' `
            -Selector ([string]$rule.DataSelector) -Subdirectory 'Data'
        Add-SqlFileBinding -Role 'restore-log-rule' -Database ([string]$rule.Database) -LogicalName 'RESTORE_LOG_FILES' `
            -Selector ([string]$rule.LogSelector) -Subdirectory 'Log'
    }
    foreach ($binding in $bindings) {
        $binding.RuntimeStorageSizeBytes = Get-LabStorageBindingRuntimeSizeBytes `
            -SqlFiles @($sqlFiles | Where-Object { [string]$_.Selector -eq [string]$binding.Selector })
    }

    $tempBindings = @($dataFileSpecs | ForEach-Object { $bindingBySelector[[string]$_.Selector] } | Where-Object { $_ })
    $distinctVolumes = @($tempBindings.VolumeId | Sort-Object -Unique)
    $distribution = [string]$tempDb.Distribution
    if ($distribution -eq 'one-file-per-volume' -and $distinctVolumes.Count -ne [int]$tempDb.DataFileCount) {
        $blockers.Add('TEMPDB_DISTINCT_VOLUME_REQUIREMENT_NOT_MET')
    }
    $globalPhysicalIsolation = [string]$StorageIntent.PhysicalIsolation -eq 'required'
    $minimumPhysicalDeviceProperty = $tempDb.PSObject.Properties['MinimumPhysicalDeviceCount']
    $minimumPhysicalDeviceCount = if ($minimumPhysicalDeviceProperty) { [int]$minimumPhysicalDeviceProperty.Value } else { 0 }
    $strictTempPhysicalIsolation = $distribution -eq 'one-file-per-physical-device'
    $physicalRequested = $strictTempPhysicalIsolation -or $globalPhysicalIsolation -or $minimumPhysicalDeviceCount -gt 0
    $physicalBindings = if ($globalPhysicalIsolation) {
        @($bindings)
    }
    elseif ($strictTempPhysicalIsolation) {
        $tempBindings
    }
    else {
        @($tempBindings | Group-Object Selector | ForEach-Object { $_.Group[0] })
    }
    $requiredDistinctBackingDeviceCount = if ($globalPhysicalIsolation) {
        @($physicalBindings).Count
    }
    elseif ($strictTempPhysicalIsolation) {
        [int]$tempDb.DataFileCount
    }
    else {
        $minimumPhysicalDeviceCount
    }
    $distinctDevices = @($physicalBindings.BackingDeviceIds | Sort-Object -Unique)
    $provenDistinctPhysicalLaneCount = 0
    $provenPhysicalBindings = @($physicalBindings | Where-Object {
        [string]$_.TopologyStatus -eq 'Proven' -and @($_.BackingDeviceIds).Count -gt 0
    })
    for ($mask = 1; $mask -lt [Math]::Pow(2, $provenPhysicalBindings.Count); $mask++) {
        $selectedDeviceIds = [Collections.Generic.List[string]]::new()
        $selectedLaneCount = 0
        $disjoint = $true
        for ($index = 0; $index -lt $provenPhysicalBindings.Count; $index++) {
            if (($mask -band (1 -shl $index)) -eq 0) { continue }
            $deviceIds = @($provenPhysicalBindings[$index].BackingDeviceIds)
            if (@($deviceIds | Where-Object { $_ -in $selectedDeviceIds }).Count -gt 0) {
                $disjoint = $false
                break
            }
            foreach ($deviceId in $deviceIds) { $selectedDeviceIds.Add([string]$deviceId) }
            $selectedLaneCount++
        }
        if ($disjoint -and $selectedLaneCount -gt $provenDistinctPhysicalLaneCount) {
            $provenDistinctPhysicalLaneCount = $selectedLaneCount
        }
    }
    $physicalUnknown = $false
    if ($physicalRequested) {
        if ($Provider -in @('docker', 'podman')) { $blockers.Add('PROVIDER_PHYSICAL_STORAGE_UNSUPPORTED') }
        foreach ($binding in $physicalBindings) {
            if ([string]$binding.TopologyStatus -ne 'Proven' -or @($binding.BackingDeviceIds).Count -eq 0) { $physicalUnknown = $true }
        }
        if ($globalPhysicalIsolation -or $strictTempPhysicalIsolation) {
            for ($left = 0; $left -lt $physicalBindings.Count; $left++) {
                for ($right = $left + 1; $right -lt $physicalBindings.Count; $right++) {
                    if (@($physicalBindings[$left].BackingDeviceIds | Where-Object { $_ -in @($physicalBindings[$right].BackingDeviceIds) }).Count -gt 0) {
                        $prefix = if ($globalPhysicalIsolation) { 'STORAGE_BACKING_DEVICE_OVERLAP' } else { 'TEMPDB_BACKING_DEVICE_OVERLAP' }
                        $blockers.Add("${prefix}:$left-$right")
                    }
                }
            }
        }
        if (-not $physicalUnknown -and $minimumPhysicalDeviceCount -gt 0 -and $provenDistinctPhysicalLaneCount -lt $minimumPhysicalDeviceCount) {
            $blockers.Add("TEMPDB_MINIMUM_PHYSICAL_DEVICE_COUNT_NOT_MET:$provenDistinctPhysicalLaneCount/$minimumPhysicalDeviceCount")
        }
        if ($physicalUnknown) { $blockers.Add('TEMPDB_PHYSICAL_TOPOLOGY_UNKNOWN') }
    }
    $blockers = @($blockers | Sort-Object -Unique)
    $topologyStatus = if ($physicalRequested) {
        if ($physicalUnknown) { 'UNKNOWN' } elseif ($blockers.Count -gt 0) { 'BLOCKED' } else { 'PASS' }
    }
    elseif ($distribution -eq 'one-file-per-volume') {
        if ($blockers.Count -gt 0) { 'BLOCKED' } else { 'PASS' }
    }
    else { 'NOT_REQUIRED' }

    return [PSCustomObject]@{
        ContractVersion='SqlServerLab.StorageBoundPlan/1.0'; PlanId=[Guid]::NewGuid().ToString('D')
        IntentSha256=Get-LabStorageIntentSha256 -StorageIntent $StorageIntent; RunId=$RunId
        InstanceId=$InstanceId; Provider=$Provider; Status=$(if ($blockers.Count -eq 0) { 'READY' } else { 'BLOCKED' })
        Bindings=@($bindings); SqlFiles=@($sqlFiles)
        TopologyEvidence=[PSCustomObject]@{
            Distribution=$distribution; PhysicalIsolation=[string]$StorageIntent.PhysicalIsolation; Status=$topologyStatus
            DistinctVolumeCount=$distinctVolumes.Count; DistinctBackingDeviceCount=$distinctDevices.Count
            RequiredDistinctBackingDeviceCount=$requiredDistinctBackingDeviceCount
            ProvenDistinctPhysicalLaneCount=$provenDistinctPhysicalLaneCount
        }
        Blockers=$blockers
        RuntimeApplicationStatus=$(if ($Provider -eq 'hyperv' -and $blockers.Count -eq 0) { 'READY_TO_APPLY' } else { 'PROVIDER_APPLY_UNAVAILABLE' })
    }
}

function ConvertTo-LabHyperVStorageDrivePlan {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification='Erzeugt ausschließlich einen in-memory Providerplan.')]
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Plan)

    if ([string]$Plan.Provider -ne 'hyperv' -or [string]$Plan.Status -ne 'READY') {
        throw 'LAB_STORAGE_HYPERV_READY_PLAN_REQUIRED'
    }
    $result = [Collections.Generic.List[object]]::new()
    $index = 0
    foreach ($binding in @($Plan.Bindings | Sort-Object Selector)) {
        $files = @($Plan.SqlFiles | Where-Object Selector -eq [string]$binding.Selector)
        $sizeBytes = [long]$binding.RuntimeStorageSizeBytes
        if ($sizeBytes -lt 4GB) { throw "LAB_STORAGE_RUNTIME_SIZE_INVALID: $($binding.Selector)" }
        $role = if (@($files | Where-Object Role -eq 'backup').Count -eq $files.Count) { 'backup' }
            elseif (@($files | Where-Object Role -like 'tempdb-*').Count -eq $files.Count) { 'tempdb' }
            elseif (@($files | Where-Object Role -in @('default-log','database-log','restore-log-rule')).Count -gt 0) { 'sqlLog' }
            elseif (@($files | Where-Object Role -in @('default-data','database-data','restore-data-rule')).Count -gt 0) { 'sqlData' }
            else { 'general' }
        $result.Add([PSCustomObject]@{
            id = 'sfp-{0:d2}' -f ($index + 1); role = $role; sizeBytes = $sizeBytes
            vhdType = 'dynamic'; guestPath = [string]$binding.GuestRoot
            allocationUnitKB = 64; fileSystem = 'NTFS'
            volumeLabel = ('SQLLAB_SFP_{0:d2}' -f ($index + 1)); maximumIops = 0
            hostRoot = [string]$binding.HostRoot; hostPath = [string]$binding.HostPath
            locationId = [string]$binding.LocationId; selector = [string]$binding.Selector
        })
        $index++
    }
    return @($result)
}

function Assert-LabStorageBoundPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Plan)

    $schemaPath = Join-Path $script:SchemasPath 'lab-storage-bound-plan.schema.json'
    if (-not (($Plan | ConvertTo-Json -Depth 40) | Test-Json -SchemaFile $schemaPath -ErrorAction SilentlyContinue)) {
        throw 'LAB_STORAGE_BOUND_PLAN_SCHEMA_INVALID'
    }
    return $true
}

function Assert-LabStorageRuntimeReceipt {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Receipt)

    $schemaPath = Join-Path $script:SchemasPath 'lab-storage-runtime-receipt.schema.json'
    if (-not (($Receipt | ConvertTo-Json -Depth 40) | Test-Json -SchemaFile $schemaPath -ErrorAction SilentlyContinue)) {
        throw 'LAB_STORAGE_RUNTIME_RECEIPT_SCHEMA_INVALID'
    }
    return $true
}

function Resolve-LabStorageRuntimeSqlPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)][object[]]$DriveReceipts,
        [Parameter(Mandatory)][object[]]$ManagedDrives
    )

    $runtimeBindings = [Collections.Generic.List[object]]::new()
    $runtimeFiles = [Collections.Generic.List[object]]::new()
    $index = 0
    foreach ($binding in @($Plan.Bindings | Sort-Object Selector)) {
        $driveId = 'sfp-{0:d2}' -f ($index + 1)
        $receipt = @($DriveReceipts | Where-Object { [string]$_.id -eq $driveId })
        $managed = @($ManagedDrives | Where-Object { [string]$_.id -eq $driveId })
        if ($receipt.Count -ne 1 -or $managed.Count -ne 1 -or -not $receipt[0].guestPath -or -not $managed[0].path) {
            throw "LAB_STORAGE_RUNTIME_DRIVE_BINDING_MISSING: $driveId"
        }
        $runtimeBindings.Add([PSCustomObject]@{
            Selector=[string]$binding.Selector; LocationId=[string]$binding.LocationId
            HostPath=[string]$managed[0].path; RuntimeStorageId=[string]$managed[0].diskIdentifier
            GuestDiskId=[string]$receipt[0].diskIdentifier; PlannedGuestRoot=[string]$binding.GuestRoot
            GuestRoot=[string]$receipt[0].guestPath
        })
        $index++
    }
    foreach ($file in @($Plan.SqlFiles)) {
        $binding = @($runtimeBindings | Where-Object { [string]$_.Selector -eq [string]$file.Selector })
        if ($binding.Count -ne 1) { throw "LAB_STORAGE_RUNTIME_FILE_BINDING_MISSING: $($file.LogicalName)" }
        $plannedRoot = ([string]$binding[0].PlannedGuestRoot).TrimEnd('\', '/')
        $plannedPath = [string]$file.GuestPath
        if (-not $plannedPath.StartsWith($plannedRoot, [StringComparison]::OrdinalIgnoreCase)) {
            throw "LAB_STORAGE_RUNTIME_GUEST_PATH_OUTSIDE_BINDING: $($file.LogicalName)"
        }
        $suffix = $plannedPath.Substring($plannedRoot.Length).TrimStart('\', '/')
        $runtimePath = Get-LabStorageGuestChildPath -Root ([string]$binding[0].GuestRoot) -Child $suffix
        $runtimeFiles.Add([PSCustomObject]@{
            Role=[string]$file.Role; Database=$file.Database; LogicalName=[string]$file.LogicalName
            FileName=$file.FileName; Selector=[string]$file.Selector; LocationId=[string]$file.LocationId
            HostPath=[string]$binding[0].HostPath; RuntimeStorageId=[string]$binding[0].RuntimeStorageId
            GuestDiskId=[string]$binding[0].GuestDiskId; GuestPath=$runtimePath; SqlPhysicalPath=$runtimePath
            SizeMB=$file.SizeMB; Growth=$file.Growth
        })
    }
    return [PSCustomObject]@{ Bindings=@($runtimeBindings); SqlFiles=@($runtimeFiles) }
}

function New-LabStorageSqlApplyQuery {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$SqlFiles)

    $statements = [Collections.Generic.List[string]]::new()
    foreach ($default in @(
        @{ Role='default-data'; Name='DefaultData' },
        @{ Role='default-log'; Name='DefaultLog' },
        @{ Role='backup'; Name='BackupDirectory' }
    )) {
        $file = @($SqlFiles | Where-Object Role -eq $default.Role)
        if ($file.Count -gt 1) { throw "LAB_STORAGE_SQL_DEFAULT_ROLE_DUPLICATE: $($default.Role)" }
        if ($file.Count -eq 1) {
            Assert-LabContainerPath -Path ([string]$file[0].SqlPhysicalPath) -Label $default.Role
            $path = ([string]$file[0].SqlPhysicalPath).Replace("'", "''")
            $statements.Add("EXEC master.dbo.xp_instance_regwrite N'HKEY_LOCAL_MACHINE', N'Software\Microsoft\MSSQLServer\MSSQLServer', N'$($default.Name)', REG_SZ, N'$path';")
        }
    }
    $tempFiles = @($SqlFiles | Where-Object Role -in @('tempdb-data','tempdb-log'))
    foreach ($file in $tempFiles) {
        Assert-LabContainerPath -Path ([string]$file.SqlPhysicalPath) -Label $file.Role
        $logical = ([string]$file.LogicalName).Replace("'", "''")
        $path = ([string]$file.SqlPhysicalPath).Replace("'", "''")
        $size = [int]$file.SizeMB
        $growth = ConvertTo-LabGrowthClause -Growth ([string]$file.Growth)
        if ([string]$file.Role -eq 'tempdb-data' -and [string]$file.LogicalName -ne 'tempdev') {
            $statements.Add("IF EXISTS (SELECT 1 FROM tempdb.sys.database_files WHERE name=N'$logical') ALTER DATABASE tempdb MODIFY FILE (NAME=N'$logical', FILENAME=N'$path', SIZE=${size}MB, FILEGROWTH=$growth) ELSE ALTER DATABASE tempdb ADD FILE (NAME=N'$logical', FILENAME=N'$path', SIZE=${size}MB, FILEGROWTH=$growth);")
        }
        else {
            $statements.Add("ALTER DATABASE tempdb MODIFY FILE (NAME=N'$logical', FILENAME=N'$path', SIZE=${size}MB, FILEGROWTH=$growth);")
        }
    }
    $desiredDataNames = @($tempFiles | Where-Object Role -eq 'tempdb-data' | ForEach-Object { "N'$(([string]$_.LogicalName).Replace("'", "''"))'" })
    if ($desiredDataNames.Count -gt 0) {
        $statements.Add("DECLARE @n sysname,@s nvarchar(max); DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT name FROM tempdb.sys.database_files WHERE type=0 AND name NOT IN ($($desiredDataNames -join ',')); OPEN c; FETCH NEXT FROM c INTO @n; WHILE @@FETCH_STATUS=0 BEGIN SET @s=N'USE tempdb; DBCC SHRINKFILE ('+QUOTENAME(@n,'''')+N', EMPTYFILE) WITH NO_INFOMSGS; ALTER DATABASE tempdb REMOVE FILE '+QUOTENAME(@n)+N';'; EXEC sys.sp_executesql @s; FETCH NEXT FROM c INTO @n; END; CLOSE c; DEALLOCATE c;")
    }
    return $statements -join "`n"
}

function Invoke-HyperVLabStoragePlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)][PSCredential]$Credential,
        [Parameter(Mandatory)][SecureString]$SqlSaPassword,
        [string]$StateRoot
    )

    if ([string]$Plan.RunId -ne $RunId -or [string]$Plan.Provider -ne 'hyperv' -or [string]$Plan.Status -ne 'READY') {
        throw 'LAB_STORAGE_RUNTIME_READY_HYPERV_PLAN_REQUIRED'
    }
    $lab = Get-HyperVLabWorkflowRun -RunId $RunId -StateRoot $StateRoot
    $managed = Get-HyperVManagedVM -VMName ([string]$lab.Instance.vmName) -ExpectedRunId $lab.Run.runId -ExpectedScopeId $lab.Run.scopeId
    if (-not $managed) { throw 'LAB_STORAGE_RUNTIME_HYPERV_VM_REQUIRED' }
    $driveReceipts = @($managed.Identity.guestDriveInitialization)
    $runtime = Resolve-LabStorageRuntimeSqlPlan -Plan $Plan -DriveReceipts $driveReceipts -ManagedDrives @($managed.Identity.additionalDrives)
    $fileBindings = @($runtime.SqlFiles | ForEach-Object {
        [PSCustomObject]@{
            Database=$_.Database; Role=$_.Role; LogicalName=$_.LogicalName; LocationId=$_.LocationId; HostPath=$_.HostPath
            RuntimeStorageId=$_.RuntimeStorageId; GuestDiskId=$_.GuestDiskId; GuestPath=$_.GuestPath; SqlPhysicalPath=$_.SqlPhysicalPath
        }
    })
    $receiptPath = Join-Path $lab.RunDirectory 'storage-runtime-receipt.json'
    $receipt = [PSCustomObject]@{
        ContractVersion='SqlServerLab.StorageRuntimeReceipt/1.0'; PlanId=[string]$Plan.PlanId
        RunId=$RunId; InstanceId=[string]$Plan.InstanceId; Provider='hyperv'; Status='APPLYING'
        FileBindings=$fileBindings; Postconditions=@()
        Recovery=[PSCustomObject]@{ Status='RETRY_APPLY'; ReceiptPath=$receiptPath }
    }
    $null = Assert-LabStorageRuntimeReceipt -Receipt $receipt
    Write-LabArtifactJsonAtomic -Path $receiptPath -InputObject $receipt
    try {
        $query = New-LabStorageSqlApplyQuery -SqlFiles @($runtime.SqlFiles)
        $verification = [PSCustomObject]@{
            Defaults=@($runtime.SqlFiles | Where-Object Role -in @('default-data','default-log','backup') | ForEach-Object { [PSCustomObject]@{ Role=$_.Role; Path=$_.SqlPhysicalPath } })
            TempDb=@($runtime.SqlFiles | Where-Object Role -in @('tempdb-data','tempdb-log') | ForEach-Object { [PSCustomObject]@{ Role=$_.Role; LogicalName=$_.LogicalName; Path=$_.SqlPhysicalPath; SizeMB=$_.SizeMB; Growth=$_.Growth } })
        }
        $verificationJson = $verification | ConvertTo-Json -Compress -Depth 10
        $directories = @($runtime.SqlFiles | ForEach-Object {
            if ($_.FileName) { Split-Path -Parent ([string]$_.SqlPhysicalPath) } else { [string]$_.SqlPhysicalPath }
        } | Sort-Object -Unique)
        $result = Invoke-HyperVPowerShellDirect -VMName ([string]$lab.Instance.vmName) -ExpectedRunId $lab.Run.runId `
            -ExpectedScopeId $lab.Run.scopeId -Credential $Credential -ArgumentList @($query, $verificationJson, $directories, $SqlSaPassword) -ScriptBlock {
            param($ApplyQuery,$VerificationJson,$Directories,$SaPassword)
            $ErrorActionPreference='Stop'
            foreach($directory in @($Directories)){if(-not(Test-Path -LiteralPath $directory)){New-Item -Path $directory -ItemType Directory -Force -ErrorAction Stop|Out-Null}}
            $expected=$VerificationJson|ConvertFrom-Json
            $bstr=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($SaPassword);$plain=$null
            try{
                $plain=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
                $builder=[Data.SqlClient.SqlConnectionStringBuilder]::new();$builder.DataSource='localhost';$builder.InitialCatalog='master';$builder.UserID='sa';$builder.Password=$plain;$builder.Encrypt=$true;$builder.TrustServerCertificate=$true;$builder.ConnectTimeout=30;$connectionString=$builder.ConnectionString
                $connection=[Data.SqlClient.SqlConnection]::new($connectionString)
                try{$connection.Open();$command=$connection.CreateCommand();$command.CommandTimeout=180;$command.CommandText=$ApplyQuery;$null=$command.ExecuteNonQuery()}finally{$connection.Dispose()}
                Restart-Service -Name MSSQLSERVER -Force -ErrorAction Stop
                $service=Get-Service -Name MSSQLSERVER -ErrorAction Stop;$service.WaitForStatus('Running',[TimeSpan]::FromMinutes(3))
                $connection=[Data.SqlClient.SqlConnection]::new($connectionString)
                try{
                    $connection.Open();$command=$connection.CreateCommand();$command.CommandText="SELECT CAST(SERVERPROPERTY('InstanceDefaultDataPath') AS nvarchar(4000)),CAST(SERVERPROPERTY('InstanceDefaultLogPath') AS nvarchar(4000));";$reader=$command.ExecuteReader();$null=$reader.Read();$actualDefaults=@{ 'default-data'=[string]$reader.GetValue(0);'default-log'=[string]$reader.GetValue(1)};$reader.Dispose()
                    $command=$connection.CreateCommand();$command.CommandText="DECLARE @p nvarchar(4000); EXEC master.dbo.xp_instance_regread N'HKEY_LOCAL_MACHINE',N'Software\Microsoft\MSSQLServer\MSSQLServer',N'BackupDirectory',@p OUTPUT; SELECT @p;";$actualDefaults['backup']=[string]$command.ExecuteScalar()
                    foreach($item in @($expected.Defaults)){if(-not([string]$actualDefaults[[string]$item.Role]).TrimEnd('\').Equals(([string]$item.Path).TrimEnd('\'),[StringComparison]::OrdinalIgnoreCase)){throw "SQL_STORAGE_DEFAULT_POSTCONDITION_FAILED_$($item.Role)"}}
                    $command=$connection.CreateCommand();$command.CommandText="SELECT name,physical_name,size/128 AS size_mb,CASE WHEN is_percent_growth=1 THEN CAST(growth AS varchar(20))+'%' ELSE CAST(growth/128 AS varchar(20))+'MB' END AS growth,type FROM sys.master_files WHERE database_id=2;";$reader=$command.ExecuteReader();$actual=@{};while($reader.Read()){$actual[[string]$reader.GetString(0)]=[PSCustomObject]@{Path=[string]$reader.GetString(1);SizeMB=[int]$reader.GetInt32(2);Growth=[string]$reader.GetString(3);Type=[int]$reader.GetInt32(4)}};$reader.Dispose()
                    foreach($item in @($expected.TempDb)){$file=$actual[[string]$item.LogicalName];if(-not$file -or -not([string]$file.Path).Equals([string]$item.Path,[StringComparison]::OrdinalIgnoreCase) -or [int]$file.SizeMB -lt [int]$item.SizeMB -or [string]$file.Growth -ne [string]$item.Growth){throw "SQL_STORAGE_TEMPDB_POSTCONDITION_FAILED_$($item.LogicalName)"}}
                    $expectedData=@($expected.TempDb|Where-Object Role -eq 'tempdb-data').Count;$actualData=@($actual.Values|Where-Object Type -eq 0).Count;if($actualData -ne $expectedData){throw 'SQL_STORAGE_TEMPDB_FILE_COUNT_POSTCONDITION_FAILED'}
                }finally{$connection.Dispose()}
                [PSCustomObject]@{Status='VERIFIED';Service='MSSQLSERVER';ServiceStatus='Running';DefaultPaths='PASS';TempDb='PASS';ObservedAt=[datetime]::UtcNow.ToString('o')}
            }finally{$plain=$null;[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)}
        }
        $result = @($result)[-1]
        if (-not $result -or [string]$result.Status -ne 'VERIFIED') { throw 'LAB_STORAGE_RUNTIME_RECEIPT_INVALID' }
        $receipt.Status='VERIFIED'
        $receipt.Postconditions=@(
            [PSCustomObject]@{ Name='sql-service-restart'; Status='PASS'; ServiceStatus=[string]$result.ServiceStatus },
            [PSCustomObject]@{ Name='instance-default-paths'; Status=[string]$result.DefaultPaths },
            [PSCustomObject]@{ Name='tempdb-master-files'; Status=[string]$result.TempDb; ObservedAt=[string]$result.ObservedAt }
        )
        $receipt.Recovery=[PSCustomObject]@{ Status='NOT_REQUIRED' }
        $null = Assert-LabStorageRuntimeReceipt -Receipt $receipt
        Write-LabArtifactJsonAtomic -Path $receiptPath -InputObject $receipt
        return $receipt
    }
    catch {
        $receipt.Status='RECOVERY_REQUIRED'
        $errorCode = if ($_.Exception.Message -cmatch '[A-Z][A-Z0-9_]{5,127}') { ([string]$Matches[0]).TrimEnd('_') } else { [string]$_.Exception.GetType().Name }
        $receipt.Recovery=[PSCustomObject]@{ Status='RETRY_APPLY'; ErrorCode=$errorCode; ReceiptPath=$receiptPath }
        $null = Assert-LabStorageRuntimeReceipt -Receipt $receipt
        Write-LabArtifactJsonAtomic -Path $receiptPath -InputObject $receipt
        throw
    }
}

function Save-LabStorageBoundPlan {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='Medium')]
    param([Parameter(Mandatory)]$Plan, [string]$DataRoot)

    $null = Assert-LabStorageBoundPlan -Plan $Plan
    if (-not $DataRoot) { $DataRoot = [string](Get-LabStorageConfiguration).DefaultDataRoot }
    if (-not $DataRoot) { throw 'LAB_STORAGE_CONFIGURATION_REQUIRED' }
    $configuration = Get-LabStorageConfiguration -DataRoot $DataRoot
    $normalizedRoot = [IO.Path]::GetFullPath($DataRoot).TrimEnd('\', '/')
    $registeredLocation = @($configuration.LabDataLocations | Where-Object {
        [string]::Equals([IO.Path]::GetFullPath([string]$_.LabDataRoot).TrimEnd('\', '/'), $normalizedRoot, [StringComparison]::OrdinalIgnoreCase)
    })
    if ($registeredLocation.Count -ne 1 -or
        -not (Test-LabDataRootOwnership -DataRoot $normalizedRoot -ControllerId ([string]$configuration.ControllerId))) {
        throw 'LAB_STORAGE_BOUND_PLAN_ROOT_NOT_OWNED'
    }
    $directory = Join-Path (Join-Path $DataRoot 'Catalog') 'storage-plans'
    $path = Join-Path $directory "$($Plan.PlanId).bound-plan.json"
    if (-not $PSCmdlet.ShouldProcess($path, 'Lokalen SQL-Storage-Bound-Plan speichern')) { return $null }
    Write-LabArtifactJsonAtomic -Path $path -InputObject $Plan
    return $path
}

function Invoke-LabStorageFilePlacementInteractive {
    [CmdletBinding()]
    param()

    $intentPath = Read-Host '  Vollständiger Pfad zu einem SqlServerLab.StorageIntent/1.0 JSON'
    $resolvedPath = (Resolve-Path -LiteralPath $intentPath -ErrorAction Stop).Path
    $intent = Get-Content -LiteralPath $resolvedPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 40
    $providerSelection = Invoke-LabConsoleMenu -ScreenId 'storage-provider-select' -Title 'Provider für lokalen Bound Plan' -Items @(
        New-LabConsoleItem -Id 'hyperv' -Label 'Hyper-V' -Value 'physische Hostbindung planbar' -Shortcut '1'
        New-LabConsoleItem -Id 'docker' -Label 'Docker' -Value 'nur logische Trennung' -Shortcut '2'
        New-LabConsoleItem -Id 'podman' -Label 'Podman' -Value 'nur logische Trennung' -Shortcut '3'
    )
    if ($providerSelection.Status -ne 'Selected') { return }
    $labName = Read-Host '  Lab-Name für die lokalen Zielpfade'
    $instanceId = Read-Host '  Instanz-ID'
    $plan = New-LabStorageBoundPlan -StorageIntent $intent -RunId ([Guid]::NewGuid().ToString('D')) `
        -LabName $labName -InstanceId $instanceId -Provider ([string]$providerSelection.SelectedItem.Id)
    Write-LabHeader 'SQL-Dateiplatzierung – lokaler Bound Plan'
    Write-LabStatus -Label 'Status' -Value $plan.Status -Color $(if ($plan.Status -eq 'READY') { 'Green' } else { 'Yellow' })
    Write-LabStatus -Label 'Topologie' -Value "$($plan.TopologyEvidence.Status) · $($plan.TopologyEvidence.Distribution)"
    foreach ($binding in @($plan.Bindings)) {
        Write-LabInfo "  Selector $($binding.Selector) -> Location $($binding.LocationId) -> $($binding.GuestRoot); Topologie=$($binding.TopologyStatus); Backing=$(@($binding.BackingDeviceIds) -join ',')"
    }
    foreach ($file in @($plan.SqlFiles)) {
        Write-Host ("  {0} · {1} -> {2}" -f $file.Role, $file.LogicalName, $file.GuestPath)
    }
    foreach ($blocker in @($plan.Blockers)) { Write-LabWarning $blocker }
    Write-LabWarning 'Diese Review-Ansicht mutiert keine Runtime. Die geprüfte Hyper-V-/SQL-Anwendung erfolgt ausschließlich im Manifest-Lifecycle mit eigenem Runtime-Receipt.'
    if (Read-LabConfirm -Prompt '  Lokalen Bound Plan als Review-Artefakt speichern?' -Default $false) {
        $path = Save-LabStorageBoundPlan -Plan $plan -Confirm:$false
        Write-LabSuccess "Bound Plan gespeichert: $path"
    }
}
