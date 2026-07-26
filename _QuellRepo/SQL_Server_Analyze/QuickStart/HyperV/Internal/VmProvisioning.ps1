function New-LabSwitch {
    $existing = Get-VMSwitch -Name $script:SwitchName -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host "Hyper-V Switch '$($script:SwitchName)' existiert bereits."
        return
    }

    Write-Host "Erstelle internen Hyper-V Switch '$($script:SwitchName)'..."
    New-VMSwitch -Name $script:SwitchName -SwitchType Internal | Out-Null

    # Adapter und Gateway konfigurieren
    $adapter = Get-NetAdapter | Where-Object { $_.Name -like "*$($script:SwitchName)*" } | Select-Object -First 1
    if ($null -eq $adapter) {
        throw "Netzwerkadapter für Switch '$($script:SwitchName)' nicht gefunden."
    }
    New-NetIPAddress -InterfaceIndex $adapter.ifIndex `
        -IPAddress $script:GatewayAddress `
        -PrefixLength $script:PrefixLength `
        -ErrorAction SilentlyContinue | Out-Null

    # NAT erstellen
    $existingNat = Get-NetNat -Name $script:NatName -ErrorAction SilentlyContinue
    if (-not $existingNat) {
        Write-Host "Erstelle NAT '$($script:NatName)' ($($script:NatSubnet))..."
        New-NetNat -Name $script:NatName -InternalIPInterfaceAddressPrefix $script:NatSubnet | Out-Null
    }
}

function Remove-LabSwitch {
    $existingNat = Get-NetNat -Name $script:NatName -ErrorAction SilentlyContinue
    if ($existingNat) {
        Write-Host "Entferne NAT '$($script:NatName)'..."
        Remove-NetNat -Name $script:NatName -Confirm:$false
    }

    $existing = Get-VMSwitch -Name $script:SwitchName -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host "Entferne Hyper-V Switch '$($script:SwitchName)'..."
        Remove-VMSwitch -Name $script:SwitchName -Force
    }
}

function New-DifferencingDisk {
    param(
        [Parameter(Mandatory)][string] $ParentPath,
        [Parameter(Mandatory)][string] $DiffPath
    )

    if (Test-Path -LiteralPath $DiffPath) {
        Write-Host "Differencing Disk existiert bereits: $DiffPath"
        return
    }

    $diffDir = [IO.Path]::GetDirectoryName($DiffPath)
    if (-not (Test-Path -LiteralPath $diffDir)) {
        New-Item -Path $diffDir -ItemType Directory -Force | Out-Null
    }

    Write-Host "Erstelle Differencing Disk: $DiffPath"
    Write-Host "  Parent: $ParentPath"
    New-VHD -Path $DiffPath -ParentPath $ParentPath -Differencing | Out-Null
}

function New-LabVm {
    param(
        [Parameter(Mandatory)][string] $Version,
        [Parameter(Mandatory)][string] $VhdPath,
        [Parameter(Mandatory)][hashtable] $Profile
    )

    $vmName = $script:VmNames[$Version]
    $existing = Get-VM -Name $vmName -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host "VM '$vmName' existiert bereits."
        return
    }

    Write-Section "Erstelle VM: $vmName"

    $vm = New-VM -Name $vmName `
        -Generation 2 `
        -MemoryStartupBytes $Profile.MinMemory `
        -VHDPath $VhdPath `
        -SwitchName $script:SwitchName

    # Konfiguration
    Set-VMMemory -VM $vm -DynamicMemoryEnabled $true `
        -MinimumBytes ($Profile.MinMemory / 2) `
        -MaximumBytes $Profile.MaxMemory

    Set-VMProcessor -VM $vm -Count $Profile.vCPUs

    # Secure Boot deaktivieren (Flexibilität)
    Set-VMFirmware -VM $vm -EnableSecureBoot Off

    # Checkpoints deaktivieren
    Set-VM -VM $vm -CheckpointType Disabled

    # Integration Services
    Enable-VMIntegrationService -VM $vm -Name 'Guest Service Interface' -ErrorAction SilentlyContinue

    Write-Host "VM '$vmName' erstellt ($(($Profile.MinMemory / 1GB))GB RAM, $($Profile.vCPUs) vCPUs)."
}

function Wait-VmReady {
    param(
        [Parameter(Mandatory)][string] $VmName,
        [int] $TimeoutSeconds = 600
    )

    Write-Host "Warte auf VM '$VmName' Bereitschaft..."
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

    # Warte auf Heartbeat
    while ((Get-Date) -lt $deadline) {
        $vm = Get-VM -Name $VmName -ErrorAction SilentlyContinue
        if ($null -ne $vm -and $vm.Heartbeat -eq 'OkApplicationsHealthy') {
            break
        }
        if ($null -ne $vm -and $vm.State -ne 'Running') {
            throw "VM '$VmName' ist nicht im Zustand 'Running' (Zustand: $($vm.State))."
        }
        Start-Sleep -Seconds 5
    }

    if ((Get-Date) -ge $deadline) {
        throw "Timeout: VM '$VmName' wurde nicht innerhalb von $TimeoutSeconds Sekunden bereit."
    }
    Write-Host "VM '$VmName' ist bereit (Heartbeat OK)."
}

function Invoke-VmPowerShell {
    param(
        [Parameter(Mandatory)][string] $VmName,
        [Parameter(Mandatory)][scriptblock] $ScriptBlock,
        [pscredential] $Credential,
        [int] $TimeoutSeconds = 300
    )

    $params = @{
        VMName = $VmName
        ScriptBlock = $ScriptBlock
    }
    if ($null -ne $Credential) {
        $params['Credential'] = $Credential
    }

    Invoke-Command @params -ErrorAction Stop
}

function Set-VmStaticIp {
    param(
        [Parameter(Mandatory)][string] $VmName,
        [Parameter(Mandatory)][string] $IpAddress,
        [Parameter(Mandatory)][pscredential] $Credential
    )

    Write-Host "Konfiguriere statische IP $IpAddress für '$VmName'..."
    Invoke-VmPowerShell -VmName $VmName -Credential $Credential -ScriptBlock {
        param($Ip, $Gateway, $Prefix)
        $adapter = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' } | Select-Object -First 1
        if ($null -eq $adapter) { throw 'Kein aktiver Netzwerkadapter in der VM.' }
        Remove-NetIPAddress -InterfaceIndex $adapter.ifIndex -Confirm:$false -ErrorAction SilentlyContinue
        Remove-NetRoute -InterfaceIndex $adapter.ifIndex -Confirm:$false -ErrorAction SilentlyContinue
        New-NetIPAddress -InterfaceIndex $adapter.ifIndex -IPAddress $Ip -PrefixLength $Prefix -DefaultGateway $Gateway | Out-Null
        Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses @('8.8.8.8', '1.1.1.1')
    } -ArgumentList @($IpAddress, $script:GatewayAddress, $script:PrefixLength)
}

# ============================================================
# Linux-VM-Provisioning
# ============================================================

function Get-LinuxCloudImage {
    param(
        [Parameter(Mandatory)][string] $DestinationPath
    )

    # Ubuntu 24.04 LTS Cloud Image (VHDX fuer Hyper-V)
    $imageUrl = 'https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64-hyperv.vhdx.zip'
    $zipPath = "$DestinationPath.zip"

    Write-Section 'Ubuntu Cloud-Image herunterladen'
    Write-Host "  URL: $imageUrl"
    Write-Host "  Ziel: $DestinationPath"

    $destDir = [IO.Path]::GetDirectoryName($DestinationPath)
    if (-not (Test-Path -LiteralPath $destDir)) {
        New-Item -Path $destDir -ItemType Directory -Force | Out-Null
    }

    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri $imageUrl -OutFile $zipPath -UseBasicParsing
    $ProgressPreference = 'Continue'

    Write-Host '  Entpacke VHDX...'
    Expand-Archive -Path $zipPath -DestinationPath $destDir -Force
    $extractedVhdx = Get-ChildItem -Path $destDir -Filter '*.vhdx' |
        Where-Object { $_.Name -ne (Split-Path $DestinationPath -Leaf) } |
        Select-Object -First 1
    if ($extractedVhdx) {
        Move-Item -LiteralPath $extractedVhdx.FullName -Destination $DestinationPath -Force
    }
    Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue

    # VHDX auf mindestens 30 GB vergroessern (Cloud-Image ist minimal)
    $vhd = Get-VHD -Path $DestinationPath
    if ($vhd.Size -lt 30GB) {
        Resize-VHD -Path $DestinationPath -SizeBytes 30GB
    }

    Write-Host '  Cloud-Image bereit.'
}

function New-LabDataDisk {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][int] $SizeGB
    )

    if (Test-Path -LiteralPath $Path) {
        Write-Host "Data-Disk existiert bereits: $Path"
        return
    }

    $diskDir = [IO.Path]::GetDirectoryName($Path)
    if (-not (Test-Path -LiteralPath $diskDir)) {
        New-Item -Path $diskDir -ItemType Directory -Force | Out-Null
    }

    Write-Host "Erstelle Data-Disk: $Path (${SizeGB}GB)"
    New-VHD -Path $Path -SizeBytes ($SizeGB * 1GB) -Dynamic | Out-Null
}

function New-CloudInitIso {
    param(
        [Parameter(Mandatory)][string] $DestinationPath,
        [Parameter(Mandatory)][string] $Hostname,
        [Parameter(Mandatory)][string] $IpAddress,
        [Parameter(Mandatory)][string] $Gateway,
        [Parameter(Mandatory)][string] $SshPubKey,
        [string] $User = 'labadmin'
    )

    Write-Host "Erstelle cloud-init ISO: $DestinationPath"

    $metaData = @"
instance-id: $Hostname
local-hostname: $Hostname
"@

    $userData = @"
#cloud-config
users:
  - name: $User
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - $SshPubKey
    lock_passwd: true

package_update: true
packages:
  - iproute2
  - curl
  - apt-transport-https

runcmd:
  - systemctl enable ssh
  - systemctl start ssh
"@

    $networkConfig = @"
network:
  version: 2
  ethernets:
    eth0:
      addresses:
        - $IpAddress/24
      routes:
        - to: default
          via: $Gateway
      nameservers:
        addresses:
          - 8.8.8.8
          - 1.1.1.1
"@

    # ISO erstellen via oscdimg (Windows ADK) oder Fallback
    $isoDir = Join-Path ([IO.Path]::GetTempPath()) "cloudinit-$Hostname"
    if (Test-Path -LiteralPath $isoDir) { Remove-Item -LiteralPath $isoDir -Recurse -Force }
    New-Item -Path $isoDir -ItemType Directory -Force | Out-Null

    Set-Content -Path (Join-Path $isoDir 'meta-data') -Value $metaData -Encoding utf8NoBOM
    Set-Content -Path (Join-Path $isoDir 'user-data') -Value $userData -Encoding utf8NoBOM
    Set-Content -Path (Join-Path $isoDir 'network-config') -Value $networkConfig -Encoding utf8NoBOM

    # Versuche oscdimg.exe (Windows ADK)
    $oscdimg = Get-Command oscdimg.exe -ErrorAction SilentlyContinue
    if ($null -eq $oscdimg) {
        $adkPath = 'C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe'
        if (Test-Path -LiteralPath $adkPath) {
            $oscdimg = Get-Item $adkPath
        }
    }

    if ($null -ne $oscdimg) {
        & $oscdimg.FullName -j2 -lCIDATA $isoDir $DestinationPath | Out-Null
    }
    else {
        Write-Warning 'oscdimg.exe nicht gefunden. Windows ADK erforderlich fuer cloud-init ISO.'
        throw 'cloud-init ISO-Erstellung erfordert oscdimg.exe aus dem Windows ADK.'
    }

    Remove-Item -LiteralPath $isoDir -Recurse -Force -ErrorAction SilentlyContinue
}

function New-LabLinuxVm {
    param(
        [Parameter(Mandatory)][string] $VmName,
        [Parameter(Mandatory)][string] $OsDisk,
        [Parameter(Mandatory)][string] $DataDisk,
        [Parameter(Mandatory)][string] $LogDisk,
        [Parameter(Mandatory)][string] $CloudInitIso,
        [Parameter(Mandatory)][hashtable] $Profile,
        [Parameter(Mandatory)][string] $SwitchName
    )

    $existing = Get-VM -Name $VmName -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host "VM '$VmName' existiert bereits."
        return
    }

    Write-Section "Erstelle Linux-VM: $VmName"

    $vm = New-VM -Name $VmName `
        -Generation 2 `
        -MemoryStartupBytes $Profile.MinMemory `
        -VHDPath $OsDisk `
        -SwitchName $SwitchName

    # Dynamischer Speicher
    Set-VMMemory -VM $vm -DynamicMemoryEnabled $true `
        -MinimumBytes ($Profile.MinMemory / 2) `
        -MaximumBytes $Profile.MaxMemory

    Set-VMProcessor -VM $vm -Count $Profile.vCPUs

    # Secure Boot deaktivieren (Linux-Kompatibilitaet)
    Set-VMFirmware -VM $vm -EnableSecureBoot Off

    # Checkpoints deaktivieren
    Set-VM -VM $vm -CheckpointType Disabled

    # Zusaetzliche Disks anhaengen (Data + Log fuer I/O-Simulation)
    Add-VMHardDiskDrive -VM $vm -Path $DataDisk
    Add-VMHardDiskDrive -VM $vm -Path $LogDisk

    # cloud-init ISO als DVD
    Add-VMDvdDrive -VM $vm -Path $CloudInitIso

    # Boot-Reihenfolge: Festplatte zuerst
    $bootDisk = Get-VMHardDiskDrive -VM $vm | Select-Object -First 1
    Set-VMFirmware -VM $vm -FirstBootDevice $bootDisk

    Write-Host "Linux-VM '$VmName' erstellt ($(($Profile.MinMemory / 1GB))GB RAM, $($Profile.vCPUs) vCPUs, Data+Log Disks)."
}
