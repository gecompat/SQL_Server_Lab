#Requires -Version 7.2
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$repo=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
. (Join-Path $PSScriptRoot '../Common/CheckResult.ps1')
foreach($name in @('AuthenticatedTlsRequest','AuthenticatedTlsRegistryIndex','AuthenticatedTlsContext','AuthenticatedTlsRegistryPayload')){. (Join-Path $repo "Private/$name.ps1")}
$passed=0;$failures=[Collections.Generic.List[string]]::new()
function Get-TlsPayloadFixture {
    param([string]$Kind='CLIENT_CONTEXT')
    $p=[ordered]@{ContractVersion='SqlServerLab.AuthenticatedTlsRegistryPayload/0.1';ControllerId='11111111-1111-4111-8111-111111111111';LocationId='22222222-2222-4222-8222-222222222222';
        Kind=$Kind;Ref='33333333-3333-4333-8333-333333333333';Generation=1;Status='ACTIVE'}
    if($Kind -ceq 'AUTHORITY'){
        $p.Ref='55555555-5555-4555-8555-555555555555';$p.TrustScopeRef='66666666-6666-4666-8666-666666666666';$p.SignerContextRef='44444444-4444-4444-8444-444444444444'
        $p.SignerGeneration=1;$p.KeyStatus='NOT_CREATED';$p.CertificateStatus='NOT_CREATED'
    }else{
        $p.Context='CURRENT_WINDOWS_PROCESS';$p.Actor=[pscustomobject][ordered]@{UserSid='S-1-5-21-100-200-300-1001';HostMarker='77777777-7777-4777-8777-777777777777';ProfilePath='C:\lab\profile'}
        if($Kind -ceq 'CLIENT_CONTEXT'){
            $p.Details=[pscustomobject][ordered]@{Store='CURRENT_USER_ROOT';ClientStacks=@('SYSTEM_DATA_SQLCLIENT','ODBC_SQLCMD');SqlClientPath='C:\lab\System.Data.SqlClient.dll';SqlClientDiskSha256=('a'*64);SqlClientDiskBytes=123;
                SqlClientAssembly='System.Data.SqlClient, Version=4.8.0.0, Culture=neutral, PublicKeyToken=b03f5f7f11d50a3a';SqlClientLoadedMvid='88888888-8888-4888-8888-888888888888';SqlcmdPath='C:\lab\sqlcmd.exe';SqlcmdDiskSha256=('b'*64);SqlcmdDiskBytes=456;
                BinaryEvidence='ON_DISK_BYTES_ONLY';LoadedImageDigestStatus='NOT_MEASURED';SqlcmdFlavorStatus='NOT_QUALIFIED';LoadedOdbcDriverStatus='NOT_EXECUTED'}
        }else{
            $p.Ref='44444444-4444-4444-8444-444444444444'
            $p.Details=[pscustomobject][ordered]@{Backend='DOTNET_X509';RuntimeVersion='10.0.12';ApiStatus='COMPLETE';
                Apis=@('REQUEST_RSA_CONSTRUCTOR','CSR_CREATE_DER','CSR_LOAD_DER','CERTIFICATE_CREATE','SAN_IP','SAN_DNS'|ForEach-Object {[pscustomobject][ordered]@{Id=$_;Present=$true}});KeyProtectionStatus='NOT_EVALUATED'}
        }
    }
    return [pscustomobject]$p
}
function Get-TlsPayloadBytes {param([object]$Value) return ,[Text.UTF8Encoding]::new($false,$true).GetBytes(($Value|ConvertTo-Json -Depth 12 -Compress))}
function Assert-TlsPayloadRejected {
    param([object]$Bytes)
    $all=@(Read-LabAuthenticatedTlsRegistryPayload $Bytes *>&1)
    $ok=($all.Count -eq 1 -and -not $all[0].Success -and $null -eq $all[0].Value -and $all[0].ErrorCode -ceq 'TLS_REGISTRY_PAYLOAD_INVALID' -and ($all|ConvertTo-Json -Compress) -notmatch 'TLS_PAYLOAD_PRIVATE_CANARY')
    Add-CheckResult 'TLS-P01 geschlossene Ablehnung ohne Rohdiagnose' $ok
}
function Get-TlsPayloadRecord {param([object]$Payload) return (Read-LabAuthenticatedTlsRegistryPayload (Get-TlsPayloadBytes $Payload)).Value.IndexRecord}
& {
    Set-StrictMode -Version Latest
    foreach($kind in @('CLIENT_CONTEXT','SIGNER_CONTEXT','AUTHORITY')){
        $p=Get-TlsPayloadFixture $kind;$r=Read-LabAuthenticatedTlsRegistryPayload (Get-TlsPayloadBytes $p)
        Add-CheckResult "TLS-P01 frische private Form $kind" ($r.Success -and $null -eq $r.ErrorCode -and @($r.Value.PSObject.Properties).Count -eq 8 -and $r.Value.Status -ceq 'OFFLINE_PAYLOAD_ONLY' -and
            $r.Value.RootBindingStatus -ceq 'NOT_EVALUATED' -and $r.Value.RegistrationStatus -ceq 'NOT_EXECUTED' -and $r.Value.QualificationStatus -ceq 'NOT_EXECUTED' -and -not $r.Value.Ready -and -not $r.Value.MutationAllowed -and
            $r.Value.IndexRecord.IdentityDigest -cmatch '\A[0-9a-f]{64}\z' -and $r.Value.IndexRecord.RevisionDigest -cmatch '\A[0-9a-f]{64}\z')
        foreach($field in @($p.PSObject.Properties.Name)){
            $bad=Get-TlsPayloadFixture $kind;$bad.PSObject.Properties.Remove($field);Assert-TlsPayloadRejected (Get-TlsPayloadBytes $bad)
        }
        $bad=Get-TlsPayloadFixture $kind;$bad|Add-Member NoteProperty IdentityDigest ('c'*64);Assert-TlsPayloadRejected (Get-TlsPayloadBytes $bad)
        foreach($field in @('ControllerId','LocationId','Ref','ContractVersion','Kind','Status')){
            $bad=Get-TlsPayloadFixture $kind;$bad.$field='TLS_PAYLOAD_PRIVATE_CANARY';Assert-TlsPayloadRejected (Get-TlsPayloadBytes $bad)
        }
        foreach($value in @(0,'1',1.5,2147483648,$true)){$bad=Get-TlsPayloadFixture $kind;$bad.Generation=$value;Assert-TlsPayloadRejected (Get-TlsPayloadBytes $bad)}
        $raw=$p|ConvertTo-Json -Depth 12 -Compress
        foreach($json in @($raw.Replace('"Kind":','"kind":"TLS_PAYLOAD_PRIVATE_CANARY","Kind":'),$raw.Replace('"Generation":1','"Generation":1,"Gener\u0061tion":2'),$raw.Replace('"Generation":1','"Generation":1.0'),($raw+',0'))){
            Assert-TlsPayloadRejected ([Text.Encoding]::UTF8.GetBytes($json))
        }
    }
    foreach($kind in @('CLIENT_CONTEXT','SIGNER_CONTEXT')){
        $template=Get-TlsPayloadFixture $kind
        foreach($group in @('Actor','Details')){
            foreach($field in @($template.$group.PSObject.Properties.Name)){$bad=Get-TlsPayloadFixture $kind;$bad.$group.PSObject.Properties.Remove($field);Assert-TlsPayloadRejected (Get-TlsPayloadBytes $bad)}
        }
        foreach($path in @('C:\','C:\lab\..\profile','C:\lab\.\profile','\\host\share\profile','C:\lab\x:ads','C:/lab/profile',"C:\lab\bad`nprofile",'C:\lab\\profile','relative')){
            $bad=Get-TlsPayloadFixture $kind;$bad.Actor.ProfilePath=$path;Assert-TlsPayloadRejected (Get-TlsPayloadBytes $bad)
        }
        $bad=Get-TlsPayloadFixture $kind;$bad.Actor.UserSid='S-1-5-18';Assert-TlsPayloadRejected (Get-TlsPayloadBytes $bad)
        $bad=Get-TlsPayloadFixture $kind;$bad.Actor.ProfilePath='C:\%PROFILE%';Assert-TlsPayloadRejected (Get-TlsPayloadBytes $bad)
    }
    foreach($field in @('Store','BinaryEvidence','LoadedImageDigestStatus','SqlcmdFlavorStatus','LoadedOdbcDriverStatus')){
        $bad=Get-TlsPayloadFixture;$bad.Details.$field='QUALIFIED';Assert-TlsPayloadRejected (Get-TlsPayloadBytes $bad)
    }
    foreach($field in @('SqlClientDiskBytes','SqlcmdDiskBytes')){foreach($value in @(0,67108865,'123')){$bad=Get-TlsPayloadFixture;$bad.Details.$field=$value;Assert-TlsPayloadRejected (Get-TlsPayloadBytes $bad)}}
    foreach($field in @('SqlClientDiskSha256','SqlcmdDiskSha256','SqlClientLoadedMvid','SqlClientAssembly','SqlClientPath','SqlcmdPath')){$bad=Get-TlsPayloadFixture;$bad.Details.$field='TLS_PAYLOAD_PRIVATE_CANARY';Assert-TlsPayloadRejected (Get-TlsPayloadBytes $bad)}
    $bad=Get-TlsPayloadFixture;$bad.Details.ClientStacks=@('ODBC_SQLCMD','SYSTEM_DATA_SQLCLIENT');Assert-TlsPayloadRejected (Get-TlsPayloadBytes $bad)
    $bad=Get-TlsPayloadFixture SIGNER_CONTEXT;$bad.Details.Apis[0].Present='true';Assert-TlsPayloadRejected (Get-TlsPayloadBytes $bad)
    $bad=Get-TlsPayloadFixture SIGNER_CONTEXT;$bad.Details.Apis[0].Present=$false;Assert-TlsPayloadRejected (Get-TlsPayloadBytes $bad)
    $bad.Details.ApiStatus='INCOMPLETE'
    Add-CheckResult 'TLS-P02 unvollstaendige API ohne Keyqualifikation erlaubt' (Read-LabAuthenticatedTlsRegistryPayload (Get-TlsPayloadBytes $bad)).Success
    $bad=Get-TlsPayloadFixture SIGNER_CONTEXT;$bad.Details.Apis[0].Id='CSR_CREATE_DER';Assert-TlsPayloadRejected (Get-TlsPayloadBytes $bad)
    foreach($field in @('KeyStatus','CertificateStatus')){$bad=Get-TlsPayloadFixture AUTHORITY;$bad.$field='CREATED';Assert-TlsPayloadRejected (Get-TlsPayloadBytes $bad)}
    foreach($inputValue in @($null,'TLS_PAYLOAD_PRIVATE_CANARY',@{},[byte[]]@(),[byte[]]@(0xc3,0x28),[byte[]]::new(32769))){Assert-TlsPayloadRejected $inputValue}
    $script:foreign=0;$alien=[pscustomobject]@{};$alien|Add-Member ScriptMethod ToString {$script:foreign++;throw 'TLS_PAYLOAD_PRIVATE_CANARY'} -Force;Assert-TlsPayloadRejected $alien
    $bytes=Get-TlsPayloadBytes (Get-TlsPayloadFixture);$bytes|Add-Member ScriptProperty Length {$script:foreign++;throw 'TLS_PAYLOAD_PRIVATE_CANARY'} -Force
    Add-CheckResult 'TLS-P02 native Arraylaenge ohne ETS-Getter' (Read-LabAuthenticatedTlsRegistryPayload $bytes).Success
    Add-CheckResult 'TLS-P02 keine fremden Getter/Casts' ($script:foreign -eq 0)
    $raw=Get-TlsPayloadBytes (Get-TlsPayloadFixture);$text=[Text.Encoding]::UTF8.GetString($raw)
    Add-CheckResult 'TLS-P02 exakte 32KiB-Grenze' (Read-LabAuthenticatedTlsRegistryPayload ([Text.Encoding]::UTF8.GetBytes($text+(' '*(32768-$raw.Length))))).Success
    Assert-TlsPayloadRejected ([byte[]](@(0xef,0xbb,0xbf)+$raw))
    $saved=[Threading.Thread]::CurrentThread.CurrentCulture
    try{foreach($culture in @('en-US','de-DE','tr-TR')){
        [Threading.Thread]::CurrentThread.CurrentCulture=[Globalization.CultureInfo]::GetCultureInfo($culture)
        foreach($char in @([char]0x200b,[char]0x00ad)){
            $bad=Get-TlsPayloadFixture;$bad.Details.Store+=$char;Assert-TlsPayloadRejected (Get-TlsPayloadBytes $bad)
            $bad=Get-TlsPayloadFixture;$bad.Kind+=$char;Assert-TlsPayloadRejected (Get-TlsPayloadBytes $bad)
        }
    }}finally{[Threading.Thread]::CurrentThread.CurrentCulture=$saved}

    $literal=[Text.Encoding]::UTF8.GetBytes('00000001a00000002bc')
    $gold=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($literal)).ToLowerInvariant()
    Add-CheckResult 'TLS-P03 kanonische Laengenrahmung statt Konkatenation' ((Get-LabTlsPayloadDigest @('a','bc')) -ceq $gold -and (Get-LabTlsPayloadDigest @('ab','c')) -cne $gold)
    $unicode=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes(('00000002'+[char]0x00e4)))).ToLowerInvariant()
    Add-CheckResult 'TLS-P03 UTF8-Bytezahl unabhaengig von Zeichenlaenge' ((Get-LabTlsPayloadDigest @([string][char]0x00e4)) -ceq $unicode)
    $base=Get-TlsPayloadRecord (Get-TlsPayloadFixture)
    $reordered=Get-TlsPayloadFixture;$map=[ordered]@{};foreach($prop in @($reordered.PSObject.Properties)|Sort-Object Name -Descending){$map[$prop.Name]=$prop.Value}
    $parsed=Read-LabAuthenticatedTlsRegistryPayload (Get-TlsPayloadBytes ([pscustomobject]$map))
    Add-CheckResult 'TLS-P03 JSON-Reihenfolge aendert keinen Digest' ($parsed.Success -and $parsed.Value.IndexRecord.IdentityDigest -ceq $base.IdentityDigest -and $parsed.Value.IndexRecord.RevisionDigest -ceq $base.RevisionDigest)
    foreach($field in @('Generation','Status','Ref')){
        $p=Get-TlsPayloadFixture
        switch($field){Generation {$p.Generation=2} Status {$p.Status='RETIRED'} Ref {$p.Ref='99999999-9999-4999-8999-999999999999'}}
        $r=Get-TlsPayloadRecord $p
        Add-CheckResult "TLS-P03 logische Verwaltung nicht im Inhaltsdigest $field" ($r.IdentityDigest -ceq $base.IdentityDigest -and $r.RevisionDigest -ceq $base.RevisionDigest)
    }
    foreach($field in @('UserSid','HostMarker')){
        $p=Get-TlsPayloadFixture;if($field -ceq 'UserSid'){$p.Actor.UserSid='S-1-5-21-100-200-300-1002'}else{$p.Actor.HostMarker='99999999-9999-4999-8999-999999999999'}
        Add-CheckResult "TLS-P03 native Identitaetsaenderung $field" ((Get-TlsPayloadRecord $p).IdentityDigest -cne $base.IdentityDigest)
    }
    $p=Get-TlsPayloadFixture;$p.Actor.ProfilePath='C:\lab\other-profile';$r=Get-TlsPayloadRecord $p
    Add-CheckResult 'TLS-P03 Profilkontext ist eine neue Revision' ($r.IdentityDigest -ceq $base.IdentityDigest -and $r.RevisionDigest -cne $base.RevisionDigest)
    foreach($field in @('SqlClientPath','SqlClientDiskSha256','SqlClientDiskBytes','SqlClientAssembly','SqlClientLoadedMvid','SqlcmdPath','SqlcmdDiskSha256','SqlcmdDiskBytes')){
        $p=Get-TlsPayloadFixture
        switch($field){
            SqlClientPath {$p.Details.SqlClientPath='C:\lab\other\System.Data.SqlClient.dll'} SqlcmdPath {$p.Details.SqlcmdPath='C:\lab\other\sqlcmd.exe'}
            SqlClientDiskSha256 {$p.Details.SqlClientDiskSha256='c'*64} SqlcmdDiskSha256 {$p.Details.SqlcmdDiskSha256='c'*64}
            SqlClientDiskBytes {$p.Details.SqlClientDiskBytes++} SqlcmdDiskBytes {$p.Details.SqlcmdDiskBytes++}
            SqlClientAssembly {$p.Details.SqlClientAssembly+=' synthetic'} SqlClientLoadedMvid {$p.Details.SqlClientLoadedMvid='99999999-9999-4999-8999-999999999999'}
        }
        $r=Get-TlsPayloadRecord $p
        Add-CheckResult "TLS-P03 binaere Revision $field" ($r.IdentityDigest -ceq $base.IdentityDigest -and $r.RevisionDigest -cne $base.RevisionDigest)
    }
    $records=@((Get-TlsPayloadRecord (Get-TlsPayloadFixture)),(Get-TlsPayloadRecord (Get-TlsPayloadFixture SIGNER_CONTEXT)),(Get-TlsPayloadRecord (Get-TlsPayloadFixture AUTHORITY)))
    $index=[pscustomobject]@{ContractVersion='SqlServerLab.AuthenticatedTlsRegistryIndex/0.1';ControllerId=(Get-TlsPayloadFixture).ControllerId;LocationId=(Get-TlsPayloadFixture).LocationId;Revision=1;Records=$records}
    Add-CheckResult 'TLS-P04 abgeleitete Records im echten Indexvertrag' (Read-LabAuthenticatedTlsRegistryIndex (Get-TlsPayloadBytes $index)).Success
    $next=$index|ConvertTo-Json -Depth 12|ConvertFrom-Json;$next.Revision=2;$p=Get-TlsPayloadFixture;$p.Generation=2;$p.Details.SqlcmdDiskSha256='c'*64;$next.Records[0]=Get-TlsPayloadRecord $p
    Add-CheckResult 'TLS-P04 echte Revision im Indexuebergang' (Test-LabAuthenticatedTlsRegistryTransition (Get-TlsPayloadBytes $index) (Get-TlsPayloadBytes $next)).Success
}

$original=${function:Get-LabAuthenticatedTlsContextPreview};$script:nativeCalls=0;$script:nativeDrift=''
try{
    function Get-LabAuthenticatedTlsContextPreview {
        param([object]$Request)
        $script:nativeCalls++;$script:lastNativeRequest=$Request
        if($script:nativeDrift -ceq 'unavailable'){return [pscustomobject]@{Success=$false;Value=$null;ErrorCode='TLS_CONTEXT_PROFILE_UNAVAILABLE'}}
        if($script:nativeDrift -ceq 'throw'){throw 'TLS_PAYLOAD_PRIVATE_CANARY native'}
        $p=Get-TlsPayloadFixture $Request.Kind
        if($script:nativeDrift -ceq 'actor'){$p.Actor.UserSid='S-1-5-21-100-200-300-1002'}
        if($script:nativeDrift -ceq 'revision'){$p.Actor.ProfilePath='C:\lab\changed'}
        $v=[ordered]@{RequestId=$Request.RequestId;Kind=$Request.Kind;Context=$Request.Context;Process=[pscustomobject]@{UserSid=$p.Actor.UserSid;HostMarker=$p.Actor.HostMarker;ProfilePath=$p.Actor.ProfilePath;ProcessId=123;ProcessStartUtcTicks=456L;ProcessPath='C:\lab\pwsh.exe'}}
        $d=$p.Details
        if($Request.Kind -ceq 'CLIENT_CONTEXT'){
            $v.Store=$d.Store;$v.ClientStacks=$d.ClientStacks
            $v.Binaries=[pscustomobject]@{SqlClient=[pscustomobject]@{Path=$d.SqlClientPath;DiskSha256=$d.SqlClientDiskSha256;DiskBytes=$d.SqlClientDiskBytes;Evidence=$d.BinaryEvidence};
                Sqlcmd=[pscustomobject]@{Path=$d.SqlcmdPath;DiskSha256=$d.SqlcmdDiskSha256;DiskBytes=$d.SqlcmdDiskBytes;Evidence=$d.BinaryEvidence};SqlClientAssembly=$d.SqlClientAssembly;SqlClientLoadedMvid=$d.SqlClientLoadedMvid;
                LoadedImageDigestStatus=$d.LoadedImageDigestStatus;SqlcmdFlavorStatus=$d.SqlcmdFlavorStatus;LoadedOdbcDriverStatus=$d.LoadedOdbcDriverStatus}
        }else{$v.Backend=$d;$v.KeyProtectionStatus=$d.KeyProtectionStatus}
        if($script:nativeDrift -ceq 'request'){$v.RequestId='99999999-9999-4999-8999-999999999999'}
        if($script:nativeDrift -ceq 'process'){$v.Process.ProcessStartUtcTicks=0L}
        return [pscustomobject]@{Success=$true;Value=[pscustomobject]$v;ErrorCode=$null}
    }
    $result=Get-LabAuthenticatedTlsPayloadPreview 'TLS_PAYLOAD_PRIVATE_CANARY'
    Add-CheckResult 'TLS-P05 Formfehler vor nativer Lesung' (-not $result.Success -and $result.ErrorCode -ceq 'TLS_REGISTRY_PAYLOAD_INVALID' -and $script:nativeCalls -eq 0)
    foreach($kind in @('CLIENT_CONTEXT','SIGNER_CONTEXT','AUTHORITY')){
        $previewArgs=@{PayloadBytes=(Get-TlsPayloadBytes (Get-TlsPayloadFixture $kind))}
        if($kind -ceq 'AUTHORITY'){$previewArgs.SignerPayloadBytes=Get-TlsPayloadBytes (Get-TlsPayloadFixture SIGNER_CONTEXT)}
        $result=Get-LabAuthenticatedTlsPayloadPreview @previewArgs
        Add-CheckResult "TLS-P05 frische interne Metadatenbindung $kind" ($result.Success -and $result.Value.Status -ceq 'FRESH_PROCESS_METADATA_MATCH' -and
            $result.Value.RootBindingStatus -ceq 'NOT_EVALUATED' -and $result.Value.AuthorityTrustScopeStatus -ceq 'NOT_EVALUATED' -and $result.Value.RegistrationStatus -ceq 'NOT_EXECUTED' -and
            $result.Value.QualificationStatus -ceq 'NOT_EXECUTED' -and -not $result.Value.Ready -and -not $result.Value.MutationAllowed)
        if($kind -ceq 'AUTHORITY'){Add-CheckResult 'TLS-P05 CA-ID wird nicht Signierer-ID' ($script:lastNativeRequest.SignerContextRef -ceq (Get-TlsPayloadFixture AUTHORITY).SignerContextRef -and $script:lastNativeRequest.Kind -ceq 'SIGNER_CONTEXT')}
        foreach($drift in @('actor','revision','request','process','unavailable','throw')){
            $script:nativeDrift=$drift;$all=@(Get-LabAuthenticatedTlsPayloadPreview @previewArgs *>&1)
            Add-CheckResult "TLS-P06 native Abweichung verwirft Teilbefund $kind $drift" ($all.Count -eq 1 -and -not $all[0].Success -and $null -eq $all[0].Value -and
                $all[0].ErrorCode -cin @('TLS_REGISTRY_PAYLOAD_BINDING_MISMATCH','TLS_REGISTRY_PAYLOAD_PREVIEW_UNAVAILABLE') -and ($all|ConvertTo-Json -Compress) -notmatch 'PRIVATE_CANARY|S-1-5-21|C:\\lab')
        }
        $script:nativeDrift=''
    }
    foreach($change in @('missing','kind','ref','generation','root','retired')){
        $ca=Get-TlsPayloadFixture AUTHORITY;$signer=Get-TlsPayloadFixture SIGNER_CONTEXT
        switch($change){kind {$signer=Get-TlsPayloadFixture} ref {$signer.Ref='99999999-9999-4999-8999-999999999999'} generation {$signer.Generation=2} root {$signer.LocationId='99999999-9999-4999-8999-999999999999'} retired {$signer.Status='RETIRED'}}
        $before=$script:nativeCalls;$signerBytes=if($change -ceq 'missing'){$null}else{Get-TlsPayloadBytes $signer}
        $result=Get-LabAuthenticatedTlsPayloadPreview (Get-TlsPayloadBytes $ca) $signerBytes
        Add-CheckResult "TLS-P06 Signierkante vor Lesung geprueft $change" (-not $result.Success -and $null -eq $result.Value -and $script:nativeCalls -eq $before)
    }
}finally{Set-Item function:Get-LabAuthenticatedTlsContextPreview $original}
$tokens=$null;$errors=$null;$source=Join-Path $repo 'Private/AuthenticatedTlsRegistryPayload.ps1'
$ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$errors)
Add-CheckResult 'TLS-P07 beim Laden nur Definitionen' ($errors.Count -eq 0 -and @($ast.EndBlock.Statements|Where-Object {$_ -isnot [Management.Automation.Language.FunctionDefinitionAst]}).Count -eq 0)
$commands=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.CommandAst]},$true)|ForEach-Object GetCommandName)
Add-CheckResult 'TLS-P07 nur Parser/Digest und bekannte lesende Vorschau' (@($commands|Where-Object {$_ -cnotin @('Get-LabTlsIndexString','Get-LabTlsIndexFields','Get-LabTlsIndexInteger','Test-LabTlsRequestEnum','Test-LabTlsRequestReference','Get-LabTlsPayloadPath',
    'Get-LabTlsPayloadDetails','Get-LabTlsPayloadDigest','Get-LabTlsPayloadIndexRecord','Read-LabAuthenticatedTlsRegistryPayload','Get-LabAuthenticatedTlsContextPreview','ConvertTo-Json','Where-Object')}).Count -eq 0)
$text=[IO.File]::ReadAllText($source)
Add-CheckResult 'TLS-P07 kein File-/Registry-/Key-/Store-/SQL-/Prozessaufruf' ($text -notmatch '(?i)IO\.(File|Directory|FileStream)|RegistryKey|X509Store|CertificateRequest|RSA\]::|Process\]::Start|SqlConnection\]::|SetValue|WriteAll')
Write-Host "Authenticated TLS Registry Payload: $passed PASS, $($failures.Count) FAIL"
if($failures.Count){throw 'AUTHENTICATED_TLS_REGISTRY_PAYLOAD_CHECKS_FAILED'}
