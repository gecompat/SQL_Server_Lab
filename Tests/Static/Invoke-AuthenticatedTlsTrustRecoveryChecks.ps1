#Requires -Version 7.2
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$repo=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
. (Join-Path $PSScriptRoot '../Common/CheckResult.ps1')
foreach($name in @('DiagnosticBundleReader','AuthenticatedTlsRequest','AuthenticatedTlsRegistryPayload','AuthenticatedTlsRegistryRoot','AuthenticatedTlsContext','AuthenticatedTlsCaCandidate','AuthenticatedTlsTrustImport','AuthenticatedTlsTrustRecovery')){. (Join-Path $repo "Private/$name.ps1")}
$passed=0;$failures=[Collections.Generic.List[string]]::new()
$fixtureRoot=Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-tls-recovery-'+[guid]::NewGuid().ToString('N'))
$controller='11111111-1111-4111-8111-111111111111';$location='22222222-2222-4222-8222-222222222222';$candidate='33333333-3333-4333-8333-333333333333';$context='CURRENT_WINDOWS_PROCESS'
$dataRoot=Join-Path $fixtureRoot 'root';$script:ioCalls=0;$script:alienCalls=0;$script:addCalls=0;$script:bindingCalls=0;$script:driftAt=0
$realWrite=${function:Write-LabTlsTrustJournalRecord};$realLock=${function:Enter-LabTlsTrustJournalLock}
$realClock=${function:Get-LabTlsTrustRecoveryUtcNow}
function Assert-TlsRecoveryClosed {param([object[]]$Result,[string]$Code='TLS_TRUST_RECOVERY_REQUIRED')
    Add-CheckResult 'TLS-TR01 geschlossener Fehler ohne Roh-/Teilbefund' ($Result.Count -eq 1 -and @($Result[0].PSObject.Properties).Count -eq 3 -and -not $Result[0].Success -and $null -eq $Result[0].Value -and (Test-LabTlsRequestEnum $Result[0].ErrorCode @($Code)))
}
function Get-TlsRecoveryPreview {New-LabAuthenticatedTlsTrustRecoveryPreview $dataRoot $controller $location $context $candidate}
function Invoke-TlsRecovery {param($Approval) Invoke-LabAuthenticatedTlsTrustRecovery $dataRoot $controller $location $context $candidate $Approval}
function Get-TlsRecoveryStatus {Get-LabAuthenticatedTlsTrustImportStatus $dataRoot $controller $location $context $candidate}
function Get-TlsRecoveryApproval {param($Preview)
    return [pscustomobject]@{ContractVersion='SqlServerLab.TlsTrustRecoveryApproval/0.1';ApprovalId=[guid]::NewGuid().ToString('D');PreviewId=$Preview.Value.PreviewId
        PreviewDigest=$Preview.Value.PreviewDigest;OriginalApprovalId=$Preview.Value.OriginalApprovalId;OriginalIntentByteSha256=$Preview.Value.OriginalIntentByteSha256
        AdapterEvidenceId=[guid]::NewGuid().ToString('D');Decision='APPROVE_ONE_VISIBLE_CURRENT_USER_ROOT_RECOVERY'}
}
function Get-TlsRecoverySnapshot {param([string[]]$Paths) return (@($Paths|ForEach-Object {$_+':'+(Get-FileHash -LiteralPath $_).Hash}) -join '|')}
function Save-TlsRecoveryFixtureJson {param($Path,$Record) [IO.File]::WriteAllText($Path,($Record|ConvertTo-Json -Depth 5 -Compress))}
try{
    & {
        Set-StrictMode -Version Latest
        function Get-LabTlsTrustImportBinding {$script:ioCalls++;throw 'RECOVERY_INPUT_IO_CANARY'}
        $shape=[pscustomobject]@{ContractVersion='SqlServerLab.TlsTrustRecoveryApproval/0.1';ApprovalId=$controller;PreviewId=$candidate;PreviewDigest=('a'*64)
            OriginalApprovalId=$location;OriginalIntentByteSha256=('b'*64);AdapterEvidenceId=$candidate;Decision='APPROVE_ONE_VISIBLE_CURRENT_USER_ROOT_RECOVERY'}
        $alien=[pscustomobject]@{};$alien|Add-Member ScriptMethod ToString {$script:alienCalls++;throw 'ALIEN_CAST'} -Force
        $getter=$shape.PSObject.Copy();$getter|Add-Member ScriptProperty Decision {$script:alienCalls++;throw 'ALIEN_GETTER'} -Force
        foreach($bad in @($null,12,$alien,@($shape),$getter)) {Assert-TlsRecoveryClosed @(Invoke-TlsRecovery $bad *>&1) 'TLS_TRUST_RECOVERY_APPROVAL_INVALID'}
        foreach($name in @('ContractVersion','ApprovalId','PreviewId','PreviewDigest','OriginalApprovalId','OriginalIntentByteSha256','AdapterEvidenceId','Decision')){
            foreach($value in @($null,$alien,@('wrong'),('wrong'+[char]0x200b))){$bad=$shape.PSObject.Copy();$bad.$name=$value;Assert-TlsRecoveryClosed @(Invoke-TlsRecovery $bad *>&1) 'TLS_TRUST_RECOVERY_APPROVAL_INVALID'}
        }
        foreach($bad in @($null,12,$alien,@($candidate),'',($candidate+[char]0x200b))){
            Assert-TlsRecoveryClosed @(Invoke-LabAuthenticatedTlsTrustRecovery $dataRoot $controller $location $context $bad $shape *>&1) 'TLS_TRUST_RECOVERY_APPROVAL_INVALID'
            Assert-TlsRecoveryClosed @(New-LabAuthenticatedTlsTrustRecoveryPreview $dataRoot $controller $location $context $bad *>&1) 'TLS_TRUST_RECOVERY_PREVIEW_INVALID'
        }
        Add-CheckResult 'TLS-TR01 native Formen/ETS vor I/O; keine fremden Getter/Casts' ($script:ioCalls -eq 0 -and $script:alienCalls -eq 0)
        if(-not [Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows) -or [Management.Automation.PSVersionInfo]::PSVersion -lt [version]'7.5'){
            Assert-TlsRecoveryClosed @(Get-TlsRecoveryPreview *>&1) 'TLS_TRUST_RECOVERY_PREVIEW_INVALID'
            Write-Host 'TLS-TR Windows-Datei-/ACL-/Lockfixtures NOT_EXECUTED; native Storemutation NOT_EXECUTED'
            return
        }
        $native=Get-LabTlsWindowsProcessFacts;$sid=$native.UserSid
        $null=New-Item -ItemType Directory -Path $fixtureRoot
        $private=Join-Path $fixtureRoot 'private';$locationPath=Join-Path $private 'location';$candidatePath=Join-Path $locationPath $candidate
        foreach($path in @($private,$locationPath,$candidatePath)){Initialize-LabTlsCaPrivateDirectory $path $sid -NewOnly}
        # Nur synthetische oeffentliche/opaque Fixturebytes; keinerlei CA-Keyanlage/-oeffnung.
        $candidateFiles=@(foreach($name in @('intent.json','receipt.json','ca.der','key.dpapi')){$path=Join-Path $candidatePath $name;Write-LabTlsCaPrivateFile $path $sid ([Text.Encoding]::UTF8.GetBytes('SYNTHETIC_'+$name));$path})
        $script:core=[pscustomobject]@{ControllerId=$controller;LocationId=$location;CandidateId=$candidate;Store='CURRENT_USER_ROOT';RootMetadataDigest=('a'*64)
            ActorDigest=(Get-LabTlsCaActorDigest $native);CertificateSha256=(Get-FileHash -LiteralPath $candidateFiles[2]).Hash.ToLowerInvariant()
            IntentSha256=(Get-FileHash -LiteralPath $candidateFiles[0]).Hash.ToLowerInvariant();ReceiptSha256=(Get-FileHash -LiteralPath $candidateFiles[1]).Hash.ToLowerInvariant()
            CiphertextSha256=(Get-FileHash -LiteralPath $candidateFiles[3]).Hash.ToLowerInvariant()}
        $script:storeState='ABSENT'
        function Get-LabTlsTrustImportBinding {
            $script:bindingCalls++;Assert-LabTlsCaCandidateCapability
            $value=[pscustomobject]@{Core=$script:core;Digest=(Get-LabTlsTrustCoreDigest $script:core);Native=$native;Paths=[pscustomobject]@{Location=$locationPath;Candidate=$candidatePath}
                Der=([byte[]]@(1,2,3));Prestate=$script:storeState;Preview=[pscustomobject]@{NotBeforeUtc='2026-01-01T00:00:00.0000000Z';NotAfterUtc='2027-01-01T00:00:00.0000000Z'}}
            if($script:bindingCalls -eq $script:driftAt){$value.Digest='f'*64}
            return $value
        }
        function Get-LabTlsCaExistingTrust {throw 'REAL_STORE_READ_FORBIDDEN'}
        function Open-LabTlsCaSigningKey {throw 'PRIVATE_CA_KEY_FORBIDDEN'}
        function Assert-LabTlsCaEncryptedKey {throw 'PRIVATE_CA_KEY_FORBIDDEN'}
        function Add-LabTlsCurrentUserRootPublicCertificate {param($Der,$CandidateId,$ActorDigest,$ExpiresUtcTicks)
            if(-not (Test-LabTlsRequestEnum ([Convert]::ToBase64String($Der)) @('AQID')) -or -not (Test-LabTlsRequestEnum $CandidateId @($candidate)) -or
                -not (Test-LabTlsRequestEnum $ActorDigest @($script:core.ActorDigest)) -or $ExpiresUtcTicks -isnot [long] -or $ExpiresUtcTicks -le [datetime]::UtcNow.Ticks -or
                -not (Test-Path -LiteralPath $script:recoveryPaths.Intent) -or (Test-Path -LiteralPath $script:recoveryPaths.Commit)){throw 'RECOVERY_ADD_BOUNDARY_INVALID'}
            $script:addCalls++;$script:storeState='IDENTICAL_PREEXISTING_NOT_OWNED';return 'ADD_RETURNED'
        }
        $realMockAdd=${function:Add-LabTlsCurrentUserRootPublicCertificate}
        $binding=Get-LabTlsTrustImportBinding;$script:journalPaths=Get-LabTlsTrustJournalPath $binding;$script:recoveryPaths=Get-LabTlsTrustRecoveryPaths $script:journalPaths
        function Reset-TlsRecoveryFixture {param([switch]$Historic)
            $full=[IO.Path]::GetFullPath($script:journalPaths.Base);$prefix=[IO.Path]::GetFullPath($fixtureRoot).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
            if(-not $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or -not (Test-LabTlsRequestEnum ([IO.Path]::GetFileName($full)) @('trust-imports'))){throw 'RECOVERY_RESET_BOUNDARY'}
            if(Test-Path -LiteralPath $full){Remove-Item -LiteralPath $full -Recurse -Force}
            $script:storeState='ABSENT';$script:addCalls=0;$script:bindingCalls=0;$script:driftAt=0
            $pre=New-LabAuthenticatedTlsTrustImportPreview $dataRoot $controller $location $context $candidate
            if(-not $pre.Success){throw 'RECOVERY_ORIGINAL_FIXTURE_FAILED'}
            $path=Join-Path $script:journalPaths.Previews ($pre.Value.PreviewId+'.json')
            $record=[IO.File]::ReadAllText($path)|ConvertFrom-Json -DateKind String
            if($Historic){$issued=[datetime]::UtcNow.AddMinutes(-10);$record.IssuedUtcTicks=$issued.Ticks.ToString([Globalization.CultureInfo]::InvariantCulture);$record.ExpiresUtcTicks=$issued.AddMinutes(5).Ticks.ToString([Globalization.CultureInfo]::InvariantCulture);Save-TlsRecoveryFixtureJson $path $record}
            $intent=[pscustomobject]@{ContractVersion='SqlServerLab.TlsTrustImportIntent/0.1';ApprovalId=$controller;PreviewId=$pre.Value.PreviewId;PreviewDigest=(Get-LabTlsTrustPreviewDigest $record)
                BindingDigest=(Get-LabTlsTrustCoreDigest $script:core);CertificateSha256=$script:core.CertificateSha256;Store='CURRENT_USER_ROOT';Prestate='ABSENT'}
            $null=Write-LabTlsTrustJournalRecord $script:journalPaths.Intent $sid $intent
            $script:originalFiles=@($script:journalPaths.Owner,$script:journalPaths.Intent,$path)+$candidateFiles
            $script:originalSnapshot=Get-TlsRecoverySnapshot $script:originalFiles
        }
        Reset-TlsRecoveryFixture -Historic
        $pre=Get-TlsRecoveryPreview;$ap=Get-TlsRecoveryApproval $pre
        Add-CheckResult 'TLS-TR02 frische konkrete Recoverypreview trotz historisch abgelaufener Originalpreview' ($pre.Success -and $pre.Value.Status -ceq 'AWAITING_EXPLICIT_RECOVERY_APPROVAL' -and
            $pre.Value.QuiescenceStatus -ceq 'NOT_ATTESTED' -and $pre.Value.Prestate -ceq 'ABSENT' -and -not $pre.Value.Ready -and -not $pre.Value.MutationAllowed)
        $second=Get-TlsRecoveryPreview
        Add-CheckResult 'TLS-TR02 wiederholte Previews verbrauchen keinen Versuch oder Originalbytes' ($second.Success -and $second.Value.PreviewId -cne $pre.Value.PreviewId -and -not (Test-Path -LiteralPath $script:recoveryPaths.Intent) -and
            [string]::Equals($script:originalSnapshot,(Get-TlsRecoverySnapshot $script:originalFiles),[StringComparison]::Ordinal))
        foreach($name in @('PreviewId','PreviewDigest','OriginalApprovalId','OriginalIntentByteSha256')){
            $bad=$ap.PSObject.Copy();$bad.$name=if($name -in @('PreviewId','OriginalApprovalId')){[guid]::NewGuid().ToString('D')}else{'b'*64}
            Assert-TlsRecoveryClosed @(Invoke-TlsRecovery $bad *>&1) 'TLS_TRUST_RECOVERY_APPROVAL_INVALID'
        }
        Add-CheckResult 'TLS-TR03 andere Freigaben ohne Recoveryintent/Add' ($script:addCalls -eq 0 -and -not (Test-Path -LiteralPath $script:recoveryPaths.Intent))
        $held=Enter-LabTlsTrustJournalLock $script:journalPaths.Lock $sid
        try{Assert-TlsRecoveryClosed @(Invoke-TlsRecovery $ap *>&1) 'TLS_TRUST_JOURNAL_BUSY';Add-CheckResult 'TLS-TR03 zentraler Status BUSY' ((Get-TlsRecoveryStatus).Value.Status -ceq 'BUSY')}
        finally{$held.Dispose()}
        $result=Invoke-TlsRecovery $ap
        Add-CheckResult 'TLS-TR04 genau ein Add nach eigenem Intent mit bestaetigtem Recoverycommit' ($result.Success -and $result.Value.Status -ceq 'RECOVERY_IMPORT_RECORDED' -and
            $result.Value.RemovalAuthority -ceq 'NONE' -and $result.Value.StoreAtomicity -ceq 'COOPERATIVE_ONLY' -and $script:addCalls -eq 1 -and -not (Test-Path -LiteralPath $script:journalPaths.Commit))
        $snapshot=Get-TlsRecoverySnapshot (@($script:originalFiles)+@($script:recoveryPaths.Intent,$script:recoveryPaths.Commit))
        function Enter-LabTlsTrustJournalLock {throw 'COMPLETED_REPEAT_MUST_NOT_CREATE_LOCK'}
        try{$repeat=Invoke-TlsRecovery $ap;Add-CheckResult 'TLS-TR04 identische fertige Wiederholung rein lesend ohne Lock oder zweiten Add' ($repeat.Success -and $repeat.Value.Status -ceq 'RECOVERY_IMPORT_RECORDED' -and $script:addCalls -eq 1)}
        finally{Set-Item function:Enter-LabTlsTrustJournalLock $realLock}
        $held=Enter-LabTlsTrustJournalLock $script:journalPaths.Lock $sid
        try{Assert-TlsRecoveryClosed @(Invoke-TlsRecovery $ap *>&1) 'TLS_TRUST_JOURNAL_BUSY'}finally{$held.Dispose()}
        $originalIntent=[IO.File]::ReadAllText($script:journalPaths.Intent)|ConvertFrom-Json -DateKind String
        $normalApproval=[pscustomobject]@{ContractVersion='SqlServerLab.TlsTrustApproval/0.1';ApprovalId=$originalIntent.ApprovalId;PreviewId=$originalIntent.PreviewId;PreviewDigest=$originalIntent.PreviewDigest;Decision='APPROVE_CURRENT_USER_ROOT_PUBLIC_DER'}
        Assert-TlsRecoveryClosed @(Invoke-LabAuthenticatedTlsTrustImport $dataRoot $controller $location $context $candidate $normalApproval *>&1)
        Add-CheckResult 'TLS-TR04 zentraler Status bestaetigt Recovery und Originalbytes bleiben gleich' ((Get-TlsRecoveryStatus).Value.Status -ceq 'RECOVERY_IMPORT_RECORDED' -and
            [string]::Equals($snapshot,(Get-TlsRecoverySnapshot (@($script:originalFiles)+@($script:recoveryPaths.Intent,$script:recoveryPaths.Commit))),[StringComparison]::Ordinal) -and
            [string]::Equals($script:originalSnapshot,(Get-TlsRecoverySnapshot $script:originalFiles),[StringComparison]::Ordinal))
        $bad=$ap.PSObject.Copy();$bad.AdapterEvidenceId=[guid]::NewGuid().ToString('D');Assert-TlsRecoveryClosed @(Invoke-TlsRecovery $bad *>&1) 'TLS_TRUST_RECOVERY_APPROVAL_INVALID'
        $script:storeState='ABSENT';Assert-TlsRecoveryClosed @(Get-TlsRecoveryStatus *>&1);Assert-TlsRecoveryClosed @(Invoke-TlsRecovery $ap *>&1)
        Reset-TlsRecoveryFixture;$script:storeState='IDENTICAL_PREEXISTING_NOT_OWNED';$pre=Get-TlsRecoveryPreview;$ap=Get-TlsRecoveryApproval $pre;$result=Invoke-TlsRecovery $ap
        Add-CheckResult 'TLS-TR05 Present ohne kausalen Add bleibt UNATTRIBUTED; Originalverlust nie attribuiert' ($result.Success -and $result.Value.Status -ceq 'RECOVERY_PREEXISTING_UNATTRIBUTED' -and
            $script:addCalls -eq 0 -and (Get-TlsRecoveryStatus).Value.Status -ceq 'RECOVERY_PREEXISTING_UNATTRIBUTED')
        Reset-TlsRecoveryFixture;$pre=Get-TlsRecoveryPreview;$ap=Get-TlsRecoveryApproval $pre
        function Add-LabTlsCurrentUserRootPublicCertificate {$script:storeState='IDENTICAL_PREEXISTING_NOT_OWNED';return 'PREEXISTING_AT_WRITE_BOUNDARY'}
        try{$result=Invoke-TlsRecovery $ap;Add-CheckResult 'TLS-TR05 Writeboundary-Race bleibt PREEXISTING_UNATTRIBUTED ohne Add' ($result.Success -and $result.Value.Status -ceq 'RECOVERY_PREEXISTING_UNATTRIBUTED' -and $script:addCalls -eq 0)}
        finally{Set-Item function:Add-LabTlsCurrentUserRootPublicCertificate $realMockAdd}
        foreach($fault in @('beforeAdd','lostAddReturn','beforeCommit','intentReadback','commitAfterWrite','afterAddPreviewDrift')){
            Reset-TlsRecoveryFixture;$pre=Get-TlsRecoveryPreview;$ap=Get-TlsRecoveryApproval $pre;$script:fault=$fault
            function Add-LabTlsCurrentUserRootPublicCertificate {param($Der,$CandidateId,$ActorDigest,$ExpiresUtcTicks)
                if($script:fault -ceq 'beforeAdd'){throw 'FAULT_BEFORE_ADD'}
                $outcome=& $realMockAdd $Der $CandidateId $ActorDigest $ExpiresUtcTicks
                if($script:fault -ceq 'lostAddReturn'){throw 'FAULT_LOST_ADD_RETURN'}
                if($script:fault -ceq 'afterAddPreviewDrift'){
                    $path=Join-Path $script:recoveryPaths.Previews ($ap.PreviewId+'.json');$record=[IO.File]::ReadAllText($path)|ConvertFrom-Json -DateKind String
                    $issued=[datetime]::UtcNow.AddMinutes(-6);$record.IssuedUtcTicks=$issued.Ticks.ToString();$record.ExpiresUtcTicks=$issued.AddMinutes(5).Ticks.ToString();Save-TlsRecoveryFixtureJson $path $record
                }
                return $outcome
            }
            function Write-LabTlsTrustJournalRecord {param($Path,$UserSid,$Record)
                $leaf=[IO.Path]::GetFileName($Path)
                if($script:fault -ceq 'beforeCommit' -and $leaf -ceq 'recovery-commit.json'){throw 'FAULT_BEFORE_COMMIT'}
                $digest=& $realWrite $Path $UserSid $Record
                if(($script:fault -ceq 'intentReadback' -and $leaf -ceq 'recovery-intent.json') -or ($script:fault -ceq 'commitAfterWrite' -and $leaf -ceq 'recovery-commit.json')){throw 'FAULT_READBACK'}
                return $digest
            }
            try{
                Assert-TlsRecoveryClosed @(Invoke-TlsRecovery $ap *>&1)
                $status=Get-TlsRecoveryStatus;$before=$script:addCalls
                if($fault -ceq 'commitAfterWrite'){Add-CheckResult 'TLS-TR06 dauerhafter Recoverycommit nach verlorenem Callerresult lesend bestaetigt' ($status.Success -and $status.Value.Status -ceq 'RECOVERY_IMPORT_RECORDED')}
                else{Add-CheckResult 'TLS-TR06 unklarer Versuch bleibt terminal RECOVERY_REQUIRED' (($status.Success -and $status.Value.Status -ceq 'RECOVERY_REQUIRED') -or (-not $status.Success -and $status.ErrorCode -ceq 'TLS_TRUST_RECOVERY_REQUIRED'));Assert-TlsRecoveryClosed @(Invoke-TlsRecovery $ap *>&1)}
                Add-CheckResult 'TLS-TR06 kein zweiter Add/normaler Commit oder Originalveraenderung' ($script:addCalls -eq $before -and -not (Test-Path -LiteralPath $script:journalPaths.Commit) -and
                    [string]::Equals($script:originalSnapshot,(Get-TlsRecoverySnapshot $script:originalFiles),[StringComparison]::Ordinal))
                Assert-TlsRecoveryClosed @(Get-TlsRecoveryPreview *>&1)
            }finally{Set-Item function:Add-LabTlsCurrentUserRootPublicCertificate $realMockAdd;Set-Item function:Write-LabTlsTrustJournalRecord $realWrite}
        }
        Reset-TlsRecoveryFixture -Historic;$pre=Get-TlsRecoveryPreview;$ap=Get-TlsRecoveryApproval $pre;$script:afterAddUtc=$null
        function Get-LabTlsTrustRecoveryUtcNow {if($null -ne $script:afterAddUtc){return $script:afterAddUtc};return & $realClock}
        function Add-LabTlsCurrentUserRootPublicCertificate {param($Der,$CandidateId,$ActorDigest,$ExpiresUtcTicks)
            $outcome=& $realMockAdd $Der $CandidateId $ActorDigest $ExpiresUtcTicks
            $path=Join-Path $script:recoveryPaths.Previews ($ap.PreviewId+'.json')
            $script:expiryFiles=@($script:originalFiles)+@($path,$script:recoveryPaths.Intent)
            $script:expirySnapshot=Get-TlsRecoverySnapshot $script:expiryFiles
            $record=[IO.File]::ReadAllText($path)|ConvertFrom-Json -DateKind String
            $script:expiryDigest=Get-LabTlsTrustRecoveryPreviewDigest $record
            # Nur Testuhr nach Add vorstellen; kein einziges Journalbyte aendern.
            $script:afterAddUtc=[datetime]::new(([long]::Parse($record.ExpiresUtcTicks,[Globalization.CultureInfo]::InvariantCulture)+1),[DateTimeKind]::Utc)
            return $outcome
        }
        try{
            $expired=Invoke-TlsRecovery $ap;$status=Get-TlsRecoveryStatus;$repeat=Invoke-TlsRecovery $ap
            $record=[IO.File]::ReadAllText((Join-Path $script:recoveryPaths.Previews ($ap.PreviewId+'.json')))|ConvertFrom-Json -DateKind String
            Add-CheckResult 'TLS-TR06 nur Uhr nach Add abgelaufen: bytegleiche Preview bleibt terminal ohne Commit/zweiten Add' (-not $expired.Success -and $null -eq $expired.Value -and
                $expired.ErrorCode -ceq 'TLS_TRUST_RECOVERY_REQUIRED' -and $status.Success -and $status.Value.Status -ceq 'RECOVERY_REQUIRED' -and
                -not $repeat.Success -and $repeat.ErrorCode -ceq 'TLS_TRUST_RECOVERY_REQUIRED' -and $script:addCalls -eq 1 -and -not (Test-Path -LiteralPath $script:recoveryPaths.Commit) -and
                [string]::Equals($script:expirySnapshot,(Get-TlsRecoverySnapshot $script:expiryFiles),[StringComparison]::Ordinal) -and
                [string]::Equals($script:expiryDigest,$ap.PreviewDigest,[StringComparison]::Ordinal) -and
                [string]::Equals($script:expiryDigest,(Get-LabTlsTrustRecoveryPreviewDigest $record),[StringComparison]::Ordinal))
        }finally{Set-Item function:Add-LabTlsCurrentUserRootPublicCertificate $realMockAdd;Set-Item function:Get-LabTlsTrustRecoveryUtcNow $realClock;$script:afterAddUtc=$null}
        foreach($time in @(-6,1)){
            Reset-TlsRecoveryFixture;$pre=Get-TlsRecoveryPreview;$ap=Get-TlsRecoveryApproval $pre;$path=Join-Path $script:recoveryPaths.Previews ($ap.PreviewId+'.json')
            $record=[IO.File]::ReadAllText($path)|ConvertFrom-Json -DateKind String;$issued=[datetime]::UtcNow.AddMinutes($time);$record.IssuedUtcTicks=$issued.Ticks.ToString();$record.ExpiresUtcTicks=$issued.AddMinutes(5).Ticks.ToString()
            Save-TlsRecoveryFixtureJson $path $record;$ap.PreviewDigest=Get-LabTlsTrustRecoveryPreviewDigest $record
            Assert-TlsRecoveryClosed @(Invoke-TlsRecovery $ap *>&1) 'TLS_TRUST_RECOVERY_APPROVAL_INVALID'
            Add-CheckResult 'TLS-TR07 alte/future Recoverypreview vor Intent/Add gesperrt' ($script:addCalls -eq 0 -and -not (Test-Path -LiteralPath $script:recoveryPaths.Intent))
        }
        foreach($drift in @('originalIntent','originalPreview','root','actor','ca','normalCommit','missingIntent')){
            Reset-TlsRecoveryFixture;$pre=Get-TlsRecoveryPreview;$ap=Get-TlsRecoveryApproval $pre;$savedCore=$script:core.PSObject.Copy()
            switch($drift){
                originalIntent {[IO.File]::AppendAllText($script:journalPaths.Intent,' ')}
                originalPreview {[IO.File]::AppendAllText($script:originalFiles[2],' ')}
                root {$script:core.RootMetadataDigest='b'*64}
                actor {$script:core.ActorDigest='b'*64}
                ca {$script:core.CertificateSha256='b'*64}
                normalCommit {Write-LabTlsCaPrivateFile $script:journalPaths.Commit $sid ([Text.Encoding]::UTF8.GetBytes('{}'))}
                missingIntent {Remove-Item -LiteralPath $script:journalPaths.Intent}
            }
            $code=if($drift -in @('originalIntent','originalPreview')){'TLS_TRUST_RECOVERY_APPROVAL_INVALID'}else{'TLS_TRUST_RECOVERY_REQUIRED'}
            try{Assert-TlsRecoveryClosed @(Invoke-TlsRecovery $ap *>&1) $code;Add-CheckResult 'TLS-TR08 Original-/Root-/Actor-/CA-/mehrdeutige Bindung sperrt Add' ($script:addCalls -eq 0)}
            finally{$script:core=$savedCore}
        }
        Reset-TlsRecoveryFixture;$pre=Get-TlsRecoveryPreview;$ap=Get-TlsRecoveryApproval $pre;$script:bindingCalls=0;$script:driftAt=2
        Assert-TlsRecoveryClosed @(Invoke-TlsRecovery $ap *>&1)
        Add-CheckResult 'TLS-TR08 Drift nach dauerhaftem Recoveryintent blockiert Add' ($script:addCalls -eq 0 -and (Test-Path -LiteralPath $script:recoveryPaths.Intent))
        $script:driftAt=0
    }
    $err=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'Private/AuthenticatedTlsTrustRecovery.ps1'),[ref]$null,[ref]$err)
    Add-CheckResult 'TLS-TR09 Laden definiert nur Funktionen' ($err.Count -eq 0 -and @($ast.EndBlock.Statements|Where-Object {$_ -isnot [Management.Automation.Language.FunctionDefinitionAst]}).Count -eq 0)
    Add-CheckResult 'TLS-TR09 keine Key-/Store-/Removal-/SQL-/Provider-/C#-Nebenaktion' ($ast.Extent.Text -notmatch '(?i)Unprotect|Open-LabTlsCaSigningKey|X509Store|ExportPkcs|ImportPkcs|Add-Type|Remove-Item|\.Remove\(|Invoke-Sqlcmd|Start-Process|LocalMachine')
    Add-CheckResult 'TLS-TR09 Stringidentitaeten ordinal' (@($ast.FindAll({param($node) $node -is [Management.Automation.Language.BinaryExpressionAst] -and $node.Operator.ToString() -in @('Ceq','Cne','Cin','Cnotin')},$true)).Count -eq 0)
    Write-Host "Authenticated TLS Trust Recovery: $passed PASS, $($failures.Count) FAIL; native Rootstoremutation NOT_EXECUTED"
    if($failures.Count){throw 'AUTHENTICATED_TLS_TRUST_RECOVERY_CHECKS_FAILED'}
}finally{
    $full=[IO.Path]::GetFullPath($fixtureRoot);$prefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    if(-not $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -cnotmatch '\Asql-lab-tls-recovery-[a-f0-9]{32}\z'){throw 'TLS_TRUST_RECOVERY_CLEANUP_BOUNDARY'}
    if(Test-Path -LiteralPath $full){Remove-Item -LiteralPath $full -Recurse -Force}
    if(Test-Path -LiteralPath $full){throw 'TLS_TRUST_RECOVERY_CLEANUP_FAILED'}
    Write-Host 'TLS-TR eigene private Datei-/ACL-/Lockfixtures CLEANED'
}
