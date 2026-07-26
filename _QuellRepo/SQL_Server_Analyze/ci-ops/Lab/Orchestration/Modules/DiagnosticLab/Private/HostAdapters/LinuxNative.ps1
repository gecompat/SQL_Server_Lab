function Invoke-LabReadOnlyProcess {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $CommandName,

        [Parameter()]
        [string[]] $ArgumentList = @(),

        [Parameter()]
        [ValidateRange(1, 30)]
        [int] $TimeoutSeconds = 5
    )

    $command = Get-Command -Name $CommandName -CommandType Application `
        -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -eq $command) {
        return [pscustomobject] @{
            Available = $false
            Succeeded = $false
            StandardOutput = ''
        }
    }

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $command.Source
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in $ArgumentList) {
        $startInfo.ArgumentList.Add($argument)
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) {
            return [pscustomobject] @{
                Available = $true
                Succeeded = $false
                StandardOutput = ''
            }
        }
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $process.Kill($true)
            $process.WaitForExit()
            return [pscustomobject] @{
                Available = $true
                Succeeded = $false
                StandardOutput = ''
            }
        }
        $standardOutput = $process.StandardOutput.ReadToEnd().Trim()
        return [pscustomobject] @{
            Available = $true
            Succeeded = ($process.ExitCode -eq 0)
            StandardOutput = $standardOutput
        }
    }
    finally {
        $process.Dispose()
    }
}

function Get-LabNormalizedArchitecture {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $architecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture
    if ($architecture -eq [Runtime.InteropServices.Architecture]::X64) {
        return 'X86_64'
    }
    return $architecture.ToString().ToUpperInvariant()
}

function Get-LabLinuxMemory {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    $memoryPath = '/proc/meminfo'
    if (-not (Test-Path -LiteralPath $memoryPath -PathType Leaf)) {
        throw 'Linux memory information is unavailable.'
    }
    $values = @{}
    foreach ($line in Get-Content -LiteralPath $memoryPath -Encoding utf8) {
        if ($line -match '^([A-Za-z_]+):\s+([0-9]+)\s+kB$') {
            $values[$Matches[1]] = [int64] $Matches[2]
        }
    }
    if (-not $values.ContainsKey('MemTotal')) {
        throw 'Linux physical memory could not be resolved.'
    }
    $availableKiB = if ($values.ContainsKey('MemAvailable')) {
        $values.MemAvailable
    }
    elseif ($values.ContainsKey('MemFree')) {
        $values.MemFree
    }
    else {
        0
    }
    return [pscustomobject] @{
        PhysicalMemoryMiB = [int64] [Math]::Floor($values.MemTotal / 1024)
        AvailableMemoryMiB = [int64] [Math]::Floor($availableKiB / 1024)
    }
}

function Get-LabLinuxHostCapability {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Configuration
    )

    if (-not $IsLinux) {
        throw 'LinuxNative host adapter requires Linux.'
    }

    $memory = Get-LabLinuxMemory
    $storage = Get-LabStorageTargetMeasurements `
        -StorageTargets $Configuration.StorageTargets
    $docker = Invoke-LabReadOnlyProcess `
        -CommandName 'docker' `
        -ArgumentList @('version', '--format', '{{.Server.Version}}')
    $podman = Invoke-LabReadOnlyProcess `
        -CommandName 'podman' `
        -ArgumentList @('info', '--format', '{{.Version.Version}}')
    $dockerCompose = if ($docker.Succeeded) {
        Invoke-LabReadOnlyProcess `
            -CommandName 'docker' `
            -ArgumentList @('compose', 'version', '--short')
    }
    else {
        [pscustomobject] @{ Succeeded = $false }
    }
    $podmanCompose = if ($podman.Succeeded) {
        Invoke-LabReadOnlyProcess `
            -CommandName 'podman' `
            -ArgumentList @('compose', 'version')
    }
    else {
        [pscustomobject] @{ Succeeded = $false }
    }
    $idResult = Invoke-LabReadOnlyProcess `
        -CommandName 'id' `
        -ArgumentList @('-u')
    $tcResult = Invoke-LabReadOnlyProcess `
        -CommandName 'tc' `
        -ArgumentList @('-Version')

    $cgroupAvailable = (
        (Test-Path -LiteralPath '/sys/fs/cgroup/cgroup.controllers' -PathType Leaf) -or
        (Test-Path -LiteralPath '/sys/fs/cgroup/cpu' -PathType Container)
    )
    $composeAvailable = (
        $dockerCompose.Succeeded -or $podmanCompose.Succeeded
    )
    $supportedModes = if (
        ($docker.Succeeded -or $podman.Succeeded) -and
        $composeAvailable -and
        $cgroupAvailable
    ) {
        @('LINUX_NATIVE')
    }
    else {
        @()
    }

    return [pscustomobject] @{
        SchemaVersion = '1.0'
        DataClassification = 'LOCAL_RUNTIME_STATE'
        HostAdapter = 'LinuxNative'
        OperatingSystemFamily = 'LINUX'
        Architecture = (Get-LabNormalizedArchitecture)
        LogicalProcessorCount = [Environment]::ProcessorCount
        PhysicalMemoryMiB = $memory.PhysicalMemoryMiB
        AvailableMemoryMiB = $memory.AvailableMemoryMiB
        StorageTargets = @($storage.Measurements)
        Capabilities = [pscustomobject] @{
            HyperV = $false
            PowerShellDirect = $false
            DockerEngine = [bool] $docker.Succeeded
            PodmanEngine = [bool] $podman.Succeeded
            ComposeProvider = [bool] $composeAvailable
            CgroupResourceLimits = [bool] $cgroupAvailable
            NetworkFaultInjection = (
                [bool] $tcResult.Available -and
                $idResult.StandardOutput -eq '0'
            )
            RemoteHost = $false
        }
        ResolvedHostClass = Resolve-LabHostClass `
            -LogicalProcessorCount ([Environment]::ProcessorCount) `
            -PhysicalMemoryMiB $memory.PhysicalMemoryMiB `
            -ApprovedFreeStorageGiB $storage.ApprovedFreeStorageGiB
        SupportedExecutionModes = @($supportedModes)
    }
}
