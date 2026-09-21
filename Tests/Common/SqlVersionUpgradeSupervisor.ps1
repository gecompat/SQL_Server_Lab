# Private test infrastructure: no runtime access until the supplied native child starts.
function Assert-SqlUpgradeChildBinding {
    param($Record,[string]$Provider,[string]$OperationId,[string]$StateRoot,[string]$EvidenceRoot)
    if ($OperationId -cnotmatch '^[a-f0-9]{32}$' -or $OperationId -ceq ('0'*32) -or
        $Record.OperationId -cne $OperationId -or $Record.Provider -cne $Provider -or
        $Record.SourceOperationId -cne ($OperationId+'-source') -or
        $Record.TargetOperationId -cne ($OperationId+'-target') -or
        $Record.StateRoot -cne $StateRoot -or
        [IO.Path]::GetFullPath($StateRoot) -cne [IO.Path]::GetFullPath((Join-Path $EvidenceRoot 'state'))) {
        throw 'SQL_UPGRADE_CHILD_BINDING_INVALID'
    }
}

function New-SqlUpgradeSupervisorRoot {
    param([switch]$Synthetic)
    $root=Join-Path ([IO.Path]::GetTempPath()) ('sql-server-lab-upgrade-'+[guid]::NewGuid().ToString('N'))
    $item=New-Item -ItemType Directory -Path $root -ErrorAction Stop
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'SQL_UPGRADE_SUPERVISOR_ROOT_INVALID' }
    if (-not $Synthetic -and $IsWindows) {
        $identity=[Security.Principal.WindowsIdentity]::GetCurrent().User
        $acl=Get-Acl -LiteralPath $root
        $acl.SetAccessRuleProtection($true,$false)
        $acl.SetOwner($identity)
        $acl.SetAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
            $identity,'FullControl','ContainerInherit,ObjectInherit','None','Allow'))
        Set-Acl -LiteralPath $root -AclObject $acl
    }
    if (-not $IsWindows) {
        $chmod=@(Get-Command chmod -CommandType Application -ErrorAction Stop)[0].Source
        & $chmod 700 $root 1>$null 2>$null
        if ($LASTEXITCODE -ne 0) { throw 'SQL_UPGRADE_SUPERVISOR_ROOT_PERMISSIONS_FAILED' }
    }
    return $root
}

function Stop-SqlUpgradeChild {
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

function Wait-SqlUpgradeOutputDrain {
    param([Threading.Tasks.Task[]]$Task, [ValidateRange(1,5000)][int]$TimeoutMilliseconds=5000)
    $complete=$true
    foreach ($drain in $Task) {
        if (-not $drain) { continue }
        try { if (-not $drain.Wait($TimeoutMilliseconds)) { $complete=$false } }
        catch { $complete=$false }
    }
    return $complete
}

function Invoke-SqlUpgradeSupervisedChild {
    param(
        [Parameter(Mandatory)][string]$AcceptanceRunner,
        [Parameter(Mandatory)][string]$Provider,
        [Parameter(Mandatory)][string]$StateRoot,
        [Parameter(Mandatory)][string]$OperationId,
        [Parameter(Mandatory)][string]$EvidenceRoot,
        [ValidateSet('ACCEPTANCE','CLEANUP')][string]$Stage='ACCEPTANCE',
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
        $confirmed=if ($timedOut -or $cancelled) { Stop-SqlUpgradeChild -Process $child } else { $true }
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
        if ($child -and -not $confirmed) { $confirmed=Stop-SqlUpgradeChild -Process $child }
        $Control.TerminationConfirmed=$confirmed
        if ($confirmed) {
            # The writer has ended before streams or handles are released.
            if (-not (Wait-SqlUpgradeOutputDrain -Task @($outTask,$errTask))) {
                $status='FAILED'; $reason='OUTPUT_FAILED'
            }
            if ($stdout) { $stdout.Dispose() }; if ($stderr) { $stderr.Dispose() }
        }
        if ($child) { $child.Dispose() }
    }
    [pscustomobject]@{Status=$status;ReasonCode=$reason;TerminationConfirmed=$confirmed;TimedOut=$timedOut}
}

function Invoke-SqlUpgradeSupervisor {
    param(
        [string]$AcceptanceRunner, [string]$Provider, [string]$StateRoot,
        [ValidateScript({ $_ -cmatch '^[0-9a-f]{32}$' -and $_ -ne ('0'*32) })]
        [string]$OperationId,
        [string]$EvidenceRoot,
        [ValidateRange(1,1800)][int]$TimeoutSeconds=900,
        [ValidateRange(1,600)][int]$CleanupTimeoutSeconds=600,
        [Threading.CancellationToken]$CancellationToken=[Threading.CancellationToken]::None
    )
    $arguments=@{
        AcceptanceRunner=$AcceptanceRunner; Provider=$Provider; StateRoot=$StateRoot
        OperationId=$OperationId; EvidenceRoot=$EvidenceRoot
    }
    # Retained outside the repository, including when Arrange never returns its RunId.
    [IO.File]::WriteAllText((Join-Path $EvidenceRoot 'operation.json'),(@{
        OperationId=$OperationId; StateRoot=$StateRoot; Provider=$Provider
        SourceOperationId=($OperationId+'-source'); TargetOperationId=($OperationId+'-target')
    } | ConvertTo-Json -Compress))
    $control=@{TerminationConfirmed=$true}
    $result=[pscustomobject]@{Status='FAILED';ReasonCode='SUPERVISOR_FAILED';TerminationConfirmed=$false}
    $cleanup=[pscustomobject]@{Status='NOT_EXECUTED';ReasonCode='TERMINATION_UNCONFIRMED';TerminationConfirmed=$false}
    try {
        $result=Invoke-SqlUpgradeSupervisedChild @arguments -TimeoutSeconds $TimeoutSeconds -Control $control -CancellationToken $CancellationToken
    }
    finally {
        # Also entered after pipeline cancellation. A failed termination never authorizes cleanup.
        if ($control.TerminationConfirmed) {
            $cleanup=Invoke-SqlUpgradeSupervisedChild @arguments -Stage CLEANUP -TimeoutSeconds $CleanupTimeoutSeconds
        }
    }
    $status=if ($result.Status -ceq 'COMPLETED' -and $cleanup.Status -ceq 'COMPLETED') { 'COMPLETED' } else { 'FAILED' }
    [pscustomobject]@{
        Status=$status; PrimaryReason=$result.ReasonCode; CleanupStatus=$cleanup.Status; CleanupReason=$cleanup.ReasonCode
        TerminationConfirmed=($result.TerminationConfirmed -and $cleanup.TerminationConfirmed)
    }
}
