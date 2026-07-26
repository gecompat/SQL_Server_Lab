function Invoke-LabExternalCommand {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [string] $FilePath,

        [Parameter(Mandatory)]
        [string[]] $Arguments,

        [Parameter()]
        [int[]] $AllowedExitCodes = @(0)
    )

    $output = @(& $FilePath @Arguments 2>&1 | ForEach-Object { [string] $_ })
    $exitCode = $LASTEXITCODE
    if ($exitCode -notin $AllowedExitCodes) {
        throw "External LAB-001 command failed with exit code $exitCode."
    }
    return $output
}

function Get-LabDockerCommand {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $command = Get-Command docker -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        throw 'Docker Engine is required for the Welle 2 container runtime.'
    }
    return $command.Source
}

function Invoke-LabLinuxContainerBootstrap {
    [CmdletBinding()]
    param()

    if (-not $IsLinux) {
        throw 'The Welle 2 container bootstrap requires Linux.'
    }
    $bash = Get-Command bash -ErrorAction SilentlyContinue
    if ($null -eq $bash) {
        throw 'The Linux container bootstrap requires bash.'
    }
    $scriptPath = Join-Path (
        $script:DiagnosticLabRoot
    ) 'Containers/Scripts/bootstrap-linux.sh'
    $output = Invoke-LabExternalCommand `
        -FilePath $bash.Source `
        -Arguments @($scriptPath)
    if ('READY' -notin @($output)) {
        throw 'The Linux container bootstrap did not report READY.'
    }
}

function ConvertFrom-LabSecureString {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [securestring] $SecureValue
    )

    $pointer = [IntPtr]::Zero
    try {
        $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR(
            $SecureValue
        )
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    }
    finally {
        if ($pointer -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
        }
    }
}

function Resolve-LabSqlContainerImage {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Configuration,

        [Parameter(Mandatory)]
        [ValidateSet(2019, 2022, 2025)]
        [int] $SqlVersion
    )

    $logicalImageId = [string] (
        $Configuration.ContainerImageLogicalIds[[string] $SqlVersion]
    )
    if ($logicalImageId -notmatch '^[A-Z0-9_]+$') {
        throw 'No bounded SQL Server image mapping exists for the requested version.'
    }
    $lock = Get-Content `
        -LiteralPath $Configuration.ImageLockPath `
        -Raw `
        -Encoding utf8 |
        ConvertFrom-Json -Depth 100
    $image = @($lock.Images) |
        Where-Object {
            $_.LogicalImageId -eq $logicalImageId -and
            $_.ProductVersion -eq [string] $SqlVersion
        } |
        Select-Object -First 1

    if ($null -eq $image -or $image.Status -ne 'LOCKED') {
        throw 'The SQL Server container image is not locked.'
    }
    $readableReference = [string] $image.ReadableReference
    $digest = [string] $image.Digest
    if (
        $readableReference -notmatch
        '^mcr\.microsoft\.com/mssql/server:[A-Za-z0-9._-]+$' -or
        $digest -notmatch '^sha256:[a-f0-9]{64}$'
    ) {
        throw 'The SQL Server container image reference or digest is invalid.'
    }
    return "$readableReference@$digest"
}

function Get-LabComposeProjectName {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $LabRunId
    )

    Test-LabRunId -LabRunId $LabRunId -ThrowOnInvalid | Out-Null
    return ('lab001-' + $LabRunId.Substring($LabRunId.Length - 8).ToLowerInvariant())
}

function Invoke-LabDockerCompose {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [string] $DockerCommand,

        [Parameter(Mandatory)]
        [string] $ProjectName,

        [Parameter(Mandatory)]
        [string[]] $Arguments
    )

    $composePath = Join-Path $script:DiagnosticLabRoot 'Containers/compose.yaml'
    $dockerOverridePath = Join-Path (
        $script:DiagnosticLabRoot
    ) 'Containers/compose.docker.yaml'
    return Invoke-LabExternalCommand `
        -FilePath $DockerCommand `
        -Arguments (@(
            'compose'
            '--project-name'
            $ProjectName
            '--file'
            $composePath
            '--file'
            $dockerOverridePath
        ) + $Arguments)
}

function Get-LabDockerObjectLabel {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $DockerCommand,

        [Parameter(Mandatory)]
        [ValidateSet('CONTAINER', 'NETWORK', 'VOLUME')]
        [string] $ResourceType,

        [Parameter(Mandatory)]
        [string] $ExactLocator
    )

    $noun = $ResourceType.ToLowerInvariant()
    $format = if ($ResourceType -eq 'CONTAINER') {
        '{{ index .Config.Labels "lab001.run-id" }}'
    }
    else {
        '{{ index .Labels "lab001.run-id" }}'
    }
    $output = Invoke-LabExternalCommand `
        -FilePath $DockerCommand `
        -Arguments @($noun, 'inspect', '--format', $format, $ExactLocator)
    return [string] ($output | Select-Object -First 1)
}

function Remove-LabDockerResource {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $LabRunId,

        [Parameter(Mandatory)]
        [ValidateSet('CONTAINER', 'NETWORK', 'VOLUME')]
        [string] $ResourceType,

        [Parameter(Mandatory)]
        [string] $ExactLocator
    )

    $dockerCommand = Get-LabDockerCommand
    $noun = $ResourceType.ToLowerInvariant()
    $existsOutput = Invoke-LabExternalCommand `
        -FilePath $dockerCommand `
        -Arguments @($noun, 'inspect', $ExactLocator) `
        -AllowedExitCodes @(0, 1)
    if ($LASTEXITCODE -eq 1 -or $existsOutput.Count -eq 0) {
        return
    }

    $owner = Get-LabDockerObjectLabel `
        -DockerCommand $dockerCommand `
        -ResourceType $ResourceType `
        -ExactLocator $ExactLocator
    if ($owner -ne $LabRunId) {
        throw 'Docker resource ownership does not match the cleanup run.'
    }

    $arguments = switch ($ResourceType) {
        'CONTAINER' { @('container', 'rm', '--force', $ExactLocator) }
        'NETWORK' { @('network', 'rm', $ExactLocator) }
        'VOLUME' { @('volume', 'rm', $ExactLocator) }
    }
    Invoke-LabExternalCommand `
        -FilePath $dockerCommand `
        -Arguments $arguments |
        Out-Null
}

function Get-LabRunDockerResources {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $DockerCommand,

        [Parameter(Mandatory)]
        [string] $ProjectName,

        [Parameter(Mandatory)]
        [string] $LabRunId
    )

    $containerCandidates = @(
        Invoke-LabDockerCompose `
            -DockerCommand $DockerCommand `
            -ProjectName $ProjectName `
            -Arguments @('ps', '--all', '--quiet', 'sql') |
            Where-Object { $_ -match '^[a-f0-9]{12,64}$' }
    )
    $networkCandidates = @(
        Invoke-LabExternalCommand `
            -FilePath $DockerCommand `
            -Arguments @(
                'network'
                'ls'
                '--filter'
                "label=lab001.run-id=$LabRunId"
                '--format'
                '{{.ID}}'
            ) |
            Where-Object { $_ -match '^[a-f0-9]{12,64}$' }
    )
    if (
        $containerCandidates.Count -ne 1 -or
        $networkCandidates.Count -ne 1
    ) {
        throw 'CTR-SINGLE did not resolve to exactly one container and network.'
    }
    $containerId = Invoke-LabExternalCommand `
        -FilePath $DockerCommand `
        -Arguments @(
            'container'
            'inspect'
            '--format'
            '{{.Id}}'
            $containerCandidates[0]
        ) |
        Select-Object -First 1
    $networkId = Invoke-LabExternalCommand `
        -FilePath $DockerCommand `
        -Arguments @(
            'network'
            'inspect'
            '--format'
            '{{.Id}}'
            $networkCandidates[0]
        ) |
        Select-Object -First 1
    if (
        [string] $containerId -notmatch '^[a-f0-9]{64}$' -or
        [string] $networkId -notmatch '^[a-f0-9]{64}$'
    ) {
        throw 'Docker did not return canonical full object IDs.'
    }
    return [pscustomobject] @{
        ContainerId = [string] $containerId
        NetworkId = [string] $networkId
    }
}

function Register-LabDiscoveredDockerResources {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $DockerCommand,

        [Parameter(Mandatory)]
        [string] $LabRunId,

        [Parameter(Mandatory)]
        [string] $StateRoot
    )

    $paths = Initialize-LabRunState -LabRunId $LabRunId -StateRoot $StateRoot
    $registry = Read-LabJsonFile -Path $paths.RegistryPath
    $registeredLocators = @($registry.Resources | ForEach-Object {
            [string] $_.ExactLocator
        })
    $definitions = @(
        @{
            Type = 'CONTAINER'
            Command = @(
                'container'
                'ls'
                '--all'
                '--filter'
                "label=lab001.run-id=$LabRunId"
                '--format'
                '{{.ID}}'
            )
        }
        @{
            Type = 'NETWORK'
            Command = @(
                'network'
                'ls'
                '--filter'
                "label=lab001.run-id=$LabRunId"
                '--format'
                '{{.ID}}'
            )
        }
    )
    foreach ($definition in $definitions) {
        $candidates = @(
            Invoke-LabExternalCommand `
                -FilePath $DockerCommand `
                -Arguments $definition.Command
        )
        $ordinal = 0
        foreach ($candidate in $candidates) {
            $ordinal++
            $locator = [string] (
                Invoke-LabExternalCommand `
                    -FilePath $DockerCommand `
                    -Arguments @(
                        $definition.Type.ToLowerInvariant()
                        'inspect'
                        '--format'
                        '{{.Id}}'
                        $candidate
                    ) |
                    Select-Object -First 1
            )
            if ($locator -in $registeredLocators) {
                continue
            }
            $owner = Get-LabDockerObjectLabel `
                -DockerCommand $DockerCommand `
                -ResourceType $definition.Type `
                -ExactLocator $locator
            if ($owner -ne $LabRunId) {
                throw 'Discovered Docker resource has an invalid run label.'
            }
            Register-LabResource `
                -LabRunId $LabRunId `
                -Provider DOCKER `
                -ResourceType $definition.Type `
                -ResourceId (
                    'RECOVERY_' + $definition.Type + '_' +
                    $ordinal.ToString('00')
                ) `
                -ExactLocator $locator `
                -StateRoot $StateRoot
            $registeredLocators += $locator
        }
    }
}

function Wait-LabSqlContainerHealthy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $DockerCommand,

        [Parameter(Mandatory)]
        [ValidatePattern('^[a-f0-9]{64}$')]
        [string] $ContainerId,

        [Parameter()]
        [ValidateRange(30, 900)]
        [int] $TimeoutSeconds = 300
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $status = Invoke-LabExternalCommand `
            -FilePath $DockerCommand `
            -Arguments @(
                'container'
                'inspect'
                '--format'
                '{{.State.Health.Status}}'
                $ContainerId
            ) |
            Select-Object -First 1
        if ($status -eq 'healthy') {
            return
        }
        if ($status -eq 'unhealthy') {
            throw 'The SQL Server container health check failed.'
        }
        Start-Sleep -Seconds 5
    }
    while ([DateTime]::UtcNow -lt $deadline)
    throw 'The SQL Server container health check timed out.'
}
