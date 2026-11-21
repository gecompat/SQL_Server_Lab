function ConvertTo-LabAiComputeInventoryView {
    param([Parameter(Mandatory)]$Inventory)

    $kinds = @('CPU', 'GPU', 'NPU')
    if ($Inventory.Contract -cne 'SqlServerLab.AiComputeInventory/1.0' -or
        $Inventory.Status -cnotin @('COMPLETE', 'INCOMPLETE') -or
        $Inventory.Platform -cnotin @('Windows', 'Linux', 'Unsupported') -or
        $Inventory.Coverage -isnot [array] -or $Inventory.Coverage.Count -ne $kinds.Count -or
        $Inventory.Devices -isnot [array] -or @($Inventory.Devices | Where-Object { $_.Kind -cnotin $kinds }).Count) {
        throw 'AI_COMPUTE_INVENTORY_VIEW_INVALID'
    }
    $rows = @(foreach ($kind in $kinds) {
        $coverage = @($Inventory.Coverage | Where-Object Kind -CEQ $kind)
        $count = @($Inventory.Devices | Where-Object Kind -CEQ $kind).Count
        if ($coverage.Count -ne 1 -or $coverage[0].Status -cnotin @('VERIFIED', 'UNAVAILABLE') -or
            ($coverage[0].Status -ceq 'UNAVAILABLE' -and ($count -or $Inventory.Status -ceq 'COMPLETE'))) {
            throw 'AI_COMPUTE_INVENTORY_VIEW_INVALID'
        }
        [pscustomobject]@{
            Kind = $kind
            Count = if ($coverage[0].Status -ceq 'VERIFIED') { $count } else { $null }
        }
    })
    if ($Inventory.Status -ceq 'COMPLETE' -and $rows[0].Count -lt 1) {
        throw 'AI_COMPUTE_INVENTORY_VIEW_INVALID'
    }
    [pscustomobject]@{ Status = $Inventory.Status; Platform = $Inventory.Platform; Items = $rows }
}

function Get-LabAiComputeInventoryView {
    $inventory = Get-SqlServerLabAiComputeInventory -WarningAction SilentlyContinue -ErrorAction Stop
    ConvertTo-LabAiComputeInventoryView -Inventory $inventory
}

function Show-LabAiComputeInventoryInteractive {
    try {
        $view = Get-LabAiComputeInventoryView
        $coverage = if ($view.Status -ceq 'COMPLETE') { 'vollständig' } else { 'unvollständig' }
        Write-LabInfo ('Geräteinventur · {0} · Erfassung {1}' -f $view.Platform, $coverage)
        foreach ($row in $view.Items) {
            $count = if ($null -eq $row.Count) { 'unbekannt' } else { $row.Count }
            Write-LabInfo ('{0}: {1}' -f $row.Kind, $count)
        }
        Write-LabInfo 'Runtime-Eignung und Leistung werden separat geprüft.'
    }
    catch { Write-LabError 'Die Geräteinventur ist nicht verfügbar.' }
    $null = Wait-LabConsoleAcknowledgement
}
