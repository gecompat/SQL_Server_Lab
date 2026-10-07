#Requires -Version 7.2
$ErrorActionPreference='Stop'
$repo=(Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
$script:passed=0
function Check([string]$Name,[bool]$Success){if(-not $Success){throw ('FAIL: '+$Name)};$script:passed++;Write-Host ('PASS: '+$Name)}
. (Join-Path $repo 'Tools/WorkflowUiJsonBody.ps1')
$errors=$null;$tokens=$null
$server=Join-Path $repo 'Tools/Start-SqlServerLabUi.ps1'
$ast=[Management.Automation.Language.Parser]::ParseFile($server,[ref]$tokens,[ref]$errors)
Check 'Server ist syntaktisch gueltig' ($errors.Count -eq 0)
$names=@('CmsInspection','InitialSetup','SlotReserve','ResourceWatch','LlamaInstaller','LlamaSession','Maintenance','MediaOverride')
$adapters=@(foreach($name in $names){$fn=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq ('Invoke-Ui'+$name+'Request')},$true);Check ('Kein synchroner Reader im Adapter '+$name) ($null -ne $fn -and $fn.Extent.Text -notmatch 'ReadBlock|StreamReader');$fn.Extent.Text})
$paths=@('/api/cms-inspection','/api/initial-setup','/api/slot-reserve','/api/resource-watch','/api/llama-installer','/api/llama-sessions','/api/maintenance','/api/media-overrides')
$limits=@(4096,16384,16384,1024,1024,1024,1024,16384)
foreach($limit in @(1024,4096,16384)){
 $bytes=[Text.Encoding]::UTF8.GetBytes((' '+([string][char]0x20ac)*($limit-1)))
 $stream=[IO.MemoryStream]::new($bytes)
 $read=Read-UiSpecializedJsonRequestBody -Request ([pscustomobject]@{InputStream=$stream}) -MaxCharacters $limit -LimitErrorCode 'SYNTHETIC_CHARACTER_LIMIT'
 Check ('Mehrbyteiger Text bis exaktem Zeichenlimit '+$limit) ($read.Length -eq $limit -and -not $stream.CanRead)
 $stream=[IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes(([string][char]0xfeff)+(' '*$limit)))
 $read=Read-UiSpecializedJsonRequestBody -Request ([pscustomobject]@{InputStream=$stream}) -MaxCharacters $limit -LimitErrorCode 'SYNTHETIC_CHARACTER_LIMIT'
 Check ('Fuehrende UTF-8-BOM wie bisher vor Zeichenlimit entfernt '+$limit) ($read.Length -eq $limit -and $read[0] -eq ' ' -and -not $stream.CanRead)
 $stream=[IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes((' '*($limit+1))))
 $caught=try{$null=Read-UiSpecializedJsonRequestBody -Request ([pscustomobject]@{InputStream=$stream}) -MaxCharacters $limit -LimitErrorCode 'SYNTHETIC_CHARACTER_LIMIT';$false}catch{$_.Exception.Message -ceq 'SYNTHETIC_CHARACTER_LIMIT'}
 Check ('Altes Zeichenlimit und erfolgreicher Streamcleanup '+$limit) ($caught -and -not $stream.CanRead)
}
$loops=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.WhileStatementAst] -and $n.Condition.Extent.Text -ceq '$listener.IsListening'},$true))
Check 'Gemeinsamer Requestblock eindeutig' ($loops.Count -eq 1)
$dispatch='foreach($iteration in 1)'+$loops[0].Body.Statements[1].Body.Extent.Text
$reply=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Write-UiResponse'},$true).Extent.Text
$valid=@(('{"action":"InspectCms","parameters":{"ExpectedPlanKey":"'+('c'*64)+'"}}'),'{"action":"PlanInitialSetup","parameters":{}}','{"action":"PlanSlotReserve","parameters":{}}','{"action":"RefreshResourceWatch","parameters":{}}','{"action":"upstream"}','{"action":"preview","operationId":"11111111-1111-1111-1111-111111111111"}',('{"action":"preview","candidateId":"'+('c'*64)+'"}'),'{"action":"PlanMediaOverride","parameters":{}}')
$cases=@(for($i=0;$i -lt $paths.Count;$i++){
 [pscustomobject]@{Path=$paths[$i];Mode='header';Length=$limits[$i]*4+1;Payload='';Expected=413}
 [pscustomobject]@{Path=$paths[$i];Mode='chunked';Length=0;Payload=(' '*($limits[$i]*4+1));Expected=413}
 [pscustomobject]@{Path=$paths[$i];Mode='characters';Length=0;Payload=($valid[$i]+(' '*($limits[$i]+1-$valid[$i].Length)));Expected=400}
 [pscustomobject]@{Path=$paths[$i];Mode='valid';Length=0;Payload=$valid[$i];Expected=200}
})+@([pscustomobject]@{Path='/api/resource-watch';Mode='trickle';Length=1000;Payload='{';Expected=408},[pscustomobject]@{Path='/api/resource-watch';Mode='utf8';Length=2;Payload='';Expected=400},[pscustomobject]@{Path='/api/resource-watch';Mode='valid';Length=0;Payload=$valid[3];Expected=200},[pscustomobject]@{Path='/api/resource-watch';Mode='bom';Length=0;Payload=(([string][char]0xfeff)+$valid[3]);Expected=200})
$probe=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0);$probe.Start();$port=$probe.LocalEndpoint.Port;$probe.Stop()
$url="http://127.0.0.1:$port/";$listener=[Net.HttpListener]::new();$listener.Prefixes.Add($url);$job=$null;$results=[Collections.Generic.List[object]]::new()
try {
 $listener.Start()
 $job=Start-ThreadJob -ArgumentList $listener,$url,$dispatch,$reply,($adapters -join "`n"),(Join-Path $repo 'Tools'),$cases.Count -ScriptBlock {
  param($Listener,$url,$Dispatch,$Reply,$Adapters,$ToolsRoot,$Count)
  $ErrorActionPreference='Stop';$script:effects=0
  . (Join-Path $ToolsRoot 'WorkflowUiRequestBoundary.ps1');. (Join-Path $ToolsRoot 'WorkflowUiJsonBody.ps1')
  . (Join-Path $ToolsRoot 'WorkflowUiOperator.ps1')
  $operatorSession=[pscustomobject]@{ListenerUrl=$url;Capability=('a'*64);Active=$true}
  . ([scriptblock]::Create($Adapters));. ([scriptblock]::Create($Reply))
  function Invoke-SqlServerLabWorkflowAction {param($Action,$ExpectedPlanKey,$LlamaSessionOperationId)$script:effects++;[pscustomobject]@{Result=[pscustomobject]@{Synthetic=$true};Synthetic=$true}}
  $synthetic=New-Module -Name SqlServerLab -ScriptBlock {
   function Get-LabLlamaInstallerUpstream {[pscustomobject]@{Synthetic=$true}}
   function Get-LabMaintenanceRepairPlan {param($CandidateId)[pscustomobject]@{Synthetic=$true}}
   function ConvertTo-LabMaintenanceRepairView {param($Plan)$Plan}
  }
  # Kein Produktmodul importieren: nur diese explizite RAM-Fixture liefern.
  function Get-Module {param($Name)$synthetic}
  for($i=0;$i -lt $Count;$i++){$pending=$Listener.GetContextAsync();if(-not $pending.Wait(10000)){throw 'SPECIALIZED_OWN_CONTEXT_TIMEOUT'};$context=$pending.GetAwaiter().GetResult();. ([scriptblock]::Create($Dispatch))}
  [pscustomobject]@{Effects=$script:effects;ProductModule='NOT_IMPORTED';Provider='NOT_EXECUTED';State='NOT_EXECUTED';Sql='NOT_EXECUTED'}
 }
 foreach($case in $cases){
  $client=[Net.Sockets.TcpClient]::new();$stream=$null;$clock=[Diagnostics.Stopwatch]::StartNew()
  try {
   $client.Connect('127.0.0.1',$port);$stream=$client.GetStream();$payload=[Text.Encoding]::UTF8.GetBytes($case.Payload)
   $headers="POST $($case.Path) HTTP/1.1`r`nHost: 127.0.0.1:$port`r`nX-SqlServerLab-Operator: $('a'*64)`r`nContent-Type: application/json`r`nConnection: close`r`n"
   if($case.Mode -ceq 'utf8'){$payload=[byte[]](0xc3,0x28)}
   if($case.Mode -ceq 'chunked'){$headers+="Transfer-Encoding: chunked`r`n`r`n";$payload=[Text.Encoding]::ASCII.GetBytes($payload.Length.ToString('x')+"`r`n"+$case.Payload+"`r`n0`r`n`r`n")}
   else {$length=if($case.Length){$case.Length}else{$payload.Length};$headers+="Content-Length: $length`r`n`r`n"}
   $bytes=[Text.Encoding]::ASCII.GetBytes($headers);$stream.Write($bytes,0,$bytes.Length);if($payload.Length){$stream.Write($payload,0,$payload.Length)}
   if($case.Mode -ceq 'trickle'){for($n=0;$n -lt 3;$n++){Start-Sleep -Milliseconds 400;$stream.WriteByte(32)}}
   $buffer=[byte[]]::new(4096);$status=0
   for($attempt=0;$attempt -lt 2;$attempt++){$pending=$stream.ReadAsync($buffer,0,$buffer.Length);if(-not $pending.Wait(7000)){throw 'SPECIALIZED_OWN_RESPONSE_TIMEOUT'};$length=$pending.GetAwaiter().GetResult();$text=[Text.Encoding]::UTF8.GetString($buffer,0,$length);$status=if($text -match 'HTTP/1\.[01] ([0-9]{3})'){[int]$Matches[1]}else{0};if($status -ne 100){break}}
   $results.Add([pscustomobject]@{Path=$case.Path;Mode=$case.Mode;Expected=$case.Expected;Actual=$status;ElapsedMs=$clock.ElapsedMilliseconds})
  } finally {if($stream){$stream.Dispose()};$client.Dispose();$clock.Stop()}
 }
 $null=Wait-Job $job -Timeout 3;if($job.State -cne 'Completed'){throw 'SPECIALIZED_BODY_JOB_INCOMPLETE'};$observed=Receive-Job $job -ErrorAction Stop
 foreach($row in $results){Check ('Echte Produktroute '+$row.Path+' '+$row.Mode) ($row.Actual -eq $row.Expected)}
 Check 'Nur acht gueltige Requests erreichen den synthetischen Workflow-Sink' ($observed.Effects -eq 8 -and $observed.ProductModule -ceq 'NOT_IMPORTED')
 Check 'Trickle besitzt absolute Frist trotz weiteren Bytes' (@($results|Where-Object Mode -EQ trickle)[0].ElapsedMs -ge 4500 -and @($results|Where-Object Mode -EQ trickle)[0].ElapsedMs -lt 7000)
} finally {
 $listener.Stop();$listener.Close();if($job){if($job.State -notin @('Completed','Stopped','Failed')){Stop-Job $job};Remove-Job $job -Force}
}
Check 'Eigener Listener und Threadjob geschlossen' (-not $listener.IsListening -and @(Get-Job|Where-Object Id -EQ $job.Id).Count -eq 0)
Write-Host "Ergebnis: $script:passed PASS, 0 FAIL"
