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

function Get-LabAiRuntimeCapabilityView {
    $inventory = Get-SqlServerLabAiComputeInventory -WarningAction SilentlyContinue -ErrorAction Stop
    if ($inventory.Status -cne 'COMPLETE') {
        return [pscustomobject]@{ Status = 'INVENTORY_INCOMPLETE'; Items = @() }
    }

    $warnings = @()
    $packages = @(Get-SqlServerLabLlamaCppRuntime -WarningAction SilentlyContinue -WarningVariable warnings -ErrorAction Stop)
    if ($warnings.Count -or $packages.Count -gt 16) {
        return [pscustomobject]@{ Status = 'PACKAGE_SCAN_INCOMPLETE'; Items = @() }
    }
    if ($packages.Count -eq 0) {
        return [pscustomobject]@{ Status = 'NO_PACKAGES'; Items = @() }
    }

    $capability = Get-SqlServerLabAiRuntimeCapability -Inventory $inventory -Runtime $packages -ErrorAction Stop
    if ($capability.EvidenceStatus -cne 'FILES_HASHED_NOT_EXECUTED') {
        throw 'AI_RUNTIME_CAPABILITY_VIEW_INVALID'
    }
    $combinationCounts = @{}
    $combinationsAvailable = $capability.Capabilities.Count -le 16
    if ($combinationsAvailable) {
        try {
            $candidateSet = Get-SqlServerLabAiComputeCandidate -Inventory $inventory -RuntimeCapability $capability.Capabilities -ErrorAction Stop
            foreach ($candidate in $candidateSet.Candidates) {
                $key = $candidate.Backend + '/' + $candidate.Devices[0].Kind
                $combinationCounts[$key]++
            }
        }
        catch {
            if ($_.Exception.Message -cne 'AI_COMPUTE_CANDIDATE_SET_TOO_LARGE') { throw }
            $combinationsAvailable = $false
        }
    }

    $items = foreach ($group in $capability.Capabilities | Group-Object Backend, { $_.DeviceKinds[0] }) {
        $row = $group.Group[0]
        [pscustomobject]@{
            Backend = $row.Backend
            Kind = $row.DeviceKinds[0]
            Eligible = @($group.Group | Where-Object Eligible).Count -gt 0
            CombinationCount = if ($combinationsAvailable) { [int]$combinationCounts[$row.Backend + '/' + $row.DeviceKinds[0]] } else { $null }
        }
    }
    [pscustomobject]@{ Status = 'FILES_HASHED_NOT_EXECUTED'; Items = @($items) }
}

function Show-LabAiRuntimeCapabilityInteractive {
    try {
        $view = Get-LabAiRuntimeCapabilityView
        switch ($view.Status) {
            INVENTORY_INCOMPLETE { Write-LabInfo 'Die Geräteinventur ist unvollständig. Die Eignung kann nicht ermittelt werden.' }
            PACKAGE_SCAN_INCOMPLETE { Write-LabInfo 'Die Paketsuche ist unvollständig oder hat mehr als 16 Kandidaten. Die Eignung kann nicht ermittelt werden.' }
            NO_PACKAGES { Write-LabInfo 'Keine llama.cpp-Pakete gefunden. Prüfe die Paketübersicht im selben Menü.' }
            FILES_HASHED_NOT_EXECUTED {
                foreach ($row in $view.Items) {
                    $result = if ($row.Eligible) { 'passendes Gerät gefunden' } else { 'kein passendes Gerät gefunden' }
                    $combinations = if ($null -eq $row.CombinationCount) { 'Prüfgrenze der Gerätekombinationen erreicht' }
                                    else { '{0} Gerätekombinationen' -f $row.CombinationCount }
                    Write-LabInfo ('{0} · {1} · {2} · {3}' -f $row.Backend, $row.Kind, $result, $combinations)
                }
                Write-LabInfo 'Paketdateien wurden geprüft. Es wurde keine Runtime ausgeführt.'
            }
        }
    }
    catch { Write-LabError 'Die Runtime-Eignung kann nicht ermittelt werden.' }
    $null = Wait-LabConsoleAcknowledgement
}
