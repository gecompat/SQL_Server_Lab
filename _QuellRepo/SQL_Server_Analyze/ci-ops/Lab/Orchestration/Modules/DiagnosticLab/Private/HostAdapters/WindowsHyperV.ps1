function Get-LabWindowsMemory {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    $operatingSystem = Get-CimInstance -ClassName Win32_OperatingSystem `
        -ErrorAction Stop
    return [pscustomobject] @{
        PhysicalMemoryMiB = [int64] [Math]::Floor(
            ([int64] $operatingSystem.TotalVisibleMemorySize) / 1024
        )
        AvailableMemoryMiB = [int64] [Math]::Floor(
            ([int64] $operatingSystem.FreePhysicalMemory) / 1024
        )
    }
}

function Get-LabWindowsHyperVHostCapability {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Configuration
    )

    if (-not $IsWindows) {
        throw 'WindowsHyperV host adapter requires Windows.'
    }

    $memory = Get-LabWindowsMemory
    $storage = Get-LabStorageTargetMeasurements `
        -StorageTargets $Configuration.StorageTargets
    $getVmCommand = Get-Command Get-VM -ErrorAction SilentlyContinue
    $invokeCommand = Get-Command Invoke-Command -ErrorAction Stop
    $vmService = Get-Service -Name vmms -ErrorAction SilentlyContinue
    $hyperVInstalled = (
        $null -ne $getVmCommand -and
        $null -ne $vmService -and
        $vmService.Status -eq 'Running'
    )
    $hyperVReadAllowed = $false
    if ($hyperVInstalled) {
        try {
            Get-VM -ErrorAction Stop | Select-Object -First 1 | Out-Null
            $hyperVReadAllowed = $true
        }
        catch {
            $hyperVReadAllowed = $false
        }
    }
    $hyperVAvailable = $hyperVInstalled -and $hyperVReadAllowed
    $powerShellDirectAvailable = (
        $hyperVAvailable -and
        $invokeCommand.Parameters.ContainsKey('VMName')
    )

    return [pscustomobject] @{
        SchemaVersion = '1.0'
        DataClassification = 'LOCAL_RUNTIME_STATE'
        HostAdapter = 'WindowsHyperV'
        OperatingSystemFamily = 'WINDOWS'
        Architecture = (Get-LabNormalizedArchitecture)
        LogicalProcessorCount = [Environment]::ProcessorCount
        PhysicalMemoryMiB = $memory.PhysicalMemoryMiB
        AvailableMemoryMiB = $memory.AvailableMemoryMiB
        StorageTargets = @($storage.Measurements)
        Capabilities = [pscustomobject] @{
            HyperV = [bool] $hyperVAvailable
            PowerShellDirect = [bool] $powerShellDirectAvailable
            DockerEngine = $false
            PodmanEngine = $false
            ComposeProvider = $false
            CgroupResourceLimits = $false
            NetworkFaultInjection = $false
            RemoteHost = $false
        }
        ResolvedHostClass = Resolve-LabHostClass `
            -LogicalProcessorCount ([Environment]::ProcessorCount) `
            -PhysicalMemoryMiB $memory.PhysicalMemoryMiB `
            -ApprovedFreeStorageGiB $storage.ApprovedFreeStorageGiB
        SupportedExecutionModes = @(
            if ($hyperVAvailable -and $powerShellDirectAvailable) {
                'WINDOWS_SINGLE_HOST'
            }
        )
    }
}
