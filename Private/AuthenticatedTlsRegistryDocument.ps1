#Requires -Version 7.2
# Vollstaendige Metadatenform im Speicher; keine Registry-I/O oder Autoritaet.

function Read-LabAuthenticatedTlsRegistryDocument {
    [CmdletBinding()]
    param([object]$Utf8Json)
    $bad=[pscustomobject][ordered]@{Success=$false;Value=$null;ErrorCode='TLS_REGISTRY_DOCUMENT_INVALID'};$document=$null
    try{
        if($null -eq $Utf8Json -or [object].GetMethod('GetType').Invoke($Utf8Json,$null) -ne [byte[]]){return $bad}
        $length=[array].GetProperty('Length').GetValue($Utf8Json)
        if($length -lt 1 -or $length -gt 4194304){return $bad}
        $bytes=[byte[]]::new($length);[Buffer]::BlockCopy($Utf8Json,0,$bytes,0,$length)
        $options=[Text.Json.JsonDocumentOptions]::new();$options.MaxDepth=8
        $document=[Text.Json.JsonDocument]::Parse([Text.UTF8Encoding]::new($false,$true).GetString($bytes),$options)
        $root=Get-LabTlsIndexFields $document.RootElement @('ContractVersion','Index','Payloads')
        if(-not (Test-LabTlsRequestEnum (Get-LabTlsIndexString $root['ContractVersion']) @('SqlServerLab.AuthenticatedTlsContextRegistry/0.1'))){return $bad}
        $index=Read-LabAuthenticatedTlsRegistryIndex ([Text.Encoding]::UTF8.GetBytes($root['Index'].GetRawText()))
        if(-not $index.Success){return $bad}
        $array=$root['Payloads']
        if($array.ValueKind -ne [Text.Json.JsonValueKind]::Array -or $array.GetArrayLength() -gt 256 -or $array.GetArrayLength() -ne $index.Value.Records.Count){return $bad}
        $byRef=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
        foreach($record in $index.Value.Records){$byRef.Add($record.Ref,$record)}
        $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $payloads=[Collections.Generic.List[object]]::new()
        foreach($element in $array.EnumerateArray()){
            $parsed=Read-LabAuthenticatedTlsRegistryPayload ([Text.Encoding]::UTF8.GetBytes($element.GetRawText()))
            if(-not $parsed.Success){return $bad}
            $p=$parsed.Value.Payload;$derived=$parsed.Value.IndexRecord
            if(-not $seen.Add($p.Ref) -or -not $byRef.ContainsKey($p.Ref) -or
                -not [string]::Equals($p.ControllerId,$index.Value.ControllerId,[StringComparison]::Ordinal) -or
                -not [string]::Equals($p.LocationId,$index.Value.LocationId,[StringComparison]::Ordinal)){return $bad}
            $record=$byRef[$p.Ref]
            foreach($name in @('Kind','Ref','Status','IdentityDigest','RevisionDigest')){
                if(-not [string]::Equals($record.$name,$derived.$name,[StringComparison]::Ordinal)){return $bad}
            }
            if($record.Generation -ne $derived.Generation){return $bad}
            if([string]::Equals($record.Kind,'AUTHORITY',[StringComparison]::Ordinal) -and
                (-not [string]::Equals($record.SignerContextRef,$derived.SignerContextRef,[StringComparison]::Ordinal) -or $record.SignerGeneration -ne $derived.SignerGeneration)){return $bad}
            $payloads.Add($p)
        }
        # Reihenfolge ist Darstellung, nicht Identitaet. Keine Rohfile-CAS-Behauptung.
        $refs=[string[]]@($byRef.Keys);[array]::Sort($refs,[StringComparer]::Ordinal)
        $atoms=[Collections.Generic.List[string]]::new()
        foreach($atom in @('SqlServerLab.TlsRegistryDocument/0.1',$index.Value.ControllerId,$index.Value.LocationId,$index.Value.Revision.ToString([Globalization.CultureInfo]::InvariantCulture))){$atoms.Add($atom)}
        foreach($ref in $refs){
            $r=$byRef[$ref]
            foreach($atom in @($r.Kind,$r.Ref,$r.Generation.ToString([Globalization.CultureInfo]::InvariantCulture),$r.Status,$r.IdentityDigest,$r.RevisionDigest)){$atoms.Add($atom)}
            if([string]::Equals($r.Kind,'AUTHORITY',[StringComparison]::Ordinal)){$atoms.Add($r.SignerContextRef);$atoms.Add($r.SignerGeneration.ToString([Globalization.CultureInfo]::InvariantCulture))}
        }
        $digest=Get-LabTlsPayloadDigest $atoms.ToArray()
        return [pscustomobject][ordered]@{Success=$true;Value=[pscustomobject][ordered]@{
            Status='OFFLINE_REGISTRY_ONLY';RegistryDocument=[pscustomobject][ordered]@{ContractVersion='SqlServerLab.AuthenticatedTlsContextRegistry/0.1';Index=$index.Value;Payloads=$payloads.ToArray()}
            ContentDigest=$digest;RootBindingStatus='NOT_EVALUATED';NativeBindingStatus='NOT_EXECUTED';RegistrationStatus='NOT_EXECUTED';QualificationStatus='NOT_EXECUTED';Ready=$false;MutationAllowed=$false
        };ErrorCode=$null}
    }catch{return $bad}finally{if($null -ne $document){$document.Dispose()}}
}

function Test-LabAuthenticatedTlsRegistryDocumentTransition {
    [CmdletBinding()]
    param([object]$CurrentBytes,[object]$CandidateBytes)
    $bad=[pscustomobject][ordered]@{Success=$false;Value=$null;ErrorCode='TLS_REGISTRY_DOCUMENT_TRANSITION_INVALID'}
    try{
        $before=Read-LabAuthenticatedTlsRegistryDocument $CurrentBytes;$after=Read-LabAuthenticatedTlsRegistryDocument $CandidateBytes
        if(-not $before.Success -or -not $after.Success){return $bad}
        $left=[Text.Encoding]::UTF8.GetBytes(($before.Value.RegistryDocument.Index|ConvertTo-Json -Depth 6 -Compress))
        $right=[Text.Encoding]::UTF8.GetBytes(($after.Value.RegistryDocument.Index|ConvertTo-Json -Depth 6 -Compress))
        $delta=Test-LabAuthenticatedTlsRegistryTransition $left $right
        if(-not $delta.Success){return $bad}
        return [pscustomobject][ordered]@{Success=$true;Value=[pscustomobject][ordered]@{
            Status='OFFLINE_REGISTRY_TRANSITION_ONLY';CurrentContentDigest=$before.Value.ContentDigest;NextContentDigest=$after.Value.ContentDigest;Delta=$delta.Value
            RootBindingStatus='NOT_EVALUATED';NativeBindingStatus='NOT_EXECUTED';RegistrationStatus='NOT_EXECUTED';QualificationStatus='NOT_EXECUTED';Ready=$false;MutationAllowed=$false
        };ErrorCode=$null}
    }catch{return $bad}
}
