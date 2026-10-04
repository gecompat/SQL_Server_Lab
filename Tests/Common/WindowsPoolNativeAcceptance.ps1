#Requires -Version 7.2
# Test-only, in-memory acceptance bindings. Never a product claim authority.
function Get-WindowsPoolNativeFailureDetail {
    param([Parameter(Mandatory)]$Failure,[Parameter(Mandatory)][string]$Fallback)
    $code=$Fallback
    if($Failure.Exception.Message -match '^(?<code>(?:WINDOWS_POOL_|HYPERV_|SQL_)[A-Z0-9_]+)(?=:|\s|$)'){$code=$Matches.code}
    [pscustomobject]@{Code=$code;ExceptionType=$Failure.Exception.GetType().FullName
        SourceFile=[IO.Path]::GetFileName([string]$Failure.InvocationInfo.ScriptName);SourceLine=$Failure.InvocationInfo.ScriptLineNumber}
}

function Resolve-WindowsPoolNativeSqlMedia {
    param([Parameter(Mandatory)][System.Management.Automation.PSModuleInfo]$Module,
        [Parameter(Mandatory)][string]$MediaRoot,
        [ValidateSet('Enterprise','Standard','Eval')][string]$MediaEdition='Eval',
        [Parameter(Mandatory)][string]$SqlMediaPath)
    # The product resolver owns edition/version/path semantics. Its explicit
    # path probe may temporarily mount this ISO to read setup.exe; the elevated
    # native preflight runs it, without SQL install, registration or download.
    $media=& $Module {param($root,$edition,$relative)
        if([IO.Path]::IsPathRooted($relative) -or $relative -match '(^|[\\/])\.\.([\\/]|$)'){throw 'HYPERV_SQL_MEDIA_PATH_INVALID'}
        $selectedRoot=(Resolve-Path -LiteralPath $root -ErrorAction Stop).Path
        $selectedIso=Join-Path $selectedRoot $relative
        if(-not(Test-LabPathWithinRoot -Root $selectedRoot -Path $selectedIso).Valid -or
            -not(Test-Path -LiteralPath $selectedIso -PathType Leaf)){throw 'WINDOWS_POOL_NATIVE_MEDIA_SCOPE_INVALID'}
        try{$before=Get-DiskImage -ImagePath $selectedIso -ErrorAction Stop}catch{throw 'WINDOWS_POOL_NATIVE_MEDIA_ATTACHMENT_UNKNOWN'}
        if(-not $before -or $before.Attached -isnot [bool]){throw 'WINDOWS_POOL_NATIVE_MEDIA_ATTACHMENT_UNKNOWN'}
        if($before.Attached){throw 'WINDOWS_POOL_NATIVE_EXISTING_ISO_MOUNT_NOT_ADOPTED'}
        $resolverFailure=$null;$cleanupFailure=$null;$resolved=$null
        try{$resolved=Resolve-HyperVSqlInstallationMedia -MediaRoot $selectedRoot -SqlVersion 2025 -MediaEdition $edition -SqlMediaPath $relative}catch{$resolverFailure=$_}
        try{
            $after=Get-DiskImage -ImagePath $selectedIso -ErrorAction Stop
            if(-not $after -or $after.Attached -isnot [bool]){throw 'WINDOWS_POOL_NATIVE_OWN_ISO_MOUNT_ABSENCE_UNKNOWN'}
            if($after.Attached){throw 'WINDOWS_POOL_NATIVE_OWN_ISO_MOUNT_RETAINED'}
        }catch{$cleanupFailure=$_}
        if($cleanupFailure){
            $failure=[InvalidOperationException]::new($cleanupFailure.Exception.Message)
            $failure.Data['CleanupError']=$cleanupFailure.Exception.Message
            if($resolverFailure){$failure.Data['OriginalError']=$resolverFailure.Exception.Message}
            throw $failure
        }
        if($resolverFailure){throw $resolverFailure}
        if($resolved.IsoPath -ine $selectedIso -or -not(Test-LabPathWithinRoot -Root $resolved.MediaRoot -Path $resolved.IsoPath).Valid){throw 'WINDOWS_POOL_NATIVE_MEDIA_SCOPE_INVALID'}
        $resolved
    } $MediaRoot $MediaEdition $SqlMediaPath
    if(-not $media -or $media.SqlVersion -cne '2025' -or $media.MediaEdition -cne $MediaEdition -or
        -not $media.RelativePath -or [IO.Path]::IsPathRooted([string]$media.RelativePath) -or
        -not(Test-Path -LiteralPath $media.IsoPath -PathType Leaf) -or $media.HashStatus -cne 'SIDECAR_READY' -or
        $media.ExpectedSha256 -notmatch '^[a-f0-9]{64}$') {throw 'WINDOWS_POOL_NATIVE_SELECTED_SQL_MEDIA_REQUIRED'}
    $actual=(Get-FileHash -LiteralPath $media.IsoPath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
    if($actual -cne $media.ExpectedSha256){throw 'WINDOWS_POOL_NATIVE_SQL_MEDIA_HASH_MISMATCH'}
    return $media
}

function Update-WindowsPoolNativeAcceptanceBindings {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Bindings,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Snapshots,[Parameter(Mandatory)][string]$PoolId)
    if(-not $Snapshots.Count){throw 'WINDOWS_POOL_NATIVE_OWN_DISCOVERY_MISSING'}
    $seen=@{}
    foreach($snapshot in $Snapshots){
        $run=$snapshot.Run;$member=$run.metadata.windowsPoolMember
        if(-not $member -or $member.poolId -cne $PoolId -or $member.runId -cne $run.runId -or
            $member.scopeId -cne $run.scopeId -or -not $run.runId -or -not $run.scopeId -or $seen.ContainsKey($run.runId)){
            throw 'WINDOWS_POOL_NATIVE_OWN_SCOPE_MISMATCH'
        }
        $seen[$run.runId]=$true
        $vmId=if($snapshot.VmId){[string]$snapshot.VmId}else{[string]$member.vmId}
        if($member.vmId -and $vmId -cne [string]$member.vmId){throw 'WINDOWS_POOL_NATIVE_ORIGINAL_BINDING_CHANGED'}
        if($Bindings.Contains($run.runId)){
            $old=$Bindings[$run.runId]
            if($old.ScopeId -cne $run.scopeId -or ($old.VmId -and $old.VmId -cne $vmId) -or
                $old.RunDirectory -cne $snapshot.RunDirectory){throw 'WINDOWS_POOL_NATIVE_ORIGINAL_BINDING_CHANGED'}
            if(-not $old.VmId){$old.VmId=$vmId}
            $old.ChildPaths=@(@($old.ChildPaths)+@($snapshot.ChildPaths)|Sort-Object -Unique)
            $old.AdapterIds=@(@($old.AdapterIds)+@($snapshot.AdapterIds)|Sort-Object -Unique)
            $old.IpamRequired=($old.IpamRequired -or [bool]$snapshot.IpamRequired)
        }else{
            $Bindings[$run.runId]=[pscustomobject]@{RunId=[string]$run.runId;ScopeId=[string]$run.scopeId;VmId=$vmId
                RunDirectory=[string]$snapshot.RunDirectory;ChildPaths=@($snapshot.ChildPaths);AdapterIds=@($snapshot.AdapterIds);IpamRequired=[bool]$snapshot.IpamRequired}
        }
    }
    foreach($id in @($Bindings.Keys)){if(-not $seen.ContainsKey($id)){throw 'WINDOWS_POOL_NATIVE_ORIGINAL_RUN_MISSING'}}
}

function Get-WindowsPoolNativeParentFingerprint {
    param([Parameter(Mandatory)][string]$Path)
    $item=Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if(-not ($item.Attributes -band [IO.FileAttributes]::ReadOnly) -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){
        throw 'WINDOWS_POOL_NATIVE_PARENT_PROTECTION_INVALID'
    }
    [pscustomobject]@{Path=$item.FullName;Sha256=(Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash
        Length=$item.Length;WriteTicks=$item.LastWriteTimeUtc.Ticks;Attributes=[string]$item.Attributes}
}

function Assert-WindowsPoolNativeParentUnchanged {
    param([Parameter(Mandatory)]$Before,[Parameter(Mandatory)]$After)
    foreach($property in @('Path','Sha256','Length','WriteTicks','Attributes')){
        if($Before.$property -cne $After.$property){throw 'WINDOWS_POOL_NATIVE_PARENT_CHANGED'}
    }
}

function Get-WindowsPoolNativeUnreleasedIpamLeases {
    param([AllowNull()]$Registry,[Parameter(Mandatory)][string]$RunId,[Parameter(Mandatory)][string]$ScopeId)
    # The existing Reserve/Release-LabHyperVNetworkAddress writer is the
    # authority: contractVersion 1, leases array, ACTIVE -> RELEASED only.
    if($Registry -isnot [pscustomobject] -or $Registry.contractVersion -isnot [string] -or $Registry.contractVersion -cne '1' -or
        -not $Registry.PSObject.Properties['leases'] -or $Registry.leases -isnot [array]){
        throw 'WINDOWS_POOL_NATIVE_OWN_IPAM_UNKNOWN'
    }
    foreach($lease in $Registry.leases){
        if(-not $lease -or $lease -isnot [pscustomobject]){throw 'WINDOWS_POOL_NATIVE_OWN_IPAM_UNKNOWN'}
        foreach($field in @('leaseId','runId','scopeId','instanceId','network','subnet','address')){
            if($lease.$field -isnot [string] -or [string]::IsNullOrWhiteSpace($lease.$field)){throw 'WINDOWS_POOL_NATIVE_OWN_IPAM_UNKNOWN'}
        }
        $leaseGuid=[guid]::Empty;$address=$null
        if(-not [guid]::TryParseExact($lease.leaseId,'D',[ref]$leaseGuid) -or $leaseGuid -eq [guid]::Empty -or
            -not [Net.IPAddress]::TryParse($lease.address,[ref]$address) -or $address.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or
            -not $lease.PSObject.Properties['releasedAt'] -or $lease.state -isnot [string] -or $lease.state -cnotin @('ACTIVE','RELEASED')){
            throw 'WINDOWS_POOL_NATIVE_OWN_IPAM_UNKNOWN'
        }
        if($lease.state -ceq 'ACTIVE' -and $null -ne $lease.releasedAt){
            throw 'WINDOWS_POOL_NATIVE_OWN_IPAM_UNKNOWN'
        }
        foreach($field in @('reservedAt')+$(if($lease.state -ceq 'RELEASED'){@('releasedAt')}else{@()})){
            $value=$lease.$field;$parsed=[datetime]::MinValue
            # Read-LabWorkflowJson uses ConvertFrom-Json; PowerShell 7.5 can
            # materialize the canonical Get-LabTimestamp UTC string as DateTime.
            $valid=($value -is [datetime] -and $value.Kind -eq [DateTimeKind]::Utc)
            if($value -is [string]){$valid=[datetime]::TryParseExact($value,'yyyy-MM-ddTHH:mm:ssZ',[Globalization.CultureInfo]::InvariantCulture,
                ([Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal),[ref]$parsed)}
            if(-not $valid){throw 'WINDOWS_POOL_NATIVE_OWN_IPAM_UNKNOWN'}
        }
        # A partial own tuple cannot be silently classified as a foreign lease.
        if(($lease.runId -ceq $RunId -or $lease.scopeId -ceq $ScopeId) -and
            ($lease.runId -cne $RunId -or $lease.scopeId -cne $ScopeId)){
            throw 'WINDOWS_POOL_NATIVE_OWN_IPAM_UNKNOWN'
        }
        if($lease.runId -ceq $RunId -and $lease.scopeId -ceq $ScopeId -and $lease.state -ceq 'ACTIVE'){$lease}
    }
}

function Assert-WindowsPoolNativeCleanupProof {
    param([Parameter(Mandatory)]$Binding,[Parameter(Mandatory)]$Run,
        [AllowEmptyCollection()][object[]]$LiveVms=@(),[AllowEmptyCollection()][string[]]$ExistingChildren=@(),
        [AllowEmptyCollection()][string[]]$LiveAdapterIds=@(),[AllowEmptyCollection()][object[]]$ActiveLeases=@(),[bool]$SecretExists,[bool]$IpamAvailable=$true)
    if($Run.runId -cne $Binding.RunId -or $Run.scopeId -cne $Binding.ScopeId -or $Run.state -cne 'REMOVED' -or
        $Run.metadata.windowsPoolMember.state -cne 'REMOVED' -or
        [string]$Run.metadata.windowsPoolMember.vmId -cne $Binding.VmId){throw 'WINDOWS_POOL_NATIVE_OWN_TERMINAL_MISSING'}
    if($LiveVms.Count -or $ExistingChildren.Count -or $LiveAdapterIds.Count -or $ActiveLeases.Count -or $SecretExists){
        throw 'WINDOWS_POOL_NATIVE_OWN_RESOURCE_REMAINED'
    }
    if(-not $Binding.VmId -or -not $Binding.ChildPaths.Count){throw 'WINDOWS_POOL_NATIVE_ORIGINAL_BINDING_INCOMPLETE'}
    if($Binding.IpamRequired -and -not $IpamAvailable){throw 'WINDOWS_POOL_NATIVE_OWN_IPAM_UNKNOWN'}
}
