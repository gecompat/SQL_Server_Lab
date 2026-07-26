function Get-LabResourceProfileManifest {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    $manifestPath = Join-Path $script:DiagnosticLabRoot 'Config/resource-profiles.json'
    return Get-Content -LiteralPath $manifestPath -Raw -Encoding utf8 |
        ConvertFrom-Json -Depth 100
}

function ConvertTo-LabIpv4Range {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Cidr,

        [Parameter()]
        [ValidateRange(0, 32)]
        [int] $MinimumPrefixLength = 0
    )

    if ([string]::IsNullOrWhiteSpace($Cidr)) {
        return $null
    }
    $parts = $Cidr.Split('/')
    if ($parts.Count -ne 2) {
        return $null
    }
    $prefixLength = 0
    if (
        -not [int]::TryParse($parts[1], [ref] $prefixLength) -or
        $prefixLength -lt $MinimumPrefixLength -or
        $prefixLength -gt 32
    ) {
        return $null
    }
    $address = $null
    if (
        -not [Net.IPAddress]::TryParse($parts[0], [ref] $address) -or
        $address.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork
    ) {
        return $null
    }
    $bytes = $address.GetAddressBytes()
    $addressNumber = (
        ([uint64] $bytes[0] -shl 24) -bor
        ([uint64] $bytes[1] -shl 16) -bor
        ([uint64] $bytes[2] -shl 8) -bor
        [uint64] $bytes[3]
    )
    $hostBits = 32 - $prefixLength
    $hostMask = if ($hostBits -eq 0) {
        [uint64] 0
    }
    else {
        ([uint64] 1 -shl $hostBits) - 1
    }
    $networkMask = ([uint64] 4294967295) -bxor $hostMask
    $start = $addressNumber -band $networkMask
    return [pscustomobject] @{
        Cidr = $Cidr
        PrefixLength = $prefixLength
        Start = $start
        End = $start + $hostMask
    }
}

function Test-LabIpv4RangeOverlap {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Left,

        [Parameter(Mandatory)]
        [pscustomobject] $Right
    )

    return $Left.Start -le $Right.End -and $Right.Start -le $Left.End
}

function Test-LabNetworkPolicy {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $NetworkPolicy
    )

    $configuredRange = ConvertTo-LabIpv4Range `
        -Cidr $NetworkPolicy.PrivateRangeCidr `
        -MinimumPrefixLength 8
    if ($null -eq $configuredRange -or $configuredRange.PrefixLength -gt 30) {
        return [pscustomobject] @{
            CheckStatus = 'NOT_CONFIGURED'
            ReasonCodes = @('NETWORK_RANGE_UNRESOLVED')
            CollisionCount = 0
        }
    }

    $privateCidr10 = ((10, 0, 0, 0) -join '.') + '/8'
    $privateCidr172 = ((172, 16, 0, 0) -join '.') + '/12'
    $privateCidr192 = ((192, 168, 0, 0) -join '.') + '/16'
    $privateRanges = @(
        ConvertTo-LabIpv4Range -Cidr $privateCidr10
        ConvertTo-LabIpv4Range -Cidr $privateCidr172
        ConvertTo-LabIpv4Range -Cidr $privateCidr192
    )
    if (-not @(
            $privateRanges |
                Where-Object {
                    $configuredRange.Start -ge $_.Start -and
                    $configuredRange.End -le $_.End
                }
        ).Count) {
        return [pscustomobject] @{
            CheckStatus = 'INVALID'
            ReasonCodes = @('NETWORK_RANGE_NOT_PRIVATE')
            CollisionCount = 0
        }
    }

    $routeCidrs = @()
    if ($IsWindows) {
        $getNetRoute = Get-Command Get-NetRoute -ErrorAction SilentlyContinue
        if ($null -eq $getNetRoute) {
            return [pscustomobject] @{
                CheckStatus = 'NOT_EXECUTED'
                ReasonCodes = @('NETWORK_ROUTE_CHECK_UNAVAILABLE')
                CollisionCount = 0
            }
        }
        $routeCidrs = @(
            Get-NetRoute -AddressFamily IPv4 -ErrorAction Stop |
                Where-Object {
                    $_.DestinationPrefix -ne (((0, 0, 0, 0) -join '.') + '/0')
                } |
                ForEach-Object { $_.DestinationPrefix }
        )
    }
    elseif ($IsLinux) {
        $routeResult = Invoke-LabReadOnlyProcess `
            -CommandName 'ip' `
            -ArgumentList @('-j', '-4', 'route', 'show')
        if (-not $routeResult.Succeeded) {
            return [pscustomobject] @{
                CheckStatus = 'NOT_EXECUTED'
                ReasonCodes = @('NETWORK_ROUTE_CHECK_UNAVAILABLE')
                CollisionCount = 0
            }
        }
        try {
            $routes = $routeResult.StandardOutput | ConvertFrom-Json -Depth 20
            $routeCidrs = @(
                $routes |
                    Where-Object {
                        -not [string]::IsNullOrWhiteSpace([string] $_.dst) -and
                        $_.dst -ne 'default'
                    } |
                    ForEach-Object { $_.dst }
            )
        }
        catch {
            return [pscustomobject] @{
                CheckStatus = 'NOT_EXECUTED'
                ReasonCodes = @('NETWORK_ROUTE_CHECK_UNAVAILABLE')
                CollisionCount = 0
            }
        }
    }
    else {
        return [pscustomobject] @{
            CheckStatus = 'NOT_EXECUTED'
            ReasonCodes = @('NETWORK_ROUTE_CHECK_UNAVAILABLE')
            CollisionCount = 0
        }
    }

    $collisionCount = 0
    foreach ($routeCidr in $routeCidrs) {
        $routeRange = ConvertTo-LabIpv4Range -Cidr $routeCidr
        if (
            $null -ne $routeRange -and
            (Test-LabIpv4RangeOverlap -Left $configuredRange -Right $routeRange)
        ) {
            $collisionCount++
        }
    }
    return [pscustomobject] @{
        CheckStatus = if ($collisionCount -eq 0) { 'PASS' } else { 'COLLISION' }
        ReasonCodes = if ($collisionCount -eq 0) {
            @()
        }
        else {
            @('NETWORK_RANGE_COLLISION')
        }
        CollisionCount = $collisionCount
    }
}

function Get-LabStorageTargetMeasurements {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [object[]] $StorageTargets
    )

    $driveInformation = @(
        [System.IO.DriveInfo]::GetDrives() |
            Where-Object { $_.IsReady } |
            Sort-Object { $_.RootDirectory.FullName.Length } -Descending
    )
    $measurements = @()
    $pathComparer = if ($IsWindows) {
        [StringComparer]::OrdinalIgnoreCase
    }
    else {
        [StringComparer]::Ordinal
    }
    $approvedVolumes = [Collections.Generic.Dictionary[string, long]]::new(
        $pathComparer
    )

    foreach ($target in $StorageTargets) {
        $freeStorageGiB = 0
        $volumeKey = $null
        $isResolved = $false
        if (
            -not [string]::IsNullOrWhiteSpace([string] $target.Path) -and
            (Test-Path -LiteralPath ([string] $target.Path) -PathType Container)
        ) {
            $resolvedTarget = (Resolve-Path -LiteralPath ([string] $target.Path)).Path
            $comparison = if ($IsWindows) {
                [StringComparison]::OrdinalIgnoreCase
            }
            else {
                [StringComparison]::Ordinal
            }
            $matchingDrive = $driveInformation |
                Where-Object {
                    $resolvedTarget.StartsWith(
                        $_.RootDirectory.FullName,
                        $comparison
                    )
                } |
                Select-Object -First 1
            if ($null -ne $matchingDrive) {
                $isResolved = $true
                $volumeKey = $matchingDrive.RootDirectory.FullName
                $freeStorageGiB = [Math]::Floor(
                    $matchingDrive.AvailableFreeSpace / 1GB
                )
                if (
                    [bool] $target.IsApprovedLabTarget -and
                    -not $approvedVolumes.ContainsKey($volumeKey)
                ) {
                    $approvedVolumes.Add(
                        $volumeKey,
                        $matchingDrive.AvailableFreeSpace
                    )
                }
            }
        }

        $measurements += [pscustomobject] @{
            LogicalTargetId = [string] $target.LogicalTargetId
            Roles = @($target.Roles)
            FreeStorageGiB = [int64] $freeStorageGiB
            IsSystemTarget = [bool] $target.IsSystemTarget
            IsApprovedLabTarget = (
                [bool] $target.IsApprovedLabTarget -and $isResolved
            )
        }
    }

    if ($measurements.Count -eq 0) {
        $measurements = @(
            [pscustomobject] @{
                LogicalTargetId = 'UNCONFIGURED_TARGET'
                Roles = @('EPHEMERAL_DATA')
                FreeStorageGiB = [int64] 0
                IsSystemTarget = $true
                IsApprovedLabTarget = $false
            }
        )
    }

    $approvedBytes = [int64] 0
    foreach ($freeBytes in $approvedVolumes.Values) {
        $approvedBytes += $freeBytes
    }

    return [pscustomobject] @{
        Measurements = $measurements
        ApprovedFreeStorageGiB = [int64] [Math]::Floor($approvedBytes / 1GB)
    }
}

function Resolve-LabHostClass {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [int] $LogicalProcessorCount,

        [Parameter(Mandatory)]
        [int64] $PhysicalMemoryMiB,

        [Parameter(Mandatory)]
        [int64] $ApprovedFreeStorageGiB
    )

    $manifest = Get-LabResourceProfileManifest
    $resolvedClass = 'UNCLASSIFIED'
    foreach ($hostClass in $manifest.HostClasses) {
        if (
            $LogicalProcessorCount -ge $hostClass.MinimumLogicalProcessors -and
            $PhysicalMemoryMiB -ge $hostClass.MinimumPhysicalMemoryMiB -and
            $ApprovedFreeStorageGiB -ge $hostClass.MinimumApprovedFreeStorageGiB
        ) {
            $resolvedClass = [string] $hostClass.HostClassId
        }
    }
    return $resolvedClass
}

function Resolve-LabExecutionMode {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [object[]] $HostCapabilities,

        [Parameter(Mandatory)]
        [ValidateSet('AUTO', 'WINDOWS_SINGLE_HOST', 'LINUX_NATIVE', 'DISTRIBUTED')]
        [string] $RequestedMode,

        [Parameter(Mandatory)]
        [string[]] $AllowedExecutionModes,

        [Parameter(Mandatory)]
        [ValidateSet('DOCKER', 'PODMAN')]
        [string] $ContainerEngine
    )

    $windowsHosts = @(
        $HostCapabilities |
            Where-Object {
                $_.Capability.OperatingSystemFamily -eq 'WINDOWS' -and
                $_.Capability.Capabilities.HyperV -and
                $_.Capability.Capabilities.PowerShellDirect
            }
    )
    $linuxHosts = @(
        $HostCapabilities |
            Where-Object {
                $engineAvailable = if ($ContainerEngine -eq 'DOCKER') {
                    $_.Capability.Capabilities.DockerEngine
                }
                else {
                    $_.Capability.Capabilities.PodmanEngine
                }
                $_.Capability.OperatingSystemFamily -eq 'LINUX' -and
                $engineAvailable -and
                $_.Capability.Capabilities.ComposeProvider -and
                $_.Capability.Capabilities.CgroupResourceLimits
            }
    )

    $supportedModes = @()
    if ($windowsHosts.Count -gt 0) {
        $supportedModes += 'WINDOWS_SINGLE_HOST'
    }
    if ($linuxHosts.Count -gt 0) {
        $supportedModes += 'LINUX_NATIVE'
    }
    if (
        $windowsHosts.Count -gt 0 -and
        $linuxHosts.Count -gt 0 -and
        @($HostCapabilities | Where-Object { $_.IsRemote }).Count -gt 0
    ) {
        $supportedModes += 'DISTRIBUTED'
    }
    $supportedModes = @(
        $supportedModes |
            Where-Object { $_ -in $AllowedExecutionModes } |
            Select-Object -Unique
    )

    if ($RequestedMode -ne 'AUTO') {
        return [pscustomobject] @{
            ResolvedExecutionMode = if ($RequestedMode -in $supportedModes) {
                $RequestedMode
            }
            else {
                $null
            }
            SupportedExecutionModes = $supportedModes
            ResolutionStatus = if ($RequestedMode -in $supportedModes) {
                'RESOLVED'
            }
            else {
                'REQUESTED_MODE_UNAVAILABLE'
            }
        }
    }

    $preferenceOrder = @(
        'DISTRIBUTED'
        'LINUX_NATIVE'
        'WINDOWS_SINGLE_HOST'
    )
    $resolvedMode = $preferenceOrder |
        Where-Object { $_ -in $supportedModes } |
        Select-Object -First 1
    return [pscustomobject] @{
        ResolvedExecutionMode = $resolvedMode
        SupportedExecutionModes = $supportedModes
        ResolutionStatus = if ($null -ne $resolvedMode) {
            'RESOLVED'
        }
        else {
            'NO_COMPATIBLE_MODE'
        }
    }
}

function Get-LabPreflightBlockers {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Configuration,

        [Parameter(Mandatory)]
        [object[]] $HostCapabilities,

        [Parameter(Mandatory)]
        [pscustomobject] $ModeResolution,

        [Parameter(Mandatory)]
        [pscustomobject] $SecretAvailability,

        [Parameter(Mandatory)]
        [pscustomobject] $ImageLockCheck,

        [Parameter(Mandatory)]
        [pscustomobject] $NetworkCheck
    )

    $blockers = [Collections.Generic.List[string]]::new()
    if ($Configuration.ConfigSource -eq 'EXAMPLE') {
        $blockers.Add('LOCAL_CONFIG_REQUIRED')
    }
    $faultTargetId = [string] $Configuration.StorageRoleBindings.FAULT_TARGET
    $configuredFaultTarget = $Configuration.StorageTargets |
        Where-Object { $_.LogicalTargetId -eq $faultTargetId } |
        Select-Object -First 1
    if (
        $null -eq $configuredFaultTarget -or
        -not $configuredFaultTarget.IsApprovedLabTarget
    ) {
        $blockers.Add('FAULT_TARGET_NOT_APPROVED')
    }
    if ($ModeResolution.ResolutionStatus -ne 'RESOLVED') {
        $blockers.Add([string] $ModeResolution.ResolutionStatus)
    }
    if (-not $SecretAvailability.IsAvailable) {
        $blockers.Add('REQUIRED_SECRET_UNAVAILABLE')
    }
    foreach ($reasonCode in $ImageLockCheck.ReasonCodes) {
        $blockers.Add([string] $reasonCode)
    }
    foreach ($reasonCode in $NetworkCheck.ReasonCodes) {
        $blockers.Add([string] $reasonCode)
    }

    foreach ($hostEntry in $HostCapabilities) {
        $capability = $hostEntry.Capability
        if ($capability.Architecture -ne 'X86_64') {
            $blockers.Add('X86_64_REQUIRED')
        }
        if ($capability.ResolvedHostClass -eq 'UNCLASSIFIED') {
            $blockers.Add('HOST_CLASS_UNCLASSIFIED')
        }

        $minimumMemoryReserveMiB = [Math]::Max(
            12288,
            [Math]::Ceiling($capability.PhysicalMemoryMiB * 0.20)
        )
        if ($capability.AvailableMemoryMiB -lt $minimumMemoryReserveMiB) {
            $blockers.Add('MEMORY_RESERVE_UNAVAILABLE')
        }

        foreach ($target in $capability.StorageTargets) {
            if (
                'FAULT_TARGET' -in @($target.Roles) -and
                (
                    $target.IsSystemTarget -or
                    'IMAGE_CACHE' -in @($target.Roles)
                )
            ) {
                $blockers.Add('FAULT_TARGET_NOT_ISOLATED')
            }
        }
    }

    return @($blockers | Select-Object -Unique)
}
