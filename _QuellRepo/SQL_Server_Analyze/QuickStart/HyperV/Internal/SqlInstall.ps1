function Get-SqlConfigurationFile {
    param(
        [Parameter(Mandatory)][string] $Version,
        [Parameter(Mandatory)][string] $SaPassword
    )

    $instanceDir = 'C:\Program Files\Microsoft SQL Server'
    $content = @"
[OPTIONS]
ACTION="Install"
FEATURES=SQLENGINE,FULLTEXT,CONN
INSTANCENAME="MSSQLSERVER"
INSTANCEDIR="$instanceDir"
SQLSYSADMINACCOUNTS="BUILTIN\Administrators"
SECURITYMODE="SQL"
SAPWD="$SaPassword"
SQLCOLLATION="SQL_Latin1_General_CP1_CS_AS"
SQLSVCSTARTUPTYPE="Automatic"
AGTSVCSTARTUPTYPE="Automatic"
BROWSERSVCSTARTUPTYPE="Disabled"
TCPENABLED=1
NPENABLED=0
IACCEPTSQLSERVERLICENSETERMS=1
SQLSVCINSTANTFILEINIT="True"
SQUPDATESOURCE="MU"
UPDATEENABLED="False"
QUIET="True"
QS="True"
"@
    return $content
}

function Install-SqlServerInVm {
    param(
        [Parameter(Mandatory)][string] $VmName,
        [Parameter(Mandatory)][string] $Version,
        [Parameter(Mandatory)][string] $MediaPath,
        [Parameter(Mandatory)][string] $SaPassword,
        [Parameter(Mandatory)][pscredential] $Credential
    )

    Write-Section "SQL Server $Version Installation in '$VmName'"

    # ConfigurationFile erzeugen und in VM kopieren
    $configContent = Get-SqlConfigurationFile -Version $Version -SaPassword $SaPassword
    $tempConfig = Join-Path $env:TEMP "sql_config_$Version.ini"
    [IO.File]::WriteAllText($tempConfig, $configContent, [Text.Encoding]::UTF8)

    try {
        # Datei in VM kopieren via Guest Services
        $vmConfigPath = 'C:\Temp\sql_config.ini'
        Invoke-VmPowerShell -VmName $VmName -Credential $Credential -ScriptBlock {
            if (-not (Test-Path 'C:\Temp')) { New-Item -Path 'C:\Temp' -ItemType Directory -Force | Out-Null }
        }
        Copy-VMFile -Name $VmName -SourcePath $tempConfig -DestinationPath $vmConfigPath `
            -FileSource Host -CreateFullPath -Force

        # ISO in VM mounten und Setup starten
        Invoke-VmPowerShell -VmName $VmName -Credential $Credential -ScriptBlock {
            param($IsoPath, $ConfigPath)

            # ISO mounten
            $mountResult = Mount-DiskImage -ImagePath $IsoPath -PassThru
            $driveLetter = ($mountResult | Get-Volume).DriveLetter
            $setupPath = "${driveLetter}:\setup.exe"

            if (-not (Test-Path $setupPath)) {
                Dismount-DiskImage -ImagePath $IsoPath
                throw "setup.exe nicht gefunden auf $setupPath"
            }

            Write-Host "Starte SQL Server Setup von ${driveLetter}:\..."
            $process = Start-Process -FilePath $setupPath `
                -ArgumentList "/ConfigurationFile=`"$ConfigPath`"" `
                -Wait -PassThru -NoNewWindow

            Dismount-DiskImage -ImagePath $IsoPath

            if ($process.ExitCode -ne 0) {
                $summaryLog = Get-ChildItem -Path 'C:\Program Files\Microsoft SQL Server\*\Setup Bootstrap\Log' `
                    -Filter 'Summary.txt' -Recurse -ErrorAction SilentlyContinue | Select-Object -Last 1
                if ($summaryLog) {
                    $lastLines = Get-Content $summaryLog.FullName -Tail 30
                    Write-Host ($lastLines -join "`n")
                }
                throw "SQL Server Setup fehlgeschlagen (Exit Code: $($process.ExitCode))."
            }
            Write-Host 'SQL Server Setup erfolgreich.'
        } -ArgumentList @($MediaPath, $vmConfigPath)

        # Query Store aktivieren
        Write-Host 'Aktiviere Query Store auf master...'
        Invoke-VmPowerShell -VmName $VmName -Credential $Credential -ScriptBlock {
            param($Password)
            $query = "ALTER DATABASE [master] SET QUERY_STORE = ON;"
            Invoke-Sqlcmd -ServerInstance 'localhost' -Username 'sa' -Password $Password `
                -Query $query -TrustServerCertificate -ErrorAction SilentlyContinue
        } -ArgumentList @($SaPassword)
    }
    finally {
        if (Test-Path -LiteralPath $tempConfig) {
            Remove-Item -LiteralPath $tempConfig -Force
        }
    }
}

function Install-FrameworkInVm {
    param(
        [Parameter(Mandatory)][string] $VmName,
        [Parameter(Mandatory)][string] $SaPassword,
        [Parameter(Mandatory)][pscredential] $Credential
    )

    Write-Section "Framework-Installation in '$VmName'"

    # Standalone-Installer erzeugen
    $buildScript = Join-Path $script:RepositoryRoot 'Code/Install/Build-StandaloneInstaller.ps1'
    $generatedInstaller = Join-Path $env:TEMP 'Install_All.generated.sql'
    & pwsh -NoLogo -NoProfile -File $buildScript -OutputPath $generatedInstaller
    if ($LASTEXITCODE -ne 0) {
        throw 'Standalone-Installer-Erzeugung fehlgeschlagen.'
    }

    # Datenbanknamen ersetzen
    $content = [IO.File]::ReadAllText($generatedInstaller, [Text.Encoding]::UTF8)
    $content = $content.Replace('[DeineDatenbank]', '[LabAnalyze]')
    [IO.File]::WriteAllText($generatedInstaller, $content, [Text.Encoding]::UTF8)

    # In VM kopieren
    $vmInstallerPath = 'C:\Temp\Install_All.sql'
    Copy-VMFile -Name $VmName -SourcePath $generatedInstaller -DestinationPath $vmInstallerPath `
        -FileSource Host -CreateFullPath -Force

    # Datenbank erstellen und Installer ausführen
    Invoke-VmPowerShell -VmName $VmName -Credential $Credential -ScriptBlock {
        param($Password, $InstallerPath)

        # LabAnalyze erstellen
        $createDb = @"
IF DB_ID(N'LabAnalyze') IS NULL
BEGIN
    CREATE DATABASE [LabAnalyze] COLLATE SQL_Latin1_General_CP1_CS_AS;
    ALTER DATABASE [LabAnalyze] SET QUERY_STORE = ON;
END
"@
        Invoke-Sqlcmd -ServerInstance 'localhost' -Username 'sa' -Password $Password `
            -Query $createDb -TrustServerCertificate

        # Framework installieren
        Write-Host 'Installiere Framework in LabAnalyze...'
        Invoke-Sqlcmd -ServerInstance 'localhost' -Username 'sa' -Password $Password `
            -InputFile $InstallerPath -TrustServerCertificate -ErrorAction Stop

        # Verifizierung
        $verify = Invoke-Sqlcmd -ServerInstance 'localhost' -Username 'sa' -Password $Password `
            -Database 'LabAnalyze' -TrustServerCertificate `
            -Query "SELECT COUNT(*) AS ObjCount FROM sys.objects WHERE schema_id = SCHEMA_ID(N'monitor');"
        if ($verify.ObjCount -lt 100) {
            throw "Framework-Verifizierung fehlgeschlagen: Nur $($verify.ObjCount) Objekte im Schema monitor."
        }
        Write-Host "Framework installiert: $($verify.ObjCount) Objekte in [monitor]."
    } -ArgumentList @($SaPassword, $vmInstallerPath)

    # Aufräumen
    Remove-Item -LiteralPath $generatedInstaller -Force -ErrorAction SilentlyContinue
    Write-Host 'FRAMEWORK_READY.'
}


# ============================================================
# Linux SQL Server Installation (APT-basiert)
# ============================================================

function Get-MssqlRepoUrl {
    param([Parameter(Mandatory)][string] $Version)

    switch ($Version) {
        '2019' { return 'https://packages.microsoft.com/config/ubuntu/22.04/mssql-server-2019.list' }
        '2022' { return 'https://packages.microsoft.com/config/ubuntu/22.04/mssql-server-2022.list' }
        '2025' { return 'https://packages.microsoft.com/config/ubuntu/24.04/mssql-server-2025.list' }
        default { throw "Unbekannte SQL Server Version: $Version" }
    }
}

function Install-SqlServerOnLinux {
    param(
        [Parameter(Mandatory)][string] $VmName,
        [Parameter(Mandatory)][string] $IpAddress,
        [Parameter(Mandatory)][string] $Version,
        [Parameter(Mandatory)][string] $SaPassword,
        [Parameter(Mandatory)][string] $SshKeyPath
    )

    Write-Section "SQL Server $Version auf Linux-VM '$VmName' installieren"

    $sshOpts = "-i $SshKeyPath -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
    $user = 'labadmin'
    $repoUrl = Get-MssqlRepoUrl -Version $Version

    # Single-quoted here-string: PowerShell interpoliert NICHTS.
    # Platzhalter werden danach per .Replace() ersetzt.
    $setupCmd = @'
set -e
echo '--- Microsoft GPG-Key importieren ---'
curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | sudo gpg --dearmor -o /usr/share/keyrings/microsoft-prod.gpg 2>/dev/null || true

echo '--- SQL Server Repository hinzufuegen ---'
curl -fsSL __REPO_URL__ | sudo tee /etc/apt/sources.list.d/mssql-server.list > /dev/null

echo '--- APT aktualisieren ---'
sudo apt-get update -qq

echo '--- SQL Server installieren ---'
sudo ACCEPT_EULA=Y DEBIAN_FRONTEND=noninteractive apt-get install -y -qq mssql-server

echo '--- SQL Server konfigurieren ---'
sudo MSSQL_SA_PASSWORD='__SA_PASSWORD__' \
     MSSQL_PID='Developer' \
     MSSQL_COLLATION='SQL_Latin1_General_CP1_CS_AS' \
     MSSQL_TCP_PORT=1433 \
     /opt/mssql/bin/mssql-conf setup accept-eula

echo '--- SQL Server Tools installieren ---'
curl -fsSL https://packages.microsoft.com/config/ubuntu/22.04/prod.list | sudo tee /etc/apt/sources.list.d/mssql-release.list > /dev/null
sudo apt-get update -qq
sudo ACCEPT_EULA=Y DEBIAN_FRONTEND=noninteractive apt-get install -y -qq mssql-tools18 unixodbc-dev

echo '--- PATH ergaenzen ---'
echo 'export PATH="$PATH:/opt/mssql-tools18/bin"' | sudo tee /etc/profile.d/mssql-tools.sh > /dev/null

echo '--- Data/Log-Verzeichnisse auf dedizierte Disks ---'
sleep 2
DATA_DISK=$(lsblk -dno NAME,SIZE | grep -v '^sda' | sort -k2 -h | tail -2 | head -1 | awk '{print "/dev/" $1}')
LOG_DISK=$(lsblk -dno NAME,SIZE | grep -v '^sda' | sort -k2 -h | tail -1 | awk '{print "/dev/" $1}')

if [ -b "$DATA_DISK" ] && [ -b "$LOG_DISK" ]; then
    echo "  Data-Disk: $DATA_DISK"
    echo "  Log-Disk: $LOG_DISK"

    sudo mkfs.ext4 -q -F $DATA_DISK 2>/dev/null || true
    sudo mkfs.ext4 -q -F $LOG_DISK 2>/dev/null || true

    sudo mkdir -p /var/opt/mssql/data /var/opt/mssql/log
    sudo mount $DATA_DISK /var/opt/mssql/data
    sudo mount $LOG_DISK /var/opt/mssql/log

    echo "$DATA_DISK /var/opt/mssql/data ext4 defaults,nofail 0 2" | sudo tee -a /etc/fstab > /dev/null
    echo "$LOG_DISK /var/opt/mssql/log ext4 defaults,nofail 0 2" | sudo tee -a /etc/fstab > /dev/null

    sudo chown -R mssql:mssql /var/opt/mssql/data /var/opt/mssql/log
    sudo /opt/mssql/bin/mssql-conf set filelocation.defaultdatadir /var/opt/mssql/data
    sudo /opt/mssql/bin/mssql-conf set filelocation.defaultlogdir /var/opt/mssql/log
fi

echo '--- SQL Server neustarten ---'
sudo systemctl restart mssql-server
sleep 5

echo '--- Verbindungstest ---'
/opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P '__SA_PASSWORD__' -C -Q "SELECT @@VERSION;" -h -1 | head -1

echo '--- Query Store aktivieren ---'
/opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P '__SA_PASSWORD__' -C -Q "
IF DB_ID(N'LabAnalyze') IS NULL CREATE DATABASE [LabAnalyze] COLLATE SQL_Latin1_General_CP1_CS_AS;
ALTER DATABASE [LabAnalyze] SET QUERY_STORE = ON;
ALTER DATABASE [LabAnalyze] SET QUERY_STORE (OPERATION_MODE = READ_WRITE, MAX_STORAGE_SIZE_MB = 200);
"

echo '=== SQL Server Installation abgeschlossen ==='
'@.Replace('__SA_PASSWORD__', $SaPassword).Replace('__REPO_URL__', $repoUrl)

    # Kommando via SSH ausfuehren
    $result = & ssh $sshOpts.Split(' ') "$user@$IpAddress" $setupCmd 2>&1
    $result | ForEach-Object { Write-Host "  $_" }

    if ($LASTEXITCODE -ne 0) {
        throw "SQL Server Installation auf $VmName fehlgeschlagen."
    }
    Write-Host "SQL Server $Version auf $VmName bereit."
}

function Install-FrameworkOnLinux {
    param(
        [Parameter(Mandatory)][string] $VmName,
        [Parameter(Mandatory)][string] $IpAddress,
        [Parameter(Mandatory)][string] $SaPassword,
        [Parameter(Mandatory)][string] $SshKeyPath
    )

    Write-Section "Framework auf Linux-VM '$VmName' installieren"

    $installerSource = Join-Path $script:RepositoryRoot 'Code' 'Install' 'Install_All.sql'
    if (-not (Test-Path -LiteralPath $installerSource)) {
        throw "Installer nicht gefunden: $installerSource"
    }

    $sshOpts = "-i $SshKeyPath -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
    $user = 'labadmin'
    $remoteInstaller = '/tmp/Install_All.sql'

    & scp $sshOpts.Split(' ') $installerSource "${user}@${IpAddress}:${remoteInstaller}" 2>&1 | Out-Null

    $installCmd = @'
set -e
echo '--- Framework installieren ---'
/opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P '__SA_PASSWORD__' -C -d LabAnalyze -i /tmp/Install_All.sql

echo '--- Verifizierung ---'
OBJ_COUNT=$(/opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P '__SA_PASSWORD__' -C -d LabAnalyze -h -1 -Q "SELECT COUNT(*) FROM sys.objects WHERE schema_id = SCHEMA_ID(N'monitor');")
echo "Framework-Objekte: $OBJ_COUNT"

rm -f /tmp/Install_All.sql
echo '=== FRAMEWORK_READY ==='
'@.Replace('__SA_PASSWORD__', $SaPassword)

    $result = & ssh $sshOpts.Split(' ') "$user@$IpAddress" $installCmd 2>&1
    $result | ForEach-Object { Write-Host "  $_" }

    if ($LASTEXITCODE -ne 0) {
        throw "Framework-Installation auf $VmName fehlgeschlagen."
    }
    Write-Host "Framework auf $VmName installiert."
}
