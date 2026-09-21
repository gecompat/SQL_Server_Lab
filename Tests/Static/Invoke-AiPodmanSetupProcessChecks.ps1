#Requires -Version 7.2
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
. (Join-Path $repoRoot 'Private/AiPodmanSetupProcess.ps1')
$root=Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-ai-process-checks-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory $root
$count=0
function Check([bool]$Condition,[string]$Name) {
    if (-not $Condition) { throw "SUPERVISOR_CHECK_FAILED: $Name" }
    $script:count++; Write-Host "PASS: $Name"
}
try {
    $pending=[Threading.Tasks.TaskCompletionSource[bool]]::new()
    Check (-not (Wait-LabAiPodmanSetupOutputDrain -Task @($pending.Task) -TimeoutMilliseconds 1)) 'Incomplete output draining fails closed'
    $pending.SetException([InvalidOperationException]::new('synthetic drain failure'))
    Check (-not (Wait-LabAiPodmanSetupOutputDrain -Task @($pending.Task) -TimeoutMilliseconds 1)) 'Faulted output draining fails closed'
    Check (Wait-LabAiPodmanSetupOutputDrain -Task @([Threading.Tasks.Task]::CompletedTask)) 'Completed output draining succeeds'
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
        $state=Join-Path $root $mode;$null=New-Item -ItemType Directory $state
        $operation=[guid]::NewGuid().ToString('N')
        @{Mode=$mode;OperationId=$operation}|ConvertTo-Json|Set-Content (Join-Path $state 'config.json')
        $timeout=if($mode -ceq 'timeout'){3}else{20}
        $cancel=[Threading.CancellationTokenSource]::new()
        if($mode -ceq 'cancelled'){$cancel.CancelAfter(2500)}
        $control=@{TerminationConfirmed=$true}
        try {
            $output=@(Invoke-LabAiPodmanSetupChild -AcceptanceRunner $runner -Provider synthetic -StateRoot $state -OperationId $operation -EvidenceRoot $state -TimeoutSeconds $timeout -Control $control -CancellationToken $cancel.Token *>&1)
        }finally{$cancel.Dispose()}
        Check ($output.Count -eq 1 -and ($output|Out-String) -notmatch 'RAW_|CANARY') "$mode only returns closed outcome"
        Check $control.TerminationConfirmed "$mode confirms child termination"
        $expected=switch($mode){success{'NONE'}partial{'RECEIPT_INVALID'}timeout{'TIMEOUT'}cancelled{'CANCELLED'}default{'CHILD_FAILED'}}
        Check ($output[0].ReasonCode -ceq $expected) "$mode preserves failure reason"
        $cleanup=Invoke-LabAiPodmanSetupChild -AcceptanceRunner $runner -Provider synthetic -StateRoot $state -OperationId $operation -EvidenceRoot $state -Stage CLEANUP -TimeoutSeconds 20
        Check (Test-Path (Join-Path $state 'cleanup.txt')) "$mode cleanup observes terminated writer"
        Check ((Get-Content (Join-Path $state 'ACCEPTANCE.stdout.log') -Raw) -match 'RAW_HOST_SECRET_CANARY' -and
            (Get-Content (Join-Path $state 'ACCEPTANCE.stderr.log') -Raw) -match 'RAW_RUNTIME_CANARY') "$mode retains streams locally"
        if($mode -ceq 'cleanup-failed'){Check ($cleanup.Status -ceq 'FAILED') 'Cleanup failure cannot become successful receipt'}
    }
    Write-Host "AI PODMAN PROCESS: $count PASS"
}
finally {
    $resolved=[IO.Path]::GetFullPath($root)
    $temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if (-not $resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($resolved) -notlike 'sql-lab-ai-process-checks-*') { throw 'SYNTHETIC_ROOT_INVALID' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
