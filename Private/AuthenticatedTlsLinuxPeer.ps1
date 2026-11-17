# The private bootstrap owns this channel table and the supervised transport.
# Neither the public reader nor an export can create or select a transport.
function Read-LabTlsLinuxVerificationReply {
    param([byte[]]$Bytes,[object]$Request,[DateTimeOffset]$SessionExpiresAt,[TimeSpan]$RoundTrip)
    if($RoundTrip -lt [TimeSpan]::Zero){throw 'TLS_LINUX_VERIFIER_REPLY_FRAME_REJECTED'}
    if($RoundTrip.TotalSeconds -gt 15){throw 'TLS_LINUX_VERIFIER_REPLY_DEADLINE_EXCEEDED'}
    if($null -eq $Bytes -or $Bytes.Length -lt 1 -or $Bytes.Length -gt 2048){throw 'TLS_LINUX_VERIFIER_REPLY_FRAME_REJECTED'}
    try{
        $reply=Read-LabTlsBoundJson $Bytes @(
            'ContractVersion','Status','SessionRef','RequestId','Stack','ExportSha256',
            'ClientRef','ContextDigest','VerifiedAtUtc','ExpiresAtUtc','QualificationRemainingMilliseconds'
        )
    }catch{throw 'TLS_LINUX_VERIFIER_REPLY_SCHEMA_REJECTED'}
    foreach($name in @('ContractVersion','Status','SessionRef','RequestId','Stack','ExportSha256','ClientRef','ContextDigest','VerifiedAtUtc','ExpiresAtUtc')){
        if($reply.$name -isnot [string]){throw 'TLS_LINUX_VERIFIER_REPLY_SCHEMA_REJECTED'}
    }
    if($reply.ContractVersion -cne 'SqlServerLab.LinuxClientVerificationReply/0.1' -or $reply.Status -cne 'VERIFIED'){throw 'TLS_LINUX_VERIFIER_REPLY_SCHEMA_REJECTED'}
    foreach($name in @('SessionRef','RequestId','Stack','ExportSha256','ClientRef','ContextDigest')){
        if($reply.$name -cne $Request.$name){throw 'TLS_LINUX_VERIFIER_REPLY_BINDING_REJECTED'}
    }
    try{
        $verified=[DateTimeOffset]::ParseExact($reply.VerifiedAtUtc,'o',[Globalization.CultureInfo]::InvariantCulture)
        $expires=[DateTimeOffset]::ParseExact($reply.ExpiresAtUtc,'o',[Globalization.CultureInfo]::InvariantCulture)
    }catch{throw 'TLS_LINUX_VERIFIER_REPLY_TIME_REJECTED'}
    $replyLifetime=$expires-$verified
    if($replyLifetime -le $RoundTrip -or $replyLifetime.TotalSeconds -gt 20 -or
        $expires -gt $SessionExpiresAt){throw 'TLS_LINUX_VERIFIER_REPLY_TIME_REJECTED'}
    if(($reply.QualificationRemainingMilliseconds -isnot [int] -and $reply.QualificationRemainingMilliseconds -isnot [long]) -or
        $reply.QualificationRemainingMilliseconds -lt 40000 -or $reply.QualificationRemainingMilliseconds -gt 900000 -or
        $reply.QualificationRemainingMilliseconds-[Math]::Ceiling($RoundTrip.TotalMilliseconds) -lt 30000){throw 'TLS_LINUX_VERIFIER_REPLY_WINDOW_REJECTED'}
    # Freshness comes from an unpredictable nonce on the live private transport
    # and the monotonic exchange deadline, not subtraction of clocks on two OSes.
    # The controller independently enforces its original UTC and monotonic TTL.
    return $reply
}

function Read-LabTlsLinuxPeerSnapshot {
    param([byte[]]$ExportBytes,[string]$SessionRef,[string]$ClientStack,[string]$StateRoot,[string]$RunId,[string]$InstanceId)
    $channel=$null;$copy=$null;$failureCode='TLS_LINUX_PEER_REJECTED'
    try{
        if(-not $IsLinux -or $SessionRef -cnotmatch '\A[0-9a-f]{64}\z' -or
            $ClientStack -cnotin @('SYSTEM_DATA_SQLCLIENT','ODBC_SQLCMD')){throw 'REJECT'}
        $channels=Get-Variable -Name SqlServerLabTlsLinuxPeerChannels -Scope Script -ValueOnly -ErrorAction SilentlyContinue
        if($null -eq $channels -or -not $channels.ContainsKey($SessionRef)){throw 'REJECT'}
        $channel=$channels[$SessionRef]
        if($channel.State -cne 'OPEN' -or $channel.InFlight -ne $false -or $channel.Requests -ge 16 -or
            $channel.ProcessId -ne $PID -or $channel.ProcessStartTicks -ne (Get-Process -Id $PID).StartTime.ToUniversalTime().Ticks -or
            $channel.Lifetime.Elapsed -ge $channel.MaximumElapsed -or
            $StateRoot -cne $channel.ControllerStateRoot -or $RunId -cne $channel.RunId -or $InstanceId -cne $channel.InstanceId -or
            $null -eq $ExportBytes -or $ExportBytes.Length -lt 1 -or $ExportBytes.Length -gt 65536){throw 'REJECT'}
        $copy=[byte[]]$ExportBytes.Clone()
        $hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($copy)).ToLowerInvariant()
        if($hash -cne $channel.ExportSha256){throw 'REJECT'}
        $request=[pscustomobject][ordered]@{
            ContractVersion='SqlServerLab.LinuxClientVerificationRequest/0.1'
            SessionRef=$SessionRef;RequestId=[guid]::NewGuid().ToString('D');Stack=$ClientStack
            ExportSha256=$hash;ClientRef=$channel.ClientRef;ContextDigest=$channel.ContextDigest
        }
        $channel.Requests++;$channel.InFlight=$true
        $requestBytes=[Text.UTF8Encoding]::new($false).GetBytes(($request|ConvertTo-Json -Compress))
        $roundTrip=[Diagnostics.Stopwatch]::StartNew()
        $failureCode='TLS_LINUX_VERIFIER_EXCHANGE_REJECTED'
        $replyBytes=& $channel.Exchange $requestBytes
        $failureCode='TLS_LINUX_VERIFIER_REPLY_REJECTED'
        try{$reply=Read-LabTlsLinuxVerificationReply $replyBytes $request $channel.ExpiresAt $roundTrip.Elapsed}
        catch{
            if((Get-LabTlsLinuxBridgeFailureCodes)-ccontains$_.Exception.Message){$failureCode=$_.Exception.Message}
            throw
        }
        if($channel.State -cne 'OPEN' -or $channel.Lifetime.Elapsed -ge $channel.MaximumElapsed){throw 'REJECT'}
        # The controller has just checked the signature/schema and current
        # registered bindings of these exact bytes. This is not a file reread.
        $failureCode='TLS_LINUX_EXPORT_DOCUMENT_INVALID'
        $doc=Read-LabTlsBoundJson $copy @('$schema','contractVersion','generatedAt','groupStatus','selectionRule','containsPlainTextSecrets','environments','qualification')
        $failureCode='TLS_LINUX_EXPORT_PAYLOAD_INVALID'
        $bodyBytes=[Convert]::FromBase64String($doc.qualification.payload)
        $body=Read-LabTlsBoundJson $bodyBytes @('ContractVersion','EnvironmentSha256','Qualification')
        $failureCode='TLS_LINUX_EXPORT_BINDING_INVALID'
        $q=$body.Qualification
        foreach($name in @('ClientRef','ClientContextDigest','ClientPlatform','ExpiresAt')){
            if($q.$name -isnot [string]){throw 'REJECT'}
        }
        if($doc.contractVersion -cne 'SqlServerLab.TestEnvironment/2.0' -or
            $q.ClientPlatform -cne 'linux' -or $q.ClientRef -cne $channel.ClientRef -or
            $q.ClientContextDigest -cne $channel.ContextDigest -or
            $reply.QualificationRemainingMilliseconds-[Math]::Ceiling($roundTrip.Elapsed.TotalMilliseconds) -lt 30000){throw 'REJECT'}
        return [pscustomobject][ordered]@{
            ContractVersion='SqlServerLab.QualifiedTestEnvironmentSnapshot/0.1'
            ExportSha256=$hash;ExportBytes=[byte[]]$copy.Clone();Contract=$doc
            Qualification=$q;VerifiedAtUtc=$reply.VerifiedAtUtc
            LinuxConnectWindow=[pscustomobject]@{
                ContractVersion='SqlServerLab.LinuxConnectWindow/0.1'
                RemainingAtApprovalMilliseconds=$reply.QualificationRemainingMilliseconds
                Clock=$roundTrip
            }
        }
    }catch{
        if($null -ne $channel){
            $channel.State='BLOCKED'
            if($channel.ExportBytes -is [byte[]]){[Array]::Clear($channel.ExportBytes,0,$channel.ExportBytes.Length)}
        }
        throw $failureCode
    }finally{
        if($null -ne $copy){[Array]::Clear($copy,0,$copy.Length)}
        if($null -ne $channel){$channel.InFlight=$false}
    }
}
