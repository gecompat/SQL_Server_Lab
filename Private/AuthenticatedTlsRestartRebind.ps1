#Requires -Version 7.2
# Explicit metadata-only rebind of one existing policy-bound TLS container.
function Get-LabTlsRebindIdentityDigest {
    param([object]$Record)
    $copy=Read-LabTlsLabRecord (ConvertTo-LabTlsRegistryWriterBytes $Record)
    if($copy.ContractVersion -cnotin @('SqlServerLab.AuthenticatedTlsLab/0.2','SqlServerLab.AuthenticatedTlsLab/0.3')){throw 'TLS_REBIND_POLICY_RECORD_REQUIRED'}
    $copy.StartedAt=''
    return Get-LabTlsCaByteDigest (ConvertTo-LabTlsRegistryWriterBytes $copy)
}

function Assert-LabTlsRestartCandidate {
    param([object]$Original,[object]$Candidate)
    $null=Get-LabTlsRebindIdentityDigest $Original
    $copy=Read-LabTlsLabRecord (ConvertTo-LabTlsRegistryWriterBytes $Candidate)
    $started=[DateTimeOffset]::MinValue;$previous=[DateTimeOffset]::MinValue
    if($copy.StartedAt -isnot [string] -or $copy.StartedAt.Length -gt 64 -or
        $copy.StartedAt -cnotmatch '\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?(?:Z|[+-]\d{2}:\d{2})\z' -or
        -not [DateTimeOffset]::TryParse($copy.StartedAt,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$started) -or
        $Original.StartedAt -isnot [string] -or $Original.StartedAt -cnotmatch '\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?(?:Z|[+-]\d{2}:\d{2})\z' -or
        -not [DateTimeOffset]::TryParse($Original.StartedAt,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$previous) -or
        $started -gt [DateTimeOffset]::UtcNow.AddSeconds(5) -or $started -le $previous){throw 'TLS_REBIND_START_EPOCH_INVALID'}
    # DateTimeOffset comparisons use UTC instants. Preserve the exact observed
    # provider string (including its offset/fraction) for the native binding.
    $copy.StartedAt=$Original.StartedAt
    if((Get-LabTlsCaByteDigest (ConvertTo-LabTlsRegistryWriterBytes $copy)) -cne
       (Get-LabTlsCaByteDigest (ConvertTo-LabTlsRegistryWriterBytes $Original))){throw 'TLS_REBIND_IMMUTABLE_BINDING_CHANGED'}
}

function Read-LabTlsRebindHistory {
    param([object]$Binding,[object]$Record,[byte[]]$CurrentBytes)
    return (Get-LabTlsRebindHistoryState $Binding $Record $CurrentBytes).Sequence
}

function Assert-LabTlsRebindCommitted {
    param([object]$Bound,[string]$StateRoot)
    $binding=[pscustomobject]@{Directory=(Join-Path $StateRoot 'authenticated-tls-rebind');Native=$Bound.Authority.Native}
    if(-not(Test-Path -LiteralPath $binding.Directory)){return}
    $lock=$null
    try {
        $lock=Enter-LabTlsRegistryWriterLock $binding
        $live=Read-LabTlsCaPrivateFile (Join-Path $StateRoot 'authenticated-tls-lab.json') $binding.Native.UserSid 32768
        if((Get-LabTlsCaByteDigest $live) -cne (Get-LabTlsCaByteDigest $Bound.Bytes)){throw 'TLS_REBIND_SOURCE_CHANGED'}
        $null=Read-LabTlsRebindHistory $binding $Bound.Record $live
    } finally {Exit-LabTlsRegistryWriterLock $lock}
}

function Assert-LabTlsRebindCandidateLock {
    param([object]$Lock,[string]$StateRoot)
    $path=[IO.Path]::GetFullPath((Join-Path $StateRoot 'authenticated-tls-rebind/writer.lock'))
    if($null -eq $Lock -or $Lock.Stream -isnot [IO.FileStream] -or $Lock.Mutex -isnot [Threading.Mutex] -or
        -not $Lock.Stream.CanRead -or -not $Lock.Stream.CanWrite -or $Lock.Stream.SafeFileHandle.IsClosed -or
        $Lock.Stream.SafeFileHandle.IsInvalid -or $Lock.Mutex.SafeWaitHandle.IsClosed -or
        -not [string]::Equals($Lock.Stream.Name,$path,[StringComparison]::OrdinalIgnoreCase)){throw 'TLS_REBIND_HELD_LOCK_REQUIRED'}
}

function New-LabTlsRebindResult {
    param([object]$Record,[bool]$Changed,[object]$Qualification)
    $profile=Get-LabTlsBindingSqlProfile $Record
    return [pscustomobject][ordered]@{ContractVersion='SqlServerLab.TlsBindingUpdate/0.1';RunId=$Record.RunId;InstanceId=$Record.InstanceId;
        Provider=(Get-LabTlsBindingProvider $Record);SqlVersion=$profile.SqlVersion;Patch=$profile.Patch;SqlBuild=$profile.SqlBuild;
        Status=$(if($Changed){'QUALIFIED_METADATA_COMMITTED'}else{'UNCHANGED_ALREADY_BOUND'});BindingUpdated=$Changed;
        QualificationStatus=$(if($Changed){'QUALIFIED'}else{'NOT_EXECUTED'});Encrypt=$true;TrustServerCertificate=$false;
        QualifiedAt=$(if($Qualification){$Qualification.QualifiedAt}else{$null});ExpiresAt=$(if($Qualification){$Qualification.ExpiresAt}else{$null});
        Evidence=$(if($Qualification){$Qualification.Evidence}else{'NO_NEW_CLIENT_CHECK'});WireCertificateFingerprint='NOT_OBSERVED'}
}

function Update-LabTlsRestartBinding {
    param([string]$RunId,[string]$InstanceId,[string]$StateRoot)
    $bound=Get-LabTlsOwnBinding $StateRoot $RunId $InstanceId
    $record=$bound.Record;$null=Get-LabTlsRebindIdentityDigest $record
    $provider=Get-LabTlsBindingProvider $record
    $budget=New-LabTlsRuntimeBudget -Provider $provider -StateRoot $StateRoot -Record $record
    $context=Assert-LabTlsOwnContainer $record $StateRoot $budget
    $binding=[pscustomobject]@{Directory=(Join-Path $bound.StateRoot 'authenticated-tls-rebind');Native=$bound.Authority.Native}
    if(-not(Test-Path -LiteralPath $binding.Directory) -and $context.Inspect.State.StartedAt -ceq $record.StartedAt){return New-LabTlsRebindResult $record $false $null}
    $lock=$null;$intentStarted=$false
    try {
        # Reuse the nonblocking global+file lock primitive; this directory is a
        # distinct consumer beneath the exact own TLS-lab root, not the CA registry.
        $lock=Enter-LabTlsRegistryWriterLock $binding
        if(-not(Test-Path -LiteralPath $binding.Directory)){
            Initialize-LabTlsCaPrivateDirectory $binding.Directory $binding.Native.UserSid -NewOnly
            $owner=[ordered]@{ContractVersion='SqlServerLab.TlsRebindStorage/0.1';RunId=$record.RunId;InstanceId=$record.InstanceId;ScopeId=$record.ScopeId;AuditId=$record.AuditId;IdentitySha256=(Get-LabTlsRebindIdentityDigest $record)}
            Write-LabTlsCaPrivateFile (Join-Path $binding.Directory 'owner.json') $binding.Native.UserSid (ConvertTo-LabTlsRegistryWriterBytes $owner)
            $lockPath=Join-Path $binding.Directory 'writer.lock'
            $created=[IO.FileSystemAclExtensions]::Create([IO.FileInfo]::new($lockPath),[IO.FileMode]::CreateNew,
                [Security.AccessControl.FileSystemRights]::FullControl,[IO.FileShare]::None,4096,[IO.FileOptions]::None,(Get-LabTlsCaSecurity $binding.Native.UserSid))
            # ACL Create returns an anonymous-handle stream (Name=[Unknown]).
            # Reopen the exact protected path while retaining the global mutex.
            $created.Dispose()
            Assert-LabTlsCaPrivateAcl $lockPath $binding.Native.UserSid
            $lock.Stream=[IO.File]::Open($lockPath,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        }
        $fresh=Get-LabTlsOwnBinding $StateRoot $RunId $InstanceId
        $sourceSha=Get-LabTlsCaByteDigest $bound.Bytes
        if((Get-LabTlsCaByteDigest $fresh.Bytes) -cne $sourceSha){throw 'TLS_REBIND_SOURCE_CHANGED'}
        $sequence=Read-LabTlsRebindHistory $binding $record $bound.Bytes
        $context=Assert-LabTlsOwnContainer $record $StateRoot $budget
        if($context.Inspect.State.StartedAt -ceq $record.StartedAt){return New-LabTlsRebindResult $record $false $null}
        if($sequence -ge 64){throw 'TLS_REBIND_HISTORY_LIMIT'}
        $candidate=Read-LabTlsLabRecord $bound.Bytes;$candidate.StartedAt=[string]$context.Inspect.State.StartedAt
        Assert-LabTlsRestartCandidate $record $candidate
        $qualified=Test-LabAuthenticatedTlsEnvironment -RunId $RunId -InstanceId $InstanceId -StateRoot $StateRoot -Budget $budget -RestartCandidate $candidate -ExpectedSourceSha256 $sourceSha -RebindLock $lock
        if($qualified.Status -cne 'QUALIFIED' -or [DateTimeOffset]::Parse($qualified.ExpiresAt,[Globalization.CultureInfo]::InvariantCulture) -le [DateTimeOffset]::UtcNow){throw 'TLS_REBIND_QUALIFICATION_EXPIRED'}
        $candidateBytes=ConvertTo-LabTlsRegistryWriterBytes $candidate;$candidateSha=Get-LabTlsCaByteDigest $candidateBytes
        $id=[guid]::NewGuid().ToString('D');$directory=Join-Path $binding.Directory $id
        Initialize-LabTlsCaPrivateDirectory $directory $binding.Native.UserSid -NewOnly
        $intentStarted=$true
        Write-LabTlsCaPrivateFile (Join-Path $directory 'original.json') $binding.Native.UserSid $bound.Bytes
        Write-LabTlsCaPrivateFile (Join-Path $directory 'candidate.json') $binding.Native.UserSid $candidateBytes
        $intent=[ordered]@{ContractVersion='SqlServerLab.TlsRebindIntent/0.1';TransactionId=$id;Sequence=($sequence+1);SourceSha256=$sourceSha;CandidateSha256=$candidateSha}
        Write-LabTlsCaPrivateFile (Join-Path $directory 'intent.json') $binding.Native.UserSid (ConvertTo-LabTlsRegistryWriterBytes $intent)
        $temporary=Join-Path $directory 'candidate-write.json'
        Write-LabTlsCaPrivateFile $temporary $binding.Native.UserSid $candidateBytes
        $again=Get-LabTlsOwnBinding $StateRoot $RunId $InstanceId
        if((Get-LabTlsCaByteDigest $again.Bytes) -cne $sourceSha -or
            (Get-LabTlsCaByteDigest (Read-LabTlsCaPrivateFile $temporary $binding.Native.UserSid 32768)) -cne $candidateSha){throw 'TLS_REBIND_SOURCE_OR_CANDIDATE_CHANGED'}
        $null=Assert-LabTlsSqlCertificateBinding $candidate $StateRoot $budget
        # All writers cooperate on the held lock. Preserve the actual replaced
        # source and verify it; an unknown outcome is never rolled back or replayed.
        [IO.File]::Replace($temporary,(Join-Path $bound.StateRoot 'authenticated-tls-lab.json'),(Join-Path $directory 'source.json'),$false)
        if((Get-LabTlsCaByteDigest (Read-LabTlsCaPrivateFile (Join-Path $directory 'source.json') $binding.Native.UserSid 32768)) -cne $sourceSha){throw 'TLS_REBIND_OVERWRITTEN_SOURCE_CHANGED'}
        $installed=Get-LabTlsOwnBinding $StateRoot $RunId $InstanceId
        if((Get-LabTlsCaByteDigest $installed.Bytes) -cne $candidateSha){throw 'TLS_REBIND_READBACK_CHANGED'}
        $null=Assert-LabTlsSqlCertificateBinding $installed.Record $StateRoot $budget
        if([DateTimeOffset]::Parse($qualified.ExpiresAt,[Globalization.CultureInfo]::InvariantCulture) -le [DateTimeOffset]::UtcNow){throw 'TLS_REBIND_QUALIFICATION_EXPIRED'}
        $commit=[ordered]@{ContractVersion='SqlServerLab.TlsRebindCommit/0.1';TransactionId=$id;SourceSha256=$sourceSha;CandidateSha256=$candidateSha;Status='QUALIFIED_METADATA_COMMITTED';QualifiedAt=$qualified.QualifiedAt;ExpiresAt=$qualified.ExpiresAt}
        Write-LabTlsCaPrivateFile (Join-Path $directory 'commit.json') $binding.Native.UserSid (ConvertTo-LabTlsRegistryWriterBytes $commit)
        $null=Read-LabTlsRebindHistory $binding $installed.Record $installed.Bytes
        return New-LabTlsRebindResult $installed.Record $true $qualified
    } catch {
        if($intentStarted){throw 'TLS_REBIND_RECOVERY_REQUIRED'}
        throw
    } finally {Exit-LabTlsRegistryWriterLock $lock}
}
