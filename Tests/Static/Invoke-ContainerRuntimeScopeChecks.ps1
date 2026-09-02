#Requires -Version 7.2
<#
.SYNOPSIS
    Prueft den read-only Docker-/Podman-Runtime-Scope-Vertrag.
#>
[CmdletBinding()]
param(
    [Alias('h','help','?')][switch]$ShowHelp,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$RemainingArgs
)

if ($ShowHelp -or @($RemainingArgs) -match '^(-h|--help|/\?|-\?)$') { Get-Help -Full -Name $PSCommandPath | Out-Host; return }
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$module = Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru -ErrorAction Stop
$schemaPath = Join-Path $repoRoot 'Schemas/container-runtime-scope.schema.json'
$failures = [Collections.Generic.List[string]]::new(); $passed = 0
$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) "sql-lab-runtime-backing-$([guid]::NewGuid().ToString('N'))"
. (Join-Path $PSScriptRoot '..' 'Common' 'CheckResult.ps1')
Write-Host ''; Write-Host 'SQL_Server_Lab - Container Runtime Scope Checks' -ForegroundColor Cyan

$dockerEvidence = [PSCustomObject]@{
    Provider='docker'; Available=$true; HostPlatform='windows'
    Contexts=@([PSCustomObject]@{
        Name='desktop-linux'; Metadata=[PSCustomObject]@{ Description='Docker Desktop' }
        Endpoints=[PSCustomObject]@{ docker=[PSCustomObject]@{ Host='npipe:////./pipe/dockerDesktopLinuxEngine' } }
    })
    Info=[PSCustomObject]@{ OperatingSystem='Docker Desktop'; ServerVersion='29.7.2'; Driver='overlayfs'; DockerRootDir='/var/lib/docker' }
}
$docker = & $module { param($e) ConvertTo-LabContainerRuntimeScope -Evidence $e } $dockerEvidence
Add-CheckResult -Name 'Docker-Desktop-Context wird stabil und schemawahr klassifiziert' -Success (
    $docker.Status -eq 'AVAILABLE' -and $docker.Binding.BackendKind -eq 'DOCKER_DESKTOP' -and
    $docker.Binding.EndpointKind -eq 'LOCAL_NPIPE' -and $docker.Binding.HostMode -eq 'WINDOWS_VM' -and
    (($docker | ConvertTo-Json -Depth 20) | Test-Json -SchemaFile $schemaPath))
Add-CheckResult -Name 'Geteilte Docker-Runtime bleibt REPORT_ONLY und nicht loeschbar' -Success (
    $docker.Ownership.Status -eq 'SHARED_EXTERNAL' -and -not $docker.Summary.CanManageRuntime -and
    'REMOVE_RUNTIME' -in @($docker.BlockedActions) -and 'USE_LABELED_RESOURCES' -in @($docker.AllowedActions))

$dockerBackingRoot = Join-Path $temporaryRoot 'Docker\wsl\disk'
$dockerConfiguration = Join-Path $temporaryRoot 'Docker\settings-store.json'
$null = New-Item -ItemType Directory -Path $dockerBackingRoot -Force
$null = New-Item -ItemType Directory -Path (Split-Path -Parent $dockerConfiguration) -Force
[IO.File]::WriteAllBytes((Join-Path $dockerBackingRoot 'docker_data.vhdx'), [byte[]](1..64))
[IO.File]::WriteAllText($dockerConfiguration, '{}')
$dockerBacking = & $module {
    param($Scope,$BackingRoot,$ConfigurationPath)
    Get-LabContainerRuntimeHostBackingEvidence -Scope $Scope -CandidateRoots @($BackingRoot) `
        -ConfigurationPaths @($ConfigurationPath) -UseProvidedPaths
} $docker $dockerBackingRoot $dockerConfiguration
$docker = & $module { param($Scope,$Evidence) Set-LabContainerRuntimeScopePhysicalBacking -Scope $Scope -Evidence $Evidence } $docker $dockerBacking
Add-CheckResult -Name 'Docker-Desktop-Backing wird hostseitig verifiziert und im Scope nur sanitisiert zusammengefasst' -Success (
    $dockerBacking.Status -eq 'VERIFIED' -and @($dockerBacking.Items | Where-Object Kind -eq 'BACKING_STORE').Count -eq 1 -and
    @($dockerBacking.Items | Where-Object Kind -eq 'CONFIGURATION').Count -eq 1 -and
    $docker.Binding.HostMode -eq 'WINDOWS_WSL2' -and $docker.PhysicalBacking.HostBackingStatus -eq 'VERIFIED' -and
    $docker.PhysicalBacking.BackingStoreCount -eq 1 -and 'RUNTIME_HOST_BACKING_UNVERIFIABLE' -notin @($docker.Issues) -and
    (($docker | ConvertTo-Json -Depth 20) | Test-Json -SchemaFile $schemaPath))

$dockerAgain = & $module { param($e) ConvertTo-LabContainerRuntimeScope -Evidence $e } $dockerEvidence
$otherDockerEvidence = $dockerEvidence | ConvertTo-Json -Depth 20 | ConvertFrom-Json -Depth 20
$otherDockerEvidence.Contexts[0].Endpoints.docker.Host = 'npipe:////./pipe/otherEngine'
$otherDocker = & $module { param($e) ConvertTo-LabContainerRuntimeScope -Evidence $e } $otherDockerEvidence
Add-CheckResult -Name 'Runtime-ID ist stabil, aber an den konkreten Endpunkt gebunden' -Success (
    $docker.RuntimeId -eq $dockerAgain.RuntimeId -and $docker.RuntimeId -ne $otherDocker.RuntimeId)

$podmanEvidence = [PSCustomObject]@{
    Provider='podman'; Available=$true; HostPlatform='windows'
    Info=[PSCustomObject]@{
        Version=[PSCustomObject]@{ Version='6.0.2' }
        Store=[PSCustomObject]@{ GraphDriverName='overlay'; GraphRoot='/var/lib/containers/storage' }
        Host=[PSCustomObject]@{ Security=[PSCustomObject]@{ Rootless=$false } }
    }
    Machines=@([PSCustomObject]@{ Name='podman-machine-default'; Running=$true; VMType='wsl' })
    Connections=@(
        [PSCustomObject]@{ Name='podman-machine-default'; URI='ssh://user@127.0.0.1:7000/run/user/1000/podman.sock'; IsMachine=$true; Default=$false },
        [PSCustomObject]@{ Name='podman-machine-default-root'; URI='ssh://root@127.0.0.1:7000/run/podman/podman.sock'; IsMachine=$true; Default=$true }
    )
}
$podman = & $module { param($e) ConvertTo-LabContainerRuntimeScope -Evidence $e } $podmanEvidence
Add-CheckResult -Name 'Podman-Default-Connection bindet eindeutig dieselbe WSL-Machine' -Success (
    $podman.Status -eq 'AVAILABLE' -and $podman.Binding.BackendKind -eq 'PODMAN_MACHINE' -and
    $podman.Binding.EndpointKind -eq 'LOCAL_MACHINE_SSH' -and $podman.Binding.HostMode -eq 'WINDOWS_WSL2' -and
    $podman.Binding.MachineName -eq 'podman-machine-default' -and $podman.Binding.Rootless -eq $false -and
    (($podman | ConvertTo-Json -Depth 20) | Test-Json -SchemaFile $schemaPath))

$podmanBackingRoot = Join-Path $temporaryRoot 'Podman\wsldist\podman-machine-default'
$podmanConfiguration = Join-Path $temporaryRoot 'Podman\podman-machine-default.json'
$null = New-Item -ItemType Directory -Path $podmanBackingRoot -Force
$null = New-Item -ItemType Directory -Path (Split-Path -Parent $podmanConfiguration) -Force
[IO.File]::WriteAllBytes((Join-Path $podmanBackingRoot 'ext4.vhdx'), [byte[]](1..32))
[IO.File]::WriteAllText($podmanConfiguration, '{}')
$podmanBacking = & $module {
    param($Scope,$BackingRoot,$ConfigurationPath)
    Get-LabContainerRuntimeHostBackingEvidence -Scope $Scope -CandidateRoots @($BackingRoot) `
        -ConfigurationPaths @($ConfigurationPath) -UseProvidedPaths
} $podman $podmanBackingRoot $podmanConfiguration
$podman = & $module { param($Scope,$Evidence) Set-LabContainerRuntimeScopePhysicalBacking -Scope $Scope -Evidence $Evidence } $podman $podmanBacking
Add-CheckResult -Name 'Podman-Machine-Disk und Konfiguration werden physisch getrennt verifiziert' -Success (
    $podmanBacking.Status -eq 'VERIFIED' -and @($podmanBacking.Items | Where-Object { $_.Kind -eq 'BACKING_STORE' -and $_.Role -eq 'DATA' }).Count -eq 1 -and
    @($podmanBacking.Items | Where-Object Kind -eq 'CONFIGURATION').Count -eq 1 -and
    $podman.PhysicalBacking.HostBackingStatus -eq 'VERIFIED' -and $podman.PhysicalBacking.BackingStoreCount -eq 1 -and
    (($podman | ConvertTo-Json -Depth 20) | Test-Json -SchemaFile $schemaPath))

$sanitizedJson = @($docker,$podman) | ConvertTo-Json -Depth 20
Add-CheckResult -Name 'Oeffentliche Evidence enthaelt weder Endpunkte noch Host-/Identity-Pfade' -Success (
    $sanitizedJson -notmatch '(?i)(npipe:|ssh://|tcp://|identitypath|dockerrootdir|graphroot|[a-z]:\\\\|/var/lib/)')

$ambiguous = $podmanEvidence | ConvertTo-Json -Depth 20 | ConvertFrom-Json -Depth 20
$ambiguous.Connections[0].Default = $true
$blocked = & $module { param($e) ConvertTo-LabContainerRuntimeScope -Evidence $e } $ambiguous
Add-CheckResult -Name 'Mehrere Default-Connections werden fail-closed blockiert' -Success (
    $blocked.Status -eq 'BLOCKED' -and 'PODMAN_ACTIVE_CONNECTION_AMBIGUOUS' -in @($blocked.Issues) -and
    -not $blocked.Summary.CanUseLabeledResources)

$remote = $podmanEvidence | ConvertTo-Json -Depth 20 | ConvertFrom-Json -Depth 20
$remote.Machines=@(); $remote.Connections=@([PSCustomObject]@{ Name='remote'; URI='ssh://runtime.example.invalid/run/podman.sock'; IsMachine=$false; Default=$true })
$remotePlan = & $module { param($e) ConvertTo-LabContainerRuntimeScope -Evidence $e } $remote
Add-CheckResult -Name 'Remote Podman-Service bleibt EXTERNAL und REPORT_ONLY' -Success (
    $remotePlan.Status -eq 'AVAILABLE' -and $remotePlan.Binding.BackendKind -eq 'PODMAN_SERVICE' -and
    $remotePlan.Binding.HostMode -eq 'REMOTE' -and $remotePlan.PhysicalBacking.HostBackingStatus -eq 'REMOTE_EXTERNAL')

$unavailable = & $module { ConvertTo-LabContainerRuntimeScope -Evidence ([PSCustomObject]@{ Provider='docker'; Available=$false; Issue='RUNTIME_NOT_AVAILABLE' }) }
Add-CheckResult -Name 'Nicht erreichbare Runtime bleibt schemawahr und nicht verwendbar' -Success (
    $unavailable.Status -eq 'UNAVAILABLE' -and -not $unavailable.Summary.CanUseLabeledResources -and
    (($unavailable | ConvertTo-Json -Depth 20) | Test-Json -SchemaFile $schemaPath))

$withSecret = $docker | ConvertTo-Json -Depth 20 | ConvertFrom-Json -Depth 20
$withSecret.Binding | Add-Member -NotePropertyName Endpoint -NotePropertyValue 'synthetic-secret'
Add-CheckResult -Name 'Strenges Schema blockiert zusaetzliche Endpoint- oder Secretfelder' -Success (
    -not (($withSecret | ConvertTo-Json -Depth 20) | Test-Json -SchemaFile $schemaPath -ErrorAction SilentlyContinue))

if (Test-Path -LiteralPath $temporaryRoot) { Remove-Item -LiteralPath $temporaryRoot -Recurse -Force }

Write-Host ''; Write-Host "Ergebnis: $passed PASS, $($failures.Count) FAIL" -ForegroundColor Cyan
if ($failures.Count) { exit 1 }; exit 0
