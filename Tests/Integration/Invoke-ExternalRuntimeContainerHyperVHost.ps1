#Requires -Version 7.2
<#
.SYNOPSIS
    Fuehrt Docker- und Podman-External-Runtime-Acceptance in einem isolierten Linux-Gast aus.
.DESCRIPTION
    Erstellt aus einem SHA-256-verifizierten Ubuntu-22.04-Cloud-VHD eine
    run-eigene Hyper-V-VM. cloud-init konfiguriert cgroup v1, PowerShell,
    sqlcmd, rootful Docker und rootful Podman. Anschliessend wird
    Invoke-ExternalRuntimeContainerAcceptance.ps1 fuer beide Provider getrennt
    ausgefuehrt. Die VM und alle run-eigenen Datentraeger werden standardmaessig
    auch bei Fehlern entfernt; das verifizierte Basisimage und sanitisierte
    Evidence liegen ausserhalb des Run-Verzeichnisses.
.PARAMETER SwitchName
    Vorhandener Hyper-V-Switch mit DHCP- und Internetzugang fuer den Gast.
.PARAMETER HostRoot
    Dedizierter Root fuer Media, fluechtige Runs und sanitisierte Evidence.
.PARAMETER KeepOnFailure
    Behaelt die VM und das Run-Verzeichnis bei einem Fehler fuer Diagnosezwecke.
#>
[CmdletBinding()]
param(
    [string]$SwitchName = 'Default Switch',
    [string]$HostRoot = 'D:\Lab_Base\Linux\ExternalRuntimeAcceptance',
    [ValidateSet('2022', '2025')][string]$SqlVersion = '2022',
    [ValidateRange(900, 14400)][int]$BootstrapTimeoutSeconds = 3600,
    [string]$TranscriptPath,
    [switch]$KeepOnFailure
)

$ErrorActionPreference = 'Stop'
if (-not $IsWindows -or -not (Get-Command Get-VM -ErrorAction SilentlyContinue)) {
    throw 'EXTERNAL_RUNTIME_CONTAINER_HYPERV_HOST_REQUIRES_WINDOWS_HYPERV'
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$imageRelease = '20260807'
$archiveName = 'ubuntu-22.04-server-cloudimg-amd64-azure.vhd.tar.gz'
$archiveSha256 = 'ed465d19bd73d1840a3b04edc895359ef5a631731fc8872a52c2409f3237f770'
$archiveUri = "https://cloud-images.ubuntu.com/releases/jammy/release-$imageRelease/$archiveName"
$mediaRoot = Join-Path $HostRoot "media\ubuntu-22.04-$imageRelease"
$archivePath = Join-Path $mediaRoot $archiveName
$baseVhdPath = Join-Path $mediaRoot 'livecd.ubuntu-cpc.azure.vhd'
$runsRoot = Join-Path $HostRoot 'runs'
$evidenceRoot = Join-Path $HostRoot 'evidence'
$runToken = [guid]::NewGuid().ToString('N')
$runRoot = Join-Path $runsRoot $runToken
$vmName = "SQLLAB-EXTLANG-LINUX-$($runToken.Substring(0, 10))"
$osVhdPath = Join-Path $runRoot 'ubuntu-22.04-os.vhdx'
$seedIsoPath = Join-Path $runRoot 'cidata.iso'
$privateKeyPath = Join-Path $runRoot 'acceptance_ed25519'
$publicKeyPath = "$privateKeyPath.pub"
$knownHostsPath = Join-Path $runRoot 'known_hosts'
$repoArchivePath = Join-Path $runRoot 'repository.tar.gz'
$serialPipeName = "sqllab-extlang-$($runToken.Substring(0, 10))"
$serialPipePath = "\\.\pipe\$serialPipeName"
$remoteRoot = '/opt/sql-server-lab'
$sshUser = 'labadmin'
$vmCreated = $false
$completed = $false
$transcriptStarted = $false

if ($TranscriptPath) {
    $transcriptDirectory = Split-Path -Parent $TranscriptPath
    if ($transcriptDirectory) { New-Item -Path $transcriptDirectory -ItemType Directory -Force | Out-Null }
    Start-Transcript -LiteralPath $TranscriptPath -Force | Out-Null
    $transcriptStarted = $true
}

function Assert-ExternalRuntimeHost {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Description)
    if (-not $Condition) { throw "EXTERNAL_RUNTIME_CONTAINER_HYPERV_HOST_FAILED: $Description" }
    Write-Host "PASS: $Description" -ForegroundColor Green
}

function Assert-ScopedRuntimePath {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Root)
    $fullPath = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    if (-not $fullPath.StartsWith("$fullRoot\", [StringComparison]::OrdinalIgnoreCase)) {
        throw "EXTERNAL_RUNTIME_CONTAINER_HYPERV_SCOPE_VIOLATION: $fullPath"
    }
}

function Send-ExternalRuntimeSerialLine {
    param(
        [Parameter(Mandatory)][IO.StreamWriter]$Writer,
        [Parameter(Mandatory)][string]$Value,
        [ValidateRange(20, 500)][int]$DelayMilliseconds = 100
    )
    foreach ($character in $Value.ToCharArray()) {
        $Writer.Write($character)
        Start-Sleep -Milliseconds $DelayMilliseconds
    }
    $Writer.Write("`r")
    Start-Sleep -Seconds 1
}

function Initialize-ExternalRuntimeNoCloudGuest {
    $pipe = [IO.Pipes.NamedPipeClientStream]::new(
        '.',
        $serialPipeName,
        [IO.Pipes.PipeDirection]::InOut,
        [IO.Pipes.PipeOptions]::Asynchronous
    )
    $connectTask = $pipe.ConnectAsync()
    Start-VM -Name $vmName | Out-Null
    if (-not $connectTask.Wait(10000)) {
        throw 'EXTERNAL_RUNTIME_CONTAINER_HYPERV_SERIAL_CONNECT_TIMEOUT'
    }

    try {
        $writer = [IO.StreamWriter]::new($pipe)
        $writer.AutoFlush = $true

        # Das gepinnte Azure-VHD priorisiert Azure/IMDS und beendet bei dessen
        # Fehlen die Datasource-Suche. Der hashgebundene Erstboot setzt deshalb
        # vor cloud-init ausschließlich NoCloud und startet danach normal neu.
        for ($index = 0; $index -lt 120; $index++) {
            $writer.Write([char]27)
            Start-Sleep -Milliseconds 25
        }
        Send-ExternalRuntimeSerialLine -Writer $writer -Value 'c'
        Send-ExternalRuntimeSerialLine -Writer $writer -Value 'search --no-floppy --fs-uuid --set=root 7f4dba93-74c0-4e0e-b8a8-854571dc965e'
        Send-ExternalRuntimeSerialLine -Writer $writer -Value 'linux /boot/vmlinuz-6.8.0-1064-azure root=PARTUUID=446bbf5a-4a8b-4efb-8173-e738bcba8b93 rw console=tty1 console=ttyS0 earlyprintk=ttyS0 nvme_core.io_timeout=240 init=/bin/bash'
        Send-ExternalRuntimeSerialLine -Writer $writer -Value 'initrd /boot/initrd.img-6.8.0-1064-azure'
        Send-ExternalRuntimeSerialLine -Writer $writer -Value 'boot'

        $buffer = [byte[]]::new(8192)
        $serialTail = ''
        $deadline = [DateTime]::UtcNow.AddSeconds(120)
        $readTask = $null
        while ([DateTime]::UtcNow -lt $deadline -and $serialTail -notmatch 'root@\(none\):/#') {
            if (-not $readTask) { $readTask = $pipe.ReadAsync($buffer,0,$buffer.Length) }
            if ($readTask.Wait(1000)) {
                if ($readTask.Result -gt 0) {
                    $serialTail += [Text.Encoding]::ASCII.GetString($buffer,0,$readTask.Result)
                    if ($serialTail.Length -gt 32768) {
                        $serialTail = $serialTail.Substring($serialTail.Length - 32768)
                    }
                }
                $readTask = $null
            }
        }
        if ($serialTail -notmatch 'root@\(none\):/#') {
            throw 'EXTERNAL_RUNTIME_CONTAINER_HYPERV_DIAGNOSTIC_SHELL_TIMEOUT'
        }

        Send-ExternalRuntimeSerialLine -Writer $writer -DelayMilliseconds 50 -Value "echo 'datasource_list: [ NoCloud ]' > /etc/cloud/cloud.cfg.d/99-sql-server-lab-nocloud.cfg; rm -rf /var/lib/cloud/instances/* /var/lib/cloud/instance; sync; /sbin/poweroff -f"
    }
    finally {
        $pipe.Dispose()
    }

    $shutdownDeadline = [DateTime]::UtcNow.AddSeconds(60)
    while ((Get-VM -Name $vmName).State -ne 'Off' -and [DateTime]::UtcNow -lt $shutdownDeadline) {
        Start-Sleep -Seconds 1
    }
    if ((Get-VM -Name $vmName).State -ne 'Off') {
        Stop-VM -Name $vmName -TurnOff -Force -Confirm:$false
    }
    Write-Host 'NoCloud-Datasource wurde im hashgebundenen Erstboot vorbereitet.' -ForegroundColor DarkCyan
    Start-VM -Name $vmName | Out-Null
}

function New-CidataIso {
    param(
        [Parameter(Mandatory)][string]$SourceDirectory,
        [Parameter(Mandatory)][string]$DestinationPath
    )

    if (-not ('SqlServerLabImapiStreamCopy' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

public static class SqlServerLabImapiStreamCopy
{
    public static void ToFile(object source, string path)
    {
        IStream stream = (IStream)source;
        byte[] buffer = new byte[65536];
        IntPtr bytesReadPointer = Marshal.AllocCoTaskMem(sizeof(int));
        try
        {
            using (FileStream file = new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.None))
            {
                while (true)
                {
                    Marshal.WriteInt32(bytesReadPointer, 0);
                    stream.Read(buffer, buffer.Length, bytesReadPointer);
                    int bytesRead = Marshal.ReadInt32(bytesReadPointer);
                    if (bytesRead <= 0) break;
                    file.Write(buffer, 0, bytesRead);
                }
            }
        }
        finally
        {
            Marshal.FreeCoTaskMem(bytesReadPointer);
        }
    }
}
'@
    }

    $image = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
    $image.FileSystemsToCreate = 3 # ISO 9660 + Joliet fuer NoCloud CIDATA
    $image.VolumeName = 'CIDATA'
    $image.Root.AddTree($SourceDirectory, $false)
    $result = $image.CreateResultImage()
    try {
        [SqlServerLabImapiStreamCopy]::ToFile($result.ImageStream, $DestinationPath)
    }
    finally {
        foreach ($comObject in @($result,$image)) {
            if ($comObject -and [Runtime.InteropServices.Marshal]::IsComObject($comObject)) {
                [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($comObject)
            }
        }
    }
    if (-not (Test-Path -LiteralPath $DestinationPath -PathType Leaf) -or
        (Get-Item -LiteralPath $DestinationPath).Length -lt 32768) {
        throw 'EXTERNAL_RUNTIME_CONTAINER_HYPERV_CIDATA_ISO_INVALID'
    }
    $mounted = $false
    try {
        Mount-DiskImage -ImagePath $DestinationPath -StorageType ISO -Access ReadOnly -PassThru | Out-Null
        $mounted = $true
        $volume = Get-DiskImage -ImagePath $DestinationPath | Get-Volume
        if (-not $volume.DriveLetter) { throw 'EXTERNAL_RUNTIME_CONTAINER_HYPERV_PROVISIONING_VOLUME_MISSING' }
        $entries = @(Get-ChildItem -LiteralPath "$($volume.DriveLetter):\" | ForEach-Object { $_.Name })
        foreach ($requiredEntry in @('user-data','meta-data')) {
            if ($entries -notcontains $requiredEntry) {
                throw "EXTERNAL_RUNTIME_CONTAINER_HYPERV_PROVISIONING_ENTRY_MISSING: $requiredEntry"
            }
        }
    }
    finally {
        if ($mounted) { Dismount-DiskImage -ImagePath $DestinationPath | Out-Null }
    }
}

function Invoke-GuestSsh {
    param(
        [Parameter(Mandatory)][string]$Address,
        [Parameter(Mandatory)][string]$Command,
        [switch]$IgnoreExitCode
    )
    $arguments = @(
        '-i', $privateKeyPath,
        '-o', 'BatchMode=yes',
        '-o', 'StrictHostKeyChecking=no',
        '-o', "UserKnownHostsFile=$knownHostsPath",
        '-o', 'ConnectTimeout=10',
        "$sshUser@$Address",
        $Command
    )
    & ssh @arguments
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0 -and -not $IgnoreExitCode) {
        throw "EXTERNAL_RUNTIME_CONTAINER_HYPERV_SSH_FAILED: exit=$exitCode command=$Command"
    }
    return $exitCode
}

function Get-GuestAddress {
    $localAddresses = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        ForEach-Object { [string]$_.IPAddress })
    $addresses = @(Get-VMNetworkAdapter -VMName $vmName | ForEach-Object { @($_.IPAddresses) } |
        Where-Object {
            $_ -match '^\d{1,3}(?:\.\d{1,3}){3}$' -and
            $_ -notmatch '^169\.254\.' -and
            $localAddresses -notcontains [string]$_
        })
    return @($addresses | Select-Object -First 1)[0]
}

function Wait-GuestAcceptanceReady {
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $lastProgress = [TimeSpan]::Zero
    while ($stopwatch.Elapsed.TotalSeconds -lt $BootstrapTimeoutSeconds) {
        $address = Get-GuestAddress
        if ($address) {
            $exitCode = Invoke-GuestSsh -Address $address -Command 'sudo test -f /var/lib/sql-server-lab/acceptance-ready' -IgnoreExitCode
            if ($exitCode -eq 0) {
                $stopwatch.Stop()
                return $address
            }
        }
        if (($stopwatch.Elapsed - $lastProgress).TotalSeconds -ge 30) {
            Write-Host "Warte auf Linux-Bootstrap/cgroup-v1-Reboot ($([int]$stopwatch.Elapsed.TotalSeconds)s)..." -ForegroundColor DarkCyan
            $lastProgress = $stopwatch.Elapsed
        }
        Start-Sleep -Seconds 5
    }
    $stopwatch.Stop()
    throw "EXTERNAL_RUNTIME_CONTAINER_HYPERV_BOOTSTRAP_TIMEOUT: $BootstrapTimeoutSeconds"
}

try {
    Assert-ExternalRuntimeHost ([bool](Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue)) "Hyper-V-Switch '$SwitchName' ist vorhanden"
    foreach ($command in @('ssh','scp','ssh-keygen','tar')) {
        Assert-ExternalRuntimeHost ([bool](Get-Command $command -ErrorAction SilentlyContinue)) "Hostbefehl '$command' ist verfuegbar"
    }

    New-Item -Path $mediaRoot,$runsRoot,$evidenceRoot,$runRoot -ItemType Directory -Force | Out-Null
    Assert-ScopedRuntimePath -Path $runRoot -Root $runsRoot
    if (-not (Test-Path -LiteralPath $archivePath -PathType Leaf)) {
        Write-Host "Lade offizielles Ubuntu-Cloud-VHD $imageRelease..." -ForegroundColor Cyan
        Start-BitsTransfer -Source $archiveUri -Destination $archivePath -DisplayName 'SQL Server Lab Ubuntu External Runtime Acceptance'
    }
    $actualArchiveSha256 = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert-ExternalRuntimeHost ($actualArchiveSha256 -eq $archiveSha256) 'Ubuntu-VHD-Archiv stimmt mit dem katalogisierten SHA-256 ueberein'
    if (-not (Test-Path -LiteralPath $baseVhdPath -PathType Leaf)) {
        & tar -xzf $archivePath -C $mediaRoot
        if ($LASTEXITCODE -ne 0) { throw 'EXTERNAL_RUNTIME_CONTAINER_HYPERV_IMAGE_EXTRACT_FAILED' }
    }
    $baseVhd = Get-VHD -Path $baseVhdPath
    Assert-ExternalRuntimeHost ($baseVhd.VhdFormat -eq 'VHD' -and $baseVhd.VhdType -eq 'Fixed' -and $baseVhd.Size -eq 32213303296) 'Ubuntu-Basis-VHD besitzt das erwartete Hyper-V-Format'

    Write-Host 'Erzeuge run-eigene dynamische OS-Disk...' -ForegroundColor Cyan
    Convert-VHD -Path $baseVhdPath -DestinationPath $osVhdPath -VHDType Dynamic
    Resize-VHD -Path $osVhdPath -SizeBytes 120GB

    & ssh-keygen -q -t ed25519 -N '' -C "sql-server-lab-$runToken" -f $privateKeyPath
    if ($LASTEXITCODE -ne 0) { throw 'EXTERNAL_RUNTIME_CONTAINER_HYPERV_SSH_KEY_FAILED' }
    $publicKey = (Get-Content -LiteralPath $publicKeyPath -Raw -Encoding utf8).Trim()
    Assert-ExternalRuntimeHost ($publicKey -match '^ssh-ed25519\s+') 'Run-eigener SSH-Schluessel wurde erzeugt'

    $bootstrapScript = @'
#!/usr/bin/env bash
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl gnupg jq git openssh-server docker.io podman
curl -fsSL https://packages.microsoft.com/config/ubuntu/22.04/packages-microsoft-prod.deb -o /tmp/packages-microsoft-prod.deb
dpkg -i /tmp/packages-microsoft-prod.deb
rm -f /tmp/packages-microsoft-prod.deb
apt-get update
ACCEPT_EULA=Y apt-get install -y powershell mssql-tools18
ln -sf /opt/mssql-tools18/bin/sqlcmd /usr/local/bin/sqlcmd
usermod -aG docker labadmin
install -d -m 0755 /var/lib/sql-server-lab
cat >/etc/default/grub.d/99-sql-server-lab-cgroup-v1.cfg <<'EOF'
GRUB_CMDLINE_LINUX_DEFAULT="systemd.unified_cgroup_hierarchy=0 systemd.legacy_systemd_cgroup_controller=false"
EOF
update-grub
cat >/usr/local/sbin/sql-server-lab-acceptance-ready <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
test "$(stat -fc %T /sys/fs/cgroup)" = tmpfs
docker info --format '{{.CgroupVersion}}' | grep -qx '1'
podman info --format json | jq -e '(.host.cgroupVersion // .host.cgroupsVersion) | tostring | test("1")' >/dev/null
command -v pwsh >/dev/null
command -v sqlcmd >/dev/null
touch /var/lib/sql-server-lab/acceptance-ready
EOF
chmod 0755 /usr/local/sbin/sql-server-lab-acceptance-ready
cat >/etc/systemd/system/sql-server-lab-acceptance-ready.service <<'EOF'
[Unit]
Description=SQL Server Lab external runtime acceptance readiness
After=network-online.target docker.service ssh.service
Wants=network-online.target docker.service ssh.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/sql-server-lab-acceptance-ready
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl enable docker.service ssh.service sql-server-lab-acceptance-ready.service
systemctl reboot
'@
    $bootstrapBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($bootstrapScript -replace "`r`n", "`n")))
    $userData = @"
#cloud-config
hostname: sql-server-lab-external-runtime
manage_etc_hosts: true
ssh_pwauth: false
users:
  - default
  - name: $sshUser
    gecos: SQL Server Lab acceptance
    groups: [adm, sudo]
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: true
    ssh_authorized_keys:
      - $publicKey
write_files:
  - path: /usr/local/sbin/sql-server-lab-bootstrap
    owner: root:root
    permissions: '0755'
    encoding: b64
    content: $bootstrapBase64
runcmd:
  - [ bash, /usr/local/sbin/sql-server-lab-bootstrap ]
"@
    $metaData = "instance-id: $runToken`nlocal-hostname: sql-server-lab-external-runtime`n"
    $seedContentPath = Join-Path $runRoot 'cidata'
    New-Item -Path $seedContentPath -ItemType Directory -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $seedContentPath 'user-data') -Value $userData -Encoding utf8NoBOM
    Set-Content -LiteralPath (Join-Path $seedContentPath 'meta-data') -Value $metaData -Encoding ascii
    New-CidataIso -SourceDirectory $seedContentPath -DestinationPath $seedIsoPath
    Assert-ExternalRuntimeHost ((Get-Item -LiteralPath $seedIsoPath).Length -gt 32768) 'NoCloud-Provisioning-ISO wurde mit exakten Vertragsdateinamen erzeugt'

    Write-Host "Erzeuge isolierte VM '$vmName'..." -ForegroundColor Cyan
    $vm = New-VM -Name $vmName -Generation 1 -MemoryStartupBytes 20GB -VHDPath $osVhdPath -SwitchName $SwitchName
    $vmCreated = $true
    Set-VM -Name $vmName -ProcessorCount 8 -DynamicMemory -MemoryMinimumBytes 8GB -MemoryStartupBytes 20GB -MemoryMaximumBytes 24GB -AutomaticStopAction ShutDown
    Set-VM -Name $vmName -AutomaticCheckpointsEnabled $false
    Set-VMComPort -VMName $vmName -Number 1 -Path $serialPipePath
    $dvd = Get-VMDvdDrive -VMName $vmName | Select-Object -First 1
    if ($dvd) { Set-VMDvdDrive -VMDvdDrive $dvd -Path $seedIsoPath }
    else { Add-VMDvdDrive -VMName $vmName -ControllerNumber 1 -ControllerLocation 0 -Path $seedIsoPath }
    Initialize-ExternalRuntimeNoCloudGuest

    $guestAddress = Wait-GuestAcceptanceReady
    Assert-ExternalRuntimeHost ($guestAddress -match '^\d{1,3}(?:\.\d{1,3}){3}$') "Linux-Gast ist unter $guestAddress bereit"
    Invoke-GuestSsh -Address $guestAddress -Command "sudo sh -c 'stat -fc %T /sys/fs/cgroup; docker info --format {{.CgroupVersion}}; podman info --format json | jq -r .host.cgroupVersion; pwsh --version; sqlcmd -?'" | Out-Host

    & git archive --format=tar.gz --output=$repoArchivePath HEAD
    if ($LASTEXITCODE -ne 0) { throw 'EXTERNAL_RUNTIME_CONTAINER_HYPERV_REPOSITORY_ARCHIVE_FAILED' }
    $scpArguments = @('-i',$privateKeyPath,'-o','StrictHostKeyChecking=no','-o',"UserKnownHostsFile=$knownHostsPath",$repoArchivePath,"$sshUser@${guestAddress}:/tmp/sql-server-lab.tar.gz")
    & scp @scpArguments
    if ($LASTEXITCODE -ne 0) { throw 'EXTERNAL_RUNTIME_CONTAINER_HYPERV_REPOSITORY_COPY_FAILED' }
    $runnerPath = Join-Path $repoRoot 'Tests/Integration/Invoke-ExternalRuntimeContainerAcceptance.ps1'
    $scpArguments[-2] = $runnerPath
    $scpArguments[-1] = "$sshUser@${guestAddress}:/tmp/Invoke-ExternalRuntimeContainerAcceptance.ps1"
    & scp @scpArguments
    if ($LASTEXITCODE -ne 0) { throw 'EXTERNAL_RUNTIME_CONTAINER_HYPERV_RUNNER_COPY_FAILED' }
    Invoke-GuestSsh -Address $guestAddress -Command "sudo mkdir -p $remoteRoot && sudo tar -xzf /tmp/sql-server-lab.tar.gz -C $remoteRoot && sudo install -m 0644 /tmp/Invoke-ExternalRuntimeContainerAcceptance.ps1 $remoteRoot/Tests/Integration/Invoke-ExternalRuntimeContainerAcceptance.ps1 && sudo chown -R root:root $remoteRoot" | Out-Host

    $evidencePaths = [Collections.Generic.List[string]]::new()
    foreach ($provider in @('docker','podman')) {
        Write-Host "Starte native $provider-External-Runtime-Abnahme..." -ForegroundColor Cyan
        $remoteEvidence = "/var/tmp/external-runtime-$SqlVersion-$provider-evidence.json"
        $keepGuestResources = if ($KeepOnFailure) { ' -KeepOnFailure' } else { '' }
        Invoke-GuestSsh -Address $guestAddress -Command "cd $remoteRoot && sudo pwsh -NoProfile -File ./Tests/Integration/Invoke-ExternalRuntimeContainerAcceptance.ps1 -Provider $provider -SqlVersion $SqlVersion -EvidencePath $remoteEvidence$keepGuestResources" | Out-Host
        $localEvidence = Join-Path $evidenceRoot "external-runtime-$SqlVersion-$provider-$runToken.json"
        $scpArguments[-2] = "$sshUser@${guestAddress}:$remoteEvidence"
        $scpArguments[-1] = $localEvidence
        & scp @scpArguments
        if ($LASTEXITCODE -ne 0) { throw "EXTERNAL_RUNTIME_CONTAINER_HYPERV_EVIDENCE_COPY_FAILED: $provider" }
        $evidence = Get-Content -LiteralPath $localEvidence -Raw -Encoding utf8 | ConvertFrom-Json -Depth 100
        Assert-ExternalRuntimeHost ([string]$evidence.status -eq 'PASS' -and [string]$evidence.provider -eq $provider -and [string]$evidence.cgroupVersion -eq '1') "$provider-Evidence ist vollstaendig und positiv"
        $evidencePaths.Add($localEvidence)
    }

    $completed = $true
    [PSCustomObject]@{
        Status = 'PASS'
        VmName = $vmName
        GuestAddress = $guestAddress
        ImageRelease = $imageRelease
        ImageSha256 = $archiveSha256
        Providers = @('docker','podman')
        SqlVersion = $SqlVersion
        EvidencePaths = @($evidencePaths)
    }
}
finally {
    if ($vmCreated -and ($completed -or -not $KeepOnFailure)) {
        try {
            $vm = Get-VM -Name $vmName -ErrorAction SilentlyContinue
            if ($vm) {
                if ($vm.State -ne 'Off') { Stop-VM -Name $vmName -TurnOff -Force -Confirm:$false }
                Remove-VM -Name $vmName -Force -Confirm:$false
            }
        }
        catch { Write-Warning "VM-Cleanup schlug fehl: $($_.Exception.Message)" }
    }
    if (($completed -or -not $KeepOnFailure) -and (Test-Path -LiteralPath $runRoot)) {
        try {
            Assert-ScopedRuntimePath -Path $runRoot -Root $runsRoot
            Remove-Item -LiteralPath $runRoot -Recurse -Force
        }
        catch { Write-Warning "Run-Verzeichnis-Cleanup schlug fehl: $($_.Exception.Message)" }
    }
    if (-not $completed -and $KeepOnFailure) {
        Write-Warning "Diagnose-Ressourcen bleiben erhalten: VM=$vmName RunRoot=$runRoot"
    }
    if ($transcriptStarted) {
        try { Stop-Transcript | Out-Null } catch { }
    }
}
