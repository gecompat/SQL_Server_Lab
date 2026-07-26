function Get-LabRemoteHostCapability {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $RemoteHostConfiguration,

        [Parameter(Mandatory)]
        [pscustomobject] $Configuration,

        [Parameter(Mandatory)]
        [switch] $AllowRemoteExecution
    )

    if (-not $RemoteHostConfiguration.Approved) {
        return [pscustomobject] @{
            LogicalHostId = $RemoteHostConfiguration.LogicalHostId
            IsRemote = $true
            Status = 'NOT_EXECUTED'
            ReasonCode = 'REMOTE_HOST_NOT_APPROVED'
            Capability = $null
        }
    }
    if (-not $AllowRemoteExecution) {
        return [pscustomobject] @{
            LogicalHostId = $RemoteHostConfiguration.LogicalHostId
            IsRemote = $true
            Status = 'NOT_EXECUTED'
            ReasonCode = 'REMOTE_EXECUTION_NOT_CONFIRMED'
            Capability = $null
        }
    }
    if (
        [string]::IsNullOrWhiteSpace($RemoteHostConfiguration.Endpoint) -or
        $RemoteHostConfiguration.Transport -notin @('WSMAN', 'SSH')
    ) {
        return [pscustomobject] @{
            LogicalHostId = $RemoteHostConfiguration.LogicalHostId
            IsRemote = $true
            Status = 'NOT_EXECUTED'
            ReasonCode = 'REMOTE_CONFIGURATION_INVALID'
            Capability = $null
        }
    }

    $session = $null
    try {
        if ($RemoteHostConfiguration.Transport -eq 'SSH') {
            $sessionArguments = @{
                HostName = $RemoteHostConfiguration.Endpoint
                UserName = $RemoteHostConfiguration.UserName
            }
            if ($null -ne $RemoteHostConfiguration.Port) {
                $sessionArguments.Port = $RemoteHostConfiguration.Port
            }
            if (-not [string]::IsNullOrWhiteSpace(
                    $RemoteHostConfiguration.KeyFilePath
                )) {
                $sessionArguments.KeyFilePath = $RemoteHostConfiguration.KeyFilePath
            }
        }
        else {
            $sessionOption = New-PSSessionOption -OperationTimeout 10000
            $sessionArguments = @{
                ComputerName = $RemoteHostConfiguration.Endpoint
                SessionOption = $sessionOption
            }
            if ($null -ne $RemoteHostConfiguration.Port) {
                $sessionArguments.Port = $RemoteHostConfiguration.Port
            }
            if (
                -not [string]::IsNullOrWhiteSpace(
                    $RemoteHostConfiguration.UserName
                ) -and
                -not [string]::IsNullOrWhiteSpace(
                    $RemoteHostConfiguration.CredentialSecretName
                )
            ) {
                $sessionArguments.Credential = New-LabCredential `
                    -UserName $RemoteHostConfiguration.UserName `
                    -LogicalSecretName $RemoteHostConfiguration.CredentialSecretName `
                    -SecretPolicy $Configuration.SecretPolicy
            }
        }

        $session = New-PSSession @sessionArguments
        $remoteStorageTargetsJson = @(
            $RemoteHostConfiguration.StorageTargets
        ) | ConvertTo-Json -Depth 20 -Compress
        $remoteResult = Invoke-Command `
            -Session $session `
            -ArgumentList $remoteStorageTargetsJson `
            -ScriptBlock {
            param([string] $StorageTargetsJson)

            $StorageTargets = @(
                $StorageTargetsJson | ConvertFrom-Json -Depth 20
            )

            $isWindowsHost = [Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
                [Runtime.InteropServices.OSPlatform]::Windows
            )
            $architecture = if (
                [Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq
                [Runtime.InteropServices.Architecture]::X64
            ) {
                'X86_64'
            }
            else {
                (
                    [Runtime.InteropServices.RuntimeInformation]::OSArchitecture
                ).ToString().ToUpperInvariant()
            }

            if ($isWindowsHost) {
                $os = Get-CimInstance -ClassName Win32_OperatingSystem
                $physicalMemoryMiB = [int64] [Math]::Floor(
                    ([int64] $os.TotalVisibleMemorySize) / 1024
                )
                $availableMemoryMiB = [int64] [Math]::Floor(
                    ([int64] $os.FreePhysicalMemory) / 1024
                )
            }
            else {
                $memoryValues = @{}
                foreach ($line in Get-Content -LiteralPath '/proc/meminfo') {
                    if ($line -match '^([A-Za-z_]+):\s+([0-9]+)\s+kB$') {
                        $memoryValues[$Matches[1]] = [int64] $Matches[2]
                    }
                }
                $physicalMemoryMiB = [int64] [Math]::Floor(
                    $memoryValues.MemTotal / 1024
                )
                $availableMemoryKiB = if (
                    $memoryValues.ContainsKey('MemAvailable')
                ) {
                    $memoryValues.MemAvailable
                }
                else {
                    $memoryValues.MemFree
                }
                $availableMemoryMiB = [int64] [Math]::Floor(
                    $availableMemoryKiB / 1024
                )
            }

            $measurements = @()
            $approvedRoots = @{}
            $drives = @(
                [IO.DriveInfo]::GetDrives() |
                    Where-Object { $_.IsReady } |
                    Sort-Object { $_.RootDirectory.FullName.Length } -Descending
            )
            foreach ($target in $StorageTargets) {
                $freeGiB = 0
                $approved = $false
                if (Test-Path -LiteralPath ([string] $target.Path) -PathType Container) {
                    $resolved = (Resolve-Path -LiteralPath ([string] $target.Path)).Path
                    $pathComparison = if ($isWindowsHost) {
                        [StringComparison]::OrdinalIgnoreCase
                    }
                    else {
                        [StringComparison]::Ordinal
                    }
                    $drive = $drives |
                        Where-Object {
                            $resolved.StartsWith(
                                $_.RootDirectory.FullName,
                                $pathComparison
                            )
                        } |
                        Select-Object -First 1
                    if ($null -ne $drive) {
                        $freeGiB = [int64] [Math]::Floor(
                            $drive.AvailableFreeSpace / 1GB
                        )
                        $approved = [bool] $target.IsApprovedLabTarget
                        if ($approved) {
                            $approvedRoots[$drive.RootDirectory.FullName] =
                                [int64] $drive.AvailableFreeSpace
                        }
                    }
                }
                $measurements += [pscustomobject] @{
                    LogicalTargetId = [string] $target.LogicalTargetId
                    Roles = @($target.Roles)
                    FreeStorageGiB = $freeGiB
                    IsSystemTarget = [bool] $target.IsSystemTarget
                    IsApprovedLabTarget = $approved
                }
            }
            if ($measurements.Count -eq 0) {
                $measurements = @(
                    [pscustomobject] @{
                        LogicalTargetId = 'UNCONFIGURED_TARGET'
                        Roles = @('EPHEMERAL_DATA')
                        FreeStorageGiB = 0
                        IsSystemTarget = $true
                        IsApprovedLabTarget = $false
                    }
                )
            }
            $approvedBytes = [int64] 0
            foreach ($value in $approvedRoots.Values) {
                $approvedBytes += $value
            }

            $hyperV = $false
            $powerShellDirect = $false
            $docker = $false
            $podman = $false
            $compose = $false
            $cgroup = $false
            $networkFault = $false
            if ($isWindowsHost) {
                $getVm = Get-Command Get-VM -ErrorAction SilentlyContinue
                $vmms = Get-Service vmms -ErrorAction SilentlyContinue
                $hyperVInstalled = (
                    $null -ne $getVm -and
                    $null -ne $vmms -and
                    $vmms.Status -eq 'Running'
                )
                if ($hyperVInstalled) {
                    try {
                        Get-VM -ErrorAction Stop |
                            Select-Object -First 1 |
                            Out-Null
                        $hyperV = $true
                    }
                    catch {
                        $hyperV = $false
                    }
                }
                $invoke = Get-Command Invoke-Command
                $powerShellDirect = (
                    $hyperV -and $invoke.Parameters.ContainsKey('VMName')
                )
            }
            else {
                $dockerCommand = Get-Command docker -ErrorAction SilentlyContinue
                $podmanCommand = Get-Command podman -ErrorAction SilentlyContinue
                if ($null -ne $dockerCommand) {
                    & $dockerCommand.Source version --format '{{.Server.Version}}' *>$null
                    $docker = $LASTEXITCODE -eq 0
                    if ($docker) {
                        & $dockerCommand.Source compose version --short *>$null
                        $compose = $LASTEXITCODE -eq 0
                    }
                }
                if ($null -ne $podmanCommand) {
                    & $podmanCommand.Source info --format '{{.Version.Version}}' *>$null
                    $podman = $LASTEXITCODE -eq 0
                    if ($podman -and -not $compose) {
                        & $podmanCommand.Source compose version *>$null
                        $compose = $LASTEXITCODE -eq 0
                    }
                }
                $cgroup = (
                    (Test-Path -LiteralPath '/sys/fs/cgroup/cgroup.controllers') -or
                    (Test-Path -LiteralPath '/sys/fs/cgroup/cpu')
                )
                $networkFault = (
                    $null -ne (Get-Command tc -ErrorAction SilentlyContinue) -and
                    $null -ne (Get-Command id -ErrorAction SilentlyContinue) -and
                    (& id -u) -eq '0'
                )
            }

            [pscustomobject] @{
                OperatingSystemFamily = if ($isWindowsHost) {
                    'WINDOWS'
                }
                else {
                    'LINUX'
                }
                Architecture = $architecture
                LogicalProcessorCount = [Environment]::ProcessorCount
                PhysicalMemoryMiB = $physicalMemoryMiB
                AvailableMemoryMiB = $availableMemoryMiB
                StorageTargets = $measurements
                ApprovedFreeStorageGiB = [int64] [Math]::Floor(
                    $approvedBytes / 1GB
                )
                Capabilities = [pscustomobject] @{
                    HyperV = $hyperV
                    PowerShellDirect = $powerShellDirect
                    DockerEngine = $docker
                    PodmanEngine = $podman
                    ComposeProvider = $compose
                    CgroupResourceLimits = $cgroup
                    NetworkFaultInjection = $networkFault
                    RemoteHost = $true
                }
            }
        }

        $supportedModes = @()
        if (
            $remoteResult.OperatingSystemFamily -eq 'WINDOWS' -and
            $remoteResult.Capabilities.HyperV -and
            $remoteResult.Capabilities.PowerShellDirect
        ) {
            $supportedModes += 'WINDOWS_SINGLE_HOST'
        }
        if (
            $remoteResult.OperatingSystemFamily -eq 'LINUX' -and
            (
                $remoteResult.Capabilities.DockerEngine -or
                $remoteResult.Capabilities.PodmanEngine
            ) -and
            $remoteResult.Capabilities.ComposeProvider -and
            $remoteResult.Capabilities.CgroupResourceLimits
        ) {
            $supportedModes += 'LINUX_NATIVE'
        }

        $capability = [pscustomobject] @{
            SchemaVersion = '1.0'
            DataClassification = 'LOCAL_RUNTIME_STATE'
            HostAdapter = 'RemoteHost'
            OperatingSystemFamily = $remoteResult.OperatingSystemFamily
            Architecture = $remoteResult.Architecture
            LogicalProcessorCount = $remoteResult.LogicalProcessorCount
            PhysicalMemoryMiB = $remoteResult.PhysicalMemoryMiB
            AvailableMemoryMiB = $remoteResult.AvailableMemoryMiB
            StorageTargets = @($remoteResult.StorageTargets)
            Capabilities = $remoteResult.Capabilities
            ResolvedHostClass = Resolve-LabHostClass `
                -LogicalProcessorCount $remoteResult.LogicalProcessorCount `
                -PhysicalMemoryMiB $remoteResult.PhysicalMemoryMiB `
                -ApprovedFreeStorageGiB $remoteResult.ApprovedFreeStorageGiB
            SupportedExecutionModes = @($supportedModes)
        }
        return [pscustomobject] @{
            LogicalHostId = $RemoteHostConfiguration.LogicalHostId
            IsRemote = $true
            Status = 'AVAILABLE'
            ReasonCode = ''
            Capability = $capability
        }
    }
    catch {
        return [pscustomobject] @{
            LogicalHostId = $RemoteHostConfiguration.LogicalHostId
            IsRemote = $true
            Status = 'NOT_EXECUTED'
            ReasonCode = 'REMOTE_PREFLIGHT_FAILED'
            Capability = $null
        }
    }
    finally {
        if ($null -ne $session) {
            Remove-PSSession -Session $session -ErrorAction SilentlyContinue
        }
    }
}
