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
. (Join-Path $repo 'Private/BatchBrowserOverview.ps1')
$validBatch=[pscustomobject]@{
 batchId='batch-20261121080000-1234abcd';status='Running';progress=[pscustomobject]@{percent=25.5;total=4}
 errorStatus=[pscustomobject]@{failed=1;cancelled=0};defaults=@{Secret='synthetic-private-value'}
 manifestSource=@{Path='synthetic-private-path'}
}
$filtered=@(Get-LabBrowserBatchOverview -Batches @($validBatch,[pscustomobject]@{batchId='batch-20261121080000-1234abcd';status='Running'}))
Check ($filtered.Count -eq 1 -and $filtered[0].BatchId -ceq $validBatch.batchId -and $filtered[0].Percent -eq 25.5 -and
 ($filtered|ConvertTo-Json -Depth 8) -notmatch 'synthetic-private|defaults|manifestSource') 'Browser projection keeps only bounded batch progress and excludes operation input'
$terminal = @(1..55 | ForEach-Object {
    [pscustomobject]@{contract='SqlServerLab.Operation/1.0';batchId=$validBatch.batchId;operationId="op-$($validBatch.batchId)-slot-$_"
        status='Failed';provider='docker';completedAt=$script:now.AddMinutes($_).ToString('o');executor=@{Secret='synthetic-private-value'}
        error=@{message='synthetic-private-path'};cleanupResult=@{remaining=@('synthetic-private-value')}}
})
$otherBatch = $terminal[0].PSObject.Copy();$otherBatch.batchId='batch-20261121090000-3234abcd'
$open = $terminal[0].PSObject.Copy();$open.status='Running'
$malformed = $terminal[0].PSObject.Copy();$malformed.completedAt='2026-01-01T00:00:00.0000000'
$inventory=ConvertTo-LabBrowserWorkflowInventory -Snapshot ([pscustomobject]@{Batches=@($validBatch);Operations=@($terminal + @($otherBatch,$open,$malformed,$null))})
Check ($inventory.OperationHistory.Count -eq 50 -and $inventory.OperationHistory[0].OperationId -like '*-55' -and
    $inventory.OperationHistory[-1].OperationId -like '*-6' -and @($inventory.OperationHistory | Where-Object Status -CNE 'Failed').Count -eq 0) 'Terminal history is bound to batch and exact UTC date, newest first with a maximum of 50 entries'
Check ($null -eq $inventory.PSObject.Properties['Operations'] -and ($inventory | ConvertTo-Json -Depth 12) -notmatch
    'synthetic-private|executor|cleanupResult|manifestSource') 'Workflow browser snapshot replaces raw operation details with a bounded safe projection'
Write-Host ('Ergebnis: '+$passed+' PASS, '+$failures.Count+' FAIL')
if($failures.Count){exit 1}
