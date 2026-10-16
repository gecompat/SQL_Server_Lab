#Requires -Version 7.2
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$repo=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
. (Join-Path $PSScriptRoot '../Common/CheckResult.ps1')
foreach($name in @('DiagnosticBundleReader','AuthenticatedTlsRequest','AuthenticatedTlsRegistryPayload','AuthenticatedTlsRegistryRoot','AuthenticatedTlsContext','AuthenticatedTlsCaCandidate','AuthenticatedTlsTrustImport')){. (Join-Path $repo "Private/$name.ps1")}
$passed=0;$failures=[Collections.Generic.List[string]]::new()
$fixtureRoot=Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-tls-import-'+[guid]::NewGuid().ToString('N'))
$controller='11111111-1111-4111-8111-111111111111';$location='22222222-2222-4222-8222-222222222222';$context='CURRENT_WINDOWS_PROCESS'
$dataRoot=Join-Path $fixtureRoot 'root';$script:addCalls=0;$script:ioCalls=0;$script:alienCalls=0
$script:candidateId=$controller
$realBinding=${function:Get-LabTlsTrustImportBinding};$realWrite=${function:Write-LabTlsTrustJournalRecord}
function Assert-TlsTrustClosed {param([object[]]$Result,[string]$Code)
    Add-CheckResult 'TLS-TI01 geschlossener Fehler ohne Rohdaten oder Teilbefund' ($Result.Count -eq 1 -and @($Result[0].PSObject.Properties).Count -eq 3 -and -not $Result[0].Success -and $null -eq $Result[0].Value -and [string]::Equals($Result[0].ErrorCode,$Code,[StringComparison]::Ordinal))
}
function Save-TlsTrustJson {param($Path,$Value) [IO.File]::WriteAllText($Path,($Value|ConvertTo-Json -Depth 8 -Compress))}
function Get-TlsTrustSnapshot {param($Path) return (@(Get-ChildItem -LiteralPath $Path -Recurse -File|Sort-Object FullName|ForEach-Object {$_.FullName+':'+(Get-FileHash -LiteralPath $_.FullName).Hash}) -join '|')}
function Get-TlsTrustPreview {New-LabAuthenticatedTlsTrustImportPreview $dataRoot $controller $location $context $script:candidateId}
function Get-TlsTrustStatus {Get-LabAuthenticatedTlsTrustImportStatus $dataRoot $controller $location $context $script:candidateId}
function Invoke-TlsTrustImport {param($Approval) Invoke-LabAuthenticatedTlsTrustImport $dataRoot $controller $location $context $script:candidateId $Approval}
function Get-TlsTrustApproval {param($Preview) return [pscustomobject][ordered]@{ContractVersion='SqlServerLab.TlsTrustApproval/0.1';ApprovalId=[guid]::NewGuid().ToString('D');PreviewId=$Preview.Value.PreviewId;PreviewDigest=$Preview.Value.PreviewDigest;Decision='APPROVE_CURRENT_USER_ROOT_PUBLIC_DER'}}
function Reset-TlsTrustJournal {
    $path=[IO.Path]::GetFullPath($script:journalPaths.Base);$prefix=[IO.Path]::GetFullPath($fixtureRoot).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    if(-not $path.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($path) -cne 'trust-imports'){throw 'TLS_TRUST_FIXTURE_BOUNDARY'}
    if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path -Recurse -Force}
    $script:storeState='ABSENT';$script:addCalls=0
}
try{
    & {
        Set-StrictMode -Version Latest
        function Get-LabTlsTrustImportBinding {$script:ioCalls++;throw 'PRIVATE_CANARY'}
        $alien=[pscustomobject]@{};$alien|Add-Member ScriptMethod ToString {$script:alienCalls++;throw 'PRIVATE_CANARY'} -Force
        try{
            foreach($bad in @($null,12,$alien,@($controller),'',($controller+[char]0x200b))){
                Assert-TlsTrustClosed @(Invoke-LabAuthenticatedTlsTrustImport 'C:\synthetic' $bad $location $context $controller $null *>&1) 'TLS_TRUST_APPROVAL_INVALID'
                Assert-TlsTrustClosed @(New-LabAuthenticatedTlsTrustImportPreview 'C:\synthetic' $controller $location $context $bad *>&1) 'TLS_TRUST_PREVIEW_INVALID'
            }
            $shape=[pscustomobject]@{ContractVersion='SqlServerLab.TlsTrustApproval/0.1';ApprovalId=$controller;PreviewId=$location;PreviewDigest=('a'*64);Decision='APPROVE_CURRENT_USER_ROOT_PUBLIC_DER'}
            $scripted=$shape.PSObject.Copy();$scripted|Add-Member ScriptProperty Decision {$script:alienCalls++;throw 'PRIVATE_CANARY'} -Force
            foreach($bad in @($null,12,$alien,@($shape),$scripted)){
                Assert-TlsTrustClosed @(Invoke-LabAuthenticatedTlsTrustImport 'C:\synthetic' $controller $location $context $controller $bad *>&1) 'TLS_TRUST_APPROVAL_INVALID'
            }
            foreach($name in @('ContractVersion','ApprovalId','PreviewId','PreviewDigest','Decision')){
                foreach($value in @($null,$alien,@('wrong'),('wrong'+[char]0x200b))){$bad=$shape.PSObject.Copy();$bad.$name=$value
                    Assert-TlsTrustClosed @(Invoke-LabAuthenticatedTlsTrustImport 'C:\synthetic' $controller $location $context $controller $bad *>&1) 'TLS_TRUST_APPROVAL_INVALID'
                }
            }
            Add-CheckResult 'TLS-TI01 keine fremden Casts/Getter und kein I/O vor Formpruefung' ($script:alienCalls -eq 0 -and $script:ioCalls -eq 0)
        }finally{Set-Item function:Get-LabTlsTrustImportBinding $realBinding}
        if(-not [Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows) -or [Management.Automation.PSVersionInfo]::PSVersion -lt [version]'7.5'){
            Assert-TlsTrustClosed @(Get-TlsTrustPreview *>&1) 'TLS_TRUST_PREVIEW_INVALID'
            Write-Host 'TLS-TI Windows-Datei-/ACL-/Lockfixtures: NOT_EXECUTED; reale Storemutation: NOT_EXECUTED'
            return
        }
        $script:native=Get-LabTlsWindowsProcessFacts;$sid=$script:native.UserSid
        function Get-LabTlsWindowsProcessFacts {return $script:native}
        function Get-LabTlsCaStorageBase {param($Native) $null=$Native;return (Join-Path $fixtureRoot 'SQL_Server_Lab_AuthenticatedTls')}
        $null=New-Item -ItemType Directory -Path (Join-Path $dataRoot 'Catalog')
        $markerPath=Join-Path $dataRoot '.sql-server-lab-root.json';$catalogPath=Join-Path $dataRoot 'Catalog/storage-locations.json'
        $marker=[pscustomobject]@{ContractVersion='SqlServerLab.DataRoot/2.0';ManagedBy='SQL_Server_Lab';ControllerId=$controller;VolumeId='synthetic-volume';DataRoot=$dataRoot}
        Save-TlsTrustJson $markerPath $marker
        Save-TlsTrustJson $catalogPath ([pscustomobject]@{ContractVersion='SqlServerLab.Storage/2.0';ControllerId=$controller;LabDataLocations=@([pscustomobject]@{LocationId=$location;ControllerId=$controller;VolumeId='synthetic-volume';LabDataRoot=$dataRoot})})
        $candidate=New-LabAuthenticatedTlsCaCandidate $dataRoot $controller $location $context 30
        if(-not $candidate.Success){throw 'TLS_TRUST_FIXTURE_CA_FAILED'}
        $script:candidateId=$candidate.Value.CandidateId;$candidatePaths=Get-LabTlsCaCandidatePaths $script:native $controller $location $script:candidateId
        $candidateSnapshot=Get-TlsTrustSnapshot $candidatePaths.Candidate
        $script:publicDer=[IO.File]::ReadAllBytes((Join-Path $candidatePaths.Candidate 'ca.der'));$script:storeState='ABSENT'
        $nativeTrust=Get-LabTlsCaExistingTrust $script:publicDer
        function Get-LabTlsCaExistingTrust {param($Der)
            if(-not [string]::Equals((Get-LabTlsCaByteDigest $Der),(Get-LabTlsCaByteDigest $script:publicDer),[StringComparison]::Ordinal)){throw 'TLS_TRUST_WRONG_PUBLIC_BYTES'}
            return $script:storeState
        }
        function Add-LabTlsCurrentUserRootPublicCertificate {param($Der,$CandidateId,$ActorDigest,$ExpiresUtcTicks)
            if(-not (Test-LabTlsRequestEnum $CandidateId @($script:candidateId)) -or -not (Test-LabTlsRequestEnum $ActorDigest @((Get-LabTlsCaActorDigest $script:native))) -or
                -not (Test-LabTlsRequestEnum (Get-LabTlsCaByteDigest $Der) @((Get-LabTlsCaByteDigest $script:publicDer))) -or
                $ExpiresUtcTicks -isnot [long] -or $ExpiresUtcTicks -le [datetime]::UtcNow.Ticks){throw 'TLS_TRUST_WRONG_WRITE_BINDING'}
            if(-not (Test-Path -LiteralPath $script:journalPaths.Intent) -or (Test-Path -LiteralPath $script:journalPaths.Commit)){throw 'TLS_TRUST_INTENT_ORDER_INVALID'}
            $script:addCalls++;$script:storeState='IDENTICAL_PREEXISTING_NOT_OWNED';return 'ADD_RETURNED'
        }
        $realAddMock=${function:Add-LabTlsCurrentUserRootPublicCertificate}
        function Assert-LabTlsCaEncryptedKey {throw 'TLS_TRUST_IMPORT_MUST_NOT_OPEN_CA_KEY'}
        $binding=Get-LabTlsTrustImportBinding $dataRoot $controller $location $script:candidateId;$script:journalPaths=Get-LabTlsTrustJournalPath $binding
        Add-CheckResult 'TLS-TI02 lesender Status ohne Journalanlage' ((Get-TlsTrustStatus).Value.Status -ceq 'NO_TRANSACTION' -and -not (Test-Path -LiteralPath $script:journalPaths.Base))
        $preview=Get-TlsTrustPreview
        Add-CheckResult 'TLS-TI02 konkrete geschuetzte fuenfminuetige Preview ohne Storewrite' ($preview.Success -and $preview.Value.Prestate -ceq 'ABSENT' -and $preview.Value.Store -ceq 'CURRENT_USER_ROOT' -and
            $preview.Value.CertificateSha256 -ceq $candidate.Value.CertificateSha256 -and -not $preview.Value.MutationAllowed -and $script:addCalls -eq 0)
        if(-not $preview.Success){throw 'TLS_TRUST_FIXTURE_PREVIEW_FAILED'}
        $approval=Get-TlsTrustApproval $preview
        foreach($name in @('ApprovalId','PreviewId','PreviewDigest','Decision')){
            $bad=$approval.PSObject.Copy();$bad.$name=if($name -in @('ApprovalId','PreviewId')){[guid]::NewGuid().ToString('D')}elseif($name -eq 'PreviewDigest'){'b'*64}else{'REJECT'}
            if($name -eq 'ApprovalId'){continue} # Ein neues Audit-ApprovalId allein ersetzt keinen exakten Previewdigest.
            Assert-TlsTrustClosed @(Invoke-TlsTrustImport $bad *>&1) 'TLS_TRUST_APPROVAL_INVALID'
        }
        Add-CheckResult 'TLS-TI03 fremde Freigaben vor Intent und Add abgelehnt' ($script:addCalls -eq 0 -and -not (Test-Path -LiteralPath $script:journalPaths.Intent))
        $held=Enter-LabTlsTrustJournalLock $script:journalPaths.Lock $sid
        try{
            Assert-TlsTrustClosed @(Invoke-TlsTrustImport $approval *>&1) 'TLS_TRUST_JOURNAL_BUSY'
            Add-CheckResult 'TLS-TI04 konkurrierender lesender Status meldet BUSY' ((Get-TlsTrustStatus).Value.Status -ceq 'BUSY')
        }finally{$held.Dispose()}
        Add-CheckResult 'TLS-TI04 eigenes DeleteOnClose-Lock vollstaendig freigegeben' (-not (Test-Path -LiteralPath $script:journalPaths.Lock))
        $result=Invoke-TlsTrustImport $approval
        Add-CheckResult 'TLS-TI05 Intent vor injiziertem Add und vollstaendiger Commit' ($result.Success -and $result.Value.Status -ceq 'OWNED_IMPORT_RECORDED' -and
            $result.Value.RemovalAuthority -ceq 'NONE' -and $result.Value.StoreAtomicity -ceq 'COOPERATIVE_ONLY' -and $script:addCalls -eq 1 -and (Test-Path -LiteralPath $script:journalPaths.Intent) -and (Test-Path -LiteralPath $script:journalPaths.Commit))
        $snapshot=Get-TlsTrustSnapshot $script:journalPaths.Journal;$status=Get-TlsTrustStatus
        Add-CheckResult 'TLS-TI05 Status liest exakten Commit ohne Dateiaenderung' ($status.Success -and $status.Value.Status -ceq 'OWNED_IMPORT_RECORDED' -and [string]::Equals($snapshot,(Get-TlsTrustSnapshot $script:journalPaths.Journal),[StringComparison]::Ordinal))
        $repeat=Invoke-TlsTrustImport $approval
        Add-CheckResult 'TLS-TI05 identische Wiederholung ohne zweiten Storeversuch' ($repeat.Success -and $repeat.Value.Status -ceq 'OWNED_IMPORT_RECORDED' -and $script:addCalls -eq 1)
        $other=$approval.PSObject.Copy();$other.ApprovalId=[guid]::NewGuid().ToString('D');Assert-TlsTrustClosed @(Invoke-TlsTrustImport $other *>&1) 'TLS_TRUST_APPROVAL_INVALID'
        $script:storeState='ABSENT';Assert-TlsTrustClosed @(Get-TlsTrustStatus *>&1) 'TLS_TRUST_RECOVERY_REQUIRED'
        Reset-TlsTrustJournal;$script:storeState='IDENTICAL_PREEXISTING_NOT_OWNED';$pre=Get-TlsTrustPreview;$ap=Get-TlsTrustApproval $pre;$result=Invoke-TlsTrustImport $ap
        Add-CheckResult 'TLS-TI06 vorbestehender identischer Trust bleibt ohne Besitz/Intent/Add' ($result.Success -and $result.Value.Status -ceq 'PREEXISTING_NOT_OWNED' -and $script:addCalls -eq 0 -and -not (Test-Path -LiteralPath $script:journalPaths.Intent))
        Reset-TlsTrustJournal;$pre=Get-TlsTrustPreview;$ap=Get-TlsTrustApproval $pre
        function Add-LabTlsCurrentUserRootPublicCertificate {param($Der,$CandidateId,$ActorDigest,$ExpiresUtcTicks) $null=$Der;$null=$CandidateId;$null=$ActorDigest;$null=$ExpiresUtcTicks;$script:storeState='IDENTICAL_PREEXISTING_NOT_OWNED';return 'PREEXISTING_AT_WRITE_BOUNDARY'}
        try{$result=Invoke-TlsTrustImport $ap;Add-CheckResult 'TLS-TI06 am Writeboundary vorbestehend ergibt nur fremden Trustcommit' ($result.Success -and $result.Value.Status -ceq 'PREEXISTING_NOT_OWNED' -and $script:addCalls -eq 0 -and (Get-TlsTrustStatus).Value.Status -ceq 'PREEXISTING_NOT_OWNED')}
        finally{Set-Item function:Add-LabTlsCurrentUserRootPublicCertificate $realAddMock}
        foreach($fault in @('beforeAdd','afterAddBeforeCommit','intentReadback','commitAfterWrite')){
            Reset-TlsTrustJournal;$pre=Get-TlsTrustPreview;$ap=Get-TlsTrustApproval $pre;$script:fault=$fault
            function Add-LabTlsCurrentUserRootPublicCertificate {param($Der,$CandidateId,$ActorDigest,$ExpiresUtcTicks)
                if($script:fault -ceq 'beforeAdd'){throw 'PRIVATE_CANARY'}
                return & $realAddMock $Der $CandidateId $ActorDigest $ExpiresUtcTicks
            }
            function Write-LabTlsTrustJournalRecord {param($Path,$UserSid,$Record)
                $leaf=[IO.Path]::GetFileName($Path)
                if($script:fault -ceq 'afterAddBeforeCommit' -and $leaf -ceq 'commit.json'){throw 'PRIVATE_CANARY'}
                $digest=& $realWrite $Path $UserSid $Record
                if(($script:fault -ceq 'intentReadback' -and $leaf -ceq 'intent.json') -or ($script:fault -ceq 'commitAfterWrite' -and $leaf -ceq 'commit.json')){throw 'PRIVATE_CANARY'}
                return $digest
            }
            try{
                Assert-TlsTrustClosed @(Invoke-TlsTrustImport $ap *>&1) 'TLS_TRUST_RECOVERY_REQUIRED'
                $recovery=Get-TlsTrustStatus;$before=$script:addCalls
                if($fault -ceq 'commitAfterWrite'){
                    Add-CheckResult 'TLS-TI07 bestaetigtes persistiertes Commit ist lesend wieder auffindbar' ($recovery.Success -and $recovery.Value.Status -ceq 'OWNED_IMPORT_RECORDED')
                }else{
                    Add-CheckResult 'TLS-TI07 Intent-only bleibt sichtbar RECOVERY_REQUIRED' ($recovery.Success -and $recovery.Value.Status -ceq 'RECOVERY_REQUIRED')
                    Assert-TlsTrustClosed @(Invoke-TlsTrustImport $ap *>&1) 'TLS_TRUST_RECOVERY_REQUIRED'
                }
                Add-CheckResult 'TLS-TI07 keine blinde Add-Wiederholung oder automatische Loeschung' ($script:addCalls -eq $before -and (Test-Path -LiteralPath $script:journalPaths.Intent))
            }finally{Set-Item function:Add-LabTlsCurrentUserRootPublicCertificate $realAddMock;Set-Item function:Write-LabTlsTrustJournalRecord $realWrite}
        }
        Reset-TlsTrustJournal;$pre=Get-TlsTrustPreview;$ap=Get-TlsTrustApproval $pre
        $previewPath=Join-Path $script:journalPaths.Previews ($pre.Value.PreviewId+'.json');$record=[IO.File]::ReadAllText($previewPath)|ConvertFrom-Json
        $old=[datetime]::UtcNow.AddMinutes(-6);$record.IssuedUtcTicks=$old.Ticks.ToString([Globalization.CultureInfo]::InvariantCulture);$record.ExpiresUtcTicks=$old.AddMinutes(5).Ticks.ToString([Globalization.CultureInfo]::InvariantCulture)
        Save-TlsTrustJson $previewPath $record;$ap.PreviewDigest=Get-LabTlsTrustPreviewDigest $record
        Assert-TlsTrustClosed @(Invoke-TlsTrustImport $ap *>&1) 'TLS_TRUST_APPROVAL_INVALID'
        Add-CheckResult 'TLS-TI08 abgelaufene Preview auch mit passendem Digest vor Add gesperrt' ($script:addCalls -eq 0 -and -not (Test-Path -LiteralPath $script:journalPaths.Intent))
        Reset-TlsTrustJournal;$pre=Get-TlsTrustPreview;$ap=Get-TlsTrustApproval $pre
        $savedAcl=[IO.FileSystemAclExtensions]::GetAccessControl([IO.FileInfo]::new($script:journalPaths.Owner))
        $broad=Get-LabTlsCaSecurity $sid;$broad.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new('S-1-1-0'),[Security.AccessControl.FileSystemRights]::Read,[Security.AccessControl.AccessControlType]::Allow))
        [IO.FileSystemAclExtensions]::SetAccessControl([IO.FileInfo]::new($script:journalPaths.Owner),$broad)
        try{Assert-TlsTrustClosed @(Invoke-TlsTrustImport $ap *>&1) 'TLS_TRUST_RECOVERY_REQUIRED';Add-CheckResult 'TLS-TI08 breite Journal-ACL sperrt vor Storewrite' ($script:addCalls -eq 0)}
        finally{[IO.FileSystemAclExtensions]::SetAccessControl([IO.FileInfo]::new($script:journalPaths.Owner),$savedAcl)}
        Reset-TlsTrustJournal;$pre=Get-TlsTrustPreview;$ap=Get-TlsTrustApproval $pre
        $previewOriginal=$script:journalPaths.Previews;$previewMoved=Join-Path $script:journalPaths.Journal 'previews-own-fixture'
        foreach($movePath in @($previewOriginal,$previewMoved)){
            if(-not [IO.Path]::GetFullPath($movePath).StartsWith([IO.Path]::GetFullPath($fixtureRoot).TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'TLS_TRUST_FIXTURE_MOVE_BOUNDARY'}
        }
        Move-Item -LiteralPath $previewOriginal -Destination $previewMoved
        $null=New-Item -ItemType Junction -Path $previewOriginal -Target $previewMoved
        try{Assert-TlsTrustClosed @(Invoke-TlsTrustImport $ap *>&1) 'TLS_TRUST_RECOVERY_REQUIRED';Add-CheckResult 'TLS-TI08 Journal-Reparse sperrt vor Storewrite' ($script:addCalls -eq 0)}
        finally{Remove-Item -LiteralPath $previewOriginal -Force;Move-Item -LiteralPath $previewMoved -Destination $previewOriginal}
        Reset-TlsTrustJournal;$pre=Get-TlsTrustPreview;$ap=Get-TlsTrustApproval $pre;$script:bindingCalls=0
        function Get-LabTlsTrustImportBinding {param($DataRoot,$ControllerId,$LocationId,$CandidateId)
            $script:bindingCalls++;$value=& $realBinding $DataRoot $ControllerId $LocationId $CandidateId
            if($script:bindingCalls -eq 2){$value.Digest='b'*64}
            return $value
        }
        try{Assert-TlsTrustClosed @(Invoke-TlsTrustImport $ap *>&1) 'TLS_TRUST_RECOVERY_REQUIRED';Add-CheckResult 'TLS-TI08 Drift nach Intent blockiert Add und bleibt Recovery' ($script:addCalls -eq 0 -and (Test-Path -LiteralPath $script:journalPaths.Intent))}
        finally{Set-Item function:Get-LabTlsTrustImportBinding $realBinding}
        foreach($drift in @('root','actor','bytes')){
            Reset-TlsTrustJournal;$pre=Get-TlsTrustPreview;$ap=Get-TlsTrustApproval $pre
            $oldMarker=[IO.File]::ReadAllText($markerPath);$oldActor=$script:native.HostMarker;$derPath=Join-Path $candidatePaths.Candidate 'ca.der'
            switch($drift){root {$marker.VolumeId='changed';Save-TlsTrustJson $markerPath $marker} actor {$script:native.HostMarker=[guid]::NewGuid().ToString('D')} bytes {[IO.File]::WriteAllBytes($derPath,[byte[]]@(1,2,3))}}
            try{Assert-TlsTrustClosed @(Invoke-TlsTrustImport $ap *>&1) 'TLS_TRUST_APPROVAL_INVALID';Add-CheckResult 'TLS-TI08 Root/Actor/DER-Drift sperrt vor Storewrite' ($script:addCalls -eq 0)}
            finally{[IO.File]::WriteAllText($markerPath,$oldMarker);$marker.VolumeId='synthetic-volume';$script:native.HostMarker=$oldActor;[IO.File]::WriteAllBytes($derPath,$script:publicDer)}
        }
        Reset-TlsTrustJournal;$pre=Get-TlsTrustPreview;$ap=Get-TlsTrustApproval $pre;$null=Invoke-TlsTrustImport $ap
        $commitText=[IO.File]::ReadAllText($script:journalPaths.Commit);[IO.File]::WriteAllText($script:journalPaths.Commit,$commitText.Replace('OWNED_IMPORT_RECORDED',('OWNED_IMPORT_RECORDED'+[char]0x200b)))
        Assert-TlsTrustClosed @(Get-TlsTrustStatus *>&1) 'TLS_TRUST_RECOVERY_REQUIRED'
        Assert-TlsTrustClosed @(Invoke-TlsTrustImport $ap *>&1) 'TLS_TRUST_RECOVERY_REQUIRED'
        Add-CheckResult 'TLS-TI09 Kandidatenbytes bleiben unveraendert; kein privater Key geoeffnet' ([string]::Equals($candidateSnapshot,(Get-TlsTrustSnapshot $candidatePaths.Candidate),[StringComparison]::Ordinal))
        $null=$nativeTrust
    }
    $err=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'Private/AuthenticatedTlsTrustImport.ps1'),[ref]$null,[ref]$err)
    Add-CheckResult 'TLS-TI10 Laden definiert nur Funktionen' ($err.Count -eq 0 -and @($ast.EndBlock.Statements|Where-Object {$_ -isnot [Management.Automation.Language.FunctionDefinitionAst]}).Count -eq 0)
    $text=$ast.Extent.Text
    Add-CheckResult 'TLS-TI10 keine Key-/Removal-/SQL-/Provider-/C#-Aktion' ($text -notmatch '(?i)Unprotect|ExportPkcs|ImportPkcs|Add-Type|Remove-Item|\.Remove\(|Invoke-Sqlcmd|Start-Process|StoreLocation\]::LocalMachine')
    Add-CheckResult 'TLS-TI10 keine kulturabhaengige Stringgleichheit' (@($ast.FindAll({param($n) $n -is [Management.Automation.Language.BinaryExpressionAst] -and $n.Operator.ToString() -in @('Ceq','Cne','Cin','Cnotin')},$true)).Count -eq 0)
    Write-Host "Authenticated TLS Trust Import: $passed PASS, $($failures.Count) FAIL; native Rootstoremutation NOT_EXECUTED"
    if($failures.Count){throw 'AUTHENTICATED_TLS_TRUST_IMPORT_CHECKS_FAILED'}
}finally{
    $full=[IO.Path]::GetFullPath($fixtureRoot);$prefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    if(-not $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -cnotmatch '\Asql-lab-tls-import-[a-f0-9]{32}\z'){throw 'TLS_TRUST_FIXTURE_CLEANUP_BOUNDARY'}
    if(Test-Path -LiteralPath $full){Remove-Item -LiteralPath $full -Recurse -Force}
    if(Test-Path -LiteralPath $full){throw 'TLS_TRUST_FIXTURE_CLEANUP_FAILED'}
    Write-Host 'TLS-TI eigene private Datei-/ACL-/Lockfixtures: CLEANED'
}
