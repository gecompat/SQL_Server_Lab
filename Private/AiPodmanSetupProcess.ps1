function Stop-LabAiPodmanSetupChild {
    param([Parameter(Mandatory)][Diagnostics.Process]$Process)
    try {
        if ($Process.HasExited) { return $true }
        if ($IsWindows) {
            $start=[Diagnostics.ProcessStartInfo]::new()
            $start.FileName=Join-Path $env:SystemRoot 'System32/taskkill.exe'
            $start.UseShellExecute=$false; $start.CreateNoWindow=$true
            $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
            foreach ($argument in @('/PID',[string]$Process.Id,'/T','/F')) { $start.ArgumentList.Add($argument) }
            $killer=[Diagnostics.Process]::Start($start)
            try {
                $output=$killer.StandardOutput.ReadToEndAsync(); $errors=$killer.StandardError.ReadToEndAsync()
                if (-not $killer.WaitForExit(15000)) { $killer.Kill($true); return $false }
                $null=$output.GetAwaiter().GetResult(); $null=$errors.GetAwaiter().GetResult()
                if ($killer.ExitCode -ne 0) { return $false }
            }
            finally { $killer.Dispose() }
        }
        else { $Process.Kill($true) }
        return $Process.WaitForExit(15000)
    }
    catch { return $false }
}

function Wait-LabAiPodmanSetupOutputDrain {
    param([Threading.Tasks.Task[]]$Task, [ValidateRange(1,5000)][int]$TimeoutMilliseconds=5000)
    $complete=$true
    foreach ($drain in $Task) {
        if (-not $drain) { continue }
        try { if (-not $drain.Wait($TimeoutMilliseconds)) { $complete=$false } }
        catch { $complete=$false }
    }
    return $complete
}

function Invoke-LabAiPodmanSetupChild {
    param(
        [Parameter(Mandatory)][string]$AcceptanceRunner,
        [Parameter(Mandatory)][string]$Provider,
        [Parameter(Mandatory)][string]$StateRoot,
        [Parameter(Mandatory)][string]$OperationId,
        [Parameter(Mandatory)][string]$EvidenceRoot,
        [ValidateSet('ACCEPTANCE','COLLECTION_CLEANUP','CLEANUP')][string]$Stage='ACCEPTANCE',
        [ValidateRange(1,1800)][int]$TimeoutSeconds=900,
        [hashtable]$Control=@{TerminationConfirmed=$true},
        [Threading.CancellationToken]$CancellationToken=[Threading.CancellationToken]::None
    )
    $childPath=Join-Path $EvidenceRoot ($Stage+'.ps1')
    $receiptPath=Join-Path $EvidenceRoot ($Stage+'.json')
    $childContent=@'
param($AcceptanceRunner,$Provider,$StateRoot,$OperationId,$ReceiptPath,$Stage)
$ErrorActionPreference='Stop'
$receipt=[ordered]@{OperationId=$OperationId;Status='FAILED'}
$code=1
try {
    $arguments=@{Provider=$Provider;StateRoot=$StateRoot;OperationId=$OperationId}
    if ($Stage -ceq 'CLEANUP') { $arguments.CleanupOnly=$true }
    if ($Stage -ceq 'COLLECTION_CLEANUP') { $arguments.CollectionCleanupOnly=$true }
    $arguments.EvidenceRoot=[IO.Path]::GetDirectoryName($ReceiptPath)
    $global:LASTEXITCODE=0
    & $AcceptanceRunner @arguments
    if ($LASTEXITCODE -ne 0) { throw 'CHILD_EXIT_FAILED' }
    $receipt.Status='COMPLETED'; $code=0
}
catch { $_ | Out-String | Write-Host }
finally { [IO.File]::WriteAllText($ReceiptPath,($receipt|ConvertTo-Json -Compress)) }
exit $code
'@
    [IO.File]::WriteAllText($childPath,$childContent)
    $start=[Diagnostics.ProcessStartInfo]::new()
    $start.FileName=(Get-Process -Id $PID).Path
    $start.UseShellExecute=$false; $start.CreateNoWindow=$true
    $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
    $start.Environment['SQL_SERVER_LAB_STATE']=$StateRoot
    foreach ($argument in @('-NoLogo','-NoProfile','-NonInteractive','-File',$childPath,
        '-AcceptanceRunner',$AcceptanceRunner,'-Provider',$Provider,'-StateRoot',$StateRoot,
        '-OperationId',$OperationId,'-ReceiptPath',$receiptPath,'-Stage',$Stage)) {
        $start.ArgumentList.Add($argument)
    }
    $child=$null; $stdout=$null; $stderr=$null; $outTask=$null; $errTask=$null
    $confirmed=$true; $timedOut=$false; $cancelled=$false
    $reason='CHILD_START_FAILED'; $status='FAILED'
    try {
        $stdout=[IO.File]::Create((Join-Path $EvidenceRoot ($Stage+'.stdout.log')))
        $stderr=[IO.File]::Create((Join-Path $EvidenceRoot ($Stage+'.stderr.log')))
        $child=[Diagnostics.Process]::Start($start)
        $confirmed=$false
        $Control.TerminationConfirmed=$false
        $outTask=$child.StandardOutput.BaseStream.CopyToAsync($stdout)
        $errTask=$child.StandardError.BaseStream.CopyToAsync($stderr)
        $deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
        while (-not $child.WaitForExit(200)) {
            if ($CancellationToken.IsCancellationRequested) { $cancelled=$true; break }
            if ([DateTime]::UtcNow -ge $deadline) { $timedOut=$true; break }
        }
        $confirmed=if ($timedOut -or $cancelled) { Stop-LabAiPodmanSetupChild -Process $child } else { $true }
        if (-not $confirmed) { $reason='TERMINATION_UNCONFIRMED' }
        elseif ($cancelled) { $reason='CANCELLED' }
        elseif ($timedOut) { $reason='TIMEOUT' }
        else {
            $reason='RECEIPT_INVALID'
            if (Test-Path -LiteralPath $receiptPath -PathType Leaf) {
                $item=Get-Item -LiteralPath $receiptPath
                if ($item.Length -le 1024 -and -not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                    $receipt=Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json -Depth 3
                    $properties=@($receipt.PSObject.Properties.Name)
                    if ($properties.Count -eq 2 -and
                        @($properties | Where-Object { $_ -cnotin @('OperationId','Status') }).Count -eq 0 -and
                        $receipt.OperationId -ceq $OperationId -and $receipt.Status -cin @('COMPLETED','FAILED')) {
                        $reason='CHILD_FAILED'
                        if ($receipt.Status -ceq 'COMPLETED' -and $child.ExitCode -eq 0) {
                            $status='COMPLETED'; $reason='NONE'
                        }
                    }
                }
            }
        }
    }
    catch { $reason='SUPERVISOR_FAILED' }
    finally {
        if ($child -and -not $confirmed) { $confirmed=Stop-LabAiPodmanSetupChild -Process $child }
        $Control.TerminationConfirmed=$confirmed
        if ($confirmed) {
            # The writer has ended before streams or handles are released.
            if (-not (Wait-LabAiPodmanSetupOutputDrain -Task @($outTask,$errTask))) {
                $status='FAILED'; $reason='OUTPUT_FAILED'
            }
            if ($stdout) { $stdout.Dispose() }; if ($stderr) { $stderr.Dispose() }
        }
        if ($child) { $child.Dispose() }
    }
    [pscustomobject]@{Status=$status;ReasonCode=$reason;TerminationConfirmed=$confirmed;TimedOut=$timedOut}
}
