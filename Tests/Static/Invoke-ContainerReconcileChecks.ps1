#Requires -Version 7.2
<#
.SYNOPSIS
    Prueft Container-Reconcile-Plan, Action und Journal ohne Provider-Mutation.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$modulePath = Join-Path $repoRoot 'SqlServerLab.psd1'
$failures = [Collections.Generic.List[string]]::new()
$passed = 0
. (Join-Path $PSScriptRoot '..' 'Common' 'CheckResult.ps1')

Write-Host ''
Write-Host 'SQL_Server_Lab - Container Reconcile Checks' -ForegroundColor Cyan
Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
Import-Module $modulePath -Force -ErrorAction Stop

$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) "sql-lab-container-reconcile-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $temporaryRoot -Force | Out-Null
try {
    $module = Get-Module SqlServerLab
    $evidence = & $module {
        param($Root)
        $runId=[guid]::NewGuid().ToString('D'); $scopeId=[guid]::NewGuid().ToString('D')
        $runDirectory=Join-Path $Root $runId; New-Item -ItemType Directory -Path $runDirectory -Force | Out-Null
        $connection=[PSCustomObject]@{ instances=@([PSCustomObject]@{ id='primary'; provider='docker'; host='127.0.0.1'; port=14333; containerName='reconcile-mock' }) }
        $context=[PSCustomObject]@{
            Run=[PSCustomObject]@{ runId=$runId; scopeId=$scopeId; state='RUNNING' }; RunId=$runId; RunDirectory=$runDirectory; StateRoot=$Root
            Connection=$connection; ConnectionPath=(Join-Path $runDirectory 'connection-info.json'); Instance=$connection.instances[0]
            InstanceId='primary'; Provider='docker'; ContainerName='reconcile-mock'; ContainerId='original-id'; WasRunning=$true
            CurrentPort=14333; CurrentMemoryMB=2048; CurrentCpu=[decimal]2; ConfiguredSqlMemory=@('MSSQL_MEMORY_LIMIT_MB=1638')
            HealthCommand='CMD-SHELL sqlcmd -C -Q SELECT 1'; MountFingerprint=('a' * 64)
            CurrentRestartPolicy='no'; CurrentAutoStartLabel='off'; CurrentAutoStart='off'
        }
        Write-LabArtifactJsonAtomic -Path $context.ConnectionPath -InputObject $connection
        $originalContext=(Get-Command Get-LabContainerReconcileContext).ScriptBlock
        $originalSql=(Get-Command Get-LabContainerSqlMaxMemoryMB).ScriptBlock
        $originalUpdate=(Get-Command Update-SqlServerLabContainer).ScriptBlock
        try {
            Set-Item Function:Get-LabContainerReconcileContext -Value { return $script:containerReconcileTestContext }
            Set-Item Function:Get-LabContainerSqlMaxMemoryMB -Value { param($Context) return 1536 }
            $script:containerReconcileTestContext=$context
            $noOp=Get-SqlServerLabReconcilePlan -RunId $runId -Container -Cpu 2 -MemoryMB 2048 -Port 14333 -SqlMaxMemoryMB 1536 -StateRoot $Root
            $live=Get-SqlServerLabReconcilePlan -RunId $runId -Container -Cpu 3 -MemoryMB 2560 -Port 14333 -SqlMaxMemoryMB 1408 -StateRoot $Root
            $recreate=Get-SqlServerLabReconcilePlan -RunId $runId -Container -Cpu 2 -MemoryMB 2048 -Port 15433 -StateRoot $Root
            $autoStart=Get-SqlServerLabReconcilePlan -RunId $runId -Container -AutoStart on -RepairSqlRuntimeContract -StateRoot $Root
            $beforeFiles=@(Get-ChildItem -LiteralPath $runDirectory -File | ForEach-Object Name)
            $null=Get-SqlServerLabReconcilePlan -RunId $runId -Container -Cpu 2 -MemoryMB 2048 -Port 14333 -StateRoot $Root
            $afterFiles=@(Get-ChildItem -LiteralPath $runDirectory -File | ForEach-Object Name)

            $script:updateCalls=0
            Set-Item Function:Update-SqlServerLabContainer -Value {
                param($RunId,$InstanceId,$Cpu,$MemoryMB,$Port,$SqlMaxMemoryMB,$AutoStart,$ReadinessTimeoutSeconds,$RepairSqlRuntimeContract,$StateRoot,$Confirm)
                $script:updateCalls++
                [PSCustomObject]@{ Status='SUCCEEDED'; Changed=$true; ChangeClass='live'; RunId=$RunId; InstanceId=$InstanceId; Cpu=$Cpu; MemoryMB=$MemoryMB; Port=$Port; SqlMaxMemoryMB=$SqlMaxMemoryMB; AutoStart=$AutoStart }
            }
            $actionNoOp=Invoke-SqlServerLabReconcileAction -RunId $runId -Container -Cpu 2 -MemoryMB 2048 -Port 14333 -SqlMaxMemoryMB 1536 -StateRoot $Root -Confirm:$false
            $actionLive=Invoke-SqlServerLabReconcileAction -RunId $runId -Container -Cpu 3 -MemoryMB 2560 -Port 14333 -SqlMaxMemoryMB 1408 -StateRoot $Root -Confirm:$false
            $actionAutoStart=Invoke-SqlServerLabReconcileAction -RunId $runId -Container -AutoStart on -RepairSqlRuntimeContract -StateRoot $Root -Confirm:$false
            $whatIf=Invoke-SqlServerLabReconcileAction -RunId $runId -Container -Cpu 4 -MemoryMB 2560 -Port 14333 -StateRoot $Root -WhatIf

            $journalInfo=New-LabContainerReconcileJournal -Context $context -Plan $live
            $journal=Get-Content -LiteralPath $journalInfo.Path -Raw -Encoding utf8 | ConvertFrom-Json -Depth 40
            [PSCustomObject]@{
                NoOp=$noOp; Live=$live; Recreate=$recreate; AutoStart=$autoStart; BeforeFiles=$beforeFiles; AfterFiles=$afterFiles
                ActionNoOp=$actionNoOp; ActionLive=$actionLive; ActionAutoStart=$actionAutoStart; WhatIf=$whatIf; UpdateCalls=$script:updateCalls
                Journal=$journal; JournalSchema=(Assert-LabContainerReconcileJournal -Journal $journal)
                TransitionMap=Get-LabStateTransitionMap
            }
        }
        finally {
            Set-Item Function:Get-LabContainerReconcileContext -Value $originalContext
            Set-Item Function:Get-LabContainerSqlMaxMemoryMB -Value $originalSql
            Set-Item Function:Update-SqlServerLabContainer -Value $originalUpdate
            Remove-Variable containerReconcileTestContext -Scope Script -ErrorAction SilentlyContinue
        }
    } $temporaryRoot

    Add-CheckResult -Name 'No-op-Plan bleibt actions- und mutationsfrei' -Success (
        $evidence.NoOp.IsNoOp -and $evidence.NoOp.HighestChangeClass -eq 'no-op' -and @($evidence.NoOp.Actions).Count -eq 0 -and
        (Compare-Object $evidence.BeforeFiles $evidence.AfterFiles).Count -eq 0
    )
    Add-CheckResult -Name 'CPU, RAM und SQL max memory werden als live klassifiziert' -Success (
        $evidence.Live.HighestChangeClass -eq 'live' -and $evidence.Live.Preview.Downtime -eq 'none' -and
        @($evidence.Live.Diff | Where-Object Changed).Count -eq 3
    )
    Add-CheckResult -Name 'Hostport und Runtime-Vertragsreparatur verwenden recreate mit Daten- und Recovery-Vorschau' -Success (
        $evidence.Recreate.HighestChangeClass -eq 'recreate' -and $evidence.Recreate.Preview.Downtime -eq 'brief' -and
        $evidence.Recreate.Preview.DataImpact -match 'preserved' -and $evidence.Recreate.Preview.Recovery -match 'rollback'
    )
    Add-CheckResult -Name 'Autostart-Drift wird explizit als recreate geplant und bis zum Executor weitergereicht' -Success (
        $evidence.AutoStart.HighestChangeClass -eq 'recreate' -and $evidence.AutoStart.Desired.AutoStart -eq 'on' -and
        @($evidence.AutoStart.Diff | Where-Object { $_.Field -eq 'AutoStart' -and $_.Changed }).Count -eq 1 -and
        $evidence.ActionAutoStart.ExecutionPlan[0].Result.AutoStart -eq 'on'
    )
    Add-CheckResult -Name 'Action führt nur den bestätigten nichtleeren Plan aus' -Success (
        $evidence.ActionNoOp.ExecutionSummary.Status -eq 'NO_OP' -and $evidence.ActionLive.ExecutionSummary.Status -eq 'SUCCEEDED' -and
        $evidence.WhatIf.ExecutionSummary.Status -eq 'WOULD_EXECUTE' -and $evidence.UpdateCalls -eq 2
    )
    Add-CheckResult -Name 'Operationsjournal ist schema-valid und bindet Run, Scope, echte ID und Compensation' -Success (
        $evidence.JournalSchema -and $evidence.Journal.Status -eq 'PREPARED' -and $evidence.Journal.Runtime.OriginalId -eq 'original-id' -and
        $evidence.Journal.Recovery.Status -eq 'ROLLBACK_AVAILABLE'
    )
    $publicPayload=@($evidence.NoOp,$evidence.Live,$evidence.Recreate,$evidence.AutoStart,$evidence.ActionNoOp,$evidence.ActionLive,$evidence.ActionAutoStart,$evidence.WhatIf) | ConvertTo-Json -Depth 30
    Add-CheckResult -Name 'Öffentliche Plan-/Action-Verträge bleiben frei von Runtime-IDs, Hostpfaden und Secrets' -Success (
        $publicPayload -notmatch 'original-id|MountFingerprint|PreviousConnection|MSSQL_SA_PASSWORD|Password=|containerId|runtimeId'
    )
    Add-CheckResult -Name 'Statevertrag erlaubt sichtbaren Reconcile-Recovery-Zustand und Rückkehr' -Success (
        'RECOVERY_REQUIRED' -in @($evidence.TransitionMap.RUNNING) -and 'RUNNING' -in @($evidence.TransitionMap.RECOVERY_REQUIRED)
    )
}
finally {
    Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''; Write-Host "Ergebnis: $passed PASS, $($failures.Count) FAIL" -ForegroundColor Cyan
if ($failures.Count) { exit 1 }; exit 0
