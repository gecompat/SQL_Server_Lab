#Requires -Version 7.2
<#
.SYNOPSIS
    Resolves SQL_Server_Lab host tools and repairs the current process PATH.
.DESCRIPTION
    Resolves Docker, Podman, and Python without changing persisted user or
    machine environment variables. Exact paths can be supplied through
    SQL_SERVER_LAB_DOCKER_PATH, SQL_SERVER_LAB_PODMAN_PATH, and
    SQL_SERVER_LAB_PYTHON_PATH.
.EXAMPLE
    .\Tools\Initialize-SqlServerLabHostTools.ps1
.OUTPUTS
    One sanitized resolution record per requested tool.
#>
[CmdletBinding()]
param(
    [ValidateSet('docker','podman','python')]
    [string[]]$Name = @('docker','podman','python')
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $repoRoot 'Private\HostToolResolution.ps1')
Initialize-LabHostToolPath -Name $Name
