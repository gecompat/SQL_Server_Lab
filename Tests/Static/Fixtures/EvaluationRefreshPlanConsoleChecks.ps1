#Requires -Version 7.2
$ErrorActionPreference='Stop'
$repo=(Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
$root=Join-Path $repo ('.artifacts/evaluation-refresh-cli-fixtures/'+[guid]::NewGuid().ToString('N'))
$checks=0
function Assert-ConsoleRefresh($value,$label){if(-not$value){throw ('REFRESH_CONSOLE_CHECK_FAILED: '+$label)};$script:checks++;Write-Host ('PASS: '+$label)}
try {
    # Reuse only the canonical synthetic arrange statements, not its green cases.
    $tokens=$null;$errorsFound=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'Tests/Static/Invoke-EvaluationRefreshPlanChecks.ps1'),[ref]$tokens,[ref]$errorsFound)
    if($errorsFound.Count){throw 'FIXTURE_PARSE_FAILED'}
    foreach($statement in $ast.EndBlock.Statements){if($statement-is[Management.Automation.Language.FunctionDefinitionAst]){. ([scriptblock]::Create(($statement.Extent.Text-replace'^function ','function script:')))}}
    $try=@($ast.EndBlock.Statements|Where-Object {$_-is[Management.Automation.Language.TryStatementAst]})
    if($try.Count-ne1){throw 'FIXTURE_ARRANGE_SHAPE'}
    $arrange=@();foreach($statement in $try[0].Body.Statements){if($statement.Extent.Text-match'^\$before='){break};$arrange+=$statement.Extent.Text}
    if($arrange.Count-ne19){throw ('FIXTURE_ARRANGE_COUNT: '+$arrange.Count)}
    . ([scriptblock]::Create($arrange-join"`n"))
    Import-RefreshFunctions 'Private/EvaluationRefreshPlanConsole.ps1'
    Import-RefreshFunctions 'Private/PublicCommandConsole.ps1'
    function New-LabConsoleItem {param($Id,$Label,$Value,$Data);[pscustomobject]@{Id=$Id;Label=$Label;Value=$Value;Data=$Data}}
    function Read-LabConsoleTextInput {param($Prompt);[pscustomobject]@{Status=$script:rootStatus;Value=$script:root}}
    function Invoke-LabConsoleMenu {param($ScreenId,$Title,$Subtitle,$Items)
        $script:seenScreens.Add($ScreenId)
        $pick=$script:answers.Dequeue()
        if($pick-ceq'CANCEL'){return [pscustomobject]@{Status='Cancelled'}}
        if($script:beforeMenu){& $script:beforeMenu $ScreenId}
        $item=if($pick-ceq'RUN'){$Items[0]}else{@($Items|Where-Object Id -CEQ $pick)[0]}
        if(-not$item){$item=[pscustomobject]@{Id=$pick;Label='unknown'}}
        [pscustomobject]@{Status='Selected';SelectedItem=$item}
    }
    function Write-LabInfo {param($Message);$script:messages.Add([string]$Message)}
    function Write-LabWarning {param($Message);$script:messages.Add([string]$Message)}
    function Wait-LabConsoleAcknowledgement {}
    $script:actualPlan=${function:Get-SqlServerLabEvaluationRefreshPlan}
    function Get-SqlServerLabEvaluationRefreshPlan {param($RunId,$InstanceId,$DataRoot,$Mode);$script:planCalls++;$script:lastPlan=& $script:actualPlan @PSBoundParameters;return $script:lastPlan}
    function Reset-ConsoleRefresh([string[]]$Answers){$script:rootStatus='Confirmed';$script:answers=[Collections.Generic.Queue[string]]::new();foreach($a in $Answers){$script:answers.Enqueue($a)};$script:messages=[Collections.Generic.List[string]]::new();$script:seenScreens=[Collections.Generic.List[string]]::new();$script:planCalls=0;$script:lastPlan=$null;$script:beforeMenu=$null}
    $before=Get-RefreshHashes
    foreach($mode in @('FREE_SLOT_REPLACEMENT','RECONSTRUCT_LAB','STATEFUL_MIGRATION')){
        Reset-ConsoleRefresh @('RUN',$mode,'preview');Invoke-LabEvaluationRefreshPlanInteractive
        Assert-ConsoleRefresh ($planCalls-eq1-and$lastPlan.Mode-ceq$mode-and$lastPlan.Actions.Count-eq0-and-not$lastPlan.MutationAllowed) ('Actual CLI to public core '+$mode)
        Assert-ConsoleRefresh (($messages-join' ')-match'Windows:.*SQL Server:.*NOT_CHECKED|NOT_CHECKED.*Windows:.*SQL Server:') ('Separate Windows and SQL display '+$mode)
    }
    Assert-ConsoleRefresh (($messages-join' ')-match'EVIDENCE_MISSING'-and($messages-join' ')-notmatch'CANARY_PRIVATE') 'Missing SQL evidence is shown without private fields'
    $evidence=@{Contract=@{Name='SqlServerLab.SqlGuestEvaluationEvidence';Version='1.0'};EvidenceId=[guid]::NewGuid().ToString('D');RunId=$runId;ScopeId=$scope;InstanceId='primary';Provider='hyperv';VmId=$connection.instances[0].vmId;ImageArtifactId=$run.metadata.imageArtifactId;SqlInstanceName='MSSQLSERVER';SqlMajorVersion=17;SqlEdition='Enterprise Evaluation Edition';ObservedAt=[datetime]::UtcNow.AddHours(-2).ToString('o');EvidenceFreshUntil=[datetime]::UtcNow.AddMinutes(-1).ToString('o');LicenseClassification='EVALUATION';DeadlineSource='SQL_GUEST_OBSERVED';ObservationStatus='CAPTURED';EvaluationExpiresAt=[datetime]::UtcNow.AddDays(3).ToString('o');PreviousEvidenceId=$null}
    $guestPath=Join-Path $runDirectory sql-guest-evaluation-evidence.json;Write-Refresh $guestPath $evidence
    Reset-ConsoleRefresh @('RUN','STATEFUL_MIGRATION','preview');Invoke-LabEvaluationRefreshPlanInteractive
    Assert-ConsoleRefresh ($planCalls-eq1-and($messages-join' ')-match'EVIDENCE_STALE'-and$lastPlan.SqlReadiness-ceq'NOT_CHECKED') 'Actual CLI presents stale SQL evidence without readiness uplift'
    Remove-Item -LiteralPath $guestPath -Force
    foreach($answerCase in @(@('CANCEL'),@('RUN','CANCEL'),@('RUN','STATEFUL_MIGRATION','CANCEL'),@('RUN','STATEFUL_MIGRATION','back'))){$label=$answerCase-join'/';Reset-ConsoleRefresh $answerCase;Invoke-LabEvaluationRefreshPlanInteractive;Assert-ConsoleRefresh ($planCalls-eq0) ('Cancel zero dispatch at '+$label)}
    Reset-ConsoleRefresh @();$rootStatus='Cancelled';Invoke-LabEvaluationRefreshPlanInteractive;Assert-ConsoleRefresh ($planCalls-eq0-and$seenScreens.Count-eq0) 'Root cancellation reads no candidate'
    Reset-ConsoleRefresh @('foreign');Invoke-LabEvaluationRefreshPlanInteractive;Assert-ConsoleRefresh ($planCalls-eq0-and($messages-join' ')-match'EVALUATION_REFRESH_INPUT_INVALID') 'Unknown menu run cannot adopt Data'
    Reset-ConsoleRefresh @('RUN','wrong');Invoke-LabEvaluationRefreshPlanInteractive;Assert-ConsoleRefresh ($planCalls-eq0) 'Unknown mode zero dispatch'
    Reset-ConsoleRefresh @('RUN','STATEFUL_MIGRATION','preview');$beforeMenu={param($ScreenId)if($ScreenId-ceq'evaluation-refresh-preview'){$script:run.state='STOPPED';Write-Refresh $script:runPath $script:run}};Invoke-LabEvaluationRefreshPlanInteractive
    Assert-ConsoleRefresh ($planCalls-eq0-and($messages-join' ')-match'EVALUATION_REFRESH_BINDING_CHANGED') 'Selected content drift rejects before public plan'
    $run.state='RUNNING';Write-Refresh $runPath $run
    $marker=Join-Path $root '.sql-server-lab-root.json';$saved=[IO.File]::ReadAllText($marker);$obj=$saved|ConvertFrom-Json;$obj.ControllerId=[guid]::NewGuid().ToString('D');Write-Refresh $marker $obj
    Reset-ConsoleRefresh @();Invoke-LabEvaluationRefreshPlanInteractive;Assert-ConsoleRefresh ($planCalls-eq0) 'Foreign controller leaves no selectable run'
    [IO.File]::WriteAllText($marker,$saved,[Text.UTF8Encoding]::new($false))
    $run.metadata.desiredState.Instances+=@{Id='second';Provider='hyperv';Version='2025'};Write-Refresh $runPath $run
    Reset-ConsoleRefresh @();Invoke-LabEvaluationRefreshPlanInteractive;Assert-ConsoleRefresh ($planCalls-eq0) 'Multiple intended instances are not selected'
    $run.metadata.desiredState.Instances=@($run.metadata.desiredState.Instances[0]);Write-Refresh $runPath $run
    Reset-ConsoleRefresh @('RUN','STATEFUL_MIGRATION','unexpected');Invoke-LabEvaluationRefreshPlanInteractive;Assert-ConsoleRefresh ($planCalls-eq0) 'Invalid preview action cannot dispatch'
    $savedReader=${function:Read-LabEvaluationRefreshSnapshot};function Read-LabEvaluationRefreshSnapshot {throw 'PRIVATE_CANARY_PATH_HOST_SECRET'}
    Reset-ConsoleRefresh @();Invoke-LabEvaluationRefreshPlanInteractive;Assert-ConsoleRefresh (-not(($messages-join' ')-match'PRIVATE_CANARY')) 'Candidate exception text is never displayed'
    Set-Item Function:Read-LabEvaluationRefreshSnapshot $savedReader
    $extra=@();try {foreach($i in 1..64){$dir=Join-Path (Split-Path $runDirectory) ('extra-'+$i);$null=New-Item -ItemType Directory $dir;$extra+=$dir};Reset-ConsoleRefresh @();Invoke-LabEvaluationRefreshPlanInteractive;Assert-ConsoleRefresh ($planCalls-eq0-and($messages-join' ')-match'EVALUATION_REFRESH_SCOPE_UNSUPPORTED') 'Directory count is bounded before candidate reads'} finally {foreach($dir in $extra){Remove-Item -LiteralPath $dir -Force}}
    Assert-ConsoleRefresh ((Get-RefreshHashes)-ceq$before) 'Actual dialog writes no state'
    $script:guidedCalls=0;$script:legacyCalls=0;$script:componentCalls=0
    function Get-LabPublicCommandConsoleCatalog {return [pscustomobject]@{Name='legacy';ParameterSets=@(@{Name='Default'})}}
    function Invoke-LabEvaluationRefreshPlanInteractive {$script:guidedCalls++}
    function Invoke-LabPublicCommandInteractive {param($CatalogItem);$script:legacyCalls++}
    function Invoke-LabComponentRelationPlanInteractive {$script:componentCalls++}
    Reset-ConsoleRefresh @('evaluation-refresh-preview','legacy','component-relations-preview','CANCEL');Manage-LabPublicCommandsInteractive
    Assert-ConsoleRefresh ($guidedCalls-eq1-and$legacyCalls-eq1-and$componentCalls-eq1) 'Actual common menu preserves legacy and component routes'
    Write-Host ('EVALUATION_REFRESH_CONSOLE_CHECKS: '+$checks+' PASS; 0 FAIL')
} finally {
    $resolved=[IO.Path]::GetFullPath($root);$expected=[IO.Path]::GetFullPath((Join-Path $repo '.artifacts/evaluation-refresh-cli-fixtures'))
    if(-not$resolved.StartsWith($expected+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)-or[IO.Path]::GetFileName($resolved)-notmatch'^[a-f0-9]{32}$'){throw 'FIXTURE_CLEANUP_SCOPE'}
    if(Test-Path $resolved){Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction Stop}
}
