#Requires -Version 7.2
# Private Windows-Metadatenlane. Keine Keys, Stores, SQL- oder Provideraktionen.

function Get-LabTlsRegistryWriterBinding {
    param([object]$DataRoot,[object]$ControllerId,[object]$LocationId)
    $metadata=Get-LabAuthenticatedTlsRootMetadata $DataRoot $ControllerId $LocationId
    if(-not $metadata.Success){throw 'TLS_REGISTRY_BINDING_INVALID'}
    $native=Get-LabTlsWindowsProcessFacts
    $drive=[IO.DriveInfo]::new([IO.Path]::GetPathRoot($metadata.Value.DataRoot))
    if($drive.DriveFormat -cnotin @('NTFS','ReFS')){throw 'TLS_REGISTRY_FILESYSTEM_UNSUPPORTED'}
    $volume=Get-LabVolumeIdentity -Path $metadata.Value.DataRoot
    $marker=$metadata.Value.MarkerText|ConvertFrom-Json
    if($volume.VolumeId -cnotmatch '\A\\\\\?\\Volume\{[0-9A-Fa-f-]{36}\}\\\z' -or
        -not [string]::Equals($volume.VolumeId,$marker.VolumeId,[StringComparison]::OrdinalIgnoreCase)){throw 'TLS_REGISTRY_VOLUME_INVALID'}
    $directory=Assert-LabDiagnosticPath (Join-Path $metadata.Value.DataRoot 'State/authenticated-tls')
    if(-not (Test-Path -LiteralPath (Split-Path $directory -Parent) -PathType Container)){throw 'TLS_REGISTRY_STATE_REQUIRED'}
    return [pscustomobject]@{Root=$metadata.Value;Native=$native;Directory=$directory;VolumeId=$volume.VolumeId;
        ActorDigest=(Get-LabTlsPayloadDigest @('SqlServerLab.TlsRegistryActor/0.1',$native.UserSid,$native.HostMarker,$native.ProfilePath))}
}

function ConvertTo-LabTlsRegistryWriterBytes {
    param([object]$Value)
    return ,[Text.UTF8Encoding]::new($false,$true).GetBytes(($Value|ConvertTo-Json -Depth 12 -Compress))
}

function Read-LabTlsRegistryWriterRecord {
    param([string]$Path,[string]$UserSid,[string[]]$Names,[int]$MaximumBytes=16384)
    $bytes=Read-LabTlsCaPrivateFile $Path $UserSid $MaximumBytes
    $document=$null
    try{
        $options=[Text.Json.JsonDocumentOptions]::new();$options.MaxDepth=2
        $document=[Text.Json.JsonDocument]::Parse([Text.UTF8Encoding]::new($false,$true).GetString($bytes),$options)
        $fields=Get-LabTlsIndexFields $document.RootElement $Names
        $value=[ordered]@{}
        foreach($name in $Names){$value[$name]=Get-LabTlsIndexString $fields[$name]}
        return [pscustomobject]$value
    }finally{if($null -ne $document){$document.Dispose()}}
}

function Enter-LabTlsRegistryWriterLock {
    param([object]$Binding)
    # Ein Global-Mutex serialisiert auch die erstmalige Verzeichnisanlage.
    # Der persistente Filelock bleibt nach Prozessende bestehen, sein Handle nicht.
    $key=Get-LabTlsPayloadDigest @('SqlServerLab.TlsRegistryLock/0.1',$Binding.Directory.ToUpperInvariant())
    $mutex=[Threading.Mutex]::new($false,('Global\SQL_Server_Lab_TLS_Registry_'+$key))
    $held=$false;$stream=$null
    try{
        try{$held=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$held=$true}
        if(-not $held){throw 'TLS_REGISTRY_BUSY'}
        if(Test-Path -LiteralPath $Binding.Directory){
            Assert-LabTlsCaPrivateAcl $Binding.Directory $Binding.Native.UserSid -Directory
            $path=Join-Path $Binding.Directory 'writer.lock'
            Assert-LabTlsCaPrivateAcl $path $Binding.Native.UserSid
            $stream=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        }
        return [pscustomobject]@{Mutex=$mutex;Stream=$stream}
    }catch{
        if($null -ne $stream){$stream.Dispose()};if($held){$mutex.ReleaseMutex()};$mutex.Dispose();throw
    }
}

function Exit-LabTlsRegistryWriterLock {
    param([object]$Lock)
    if($null -ne $Lock){
        if($null -ne $Lock.Stream){$Lock.Stream.Dispose()}
        $Lock.Mutex.ReleaseMutex();$Lock.Mutex.Dispose()
    }
}

function Assert-LabTlsRegistryWriterBinding {
    param([object]$Binding,[string]$ExpectedRootDigest,[string]$ExpectedActorDigest)
    $fresh=Get-LabTlsRegistryWriterBinding $Binding.Root.DataRoot $Binding.Root.ControllerId $Binding.Root.LocationId
    if(-not [string]::Equals($fresh.Root.RootMetadataDigest,$ExpectedRootDigest,[StringComparison]::Ordinal) -or
        -not [string]::Equals($fresh.ActorDigest,$ExpectedActorDigest,[StringComparison]::Ordinal) -or
        -not [string]::Equals($fresh.Native.UserSid,$Binding.Native.UserSid,[StringComparison]::Ordinal)){throw 'TLS_REGISTRY_BINDING_CHANGED'}
}

function Read-LabTlsRegistryWriterState {
    param([object]$Binding)
    $dir=$Binding.Directory;$sid=$Binding.Native.UserSid
    Assert-LabTlsCaPrivateAcl $dir $sid -Directory
    $owner=Read-LabTlsRegistryWriterRecord (Join-Path $dir 'owner.json') $sid @('ContractVersion','RegistryId','ControllerId','LocationId','RootDigest','ActorDigest')
    if($owner.ContractVersion -cne 'SqlServerLab.TlsRegistryOwner/0.1' -or -not (Test-LabTlsRequestReference $owner.RegistryId) -or
        $owner.ControllerId -cne $Binding.Root.ControllerId -or $owner.LocationId -cne $Binding.Root.LocationId -or
        $owner.RootDigest -cne $Binding.Root.RootMetadataDigest -or $owner.ActorDigest -cne $Binding.ActorDigest){throw 'TLS_REGISTRY_OWNER_INVALID'}
    $names=@('ContractVersion','TransactionId','RegistryId','RootDigest','ActorDigest','SourceSha256','CandidateSha256','CandidateBase64')
    $terminalNames=@('ContractVersion','TransactionId','RegistryId','SourceSha256','CandidateSha256','Outcome')
    $intents=[Collections.Generic.List[object]]::new();$committed=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    $pending=[Collections.Generic.List[object]]::new();$reserved=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    # Enumeration ist begrenzt und verwirft unbekannte Namen/Verzeichnisse.
    $entries=[Collections.Generic.List[object]]::new()
    foreach($entry in [IO.Directory]::EnumerateFileSystemEntries($dir)){
        if($entries.Count -ge 1028){throw 'TLS_REGISTRY_JOURNAL_LIMIT'}
        $leaf=[IO.Path]::GetFileName($entry)
        if($leaf -cnotin @('owner.json','writer.lock','registry.json') -and
            $leaf -cnotmatch '\A[0-9a-f-]{36}\.(?:intent|candidate|source|commit|abort)\.json\z'){throw 'TLS_REGISTRY_ARTIFACT_UNKNOWN'}
        $entries.Add($entry)
    }
    foreach($path in $entries){
        if(-not $path.EndsWith('.intent.json',[StringComparison]::Ordinal)){continue}
        if($intents.Count -ge 256){throw 'TLS_REGISTRY_JOURNAL_LIMIT'}
        $intent=Read-LabTlsRegistryWriterRecord $path $sid $names 5611520
        $id=[IO.Path]::GetFileName($path).Substring(0,36)
        if(-not (Test-LabTlsRequestReference $id) -or $intent.TransactionId -cne $id -or
            $intent.ContractVersion -cne 'SqlServerLab.TlsRegistryIntent/0.1' -or $intent.RegistryId -cne $owner.RegistryId -or
            $intent.RootDigest -cne $owner.RootDigest -or $intent.ActorDigest -cne $owner.ActorDigest -or
            $intent.SourceSha256 -cnotmatch '\A(?:ABSENT|[0-9a-f]{64})\z' -or $intent.CandidateSha256 -cnotmatch '\A[0-9a-f]{64}\z' -or
            $intent.CandidateBase64.Length -gt 5592408){throw 'TLS_REGISTRY_INTENT_INVALID'}
        $candidate=[Convert]::FromBase64String($intent.CandidateBase64)
        $parsed=Read-LabAuthenticatedTlsRegistryDocument $candidate
        if(-not $parsed.Success -or (Get-LabTlsCaByteDigest $candidate) -cne $intent.CandidateSha256 -or
            $parsed.Value.RegistryDocument.Index.ControllerId -cne $owner.ControllerId -or
            $parsed.Value.RegistryDocument.Index.LocationId -cne $owner.LocationId){throw 'TLS_REGISTRY_INTENT_INVALID'}
        if($intent.SourceSha256 -ceq 'ABSENT' -and ($parsed.Value.RegistryDocument.Index.Revision -ne 0 -or $parsed.Value.RegistryDocument.Payloads.Count -ne 0)){throw 'TLS_REGISTRY_INTENT_INVALID'}
        $backup=Join-Path $dir ($id+'.source.json')
        if(Test-Path -LiteralPath $backup){
            $source=Read-LabTlsCaPrivateFile $backup $sid 4194304
            if((Get-LabTlsCaByteDigest $source) -cne $intent.SourceSha256 -or -not (Read-LabAuthenticatedTlsRegistryDocument $source).Success){throw 'TLS_REGISTRY_SOURCE_INVALID'}
        }
        foreach($record in $parsed.Value.RegistryDocument.Index.Records){$null=$reserved.Add($record.Ref)}
        foreach($payload in $parsed.Value.RegistryDocument.Payloads){if($payload.Kind -ceq 'AUTHORITY'){$null=$reserved.Add($payload.TrustScopeRef)}}
        # Alte Journale behalten nur ihre Bindungen im Arbeitsspeicher.
        # Vollstaendige Base64-/Payloadkopien je Revision waeren unnoetig kumulativ.
        $intent.PSObject.Properties.Remove('CandidateBase64')
        $item=[pscustomobject]@{Intent=$intent;Terminal=$null}
        foreach($suffix in @('commit','abort')){
            $terminal=Join-Path $dir ($id+'.'+$suffix+'.json')
            if(Test-Path -LiteralPath $terminal){
                if($null -ne $item.Terminal){throw 'TLS_REGISTRY_TERMINAL_CONFLICT'}
                $receipt=Read-LabTlsRegistryWriterRecord $terminal $sid $terminalNames
                $expected=if($suffix -ceq 'commit'){'COMMITTED'}else{'ABORTED'}
                if($receipt.ContractVersion -cne 'SqlServerLab.TlsRegistryTerminal/0.1' -or $receipt.TransactionId -cne $id -or
                    $receipt.RegistryId -cne $owner.RegistryId -or $receipt.SourceSha256 -cne $intent.SourceSha256 -or
                    $receipt.CandidateSha256 -cne $intent.CandidateSha256 -or $receipt.Outcome -cne $expected){throw 'TLS_REGISTRY_TERMINAL_INVALID'}
                $item.Terminal=$expected
            }
        }
        $intents.Add($item)
        if($item.Terminal -ceq 'COMMITTED'){$committed.Add($intent.SourceSha256,$item)}
        elseif($null -eq $item.Terminal){$pending.Add($item)}
    }
    if($intents.Count -lt 1 -or $pending.Count -gt 1){throw 'TLS_REGISTRY_RECOVERY_REQUIRED'}
    # Kein losgeloster Commit, keine Verzweigung, kein Rueckspielen eines alten Registryfiles.
    $head='ABSENT';$visited=0
    while($committed.ContainsKey($head)){
        $next=$committed[$head];$head=$next.Intent.CandidateSha256;$visited++
        if($visited -gt $committed.Count){throw 'TLS_REGISTRY_HISTORY_INVALID'}
    }
    if($visited -ne $committed.Count){throw 'TLS_REGISTRY_HISTORY_INVALID'}
    foreach($path in $entries){
        $leaf=[IO.Path]::GetFileName($path)
        if($leaf -cin @('owner.json','writer.lock','registry.json')){continue}
        $id=$leaf.Substring(0,36)
        if(@($intents|Where-Object {$_.Intent.TransactionId -ceq $id}).Count -ne 1){throw 'TLS_REGISTRY_ARTIFACT_UNKNOWN'}
        # Auch erhaltene Kandidaten duerfen keine Reparse-/ACL-Grenze oeffnen.
        Assert-LabTlsCaPrivateAcl $path $sid
    }
    $bytes=$null;$digest='ABSENT';$registry=Join-Path $dir 'registry.json'
    if(Test-Path -LiteralPath $registry){
        $bytes=Read-LabTlsCaPrivateFile $registry $sid 4194304
        $parsed=Read-LabAuthenticatedTlsRegistryDocument $bytes
        if(-not $parsed.Success){throw 'TLS_REGISTRY_DOCUMENT_INVALID'}
        $digest=Get-LabTlsCaByteDigest $bytes
    }
    $status='COMMITTED'
    if($pending.Count -eq 1){
        $p=$pending[0].Intent
        if($p.SourceSha256 -cne $head){throw 'TLS_REGISTRY_HISTORY_INVALID'}
        $status=if($digest -ceq $p.SourceSha256){'SOURCE_UNCHANGED'}elseif($digest -ceq $p.CandidateSha256){'CANDIDATE_INSTALLED'}else{'UNKNOWN'}
    }elseif($digest -cne $head -or $digest -ceq 'ABSENT'){throw 'TLS_REGISTRY_RECOVERY_REQUIRED'}
    return [pscustomobject]@{Owner=$owner;Status=$status;Bytes=$bytes;Digest=$digest;Head=$head;Intents=$intents;Pending=$pending;Reserved=$reserved}
}

function Write-LabTlsRegistryTerminal {
    param([object]$Binding,[object]$Intent,[string]$Outcome)
    $value=[ordered]@{ContractVersion='SqlServerLab.TlsRegistryTerminal/0.1';TransactionId=$Intent.TransactionId;RegistryId=$Intent.RegistryId;
        SourceSha256=$Intent.SourceSha256;CandidateSha256=$Intent.CandidateSha256;Outcome=$Outcome}
    $suffix=if($Outcome -ceq 'COMMITTED'){'commit'}else{'abort'}
    $path=Join-Path $Binding.Directory ($Intent.TransactionId+'.'+$suffix+'.json')
    $bytes=ConvertTo-LabTlsRegistryWriterBytes $value
    Write-LabTlsCaPrivateFile $path $Binding.Native.UserSid $bytes
    $again=Read-LabTlsCaPrivateFile $path $Binding.Native.UserSid 16384
    if((Get-LabTlsCaByteDigest $again) -cne (Get-LabTlsCaByteDigest $bytes)){throw 'TLS_REGISTRY_TERMINAL_CHANGED'}
}

function Assert-LabTlsRegistryFreshPayloads {
    param([object]$Current,[object]$Candidate,[object]$Binding,[object]$Reserved)
    $old=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    foreach($p in $Current.Payloads){$old.Add($p.Ref,$p)}
    foreach($p in $Candidate.Payloads){
        if($p.Status -cne 'ACTIVE'){throw 'TLS_REGISTRY_OPERATION_UNSUPPORTED'}
        if(-not $old.ContainsKey($p.Ref) -and $Reserved.Contains($p.Ref)){throw 'TLS_REGISTRY_REF_RESERVED'}
        if($p.Kind -ceq 'AUTHORITY'){
            if(-not $old.ContainsKey($p.Ref) -and $Reserved.Contains($p.TrustScopeRef)){throw 'TLS_REGISTRY_REF_RESERVED'}
            # Kein Upgrade ungebundener 0.1-CAs und kein Same-Generation-Skip:
            # Kandidat, beide Kontexte und Store werden stets frisch gelesen.
            if($p.ContractVersion -cne 'SqlServerLab.AuthenticatedTlsRegistryPayload/0.2') {throw 'TLS_REGISTRY_OPERATION_UNSUPPORTED'}
            $signer=@($Candidate.Payloads|Where-Object Ref -CEQ $p.SignerContextRef)
            $client=@($Candidate.Payloads|Where-Object Ref -CEQ $p.ClientRef)
            if($signer.Count -ne 1 -or $client.Count -ne 1){throw 'TLS_REGISTRY_PAYLOAD_STALE'}
            $preview=Get-LabAuthenticatedTlsAuthorityPreview $Binding.Root.DataRoot $Binding.Root.ControllerId $Binding.Root.LocationId CURRENT_WINDOWS_PROCESS `
                (ConvertTo-LabTlsRegistryWriterBytes $p) (ConvertTo-LabTlsRegistryWriterBytes $signer[0]) (ConvertTo-LabTlsRegistryWriterBytes $client[0])
            if(-not $preview.Success -or $preview.Value.RootMetadataDigest -cne $Binding.Root.RootMetadataDigest){throw 'TLS_REGISTRY_PAYLOAD_STALE'}
            continue
        }
        if($old.ContainsKey($p.Ref) -and $old[$p.Ref].Generation -eq $p.Generation){continue}
        if($p.Actor.UserSid -cne $Binding.Native.UserSid -or $p.Actor.HostMarker -cne $Binding.Native.HostMarker -or
            $p.Actor.ProfilePath -cne $Binding.Native.ProfilePath){throw 'TLS_REGISTRY_ACTOR_MISMATCH'}
        $preview=Get-LabAuthenticatedTlsPayloadPreview (ConvertTo-LabTlsRegistryWriterBytes $p)
        if(-not $preview.Success){throw 'TLS_REGISTRY_PAYLOAD_STALE'}
    }
}

function Get-LabAuthenticatedTlsRegistryWriterPreview {
    [CmdletBinding()]
    param([object]$DataRoot,[object]$ControllerId,[object]$LocationId,[object]$Context)
    $lock=$null
    try{
        if(-not (Test-LabTlsRequestEnum $Context @('CURRENT_WINDOWS_PROCESS'))){throw 'TLS_REGISTRY_CONTEXT_INVALID'}
        $b=Get-LabTlsRegistryWriterBinding $DataRoot $ControllerId $LocationId
        $lock=Enter-LabTlsRegistryWriterLock $b
        $state=if(Test-Path -LiteralPath $b.Directory){Read-LabTlsRegistryWriterState $b}else{$null}
        Assert-LabTlsRegistryWriterBinding $b $b.Root.RootMetadataDigest $b.ActorDigest
        return [pscustomobject]@{Success=$true;Value=[pscustomobject]@{Status=$(if($null -eq $state){'NOT_INITIALIZED'}else{$state.Status});
            RootMetadataDigest=$b.Root.RootMetadataDigest;ActorDigest=$b.ActorDigest;RegistryByteSha256=$(if($null -eq $state){'ABSENT'}else{$state.Digest});
            PendingTransactionId=$(if($null -ne $state -and $state.Pending.Count -eq 1){$state.Pending[0].Intent.TransactionId}else{$null});
            QualificationStatus='NOT_EXECUTED';Ready=$false;MutationAllowed=$false};ErrorCode=$null}
    }catch{return [pscustomobject]@{Success=$false;Value=$null;ErrorCode='TLS_REGISTRY_WRITER_PREVIEW_INVALID'}}
    finally{Exit-LabTlsRegistryWriterLock $lock}
}

function Invoke-LabAuthenticatedTlsRegistryWrite {
    [CmdletBinding()]
    param([object]$DataRoot,[object]$ControllerId,[object]$LocationId,[object]$Context,
        [object]$Operation,[object]$ExpectedRootDigest,[object]$ExpectedActorDigest,[object]$ExpectedSourceSha256,
        [object]$CandidateBytes,[object]$TransactionId)
    $lock=$null;$started=$false
    try{
        if(-not (Test-LabTlsCaCandidateInput $DataRoot $ControllerId $LocationId $Context) -or
            -not (Test-LabTlsRequestEnum $Operation @('INITIALIZE','UPDATE','RECOVER_COMMIT','RECOVER_ABORT'))){throw 'TLS_REGISTRY_INPUT_INVALID'}
        foreach($digest in @($ExpectedRootDigest,$ExpectedActorDigest)){
            if($digest -isnot [string] -or $digest -cnotmatch '\A[0-9a-f]{64}\z'){throw 'TLS_REGISTRY_INPUT_INVALID'}
        }
        if($ExpectedSourceSha256 -isnot [string] -or $ExpectedSourceSha256 -cnotmatch '\A(?:ABSENT|[0-9a-f]{64})\z'){throw 'TLS_REGISTRY_INPUT_INVALID'}
        # Keine auf Caller-Strings angehaengten ETS-Methoden aufrufen.
        $recover=Test-LabTlsRequestEnum $Operation @('RECOVER_COMMIT','RECOVER_ABORT')
        if($recover){
            if(-not (Test-LabTlsRequestReference $TransactionId) -or $null -ne $CandidateBytes){throw 'TLS_REGISTRY_INPUT_INVALID'}
        }elseif($null -ne $TransactionId){throw 'TLS_REGISTRY_INPUT_INVALID'}
        $candidate=$null
        if(-not $recover){
            $parsed=Read-LabAuthenticatedTlsRegistryDocument $CandidateBytes
            if(-not $parsed.Success){throw 'TLS_REGISTRY_INPUT_INVALID'}
            # Eigene Bytekopie vor jeglichem I/O; Caller kann sie nicht nachtraeglich aendern.
            $candidate=[byte[]]::new([array].GetProperty('Length').GetValue($CandidateBytes));[Buffer]::BlockCopy($CandidateBytes,0,$candidate,0,$candidate.Length)
            $parsed=Read-LabAuthenticatedTlsRegistryDocument $candidate
            if(-not $parsed.Success -or $parsed.Value.RegistryDocument.Index.ControllerId -cne $ControllerId -or
                $parsed.Value.RegistryDocument.Index.LocationId -cne $LocationId){throw 'TLS_REGISTRY_INPUT_INVALID'}
            if($Operation -ceq 'INITIALIZE' -and ($ExpectedSourceSha256 -cne 'ABSENT' -or $parsed.Value.RegistryDocument.Index.Revision -ne 0 -or
                $parsed.Value.RegistryDocument.Payloads.Count -ne 0)){throw 'TLS_REGISTRY_INPUT_INVALID'}
        }
        $b=Get-LabTlsRegistryWriterBinding $DataRoot $ControllerId $LocationId
        $lock=Enter-LabTlsRegistryWriterLock $b
        Assert-LabTlsRegistryWriterBinding $b $ExpectedRootDigest $ExpectedActorDigest
        if($Operation -ceq 'INITIALIZE'){
            if(Test-Path -LiteralPath $b.Directory){throw 'TLS_REGISTRY_ALREADY_EXISTS'}
            $started=$true
            Initialize-LabTlsCaPrivateDirectory $b.Directory $b.Native.UserSid -NewOnly
            Write-LabTlsCaPrivateFile (Join-Path $b.Directory 'writer.lock') $b.Native.UserSid ([byte[]]@(0))
            $lock.Stream=[IO.File]::Open((Join-Path $b.Directory 'writer.lock'),[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
            $owner=[ordered]@{ContractVersion='SqlServerLab.TlsRegistryOwner/0.1';RegistryId=[guid]::NewGuid().ToString('D');
                ControllerId=$b.Root.ControllerId;LocationId=$b.Root.LocationId;RootDigest=$ExpectedRootDigest;ActorDigest=$ExpectedActorDigest}
            Write-LabTlsCaPrivateFile (Join-Path $b.Directory 'owner.json') $b.Native.UserSid (ConvertTo-LabTlsRegistryWriterBytes $owner)
        }else{
            $state=Read-LabTlsRegistryWriterState $b;$owner=$state.Owner
            if($state.Digest -cne $ExpectedSourceSha256){throw 'TLS_REGISTRY_SOURCE_CHANGED'}
            if($recover){
                if($state.Pending.Count -ne 1 -or $state.Pending[0].Intent.TransactionId -cne $TransactionId){throw 'TLS_REGISTRY_RECOVERY_INVALID'}
                $intent=$state.Pending[0].Intent
                $required=if($Operation -ceq 'RECOVER_COMMIT'){'CANDIDATE_INSTALLED'}else{'SOURCE_UNCHANGED'}
                if($state.Status -cne $required){throw 'TLS_REGISTRY_RECOVERY_INVALID'}
                Assert-LabTlsRegistryWriterBinding $b $ExpectedRootDigest $ExpectedActorDigest
                if($Operation -ceq 'RECOVER_COMMIT'){
                    $recovered=(Read-LabAuthenticatedTlsRegistryDocument $state.Bytes).Value.RegistryDocument
                    Assert-LabTlsRegistryFreshPayloads ([pscustomobject]@{Payloads=@()}) $recovered $b ([Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal))
                }
                # Recovery fuehrt keinen Ersatz aus. Sie bestaetigt nur exakt gelesene Bytes.
                $started=$true
                Write-LabTlsRegistryTerminal $b $intent $(if($Operation -ceq 'RECOVER_COMMIT'){'COMMITTED'}else{'ABORTED'})
                return [pscustomobject]@{Success=$true;Value=[pscustomobject]@{Status=$(if($Operation -ceq 'RECOVER_COMMIT'){'RECOVERY_COMMITTED'}else{'RECOVERY_ABORTED'});
                    TransactionId=$intent.TransactionId;RegistryByteSha256=$state.Digest;QualificationStatus='NOT_EXECUTED';Ready=$false;MutationAllowed=$false};ErrorCode=$null}
            }
            if($state.Status -cne 'COMMITTED' -or $state.Pending.Count -ne 0 -or $state.Intents.Count -ge 256){throw 'TLS_REGISTRY_RECOVERY_REQUIRED'}
            $transition=Test-LabAuthenticatedTlsRegistryDocumentTransition $state.Bytes $candidate
            if(-not $transition.Success){throw 'TLS_REGISTRY_TRANSITION_INVALID'}
            $before=(Read-LabAuthenticatedTlsRegistryDocument $state.Bytes).Value.RegistryDocument
            Assert-LabTlsRegistryFreshPayloads $before $parsed.Value.RegistryDocument $b $state.Reserved
        }
        $id=[guid]::NewGuid().ToString('D');$candidateSha=Get-LabTlsCaByteDigest $candidate
        $intent=[ordered]@{ContractVersion='SqlServerLab.TlsRegistryIntent/0.1';TransactionId=$id;RegistryId=$owner.RegistryId;
            RootDigest=$ExpectedRootDigest;ActorDigest=$ExpectedActorDigest;SourceSha256=$ExpectedSourceSha256;
            CandidateSha256=$candidateSha;CandidateBase64=[Convert]::ToBase64String($candidate)}
        $started=$true
        Write-LabTlsCaPrivateFile (Join-Path $b.Directory ($id+'.intent.json')) $b.Native.UserSid (ConvertTo-LabTlsRegistryWriterBytes $intent)
        $candidatePath=Join-Path $b.Directory ($id+'.candidate.json')
        Write-LabTlsCaPrivateFile $candidatePath $b.Native.UserSid $candidate
        $readback=Read-LabTlsCaPrivateFile $candidatePath $b.Native.UserSid 4194304
        if((Get-LabTlsCaByteDigest $readback) -cne $candidateSha -or -not (Read-LabAuthenticatedTlsRegistryDocument $readback).Success){throw 'TLS_REGISTRY_CANDIDATE_CHANGED'}
        Assert-LabTlsRegistryWriterBinding $b $ExpectedRootDigest $ExpectedActorDigest
        $registry=Join-Path $b.Directory 'registry.json'
        if($Operation -ceq 'UPDATE'){Assert-LabTlsRegistryFreshPayloads $before $parsed.Value.RegistryDocument $b $state.Reserved}
        if($Operation -ceq 'INITIALIZE'){
            if(Test-Path -LiteralPath $registry){throw 'TLS_REGISTRY_SOURCE_CHANGED'}
            [IO.File]::Move($candidatePath,$registry)
        }else{
            $current=Read-LabTlsCaPrivateFile $registry $b.Native.UserSid 4194304
            if((Get-LabTlsCaByteDigest $current) -cne $ExpectedSourceSha256){throw 'TLS_REGISTRY_SOURCE_CHANGED'}
            # PowerShell bindet $null fuer diesen Stringparameter als Leerpfad.
            # Ein eigener CreateNew-gepruefter Backupname erhaelt zugleich die Quelle.
            $backupPath=Join-Path $b.Directory ($id+'.source.json')
            if(Test-Path -LiteralPath $backupPath){throw 'TLS_REGISTRY_ARTIFACT_UNKNOWN'}
            [IO.File]::Replace($candidatePath,$registry,$backupPath,$false)
        }
        $installed=Read-LabTlsCaPrivateFile $registry $b.Native.UserSid 4194304
        if((Get-LabTlsCaByteDigest $installed) -cne $candidateSha -or -not (Read-LabAuthenticatedTlsRegistryDocument $installed).Success){throw 'TLS_REGISTRY_READBACK_INVALID'}
        Assert-LabTlsRegistryWriterBinding $b $ExpectedRootDigest $ExpectedActorDigest
        if($Operation -ceq 'UPDATE'){Assert-LabTlsRegistryFreshPayloads $before $parsed.Value.RegistryDocument $b $state.Reserved}
        Write-LabTlsRegistryTerminal $b ([pscustomobject]$intent) 'COMMITTED'
        $final=Read-LabTlsRegistryWriterState $b
        if($final.Status -cne 'COMMITTED' -or $final.Digest -cne $candidateSha){throw 'TLS_REGISTRY_COMMIT_INVALID'}
        return [pscustomobject]@{Success=$true;Value=[pscustomobject]@{Status='METADATA_COMMITTED';TransactionId=$id;RegistryByteSha256=$candidateSha;
            QualificationStatus='NOT_EXECUTED';Ready=$false;MutationAllowed=$false};ErrorCode=$null}
    }catch{
        return [pscustomobject]@{Success=$false;Value=$null;ErrorCode=$(if($started){'TLS_REGISTRY_RECOVERY_REQUIRED'}else{'TLS_REGISTRY_WRITE_REJECTED'})}
    }finally{Exit-LabTlsRegistryWriterLock $lock}
}
