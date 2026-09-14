#Requires -Version 7.2
$ErrorActionPreference='Stop'
$repoRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$acceptancePath=Join-Path $repoRoot 'Tests/Integration/Invoke-HyperVResourceReconcileAcceptance.ps1'
$ciPath=Join-Path $repoRoot 'Tests/Integration/Invoke-HyperVResourceReconcileCiAcceptance.ps1'
$workflowPath=Join-Path $repoRoot '.github/workflows/runtime-smoke-hyperv.yml'
$acceptance=Get-Content -LiteralPath $acceptancePath -Raw -Encoding utf8
$ci=Get-Content -LiteralPath $ciPath -Raw -Encoding utf8
$workflow=Get-Content -LiteralPath $workflowPath -Raw -Encoding utf8
$tokens=$null;$errors=$null;[Management.Automation.Language.Parser]::ParseFile($acceptancePath,[ref]$tokens,[ref]$errors)|Out-Null
$ciTokens=$null;$ciErrors=$null;[Management.Automation.Language.Parser]::ParseFile($ciPath,[ref]$ciTokens,[ref]$ciErrors)|Out-Null
function Add-Check {param([string]$Name,[bool]$Success);Write-Host ('  {0}  {1}' -f $(if($Success){'PASS'}else{'FAIL'}),$Name) -ForegroundColor $(if($Success){'Green'}else{'Red'});[pscustomobject]@{Name=$Name;Success=$Success}}
$checks=@(
 Add-Check 'Native- und CI-Runner sind syntaktisch gueltig' ($errors.Count -eq 0 -and $ciErrors.Count -eq 0)
 Add-Check 'Native Runner erzeugt genau zwei operationgebundene SQL-2025-Prepared-Runs' ($acceptance -match '\$Run1OperationId' -and $acceptance -match '\$Run2OperationId' -and $acceptance -match 'DeferCleanup' -and $acceptance -match 'Invoke-WithLabWorkflowOperationContext' -and $acceptance -match "artifactState -eq 'SQL_PREPARED_SEALED'" -and $acceptance -match "sql.version -eq '2025'")
 Add-Check 'Dynamischer und statischer Ressourcenfall pruefen Plan, WhatIf, Apply und No-op' ($acceptance -match 'DynamicMemoryEnabled' -and $acceptance -match 'ProcessorCount' -and $acceptance -match 'Get-SqlServerLabReconcilePlan.*-HyperVResources' -and $acceptance -match 'Invoke-SqlServerLabReconcileAction.*-RepairHyperVResources.*-WhatIf' -and $acceptance -match 'Dynamischer Wiederholungsplan ist No-op' -and $acceptance -match 'Statischer Wiederholungsplan ist No-op')
 Add-Check 'Static-Apply prueft CPU, RAM-Modus, SQL-Readiness und Datenmarker' ($acceptance -match 'CPU-, Startup-RAM- und Modusdrift' -and $acceptance -match 'SqlLabHvResourceMarker' -and $acceptance -match 'Restart-Reconcile stellt CPU, statischen RAM, SQL-Readiness und Datenmarker wieder her')
 Add-Check 'Native Failure-Injection wird nicht behauptet' ($acceptance -match '(?s)Runner injiziert keinen.*bleibt daher bewusst offen' -and $acceptance -notmatch 'Mock\s+Start-VM')
 Add-Check 'Supervisor begrenzt den Childprozess, validiert eine kleine Receipt und bereinigt nur operationgebundene Runs' ($ci -match 'RunnerTimeoutSeconds' -and $ci -match 'DeferCleanup' -and $ci -match 'Test-HyperVResourceReconcileCiStageReceipt' -and $ci -match 'Stop-HyperVResourceReconcileCiChildProcessTree' -and $ci -match 'Get-LabOperationOwnedRun' -and $ci -match 'Get-HyperVManagedVM.*-ExpectedRunId.*-ExpectedScopeId' -and $ci -match 'Remove-SqlServerLab -RunId \$RunId -StateRoot \$Root -Force -Confirm:\$false')
 Add-Check 'Workflow erlaubt den nativen Modus nur manuell auf main und uebergibt ArtifactId ueber Environment' ($workflow -match '(?s)workflow_dispatch:.*resource-reconcile-acceptance' -and $workflow -match "github\.event_name == 'workflow_dispatch' && github\.ref == 'refs/heads/main' && inputs\.mode == 'resource-reconcile-acceptance'" -and $workflow -match "inputs\.mode == 'resource-reconcile-acceptance' && !\(github\.event_name == 'workflow_dispatch' && github\.ref == 'refs/heads/main'\)" -and $workflow -match 'HYPERV_RESOURCE_RECONCILE_CI_MANUAL_MAIN_REQUIRED' -and $workflow -match 'SQL_SERVER_LAB_CI_IMAGE_ARTIFACT_ID' -and $workflow -match 'Invoke-HyperVResourceReconcileCiAcceptance\.ps1 @arguments')
)
$failed=@($checks|Where-Object{-not $_.Success});if($failed){throw "Hyper-V resource reconcile acceptance checks failed: $($failed.Name -join ', ')"};Write-Host "Hyper-V Resource Reconcile Acceptance Checks: $($checks.Count) PASS, 0 FAIL" -ForegroundColor Green
