# Execute the actual workflow blocks with synthetic process/issue boundaries only.
$nightlySource = Get-Content (Join-Path $repoRoot '.github/workflows/nightly-regression.yml') -Raw
$hypervSource = Get-Content (Join-Path $repoRoot '.github/workflows/runtime-smoke-hyperv.yml') -Raw
function Get-NightlyFixtureBlock([string]$Source,[string]$Name) {
    $match = [regex]::Match($Source, '(?ms)^      - name: ' + [regex]::Escape($Name) + '\r?\n(?:(?!^      - name:|^  [\w-]+:).)*?        run: \|\r?\n(?<body>(?:^          [^\r\n]*\r?\n|^[ \t]*\r?\n)+)')
    if (-not $match.Success) { throw 'SYNTHETIC_WORKFLOW_BLOCK_MISSING' }
    return [regex]::Replace($match.Groups['body'].Value,'(?m)^          ','')
}
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-nightly-auth-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $fixtureRoot
function Invoke-NightlyAuthorizationFixture {
    param([string]$Name,[string]$Body,[hashtable]$Values=@{},[int]$NativeExit=0)
    $directory = Join-Path $fixtureRoot $Name
    $null = New-Item -ItemType Directory -Path $directory
    $prefix = @'
$ErrorActionPreference = 'Stop'
function pwsh {
    param([Parameter(ValueFromRemainingArguments)]$Arguments)
    [IO.File]::AppendAllText((Join-Path $env:RUNNER_TEMP 'trace.txt'), (($Arguments -join ' ') + "`n"))
    Write-Output 'PRIVATE_SYNTHETIC_DIAGNOSTIC'
    $global:LASTEXITCODE = [int]$env:SYNTHETIC_NATIVE_EXIT
}
function gh {
    param([Parameter(ValueFromRemainingArguments)]$Arguments)
    if (($Arguments[0..1] -join ' ') -eq 'issue list') { return '[]' }
    [IO.File]::AppendAllText((Join-Path $env:RUNNER_TEMP 'issue.txt'), (($Arguments -join ' ') + "`n"))
}
'@
    $scriptPath = Join-Path $directory 'fixture.ps1'
    Set-Content -LiteralPath $scriptPath -Value ($prefix + "`n" + $Body) -Encoding utf8
    $start = [Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
    $start.UseShellExecute=$false; $start.CreateNoWindow=$true
    $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
    foreach ($argument in @('-NoProfile','-File',$scriptPath)) { $start.ArgumentList.Add($argument) }
    $environment = @{RUNNER_TEMP=$directory; GITHUB_OUTPUT=(Join-Path $directory 'output.txt'); EVENT_NAME='workflow_dispatch'; EVENT_REPOSITORY='synthetic/repo'; REPOSITORY='synthetic/repo'; CONFIRM_SHARED_MUTATION='false'; SYNTHETIC_NATIVE_EXIT=[string]$NativeExit; RUN_URL='https://example.invalid/synthetic'}
    foreach ($key in $Values.Keys) { $environment[$key]=$Values[$key] }
    foreach ($key in $environment.Keys) { $start.Environment[$key]=[string]$environment[$key] }
    $process=[Diagnostics.Process]::Start($start)
    $stdout=$process.StandardOutput.ReadToEndAsync(); $stderr=$process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(30000)) { $process.Kill($true); $process.WaitForExit(); throw 'SYNTHETIC_WORKFLOW_TIMEOUT' }
    $outputPath=Join-Path $directory 'output.txt'; $tracePath=Join-Path $directory 'trace.txt'; $issuePath=Join-Path $directory 'issue.txt'
    $result=@{Exit=$process.ExitCode; Public=$stdout.GetAwaiter().GetResult()+$stderr.GetAwaiter().GetResult(); Output=''; Trace=''; Issue=''}
    if (Test-Path $outputPath) { $result.Output=Get-Content $outputPath -Raw }
    if (Test-Path $tracePath) { $result.Trace=Get-Content $tracePath -Raw }
    if (Test-Path $issuePath) { $result.Issue=Get-Content $issuePath -Raw }
    $process.Dispose()
    return $result
}
try {
    $authorization=Get-NightlyFixtureBlock $nightlySource 'Authorize shared environment mutation'
    $hypervGuard=Get-NightlyFixtureBlock $hypervSource 'Authorize shared environment mutation'
    $recover=Get-NightlyFixtureBlock $hypervSource 'Recover registered Windows test environments'
    $accept=Get-NightlyFixtureBlock $hypervSource 'Accept all shared SQL test environments and CMS'
    $nightlyAccept=Get-NightlyFixtureBlock $nightlySource 'SQL, write access and CMS consistency'
    $cases=@(
        @{Name='schedule'; Values=@{EVENT_NAME='schedule'; CONFIRM_SHARED_MUTATION='true'}; Allowed=$false},
        @{Name='default'; Values=@{}; Allowed=$false},
        @{Name='foreign'; Values=@{EVENT_REPOSITORY='synthetic/other'; CONFIRM_SHARED_MUTATION='true'}; Allowed=$false},
        @{Name='call'; Values=@{EVENT_NAME='workflow_call'; CONFIRM_SHARED_MUTATION='true'}; Allowed=$false},
        @{Name='missing-repo'; Values=@{REPOSITORY=''; EVENT_REPOSITORY=''; CONFIRM_SHARED_MUTATION='true'}; Allowed=$false},
        @{Name='malformed'; Values=@{CONFIRM_SHARED_MUTATION='True'}; Allowed=$false},
        @{Name='explicit'; Values=@{CONFIRM_SHARED_MUTATION='true'}; Allowed=$true}
    )
    foreach($case in $cases) {
        $decision=Invoke-NightlyAuthorizationFixture ('decision-'+$case.Name) $authorization $case.Values
        $expected=if($case.Allowed){'true'}else{'false'}
        Add-CheckResult -Name "Nightly echte Autorisierung $($case.Name)" -Success ($decision.Exit -eq 0 -and $decision.Output -match "authorized=$expected")
        foreach($flow in @('nightly','hyperv')) {
            $body=if($flow -eq 'nightly'){$nightlyAccept}else{$hypervGuard+"`n"+$recover+"`n"+$accept}
            $execution=Invoke-NightlyAuthorizationFixture ($flow+'-'+$case.Name) $body $case.Values
            $expectedCount=if($flow -eq 'nightly'){1}else{2}
            $count=@($execution.Trace -split "`n" | Where-Object {$_}).Count
            $correct=if($case.Allowed){$execution.Exit -eq 0 -and $count -eq $expectedCount}else{$execution.Exit -ne 0 -and $count -eq 0 -and $execution.Public -match 'SHARED_ENVIRONMENT_MUTATION_NOT_AUTHORIZED'}
            Add-CheckResult -Name "$flow echte Mutationsgrenze $($case.Name), kein Diagnoseleak" -Success ($correct -and $execution.Public -notmatch 'PRIVATE_SYNTHETIC_DIAGNOSTIC')
        }
    }
    foreach($flow in @('nightly','hyperv')) {
        $body=if($flow -eq 'nightly'){$nightlyAccept}else{$hypervGuard+"`n"+$recover+"`n"+$accept}
        $failure=Invoke-NightlyAuthorizationFixture ($flow+'-failure') $body @{CONFIRM_SHARED_MUTATION='true'} 7
        Add-CheckResult -Name "$flow realer Fehler bleibt Fehler ohne Folgeaufruf oder Diagnoseleak" -Success ($failure.Exit -ne 0 -and @($failure.Trace -split "`n" | Where-Object {$_}).Count -eq 1 -and $failure.Public -notmatch 'PRIVATE_SYNTHETIC_DIAGNOSTIC')
    }
    $report=Get-NightlyFixtureBlock $nightlySource 'Open, update or close tracking issue'
    foreach($case in @(
        @{Name='excluded'; Shared='skipped'; Auth='false'; Class='NOT_AUTHORIZED'; Static='success'; Gate='success'; Success=$true},
        @{Name='authorized'; Shared='success'; Auth='true'; Class='AUTHORIZED'; Static='success'; Gate='success'; Success=$true},
        @{Name='unauthorized-success'; Shared='success'; Auth='false'; Class='NOT_AUTHORIZED'; Static='success'; Gate='success'; Success=$false},
        @{Name='authorized-skip'; Shared='skipped'; Auth='true'; Class='AUTHORIZED'; Static='success'; Gate='success'; Success=$false},
        @{Name='missing-auth'; Shared='skipped'; Auth=''; Class=''; Static='success'; Gate='success'; Success=$false},
        @{Name='gate-failure'; Shared='skipped'; Auth='false'; Class='NOT_AUTHORIZED'; Static='success'; Gate='failure'; Success=$false},
        @{Name='static-cancel'; Shared='skipped'; Auth='false'; Class='NOT_AUTHORIZED'; Static='cancelled'; Gate='success'; Success=$false},
        @{Name='shared-failure'; Shared='failure'; Auth='false'; Class='NOT_AUTHORIZED'; Static='success'; Gate='success'; Success=$false}
    )) {
        $body=$report.Replace('${{ needs.test-environments.result }}',$case.Shared).Replace('${{ needs.change-gate.outputs.shared_authorized }}',$case.Auth).Replace('${{ needs.change-gate.outputs.shared_classification }}',$case.Class).Replace('${{ needs.full-static-contracts.result }}',$case.Static).Replace('${{ needs.change-gate.result }}',$case.Gate)
        $body=[regex]::Replace($body,'\$\{\{ needs\.[\w-]+\.result \}\}','success')
        $body=[regex]::Replace($body,'\$\{\{ needs\.[\w-]+\.outputs\.validation_classification \}\}','VALIDATED')
        $result=Invoke-NightlyAuthorizationFixture ('report-'+$case.Name) $body
        Add-CheckResult -Name "Echter Nightlyreport $($case.Name) erhaelt Pflichtfehler" -Success (($result.Exit -eq 0) -eq $case.Success)
        if($case.Name -eq 'excluded') { Add-CheckResult -Name 'Erwarteter Ausschluss berichtet NOT_EXECUTED und NOT_AUTHORIZED' -Success ($result.Public -match 'NOT_EXECUTED: NOT_AUTHORIZED') }
        if($case.Name -eq 'static-cancel') { Add-CheckResult -Name 'Abbruch bleibt UNKNOWN, Sharedausschluss wird nicht VALIDATED' -Success ($result.Issue -match 'static: \*\*cancelled\*\* \(UNKNOWN\)' -and $result.Issue -match 'test_environments: \*\*NOT_EXECUTED\*\* \(NOT_AUTHORIZED\)') }
    }
    Add-CheckResult -Name 'Shared Nightlyjob braucht positiven Autorisierungsoutput' -Success ($nightlySource -match "(?s)test-environments:.*?if: needs.change-gate.outputs.should_run == 'true' && needs.change-gate.outputs.shared_authorized == 'true'")
    Add-CheckResult -Name 'Shared HyperV Guard steht vor Preflight und Recover; Default bleibt lifecycle' -Success ($hypervSource.IndexOf('- name: Authorize shared environment mutation') -lt $hypervSource.IndexOf('- name: Hyper-V preflight') -and $hypervSource -match '(?s)workflow_call:.*?default: lifecycle')
    foreach($source in @($nightlySource,$hypervSource)) {
        Add-CheckResult -Name 'Separate Sharedbestaetigung ist im manuellen Workflow defaultfalse' -Success ($source -match '(?s)workflow_dispatch:.*?confirm_shared_mutation:.*?type: boolean\s+default: false')
    }
}
finally {
    $resolved=[IO.Path]::GetFullPath($fixtureRoot)
    $tempPrefix=[IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath([IO.Path]::GetTempPath()))+[IO.Path]::DirectorySeparatorChar
    if(-not $resolved.StartsWith($tempPrefix,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notmatch '^sql-lab-nightly-auth-[a-f0-9]{32}$') { throw 'SYNTHETIC_CLEANUP_BOUNDARY' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
