#Requires -Version 7.2
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$repo=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
. (Join-Path $PSScriptRoot '../Common/CheckResult.ps1')
foreach($name in @('DiagnosticBundleReader','AuthenticatedTlsRequest','AuthenticatedTlsRegistryPayload','AuthenticatedTlsRegistryRoot','AuthenticatedTlsContext','AuthenticatedTlsCaCandidate','AuthenticatedTlsLeafCsr')){. (Join-Path $repo "Private/$name.ps1")}
$passed=0;$failures=[Collections.Generic.List[string]]::new()
$fixtureRoot=Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-tls-leaf-'+[guid]::NewGuid().ToString('N'))
$controller='11111111-1111-4111-8111-111111111111';$location='22222222-2222-4222-8222-222222222222';$context='CURRENT_WINDOWS_PROCESS'
$dataRoot=Join-Path $fixtureRoot 'root';$candidateId=$controller;$script:keyOpens=0;$script:storeCalls=0;$script:alienCalls=0
$ip=[pscustomobject]@{Kind='IP';Value='192.0.2.10'};$dns=[pscustomobject]@{Kind='DNS';Value='sql.example.test'}
$realBinding=${function:Get-LabTlsCaCandidateBinding};$realOpen=${function:Open-LabTlsCaSigningKey}
$leafRsa=$null;$weak=$null;$ec=$null
function Assert-TlsLeafClosed {param([object[]]$Result,[string]$Code='TLS_LEAF_CSR_INVALID')
    Add-CheckResult 'TLS-L01 geschlossener Fehler ohne Teilzertifikat/Rohdaten' ($Result.Count -eq 1 -and @($Result[0].PSObject.Properties).Count -eq 3 -and -not $Result[0].Success -and $null -eq $Result[0].Value -and [string]::Equals($Result[0].ErrorCode,$Code,[StringComparison]::Ordinal))
}
function Invoke-TlsLeafFixture {param($Csr,$Identity=$ip,$Days=1) New-LabAuthenticatedTlsServerLeaf $dataRoot $controller $location $context $candidateId $Csr $Identity $Days}
function New-TlsLeafFixtureCsr {param($Key,$Identity,$Hash=[Security.Cryptography.HashAlgorithmName]::SHA256,[string]$Subject='CN=SQL_Server_Lab Server Leaf',[switch]$Extra,[switch]$Utf8)
    $name=if($Utf8){[Security.Cryptography.X509Certificates.X500DistinguishedName]::new($Subject,[Security.Cryptography.X509Certificates.X500DistinguishedNameFlags]::UseUTF8Encoding)}else{[Security.Cryptography.X509Certificates.X500DistinguishedName]::new($Subject)}
    $request=[Security.Cryptography.X509Certificates.CertificateRequest]::new($name,$Key,$Hash,[Security.Cryptography.RSASignaturePadding]::Pkcs1)
    if($null -ne $Identity){$san=[Security.Cryptography.X509Certificates.SubjectAlternativeNameBuilder]::new();if($Identity.Kind -ceq 'IP'){$san.AddIpAddress([Net.IPAddress]::Parse($Identity.Value))}else{$san.AddDnsName($Identity.Value)};$request.CertificateExtensions.Add($san.Build($false))}
    if($Extra){$request.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new($true,$true,0,$true))}
    return ,$request.CreateSigningRequest()
}
function Get-TlsLeafSnapshot {return (@(Get-ChildItem -LiteralPath $fixtureRoot -Recurse -File|Sort-Object FullName|ForEach-Object {$_.FullName+':'+(Get-FileHash -LiteralPath $_.FullName).Hash}) -join '|')}
function New-TlsLeafFixtureBerKeyCsr {param([byte[]]$Original,$Key)
    $reader=[Formats.Asn1.AsnReader]::new([ReadOnlyMemory[byte]]::new($Original),[Formats.Asn1.AsnEncodingRules]::DER);$outer=$reader.ReadSequence();$info=$outer.ReadSequence()
    $version=$info.ReadEncodedValue().ToArray();$subject=$info.ReadEncodedValue().ToArray();$spki=$info.ReadEncodedValue().ToArray();$attributes=$info.ReadEncodedValue().ToArray();$signatureAlgorithm=$outer.ReadEncodedValue().ToArray()
    $reader=[Formats.Asn1.AsnReader]::new([ReadOnlyMemory[byte]]::new($spki),[Formats.Asn1.AsnEncodingRules]::DER);$sequence=$reader.ReadSequence();$algorithm=$sequence.ReadEncodedValue().ToArray();$unused=0;$keyBytes=$sequence.ReadBitString([ref]$unused)
    $reader=[Formats.Asn1.AsnReader]::new([ReadOnlyMemory[byte]]::new($keyBytes),[Formats.Asn1.AsnEncodingRules]::DER);$sequence=$reader.ReadSequence();$modulus=$sequence.ReadEncodedValue().ToArray();$exponent=$sequence.ReadEncodedValue().ToArray()
    $ber=[byte[]](@(0x30,0x80)+$modulus+$exponent+@(0,0))
    $writer=[Formats.Asn1.AsnWriter]::new([Formats.Asn1.AsnEncodingRules]::DER);$null=$writer.PushSequence();$writer.WriteEncodedValue($algorithm);$writer.WriteBitString($ber);$writer.PopSequence();$newSpki=$writer.Encode()
    $writer=[Formats.Asn1.AsnWriter]::new([Formats.Asn1.AsnEncodingRules]::DER);$null=$writer.PushSequence();foreach($part in @($version,$subject,$newSpki,$attributes)){$writer.WriteEncodedValue($part)};$writer.PopSequence();$newInfo=$writer.Encode()
    $signature=$Key.SignData($newInfo,[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $writer=[Formats.Asn1.AsnWriter]::new([Formats.Asn1.AsnEncodingRules]::DER);$null=$writer.PushSequence();$writer.WriteEncodedValue($newInfo);$writer.WriteEncodedValue($signatureAlgorithm);$writer.WriteBitString($signature);$writer.PopSequence()
    return ,$writer.Encode()
}
try{
    & {
        Set-StrictMode -Version Latest
        $script:bindingCalls=0
        function Get-LabTlsCaCandidateBinding {$script:bindingCalls++;throw 'PRIVATE_CANARY'}
        $alien=[pscustomobject]@{};$alien|Add-Member ScriptMethod ToString {$script:alienCalls++;throw 'PRIVATE_CANARY'} -Force
        try{
            foreach($bad in @($null,'csr',12,$alien,[object[]]@(1,2),[byte[]]@(),[byte[]]::new(16385))){Assert-TlsLeafClosed @(Invoke-TlsLeafFixture $bad *>&1)}
            foreach($bad in @($null,'1',0,31,[long]1,@(1),$alien)){Assert-TlsLeafClosed @(Invoke-TlsLeafFixture ([byte[]]@(1)) $ip $bad *>&1)}
            foreach($bad in @($null,$alien,[pscustomobject]@{Kind='IP';Value='0.0.0.0'},[pscustomobject]@{Kind='DNS';Value='*.example.test'},[pscustomobject]@{Kind='DNS';Value='192.0.2.10'},[pscustomobject]@{Kind='DNS';Value=('sql.example.test'+[char]0x200b)})){Assert-TlsLeafClosed @(Invoke-TlsLeafFixture ([byte[]]@(1)) $bad *>&1)}
            $scripted=[pscustomobject]@{Kind='IP';Value='192.0.2.10'};$scripted|Add-Member ScriptProperty Value {$script:alienCalls++;throw 'PRIVATE_CANARY'} -Force
            Assert-TlsLeafClosed @(Invoke-TlsLeafFixture ([byte[]]@(1)) $scripted *>&1)
            Add-CheckResult 'TLS-L01 Form/ETS/Laengen vor I/O und Keyoeffnung' ($script:bindingCalls -eq 0 -and $script:alienCalls -eq 0 -and $script:keyOpens -eq 0)
        }finally{Set-Item function:Get-LabTlsCaCandidateBinding $realBinding}
        if(-not [Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows) -or [Management.Automation.PSVersionInfo]::PSVersion -lt [version]'7.5'){
            Assert-TlsLeafClosed @(Invoke-TlsLeafFixture ([byte[]]@(1)) *>&1) 'TLS_LEAF_NOT_SUPPORTED'
            Write-Host 'TLS-L Windows-CSR-/DPAPI-/Signaturfixtures NOT_EXECUTED; keine Plattformqualifikation'
            return
        }
        $script:native=Get-LabTlsWindowsProcessFacts
        function Get-LabTlsWindowsProcessFacts {return $script:native}
        function Get-LabTlsCaStorageBase {param($Native) $null=$Native;return (Join-Path $fixtureRoot 'SQL_Server_Lab_AuthenticatedTls')}
        function Get-LabTlsCaExistingTrust {$script:storeCalls++;throw 'LEAF_MUST_NOT_READ_STORE'}
        $null=New-Item -ItemType Directory -Path (Join-Path $dataRoot 'Catalog')
        $markerPath=Join-Path $dataRoot '.sql-server-lab-root.json'
        $marker=[pscustomobject]@{ContractVersion='SqlServerLab.DataRoot/2.0';ManagedBy='SQL_Server_Lab';ControllerId=$controller;VolumeId='synthetic-volume';DataRoot=$dataRoot}
        [IO.File]::WriteAllText($markerPath,($marker|ConvertTo-Json -Compress))
        $catalog=[pscustomobject]@{ContractVersion='SqlServerLab.Storage/2.0';ControllerId=$controller;LabDataLocations=@([pscustomobject]@{LocationId=$location;ControllerId=$controller;VolumeId='synthetic-volume';LabDataRoot=$dataRoot})}
        [IO.File]::WriteAllText((Join-Path $dataRoot 'Catalog/storage-locations.json'),($catalog|ConvertTo-Json -Depth 6 -Compress))
        $candidate=New-LabAuthenticatedTlsCaCandidate $dataRoot $controller $location $context 20
        if(-not $candidate.Success){throw 'TLS_LEAF_FIXTURE_CA_FAILED'}
        $candidateId=$candidate.Value.CandidateId;$binding=Get-LabTlsCaCandidateBinding $dataRoot $controller $location $candidateId
        function Open-LabTlsCaSigningKey {param($Encrypted,$Entropy,$Der) $script:keyOpens++;return & $realOpen $Encrypted $Entropy $Der}
        $script:leafRsa=[Security.Cryptography.RSA]::Create(3072)
        $csr=New-TlsLeafFixtureCsr $script:leafRsa $ip;$snapshot=Get-TlsLeafSnapshot
        $decorated=[byte[]]$csr.Clone();$decorated|Add-Member ScriptProperty Length {$script:alienCalls++;throw 'PRIVATE_CANARY'} -Force
        $decorated|Add-Member ScriptMethod Clone {$script:alienCalls++;throw 'PRIVATE_CANARY'} -Force
        $result=Invoke-TlsLeafFixture $decorated
        Add-CheckResult 'TLS-L02 echte CSR-POP, DPAPI-Reopen und separat gepruefte Leafsignatur' ($result.Success -and $result.Value.Status -ceq 'UNREGISTERED_UNQUALIFIED' -and
            $result.Value.SignatureStatus -ceq 'VERIFIED' -and $result.Value.KeyMatchStatus -ceq 'DPAPI_REOPEN_SIGN_VERIFY' -and $script:keyOpens -eq 1 -and
            $script:alienCalls -eq 0 -and -not $result.Value.Ready -and -not $result.Value.MutationAllowed)
        if(-not $result.Success){throw 'TLS_LEAF_FIXTURE_ISSUE_FAILED'}
        $cert=[Security.Cryptography.X509Certificates.X509Certificate2]::new($result.Value.CertificateDer)
        try{
            $privateProof=[Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPublicKey($cert)
            try{$challenge=[Security.Cryptography.RandomNumberGenerator]::GetBytes(32);$proof=$script:leafRsa.SignData($challenge,[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pkcs1)
                Add-CheckResult 'TLS-L02 ausgegebenes Publicleaf passt zum ausschliesslichen CSR-Fixturekey' (-not $cert.HasPrivateKey -and $privateProof.VerifyData($challenge,$proof,[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pkcs1))
            }finally{$privateProof.Dispose()}
        }finally{$cert.Dispose()}
        $berCsr=New-TlsLeafFixtureBerKeyCsr $csr $script:leafRsa
        # Echte POP bleibt gueltig: ausschliesslich inneres PKCS1-DER ist falsch.
        $proof=[Security.Cryptography.X509Certificates.CertificateRequest]::LoadSigningRequest($berCsr,[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.X509Certificates.CertificateRequestLoadOptions]::Default,[Security.Cryptography.RSASignaturePadding]::Pkcs1)
        $script:bindingCalls=0;$before=$script:keyOpens
        function Get-LabTlsCaCandidateBinding {$script:bindingCalls++;throw 'EMBEDDED_BER_MUST_NOT_READ_CANDIDATE'}
        try{
            Assert-TlsLeafClosed @(Invoke-TlsLeafFixture $berCsr *>&1)
            Add-CheckResult 'TLS-L04 gueltig signierter BER-Key im DER-CSR vor Kandidat-/Key-I/O gesperrt' ($null -ne $proof -and $script:bindingCalls -eq 0 -and $script:keyOpens -eq $before)
        }finally{Set-Item function:Get-LabTlsCaCandidateBinding $realBinding}
        # Ausschliesslich eigener Temp-CA-Key: echtes CSR mit demselben SPKI.
        $entropy=[Text.Encoding]::UTF8.GetBytes((Get-LabTlsPayloadDigest @('SqlServerLab.TlsCaCandidateKey/0.1',$candidateId,$controller,$location,$binding.RootMetadataDigest,$binding.ActorDigest)))
        $sameKey=$null
        try{$sameKey=& $realOpen $binding.Encrypted $entropy $binding.Der;$sameCsr=New-TlsLeafFixtureCsr $sameKey $ip}
        finally{if($null -ne $sameKey){$sameKey.Dispose()}}
        $script:aliasKeyOpens=0
        function Open-LabTlsCaSigningKey {$script:aliasKeyOpens++;throw 'SAME_ISSUER_KEY_MUST_NOT_OPEN_PRIVATE_KEY'}
        try{
            Assert-TlsLeafClosed @(Invoke-TlsLeafFixture $sameCsr *>&1)
            Add-CheckResult 'TLS-L04 echter CSR mit CA-SPKI vor privater Keyoeffnung gesperrt' ($script:aliasKeyOpens -eq 0)
        }finally{function Open-LabTlsCaSigningKey {param($Encrypted,$Entropy,$Der) $script:keyOpens++;return & $realOpen $Encrypted $Entropy $Der}}
        foreach($identity in @($dns,[pscustomobject]@{Kind='IP';Value='2001:db8::10'})){
            $r=Invoke-TlsLeafFixture (New-TlsLeafFixtureCsr $script:leafRsa $identity) $identity
            Add-CheckResult 'TLS-L03 DNS/IPv6 exakt als angeforderter SAN ohne Resolver' ($r.Success -and $r.Value.Identity.Kind -ceq $identity.Kind -and $r.Value.Identity.Value -ceq $identity.Value)
        }
        $utf8Csr=New-TlsLeafFixtureCsr $script:leafRsa $ip -Utf8
        $utf8Result=Invoke-TlsLeafFixture $utf8Csr
        Add-CheckResult 'TLS-L03 fester einzelner UTF8-CN wie nativer OpenSSL-CSR mit echter POP und Leafsignatur' ($utf8Result.Success -and $utf8Result.Value.SignatureStatus -ceq 'VERIFIED' -and
            $utf8Result.Value.CsrSha256 -ceq (Get-LabTlsCaByteDigest $utf8Csr) -and -not $utf8Result.Value.Ready -and -not $utf8Result.Value.MutationAllowed)
        $before=$script:keyOpens
        $tampered=[byte[]]$csr.Clone();$tampered[$tampered.Length-1]=$tampered[$tampered.Length-1] -bxor 1
        $utf8Tampered=[byte[]]$utf8Csr.Clone();$utf8Tampered[$utf8Tampered.Length-1]=$utf8Tampered[$utf8Tampered.Length-1] -bxor 1
        $script:weak=[Security.Cryptography.RSA]::Create(2048)
        foreach($bad in @($tampered,$utf8Tampered,[byte[]]($csr+[byte]0),[byte[]]$csr[0..($csr.Length-2)],(New-TlsLeafFixtureCsr $script:weak $ip),
            (New-TlsLeafFixtureCsr $script:leafRsa $ip -Hash ([Security.Cryptography.HashAlgorithmName]::SHA384)),
            (New-TlsLeafFixtureCsr $script:leafRsa $ip -Subject 'CN=foreign.example.test'),
            (New-TlsLeafFixtureCsr $script:leafRsa $ip -Utf8 -Subject 'CN=foreign.example.test'),
            (New-TlsLeafFixtureCsr $script:leafRsa $ip -Utf8 -Subject 'CN=SQL_Server_Lab Server Leaf, O=extra'),
            (New-TlsLeafFixtureCsr $script:leafRsa $ip -Utf8 -Extra),
            (New-TlsLeafFixtureCsr $script:leafRsa $null),(New-TlsLeafFixtureCsr $script:leafRsa $ip -Extra))){Assert-TlsLeafClosed @(Invoke-TlsLeafFixture $bad *>&1)}
        Assert-TlsLeafClosed @(Invoke-TlsLeafFixture $csr $dns *>&1)
        Assert-TlsLeafClosed @(Invoke-TlsLeafFixture $csr $ip 21 *>&1)
        $script:ec=[Security.Cryptography.ECDsa]::Create([Security.Cryptography.ECCurve+NamedCurves]::nistP256)
        $ecRequest=[Security.Cryptography.X509Certificates.CertificateRequest]::new('CN=SQL_Server_Lab Server Leaf',$script:ec,[Security.Cryptography.HashAlgorithmName]::SHA256)
        Assert-TlsLeafClosed @(Invoke-TlsLeafFixture $ecRequest.CreateSigningRequest() *>&1)
        Add-CheckResult 'TLS-L04 Signatur/DER/Key/Subject/SAN/CA-Ende vor privater Keyoeffnung gesperrt' ($script:keyOpens -eq $before)
        foreach($driftCall in @(2,3)){
            $script:bindingCalls=0;$script:driftCall=$driftCall
            function Get-LabTlsCaCandidateBinding {param($DataRoot,$ControllerId,$LocationId,$CandidateId) $script:bindingCalls++;$v=& $realBinding $DataRoot $ControllerId $LocationId $CandidateId;if($script:bindingCalls -eq $script:driftCall){$v.Digest='changed'};return $v}
            try{Assert-TlsLeafClosed @(Invoke-TlsLeafFixture $csr *>&1)}finally{Set-Item function:Get-LabTlsCaCandidateBinding $realBinding}
        }
        function Open-LabTlsCaSigningKey {param($Encrypted,$Entropy,$Der) $null=$Encrypted;$null=$Entropy;$null=$Der;return [Security.Cryptography.RSA]::Create(3072)}
        try{Assert-TlsLeafClosed @(Invoke-TlsLeafFixture $csr *>&1)}finally{function Open-LabTlsCaSigningKey {param($Encrypted,$Entropy,$Der) $script:keyOpens++;return & $realOpen $Encrypted $Entropy $Der}}
        $keyPath=Join-Path $binding.Paths.Candidate 'key.dpapi';$receiptPath=Join-Path $binding.Paths.Candidate 'receipt.json'
        $oldKey=[IO.File]::ReadAllBytes($keyPath);$oldReceipt=[IO.File]::ReadAllText($receiptPath);$receipt=$oldReceipt|ConvertFrom-Json -DateKind String
        [IO.File]::WriteAllBytes($keyPath,[byte[]]@(1,2,3));$receipt.EncryptedKeySha256=Get-LabTlsCaByteDigest ([byte[]]@(1,2,3));[IO.File]::WriteAllText($receiptPath,($receipt|ConvertTo-Json -Compress))
        try{Assert-TlsLeafClosed @(Invoke-TlsLeafFixture $csr *>&1)}finally{[IO.File]::WriteAllBytes($keyPath,$oldKey);[IO.File]::WriteAllText($receiptPath,$oldReceipt)}
        $oldActor=$script:native.HostMarker;$script:native.HostMarker=[guid]::NewGuid().ToString('D')
        try{Assert-TlsLeafClosed @(Invoke-TlsLeafFixture $csr *>&1)}finally{$script:native.HostMarker=$oldActor}
        Add-CheckResult 'TLS-L05 CA-/Leaf-/Journal-/Storedateien nicht geschrieben; kein Storezugriff' ([string]::Equals($snapshot,(Get-TlsLeafSnapshot),[StringComparison]::Ordinal) -and $script:storeCalls -eq 0 -and
            @(Get-ChildItem -LiteralPath $binding.Paths.Candidate -File).Count -eq 4 -and -not (Test-Path -LiteralPath (Join-Path $binding.Paths.Location 'trust-imports')))
    }
    $err=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'Private/AuthenticatedTlsLeafCsr.ps1'),[ref]$null,[ref]$err)
    Add-CheckResult 'TLS-L06 Laden definiert nur Funktionen' ($err.Count -eq 0 -and @($ast.EndBlock.Statements|Where-Object {$_ -isnot [Management.Automation.Language.FunctionDefinitionAst]}).Count -eq 0)
    Add-CheckResult 'TLS-L06 keine Store-/Provider-/Dateischreib-/C#- oder neue Leafkeyaktion' ($ast.Extent.Text -notmatch '(?i)X509Store|Get-LabTlsCaExistingTrust|Add-Type|WriteAll|Write-LabTls|::Create\(3072\)|CreateSelfSigned|Remove-Item|Invoke-Sqlcmd|Start-Process')
    Write-Host "Authenticated TLS Leaf CSR: $passed PASS, $($failures.Count) FAIL; native Target/SQL/TLS NOT_EXECUTED"
    if($failures.Count){throw 'AUTHENTICATED_TLS_LEAF_CSR_CHECKS_FAILED'}
}finally{
    foreach($resource in @($script:leafRsa,$script:weak,$script:ec)){if($null -ne $resource){$resource.Dispose()}}
    $full=[IO.Path]::GetFullPath($fixtureRoot);$prefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    if(-not $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -cnotmatch '\Asql-lab-tls-leaf-[a-f0-9]{32}\z'){throw 'TLS_LEAF_FIXTURE_CLEANUP_BOUNDARY'}
    if(Test-Path -LiteralPath $full){Remove-Item -LiteralPath $full -Recurse -Force}
    if(Test-Path -LiteralPath $full){throw 'TLS_LEAF_FIXTURE_CLEANUP_FAILED'}
    Write-Host 'TLS-L eigene private CA-/CSRfixtures CLEANED'
}
