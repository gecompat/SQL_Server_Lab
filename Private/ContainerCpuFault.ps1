# Internal FLT-811/812: fixed CPU pulse on fresh operation-owned SQL test containers.
# The local caller owns the private journal directory and the authentication key.

function Assert-LabCpuFaultPath {
    param([string]$Path)
    $cursor=[IO.Path]::GetFullPath($Path)
    while ($cursor) {
        if ((Test-Path -LiteralPath $cursor) -and ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'CPU_FAULT_PATH_UNSAFE' }
        $cursor=[IO.Path]::GetDirectoryName($cursor)
    }
}

function Get-LabCpuFaultAuthentication {
    param([string]$Content,[byte[]]$Key)
    $hmac=[Security.Cryptography.HMACSHA256]::new($Key)
    try { [Convert]::ToHexString($hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes($Content))).ToLowerInvariant() }
    finally { $hmac.Dispose() }
}

function Get-LabCpuFaultHash {
    param([string]$Text)
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Text))).ToLowerInvariant()
}

function ConvertTo-LabCpuFaultCanonicalJson {
    param($Value)
    function ConvertTo-CpuFaultNode {
        param($Node)
        if ($Node -is [Collections.IDictionary]) {
            $ordered=[ordered]@{}
            foreach ($name in @($Node.Keys | Sort-Object -CaseSensitive)) { $ordered[$name]=ConvertTo-CpuFaultNode $Node[$name] }
            return $ordered
        }
        if ($Node -is [pscustomobject]) {
            $ordered=[ordered]@{}
            foreach ($property in @($Node.PSObject.Properties | Sort-Object Name -CaseSensitive)) { $ordered[$property.Name]=ConvertTo-CpuFaultNode $property.Value }
            return $ordered
        }
        if ($Node -is [DateTime] -or $Node -is [DateTimeOffset]) { return ([DateTimeOffset]$Node).ToUniversalTime().ToString('o') }
        if ($Node -is [Array]) { return ,@($Node | ForEach-Object { ConvertTo-CpuFaultNode $_ }) }
        return $Node
    }
    ConvertTo-CpuFaultNode $Value | ConvertTo-Json -Compress -Depth 20
}

function Invoke-LabCpuFaultNative {
    param($Binding, [string[]]$Arguments, [int]$TimeoutMilliseconds = 5000, [Security.SecureString]$Password)
    $process = [Diagnostics.Process]::new()
    $process.StartInfo.FileName = $Binding.Invocation
    $process.StartInfo.UseShellExecute = $false
    $process.StartInfo.CreateNoWindow = $true
    $process.StartInfo.RedirectStandardOutput = $true
    $process.StartInfo.RedirectStandardError = $true
    foreach ($name in @('DOCKER_HOST','DOCKER_CONTEXT','DOCKER_TLS_VERIFY','DOCKER_CERT_PATH','CONTAINER_HOST','CONTAINER_CONNECTION')) {
        $null = $process.StartInfo.Environment.Remove($name)
    }
    foreach ($argument in @($Binding.Arguments) + $Arguments) { $process.StartInfo.ArgumentList.Add($argument) }
    if ($Password) {
        $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
        try { $process.StartInfo.Environment['SQLCMDPASSWORD'] = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
    }
    $started = $false
    try {
        $started = $process.Start()
        $out = $process.StandardOutput.ReadToEndAsync()
        $err = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutMilliseconds)) { throw 'CPU_FAULT_NATIVE_TIMEOUT' }
        if (-not $out.Wait(100) -or -not $err.Wait(100)) { throw 'CPU_FAULT_NATIVE_TIMEOUT' }
        if ($process.ExitCode -ne 0) { throw 'CPU_FAULT_NATIVE_FAILED' }
        if ($out.Result.Length -gt 1048576) { throw 'CPU_FAULT_NATIVE_OUTPUT_LIMIT' }
        return $out.Result.Trim()
    }
    finally {
        if ($started -and -not $process.HasExited) {
            $process.Kill($true)
            if (-not $process.WaitForExit(1000)) { throw 'CPU_FAULT_NATIVE_TERMINATION_UNCONFIRMED' }
        }
        $null = $process.StartInfo.Environment.Remove('SQLCMDPASSWORD')
        $process.Dispose()
    }
}

function New-LabCpuFaultRuntimeBinding {
    param([ValidateSet('docker','podman')][string]$Provider)
    $binding = [ordered]@{ Provider=$Provider; Invocation=(Get-LabHostToolInvocation -Name $Provider); Arguments=@(); Identity='' }
    if ($Provider -eq 'docker') {
        # Resolve once, then use the literal local endpoint, never mutable current selection.
        $context = @(Invoke-LabCpuFaultNative $binding @('context','inspect') | ConvertFrom-Json)[0]
        $endpoint = [string]$context.Endpoints.docker.Host
        if ($endpoint -notmatch '^(npipe:////\./pipe/[A-Za-z0-9_.-]+|unix:///[^\r\n]+)$') { throw 'CPU_FAULT_LOCAL_RUNTIME_REQUIRED' }
        $binding.Arguments = @('--host',$endpoint)
    }
    else {
        $connections = @(Invoke-LabCpuFaultNative $binding @('system','connection','list','--format','json') | ConvertFrom-Json)
        $selected = @($connections | Where-Object Default)
        if ($selected.Count -eq 0 -and $IsLinux) { $binding.Arguments = @('--remote=false') }
        elseif ($selected.Count -eq 1 -and [string]$selected[0].URI -match '^ssh://[^@/]+@(127\.0\.0\.1|localhost):[0-9]+/[^\r\n]+$') {
            $binding.Arguments = @('--remote','--url',[string]$selected[0].URI,'--identity',[string]$selected[0].Identity)
        }
        else { throw 'CPU_FAULT_LOCAL_RUNTIME_REQUIRED' }
    }
    $binding.Identity = Get-LabCpuFaultRuntimeIdentity $binding
    return $binding
}

function Get-LabCpuFaultRuntimeIdentity {
    param($Binding)
    $info = Invoke-LabCpuFaultNative $Binding @('info','--format','{{json .}}') | ConvertFrom-Json
    $identity = if ($Binding.Provider -eq 'docker') { [string]$info.ID } else { [string]$info.host.hostname }
    if (-not $identity) { throw 'CPU_FAULT_RUNTIME_IDENTITY_MISSING' }
    Get-LabCpuFaultHash ($Binding.Provider + '|' + ($Binding.Arguments -join '|') + '|' + $identity)
}

function Assert-LabCpuFaultTarget {
    param($Target)
    $json = $Target | ConvertTo-Json -Depth 10 -Compress
    if (-not ($json | Test-Json -SchemaFile (Join-Path $PSScriptRoot '../Schemas/container-cpu-fault-target.schema.json') -ErrorAction SilentlyContinue)) { throw 'CPU_FAULT_TARGET_INVALID' }
    foreach ($name in @('OperationId','RunId','ScopeId')) { if ([guid]$Target.$name -eq [guid]::Empty) { throw 'CPU_FAULT_TARGET_INVALID' } }
}

function Get-LabCpuFaultSnapshot {
    param($Binding, $Target, [switch]$Fresh, [int]$TimeoutMilliseconds = 5000)
    # Never request Config.Env: a container may keep its SA secret there.
    $format='{"Id":{{json .Id}},"State":{"Running":{{json .State.Running}}},"Config":{"Labels":{{json .Config.Labels}}},"Created":{{json .Created}},"Image":{{json .Image}},"HostConfig":{{json .HostConfig}}}'
    # Podman's Go field is ID; its .Id compatibility rewrite does not cover json.
    if ($Binding.Provider -eq 'podman') { $format=$format.Replace('{{json .Id}}','{{json .ID}}') }
    $items = @(Invoke-LabCpuFaultNative $Binding @('inspect','--format',$format,$Target.ContainerId) $TimeoutMilliseconds | ConvertFrom-Json -Depth 40)
    if ($items.Count -ne 1) { throw 'CPU_FAULT_IDENTITY_MISMATCH' }
    $item = $items[0]
    $labels = $item.Config.Labels
    if ([string]$item.Id -cne $Target.ContainerId -or -not $item.State.Running) { throw 'CPU_FAULT_IDENTITY_MISMATCH' }
    foreach ($pair in @(@('run-id','RunId'),@('scope-id','ScopeId'),@('instance-id','InstanceId'),@('provider','Provider'),@('test-operation-id','OperationId'))) {
        if ([string]$labels.('sql-server-lab.' + $pair[0]) -cne [string]$Target.($pair[1])) { throw 'CPU_FAULT_OWNERSHIP_MISMATCH' }
    }
    if ([string]$labels.'sql-server-lab.lifecycle' -cne 'test') { throw 'CPU_FAULT_DISPOSABLE_REQUIRED' }
    foreach ($property in $labels.PSObject.Properties) {
        if ($property.Name -match '(?i)protect|reserved|test-environment|environment-group|support') { throw 'CPU_FAULT_PROTECTED_TARGET' }
    }
    $created = [DateTimeOffset]$item.Created
    $after = [DateTimeOffset]$Target.CreatedAfterUtc
    if ($created -lt $after -or $created -gt [DateTimeOffset]::UtcNow.AddSeconds(5)) { throw 'CPU_FAULT_FRESH_TARGET_REQUIRED' }
    if ($Fresh -and ([DateTimeOffset]::UtcNow - $after).TotalMinutes -gt 30) { throw 'CPU_FAULT_FRESH_TARGET_REQUIRED' }
    $cpu = [ordered]@{}
    foreach ($field in @('NanoCpus','CpuPeriod','CpuQuota','CpuShares','CpuRealtimePeriod','CpuRealtimeRuntime','CpusetCpus','CpusetMems','CpuCount','CpuPercent')) {
        # Missing fields are retained as null; no invented default or normalization.
        $cpu[$field] = $item.HostConfig.$field
    }
    return [ordered]@{ Cpu=$cpu; Created=$created.ToUniversalTime().ToString('o'); Image=[string]$item.Image }
}

function Get-LabCpuFaultCapMode {
    param($Cpu,[string]$Provider)
    foreach ($field in @('CpuShares','CpuRealtimePeriod','CpuRealtimeRuntime','CpuCount','CpuPercent')) {
        if ($null -ne $Cpu[$field] -and [long]$Cpu[$field] -ne 0) { throw 'CPU_FAULT_CAP_UNSUPPORTED' }
    }
    if ($Cpu.CpusetCpus -or $Cpu.CpusetMems) { throw 'CPU_FAULT_CAP_UNSUPPORTED' }
    if ($Cpu.NanoCpus -eq 2000000000 -and $Cpu.CpuPeriod -eq 0 -and $Cpu.CpuQuota -eq 0) { return 'NANO' }
    # Podman inspect projects its period/quota pair into NanoCpus as well.
    if ($Provider -eq 'podman' -and $Cpu.NanoCpus -eq 2000000000 -and $Cpu.CpuPeriod -eq 100000 -and $Cpu.CpuQuota -eq 200000) { return 'PODMAN_QUOTA' }
    if (($null -eq $Cpu.NanoCpus -or $Cpu.NanoCpus -eq 0) -and $Cpu.CpuPeriod -eq 100000 -and $Cpu.CpuQuota -eq 200000) { return 'QUOTA' }
    throw 'CPU_FAULT_CAP_UNSUPPORTED'
}

function Set-LabCpuFaultCap {
    param($Binding, $Target, [ValidateSet('NANO','QUOTA','PODMAN_QUOTA')][string]$Mode, [switch]$Restore)
    $arguments = if ($Mode -eq 'NANO') { @('update','--cpus',$(if ($Restore) { '2' } else { '1' }),$Target.ContainerId) }
        else { @('update','--cpu-period','100000','--cpu-quota',$(if ($Restore) { '200000' } else { '100000' }),$Target.ContainerId) }
    $null = Invoke-LabCpuFaultNative $Binding $arguments 1000
}

function Test-LabCpuFaultSql {
    param($Binding, $Target, [Security.SecureString]$Password, [int]$TimeoutMilliseconds = 5000)
    $query = "SET NOCOUNT ON; SELECT CASE WHEN CONVERT(int,SERVERPROPERTY('EngineEdition'))=3 AND DATABASEPROPERTYEX('master','Status')='ONLINE' THEN 'SQL_READY' ELSE 'SQL_NOT_READY' END;"
    $output = Invoke-LabCpuFaultNative $Binding @('exec','--env','SQLCMDPASSWORD',$Target.ContainerId,'/opt/mssql-tools18/bin/sqlcmd','-S','localhost','-U','sa','-C','-d','master','-b','-X1','-x','-l','1','-t','1','-h','-1','-W','-Q',$query) $TimeoutMilliseconds $Password
    if ($output.Trim() -cne 'SQL_READY') { throw 'CPU_FAULT_SQL_NOT_READY' }
}

function Read-LabCpuFaultJournal {
    param([string]$Path,[byte[]]$Key,[string]$TargetHash)
    Assert-LabCpuFaultPath $Path
    try {
        if ((Get-Item -LiteralPath $Path).Length -gt 65536) { throw 'size' }
        $envelope = [IO.File]::ReadAllText($Path) | ConvertFrom-Json -AsHashtable
        if (($envelope.Keys | Sort-Object) -join ',' -cne 'Authentication,Payload') { throw 'shape' }
        if ((Get-LabCpuFaultAuthentication $envelope.Payload $Key) -cne $envelope.Authentication) { throw 'authentication' }
        if (-not ($envelope.Payload | Test-Json -SchemaFile (Join-Path $PSScriptRoot '../Schemas/container-cpu-fault-journal.schema.json') -ErrorAction SilentlyContinue)) { throw 'schema' }
        $state = $envelope.Payload | ConvertFrom-Json -AsHashtable
        $state.Target.CreatedAfterUtc = ([DateTimeOffset]$state.Target.CreatedAfterUtc).ToUniversalTime().ToString('o')
        $state.Baseline.Created = ([DateTimeOffset]$state.Baseline.Created).ToUniversalTime().ToString('o')
        if ($state.TargetHash -cne $TargetHash) { throw 'target' }
        Assert-LabCpuFaultTarget $state.Target
        if ((Get-LabCpuFaultHash (ConvertTo-LabCpuFaultCanonicalJson $state.Target)) -cne $TargetHash) { throw 'binding' }
        if ((Get-LabCpuFaultCapMode $state.Baseline.Cpu $state.Target.Provider) -cne $state.Mode) { throw 'baseline' }
        if ($state.Status -eq 'COMPLETED' -and $state.CleanupStatus -ne 'PASSED') { throw 'outcome' }
        return $state
    }
    catch { throw 'CPU_FAULT_JOURNAL_UNTRUSTED' }
}

function Write-LabCpuFaultJournal {
    param([string]$Path,[byte[]]$Key,$State,[string]$PreviousAuthentication)
    Assert-LabCpuFaultPath $Path
    if (Test-Path -LiteralPath $Path) {
        $null = Read-LabCpuFaultJournal $Path $Key $State.TargetHash
        if (([IO.File]::ReadAllText($Path) | ConvertFrom-Json).Authentication -cne $PreviousAuthentication) { throw 'CPU_FAULT_JOURNAL_CHANGED' }
    }
    elseif ($PreviousAuthentication) { throw 'CPU_FAULT_JOURNAL_CHANGED' }
    $payload = $State | ConvertTo-Json -Depth 20 -Compress
    if (-not ($payload | Test-Json -SchemaFile (Join-Path $PSScriptRoot '../Schemas/container-cpu-fault-journal.schema.json') -ErrorAction SilentlyContinue)) { throw 'CPU_FAULT_JOURNAL_INVALID' }
    $authentication = Get-LabCpuFaultAuthentication $payload $Key
    $temporary = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        $stream = [IO.File]::Open($temporary,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try {
            $bytes = [Text.Encoding]::UTF8.GetBytes((@{ Payload=$payload; Authentication=$authentication } | ConvertTo-Json -Compress))
            $stream.Write($bytes); $stream.Flush($true)
        }
        finally { $stream.Dispose() }
        [IO.File]::Move($temporary,$Path,[bool]$PreviousAuthentication)
    }
    finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
    $authentication
}

function Wait-LabCpuFaultTestCheckpoint {
    # Private fixture synchronization only: no environment, target or public input.
    # The fixed bound also lets finally restore if the test parent disappears.
    $pause=Get-Variable -Name LabCpuFaultTestCheckpointPause -Scope Script -ValueOnly -ErrorAction SilentlyContinue
    if ($pause -is [bool] -and $pause) {
        [Threading.Thread]::Sleep(30000)
    }
}

function Invoke-LabContainerCpuFault {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Target,[Parameter(Mandatory)][string]$JournalDirectory,
        [Parameter(Mandatory)][byte[]]$OwnershipKey,[Parameter(Mandatory)][Security.SecureString]$Password,
        [Threading.CancellationToken]$CancellationToken = [Threading.CancellationToken]::None,[switch]$Resume)
    $ErrorActionPreference = 'Stop'
    Assert-LabCpuFaultTarget $Target
    if ($OwnershipKey.Length -ne 32) { throw 'CPU_FAULT_OWNERSHIP_INVALID' }
    $Target = $Target | ConvertTo-Json -Depth 10 -Compress | ConvertFrom-Json -AsHashtable
    $Target.CreatedAfterUtc = ([DateTimeOffset]$Target.CreatedAfterUtc).ToUniversalTime().ToString('o')
    $targetHash = Get-LabCpuFaultHash (ConvertTo-LabCpuFaultCanonicalJson $Target)
    $result = [ordered]@{ ContractVersion='SqlServerLab.InternalContainerCpuFaultResult/0.1'; OperationId=$Target.OperationId; Profile='container.cpu-limit'; Status='CANCELLED'; PrimaryStatus='CANCELLED'; CleanupStatus='NOT_REQUIRED'; AppliedVerified=$false; RestoredVerified=$false }
    if (-not $Resume -and $CancellationToken.IsCancellationRequested) { return [pscustomobject]$result }
    $directory = [IO.Path]::GetFullPath($JournalDirectory)
    Assert-LabCpuFaultPath $directory
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) { throw 'CPU_FAULT_DIRECTORY_REQUIRED' }
    $path = Join-Path $directory ($Target.OperationId + '.cpu-fault.json')
    $lockPath = Join-Path $directory ($Target.OperationId + '.cpu-fault.lock')
    Assert-LabCpuFaultPath $lockPath
    $lock = $null
    try {
        try { $lock = [IO.File]::Open($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None) }
        catch { throw 'CPU_FAULT_LOCK_UNAVAILABLE' }
        $authentication = ''
        if ($Resume) {
            $state = Read-LabCpuFaultJournal $path $OwnershipKey $targetHash
            $authentication = ([IO.File]::ReadAllText($path) | ConvertFrom-Json).Authentication
            $binding = $state.Runtime
        }
        else {
            if (Test-Path -LiteralPath $path) { throw 'CPU_FAULT_OPERATION_EXISTS' }
            $binding = New-LabCpuFaultRuntimeBinding $Target.Provider
            $baseline = Get-LabCpuFaultSnapshot $binding $Target -Fresh
            $mode = Get-LabCpuFaultCapMode $baseline.Cpu $Target.Provider
            Test-LabCpuFaultSql $binding $Target $Password
            $state = [ordered]@{ ContractVersion='SqlServerLab.InternalContainerCpuFaultJournal/0.1'; Profile='container.cpu-limit'; Target=$Target; TargetHash=$targetHash; Runtime=$binding; Baseline=$baseline; Mode=$mode; RestoreIntent=$true; Status='RESTORE_REQUIRED'; PrimaryStatus='NOT_EXECUTED'; CleanupStatus='PENDING'; CleanupAttempts=0; AppliedVerified=$false; RestoredVerified=$false }
            # Write-ahead restore intent: even an interruption before activation resumes restore only.
            $authentication = Write-LabCpuFaultJournal $path $OwnershipKey $state $authentication
        }
        if ($state.Status -ne 'COMPLETED' -and $state.CleanupAttempts -lt 3) {
            if ($Resume -and $state.PrimaryStatus -eq 'NOT_EXECUTED') { $state.PrimaryStatus='INTERRUPTED' }
            try {
                if (-not $Resume) {
                    if ($CancellationToken.IsCancellationRequested) { $state.PrimaryStatus='CANCELLED' }
                    else {
                        if ((Get-LabCpuFaultRuntimeIdentity $binding) -cne $binding.Identity) { throw 'CPU_FAULT_RUNTIME_CHANGED' }
                        $before = Get-LabCpuFaultSnapshot $binding $Target -Fresh
                        if ((ConvertTo-LabCpuFaultCanonicalJson $before) -cne (ConvertTo-LabCpuFaultCanonicalJson $state.Baseline)) { throw 'CPU_FAULT_BASELINE_CHANGED' }
                        if ($CancellationToken.IsCancellationRequested) { $state.PrimaryStatus='CANCELLED' }
                        else {
                            $clock = [Diagnostics.Stopwatch]::StartNew()
                            Set-LabCpuFaultCap $binding $Target $state.Mode
                            $applied = Get-LabCpuFaultSnapshot $binding $Target -TimeoutMilliseconds 1000
                            $expected = $state.Baseline.Cpu | ConvertTo-Json -Compress | ConvertFrom-Json -AsHashtable
                            if ($state.Mode -eq 'NANO') { $expected.NanoCpus=1000000000 } else { $expected.CpuQuota=100000 }
                            if ($state.Mode -eq 'PODMAN_QUOTA') { $expected.NanoCpus=1000000000 }
                            if ((ConvertTo-LabCpuFaultCanonicalJson $applied.Cpu) -cne (ConvertTo-LabCpuFaultCanonicalJson $expected)) { throw 'CPU_FAULT_APPLIED_POSTCONDITION_FAILED' }
                            $state.AppliedVerified=$true
                            # Commit applied evidence before observation or any finally cleanup.
                            $authentication = Write-LabCpuFaultJournal $path $OwnershipKey $state $authentication
                            Wait-LabCpuFaultTestCheckpoint
                            if ($CancellationToken.IsCancellationRequested) { $state.PrimaryStatus='CANCELLED' }
                            else {
                                Test-LabCpuFaultSql $binding $Target $Password -TimeoutMilliseconds 1000
                                $state.PrimaryStatus = if ($CancellationToken.IsCancellationRequested) { 'CANCELLED' } elseif ($clock.ElapsedMilliseconds -ge 5000) { 'TIMED_OUT' } else { 'PASSED' }
                            }
                        }
                    }
                }
            }
            catch { $state.PrimaryStatus = if ($_.Exception.Message -eq 'CPU_FAULT_NATIVE_TIMEOUT') { 'TIMED_OUT' } else { 'EXECUTION_FAILED' } }
            finally {
                try {
                    $null = Read-LabCpuFaultJournal $path $OwnershipKey $targetHash
                    $state.CleanupAttempts++; $state.CleanupStatus='IN_PROGRESS'
                    $authentication = Write-LabCpuFaultJournal $path $OwnershipKey $state $authentication
                    if ((Get-LabCpuFaultRuntimeIdentity $binding) -cne $binding.Identity) { throw 'CPU_FAULT_RUNTIME_CHANGED' }
                    $current = Get-LabCpuFaultSnapshot $binding $Target
                    if ($current.Created -cne $state.Baseline.Created -or $current.Image -cne $state.Baseline.Image) { throw 'CPU_FAULT_IDENTITY_MISMATCH' }
                    $allowedApplied = $state.Baseline.Cpu | ConvertTo-Json -Compress | ConvertFrom-Json -AsHashtable
                    if ($state.Mode -eq 'NANO') { $allowedApplied.NanoCpus=1000000000 } else { $allowedApplied.CpuQuota=100000 }
                    if ($state.Mode -eq 'PODMAN_QUOTA') { $allowedApplied.NanoCpus=1000000000 }
                    if ((ConvertTo-LabCpuFaultCanonicalJson $current.Cpu) -cne (ConvertTo-LabCpuFaultCanonicalJson $state.Baseline.Cpu) -and
                        (ConvertTo-LabCpuFaultCanonicalJson $current.Cpu) -cne (ConvertTo-LabCpuFaultCanonicalJson $allowedApplied)) { throw 'CPU_FAULT_UNEXPECTED_CPU_DRIFT' }
                    if ((ConvertTo-LabCpuFaultCanonicalJson $current.Cpu) -cne (ConvertTo-LabCpuFaultCanonicalJson $state.Baseline.Cpu)) { Set-LabCpuFaultCap $binding $Target $state.Mode -Restore }
                    $restored = Get-LabCpuFaultSnapshot $binding $Target
                    if ((ConvertTo-LabCpuFaultCanonicalJson $restored) -cne (ConvertTo-LabCpuFaultCanonicalJson $state.Baseline)) { throw 'CPU_FAULT_RESTORE_POSTCONDITION_FAILED' }
                    Test-LabCpuFaultSql $binding $Target $Password
                    $state.RestoredVerified=$true; $state.CleanupStatus='PASSED'; $state.Status='COMPLETED'
                }
                catch { $state.CleanupStatus='FAILED'; $state.Status='RECOVERY_REQUIRED' }
                # If persistence fails, the durable write-ahead record still requires restore.
                try { $authentication = Write-LabCpuFaultJournal $path $OwnershipKey $state $authentication }
                catch { $state.CleanupStatus='FAILED'; $state.Status='RECOVERY_REQUIRED' }
            }
        }
        foreach ($name in @('PrimaryStatus','CleanupStatus','AppliedVerified','RestoredVerified')) { $result[$name]=$state[$name] }
        $result.Status = if ($state.Status -ne 'COMPLETED') { 'RECOVERY_REQUIRED' } else { $state.PrimaryStatus }
        return [pscustomobject]$result
    }
    finally { if ($lock) { $lock.Dispose() } }
}
