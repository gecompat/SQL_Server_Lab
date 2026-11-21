function Invoke-LabHyperVAutoStartBrowser {
    param([Parameter(Mandatory)][hashtable]$Store,[Parameter(Mandatory)][string]$Json)
    $document = [Text.Json.JsonDocument]::Parse($Json)
    try {
        $payload = $document.RootElement
        if ($payload.ValueKind -ne [Text.Json.JsonValueKind]::Object -or
            $payload.GetProperty('Action').ValueKind -ne [Text.Json.JsonValueKind]::String) {
            throw 'HYPERV_AUTOSTART_BROWSER_INVALID'
        }
        $action = $payload.GetProperty('Action').GetString()
        $names = @(@($payload.EnumerateObject()).Name | Sort-Object) -join ','
        if ($action -ceq 'Plan' -and $names -ceq 'Action,AutoStart,RunId' -and
            $payload.GetProperty('RunId').ValueKind -eq [Text.Json.JsonValueKind]::String -and
            $payload.GetProperty('AutoStart').ValueKind -eq [Text.Json.JsonValueKind]::String) {
            $runId = $payload.GetProperty('RunId').GetString()
            $desired = $payload.GetProperty('AutoStart').GetString()
            if (-not (Test-LabDiagnosticGuid $runId) -or $desired -cnotin @('on', 'off')) { throw 'HYPERV_AUTOSTART_BROWSER_INVALID' }
        }
        elseif ($action -ceq 'PlanRecovery' -and $names -ceq 'Action,RunId' -and
            $payload.GetProperty('RunId').ValueKind -eq [Text.Json.JsonValueKind]::String) {
            $runId = $payload.GetProperty('RunId').GetString()
            if (-not (Test-LabDiagnosticGuid $runId)) { throw 'HYPERV_AUTOSTART_BROWSER_INVALID' }
        }
        elseif ($action -ceq 'Apply' -and $names -ceq 'Action,Confirmed,Selection' -and
            $payload.GetProperty('Confirmed').ValueKind -eq [Text.Json.JsonValueKind]::True -and
            $payload.GetProperty('Selection').ValueKind -eq [Text.Json.JsonValueKind]::String) {
            $selection = $payload.GetProperty('Selection').GetString()
        }
        else { throw 'HYPERV_AUTOSTART_BROWSER_INVALID' }
    }
    finally { $document.Dispose() }

    if ($action -ceq 'Plan') {
        $Store.Clear()
        $plan = Get-SqlServerLabHyperVAutoStartPlan -RunId $runId -AutoStart $desired -ErrorAction Stop
        if ($plan.Provider -cne 'hyperv' -or $plan.RunId -cne $runId -or
            $plan.Actual.AutoStart -cnotin @('ON', 'OFF') -or $plan.Desired.AutoStart -cne $desired.ToUpperInvariant() -or
            $plan.NoChange -isnot [bool] -or $plan.PlanKey -cnotmatch '^[a-f0-9]{64}$') {
            throw 'HYPERV_AUTOSTART_BROWSER_PLAN_INVALID'
        }
        $token = $null
        if (-not $plan.NoChange) {
            $token = [guid]::NewGuid().ToString('N')
            $Store.Plan = @{
                Token = $token; RunId = $runId; Desired = $desired; PlanKey = $plan.PlanKey
                Expires = [DateTime]::UtcNow.AddMinutes(5)
            }
        }
        return [pscustomobject]@{ Current = $plan.Actual.AutoStart; Desired = $plan.Desired.AutoStart; NoChange = $plan.NoChange; Selection = $token }
    }

    if ($action -ceq 'PlanRecovery') {
        $Store.Clear()
        $recovery = Get-LabHyperVAutoStartRecoveryPlan -RunId $runId
        $token = [guid]::NewGuid().ToString('N')
        $Store.Plan = @{
            Token = $token; RunId = $runId; RecoveryOperationId = $recovery.Journal.OperationId
            StateRoot = $recovery.Plan.Lab.StateRoot; Expires = [DateTime]::UtcNow.AddMinutes(5)
        }
        return [pscustomobject]@{ Desired = $recovery.Journal.Target.AutoStart.ToUpperInvariant(); Selection = $token }
    }

    $approved = $Store.Plan
    if (-not $approved -or $selection -cne $approved.Token -or $approved.Expires -le [DateTime]::UtcNow) {
        throw 'HYPERV_AUTOSTART_BROWSER_APPROVAL_INVALID'
    }
    $Store.Clear()
    $result = if ($approved.RecoveryOperationId) {
        Resume-SqlServerLabHyperVAutoStart -RunId $approved.RunId -StateRoot $approved.StateRoot -ExpectedRecoveryOperationId $approved.RecoveryOperationId -Confirm:$false -ErrorAction Stop
    } else {
        Set-SqlServerLabHyperVAutoStart -RunId $approved.RunId -AutoStart $approved.Desired -ExpectedAutoStartPlanKey $approved.PlanKey -Confirm:$false -ErrorAction Stop
    }
    if ($result.Status -cnotin @('NO_OP', 'SUCCEEDED', 'RECOVERY_SUCCEEDED')) { throw 'HYPERV_AUTOSTART_BROWSER_RESULT_INVALID' }
    [pscustomobject]@{ Status = $result.Status }
}
