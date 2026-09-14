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
$ciTokens=$null;$ciErrors=$null;$ciAst=[Management.Automation.Language.Parser]::ParseFile($ciPath,[ref]$ciTokens,[ref]$ciErrors)
function Add-Check {param([string]$Name,[bool]$Success);Write-Host ('  {0}  {1}' -f $(if($Success){'PASS'}else{'FAIL'}),$Name) -ForegroundColor $(if($Success){'Green'}else{'Red'});[pscustomobject]@{Name=$Name;Success=$Success}}
function Test-StageReceiptContract {
    $functionAst=@($ciAst.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Test-HyperVResourceReconcileCiStageReceipt'},$true))[0]
    if(-not $functionAst){return $false}
    $root=Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-hv-resource-reconcile-static-'+[guid]::NewGuid().ToString('N'))
    try {
        $null=New-Item -ItemType Directory -Path $root -Force
        . ([scriptblock]::Create($functionAst.Extent.Text))
        $receiptPath=Join-Path $root 'stage-receipt.json'
        [IO.File]::WriteAllText($receiptPath,'{"status":"FAILED","stage":"RUNNER_FAILED","reasonCode":"HYPERV_RESOURCE_RECONCILE_ACCEPTANCE_STAGE_DYNAMIC_LIVE_DRIFT_FAILED"}',[Text.UTF8Encoding]::new($false))
        $valid=Test-HyperVResourceReconcileCiStageReceipt -ReceiptPath $receiptPath
        [IO.File]::WriteAllText($receiptPath,'{"status":"FAILED","stage":"RUNNER_FAILED","reasonCode":"HYPERV_RESOURCE_RECONCILE_CI_EXECUTION_FAILED"}',[Text.UTF8Encoding]::new($false))
        $generic=Test-HyperVResourceReconcileCiStageReceipt -ReceiptPath $receiptPath
        [IO.File]::WriteAllText($receiptPath,'{"status":"FAILED","stage":"RUNNER_FAILED","reasonCode":null}',[Text.UTF8Encoding]::new($false))
        $missing=Test-HyperVResourceReconcileCiStageReceipt -ReceiptPath $receiptPath
        return $valid -and $valid.ReasonCode -ceq 'HYPERV_RESOURCE_RECONCILE_ACCEPTANCE_STAGE_DYNAMIC_LIVE_DRIFT_FAILED' -and -not $generic -and -not $missing
    } catch { return $false } finally { if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue} }
}function Test-RunnerReasonCodeContract {
    $functionAst=@($ciAst.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-HyperVResourceReconcileCiRunnerReasonCode'},$true))[0]
    if(-not $functionAst){return $false}
    try {
        . ([scriptblock]::Create($functionAst.Extent.Text))
        $stage=@(Get-HyperVResourceReconcileCiRunnerReasonCode -RunnerOutput @('HYPERV_RESOURCE_RECONCILE_ACCEPTANCE_STAGE_DYNAMIC_LIVE_DRIFT_FAILED'))
        $legacy=@(Get-HyperVResourceReconcileCiRunnerReasonCode -RunnerOutput @('HYPERV_RESOURCE_ACCEPTANCE_FAILED: local detail'))
        $unknown=@(Get-HyperVResourceReconcileCiRunnerReasonCode -RunnerOutput @('HYPERV_RESOURCE_RECONCILE_CI_EXECUTION_FAILED'))
        return $stage.Count -eq 1 -and $stage[0] -ceq 'HYPERV_RESOURCE_RECONCILE_ACCEPTANCE_STAGE_DYNAMIC_LIVE_DRIFT_FAILED' -and $legacy.Count -eq 1 -and $legacy[0] -ceq 'HYPERV_RESOURCE_RECONCILE_ACCEPTANCE_STAGE_LEGACY_UNCLASSIFIED_FAILED' -and $unknown.Count -eq 0
    } catch { return $false }
}
$checks=@(
 Add-Check 'Native- und CI-Runner sind syntaktisch gueltig' ($errors.Count -eq 0 -and $ciErrors.Count -eq 0)
 Add-Check 'Native Runner erzeugt genau zwei operationgebundene SQL-2025-Prepared-Runs' ($acceptance -match '\$Run1OperationId' -and $acceptance -match '\$Run2OperationId' -and $acceptance -match 'DeferCleanup' -and $acceptance -match 'Invoke-WithLabWorkflowOperationContext' -and $acceptance -match "artifactState -eq 'SQL_PREPARED_SEALED'" -and $acceptance -match "sql.version -eq '2025'")
 Add-Check 'Dynamischer und statischer Ressourcenfall pruefen Plan, WhatIf, Apply und No-op' ($acceptance -match 'DynamicMemoryEnabled' -and $acceptance -match 'ProcessorCount' -and $acceptance -match 'Get-SqlServerLabReconcilePlan.*-HyperVResources' -and $acceptance -match 'Invoke-SqlServerLabReconcileAction.*-RepairHyperVResources.*-WhatIf' -and $acceptance -match 'Dynamischer Wiederholungsplan ist No-op' -and $acceptance -match 'Statischer Wiederholungsplan ist No-op')
 Add-Check 'Dynamic-Apply prueft gestoppte einengende Drift, Restart, SQL-Readiness und bereichserweiternde Live-Reparatur' ($acceptance -match 'einengende dynamische Drift gestoppt' -and $acceptance -match 'DYNAMIC_FORBIDDEN_PLAN' -and $acceptance -match 'HYPERV_RESOURCE_RECONCILE_LIVE_DIRECTION_RESTART_REQUIRED' -and $acceptance -match 'DYNAMIC_LIVE_PLAN' -and $acceptance -match 'tempdb-Marker ohne Restart wieder her')
 Add-Check 'Static-Apply prueft CPU, RAM-Modus, SQL-Readiness und persistenten Datenmarker mit normalisierten Werten' ($acceptance -match 'CREATE DATABASE SqlLabHvResourceMarkerDb' -and $acceptance -match 'Wait-ResourcePersistentSqlMarker' -and $acceptance -match 'Minimum=if\(\$dynamic\)' -and $acceptance -match 'Restart-Reconcile stellt CPU, statischen RAM, SQL-Readiness und persistenten Datenmarker wieder her')
 Add-Check 'Native Runner emittiert nur allowlistgebundene Fehlerstufen ohne Rohfehler' ($acceptance -match "\`$allowedStages=@\('INITIALIZATION'" -and $acceptance -match 'HYPERV_RESOURCE_RECONCILE_ACCEPTANCE_STAGE_\$\{safeStage\}_FAILED' -and $acceptance -notmatch 'throw "HYPERV_RESOURCE_RECONCILE_ACCEPTANCE_STAGE_\$\{safeStage\}_FAILED: \$\(')
 Add-Check 'Native Failure-Injection wird nicht behauptet' ($acceptance -match '(?s)Runner injiziert keinen.*bleibt daher bewusst offen' -and $acceptance -notmatch 'Mock\s+Start-VM')
 Add-Check 'Supervisor extrahiert nur feste Stufencodes und ordnet Legacyfehler sicher zu' (Test-RunnerReasonCodeContract)
 Add-Check 'Receipt akzeptiert nur eine feste Fehlerstufe und weist generische Codes ab' (Test-StageReceiptContract)
 Add-Check 'Child verwendet dieselbe feste Stufen- und Legacyallowlist' ($ci -match '(?s)function Get-ReasonCode \{.*?HYPERV_RESOURCE_RECONCILE_ACCEPTANCE_STAGE_.*?LEGACY_UNCLASSIFIED.*?return @\(\)')
 Add-Check 'Supervisor validiert nur die feste Stufenallowlist in der Receipt' ($ci -match "reasonCode -notmatch '\^HYPERV_RESOURCE_RECONCILE_ACCEPTANCE_STAGE_" -and $ci -match 'LEGACY_UNCLASSIFIED')
 Add-Check 'Supervisor begrenzt den Childprozess, validiert eine kleine Receipt und bereinigt nur operationgebundene Runs' ($ci -match 'RunnerTimeoutSeconds' -and $ci -match 'DeferCleanup' -and $ci -match 'Test-HyperVResourceReconcileCiStageReceipt' -and $ci -match 'Stop-HyperVResourceReconcileCiChildProcessTree' -and $ci -match 'Get-LabOperationOwnedRun' -and $ci -match 'Get-HyperVManagedVM.*-ExpectedRunId.*-ExpectedScopeId' -and $ci -match 'Remove-SqlServerLab -RunId \$RunId -StateRoot \$Root -Force -Confirm:\$false')
 Add-Check 'Workflow erlaubt den nativen Modus nur manuell auf main und uebergibt ArtifactId ueber Environment' ($workflow -match '(?s)workflow_dispatch:.*resource-reconcile-acceptance' -and $workflow -match "github\.event_name == 'workflow_dispatch' && github\.ref == 'refs/heads/main' && inputs\.mode == 'resource-reconcile-acceptance'" -and $workflow -match "inputs\.mode == 'resource-reconcile-acceptance' && !\(github\.event_name == 'workflow_dispatch' && github\.ref == 'refs/heads/main'\)" -and $workflow -match 'HYPERV_RESOURCE_RECONCILE_CI_MANUAL_MAIN_REQUIRED' -and $workflow -match 'SQL_SERVER_LAB_CI_IMAGE_ARTIFACT_ID' -and $workflow -match 'Invoke-HyperVResourceReconcileCiAcceptance\.ps1 @arguments')
)
$failed=@($checks|Where-Object{-not $_.Success});if($failed){throw "Hyper-V resource reconcile acceptance checks failed: $($failed.Name -join ', ')"};Write-Host "Hyper-V Resource Reconcile Acceptance Checks: $($checks.Count) PASS, 0 FAIL" -ForegroundColor Green
