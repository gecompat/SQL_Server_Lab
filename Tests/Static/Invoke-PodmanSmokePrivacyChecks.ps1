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
    param([string]$Script, [string]$Name, [int]$ExitCode, [string]$FailureStage = '')
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
    $start.Environment['GITHUB_STEP_SUMMARY'] = Join-Path $directory 'summary.txt'
    $start.Environment['PRIVACY_FIXTURE_EXIT'] = [string]$ExitCode
    $start.Environment['PRIVACY_FIXTURE_STAGE'] = $FailureStage
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
    $blocks = @([regex]::Matches($workflow, '(?m)^        run: \|\r?\n(?<body>(?:^          [^\r\n]*\r?\n|^\r?\n)+)') | ForEach-Object {
        [regex]::Replace($_.Groups['body'].Value, '(?m)^          ', '')
    })
    if ($blocks.Count -ne 2) { throw 'PODMAN_WORKFLOW_RUN_BLOCK_COUNT' }
    $preflight = $blocks[0]
    $runtime = $blocks[1].Replace('SQL_Server_Lab_Runtime_Smoke', ('PodmanPrivacyFixture_' + [guid]::NewGuid().ToString('N')))
    $commands = @([regex]::Matches($runtime, 'Tests\\Integration\\(?<name>Invoke-[\w-]+\.ps1)') | ForEach-Object { $_.Groups['name'].Value })
    $expected = @('Invoke-ContainerCliAcceptance.ps1', 'Invoke-SmokeMatrix.ps1', 'Invoke-ContainerCollationAcceptance.ps1', 'Invoke-RestoreSmokeTest.ps1', 'Invoke-PointInTimeRecoveryAcceptance.ps1', 'Invoke-SqlVersionUpgradeAcceptance.ps1', 'Invoke-BatchWorkflowSmokeTest.ps1', 'Invoke-ContainerToolAcceptance.ps1', 'Invoke-PersistentStorageRemovalExecutorAcceptance.ps1', 'Invoke-ContainerDatabasePackageExportAcceptance.ps1', 'Invoke-PortableContainerTransferPreflightAcceptance.ps1', 'Invoke-PortableContainerTransferAcceptance.ps1', 'Invoke-AiVectorCoreAcceptance.ps1', 'Invoke-AiPodmanSamplesReferenceAcceptance.ps1')
    Add-CheckResult -Name 'Podman gate retains every acceptance in order and both modes' -Success (($commands -join '|') -ceq ($expected -join '|') -and $workflow -match 'default: lifecycle' -and $workflow -match '\- cli-acceptance')
    Add-CheckResult -Name 'Podman gate retains serialization, timeout and mutex cleanup' -Success ($workflow -match 'cancel-in-progress: false' -and $workflow -match 'timeout-minutes: 45' -and $runtime -match 'FromMinutes\(10\)' -and $runtime -match '\$mutex.ReleaseMutex\(\)' -and $runtime -match '\$mutex.Dispose\(\)')
    Add-CheckResult -Name 'Every acceptance retains its nonzero exit guard' -Success ([regex]::Matches($runtime, 'if \(\$(?:LASTEXITCODE|\w+ExitCode) -ne 0\) \{ throw ').Count -eq $expected.Count)
    Add-CheckResult -Name 'Podman gate never uploads or tees private diagnostics' -Success ($workflow -notmatch 'upload-artifact|Tee-Object|\$\(_\.Exception.Message\)')

    $null = New-Item -ItemType Directory -Path (Join-Path $root 'Tests/Integration') -Force
    $fixture = @'
Write-Output 'SYNTHETIC_PRIVATE_HOST sentinel.invalid'
[Console]::Error.WriteLine('SYNTHETIC_PRIVATE_SECRET fixture-value')
Write-Host 'SYNTHETIC_PRIVATE_INFORMATION'
Add-Content -LiteralPath $env:PRIVACY_FIXTURE_TRACE -Value ([IO.Path]::GetFileName($PSCommandPath))
if (-not $env:PRIVACY_FIXTURE_STAGE -or [IO.Path]::GetFileName($PSCommandPath) -eq $env:PRIVACY_FIXTURE_STAGE) { exit ([int]$env:PRIVACY_FIXTURE_EXIT) }
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
    $result = Invoke-WorkflowFixture -Script ("function pwsh { throw 'SYNTHETIC_PRIVATE_EXCEPTION' }`n" + $preflight) -Name 'preflight-exception' -ExitCode 0
    Add-CheckResult -Name 'Unexpected native-preflight exception remains private' -Success ($result.ExitCode -ne 0 -and $result.Public -notmatch 'SYNTHETIC_PRIVATE' -and $result.Private -match 'SYNTHETIC_PRIVATE_EXCEPTION')
    $result = Invoke-WorkflowFixture -Script ("function pwsh { throw 'SYNTHETIC_PRIVATE_EXCEPTION' }`n" + $runtime.Replace('${{ inputs.mode }}', 'lifecycle')) -Name 'runtime-exception' -ExitCode 0
    Add-CheckResult -Name 'Unexpected runtime invocation exception remains private' -Success ($result.ExitCode -ne 0 -and $result.Public -match 'PODMAN_RUNTIME_FAILED' -and $result.Public -notmatch 'SYNTHETIC_PRIVATE' -and $result.Private -match 'SYNTHETIC_PRIVATE_EXCEPTION')
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
