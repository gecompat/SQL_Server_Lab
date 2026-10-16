#Requires -Version 7.2
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$repo=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
. (Join-Path $PSScriptRoot '../Common/CheckResult.ps1')
foreach($name in @('AuthenticatedTlsRequest','AuthenticatedTlsRegistryIndex','AuthenticatedTlsRegistryPayload','AuthenticatedTlsRegistryDocument')){. (Join-Path $repo "Private/$name.ps1")}
$passed=0;$failures=[Collections.Generic.List[string]]::new()
function Get-TlsDocumentFixtureRef {param([int]$Number) return ('00000000-0000-4000-8000-{0:d12}' -f $Number)}
function Get-TlsDocumentFixturePayload {
    param([string]$Kind='CLIENT_CONTEXT',[int]$Number=1)
    $p=[ordered]@{ContractVersion='SqlServerLab.AuthenticatedTlsRegistryPayload/0.1';ControllerId='11111111-1111-4111-8111-111111111111';LocationId='22222222-2222-4222-8222-222222222222';Kind=$Kind;Ref=(Get-TlsDocumentFixtureRef $Number);Generation=1;Status='ACTIVE'}
    if($Kind -ceq 'AUTHORITY'){
        $p.TrustScopeRef=Get-TlsDocumentFixtureRef 9;$p.SignerContextRef=Get-TlsDocumentFixtureRef 2;$p.SignerGeneration=1;$p.KeyStatus='NOT_CREATED';$p.CertificateStatus='NOT_CREATED'
    }else{
        $p.Context='CURRENT_WINDOWS_PROCESS';$p.Actor=[pscustomobject]@{UserSid='S-1-5-21-100-200-300-1001';HostMarker='77777777-7777-4777-8777-777777777777';ProfilePath='C:\lab\profile'}
        if($Kind -ceq 'CLIENT_CONTEXT'){
            $p.Details=[pscustomobject]@{Store='CURRENT_USER_ROOT';ClientStacks=@('SYSTEM_DATA_SQLCLIENT','ODBC_SQLCMD');SqlClientPath='C:\lab\System.Data.SqlClient.dll';SqlClientDiskSha256=('a'*64);SqlClientDiskBytes=123;
                SqlClientAssembly='System.Data.SqlClient, Version=4.8.0.0, Culture=neutral, PublicKeyToken=b03f5f7f11d50a3a';SqlClientLoadedMvid='88888888-8888-4888-8888-888888888888';SqlcmdPath='C:\lab\sqlcmd.exe';SqlcmdDiskSha256=('b'*64);SqlcmdDiskBytes=456;
                BinaryEvidence='ON_DISK_BYTES_ONLY';LoadedImageDigestStatus='NOT_MEASURED';SqlcmdFlavorStatus='NOT_QUALIFIED';LoadedOdbcDriverStatus='NOT_EXECUTED'}
        }else{$p.Details=[pscustomobject]@{Backend='DOTNET_X509';RuntimeVersion='10.0.12';ApiStatus='COMPLETE';Apis=@('REQUEST_RSA_CONSTRUCTOR','CSR_CREATE_DER','CSR_LOAD_DER','CERTIFICATE_CREATE','SAN_IP','SAN_DNS'|ForEach-Object {[pscustomobject]@{Id=$_;Present=$true}});KeyProtectionStatus='NOT_EVALUATED'}}
    }
    return [pscustomobject]$p
}
function Get-TlsDocumentFixtureBytes {param([object]$Value) return ,[Text.UTF8Encoding]::new($false,$true).GetBytes(($Value|ConvertTo-Json -Depth 16 -Compress))}
function Update-TlsDocumentFixtureIndex {
    param([object]$Value)
    $Value.Index.Records=@(foreach($payload in $Value.Payloads){$r=Read-LabAuthenticatedTlsRegistryPayload (Get-TlsDocumentFixtureBytes $payload);if(-not $r.Success){throw 'TLS_DOCUMENT_FIXTURE_INVALID'};$r.Value.IndexRecord})
}
function Get-TlsDocumentFixture {
    $payloads=@((Get-TlsDocumentFixturePayload CLIENT_CONTEXT 1),(Get-TlsDocumentFixturePayload SIGNER_CONTEXT 2),(Get-TlsDocumentFixturePayload AUTHORITY 3))
    $value=[pscustomobject][ordered]@{ContractVersion='SqlServerLab.AuthenticatedTlsContextRegistry/0.1';Index=[pscustomobject]@{ContractVersion='SqlServerLab.AuthenticatedTlsRegistryIndex/0.1';ControllerId=$payloads[0].ControllerId;LocationId=$payloads[0].LocationId;Revision=1;Records=@()};Payloads=$payloads}
    Update-TlsDocumentFixtureIndex $value
    return $value
}
function Assert-TlsDocumentRejected {
    param([object]$Bytes)
    $all=@(Read-LabAuthenticatedTlsRegistryDocument $Bytes *>&1)
    Add-CheckResult 'TLS-D01 geschlossene Ablehnung ohne Rohdiagnose' ($all.Count -eq 1 -and -not $all[0].Success -and $null -eq $all[0].Value -and $all[0].ErrorCode -ceq 'TLS_REGISTRY_DOCUMENT_INVALID' -and ($all|ConvertTo-Json -Compress) -notmatch 'TLS_DOCUMENT_PRIVATE_CANARY')
}
function Assert-TlsDocumentTransition {
    param([object]$Before,[object]$After,[bool]$Expected)
    $all=@(Test-LabAuthenticatedTlsRegistryDocumentTransition (Get-TlsDocumentFixtureBytes $Before) (Get-TlsDocumentFixtureBytes $After) *>&1)
    $ok=$all.Count -eq 1 -and $all[0].Success -eq $Expected
    if($Expected){$ok=$ok -and $null -eq $all[0].ErrorCode -and $all[0].Value.Status -ceq 'OFFLINE_REGISTRY_TRANSITION_ONLY' -and
        $all[0].Value.RootBindingStatus -ceq 'NOT_EVALUATED' -and $all[0].Value.NativeBindingStatus -ceq 'NOT_EXECUTED' -and
        $all[0].Value.RegistrationStatus -ceq 'NOT_EXECUTED' -and $all[0].Value.QualificationStatus -ceq 'NOT_EXECUTED' -and -not $all[0].Value.Ready -and -not $all[0].Value.MutationAllowed}
    else{$ok=$ok -and $null -eq $all[0].Value -and $all[0].ErrorCode -ceq 'TLS_REGISTRY_DOCUMENT_TRANSITION_INVALID'}
    Add-CheckResult "TLS-D05 Uebergang erwartet $Expected" $ok
}
$script:nativeCalls=0
function Get-LabAuthenticatedTlsContextPreview {param($Request) $script:nativeCalls++;throw 'TLS_DOCUMENT_PRIVATE_CANARY native call'}
& {
    Set-StrictMode -Version Latest
    $fixture=Get-TlsDocumentFixture;$bytes=Get-TlsDocumentFixtureBytes $fixture
    $result=Read-LabAuthenticatedTlsRegistryDocument $bytes
    Add-CheckResult 'TLS-D01 geschlossene private Projektion' ($result.Success -and @($result.PSObject.Properties).Count -eq 3 -and @($result.Value.PSObject.Properties).Count -eq 9 -and
        $result.Value.Status -ceq 'OFFLINE_REGISTRY_ONLY' -and $result.Value.ContentDigest -cmatch '\A[0-9a-f]{64}\z' -and
        $result.Value.RootBindingStatus -ceq 'NOT_EVALUATED' -and $result.Value.NativeBindingStatus -ceq 'NOT_EXECUTED' -and $result.Value.RegistrationStatus -ceq 'NOT_EXECUTED' -and
        $result.Value.QualificationStatus -ceq 'NOT_EXECUTED' -and -not $result.Value.Ready -and -not $result.Value.MutationAllowed)
    [array]::Clear($bytes,0,$bytes.Length)
    Add-CheckResult 'TLS-D01 frische Daten ohne Callerbytes/JsonElement' ($result.Value.RegistryDocument.Payloads.Count -eq 3 -and $result.Value.RegistryDocument.Payloads[0].Actor.ProfilePath -ceq 'C:\lab\profile')
    foreach($name in @('ContractVersion','Index','Payloads')){
        $bad=Get-TlsDocumentFixture;$bad.PSObject.Properties.Remove($name);Assert-TlsDocumentRejected (Get-TlsDocumentFixtureBytes $bad)
        $bad=Get-TlsDocumentFixture;$bad.$name=$null;Assert-TlsDocumentRejected (Get-TlsDocumentFixtureBytes $bad)
    }
    foreach($extra in @('Ready','RootBinding','ContentDigest','NativePreview','StateRoot')){$bad=Get-TlsDocumentFixture;$bad|Add-Member NoteProperty $extra 'TLS_DOCUMENT_PRIVATE_CANARY';Assert-TlsDocumentRejected (Get-TlsDocumentFixtureBytes $bad)}
    $raw=$fixture|ConvertTo-Json -Depth 16 -Compress
    foreach($json in @($raw.Replace('"Index":','"index":{},"Index":'),$raw.Replace('"Payloads":','"Paylo\u0061ds":[],"Payloads":'),
        $raw.Replace('"Generation":1','"Generation":1,"Generation":2'),($raw+',0'),($raw.TrimEnd('}')+',}'),('['*9+'0'+']'*9),'[]','null')){
        Assert-TlsDocumentRejected ([Text.Encoding]::UTF8.GetBytes($json))
    }
    foreach($inputValue in @($null,'TLS_DOCUMENT_PRIVATE_CANARY',1,@{},[byte[]]@(),[byte[]]@(0xc3,0x28),[byte[]]::new(4194305))){Assert-TlsDocumentRejected $inputValue}
    Assert-TlsDocumentRejected ([byte[]](@(0xef,0xbb,0xbf)+[Text.Encoding]::UTF8.GetBytes($raw)))
    $script:foreign=0;$alien=[pscustomobject]@{};$alien|Add-Member ScriptMethod ToString {$script:foreign++;throw 'TLS_DOCUMENT_PRIVATE_CANARY'} -Force;Assert-TlsDocumentRejected $alien
    $decorated=Get-TlsDocumentFixtureBytes $fixture;$decorated|Add-Member ScriptProperty Length {$script:foreign++;throw 'TLS_DOCUMENT_PRIVATE_CANARY Length'} -Force
    Add-CheckResult 'TLS-D02 native Bytearraylaenge statt ETS-Getter' (Read-LabAuthenticatedTlsRegistryDocument $decorated).Success
    Add-CheckResult 'TLS-D02 keine fremden Getter/Casts' ($script:foreign -eq 0)
    $padded=$raw+(' '*(4194304-[Text.Encoding]::UTF8.GetByteCount($raw)))
    Add-CheckResult 'TLS-D02 exakte 4MiB-Bytegrenze' (Read-LabAuthenticatedTlsRegistryDocument ([Text.Encoding]::UTF8.GetBytes($padded))).Success
    Assert-TlsDocumentRejected ([Text.Encoding]::UTF8.GetBytes($padded+' '))
    foreach($change in @('missing','extra','duplicate','foreignRef','controller','location','role','generation','status','identity','revision','signerRef','signerGeneration','payloadChange')){
        $bad=Get-TlsDocumentFixture
        switch($change){
            missing {$bad.Payloads=$bad.Payloads[0..1]}
            extra {$bad.Payloads+=Get-TlsDocumentFixturePayload CLIENT_CONTEXT 4}
            duplicate {$bad.Payloads[1]=$bad.Payloads[0]}
            foreignRef {$bad.Payloads[0].Ref=Get-TlsDocumentFixtureRef 8}
            controller {$bad.Payloads[0].ControllerId=Get-TlsDocumentFixtureRef 8}
            location {$bad.Payloads[0].LocationId=Get-TlsDocumentFixtureRef 8}
            role {$bad.Index.Records[0].Kind='SIGNER_CONTEXT'}
            generation {$bad.Index.Records[0].Generation=2}
            status {$bad.Index.Records[0].Status='RETIRED'}
            identity {$bad.Index.Records[0].IdentityDigest='c'*64}
            revision {$bad.Index.Records[0].RevisionDigest='c'*64}
            signerRef {$bad.Payloads[2].SignerContextRef=Get-TlsDocumentFixtureRef 1}
            signerGeneration {$bad.Payloads[2].SignerGeneration=2}
            payloadChange {$bad.Payloads[0].Details.SqlcmdDiskSha256='c'*64}
        }
        Assert-TlsDocumentRejected (Get-TlsDocumentFixtureBytes $bad)
    }
    $empty=Get-TlsDocumentFixture;$empty.Index.Revision=0;$empty.Index.Records=@();$empty.Payloads=@()
    Add-CheckResult 'TLS-D02 leerer vollstaendiger Anfangsstand' (Read-LabAuthenticatedTlsRegistryDocument (Get-TlsDocumentFixtureBytes $empty)).Success
    $limit=Get-TlsDocumentFixture;$limit.Payloads=@(1..256|ForEach-Object {Get-TlsDocumentFixturePayload CLIENT_CONTEXT $_});Update-TlsDocumentFixtureIndex $limit
    Add-CheckResult 'TLS-D02 256 exakt zugeordnete Payloads' (Read-LabAuthenticatedTlsRegistryDocument (Get-TlsDocumentFixtureBytes $limit)).Success
    $limit.Payloads+=Get-TlsDocumentFixturePayload CLIENT_CONTEXT 257;Assert-TlsDocumentRejected (Get-TlsDocumentFixtureBytes $limit)
    $bad=Get-TlsDocumentFixture;$bad.Payloads[0].Details|Add-Member NoteProperty Extra 'TLS_DOCUMENT_PRIVATE_CANARY';Assert-TlsDocumentRejected (Get-TlsDocumentFixtureBytes $bad)
    $saved=[Threading.Thread]::CurrentThread.CurrentCulture
    try{foreach($culture in @('en-US','de-DE','tr-TR')){
        [Threading.Thread]::CurrentThread.CurrentCulture=[Globalization.CultureInfo]::GetCultureInfo($culture)
        foreach($char in @([char]0x200b,[char]0x00ad)){
            $bad=Get-TlsDocumentFixture;$bad.ContractVersion+=$char;Assert-TlsDocumentRejected (Get-TlsDocumentFixtureBytes $bad)
            $bad=Get-TlsDocumentFixture;$bad.Payloads[0].Status+=$char;Assert-TlsDocumentRejected (Get-TlsDocumentFixtureBytes $bad)
        }
        Add-CheckResult 'TLS-D03 kulturunabhaengiger Inhaltsdigest' ((Read-LabAuthenticatedTlsRegistryDocument (Get-TlsDocumentFixtureBytes $fixture)).Value.ContentDigest -ceq $result.Value.ContentDigest)
    }}finally{[Threading.Thread]::CurrentThread.CurrentCulture=$saved}
    $reordered=Get-TlsDocumentFixture;[array]::Reverse($reordered.Payloads);[array]::Reverse($reordered.Index.Records)
    $orderedResult=Read-LabAuthenticatedTlsRegistryDocument (Get-TlsDocumentFixtureBytes $reordered)
    Add-CheckResult 'TLS-D03 Reihenfolge von Payloads und Index irrelevant' ($orderedResult.Success -and $orderedResult.Value.ContentDigest -ceq $result.Value.ContentDigest)
    $pretty=[Text.Encoding]::UTF8.GetBytes(($fixture|ConvertTo-Json -Depth 16))
    Add-CheckResult 'TLS-D03 JSON-Whitespace ist kein Inhaltswechsel' ((Read-LabAuthenticatedTlsRegistryDocument $pretty).Value.ContentDigest -ceq $result.Value.ContentDigest)
    $changed=Get-TlsDocumentFixture;$changed.Index.Revision=2
    Add-CheckResult 'TLS-D03 Indexrevision ist im Dokumentdigest' ((Read-LabAuthenticatedTlsRegistryDocument (Get-TlsDocumentFixtureBytes $changed)).Value.ContentDigest -cne $result.Value.ContentDigest)
    $changed=Get-TlsDocumentFixture;$changed.Payloads[0].Status='RETIRED';Update-TlsDocumentFixtureIndex $changed
    Add-CheckResult 'TLS-D03 Retirement ist im Dokumentdigest' ((Read-LabAuthenticatedTlsRegistryDocument (Get-TlsDocumentFixtureBytes $changed)).Value.ContentDigest -cne $result.Value.ContentDigest)
    $changed=Get-TlsDocumentFixture;$changed.Payloads[0].Generation=2;Update-TlsDocumentFixtureIndex $changed
    Add-CheckResult 'TLS-D03 Generation ist im Dokumentdigest' ((Read-LabAuthenticatedTlsRegistryDocument (Get-TlsDocumentFixtureBytes $changed)).Value.ContentDigest -cne $result.Value.ContentDigest)
    $history=Get-TlsDocumentFixture;$history.Payloads[1].Generation=2;$history.Payloads[1].Details.RuntimeVersion='10.0.13';$history.Payloads[2].Status='RETIRED';Update-TlsDocumentFixtureIndex $history
    Add-CheckResult 'TLS-D04 CA-Tombstone mit historischer Kante ist keine historische Payloadaufloesung' (Read-LabAuthenticatedTlsRegistryDocument (Get-TlsDocumentFixtureBytes $history)).Success
    Assert-TlsDocumentTransition $empty $fixture $true
    Assert-TlsDocumentTransition $fixture $fixture $false
    $candidate=Get-TlsDocumentFixture;$candidate.Index.Revision=2;Assert-TlsDocumentTransition $fixture $candidate $false
    foreach($change in @('add','update','retire','rotateSigner','retireBoth')){
        $candidate=Get-TlsDocumentFixture;$candidate.Index.Revision=2
        switch($change){
            add {$candidate.Payloads+=Get-TlsDocumentFixturePayload CLIENT_CONTEXT 4}
            update {$candidate.Payloads[0].Generation=2;$candidate.Payloads[0].Details.SqlcmdDiskSha256='c'*64}
            retire {$candidate.Payloads[0].Status='RETIRED'}
            rotateSigner {$candidate.Payloads[1].Generation=2;$candidate.Payloads[1].Details.RuntimeVersion='10.0.13';$candidate.Payloads[2].Generation=2;$candidate.Payloads[2].SignerGeneration=2}
            retireBoth {$candidate.Payloads[1].Status='RETIRED';$candidate.Payloads[2].Status='RETIRED'}
        }
        Update-TlsDocumentFixtureIndex $candidate;Assert-TlsDocumentTransition $fixture $candidate $true
    }
    foreach($change in @('generationOnly','digestOnly','identity','delete','skip','forgedIndex')){
        $candidate=Get-TlsDocumentFixture;$candidate.Index.Revision=2
        switch($change){generationOnly {$candidate.Payloads[0].Generation=2} digestOnly {$candidate.Payloads[0].Details.SqlcmdDiskSha256='c'*64} identity {$candidate.Payloads[0].Actor.UserSid='S-1-5-21-100-200-300-1002'} delete {$candidate.Payloads=$candidate.Payloads[1..2]} skip {$candidate.Index.Revision=3}}
        Update-TlsDocumentFixtureIndex $candidate
        if($change -ceq 'forgedIndex'){$candidate.Index.Records[0].RevisionDigest='c'*64}
        Assert-TlsDocumentTransition $fixture $candidate $false
    }
    $tombstone=Get-TlsDocumentFixture;$tombstone.Payloads[0].Status='RETIRED';Update-TlsDocumentFixtureIndex $tombstone
    $candidate=Get-TlsDocumentFixture;$candidate.Index.Revision=2;Assert-TlsDocumentTransition $tombstone $candidate $false
    $first=Get-TlsDocumentFixture;$first.Index.Revision=2;$first.Payloads+=Get-TlsDocumentFixturePayload CLIENT_CONTEXT 4;Update-TlsDocumentFixtureIndex $first
    $second=Get-TlsDocumentFixture;$second.Index.Revision=2;$second.Payloads+=Get-TlsDocumentFixturePayload CLIENT_CONTEXT 5;Update-TlsDocumentFixtureIndex $second
    Assert-TlsDocumentTransition $fixture $first $true;Assert-TlsDocumentTransition $fixture $second $true;Assert-TlsDocumentTransition $first $second $false
    foreach($side in @('before','after')){
        $left=Get-TlsDocumentFixtureBytes $fixture;$right=Get-TlsDocumentFixtureBytes $first
        if($side -ceq 'before'){$left='TLS_DOCUMENT_PRIVATE_CANARY'}else{$right='TLS_DOCUMENT_PRIVATE_CANARY'}
        $all=@(Test-LabAuthenticatedTlsRegistryDocumentTransition $left $right *>&1)
        Add-CheckResult 'TLS-D05 defekte Gesamtform ohne Teiluebergang' ($all.Count -eq 1 -and -not $all[0].Success -and $null -eq $all[0].Value -and $all[0].ErrorCode -ceq 'TLS_REGISTRY_DOCUMENT_TRANSITION_INVALID')
    }
}
Add-CheckResult 'TLS-D06 keine native Vorschau aufgerufen' ($script:nativeCalls -eq 0)
$tokens=$null;$errors=$null;$source=Join-Path $repo 'Private/AuthenticatedTlsRegistryDocument.ps1'
$ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$errors)
Add-CheckResult 'TLS-D06 Laden definiert nur Funktionen' ($errors.Count -eq 0 -and @($ast.EndBlock.Statements|Where-Object {$_ -isnot [Management.Automation.Language.FunctionDefinitionAst]}).Count -eq 0)
$commands=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.CommandAst]},$true)|ForEach-Object GetCommandName)
Add-CheckResult 'TLS-D06 nur In-Memory-Validatoren und Kodierung' (@($commands|Where-Object {$_ -cnotin @('Get-LabTlsIndexFields','Get-LabTlsIndexString','Test-LabTlsRequestEnum','Read-LabAuthenticatedTlsRegistryIndex','Read-LabAuthenticatedTlsRegistryPayload','Get-LabTlsPayloadDigest',
    'Read-LabAuthenticatedTlsRegistryDocument','Test-LabAuthenticatedTlsRegistryTransition','ConvertTo-Json')}).Count -eq 0)
$types=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.TypeExpressionAst]},$true)|ForEach-Object {$_.TypeName.FullName})
Add-CheckResult 'TLS-D06 keine I/O-/Registry-/Prozess-/PKI-/SQL-Typen' (@($types|Where-Object {$_ -match '(?i)\A(IO\.|Microsoft\.Win32|Diagnostics\.|Security\.|Net\.|.*SqlConnection)'}).Count -eq 0)
Write-Host "Authenticated TLS Registry Document: $passed PASS, $($failures.Count) FAIL"
if($failures.Count){throw 'AUTHENTICATED_TLS_REGISTRY_DOCUMENT_CHECKS_FAILED'}
