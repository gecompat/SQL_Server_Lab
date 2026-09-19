#Requires -Version 7.2
[CmdletBinding()]param()
$ErrorActionPreference='Stop';$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$path=Join-Path $repoRoot 'Tests/Integration/Invoke-HyperVSqlStorageReconcileAcceptance.ps1';$workflow=Join-Path $repoRoot '.github/workflows/runtime-smoke-hyperv.yml';$source=Get-Content $path -Raw -Encoding utf8;$errors=$null;$null=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$null,[ref]$errors)
# Execute only the runner's pure comparison block; never bootstrap Hyper-V here.
$comparisonStart=$source.IndexOf('    $expected=@($receiptAfter.FileBindings)')
$comparisonEnd=$source.IndexOf('    $resultOk=', $comparisonStart)
if($comparisonStart -lt 0 -or $comparisonEnd -le $comparisonStart){throw 'Acceptance comparison block not found'}
$comparison=[scriptblock]::Create($source.Substring($comparisonStart,$comparisonEnd-$comparisonStart)+"`n[pscustomobject]@{Defaults=`$defaultsOk;TempDb=`$tempOk}")
function Test-ComparisonCase {
 param([string]$Case)
 $bindings=@(
  [pscustomobject]@{Role='default-data';SqlPhysicalPath='F:\SQLData'}
  [pscustomobject]@{Role='default-log';SqlPhysicalPath='F:\SQLLog'}
  [pscustomobject]@{Role='backup';SqlPhysicalPath='F:\Backup'}
  [pscustomobject]@{Role='tempdb-data';LogicalName='tempdev';SqlPhysicalPath='F:\Temp\tempdb.mdf'}
  [pscustomobject]@{Role='tempdb-log';LogicalName='templog';SqlPhysicalPath='F:\Temp\templog.ldf'}
 )
 $receiptAfter=[pscustomobject]@{FileBindings=$bindings}
 $after=[pscustomobject]@{Defaults=[pscustomobject]@{DefaultData='f:\SQLData\';DefaultLog='F:\SQLLog\';BackupDirectory='F:\Backup'};TempDb=@($bindings|Where-Object Role -like 'tempdb-*'|ForEach-Object{[pscustomobject]@{LogicalName=$_.LogicalName;SqlPhysicalPath=$_.SqlPhysicalPath}})}
 switch($Case){
  'WrongDefault' {$after.Defaults.DefaultData='F:\Other'}
  'EmptyDefault' {$bindings[0].SqlPhysicalPath='';$after.Defaults.DefaultData=''}
  'MissingTempDb' {$after.TempDb=@($after.TempDb[0])}
  'DuplicateTempDb' {$after.TempDb+= $after.TempDb[0]}
  'WrongTempDb' {$after.TempDb[0].SqlPhysicalPath='F:\Other\tempdb.mdf'}
 }
 & $comparison
}
$valid=Test-ComparisonCase 'Valid'
. (Join-Path $PSScriptRoot '../Common/HyperVStorageAcceptanceRecoveryFixture.ps1')
$checks=[ordered]@{
 'Early clone failure recovers only this operation; unowned, absent and ambiguous runs remain fail-closed'=(Test-HyperVStorageAcceptanceRecovery -RunnerPath $path)
 'Directory delimiters and case do not reject converged SQL paths'=($valid.Defaults -and $valid.TempDb)
 'Different and empty default directories remain rejected'=(-not (Test-ComparisonCase 'WrongDefault').Defaults -and -not (Test-ComparisonCase 'EmptyDefault').Defaults)
 'Missing duplicate and misplaced TempDB files remain rejected'=(-not (Test-ComparisonCase 'MissingTempDb').TempDb -and -not (Test-ComparisonCase 'DuplicateTempDb').TempDb -and -not (Test-ComparisonCase 'WrongTempDb').TempDb)
 'Native SQL storage acceptance is syntactically valid'=($errors.Count -eq 0)
 'Acceptance requires an operation-owned Windows 2025 clone with verified SQL media and denied egress'=($source -match 'Parameter\(Mandatory\)\]\[string\]\$CloneSourceRunId' -and $source -match 'Parameter\(Mandatory\)\]\[string\]\$MediaRoot' -and $source -match 'New-HyperVResourceAcceptanceSlotClone' -and $source -match "Strategy='VerifyOnly'" -and $source -match "EgressPolicy='Denied'")
 'Host storage is reconciled from a schema-valid bound storage intent and no-op before SQL storage mutation'=($source -match "placementPolicy='logical-only'" -and $source -match "dataFileCount=4" -and $source -match "defaultData=\[ordered\]@\{selector='default'\}" -and $source -match "defaultLog=\[ordered\]@\{selector='default'\}" -and $source -match 'New-LabStorageBoundPlan' -and $source -match 'storage-bound-plan\.json' -and $source -match '\$hostReasonCodes' -and $source -match "HighestChangeClass -in @\('live','restart'\)" -and $source -match 'Actions\[0\]\.Operation' -and $source -match 'Start-VM -VM \$VM' -and $source -match 'HV-603 ist vor SQL-Mutation No-op' -and $source -match 'RepairHyperVSqlStorage')
 'SQL paths are verified solely through the runtime receipt produced after SQL reconciliation'=($source -match 'storage-runtime-receipt\.json' -and $source -match 'HV-603 persistiert noch keinen SQL-Runtime-Receipt' -and $source -match 'receiptAfter\.FileBindings' -and $source -match 'Get-SqlStorageObservation')
 'Applied SQL reconciliation inspects the public execution-plan result'=($source -match 'result\.ExecutionPlan\[0\]\.Result\.ReceiptStatus' -and $source -notmatch 'result\.Actions\[0\]\.Result\.ReceiptStatus')
 'Failed convergence reports component-level evidence without SQL paths'=($source -match '\$convergenceEvidence' -and $source -match 'result=\$resultOk' -and $source -match 'tempdb=\$tempOk' -and $source -match 'defaultsDetail=' -and $source -match 'tempdbDetail=' -and $source -notmatch 'SqlPhysicalPath.*convergenceEvidence')
 'WhatIf, service-only restart, no-op and scope-bound cleanup are explicit'=($source -match 'RepairHyperVSqlStorage.*-WhatIf' -and $source -match 'SqlStartTime -ne' -and $source -match 'bootAfter -eq \$bootBefore' -and $source -match 'Wiederholter HV-603A-Plan ist No-op' -and $source -match 'Remove-SqlServerLab')
 'Synthetic fault resume remains separate and no production injection seam is introduced'=($source -match 'Fault/resume injection remains in the synthetic contract' -and $source -match 'does\s+not add a production fault-injection seam' -and $source -notmatch 'Resize-VHD')
 'Workflow exposes the acceptance only through manual main dispatch with a clone source'=((Get-Content $workflow -Raw -Encoding utf8) -match '(?m)^\s*- sql-storage-reconcile-acceptance\s*$' -and (Get-Content $workflow -Raw -Encoding utf8) -match 'HYPERV_SQL_STORAGE_RECONCILE_CI_MANUAL_MAIN_REQUIRED' -and (Get-Content $workflow -Raw -Encoding utf8) -match 'HYPERV_SQL_STORAGE_RECONCILE_CI_CLONE_SOURCE_REQUIRED' -and (Get-Content $workflow -Raw -Encoding utf8) -match 'Invoke-HyperVSqlStorageReconcileAcceptance\.ps1 @arguments')
}
$failed=@($checks.GetEnumerator()|Where-Object{-not $_.Value});if($failed){throw "Hyper-V SQL storage reconcile acceptance checks failed: $($failed.Key -join ', ')"};Write-Host "Hyper-V SQL Storage Reconcile Acceptance Checks: $($checks.Count) PASS, 0 FAIL" -ForegroundColor Green
