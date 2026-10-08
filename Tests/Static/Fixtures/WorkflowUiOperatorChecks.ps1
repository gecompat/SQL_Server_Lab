#Requires -Version 7.2
$ErrorActionPreference='Stop'
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
. (Join-Path $repo 'Tools/WorkflowUiOperator.ps1')
. (Join-Path $PSScriptRoot 'WorkflowUiCommandGrantFixture.ps1')
$script:passed=0
function Check([string]$Name,[bool]$Success){if(-not $Success){throw ('UI_OPERATOR_CHECK_FAILED: '+$Name)};$script:passed++;Write-Host ('PASS '+$Name)}
function New-Request([string]$Path='/api/jobs',[string]$Method='GET'){
 $stream=[IO.MemoryStream]::new();$stream.Dispose()
 [pscustomobject]@{Url=[uri]('http://127.0.0.1:18484'+$Path);Headers=[Collections.Specialized.NameValueCollection]::new();HttpMethod=$Method;InputStream=$stream}
}
Check 'Windows bleibt ohne Unix-APIs zulässig (PS7.2-Floor)' (Get-UiOperatorPlatformDecision Windows $false).Allowed
Check 'Unix mit atomaren Mode-APIs ist zulässig' (Get-UiOperatorPlatformDecision Unix $true).Allowed
$unsupported=Get-UiOperatorPlatformDecision Unix $false
Check 'Unix ohne Mode-APIs wird mit festem Fehler abgewiesen' (-not $unsupported.Allowed -and $unsupported.Code -ceq 'UI_OPERATOR_UNIX_MODE_UNAVAILABLE')
$unsupported=Get-UiOperatorPlatformDecision Other $true
Check 'Unbekannte Plattform erhält keine Rechteautorität' (-not $unsupported.Allowed -and $unsupported.Code -ceq 'UI_OPERATOR_PLATFORM_UNSUPPORTED')
Check 'Tatsächliche Hostfeatures sind für diesen Rechtebeweis vorhanden' (Get-UiOperatorHostDecision).Allowed
$newSource=(Get-Command New-UiOperatorSession).ScriptBlock.Ast.Extent.Text
Check 'Featureveto steht vor Pfadauflösung, Anlage und Credentialbytes' ($newSource.IndexOf('throw $platformDecision.Code') -lt $newSource.IndexOf('[IO.Path]::GetTempPath()') -and $newSource.IndexOf('throw $platformDecision.Code') -lt $newSource.IndexOf('[byte[]]::new(32)'))
$base='http://127.0.0.1:18484/';$first=$null;$second=$null
try {
 $first=New-UiOperatorSession $base;$second=New-UiOperatorSession $base
 Check 'CSPRNG-Capability ist frisch je Start, eigene disjunkte Artefakte' ($first.Capability -cmatch '^[a-f0-9]{64}$' -and $first.Capability -cne $second.Capability -and $first.Directory -cne $second.Directory)
 Check 'Privates Verzeichnis ist vor Credentialhandoff geschützt' (Test-UiOperatorDirectoryProtection $first.Directory)
 $handoff=[IO.File]::ReadAllText($first.File)|ConvertFrom-Json
 Check 'NoBrowser/CLI/Reload erhalten denselben privaten Startvertrag' ($handoff.ContractVersion -ceq 'SqlServerLab.UiOperator/1.0' -and $handoff.StartUrl -ceq $first.StartUrl -and $handoff.Capability -ceq $first.Capability -and $handoff.ListenerUrl -ceq $base)
 $blocked=try{$stream=[IO.FileStream]::new($first.File,[IO.FileMode]::CreateNew);$stream.Dispose();$false}catch{$true}
 Check 'Credentialdatei wird nicht überschrieben' $blocked
 foreach($path in @('/api/jobs','/api/config','/api/actions','/api/commands','/api/operations','/api/batches','/api/unknown','/API/jobs','/api','/API')) {
  $r=New-Request $path;$d=Get-UiOperatorDecision $r $base $first
  Check ('Fehlende Capability vor geschlossenem Body '+$path) (-not $d.Allowed -and $d.Code -ceq 'UI_OPERATOR_REQUIRED')
 }
 foreach($value in @('',('a'*63),('a'*65),('A'*64),($first.Capability+','+$first.Capability),$second.Capability)) {
  $r=New-Request;$r.Headers.Add('X-SqlServerLab-Operator',$value)
  Check 'Falsche/missgebildete/alte Capability liest keinen Body' (-not (Get-UiOperatorDecision $r $base $first).Allowed)
 }
 $r=New-Request;$r.Headers.Add('X-SqlServerLab-Operator',$first.Capability);$r.Headers.Add('X-SqlServerLab-Operator',$first.Capability)
 Check 'Doppelte Credentialheader bleiben gesperrt' (-not (Get-UiOperatorDecision $r $base $first).Allowed)
 foreach($method in @('GET','POST')){$r=New-Request '/api/jobs' $method;$r.Headers.Add('X-SqlServerLab-Operator',$first.Capability);Check ('Passende Capability vor Body '+$method) (Get-UiOperatorDecision $r $base $first).Allowed}
 $r.Url=[uri]'http://127.0.0.1:18485/api/jobs';Check 'Anderer Listenerport bleibt gesperrt' (-not (Get-UiOperatorDecision $r $base $first).Allowed)
 Check 'Session eines anderen Starts bleibt gesperrt' (-not (Get-UiOperatorDecision (New-Request) 'http://127.0.0.1:18485/' $first).Allowed)
 Check 'Statische HTML/JS tragen kein Credential' (Get-UiOperatorDecision (New-Request '/operator-transport.js') $base $first).Allowed
 $directory=$second.Directory;Check 'Eigener Scope wird gezielt geschlossen/entfernt' (Close-UiOperatorSession $second);Check 'Andere aktive Sitzung bleibt erhalten' (-not (Test-Path -LiteralPath $directory) -and (Test-Path -LiteralPath $first.File));$second=$null
} finally { if($first){$null=Close-UiOperatorSession $first};if($second){$null=Close-UiOperatorSession $second} }

# Vollständiger unveränderter Produkt-Requestblock, tatsächliche Headergrenze,
# Operatorhelper und JSON-Reader; nur Fach-/Job-Sinks sind synthetisch.
$errors=$null;$tokens=$null;$source=[IO.File]::ReadAllText((Join-Path $repo 'Tools/Start-SqlServerLabUi.ps1'))
$ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)
$loop=$ast.Find({param($n)$n -is [Management.Automation.Language.WhileStatementAst] -and $n.Condition.Extent.Text -ceq '$listener.IsListening'},$true)
$block=$loop.Body.Statements[1].Body
$gate=$block.Statements|Where-Object {$_.Extent.Text -ceq '$operatorDecision = Get-UiOperatorDecision -Request $context.Request -ListenerUrl $url -Session $operatorSession'}
$firstRoute=$block.Statements|Where-Object {$_ -is [Management.Automation.Language.IfStatementAst] -and $_.Clauses[0].Item1.Extent.Text.StartsWith('$path -eq ')}|Select-Object -First 1
Check 'Operatorgate steht aktiv nach Headergrenze vor erster Route' ($errors.Count -eq 0 -and $gate -and $gate.Extent.StartOffset -gt $block.Statements[2].Extent.EndOffset -and $gate.Extent.EndOffset -lt $firstRoute.Extent.StartOffset)
$hostWrites=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -ceq 'Write-Host'},$true))
Check 'Startup-Logs enthalten nur öffentlichen Listener und privaten Locator' (@($hostWrites|Where-Object {$_.Extent.Text -match 'operatorSession\.(Capability|StartUrl)'}).Count -eq 0 -and $source -match 'Start-Process \$operatorSession.StartUrl')
$reply=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Write-UiResponse'},$true).Extent.Text
$dispatch='foreach($iteration in 1)'+$block.Extent.Text
$cases=@(
 @{Path='api/config';Method='GET';Status=403}
 @{Path='api/jobs';Method='GET';Status=403}
 @{Path='API/config';Method='GET';Status=403}
 @{Path='Api/commands';Method='POST';Status=403}
 @{Path='api';Method='GET';Status=403}
 @{Path='api/commands';Method='POST';Status=403}
 @{Path='api/initial-setup';Method='POST';Status=403}
 @{Path='api/commands';Method='POST';Token='wrong';Status=403}
 @{Path='api/config';Method='GET';Token='valid';Status=200}
 @{Path='api/commands';Method='POST';Token='valid';Origin='foreign';Status=403}
 @{Path='api/commands';Method='POST';Token='valid';Status=202}
 @{Path='api/commands';Method='POST';Token='valid';Status=202}
)
$probe=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0);$probe.Start();$port=$probe.LocalEndpoint.Port;$probe.Stop()
$url="http://127.0.0.1:$port/";$listener=[Net.HttpListener]::new();$listener.Prefixes.Add($url);$session=$null;$job=$null;$client=$null
try {
 $session=New-UiOperatorSession $url;$listener.Start()
 $job=Start-ThreadJob -ArgumentList $listener,$url,$session,$dispatch,$reply,(Join-Path $repo 'Tools'),($cases.Count+2) -ScriptBlock {
  param($Listener,$url,$operatorSession,$Dispatch,$Reply,$ToolsRoot,$Count)
  $ErrorActionPreference='Stop';$script:effects=0;$jobs=@{}
  . (Join-Path $ToolsRoot 'WorkflowUiRequestBoundary.ps1');. (Join-Path $ToolsRoot 'WorkflowUiOperator.ps1');. (Join-Path $ToolsRoot 'WorkflowUiJsonBody.ps1');. ([scriptblock]::Create($Reply))
  . (Join-Path $ToolsRoot '../Tests/Static/Fixtures/WorkflowUiCommandGrantFixture.ps1')
  $commandGrantStore=New-UiCommandGrantStore $operatorSession
  function Get-UiCapabilityConfig {$script:effects++;[pscustomobject]@{Synthetic=$true}}
  function Start-UiPublicCommandJob {param($CommandName,$ParameterSetName,$Parameters,[switch]$Confirmed)$script:effects++;[pscustomobject]@{Id='synthetic';Action='NOT_EXECUTED'}}
  try{for($i=0;$i -lt $Count;$i++){$pending=$Listener.GetContextAsync();if(-not $pending.Wait(10000)){throw 'UI_OPERATOR_OWN_CONTEXT_TIMEOUT'};$context=$pending.GetAwaiter().GetResult();. ([scriptblock]::Create($Dispatch))}}finally{Close-UiCommandGrantStore $commandGrantStore}
  [pscustomobject]@{Effects=$script:effects;ProductModule='NOT_IMPORTED';Provider='NOT_EXECUTED';State='NOT_EXECUTED';Sql='NOT_EXECUTED'}
 }
 $client=[Net.Http.HttpClient]::new();$client.Timeout=[timespan]::FromSeconds(5)
 foreach($case in $cases){
  $request=[Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::new($case.Method),$url+$case.Path)
  try {
   if($case.Token){$cap=if($case.Token -ceq 'valid'){$session.Capability}else{'a'*64};$null=$request.Headers.TryAddWithoutValidation('X-SqlServerLab-Operator',$cap)}
   if($case.Origin){$null=$request.Headers.TryAddWithoutValidation('Origin','https://synthetic.invalid')}
   if($case.Method -ceq 'POST'){$body=if($case.Status -eq 202){'{"commandName":"synthetic","parameterSetName":"synthetic","parameters":{},"confirmed":true}'}else{'invalid-json-never-parse'};if($case.Status -eq 202){$grant=Get-FixtureCommandGrant $url $body $session.Capability;$null=$request.Headers.TryAddWithoutValidation('X-SqlServerLab-Action-Grant',$grant.grant)};$request.Content=[Net.Http.StringContent]::new($body,[Text.Encoding]::UTF8,'application/json')}
   $response=$client.SendAsync($request).GetAwaiter().GetResult()
   try {Check ('Echter HTTP-Request vor Fach-/Jobdispatch '+$case.Path+' '+$case.Method+' '+$case.Token) ([int]$response.StatusCode -eq $case.Status -and -not $response.Headers.Contains('Access-Control-Allow-Origin'))}finally{$response.Dispose()}
  }finally{$request.Dispose()}
 }
 $null=Wait-Job $job -Timeout 3;if($job.State -ne 'Completed'){throw 'UI_OPERATOR_JOB_INCOMPLETE'};$observed=Receive-Job $job -ErrorAction Stop
 Check 'Nur drei autorisierte Reads/Commands erreichen synthetische Sinks' ($observed.Effects -eq 3 -and $observed.ProductModule -ceq 'NOT_IMPORTED' -and $observed.State -ceq 'NOT_EXECUTED')
}finally{
 if($client){$client.Dispose()};$listener.Stop();$listener.Close();if($job){if($job.State -notin @('Completed','Stopped','Failed')){Stop-Job $job};Remove-Job $job -Force};if($session){$null=Close-UiOperatorSession $session}
}
Check 'Eigener Listener, Job und private Credentialdatei entfernt' (-not $listener.IsListening -and -not (Test-Path -LiteralPath $session.Directory) -and @(Get-Job|Where-Object Id -EQ $job.Id).Count -eq 0)
Write-Host "Ergebnis: $script:passed PASS, 0 FAIL"
