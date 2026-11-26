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
    function Get-SqlServerLabEvaluationRefreshPlan {param($RunId,$InstanceId,$DataRoot,$Mode,$TargetRunId,$TargetInstanceId);$script:planCalls++;& $script:actualPublic @PSBoundParameters}
    foreach($forbidden in @('Start-UiBackgroundAction','Invoke-SqlServerLabWorkflowAction','Start-Job','Write-LabEvent')){Set-Item ('Function:script:'+$forbidden) {throw 'FORBIDDEN_REFRESH_HTTP_DISPATCH'}}
    function New-RefreshRequest($payload,$origin='http://localhost:8080',$method='POST',$contentType='application/json'){
        $json=if($payload-is[string]){$payload}else{$payload|ConvertTo-Json -Depth 20 -Compress}
        [pscustomobject]@{HttpMethod=$method;ContentType=$contentType;Headers=@{Origin=$origin};Url=[uri]'http://localhost:8080/api/evaluation-refresh-plan';ContentEncoding=[Text.Encoding]::UTF8;InputStream=[IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes($json))}
    }
    function Invoke-RefreshHttp($payload,$origin='http://localhost:8080',$method='POST',$contentType='application/json'){Invoke-LabEvaluationRefreshHttpRequest -Request (New-RefreshRequest $payload $origin $method $contentType)}
    function Assert-RefreshHttpReject($payload,$label,$origin='http://localhost:8080',$method='POST',$contentType='application/json'){
        $count=$script:planCalls;$code=$null;try{$null=Invoke-RefreshHttp $payload $origin $method $contentType}catch{$code=$_.Exception.Message}
        Assert-HttpRefresh ($code-cin@('EVALUATION_REFRESH_HTTP_INVALID','EVALUATION_REFRESH_BINDING_CHANGED','EVALUATION_REFRESH_SCOPE_UNSUPPORTED','EVALUATION_REFRESH_BINDING_INVALID','EVALUATION_REFRESH_BINDING_UNAVAILABLE','EVALUATION_REFRESH_TARGET_SELECTION_INVALID')-and$script:planCalls-eq$count) $label
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
    $targetFixture=New-RefreshTargetFixture $root $run $connection
    $beforeTargets=Get-RefreshHashes
    $pairView=Invoke-RefreshHttp @{Action='Read';DataRoot=$root}
    $sourceSelection=$pairView.Runs | Where-Object RunId -CEQ $runId
    $targetSelection=$pairView.Runs | Where-Object RunId -CEQ $targetFixture.RunId
    $targetRequest=@{Action='Preview';DataRoot=$root;Selection=$sourceSelection;Target=$targetSelection;Mode='STATEFUL_MIGRATION'}
    $targetPlan=Invoke-RefreshHttp $targetRequest
    Assert-HttpRefresh ($targetPlan.Status -ceq 'BLOCKED' -and $targetPlan.TargetAssessment.RunId -ceq $targetFixture.RunId -and
        $targetPlan.TargetAssessment.ObservedContentSha256 -ceq $targetSelection.Digest -and
        $targetPlan.TargetAssessment.RegisteredState -ceq 'STOPPED' -and $targetPlan.TransferAuthority -ceq 'NONE' -and
        ($targetPlan | ConvertTo-Json -Depth 12) -cnotmatch 'CANARY_PRIVATE|vmId|vmName') 'Browser projection returns only the explicit bound target metadata'
    $targetRequest.Target=$sourceSelection
    Assert-RefreshHttpReject $targetRequest 'Identical source and target are rejected before plan dispatch'
    $targetRequest.Target=$targetSelection | ConvertTo-Json | ConvertFrom-Json
    $targetRequest.Target.Digest='0'*64
    Assert-RefreshHttpReject $targetRequest 'Target digest change is rejected before plan dispatch'
    $targetRequest.Mode='RECONSTRUCT_LAB'
    Assert-RefreshHttpReject $targetRequest 'Target field is forbidden outside stateful migration'
    Assert-HttpRefresh ((Get-RefreshHashes)-ceq$beforeTargets) 'Target preview leaves source and target metadata unchanged'
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
    $actionRoute = $server.Find({
        param($node)
        $node -is [Management.Automation.Language.IfStatementAst] -and
        $node.Clauses[0].Item1.Extent.Text -ceq '$path -eq ''/api/actions'' -and $context.Request.HttpMethod -eq ''POST'''
    }, $true)
    $actionHandler = [scriptblock]::Create('foreach ($once in @(1)) ' + $actionRoute.Clauses[0].Item2.Extent.Text)
    & {
        $jobs = @{}
        foreach ($case in @(
            @{ Action='ReadHyperVEvaluationSqlSource'; Target=$false },
            @{ Action='ReadHyperVEvaluationWindowsLicense'; Target=$false },
            @{ Action='ReadHyperVEvaluationWindowsLicense'; Target=$true },
            @{ Action='ReadHyperVEvaluationTargetSqlReadiness'; Target=$true },
            @{ Action='ReadHyperVEvaluationTargetStorage'; Target=$true },
            @{ Action='ReadHyperVEvaluationFileAllocationComparison'; Target=$true }
        )) {
            $jobs.Clear()
            $actionName = $case.Action
            $parameters = @{ RunId=$selection.RunId; InstanceId=$selection.InstanceId; DataRoot=$root; ExpectedPlanKey=$selection.Digest }
            if ($case.Target) {
                $parameters.TargetRunId = $targetSelection.RunId
                $parameters.TargetInstanceId = $targetSelection.InstanceId
                $parameters.ExpectedTargetPlanKey = $targetSelection.Digest
            }
            $expectedCount = $parameters.Count
            $requestJson = @{ action=$actionName; parameters=$parameters } | ConvertTo-Json -Depth 5 -Compress
            function Read-UiJsonRequestBody { param($Request) @{ Allowed=$true; Body=$requestJson } }
            function New-SqlServerLabBatch { throw 'READ_ONLY_ACTION_CREATED_PERSISTENT_BATCH' }
            function Start-UiWorkflowJob {
                param($Action,$Parameters)
                if ($Action -cne $actionName -or $Parameters.Count -ne $expectedCount -or $Parameters.ExpectedPlanKey -cne $selection.Digest -or
                    $Parameters.RunId -cne $selection.RunId -or ($case.Target -and ($Parameters.TargetRunId -cne $targetSelection.RunId -or
                    $Parameters.TargetInstanceId -cne $targetSelection.InstanceId -or $Parameters.ExpectedTargetPlanKey -cne $targetSelection.Digest))) {
                    throw 'UNEXPECTED_EVALUATION_JOB'
                }
                [pscustomobject]@{ Id='synthetic-source'; Action=$Action; Job=[pscustomobject]@{ State='Running' } }
            }
            & $actionHandler
            Assert-HttpRefresh ($httpResponse.StatusCode -eq 202 -and ($httpResponse.Body | ConvertFrom-Json).id -ceq 'synthetic-source' -and $jobs.Count -eq 1) ('Bound read starts a single transient job, target='+$case.Target)
            $busy = $false
            $expectedBusy = switch -CaseSensitive ($actionName) {
                'ReadHyperVEvaluationSqlSource' { 'EVALUATION_REFRESH_SQL_SOURCE_ALREADY_RUNNING' }
                'ReadHyperVEvaluationTargetSqlReadiness' { 'EVALUATION_REFRESH_TARGET_SQL_ALREADY_RUNNING' }
                'ReadHyperVEvaluationTargetStorage' { 'EVALUATION_REFRESH_TARGET_STORAGE_ALREADY_RUNNING' }
                'ReadHyperVEvaluationFileAllocationComparison' { 'EVALUATION_REFRESH_FILE_ALLOCATION_ALREADY_RUNNING' }
                default { 'EVALUATION_REFRESH_WINDOWS_READ_ALREADY_RUNNING' }
            }
            try { & $actionHandler } catch { $busy = $_.Exception.Message -ceq $expectedBusy }
            Assert-HttpRefresh $busy 'Concurrent source observation is rejected before dispatch'
            $parameters.StateRoot = 'synthetic-foreign'
            $requestJson = @{ action=$actionName; parameters=$parameters } | ConvertTo-Json -Depth 5 -Compress
            $invalid = $false
            try { & $actionHandler } catch { $invalid = $_.Exception.Message -ceq 'EVALUATION_REFRESH_INPUT_INVALID' }
            Assert-HttpRefresh $invalid 'The source job rejects additional root fields before dispatch'
            $parameters.Remove('StateRoot')
            if ($case.Target) {
                $parameters.Remove('ExpectedTargetPlanKey')
                $requestJson = @{ action=$actionName; parameters=$parameters } | ConvertTo-Json -Depth 5 -Compress
                $invalid = $false
                try { & $actionHandler } catch { $invalid = $_.Exception.Message -ceq 'EVALUATION_REFRESH_INPUT_INVALID' }
                Assert-HttpRefresh $invalid 'Incomplete target payload cannot start a license read'
            }
        }
    }
    $formatter = $server.Find({
        param($node)
        $node -is [Management.Automation.Language.IfStatementAst] -and
        $node.Clauses[0].Item1.Extent.Text -ceq '$JobAction -ceq ''ReadHyperVEvaluationSqlSource'''
    }, $true)
    $formatBody = $formatter.Clauses[0].Item2.Extent.Text
    $result = [pscustomobject]@{ Result=[pscustomobject]@{
        Status='PARTIALLY_OBSERVED'
        Items=@([pscustomobject]@{Category='Credentials';Count=[long]1})
        AllocatedFileStorage=[pscustomobject]@{Status='OBSERVED';DataBytes=[long]1048576;LogBytes=[long]262144;Private='SYNTHETIC_PRIVATE'}
        DependencyFindings=@([pscustomobject]@{Category='Credentials';Count=[long]1;Code='CREDENTIAL_REBIND_REQUIRED';Private='SYNTHETIC_PRIVATE'})
    }}
    $lines = & ([scriptblock]::Create($formatBody.Substring(1, $formatBody.Length-2)))
    Assert-HttpRefresh (($lines -join ' ') -cmatch 'CREDENTIAL_REBIND_REQUIRED' -and
        ($lines -join ' ') -cmatch 'Daten: 1048576 Bytes · Log: 262144 Bytes' -and
        ($lines -join ' ') -cnotmatch 'SYNTHETIC_PRIVATE') 'Actual transient job format exposes fixed dependency fields and aggregate byte totals'
    $result.Result.AllocatedFileStorage = [pscustomobject]@{Status='NOT_OBSERVED';DataBytes=$null;LogBytes=$null}
    $lines = & ([scriptblock]::Create($formatBody.Substring(1, $formatBody.Length-2)))
    Assert-HttpRefresh (($lines -join ' ') -cmatch 'SQL-Quelldateigrößen konnten nicht bestimmt werden' -and
        ($lines -join ' ') -cnotmatch 'Daten:.*Bytes') 'Unknown file size is not formatted as observed zero'
    $windowsFormatter = $server.Find({
        param($node)
        $node -is [Management.Automation.Language.IfStatementAst] -and
        $node.Clauses[0].Item1.Extent.Text -ceq '$JobAction -ceq ''ReadHyperVEvaluationWindowsLicense'''
    }, $true)
    $windowsBody = $windowsFormatter.Clauses[0].Item2.Extent.Text
    $result = [pscustomobject]@{Result=[pscustomobject]@{
        TargetRunId=$targetSelection.RunId; TargetInstanceId=$targetSelection.InstanceId
        WindowsLicenseObservation=[pscustomobject]@{Status='OBSERVED';LicenseState='LICENSED';ObservedAt='2030-01-01T00:00:00.0000000Z';EvaluationExpiresAt=$null;Private='SYNTHETIC_PRIVATE'}
    }}
    $lines = & ([scriptblock]::Create($windowsBody.Substring(1,$windowsBody.Length-2)))
    Assert-HttpRefresh (($lines -join ' ') -clike ('*Ziellab '+$targetSelection.RunId+'*LICENSED*') -and
        ($lines -join ' ') -cnotmatch 'SYNTHETIC_PRIVATE') 'Actual job formatter identifies the destination and confines the license fields'
    $sqlFormatter = $server.Find({
        param($node)
        $node -is [Management.Automation.Language.IfStatementAst] -and
        $node.Clauses[0].Item1.Extent.Text -ceq '$JobAction -ceq ''ReadHyperVEvaluationTargetSqlReadiness'''
    }, $true)
    $sqlBody = $sqlFormatter.Clauses[0].Item2.Extent.Text
    $result = [pscustomobject]@{Result=[pscustomobject]@{
        TargetRunId=$targetSelection.RunId; TargetInstanceId=$targetSelection.InstanceId
        SqlReadinessObservation=[pscustomobject]@{Status='OBSERVED';ObservedAt='2030-01-01T00:00:00.0000000Z';Private='SYNTHETIC_PRIVATE'}
        SqlEditionObservation=[pscustomobject]@{Status='OBSERVED';Classification='EVALUATION';EvaluationDeadlineStatus='NOT_OBSERVED';Private='SYNTHETIC_PRIVATE'}
    }}
    $lines = & ([scriptblock]::Create($sqlBody.Substring(1,$sqlBody.Length-2)))
    Assert-HttpRefresh (($lines -join ' ') -clike ('*Ziellab '+$targetSelection.RunId+'*OBSERVED*BLOCKED*') -and
        ($lines -join ' ') -cmatch 'SQL-Edition im Ziellab: OBSERVED · EVALUATION · Evaluationsfrist: NOT_OBSERVED' -and
        ($lines -join ' ') -cnotmatch 'SYNTHETIC_PRIVATE') 'Target SQL job projects edition and an unobserved deadline, preserving the migration boundary'
    $storageFormatter = $server.Find({
        param($node)
        $node -is [Management.Automation.Language.IfStatementAst] -and
        $node.Clauses[0].Item1.Extent.Text -ceq '$JobAction -ceq ''ReadHyperVEvaluationTargetStorage'''
    }, $true)
    $storageBody = $storageFormatter.Clauses[0].Item2.Extent.Text
    $result = [pscustomobject]@{Result=[pscustomobject]@{
        TargetRunId=$targetSelection.RunId; TargetInstanceId=$targetSelection.InstanceId
        StorageObservation=[pscustomobject]@{Status='OBSERVED';ObservedAt='2030-01-01T00:00:00.0000000Z'
            Volumes=@([pscustomobject]@{Roles=@('Data','Log','Backup');AvailableBytes=[long]42;Path='SYNTHETIC_PRIVATE'})
        }
    }}
    $lines = & ([scriptblock]::Create($storageBody.Substring(1,$storageBody.Length-2)))
    Assert-HttpRefresh (($lines -join ' ') -clike ('*Ziellab '+$targetSelection.RunId+'*OBSERVED*42 Bytes frei*') -and
        ($lines -join ' ') -cnotmatch 'SYNTHETIC_PRIVATE') 'Target storage job logs capacity without guest locations'
    $guestGuard=$server.Find({
        param($node)
        $node -is [Management.Automation.Language.IfStatementAst] -and
        $node.Clauses[0].Item1.Extent.Text.StartsWith('$action -in @(''ReadHyperVEvaluationSqlSource''',[StringComparison]::Ordinal)
    },$true)
    $guard=[scriptblock]::Create($guestGuard.Extent.Text)
    $jobs=@{}
    $action='ReadHyperVEvaluationSqlSource'
    $parameters=@{RunId='33333333-3333-4333-8333-333333333333';InstanceId='primary';DataRoot='synthetic-root';ExpectedPlanKey=('a'*64);DatabaseName='MigrationFixture'}
    $null=& $guard
    $null=Assert-HttpRefresh ($parameters.Count -eq 5) 'Actual transient route accepts only the selected database field on source reads'
    $parameters.DatabaseName='invalid-name'
    $reason=$null
    try { & $guard } catch { $reason=$_.Exception.Message }
    Assert-HttpRefresh ($reason -ceq 'EVALUATION_REFRESH_SOURCE_DATABASE_INPUT_INVALID') 'Actual transient route rejects malformed database before the worker'
    $action='ReadHyperVEvaluationWindowsLicense'
    $parameters.DatabaseName='MigrationFixture'
    $reason=$null
    try { & $guard } catch { $reason=$_.Exception.Message }
    Assert-HttpRefresh ($reason -ceq 'EVALUATION_REFRESH_INPUT_INVALID') 'Database choice is scoped to the separate SQL read'
    Write-Host ('EVALUATION_REFRESH_HTTP_CHECKS: '+$checks+' PASS; 0 FAIL')
}finally{
    $resolved=[IO.Path]::GetFullPath($root);$expected=[IO.Path]::GetFullPath((Join-Path $repo '.artifacts/evaluation-refresh-browser-fixtures'))
    if(-not$resolved.StartsWith($expected+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)-or[IO.Path]::GetFileName($resolved)-notmatch'^[a-f0-9]{32}$'){throw 'FIXTURE_CLEANUP_SCOPE'}
    if(Test-Path -LiteralPath $resolved){Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction Stop}
}
