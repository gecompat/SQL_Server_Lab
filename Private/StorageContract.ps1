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
            $affectedRuns += [PSCustomObject]@{ RunId=[string]$run.runId; Name=[string]$run.metadata.name; State=$runState }
            if ($runState -notin @('STOPPED', 'REMOVED', 'FAILED')) { $blockers.Add("RUN_NOT_STOPPED:$($run.runId)") }
        }
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
        ExecutionImplemented = $false
    }
    $planDirectory = Join-Path (Join-Path $sourceRoot 'Catalog') 'storage-migrations'
    if (-not (Test-Path -LiteralPath $planDirectory -PathType Container)) { New-Item -Path $planDirectory -ItemType Directory -Force | Out-Null }
    $planPath = Join-Path $planDirectory "$planId.plan.json"
    Write-LabArtifactJsonAtomic -Path $planPath -InputObject $plan
    return [PSCustomObject]@{ Path=$planPath; Plan=$plan }
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
}
