#Requires -Version 7.2
$ErrorActionPreference='Stop'
$repoRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$runnerPath=Join-Path $repoRoot 'Tests/Integration/Invoke-HyperVExternalRuntimeReconcileCiAcceptance.ps1'
$workflowPath=Join-Path $repoRoot '.github/workflows/runtime-smoke-hyperv.yml'
$runner=Get-Content -LiteralPath $runnerPath -Raw -Encoding utf8
$workflow=Get-Content -LiteralPath $workflowPath -Raw -Encoding utf8
$manifestHelper=Get-Content -LiteralPath (Join-Path $repoRoot 'Tests/Common/HyperVExternalRuntimeReconcileAcceptanceManifest.ps1') -Raw -Encoding utf8
$tokens=$null;$errors=$null
[Management.Automation.Language.Parser]::ParseFile($runnerPath,[ref]$tokens,[ref]$errors)|Out-Null

function Add-CiAcceptanceCheck {
    param([string]$Name,[bool]$Success)
    $color=if($Success){'Green'}else{'Red'}
    Write-Host ("  {0}  {1}" -f $(if($Success){'PASS'}else{'FAIL'}),$Name) -ForegroundColor $color
    [PSCustomObject]@{Name=$Name;Success=$Success}
}

$checks=@(
    Add-CiAcceptanceCheck 'CI-Runner ist syntaktisch gueltig' ($errors.Count -eq 0)
    Add-CiAcceptanceCheck 'Workflow bietet den Modus nur manuell auf main an' (
        $workflow -match '(?s)workflow_dispatch:.*external-runtime-reconcile-acceptance' -and
        $workflow -match "github\.event_name == 'workflow_dispatch' && github\.ref == 'refs/heads/main' && inputs\.mode == 'external-runtime-reconcile-acceptance'"
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
        $runner -match 'HYPERV_EXTERNAL_RUNTIME_CI_EXECUTION_AND_CLEANUP_FAILED' -and $runner -match 'HYPERV_EXTERNAL_RUNTIME_CI_CLEANUP_FAILED'
    )
    Add-CiAcceptanceCheck 'Workflow interpoliert keine untrusted Inputs direkt in PowerShell und publiziert keine Roh-Evidence' (
        $workflow -match 'SQL_SERVER_LAB_CI_IMAGE_ARTIFACT_ID: \$\{\{ inputs\.image_artifact_id \}\}' -and
        $workflow -match 'SQL_SERVER_LAB_CI_MEDIA_ROOT: \$\{\{ inputs\.media_root \}\}' -and
        $workflow -notmatch "external-runtime-reconcile-acceptance[\s\S]{0,1200}'\$\{\{ inputs\." -and
        $runner -match '\$runnerOutput = @\(& \$acceptanceRunner' -and $runner -notmatch 'NATIVE_EVIDENCE_PATH' -and $runner -notmatch 'Start-Transcript'
    )
    Add-CiAcceptanceCheck 'Artifact und Media Root bleiben katalog- beziehungsweise konstantgebunden' (
        $runner -match 'HYPERV_EXTERNAL_RUNTIME_CI_OS_SEALED_ARTIFACT_INVALID' -and $runner -match 'Test-HyperVExternalRuntimeCiMediaRoot' -and
        $runner -match 'HYPERV_EXTERNAL_RUNTIME_CI_MEDIA_ROOT_INVALID' -and $runner -notmatch 'https?://'
    )
)
$failed=@($checks|Where-Object{-not $_.Success})
if($failed.Count){throw "Hyper-V External Runtime CI Acceptance checks failed: $($failed.Name -join ', ')"}
Write-Host "Hyper-V External Runtime CI Acceptance Checks: $($checks.Count) PASS, 0 FAIL" -ForegroundColor Green
