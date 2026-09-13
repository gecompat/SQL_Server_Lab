[CmdletBinding()]
param()

$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
. (Join-Path $PSScriptRoot '..\Common\CheckResult.ps1')
$runnerPath=Join-Path $repoRoot 'Tests/Integration/Invoke-HyperVSampleManifestAcceptance.ps1'
$ciRunnerPath=Join-Path $repoRoot 'Tests/Integration/Invoke-HyperVSampleManifestCiAcceptance.ps1'
$workflowPath=Join-Path $repoRoot '.github/workflows/runtime-smoke-hyperv.yml'
$runner=Get-Content -LiteralPath $runnerPath -Raw -Encoding utf8
$ciRunner=Get-Content -LiteralPath $ciRunnerPath -Raw -Encoding utf8
$workflow=Get-Content -LiteralPath $workflowPath -Raw -Encoding utf8

$failures=[Collections.Generic.List[string]]::new();$passed=0
function Add-LocalCheck { param([string]$Name,[bool]$Success,[string]$Message='') if($Success){$script:passed++;Write-Host "PASS: $Name" -ForegroundColor Green}else{$script:failures.Add("$Name$(if($Message){": $Message"})");Write-Host "FAIL: $Name $Message" -ForegroundColor Red} }

$tokens=$null;$parseErrors=$null;[void][Management.Automation.Language.Parser]::ParseFile($runnerPath,[ref]$tokens,[ref]$parseErrors)
Add-LocalCheck 'Nativer Mehrfach-Sample-Runner ist syntaktisch gueltig' ($parseErrors.Count -eq 0) (($parseErrors|ForEach-Object Message)-join '; ')
$tokens=$null;$parseErrors=$null;[void][Management.Automation.Language.Parser]::ParseFile($ciRunnerPath,[ref]$tokens,[ref]$parseErrors)
Add-LocalCheck 'CI-Mehrfach-Sample-Runner ist syntaktisch gueltig' ($parseErrors.Count -eq 0) (($parseErrors|ForEach-Object Message)-join '; ')
$tokens=$null;$parseErrors=$null;$ciRunnerAst=[Management.Automation.Language.Parser]::ParseFile($ciRunnerPath,[ref]$tokens,[ref]$parseErrors)
$reasonCodeFunction=$ciRunnerAst.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-HyperVSampleManifestCiRunnerReasonCode'},$true)
if($reasonCodeFunction){. ([scriptblock]::Create($reasonCodeFunction.Extent.Text))}
$selectedReasonCodes=if($reasonCodeFunction){@(Get-HyperVSampleManifestCiRunnerReasonCode -RunnerOutput @('untrusted HYPERV_SAMPLE_MANIFEST_INNER_FAILURE: sensitive-demo-value','HYPERV_SAMPLE_MANIFEST_INNER_FAILURE'))}else{@()}
$rejectedReasonCodes=if($reasonCodeFunction){@(Get-HyperVSampleManifestCiRunnerReasonCode -RunnerOutput @('sensitive-demo-value HYPERV_SAMPLE_manifest_bad'))}else{@('missing-function')}
$reasonSelectorPass=$false
if(($selectedReasonCodes.Count -eq 1) -and ($selectedReasonCodes -ceq 'HYPERV_SAMPLE_MANIFEST_INNER_FAILURE')){
    if($rejectedReasonCodes.Count -eq 0){$reasonSelectorPass=$true}
}
Add-LocalCheck 'Native Abnahme bindet zwei sequenzielle frische New-SqlServerLab-Manifestruns an denselben isolierten Testdatenroot' (
    $runner -match 'SQL_SERVER_LAB_TEST_DATA_ROOT' -and $runner -match 'Initialize-LabManagedDataRoot' -and
    $runner -match 'New-SampleManifestRun -OperationId \$Run1OperationId' -and $runner -match 'Remove-AcceptanceRun -Lab \$run1\.Lab' -and
    $runner -match 'New-SampleManifestRun -OperationId \$Run2OperationId'
)
Add-LocalCheck 'Native Abnahme pinnt Chinook und Northwind vor jeder Mutation an katalogisierte Hashquellen' (
    $runner -match "id='chinook';variant='sql-server'" -and $runner -match "id='northwind';variant='script'" -and
    $runner -match 'Resolve-LabSampleRestore' -and $runner -match "trustPolicy -ne 'catalog-only'" -and $runner -match "expectedSha256 -notmatch '\^\[a-f0-9\]\{64\}\$'"
)
Add-LocalCheck 'Native Abnahme prueft Artifact-Integritaet, Evaluation, Child-Run und Storage-Lanes' (
    $runner -match 'SQL_PREPARED_SEALED' -and $runner -match 'VERIFIED_CACHE' -and $runner -match 'Test-HyperVImageArtifactEvaluationEligibility' -and
    $runner -match 'Test-HyperVImageArtifactChildValidationEligibility' -and $runner -match 'Get-HyperVArtifactStorageConfiguration' -and $runner -match 'New-LabStorageBoundPlan'
)
Add-LocalCheck 'Native Abnahme validiert Inhalt, LAB_GENERATED-Key/Hash und zweiten Manifest-Lock ohne Roh-Evidence-Ausgabe' (
    $runner -match 'dbo\.Artist' -and $runner -match 'dbo\.Customers' -and $runner -match 'LAB_GENERATED' -and
    $runner -match 'baselineEquivalent' -and $runner -match 'lockEquivalent' -and $runner -match 'Get-ManifestSampleLockEntries' -and
    $runner -notmatch 'Write-Host \$run1Locks' -and $runner -notmatch 'Write-Host \$run2Locks'
)
Add-LocalCheck 'CI-Wrapper akzeptiert keine bestehende Run-ID und bereinigt nur beide abgeleiteten operationsgebundenen Hyper-V-Runs' (
    $ciRunner -notmatch '\[string\]\$RunId' -and $ciRunner -notmatch 'CloneSourceRunId' -and
    $ciRunner -match 'github-\[0-9\]\+-\[0-9\]\+' -and $ciRunner -match 'sample-r1' -and $ciRunner -match 'sample-r2' -and
    $ciRunner -match 'Get-LabOperationOwnedRun' -and $ciRunner -match 'Get-CleanupPlan' -and $ciRunner -match 'Remove-SqlServerLab' -and
    $ciRunner -match 'Get-HyperVManagedVM' -and $ciRunner -match 'HYPERV_SAMPLE_MANIFEST_CI_OWNED_VM_OWNERSHIP_INVALID' -and
    $ciRunner -match 'HYPERV_SAMPLE_MANIFEST_CI_CLEANUP_VM_POSTCONDITION_FAILED'
)
Add-LocalCheck 'CI-Wrapper haelt die innere Ausgabe privat und publiziert nur grobe Fehlerarten' (
    $ciRunner -match '\$runnerOutput=@\(& \$acceptanceRunner' -and $ciRunner -notmatch 'Write-Host \$runnerOutput' -and
    $ciRunner -match 'HYPERV_SAMPLE_MANIFEST_CI_FAILURE_KIND=PRIMARY' -and $ciRunner -match 'HYPERV_SAMPLE_MANIFEST_CI_FAILURE_KIND=CLEANUP'
)
Add-LocalCheck 'CI-Wrapper publiziert bei einem inneren Fehler hoechstens einen regex-validierten Sample-Reason-Code' (
    $ciRunner -match 'function Get-HyperVSampleManifestCiRunnerReasonCode' -and
    $ciRunner -match "'\(\?<\!\[A-Z0-9_\]\)HYPERV_SAMPLE_MANIFEST_\[A-Z0-9\]\+\(\?:_\[A-Z0-9\]\+\)\*\(\?\!\[A-Z0-9_\]\)'" -and
    $ciRunner -match '\$runnerReasonCode=Get-HyperVSampleManifestCiRunnerReasonCode -RunnerOutput \$runnerOutput' -and
    $ciRunner -match 'HYPERV_SAMPLE_MANIFEST_CI_RUNNER_REASON_CODE=\$runnerReasonCode' -and
    $ciRunner -notmatch 'Write-Host \$primaryFailure' -and $ciRunner -notmatch 'Write-Host \$cleanupFailure'
)
Add-LocalCheck 'Reason-Code-Selektor gibt nur einen kanonischen Code aus und verwirft nicht passende Payloads' (
    $reasonSelectorPass
)
Add-LocalCheck 'Hyper-V-Workflow bietet den manuellen main-gebundenen Sample-Manifest-Modus mit kontrolliertem Artifact-Input' (
    $workflow -match '(?m)^\s*- sample-manifest-acceptance\s*$' -and $workflow -match "inputs\.mode == 'sample-manifest-acceptance'" -and
    $workflow -match "github\.event_name == 'workflow_dispatch' && github\.ref == 'refs/heads/main'" -and
    $workflow -match 'HYPERV_SAMPLE_MANIFEST_CI_MANUAL_MAIN_REQUIRED' -and $workflow -match 'SQL_SERVER_LAB_CI_IMAGE_ARTIFACT_ID' -and
    $workflow -match 'Invoke-HyperVSampleManifestCiAcceptance\.ps1 @arguments'
)

if($failures.Count -gt 0){Write-Host "`nErgebnis: $passed PASS, $($failures.Count) FAIL" -ForegroundColor Red;foreach($failure in $failures){Write-Host "  - $failure" -ForegroundColor Red};exit 1}
Write-Host "`nErgebnis: $passed PASS, 0 FAIL" -ForegroundColor Green
