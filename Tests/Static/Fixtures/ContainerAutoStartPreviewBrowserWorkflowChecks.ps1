#Requires -Version 7.2
$ErrorActionPreference='Stop'
$repo=Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
. (Join-Path $repo Tests/Common/ContainerAutoStartPreviewBrowserAcceptance.ps1)
$root=Join-Path ([IO.Path]::GetTempPath()) ('SqlServerLab-AutoStartBrowser-'+[guid]::NewGuid().ToString('N'))
$checks=0
function Check($value,$name){if(-not $value){throw ('AUTOSTART_BROWSER_CHECK_FAILED: '+$name)};$script:checks++;Write-Host ('PASS: '+$name)}
function Reject($Action,$code,$name){$errorText=$null;try{& $Action}catch{$errorText=$_.Exception.Message};Check ($errorText -clike ('*'+$code+'*')) $name}
function Remove-OwnFixtureRoot([string]$Path){
 $absolute=[IO.Path]::GetFullPath($Path);$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
 if([IO.Path]::GetDirectoryName($absolute) -cne $temp -or [IO.Path]::GetFileName($absolute) -cnotmatch '^SqlServerLab-AutoStartBrowser-[a-f0-9]{32}$'){throw 'FIXTURE_CLEANUP_SCOPE'}
 if(Test-Path -LiteralPath $absolute){$item=Get-Item -LiteralPath $absolute -Force
  while($item){if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'FIXTURE_CLEANUP_REPARSE'};$item=$item.Parent}
  foreach($item in @(Get-Item -LiteralPath $absolute -Force)+@(Get-ChildItem -LiteralPath $absolute -Force -Recurse)){
   if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'FIXTURE_CLEANUP_REPARSE'}
  };Remove-Item -LiteralPath $absolute -Recurse -Force -ErrorAction Stop
 }
}
try{
 $null=New-Item -ItemType Directory -Path $root
 $evidence=Join-Path $root ('test-runs/port-preview-'+[guid]::NewGuid().ToString('N'))
 $null=New-Item -ItemType Directory -Path $evidence
 $record=Write-AutoStartBrowserAcceptanceFile $evidence 'test.private.json' '{"Status":"PASS"}'
 Check ($record.Bytes -eq 17 -and $record.Sha256 -ceq (Get-FileHash $record.Path).Hash) 'Exclusive evidence preserves actual bytes/hash'
 Reject {Write-AutoStartBrowserAcceptanceFile $evidence 'test.private.json' '{}'} 'exists' 'Evidence refuses overwrite'
 Reject {Write-AutoStartBrowserAcceptanceFile $evidence '../escape.private.json' '{}'} 'EVIDENCE_NAME' 'Traversal veto before write'
 Reject {Write-AutoStartBrowserAcceptanceFile $root 'escape.private.json' '{}'} 'EVIDENCE_SCOPE' 'Non-own root veto before write'
 Reject {Write-AutoStartBrowserAcceptanceFile $evidence 'large.private.json' ('x'*131073)} 'EVIDENCE_SIZE' 'Evidence size veto before create'
 Check (-not(Test-Path (Join-Path $evidence large.private.json))) 'Oversize leaves no file'
 $data=Join-Path $root data;$state=Join-Path $data State
 $priorData=$env:SQL_SERVER_LAB_DATA_ROOT;$priorState=$env:SQL_SERVER_LAB_STATE
 $start=New-AutoStartBrowserServerStartInfo 'C:/synthetic/pwsh.exe' 'C:/synthetic/server.ps1' 'C:/synthetic/config.json' ([pscustomobject]@{DataRoot=$data;StateRoot=$state})
 Check ($start.Environment['SQL_SERVER_LAB_DATA_ROOT'] -ceq $data -and $start.Environment['SQL_SERVER_LAB_STATE'] -ceq $state -and
  $start.UseShellExecute -eq $false -and $start.ArgumentList.Contains('-NoProfile')) 'Child process has exact DataRoot and StateRoot, no shell/global fallback'
 Check ($env:SQL_SERVER_LAB_DATA_ROOT -ceq $priorData -and $env:SQL_SERVER_LAB_STATE -ceq $priorState) 'Parent process environment untouched'
 $time=[datetime]::UtcNow
 function New-SyntheticProcess([string]$Path,[datetime]$Time){
  $p=[pscustomobject]@{HasExited=$false;StartTime=$Time;MainModule=[pscustomobject]@{FileName=$Path};Kills=0;Waits=0}
  $p|Add-Member ScriptMethod Kill {param($Tree)$this.Kills++;$this.HasExited=$true}
  $p|Add-Member ScriptMethod WaitForExit {param($Timeout)$this.Waits++;return $true};$p
 }
 $p=New-SyntheticProcess 'C:/synthetic/edge.exe' $time
 Reject {Stop-AutoStartBrowserOwnedProcess $p 'C:/foreign/edge.exe' $time} 'PROCESS_CUSTODY' 'Foreign executable veto before process stop'
 Reject {Stop-AutoStartBrowserOwnedProcess $p 'C:/synthetic/edge.exe' $time.AddSeconds(1)} 'PROCESS_CUSTODY' 'Start-time drift veto before process stop'
 Check ($p.Kills -eq 0) 'Custody veto has zero stop effects'
 Stop-AutoStartBrowserOwnedProcess $p 'C:/synthetic/edge.exe' $time
 Check ($p.Kills -eq 1 -and $p.Waits -eq 1) 'Only actual bound handle/tree stopped once'
 $stdout=[IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes('bounded-output'));$stderr=[IO.MemoryStream]::new([byte[]]@())
 $p=[pscustomobject]@{StandardOutput=[pscustomobject]@{BaseStream=$stdout};StandardError=[pscustomobject]@{BaseStream=$stderr}}
 $capture=New-AutoStartBrowserPipeCapture $p
 try{for($i=0;$i -lt 4;$i++){Read-AutoStartBrowserPipeCapture $capture}
  Check ($capture.Total -eq 14 -and @($capture.Done|Where-Object{-not $_}).Count -eq 0 -and
   [Text.Encoding]::UTF8.GetString($capture.Streams[0].ToArray()) -ceq 'bounded-output') 'Actual bounded pipe collector drains both streams and EOF'
 }finally{$stdout.Dispose();$stderr.Dispose();foreach($s in $capture.Streams){$s.Dispose()}}
 $stdout=[IO.MemoryStream]::new([byte[]]::new(65537));$stderr=[IO.MemoryStream]::new([byte[]]@())
 $capture=New-AutoStartBrowserPipeCapture ([pscustomobject]@{StandardOutput=[pscustomobject]@{BaseStream=$stdout};StandardError=[pscustomobject]@{BaseStream=$stderr}})
 try{Reject {for($i=0;$i -lt 20;$i++){Read-AutoStartBrowserPipeCapture $capture}} 'OUTPUT_LIMIT' 'Actual pipe collector enforces byte cap without process startup'}finally{$stdout.Dispose();$stderr.Dispose();foreach($s in $capture.Streams){$s.Dispose()}}
 $tokens=$null;$errors=$null;$server=[Management.Automation.Language.Parser]::ParseInput((Get-AutoStartBrowserServerSource),[ref]$tokens,[ref]$errors)
 Check ($errors.Count -eq 0) 'Actual generated server source parses'
 $integration=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo Tests/Integration/Invoke-ContainerAutoStartPreviewAcceptance.ps1),[ref]$tokens,[ref]$errors)
 Check ($errors.Count -eq 0 -and $integration.ParamBlock.Parameters.Name.VariablePath.UserPath -contains 'BrowserOnly') 'Actual entry exposes separate BrowserOnly mode'
 $mode=@($integration.FindAll({param($n)$n -is [Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text -ceq '$ConsoleOnly -and $BrowserOnly'},$true))
 Check ($mode.Count -eq 1) 'Actual entry rejects simultaneous ConsoleOnly and BrowserOnly before scope creation'
 $ConsoleOnly=$true;$BrowserOnly=$true
 Reject {& ([scriptblock]::Create($mode[0].Extent.Text))} 'MODE_INVALID' 'Actual mode veto executed with no runtime'
 $admitCall=@($integration.FindAll({param($n)$n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -ceq 'Assert-AutoStartBrowserRuntimeMetadata'},$true))
 $createCall=@($integration.FindAll({param($n)$n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -ceq 'New-SqlServerLab'},$true))
 Check ($admitCall.Count -eq 1 -and $createCall.Count -eq 1 -and $admitCall[0].Extent.StartOffset -lt $createCall[0].Extent.StartOffset) 'Actual BrowserOnly tool admission precedes runtime arrangement'
 $hostHook=@($server.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Write-Host'},$true))[0]
 $bindingSource='function Write-Host {'+$hostHook.Body.ParamBlock.Extent.Text+';[pscustomobject]@{Value=@($Object);Color=$ForegroundColor}};Write-Host "SQL_Server_Lab Workflow UI: http://127.0.0.1:19499/" -ForegroundColor Green'
 $binding=& ([scriptblock]::Create($bindingSource))
 Check (@($binding.Value).Count -eq 1 -and $binding.Value[0] -ceq 'SQL_Server_Lab Workflow UI: http://127.0.0.1:19499/' -and
  $binding.Color -eq [ConsoleColor]::Green) 'Actual Write-Host hook binds positional UI readiness text'
 $hookIf=$hostHook.Body.EndBlock.Statements[0]
 $hookText=($hookIf.Clauses[0].Item2.Statements[0..2].Extent.Text -join "`n")
 if(-not $hookText.Contains('$listener -isnot [Net.HttpListener]')){throw 'BROWSER_FIXTURE_HOOK_TYPE_CHANGED'}
 # Replace ONLY the native listener type leaf. Caller scope lookup, actual
 # listening/prefix guard and actual exclusive ready writer still execute.
 $hookText=$hookText.Replace('$listener -isnot [Net.HttpListener]','$listener -isnot [pscustomobject]')
 $scopeEvidence=Join-Path $root ('test-runs/port-preview-'+[guid]::NewGuid().ToString('N'))
 $null=New-Item -ItemType Directory -Path $scopeEvidence
 $scopeProbe=Join-Path $root 'scope-probe.private.ps1'
 [IO.File]::WriteAllText($scopeProbe,'$listener=[pscustomobject]@{IsListening=$true;Prefixes=@("http://127.0.0.1:19499/")};Write-Host "SQL_Server_Lab Workflow UI: http://127.0.0.1:19499/" -ForegroundColor Green',[Text.UTF8Encoding]::new($false))
 $global:browserServerConfig=[pscustomobject]@{ListenerPort=19499;EvidenceRoot=$scopeEvidence}
 try{
  $probeSource='function Write-Host {'+$hostHook.Body.ParamBlock.Extent.Text+';if('+$hookIf.Clauses[0].Item1.Extent.Text+'){' + $hookText + '}};& $scopeProbe'
  & ([scriptblock]::Create($probeSource))
  Check (Test-Path -LiteralPath (Join-Path $scopeEvidence 'browser-listener-ready.private.json')) 'Actual hook reads bound config across child-script scope'
 }finally{Remove-Variable -Name browserServerConfig -Scope Global -ErrorAction SilentlyContinue}
 $global:browserServerConfig=[pscustomobject]@{ListenerPort=19499;EvidenceRoot=$evidence}
 function Invoke-SyntheticReadyHook {. ([scriptblock]::Create($hookText))}
 & {$listener=[pscustomobject]@{IsListening=$true;Prefixes=@('http://127.0.0.1:19499/')};Invoke-SyntheticReadyHook}
 $readyFile=Join-Path $evidence browser-listener-ready.private.json
 Check ((Get-Content $readyFile -Raw) -ceq '{"ListenerStarted":true}') 'Actual hook resolves listener from caller scope and writes readiness after exact bind'
 $readyHash=(Get-FileHash $readyFile).Hash
 Reject {& {$listener=[pscustomobject]@{IsListening=$true;Prefixes=@('http://127.0.0.1:14336/')};Invoke-SyntheticReadyHook}} 'LISTENER_BINDING' 'Wrong listener prefix veto before ready write'
 Check ((Get-FileHash $readyFile).Hash -ceq $readyHash) 'Listener veto retains readiness evidence without overwrite'
 Remove-Variable -Name browserServerConfig -Scope Global -ErrorAction Stop
 # Reuse ONLY the existing HTTP fixture's registered synthetic Arrange. Its
 # assertions are not repeated. The actual module/public/core/HTTP bodies run;
 # the native inspect executable is the existing synthetic process leaf.
 $httpFixture=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo Tests/Static/Fixtures/ContainerAutoStartPreviewHttpChecks.ps1),[ref]$tokens,[ref]$errors)
 $httpTry=@($httpFixture.FindAll({param($n)$n -is [Management.Automation.Language.TryStatementAst]},$false))[0]
 $arrange=$httpTry.Body.Statements[0].Extent.Text
 foreach($pair in @(@('id=$provider;provider=$provider;containerId',"id='primary';provider=`$provider;containerId"),@('id=$provider;provider=$provider',"id='primary';provider=`$provider"),@('instanceIds=@($provider)',"instanceIds=@('primary')"))){
  if(-not $arrange.Contains($pair[0])){throw 'BROWSER_FIXTURE_ARRANGE_CHANGED'};$arrange=$arrange.Replace($pair[0],$pair[1])
 }
 $module=Import-Module (Join-Path $repo SqlServerLab.psd1) -Force -PassThru
 try{
  $tools=Join-Path $root tools;$null=New-Item -ItemType Directory $tools
  [IO.File]::WriteAllText((Join-Path $tools node.exe),'SYNTHETIC_NOT_EXECUTABLE');[IO.File]::WriteAllText((Join-Path $tools msedge.exe),'SYNTHETIC_NOT_EXECUTABLE')
  [IO.File]::WriteAllText((Join-Path $tools package.json),'{"name":"playwright","license":"Apache-2.0"}')
  $metadata=[ordered]@{Contract='SqlServerLab.AutoStartBrowserRuntime/1.0';Node=$null;PlaywrightPackage=$null;Browser=$null;ListenerPort=19499}
  foreach($pair in @(@('Node','node.exe'),@('PlaywrightPackage','package.json'),@('Browser','msedge.exe'))){$file=Join-Path $tools $pair[1];$metadata[$pair[0]]=[ordered]@{Path=$file;Sha256=(Get-FileHash $file).Hash;Bytes=(Get-Item $file).Length}}
  $metadataPath=Join-Path $root runtime.private.json
  function Save-Metadata {$metadata|ConvertTo-Json -Depth 5|Set-Content -LiteralPath $metadataPath -Encoding utf8}
  Save-Metadata;$bound=Assert-AutoStartBrowserRuntimeMetadata $module $metadataPath
  Check ($bound.ListenerPort -eq 19499) 'Actual metadata reader verifies all existing tool hash/byte pins without launch'
  $metadata.ListenerPort=14336;Save-Metadata
  Reject {Assert-AutoStartBrowserRuntimeMetadata $module $metadataPath} 'TOOLS_INVALID' 'Reserved port veto before process start'
  $metadata.ListenerPort=19499;$metadata.Contract=@($metadata.Contract);Save-Metadata
  Reject {Assert-AutoStartBrowserRuntimeMetadata $module $metadataPath} 'TOOLS_INVALID' 'Runtime contract array veto'
  $metadata.Contract='SqlServerLab.AutoStartBrowserRuntime/1.0';$metadata.Node.Sha256='0'*64;Save-Metadata
  Reject {Assert-AutoStartBrowserRuntimeMetadata $module $metadataPath} 'TOOLS_DRIFT' 'Actual tool pin drift veto before process start'
  $rendered=[pscustomobject]@{Contract='SqlServerLab.AutoStartRenderedBrowserEvidence/1.0';Status='PASS';PublicPreviewRequests=3;MetadataRequests=3;EarlyCancelInvalidPreviewRequests=0;LateRealResponseDisplayVeto=$true;RenderedCategories=$true;DeniedUnrelatedRequests=4;PreviewResponsesStubbed=$false}
  Assert-AutoStartBrowserRenderedRecord $rendered
  foreach($field in @('Contract','Status','PublicPreviewRequests','LateRealResponseDisplayVeto')){$value=$rendered.$field;$rendered.$field=@($value)
   try{Reject {Assert-AutoStartBrowserRenderedRecord $rendered} 'RENDERED_RECORD' ('Private rendered record scalar-array veto '+$field)}finally{$rendered.$field=$value}
  }
  $cleanupTry=@($integration.FindAll({param($n)$n -is [Management.Automation.Language.TryStatementAst] -and $n.Body.Extent.Text -match 'Remove-PortPreviewAcceptanceScope'},$false))[0]
  $cleanupCalls=0;function Remove-PortPreviewAcceptanceScope {$script:cleanupCalls++;throw 'UNEXPECTED_RUNTIME_CLEANUP'}
  $scope=[pscustomobject]@{DataRoot=$root};$BrowserOnly=$true;$primaryError=[Management.Automation.ErrorRecord]::new([Exception]::new('synthetic failure'),'synthetic',[Management.Automation.ErrorCategory]::NotSpecified,$null)
  $primaryError.Exception.Data['AutoStartBrowserProcessRecoveryRequired']=$true
  Reject {& ([scriptblock]::Create($cleanupTry.Body.Extent.Text.TrimStart('{').TrimEnd('}')))} 'PROCESS_RECOVERY_REQUIRED' 'Actual entry retains runtime custody when own child recovery is unresolved'
  Check ($cleanupCalls -eq 0) 'Process recovery veto invokes zero runtime removal calls'
  $commonAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo Tests/Common/ContainerAutoStartPreviewBrowserAcceptance.ps1),[ref]$tokens,[ref]$errors)
  $invoker=@($commonAst.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Invoke-AutoStartBrowserAcceptanceObservations'},$false))[0]
  $failure=@($invoker.Body.FindAll({param($n)$n -is [Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text -ceq '$primary'},$true))
  Check ($failure.Count -eq 1) 'Actual orchestration primary-failure branch extracted once'
  $primary=[Management.Automation.ErrorRecord]::new([Exception]::new('SYNTHETIC_RENDER_FAILURE'),'synthetic',[Management.Automation.ErrorCategory]::NotSpecified,$null)
  $driverTime=[datetime]::UtcNow;$cleanupErrors=[Collections.Generic.List[object]]::new()
  Reject {& ([scriptblock]::Create($failure[0].Extent.Text))} 'SYNTHETIC_RENDER_FAILURE' 'Actual orchestration preserves original failure'
  Check ($primary.Exception.Data['AutoStartBrowserProcessRecoveryRequired'] -eq $true) 'Started failed driver retains custody even after its PID exited'
  $admission=@($server.EndBlock.Statements|Where-Object{$_.Extent.Text -like '& $module {*'})
  Check ($admission.Count -eq 1) 'Actual child prelistener authority block extracted once'
  if($IsWindows){
  foreach($provider in @('docker','podman')){
   $own=Join-Path $root ('admission-'+$provider)
   $resolved=& $module {
    param($Own,$Provider,$Tools)
    $exe=Join-Path $Tools ($Provider+'.exe');[IO.File]::WriteAllText($exe,'SYNTHETIC_NOT_EXECUTABLE')
    $pin=[pscustomobject]@{Provider=$Provider;Invocation=$exe;Endpoint='npipe:////./pipe/synthetic';IdentityPath='';IdentitySha256=''}
    if($Provider -ceq 'podman'){$identity=Join-Path $Tools synthetic-key;[IO.File]::WriteAllText($identity,'SYNTHETIC_KEY');$pin.Endpoint='ssh://synthetic@127.0.0.1:19499/synthetic';$pin.IdentityPath=$identity;$pin.IdentitySha256=(Get-FileHash $identity).Hash.ToLowerInvariant()}
    $operation=[guid]::NewGuid().ToString('N');$state=Join-Path $Own State
    $null=Initialize-LabOwnedHostPolicy -StateRoot $Own -RuntimePins @($pin) -ParentOperationId $operation
    $null=Initialize-LabOwnedHostPolicy -StateRoot $state -RuntimePins @($pin) -ParentOperationId $operation
    $null=Initialize-LabManagedDataRoot -DataRoot $Own -ControllerId ([guid]::NewGuid().ToString('D')) -Confirm:$false
    $config=Get-LabStorageConfiguration -DataRoot $Own;$null=Write-LabStorageConfiguration -Configuration $config
    $instance=[pscustomobject]@{id='primary';provider=$Provider;version='2025';profile='standard';autostart='off';drives=@();databases=@();software=@()}
    $desired=New-LabDesiredStateSnapshot -ResolvedLab ([pscustomobject]@{name='Synthetic child authority';instances=@($instance)}) -ProvisioningMode adhoc -PersistentData $false
    $run=New-LabRunState -StateRoot $state -Metadata @{desiredState=$desired;persistentData=$false;workflowOperationId=$operation} -ProviderSubRuns @([pscustomobject]@{provider=$Provider;instanceIds=@('primary')})
    $stored=Get-Content (Join-Path $run.RunDir run-state.json) -Raw|ConvertFrom-Json -Depth 60;$stored.state='RUNNING';$stored.providerSubRuns[0].state='RUNNING'
    $stored|ConvertTo-Json -Depth 60|Set-Content (Join-Path $run.RunDir run-state.json) -Encoding utf8
    @{instances=@(@{id='primary';provider=$Provider;containerId=('a'*64);containerName='SYNTHETIC';port=1})}|ConvertTo-Json -Depth 8|Set-Content (Join-Path $run.RunDir connection-info.json) -Encoding utf8
    [pscustomobject]@{Scope=[pscustomobject]@{DataRoot=$Own;StateRoot=$state;ParentOperationId=$operation;ParentPolicyHash=(Get-FileHash (Join-Path $Own owned-host-policy.json)).Hash;StatePolicyHash=(Get-FileHash (Join-Path $state owned-host-policy.json)).Hash};RunId=$run.RunId;Provider=$Provider;Invocation=$exe}
   } $own $provider $tools
   $c=[pscustomobject]@{Scope=$resolved.Scope;RunId=$resolved.RunId;Provider=$provider};$resolution=[pscustomobject]@{Invocation=$resolved.Invocation}
   $oldData=$env:SQL_SERVER_LAB_DATA_ROOT;$oldState=$env:SQL_SERVER_LAB_STATE
   try{
    $env:SQL_SERVER_LAB_DATA_ROOT=$c.Scope.DataRoot;$env:SQL_SERVER_LAB_STATE=$c.Scope.StateRoot
    & ([scriptblock]::Create($admission[0].Extent.Text))
    Check $true ('Actual child parent/run policy ACL/origin/root/pin/target admission '+$provider)
    $resolution.Invocation=Join-Path $tools foreign.exe
    Reject {& ([scriptblock]::Create($admission[0].Extent.Text))} 'BROWSER_PIN' ('Child invocation mismatch veto before listener '+$provider)
    $resolution.Invocation=$resolved.Invocation;$env:SQL_SERVER_LAB_STATE=$root
    Reject {& ([scriptblock]::Create($admission[0].Extent.Text))} 'BROWSER_ROOT' ('Child StateRoot mismatch veto before listener '+$provider)
   }finally{$env:SQL_SERVER_LAB_DATA_ROOT=$oldData;$env:SQL_SERVER_LAB_STATE=$oldState}
  }
  }else{
   $unsupported=Join-Path $root 'admission-unsupported'
   Reject {& $module {param($Path)Initialize-LabOwnedHostPolicy -StateRoot $Path -RuntimePins @([pscustomobject]@{})} $unsupported} 'OWNED_HOST_PLATFORM_UNSUPPORTED' 'Non-Windows actual owned policy rejects before root mutation'
   Check (-not (Test-Path -LiteralPath $unsupported)) 'Non-Windows unsupported root remains absent'
  }
  . ([scriptblock]::Create($arrange))
  & $module {Set-Item Function:script:Get-SqlServerLabReconcilePlan $script:publicBody}
  . (Join-Path $repo Tests/Common/ContainerPortPreviewAcceptance.ps1)
  . (Join-Path $repo Tests/Common/ContainerAutoStartPreviewAcceptance.ps1)
  $observer=@($server.FindAll({param($n)$n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ceq '$restore'},$true))
  Check ($observer.Count -eq 1) 'Actual generated child observer installation extracted once'
  $targets=@(& $module {Get-LabContainerPortConsoleTargets -DataRoot $script:dataRoot})
  foreach($target in $targets){
   $scope=[pscustomobject]@{DataRoot=(& $module {$script:dataRoot});StateRoot=(Join-Path (& $module {$script:dataRoot}) State)}
   $ownEvidence=Join-Path $repo ('.artifacts/test-runs/port-preview-'+[guid]::NewGuid().ToString('N'))
   $null=New-Item -ItemType Directory -Path $ownEvidence -Force
   $c=[pscustomobject]@{RepositoryRoot=$repo;Scope=$scope;RunId=$target.RunId;Provider=$target.Provider;EvidenceRoot=$ownEvidence;ListenerPort=19499}
   & $module {param($t)Set-HttpInspect $t} $target
   $original=@{};& $module {param($saved)foreach($n in @('Get-SqlServerLabReconcilePlan','Invoke-LabOwnedHostNativeProcess','Invoke-LabContainerAutoStartPreviewHttpRequest')){$saved[$n]=(Get-Item ('Function:'+ $n)).ScriptBlock}} $original
   . ([scriptblock]::Create($observer[0].Extent.Text))
   try{
    function Send-Observed([string]$Body){
     $bytes=[Text.Encoding]::UTF8.GetBytes($Body);$stream=[IO.MemoryStream]::new($bytes,$false)
     try{$r=[pscustomobject]@{HttpMethod='POST';ContentType='application/json';Headers=@{Origin='http://127.0.0.1:19499'};Url=[uri]'http://127.0.0.1:19499/api/container-autostart-preview';LocalEndPoint=[Net.IPEndPoint]::new([Net.IPAddress]::Loopback,19499);RemoteEndPoint=[Net.IPEndPoint]::new([Net.IPAddress]::Loopback,19000);InputStream=$stream}
      & $module {param($r)Invoke-LabContainerAutoStartPreviewHttpRequest -Request $r -ListenerPort 19499} $r
     }finally{$stream.Dispose()}
    }
    $before=Get-PortPreviewAcceptanceFileBinding $scope.DataRoot;$inspect=$global:httpInspectCalls
    $null=Send-Observed '{"Action":"Read"}'
    Reject {Send-Observed '{"Action":["Read"]}'} 'AUTOSTART_HTTP_INVALID' ('Actual observer invalid request '+$target.Provider)
    Check ((& $module {$script:browserAcceptancePublicCount}) -eq 0 -and $global:httpInspectCalls -eq $inspect) ('Metadata/invalid HTTP has zero public/inspect '+$target.Provider)
    foreach($desired in @('on','off','on')){
     $body=@{Action='Preview';RunId=$target.RunId;InstanceId='primary';AutoStart=$desired}|ConvertTo-Json -Compress
     $response=Send-Observed $body
     Check ($response.Status -ceq 'PLAN_ONLY') ('Actual HTTP/public/core completed '+$target.Provider+' '+$desired)
    }
    $records=@(Get-ChildItem $ownEvidence -Filter 'browser-request-*.private.json'|ForEach-Object{Get-Content $_.FullName -Raw|ConvertFrom-Json})
    Check ((& $module {$script:browserAcceptancePublicCount}) -eq 3 -and $global:httpInspectCalls-$inspect -eq 3 -and ($records|Measure-Object PublicCalls -Sum).Sum -eq 3) ('Transparent observer adds no public/inspect calls '+$target.Provider)
    Check (@($records|Where-Object RepeatContentEqual -eq $true).Count -eq 1 -and @($records|Where-Object DesiredOnlyDifference -eq $true).Count -eq 1) ('Real content key repeat/desired booleans '+$target.Provider)
    Check (($before|ConvertTo-Json -Depth 5 -Compress) -ceq ((Get-PortPreviewAcceptanceFileBinding $scope.DataRoot)|ConvertTo-Json -Depth 5 -Compress)) ('Actual observed preview state bytes unchanged '+$target.Provider)
    $payloads=@(Get-ChildItem $ownEvidence -Filter '*.json'|ForEach-Object{Get-Content $_.FullName -Raw}) -join '|'
    Check ($payloads -notmatch 'PRIVATE_CANARY|ObservationKey|ContainerId|StateRoot|HostPort') ('Fixed private categories omit raw authority '+$target.Provider)
    $global:httpInspect.Config.Labels.'sql-server-lab.autostart'='unknown'
    Reject {Send-Observed $body} 'AUTOSTART_HTTP_INVALID' ('Actual blocked core DTO veto '+$target.Provider)
    $blocked=Get-Content (Join-Path $ownEvidence autostart-preview-04.private.json) -Raw|ConvertFrom-Json
    Check ($blocked.Status -ceq 'BLOCKED' -and $blocked.Reason -ceq 'AUTOSTART_PREVIEW_POLICY_UNKNOWN' -and $blocked.PublicCallOrdinal -eq 4) ('Blocked actual DTO category retained before veto '+$target.Provider)
    $global:httpInspect.Config.Labels.'sql-server-lab.autostart'='off'
    $null=Write-AutoStartBrowserAcceptanceFile $ownEvidence 'autostart-preview-05.private.json' '{"PreservedOriginal":true}'
    Reject {Send-Observed $body} 'AUTOSTART_HTTP_INVALID' ('Actual evidence CreateNew failure veto '+$target.Provider)
    Check ((Get-Content (Join-Path $ownEvidence autostart-preview-05.private.json) -Raw) -ceq '{"PreservedOriginal":true}' -and
      ($before|ConvertTo-Json -Depth 5 -Compress) -ceq ((Get-PortPreviewAcceptanceFileBinding $scope.DataRoot)|ConvertTo-Json -Depth 5 -Compress)) ('Evidence veto preserves original and runtime state '+$target.Provider)
   }finally{
    # Execute the actual child restoration's module block, not a mirrored reset.
    $final=@($server.FindAll({param($n)$n -is [Management.Automation.Language.TryStatementAst] -and $n.Body.Extent.Text -match 'Start-SqlServerLabUi'},$false))[0].Finally
    $restoreTry=@($final.Statements|Where-Object{$_.Extent.Text -like 'try{& $module *'})[0]
    $restorationErrors=[Collections.Generic.List[object]]::new();. ([scriptblock]::Create($restoreTry.Extent.Text))
    Check ($restorationErrors.Count -eq 0 -and (& $module {param($saved) @($saved.Keys|Where-Object{(Get-Item ('Function:'+$_)).ScriptBlock.ToString() -cne $saved[$_].ToString()}).Count} $original) -eq 0) ('Actual finally restores every function '+$target.Provider)
   }
  }
 }finally{Microsoft.PowerShell.Core\Remove-Module $module -Force}
 # Execute the actual driver with a synthetic Playwright leaf and the ACTUAL
 # product dialog script. No listener, browser executable or network is started.
 $driverSource=Join-Path $root driver.cjs;$driverTest=Join-Path $root driver-check.cjs
 [IO.File]::WriteAllText($driverSource,(Get-AutoStartBrowserDriverSource),[Text.UTF8Encoding]::new($false))
 $driverChecks=@'
'use strict';
const fs=require('node:fs'),vm=require('node:vm'),path=require('node:path');
const repo=process.argv[2],driver=fs.readFileSync(process.argv[3],'utf8');
let checks=0;const check=(v,n)=>{if(!v)throw Error(n);checks++;console.log('PASS: '+n);};
const fixture=fs.readFileSync(path.join(repo,'Tests/Static/Fixtures/ContainerAutoStartPreviewUiChecks.cjs'),'utf8');
const prefix=fixture.slice(0,fixture.indexOf('function setup()'));
const definitions={require,__dirname:path.join(repo,'Tests/Static/Fixtures'),console};
vm.runInNewContext(prefix+'\nglobalThis.makePlan=plan;',definitions);
const dialogSource=fs.readFileSync(path.join(repo,'Ui/container-autostart-preview.js'),'utf8');
const tick=()=>new Promise(resolve=>setImmediate(resolve));
async function scenario(badOriginStatus){
 const c={ListenerPort:19499,BrowserExecutable:'SYNTHETIC_EDGE',PlaywrightDirectory:'SYNTHETIC_PLAYWRIGHT',ResultPath:'SYNTHETIC_RESULT',RunId:'11111111-1111-1111-1111-111111111111'};
 const base='http://127.0.0.1:19499';let handler,closed=0,launched=0,fetches=0,continued=0,aborted=0,report,error='';
 const elements={};for(const id of ['open','dialog','close','read','plan','target','policy','status','result'])elements[id]={events:{},value:'',textContent:'',disabled:false,open:false,children:[],addEventListener(n,f){this.events[n]=f;},replaceChildren(){this.children=[];this.value='';},appendChild(v){this.children.push(v);if(this.children.length===1)this.value=v.value;},showModal(){this.open=true;},close(){this.open=false;}};
 const document={querySelector:s=>elements[s.replace('#autostart-preview-','')],createElement:()=>({})};
 const dom={document,TextEncoder,fetch:(url,options)=>new Promise((resolve,reject)=>{
  const p=JSON.parse(options.body),value=p.Action==='Read'?{ContractVersion:'SqlServerLab.ContainerAutoStartBrowser/1.0',Status:'METADATA_ONLY',Targets:[{RunId:c.RunId,InstanceId:'primary',Provider:'docker'}],CanApply:false,MutationAllowed:false,Actions:[]}:definitions.makePlan('docker',p.AutoStart==='off');
  const actualResponse={ok:true,json:async()=>value};
  const route={request:()=>({url:()=>base+url,method:()=>options.method,postData:()=>options.body}),fetch:async()=>{fetches++;return actualResponse;},fulfill:async arg=>{check(arg.response===actualResponse && Object.keys(arg).join(',')==='response','Driver forwards delayed genuine response handle/body without replacement');resolve(arg.response);},continue:async()=>{continued++;resolve(actualResponse);},abort:async()=>{aborted++;reject(Error('DENIED'));}};
  Promise.resolve(handler(route)).catch(reject);
 })};
 vm.runInNewContext(dialogSource,dom);
 async function wait(condition){for(let i=0;i<100;i++){if(condition())return;await tick();}throw Error('SYNTHETIC_WAIT');}
 const locator=id=>({click:async()=>{elements[id].events.click();await tick();},selectOption:async value=>{elements[id].value=value;},dispatchEvent:async name=>{elements[id].events[name]();await tick();},textContent:async()=>elements[id].textContent,
  locator:()=>({first:()=>({waitFor:async options=>{check(options&&options.state==='attached','Option wait uses DOM attachment, not hidden-option visibility');return wait(()=>elements.target.children.length>0);}}),count:async()=>elements.target.children.length})});
 const page={setDefaultTimeout(){},route:async(pattern,fn)=>{check(pattern==='**/*','Driver intercepts all requests before server work');handler=fn;},locator:s=>locator(s.replace('#autostart-preview-','')),waitForFunction:async fn=>wait(()=>vm.runInNewContext('('+fn.toString()+')()',dom)),goto:async()=>{
  for(const suffix of ['/','/app.js','/api/jobs','/api/workflow-inventory','/api/config']){await handler({request:()=>({url:()=>base+suffix,method:()=> 'GET',postData:()=>null}),continue:async()=>{continued++;},abort:async()=>{aborted++;}});}
  await handler({request:()=>({url:()=> 'https://foreign.invalid/',method:()=> 'GET'}),abort:async()=>{aborted++;}});
 }};
 const context={newPage:async()=>page,request:{post:async(url,args)=>({status:()=>args.headers.Origin===base?400:badOriginStatus}),get:async()=>({status:()=>400})}};
 const leaf={chromium:{launch:async args=>{check(args.executablePath===c.BrowserExecutable&&args.headless&&args.timeout===30000,'Driver uses bound existing browser with one bounded launch');launched++;return{newContext:async args=>{check(args.serviceWorkers==='block','Service workers cannot bypass request filter');return context;},close:async()=>{closed++;}};}}};
 const proc={argv:['node','driver','config'],stderr:{write:v=>{error+=v;}},exitCode:0};
 const fakeFs={readFileSync:()=>JSON.stringify(c),writeFileSync:(name,text,args)=>{check(name===c.ResultPath&&args.flag==='wx','Driver result uses exclusive bound path');report=JSON.parse(text);}};
 await vm.runInNewContext(driver,{require:name=>name==='node:fs'?fakeFs:leaf,process:proc,URL,console});
 check(launched===1&&closed===1,'Driver finally closes its single returned browser on success/failure');
 check(fetches===1&&aborted===4,'Unrelated/external requests denied; one delayed real response fetched');
 if(badOriginStatus===400){check(proc.exitCode===0&&report.PublicPreviewRequests===3&&report.EarlyCancelInvalidPreviewRequests===0&&report.LateRealResponseDisplayVeto&&report.PreviewResponsesStubbed===false,'Actual driver and dialog complete three previews/cancel/late-veto with fixed report');}
 else{check(proc.exitCode===1&&!report&&error==='AUTOSTART_BROWSER_DRIVER_FAILED:INVALID_REQUESTS\n','Unexpected transport acceptance fails closed with fixed stage only');}
}
(async()=>{await scenario(400);await scenario(200);console.log('DRIVER BOUNDARY: '+checks+' PASS; actual driver+actual dialog; synthetic Playwright/HTTP; BrowserStarts0 NetworkStarts0');})().catch(e=>{console.error(e);process.exitCode=1;});
'@
 [IO.File]::WriteAllText($driverTest,$driverChecks,[Text.UTF8Encoding]::new($false))
 $node=Get-Command node -ErrorAction Stop
 & $node.Source $driverTest $repo $driverSource
 Check ($LASTEXITCODE -eq 0) 'Actual driver/dialog synthetic transport characterization passed'
 Write-Host ('BROWSER ACCEPTANCE BOUNDARY: '+$checks+' PASS; 0 FAIL; ServerStarts0 BrowserStarts0 ProviderMutations0')
}finally{Remove-OwnFixtureRoot $root}
