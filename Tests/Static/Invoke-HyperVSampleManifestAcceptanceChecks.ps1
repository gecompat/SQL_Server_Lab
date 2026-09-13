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
$foreignProcess=$null;$foreignIdentity=$null;$treeParent=$null;$treeParentIdentity=$null;$treeChildIdentity=$null
function Get-SyntheticProcessIdentity {
    param([Parameter(Mandatory)][Diagnostics.Process]$Process)
    try {$Process.Refresh();return [pscustomobject]@{Pid=[int]$Process.Id;StartTicks=[int64]$Process.StartTime.ToUniversalTime().Ticks}}catch{return $null}
}
function Test-SyntheticProcessTerminal {
    param([Parameter(Mandatory)]$Identity)
    if($IsLinux){
        $process=$null;try{$process=Get-Process -Id ([int]$Identity.Pid) -ErrorAction Stop;$process.Refresh()}catch{}
        $statPath="/proc/$([int]$Identity.Pid)/stat"
        if(-not (Test-Path -LiteralPath $statPath -PathType Leaf)){return $true}
        if(-not $process){return $false}
        try {
            if([int64]$process.StartTime.ToUniversalTime().Ticks -ne [int64]$Identity.StartTicks){return $true}
            $stat=Get-Content -LiteralPath $statPath -Raw -Encoding utf8
            return $stat -match '^\d+ \(.+\) [ZX] '
        } catch { return $false }
    }
    try {
        $process=Get-Process -Id ([int]$Identity.Pid) -ErrorAction Stop;$process.Refresh()
        if([int64]$process.StartTime.ToUniversalTime().Ticks -ne [int64]$Identity.StartTicks){return $true}
        return $process.HasExited
    } catch { return $true }
}
function Test-SyntheticProcessAlive {
    param([Parameter(Mandatory)]$Identity)
    try {
        $process=Get-Process -Id ([int]$Identity.Pid) -ErrorAction Stop;$process.Refresh()
        if([int64]$process.StartTime.ToUniversalTime().Ticks -ne [int64]$Identity.StartTicks){return $false}
        if($IsLinux){
            $statPath="/proc/$([int]$Identity.Pid)/stat"
            if(-not (Test-Path -LiteralPath $statPath -PathType Leaf)){return $false}
            try{$stat=Get-Content -LiteralPath $statPath -Raw -Encoding utf8}catch{return $false}
            return $stat -notmatch '^\d+ \(.+\) [ZX] '
        }
        return -not $process.HasExited
    } catch { return $false }
}
function Wait-SyntheticProcessTerminal {
    param([Parameter(Mandatory)]$Identity,[ValidateRange(1,30)][int]$TimeoutSeconds=10)
    $deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {if(Test-SyntheticProcessTerminal -Identity $Identity){return $true};Start-Sleep -Milliseconds 100} while([DateTime]::UtcNow -lt $deadline)
    return $false
}
function Wait-SyntheticReadyFile {
    param([Parameter(Mandatory)][string]$Path,[ValidateRange(1,30)][int]$TimeoutSeconds=10)
    $deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {if(Test-Path -LiteralPath $Path -PathType Leaf){return $true};Start-Sleep -Milliseconds 100} while([DateTime]::UtcNow -lt $deadline)
    return $false
}
function Stop-SyntheticProcessByIdentity {
    param($Identity)
    if(-not $Identity){return}
    try {$process=Get-Process -Id ([int]$Identity.Pid) -ErrorAction Stop;$process.Refresh();if([int64]$process.StartTime.ToUniversalTime().Ticks -eq [int64]$Identity.StartTicks -and -not $process.HasExited){$process.Kill($true);$null=$process.WaitForExit(5000)}}catch{}
}
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
    $treeChildRunner=Join-Path $supervisorFixtureRoot 'tree-child.ps1'
    $treeParentRunner=Join-Path $supervisorFixtureRoot 'tree-parent.ps1'
    [IO.File]::WriteAllText($successRunner,"param([string]`$ArtifactId,[string]`$StateRoot,[string]`$Run1OperationId,[string]`$Run2OperationId)`r`nexit 0`r`n",[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($failureRunner,"param([string]`$ArtifactId,[string]`$StateRoot,[string]`$Run1OperationId,[string]`$Run2OperationId)`r`nthrow 'HYPERV_SAMPLE_MANIFEST_SYNTHETIC_FAILURE: private-value'`r`n",[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($hangRunner,"param([string]`$ArtifactId,[string]`$StateRoot,[string]`$Run1OperationId,[string]`$Run2OperationId)`r`nStart-Sleep -Seconds 30`r`n",[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($treeChildRunner,@'
param([string]$ReadyRoot)
$current=[Diagnostics.Process]::GetCurrentProcess()
$identity='{0}|{1}' -f $current.Id,$current.StartTime.ToUniversalTime().Ticks
[IO.File]::WriteAllText((Join-Path $ReadyRoot 'tree-child.ready'),$identity,[Text.UTF8Encoding]::new($false))
Start-Sleep -Seconds 60
'@,[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($treeParentRunner,@'
param([string]$ReadyRoot,[string]$ChildRunner,[string]$PowerShellPath)
$startInfo=[Diagnostics.ProcessStartInfo]::new()
$startInfo.FileName=$PowerShellPath;$startInfo.UseShellExecute=$false;$startInfo.CreateNoWindow=$true
foreach($argument in @('-NoLogo','-NoProfile','-NonInteractive','-File',$ChildRunner,'-ReadyRoot',$ReadyRoot)){[void]$startInfo.ArgumentList.Add($argument)}
$child=[Diagnostics.Process]::Start($startInfo)
$deadline=[DateTime]::UtcNow.AddSeconds(10)
while(-not (Test-Path -LiteralPath (Join-Path $ReadyRoot 'tree-child.ready') -PathType Leaf) -and [DateTime]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 100}
if(-not (Test-Path -LiteralPath (Join-Path $ReadyRoot 'tree-child.ready') -PathType Leaf)){exit 2}
[IO.File]::WriteAllText((Join-Path $ReadyRoot 'tree-parent.ready'),'READY',[Text.UTF8Encoding]::new($false))
Start-Sleep -Seconds 60
'@,[Text.UTF8Encoding]::new($false))
    $supervisorArguments=@{ArtifactId='synthetic-artifact';StateRoot=$supervisorFixtureRoot;Run1OperationId='synthetic-r1';Run2OperationId='synthetic-r2';PowerShellPath=([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName);Synthetic=$true}
    $success=Invoke-HyperVSampleManifestCiSupervisor -AcceptanceRunner $successRunner -TimeoutSeconds 10 @supervisorArguments
    Add-LocalCheck 'Supervisor akzeptiert einen erfolgreichen nichtinteraktiven Kindlauf nur mit gueltiger Abschlussquittung' ($success.Status -eq 'COMPLETED' -and $success.Stage -eq 'RUNNER_COMPLETED' -and $success.TerminationConfirmed)
    $failure=Invoke-HyperVSampleManifestCiSupervisor -AcceptanceRunner $failureRunner -TimeoutSeconds 10 @supervisorArguments
    Add-LocalCheck 'Supervisor reduziert einen fehlerhaften Kindlauf auf den allowlist-validierten Reason-Code' ($failure.Status -eq 'FAILED' -and $failure.Stage -eq 'RUNNER_FAILED' -and $failure.ReasonCode -eq 'HYPERV_SAMPLE_MANIFEST_SYNTHETIC_FAILURE' -and $failure.TerminationConfirmed)
    $invalidReceipt=Join-Path $supervisorFixtureRoot 'invalid-receipt.json'
    [IO.File]::WriteAllText($invalidReceipt,'{"status":"COMPLETED","stage":"RUNNER_COMPLETED","reasonCode":"unexpected"}',[Text.UTF8Encoding]::new($false))
    Add-LocalCheck 'Supervisor verwirft Quittungen mit nicht erlaubter Nutzlast' (-not (Test-HyperVSampleManifestCiStageReceipt -ReceiptPath $invalidReceipt))
    $hang=Invoke-HyperVSampleManifestCiSupervisor -AcceptanceRunner $hangRunner -TimeoutSeconds 1 @supervisorArguments
    Add-LocalCheck 'Supervisor meldet einen haengenden Kindlauf nach der festen Deadline als Timeout' ($hang.Status -eq 'FAILED' -and $hang.ReasonCode -eq 'HYPERV_SAMPLE_MANIFEST_CI_RUNNER_TIMEOUT' -and $hang.TimedOut -and $hang.TerminationConfirmed)
    $foreignProcess=Start-Process -FilePath ([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) -ArgumentList @('-NoLogo','-NoProfile','-NonInteractive','-Command','Start-Sleep -Seconds 60') -PassThru
    $foreignIdentity=Get-SyntheticProcessIdentity -Process $foreignProcess
    $parentStartInfo=[Diagnostics.ProcessStartInfo]::new()
    $parentStartInfo.FileName=([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName);$parentStartInfo.UseShellExecute=$false;$parentStartInfo.CreateNoWindow=$true
    foreach($argument in @('-NoLogo','-NoProfile','-NonInteractive','-File',$treeParentRunner,'-ReadyRoot',$supervisorFixtureRoot,'-ChildRunner',$treeChildRunner,'-PowerShellPath',([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName))){[void]$parentStartInfo.ArgumentList.Add($argument)}
    $treeParent=[Diagnostics.Process]::Start($parentStartInfo);$treeParentIdentity=Get-SyntheticProcessIdentity -Process $treeParent
    $parentReady=Wait-SyntheticReadyFile -Path (Join-Path $supervisorFixtureRoot 'tree-parent.ready')
    $childReady=Wait-SyntheticReadyFile -Path (Join-Path $supervisorFixtureRoot 'tree-child.ready')
    $childIdentity=$null
    if($childReady){$childIdentityText=Get-Content -LiteralPath (Join-Path $supervisorFixtureRoot 'tree-child.ready') -Raw -Encoding utf8;if($childIdentityText -match '^(\d+)\|(\d+)$'){$childIdentity=[pscustomobject]@{Pid=[int]$Matches[1];StartTicks=[int64]$Matches[2]}}}
    $treeChildIdentity=$childIdentity
    $terminationRequested=$false
    if($parentReady -and $childReady -and $treeParentIdentity -and $treeChildIdentity -and $foreignIdentity){$terminationRequested=Stop-HyperVSampleManifestCiChildProcessTree -Process $treeParent}
    $parentTerminal=if($treeParentIdentity){Wait-SyntheticProcessTerminal -Identity $treeParentIdentity}else{$false}
    $childTerminal=if($treeChildIdentity){Wait-SyntheticProcessTerminal -Identity $treeChildIdentity}else{$false}
    $foreignAlive=if($foreignIdentity){Test-SyntheticProcessAlive -Identity $foreignIdentity}else{$false}
    Add-LocalCheck 'Supervisor beendet nur den bereiten eigenen Parent-/Kindprozessbaum und laesst den fremden Sentinel unveraendert' ([bool]($parentReady -and $childReady -and $terminationRequested -and $parentTerminal -and $childTerminal -and $foreignAlive))
    $cleanupIndex=$ciRunner.LastIndexOf('Invoke-HyperVSampleManifestCiCleanup -Module')
    $supervisionIndex=$ciRunner.IndexOf('Invoke-HyperVSampleManifestCiSupervisor -AcceptanceRunner')
    $cleanupOrderingPass=[bool]($supervisionIndex -ge 0 -and $cleanupIndex -gt $supervisionIndex -and ($ciRunner -match '\$module -and -not \$childTerminationUnconfirmed') -and ($ciRunner -match 'RUNNER_TERMINATION_UNCONFIRMED_RECOVERY_REQUIRED') -and ($ciRunner -match 'New-HyperVSampleManifestCiSupervisorRoot -Synthetic:\$Synthetic') -and ($ciRunner -match 'HYPERV_SAMPLE_MANIFEST_CI_RUNNER_NOT_ELEVATED'))
    Add-LocalCheck 'CI-Wrapper blockiert operationgebundenen Cleanup bis zum bestaetigten Supervisorabschluss und bewahrt State bei unbestaetigter Terminierung' $cleanupOrderingPass
} catch {
    Add-LocalCheck 'Synthetische Supervisor-Vertragspruefung ist ausfuehrbar' $false 'synthetic-supervisor-failed'
} finally {
    Stop-SyntheticProcessByIdentity -Identity $treeChildIdentity
    Stop-SyntheticProcessByIdentity -Identity $treeParentIdentity
    Stop-SyntheticProcessByIdentity -Identity $foreignIdentity
    if($foreignProcess){$foreignProcess.Dispose()}
    if($treeParent){$treeParent.Dispose()}
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
