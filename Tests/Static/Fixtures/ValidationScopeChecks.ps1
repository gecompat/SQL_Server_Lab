#Requires -Version 7.2
# Runs inside CiStrategyChecks; actual selector/scope/cache functions, no provider.
$validationSelector=Join-Path $repoRoot 'Tools/Get-CiTestSelection.ps1'
foreach($docPath in @('Documentation/Architecture/STOP_HOST_MEMORY.md','Documentation/Restore.md','Documentation/HyperVProvider.md')) {
    $selected=& $validationSelector -ChangedPath @($docPath)
    Add-CheckResult -Name "Docs basename cannot request runtime: $docPath" -Success (
        $selected.DocumentationOnly -and -not $selected.Docker -and -not $selected.Podman -and -not $selected.Mixed -and -not $selected.HyperV -and -not $selected.Adapter)
}
$mapping=& $validationSelector -ChangedPath @('Tools/Get-CiTestSelection.ps1','Tools/Get-CiCapabilitySelection.ps1')
Add-CheckResult -Name 'Selector mapping contract has static proof without provider effects' -Success (
    'Invoke-CiStrategyChecks.ps1' -in $mapping.StaticChecks -and -not $mapping.Docker -and -not $mapping.Podman -and -not $mapping.Mixed -and -not $mapping.HyperV -and -not $mapping.Adapter)
$pitr=& $validationSelector -ChangedPath @('Private/PointInTimeRecovery.ps1')
Add-CheckResult -Name 'PITR keeps two provider baselines and restore dependency, without unrelated features' -Success (
    $pitr.Docker -and $pitr.Podman -and ($pitr.Capabilities.Docker -join ',') -ceq 'lifecycle,pitr,restore' -and
    ($pitr.Capabilities.Podman -join ',') -ceq 'lifecycle,pitr,restore' -and -not $pitr.HyperV)
$union=& $validationSelector -ChangedPath @('Private/PointInTimeRecovery.ps1','Private/UnknownNewProduct.ps1')
Add-CheckResult -Name 'Unknown product cannot be narrowed by a known feature' -Success ('transfer' -cin $union.Capabilities.Docker -and 'pitr' -cin $union.Capabilities.Docker)
Add-CheckResult -Name 'Unknown product reach retains every provider until classified' -Success ($union.Docker -and $union.Podman -and $union.Mixed -and $union.HyperV -and $union.Adapter)
$common=& $validationSelector -ChangedPath @('Private/Common.ps1')
Add-CheckResult -Name 'Common module dependency retains all five gates and full container capabilities' -Success (
    $common.Docker -and $common.Podman -and $common.Mixed -and $common.HyperV -and $common.Adapter -and 'transfer' -cin $common.Capabilities.Docker)
$scopeCommand=Join-Path $repoRoot 'Tools/Get-StaticValidationScope.ps1'
$scoped=& $scopeCommand -ChangedPath @('Private/SmtpTestServiceReceiverRead.ps1')
Add-CheckResult -Name 'Local source scope keeps module/export Pester dependency without unrelated lifecycle suite' -Success (
    -not $scoped.Global -and $scoped.Pester.Count -eq 1 -and $scoped.Pester[0] -ceq 'Tests/Pester/SqlServerLab.Module.Tests.ps1' -and
    ($scoped.Analyzer -join ',') -ceq 'Private/SmtpTestServiceReceiverRead.ps1')
foreach($shared in @('SqlServerLab.psm1','Tests/Static/PSScriptAnalyzerSettings.psd1','Tests/Common/CheckResult.ps1','Other/unknown.ps1')) {
    $scope=& $scopeCommand -ChangedPath @($shared)
    Add-CheckResult -Name "Shared or unknown scope falls back globally: $shared" -Success ($scope.Global -and $scope.Pester.Count -ge 3)
}
$rejected=$false
try { & $scopeCommand -ChangedPath @('../foreign.ps1') | Out-Null } catch { $rejected=$true }
Add-CheckResult -Name 'Development scope rejects traversal' -Success $rejected
. (Join-Path $repoRoot 'Tests/Common/LocalStaticEvidence.ps1')
$fixture=Join-Path $repoRoot ('.artifacts/test-runs/validation-evidence-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $fixture
$log=Join-Path $fixture 'original.private.log'; 'SYNTHETIC PASS' | Set-Content -LiteralPath $log
$recordPath=Join-Path $fixture 'record.json'
$record=@{Schema='LOCAL_STATIC_EVIDENCE/v1';Status='EXECUTED_PASS';Binding='synthetic-binding';ExitCode=0;SourceStable=$true;
    CompletedUtc=[datetime]::UtcNow.ToString('o');Log=$log;LogSHA256=(Get-FileHash -LiteralPath $log).Hash}
$record | ConvertTo-Json | Set-Content -LiteralPath $recordPath
Add-CheckResult -Name 'Valid original executed evidence can be reused' -Success (Test-LocalStaticEvidence $recordPath 'synthetic-binding')
$validJson=$record | ConvertTo-Json -Compress
foreach ($invalidJson in @(
    ('['+$validJson+']'),
    $validJson.Replace('"SourceStable":true','"SourceStable":1'),
    $validJson.Replace('"ExitCode":0','"ExitCode":"0"'),
    $validJson.Replace('EXECUTED_PASS','EXECUTED_PASS\u0000'),
    $validJson.Replace('LOCAL_STATIC_EVIDENCE/v1','LOCAL_STATIC_EVIDENCE/v1\u0000'),
    $validJson.Replace('synthetic-binding','synthetic-binding\u0000'),
    ('{"Status":"EXECUTED_PASS",'+$validJson.Substring(1)),
    $validJson.Replace('"Binding":"synthetic-binding"','"Binding":["synthetic-binding"]')
)) {
    $invalidJson | Set-Content -LiteralPath $recordPath
    Add-CheckResult -Name 'Malformed evidence cannot attest executed PASS' -Success (-not (Test-LocalStaticEvidence $recordPath 'synthetic-binding'))
}
$validJson | Set-Content -LiteralPath $recordPath
Add-CheckResult -Name 'Changed source/environment binding cannot reuse green evidence' -Success (-not (Test-LocalStaticEvidence $recordPath 'changed-binding'))
foreach($status in @('FAIL_OR_UNKNOWN','RUNNING','NOT_EXECUTED','REUSED')) {
    $record.Status=$status; $record | ConvertTo-Json | Set-Content -LiteralPath $recordPath
    Add-CheckResult -Name "Non-executed/failed state cannot become reused PASS: $status" -Success (-not (Test-LocalStaticEvidence $recordPath 'synthetic-binding'))
}
$record.Status='EXECUTED_PASS';$record.CompletedUtc=[datetime]::UtcNow.AddHours(-5).ToString('o');$record | ConvertTo-Json | Set-Content -LiteralPath $recordPath
Add-CheckResult -Name 'Expired evidence must execute again' -Success (-not (Test-LocalStaticEvidence $recordPath 'synthetic-binding'))
$record.CompletedUtc=[datetime]::UtcNow.ToString('o');$record | ConvertTo-Json | Set-Content -LiteralPath $recordPath
'CHANGED' | Add-Content -LiteralPath $log
Add-CheckResult -Name 'Altered original log cannot attest PASS' -Success (-not (Test-LocalStaticEvidence $recordPath 'synthetic-binding'))
Add-CheckResult -Name 'Runtime/provider check has no cache binding' -Success (
    $null -eq (Get-LocalStaticEvidenceBinding $repoRoot 'Invoke-SmokeTest.ps1' @('Private/Common.ps1')))
# Retain this tiny synthetic fixture under ignored local evidence; no cleanup of foreign roots.

$scopeResolver=Join-Path $repoRoot 'Tools/Resolve-CiRuntimeScope.ps1'
foreach ($provider in @('docker','podman')) {
    $baseline=& $scopeResolver -Provider $provider -Capabilities lifecycle -Mode lifecycle
    Add-CheckResult -Name "Minimal capability admission: $provider" -Success (($baseline.Capabilities -join ',') -ceq 'lifecycle')
    foreach ($invalid in @('','restore','lifecycle,unknown','lifecycle,lifecycle','Lifecycle','lifecycle,','lifecycle, lifecycle',"lifecycle`0")) {
        $veto=$false
        try { & $scopeResolver -Provider $provider -Capabilities $invalid -Mode lifecycle | Out-Null } catch { $veto=$true }
        Add-CheckResult -Name "Invalid capability veto before provider preflight: $provider/$invalid" -Success $veto
    }
    $modeVeto=$false
    try { & $scopeResolver -Provider $provider -Capabilities lifecycle -Mode unknown | Out-Null } catch { $modeVeto=$true }
    Add-CheckResult -Name "Unknown runtime mode veto: $provider" -Success $modeVeto
    $workflow=Get-Content -LiteralPath (Join-Path $repoRoot ".github/workflows/runtime-smoke-$provider.yml") -Raw
    Add-CheckResult -Name "Admission precedes host tools, module and own-root creation: $provider" -Success (
        $workflow.IndexOf('Resolve-CiRuntimeScope.ps1') -lt $workflow.IndexOf('Initialize-SqlServerLabHostTools.ps1') -and
        $workflow.IndexOf('Resolve-CiRuntimeScope.ps1') -lt $workflow.IndexOf('Import-Module') -and
        $workflow.IndexOf('Resolve-CiRuntimeScope.ps1') -lt $workflow.IndexOf('Initialize-OwnedHostTestRoot'))
}
$foreignVeto=$false
try { & $scopeResolver -Provider docker -Capabilities 'lifecycle,ai-samples' -Mode lifecycle | Out-Null } catch { $foreignVeto=$true }
Add-CheckResult -Name 'Docker rejects Podman-only capability' -Success $foreignVeto
foreach ($dependency in @('Schemas/provider.json','Catalogs/software.json','Tools/UnknownNewTool.ps1','Tests/Static/Fixtures/Unknown.ps1')) {
    $dependencyScope=& $scopeCommand -ChangedPath @($dependency)
    Add-CheckResult -Name "Uncatalogued test/config dependency remains global: $dependency" -Success $dependencyScope.Global
}
$dependencySelection=& $validationSelector -ChangedPath @('Tests/Common/LocalStaticEvidence.ps1','Tests/Static/Fixtures/ValidationScopeChecks.ps1')
Add-CheckResult -Name 'Cache and scope fixtures select their executable regression consumer' -Success ('Invoke-CiStrategyChecks.ps1' -in $dependencySelection.StaticChecks)
$pesterSelection=& $validationSelector -ChangedPath @('Tests/Static/Invoke-PesterChecks.ps1')
Add-CheckResult -Name 'Pester runner selects release-readiness fixture dependency' -Success ('Invoke-ReleaseReadinessChecks.ps1' -in $pesterSelection.StaticChecks)

# Exercise the actual opaque binding with an owned synthetic Git tree and
# inert child-executable bytes. No alternate runtime is executed.
$bindingRepo=Join-Path $fixture 'binding-repository'
$null=New-Item -ItemType Directory -Path $bindingRepo
$git=(Get-Command git -ErrorAction Stop).Source
& $git -C $bindingRepo init --quiet
if ($LASTEXITCODE -ne 0) { throw 'SYNTHETIC_BINDING_GIT_INIT_FAILED' }
'ignored-active.md' | Set-Content -LiteralPath (Join-Path $bindingRepo '.gitignore')
'before' | Set-Content -LiteralPath (Join-Path $bindingRepo 'ignored-active.md')
$runnerRoot=Join-Path $fixture 'inert-runtime'
$null=New-Item -ItemType Directory -Path $runnerRoot
$runner=Join-Path $runnerRoot 'pwsh.exe'; 'inert-before' | Set-Content -LiteralPath $runner
$firstBinding=Get-LocalStaticEvidenceBinding -RepoRoot $bindingRepo -Check Invoke-CiStrategyChecks.ps1 -RunnerInvocation $runner
'after' | Set-Content -LiteralPath (Join-Path $bindingRepo 'ignored-active.md')
$ignoredChangedBinding=Get-LocalStaticEvidenceBinding -RepoRoot $bindingRepo -Check Invoke-CiStrategyChecks.ps1 -RunnerInvocation $runner
Add-CheckResult -Name 'Ignored active source invalidates actual binding' -Success ($firstBinding -and $ignoredChangedBinding -and $firstBinding -cne $ignoredChangedBinding)
'inert-after' | Set-Content -LiteralPath $runner
$runnerChangedBinding=Get-LocalStaticEvidenceBinding -RepoRoot $bindingRepo -Check Invoke-CiStrategyChecks.ps1 -RunnerInvocation $runner
Add-CheckResult -Name 'Actual child executable bytes invalidate binding' -Success ($runnerChangedBinding -and $runnerChangedBinding -cne $ignoredChangedBinding)

# Actual parent custody path: busy lock never launches the child. A later
# failed fresh execution replaces a previous green record even with NoReuse.
$custodyRepo=Join-Path $fixture 'custody-repository'
foreach($directory in @('Tools','Tests/Common','Tests/Static','.artifacts/test-runs/local-static-evidence')) {
    $null=New-Item -ItemType Directory -Path (Join-Path $custodyRepo $directory) -Force
}
& $git -C $custodyRepo init --quiet
if ($LASTEXITCODE -ne 0) { throw 'SYNTHETIC_CUSTODY_GIT_INIT_FAILED' }
'.artifacts/' | Set-Content -LiteralPath (Join-Path $custodyRepo '.gitignore')
Copy-Item -LiteralPath (Join-Path $repoRoot 'Tests/Common/LocalStaticEvidence.ps1') -Destination (Join-Path $custodyRepo 'Tests/Common/LocalStaticEvidence.ps1')
Copy-Item -LiteralPath (Join-Path $repoRoot 'Tests/Static/Invoke-ImpactedChecks.ps1') -Destination (Join-Path $custodyRepo 'Tests/Static/Invoke-ImpactedChecks.ps1')
"[pscustomobject]@{StaticChecks=@('Invoke-DocumentationChecks.ps1')}" | Set-Content -LiteralPath (Join-Path $custodyRepo 'Tools/Get-CiTestSelection.ps1')
"'CHILD_STARTED' | Set-Content -LiteralPath (Join-Path `$PSScriptRoot '../../.artifacts/child-marker'); exit 1" | Set-Content -LiteralPath (Join-Path $custodyRepo 'Tests/Static/Invoke-DocumentationChecks.ps1')
$custodyRecord=Join-Path $custodyRepo '.artifacts/test-runs/local-static-evidence/Invoke-DocumentationChecks.ps1.json'
$oldLog=Join-Path (Split-Path -Parent $custodyRecord) 'old.private.log'; 'OLD SYNTHETIC PASS' | Set-Content -LiteralPath $oldLog
$actualRunner=(Get-Command pwsh -ErrorAction Stop).Source
function Invoke-OwnedLocalEvidenceParent {
    param([string]$LogPath,[switch]$Development,[switch]$NoReuse)
    $info=[Diagnostics.ProcessStartInfo]::new()
    $info.FileName=$actualRunner;$info.UseShellExecute=$false;$info.CreateNoWindow=$true
    $info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    # This fixture models a local caller even when the suite itself runs in CI.
    # Only the owned child's environment changes; production CI never reuses.
    $info.Environment['GITHUB_ACTIONS']='false'
    foreach($argument in @('-NoLogo','-NoProfile','-File',(Join-Path $custodyRepo 'Tests/Static/Invoke-ImpactedChecks.ps1'),'-ChangedPath','README.md')) { $info.ArgumentList.Add($argument) }
    if($Development){$info.ArgumentList.Add('-Development')};if($NoReuse){$info.ArgumentList.Add('-NoReuse')}
    $child=[Diagnostics.Process]::new();$child.StartInfo=$info
    try {
        $null=$child.Start();$stdout=$child.StandardOutput.ReadToEndAsync();$stderr=$child.StandardError.ReadToEndAsync()
        if(-not $child.WaitForExit(30000)){throw 'LOCAL_EVIDENCE_FIXTURE_PARENT_TIMEOUT'}
        $output=$stdout.GetAwaiter().GetResult()+$stderr.GetAwaiter().GetResult()
        if($output.Length -gt 65536){throw 'LOCAL_EVIDENCE_FIXTURE_PARENT_OUTPUT_LIMIT'}
        $output | Set-Content -LiteralPath $LogPath
        return $child.ExitCode
    } finally { if($child.Id -and -not $child.HasExited){$child.Kill($true);$child.WaitForExit()};$child.Dispose() }
}
$custodyBinding=Get-LocalStaticEvidenceBinding -RepoRoot $custodyRepo -Check Invoke-DocumentationChecks.ps1 -ChangedPath README.md -RunnerInvocation $actualRunner
$oldRecord=@{Schema='LOCAL_STATIC_EVIDENCE/v1';Status='EXECUTED_PASS';Binding=$custodyBinding;ExitCode=0;SourceStable=$true;
    CompletedUtc=[datetime]::UtcNow.ToString('o');Log=$oldLog;LogSHA256=(Get-FileHash -LiteralPath $oldLog).Hash}
$oldRecord | ConvertTo-Json | Set-Content -LiteralPath $custodyRecord
if (-not $custodyBinding) {
    # Some platform bundles contain links which deliberately veto reuse. Test
    # the actual fail-closed uncached path instead of claiming cache execution.
    $unboundExit=Invoke-OwnedLocalEvidenceParent -LogPath (Join-Path $fixture 'custody-unbound.private.log') -Development
    $unboundOutput=Get-Content -LiteralPath (Join-Path $fixture 'custody-unbound.private.log') -Raw
    Add-CheckResult -Name 'Unavailable concrete runtime binding executes fresh and cannot reuse evidence' -Success (
        $unboundExit -ne 0 -and -not $unboundOutput.Contains('REUSED:') -and
        (Test-Path -LiteralPath (Join-Path $custodyRepo '.artifacts/child-marker')) -and -not (Test-LocalStaticEvidence $custodyRecord $custodyBinding))
    return
}
$heldLock=[IO.File]::Open($custodyRecord+'.lock',[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
try {
    $busyExit=Invoke-OwnedLocalEvidenceParent -LogPath (Join-Path $fixture 'custody-busy.private.log') -Development
} finally { $heldLock.Dispose() }
$busyLog=Get-Content -LiteralPath (Join-Path $fixture 'custody-busy.private.log') -Raw
Add-CheckResult -Name 'Busy evidence custody reports NOT_EXECUTED and launches no child' -Success (
    $busyExit -ne 0 -and $busyLog.Contains('LOCAL_EVIDENCE_BUSY_NOT_EXECUTED') -and -not (Test-Path -LiteralPath (Join-Path $custodyRepo '.artifacts/child-marker')))
$freshFailureExit=Invoke-OwnedLocalEvidenceParent -LogPath (Join-Path $fixture 'custody-failure.private.log') -NoReuse
$failedRecord=Get-Content -LiteralPath $custodyRecord -Raw | ConvertFrom-Json
Add-CheckResult -Name 'Fresh failure invalidates old green even when reuse is disabled' -Success (
    $freshFailureExit -ne 0 -and $failedRecord.Status -ceq 'FAIL_OR_UNKNOWN' -and
    (Test-Path -LiteralPath (Join-Path $custodyRepo '.artifacts/child-marker')) -and -not (Test-LocalStaticEvidence $custodyRecord $custodyBinding))

"'CHILD_STARTED' | Add-Content -LiteralPath (Join-Path `$PSScriptRoot '../../.artifacts/child-count'); exit 0" | Set-Content -LiteralPath (Join-Path $custodyRepo 'Tests/Static/Invoke-DocumentationChecks.ps1')
$firstPassExit=Invoke-OwnedLocalEvidenceParent -LogPath (Join-Path $fixture 'custody-first-pass.private.log') -Development
$reuseExit=Invoke-OwnedLocalEvidenceParent -LogPath (Join-Path $fixture 'custody-reused.private.log') -Development
$reuseOutput=Get-Content -LiteralPath (Join-Path $fixture 'custody-reused.private.log') -Raw
Add-CheckResult -Name 'Actual development parent reuses original PASS without second child execution' -Success (
    $firstPassExit -eq 0 -and $reuseExit -eq 0 -and $reuseOutput.Contains('REUSED: Invoke-DocumentationChecks.ps1') -and
    @(Get-Content -LiteralPath (Join-Path $custodyRepo '.artifacts/child-count')).Count -eq 1)
