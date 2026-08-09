#Requires -Version 7.2
<#
.SYNOPSIS
    Prueft den Reconcile-Executor fuer eine gesteuerte Apply-Phase.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$modulePath = Join-Path $repoRoot 'SqlServerLab.psd1'
$actionPath = Join-Path $repoRoot 'Public\Invoke-SqlServerLabReconcileAction.ps1'

$failures = [System.Collections.Generic.List[string]]::new()
$passed = 0
. (Join-Path $PSScriptRoot '..' 'Common' 'CheckResult.ps1')

Write-Host ''
Write-Host 'SQL_Server_Lab - Reconcile-Action Contract Checks' -ForegroundColor Cyan

Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
Import-Module $modulePath -Force -ErrorAction Stop

Add-CheckResult `
    -Name 'Export verfuegbar: Invoke-SqlServerLabReconcileAction' `
    -Success ([bool](Get-Command Invoke-SqlServerLabReconcileAction -Module SqlServerLab -ErrorAction SilentlyContinue))

$startCommand = Get-Command Start-SqlServerLab -Module SqlServerLab -ErrorAction Stop
$stopCommand = Get-Command Stop-SqlServerLab -Module SqlServerLab -ErrorAction Stop
Add-CheckResult `
    -Name 'Start-SqlServerLab und Stop-SqlServerLab akzeptieren optionalen StateRoot' `
    -Success (($startCommand.Parameters.ContainsKey('StateRoot') -and $stopCommand.Parameters.ContainsKey('StateRoot')))

$testSource = Get-Content -LiteralPath $actionPath -Raw -Encoding utf8
$forbiddenMutations = @(
    'Write-LabArtifactJsonAtomic',
    'Set-Content',
    'Set-LabRunState',
    'Set-LabProviderSubRunState',
    'Set-LabRunRuntimeState',
    'Sync-LabRunState'
)
Add-CheckResult `
    -Name 'Reconcile-Executor ist statisch: keine Write-LabArtifactJsonAtomic/Set-Content/State-Mutationen im Funktionscode' `
    -Success ((@($forbiddenMutations | Where-Object { $testSource -match [regex]::Escape($_) }).Count -eq 0))

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("sql-lab-reconcile-action-" + [guid]::NewGuid().ToString('N'))

try {
    New-Item -ItemType Directory -Path $tempRoot | Out-Null
    $module = Get-Module SqlServerLab
    $testData = & $module {
        param($Root)
        $resolvedLab = [PSCustomObject]@{
            name = 'Reconcile action'
            instances = @(
                [PSCustomObject]@{ id = 'primary'; provider = 'docker'; version = '2019'; profile = 'standard'; databases = @([PSCustomObject]@{ name = 'master' }) }
                [PSCustomObject]@{ id = 'secondary'; provider = 'podman'; version = '2022'; profile = 'compact'; databases = @([PSCustomObject]@{ name = 'master' }) }
            )
        }

        $desiredState = New-LabDesiredStateSnapshot -ResolvedLab $resolvedLab -ProvisioningMode 'manifest' -PersistentData $false
        $run = New-LabRunState -StateRoot $Root -Metadata @{ name = 'Reconcile action'; desiredState = $desiredState } -ProviderSubRuns @(
            [PSCustomObject]@{ provider = 'docker'; instanceIds = @('primary') },
            [PSCustomObject]@{ provider = 'podman'; instanceIds = @('secondary') }
        )

        $connection = [PSCustomObject]@{
            instances = @(
                [PSCustomObject]@{
                    id = 'primary'; provider = 'docker'; host = '127.0.0.1'; port = 14330; containerId = 'container-secret-id'
                    connectionString = 'Password=not-in-plan'
                    databases = @([PSCustomObject]@{ name = 'master' }, [PSCustomObject]@{ name = 'app' })
                },
                [PSCustomObject]@{
                    id = 'secondary'; provider = 'podman'; host = '127.0.0.1'; port = 14331; containerId = 'container-secret-id-2'
                    connectionString = 'Password=not-in-plan'; databases = @([PSCustomObject]@{ name = 'master' }, [PSCustomObject]@{ name = 'analytics' })
                }
            )
        }
        $statePath = Join-Path $run.RunDir 'run-state.json'
        $connectionPath = Join-Path $run.RunDir 'connection-info.json'
        Write-LabArtifactJsonAtomic -Path $connectionPath -InputObject $connection

        return [PSCustomObject]@{
            RunId = $run.RunId
            StatePath = $statePath
            ConnectionPath = $connectionPath
            StateBefore = Get-Content -LiteralPath $statePath -Raw -Encoding utf8
            ConnectionBefore = Get-Content -LiteralPath $connectionPath -Raw -Encoding utf8
            StateRoot = $Root
        }
    } $tempRoot

    $contract = & $module {
        param($RunId, $StateRoot, $StateBefore, $ConnectionBefore)

        $originalRuntime = (Get-Command Get-LabRunRuntimeStatus).ScriptBlock
        $originalStart = (Get-Command Start-SqlServerLab).ScriptBlock
        $originalStop = (Get-Command Stop-SqlServerLab).ScriptBlock
        $originalPlan = (Get-Command Get-SqlServerLabReconcilePlan).ScriptBlock

        try {
            $script:reconcileRuntimeState = 'RUNNING'
            $script:startCalls = 0
            $script:stopCalls = 0
            $script:executorStateRoots = [System.Collections.Generic.List[string]]::new()
            Set-Item Function:Get-LabRunRuntimeStatus -Value {
                [PSCustomObject]@{
                    State = $script:reconcileRuntimeState
                    Source = 'mock'
                    Instances = @(
                        [PSCustomObject]@{ Id = 'primary'; Provider = 'docker'; State = $script:reconcileRuntimeState },
                        [PSCustomObject]@{ Id = 'secondary'; Provider = 'podman'; State = $script:reconcileRuntimeState }
                    )
                }
            }
            Set-Item Function:Start-SqlServerLab -Value {
                param([string]$RunId, [string]$StateRoot)
                $script:startCalls++
                $script:executorStateRoots.Add($StateRoot)
                [PSCustomObject]@{ RunId = $RunId; Status = 'RUNNING'; Action = 'STARTED' }
            }
            Set-Item Function:Stop-SqlServerLab -Value {
                param([string]$RunId, [string]$StateRoot, [switch]$Force)
                $script:stopCalls++
                $script:executorStateRoots.Add($StateRoot)
                [PSCustomObject]@{ RunId = $RunId; Status = 'STOPPED'; Action = 'STOPPED' }
            }

            $script:reconcileRuntimeState = 'RUNNING'
            $noOp = Invoke-SqlServerLabReconcileAction -RunId $RunId -TargetState RUNNING -StateRoot $StateRoot

            $script:reconcileRuntimeState = 'MISSING'
            $unsupported = Invoke-SqlServerLabReconcileAction -RunId $RunId -TargetState STOPPED -StateRoot $StateRoot

            $script:reconcileRuntimeState = 'STOPPED'
            $restart = Invoke-SqlServerLabReconcileAction -RunId $RunId -TargetState RUNNING -StateRoot $StateRoot

            $script:reconcileRuntimeState = 'RUNNING'
            $stop = Invoke-SqlServerLabReconcileAction -RunId $RunId -TargetState STOPPED -StateRoot $StateRoot

            $script:reconcileRuntimeState = 'STOPPED'
            $whatIf = Invoke-SqlServerLabReconcileAction -RunId $RunId -TargetState RUNNING -StateRoot $StateRoot -WhatIf

            Set-Item Function:Get-SqlServerLabReconcilePlan -Value {
                param([string]$RunId, [string]$TargetState, [string]$StateRoot)
                [PSCustomObject]@{
                    Contract = [PSCustomObject]@{ Name = 'SqlServerLab.ReconcilePlan'; Version = '1.0' }
                    RunId = $RunId
                    TargetState = $TargetState
                    Desired = [PSCustomObject]@{ Instances = @(
                        [PSCustomObject]@{ Id = 'primary'; Provider = 'docker'; TargetState = $TargetState },
                        [PSCustomObject]@{ Id = 'secondary'; Provider = 'podman'; TargetState = $TargetState }
                    ) }
                    Actual = [PSCustomObject]@{ State = 'STOPPED' }
                    Diff = @()
                    Actions = @(
                        [PSCustomObject]@{ Operation = 'Start'; Provider = 'docker'; TargetState = $TargetState },
                        [PSCustomObject]@{ Operation = 'Stop'; Provider = 'podman'; TargetState = $TargetState }
                    )
                    HighestChangeClass = 'restart'
                    IsNoOp = $false
                    MutationAllowed = $false
                    Warnings = @('mixed operations')
                }
            }
            $mixed = Invoke-SqlServerLabReconcileAction -RunId $RunId -TargetState RUNNING -StateRoot $StateRoot

            return [PSCustomObject]@{
                NoOp = $noOp
                Unsupported = $unsupported
                Restart = $restart
                Stop = $stop
                WhatIf = $whatIf
                Mixed = $mixed
                StartCalls = $script:startCalls
                StopCalls = $script:stopCalls
                ExecutorStateRoots = @($script:executorStateRoots)
                StateBefore = $StateBefore
                ConnectionBefore = $ConnectionBefore
                StatePath = Join-Path $StateRoot 'runs' $RunId 'run-state.json'
                ConnectionPath = Join-Path $StateRoot 'runs' $RunId 'connection-info.json'
            }
        }
        finally {
            Set-Item Function:Get-LabRunRuntimeStatus -Value $originalRuntime
            Set-Item Function:Start-SqlServerLab -Value $originalStart
            Set-Item Function:Stop-SqlServerLab -Value $originalStop
            Set-Item Function:Get-SqlServerLabReconcilePlan -Value $originalPlan
        }
    } $testData.RunId $testData.StateRoot $testData.StateBefore $testData.ConnectionBefore

    Add-CheckResult `
        -Name 'No-op-Plan bleibt ohne Mutation' `
        -Success ($contract.NoOp.Contract.Name -eq 'SqlServerLab.ReconcileAction' -and $contract.NoOp.ExecutionSummary.Status -eq 'NO_OP' -and $contract.NoOp.MutationAllowed -eq $false -and $contract.NoOp.ExecutionSummary.ExecutedActions -eq 0)
    Add-CheckResult `
        -Name 'Unsupported-Plan bleibt ohne Mutation' `
        -Success ($contract.Unsupported.ExecutionSummary.Status -eq 'UNSUPPORTED' -and $contract.Unsupported.MutationAllowed -eq $false -and $contract.Unsupported.ExecutionSummary.ExecutedActions -eq 0)
    Add-CheckResult `
        -Name 'Reconcile-Executor ruft Start und Stop genau einmal auf' `
        -Success ($contract.Restart.MutationAllowed -eq $true -and $contract.Restart.ExecutionSummary.Status -eq 'SUCCEEDED' -and $contract.Stop.MutationAllowed -eq $true -and $contract.Stop.ExecutionSummary.Status -eq 'SUCCEEDED' -and $contract.StartCalls -eq 1 -and $contract.StopCalls -eq 1)
    Add-CheckResult `
        -Name 'Reconcile-Executor reicht den angeforderten StateRoot an Start und Stop weiter' `
        -Success ($contract.ExecutorStateRoots.Count -eq 2 -and @($contract.ExecutorStateRoots | Where-Object { $_ -ne $testData.StateRoot }).Count -eq 0)
    Add-CheckResult `
        -Name 'WhatIf verhindert Laufzeitmutation' `
        -Success ($contract.WhatIf.MutationAllowed -eq $false -and $contract.WhatIf.ExecutionSummary.ExecutedActions -eq 0 -and $contract.WhatIf.ExecutionSummary.Status -eq 'WOULD_EXECUTE')
    Add-CheckResult `
        -Name 'Gemischte Reconcile-Operationen werden als unsupported klassifiziert' `
        -Success ($contract.Mixed.ExecutionSummary.Status -eq 'UNSUPPORTED' -and $contract.Mixed.MutationAllowed -eq $false -and $contract.StartCalls -eq 1 -and $contract.StopCalls -eq 1)

    $leakPayload = @($contract.NoOp, $contract.Unsupported, $contract.Restart, $contract.Stop, $contract.WhatIf, $contract.Mixed) | ConvertTo-Json -Depth 20

    Add-CheckResult `
        -Name 'Reconcile-Action-Vertrag leakt keine Geheimnisse oder Host-Infos' `
        -Success (($leakPayload -notmatch 'not-in-plan|container-secret-id|127\\.0\\.0\\.1|\"host\"\\s*:|\"port\"\\s*:|connectionString|containerId|Password='))

    Add-CheckResult `
        -Name 'Reconcile-Action ändert Run-/Connection-JSON nicht' `
        -Success (`
            (Get-Content -LiteralPath $contract.StatePath -Raw -Encoding utf8) -eq $contract.StateBefore -and
            (Get-Content -LiteralPath $contract.ConnectionPath -Raw -Encoding utf8) -eq $contract.ConnectionBefore
        )
}
finally {
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}

if ($failures.Count -gt 0) {
    Write-Host "`nErgebnis: $passed PASS, $($failures.Count) FAIL" -ForegroundColor Red
    foreach ($failure in $failures) { Write-Host "  - $failure" -ForegroundColor Red }
    exit 1
}

Write-Host "`nErgebnis: $passed PASS, 0 FAIL" -ForegroundColor Green
exit 0
