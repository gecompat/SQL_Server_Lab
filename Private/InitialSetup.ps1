<#
.SYNOPSIS
    Gemeinsamer, idempotenter Ersteinrichtungsvertrag fuer Lab_Base und Lab_Data.
#>

function Test-LabInitialSetupPathWithinRepository {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not $script:ModuleRoot) { return $false }
    $candidate = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    $repository = [IO.Path]::GetFullPath($script:ModuleRoot).TrimEnd('\', '/')
    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    return $candidate.Equals($repository, $comparison) -or
        $candidate.StartsWith($repository + [IO.Path]::DirectorySeparatorChar, $comparison)
}

function Resolve-LabInitialSetupMediaParent {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $candidate = $Path.Trim()
    if ([string]::IsNullOrWhiteSpace($candidate) -or
        $candidate -match '^[A-Za-z]:$' -or
        -not [IO.Path]::IsPathFullyQualified($candidate)) {
        throw 'INITIAL_SETUP_MEDIA_PARENT_NOT_FULLY_QUALIFIED'
    }
    try { $fullPath = [IO.Path]::GetFullPath($candidate) }
    catch { throw "INITIAL_SETUP_MEDIA_PARENT_INVALID: $($_.Exception.Message)" }
    $volumeRoot = [IO.Path]::GetPathRoot($fullPath)
    $parent = if ($fullPath.TrimEnd('\', '/') -eq $volumeRoot.TrimEnd('\', '/')) {
        $volumeRoot
    }
    else { $fullPath.TrimEnd('\', '/') }
    if ([string]::IsNullOrWhiteSpace($parent)) { throw 'INITIAL_SETUP_MEDIA_PARENT_INVALID' }
    $mediaRoot = Join-Path $parent 'Lab_Base'
    if (Test-LabInitialSetupPathWithinRepository -Path $mediaRoot) {
        throw 'MEDIA_ROOT_INSIDE_REPOSITORY: Medien muessen ausserhalb des Git-Checkouts liegen.'
    }
    return [PSCustomObject]@{ BaseParent = $parent; MediaRoot = $mediaRoot }
}

function Get-LabInitialSetupState {
    [CmdletBinding()]
    param()

    $mediaRoot = Get-LabMediaRootDefault
    $configuration = Get-LabStorageConfiguration
    $validLocations = @(
        foreach ($location in @($configuration.LabDataLocations)) {
            $root = [string]$location.LabDataRoot
            if (-not $root -or -not (Test-Path -LiteralPath $root -PathType Container)) { continue }
            if (-not (Test-LabDataRootOwnership -DataRoot $root -ControllerId ([string]$configuration.ControllerId))) { continue }
            $location
        }
    )
    $defaultLocation = @($validLocations | Where-Object {
        [string]$_.LocationId -eq [string]$configuration.DefaultLocationId
    } | Select-Object -First 1)
    return [PSCustomObject]@{
        ContractVersion = 'SqlServerLab.InitialSetupState/1.0'
        MediaRoot = $mediaRoot
        MediaRootValid = [bool]$mediaRoot
        Locations = $validLocations
        InvalidLocationCount = @($configuration.LabDataLocations).Count - $validLocations.Count
        DefaultLocation = if ($defaultLocation.Count -eq 1) { $defaultLocation[0] } else { $null }
        DefaultLocationValid = $defaultLocation.Count -eq 1
        Complete = [bool]$mediaRoot -and $validLocations.Count -gt 0 -and $defaultLocation.Count -eq 1
    }
}

function New-LabInitialSetupPlan {
    [CmdletBinding()]
    param(
        [string]$MediaBaseParent,
        [string[]]$LabDataParent = @(),
        [string]$DefaultDataRoot
    )

    $state = Get-LabInitialSetupState
    $mediaAction = $null
    if (-not $state.MediaRootValid) {
        if ([string]::IsNullOrWhiteSpace($MediaBaseParent)) { throw 'INITIAL_SETUP_MEDIA_PARENT_REQUIRED' }
        $resolvedMedia = Resolve-LabInitialSetupMediaParent -Path $MediaBaseParent
        $mediaAction = [PSCustomObject]@{
            Action = 'Initialize'
            BaseParent = [string]$resolvedMedia.BaseParent
            MediaRoot = [string]$resolvedMedia.MediaRoot
        }
    }

    $plannedLocations = [System.Collections.Generic.List[object]]::new()
    $knownRoots = [System.Collections.Generic.List[string]]::new()
    $knownVolumes = [System.Collections.Generic.Dictionary[string,string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($location in @($state.Locations)) {
        $root = [IO.Path]::GetFullPath([string]$location.LabDataRoot).TrimEnd('\', '/')
        $knownRoots.Add($root)
        $volumeId = [string]$location.VolumeId
        if ($volumeId) { $knownVolumes[$volumeId] = $root }
    }

    foreach ($parentInput in @($LabDataParent | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })) {
        $resolved = Resolve-LabStorageParentPath -Path ([string]$parentInput)
        $root = [IO.Path]::GetFullPath([string]$resolved.LabDataRoot).TrimEnd('\', '/')
        if (Test-LabInitialSetupPathWithinRepository -Path $root) { throw 'LAB_DATA_ROOT_INSIDE_REPOSITORY' }
        if (@($knownRoots | Where-Object { $_.Equals($root, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0) { continue }

        $marker = Get-LabDataRootMarker -DataRoot $root
        if ($marker -and ([string]$marker.ManagedBy -ne 'SQL_Server_Lab' -or
                ($state.Locations.Count -gt 0 -and [string]$marker.ControllerId -ne [string]$state.Locations[0].ControllerId))) {
            throw "INITIAL_SETUP_DATA_ROOT_FOREIGN: $root"
        }
        if (-not $marker -and (Test-Path -LiteralPath $root -PathType Container) -and
            @(Get-ChildItem -LiteralPath $root -Force -ErrorAction Stop).Count -gt 0) {
            throw "INITIAL_SETUP_DATA_ROOT_NOT_EMPTY: $root"
        }

        $volume = Get-LabVolumeIdentity -Path $root
        $volumeId = [string]$volume.VolumeId
        if ($knownVolumes.ContainsKey($volumeId)) {
            throw "INITIAL_SETUP_VOLUME_ALREADY_CONFIGURED: $volumeId -> $($knownVolumes[$volumeId])"
        }
        $knownRoots.Add($root)
        $knownVolumes[$volumeId] = $root
        $plannedLocations.Add([PSCustomObject]@{
            Action = 'InitializeAndRegister'
            LabDataParent = [string]$resolved.LabDataParent
            LabDataRoot = $root
            VolumeId = $volumeId
        })
    }

    if ($knownRoots.Count -eq 0) { throw 'INITIAL_SETUP_DATA_PARENT_REQUIRED' }
    $selectedDefault = if ($DefaultDataRoot) {
        [IO.Path]::GetFullPath($DefaultDataRoot).TrimEnd('\', '/')
    }
    elseif ($state.DefaultLocationValid) {
        [IO.Path]::GetFullPath([string]$state.DefaultLocation.LabDataRoot).TrimEnd('\', '/')
    }
    else { $null }
    if (-not $selectedDefault) { throw 'INITIAL_SETUP_DEFAULT_DATA_ROOT_REQUIRED' }
    if (@($knownRoots | Where-Object { $_.Equals($selectedDefault, [StringComparison]::OrdinalIgnoreCase) }).Count -ne 1) {
        throw "INITIAL_SETUP_DEFAULT_DATA_ROOT_UNKNOWN: $selectedDefault"
    }

    return [PSCustomObject]@{
        ContractVersion = 'SqlServerLab.InitialSetupPlan/1.0'
        CreatedAt = Get-LabTimestamp
        CurrentState = $state
        MediaAction = $mediaAction
        LocationActions = @($plannedLocations)
        DefaultDataRoot = $selectedDefault
        IsNoOp = -not $mediaAction -and $plannedLocations.Count -eq 0 -and $state.DefaultLocationValid
    }
}

function Invoke-LabInitialSetupPlan {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='Medium')]
    param(
        [Parameter(Mandatory)]$Plan,
        [switch]$ProcessEnvironmentOnly
    )

    if ([string]$Plan.ContractVersion -ne 'SqlServerLab.InitialSetupPlan/1.0') {
        throw 'INITIAL_SETUP_PLAN_CONTRACT_UNSUPPORTED'
    }
    $Plan = New-LabInitialSetupPlan `
        -MediaBaseParent $(if ($Plan.MediaAction) { [string]$Plan.MediaAction.BaseParent } else { $null }) `
        -LabDataParent @($Plan.LocationActions | ForEach-Object { [string]$_.LabDataParent }) `
        -DefaultDataRoot ([string]$Plan.DefaultDataRoot)
    if ($Plan.IsNoOp) { return $Plan.CurrentState }
    if (-not $PSCmdlet.ShouldProcess('Lab_Base und Lab_Data', 'Geprueften Ersteinrichtungsplan anwenden')) { return $Plan }

    if ($Plan.MediaAction) {
        $initializer = Join-Path $script:ModuleRoot 'Tools/Initialize-SqlServerLabMediaRoot.ps1'
        if (-not (Test-Path -LiteralPath $initializer -PathType Leaf)) { throw 'INITIAL_SETUP_MEDIA_INITIALIZER_NOT_FOUND' }
        $null = & $initializer -RootPath ([string]$Plan.MediaAction.MediaRoot) -Confirm:$false
        $null = Set-LabMediaRootDefault -MediaRoot ([string]$Plan.MediaAction.MediaRoot) -ProcessEnvironmentOnly:$ProcessEnvironmentOnly
    }

    foreach ($location in @($Plan.LocationActions)) {
        $null = Set-LabDataLocation -LabDataParent ([string]$location.LabDataParent) `
            -ProcessEnvironmentOnly:$ProcessEnvironmentOnly -Confirm:$false
    }
    $configuration = Get-LabStorageConfiguration
    $defaultLocation = @($configuration.LabDataLocations | Where-Object {
        [string]::Equals([IO.Path]::GetFullPath([string]$_.LabDataRoot).TrimEnd('\', '/'),
            [string]$Plan.DefaultDataRoot, [StringComparison]::OrdinalIgnoreCase)
    } | Select-Object -First 1)
    if ($defaultLocation.Count -ne 1) { throw 'INITIAL_SETUP_DEFAULT_LOCATION_NOT_REGISTERED' }
    $null = Set-LabDefaultDataLocation -LocationId ([string]$defaultLocation[0].LocationId) `
        -ProcessEnvironmentOnly:$ProcessEnvironmentOnly -Confirm:$false

    $result = Get-LabInitialSetupState
    if (-not $result.Complete) { throw 'INITIAL_SETUP_POSTCONDITION_FAILED' }
    return $result
}

function Invoke-LabInitialSetup {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='Medium')]
    param(
        [string]$MediaBaseParent,
        [string[]]$LabDataParent = @(),
        [string]$DefaultDataRoot,
        [switch]$ProcessEnvironmentOnly
    )

    $plan = New-LabInitialSetupPlan -MediaBaseParent $MediaBaseParent `
        -LabDataParent $LabDataParent -DefaultDataRoot $DefaultDataRoot
    if ($plan.IsNoOp) { return $plan.CurrentState }
    return Invoke-LabInitialSetupPlan -Plan $plan -ProcessEnvironmentOnly:$ProcessEnvironmentOnly `
        -Confirm:$false -WhatIf:$WhatIfPreference
}

function Invoke-LabInitialSetupInteractive {
    [CmdletBinding()]
    param()

    $state = Get-LabInitialSetupState
    if ($state.Complete) {
        Write-LabSuccess "Ersteinrichtung ist bereits vollständig: Lab_Base=$($state.MediaRoot), Lab_Data=$(@($state.Locations).Count) Location(s)."
        return $state
    }

    $mediaParent = $null
    if (-not $state.MediaRootValid) {
        $inputResult = Read-LabConsoleTextInput -Prompt '  Basisverzeichnis für Lab_Base (z. B. D:\)'
        if ($inputResult.Status -ne 'Confirmed' -or [string]::IsNullOrWhiteSpace([string]$inputResult.Value)) { return $null }
        $mediaParent = [string]$inputResult.Value
    }

    $parents = [System.Collections.Generic.List[string]]::new()
    $prospectiveRoots = [System.Collections.Generic.List[string]]::new()
    foreach ($location in @($state.Locations)) { $prospectiveRoots.Add([string]$location.LabDataRoot) }
    if ($state.Locations.Count -eq 0) {
        do {
            $inputResult = Read-LabConsoleTextInput -Prompt '  Parent für Lab_Data (z. B. D:\; daraus wird D:\Lab_Data)'
            if ($inputResult.Status -ne 'Confirmed' -or [string]::IsNullOrWhiteSpace([string]$inputResult.Value)) { return $null }
            $resolved = Resolve-LabStorageParentPath -Path ([string]$inputResult.Value)
            Write-LabInfo "Normalisiertes Ziel: $($resolved.LabDataRoot)"
            $parents.Add([string]$resolved.LabDataParent)
            $prospectiveRoots.Add([string]$resolved.LabDataRoot)
            $addMore = Read-LabConfirm -Prompt '  Weitere Lab_Data-Location auf einem anderen Volume hinzufügen?' -Default $false
        } while ($addMore)
    }

    $defaultRoot = if ($state.DefaultLocationValid) { [string]$state.DefaultLocation.LabDataRoot } else { $null }
    if (-not $defaultRoot) {
        $items = for ($index = 0; $index -lt $prospectiveRoots.Count; $index++) {
            $root = [string]$prospectiveRoots[$index]
            New-LabConsoleItem -Id ([string]$index) -Label $root -Value 'globaler Lab_Data-Standard' `
                -Shortcut ([string]($index + 1)) -Data $root
        }
        $selection = Invoke-LabConsoleMenu -ScreenId 'initial-setup-default-data-root' `
            -Title 'Globalen Lab_Data-Standard ausdrücklich wählen' -Items $items
        if ($selection.Status -ne 'Selected') { return $null }
        $defaultRoot = [string]$selection.SelectedItem.Data
    }

    $plan = New-LabInitialSetupPlan -MediaBaseParent $mediaParent -LabDataParent @($parents) -DefaultDataRoot $defaultRoot
    if ($plan.MediaAction) { Write-LabInfo "Lab_Base: $($plan.MediaAction.MediaRoot)" }
    foreach ($location in @($plan.LocationActions)) { Write-LabInfo "Lab_Data: $($location.LabDataRoot)" }
    Write-LabInfo "Globaler Lab_Data-Standard: $($plan.DefaultDataRoot)"
    if (-not (Read-LabConfirm -Prompt '  Diese Ersteinrichtung jetzt anwenden?' -Default $false)) { return $null }
    $result = Invoke-LabInitialSetupPlan -Plan $plan -Confirm:$false
    Write-LabSuccess 'Lab_Base und Lab_Data sind vollständig eingerichtet.'
    return $result
}
