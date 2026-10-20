#Requires -Version 7.2
# Immutable snapshots: partial records reserve the attempt and require recovery.
function New-LabTlsSqlConsumerSession {
    [CmdletBinding()]
    param([string]$DataRoot,[string]$ControllerId,[string]$LocationId,
        [string]$OperationId,[string]$RunId,[string]$ScopeId,[string]$VmId,
        [string]$SourceDigest,[string]$WorkerDigest)
    $binding=Get-LabTlsRegistryWriterBinding $DataRoot $ControllerId $LocationId
    $ids=@{OperationId=$OperationId;RunId=$RunId;ScopeId=$ScopeId;VmId=$VmId;
        RootDigest=$binding.Root.RootMetadataDigest;SourceDigest=$SourceDigest;WorkerDigest=$WorkerDigest}
    $first=New-LabTlsSqlConsumerJournalBytes @ids
    if(-not $first.Success){throw 'TLS_SQL_SESSION_BINDING_INVALID'}
    $directory=Assert-LabDiagnosticPath (Join-Path $binding.Root.DataRoot 'State/tls-sql-consumers')
    $mutex=[Threading.Mutex]::new($false,('Global\SQL_Server_Lab_TlsSql_'+(Get-LabTlsPayloadDigest @($directory.ToUpperInvariant()))))
    $held=$false
    try{
        try{$held=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$held=$true;throw 'TLS_SQL_SESSION_ABANDONED'}
        if(-not $held){throw 'TLS_SQL_SESSION_BUSY'}
        Assert-LabTlsRegistryWriterBinding $binding $ids.RootDigest $binding.ActorDigest
        Initialize-LabTlsCaPrivateDirectory $directory $binding.Native.UserSid
        # The VM reservation deliberately survives both success and crashes.
        # A new operation ID must not bypass an unresolved previous dispatch.
        $owner=[ordered]@{ContractVersion='SqlServerLab.TlsSqlConsumerOwner/0.1';OperationId=$OperationId;
            RunId=$RunId;ScopeId=$ScopeId;VmId=$VmId;RootDigest=$ids.RootDigest;ActorDigest=$binding.ActorDigest;
            SourceDigest=$SourceDigest;WorkerDigest=$WorkerDigest}
        Write-LabTlsCaPrivateFile (Join-Path $directory ('vm-'+$VmId+'.json')) $binding.Native.UserSid (ConvertTo-LabTlsRegistryWriterBytes $owner)
        $operation=Join-Path $directory $OperationId
        Initialize-LabTlsCaPrivateDirectory $operation $binding.Native.UserSid -NewOnly
        Write-LabTlsCaPrivateFile (Join-Path $operation '00-PREPARED.json') $binding.Native.UserSid $first.Value.Utf8Json
        $observed=Read-LabTlsCaPrivateFile (Join-Path $operation '00-PREPARED.json') $binding.Native.UserSid 65536
        if((Get-LabTlsCaByteDigest $observed) -cne $first.Value.Journal.JournalSha256){throw 'TLS_SQL_SESSION_READBACK_FAILED'}
        return [pscustomobject]@{Binding=$binding;Ids=$ids;Directory=$operation;JournalSha256=$first.Value.Journal.JournalSha256}
    }finally{if($held){$mutex.ReleaseMutex()};$mutex.Dispose()}
}

function Write-LabTlsSqlConsumerStage {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session,[ValidateSet('DISPATCHED','REPLY_OBSERVED','RECOVERY_REQUIRED')][string]$Phase)
    $binding=$Session.Binding;$sid=$binding.Native.UserSid
    Assert-LabTlsRegistryWriterBinding $binding $Session.Ids.RootDigest $binding.ActorDigest
    Assert-LabTlsCaPrivateAcl $Session.Directory $sid -Directory
    $ownerPath=Join-Path (Split-Path $Session.Directory -Parent) ('vm-'+$Session.Ids.VmId+'.json')
    $owner=Read-LabTlsRegistryWriterRecord $ownerPath $sid @('ContractVersion','OperationId','RunId','ScopeId','VmId','RootDigest','ActorDigest','SourceDigest','WorkerDigest')
    if($owner.ContractVersion -cne 'SqlServerLab.TlsSqlConsumerOwner/0.1' -or $owner.ActorDigest -cne $binding.ActorDigest){throw 'TLS_SQL_SESSION_OWNER_INVALID'}
    foreach($key in $Session.Ids.Keys){if($owner.$key -cne $Session.Ids[$key]){throw 'TLS_SQL_SESSION_OWNER_CHANGED'}}
    $allowed=@('00-PREPARED.json','01-DISPATCHED.json','02-REPLY_OBSERVED.json','02-RECOVERY_REQUIRED.json','03-RECOVERY_REQUIRED.json')
    $entries=@(Get-ChildItem -LiteralPath $Session.Directory -Force)
    if(@($entries|Where-Object {$_.PSIsContainer -or $_.Name -cnotin ($allowed+@('setup-reply.json','postsetup-reply.json','reboot-intent.json','consumer-end.json'))}).Count){throw 'TLS_SQL_SESSION_RECORDS_INVALID'}
    $files=@($entries|Where-Object Name -cin $allowed)
    if($files.Count -lt 1 -or $files.Count -gt 3){throw 'TLS_SQL_SESSION_RECORDS_INVALID'}
    $last=@($files|Sort-Object Name)[-1]
    $previous=Read-LabTlsCaPrivateFile $last.FullName $sid 65536
    $ids=$Session.Ids
    $next=New-LabTlsSqlConsumerJournalBytes @ids -PreviousUtf8Json $previous -ExpectedJournalSha256 $Session.JournalSha256 -NextPhase $Phase
    if(-not $next.Success){throw 'TLS_SQL_SESSION_TRANSITION_INVALID'}
    $path=Join-Path $Session.Directory (('{0:d2}-' -f ($next.Value.Journal.EventCount-1))+$Phase+'.json')
    # CreateNew, an exclusive handle and Flush(true) precede every effect.
    # Competing writers cannot overwrite even an incomplete reservation.
    Write-LabTlsCaPrivateFile $path $sid $next.Value.Utf8Json
    $checked=Read-LabTlsSqlConsumerJournal -Utf8Json (Read-LabTlsCaPrivateFile $path $sid 65536) @ids
    if(-not $checked.Success -or $checked.Value.JournalSha256 -cne $next.Value.Journal.JournalSha256){throw 'TLS_SQL_SESSION_READBACK_FAILED'}
    $Session.JournalSha256=$checked.Value.JournalSha256
    return $checked.Value
}

function Write-LabTlsSqlConsumerEvidence {
    param($Session,[ValidateSet('setup-reply.json','postsetup-reply.json','reboot-intent.json','consumer-end.json')][string]$Name,$Value)
    Assert-LabTlsRegistryWriterBinding $Session.Binding $Session.Ids.RootDigest $Session.Binding.ActorDigest
    Assert-LabTlsCaPrivateAcl $Session.Directory $Session.Binding.Native.UserSid -Directory
    Write-LabTlsCaPrivateFile (Join-Path $Session.Directory $Name) $Session.Binding.Native.UserSid (ConvertTo-LabTlsRegistryWriterBytes $Value)
}
