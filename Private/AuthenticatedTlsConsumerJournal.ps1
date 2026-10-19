#Requires -Version 7.2
# A closed read model, not an end attestation, writer, executor, or cleanup permit.
function Read-LabTlsSqlConsumerJournal {
    [CmdletBinding()]
    param(
        [object]$Utf8Json,
        [object]$OperationId,[object]$RunId,[object]$ScopeId,[object]$VmId,
        [object]$RootDigest,[object]$SourceDigest,[object]$WorkerDigest
    )
    $bad=[pscustomobject][ordered]@{Success=$false;Value=$null;ErrorCode='TLS_CONSUMER_JOURNAL_INVALID'}
    $document=$null
    try {
        foreach($id in @($OperationId,$RunId,$ScopeId,$VmId)) { if(-not (Test-LabTlsRequestReference $id)){return $bad} }
        foreach($hash in @($RootDigest,$SourceDigest,$WorkerDigest)) { if($hash -isnot [string] -or $hash -cnotmatch '\A[a-f0-9]{64}\z'){return $bad} }
        if($null -eq $Utf8Json -or [object].GetMethod('GetType').Invoke($Utf8Json,$null) -ne [byte[]]){return $bad}
        $length=[array].GetProperty('Length').GetValue($Utf8Json)
        if($length -lt 1 -or $length -gt 65536){return $bad}
        $bytes=[byte[]]::new($length);[Buffer]::BlockCopy($Utf8Json,0,$bytes,0,$length)
        $options=[Text.Json.JsonDocumentOptions]::new();$options.MaxDepth=5
        $document=[Text.Json.JsonDocument]::Parse([Text.UTF8Encoding]::new($false,$true).GetString($bytes),$options)
        $root=Get-LabTlsIndexFields $document.RootElement @('ContractVersion','OperationId','RunId','ScopeId','VmId','RootDigest','SourceDigest','WorkerDigest','Events')
        if((Get-LabTlsIndexString $root['ContractVersion']) -cne 'SqlServerLab.TlsSqlConsumerJournal/0.1'){return $bad}
        $expected=@{OperationId=$OperationId;RunId=$RunId;ScopeId=$ScopeId;VmId=$VmId;RootDigest=$RootDigest;SourceDigest=$SourceDigest;WorkerDigest=$WorkerDigest}
        foreach($key in $expected.Keys){if(-not [string]::Equals((Get-LabTlsIndexString $root[$key]),$expected[$key],[StringComparison]::Ordinal)){return $bad}}
        $events=$root['Events']
        if($events.ValueKind -ne [Text.Json.JsonValueKind]::Array -or $events.GetArrayLength() -lt 1 -or $events.GetArrayLength() -gt 16){return $bad}
        $phase='';$entered=$false;$previous=('0'*64);$sequence=0
        foreach($event in $events.EnumerateArray()) {
            $fields=Get-LabTlsIndexFields $event @('Sequence','Phase','EffectEntered','PreviousSha256')
            if((Get-LabTlsIndexInteger $fields['Sequence'] 0) -ne $sequence -or (Get-LabTlsIndexString $fields['PreviousSha256']) -cne $previous){return $bad}
            if($fields['EffectEntered'].ValueKind -notin @([Text.Json.JsonValueKind]::True,[Text.Json.JsonValueKind]::False)){return $bad}
            $next=Get-LabTlsIndexString $fields['Phase'];$effect=$fields['EffectEntered'].GetBoolean()
            $allowed=switch($phase){
                '' {@('PREPARED')}
                'PREPARED' {@('DISPATCHED','ABORTED_NO_EFFECT')}
                'DISPATCHED' {@('REPLY_OBSERVED','RECOVERY_REQUIRED')}
                'REPLY_OBSERVED' {@('RECOVERY_REQUIRED')}
                default {@()}
            }
            if($next -cnotin $allowed -or $effect -ne ($next -cin @('DISPATCHED','REPLY_OBSERVED','RECOVERY_REQUIRED')) -or ($entered -and -not $effect)){return $bad}
            $phase=$next;$entered=$effect;$sequence++
            # Exact UTF8 event representation, including property order, links the records.
            $previous=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($event.GetRawText()))).ToLowerInvariant()
        }
        $status=if($entered){'RECOVERY_REQUIRED'}elseif($phase -ceq 'ABORTED_NO_EFFECT'){'PRE_EFFECT_ABORT_RECORDED'}else{'PREPARED_NOT_AUTHORIZED'}
        return [pscustomobject][ordered]@{Success=$true;Value=[pscustomobject][ordered]@{
            OperationId=$OperationId;Phase=$phase;Status=$status;EventCount=$sequence;EffectEntered=$entered
            JournalSha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
            ConsumerEnd='NOT_PROVEN';EndAttestationRequired=$true
            Ready=$false;MutationAllowed=$false;RetryAllowed=$false;StopAllowed=$false;CleanupAllowed=$false
        };ErrorCode=$null}
    } catch {return $bad} finally {if($null -ne $document){$document.Dispose()}}
}

function Get-LabTlsSqlConsumerRecoveryStatus {
    [CmdletBinding()]
    param(
        [object]$Anchor,[object]$OperationId,[object]$RunId,[object]$ScopeId,[object]$VmId,
        [object]$RootDigest,[object]$SourceDigest,[object]$WorkerDigest
    )
    $bad=[pscustomobject][ordered]@{Success=$false;Value=$null;ErrorCode='TLS_CONSUMER_RECOVERY_STATUS_INVALID'}
    try {
        foreach($id in @($OperationId,$RunId,$ScopeId,$VmId)){if(-not (Test-LabTlsRequestReference $id)){return $bad}}
        foreach($hash in @($RootDigest,$SourceDigest,$WorkerDigest)){if($hash -isnot [string] -or $hash -cnotmatch '\A[a-f0-9]{64}\z'){return $bad}}
        $bytes=Read-LabTlsAnchoredFile -Anchor $Anchor -RelativePath ('State/authenticated-tls/sql-completion/'+$OperationId+'.json') -MaximumBytes 65536
        $result=Read-LabTlsSqlConsumerJournal -Utf8Json $bytes -OperationId $OperationId -RunId $RunId -ScopeId $ScopeId -VmId $VmId -RootDigest $RootDigest -SourceDigest $SourceDigest -WorkerDigest $WorkerDigest
        if(-not $result.Success){return $bad}
        return $result
    } catch {return $bad}
}
