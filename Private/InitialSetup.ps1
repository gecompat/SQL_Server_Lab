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

function Resolve-LabInitialSetupMediaRoot {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $candidate = $Path.Trim()
    if ([string]::IsNullOrWhiteSpace($candidate) -or
        $candidate -match '^[A-Za-z]:$' -or
        -not [IO.Path]::IsPathFullyQualified($candidate)) {
        throw 'INITIAL_SETUP_MEDIA_ROOT_NOT_FULLY_QUALIFIED'
    }
    try { $fullPath = [IO.Path]::GetFullPath($candidate) }
    catch { throw "INITIAL_SETUP_MEDIA_ROOT_INVALID: $($_.Exception.Message)" }
    $volumeRoot = [IO.Path]::GetPathRoot($fullPath)
    $mediaRoot = $fullPath.TrimEnd('\', '/')
    if ($mediaRoot -eq $volumeRoot.TrimEnd('\', '/')) { throw 'INITIAL_SETUP_MEDIA_ROOT_TOO_BROAD' }
    if (Test-LabInitialSetupPathWithinRepository -Path $mediaRoot) {
        throw 'MEDIA_ROOT_INSIDE_REPOSITORY: Medien muessen ausserhalb des Git-Checkouts liegen.'
    }
    return [PSCustomObject]@{ MediaRoot = $mediaRoot }
}

function Get-LabInitialSetupState {
    [CmdletBinding()]
    param()

    $mediaRoot = Get-LabMediaRootDefault
    $mediaCandidates = @(Get-LabMediaRootCandidates)
    $configurationStatus = 'READY'
    try { $configuration = Get-LabStorageConfiguration }
    catch {
        $configurationStatus = 'STORAGE_CONFIGURATION_INVALID'
        $configuration = [pscustomobject]@{ LabDataLocations=@(); ControllerId=''; DefaultLocationId='' }
    }
    $locationStatus = @(
        foreach ($location in @($configuration.LabDataLocations)) {
            $root = [string]$location.LabDataRoot
            try {
                $code = if (-not $root -or -not (Test-Path -LiteralPath $root -PathType Container -ErrorAction Stop)) { 'ROOT_NOT_FOUND' }
                    elseif (-not (Test-LabDataRootOwnership -DataRoot $root -ControllerId ([string]$configuration.ControllerId))) { 'OWNERSHIP_INVALID' }
                    else { 'READY' }
            }
            catch { $code = 'ROOT_UNREADABLE' }
            [pscustomobject]@{
                LocationId=[string]$location.LocationId; LabDataRoot=$root; Status=$code
                Source='StorageConfiguration'; IsDefault=([string]$location.LocationId -eq [string]$configuration.DefaultLocationId)
            }
        }
    )
    $validLocations = @(
        foreach ($location in @($configuration.LabDataLocations)) {
            $root = [string]$location.LabDataRoot
            if (-not @($locationStatus | Where-Object { $_.LocationId -eq [string]$location.LocationId -and $_.Status -eq 'READY' }).Count) { continue }
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
        MediaRootCandidates = $mediaCandidates
        ConfigurationStatus = $configurationStatus
        LocationStatus = $locationStatus
        Writeability = 'NOT_CHECKED'
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
        [string]$MediaRoot,
        [string[]]$LabDataRoot = @(),
        [string]$DefaultDataRoot
    )

    $state = Get-LabInitialSetupState
    if ($state.ConfigurationStatus -ne 'READY') { throw 'INITIAL_SETUP_STORAGE_CONFIGURATION_INVALID' }
    if ($state.MediaRootValid -and $MediaRoot -and
        -not [string]::Equals([IO.Path]::GetFullPath($MediaRoot).TrimEnd('\', '/'),
            [string]$state.MediaRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'INITIAL_SETUP_MEDIA_ROOT_CHANGE_UNSUPPORTED'
    }
    $mediaAction = $null
    if (-not $state.MediaRootValid) {
        if ([string]::IsNullOrWhiteSpace($MediaRoot)) { throw 'INITIAL_SETUP_MEDIA_ROOT_REQUIRED' }
        $resolvedMedia = Resolve-LabInitialSetupMediaRoot -Path $MediaRoot
        $mediaAction = [PSCustomObject]@{
            Action = 'Initialize'
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

    foreach ($rootInput in @($LabDataRoot | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })) {
        $resolved = Resolve-LabStorageRootPath -Path ([string]$rootInput)
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
        IsNoOp = -not $mediaAction -and $plannedLocations.Count -eq 0 -and $state.DefaultLocationValid -and
            [string]::Equals([IO.Path]::GetFullPath([string]$state.DefaultLocation.LabDataRoot).TrimEnd('\', '/'),
                $selectedDefault, [StringComparison]::OrdinalIgnoreCase)
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
        -MediaRoot $(if ($Plan.MediaAction) { [string]$Plan.MediaAction.MediaRoot } else { $null }) `
        -LabDataRoot @($Plan.LocationActions | ForEach-Object { [string]$_.LabDataRoot }) `
        -DefaultDataRoot ([string]$Plan.DefaultDataRoot)
    if ($Plan.IsNoOp) { return $Plan.CurrentState }
    if (-not $PSCmdlet.ShouldProcess('gemeinsame Host-Wurzeln', 'Geprueften Ersteinrichtungsplan anwenden')) { return $Plan }

    if ($Plan.MediaAction) {
        $initializer = Join-Path $script:ModuleRoot 'Tools/Initialize-SqlServerLabMediaRoot.ps1'
        if (-not (Test-Path -LiteralPath $initializer -PathType Leaf)) { throw 'INITIAL_SETUP_MEDIA_INITIALIZER_NOT_FOUND' }
        $null = & $initializer -RootPath ([string]$Plan.MediaAction.MediaRoot) -Confirm:$false
        $null = Set-LabMediaRootDefault -MediaRoot ([string]$Plan.MediaAction.MediaRoot) -ProcessEnvironmentOnly:$ProcessEnvironmentOnly
    }

    foreach ($location in @($Plan.LocationActions)) {
        $null = Set-LabDataLocation -LabDataRoot ([string]$location.LabDataRoot) `
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
        [string]$MediaRoot,
        [string[]]$LabDataRoot = @(),
        [string]$DefaultDataRoot,
        [switch]$ProcessEnvironmentOnly
    )

    $plan = New-LabInitialSetupPlan -MediaRoot $MediaRoot `
        -LabDataRoot $LabDataRoot -DefaultDataRoot $DefaultDataRoot
    if ($plan.IsNoOp) { return $plan.CurrentState }
    return Invoke-LabInitialSetupPlan -Plan $plan -ProcessEnvironmentOnly:$ProcessEnvironmentOnly `
        -Confirm:$false -WhatIf:$WhatIfPreference
}

function Invoke-LabInitialSetupInteractive {
    [CmdletBinding()]
    param()

    while ($true) {
        $state = (Invoke-SqlServerLabWorkflowAction -Action GetInitialSetupState).Result
        $items = @(
            New-LabConsoleItem -Id 'Configure' -Label 'Fehlende Roots ergänzen / globalen Standard wählen' -Shortcut '1'
            New-LabConsoleItem -Id 'Provider' -Label 'Einen Provider ausdrücklich erneut prüfen' -Shortcut '2'
            New-LabConsoleItem -Id 'root-status' -Label "Grundkonfiguration: $($state.ConfigurationStatus)" `
                -Value "Vollständig=$($state.Complete); Schreibbarkeit ungeprüft" `
                -Data "Grundkonfiguration: $($state.ConfigurationStatus); Vollständig=$($state.Complete); Schreibbarkeit ungeprüft."
            $index = 0
            foreach ($candidate in @($state.MediaRootCandidates)) {
                $detail = "Lab_Base: $($candidate.Path) | $($candidate.Source) | $($candidate.Status) | aktiv=$($candidate.Selected)"
                New-LabConsoleItem -Id "root-$index" -Label "Lab_Base · $($candidate.Source) · $($candidate.Status) · aktiv=$($candidate.Selected)" -Value ([string]$candidate.Path) -Data $detail
                $index++
            }
            foreach ($location in @($state.LocationStatus)) {
                $detail = "Lab_Data: $($location.LabDataRoot) | $($location.Source) | $($location.Status) | Standard=$($location.IsDefault)"
                New-LabConsoleItem -Id "root-$index" -Label "Lab_Data · $($location.Status) · Standard=$($location.IsDefault)" -Value ([string]$location.LabDataRoot) -Data $detail
                $index++
            }
        )
        $choice = Invoke-LabConsoleMenu -ScreenId 'initial-setup' -Title 'SQL-Lab-Grundkonfiguration' `
            -Subtitle "$($state.ConfigurationStatus) · Vollständig=$($state.Complete) · Schreibbarkeit ungeprüft; Root auswählen für Details" -Items $items
        if ($choice.Status -eq 'Refresh') { continue }
        if ($choice.Status -ne 'Selected') { return $state }
        if ([string]$choice.SelectedItem.Id -like 'root-*') {
            Write-LabInfo ([string]$choice.SelectedItem.Data)
            Wait-LabConsoleAcknowledgement
            continue
        }
        if ($choice.SelectedItem.Id -eq 'Provider') {
            $providers = @('docker', 'podman', 'hyperv') | ForEach-Object { New-LabConsoleItem -Id $_ -Label $_ -Data $_ }
            $selection = Invoke-LabConsoleMenu -ScreenId 'initial-setup-provider' -Title 'Provider prüfen (kein Start, keine Installation)' -Items $providers
            if ($selection.Status -eq 'Selected') {
                $result = (Invoke-SqlServerLabWorkflowAction -Action RefreshSetupProvider -SetupProvider ([string]$selection.SelectedItem.Data)).Result
                Write-LabInfo "$($result.Provider): $($result.Check.Status) | $($result.Check.Code) | $($result.Check.NextStep)"
                Wait-LabConsoleAcknowledgement
            }
            continue
        }
        if ($choice.SelectedItem.Id -ne 'Configure') { continue }
        if ($state.ConfigurationStatus -ne 'READY') {
            Write-LabWarning 'Storage-Konfiguration ungültig; bestehende Konfiguration separat prüfen.'
            Wait-LabConsoleAcknowledgement
            continue
        }
        $mediaParent = $null
        if (-not $state.MediaRootValid) {
            $inputResult = Read-LabConsoleTextInput -Prompt '  Vollständiger gemeinsamer Media-Root (z. B. D:\Lab1_Base)'
            if ($inputResult.Status -ne 'Confirmed' -or [string]::IsNullOrWhiteSpace([string]$inputResult.Value)) { continue }
            $mediaParent = [string]$inputResult.Value
        }
        $parents = [System.Collections.Generic.List[string]]::new()
        $prospectiveRoots = [System.Collections.Generic.List[string]]::new()
        foreach ($location in @($state.Locations)) { $prospectiveRoots.Add([string]$location.LabDataRoot) }
        $addMore = $state.Locations.Count -eq 0 -or (Read-LabConfirm -Prompt '  Weitere Lab_Data-Location auf anderem Volume hinzufügen?' -Default $false)
        $cancelled = $false
        while ($addMore) {
            $inputResult = Read-LabConsoleTextInput -Prompt '  Vollständiger gemeinsamer Lab-Datenroot (z. B. D:\Lab1_Data)'
            if ($inputResult.Status -ne 'Confirmed' -or [string]::IsNullOrWhiteSpace([string]$inputResult.Value)) { $cancelled=$true; break }
            $resolved = Resolve-LabStorageRootPath -Path ([string]$inputResult.Value)
            Write-LabInfo "Normalisiertes Ziel: $($resolved.LabDataRoot)"
            $parents.Add([string]$resolved.LabDataRoot)
            $prospectiveRoots.Add([string]$resolved.LabDataRoot)
            $addMore = Read-LabConfirm -Prompt '  Weitere Lab_Data-Location auf anderem Volume hinzufügen?' -Default $false
        }
        if ($cancelled) { continue }
        $items = for ($index = 0; $index -lt $prospectiveRoots.Count; $index++) {
            $root = [string]$prospectiveRoots[$index]
            New-LabConsoleItem -Id ([string]$index) -Label $root -Value 'globaler Lab_Data-Standard' -Shortcut ([string]($index + 1)) -Data $root
        }
        $selection = Invoke-LabConsoleMenu -ScreenId 'initial-setup-default-data-root' -Title 'Globalen Lab_Data-Standard ausdrücklich wählen' -Items $items
        if ($selection.Status -ne 'Selected') { continue }
        $plan = (Invoke-SqlServerLabWorkflowAction -Action PlanInitialSetup -MediaRoot $mediaParent -LabDataRoot @($parents) -DefaultDataRoot ([string]$selection.SelectedItem.Data)).Result
        if ($plan.MediaAction) { Write-LabInfo "Neuer gemeinsamer Media-Root: $($plan.MediaAction.MediaRoot)" }
        foreach ($location in @($plan.LocationActions)) { Write-LabInfo "Neuer gemeinsamer Lab-Datenroot: $($location.LabDataRoot)" }
        Write-LabInfo "Globaler Lab_Data-Standard: $($plan.DefaultDataRoot) | Keine Änderung: $($plan.IsNoOp)"
        if (-not (Read-LabConfirm -Prompt '  Diesen Plan jetzt revalidieren und anwenden?' -Default $false)) { continue }
        $result = (Invoke-SqlServerLabWorkflowAction -Action ApplyInitialSetup -InitialSetupPlan $plan -ConfirmSetup).Result
        if ($result.Complete) { Write-LabSuccess 'Gemeinsame Host-Infrastruktur ist vollständig eingerichtet.' }
        Wait-LabConsoleAcknowledgement
    }
}
