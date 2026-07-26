# NetworkSimulation.ps1
# Netzwerk- und I/O-Simulation für Linux-VMs via SSH + tc/netem/cgroups

function Get-SshSession {
    param(
        [Parameter(Mandatory)][string] $VmName,
        [Parameter(Mandatory)][string] $IpAddress
    )

    # Prüfe ob SSH verfügbar ist
    $sshAvailable = $false
    for ($i = 0; $i -lt 10; $i++) {
        $tcpTest = Test-NetConnection -ComputerName $IpAddress -Port 22 -WarningAction SilentlyContinue
        if ($tcpTest.TcpTestSucceeded) {
            $sshAvailable = $true
            break
        }
        Start-Sleep -Seconds 3
    }
    if (-not $sshAvailable) {
        throw "SSH auf $VmName ($IpAddress) nicht erreichbar."
    }
    return $IpAddress
}

function Invoke-SshCommand {
    param(
        [Parameter(Mandatory)][string] $IpAddress,
        [Parameter(Mandatory)][string] $Command,
        [string] $User = 'labadmin',
        [string] $KeyPath = $null
    )

    $sshArgs = @('-o', 'StrictHostKeyChecking=no', '-o', 'UserKnownHostsFile=/dev/null')
    if ($KeyPath) {
        $sshArgs += @('-i', $KeyPath)
    }
    $sshArgs += @("$User@$IpAddress", $Command)

    $result = & ssh @sshArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "SSH-Befehl fehlgeschlagen auf $IpAddress`: $Command"
        Write-Warning ($result | Out-String)
    }
    return $result
}

function Set-NetworkProfile {
    param(
        [Parameter(Mandatory)][string] $VmName,
        [Parameter(Mandatory)][string] $IpAddress,
        [Parameter(Mandatory)][string] $ProfileName
    )

    if (-not $script:NetworkProfiles.ContainsKey($ProfileName)) {
        throw "Unbekanntes Netzwerkprofil: $ProfileName. Verfügbar: $($script:NetworkProfiles.Keys -join ', ')"
    }

    $profile = $script:NetworkProfiles[$ProfileName]
    Write-Section "Netzwerkprofil '$ProfileName' auf $VmName anwenden"
    Write-Host "  Beschreibung: $($profile.Description)"
    Write-Host "  Latenz: $($profile.Delay)"
    Write-Host "  Bandbreite: $(if ($profile.Rate) { $profile.Rate } else { 'unbegrenzt' })"
    Write-Host "  Paketverlust: $($profile.Loss)"

    # Bestehende qdisc entfernen
    Invoke-SshCommand -IpAddress $IpAddress -Command 'sudo tc qdisc del dev eth0 root 2>/dev/null; true'

    if ($ProfileName -eq 'LAN') {
        Write-Host '  Netzwerksimulation deaktiviert (LAN-Modus).'
        return
    }

    # netem für Latenz und Paketverlust
    $netemCmd = "sudo tc qdisc add dev eth0 root handle 1: netem delay $($profile.Delay) loss $($profile.Loss)"
    Invoke-SshCommand -IpAddress $IpAddress -Command $netemCmd

    # tbf für Bandbreitenlimit (als Child von netem)
    if ($profile.Rate) {
        $tbfCmd = "sudo tc qdisc add dev eth0 parent 1: handle 2: tbf rate $($profile.Rate) burst 64kbit latency 50ms"
        Invoke-SshCommand -IpAddress $IpAddress -Command $tbfCmd
    }

    Write-Host '  Netzwerkprofil aktiv.'
}

function Get-NetworkProfile {
    param(
        [Parameter(Mandatory)][string] $IpAddress
    )

    $output = Invoke-SshCommand -IpAddress $IpAddress -Command 'sudo tc qdisc show dev eth0 2>/dev/null'
    return ($output | Out-String).Trim()
}

function Set-IoProfile {
    param(
        [Parameter(Mandatory)][string] $VmName,
        [Parameter(Mandatory)][string] $IpAddress,
        [Parameter(Mandatory)][string] $ProfileName,
        [string] $DataDevice = '',
        [string] $LogDevice = ''
    )

    if (-not $script:IoProfiles.ContainsKey($ProfileName)) {
        throw "Unbekanntes I/O-Profil: $ProfileName. Verfügbar: $($script:IoProfiles.Keys -join ', ')"
    }

    $profile = $script:IoProfiles[$ProfileName]
    Write-Section "I/O-Profil '$ProfileName' auf $VmName anwenden"
    Write-Host "  Beschreibung: $($profile.Description)"

    if ($ProfileName -eq 'SSD') {
        # Alle I/O-Limits entfernen
        $resetCmd = @"
sudo bash -c '
  for cg in /sys/fs/cgroup/sql_data /sys/fs/cgroup/sql_log; do
    if [ -d \"\$cg\" ]; then
      echo \"\" > \"\$cg/io.max\"
    fi
  done
'
"@
        Invoke-SshCommand -IpAddress $IpAddress -Command $resetCmd
        Write-Host '  I/O-Simulation deaktiviert (SSD-Modus).'
        return
    }

    # Geräte ermitteln falls nicht angegeben
    if (-not $DataDevice) {
        $DataDevice = (Invoke-SshCommand -IpAddress $IpAddress -Command `
            "lsblk -no NAME,MOUNTPOINT | grep '/var/opt/mssql/data' | awk '{print \"/dev/\"\$1}'" | Out-String).Trim()
    }
    if (-not $LogDevice) {
        $LogDevice = (Invoke-SshCommand -IpAddress $IpAddress -Command `
            "lsblk -no NAME,MOUNTPOINT | grep '/var/opt/mssql/log' | awk '{print \"/dev/\"\$1}'" | Out-String).Trim()
    }

    if (-not $DataDevice -and -not $LogDevice) {
        Write-Warning 'Keine dedizierten Data/Log-Geräte gefunden. I/O-Profil nicht anwendbar.'
        return
    }

    # cgroups v2 io.max setzen
    $devices = @()
    if ($DataDevice) { $devices += @{ Path = $DataDevice; Name = 'sql_data' } }
    if ($LogDevice) { $devices += @{ Path = $LogDevice; Name = 'sql_log' } }

    foreach ($dev in $devices) {
        $major_minor = (Invoke-SshCommand -IpAddress $IpAddress -Command `
            "stat -c '%t:%T' $($dev.Path) | xargs printf '%d:%d'" | Out-String).Trim()

        $limits = @()
        $rIOPS = if ($profile.ReadIOPS -gt 0) { "riops=$($profile.ReadIOPS)" } else { '' }
        $wIOPS = if ($profile.WriteIOPS -gt 0) { "wiops=$($profile.WriteIOPS)" } else { '' }
        $rBPS = if ($profile.ReadMBs -gt 0) { "rbps=$($profile.ReadMBs * 1048576)" } else { '' }
        $wBPS = if ($profile.WriteMBs -gt 0) { "wbps=$($profile.WriteMBs * 1048576)" } else { '' }
        $limitLine = @($rIOPS, $wIOPS, $rBPS, $wBPS) | Where-Object { $_ } | Join-String -Separator ' '

        $cgroupCmd = @"
sudo bash -c '
  mkdir -p /sys/fs/cgroup/$($dev.Name)
  echo "$major_minor $limitLine" > /sys/fs/cgroup/$($dev.Name)/io.max
  # SQL Server PID in cgroup verschieben
  MSSQL_PID=\$(pgrep -x sqlservr | head -1)
  if [ -n "\$MSSQL_PID" ]; then
    echo \$MSSQL_PID > /sys/fs/cgroup/$($dev.Name)/cgroup.procs
  fi
'
"@
        Invoke-SshCommand -IpAddress $IpAddress -Command $cgroupCmd
        Write-Host "  $($dev.Name) ($($dev.Path)): $limitLine"
    }

    Write-Host '  I/O-Profil aktiv.'
}

function Get-IoProfile {
    param(
        [Parameter(Mandatory)][string] $IpAddress
    )

    $output = Invoke-SshCommand -IpAddress $IpAddress -Command @'
sudo bash -c '
  for cg in sql_data sql_log; do
    f="/sys/fs/cgroup/$cg/io.max"
    if [ -f "$f" ]; then
      echo "$cg: $(cat $f)"
    fi
  done
'
'@
    return ($output | Out-String).Trim()
}

function Show-SimulationStatus {
    param(
        [Parameter(Mandatory)][string] $VmName,
        [Parameter(Mandatory)][string] $IpAddress
    )

    Write-Section "Simulation Status: $VmName"

    Write-Host '  Netzwerk:'
    $netStatus = Get-NetworkProfile -IpAddress $IpAddress
    if ($netStatus -match 'netem') {
        Write-Host "    $netStatus" -ForegroundColor Yellow
    }
    else {
        Write-Host '    LAN (keine Simulation)' -ForegroundColor Green
    }

    Write-Host '  I/O:'
    $ioStatus = Get-IoProfile -IpAddress $IpAddress
    if ($ioStatus) {
        Write-Host "    $ioStatus" -ForegroundColor Yellow
    }
    else {
        Write-Host '    SSD (keine Drosselung)' -ForegroundColor Green
    }
}
