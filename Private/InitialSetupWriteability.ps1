# Explicit, temporary write probe; ordinary setup discovery never calls this executor.
function Get-LabSetupWriteProbeDigest([string]$Text) {
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Text))).ToLowerInvariant()
}

function Get-LabSetupWriteProbeBinding {
    param([Parameter(Mandatory)][string]$LocationId)
    if (-not $IsWindows) { throw 'INITIAL_SETUP_PROBE_PLATFORM_UNSUPPORTED' }
    if ($LocationId -cnotmatch '^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$') { throw 'INITIAL_SETUP_PROBE_LOCATION_INVALID' }
    $configuration = Get-LabStorageConfiguration
    $locations = @($configuration.LabDataLocations | Where-Object LocationId -CEQ $LocationId)
    if ($locations.Count -ne 1 -or [string]::IsNullOrWhiteSpace($configuration.ControllerId)) { throw 'INITIAL_SETUP_PROBE_LOCATION_UNKNOWN' }
    $location = $locations[0]
    $root = [IO.Path]::GetFullPath([string]$location.LabDataRoot).TrimEnd('\', '/')
    if ($root -cnotmatch '^[A-Za-z]:\\.+' -or (Test-LabInitialSetupPathWithinRepository $root)) { throw 'INITIAL_SETUP_PROBE_ROOT_UNSUPPORTED' }
    $drive = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($root))
    if ($drive.DriveType -ne [IO.DriveType]::Fixed -or $drive.DriveFormat -cnotin @('NTFS','ReFS')) { throw 'INITIAL_SETUP_PROBE_FILESYSTEM_UNSUPPORTED' }
    $ancestors = @()
    $cursor = $root
    while ($cursor) {
        $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
        if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'INITIAL_SETUP_PROBE_REPARSE_OR_MISSING_ROOT' }
        $ancestors += [ordered]@{ Path=$item.FullName; CreatedTicks=$item.CreationTimeUtc.Ticks }
        $cursor = [IO.Path]::GetDirectoryName($cursor)
    }
    $markerPath = Get-LabDataRootMarkerPath $root
    $markerItem = Get-Item -LiteralPath $markerPath -Force -ErrorAction Stop
    if ($markerItem.PSIsContainer -or ($markerItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'INITIAL_SETUP_PROBE_MARKER_INVALID' }
    $marker = Get-LabDataRootMarker $root
    $volume = Get-LabVolumeIdentity $root
    # A marker-only legacy discovery is not registration authority for this probe.
    $catalogPath=Join-Path $root 'Catalog/storage-locations.json'
    foreach ($catalogPart in @((Join-Path $root 'Catalog'),$catalogPath)) {
        $catalogItem=Get-Item -LiteralPath $catalogPart -Force -ErrorAction Stop
        if ($catalogItem.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'INITIAL_SETUP_PROBE_REGISTRATION_INVALID' }
    }
    $registered=Get-Content -LiteralPath $catalogPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 20 -ErrorAction Stop
    $registeredLocation=@($registered.LabDataLocations | Where-Object LocationId -CEQ $LocationId)
    if ($registered.ContractVersion -cne 'SqlServerLab.Storage/2.0' -or $registered.ControllerId -cne $configuration.ControllerId -or
        $registeredLocation.Count -ne 1 -or $registeredLocation[0].ControllerId -cne $configuration.ControllerId -or
        $registeredLocation[0].VolumeId -cne $volume.VolumeId -or $registeredLocation[0].LabDataRoot -cne $root) { throw 'INITIAL_SETUP_PROBE_REGISTRATION_INVALID' }
    if (-not (Test-LabDataRootOwnership -DataRoot $root -ControllerId $configuration.ControllerId) -or
        $location.ControllerId -cne $configuration.ControllerId -or
        $marker.DataRoot -cne $root -or
        $marker.VolumeId -cne $location.VolumeId -or $volume.VolumeId -cne $location.VolumeId -or
        [string]::IsNullOrWhiteSpace($volume.VolumeId) -or $volume.VolumeId -ceq $volume.VolumeRoot) { throw 'INITIAL_SETUP_PROBE_OWNERSHIP_OR_VOLUME_CHANGED' }
    $authority = [ordered]@{
        ControllerId=$configuration.ControllerId; DefaultLocationId=$configuration.DefaultLocationId
        Locations=@($configuration.LabDataLocations | Sort-Object LocationId | ForEach-Object {
            [ordered]@{ LocationId=$_.LocationId; LabDataRoot=$_.LabDataRoot; VolumeId=$_.VolumeId; ControllerId=$_.ControllerId }
        })
        Ancestors=$ancestors; MarkerSha256=(Get-FileHash -LiteralPath $markerPath -Algorithm SHA256).Hash.ToLowerInvariant()
        RegistrationSha256=(Get-FileHash -LiteralPath $catalogPath -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    [pscustomobject]@{ LocationId=$LocationId; Root=$root; Ancestors=$ancestors; MarkerPath=$markerPath
        MarkerSha256=$authority.MarkerSha256; Key=(Get-LabSetupWriteProbeDigest ($authority | ConvertTo-Json -Depth 8 -Compress)) }
}

function New-LabInitialSetupWriteabilityPlan {
    param([Parameter(Mandatory)][string]$LocationId)
    try { $binding = Get-LabSetupWriteProbeBinding $LocationId }
    catch { if ($_.Exception.Message -cmatch '^INITIAL_SETUP_PROBE_[A-Z_]+$') { throw $_.Exception.Message }; throw 'INITIAL_SETUP_PROBE_LOCATION_UNREADABLE' }
    if (-not $script:SetupWriteProbePlans) { $script:SetupWriteProbePlans = [Collections.Concurrent.ConcurrentDictionary[string,object]]::new() }
    foreach ($entry in $script:SetupWriteProbePlans.ToArray()) {
        if ($entry.Value.ExpiresAt -le [datetime]::UtcNow) { $removed=$null; $null=$script:SetupWriteProbePlans.TryRemove($entry.Key,[ref]$removed) }
    }
    if ($script:SetupWriteProbePlans.Count -ge 64) { throw 'INITIAL_SETUP_PROBE_TOO_MANY_PREVIEWS' }
    $id = [guid]::NewGuid().ToString('D')
    $expires = [datetime]::UtcNow.AddMinutes(5)
    $record = [pscustomobject]@{ Binding=$binding; PlanId=$id; ExpiresAt=$expires
        Leaf=('.sql-server-lab-write-probe-'+[guid]::NewGuid().ToString('N')+'.tmp') }
    if (-not $script:SetupWriteProbePlans.TryAdd($id,$record)) { throw 'INITIAL_SETUP_PROBE_PLAN_COLLISION' }
    [pscustomobject]@{ ContractVersion='SqlServerLab.InitialSetupWriteabilityPlan/1.0'; PlanId=$id; LocationId=$LocationId
        ExpiresAt=$expires.ToString('o'); WriteBytes=1; MaximumSeconds=43
        Notice='Eine eigene temporäre Datei schreiben, flushen und entfernen. Keine Root-, Default- oder Provideränderung.' }
}

function Invoke-LabSetupWriteProbeWorkerCore {
    param([Parameter(Mandatory)]$Record,[ValidateSet('Probe','Cleanup')][string]$Mode)
    $guards=[Collections.Generic.List[IDisposable]]::new()
    $stream=$null; $created=$false; $written=$false; $primary=$null; $cleanup=$null; $absent=$false; $validLeaf=$false
    try {
        if ($Record.Leaf -cnotmatch '^\.sql-server-lab-write-probe-[a-f0-9]{32}\.tmp$') { throw 'INITIAL_SETUP_PROBE_LEAF_INVALID' }
        $validLeaf=$true
        if ($Mode -eq 'Probe' -and [datetime]$Record.ExpiresAt -le [datetime]::UtcNow) { throw 'INITIAL_SETUP_PROBE_PLAN_UNKNOWN_OR_EXPIRED' }
        $current = Get-LabSetupWriteProbeBinding $Record.Binding.LocationId
        if ($current.Key -cne $Record.Binding.Key -or $current.Root -cne $Record.Binding.Root) { throw 'INITIAL_SETUP_PROBE_PREVIEW_STALE' }
        # Windows directory handles deny write/delete sharing while the marker and own leaf
        # are held. Unsupported BCL/filesystem semantics fail before CreateNew; no fallback.
        foreach ($ancestor in @($current.Ancestors | Sort-Object { $_.Path.Length })) {
            $guards.Add([IO.File]::OpenHandle($ancestor.Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read,[IO.FileOptions]0x02000000))
        }
        $markerHandle = [IO.File]::Open($current.MarkerPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        $guards.Add($markerHandle)
        $heldMarkerHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($markerHandle)).ToLowerInvariant()
        $held = Get-LabSetupWriteProbeBinding $Record.Binding.LocationId
        if ($held.Key -cne $Record.Binding.Key -or $heldMarkerHash -cne $held.MarkerSha256) { throw 'INITIAL_SETUP_PROBE_PREVIEW_STALE' }
        $path=Join-Path $held.Root $Record.Leaf
        if ($Mode -eq 'Probe') {
            $stream=[IO.FileStream]::new($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None,1,[IO.FileOptions]::DeleteOnClose)
            $created=$true
            # Recheck after opening and before the byte write, while directory/marker guards
            # still protect the names. This is not a claim of portable atomic directory IDs.
            if ((Get-LabSetupWriteProbeBinding $Record.Binding.LocationId).Key -cne $Record.Binding.Key) { throw 'INITIAL_SETUP_PROBE_PREVIEW_STALE' }
            if ([datetime]$Record.ExpiresAt -le [datetime]::UtcNow) { throw 'INITIAL_SETUP_PROBE_PLAN_UNKNOWN_OR_EXPIRED' }
            $stream.WriteByte(1); $stream.Flush($true); $written=$true
        }
    } catch [UnauthorizedAccessException] { $primary='INITIAL_SETUP_PROBE_ACCESS_DENIED' }
    catch { $primary=if ($_.Exception.Message -cmatch '^INITIAL_SETUP_PROBE_[A-Z_]+$') { $_.Exception.Message } else { 'INITIAL_SETUP_PROBE_IO_FAILED' } }
    finally {
        try { if ($stream) { $stream.Dispose() } } catch { $cleanup='INITIAL_SETUP_PROBE_HANDLE_CLEANUP_FAILED' }
        try {
            if (-not $validLeaf) { throw 'INITIAL_SETUP_PROBE_LEAF_INVALID' }
            $cleanupBinding=Get-LabSetupWriteProbeBinding $Record.Binding.LocationId
            if ($cleanupBinding.Key -cne $Record.Binding.Key -or $cleanupBinding.Root -cne $Record.Binding.Root) { throw 'INITIAL_SETUP_PROBE_CLEANUP_BINDING_CHANGED' }
            $absent=-not (Test-Path -LiteralPath (Join-Path $Record.Binding.Root $Record.Leaf))
            if (-not $absent) { throw 'INITIAL_SETUP_PROBE_LEAF_ABSENCE_UNCONFIRMED' }
        } catch { if (-not $cleanup) { $cleanup=if ($_.Exception.Message -cmatch '^INITIAL_SETUP_PROBE_[A-Z_]+$') { $_.Exception.Message } else { 'INITIAL_SETUP_PROBE_CLEANUP_CHECK_FAILED' } } }
        for ($index=$guards.Count-1; $index -ge 0; $index--) { try { $guards[$index].Dispose() } catch { if (-not $cleanup) { $cleanup='INITIAL_SETUP_PROBE_GUARD_CLEANUP_FAILED' } } }
    }
    [pscustomobject]@{ ContractVersion='SqlServerLab.InitialSetupWriteabilityWorker/1.0'; Mode=$Mode
        Created=$created; Written=$written; Absent=$absent; PrimaryCode=$primary; CleanupCode=$cleanup }
}

function Invoke-LabSetupWriteProbeProcess {
    param($Record,[ValidateSet('Probe','Cleanup')][string]$Mode,[int]$Seconds)
    $start=[Diagnostics.ProcessStartInfo]::new((Get-Command pwsh -ErrorAction Stop).Source)
    $start.UseShellExecute=$false; $start.CreateNoWindow=$true
    $start.RedirectStandardInput=$true; $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
    foreach ($argument in @('-NoLogo','-NoProfile','-NonInteractive','-File',(Join-Path $script:ModuleRoot 'Tools/Invoke-InitialSetupWriteProbe.ps1'))) { $start.ArgumentList.Add($argument) }
    $process=[Diagnostics.Process]::new(); $process.StartInfo=$start; $started=$false
    try {
        $inputJson=[ordered]@{ Record=$Record; Mode=$Mode } | ConvertTo-Json -Depth 12 -Compress
        if ($inputJson.Length -gt 32768) { throw 'INITIAL_SETUP_PROBE_INPUT_INVALID' }
        $started=$process.Start()
        $output=$process.StandardOutput.ReadToEndAsync(); $errors=$process.StandardError.ReadToEndAsync()
        $writeInput=$process.StandardInput.WriteLineAsync($inputJson)
        if (-not $writeInput.Wait(2000)) { throw 'INITIAL_SETUP_PROBE_INPUT_TIMEOUT' }
        $process.StandardInput.Close()
        if (-not $process.WaitForExit($Seconds*1000)) {
            throw 'INITIAL_SETUP_PROBE_WORKER_TIMEOUT'
        }
        $result=$output.GetAwaiter().GetResult() | ConvertFrom-Json -Depth 8 -ErrorAction Stop
        $null=$errors.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0 -or $result.ContractVersion -cne 'SqlServerLab.InitialSetupWriteabilityWorker/1.0' -or
            $result -isnot [pscustomobject] -or $result.Mode -cne $Mode -or $result.Created -isnot [bool] -or $result.Written -isnot [bool] -or $result.Absent -isnot [bool] -or
            ($result.Written -and -not $result.Created) -or ($Mode -eq 'Cleanup' -and ($result.Written -or $result.Created)) -or
            @($result.PSObject.Properties.Name | Where-Object { $_ -cnotin @('ContractVersion','Mode','Created','Written','Absent','PrimaryCode','CleanupCode') }).Count -or
            ($null -ne $result.PrimaryCode -and ($result.PrimaryCode -isnot [string] -or $result.PrimaryCode -cnotmatch '^INITIAL_SETUP_PROBE_[A-Z_]+$')) -or
            ($null -ne $result.CleanupCode -and ($result.CleanupCode -isnot [string] -or $result.CleanupCode -cnotmatch '^INITIAL_SETUP_PROBE_[A-Z_]+$'))) { throw 'INITIAL_SETUP_PROBE_WORKER_RESULT_INVALID' }
        $result
    } finally {
        try {
            if ($started -and -not $process.HasExited) {
                $process.Kill($true)
                if (-not $process.WaitForExit(2000)) { throw 'INITIAL_SETUP_PROBE_WORKER_TERMINATION_UNCONFIRMED' }
            }
        } catch { throw 'INITIAL_SETUP_PROBE_WORKER_TERMINATION_UNCONFIRMED' }
        finally { $process.Dispose() }
    }
}

function Invoke-LabInitialSetupWriteabilityPlan {
    [CmdletBinding(SupportsShouldProcess,ConfirmImpact='Medium')]
    param([Parameter(Mandatory)][string]$PlanId,[switch]$Confirmed)
    if (-not $Confirmed) { throw 'INITIAL_SETUP_PROBE_CONFIRMATION_REQUIRED' }
    $record=$null
    if (-not $script:SetupWriteProbePlans -or -not $script:SetupWriteProbePlans.TryGetValue($PlanId,[ref]$record) -or
        $record.ExpiresAt -le [datetime]::UtcNow) { throw 'INITIAL_SETUP_PROBE_PLAN_UNKNOWN_OR_EXPIRED' }
    if (-not $PSCmdlet.ShouldProcess($record.Binding.LocationId,'Eine temporäre Schreibbarkeitsprobe ausführen und bereinigen')) { return }
    $removed=$null
    if (-not $script:SetupWriteProbePlans.TryRemove($PlanId,[ref]$removed)) { throw 'INITIAL_SETUP_PROBE_PLAN_ALREADY_USED' }
    $probe=$null; $check=$null; $primary=$null; $cleanup=$null
    try { $probe=Invoke-LabSetupWriteProbeProcess -Record $record -Mode Probe -Seconds 20; $primary=$probe.PrimaryCode }
    catch { $primary=if ($_.Exception.Message -cmatch '^INITIAL_SETUP_PROBE_[A-Z_]+$') { $_.Exception.Message } else { 'INITIAL_SETUP_PROBE_WORKER_FAILED' } }
    # A fresh bounded read-only worker confirms absence independently, also after timeout.
    # It never removes a file by path, including a colliding or replaced foreign leaf.
    try { $check=Invoke-LabSetupWriteProbeProcess -Record $record -Mode Cleanup -Seconds 15; $cleanup=$check.CleanupCode
        if ($check.PrimaryCode -or -not $check.Absent) { $cleanup='INITIAL_SETUP_PROBE_CLEANUP_UNCONFIRMED' }
    } catch { $cleanup='INITIAL_SETUP_PROBE_CLEANUP_UNCONFIRMED' }
    if ($probe -and $probe.CleanupCode) { $cleanup=$probe.CleanupCode }
    if ($primary -ceq 'INITIAL_SETUP_PROBE_WORKER_TERMINATION_UNCONFIRMED') { $cleanup='INITIAL_SETUP_PROBE_WORKER_TERMINATION_UNCONFIRMED' }
    $status=if ($cleanup) { 'RECOVERY_REQUIRED' } elseif ($primary) { 'FAILED' } elseif ($probe -and $probe.Written) { 'WRITABLE' } else { 'FAILED' }
    [pscustomobject]@{ ContractVersion='SqlServerLab.InitialSetupWriteabilityResult/1.0'; PlanId=$PlanId
        LocationId=$record.Binding.LocationId; ObservedAt=[datetime]::UtcNow.ToString('o'); Status=$status
        PrimaryCode=$primary; CleanupCode=$cleanup; OwnLeafAbsent=[bool]($check -and $check.Absent -and -not $cleanup)
        Notice='Momentaufnahme für diese Location; keine Kapazitäts-, SQL- oder Providerabnahme.' }
}
