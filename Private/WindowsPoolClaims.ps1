<#
Windows reserve members use their existing run-state as the only authority.
Operation files are write-ahead intents; VM Notes contain a locator, never a claim.
#>
# Load the read-only Windows path probe before any canonical root lock is held.
if($IsWindows -and -not ('SqlServerLab.WindowsPoolRootProbe' -as [type])){
    try { Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
namespace SqlServerLab {
    public static class WindowsPoolRootProbe {
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        static extern uint QueryDosDevice(string name, StringBuilder value, int capacity);
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        static extern SafeFileHandle CreateFile(string path, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        static extern uint GetFinalPathNameByHandle(SafeFileHandle handle, StringBuilder value, uint capacity, uint flags);
        public static string Device(string drive) {
            var value=new StringBuilder(4096);
            return QueryDosDevice(drive,value,value.Capacity)>0 ? value.ToString() : null;
        }
        public static string FinalDirectory(string path) {
            using(var handle=CreateFile(path,0,7,IntPtr.Zero,3,0x02000000,IntPtr.Zero)) {
                if(handle.IsInvalid) return null;
                var value=new StringBuilder(32768);
                uint length=GetFinalPathNameByHandle(handle,value,(uint)value.Capacity,0);
                return length>0 && length<value.Capacity ? value.ToString() : null;
            }
        }
    }
}
'@ -ErrorAction Stop } catch {
        # Unsupported platform interop blocks pool-locality proof when requested;
        # ordinary non-pool module import and lifecycle remain available.
        $script:LabWindowsPoolRootProbeUnavailable=$true
    }
}

function Resolve-LabWindowsPoolRoot {
    [CmdletBinding()]
    param([string]$StateRoot)
    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
    $full = [IO.Path]::GetFullPath($StateRoot)
    $root = $full.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    if($root -ceq [IO.Path]::GetPathRoot($full).TrimEnd('\','/') -or -not $root){$root=[IO.Path]::GetPathRoot($full)}
    $cursor = $root
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'WINDOWS_POOL_ROOT_REPARSE' }
        }
        $parent = Split-Path -Parent $cursor
        if ($parent -eq $cursor) { break }; $cursor = $parent
    }
    return $(if ($IsWindows) { $root.ToLowerInvariant() } else { $root })
}

function Get-LabWindowsPoolLocalDriveIdentity {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DriveRoot)
    [pscustomobject]@{Type=[IO.DriveInfo]::new($DriveRoot).DriveType;Device=[SqlServerLab.WindowsPoolRootProbe]::Device($DriveRoot.TrimEnd('\'))}
}

function Assert-LabWindowsPoolRootSupport {
    [CmdletBinding()]
    param([string]$StateRoot)
    if(-not $StateRoot){$StateRoot=Get-LabStateRoot}
    $full=[IO.Path]::GetFullPath($StateRoot)
    if($full.TrimEnd('\','/') -ceq [IO.Path]::GetPathRoot($full).TrimEnd('\','/')){throw 'WINDOWS_POOL_ROOT_TOO_BROAD'}
    # This check is lexical and precedes filesystem access at pool entrances.
    # The host-wide mutex does not provide exclusion across a network share.
    if($IsWindows -and $full.StartsWith('\\',[StringComparison]::Ordinal)){throw 'WINDOWS_POOL_NETWORK_ROOT_UNSUPPORTED'}
    if($IsWindows){
        try{
            $driveRoot=[IO.Path]::GetPathRoot($full)
            $identity=Get-LabWindowsPoolLocalDriveIdentity -DriveRoot $driveRoot
            if($identity.Type -ne [IO.DriveType]::Fixed){throw 'LOCALITY'}
            if(-not $identity.Device -or $identity.Device -cnotmatch '^\\Device\\HarddiskVolume[0-9]+$'){throw 'ALIAS'}
            # Inspect from the local volume outward, stopping before a reparse
            # ancestor can redirect a deeper filesystem probe to another root.
            $ancestor=$driveRoot
            foreach($segment in $full.Substring($driveRoot.Length).Split([char]'\',[StringSplitOptions]::RemoveEmptyEntries)){
                $candidate=Join-Path $ancestor $segment
                if(-not(Test-Path -LiteralPath $candidate)){break}
                $entry=Get-Item -LiteralPath $candidate -Force -ErrorAction Stop
                if($entry.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'REPARSE'}
                if(-not $entry.PSIsContainer){throw 'NOT_DIRECTORY'}
                $ancestor=$candidate
            }
            $final=[SqlServerLab.WindowsPoolRootProbe]::FinalDirectory($ancestor)
            if(-not $final -or -not $final.StartsWith('\\?\',[StringComparison]::Ordinal)){throw 'UNKNOWN'}
            $final=$final.Substring(4).TrimEnd('\');$expected=$ancestor.TrimEnd('\')
            if(-not [string]::Equals($final,$expected,[StringComparison]::OrdinalIgnoreCase)){throw 'ALIAS'}
        }catch{throw 'WINDOWS_POOL_ROOT_LOCALITY_UNSUPPORTED'}
    }
}

function Invoke-WithLabWindowsPoolLock {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StateRoot, [Parameter(Mandatory)][scriptblock]$Body)
    $root = Resolve-LabWindowsPoolRoot -StateRoot $StateRoot
    $key = Get-LabWorkflowHash -Text $(if ($IsWindows) { $root.ToLowerInvariant() } else { $root }) -Length 32
    $name = $(if ($IsWindows) { 'Global\' } else { '' }) + 'SQL_Server_Lab_Windows_Pool_' + $key
    $mutex = [Threading.Mutex]::new($false, $name); $acquired = $false
    try {
        try { $acquired = $mutex.WaitOne(10000) } catch [Threading.AbandonedMutexException] { $acquired = $true }
        if (-not $acquired) { throw 'WINDOWS_POOL_LOCKED' }
        if ((Resolve-LabWindowsPoolRoot -StateRoot $StateRoot) -cne $root) { throw 'WINDOWS_POOL_ROOT_CHANGED' }
        & $Body
    } finally { if ($acquired) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
}

function Invoke-WithLabWindowsPoolOperation {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][scriptblock]$Body)
    Assert-LabWindowsPoolRootSupport -StateRoot $Context.StateRoot
    $root = Resolve-LabWindowsPoolRoot -StateRoot $Context.StateRoot
    $operationGuid = [guid]::Empty
    if (-not [guid]::TryParseExact([string]$Context.OperationId, 'D', [ref]$operationGuid)) { throw 'WINDOWS_POOL_OPERATION_ID_INVALID' }
    $operationPath = Join-Path (Join-Path $root 'operations') ($Context.OperationId + '.json')
    if (-not (Test-LabPathWithinRoot -Root $root -Path $operationPath).Valid) { throw 'WINDOWS_POOL_OPERATION_PATH_INVALID' }
    $operation = Read-LabWorkflowJson -Path $operationPath
    if (-not $operation -or $operation.kind -ne 'WindowsPool' -or $operation.executor.poolId -cne $Context.PoolId) { throw 'WINDOWS_POOL_OPERATION_BINDING_INVALID' }
    if($operation.executor.purpose -cne 'Prepare' -and $operation.runId -cne $Context.RunId){throw 'WINDOWS_POOL_OPERATION_RUN_BINDING_INVALID'}
    $key = Get-LabWorkflowHash -Text ($root + ':' + $Context.OperationId) -Length 32
    $mutex = [Threading.Mutex]::new($false, ($(if ($IsWindows) { 'Global\' } else { '' }) + 'SQL_Server_Lab_Windows_Pool_Execution_' + $key))
    $acquired = $false; $previous = $script:LabWindowsPoolContext
    try {
        try { $acquired = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $acquired = $true }
        if (-not $acquired) { throw 'WINDOWS_POOL_OPERATION_RUNNING' }
        $script:LabWindowsPoolContext = $Context
        & $Body
    } finally { $script:LabWindowsPoolContext = $previous; if ($acquired) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
}

function Get-LabWindowsPoolMemberPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunId, [Parameter(Mandatory)][string]$StateRoot)
    Assert-LabWindowsPoolRootSupport -StateRoot $StateRoot
    $id = [guid]::Empty
    if (-not [guid]::TryParseExact($RunId, 'D', [ref]$id)) { throw 'WINDOWS_POOL_RUN_ID_INVALID' }
    $root = Resolve-LabWindowsPoolRoot -StateRoot $StateRoot
    $path = Join-Path (Join-Path (Join-Path $root 'runs') $RunId) 'run-state.json'
    if (-not (Test-LabPathWithinRoot -Root $root -Path $path).Valid) { throw 'WINDOWS_POOL_STATE_PATH_INVALID' }
    return $path
}

function Assert-LabWindowsPoolMember {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Run)
    $member = $Run.metadata.windowsPoolMember
    if (-not $member) { return $null }
    foreach ($id in @($member.poolId, $member.creationOperationId, $member.runId, $member.scopeId, $member.evidenceEpoch)) {
        $parsed = [guid]::Empty
        if (-not [guid]::TryParseExact([string]$id, 'D', [ref]$parsed)) { throw 'WINDOWS_POOL_MEMBER_INVALID' }
    }
    if ($member.contractVersion -cne 'SqlServerLab.WindowsPoolMember/1.0' -or
        $member.runId -cne $Run.runId -or $member.scopeId -cne $Run.scopeId -or $member.provider -cne 'hyperv' -or
        [string]$Run.metadata.workflowKind -cne 'hyperv-lab' -or $member.imageArtifactId -cne $Run.metadata.imageArtifactId -or
        [int]$member.revision -lt 1 -or [int]$member.index -lt 1 -or
        $member.state -cnotin @('PREPARING','FREE','CLAIMED','RECOVERY_REQUIRED','CONSUMED','REMOVED')) { throw 'WINDOWS_POOL_MEMBER_INVALID' }
    if($member.vmId -or $member.state -in @('FREE','CLAIMED','CONSUMED')){
        $parsed=[guid]::Empty
        if(-not [guid]::TryParseExact([string]$member.vmId,'D',[ref]$parsed) -or $parsed -eq [guid]::Empty){throw 'WINDOWS_POOL_VM_ID_INVALID'}
    }
    if($member.claim){
        foreach($id in @($member.claim.operationId,$member.claim.claimId)){$parsed=[guid]::Empty;if(-not [guid]::TryParseExact([string]$id,'D',[ref]$parsed)){throw 'WINDOWS_POOL_CLAIM_INVALID'}}
        if($member.claim.purpose -cnotin @('Prepare','Claim','Cleanup') -or $member.claim.providerMutationStarted -isnot [bool]){throw 'WINDOWS_POOL_CLAIM_INVALID'}
    }
    if ($member.state -in @('PREPARING','CLAIMED','RECOVERY_REQUIRED') -and -not $member.claim) { throw 'WINDOWS_POOL_CLAIM_MISSING' }
    if ($member.state -eq 'FREE' -and $member.claim) { throw 'WINDOWS_POOL_FREE_MEMBER_CLAIMED' }
    if ($member.instanceId -cne 'primary' -or $member.imageArtifactId -notmatch '^hyperv-os-sealed-[a-f0-9]{64}$') { throw 'WINDOWS_POOL_MEMBER_TUPLE_INVALID' }
    return $member
}

function Test-LabWindowsPoolOperationContext {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Member, [Parameter(Mandatory)][string]$StateRoot)
    $context = $script:LabWindowsPoolContext
    return $context -and $context.StateRoot -ceq (Resolve-LabWindowsPoolRoot -StateRoot $StateRoot) -and
        $context.PoolId -ceq $Member.poolId -and $Member.claim -and $context.OperationId -ceq $Member.claim.operationId -and
        ($context.RunId -ceq $Member.runId -or ($context.Kind -ceq 'Prepare' -and -not $context.RunId -and $Member.creationOperationId -ceq $context.OperationId))
}

function Assert-LabWindowsPoolMutationAllowed {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunId, [string]$StateRoot, [switch]$InvalidateEvidence)
    $root = Resolve-LabWindowsPoolRoot -StateRoot $StateRoot
    $path = Join-Path (Join-Path (Join-Path $root 'runs') $RunId) 'run-state.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return }
    if (-not (Test-LabPathWithinRoot -Root $root -Path $path).Valid) { throw 'WINDOWS_POOL_STATE_PATH_INVALID' }
    Invoke-WithLabWindowsPoolLock -StateRoot $root -Body {
        $run = Read-LabWorkflowJson -Path $path; $member = Assert-LabWindowsPoolMember -Run $run
        if($member){Assert-LabWindowsPoolRootSupport -StateRoot $root}
        if (-not $member -or $member.state -in @('CONSUMED','REMOVED')) { return }
        if (-not (Test-LabWindowsPoolOperationContext -Member $member -StateRoot $root)) { throw 'WINDOWS_POOL_MEMBER_RESERVED' }
        if ($InvalidateEvidence -and ($member.evidence -or -not $member.claim.providerMutationStarted)) {
            $member.claim.providerMutationStarted = $true
            $member.evidenceEpoch = [guid]::NewGuid().ToString(); $member.evidence = $null; $member.revision++
            Write-LabArtifactJsonAtomicRaw -Path $path -InputObject $run
        }
    }
}

function Write-LabWindowsPoolRunState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$InputObject)
    $directory = Split-Path -Parent $Path; $root = Split-Path -Parent (Split-Path -Parent $directory)
    $root = Resolve-LabWindowsPoolRoot -StateRoot $root
    Invoke-WithLabWindowsPoolLock -StateRoot $root -Body {
        if (-not (Test-LabPathWithinRoot -Root $root -Path $Path).Valid) { throw 'WINDOWS_POOL_STATE_PATH_INVALID' }
        $current = Read-LabWorkflowJson -Path $Path
        if ($current -and $current.metadata.windowsPoolMember) {
            Assert-LabWindowsPoolRootSupport -StateRoot $root
            $member = Assert-LabWindowsPoolMember -Run $current
            if ($InputObject.runId -cne $current.runId -or $InputObject.scopeId -cne $current.scopeId) { throw 'WINDOWS_POOL_STATE_BINDING_CHANGED' }
            # Protected fields are never supplied by snapshot writers, even by the owning worker.
            if (-not $InputObject.metadata.windowsPoolMember -or [int]$InputObject.metadata.windowsPoolMember.revision -ne [int]$member.revision) { throw 'WINDOWS_POOL_STATE_SNAPSHOT_STALE' }
            if ($member.state -notin @('CONSUMED','REMOVED') -and
                -not (Test-LabWindowsPoolOperationContext -Member $member -StateRoot $root)) { throw 'WINDOWS_POOL_MEMBER_RESERVED' }
            $InputObject.metadata.windowsPoolMember = $member
            if($member.state -ceq 'CONSUMED' -and $InputObject.state -ceq 'REMOVED'){$member.state='REMOVED';$member.evidence=$null;$member.revision++}
        } elseif ($InputObject.metadata.windowsPoolMember) {
            Assert-LabWindowsPoolRootSupport -StateRoot $root
            $member = Assert-LabWindowsPoolMember -Run $InputObject
            if ($member.state -cne 'PREPARING' -or -not (Test-LabWindowsPoolOperationContext -Member $member -StateRoot $root)) { throw 'WINDOWS_POOL_REGISTRATION_CONTEXT_REQUIRED' }
        }
        Write-LabArtifactJsonAtomicRaw -Path $Path -InputObject $InputObject
    }
}

function New-LabWindowsPoolMemberMetadata {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunId, [Parameter(Mandatory)][string]$ScopeId, [Parameter(Mandatory)]$Metadata, [Parameter(Mandatory)][string]$StateRoot)
    $context = $script:LabWindowsPoolContext
    if (-not $context -or $context.Kind -cne 'Prepare') { return }
    if ($context.StateRoot -cne (Resolve-LabWindowsPoolRoot -StateRoot $StateRoot) -or $Metadata.workflowKind -cne 'hyperv-lab' -or $Metadata.workload -cne 'windows') { throw 'WINDOWS_POOL_CREATE_BINDING_INVALID' }
    $Metadata.windowsPoolMember = [pscustomobject][ordered]@{
        contractVersion='SqlServerLab.WindowsPoolMember/1.0';poolId=$context.PoolId;creationOperationId=$context.OperationId
        index=$context.Index;runId=$RunId;scopeId=$ScopeId;instanceId='primary';provider='hyperv';vmId=$null
        imageArtifactId=$Metadata.imageArtifactId;revision=1;state='PREPARING';evidenceEpoch=[guid]::NewGuid().ToString();evidence=$null
        claim=[pscustomobject]@{claimId=[guid]::NewGuid().ToString();operationId=$context.OperationId;purpose='Prepare';providerMutationStarted=$false}
    }
    $operationPath=Join-Path (Join-Path $context.StateRoot 'operations') ($context.OperationId+'.json')
    $operation=Read-LabWorkflowJson -Path $operationPath
    $operation.executor.members=@($operation.executor.members)+@([pscustomobject]@{index=$context.Index;runId=$RunId;scopeId=$ScopeId})
    Write-LabArtifactJsonAtomicRaw -Path $operationPath -InputObject $operation
}

function Set-LabWindowsPoolMemberState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunId,[Parameter(Mandatory)][string]$StateRoot,[Parameter(Mandatory)][int]$ExpectedRevision,[Parameter(Mandatory)][scriptblock]$Change)
    $path = Get-LabWindowsPoolMemberPath -RunId $RunId -StateRoot $StateRoot
    Invoke-WithLabWindowsPoolLock -StateRoot $StateRoot -Body {
        $run = Read-LabWorkflowJson -Path $path; $member = Assert-LabWindowsPoolMember -Run $run
        if (-not $member -or [int]$member.revision -ne $ExpectedRevision) { throw 'WINDOWS_POOL_PREVIEW_STALE' }
        $context=$script:LabWindowsPoolContext;$root=Resolve-LabWindowsPoolRoot -StateRoot $StateRoot
        if(-not $context -or $context.StateRoot -cne $root -or $context.PoolId -cne $member.poolId){throw 'WINDOWS_POOL_MEMBER_CONTEXT_REQUIRED'}
        $owned=Test-LabWindowsPoolOperationContext -Member $member -StateRoot $root
        $newClaim=$member.state -ceq 'FREE' -and $context.Kind -in @('Claim','Prepare','Cleanup')
        $cleanupTakeover=$context.Kind -ceq 'Cleanup' -and $script:LabWindowsPoolCleanupSourceId -ceq $(if($member.claim){$member.claim.operationId}else{$member.creationOperationId})
        if(-not ($owned -or $newClaim -or $cleanupTakeover)){throw 'WINDOWS_POOL_MEMBER_RESERVED'}
        & $Change $member
        $member.revision++; $null = Assert-LabWindowsPoolMember -Run $run
        Write-LabArtifactJsonAtomicRaw -Path $path -InputObject $run
        return $member
    }
}

function Get-LabWindowsPoolBoundMember {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunId,[Parameter(Mandatory)][string]$StateRoot,[switch]$RequireOff)
    $root=Resolve-LabWindowsPoolRoot -StateRoot $StateRoot; $path=Get-LabWindowsPoolMemberPath -RunId $RunId -StateRoot $root
    $run=Read-LabWorkflowJson -Path $path; $member=Assert-LabWindowsPoolMember -Run $run
    if (-not $member) { throw 'WINDOWS_POOL_MEMBERSHIP_REQUIRED' }
    $connectionPath=Join-Path (Split-Path -Parent $path) 'connection-info.json'
    if (-not (Test-LabPathWithinRoot -Root $root -Path $connectionPath).Valid) { throw 'WINDOWS_POOL_CONNECTION_PATH_INVALID' }
    $connection=Read-LabWorkflowJson -Path $connectionPath; $instances=@($connection.instances)
    if ($instances.Count -ne 1 -or $instances[0].id -cne $member.instanceId -or $instances[0].provider -cne 'hyperv' -or
        $instances[0].imageArtifactId -cne $member.imageArtifactId -or -not $instances[0].vmId -or
        ($member.vmId -and $instances[0].vmId -cne $member.vmId)) { throw 'WINDOWS_POOL_INSTANCE_BINDING_INVALID' }
    $instance=$instances[0];$managed=Get-HyperVManagedVM -VMName $instance.vmName -ExpectedRunId $RunId -ExpectedScopeId $run.scopeId
    if (-not $managed -or [string]$managed.VM.Id -cne [string]$instance.vmId -or $managed.Identity.instanceId -cne $member.instanceId) { throw 'WINDOWS_POOL_VM_BINDING_INVALID' }
    Assert-LabWindowsPoolNotes -Identity $managed.Identity -StateRoot $root -Run $run
    if ($RequireOff -and ([string]$managed.VM.State -cne 'Off' -or $run.state -cne 'STOPPED')) { throw 'WINDOWS_POOL_VM_MUST_BE_OFF' }
    if ($run.metadata.automatedTestEnvironment -or $run.metadata.testGroupId -or $managed.Identity.lifecycle -cne 'run' -or
        (Test-LabAutomatedTestEnvironmentRun -RunId $RunId)) { throw 'WINDOWS_POOL_PROTECTED_RUN' }
    $artifact=Get-HyperVImageArtifact -ArtifactId $member.imageArtifactId -StateRoot $root -SkipIntegrityCheck
    if (-not $artifact -or $artifact.artifactState -cne 'OS_SEALED' -or -not $artifact.generalized) { throw 'WINDOWS_POOL_ARTIFACT_INVALID' }
    $disks=@(Get-VMHardDiskDrive -VM $managed.VM -ErrorAction Stop)
    $pathComparison=if($IsWindows){[StringComparison]::OrdinalIgnoreCase}else{[StringComparison]::Ordinal}
    if ($disks.Count -ne 1 -or -not [string]::Equals([IO.Path]::GetFullPath([string]$disks[0].Path),[IO.Path]::GetFullPath([string]$managed.Identity.childVhdxPath),$pathComparison) -or
        @(Get-VMSnapshot -VM $managed.VM -ErrorAction Stop).Count) { throw 'WINDOWS_POOL_DISK_BINDING_INVALID' }
    $vhd=Get-VHD -Path ([string]$disks[0].Path) -ErrorAction Stop
    if (-not $vhd.ParentPath -or -not [string]::Equals([IO.Path]::GetFullPath([string]$vhd.ParentPath),[IO.Path]::GetFullPath([string]$artifact.Path),$pathComparison)) { throw 'WINDOWS_POOL_PARENT_BINDING_INVALID' }
    $parent=Get-Item -LiteralPath $artifact.Path -Force -ErrorAction Stop
    if (-not $parent.IsReadOnly -or ($parent.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'WINDOWS_POOL_PARENT_NOT_IMMUTABLE' }
    $fingerprint=Get-LabWorkflowHash -Text ($artifact.artifactId+':'+$artifact.sha256+':'+$parent.Length+':'+$parent.LastWriteTimeUtc.Ticks) -Length 64
    [pscustomobject]@{Run=$run;Member=$member;Instance=$instance;Managed=$managed;Artifact=$artifact;ParentFingerprint=$fingerprint;StateRoot=$root;RunDirectory=(Split-Path -Parent $path)}
}

function Assert-LabWindowsPoolNotes {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Identity,[Parameter(Mandatory)][string]$StateRoot,[Parameter(Mandatory)]$Run)
    $member=Assert-LabWindowsPoolMember -Run $Run;$root=Resolve-LabWindowsPoolRoot -StateRoot $StateRoot
    $hint=$Identity.windowsPoolMember
    if (-not $hint -or $hint.stateRoot -cne $root -or $hint.poolId -cne $member.poolId -or
        $Identity.runId -cne $member.runId -or $Identity.scopeId -cne $member.scopeId -or $Identity.instanceId -cne $member.instanceId) { throw 'WINDOWS_POOL_NOTES_BINDING_INVALID' }
}

function Assert-LabWindowsPoolProviderMutation {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Managed,[string]$StateRoot)
    $hint=$Managed.Identity.windowsPoolMember
    # Do not open a hinted root: only a separately selected root/context is trusted.
    $root=if($StateRoot){Resolve-LabWindowsPoolRoot -StateRoot $StateRoot}elseif($script:LabWindowsPoolContext){$script:LabWindowsPoolContext.StateRoot}else{Resolve-LabWindowsPoolRoot}
    if ($hint -and $hint.stateRoot -cne $root) { throw 'WINDOWS_POOL_NOTES_ROOT_MISMATCH' }
    # Missing Notes cannot bypass membership in the independently selected root.
    if (-not $hint) {
        $candidate=Join-Path (Join-Path (Join-Path $root 'runs') ([string]$Managed.Identity.runId)) 'run-state.json'
        if (-not (Test-LabPathWithinRoot -Root $root -Path $candidate).Valid) { throw 'WINDOWS_POOL_STATE_PATH_INVALID' }
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            $buildCandidates=@('hyperv','hyperv-sql' | ForEach-Object {
                Join-Path $root "image-builds/$_/$($Managed.Identity.runId)/build-state.json"
            } | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
            if($buildCandidates.Count -eq 0){throw 'WINDOWS_POOL_PROVIDER_AUTHORITY_REQUIRED'}
            Assert-HyperVBuildProviderMutation -Managed $Managed -StateRoot $root
            return
        }
        $selectedRun=Read-LabWorkflowJson -Path $candidate
        if ($Managed.Identity.provider -cne 'hyperv' -or $selectedRun.runId -cne $Managed.Identity.runId -or $selectedRun.scopeId -cne $Managed.Identity.scopeId -or
            -not $selectedRun.runId -or -not $selectedRun.scopeId) { throw 'WINDOWS_POOL_PROVIDER_AUTHORITY_REQUIRED' }
        if (-not $selectedRun.metadata.windowsPoolMember) {
            $connectionPath=Join-Path (Split-Path -Parent $candidate) 'connection-info.json'
            if (-not (Test-LabPathWithinRoot -Root $root -Path $connectionPath).Valid -or
                -not (Test-Path -LiteralPath $connectionPath -PathType Leaf)) { throw 'WINDOWS_POOL_PROVIDER_AUTHORITY_REQUIRED' }
            $connection=Read-LabWorkflowJson -Path $connectionPath
            $instance=@($connection.instances | Where-Object {$_.provider -ceq 'hyperv' -and $_.id -ceq $Managed.Identity.instanceId})
            if($instance.Count -ne 1 -or -not $instance[0].vmId -or [string]$Managed.VM.Id -cne [string]$instance[0].vmId){throw 'WINDOWS_POOL_PROVIDER_AUTHORITY_REQUIRED'}
            return
        }
        throw 'WINDOWS_POOL_NOTES_BINDING_INVALID'
    }
    $path=Get-LabWindowsPoolMemberPath -RunId $Managed.Identity.runId -StateRoot $root
    $run=Read-LabWorkflowJson -Path $path
    Assert-LabWindowsPoolNotes -Identity $Managed.Identity -StateRoot $root -Run $run
    if ($run.metadata.windowsPoolMember.vmId -and [string]$Managed.VM.Id -cne $run.metadata.windowsPoolMember.vmId) { throw 'WINDOWS_POOL_VM_BINDING_INVALID' }
    Assert-LabWindowsPoolMutationAllowed -RunId $run.runId -StateRoot $root -InvalidateEvidence
}

# These read/modify/write operations hold only the canonical root mutex. The
# central writer re-enters that same mutex; no provider work or second lock is
# permitted here. Whole-run snapshot writers use member revision CAS instead.
function Set-LabRunState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunId,[Parameter(Mandatory)][string]$NewState,[string]$Reason='', [string]$StateRoot)
    $parameters=@{} + $PSBoundParameters
    $parameters.StateRoot=Resolve-LabWindowsPoolRoot -StateRoot $StateRoot
    Invoke-WithLabWindowsPoolLock -StateRoot $parameters.StateRoot -Body {
        Assert-LabWindowsPoolMutationAllowed -RunId $RunId -StateRoot $parameters.StateRoot
        Set-LabRunStateCore @parameters
    }
}

function Set-LabProviderSubRunState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunId,[Parameter(Mandatory)][string]$Provider,[Parameter(Mandatory)][string]$NewState,[string]$Reason='', [string]$StateRoot)
    $parameters=@{} + $PSBoundParameters
    $parameters.StateRoot=Resolve-LabWindowsPoolRoot -StateRoot $StateRoot
    Invoke-WithLabWindowsPoolLock -StateRoot $parameters.StateRoot -Body {
        Assert-LabWindowsPoolMutationAllowed -RunId $RunId -StateRoot $parameters.StateRoot
        Set-LabProviderSubRunStateCore @parameters
    }
}

function Add-LabRunError {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunId,[Parameter(Mandatory)][string]$Message,[string]$Component='', [string]$StateRoot)
    $parameters=@{} + $PSBoundParameters
    $parameters.StateRoot=Resolve-LabWindowsPoolRoot -StateRoot $StateRoot
    Invoke-WithLabWindowsPoolLock -StateRoot $parameters.StateRoot -Body { Add-LabRunErrorCore @parameters }
}

function Rename-LabRunDisplayName {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunId,[Parameter(Mandatory)][string]$DisplayName,[string]$StateRoot)
    $parameters=@{} + $PSBoundParameters
    $parameters.StateRoot=Resolve-LabWindowsPoolRoot -StateRoot $StateRoot
    Invoke-WithLabWindowsPoolLock -StateRoot $parameters.StateRoot -Body {
        Assert-LabWindowsPoolMutationAllowed -RunId $RunId -StateRoot $parameters.StateRoot
        Rename-LabRunDisplayNameCore @parameters
    }
}

function New-LabWindowsPoolOperationIntent {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$PoolId,[Parameter(Mandatory)][string]$Purpose,
        [Parameter(Mandatory)][string]$StateRoot,[string]$OperationId=([guid]::NewGuid().ToString()),[string]$RunId,
        [string]$ConfigurationKey)
    Assert-LabWindowsPoolRootSupport -StateRoot $StateRoot
    $root=Resolve-LabWindowsPoolRoot -StateRoot $StateRoot
    $null=Initialize-LabWorkflowStore -StateRoot $root
    $operation=New-LabOperationStateObject -OperationId $OperationId -BatchId $OperationId -ItemId $PoolId `
        -Title ('Windows-Pool: '+$Purpose) -Kind WindowsPool -Priority Normal -QueuePosition 0 -Provider hyperv `
        -ProviderReason 'ExplicitWindowsPoolSelection' -ResourceClass HyperV `
        -Executor ([pscustomobject]@{mode='InlineWindowsPool';poolId=$PoolId;purpose=$Purpose;configurationKey=$ConfigurationKey;members=@()}) `
        -Steps @(New-LabWorkflowStep -Id windows-pool -Action WindowsPool -Title $Purpose)
    # Inline operations never enter the generic scheduler. The operation mutex
    # determines execution ownership; Paused does not release a canonical claim.
    $operation.status='Paused';$operation.runId=$RunId
    $path=Join-Path (Join-Path $root 'operations') ($OperationId+'.json')
    Invoke-WithLabWindowsPoolLock -StateRoot $root -Body {
        if ($Purpose -ceq 'Prepare') {
            foreach($file in @(Get-ChildItem -LiteralPath (Join-Path $root 'operations') -File -Filter '*.json')) {
                if(-not (Test-LabPathWithinRoot -Root $root -Path $file.FullName).Valid){throw 'WINDOWS_POOL_OPERATION_PATH_INVALID'}
                $existing=Read-LabWorkflowJson -Path $file.FullName
                if($existing.kind -ceq 'WindowsPool' -and $existing.executor.poolId -ceq $PoolId -and $existing.executor.purpose -ceq 'Prepare'){throw 'WINDOWS_POOL_PREPARE_INTENT_ALREADY_EXISTS'}
            }
        }
        if (Test-Path -LiteralPath $path) { throw 'WINDOWS_POOL_OPERATION_ALREADY_EXISTS' }
        Write-LabArtifactJsonAtomicRaw -Path $path -InputObject $operation
    }
    return $operation
}

function Get-LabWindowsPoolPrepareIntent {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$PoolId,[Parameter(Mandatory)][string]$ConfigurationKey,[Parameter(Mandatory)][string]$StateRoot)
    $root=Resolve-LabWindowsPoolRoot -StateRoot $StateRoot
    $directory=Join-Path $root 'operations'
    $poolMatches=@(if(Test-Path -LiteralPath $directory){Get-ChildItem -LiteralPath $directory -File -Filter '*.json' | ForEach-Object {
        if (-not (Test-LabPathWithinRoot -Root $root -Path $_.FullName).Valid) { throw 'WINDOWS_POOL_OPERATION_PATH_INVALID' }
        Read-LabWorkflowJson -Path $_.FullName
    } | Where-Object {$_.kind -ceq 'WindowsPool' -and $_.executor.poolId -ceq $PoolId -and $_.executor.purpose -ceq 'Prepare'}})
    if ($poolMatches.Count -gt 1) { throw 'WINDOWS_POOL_PREPARE_INTENT_AMBIGUOUS' }
    if ($poolMatches.Count -eq 1) {
        if ($poolMatches[0].executor.configurationKey -cne $ConfigurationKey) { throw 'WINDOWS_POOL_RESUME_CONFIGURATION_CHANGED' }
        return $poolMatches[0]
    }
    New-LabWindowsPoolOperationIntent -PoolId $PoolId -Purpose Prepare -ConfigurationKey $ConfigurationKey -StateRoot $root
}

function Get-LabWindowsPoolEvidenceStatus {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Bound,[ValidateRange(0,3650)][int]$MinimumDaysRemaining=0,[ValidateRange(0,3650)][int]$WarningDaysRemaining=0)
    $member=$Bound.Member;$evidence=$member.evidence;$now=[datetime]::UtcNow
    $status='UNKNOWN';$expiry=$null;$observed=$null;$fresh=$null
    if($evidence){$observed=ConvertTo-LabWindowsPoolUtc $evidence.observedAt;$fresh=ConvertTo-LabWindowsPoolUtc $evidence.freshUntil;$expiry=ConvertTo-LabWindowsPoolUtc $evidence.evaluationExpiresAt}
    if ($evidence -and $evidence.contractVersion -ceq 'SqlServerLab.WindowsPoolEvidence/1.0' -and
        $evidence.poolId -ceq $member.poolId -and $evidence.runId -ceq $member.runId -and $evidence.scopeId -ceq $member.scopeId -and
        $evidence.instanceId -ceq $member.instanceId -and $evidence.vmId -ceq $member.vmId -and
        $evidence.imageArtifactId -ceq $member.imageArtifactId -and $evidence.evidenceEpoch -ceq $member.evidenceEpoch -and
        $Bound.ParentFingerprint -and $evidence.parentFingerprint -ceq $Bound.ParentFingerprint -and
        [int]$evidence.preparationRevision -gt 0 -and [int]$evidence.preparationRevision -le [int]$member.revision -and
        $observed -and $fresh -and $expiry -and $observed -le $now -and
        $fresh.ToUniversalTime() -eq $observed.ToUniversalTime().AddHours(24) -and $fresh.ToUniversalTime() -gt $now -and
        $evidence.licenseStatus -eq 1 -and $evidence.provisioningComplete -eq $true -and $evidence.localeVerified -eq $true) {
        $remaining=($expiry.ToUniversalTime()-$now).TotalDays
        $status=if($remaining -le 0){'EXPIRED'}elseif($remaining -lt $MinimumDaysRemaining){'BELOW_MINIMUM'}else{'CURRENT'}
    }
    [pscustomobject]@{Status=$status;VerifiedAvailable=($status -ceq 'CURRENT' -and $member.state -ceq 'FREE' -and -not $member.claim)
        Days=$(if($expiry){[Math]::Max(0,[int][Math]::Floor(($expiry.ToUniversalTime()-$now).TotalDays))}else{$null})
        Warning=$(if(-not $expiry){'UNKNOWN'}elseif(($expiry.ToUniversalTime()-$now).TotalDays -le $WarningDaysRemaining){'WARNING'}else{'CLEAR'})}
}

function ConvertTo-LabWindowsPoolUtc {
    [CmdletBinding()]
    param([AllowNull()]$Value)
    if($Value -is [datetime] -and $Value.Kind -ne [DateTimeKind]::Unspecified){return $Value.ToUniversalTime()}
    if($Value -is [datetimeoffset]){return $Value.UtcDateTime}
    if($Value -isnot [string] -or $Value -notmatch '^\d{4}-\d{2}-\d{2}T.*(?:Z|[+-]\d{2}:\d{2})$'){return $null}
    $parsed=[datetimeoffset]::MinValue
    if([datetimeoffset]::TryParse($Value,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$parsed)){return $parsed.UtcDateTime}
    return $null
}

function Get-LabWindowsPoolGuestReceipt {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Bound,[PSCredential]$Credential)
    if (-not (Test-LabWindowsPoolOperationContext -Member $Bound.Member -StateRoot $Bound.StateRoot)) { throw 'WINDOWS_POOL_CAPTURE_CONTEXT_REQUIRED' }
    if ([string]$Bound.Managed.VM.State -cne 'Running') { throw 'WINDOWS_POOL_CAPTURE_VM_MUST_BE_RUNNING' }
    if (-not $Credential) {
        $password=Get-LabSecret -Path $Bound.RunDirectory -Name guest-administrator-password
        if (-not $password) { throw 'WINDOWS_POOL_CAPTURE_CREDENTIAL_UNAVAILABLE' }
        $Credential=[PSCredential]::new('Administrator',$password)
    }
    $receipt=@(Invoke-HyperVPowerShellDirect -VMName $Bound.Managed.VM.Name -ExpectedRunId $Bound.Run.runId `
        -ExpectedScopeId $Bound.Run.scopeId -ExpectedVmId ([guid]$Bound.Managed.VM.Id) -Credential $Credential -TimeoutSeconds 90 -ScriptBlock {
            $ErrorActionPreference='Stop'
            $product=@(Get-CimInstance SoftwareLicensingProduct -Filter "ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f'" |
                Where-Object {$_.PartialProductKey -and -not $_.LicenseIsAddon} | Sort-Object LicenseStatus,GracePeriodRemaining -Descending)[0]
            $edition=(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').EditionID
            $setup=Get-ItemProperty 'HKLM:\SYSTEM\Setup'
            $observed=[datetime]::UtcNow
            $end=$null
            if($product.EvaluationEndDate){$value=if($product.EvaluationEndDate -is [datetime]){$product.EvaluationEndDate}else{[Management.ManagementDateTimeConverter]::ToDateTime([string]$product.EvaluationEndDate)};if($value.Year -ge 1970){$end=$value.ToUniversalTime().ToString('o')}}
            # The existing license probe normalizes pre-1970 dates to no
            # evaluation end. Such a sentinel must not suppress fresh grace.
            # Malformed explicit dates still throw; a real end keeps priority.
            if(-not $end -and $product -and [int]$product.GracePeriodRemaining -gt 0){$end=$observed.AddMinutes([int]$product.GracePeriodRemaining).ToString('o')}
            [pscustomobject]@{observedAt=$observed.ToString('o');licenseStatus=[int]$product.LicenseStatus
                evaluationExpiresAt=$end;edition=[string]$edition;systemLocale=(Get-WinSystemLocale).Name
                uiLanguage=[string](Get-UICulture).Name;timeZone=(Get-TimeZone).Id
                geoId=[int](Get-WinHomeLocation).GeoId
                inputLocales=@(Get-WinUserLanguageList | ForEach-Object {@($_.InputMethodTips)} | ForEach-Object {[string]$_})
                provisioningComplete=($setup.OOBEInProgress -eq 0 -and $setup.SystemSetupInProgress -eq 0)}
        })[-1]
    $locale=$Bound.Run.metadata.windowsLocale
    $observed=ConvertTo-LabWindowsPoolUtc $receipt.observedAt
    $expiry=ConvertTo-LabWindowsPoolUtc $receipt.evaluationExpiresAt
    # Preserve every acceptance predicate. Diagnostics contain only fixed field
    # codes; neither actual/expected guest values nor the raw receipt escape.
    $invalid=[ordered]@{
        RECEIPT_MISSING=(-not $receipt)
        EDITION_INVALID=($receipt.edition -notmatch '(?i)eval')
        OBSERVED_AT_INVALID=(-not $observed)
        OBSERVED_AT_FUTURE=($observed -and $observed -gt [datetime]::UtcNow)
        OBSERVED_AT_STALE=($observed -and $observed -lt [datetime]::UtcNow.AddHours(-24))
        EXPIRY_INVALID=(-not $expiry)
        EXPIRY_NOT_AFTER_CAPTURE=($expiry -and $observed -and $expiry -le $observed)
        LICENSE_STATUS_INVALID=($receipt.licenseStatus -ne 1)
        PROVISIONING_INCOMPLETE=(-not $receipt.provisioningComplete)
        LOCALE_INTENT_MISSING=(-not $locale)
        SYSTEM_LOCALE_MISMATCH=($receipt.systemLocale -ine $locale.SystemLocale)
        UI_LANGUAGE_MISMATCH=($receipt.uiLanguage -ine $locale.UiLanguage)
        TIME_ZONE_MISMATCH=($receipt.timeZone -cne $locale.TimeZone)
        GEO_ID_MISMATCH=($locale -and $receipt.geoId -ne [Globalization.RegionInfo]::new($locale.Region).GeoId)
        INPUT_LOCALE_MISMATCH=(@($receipt.inputLocales) -notcontains $locale.InputLocale)
    }
    $mismatchCodes=@($invalid.Keys | Where-Object {$invalid[$_]})
    if ($mismatchCodes.Count) {
        $failure=[InvalidOperationException]::new('WINDOWS_POOL_CAPTURE_EVIDENCE_INVALID')
        $failure.Data['WindowsPoolCaptureMismatchCodes']=$mismatchCodes
        throw $failure
    }
    return $receipt
}

function Get-LabWindowsPoolFailureCode {
    param([Parameter(Mandatory)]$Failure,[Parameter(Mandatory)][string]$Fallback)
    if($Failure.Exception.Message -match '^(?<code>(?:WINDOWS_POOL_|HYPERV_|SQL_)[A-Z0-9_]+)(?=:|\s|$)'){return $Matches.code}
    return $Fallback
}

function Write-LabWindowsPoolFailureReceipt {
    param([Parameter(Mandatory)]$Failure,[Parameter(Mandatory)]$Context,[Parameter(Mandatory)][string]$RunId,[Parameter(Mandatory)][string]$Stage)
    $run=Get-LabRunState -RunId $RunId -StateRoot $Context.StateRoot
    if(-not(Test-LabWindowsPoolOperationContext -Member $run.metadata.windowsPoolMember -StateRoot $Context.StateRoot)){throw 'WINDOWS_POOL_CAUSE_CONTEXT_REQUIRED'}
    $directory=Split-Path -Parent (Get-LabWindowsPoolMemberPath -RunId $RunId -StateRoot $Context.StateRoot)
    $path=Join-Path $directory ('windows-pool-cause-'+[guid]::NewGuid().ToString('N')+'.json')
    if(-not(Test-LabPathWithinRoot -Root $Context.StateRoot -Path $path).Valid){throw 'WINDOWS_POOL_CAUSE_SCOPE_INVALID'}
    # Fixed code/type/repository filename/line only: no exception message,
    # stack, credential, guest output or host diagnostic payload is persisted.
    Write-LabArtifactJsonAtomicRaw -Path $path -InputObject ([pscustomobject]@{
        contractVersion='SqlServerLab.WindowsPoolCause/1.0';runId=$run.runId;scopeId=$run.scopeId;operationId=$Context.OperationId;stage=$Stage
        code=(Get-LabWindowsPoolFailureCode -Failure $Failure -Fallback WINDOWS_POOL_PREPARATION_FAILED)
        exceptionType=$Failure.Exception.GetType().FullName;sourceFile=[IO.Path]::GetFileName([string]$Failure.InvocationInfo.ScriptName)
        sourceLine=$Failure.InvocationInfo.ScriptLineNumber;observedAt=[datetime]::UtcNow.ToString('o')
        captureMismatchCodes=@($Failure.Exception.Data['WindowsPoolCaptureMismatchCodes'] | Where-Object {
            $_ -is [string] -and $_ -cin @('RECEIPT_MISSING','EDITION_INVALID','OBSERVED_AT_INVALID','OBSERVED_AT_FUTURE','OBSERVED_AT_STALE',
                'EXPIRY_INVALID','EXPIRY_NOT_AFTER_CAPTURE','LICENSE_STATUS_INVALID','PROVISIONING_INCOMPLETE','LOCALE_INTENT_MISSING',
                'SYSTEM_LOCALE_MISMATCH','UI_LANGUAGE_MISMATCH','TIME_ZONE_MISMATCH','GEO_ID_MISMATCH','INPUT_LOCALE_MISMATCH')
        } | Select-Object -Unique)
    })
}

function Complete-LabWindowsPoolPreparation {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunId,[Parameter(Mandatory)][string]$StateRoot,[Parameter(Mandatory)]$Receipt,[switch]$KeepClaim)
    $bound=Get-LabWindowsPoolBoundMember -RunId $RunId -StateRoot $StateRoot -RequireOff
    if (-not (Test-LabWindowsPoolOperationContext -Member $bound.Member -StateRoot $StateRoot)) { throw 'WINDOWS_POOL_PREPARATION_CONTEXT_REQUIRED' }
    $observed=ConvertTo-LabWindowsPoolUtc $Receipt.observedAt
    if(-not $observed -or $observed -gt [datetime]::UtcNow){throw 'WINDOWS_POOL_CAPTURE_TIME_INVALID'}
    $journalPath=Join-Path (Join-Path $StateRoot 'operations') ($script:LabWindowsPoolContext.OperationId+'.json')
    $journal=Read-LabWorkflowJson -Path $journalPath
    $journal.receipts=@($journal.receipts)+@([pscustomobject]@{runId=$RunId;scopeId=$bound.Run.scopeId;stage='PreparedCommitPending';evidenceEpoch=$bound.Member.evidenceEpoch})
    Write-LabArtifactJsonAtomicRaw -Path $journalPath -InputObject $journal
    $null=Set-LabWindowsPoolMemberState -RunId $RunId -StateRoot $StateRoot -ExpectedRevision $bound.Member.revision -Change {
        param($member)
        if ($member.state -notin @('PREPARING','CLAIMED','RECOVERY_REQUIRED') -or
            ($KeepClaim -and $member.claim.purpose -cne 'Claim') -or (-not $KeepClaim -and $member.claim.purpose -cne 'Prepare')) { throw 'WINDOWS_POOL_PREPARATION_STATE_INVALID' }
        $member.vmId=[string]$bound.Managed.VM.Id
        $member.evidence=[pscustomobject]@{contractVersion='SqlServerLab.WindowsPoolEvidence/1.0';poolId=$member.poolId;runId=$member.runId
            scopeId=$member.scopeId;instanceId=$member.instanceId;vmId=$member.vmId;imageArtifactId=$member.imageArtifactId
            evidenceEpoch=$member.evidenceEpoch;parentFingerprint=$bound.ParentFingerprint;preparationRevision=([int]$member.revision+1);observedAt=$observed.ToString('o')
            freshUntil=$observed.AddHours(24).ToString('o');evaluationExpiresAt=$Receipt.evaluationExpiresAt
            licenseStatus=$Receipt.licenseStatus;provisioningComplete=$Receipt.provisioningComplete;localeVerified=$true}
        if($KeepClaim){$member.state='CLAIMED'}else{$member.state='FREE';$member.claim=$null}
    }
}

function ConvertTo-LabWindowsPoolCanonicalValue {
    param([AllowNull()]$Value)
    if($null -eq $Value){return $null}
    if($Value -is [Collections.IDictionary] -or $Value -is [pscustomobject]){
        $result=[ordered]@{}
        $names=if($Value -is [Collections.IDictionary]){@($Value.Keys)}else{@($Value.PSObject.Properties.Name)}
        foreach($name in @($names | Sort-Object -CaseSensitive)){$result[$name]=ConvertTo-LabWindowsPoolCanonicalValue $Value.$name}
        return $result
    }
    if($Value -is [Collections.IEnumerable] -and $Value -isnot [string]){return ,@($Value | ForEach-Object {ConvertTo-LabWindowsPoolCanonicalValue $_})}
    return $Value
}

function Get-LabWindowsPoolPlanKey {
    param([Parameter(Mandatory)]$Plan)
    Get-LabWorkflowHash -Text ((ConvertTo-LabWindowsPoolCanonicalValue $Plan) | ConvertTo-Json -Depth 20 -Compress) -Length 64
}

function New-LabWindowsPoolMemberPreview {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunId,[Parameter(Mandatory)][ValidateSet('Claim','Release','Stop','Refresh','Consume','Cleanup')][string]$Action,
        [string]$StateRoot,[object]$SqlDeploymentPlan)
    Assert-LabWindowsPoolRootSupport -StateRoot $StateRoot
    $Action=@('Claim','Release','Stop','Refresh','Consume','Cleanup') | Where-Object {$_ -ieq $Action} | Select-Object -First 1
    $root=Resolve-LabWindowsPoolRoot -StateRoot $StateRoot
    $bound=if($Action -ceq 'Cleanup'){Get-LabWindowsPoolCleanupBinding -RunId $RunId -StateRoot $root}else{Get-LabWindowsPoolBoundMember -RunId $RunId -StateRoot $root -RequireOff:($Action -cne 'Stop')}
    $member=$bound.Member;$policy=(Get-LabSlotReserveState).Policy
    $evidence=Get-LabWindowsPoolEvidenceStatus -Bound $bound -MinimumDaysRemaining $(if($policy){$policy.MinimumDaysRemaining}else{0})
    switch($Action){
        Claim {if(-not $evidence.VerifiedAvailable){throw 'WINDOWS_POOL_MEMBER_UNAVAILABLE'}}
        Release {if($member.state -notin @('CLAIMED','RECOVERY_REQUIRED') -or $member.claim.purpose -cne 'Claim' -or $member.claim.providerMutationStarted){throw 'WINDOWS_POOL_RELEASE_NOT_PROVEN_SAFE'}}
        Refresh {if($member.state -notin @('CLAIMED','RECOVERY_REQUIRED') -or $member.claim.purpose -cne 'Claim'){throw 'WINDOWS_POOL_REFRESH_CLAIM_REQUIRED'}}
        Stop {if($member.state -notin @('PREPARING','CLAIMED','RECOVERY_REQUIRED') -or -not $member.claim){throw 'WINDOWS_POOL_STOP_HELD_MEMBER_REQUIRED'}}
        Consume {if($member.state -cne 'CLAIMED' -or $evidence.Status -cne 'CURRENT' -or -not $SqlDeploymentPlan){throw 'WINDOWS_POOL_CONSUME_PLAN_REQUIRED'}
            $names=if($SqlDeploymentPlan -is [Collections.IDictionary]){@($SqlDeploymentPlan.Keys)}else{@($SqlDeploymentPlan.PSObject.Properties.Name)}
            $allowed=@('SqlVersion','DeploymentMode','MediaEdition','SqlMediaPath','SqlFeatures','ProcessorCount','MemoryStartupMB','MaximumDataIops','Collation','SqlPort','NetworkMode','ServerConfig','StorageConfiguration','SqlPatch','SqlUpdatePath','ExpectedSqlBuild')
            if(@($names | Where-Object {$_ -notin $allowed}).Count -or -not $SqlDeploymentPlan.SqlVersion -or -not $SqlDeploymentPlan.SqlMediaPath -or
                $SqlDeploymentPlan.DeploymentMode -notin @('sql-pool-slot','adhoc-install') -or $SqlDeploymentPlan.SqlVersion -notin @('2016','2017','2019','2022','2025') -or
                @($SqlDeploymentPlan.SqlFeatures).Count -eq 0 -or @($SqlDeploymentPlan.SqlFeatures) -notcontains 'SQLENGINE' -or
                @($SqlDeploymentPlan.SqlFeatures | Where-Object {$_ -notin @('SQLENGINE','FULLTEXT','REPLICATION','ADVANCEDANALYTICS')}).Count){throw 'WINDOWS_POOL_CONSUME_PLAN_INVALID'}
            # Validate and normalize before any write-ahead intent or provider work.
            $normalized=[ordered]@{MediaEdition='Enterprise';ProcessorCount=4;MemoryStartupMB=0;MaximumDataIops=0
                Collation='SQL_Latin1_General_CP1_CI_AS';SqlPort=1433;NetworkMode='host-access'}
            foreach($name in $names){$normalized[$name]=$SqlDeploymentPlan.$name}
            if($normalized.MediaEdition -notin @('Eval','Enterprise','Standard') -or $normalized.NetworkMode -notin @('host-access','isolated') -or
                [string]$normalized.Collation -cnotmatch '^[A-Za-z0-9_]{1,128}$'){throw 'WINDOWS_POOL_CONSUME_PLAN_INVALID'}
            foreach($range in @(@('ProcessorCount',1,64),@('MemoryStartupMB',0,1048576),@('MaximumDataIops',0,1000000),@('SqlPort',1,65535))){
                $number=0L
                if(-not [long]::TryParse([string]$normalized[$range[0]],[ref]$number) -or $number -lt $range[1] -or $number -gt $range[2]){throw 'WINDOWS_POOL_CONSUME_PLAN_INVALID'}
                $normalized[$range[0]]=$number
            }
            $normalized.SqlFeatures=@($normalized.SqlFeatures | ForEach-Object {([string]$_).ToUpperInvariant()} | Sort-Object -Unique)
            if($normalized.ServerConfig){
                $manifestSchema=Read-LabWorkflowJson -Path (Join-Path $script:SchemasPath lab-manifest.schema.json)
                $configSchema=@{'$ref'='#/definitions/serverConfig';definitions=$manifestSchema.definitions} | ConvertTo-Json -Depth 60
                $valid=$false
                try{$valid=($normalized.ServerConfig | ConvertTo-Json -Depth 20 | Test-Json -Schema $configSchema -ErrorAction Stop 2>$null)}catch{$valid=$false}
                if(-not $valid){throw 'WINDOWS_POOL_CONSUME_SERVER_CONFIG_INVALID'}
            }
            if($normalized.StorageConfiguration){
                $storage=$normalized.StorageConfiguration
                $storageNames=if($storage -is [Collections.IDictionary]){@($storage.Keys)}else{@($storage.PSObject.Properties.Name)}
                if(@($storageNames | Where-Object {$_ -notin @('dataPath','logPath','tempDbPaths','backupPath')}).Count){throw 'WINDOWS_POOL_CONSUME_STORAGE_CONFIG_INVALID'}
                foreach($value in @($storage.dataPath,$storage.logPath,$storage.backupPath)+@($storage.tempDbPaths)){
                    if($value -isnot [string] -or $value -cnotmatch '^[A-Za-z]:\\[^\r\n]+$'){throw 'WINDOWS_POOL_CONSUME_STORAGE_CONFIG_INVALID'}
                }
            }
            $SqlDeploymentPlan=[pscustomobject]$normalized
        }
        Cleanup {if($member.state -notin @('PREPARING','CLAIMED','RECOVERY_REQUIRED','FREE')){throw 'WINDOWS_POOL_CLEANUP_STATE_INVALID'}}
    }
    if (-not $script:LabWindowsPoolPreviews) { $script:LabWindowsPoolPreviews=@{} }
    $id=[guid]::NewGuid().ToString()
    $plan=[pscustomobject]@{previewId=$id;action=$Action;runId=$RunId;poolId=$member.poolId;stateRoot=$root;revision=[int]$member.revision
        rootSelection=$(if([string]::IsNullOrWhiteSpace($StateRoot)){'Default'}else{'Explicit'})
        evidenceEpoch=$member.evidenceEpoch;vmId=[string]$bound.Managed.VM.Id;claimOperationId=$(if($member.claim){$member.claim.operationId}else{$null})
        sourceOperationId=$(if($member.claim){$member.claim.operationId}else{$member.creationOperationId})
        cleanupKey=$(if($Action -ceq 'Cleanup'){$bound.CleanupKey}else{$null})
        expiresAt=[datetime]::UtcNow.AddMinutes(5);sqlDeploymentPlan=$SqlDeploymentPlan}
    # A private deep copy prevents a caller from editing the confirmed preview.
    $script:LabWindowsPoolPreviews[$id]=$plan | ConvertTo-Json -Depth 15 | ConvertFrom-Json -Depth 15
    [pscustomobject]@{PreviewId=$id;Action=$Action;RunId=$RunId;PoolId=$member.poolId;MemberState=$member.state;Revision=$member.revision
        VMName=$bound.Managed.VM.Name;VMState=[string]$bound.Managed.VM.State;Evidence=$evidence.Status;ProviderMutation=($Action -in @('Stop','Refresh','Consume','Cleanup'))
        SqlPlan=$SqlDeploymentPlan;Notice=$(if($Action -eq 'Cleanup'){'Nur dieses eigene Mitglied samt Child-VM/VHDX bereinigen; Fehler bleiben zur Recovery erhalten.'}elseif($Action -eq 'Stop'){'Diese eigene gebundene VM stoppen; Evidence verwerfen und Claim erhalten. Cleanup bleibt separat.'}else{'Die Bestätigung revalidiert Bindung, Revision, gestoppte VM und Evidence.'})}
}

function Invoke-LabWindowsPoolMemberPreview {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$PreviewId,[switch]$Confirm,[switch]$Cancel)
    if (-not $script:LabWindowsPoolPreviews -or -not $script:LabWindowsPoolPreviews.ContainsKey($PreviewId)) { throw 'WINDOWS_POOL_PREVIEW_NOT_HELD' }
    $plan=$script:LabWindowsPoolPreviews[$PreviewId]
    if ($Cancel) {$script:LabWindowsPoolPreviews.Remove($PreviewId);return [pscustomobject]@{Status='CANCELLED';ProviderMutation=$false}}
    if (-not $Confirm) {throw 'WINDOWS_POOL_CONFIRMATION_REQUIRED'}
    $script:LabWindowsPoolPreviews.Remove($PreviewId)
    if ([datetime]::UtcNow -ge [datetime]$plan.expiresAt) {throw 'WINDOWS_POOL_PREVIEW_EXPIRED'}
    if($plan.rootSelection -ceq 'Default' -and (Resolve-LabWindowsPoolRoot) -cne $plan.stateRoot){throw 'WINDOWS_POOL_SELECTED_ROOT_CHANGED'}
    $bound=if($plan.action -ceq 'Cleanup'){Get-LabWindowsPoolCleanupBinding -RunId $plan.runId -StateRoot $plan.stateRoot}else{Get-LabWindowsPoolBoundMember -RunId $plan.runId -StateRoot $plan.stateRoot -RequireOff:($plan.action -cne 'Stop')}
    if($bound.Member.revision -ne $plan.revision -or $bound.Member.evidenceEpoch -cne $plan.evidenceEpoch -or
        [string]$bound.Managed.VM.Id -cne $plan.vmId -or ($plan.action -ceq 'Cleanup' -and $bound.CleanupKey -cne $plan.cleanupKey)){throw 'WINDOWS_POOL_PREVIEW_STALE'}
    $policy=(Get-LabSlotReserveState).Policy
    $evidence=Get-LabWindowsPoolEvidenceStatus -Bound $bound -MinimumDaysRemaining $(if($policy){$policy.MinimumDaysRemaining}else{0})
    if($plan.action -in @('Claim','Consume') -and $evidence.Status -cne 'CURRENT'){throw 'WINDOWS_POOL_EVIDENCE_NOT_CURRENT'}
    $operation=if($plan.action -in @('Claim','Cleanup')){
        New-LabWindowsPoolOperationIntent -PoolId $plan.poolId -Purpose $plan.action -RunId $plan.runId -StateRoot $plan.stateRoot
    }else{Read-LabWorkflowJson -Path (Join-Path (Join-Path $plan.stateRoot 'operations') ($plan.claimOperationId+'.json'))}
    $context=[pscustomobject]@{StateRoot=$plan.stateRoot;PoolId=$plan.poolId;OperationId=$operation.operationId;RunId=$plan.runId;Kind=$plan.action}
    Invoke-WithLabWindowsPoolCleanupSource -Context $context -SourceOperationId $(if($plan.action -ceq 'Cleanup'){$plan.sourceOperationId}else{$null}) -Body {
        $member=$bound.Member
        if($plan.action -in @('Claim','Cleanup')){
            $member=Set-LabWindowsPoolMemberState -RunId $plan.runId -StateRoot $plan.stateRoot -ExpectedRevision $plan.revision -Change {
                param($current)
                if($plan.action -eq 'Claim' -and ($current.state -cne 'FREE' -or $current.claim)){throw 'WINDOWS_POOL_MEMBER_UNAVAILABLE'}
                $current.state=if($plan.action -eq 'Claim'){'CLAIMED'}else{'RECOVERY_REQUIRED'}
                $current.claim=[pscustomobject]@{claimId=[guid]::NewGuid().ToString();operationId=$operation.operationId;purpose=$plan.action;providerMutationStarted=$false}
            }
        }elseif($member.claim.operationId -cne $operation.operationId){throw 'WINDOWS_POOL_CLAIM_BINDING_INVALID'}
        $cleanupError=$null;$terminalState=$null
        try {
            switch($plan.action){
                Claim { $status='CLAIMED' }
                Release {
                    if($member.state -notin @('CLAIMED','RECOVERY_REQUIRED') -or $member.claim.purpose -cne 'Claim' -or $member.claim.providerMutationStarted){throw 'WINDOWS_POOL_RELEASE_NOT_PROVEN_SAFE'}
                    $terminalState='FREE';$status='RELEASED'
                }
                Consume {
                    $consumeKey=Get-LabWindowsPoolPlanKey -Plan $plan.sqlDeploymentPlan
                    if($operation.executor.consumeKey -and $operation.executor.consumeKey -cne $consumeKey){throw 'WINDOWS_POOL_CONSUME_RESUME_PLAN_CHANGED'}
                    $operation.executor | Add-Member -NotePropertyName consumeKey -NotePropertyValue $consumeKey -Force
                    $operation.executor | Add-Member -NotePropertyName consumePlan -NotePropertyValue $plan.sqlDeploymentPlan -Force
                    Write-LabArtifactJsonAtomicRaw -Path (Join-Path (Join-Path $plan.stateRoot 'operations') ($operation.operationId+'.json')) -InputObject $operation
                    $parameters=@{RunId=$plan.runId;StateRoot=$plan.stateRoot}
                    foreach($property in $plan.sqlDeploymentPlan.PSObject.Properties){$parameters[$property.Name]=$property.Value}
                    $null=Set-HyperVLabSqlDeploymentPlan @parameters
                    $fresh=Get-LabWindowsPoolBoundMember -RunId $plan.runId -StateRoot $plan.stateRoot -RequireOff
                    $sql=$fresh.Instance.sqlDeploymentPlan
                    $cpu=Get-VMProcessor -VM $fresh.Managed.VM -ErrorAction Stop
                    $memory=Get-VMMemory -VM $fresh.Managed.VM -ErrorAction Stop
                    if(-not $sql -or $sql.state -cne 'PLANNED' -or [int]$cpu.Count -ne [int]$sql.processorCount -or
                        ([int]$sql.memoryStartupMB -gt 0 -and [long]$memory.Startup -ne ([long]$sql.memoryStartupMB*1MB))){throw 'WINDOWS_POOL_CONSUME_POSTCONDITION_FAILED'}
                    $fieldMap=@{SqlVersion='sqlVersion';DeploymentMode='deploymentMode';MediaEdition='mediaEdition';SqlMediaPath='sqlMediaPath'
                        SqlFeatures='features';ProcessorCount='processorCount';MemoryStartupMB='memoryStartupMB';MaximumDataIops='maximumDataIops'
                        Collation='collation';SqlPort='sqlPort';NetworkMode='networkMode';ServerConfig='serverConfig';StorageConfiguration='storage'
                        SqlPatch='sqlPatch';SqlUpdatePath='sqlUpdatePath';ExpectedSqlBuild='expectedSqlBuild'}
                    foreach($property in $plan.sqlDeploymentPlan.PSObject.Properties){
                        $expected=$property.Value;$actual=$sql.($fieldMap[$property.Name])
                        if($property.Name -ceq 'SqlFeatures'){$actual=@($actual | Sort-Object -Unique)}
                        if((Get-LabWindowsPoolPlanKey -Plan @{value=$expected}) -cne (Get-LabWindowsPoolPlanKey -Plan @{value=$actual})){throw 'WINDOWS_POOL_CONSUME_PLAN_PERSISTENCE_MISMATCH'}
                    }
                    $member=$fresh.Member;$terminalState='CONSUMED'
                    $status='CONSUMED'
                }
                Refresh {
                    $null=Start-HyperVLabEnvironment -RunId $plan.runId -SkipWindowsActivationReconcile -StateRoot $plan.stateRoot
                    $fresh=Get-LabWindowsPoolBoundMember -RunId $plan.runId -StateRoot $plan.stateRoot
                    $receipt=Get-LabWindowsPoolGuestReceipt -Bound $fresh
                    $null=Stop-HyperVLabEnvironment -RunId $plan.runId -StateRoot $plan.stateRoot
                    Complete-LabWindowsPoolPreparation -RunId $plan.runId -StateRoot $plan.stateRoot -Receipt $receipt -KeepClaim
                    $status='CLAIMED_EVIDENCE_REFRESHED'
                }
                Stop {
                    $null=Stop-HyperVLabEnvironment -RunId $plan.runId -StateRoot $plan.stateRoot
                    $fresh=Get-LabWindowsPoolBoundMember -RunId $plan.runId -StateRoot $plan.stateRoot
                    if([string]$fresh.Managed.VM.State -cne 'Off'){throw 'WINDOWS_POOL_STOP_POSTCONDITION_FAILED'}
                    $member=$fresh.Member
                    $status='STOPPED_CLAIM_HELD'
                }
                Cleanup {
                    $fresh=Get-LabWindowsPoolCleanupBinding -RunId $plan.runId -StateRoot $plan.stateRoot
                    $result=Remove-SqlServerLab -RunId $plan.runId -StateRoot $plan.stateRoot -Force -Confirm:$false
                    if($result.Status -cne 'REMOVED' -or $result.Cleanup -notin @('CLEANUP_SUCCEEDED','ALREADY_REMOVED')){throw 'WINDOWS_POOL_CLEANUP_FAILED'}
                    $current=Get-LabRunState -RunId $plan.runId -StateRoot $plan.stateRoot
                    $member=$current.metadata.windowsPoolMember;$terminalState='REMOVED'
                    $status='REMOVED'
                }
            }
            # Persist the result before terminal claim disposal. A failed journal
            # is surfaced; membership remains the authority and never becomes FREE.
            $operation.result=[pscustomobject]@{Status=$status};$operation.status='Completed';$operation.updatedAt=Get-LabWorkflowUtcNow
            Write-LabArtifactJsonAtomicRaw -Path (Join-Path (Join-Path $plan.stateRoot 'operations') ($operation.operationId+'.json')) -InputObject $operation
            if($terminalState){
                $null=Set-LabWindowsPoolMemberState -RunId $plan.runId -StateRoot $plan.stateRoot -ExpectedRevision $member.revision -Change {
                    param($value)
                    if(-not (Test-LabWindowsPoolOperationContext -Member $value -StateRoot $plan.stateRoot)){throw 'WINDOWS_POOL_CLAIM_BINDING_INVALID'}
                    $value.state=$terminalState
                    if($terminalState -ceq 'FREE'){$value.claim=$null}elseif($terminalState -ceq 'REMOVED'){$value.evidence=$null}
                }
            }
            [pscustomobject]@{Status=$status;RunId=$plan.runId;OperationId=$operation.operationId;OriginalError=$null;CleanupError=$null}
        } catch {
            $operationFailure=$_;$causeCode=Get-LabWindowsPoolFailureCode -Failure $operationFailure -Fallback WINDOWS_POOL_OPERATION_FAILED
            $diagnosticError=$null
            try{Write-LabWindowsPoolFailureReceipt -Failure $operationFailure -Context $context -RunId $plan.runId -Stage $plan.action}catch{$diagnosticError='WINDOWS_POOL_CAUSE_PERSIST_FAILED'}
            try {
                $current=Get-LabRunState -RunId $plan.runId -StateRoot $plan.stateRoot
                $null=Set-LabWindowsPoolMemberState -RunId $plan.runId -StateRoot $plan.stateRoot -ExpectedRevision $current.metadata.windowsPoolMember.revision -Change {
                    param($value)
                    if($value.state -notin @('CONSUMED','REMOVED','FREE')){$value.state='RECOVERY_REQUIRED';$value.evidence=$null}
                }
            } catch {$cleanupError=$_.Exception.Message}
            # Local bounded codes only; no provider/guest diagnostics leave state.
            return [pscustomobject]@{Status='RECOVERY_REQUIRED';RunId=$plan.runId;OperationId=$operation.operationId
                OriginalError='WINDOWS_POOL_OPERATION_FAILED';CauseCode=$causeCode;DiagnosticError=$diagnosticError;CleanupError=$(if($cleanupError){'WINDOWS_POOL_RECOVERY_PERSIST_FAILED'}else{$null})}
        }
    }
}

function Assert-LabWindowsPoolStateRootMigrationAllowed {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Plan)
    $root=Resolve-LabWindowsPoolRoot -StateRoot ([string]$Plan.StateRoot)
    $source=[IO.Path]::GetFullPath([string]$Plan.Source.LabDataRoot).TrimEnd('\','/')
    $target=[IO.Path]::GetFullPath([string]$Plan.Target.LabDataRoot).TrimEnd('\','/')
    $comparison=if($IsWindows){[StringComparison]::OrdinalIgnoreCase}else{[StringComparison]::Ordinal}
    if([string]::Equals($source,$target,$comparison) -or
        (-not [string]::Equals($root,$source,$comparison) -and -not $root.StartsWith($source+[IO.Path]::DirectorySeparatorChar,$comparison))){return}
    # No Notes-root adoption is authorized by a filesystem migration. A removed
    # tombstone is safe only when fresh provider identity proves no live VM.
    try{
        foreach($run in @(Get-LabWindowsPoolRuns -StateRoot $root)){
            $vms=@(Get-HyperVLabVMs -RunId $run.runId -ScopeId $run.scopeId)
            if($run.metadata.windowsPoolMember.state -ceq 'REMOVED' -and $run.state -ceq 'REMOVED' -and $vms.Count -eq 0){continue}
            throw 'WINDOWS_POOL_STATE_ROOT_MIGRATION_BLOCKED'
        }
    }catch{throw 'WINDOWS_POOL_STATE_ROOT_MIGRATION_BLOCKED'}
}

function Get-LabWindowsPoolCreationPreview {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$PoolId,[Parameter(Mandatory)]$Configuration,[Parameter(Mandatory)][string]$StateRoot)
    Assert-LabWindowsPoolRootSupport -StateRoot $StateRoot
    $root=Resolve-LabWindowsPoolRoot -StateRoot $StateRoot
    $runs=@(Get-LabActiveRuns -StateRoot $root)+@(Get-LabWindowsPoolRuns -StateRoot $root)
    $runs=@($runs | Group-Object runId | ForEach-Object {$_.Group[0]})
    $last=$Configuration.StartIndex+$Configuration.Count-1;$width=[Math]::Max(2,([string]$last).Length)
    for($index=$Configuration.StartIndex;$index -le $last;$index++){
        $name='{0}-{1}' -f $Configuration.NamePrefix,$index.ToString("D$width")
        if($name.Length -gt 64){throw 'WINDOWS_POOL_NAME_TOO_LONG'}
        $poolMatches=@($runs | Where-Object {$_.metadata.name -ceq $name -or
            ($_.metadata.windowsPoolMember.poolId -ceq $PoolId -and $_.metadata.windowsPoolMember.index -eq $index)})
        if($poolMatches.Count -gt 1){throw 'WINDOWS_POOL_MEMBER_AMBIGUOUS'}
        $bound=$null
        if($poolMatches.Count){
            $member=Assert-LabWindowsPoolMember -Run $poolMatches[0]
            if(-not $member -or $member.poolId -cne $PoolId -or $member.index -ne $index -or $poolMatches[0].metadata.name -cne $name -or
                $member.imageArtifactId -cne $Configuration.ArtifactId -or $member.state -notin @('PREPARING','RECOVERY_REQUIRED','FREE')){throw 'WINDOWS_POOL_EXISTING_NAME_CONFLICT'}
            $bound=Get-LabWindowsPoolBoundMember -RunId $member.runId -StateRoot $root
            $resource=$bound.Instance.resourceSettings
            if(-not $resource.dynamicMemoryEnabled -or $resource.memoryMinimumMB -ne $Configuration.MemoryMinimumMB -or
                $resource.memoryStartupMB -ne $Configuration.MemoryStartupMB -or $resource.memoryMaximumMB -ne $Configuration.MemoryMaximumMB -or
                $resource.processorCount -ne $Configuration.ProcessorCount -or $bound.Run.metadata.networkIntent -cne 'hostOnly'){throw 'WINDOWS_POOL_RESUME_CONFIGURATION_CHANGED'}
        }elseif(@(Get-VM -Name $name -ErrorAction SilentlyContinue).Count){throw 'WINDOWS_POOL_EXISTING_VM_NAME_CONFLICT'}
        [pscustomobject]@{Index=$index;Name=$name;RunId=$(if($bound){$bound.Run.runId}else{$null});Action=$(if($bound){'RESUME_BOUND_MEMBER'}else{'CREATE'})}
    }
}

function Get-LabWindowsPoolRuns {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StateRoot)
    Assert-LabWindowsPoolRootSupport -StateRoot $StateRoot
    $root=Resolve-LabWindowsPoolRoot -StateRoot $StateRoot;$directory=Join-Path $root 'runs'
    if(-not (Test-Path -LiteralPath $directory -PathType Container)){return}
    foreach($entry in @(Get-ChildItem -LiteralPath $directory -Directory)){
        $path=Join-Path $entry.FullName 'run-state.json'
        if(-not (Test-LabPathWithinRoot -Root $root -Path $path).Valid){throw 'WINDOWS_POOL_STATE_PATH_INVALID'}
        if(-not (Test-Path -LiteralPath $path -PathType Leaf)){continue}
        $run=Read-LabWorkflowJson -Path $path
        if($run.metadata.windowsPoolMember){$null=Assert-LabWindowsPoolMember -Run $run;$run}
    }
}

function Invoke-WithLabWindowsPoolCleanupSource {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context,[string]$SourceOperationId,[Parameter(Mandatory)][scriptblock]$Body)
    if(-not $SourceOperationId -or $SourceOperationId -ceq $Context.OperationId){Invoke-WithLabWindowsPoolOperation -Context $Context -Body $Body;return}
    # Cleanup cannot replace a claim while its original executor is active.
    # Only cleanup takes this pair, in source-then-cleanup order, outside root.
    $source=[pscustomobject]@{StateRoot=$Context.StateRoot;PoolId=$Context.PoolId;OperationId=$SourceOperationId;RunId=$Context.RunId;Kind='CleanupSource'}
    # The nested executor also declares Context/Body. Capture under distinct
    # names so PowerShell's dynamic scope cannot select its wrapper again.
    $cleanupTargetContext=$Context
    $cleanupTargetBody=$Body
    Invoke-WithLabWindowsPoolOperation -Context $source -Body {
        $previousSource=$script:LabWindowsPoolCleanupSourceId
        try{$script:LabWindowsPoolCleanupSourceId=$SourceOperationId;Invoke-WithLabWindowsPoolOperation -Context $cleanupTargetContext -Body $cleanupTargetBody}
        finally{$script:LabWindowsPoolCleanupSourceId=$previousSource}
    }
}

function Get-LabWindowsPoolCleanupBinding {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunId,[Parameter(Mandatory)][string]$StateRoot)
    $root=Resolve-LabWindowsPoolRoot -StateRoot $StateRoot;$path=Get-LabWindowsPoolMemberPath -RunId $RunId -StateRoot $root
    $run=Read-LabWorkflowJson -Path $path;$member=Assert-LabWindowsPoolMember -Run $run
    if(-not $member -or $run.metadata.testGroupId -or $run.metadata.automatedTestEnvironment -or
        (Test-LabAutomatedTestEnvironmentRun -RunId $RunId)){throw 'WINDOWS_POOL_CLEANUP_BINDING_INVALID'}
    $directory=Split-Path -Parent $path;$cleanupPath=Join-Path $directory 'cleanup-plan.json'
    if(-not (Test-LabPathWithinRoot -Root $root -Path $cleanupPath).Valid -or -not (Test-Path -LiteralPath $cleanupPath -PathType Leaf)){throw 'WINDOWS_POOL_CLEANUP_PLAN_REQUIRED'}
    $cleanup=Read-LabWorkflowJson -Path $cleanupPath
    if($cleanup.runId -cne $run.runId -or $cleanup.scopeId -cne $run.scopeId -or
        @($cleanup.providerSubRuns | Where-Object provider -ne hyperv).Count -or
        @($cleanup.steps | Where-Object {$_.provider -and $_.provider -cne 'hyperv'}).Count){throw 'WINDOWS_POOL_CLEANUP_PLAN_BINDING_INVALID'}
    $vms=@(Get-HyperVLabVMs -RunId $run.runId -ScopeId $run.scopeId)
    if($vms.Count -gt 1){throw 'WINDOWS_POOL_VM_BINDING_INVALID'}
    $managed=$null
    if($vms.Count){
        $managed=Get-HyperVManagedVM -VMName $vms[0].VMName -ExpectedRunId $run.runId -ExpectedScopeId $run.scopeId
        Assert-LabWindowsPoolNotes -Identity $managed.Identity -StateRoot $root -Run $run
        if([string]$managed.VM.State -cne 'Off' -or ($member.vmId -and [string]$managed.VM.Id -cne $member.vmId)){throw 'WINDOWS_POOL_VM_BINDING_INVALID'}
    }else{
        # The locator is still canonical when creation crashed before connection
        # persistence, or removal completed before its terminal member commit.
        $connectionPath=Join-Path $directory 'connection-info.json'
        if(Test-Path -LiteralPath $connectionPath){
            if(-not (Test-LabPathWithinRoot -Root $root -Path $connectionPath).Valid){throw 'WINDOWS_POOL_CONNECTION_PATH_INVALID'}
            $connection=Read-LabWorkflowJson -Path $connectionPath
            foreach($instance in @($connection.instances)){
                if($instance.provider -cne 'hyperv' -or $instance.id -cne $member.instanceId){throw 'WINDOWS_POOL_INSTANCE_BINDING_INVALID'}
                if(@(Get-VM -Name $instance.vmName -ErrorAction SilentlyContinue).Count){throw 'WINDOWS_POOL_FOREIGN_NAME_CONFLICT'}
            }
        }
        $managed=[pscustomobject]@{VM=[pscustomobject]@{Id=[string]$member.vmId;Name=[string]$run.metadata.name};Identity=$null}
    }
    $key=(Get-FileHash -LiteralPath $cleanupPath -Algorithm SHA256).Hash
    [pscustomobject]@{Run=$run;Member=$member;Managed=$managed;RunDirectory=$directory;StateRoot=$root;CleanupKey=$key;LiveVMExists=($vms.Count -eq 1)}
}

function Invoke-LabWindowsPoolPreparation {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context,[Parameter(Mandatory)]$Configuration,[SecureString]$AdministratorPassword,
        [switch]$GenerateAdministratorPasswords,[switch]$LeaveRunning)
    $specifications=@(Get-LabWindowsPoolCreationPreview -PoolId $Context.PoolId -Configuration $Configuration -StateRoot $Context.StateRoot)
    foreach($specification in $specifications){
        $Context.Index=$specification.Index;$runId=$specification.RunId;$password=$null;$cleanupError=$null
        try {
            if($runId){
                $bound=Get-LabWindowsPoolBoundMember -RunId $runId -StateRoot $Context.StateRoot
                if($bound.Member.creationOperationId -cne $Context.OperationId){throw 'WINDOWS_POOL_RESUME_OPERATION_CHANGED'}
                if($bound.Member.state -ceq 'FREE'){
                    $status=Get-LabWindowsPoolEvidenceStatus -Bound $bound -MinimumDaysRemaining 0
                    if($status.VerifiedAvailable -and [string]$bound.Managed.VM.State -ceq 'Off' -and $bound.Run.state -ceq 'STOPPED'){
                        [pscustomobject]@{Index=$specification.Index;Name=$specification.Name;RunId=$runId;VMName=$bound.Managed.VM.Name;Action='REUSED_BOUND_MEMBER';State='STOPPED'}
                        continue
                    }
                    $null=Set-LabWindowsPoolMemberState -RunId $runId -StateRoot $Context.StateRoot -ExpectedRevision $bound.Member.revision -Change {
                        param($member)
                        if($member.state -cne 'FREE' -or $member.claim){throw 'WINDOWS_POOL_MEMBER_UNAVAILABLE'}
                        $member.state='PREPARING';$member.claim=[pscustomobject]@{claimId=[guid]::NewGuid().ToString();operationId=$Context.OperationId;purpose='Prepare';providerMutationStarted=$false}
                    }
                }elseif($bound.Member.claim.operationId -cne $Context.OperationId){throw 'WINDOWS_POOL_MEMBER_RESERVED'}
            }else{
                # All names were checked before mutation, and each name is freshly
                # checked again immediately before the prospective run registration.
                if(@(Get-VM -Name $specification.Name -ErrorAction SilentlyContinue).Count){throw 'WINDOWS_POOL_EXISTING_VM_NAME_CONFLICT'}
                $created=New-HyperVLabEnvironment -ArtifactId $Configuration.ArtifactId -LabName $specification.Name -InstanceId primary `
                    -DynamicMemoryEnabled $true -MemoryMinimumMB $Configuration.MemoryMinimumMB -MemoryStartupMB $Configuration.MemoryStartupMB `
                    -MemoryMaximumMB $Configuration.MemoryMaximumMB -ProcessorCount $Configuration.ProcessorCount -AutoStart off `
                    -NetworkIntent hostOnly -WindowsLocale $Configuration.Locale -WindowsActivation $Configuration.Activation -StateRoot $Context.StateRoot
                $runId=$created.RunId
                $bound=Get-LabWindowsPoolBoundMember -RunId $runId -StateRoot $Context.StateRoot
                $null=Set-LabWindowsPoolMemberState -RunId $runId -StateRoot $Context.StateRoot -ExpectedRevision $bound.Member.revision -Change {param($member)$member.vmId=[string]$bound.Managed.VM.Id}
            }
            $lab=Get-HyperVLabWorkflowRun -RunId $runId -StateRoot $Context.StateRoot
            if($lab.Instance.windowsProvisioning.state -cne 'COMPLETE' -and $lab.Instance.oobeAutomation.status -cne 'COMPLETED'){
                $password=$AdministratorPassword;$passwordSource='user'
                if($GenerateAdministratorPasswords){
                    $passwordSource='generated';$password=Get-LabSecret -Path $lab.RunDirectory -Name generated-windows-administrator-password
                    if(-not $password){$password=Get-LabSecret -Path $lab.RunDirectory -Name guest-administrator-password}
                    if(-not $password){$password=New-HyperVSqlUnattendedPassword}
                }
                $null=Stop-HyperVLabEnvironment -RunId $runId -StateRoot $Context.StateRoot
                $null=Invoke-HyperVLabUnattendedProvision -RunId $runId -AdministratorPassword $password -PasswordSource $passwordSource `
                    -Region $Configuration.Locale.Region -SystemLocale $Configuration.Locale.SystemLocale -UiLanguage $Configuration.Locale.UiLanguage `
                    -InputLocale $Configuration.Locale.InputLocale -TimeZone $Configuration.Locale.TimeZone -StateRoot $Context.StateRoot
            }
            $null=Start-HyperVLabEnvironment -RunId $runId -SkipWindowsActivationReconcile -StateRoot $Context.StateRoot
            $null=Invoke-HyperVWindowsSlotActivation -RunId $runId -WindowsActivation $Configuration.Activation -StateRoot $Context.StateRoot
            $bound=Get-LabWindowsPoolBoundMember -RunId $runId -StateRoot $Context.StateRoot
            $receipt=Get-LabWindowsPoolGuestReceipt -Bound $bound
            if(-not $LeaveRunning){
                $null=Stop-HyperVLabEnvironment -RunId $runId -StateRoot $Context.StateRoot
                Complete-LabWindowsPoolPreparation -RunId $runId -StateRoot $Context.StateRoot -Receipt $receipt
            }
            [pscustomobject]@{Index=$specification.Index;Name=$specification.Name;RunId=$runId;VMName=$bound.Managed.VM.Name
                Action=$specification.Action;State=$(if($LeaveRunning){'RUNNING_RESERVED'}else{'STOPPED'})}
        }catch{
            $originalFailure=$_
            $originalCode=Get-LabWindowsPoolFailureCode -Failure $originalFailure -Fallback WINDOWS_POOL_PREPARATION_FAILED
            $diagnosticError=$null
            if(-not $runId){
                $operation=Read-LabWorkflowJson -Path (Join-Path (Join-Path $Context.StateRoot 'operations') ($Context.OperationId+'.json'))
                $entry=@($operation.executor.members | Where-Object index -eq $specification.Index | Select-Object -Last 1)
                if($entry.Count){$runId=$entry[0].runId}
            }
            if($runId){
                try{Write-LabWindowsPoolFailureReceipt -Failure $originalFailure -Context $Context -RunId $runId -Stage Prepare}catch{$diagnosticError='WINDOWS_POOL_CAUSE_PERSIST_FAILED'}
                try {$null=Stop-HyperVLabEnvironment -RunId $runId -StateRoot $Context.StateRoot}catch{
                    $cleanupError=Get-LabWindowsPoolFailureCode -Failure $_ -Fallback WINDOWS_POOL_STOP_FAILED
                    try{Write-LabWindowsPoolFailureReceipt -Failure $_ -Context $Context -RunId $runId -Stage PrepareStop}catch{$diagnosticError='WINDOWS_POOL_CAUSE_PERSIST_FAILED'}
                }
                try {
                    $run=Get-LabRunState -RunId $runId -StateRoot $Context.StateRoot
                    $null=Set-LabWindowsPoolMemberState -RunId $runId -StateRoot $Context.StateRoot -ExpectedRevision $run.metadata.windowsPoolMember.revision -Change {
                        param($member)
                        if($member.claim.operationId -cne $Context.OperationId){throw 'WINDOWS_POOL_CLAIM_BINDING_INVALID'}
                        $member.state='RECOVERY_REQUIRED';$member.evidence=$null
                    }
                }catch{$cleanupError='WINDOWS_POOL_RECOVERY_PERSIST_FAILED'}
            }
            [pscustomobject]@{Index=$specification.Index;Name=$specification.Name;RunId=$runId;Action=$specification.Action;State='RECOVERY_REQUIRED'
                OriginalError=$originalCode;CleanupError=$cleanupError;DiagnosticError=$diagnosticError}
            break
        }finally{$password=$null}
    }
}
