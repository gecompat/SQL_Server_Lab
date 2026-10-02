#Requires -Version 7.2
$ErrorActionPreference='Stop'
$repo=(Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
$root=Join-Path $repo ('.artifacts/evaluation-refresh-browser-fixtures/'+[guid]::NewGuid().ToString('N'))
$checks=0
function Assert-HttpRefresh($value,$label){if(-not$value){throw ('REFRESH_HTTP_CHECK_FAILED: '+$label)};$script:checks++;Write-Host ('PASS: '+$label)}
try {
    # Execute only the existing synthetic metadata arrange, not its test cases.
    $tokens=$null;$parseErrors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'Tests/Static/Invoke-EvaluationRefreshPlanChecks.ps1'),[ref]$tokens,[ref]$parseErrors)
    if($parseErrors.Count){throw 'FIXTURE_PARSE_FAILED'}
    foreach($statement in $ast.EndBlock.Statements){if($statement-is[Management.Automation.Language.FunctionDefinitionAst]){. ([scriptblock]::Create(($statement.Extent.Text-replace'^function ','function script:')))}}
    $try=@($ast.EndBlock.Statements|Where-Object {$_-is[Management.Automation.Language.TryStatementAst]})
    if($try.Count-ne1){throw 'FIXTURE_ARRANGE_SHAPE'}
    $arrange=@();foreach($statement in $try[0].Body.Statements){if($statement.Extent.Text-match'^\$before='){break};$arrange+=$statement.Extent.Text}
    if($arrange.Count-ne19){throw 'FIXTURE_ARRANGE_COUNT'}
    . ([scriptblock]::Create($arrange-join"`n"))
    Import-RefreshFunctions 'Private/EvaluationRefreshPlanConsole.ps1'
    Import-RefreshFunctions 'Private/EvaluationRefreshPlanHttp.ps1'
    $script:actualPublic=${function:Get-SqlServerLabEvaluationRefreshPlan};$script:planCalls=0
    function Get-SqlServerLabEvaluationRefreshPlan {param($RunId,$InstanceId,$DataRoot,$Mode);$script:planCalls++;& $script:actualPublic @PSBoundParameters}
    foreach($forbidden in @('Start-UiBackgroundAction','Invoke-SqlServerLabWorkflowAction','Start-Job','Write-LabEvent')){Set-Item ('Function:script:'+$forbidden) {throw 'FORBIDDEN_REFRESH_HTTP_DISPATCH'}}
    function New-RefreshRequest($payload,$origin='http://localhost:8080',$method='POST',$contentType='application/json'){
        $json=if($payload-is[string]){$payload}else{$payload|ConvertTo-Json -Depth 20 -Compress}
        [pscustomobject]@{HttpMethod=$method;ContentType=$contentType;Headers=@{Origin=$origin};Url=[uri]'http://localhost:8080/api/evaluation-refresh-plan';ContentEncoding=[Text.Encoding]::UTF8;InputStream=[IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes($json))}
    }
    function Invoke-RefreshHttp($payload,$origin='http://localhost:8080',$method='POST',$contentType='application/json'){Invoke-LabEvaluationRefreshHttpRequest -Request (New-RefreshRequest $payload $origin $method $contentType)}
    function Assert-RefreshHttpReject($payload,$label,$origin='http://localhost:8080',$method='POST',$contentType='application/json'){
        $count=$script:planCalls;$code=$null;try{$null=Invoke-RefreshHttp $payload $origin $method $contentType}catch{$code=$_.Exception.Message}
        Assert-HttpRefresh ($code-cin@('EVALUATION_REFRESH_HTTP_INVALID','EVALUATION_REFRESH_BINDING_CHANGED','EVALUATION_REFRESH_SCOPE_UNSUPPORTED','EVALUATION_REFRESH_BINDING_INVALID','EVALUATION_REFRESH_BINDING_UNAVAILABLE')-and$script:planCalls-eq$count) $label
    }
    $before=Get-RefreshHashes
    $view=Invoke-RefreshHttp @{Action='Read';DataRoot=$root}
    Assert-HttpRefresh ($view.Runs.Count-eq1-and$planCalls-eq0-and$view.Actions.Count-eq0-and-not$view.MutationAllowed) 'Actual HTTP metadata uses D reader without plan/job dispatch'
    Assert-HttpRefresh (-not(($view|ConvertTo-Json -Depth 12)-match'CANARY_PRIVATE|vmId|vmName|DataRoot|StateRoot')-and-not($view|ConvertTo-Json -Depth 12).Contains($root)) 'Metadata excludes raw root VM endpoints and evidence'
    $selection=$view.Runs[0]
    foreach($mode in @('FREE_SLOT_REPLACEMENT','RECONSTRUCT_LAB','STATEFUL_MIGRATION')){
        $prior=$planCalls;$plan=Invoke-RefreshHttp @{Action='Preview';DataRoot=$root;Selection=$selection;Mode=$mode}
        Assert-HttpRefresh ($planCalls-eq$prior+1-and$plan.Mode-ceq$mode-and$plan.Status-ceq'BLOCKED'-and$plan.Actions.Count-eq0-and-not$plan.ExecutionSupported-and-not$plan.MutationAllowed-and$plan.TransferAuthority-ceq'NONE') ('Actual HTTP to public/core '+$mode)
        Assert-HttpRefresh ($plan.Evaluations[0].EvidenceStatus-ceq'HISTORICAL_METADATA'-and$plan.Evaluations[1].EvidenceStatus-ceq'EVIDENCE_MISSING'-and$plan.SqlReadiness-ceq'NOT_CHECKED'-and-not$plan.FreshWindowsLicenseProof) ('Separate Windows SQL sources '+$mode)
    }
    $request=@{Action='Preview';DataRoot=$root;Selection=$selection;Mode='STATEFUL_MIGRATION'}
    $evidence=@{Contract=@{Name='SqlServerLab.SqlGuestEvaluationEvidence';Version='1.0'};EvidenceId=[guid]::NewGuid().ToString('D');RunId=$runId;ScopeId=$scope;InstanceId='primary';Provider='hyperv';VmId=$connection.instances[0].vmId;ImageArtifactId=$run.metadata.imageArtifactId;SqlInstanceName='MSSQLSERVER';SqlMajorVersion=17;SqlEdition='Enterprise Evaluation Edition';ObservedAt=[datetime]::UtcNow.AddMinutes(-5).ToString('o');EvidenceFreshUntil=[datetime]::UtcNow.AddHours(12).ToString('o');LicenseClassification='EVALUATION';DeadlineSource='SQL_GUEST_OBSERVED';ObservationStatus='CAPTURED';EvaluationExpiresAt=[datetime]::UtcNow.AddDays(3).ToString('o');PreviousEvidenceId=$null}
    $guestPath=Join-Path $runDirectory sql-guest-evaluation-evidence.json;Write-Refresh $guestPath $evidence
    $selectedNow=(Invoke-RefreshHttp @{Action='Read';DataRoot=$root}).Runs[0]
    $current=Invoke-RefreshHttp @{Action='Preview';DataRoot=$root;Selection=$selectedNow;Mode='STATEFUL_MIGRATION'}
    Assert-HttpRefresh ($current.Evaluations[1].EvidenceStatus-ceq'CURRENT'-and$current.SqlReadiness-ceq'NOT_CHECKED'-and$current.Status-ceq'BLOCKED') 'Actual guest receipt current is not SQL readiness or migration authority'
    $evidence.EvidenceFreshUntil=[datetime]::UtcNow.AddMinutes(-1).ToString('o');Write-Refresh $guestPath $evidence
    $selectedNow=(Invoke-RefreshHttp @{Action='Read';DataRoot=$root}).Runs[0]
    $stale=Invoke-RefreshHttp @{Action='Preview';DataRoot=$root;Selection=$selectedNow;Mode='STATEFUL_MIGRATION'}
    Assert-HttpRefresh ($stale.Evaluations[1].EvidenceStatus-ceq'EVIDENCE_STALE'-and$stale.Evaluations[1].Status-ceq'UNKNOWN'-and$null-eq$stale.Evaluations[1].EvaluationExpiresAt) 'Actual stale SQL evidence remains unknown in browser projection'
    Remove-Item -LiteralPath $guestPath -Force
    Assert-RefreshHttpReject @{Action='Read';DataRoot=$root;StateRoot=$stateRoot} 'Unknown field rejected before any core dispatch'
    Assert-RefreshHttpReject @{Action='Read';DataRoot=$root} 'Foreign Origin rejected' 'http://foreign.invalid'
    Assert-RefreshHttpReject @{Action='Read';DataRoot=$root} 'GET rejected' '' GET
    Assert-RefreshHttpReject @{Action='Read';DataRoot=$root} 'Wrong content type rejected' '' POST text/plain
    foreach($bad in @('[]','{"Action":"Read","action":"Read","DataRoot":"x"}','{"Action":"Read","DataRoot":"x","DataRoot":"y"}',(' '*16385),('{"Action":"Read","DataRoot":'+('['*13)+'0'+(']'*13)+'}'),('{"Action":"Read","DataRoot":"x","Extra":['+((1..260)-join',')+']}'))){Assert-RefreshHttpReject $bad 'Bounded shape/duplicate/depth/nodes/size rejection'}
    $changed=$selection|ConvertTo-Json|ConvertFrom-Json;$changed.Digest='b'*64
    Assert-RefreshHttpReject @{Action='Preview';DataRoot=$root;Selection=$changed;Mode='STATEFUL_MIGRATION'} 'Selection digest drift rejected before public plan'
    $changed.ScopeId=[guid]::NewGuid().ToString('D')
    Assert-RefreshHttpReject @{Action='Preview';DataRoot=$root;Selection=$changed;Mode='STATEFUL_MIGRATION'} 'Foreign selected scope rejected'
    Assert-RefreshHttpReject @{Action='Preview';DataRoot=$root;Selection=$selection;Mode='stateful_migration'} 'Noncanonical mode rejected'
    $badId=$selection|ConvertTo-Json|ConvertFrom-Json;$badId.RunId=@($selection.RunId)
    Assert-RefreshHttpReject @{Action='Preview';DataRoot=$root;Selection=$badId;Mode='STATEFUL_MIGRATION'} 'Array identity rejected before coercion'
    $script:realReader=${function:Read-LabEvaluationRefreshSnapshot};$script:readCount=0
    function Read-LabEvaluationRefreshSnapshot {param($RunId,$InstanceId,$DataRoot);$snapshot=& $script:realReader @PSBoundParameters;if(++$script:readCount-eq2){$script:run.state='STOPPED';Write-Refresh $script:runPath $script:run};$snapshot}
    $code=$null;try{$null=Invoke-RefreshHttp $request}catch{$code=$_.Exception.Message}
    Assert-HttpRefresh ($code-ceq'EVALUATION_REFRESH_BINDING_CHANGED'-and$readCount-eq3) 'Actual public double observation rejects drift after HTTP revalidation'
    Set-Item Function:Read-LabEvaluationRefreshSnapshot $script:realReader
    $run.state='RUNNING';Write-Refresh $runPath $run
    $run.state='RECOVERY_REQUIRED';Write-Refresh $runPath $run
    Assert-RefreshHttpReject $request 'Recovery state blocks public dispatch'
    $run.state='RUNNING';Write-Refresh $runPath $run
    $marker=Join-Path $root '.sql-server-lab-root.json';$saved=[IO.File]::ReadAllText($marker);$object=$saved|ConvertFrom-Json;$object.ControllerId=[guid]::NewGuid().ToString('D');Write-Refresh $marker $object
    Assert-RefreshHttpReject $request 'Foreign controller rejected by actual registered reader'
    [IO.File]::WriteAllText($marker,$saved,[Text.UTF8Encoding]::new($false))
    $savedPublic=${function:Get-SqlServerLabEvaluationRefreshPlan}
    function Get-SqlServerLabEvaluationRefreshPlan {param($RunId,$InstanceId,$DataRoot,$Mode);$p=& $script:actualPublic @PSBoundParameters;$p.Evaluations[0].DeadlineSource='PRIVATE_HOST_SECRET_CANARY';$p}
    Assert-RefreshHttpReject $request 'Projection rejects unknown caller-text evidence codes'
    Set-Item Function:Get-SqlServerLabEvaluationRefreshPlan $savedPublic
    $extra=@();try{foreach($i in 1..64){$directory=Join-Path (Split-Path $runDirectory) ('extra-'+$i);$null=New-Item -ItemType Directory $directory;$extra+=$directory};Assert-RefreshHttpReject @{Action='Read';DataRoot=$root} 'HTTP canonical enumerator rejects more than 64 directories'}finally{foreach($directory in $extra){Remove-Item -LiteralPath $directory -Force}}
    Assert-HttpRefresh ((Get-RefreshHashes)-ceq$before) 'Actual HTTP composition writes no registered metadata'
    # Execute the exact dedicated server branch with only module/response leaves isolated.
    $server=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'Tools/Start-SqlServerLabUi.ps1'),[ref]$tokens,[ref]$parseErrors)
    $routes=@($server.FindAll({param($node)$node-is[Management.Automation.Language.IfStatementAst]-and$node.Clauses[0].Item1.Extent.Text-ceq"`$path -eq '/api/evaluation-refresh-plan'"},$true))
    if($parseErrors.Count-or$routes.Count-ne1){throw 'FIXTURE_ROUTE_BOUNDARY_INVALID'}
    function Get-Module {param($Name);if($Name-cne'SqlServerLab'){throw 'FORBIDDEN_MODULE'};return {param($moduleScript,$moduleRequest)& $moduleScript $moduleRequest}}
    function Write-UiResponse {param($Context,$Body,$ContentType,$StatusCode=200);$script:httpResponse=[pscustomobject]@{Body=$Body;StatusCode=$StatusCode}}
    $path='/api/evaluation-refresh-plan';$context=[pscustomobject]@{Request=New-RefreshRequest @{Action='Read';DataRoot=$root}};$prior=$planCalls
    . ([scriptblock]::Create('foreach($routeIteration in @(1)){'+$routes[0].Extent.Text+'}'))
    Assert-HttpRefresh ($httpResponse.StatusCode-eq200-and($httpResponse.Body|ConvertFrom-Json).Status-ceq'METADATA_ONLY'-and$planCalls-eq$prior) 'Actual route delegates metadata with zero job or plan'
    $context.Request=New-RefreshRequest '{"Action":"Read","DataRoot":"PRIVATE_PATH_CANARY"}'
    . ([scriptblock]::Create('foreach($routeIteration in @(1)){'+$routes[0].Extent.Text+'}'))
    Assert-HttpRefresh ($httpResponse.StatusCode-eq400-and($httpResponse.Body|ConvertFrom-Json).Code-ceq'EVALUATION_REFRESH_BINDING_UNAVAILABLE'-and-not$httpResponse.Body.Contains('PRIVATE_PATH_CANARY')) 'Actual route catch returns fixed safe error'
    Write-Host ('EVALUATION_REFRESH_HTTP_CHECKS: '+$checks+' PASS; 0 FAIL')
}finally{
    $resolved=[IO.Path]::GetFullPath($root);$expected=[IO.Path]::GetFullPath((Join-Path $repo '.artifacts/evaluation-refresh-browser-fixtures'))
    if(-not$resolved.StartsWith($expected+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)-or[IO.Path]::GetFileName($resolved)-notmatch'^[a-f0-9]{32}$'){throw 'FIXTURE_CLEANUP_SCOPE'}
    if(Test-Path -LiteralPath $resolved){Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction Stop}
}
