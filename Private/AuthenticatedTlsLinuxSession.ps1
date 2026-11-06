# Private protocol kernel, not a runtime or registration capability. The native
# controller owns the session table and its exact supervised Linux transport.
# A serialized session, an export, or a reply never creates controller authority.
function New-LabTlsLinuxConsumerSession {
    param(
        [byte[]]$ExportBytes, [string]$ClientRef, [string]$ContextDigest,
        [DateTimeOffset]$ExpiresAt, [scriptblock]$Verify,
        [scriptblock]$Clock = { [DateTimeOffset]::UtcNow },
        [DateTimeOffset]$QualificationExpiresAt = [DateTimeOffset]::MinValue
    )
    $now = & $Clock
    if ($now -isnot [DateTimeOffset] -or $null -eq $Verify -or
        $null -eq $ExportBytes -or $ExportBytes.Length -lt 1 -or $ExportBytes.Length -gt 65536 -or
        -not (Test-LabTlsRequestReference $ClientRef) -or
        $ContextDigest -cnotmatch '\A[0-9a-f]{64}\z' -or
        $ExpiresAt -le $now -or $ExpiresAt -gt $now.AddMinutes(5)) {
        throw 'TLS_LINUX_SESSION_INVALID'
    }
    $qualificationRemaining=($QualificationExpiresAt-$now).TotalMilliseconds
    # Five seconds cover the bounded exchange; thirty remain for the login.
    if($qualificationRemaining -lt 35000 -or $qualificationRemaining -gt 900000 -or
        $ExpiresAt -gt $QualificationExpiresAt.AddSeconds(-35)){throw 'TLS_LINUX_SESSION_INVALID'}
    return [pscustomobject]@{
        SessionRef = [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(32)).ToLowerInvariant()
        State = 'OPEN'; InFlight = $false; Requests = 0
        RequestIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        ExportBytes = [byte[]]$ExportBytes.Clone()
        ExportSha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($ExportBytes)).ToLowerInvariant()
        ClientRef = $ClientRef; ContextDigest = $ContextDigest
        CreatedAtUtc = $now; LastObservedAtUtc = $now
        Lifetime = [Diagnostics.Stopwatch]::StartNew()
        MaximumElapsed = $ExpiresAt - $now
        QualificationExpiresAt = $QualificationExpiresAt
        QualificationRemainingAtCreationMilliseconds = [long][Math]::Floor($qualificationRemaining)
        ExpiresAt = $ExpiresAt; Verify = $Verify; Clock = $Clock
    }
}

function Close-LabTlsLinuxConsumerSession {
    param([object]$Session, [switch]$Blocked)
    $Session.State = if ($Blocked) { 'BLOCKED' } else { 'CLOSED' }
    if ($Session.ExportBytes -is [byte[]]) {
        [Array]::Clear($Session.ExportBytes, 0, $Session.ExportBytes.Length)
    }
}

function Invoke-LabTlsLinuxSessionVerification {
    param([object]$Session, [byte[]]$RequestBytes)
    $copy = $null
    try {
        # Dispatch is serial. Re-entry blocks both the nested and outer call.
        if ($Session.State -cne 'OPEN' -or $Session.InFlight -ne $false -or
            $Session.Requests -ge 16) { throw 'REJECT' }
        $now = & $Session.Clock
        if ($now -isnot [DateTimeOffset] -or $now -lt $Session.LastObservedAtUtc -or
            $now -ge $Session.ExpiresAt -or $Session.Lifetime.Elapsed -ge $Session.MaximumElapsed -or
            $null -eq $RequestBytes -or $RequestBytes.Length -lt 1 -or
            $RequestBytes.Length -gt 2048) { throw 'REJECT' }
        $request = Read-LabTlsBoundJson $RequestBytes @(
            'ContractVersion','SessionRef','RequestId','Stack',
            'ExportSha256','ClientRef','ContextDigest'
        )
        foreach ($name in @('ContractVersion','SessionRef','RequestId','Stack','ExportSha256','ClientRef','ContextDigest')) {
            if ($request.$name -isnot [string]) { throw 'REJECT' }
        }
        if ($request.ContractVersion -cne 'SqlServerLab.LinuxClientVerificationRequest/0.1' -or
            $request.SessionRef -cne $Session.SessionRef -or
            $request.RequestId -cnotmatch '\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z' -or
            $request.Stack -cnotin @('SYSTEM_DATA_SQLCLIENT','ODBC_SQLCMD') -or
            $request.ExportSha256 -cne $Session.ExportSha256 -or
            $request.ClientRef -cne $Session.ClientRef -or
            $request.ContextDigest -cne $Session.ContextDigest -or
            -not $Session.RequestIds.Add($request.RequestId)) { throw 'REJECT' }
        $Session.Requests++
        $Session.LastObservedAtUtc = $now
        $Session.InFlight = $true
        $copy = [byte[]]$Session.ExportBytes.Clone()
        # Only the current controller reader is supplied by the transport.
        # No callback, module or root is obtained from an export.
        $snapshot = & $Session.Verify $copy $request.Stack $Session.ClientRef $Session.ContextDigest
        $after = & $Session.Clock
        if ($Session.State -cne 'OPEN' -or $after -isnot [DateTimeOffset] -or
            $after -lt $now -or $after -ge $Session.ExpiresAt -or
            $Session.Lifetime.Elapsed -ge $Session.MaximumElapsed -or
            $snapshot -isnot [pscustomobject]) { throw 'REJECT' }
        foreach ($name in @('ContractVersion','ExportSha256','VerifiedAtUtc')) {
            if ($snapshot.$name -isnot [string]) { throw 'REJECT' }
        }
        if ($snapshot.ContractVersion -cne 'SqlServerLab.QualifiedTestEnvironmentSnapshot/0.1' -or
            $snapshot.ExportBytes -isnot [byte[]] -or
            $snapshot.ExportSha256 -cne $Session.ExportSha256 -or
            [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($snapshot.ExportBytes)).ToLowerInvariant() -cne $Session.ExportSha256) {
            throw 'REJECT'
        }
        $q = $snapshot.Qualification
        if ($q -isnot [pscustomobject]) { throw 'REJECT' }
        foreach ($name in @('Status','ClientPlatform','ClientRef','ClientContextDigest','ExpiresAt')) {
            if ($q.$name -isnot [string]) { throw 'REJECT' }
        }
        $verifiedAt = [DateTimeOffset]::ParseExact($snapshot.VerifiedAtUtc, 'o', [Globalization.CultureInfo]::InvariantCulture)
        $qualificationExpires = [DateTimeOffset]::ParseExact($q.ExpiresAt, 'o', [Globalization.CultureInfo]::InvariantCulture)
        if ($q.Status -cne 'QUALIFIED' -or $q.ClientPlatform -cne 'linux' -or
            $q.ClientRef -cne $Session.ClientRef -or $q.ClientContextDigest -cne $Session.ContextDigest -or
            $verifiedAt -gt $after -or ($after - $verifiedAt).TotalSeconds -gt 5 -or
            $qualificationExpires -ne $Session.QualificationExpiresAt) { throw 'REJECT' }
        $Session.LastObservedAtUtc = $after
        $remaining=[long][Math]::Floor([Math]::Min(
            ($qualificationExpires-$after).TotalMilliseconds,
            ($Session.QualificationRemainingAtCreationMilliseconds-$Session.Lifetime.Elapsed.TotalMilliseconds)))
        if($remaining -lt 35000){throw 'REJECT'}
        $permitExpires = $after.AddSeconds(5)
        if ($permitExpires -gt $Session.ExpiresAt) { $permitExpires = $Session.ExpiresAt }
        # An acknowledgement on the live private transport, not another export,
        # signature, or runtime lease.
        return [pscustomobject][ordered]@{
            ContractVersion = 'SqlServerLab.LinuxClientVerificationReply/0.1'
            Status = 'VERIFIED'; SessionRef = $Session.SessionRef
            RequestId = $request.RequestId; Stack = $request.Stack
            ExportSha256 = $Session.ExportSha256
            ClientRef = $Session.ClientRef; ContextDigest = $Session.ContextDigest
            VerifiedAtUtc = $verifiedAt.ToString('o')
            ExpiresAtUtc = $permitExpires.ToString('o')
            QualificationRemainingMilliseconds = $remaining
        }
    } catch {
        Close-LabTlsLinuxConsumerSession $Session -Blocked
        throw 'TLS_LINUX_SESSION_REJECTED'
    } finally {
        if ($null -ne $copy) { [Array]::Clear($copy, 0, $copy.Length) }
        $Session.InFlight = $false
    }
}
