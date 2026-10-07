#Requires -Version 7.2
$ErrorActionPreference='Stop'
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
. (Join-Path $repo 'Tools/WorkflowUiJsonBody.ps1')
$script:passed=0
function Check([string]$Name,[bool]$Value){if(-not $Value){throw ('UI_BODY_CHECK_FAILED: '+$Name)};$script:passed++;Write-Host "PASS $Name"}
Add-Type -TypeDefinition @'
using System; using System.IO; using System.Threading; using System.Threading.Tasks;
public sealed class UiBodyFixtureStream : Stream {
 public long ReadBytes; public bool Closed; public int Delay; public long LengthToGenerate;
 private readonly CancellationTokenSource stop = new CancellationTokenSource();
 public UiBodyFixtureStream(long length, int delay=0){LengthToGenerate=length;Delay=delay;}
 public override bool CanRead=>!Closed; public override bool CanSeek=>false; public override bool CanWrite=>false;
 public override long Length=>throw new NotSupportedException(); public override long Position {get=>ReadBytes;set=>throw new NotSupportedException();}
 public override int Read(byte[] b,int o,int c){int n=(int)Math.Min(c,LengthToGenerate-ReadBytes);Array.Fill(b,(byte)32,o,n);ReadBytes+=n;return n;}
 public override async Task<int> ReadAsync(byte[] b,int o,int c,CancellationToken ct){if(Delay>0)await Task.Delay(Delay,stop.Token);return Read(b,o,Delay>0?Math.Min(1,c):c);}
 protected override void Dispose(bool d){Closed=true;stop.Cancel();base.Dispose(d);}
 public override void Flush(){} public override long Seek(long o,SeekOrigin s)=>throw new NotSupportedException();
 public override void SetLength(long v)=>throw new NotSupportedException(); public override void Write(byte[] b,int o,int c)=>throw new NotSupportedException();
}
'@
function Read-Bytes([byte[]]$Bytes,[long]$Declared=-1){$stream=[IO.MemoryStream]::new($Bytes,$false);try{Read-UiJsonRequestBody -Request ([pscustomobject]@{InputStream=$stream;ContentLength64=$Declared}) -MaxBytes 32}finally{$stream.Dispose()}}
foreach($length in @(0,1,31,32)){$result=Read-Bytes ([Text.Encoding]::UTF8.GetBytes((' '*$length)));Check ('EOF bis exaktes Bytelimit '+$length) ($result.Allowed -and $result.Body.Length -eq $length)}
$result=Read-Bytes ([Text.Encoding]::UTF8.GetBytes((' '*33)));Check 'Ein Byte ueber unbekannter Laenge wird gesperrt' (-not $result.Allowed -and $result.StatusCode -eq 413 -and $null -eq $result.Body)
$result=Read-Bytes ([Text.Encoding]::UTF8.GetBytes(([string][char]0x20ac)*11));Check 'Bytelimit gilt vor mehrbyteiger Decodierung' (-not $result.Allowed -and $result.StatusCode -eq 413)
$result=Read-Bytes ([byte[]](0xc3,0x28));Check 'Ungueltiges UTF8 bleibt fest und bodyfrei' (-not $result.Allowed -and $result.Code -ceq 'UI_REQUEST_BODY_UTF8_INVALID' -and $null -eq $result.Body)
$stream=[UiBodyFixtureStream]::new(1000000);$result=Read-UiJsonRequestBody -Request ([pscustomobject]@{InputStream=$stream;ContentLength64=[long]33}) -MaxBytes 32
Check 'Deklarierte Ueberlaenge liest null Bytes' ($result.StatusCode -eq 413 -and $stream.ReadBytes -eq 0 -and $stream.Closed)
$stream=[UiBodyFixtureStream]::new(1000000);$result=Read-UiJsonRequestBody -Request ([pscustomobject]@{InputStream=$stream;ContentLength64=[long]-1}) -MaxBytes 32
Check 'Unbekannte Laenge liest nur Limit plus Sentinel' ($result.StatusCode -eq 413 -and $stream.ReadBytes -eq 33 -and $stream.Closed)
$stream=[UiBodyFixtureStream]::new(1000000,80);$clock=[Diagnostics.Stopwatch]::StartNew();$result=Read-UiJsonRequestBody -Request ([pscustomobject]@{InputStream=$stream;ContentLength64=[long]-1}) -MaxBytes 32 -TimeoutMilliseconds 250;$clock.Stop()
Check 'Trickle verwendet eine absolute Frist und schliesst Stream' ($result.StatusCode -eq 408 -and $stream.Closed -and $clock.ElapsedMilliseconds -lt 1500 -and $stream.ReadBytes -lt 5)
$stream=[IO.MemoryStream]::new();$stream.Dispose();$result=Read-UiJsonRequestBody -Request ([pscustomobject]@{InputStream=$stream})
Check 'Geschlossener Stream ergibt festes Veto' (-not $result.Allowed -and $null -eq $result.Body)

$server=Join-Path $repo 'Tools/Start-SqlServerLabUi.ps1';$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($server,[ref]$tokens,[ref]$errors)
$include=@($ast.EndBlock.Statements|Where-Object Extent |Where-Object {$_.Extent.Text -ceq ". (Join-Path `$PSScriptRoot 'WorkflowUiJsonBody.ps1')"})
$boundary=@($ast.EndBlock.Statements|Where-Object {$_.Extent.Text -ceq ". (Join-Path `$PSScriptRoot 'WorkflowUiRequestBoundary.ps1')"})
$loops=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.WhileStatementAst] -and $n.Condition.Extent.Text -ceq '$listener.IsListening'},$true))
Check 'Beide Includes stehen vor dem eindeutigen Listenerloop' ($errors.Count -eq 0 -and $include.Count -eq 1 -and $boundary.Count -eq 1 -and $loops.Count -eq 1 -and $include[0].Extent.EndOffset -lt $loops[0].Extent.StartOffset -and $boundary[0].Extent.EndOffset -lt $loops[0].Extent.StartOffset)
$dispatchTry=$loops[0].Body.Statements[1];$body=$dispatchTry.Body
$expected=@('/api/ai-shared-gateway/service-secret','/api/batches','/api/operations','/api/persistent-storage/retained-removal-plan','/api/persistent-storage/removal-plan','/api/actions','/api/commands')
$routes=@($body.Statements|Where-Object {$_ -is [Management.Automation.Language.IfStatementAst] -and $_.Clauses[0].Item1.Extent.Text.StartsWith('$path -eq ') -and $_.Clauses[0].Item2.Statements[0].Extent.Text -ceq '$bodyRead = Read-UiJsonRequestBody -Request $context.Request'})
Check 'Sieben direkte POST-Routen verwenden gemeinsamen Reader' ($routes.Count -eq 7 -and [IO.File]::ReadAllText($server) -notmatch '\.ReadToEnd\(')
foreach($path in $expected){$route=@($routes|Where-Object {$_.Clauses[0].Item1.Extent.Text -ceq "`$path -eq '$path' -and `$context.Request.HttpMethod -eq 'POST'"});Check ('Reader und Veto vor JSON/Fachaufruf '+$path) ($route.Count -eq 1 -and $route[0].Clauses[0].Item2.Statements[1].Clauses[0].Item1.Extent.Text -ceq '-not $bodyRead.Allowed' -and $route[0].Clauses[0].Item2.Statements[2].Extent.Text -ceq '$body = $bodyRead.Body')}
$reply=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Write-UiResponse'},$true))[0].Extent.Text
$dispatch='foreach($iteration in 1)'+$body.Extent.Text
$cases=@(foreach($path in $expected){[pscustomobject]@{Path=$path;Mode='header';Expected=413}})+@(
 [pscustomobject]@{Path='/api/commands';Mode='chunked';Expected=413}
 [pscustomobject]@{Path='/api/actions';Mode='utf8';Expected=400}
 [pscustomobject]@{Path='/api/batches';Mode='trickle';Expected=408}
 [pscustomobject]@{Path='/api/commands';Mode='command';Expected=202}
 [pscustomobject]@{Path='/api/actions';Mode='action';Expected=202}
 [pscustomobject]@{Path='/api/batches';Mode='batch';Expected=201}
)
$probe=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0);$probe.Start();$port=$probe.LocalEndpoint.Port;$probe.Stop()
$url="http://127.0.0.1:$port/";$listener=[Net.HttpListener]::new();$listener.Prefixes.Add($url);$job=$null;$results=[Collections.Generic.List[object]]::new()
try{
 $listener.Start()
 $job=Start-ThreadJob -ArgumentList $listener,$url,$dispatch,$reply,($boundary[0].Extent.Text+"`n"+$include[0].Extent.Text),(Join-Path $repo 'Tools'),$cases.Count -ScriptBlock {
  param($Listener,$url,$Dispatch,$Reply,$Includes,$ToolsRoot,$Count)
  $ErrorActionPreference='Stop';$jobs=@{};$persistentJobs=@{};$script:effects=0
  . ([scriptblock]::Create('param([string]$PSScriptRoot)'+"`n"+$Includes)) $ToolsRoot
  . (Join-Path $ToolsRoot 'WorkflowUiOperator.ps1')
  $operatorSession=[pscustomobject]@{ListenerUrl=$url;Capability=('a'*64);Active=$true}
  . ([scriptblock]::Create($Reply))
  function Start-UiPublicCommandJob {param($CommandName,$ParameterSetName,$Parameters,[switch]$Confirmed)$script:effects++;[pscustomobject]@{Id='synthetic-command';Action='synthetic'}}
  function Start-UiWorkflowJob {param($Action,$Parameters)$script:effects++;[pscustomobject]@{Id='synthetic-action';Action='synthetic'}}
  function New-SqlServerLabBatch {param($Name,$Priority,$Defaults,$Items,[switch]$Queue)$script:effects++;[pscustomobject]@{batchId='synthetic-batch'}}
  for($i=0;$i -lt $Count;$i++){$pending=$Listener.GetContextAsync();if(-not $pending.Wait(10000)){throw 'OWN_CONTEXT_TIMEOUT'};$context=$pending.GetAwaiter().GetResult();. ([scriptblock]::Create($Dispatch))}
  [pscustomobject]@{SyntheticEffects=$script:effects;ProductModule='NOT_IMPORTED';Provider='NOT_EXECUTED';State='NOT_EXECUTED';Sql='NOT_EXECUTED'}
 }
 foreach($case in $cases){
  $client=[Net.Sockets.TcpClient]::new();$stream=$null
  try{
   $client.Connect('127.0.0.1',$port);$stream=$client.GetStream();$payload=[byte[]]::new(0);$headers="POST $($case.Path) HTTP/1.1`r`nHost: 127.0.0.1:$port`r`nX-SqlServerLab-Operator: $('a'*64)`r`nContent-Type: application/json`r`nConnection: close`r`n"
   switch($case.Mode){
    'header' {$headers+="Content-Length: 1048577`r`n`r`n"}
    'chunked' {$headers+="Transfer-Encoding: chunked`r`n`r`n";$payload=[Text.Encoding]::ASCII.GetBytes("100001`r`n"+(' '*1048577)+"`r`n0`r`n`r`n")}
    'utf8' {$headers+="Content-Length: 2`r`n`r`n";$payload=[byte[]](0xc3,0x28)}
    'trickle' {$headers+="Content-Length: 100`r`n`r`n";$payload=[byte[]](32)}
    default {$json=switch($case.Mode){'command' {'{"commandName":"synthetic","parameterSetName":"synthetic","parameters":{},"confirmed":true}'}'action' {'{"action":"Refresh","parameters":{}}'}'batch' {'{"name":"synthetic","items":[]}'}};$payload=[Text.Encoding]::UTF8.GetBytes($json);$headers+="Content-Length: $($payload.Length)`r`n`r`n"}
   }
   $headerBytes=[Text.Encoding]::ASCII.GetBytes($headers);$stream.Write($headerBytes,0,$headerBytes.Length)
   if($payload.Length){$stream.Write($payload,0,$payload.Length)}
   if($case.Mode -ceq 'trickle'){for($n=0;$n -lt 3;$n++){Start-Sleep -Milliseconds 400;$stream.WriteByte(32)}}
   $clock=[Diagnostics.Stopwatch]::StartNew();$response=[byte[]]::new(4096);$read=$stream.ReadAsync($response,0,$response.Length);if(-not $read.Wait(7000)){throw 'OWN_RESPONSE_TIMEOUT'};$size=$read.GetAwaiter().GetResult();$text=[Text.Encoding]::UTF8.GetString($response,0,$size);$clock.Stop()
   $status=if($text -match '\AHTTP/1\.[01] ([0-9]{3})'){[int]$Matches[1]}else{0}
   # HttpListener kann dem Chunkupload eine vorlaeufige 100-Antwort senden.
   if($status -eq 100){$read=$stream.ReadAsync($response,0,$response.Length);if(-not $read.Wait(7000)){throw 'OWN_FINAL_RESPONSE_TIMEOUT'};$size=$read.GetAwaiter().GetResult();$text=[Text.Encoding]::UTF8.GetString($response,0,$size);$status=if($text -match 'HTTP/1\.[01] ([0-9]{3})'){[int]$Matches[1]}else{0}}
   $results.Add([pscustomobject]@{Path=$case.Path;Mode=$case.Mode;Expected=$case.Expected;Actual=$status;ResponseWaitMs=$clock.ElapsedMilliseconds})
  }finally{if($stream){$stream.Dispose()};$client.Dispose()}
 }
 $null=Wait-Job $job -Timeout 5;if($job.State -ne 'Completed'){throw 'BODY_HTTP_JOB_NOT_COMPLETED'};$observed=Receive-Job $job -ErrorAction Stop
 foreach($row in $results){Check ('Echter HTTP-Body '+$row.Path+' '+$row.Mode) ($row.Actual -eq $row.Expected)}
 Check 'Nur drei erlaubte Requests erreichen synthetische Effekte' ($observed.SyntheticEffects -eq 3 -and $observed.ProductModule -ceq 'NOT_IMPORTED' -and $observed.State -ceq 'NOT_EXECUTED')
}finally{
 $listener.Stop();$listener.Close();if($job){if($job.State -notin @('Completed','Stopped','Failed')){Stop-Job $job};Remove-Job $job -Force}
}
Check 'Eigener Listener geschlossen und Job entfernt' (-not $listener.IsListening -and @(Get-Job|Where-Object Id -EQ $job.Id).Count -eq 0)
Write-Host "Ergebnis: $script:passed PASS, 0 FAIL"
