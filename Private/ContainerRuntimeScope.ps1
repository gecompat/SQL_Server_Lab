<#
.SYNOPSIS
    Ermittelt die Reichweite einer Docker- oder Podman-Runtime read-only.
.DESCRIPTION
    Bindet den aktiven Docker-Context beziehungsweise die aktive Podman-
    Connection an eine stabile, geheimnisfreie Runtime-ID. Rohendpunkte,
    Identity-Pfade und Runtime-interne Storage-Pfade verlassen die Evidence-
    Verarbeitung nicht. Ohne eigenen Ownership-Vertrag bleiben Engine,
    Machine, Hostdefaults und physisches Backing REPORT_ONLY.
#>

function Get-LabContainerRuntimeScopeId {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('docker','podman')][string]$Provider,
        [Parameter(Mandatory)][string]$IdentityKey
    )

    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes("$Provider|$IdentityKey".ToLowerInvariant())
        $hash = [BitConverter]::ToString($algorithm.ComputeHash($bytes)).Replace('-', '').ToLowerInvariant()
        return "runtime-scope-$($hash.Substring(0, 24))"
    }
    finally { $algorithm.Dispose() }
}

function Get-LabContainerRuntimeEndpointKind {
    [CmdletBinding()]
    param([AllowNull()][string]$Endpoint)

    if ([string]::IsNullOrWhiteSpace($Endpoint)) { return 'UNKNOWN' }
    if ($Endpoint -match '^(?i)npipe:') { return 'LOCAL_NPIPE' }
    if ($Endpoint -match '^(?i)unix:') { return 'LOCAL_UNIX' }
    if ($Endpoint -match '^(?i)ssh://[^@/]+@(127\.0\.0\.1|localhost)(:|/)') { return 'LOCAL_MACHINE_SSH' }
    if ($Endpoint -match '^(?i)ssh:') { return 'REMOTE_SSH' }
    if ($Endpoint -match '^(?i)(tcp|http|https):') { return 'REMOTE_TCP' }
    return 'UNKNOWN'
}

function Invoke-LabContainerRuntimeJsonCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('docker','podman')][string]$Provider,
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$FailureCode
    )

    $invocation = Get-LabHostToolInvocation -Name $Provider
    $output = @(& $invocation @Arguments 2>$null)
    if ($LASTEXITCODE -ne 0 -or $output.Count -eq 0) { throw $FailureCode }
    try { return (($output -join "`n") | ConvertFrom-Json -Depth 30 -ErrorAction Stop) }
    catch { throw $FailureCode }
}

function Get-LabContainerRuntimeScopeEvidence {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('docker','podman')][string]$Provider)

    $resolution = Resolve-LabHostTool -Name $Provider
    if (-not $resolution.Available) {
        return [PSCustomObject]@{ Provider=$Provider; Available=$false; Issue='RUNTIME_CLI_NOT_INSTALLED' }
    }

    try {
        if ($Provider -eq 'docker') {
            $contexts = @(Invoke-LabContainerRuntimeJsonCommand -Provider docker -Arguments @('context','inspect') -FailureCode 'DOCKER_CONTEXT_INSPECTION_FAILED')
            $info = Invoke-LabContainerRuntimeJsonCommand -Provider docker -Arguments @('info','--format','{{json .}}') -FailureCode 'DOCKER_INFO_FAILED'
            return [PSCustomObject]@{
                Provider='docker'; Available=$true; HostPlatform=if ($IsWindows) { 'windows' } elseif ($IsMacOS) { 'macos' } else { 'linux' }
                Contexts=@($contexts); Info=$info
            }
        }

        $info = Invoke-LabContainerRuntimeJsonCommand -Provider podman -Arguments @('info','--format','json') -FailureCode 'PODMAN_INFO_FAILED'
        $machines = @(Invoke-LabContainerRuntimeJsonCommand -Provider podman -Arguments @('machine','list','--format','json') -FailureCode 'PODMAN_MACHINE_INSPECTION_FAILED')
        $connections = @(Invoke-LabContainerRuntimeJsonCommand -Provider podman -Arguments @('system','connection','list','--format','json') -FailureCode 'PODMAN_CONNECTION_INSPECTION_FAILED')
        return [PSCustomObject]@{
            Provider='podman'; Available=$true; HostPlatform=if ($IsWindows) { 'windows' } elseif ($IsMacOS) { 'macos' } else { 'linux' }
            Info=$info; Machines=@($machines); Connections=@($connections)
        }
    }
    catch {
        return [PSCustomObject]@{ Provider=$Provider; Available=$false; Issue=[string]$_.Exception.Message }
    }
}

function Get-LabContainerRuntimeHostMode {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$HostPlatform,
        [Parameter(Mandatory)][string]$EndpointKind,
        [AllowNull()][string]$MachineType
    )

    if ($EndpointKind -in @('REMOTE_SSH','REMOTE_TCP')) { return 'REMOTE' }
    if ($HostPlatform -eq 'windows') {
        if ([string]$MachineType -match '^(?i)wsl$') { return 'WINDOWS_WSL2' }
        return 'WINDOWS_VM'
    }
    if ($HostPlatform -eq 'macos') { return 'MACOS_VM' }
    if ($HostPlatform -eq 'linux') { return 'LINUX_NATIVE' }
    return 'UNKNOWN'
}

function Get-LabContainerRuntimeHostBackingEvidence {
    <#
    .SYNOPSIS
        Loest das physische Host-Backing einer lokalen Container-Runtime read-only auf.
    .DESCRIPTION
        Windows-WSL-/VM-Datentraeger und zugehoerige Konfigurationsdateien
        werden nur innerhalb provider-eigener Standardverzeichnisse oder der
        WSL-Registrierung gelesen. Das Ergebnis erteilt keinerlei Mutationsrecht.
        Rohpfade werden nur vom Storage-Residency-Audit konsumiert und nie in
        den sanitisierten Runtime-Scope uebernommen.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Scope,
        [AllowEmptyCollection()][string[]]$KnownRoots = @(),
        [AllowEmptyCollection()][string[]]$CandidateRoots = @(),
        [AllowEmptyCollection()][string[]]$ConfigurationPaths = @(),
        [switch]$UseProvidedPaths
    )

    $provider = ([string]$Scope.Provider).ToLowerInvariant()
    if ($provider -notin @('docker','podman')) { throw 'RUNTIME_PROVIDER_UNSUPPORTED' }
    $items = [Collections.Generic.List[object]]::new()
    $seenPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $hostMode = [string]$Scope.Binding.HostMode

    if ([string]$Scope.Status -eq 'UNAVAILABLE' -or -not $Scope.RuntimeId) {
        return [PSCustomObject]@{ Provider=$provider; RuntimeId=$null; Status='UNVERIFIABLE'; LabDataRelation='UNKNOWN'; DetectedHostMode=$hostMode; Items=@() }
    }
    if ($hostMode -eq 'REMOTE') {
        return [PSCustomObject]@{ Provider=$provider; RuntimeId=[string]$Scope.RuntimeId; Status='REMOTE_EXTERNAL'; LabDataRelation='UNKNOWN'; DetectedHostMode='REMOTE'; Items=@() }
    }

    if (-not $UseProvidedPaths) {
        if ($IsWindows) {
            if ($provider -eq 'docker') {
                $localAppData = [Environment]::GetFolderPath('LocalApplicationData')
                $applicationData = [Environment]::GetFolderPath('ApplicationData')
                if ($localAppData) {
                    $CandidateRoots = @(
                        (Join-Path $localAppData 'Docker\wsl'),
                        (Join-Path $localAppData 'DockerDesktop\vm-data'),
                        (Join-Path $localAppData 'Docker\vm-data')
                    )
                }
                if ($applicationData) {
                    $ConfigurationPaths = @(
                        (Join-Path $applicationData 'Docker\settings-store.json'),
                        (Join-Path $applicationData 'Docker\settings.json')
                    )
                }
            }
            elseif ($Scope.Binding.MachineName) {
                $machineName = [string]$Scope.Binding.MachineName
                $wslKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
                foreach ($key in @(Get-ChildItem -LiteralPath $wslKey -ErrorAction SilentlyContinue)) {
                    try {
                        $distribution = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction Stop
                        if ([string]$distribution.DistributionName -eq $machineName -and $distribution.BasePath) {
                            $CandidateRoots += [Environment]::ExpandEnvironmentVariables([string]$distribution.BasePath)
                        }
                    }
                    catch { continue }
                }
                $userProfile = [Environment]::GetFolderPath('UserProfile')
                if ($userProfile) {
                    $CandidateRoots += Join-Path $userProfile ".local\share\containers\podman\machine\wsl\wsldist\$machineName"
                }
                try {
                    $invocation = Get-LabHostToolInvocation -Name podman
                    $raw = @(& $invocation machine inspect $machineName 2>$null)
                    if ($LASTEXITCODE -eq 0 -and $raw.Count -gt 0) {
                        $machine = @((($raw -join "`n") | ConvertFrom-Json -Depth 30 -ErrorAction Stop))[0]
                        $configDirectory = [string]$machine.ConfigDir.Path
                        if ($configDirectory -and (Test-Path -LiteralPath $configDirectory -PathType Container)) {
                            $ConfigurationPaths += @(Get-ChildItem -LiteralPath $configDirectory -File -Force -ErrorAction SilentlyContinue |
                                Where-Object { $_.Extension -in @('.json','.ign') } | ForEach-Object FullName)
                        }
                    }
                }
                catch { }
            }
        }
        elseif ($hostMode -eq 'LINUX_NATIVE') {
            try {
                $runtimeRoot = Get-LabRuntimeStorageRoot -Provider $provider
                if ($runtimeRoot) { $CandidateRoots = @($runtimeRoot) }
            }
            catch { }
        }
        elseif ($IsMacOS -and $provider -eq 'docker') {
            $userProfile = [Environment]::GetFolderPath('UserProfile')
            if ($userProfile) {
                $ConfigurationPaths = @(Join-Path $userProfile 'Library/Group Containers/group.com.docker/settings-store.json')
                $CandidateRoots = @(Join-Path $userProfile 'Library/Containers/com.docker.docker/Data/vms')
            }
        }
    }

    foreach ($root in @($CandidateRoots | Where-Object { $_ } | Select-Object -Unique)) {
        $candidates = if (Test-Path -LiteralPath $root -PathType Leaf) {
            @(Get-Item -LiteralPath $root -Force -ErrorAction SilentlyContinue)
        }
        elseif (Test-Path -LiteralPath $root -PathType Container) {
            if ($hostMode -eq 'LINUX_NATIVE') { @(Get-Item -LiteralPath $root -Force -ErrorAction SilentlyContinue) }
            else { @(Get-ChildItem -LiteralPath $root -File -Recurse -Force -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in @('.vhdx','.raw') }) }
        }
        else { @() }
        foreach ($file in $candidates) {
            $path = [IO.Path]::GetFullPath([string]$file.FullName)
            if (-not $seenPaths.Add($path)) { continue }
            $relation = Get-LabStoragePathRelation -Path $path -KnownRoots $KnownRoots
            $role = if ($hostMode -eq 'LINUX_NATIVE') { 'DATA' }
                elseif ($file.Name -match '^(?i)(docker_data|ext4)\.vhdx$' -and $path -match '(?i)(disk|wsldist)') { 'DATA' }
                else { 'SYSTEM' }
            $items.Add([PSCustomObject]@{
                Kind='BACKING_STORE'; Role=$role; Path=$path; IsDirectory=[bool]$file.PSIsContainer
                Bytes=if ($file.PSIsContainer) { $null } else { [long]$file.Length }
                LastWriteTimeUtc=[datetime]$file.LastWriteTimeUtc; LabDataRelation=$relation
            })
        }
    }
    foreach ($candidate in @($ConfigurationPaths | Where-Object { $_ } | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
        $file = Get-Item -LiteralPath $candidate -Force -ErrorAction SilentlyContinue
        if (-not $file) { continue }
        $path = [IO.Path]::GetFullPath([string]$file.FullName)
        if (-not $seenPaths.Add($path)) { continue }
        $items.Add([PSCustomObject]@{
            Kind='CONFIGURATION'; Role='RUNTIME_CONFIGURATION'; Path=$path; IsDirectory=$false
            Bytes=[long]$file.Length; LastWriteTimeUtc=[datetime]$file.LastWriteTimeUtc
            LabDataRelation=Get-LabStoragePathRelation -Path $path -KnownRoots $KnownRoots
        })
    }

    $backingStores = @($items | Where-Object Kind -eq 'BACKING_STORE')
    $relations = @($backingStores.LabDataRelation | Sort-Object -Unique)
    $relation = if ($relations.Count -eq 1) { [string]$relations[0] } else { 'UNKNOWN' }
    if ($provider -eq 'docker' -and @($backingStores | Where-Object Path -match '(?i)[\\/]Docker[\\/]wsl[\\/]').Count -gt 0) {
        $hostMode = 'WINDOWS_WSL2'
    }
    $status = if ($backingStores.Count -gt 0) { 'VERIFIED' } else { 'UNVERIFIABLE' }
    return [PSCustomObject]@{
        Provider=$provider; RuntimeId=[string]$Scope.RuntimeId; Status=$status
        LabDataRelation=$relation; DetectedHostMode=$hostMode; Items=@($items)
    }
}

function Set-LabContainerRuntimeScopePhysicalBacking {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Scope, [Parameter(Mandatory)]$Evidence)

    $Scope.PhysicalBacking.HostBackingStatus = [string]$Evidence.Status
    $Scope.PhysicalBacking.LabDataRelation = [string]$Evidence.LabDataRelation
    $Scope.PhysicalBacking | Add-Member -NotePropertyName BackingStoreCount `
        -NotePropertyValue @($Evidence.Items | Where-Object Kind -eq 'BACKING_STORE').Count -Force
    if ([string]$Evidence.DetectedHostMode -in @('WINDOWS_WSL2','WINDOWS_VM','LINUX_NATIVE','MACOS_VM','REMOTE')) {
        $Scope.Binding.HostMode = [string]$Evidence.DetectedHostMode
    }
    if ([string]$Evidence.Status -in @('VERIFIED','REMOTE_EXTERNAL')) {
        $Scope.Issues = @($Scope.Issues | Where-Object { [string]$_ -ne 'RUNTIME_HOST_BACKING_UNVERIFIABLE' })
    }
    return $Scope
}

function ConvertTo-LabContainerRuntimeScope {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Evidence)

    $provider = ([string]$Evidence.Provider).ToLowerInvariant()
    if ($provider -notin @('docker','podman')) { throw 'RUNTIME_PROVIDER_UNSUPPORTED' }
    $blockedActions = @('RELOCATE_RUNTIME_STORAGE','REMOVE_RUNTIME','CHANGE_DEFAULT_CONNECTION','CHANGE_RUNTIME_MODE','ADOPT_FOREIGN_RESOURCES')
    if (-not $Evidence.Available) {
        return [PSCustomObject][ordered]@{
            ContractVersion='SqlServerLab.ContainerRuntimeScope/1.0'; Provider=$provider; Status='UNAVAILABLE'; RuntimeId=$null
            Binding=[PSCustomObject][ordered]@{ DisplayName=$null; EndpointKind='UNKNOWN'; BackendKind='UNKNOWN'; HostMode='UNKNOWN'; EngineVersion=$null; StorageDriver=$null; Rootless=$null; SelectedBy='UNKNOWN'; MachineName=$null; MachineState='UNKNOWN'; MachineCount=0; ConnectionCount=0 }
            Ownership=[PSCustomObject][ordered]@{ Status='UNPROVEN'; MutationPolicy='REPORT_ONLY'; CleanupPolicy='PRESERVE_RUNTIME' }
            PhysicalBacking=[PSCustomObject][ordered]@{ RuntimeNamespaceStatus='UNAVAILABLE'; HostBackingStatus='UNVERIFIABLE'; LabDataRelation='UNKNOWN'; BackingStoreCount=0 }
            AllowedActions=@('INSPECT'); BlockedActions=$blockedActions; Issues=@($(if ($Evidence.Issue) { [string]$Evidence.Issue } else { 'RUNTIME_NOT_AVAILABLE' }))
            Summary=[PSCustomObject][ordered]@{ CanUseLabeledResources=$false; CanManageRuntime=$false; RequiresDedicatedOwnershipContract=$true }
        }
    }

    $issues = [Collections.Generic.List[string]]::new()
    $displayName = $null; $endpoint = $null; $endpointKind = 'UNKNOWN'; $backendKind = 'UNKNOWN'; $hostMode = 'UNKNOWN'
    $engineVersion = $null; $storageDriver = $null; $rootless = $null; $selectedBy = 'UNKNOWN'; $machineName = $null
    $machineState = 'NOT_APPLICABLE'; $machineCount = 0; $connectionCount = 0; $runtimeRoot = $null

    if ($provider -eq 'docker') {
        $contexts = @($Evidence.Contexts)
        if ($contexts.Count -ne 1) { $issues.Add('DOCKER_ACTIVE_CONTEXT_AMBIGUOUS') }
        $context = @($contexts)[0]
        if ($context) {
            $displayName = [string]$context.Name
            $endpoint = [string]$context.Endpoints.docker.Host
            $selectedBy = 'ACTIVE_CONTEXT'
        }
        $endpointKind = Get-LabContainerRuntimeEndpointKind -Endpoint $endpoint
        $description = if ($context) { [string]$context.Metadata.Description } else { '' }
        $backendKind = if ($description -match '(?i)Docker Desktop' -or [string]$Evidence.Info.OperatingSystem -match '(?i)Docker Desktop') { 'DOCKER_DESKTOP' } else { 'DOCKER_ENGINE' }
        $hostMode = Get-LabContainerRuntimeHostMode -HostPlatform ([string]$Evidence.HostPlatform) -EndpointKind $endpointKind
        $engineVersion = [string]$Evidence.Info.ServerVersion; $storageDriver = [string]$Evidence.Info.Driver; $runtimeRoot = [string]$Evidence.Info.DockerRootDir
    }
    else {
        $machines = @($Evidence.Machines); $connections = @($Evidence.Connections)
        $machineCount = $machines.Count; $connectionCount = $connections.Count
        $selected = @($connections | Where-Object { [bool]$_.Default })
        if ($selected.Count -eq 1) { $selected = $selected[0]; $selectedBy = 'DEFAULT_CONNECTION' }
        elseif ($selected.Count -eq 0 -and $connections.Count -eq 1) { $selected = $connections[0]; $selectedBy = 'ONLY_CONNECTION' }
        else { $selected = $null; $issues.Add('PODMAN_ACTIVE_CONNECTION_AMBIGUOUS') }
        if ($selected) {
            $displayName = [string]$selected.Name; $endpoint = [string]$selected.URI
            $endpointKind = Get-LabContainerRuntimeEndpointKind -Endpoint $endpoint
            if ([bool]$selected.IsMachine) {
                $machineMatches = @($machines | Where-Object { [string]$selected.Name -in @([string]$_.Name, "$([string]$_.Name)-root") })
                if ($machineMatches.Count -eq 1) {
                    $machine = $machineMatches[0]; $machineName = [string]$machine.Name
                    $machineState = if ([bool]$machine.Running) { 'RUNNING' } else { 'STOPPED' }
                    $backendKind = 'PODMAN_MACHINE'
                    $hostMode = Get-LabContainerRuntimeHostMode -HostPlatform ([string]$Evidence.HostPlatform) -EndpointKind $endpointKind -MachineType ([string]$machine.VMType)
                }
                else { $issues.Add('PODMAN_MACHINE_BINDING_UNRESOLVED') }
            }
            else {
                $backendKind = 'PODMAN_SERVICE'
                $hostMode = Get-LabContainerRuntimeHostMode -HostPlatform ([string]$Evidence.HostPlatform) -EndpointKind $endpointKind
            }
        }
        $engineVersion = [string]$Evidence.Info.Version.Version; $storageDriver = [string]$Evidence.Info.Store.GraphDriverName
        if ($null -ne $Evidence.Info.Host.Security.Rootless) { $rootless = [bool]$Evidence.Info.Host.Security.Rootless }
        $runtimeRoot = [string]$Evidence.Info.Store.GraphRoot
    }

    if (-not $displayName -or $endpointKind -eq 'UNKNOWN' -or $backendKind -eq 'UNKNOWN') { $issues.Add('RUNTIME_BINDING_INCOMPLETE') }
    $issues.Add('RUNTIME_OWNERSHIP_NOT_PROVEN')
    $issues.Add('RUNTIME_HOST_BACKING_UNVERIFIABLE')
    $identityKey = "$displayName|$endpoint|$backendKind"
    $runtimeId = if ($displayName -and $endpoint) { Get-LabContainerRuntimeScopeId -Provider $provider -IdentityKey $identityKey } else { $null }
    $status = if (@($issues | Where-Object { $_ -match '(AMBIGUOUS|UNRESOLVED|INCOMPLETE)' }).Count) { 'BLOCKED' } else { 'AVAILABLE' }
    $runtimeNamespaceStatus = if ($runtimeRoot) { 'DECLARED' } else { 'UNAVAILABLE' }
    $hostBackingStatus = if ($endpointKind -in @('REMOTE_SSH','REMOTE_TCP')) { 'REMOTE_EXTERNAL' } else { 'UNVERIFIABLE' }

    return [PSCustomObject][ordered]@{
        ContractVersion='SqlServerLab.ContainerRuntimeScope/1.0'; Provider=$provider; Status=$status; RuntimeId=$runtimeId
        Binding=[PSCustomObject][ordered]@{
            DisplayName=if ($displayName) { $displayName } else { $null }; EndpointKind=$endpointKind; BackendKind=$backendKind; HostMode=$hostMode
            EngineVersion=if ($engineVersion) { $engineVersion } else { $null }; StorageDriver=if ($storageDriver) { $storageDriver } else { $null }
            Rootless=$rootless; SelectedBy=$selectedBy; MachineName=if ($machineName) { $machineName } else { $null }; MachineState=$machineState
            MachineCount=$machineCount; ConnectionCount=$connectionCount
        }
        Ownership=[PSCustomObject][ordered]@{ Status='SHARED_EXTERNAL'; MutationPolicy='REPORT_ONLY'; CleanupPolicy='PRESERVE_RUNTIME' }
        PhysicalBacking=[PSCustomObject][ordered]@{ RuntimeNamespaceStatus=$runtimeNamespaceStatus; HostBackingStatus=$hostBackingStatus; LabDataRelation='UNKNOWN'; BackingStoreCount=0 }
        AllowedActions=@('INSPECT','USE_LABELED_RESOURCES'); BlockedActions=$blockedActions; Issues=@($issues | Sort-Object -Unique)
        Summary=[PSCustomObject][ordered]@{ CanUseLabeledResources=($status -eq 'AVAILABLE'); CanManageRuntime=$false; RequiresDedicatedOwnershipContract=$true }
    }
}

function Get-LabContainerRuntimeScope {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('docker','podman')][string]$Provider)

    $evidence = Get-LabContainerRuntimeScopeEvidence -Provider $Provider
    $scope = ConvertTo-LabContainerRuntimeScope -Evidence $evidence
    $backing = Get-LabContainerRuntimeHostBackingEvidence -Scope $scope
    return (Set-LabContainerRuntimeScopePhysicalBacking -Scope $scope -Evidence $backing)
}
