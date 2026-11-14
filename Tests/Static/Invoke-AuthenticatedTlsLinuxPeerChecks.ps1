#Requires -Version 7.5
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$repo=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $PSScriptRoot '../Common/CheckResult.ps1')
. (Join-Path $repo 'Private/AuthenticatedTlsRequest.ps1')
. (Join-Path $repo 'Private/AuthenticatedTlsRegistryIndex.ps1')
. (Join-Path $repo 'Private/AuthenticatedTlsLab.ps1')
. (Join-Path $repo 'Private/AuthenticatedTlsLinuxPeer.ps1')
. (Join-Path $repo 'Private/AuthenticatedTlsLinuxSession.ps1')
$passed=0;$failures=[Collections.Generic.List[string]]::new()
function Check([string]$Name,[scriptblock]$Body){
    try{& $Body;Add-CheckResult $Name $true}catch{Add-CheckResult $Name $false ($_.Exception.Message+' at '+$_.InvocationInfo.ScriptLineNumber)}
}
function Assert([bool]$Pass,[string]$Message){if(-not $Pass){throw $Message}}
function Fixture {
    $script:request=[pscustomobject]@{SessionRef=('a'*64);RequestId='11111111-1111-1111-1111-111111111111';Stack='SYSTEM_DATA_SQLCLIENT';ExportSha256=('b'*64);ClientRef='22222222-2222-2222-2222-222222222222';ContextDigest=('c'*64)}
    $script:reply=[ordered]@{ContractVersion='SqlServerLab.LinuxClientVerificationReply/0.1';Status='VERIFIED';SessionRef=$script:request.SessionRef;RequestId=$script:request.RequestId;Stack=$script:request.Stack;ExportSha256=$script:request.ExportSha256;ClientRef=$script:request.ClientRef;ContextDigest=$script:request.ContextDigest;VerifiedAtUtc='2026-10-26T03:00:00.0000000+00:00';ExpiresAtUtc='2026-10-26T03:00:05.0000000+00:00'}
    $script:reply.QualificationRemainingMilliseconds=180000
    $script:deadline=[DateTimeOffset]'2026-10-26T03:02:00Z'
}
function Read-Reply {
    Read-LabTlsLinuxVerificationReply ([Text.Encoding]::UTF8.GetBytes(($script:reply|ConvertTo-Json -Compress))) $script:request $script:deadline ([TimeSpan]::FromMilliseconds(100))
}
function Reject {
    $rejected=$false
    try{$null=Read-Reply}catch{$rejected=$true}
    Assert $rejected 'Expected reply rejection'
}
function RejectAs([string]$ExpectedCode,[scriptblock]$Read){
    $actual=$null
    try{$null=& $Read}catch{$actual=$_.Exception.Message}
    Assert ($actual-ceq$ExpectedCode) ('Expected safe reply class '+$ExpectedCode)
}
Check 'Exact live request bindings accepted without producing a new export or authority' {
    Fixture
    $r=Read-Reply
    Assert ($r.Status -ceq 'VERIFIED' -and $r.RequestId -ceq $script:request.RequestId) 'Reply mismatch'
}
Check 'Actual controller replies compose with the actual peer parser for both stacks' {
    $script:sessionNow=[DateTimeOffset]'2026-10-26T03:00:00Z'
    $sourceBytes=[Text.Encoding]::UTF8.GetBytes('synthetic-private-bytes')
    $session=New-LabTlsLinuxConsumerSession $sourceBytes '11111111-1111-1111-1111-111111111111' ('c'*64) $script:sessionNow.AddMinutes(2) {
        param($Bytes,$Stack,$ClientRef,$ContextDigest)
        $null=$Stack
        [pscustomobject]@{
            ContractVersion='SqlServerLab.QualifiedTestEnvironmentSnapshot/0.1'
            ExportBytes=[byte[]]$Bytes.Clone()
            ExportSha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
            VerifiedAtUtc=$script:sessionNow.ToString('o')
            Qualification=[pscustomobject]@{Status='QUALIFIED';ClientPlatform='linux';ClientRef=$ClientRef;ClientContextDigest=$ContextDigest;ExpiresAt=$script:sessionNow.AddMinutes(3).ToString('o')}
        }
    } {$script:sessionNow} -QualificationExpiresAt $script:sessionNow.AddMinutes(3)
    foreach($stack in @('SYSTEM_DATA_SQLCLIENT','ODBC_SQLCMD')){
        $request=[pscustomobject]@{ContractVersion='SqlServerLab.LinuxClientVerificationRequest/0.1';SessionRef=$session.SessionRef;RequestId=[guid]::NewGuid().ToString('D');Stack=$stack;ExportSha256=$session.ExportSha256;ClientRef=$session.ClientRef;ContextDigest=$session.ContextDigest}
        $response=Invoke-LabTlsLinuxSessionVerification $session ([Text.Encoding]::UTF8.GetBytes(($request|ConvertTo-Json -Compress)))
        $actual=Read-LabTlsLinuxVerificationReply ([Text.Encoding]::UTF8.GetBytes(($response|ConvertTo-Json -Compress))) $request $session.ExpiresAt ([TimeSpan]::FromMilliseconds(20))
        Assert ($actual.Stack -ceq $stack -and $actual.RequestId -ceq $request.RequestId) 'Producer/consumer mismatch'
    }
    Assert ($session.Requests -eq 2) 'Both requests must be verified independently'
    Close-LabTlsLinuxConsumerSession $session
}
foreach($field in @('ContractVersion','Status','SessionRef','RequestId','Stack','ExportSha256','ClientRef','ContextDigest','VerifiedAtUtc','ExpiresAtUtc')){
    foreach($variant in @('wrong','empty-array','single-array')){
        Check ("Closed reply field: $field/$variant") {
            Fixture
            $old=$script:reply[$field]
            $script:reply[$field]=switch($variant){wrong{'wrong'};empty-array{,([object[]]::new(0))};single-array{,([object[]]@($old))}}
            Reject
        }
    }
}
Check 'Missing reply key blocks' {Fixture;$script:reply.Remove('Status');Reject}
foreach($value in @('40000',40000.5,$true,39999,900001,@(180000))){
    Check 'Controller remaining budget must be a bounded scalar integer' {
        Fixture;$script:reply.QualificationRemainingMilliseconds=$value;Reject
    }
}
Check 'Ten seconds of transit are deducted from the controller open window' {
    Fixture;$script:reply.QualificationRemainingMilliseconds=40000
    $script:reply.ExpiresAtUtc='2026-10-26T03:00:15.0000000+00:00'
    $r=Read-LabTlsLinuxVerificationReply ([Text.Encoding]::UTF8.GetBytes(($script:reply|ConvertTo-Json -Compress))) $script:request $script:deadline ([TimeSpan]::FromSeconds(10))
    Assert ($r.QualificationRemainingMilliseconds-10000 -eq 30000) 'Conservative open window mismatch'
}
Check 'Fifteen-second verifier transit is accepted only with a full post-transit login window' {
    Fixture;$script:reply.QualificationRemainingMilliseconds=45000
    $script:reply.ExpiresAtUtc='2026-10-26T03:00:20.0000000+00:00'
    $r=Read-LabTlsLinuxVerificationReply ([Text.Encoding]::UTF8.GetBytes(($script:reply|ConvertTo-Json -Compress))) $script:request $script:deadline ([TimeSpan]::FromSeconds(15))
    Assert ($r.QualificationRemainingMilliseconds-[Math]::Ceiling(15000)-eq30000) 'Fifteen-second transit must retain thirty seconds before open'
}
Check 'Fifteen-second verifier transit rejects a shorter controller permit' {
    Fixture;$script:reply.ExpiresAtUtc='2026-10-26T03:00:15.0000000+00:00'
    RejectAs 'TLS_LINUX_VERIFIER_REPLY_TIME_REJECTED' {Read-LabTlsLinuxVerificationReply ([Text.Encoding]::UTF8.GetBytes(($script:reply|ConvertTo-Json -Compress))) $script:request $script:deadline ([TimeSpan]::FromSeconds(15))}
}
Check 'Fifteen-second verifier transit rejects a short post-transit login window' {
    Fixture;$script:reply.QualificationRemainingMilliseconds=44999
    $script:reply.ExpiresAtUtc='2026-10-26T03:00:20.0000000+00:00'
    RejectAs 'TLS_LINUX_VERIFIER_REPLY_WINDOW_REJECTED' {Read-LabTlsLinuxVerificationReply ([Text.Encoding]::UTF8.GetBytes(($script:reply|ConvertTo-Json -Compress))) $script:request $script:deadline ([TimeSpan]::FromSeconds(15))}
}
Check 'Additional reply key blocks' {Fixture;$script:reply.Extra='forbidden';Reject}
Check 'Reply cannot extend its controller session' {Fixture;$script:deadline=[DateTimeOffset]'2026-10-26T03:00:04Z';Reject}
Check 'Reply cannot precede its observation' {Fixture;$script:reply.ExpiresAtUtc=$script:reply.VerifiedAtUtc;Reject}
Check 'Reply lifetime must outlast the complete measured exchange' {
    Fixture;$script:reply.ExpiresAtUtc='2026-10-26T03:00:10.0000000+00:00'
    $rejected=$false
    try{$null=Read-LabTlsLinuxVerificationReply ([Text.Encoding]::UTF8.GetBytes(($script:reply|ConvertTo-Json -Compress))) $script:request $script:deadline ([TimeSpan]::FromSeconds(10))}catch{$rejected=$_.Exception.Message-ceq'TLS_LINUX_VERIFIER_REPLY_TIME_REJECTED'}
    Assert $rejected 'A reply expiring at exchange completion is not safely usable'
}
Check 'Reply accepts the exact bounded maximum lifetime' {
    Fixture;$script:reply.ExpiresAtUtc='2026-10-26T03:00:20.0000000+00:00'
    $r=Read-LabTlsLinuxVerificationReply ([Text.Encoding]::UTF8.GetBytes(($script:reply|ConvertTo-Json -Compress))) $script:request $script:deadline ([TimeSpan]::Zero)
    Assert ($r.Status -ceq 'VERIFIED') 'Exact maximum reply lifetime was rejected'
}
Check 'Reply lifetime has a closed upper bound' {Fixture;$script:reply.ExpiresAtUtc='2026-10-26T03:00:21.0000000+00:00';Reject}
foreach($milliseconds in @(-1,10001)){
    Check ("Monotonic exchange budget rejects $milliseconds ms") {
        Fixture;$rejected=$false
        try{$null=Read-LabTlsLinuxVerificationReply ([Text.Encoding]::UTF8.GetBytes(($script:reply|ConvertTo-Json -Compress))) $script:request $script:deadline ([TimeSpan]::FromMilliseconds($milliseconds))}catch{$rejected=$true}
        Assert $rejected 'Expected exchange deadline rejection'
    }
}
Check 'Malformed or oversized frame never becomes a reply' {
    Fixture
    foreach($bytes in @([byte[]]@(255,255),[byte[]]::new(2049),[Text.Encoding]::UTF8.GetBytes('{'))){
        $rejected=$false;try{$null=Read-LabTlsLinuxVerificationReply $bytes $script:request $script:deadline ([TimeSpan]::Zero)}catch{$rejected=$true}
        Assert $rejected 'Expected invalid frame rejection'
    }
}
Check 'Verifier reply failures have closed, data-free diagnostic classes' {
    Fixture
    $codes=[ordered]@{
        Frame='TLS_LINUX_VERIFIER_REPLY_FRAME_REJECTED'
        Schema='TLS_LINUX_VERIFIER_REPLY_SCHEMA_REJECTED'
        Binding='TLS_LINUX_VERIFIER_REPLY_BINDING_REJECTED'
        Time='TLS_LINUX_VERIFIER_REPLY_TIME_REJECTED'
        Window='TLS_LINUX_VERIFIER_REPLY_WINDOW_REJECTED'
        Deadline='TLS_LINUX_VERIFIER_REPLY_DEADLINE_EXCEEDED'
    }
    foreach($code in $codes.Values){
        $envelope=[Text.Encoding]::UTF8.GetBytes((@{Schema='SqlServerLab.TlsLinuxPeerFailure/0.1';Status='FAIL';Code=$code}|ConvertTo-Json -Compress))
        Assert ((Get-LabTlsLinuxBridgeFailureCode $envelope)-ceq$code) 'Safe reply class is not bridge-allowlisted'
    }
    Fixture;$script:reply.Status='REJECTED';RejectAs $codes.Schema {Read-Reply}
    Fixture;$script:reply.RequestId=[guid]::NewGuid().ToString('D');RejectAs $codes.Binding {Read-Reply}
    Fixture;$script:reply.VerifiedAtUtc='invalid';RejectAs $codes.Time {Read-Reply}
    Fixture;$script:reply.QualificationRemainingMilliseconds=34999;RejectAs $codes.Window {Read-Reply}
    Fixture;RejectAs $codes.Deadline {Read-LabTlsLinuxVerificationReply ([Text.Encoding]::UTF8.GetBytes(($script:reply|ConvertTo-Json -Compress))) $script:request $script:deadline ([TimeSpan]::FromMilliseconds(15001))}
    Fixture;RejectAs $codes.Frame {Read-LabTlsLinuxVerificationReply ([byte[]]::new(2049)) $script:request $script:deadline ([TimeSpan]::Zero)}
}
Check 'Public reader rejects absent bootstrap without invoking controller/native handlers' {
    $m=New-Module -ArgumentList $repo -ScriptBlock {
        param($Root)
        . (Join-Path $Root 'Public/Read-SqlServerLabQualifiedTestEnvironment.ps1')
        . (Join-Path $Root 'Private/AuthenticatedTlsLinuxPeer.ps1')
        $script:unsafeCalls=0
        function Read-LabTlsQualifiedExportSnapshot {$script:unsafeCalls++;throw 'SYNTHETIC_NATIVE_FORBIDDEN'}
        $script:Check={
            foreach($mode in @('missing-session','explicit-session')){
                $p=@{ExportBytes=([byte[]]@(1));RunId='synthetic';InstanceId='primary';StateRoot='synthetic'}
                if($mode -ceq 'explicit-session'){$p.LinuxSessionRef='a'*64}
                if($IsWindows -and $mode -ceq 'missing-session'){continue}
                $rejected=$false
                try{$null=Read-SqlServerLabQualifiedTestEnvironment @p}catch{$rejected=$_.Exception.Message -ceq 'TLS_EXPORT_READ_REJECTED'}
                if(-not $rejected -or $script:unsafeCalls-ne0){throw 'PUBLIC_READER_BOOTSTRAP_GUARD_FAILED'}
            }
        }
    }
    try{& $m {& $script:Check}}finally{Remove-Module $m -Force}
}
Check 'Linux reader preserves only closed stage codes and keeps Windows errors generic' {
    $m=New-Module -ArgumentList $repo -ScriptBlock {
        param($Root)
        . (Join-Path $Root 'Private/AuthenticatedTlsLab.ps1')
        . (Join-Path $Root 'Public/Read-SqlServerLabQualifiedTestEnvironment.ps1')
        $script:Check={
            $codes=@(
                'TLS_LINUX_VERIFIER_EXCHANGE_REJECTED','TLS_LINUX_VERIFIER_REPLY_REJECTED',
                'TLS_LINUX_VERIFIER_REPLY_FRAME_REJECTED','TLS_LINUX_VERIFIER_REPLY_SCHEMA_REJECTED',
                'TLS_LINUX_VERIFIER_REPLY_BINDING_REJECTED','TLS_LINUX_VERIFIER_REPLY_TIME_REJECTED',
                'TLS_LINUX_VERIFIER_REPLY_WINDOW_REJECTED','TLS_LINUX_VERIFIER_REPLY_DEADLINE_EXCEEDED'
            )
            foreach($code in $codes){
                if((Get-LabTlsLinuxBridgeFailureCodes)-cnotcontains$code){throw 'BRIDGE_FAILURE_CODE_NOT_ALLOWLISTED'}
                $record=[Management.Automation.ErrorRecord]::new([InvalidOperationException]::new($code),'synthetic',[Management.Automation.ErrorCategory]::NotSpecified,$null)
                if((Get-LabTlsSafeLinuxPeerReadFailureCode $record -Linux)-cne$code){throw 'PUBLIC_READER_DROPPED_SAFE_REPLY_CLASS'}
                if((Get-LabTlsSafeLinuxPeerReadFailureCode $record)-cne'TLS_EXPORT_READ_REJECTED'){throw 'WINDOWS_REVEALED_LINUX_FAILURE_CLASS'}
            }
            $known=[InvalidOperationException]::new('TLS_LINUX_EXPORT_DOCUMENT_INVALID')
            $wrapped=[InvalidOperationException]::new('wrapper path=C:\private password=synthetic-secret',$known)
            $knownCode=Get-LabTlsSafeLinuxPeerReadFailureCode ([Management.Automation.ErrorRecord]::new($wrapped,'synthetic',[Management.Automation.ErrorCategory]::NotSpecified,$null)) -Linux
            $spoof=[InvalidOperationException]::new('TLS_LINUX_EXPORT_DOCUMENT_INVALID password=synthetic-secret')
            $spoofCode=Get-LabTlsSafeLinuxPeerReadFailureCode ([Management.Automation.ErrorRecord]::new($spoof,'synthetic',[Management.Automation.ErrorCategory]::NotSpecified,$null)) -Linux
            $windowsCode=Get-LabTlsSafeLinuxPeerReadFailureCode ([Management.Automation.ErrorRecord]::new($known,'synthetic',[Management.Automation.ErrorCategory]::NotSpecified,$null))
            if($knownCode-cne'TLS_LINUX_EXPORT_DOCUMENT_INVALID' -or $spoofCode-cne'TLS_EXPORT_READ_REJECTED' -or $windowsCode-cne'TLS_EXPORT_READ_REJECTED'){
                throw 'PUBLIC_READER_FAILURE_CLASSIFICATION_FAILED'
            }
        }
    }
    try{& $m {& $script:Check}}finally{Remove-Module $m -Force}
}
[pscustomobject]@{Suite='AuthenticatedTlsLinuxPeer';Passed=$passed;Failed=$failures.Count;ProviderActions=0;SqlLogins=0}|ConvertTo-Json -Compress
if($failures.Count){throw 'TLS_LINUX_PEER_CHECKS_FAILED'}
