function New-LabStandaloneInstaller {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $RunDirectory
    )

    $installerDirectory = Join-Path $RunDirectory 'runtime/installer'
    [IO.Directory]::CreateDirectory($installerDirectory) | Out-Null
    $outputPath = Join-Path $installerDirectory 'Install_All.generated.sql'
    $builderPath = [IO.Path]::GetFullPath(
        (Join-Path $script:DiagnosticLabRoot '../Code/Install/Build-StandaloneInstaller.ps1')
    )
    & $builderPath `
        -RepositoryRoot ([IO.Path]::GetFullPath(
            (Join-Path $script:DiagnosticLabRoot '..')
        )) `
        -OutputPath $outputPath
    if (-not (Test-Path -LiteralPath $outputPath -PathType Leaf)) {
        throw 'The standalone framework installer was not generated.'
    }

    $content = [IO.File]::ReadAllText($outputPath, [Text.Encoding]::UTF8)
    $content = $content.Replace('[DeineDatenbank]', '[LabAnalyze]')
    [IO.File]::WriteAllText(
        $outputPath,
        $content,
        [Text.UTF8Encoding]::new($false)
    )
    return $outputPath
}

function Get-LabSqlCmdDockerArguments {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[a-f0-9]{64}$')]
        [string] $ContainerId,

        [Parameter(Mandatory)]
        [ValidatePattern('^/lab/runtime/[A-Za-z0-9_./-]+\.sql$')]
        [string] $ContainerSqlPath,

        [Parameter()]
        [hashtable] $SqlCmdVariables = @{},

        [Parameter()]
        [ValidateRange(1, 600)]
        [int] $QueryTimeoutSeconds = 300
    )

    $arguments = [Collections.Generic.List[string]]::new()
    foreach ($argument in @(
            'exec',
            $ContainerId,
            '/bin/bash',
            '-c',
            (
                'sqlcmd_path="$(command -v sqlcmd 2>/dev/null || true)"; ' +
                'if [ -z "$sqlcmd_path" ]; then ' +
                'for candidate in /opt/mssql-tools18/bin/sqlcmd ' +
                '/opt/mssql-tools/bin/sqlcmd; do ' +
                'if [ -x "$candidate" ]; then sqlcmd_path="$candidate"; break; fi; ' +
                'done; fi; ' +
                'if [ -z "$sqlcmd_path" ]; then exit 127; fi; ' +
                'export SQLCMDPASSWORD="$MSSQL_SA_PASSWORD"; ' +
                'exec "$sqlcmd_path" "$@"'
            ),
            'lab-sqlcmd',
            '-C',
            '-b',
            '-S',
            'localhost',
            '-U',
            'sa',
            '-h',
            '-1',
            '-W',
            '-t',
            [string] $QueryTimeoutSeconds,
            '-i',
            $ContainerSqlPath
        )) {
        $arguments.Add([string] $argument)
    }

    foreach ($name in @($SqlCmdVariables.Keys | Sort-Object)) {
        $value = [string] $SqlCmdVariables[$name]
        if (
            [string] $name -notmatch '^[A-Za-z][A-Za-z0-9_]{0,63}$' -or
            $value -notmatch '^[A-Za-z0-9_.-]{1,128}$'
        ) {
            throw 'A sqlcmd variable is outside the bounded LAB-001 contract.'
        }
        $arguments.Add('-v')
        $arguments.Add("$name=$value")
    }
    return $arguments.ToArray()
}

function Invoke-LabSqlFile {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [string] $DockerCommand,

        [Parameter(Mandatory)]
        [ValidatePattern('^[a-f0-9]{64}$')]
        [string] $ContainerId,

        [Parameter(Mandatory)]
        [ValidatePattern('^/lab/runtime/[A-Za-z0-9_./-]+\.sql$')]
        [string] $ContainerSqlPath,

        [Parameter()]
        [hashtable] $SqlCmdVariables = @{},

        [Parameter()]
        [int[]] $AllowedExitCodes = @(0),

        [Parameter()]
        [ValidateRange(1, 600)]
        [int] $QueryTimeoutSeconds = 300
    )

    return Invoke-LabExternalCommand `
        -FilePath $DockerCommand `
        -Arguments (Get-LabSqlCmdDockerArguments `
            -ContainerId $ContainerId `
            -ContainerSqlPath $ContainerSqlPath `
            -SqlCmdVariables $SqlCmdVariables `
            -QueryTimeoutSeconds $QueryTimeoutSeconds) `
        -AllowedExitCodes $AllowedExitCodes
}

function Install-LabFramework {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $DockerCommand,

        [Parameter(Mandatory)]
        [ValidatePattern('^[a-f0-9]{64}$')]
        [string] $ContainerId,

        [Parameter(Mandatory)]
        [string] $RunDirectory
    )

    $installerPath = New-LabStandaloneInstaller -RunDirectory $RunDirectory
    $preparePath = Join-Path (
        Split-Path -Parent $installerPath
    ) 'Prepare_Framework_Database.sql'
    $prepareSql = @'
SET NOCOUNT ON;
IF DB_ID(N'LabAnalyze') IS NULL
BEGIN
    CREATE DATABASE [LabAnalyze]
    COLLATE SQL_Latin1_General_CP1_CS_AS;
END;
'@
    [IO.File]::WriteAllText(
        $preparePath,
        $prepareSql,
        [Text.UTF8Encoding]::new($false)
    )

    Invoke-LabSqlFile `
        -DockerCommand $DockerCommand `
        -ContainerId $ContainerId `
        -ContainerSqlPath '/lab/runtime/installer/Prepare_Framework_Database.sql' |
        Out-Null
    Invoke-LabSqlFile `
        -DockerCommand $DockerCommand `
        -ContainerId $ContainerId `
        -ContainerSqlPath '/lab/runtime/installer/Install_All.generated.sql' |
        Out-Null
}
