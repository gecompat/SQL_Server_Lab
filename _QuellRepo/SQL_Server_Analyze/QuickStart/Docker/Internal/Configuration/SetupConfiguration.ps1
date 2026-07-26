function Test-LinuxSlowIoConfiguration {
    param(
        [Parameter(Mandatory)][string] $LabRoot,
        [Parameter(Mandatory)][string] $Device
    )

    if ($script:IsWindowsHost) {
        throw 'Deterministische Block-I/O-Drosselung wird unter Docker Desktop auf Windows nicht angeboten. Verwenden Sie eine Linux-Docker-Engine, beispielsweise in einer Hyper-V-VM.'
    }
    foreach ($command in @('findmnt', 'lsblk', 'readlink')) {
        if (-not (Get-Command -Name $command -ErrorAction SilentlyContinue)) {
            throw "Für Slow-I/O fehlt das Linux-Werkzeug '$command'."
        }
    }
    if (-not (Test-Path -LiteralPath $LabRoot -PathType Container)) {
        throw 'Für Slow-I/O muss die leere Lab-Wurzel bereits als dedizierter Mountpoint existieren.'
    }
    if ($Device -notmatch '^/dev/[A-Za-z0-9_./-]+$' -or -not (Test-Path -LiteralPath $Device)) {
        throw "Das Blockgerät '$Device' ist ungültig."
    }

    $deviceType = Get-FirstOutputLine -InputObject @(
        Invoke-ExternalCommand -FilePath 'lsblk' -Arguments @('-ndo', 'TYPE', $Device) -Quiet
    )
    if ($deviceType -notin @('disk', 'part', 'lvm')) {
        throw "Das Slow-I/O-Ziel '$Device' hat den nicht unterstützten Typ '$deviceType'."
    }

    $mountSource = Get-FirstOutputLine -InputObject @(
        Invoke-ExternalCommand -FilePath 'findmnt' -Arguments @('-n', '-o', 'SOURCE', '-T', $LabRoot) -Quiet
    )
    $mountTarget = Get-FirstOutputLine -InputObject @(
        Invoke-ExternalCommand -FilePath 'findmnt' -Arguments @('-n', '-o', 'TARGET', '-T', $LabRoot) -Quiet
    )
    $resolvedMountTarget = Get-CanonicalPath -Path $mountTarget
    $resolvedLabRoot = Get-CanonicalPath -Path $LabRoot
    if (-not $resolvedMountTarget.Equals($resolvedLabRoot, $script:PathComparison)) {
        throw "Die Lab-Wurzel '$resolvedLabRoot' ist kein eigener Mountpoint. Slow-I/O verlangt eine ausschließlich diesem Lab zugeordnete virtuelle Disk bzw. Partition."
    }
    $resolvedDevice = Get-FirstOutputLine -InputObject @(
        Invoke-ExternalCommand -FilePath 'readlink' -Arguments @('-f', $Device) -Quiet
    )
    $resolvedSource = Get-FirstOutputLine -InputObject @(
        Invoke-ExternalCommand -FilePath 'readlink' -Arguments @('-f', $mountSource) -Quiet
    )
    if ($resolvedDevice -ne $resolvedSource) {
        throw "Die Lab-Wurzel liegt auf '$mountSource', nicht auf dem angegebenen Gerät '$Device'."
    }

    Write-Warning 'Slow-I/O wirkt auf das angegebene Blockgerät. Es darf ausschließlich für dieses Lab verwendet werden.'
    $confirmation = (Read-Host "Zum Bestätigen exakt 'SLOWIO' eingeben").Trim()
    if ($confirmation -ne 'SLOWIO') {
        throw 'Slow-I/O wurde nicht bestätigt.'
    }
}

function Get-SetupConfiguration {
    Assert-DockerReady

    if (Test-Path -LiteralPath $script:EnvPath -PathType Leaf) {
        try {
            $existing = Read-EnvFile
            Assert-ManagedRoots -Env $existing
            throw 'Eine bestehende verwaltete QuickStart-Umgebung wurde erkannt. Bitte zuerst über Setup.ps1 die Aktion Remove ausführen.'
        }
        catch {
            if ($_.Exception.Message -like 'Eine bestehende verwaltete*') {
                throw
            }
            Write-Warning 'Eine vorhandene .env-Datei verweist nicht auf eine gültige verwaltete Umgebung.'
            if (-not (Read-YesNo -Prompt 'Nur diese .env-Datei überschreiben?' -Default $false)) {
                throw 'Setup wurde abgebrochen.'
            }
        }
    }

    Write-Section -Text 'SQL-Versionen und Ressourcen'
    $versions = @(Get-SelectedVersions)
    $resource = Get-ResourceSettings -VersionCount $versions.Count

    Write-Section -Text 'Speicherlayout'
    $layoutChoice = Read-MenuChoice -Prompt 'Speicherlayout' -Choices @{
        '1' = 'Single Root: Daten, Logs und Backups unter einer leeren Lab-Wurzel; geeignet für Systeme mit nur einem Laufwerk'
        '2' = 'Separate Data/Log Roots: drei getrennte, leere Wurzelpfade'
    } -DefaultKey '1'
    $storageLayout = if ($layoutChoice -eq '1') { 'SINGLE_ROOT' } else { 'SPLIT_DATA_LOG' }

    $defaultRoot = Get-DefaultLabRoot
    $labRoot = Assert-SafeEmptyRoot -Path (Read-PathWithDefault -Prompt 'Leere Lab-Wurzel' -Default $defaultRoot) -Purpose 'Lab'
    if ($storageLayout -eq 'SINGLE_ROOT') {
        $dataRoot = Join-Path $labRoot 'data'
        $logRoot = Join-Path $labRoot 'log'
    }
    else {
        $dataRoot = Assert-SafeEmptyRoot -Path (Read-PathWithDefault -Prompt 'Leere Daten-Wurzel' -Default "${labRoot}_Data") -Purpose 'Daten'
        $logRoot = Assert-SafeEmptyRoot -Path (Read-PathWithDefault -Prompt 'Leere Log-Wurzel' -Default "${labRoot}_Log") -Purpose 'Log'
        Assert-RootsDoNotOverlap -Paths @($labRoot, $dataRoot, $logRoot)
    }

    Write-Section -Text 'I/O-Profil'
    while ($true) {
        $ioChoice = Read-MenuChoice -Prompt 'I/O-Profil' -Choices @{
            '1' = 'Normal: keine künstliche Block-I/O-Drosselung'
            '2' = 'Slow-I/O: nur Linux Docker Engine / Docker in Hyper-V-VM mit dediziertem Blockgerät'
        } -DefaultKey '1'
        if ($ioChoice -eq '1') {
            $ioProfile = 'NORMAL'
            $slowIoDevice = ''
            $slowIoRead = '20mb'
            $slowIoWrite = '10mb'
            break
        }
        if ($script:IsWindowsHost) {
            Write-Warning 'Docker Desktop auf Windows bietet für Bind-Mounts keine portable, belastbare Block-I/O-Drosselung. Führen Sie diesen QuickStart für Slow-I/O innerhalb einer Linux-Hyper-V-VM mit dediziertem Datenträger aus.'
            continue
        }
        if ($storageLayout -ne 'SINGLE_ROOT') {
            Write-Warning 'Slow-I/O unterstützt im sicheren QuickStart nur SINGLE_ROOT auf einem dedizierten Blockgerät.'
            continue
        }
        $slowIoDevice = (Read-Host 'Dediziertes Blockgerät, z. B. /dev/sdb1').Trim()
        $slowIoRead = (Read-Host 'Maximale Leserate [Standard: 20mb]').Trim()
        if ([string]::IsNullOrWhiteSpace($slowIoRead)) { $slowIoRead = '20mb' }
        $slowIoWrite = (Read-Host 'Maximale Schreibrate [Standard: 10mb]').Trim()
        if ([string]::IsNullOrWhiteSpace($slowIoWrite)) { $slowIoWrite = '10mb' }
        if ($slowIoRead -notmatch '^\d+(kb|mb|gb)$' -or $slowIoWrite -notmatch '^\d+(kb|mb|gb)$') {
            Write-Warning 'Raten müssen beispielsweise als 20mb oder 1gb angegeben werden.'
            continue
        }
        Test-LinuxSlowIoConfiguration -LabRoot $labRoot -Device $slowIoDevice
        $ioProfile = 'SLOW_IO'
        break
    }

    Write-Section -Text 'Ports'
    $ports = @{}
    $selectedPorts = [Collections.Generic.List[int]]::new()
    foreach ($version in $versions) {
        $defaultPort = switch ($version) { '2019' { 14331 } '2022' { 14332 } '2025' { 14335 } }
        $port = Read-AvailablePort -Version $version -DefaultPort $defaultPort -AlreadySelected $selectedPorts.ToArray()
        $ports[$version] = $port
        $selectedPorts.Add($port)
    }
    foreach ($version in @('2019', '2022', '2025')) {
        if (-not $ports.ContainsKey($version)) {
            $ports[$version] = switch ($version) { '2019' { 14331 } '2022' { 14332 } '2025' { 14335 } }
        }
    }

    Write-Section -Text 'Secret und Framework'
    $password = Read-SaPassword
    $agentEnabled = Read-YesNo -Prompt 'SQL Server Agent für Infrastrukturtests aktivieren?' -Default $true
    $installFramework = Read-YesNo -Prompt 'SQL_Server_Analyze nach dem Containerstart automatisch in LabAnalyze installieren?' -Default $true

    $runtimeMode = if ($script:IsWindowsHost) {
        'DOCKER_DESKTOP_WINDOWS'
    }
    elseif (Read-YesNo -Prompt 'Läuft diese Linux Docker Engine innerhalb einer Hyper-V-VM?' -Default $false) {
        'HYPERV_LINUX_DOCKER'
    }
    else {
        'DOCKER_ENGINE_LINUX'
    }

    $scopeId = ([guid]::NewGuid().ToString('N')).Substring(0, 12)
    $projectName = "ssa-quickstart-$scopeId"
    $backupRoot = Join-Path $labRoot 'backup'
    $installerRoot = Join-Path $labRoot 'control/installer'

    $values = @{
        QUICKSTART_SCHEMA_VERSION = '1'
        QUICKSTART_SCOPE_ID = $scopeId
        QUICKSTART_RUNTIME_MODE = $runtimeMode
        COMPOSE_PROJECT_NAME = $projectName
        COMPOSE_PROFILES = (@($versions | ForEach-Object { "sql$_" }) -join ',')
        SQL_VERSIONS = ($versions -join ',')
        BIND_ADDRESS = '127.0.0.1'
        MSSQL_SA_PASSWORD = $password
        MSSQL_COLLATION = 'SQL_Latin1_General_CP1_CS_AS'
        MSSQL_AGENT_ENABLED = if ($agentEnabled) { 'true' } else { 'false' }
        FRAMEWORK_DATABASE = 'LabAnalyze'
        INSTALL_FRAMEWORK = if ($installFramework) { 'true' } else { 'false' }
        RESOURCE_PROFILE = $resource.Name
        CONTAINER_CPUS = $resource.Cpus
        CONTAINER_MEMORY = $resource.ContainerMemory
        SQL_MEMORY_LIMIT_MB = [string] $resource.SqlMemoryMb
        STORAGE_LAYOUT = $storageLayout
        LAB_ROOT = ConvertTo-EnvPath -Path $labRoot
        DATA_ROOT = ConvertTo-EnvPath -Path $dataRoot
        LOG_ROOT = ConvertTo-EnvPath -Path $logRoot
        BACKUP_ROOT = ConvertTo-EnvPath -Path $backupRoot
        INSTALLER_ROOT = ConvertTo-EnvPath -Path $installerRoot
        SQL2019_PORT = [string] $ports['2019']
        SQL2022_PORT = [string] $ports['2022']
        SQL2025_PORT = [string] $ports['2025']
        SQL2019_DATA_DIR = ConvertTo-EnvPath -Path (Join-Path $dataRoot '2019')
        SQL2019_LOG_DIR = ConvertTo-EnvPath -Path (Join-Path $logRoot '2019')
        SQL2019_BACKUP_DIR = ConvertTo-EnvPath -Path (Join-Path $backupRoot '2019')
        SQL2022_DATA_DIR = ConvertTo-EnvPath -Path (Join-Path $dataRoot '2022')
        SQL2022_LOG_DIR = ConvertTo-EnvPath -Path (Join-Path $logRoot '2022')
        SQL2022_BACKUP_DIR = ConvertTo-EnvPath -Path (Join-Path $backupRoot '2022')
        SQL2025_DATA_DIR = ConvertTo-EnvPath -Path (Join-Path $dataRoot '2025')
        SQL2025_LOG_DIR = ConvertTo-EnvPath -Path (Join-Path $logRoot '2025')
        SQL2025_BACKUP_DIR = ConvertTo-EnvPath -Path (Join-Path $backupRoot '2025')
        SQL2019_IMAGE = 'mcr.microsoft.com/mssql/server:2019-latest'
        SQL2022_IMAGE = 'mcr.microsoft.com/mssql/server:2022-latest'
        SQL2025_IMAGE = 'mcr.microsoft.com/mssql/server:2025-latest'
        IO_PROFILE = $ioProfile
        SLOW_IO_DEVICE = $slowIoDevice
        SLOW_IO_READ_BPS = $slowIoRead
        SLOW_IO_WRITE_BPS = $slowIoWrite
    }

    $setupRoots = if ($storageLayout -eq 'SINGLE_ROOT') {
        @($labRoot)
    }
    else {
        @($labRoot, $dataRoot, $logRoot) | Select-Object -Unique
    }
    $preExistingRoots = @{}
    foreach ($root in $setupRoots) {
        $preExistingRoots[$root] = Test-Path -LiteralPath $root -PathType Container
    }

    return [pscustomobject]@{
        Values = $values
        LabRoot = $labRoot
        DataRoot = $dataRoot
        LogRoot = $logRoot
        StorageLayout = $storageLayout
        ScopeId = $scopeId
        PreExistingRoots = $preExistingRoots
    }
}
