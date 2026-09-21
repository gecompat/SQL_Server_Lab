# Private test infrastructure: no runtime access until the supplied native child starts.
function New-HyperVPreparedLocaleSupervisorRoot {
    param([switch]$Synthetic)
    $root=Join-Path ([IO.Path]::GetTempPath()) ('sql-server-lab-prepared-locale-ci-'+[guid]::NewGuid().ToString('N'))
    $item=New-Item -ItemType Directory -Path $root -ErrorAction Stop
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'PREPARED_LOCALE_SUPERVISOR_ROOT_INVALID' }
    if (-not $Synthetic) {
        $identity=[Security.Principal.WindowsIdentity]::GetCurrent().User
        $acl=Get-Acl -LiteralPath $root
        $acl.SetAccessRuleProtection($true,$false)
        $acl.SetOwner($identity)
        $acl.SetAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
            $identity,'FullControl','ContainerInherit,ObjectInherit','None','Allow'))
        Set-Acl -LiteralPath $root -AclObject $acl
    }
    return $root
}

function Stop-HyperVPreparedLocaleChild {
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

function Wait-HyperVPreparedLocaleOutputDrain {
    param([Threading.Tasks.Task[]]$Task, [ValidateRange(1,5000)][int]$TimeoutMilliseconds=5000)
    $complete=$true
    foreach ($drain in $Task) {
        if (-not $drain) { continue }
        try { if (-not $drain.Wait($TimeoutMilliseconds)) { $complete=$false } }
        catch { $complete=$false }
    }
    return $complete
}

function Invoke-HyperVPreparedLocaleSupervisedChild {
    param(
        [Parameter(Mandatory)][string]$AcceptanceRunner,
        [Parameter(Mandatory)][string]$ArtifactId,
        [Parameter(Mandatory)][string]$StateRoot,
        [Parameter(Mandatory)][string]$OperationId,
        [Parameter(Mandatory)][string]$EvidenceRoot,
        [ValidateSet('ACCEPTANCE','CLEANUP')][string]$Stage='ACCEPTANCE',
        [ValidateRange(1,7200)][int]$TimeoutSeconds=5400
    )
    $childPath=Join-Path $EvidenceRoot ($Stage+'.ps1')
    $receiptPath=Join-Path $EvidenceRoot ($Stage+'.json')
    $childContent=@'
param($AcceptanceRunner,$ArtifactId,$StateRoot,$OperationId,$ReceiptPath,$Stage)
$ErrorActionPreference='Stop'
$receipt=[ordered]@{OperationId=$OperationId;Status='FAILED'}
$code=1
try {
    $arguments=@{ArtifactId=$ArtifactId;StateRoot=$StateRoot;OperationId=$OperationId}
    if ($Stage -ceq 'CLEANUP') { $arguments.CleanupOnly=$true }
    else { $arguments.DeferCleanup=$true }
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
        '-AcceptanceRunner',$AcceptanceRunner,'-ArtifactId',$ArtifactId,'-StateRoot',$StateRoot,
        '-OperationId',$OperationId,'-ReceiptPath',$receiptPath,'-Stage',$Stage)) {
        $start.ArgumentList.Add($argument)
    }
    $child=$null; $stdout=$null; $stderr=$null; $outTask=$null; $errTask=$null
    $confirmed=$true; $timedOut=$false
    $reason='CHILD_START_FAILED'; $status='FAILED'
    try {
        $stdout=[IO.File]::Create((Join-Path $EvidenceRoot ($Stage+'.stdout.log')))
        $stderr=[IO.File]::Create((Join-Path $EvidenceRoot ($Stage+'.stderr.log')))
        $child=[Diagnostics.Process]::Start($start)
        $confirmed=$false
        $outTask=$child.StandardOutput.BaseStream.CopyToAsync($stdout)
        $errTask=$child.StandardError.BaseStream.CopyToAsync($stderr)
        $deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
        while (-not $child.WaitForExit(200)) {
            if ([DateTime]::UtcNow -ge $deadline) { $timedOut=$true; break }
        }
        $confirmed=if ($timedOut) { Stop-HyperVPreparedLocaleChild -Process $child } else { $true }
        if (-not $confirmed) { $reason='TERMINATION_UNCONFIRMED' }
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
        if ($child -and -not $confirmed) { $confirmed=Stop-HyperVPreparedLocaleChild -Process $child }
        if ($confirmed) {
            # The writer has ended before streams or handles are released.
            if (-not (Wait-HyperVPreparedLocaleOutputDrain -Task @($outTask,$errTask))) {
                $status='FAILED'; $reason='OUTPUT_FAILED'
            }
            if ($stdout) { $stdout.Dispose() }; if ($stderr) { $stderr.Dispose() }
        }
        if ($child) { $child.Dispose() }
    }
    [pscustomobject]@{Status=$status;ReasonCode=$reason;TerminationConfirmed=$confirmed;TimedOut=$timedOut}
}

function Invoke-HyperVPreparedLocaleSupervisor {
    param(
        [string]$AcceptanceRunner, [string]$ArtifactId, [string]$StateRoot,
        [ValidateScript({ $_ -cmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' -and [guid]$_ -ne [guid]::Empty })]
        [string]$OperationId,
        [string]$EvidenceRoot,
        [ValidateRange(1,7200)][int]$TimeoutSeconds=5400,
        [ValidateRange(1,1800)][int]$CleanupTimeoutSeconds=900
    )
    $arguments=@{
        AcceptanceRunner=$AcceptanceRunner; ArtifactId=$ArtifactId; StateRoot=$StateRoot
        OperationId=$OperationId; EvidenceRoot=$EvidenceRoot
    }
    # Retained outside the repository, including when Arrange never returns its RunId.
    [IO.File]::WriteAllText((Join-Path $EvidenceRoot 'operation.json'),(@{
        OperationId=$OperationId; StateRoot=$StateRoot; ArtifactId=$ArtifactId
    } | ConvertTo-Json -Compress))
    $result=Invoke-HyperVPreparedLocaleSupervisedChild @arguments -TimeoutSeconds $TimeoutSeconds
    $cleanup=[pscustomobject]@{Status='NOT_EXECUTED';ReasonCode='TERMINATION_UNCONFIRMED';TerminationConfirmed=$false}
    if ($result.TerminationConfirmed) {
        $cleanup=Invoke-HyperVPreparedLocaleSupervisedChild @arguments -Stage CLEANUP -TimeoutSeconds $CleanupTimeoutSeconds
    }
    $status=if ($result.Status -ceq 'COMPLETED' -and $cleanup.Status -ceq 'COMPLETED') { 'COMPLETED' } else { 'FAILED' }
    [pscustomobject]@{
        Status=$status; PrimaryReason=$result.ReasonCode; CleanupStatus=$cleanup.Status; CleanupReason=$cleanup.ReasonCode
        TerminationConfirmed=($result.TerminationConfirmed -and $cleanup.TerminationConfirmed)
    }
}
