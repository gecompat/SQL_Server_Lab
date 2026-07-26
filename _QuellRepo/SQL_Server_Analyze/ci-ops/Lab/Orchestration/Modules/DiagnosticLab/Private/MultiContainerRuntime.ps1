function Get-LabWave4TopologyPlan {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('CTR-PAIR', 'CTR-TRIPLE')]
        [string] $TopologyId
    )

    $nodes = [Collections.Generic.List[object]]::new()
    $nodes.Add([pscustomobject] @{
            Ordinal = 1
            Role = 'SQL_PRIMARY'
            ServiceName = 'sql-primary'
            ResourceId = 'SQL_PRIMARY_CONTAINER'
            DataLeaf = 'sql-primary'
            Hostname = 'lab-sql-primary'
        })
    $nodes.Add([pscustomobject] @{
            Ordinal = 2
            Role = 'SQL_SECONDARY'
            ServiceName = 'sql-secondary'
            ResourceId = 'SQL_SECONDARY_CONTAINER'
            DataLeaf = 'sql-secondary'
            Hostname = 'lab-sql-secondary'
        })
    if ($TopologyId -eq 'CTR-TRIPLE') {
        $nodes.Add([pscustomobject] @{
                Ordinal = 3
                Role = 'SQL_TERTIARY'
                ServiceName = 'sql-tertiary'
                ResourceId = 'SQL_TERTIARY_CONTAINER'
                DataLeaf = 'sql-tertiary'
                Hostname = 'lab-sql-tertiary'
            })
    }

    return [pscustomobject] @{
        TopologyId = $TopologyId
        ResourceProfile = 'Standard'
        ManagementPath = 'DOCKER_EXEC_OUT_OF_BAND'
        NetworkSegments = @('LAB_MANAGEMENT', 'LAB_DATA')
        Nodes = $nodes.ToArray()
    }
}

function Invoke-LabWave4DockerCompose {
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

    $composePath = Join-Path $script:DiagnosticLabRoot 'Containers/wave4.compose.yaml'
    $dockerOverridePath = Join-Path (
        $script:DiagnosticLabRoot
    ) 'Containers/wave4.compose.docker.yaml'
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

function Get-LabWave4DockerLabel {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $DockerCommand,

        [Parameter(Mandatory)]
        [ValidateSet('CONTAINER', 'NETWORK')]
        [string] $ResourceType,

        [Parameter(Mandatory)]
        [ValidatePattern('^[a-f0-9]{64}$')]
        [string] $ExactLocator,

        [Parameter(Mandatory)]
        [ValidatePattern('^lab001\.[a-z0-9-]+$')]
        [string] $LabelName
    )

    $noun = $ResourceType.ToLowerInvariant()
    $template = if ($ResourceType -eq 'CONTAINER') {
        '{{ index .Config.Labels "__LABEL__" }}'
    }
    else {
        '{{ index .Labels "__LABEL__" }}'
    }
    $format = $template.Replace('__LABEL__', $LabelName)
    return [string] (
        Invoke-LabExternalCommand `
            -FilePath $DockerCommand `
            -Arguments @($noun, 'inspect', '--format', $format, $ExactLocator) |
            Select-Object -First 1
    )
}

function Get-LabWave4ServiceContainerId {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $DockerCommand,

        [Parameter(Mandatory)]
        [string] $ProjectName,

        [Parameter(Mandatory)]
        [ValidateSet('sql-primary', 'sql-secondary', 'sql-tertiary')]
        [string] $ServiceName
    )

    $candidates = @(
        Invoke-LabWave4DockerCompose `
            -DockerCommand $DockerCommand `
            -ProjectName $ProjectName `
            -Arguments @('ps', '--all', '--quiet', $ServiceName) |
            Where-Object { $_ -match '^[a-f0-9]{12,64}$' }
    )
    if ($candidates.Count -ne 1) {
        throw "Welle 4 service $ServiceName did not resolve to exactly one container."
    }
    $containerId = [string] (
        Invoke-LabExternalCommand `
            -FilePath $DockerCommand `
            -Arguments @(
                'container'
                'inspect'
                '--format'
                '{{.Id}}'
                $candidates[0]
            ) |
            Select-Object -First 1
    )
    if ($containerId -notmatch '^[a-f0-9]{64}$') {
        throw 'Docker did not return a canonical full container ID.'
    }
    return $containerId
}

function Get-LabWave4NetworkResources {
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [string] $DockerCommand,

        [Parameter(Mandatory)]
        [string] $LabRunId,

        [Parameter(Mandatory)]
        [ValidateSet('CTR-PAIR', 'CTR-TRIPLE')]
        [string] $TopologyId
    )

    $candidates = @(
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
    $resources = [Collections.Generic.List[object]]::new()
    foreach ($candidate in $candidates) {
        $networkId = [string] (
            Invoke-LabExternalCommand `
                -FilePath $DockerCommand `
                -Arguments @(
                    'network'
                    'inspect'
                    '--format'
                    '{{.Id}}'
                    $candidate
                ) |
                Select-Object -First 1
        )
        if ($networkId -notmatch '^[a-f0-9]{64}$') {
            throw 'Docker did not return a canonical full network ID.'
        }
        $owner = Get-LabWave4DockerLabel `
            -DockerCommand $DockerCommand `
            -ResourceType NETWORK `
            -ExactLocator $networkId `
            -LabelName 'lab001.owner'
        $runOwner = Get-LabWave4DockerLabel `
            -DockerCommand $DockerCommand `
            -ResourceType NETWORK `
            -ExactLocator $networkId `
            -LabelName 'lab001.run-id'
        $topology = Get-LabWave4DockerLabel `
            -DockerCommand $DockerCommand `
            -ResourceType NETWORK `
            -ExactLocator $networkId `
            -LabelName 'lab001.topology'
        $segment = Get-LabWave4DockerLabel `
            -DockerCommand $DockerCommand `
            -ResourceType NETWORK `
            -ExactLocator $networkId `
            -LabelName 'lab001.segment'
        if (
            $owner -ne 'SQL_SERVER_ANALYZE' -or
            $runOwner -ne $LabRunId -or
            $topology -ne $TopologyId -or
            $segment -notin @('LAB_MANAGEMENT', 'LAB_DATA')
        ) {
            throw 'A discovered Welle 4 network failed its ownership contract.'
        }
        $resources.Add([pscustomobject] @{
                Segment = $segment
                NetworkId = $networkId
                ResourceId = $segment + '_NETWORK'
            })
    }
    $segments = @($resources | Select-Object -ExpandProperty Segment -Unique | Sort-Object)
    if (
        $resources.Count -ne 2 -or
        ($segments -join ',') -ne 'LAB_DATA,LAB_MANAGEMENT'
    ) {
        throw 'Welle 4 requires exactly one management and one data network.'
    }
    return $resources.ToArray()
}

function Assert-LabWave4ContainerOwnership {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $DockerCommand,

        [Parameter(Mandatory)]
        [ValidatePattern('^[a-f0-9]{64}$')]
        [string] $ContainerId,

        [Parameter(Mandatory)]
        [string] $LabRunId,

        [Parameter(Mandatory)]
        [ValidateSet('CTR-PAIR', 'CTR-TRIPLE')]
        [string] $TopologyId,

        [Parameter(Mandatory)]
        [ValidateSet('SQL_PRIMARY', 'SQL_SECONDARY', 'SQL_TERTIARY')]
        [string] $Role
    )

    $labels = @{
        Owner = Get-LabWave4DockerLabel -DockerCommand $DockerCommand -ResourceType CONTAINER -ExactLocator $ContainerId -LabelName 'lab001.owner'
        RunId = Get-LabWave4DockerLabel -DockerCommand $DockerCommand -ResourceType CONTAINER -ExactLocator $ContainerId -LabelName 'lab001.run-id'
        Topology = Get-LabWave4DockerLabel -DockerCommand $DockerCommand -ResourceType CONTAINER -ExactLocator $ContainerId -LabelName 'lab001.topology'
        Role = Get-LabWave4DockerLabel -DockerCommand $DockerCommand -ResourceType CONTAINER -ExactLocator $ContainerId -LabelName 'lab001.role'
    }
    if (
        $labels.Owner -ne 'SQL_SERVER_ANALYZE' -or
        $labels.RunId -ne $LabRunId -or
        $labels.Topology -ne $TopologyId -or
        $labels.Role -ne $Role
    ) {
        throw "The Welle 4 container for role $Role failed its ownership contract."
    }
}

function Invoke-LabContainerSqlScalar {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $DockerCommand,

        [Parameter(Mandatory)]
        [ValidatePattern('^[a-f0-9]{64}$')]
        [string] $ContainerId,

        [Parameter(Mandatory)]
        [ValidateLength(1, 1000)]
        [string] $Query
    )

    $output = Invoke-LabExternalCommand `
        -FilePath $DockerCommand `
        -Arguments @(
            'exec'
            $ContainerId
            '/bin/bash'
            '-c'
            (
                'sqlcmd_path="$(command -v sqlcmd 2>/dev/null || true)"; ' +
                'if [ -z "$sqlcmd_path" ]; then ' +
                'for candidate in /opt/mssql-tools18/bin/sqlcmd /opt/mssql-tools/bin/sqlcmd; do ' +
                'if [ -x "$candidate" ]; then sqlcmd_path="$candidate"; break; fi; done; fi; ' +
                'if [ -z "$sqlcmd_path" ]; then exit 127; fi; ' +
                'export SQLCMDPASSWORD="$MSSQL_SA_PASSWORD"; ' +
                'exec "$sqlcmd_path" "$@"'
            )
            'lab-wave4-sqlcmd'
            '-C'
            '-b'
            '-S'
            'localhost'
            '-U'
            'sa'
            '-h'
            '-1'
            '-W'
            '-Q'
            $Query
        )
    return [string] (
        $output |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Select-Object -First 1
    )
}
