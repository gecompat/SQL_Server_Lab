#Requires -Version 7.2
$ErrorActionPreference='Stop'
$repoRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$runnerPath=Join-Path $repoRoot 'Tests/Integration/Invoke-HyperVExternalRuntimeReconcileCiAcceptance.ps1'
$diagnosticsPath=Join-Path $repoRoot 'Tests/Common/HyperVExternalRuntimeReconcileCiDiagnostics.ps1'
$workflowPath=Join-Path $repoRoot '.github/workflows/runtime-smoke-hyperv.yml'
$runner=Get-Content -LiteralPath $runnerPath -Raw -Encoding utf8
$workflow=Get-Content -LiteralPath $workflowPath -Raw -Encoding utf8
$manifestHelper=Get-Content -LiteralPath (Join-Path $repoRoot 'Tests/Common/HyperVExternalRuntimeReconcileAcceptanceManifest.ps1') -Raw -Encoding utf8
$externalRuntimeRunner=Get-Content -LiteralPath (Join-Path $repoRoot 'Tests/Integration/Invoke-ExternalRuntimeHyperVAcceptance.ps1') -Raw -Encoding utf8
$tokens=$null;$errors=$null
[Management.Automation.Language.Parser]::ParseFile($runnerPath,[ref]$tokens,[ref]$errors)|Out-Null
$diagnosticTokens=$null;$diagnosticErrors=$null
[Management.Automation.Language.Parser]::ParseFile($diagnosticsPath,[ref]$diagnosticTokens,[ref]$diagnosticErrors)|Out-Null
. $diagnosticsPath

function Add-CiAcceptanceCheck {
    param([string]$Name,[bool]$Success)
    $color=if($Success){'Green'}else{'Red'}
    Write-Host ("  {0}  {1}" -f $(if($Success){'PASS'}else{'FAIL'}),$Name) -ForegroundColor $color
    [PSCustomObject]@{Name=$Name;Success=$Success}
}

$checks=@(
    Add-CiAcceptanceCheck 'CI-Runner ist syntaktisch gueltig' ($errors.Count -eq 0)
    Add-CiAcceptanceCheck 'Diagnosehelfer ist syntaktisch gueltig und klassifiziert nur den letzten groben Fehlercode' (
        $diagnosticErrors.Count -eq 0 -and
        (Get-HyperVExternalRuntimeCiFailureCode -InputObject @('untrusted C:\\runner\\local.txt', 'HYPERV_EXTERNAL_RUNTIME_SQL_SLOT_NOT_READY: C:\\secret.txt', 'HYPERV_EXTERNAL_RUNTIME_RECONCILE_ACCEPTANCE_APPLY_FAILED: host=internal')) -eq 'HYPERV_EXTERNAL_RUNTIME_RECONCILE_ACCEPTANCE_APPLY_FAILED' -and
        (Get-HyperVExternalRuntimeCiFailureCode -InputObject @('untrusted C:\\runner\\local.txt')) -eq 'UNCLASSIFIED'
    )
    Add-CiAcceptanceCheck 'Fehlerdiagnosen geben ausschliesslich grobe Codes aus und nie den erfassten Runnertext' (
        (Get-HyperVExternalRuntimeCiFailureDiagnosticLine -FailureKind PRIMARY -FailureCode 'HYPERV_EXTERNAL_RUNTIME_SQL_SLOT_NOT_READY') -eq 'HYPERV_EXTERNAL_RUNTIME_CI_PRIMARY_FAILURE_CODE=HYPERV_EXTERNAL_RUNTIME_SQL_SLOT_NOT_READY' -and
        (Get-HyperVExternalRuntimeCiFailureDiagnosticLine -FailureKind CLEANUP -FailureCode 'C:\\runner\\local.txt') -eq 'HYPERV_EXTERNAL_RUNTIME_CI_CLEANUP_FAILURE_CODE=UNCLASSIFIED' -and
        $runner -match 'Get-HyperVExternalRuntimeCiFailureCode -InputObject \$runnerOutput' -and
        $runner -match 'Get-HyperVExternalRuntimeCiFailureDiagnosticLine -FailureKind .PRIMARY.' -and
        $runner -notmatch 'Write-(Host|Output|Error).*\$runnerOutput'
    )
    Add-CiAcceptanceCheck 'Workflow bietet den Modus nur manuell auf main an und weist jeden anderen Aufruf sichtbar ab' (
        $workflow -match '(?s)workflow_dispatch:.*external-runtime-reconcile-acceptance' -and
        $workflow -match "github\.event_name == 'workflow_dispatch' && github\.ref == 'refs/heads/main' && inputs\.mode == 'external-runtime-reconcile-acceptance'" -and
        $workflow -match "inputs\.mode == 'external-runtime-reconcile-acceptance' && !\(github\.event_name == 'workflow_dispatch' && github\.ref == 'refs/heads/main'\)" -and
        $workflow -match 'HYPERV_EXTERNAL_RUNTIME_CI_MANUAL_MAIN_REQUIRED'
    )
    Add-CiAcceptanceCheck 'CI-Grenze akzeptiert weder RunId noch CloneSourceRunId' (
        $runner -notmatch '(?m)^\s*\[string\]\$RunId\b' -and $runner -notmatch '(?m)^\s*\[string\]\$CloneSourceRunId\b' -and
        $runner -match 'Invoke-WithLabWorkflowOperationContext' -and $runner -match 'Get-LabOperationOwnedRun'
    )
    Add-CiAcceptanceCheck 'Manifest bindet SQL-2022/Windows-2025, OS_SEALED und temporaere Aktivierung' (
        $runner -match "operatingSystem\.version -eq '2025'" -and $runner -match "artifactState -eq 'OS_SEALED'" -and
        $runner -match "Strategy='EvaluationOnline'" -and $runner -match "EgressPolicy='AllowTemporary'" -and
        $manifestHelper -match "id = 'sql2022-ext'; version = '2022'; provider = 'hyperv'; os = 'windows'"
    )
    Add-CiAcceptanceCheck 'External-Runtime-Runner installiert den SQL-Slot vor Runtime-Plan oder Apply und uebergibt den Resource-Governor-Intent' (
        $externalRuntimeRunner.IndexOf('Invoke-HyperVLabSqlSlotInstall') -ge 0 -and
        $externalRuntimeRunner.IndexOf('Invoke-HyperVLabSqlSlotInstall') -lt $externalRuntimeRunner.IndexOf('Get-SqlServerLabReconcilePlan') -and
        $externalRuntimeRunner.IndexOf('Invoke-HyperVLabSqlSlotInstall') -lt $externalRuntimeRunner.IndexOf('Invoke-SqlServerLabReconcileAction') -and
        $manifestHelper -match "resourceGovernor = \[ordered\]@\{ maxMemoryPercent=40; maxProcesses=32 \}" -and
        $externalRuntimeRunner -match 'ResourceGovernorConfig \(\[PSCustomObject\]@\{ maxMemoryPercent=40; maxProcesses=32 \}\)'
    )
    Add-CiAcceptanceCheck 'Erfolg und Fehler verwenden denselben oeffentlichen scopegebundenen Cleanup' (
        $runner -match 'finally\s*\{\s*if \(\$module\)' -and $runner -match 'Invoke-HyperVExternalRuntimeCiCleanup' -and
        $runner -match 'Remove-SqlServerLab -RunId \$RunId -StateRoot \$Root -Force -Confirm:\$false'
    )
    Add-CiAcceptanceCheck 'Fruehe Create-Fehler werden ausschliesslich ueber exakten Operationskontext aufgeloest' (
        $runner -match "\^github-\[0-9\]\+\-\[0-9\]\+\$" -and $runner -match 'HYPERV_EXTERNAL_RUNTIME_CI_OPERATION_CONTEXT_INVALID' -and
        $runner -match 'HYPERV_EXTERNAL_RUNTIME_CI_OWNED_RUN_STATE_INVALID' -and $runner -notmatch 'Get-VM\s+-Name\s+\*'
    )
    Add-CiAcceptanceCheck 'Fremde oder mehrdeutige State-, Scope- und VM-Ownership sperren Cleanup' (
        $runner -match 'Get-LabOperationOwnedRun' -and $runner -match 'HYPERV_EXTERNAL_RUNTIME_CI_OWNED_RUN_CLEANUP_PLAN_INVALID' -and
        $runner -match '(?s)Get-HyperVManagedVM.*-ExpectedRunId.*-ExpectedScopeId' -and $runner -match 'HYPERV_EXTERNAL_RUNTIME_CI_OWNED_VM_OWNERSHIP_INVALID'
    )
    Add-CiAcceptanceCheck 'Primar- und Cleanup-Fehler bleiben getrennt klassifiziert' (
        $runner -match '\$primaryFailure' -and $runner -match '\$cleanupFailure' -and
        $runner -match '\$primaryFailureCode' -and $runner -match '\$cleanupFailureCode' -and
        $runner -match '-FailureKind ''PRIMARY'' -FailureCode \$primaryFailureCode' -and
        $runner -match '-FailureKind ''CLEANUP'' -FailureCode \$cleanupFailureCode' -and
        $runner -match 'HYPERV_EXTERNAL_RUNTIME_CI_EXECUTION_AND_CLEANUP_FAILED' -and $runner -match 'HYPERV_EXTERNAL_RUNTIME_CI_CLEANUP_FAILED'
    )
    Add-CiAcceptanceCheck 'Erfolgreicher Runnerlauf gibt keine Fehlerdiagnose aus und behaelt seinen PASS-Vertrag' (
        $runner -match '\$runnerSucceeded = \$\?' -and $runner -match 'if \(-not \$runnerSucceeded\)' -and
        $runner -match "Write-Host 'PASS: Isolierter Hyper-V External-Runtime-Reconcile wurde ausgefuehrt\.'" -and
        $runner.IndexOf("Write-Host 'PASS: Isolierter Hyper-V External-Runtime-Reconcile wurde ausgefuehrt.'") -lt $runner.IndexOf("if (`$primaryFailure) { Write-Host") -and
        $runner -match "Write-Host 'Native Hyper-V External-Runtime-Reconcile-CI-Akzeptanz erfolgreich\.'"
    )
    Add-CiAcceptanceCheck 'Workflow interpoliert keine untrusted Inputs direkt in PowerShell und publiziert keine Roh-Evidence' (
        $workflow -match 'SQL_SERVER_LAB_CI_IMAGE_ARTIFACT_ID: \$\{\{ inputs\.image_artifact_id \}\}' -and
        $workflow -match 'SQL_SERVER_LAB_CI_MEDIA_ROOT: \$\{\{ inputs\.media_root \}\}' -and
        $workflow -notmatch "external-runtime-reconcile-acceptance[\s\S]{0,1200}'\$\{\{ inputs\." -and
        $runner -match '\$runnerOutput = @\(& \$acceptanceRunner' -and $runner -notmatch 'NATIVE_EVIDENCE_PATH' -and $runner -notmatch 'Start-Transcript'
    )
    Add-CiAcceptanceCheck 'Artefaktauswahl ist integritaetsgeprueft, evaluation- und child-validiert' (
        $runner -match 'Get-HyperVImageArtifact -ArtifactId \$Id -StateRoot \$Root' -and
        $runner -match 'Get-HyperVImageArtifact -StateRoot \$Root \|' -and $runner -notmatch 'Get-HyperVImageArtifact[^\r\n]*SkipIntegrityCheck' -and
        $runner -match "integrityVerification\.status -in @\('VERIFIED_CACHE','VERIFIED_HASH'\)" -and
        $runner -match 'Test-HyperVImageArtifactEvaluationEligibility' -and $runner -match 'Test-HyperVImageArtifactChildValidationEligibility'
    )
    Add-CiAcceptanceCheck 'Artifact und Media Root bleiben katalog- beziehungsweise konstantgebunden' (
        $runner -match 'HYPERV_EXTERNAL_RUNTIME_CI_OS_SEALED_ARTIFACT_INVALID' -and $runner -match 'Test-HyperVExternalRuntimeCiMediaRoot' -and
        $runner -match 'HYPERV_EXTERNAL_RUNTIME_CI_MEDIA_ROOT_INVALID' -and $runner -notmatch 'https?://'
    )
    Add-CiAcceptanceCheck 'Cleanup belegt VM-, VHDX- und IPAM-Nachbedingungen auch fuer bereits entfernte Runs' (
        $runner -match 'Test-HyperVExternalRuntimeCiCleanupPostconditions' -and
        $runner -match 'HYPERV_EXTERNAL_RUNTIME_CI_CLEANUP_VM_POSTCONDITION_FAILED' -and
        $runner -match 'HYPERV_EXTERNAL_RUNTIME_CI_CLEANUP_VHDX_POSTCONDITION_FAILED' -and
        $runner -match 'HYPERV_EXTERNAL_RUNTIME_CI_CLEANUP_IPAM_POSTCONDITION_FAILED' -and
        $runner -match "@\('REMOVED','COMPLETED','ALREADY_REMOVED'\)" -and
        $runner -match 'resourceType -notin @\(''vm'', ''vhdx'', ''ipam-lease''\)' -and
        $runner -match '\$vmSteps\.Count -ne 1' -and
        $runner -match 'Get-VM -Name \(\[string\]\$CleanupOwned\.VMName\)' -and
        $runner.IndexOf('Test-HyperVExternalRuntimeCiCleanupPostconditions') -lt $runner.LastIndexOf('return $result')
    )
)
$failed=@($checks|Where-Object{-not $_.Success})
if($failed.Count){throw "Hyper-V External Runtime CI Acceptance checks failed: $($failed.Name -join ', ')"}
Write-Host "Hyper-V External Runtime CI Acceptance Checks: $($checks.Count) PASS, 0 FAIL" -ForegroundColor Green
