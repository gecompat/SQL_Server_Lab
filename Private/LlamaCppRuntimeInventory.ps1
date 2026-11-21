function Get-LabLlamaCppRuntimeInventory {
    [CmdletBinding()]
    param()

    $warnings = @()
    $candidates = @(Get-SqlServerLabLlamaCppRuntime -WarningAction SilentlyContinue -WarningVariable warnings -ErrorAction Stop)
    $backends = @('Unknown', 'Ambiguous', 'LlamaCppCuda', 'LlamaCppOpenVino', 'LlamaCppRocm', 'LlamaCppVulkan', 'LlamaCppSycl')
    $items = foreach ($candidate in $candidates) {
        if ($candidate.EvidenceStatus -cne 'FILES_ONLY' -or $candidate.Backend -cnotin $backends) {
            throw 'LLAMA_RUNTIME_INVENTORY_INVALID'
        }
        [pscustomobject]@{
            Backend = $candidate.Backend
            Build = if ($null -ne $candidate.Build) { ([long]$candidate.Build).ToString([Globalization.CultureInfo]::InvariantCulture) } else { $null }
        }
    }
    [pscustomobject]@{
        EvidenceStatus = 'FILES_ONLY'
        ScanStatus = if ($warnings.Count) { 'PARTIAL' } else { 'COMPLETED' }
        Items = @($items | Where-Object { $null -ne $_ })
    }
}

function Show-LabLlamaCppRuntimeInventoryInteractive {
    Write-LabInfo 'Suche im konfigurierten llama.cpp-Verzeichnis und beim ersten Programmfund im Prozess-PATH. Nur Paketdateien werden geprüft.'
    try {
        $inventory = Get-LabLlamaCppRuntimeInventory
        if ($inventory.ScanStatus -ceq 'PARTIAL') {
            Write-LabWarning 'Mindestens ein Suchverzeichnis war nicht lesbar. Die Trefferliste ist unvollständig.'
        }
        if ($inventory.Items.Count -eq 0) {
            Write-LabInfo 'Keine Paketdateien in den geprüften Suchverzeichnissen gefunden.'
        }
        foreach ($item in $inventory.Items) {
            $build = if ($null -eq $item.Build) { 'unbekannt' } else { $item.Build }
            Write-LabInfo ('Backend {0} · Build {1}' -f $item.Backend, $build)
        }
        Write-LabInfo 'Paketursprung, Geräteverfügbarkeit und SQL-Embedding-Bereitschaft bleiben ungeprüft.'
    }
    catch { Write-LabError 'llama.cpp-Paketübersicht nicht verfügbar. Konfigurierte Suchverzeichnisse und Suchgrenzen prüfen.' }
    $null = Wait-LabConsoleAcknowledgement
}

function Invoke-LabLlamaCppRuntimeInventoryHttpRequest {
    param([Parameter(Mandatory)]$Request)

    if ($Request.HttpMethod -cne 'GET' -or $Request.Url.Query -or $Request.HasEntityBody) {
        throw 'LLAMA_RUNTIME_INVENTORY_REQUEST_INVALID'
    }
    Get-LabLlamaCppRuntimeInventory
}
