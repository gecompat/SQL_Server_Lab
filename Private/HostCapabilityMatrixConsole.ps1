function Show-LabHostCapabilityMatrixInteractive {
    $items=@(foreach($version in $script:VersionCatalog.versions) {
        New-LabConsoleItem -Id ([string]$version.id) -Label ("SQL Server {0}" -f $version.id) -Data $version
    })
    $selected=Select-LabConsoleDataItem -ScreenId 'host-matrix-sql' -Title 'Hostfähigkeiten: SQL-Version' `
        -Subtitle 'Katalog und aktuelle Providerbereitschaft bleiben getrennt.' -Items $items
    if(-not $selected) {return}
    $choices=@(
        New-LabConsoleItem -Id 'catalog' -Label 'Katalogübersicht ohne Hostabfrage' -Shortcut '1' -Data ([pscustomobject]@{Probe=$false})
        New-LabConsoleItem -Id 'readiness' -Label 'Provider jetzt bewusst lesend prüfen' -Value 'Kein Start; je Provider bis zu 50 Sekunden.' -Shortcut '2' -Data ([pscustomobject]@{Probe=$true})
    )
    $choice=Select-LabConsoleDataItem -ScreenId 'host-matrix-probe' -Title 'Hostfähigkeiten: Prüfumfang' `
        -Subtitle 'Esc bricht ab. Erreichbarkeit beweist keine SQL- oder Sprachfunktion.' -Items $choices
    if(-not $choice) {return}
    $matrix=Get-SqlServerLabHostCapabilityMatrix -SqlVersion ([string]$selected.id) -CheckProviderReadiness:$choice.Probe
    # Host observations are transient output, never messages.jsonl entries.
    Write-Host ("Hostprofil: {0}; SQL {1}; Hostsystem {2}" -f $matrix.ProviderProfile,$matrix.SqlVersion,$matrix.HostOperatingSystem)
    foreach($provider in $matrix.Providers) {
        Write-Host ("{0}: Installation {1}; Bereitschaft {2}; Grund {3}" -f $provider.Provider,$provider.Presence,$provider.Readiness,$provider.ReasonCode)
    }
    foreach($row in $matrix.Capabilities) {
        Write-Host ("{0}/{1} · {2} {3} · {4}: {5}; nächster Schritt: {6}" -f $row.Provider,$row.TargetOperatingSystem,$row.Language,$row.RuntimeVersion,$row.Availability,$row.ReasonCode,$row.NextStep)
        Write-Host $row.Explanation
    }
    Write-Host 'Keine Ausführungsfreigabe. Launchmodus, Gast/SQL-Build, Kernel/Controller, WSL, Ressourcen, Zielrechte und Sprachabnahme sind ungeprüft.'
    Wait-LabConsoleAcknowledgement -Prompt '  Enter oder Escape: Zurück zum Hauptmenü'
}
