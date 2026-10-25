# Test-only supervisor for the two filesystem-heavy HTTP fixtures.
. (Join-Path $PSScriptRoot 'TestTemporaryDirectory.ps1')

function Write-WorkflowUiFixtureRecoveryReceipt {
    param([Parameter(Mandatory)][string]$Directory,[Parameter(Mandatory)]$Record)
    try {
        $null=New-Item -ItemType Directory -Path $Directory -Force -ErrorAction Stop
        $path=Join-Path $Directory ([guid]::NewGuid().ToString('N')+'.private.json')
        $Record|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $path -Encoding utf8 -ErrorAction Stop
        [pscustomobject]@{Status='WRITTEN';Path=$path;FailureType='NONE'}
    } catch {
        [pscustomobject]@{Status='WRITE_FAILED';Path=$null;FailureType=$_.Exception.GetType().FullName}
    }
}

function Invoke-WorkflowUiTemporaryFixture {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FixturePath,
        [Parameter(Mandatory)][ValidateRange(1,240000)][int]$TimeoutMilliseconds,
        [string]$ParentPath = [IO.Path]::GetTempPath()
    )
    $owned = $null
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = (Get-Process -Id $PID).Path
    $start.UseShellExecute = $false; $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
    foreach($argument in @('-NoProfile','-NonInteractive','-OutputFormat','Text','-File',[IO.Path]::GetFullPath($FixturePath))) {
        $start.ArgumentList.Add($argument)
    }
    $process = [Diagnostics.Process]::new(); $process.StartInfo = $start
    $started = $false; $terminated = $false; $complete = $false; $drained = $false
    $cleanup = 'PENDING'; $failure = 'NONE'; $cleanupReason = 'NONE'; $exitCode = -1
    $outputText = ''; $errorText = ''
    $processId = $null; $processStartedUtc = $null
    try {
        $owned = New-TestTemporaryDirectory -ParentPath $ParentPath
        foreach($name in @('TEMP','TMP','TMPDIR')) { $start.Environment[$name] = $owned.Path }
        $started = $process.Start()
        if(-not $started) { throw 'FIXTURE_START_FAILED' }
        $processId = $process.Id; $processStartedUtc = $process.StartTime.ToUniversalTime().ToString('o')
        $output = $process.StandardOutput.ReadToEndAsync(); $errors = $process.StandardError.ReadToEndAsync()
        $complete = $process.WaitForExit($TimeoutMilliseconds)
        if(-not $complete) { $failure = 'TIMEOUT'; $process.Kill($true) }
        $terminated = $process.WaitForExit(5000)
        if($terminated) {
            $exitCode = $process.ExitCode
            $drained = ([Threading.Tasks.Task]::WhenAll([Threading.Tasks.Task[]]@($output,$errors))).Wait(5000)
            if($drained) {
                $outputText = $output.GetAwaiter().GetResult(); $errorText = $errors.GetAwaiter().GetResult()
                if($complete -and $exitCode -ne 0) { $failure = 'NONZERO_EXIT' }
            } elseif($failure -ceq 'NONE') { $failure = 'OUTPUT_DRAIN_UNCONFIRMED' }
        } elseif($failure -ceq 'NONE') { $failure = 'TERMINATION_UNCONFIRMED' }
    } catch {
        if($failure -ceq 'NONE') { $failure = 'PROCESS_FAILED' }
    } finally {
        if($started -and -not $process.HasExited) {
            try { $process.Kill($true); $terminated = $process.WaitForExit(5000) } catch { $terminated = $false }
        }
        $process.Dispose()
        # Never remove files while a process or inherited output pipe remains unconfirmed.
        if($null -eq $owned) { $cleanup = 'RECOVERY_REQUIRED'; $cleanupReason = 'TEST_DIRECTORY_ALLOCATION_FAILED' }
        elseif(-not $started -or ($terminated -and $drained)) {
            try { Remove-TestTemporaryDirectory $owned; $cleanup = 'CLEAN' } catch {
                $cleanup = 'RECOVERY_REQUIRED'; $cleanupReason = 'TEST_DIRECTORY_CLEANUP_FAILED'
            }
        } else { $cleanup = 'RECOVERY_REQUIRED'; $cleanupReason = 'FIXTURE_TERMINATION_UNCONFIRMED' }
    }
    [pscustomobject]@{
        Completed=$complete; ExitCode=$exitCode; PrimaryFailure=$failure
        Output=$outputText; Error=$errorText; Cleanup=$cleanup; CleanupReason=$cleanupReason
        OwnedDirectory=$owned
        Process=[pscustomobject]@{Started=$started;Id=$processId;StartTimeUtc=$processStartedUtc;TerminationConfirmed=$terminated;OutputClosed=$drained}
    }
}
