# Internal FLT-811/812 memory pulse. The CPU slice supplies only the unchanged
# local transport, canonical JSON/hash/HMAC and path helpers, not fault semantics.

function Assert-LabMemoryFaultTarget {
    param($Target)
    if (-not (($Target | ConvertTo-Json -Depth 10 -Compress) | Test-Json -SchemaFile (Join-Path $PSScriptRoot '../Schemas/container-memory-fault-target.schema.json') -ErrorAction SilentlyContinue)) { throw 'MEMORY_FAULT_TARGET_INVALID' }
    foreach ($name in @('OperationId','RunId','ScopeId')) { if ([guid]$Target.$name -eq [guid]::Empty) { throw 'MEMORY_FAULT_TARGET_INVALID' } }
}

function Get-LabMemoryFaultSnapshot {
    param($Binding,$Target,[switch]$Fresh,[switch]$RequireRunning,[int]$TimeoutMilliseconds=5000)
    # Projection excludes Config.Env and all other container configuration.
    $format='{"Id":{{json .Id}},"State":{"Running":{{json .State.Running}}},"Config":{"Labels":{{json .Config.Labels}}},"Created":{{json .Created}},"Image":{{json .Image}},"HostConfig":{{json .HostConfig}}}'
    if ($Binding.Provider -eq 'podman') { $format=$format.Replace('{{json .Id}}','{{json .ID}}') }
    $cgroupFormat=if ($Binding.Provider -eq 'docker') { '{{json .CgroupVersion}}' } else { '{{json .Host.CgroupsVersion}}' }
    $cgroup=[string](Invoke-LabCpuFaultNative $Binding @('info','--format',$cgroupFormat) $TimeoutMilliseconds | ConvertFrom-Json)
    if (($Binding.Provider -eq 'docker' -and $cgroup -notin @('1','2')) -or ($Binding.Provider -eq 'podman' -and $cgroup -notin @('v1','v2'))) { throw 'MEMORY_FAULT_CGROUP_UNKNOWN' }
    $items=@(Invoke-LabCpuFaultNative $Binding @('inspect','--format',$format,$Target.ContainerId) $TimeoutMilliseconds | ConvertFrom-Json -Depth 30)
    if ($items.Count -ne 1 -or [string]$items[0].Id -cne $Target.ContainerId -or $items[0].State.Running -isnot [bool]) { throw 'MEMORY_FAULT_IDENTITY_MISMATCH' }
    $item=$items[0]
    if ($RequireRunning -and -not $item.State.Running) { throw 'MEMORY_FAULT_RUNNING_REQUIRED' }
    $labels=$item.Config.Labels
    foreach ($pair in @(@('run-id','RunId'),@('scope-id','ScopeId'),@('instance-id','InstanceId'),@('provider','Provider'),@('test-operation-id','OperationId'))) {
        if ([string]$labels.('sql-server-lab.'+$pair[0]) -cne [string]$Target.($pair[1])) { throw 'MEMORY_FAULT_OWNERSHIP_MISMATCH' }
    }
    if ([string]$labels.'sql-server-lab.lifecycle' -cne 'test') { throw 'MEMORY_FAULT_DISPOSABLE_REQUIRED' }
    foreach ($property in $labels.PSObject.Properties) {
        if ($property.Name -match '(?i)protect|reserved|test-environment|environment-group|support') { throw 'MEMORY_FAULT_PROTECTED_TARGET' }
    }
    $created=[DateTimeOffset]$item.Created
    $after=[DateTimeOffset]$Target.CreatedAfterUtc
    if ($created -lt $after -or $created -gt [DateTimeOffset]::UtcNow.AddSeconds(5) -or ($Fresh -and ([DateTimeOffset]::UtcNow-$after).TotalMinutes -gt 30)) { throw 'MEMORY_FAULT_FRESH_TARGET_REQUIRED' }
    $memory=[ordered]@{}
    foreach ($field in @('Memory','MemorySwap','MemoryReservation','MemorySwappiness','KernelMemory','KernelMemoryTCP','OomKillDisable')) {
        # Retain absence as null, never invent a numeric default.
        $memory[$field]=$item.HostConfig.$field
    }
    return [ordered]@{ Memory=$memory; Created=$created.ToUniversalTime().ToString('o'); Image=[string]$item.Image; Running=[bool]$item.State.Running; CgroupVersion=$cgroup }
}

function Assert-LabMemoryFaultBaseline {
    param($Baseline)
    $memory=$Baseline.Memory
    # Only the explicitly bounded 3 GiB / 6 GiB tuple is reversible in this slice.
    if ($memory.Memory -ne 3221225472 -or $memory.MemorySwap -ne 6442450944 -or
        $null -eq $memory.MemoryReservation -or $memory.MemoryReservation -ne 0 -or
        -not $Baseline.Running) { throw 'MEMORY_FAULT_BASELINE_UNSUPPORTED' }
    # cgroup v2 has no OOM-killer-disable control. Keep the absent raw value,
    # but require live cgroup evidence rather than interpreting null as false.
    if ($null -eq $memory.OomKillDisable) {
        if ($Baseline.CgroupVersion -notin @('2','v2')) { throw 'MEMORY_FAULT_BASELINE_UNSUPPORTED' }
    } elseif ($memory.OomKillDisable -isnot [bool] -or $memory.OomKillDisable) { throw 'MEMORY_FAULT_BASELINE_UNSUPPORTED' }
    foreach ($field in @('KernelMemory','KernelMemoryTCP')) {
        if ($null -ne $memory[$field] -and $memory[$field] -ne 0) { throw 'MEMORY_FAULT_BASELINE_UNSUPPORTED' }
    }
    if ($null -ne $memory.MemorySwappiness -and $memory.MemorySwappiness -notin @(-1,0)) { throw 'MEMORY_FAULT_BASELINE_UNSUPPORTED' }
}

function Get-LabMemoryFaultAppliedMemory {
    param($Baseline)
    $memory=$Baseline.Memory | ConvertTo-Json -Compress | ConvertFrom-Json -AsHashtable
    $memory.Memory=2684354560
    return $memory
}

function Set-LabMemoryFaultLimit {
    param($Binding,$Target,[switch]$Restore)
    # Explicit total memory+swap prevents provider default recomputation.
    $bytes=if ($Restore) { '3221225472' } else { '2684354560' }
    $null=Invoke-LabCpuFaultNative $Binding @('update','--memory',$bytes,'--memory-swap','6442450944',$Target.ContainerId) 1000
}

function Test-LabMemoryFaultSql {
    param($Binding,$Target,[Security.SecureString]$Password,[int]$TimeoutMilliseconds=5000)
    $query="SET NOCOUNT ON; SELECT CASE WHEN CONVERT(int,SERVERPROPERTY('EngineEdition'))=3 AND CONVERT(int,SERVERPROPERTY('ProductMajorVersion'))=17 AND DATABASEPROPERTYEX('master','Status')='ONLINE' THEN 'SQL_READY' ELSE 'SQL_NOT_READY' END;"
    $output=Invoke-LabCpuFaultNative $Binding @('exec','--env','SQLCMDPASSWORD',$Target.ContainerId,'/opt/mssql-tools18/bin/sqlcmd','-S','localhost','-U','sa','-C','-d','master','-b','-X1','-x','-l','1','-t','1','-h','-1','-W','-Q',$query) $TimeoutMilliseconds $Password
    if ($output.Trim() -cne 'SQL_READY') { throw 'MEMORY_FAULT_SQL_NOT_READY' }
}

function Read-LabMemoryFaultJournal {
    param([string]$Path,[byte[]]$Key,[string]$TargetHash)
    Assert-LabCpuFaultPath $Path
    try {
        if ((Get-Item -LiteralPath $Path).Length -gt 65536) { throw 'size' }
        $envelope=[IO.File]::ReadAllText($Path) | ConvertFrom-Json -AsHashtable
        if (($envelope.Keys | Sort-Object) -join ',' -cne 'Authentication,Payload' -or (Get-LabCpuFaultAuthentication $envelope.Payload $Key) -cne $envelope.Authentication) { throw 'authentication' }
        if (-not ($envelope.Payload | Test-Json -SchemaFile (Join-Path $PSScriptRoot '../Schemas/container-memory-fault-journal.schema.json') -ErrorAction SilentlyContinue)) { throw 'schema' }
        $state=$envelope.Payload | ConvertFrom-Json -AsHashtable
        $state.Target.CreatedAfterUtc=([DateTimeOffset]$state.Target.CreatedAfterUtc).ToUniversalTime().ToString('o')
        $state.Baseline.Created=([DateTimeOffset]$state.Baseline.Created).ToUniversalTime().ToString('o')
        Assert-LabMemoryFaultTarget $state.Target
        Assert-LabMemoryFaultBaseline $state.Baseline
        if ($state.TargetHash -cne $TargetHash -or (Get-LabCpuFaultHash (ConvertTo-LabCpuFaultCanonicalJson $state.Target)) -cne $TargetHash -or $state.Runtime.Provider -cne $state.Target.Provider) { throw 'binding' }
        if ($state.Status -eq 'COMPLETED' -and ($state.CleanupStatus -ne 'PASSED' -or -not $state.LimitRestoredVerified -or -not $state.SqlRestoredVerified)) { throw 'outcome' }
        return $state
    } catch { throw 'MEMORY_FAULT_JOURNAL_UNTRUSTED' }
}

function Write-LabMemoryFaultJournal {
    param([string]$Path,[byte[]]$Key,$State,[string]$PreviousAuthentication)
    Assert-LabCpuFaultPath $Path
    if (Test-Path -LiteralPath $Path) {
        $null=Read-LabMemoryFaultJournal $Path $Key $State.TargetHash
        if (([IO.File]::ReadAllText($Path) | ConvertFrom-Json).Authentication -cne $PreviousAuthentication) { throw 'MEMORY_FAULT_JOURNAL_CHANGED' }
    } elseif ($PreviousAuthentication) { throw 'MEMORY_FAULT_JOURNAL_CHANGED' }
    $payload=$State | ConvertTo-Json -Depth 20 -Compress
    if (-not ($payload | Test-Json -SchemaFile (Join-Path $PSScriptRoot '../Schemas/container-memory-fault-journal.schema.json') -ErrorAction SilentlyContinue)) { throw 'MEMORY_FAULT_JOURNAL_INVALID' }
    $authentication=Get-LabCpuFaultAuthentication $payload $Key
    $temporary="$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        $stream=[IO.File]::Open($temporary,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try {
            $bytes=[Text.Encoding]::UTF8.GetBytes((@{Payload=$payload; Authentication=$authentication} | ConvertTo-Json -Compress))
            $stream.Write($bytes); $stream.Flush($true)
        } finally { $stream.Dispose() }
        [IO.File]::Move($temporary,$Path,[bool]$PreviousAuthentication)
    } finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
    return $authentication
}

function Wait-LabMemoryFaultTestCheckpoint {
    # Fixed private fixture bound; no public/target/environment control.
    $pause=Get-Variable -Name LabMemoryFaultTestCheckpointPause -Scope Script -ValueOnly -ErrorAction SilentlyContinue
    if ($pause -is [bool] -and $pause) { [Threading.Thread]::Sleep(30000) }
}

function Invoke-LabContainerMemoryFault {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Target,[Parameter(Mandatory)][string]$JournalDirectory,
        [Parameter(Mandatory)][byte[]]$OwnershipKey,[Parameter(Mandatory)][Security.SecureString]$Password,
        [Threading.CancellationToken]$CancellationToken=[Threading.CancellationToken]::None,[switch]$Resume)
    $ErrorActionPreference='Stop'
    Assert-LabMemoryFaultTarget $Target
    if ($OwnershipKey.Length -ne 32) { throw 'MEMORY_FAULT_OWNERSHIP_INVALID' }
    $Target=$Target | ConvertTo-Json -Depth 10 -Compress | ConvertFrom-Json -AsHashtable
    $Target.CreatedAfterUtc=([DateTimeOffset]$Target.CreatedAfterUtc).ToUniversalTime().ToString('o')
    $hash=Get-LabCpuFaultHash (ConvertTo-LabCpuFaultCanonicalJson $Target)
    $result=[ordered]@{ContractVersion='SqlServerLab.InternalContainerMemoryFaultResult/0.1'; OperationId=$Target.OperationId; Profile='container.memory-limit'; Status='CANCELLED'; PrimaryStatus='CANCELLED'; CleanupStatus='NOT_REQUIRED'; AppliedVerified=$false; LimitRestoredVerified=$false; SqlRestoredVerified=$false}
    if (-not $Resume -and $CancellationToken.IsCancellationRequested) { return [pscustomobject]$result }
    $directory=[IO.Path]::GetFullPath($JournalDirectory)
    Assert-LabCpuFaultPath $directory
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) { throw 'MEMORY_FAULT_DIRECTORY_REQUIRED' }
    $path=Join-Path $directory ($Target.OperationId+'.memory-fault.json')
    $lockPath=Join-Path $directory ($Target.OperationId+'.memory-fault.lock')
    Assert-LabCpuFaultPath $lockPath
    $lock=$null
    try {
        try { $lock=[IO.File]::Open($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None) }
        catch { throw 'MEMORY_FAULT_LOCK_UNAVAILABLE' }
        $authentication=''
        if ($Resume) {
            $state=Read-LabMemoryFaultJournal $path $OwnershipKey $hash
            $authentication=([IO.File]::ReadAllText($path) | ConvertFrom-Json).Authentication
            $binding=$state.Runtime
        } else {
            if (Test-Path -LiteralPath $path) { throw 'MEMORY_FAULT_OPERATION_EXISTS' }
            $binding=New-LabCpuFaultRuntimeBinding $Target.Provider
            $baseline=Get-LabMemoryFaultSnapshot $binding $Target -Fresh -RequireRunning
            Assert-LabMemoryFaultBaseline $baseline
            Test-LabMemoryFaultSql $binding $Target $Password
            $state=[ordered]@{ContractVersion='SqlServerLab.InternalContainerMemoryFaultJournal/0.1'; Profile='container.memory-limit'; Target=$Target; TargetHash=$hash; Runtime=$binding; Baseline=$baseline; RestoreIntent=$true; Status='RESTORE_REQUIRED'; PrimaryStatus='NOT_EXECUTED'; CleanupStatus='PENDING'; CleanupAttempts=0; AppliedVerified=$false; LimitRestoredVerified=$false; SqlRestoredVerified=$false}
            $authentication=Write-LabMemoryFaultJournal $path $OwnershipKey $state $authentication
        }
        if ($state.Status -ne 'COMPLETED' -and $state.CleanupAttempts -lt 3) {
            if ($Resume -and $state.PrimaryStatus -eq 'NOT_EXECUTED') { $state.PrimaryStatus='INTERRUPTED' }
            try {
                if (-not $Resume) {
                    if ($CancellationToken.IsCancellationRequested) { $state.PrimaryStatus='CANCELLED' }
                    else {
                        if ((Get-LabCpuFaultRuntimeIdentity $binding) -cne $binding.Identity) { throw 'MEMORY_FAULT_RUNTIME_CHANGED' }
                        $before=Get-LabMemoryFaultSnapshot $binding $Target -Fresh -RequireRunning
                        if ((ConvertTo-LabCpuFaultCanonicalJson $before) -cne (ConvertTo-LabCpuFaultCanonicalJson $state.Baseline)) { throw 'MEMORY_FAULT_BASELINE_CHANGED' }
                        if ($CancellationToken.IsCancellationRequested) { $state.PrimaryStatus='CANCELLED' }
                        else {
                            $clock=[Diagnostics.Stopwatch]::StartNew()
                            Set-LabMemoryFaultLimit $binding $Target
                            $applied=Get-LabMemoryFaultSnapshot $binding $Target -RequireRunning -TimeoutMilliseconds 1000
                            if ($applied.Created -cne $baseline.Created -or $applied.Image -cne $baseline.Image -or $applied.CgroupVersion -cne $baseline.CgroupVersion -or (ConvertTo-LabCpuFaultCanonicalJson $applied.Memory) -cne (ConvertTo-LabCpuFaultCanonicalJson (Get-LabMemoryFaultAppliedMemory $baseline))) { throw 'MEMORY_FAULT_APPLIED_POSTCONDITION_FAILED' }
                            $state.AppliedVerified=$true
                            $authentication=Write-LabMemoryFaultJournal $path $OwnershipKey $state $authentication
                            Wait-LabMemoryFaultTestCheckpoint
                            if ($CancellationToken.IsCancellationRequested) { $state.PrimaryStatus='CANCELLED' }
                            else {
                                Test-LabMemoryFaultSql $binding $Target $Password -TimeoutMilliseconds 1000
                                $state.PrimaryStatus=if ($CancellationToken.IsCancellationRequested) { 'CANCELLED' } elseif ($clock.ElapsedMilliseconds -ge 5000) { 'TIMED_OUT' } else { 'PASSED' }
                            }
                        }
                    }
                }
            } catch { $state.PrimaryStatus=if ($_.Exception.Message -eq 'CPU_FAULT_NATIVE_TIMEOUT') { 'TIMED_OUT' } else { 'EXECUTION_FAILED' } }
            finally {
                try {
                    $null=Read-LabMemoryFaultJournal $path $OwnershipKey $hash
                    $state.CleanupAttempts++; $state.CleanupStatus='IN_PROGRESS'
                    $state.LimitRestoredVerified=$false; $state.SqlRestoredVerified=$false
                    $authentication=Write-LabMemoryFaultJournal $path $OwnershipKey $state $authentication
                    if ((Get-LabCpuFaultRuntimeIdentity $binding) -cne $binding.Identity) { throw 'MEMORY_FAULT_RUNTIME_CHANGED' }
                    # Stopping cannot suppress rollback. Identity and ownership still apply.
                    $current=Get-LabMemoryFaultSnapshot $binding $Target
                    if ($current.Created -cne $state.Baseline.Created -or $current.Image -cne $state.Baseline.Image -or $current.CgroupVersion -cne $state.Baseline.CgroupVersion) { throw 'MEMORY_FAULT_IDENTITY_MISMATCH' }
                    $raw=ConvertTo-LabCpuFaultCanonicalJson $current.Memory
                    $original=ConvertTo-LabCpuFaultCanonicalJson $state.Baseline.Memory
                    if ($raw -cne $original -and $raw -cne (ConvertTo-LabCpuFaultCanonicalJson (Get-LabMemoryFaultAppliedMemory $state.Baseline))) { throw 'MEMORY_FAULT_UNEXPECTED_MEMORY_DRIFT' }
                    if ($raw -cne $original) { Set-LabMemoryFaultLimit $binding $Target -Restore }
                    $restored=Get-LabMemoryFaultSnapshot $binding $Target
                    if ($restored.Created -cne $state.Baseline.Created -or $restored.Image -cne $state.Baseline.Image -or $restored.CgroupVersion -cne $state.Baseline.CgroupVersion -or (ConvertTo-LabCpuFaultCanonicalJson $restored.Memory) -cne $original) { throw 'MEMORY_FAULT_RESTORE_POSTCONDITION_FAILED' }
                    $state.LimitRestoredVerified=$true
                    # Durable limit evidence survives SQL failure or a stopped container.
                    $authentication=Write-LabMemoryFaultJournal $path $OwnershipKey $state $authentication
                    if (-not $restored.Running) { throw 'MEMORY_FAULT_SQL_NOT_READY' }
                    Test-LabMemoryFaultSql $binding $Target $Password
                    $state.SqlRestoredVerified=$true; $state.CleanupStatus='PASSED'; $state.Status='COMPLETED'
                } catch { $state.CleanupStatus='FAILED'; $state.Status='RECOVERY_REQUIRED' }
                try { $authentication=Write-LabMemoryFaultJournal $path $OwnershipKey $state $authentication }
                catch { $state.CleanupStatus='FAILED'; $state.Status='RECOVERY_REQUIRED' }
            }
        }
        foreach ($name in @('PrimaryStatus','CleanupStatus','AppliedVerified','LimitRestoredVerified','SqlRestoredVerified')) { $result[$name]=$state[$name] }
        $result.Status=if ($state.Status -eq 'COMPLETED') { $state.PrimaryStatus } else { 'RECOVERY_REQUIRED' }
        return [pscustomobject]$result
    } finally { if ($lock) { $lock.Dispose() } }
}
