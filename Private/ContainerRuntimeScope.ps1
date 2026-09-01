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

    $output = @(& $Provider @Arguments 2>$null)
    if ($LASTEXITCODE -ne 0 -or $output.Count -eq 0) { throw $FailureCode }
    try { return (($output -join "`n") | ConvertFrom-Json -Depth 30 -ErrorAction Stop) }
    catch { throw $FailureCode }
}

function Get-LabContainerRuntimeScopeEvidence {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('docker','podman')][string]$Provider)

    if (-not (Get-Command $Provider -ErrorAction SilentlyContinue)) {
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
            PhysicalBacking=[PSCustomObject][ordered]@{ RuntimeNamespaceStatus='UNAVAILABLE'; HostBackingStatus='UNVERIFIABLE'; LabDataRelation='UNKNOWN' }
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
        PhysicalBacking=[PSCustomObject][ordered]@{ RuntimeNamespaceStatus=$runtimeNamespaceStatus; HostBackingStatus=$hostBackingStatus; LabDataRelation='UNKNOWN' }
        AllowedActions=@('INSPECT','USE_LABELED_RESOURCES'); BlockedActions=$blockedActions; Issues=@($issues | Sort-Object -Unique)
        Summary=[PSCustomObject][ordered]@{ CanUseLabeledResources=($status -eq 'AVAILABLE'); CanManageRuntime=$false; RequiresDedicatedOwnershipContract=$true }
    }
}

function Get-LabContainerRuntimeScope {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('docker','podman')][string]$Provider)

    $evidence = Get-LabContainerRuntimeScopeEvidence -Provider $Provider
    return ConvertTo-LabContainerRuntimeScope -Evidence $evidence
}
