#Requires -Version 7.5
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $PSScriptRoot '../Common/CheckResult.ps1')
. (Join-Path $repo 'Private/AuthenticatedTlsRequest.ps1')
. (Join-Path $repo 'Private/AuthenticatedTlsRegistryIndex.ps1')
. (Join-Path $repo 'Private/AuthenticatedTlsLab.ps1')
. (Join-Path $repo 'Private/AuthenticatedTlsLinuxSession.ps1')
$passed = 0
$failures = [Collections.Generic.List[string]]::new()

function Check([string]$Name, [scriptblock]$Body) {
    try {
        & $Body
        Add-CheckResult $Name $true
    } catch {
        Add-CheckResult $Name $false ($_.Exception.Message + ' at ' + $_.InvocationInfo.ScriptLineNumber)
    }
}
function Assert([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function New-Fixture {
    $script:ClockNow = [DateTimeOffset]'2026-10-26T03:00:00Z'
    $script:QualificationExpiresAt = $script:ClockNow.AddMinutes(3)
    $script:Bytes = [Text.Encoding]::UTF8.GetBytes('{"synthetic":"private export bytes"}')
    $script:Calls = 0
    $script:Session = New-LabTlsLinuxConsumerSession $script:Bytes '11111111-1111-1111-1111-111111111111' ('b' * 64) $script:ClockNow.AddMinutes(2) {
        param($Bytes, $Stack, $ClientRef, $ContextDigest)
        $null = $Bytes, $Stack, $ClientRef, $ContextDigest
        $script:Calls++
        New-Snapshot
    } { $script:ClockNow } -QualificationExpiresAt $script:QualificationExpiresAt
}
function New-Snapshot {
    [pscustomobject]@{
        ContractVersion = 'SqlServerLab.QualifiedTestEnvironmentSnapshot/0.1'
        ExportBytes = [byte[]]$script:Bytes.Clone()
        ExportSha256 = $script:Session.ExportSha256
        VerifiedAtUtc = $script:ClockNow.ToString('o')
        Qualification = [pscustomobject]@{
            Status = 'QUALIFIED'; ClientPlatform = 'linux'
            ClientRef = $script:Session.ClientRef
            ClientContextDigest = $script:Session.ContextDigest
            ExpiresAt = $script:QualificationExpiresAt.ToString('o')
        }
    }
}
function New-Request([string]$Stack = 'SYSTEM_DATA_SQLCLIENT') {
    [ordered]@{
        ContractVersion = 'SqlServerLab.LinuxClientVerificationRequest/0.1'
        SessionRef = $script:Session.SessionRef
        RequestId = [guid]::NewGuid().ToString('D'); Stack = $Stack
        ExportSha256 = $script:Session.ExportSha256
        ClientRef = $script:Session.ClientRef
        ContextDigest = $script:Session.ContextDigest
    }
}
function Bytes($Request) {
    [Text.Encoding]::UTF8.GetBytes(($Request | ConvertTo-Json -Compress))
}
function Reject([byte[]]$Request, [int]$ExpectedCalls = 0) {
    $rejected = $false
    try { $null = Invoke-LabTlsLinuxSessionVerification $script:Session $Request }
    catch { $rejected = $_.Exception.Message -ceq 'TLS_LINUX_SESSION_REJECTED' }
    Assert $rejected 'Expected closed session rejection'
    Assert ($script:Calls -eq $ExpectedCalls) "Expected verifier calls=$ExpectedCalls; actual=$script:Calls"
    Assert ($script:Session.State -ceq 'BLOCKED') 'Rejected session must be latched BLOCKED'
    Assert (@($script:Session.ExportBytes | Where-Object { $_ -ne 0 }).Count -eq 0) 'Rejected private snapshot must be zeroed'
}

Check 'Both stacks require separate fresh calls and replies contain no export or credentials' {
    New-Fixture
    foreach ($stack in @('SYSTEM_DATA_SQLCLIENT','ODBC_SQLCMD')) {
        $request = New-Request $stack
        $reply = Invoke-LabTlsLinuxSessionVerification $script:Session (Bytes $request)
        Assert ($reply.Status -ceq 'VERIFIED' -and $reply.RequestId -ceq $request.RequestId -and $reply.Stack -ceq $stack) 'Reply binding mismatch'
        Assert (@($reply.PSObject.Properties).Count -eq 11 -and $null -eq $reply.PSObject.Properties['ExportBytes']) 'Reply shape/private data mismatch'
        Assert ($reply.QualificationRemainingMilliseconds -ge 35000 -and $reply.QualificationRemainingMilliseconds -le 180000) 'Controller open window mismatch'
        Assert ([DateTimeOffset]::Parse($reply.ExpiresAtUtc) -eq $script:ClockNow.AddSeconds(5)) 'Expected five-second acknowledgement'
    }
    Assert ($script:Calls -eq 2) 'Each stack must reverify'
}
Check 'Original byte mutation does not change session-owned snapshot' {
    New-Fixture
    $original = $script:Session.ExportBytes[0]
    $script:Bytes[0] = 0
    Assert ($script:Session.ExportBytes[0] -eq $original) 'Input alias leaked into session'
}
Check 'Duplicate nonce closes session before second verifier call' {
    New-Fixture
    $request = Bytes (New-Request)
    $null = Invoke-LabTlsLinuxSessionVerification $script:Session $request
    Reject $request 1
}
foreach ($field in @('ContractVersion','SessionRef','RequestId','Stack','ExportSha256','ClientRef','ContextDigest')) {
    Check ("Changed request binding: " + $field) {
        New-Fixture
        $request = New-Request
        $request[$field] = 'wrong'
        Reject (Bytes $request)
    }
    Check ("Non-string request field: " + $field) {
        New-Fixture
        $request = New-Request
        $request[$field] = @('not','scalar')
        Reject (Bytes $request)
    }
}
foreach ($mode in @('missing','extra','duplicate','case-duplicate','invalid-utf8','oversize','invalid-json','empty')) {
    Check ("Closed request framing: " + $mode) {
        New-Fixture
        $request = New-Request
        $text = $request | ConvertTo-Json -Compress
        switch ($mode) {
            missing { $request.Remove('Stack'); $inputBytes = Bytes $request }
            extra { $request.Extra = 'forbidden'; $inputBytes = Bytes $request }
            duplicate { $inputBytes = [Text.Encoding]::UTF8.GetBytes($text.Replace('{"ContractVersion":','{"Stack":"ODBC_SQLCMD","ContractVersion":')) }
            case-duplicate { $inputBytes = [Text.Encoding]::UTF8.GetBytes($text.Replace('{"ContractVersion":','{"stack":"ODBC_SQLCMD","ContractVersion":')) }
            invalid-utf8 { $inputBytes = [byte[]]@(255,255) }
            oversize { $inputBytes = [byte[]]::new(2049) }
            invalid-json { $inputBytes = [Text.Encoding]::UTF8.GetBytes('{') }
            empty { $inputBytes = [byte[]]::new(0) }
        }
        Reject $inputBytes
    }
}
Check 'Expired session rejects without calling the controller' {
    New-Fixture
    $script:ClockNow = $script:Session.ExpiresAt
    Reject (Bytes (New-Request))
}
Check 'UTC rollback before first request cannot extend the session' {
    New-Fixture
    $script:ClockNow = $script:ClockNow.AddTicks(-1)
    Reject (Bytes (New-Request))
}
Check 'UTC rollback after a successful request blocks the next approval' {
    New-Fixture
    $script:ClockNow = $script:ClockNow.AddSeconds(10)
    $null = Invoke-LabTlsLinuxSessionVerification $script:Session (Bytes (New-Request))
    $script:ClockNow = $script:ClockNow.AddTicks(-1)
    Reject (Bytes (New-Request)) 1
}
Check 'A frozen UTC clock cannot outlive the monotonic session budget' {
    New-Fixture
    $script:Session = New-LabTlsLinuxConsumerSession $script:Bytes $script:Session.ClientRef ('b' * 64) $script:ClockNow.AddMilliseconds(10) {
        param($Bytes,$Stack,$ClientRef,$ContextDigest)
        $null = $Bytes,$Stack,$ClientRef,$ContextDigest
        $script:Calls++
        New-Snapshot
    } { $script:ClockNow } -QualificationExpiresAt $script:QualificationExpiresAt
    Start-Sleep -Milliseconds 30
    Reject (Bytes (New-Request))
}
Check 'Expiry during verification rejects a late result' {
    New-Fixture
    $script:Session.Verify = {
        param($Bytes,$Stack,$ClientRef,$ContextDigest)
        $null = $Bytes,$Stack,$ClientRef,$ContextDigest
        $script:Calls++
        $script:ClockNow = $script:Session.ExpiresAt
        New-Snapshot
    }
    Reject (Bytes (New-Request)) 1
}
foreach ($mode in @('false','array','throw','bytes','hash','ref','context','windows','status','future','old','expiry')) {
    Check ("Controller snapshot rejects: " + $mode) {
        New-Fixture
        $script:SnapshotMode = $mode
        $script:Session.Verify = {
            param($Bytes,$Stack,$ClientRef,$ContextDigest)
            $null = $Bytes,$Stack,$ClientRef,$ContextDigest
            $script:Calls++
            $snapshot = New-Snapshot
            switch ($script:SnapshotMode) {
                false { return $false }
                array { return @($snapshot,$snapshot) }
                throw { throw 'SYNTHETIC_PRIVATE_CONTROLLER_FAILURE' }
                bytes { $snapshot.ExportBytes[0] = 0 }
                hash { $snapshot.ExportSha256 = 'c' * 64 }
                ref { $snapshot.Qualification.ClientRef = 'foreign-client' }
                context { $snapshot.Qualification.ClientContextDigest = 'c' * 64 }
                windows { $snapshot.Qualification.ClientPlatform = 'windows' }
                status { $snapshot.Qualification.Status = 'UNQUALIFIED' }
                future { $snapshot.VerifiedAtUtc = $script:ClockNow.AddTicks(1).ToString('o') }
                old { $snapshot.VerifiedAtUtc = $script:ClockNow.AddSeconds(-6).ToString('o') }
                expiry { $snapshot.Qualification.ExpiresAt = $script:Session.ExpiresAt.AddTicks(-1).ToString('o') }
            }
            return $snapshot
        }
        Reject (Bytes (New-Request)) 1
    }
}
Check 'Callback re-entry blocks outer approval as well' {
    New-Fixture
    $script:Session.Verify = {
        param($Bytes,$Stack,$ClientRef,$ContextDigest)
        $null = $Bytes,$Stack,$ClientRef,$ContextDigest
        $script:Calls++
        try { $null = Invoke-LabTlsLinuxSessionVerification $script:Session (Bytes (New-Request)) } catch {}
        New-Snapshot
    }
    Reject (Bytes (New-Request)) 1
}
foreach ($area in @('Snapshot','Qualification')) {
    $names = if ($area -ceq 'Snapshot') { @('ContractVersion','ExportSha256','VerifiedAtUtc') }
             else { @('Status','ClientPlatform','ClientRef','ClientContextDigest','ExpiresAt') }
    foreach ($field in $names) {
        foreach ($variant in @('empty','single','nested')) {
            Check ("Controller scalar boundary: $area.$field/$variant") {
                New-Fixture
                $script:FieldSpec = @{Area=$area;Field=$field;Variant=$variant}
                $script:Session.Verify = {
                    param($Bytes,$Stack,$ClientRef,$ContextDigest)
                    $null = $Bytes,$Stack,$ClientRef,$ContextDigest
                    $script:Calls++
                    $snapshot = New-Snapshot
                    $target = if ($script:FieldSpec.Area -ceq 'Snapshot') { $snapshot } else { $snapshot.Qualification }
                    $value = $target.($script:FieldSpec.Field)
                    $bad = switch ($script:FieldSpec.Variant) {
                        empty { ,([object[]]::new(0)) }
                        single { ,([object[]]@($value)) }
                        nested { ,([object[]]@(,([object[]]@($value)))) }
                    }
                    $target.($script:FieldSpec.Field) = $bad
                    $snapshot
                }
                Reject (Bytes (New-Request)) 1
            }
        }
    }
}
Check 'Sixteen requests maximum, seventeenth has no controller action' {
    New-Fixture
    for ($i = 0; $i -lt 16; $i++) {
        $null = Invoke-LabTlsLinuxSessionVerification $script:Session (Bytes (New-Request))
    }
    Reject (Bytes (New-Request)) 16
}
Check 'Explicit close erases the snapshot and rejects later use' {
    New-Fixture
    Close-LabTlsLinuxConsumerSession $script:Session
    Assert ($script:Session.State -ceq 'CLOSED') 'Close status mismatch'
    Reject (Bytes (New-Request))
}
Check 'Acknowledgement cannot outlive the session' {
    New-Fixture
    $script:ClockNow = $script:Session.ExpiresAt.AddSeconds(-1)
    $reply = Invoke-LabTlsLinuxSessionVerification $script:Session (Bytes (New-Request))
    Assert ([DateTimeOffset]::Parse($reply.ExpiresAtUtc) -eq $script:Session.ExpiresAt) 'Acknowledgement extended expiry'
}
foreach ($mode in @('empty','oversize','reference','digest','expired','too-long','no-verifier','missing-qualification','short-qualification','session-beyond-open-window')) {
    Check ("Constructor rejects: " + $mode) {
        New-Fixture
        $p = @{
            ExportBytes=$script:Bytes;ClientRef=$script:Session.ClientRef;ContextDigest=$script:Session.ContextDigest
            ExpiresAt=$script:Session.ExpiresAt;Verify={ New-Snapshot };Clock={ $script:ClockNow };QualificationExpiresAt=$script:QualificationExpiresAt
        }
        switch ($mode) {
            empty { $p.ExportBytes = [byte[]]::new(0) }
            oversize { $p.ExportBytes = [byte[]]::new(65537) }
            reference { $p.ClientRef = '../foreign' }
            digest { $p.ContextDigest = 'b' * 63 }
            expired { $p.ExpiresAt = $script:ClockNow }
            too-long { $p.ExpiresAt = $script:ClockNow.AddMinutes(5).AddTicks(1) }
            no-verifier { $p.Verify = $null }
            missing-qualification { $p.Remove('QualificationExpiresAt') }
            short-qualification { $p.QualificationExpiresAt = $script:ClockNow.AddSeconds(34) }
            session-beyond-open-window { $p.QualificationExpiresAt = $script:ClockNow.AddMinutes(2) }
        }
        $rejected = $false
        try { $null = New-LabTlsLinuxConsumerSession @p } catch { $rejected = $_.Exception.Message -ceq 'TLS_LINUX_SESSION_INVALID' }
        Assert $rejected 'Expected constructor rejection'
    }
}
[pscustomobject]@{Suite='AuthenticatedTlsLinuxSession';Passed=$passed;Failed=$failures.Count;ProviderActions=0;SqlLogins=0} | ConvertTo-Json -Compress
if ($failures.Count) { throw 'TLS_LINUX_SESSION_CHECKS_FAILED' }
