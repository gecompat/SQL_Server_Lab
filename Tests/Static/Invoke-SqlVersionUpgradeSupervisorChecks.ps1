#Requires -Version 7.2
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
. (Join-Path $repoRoot 'Tests/Common/SqlVersionUpgradeSupervisor.ps1')
$root=New-SqlUpgradeSupervisorRoot -Synthetic
$count=0
function Check([bool]$Condition,[string]$Name) {
    if (-not $Condition) { throw "SUPERVISOR_CHECK_FAILED: $Name" }
    $script:count++; Write-Host "PASS: $Name"
}
try {
    $operation=[guid]::NewGuid().ToString('N'); $state=Join-Path $root 'state'
    $record=@{OperationId=$operation;Provider='docker';StateRoot=$state;SourceOperationId=($operation+'-source');TargetOperationId=($operation+'-target')}
    Assert-SqlUpgradeChildBinding -Record $record -Provider docker -OperationId $operation -StateRoot $state -EvidenceRoot $root
    Check $true 'Actual child accepts its exact parent-selected operation, provider and isolated StateRoot'
    foreach ($field in @('OperationId','Provider','StateRoot','SourceOperationId','TargetOperationId')) {
        $changed=$record.Clone(); $changed[$field]='foreign'
        $caught=$null
        try { Assert-SqlUpgradeChildBinding -Record $changed -Provider docker -OperationId $operation -StateRoot $state -EvidenceRoot $root }
        catch { $caught=$_.Exception.Message }
        Check ($caught -ceq 'SQL_UPGRADE_CHILD_BINDING_INVALID') "Actual child rejects changed $field before any provider access"
    }
    $pending=[Threading.Tasks.TaskCompletionSource[bool]]::new()
    Check (-not (Wait-SqlUpgradeOutputDrain -Task @($pending.Task) -TimeoutMilliseconds 1)) 'Incomplete output draining fails closed'
    $pending.SetException([InvalidOperationException]::new('synthetic drain failure'))
    Check (-not (Wait-SqlUpgradeOutputDrain -Task @($pending.Task) -TimeoutMilliseconds 1)) 'Faulted output draining fails closed'
    Check (Wait-SqlUpgradeOutputDrain -Task @([Threading.Tasks.Task]::CompletedTask)) 'Completed output draining succeeds'
    $runner=Join-Path $root 'synthetic-native.ps1'
    @'
param($Provider,$StateRoot,$OperationId,$EvidenceRoot,[switch]$CleanupOnly)
$ErrorActionPreference='Stop'
$config=Get-Content (Join-Path $StateRoot 'config.json') -Raw | ConvertFrom-Json
if ($OperationId -cne $config.OperationId -or $env:SQL_SERVER_LAB_STATE -cne $StateRoot) { throw 'BINDING_MISMATCH' }
Write-Host 'RAW_HOST_SECRET_CANARY'
[Console]::Error.WriteLine('RAW_RUNTIME_CANARY')
if ($CleanupOnly) {
    $marker=Join-Path $StateRoot 'arrange.json'
    if (Test-Path $marker) {
        $arrange=Get-Content $marker -Raw | ConvertFrom-Json
        if (Get-Process -Id $arrange.ChildPid -ErrorAction SilentlyContinue) { throw 'CHILD_STILL_RUNNING' }
        if ($arrange.OperationId -cne $OperationId) { throw 'CLEANUP_OPERATION_MISMATCH' }
    }
    Set-Content (Join-Path $StateRoot 'cleanup.txt') 'OWN_CLEANUP_AFTER_CHILD_EXIT'
    if ($config.Mode -ceq 'cleanup-failed') { throw 'RAW_CLEANUP_ERROR_CANARY' }
    return
}

@{ChildPid=$PID;OperationId=$OperationId} | ConvertTo-Json | Set-Content (Join-Path $StateRoot 'arrange.json')
switch ($config.Mode) {
    failed { throw 'RAW_PRIMARY_ERROR_CANARY' }
    partial { [Environment]::Exit(7) }
    timeout { Start-Sleep -Seconds 60 }
    cancelled { Start-Sleep -Seconds 60 }
    cleanup-failed { throw 'RAW_PRIMARY_ERROR_CANARY' }
}
'@ | Set-Content -LiteralPath $runner
    foreach ($mode in @('success','failed','partial','timeout','cancelled','cleanup-failed')) {
        $state=Join-Path $root $mode; $null=New-Item -ItemType Directory $state
        $operation=[guid]::NewGuid().ToString('N')
        @{Mode=$mode;OperationId=$operation} | ConvertTo-Json | Set-Content (Join-Path $state 'config.json')
        $timeout=if ($mode -ceq 'timeout') { 3 } else { 20 }
        $cancellation=[Threading.CancellationTokenSource]::new()
        if ($mode -ceq 'cancelled') { $cancellation.CancelAfter(2500) }
        try {
            $output=@(Invoke-SqlUpgradeSupervisor -AcceptanceRunner $runner -Provider 'synthetic' `
                -StateRoot $state -OperationId $operation -EvidenceRoot $state -TimeoutSeconds $timeout `
                -CleanupTimeoutSeconds 20 -CancellationToken $cancellation.Token *>&1)
        }
        finally { $cancellation.Dispose() }
        Check ($output.Count -eq 1 -and ($output | Out-String) -notmatch 'RAW_|CANARY') "$mode emits only closed status"
        $result=$output[0]
        Check (Test-Path (Join-Path $state 'cleanup.txt')) "$mode performs independent own cleanup"
        Check $result.TerminationConfirmed "$mode confirms child completion before cleanup"
        Check ((Get-Content (Join-Path $state 'ACCEPTANCE.stdout.log') -Raw) -match 'RAW_HOST_SECRET_CANARY' -and
            (Get-Content (Join-Path $state 'ACCEPTANCE.stderr.log') -Raw) -match 'RAW_RUNTIME_CANARY') "$mode keeps raw output local"
        $expected=switch ($mode) { success {'NONE'} partial {'RECEIPT_INVALID'} timeout {'TIMEOUT'} cancelled {'CANCELLED'} default {'CHILD_FAILED'} }
        Check ($result.PrimaryReason -ceq $expected) "$mode preserves primary outcome"
        if ($mode -ceq 'success') { Check ($result.Status -ceq 'COMPLETED') 'Successful child and cleanup required for PASS' }
        else { Check ($result.Status -ceq 'FAILED') "$mode cannot become PASS after cleanup" }
        if ($mode -ceq 'cleanup-failed') { Check ($result.CleanupReason -ceq 'CHILD_FAILED') 'Cleanup failure stays separate from primary failure' }
    }
    $script:childCalls=0
    function Invoke-SqlUpgradeSupervisedChild {
        param($Control)
        $Control.TerminationConfirmed=$false
        $script:childCalls++
        [pscustomobject]@{Status='FAILED';ReasonCode='TERMINATION_UNCONFIRMED';TerminationConfirmed=$false}
    }
    $blocked=Invoke-SqlUpgradeSupervisor -AcceptanceRunner $runner -Provider 'synthetic' `
        -StateRoot $root -OperationId $operation -EvidenceRoot $root
    Check ($script:childCalls -eq 1 -and $blocked.CleanupStatus -ceq 'NOT_EXECUTED' -and -not $blocked.TerminationConfirmed) 'Unconfirmed child termination blocks cleanup'
    Write-Host "SQL_UPGRADE SUPERVISOR: $count PASS"
}
finally {
    $resolved=[IO.Path]::GetFullPath($root)
    $temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if (-not $resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($resolved) -notlike 'sql-server-lab-upgrade-*') { throw 'SYNTHETIC_ROOT_INVALID' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
