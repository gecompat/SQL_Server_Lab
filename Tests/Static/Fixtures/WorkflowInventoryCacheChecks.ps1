#Requires -Version 7.2
# Execute only the actual cache functions. Job leaves and time are synthetic;
# no listener, module import, inventory, provider or filesystem mutation occurs.
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'Tools/Start-SqlServerLabUi.ps1'),[ref]$tokens,[ref]$errors)
if($errors){throw 'WORKFLOW_CACHE_SOURCE_PARSE'}
foreach($name in @('Update-UiWorkflowInventory','Get-UiWorkflowInventoryResponse')){
 $definitions=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name},$true))
 if($definitions.Count -ne 1){throw 'WORKFLOW_CACHE_SOURCE_FUNCTION'}
 . ([scriptblock]::Create($definitions[0].Extent.Text))
}
$script:now=[datetime]'2026-01-01T00:01:00Z';$script:starts=0;$script:removals=0
$script:received=[pscustomobject]@{Marker='new-synthetic-snapshot'}
$modulePath='synthetic-module-not-imported'
function Get-Date {return $script:now}
function Start-ThreadJob {param($Name,$ArgumentList,$ScriptBlock) $script:starts++;return [pscustomobject]@{State='Running'}}
function Receive-Job {param($Job,$ErrorAction) return $script:received}
function Remove-Job {param($Job,[switch]$Force,$ErrorAction) $script:removals++}
function Reset-Cache($State='Completed',$Root='synthetic-root') {
 $script:starts=0;$script:removals=0;$script:received=[pscustomobject]@{Marker='new-synthetic-snapshot'}
 $script:workflowInventory=[pscustomobject]@{Job=[pscustomobject]@{State=$State};Snapshot=$null;MediaRoot=$Root;RequestedAt=$script:now.AddSeconds(-20)}
}
$passed=0;$failures=[Collections.Generic.List[string]]::new()
function Check($Value,[string]$Name){if($Value){$script:passed++;Write-Host ('PASS: '+$Name)}else{$script:failures.Add($Name);Write-Host ('FAIL: '+$Name)}}
Reset-Cache
$view=Get-UiWorkflowInventoryResponse -MediaRoot 'synthetic-root'
Check (-not $view.Refreshing -and $view.Snapshot.Marker -ceq 'new-synthetic-snapshot' -and $starts -eq 0 -and $removals -eq 1) 'Slow completed inventory is returned without immediate replacement'
Check ($workflowInventory.RequestedAt -eq $now) 'Successful nonempty completion starts the freshness interval'
$view=Get-UiWorkflowInventoryResponse -MediaRoot 'synthetic-root'
Check (-not $view.Refreshing -and $starts -eq 0) 'Fresh completed snapshot is reused'
$script:now=$now.AddSeconds(6)
$view=Get-UiWorkflowInventoryResponse -MediaRoot 'synthetic-root'
Check ($view.Refreshing -and $starts -eq 1) 'Expired snapshot starts exactly one new inventory'
$view=Get-UiWorkflowInventoryResponse -MediaRoot 'synthetic-root'
Check ($view.Refreshing -and $starts -eq 1) 'Active inventory is not duplicated by polling'
Reset-Cache
$null=Get-UiWorkflowInventoryResponse -MediaRoot 'synthetic-root'
$script:starts=0
$view=Get-UiWorkflowInventoryResponse -MediaRoot 'other-synthetic-root'
Check ($view.Refreshing -and $starts -eq 1 -and $workflowInventory.MediaRoot -ceq 'other-synthetic-root') 'Changing media root starts a separate inventory'
foreach($state in @('Failed','Stopped')){
 Reset-Cache $state
 $view=Get-UiWorkflowInventoryResponse -MediaRoot 'synthetic-root'
 Check ($view.Refreshing -and $null -eq $view.Snapshot -and $starts -eq 1 -and $removals -eq 1) ($state+' job does not establish a fresh snapshot')
}
Reset-Cache;$script:received=$null
$view=Get-UiWorkflowInventoryResponse -MediaRoot 'synthetic-root'
Check ($view.Refreshing -and $null -eq $view.Snapshot -and $starts -eq 1 -and $removals -eq 1) 'Empty completed job does not establish a fresh snapshot'
foreach($state in @('Failed','Stopped','Empty')){
 Reset-Cache $(if($state -ceq 'Empty'){'Completed'}else{$state})
 $workflowInventory.Snapshot=[pscustomobject]@{Marker='old-synthetic-snapshot'}
 $oldTimestamp=$workflowInventory.RequestedAt
 if($state -ceq 'Empty'){$script:received=@()}
 Update-UiWorkflowInventory
 Check ($workflowInventory.RequestedAt -eq $oldTimestamp -and $workflowInventory.Snapshot.Marker -ceq 'old-synthetic-snapshot' -and $null -eq $workflowInventory.Job -and $removals -eq 1) ($state+' completion preserves the old snapshot and its expired timestamp')
 $view=Get-UiWorkflowInventoryResponse -MediaRoot 'synthetic-root'
 Check ($view.Refreshing -and $starts -eq 1) ($state+' completion cannot make the old snapshot a cache hit')
}
Write-Host ('Ergebnis: '+$passed+' PASS, '+$failures.Count+' FAIL')
if($failures.Count){exit 1}
