#Requires -Version 7.2
<#
.SYNOPSIS
    Resolves host-side development and provider executables deterministically.
.DESCRIPTION
    Uses an explicit repository-scoped environment override first, then an
    existing session command, persisted Windows PATH entries, and known Windows
    installation locations. Only the current process PATH is extended. User and
    machine environment variables are never persisted or rewritten.
#>

function Get-LabHostToolDefinition {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('docker','podman','python')][string]$Name)

    $localAppData = [Environment]::GetFolderPath('LocalApplicationData')
    $programFiles = [Environment]::GetFolderPath('ProgramFiles')
    $commandNames = switch ($Name) {
        'docker' { @('docker') }
        'podman' { @('podman') }
        'python' { @('python','python3','py') }
    }
    $windowsLeafNames = switch ($Name) {
        'docker' { @('docker.exe','docker.cmd','docker.bat') }
        'podman' { @('podman.exe','podman.cmd','podman.bat') }
        'python' { @('python.exe','python3.exe','py.exe') }
    }
    $acceptedLeafNames = if ($IsWindows) { $windowsLeafNames } else { $commandNames }
    $knownPaths = [System.Collections.Generic.List[string]]::new()
    if ($IsWindows) {
        switch ($Name) {
            'docker' {
                if ($programFiles) { $knownPaths.Add((Join-Path $programFiles 'Docker\Docker\resources\bin\docker.exe')) }
                if ($localAppData) { $knownPaths.Add((Join-Path $localAppData 'Docker\Docker\resources\bin\docker.exe')) }
            }
            'podman' {
                if ($localAppData) { $knownPaths.Add((Join-Path $localAppData 'Programs\Podman\podman.exe')) }
                if ($programFiles) {
                    $knownPaths.Add((Join-Path $programFiles 'RedHat\Podman\podman.exe'))
                    $knownPaths.Add((Join-Path $programFiles 'Podman\podman.exe'))
                }
            }
            'python' {
                if ($localAppData) {
                    $pythonRoot = Join-Path $localAppData 'Programs\Python'
                    if (Test-Path -LiteralPath $pythonRoot -PathType Container -ErrorAction SilentlyContinue) {
                        foreach ($directory in @(Get-ChildItem -LiteralPath $pythonRoot -Directory -Filter 'Python*' -ErrorAction SilentlyContinue | Sort-Object Name -Descending)) {
                            $knownPaths.Add((Join-Path $directory.FullName 'python.exe'))
                        }
                    }
                    $knownPaths.Add((Join-Path $localAppData 'Programs\Python\Launcher\py.exe'))
                }
            }
        }
    }

    [PSCustomObject]@{
        Name = $Name
        OverrideVariable = "SQL_SERVER_LAB_$($Name.ToUpperInvariant())_PATH"
        CommandNames = $commandNames
        AcceptedLeafNames = $acceptedLeafNames
        WindowsLeafNames = $windowsLeafNames
        KnownPaths = @($knownPaths)
    }
}

function Test-LabHostToolPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Definition
    )

    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf -ErrorAction Stop)) { return $false }
    }
    catch { return $false }
    $leafName = [IO.Path]::GetFileName($Path)
    if ($IsWindows) { return $leafName -iin @($Definition.AcceptedLeafNames) }
    return $leafName -cin @($Definition.AcceptedLeafNames)
}

function Add-LabHostToolDirectoryToProcessPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Directory)

    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    $entries = @($env:PATH -split [IO.Path]::PathSeparator | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if (@($entries | Where-Object { [string]::Equals($_.TrimEnd('\','/'), $Directory.TrimEnd('\','/'), $comparison) }).Count -gt 0) {
        return $false
    }
    $env:PATH = "$Directory$([IO.Path]::PathSeparator)$env:PATH"
    return $true
}

function Resolve-LabHostTool {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('docker','podman','python')][string]$Name)

    $definition = Get-LabHostToolDefinition -Name $Name
    $overridePath = [Environment]::GetEnvironmentVariable([string]$definition.OverrideVariable, 'Process')
    if (-not [string]::IsNullOrWhiteSpace($overridePath)) {
        $overridePath = [Environment]::ExpandEnvironmentVariables($overridePath.Trim().Trim('"'))
        if (-not (Test-LabHostToolPath -Path $overridePath -Definition $definition)) {
            throw "HOST_TOOL_OVERRIDE_INVALID: $($definition.OverrideVariable)"
        }
        $directory = Split-Path -Parent $overridePath
        $changed = Add-LabHostToolDirectoryToProcessPath -Directory $directory
        return [PSCustomObject]@{
            Name=$Name; Available=$true; Invocation=$overridePath; Source='EXPLICIT_OVERRIDE'; PathChanged=$changed
        }
    }

    foreach ($commandName in @($definition.CommandNames)) {
        $command = Get-Command $commandName -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($command) {
            $invocation = if ($command.CommandType -eq 'Application') { [string]$command.Source } else { $commandName }
            return [PSCustomObject]@{
                Name=$Name; Available=$true; Invocation=$invocation; Source='SESSION_COMMAND'; PathChanged=$false
            }
        }
    }

    if ($IsWindows) {
        foreach ($scope in @('User','Machine')) {
            $scopePath = [Environment]::GetEnvironmentVariable('Path', $scope)
            foreach ($directory in @($scopePath -split [IO.Path]::PathSeparator | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
                $directory = [Environment]::ExpandEnvironmentVariables($directory.Trim().Trim('"'))
                foreach ($leafName in @($definition.WindowsLeafNames)) {
                    $candidate = Join-Path $directory $leafName
                    if (Test-LabHostToolPath -Path $candidate -Definition $definition) {
                        $changed = Add-LabHostToolDirectoryToProcessPath -Directory (Split-Path -Parent $candidate)
                        return [PSCustomObject]@{
                            Name=$Name; Available=$true; Invocation=$candidate; Source="${scope}_PATH".ToUpperInvariant(); PathChanged=$changed
                        }
                    }
                }
            }
        }
    }

    foreach ($candidate in @($definition.KnownPaths)) {
        if (Test-LabHostToolPath -Path $candidate -Definition $definition) {
            $changed = Add-LabHostToolDirectoryToProcessPath -Directory (Split-Path -Parent $candidate)
            return [PSCustomObject]@{
                Name=$Name; Available=$true; Invocation=$candidate; Source='KNOWN_INSTALL_LOCATION'; PathChanged=$changed
            }
        }
    }

    return [PSCustomObject]@{
        Name=$Name; Available=$false; Invocation=$null; Source='NOT_FOUND'; PathChanged=$false
    }
}

function Initialize-LabHostToolPath {
    [CmdletBinding()]
    param(
        [ValidateSet('docker','podman','python')]
        [string[]]$Name = @('docker','podman','python')
    )

    foreach ($toolName in @($Name | Select-Object -Unique)) {
        Resolve-LabHostTool -Name $toolName
    }
}
