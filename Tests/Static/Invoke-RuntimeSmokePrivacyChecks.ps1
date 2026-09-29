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
    $mixed=@(Get-WorkflowBlocks 'runtime-smoke-mixed-providers.yml')
    $hyperv=@(
        Get-WorkflowBlocks 'runtime-smoke-hyperv.yml' 'Hyper-V preflight'
        Get-WorkflowBlocks 'runtime-smoke-hyperv.yml' 'Hyper-V lifecycle smoke'
    )
    $adapter=@(Get-WorkflowBlocks 'adapter-smoke-github-hosted.yml')
    $fixture=@'
param([string]$Version,[string]$Provider)
Write-Output 'SYNTHETIC_PRIVATE_HOST sentinel.invalid'
[Console]::Error.WriteLine('SYNTHETIC_PRIVATE_SECRET fixture-value')
Write-Host 'SYNTHETIC_PRIVATE_INFORMATION'
Add-Content $env:PRIVACY_FIXTURE_TRACE ([IO.Path]::GetFileName($PSCommandPath)+"|$Version|$Provider")
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
            $result=Invoke-WorkflowFixture -Script $entry.Block -Name ($entry.Name+'-'+$case.Name) -ExitCode $case.Code -FailureStage $case.Stage
            $expected=$entry.Result+$(if($case.Name -eq 'success'){'_SUCCEEDED'}else{'_FAILED'})
            Add-CheckResult -Name "$($entry.Name) $($case.Name) executes exact invocation and keeps streams private" -Success (
                $result.Public -notmatch 'SYNTHETIC_PRIVATE' -and $result.Private -match 'SYNTHETIC_PRIVATE_HOST' -and $result.Private -match 'SYNTHETIC_PRIVATE_SECRET' -and
                $result.Public -match $expected -and ($result.Trace -join '') -ceq $entry.Trace -and
                (($case.Name -eq 'success' -and $result.ExitCode -eq 0) -or ($case.Name -ne 'success' -and $result.ExitCode -ne 0)))
        }
    }
    $result=Invoke-WorkflowFixture -Script ("function docker { `$global:LASTEXITCODE=0 }`nfunction sqlcmd { `$global:LASTEXITCODE=0 }`n"+$mixed[0]) -Name 'mixed-podman-failure' -ExitCode 23
    Add-CheckResult -Name 'Mixed Podman initialization failure cannot be masked by later sqlcmd success' -Success (
        $result.ExitCode -ne 0 -and $result.Public -match 'INFRASTRUCTURE_UNAVAILABLE' -and $result.Public -notmatch 'SYNTHETIC_PRIVATE' -and $result.Private -match 'SYNTHETIC_PRIVATE_SECRET')
    $result=Invoke-WorkflowFixture -Script ("function docker { throw 'SYNTHETIC_PRIVATE_EXCEPTION' }`n"+$mixed[0]) -Name 'mixed-preflight-exception' -ExitCode 0
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
        $mixed[1] -match 'FromMinutes\(10\)' -and $mixed[1] -match '\$smokeExitCode -ne 0' -and
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
