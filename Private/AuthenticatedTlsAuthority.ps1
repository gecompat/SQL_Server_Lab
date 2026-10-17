#Requires -Version 7.2
# Operational Windows binding. No trust import or CA/key adoption by path.
function New-LabTlsNativeContextPayload {
    param([string]$ControllerId,[string]$LocationId,[string]$Kind,[string]$Reference)
    $request=[ordered]@{ContractVersion='SqlServerLab.AuthenticatedTlsContextRequest/0.1';RequestId=[guid]::NewGuid().ToString('D');Kind=$Kind;Context='CURRENT_WINDOWS_PROCESS'}
    if($Kind -ceq 'CLIENT_CONTEXT'){$request.ClientRef=$Reference;$request.Store='CURRENT_USER_ROOT';$request.ClientStacks=@('SYSTEM_DATA_SQLCLIENT','ODBC_SQLCMD')}
    elseif($Kind -ceq 'SIGNER_CONTEXT'){$request.SignerContextRef=$Reference;$request.Backend='DOTNET_X509'}else{throw 'TLS_AUTHORITY_CONTEXT_INVALID'}
    $preview=Get-LabAuthenticatedTlsContextPreview ([pscustomobject]$request)
    if(-not $preview.Success){throw 'TLS_AUTHORITY_CONTEXT_UNAVAILABLE'}
    $v=$preview.Value
    $payload=[ordered]@{ContractVersion='SqlServerLab.AuthenticatedTlsRegistryPayload/0.1';ControllerId=$ControllerId;LocationId=$LocationId;Kind=$Kind;
        Ref=$Reference;Generation=1;Status='ACTIVE';Context='CURRENT_WINDOWS_PROCESS';
        Actor=[pscustomobject][ordered]@{UserSid=$v.Process.UserSid;HostMarker=$v.Process.HostMarker;ProfilePath=$v.Process.ProfilePath}}
    if($Kind -ceq 'CLIENT_CONTEXT'){
        $b=$v.Binaries
        $payload.Details=[pscustomobject][ordered]@{Store=$v.Store;ClientStacks=$v.ClientStacks;SqlClientPath=$b.SqlClient.Path;SqlClientDiskSha256=$b.SqlClient.DiskSha256;SqlClientDiskBytes=$b.SqlClient.DiskBytes;
            SqlClientAssembly=$b.SqlClientAssembly;SqlClientLoadedMvid=$b.SqlClientLoadedMvid;SqlcmdPath=$b.Sqlcmd.Path;SqlcmdDiskSha256=$b.Sqlcmd.DiskSha256;SqlcmdDiskBytes=$b.Sqlcmd.DiskBytes;
            BinaryEvidence='ON_DISK_BYTES_ONLY';LoadedImageDigestStatus='NOT_MEASURED';SqlcmdFlavorStatus='NOT_QUALIFIED';LoadedOdbcDriverStatus='NOT_EXECUTED'}
    }else{$payload.Details=[pscustomobject][ordered]@{Backend=$v.Backend.Backend;RuntimeVersion=$v.Backend.RuntimeVersion;ApiStatus=$v.Backend.ApiStatus;Apis=$v.Backend.Apis;KeyProtectionStatus=$v.KeyProtectionStatus}}
    $parsed=Read-LabAuthenticatedTlsRegistryPayload (ConvertTo-LabTlsRegistryWriterBytes ([pscustomobject]$payload))
    if(-not $parsed.Success){throw 'TLS_AUTHORITY_CONTEXT_INVALID'}
    return $parsed.Value.Payload
}

function Assert-LabTlsOperationalAuthority {
    param([object]$Payload,[object]$Document,[object]$Binding)
    if($Payload.Kind -cne 'AUTHORITY' -or $Payload.ContractVersion -cne 'SqlServerLab.AuthenticatedTlsRegistryPayload/0.2' -or $Payload.Status -cne 'ACTIVE'){throw 'TLS_AUTHORITY_INVALID'}
    $client=@($Document.Payloads|Where-Object {$_.Ref -ceq $Payload.ClientRef})
    $signer=@($Document.Payloads|Where-Object {$_.Ref -ceq $Payload.SignerContextRef})
    if($client.Count -ne 1 -or $signer.Count -ne 1 -or $client[0].Kind -cne 'CLIENT_CONTEXT' -or $signer[0].Kind -cne 'SIGNER_CONTEXT' -or
        $client[0].Status -cne 'ACTIVE' -or $signer[0].Status -cne 'ACTIVE' -or $client[0].Generation -ne $Payload.ClientGeneration -or $signer[0].Generation -ne $Payload.SignerGeneration){throw 'TLS_AUTHORITY_CONTEXT_INVALID'}
    $preview=Get-LabAuthenticatedTlsAuthorityPreview $Binding.Root.DataRoot $Payload.ControllerId $Payload.LocationId CURRENT_WINDOWS_PROCESS `
        (ConvertTo-LabTlsRegistryWriterBytes $Payload) (ConvertTo-LabTlsRegistryWriterBytes $signer[0]) (ConvertTo-LabTlsRegistryWriterBytes $client[0])
    if(-not $preview.Success){throw 'TLS_AUTHORITY_METADATA_OR_TRUST_CHANGED'}
    $ca=Get-LabTlsCaCandidateBinding $Binding.Root.DataRoot $Payload.ControllerId $Payload.LocationId $Payload.CandidateId
    if($ca.ActorDigest -cne (Get-LabTlsCaActorDigest $Binding.Native) -or $ca.RootMetadataDigest -cne $Binding.Root.RootMetadataDigest){throw 'TLS_AUTHORITY_ROOT_OR_ACTOR_CHANGED'}
    if($ca.Certificate.Sha256 -cne $Payload.CertificateSha256 -or (Get-LabTlsCaByteDigest $ca.Encrypted) -cne $Payload.EncryptedKeySha256){throw 'TLS_AUTHORITY_CA_BYTES_CHANGED'}
    if($ca.Certificate.NotBeforeUtc -cne $Payload.NotBeforeUtc -or $ca.Certificate.NotAfterUtc -cne $Payload.NotAfterUtc){throw 'TLS_AUTHORITY_VALIDITY_CHANGED'}
    if([DateTimeOffset]::UtcNow -lt [DateTimeOffset]::ParseExact($Payload.NotBeforeUtc,'o',[Globalization.CultureInfo]::InvariantCulture) -or [DateTimeOffset]::UtcNow -ge [DateTimeOffset]::ParseExact($Payload.NotAfterUtc,'o',[Globalization.CultureInfo]::InvariantCulture)){throw 'TLS_AUTHORITY_EXPIRED_OR_NOT_YET_VALID'}
    if((Get-LabTlsCaExistingTrust $ca.Der) -cne 'IDENTICAL_PREEXISTING_NOT_OWNED'){throw 'TLS_AUTHORITY_TRUST_CHANGED'}
    # Fresh possession proof; plaintext is zeroed by the existing key opener.
    $entropy=[Text.Encoding]::UTF8.GetBytes((Get-LabTlsPayloadDigest @('SqlServerLab.TlsCaCandidateKey/0.1',$Payload.CandidateId,$Payload.ControllerId,$Payload.LocationId,$ca.RootMetadataDigest,$ca.ActorDigest)))
    Assert-LabTlsCaEncryptedKey $ca.Encrypted $entropy $ca.Der
    $again=Get-LabTlsCaCandidateBinding $Binding.Root.DataRoot $Payload.ControllerId $Payload.LocationId $Payload.CandidateId
    if($again.Digest -cne $ca.Digest -or (Get-LabTlsCaExistingTrust $again.Der) -cne 'IDENTICAL_PREEXISTING_NOT_OWNED'){throw 'TLS_AUTHORITY_CA_OR_TRUST_CHANGED'}
}

function Get-LabTlsOperationalAuthority {
    param([string]$DataRoot,[string]$ControllerId,[string]$LocationId,[string]$AuthorityRef,[string]$ClientRef)
    foreach($ref in @($ControllerId,$LocationId,$AuthorityRef,$ClientRef)){if(-not (Test-LabTlsRequestReference $ref)){throw 'TLS_AUTHORITY_REFERENCE_INVALID'}}
    $binding=Get-LabTlsRegistryWriterBinding $DataRoot $ControllerId $LocationId;$lock=$null
    try{
        $lock=Enter-LabTlsRegistryWriterLock $binding;$state=Read-LabTlsRegistryWriterState $binding
        if($state.Status -cne 'COMMITTED' -or $state.Pending.Count -ne 0){throw 'TLS_AUTHORITY_REGISTRY_UNCONFIRMED'}
        $document=(Read-LabAuthenticatedTlsRegistryDocument $state.Bytes).Value.RegistryDocument
        $authority=@($document.Payloads|Where-Object {$_.Kind -ceq 'AUTHORITY' -and $_.Ref -ceq $AuthorityRef})
        if($authority.Count -ne 1 -or $authority[0].ClientRef -cne $ClientRef){throw 'TLS_AUTHORITY_REFERENCE_INVALID'}
        Assert-LabTlsOperationalAuthority $authority[0] $document $binding
        Assert-LabTlsRegistryWriterBinding $binding $binding.Root.RootMetadataDigest $binding.ActorDigest
        return [pscustomobject]@{Authority=$authority[0];Client=@($document.Payloads|Where-Object Ref -CEQ $ClientRef)[0];
            RegistrySha256=$state.Digest;RootDigest=$binding.Root.RootMetadataDigest;ActorDigest=$binding.ActorDigest;Native=$binding.Native}
    }finally{Exit-LabTlsRegistryWriterLock $lock}
}

function Register-LabTlsOperationalAuthority {
    param([string]$DataRoot,[string]$ControllerId,[string]$LocationId,[string]$CandidateId)
    if(-not (Test-LabTlsCaCandidateInput $DataRoot $ControllerId $LocationId CURRENT_WINDOWS_PROCESS) -or -not (Test-LabTlsRequestReference $CandidateId)){throw 'TLS_AUTHORITY_INPUT_INVALID'}
    $ca=Get-LabTlsCaCandidateBinding $DataRoot $ControllerId $LocationId $CandidateId
    if((Get-LabTlsCaExistingTrust $ca.Der) -cne 'IDENTICAL_PREEXISTING_NOT_OWNED'){throw 'TLS_AUTHORITY_TRUST_REQUIRED'}
    $entropy=[Text.Encoding]::UTF8.GetBytes((Get-LabTlsPayloadDigest @('SqlServerLab.TlsCaCandidateKey/0.1',$CandidateId,$ControllerId,$LocationId,$ca.RootMetadataDigest,$ca.ActorDigest)))
    Assert-LabTlsCaEncryptedKey $ca.Encrypted $entropy $ca.Der
    $sqlClientProbe=[System.Data.SqlClient.SqlConnection]::new();$sqlClientProbe.Dispose()
    $prototypes=@{}
    foreach($kind in @('CLIENT_CONTEXT','SIGNER_CONTEXT')){$prototypes[$kind]=New-LabTlsNativeContextPayload $ControllerId $LocationId $kind ([guid]::NewGuid().ToString('D'))}
    $preview=Get-LabAuthenticatedTlsRegistryWriterPreview $DataRoot $ControllerId $LocationId CURRENT_WINDOWS_PROCESS
    if(-not $preview.Success){throw 'TLS_AUTHORITY_REGISTRY_UNAVAILABLE'}
    $document=[pscustomobject]@{ContractVersion='SqlServerLab.AuthenticatedTlsContextRegistry/0.1';
        Index=[pscustomobject]@{ContractVersion='SqlServerLab.AuthenticatedTlsRegistryIndex/0.1';ControllerId=$ControllerId;LocationId=$LocationId;Revision=0;Records=@()};Payloads=@()}
    if($preview.Value.Status -ceq 'NOT_INITIALIZED'){
        $created=Invoke-LabAuthenticatedTlsRegistryWrite $DataRoot $ControllerId $LocationId CURRENT_WINDOWS_PROCESS INITIALIZE $preview.Value.RootMetadataDigest $preview.Value.ActorDigest ABSENT (ConvertTo-LabTlsRegistryWriterBytes $document)
        if(-not $created.Success){throw 'TLS_AUTHORITY_REGISTRY_INITIALIZATION_UNCONFIRMED'}
    }
    $binding=Get-LabTlsRegistryWriterBinding $DataRoot $ControllerId $LocationId;$lock=$null
    try{
        $lock=Enter-LabTlsRegistryWriterLock $binding;$state=Read-LabTlsRegistryWriterState $binding
        if($state.Status -cne 'COMMITTED' -or $state.Pending.Count -ne 0){throw 'TLS_AUTHORITY_REGISTRY_UNCONFIRMED'}
        $document=(Read-LabAuthenticatedTlsRegistryDocument $state.Bytes).Value.RegistryDocument
    }finally{Exit-LabTlsRegistryWriterLock $lock}
    $payloads=@($document.Payloads);$contexts=@{}
    foreach($kind in @('CLIENT_CONTEXT','SIGNER_CONTEXT')){
        $fresh=$prototypes[$kind]
        $record=Get-LabTlsPayloadIndexRecord $fresh
        $matching=@($payloads|Where-Object {$_.Kind -ceq $kind -and $_.Status -ceq 'ACTIVE' -and (Get-LabTlsPayloadIndexRecord $_).IdentityDigest -ceq $record.IdentityDigest})
        if($matching.Count -gt 1){throw 'TLS_AUTHORITY_CONTEXT_AMBIGUOUS'}
        if($matching.Count -eq 1){
            if((Get-LabTlsPayloadIndexRecord $matching[0]).RevisionDigest -cne $record.RevisionDigest){throw 'TLS_AUTHORITY_CONTEXT_CHANGED'}
            $fresh=$matching[0]
        }else{$payloads+=@($fresh)}
        $contexts[$kind]=$fresh
    }
    $client=$contexts.CLIENT_CONTEXT;$signer=$contexts.SIGNER_CONTEXT
    $existing=@($document.Payloads|Where-Object {$_.ContractVersion -ceq 'SqlServerLab.AuthenticatedTlsRegistryPayload/0.2' -and $_.Status -ceq 'ACTIVE' -and $_.CandidateId -ceq $CandidateId -and $_.ClientRef -ceq $client.Ref -and $_.SignerContextRef -ceq $signer.Ref})
    if($existing.Count -gt 1){throw 'TLS_AUTHORITY_AMBIGUOUS'}
    if($existing.Count -eq 1){return Get-LabTlsOperationalAuthority $DataRoot $ControllerId $LocationId $existing[0].Ref $client.Ref}
    $authority=[pscustomobject][ordered]@{ContractVersion='SqlServerLab.AuthenticatedTlsRegistryPayload/0.2';ControllerId=$ControllerId;LocationId=$LocationId;
        Kind='AUTHORITY';Ref=[guid]::NewGuid().ToString('D');Generation=1;Status='ACTIVE';TrustScopeRef=[guid]::NewGuid().ToString('D');SignerContextRef=$signer.Ref;SignerGeneration=$signer.Generation;
        KeyStatus='CIPHERTEXT_BOUND_NOT_OPENED';CertificateStatus='PROFILE_BOUND_NOT_QUALIFIED';CandidateId=$CandidateId;ClientRef=$client.Ref;ClientGeneration=$client.Generation;
        CandidateBindingDigest=$ca.Digest;CertificateSha256=$ca.Certificate.Sha256;EncryptedKeySha256=(Get-LabTlsCaByteDigest $ca.Encrypted);
        NotBeforeUtc=$ca.Certificate.NotBeforeUtc;NotAfterUtc=$ca.Certificate.NotAfterUtc;Store='CURRENT_USER_ROOT';TrustStatus='IDENTICAL_PREEXISTING_NOT_OWNED'}
    $payloads+=@($authority)
    $next=[pscustomobject]@{ContractVersion=$document.ContractVersion;Index=[pscustomobject]@{ContractVersion=$document.Index.ContractVersion;ControllerId=$ControllerId;LocationId=$LocationId;
        Revision=([int]$document.Index.Revision+1);Records=@($payloads|ForEach-Object {Get-LabTlsPayloadIndexRecord $_})};Payloads=$payloads}
    $written=Invoke-LabAuthenticatedTlsRegistryWrite $DataRoot $ControllerId $LocationId CURRENT_WINDOWS_PROCESS UPDATE $binding.Root.RootMetadataDigest $binding.ActorDigest $state.Digest (ConvertTo-LabTlsRegistryWriterBytes $next)
    if(-not $written.Success){throw 'TLS_AUTHORITY_REGISTRATION_UNCONFIRMED'}
    return Get-LabTlsOperationalAuthority $DataRoot $ControllerId $LocationId $authority.Ref $client.Ref
}
