function Get-LabSsmsRegistrationDownload {
    $catalog = Get-SqlServerLabConnectionCenter -StoredOnly
    if ($catalog.Entries.Count -gt 500) { throw 'SSMS_REGISTRATION_LIMIT_EXCEEDED' }
    $document = (New-LabSsmsRegistrationLines -ConnectionCenter $catalog) -join [Environment]::NewLine
    if ([Text.Encoding]::UTF8.GetByteCount($document) -gt 2097152) { throw 'SSMS_REGISTRATION_LIMIT_EXCEEDED' }
    return $document
}

function Get-LabStoredConnectionCenterView {
    $inventory = Get-SqlServerLabConnectionCenter -StoredOnly
    $entries = [Collections.Generic.List[object]]::new()
    $skipped = 0
    $limit = 200
    $more = $false
    foreach ($entry in $inventory.Entries) {
        $provider = [string]$entry.Provider
        $state = [string]$entry.RuntimeState
        $name = [string]$entry.DisplayName
        $server = [string]$entry.Server
        $port = [regex]::Match($server, ',([0-9]{1,5})\z')
        $portNumber = if ($port.Success) { [int]$port.Groups[1].Value } else { $null }
        # Only project an address, never the connection string or its options.
        if ($server.Length -gt 300 -or $server -cnotmatch '\A(?:tcp:)?(?:[A-Za-z0-9_.-]+|\[[0-9a-fA-F:]+\]|[0-9a-fA-F]*:[0-9a-fA-F:]+)(?:\\[A-Za-z0-9_.-]+)?(?:,[0-9]{1,5})?\z' -or
            ($port.Success -and ($portNumber -lt 1 -or $portNumber -gt 65535)) -or
            [string]::IsNullOrWhiteSpace($name) -or $name.Length -gt 256 -or $name -match '[\x00-\x1f\x7f]' -or
            $provider -cnotin @('docker','podman','hyperv','unknown') -or $state -cnotin @('RUNNING','STOPPED','UNKNOWN')) {
            $skipped++
            continue
        }
        if ($entries.Count -ge $limit) {
            $more = $true
            continue
        }
        $entries.Add([pscustomobject]@{DisplayName=$name;Provider=$provider;Server=$server;StoredState=$state})
    }
    [pscustomobject]@{
        ContractVersion='SqlServerLab.StoredConnectionCenter/1.0'
        Entries=$entries.ToArray()
        SkippedCount=$skipped
        MoreAvailable=$more
    }
}

function Show-LabStoredConnectionCenterInteractive {
    try {
        $view = Get-LabStoredConnectionCenterView
        $subtitle = '{0} Endpunkte · {1} ausgelassen · gespeicherter Zustand' -f $view.Entries.Count,$view.SkippedCount
        if ($view.MoreAvailable) { $subtitle += ' · Anzeige auf 200 gültige Einträge begrenzt' }
        $items = @(for ($index=0; $index -lt $view.Entries.Count; $index++) {
            $entry = $view.Entries[$index]
            New-LabConsoleItem -Id ("endpoint-$index") -Label $entry.DisplayName -Value ("{0} · {1}" -f $entry.Provider,$entry.StoredState) -Data $entry
        })
        $items += New-LabConsoleItem -Id back -Label 'Zurück' -Shortcut 0
        $choice = Invoke-LabConsoleMenu -ScreenId 'stored-connection-center' -Title 'Gespeicherte SQL-Endpunkte' -Subtitle $subtitle -Items $items
        if ($choice.Status -cne 'Selected' -or $choice.SelectedItem.Id -ceq 'back') { return }
        $matching = @($items | Where-Object Id -CEQ ([string]$choice.SelectedItem.Id))
        if ($matching.Count -ne 1 -or -not $matching[0].Data) { return }
        $selected = $matching[0].Data
        Write-LabInfo ("{0} · {1} · SQL-Endpunkt {2}" -f $selected.DisplayName,$selected.Provider,$selected.Server)
        Write-LabInfo ("Gespeicherter Zustand {0}. Aktuelle Erreichbarkeit wurde nicht geprüft." -f $selected.StoredState)
    } catch [Management.Automation.PipelineStoppedException] { throw }
    catch { Write-LabWarning 'Gespeicherte SQL-Endpunkte konnten nicht gelesen werden.' }
    $null = Wait-LabConsoleAcknowledgement
}
