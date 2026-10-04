# Host cache maintenance is separate from the run's STOPPED postcondition.
# Never terminate a distribution, stop another container, or change WSL settings.
function Get-LabStopHostMemory {
    if (-not $IsWindows) { return $null }
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    return [pscustomobject]@{ TotalMB=[long]($os.TotalVisibleMemorySize / 1024); AvailableMB=[long]($os.FreePhysicalMemory / 1024) }
}

function Invoke-LabStopMemoryCommand {
    param([string]$Invocation, [string[]]$Arguments)
    $result = Invoke-LabProgressNativeCommand -FilePath $Invocation -ArgumentList $Arguments -Phase Cleanup -TimeoutSeconds 20
    if ($result.ExitCode -ne 0) { throw 'STOP_MEMORY_COMMAND_FAILED' }
    return ((@($result.Output) -join "`n") -replace "`0", '')
}

function Get-LabStopMemoryTarget {
    param([ValidateSet('docker','podman')][string]$Provider)
    # Overrides may select an endpoint other than the inspected default.
    foreach ($name in @('DOCKER_HOST','DOCKER_CONTEXT','CONTAINER_HOST','CONTAINER_CONNECTION')) {
        if ([Environment]::GetEnvironmentVariable($name)) { return $null }
    }
    $invocation = Get-LabHostToolInvocation -Name $Provider
    $evidence = [pscustomobject]@{Provider=$Provider; Available=$true; HostPlatform='windows'; Info=$null; Contexts=@(); Machines=@(); Connections=@()}
    if ($Provider -eq 'docker') {
        $evidence.Contexts = @(Invoke-LabStopMemoryCommand $invocation @('context','inspect') | ConvertFrom-Json)
        $evidence.Info = Invoke-LabStopMemoryCommand $invocation @('info','--format','{{json .}}') | ConvertFrom-Json
    }
    else {
        $evidence.Info = Invoke-LabStopMemoryCommand $invocation @('info','--format','json') | ConvertFrom-Json
        $evidence.Machines = @(Invoke-LabStopMemoryCommand $invocation @('machine','list','--format','json') | ConvertFrom-Json)
        $evidence.Connections = @(Invoke-LabStopMemoryCommand $invocation @('system','connection','list','--format','json') | ConvertFrom-Json)
    }
    $scope = ConvertTo-LabContainerRuntimeScope -Evidence $evidence
    if ($scope.Status -ne 'AVAILABLE') { return $null }
    $distribution = $null
    if ($Provider -eq 'docker' -and $scope.Binding.BackendKind -eq 'DOCKER_DESKTOP' -and
        $scope.Binding.EndpointKind -eq 'LOCAL_NPIPE' -and $evidence.Info.KernelVersion -match '(?i)microsoft.*wsl2') {
        $distribution = 'docker-desktop'
    }
    elseif ($Provider -eq 'podman' -and $scope.Binding.BackendKind -eq 'PODMAN_MACHINE' -and
        $scope.Binding.HostMode -eq 'WINDOWS_WSL2' -and $scope.Binding.EndpointKind -eq 'LOCAL_MACHINE_SSH' -and
        $scope.Binding.MachineState -eq 'RUNNING') {
        $distribution = [string]$scope.Binding.MachineName
    }
    if (-not $distribution -or $distribution -notmatch '^[a-zA-Z0-9][a-zA-Z0-9_.-]*$') { return $null }
    $wsl = (Get-Command wsl.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    $running = (Invoke-LabStopMemoryCommand $wsl @('--list','--running','--quiet')) -split '\r?\n' | ForEach-Object { $_.Trim() }
    if ($distribution -cnotin $running) { return $null }
    return [pscustomobject]@{Invocation=$wsl; Distribution=$distribution; RuntimeId=$scope.RuntimeId}
}

function Get-LabStopLinuxCacheMB {
    param([string]$MemInfo)
    $values = @{}
    foreach ($line in ($MemInfo -split '\r?\n')) {
        if ($line -match '^(Cached|Buffers|Shmem):\s+(\d+) kB\s*$') { $values[$Matches[1]]=[long]$Matches[2] }
    }
    foreach ($key in @('Cached','Buffers','Shmem')) { if (-not $values.ContainsKey($key)) { throw 'STOP_MEMORY_INVALID_MEMINFO' } }
    return [long]([math]::Max(0, $values.Cached + $values.Buffers - $values.Shmem) / 1024)
}

function Invoke-LabStoppedHostMemoryRelease {
    [CmdletBinding()]
    param([string[]]$Provider, [switch]$Skip)
    $ErrorActionPreference='Stop'
    $receipt = [pscustomobject][ordered]@{
        Status='NOT_APPLICABLE'; AvailableBeforeMB=$null; AvailableAfterMB=$null
        CacheBeforeMB=$null; CacheAfterMB=$null; CacheReleaseRequested=$false
    }
    if ($Skip) { $receipt.Status='DISABLED'; return $receipt }
    # Shared WSL maintenance is applicable only to an exclusively container-bound set.
    # Reject non-container/unknown providers before host reads or backend selection.
    if (@($Provider).Count -eq 0 -or @($Provider | Where-Object { $_ -notin @('docker','podman') }).Count) { return $receipt }
    $mutex=$null; $held=$false
    try {
        $before = Get-LabStopHostMemory
        if (-not $before -or @($Provider).Count -eq 0) { return $receipt }
        $receipt.AvailableBeforeMB=$before.AvailableMB
        $receipt.AvailableAfterMB=$before.AvailableMB
        if ($before.TotalMB -le 0) { throw 'STOP_MEMORY_INVALID_HOST_MEASUREMENT' }
        if ($before.AvailableMB -ge ($before.TotalMB * 0.25)) { $receipt.Status='NOT_REQUIRED'; return $receipt }
        $mutex=[Threading.Mutex]::new($false, 'Local\SQL_Server_Lab_StopMemory')
        try { $held=$mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $held=$true }
        if (-not $held) { $receipt.Status='DEFERRED'; return $receipt }
        $target=$null; $selectedProvider=$null
        foreach ($candidate in @($Provider | Sort-Object -Unique)) {
            $target=Get-LabStopMemoryTarget -Provider $candidate
            if ($target) { $selectedProvider=$candidate; break }
        }
        if (-not $target) { $receipt.Status='UNSUPPORTED_BACKEND'; return $receipt }
        $readArgs=@('-d',$target.Distribution,'-u','root','--','cat','/proc/meminfo')
        $receipt.CacheBeforeMB=Get-LabStopLinuxCacheMB (Invoke-LabStopMemoryCommand $target.Invocation $readArgs)
        if ($receipt.CacheBeforeMB -lt 4096) { $receipt.Status='NOT_REQUIRED'; return $receipt }
        # Revalidate selection/running state immediately before the shared-cache operation.
        $current=Get-LabStopMemoryTarget -Provider $selectedProvider
        if (-not $current -or $current.RuntimeId -ne $target.RuntimeId -or $current.Distribution -cne $target.Distribution) {
            $receipt.Status='BACKEND_CHANGED'; return $receipt
        }
        $null=Invoke-LabStopMemoryCommand $target.Invocation @('-d',$target.Distribution,'-u','root','--','sh','-c','sync && echo 1 > /proc/sys/vm/drop_caches')
        $receipt.CacheReleaseRequested=$true
        $receipt.CacheAfterMB=Get-LabStopLinuxCacheMB (Invoke-LabStopMemoryCommand $target.Invocation $readArgs)
        $receipt.Status='RETURN_PENDING'
        # WSL returns free pages asynchronously; host-wide deltas are observations, not ownership evidence.
        for ($attempt=0; $attempt -lt 5; $attempt++) {
            Start-Sleep -Milliseconds 1000
            $after=Get-LabStopHostMemory
            $receipt.AvailableAfterMB=$after.AvailableMB
            if ($receipt.CacheAfterMB -lt $receipt.CacheBeforeMB -and $after.AvailableMB -ge ($before.AvailableMB + 64)) {
                $receipt.Status='HOST_RETURN_OBSERVED'; break
            }
        }
    }
    catch { $receipt.Status='CHECK_FAILED' }
    finally {
        if ($held) { $mutex.ReleaseMutex() }
        if ($mutex) { $mutex.Dispose() }
        if ($receipt.Status -in @('RETURN_PENDING','CHECK_FAILED','UNSUPPORTED_BACKEND','BACKEND_CHANGED','DEFERRED')) {
            Write-LabWarning "Lab gestoppt; Host-RAM-Rueckgabe nicht bestaetigt ($($receipt.Status)). Keine Runtime wurde beendet."
        }
    }
    return $receipt
}
