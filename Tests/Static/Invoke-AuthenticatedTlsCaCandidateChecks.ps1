#Requires -Version 7.2
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$repo=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
. (Join-Path $PSScriptRoot '../Common/CheckResult.ps1')
foreach($name in @('DiagnosticBundleReader','AuthenticatedTlsRequest','AuthenticatedTlsRegistryPayload','AuthenticatedTlsRegistryRoot','AuthenticatedTlsContext','AuthenticatedTlsCaCandidate')){. (Join-Path $repo "Private/$name.ps1")}
$passed=0;$failures=[Collections.Generic.List[string]]::new()
$fixtureRoot=Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-tls-ca-'+[guid]::NewGuid().ToString('N'))
$controller='11111111-1111-4111-8111-111111111111';$location='22222222-2222-4222-8222-222222222222'
$dataRoot=Join-Path $fixtureRoot 'root';$context='CURRENT_WINDOWS_PROCESS'
function Invoke-TlsCaFixtureCandidate { New-LabAuthenticatedTlsCaCandidate $dataRoot $controller $location $context 30 }
function Get-TlsCaFixturePreview {param($Id) Get-LabAuthenticatedTlsCaTrustPreview $dataRoot $controller $location $context $Id}
function Assert-TlsCaClosed {param([object[]]$Result,[string]$Code)
    Add-CheckResult 'TLS-CA01 geschlossener Fehler ohne private Rohdaten' ($Result.Count -eq 1 -and @($Result[0].PSObject.Properties).Count -eq 3 -and -not $Result[0].Success -and $null -eq $Result[0].Value -and $Result[0].ErrorCode -ceq $Code)
}
function Test-TlsCaThrows {param([scriptblock]$Action) try{$null=& $Action;return $false}catch{return $true}}
function Save-TlsCaJson {param($Path,$Value) [IO.File]::WriteAllText($Path,($Value|ConvertTo-Json -Depth 8 -Compress))}
function Get-TlsCaFixtureSnapshot {return (@(Get-ChildItem -LiteralPath $fixtureRoot -File -Recurse|Sort-Object FullName|ForEach-Object {$_.FullName+':'+(Get-FileHash -LiteralPath $_.FullName).Hash}) -join '|')}
try{
    & {
        Set-StrictMode -Version Latest
        $realFacts=${function:Get-LabTlsWindowsProcessFacts};$realStorage=${function:Get-LabTlsCaStorageBase}
        $realRoot=${function:Get-LabAuthenticatedTlsRootMetadata};$realCapability=${function:Assert-LabTlsCaCandidateCapability}
        $script:ioCalls=0;$script:alienCalls=0
        function Get-LabAuthenticatedTlsRootMetadata {$script:ioCalls++;throw 'PRIVATE_CANARY'}
        function Get-LabTlsWindowsProcessFacts {$script:ioCalls++;throw 'PRIVATE_CANARY'}
        $alien=[pscustomobject]@{};$alien|Add-Member ScriptMethod ToString {$script:alienCalls++;throw 'PRIVATE_CANARY'} -Force
        try{
            foreach($bad in @($null,12,@($controller),$alien,'',[guid]$controller)){
                Assert-TlsCaClosed @(New-LabAuthenticatedTlsCaCandidate 'C:\synthetic' $bad $location $context 30 *>&1) 'TLS_CA_CANDIDATE_INVALID'
                Assert-TlsCaClosed @(Get-LabAuthenticatedTlsCaTrustPreview 'C:\synthetic' $controller $location $context $bad *>&1) 'TLS_CA_TRUST_PREVIEW_INVALID'
            }
            foreach($bad in @($null,'30',1,366,[long]30,@(30),$alien)){
                Assert-TlsCaClosed @(New-LabAuthenticatedTlsCaCandidate 'C:\synthetic' $controller $location $context $bad *>&1) 'TLS_CA_CANDIDATE_INVALID'
            }
            foreach($bad in @($null,'CURRENT_PROCESS','current_windows_process',@($context),$alien)){
                Assert-TlsCaClosed @(New-LabAuthenticatedTlsCaCandidate 'C:\synthetic' $controller $location $bad 30 *>&1) 'TLS_CA_CANDIDATE_INVALID'
            }
            foreach($bad in @($null,12,@('C:\synthetic'),$alien,('x'*4097))){
                Assert-TlsCaClosed @(New-LabAuthenticatedTlsCaCandidate $bad $controller $location $context 30 *>&1) 'TLS_CA_CANDIDATE_INVALID'
            }
            Add-CheckResult 'TLS-CA01 fremde Casts/Getter und I/O vor Formpruefung gesperrt' ($script:ioCalls -eq 0 -and $script:alienCalls -eq 0)
            function Assert-LabTlsCaCandidateCapability {throw 'TLS_CA_CANDIDATE_NOT_SUPPORTED'}
            Assert-TlsCaClosed @(New-LabAuthenticatedTlsCaCandidate 'C:\synthetic' $controller $location $context 30 *>&1) 'TLS_CA_CANDIDATE_NOT_SUPPORTED'
            Assert-TlsCaClosed @(Get-LabAuthenticatedTlsCaTrustPreview 'C:\synthetic' $controller $location $context $controller *>&1) 'TLS_CA_CANDIDATE_NOT_SUPPORTED'
            Add-CheckResult 'TLS-CA01 fehlende Windows-/Spanfaehigkeit blockiert vor I/O' ($script:ioCalls -eq 0)
        }finally{Set-Item function:Get-LabAuthenticatedTlsRootMetadata $realRoot;Set-Item function:Get-LabTlsWindowsProcessFacts $realFacts;Set-Item function:Assert-LabTlsCaCandidateCapability $realCapability}
        if(-not [Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows) -or $PSVersionTable.PSVersion -lt [version]'7.5'){
            Assert-TlsCaClosed @(Invoke-TlsCaFixtureCandidate *>&1) 'TLS_CA_CANDIDATE_NOT_SUPPORTED'
            Write-Host 'TLS-CA Windows-DPAPI-/ACL-/Kryptofaelle: NOT_EXECUTED; Plattform oder Engine nicht unterstuetzt'
            return
        }
        $native=& $realFacts;$sid=$native.UserSid
        $actualBase=& $realStorage $native
        Add-CheckResult 'TLS-CA02 fixer eigener LocalApplicationData-Namespace ohne Callerpfad' ($actualBase.EndsWith('\SQL_Server_Lab_AuthenticatedTls',[StringComparison]::Ordinal) -and $actualBase.StartsWith($native.ProfilePath+'\',[StringComparison]::OrdinalIgnoreCase))
        $null=New-Item -ItemType Directory -Path (Join-Path $dataRoot 'Catalog')
        $markerPath=Join-Path $dataRoot '.sql-server-lab-root.json';$catalogPath=Join-Path $dataRoot 'Catalog/storage-locations.json'
        $marker=[pscustomobject]@{ContractVersion='SqlServerLab.DataRoot/2.0';ManagedBy='SQL_Server_Lab';ControllerId=$controller;VolumeId='synthetic-volume';DataRoot=$dataRoot}
        $catalog=[pscustomobject]@{ContractVersion='SqlServerLab.Storage/2.0';ControllerId=$controller;LabDataLocations=@([pscustomobject]@{LocationId=$location;ControllerId=$controller;VolumeId='synthetic-volume';LabDataRoot=$dataRoot})}
        Save-TlsCaJson $markerPath $marker;Save-TlsCaJson $catalogPath $catalog
        $genericProject=Join-Path $fixtureRoot 'SQL_Server_Lab';$null=New-Item -ItemType Directory -Path $genericProject
        $genericFile=Join-Path $genericProject 'synthetic-foreign-owner.txt';[IO.File]::WriteAllText($genericFile,'synthetic unrelated project bytes')
        $genericAcl=[IO.FileSystemAclExtensions]::GetAccessControl([IO.DirectoryInfo]::new($genericProject)).GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]'Access, Owner, Group')
        $genericHash=(Get-FileHash -LiteralPath $genericFile).Hash
        function Get-LabTlsCaStorageBase {param($Native) $null=$Native;return (Join-Path $fixtureRoot 'SQL_Server_Lab_AuthenticatedTls')}
        $script:facts=$native
        function Get-LabTlsWindowsProcessFacts {return $script:facts}
        $metadata=Get-LabAuthenticatedTlsRootMetadata $dataRoot $controller $location
        Add-CheckResult 'TLS-CA02 registrierte Metadaten ohne erfundene Registrydatei' ($metadata.Success -and -not (Test-Path -LiteralPath (Join-Path $dataRoot 'State/authenticated-tls/registry.json')))
        foreach($unsafe in @('relative','C:','\\synthetic\share','C:\lab\..\other','C:\lab:stream','C:\lab.','C:\lab ','C:\lab\*')){
            Assert-TlsCaClosed @(New-LabAuthenticatedTlsCaCandidate $unsafe $controller $location $context 30 *>&1) 'TLS_CA_CANDIDATE_INVALID'
        }
        $decorated=[string]::Concat($dataRoot);$decorated|Add-Member ScriptMethod Substring {$script:alienCalls++;throw 'PRIVATE_CANARY'} -Force
        $decorated|Add-Member ScriptProperty Length {$script:alienCalls++;throw 'PRIVATE_CANARY'} -Force
        $candidate=New-LabAuthenticatedTlsCaCandidate $decorated $controller $location $context 365
        Add-CheckResult 'TLS-CA03 native eigene CA mit verschluesseltem PKCS8 und Reopen/Sign/Verify' ($candidate.Success -and $candidate.Value.Status -ceq 'UNREGISTERED_UNQUALIFIED' -and
            $candidate.Value.KeyProtection -ceq 'DPAPI_CURRENT_USER_PKCS8' -and $candidate.Value.KeyMatchStatus -ceq 'REOPEN_SIGN_VERIFY' -and -not $candidate.Value.Ready -and -not $candidate.Value.MutationAllowed -and $script:alienCalls -eq 0)
        if(-not $candidate.Success){throw 'TLS_CA_FIXTURE_CREATION_FAILED'}
        $id=$candidate.Value.CandidateId;$paths=Get-LabTlsCaCandidatePaths $native $controller $location $id
        $receiptPath=Join-Path $paths.Candidate 'receipt.json';$derPath=Join-Path $paths.Candidate 'ca.der';$keyPath=Join-Path $paths.Candidate 'key.dpapi'
        $der=[IO.File]::ReadAllBytes($derPath);$encrypted=[IO.File]::ReadAllBytes($keyPath)
        $receipt=[IO.File]::ReadAllText($receiptPath)|ConvertFrom-Json -DateKind String
        Add-CheckResult 'TLS-CA03 hoechstens 365 Tage inklusive Backdating' (([datetime]$receipt.NotAfterUtc-[datetime]$receipt.NotBeforeUtc).TotalDays -eq 365)
        Add-CheckResult 'TLS-CA03 nur Ciphertext/DER/geschlossene Metadaten persistiert' (@(Get-ChildItem -LiteralPath $paths.Candidate -File).Count -eq 4 -and $encrypted.Length -gt 1792 -and
            [Text.Encoding]::ASCII.GetString($encrypted) -notmatch 'PRIVATE KEY' -and $receipt.EncryptedKeySha256 -ceq (Get-LabTlsCaByteDigest $encrypted))
        Add-CheckResult 'TLS-CA03 fremdes vorhandenes Kandidatenverzeichnis wird nicht adoptiert' (Test-TlsCaThrows {Initialize-LabTlsCaPrivateDirectory $paths.Candidate $sid -NewOnly})
        Add-CheckResult 'TLS-CA03 CreateNew ueberschreibt keine bestehenden Bytes' (Test-TlsCaThrows {Write-LabTlsCaPrivateFile $keyPath $sid ([byte[]]@(1,2,3))})
        $snapshot=Get-TlsCaFixtureSnapshot;$preview=Get-TlsCaFixturePreview $id
        Add-CheckResult 'TLS-CA04 echte ReadOnly-Storevorschau ohne SQL-/TLS-Qualifikation' ($preview.Success -and $preview.Value.Store -ceq 'CURRENT_USER_ROOT' -and $preview.Value.UserSid -ceq $sid -and
            $preview.Value.CertificateSha256 -ceq $candidate.Value.CertificateSha256 -and $preview.Value.PreexistingTrust -ceq 'ABSENT' -and $preview.Value.TlsStatus -ceq 'NOT_EXECUTED' -and -not $preview.Value.Ready -and -not $preview.Value.MutationAllowed)
        Add-CheckResult 'TLS-CA04 Vorschau schreibt keine Datei' ($snapshot -ceq (Get-TlsCaFixtureSnapshot))
        $receiptText=[IO.File]::ReadAllText($receiptPath)
        $originalCulture=[Globalization.CultureInfo]::CurrentCulture;$originalUiCulture=[Globalization.CultureInfo]::CurrentUICulture
        $receiptNames=@('ContractVersion','CandidateId','ControllerId','LocationId','RootMetadataDigest','ActorDigest','CertificateSha256','EncryptedKeySha256','NotBeforeUtc','NotAfterUtc','Status')
        $unicodeCertificates=@{};$probeRsa=$null;$probePlain=$null
        try{
            $candidateEntropy=[Text.Encoding]::UTF8.GetBytes((Get-LabTlsPayloadDigest @('SqlServerLab.TlsCaCandidateKey/0.1',$id,$controller,$location,$metadata.Value.RootMetadataDigest,(Get-LabTlsCaActorDigest $native))))
            $probePlain=[Security.Cryptography.ProtectedData]::Unprotect($encrypted,$candidateEntropy,[Security.Cryptography.DataProtectionScope]::CurrentUser)
            $probeRsa=[Security.Cryptography.RSA]::Create();$probeConsumed=0;$probeRsa.ImportPkcs8PrivateKey($probePlain,[ref]$probeConsumed)
            foreach($codepoint in @(0x200b,0x00ad)){
                $probeRequest=[Security.Cryptography.X509Certificates.CertificateRequest]::new(('CN=SQL_Server_Lab Candidate '+$id+[char]$codepoint),$probeRsa,[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pkcs1)
                $probeRequest.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new($true,$true,0,$true))
                $probeRequest.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509KeyUsageExtension]::new([Security.Cryptography.X509Certificates.X509KeyUsageFlags]'KeyCertSign, CrlSign',$true))
                $probeCert=$probeRequest.CreateSelfSigned([DateTimeOffset]::UtcNow.AddMinutes(-5),[DateTimeOffset]::UtcNow.AddDays(29))
                try{$unicodeCertificates.Add($codepoint,$probeCert.Export([Security.Cryptography.X509Certificates.X509ContentType]::Cert))}finally{$probeCert.Dispose()}
            }
            foreach($culture in @('en-US','de-DE','tr-TR')){
                [Globalization.CultureInfo]::CurrentCulture=[Globalization.CultureInfo]::GetCultureInfo($culture)
                [Globalization.CultureInfo]::CurrentUICulture=[Globalization.CultureInfo]::GetCultureInfo($culture)
                Add-CheckResult "TLS-CA09 unveraenderte Preview unter $culture" (Get-TlsCaFixturePreview $id).Success
                foreach($codepoint in @(0x200b,0x00ad)){
                    foreach($name in $receiptNames){
                        $original=$receipt.$name;$receipt.$name=$original+[char]$codepoint;Save-TlsCaJson $receiptPath $receipt
                        $altered=@(Get-TlsCaFixturePreview $id *>&1)
                        Add-CheckResult "TLS-CA09 Receiptwert $name U+$('{0:X4}' -f $codepoint) unter $culture" ($altered.Count -eq 1 -and -not $altered[0].Success -and $null -eq $altered[0].Value -and [string]::Equals($altered[0].ErrorCode,'TLS_CA_TRUST_PREVIEW_INVALID',[StringComparison]::Ordinal))
                        $receipt.$name=$original;[IO.File]::WriteAllText($receiptPath,$receiptText)
                        $keyAlias=$receiptText.Replace(('"'+$name+'":'),('"'+$name+[char]$codepoint+'":'))
                        Add-CheckResult "TLS-CA09 Metadataschluessel $name U+$('{0:X4}' -f $codepoint) unter $culture" (Test-TlsCaThrows {Read-LabTlsCaMetadata ([Text.Encoding]::UTF8.GetBytes($keyAlias)) $receiptNames})
                    }
                    Add-CheckResult "TLS-CA09 Zertifikatsubject U+$('{0:X4}' -f $codepoint) unter $culture" (Test-TlsCaThrows {Assert-LabTlsCaCertificate $unicodeCertificates[$codepoint] $id})
                }
            }
        }finally{
            [Globalization.CultureInfo]::CurrentCulture=$originalCulture;[Globalization.CultureInfo]::CurrentUICulture=$originalUiCulture
            [IO.File]::WriteAllText($receiptPath,$receiptText)
            if($null -ne $probePlain){[Array]::Clear($probePlain,0,$probePlain.Length)};if($null -ne $probeRsa){$probeRsa.Dispose()}
        }
        foreach($badText in @($receiptText.Replace('"CandidateId":','"candidateId":'),$receiptText.Replace('"Status":','"Status":"duplicate","Status":'),$receiptText.Replace('"Status":"UNREGISTERED_UNQUALIFIED"','"Status":{}'),$receiptText.Replace('"Status":"UNREGISTERED_UNQUALIFIED"','"Status":[]'),$receiptText.Replace('"Status":"UNREGISTERED_UNQUALIFIED"','"Status":123'),$receiptText.Replace('"Status":"UNREGISTERED_UNQUALIFIED"','"Status":"UNREGISTERED_UNQUALIFIED","Extra":"forbidden"'))){
            [IO.File]::WriteAllText($receiptPath,$badText);Assert-TlsCaClosed @(Get-TlsCaFixturePreview $id *>&1) 'TLS_CA_TRUST_PREVIEW_INVALID'
        }
        [IO.File]::WriteAllText($receiptPath,$receiptText)
        $intentPath=Join-Path $paths.Candidate 'intent.json';$intentText=[IO.File]::ReadAllText($intentPath)
        [IO.File]::WriteAllText($intentPath,$intentText.Replace('OWNED_PARTIAL_RECOVERY_REQUIRED','foreign'))
        Assert-TlsCaClosed @(Get-TlsCaFixturePreview $id *>&1) 'TLS_CA_TRUST_PREVIEW_INVALID';[IO.File]::WriteAllText($intentPath,$intentText)
        $foreignPath=Join-Path $paths.Candidate 'foreign.bin';[IO.File]::WriteAllBytes($foreignPath,[byte[]]@(1))
        Assert-TlsCaClosed @(Get-TlsCaFixturePreview $id *>&1) 'TLS_CA_TRUST_PREVIEW_INVALID';Remove-Item -LiteralPath $foreignPath
        $keyCheck=${function:Assert-LabTlsCaEncryptedKey};$trustRead=${function:Get-LabTlsCaExistingTrust}
        function Assert-LabTlsCaEncryptedKey {throw 'PREVIEW_MUST_NOT_OPEN_KEY'}
        function Get-LabTlsCaExistingTrust {param($Der) $null=$Der;return 'IDENTICAL_PREEXISTING_NOT_OWNED'}
        try{$pre=Get-TlsCaFixturePreview $id;Add-CheckResult 'TLS-CA04 vorbestehender Trust ist nie eigenes Cleanup; kein Keyoeffnen' ($pre.Success -and $pre.Value.PreexistingTrust -ceq 'IDENTICAL_PREEXISTING_NOT_OWNED' -and $pre.Value.CleanupOwnership -ceq 'PREEXISTING_TRUST_NEVER_OWNED')}
        finally{Set-Item function:Assert-LabTlsCaEncryptedKey $keyCheck;Set-Item function:Get-LabTlsCaExistingTrust $trustRead}
        foreach($name in @('CandidateId','ControllerId','LocationId','RootMetadataDigest','ActorDigest','CertificateSha256','EncryptedKeySha256','NotBeforeUtc','NotAfterUtc','Status','ContractVersion')){
            $original=$receipt.$name;$receipt.$name='synthetic-drift';Save-TlsCaJson $receiptPath $receipt
            Assert-TlsCaClosed @(Get-TlsCaFixturePreview $id *>&1) 'TLS_CA_TRUST_PREVIEW_INVALID'
            $receipt.$name=$original;Save-TlsCaJson $receiptPath $receipt
        }
        foreach($field in @('UserSid','HostMarker','ProfilePath')){
            $original=$script:facts.$field;$script:facts.$field='synthetic-drift'
            Assert-TlsCaClosed @(Get-TlsCaFixturePreview $id *>&1) 'TLS_CA_TRUST_PREVIEW_INVALID'
            $script:facts.$field=$original
        }
        $marker.VolumeId='synthetic-drift';Save-TlsCaJson $markerPath $marker
        Assert-TlsCaClosed @(Get-TlsCaFixturePreview $id *>&1) 'TLS_CA_TRUST_PREVIEW_INVALID'
        $marker.VolumeId='synthetic-volume';Save-TlsCaJson $markerPath $marker
        $script:factCalls=0
        function Get-LabTlsWindowsProcessFacts {
            $script:factCalls++;$copy=$script:facts.PSObject.Copy()
            if($script:factCalls -eq 2){$copy.HostMarker='synthetic-drift'}
            return $copy
        }
        try{Assert-TlsCaClosed @(Get-TlsCaFixturePreview $id *>&1) 'TLS_CA_TRUST_PREVIEW_INVALID'}
        finally{function Get-LabTlsWindowsProcessFacts {return $script:facts}}
        foreach($badDer in @([byte[]]@(),[byte[]]$der[0..($der.Length-2)],[byte[]]($der+[byte]0))){
            Add-CheckResult 'TLS-CA05 DER-Leere/Trunkierung/Trailingbytes gesperrt' (Test-TlsCaThrows {Assert-LabTlsCaCertificate $badDer $id})
        }
        $broken=[byte[]]$der.Clone();$broken[$broken.Length-1]=$broken[$broken.Length-1] -bxor 1
        Add-CheckResult 'TLS-CA05 echte Zertifikatsselbstsignatur geprueft' (Test-TlsCaThrows {Assert-LabTlsCaCertificate $broken $id})
        Add-CheckResult 'TLS-CA05 andere Kandidatenidentitaet gesperrt' (Test-TlsCaThrows {Assert-LabTlsCaCertificate $der $controller})
        [IO.File]::WriteAllBytes($derPath,$broken);Assert-TlsCaClosed @(Get-TlsCaFixturePreview $id *>&1) 'TLS_CA_TRUST_PREVIEW_INVALID';[IO.File]::WriteAllBytes($derPath,$der)
        [IO.File]::WriteAllBytes($keyPath,[byte[]]@(1,2,3));Assert-TlsCaClosed @(Get-TlsCaFixturePreview $id *>&1) 'TLS_CA_TRUST_PREVIEW_INVALID';[IO.File]::WriteAllBytes($keyPath,$encrypted)
        $entropy=[Text.Encoding]::UTF8.GetBytes((Get-LabTlsPayloadDigest @('SqlServerLab.TlsCaCandidateKey/0.1',$id,$controller,$location,$metadata.Value.RootMetadataDigest,(Get-LabTlsCaActorDigest $native))))
        Add-CheckResult 'TLS-CA05 falsche Purpose-/Identitaetsbindung verhindert Entschluesselung' (Test-TlsCaThrows {Assert-LabTlsCaEncryptedKey $encrypted ([byte[]]@(1,2,3)) $der})
        Add-CheckResult 'TLS-CA05 defekter Ciphertext verhindert Wiedereroeffnung' (Test-TlsCaThrows {Assert-LabTlsCaEncryptedKey ([byte[]]@(1,2,3)) $entropy $der})
        $second=Invoke-TlsCaFixtureCandidate
        Add-CheckResult 'TLS-CA05 neue Kandidaten besitzen eindeutige IDs' ($second.Success -and $second.Value.CandidateId -cne $id)
        $secondPaths=Get-LabTlsCaCandidatePaths $native $controller $location $second.Value.CandidateId
        $secondDer=[IO.File]::ReadAllBytes((Join-Path $secondPaths.Candidate 'ca.der'))
        Add-CheckResult 'TLS-CA05 echter Key/Zertifikat-Mismatch gesperrt' (Test-TlsCaThrows {Assert-LabTlsCaEncryptedKey $encrypted $entropy $secondDer})
        $plain=$null;$withTrailing=$null
        try{
            $plain=[Security.Cryptography.ProtectedData]::Unprotect($encrypted,$entropy,[Security.Cryptography.DataProtectionScope]::CurrentUser)
            $withTrailing=[byte[]]($plain+[byte]0);$badKey=[Security.Cryptography.ProtectedData]::Protect($withTrailing,$entropy,[Security.Cryptography.DataProtectionScope]::CurrentUser)
            Add-CheckResult 'TLS-CA05 vollstaendiger PKCS8-Verbrauch erforderlich' (Test-TlsCaThrows {Assert-LabTlsCaEncryptedKey $badKey $entropy $der})
        }finally{foreach($buffer in @($plain,$withTrailing)){if($null -ne $buffer){[Array]::Clear($buffer,0,$buffer.Length)}}}
        $savedAcl=[IO.FileSystemAclExtensions]::GetAccessControl([IO.FileInfo]::new($keyPath))
        $broad=Get-LabTlsCaSecurity $sid;$broad.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new('S-1-1-0'),[Security.AccessControl.FileSystemRights]::Read,[Security.AccessControl.AccessControlType]::Allow))
        [IO.FileSystemAclExtensions]::SetAccessControl([IO.FileInfo]::new($keyPath),$broad)
        Assert-TlsCaClosed @(Get-TlsCaFixturePreview $id *>&1) 'TLS_CA_TRUST_PREVIEW_INVALID'
        [IO.FileSystemAclExtensions]::SetAccessControl([IO.FileInfo]::new($keyPath),$savedAcl)
        $savedDirAcl=[IO.FileSystemAclExtensions]::GetAccessControl([IO.DirectoryInfo]::new($paths.Candidate))
        $broadDir=Get-LabTlsCaSecurity $sid -Directory;$broadDir.SetAccessRuleProtection($false,$false)
        [IO.FileSystemAclExtensions]::SetAccessControl([IO.DirectoryInfo]::new($paths.Candidate),$broadDir)
        Assert-TlsCaClosed @(Get-TlsCaFixturePreview $id *>&1) 'TLS_CA_TRUST_PREVIEW_INVALID'
        [IO.FileSystemAclExtensions]::SetAccessControl([IO.DirectoryInfo]::new($paths.Candidate),$savedDirAcl)
        $link=Join-Path $fixtureRoot 'junction';$null=New-Item -ItemType Junction -Path $link -Target $paths.Candidate
        try{Add-CheckResult 'TLS-CA06 Reparsepfad vor Key-I/O gesperrt' (Test-TlsCaThrows {Read-LabTlsCaPrivateFile (Join-Path $link 'key.dpapi') $sid 16384})}
        finally{Remove-Item -LiteralPath $link -Force}
        $realWrite=${function:Write-LabTlsCaPrivateFile};$script:writeCalls=0
        function Write-LabTlsCaPrivateFile {param($Path,$UserSid,$Bytes) $script:writeCalls++;if($script:writeCalls -eq 2){throw 'PRIVATE_PARTIAL_CANARY'};& $realWrite $Path $UserSid $Bytes}
        try{
            Assert-TlsCaClosed @(Invoke-TlsCaFixtureCandidate *>&1) 'TLS_CA_CANDIDATE_RECOVERY_REQUIRED'
            Add-CheckResult 'TLS-CA06 eigener Teilzustand bleibt mit explizitem Recoverybedarf' (@(Get-ChildItem -LiteralPath $paths.Location -Directory|Where-Object {-not (Test-Path -LiteralPath (Join-Path $_.FullName 'receipt.json'))}).Count -eq 1)
        }finally{Set-Item function:Write-LabTlsCaPrivateFile $realWrite}
        $script:rootReads=0
        function Get-LabAuthenticatedTlsRootMetadata {param($DataRoot,$ControllerId,$LocationId)
            $script:rootReads++;$value=& $realRoot $DataRoot $ControllerId $LocationId
            if($script:rootReads -eq 2){$value.Value.RootMetadataDigest='synthetic-drift'}
            return $value
        }
        try{Assert-TlsCaClosed @(Invoke-TlsCaFixtureCandidate *>&1) 'TLS_CA_CANDIDATE_RECOVERY_REQUIRED'}
        finally{Set-Item function:Get-LabAuthenticatedTlsRootMetadata $realRoot}
        # Storevergleich wird nur lesend auch an einem vorhandenen oeffentlichen Anker geprueft.
        $store=[Security.Cryptography.X509Certificates.X509Store]::new([Security.Cryptography.X509Certificates.StoreName]::Root,[Security.Cryptography.X509Certificates.StoreLocation]::CurrentUser)
        try{
            $store.Open([Security.Cryptography.X509Certificates.OpenFlags]'ReadOnly, OpenExistingOnly');$existing=$store.Certificates
            try{if($existing.Count){Add-CheckResult 'TLS-CA04 exakte vorhandene Publicbytes werden als fremder Trust erkannt' ((Get-LabTlsCaExistingTrust $existing[0].RawData) -ceq 'IDENTICAL_PREEXISTING_NOT_OWNED')}}
            finally{foreach($certificate in $existing){$certificate.Dispose()}}
        }finally{$store.Dispose()}
        Add-CheckResult 'TLS-CA06 Rootregistry weiterhin nicht erzeugt' (-not (Test-Path -LiteralPath (Join-Path $dataRoot 'State/authenticated-tls/registry.json')))
        $genericAclAgain=[IO.FileSystemAclExtensions]::GetAccessControl([IO.DirectoryInfo]::new($genericProject)).GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]'Access, Owner, Group')
        Add-CheckResult 'TLS-CA10 bestehender generischer Projektordner bleibt mit ACL/Bytes unangetastet' ([string]::Equals($genericAcl,$genericAclAgain,[StringComparison]::Ordinal) -and
            [string]::Equals($genericHash,(Get-FileHash -LiteralPath $genericFile).Hash,[StringComparison]::Ordinal) -and @(Get-ChildItem -LiteralPath $genericProject -Force).Count -eq 1)
    }
    $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'Private/AuthenticatedTlsCaCandidate.ps1'),[ref]$tokens,[ref]$errors)
    Add-CheckResult 'TLS-CA07 Laden definiert nur Funktionen' ($errors.Count -eq 0 -and @($ast.EndBlock.Statements|Where-Object {$_ -isnot [Management.Automation.Language.FunctionDefinitionAst]}).Count -eq 0)
    $text=$ast.Extent.Text
    Add-CheckResult 'TLS-CA07 keine SQL-/Provider-/Trustmutation oder C#-Bruecke' ($text -notmatch '(?i)Add-Type|Import-Certificate|Remove-Item|Start-Process|Invoke-Sqlcmd|::LoadFrom|\.Add\(\$certificate|\.Remove\(\$certificate|LocalMachine|\.pfx|\.pem')
    Write-Host "Authenticated TLS CA Candidate: $passed PASS, $($failures.Count) FAIL"
    if($failures.Count){throw 'AUTHENTICATED_TLS_CA_CANDIDATE_CHECKS_FAILED'}
}finally{
    $full=[IO.Path]::GetFullPath($fixtureRoot);$prefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    if(-not $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -cnotmatch '\Asql-lab-tls-ca-[a-f0-9]{32}\z'){throw 'TLS_CA_FIXTURE_CLEANUP_BOUNDARY'}
    if(Test-Path -LiteralPath $full){Remove-Item -LiteralPath $full -Recurse -Force}
    if(Test-Path -LiteralPath $full){throw 'TLS_CA_FIXTURE_CLEANUP_FAILED'}
    Write-Host 'TLS-CA eigene private Tempfixtures: CLEANED'
}
