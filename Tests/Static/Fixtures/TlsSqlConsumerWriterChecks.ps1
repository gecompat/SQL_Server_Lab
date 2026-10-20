#Requires -Version 7.2
[CmdletBinding()]
param([Parameter(Mandatory)][string]$RepoRoot)
$ErrorActionPreference='Stop'
$passed=0;$failures=[Collections.Generic.List[string]]::new()
. (Join-Path $PSScriptRoot '../../Common/CheckResult.ps1')
foreach($name in @('AuthenticatedTlsRequest','AuthenticatedTlsRegistryIndex','AuthenticatedTlsRegistryPayload','AuthenticatedTlsCaCandidate','AuthenticatedTlsConsumerJournal','AuthenticatedTlsSqlConsumerWriter','AuthenticatedTlsHyperVSqlConsumer')){. (Join-Path $RepoRoot "Private/$name.ps1")}
if(-not $IsWindows){Write-Host 'TLS SQL writer Windows ACL fixtures NOT_EXECUTED';return}
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-tls-sql-consumers-'+[guid]::NewGuid().ToString('N'))
$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$null=New-Item -ItemType Directory -Path (Join-Path $fixture 'State') -Force
# Only registration/actor discovery is synthetic. Files, ACLs and writes are real.
function Assert-LabDiagnosticPath([string]$Path){
    $full=[IO.Path]::GetFullPath($Path)
    if(-not $full.StartsWith($fixture+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'FIXTURE_PATH_ESCAPE'}
    $item=[IO.FileInfo]::new($full)
    while($null -ne $item){if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -and $item.Exists){throw 'FIXTURE_REPARSE'};$item=$item.Directory}
    return $full
}
function Get-LabTlsRegistryWriterBinding {
    [pscustomobject]@{Root=[pscustomobject]@{DataRoot=$fixture;RootMetadataDigest=('a'*64)};Native=[pscustomobject]@{UserSid=$sid};ActorDigest=('d'*64)}
}
function Assert-LabTlsRegistryWriterBinding($Binding,$RootDigest,$ActorDigest){
    if($RootDigest -cne ('a'*64) -or $ActorDigest -cne ('d'*64)){throw 'FIXTURE_STALE_ROOT'}
}
function Read-LabTlsRegistryWriterRecord($Path,$UserSid,$Names){
    $bytes=Read-LabTlsCaPrivateFile $Path $UserSid 16384
    $doc=[Text.Json.JsonDocument]::Parse([Text.Encoding]::UTF8.GetString($bytes))
    try{$fields=Get-LabTlsIndexFields $doc.RootElement $Names;$record=[ordered]@{};foreach($name in $Names){$record[$name]=Get-LabTlsIndexString $fields[$name]};[pscustomobject]$record}finally{$doc.Dispose()}
}
function ConvertTo-LabTlsRegistryWriterBytes($Value){,[Text.Encoding]::UTF8.GetBytes(($Value|ConvertTo-Json -Depth 12 -Compress))}
$ids=@{DataRoot=$fixture;ControllerId='11111111-1111-4111-8111-111111111111';LocationId='22222222-2222-4222-8222-222222222222';OperationId='33333333-3333-4333-8333-333333333333';RunId='44444444-4444-4444-8444-444444444444';ScopeId='55555555-5555-4555-8555-555555555555';VmId='66666666-6666-4666-8666-666666666666';SourceDigest=('b'*64);WorkerDigest=('c'*64)}
try{
    $session=New-LabTlsSqlConsumerSession @ids
    Add-CheckResult 'TLS-SW durable PREPARED readback with actual private ACL' (Test-Path (Join-Path $session.Directory '00-PREPARED.json'))
    $duplicate=$false;try{$null=New-LabTlsSqlConsumerSession @ids}catch{$duplicate=$true}
    Add-CheckResult 'TLS-SW CreateNew refuses same attempt replay' $duplicate
    $different=@{};foreach($key in $ids.Keys){$different[$key]=$ids[$key]};$different.OperationId='77777777-7777-4777-8777-777777777777'
    $duplicate=$false;try{$null=New-LabTlsSqlConsumerSession @different}catch{$duplicate=$true}
    Add-CheckResult 'TLS-SW new operation cannot bypass persistent VM reservation' $duplicate
    $first=[IO.File]::ReadAllBytes((Join-Path $session.Directory '00-PREPARED.json'))
    $record=Write-LabTlsSqlConsumerStage $session DISPATCHED
    Add-CheckResult 'TLS-SW durable dispatch still grants no end or cleanup authority' ($record.Phase -ceq 'DISPATCHED' -and $record.ConsumerEnd -ceq 'NOT_PROVEN' -and -not $record.CleanupAllowed)
    $duplicate=$false;try{$null=Write-LabTlsSqlConsumerStage $session DISPATCHED}catch{$duplicate=$true}
    Add-CheckResult 'TLS-SW dispatch cannot replay' $duplicate
    $null=Write-LabTlsSqlConsumerStage $session REPLY_OBSERVED
    Write-LabTlsSqlConsumerEvidence $session 'setup-reply.json' @{Synthetic=$true}
    Write-LabTlsSqlConsumerEvidence $session 'postsetup-reply.json' @(@{Success=$false;ConsumerEnded=$true;ErrorCode='TLS_SQL_READINESS_TIMEOUT'})
    $failedReply=ConvertFrom-Json ([Text.Encoding]::UTF8.GetString((Read-LabTlsCaPrivateFile (Join-Path $session.Directory 'postsetup-reply.json') $sid 65536)))
    Add-CheckResult 'TLS-SW durable failed post-setup reply survives without granting retry' (-not $failedReply[0].Success -and $failedReply[0].ConsumerEnded -and $failedReply[0].ErrorCode -ceq 'TLS_SQL_READINESS_TIMEOUT')
    $last=Write-LabTlsSqlConsumerStage $session RECOVERY_REQUIRED
    Add-CheckResult 'TLS-SW immutable predecessors and conservative terminal state' ([Convert]::ToBase64String($first) -ceq [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $session.Directory '00-PREPARED.json'))) -and $last.Phase -ceq 'RECOVERY_REQUIRED' -and -not $last.RetryAllowed)
    $ids.OperationId='88888888-8888-4888-8888-888888888888';$ids.VmId='99999999-9999-4999-8999-999999999999'
    $partial=New-LabTlsSqlConsumerSession @ids
    Write-LabTlsCaPrivateFile (Join-Path $partial.Directory '01-DISPATCHED.json') $sid ([Text.Encoding]::UTF8.GetBytes('{'))
    $blocked=$false;try{$null=Write-LabTlsSqlConsumerStage $partial DISPATCHED}catch{$blocked=$true}
    Add-CheckResult 'TLS-SW crash-partial snapshot survives and blocks replay' ($blocked -and [IO.File]::ReadAllText((Join-Path $partial.Directory '01-DISPATCHED.json')) -ceq '{')
    $partial.Ids.RootDigest='e'*64
    $blocked=$false;try{$null=Write-LabTlsSqlConsumerStage $partial RECOVERY_REQUIRED}catch{$blocked=$true}
    Add-CheckResult 'TLS-SW stale fresh root prevents write' $blocked
    $parseErrors=$null;$tokens=$null
    $guest=[Management.Automation.Language.Parser]::ParseInput((Get-LabTlsSqlSetupGuestScript).ToString(),[ref]$tokens,[ref]$parseErrors)
    $kills=@($guest.FindAll({param($node)$node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -in @('Stop-Process','Stop-VM','Restart-Computer','Stop-Computer')},$true))
    Add-CheckResult 'TLS-SW setup timeout has no destructive recovery command' ($parseErrors.Count -eq 0 -and $kills.Count -eq 0)
    Write-Host "TLS SQL Consumer Writer: $passed PASS, $($failures.Count) FAIL"
    if($failures.Count){throw 'TLS_SQL_CONSUMER_WRITER_CHECKS_FAILED'}
}finally{
    $full=[IO.Path]::GetFullPath($fixture);$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    if(-not $full.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -cnotmatch '\Asql-lab-tls-sql-consumers-[a-f0-9]{32}\z'){throw 'TLS_SQL_FIXTURE_CLEANUP_BOUNDARY'}
    if(Test-Path -LiteralPath $full){Remove-Item -LiteralPath $full -Recurse -Force}
}
