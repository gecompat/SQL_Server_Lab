#Requires -Version 7.2
# Private Windows-Lane: unregistrierter Kandidat, niemals Storemutation.

function Test-LabTlsCaCandidateInput {
    param([object]$DataRoot,[object]$ControllerId,[object]$LocationId,[object]$Context)
    return ($DataRoot -is [string] -and [string].GetProperty('Length').GetValue($DataRoot) -le 4096 -and
        (Test-LabTlsRequestReference $ControllerId) -and (Test-LabTlsRequestReference $LocationId) -and
        (Test-LabTlsRequestEnum $Context @('CURRENT_WINDOWS_PROCESS')))
}

function Assert-LabTlsCaCandidateCapability {
    if(-not [Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows) -or
        [Management.Automation.PSVersionInfo]::PSVersion -lt [version]'7.5'){throw 'TLS_CA_CANDIDATE_NOT_SUPPORTED'}
    # Oeffentliches ungueltiges Canary prueft die tatsaechliche Span-Bindung,
    # bevor irgendein Verzeichnis oder privater Key angelegt wird.
    $probe=$null;$bound=$false
    try{
        $probe=[Security.Cryptography.RSA]::Create();$consumed=0
        try{$probe.ImportPkcs8PrivateKey([byte[]]@(0),[ref]$consumed)}catch{
            $inner=$_.Exception
            while($null -ne $inner){if($inner -is [Security.Cryptography.CryptographicException]){$bound=$true;break};$inner=$inner.InnerException}
        }
    }finally{if($null -ne $probe){$probe.Dispose()}}
    if(-not $bound){throw 'TLS_CA_CANDIDATE_NOT_SUPPORTED'}
}

function Get-LabTlsCaActorDigest {
    param([object]$Native)
    return Get-LabTlsPayloadDigest @('SqlServerLab.TlsCaCandidateActor/0.1',$Native.UserSid,$Native.HostMarker,$Native.ProfilePath)
}

function Get-LabTlsCaStorageBase {
    param([object]$Native)
    $local=Assert-LabDiagnosticPath ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData))
    if(-not $local.StartsWith($Native.ProfilePath.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase) -or
        [IO.DriveInfo]::new([IO.Path]::GetPathRoot($local)).DriveType -ne [IO.DriveType]::Fixed){throw 'TLS_CA_STORAGE_INVALID'}
    $path=Assert-LabDiagnosticPath (Join-Path $local 'SQL_Server_Lab_AuthenticatedTls')
    # Kein Git-Checkout darf zum privaten Keybereich werden, auch kein verschachteltes Repo.
    $ancestor=[IO.DirectoryInfo]::new($path)
    while($null -ne $ancestor){
        if(Test-Path -LiteralPath (Join-Path $ancestor.FullName '.git')){throw 'TLS_CA_STORAGE_INVALID'}
        $ancestor=$ancestor.Parent
    }
    return $path
}

function Get-LabTlsCaSecurity {
    param([string]$UserSid,[switch]$Directory)
    $acl=if($Directory){[Security.AccessControl.DirectorySecurity]::new()}else{[Security.AccessControl.FileSecurity]::new()}
    $owner=[Security.Principal.SecurityIdentifier]::new($UserSid)
    $acl.SetOwner($owner);$acl.SetAccessRuleProtection($true,$false)
    foreach($sid in @($owner,[Security.Principal.SecurityIdentifier]::new('S-1-5-18'))){
        $rule=if($Directory){
            [Security.AccessControl.FileSystemAccessRule]::new($sid,[Security.AccessControl.FileSystemRights]::FullControl,
                [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit',[Security.AccessControl.PropagationFlags]::None,[Security.AccessControl.AccessControlType]::Allow)
        }else{[Security.AccessControl.FileSystemAccessRule]::new($sid,[Security.AccessControl.FileSystemRights]::FullControl,[Security.AccessControl.AccessControlType]::Allow)}
        $null=$acl.AddAccessRule($rule)
    }
    return $acl
}

function Assert-LabTlsCaPrivateAcl {
    param([string]$Path,[string]$UserSid,[switch]$Directory)
    $null=Assert-LabDiagnosticPath $Path
    $item=Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if($item.PSIsContainer -ne [bool]$Directory -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'TLS_CA_STORAGE_INVALID'}
    $acl=if($Directory){[IO.FileSystemAclExtensions]::GetAccessControl([IO.DirectoryInfo]::new($Path))}else{[IO.FileSystemAclExtensions]::GetAccessControl([IO.FileInfo]::new($Path))}
    $rules=$acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])
    if(-not $acl.AreAccessRulesProtected -or (-not [string]::Equals(($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value),($UserSid),[StringComparison]::Ordinal)) -or $rules.Count -ne 2){throw 'TLS_CA_ACL_INVALID'}
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($rule in $rules){
        if($rule.IsInherited -or $rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow -or
            $rule.FileSystemRights -ne [Security.AccessControl.FileSystemRights]::FullControl -or
            (-not (Test-LabTlsRequestEnum ($rule.IdentityReference.Value) (@($UserSid,'S-1-5-18')))) -or -not $seen.Add($rule.IdentityReference.Value) -or
            $rule.PropagationFlags -ne [Security.AccessControl.PropagationFlags]::None -or
            $rule.InheritanceFlags -ne $(if($Directory){[Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'}else{[Security.AccessControl.InheritanceFlags]::None})){throw 'TLS_CA_ACL_INVALID'}
    }
}

function Initialize-LabTlsCaPrivateDirectory {
    param([string]$Path,[string]$UserSid,[switch]$NewOnly)
    $null=Assert-LabDiagnosticPath $Path
    if(Test-Path -LiteralPath $Path){if($NewOnly){throw 'TLS_CA_ALREADY_EXISTS'}}else{
        [IO.FileSystemAclExtensions]::Create([IO.DirectoryInfo]::new($Path),(Get-LabTlsCaSecurity $UserSid -Directory))
    }
    Assert-LabTlsCaPrivateAcl $Path $UserSid -Directory
}

function Write-LabTlsCaPrivateFile {
    param([string]$Path,[string]$UserSid,[byte[]]$Bytes)
    $null=Assert-LabDiagnosticPath $Path
    $stream=$null
    try{
        $stream=[IO.FileSystemAclExtensions]::Create([IO.FileInfo]::new($Path),[IO.FileMode]::CreateNew,
            [Security.AccessControl.FileSystemRights]::FullControl,[IO.FileShare]::None,4096,[IO.FileOptions]::None,(Get-LabTlsCaSecurity $UserSid))
        $stream.Write($Bytes,0,$Bytes.Length);$stream.Flush($true)
    }finally{if($null -ne $stream){$stream.Dispose()}}
    Assert-LabTlsCaPrivateAcl $Path $UserSid
}

function Read-LabTlsCaPrivateFile {
    param([string]$Path,[string]$UserSid,[int]$MaximumBytes)
    Assert-LabTlsCaPrivateAcl $Path $UserSid
    $stream=$null
    try{
        $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        if($stream.Length -lt 1 -or $stream.Length -gt $MaximumBytes){throw 'TLS_CA_FILE_INVALID'}
        $bytes=[byte[]]::new([int]$stream.Length);$offset=0
        while($offset -lt $bytes.Length){$count=$stream.Read($bytes,$offset,$bytes.Length-$offset);if($count -eq 0){throw 'TLS_CA_FILE_INVALID'};$offset+=$count}
        if($stream.ReadByte() -ne -1){throw 'TLS_CA_FILE_INVALID'}
        return ,$bytes
    }finally{if($null -ne $stream){$stream.Dispose()}}
}

function Get-LabTlsCaByteDigest {
    param([byte[]]$Bytes)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
}

function Read-LabTlsCaMetadata {
    param([byte[]]$Bytes,[string[]]$Names)
    $document=$null
    try{
        $options=[Text.Json.JsonDocumentOptions]::new();$options.MaxDepth=4
        $document=[Text.Json.JsonDocument]::Parse([Text.UTF8Encoding]::new($false,$true).GetString($Bytes),$options)
        if($document.RootElement.ValueKind -ne [Text.Json.JsonValueKind]::Object){throw 'TLS_CA_METADATA_INVALID'}
        $fields=[ordered]@{};$seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach($property in $document.RootElement.EnumerateObject()){
            if($fields.Count -ge $Names.Count -or (-not (Test-LabTlsRequestEnum ($property.Name) ($Names))) -or -not $seen.Add($property.Name) -or
                $property.Value.ValueKind -ne [Text.Json.JsonValueKind]::String){throw 'TLS_CA_METADATA_INVALID'}
            $value=$property.Value.GetString();if($value.Length -gt 256){throw 'TLS_CA_METADATA_INVALID'}
            $fields.Add($property.Name,$value)
        }
        if($fields.Count -ne $Names.Count){throw 'TLS_CA_METADATA_INVALID'}
        return [pscustomobject]$fields
    }finally{if($null -ne $document){$document.Dispose()}}
}

function Get-LabTlsCaCandidatePaths {
    param([object]$Native,[string]$ControllerId,[string]$LocationId,[string]$CandidateId)
    $base=Get-LabTlsCaStorageBase $Native
    return [pscustomobject]@{Base=$base;Controller=(Join-Path $base $ControllerId);Location=(Join-Path (Join-Path $base $ControllerId) $LocationId)
        Candidate=(Join-Path (Join-Path (Join-Path $base $ControllerId) $LocationId) $CandidateId)}
}

function Assert-LabTlsCaCertificate {
    param([byte[]]$Der,[string]$CandidateId)
    $cert=$null;$public=$null
    try{
        $cert=[Security.Cryptography.X509Certificates.X509Certificate2]::new($Der)
        if($cert.HasPrivateKey -or $cert.RawData.Length -ne $Der.Length -or (-not [string]::Equals(((Get-LabTlsCaByteDigest $cert.RawData)),((Get-LabTlsCaByteDigest $Der)),[StringComparison]::Ordinal)) -or
            (-not [string]::Equals(($cert.Subject),(('CN=SQL_Server_Lab Candidate '+$CandidateId)),[StringComparison]::Ordinal)) -or (-not [string]::Equals(($cert.Issuer),($cert.Subject),[StringComparison]::Ordinal)) -or
            (-not [string]::Equals(($cert.SignatureAlgorithm.Value),('1.2.840.113549.1.1.11'),[StringComparison]::Ordinal)) -or $cert.Extensions.Count -ne 2 -or
            $cert.NotAfter.ToUniversalTime() -le [datetime]::UtcNow -or $cert.NotBefore.ToUniversalTime() -gt [datetime]::UtcNow -or
            ($cert.NotAfter.ToUniversalTime()-$cert.NotBefore.ToUniversalTime()).TotalDays -gt 365){throw 'TLS_CA_CERTIFICATE_INVALID'}
        $bc=@($cert.Extensions|Where-Object {([string]::Equals(($_.Oid.Value),('2.5.29.19'),[StringComparison]::Ordinal))});$ku=@($cert.Extensions|Where-Object {([string]::Equals(($_.Oid.Value),('2.5.29.15'),[StringComparison]::Ordinal))})
        if($bc.Count -ne 1 -or $ku.Count -ne 1 -or -not $bc[0].Critical -or -not $ku[0].Critical -or
            -not $bc[0].CertificateAuthority -or -not $bc[0].HasPathLengthConstraint -or $bc[0].PathLengthConstraint -ne 0 -or
            $ku[0].KeyUsages -ne [Security.Cryptography.X509Certificates.X509KeyUsageFlags]'KeyCertSign, CrlSign'){throw 'TLS_CA_CERTIFICATE_INVALID'}
        $public=[Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPublicKey($cert)
        if($null -eq $public -or $public.KeySize -ne 3072){throw 'TLS_CA_CERTIFICATE_INVALID'}
        # Vollstaendige DER-Sequenz und echte Selbstsignatur, ohne Chain-/Netzwerkprobe.
        $reader=[Formats.Asn1.AsnReader]::new([ReadOnlyMemory[byte]]::new($Der),[Formats.Asn1.AsnEncodingRules]::DER)
        $sequence=$reader.ReadSequence();$tbs=$sequence.ReadEncodedValue().ToArray();$null=$sequence.ReadEncodedValue()
        $unused=0;$signature=$sequence.ReadBitString([ref]$unused)
        if($unused -ne 0 -or $reader.HasData -or $sequence.HasData -or -not $public.VerifyData($tbs,$signature,[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pkcs1)){throw 'TLS_CA_CERTIFICATE_INVALID'}
        return [pscustomobject]@{Sha256=(Get-LabTlsCaByteDigest $Der);NotBeforeUtc=$cert.NotBefore.ToUniversalTime().ToString('O');NotAfterUtc=$cert.NotAfter.ToUniversalTime().ToString('O')}
    }finally{if($null -ne $public){$public.Dispose()};if($null -ne $cert){$cert.Dispose()}}
}

function Open-LabTlsCaSigningKey {
    param([byte[]]$Encrypted,[byte[]]$Entropy,[byte[]]$Der)
    $plain=$null;$rsa=$null;$cert=$null;$public=$null;$opened=$false
    try{
        $plain=[Security.Cryptography.ProtectedData]::Unprotect($Encrypted,$Entropy,[Security.Cryptography.DataProtectionScope]::CurrentUser)
        $rsa=[Security.Cryptography.RSA]::Create();$consumed=0;$rsa.ImportPkcs8PrivateKey($plain,[ref]$consumed)
        if($consumed -ne $plain.Length -or $rsa.KeySize -ne 3072){throw 'TLS_CA_KEY_INVALID'}
        $cert=[Security.Cryptography.X509Certificates.X509Certificate2]::new($Der);$public=[Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPublicKey($cert)
        $challenge=[Security.Cryptography.RandomNumberGenerator]::GetBytes(32)
        $signature=$rsa.SignData($challenge,[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pkcs1)
        if(-not $public.VerifyData($challenge,$signature,[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pkcs1)){throw 'TLS_CA_KEY_INVALID'}
        $opened=$true;return $rsa
    }finally{
        if($null -ne $plain){[Array]::Clear($plain,0,$plain.Length)}
        foreach($resource in @($public,$cert)){if($null -ne $resource){$resource.Dispose()}}
        if(-not $opened -and $null -ne $rsa){$rsa.Dispose()}
    }
}

function Assert-LabTlsCaEncryptedKey {
    param([byte[]]$Encrypted,[byte[]]$Entropy,[byte[]]$Der)
    $key=$null
    try{$key=Open-LabTlsCaSigningKey $Encrypted $Entropy $Der}
    finally{if($null -ne $key){$key.Dispose()}}
}
function New-LabAuthenticatedTlsCaCandidate {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Private fixed candidate operation; activation and trust require a separate reviewed approval.')]
    [CmdletBinding()]
    param([object]$DataRoot,[object]$ControllerId,[object]$LocationId,[object]$Context,[object]$ValidityDays)
    $bad=[pscustomobject][ordered]@{Success=$false;Value=$null;ErrorCode='TLS_CA_CANDIDATE_INVALID'}
    if(-not (Test-LabTlsCaCandidateInput $DataRoot $ControllerId $LocationId $Context) -or $ValidityDays -isnot [int] -or $ValidityDays -lt 2 -or $ValidityDays -gt 365){return $bad}
    $ControllerId=[guid]::Parse($ControllerId).ToString('D');$LocationId=[guid]::Parse($LocationId).ToString('D')
    $rsa=$null;$cert=$null;$plain=$null;$owned=$false
    try{
        Assert-LabTlsCaCandidateCapability
        $root=Get-LabAuthenticatedTlsRootMetadata $DataRoot $ControllerId $LocationId
        if(-not $root.Success){return $bad}
        $native=Get-LabTlsWindowsProcessFacts;$actor=Get-LabTlsCaActorDigest $native
        $id=[guid]::NewGuid().ToString('D');$paths=Get-LabTlsCaCandidatePaths $native $ControllerId $LocationId $id
        # Sequentielle private Hierarchie; bestehende ACLs werden nur geprueft.
        foreach($parent in @($paths.Base,$paths.Controller,$paths.Location)){
            if(-not (Test-Path -LiteralPath $parent)){$owned=$true}
            Initialize-LabTlsCaPrivateDirectory $parent $native.UserSid
        }
        Initialize-LabTlsCaPrivateDirectory $paths.Candidate $native.UserSid -NewOnly;$owned=$true
        $intent=[pscustomobject][ordered]@{ContractVersion='SqlServerLab.TlsCaCandidateIntent/0.1';CandidateId=$id;ActorDigest=$actor;RootMetadataDigest=$root.Value.RootMetadataDigest;Status='OWNED_PARTIAL_RECOVERY_REQUIRED'}
        Write-LabTlsCaPrivateFile (Join-Path $paths.Candidate 'intent.json') $native.UserSid ([Text.Encoding]::UTF8.GetBytes(($intent|ConvertTo-Json -Compress)))
        $rsa=[Security.Cryptography.RSA]::Create(3072)
        $request=[Security.Cryptography.X509Certificates.CertificateRequest]::new(('CN=SQL_Server_Lab Candidate '+$id),$rsa,[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pkcs1)
        $request.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new($true,$true,0,$true))
        $request.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509KeyUsageExtension]::new([Security.Cryptography.X509Certificates.X509KeyUsageFlags]'KeyCertSign, CrlSign',$true))
        $begin=[DateTimeOffset]::UtcNow.AddMinutes(-5);$cert=$request.CreateSelfSigned($begin,$begin.AddDays($ValidityDays))
        $der=$cert.Export([Security.Cryptography.X509Certificates.X509ContentType]::Cert);$profileData=Assert-LabTlsCaCertificate $der $id
        $entropy=[Text.Encoding]::UTF8.GetBytes((Get-LabTlsPayloadDigest @('SqlServerLab.TlsCaCandidateKey/0.1',$id,$ControllerId,$LocationId,$root.Value.RootMetadataDigest,$actor)))
        $plain=$rsa.ExportPkcs8PrivateKey()
        $encrypted=[Security.Cryptography.ProtectedData]::Protect($plain,$entropy,[Security.Cryptography.DataProtectionScope]::CurrentUser)
        [Array]::Clear($plain,0,$plain.Length);$plain=$null
        Write-LabTlsCaPrivateFile (Join-Path $paths.Candidate 'ca.der') $native.UserSid $der
        Write-LabTlsCaPrivateFile (Join-Path $paths.Candidate 'key.dpapi') $native.UserSid $encrypted
        $der=Read-LabTlsCaPrivateFile (Join-Path $paths.Candidate 'ca.der') $native.UserSid 16384
        if((-not [string]::Equals(((Assert-LabTlsCaCertificate $der $id).Sha256),($profileData.Sha256),[StringComparison]::Ordinal))){throw 'TLS_CA_CERTIFICATE_INVALID'}
        $reopened=Read-LabTlsCaPrivateFile (Join-Path $paths.Candidate 'key.dpapi') $native.UserSid 16384
        Assert-LabTlsCaEncryptedKey $reopened $entropy $der
        $again=Get-LabAuthenticatedTlsRootMetadata $DataRoot $ControllerId $LocationId
        if(-not $again.Success -or (-not [string]::Equals(($again.Value.RootMetadataDigest),($root.Value.RootMetadataDigest),[StringComparison]::Ordinal)) -or
            (-not [string]::Equals(((Get-LabTlsCaActorDigest (Get-LabTlsWindowsProcessFacts))),($actor),[StringComparison]::Ordinal))){throw 'TLS_CA_BINDING_DRIFT'}
        $receipt=[pscustomobject][ordered]@{ContractVersion='SqlServerLab.TlsCaCandidate/0.1';CandidateId=$id;ControllerId=$ControllerId;LocationId=$LocationId
            RootMetadataDigest=$root.Value.RootMetadataDigest;ActorDigest=$actor;CertificateSha256=$profileData.Sha256;EncryptedKeySha256=(Get-LabTlsCaByteDigest $reopened)
            NotBeforeUtc=$profileData.NotBeforeUtc;NotAfterUtc=$profileData.NotAfterUtc;Status='UNREGISTERED_UNQUALIFIED'}
        Write-LabTlsCaPrivateFile (Join-Path $paths.Candidate 'receipt.json') $native.UserSid ([Text.Encoding]::UTF8.GetBytes(($receipt|ConvertTo-Json -Compress)))
        $receiptAgain=Read-LabTlsCaPrivateFile (Join-Path $paths.Candidate 'receipt.json') $native.UserSid 8192
        if((-not [string]::Equals(([Text.Encoding]::UTF8.GetString($receiptAgain)),(($receipt|ConvertTo-Json -Compress)),[StringComparison]::Ordinal))){throw 'TLS_CA_FILE_INVALID'}
        return [pscustomobject][ordered]@{Success=$true;Value=[pscustomobject][ordered]@{CandidateId=$id;Status='UNREGISTERED_UNQUALIFIED';CertificateSha256=$profileData.Sha256
            NotBeforeUtc=$profileData.NotBeforeUtc;NotAfterUtc=$profileData.NotAfterUtc;KeyProtection='DPAPI_CURRENT_USER_PKCS8';KeyMatchStatus='REOPEN_SIGN_VERIFY'
            RegistrationStatus='NOT_EXECUTED';QualificationStatus='NOT_EXECUTED';Ready=$false;MutationAllowed=$false};ErrorCode=$null}
    }catch{
        $bad.ErrorCode=if($owned){'TLS_CA_CANDIDATE_RECOVERY_REQUIRED'}elseif(([string]::Equals(($_.Exception.Message),('TLS_CA_CANDIDATE_NOT_SUPPORTED'),[StringComparison]::Ordinal))){'TLS_CA_CANDIDATE_NOT_SUPPORTED'}else{'TLS_CA_CANDIDATE_INVALID'}
        return $bad
    }finally{if($null -ne $plain){[Array]::Clear($plain,0,$plain.Length)};foreach($resource in @($cert,$rsa)){if($null -ne $resource){$resource.Dispose()}}}
}

function Get-LabTlsCaExistingTrust {
    param([byte[]]$Der)
    $store=$null
    try{
        $store=[Security.Cryptography.X509Certificates.X509Store]::new([Security.Cryptography.X509Certificates.StoreName]::Root,[Security.Cryptography.X509Certificates.StoreLocation]::CurrentUser)
        $store.Open([Security.Cryptography.X509Certificates.OpenFlags]'ReadOnly, OpenExistingOnly')
        $count=0;$certificates=$store.Certificates
        try{foreach($certificate in $certificates){if(([string]::Equals(([Convert]::ToBase64String($certificate.RawData)),([Convert]::ToBase64String($Der)),[StringComparison]::Ordinal))){$count++}}}
        finally{foreach($certificate in $certificates){$certificate.Dispose()}}
        return $(if($count -gt 0){'IDENTICAL_PREEXISTING_NOT_OWNED'}else{'ABSENT'})
    }finally{if($null -ne $store){$store.Dispose()}}
}

function Get-LabTlsCaCandidateBinding {
    param([string]$DataRoot,[string]$ControllerId,[string]$LocationId,[string]$CandidateId)
        Assert-LabTlsCaCandidateCapability
        $root=Get-LabAuthenticatedTlsRootMetadata $DataRoot $ControllerId $LocationId;if(-not $root.Success){throw 'TLS_CA_CANDIDATE_BINDING_INVALID'}
        $native=Get-LabTlsWindowsProcessFacts;$actor=Get-LabTlsCaActorDigest $native
        $paths=Get-LabTlsCaCandidatePaths $native $ControllerId $LocationId $CandidateId
        foreach($parent in @($paths.Base,$paths.Controller,$paths.Location,$paths.Candidate)){Assert-LabTlsCaPrivateAcl $parent $native.UserSid -Directory}
        $names=@(Get-ChildItem -LiteralPath $paths.Candidate -Force -ErrorAction Stop|Select-Object -ExpandProperty Name)
        if($names.Count -ne 4 -or @($names|Where-Object {(-not (Test-LabTlsRequestEnum ($_) (@('intent.json','receipt.json','ca.der','key.dpapi'))))}).Count -ne 0){throw 'TLS_CA_CANDIDATE_BINDING_INVALID'}
        $intentPath=Join-Path $paths.Candidate 'intent.json'
        $intentBytes=Read-LabTlsCaPrivateFile $intentPath $native.UserSid 2048
        $intent=Read-LabTlsCaMetadata $intentBytes @('ContractVersion','CandidateId','ActorDigest','RootMetadataDigest','Status')
        $intentFields=Get-LabTlsRequestFields $intent @('ContractVersion','CandidateId','ActorDigest','RootMetadataDigest','Status')
        if($null -eq $intentFields -or $intentFields.Count -ne 5 -or
            -not (Test-LabTlsRequestEnum $intentFields.ContractVersion @('SqlServerLab.TlsCaCandidateIntent/0.1')) -or
            -not (Test-LabTlsRequestEnum $intentFields.CandidateId @($CandidateId)) -or
            -not (Test-LabTlsRequestEnum $intentFields.ActorDigest @($actor)) -or
            -not (Test-LabTlsRequestEnum $intentFields.RootMetadataDigest @($root.Value.RootMetadataDigest)) -or
            -not (Test-LabTlsRequestEnum $intentFields.Status @('OWNED_PARTIAL_RECOVERY_REQUIRED'))){throw 'TLS_CA_CANDIDATE_BINDING_INVALID'}
        $receiptPath=Join-Path $paths.Candidate 'receipt.json'
        $bytes=Read-LabTlsCaPrivateFile $receiptPath $native.UserSid 8192
        $receipt=Read-LabTlsCaMetadata $bytes @('ContractVersion','CandidateId','ControllerId','LocationId','RootMetadataDigest','ActorDigest','CertificateSha256','EncryptedKeySha256','NotBeforeUtc','NotAfterUtc','Status')
        $fields=Get-LabTlsRequestFields $receipt @('ContractVersion','CandidateId','ControllerId','LocationId','RootMetadataDigest','ActorDigest','CertificateSha256','EncryptedKeySha256','NotBeforeUtc','NotAfterUtc','Status')
        if($null -eq $fields -or $fields.Count -ne 11){throw 'TLS_CA_CANDIDATE_BINDING_INVALID'}
        foreach($entry in $fields.GetEnumerator()){if($entry.Value -isnot [string] -or [string].GetProperty('Length').GetValue($entry.Value) -gt 256){throw 'TLS_CA_CANDIDATE_BINDING_INVALID'}}
        if((-not [string]::Equals(($fields.ContractVersion),('SqlServerLab.TlsCaCandidate/0.1'),[StringComparison]::Ordinal)) -or (-not [string]::Equals(($fields.CandidateId),($CandidateId),[StringComparison]::Ordinal)) -or (-not [string]::Equals(($fields.ControllerId),($ControllerId),[StringComparison]::Ordinal)) -or
            (-not [string]::Equals(($fields.LocationId),($LocationId),[StringComparison]::Ordinal)) -or (-not [string]::Equals(($fields.RootMetadataDigest),($root.Value.RootMetadataDigest),[StringComparison]::Ordinal)) -or (-not [string]::Equals(($fields.ActorDigest),($actor),[StringComparison]::Ordinal)) -or
            (-not [string]::Equals(($fields.Status),('UNREGISTERED_UNQUALIFIED'),[StringComparison]::Ordinal)) -or $fields.CertificateSha256 -cnotmatch '\A[0-9a-f]{64}\z' -or $fields.EncryptedKeySha256 -cnotmatch '\A[0-9a-f]{64}\z'){throw 'TLS_CA_CANDIDATE_BINDING_INVALID'}
        $der=Read-LabTlsCaPrivateFile (Join-Path $paths.Candidate 'ca.der') $native.UserSid 16384
        $profileData=Assert-LabTlsCaCertificate $der $CandidateId
        if((-not [string]::Equals(($profileData.Sha256),($fields.CertificateSha256),[StringComparison]::Ordinal)) -or (-not [string]::Equals(($profileData.NotBeforeUtc),($fields.NotBeforeUtc),[StringComparison]::Ordinal)) -or (-not [string]::Equals(($profileData.NotAfterUtc),($fields.NotAfterUtc),[StringComparison]::Ordinal))){throw 'TLS_CA_CANDIDATE_BINDING_INVALID'}
        # Nur Ciphertext-Hash; Preview oeffnet keinen privaten Schluessel.
        $encrypted=Read-LabTlsCaPrivateFile (Join-Path $paths.Candidate 'key.dpapi') $native.UserSid 16384
        if((-not [string]::Equals(((Get-LabTlsCaByteDigest $encrypted)),($fields.EncryptedKeySha256),[StringComparison]::Ordinal))){throw 'TLS_CA_CANDIDATE_BINDING_INVALID'}
        $again=Get-LabAuthenticatedTlsRootMetadata $DataRoot $ControllerId $LocationId
        if(-not $again.Success -or (-not [string]::Equals(($again.Value.RootMetadataDigest),($root.Value.RootMetadataDigest),[StringComparison]::Ordinal)) -or
            (-not [string]::Equals(((Get-LabTlsCaActorDigest (Get-LabTlsWindowsProcessFacts))),($actor),[StringComparison]::Ordinal)) -or
            (-not [string]::Equals(((Get-LabTlsCaByteDigest (Read-LabTlsCaPrivateFile $intentPath $native.UserSid 2048))),((Get-LabTlsCaByteDigest $intentBytes)),[StringComparison]::Ordinal)) -or
            (-not [string]::Equals(((Get-LabTlsCaByteDigest (Read-LabTlsCaPrivateFile (Join-Path $paths.Candidate 'ca.der') $native.UserSid 16384))),($profileData.Sha256),[StringComparison]::Ordinal)) -or
            (-not [string]::Equals(((Get-LabTlsCaByteDigest (Read-LabTlsCaPrivateFile (Join-Path $paths.Candidate 'key.dpapi') $native.UserSid 16384))),($fields.EncryptedKeySha256),[StringComparison]::Ordinal)) -or
            (-not [string]::Equals(((Get-LabTlsCaByteDigest (Read-LabTlsCaPrivateFile $receiptPath $native.UserSid 8192))),((Get-LabTlsCaByteDigest $bytes)),[StringComparison]::Ordinal))){throw 'TLS_CA_CANDIDATE_BINDING_INVALID'}
        $digest=Get-LabTlsPayloadDigest @('SqlServerLab.TlsCaCandidateBinding/0.1',$root.Value.RootMetadataDigest,$actor,$profileData.Sha256,
            (Get-LabTlsCaByteDigest $intentBytes),(Get-LabTlsCaByteDigest $bytes),(Get-LabTlsCaByteDigest $encrypted))
        return [pscustomobject]@{Native=$native;Paths=$paths;RootMetadataDigest=$root.Value.RootMetadataDigest;ActorDigest=$actor
            Certificate=$profileData;Der=$der;Encrypted=$encrypted;Digest=$digest}
}
function Get-LabAuthenticatedTlsCaTrustPreview {
    [CmdletBinding()]
    param([object]$DataRoot,[object]$ControllerId,[object]$LocationId,[object]$Context,[object]$CandidateId)
    $bad=[pscustomobject][ordered]@{Success=$false;Value=$null;ErrorCode='TLS_CA_TRUST_PREVIEW_INVALID'}
    if(-not (Test-LabTlsCaCandidateInput $DataRoot $ControllerId $LocationId $Context) -or -not (Test-LabTlsRequestReference $CandidateId)){return $bad}
    $ControllerId=[guid]::Parse($ControllerId).ToString('D');$LocationId=[guid]::Parse($LocationId).ToString('D');$CandidateId=[guid]::Parse($CandidateId).ToString('D')
    try{
        $binding=Get-LabTlsCaCandidateBinding $DataRoot $ControllerId $LocationId $CandidateId
        $preexisting=Get-LabTlsCaExistingTrust $binding.Der
        $again=Get-LabTlsCaCandidateBinding $DataRoot $ControllerId $LocationId $CandidateId
        if(-not [string]::Equals($binding.Digest,$again.Digest,[StringComparison]::Ordinal)){return $bad}
        $native=$binding.Native;$profileData=$binding.Certificate
        return [pscustomobject][ordered]@{Success=$true;Value=[pscustomobject][ordered]@{Status='PRIVATE_TRUST_APPROVAL_PREVIEW';CandidateId=$CandidateId
            CertificateSha256=$profileData.Sha256;NotBeforeUtc=$profileData.NotBeforeUtc;NotAfterUtc=$profileData.NotAfterUtc;Context='CURRENT_WINDOWS_PROCESS'
            UserSid=$native.UserSid;HostMarker=$native.HostMarker;ProfilePath=$native.ProfilePath;Store='CURRENT_USER_ROOT';PreexistingTrust=$preexisting
            ApprovalEffect='Trust may affect other applications of this Windows user.';CleanupOwnership='PREEXISTING_TRUST_NEVER_OWNED'
            RegistrationStatus='NOT_EXECUTED';QualificationStatus='NOT_EXECUTED';TlsStatus='NOT_EXECUTED';SnapshotStatus='NON_ATOMIC_READ';Ready=$false;MutationAllowed=$false};ErrorCode=$null}
    }catch{if(([string]::Equals(($_.Exception.Message),('TLS_CA_CANDIDATE_NOT_SUPPORTED'),[StringComparison]::Ordinal))){$bad.ErrorCode='TLS_CA_CANDIDATE_NOT_SUPPORTED'};return $bad}
}
