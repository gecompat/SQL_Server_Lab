#Requires -Version 7.2
[CmdletBinding()]param()
$ErrorActionPreference='Stop'
$repo=(Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
$fixture=Join-Path $repo ('.artifacts/component-relation-console/'+[guid]::NewGuid().ToString('N'))
$checks=0
function Assert-ConsolePlan($condition,$name) { if(-not $condition){throw ('COMPONENT_CONSOLE_CHECK_FAILED: '+$name)};$script:checks++;Write-Host ('PASS: '+$name) }
function Import-ConsolePlanFunctions($relative,[string[]]$names) {
    $tokens=$null;$parseErrors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo $relative),[ref]$tokens,[ref]$parseErrors)
    if($parseErrors.Count){throw 'FIXTURE_SOURCE_PARSE_FAILED'}
    foreach($statement in $ast.EndBlock.Statements){
        if($statement -is [Management.Automation.Language.FunctionDefinitionAst] -and (-not $names -or $statement.Name -cin $names)){
            . ([scriptblock]::Create(($statement.Extent.Text -replace '^function ', 'function script:')))
        }
    }
}
function Write-ConsolePlanJson($path,$value){$null=New-Item -ItemType Directory -Path (Split-Path $path) -Force;$value|ConvertTo-Json -Depth 64|Set-Content -LiteralPath $path -Encoding utf8}
try {
    # Load actual declarations, never the module loader, provider scripts or host tools.
    Import-ConsolePlanFunctions Private/DiagnosticBundleReader.ps1
    Import-ConsolePlanFunctions Private/ComponentRelationPlan.ps1
    Import-ConsolePlanFunctions Private/ComponentRelationPlanConsole.ps1
    Import-ConsolePlanFunctions Private/DesiredState.ps1 @('Get-LabPersistedDesiredState')
    Import-ConsolePlanFunctions Private/StateMachine.ps1 @('Get-LabRunState')
    Import-ConsolePlanFunctions Private/ProviderCapability.ps1 @('Get-LabProviderCapabilityContract')
    Import-ConsolePlanFunctions Private/VersionCatalog.ps1 @('Get-SqlServerVersion')
    Import-ConsolePlanFunctions Private/BatchWorkflow.ps1 @('Get-LabWorkflowHash')
    Import-ConsolePlanFunctions Private/ConsoleUi.ps1 @('New-LabConsoleItem')
    Import-ConsolePlanFunctions Private/PublicCommandConsole.ps1 @('Manage-LabPublicCommandsInteractive','Edit-LabPublicCommandParameterValue','ConvertFrom-LabPublicCommandInput')
    Import-ConsolePlanFunctions Public/Get-SqlServerLabReconcilePlan.ps1 @('Get-SqlServerLabReconcilePlan')
    $script:realPlan=${function:Get-SqlServerLabReconcilePlan}
    function Get-SqlServerLabReconcilePlan {param($RunId,$StateRoot,[AllowEmptyCollection()][object[]]$ProposedRelations);$script:planCalls++;$script:lastPlan=& $script:realPlan @PSBoundParameters;$script:lastPlan}
    $script:VersionCatalog=Get-Content (Join-Path $repo Catalogs/sql-server-versions.json) -Raw|ConvertFrom-Json
    $script:RegisteredProviders=@{}
    foreach($provider in @('docker','podman')){
        $providerDirectory=switch -CaseSensitive ($provider){'docker'{'Docker'};'podman'{'Podman'};default{throw 'FIXTURE_PROVIDER_UNKNOWN'}}
        $script:RegisteredProviders[$provider]=@{Definition=Get-Content (Join-Path $repo ('Providers/'+$providerDirectory+'/provider.json')) -Raw|ConvertFrom-Json}
    }
    function Get-LabStateRoot {throw 'FORBIDDEN_DEFAULT_ROOT'}
    function Get-LabStorageConfiguration {throw 'FORBIDDEN_TOPOLOGY_READ'}
    function Get-ContainerRuntime {throw 'FORBIDDEN_PROVIDER_CALL'}
    function Get-LabHostToolInvocation {throw 'FORBIDDEN_HOSTTOOL_CALL'}
    function Get-LabSecret {throw 'FORBIDDEN_SECRET_CALL'}
    function Invoke-SqlServerLabReconcileAction {throw 'FORBIDDEN_EXECUTOR_CALL'}
    function Invoke-SqlServerLabWorkflowAction {throw 'FORBIDDEN_WORKFLOW_CALL'}
    function Wait-LabConsoleAcknowledgement {}
    function Write-LabInfo {param($Message);$script:messages.Add([string]$Message)}
    function Write-LabWarning {param($Message);$script:warnings.Add([string]$Message)}
    function Read-LabConsoleTextInput {param($Prompt,$Default);[pscustomobject]@{Status=$script:inputStatus;Value=$script:dataRoot}}
    function Invoke-LabConsoleMenu {
        param($ScreenId,$Title,$Subtitle,$Items)
        $script:observedMenus.Add([pscustomobject]@{Title=$Title;Ids=@($Items.Id)})
        if(-not $script:choices.Count){return [pscustomobject]@{Status='Cancelled'}}
        $id=$script:choices.Dequeue()
        if($id-ceq'cancel'){return [pscustomobject]@{Status='Cancelled'}}
        if($id-ceq'preview'-and$script:beforePreview){& $script:beforePreview}
        $item=@($Items|Where-Object Id -CEQ $id)
        if($item.Count-ne1){throw 'FIXTURE_CHOICE_NOT_FOUND'}
        [pscustomobject]@{Status='Selected';SelectedItem=$item[0]}
    }
    $script:dataRoot=Join-Path $fixture data
    $stateRoot=Join-Path $dataRoot State
    $controller='11111111-1111-4111-8111-111111111111';$location='22222222-2222-4222-8222-222222222222'
    $ownId='33333333-3333-4333-8333-333333333333';$ownScope='44444444-4444-4444-8444-444444444444'
    $sharedId='55555555-5555-4555-8555-555555555555';$sharedScope='66666666-6666-4666-8666-666666666666'
    Write-ConsolePlanJson (Join-Path $dataRoot '.sql-server-lab-root.json') @{ContractVersion='SqlServerLab.DataRoot/2.0';ManagedBy='SQL_Server_Lab';ControllerId=$controller;VolumeId='SYNTHETIC_VOLUME';DataRoot=$dataRoot}
    Write-ConsolePlanJson (Join-Path $dataRoot Catalog/storage-locations.json) @{ContractVersion='SqlServerLab.Storage/2.0';ControllerId=$controller;LabDataLocations=@(@{LocationId=$location;ControllerId=$controller;LabDataRoot=$dataRoot;VolumeId='SYNTHETIC_VOLUME'})}
    function Write-ConsoleRun($id,$scope,$instances) {
        $sub=@($instances|Group-Object Provider|ForEach-Object {@{id=('provider-'+$_.Name);provider=$_.Name;instanceIds=@($_.Group.Id);state='RUNNING'}})
        $run=@{contractVersion='SqlServerLab.RunState/1.0';runId=$id;scopeId=$scope;state='RUNNING';instances=@();errors=@();stateHistory=@();providerSubRuns=$sub;metadata=@{persistentData=$false;desiredState=@{Contract=@{Name='SqlServerLab.RunDesiredState';Version='1.0'};PersistentData=$false;ProvisioningMode='adhoc';Instances=$instances}}}
        Write-ConsolePlanJson (Join-Path $stateRoot ('runs/'+$id+'/run-state.json')) $run
        Write-ConsolePlanJson (Join-Path $stateRoot ('scope-markers/'+$scope+'.json')) @{runId=$id;scopeId=$scope}
        Write-ConsolePlanJson (Join-Path $stateRoot ('runs/'+$id+'/connection-info.json')) @{instances=@($instances|ForEach-Object {@{id=$_.Id;provider=$_.Provider;containerId='a'*64;containerName='SYNTHETIC_PRIVATE_CONTAINER';host='127.0.0.1';port=14330}})}
    }
    $instances=@(@{Id='consumer';Provider='docker';Version='2025'},@{Id='prerequisite';Provider='podman';Version='2025'})
    Write-ConsoleRun $ownId $ownScope $instances
    Write-ConsoleRun $sharedId $sharedScope @(@{Id='sharedSql';Provider='docker';Version='2025'})
    function Reset-ConsoleTest([string[]]$ids) {
        $script:planCalls=0;$script:lastPlan=$null;$script:beforePreview=$null;$script:inputStatus='Confirmed'
        $script:messages=[Collections.Generic.List[string]]::new();$script:warnings=[Collections.Generic.List[string]]::new()
        $script:observedMenus=[Collections.Generic.List[object]]::new()
        $script:choices=[Collections.Generic.Queue[string]]::new();foreach($id in $ids){$script:choices.Enqueue($id)}
    }
    function Get-ConsoleFileBinding {(@(Get-ChildItem -LiteralPath $fixture -File -Recurse|Sort-Object FullName|ForEach-Object {$_.FullName+':'+(Get-FileHash -LiteralPath $_.FullName).Hash})-join'|')}
    $before=Get-ConsoleFileBinding
    Reset-ConsoleTest @($ownId,'add','consumer',($ownId+':prerequisite'),'add','prerequisite',($sharedId+':sharedSql'),'preview')
    Invoke-LabComponentRelationPlanInteractive
    Assert-ConsolePlan ($planCalls-eq1-and$warnings.Count-eq0-and($lastPlan.PrerequisiteOrder.InstanceId-join',')-ceq'sharedSql,prerequisite,consumer') 'Actual guided CLI dispatches public pure core once with own/shared DAG'
    Assert-ConsolePlan ($lastPlan.Actual.SqlReadiness-ceq'NOT_CHECKED'-and$lastPlan.SharedRemovalPolicy-ceq'PRESERVE'-and-not$lastPlan.MutationAllowed-and-not$lastPlan.ExecutionSupported-and$lastPlan.Actions.Count-eq0) 'Actual core remains PLAN_ONLY NOT_CHECKED PRESERVE without executor'
    Assert-ConsolePlan (@($messages|Where-Object {$_-match' · Provider: (docker|podman) · '}).Count-eq3-and-not($messages-join' ').Contains('SQL docker')-and-not($messages-join' ').Contains('SQL podman')) 'Result labels distinguish providers from SQL versions'
    Assert-ConsolePlan (($messages-join' ')-notmatch'SYNTHETIC_PRIVATE_CONTAINER|127\.0\.0\.1|14330'-and-not($messages-join' ').Contains($fixture)) 'Guided result excludes endpoint/native/path metadata'
    Assert-ConsolePlan ($before-ceq(Get-ConsoleFileBinding)) 'Actual guidance and core preserve all registered metadata'
    foreach($choices in @(@('cancel'),@($ownId,'back'),@($ownId,'add','cancel'),@($ownId,'add','consumer','cancel'))){Reset-ConsoleTest $choices;Invoke-LabComponentRelationPlanInteractive;Assert-ConsolePlan ($planCalls-eq0) ('Cancel/back zero public dispatch at depth '+$choices.Count)}
    Reset-ConsoleTest @();$script:inputStatus='Cancelled';Invoke-LabComponentRelationPlanInteractive
    Assert-ConsolePlan ($planCalls-eq0) 'Root input cancellation has zero public dispatch'
    Reset-ConsoleTest @($ownId,'preview');Invoke-LabComponentRelationPlanInteractive
    Assert-ConsolePlan ($planCalls-eq1-and$lastPlan.Status-ceq'NO_RELATION_CHANGE') 'Explicit empty relations stay on pure plan route'
    Reset-ConsoleTest @($ownId,'add','consumer',($ownId+':prerequisite'),'add','prerequisite',($ownId+':consumer'),'preview');Invoke-LabComponentRelationPlanInteractive
    Assert-ConsolePlan ($planCalls-eq1-and$warnings.Count-eq1-and$warnings[0]-match'^COMPONENT_RELATION_CYCLE:') 'Actual guided cycle fails through public core'
    $runPath=Join-Path $stateRoot ('runs/'+$ownId+'/run-state.json');$original=Get-Content -LiteralPath $runPath -Raw
    Reset-ConsoleTest @($ownId,'preview');$script:beforePreview={ $run=$original|ConvertFrom-Json -Depth 64;$run.state='STOPPED';Write-ConsolePlanJson $runPath $run };Invoke-LabComponentRelationPlanInteractive
    Assert-ConsolePlan ($planCalls-eq0-and$warnings.Count-eq1-and$warnings[0]-match'^COMPONENT_RELATION_BINDING_CHANGED:') 'Selection content drift fails before public dispatch'
    [IO.File]::WriteAllText($runPath,$original,[Text.UTF8Encoding]::new($false))
    $threeId='77777777-7777-4777-8777-777777777777';Write-ConsoleRun $threeId '88888888-8888-4888-8888-888888888888' @($instances+@{Id='third';Provider='docker';Version='2025'})
    Assert-ConsolePlan ($threeId-cnotin@(Get-LabComponentRelationConsoleRuns $dataRoot).RunId) 'Three-target scope is not selectable by actual binding reader'
    $otherSharedId='99999999-9999-4999-8999-999999999999'
    Write-ConsoleRun $otherSharedId 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa' @(@{Id='otherSql';Provider='podman';Version='2025'})
    Reset-ConsoleTest @($ownId,'add','consumer',($sharedId+':sharedSql'),'add','prerequisite','cancel');Invoke-LabComponentRelationPlanInteractive
    $targetMenus=@($observedMenus|Where-Object Title -CEQ 'Benötigte SQL-Instanz auswählen')
    Assert-ConsolePlan ($planCalls-eq0-and$targetMenus.Count-eq2-and($otherSharedId+':otherSql')-cin$targetMenus[0].Ids-and($otherSharedId+':otherSql')-cnotin$targetMenus[1].Ids) 'Actual dialog limits shared selection to exactly one managed reference'
    $markerPath=Join-Path $dataRoot '.sql-server-lab-root.json';$markerText=Get-Content -LiteralPath $markerPath -Raw
    $marker=$markerText|ConvertFrom-Json;$marker.ControllerId='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';Write-ConsolePlanJson $markerPath $marker
    Reset-ConsoleTest @();Invoke-LabComponentRelationPlanInteractive
    Assert-ConsolePlan ($planCalls-eq0-and$messages.Count-eq1-and$messages[0]-match'^Keine vollständig') 'Unbound controller/root offers no selectable run or plan dispatch'
    [IO.File]::WriteAllText($markerPath,$markerText,[Text.UTF8Encoding]::new($false))
    $unregistered=Join-Path $fixture unregistered;$script:dataRoot=$unregistered;Reset-ConsoleTest @();Invoke-LabComponentRelationPlanInteractive
    Assert-ConsolePlan ($planCalls-eq0-and$warnings.Count-eq1-and-not$warnings[0].Contains($fixture)) 'Missing unregistered root fails privately without initialization'
    $script:dataRoot=Join-Path $fixture data
    # Complete menu routing retains the existing generic branch.
    function Get-LabPublicCommandConsoleCatalog { @([pscustomobject]@{Name='SyntheticLegacyCommand';Command='SyntheticLegacyCommand';ParameterSets=@(@{Name='Default'})}) }
    function Invoke-LabPublicCommandInteractive {param($CatalogItem);$script:legacyCalls++;Assert-ConsolePlan ($CatalogItem.Name-ceq'SyntheticLegacyCommand') 'Legacy catalog item is retained'}
    Reset-ConsoleTest @('SyntheticLegacyCommand','cancel');$script:legacyCalls=0;Manage-LabPublicCommandsInteractive
    Assert-ConsolePlan ($legacyCalls-eq1-and$planCalls-eq0) 'Actual menu legacy branch remains independent'
    Reset-ConsoleTest @('component-relations-preview',$ownId,'preview','cancel');Manage-LabPublicCommandsInteractive
    Assert-ConsolePlan ($planCalls-eq1-and$legacyCalls-eq1) 'Actual public menu reaches guided preview without generic execution'
    Write-Host ('COMPONENT_RELATION_CONSOLE_CHECKS: '+$checks+' PASS; 0 FAIL')
} finally {
    $resolved=[IO.Path]::GetFullPath($fixture);$expected=Join-Path $repo '.artifacts/component-relation-console'
    if($resolved.StartsWith($expected+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)-and[IO.Directory]::Exists($resolved)){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
