#Requires -Version 7.2
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$temporaryParent = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath ([IO.Path]::GetTempPath())).ProviderPath).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
$fixtureLeaf = 'podman-ci-privacy-' + [guid]::NewGuid().ToString('N')
$root = Join-Path $temporaryParent $fixtureLeaf
$rootCreated = $false
$failures = [Collections.Generic.List[string]]::new()
$passed = 0
. (Join-Path $PSScriptRoot '../Common/CheckResult.ps1')

function Invoke-WorkflowFixture {
    param([string]$Script, [string]$Name, [int]$ExitCode, [string]$FailureStage = '', [string]$SafeSummary = '')
    $directory = Join-Path $root $Name
    $null = New-Item -ItemType Directory -Path $directory
    $driver = Join-Path $directory 'driver.ps1'
    [IO.File]::WriteAllText($driver, $Script)
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = (Get-Process -Id $PID).Path
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.WorkingDirectory = $root
    foreach ($argument in @('-NoLogo', '-NoProfile', '-File', $driver)) { $start.ArgumentList.Add($argument) }
    $start.Environment['RUNNER_TEMP'] = $directory
    $start.Environment['GITHUB_OUTPUT'] = Join-Path $directory 'outputs.txt'
    $start.Environment['GITHUB_ENV'] = Join-Path $directory 'environment.txt'
    $start.Environment['LOCALAPPDATA'] = $directory
    $start.Environment['SQL_SERVER_LAB_CI_OWN_STATE_ROOT'] = $directory
    $start.Environment['SQL_SERVER_LAB_CI_MODE'] = if ($Name.StartsWith('cli-acceptance')) { 'cli-acceptance' } else { 'lifecycle' }
    $start.Environment['GITHUB_STEP_SUMMARY'] = Join-Path $directory 'summary.txt'
    $start.Environment['PRIVACY_FIXTURE_EXIT'] = [string]$ExitCode
    $start.Environment['PRIVACY_FIXTURE_STAGE'] = $FailureStage
    $start.Environment['PRIVACY_FIXTURE_SAFE_SUMMARY'] = $SafeSummary
    $start.Environment['PRIVACY_FIXTURE_TRACE'] = Join-Path $directory 'trace.txt'
    $process = [Diagnostics.Process]::Start($start)
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(30000)) { $process.Kill($true); $process.WaitForExit(); throw 'PRIVACY_FIXTURE_TIMEOUT' }
        $public = $stdout.GetAwaiter().GetResult() + $stderr.GetAwaiter().GetResult()
        foreach ($file in @('outputs.txt', 'summary.txt')) {
            $path = Join-Path $directory $file
            if (Test-Path -LiteralPath $path) { $public += Get-Content -LiteralPath $path -Raw }
        }
        $private = (@(Get-ChildItem -LiteralPath $directory -Filter '*.private.log' | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }) -join "`n")
        $trace = if (Test-Path -LiteralPath $start.Environment['PRIVACY_FIXTURE_TRACE']) { @(Get-Content -LiteralPath $start.Environment['PRIVACY_FIXTURE_TRACE']) } else { @() }
        return [pscustomobject]@{ ExitCode = $process.ExitCode; Public = $public; Private = $private; Trace = @($trace) }
    }
    finally { $process.Dispose() }
}

try {
    $null = New-Item -ItemType Directory -Path $root
    $rootCreated = $true
    $workflow = Get-Content -LiteralPath (Join-Path $repoRoot '.github/workflows/runtime-smoke-podman.yml') -Raw
    $blocks = @([regex]::Matches(($workflow -split '(?m)^  owned-run-recovery:')[0], '(?m)^        run: \|\r?\n(?<body>(?:^          [^\r\n]*\r?\n|^\r?\n)+)') | ForEach-Object {
        [regex]::Replace($_.Groups['body'].Value, '(?m)^          ', '')
    })
    if ($blocks.Count -ne 3) { throw 'PODMAN_WORKFLOW_RUN_BLOCK_COUNT' }
    $preflight = $blocks[0]
    $runtime = $blocks[1].Replace('SQL_Server_Lab_Runtime_Smoke', ('PodmanPrivacyFixture_' + [guid]::NewGuid().ToString('N')))
    Add-CheckResult -Name 'Podman owned-run cleanup remains a distinct final workflow block' -Success ($blocks[2] -match 'Complete-OwnedHostTestRoot\.ps1' -and $blocks[2] -match 'OWNED_TEST_CLEANUP_RECOVERY_REQUIRED')
    $commands = @([regex]::Matches($runtime, 'Tests\\Integration\\(?<name>Invoke-[\w-]+\.ps1)') | ForEach-Object { $_.Groups['name'].Value })
    $expected = @('Invoke-ContainerCliAcceptance.ps1', 'Invoke-SmokeMatrix.ps1', 'Invoke-ContainerCollationAcceptance.ps1', 'Invoke-RestoreSmokeTest.ps1', 'Invoke-PointInTimeRecoveryAcceptance.ps1', 'Invoke-SqlVersionUpgradeAcceptance.ps1', 'Invoke-BatchWorkflowSmokeTest.ps1', 'Invoke-ContainerToolAcceptance.ps1', 'Invoke-PersistentStorageRemovalExecutorAcceptance.ps1', 'Invoke-ContainerDatabasePackageExportAcceptance.ps1', 'Invoke-PortableContainerTransferPreflightAcceptance.ps1', 'Invoke-PortableContainerTransferAcceptance.ps1', 'Invoke-AiVectorCoreAcceptance.ps1', 'Invoke-AiPodmanSamplesReferenceAcceptance.ps1')
    Add-CheckResult -Name 'Podman gate retains every acceptance in order and both modes' -Success (($commands -join '|') -ceq ($expected -join '|') -and $workflow -match 'default: lifecycle' -and $workflow -match '\- cli-acceptance')
    Add-CheckResult -Name 'Podman gate retains serialization, finite qualification budget and mutex cleanup' -Success ($workflow -match 'cancel-in-progress: false' -and $workflow -match 'timeout-minutes: 90' -and $runtime -match 'FromMinutes\(10\)' -and $runtime -match '\$mutex.ReleaseMutex\(\)' -and $runtime -match '\$mutex.Dispose\(\)')
    Add-CheckResult -Name 'Podman ownership state survives runner temporary-directory cleanup' -Success ($workflow.Contains('$stateRoot=Join-Path (Split-Path $env:RUNNER_TEMP -Parent) ([guid]::NewGuid().ToString(''N''))') -and $runtime.Contains('Join-Path $env:SQL_SERVER_LAB_CI_OWN_STATE_ROOT') -and $workflow -match 'Initialize-OwnedHostTestRoot -Module \$module -StateRoot \$stateRoot')
    Add-CheckResult -Name 'Every acceptance retains its nonzero exit guard' -Success ([regex]::Matches($runtime, 'if \(\$(?:LASTEXITCODE|\w+ExitCode) -ne 0\) \{ throw ').Count -eq $expected.Count)
    Add-CheckResult -Name 'Podman gate never uploads or tees private diagnostics' -Success ($workflow -notmatch 'upload-artifact|Tee-Object|\$\(_\.Exception.Message\)')
    $recoveryBlocks=@([regex]::Matches(($workflow -split '(?m)^  owned-run-recovery:')[1], '(?m)^        run: \|\r?\n(?<body>(?:^          [^\r\n]*\r?\n|^\r?\n)+)') | ForEach-Object {
        [regex]::Replace($_.Groups['body'].Value, '(?m)^          ', '')
    })
    if($recoveryBlocks.Count -ne 1){throw 'RECOVERY_WORKFLOW_RUN_BLOCK_COUNT'}
    foreach($invalid in @('state','policy','run','provider','location')) {
        $prefix=@'
$env:RECOVERY_POLICY_ID='4ab2a1f0-693d-4e75-bf9f-6ef902bc7503'
$env:RECOVERY_RUN_ID='e40a0ac7-51c1-44f3-b754-4dd2cf4a62bd'
$env:RECOVERY_STATE_ID='7e494facb1af4457bbec91220f3848eb'
$env:RECOVERY_PROVIDER='podman'
$env:RECOVERY_LOCATION='runner-work'
'@
        $key=switch($invalid){state{'STATE_ID'}policy{'POLICY_ID'}run{'RUN_ID'}provider{'PROVIDER'}location{'LOCATION'}}
        $prefix+="`n[Environment]::SetEnvironmentVariable('RECOVERY_$key','../foreign')`n"
        $result=Invoke-WorkflowFixture -Script ($prefix+$recoveryBlocks[0]) -Name ('recovery-invalid-'+$invalid) -ExitCode 0
        Add-CheckResult -Name ('Actual recovery rejects invalid '+$invalid+' before module or native mutation') -Success (
            $result.ExitCode -ne 0 -and $result.Public -match 'OWNED_CI_RUN_RECOVERY_FAILED' -and $result.Public -notmatch 'OWNED_CI_RUN_RECOVERY_SUCCEEDED|ModuleNotFound|Initialize-SqlServerLabHostTools')
    }

    $null = New-Item -ItemType Directory -Path (Join-Path $root 'Tests/Integration') -Force
    $null = New-Item -ItemType Directory -Path (Join-Path $root 'Tests/Common') -Force
    $null = New-Item -ItemType Directory -Path (Join-Path $root 'Tools') -Force
    # Isolate readiness dependencies; execute actual workflow redirections,
    # outcome guards and every acceptance invocation.
    [IO.File]::WriteAllText((Join-Path $root 'SqlServerLab.psd1'), "@{ModuleVersion='1.0';GUID='276bf358-475d-4abd-b56b-dc4f439b95fb'}")
    [IO.File]::WriteAllText((Join-Path $root 'Tests/Common/OwnedHostTestScope.ps1'), 'function Initialize-OwnedHostTestRoot { param($Module,$StateRoot,$Providers,$ParentOperationId) }')
    [IO.File]::WriteAllText((Join-Path $root 'Tools/Initialize-SqlServerLabHostTools.ps1'), "param(`$Name); [pscustomobject]@{Available=`$true}")
    [IO.File]::WriteAllText((Join-Path $root 'Tools/Resolve-CiRuntimeScope.ps1'), "param(`$Provider,`$Capabilities,`$Mode); [pscustomobject]@{Capabilities=@('lifecycle','collation','restore','pitr','upgrade','batch','tool','removal','package','transfer-preflight','transfer','ai-vector','ai-samples')}")
    $fixture = @'
Write-Output 'SYNTHETIC_PRIVATE_HOST sentinel.invalid'
[Console]::Error.WriteLine('SYNTHETIC_PRIVATE_SECRET fixture-value')
Write-Host 'SYNTHETIC_PRIVATE_INFORMATION'
Add-Content -LiteralPath $env:PRIVACY_FIXTURE_TRACE -Value ([IO.Path]::GetFileName($PSCommandPath))
if (-not $env:PRIVACY_FIXTURE_STAGE -or [IO.Path]::GetFileName($PSCommandPath) -eq $env:PRIVACY_FIXTURE_STAGE) {
    if ($env:PRIVACY_FIXTURE_SAFE_SUMMARY) { Write-Host $env:PRIVACY_FIXTURE_SAFE_SUMMARY }
    exit ([int]$env:PRIVACY_FIXTURE_EXIT)
}
exit 0
'@
    foreach ($command in $commands) { [IO.File]::WriteAllText((Join-Path $root "Tests/Integration/$command"), $fixture) }
    [IO.File]::WriteAllText((Join-Path $root 'native-fixture.ps1'), $fixture)
    [IO.File]::WriteAllText((Join-Path $root 'Tests/Integration/Initialize-PodmanRuntime.ps1'), "& pwsh -NoLogo -NoProfile -File ./native-fixture.ps1`nif (`$LASTEXITCODE -ne 0) { throw 'SYNTHETIC_PRIVATE_INIT_FAILED' }")
    $shim = @'
function podman { & pwsh -NoLogo -NoProfile -File ./native-fixture.ps1; $global:LASTEXITCODE = $LASTEXITCODE }
function sqlcmd { & pwsh -NoLogo -NoProfile -File ./native-fixture.ps1; $global:LASTEXITCODE = $LASTEXITCODE }
'@
    foreach ($exitCode in @(0, 19)) {
        $result = Invoke-WorkflowFixture -Script ($shim + "`n" + $preflight) -Name "preflight-$exitCode" -ExitCode $exitCode
        Add-CheckResult -Name "Preflight $exitCode keeps all raw output local and preserves outcome" -Success (
            $result.Public -notmatch 'SYNTHETIC_PRIVATE' -and $result.Private -match 'SYNTHETIC_PRIVATE_HOST' -and $result.Private -match 'SYNTHETIC_PRIVATE_SECRET' -and
            (($exitCode -eq 0 -and $result.ExitCode -eq 0 -and $result.Public -match 'validation_classification=VALIDATED') -or
            ($exitCode -ne 0 -and $result.ExitCode -ne 0 -and $result.Public -match 'INFRASTRUCTURE_UNAVAILABLE')))
    }
    $result = Invoke-WorkflowFixture -Script ("function Import-Module { throw 'SYNTHETIC_PRIVATE_EXCEPTION' }`n" + $preflight) -Name 'preflight-exception' -ExitCode 0
    Add-CheckResult -Name 'Unexpected native-preflight exception remains private' -Success ($result.ExitCode -ne 0 -and $result.Public -notmatch 'SYNTHETIC_PRIVATE' -and $result.Private -match 'SYNTHETIC_PRIVATE_EXCEPTION')
    $result = Invoke-WorkflowFixture -Script ("function pwsh { throw 'SYNTHETIC_PRIVATE_EXCEPTION' }`n" + $runtime.Replace('${{ inputs.mode }}', 'lifecycle')) -Name 'runtime-exception' -ExitCode 0
    Add-CheckResult -Name 'Unexpected runtime invocation exception remains private' -Success ($result.ExitCode -ne 0 -and $result.Public -match 'PODMAN_RUNTIME_FAILED' -and $result.Public -notmatch 'SYNTHETIC_PRIVATE' -and $result.Private -match 'SYNTHETIC_PRIVATE_EXCEPTION')
    foreach ($stageCase in @(
        @{ Script = 'Invoke-ContainerToolAcceptance.ps1'; Name = 'tool' },
        @{ Script = 'Invoke-ContainerDatabasePackageExportAcceptance.ps1'; Name = 'package' }
    )) {
        $result = Invoke-WorkflowFixture -Script $runtime.Replace('${{ inputs.mode }}', 'lifecycle') -Name ('acceptance-stage-' + $stageCase.Name) -ExitCode 23 -FailureStage $stageCase.Script
        Add-CheckResult -Name "A failed $($stageCase.Name) acceptance reports only its safe stage name" -Success (
            $result.ExitCode -ne 0 -and $result.Public -match ("PODMAN_ACCEPTANCE_FAILED=" + [regex]::Escape($stageCase.Name)) -and
            $result.Public -match 'PODMAN_RUNTIME_FAILED' -and $result.Public -notmatch 'SYNTHETIC_PRIVATE' -and
            $result.Private -match 'SYNTHETIC_PRIVATE_SECRET' -and $result.Trace[-1] -ceq $stageCase.Script)
    }
    $aiSamplesStage = 'Invoke-AiPodmanSamplesReferenceAcceptance.ps1'
    $safeFailureSummary = 'PRIMARY=FAILED; PRIMARY_REASON=SAMPLES_NEW_FAILED; CLEANUP=COMPLETED; CLEANUP_REASON=NONE'
    $safeFailureScript = $runtime.Replace('${{ inputs.mode }}', 'lifecycle')
    $result = Invoke-WorkflowFixture -Script $safeFailureScript -Name 'ai-samples-safe-failure-code' -ExitCode 23 -FailureStage $aiSamplesStage -SafeSummary $safeFailureSummary
    Add-CheckResult -Name 'AI sample failure emits only allowlisted result codes while raw streams remain private' -Success (
        $result.ExitCode -ne 0 -and $result.Public -match 'PODMAN_ACCEPTANCE_FAILED=ai-samples' -and
        $result.Public -match 'PODMAN_AI_SAMPLES_FAILURE_CODE=PRIMARY/FAILED/SAMPLES_NEW_FAILED;CLEANUP/COMPLETED/NONE' -and
        $result.Public -notmatch 'SYNTHETIC_PRIVATE|PRIMARY_REASON|SAMPLES_NEW_FAILED.*fixture-value' -and
        $result.Private -match 'SYNTHETIC_PRIVATE_SECRET' -and $result.Trace[-1] -ceq $aiSamplesStage)
    $result = Invoke-WorkflowFixture -Script $safeFailureScript -Name 'ai-samples-missing-result-code' -ExitCode 23 -FailureStage $aiSamplesStage
    Add-CheckResult -Name 'Missing AI sample result remains a generic failed gate' -Success (
        $result.ExitCode -ne 0 -and $result.Public -match 'PODMAN_AI_SAMPLES_FAILURE_CODE=UNAVAILABLE' -and
        $result.Public -notmatch 'SYNTHETIC_PRIVATE|PRIMARY_REASON' -and $result.Private -match 'SYNTHETIC_PRIVATE_SECRET')
    $secretSummary = 'PRIMARY=FAILED; PRIMARY_REASON=SAMPLES_NEW_FAILED_SECRET; CLEANUP=COMPLETED; CLEANUP_REASON=NONE'
    $result = Invoke-WorkflowFixture -Script $safeFailureScript -Name 'ai-samples-secret-suffix-rejected' -ExitCode 23 -FailureStage $aiSamplesStage -SafeSummary $secretSummary
    Add-CheckResult -Name 'Unknown or secret-suffixed AI sample codes are never emitted' -Success (
        $result.ExitCode -ne 0 -and $result.Public -match 'PODMAN_AI_SAMPLES_FAILURE_CODE=UNAVAILABLE' -and
        $result.Public -notmatch 'SYNTHETIC_PRIVATE|SAMPLES_NEW_FAILED_SECRET' -and $result.Private -match 'SYNTHETIC_PRIVATE_SECRET')
    $duplicateSummary = $safeFailureSummary + "`n" + $safeFailureSummary
    $result = Invoke-WorkflowFixture -Script $safeFailureScript -Name 'ai-samples-duplicate-result-rejected' -ExitCode 23 -FailureStage $aiSamplesStage -SafeSummary $duplicateSummary
    Add-CheckResult -Name 'Duplicate AI sample result records are rejected as an array-spoof attempt' -Success (
        $result.ExitCode -ne 0 -and $result.Public -match 'PODMAN_AI_SAMPLES_FAILURE_CODE=UNAVAILABLE' -and
        $result.Public -notmatch 'SYNTHETIC_PRIVATE|SAMPLES_NEW_FAILED' -and $result.Private -match 'SYNTHETIC_PRIVATE_SECRET')
    $cleanupFailureSummary = 'PRIMARY=COMPLETED; PRIMARY_REASON=NONE; CLEANUP=FAILED; CLEANUP_REASON=SUPERVISOR_FAILED'
    $result = Invoke-WorkflowFixture -Script $safeFailureScript -Name 'ai-samples-cleanup-failure-code' -ExitCode 23 -FailureStage $aiSamplesStage -SafeSummary $cleanupFailureSummary
    Add-CheckResult -Name 'Cleanup failure exposes only its allowlisted cleanup code and remains failed' -Success (
        $result.ExitCode -ne 0 -and $result.Public -match 'PODMAN_AI_SAMPLES_FAILURE_CODE=PRIMARY/COMPLETED/NONE;CLEANUP/FAILED/SUPERVISOR_FAILED' -and
        $result.Public -notmatch 'SYNTHETIC_PRIVATE|PRIMARY_REASON' -and $result.Private -match 'SYNTHETIC_PRIVATE_SECRET')
    $workerStageSummary = 'PRIMARY=FAILED; PRIMARY_REASON=AI_PODMAN_SAMPLES_WORKER_FAILED_AT_LAB_CREATE; CLEANUP=COMPLETED; CLEANUP_REASON=NONE'
    $result = Invoke-WorkflowFixture -Script $safeFailureScript -Name 'ai-samples-worker-stage-code' -ExitCode 23 -FailureStage $aiSamplesStage -SafeSummary $workerStageSummary
    Add-CheckResult -Name 'Allowlisted worker stage diagnosis is emitted without private details' -Success (
        $result.ExitCode -ne 0 -and $result.Public -match 'PODMAN_AI_SAMPLES_FAILURE_CODE=PRIMARY/FAILED/AI_PODMAN_SAMPLES_WORKER_FAILED_AT_LAB_CREATE;CLEANUP/COMPLETED/NONE' -and
        $result.Public -notmatch 'SYNTHETIC_PRIVATE|PRIMARY_REASON' -and $result.Private -match 'SYNTHETIC_PRIVATE_SECRET')
    $postAcceptanceFailureScript = $safeFailureScript.Replace(
        '"validated_capabilities=$completedCapabilities" | Out-File -LiteralPath $env:GITHUB_OUTPUT -Encoding utf8 -Append',
        "throw 'SYNTHETIC_PRIVATE_POST_ACCEPTANCE_FAILURE'")
    $successfulSummary = 'PRIMARY=COMPLETED; PRIMARY_REASON=NONE; CLEANUP=COMPLETED; CLEANUP_REASON=NONE'
    $result = Invoke-WorkflowFixture -Script $postAcceptanceFailureScript -Name 'post-ai-samples-output-failure' -ExitCode 0 -FailureStage $aiSamplesStage -SafeSummary $successfulSummary
    Add-CheckResult -Name 'A later workflow output failure is not mislabeled as an AI sample failure' -Success (
        $result.ExitCode -ne 0 -and $result.Public -match 'PODMAN_RUNTIME_FAILED' -and
        $result.Public -notmatch 'PODMAN_AI_SAMPLES_FAILURE_CODE|SYNTHETIC_PRIVATE' -and
        $result.Private -match 'SYNTHETIC_PRIVATE_POST_ACCEPTANCE_FAILURE')
    foreach ($mode in @('lifecycle', 'cli-acceptance')) {
        $script = $runtime.Replace('${{ inputs.mode }}', $mode)
        $result = Invoke-WorkflowFixture -Script $script -Name "$mode-success" -ExitCode 0
        $expectedTrace = @(if ($mode -eq 'lifecycle') { $expected[1..($expected.Count - 1)] } else { $expected[0] })
        Add-CheckResult -Name "$mode executes the complete gate without forwarding private output" -Success ($result.ExitCode -eq 0 -and $result.Public -match 'PODMAN_RUNTIME_SUCCEEDED' -and $result.Public -notmatch 'SYNTHETIC_PRIVATE' -and $result.Private -match 'SYNTHETIC_PRIVATE_SECRET' -and ($result.Trace -join '|') -ceq ($expectedTrace -join '|'))
        foreach ($stage in @($expectedTrace[0], $expectedTrace[-1] | Select-Object -Unique)) {
            $result = Invoke-WorkflowFixture -Script $script -Name ($mode + '-' + $stage) -ExitCode 23 -FailureStage $stage
            Add-CheckResult -Name "$mode $stage failure remains a failed private gate" -Success ($result.ExitCode -ne 0 -and $result.Public -match 'PODMAN_RUNTIME_FAILED' -and $result.Public -notmatch 'SYNTHETIC_PRIVATE' -and $result.Private -match 'SYNTHETIC_PRIVATE_SECRET' -and $result.Trace[-1] -ceq $stage)
        }
    }
}
finally {
    # Only this newly-created synthetic fixture directory is owned by this test.
    if ($rootCreated -and (Test-Path -LiteralPath $root)) {
        $target = Get-Item -LiteralPath $root -Force
        $resolvedTarget = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $root).ProviderPath)
        $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
        if (-not $target.PSIsContainer -or
            ($target.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            -not $resolvedTarget.Equals([IO.Path]::GetFullPath($root), $comparison) -or
            -not ([IO.Path]::GetDirectoryName($resolvedTarget)).Equals($temporaryParent, $comparison) -or
            [IO.Path]::GetFileName($resolvedTarget) -cne $fixtureLeaf -or
            $fixtureLeaf -cnotmatch '^podman-ci-privacy-[a-f0-9]{32}$') {
            throw 'PRIVACY_FIXTURE_CLEANUP_SCOPE_INVALID'
        }
        Remove-Item -LiteralPath $resolvedTarget -Recurse -Force
    }
}
Write-Host "Podman smoke privacy: $passed PASS / $($failures.Count) FAIL"
if ($failures.Count -gt 0) { exit 1 }
