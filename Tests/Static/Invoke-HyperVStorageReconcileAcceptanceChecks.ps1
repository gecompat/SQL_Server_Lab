#Requires -Version 7.2
[CmdletBinding()]param()
$ErrorActionPreference='Stop';$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$path=Join-Path $repoRoot 'Tests/Integration/Invoke-HyperVStorageReconcileAcceptance.ps1';$workflow=Join-Path $repoRoot '.github/workflows/runtime-smoke-hyperv.yml';$source=Get-Content $path -Raw -Encoding utf8;$errors=$null;$null=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$null,[ref]$errors)
. (Join-Path $PSScriptRoot '../Common/HyperVStorageAcceptanceRecoveryFixture.ps1')
$checks=[ordered]@{
 'Early clone failure recovers only this operation; unowned, absent and ambiguous runs remain fail-closed'=(Test-HyperVStorageAcceptanceRecovery -RunnerPath $path)
 'Native storage acceptance is syntactically valid'=($errors.Count -eq 0)
 'Acceptance uses an isolated operation-owned verified Windows 2025 clone'=($source -match 'CloneSourceRunId' -and $source -match 'Parameter\(Mandatory\)\]\[string\]\$CloneSourceRunId' -and $source -match 'New-HyperVResourceAcceptanceSlotClone')
 'Acceptance remains scoped to HV-603 host storage rather than SQL path rebinding'=($source -match 'RepairHyperVStorage' -and $source -notmatch 'RepairHyperVSqlStorage' -and $source -notmatch 'RepairHyperVSqlConfiguration')
 'Manifest-bound SCSI additions use schema-valid drive mappings with free unique host slots and guest postconditions without destructive shrink simulation'=($source -match "id='data';containerPath='E:\\SQLData';sizeLimitGB=4" -and $source -match "id='log';containerPath='L:\\SQLLog';sizeLimitGB=2" -and $source -match 'managedSlots' -and $source -match 'slotBindings' -and $source -match 'Sort-Object -Unique' -and $source -notmatch 'Resize-VHD' -and $source -match 'guestDriveInitialization' -and $source -match 'GUEST_VERIFIED')
 'WhatIf, restart readiness, no-op and scope-bound cleanup are explicit'=($source -match 'RepairHyperVStorage.*-WhatIf' -and $source -match 'Wait-StorageSqlReady' -and $source -match 'Remove-SqlServerLab' -and $source -match 'Wiederholter Storage-Plan ist No-op')
 'Controlled interruption and duplicate-host-mutation evidence is retained as the existing synthetic contract without a production test hook'=($source -match 'controlled HOST_APPLIED interruption/resume' -and $source -match 'does not add a production fault-injection seam')
 'Workflow exposes the native storage acceptance only through manual main dispatch'=((Get-Content $workflow -Raw -Encoding utf8) -match '(?m)^\s*- storage-reconcile-acceptance\s*$' -and (Get-Content $workflow -Raw -Encoding utf8) -match 'HYPERV_STORAGE_RECONCILE_CI_MANUAL_MAIN_REQUIRED' -and (Get-Content $workflow -Raw -Encoding utf8) -match 'Invoke-HyperVStorageReconcileAcceptance\.ps1 @arguments')
}
$failed=@($checks.GetEnumerator()|Where-Object{-not $_.Value});if($failed){throw "Hyper-V storage reconcile acceptance checks failed: $($failed.Key -join ', ')"};Write-Host "Hyper-V Storage Reconcile Acceptance Checks: $($checks.Count) PASS, 0 FAIL" -ForegroundColor Green
