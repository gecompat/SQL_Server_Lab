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

function New-LabTlsRevisedContextPayload {
    param([object]$Current,[object]$Fresh)
    if($Current.Kind -cnotin @('CLIENT_CONTEXT','SIGNER_CONTEXT') -or $Fresh.Kind -cne $Current.Kind -or
        $Current.Status -cne 'ACTIVE' -or $Fresh.Status -cne 'ACTIVE' -or
        $Current.Generation -ge [int]::MaxValue -or $Current.ControllerId -cne $Fresh.ControllerId -or
        $Current.LocationId -cne $Fresh.LocationId -or $Current.Context -cne $Fresh.Context -or
        $Current.Actor.UserSid -cne $Fresh.Actor.UserSid -or $Current.Actor.HostMarker -cne $Fresh.Actor.HostMarker -or
        $Current.Actor.ProfilePath -cne $Fresh.Actor.ProfilePath){throw 'TLS_AUTHORITY_CONTEXT_IDENTITY_CHANGED'}
    $oldRecord=Get-LabTlsPayloadIndexRecord $Current
    $Fresh.Ref=$Current.Ref;$Fresh.Generation=[int]($Current.Generation+1)
    $parsed=Read-LabAuthenticatedTlsRegistryPayload (ConvertTo-LabTlsRegistryWriterBytes $Fresh)
    if(-not $parsed.Success -or $parsed.Value.IndexRecord.IdentityDigest -cne $oldRecord.IdentityDigest -or
        $parsed.Value.IndexRecord.RevisionDigest -ceq $oldRecord.RevisionDigest){throw 'TLS_AUTHORITY_CONTEXT_REVISION_INVALID'}
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
    param([string]$DataRoot,[string]$ControllerId,[string]$LocationId,[string]$CandidateId,[string]$ExpectedRegistrySha256)
    if($ExpectedRegistrySha256-and$ExpectedRegistrySha256-cnotmatch'\A[0-9a-f]{64}\z'){throw 'TLS_AUTHORITY_EXPECTED_REGISTRY_INVALID'}
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
    if($ExpectedRegistrySha256-and$preview.Value.Status-cne'COMMITTED'){throw 'TLS_AUTHORITY_EXPECTED_REGISTRY_CHANGED'}
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
        if($ExpectedRegistrySha256-and$state.Digest-cne$ExpectedRegistrySha256){throw 'TLS_AUTHORITY_EXPECTED_REGISTRY_CHANGED'}
        $document=(Read-LabAuthenticatedTlsRegistryDocument $state.Bytes).Value.RegistryDocument
    }finally{Exit-LabTlsRegistryWriterLock $lock}
    $payloads=[Collections.Generic.List[object]]::new();foreach($item in $document.Payloads){$payloads.Add($item)}
    $contexts=@{};$updatedContextRefs=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $allCandidateAuthorities=@($payloads|Where-Object {$_.Kind -ceq 'AUTHORITY' -and $_.ContractVersion -ceq 'SqlServerLab.AuthenticatedTlsRegistryPayload/0.2' -and $_.CandidateId -ceq $CandidateId})
    $activeCandidateAuthorities=@($allCandidateAuthorities|Where-Object Status -CEQ 'ACTIVE')
    if($activeCandidateAuthorities.Count -gt 1){throw 'TLS_AUTHORITY_AMBIGUOUS'}
    if($allCandidateAuthorities.Count -gt 0 -and $activeCandidateAuthorities.Count -eq 0){throw 'TLS_AUTHORITY_CANDIDATE_RETIRED'}
    foreach($kind in @('CLIENT_CONTEXT','SIGNER_CONTEXT')){
        $fresh=$prototypes[$kind]
        $record=Get-LabTlsPayloadIndexRecord $fresh
        $matching=@($payloads|Where-Object {$_.Kind -ceq $kind -and $_.Status -ceq 'ACTIVE' -and (Get-LabTlsPayloadIndexRecord $_).IdentityDigest -ceq $record.IdentityDigest})
        if($matching.Count -gt 1){throw 'TLS_AUTHORITY_CONTEXT_AMBIGUOUS'}
        $expectedRef=if($activeCandidateAuthorities.Count -eq 1){if($kind -ceq 'CLIENT_CONTEXT'){$activeCandidateAuthorities[0].ClientRef}else{$activeCandidateAuthorities[0].SignerContextRef}}else{$null}
        if($matching.Count -eq 1){
            if($expectedRef -and $matching[0].Ref -cne $expectedRef){throw 'TLS_AUTHORITY_CONTEXT_IDENTITY_CHANGED'}
            $oldRecord=Get-LabTlsPayloadIndexRecord $matching[0]
            if($oldRecord.RevisionDigest -cne $record.RevisionDigest){
                $fresh=New-LabTlsRevisedContextPayload $matching[0] $fresh
                for($i=0;$i -lt $payloads.Count;$i++){if($payloads[$i].Ref -ceq $matching[0].Ref){$payloads[$i]=$fresh;break}}
                $null=$updatedContextRefs.Add($fresh.Ref)
            }else{$fresh=$matching[0]}
        }else{
            if($expectedRef){throw 'TLS_AUTHORITY_CONTEXT_IDENTITY_CHANGED'}
            $payloads.Add($fresh)
        }
        $contexts[$kind]=$fresh
    }
    $client=$contexts.CLIENT_CONTEXT;$signer=$contexts.SIGNER_CONTEXT
    $existing=@($payloads|Where-Object {$_.ContractVersion -ceq 'SqlServerLab.AuthenticatedTlsRegistryPayload/0.2' -and $_.Status -ceq 'ACTIVE' -and $_.CandidateId -ceq $CandidateId -and $_.ClientRef -ceq $client.Ref -and $_.SignerContextRef -ceq $signer.Ref})
    if($existing.Count -gt 1){throw 'TLS_AUTHORITY_AMBIGUOUS'}
    if($activeCandidateAuthorities.Count -eq 1 -and $existing.Count -ne 1){throw 'TLS_AUTHORITY_CONTEXT_IDENTITY_CHANGED'}
    if($updatedContextRefs.Count){
        $shared=@($payloads|Where-Object {$_.Kind -ceq 'AUTHORITY' -and $_.Status -ceq 'ACTIVE' -and
            (($_.SignerContextRef -and $updatedContextRefs.Contains($_.SignerContextRef)) -or ($_.ClientRef -and $updatedContextRefs.Contains($_.ClientRef))) -and
            ($existing.Count -ne 1 -or $_.Ref -cne $existing[0].Ref)})
        if($shared.Count){throw 'TLS_AUTHORITY_CONTEXT_SHARED'}
    }
    if($existing.Count -eq 1 -and $updatedContextRefs.Count -eq 0){
        $current=Get-LabTlsOperationalAuthority $DataRoot $ControllerId $LocationId $existing[0].Ref $client.Ref
        if($ExpectedRegistrySha256-and$current.RegistrySha256-cne$ExpectedRegistrySha256){throw 'TLS_AUTHORITY_EXPECTED_REGISTRY_CHANGED'}
        return $current
    }
    if($existing.Count -eq 1){
        $authority=$existing[0]
        if($authority.Generation -ge [int]::MaxValue -or $authority.CandidateBindingDigest -cne $ca.Digest -or
            $authority.CertificateSha256 -cne $ca.Certificate.Sha256 -or $authority.EncryptedKeySha256 -cne (Get-LabTlsCaByteDigest $ca.Encrypted) -or
            $authority.NotBeforeUtc -cne $ca.Certificate.NotBeforeUtc -or $authority.NotAfterUtc -cne $ca.Certificate.NotAfterUtc -or
            $authority.Store -cne 'CURRENT_USER_ROOT' -or $authority.TrustStatus -cne 'IDENTICAL_PREEXISTING_NOT_OWNED') {throw 'TLS_AUTHORITY_CA_OR_TRUST_CHANGED'}
        $authority.Generation=[int]($authority.Generation+1);$authority.ClientGeneration=$client.Generation;$authority.SignerGeneration=$signer.Generation
    }else{
        $authority=[pscustomobject][ordered]@{ContractVersion='SqlServerLab.AuthenticatedTlsRegistryPayload/0.2';ControllerId=$ControllerId;LocationId=$LocationId;
            Kind='AUTHORITY';Ref=[guid]::NewGuid().ToString('D');Generation=1;Status='ACTIVE';TrustScopeRef=[guid]::NewGuid().ToString('D');SignerContextRef=$signer.Ref;SignerGeneration=$signer.Generation;
            KeyStatus='CIPHERTEXT_BOUND_NOT_OPENED';CertificateStatus='PROFILE_BOUND_NOT_QUALIFIED';CandidateId=$CandidateId;ClientRef=$client.Ref;ClientGeneration=$client.Generation;
            CandidateBindingDigest=$ca.Digest;CertificateSha256=$ca.Certificate.Sha256;EncryptedKeySha256=(Get-LabTlsCaByteDigest $ca.Encrypted);
            NotBeforeUtc=$ca.Certificate.NotBeforeUtc;NotAfterUtc=$ca.Certificate.NotAfterUtc;Store='CURRENT_USER_ROOT';TrustStatus='IDENTICAL_PREEXISTING_NOT_OWNED'}
        $payloads.Add($authority)
    }
    $revision=[long]$document.Index.Revision;if($revision -ge [int]::MaxValue){throw 'TLS_AUTHORITY_REGISTRY_REVISION_OVERFLOW'}
    $next=[pscustomobject]@{ContractVersion=$document.ContractVersion;Index=[pscustomobject]@{ContractVersion=$document.Index.ContractVersion;ControllerId=$ControllerId;LocationId=$LocationId;
        Revision=[int]($revision+1);Records=@($payloads|ForEach-Object {Get-LabTlsPayloadIndexRecord $_})};Payloads=@($payloads.ToArray())}
    $candidateBytes=ConvertTo-LabTlsRegistryWriterBytes $next
    if(-not (Read-LabAuthenticatedTlsRegistryDocument $candidateBytes).Success){throw 'TLS_AUTHORITY_REGISTRY_REVISION_INVALID'}
    $written=Invoke-LabAuthenticatedTlsRegistryWrite $DataRoot $ControllerId $LocationId CURRENT_WINDOWS_PROCESS UPDATE $binding.Root.RootMetadataDigest $binding.ActorDigest $state.Digest $candidateBytes
    if(-not $written.Success){throw 'TLS_AUTHORITY_REGISTRATION_UNCONFIRMED'}
    return Get-LabTlsOperationalAuthority $DataRoot $ControllerId $LocationId $authority.Ref $client.Ref
}

function Read-LabTlsAuthorityJournalJson {
    param([string]$Path,[string]$UserSid,[int]$MaximumBytes,[int]$MaximumDepth,[string[]]$Fields)
    $bytes=Read-LabTlsCaPrivateFile $Path $UserSid $MaximumBytes
    try{$text=[Text.UTF8Encoding]::new($false,$true).GetString($bytes)}catch{throw 'TLS_AUTHORITY_USE_UNCONFIRMED'}
    $options=[Text.Json.JsonDocumentOptions]::new();$options.MaxDepth=$MaximumDepth
    try{$document=[Text.Json.JsonDocument]::Parse($text,$options)}catch{throw 'TLS_AUTHORITY_USE_UNCONFIRMED'}
    try{
        if($document.RootElement.ValueKind -ne [Text.Json.JsonValueKind]::Object){throw 'TLS_AUTHORITY_USE_UNCONFIRMED'}
        $pending=[Collections.Generic.Stack[Text.Json.JsonElement]]::new();$pending.Push($document.RootElement);$nodes=0
        while($pending.Count){if(++$nodes -gt 8192){throw 'TLS_AUTHORITY_USE_UNCONFIRMED'};$element=$pending.Pop()
            if($element.ValueKind -eq [Text.Json.JsonValueKind]::Object){$keys=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
                foreach($property in $element.EnumerateObject()){if(-not $keys.Add($property.Name)){throw 'TLS_AUTHORITY_USE_UNCONFIRMED'};$pending.Push($property.Value)}}
            elseif($element.ValueKind -eq [Text.Json.JsonValueKind]::Array){foreach($child in $element.EnumerateArray()){$pending.Push($child)}}
        }
        $value=$text|ConvertFrom-Json -Depth $MaximumDepth -ErrorAction Stop
        if($null -ne $Fields){
            $actual=@($value.PSObject.Properties.Name)
            if($actual.Count -ne $Fields.Count -or @($actual|Where-Object {$_ -cnotin $Fields}).Count -or @($Fields|Where-Object {$_ -notin $actual}).Count){throw 'TLS_AUTHORITY_USE_UNCONFIRMED'}
        }
        return $value
    }catch{if($_.Exception.Message -ceq 'TLS_AUTHORITY_USE_UNCONFIRMED'){throw};throw 'TLS_AUTHORITY_USE_UNCONFIRMED'}finally{$document.Dispose()}
}

function Assert-LabTlsAuthorityJournalStringFields {
    param([object]$Value,[string[]]$Fields)
    foreach($field in $Fields){if(-not $Value.PSObject.Properties[$field] -or $Value.$field -isnot [string]){throw 'TLS_AUTHORITY_USE_UNCONFIRMED'}}
}

function Assert-LabTlsAuthorityRunRetiredAndAbsent {
    param([string]$RunId,[string]$StateRoot,[object]$ExpectedTarget)
    if(-not (Test-LabTlsRequestReference $RunId) -or -not $StateRoot){throw 'TLS_AUTHORITY_USE_UNCONFIRMED'}
    try{
        $root=[IO.Path]::GetFullPath($StateRoot)
        $runPath=Join-Path (Join-Path $root 'runs') ($RunId+'/run-state.json')
        $run=Read-LabDiagnosticJson $runPath 1048576 20
        if($run.contractVersion -isnot [string] -or $run.contractVersion -cne 'SqlServerLab.RunState/1.0' -or
            $run.runId -isnot [string] -or $run.runId -cne $RunId -or $run.scopeId -isnot [string] -or $run.state -isnot [string]){throw 'TLS_AUTHORITY_USE_UNCONFIRMED'}
        if($run.state -cne 'REMOVED'){throw 'TLS_AUTHORITY_IN_USE'}
        $runDirectory=Join-Path (Join-Path $root 'runs') $RunId
        $cleanupPath=Join-Path $runDirectory 'cleanup-plan.json'
        if(-not (Test-Path -LiteralPath $cleanupPath -PathType Leaf)){throw 'TLS_AUTHORITY_USE_UNCONFIRMED'}
        $cleanup=Read-LabDiagnosticJson $cleanupPath 65536 16
        if($cleanup.status -isnot [string] -or $cleanup.runId -isnot [string] -or $cleanup.scopeId -isnot [string] -or
            $cleanup.runId -cne $RunId -or $cleanup.scopeId -cne $run.scopeId){throw 'TLS_AUTHORITY_USE_UNCONFIRMED'}
        if($cleanup.status -cne 'COMPLETED'){throw 'TLS_AUTHORITY_IN_USE'}
        $connectionPath=Join-Path (Join-Path $root 'runs') ($RunId+'/connection-info.json')
        $connection=Read-LabDiagnosticJson $connectionPath 262144 20
        if($connection.runId -isnot [string] -or $connection.runId -cne $run.runId -or
            $connection.scopeId -isnot [string] -or $connection.scopeId -cne $run.scopeId){throw 'TLS_AUTHORITY_USE_UNCONFIRMED'}
        $instances=@($connection.instances)
        $desiredInstances=@($run.metadata.desiredState.Instances)
        if($instances.Count -lt 1 -or $instances.Count -gt 16 -or $desiredInstances.Count -ne $instances.Count){throw 'TLS_AUTHORITY_USE_UNCONFIRMED'}
        if($null -ne $ExpectedTarget){
            foreach($field in @('ScopeId','InstanceId','Provider','RuntimeId')){
                if(-not $ExpectedTarget.PSObject.Properties[$field] -or $ExpectedTarget.$field -isnot [string] -or -not $ExpectedTarget.$field){throw 'TLS_AUTHORITY_USE_UNCONFIRMED'}
            }
            if($ExpectedTarget.ScopeId -cne $run.scopeId){throw 'TLS_AUTHORITY_USE_UNCONFIRMED'}
            $selected=@($instances|Where-Object {$_.id -is [string] -and $_.id -ceq $ExpectedTarget.InstanceId})
            if($selected.Count -ne 1){throw 'TLS_AUTHORITY_USE_UNCONFIRMED'}
            $selectedInstance=$selected[0]
            Assert-LabTlsAuthorityJournalStringFields $selectedInstance @('provider')
            if($selectedInstance.provider -cne $ExpectedTarget.Provider){throw 'TLS_AUTHORITY_USE_UNCONFIRMED'}
            $actualRuntimeId=if($selectedInstance.provider -cin @('docker','podman')){$selectedInstance.containerId}elseif($selectedInstance.provider -ceq 'hyperv'){$selectedInstance.vmId}else{$null}
            if($actualRuntimeId -isnot [string] -or $actualRuntimeId -cne $ExpectedTarget.RuntimeId){throw 'TLS_AUTHORITY_USE_UNCONFIRMED'}
        }
        foreach($instance in $instances){
            Assert-LabTlsAuthorityJournalStringFields $instance @('id','provider')
            $provider=[string]$instance.provider
            $desired=@($desiredInstances|Where-Object {$_.Id -is [string] -and $_.Id -ceq $instance.id -and $_.Provider -is [string] -and $_.Provider -ceq $provider})
            if($desired.Count -ne 1){throw 'TLS_AUTHORITY_USE_UNCONFIRMED'}
            if($provider -cin @('docker','podman')){
                Assert-LabTlsAuthorityJournalStringFields $instance @('containerId','containerName')
                $container=[string]$instance.containerId
                if(-not $container -or $container.Length -gt 256){throw 'TLS_AUTHORITY_USE_UNCONFIRMED'}
                $removed=@($cleanup.steps|Where-Object {$_.resourceType -ceq 'container' -and $_.provider -ceq $provider -and
                    $_.action -ceq 'remove' -and $_.state -ceq 'COMPLETED' -and $_.resourceId -ceq $instance.containerName})
                if($removed.Count -ne 1){throw 'TLS_AUTHORITY_USE_UNCONFIRMED'}
                $names=@($container,[string]$instance.containerName|Select-Object -Unique)
                foreach($targetName in $names){
                    $status=if($provider -ceq 'docker'){Get-DockerInstanceStatus -ContainerIdOrName $targetName -StateRoot $root}else{Get-PodmanInstanceStatus -ContainerIdOrName $targetName -StateRoot $root}
                    if(-not $status.Available){throw 'TLS_AUTHORITY_USE_UNCONFIRMED'}
                    if($status.Exists){throw 'TLS_AUTHORITY_IN_USE'}
                }
            }elseif($provider -ceq 'hyperv'){
                if($null -eq $ExpectedTarget){throw 'TLS_AUTHORITY_USE_UNCONFIRMED'}
                Assert-LabTlsAuthorityJournalStringFields $instance @('vmId')
                $vmId=[guid]::Empty
                if(-not [guid]::TryParse([string]$instance.vmId,[ref]$vmId)){throw 'TLS_AUTHORITY_USE_UNCONFIRMED'}
                try{$vm=@(Get-VM -Id $vmId -ErrorAction Stop)}catch{
                    $knownNotFound=$_.CategoryInfo.Category -eq [Management.Automation.ErrorCategory]::ObjectNotFound -and
                        $_.FullyQualifiedErrorId -ceq 'ObjectNotFound,Microsoft.HyperV.PowerShell.Commands.GetVM'
                    if($knownNotFound){continue}
                    throw 'TLS_AUTHORITY_USE_UNCONFIRMED'
                }
                if($vm.Count){throw 'TLS_AUTHORITY_IN_USE'}
            }else{throw 'TLS_AUTHORITY_USE_UNCONFIRMED'}
        }
        return $true
    }catch{
        if($_.Exception.Message -cmatch '\ATLS_AUTHORITY_(?:IN_USE|USE_UNCONFIRMED)\z'){throw}
        throw 'TLS_AUTHORITY_USE_UNCONFIRMED'
    }
}

function Get-LabTlsAuthorityExpectedWindowsTarget {
    param([object]$RunInfo,[object]$Record,[string]$OperationAuditId,[string]$DataRoot,[string]$ControllerId,[string]$LocationId,[string]$AuthorityRef,[string]$RegistrySha256)
    foreach($field in @('AuditId','RunId','StateRoot','DataRoot','ControllerId','LocationId','AuthorityRef','RegistrySha256','InstanceId','ScopeId','VmId')){
        if(-not $Record.PSObject.Properties[$field] -or $Record.$field -isnot [string] -or -not $Record.$field){throw 'TLS_AUTHORITY_USE_UNCONFIRMED'}
    }
    if($Record.AuditId -cne $OperationAuditId -or $Record.RunId -cne $RunInfo.RunId -or $Record.InstanceId -cne 'primary' -or
        -not [string]::Equals([IO.Path]::GetFullPath($Record.StateRoot),[IO.Path]::GetFullPath($RunInfo.StateRoot),[StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals([IO.Path]::GetFullPath($Record.DataRoot),[IO.Path]::GetFullPath($DataRoot),[StringComparison]::OrdinalIgnoreCase) -or
        $Record.ControllerId -cne $ControllerId -or $Record.LocationId -cne $LocationId -or
        -not (Test-LabTlsRequestReference $Record.ScopeId) -or -not (Test-LabTlsRequestReference $Record.VmId)) {throw 'TLS_AUTHORITY_USE_UNCONFIRMED'}
    if($Record.AuthorityRef -cne $AuthorityRef -and $Record.RegistrySha256 -cne $RegistrySha256){return $null}
    return [pscustomobject]@{ScopeId=$Record.ScopeId;InstanceId=$Record.InstanceId;Provider='hyperv';RuntimeId=$Record.VmId}
}

function Get-LabTlsAuthorityWindowsRunTarget {
    param([object]$RunInfo,[string]$OperationAuditId,[object]$Binding,[object]$WriterState,[string]$AuthorityRef,[string]$DataRoot)
    $recordPath=Get-LabTlsWindowsRecordPath ([string]$RunInfo.StateRoot) ([string]$RunInfo.RunId) primary
    $recordBytes=Read-LabTlsCaPrivateFile $recordPath $Binding.Native.UserSid 32768
    $record=Read-LabTlsWindowsRecord $recordBytes
    return Get-LabTlsAuthorityExpectedWindowsTarget $RunInfo $record $OperationAuditId $DataRoot $Binding.Root.ControllerId $Binding.Root.LocationId $AuthorityRef $WriterState.Digest
}

function Assert-LabTlsAuthorityOrphanAllocationRetiredAndAbsent {
    param([object]$Allocation,[string]$UserSid)
    $allowed=@('catalog','owned-host-volumes','runs','scope-markers','config.json','intent.json','owned-host-policy.json','owned-host-required')
    $entries=@(Get-ChildItem -LiteralPath $Allocation.FullName -Force -ErrorAction Stop)
    if(@($entries|Where-Object {$_.Name -cnotin $allowed -or ($_.Attributes -band [IO.FileAttributes]::ReparsePoint)}).Count){throw 'TLS_AUTHORITY_USE_UNCONFIRMED'}
    $intentPath=Join-Path $Allocation.FullName 'intent.json'
    if(-not (Test-Path -LiteralPath $intentPath -PathType Leaf)){throw 'TLS_AUTHORITY_USE_UNCONFIRMED'}
    $intent=Read-LabTlsAuthorityJournalJson $intentPath $UserSid 8192 4 @('AuditId','Status','Cleanup')
    Assert-LabTlsAuthorityJournalStringFields $intent @('AuditId','Status','Cleanup')
    if($intent.AuditId -cne $Allocation.Name -or $intent.Status -cne 'OWNED_CREATE_PENDING'){throw 'TLS_AUTHORITY_USE_UNCONFIRMED'}
    $runsRoot=Join-Path $Allocation.FullName 'runs'
    if(-not (Test-Path -LiteralPath $runsRoot -PathType Container)){throw 'TLS_AUTHORITY_IN_USE'}
    $runDirectories=@(Get-ChildItem -LiteralPath $runsRoot -Force -ErrorAction Stop)
    if($runDirectories.Count -lt 1 -or @($runDirectories|Where-Object {-not $_.PSIsContainer -or ($_.Attributes -band [IO.FileAttributes]::ReparsePoint)}).Count){throw 'TLS_AUTHORITY_USE_UNCONFIRMED'}
    foreach($runDirectory in $runDirectories){
        if(-not (Test-LabTlsRequestReference $runDirectory.Name)){throw 'TLS_AUTHORITY_USE_UNCONFIRMED'}
        $null=Assert-LabTlsAuthorityRunRetiredAndAbsent $runDirectory.Name $Allocation.FullName
    }
}

function Assert-LabTlsAuthorityRetirementUse {
    param([object]$Binding,[object]$WriterState,[string]$AuthorityRef)
    $dataRoot=[IO.Path]::GetFullPath($Binding.Root.DataRoot).TrimEnd('\')
    $labsRoot=Join-Path $dataRoot 'State/authenticated-tls-labs'
    if(Test-Path -LiteralPath $labsRoot){
        $native=$Binding.Native
        foreach($allocation in Get-ChildItem -LiteralPath $labsRoot -Force -ErrorAction Stop){
            try{
                if(-not $allocation.PSIsContainer -or ($allocation.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'TLS_AUTHORITY_USE_UNCONFIRMED'}
                if(-not (Test-LabTlsRequestReference $allocation.Name)){throw 'TLS_AUTHORITY_USE_UNCONFIRMED'}
                $file=Join-Path $allocation.FullName 'authenticated-tls-lab.json'
                # A directory without a published record may still contain a
                # policy, intent, allocated run, or crash residue. Until its
                # exact run cleanup is proven, it blocks authority retirement.
                if(-not (Test-Path -LiteralPath $file -PathType Leaf)){
                    $null=Assert-LabTlsAuthorityOrphanAllocationRetiredAndAbsent $allocation $native.UserSid
                    continue
                }
                $bytes=Read-LabTlsCaPrivateFile $file $native.UserSid 32768
                $record=Read-LabTlsLabRecord $bytes
                $intentPath=Join-Path $allocation.FullName 'intent.json'
                $targetIntentPath=Join-Path $allocation.FullName 'target-intent.json'
                if(-not (Test-Path -LiteralPath $intentPath -PathType Leaf) -or -not (Test-Path -LiteralPath $targetIntentPath -PathType Leaf)){throw 'TLS_AUTHORITY_USE_UNCONFIRMED'}
                $intent=Read-LabTlsAuthorityJournalJson $intentPath $native.UserSid 8192 4 @('AuditId','Status','Cleanup')
                Assert-LabTlsAuthorityJournalStringFields $intent @('AuditId','Status','Cleanup')
                if($intent.AuditId -cne $allocation.Name -or $intent.Status -cne 'OWNED_CREATE_PENDING'){throw 'TLS_AUTHORITY_USE_UNCONFIRMED'}
                $targetIntent=Read-LabTlsAuthorityJournalJson $targetIntentPath $native.UserSid 32768 8 $null
                Assert-LabTlsAuthorityJournalStringFields $targetIntent @('ContractVersion','AuditId','DataRoot','ControllerId','LocationId','AuthorityRef','ClientRef','RegistrySha256','RunId','InstanceId')
                $sameRoot=[string]::Equals([IO.Path]::GetFullPath($record.DataRoot).TrimEnd('\'),$dataRoot,[StringComparison]::OrdinalIgnoreCase)
                $sameRegistry=[string]::Equals($record.ControllerId,$Binding.Root.ControllerId,[StringComparison]::Ordinal) -and
                    [string]::Equals($record.LocationId,$Binding.Root.LocationId,[StringComparison]::Ordinal)
                if(-not $sameRoot -or -not $sameRegistry){throw 'TLS_AUTHORITY_USE_UNCONFIRMED'}
                if($record.ContractVersion -cnotin @('SqlServerLab.AuthenticatedTlsLab/0.2','SqlServerLab.AuthenticatedTlsLab/0.3','SqlServerLab.AuthenticatedTlsLab/0.4')){throw 'TLS_AUTHORITY_USE_UNCONFIRMED'}
                foreach($field in @('ContractVersion','AuditId','DataRoot','ControllerId','LocationId','AuthorityRef','ClientRef','RegistrySha256','RunId','InstanceId')){
                    if(-not $targetIntent.PSObject.Properties[$field] -or $targetIntent.$field -cne $record.$field){throw 'TLS_AUTHORITY_USE_UNCONFIRMED'}
                }
                if($targetIntent.InstanceId -cne 'primary'){throw 'TLS_AUTHORITY_USE_UNCONFIRMED'}
                $usesTarget=[string]::Equals($record.AuthorityRef,$AuthorityRef,[StringComparison]::Ordinal)
                $usesCurrentDigest=[string]::Equals($record.RegistrySha256,$WriterState.Digest,[StringComparison]::Ordinal)
                if(-not $usesTarget -and -not $usesCurrentDigest){continue}
                if(-not (Test-LabTlsRequestReference $record.AuditId) -or -not (Test-LabTlsRequestReference $record.RunId)){throw 'TLS_AUTHORITY_USE_UNCONFIRMED'}
                $expectedRoot=[IO.Path]::GetFullPath((Join-Path $labsRoot $record.AuditId))
                if(-not [string]::Equals([IO.Path]::GetFullPath($allocation.FullName),$expectedRoot,[StringComparison]::OrdinalIgnoreCase)){throw 'TLS_AUTHORITY_USE_UNCONFIRMED'}
        $runtimeId=if($record.Provider -cin @('docker','podman')){$record.ContainerId}elseif($record.Provider -ceq 'hyperv'){$record.VmId}else{$null}
        if($runtimeId -isnot [string] -or -not $runtimeId){throw 'TLS_AUTHORITY_USE_UNCONFIRMED'}
        $expectedTarget=[pscustomobject]@{ScopeId=[string]$record.ScopeId;InstanceId=[string]$record.InstanceId;Provider=[string]$record.Provider;RuntimeId=$runtimeId}
        $null=Assert-LabTlsAuthorityRunRetiredAndAbsent $record.RunId $expectedRoot $expectedTarget
            }catch{
                if($_.Exception.Message -cmatch '\ATLS_AUTHORITY_(?:IN_USE|USE_UNCONFIRMED)\z'){throw}
                throw 'TLS_AUTHORITY_USE_UNCONFIRMED'
            }
        }
    }
    $null=Assert-LabDiagnosticPath $labsRoot
    $operationsRoot=Join-Path $dataRoot 'State/authenticated-tls-windows-operations'
    if(Test-Path -LiteralPath $operationsRoot){
        $null=Assert-LabDiagnosticPath $operationsRoot
        foreach($directory in Get-ChildItem -LiteralPath $operationsRoot -Force -ErrorAction Stop){
            try{
                if(-not $directory.PSIsContainer -or ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'TLS_AUTHORITY_USE_UNCONFIRMED'}
                if($directory.Name -notmatch '\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z' -or
                    ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'TLS_AUTHORITY_USE_UNCONFIRMED'}
                $operationEntries=@(Get-ChildItem -LiteralPath $directory.FullName -Force -ErrorAction Stop)
                if(@($operationEntries|Where-Object {$_.PSIsContainer -or $_.Name -cnotin @('intent.json','create-manifest.json','run.json','ready.json','failure.json')}).Count){throw 'TLS_AUTHORITY_USE_UNCONFIRMED'}
                $intentPath=Join-Path $directory.FullName 'intent.json'
                if(-not (Test-Path -LiteralPath $intentPath -PathType Leaf)){throw 'TLS_AUTHORITY_USE_UNCONFIRMED'}
                $intent=Read-LabTlsAuthorityJournalJson $intentPath $Binding.Native.UserSid 8192 4 @('ContractVersion','AuditId','Status')
                Assert-LabTlsAuthorityJournalStringFields $intent @('ContractVersion','AuditId','Status')
                if($intent.ContractVersion -cne 'SqlServerLab.WindowsTlsCreateIntent/0.1' -or $intent.AuditId -cne $directory.Name -or $intent.Status -cne 'NEW_OWN_RUN_PENDING'){throw 'TLS_AUTHORITY_USE_UNCONFIRMED'}
                $failurePath=Join-Path $directory.FullName 'failure.json'
                $readyPath=Join-Path $directory.FullName 'ready.json'
                $runPath=Join-Path $directory.FullName 'run.json'
                if(Test-Path -LiteralPath $readyPath -PathType Leaf){
                    if(Test-Path -LiteralPath $failurePath -PathType Leaf){throw 'TLS_AUTHORITY_USE_UNCONFIRMED'}
                    $ready=Read-LabTlsAuthorityJournalJson $readyPath $Binding.Native.UserSid 8192 4 @('Status','RunId','ClientChecks','ConsumerEnded')
                    Assert-LabTlsAuthorityJournalStringFields $ready @('Status','RunId')
                    if(($ready.ClientChecks -isnot [int] -and $ready.ClientChecks -isnot [long]) -or $ready.ConsumerEnded -isnot [bool] -or
                        $ready.Status -cne 'READY' -or $ready.ClientChecks -ne 2 -or -not $ready.ConsumerEnded -or
                        -not (Test-LabTlsRequestReference ([string]$ready.RunId))){throw 'TLS_AUTHORITY_USE_UNCONFIRMED'}
                    if(-not (Test-Path -LiteralPath $runPath -PathType Leaf)){throw 'TLS_AUTHORITY_USE_UNCONFIRMED'}
                    $runInfo=Read-LabTlsAuthorityJournalJson $runPath $Binding.Native.UserSid 8192 4 @('AuditId','RunId','StateRoot')
                    Assert-LabTlsAuthorityJournalStringFields $runInfo @('AuditId','RunId','StateRoot')
                    if($runInfo.AuditId -cne $directory.Name -or $runInfo.RunId -cne $ready.RunId){throw 'TLS_AUTHORITY_USE_UNCONFIRMED'}
                    $expectedTarget=Get-LabTlsAuthorityWindowsRunTarget $runInfo $directory.Name $Binding $WriterState $AuthorityRef $dataRoot
                    if($null -eq $expectedTarget){continue}
                    $null=Assert-LabTlsAuthorityRunRetiredAndAbsent ([string]$runInfo.RunId) ([string]$runInfo.StateRoot) $expectedTarget
                    continue
                }
                if(Test-Path -LiteralPath $failurePath -PathType Leaf){
                    $failure=Read-LabTlsAuthorityJournalJson $failurePath $Binding.Native.UserSid 8192 4 @('Status','Phase','FailureCode','ConsumerEnded','Cleanup')
                    Assert-LabTlsAuthorityJournalStringFields $failure @('Status','Phase','FailureCode','Cleanup')
                    if($failure.ConsumerEnded -isnot [bool] -or $failure.Status -cne 'FAILED' -or -not $failure.ConsumerEnded -or $failure.Cleanup -cne 'OWN_RUN_ONLY'){throw 'TLS_AUTHORITY_IN_USE'}
                    if(-not (Test-Path -LiteralPath $runPath -PathType Leaf)){throw 'TLS_AUTHORITY_USE_UNCONFIRMED'}
                    $runInfo=Read-LabTlsAuthorityJournalJson $runPath $Binding.Native.UserSid 8192 4 @('AuditId','RunId','StateRoot')
                    Assert-LabTlsAuthorityJournalStringFields $runInfo @('AuditId','RunId','StateRoot')
                    if($runInfo.AuditId -cne $directory.Name){throw 'TLS_AUTHORITY_USE_UNCONFIRMED'}
                    $expectedTarget=Get-LabTlsAuthorityWindowsRunTarget $runInfo $directory.Name $Binding $WriterState $AuthorityRef $dataRoot
                    if($null -eq $expectedTarget){continue}
                    $null=Assert-LabTlsAuthorityRunRetiredAndAbsent ([string]$runInfo.RunId) ([string]$runInfo.StateRoot) $expectedTarget
                    continue
                }
                throw 'TLS_AUTHORITY_IN_USE'
            }catch{
                if($_.Exception.Message -cmatch '\ATLS_AUTHORITY_(?:IN_USE|USE_UNCONFIRMED)\z'){throw}
                throw 'TLS_AUTHORITY_USE_UNCONFIRMED'
            }
        }
    }
}

function Retire-LabTlsOperationalAuthority {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$DataRoot,
        [Parameter(Mandatory)][string]$ControllerId,
        [Parameter(Mandatory)][string]$LocationId,
        [Parameter(Mandatory)][string]$AuthorityRef,
        [Parameter(Mandatory)][string]$ExpectedCandidateId,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$ExpectedRegistrySha256
    )
    if(-not (Test-LabTlsCaCandidateInput $DataRoot $ControllerId $LocationId CURRENT_WINDOWS_PROCESS) -or
        -not (Test-LabTlsRequestReference $AuthorityRef) -or -not (Test-LabTlsRequestReference $ExpectedCandidateId)){
        throw 'TLS_AUTHORITY_RETIREMENT_INPUT_INVALID'
    }
    $binding=Get-LabTlsRegistryWriterBinding $DataRoot $ControllerId $LocationId
    $lifecycleLock=Enter-LabTlsRegistryLifecycleLock $binding;$registryLock=$null
    try{
        $registryLock=Enter-LabTlsRegistryWriterLock $binding
        $state=Read-LabTlsRegistryWriterState $binding
        if($state.Status -cne 'COMMITTED' -or $state.Pending.Count -ne 0){throw 'TLS_AUTHORITY_REGISTRY_UNCONFIRMED'}
        if($state.Digest -cne $ExpectedRegistrySha256){throw 'TLS_AUTHORITY_EXPECTED_REGISTRY_CHANGED'}
        $parsed=Read-LabAuthenticatedTlsRegistryDocument $state.Bytes
        if(-not $parsed.Success){throw 'TLS_AUTHORITY_REGISTRY_INVALID'}
        $document=$parsed.Value.RegistryDocument
        $targets=@($document.Payloads|Where-Object {$_.Kind -ceq 'AUTHORITY' -and $_.Ref -ceq $AuthorityRef -and $_.ContractVersion -ceq 'SqlServerLab.AuthenticatedTlsRegistryPayload/0.2'})
        if($targets.Count -ne 1 -or $targets[0].Status -cne 'ACTIVE' -or $targets[0].CandidateId -cne $ExpectedCandidateId){throw 'TLS_AUTHORITY_RETIREMENT_TARGET_INVALID'}
        if(-not $PSCmdlet.ShouldProcess($AuthorityRef,"Retire only this TLS authority at registry $ExpectedRegistrySha256")){
            return [pscustomobject]@{Success=$true;Value=[pscustomobject]@{Status='CANCELLED';AuthorityRef=$AuthorityRef;RegistrySha256=$state.Digest;MutationAllowed=$false};ErrorCode=$null}
        }
        Exit-LabTlsRegistryWriterLock $registryLock;$registryLock=$null
        $payloads=[Collections.Generic.List[object]]::new()
        foreach($payload in $document.Payloads){
            if([string]::Equals($payload.Ref,$AuthorityRef,[StringComparison]::Ordinal)){$payload.Status='RETIRED'}
            $payloads.Add($payload)
        }
        $revision=[long]$document.Index.Revision
        if($revision -ge [int]::MaxValue){throw 'TLS_AUTHORITY_REGISTRY_REVISION_OVERFLOW'}
        $next=[pscustomobject]@{
            ContractVersion=$document.ContractVersion
            Index=[pscustomobject]@{ContractVersion=$document.Index.ContractVersion;ControllerId=$ControllerId;LocationId=$LocationId;
                Revision=[int]($revision+1);Records=@($payloads|ForEach-Object {Get-LabTlsPayloadIndexRecord $_})}
            Payloads=@($payloads.ToArray())
        }
        $candidateBytes=ConvertTo-LabTlsRegistryWriterBytes $next
        if(-not (Test-LabAuthenticatedTlsRegistryDocumentTransition $state.Bytes $candidateBytes).Success){throw 'TLS_AUTHORITY_RETIREMENT_TRANSITION_INVALID'}
        $written=Invoke-LabAuthenticatedTlsRegistryWrite $DataRoot $ControllerId $LocationId CURRENT_WINDOWS_PROCESS RETIRE_AUTHORITY `
            $binding.Root.RootMetadataDigest $binding.ActorDigest $state.Digest $candidateBytes $null $AuthorityRef $ExpectedCandidateId
        if(-not $written.Success){throw 'TLS_AUTHORITY_RETIREMENT_UNCONFIRMED'}
        $final=Read-LabTlsRegistryWriterState $binding
        if($final.Status -cne 'COMMITTED' -or $final.Pending.Count -ne 0){throw 'TLS_AUTHORITY_RETIREMENT_UNCONFIRMED'}
        $after=Read-LabAuthenticatedTlsRegistryDocument $final.Bytes
        if(-not $after.Success){throw 'TLS_AUTHORITY_RETIREMENT_UNCONFIRMED'}
        $retired=@($after.Value.RegistryDocument.Payloads|Where-Object {$_.Kind -ceq 'AUTHORITY' -and $_.Ref -ceq $AuthorityRef -and $_.CandidateId -ceq $ExpectedCandidateId})
        if($retired.Count -ne 1 -or $retired[0].Status -cne 'RETIRED'){throw 'TLS_AUTHORITY_RETIREMENT_UNCONFIRMED'}
        return [pscustomobject]@{Success=$true;Value=[pscustomobject]@{Status='TOMBSTONE_COMMITTED';AuthorityRef=$AuthorityRef;CandidateId=$ExpectedCandidateId;
            RegistrySha256=$final.Digest;Revision=$after.Value.RegistryDocument.Index.Revision;RemovalStatus='NONE';QualificationStatus='NOT_EXECUTED';Ready=$false;MutationAllowed=$false};ErrorCode=$null}
    }catch{
        throw
    }finally{
        Exit-LabTlsRegistryWriterLock $registryLock
        Exit-LabTlsRegistryLifecycleLock $lifecycleLock
    }
}
