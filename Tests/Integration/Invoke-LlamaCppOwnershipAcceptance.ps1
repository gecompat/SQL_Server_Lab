#Requires -Version 7.2
[CmdletBinding()]param([ValidateSet('OwnerClosed','LeaseExpired','WorkerKilled','OutputLimit','CleanupRetry','GuidedStop')][string[]]$Case=@('OwnerClosed','LeaseExpired','WorkerKilled','OutputLimit','CleanupRetry'))
$ErrorActionPreference='Stop'
if(-not $IsWindows){throw 'LLAMA_WINDOWS_REQUIRED'}
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$root=Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-llama-ownership-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $root
$workers=[Collections.Generic.List[Diagnostics.Process]]::new()
$preserveRoot=$false
try {
    foreach($mode in $Case) {
        $scope=Join-Path $root $mode;$null=New-Item -ItemType Directory -Path $scope
        if($mode -eq 'CleanupRetry') {
            $module=Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru
            $psi=[Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
            $psi.UseShellExecute=$false;$psi.CreateNoWindow=$true
            foreach($arg in @('-NoProfile','-NonInteractive','-Command','exit 0')){$psi.ArgumentList.Add($arg)}
            $finished=[Diagnostics.Process]::Start($psi);$null=$finished.WaitForExit(5000)
            $id=[guid]::NewGuid().ToString('D');$keyPath=Join-Path $scope 'api-key.txt';[IO.File]::WriteAllText($keyPath,'synthetic-fixture-only')
            & $module {param($Id,$Process,$Root)$script:LlamaCppOwnedSessions=@{};$script:LlamaCppOwnedSessions[$Id]=@{Worker=$Process;OperationRoot=$Root;ReceiptPath=(Join-Path $Root 'absent.json');Port=19435}} $id $finished $scope
            $lock=[IO.File]::Open($keyPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
            $failed=$false
            try {try {Stop-SqlServerLabLlamaCppRuntime $id|Out-Null}catch{$failed=$true}}finally{$lock.Dispose()}
            if(-not $failed){throw 'CLEANUP_FAILURE_NOT_OBSERVED'}
            $cleanup=Stop-SqlServerLabLlamaCppRuntime $id
            if($cleanup.Status -ne 'CLEANUP_SUCCEEDED' -or (Test-Path $keyPath)){throw 'CLEANUP_RETRY_FAILED'}
            Remove-Module $module -Force
            Write-Host 'PASS: cleanup can retry after temporary key-file lock'
            continue
        }
        $requestPath=Join-Path $scope 'request.json';$receiptPath=Join-Path $scope 'receipt.json'
        $request=@{OperationId=[guid]::NewGuid().ToString('D');Invocation=(Get-Process -Id $PID).Path;Arguments=@('-NoProfile','-NonInteractive','-Command',$(if($mode -eq 'OutputLimit'){'[Console]::Out.Write([string]::new([char]120,5MB));Start-Sleep -Seconds 60'}else{'Start-Sleep -Seconds 60'}));Environment=@{};LeaseSeconds=if($mode -eq 'LeaseExpired'){2}else{30};StartTimeoutSeconds=0}
        [IO.File]::WriteAllText($requestPath,($request|ConvertTo-Json -Depth 5))
        [IO.File]::WriteAllText((Join-Path $scope 'api-key.txt'),'synthetic-fixture-only')
        $psi=[Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
        $psi.UseShellExecute=$false;$psi.CreateNoWindow=$true;$psi.RedirectStandardInput=$true
        $psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
        foreach($arg in @('-NoProfile','-NonInteractive','-File',(Join-Path $repoRoot 'Tools/Invoke-LlamaCppOwnedWorker.ps1'),'-RequestPath',$requestPath)){$psi.ArgumentList.Add($arg)}
        $worker=[Diagnostics.Process]::Start($psi);$workers.Add($worker)
        $out=$worker.StandardOutput.ReadToEndAsync();$err=$worker.StandardError.ReadToEndAsync()
        $watch=[Diagnostics.Stopwatch]::StartNew();$receipt=$null
        do {
            if(Test-Path $receiptPath){$receipt=Get-Content $receiptPath -Raw|ConvertFrom-Json}
            if($receipt.Status -eq 'RUNNING'){break}
            if($worker.HasExited -or $watch.Elapsed.TotalSeconds -gt 15){throw 'WORKER_NOT_RUNNING'}
            Start-Sleep -Milliseconds 50
        }while($true)
        $child=Get-Process -Id $receipt.ProcessId -ErrorAction Stop
        if($mode -eq 'GuidedStop') {
            $preserveRoot=$true # Only confirmed worker/child/key/neighbor cleanup permits deletion.
            $module=Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru
            $neighborStart=[Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
            $neighborStart.UseShellExecute=$false;$neighborStart.CreateNoWindow=$true
            foreach($arg in @('-NoProfile','-NonInteractive','-Command','Start-Sleep -Seconds 60')){$neighborStart.ArgumentList.Add($arg)}
            $neighbor=[Diagnostics.Process]::Start($neighborStart);$workers.Add($neighbor)
            $workerWatch=Get-Process -Id $worker.Id -ErrorAction Stop
            if($workerWatch.StartTime.ToUniversalTime().Ticks -ne $worker.StartTime.ToUniversalTime().Ticks){throw 'GUIDED_WORKER_WATCH_IDENTITY_FAILED'}
            $guidedEvidence=[pscustomobject]@{Stopped=$false}
            $guidedFailure=$null;$guidedCleanupFailure=$null;$workerGone=$false;$childGone=$false;$neighborGone=$false
            try {
                & $module {
                    param($Id,$Worker,$Scope,$ReceiptPath,$Evidence)
                    $script:guidedRoot=$Scope
                    function Get-LabDataRootDefault {$script:guidedRoot}
                    function Get-LabStateRoot {$script:guidedRoot}
                    function Get-LabTestEnvironmentExportDirectory {param($OutputDirectory)$script:guidedRoot}
                    # Real worker and cleanup; isolated synthetic registry, no SQL/model evidence.
                    $script:LlamaCppOwnedSessions=@{}
                    $script:LlamaCppOwnedSessions[$Id]=@{Worker=$Worker;OperationRoot=$Scope;ReceiptPath=$ReceiptPath;Port=19435}
                    $plan=(Invoke-SqlServerLabWorkflowAction -Action PlanLlamaSessionStop -LlamaSessionOperationId $Id).Result
                    $cancel=Invoke-LabLlamaCppSessionStopPlan -PlanId $plan.PlanId
                    if($cancel.Status -cne 'CANCELLED' -or $Worker.HasExited){throw 'GUIDED_CANCEL_FAILED'}
                    $expired=New-LabLlamaCppSessionStopPlan $Id
                    $script:LlamaCppStopPlans[$expired.PlanId].Expires=[datetime]::UtcNow.AddSeconds(-1)
                    $blocked=$false;try{Invoke-LabLlamaCppSessionStopPlan -PlanId $expired.PlanId -Confirmed|Out-Null}catch{$blocked=$_.Exception.Message -ceq 'LLAMA_SESSION_PREVIEW_EXPIRED'}
                    if(-not $blocked -or $Worker.HasExited){throw 'GUIDED_STALE_FAILED'}
                    $result=(Invoke-SqlServerLabWorkflowAction -Action StopLlamaSession -LlamaSessionPlanId $plan.PlanId -ConfirmLlamaSessionStop).Result
                    $Evidence.Stopped=$result.Status -ceq 'CLEANUP_SUCCEEDED'
                    if($result.Status -cne 'CLEANUP_SUCCEEDED' -or (Get-LabLlamaCppSessionView).Items.Count){throw 'GUIDED_STOP_FAILED'}
                    $blocked=$false;try{Invoke-LabLlamaCppSessionStopPlan -PlanId $plan.PlanId -Confirmed|Out-Null}catch{$blocked=$_.Exception.Message -ceq 'LLAMA_SESSION_PREVIEW_NOT_FOUND'}
                    if(-not $blocked){throw 'GUIDED_REPLAY_FAILED'}
                } $request.OperationId $worker $scope $receiptPath $guidedEvidence
                $workerGone=$workerWatch.WaitForExit(5000);$childGone=$child.WaitForExit(5000)
                if(-not $workerGone -or -not $childGone -or (Test-Path -LiteralPath (Join-Path $scope 'api-key.txt')) -or $neighbor.HasExited){throw 'GUIDED_NATIVE_POSTCONDITION_FAILED'}
            } catch {$guidedFailure=$_}
            finally {
                try {
                    # Failed stop retains the exact original worker. OnRemove is not cleanup evidence.
                    if(-not $guidedEvidence.Stopped -and -not $worker.HasExited){
                        $worker.StandardInput.Close()
                        if(-not $worker.WaitForExit(5000)){$worker.Kill();if(-not $worker.WaitForExit(5000)){throw 'GUIDED_WORKER_CLEANUP_UNCONFIRMED'}}
                    }
                    $workerGone=$workerWatch.WaitForExit(5000);$childGone=$child.WaitForExit(5000)
                    if(-not $workerGone -or -not $childGone){throw 'GUIDED_ACTIVITY_CLEANUP_UNCONFIRMED'}
                    $keyPath=Join-Path $scope 'api-key.txt'
                    if(Test-Path -LiteralPath $keyPath){Remove-Item -LiteralPath $keyPath -Force -ErrorAction Stop}
                    $null=$workers.Remove($worker)
                    & $module {$script:LlamaCppOwnedSessions=@{};$script:LlamaCppStopPlans=@{}}
                    if(-not $guidedEvidence.Stopped){$worker.Dispose()}
                    if(-not $neighbor.HasExited){$neighbor.Kill()}
                    $neighborGone=$neighbor.WaitForExit(5000)
                    if(-not $neighborGone){throw 'GUIDED_NEIGHBOR_CLEANUP_UNCONFIRMED'}
                    $null=$workers.Remove($neighbor);$neighbor.Dispose()
                } catch {$guidedCleanupFailure=$_;$preserveRoot=$true}
                finally {$workerWatch.Dispose();$child.Dispose();Remove-Module $module -Force}
            }
            if($workerGone -and $childGone -and $neighborGone -and -not $guidedCleanupFailure){$preserveRoot=$false}
            if($guidedCleanupFailure){throw "GUIDED_RECOVERY_REQUIRED; OriginalFailure=$($guidedFailure.Exception.Message); CleanupFailure=$($guidedCleanupFailure.Exception.Message)"}
            if($guidedFailure){throw $guidedFailure}
            Write-Host 'PASS: GuidedStop preview/cancel/stale/apply/replay; worker/child/key absent, neighboring child untouched then own-cleaned; no SQL/model probe'
            continue
        }
        if($mode -eq 'WorkerKilled'){$worker.Kill()}
        elseif($mode -eq 'OwnerClosed'){$worker.StandardInput.Close()}
        if(-not $worker.WaitForExit(15000)){throw 'WORKER_DID_NOT_EXIT'}
        if(-not $child.WaitForExit(5000)){throw 'OWN_CHILD_SURVIVED'}
        $child.Dispose()
        if($mode -ne 'WorkerKilled' -and (Test-Path (Join-Path $scope 'api-key.txt'))){throw 'SECRET_NOT_REMOVED'}
        if($mode -eq 'OutputLimit' -and (Get-Item -LiteralPath (Join-Path $scope 'stdout.log')).Length -ne 4MB){throw 'OUTPUT_CAP_FAILED'}
        Write-Host "PASS: $mode terminates its child; scoped cleanup confirmed"
    }
}
finally {
    foreach($worker in $workers){if(-not $worker.HasExited){$worker.Kill();$null=$worker.WaitForExit(5000)};$worker.Dispose()}
    $resolved=[IO.Path]::GetFullPath($root);$boundary=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    if(-not $resolved.StartsWith($boundary,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notlike 'sql-lab-llama-ownership-*'){throw 'CLEANUP_SCOPE_INVALID'}
    if(-not $preserveRoot){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
Write-Host 'LLAMA OWNERSHIP ACCEPTANCE: PASS; CLEANUP_SUCCEEDED'
