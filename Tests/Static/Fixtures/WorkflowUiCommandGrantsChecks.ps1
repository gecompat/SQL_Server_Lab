#Requires -Version 7.2
$ErrorActionPreference='Stop'
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
. (Join-Path $repo 'Tools/WorkflowUiJsonBody.ps1')
. (Join-Path $PSScriptRoot 'WorkflowUiCommandGrantFixture.ps1')
$script:passed=0
function Check([string]$Name,[bool]$Ok){if(-not $Ok){throw ('COMMAND_GRANT_CHECK_FAILED: '+$Name)};$script:passed++;Write-Host ('PASS '+$Name)}
function Denied([scriptblock]$Action,[string]$Code='UI_COMMAND_GRANT_REQUIRED'){try{$null=&$Action;return $false}catch{return $_.Exception.Message -ceq $Code}}
function Request([string]$Path='/api/command-grants',[string]$Method='POST'){
 [pscustomobject]@{Url=[uri]('http://127.0.0.1:18484'+$Path);HttpMethod=$Method;Headers=[Collections.Specialized.NameValueCollection]::new()}
}
$json='{"commandName":"synthetic","parameterSetName":"synthetic","parameters":{"Target":"same","Plan":"fresh","Consent":true,"Transient":"LOCAL_SYNTHETIC_ONLY"},"confirmed":true}'
$bytes=[Text.Encoding]::UTF8.GetBytes($json)
$catalog=@(Get-UiCommandGrantCatalog)
Check 'Bekannter Katalog und Parametersatz mit echter Zustimmung' ($null -ne (Get-UiCommandGrantRequest $json $catalog))
foreach($bad in @($json.Replace('"confirmed":true','"confirmed":"false"'),$json.Replace('"confirmed":true','"confirmed":false'),$json.Replace('"synthetic"','"not-exported"'),$json.Replace('"parameterSetName":"synthetic"','"parameterSetName":"other"'),$json.Replace('"confirmed":true','"confirmed":true,"Confirmed":false'),$json.Replace('"Target":"same"','"Target":"same","target":"other"'),$json.Replace('"confirmed":true','"confirmed":true,"extra":null'))){Check 'Missgebildete/mehrdeutige/ungeklärte Anfrage vor jedem Executor gesperrt' (Denied {Get-UiCommandGrantRequest $bad $catalog} 'UI_COMMAND_REQUEST_INVALID')}
$session=[pscustomobject]@{Active=$true;Capability=('a'*64);ListenerUrl='http://127.0.0.1:18484/'}
$store=New-UiCommandGrantStore $session -Quota 6
try {
 $a=New-UiCommandGrant $store $session (Request) $bytes;$b=New-UiCommandGrant $store $session (Request) $bytes
 Check 'Frische disjunkte 256bit-Grants und getrennte Receipts' ($a.grant -cmatch '^[a-f0-9]{64}$' -and $a.grant -cne $b.grant -and $a.receiptId -cne $b.receiptId)
 Check 'Store hält keine Body-/Parameterwerte oder Granttokens' (($store.Receipts.Values|ConvertTo-Json -Depth 5) -notmatch 'LOCAL_SYNTHETIC_ONLY|commandName|"grant"')
 $r=Request '/api/commands';$r.Headers.Add('X-SqlServerLab-Action-Grant',$a.grant)
 foreach($mutated in @($json+' ',$json.Replace('same','s\u0061me'),$json.Replace('same','other'),$json.Replace('fresh','stale'),$json.Replace('"Consent":true','"Consent":false'),$json.Replace('LOCAL_SYNTHETIC_ONLY','OTHER_SYNTHETIC_ONLY'))){Check 'Exakte Byte-/Ziel-/Plan-/Consent-/Transientbindung' (Denied {Use-UiCommandGrant $store $session $r ([Text.Encoding]::UTF8.GetBytes($mutated))})}
 $r.Headers.Add('X-SqlServerLab-Action-Grant',$a.grant);Check 'Doppelter Grantheader gesperrt' (Denied {Use-UiCommandGrant $store $session $r $bytes});$r.Headers.Remove('X-SqlServerLab-Action-Grant');$r.Headers.Add('X-SqlServerLab-Action-Grant',$a.grant)
 foreach($path in @('/api/actions','/api/command-grants','/api/commands?mode=other')){$r.Url=[uri]('http://127.0.0.1:18484'+$path);Check 'Andere Route oder Query gesperrt' (Denied {Use-UiCommandGrant $store $session $r $bytes})}
 $r.Url=[uri]'http://127.0.0.1:18485/api/commands';Check 'Andere Listenerbindung gesperrt' (Denied {Use-UiCommandGrant $store $session $r $bytes})
 $r=Request '/api/commands' 'GET';$r.Headers.Add('X-SqlServerLab-Action-Grant',$a.grant);Check 'Andere Methode gesperrt' (Denied {Use-UiCommandGrant $store $session $r $bytes})
 $other=[pscustomobject]@{Active=$true;Capability=('a'*64);ListenerUrl=$session.ListenerUrl};$r=Request '/api/commands';$r.Headers.Add('X-SqlServerLab-Action-Grant',$a.grant);Check 'Andere Operatorsitzung auch mit gleichen Factwerten gesperrt' (Denied {Use-UiCommandGrant $store $other $r $bytes})
 $r.Url=[uri]'http://127.0.0.1:18484/API/Commands';$id=Use-UiCommandGrant $store $session $r $bytes
 Check 'Case-insensitive Produktroute verbraucht denselben kanonischen Grant' ($id -ceq $a.receiptId -and $store.Receipts[$id].State -ceq 'CONSUMED' -and $null -eq $store.Receipts[$id].BodyMac)
 Check 'Doppelverbrauch ohne Jobwiederholung gesperrt' (Denied {Use-UiCommandGrant $store $session $r $bytes})
 Set-UiCommandGrantOutcome $store $id $null
 $safe=Get-UiCommandGrantReceipt $store $session (Request ('/api/command-grants/'+$id) 'GET') $id
 Check 'Unconfirmed enthält ausschließlich sichere Receiptkoordinaten' ($safe.state -ceq 'UNCONFIRMED' -and $null -eq $safe.jobId -and (($safe.PSObject.Properties.Name|Sort-Object)-join ',') -ceq 'jobId,receiptId,state')
 Check 'Unconfirmed stellt Grant niemals wieder her' (Denied {Use-UiCommandGrant $store $session $r $bytes})
 $safe=Get-UiCommandGrantReceipt $store $session (Request ('/api/command-grants/'+$b.receiptId+'/cancel')) $b.receiptId -Cancel
 $r=Request '/api/commands';$r.Headers.Add('X-SqlServerLab-Action-Grant',$b.grant)
 Check 'Widerruf vor Annahme sperrt den Grant' ($safe.state -ceq 'CANCELLED' -and (Denied {Use-UiCommandGrant $store $session $r $bytes}))
 $c=New-UiCommandGrant $store $session (Request) $bytes
 $raceJobs=@(1..2|ForEach-Object {Start-ThreadJob -ArgumentList $store,$session,$c.grant,$bytes,(Join-Path $repo 'Tools/WorkflowUiCommandGrants.ps1') -ScriptBlock {
  param($Store,$Session,$Token,$Bytes,$Helper);. $Helper
  $r=[pscustomobject]@{Url=[uri]($Session.ListenerUrl+'api/commands');HttpMethod='POST';Headers=[Collections.Specialized.NameValueCollection]::new()};$r.Headers.Add('X-SqlServerLab-Action-Grant',$Token)
  try{$null=Use-UiCommandGrant $Store $Session $r $Bytes;'CONSUMED'}catch{if($_.Exception.Message -ceq 'UI_COMMAND_GRANT_REQUIRED'){'DENIED'}else{throw}}
 }})
 try{$null=Wait-Job $raceJobs -Timeout 5;$race=@(Receive-Job $raceJobs -ErrorAction Stop);Check 'Zwei echte Threadconsumer ergeben genau einen Verbrauch' (@($race|Where-Object {$_ -ceq 'CONSUMED'}).Count -eq 1 -and @($race|Where-Object {$_ -ceq 'DENIED'}).Count -eq 1)}finally{$raceJobs|Remove-Job -Force}
 Set-UiCommandGrantOutcome $store $c.receiptId 'synthetic-job'
 $safe=Get-UiCommandGrantReceipt $store $session (Request ('/api/command-grants/'+$c.receiptId+'/cancel')) $c.receiptId -Cancel
 Check 'Abbruch nach Annahme verändert weder Job noch Receipt' ($safe.state -ceq 'ACCEPTED' -and $safe.jobId -ceq 'synthetic-job')
 1..3|ForEach-Object {$null=New-UiCommandGrant $store $session (Request) $bytes}
 Check 'Sessionquota verdrängt auch terminale Receipts niemals' (Denied {New-UiCommandGrant $store $session (Request) $bytes} 'UI_COMMAND_GRANT_CAPACITY')
 $oldKey=$store.Key
} finally {Close-UiCommandGrantStore $store}
Check 'Storecleanup leert Records und nullt alten HMAC-Keybuffer' (-not $store.Active -and $store.Receipts.Count -eq 0 -and $store.Tokens.Count -eq 0 -and $null -eq $store.Key -and @($oldKey|Where-Object {$_ -ne 0}).Count -eq 0)
$store=New-UiCommandGrantStore $session
try {
 $bomBody=[string][char]0xfeff+$json;$bomBytes=[Text.Encoding]::UTF8.GetBytes($bomBody)
 Check 'UTF8-BOM bleibt im Bytevertrag bei gültiger JSON-Fachform' ($null -ne (Get-UiCommandGrantRequest $bomBody $catalog))
 $g=New-UiCommandGrant $store $session (Request) $bomBytes;$r=Request '/api/commands';$r.Headers.Add('X-SqlServerLab-Action-Grant',$g.grant)
 Check 'BOMentfernung ist Drift; identische BOMbytes konsumieren' ((Denied {Use-UiCommandGrant $store $session $r $bytes}) -and (Use-UiCommandGrant $store $session $r $bomBytes) -ceq $g.receiptId)
} finally {Close-UiCommandGrantStore $store}
if(-not ('SqlLabCommandDelayedStream' -as [type])){Add-Type -TypeDefinition 'using System;using System.IO;using System.Threading;using System.Threading.Tasks;public sealed class SqlLabCommandDelayedStream:MemoryStream{public SqlLabCommandDelayedStream(byte[] bytes):base(bytes){} public override async Task<int> ReadAsync(byte[] b,int o,int c,CancellationToken t){await Task.Delay(100,t);return base.Read(b,o,c);}}'}
$store=New-UiCommandGrantStore $session -TtlMilliseconds 50
try {
 $g=New-UiCommandGrant $store $session (Request) $bytes;$r=Request '/api/commands';$r.Headers.Add('X-SqlServerLab-Action-Grant',$g.grant);$r|Add-Member InputStream ([SqlLabCommandDelayedStream]::new($bytes));$r|Add-Member ContentLength64 $bytes.Length
 try{$read=Read-UiJsonRequestBody $r -IncludeBytes;Check 'Rawbyte-Opt-in bewahrt tatsächlich gelesene UTF8bytes' ($read.Allowed -and [Convert]::ToHexString($read.BodyBytes) -ceq [Convert]::ToHexString($bytes));Check 'MonotonicExpiry während echter langsamer Bodylesung sperrt Consume' ((Denied {Use-UiCommandGrant $store $session $r $read.BodyBytes}) -and $store.Receipts[$g.receiptId].State -ceq 'EXPIRED')}
 finally {if($read.BodyBytes){[Array]::Clear($read.BodyBytes,0,$read.BodyBytes.Length)};$r.InputStream.Dispose()}
 Check 'Abgelaufener Slot bleibt belegt' ($store.Receipts.Count -eq 1)
} finally {Close-UiCommandGrantStore $store}
$legacy=[pscustomobject]@{InputStream=[IO.MemoryStream]::new($bytes);ContentLength64=$bytes.Length}
try{$read=Read-UiJsonRequestBody $legacy;Check 'Bestehendes ReaderDTO besitzt ohne Opt-in keine Rawbytes' ($read.PSObject.Properties.Name -notcontains 'BodyBytes')}finally{$legacy.InputStream.Dispose()}

# Echte HTTP-Abnahme am vollständigen Produktrequestblock, nur Fachleaves synthetisch.
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'Tools/Start-SqlServerLabUi.ps1'),[ref]$null,[ref]$null)
$loop=$ast.Find({param($n)$n -is [Management.Automation.Language.WhileStatementAst] -and $n.Condition.Extent.Text -ceq '$listener.IsListening'},$true)
$dispatch='foreach($iteration in 1)'+$loop.Body.Statements[1].Body.Extent.Text
$reply=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Write-UiResponse'},$true).Extent.Text
$probe=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0);$probe.Start();$port=$probe.LocalEndpoint.Port;$probe.Stop();$url="http://127.0.0.1:$port/"
$listener=[Net.HttpListener]::new();$listener.Prefixes.Add($url);$job=$null;$client=$null
try {
 $listener.Start()
 $job=Start-ThreadJob -ArgumentList $listener,$url,$dispatch,$reply,(Join-Path $repo 'Tools') -ScriptBlock {
  param($Listener,$url,$Dispatch,$Reply,$ToolsRoot);$ErrorActionPreference='Stop';$jobs=@{};$script:attempts=0;$script:consumed=$true
  . (Join-Path $ToolsRoot 'WorkflowUiRequestBoundary.ps1');. (Join-Path $ToolsRoot 'WorkflowUiOperator.ps1');. (Join-Path $ToolsRoot 'WorkflowUiJsonBody.ps1');. (Join-Path $ToolsRoot '../Tests/Static/Fixtures/WorkflowUiCommandGrantFixture.ps1');. ([scriptblock]::Create($Reply))
  # Beobachte ausschließlich Bytebuffer-Lebensdauer; Reader bleibt tatsächlich.
  $reader=(Get-Command Read-UiJsonRequestBody).ScriptBlock.Ast.Extent.Text.Replace('function Read-UiJsonRequestBody','function Read-FixtureActualJsonBody')
  . ([scriptblock]::Create($reader));$script:rawBuffers=[Collections.Generic.List[object]]::new()
  function Read-UiJsonRequestBody {param($Request,[int]$MaxBytes=1048576,[int]$TimeoutMilliseconds=5000,[switch]$IncludeBytes)
   $read=Read-FixtureActualJsonBody -Request $Request -MaxBytes $MaxBytes -TimeoutMilliseconds $TimeoutMilliseconds -IncludeBytes:$IncludeBytes
   if($read.PSObject.Properties.Name -contains 'BodyBytes' -and $read.BodyBytes){$script:rawBuffers.Add($read.BodyBytes)}
   return $read
  }
  $operatorSession=[pscustomobject]@{Active=$true;Capability=('a'*64);ListenerUrl=$url};$commandGrantStore=New-UiCommandGrantStore $operatorSession -Quota 4
  function Start-UiPublicCommandJob {param($CommandName,$ParameterSetName,$Parameters,[switch]$Confirmed)
   $script:attempts++;$script:consumed=$script:consumed -and @($commandGrantStore.Receipts.Values|Where-Object State -CEQ 'CONSUMED').Count -eq 1
   if($Parameters.Fail){throw 'LOCAL_SYNTHETIC_ONLY_MUST_NOT_REFLECT'}
   [pscustomobject]@{Id=('synthetic-'+$script:attempts);Action='synthetic'}
  }
  try {for($n=0;$n -lt 23;$n++){$pending=$Listener.GetContextAsync();if(-not $pending.Wait(10000)){throw 'COMMAND_HTTP_CONTEXT_TIMEOUT'};$context=$pending.GetAwaiter().GetResult();. ([scriptblock]::Create($Dispatch))}
   $cleared=$script:rawBuffers.Count -gt 0 -and @($script:rawBuffers|Where-Object {@($_|Where-Object {$_ -ne 0}).Count -gt 0}).Count -eq 0
   [pscustomobject]@{Attempts=$script:attempts;ConsumedBeforeJob=$script:consumed;Slots=$commandGrantStore.Receipts.Count;RawBuffersCleared=$cleared;ProductModule='NOT_IMPORTED';Provider='NOT_EXECUTED';State='NOT_EXECUTED';Sql='NOT_EXECUTED'}
  } finally {Close-UiCommandGrantStore $commandGrantStore}
 }
 $client=[Net.Http.HttpClient]::new();$client.Timeout=[timespan]::FromSeconds(5)
 function Send([string]$Path,[int]$Expected,[string]$Body=$json,[string]$Token,[string]$Method='POST',[bool]$Operator=$true){
  $r=[Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::new($Method),$url+$Path)
  try{
   if($Operator){$null=$r.Headers.TryAddWithoutValidation('X-SqlServerLab-Operator',('a'*64))};if($Token){$null=$r.Headers.TryAddWithoutValidation('X-SqlServerLab-Action-Grant',$Token)}
   if($Method -ceq 'POST'){$r.Content=[Net.Http.StringContent]::new($Body,[Text.Encoding]::UTF8,'application/json')}
   $response=$client.SendAsync($r).GetAwaiter().GetResult()
   try{$text=$response.Content.ReadAsStringAsync().GetAwaiter().GetResult();Check ('HTTP '+$Path+' '+$Expected) ([int]$response.StatusCode -eq $Expected -and $text -notmatch 'LOCAL_SYNTHETIC_ONLY|BodyMac|BodyLength|commandName|OperatorCapability');if($text.StartsWith('{')){return $text|ConvertFrom-Json};return $null}finally{$response.Dispose()}
  } finally {$r.Dispose()}
 }
 $a=Send 'api/command-grants' 201
 $accepted=Send 'API/Commands' 202 $json $a.grant
 $null=Send 'api/commands' 403 $json $a.grant
 $safe=Send ('api/command-grants/'+$a.receiptId) 200 -Method GET
 Check 'HTTP Status zeigt nur Receipt/State/Job nach Annahme' ($safe.state -ceq 'ACCEPTED' -and $safe.jobId -ceq $accepted.id -and $null -eq $safe.grant)
 $null=Send 'api/command-grants' 400 ($json.Replace('"confirmed":true','"confirmed":"false"'))
 $null=Send 'api/command-grants' 400 ($json.Replace('"commandName":"synthetic"','"commandName":"unknown"'))
 $null=Send 'api/command-grants' 400 ($json.Replace('"parameterSetName":"synthetic"','"parameterSetName":"unknown"'))
 $b=Send 'api/command-grants' 201
 $null=Send 'api/commands' 403 ($json+' ') $b.grant
 $null=Send 'api/commands' 202 $json $b.grant
 $faultBody=$json.Replace('"Target":"same"','"Target":"same","Fail":true')
 $f=Send 'api/command-grants' 201 $faultBody
 $null=Send 'api/commands' 500 $faultBody $f.grant
 $null=Send 'api/commands' 403 $faultBody $f.grant
 $safe=Send ('api/command-grants/'+$f.receiptId) 200 -Method GET
 Check 'HTTP Jobfehler bleibt UNCONFIRMED ohne Grantrestore' ($safe.state -ceq 'UNCONFIRMED' -and $null -eq $safe.jobId)
 $c=Send 'api/command-grants' 201
 $null=Send ('api/command-grants/'+$c.receiptId+'/cancel') 200 '{}'
 $null=Send 'api/commands' 403 $json $c.grant
 $null=Send ('api/command-grants/'+$c.receiptId) 200 -Method GET
 $null=Send 'api/command-grants' 403 -Operator $false
 $null=Send 'api/commands' 403
 $null=Send 'api/command-grants' 429
 $null=Send ('api/command-grants/'+('0'*32)) 403 -Method GET
 $null=Send 'api/command-grants' 400 '{malformed LOCAL_SYNTHETIC_ONLY'
 $null=Wait-Job $job -Timeout 5;if($job.State -ne 'Completed'){throw 'COMMAND_HTTP_JOB_NOT_COMPLETED'};$observed=Receive-Job $job -ErrorAction Stop
 Check 'Nur drei synthetische Jobversuche nach Consume; keine Grantissue-Ausführung' ($observed.Attempts -eq 3 -and $observed.ConsumedBeforeJob -and $observed.Slots -eq 4 -and $observed.ProductModule -ceq 'NOT_IMPORTED' -and $observed.Provider -ceq 'NOT_EXECUTED')
 Check 'Tatsächliche Rawbytebuffer nach Erfolg, Veto und Jobfault genullt' $observed.RawBuffersCleared
} finally {if($client){$client.Dispose()};$listener.Stop();$listener.Close();if($job){if($job.State -notin @('Completed','Stopped','Failed')){Stop-Job $job};Remove-Job $job -Force}}
Check 'Eigener HTTP-Listener und alle Threadjobs geschlossen' (-not $listener.IsListening -and @(Get-Job|Where-Object Id -EQ $job.Id).Count -eq 0)
Write-Host "Ergebnis: $script:passed PASS, 0 FAIL; 23 echte HTTP-Requests"
