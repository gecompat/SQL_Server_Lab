function Read-LabContainerAutoStartRecoveryBrowser {
    param([Parameter(Mandatory)][hashtable]$Selections)

    $Selections.Clear()
    $root = Get-LabDataRootDefault
    $targets = @(if ($root) { Get-LabContainerAutoStartRecoveryTargets -DataRoot $root })
    if ($targets.Count -gt 64) { throw 'AUTOSTART_RECOVERY_BROWSER_SCOPE_INVALID' }
    $expires = [DateTime]::UtcNow.AddMinutes(5)
    $rows = @(foreach ($target in $targets) {
        $token = [guid]::NewGuid().ToString('N')
        $Selections.Add($token, @{ Target = $target; Expires = $expires })
        [pscustomobject]@{
            Selection = $token
            RunId = $target.RunId
            InstanceId = $target.InstanceId
            Provider = $target.Provider
            TargetAutoStart = $target.TargetAutoStart
        }
    })
    [pscustomobject]@{ Items = $rows }
}

function Invoke-LabContainerAutoStartRecoveryBrowser {
    param(
        [Parameter(Mandatory)][hashtable]$Selections,
        [Parameter(Mandatory)][string]$Body
    )

    $document = [Text.Json.JsonDocument]::Parse($Body)
    try {
        $payload = $document.RootElement
        if ($payload.ValueKind -ne [Text.Json.JsonValueKind]::Object -or
            (@(@($payload.EnumerateObject()).Name | Sort-Object) -join ',') -cne 'Confirmed,Selection' -or
            $payload.GetProperty('Confirmed').ValueKind -ne [Text.Json.JsonValueKind]::True -or
            $payload.GetProperty('Selection').ValueKind -ne [Text.Json.JsonValueKind]::String) {
            throw 'AUTOSTART_RECOVERY_BROWSER_CONFIRMATION_REQUIRED'
        }
        $token = $payload.GetProperty('Selection').GetString()
    }
    finally { $document.Dispose() }
    if ($token -cnotmatch '\A[a-f0-9]{32}\z' -or -not $Selections.ContainsKey($token)) {
        throw 'AUTOSTART_RECOVERY_BROWSER_SELECTION_INVALID'
    }

    $selection = $Selections[$token]
    $Selections.Clear()
    if ($selection.Expires -le [DateTime]::UtcNow) { throw 'AUTOSTART_RECOVERY_BROWSER_SELECTION_EXPIRED' }
    $target = $selection.Target
    $root = Get-LabDataRootDefault
    $current = @(if ($root) {
        Get-LabContainerAutoStartRecoveryTargets -DataRoot $root | Where-Object {
            $_.RunId -ceq $target.RunId -and $_.InstanceId -ceq $target.InstanceId -and
            $_.ScopeId -ceq $target.ScopeId -and $_.Provider -ceq $target.Provider -and
            $_.StateRoot -ceq $target.StateRoot -and $_.OperationId -ceq $target.OperationId -and
            $_.TargetAutoStart -ceq $target.TargetAutoStart
        }
    })
    if ($current.Count -ne 1) { throw 'AUTOSTART_RECOVERY_BROWSER_SELECTION_CHANGED' }
    Invoke-LabConfirmedContainerAutoStartRecovery -Target $current[0]
}
