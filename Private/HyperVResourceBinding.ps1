<#
.SYNOPSIS
    Lokaler Root-Vertrag fuer physische Hyper-V-Ressourcen.
.DESCRIPTION
    Trennt kleine Steuerungsdaten im StateRoot von beschreibbaren Hyper-V-
    Ressourcen. Neue Create-Bindings werden ausschliesslich aus registrierten,
    controller-eigenen Lab_Data-Locations abgeleitet. Legacy-Roots bleiben fuer
    Discovery und bestehenden Lifecycle sichtbar, sind aber kein Create-Root.
#>

function Get-LabHyperVResourceClassDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Run', 'Build', 'Image', 'Staging', 'Recovery')]
        [string]$ResourceClass
    )

    switch ($ResourceClass) {
        'Run' { return 'Runs' }
        'Build' { return 'Builds' }
        'Image' { return 'Images' }
        'Staging' { return 'Staging' }
        'Recovery' { return 'Recovery' }
    }
}

function Get-LabHyperVShortResourceKey {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ResourceId,
        [Parameter(Mandatory)]
        [ValidateSet('Run', 'Build', 'Image', 'Staging', 'Recovery')]
        [string]$ResourceClass
    )

    if ([string]::IsNullOrWhiteSpace($ResourceId) -or $ResourceId.Length -gt 256) {
        throw 'HYPERV_RESOURCE_ID_INVALID'
    }
    $material = "$($ResourceClass.ToLowerInvariant())`n$($ResourceId.Trim().ToLowerInvariant())"
    $hash = [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($material))
    return ([Convert]::ToHexString($hash).ToLowerInvariant()).Substring(0, 20)
}

function Resolve-LabHyperVResourceBinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ResourceId,
        [Parameter(Mandatory)]
        [ValidateSet('Run', 'Build', 'Image', 'Staging', 'Recovery')]
        [string]$ResourceClass,
        [string]$LocationId,
        [string]$DataRoot
    )

    $configuration = Get-LabStorageConfiguration -DataRoot $DataRoot
    if (-not $configuration.ControllerId -or -not $configuration.DefaultLocationId) {
        throw 'HYPERV_RESOURCE_BINDING_STORAGE_CONFIGURATION_REQUIRED'
    }
    $effectiveLocationId = if ($LocationId) { $LocationId } else { [string]$configuration.DefaultLocationId }
    $locations = @($configuration.LabDataLocations | Where-Object {
        [string]$_.LocationId -eq $effectiveLocationId
    })
    if ($locations.Count -ne 1) { throw "HYPERV_RESOURCE_BINDING_LOCATION_NOT_FOUND: $effectiveLocationId" }
    $location = $locations[0]
    $labDataRoot = [IO.Path]::GetFullPath([string]$location.LabDataRoot).TrimEnd('\', '/')
    if (-not (Test-LabDataRootOwnership -DataRoot $labDataRoot -ControllerId ([string]$configuration.ControllerId))) {
        throw "HYPERV_RESOURCE_BINDING_ROOT_NOT_OWNED: $labDataRoot"
    }
    $marker = Get-LabDataRootMarker -DataRoot $labDataRoot
    $volume = Get-LabVolumeIdentity -Path $labDataRoot
    if (-not $marker -or
        [string]$marker.VolumeId -ne [string]$volume.VolumeId -or
        [string]$location.VolumeId -ne [string]$volume.VolumeId) {
        throw 'HYPERV_RESOURCE_BINDING_VOLUME_MISMATCH'
    }

    $resourceKey = Get-LabHyperVShortResourceKey -ResourceId $ResourceId -ResourceClass $ResourceClass
    $classDirectory = Get-LabHyperVResourceClassDirectory -ResourceClass $ResourceClass
    $classRoot = Join-Path (Join-Path $labDataRoot 'HyperV') $classDirectory
    $resourceRoot = Join-Path $classRoot $resourceKey
    $boundary = Test-LabPathWithinRoot -Root $labDataRoot -Path $resourceRoot
    if (-not $boundary.Valid) { throw "HYPERV_RESOURCE_BINDING_SCOPE_INVALID: $($boundary.Reason)" }
    if ($resourceRoot.Length -gt 180) { throw "HYPERV_RESOURCE_BINDING_PATH_TOO_LONG: $($resourceRoot.Length)" }

    $systemVolume = $false
    if ($IsWindows -and $env:SystemDrive) {
        $systemVolume = [string]::Equals(
            [IO.Path]::GetPathRoot($labDataRoot).TrimEnd('\'),
            ([string]$env:SystemDrive).TrimEnd('\'),
            [StringComparison]::OrdinalIgnoreCase
        )
    }
    return [PSCustomObject]@{
        ContractVersion = 'SqlServerLab.HyperVResourceBinding/1.0'
        BindingMode = 'CREATE'
        ResourceClass = $ResourceClass
        ResourceId = $ResourceId
        ResourceKey = $resourceKey
        ControllerId = [string]$configuration.ControllerId
        LocationId = [string]$location.LocationId
        VolumeId = [string]$volume.VolumeId
        LabDataRoot = $labDataRoot
        HyperVResourceRoot = [IO.Path]::GetFullPath($resourceRoot)
        AllowsCreate = $true
        AllowsExistingLifecycle = $true
        SystemVolume = $systemVolume
        ObservedFreeBytes = [long]$location.FreeBytes
        ResolvedAt = Get-LabTimestamp
    }
}

function Test-LabHyperVResourceBinding {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Binding, [string]$DataRoot)

    $failure = {
        param([string]$Code, [string]$Reason)
        [PSCustomObject]@{ Valid = $false; Code = $Code; Reason = $Reason; Binding = $Binding }
    }
    if (-not $Binding -or
        [string]$Binding.ContractVersion -ne 'SqlServerLab.HyperVResourceBinding/1.0' -or
        [string]$Binding.BindingMode -ne 'CREATE') {
        return & $failure 'HYPERV_RESOURCE_BINDING_CONTRACT_INVALID' 'Vertragsversion oder Bindungsmodus ist ungueltig.'
    }
    if ([string]$Binding.ResourceClass -notin @('Run', 'Build', 'Image', 'Staging', 'Recovery') -or
        -not [string]$Binding.ResourceId -or
        -not [string]$Binding.ResourceKey) {
        return & $failure 'HYPERV_RESOURCE_BINDING_IDENTITY_INVALID' 'Ressourcenklasse, ID oder Key fehlt.'
    }
    try {
        $expected = Resolve-LabHyperVResourceBinding -ResourceId ([string]$Binding.ResourceId) `
            -ResourceClass ([string]$Binding.ResourceClass) -LocationId ([string]$Binding.LocationId) -DataRoot $DataRoot
    }
    catch {
        return & $failure 'HYPERV_RESOURCE_BINDING_REVALIDATION_FAILED' $_.Exception.Message
    }
    foreach ($property in @('ResourceKey', 'ControllerId', 'LocationId', 'VolumeId', 'LabDataRoot', 'HyperVResourceRoot')) {
        if (-not [string]::Equals([string]$Binding.$property, [string]$expected.$property, [StringComparison]::OrdinalIgnoreCase)) {
            return & $failure 'HYPERV_RESOURCE_BINDING_IDENTITY_CHANGED' "$property stimmt nicht mehr mit der lokalen Registry ueberein."
        }
    }
    $boundary = Test-LabPathWithinRoot -Root ([string]$expected.LabDataRoot) -Path ([string]$expected.HyperVResourceRoot)
    if (-not $boundary.Valid) {
        return & $failure 'HYPERV_RESOURCE_BINDING_SCOPE_INVALID' $boundary.Reason
    }
    return [PSCustomObject]@{ Valid = $true; Code = 'HYPERV_RESOURCE_BINDING_VALID'; Reason = ''; Binding = $expected }
}

function Assert-LabHyperVResourceBinding {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Binding, [string]$DataRoot)

    $result = Test-LabHyperVResourceBinding -Binding $Binding -DataRoot $DataRoot
    if (-not $result.Valid) { throw "$($result.Code): $($result.Reason)" }
    return $result.Binding
}

function Write-LabHyperVResourceBinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Binding,
        [Parameter(Mandatory)][string]$StateDirectory,
        [string]$DataRoot
    )

    $validated = Assert-LabHyperVResourceBinding -Binding $Binding -DataRoot $DataRoot
    $directory = [IO.Path]::GetFullPath($StateDirectory)
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        throw "HYPERV_RESOURCE_BINDING_STATE_DIRECTORY_NOT_FOUND: $directory"
    }
    $path = Join-Path $directory 'hyperv-resource-binding.local.json'
    Write-LabArtifactJsonAtomic -Path $path -InputObject $validated
    return $path
}

function Read-LabHyperVResourceBinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$StateDirectory,
        [string]$DataRoot
    )

    $path = Join-Path ([IO.Path]::GetFullPath($StateDirectory)) 'hyperv-resource-binding.local.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    try { $binding = Get-Content -LiteralPath $path -Raw -Encoding utf8 | ConvertFrom-Json -Depth 12 }
    catch { throw "HYPERV_RESOURCE_BINDING_FILE_INVALID: $($_.Exception.Message)" }
    return Assert-LabHyperVResourceBinding -Binding $binding -DataRoot $DataRoot
}

function Get-LabHyperVResourceDiscoveryRoots {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Run', 'Build', 'Image', 'Staging', 'Recovery')]
        [string]$ResourceClass,
        [string]$StateRoot,
        [string]$DataRoot
    )

    $configuration = Get-LabStorageConfiguration -DataRoot $DataRoot
    $classDirectory = Get-LabHyperVResourceClassDirectory -ResourceClass $ResourceClass
    $roots = @(
        foreach ($location in @($configuration.LabDataLocations)) {
            $root = Join-Path (Join-Path ([string]$location.LabDataRoot) 'HyperV') $classDirectory
            [PSCustomObject]@{
                RootKind = 'REGISTERED'; Path = [IO.Path]::GetFullPath($root)
                LocationId = [string]$location.LocationId; AllowsCreate = $true; AllowsExistingLifecycle = $true
            }
        }
    )
    if ($StateRoot) {
        $legacyRelativePath = switch ($ResourceClass) {
            'Run' { 'runs' }
            'Build' { 'image-builds' }
            'Image' { 'artifacts/hyperv/images' }
            'Staging' { 'artifacts/hyperv/staging' }
            'Recovery' { 'runs' }
        }
        $legacyPath = Join-Path ([IO.Path]::GetFullPath($StateRoot)) $legacyRelativePath
        if (@($roots | Where-Object { [string]::Equals([string]$_.Path, $legacyPath, [StringComparison]::OrdinalIgnoreCase) }).Count -eq 0) {
            $roots += [PSCustomObject]@{
                RootKind = 'LEGACY_READ_ONLY'; Path = $legacyPath; LocationId = $null
                AllowsCreate = $false; AllowsExistingLifecycle = $true
            }
        }
    }
    return @($roots)
}

function Resolve-LabHyperVMutationRoot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ExistingResourcePath,
        [Parameter(Mandatory)]
        [ValidateSet('Run', 'Build', 'Image', 'Staging', 'Recovery')]
        [string]$ResourceClass,
        [string]$StateRoot,
        [string]$DataRoot
    )

    $candidate = [IO.Path]::GetFullPath($ExistingResourcePath)
    foreach ($root in @(Get-LabHyperVResourceDiscoveryRoots -ResourceClass $ResourceClass -StateRoot $StateRoot -DataRoot $DataRoot)) {
        $boundary = Test-LabPathWithinRoot -Root ([string]$root.Path) -Path $candidate
        if ($boundary.Valid) {
            return [PSCustomObject]@{
                RootKind = [string]$root.RootKind; MutationRoot = [string]$root.Path
                ExistingResourcePath = $candidate; LocationId = [string]$root.LocationId
                AllowsCreate = [bool]$root.AllowsCreate
                AllowsExistingLifecycle = [bool]$root.AllowsExistingLifecycle
            }
        }
    }
    throw "HYPERV_RESOURCE_MUTATION_ROOT_UNKNOWN: $candidate"
}
