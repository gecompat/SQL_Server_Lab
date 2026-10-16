#Requires -Version 7.2
# Private Windows-Transaktion: ausschliesslich oeffentliche DER-Bytes, kein Removal.

function Test-LabTlsTrustImportInput {
    param([object]$DataRoot,[object]$ControllerId,[object]$LocationId,[object]$Context,[object]$CandidateId)
    return ((Test-LabTlsCaCandidateInput $DataRoot $ControllerId $LocationId $Context) -and (Test-LabTlsRequestReference $CandidateId))
}

function Test-LabTlsTrustApproval {
    param([object]$Approval)
    $fields=Get-LabTlsRequestFields $Approval @('ContractVersion','ApprovalId','PreviewId','PreviewDigest','Decision')
    if($null -eq $fields -or $fields.Count -ne 5 -or
        -not (Test-LabTlsRequestEnum $fields.ContractVersion @('SqlServerLab.TlsTrustApproval/0.1')) -or
        -not (Test-LabTlsRequestReference $fields.ApprovalId) -or -not (Test-LabTlsRequestReference $fields.PreviewId) -or
        $fields.PreviewDigest -isnot [string] -or $fields.PreviewDigest -cnotmatch '\A[0-9a-f]{64}\z' -or
        -not (Test-LabTlsRequestEnum $fields.Decision @('APPROVE_CURRENT_USER_ROOT_PUBLIC_DER'))){return $null}
    return [pscustomobject]@{ContractVersion='SqlServerLab.TlsTrustApproval/0.1';ApprovalId=[guid]::Parse($fields.ApprovalId).ToString('D')
        PreviewId=[guid]::Parse($fields.PreviewId).ToString('D');PreviewDigest=[string]::Concat($fields.PreviewDigest);Decision='APPROVE_CURRENT_USER_ROOT_PUBLIC_DER'}
}

function Get-LabTlsTrustCoreDigest {
    param([object]$Record)
    return Get-LabTlsPayloadDigest @('SqlServerLab.TlsTrustImportBinding/0.1',$Record.ControllerId,$Record.LocationId,$Record.CandidateId,
        $Record.Store,$Record.RootMetadataDigest,$Record.ActorDigest,$Record.CertificateSha256,$Record.ReceiptSha256,$Record.IntentSha256,$Record.CiphertextSha256)
}

function Get-LabTlsTrustImportBinding {
    param([string]$DataRoot,[string]$ControllerId,[string]$LocationId,[string]$CandidateId)
    $preview=Get-LabAuthenticatedTlsCaTrustPreview $DataRoot $ControllerId $LocationId 'CURRENT_WINDOWS_PROCESS' $CandidateId
    if(-not $preview.Success){throw 'TLS_TRUST_BINDING_INVALID'}
    $native=Get-LabTlsWindowsProcessFacts;$actor=Get-LabTlsCaActorDigest $native
    if(-not [string]::Equals($actor,(Get-LabTlsCaActorDigest $preview.Value),[StringComparison]::Ordinal)){throw 'TLS_TRUST_BINDING_INVALID'}
    $root=Get-LabAuthenticatedTlsRootMetadata $DataRoot $ControllerId $LocationId
    if(-not $root.Success){throw 'TLS_TRUST_BINDING_INVALID'}
    $paths=Get-LabTlsCaCandidatePaths $native $ControllerId $LocationId $CandidateId
    $der=Read-LabTlsCaPrivateFile (Join-Path $paths.Candidate 'ca.der') $native.UserSid 16384
    $certificate=Assert-LabTlsCaCertificate $der $CandidateId
    if(-not [string]::Equals($certificate.Sha256,$preview.Value.CertificateSha256,[StringComparison]::Ordinal)){throw 'TLS_TRUST_BINDING_INVALID'}
    $core=[pscustomobject][ordered]@{ControllerId=$ControllerId;LocationId=$LocationId;CandidateId=$CandidateId;Store='CURRENT_USER_ROOT'
        RootMetadataDigest=$root.Value.RootMetadataDigest;ActorDigest=$actor;CertificateSha256=$certificate.Sha256
        ReceiptSha256=(Get-LabTlsCaByteDigest (Read-LabTlsCaPrivateFile (Join-Path $paths.Candidate 'receipt.json') $native.UserSid 8192))
        IntentSha256=(Get-LabTlsCaByteDigest (Read-LabTlsCaPrivateFile (Join-Path $paths.Candidate 'intent.json') $native.UserSid 2048))
        CiphertextSha256=(Get-LabTlsCaByteDigest (Read-LabTlsCaPrivateFile (Join-Path $paths.Candidate 'key.dpapi') $native.UserSid 16384))}
    $again=Get-LabAuthenticatedTlsRootMetadata $DataRoot $ControllerId $LocationId
    $prestate=Get-LabTlsCaExistingTrust $der
    if(-not $again.Success -or -not [string]::Equals($core.RootMetadataDigest,$again.Value.RootMetadataDigest,[StringComparison]::Ordinal) -or
        -not [string]::Equals($prestate,$preview.Value.PreexistingTrust,[StringComparison]::Ordinal) -or
        -not (Test-LabTlsRequestEnum $prestate @('ABSENT','IDENTICAL_PREEXISTING_NOT_OWNED'))){throw 'TLS_TRUST_BINDING_INVALID'}
    return [pscustomobject]@{Core=$core;Digest=(Get-LabTlsTrustCoreDigest $core);Native=$native;Paths=$paths;Der=$der;Prestate=$prestate;Preview=$preview.Value}
}

function Get-LabTlsTrustJournalPath {
    param([object]$Binding)
    $base=Join-Path $Binding.Paths.Location 'trust-imports'
    $journal=Join-Path $base $Binding.Core.CandidateId
    return [pscustomobject]@{Base=$base;Journal=$journal;Previews=(Join-Path $journal 'previews');Lock=(Join-Path $base ($Binding.Core.CandidateId+'.lock'))
        Owner=(Join-Path $journal 'owner.json');Intent=(Join-Path $journal 'intent.json');Commit=(Join-Path $journal 'commit.json')}
}

function Enter-LabTlsTrustJournalLock {
    param([string]$Path,[string]$UserSid)
    $null=Assert-LabDiagnosticPath $Path
    # Ein einziger nicht wartender Versuch; kein fremdes/stales Lock entfernen.
    $stream=$null
    try{
        $stream=[IO.FileSystemAclExtensions]::Create([IO.FileInfo]::new($Path),[IO.FileMode]::CreateNew,
            [Security.AccessControl.FileSystemRights]::FullControl,[IO.FileShare]::None,4096,[IO.FileOptions]::DeleteOnClose,(Get-LabTlsCaSecurity $UserSid))
        $acl=[IO.FileSystemAclExtensions]::GetAccessControl($stream);$rules=$acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])
        if(-not $acl.AreAccessRulesProtected -or -not [string]::Equals($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value,$UserSid,[StringComparison]::Ordinal) -or $rules.Count -ne 2){throw 'TLS_TRUST_LOCK_INVALID'}
        $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach($rule in $rules){if($rule.IsInherited -or $rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow -or
            $rule.FileSystemRights -ne [Security.AccessControl.FileSystemRights]::FullControl -or $rule.InheritanceFlags -ne [Security.AccessControl.InheritanceFlags]::None -or
            $rule.PropagationFlags -ne [Security.AccessControl.PropagationFlags]::None -or -not (Test-LabTlsRequestEnum $rule.IdentityReference.Value @($UserSid,'S-1-5-18')) -or
            -not $seen.Add($rule.IdentityReference.Value)){throw 'TLS_TRUST_LOCK_INVALID'}}
        return $stream
    }catch{if($null -ne $stream){$stream.Dispose()};throw 'TLS_TRUST_JOURNAL_BUSY'}
}

function Write-LabTlsTrustJournalRecord {
    param([string]$Path,[string]$UserSid,[object]$Record)
    $bytes=[Text.Encoding]::UTF8.GetBytes(($Record|ConvertTo-Json -Depth 4 -Compress))
    Write-LabTlsCaPrivateFile $Path $UserSid $bytes
    $again=Read-LabTlsCaPrivateFile $Path $UserSid 8192
    if(-not [string]::Equals((Get-LabTlsCaByteDigest $bytes),(Get-LabTlsCaByteDigest $again),[StringComparison]::Ordinal)){throw 'TLS_TRUST_JOURNAL_INVALID'}
    return Get-LabTlsCaByteDigest $again
}

function Read-LabTlsTrustJournalRecord {
    param([string]$Path,[string]$UserSid,[string[]]$Names)
    $bytes=Read-LabTlsCaPrivateFile $Path $UserSid 8192
    return [pscustomobject]@{Record=(Read-LabTlsCaMetadata $bytes $Names);ByteDigest=(Get-LabTlsCaByteDigest $bytes)}
}

function Assert-LabTlsTrustJournalOwner {
    param([object]$Binding,[object]$Paths)
    foreach($path in @($Paths.Base,$Paths.Journal,$Paths.Previews)){Assert-LabTlsCaPrivateAcl $path $Binding.Native.UserSid -Directory}
    $owner=(Read-LabTlsTrustJournalRecord $Paths.Owner $Binding.Native.UserSid @('ContractVersion','CandidateId','ControllerId','LocationId','RootMetadataDigest','ActorDigest')).Record
    if(-not (Test-LabTlsRequestEnum $owner.ContractVersion @('SqlServerLab.TlsTrustJournal/0.1'))){throw 'TLS_TRUST_JOURNAL_INVALID'}
    foreach($name in @('CandidateId','ControllerId','LocationId','RootMetadataDigest','ActorDigest')){
        if(-not [string]::Equals($owner.$name,$Binding.Core.$name,[StringComparison]::Ordinal)){throw 'TLS_TRUST_JOURNAL_INVALID'}
    }
}

function Initialize-LabTlsTrustJournal {
    param([object]$Binding,[object]$Paths)
    if(-not (Test-Path -LiteralPath $Paths.Journal)){
        Initialize-LabTlsCaPrivateDirectory $Paths.Journal $Binding.Native.UserSid -NewOnly
        Initialize-LabTlsCaPrivateDirectory $Paths.Previews $Binding.Native.UserSid -NewOnly
        $owner=[pscustomobject][ordered]@{ContractVersion='SqlServerLab.TlsTrustJournal/0.1';CandidateId=$Binding.Core.CandidateId;ControllerId=$Binding.Core.ControllerId
            LocationId=$Binding.Core.LocationId;RootMetadataDigest=$Binding.Core.RootMetadataDigest;ActorDigest=$Binding.Core.ActorDigest}
        $null=Write-LabTlsTrustJournalRecord $Paths.Owner $Binding.Native.UserSid $owner
    }
    Assert-LabTlsTrustJournalOwner $Binding $Paths
}

function Get-LabTlsTrustPreviewDigest {
    param([object]$Record)
    return Get-LabTlsPayloadDigest @('SqlServerLab.TlsTrustImportPreviewDigest/0.1',$Record.PreviewId,$Record.BindingDigest,$Record.Prestate,$Record.IssuedUtcTicks,$Record.ExpiresUtcTicks)
}

function Read-LabTlsTrustImportPreviewRecord {
    param([object]$Binding,[object]$Paths,[string]$PreviewId,[switch]$RequireFresh)
    $names=@('ContractVersion','PreviewId','BindingDigest','Prestate','IssuedUtcTicks','ExpiresUtcTicks')
    $record=(Read-LabTlsTrustJournalRecord (Join-Path $Paths.Previews ($PreviewId+'.json')) $Binding.Native.UserSid $names).Record
    $issued=0L;$expires=0L
    if(-not (Test-LabTlsRequestEnum $record.ContractVersion @('SqlServerLab.TlsTrustImportPreview/0.1')) -or
        -not (Test-LabTlsRequestEnum $record.PreviewId @($PreviewId)) -or $record.BindingDigest -cnotmatch '\A[0-9a-f]{64}\z' -or
        -not (Test-LabTlsRequestEnum $record.Prestate @('ABSENT','IDENTICAL_PREEXISTING_NOT_OWNED')) -or
        $record.IssuedUtcTicks -cnotmatch '\A[0-9]{18,19}\z' -or $record.ExpiresUtcTicks -cnotmatch '\A[0-9]{18,19}\z' -or
        -not [long]::TryParse($record.IssuedUtcTicks,[Globalization.NumberStyles]::None,[Globalization.CultureInfo]::InvariantCulture,[ref]$issued) -or
        -not [long]::TryParse($record.ExpiresUtcTicks,[Globalization.NumberStyles]::None,[Globalization.CultureInfo]::InvariantCulture,[ref]$expires) -or
        $issued -lt [datetime]::MinValue.Ticks -or $expires -gt [datetime]::MaxValue.Ticks -or $expires-$issued -ne [timespan]::FromMinutes(5).Ticks){throw 'TLS_TRUST_APPROVAL_INVALID'}
    if($RequireFresh -and ($issued -gt [datetime]::UtcNow.Ticks -or $expires -le [datetime]::UtcNow.Ticks)){throw 'TLS_TRUST_APPROVAL_INVALID'}
    return $record
}

function New-LabAuthenticatedTlsTrustImportPreview {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Private preparation writes only protected approval metadata; no store mutation.')]
    [CmdletBinding()]
    param([object]$DataRoot,[object]$ControllerId,[object]$LocationId,[object]$Context,[object]$CandidateId)
    $bad=[pscustomobject]@{Success=$false;Value=$null;ErrorCode='TLS_TRUST_PREVIEW_INVALID'}
    if(-not (Test-LabTlsTrustImportInput $DataRoot $ControllerId $LocationId $Context $CandidateId)){return $bad}
    $ControllerId=[guid]::Parse($ControllerId).ToString('D');$LocationId=[guid]::Parse($LocationId).ToString('D');$CandidateId=[guid]::Parse($CandidateId).ToString('D')
    $lock=$null
    try{
        $binding=Get-LabTlsTrustImportBinding $DataRoot $ControllerId $LocationId $CandidateId;$paths=Get-LabTlsTrustJournalPath $binding
        Initialize-LabTlsCaPrivateDirectory $paths.Base $binding.Native.UserSid
        $lock=Enter-LabTlsTrustJournalLock $paths.Lock $binding.Native.UserSid
        Initialize-LabTlsTrustJournal $binding $paths
        if((Test-Path -LiteralPath $paths.Intent) -or (Test-Path -LiteralPath $paths.Commit)){throw 'TLS_TRUST_RECOVERY_REQUIRED'}
        $issued=[datetime]::UtcNow;$id=[guid]::NewGuid().ToString('D')
        $record=[pscustomobject][ordered]@{ContractVersion='SqlServerLab.TlsTrustImportPreview/0.1';PreviewId=$id;BindingDigest=$binding.Digest;Prestate=$binding.Prestate
            IssuedUtcTicks=$issued.Ticks.ToString([Globalization.CultureInfo]::InvariantCulture);ExpiresUtcTicks=$issued.AddMinutes(5).Ticks.ToString([Globalization.CultureInfo]::InvariantCulture)}
        $null=Write-LabTlsTrustJournalRecord (Join-Path $paths.Previews ($id+'.json')) $binding.Native.UserSid $record
        $checked=Read-LabTlsTrustImportPreviewRecord $binding $paths $id -RequireFresh
        return [pscustomobject]@{Success=$true;Value=[pscustomobject][ordered]@{PreviewId=$id;PreviewDigest=(Get-LabTlsTrustPreviewDigest $checked);ExpiresUtc=$issued.AddMinutes(5).ToString('O')
            CandidateId=$CandidateId;CertificateSha256=$binding.Core.CertificateSha256;NotBeforeUtc=$binding.Preview.NotBeforeUtc;NotAfterUtc=$binding.Preview.NotAfterUtc
            UserSid=$binding.Native.UserSid;HostMarker=$binding.Native.HostMarker;ProfilePath=$binding.Native.ProfilePath;Store='CURRENT_USER_ROOT';Prestate=$binding.Prestate
            ApprovalEffect='Trust may affect other applications of this Windows user.';Status='AWAITING_EXPLICIT_APPROVAL';RegistrationStatus='NOT_EXECUTED';TlsStatus='NOT_EXECUTED';Ready=$false;MutationAllowed=$false};ErrorCode=$null}
    }catch{if(Test-LabTlsRequestEnum $_.Exception.Message @('TLS_TRUST_JOURNAL_BUSY','TLS_TRUST_RECOVERY_REQUIRED')){$bad.ErrorCode=$_.Exception.Message};return $bad}
    finally{if($null -ne $lock){$lock.Dispose()}}
}

function Add-LabTlsCurrentUserRootPublicCertificate {
    param([byte[]]$Der,[string]$CandidateId,[string]$ActorDigest,[long]$ExpiresUtcTicks)
    $null=Assert-LabTlsCaCertificate $Der $CandidateId
    if(-not [string]::Equals((Get-LabTlsCaActorDigest (Get-LabTlsWindowsProcessFacts)),$ActorDigest,[StringComparison]::Ordinal)){throw 'TLS_TRUST_BINDING_INVALID'}
    if([datetime]::UtcNow.Ticks -ge $ExpiresUtcTicks){throw 'TLS_TRUST_APPROVAL_INVALID'}
    $store=$null;$certificate=$null
    try{
        $certificate=[Security.Cryptography.X509Certificates.X509Certificate2]::new($Der)
        if($certificate.HasPrivateKey){throw 'TLS_TRUST_PUBLIC_ONLY_REQUIRED'}
        $store=[Security.Cryptography.X509Certificates.X509Store]::new([Security.Cryptography.X509Certificates.StoreName]::Root,[Security.Cryptography.X509Certificates.StoreLocation]::CurrentUser)
        $store.Open([Security.Cryptography.X509Certificates.OpenFlags]'ReadWrite, OpenExistingOnly')
        $existing=$store.Certificates
        try{
            if($existing.Count -gt 8192){throw 'TLS_TRUST_STORE_LIMIT'}
            foreach($item in $existing){if([string]::Equals([Convert]::ToBase64String($item.RawData),[Convert]::ToBase64String($Der),[StringComparison]::Ordinal)){return 'PREEXISTING_AT_WRITE_BOUNDARY'}}
        }finally{foreach($item in $existing){$item.Dispose()}}
        if([datetime]::UtcNow.Ticks -ge $ExpiresUtcTicks -or [datetime]::UtcNow -ge $certificate.NotAfter.ToUniversalTime()){throw 'TLS_TRUST_APPROVAL_INVALID'}
        $store.Add($certificate)
        return 'ADD_RETURNED'
    }finally{if($null -ne $certificate){$certificate.Dispose()};if($null -ne $store){$store.Dispose()}}
}

function Get-LabTlsTrustJournalState {
    param([object]$Binding,[object]$Paths)
    Assert-LabTlsTrustJournalOwner $Binding $Paths
    $hasIntent=Test-Path -LiteralPath $Paths.Intent;$hasCommit=Test-Path -LiteralPath $Paths.Commit
    if(-not $hasIntent){if($hasCommit){throw 'TLS_TRUST_RECOVERY_REQUIRED'};return [pscustomobject]@{Status='AWAITING_APPROVAL';ApprovalId=$null;PreviewId=$null;PreviewDigest=$null}}
    $intentRead=Read-LabTlsTrustJournalRecord $Paths.Intent $Binding.Native.UserSid @('ContractVersion','ApprovalId','PreviewId','PreviewDigest','BindingDigest','CertificateSha256','Store','Prestate')
    $intent=$intentRead.Record
    if(-not (Test-LabTlsRequestEnum $intent.ContractVersion @('SqlServerLab.TlsTrustImportIntent/0.1')) -or
        -not (Test-LabTlsRequestReference $intent.ApprovalId) -or -not (Test-LabTlsRequestReference $intent.PreviewId) -or
        -not (Test-LabTlsRequestEnum $intent.BindingDigest @($Binding.Digest)) -or -not (Test-LabTlsRequestEnum $intent.CertificateSha256 @($Binding.Core.CertificateSha256)) -or
        -not (Test-LabTlsRequestEnum $intent.Store @('CURRENT_USER_ROOT')) -or -not (Test-LabTlsRequestEnum $intent.Prestate @('ABSENT'))){throw 'TLS_TRUST_RECOVERY_REQUIRED'}
    $preview=Read-LabTlsTrustImportPreviewRecord $Binding $Paths $intent.PreviewId
    if(-not (Test-LabTlsRequestEnum $intent.PreviewDigest @((Get-LabTlsTrustPreviewDigest $preview))) -or
        -not (Test-LabTlsRequestEnum $preview.BindingDigest @($Binding.Digest)) -or -not (Test-LabTlsRequestEnum $preview.Prestate @('ABSENT'))){throw 'TLS_TRUST_RECOVERY_REQUIRED'}
    if(-not $hasCommit){return [pscustomobject]@{Status='RECOVERY_REQUIRED';ApprovalId=$intent.ApprovalId;PreviewId=$intent.PreviewId;PreviewDigest=$intent.PreviewDigest}}
    $commit=(Read-LabTlsTrustJournalRecord $Paths.Commit $Binding.Native.UserSid @('ContractVersion','ApprovalId','PreviewDigest','IntentByteSha256','CertificateSha256','Outcome','Store')).Record
    if(-not (Test-LabTlsRequestEnum $commit.ContractVersion @('SqlServerLab.TlsTrustImportCommit/0.1')) -or
        -not (Test-LabTlsRequestEnum $commit.ApprovalId @($intent.ApprovalId)) -or -not (Test-LabTlsRequestEnum $commit.PreviewDigest @($intent.PreviewDigest)) -or
        -not (Test-LabTlsRequestEnum $commit.IntentByteSha256 @($intentRead.ByteDigest)) -or -not (Test-LabTlsRequestEnum $commit.CertificateSha256 @($Binding.Core.CertificateSha256)) -or
        -not (Test-LabTlsRequestEnum $commit.Store @('CURRENT_USER_ROOT')) -or -not (Test-LabTlsRequestEnum $commit.Outcome @('OWNED_IMPORT_RECORDED','PREEXISTING_NOT_OWNED')) -or
        -not (Test-LabTlsRequestEnum $Binding.Prestate @('IDENTICAL_PREEXISTING_NOT_OWNED'))){throw 'TLS_TRUST_RECOVERY_REQUIRED'}
    return [pscustomobject]@{Status=$commit.Outcome;ApprovalId=$intent.ApprovalId;PreviewId=$intent.PreviewId;PreviewDigest=$intent.PreviewDigest}
}

function Get-LabTlsTrustImportResult {
    param([string]$Status)
    return [pscustomobject]@{Success=$true;Value=[pscustomobject][ordered]@{Status=$Status;Store='CURRENT_USER_ROOT';RemovalAuthority='NONE'
        StoreAtomicity='COOPERATIVE_ONLY';RegistrationStatus='NOT_EXECUTED';TlsStatus='NOT_EXECUTED';Ready=$false;MutationAllowed=$false};ErrorCode=$null}
}

function Invoke-LabAuthenticatedTlsTrustImport {
    [CmdletBinding()]
    param([object]$DataRoot,[object]$ControllerId,[object]$LocationId,[object]$Context,[object]$CandidateId,[object]$Approval)
    $bad=[pscustomobject]@{Success=$false;Value=$null;ErrorCode='TLS_TRUST_APPROVAL_INVALID'}
    if(-not (Test-LabTlsTrustImportInput $DataRoot $ControllerId $LocationId $Context $CandidateId)){return $bad}
    $ControllerId=[guid]::Parse($ControllerId).ToString('D');$LocationId=[guid]::Parse($LocationId).ToString('D');$CandidateId=[guid]::Parse($CandidateId).ToString('D')
    $checked=Test-LabTlsTrustApproval $Approval;if($null -eq $checked){return $bad}
    $lock=$null;$intentStarted=$false
    try{
        $binding=Get-LabTlsTrustImportBinding $DataRoot $ControllerId $LocationId $CandidateId;$paths=Get-LabTlsTrustJournalPath $binding
        if(-not (Test-Path -LiteralPath $paths.Journal)){return $bad}
        Assert-LabTlsCaPrivateAcl $paths.Base $binding.Native.UserSid -Directory
        $lock=Enter-LabTlsTrustJournalLock $paths.Lock $binding.Native.UserSid
        try{$state=Get-LabTlsTrustJournalState $binding $paths}catch{throw 'TLS_TRUST_RECOVERY_REQUIRED'}
        if(Test-LabTlsRequestEnum $state.Status @('RECOVERY_REQUIRED')){throw 'TLS_TRUST_RECOVERY_REQUIRED'}
        if(Test-LabTlsRequestEnum $state.Status @('OWNED_IMPORT_RECORDED','PREEXISTING_NOT_OWNED')){
            if(-not (Test-LabTlsRequestEnum $checked.ApprovalId @($state.ApprovalId)) -or -not (Test-LabTlsRequestEnum $checked.PreviewId @($state.PreviewId)) -or
                -not (Test-LabTlsRequestEnum $checked.PreviewDigest @($state.PreviewDigest))){return $bad}
            return Get-LabTlsTrustImportResult $state.Status
        }
        $preview=Read-LabTlsTrustImportPreviewRecord $binding $paths $checked.PreviewId -RequireFresh
        if(-not (Test-LabTlsRequestEnum $checked.PreviewDigest @((Get-LabTlsTrustPreviewDigest $preview))) -or
            -not (Test-LabTlsRequestEnum $preview.BindingDigest @($binding.Digest)) -or -not (Test-LabTlsRequestEnum $preview.Prestate @($binding.Prestate))){return $bad}
        if(Test-LabTlsRequestEnum $binding.Prestate @('IDENTICAL_PREEXISTING_NOT_OWNED')){return Get-LabTlsTrustImportResult 'PREEXISTING_NOT_OWNED'}
        $intent=[pscustomobject][ordered]@{ContractVersion='SqlServerLab.TlsTrustImportIntent/0.1';ApprovalId=$checked.ApprovalId;PreviewId=$checked.PreviewId
            PreviewDigest=$checked.PreviewDigest;BindingDigest=$binding.Digest;CertificateSha256=$binding.Core.CertificateSha256;Store='CURRENT_USER_ROOT';Prestate='ABSENT'}
        $intentStarted=$true;$intentDigest=Write-LabTlsTrustJournalRecord $paths.Intent $binding.Native.UserSid $intent
        $fresh=Get-LabTlsTrustImportBinding $DataRoot $ControllerId $LocationId $CandidateId
        $freshPreview=Read-LabTlsTrustImportPreviewRecord $fresh $paths $checked.PreviewId -RequireFresh
        if(-not (Test-LabTlsRequestEnum $fresh.Digest @($binding.Digest)) -or -not (Test-LabTlsRequestEnum $fresh.Prestate @('ABSENT')) -or
            -not (Test-LabTlsRequestEnum (Get-LabTlsTrustPreviewDigest $freshPreview) @($checked.PreviewDigest)) -or
            -not (Test-LabTlsRequestEnum (Get-LabTlsCaByteDigest (Read-LabTlsCaPrivateFile $paths.Intent $fresh.Native.UserSid 8192)) @($intentDigest))){throw 'TLS_TRUST_RECOVERY_REQUIRED'}
        $writeResult=Add-LabTlsCurrentUserRootPublicCertificate $fresh.Der $CandidateId $fresh.Core.ActorDigest ([long]::Parse($freshPreview.ExpiresUtcTicks,[Globalization.CultureInfo]::InvariantCulture))
        if(-not (Test-LabTlsRequestEnum $writeResult @('ADD_RETURNED','PREEXISTING_AT_WRITE_BOUNDARY')) -or
            -not (Test-LabTlsRequestEnum (Get-LabTlsCaExistingTrust $fresh.Der) @('IDENTICAL_PREEXISTING_NOT_OWNED'))){throw 'TLS_TRUST_RECOVERY_REQUIRED'}
        $after=Get-LabTlsTrustImportBinding $DataRoot $ControllerId $LocationId $CandidateId
        if(-not (Test-LabTlsRequestEnum $after.Digest @($binding.Digest)) -or -not (Test-LabTlsRequestEnum $after.Prestate @('IDENTICAL_PREEXISTING_NOT_OWNED'))){throw 'TLS_TRUST_RECOVERY_REQUIRED'}
        $outcome=if(Test-LabTlsRequestEnum $writeResult @('ADD_RETURNED')){'OWNED_IMPORT_RECORDED'}else{'PREEXISTING_NOT_OWNED'}
        $commit=[pscustomobject][ordered]@{ContractVersion='SqlServerLab.TlsTrustImportCommit/0.1';ApprovalId=$checked.ApprovalId;PreviewDigest=$checked.PreviewDigest
            IntentByteSha256=$intentDigest;CertificateSha256=$binding.Core.CertificateSha256;Outcome=$outcome;Store='CURRENT_USER_ROOT'}
        $null=Write-LabTlsTrustJournalRecord $paths.Commit $binding.Native.UserSid $commit
        $confirmed=Get-LabTlsTrustJournalState $after $paths
        return Get-LabTlsTrustImportResult $confirmed.Status
    }catch{
        if($intentStarted -or (Test-LabTlsRequestEnum $_.Exception.Message @('TLS_TRUST_RECOVERY_REQUIRED'))){$bad.ErrorCode='TLS_TRUST_RECOVERY_REQUIRED'}
        elseif(Test-LabTlsRequestEnum $_.Exception.Message @('TLS_TRUST_JOURNAL_BUSY')){$bad.ErrorCode='TLS_TRUST_JOURNAL_BUSY'}
        return $bad
    }finally{if($null -ne $lock){$lock.Dispose()}}
}

function Get-LabAuthenticatedTlsTrustImportStatus {
    [CmdletBinding()]
    param([object]$DataRoot,[object]$ControllerId,[object]$LocationId,[object]$Context,[object]$CandidateId)
    $bad=[pscustomobject]@{Success=$false;Value=$null;ErrorCode='TLS_TRUST_STATUS_INVALID'}
    if(-not (Test-LabTlsTrustImportInput $DataRoot $ControllerId $LocationId $Context $CandidateId)){return $bad}
    $ControllerId=[guid]::Parse($ControllerId).ToString('D');$LocationId=[guid]::Parse($LocationId).ToString('D');$CandidateId=[guid]::Parse($CandidateId).ToString('D')
    $bad.ErrorCode='TLS_TRUST_RECOVERY_REQUIRED'
    try{
        $binding=Get-LabTlsTrustImportBinding $DataRoot $ControllerId $LocationId $CandidateId;$paths=Get-LabTlsTrustJournalPath $binding
        if(-not (Test-Path -LiteralPath $paths.Journal)){return Get-LabTlsTrustImportResult 'NO_TRANSACTION'}
        $bad.ErrorCode='TLS_TRUST_RECOVERY_REQUIRED'
        Assert-LabTlsCaPrivateAcl $paths.Base $binding.Native.UserSid -Directory
        if(Test-Path -LiteralPath $paths.Lock){return Get-LabTlsTrustImportResult 'BUSY'}
        $state=Get-LabTlsTrustJournalState $binding $paths
        if(Test-Path -LiteralPath $paths.Lock){return Get-LabTlsTrustImportResult 'BUSY'}
        return Get-LabTlsTrustImportResult $state.Status
    }catch{return $bad}
}
