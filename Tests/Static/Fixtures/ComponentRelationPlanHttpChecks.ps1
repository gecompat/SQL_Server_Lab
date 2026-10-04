#Requires -Version 7.2
[CmdletBinding()]param()
$ErrorActionPreference='Stop'
# Reuse the existing registered synthetic metadata producer, stopping before its tests.
$setupPath=Join-Path $PSScriptRoot 'ComponentRelationPlanConsoleChecks.ps1'
$setup=[IO.File]::ReadAllText($setupPath)
$end=$setup.IndexOf('    $before=Get-ConsoleFileBinding',[StringComparison]::Ordinal)
if($end -lt 0 -or $setup.IndexOf('    $before=Get-ConsoleFileBinding',$end+1,[StringComparison]::Ordinal)-ge0){throw 'FIXTURE_SETUP_BOUNDARY_INVALID'}
$httpRepo=(Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
$prefix=$setup.Substring(0,$end).Replace("`$repo=(Resolve-Path (Join-Path `$PSScriptRoot '../../..')).Path",'$repo=$httpRepo')
. ([scriptblock]::Create($prefix+'} finally {}'))
try {
    Import-ConsolePlanFunctions Private/ComponentRelationPlanHttp.ps1
    $script:planCalls=0
    function Invoke-HttpFixture($payload,$origin='http://localhost:8080',$method='POST') {
        $json=if($payload -is [string]){$payload}else{$payload|ConvertTo-Json -Depth 12 -Compress}
        $request=[pscustomobject]@{HttpMethod=$method;ContentType='application/json';Headers=@{Origin=$origin};Url=[uri]'http://localhost:8080/api/component-relations';
            ContentEncoding=[Text.Encoding]::UTF8;InputStream=[IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes($json))}
        Invoke-LabComponentRelationHttpRequest -Request $request
    }
    function Assert-HttpReject($payload,$name,$origin='http://localhost:8080',$method='POST') {
        $beforeCalls=$script:planCalls;$code=$null
        try{$null=Invoke-HttpFixture $payload $origin $method}catch{$code=$_.Exception.Message}
        Assert-ConsolePlan ($code-cin@('COMPONENT_RELATION_HTTP_INVALID','COMPONENT_RELATION_BINDING_CHANGED','COMPONENT_RELATION_SCOPE_UNSUPPORTED','COMPONENT_RELATION_INPUT_INVALID','COMPONENT_RELATION_TARGET_INVALID','COMPONENT_RELATION_CYCLE','COMPONENT_RELATION_BINDING_UNAVAILABLE')) $name
        return $script:planCalls-$beforeCalls
    }
    $before=Get-ConsoleFileBinding
    $view=Invoke-HttpFixture @{Action='Read';DataRoot=$dataRoot}
    Assert-ConsolePlan ($view.Runs.Count-eq2-and$planCalls-eq0-and$view.SqlReadiness-ceq'NOT_CHECKED') 'Actual HTTP metadata uses registered reader with zero plan dispatch'
    Assert-ConsolePlan (($view|ConvertTo-Json -Depth 12)-notmatch'SYNTHETIC_PRIVATE_CONTAINER|127\.0\.0\.1|14330'-and-not($view|ConvertTo-Json -Depth 12).Contains($fixture)) 'Metadata response excludes endpoint/native/root fields'
    $bindings=@($view.Runs|ForEach-Object{[ordered]@{RunId=$_.RunId;ScopeId=$_.ScopeId;Digest=$_.Digest;State=$_.State}})
    $ownSelection=@($bindings|Where-Object RunId -CEQ $ownId)[0]
    $relation=@{SourceInstanceId='consumer';Type='requires-sql';Target=@{RunId=$sharedId;ScopeId=$sharedScope;InstanceId='sharedSql';ManagementMode='EXTERNAL_READ_ONLY'}}
    $request=@{Action='Preview';DataRoot=$dataRoot;RunId=$ownId;Bindings=$bindings;ProposedRelations=@($relation)}
    $result=Invoke-HttpFixture $request
    Assert-ConsolePlan ($planCalls-eq1-and$result.Status-ceq'BLOCKED_SQL_READINESS_NOT_CHECKED'-and$result.Actions.Count-eq0-and-not$result.MutationAllowed-and-not$result.ExecutionSupported-and$result.SharedRemovalPolicy-ceq'PRESERVE') 'Actual HTTP preview reaches public pure core with shared preserve and no SQL probe'
    Assert-ConsolePlan ($before-ceq(Get-ConsoleFileBinding)) 'HTTP metadata/preview preserve registered files byte-for-byte'
    $empty=@{Action='Preview';DataRoot=$dataRoot;RunId=$ownId;Bindings=@($ownSelection);ProposedRelations=@()}
    Assert-ConsolePlan ((Invoke-HttpFixture $empty).Status-ceq'NO_RELATION_CHANGE') 'Explicit empty relations remain plan-only'
    foreach($invalid in @(@{Action='Read';DataRoot=$dataRoot;StateRoot='PRIVATE_CANARY'},@{Action='Read';DataRoot=(Join-Path $fixture 'foreign')},@{Action='Read';DataRoot=$dataRoot;Secret='PRIVATE_CANARY'})){
        Assert-ConsolePlan ((Assert-HttpReject $invalid 'Foreign root/extra parameter rejected')-eq0) 'Invalid HTTP input dispatches no plan'
    }
    Assert-ConsolePlan ((Assert-HttpReject @{Action='Read';DataRoot=$dataRoot} 'Foreign origin rejected' 'http://foreign.invalid')-eq0) 'Origin veto precedes metadata observation'
    Assert-ConsolePlan ((Assert-HttpReject @{Action='Read';DataRoot=$dataRoot} 'GET rejected' 'http://localhost:8080' 'GET')-eq0) 'GET cannot observe or dispatch'
    $duplicate='{"Action":"Read","Action":"Preview","DataRoot":"PRIVATE_CANARY"}'
    Assert-ConsolePlan ((Assert-HttpReject $duplicate 'Duplicate JSON keys rejected')-eq0) 'Duplicate input dispatch zero'
    Assert-ConsolePlan ((Assert-HttpReject ('x'*16385) 'Oversized body rejected')-eq0) 'Body bound precedes dispatch'
    $copy=$request|ConvertTo-Json -Depth 12|ConvertFrom-Json -Depth 12;$copy.Bindings[0].ScopeId='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
    Assert-ConsolePlan ((Assert-HttpReject $copy 'Selected scope drift rejected')-eq0) 'Scope drift dispatch zero'
    $runPath=Join-Path $stateRoot ('runs/'+$ownId+'/run-state.json');$original=[IO.File]::ReadAllText($runPath)
    $run=$original|ConvertFrom-Json -Depth 64;$run.state='STOPPED';Write-ConsolePlanJson $runPath $run
    Assert-ConsolePlan ((Assert-HttpReject $request 'Selected lifecycle drift rejected')-eq0) 'State drift dispatch zero'
    [IO.File]::WriteAllText($runPath,$original,[Text.UTF8Encoding]::new($false))
    $cycle=@{Action='Preview';DataRoot=$dataRoot;RunId=$ownId;Bindings=@($ownSelection);ProposedRelations=@(
        @{SourceInstanceId='consumer';Type='requires-sql';Target=@{RunId=$ownId;ScopeId=$ownScope;InstanceId='prerequisite';ManagementMode='PROVISIONED'}},
        @{SourceInstanceId='prerequisite';Type='requires-sql';Target=@{RunId=$ownId;ScopeId=$ownScope;InstanceId='consumer';ManagementMode='PROVISIONED'}})}
    Assert-ConsolePlan ((Assert-HttpReject $cycle 'Actual core cycle rejected')-eq1) 'Cycle reaches only public plan, never executor'
    $run=$original|ConvertFrom-Json -Depth 64;$run.state='RECOVERY_REQUIRED';Write-ConsolePlanJson $runPath $run
    $recovery=Invoke-HttpFixture @{Action='Read';DataRoot=$dataRoot};$selection=@($recovery.Runs|Where-Object RunId -CEQ $ownId)[0]
    $recoveryPlan=Invoke-HttpFixture @{Action='Preview';DataRoot=$dataRoot;RunId=$ownId;Bindings=@(@{RunId=$selection.RunId;ScopeId=$selection.ScopeId;State=$selection.State;Digest=$selection.Digest});ProposedRelations=@()}
    Assert-ConsolePlan ($recoveryPlan.Status-ceq'BLOCKED_COMPONENT_RECOVERY_REQUIRED'-and$recoveryPlan.Actions.Count-eq0) 'Current recovery produces blocked plan, never ready'
    [IO.File]::WriteAllText($runPath,$original,[Text.UTF8Encoding]::new($false))
    $tooMany=$request|ConvertTo-Json -Depth 12|ConvertFrom-Json -Depth 12;$tooMany.ProposedRelations=@($relation,$relation,$relation,$relation,$relation)
    Assert-ConsolePlan ((Assert-HttpReject $tooMany 'Relation cardinality bounded before plan')-eq0) 'Five relations dispatch zero'
    $missing=$request|ConvertTo-Json -Depth 12|ConvertFrom-Json -Depth 12;$missing.Bindings=@($ownSelection)
    Assert-ConsolePlan ((Assert-HttpReject $missing 'Missing shared selection binding rejected')-eq0) 'Shared authority cannot be inferred from caller target'
    $markerPath=Join-Path $dataRoot '.sql-server-lab-root.json';$markerText=[IO.File]::ReadAllText($markerPath)
    $marker=$markerText|ConvertFrom-Json;$marker.ControllerId='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';Write-ConsolePlanJson $markerPath $marker
    Assert-ConsolePlan ((Invoke-HttpFixture @{Action='Read';DataRoot=$dataRoot}).Runs.Count-eq0) 'Controller mismatch offers no selectable authority'
    Assert-ConsolePlan ((Assert-HttpReject $request 'Controller mismatch blocks direct preview')-eq0) 'Controller mismatch dispatch zero'
    [IO.File]::WriteAllText($markerPath,$markerText,[Text.UTF8Encoding]::new($false))
    $threeId='77777777-7777-4777-8777-777777777777';Write-ConsoleRun $threeId '88888888-8888-4888-8888-888888888888' @($instances+@{Id='third';Provider='docker';Version='2025'})
    Assert-ConsolePlan ($threeId-cnotin@(Invoke-HttpFixture @{Action='Read';DataRoot=$dataRoot}).Runs.RunId) 'Three-target run excluded by actual metadata authority'
    # Execute the exact production route, replacing only its module/HTTP transport leaves.
    $tokens=$null;$parseErrors=$null;$server=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'Tools/Start-SqlServerLabUi.ps1'),[ref]$tokens,[ref]$parseErrors)
    $route=@($server.FindAll({param($n)$n -is [Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text -ceq "`$path -eq '/api/component-relations'"},$true))
    if($parseErrors.Count-or$route.Count-ne1){throw 'FIXTURE_ROUTE_BOUNDARY_INVALID'}
    function Get-Module {param($Name);if($Name-cne'SqlServerLab'){throw 'FORBIDDEN_MODULE'};return {param($moduleScript,$moduleRequest)& $moduleScript $moduleRequest}}
    function Write-UiResponse {param($Context,$Body,$ContentType,$StatusCode=200);$script:httpResponse=[pscustomobject]@{Body=$Body;StatusCode=$StatusCode}}
    $stream=[IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes((@{Action='Read';DataRoot=$dataRoot}|ConvertTo-Json -Compress)))
    $context=[pscustomobject]@{Request=[pscustomobject]@{HttpMethod='POST';ContentType='application/json';Headers=@{};Url=[uri]'http://localhost:8080/api/component-relations';ContentEncoding=[Text.Encoding]::UTF8;InputStream=$stream}}
    $path='/api/component-relations';$prior=$planCalls
    . ([scriptblock]::Create('foreach($routeIteration in @(1)){'+$route[0].Extent.Text+'}'))
    $body=$httpResponse.Body|ConvertFrom-Json -Depth 12
    Assert-ConsolePlan ($httpResponse.StatusCode-eq200-and$body.Status-ceq'METADATA_ONLY'-and$planCalls-eq$prior) 'Actual dedicated server route reaches metadata helper without job/plan dispatch'
    $context.Request.InputStream=[IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes('{"Action":"Read","DataRoot":"PRIVATE_PATH_CANARY"}'))
    . ([scriptblock]::Create('foreach($routeIteration in @(1)){'+$route[0].Extent.Text+'}'))
    Assert-ConsolePlan ($httpResponse.StatusCode-eq400-and($httpResponse.Body|ConvertFrom-Json).Code-ceq'COMPONENT_RELATION_BINDING_UNAVAILABLE'-and-not$httpResponse.Body.Contains('PRIVATE_PATH_CANARY')) 'Actual route error catch emits fixed code without private path'
    Write-Host ('COMPONENT_RELATION_HTTP_CHECKS: '+$checks+' PASS; 0 FAIL')
} finally {
    $resolved=[IO.Path]::GetFullPath($fixture);$expected=Join-Path $repo '.artifacts/component-relation-console'
    if($resolved.StartsWith($expected+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)-and[IO.Directory]::Exists($resolved)){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
