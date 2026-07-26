function Get-ComposeArguments {
    param([Parameter(Mandatory)][hashtable] $Env)

    $arguments = [Collections.Generic.List[string]]::new()
    foreach ($value in @('compose', '--env-file', $script:EnvPath, '-f', $script:ComposePath)) {
        $arguments.Add([string] $value)
    }
    if ($Env.QUICKSTART_RUNTIME_MODE -eq 'DOCKER_DESKTOP_WINDOWS') {
        if (-not (Test-Path -LiteralPath $script:DockerDesktopComposePath -PathType Leaf)) {
            throw 'Die Docker-Desktop-Compose-Erweiterung fehlt.'
        }
        foreach ($value in @('-f', $script:DockerDesktopComposePath)) {
            $arguments.Add([string] $value)
        }
    }
    if ($Env.IO_PROFILE -eq 'SLOW_IO') {
        foreach ($value in @('-f', $script:SlowIoComposePath)) {
            $arguments.Add([string] $value)
        }
    }
    return $arguments.ToArray()
}

function Invoke-Compose {
    param(
        [Parameter(Mandatory)][hashtable] $Env,
        [Parameter(Mandatory)][string[]] $Arguments,
        [switch] $Quiet
    )

    $compose = [Collections.Generic.List[string]]::new()
    foreach ($argument in @(Get-ComposeArguments -Env $Env)) {
        $compose.Add($argument)
    }
    foreach ($argument in $Arguments) {
        $compose.Add($argument)
    }
    return Invoke-ExternalCommand -FilePath 'docker' -Arguments $compose.ToArray() -Quiet:$Quiet
}

function Assert-DockerResourceOwnership {
    param([Parameter(Mandatory)][hashtable] $Env)

    $projectName = [string] $Env.COMPOSE_PROJECT_NAME
    $scopeId = [string] $Env.QUICKSTART_SCOPE_ID

    $containerIds = @(
        Invoke-ExternalCommand -FilePath 'docker' -Arguments @(
            'ps', '-a',
            '--filter', "label=com.docker.compose.project=$projectName",
            '--format', '{{.ID}}'
        ) -Quiet | Where-Object { -not [string]::IsNullOrWhiteSpace([string] $_) }
    )
    foreach ($containerId in $containerIds) {
        $labels = Get-FirstOutputLine -InputObject @(
            Invoke-ExternalCommand -FilePath 'docker' -Arguments @(
                'inspect', '--format',
                '{{ index .Config.Labels "quickstart.owner" }}|{{ index .Config.Labels "quickstart.scope" }}',
                ([string] $containerId).Trim()
            ) -Quiet
        )
        if ($labels -ne "SQL_SERVER_ANALYZE_QUICKSTART|$scopeId") {
            throw "Ein vorhandener Container des Compose-Projekts '$projectName' trägt nicht den erwarteten QuickStart-Owner- und Scope-Marker. Es erfolgt keine Mutation."
        }
    }

    $networkIds = @(
        Invoke-ExternalCommand -FilePath 'docker' -Arguments @(
            'network', 'ls',
            '--filter', "label=com.docker.compose.project=$projectName",
            '--format', '{{.ID}}'
        ) -Quiet | Where-Object { -not [string]::IsNullOrWhiteSpace([string] $_) }
    )
    foreach ($networkId in $networkIds) {
        $labels = Get-FirstOutputLine -InputObject @(
            Invoke-ExternalCommand -FilePath 'docker' -Arguments @(
                'network', 'inspect', '--format',
                '{{ index .Labels "quickstart.owner" }}|{{ index .Labels "quickstart.scope" }}',
                ([string] $networkId).Trim()
            ) -Quiet
        )
        if ($labels -ne "SQL_SERVER_ANALYZE_QUICKSTART|$scopeId") {
            throw "Ein vorhandenes Netzwerk des Compose-Projekts '$projectName' trägt nicht den erwarteten QuickStart-Owner- und Scope-Marker. Es erfolgt keine Mutation."
        }
    }

    $volumeNames = @(
        Invoke-ExternalCommand -FilePath 'docker' -Arguments @(
            'volume', 'ls',
            '--filter', "label=com.docker.compose.project=$projectName",
            '--format', '{{.Name}}'
        ) -Quiet | Where-Object { -not [string]::IsNullOrWhiteSpace([string] $_) }
    )
    foreach ($volumeName in $volumeNames) {
        $labels = Get-FirstOutputLine -InputObject @(
            Invoke-ExternalCommand -FilePath 'docker' -Arguments @(
                'volume', 'inspect', '--format',
                '{{ index .Labels "quickstart.owner" }}|{{ index .Labels "quickstart.scope" }}',
                ([string] $volumeName).Trim()
            ) -Quiet
        )
        if ($labels -ne "SQL_SERVER_ANALYZE_QUICKSTART|$scopeId") {
            throw "Ein vorhandenes Volume des Compose-Projekts '$projectName' trägt nicht den erwarteten QuickStart-Owner- und Scope-Marker. Es erfolgt keine Mutation."
        }
    }
}

function Get-ServiceContainerId {
    param(
        [Parameter(Mandatory)][hashtable] $Env,
        [Parameter(Mandatory)][string] $Service
    )

    $containerIds = @(
        Invoke-Compose -Env $Env -Arguments @('ps', '-q', $Service) -Quiet |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string] $_) }
    )
    if ($containerIds.Count -ne 1) {
        throw "Service '$Service' besitzt keinen eindeutigen Container."
    }
    return ([string] $containerIds[0]).Trim()
}

function Get-PublishedSqlEndpoint {
    param(
        [Parameter(Mandatory)][hashtable] $Env,
        [Parameter(Mandatory)][string] $Service
    )

    $containerId = Get-ServiceContainerId -Env $Env -Service $Service
    $inspectText = @(
        Invoke-ExternalCommand -FilePath 'docker' -Arguments @('inspect', $containerId) -Quiet
    ) -join [Environment]::NewLine
    if ([string]::IsNullOrWhiteSpace($inspectText)) {
        throw "Docker lieferte keine Inspect-Daten für Service '$Service'."
    }

    try {
        $inspect = @($inspectText | ConvertFrom-Json -ErrorAction Stop)
    }
    catch {
        throw "Die Docker-Inspect-Daten für Service '$Service' konnten nicht ausgewertet werden."
    }
    if ($inspect.Count -ne 1) {
        throw "Docker lieferte keine eindeutigen Inspect-Daten für Service '$Service'."
    }

    $bindings = @($inspect[0].NetworkSettings.Ports.'1433/tcp')
    if ($bindings.Count -ne 1 -or $null -eq $bindings[0]) {
        throw "Service '$Service' besitzt keine eindeutige veröffentlichte Host-Portbindung für TCP 1433."
    }

    $hostIp = [string] $bindings[0].HostIp
    $hostPort = [string] $bindings[0].HostPort
    if ([string]::IsNullOrWhiteSpace($hostIp) -or [string]::IsNullOrWhiteSpace($hostPort)) {
        throw "Service '$Service' besitzt eine unvollständige Host-Portbindung für TCP 1433."
    }
    return "$hostIp`:$hostPort"
}

function Assert-ServicePublishedPort {
    param(
        [Parameter(Mandatory)][hashtable] $Env,
        [Parameter(Mandatory)][string] $Service,
        [Parameter(Mandatory)][ValidateRange(1024, 65535)][int] $ExpectedPort
    )

    $expectedEndpoint = "$([string] $Env.BIND_ADDRESS):$ExpectedPort"
    $actualEndpoint = Get-PublishedSqlEndpoint -Env $Env -Service $Service
    if ($actualEndpoint -ne $expectedEndpoint) {
        throw "Service '$Service' veröffentlicht TCP 1433 unter '$actualEndpoint' statt unter '$expectedEndpoint'."
    }
}

function Start-ServiceWithPublishedPort {
    param(
        [Parameter(Mandatory)][hashtable] $Env,
        [Parameter(Mandatory)][string] $Service,
        [Parameter(Mandatory)][ValidateRange(1024, 65535)][int] $ExpectedPort
    )

    Invoke-Compose -Env $Env -Arguments @('up', '-d', '--no-deps', $Service) | Out-Null
    try {
        Assert-ServicePublishedPort -Env $Env -Service $Service -ExpectedPort $ExpectedPort
    }
    catch {
        Write-Warning "Die erwartete Host-Portbindung für '$Service' fehlt. Der Container wird mit der aktuellen Compose-Konfiguration neu erstellt."
        Invoke-Compose -Env $Env -Arguments @('up', '-d', '--no-deps', '--force-recreate', $Service) | Out-Null
        Assert-ServicePublishedPort -Env $Env -Service $Service -ExpectedPort $ExpectedPort
    }
}

function Assert-TcpEndpointReachable {
    param(
        [Parameter(Mandatory)][string] $Address,
        [Parameter(Mandatory)][ValidateRange(1024, 65535)][int] $Port,
        [ValidateRange(1, 30)][int] $TimeoutSeconds = 5
    )

    $client = [Net.Sockets.TcpClient]::new()
    try {
        $connectTask = $client.ConnectAsync($Address, $Port)
        if (-not $connectTask.Wait([TimeSpan]::FromSeconds($TimeoutSeconds)) -or -not $client.Connected) {
            throw "TCP-Endpunkt '$Address`:$Port' ist vom Host nicht erreichbar."
        }
    }
    finally {
        $client.Dispose()
    }
}

function Wait-ServiceHealthy {
    param(
        [Parameter(Mandatory)][hashtable] $Env,
        [Parameter(Mandatory)][string] $Service,
        [ValidateRange(30, 1200)][int] $TimeoutSeconds = 600
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        $containerIdLine = Invoke-Compose -Env $Env -Arguments @('ps', '-q', $Service) -Quiet | Select-Object -First 1
        $containerId = if ($null -eq $containerIdLine) { '' } else { ([string] $containerIdLine).Trim() }
        if (-not [string]::IsNullOrWhiteSpace($containerId)) {
            $statusLine = Invoke-ExternalCommand -FilePath 'docker' -Arguments @('inspect', '--format', '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}', $containerId) -Quiet | Select-Object -First 1
            $status = if ($null -eq $statusLine) { '' } else { ([string] $statusLine).Trim() }
            if ($status -eq 'healthy') {
                return
            }
            if ($status -in @('exited', 'dead')) {
                Invoke-Compose -Env $Env -Arguments @('logs', '--no-color', '--tail', '100', $Service) | Out-Null
                throw "Service '$Service' wurde mit Status '$status' beendet."
            }
        }
        Start-Sleep -Seconds 5
    }
    Invoke-Compose -Env $Env -Arguments @('logs', '--no-color', '--tail', '100', $Service) | Out-Null
    throw "Service '$Service' wurde innerhalb von $TimeoutSeconds Sekunden nicht healthy."
}

function New-FrameworkInstaller {
    param([Parameter(Mandatory)][hashtable] $Env)

    $installerRoot = Get-CanonicalPath -Path ([string] $Env.INSTALLER_ROOT)
    [IO.Directory]::CreateDirectory($installerRoot) | Out-Null
    $outputPath = Join-Path $installerRoot 'Install_All.generated.sql'
    $builderPath = Join-Path $script:RepositoryRoot 'Code/Install/Build-StandaloneInstaller.ps1'
    if (-not (Test-Path -LiteralPath $builderPath -PathType Leaf)) {
        throw 'Der kanonische Standalone-Installer-Builder wurde nicht gefunden.'
    }

    & $builderPath -RepositoryRoot $script:RepositoryRoot -OutputPath $outputPath
    if (-not (Test-Path -LiteralPath $outputPath -PathType Leaf)) {
        throw 'Der Frameworkinstaller wurde nicht erzeugt.'
    }

    $content = [IO.File]::ReadAllText($outputPath, [Text.Encoding]::UTF8)
    $content = $content.Replace('[DeineDatenbank]', '[LabAnalyze]')
    [IO.File]::WriteAllText($outputPath, $content, [Text.UTF8Encoding]::new($false))

    $prepareSql = @'
SET NOCOUNT ON;
IF DB_ID(N'LabAnalyze') IS NULL
BEGIN
    CREATE DATABASE [LabAnalyze]
    COLLATE SQL_Latin1_General_CP1_CS_AS;
END;
'@
    [IO.File]::WriteAllText((Join-Path $installerRoot 'Prepare_Framework_Database.sql'), $prepareSql, [Text.UTF8Encoding]::new($false))

    $verifySql = @'
SET NOCOUNT ON;
IF DB_ID(N'LabAnalyze') IS NULL
    THROW 51000, 'Framework database is missing.', 1;
IF NOT EXISTS
(
    SELECT 1
    FROM [LabAnalyze].[sys].[schemas] AS s
    WHERE s.[name] = N'monitor'
)
    THROW 51000, 'Framework schema is missing.', 1;
SELECT N'FRAMEWORK_READY';
'@
    [IO.File]::WriteAllText((Join-Path $installerRoot 'Verify_Framework.sql'), $verifySql, [Text.UTF8Encoding]::new($false))
}

function Invoke-ContainerSqlFile {
    param(
        [Parameter(Mandatory)][hashtable] $Env,
        [Parameter(Mandatory)][string] $Service,
        [Parameter(Mandatory)][ValidatePattern('^/quickstart/installer/[A-Za-z0-9_.-]+\.sql$')][string] $ContainerPath
    )

    $shell = @'
sqlcmd_path="$(command -v sqlcmd 2>/dev/null || true)"; if [ -z "$sqlcmd_path" ]; then for candidate in /opt/mssql-tools18/bin/sqlcmd /opt/mssql-tools/bin/sqlcmd; do if [ -x "$candidate" ]; then sqlcmd_path="$candidate"; break; fi; done; fi; if [ -z "$sqlcmd_path" ]; then exit 127; fi; export SQLCMDPASSWORD="$MSSQL_SA_PASSWORD"; exec "$sqlcmd_path" "$@"
'@
    return Invoke-Compose -Env $Env -Arguments @(
        'exec', '-T', $Service,
        '/bin/bash', '-c', $shell,
        'quickstart-sqlcmd',
        '-C', '-b', '-S', 'localhost', '-U', 'sa', '-h', '-1', '-W', '-t', '300', '-i', $ContainerPath
    ) -Quiet
}

function Install-Framework {
    param(
        [Parameter(Mandatory)][hashtable] $Env,
        [Parameter(Mandatory)][string[]] $Versions
    )

    New-FrameworkInstaller -Env $Env
    foreach ($version in $Versions) {
        $service = "sql$version"
        Write-Host "Installiere bzw. aktualisiere SQL_Server_Analyze auf SQL Server $version ..."
        Invoke-ContainerSqlFile -Env $Env -Service $service -ContainerPath '/quickstart/installer/Prepare_Framework_Database.sql' | Out-Null
        Invoke-ContainerSqlFile -Env $Env -Service $service -ContainerPath '/quickstart/installer/Install_All.generated.sql' | Out-Null
        $verification = Invoke-ContainerSqlFile -Env $Env -Service $service -ContainerPath '/quickstart/installer/Verify_Framework.sql'
        if ('FRAMEWORK_READY' -notin @($verification | ForEach-Object { ([string] $_).Trim() })) {
            throw "Framework-Verifikation für SQL Server $version fehlgeschlagen."
        }
        Write-Host "SQL Server ${version}: FRAMEWORK_READY"
    }
}

function Start-Environment {
    Assert-DockerReady
    $envValues = Read-EnvFile
    Assert-ManagedRoots -Env $envValues
    Assert-DockerResourceOwnership -Env $envValues
    Invoke-Compose -Env $envValues -Arguments @('config', '--quiet') -Quiet | Out-Null

    $versions = @([string] $envValues.SQL_VERSIONS -split ',' | Where-Object { $_ -in @('2019', '2022', '2025') })
    if ($versions.Count -eq 0) {
        throw 'Die .env-Datei enthält keine unterstützte SQL-Version.'
    }

    if ($envValues.QUICKSTART_RUNTIME_MODE -eq 'DOCKER_DESKTOP_WINDOWS') {
        Write-Warning 'Docker Desktop startet die lokalen SQL-Testcontainer als root innerhalb des Containers. Die Container bleiben unprivilegiert, binden SQL ausschließlich an die lokale Loopback-Schnittstelle und speichern aktive SQL-Dateien in projektgebundenen Docker-Volumes.'
    }

    foreach ($version in $versions) {
        $service = "sql$version"
        $publishedPort = [int] $envValues["SQL${version}_PORT"]
        Write-Section -Text "SQL Server $version"
        Invoke-Compose -Env $envValues -Arguments @('pull', $service) | Out-Null
        Start-ServiceWithPublishedPort -Env $envValues -Service $service -ExpectedPort $publishedPort
        Wait-ServiceHealthy -Env $envValues -Service $service
        Assert-TcpEndpointReachable -Address ([string] $envValues.BIND_ADDRESS) -Port $publishedPort
        Write-Host "SQL Server $version ist healthy und unter $($envValues.BIND_ADDRESS):$publishedPort vom Host erreichbar."
    }

    if ($envValues.INSTALL_FRAMEWORK -eq 'true') {
        Write-Section -Text 'Frameworkinstallation'
        Install-Framework -Env $envValues -Versions $versions
    }

    Write-Section -Text 'Bereit'
    foreach ($version in $versions) {
        Write-Host ("SQL Server {0} für SSMS: {1},{2}" -f $version, $envValues.BIND_ADDRESS, $envValues["SQL${version}_PORT"])
    }
    Write-Host 'Frameworkdatenbank: LabAnalyze'
}

function Show-Status {
    Assert-DockerReady
    $envValues = Read-EnvFile
    Assert-ManagedRoots -Env $envValues
    Assert-DockerResourceOwnership -Env $envValues
    Invoke-Compose -Env $envValues -Arguments @('ps', '-a') | Out-Null
}

function Stop-Environment {
    Assert-DockerReady
    $envValues = Read-EnvFile
    Assert-ManagedRoots -Env $envValues
    Assert-DockerResourceOwnership -Env $envValues
    $versions = @([string] $envValues.SQL_VERSIONS -split ',' | Where-Object { $_ -in @('2019', '2022', '2025') })
    $services = @($versions | ForEach-Object { "sql$_" })
    Invoke-Compose -Env $envValues -Arguments (@('stop', '--timeout', '60') + $services) | Out-Null
    Write-Host 'Die QuickStart-Container wurden gestoppt; Daten und Konfiguration bleiben erhalten.'
}
