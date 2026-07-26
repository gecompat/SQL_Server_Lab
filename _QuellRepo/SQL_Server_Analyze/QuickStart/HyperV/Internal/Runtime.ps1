function Start-Environment {
    Write-Section 'VMs starten'
    $config = Read-EnvFile -Path $script:EnvPath
    if ($config.Count -eq 0) {
        throw 'Keine Konfiguration gefunden. Bitte zuerst Setup ausfuehren.'
    }

    $versions = $config['SQL_VERSIONS'] -split ','
    $osMode = $config['OS_MODE']

    # VM-Namen sammeln
    $vmList = @()
    foreach ($version in $versions) {
        if ($osMode -in @('Windows', 'Mixed')) {
            $vmList += @{ Name = "SQL_Analyze_Win_$version"; Key = "win-$version"; Type = 'Windows' }
        }
        if ($osMode -in @('Linux', 'Mixed')) {
            $vmList += @{ Name = "SQL_Analyze_Linux_$version"; Key = "linux-$version"; Type = 'Linux' }
        }
    }

    # VMs starten
    foreach ($entry in $vmList) {
        $vm = Get-VM -Name $entry.Name -ErrorAction SilentlyContinue
        if ($null -eq $vm) {
            Write-Warning "VM '$($entry.Name)' nicht gefunden. Uebersprungen."
            continue
        }
        if ($vm.State -eq 'Running') {
            Write-Host "VM '$($entry.Name)' laeuft bereits."
            continue
        }
        Write-Host "Starte VM '$($entry.Name)'..."
        Start-VM -Name $entry.Name
    }

    # Auf SQL-Bereitschaft warten
    Write-Host ''
    foreach ($entry in $vmList) {
        $ip = $script:VmIpMap[$entry.Key]
        Write-Host "Warte auf SQL Server ($($entry.Name), $ip)..."

        if ($entry.Type -eq 'Linux') {
            # SSH-Bereitschaft pruefen
            $sshReady = $false
            for ($i = 0; $i -lt 30; $i++) {
                $tcp = Test-NetConnection -ComputerName $ip -Port 22 -WarningAction SilentlyContinue
                if ($tcp.TcpTestSucceeded) { $sshReady = $true; break }
                Start-Sleep -Seconds 3
            }
            if (-not $sshReady) {
                Write-Warning "  SSH auf $($entry.Name) nicht erreichbar."
                continue
            }
        }

        # SQL-Verbindungstest
        $ready = $false
        for ($i = 0; $i -lt 60; $i++) {
            if (Test-SqlConnection -ServerInstance "$ip,1433" -Password $config['SA_PASSWORD'] -TimeoutSeconds 3) {
                $ready = $true
                break
            }
            Start-Sleep -Seconds 5
        }
        if ($ready) {
            Write-Host "  $($entry.Name) bereit." -ForegroundColor Green
        }
        else {
            Write-Warning "  $($entry.Name) nicht erreichbar nach 5 Minuten."
        }
    }
}

function Show-Status {
    Write-Section 'Hyper-V QuickStart Status'
    $config = Read-EnvFile -Path $script:EnvPath
    if ($config.Count -eq 0) {
        Write-Host 'Keine Konfiguration gefunden.'
        return
    }

    Write-Host "Scope-ID: $($config['SCOPE_ID'])"
    Write-Host "Modus:    $($config['OS_MODE'])"
    Write-Host "Profil:   $($config['RESOURCE_PROFILE'])"
    Write-Host "Lab-Root: $($config['LAB_ROOT'])"
    Write-Host ''

    $versions = $config['SQL_VERSIONS'] -split ','
    $osMode = $config['OS_MODE']

    foreach ($version in $versions) {
        if ($osMode -in @('Windows', 'Mixed')) {
            $vmName = "SQL_Analyze_Win_$version"
            $ip = $script:VmIpMap["win-$version"]
            Show-VmStatus -VmName $vmName -IpAddress $ip -Version $version -OsType 'Windows' -Config $config
        }
        if ($osMode -in @('Linux', 'Mixed')) {
            $vmName = "SQL_Analyze_Linux_$version"
            $ip = $script:VmIpMap["linux-$version"]
            Show-VmStatus -VmName $vmName -IpAddress $ip -Version $version -OsType 'Linux' -Config $config
        }
    }
}

function Show-VmStatus {
    param(
        [string] $VmName,
        [string] $IpAddress,
        [string] $Version,
        [string] $OsType,
        [hashtable] $Config
    )

    $vm = Get-VM -Name $VmName -ErrorAction SilentlyContinue
    $state = if ($null -eq $vm) { 'NICHT VORHANDEN' } else { $vm.State.ToString() }
    $sqlStatus = 'unbekannt'

    if ($null -ne $vm -and $vm.State -eq 'Running') {
        $sqlStatus = if (Test-SqlConnection -ServerInstance "$IpAddress,1433" -Password $Config['SA_PASSWORD'] -TimeoutSeconds 3) {
            'erreichbar'
        }
        else {
            'nicht erreichbar'
        }
    }

    Write-Host "SQL Server $Version [$OsType] ($VmName):"
    Write-Host "  VM:  $state"
    Write-Host "  SQL: $sqlStatus"
    Write-Host "  IP:  $IpAddress,1433"

    # Linux: Simulation-Status anzeigen
    if ($OsType -eq 'Linux' -and $state -eq 'Running' -and $sqlStatus -eq 'erreichbar') {
        try {
            Show-SimulationStatus -VmName $VmName -IpAddress $IpAddress
        }
        catch {
            Write-Host '  Simulation: Status nicht abrufbar'
        }
    }
    Write-Host ''
}

function Stop-Environment {
    Write-Section 'VMs herunterfahren'
    $config = Read-EnvFile -Path $script:EnvPath
    if ($config.Count -eq 0) {
        throw 'Keine Konfiguration gefunden.'
    }

    $versions = $config['SQL_VERSIONS'] -split ','
    $osMode = $config['OS_MODE']

    $vmNames = @()
    foreach ($version in $versions) {
        if ($osMode -in @('Windows', 'Mixed')) { $vmNames += "SQL_Analyze_Win_$version" }
        if ($osMode -in @('Linux', 'Mixed')) { $vmNames += "SQL_Analyze_Linux_$version" }
    }

    foreach ($vmName in $vmNames) {
        $vm = Get-VM -Name $vmName -ErrorAction SilentlyContinue
        if ($null -eq $vm) {
            Write-Warning "VM '$vmName' nicht gefunden."
            continue
        }
        if ($vm.State -ne 'Running') {
            Write-Host "VM '$vmName' ist nicht aktiv ($($vm.State))."
            continue
        }
        Write-Host "Fahre VM '$vmName' herunter..."
        Stop-VM -Name $vmName -Force
    }
    Write-Host 'Alle VMs gestoppt.'
}
