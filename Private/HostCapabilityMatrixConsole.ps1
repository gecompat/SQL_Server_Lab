function Get-LabHostMatrixLaunchRows {
    param($Matrix)
    @($Matrix.Capabilities | Where-Object {
        $_.CatalogStatus -ceq 'DECLARED_SUPPORTED' -and $_.Provider -cin @('docker','podman') -and
        $_.TargetOperatingSystem -ceq 'linux' -and $Matrix.SqlVersion -cin @('2019','2022','2025')
    })
}

function Show-LabHostMatrixLaunchDetailsInteractive {
    param($Matrix,[object[]]$Rows)
    if(-not $Rows.Count) {return}
    $items=@(foreach($row in $Rows) {
        New-LabConsoleItem -Id ($row.Provider+'/'+$row.VariantId) `
            -Label ("{0}: {1} {2}" -f $row.Provider,$row.Language,$row.RuntimeVersion) -Value $row.VariantId -Data $row
    })
    $selected=Select-LabConsoleDataItem -ScreenId 'host-matrix-launch-variant' -Title 'Container-Sprachvariante auswählen' `
        -Subtitle 'Katalogbindung erneut lesen; keine Instanz oder Sprache ausführen.' -Items $items
    if(-not $selected) {return}
    $choices=@(
        New-LabConsoleItem -Id 'catalog' -Label 'Katalog- und Launchdeklaration ohne Hostabfrage' -Shortcut '1' -Data ([pscustomobject]@{Probe=$false})
        New-LabConsoleItem -Id 'probe' -Label 'Container-Grundlagen bewusst lesend prüfen' -Value 'Linux · cgroup-Version · Rootful; bis zu 20 Sekunden.' -Shortcut '2' -Data ([pscustomobject]@{Probe=$true})
    )
    $choice=Select-LabConsoleDataItem -ScreenId 'host-matrix-launch-probe' -Title 'Variantenprüfung: Umfang' `
        -Subtitle 'Esc bricht vor jeder Abfrage ab. Ressourcen, WSL-Konflikte und SQL-Sprachausführung bleiben ungeprüft.' -Items $choices
    if(-not $choice) {return}
    $decision=Get-SqlServerLabExternalRuntimeCapability -SqlVersion $Matrix.SqlVersion -Provider $selected.Provider -OperatingSystem linux `
        -SoftwareId $selected.SoftwareId -RuntimeVersion $selected.RuntimeVersion -VariantId $selected.VariantId -CheckProviderReadiness:$choice.Probe
    Write-Host ("SQL {0} · {1} · {2} · {3}" -f $Matrix.SqlVersion,$selected.Provider,$selected.SoftwareId,$selected.VariantId)
    Write-Host ("Katalog: {0} / {1}" -f $decision.CatalogDecision.Status,$decision.CatalogDecision.ReasonCode)
    Write-Host ("Container-Grundlagen: {0} / {1}; Launchmodus: {2}; benötigte cgroup-Version: {3}" -f
        $decision.CurrentReadiness.Status,$decision.CurrentReadiness.ReasonCode,$decision.CurrentReadiness.LaunchMode,$decision.CurrentReadiness.RequiredCgroupVersion)
    Write-Host 'Keine Ausführungsfreigabe. SQL-Sprachausführung, Zielrechte, Ressourcen und WSL-Konflikte bleiben ungeprüft.'
    Wait-LabConsoleAcknowledgement -Prompt '  Enter oder Escape: Zurück zum Hauptmenü'
}

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
    $launchRows=@(Get-LabHostMatrixLaunchRows -Matrix $matrix)
    $prompt=if($launchRows.Count){'  Enter oder Escape: Zu Variantenprüfung oder Hauptmenü'}else{'  Enter oder Escape: Zurück zum Hauptmenü'}
    Wait-LabConsoleAcknowledgement -Prompt $prompt
    if($launchRows.Count) {
        $items=@(
            New-LabConsoleItem -Id 'back' -Label 'Zurück zum Hauptmenü' -Shortcut '0' -Data ([pscustomobject]@{Action='Return'})
            New-LabConsoleItem -Id 'details' -Label 'Konkrete Container-Variante näher prüfen' -Value 'Bestehende Katalog-/cgroup-/Rootful-Entscheidung' -Shortcut '1' -Data ([pscustomobject]@{Action='Details'})
        )
        $next=Select-LabConsoleDataItem -ScreenId 'host-matrix-next' -Title 'Nächster Schritt' `
            -Subtitle 'Hyper-V-Launchdetails und C# bleiben in dieser Vertiefung offen.' -Items $items
        if($next -and $next.Action -ceq 'Details') {Show-LabHostMatrixLaunchDetailsInteractive -Matrix $matrix -Rows $launchRows}
    }
}
