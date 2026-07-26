function Invoke-Setup {
    Write-Section 'Hyper-V QuickStart Setup'

    if (Test-Path -LiteralPath $script:EnvPath) {
        $overwrite = Read-YesNo -Prompt 'Bestehende Konfiguration überschreiben?' -Default $false
        if (-not $overwrite) {
            Write-Host 'Setup abgebrochen.'
            return
        }
    }

    $config = @{}
    $config['SCOPE_ID'] = [guid]::NewGuid().ToString('N')

    # Betriebsmodus
    Write-Section 'Betriebsmodus'
    $osChoice = Read-MenuChoice -Prompt 'VM-Betriebssystem' `
        -Choices @{ '1' = 'Windows (native SQL Server)'; '2' = 'Linux (SQL on Linux + Simulation)'; '3' = 'Gemischt (beide)' } `
        -DefaultKey '1'
    $osMode = switch ($osChoice) { '1' { 'Windows' } '2' { 'Linux' } '3' { 'Mixed' } }
    $config['OS_MODE'] = $osMode

    # SQL-Server-Versionen
    Write-Section 'SQL-Server-Versionen'
    $versions = @()
    foreach ($v in @('2019', '2022', '2025')) {
        if (Read-YesNo -Prompt "SQL Server $v einrichten?" -Default ($v -eq '2022')) {
            $versions += $v
        }
    }
    if ($versions.Count -eq 0) {
        throw 'Mindestens eine SQL-Server-Version muss gewählt werden.'
    }
    $config['SQL_VERSIONS'] = $versions -join ','

    # Ressourcenprofil
    Write-Section 'Ressourcenprofil'
    $profileChoice = Read-MenuChoice -Prompt 'Profil wählen' `
        -Choices @{ '1' = 'Compact (4GB/2vCPU)'; '2' = 'Standard (8GB/4vCPU)'; '3' = 'Performance (16GB/8vCPU)' } `
        -DefaultKey '2'
    $profileName = switch ($profileChoice) { '1' { 'Compact' } '2' { 'Standard' } '3' { 'Performance' } }
    $config['RESOURCE_PROFILE'] = $profileName

    # Hostressourcen prüfen
    $hostMemoryGB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1)
    $profileDef = $script:ResourceProfiles[$profileName]
    $totalVmMemoryGB = [math]::Round(($profileDef.MaxMemory / 1GB) * $versions.Count, 1)
    if ($totalVmMemoryGB -gt ($hostMemoryGB * 0.7)) {
        Write-Warning "Gewähltes Profil benötigt bis zu ${totalVmMemoryGB}GB bei ${hostMemoryGB}GB Host-RAM."
        if (-not (Read-YesNo -Prompt 'Trotzdem fortfahren?')) {
            throw 'Setup abgebrochen wegen Ressourcenwarnung.'
        }
    }

    # Speicherpfad
    Write-Section 'Speicherpfad'
    $defaultDrive = Get-PSDrive -PSProvider FileSystem |
        Where-Object { $_.Used -gt 0 -and $_.Free -gt 40GB } |
        Sort-Object Free -Descending | Select-Object -First 1
    $defaultPath = if ($defaultDrive) { "$($defaultDrive.Root)Lab\HyperV" } else { 'C:\Lab\HyperV' }

    $labRoot = (Read-Host "Speicherpfad für VMs und VHDs [$defaultPath]").Trim()
    if ([string]::IsNullOrWhiteSpace($labRoot)) { $labRoot = $defaultPath }
    Assert-SafeTargetPath -Path $labRoot
    $config['LAB_ROOT'] = Get-CanonicalPath -Path $labRoot

    # Base-Image
    Write-Section 'Base-Image'
    $baseSource = Read-MenuChoice -Prompt 'Windows Server Base-Image' `
        -Choices @{ '1' = 'Lokales VHDX bereitstellen'; '2' = 'Evaluation herunterladen (5+ GB)' } `
        -DefaultKey '1'
    if ($baseSource -eq '1') {
        $vhdxPath = (Read-Host 'Pfad zum Base-VHDX (sysprep-generalisiert, Gen2)').Trim()
        if (-not (Test-Path -LiteralPath $vhdxPath)) {
            throw "Base-VHDX nicht gefunden: $vhdxPath"
        }
        $config['BASE_IMAGE_SOURCE'] = 'Local'
        $config['BASE_VHDX_PATH'] = $vhdxPath
    }
    else {
        $config['BASE_IMAGE_SOURCE'] = 'Download'
        $config['BASE_VHDX_PATH'] = ''
    }

    # SQL Server Medien
    Write-Section 'SQL Server Installationsmedien'
    foreach ($v in $versions) {
        $mediaChoice = Read-MenuChoice -Prompt "SQL Server $v Installationsmedium" `
            -Choices @{ '1' = 'Lokales ISO'; '2' = 'Download (Developer Edition)' } `
            -DefaultKey '2'
        if ($mediaChoice -eq '1') {
            $isoPath = (Read-Host "Pfad zur SQL Server $v ISO").Trim()
            if (-not (Test-Path -LiteralPath $isoPath)) {
                throw "ISO nicht gefunden: $isoPath"
            }
            $config["SQL_${v}_MEDIA"] = $isoPath
        }
        else {
            $config["SQL_${v}_MEDIA"] = 'Download'
        }
    }

    # SA-Passwort
    Write-Section 'SA-Passwort'
    $saPassword = Read-SecurePassword -Prompt 'SA-Passwort für die synthetischen Testinstanzen'
    $config['SA_PASSWORD'] = $saPassword

    # Optionen
    $config['SQL_AGENT_ENABLED'] = 'true'
    $config['INSTALL_FRAMEWORK'] = if (Read-YesNo -Prompt 'Framework automatisch installieren?' -Default $true) { 'true' } else { 'false' }
    $config['STORAGE_LAYOUT'] = 'SingleRoot'

    # Konfiguration schreiben
    Write-EnvFile -Path $script:EnvPath -Config $config
    Write-Host ''
    Write-Host "Konfiguration gespeichert: $($script:EnvPath)"

    # Scope-Marker setzen
    $labRootPath = $config['LAB_ROOT']
    if (-not (Test-Path -LiteralPath $labRootPath)) {
        New-Item -Path $labRootPath -ItemType Directory -Force | Out-Null
    }
    Write-ScopeMarker -Path $labRootPath -ScopeId $config['SCOPE_ID']

    # Netzwerk, VMs, SQL-Installation
    if (Read-YesNo -Prompt 'Umgebung jetzt erstellen und starten?' -Default $true) {
        New-LabSwitch
        Initialize-VmEnvironment -Config $config
    }
}

function Initialize-VmEnvironment {
    param([Parameter(Mandatory)][hashtable] $Config)

    $labRoot = $Config['LAB_ROOT']
    $baseDir = Join-Path $labRoot 'base'
    $profileDef = $script:ResourceProfiles[$Config['RESOURCE_PROFILE']]
    $versions = $Config['SQL_VERSIONS'] -split ','
    $saPassword = $Config['SA_PASSWORD']
    $osMode = $Config['OS_MODE']

    # Base-Verzeichnis
    if (-not (Test-Path -LiteralPath $baseDir)) {
        New-Item -Path $baseDir -ItemType Directory -Force | Out-Null
    }

    # --- Windows Base-Image ---
    if ($osMode -in @('Windows', 'Mixed')) {
        $winBaseVhdx = Join-Path $baseDir 'windows-server-base.vhdx'
        if ($Config['WIN_BASE_IMAGE_SOURCE'] -eq 'Local') {
            if (-not (Test-Path -LiteralPath $winBaseVhdx)) {
                Write-Host 'Kopiere Windows Base-VHDX...'
                Copy-Item -LiteralPath $Config['WIN_BASE_VHDX_PATH'] -Destination $winBaseVhdx
            }
        }
        else {
            if (-not (Test-Path -LiteralPath $winBaseVhdx)) {
                throw 'Download-Modus fuer Windows Base-Image noch nicht implementiert. Bitte lokales VHDX bereitstellen.'
            }
        }
        Set-ItemProperty -LiteralPath $winBaseVhdx -Name IsReadOnly -Value $true
    }

    # --- Linux Base-Image ---
    if ($osMode -in @('Linux', 'Mixed')) {
        $linuxBaseVhdx = Join-Path $baseDir 'ubuntu-cloud-base.vhdx'
        if ($Config['LINUX_BASE_IMAGE_SOURCE'] -eq 'Local') {
            if (-not (Test-Path -LiteralPath $linuxBaseVhdx)) {
                Write-Host 'Kopiere Linux Base-VHDX...'
                Copy-Item -LiteralPath $Config['LINUX_BASE_VHDX_PATH'] -Destination $linuxBaseVhdx
            }
        }
        else {
            if (-not (Test-Path -LiteralPath $linuxBaseVhdx)) {
                Get-LinuxCloudImage -DestinationPath $linuxBaseVhdx
            }
        }
        Set-ItemProperty -LiteralPath $linuxBaseVhdx -Name IsReadOnly -Value $true
    }

    # --- Windows VMs erstellen ---
    if ($osMode -in @('Windows', 'Mixed')) {
        Write-Section 'Windows-VMs erstellen'
        $securePass = ConvertTo-SecureString -String 'P@ssw0rd' -AsPlainText -Force
        $credential = [pscredential]::new('Administrator', $securePass)

        foreach ($version in $versions) {
            $vmDir = Join-Path $labRoot "vm-win-$version"
            $diffVhd = Join-Path $vmDir "sql${version}-diff.vhdx"
            $vmKey = "win-$version"
            $vmName = "SQL_Analyze_Win_$version"

            New-DifferencingDisk -ParentPath $winBaseVhdx -DiffPath $diffVhd
            New-LabVm -VmName $vmName -VhdPath $diffVhd -Profile $profileDef -SwitchName $script:SwitchName

            Start-VM -Name $vmName
            Wait-VmReady -VmName $vmName -TimeoutSeconds 600
            Set-VmStaticIp -VmName $vmName -IpAddress $script:VmIpMap[$vmKey] -Credential $credential

            # SQL Server installieren
            $mediaPath = $Config["SQL_${version}_MEDIA"]
            if ($mediaPath -eq 'Download') {
                throw "Download-Modus fuer SQL Server $version Medien noch nicht implementiert. Bitte ISO bereitstellen."
            }
            $vmIsoPath = "C:\Temp\sql_server_$version.iso"
            Copy-VMFile -Name $vmName -SourcePath $mediaPath -DestinationPath $vmIsoPath `
                -FileSource Host -CreateFullPath -Force
            Install-SqlServerInVm -VmName $vmName -Version $version -MediaPath $vmIsoPath `
                -SaPassword $saPassword -Credential $credential

            if ($Config['INSTALL_FRAMEWORK'] -eq 'true') {
                Install-FrameworkInVm -VmName $vmName -SaPassword $saPassword -Credential $credential
            }
            Write-Host "  Windows SQL $version bereit: $($script:VmIpMap[$vmKey]),1433"
        }
    }

    # --- Linux VMs erstellen ---
    if ($osMode -in @('Linux', 'Mixed')) {
        Write-Section 'Linux-VMs erstellen'
        $sshKeyPath = $Config['SSH_KEY_PATH']
        $sshPubKey = $Config['SSH_PUB_KEY']

        foreach ($version in $versions) {
            $vmDir = Join-Path $labRoot "vm-linux-$version"
            $diffVhd = Join-Path $vmDir "sql${version}-diff.vhdx"
            $dataVhd = Join-Path $vmDir 'data.vhdx'
            $logVhd = Join-Path $vmDir 'log.vhdx'
            $vmKey = "linux-$version"
            $vmName = "SQL_Analyze_Linux_$version"
            $ipAddress = $script:VmIpMap[$vmKey]

            # Differencing Disk + dedizierte Data/Log-Disks
            New-DifferencingDisk -ParentPath $linuxBaseVhdx -DiffPath $diffVhd
            New-LabDataDisk -Path $dataVhd -SizeGB 20
            New-LabDataDisk -Path $logVhd -SizeGB 10

            # cloud-init ISO erstellen (User, SSH-Key, Netzwerk)
            $ciIso = Join-Path $vmDir 'cloud-init.iso'
            New-CloudInitIso -DestinationPath $ciIso `
                -Hostname $vmName `
                -IpAddress $ipAddress `
                -Gateway $script:GatewayIP `
                -SshPubKey $sshPubKey `
                -User 'labadmin'

            # VM erstellen
            New-LabLinuxVm -VmName $vmName -OsDisk $diffVhd -DataDisk $dataVhd `
                -LogDisk $logVhd -CloudInitIso $ciIso -Profile $profileDef -SwitchName $script:SwitchName

            Start-VM -Name $vmName
            Write-Host "  Warte auf SSH ($ipAddress)..."
            Get-SshSession -VmName $vmName -IpAddress $ipAddress

            # SQL Server installieren (APT)
            Install-SqlServerOnLinux -VmName $vmName -IpAddress $ipAddress `
                -Version $version -SaPassword $saPassword -SshKeyPath $sshKeyPath

            # Framework installieren
            if ($Config['INSTALL_FRAMEWORK'] -eq 'true') {
                Install-FrameworkOnLinux -VmName $vmName -IpAddress $ipAddress `
                    -SaPassword $saPassword -SshKeyPath $sshKeyPath
            }

            # Initiales Netzwerk-/IO-Profil setzen
            $netProfile = $Config['LINUX_NETWORK_PROFILE']
            if ($netProfile -and $netProfile -ne 'LAN') {
                Set-NetworkProfile -VmName $vmName -IpAddress $ipAddress -ProfileName $netProfile
            }
            $ioProfile = $Config['LINUX_IO_PROFILE']
            if ($ioProfile -and $ioProfile -ne 'SSD') {
                Set-IoProfile -VmName $vmName -IpAddress $ipAddress -ProfileName $ioProfile
            }

            Write-Host "  Linux SQL $version bereit: $ipAddress,1433"
        }
    }

    # --- Zusammenfassung ---
    Write-Section 'Setup abgeschlossen'
    Write-Host 'Verbindung via SSMS/ADS/sqlcmd:'
    foreach ($version in $versions) {
        if ($osMode -in @('Windows', 'Mixed')) {
            Write-Host "  Windows SQL ${version}: $($script:VmIpMap['win-' + $version]),1433 (sa)"
        }
        if ($osMode -in @('Linux', 'Mixed')) {
            Write-Host "  Linux   SQL ${version}: $($script:VmIpMap['linux-' + $version]),1433 (sa)"
        }
    }
}

function Invoke-Menu {
    Write-Section 'Hyper-V QuickStart Menü'
    if (-not (Test-Path -LiteralPath $script:EnvPath)) {
        Write-Host 'Keine Konfiguration gefunden. Starte Setup...'
        Invoke-Setup
        return
    }

    $choice = Read-MenuChoice -Prompt 'Aktion wählen' `
        -Choices @{
            '1' = 'Start (VMs starten)'
            '2' = 'Status anzeigen'
            '3' = 'Stop (VMs herunterfahren)'
            '4' = 'Remove (VMs und Daten entfernen)'
            '5' = 'Setup (neu einrichten)'
        } `
        -DefaultKey '2'

    switch ($choice) {
        '1' { Start-Environment }
        '2' { Show-Status }
        '3' { Stop-Environment }
        '4' { Remove-Environment }
        '5' { Invoke-Setup }
    }
}
