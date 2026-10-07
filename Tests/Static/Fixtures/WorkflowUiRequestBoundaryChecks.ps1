#Requires -Version 7.2
$ErrorActionPreference='Stop'
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
. (Join-Path $repo 'Tools/WorkflowUiRequestBoundary.ps1')
$script:passed=0
function Check([string]$Name,[bool]$Success){if(-not $Success){throw "UI_BOUNDARY_CHECK_FAILED: $Name"};$script:passed++;Write-Host "PASS $Name"}
function New-Request([string]$Method='POST',[string]$ContentType='application/json'){
 $headers=[Collections.Specialized.NameValueCollection]::new();$headers.Add('Host','127.0.0.1:18484');if($ContentType){$headers.Add('Content-Type',$ContentType)}
 $stream=[IO.MemoryStream]::new();$stream.Dispose() # Jede Bodylesung waere ein Fehler.
 [pscustomobject]@{Url=[uri]'http://127.0.0.1:18484/api/commands';RemoteEndPoint=[Net.IPEndPoint]::new([Net.IPAddress]::Loopback,12345);Headers=$headers;HttpMethod=$Method;InputStream=$stream}
}
$base='http://127.0.0.1:18484/'
Check 'Lokales JSON ohne Origin ist keine Operatorauthentifizierung' (Get-UiRequestBoundaryDecision (New-Request) $base).Allowed
$request=New-Request;$request.Headers.Add('Origin',$base.TrimEnd('/'));$request.Headers.Add('Sec-Fetch-Site','same-origin')
Check 'Exakte Browser-Origin bleibt zugelassen' (Get-UiRequestBoundaryDecision $request $base).Allowed
Check 'GET benoetigt keinen JSON-Body' (Get-UiRequestBoundaryDecision (New-Request GET '') $base).Allowed
foreach($value in @('application/json; charset=utf-8','application/json; charset="utf-8"','APPLICATION/JSON; CHARSET=UTF-8')){Check ('UTF8-JSON '+$value) (Get-UiRequestBoundaryDecision (New-Request POST $value) $base).Allowed}
foreach($value in @('text/plain','application/x-www-form-urlencoded','multipart/form-data','application/json; charset=utf-16','application/json; charset=utf-8; charset=utf-8','application/json, text/plain','')){
 $decision=Get-UiRequestBoundaryDecision (New-Request POST $value) $base;Check ('POST-Medientyp blockiert ohne Bodylesung '+$value) (-not $decision.Allowed -and $decision.StatusCode -eq 415)
}
foreach($value in @('https://synthetic.invalid','null','http://127.0.0.1:18485','http://localhost:18484','https://127.0.0.1:18484','http://127.0.0.1:18484/','http://127.0.0.1:18484#x')){
 $request=New-Request;$request.Headers.Add('Origin',$value);$decision=Get-UiRequestBoundaryDecision $request $base;Check ('Origin blockiert ohne Bodylesung '+$value) (-not $decision.Allowed -and $decision.StatusCode -eq 403)
}
foreach($field in @('Host','Origin','Content-Type','Sec-Fetch-Site')){$request=New-Request;$request.Headers.Add($field,'synthetic-duplicate');$request.Headers.Add($field,'synthetic-duplicate');Check ('Mehrdeutiger Header '+$field) (-not (Get-UiRequestBoundaryDecision $request $base).Allowed)}
$request=New-Request;$request.Url=[uri]'http://localhost:18484/api/commands';Check 'Request-Authority ist an IPv4-Listener gebunden' (-not (Get-UiRequestBoundaryDecision $request $base).Allowed)
$request=New-Request;$request.RemoteEndPoint=[Net.IPEndPoint]::new([Net.IPAddress]::Parse('192.0.2.1'),12345);Check 'Nichtlokaler Peer blockiert' (-not (Get-UiRequestBoundaryDecision $request $base).Allowed)
Check 'Ungueltige Listenerbindung blockiert' (-not (Get-UiRequestBoundaryDecision (New-Request) 'https://127.0.0.1:18484/').Allowed)

# Echter Listener mit unveraenderten Produkt-Gate-/Route-Anweisungen und einem
# ausschliesslich synthetischen Job-Sink. Kein Produktmodul oder Statezugriff.
$server=Join-Path $repo 'Tools/Start-SqlServerLabUi.ps1';$errors=$null;$tokens=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($server,[ref]$tokens,[ref]$errors)
$reply=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Write-UiResponse'},$true))
$gate=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ceq '$requestBoundary' -and $n.Right.Extent.Text -match '^Get-UiRequestBoundaryDecision '},$true))
$veto=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text -ceq '-not $requestBoundary.Allowed'},$true))
$path=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ceq '$path' -and $n.Right.Extent.Text -ceq '$context.Request.Url.AbsolutePath'},$true))
$route=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text -ceq "`$path -eq '/api/commands' -and `$context.Request.HttpMethod -eq 'POST'"},$true))
Check 'Zentrales Produktgate steht vor Routing und Bodylesung' ($errors.Count -eq 0 -and $reply.Count -eq 1 -and $gate.Count -eq 1 -and $veto.Count -eq 1 -and $path.Count -eq 1 -and $route.Count -eq 1 -and $gate[0].Extent.StartOffset -lt $veto[0].Extent.StartOffset -and $veto[0].Extent.EndOffset -lt $path[0].Extent.StartOffset)
function Get-ActiveRequestBinding([string]$Source){
 $parseErrors=$null;$parseTokens=$null;$tree=[Management.Automation.Language.Parser]::ParseInput($Source,[ref]$parseTokens,[ref]$parseErrors)
 if($parseErrors.Count){return $null}
 $include=@($tree.FindAll({param($n)$n -is [Management.Automation.Language.PipelineAst] -and $n.Extent.Text -ceq ". (Join-Path `$PSScriptRoot 'WorkflowUiRequestBoundary.ps1')"},$true))
 $loops=@($tree.FindAll({param($n)$n -is [Management.Automation.Language.WhileStatementAst] -and $n.Condition.Extent.Text -ceq '$listener.IsListening'},$true))
 if($include.Count -ne 1 -or $tree.EndBlock.Statements -notcontains $include[0] -or $loops.Count -ne 1){return $null}
 $loop=$loops[0];$outer=$loop.Parent.Parent
 if($outer -isnot [Management.Automation.Language.TryStatementAst] -or $outer.Parent -ne $tree.EndBlock -or $outer.Body.Statements[-1] -ne $loop -or $include[0].Extent.EndOffset -ge $outer.Extent.StartOffset -or $loop.Body.Statements.Count -ne 2){return $null}
 $receive=$loop.Body.Statements[0];$dispatchTry=$loop.Body.Statements[1]
 if($receive -isnot [Management.Automation.Language.TryStatementAst] -or $receive.Body.Statements.Count -ne 1 -or $receive.Body.Statements[0].Extent.Text -cne '$context = $listener.GetContext()' -or $dispatchTry -isnot [Management.Automation.Language.TryStatementAst]){return $null}
 $statements=$dispatchTry.Body.Statements
 if($statements.Count -lt 5 -or $statements[1].Extent.Text -cne '$requestBoundary = Get-UiRequestBoundaryDecision -Request $context.Request -ListenerUrl $url' -or $statements[2] -isnot [Management.Automation.Language.IfStatementAst] -or $statements[2].Clauses[0].Item1.Extent.Text -cne '-not $requestBoundary.Allowed' -or $statements[3].Extent.Text -cne '$path = $context.Request.Url.AbsolutePath'){return $null}
 $commandRoute=@($statements|Where-Object {$_ -is [Management.Automation.Language.IfStatementAst] -and $_.Clauses[0].Item1.Extent.Text -ceq "`$path -eq '/api/commands' -and `$context.Request.HttpMethod -eq 'POST'"})
 if($commandRoute.Count -ne 1){return $null}
 [pscustomobject]@{Include=$include[0].Extent.Text;Body=$dispatchTry.Body.Extent.Text}
}
$source=[IO.File]::ReadAllText($server);$binding=Get-ActiveRequestBinding $source
Check 'Helper und Gate sind im aktiven gemeinsamen Requestblock eingebunden' ($null -ne $binding)
foreach($variant in @(
 @{Name='fehlender Include';Text=$source.Replace(". (Join-Path `$PSScriptRoot 'WorkflowUiRequestBoundary.ps1')",'')}
 @{Name='inaktiver Include';Text=$source.Replace($binding.Include,('if ($false) { '+$binding.Include+' }'))}
 @{Name='inaktives Gate';Text=$source.Replace($gate[0].Extent.Text,('if ($false) { '+$gate[0].Extent.Text+' }'))}
 @{Name='inaktives Veto';Text=$source.Replace($veto[0].Extent.Text,('if ($false) { '+$veto[0].Extent.Text+' }'))}
 @{Name='inaktive Commandroute';Text=$source.Replace($route[0].Extent.Text,('if ($false) { '+$route[0].Extent.Text+' }'))}
)){Check ('Kontrollfluss-Negativvariante '+$variant.Name) ($null -eq (Get-ActiveRequestBinding $variant.Text))}
# Der vollstaendige gemeinsame Produktblock bleibt zusammen; keine erneute
# Komposition ausgewaehlter Guard-/Routetextfragmente.
$dispatch='foreach($iteration in 1)'+$binding.Body
$cases=@(
 @{Name='foreign-text-plain';Origin='https://synthetic.invalid';Type='text/plain';Status=403}
 @{Name='no-origin-text-plain';Type='text/plain';Status=415}
 @{Name='foreign-json';Origin='https://synthetic.invalid';Type='application/json';Status=403}
 @{Name='null-origin';Origin='null';Type='application/json';Status=403}
 @{Name='wrong-origin-port';Origin='http://127.0.0.1:18485';Type='application/json';Status=403}
 @{Name='cross-site-json';Site='cross-site';Type='application/json';Status=403}
 @{Name='same-site-json';Site='same-site';Type='application/json';Status=403}
 @{Name='unknown-site';Site='synthetic';Type='application/json';Status=403}
 @{Name='unsupported-charset';Type='application/json; charset=utf-16';Status=415}
 @{Name='options-no-cors';Method='OPTIONS';Status=405}
 @{Name='same-origin-json';Origin='SELF';Site='same-origin';Type='application/json';Status=202}
 @{Name='local-originless-authenticated';Type='application/json';Status=202}
)
$probe=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0);$probe.Start();$port=$probe.LocalEndpoint.Port;$probe.Stop()
$url="http://127.0.0.1:$port/";$listener=[Net.HttpListener]::new();$listener.Prefixes.Add($url)
$job=$null;$client=$null;$responses=[Collections.Generic.List[object]]::new()
try{
 $listener.Start()
 $job=Start-ThreadJob -ArgumentList $listener,$url,$dispatch,$reply[0].Extent.Text,$binding.Include,(Join-Path $repo 'Tools'),$cases.Count -ScriptBlock {
  param($Listener,$url,$Dispatch,$Reply,$Include,$ToolsRoot,$Count)
  $ErrorActionPreference='Stop';$jobs=@{};$script:syntheticDispatches=0
  . ([scriptblock]::Create('param([string]$PSScriptRoot)'+"`n"+$Include)) $ToolsRoot
  . (Join-Path $ToolsRoot 'WorkflowUiJsonBody.ps1')
  . (Join-Path $ToolsRoot 'WorkflowUiOperator.ps1')
  $operatorSession=[pscustomobject]@{ListenerUrl=$url;Capability=('a'*64);Active=$true}
  . ([scriptblock]::Create($Reply))
  function Start-UiPublicCommandJob {param($CommandName,$ParameterSetName,$Parameters,[switch]$Confirmed)
   if($CommandName -cne 'Remove-SqlServerLab' -or -not $Confirmed){throw 'SYNTHETIC_JOB_INPUT'}
   $script:syntheticDispatches++;[pscustomobject]@{Id='synthetic-only-'+$script:syntheticDispatches;Action='synthetic-not-executed'}
  }
  for($i=0;$i -lt $Count;$i++){$pending=$Listener.GetContextAsync();if(-not $pending.Wait(10000)){throw 'UI_CONTEXT_TIMEOUT'};$context=$pending.GetAwaiter().GetResult();. ([scriptblock]::Create($Dispatch))}
  [pscustomobject]@{SyntheticDispatches=$script:syntheticDispatches;ProductModule='NOT_IMPORTED';State='NOT_EXECUTED';Provider='NOT_EXECUTED';Sql='NOT_EXECUTED'}
 }
 $client=[Net.Http.HttpClient]::new();$client.Timeout=[timespan]::FromSeconds(5)
 foreach($case in $cases){
  $method=if($case.Method){$case.Method}else{'POST'};$request=[Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::new($method),$url+'api/commands')
  try{
   $null=$request.Headers.TryAddWithoutValidation('X-SqlServerLab-Operator',('a'*64))
   if($case.Origin){$origin=if($case.Origin -ceq 'SELF'){$url.TrimEnd('/')}else{$case.Origin};$null=$request.Headers.TryAddWithoutValidation('Origin',$origin)}
   if($case.Site){$null=$request.Headers.TryAddWithoutValidation('Sec-Fetch-Site',$case.Site)}
   if($method -ceq 'POST'){$body=if($case.Status -eq 202){'{"commandName":"Remove-SqlServerLab","parameterSetName":"synthetic","parameters":{},"confirmed":true}'}else{'synthetic-invalid-json-must-not-be-parsed'};$request.Content=[Net.Http.StringContent]::new($body,[Text.Encoding]::UTF8);$request.Content.Headers.Remove('Content-Type')|Out-Null;$null=$request.Content.Headers.TryAddWithoutValidation('Content-Type',$case.Type)}
   $response=$client.SendAsync($request).GetAwaiter().GetResult()
   try{$responses.Add([pscustomobject]@{Name=$case.Name;Expected=$case.Status;Actual=[int]$response.StatusCode;CorsGrant=$response.Headers.Contains('Access-Control-Allow-Origin')})}finally{$response.Dispose()}
  }finally{$request.Dispose()}
 }
 $null=Wait-Job $job -Timeout 5;if($job.State -ne 'Completed'){throw 'UI_BOUNDARY_JOB_NOT_COMPLETED'};$observed=Receive-Job $job -ErrorAction Stop
 foreach($row in $responses){Check ('Echter HTTP-Request '+$row.Name+' vor Body-/Jobdispatch') ($row.Actual -eq $row.Expected -and -not $row.CorsGrant)}
 Check 'Nur zwei erlaubte Requests erreichen synthetischen Sink' ($observed.SyntheticDispatches -eq 2 -and $observed.ProductModule -ceq 'NOT_IMPORTED' -and $observed.Provider -ceq 'NOT_EXECUTED')
}finally{
 if($client){$client.Dispose()};$listener.Stop();$listener.Close()
 if($job){if($job.State -notin @('Completed','Failed','Stopped')){$null=Wait-Job $job -Timeout 2;if($job.State -notin @('Completed','Failed','Stopped')){Stop-Job $job}};Remove-Job $job -Force}
}
Check 'Eigener Listener geschlossen und Threadjob entfernt' (-not $listener.IsListening -and @((Get-Job)|Where-Object Id -EQ $job.Id).Count -eq 0)
Write-Host "Ergebnis: $script:passed PASS, 0 FAIL"
