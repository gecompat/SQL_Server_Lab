#Requires -Version 7.2
$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
$module=Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru
try {
    & $module {
        param($Root)
        $script:SchemasPath=Join-Path $Root 'Schemas'
        $runId=[guid]::NewGuid().ToString('D');$scopeId=[guid]::NewGuid().ToString('D');$containerId=('a'*64)
        $state=Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-autostart-apply-'+[guid]::NewGuid().ToString('N'))
        $runDirectory=Join-Path (Join-Path $state 'runs') $runId;$null=New-Item -ItemType Directory -Path $runDirectory -Force
        try {
            $desiredInstance=[pscustomobject]@{Id='primary';Provider='docker';AutoStart='off'}
            $run=[pscustomobject]@{runId=$runId;scopeId=$scopeId;state='RUNNING';metadata=[pscustomobject]@{desiredState=[pscustomobject]@{Instances=@($desiredInstance)}}}
            $connection=[pscustomobject]@{instances=@([pscustomobject]@{id='primary';provider='docker';containerId=$containerId;autostart='off'})}
            $script:context=[pscustomobject]@{
                Run=$run;RunId=$runId;RunDirectory=$runDirectory;StateRoot=$state;Connection=$connection;ConnectionPath=(Join-Path $runDirectory 'connection-info.json')
                Instance=$connection.instances[0];InstanceId='primary';Provider='docker';ContainerId=$containerId;ContainerName='synthetic-sql';WasRunning=$true
                CurrentAutoStart='off';CurrentRestartPolicy='no'
                Inspect=[pscustomobject]@{Id=$containerId;State=[pscustomobject]@{Running=$true};Config=[pscustomobject]@{Labels=[pscustomobject]@{'sql-server-lab.instance-id'='primary';'sql-server-lab.run-id'=$runId;'sql-server-lab.scope-id'=$scopeId}};HostConfig=[pscustomobject]@{RestartPolicy=[pscustomobject]@{Name='no'}}}
            }
            $script:commands=@();$script:writes=@();$script:lastJournal=$null
            function Get-LabCanonicalResourceRoot { param($StateRoot) $StateRoot }
            function Assert-LabResourceChangeAllowed { param($RunId,$StateRoot) }
            function Test-LabAutomatedTestEnvironmentRun { param($RunId) $false }
            function Get-LabContainerResourceLockName { param($StateRoot,$RunId) 'sql-lab-autostart-apply-test-lock' }
            function Get-LabContainerReconcileContext { param($RunId,$InstanceId,$StateRoot) $script:context }
            function Get-LabProviderSubRuns { param($RunId,$StateRoot) @([pscustomobject]@{provider='docker';state='RUNNING'}) }
            function Get-LabPersistedDesiredState { param($RunId,$StateRoot) [pscustomobject]@{Status='VALID';Snapshot=$script:context.Run.metadata.desiredState} }
            function Write-LabArtifactJsonAtomic { param($Path,$InputObject) $script:writes+=,$Path;if($Path -like '*container-autostart-journal.json'){$script:lastJournal=$InputObject|ConvertTo-Json -Depth 60|ConvertFrom-Json -Depth 60; $InputObject|ConvertTo-Json -Depth 60|Set-Content -LiteralPath $Path -Encoding utf8} }
            function Invoke-LabContainerReconcileCommand { param($Provider,$Arguments,$ErrorCode) $script:commands+=,@($Arguments);$script:context.Inspect.HostConfig.RestartPolicy.Name=[string]$Arguments[2];$script:context.CurrentRestartPolicy=[string]$Arguments[2];$script:context.CurrentAutoStart=if($Arguments[2]-eq'unless-stopped'){'on'}else{'off'} }
            function Assert-LabContainerReconcileRuntimeIdentity { param($Provider,$Identity,$RunId,$ScopeId) $script:context.Inspect }

            $plan=Get-SqlServerLabContainerAutoStartPlan -RunId $runId -InstanceId primary -AutoStart on -StateRoot $state
            if($plan.NoChange -or -not $plan.MutationAllowed -or $plan.ChangeClass-ne'live' -or $plan.Desired.AutoStart-ne'ON' -or $plan.PlanKey-notmatch'^[a-f0-9]{64}$' -or ($plan|ConvertTo-Json -Depth 10)-match $containerId){throw 'AUTOSTART_APPLY_PLAN_BINDING'}
            $result=Set-SqlServerLabContainerAutoStart -RunId $runId -InstanceId primary -AutoStart on -ExpectedAutoStartPlanKey $plan.PlanKey -StateRoot $state -Confirm:$false
            if($result.Status-ne'SUCCEEDED' -or $script:commands.Count-ne 1 -or (@($script:commands[0])-join' ') -ne "update --restart unless-stopped $containerId"){throw 'AUTOSTART_APPLY_COMMAND'}
            if($script:context.Inspect.Id-ne$containerId -or -not $script:context.Inspect.State.Running -or $connection.instances[0].autostart-ne'on' -or $desiredInstance.AutoStart-ne'on'){throw 'AUTOSTART_APPLY_STATE'}
            if($script:lastJournal.Status-ne'COMPLETED' -or $script:lastJournal.Runtime.OriginalId-ne$containerId -or $script:lastJournal.Before.Running-ne$true){throw 'AUTOSTART_APPLY_JOURNAL'}
            $connection.instances[0].autostart='off';$desiredInstance.AutoStart='off'
            $journalPath=Get-LabContainerAutoStartJournalPath -RunDirectory $runDirectory;$recovery=Get-Content -LiteralPath $journalPath -Raw|ConvertFrom-Json -Depth 60
            $recovery.Status='RECOVERY_REQUIRED';$recovery.Recovery.Status='RESUME_STATE_COMMIT';$recovery|ConvertTo-Json -Depth 60|Set-Content -LiteralPath $journalPath -Encoding utf8
            $beforeRecovery=$script:commands.Count;$recovered=Resume-SqlServerLabContainerAutoStart -RunId $runId -InstanceId primary -StateRoot $state -Confirm:$false
            if($recovered.Status-ne'RECOVERY_SUCCEEDED' -or $script:commands.Count-ne$beforeRecovery -or $connection.instances[0].autostart-ne'on' -or $desiredInstance.AutoStart-ne'on' -or $script:lastJournal.Status-ne'COMPLETED'){throw 'AUTOSTART_APPLY_RECOVERY'}
            $noOpPlan=Get-SqlServerLabContainerAutoStartPlan -RunId $runId -InstanceId primary -AutoStart on -StateRoot $state
            $before=$script:commands.Count;$noOp=Set-SqlServerLabContainerAutoStart -RunId $runId -InstanceId primary -AutoStart on -ExpectedAutoStartPlanKey $noOpPlan.PlanKey -StateRoot $state -Confirm:$false
            if(-not $noOp.NoChange -or $script:commands.Count-ne$before){throw 'AUTOSTART_APPLY_NO_OP'}
            Write-Host 'Container autostart apply fixture: PASS'
        }
        finally { Remove-Item -LiteralPath $state -Recurse -Force -ErrorAction SilentlyContinue }
    } $repoRoot
}
finally { Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue }
