#Requires -Version 7.5
[CmdletBinding()]
param([Parameter(Mandatory)][string]$PlanPath,[Parameter(Mandatory)][ValidatePattern('\A[0-9A-F]{64}\z')][string]$ExpectedPlanSha256,
    [Parameter(Mandatory)][ValidateSet('Bootstrap','Workflow')][string]$Mode,[ValidateSet('Ready','Run')][string]$Operation='Ready',[int]$Attempt=0,
    [ValidatePattern('\A[0-9a-f-]{36}\z')][string]$DispatchId)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')
Assert-BoundedTlsAdministrator
$plan=Read-BoundedTlsPinnedJson $PlanPath $ExpectedPlanSha256;Assert-BoundedTlsPlan $plan -Installed
if([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -cne $plan.ActorSid){throw 'BOUNDED_TLS_RUNTIME_ACTOR_CHANGED'}
Assert-BoundedTlsBinaryPins $plan
Set-BoundedTlsProcessEnvironment $plan
$root=$plan.InstallRoot;$source=Join-Path $root 'source';$statePath=Join-Path $root 'state.private.json'
$pins=[Collections.Generic.List[IDisposable]]::new();$mutex=$null;$held=$false;$nativeStarted=$false
function Close-BoundedTlsTask {
    param([string]$Reason)
    $task=Get-ScheduledTask -TaskName $plan.TaskName -ErrorAction Stop
    $principal=$task.Principal.UserId
    if(-not $principal.StartsWith('S-1-',[StringComparison]::Ordinal)){$principal=([Security.Principal.NTAccount]::new($principal)).Translate([Security.Principal.SecurityIdentifier]).Value}
    if($principal -cne $plan.ActorSid -or @($task.Actions).Count -ne 1 -or
        $task.Actions[0].Execute -ine (Join-Path ([Environment]::GetFolderPath('Windows')) 'System32/cmd.exe') -or
        $task.Actions[0].Arguments -cne ('/d /s /c ""'+(Join-Path $root 'launch.cmd')+'""')){throw 'BOUNDED_TLS_TASK_DRIFT_NO_REMOVAL'}
    Unregister-ScheduledTask -TaskName $plan.TaskName -Confirm:$false
    Write-BoundedTlsJson (Join-Path $root 'closed.private.json') @{Status='CLOSED';Reason=$Reason;TaskRemoved=$true;ObservedAtUtc=[datetimeoffset]::UtcNow.ToString('o')}
}
try{
    foreach($row in $plan.Sources){
        $path=Assert-BoundedTlsSourceRow $row $source
        $pin=[IO.File]::Open($path,'Open','Read','Read');$pins.Add($pin)
        if([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($pin)) -cne $row.Sha256){throw 'BOUNDED_TLS_FROZEN_SOURCE_CHANGED'}
    }
    if($Mode -ceq 'Workflow'){
        $dispatch=[guid]::Empty
        if(-not [guid]::TryParseExact($DispatchId,'D',[ref]$dispatch) -or $dispatch -eq [guid]::Empty -or $dispatch.ToString('D') -cne $DispatchId){throw 'BOUNDED_TLS_DISPATCH_INVALID'}
        $active=Read-BoundedTlsJson $statePath
        if($active.Status -cne 'RUNNING' -or $active.LastRequestId -cne $DispatchId -or $active.Attempts -ne $Attempt){throw 'BOUNDED_TLS_DISPATCH_NOT_ACTIVE'}
        $launchName='launch-'+$DispatchId+'.private.json'
        Write-BoundedTlsJson (Join-Path $root $launchName) @{Pid=$PID;StartTicks=(Get-Process -Id $PID).StartTime.ToUniversalTime().Ticks;DispatchId=$DispatchId}
        function Write-WorkflowOutcome($Value){
            $Value.DispatchId=$DispatchId;$Value.Pid=$PID;$Value.PlanSha256=$ExpectedPlanSha256
            $name=if($Operation -ceq 'Ready'){'ready-'+$DispatchId+'.private.json'}else{'outcome-'+$DispatchId+'.private.json'}
            Write-BoundedTlsJson (Join-Path $root $name) $Value
        }
        if($Operation -ceq 'Run' -and ($Attempt -lt 1 -or $Attempt -gt 2)){throw 'BOUNDED_TLS_ATTEMPT_INVALID'}
        $module=Import-Module (Join-Path $source 'SqlServerLab.psd1') -Force -PassThru
        $null=& $module {param($p)Get-LabTlsOperationalAuthority $p.DataRoot $p.ControllerId $p.LocationId $p.AuthorityRef $p.ClientRef} $plan
        if([datetimeoffset]::UtcNow -ge [datetimeoffset]::Parse($plan.ExpiresUtc)){throw 'BOUNDED_TLS_LEASE_EXPIRED'}
        if($Operation -ceq 'Ready'){
            Write-WorkflowOutcome @{Status='READY';Elevated=$true;AuthorityValidated=$true;ObservedAtUtc=[datetimeoffset]::UtcNow.ToString('o')}
            return
        }
        $work=Join-Path $root ('work/attempt-'+$Attempt)
        & $module {param($p,$s)Initialize-LabTlsCaPrivateDirectory $p $s -NewOnly} $work $plan.ActorSid
        . (Join-Path $source 'Tests/Common/AuthenticatedTlsHyperVAcceptance.ps1')
        $snapshot=Get-TlsHyperVSourceSnapshot $source $module
        $config=@{Scope='PUBLIC_WINDOWS_TLS_NEW_UNINTERRUPTED';MaximumCreates=1;MaximumMinutes=120;ExpectedBuild='17.0.1000.7';ExpiresUtc=$plan.ExpiresUtc;
            ActorSid=$plan.ActorSid;RepositoryRoot=$source;EvidenceRoot=$work;DataRoot=$plan.DataRoot;StateRoot=$plan.StateRoot;ControllerId=$plan.ControllerId;
            LocationId=$plan.LocationId;CandidateId=$plan.CandidateId;AuthorityRef=$plan.AuthorityRef;ClientRef=$plan.ClientRef;OperationId=[guid]::NewGuid().ToString('D');
            Sources=$snapshot.Sources;SourceDigest=$snapshot.SourceDigest;RunnerSha256=(Get-BoundedTlsHash (Join-Path $source 'Tests/Integration/Invoke-AuthenticatedTlsWindowsPublicAcceptance.ps1'))}
        $configPath=Join-Path $work 'config.private.json'
        & $module {param($p,$s,$v)Write-LabTlsCaPrivateFile $p $s (ConvertTo-LabTlsRegistryWriterBytes $v)} $configPath $plan.ActorSid $config
        $deadline=[datetimeoffset]::UtcNow.AddMinutes(45)
        if($deadline -gt [datetimeoffset]::Parse($plan.ExpiresUtc)){$deadline=[datetimeoffset]::Parse($plan.ExpiresUtc)}
        if(Test-Path -LiteralPath (Join-Path $root 'dispatch-cancelled.private.json')){throw 'BOUNDED_TLS_DISPATCH_CANCELLED'}
        $nativeStarted=$true
        & $plan.Binaries.PowerShell.Path -NoLogo -NoProfile -NonInteractive -File (Join-Path $source 'Tests/Integration/Invoke-AuthenticatedTlsWindowsPublicAcceptance.ps1') `
            -ConfigurationPath $configPath -ExpectedConfigurationSha256 (Get-BoundedTlsHash $configPath) -Mode Supervisor -DeadlineUtc $deadline.ToString('o')
        $nativeExit=$LASTEXITCODE
        $resultPath=Join-Path $work 'supervisor-result.private.json'
        $result=if(Test-Path -LiteralPath $resultPath){Read-BoundedTlsJson $resultPath}else{$null}
        if($result -and $nativeExit -eq 0 -and $result.Status -ceq 'PASS' -and $result.NativeEndKnown -eq $true -and @($result.Cases).Count -eq 7){
            Write-WorkflowOutcome @{Status='PASS';Attempt=$Attempt;NativeEndKnown=$true;CoordinatorCases=7;SupervisorPid=$result.Pid;SourceDigest=$snapshot.SourceDigest}
        }else{
            $workerPath=Join-Path $work 'worker-result.private.json';$worker=if(Test-Path -LiteralPath $workerPath){Read-BoundedTlsJson $workerPath}else{$null}
            $clean=$false
            if($worker -and $worker.NativeEndKnown -eq $true -and $worker.Cleanup -ceq 'REMOVED'){
                & $plan.Binaries.PowerShell.Path -NoLogo -NoProfile -NonInteractive -File (Join-Path $source 'Tests/Integration/Invoke-AuthenticatedTlsWindowsPublicCleanupAudit.ps1') `
                    -ConfigurationPath $configPath -ExpectedConfigurationSha256 (Get-BoundedTlsHash $configPath)
                $clean=$LASTEXITCODE -eq 0
            }
            Write-WorkflowOutcome @{Status='FAIL';Attempt=$Attempt;NativeEndKnown=([bool]$worker -and $worker.NativeEndKnown -eq $true);CleanupAudited=$clean;NativeExit=$nativeExit}
        }
        return
    }
    $mutex=[Threading.Mutex]::new($false,('Global\SQL_Server_Lab_BoundedTls_'+$plan.RunnerId))
    try{$held=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$held=$true;throw 'BOUNDED_TLS_MUTEX_ABANDONED'}
    if(-not $held){throw 'BOUNDED_TLS_ALREADY_ACTIVE'}
    $state=Read-BoundedTlsJson $statePath
    # Teardown and unknown-predecessor lockout never depend on writable input.
    $protectedDecision=Get-BoundedTlsDecision $plan $state 'Ready'
    if($protectedDecision -cin @('CLOSE','CLOSED','RECOVERY')){
        Close-BoundedTlsTask $protectedDecision
        $state.Status=if($protectedDecision -ceq 'RECOVERY'){'RECOVERY_REQUIRED'}else{'CLOSED'}
        Write-BoundedTlsJson $statePath $state -Replace;return
    }
    $requestPath=Join-Path $root 'requests/request.private.json'
    $request=if(Test-Path -LiteralPath $requestPath){Read-BoundedTlsJson $requestPath 2048 $plan.ActorSid}else{$null}
    $op='Ready'
    if($request){
        Assert-BoundedTlsRequest $request $plan.RunnerId $state
        $op=$request.Operation
    }
    $decision=Get-BoundedTlsDecision $plan $state $op
    if($decision -cin @('CLOSE','CLOSED','EXHAUSTED')){
        Close-BoundedTlsTask $decision;$state.Status='CLOSED';Write-BoundedTlsJson $statePath $state -Replace;return
    }
    if($decision -ceq 'RUN'){
        if($state.Status -cne 'READY' -and $state.Status -cne 'FAILED_CLEANED'){throw 'BOUNDED_TLS_READINESS_REQUIRED'}
        $state.Attempts=[int]$state.Attempts+1
    }
    $state.Status='RUNNING';$state.LastRequestId=if($request){$request.RequestId}else{[guid]::NewGuid().ToString('D')}
    $state.ConsumedRequestIds=@($state.ConsumedRequestIds)+@($state.LastRequestId)
    Write-BoundedTlsJson $statePath $state -Replace
    $modeOp=if($decision -ceq 'RUN'){'Run'}else{'Ready'}
    $arguments='-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -File "'+$PSCommandPath+'" -PlanPath "'+$PlanPath+'" -ExpectedPlanSha256 '+$ExpectedPlanSha256+' -Mode Workflow -Operation '+$modeOp+' -Attempt '+$state.Attempts+' -DispatchId '+$state.LastRequestId
    Invoke-CommandInDesktopPackage -PackageFamilyName $plan.PackageFamilyName -AppId $plan.AppId -Command $plan.Binaries.PowerShell.Path -Args $arguments -PreventBreakaway
    $receipt=if($modeOp -ceq 'Ready'){Join-Path $root ('ready-'+$state.LastRequestId+'.private.json')}else{Join-Path $root ('outcome-'+$state.LastRequestId+'.private.json')}
    $end=[datetimeoffset]::Parse($plan.ExpiresUtc)
    $ackEnd=[datetimeoffset]::UtcNow.AddSeconds(60)
    $launchName='launch-'+$state.LastRequestId+'.private.json'
    while(-not (Test-Path -LiteralPath $receipt)){
        if([datetimeoffset]::UtcNow -ge $end -or ([datetimeoffset]::UtcNow -ge $ackEnd -and -not(Test-Path -LiteralPath (Join-Path $root $launchName)))){
            Write-BoundedTlsJson (Join-Path $root 'dispatch-cancelled.private.json') @{Reason='LEASE_OR_ACK_ENDED';NoNativeKill=$true}
            $state.Status='RECOVERY_REQUIRED';Write-BoundedTlsJson $statePath $state -Replace
            Close-BoundedTlsTask 'LEASE_ENDED_RETAIN_UNKNOWN_NATIVE_RESOURCES';return
        }
        Start-Sleep -Seconds 2
    }
    $outcome=Read-BoundedTlsJson $receipt
    $launch=Read-BoundedTlsJson (Join-Path $root $launchName)
    if($outcome.DispatchId -cne $state.LastRequestId -or $launch.DispatchId -cne $state.LastRequestId -or $outcome.Pid -ne $launch.Pid -or
        $outcome.PlanSha256 -cne $ExpectedPlanSha256){throw 'BOUNDED_TLS_WORKFLOW_RESULT_BINDING_INVALID'}
    $child=Get-Process -Id $launch.Pid -ErrorAction SilentlyContinue
    if($child -and $child.StartTime.ToUniversalTime().Ticks -eq $launch.StartTicks){
        if(-not $child.WaitForExit(10000)){throw 'BOUNDED_TLS_WORKFLOW_END_UNKNOWN'}
    }
    if($modeOp -ceq 'Ready'){$state.Status=if($outcome.Status -ceq 'READY' -and $outcome.Elevated -eq $true -and $outcome.AuthorityValidated -eq $true){'READY'}else{'BLOCKED'}}
    elseif($outcome.Status -ceq 'PASS'){$state.Status='PASS';Close-BoundedTlsTask 'PASS_CLEANED'}
    elseif($outcome.NativeEndKnown -eq $true -and $outcome.CleanupAudited -eq $true){$state.Status='FAILED_CLEANED'}
    else{$state.Status='RECOVERY_REQUIRED';Close-BoundedTlsTask 'RETAIN_UNKNOWN_NATIVE_RESOURCES'}
    $state.Results=@($state.Results)+@($outcome)
    Write-BoundedTlsJson $statePath $state -Replace
}catch{
    if($Mode -ceq 'Workflow'){
        $failure=if($Operation -ceq 'Ready'){Join-Path $root ('ready-'+$DispatchId+'.private.json')}else{Join-Path $root ('outcome-'+$DispatchId+'.private.json')}
        if(-not(Test-Path -LiteralPath $failure)){
            Write-BoundedTlsJson $failure @{Status='FAIL';DispatchId=$DispatchId;Pid=$PID;PlanSha256=$ExpectedPlanSha256;Attempt=$Attempt;NativeEndKnown=(-not $nativeStarted);CleanupAudited=(-not $nativeStarted);ErrorCode='BOUNDED_TLS_WORKFLOW_FAILED'}
        }
    }
    Write-BoundedTlsJson (Join-Path $root ('error-'+[guid]::NewGuid().ToString('N')+'.private.json')) @{Status='FAIL';Mode=$Mode;Operation=$Operation;Error=$_.Exception.ToString();ObservedAtUtc=[datetimeoffset]::UtcNow.ToString('o')}
    throw
}finally{
    if($held){$mutex.ReleaseMutex()};if($mutex){$mutex.Dispose()}
    for($i=$pins.Count-1;$i -ge 0;$i--){$pins[$i].Dispose()}
}
