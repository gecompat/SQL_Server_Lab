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

function Get-LabHyperVResourceLocationPreview {
    <#
    .SYNOPSIS
        Erstellt die read-only Zielvorschau fuer physische Hyper-V-Ressourcen.
    .DESCRIPTION
        Loest Controller, Location, Volume, Lab_Data-Root und die erlaubten
        Klassenroots vor einer Provider- oder UAC-Mutation auf. Die Vorschau
        enthaelt keine Secrets und kann im erhoehten Prozess erneut gegen die
        lokale Storage-Registry validiert werden.
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('Run', 'Build', 'Image', 'Staging', 'Recovery')]
        [string[]]$ResourceClass = @('Run', 'Build', 'Image', 'Staging', 'Recovery'),
        [string]$LocationId,
        [string]$DataRoot
    )

    $classes = @($ResourceClass | Sort-Object -Unique)
    if ($classes.Count -eq 0) { throw 'HYPERV_RESOURCE_PREVIEW_CLASS_REQUIRED' }
    $configuration = Get-LabStorageConfiguration -DataRoot $DataRoot
    if (-not $configuration.ControllerId -or -not $configuration.DefaultLocationId) {
        throw 'HYPERV_RESOURCE_BINDING_STORAGE_CONFIGURATION_REQUIRED'
    }
    $effectiveLocationId = if ($LocationId) { $LocationId } else { [string]$configuration.DefaultLocationId }
    $locations = @($configuration.LabDataLocations | Where-Object { [string]$_.LocationId -eq $effectiveLocationId })
    if ($locations.Count -ne 1) { throw "HYPERV_RESOURCE_BINDING_LOCATION_NOT_FOUND: $effectiveLocationId" }
    $location = $locations[0]

    # Resolve fuehrt die vollstaendige Ownership-, Marker-, Volume-, Reparse-
    # und Pfadlaengenpruefung aus. Eine feste Preview-ID erzeugt dabei keine
    # Datei und dient nur dazu, den kanonischen Klassenroot abzuleiten.
    $targets = @(
        foreach ($class in $classes) {
            $binding = Resolve-LabHyperVResourceBinding -ResourceId "location-preview:$class" `
                -ResourceClass $class -LocationId $effectiveLocationId -DataRoot ([string]$location.LabDataRoot)
            $classRoot = Split-Path -Parent ([string]$binding.HyperVResourceRoot)
            [PSCustomObject]@{
                ResourceClass = $class
                ClassRoot = [IO.Path]::GetFullPath($classRoot)
                ResourceRootPattern = Join-Path ([IO.Path]::GetFullPath($classRoot)) '<20-character-resource-key>'
            }
        }
    )
    $representative = Resolve-LabHyperVResourceBinding -ResourceId 'location-preview:identity' `
        -ResourceClass Run -LocationId $effectiveLocationId -DataRoot ([string]$location.LabDataRoot)
    $warnings = @()
    if ($representative.SystemVolume) { $warnings += 'HYPERV_RESOURCE_PREVIEW_SYSTEM_VOLUME' }

    return [PSCustomObject]@{
        ContractVersion = 'SqlServerLab.HyperVResourceLocationPreview/1.0'
        ControllerId = [string]$representative.ControllerId
        LocationId = [string]$representative.LocationId
        VolumeId = [string]$representative.VolumeId
        LabDataRoot = [string]$representative.LabDataRoot
        ExpectedResourceClasses = @($classes)
        Targets = @($targets)
        ObservedFreeBytes = [long]$location.FreeBytes
        SystemVolume = [bool]$representative.SystemVolume
        Warnings = @($warnings)
        ResolvedAt = Get-LabTimestamp
    }
}

function Assert-LabHyperVResourceLocationPreview {
    <#
    .SYNOPSIS
        Revalidiert eine Hyper-V-Zielvorschau gegen die lokale Storage-Registry.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Preview)

    if (-not $Preview -or [string]$Preview.ContractVersion -ne 'SqlServerLab.HyperVResourceLocationPreview/1.0') {
        throw 'HYPERV_RESOURCE_PREVIEW_CONTRACT_INVALID'
    }
    $classes = @($Preview.ExpectedResourceClasses | ForEach-Object { [string]$_ })
    if ($classes.Count -eq 0 -or @($classes | Where-Object { $_ -notin @('Run', 'Build', 'Image', 'Staging', 'Recovery') }).Count -gt 0) {
        throw 'HYPERV_RESOURCE_PREVIEW_CLASS_INVALID'
    }
    $expected = Get-LabHyperVResourceLocationPreview -ResourceClass $classes `
        -LocationId ([string]$Preview.LocationId) -DataRoot ([string]$Preview.LabDataRoot)
    foreach ($property in @('ControllerId', 'LocationId', 'VolumeId', 'LabDataRoot')) {
        if (-not [string]::Equals([string]$Preview.$property, [string]$expected.$property, [StringComparison]::OrdinalIgnoreCase)) {
            throw "HYPERV_RESOURCE_PREVIEW_IDENTITY_CHANGED: $property"
        }
    }
    $actualTargets = @($Preview.Targets)
    if ($actualTargets.Count -ne @($expected.Targets).Count) { throw 'HYPERV_RESOURCE_PREVIEW_TARGETS_CHANGED' }
    foreach ($target in @($expected.Targets)) {
        $actual = @($actualTargets | Where-Object { [string]$_.ResourceClass -eq [string]$target.ResourceClass })
        if ($actual.Count -ne 1 -or
            -not [string]::Equals([string]$actual[0].ClassRoot, [string]$target.ClassRoot, [StringComparison]::OrdinalIgnoreCase) -or
            -not [string]::Equals([string]$actual[0].ResourceRootPattern, [string]$target.ResourceRootPattern, [StringComparison]::OrdinalIgnoreCase)) {
            throw "HYPERV_RESOURCE_PREVIEW_TARGET_CHANGED: $([string]$target.ResourceClass)"
        }
    }
    return $expected
}

function Write-LabHyperVResourceLocationPreview {
    <# .SYNOPSIS Zeigt die sanitisierte Hyper-V-Ressourcenroot-Vorschau an. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Preview)

    $validated = Assert-LabHyperVResourceLocationPreview -Preview $Preview
    $freeGiB = [Math]::Round(([double]$validated.ObservedFreeBytes / 1GB), 1)
    Write-Host '  Physische Hyper-V-Zielbindung:' -ForegroundColor Cyan
    Write-Host "    Location: $($validated.LocationId)" -ForegroundColor DarkGray
    Write-Host "    Lab_Data: $($validated.LabDataRoot)" -ForegroundColor DarkGray
    Write-Host "    Freier Speicher bei Prüfung: $freeGiB GB" -ForegroundColor DarkGray
    foreach ($target in @($validated.Targets)) {
        Write-Host "    $($target.ResourceClass): $($target.ResourceRootPattern)" -ForegroundColor DarkGray
    }
    if ($validated.SystemVolume) {
        Write-LabWarning 'Der registrierte Hyper-V-Root liegt auf dem Systemvolume. Kapazität vor großen Builds besonders prüfen; es erfolgt kein stiller Wechsel auf ein anderes Volume.'
    }
    return $validated
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

function Initialize-LabHyperVResourceBinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ResourceId,
        [Parameter(Mandatory)]
        [ValidateSet('Run', 'Build', 'Image', 'Staging', 'Recovery')]
        [string]$ResourceClass,
        [Parameter(Mandatory)][string]$StateDirectory,
        [string]$LocationId,
        [string]$DataRoot
    )

    $statePath = [IO.Path]::GetFullPath($StateDirectory)
    if (-not (Test-Path -LiteralPath $statePath -PathType Container)) {
        throw "HYPERV_RESOURCE_BINDING_STATE_DIRECTORY_NOT_FOUND: $statePath"
    }
    $binding = Read-LabHyperVResourceBinding -StateDirectory $statePath -DataRoot $DataRoot
    if ($binding) {
        if ([string]$binding.ResourceId -ne $ResourceId -or
            [string]$binding.ResourceClass -ne $ResourceClass) {
            throw 'HYPERV_RESOURCE_BINDING_STATE_IDENTITY_MISMATCH'
        }
        return $binding
    }

    $binding = Resolve-LabHyperVResourceBinding -ResourceId $ResourceId -ResourceClass $ResourceClass `
        -LocationId $LocationId -DataRoot $DataRoot
    $null = Write-LabHyperVResourceBinding -Binding $binding -StateDirectory $statePath -DataRoot $DataRoot
    return Assert-LabHyperVResourceBinding -Binding $binding -DataRoot $DataRoot
}

function Test-LabHyperVBoundPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Binding,
        [Parameter(Mandatory)][string]$Path,
        [string]$DataRoot,
        [ValidateRange(80, 240)][int]$MaximumPathLength = 220
    )

    $validated = Assert-LabHyperVResourceBinding -Binding $Binding -DataRoot $DataRoot
    $candidate = [IO.Path]::GetFullPath($Path)
    if ($candidate.Length -gt $MaximumPathLength) {
        return [PSCustomObject]@{ Valid=$false; Code='HYPERV_RESOURCE_PATH_TOO_LONG'; Reason="$($candidate.Length) > $MaximumPathLength"; Path=$candidate; Binding=$validated }
    }
    $rootItem = Get-Item -LiteralPath ([string]$validated.LabDataRoot) -Force -ErrorAction SilentlyContinue
    if (-not $rootItem -or ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        return [PSCustomObject]@{ Valid=$false; Code='HYPERV_RESOURCE_ROOT_REPARSE_OR_MISSING'; Reason=[string]$validated.LabDataRoot; Path=$candidate; Binding=$validated }
    }
    $boundary = Test-LabPathWithinRoot -Root ([string]$validated.HyperVResourceRoot) -Path $candidate
    if (-not $boundary.Valid) {
        return [PSCustomObject]@{ Valid=$false; Code='HYPERV_RESOURCE_PATH_SCOPE_INVALID'; Reason=$boundary.Reason; Path=$candidate; Binding=$validated }
    }
    return [PSCustomObject]@{ Valid=$true; Code='HYPERV_RESOURCE_PATH_VALID'; Reason=''; Path=$candidate; Binding=$validated }
}

function Assert-LabHyperVBoundPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Binding,
        [Parameter(Mandatory)][string]$Path,
        [string]$DataRoot,
        [ValidateRange(80, 240)][int]$MaximumPathLength = 220
    )

    $result = Test-LabHyperVBoundPath -Binding $Binding -Path $Path -DataRoot $DataRoot -MaximumPathLength $MaximumPathLength
    if (-not $result.Valid) { throw "$($result.Code): $($result.Reason)" }
    return $result.Path
}

function Resolve-LabHyperVStateResourcePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$StateDirectory,
        [Parameter(Mandatory)][string]$BoundRelativePath,
        [Parameter(Mandatory)][string]$LegacyRelativePath,
        [string]$DataRoot
    )

    $binding = Read-LabHyperVResourceBinding -StateDirectory $StateDirectory -DataRoot $DataRoot
    if ($binding) {
        $candidate = Join-Path ([string]$binding.HyperVResourceRoot) $BoundRelativePath
        return Assert-LabHyperVBoundPath -Binding $binding -Path $candidate -DataRoot $DataRoot
    }
    return [IO.Path]::GetFullPath((Join-Path $StateDirectory $LegacyRelativePath))
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
            if ([string]$root.RootKind -eq 'REGISTERED') {
                try {
                    $validationBinding = Resolve-LabHyperVResourceBinding `
                        -ResourceId 'mutation-root-validation' -ResourceClass $ResourceClass `
                        -LocationId ([string]$root.LocationId) -DataRoot $DataRoot
                    $expectedClassRoot = Split-Path -Parent ([string]$validationBinding.HyperVResourceRoot)
                    if (-not [string]::Equals([IO.Path]::GetFullPath([string]$root.Path), [IO.Path]::GetFullPath($expectedClassRoot), [StringComparison]::OrdinalIgnoreCase)) {
                        throw 'registered class root changed'
                    }
                }
                catch { throw "HYPERV_RESOURCE_MUTATION_ROOT_REVALIDATION_FAILED: $($_.Exception.Message)" }
            }
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
