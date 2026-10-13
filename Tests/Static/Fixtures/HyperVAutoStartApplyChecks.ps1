#Requires -Version 7.2
[CmdletBinding()]
param([Parameter(Mandatory)][System.Management.Automation.PSModuleInfo]$Module)

$ErrorActionPreference = 'Stop'

& $Module {
    $runId = [guid]::NewGuid().ToString('D')
    $scopeId = [guid]::NewGuid().ToString('D')
    $desiredInstance = [pscustomobject]@{ Id = 'primary'; Provider = 'hyperv'; AutoStart = 'off' }
    $run = [pscustomobject]@{
        runId = $runId; scopeId = $scopeId; state = 'STOPPED'; updatedAt = $null
        metadata = [pscustomobject]@{
            autostart = 'off'
            desiredState = [pscustomobject]@{ Instances = @($desiredInstance) }
        }
    }
    $connection = [pscustomobject]@{
        instances = @([pscustomobject]@{ id = 'primary'; provider = 'hyperv'; vmName = 'synthetic-hyperv'; vmId = 'vm-guid'; autostart = 'off' })
    }
    $script:autostartVm = [pscustomobject]@{ Id = 'vm-guid'; State = 'Off'; AutomaticStartAction = 'Nothing' }
    $script:autostartSetCalls = 0
    $script:autostartWrites = @()
    $script:autostartJournal = $null
    $syntheticRunDirectory = Join-Path ([IO.Path]::GetTempPath()) ("sql-lab-hyperv-autostart-synthetic-$([guid]::NewGuid().ToString('N'))")
    $null = New-Item -ItemType Directory -Path $syntheticRunDirectory -Force

    function Assert-LabWindowsPoolMutationAllowed { param($RunId,$StateRoot,[switch]$InvalidateEvidence) }
    function Assert-LabResourceChangeAllowed { param($RunId,$StateRoot) }
    function Assert-LabHyperVResourceMigrationLifecycleAllowed { param($RunId,$Operation,$StateRoot) }
    function Get-HyperVLabWorkflowRun {
        param($RunId,$StateRoot)
        [pscustomobject]@{
            Run = $run; RunDirectory = $syntheticRunDirectory; Connection = $connection
            Instance = $connection.instances[0]; StateRoot = ([IO.Path]::GetTempPath())
        }
    }
    function Get-HyperVManagedVM {
        param($VMName,$ExpectedRunId,$ExpectedScopeId)
        [pscustomobject]@{ VM = $script:autostartVm }
    }
    function Set-VM {
        param($VM,$AutomaticStartAction)
        $script:autostartSetCalls++
        $VM.AutomaticStartAction = $AutomaticStartAction
    }
    function Get-LabTimestamp { '2026-10-10T00:00:00.0000000Z' }
    function Write-LabArtifactJsonAtomic {
        param($Path,$InputObject)
        $script:autostartWrites += [string]$Path
        if ($Path -like '*hyperv-autostart-journal.json') {
            $script:autostartJournal = $InputObject | ConvertTo-Json -Depth 30 | ConvertFrom-Json -Depth 30
            $InputObject | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $Path -Encoding utf8
        }
        elseif ($script:failConnectionWrite -and $Path -like '*connection-info.json') {
            $script:failConnectionWrite = $false
            throw 'SYNTHETIC_STATE_COMMIT_FAILURE'
        }
    }

    $plan = Get-SqlServerLabHyperVAutoStartPlan -RunId $runId -AutoStart on -StateRoot ([IO.Path]::GetTempPath())
    if ($plan.Contract.Name -ne 'SqlServerLab.HyperVAutoStartPlan' -or $plan.NoChange -or $plan.ChangeClass -ne 'live' -or
        $plan.Actual.AutoStart -ne 'OFF' -or $plan.Desired.AutoStart -ne 'ON' -or $plan.PlanKey -notmatch '^[a-f0-9]{64}$' -or
        ($plan | ConvertTo-Json -Depth 10) -match 'vm-guid') { throw 'HYPERV_AUTOSTART_PLAN_BINDING' }
    $result = Set-SqlServerLabHyperVAutoStart -RunId $runId -AutoStart on -ExpectedAutoStartPlanKey $plan.PlanKey -StateRoot ([IO.Path]::GetTempPath()) -Confirm:$false
    $success = $result.Status -eq 'SUCCEEDED' -and $result.AutoStart -eq 'on' -and
        $script:autostartSetCalls -eq 1 -and $script:autostartVm.Id -eq 'vm-guid' -and
        $script:autostartVm.State -eq 'Off' -and $script:autostartVm.AutomaticStartAction -eq 'Start' -and
        $connection.instances[0].autostart -eq 'on' -and $run.metadata.autostart -eq 'on' -and
        $desiredInstance.AutoStart -eq 'on' -and $script:autostartWrites.Count -eq 6 -and
        $script:autostartJournal.Status -eq 'COMPLETED' -and $script:autostartJournal.Runtime.VMId -eq 'vm-guid'
    $script:autostartVm.AutomaticStartAction = 'Nothing'
    $connection.instances[0].autostart = 'off'; $run.metadata.autostart = 'off'; $desiredInstance.AutoStart = 'off'
    $script:failConnectionWrite = $true
    $recoveryPlan = Get-SqlServerLabHyperVAutoStartPlan -RunId $runId -AutoStart on -StateRoot ([IO.Path]::GetTempPath())
    $recoveryFailed = $false
    try { $null = Set-SqlServerLabHyperVAutoStart -RunId $runId -AutoStart on -ExpectedAutoStartPlanKey $recoveryPlan.PlanKey -StateRoot ([IO.Path]::GetTempPath()) -Confirm:$false }
    catch { $recoveryFailed = $_.Exception.Message -match 'SYNTHETIC_STATE_COMMIT_FAILURE' }
    $setCallsBeforeResume = $script:autostartSetCalls
    $recovered = Resume-SqlServerLabHyperVAutoStart -RunId $runId -StateRoot ([IO.Path]::GetTempPath()) -Confirm:$false
    $recoverySuccess = $recoveryFailed -and $script:autostartJournal.Status -eq 'COMPLETED' -and
        $recovered.Status -eq 'RECOVERY_SUCCEEDED' -and $script:autostartSetCalls -eq $setCallsBeforeResume -and
        $connection.instances[0].autostart -eq 'on' -and $desiredInstance.AutoStart -eq 'on'
    Remove-Item -LiteralPath $syntheticRunDirectory -Recurse -Force -ErrorAction SilentlyContinue
    [pscustomobject]@{ Success = ($success -and $recoverySuccess) }
}
