#Requires -Version 7.2
$ErrorActionPreference='Stop'
$repo=(Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
$root=Join-Path $repo ('.artifacts/evaluation-refresh-cli-fixtures/'+[guid]::NewGuid().ToString('N'))
$checks=0
function Assert-ConsoleRefresh($value,$label){if(-not$value){throw ('REFRESH_CONSOLE_CHECK_FAILED: '+$label)};$script:checks++;Write-Host ('PASS: '+$label)}
function Import-RefreshNamedFunction([string]$relative,[string]$name){
    $tokens=$null;$parseErrors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo $relative),[ref]$tokens,[ref]$parseErrors)
    if($parseErrors.Count){throw 'FIXTURE_PARSE_FAILED'}
    $matches=@($ast.EndBlock.Statements|Where-Object {$_ -is [Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -ceq $name})
    if($matches.Count-ne1){throw ('FIXTURE_FUNCTION_NOT_UNIQUE: '+$name)}
    . ([scriptblock]::Create(($matches[0].Extent.Text-replace'^function ','function script:')))
}
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
    $script:actualPlan=${function:New-LabEvaluationRefreshPlan}
    function New-LabEvaluationRefreshPlan {
        param($RunId,$InstanceId,$DataRoot,$Mode,$ExpectedSnapshotDigest,[switch]$ObserveSqlSource,[switch]$ObserveWindowsLicense,
            $TargetRunId,$TargetInstanceId,$ExpectedTargetSnapshotDigest,[switch]$ObserveTargetWindowsLicense,[switch]$ObserveTargetSqlReadiness,[switch]$ObserveTargetStorage)
        $script:planCalls++
        if ($ExpectedSnapshotDigest -cnotmatch '^[a-f0-9]{64}$') { throw 'SYNTHETIC_EXPECTED_DIGEST_REQUIRED' }
        $script:lastPlan = & $script:actualPlan @PSBoundParameters
        return $script:lastPlan
    }
    function Get-LabEvaluationSqlSourceInventory {
        param($Snapshot)
        [pscustomobject]@{ Status='PARTIALLY_OBSERVED'; Items=@([pscustomobject]@{Category='Credentials';Count=[long]1})
            DependencyFindings=@([pscustomobject]@{Category='Credentials';Count=[long]1;Code='CREDENTIAL_REBIND_REQUIRED'}) }
    }
    function Get-LabEvaluationWindowsLicenseObservation {
        param($Snapshot)
        [pscustomobject]@{Status='OBSERVED';LicenseState='LICENSED';ObservedAt=[datetime]::UtcNow.ToString('o');EvaluationExpiresAt=$null}
    }
    function Get-LabEvaluationSqlGuestObservation {
        param($Snapshot,[switch]$IncludeSourceInventory,[switch]$IncludeTargetStorage)
        if ($IncludeSourceInventory -or $Snapshot.Binding.Run.state -cne 'RUNNING') { throw 'UNEXPECTED_SQL_READINESS_PROBE' }
        if ($IncludeTargetStorage) {
            return [pscustomobject]@{TargetStorage=@([pscustomobject]@{Roles=@('Data','Log','Backup');AvailableBytes=[long]500})}
        }
        [pscustomobject]@{MajorVersion=17}
    }
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
    Reset-ConsoleRefresh @('RUN','STATEFUL_MIGRATION','observe-windows');$beforeMenu={param($ScreenId)if($ScreenId-ceq'evaluation-refresh-preview'){$script:run.state='STOPPED';Write-Refresh $script:runPath $script:run}};Invoke-LabEvaluationRefreshPlanInteractive
    Assert-ConsoleRefresh ($planCalls -eq 1 -and -not $lastPlan -and ($messages -join ' ') -match 'EVALUATION_REFRESH_BINDING_CHANGED') 'Core rejects selected CLI digest drift before accessing the guest'
    $run.state='RUNNING';Write-Refresh $runPath $run
    $marker=Join-Path $root '.sql-server-lab-root.json';$saved=[IO.File]::ReadAllText($marker);$obj=$saved|ConvertFrom-Json;$obj.ControllerId=[guid]::NewGuid().ToString('D');Write-Refresh $marker $obj
    Reset-ConsoleRefresh @();Invoke-LabEvaluationRefreshPlanInteractive;Assert-ConsoleRefresh ($planCalls-eq0) 'Foreign controller leaves no selectable run'
    [IO.File]::WriteAllText($marker,$saved,[Text.UTF8Encoding]::new($false))
    $run.metadata.desiredState.Instances+=@{Id='second';Provider='hyperv';Version='2025'};Write-Refresh $runPath $run
    Reset-ConsoleRefresh @();Invoke-LabEvaluationRefreshPlanInteractive;Assert-ConsoleRefresh ($planCalls-eq0) 'Multiple intended instances are not selected'
    $run.metadata.desiredState.Instances=@($run.metadata.desiredState.Instances[0]);Write-Refresh $runPath $run
    Reset-ConsoleRefresh @('RUN','STATEFUL_MIGRATION','unexpected');Invoke-LabEvaluationRefreshPlanInteractive;Assert-ConsoleRefresh ($planCalls-eq0) 'Invalid preview action cannot dispatch'
    Reset-ConsoleRefresh @('RUN','STATEFUL_MIGRATION','observe');Invoke-LabEvaluationRefreshPlanInteractive
    Assert-ConsoleRefresh ($planCalls -eq 1 -and $lastPlan.SqlSourceInventory.Status -ceq 'PARTIALLY_OBSERVED' -and
        ($messages -join ' ') -cmatch 'CREDENTIAL_REBIND_REQUIRED') 'The explicit guided source observation shows the identified dependency'
    Reset-ConsoleRefresh @('RUN','RECONSTRUCT_LAB','observe');Invoke-LabEvaluationRefreshPlanInteractive
    Assert-ConsoleRefresh ($planCalls -eq 0) 'The observation choice is unavailable outside stateful migration'
    Reset-ConsoleRefresh @('RUN','RECONSTRUCT_LAB','observe-windows');Invoke-LabEvaluationRefreshPlanInteractive
    Assert-ConsoleRefresh ($planCalls -eq 1 -and $lastPlan.WindowsLicenseObservation.LicenseState -ceq 'LICENSED' -and
        -not $lastPlan.PSObject.Properties['SqlSourceInventory'] -and $lastPlan.Status -ceq 'BLOCKED' -and
        ($messages -join ' ') -cmatch 'LICENSED') 'Windows observation is a distinct guided read with its own display'
    $savedReader=${function:Read-LabEvaluationRefreshSnapshot};function Read-LabEvaluationRefreshSnapshot {throw 'PRIVATE_CANARY_PATH_HOST_SECRET'}
    Reset-ConsoleRefresh @();Invoke-LabEvaluationRefreshPlanInteractive;Assert-ConsoleRefresh (-not(($messages-join' ')-match'PRIVATE_CANARY')) 'Candidate exception text is never displayed'
    Set-Item Function:Read-LabEvaluationRefreshSnapshot $savedReader
    $extra=@();try {foreach($i in 1..64){$dir=Join-Path (Split-Path $runDirectory) ('extra-'+$i);$null=New-Item -ItemType Directory $dir;$extra+=$dir};Reset-ConsoleRefresh @();Invoke-LabEvaluationRefreshPlanInteractive;Assert-ConsoleRefresh ($planCalls-eq0-and($messages-join' ')-match'EVALUATION_REFRESH_SCOPE_UNSUPPORTED') 'Directory count is bounded before candidate reads'} finally {foreach($dir in $extra){Remove-Item -LiteralPath $dir -Force}}
    Assert-ConsoleRefresh ((Get-RefreshHashes)-ceq$before) 'Actual dialog writes no state'
    $targetFixture=New-RefreshTargetFixture $root $run $connection
    $beforeTargets=Get-RefreshHashes
    Reset-ConsoleRefresh @($runId,'STATEFUL_MIGRATION','target',$targetFixture.RunId);Invoke-LabEvaluationRefreshPlanInteractive
    Assert-ConsoleRefresh ($planCalls-eq1-and$lastPlan.TargetAssessment.RunId-ceq$targetFixture.RunId-and
        ($messages-join' ')-cmatch'TARGET_STORAGE_AND_TRANSFER_NOT_VERIFIED'-and
        $seenScreens.Contains('evaluation-refresh-target')) 'CLI binds the selected target and shows the remaining checks'
    Reset-ConsoleRefresh @($runId,'STATEFUL_MIGRATION','target','CANCEL');Invoke-LabEvaluationRefreshPlanInteractive
    Assert-ConsoleRefresh ($planCalls-eq0) 'Cancelling target selection dispatches no plan'
    Reset-ConsoleRefresh @($runId,'STATEFUL_MIGRATION','target',$runId);Invoke-LabEvaluationRefreshPlanInteractive
    Assert-ConsoleRefresh ($planCalls-eq0) 'The source is never offered as its own target'
    Assert-ConsoleRefresh ((Get-RefreshHashes)-ceq$beforeTargets) 'Target dialog does not change either fixture'
    $liveTarget=New-RefreshTargetFixture $root $run $connection RUNNING
    $beforeLiveTargets=Get-RefreshHashes
    Reset-ConsoleRefresh @($runId,'STATEFUL_MIGRATION','observe-target-windows',$liveTarget.RunId);Invoke-LabEvaluationRefreshPlanInteractive
    Assert-ConsoleRefresh ($planCalls -eq 1 -and $lastPlan.TargetAssessment.RunId -ceq $liveTarget.RunId -and
        $lastPlan.TargetAssessment.WindowsLicenseObservation.LicenseState -ceq 'LICENSED' -and
        ($messages-join ' ') -cmatch 'Windows-Lizenz im Ziellab.*LICENSED') 'CLI explicitly reads and displays the selected target license'
    Reset-ConsoleRefresh @($runId,'STATEFUL_MIGRATION','observe-target-windows',$targetFixture.RunId);Invoke-LabEvaluationRefreshPlanInteractive
    Assert-ConsoleRefresh ($planCalls -eq 0) 'CLI cannot dispatch a license read for a stopped or forged target'
    Reset-ConsoleRefresh @($runId,'STATEFUL_MIGRATION','observe-target-sql',$liveTarget.RunId);Invoke-LabEvaluationRefreshPlanInteractive
    Assert-ConsoleRefresh ($planCalls -eq 1 -and $lastPlan.TargetAssessment.RunId -ceq $liveTarget.RunId -and
        $lastPlan.TargetAssessment.SqlReadinessObservation.Status -ceq 'OBSERVED' -and
        ($messages -join ' ') -cmatch 'SQL-Bereitschaft im Ziellab: OBSERVED') 'CLI explicitly reads and displays the selected target SQL readiness'
    Reset-ConsoleRefresh @($runId,'STATEFUL_MIGRATION','observe-target-sql',$targetFixture.RunId);Invoke-LabEvaluationRefreshPlanInteractive
    Assert-ConsoleRefresh ($planCalls -eq 0) 'CLI cannot query a stopped destination'
    Reset-ConsoleRefresh @($runId,'STATEFUL_MIGRATION','observe-target-storage',$liveTarget.RunId);Invoke-LabEvaluationRefreshPlanInteractive
    Assert-ConsoleRefresh ($planCalls -eq 1 -and $lastPlan.TargetAssessment.RunId -ceq $liveTarget.RunId -and
        $lastPlan.TargetAssessment.StorageObservation.Status -ceq 'OBSERVED' -and
        ($messages -join ' ') -cmatch 'Freier Gast-Speicher im Ziellab: OBSERVED.*Data / Log / Backup: 500 Bytes frei') 'CLI reads the selected target and groups shared storage'
    Reset-ConsoleRefresh @($runId,'STATEFUL_MIGRATION','observe-target-storage',$targetFixture.RunId);Invoke-LabEvaluationRefreshPlanInteractive
    Assert-ConsoleRefresh ($planCalls -eq 0) 'CLI cannot read storage from a stopped destination'
    Assert-ConsoleRefresh ((Get-RefreshHashes) -ceq $beforeLiveTargets) 'Target observations leave saved state unchanged'
    $script:guidedCalls=0;$script:legacyCalls=0;$script:componentCalls=0
    function Get-LabPublicCommandConsoleCatalog {return [pscustomobject]@{Name='legacy';ParameterSets=@(@{Name='Default'})}}
    function Invoke-LabEvaluationRefreshPlanInteractive {$script:guidedCalls++}
    function Invoke-LabPublicCommandInteractive {param($CatalogItem);$script:legacyCalls++}
    function Invoke-LabComponentRelationPlanInteractive {$script:componentCalls++}
    Reset-ConsoleRefresh @('evaluation-refresh-preview','legacy','component-relations-preview','CANCEL');Manage-LabPublicCommandsInteractive
    Assert-ConsoleRefresh ($guidedCalls-eq1-and$legacyCalls-eq1-and$componentCalls-eq1) 'Actual common menu preserves legacy and component routes'

    Import-RefreshNamedFunction 'Public/BatchConsole.ps1' 'Show-LabMaintenanceMenu'
    Import-RefreshNamedFunction 'Public/Invoke-SqlServerLab.ps1' 'Invoke-LabMenuAction'
    function New-LabConsoleItem {param($Id,$Label,$Value,$Shortcut,$Disabled,$DisabledReason,$Help);[pscustomobject]@{Id=$Id;Label=$Label;Value=$Value;Shortcut=$Shortcut;Disabled=$Disabled;DisabledReason=$DisabledReason;Help=$Help}}
    function Show-LabSubMenu {param($ScreenId,$Title,$Subtitle,$Items);return $Items}
    $maintenanceItems=@(Show-LabMaintenanceMenu)
    Assert-ConsoleRefresh (@($maintenanceItems|Where-Object Id -CEQ 'EvaluationRefreshPlan').Count-eq1) 'Maintenance menu exposes the dedicated evaluation decision'
    $script:menuActionCalls=0
    function Invoke-LabEvaluationRefreshPlanInteractive {$script:menuActionCalls++}
    Invoke-LabMenuAction -ActionName EvaluationRefreshPlan
    Assert-ConsoleRefresh ($menuActionCalls-eq1) 'Maintenance menu action dispatches the guided evaluation flow'

    Import-RefreshNamedFunction 'Public/Invoke-SqlServerLab.ps1' 'Invoke-SqlServerLab'
    function New-LabQueueStatusProvider {param($Height);return {}}
    Invoke-SqlServerLab -Action EvaluationRefreshPlan -ConsoleMode Fallback
    Assert-ConsoleRefresh ($menuActionCalls-eq2) 'Direct Action supports the same guided evaluation flow'
    Write-Host ('EVALUATION_REFRESH_CONSOLE_CHECKS: '+$checks+' PASS; 0 FAIL')
} finally {
    $resolved=[IO.Path]::GetFullPath($root);$expected=[IO.Path]::GetFullPath((Join-Path $repo '.artifacts/evaluation-refresh-cli-fixtures'))
    if(-not$resolved.StartsWith($expected+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)-or[IO.Path]::GetFileName($resolved)-notmatch'^[a-f0-9]{32}$'){throw 'FIXTURE_CLEANUP_SCOPE'}
    if(Test-Path $resolved){Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction Stop}
}
