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
        [IO.File]::WriteAllText($receiptPath,'{"status":"FAILED","stage":"RUNNER_FAILED","reasonCode":"HYPERV_RESOURCE_RECONCILE_ACCEPTANCE_STAGE_DYNAMIC_LIVE_SHUTDOWN_READINESS_FAILED","activationReasonCode":null}',[Text.UTF8Encoding]::new($false))
        $valid=Test-HyperVResourceReconcileCiStageReceipt -ReceiptPath $receiptPath
        [IO.File]::WriteAllText($receiptPath,'{"status":"FAILED","stage":"RUNNER_FAILED","reasonCode":"HYPERV_RESOURCE_RECONCILE_ACCEPTANCE_STAGE_DYNAMIC_PROVISION_FAILED","activationReasonCode":"WINDOWS_ACTIVATION_REQUIRED"}',[Text.UTF8Encoding]::new($false))
        $activation=Test-HyperVResourceReconcileCiStageReceipt -ReceiptPath $receiptPath
        [IO.File]::WriteAllText($receiptPath,'{"status":"FAILED","stage":"RUNNER_FAILED","reasonCode":"HYPERV_RESOURCE_RECONCILE_ACCEPTANCE_STAGE_DYNAMIC_PROVISION_FAILED","activationReasonCode":"raw failure detail"}',[Text.UTF8Encoding]::new($false))
        $unsafeActivation=Test-HyperVResourceReconcileCiStageReceipt -ReceiptPath $receiptPath
        [IO.File]::WriteAllText($receiptPath,'{"status":"FAILED","stage":"RUNNER_FAILED","reasonCode":"HYPERV_RESOURCE_RECONCILE_CI_EXECUTION_FAILED","activationReasonCode":null}',[Text.UTF8Encoding]::new($false))
        $generic=Test-HyperVResourceReconcileCiStageReceipt -ReceiptPath $receiptPath
        [IO.File]::WriteAllText($receiptPath,'{"status":"FAILED","stage":"RUNNER_FAILED","reasonCode":null,"activationReasonCode":null}',[Text.UTF8Encoding]::new($false))
        $missing=Test-HyperVResourceReconcileCiStageReceipt -ReceiptPath $receiptPath
        return $valid -and $valid.ReasonCode -ceq 'HYPERV_RESOURCE_RECONCILE_ACCEPTANCE_STAGE_DYNAMIC_LIVE_SHUTDOWN_READINESS_FAILED' -and -not $valid.ActivationReasonCode -and $activation -and $activation.ActivationReasonCode -ceq 'WINDOWS_ACTIVATION_REQUIRED' -and -not $unsafeActivation -and -not $generic -and -not $missing
    } catch { return $false } finally { if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue} }
}function Test-RunnerReasonCodeContract {
    $functionAst=@($ciAst.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-HyperVResourceReconcileCiRunnerReasonCode'},$true))[0]
    if(-not $functionAst){return $false}
    try {
        . ([scriptblock]::Create($functionAst.Extent.Text))
        $stage=@(Get-HyperVResourceReconcileCiRunnerReasonCode -RunnerOutput @('HYPERV_RESOURCE_RECONCILE_ACCEPTANCE_STAGE_DYNAMIC_LIVE_SHUTDOWN_READINESS_FAILED'))
        $legacy=@(Get-HyperVResourceReconcileCiRunnerReasonCode -RunnerOutput @('HYPERV_RESOURCE_ACCEPTANCE_FAILED: local detail'))
        $unknown=@(Get-HyperVResourceReconcileCiRunnerReasonCode -RunnerOutput @('HYPERV_RESOURCE_RECONCILE_CI_EXECUTION_FAILED'))
        return $stage.Count -eq 1 -and $stage[0] -ceq 'HYPERV_RESOURCE_RECONCILE_ACCEPTANCE_STAGE_DYNAMIC_LIVE_SHUTDOWN_READINESS_FAILED' -and $legacy.Count -eq 1 -and $legacy[0] -ceq 'HYPERV_RESOURCE_RECONCILE_ACCEPTANCE_STAGE_LEGACY_UNCLASSIFIED_FAILED' -and $unknown.Count -eq 0
    } catch { return $false }
}
function Test-ActivationReasonContract {
    $acceptanceAst=[Management.Automation.Language.Parser]::ParseFile($acceptancePath,[ref]$null,[ref]$null)
    $functionAst=@($acceptanceAst.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-HyperVResourceReconcileAcceptanceActivationReasonCode'},$true))[0]
    $transportAst=@($ciAst.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-HyperVResourceReconcileCiActivationReasonCode'},$true))[0]
    if(-not $functionAst -or -not $transportAst){return $false}
    try {
        . ([scriptblock]::Create($functionAst.Extent.Text))
        . ([scriptblock]::Create($transportAst.Extent.Text))
        $known=$null;$unknown=$null
        try{throw 'WINDOWS_ACTIVATION_REQUIRED: private detail'}catch{$known=Get-HyperVResourceReconcileAcceptanceActivationReasonCode -ErrorRecord $_}
        try{throw 'private failure detail'}catch{$unknown=Get-HyperVResourceReconcileAcceptanceActivationReasonCode -ErrorRecord $_}
        $transport=@(Get-HyperVResourceReconcileCiActivationReasonCode -RunnerOutput @('HYPERV_RESOURCE_RECONCILE_ACCEPTANCE_STAGE_DYNAMIC_PROVISION_FAILED WINDOWS_ACTIVATION_REQUIRED'))
        $ignored=@(Get-HyperVResourceReconcileCiActivationReasonCode -RunnerOutput @('private failure detail'))
        return $known -ceq 'WINDOWS_ACTIVATION_REQUIRED' -and $unknown -ceq 'HYPERV_RESOURCE_RECONCILE_ACCEPTANCE_ACTIVATION_REASON_UNCLASSIFIED' -and $transport.Count -eq 1 -and $transport[0] -ceq 'WINDOWS_ACTIVATION_REQUIRED' -and $ignored.Count -eq 0
    } catch { return $false }
}
function Test-ShutdownIntegrationReadinessContract {
    $acceptanceAst=[Management.Automation.Language.Parser]::ParseFile($acceptancePath,[ref]$null,[ref]$null)
    $functionAst=@($acceptanceAst.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Wait-ResourceShutdownIntegrationReady'},$true))[0]
    if(-not $functionAst){return $false}
    $body=$functionAst.Extent.Text
    return $body -match '9F8233AC-BE49-4C79-8EE3-E7E1985B2077' -and $body -match 'shutdownService\.Enabled' -and $body -match 'PrimaryOperationalStatus\s+-eq\s+2' -and $body -notmatch 'PrimaryStatusDescription'
}
function Test-DynamicRestartReadinessOrdering {
    $applyIndex=$acceptance.IndexOf("`$stage='DYNAMIC_FORBIDDEN_APPLY'")
    $sqlIndex=$acceptance.IndexOf("`$stage='DYNAMIC_RESTART_SQL_READINESS'")
    $shutdownIndex=$acceptance.IndexOf("`$stage='DYNAMIC_RESTART_SHUTDOWN_READINESS'")
    $stopIndex=$acceptance.IndexOf("`$stage='DYNAMIC_LIVE_STOP'")
    if($applyIndex -lt 0 -or $sqlIndex -le $applyIndex -or $shutdownIndex -le $sqlIndex -or $stopIndex -le $shutdownIndex){return $false}
    $sqlSlice=$acceptance.Substring($sqlIndex,$shutdownIndex-$sqlIndex)
    $shutdownSlice=$acceptance.Substring($shutdownIndex,$stopIndex-$shutdownIndex)
    return $sqlSlice.IndexOf('Wait-ResourceSqlReady $dynamicContext $sa') -ge 0 -and $sqlSlice.IndexOf('Wait-ResourceShutdownIntegrationReady $dynamicContext') -lt 0 -and $shutdownSlice.IndexOf('Wait-ResourceShutdownIntegrationReady $dynamicContext') -ge 0 -and $shutdownSlice.IndexOf('Wait-ResourceSqlReady $dynamicContext $sa') -lt 0
}
function Test-DynamicLiveOrdering {
    $stopStageIndex=$acceptance.IndexOf("`$stage='DYNAMIC_LIVE_STOP'")
    $configureStageIndex=$acceptance.IndexOf("`$stage='DYNAMIC_LIVE_CONFIGURE'")
    $startStageIndex=$acceptance.IndexOf("`$stage='DYNAMIC_LIVE_START'")
    $verifyStageIndex=$acceptance.IndexOf("`$stage='DYNAMIC_LIVE_VERIFY'")
    $sqlStageIndex=$acceptance.IndexOf("`$stage='DYNAMIC_LIVE_SQL_READINESS'")
    $shutdownStageIndex=$acceptance.IndexOf("`$stage='DYNAMIC_LIVE_SHUTDOWN_READINESS'")
    $planIndex=$acceptance.IndexOf("`$stage='DYNAMIC_LIVE_PLAN'")
    if($stopStageIndex -lt 0 -or $configureStageIndex -le $stopStageIndex -or $startStageIndex -le $configureStageIndex -or $verifyStageIndex -le $startStageIndex -or $sqlStageIndex -le $verifyStageIndex -or $shutdownStageIndex -le $sqlStageIndex -or $planIndex -le $shutdownStageIndex){return $false}
    $slice=$acceptance.Substring($stopStageIndex,$planIndex-$stopStageIndex)
    $stopIndex=$slice.IndexOf('Stop-VM -VM $dynamicVm')
    $setIndex=$slice.IndexOf('MinimumBytes 2048MB')
    $startIndex=$slice.IndexOf('Start-VM -VM $dynamicVm')
    $sqlReadyIndex=$slice.IndexOf('Wait-ResourceSqlReady $dynamicContext $sa')
    $shutdownReadyIndex=$slice.IndexOf('Wait-ResourceShutdownIntegrationReady $dynamicContext')
    $markerIndex=$slice.IndexOf('CREATE TABLE tempdb.dbo.SqlLabHvResourceMarker')
    return $stopIndex -ge 0 -and $setIndex -gt $stopIndex -and $startIndex -gt $setIndex -and $sqlReadyIndex -gt $startIndex -and $shutdownReadyIndex -gt $sqlReadyIndex -and $markerIndex -gt $shutdownReadyIndex
}
$checks=@(
 Add-Check 'Native- und CI-Runner sind syntaktisch gueltig' ($errors.Count -eq 0 -and $ciErrors.Count -eq 0)
 Add-Check 'Native Runner erzeugt genau zwei operationgebundene SQL-2025-Prepared-Runs' ($acceptance -match '\$Run1OperationId' -and $acceptance -match '\$Run2OperationId' -and $acceptance -match 'DeferCleanup' -and $acceptance -match 'Invoke-WithLabWorkflowOperationContext' -and $acceptance -match "artifactState -eq 'SQL_PREPARED_SEALED'" -and $acceptance -match "sql.version -eq '2025'")
 Add-Check 'Dynamischer und statischer Ressourcenfall pruefen Plan, WhatIf, Apply und No-op' ($acceptance -match 'DynamicMemoryEnabled' -and $acceptance -match 'ProcessorCount' -and $acceptance -match 'Get-SqlServerLabReconcilePlan.*-HyperVResources' -and $acceptance -match 'Invoke-SqlServerLabReconcileAction.*-RepairHyperVResources.*-WhatIf' -and $acceptance -match 'Dynamischer Wiederholungsplan ist No-op' -and $acceptance -match 'Statischer Wiederholungsplan ist No-op')
 Add-Check 'Dynamic-Apply prueft gestoppte einengende Drift, getrennte Restart- und Live-Readiness sowie bereichserweiternde Live-Reparatur' ($acceptance -match 'einengende dynamische Drift gestoppt' -and $acceptance -match 'DYNAMIC_FORBIDDEN_PLAN' -and $acceptance -match 'HYPERV_RESOURCE_RECONCILE_LIVE_DIRECTION_RESTART_REQUIRED' -and $acceptance -match 'DYNAMIC_LIVE_PLAN' -and $acceptance -match 'tempdb-Marker ohne Restart wieder her' -and (Test-DynamicRestartReadinessOrdering) -and (Test-DynamicLiveOrdering))
 Add-Check 'Shutdown-Readiness verwendet die feste Shutdown-GUID und den lokalisierungsfreien operativen Status' (Test-ShutdownIntegrationReadinessContract)
 Add-Check 'Static-Apply prueft CPU, RAM-Modus, SQL-Readiness und persistenten Datenmarker mit normalisierten Werten' ($acceptance -match 'CREATE DATABASE SqlLabHvResourceMarkerDb' -and $acceptance -match 'Wait-ResourcePersistentSqlMarker' -and $acceptance -match 'Minimum=if\(\$dynamic\)' -and $acceptance -match 'Restart-Reconcile stellt CPU, statischen RAM, SQL-Readiness und persistenten Datenmarker wieder her')
 Add-Check 'Native Runner emittiert nur allowlistgebundene Fehlerstufen ohne Rohfehler' ($acceptance -match "\`$allowedStages=@\('INITIALIZATION'" -and $acceptance -match 'HYPERV_RESOURCE_RECONCILE_ACCEPTANCE_STAGE_\$\{safeStage\}_FAILED' -and $acceptance -notmatch 'throw "HYPERV_RESOURCE_RECONCILE_ACCEPTANCE_STAGE_\$\{safeStage\}_FAILED: \$\(')
 Add-Check 'Native Failure-Injection wird nicht behauptet' ($acceptance -match '(?s)Runner injiziert keinen.*bleibt daher bewusst offen' -and $acceptance -notmatch 'Mock\s+Start-VM')
 Add-Check 'Supervisor extrahiert nur feste Stufencodes und ordnet Legacyfehler sicher zu' (Test-RunnerReasonCodeContract)
 Add-Check 'Receipt akzeptiert nur eine feste Fehlerstufe und weist generische Codes ab' (Test-StageReceiptContract)
 Add-Check 'Provisionierungsfehler transportieren nur allowlistgebundene Aktivierungsgründe oder den festen Fallback' (Test-ActivationReasonContract)
 Add-Check 'Child verwendet dieselbe feste Stufen-, Legacy- und Aktivierungsallowlist' ($ci -match '(?s)function Get-ReasonCode \{.*?HYPERV_RESOURCE_RECONCILE_ACCEPTANCE_STAGE_.*?LEGACY_UNCLASSIFIED.*?return @\(\)' -and $ci -match '(?s)function Get-ActivationReasonCode \{.*?WINDOWS_ACTIVATION_REQUIRED.*?ACTIVATION_REASON_UNCLASSIFIED.*?return @\(\)')
 Add-Check 'Supervisor validiert nur feste Stufen und allowlistgebundene Aktivierungsgründe in der Receipt' ($ci -match "reasonCode -notmatch '\^HYPERV_RESOURCE_RECONCILE_ACCEPTANCE_STAGE_" -and $ci -match 'activationReasonCode' -and $ci -match 'HYPERV_RESOURCE_RECONCILE_ACCEPTANCE_ACTIVATION_REASON_UNCLASSIFIED' -and $ci -match 'LEGACY_UNCLASSIFIED')
 Add-Check 'Supervisor begrenzt den Childprozess, validiert eine kleine Receipt und bereinigt nur operationgebundene Runs' ($ci -match 'RunnerTimeoutSeconds' -and $ci -match 'DeferCleanup' -and $ci -match 'Test-HyperVResourceReconcileCiStageReceipt' -and $ci -match 'Stop-HyperVResourceReconcileCiChildProcessTree' -and $ci -match 'Get-LabOperationOwnedRun' -and $ci -match 'Get-HyperVManagedVM.*-ExpectedRunId.*-ExpectedScopeId' -and $ci -match 'Remove-SqlServerLab -RunId \$RunId -StateRoot \$Root -Force -Confirm:\$false')
 Add-Check 'Workflow erlaubt den nativen Modus nur manuell auf main und uebergibt ArtifactId ueber Environment' ($workflow -match '(?s)workflow_dispatch:.*resource-reconcile-acceptance' -and $workflow -match "github\.event_name == 'workflow_dispatch' && github\.ref == 'refs/heads/main' && inputs\.mode == 'resource-reconcile-acceptance'" -and $workflow -match "inputs\.mode == 'resource-reconcile-acceptance' && !\(github\.event_name == 'workflow_dispatch' && github\.ref == 'refs/heads/main'\)" -and $workflow -match 'HYPERV_RESOURCE_RECONCILE_CI_MANUAL_MAIN_REQUIRED' -and $workflow -match 'SQL_SERVER_LAB_CI_IMAGE_ARTIFACT_ID' -and $workflow -match 'Invoke-HyperVResourceReconcileCiAcceptance\.ps1 @arguments')
)
$failed=@($checks|Where-Object{-not $_.Success});if($failed){throw "Hyper-V resource reconcile acceptance checks failed: $($failed.Name -join ', ')"};Write-Host "Hyper-V Resource Reconcile Acceptance Checks: $($checks.Count) PASS, 0 FAIL" -ForegroundColor Green
