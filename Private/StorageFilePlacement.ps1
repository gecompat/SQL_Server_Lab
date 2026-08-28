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
    return $true
}

function Get-LabStorageGuestChildPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root, [string]$Child)

    if (-not $Child) { return $Root }
    if ($Root -match '^[A-Za-z]:\\') { return "$($Root.TrimEnd('\'))\$($Child.TrimStart('\'))" }
    return "$($Root.TrimEnd('/'))/$($Child.TrimStart('/'))"
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

    $tempBindings = @($dataFileSpecs | ForEach-Object { $bindingBySelector[[string]$_.Selector] } | Where-Object { $_ })
    $distinctVolumes = @($tempBindings.VolumeId | Sort-Object -Unique)
    $distribution = [string]$tempDb.Distribution
    if ($distribution -eq 'one-file-per-volume' -and $distinctVolumes.Count -ne [int]$tempDb.DataFileCount) {
        $blockers.Add('TEMPDB_DISTINCT_VOLUME_REQUIREMENT_NOT_MET')
    }
    $globalPhysicalIsolation = [string]$StorageIntent.PhysicalIsolation -eq 'required'
    $physicalRequested = $distribution -eq 'one-file-per-physical-device' -or $globalPhysicalIsolation
    $physicalBindings = if ($globalPhysicalIsolation) { @($bindings) } else { $tempBindings }
    $distinctDevices = @($physicalBindings.BackingDeviceIds | Sort-Object -Unique)
    $physicalUnknown = $false
    if ($physicalRequested) {
        if ($Provider -in @('docker', 'podman')) { $blockers.Add('PROVIDER_PHYSICAL_STORAGE_UNSUPPORTED') }
        foreach ($binding in $physicalBindings) {
            if ([string]$binding.TopologyStatus -ne 'Proven' -or @($binding.BackingDeviceIds).Count -eq 0) { $physicalUnknown = $true }
        }
        for ($left = 0; $left -lt $physicalBindings.Count; $left++) {
            for ($right = $left + 1; $right -lt $physicalBindings.Count; $right++) {
                if (@($physicalBindings[$left].BackingDeviceIds | Where-Object { $_ -in @($physicalBindings[$right].BackingDeviceIds) }).Count -gt 0) {
                    $prefix = if ($globalPhysicalIsolation) { 'STORAGE_BACKING_DEVICE_OVERLAP' } else { 'TEMPDB_BACKING_DEVICE_OVERLAP' }
                    $blockers.Add("${prefix}:$left-$right")
                }
            }
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
        }
        Blockers=$blockers; RuntimeApplicationStatus='PLANNED_NOT_IMPLEMENTED'
    }
}

function Save-LabStorageBoundPlan {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='Medium')]
    param([Parameter(Mandatory)]$Plan, [string]$DataRoot)

    $schemaPath = Join-Path $script:SchemasPath 'lab-storage-bound-plan.schema.json'
    $json = $Plan | ConvertTo-Json -Depth 40
    if (-not ($json | Test-Json -SchemaFile $schemaPath -ErrorAction SilentlyContinue)) { throw 'LAB_STORAGE_BOUND_PLAN_SCHEMA_INVALID' }
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
    Write-LabWarning 'Dieser Slice plant und prüft die Bindung; die Provider-/SQL-Anwendung ist noch nicht freigeschaltet.'
    if (Read-LabConfirm -Prompt '  Lokalen Bound Plan als Review-Artefakt speichern?' -Default $false) {
        $path = Save-LabStorageBoundPlan -Plan $plan -Confirm:$false
        Write-LabSuccess "Bound Plan gespeichert: $path"
    }
}
