#Requires -Version 7.2
# Explizite einmalige Recovery; Originaljournal bleibt unveraendert, kein Removal.

function Get-LabTlsTrustRecoveryUtcNow {
    return [datetime]::UtcNow
}

function Get-LabTlsTrustRecoveryPaths {
    param([object]$Paths)
    return [pscustomobject]@{Previews=(Join-Path $Paths.Journal 'recovery-previews');Intent=(Join-Path $Paths.Journal 'recovery-intent.json');Commit=(Join-Path $Paths.Journal 'recovery-commit.json')}
}

function Test-LabTlsTrustRecoveryApproval {
    param([object]$Approval)
    $names=@('ContractVersion','ApprovalId','PreviewId','PreviewDigest','OriginalApprovalId','OriginalIntentByteSha256','AdapterEvidenceId','Decision')
    $fields=Get-LabTlsRequestFields $Approval $names
    if($null -eq $fields -or $fields.Count -ne $names.Count -or
        -not (Test-LabTlsRequestEnum $fields.ContractVersion @('SqlServerLab.TlsTrustRecoveryApproval/0.1')) -or
        -not (Test-LabTlsRequestEnum $fields.Decision @('APPROVE_ONE_VISIBLE_CURRENT_USER_ROOT_RECOVERY'))){return $null}
    foreach($name in @('ApprovalId','PreviewId','OriginalApprovalId','AdapterEvidenceId')){if(-not (Test-LabTlsRequestReference $fields.$name)){return $null}}
    foreach($name in @('PreviewDigest','OriginalIntentByteSha256')){if($fields.$name -isnot [string] -or $fields.$name -cnotmatch '\A[0-9a-f]{64}\z'){return $null}}
    return [pscustomobject]@{ContractVersion='SqlServerLab.TlsTrustRecoveryApproval/0.1';ApprovalId=[guid]::Parse($fields.ApprovalId).ToString('D')
        PreviewId=[guid]::Parse($fields.PreviewId).ToString('D');OriginalApprovalId=[guid]::Parse($fields.OriginalApprovalId).ToString('D')
        AdapterEvidenceId=[guid]::Parse($fields.AdapterEvidenceId).ToString('D');PreviewDigest=[string]::Concat($fields.PreviewDigest)
        OriginalIntentByteSha256=[string]::Concat($fields.OriginalIntentByteSha256);Decision='APPROVE_ONE_VISIBLE_CURRENT_USER_ROOT_RECOVERY'}
}

function Get-LabTlsTrustRecoveryOriginal {
    param([object]$Binding,[object]$Paths)
    try{
    # Vollstaendige urspruengliche Bindung; historisches Ablaufdatum nicht umschreiben.
    $state=Get-LabTlsTrustJournalState $Binding $Paths -OriginalOnly
    if(-not (Test-LabTlsRequestEnum $state.Status @('RECOVERY_REQUIRED')) -or (Test-Path -LiteralPath $Paths.Commit)){throw 'TLS_TRUST_RECOVERY_REQUIRED'}
    $intent=Read-LabTlsTrustJournalRecord $Paths.Intent $Binding.Native.UserSid @('ContractVersion','ApprovalId','PreviewId','PreviewDigest','BindingDigest','CertificateSha256','Store','Prestate')
    $preview=Read-LabTlsTrustImportPreviewRecord $Binding $Paths $intent.Record.PreviewId
    if([long]::Parse($preview.IssuedUtcTicks,[Globalization.CultureInfo]::InvariantCulture) -gt [datetime]::UtcNow.Ticks){throw 'TLS_TRUST_RECOVERY_REQUIRED'}
    if(-not (Test-LabTlsRequestEnum $intent.Record.ApprovalId @($state.ApprovalId)) -or
        -not (Test-LabTlsRequestEnum $intent.Record.PreviewId @($state.PreviewId)) -or
        -not (Test-LabTlsRequestEnum $intent.Record.PreviewDigest @($state.PreviewDigest)) -or
        -not (Test-LabTlsRequestEnum (Get-LabTlsTrustPreviewDigest $preview) @($state.PreviewDigest)) -or
        -not (Test-LabTlsRequestEnum $intent.Record.BindingDigest @($Binding.Digest))){throw 'TLS_TRUST_RECOVERY_REQUIRED'}
    $owner=(Read-LabTlsTrustJournalRecord $Paths.Owner $Binding.Native.UserSid @('ContractVersion','CandidateId','ControllerId','LocationId','RootMetadataDigest','ActorDigest')).ByteDigest
    $previewBytes=Get-LabTlsCaByteDigest (Read-LabTlsCaPrivateFile (Join-Path $Paths.Previews ($state.PreviewId+'.json')) $Binding.Native.UserSid 8192)
    $digest=Get-LabTlsPayloadDigest @('SqlServerLab.TlsTrustRecoveryOriginal/0.1',$Binding.Digest,$owner,$intent.ByteDigest,$previewBytes,$state.ApprovalId,$state.PreviewId,$state.PreviewDigest)
    return [pscustomobject]@{Digest=$digest;IntentByteSha256=$intent.ByteDigest;ApprovalId=$state.ApprovalId;PreviewId=$state.PreviewId;PreviewDigest=$state.PreviewDigest}
    }catch{throw 'TLS_TRUST_RECOVERY_REQUIRED'}
}

function Get-LabTlsTrustRecoveryPreviewDigest {
    param([object]$Record)
    return Get-LabTlsPayloadDigest @('SqlServerLab.TlsTrustRecoveryPreviewDigest/0.1',$Record.PreviewId,$Record.BindingDigest,$Record.OriginalDigest,
        $Record.OriginalIntentByteSha256,$Record.OriginalApprovalId,$Record.OriginalPreviewDigest,$Record.Prestate,$Record.IssuedUtcTicks,$Record.ExpiresUtcTicks)
}

function Read-LabTlsTrustRecoveryPreview {
    param([object]$Binding,[object]$Paths,[object]$Original,[string]$PreviewId,[switch]$RequireFresh)
    $recovery=Get-LabTlsTrustRecoveryPaths $Paths
    Assert-LabTlsCaPrivateAcl $recovery.Previews $Binding.Native.UserSid -Directory
    $names=@('ContractVersion','PreviewId','BindingDigest','OriginalDigest','OriginalIntentByteSha256','OriginalApprovalId','OriginalPreviewDigest','Prestate','IssuedUtcTicks','ExpiresUtcTicks')
    $record=(Read-LabTlsTrustJournalRecord (Join-Path $recovery.Previews ($PreviewId+'.json')) $Binding.Native.UserSid $names).Record
    $issued=0L;$expires=0L;$now=Get-LabTlsTrustRecoveryUtcNow
    if(-not (Test-LabTlsRequestEnum $record.ContractVersion @('SqlServerLab.TlsTrustRecoveryPreview/0.1')) -or
        -not (Test-LabTlsRequestEnum $record.PreviewId @($PreviewId)) -or -not (Test-LabTlsRequestEnum $record.BindingDigest @($Binding.Digest)) -or
        -not (Test-LabTlsRequestEnum $record.OriginalDigest @($Original.Digest)) -or -not (Test-LabTlsRequestEnum $record.OriginalIntentByteSha256 @($Original.IntentByteSha256)) -or
        -not (Test-LabTlsRequestEnum $record.OriginalApprovalId @($Original.ApprovalId)) -or -not (Test-LabTlsRequestEnum $record.OriginalPreviewDigest @($Original.PreviewDigest)) -or
        -not (Test-LabTlsRequestEnum $record.Prestate @('ABSENT','IDENTICAL_PREEXISTING_NOT_OWNED')) -or
        $record.IssuedUtcTicks -cnotmatch '\A[0-9]{18,19}\z' -or $record.ExpiresUtcTicks -cnotmatch '\A[0-9]{18,19}\z' -or
        -not [long]::TryParse($record.IssuedUtcTicks,[Globalization.NumberStyles]::None,[Globalization.CultureInfo]::InvariantCulture,[ref]$issued) -or
        -not [long]::TryParse($record.ExpiresUtcTicks,[Globalization.NumberStyles]::None,[Globalization.CultureInfo]::InvariantCulture,[ref]$expires) -or
        $issued -lt [datetime]::MinValue.Ticks -or $expires -gt [datetime]::MaxValue.Ticks -or $expires-$issued -ne [timespan]::FromMinutes(5).Ticks -or
        $issued -gt $now.Ticks -or ($RequireFresh -and $expires -le $now.Ticks)){throw 'TLS_TRUST_RECOVERY_APPROVAL_INVALID'}
    return $record
}

function Get-LabTlsTrustRecoveryJournalState {
    param([object]$Binding,[object]$Paths)
    $original=Get-LabTlsTrustRecoveryOriginal $Binding $Paths;$recovery=Get-LabTlsTrustRecoveryPaths $Paths
    if(-not (Test-Path -LiteralPath $recovery.Intent)){throw 'TLS_TRUST_RECOVERY_REQUIRED'}
    $intent=Read-LabTlsTrustJournalRecord $recovery.Intent $Binding.Native.UserSid @('ContractVersion','ApprovalId','PreviewId','PreviewDigest','OriginalDigest','OriginalIntentByteSha256','OriginalApprovalId','AdapterEvidenceId','BindingDigest','Prestate')
    $record=$intent.Record
    if(-not (Test-LabTlsRequestEnum $record.ContractVersion @('SqlServerLab.TlsTrustRecoveryIntent/0.1')) -or
        -not (Test-LabTlsRequestReference $record.ApprovalId) -or -not (Test-LabTlsRequestReference $record.PreviewId) -or -not (Test-LabTlsRequestReference $record.AdapterEvidenceId) -or
        -not (Test-LabTlsRequestEnum $record.BindingDigest @($Binding.Digest)) -or -not (Test-LabTlsRequestEnum $record.OriginalDigest @($original.Digest)) -or
        -not (Test-LabTlsRequestEnum $record.OriginalIntentByteSha256 @($original.IntentByteSha256)) -or -not (Test-LabTlsRequestEnum $record.OriginalApprovalId @($original.ApprovalId))){throw 'TLS_TRUST_RECOVERY_REQUIRED'}
    $preview=Read-LabTlsTrustRecoveryPreview $Binding $Paths $original $record.PreviewId
    if(-not (Test-LabTlsRequestEnum $record.PreviewDigest @((Get-LabTlsTrustRecoveryPreviewDigest $preview))) -or
        -not (Test-LabTlsRequestEnum $record.Prestate @($preview.Prestate))){throw 'TLS_TRUST_RECOVERY_REQUIRED'}
    if(-not (Test-Path -LiteralPath $recovery.Commit)){return [pscustomobject]@{Status='RECOVERY_REQUIRED'}}
    $commit=(Read-LabTlsTrustJournalRecord $recovery.Commit $Binding.Native.UserSid @('ContractVersion','ApprovalId','PreviewDigest','RecoveryIntentByteSha256','OriginalDigest','CertificateSha256','Outcome','WriteResult','Store')).Record
    $outcome=if(Test-LabTlsRequestEnum $commit.WriteResult @('ADD_RETURNED')){'RECOVERY_IMPORT_RECORDED'}elseif(Test-LabTlsRequestEnum $commit.WriteResult @('NO_ADD_PREEXISTING','PREEXISTING_AT_WRITE_BOUNDARY')){'RECOVERY_PREEXISTING_UNATTRIBUTED'}else{throw 'TLS_TRUST_RECOVERY_REQUIRED'}
    if(-not (Test-LabTlsRequestEnum $commit.ContractVersion @('SqlServerLab.TlsTrustRecoveryCommit/0.1')) -or
        -not (Test-LabTlsRequestEnum $commit.ApprovalId @($record.ApprovalId)) -or -not (Test-LabTlsRequestEnum $commit.PreviewDigest @($record.PreviewDigest)) -or
        -not (Test-LabTlsRequestEnum $commit.RecoveryIntentByteSha256 @($intent.ByteDigest)) -or -not (Test-LabTlsRequestEnum $commit.OriginalDigest @($original.Digest)) -or
        -not (Test-LabTlsRequestEnum $commit.CertificateSha256 @($Binding.Core.CertificateSha256)) -or -not (Test-LabTlsRequestEnum $commit.Store @('CURRENT_USER_ROOT')) -or
        -not (Test-LabTlsRequestEnum $commit.Outcome @($outcome)) -or -not (Test-LabTlsRequestEnum $Binding.Prestate @('IDENTICAL_PREEXISTING_NOT_OWNED')) -or
        ((Test-LabTlsRequestEnum $commit.WriteResult @('ADD_RETURNED','PREEXISTING_AT_WRITE_BOUNDARY')) -and -not (Test-LabTlsRequestEnum $record.Prestate @('ABSENT'))) -or
        ((Test-LabTlsRequestEnum $commit.WriteResult @('NO_ADD_PREEXISTING')) -and -not (Test-LabTlsRequestEnum $record.Prestate @('IDENTICAL_PREEXISTING_NOT_OWNED')))){throw 'TLS_TRUST_RECOVERY_REQUIRED'}
    return [pscustomobject]@{Status=$outcome;ApprovalId=$record.ApprovalId;PreviewId=$record.PreviewId;PreviewDigest=$record.PreviewDigest
        OriginalApprovalId=$record.OriginalApprovalId;OriginalIntentByteSha256=$record.OriginalIntentByteSha256;AdapterEvidenceId=$record.AdapterEvidenceId}
}

function Test-LabTlsTrustRecoveryCompletedApproval {
    param([object]$Approval,[object]$State)
    foreach($name in @('ApprovalId','PreviewId','PreviewDigest','OriginalApprovalId','OriginalIntentByteSha256','AdapterEvidenceId')){
        if(-not (Test-LabTlsRequestEnum $Approval.$name @($State.$name))){return $false}
    }
    return $true
}

function New-LabAuthenticatedTlsTrustRecoveryPreview {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Private protected recovery preview only; no store mutation or authority creation.')]
    [CmdletBinding()]
    param([object]$DataRoot,[object]$ControllerId,[object]$LocationId,[object]$Context,[object]$CandidateId)
    $bad=[pscustomobject]@{Success=$false;Value=$null;ErrorCode='TLS_TRUST_RECOVERY_PREVIEW_INVALID'}
    if(-not (Test-LabTlsTrustImportInput $DataRoot $ControllerId $LocationId $Context $CandidateId)){return $bad}
    $ControllerId=[guid]::Parse($ControllerId).ToString('D');$LocationId=[guid]::Parse($LocationId).ToString('D');$CandidateId=[guid]::Parse($CandidateId).ToString('D')
    $lock=$null
    try{
        $binding=Get-LabTlsTrustImportBinding $DataRoot $ControllerId $LocationId $CandidateId;$paths=Get-LabTlsTrustJournalPath $binding
        Assert-LabTlsCaPrivateAcl $paths.Base $binding.Native.UserSid -Directory
        $lock=Enter-LabTlsTrustJournalLock $paths.Lock $binding.Native.UserSid
        $original=Get-LabTlsTrustRecoveryOriginal $binding $paths;$recovery=Get-LabTlsTrustRecoveryPaths $paths
        if((Test-Path -LiteralPath $recovery.Intent) -or (Test-Path -LiteralPath $recovery.Commit)){throw 'TLS_TRUST_RECOVERY_REQUIRED'}
        Initialize-LabTlsCaPrivateDirectory $recovery.Previews $binding.Native.UserSid
        $issued=[datetime]::UtcNow;$id=[guid]::NewGuid().ToString('D')
        $record=[pscustomobject][ordered]@{ContractVersion='SqlServerLab.TlsTrustRecoveryPreview/0.1';PreviewId=$id;BindingDigest=$binding.Digest;OriginalDigest=$original.Digest
            OriginalIntentByteSha256=$original.IntentByteSha256;OriginalApprovalId=$original.ApprovalId;OriginalPreviewDigest=$original.PreviewDigest;Prestate=$binding.Prestate
            IssuedUtcTicks=$issued.Ticks.ToString([Globalization.CultureInfo]::InvariantCulture);ExpiresUtcTicks=$issued.AddMinutes(5).Ticks.ToString([Globalization.CultureInfo]::InvariantCulture)}
        $null=Write-LabTlsTrustJournalRecord (Join-Path $recovery.Previews ($id+'.json')) $binding.Native.UserSid $record
        $fresh=Get-LabTlsTrustImportBinding $DataRoot $ControllerId $LocationId $CandidateId;$again=Get-LabTlsTrustRecoveryOriginal $fresh $paths
        $checked=Read-LabTlsTrustRecoveryPreview $fresh $paths $again $id -RequireFresh
        if(-not (Test-LabTlsRequestEnum $again.Digest @($original.Digest)) -or -not (Test-LabTlsRequestEnum $fresh.Prestate @($binding.Prestate))){throw 'TLS_TRUST_RECOVERY_REQUIRED'}
        return [pscustomobject]@{Success=$true;Value=[pscustomobject][ordered]@{PreviewId=$id;PreviewDigest=(Get-LabTlsTrustRecoveryPreviewDigest $checked);ExpiresUtc=$issued.AddMinutes(5).ToString('O')
            OriginalIntentByteSha256=$original.IntentByteSha256;OriginalApprovalId=$original.ApprovalId;OriginalPreviewId=$original.PreviewId;OriginalPreviewDigest=$original.PreviewDigest
            OriginalDigest=$original.Digest;BindingDigest=$binding.Digest;CandidateId=$CandidateId;CertificateSha256=$binding.Core.CertificateSha256
            NotBeforeUtc=$binding.Preview.NotBeforeUtc;NotAfterUtc=$binding.Preview.NotAfterUtc;UserSid=$binding.Native.UserSid;HostMarker=$binding.Native.HostMarker;ProfilePath=$binding.Native.ProfilePath
            Store='CURRENT_USER_ROOT';Prestate=$binding.Prestate;ApprovalEffect='Trust may affect other applications of this Windows user.';Status='AWAITING_EXPLICIT_RECOVERY_APPROVAL'
            QuiescenceStatus='NOT_ATTESTED';RemovalAuthority='NONE';StoreAtomicity='COOPERATIVE_ONLY';RegistrationStatus='NOT_EXECUTED';TlsStatus='NOT_EXECUTED';Ready=$false;MutationAllowed=$false};ErrorCode=$null}
    }catch{if(Test-LabTlsRequestEnum $_.Exception.Message @('TLS_TRUST_JOURNAL_BUSY','TLS_TRUST_RECOVERY_REQUIRED')){$bad.ErrorCode=$_.Exception.Message};return $bad}
    finally{if($null -ne $lock){$lock.Dispose()}}
}

function Invoke-LabAuthenticatedTlsTrustRecovery {
    [CmdletBinding()]
    param([object]$DataRoot,[object]$ControllerId,[object]$LocationId,[object]$Context,[object]$CandidateId,[object]$Approval)
    $bad=[pscustomobject]@{Success=$false;Value=$null;ErrorCode='TLS_TRUST_RECOVERY_APPROVAL_INVALID'}
    if(-not (Test-LabTlsTrustImportInput $DataRoot $ControllerId $LocationId $Context $CandidateId)){return $bad}
    $checked=Test-LabTlsTrustRecoveryApproval $Approval;if($null -eq $checked){return $bad}
    $ControllerId=[guid]::Parse($ControllerId).ToString('D');$LocationId=[guid]::Parse($LocationId).ToString('D');$CandidateId=[guid]::Parse($CandidateId).ToString('D')
    $lock=$null;$started=$false
    try{
        $binding=Get-LabTlsTrustImportBinding $DataRoot $ControllerId $LocationId $CandidateId;$paths=Get-LabTlsTrustJournalPath $binding
        Assert-LabTlsCaPrivateAcl $paths.Base $binding.Native.UserSid -Directory
        $recovery=Get-LabTlsTrustRecoveryPaths $paths
        # Abgeschlossene Wiederholung ist ausschliesslich lesend, auch ohne Lockanlage.
        if((Test-Path -LiteralPath $recovery.Intent) -or (Test-Path -LiteralPath $recovery.Commit)){
            $started=$true
            if(Test-Path -LiteralPath $paths.Lock){throw 'TLS_TRUST_JOURNAL_BUSY'}
            $state=Get-LabTlsTrustRecoveryJournalState $binding $paths
            if(Test-Path -LiteralPath $paths.Lock){throw 'TLS_TRUST_JOURNAL_BUSY'}
            if(Test-LabTlsRequestEnum $state.Status @('RECOVERY_REQUIRED')){throw 'TLS_TRUST_RECOVERY_REQUIRED'}
            if(-not (Test-LabTlsTrustRecoveryCompletedApproval $checked $state)){return $bad}
            return Get-LabTlsTrustImportResult $state.Status
        }
        $lock=Enter-LabTlsTrustJournalLock $paths.Lock $binding.Native.UserSid
        $original=Get-LabTlsTrustRecoveryOriginal $binding $paths;$recovery=Get-LabTlsTrustRecoveryPaths $paths
        if((Test-Path -LiteralPath $recovery.Intent) -or (Test-Path -LiteralPath $recovery.Commit)){
            $started=$true
            $state=Get-LabTlsTrustRecoveryJournalState $binding $paths
            if(Test-LabTlsRequestEnum $state.Status @('RECOVERY_REQUIRED')){throw 'TLS_TRUST_RECOVERY_REQUIRED'}
            if(-not (Test-LabTlsTrustRecoveryCompletedApproval $checked $state)){return $bad}
            return Get-LabTlsTrustImportResult $state.Status
        }
        $preview=Read-LabTlsTrustRecoveryPreview $binding $paths $original $checked.PreviewId -RequireFresh
        if(-not (Test-LabTlsRequestEnum $checked.PreviewDigest @((Get-LabTlsTrustRecoveryPreviewDigest $preview))) -or
            -not (Test-LabTlsRequestEnum $checked.OriginalApprovalId @($original.ApprovalId)) -or -not (Test-LabTlsRequestEnum $checked.OriginalIntentByteSha256 @($original.IntentByteSha256)) -or
            -not (Test-LabTlsRequestEnum $preview.Prestate @($binding.Prestate))){return $bad}
        $intent=[pscustomobject][ordered]@{ContractVersion='SqlServerLab.TlsTrustRecoveryIntent/0.1';ApprovalId=$checked.ApprovalId;PreviewId=$checked.PreviewId;PreviewDigest=$checked.PreviewDigest
            OriginalDigest=$original.Digest;OriginalIntentByteSha256=$original.IntentByteSha256;OriginalApprovalId=$original.ApprovalId;AdapterEvidenceId=$checked.AdapterEvidenceId
            BindingDigest=$binding.Digest;Prestate=$binding.Prestate}
        $started=$true;$intentDigest=Write-LabTlsTrustJournalRecord $recovery.Intent $binding.Native.UserSid $intent
        $fresh=Get-LabTlsTrustImportBinding $DataRoot $ControllerId $LocationId $CandidateId;$again=Get-LabTlsTrustRecoveryOriginal $fresh $paths
        $freshPreview=Read-LabTlsTrustRecoveryPreview $fresh $paths $again $checked.PreviewId -RequireFresh
        if(-not (Test-LabTlsRequestEnum $fresh.Digest @($binding.Digest)) -or -not (Test-LabTlsRequestEnum $again.Digest @($original.Digest)) -or
            -not (Test-LabTlsRequestEnum $fresh.Prestate @($binding.Prestate)) -or -not (Test-LabTlsRequestEnum (Get-LabTlsTrustRecoveryPreviewDigest $freshPreview) @($checked.PreviewDigest)) -or
            -not (Test-LabTlsRequestEnum (Get-LabTlsCaByteDigest (Read-LabTlsCaPrivateFile $recovery.Intent $fresh.Native.UserSid 8192)) @($intentDigest))){throw 'TLS_TRUST_RECOVERY_REQUIRED'}
        $writeResult=if(Test-LabTlsRequestEnum $fresh.Prestate @('ABSENT')){
            Add-LabTlsCurrentUserRootPublicCertificate $fresh.Der $CandidateId $fresh.Core.ActorDigest ([long]::Parse($freshPreview.ExpiresUtcTicks,[Globalization.CultureInfo]::InvariantCulture))
        }else{'NO_ADD_PREEXISTING'}
        if(-not (Test-LabTlsRequestEnum $writeResult @('ADD_RETURNED','PREEXISTING_AT_WRITE_BOUNDARY','NO_ADD_PREEXISTING'))){throw 'TLS_TRUST_RECOVERY_REQUIRED'}
        $after=Get-LabTlsTrustImportBinding $DataRoot $ControllerId $LocationId $CandidateId;$afterOriginal=Get-LabTlsTrustRecoveryOriginal $after $paths
        $afterPreview=Read-LabTlsTrustRecoveryPreview $after $paths $afterOriginal $checked.PreviewId -RequireFresh
        if(-not (Test-LabTlsRequestEnum $after.Digest @($binding.Digest)) -or -not (Test-LabTlsRequestEnum $afterOriginal.Digest @($original.Digest)) -or
            -not (Test-LabTlsRequestEnum $after.Prestate @('IDENTICAL_PREEXISTING_NOT_OWNED')) -or
            -not (Test-LabTlsRequestEnum (Get-LabTlsTrustRecoveryPreviewDigest $afterPreview) @($checked.PreviewDigest)) -or
            -not (Test-LabTlsRequestEnum (Get-LabTlsCaByteDigest (Read-LabTlsCaPrivateFile $recovery.Intent $after.Native.UserSid 8192)) @($intentDigest))){throw 'TLS_TRUST_RECOVERY_REQUIRED'}
        $outcome=if(Test-LabTlsRequestEnum $writeResult @('ADD_RETURNED')){'RECOVERY_IMPORT_RECORDED'}else{'RECOVERY_PREEXISTING_UNATTRIBUTED'}
        $commit=[pscustomobject][ordered]@{ContractVersion='SqlServerLab.TlsTrustRecoveryCommit/0.1';ApprovalId=$checked.ApprovalId;PreviewDigest=$checked.PreviewDigest
            RecoveryIntentByteSha256=$intentDigest;OriginalDigest=$original.Digest;CertificateSha256=$binding.Core.CertificateSha256;Outcome=$outcome;WriteResult=$writeResult;Store='CURRENT_USER_ROOT'}
        $null=Write-LabTlsTrustJournalRecord $recovery.Commit $after.Native.UserSid $commit
        $latest=Get-LabTlsTrustImportBinding $DataRoot $ControllerId $LocationId $CandidateId
        $confirmed=Get-LabTlsTrustRecoveryJournalState $latest $paths
        return Get-LabTlsTrustImportResult $confirmed.Status
    }catch{
        if(Test-LabTlsRequestEnum $_.Exception.Message @('TLS_TRUST_JOURNAL_BUSY')){$bad.ErrorCode='TLS_TRUST_JOURNAL_BUSY'}
        elseif($started -or (Test-LabTlsRequestEnum $_.Exception.Message @('TLS_TRUST_RECOVERY_REQUIRED'))){$bad.ErrorCode='TLS_TRUST_RECOVERY_REQUIRED'}
        return $bad
    }finally{if($null -ne $lock){$lock.Dispose()}}
}
