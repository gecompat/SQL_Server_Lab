#Requires -Version 7.2
# Private Metadaten vor Keyanlage; Digests sind keine Autorisierung.

function Get-LabTlsPayloadPath {
    param([Text.Json.JsonElement]$Element)
    $value=Get-LabTlsIndexString $Element
    if($value.Length -gt 2048 -or $value -cnotmatch '\A[A-Za-z]:\\[^\\]' -or
        $value.Substring(2) -match '[\x00-\x1f<>"|?*:/]' -or $value.EndsWith('\') -or @($value.Substring(3).Split('\')|Where-Object {$_ -cin @('','.', '..')}).Count){throw 'TLS_PAYLOAD_INVALID'}
    return $value
}

function Get-LabTlsPayloadDetails {
    param([Text.Json.JsonElement]$Element,[string]$Kind)
    if([string]::Equals($Kind,'CLIENT_CONTEXT',[StringComparison]::Ordinal)){
        $names=@('Store','ClientStacks','SqlClientPath','SqlClientDiskSha256','SqlClientDiskBytes','SqlClientAssembly','SqlClientLoadedMvid',
            'SqlcmdPath','SqlcmdDiskSha256','SqlcmdDiskBytes','BinaryEvidence','LoadedImageDigestStatus','SqlcmdFlavorStatus','LoadedOdbcDriverStatus')
        $fields=Get-LabTlsIndexFields $Element $names
        $value=[ordered]@{}
        foreach($name in @('Store','SqlClientDiskSha256','SqlClientAssembly','SqlClientLoadedMvid','SqlcmdDiskSha256','BinaryEvidence','LoadedImageDigestStatus','SqlcmdFlavorStatus','LoadedOdbcDriverStatus')){
            $value[$name]=Get-LabTlsIndexString $fields[$name]
        }
        foreach($pair in @(@('Store','CURRENT_USER_ROOT'),@('BinaryEvidence','ON_DISK_BYTES_ONLY'),@('LoadedImageDigestStatus','NOT_MEASURED'),@('SqlcmdFlavorStatus','NOT_QUALIFIED'),@('LoadedOdbcDriverStatus','NOT_EXECUTED'))){
            if(-not (Test-LabTlsRequestEnum $value[$pair[0]] @($pair[1]))){throw 'TLS_PAYLOAD_INVALID'}
        }
        if($value.SqlClientDiskSha256 -cnotmatch '\A[0-9a-f]{64}\z' -or $value.SqlcmdDiskSha256 -cnotmatch '\A[0-9a-f]{64}\z' -or
            -not (Test-LabTlsRequestReference $value.SqlClientLoadedMvid) -or $value.SqlClientAssembly.Length -gt 1024 -or
            $value.SqlClientAssembly -cnotmatch '\ASystem\.Data\.SqlClient, [^\x00-\x1f]+\z'){throw 'TLS_PAYLOAD_INVALID'}
        $stacks=$fields['ClientStacks']
        if($stacks.ValueKind -ne [Text.Json.JsonValueKind]::Array -or $stacks.GetArrayLength() -ne 2 -or
            -not (Test-LabTlsRequestEnum (Get-LabTlsIndexString $stacks[0]) @('SYSTEM_DATA_SQLCLIENT')) -or
            -not (Test-LabTlsRequestEnum (Get-LabTlsIndexString $stacks[1]) @('ODBC_SQLCMD'))){throw 'TLS_PAYLOAD_INVALID'}
        $value.ClientStacks=@('SYSTEM_DATA_SQLCLIENT','ODBC_SQLCMD')
        foreach($prefix in @('SqlClient','Sqlcmd')){
            $value[$prefix+'Path']=Get-LabTlsPayloadPath $fields[$prefix+'Path']
            $value[$prefix+'DiskBytes']=Get-LabTlsIndexInteger $fields[$prefix+'DiskBytes'] 1
            if($value[$prefix+'DiskBytes'] -gt 67108864){throw 'TLS_PAYLOAD_INVALID'}
            $file=($value[$prefix+'Path'] -split '\\')[-1];$expected=if($prefix -ceq 'SqlClient'){'System.Data.SqlClient.dll'}else{'sqlcmd.exe'}
            if(-not [string]::Equals($file,$expected,[StringComparison]::OrdinalIgnoreCase)){throw 'TLS_PAYLOAD_INVALID'}
        }
        return [pscustomobject]$value
    }
    $fields=Get-LabTlsIndexFields $Element @('Backend','RuntimeVersion','ApiStatus','Apis','KeyProtectionStatus')
    $value=[ordered]@{Backend=(Get-LabTlsIndexString $fields['Backend']);RuntimeVersion=(Get-LabTlsIndexString $fields['RuntimeVersion']);ApiStatus=(Get-LabTlsIndexString $fields['ApiStatus']);
        Apis=@();KeyProtectionStatus=(Get-LabTlsIndexString $fields['KeyProtectionStatus'])}
    if(-not (Test-LabTlsRequestEnum $value.Backend @('DOTNET_X509')) -or -not (Test-LabTlsRequestEnum $value.KeyProtectionStatus @('NOT_EVALUATED')) -or
        $value.RuntimeVersion.Length -gt 64 -or $value.RuntimeVersion -cnotmatch '\A[0-9]+\.[0-9]+\.[0-9]+(?:\.[0-9]+)?\z'){throw 'TLS_PAYLOAD_INVALID'}
    $ids=@('REQUEST_RSA_CONSTRUCTOR','CSR_CREATE_DER','CSR_LOAD_DER','CERTIFICATE_CREATE','SAN_IP','SAN_DNS');$apis=$fields['Apis'];$complete=$true
    if($apis.ValueKind -ne [Text.Json.JsonValueKind]::Array -or $apis.GetArrayLength() -ne 6){throw 'TLS_PAYLOAD_INVALID'}
    for($i=0;$i -lt 6;$i++){
        $api=Get-LabTlsIndexFields $apis[$i] @('Id','Present')
        if(-not (Test-LabTlsRequestEnum (Get-LabTlsIndexString $api['Id']) @($ids[$i])) -or
            $api['Present'].ValueKind -notin @([Text.Json.JsonValueKind]::True,[Text.Json.JsonValueKind]::False)){throw 'TLS_PAYLOAD_INVALID'}
        $present=$api['Present'].GetBoolean();$complete=$complete -and $present
        $value.Apis += [pscustomobject][ordered]@{Id=$ids[$i];Present=$present}
    }
    $expected=if($complete){'COMPLETE'}else{'INCOMPLETE'}
    if(-not (Test-LabTlsRequestEnum $value.ApiStatus @($expected))){throw 'TLS_PAYLOAD_INVALID'}
    return [pscustomobject]$value
}

function Get-LabTlsPayloadDigest {
    param([string[]]$Atoms)
    $stream=[IO.MemoryStream]::new()
    try{
        $encoding=[Text.UTF8Encoding]::new($false,$true)
        foreach($atom in $Atoms){
            $bytes=$encoding.GetBytes($atom);$length=[Text.Encoding]::ASCII.GetBytes($bytes.Length.ToString('x8',[Globalization.CultureInfo]::InvariantCulture))
            $stream.Write($length,0,8);$stream.Write($bytes,0,$bytes.Length)
        }
        return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stream.ToArray())).ToLowerInvariant()
    }finally{$stream.Dispose()}
}

function Get-LabTlsPayloadIndexRecord {
    param([object]$Payload)
    $p=$Payload
    $identity=@('SqlServerLab.TlsPayloadIdentity/0.1',$p.Kind,$p.ControllerId,$p.LocationId)
    $revision=@('SqlServerLab.TlsPayloadRevision/0.1')
    if([string]::Equals($p.Kind,'AUTHORITY',[StringComparison]::Ordinal)){
        $identity+=@($p.TrustScopeRef,$p.SignerContextRef)
        $revision+=@($p.SignerGeneration.ToString([Globalization.CultureInfo]::InvariantCulture),$p.KeyStatus,$p.CertificateStatus)
    }else{
        $identity+=@($p.Context,$p.Actor.UserSid,$p.Actor.HostMarker)
        $revision+=@($p.Actor.ProfilePath)
        $d=$p.Details
        if([string]::Equals($p.Kind,'CLIENT_CONTEXT',[StringComparison]::Ordinal)){
            foreach($name in @('Store','SqlClientPath','SqlClientDiskSha256','SqlClientDiskBytes','SqlClientAssembly','SqlClientLoadedMvid','SqlcmdPath','SqlcmdDiskSha256','SqlcmdDiskBytes',
                'BinaryEvidence','LoadedImageDigestStatus','SqlcmdFlavorStatus','LoadedOdbcDriverStatus')){
                $revision+=@($name,[Convert]::ToString($d.$name,[Globalization.CultureInfo]::InvariantCulture))
            }
            $revision+=@($d.ClientStacks)
        }else{
            $revision+=@($d.Backend,$d.RuntimeVersion,$d.ApiStatus,$d.KeyProtectionStatus)
            foreach($api in $d.Apis){$revision+=@($api.Id,$(if($api.Present){'1'}else{'0'}))}
        }
    }
    $id=Get-LabTlsPayloadDigest $identity
    $digest=Get-LabTlsPayloadDigest ($revision+@($id))
    $record=[ordered]@{Kind=$p.Kind;Ref=$p.Ref;Generation=$p.Generation;Status=$p.Status;IdentityDigest=$id;RevisionDigest=$digest}
    if([string]::Equals($p.Kind,'AUTHORITY',[StringComparison]::Ordinal)){$record.SignerContextRef=$p.SignerContextRef;$record.SignerGeneration=$p.SignerGeneration}
    return [pscustomobject]$record
}

function Read-LabAuthenticatedTlsRegistryPayload {
    [CmdletBinding()]
    param([object]$Utf8Json)
    $bad=[pscustomobject][ordered]@{Success=$false;Value=$null;ErrorCode='TLS_REGISTRY_PAYLOAD_INVALID'};$document=$null
    try{
        if($null -eq $Utf8Json -or [object].GetMethod('GetType').Invoke($Utf8Json,$null) -ne [byte[]]){return $bad}
        $length=[array].GetProperty('Length').GetValue($Utf8Json)
        if($length -lt 1 -or $length -gt 32768){return $bad}
        $bytes=[byte[]]::new($length);[Buffer]::BlockCopy($Utf8Json,0,$bytes,0,$length)
        $options=[Text.Json.JsonDocumentOptions]::new();$options.MaxDepth=6
        $document=[Text.Json.JsonDocument]::Parse([Text.UTF8Encoding]::new($false,$true).GetString($bytes),$options)
        $kindElement=[Text.Json.JsonElement]::new()
        if($document.RootElement.ValueKind -ne [Text.Json.JsonValueKind]::Object -or -not $document.RootElement.TryGetProperty('Kind',[ref]$kindElement)){return $bad}
        $kind=Get-LabTlsIndexString $kindElement
        if(-not (Test-LabTlsRequestEnum $kind @('CLIENT_CONTEXT','SIGNER_CONTEXT','AUTHORITY'))){return $bad}
        $names=@('ContractVersion','ControllerId','LocationId','Kind','Ref','Generation','Status')
        $names+=if([string]::Equals($kind,'AUTHORITY',[StringComparison]::Ordinal)){@('TrustScopeRef','SignerContextRef','SignerGeneration','KeyStatus','CertificateStatus')}else{@('Context','Actor','Details')}
        $fields=Get-LabTlsIndexFields $document.RootElement $names
        $p=[ordered]@{}
        foreach($name in @('ContractVersion','ControllerId','LocationId','Kind','Ref','Status')){$p[$name]=Get-LabTlsIndexString $fields[$name]}
        if(-not (Test-LabTlsRequestEnum $p.ContractVersion @('SqlServerLab.AuthenticatedTlsRegistryPayload/0.1')) -or -not (Test-LabTlsRequestEnum $p.Status @('ACTIVE','RETIRED'))){return $bad}
        foreach($name in @('ControllerId','LocationId','Ref')){if(-not (Test-LabTlsRequestReference $p[$name])){return $bad}}
        $p.Generation=Get-LabTlsIndexInteger $fields['Generation'] 1
        if([string]::Equals($kind,'AUTHORITY',[StringComparison]::Ordinal)){
            foreach($name in @('TrustScopeRef','SignerContextRef')){$p[$name]=Get-LabTlsIndexString $fields[$name];if(-not (Test-LabTlsRequestReference $p[$name])){return $bad}}
            $p.SignerGeneration=Get-LabTlsIndexInteger $fields['SignerGeneration'] 1
            foreach($name in @('KeyStatus','CertificateStatus')){$p[$name]=Get-LabTlsIndexString $fields[$name];if(-not (Test-LabTlsRequestEnum $p[$name] @('NOT_CREATED'))){return $bad}}
        }else{
            $p.Context=Get-LabTlsIndexString $fields['Context'];if(-not (Test-LabTlsRequestEnum $p.Context @('CURRENT_WINDOWS_PROCESS'))){return $bad}
            $actor=Get-LabTlsIndexFields $fields['Actor'] @('UserSid','HostMarker','ProfilePath')
            $p.Actor=[pscustomobject][ordered]@{UserSid=(Get-LabTlsIndexString $actor['UserSid']);HostMarker=(Get-LabTlsIndexString $actor['HostMarker']);ProfilePath=(Get-LabTlsPayloadPath $actor['ProfilePath'])}
            if($p.Actor.UserSid -cnotmatch '\AS-1-(?:5-21|12-1)(?:-[0-9]+){4}\z' -or -not (Test-LabTlsRequestReference $p.Actor.HostMarker) -or $p.Actor.ProfilePath.Contains('%')){return $bad}
            $p.Details=Get-LabTlsPayloadDetails $fields['Details'] $kind
        }
        $payload=[pscustomobject]$p;$record=Get-LabTlsPayloadIndexRecord $payload
        return [pscustomobject][ordered]@{Success=$true;Value=[pscustomobject][ordered]@{Status='OFFLINE_PAYLOAD_ONLY';Payload=$payload;IndexRecord=$record;
            RootBindingStatus='NOT_EVALUATED';RegistrationStatus='NOT_EXECUTED';QualificationStatus='NOT_EXECUTED';Ready=$false;MutationAllowed=$false};ErrorCode=$null}
    }catch{return $bad}finally{if($null -ne $document){$document.Dispose()}}
}

function Get-LabAuthenticatedTlsPayloadPreview {
    [CmdletBinding()]
    param([object]$PayloadBytes,[object]$SignerPayloadBytes)
    $bad=[pscustomobject][ordered]@{Success=$false;Value=$null;ErrorCode='TLS_REGISTRY_PAYLOAD_INVALID'}
    $parsed=Read-LabAuthenticatedTlsRegistryPayload $PayloadBytes;if(-not $parsed.Success){return $bad}
    $p=$parsed.Value.Payload;$isCa=[string]::Equals($p.Kind,'AUTHORITY',[StringComparison]::Ordinal)
    $bad.ErrorCode='TLS_REGISTRY_PAYLOAD_BINDING_MISMATCH'
    if(-not [string]::Equals($p.Status,'ACTIVE',[StringComparison]::Ordinal)){return $bad}
    $target=$parsed
    if($isCa){
        $target=Read-LabAuthenticatedTlsRegistryPayload $SignerPayloadBytes
        if(-not $target.Success){return $bad}
        $s=$target.Value.Payload
        if(-not [string]::Equals($s.Kind,'SIGNER_CONTEXT',[StringComparison]::Ordinal) -or -not [string]::Equals($s.Status,'ACTIVE',[StringComparison]::Ordinal) -or
            -not [string]::Equals($s.Ref,$p.SignerContextRef,[StringComparison]::Ordinal) -or $s.Generation -ne $p.SignerGeneration -or
            -not [string]::Equals($s.ControllerId,$p.ControllerId,[StringComparison]::Ordinal) -or -not [string]::Equals($s.LocationId,$p.LocationId,[StringComparison]::Ordinal)){return $bad}
    }elseif($null -ne $SignerPayloadBytes){return $bad}
    try{
        $s=$target.Value.Payload
        $request=[ordered]@{ContractVersion='SqlServerLab.AuthenticatedTlsContextRequest/0.1';RequestId=[guid]::NewGuid().ToString('D');Kind=$s.Kind;Context='CURRENT_WINDOWS_PROCESS'}
        if([string]::Equals($s.Kind,'CLIENT_CONTEXT',[StringComparison]::Ordinal)){$request.ClientRef=$s.Ref;$request.Store='CURRENT_USER_ROOT';$request.ClientStacks=@('SYSTEM_DATA_SQLCLIENT','ODBC_SQLCMD')}
        else{$request.SignerContextRef=$s.Ref;$request.Backend='DOTNET_X509'}
        $fresh=Get-LabAuthenticatedTlsContextPreview -Request ([pscustomobject]$request)
        if(-not $fresh.Success){$bad.ErrorCode='TLS_REGISTRY_PAYLOAD_PREVIEW_UNAVAILABLE';return $bad}
        $v=$fresh.Value
        if(-not [string]::Equals($v.RequestId,$request.RequestId,[StringComparison]::Ordinal) -or -not [string]::Equals($v.Kind,$s.Kind,[StringComparison]::Ordinal) -or
            -not [string]::Equals($v.Context,'CURRENT_WINDOWS_PROCESS',[StringComparison]::Ordinal) -or $v.Process.ProcessId -isnot [int] -or $v.Process.ProcessId -lt 1 -or
            $v.Process.ProcessStartUtcTicks -isnot [long] -or $v.Process.ProcessStartUtcTicks -lt 1 -or $v.Process.ProcessPath -isnot [string]){return $bad}
        $expected=[ordered]@{ContractVersion=$s.ContractVersion;ControllerId=$s.ControllerId;LocationId=$s.LocationId;Kind=$s.Kind;Ref=$s.Ref;Generation=$s.Generation;Status='ACTIVE';Context=$s.Context;
            Actor=[pscustomobject][ordered]@{UserSid=$v.Process.UserSid;HostMarker=$v.Process.HostMarker;ProfilePath=$v.Process.ProfilePath}}
        if([string]::Equals($s.Kind,'CLIENT_CONTEXT',[StringComparison]::Ordinal)){
            $b=$v.Binaries
            if(-not [string]::Equals($b.SqlClient.Evidence,'ON_DISK_BYTES_ONLY',[StringComparison]::Ordinal) -or -not [string]::Equals($b.Sqlcmd.Evidence,'ON_DISK_BYTES_ONLY',[StringComparison]::Ordinal)){return $bad}
            $expected.Details=[pscustomobject][ordered]@{Store=$v.Store;ClientStacks=$v.ClientStacks;SqlClientPath=$b.SqlClient.Path;SqlClientDiskSha256=$b.SqlClient.DiskSha256;SqlClientDiskBytes=$b.SqlClient.DiskBytes;
                SqlClientAssembly=$b.SqlClientAssembly;SqlClientLoadedMvid=$b.SqlClientLoadedMvid;SqlcmdPath=$b.Sqlcmd.Path;SqlcmdDiskSha256=$b.Sqlcmd.DiskSha256;SqlcmdDiskBytes=$b.Sqlcmd.DiskBytes;
                BinaryEvidence='ON_DISK_BYTES_ONLY';LoadedImageDigestStatus=$b.LoadedImageDigestStatus;SqlcmdFlavorStatus=$b.SqlcmdFlavorStatus;LoadedOdbcDriverStatus=$b.LoadedOdbcDriverStatus}
        }else{
            $expected.Details=[pscustomobject][ordered]@{Backend=$v.Backend.Backend;RuntimeVersion=$v.Backend.RuntimeVersion;ApiStatus=$v.Backend.ApiStatus;Apis=$v.Backend.Apis;KeyProtectionStatus=$v.KeyProtectionStatus}
        }
        $nativeBytes=[Text.UTF8Encoding]::new($false,$true).GetBytes(([pscustomobject]$expected|ConvertTo-Json -Depth 8 -Compress))
        $native=Read-LabAuthenticatedTlsRegistryPayload $nativeBytes
        if(-not $native.Success -or -not [string]::Equals($native.Value.IndexRecord.IdentityDigest,$target.Value.IndexRecord.IdentityDigest,[StringComparison]::Ordinal) -or
            -not [string]::Equals($native.Value.IndexRecord.RevisionDigest,$target.Value.IndexRecord.RevisionDigest,[StringComparison]::Ordinal)){return $bad}
        return [pscustomobject][ordered]@{Success=$true;Value=[pscustomobject][ordered]@{Status='FRESH_PROCESS_METADATA_MATCH';Payload=$parsed.Value.Payload;IndexRecord=$parsed.Value.IndexRecord;
            ProcessId=$v.Process.ProcessId;ProcessStartUtcTicks=$v.Process.ProcessStartUtcTicks;ProcessPath=$v.Process.ProcessPath;
            RootBindingStatus='NOT_EVALUATED';AuthorityTrustScopeStatus='NOT_EVALUATED';RegistrationStatus='NOT_EXECUTED';QualificationStatus='NOT_EXECUTED';Ready=$false;MutationAllowed=$false};ErrorCode=$null}
    }catch{return $bad}
}
