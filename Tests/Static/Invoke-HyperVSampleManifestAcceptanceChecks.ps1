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
    $ciRunner -match '\$childContent=@' -and $ciRunner -match '\$runnerOutput=@\(& \$AcceptanceRunner' -and $ciRunner -notmatch 'Write-Host \$runnerOutput' -and
    $ciRunner -match 'HYPERV_SAMPLE_MANIFEST_CI_FAILURE_KIND=PRIMARY' -and $ciRunner -match 'HYPERV_SAMPLE_MANIFEST_CI_FAILURE_KIND=CLEANUP'
)
Add-LocalCheck 'CI-Wrapper publiziert bei einem inneren Fehler hoechstens einen regex-validierten Sample-Reason-Code' (
    $ciRunner -match 'function Get-HyperVSampleManifestCiRunnerReasonCode' -and
    $ciRunner -match "'\(\?<\!\[A-Z0-9_\]\)HYPERV_SAMPLE_MANIFEST_\[A-Z0-9\]\+\(\?:_\[A-Z0-9\]\+\)\*\(\?\!\[A-Z0-9_\]\)'" -and
    $ciRunner -match 'Test-HyperVSampleManifestCiStageReceipt' -and
    $ciRunner -match 'HYPERV_SAMPLE_MANIFEST_CI_RUNNER_REASON_CODE=\$\(\$supervision\.ReasonCode\)' -and
    $ciRunner -notmatch 'Write-Host \$primaryFailure' -and $ciRunner -notmatch 'Write-Host \$cleanupFailure'
)
Add-LocalCheck 'Reason-Code-Selektor gibt nur einen kanonischen Code aus und verwirft nicht passende Payloads' (
    $reasonSelectorPass
)
$supervisorFixtureRoot=Join-Path ([IO.Path]::GetTempPath()) ('sql-server-lab-supervisor-static-'+[guid]::NewGuid().ToString('N'))
$foreignProcess=$null
try {
    foreach($name in @('New-HyperVSampleManifestCiSupervisorRoot','Test-HyperVSampleManifestCiStageReceipt','Stop-HyperVSampleManifestCiChildProcessTree','Invoke-HyperVSampleManifestCiSupervisor')){
        $functionName=$name
        $definition=$ciRunnerAst.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName},$true)
        if(-not $definition){throw "missing-supervisor-function:$name"}
        . ([scriptblock]::Create($definition.Extent.Text))
    }
    New-Item -ItemType Directory -Path $supervisorFixtureRoot -Force|Out-Null
    $successRunner=Join-Path $supervisorFixtureRoot 'success.ps1'
    $failureRunner=Join-Path $supervisorFixtureRoot 'failure.ps1'
    $hangRunner=Join-Path $supervisorFixtureRoot 'hang.ps1'
    $grandchildRunner=Join-Path $supervisorFixtureRoot 'grandchild.ps1'
    [IO.File]::WriteAllText($successRunner,"param([string]`$ArtifactId,[string]`$StateRoot,[string]`$Run1OperationId,[string]`$Run2OperationId)`r`nexit 0`r`n",[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($failureRunner,"param([string]`$ArtifactId,[string]`$StateRoot,[string]`$Run1OperationId,[string]`$Run2OperationId)`r`nthrow 'HYPERV_SAMPLE_MANIFEST_SYNTHETIC_FAILURE: private-value'`r`n",[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($hangRunner,"param([string]`$ArtifactId,[string]`$StateRoot,[string]`$Run1OperationId,[string]`$Run2OperationId)`r`nStart-Sleep -Seconds 30`r`n",[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($grandchildRunner,"param([string]`$ArtifactId,[string]`$StateRoot,[string]`$Run1OperationId,[string]`$Run2OperationId)`r`n`$child=Start-Process -FilePath (Join-Path `$PSHOME 'pwsh.exe') -ArgumentList @('-NoLogo','-NoProfile','-NonInteractive','-Command','Start-Sleep -Seconds 30') -PassThru`r`n[IO.File]::WriteAllText((Join-Path `$StateRoot 'grandchild.pid'),[string]`$child.Id,[Text.UTF8Encoding]::new(`$false))`r`nStart-Sleep -Seconds 30`r`n",[Text.UTF8Encoding]::new($false))
    $supervisorArguments=@{ArtifactId='synthetic-artifact';StateRoot=$supervisorFixtureRoot;Run1OperationId='synthetic-r1';Run2OperationId='synthetic-r2';PowerShellPath=(Join-Path $PSHOME 'pwsh.exe')}
    $success=Invoke-HyperVSampleManifestCiSupervisor -AcceptanceRunner $successRunner -TimeoutSeconds 10 @supervisorArguments
    Add-LocalCheck 'Supervisor akzeptiert einen erfolgreichen nichtinteraktiven Kindlauf nur mit gueltiger Abschlussquittung' ($success.Status -eq 'COMPLETED' -and $success.Stage -eq 'RUNNER_COMPLETED' -and $success.TerminationConfirmed)
    $failure=Invoke-HyperVSampleManifestCiSupervisor -AcceptanceRunner $failureRunner -TimeoutSeconds 10 @supervisorArguments
    Add-LocalCheck 'Supervisor reduziert einen fehlerhaften Kindlauf auf den allowlist-validierten Reason-Code' ($failure.Status -eq 'FAILED' -and $failure.Stage -eq 'RUNNER_FAILED' -and $failure.ReasonCode -eq 'HYPERV_SAMPLE_MANIFEST_SYNTHETIC_FAILURE' -and $failure.TerminationConfirmed)
    $invalidReceipt=Join-Path $supervisorFixtureRoot 'invalid-receipt.json'
    [IO.File]::WriteAllText($invalidReceipt,'{"status":"COMPLETED","stage":"RUNNER_COMPLETED","reasonCode":"unexpected"}',[Text.UTF8Encoding]::new($false))
    Add-LocalCheck 'Supervisor verwirft Quittungen mit nicht erlaubter Nutzlast' (-not (Test-HyperVSampleManifestCiStageReceipt -ReceiptPath $invalidReceipt))
    $hang=Invoke-HyperVSampleManifestCiSupervisor -AcceptanceRunner $hangRunner -TimeoutSeconds 1 @supervisorArguments
    Add-LocalCheck 'Supervisor meldet einen haengenden Kindlauf nach der festen Deadline als Timeout' ($hang.Status -eq 'FAILED' -and $hang.ReasonCode -eq 'HYPERV_SAMPLE_MANIFEST_CI_RUNNER_TIMEOUT' -and $hang.TimedOut -and $hang.TerminationConfirmed)
    $foreignProcess=Start-Process -FilePath (Join-Path $PSHOME 'pwsh.exe') -ArgumentList @('-NoLogo','-NoProfile','-NonInteractive','-Command','Start-Sleep -Seconds 30') -PassThru
    $timeout=Invoke-HyperVSampleManifestCiSupervisor -AcceptanceRunner $grandchildRunner -TimeoutSeconds 1 @supervisorArguments
    $grandchildId=[int](Get-Content -LiteralPath (Join-Path $supervisorFixtureRoot 'grandchild.pid') -Raw -Encoding utf8)
    $grandchildExited=$false;try{(Get-Process -Id $grandchildId -ErrorAction Stop).Refresh()}catch{$grandchildExited=$true}
    $foreignProcess.Refresh()
    Add-LocalCheck 'Supervisor beendet beim Timeout ausschliesslich den eigenen Kindprozessbaum und bestaetigt dessen Ende' ($timeout.Status -eq 'FAILED' -and $timeout.ReasonCode -eq 'HYPERV_SAMPLE_MANIFEST_CI_RUNNER_TIMEOUT' -and $timeout.TimedOut -and $timeout.TerminationConfirmed -and $grandchildExited -and -not $foreignProcess.HasExited)
    $cleanupIndex=$ciRunner.LastIndexOf('Invoke-HyperVSampleManifestCiCleanup -Module')
    $supervisionIndex=$ciRunner.IndexOf('Invoke-HyperVSampleManifestCiSupervisor -AcceptanceRunner')
    $cleanupOrderingPass=[bool]($supervisionIndex -ge 0 -and $cleanupIndex -gt $supervisionIndex -and ($ciRunner -match '\$module -and -not \$childTerminationUnconfirmed') -and ($ciRunner -match 'RUNNER_TERMINATION_UNCONFIRMED_RECOVERY_REQUIRED'))
    Add-LocalCheck 'CI-Wrapper blockiert operationgebundenen Cleanup bis zum bestaetigten Supervisorabschluss und bewahrt State bei unbestaetigter Terminierung' $cleanupOrderingPass
} catch {
    Add-LocalCheck 'Synthetische Supervisor-Vertragspruefung ist ausfuehrbar' $false ('synthetic-supervisor-failed: '+$_.Exception.Message)
} finally {
    if($foreignProcess){try{if(-not $foreignProcess.HasExited){$null=$foreignProcess.Kill($true);$null=$foreignProcess.WaitForExit(5000)}}catch{};$foreignProcess.Dispose()}
    if(Test-Path -LiteralPath $supervisorFixtureRoot){Remove-Item -LiteralPath $supervisorFixtureRoot -Recurse -Force}
}
Add-LocalCheck 'Hyper-V-Workflow bietet den manuellen main-gebundenen Sample-Manifest-Modus mit kontrolliertem Artifact-Input' (
    $workflow -match '(?m)^\s*- sample-manifest-acceptance\s*$' -and $workflow -match "inputs\.mode == 'sample-manifest-acceptance'" -and
    $workflow -match "github\.event_name == 'workflow_dispatch' && github\.ref == 'refs/heads/main'" -and
    $workflow -match 'HYPERV_SAMPLE_MANIFEST_CI_MANUAL_MAIN_REQUIRED' -and $workflow -match 'SQL_SERVER_LAB_CI_IMAGE_ARTIFACT_ID' -and
    $workflow -match 'Invoke-HyperVSampleManifestCiAcceptance\.ps1 @arguments'
)

if($failures.Count -gt 0){Write-Host "`nErgebnis: $passed PASS, $($failures.Count) FAIL" -ForegroundColor Red;foreach($failure in $failures){Write-Host "  - $failure" -ForegroundColor Red};exit 1}
Write-Host "`nErgebnis: $passed PASS, 0 FAIL" -ForegroundColor Green
