#Requires -Version 7.2
# Reiner Offline-Referenzindex. Keine native Payload, Registrierung oder I/O.

function Get-LabTlsIndexFields {
    param([Text.Json.JsonElement]$Element,[string[]]$Names)
    if($Element.ValueKind -ne [Text.Json.JsonValueKind]::Object){throw 'TLS_INDEX_INVALID'}
    $fields=[Collections.Generic.Dictionary[string,Text.Json.JsonElement]]::new([StringComparer]::Ordinal)
    $allowed=[Collections.Generic.HashSet[string]]::new($Names,[StringComparer]::Ordinal)
    foreach($property in $Element.EnumerateObject()){
        if(-not $allowed.Contains($property.Name) -or $fields.ContainsKey($property.Name)){throw 'TLS_INDEX_INVALID'}
        $fields.Add($property.Name,$property.Value)
    }
    if($fields.Count -ne $Names.Count){throw 'TLS_INDEX_INVALID'}
    return ,$fields
}

function Get-LabTlsIndexString {
    param([Text.Json.JsonElement]$Element)
    if($Element.ValueKind -ne [Text.Json.JsonValueKind]::String){throw 'TLS_INDEX_INVALID'}
    return $Element.GetString()
}

function Get-LabTlsIndexInteger {
    param([Text.Json.JsonElement]$Element,[int]$Minimum)
    $number=0
    if($Element.ValueKind -ne [Text.Json.JsonValueKind]::Number -or -not $Element.TryGetInt32([ref]$number) -or $number -lt $Minimum){throw 'TLS_INDEX_INVALID'}
    return $number
}

function Read-LabAuthenticatedTlsRegistryIndex {
    [CmdletBinding()]
    param([object]$Utf8Json)
    $bad=[pscustomobject][ordered]@{Success=$false;Value=$null;ErrorCode='TLS_REGISTRY_INDEX_INVALID'}
    $document=$null
    try{
        if($null -eq $Utf8Json -or [object].GetMethod('GetType').Invoke($Utf8Json,$null) -ne [byte[]]){return $bad}
        $length=[array].GetProperty('Length').GetValue($Utf8Json)
        if($length -lt 1 -or $length -gt 131072){return $bad}
        $bytes=[byte[]]::new($length);[Buffer]::BlockCopy($Utf8Json,0,$bytes,0,$length)
        $text=[Text.UTF8Encoding]::new($false,$true).GetString($bytes)
        $options=[Text.Json.JsonDocumentOptions]::new();$options.MaxDepth=6
        $options.AllowTrailingCommas=$false;$options.CommentHandling=[Text.Json.JsonCommentHandling]::Disallow
        $document=[Text.Json.JsonDocument]::Parse($text,$options)
        $root=Get-LabTlsIndexFields $document.RootElement @('ContractVersion','ControllerId','LocationId','Revision','Records')
        if(-not (Test-LabTlsRequestEnum (Get-LabTlsIndexString $root['ContractVersion']) @('SqlServerLab.AuthenticatedTlsRegistryIndex/0.1'))){return $bad}
        $controller=Get-LabTlsIndexString $root['ControllerId'];$location=Get-LabTlsIndexString $root['LocationId']
        if(-not (Test-LabTlsRequestReference $controller) -or -not (Test-LabTlsRequestReference $location)){return $bad}
        $revision=Get-LabTlsIndexInteger $root['Revision'] 0
        $array=$root['Records']
        if($array.ValueKind -ne [Text.Json.JsonValueKind]::Array -or $array.GetArrayLength() -gt 256 -or
            ($revision -eq 0 -and $array.GetArrayLength() -ne 0) -or ($revision -gt 0 -and $array.GetArrayLength() -eq 0)){return $bad}
        $records=[Collections.Generic.List[object]]::new()
        $byRef=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
        foreach($element in $array.EnumerateArray()){
            $kindElement=[Text.Json.JsonElement]::new()
            if($element.ValueKind -ne [Text.Json.JsonValueKind]::Object -or -not $element.TryGetProperty('Kind',[ref]$kindElement)){return $bad}
            $kind=Get-LabTlsIndexString $kindElement
            if(-not (Test-LabTlsRequestEnum $kind @('CLIENT_CONTEXT','SIGNER_CONTEXT','AUTHORITY'))){return $bad}
            $names=@('Kind','Ref','Generation','Status','IdentityDigest','RevisionDigest')
            if([string]::Equals($kind,'AUTHORITY',[StringComparison]::Ordinal)){$names+=@('SignerContextRef','SignerGeneration')}
            $fields=Get-LabTlsIndexFields $element $names
            $ref=Get-LabTlsIndexString $fields['Ref'];$status=Get-LabTlsIndexString $fields['Status']
            $identity=Get-LabTlsIndexString $fields['IdentityDigest'];$digest=Get-LabTlsIndexString $fields['RevisionDigest']
            if(-not (Test-LabTlsRequestReference $ref) -or $byRef.ContainsKey($ref) -or
                -not (Test-LabTlsRequestEnum $status @('ACTIVE','RETIRED')) -or
                $identity -cnotmatch '\A[0-9a-f]{64}\z' -or $digest -cnotmatch '\A[0-9a-f]{64}\z'){return $bad}
            $value=[ordered]@{Kind=$kind;Ref=$ref;Generation=(Get-LabTlsIndexInteger $fields['Generation'] 1);Status=$status;IdentityDigest=$identity;RevisionDigest=$digest}
            if([string]::Equals($kind,'AUTHORITY',[StringComparison]::Ordinal)){
                $signer=Get-LabTlsIndexString $fields['SignerContextRef']
                if(-not (Test-LabTlsRequestReference $signer)){return $bad}
                $value.SignerContextRef=$signer;$value.SignerGeneration=Get-LabTlsIndexInteger $fields['SignerGeneration'] 1
            }
            $record=[pscustomobject]$value;$records.Add($record);$byRef.Add($ref,$record)
        }
        foreach($record in $records){
            if(-not [string]::Equals($record.Kind,'AUTHORITY',[StringComparison]::Ordinal)){continue}
            if(-not $byRef.ContainsKey($record.SignerContextRef)){return $bad}
            $signer=$byRef[$record.SignerContextRef]
            if(-not [string]::Equals($signer.Kind,'SIGNER_CONTEXT',[StringComparison]::Ordinal) -or $record.SignerGeneration -gt $signer.Generation){return $bad}
            if([string]::Equals($record.Status,'ACTIVE',[StringComparison]::Ordinal) -and
                (-not [string]::Equals($signer.Status,'ACTIVE',[StringComparison]::Ordinal) -or $record.SignerGeneration -ne $signer.Generation)){return $bad}
        }
        return [pscustomobject][ordered]@{Success=$true;Value=[pscustomobject][ordered]@{
            ContractVersion='SqlServerLab.AuthenticatedTlsRegistryIndex/0.1';ControllerId=$controller;LocationId=$location;Revision=$revision;Records=$records.ToArray()
        };ErrorCode=$null}
    }catch{return $bad}finally{if($null -ne $document){$document.Dispose()}}
}

function Test-LabAuthenticatedTlsRegistryTransition {
    [CmdletBinding()]
    param([object]$CurrentBytes,[object]$CandidateBytes)
    $bad=[pscustomobject][ordered]@{Success=$false;Value=$null;ErrorCode='TLS_REGISTRY_TRANSITION_INVALID'}
    $current=Read-LabAuthenticatedTlsRegistryIndex $CurrentBytes
    $candidate=Read-LabAuthenticatedTlsRegistryIndex $CandidateBytes
    if(-not $current.Success -or -not $candidate.Success){return $bad}
    $before=$current.Value;$after=$candidate.Value
    if(-not [string]::Equals($before.ControllerId,$after.ControllerId,[StringComparison]::Ordinal) -or
        -not [string]::Equals($before.LocationId,$after.LocationId,[StringComparison]::Ordinal) -or
        [long]$after.Revision -ne ([long]$before.Revision+1)){return $bad}
    $old=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    $next=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    foreach($record in $before.Records){$old.Add($record.Ref,$record)}
    foreach($record in $after.Records){$next.Add($record.Ref,$record)}
    $added=[Collections.Generic.List[string]]::new();$updated=[Collections.Generic.List[string]]::new();$retired=[Collections.Generic.List[string]]::new()
    foreach($record in $before.Records){
        if(-not $next.ContainsKey($record.Ref)){return $bad}
        $replacement=$next[$record.Ref]
        if(-not [string]::Equals($record.Kind,$replacement.Kind,[StringComparison]::Ordinal) -or
            -not [string]::Equals($record.IdentityDigest,$replacement.IdentityDigest,[StringComparison]::Ordinal)){return $bad}
        $isAuthority=[string]::Equals($record.Kind,'AUTHORITY',[StringComparison]::Ordinal)
        if($isAuthority -and -not [string]::Equals($record.SignerContextRef,$replacement.SignerContextRef,[StringComparison]::Ordinal)){return $bad}
        $sameDigest=[string]::Equals($record.RevisionDigest,$replacement.RevisionDigest,[StringComparison]::Ordinal)
        $sameGeneration=$record.Generation -eq $replacement.Generation
        $sameEdge=(-not $isAuthority -or $record.SignerGeneration -eq $replacement.SignerGeneration)
        $sameStatus=[string]::Equals($record.Status,$replacement.Status,[StringComparison]::Ordinal)
        if([string]::Equals($record.Status,'RETIRED',[StringComparison]::Ordinal)){
            if(-not $sameDigest -or -not $sameGeneration -or -not $sameStatus -or -not $sameEdge){return $bad}
            continue
        }
        if(-not $sameStatus){
            if(-not $sameDigest -or -not $sameGeneration -or -not $sameEdge){return $bad}
            $retired.Add($record.Ref);continue
        }
        if($sameGeneration){if(-not $sameDigest -or -not $sameEdge){return $bad};continue}
        if([long]$replacement.Generation -ne ([long]$record.Generation+1) -or $sameDigest -or
            ($isAuthority -and $replacement.SignerGeneration -lt $record.SignerGeneration)){return $bad}
        $updated.Add($record.Ref)
    }
    foreach($record in $after.Records){
        if($old.ContainsKey($record.Ref)){continue}
        if($record.Generation -ne 1 -or -not [string]::Equals($record.Status,'ACTIVE',[StringComparison]::Ordinal)){return $bad}
        $added.Add($record.Ref)
    }
    if($added.Count+$updated.Count+$retired.Count -eq 0){return $bad}
    $adds=$added.ToArray();$updates=$updated.ToArray();$retires=$retired.ToArray()
    [array]::Sort($adds,[StringComparer]::Ordinal);[array]::Sort($updates,[StringComparer]::Ordinal);[array]::Sort($retires,[StringComparer]::Ordinal)
    return [pscustomobject][ordered]@{Success=$true;Value=[pscustomobject][ordered]@{
        ContractVersion='SqlServerLab.AuthenticatedTlsRegistryTransition/0.1';Status='OFFLINE_TRANSITION_ONLY'
        ControllerId=$after.ControllerId;LocationId=$after.LocationId;BaseRevision=$before.Revision;NextRevision=$after.Revision
        AddedRefs=$adds;UpdatedRefs=$updates;RetiredRefs=$retires;RegistrationStatus='NOT_EXECUTED';QualificationStatus='NOT_EXECUTED';Ready=$false;MutationAllowed=$false
    };ErrorCode=$null}
}
