#Requires -Version 7.2
<#
.SYNOPSIS
    Richtet einen eigenen Linux-Containerhost fuer SQL External Languages ein.
.DESCRIPTION
    Plan ist read-only. Create erzeugt eine persistente Ubuntu-22.04-Hyper-V-VM
    unter registriertem Lab_Data, mit cgroup v1, rootful Docker und Podman,
    PowerShell, sqlcmd und einem Snapshot der versionierten Repositorydateien.
    Bestehende Desktop-Runtimes werden nicht geaendert. Kein Remote-Docker-Socket.
    Fehler behalten das Journal und eigene Ressourcen zur gezielten Recovery.
.PARAMETER Action
    Plan, Create, Status, Start, Stop, Remove, Connect, SyncRepository oder Test. Test fuehrt
    die bestehende SQL-2025-Sprachabnahme im Gast fuer den gewaehlten Provider aus.
.PARAMETER HostId
    Stabile ID aus Create; fuer alle Aktionen ausser Plan/Create erforderlich.
.PARAMETER DataRoot
    Registrierter Lab_Data-Root. Standard ist die konfigurierte Ablage.
.PARAMETER MediaRoot
    Mediencache. Standard ist der konfigurierte Lab_Base-Root.
.PARAMETER SwitchName
    Vorhandener interner Hyper-V-Switch mit DHCP und Internetzugang.
.PARAMETER Provider
    Provider fuer Test. Beide Provider werden im Gast installiert.
.PARAMETER MemoryMB
    Statischer VM-Speicher; CPU- und Speichernutzung bleibt auf diese VM begrenzt.
.PARAMETER ProcessorCount
    Virtuelle Prozessoren fuer die eigene VM.
.PARAMETER BootstrapTimeoutSeconds
    Frist fuer den Gastbootstrap einschliesslich cgroup-Neustart.
.EXAMPLE
    ./Tools/Invoke-SqlServerLabLinuxContainerHost.ps1 -Action Plan
.EXAMPLE
    ./Tools/Invoke-SqlServerLabLinuxContainerHost.ps1 -Action Create
.EXAMPLE
    ./Tools/Invoke-SqlServerLabLinuxContainerHost.ps1 -Action Test -HostId '<id>' -Provider docker
.OUTPUTS
    Lokaler Hostzustand. Enthaelt lokale Verbindungspfade, aber keine Secrets.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact='Medium')]
param(
    [ValidateSet('Plan','Create','Status','Start','Stop','Remove','Connect','SyncRepository','Test')][string]$Action='Plan',
    [string]$HostId,
    [string]$DataRoot,
    [string]$MediaRoot,
    [string]$SwitchName='Default Switch',
    [ValidateSet('docker','podman')][string]$Provider='docker',
    [ValidateRange(8192,32768)][int]$MemoryMB=16384,
    [ValidateRange(2,16)][int]$ProcessorCount=8,
    [ValidateRange(600,7200)][int]$BootstrapTimeoutSeconds=3600
)
$ErrorActionPreference='Stop'
$repoRoot=Split-Path $PSScriptRoot -Parent
$module=Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -PassThru -WarningAction SilentlyContinue
. (Join-Path $PSScriptRoot 'Common/LinuxContainerHostBootstrap.ps1')
. (Join-Path $PSScriptRoot 'Common/LinuxContainerHostContract.ps1')
$DataRoot=& $module {param($root) Resolve-LabDataRootForUse -DataRoot $root} $DataRoot
if (-not $MediaRoot) { $MediaRoot=& $module {Get-LabMediaRootDefault} }
if (-not $MediaRoot) { throw 'LINUX_HOST_MEDIA_ROOT_REQUIRED' }
$hostsRoot=Join-Path $DataRoot 'LinuxContainerHosts'
$release='20260807'
$archiveName='ubuntu-22.04-server-cloudimg-amd64-azure.vhd.tar.gz'
$archiveHash='ed465d19bd73d1840a3b04edc895359ef5a631731fc8872a52c2409f3237f770'
$archiveUri="https://cloud-images.ubuntu.com/releases/jammy/release-$release/$archiveName"
$mediaCache=Join-Path $MediaRoot "Linux/ContainerHost/ubuntu-$release"
$archivePath=Join-Path $mediaCache $archiveName
if ($Action -eq 'Plan') {
    [pscustomobject]@{Contract='SqlServerLab.LinuxContainerHost/1.0';Action='Create';DataRoot=$DataRoot;
        MediaRoot=$mediaCache;SwitchName=$SwitchName;MemoryMB=$MemoryMB;ProcessorCount=$ProcessorCount;
        DiskGB=160;Providers=@('docker','podman');CgroupVersion='1';RequiresElevation=$true;
        HostBackend='HyperV';RequiresHyperV=$true;HyperVCmdletsAvailable=($IsWindows -and [bool](Get-Command Get-VM -ErrorAction SilentlyContinue));
        Source=$archiveUri;SourceSha256=$archiveHash;Retention='Explicit Remove only';
        Effects='Own Hyper-V VM; guest package downloads; no Desktop runtime changes'}
    return
}
if ($Action -ne 'Create') { Assert-LinuxContainerHostId $HostId }
elseif ($HostId) { throw 'LINUX_HOST_CREATE_ID_IS_GENERATED' }
if (-not $IsWindows) { throw 'LINUX_HOST_WINDOWS_REQUIRED' }
if (-not (Get-Command Get-VM -ErrorAction SilentlyContinue)) { throw 'LINUX_HOST_HYPERV_REQUIRED: Automatic VM provisioning requires Hyper-V; no alternative VM backend is selected.' }
if ($Action -notin @('Status','Connect','Test') -and -not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'LINUX_HOST_ELEVATION_REQUIRED: Run this command from elevated PowerShell.'
}
if ($Action -eq 'Create') { $HostId=[guid]::NewGuid().ToString() }
$runRoot=Join-Path $hostsRoot $HostId
Assert-ScopedRuntimePath -Path $runRoot -Root $hostsRoot
Assert-LinuxContainerHostPath -Path $runRoot -Root $DataRoot
$statePath=Join-Path $runRoot 'host.json'
$lock=$null
if ($Action -eq 'Create') {
    if (-not $PSCmdlet.ShouldProcess('New isolated Linux container host','Create VM and install Docker/Podman')) { return }
    New-Item -ItemType Directory -Path $runRoot -ErrorAction Stop | Out-Null
    $acl=[Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true,$false)
    foreach($sid in @([Security.Principal.WindowsIdentity]::GetCurrent().User,
        [Security.Principal.SecurityIdentifier]::new('S-1-5-18'),[Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))) {
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid,'FullControl','ContainerInherit,ObjectInherit','None','Allow'))
    }
    Set-Acl -LiteralPath $runRoot -AclObject $acl
}
elseif (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) { throw 'LINUX_HOST_STATE_NOT_FOUND' }
try {
    $lock=[IO.File]::Open((Join-Path $runRoot 'operation.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    $state=if ($Action -eq 'Create') {
        [pscustomobject]@{Contract='SqlServerLab.LinuxContainerHost/1.0';HostId=$HostId;Status='PREPARING';
            VmId=$null;VmName="SQLLAB-LINUX-$($HostId.Substring(0,8))";Disk='os.vhdx';
            Address=$null;CreatedAt=[DateTime]::UtcNow.ToString('o');RepositoryCommit=$null;
            CgroupVersion=$null;DockerReady=$false;PodmanReady=$false;FailureCode=$null}
    } else { Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json }
    Assert-LinuxContainerHostState -State $state -HostId $HostId
    $vmName=[string]$state.VmName
    $serialPipeName="sqllab-linux-$HostId"
    $serialPipePath="\\.\pipe\$serialPipeName"
    $osVhdPath=Join-Path $runRoot 'os.vhdx'
    $seedIsoPath=Join-Path $runRoot 'cidata.iso'
    $privateKeyPath=Join-Path $runRoot 'client_ed25519'
    $knownHostsPath=Join-Path $runRoot 'known_hosts'
    $sshUser='labadmin'
    $sshArguments=@('-i',$privateKeyPath,'-o','BatchMode=yes','-o','StrictHostKeyChecking=yes',
        '-o',"UserKnownHostsFile=$knownHostsPath",'-o',"HostKeyAlias=sqllab-$HostId",'-o','ConnectTimeout=8',
        '-o','ServerAliveInterval=10','-o','ServerAliveCountMax=3')
    function Save-HostState {
        $temp="$statePath.tmp"
        $state|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $temp -Encoding utf8
        [IO.File]::Move($temp,$statePath,$true)
    }
    function Get-OwnedVm {
        if (-not $state.VmId) { throw 'LINUX_HOST_VM_ID_MISSING' }
        $vm=Get-VM -Id ([guid]$state.VmId) -ErrorAction Stop
        Assert-LinuxContainerHostVm -State $state -Vm $vm -DiskPath $osVhdPath `
            -DiskPaths @(Get-VMHardDiskDrive -VM $vm | ForEach-Object { $_.Path })
        return $vm
    }
    function Invoke-HostSsh {
        param([string]$Command,[int]$TimeoutSeconds=60)
        Invoke-LinuxContainerHostNative -Executable 'ssh' -Arguments @($sshArguments + @("${sshUser}@$($state.Address)",$Command)) -TimeoutSeconds $TimeoutSeconds
    }
    function Sync-HostRepository {
        $archive=Join-Path $runRoot 'repository.tar.gz'
        $commit=Invoke-LinuxContainerHostNative -Executable git -Arguments @('-C',$repoRoot,'rev-parse','HEAD')
        if ($commit.ExitCode -ne 0) {throw 'LINUX_HOST_REPOSITORY_COMMIT_FAILED'}
        Assert-LinuxContainerHostRevision -InstalledCommit $state.RepositoryCommit -RequestedCommit $commit.Output.Trim()
        $state.Status='BOOTSTRAP_READY';Save-HostState
        $result=Invoke-LinuxContainerHostNative -Executable git -Arguments @('-C',$repoRoot,'archive','--format=tar.gz',"--output=$archive",'HEAD') -TimeoutSeconds 120
        if ($result.ExitCode -ne 0) {throw 'LINUX_HOST_REPOSITORY_ARCHIVE_FAILED'}
        $result=Invoke-LinuxContainerHostNative -Executable scp -Arguments @($sshArguments + @($archive,"${sshUser}@$($state.Address):/tmp/sql-server-lab.tar.gz")) -TimeoutSeconds 120
        if ($result.ExitCode -ne 0) {throw 'LINUX_HOST_REPOSITORY_TRANSFER_FAILED'}
        $hash=(Get-FileHash -LiteralPath $archive).Hash.ToLowerInvariant()
        $result=Invoke-HostSsh -Command "echo '$hash  /tmp/sql-server-lab.tar.gz' | sha256sum -c - && sudo mkdir -p /opt/sql-server-lab && sudo tar -xzf /tmp/sql-server-lab.tar.gz -C /opt/sql-server-lab && sudo chown -R root:root /opt/sql-server-lab && rm /tmp/sql-server-lab.tar.gz" -TimeoutSeconds 120
        if ($result.ExitCode -ne 0) {throw 'LINUX_HOST_REPOSITORY_INSTALL_FAILED'}
        $configure=@'
$ErrorActionPreference='Stop'
if(-not $IsLinux){throw 'LINUX_HOST_GUEST_OS_INVALID'}
$module=Import-Module /opt/sql-server-lab/SqlServerLab.psd1 -PassThru
& $module {
    $data=Get-LabDataRootDefault
    if(-not $data){$data=(Set-LabDataLocation -LabDataRoot /var/lib/sql-server-lab/Lab_Data -SetDefault -Confirm:$false).LabDataRoot}
    $media=Get-LabMediaRootDefault
    if(-not $media){New-Item -ItemType Directory -Path /var/lib/sql-server-lab/Lab_Base -Force|Out-Null;$media=Set-LabMediaRootDefault -MediaRoot /var/lib/sql-server-lab/Lab_Base}
    # Linux has no persistent User environment target. Keep a repository-local
    # bootstrap pointer, using the existing atomic preferences writer.
    $previousData=$env:SQL_SERVER_LAB_DATA_ROOT
    try {
        $env:SQL_SERVER_LAB_DATA_ROOT=$null
        Set-LabProjectPreferenceValue -Name dataRoot -Value $data
        Set-LabProjectPreferenceValue -Name mediaRoot -Value $media
    } finally {$env:SQL_SERVER_LAB_DATA_ROOT=$previousData}
}
foreach($provider in @('docker','podman')) {
    $ready=& /opt/sql-server-lab/Tools/Test-SqlServerLabClientReadiness.ps1 -Provider $provider -Operation Create
    if($ready.Status -notin @('READY','READY_WITH_WARNINGS') -or @($ready.MissingPrerequisites).Count -ne 0){throw "LINUX_HOST_GUEST_CREATE_NOT_READY: $provider"}
}
'@
        $encodedConfigure=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($configure))
        $result=Invoke-HostSsh -Command "sudo env TEMP=/tmp pwsh -NoProfile -EncodedCommand $encodedConfigure" -TimeoutSeconds 120
        if($result.ExitCode -ne 0){$result.Error|Set-Content -LiteralPath (Join-Path $runRoot 'guest-configuration.stderr.log');throw 'LINUX_HOST_GUEST_CONFIGURATION_FAILED'}
        Get-VMDvdDrive -VM (Get-OwnedVm)|Set-VMDvdDrive -Path $null
        $state.RepositoryCommit=$commit.Output.Trim();$state.Status='READY';$state.FailureCode=$null;Save-HostState
    }
    function Wait-OwnedGuest {
        $deadline=[DateTime]::UtcNow.AddSeconds($BootstrapTimeoutSeconds)
        while ([DateTime]::UtcNow -lt $deadline) {
            $vm=Get-OwnedVm
            if ($vm.DynamicMemoryEnabled) {throw 'LINUX_HOST_STATIC_MEMORY_REQUIRED'}
            $addresses=@(Get-VMNetworkAdapter -VM $vm | ForEach-Object IPAddresses | Where-Object {$_ -match '^\d{1,3}(\.\d{1,3}){3}$' -and $_ -notmatch '^169\.254\.'})
            foreach ($address in $addresses) {
                $state.Address=$address
                $check=Invoke-HostSsh -Command 'sudo /usr/local/sbin/sql-server-lab-host-ready' -TimeoutSeconds 20
                if ($check.ExitCode -eq 0) {
                    $state.CgroupVersion='1';$state.DockerReady=$true;$state.PodmanReady=$true
                    Save-HostState
                    return
                }
            }
            Write-Host 'Waiting for owned Linux guest and both cgroup-v1 providers...'
            Start-Sleep -Seconds 10
        }
        throw 'LINUX_HOST_BOOTSTRAP_TIMEOUT'
    }
    if ($Action -eq 'Status') {
        if ($state.Status -ne 'REMOVED' -and $state.VmId) { $vm=Get-OwnedVm; $state|Add-Member RuntimeState ([string]$vm.State) -Force }
        $state
        return
    }
    if ($Action -eq 'Remove') {
        if ($state.Status -eq 'REMOVED') { $state;return }
        if (-not $PSCmdlet.ShouldProcess($HostId,'Permanently delete owned VM and all guest labs/data')) { return }
        if ($state.VmId) {
            $vm=Get-VM -Id ([guid]$state.VmId) -ErrorAction SilentlyContinue
            if ($vm) { $vm=Get-OwnedVm; if ($vm.State -ne 'Off') {Stop-VM -VM $vm -TurnOff -Force -Confirm:$false};Remove-VM -VM $vm -Force -Confirm:$false }
        } elseif (Get-VM -Name $vmName -ErrorAction SilentlyContinue) { throw 'LINUX_HOST_UNBOUND_VM_REQUIRES_REVIEW' }
        $state.Status='REMOVING';Save-HostState
        foreach ($item in @(Get-ChildItem -LiteralPath $runRoot -Force | Where-Object Name -notin @('host.json','operation.lock'))) {
            Assert-LinuxContainerHostPath -Path $item.FullName -Root $runRoot
            if (@(Get-ChildItem -LiteralPath $item.FullName -Recurse -Force -ErrorAction Stop | Where-Object {$_.Attributes -band [IO.FileAttributes]::ReparsePoint}).Count) {throw 'LINUX_HOST_REPARSE_POINT_REJECTED'}
            Remove-Item -LiteralPath $item.FullName -Recurse -Force
        }
        $state.Status='REMOVED';$state.Address=$null;Save-HostState;$state;return
    }
    if ($Action -ne 'Create') {
        $vm=Get-OwnedVm
        if ($Action -eq 'Stop') {
            if ($PSCmdlet.ShouldProcess($HostId,'Shut down Linux host and all guest labs')) {Stop-VM -VM $vm -Confirm:$false;$state.Status='STOPPED';Save-HostState}
            $state;return
        }
        if ($Action -eq 'Start') {
            if (-not $PSCmdlet.ShouldProcess($HostId,'Start Linux host')) {return}
            if ($vm.State -eq 'Off') {Start-VM -VM $vm|Out-Null}
            Wait-OwnedGuest;$state.Status=if($state.RepositoryCommit){'READY'}else{'BOOTSTRAP_READY'};Save-HostState;$state;return
        }
        if ($Action -eq 'SyncRepository') {
            if (-not $PSCmdlet.ShouldProcess($HostId,'Install committed repository snapshot in guest')) {return}
            if ($vm.State -ne 'Running') {throw 'LINUX_HOST_NOT_RUNNING'}
            Wait-OwnedGuest;Sync-HostRepository;$state;return
        }
        if ($vm.State -ne 'Running' -or $state.Status -ne 'READY') {throw 'LINUX_HOST_NOT_READY'}
        if ($Action -eq 'Test' -and -not $PSCmdlet.ShouldProcess($HostId,"Run isolated SQL-2025 $Provider language acceptance")) {return}
        if ($Action -eq 'Connect' -and -not $PSCmdlet.ShouldProcess($HostId,'Open interactive SSH session')) {return}
        Wait-OwnedGuest
        # The retained core's Docker availability probe expects TEMP on Linux.
        # Supply it only to the launched guest PowerShell process.
        if ($Action -eq 'Connect') { & ssh @sshArguments -t "${sshUser}@$($state.Address)" 'cd /opt/sql-server-lab && sudo env TEMP=/tmp pwsh -NoLogo';return }
        if ($Action -eq 'Test') {
            $harness=Join-Path $repoRoot 'Tests/Integration/Invoke-LinuxContainerHostAcceptance.ps1'
            $harnessHash=(Get-FileHash -LiteralPath $harness).Hash.ToLowerInvariant()
            $remoteDirectory="/home/labadmin/.sql-lab-host-tests/$([guid]::NewGuid().ToString('N'))"
            $remoteHarness="$remoteDirectory/acceptance.ps1"
            $prepare=Invoke-HostSsh -Command "mkdir -p -m 700 '$remoteDirectory'"
            if($prepare.ExitCode -ne 0){throw 'LINUX_HOST_TEST_DIRECTORY_FAILED'}
            try {
                $transfer=Invoke-LinuxContainerHostNative -Executable scp -Arguments @($sshArguments+@($harness,"${sshUser}@$($state.Address):$remoteHarness")) -TimeoutSeconds 60
                if($transfer.ExitCode -ne 0){throw 'LINUX_HOST_TEST_TRANSFER_FAILED'}
                $test=Invoke-HostSsh -TimeoutSeconds 14400 -Command "echo '$harnessHash  $remoteHarness' | sha256sum -c - && sudo env TEMP=/tmp pwsh -NoProfile -File '$remoteHarness' -RepositoryRoot /opt/sql-server-lab -Provider $Provider -EvidencePath /var/lib/sql-server-lab/$Provider-evidence.json"
            } finally {
                $null=Invoke-HostSsh -Command "rm -f -- '$remoteHarness' && rmdir -- '$remoteDirectory'"
            }
            $test.Output|Set-Content -LiteralPath (Join-Path $runRoot "$Provider-test.log")
            $test.Error|Set-Content -LiteralPath (Join-Path $runRoot "$Provider-test.stderr.log")
            if ($test.ExitCode -ne 0) {throw "LINUX_HOST_PROVIDER_ACCEPTANCE_FAILED: $Provider"}
            $receipt=Invoke-HostSsh -Command "sudo cat /var/lib/sql-server-lab/$Provider-evidence.json"
            if ($receipt.ExitCode -ne 0) {throw 'LINUX_HOST_EVIDENCE_READ_FAILED'}
            $evidence=$receipt.Output|ConvertFrom-Json
            if ($evidence.contract -ne 'SqlServerLab.LinuxContainerHostAcceptance/1.0' -or $evidence.status -ne 'PASS' -or $evidence.provider -ne $Provider -or $evidence.cgroupVersion -ne '1' -or $evidence.cleanup -ne 'REMOVED') {throw 'LINUX_HOST_EVIDENCE_INVALID'}
            $receipt.Output|Set-Content -LiteralPath (Join-Path $runRoot "$Provider-evidence.json")
            [pscustomobject]@{HostId=$HostId;Provider=$Provider;Status='PASS';SqlVersion='2025'};return
        }
    }
    Save-HostState
    $switch=Get-VMSwitch -Name $SwitchName -ErrorAction Stop
    if ($switch.SwitchType -ne 'Internal') {throw 'LINUX_HOST_INTERNAL_SWITCH_REQUIRED'}
    foreach ($command in @('ssh','scp','ssh-keygen','tar','git')) {if (-not (Get-Command $command -ErrorAction SilentlyContinue)){throw "LINUX_HOST_TOOL_MISSING: $command"}}
    $freeMB=[math]::Floor((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory/1024)
    if ($freeMB -lt ($MemoryMB+2048)) {throw 'LINUX_HOST_INSUFFICIENT_MEMORY'}
    if ((Get-Item $DataRoot).PSDrive.Free -lt 40GB) {throw 'LINUX_HOST_INSUFFICIENT_DISK'}
    New-Item -ItemType Directory -Path $mediaCache -Force|Out-Null
    if (-not (Test-Path -LiteralPath $archivePath)) {
        Invoke-WebRequest -Uri $archiveUri -OutFile "$archivePath.partial" -TimeoutSec 1800
        if ((Get-FileHash "$archivePath.partial").Hash.ToLowerInvariant() -ne $archiveHash) {throw 'LINUX_HOST_IMAGE_HASH_MISMATCH'}
        Move-Item -LiteralPath "$archivePath.partial" -Destination $archivePath
    }
    if ((Get-FileHash -LiteralPath $archivePath).Hash.ToLowerInvariant() -ne $archiveHash) {throw 'LINUX_HOST_IMAGE_HASH_MISMATCH'}
    $extract=Join-Path $runRoot 'image';New-Item -ItemType Directory -Path $extract|Out-Null
    $result=Invoke-LinuxContainerHostNative -Executable tar -Arguments @('-xzf',$archivePath,'-C',$extract) -TimeoutSeconds 300
    if ($result.ExitCode -ne 0) {throw 'LINUX_HOST_IMAGE_EXTRACT_FAILED'}
    $baseVhdPath=Join-Path $extract 'livecd.ubuntu-cpc.azure.vhd'
    $base=Get-VHD -Path $baseVhdPath
    if ($base.VhdFormat -ne 'VHD' -or $base.Size -ne 32213303296) {throw 'LINUX_HOST_IMAGE_LAYOUT_MISMATCH'}
    Convert-VHD -Path $baseVhdPath -DestinationPath $osVhdPath -VHDType Dynamic
    Resize-VHD -Path $osVhdPath -SizeBytes 160GB
    Remove-Item -LiteralPath $baseVhdPath -Force
    foreach ($keyPath in @($privateKeyPath,(Join-Path $runRoot 'host_ed25519'))) {
        $result=Invoke-LinuxContainerHostNative -Executable ssh-keygen -Arguments @('-q','-t','ed25519','-N','','-f',$keyPath) -TimeoutSeconds 30
        if ($result.ExitCode -ne 0) {throw 'LINUX_HOST_KEY_GENERATION_FAILED'}
    }
    $publicKey=(Get-Content "$privateKeyPath.pub" -Raw).Trim()
    $hostPublic=(Get-Content (Join-Path $runRoot 'host_ed25519.pub') -Raw).Trim()
    "sqllab-$HostId $hostPublic"|Set-Content -LiteralPath $knownHostsPath -Encoding ascii
    $hostPrivate=((Get-Content (Join-Path $runRoot 'host_ed25519') | ForEach-Object {"    $_"}) -join "`n")
    $bootstrap=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Common/linux-container-host-bootstrap.sh')) -replace "`r`n","`n"
    $encoded=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($bootstrap))
    $seedContentPath=Join-Path $runRoot 'cidata';New-Item -ItemType Directory -Path $seedContentPath|Out-Null
    @"
#cloud-config
hostname: sql-lab-linux
manage_etc_hosts: true
ssh_pwauth: false
ssh_keys:
  ed25519_private: |
$hostPrivate
  ed25519_public: $hostPublic
users:
  - name: labadmin
    groups: [adm, sudo]
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: true
    ssh_authorized_keys:
      - $publicKey
write_files:
  - path: /usr/local/sbin/sql-server-lab-bootstrap
    permissions: '0700'
    encoding: b64
    content: $encoded
runcmd:
  - [ bash, /usr/local/sbin/sql-server-lab-bootstrap ]
"@|Set-Content -LiteralPath (Join-Path $seedContentPath 'user-data') -Encoding utf8NoBOM
    "instance-id: $HostId`nlocal-hostname: sql-lab-linux"|Set-Content -LiteralPath (Join-Path $seedContentPath 'meta-data') -Encoding ascii
    New-CidataIso -SourceDirectory $seedContentPath -DestinationPath $seedIsoPath
    $vm=New-VM -Name $vmName -Generation 1 -MemoryStartupBytes ($MemoryMB*1MB) -VHDPath $osVhdPath -SwitchName $SwitchName -Path $runRoot
    $state.VmId=[string]$vm.Id;Save-HostState
    Set-VM -VM $vm -Notes "SqlServerLab.LinuxContainerHost/1.0:$HostId" -ProcessorCount $ProcessorCount -AutomaticCheckpointsEnabled $false -AutomaticStartAction Nothing -AutomaticStopAction ShutDown
    Set-VMMemory -VM $vm -DynamicMemoryEnabled $false -StartupBytes ($MemoryMB*1MB)
    Set-VMComPort -VM $vm -Number 1 -Path $serialPipePath
    Add-VMDvdDrive -VM $vm -Path $seedIsoPath
    Initialize-ExternalRuntimeNoCloudGuest
    Wait-OwnedGuest
    Sync-HostRepository
    # NoCloud keys remain only on the owned disk; detach the seed after bootstrap.
    Get-VMDvdDrive -VM (Get-OwnedVm)|Set-VMDvdDrive -Path $null
    $state
} catch {
    if ($state -and $Action -eq 'Create') {$state.Status='RECOVERY_REQUIRED';$state.FailureCode='LINUX_HOST_CREATE_FAILED';Save-HostState;Write-Warning "Retained owned host for recovery: $HostId"}
    throw
} finally {if ($lock){$lock.Dispose()}}
