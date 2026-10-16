#Requires -Version 7.2
# Enger CSR-Kryptovertrag, keine native Target-/SQL-/Trustautorisierung.

function Assert-LabTlsLeafSan {
    param([byte[]]$Der,[object]$Identity)
    $reader=[Formats.Asn1.AsnReader]::new([ReadOnlyMemory[byte]]::new($Der),[Formats.Asn1.AsnEncodingRules]::DER)
    $names=$reader.ReadSequence()
    if(Test-LabTlsRequestEnum $Identity.Kind @('IP')){
        $actual=$names.ReadOctetString([Formats.Asn1.Asn1Tag]::new([Formats.Asn1.TagClass]::ContextSpecific,7))
        $expected=[Net.IPAddress]::Parse($Identity.Value).GetAddressBytes()
        if(-not [string]::Equals([Convert]::ToBase64String($actual),[Convert]::ToBase64String($expected),[StringComparison]::Ordinal)){throw 'TLS_LEAF_CSR_INVALID'}
    }else{
        $actual=$names.ReadCharacterString([Formats.Asn1.UniversalTagNumber]::IA5String,[Formats.Asn1.Asn1Tag]::new([Formats.Asn1.TagClass]::ContextSpecific,2))
        if(-not [string]::Equals($actual,$Identity.Value,[StringComparison]::Ordinal)){throw 'TLS_LEAF_CSR_INVALID'}
    }
    if($reader.HasData -or $names.HasData){throw 'TLS_LEAF_CSR_INVALID'}
}

function Read-LabTlsServerLeafCsr {
    param([byte[]]$Der,[object]$Identity)
    $reader=[Formats.Asn1.AsnReader]::new([ReadOnlyMemory[byte]]::new($Der),[Formats.Asn1.AsnEncodingRules]::DER)
    $outer=$reader.ReadSequence();$info=$outer.ReadSequence()
    if($info.ReadInteger() -ne 0){throw 'TLS_LEAF_CSR_INVALID'}
    $subject=$info.ReadEncodedValue().ToArray()
    $expectedSubject=[Security.Cryptography.X509Certificates.X500DistinguishedName]::new('CN=SQL_Server_Lab Server Leaf')
    $expectedUtf8Subject=[Security.Cryptography.X509Certificates.X500DistinguishedName]::new('CN=SQL_Server_Lab Server Leaf',[Security.Cryptography.X509Certificates.X500DistinguishedNameFlags]::UseUTF8Encoding)
    $subjectDigest=Get-LabTlsCaByteDigest $subject
    # Derselbe feste einzelne CN: native OpenSSL-UTF8- oder bisherige BCL-DER-Form.
    if(-not [string]::Equals($subjectDigest,(Get-LabTlsCaByteDigest $expectedSubject.RawData),[StringComparison]::Ordinal) -and
        -not [string]::Equals($subjectDigest,(Get-LabTlsCaByteDigest $expectedUtf8Subject.RawData),[StringComparison]::Ordinal)){throw 'TLS_LEAF_CSR_INVALID'}
    $spkiBytes=$info.ReadEncodedValue().ToArray()
    $keyReader=[Formats.Asn1.AsnReader]::new([ReadOnlyMemory[byte]]::new($spkiBytes),[Formats.Asn1.AsnEncodingRules]::DER)
    $spki=$keyReader.ReadSequence();$algorithm=$spki.ReadSequence()
    if(-not (Test-LabTlsRequestEnum ($algorithm.ReadObjectIdentifier()) @('1.2.840.113549.1.1.1'))){throw 'TLS_LEAF_CSR_INVALID'}
    $algorithm.ReadNull();$unused=0;$keyBytes=$spki.ReadBitString([ref]$unused)
    if($algorithm.HasData -or $spki.HasData -or $keyReader.HasData -or $unused -ne 0){throw 'TLS_LEAF_CSR_INVALID'}
    # Der BITSTRING-Inhalt ist selbst PKCS1-DER; BCL-Import allein akzeptiert BER.
    $pkcs1=[Formats.Asn1.AsnReader]::new([ReadOnlyMemory[byte]]::new($keyBytes),[Formats.Asn1.AsnEncodingRules]::DER)
    $keySequence=$pkcs1.ReadSequence();$modulus=$keySequence.ReadInteger();$exponent=$keySequence.ReadInteger()
    if($pkcs1.HasData -or $keySequence.HasData -or $modulus.Sign -le 0 -or $exponent.Sign -le 0){throw 'TLS_LEAF_CSR_INVALID'}
    $attributes=$info.ReadSetOf($false,[Formats.Asn1.Asn1Tag]::new([Formats.Asn1.TagClass]::ContextSpecific,0,$true))
    $attribute=$attributes.ReadSequence()
    if(-not (Test-LabTlsRequestEnum ($attribute.ReadObjectIdentifier()) @('1.2.840.113549.1.9.14'))){throw 'TLS_LEAF_CSR_INVALID'}
    $values=$attribute.ReadSetOf();$extensions=$values.ReadSequence();$extension=$extensions.ReadSequence()
    if(-not (Test-LabTlsRequestEnum ($extension.ReadObjectIdentifier()) @('2.5.29.17'))){throw 'TLS_LEAF_CSR_INVALID'}
    # Genau ein nichtkritischer SAN; BOOLEAN TRUE oder weitere Extensions sperren.
    $san=$extension.ReadOctetString();Assert-LabTlsLeafSan $san $Identity
    if($extension.HasData -or $extensions.HasData -or $values.HasData -or $attribute.HasData -or $attributes.HasData -or $info.HasData){throw 'TLS_LEAF_CSR_INVALID'}
    $signatureAlgorithm=$outer.ReadSequence()
    if(-not (Test-LabTlsRequestEnum ($signatureAlgorithm.ReadObjectIdentifier()) @('1.2.840.113549.1.1.11'))){throw 'TLS_LEAF_CSR_INVALID'}
    $signatureAlgorithm.ReadNull();$unused=0;$null=$outer.ReadBitString([ref]$unused)
    if($signatureAlgorithm.HasData -or $outer.HasData -or $reader.HasData -or $unused -ne 0){throw 'TLS_LEAF_CSR_INVALID'}
    $rsa=$null
    try{
        # Nur PublicKey importieren. Groesse/Exponent begrenzen den Aufwand der
        # anschliessenden POP-Pruefung, bevor fremde grosse Exponenten wirken.
        $rsa=[Security.Cryptography.RSA]::Create();$consumed=0;$rsa.ImportSubjectPublicKeyInfo($spkiBytes,[ref]$consumed)
        if($consumed -ne $spkiBytes.Length -or $rsa.KeySize -ne 3072 -or -not [string]::Equals([Convert]::ToBase64String($rsa.ExportParameters($false).Exponent),'AQAB',[StringComparison]::Ordinal)){throw 'TLS_LEAF_CSR_INVALID'}
        # Default prueft die echte Signatur und uebernimmt keine Extensions.
        $loaded=[Security.Cryptography.X509Certificates.CertificateRequest]::LoadSigningRequest($Der,[Security.Cryptography.HashAlgorithmName]::SHA256,
            [Security.Cryptography.X509Certificates.CertificateRequestLoadOptions]::Default,[Security.Cryptography.RSASignaturePadding]::Pkcs1)
        if($loaded.CertificateExtensions.Count -ne 0){throw 'TLS_LEAF_CSR_INVALID'}
        return [pscustomobject]@{PublicKey=$loaded.PublicKey;Spki=$rsa.ExportSubjectPublicKeyInfo()}
    }finally{if($null -ne $rsa){$rsa.Dispose()}}
}

function Assert-LabTlsServerLeafCertificate {
    param([byte[]]$Der,[byte[]]$Spki,[object]$Identity,[byte[]]$CaDer,[DateTimeOffset]$NotBefore,[DateTimeOffset]$NotAfter)
    $certificate=$null;$ca=$null;$public=$null;$issuer=$null
    try{
        $certificate=[Security.Cryptography.X509Certificates.X509Certificate2]::new($Der)
        $ca=[Security.Cryptography.X509Certificates.X509Certificate2]::new($CaDer)
        $subject=[Security.Cryptography.X509Certificates.X500DistinguishedName]::new('CN=SQL_Server_Lab Server Leaf')
        if($certificate.HasPrivateKey -or $certificate.RawData.Length -ne $Der.Length -or
            -not [string]::Equals((Get-LabTlsCaByteDigest $certificate.RawData),(Get-LabTlsCaByteDigest $Der),[StringComparison]::Ordinal) -or
            -not [string]::Equals((Get-LabTlsCaByteDigest $certificate.SubjectName.RawData),(Get-LabTlsCaByteDigest $subject.RawData),[StringComparison]::Ordinal) -or
            -not [string]::Equals((Get-LabTlsCaByteDigest $certificate.IssuerName.RawData),(Get-LabTlsCaByteDigest $ca.SubjectName.RawData),[StringComparison]::Ordinal) -or
            -not (Test-LabTlsRequestEnum $certificate.SignatureAlgorithm.Value @('1.2.840.113549.1.1.11')) -or
            $certificate.NotBefore.ToUniversalTime().Ticks -ne $NotBefore.UtcTicks -or $certificate.NotAfter.ToUniversalTime().Ticks -ne $NotAfter.UtcTicks -or
            $NotAfter -le $NotBefore -or ($NotAfter-$NotBefore).TotalDays -gt 30 -or $NotAfter.UtcDateTime -gt $ca.NotAfter.ToUniversalTime() -or
            $NotBefore.UtcDateTime -lt $ca.NotBefore.ToUniversalTime() -or $certificate.Extensions.Count -ne 4){throw 'TLS_LEAF_CERTIFICATE_INVALID'}
        $byOid=@{}
        foreach($extension in $certificate.Extensions){if($byOid.ContainsKey($extension.Oid.Value)){throw 'TLS_LEAF_CERTIFICATE_INVALID'};$byOid.Add($extension.Oid.Value,$extension)}
        foreach($oid in @('2.5.29.19','2.5.29.15','2.5.29.37','2.5.29.17')){if(-not $byOid.ContainsKey($oid)){throw 'TLS_LEAF_CERTIFICATE_INVALID'}}
        if(-not $byOid['2.5.29.19'].Critical -or $byOid['2.5.29.19'].CertificateAuthority -or $byOid['2.5.29.19'].HasPathLengthConstraint -or
            -not $byOid['2.5.29.15'].Critical -or $byOid['2.5.29.15'].KeyUsages -ne [Security.Cryptography.X509Certificates.X509KeyUsageFlags]'DigitalSignature, KeyEncipherment' -or
            $byOid['2.5.29.37'].Critical -or $byOid['2.5.29.37'].EnhancedKeyUsages.Count -ne 1 -or
            -not (Test-LabTlsRequestEnum $byOid['2.5.29.37'].EnhancedKeyUsages[0].Value @('1.3.6.1.5.5.7.3.1')) -or $byOid['2.5.29.17'].Critical){throw 'TLS_LEAF_CERTIFICATE_INVALID'}
        Assert-LabTlsLeafSan $byOid['2.5.29.17'].RawData $Identity
        $public=[Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPublicKey($certificate)
        if($null -eq $public -or $public.KeySize -ne 3072 -or -not [string]::Equals((Get-LabTlsCaByteDigest $public.ExportSubjectPublicKeyInfo()),(Get-LabTlsCaByteDigest $Spki),[StringComparison]::Ordinal)){throw 'TLS_LEAF_CERTIFICATE_INVALID'}
        $reader=[Formats.Asn1.AsnReader]::new([ReadOnlyMemory[byte]]::new($Der),[Formats.Asn1.AsnEncodingRules]::DER)
        $sequence=$reader.ReadSequence();$tbs=$sequence.ReadEncodedValue().ToArray();$null=$sequence.ReadEncodedValue();$unused=0;$signature=$sequence.ReadBitString([ref]$unused)
        $issuer=[Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPublicKey($ca)
        if($reader.HasData -or $sequence.HasData -or $unused -ne 0 -or -not $issuer.VerifyData($tbs,$signature,[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pkcs1)){throw 'TLS_LEAF_CERTIFICATE_INVALID'}
    }finally{foreach($resource in @($issuer,$public,$ca,$certificate)){if($null -ne $resource){$resource.Dispose()}}}
}

function New-LabAuthenticatedTlsServerLeaf {
    [CmdletBinding()]
    param([object]$DataRoot,[object]$ControllerId,[object]$LocationId,[object]$Context,[object]$CandidateId,[object]$CsrDer,[object]$Identity,[object]$ValidityDays)
    $bad=[pscustomobject][ordered]@{Success=$false;Value=$null;ErrorCode='TLS_LEAF_CSR_INVALID'}
    if(-not (Test-LabTlsCaCandidateInput $DataRoot $ControllerId $LocationId $Context) -or -not (Test-LabTlsRequestReference $CandidateId) -or
        $CsrDer -isnot [byte[]] -or $ValidityDays -isnot [int] -or $ValidityDays -lt 1 -or $ValidityDays -gt 30){return $bad}
    $length=[array].GetProperty('Length').GetValue($CsrDer)
    if($length -lt 1 -or $length -gt 16384){return $bad}
    $selected=Get-LabTlsRequestIdentity $Identity;if($null -eq $selected){return $bad}
    $selected=[pscustomobject]@{Kind=[string]::Concat($selected.Kind);Value=[string]::Concat($selected.Value)}
    $ControllerId=[guid]::Parse($ControllerId).ToString('D');$LocationId=[guid]::Parse($LocationId).ToString('D');$CandidateId=[guid]::Parse($CandidateId).ToString('D')
    $bytes=[byte[]]::new($length);[Buffer]::BlockCopy($CsrDer,0,$bytes,0,$length)
    $key=$null;$ca=$null;$caPublic=$null;$leaf=$null
    try{
        Assert-LabTlsCaCandidateCapability
        $csr=Read-LabTlsServerLeafCsr $bytes $selected
        $binding=Get-LabTlsCaCandidateBinding $DataRoot $ControllerId $LocationId $CandidateId
        $ca=[Security.Cryptography.X509Certificates.X509Certificate2]::new($binding.Der)
        $caPublic=[Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPublicKey($ca)
        # CA und Leaf muessen getrennte Keys haben, vor privater CA-Keyoeffnung.
        if([string]::Equals([Convert]::ToBase64String($csr.Spki),[Convert]::ToBase64String($caPublic.ExportSubjectPublicKeyInfo()),[StringComparison]::Ordinal)){return $bad}
        $ticks=[datetime]::UtcNow.Ticks;$begin=[DateTimeOffset]::new(($ticks-($ticks%[timespan]::TicksPerSecond)),[timespan]::Zero);$end=$begin.AddDays($ValidityDays)
        if($begin.UtcDateTime -lt $ca.NotBefore.ToUniversalTime() -or $end.UtcDateTime -gt $ca.NotAfter.ToUniversalTime()){return $bad}
        $again=Get-LabTlsCaCandidateBinding $DataRoot $ControllerId $LocationId $CandidateId
        if(-not [string]::Equals($binding.Digest,$again.Digest,[StringComparison]::Ordinal)){return $bad}
        $entropy=[Text.Encoding]::UTF8.GetBytes((Get-LabTlsPayloadDigest @('SqlServerLab.TlsCaCandidateKey/0.1',$CandidateId,$ControllerId,$LocationId,$binding.RootMetadataDigest,$binding.ActorDigest)))
        $key=Open-LabTlsCaSigningKey $again.Encrypted $entropy $again.Der
        $request=[Security.Cryptography.X509Certificates.CertificateRequest]::new([Security.Cryptography.X509Certificates.X500DistinguishedName]::new('CN=SQL_Server_Lab Server Leaf'),
            $csr.PublicKey,[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pkcs1)
        $request.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new($false,$false,0,$true))
        $request.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509KeyUsageExtension]::new([Security.Cryptography.X509Certificates.X509KeyUsageFlags]'DigitalSignature, KeyEncipherment',$true))
        $usages=[Security.Cryptography.OidCollection]::new();$null=$usages.Add([Security.Cryptography.Oid]::new('1.3.6.1.5.5.7.3.1'))
        $request.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]::new($usages,$false))
        $san=[Security.Cryptography.X509Certificates.SubjectAlternativeNameBuilder]::new()
        if(Test-LabTlsRequestEnum $selected.Kind @('IP')){$san.AddIpAddress([Net.IPAddress]::Parse($selected.Value))}else{$san.AddDnsName($selected.Value)}
        $request.CertificateExtensions.Add($san.Build($false))
        $serial=[Security.Cryptography.RandomNumberGenerator]::GetBytes(16);$serial[0]=($serial[0] -band 0x7f) -bor 1
        $generator=[Security.Cryptography.X509Certificates.X509SignatureGenerator]::CreateForRSA($key,[Security.Cryptography.RSASignaturePadding]::Pkcs1)
        $leaf=$request.Create($ca.SubjectName,$generator,$begin,$end,$serial);$der=$leaf.Export([Security.Cryptography.X509Certificates.X509ContentType]::Cert)
        Assert-LabTlsServerLeafCertificate $der $csr.Spki $selected $again.Der $begin $end
        $after=Get-LabTlsCaCandidateBinding $DataRoot $ControllerId $LocationId $CandidateId
        if(-not [string]::Equals($binding.Digest,$after.Digest,[StringComparison]::Ordinal)){return $bad}
        return [pscustomobject][ordered]@{Success=$true;Value=[pscustomobject][ordered]@{Status='UNREGISTERED_UNQUALIFIED';CertificateDer=$der
            CertificateSha256=(Get-LabTlsCaByteDigest $der);CsrSha256=(Get-LabTlsCaByteDigest $bytes);CaCertificateSha256=$binding.Certificate.Sha256
            Identity=$selected;NotBeforeUtc=$begin.UtcDateTime.ToString('O');NotAfterUtc=$end.UtcDateTime.ToString('O');KeyMatchStatus='DPAPI_REOPEN_SIGN_VERIFY'
            SignatureStatus='VERIFIED';NativeTargetStatus='NOT_EXECUTED';RegistrationStatus='NOT_EXECUTED';TlsStatus='NOT_EXECUTED';Ready=$false;MutationAllowed=$false};ErrorCode=$null}
    }catch{if(Test-LabTlsRequestEnum $_.Exception.Message @('TLS_CA_CANDIDATE_NOT_SUPPORTED')){$bad.ErrorCode='TLS_LEAF_NOT_SUPPORTED'};return $bad}
    finally{foreach($resource in @($leaf,$caPublic,$ca,$key)){if($null -ne $resource){$resource.Dispose()}}}
}
