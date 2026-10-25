#Requires -Version 7.2
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$temporaryParent = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath ([IO.Path]::GetTempPath())).ProviderPath).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
$fixtureLeaf = 'runtime-ci-privacy-' + [guid]::NewGuid().ToString('N')
$root = Join-Path $temporaryParent $fixtureLeaf
$rootCreated = $false
$failures = [Collections.Generic.List[string]]::new()
$passed = 0
. (Join-Path $PSScriptRoot '../Common/CheckResult.ps1')

function Invoke-WorkflowFixture {
    param([string]$Script, [string]$Name, [int]$ExitCode, [string]$FailureStage = '', [switch]$ClearRunnerTemp)
    $directory = Join-Path $root $Name
    $null = New-Item -ItemType Directory -Path $directory
    $runnerTemp = Join-Path $directory 'runner-temp'
    $policyRoot = Join-Path $directory 'owned-state'
    $null = New-Item -ItemType Directory -Path $runnerTemp, $policyRoot
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
    $start.Environment['RUNNER_TEMP'] = $runnerTemp
    $start.Environment['SQL_SERVER_LAB_CI_OWN_STATE_ROOT'] = $policyRoot
    $start.Environment['GITHUB_ENV'] = Join-Path $directory 'github-env.txt'
    $start.Environment['GITHUB_OUTPUT'] = Join-Path $directory 'outputs.txt'
    $start.Environment['GITHUB_STEP_SUMMARY'] = Join-Path $directory 'summary.txt'
    $start.Environment['PRIVACY_FIXTURE_EXIT'] = [string]$ExitCode
    $start.Environment['PRIVACY_FIXTURE_STAGE'] = $FailureStage
    $start.Environment['PRIVACY_FIXTURE_TRACE'] = Join-Path $directory 'trace.txt'
    $start.Environment['PRIVACY_FIXTURE_STATE_TRACE'] = Join-Path $directory 'state-trace.txt'
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
        $private = (@(Get-ChildItem -LiteralPath $directory -Recurse -Filter '*.private.log' | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }) -join "`n")
        $trace = if (Test-Path -LiteralPath $start.Environment['PRIVACY_FIXTURE_TRACE']) { @(Get-Content -LiteralPath $start.Environment['PRIVACY_FIXTURE_TRACE']) } else { @() }
        $stateTrace = if (Test-Path -LiteralPath $start.Environment['PRIVACY_FIXTURE_STATE_TRACE']) { @(Get-Content -LiteralPath $start.Environment['PRIVACY_FIXTURE_STATE_TRACE']) } else { @() }
        if ($ClearRunnerTemp) {
            $item = Get-Item -LiteralPath $runnerTemp -Force
            if ($item.FullName -cne [IO.Path]::GetFullPath((Join-Path $directory 'runner-temp')) -or
                @(@($item) + @(Get-ChildItem -LiteralPath $runnerTemp -Recurse -Force) | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count) {
                throw 'PRIVACY_FIXTURE_RUNNER_TEMP_SCOPE_INVALID'
            }
            Remove-Item -LiteralPath $runnerTemp -Recurse -Force
        }
        $retainedPath = Join-Path $policyRoot 'mixed-provider-smoke.private.log'
        $retained = if (Test-Path -LiteralPath $retainedPath) { Get-Content -LiteralPath $retainedPath -Raw } else { '' }
        return [pscustomobject]@{ ExitCode = $process.ExitCode; Public = $public; Private = $private; Trace = @($trace); StateTrace = @($stateTrace); PolicyRoot = $policyRoot; RetainedPrivate = $retained; RunnerTempAbsent = -not (Test-Path -LiteralPath $runnerTemp) }
    }
    finally { $process.Dispose() }
}

function Get-WorkflowBlocks([string]$Name,[string]$StepName) {
    $text=Get-Content (Join-Path $repoRoot ".github/workflows/$Name") -Raw
    if ($StepName) {
        $step=[regex]::Match($text,'(?ms)^      - name: '+[regex]::Escape($StepName)+'\r?\n(?<step>.*?)(?=^      - name:|\z)')
        if (-not $step.Success) { throw 'PRIVACY_WORKFLOW_STEP_MISSING' }
        $text=$step.Groups['step'].Value
    }
    @([regex]::Matches($text,'(?m)^        run: \|\r?\n(?<body>(?:^          [^\r\n]*\r?\n|^\r?\n)+)')|ForEach-Object {
        [regex]::Replace($_.Groups['body'].Value,'(?m)^          ','')
    })
}

function Invoke-BashFixture([string]$Script,[string]$Name,[int]$ExitCode) {
    $bash=if($IsWindows){Join-Path (Split-Path (Split-Path (Get-Command git -ErrorAction Stop).Source -Parent) -Parent) 'bin/bash.exe'}else{(Get-Command bash -ErrorAction Stop).Source}
    if(-not (Test-Path -LiteralPath $bash)){throw 'PRIVACY_FIXTURE_GIT_BASH_REQUIRED'}
    $directory=Join-Path $root $Name;$null=New-Item -ItemType Directory -Path $directory
    $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=$bash
    $start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    $start.WorkingDirectory=$directory
    $start.ArgumentList.Add('-c');$start.ArgumentList.Add($Script.Replace("`r",''))
    $start.Environment['RUNNER_TEMP']=$directory.Replace('\','/')
    $start.Environment['GITHUB_PATH']=(Join-Path $directory 'github-path.txt').Replace('\','/')
    $start.Environment['PRIVACY_FIXTURE_EXIT']=[string]$ExitCode
    $process=[Diagnostics.Process]::Start($start)
    try {
        $out=$process.StandardOutput.ReadToEndAsync();$err=$process.StandardError.ReadToEndAsync()
        if(-not $process.WaitForExit(30000)){$process.Kill($true);$process.WaitForExit();throw 'PRIVACY_FIXTURE_TIMEOUT'}
        [pscustomobject]@{ExitCode=$process.ExitCode;Public=($out.GetAwaiter().GetResult()+$err.GetAwaiter().GetResult());Private=(@(Get-ChildItem $directory -Filter '*.private.log'|ForEach-Object {Get-Content $_.FullName -Raw})-join "`n")}
    }finally{$process.Dispose()}
}

try {
    $null=New-Item -ItemType Directory -Path $root
    $rootCreated=$true
    $null=New-Item -ItemType Directory -Path (Join-Path $root 'Tests/Integration')
    $null=New-Item -ItemType Directory -Path (Join-Path $root 'Tests/Common'), (Join-Path $root 'Tools')
    [IO.File]::WriteAllText((Join-Path $root 'Tests/Common/OwnedHostTestScope.ps1'), 'function Initialize-OwnedHostTestRoot { param($Module,$StateRoot,$Providers,$ParentOperationId); $null=New-Item -ItemType Directory -Path $StateRoot }')
    [IO.File]::WriteAllText((Join-Path $root 'Tools/Initialize-SqlServerLabHostTools.ps1'), 'param($Name); [pscustomobject]@{Available=($env:PRIVACY_FIXTURE_STAGE -cne ''tools-unavailable'')}')
    $mixed=@(Get-WorkflowBlocks 'runtime-smoke-mixed-providers.yml')
    $hyperv=@(
        Get-WorkflowBlocks 'runtime-smoke-hyperv.yml' 'Hyper-V preflight'
        Get-WorkflowBlocks 'runtime-smoke-hyperv.yml' 'Hyper-V lifecycle smoke'
    )
    $adapter=@(Get-WorkflowBlocks 'adapter-smoke-github-hosted.yml')
    $fixture=@'
param([string]$Version,[string]$Provider,[string]$StateRoot)
Write-Output 'SYNTHETIC_PRIVATE_HOST sentinel.invalid'
[Console]::Error.WriteLine('SYNTHETIC_PRIVATE_SECRET fixture-value')
Write-Host 'SYNTHETIC_PRIVATE_INFORMATION'
Add-Content $env:PRIVACY_FIXTURE_TRACE ([IO.Path]::GetFileName($PSCommandPath)+"|$Version|$Provider")
if($StateRoot){Add-Content $env:PRIVACY_FIXTURE_STATE_TRACE $StateRoot}
if($env:PRIVACY_FIXTURE_STAGE -eq 'throw'){throw 'SYNTHETIC_PRIVATE_EXCEPTION'}
exit ([int]$env:PRIVACY_FIXTURE_EXIT)
'@
    foreach($name in @('Invoke-MixedProviderSmokeTest.ps1','Invoke-HyperVSmokeTest.ps1','Invoke-AdapterSmokeTest.ps1','Initialize-PodmanRuntime.ps1')) {
        [IO.File]::WriteAllText((Join-Path $root "Tests/Integration/$name"),$fixture)
    }
    [IO.File]::WriteAllText((Join-Path $root 'native-fixture.ps1'),$fixture)
    $shim=@'
function docker { & pwsh -NoLogo -NoProfile -File ./native-fixture.ps1; $global:LASTEXITCODE=$LASTEXITCODE }
function sqlcmd { & pwsh -NoLogo -NoProfile -File ./native-fixture.ps1; $global:LASTEXITCODE=$LASTEXITCODE }
function Get-VMHost { Write-Output 'SYNTHETIC_PRIVATE_HOST'; if([int]$env:PRIVACY_FIXTURE_EXIT){throw 'SYNTHETIC_PRIVATE_EXCEPTION'} }
function Get-Command { Write-Output 'SYNTHETIC_PRIVATE_TOOLS' }
function Import-Module { [pscustomobject]@{Name='SyntheticFixtureModule'} }
'@
    foreach($entry in @(@{Name='mixed';Block=$mixed[0]},@{Name='hyperv';Block=$hyperv[0]})) {
        foreach($code in @(0,19)) {
            $result=Invoke-WorkflowFixture -Script ($shim+"`n"+$entry.Block) -Name ($entry.Name+"-preflight-$code") -ExitCode $code
            Add-CheckResult -Name "$($entry.Name) preflight $code preserves classification without raw forwarding" -Success (
                $result.Public -notmatch 'SYNTHETIC_PRIVATE' -and $result.Private -match 'SYNTHETIC_PRIVATE' -and
                (($code -eq 0 -and $result.ExitCode -eq 0 -and $result.Public -match 'validation_classification=VALIDATED') -or
                ($code -ne 0 -and $result.ExitCode -ne 0 -and $result.Public -match 'INFRASTRUCTURE_UNAVAILABLE')))
        }
    }
    $cases=@(
        @{Name='mixed';Block=$mixed[1].Replace('SQL_Server_Lab_Runtime_Smoke',('PrivacyFixture_'+[guid]::NewGuid().ToString('N')));Trace='Invoke-MixedProviderSmokeTest.ps1||';Result='MIXED_RUNTIME'},
        @{Name='hyperv';Block=$hyperv[1];Trace='Invoke-HyperVSmokeTest.ps1||';Result='HYPERV_LIFECYCLE'},
        @{Name='adapter';Block=$adapter[1];Trace='Invoke-AdapterSmokeTest.ps1|2025|docker';Result='ADAPTER_RUNTIME'}
    )
    foreach($entry in $cases) {
        foreach($case in @(@{Name='success';Code=0;Stage=''},@{Name='exit';Code=23;Stage=''},@{Name='throw';Code=0;Stage='throw'})) {
            $result=Invoke-WorkflowFixture -Script $entry.Block -Name ($entry.Name+'-'+$case.Name) -ExitCode $case.Code -FailureStage $case.Stage -ClearRunnerTemp:($entry.Name -ceq 'mixed')
            $expected=$entry.Result+$(if($case.Name -eq 'success'){'_SUCCEEDED'}else{'_FAILED'})
            Add-CheckResult -Name "$($entry.Name) $($case.Name) executes exact invocation and keeps streams private" -Success (
                $result.Public -notmatch 'SYNTHETIC_PRIVATE' -and $result.Private -match 'SYNTHETIC_PRIVATE_HOST' -and $result.Private -match 'SYNTHETIC_PRIVATE_SECRET' -and
                $result.Public -match $expected -and ($result.Trace -join '') -ceq $entry.Trace -and
                (($case.Name -eq 'success' -and $result.ExitCode -eq 0) -or ($case.Name -ne 'success' -and $result.ExitCode -ne 0)))
            if($entry.Name -ceq 'mixed') {
                Add-CheckResult -Name "Mixed $($case.Name) retains bound private diagnostics after runner-temp cleanup" -Success (
                    $result.RunnerTempAbsent -and $result.RetainedPrivate -match 'SYNTHETIC_PRIVATE_HOST' -and
                    $result.RetainedPrivate -match 'SYNTHETIC_PRIVATE_SECRET' -and $result.StateTrace.Count -eq 1 -and
                    $result.StateTrace[0] -ceq $result.PolicyRoot)
            }
        }
    }
    $legacy = $mixed[1].Replace('SQL_Server_Lab_Runtime_Smoke', ('PrivacyFixture_' + [guid]::NewGuid().ToString('N'))).Replace("`$env:SQL_SERVER_LAB_CI_OWN_STATE_ROOT 'mixed-provider-smoke.private.log'", "`$env:RUNNER_TEMP 'mixed-provider-smoke.private.log'")
    $result = Invoke-WorkflowFixture -Script $legacy -Name 'mixed-legacy-loss' -ExitCode 0 -ClearRunnerTemp
    Add-CheckResult -Name 'Legacy runner-temp log loses diagnostics after runner cleanup' -Success (
        $legacy -cne $mixed[1] -and $result.ExitCode -eq 0 -and $result.RunnerTempAbsent -and
        $result.Private -match 'SYNTHETIC_PRIVATE_SECRET' -and [string]::IsNullOrEmpty($result.RetainedPrivate))
    $result=Invoke-WorkflowFixture -Script ($shim+"`n"+$mixed[0]) -Name 'mixed-podman-failure' -ExitCode 0 -FailureStage 'tools-unavailable'
    Add-CheckResult -Name 'Mixed unavailable host tool stops before sqlcmd without raw forwarding' -Success (
        $result.ExitCode -ne 0 -and $result.Public -match 'INFRASTRUCTURE_UNAVAILABLE' -and
        $result.Public -notmatch 'SYNTHETIC_PRIVATE' -and $result.Private -match 'OWNED_HOST_TEST_TOOL_UNAVAILABLE' -and $result.Trace.Count -eq 0)
    $result=Invoke-WorkflowFixture -Script ("function Import-Module { throw 'SYNTHETIC_PRIVATE_EXCEPTION' }`n"+$mixed[0]) -Name 'mixed-preflight-exception' -ExitCode 0
    Add-CheckResult -Name 'Mixed unexpected preflight exception stays private' -Success ($result.ExitCode -ne 0 -and $result.Public -notmatch 'SYNTHETIC_PRIVATE' -and $result.Private -match 'SYNTHETIC_PRIVATE_EXCEPTION')
    $bashShim=@'
fixture_native() { printf '%s\n' 'SYNTHETIC_PRIVATE_HOST sentinel.invalid'; printf '%s\n' 'SYNTHETIC_PRIVATE_SECRET fixture-value' >&2; return "$PRIVACY_FIXTURE_EXIT"; }
lsb_release() { printf '%s\n' '22.04'; }
curl() { fixture_native; }
dpkg-deb() { fixture_native; }
sudo() { fixture_native; }
fixture_sqlcmd() { fixture_native; }
docker() { fixture_native; }
xargs() { cat >/dev/null; fixture_native; }
'@
    foreach($code in @(0,19)) {
        $result=Invoke-BashFixture -Script ($bashShim+"`n"+$adapter[0].Replace('/opt/mssql-tools18/bin/sqlcmd','fixture_sqlcmd')) -Name "adapter-install-$code" -ExitCode $code
        Add-CheckResult -Name "Bash install $code captures native streams and preserves failure" -Success (
            $result.Public -notmatch 'SYNTHETIC_PRIVATE' -and $result.Private -match 'SYNTHETIC_PRIVATE_SECRET' -and
            (($code -eq 0 -and $result.ExitCode -eq 0 -and $result.Public -match 'ADAPTER_INSTALL_SUCCEEDED') -or
            ($code -ne 0 -and $result.ExitCode -ne 0 -and $result.Public -match 'ADAPTER_INSTALL_FAILED')))
        $result=Invoke-BashFixture -Script ($bashShim+"`n"+$adapter[2]) -Name "adapter-cleanup-$code" -ExitCode $code
        Add-CheckResult -Name "Bash cleanup $code preserves existing best-effort semantics without raw output" -Success (
            $result.ExitCode -eq 0 -and $result.Public -notmatch 'SYNTHETIC_PRIVATE' -and $result.Public -match 'ADAPTER_CLEANUP_COMPLETED' -and $result.Private -match 'SYNTHETIC_PRIVATE_SECRET')
    }
    $result=Invoke-BashFixture -Script ($bashShim+"`nfixture_sqlcmd() { fixture_native; return 23; }`n"+$adapter[0].Replace('/opt/mssql-tools18/bin/sqlcmd','fixture_sqlcmd')) -Name 'adapter-install-late-failure' -ExitCode 0
    Add-CheckResult -Name 'Bash final sqlcmd failure remains a failed sanitized install step' -Success ($result.ExitCode -ne 0 -and $result.Public -match 'ADAPTER_INSTALL_FAILED' -and $result.Public -notmatch 'SYNTHETIC_PRIVATE' -and $result.Private -match 'SYNTHETIC_PRIVATE_SECRET')
    $dispatch=Get-Content (Join-Path $repoRoot '.github/workflows/static-contracts.yml') -Raw
    $workflow=Get-Content (Join-Path $repoRoot '.github/workflows/runtime-smoke-hyperv.yml') -Raw
    $mixedWorkflow=Get-Content (Join-Path $repoRoot '.github/workflows/runtime-smoke-mixed-providers.yml') -Raw
    Add-CheckResult -Name 'PR HyperV dispatch retains lifecycle default and never selects shared environments' -Success (
        $dispatch -match '(?s)hyperv-runtime:.*?uses: \./\.github/workflows/runtime-smoke-hyperv.yml\s+adapter-runtime:' -and
        $workflow -match '(?s)workflow_call:.*?mode:.*?default: lifecycle' -and
        $workflow -match "if: inputs.mode == 'shared-environments'")
    Add-CheckResult -Name 'Mixed gate retains timeout mutex exit guard and cleanup without uploads' -Success (
        $mixedWorkflow -match 'timeout-minutes: 20' -and $mixedWorkflow -match 'cancel-in-progress: false' -and
        $mixed[1] -match 'FromMinutes\(2\)' -and $mixed[1] -match '\$smokeExitCode -ne 0' -and
        $mixedWorkflow -match '(?s)name: Mixed provider smoke test\s+timeout-minutes: 10' -and
        $mixedWorkflow -match 'Complete-OwnedHostTestRoot\.ps1 -StateRoot \$env:SQL_SERVER_LAB_CI_OWN_STATE_ROOT' -and
        $mixed[1] -match '\$mutex.ReleaseMutex\(\)' -and $mixed[1] -match '\$mutex.Dispose\(\)' -and
        $mixedWorkflow -notmatch 'Tee-Object|upload-artifact|Exception.Message')
}
finally {
    if($rootCreated -and (Test-Path -LiteralPath $root)) {
        $target=Get-Item -LiteralPath $root -Force
        $resolved=[IO.Path]::GetFullPath((Resolve-Path -LiteralPath $root).ProviderPath)
        $comparison=if($IsWindows){[StringComparison]::OrdinalIgnoreCase}else{[StringComparison]::Ordinal}
        if(($target.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
            -not $resolved.Equals([IO.Path]::GetFullPath($root),$comparison) -or
            -not ([IO.Path]::GetDirectoryName($resolved)).Equals($temporaryParent,$comparison) -or
            $target.Name -cne $fixtureLeaf -or $fixtureLeaf -cnotmatch '^runtime-ci-privacy-[a-f0-9]{32}$'){throw 'PRIVACY_FIXTURE_CLEANUP_SCOPE_INVALID'}
        $items=@(Get-ChildItem -LiteralPath $resolved -Recurse -Force)
        foreach($item in $items){if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or -not $item.FullName.StartsWith($resolved+[IO.Path]::DirectorySeparatorChar,$comparison)){throw 'PRIVACY_FIXTURE_CLEANUP_CONTENT_INVALID'}}
        foreach($item in @($items|Where-Object {-not $_.PSIsContainer})){Remove-Item -LiteralPath $item.FullName -Force}
        foreach($item in @($items|Where-Object PSIsContainer|Sort-Object {$_.FullName.Length} -Descending)){Remove-Item -LiteralPath $item.FullName -Force}
        Remove-Item -LiteralPath $resolved -Force
    }
}
Write-Host "Runtime smoke privacy: $passed PASS / $($failures.Count) FAIL"
if($failures.Count){exit 1}
