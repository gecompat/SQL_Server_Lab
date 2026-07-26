function Get-LabCurrentResourceSnapshot {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $StoragePath
    )

    $availableMemoryMiB = if ($IsLinux) {
        $line = Get-Content -LiteralPath '/proc/meminfo' |
            Where-Object { $_ -match '^MemAvailable:\s+([0-9]+)\s+kB$' } |
            Select-Object -First 1
        if ($null -eq $line -or $line -notmatch '^MemAvailable:\s+([0-9]+)\s+kB$') {
            throw 'Available Linux memory could not be measured.'
        }
        [int64] ([math]::Floor(([int64] $Matches[1]) / 1024))
    }
    else {
        throw 'LAB-001 container resource measurement requires a Linux execution host.'
    }

    $resolvedStoragePath = (Resolve-Path -LiteralPath $StoragePath).Path
    $root = [IO.Path]::GetPathRoot($resolvedStoragePath)
    $drive = [IO.DriveInfo]::new($root)
    return [pscustomobject] @{
        CapturedAtUtc = [DateTime]::UtcNow.ToString('o')
        AvailableMemoryMiB = $availableMemoryMiB
        AvailableStorageGiB = [int64] (
            [math]::Floor($drive.AvailableFreeSpace / 1GB)
        )
    }
}

function Get-LabContainerBudget {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Compact', 'Standard')]
        [string] $ResourceProfile
    )

    $profilePath = Join-Path (
        $script:DiagnosticLabRoot
    ) 'Config/resource-profiles.json'
    $profiles = Get-Content -LiteralPath $profilePath -Raw -Encoding utf8 |
        ConvertFrom-Json -Depth 100
    $profile = @($profiles.ResourceProfiles) |
        Where-Object { $_.ResourceProfileId -eq $ResourceProfile } |
        Select-Object -First 1
    if ($null -eq $profile) {
        throw "The $ResourceProfile resource profile is missing."
    }
    $role = $profile.Roles.SQL_CONTAINER
    foreach ($property in @(
            'MemoryMiB'
            'LogicalProcessors'
            'SqlMemoryLimitMiB'
            'MaximumStorageGiB'
        )) {
        if ([int] $role.$property -le 0) {
            throw "The $ResourceProfile SQL container budget is incomplete."
        }
    }
    return [pscustomobject] @{
        ResourceProfile = $ResourceProfile
        MemoryMiB = [int] $role.MemoryMiB
        LogicalProcessors = [int] $role.LogicalProcessors
        SqlMemoryLimitMiB = [int] $role.SqlMemoryLimitMiB
        MaximumStorageGiB = [int] $role.MaximumStorageGiB
        MinimumHostMemoryReserveMiB = [int] (
            $profiles.HostReserve.MinimumMemoryMiB
        )
        MinimumHostStorageReserveGiB = [int] (
            $profiles.HostReserve.MinimumStorageGiB
        )
    }
}

function Get-LabCompactContainerBudget {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    return Get-LabContainerBudget -ResourceProfile Compact
}

function Assert-LabResourceBudget {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Snapshot,

        [Parameter(Mandatory)]
        [pscustomobject] $Budget,

        [Parameter(Mandatory)]
        [ValidateSet('BEFORE_UP', 'AFTER_UP')]
        [string] $Phase,

        [Parameter()]
        [ValidateRange(1, 3)]
        [int] $InstanceCount = 1
    )

    $requiredMemoryMiB = $Budget.MinimumHostMemoryReserveMiB
    $requiredStorageGiB = $Budget.MinimumHostStorageReserveGiB
    if ($Phase -eq 'BEFORE_UP') {
        $requiredMemoryMiB += ([int64] $Budget.MemoryMiB * $InstanceCount)
        $requiredStorageGiB += ([int64] $Budget.MaximumStorageGiB * $InstanceCount)
    }
    if ($Snapshot.AvailableMemoryMiB -lt $requiredMemoryMiB) {
        throw 'The LAB host memory reserve would be violated.'
    }
    if ($Snapshot.AvailableStorageGiB -lt $requiredStorageGiB) {
        throw 'The LAB host storage reserve would be violated.'
    }
    return [pscustomobject] @{
        Phase = $Phase
        InstanceCount = $InstanceCount
        RequiredMemoryMiB = $requiredMemoryMiB
        RequiredStorageGiB = $requiredStorageGiB
        ReserveStatus = 'PASS'
    }
}

function Measure-LabContainerResources {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $DockerCommand,

        [Parameter(Mandatory)]
        [ValidatePattern('^[a-f0-9]{64}$')]
        [string] $ContainerId,

        [Parameter(Mandatory)]
        [pscustomobject] $Budget
    )

    $inspect = Invoke-LabExternalCommand `
        -FilePath $DockerCommand `
        -Arguments @(
            'container'
            'inspect'
            '--format'
            '{{json .HostConfig}}'
            $ContainerId
        ) |
        Select-Object -First 1 |
        ConvertFrom-Json
    $storageBytes = Invoke-LabExternalCommand `
        -FilePath $DockerCommand `
        -Arguments @(
            'exec'
            $ContainerId
            '/usr/bin/du'
            '-sb'
            '/var/opt/mssql'
        ) |
        Select-Object -First 1
    if ([string] $storageBytes -notmatch '^([0-9]+)\s+') {
        throw 'Container storage consumption could not be measured.'
    }
    $measuredStorageBytes = [int64] $Matches[1]
    if ($measuredStorageBytes -gt ([int64] $Budget.MaximumStorageGiB * 1GB)) {
        throw 'Container storage consumption exceeds its resource profile budget.'
    }
    if (
        [int64] $inspect.Memory -ne ([int64] $Budget.MemoryMiB * 1MB) -or
        [int64] $inspect.NanoCpus -ne (
            [int64] $Budget.LogicalProcessors * 1000000000
        )
    ) {
        throw 'Effective Docker limits do not match the selected resource profile.'
    }
    return [pscustomobject] @{
        CapturedAtUtc = [DateTime]::UtcNow.ToString('o')
        ResourceProfile = [string] $Budget.ResourceProfile
        ContainerMemoryLimitMiB = [int64] ($inspect.Memory / 1MB)
        ContainerLogicalProcessorLimit = [decimal] (
            $inspect.NanoCpus / 1000000000
        )
        SqlMemoryLimitMiB = $Budget.SqlMemoryLimitMiB
        DataStorageBytes = $measuredStorageBytes
        MaximumDataStorageGiB = $Budget.MaximumStorageGiB
        LimitStatus = 'PASS'
    }
}
