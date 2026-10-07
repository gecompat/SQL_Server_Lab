param([string[]]$Case = @())

# Execute the unchanged runner in a synthetic repository and isolated processes.
# Pester discovery/invocation are synthetic; no module installation or provider.
$pesterFixtureParent = Join-Path $repoRoot '.artifacts/test-runs'
foreach ($fixtureAncestor in @($repoRoot, (Join-Path $repoRoot '.artifacts'), $pesterFixtureParent)) {
    if (Test-Path -LiteralPath $fixtureAncestor) {
        $ancestorItem = Get-Item -LiteralPath $fixtureAncestor -Force
        if (-not $ancestorItem.PSIsContainer -or
            ($ancestorItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'PESTER_FIXTURE_ROOT_UNSAFE'
        }
    }
}
$pesterFixtureRoot = Join-Path $pesterFixtureParent ('pester-runner-' + [guid]::NewGuid().ToString('N'))
$pesterFixtureRoot = [IO.Path]::GetFullPath($pesterFixtureRoot)
$null = New-Item -ItemType Directory -Path (Join-Path $pesterFixtureRoot 'Tests/Static') -Force
$null = New-Item -ItemType Directory -Path (Join-Path $pesterFixtureRoot 'Tests/Common') -Force
$null = New-Item -ItemType Directory -Path (Join-Path $pesterFixtureRoot 'Tests/Pester') -Force
$pesterFixtureRunner = Join-Path $pesterFixtureRoot 'Tests/Static/Invoke-PesterChecks.ps1'
Copy-Item -LiteralPath (Join-Path $repoRoot 'Tests/Static/Invoke-PesterChecks.ps1') -Destination $pesterFixtureRunner
Copy-Item -LiteralPath (Join-Path $repoRoot 'Tests/Common/CheckResult.ps1') -Destination (Join-Path $pesterFixtureRoot 'Tests/Common/CheckResult.ps1')
$pesterFixtureWrapper = Join-Path $pesterFixtureRoot 'Invoke-Fixture.ps1'
$pesterFixtureWrapperText = @'
param([string]$Case)
$ErrorActionPreference = 'Stop'
$PSModuleAutoLoadingPreference = 'None'
Import-Module Microsoft.PowerShell.Management, Microsoft.PowerShell.Utility
function Get-Module {
    param([switch]$ListAvailable, [string]$Name)
    if ($Name -ne 'Pester') { throw 'UNEXPECTED_MODULE_DISCOVERY' }
    if ($Case -eq 'Missing') { return }
    $version = if ($Case -eq 'Legacy') { '3.4.0' } elseif ($Case -eq 'Modern6') { '6.0.0' } else { '5.7.0' }
    [pscustomobject]@{Version=[version]$version;Path='synthetic-pester.psm1'}
}
function Import-Module {
    param([string]$Name,[switch]$Force)
    if ($Name -ne 'synthetic-pester.psm1') { throw 'UNPINNED_MODULE_IMPORT' }
    if ($Case -eq 'ImportFailure') { throw 'SYNTHETIC_IMPORT_FAILURE' }
    $script:PesterImported = $true
}
function New-PesterConfiguration {
    if (-not $script:PesterImported) { throw 'PESTER_NOT_IMPORTED' }
    [pscustomobject]@{Run=[pscustomobject]@{Path=@();PassThru=$false};Output=[pscustomobject]@{Verbosity=''}}
}
function Invoke-Pester {
    param($Configuration,$Script,[switch]$PassThru)
    if ($Case -eq 'InvocationFailure') { throw 'SYNTHETIC_INVOCATION_FAILURE' }
    if ($Case -eq 'NoResult') { return }
    if ($null -eq $Configuration -or -not $Configuration.Run.PassThru -or
        @($Configuration.Run.Path).Count -ne 1 -or
        $Configuration.Run.Path[0] -ne (Join-Path $PSScriptRoot 'Tests/Pester')) { throw 'INVALID_PESTER_CONFIGURATION' }
    $result=[pscustomobject]@{TotalCount=2;PassedCount=2;FailedCount=0;SkippedCount=0;NotRunCount=0;InconclusiveCount=0;FailedContainersCount=0;Result='Passed'}
    switch ($Case) {
        Empty {$result.TotalCount=0;$result.PassedCount=0}
        Failed {$result.PassedCount=1;$result.FailedCount=1;$result.Result='Failed'}
        Skipped {$result.PassedCount=1;$result.SkippedCount=1}
        NotRun {$result.PassedCount=1;$result.NotRunCount=1}
        Inconclusive {$result.PassedCount=1;$result.InconclusiveCount=1}
        ContainerFailure {$result.FailedContainersCount=1;$result.Result='Failed'}
        Malformed {$result.TotalCount=3}
    }
    $result
}
& (Join-Path $PSScriptRoot 'Tests/Static/Invoke-PesterChecks.ps1')
exit $LASTEXITCODE
'@
[IO.File]::WriteAllText($pesterFixtureWrapper,$pesterFixtureWrapperText,[Text.UTF8Encoding]::new($false))
$pesterFixtureCases = @(
    @{Name='Missing';Exit=2;Status='INFRASTRUCTURE_UNAVAILABLE.*NOT_EXECUTED'},
    @{Name='Legacy';Exit=2;Status='INFRASTRUCTURE_UNAVAILABLE.*NOT_EXECUTED'},
    @{Name='Modern5';Exit=0;Status='Pester: PASS'},
    @{Name='Modern6';Exit=0;Status='Pester: PASS'},
    @{Name='Empty';Exit=1;Status='Pester: FAIL'},
    @{Name='Failed';Exit=1;Status='Pester: FAIL'},
    @{Name='Skipped';Exit=2;Status='Pester: NOT_EXECUTED'},
    @{Name='NotRun';Exit=2;Status='Pester: NOT_EXECUTED'},
    @{Name='Inconclusive';Exit=2;Status='Pester: NOT_EXECUTED'},
    @{Name='ContainerFailure';Exit=1;Status='Pester: FAIL'},
    @{Name='Malformed';Exit=1;Status='Pester: FAIL'},
    @{Name='NoResult';Exit=1;Status='Pester: FAIL'},
    @{Name='ImportFailure';Exit=1;Status='Pester: FAIL'},
    @{Name='InvocationFailure';Exit=1;Status='Pester: FAIL'}
)
try {
    foreach ($pesterCase in $pesterFixtureCases) {
        if ($Case.Count -gt 0 -and $pesterCase.Name -notin $Case) { continue }
        $startInfo=[Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName=(Get-Command pwsh -ErrorAction Stop).Source
        $startInfo.UseShellExecute=$false
        $startInfo.CreateNoWindow=$true
        $startInfo.RedirectStandardOutput=$true
        $startInfo.RedirectStandardError=$true
        foreach ($argument in @('-NoLogo','-NoProfile','-NonInteractive','-File',$pesterFixtureWrapper,'-Case',$pesterCase.Name)) { $startInfo.ArgumentList.Add($argument) }
        $child=[Diagnostics.Process]::new();$child.StartInfo=$startInfo
        try {
            $null=$child.Start()
            $stdout=$child.StandardOutput.ReadToEndAsync();$stderr=$child.StandardError.ReadToEndAsync()
            if (-not $child.WaitForExit(15000)) { $child.Kill($true);$child.WaitForExit();throw 'PESTER_FIXTURE_TIMEOUT' }
            $output=$stdout.GetAwaiter().GetResult()+$stderr.GetAwaiter().GetResult()
            if ($output.Length -gt 65536) { throw 'PESTER_FIXTURE_OUTPUT_LIMIT' }
            $statusMatches=$output -match ('(?s)'+$pesterCase.Status)
            $falsePass=$pesterCase.Exit -ne 0 -and $output -match '\bPASS\b'
            Add-CheckResult -Name "Pester runner $($pesterCase.Name): bounded process and truthful status" -Success (
                $child.ExitCode -eq $pesterCase.Exit -and $statusMatches -and -not $falsePass
            ) -Message "Exitcode $($child.ExitCode); expected $($pesterCase.Exit); status match $statusMatches; false PASS $falsePass"
        }
        finally {
            if ($child.Id -and -not $child.HasExited) { $child.Kill($true); $child.WaitForExit() }
            $child.Dispose()
        }
    }
}
finally {
    $resolvedParent=[IO.Path]::GetFullPath($pesterFixtureParent)+[IO.Path]::DirectorySeparatorChar
    $rootItem=Get-Item -LiteralPath $pesterFixtureRoot -Force
    if (-not $pesterFixtureRoot.StartsWith($resolvedParent,[StringComparison]::OrdinalIgnoreCase) -or
        ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        @(Get-ChildItem -LiteralPath $pesterFixtureRoot -Recurse -Force | Where-Object {($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0}).Count -gt 0) {
        throw 'PESTER_FIXTURE_CLEANUP_UNSAFE'
    }
    Remove-Item -LiteralPath $pesterFixtureRoot -Recurse -Force
}
