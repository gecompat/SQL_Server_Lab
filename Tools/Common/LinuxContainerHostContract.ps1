function Assert-LinuxContainerHostId {
    param([string]$HostId)
    if ($HostId -cnotmatch '^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$') {throw 'LINUX_HOST_ID_INVALID'}
}
function Assert-LinuxContainerHostState {
    param($State,[string]$HostId)
    Assert-LinuxContainerHostId $HostId
    if ($State.Contract -cne 'SqlServerLab.LinuxContainerHost/1.0' -or $State.HostId -cne $HostId -or
        $State.Disk -cne 'os.vhdx' -or $State.VmName -cne "SQLLAB-LINUX-$($HostId.Substring(0,8))" -or
        $State.Status -notin @('PREPARING','BOOTSTRAP_READY','READY','STOPPED','RECOVERY_REQUIRED','REMOVING','REMOVED')) {throw 'LINUX_HOST_STATE_INVALID'}
}
function Assert-LinuxContainerHostRevision {
    param([string]$InstalledCommit,[string]$RequestedCommit)
    if ($RequestedCommit -cnotmatch '^[a-f0-9]{40}$') {throw 'LINUX_HOST_REPOSITORY_COMMIT_INVALID'}
    if ($InstalledCommit -and $InstalledCommit -cne $RequestedCommit) {
        throw 'LINUX_HOST_REPOSITORY_REVISION_MISMATCH: This host retains its original repository snapshot; create a new host for another revision.'
    }
}
function Assert-LinuxContainerHostPath {
    param([string]$Path,[string]$Root)
    $fullRoot=[IO.Path]::GetFullPath($Root).TrimEnd('\','/')
    $fullPath=[IO.Path]::GetFullPath($Path)
    if (-not $fullPath.StartsWith($fullRoot+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) {throw 'LINUX_HOST_PATH_ESCAPE'}
    $current=$fullPath
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            if ((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {throw 'LINUX_HOST_REPARSE_POINT_REJECTED'}
        }
        $parent=Split-Path $current -Parent
        if ($parent -eq $current) {break}
        $current=$parent
    }
}
function Assert-LinuxContainerHostVm {
    param($State,$Vm,[string]$DiskPath,[string[]]$DiskPaths)
    if ([string]$Vm.Id -cne [string]$State.VmId -or $Vm.Name -cne $State.VmName -or
        $Vm.Notes -cne "SqlServerLab.LinuxContainerHost/1.0:$($State.HostId)" -or
        $DiskPaths.Count -ne 1 -or [IO.Path]::GetFullPath($DiskPaths[0]) -ine [IO.Path]::GetFullPath($DiskPath)) {throw 'LINUX_HOST_VM_BINDING_MISMATCH'}
}
function Invoke-LinuxContainerHostNative {
    param([string]$Executable,[string[]]$Arguments,[int]$TimeoutSeconds=60)
    $info=[Diagnostics.ProcessStartInfo]::new()
    $info.FileName=(Get-Command $Executable -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    $info.UseShellExecute=$false;$info.CreateNoWindow=$true
    $info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    foreach($argument in $Arguments){$info.ArgumentList.Add($argument)}
    $process=[Diagnostics.Process]::new();$process.StartInfo=$info
    try {
        $null=$process.Start();$stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds*1000)) {$process.Kill($true);$process.WaitForExit();throw 'LINUX_HOST_NATIVE_TIMEOUT'}
        [pscustomobject]@{ExitCode=$process.ExitCode;Output=$stdout.GetAwaiter().GetResult();Error=$stderr.GetAwaiter().GetResult()}
    } finally {$process.Dispose()}
}
