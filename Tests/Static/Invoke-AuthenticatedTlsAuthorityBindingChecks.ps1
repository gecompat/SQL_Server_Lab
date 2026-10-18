#Requires -Version 7.5
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$repo=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
foreach($name in @('DiagnosticBundleReader','StorageContract','AuthenticatedTlsRequest','AuthenticatedTlsRegistryIndex','AuthenticatedTlsRegistryPayload',
    'AuthenticatedTlsRegistryDocument','AuthenticatedTlsRegistryRoot','AuthenticatedTlsContext','AuthenticatedTlsBackend','AuthenticatedTlsCaCandidate',
    'AuthenticatedTlsAuthorityBinding','AuthenticatedTlsRegistryWriter')){. (Join-Path $repo "Private/$name.ps1")}
. (Join-Path $PSScriptRoot '../Common/CheckResult.ps1')
$passed=0;$failures=[Collections.Generic.List[string]]::new()
$fixtureRoot=Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-tls-authority-'+[guid]::NewGuid().ToString('N'))
$controller='11111111-1111-4111-8111-111111111111';$location='22222222-2222-4222-8222-222222222222'
function ConvertTo-AuthorityBytes {param($Value) return ,[Text.Encoding]::UTF8.GetBytes(($Value|ConvertTo-Json -Depth 12 -Compress))}
function Copy-AuthorityFixture {param($Value) return ($Value|ConvertTo-Json -Depth 12 -Compress|ConvertFrom-Json -DateKind String)}
function New-AuthorityDocument {
    param([int]$Revision,[object[]]$Payloads=@())
    return ,(ConvertTo-AuthorityBytes ([pscustomobject]@{ContractVersion='SqlServerLab.AuthenticatedTlsContextRegistry/0.1';
        Index=[pscustomobject]@{ContractVersion='SqlServerLab.AuthenticatedTlsRegistryIndex/0.1';ControllerId=$controller;LocationId=$location;
            Revision=$Revision;Records=@($Payloads|ForEach-Object {Get-LabTlsPayloadIndexRecord $_})};Payloads=@($Payloads)}))
}
function Get-AuthoritySnapshot {
    return (@(Get-ChildItem -LiteralPath $fixtureRoot -File -Recurse|Sort-Object FullName|ForEach-Object {$_.FullName+':'+(Get-FileHash -LiteralPath $_.FullName).Hash}) -join '|')
}
function Invoke-AuthorityWrite {
    param($Operation,$Bytes,$TransactionId)
    $p=Get-LabAuthenticatedTlsRegistryWriterPreview $root $controller $location CURRENT_WINDOWS_PROCESS
    if(-not $p.Success){throw 'FIXTURE_WRITER_PREVIEW_FAILED'}
    return Invoke-LabAuthenticatedTlsRegistryWrite $root $controller $location CURRENT_WINDOWS_PROCESS $Operation `
        $p.Value.RootMetadataDigest $p.Value.ActorDigest $p.Value.RegistryByteSha256 $Bytes $TransactionId
}
function Get-AuthorityPreview {
    return Get-LabAuthenticatedTlsAuthorityPreview $root $controller $location CURRENT_WINDOWS_PROCESS `
        (ConvertTo-AuthorityBytes $ca) (ConvertTo-AuthorityBytes $signer) (ConvertTo-AuthorityBytes $client)
}
try{
    & {
        Set-StrictMode -Version Latest
        $ca=[pscustomobject][ordered]@{ContractVersion='SqlServerLab.AuthenticatedTlsRegistryPayload/0.2';ControllerId=$controller;LocationId=$location;
            Kind='AUTHORITY';Ref='33333333-3333-4333-8333-333333333333';Generation=1;Status='ACTIVE';
            TrustScopeRef='44444444-4444-4444-8444-444444444444';SignerContextRef='55555555-5555-4555-8555-555555555555';SignerGeneration=1;
            KeyStatus='CIPHERTEXT_BOUND_NOT_OPENED';CertificateStatus='PROFILE_BOUND_NOT_QUALIFIED';CandidateId='66666666-6666-4666-8666-666666666666';
            ClientRef='77777777-7777-4777-8777-777777777777';ClientGeneration=1;CandidateBindingDigest=('a'*64);CertificateSha256=('b'*64);
            EncryptedKeySha256=('c'*64);NotBeforeUtc='2026-01-01T00:00:00.0000000Z';NotAfterUtc='2026-01-03T00:00:00.0000000Z';
            Store='CURRENT_USER_ROOT';TrustStatus='IDENTICAL_PREEXISTING_NOT_OWNED'}
        $parsed=Read-LabAuthenticatedTlsRegistryPayload (ConvertTo-AuthorityBytes $ca)
        Add-CheckResult 'TLS-A01 neue geschlossene Authorityform bleibt offline/unqualifiziert' ($parsed.Success -and -not $parsed.Value.Ready -and $parsed.Value.QualificationStatus -ceq 'NOT_EXECUTED')
        $digest=$parsed.Value.IndexRecord.RevisionDigest
        foreach($change in @(@('CandidateId','88888888-8888-4888-8888-888888888888'),@('ClientRef','88888888-8888-4888-8888-888888888888'),
            @('ClientGeneration',2),@('CandidateBindingDigest',('d'*64)),@('CertificateSha256',('d'*64)),@('EncryptedKeySha256',('d'*64)),
            @('NotBeforeUtc','2026-01-01T00:00:01.0000000Z'),@('NotAfterUtc','2026-01-04T00:00:00.0000000Z'))){
            $copy=Copy-AuthorityFixture $ca;$copy.($change[0])=$change[1];$read=Read-LabAuthenticatedTlsRegistryPayload (ConvertTo-AuthorityBytes $copy)
            Add-CheckResult "TLS-A01 Revisionsdigest bindet $($change[0])" ($read.Success -and $read.Value.IndexRecord.RevisionDigest -cne $digest)
        }
        foreach($change in @(@('ContractVersion','SqlServerLab.AuthenticatedTlsRegistryPayload/0.1'),@('ClientGeneration','1'),@('NotAfterUtc','2027-01-03T00:00:00.0000000Z'),
            @('NotBeforeUtc','2026-01-01T00:00:00Z'),@('NotAfterUtc','2026-01-01T00:00:00.0000000Z'),@('KeyStatus','OPENED'),@('Store','LOCAL_MACHINE_ROOT'),@('TrustStatus','OWNED'))){
            $copy=Copy-AuthorityFixture $ca;$copy.($change[0])=$change[1]
            Add-CheckResult "TLS-A01 unzulaessiges $($change[0]) geschlossen abgelehnt" (-not (Read-LabAuthenticatedTlsRegistryPayload (ConvertTo-AuthorityBytes $copy)).Success)
        }
        $text=[Text.Encoding]::UTF8.GetString((ConvertTo-AuthorityBytes $ca))
        foreach($bad in @($text.Replace('"CandidateId":','"Candidate\u0049d":"private-canary","CandidateId":'),$text.Replace('"Kind":','"Unknown":true,"Kind":'))){
            Add-CheckResult 'TLS-A01 doppelte dekodierte und fremde Felder abgelehnt' (-not (Read-LabAuthenticatedTlsRegistryPayload ([Text.Encoding]::UTF8.GetBytes($bad))).Success)
        }
        Add-CheckResult 'TLS-A01 alter signer-only Preview qualifiziert neue CA nicht' (-not (Get-LabAuthenticatedTlsPayloadPreview (ConvertTo-AuthorityBytes $ca)).Success)
        $alien=[pscustomobject]@{};$script:alienCalls=0;$alien|Add-Member ScriptMethod ToString {$script:alienCalls++;throw 'PRIVATE_CANARY'} -Force
        $rejected=Get-LabAuthenticatedTlsAuthorityPreview $alien $controller $location CURRENT_WINDOWS_PROCESS $null $null $null
        Add-CheckResult 'TLS-A02 geschlossene Eingabe ohne Callerstringcast' (-not $rejected.Success -and $null -eq $rejected.Value -and $rejected.ErrorCode -ceq 'TLS_AUTHORITY_BINDING_INVALID' -and $script:alienCalls -eq 0)
        if(-not [Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)){
            Write-Host 'TLS-A native NTFS/DPAPI/Actor/ReadOnly-Store: NOT_EXECUTED auf Nicht-Windows';return
        }
        $root=Join-Path $fixtureRoot 'root'
        $null=New-Item -ItemType Directory -Path (Join-Path $root 'Catalog'),(Join-Path $root 'State') -Force
        $volume=(Get-LabVolumeIdentity $root).VolumeId
        [IO.File]::WriteAllBytes((Join-Path $root '.sql-server-lab-root.json'),(ConvertTo-AuthorityBytes @{ContractVersion='SqlServerLab.DataRoot/2.0';ManagedBy='SQL_Server_Lab';ControllerId=$controller;VolumeId=$volume;DataRoot=$root}))
        [IO.File]::WriteAllBytes((Join-Path $root 'Catalog/storage-locations.json'),(ConvertTo-AuthorityBytes @{ContractVersion='SqlServerLab.Storage/2.0';ControllerId=$controller;LabDataLocations=@(@{LocationId=$location;ControllerId=$controller;VolumeId=$volume;LabDataRoot=$root})}))
        function Get-LabTlsCaStorageBase {param($Native) return (Join-Path $fixtureRoot 'candidates')}
        $new=New-LabAuthenticatedTlsCaCandidate $root $controller $location CURRENT_WINDOWS_PROCESS 2
        if(-not $new.Success){throw 'FIXTURE_OWN_CA_CREATION_FAILED'}
        $binding=Get-LabTlsCaCandidateBinding $root $controller $location $new.Value.CandidateId
        $ca.CandidateId=$new.Value.CandidateId;$ca.CandidateBindingDigest=$binding.Digest;$ca.CertificateSha256=$binding.Certificate.Sha256
        $ca.EncryptedKeySha256=Get-LabTlsCaByteDigest $binding.Encrypted;$ca.NotBeforeUtc=$binding.Certificate.NotBeforeUtc;$ca.NotAfterUtc=$binding.Certificate.NotAfterUtc
        $script:keyCalls=0
        function Open-LabTlsCaSigningKey {$script:keyCalls++;throw 'FIXTURE_FORBIDDEN_KEY_OPEN'}
        $facts=Get-LabTlsWindowsProcessFacts;$backend=(Get-LabAuthenticatedTlsBackendMetadata CURRENT_PROCESS).Value
        $actor=[pscustomobject]@{UserSid=$facts.UserSid;HostMarker=$facts.HostMarker;ProfilePath=$facts.ProfilePath}
        $signer=[pscustomobject]@{ContractVersion='SqlServerLab.AuthenticatedTlsRegistryPayload/0.1';ControllerId=$controller;LocationId=$location;
            Kind='SIGNER_CONTEXT';Ref=$ca.SignerContextRef;Generation=1;Status='ACTIVE';Context='CURRENT_WINDOWS_PROCESS';Actor=$actor;
            Details=[pscustomobject]@{Backend='DOTNET_X509';RuntimeVersion=$backend.RuntimeVersion;ApiStatus=$backend.ApiStatus;Apis=$backend.Apis;KeyProtectionStatus='NOT_EVALUATED'}}
        # Nur Binaermetadaten injiziert; Actor, Root, ACL, Candidate, DPAPI und Writer sind echt.
        $script:clientHash='a'*64
        function Get-LabTlsWindowsClientBinaryMetadata {
            return [pscustomobject]@{SqlClient=[pscustomobject]@{Path='C:\synthetic\System.Data.SqlClient.dll';DiskSha256=$script:clientHash;DiskBytes=1;Evidence='ON_DISK_BYTES_ONLY'};
                Sqlcmd=[pscustomobject]@{Path='C:\synthetic\sqlcmd.exe';DiskSha256=('b'*64);DiskBytes=1;Evidence='ON_DISK_BYTES_ONLY'};
                SqlClientAssembly='System.Data.SqlClient, Version=4.6.1.6, Culture=neutral, PublicKeyToken=b77a5c561934e089';
                SqlClientLoadedMvid='99999999-9999-4999-8999-999999999999';LoadedImageDigestStatus='NOT_MEASURED';SqlcmdFlavorStatus='NOT_QUALIFIED';LoadedOdbcDriverStatus='NOT_EXECUTED'}
        }
        $b=Get-LabTlsWindowsClientBinaryMetadata
        $client=[pscustomobject]@{ContractVersion='SqlServerLab.AuthenticatedTlsRegistryPayload/0.1';ControllerId=$controller;LocationId=$location;
            Kind='CLIENT_CONTEXT';Ref=$ca.ClientRef;Generation=1;Status='ACTIVE';Context='CURRENT_WINDOWS_PROCESS';Actor=$actor;
            Details=[pscustomobject]@{Store='CURRENT_USER_ROOT';ClientStacks=@('SYSTEM_DATA_SQLCLIENT','ODBC_SQLCMD');SqlClientPath=$b.SqlClient.Path;SqlClientDiskSha256=$b.SqlClient.DiskSha256;SqlClientDiskBytes=1;
                SqlClientAssembly=$b.SqlClientAssembly;SqlClientLoadedMvid=$b.SqlClientLoadedMvid;SqlcmdPath=$b.Sqlcmd.Path;SqlcmdDiskSha256=$b.Sqlcmd.DiskSha256;SqlcmdDiskBytes=1;
                BinaryEvidence='ON_DISK_BYTES_ONLY';LoadedImageDigestStatus='NOT_MEASURED';SqlcmdFlavorStatus='NOT_QUALIFIED';LoadedOdbcDriverStatus='NOT_EXECUTED'}}
        $before=Get-AuthoritySnapshot
        Add-CheckResult 'TLS-A03 echter fehlender Trust wird read-only abgelehnt' (-not (Get-AuthorityPreview).Success -and (Get-AuthoritySnapshot) -ceq $before)
        # Positiv/Drift ausschliesslich injizierte Storelesung, niemals Storeimport.
        $script:trust='IDENTICAL_PREEXISTING_NOT_OWNED';$script:trustCalls=0;$script:failAt=0
        function Get-LabTlsCaExistingTrust {param($Der) $script:trustCalls++;if($script:failAt -gt 0 -and $script:trustCalls -ge $script:failAt){return 'ABSENT'};return $script:trust}
        $p=Get-AuthorityPreview
        Add-CheckResult 'TLS-A03 frischer Actor/Root/Ciphertext mit injiziertem Trust bleibt unqualifiziert' ($p.Success -and $p.Value.Status -ceq 'METADATA_BOUND_NOT_TLS_QUALIFIED' -and $p.Value.SnapshotStatus -ceq 'NON_ATOMIC_READ' -and -not $p.Value.Ready -and (Get-AuthoritySnapshot) -ceq $before)
        $realBinding=${function:Get-LabTlsCaCandidateBinding}
        $script:raceBytes=ConvertTo-AuthorityBytes $client
        $raceClient=Copy-AuthorityFixture $client;$raceClient.Details.SqlClientDiskSha256='d'*64
        $script:replacement=ConvertTo-AuthorityBytes $raceClient
        if($script:raceBytes.Length -ne $script:replacement.Length){throw 'FIXTURE_RACE_LENGTH_MISMATCH'}
        try{
            function Get-LabTlsCaCandidateBinding {
                param($DataRoot,$ControllerId,$LocationId,$CandidateId)
                [Buffer]::BlockCopy($script:replacement,0,$script:raceBytes,0,$script:raceBytes.Length)
                $script:clientHash='d'*64
                return & $realBinding $DataRoot $ControllerId $LocationId $CandidateId
            }
            $r=Get-LabAuthenticatedTlsAuthorityPreview $root $controller $location CURRENT_WINDOWS_PROCESS `
                (ConvertTo-AuthorityBytes $ca) (ConvertTo-AuthorityBytes $signer) $script:raceBytes
            Add-CheckResult 'TLS-A03 mutiertes Callerarray kann alten Snapshot nicht frisch binden' (-not $r.Success)
        }finally{Set-Item function:Get-LabTlsCaCandidateBinding $realBinding;$script:clientHash='a'*64}
        $saved=$client.Actor;$client.Actor=Copy-AuthorityFixture $saved;$client.Actor.HostMarker='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
        Add-CheckResult 'TLS-A03 fremder Clientactor abgelehnt' (-not (Get-AuthorityPreview).Success);$client.Actor=$saved
        $keyPath=Join-Path $binding.Paths.Candidate 'key.dpapi';$cipher=[IO.File]::ReadAllBytes($keyPath)
        try{[IO.File]::WriteAllBytes($keyPath,([byte[]]@(1,2,3)));Add-CheckResult 'TLS-A03 Ciphertextdrift ohne Keyopen abgelehnt' (-not (Get-AuthorityPreview).Success)}
        finally{[IO.File]::WriteAllBytes($keyPath,$cipher)}
        foreach($payloads in @(@($signer,$ca),@($signer,$client,$ca))){
            $valid=$payloads.Count -eq 3
            Add-CheckResult 'TLS-A04 Dokument fordert exakte aktive Clientkante' ((Read-LabAuthenticatedTlsRegistryDocument (New-AuthorityDocument 1 $payloads)).Success -eq $valid)
        }
        $client.Generation=2
        Add-CheckResult 'TLS-A04 stale Clientgeneration geschlossen abgelehnt' (-not (Read-LabAuthenticatedTlsRegistryDocument (New-AuthorityDocument 1 @($signer,$client,$ca))).Success);$client.Generation=1
        $replacement=Copy-AuthorityFixture $ca;$replacement.Generation=2;$replacement.CandidateId=[guid]::NewGuid().ToString('D')
        Add-CheckResult 'TLS-A04 kein Kandidatenaustausch unter derselben AuthorityRef' (-not (Test-LabAuthenticatedTlsRegistryDocumentTransition `
            (New-AuthorityDocument 1 @($signer,$client,$ca)) (New-AuthorityDocument 2 @($signer,$client,$replacement))).Success)
        foreach($name in @('TrustScopeRef','CandidateId','CertificateSha256')){
            $duplicate=Copy-AuthorityFixture $ca;$duplicate.Ref='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
            foreach($other in @('TrustScopeRef','CandidateId','CertificateSha256')|Where-Object {$_ -cne $name}){$duplicate.$other=if($other -ceq 'CertificateSha256'){'e'*64}else{[guid]::NewGuid().ToString('D')}}
            Add-CheckResult "TLS-A04 doppelte aktive $name abgelehnt" (-not (Read-LabAuthenticatedTlsRegistryDocument (New-AuthorityDocument 1 @($signer,$client,$ca,$duplicate))).Success)
        }
        $r=Invoke-AuthorityWrite INITIALIZE (New-AuthorityDocument 0)
        if(-not $r.Success){throw 'FIXTURE_INITIALIZE_FAILED'}
        $r=Invoke-AuthorityWrite UPDATE (New-AuthorityDocument 1 @($signer,$client))
        if(-not $r.Success){throw 'FIXTURE_CONTEXT_WRITE_FAILED'}
        $r=Invoke-AuthorityWrite UPDATE (New-AuthorityDocument 2 @($signer,$client,$ca))
        Add-CheckResult 'TLS-A05 echte private CA-Metadaten-Commitlane ohne Key-/Storewrite' ($r.Success -and $r.Value.Status -ceq 'METADATA_COMMITTED' -and -not $r.Value.Ready)
        if(-not $r.Success){throw 'FIXTURE_CA_WRITE_FAILED'}
        $extra=Copy-AuthorityFixture $signer;$extra.Ref='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
        $next=New-AuthorityDocument 3 @($signer,$client,$ca,$extra)
        $before=Get-AuthoritySnapshot;$script:trust='ABSENT'
        $r=Invoke-AuthorityWrite UPDATE $next
        Add-CheckResult 'TLS-A05 unveraenderte CA bei Trustdrift vor Intent abgelehnt' (-not $r.Success -and $r.ErrorCode -ceq 'TLS_REGISTRY_WRITE_REJECTED' -and (Get-AuthoritySnapshot) -ceq $before)
        $script:trust='IDENTICAL_PREEXISTING_NOT_OWNED';$script:clientHash='d'*64
        $r=Invoke-AuthorityWrite UPDATE $next
        Add-CheckResult 'TLS-A05 unveraenderte Clientgeneration frisch gebunden' (-not $r.Success -and (Get-AuthoritySnapshot) -ceq $before);$script:clientHash='a'*64
        # Kontrollierter Trustentzug zwischen installiertem Kandidaten und Commit.
        $script:trustCalls=0;$script:failAt=5
        $r=Invoke-AuthorityWrite UPDATE $next
        $pending=Get-LabAuthenticatedTlsRegistryWriterPreview $root $controller $location CURRENT_WINDOWS_PROCESS
        Add-CheckResult 'TLS-A06 Drift vor Commit erhaelt installierten Kandidaten offen' (-not $r.Success -and $r.ErrorCode -ceq 'TLS_REGISTRY_RECOVERY_REQUIRED' -and $pending.Success -and $pending.Value.Status -ceq 'CANDIDATE_INSTALLED')
        if(-not $pending.Success -or $pending.Value.Status -cne 'CANDIDATE_INSTALLED'){throw 'FIXTURE_PENDING_EXPECTED'}
        $before=Get-AuthoritySnapshot
        $r=Invoke-AuthorityWrite RECOVER_COMMIT $null $pending.Value.PendingTransactionId
        Add-CheckResult 'TLS-A06 Recovery prueft Trust frisch und schreibt keine falsche Quittung' (-not $r.Success -and (Get-AuthoritySnapshot) -ceq $before)
        $script:failAt=0
        $r=Invoke-AuthorityWrite RECOVER_COMMIT $null $pending.Value.PendingTransactionId
        Add-CheckResult 'TLS-A06 expliziter Recoverycommit nach frischer Bindung' ($r.Success -and $r.Value.Status -ceq 'RECOVERY_COMMITTED')
        Add-CheckResult 'TLS-A06 Bindung und Writer oeffnen keinen privaten Key' ($script:keyCalls -eq 0)
        Write-Host 'TLS-A native eigene Temp-CA/NTFS/DPAPI/Registry; positive Trust- und Binaerwerte INJECTED, keine TLS-Qualifikation.'
    }
}finally{
    if(Test-Path -LiteralPath $fixtureRoot){
        $full=[IO.Path]::GetFullPath($fixtureRoot);$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
        if(-not $full.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -cnotmatch '\Asql-lab-tls-authority-[0-9a-f]{32}\z'){throw 'FIXTURE_CLEANUP_SCOPE_INVALID'}
        Assert-LabDiagnosticPath $full
        Remove-Item -LiteralPath $full -Recurse -Force
        Add-CheckResult 'TLS-A07 eigener Tempbaum entfernt' (-not (Test-Path -LiteralPath $full))
    }
}
Write-Host "TLS Authority Binding: $passed PASS; $($failures.Count) FAIL"
if($failures.Count){throw ($failures -join [Environment]::NewLine)}
