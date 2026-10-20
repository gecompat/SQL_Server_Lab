#Requires -Version 7.2
# Closed byte construction and read model; no durable writer or execution permit.
function New-LabTlsSqlConsumerJournalBytes {
    [CmdletBinding()]
    param(
        [object]$OperationId,[object]$RunId,[object]$ScopeId,[object]$VmId,
        [object]$RootDigest,[object]$SourceDigest,[object]$WorkerDigest,
        [object]$PreviousUtf8Json,[object]$ExpectedJournalSha256,
        [object]$NextPhase='PREPARED'
    )
    $bad=[pscustomobject][ordered]@{Success=$false;Value=$null;ErrorCode='TLS_CONSUMER_JOURNAL_BYTES_INVALID'}
    $document=$null;$stream=$null;$writer=$null
    try {
        foreach($id in @($OperationId,$RunId,$ScopeId,$VmId)){if(-not (Test-LabTlsRequestReference $id)){return $bad}}
        foreach($hash in @($RootDigest,$SourceDigest,$WorkerDigest)){if($hash -isnot [string] -or $hash -cnotmatch '\A[a-f0-9]{64}\z'){return $bad}}
        if($NextPhase -isnot [string] -or $NextPhase -cnotin @('PREPARED','ABORTED_NO_EFFECT','DISPATCHED','REPLY_OBSERVED','RECOVERY_REQUIRED')){return $bad}
        $binding=[ordered]@{OperationId=$OperationId;RunId=$RunId;ScopeId=$ScopeId;VmId=$VmId;RootDigest=$RootDigest;SourceDigest=$SourceDigest;WorkerDigest=$WorkerDigest}
        $events=[Collections.Generic.List[string]]::new()
        if($PSBoundParameters.ContainsKey('PreviousUtf8Json')){
            if($null -eq $PreviousUtf8Json -or [object].GetMethod('GetType').Invoke($PreviousUtf8Json,$null) -ne [byte[]] -or
                $ExpectedJournalSha256 -isnot [string] -or $ExpectedJournalSha256 -cnotmatch '\A[a-f0-9]{64}\z'){return $bad}
            $length=[array].GetProperty('Length').GetValue($PreviousUtf8Json)
            if($length -lt 1 -or $length -gt 65536){return $bad}
            # One owned snapshot is used both for validation and construction.
            $snapshot=[byte[]]::new($length);[Buffer]::BlockCopy($PreviousUtf8Json,0,$snapshot,0,$length)
            $previous=Read-LabTlsSqlConsumerJournal -Utf8Json $snapshot @binding
            if(-not $previous.Success -or $previous.Value.JournalSha256 -cne $ExpectedJournalSha256){return $bad}
            $document=[Text.Json.JsonDocument]::Parse([Text.UTF8Encoding]::new($false,$true).GetString($snapshot))
            foreach($event in $document.RootElement.GetProperty('Events').EnumerateArray()){$events.Add($event.GetRawText())}
        }elseif($PSBoundParameters.ContainsKey('ExpectedJournalSha256') -or $NextPhase -cne 'PREPARED'){
            return $bad
        }
        $previousHash=if($events.Count){[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($events[$events.Count-1]))).ToLowerInvariant()}else{'0'*64}
        $next=[ordered]@{Sequence=$events.Count;Phase=$NextPhase;EffectEntered=($NextPhase -cin @('DISPATCHED','REPLY_OBSERVED','RECOVERY_REQUIRED'));PreviousSha256=$previousHash}
        $events.Add(($next|ConvertTo-Json -Depth 3 -Compress))
        $stream=[IO.MemoryStream]::new();$writer=[Text.Json.Utf8JsonWriter]::new($stream)
        $writer.WriteStartObject();$writer.WriteString('ContractVersion','SqlServerLab.TlsSqlConsumerJournal/0.1')
        foreach($key in $binding.Keys){$writer.WriteString($key,[string]$binding[$key])}
        $writer.WritePropertyName('Events');$writer.WriteStartArray()
        # Reserializing an old event would invalidate subsequent exact-byte links.
        foreach($raw in $events){$writer.WriteRawValue($raw,$false)}
        $writer.WriteEndArray();$writer.WriteEndObject();$writer.Flush()
        $candidate=$stream.ToArray()
        $checked=Read-LabTlsSqlConsumerJournal -Utf8Json $candidate @binding
        if(-not $checked.Success){return $bad}
        return [pscustomobject][ordered]@{Success=$true;Value=[pscustomobject][ordered]@{Utf8Json=$candidate;Journal=$checked.Value};ErrorCode=$null}
    }catch{return $bad}finally{
        if($null -ne $writer){$writer.Dispose()};if($null -ne $stream){$stream.Dispose()};if($null -ne $document){$document.Dispose()}
    }
}

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
