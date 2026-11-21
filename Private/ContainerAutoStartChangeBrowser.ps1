function Read-LabContainerAutoStartChangeBrowser {
    param([Parameter(Mandatory)][hashtable]$Store)

    $Store.Clear()
    $root = Get-LabDataRootDefault
    $targets = @(if ($root) { Get-LabContainerPortConsoleTargets -DataRoot $root })
    if ($targets.Count -gt 4096) { throw 'AUTOSTART_CHANGE_BROWSER_SCOPE_INVALID' }
    $Store.Root = $root
    $Store.Targets = @{}
    $Store.Expires = [DateTime]::UtcNow.AddMinutes(5)
    $items = @(foreach ($target in $targets) {
        $selection = [guid]::NewGuid().ToString('N')
        $Store.Targets.Add($selection, $target)
        [pscustomobject]@{
            Selection = $selection
            RunId = $target.RunId
            InstanceId = $target.InstanceId
            Provider = $target.Provider
        }
    })
    [pscustomobject]@{ Items = $items }
}

function Invoke-LabContainerAutoStartChangeBrowser {
    param(
        [Parameter(Mandatory)][hashtable]$Store,
        [Parameter(Mandatory)][string]$Body
    )

    $document = [Text.Json.JsonDocument]::Parse($Body)
    try {
        $payload = $document.RootElement
        if ($payload.ValueKind -ne [Text.Json.JsonValueKind]::Object -or
            $payload.GetProperty('Action').ValueKind -ne [Text.Json.JsonValueKind]::String -or
            $payload.GetProperty('Selection').ValueKind -ne [Text.Json.JsonValueKind]::String) {
            throw 'AUTOSTART_CHANGE_BROWSER_REQUEST_INVALID'
        }
        $action = $payload.GetProperty('Action').GetString()
        $selection = $payload.GetProperty('Selection').GetString()
        $names = @(@($payload.EnumerateObject()).Name | Sort-Object) -join ','
        if ($selection -cnotmatch '\A[a-f0-9]{32}\z') { throw 'AUTOSTART_CHANGE_BROWSER_SELECTION_INVALID' }
        if ($action -ceq 'Plan' -and $names -ceq 'Action,AutoStart,Selection' -and
            $payload.GetProperty('AutoStart').ValueKind -eq [Text.Json.JsonValueKind]::String) {
            $desired = $payload.GetProperty('AutoStart').GetString()
            if ($desired -cnotin @('on', 'off')) { throw 'AUTOSTART_CHANGE_BROWSER_POLICY_INVALID' }
        }
        elseif ($action -cne 'Apply' -or $names -cne 'Action,Confirmed,Selection' -or
            $payload.GetProperty('Confirmed').ValueKind -ne [Text.Json.JsonValueKind]::True) {
            throw 'AUTOSTART_CHANGE_BROWSER_CONFIRMATION_REQUIRED'
        }
    }
    finally { $document.Dispose() }

    if ($action -ceq 'Plan') { $Store.Remove('Plan') }
    $root = Get-LabDataRootDefault
    if (-not $root -or $Store.Root -cne $root -or -not $Store.Expires -or
        $Store.Expires -le [DateTime]::UtcNow) {
        $Store.Clear()
        throw 'AUTOSTART_CHANGE_BROWSER_SELECTION_EXPIRED'
    }

    if ($action -ceq 'Apply') {
        $approved = $Store.Plan
        if (-not $approved -or $approved.Selection -cne $selection) {
            throw 'AUTOSTART_CHANGE_BROWSER_PLAN_INVALID'
        }
        $Store.Clear()
        Invoke-LabConfirmedContainerAutoStartChange -Target $approved.Target -AutoStart $approved.AutoStart -PlanKey $approved.PlanKey
        return
    }

    if (-not $Store.Targets.ContainsKey($selection)) { throw 'AUTOSTART_CHANGE_BROWSER_SELECTION_INVALID' }
    $target = $Store.Targets[$selection]
    $current = @(Get-LabContainerPortConsoleTargets -DataRoot $root | Where-Object {
        $_.RunId -ceq $target.RunId -and $_.ScopeId -ceq $target.ScopeId -and
        $_.InstanceId -ceq $target.InstanceId -and $_.Provider -ceq $target.Provider -and
        $_.StateRoot -ceq $target.StateRoot
    })
    if ($current.Count -ne 1) { throw 'AUTOSTART_CHANGE_BROWSER_SELECTION_CHANGED' }
    $plan = Get-SqlServerLabContainerAutoStartPlan -RunId $target.RunId -InstanceId $target.InstanceId -StateRoot $target.StateRoot -AutoStart $desired
    Assert-LabContainerAutoStartPlanConsoleContract -Plan $plan -RunId $target.RunId -InstanceId $target.InstanceId -Provider $target.Provider -AutoStart $desired
    $confirmation = if (-not $plan.NoChange) {
        $token = [guid]::NewGuid().ToString('N')
        $Store.Plan = @{ Selection = $token; Target = $target; PlanKey = $plan.PlanKey; AutoStart = $desired }
        $token
    } else { $null }
    [pscustomobject]@{
        Selection = $confirmation
        Current = $plan.Actual.AutoStart
        Desired = $plan.Desired.AutoStart
        NoChange = $plan.NoChange
    }
}
