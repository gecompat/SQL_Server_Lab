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
        New-LabConsoleItem -Id 'catalog' -Label 'Katalog- und Launchdeklaration ohne Hostabfrage' -Shortcut '1' -Data ([pscustomobject]@{Probe=$false; Prerequisites=$false; History=$false})
        New-LabConsoleItem -Id 'probe' -Label 'Container-Grundlagen bewusst lesend prüfen' -Value 'Linux · cgroup-Version · Rootful · bis zu 20 Sekunden' -Shortcut '2' -Data ([pscustomobject]@{Probe=$true; Prerequisites=$false; History=$false})
        New-LabConsoleItem -Id 'prerequisites' -Label 'Voraussetzungen für ein Ressourcenprofil lesend prüfen' `
            -Value 'Zusätzlich Controller und Gesamtkapazität des Providers' -Shortcut '3' -Data ([pscustomobject]@{Probe=$true; Prerequisites=$true; History=$false})
        New-LabConsoleItem -Id 'history' -Label 'Historische Nachweise für diese Variante lesen' `
            -Value 'Gespeicherten Index ohne Hostabfrage lesen' -Shortcut '4' -Data ([pscustomobject]@{Probe=$false; Prerequisites=$false; History=$true})
    )
    $choice=Select-LabConsoleDataItem -ScreenId 'host-matrix-launch-probe' -Title 'Variantenprüfung: Umfang' `
        -Subtitle 'Esc bricht vor der Abfrage ab. SQL-Sprachausführung und WSL-Konflikte werden hier nicht geprüft.' -Items $choices
    if(-not $choice) {return}
    $arguments = @{ CheckProviderReadiness = $choice.Probe }
    if ($choice.History) { $arguments.IncludeRecordedEvidence = $true }
    if ($choice.Prerequisites) {
        $profiles = foreach ($profile in $script:VersionCatalog.profiles.PSObject.Properties) {
            New-LabConsoleItem -Id $profile.Name -Label $profile.Name `
                -Value "$($profile.Value.maxCpus) vCPU · $($profile.Value.maxMemoryMB) MB RAM" -Data $profile.Name
        }
        $profileName = Select-LabConsoleDataItem -ScreenId 'host-matrix-launch-profile' -Title 'Ressourcenprofil zur Prüfung wählen' `
            -Subtitle 'Die Auswahl löst genau eine lesende Providerabfrage aus.' -Items @($profiles) -SelectedId 'standard'
        if (-not $profileName) { return }
        $arguments.IncludeHostPrerequisites = $true
        $arguments.IncludeProviderFacts = $true
        $arguments.ResourceProfile = $profileName
    }
    $decision=Get-SqlServerLabExternalRuntimeCapability -SqlVersion $Matrix.SqlVersion -Provider $selected.Provider -OperatingSystem linux `
        -SoftwareId $selected.SoftwareId -RuntimeVersion $selected.RuntimeVersion -VariantId $selected.VariantId @arguments
    Write-Host ("SQL {0} · {1} · {2} · {3}" -f $Matrix.SqlVersion,$selected.Provider,$selected.SoftwareId,$selected.VariantId)
    Write-Host ("Katalog: {0} / {1}" -f $decision.CatalogDecision.Status,$decision.CatalogDecision.ReasonCode)
    if ($choice.History) {
        try {
            if ($decision.Contract.Version -cne '1.1' -or $decision.CurrentReadiness.Status -cne 'NOT_CHECKED') {
                throw 'EXTERNAL_RUNTIME_HISTORY_INVALID'
            }
            $history = ConvertTo-LabExternalRuntimeHistorySummary $decision.HistoricalEvidence
            Write-Host ("Historie {0} · Zuordnung {1} · {2}" -f $history.Status,$history.MappingStatus,$history.ReasonCode)
            Write-Host ("Zugeordnete historische Einträge {0} · Referenzen {1}" -f $history.RecordCount,$history.ReferenceVerificationStatus)
            Write-Host 'Aktuelle Hostbereitschaft NOT_CHECKED.'
            Write-Host 'Die Anzahl zählt auch frühere Fehler. Die aktuelle SQL-Sprachausführung bleibt ungeprüft.'
        } catch {
            Write-Host 'Historische Zuordnung konnte für diese Variante nicht bestätigt werden.'
        }
    } else {
        Write-Host ("Container-Grundlagen: {0} / {1}; Launchmodus: {2}; benötigte cgroup-Version: {3}" -f
            $decision.CurrentReadiness.Status,$decision.CurrentReadiness.ReasonCode,$decision.CurrentReadiness.LaunchMode,$decision.CurrentReadiness.RequiredCgroupVersion)
    }
    if ($choice.Prerequisites) {
        $facts = $decision.HostPrerequisites
        Write-Host ("Profil {0} · {1} · {2}" -f $facts.ResourceProfile,$facts.Status,($facts.ReasonCodes -join ', '))
        if ($facts.ProviderFacts) {
            $rootless = if ($facts.ProviderFacts.Rootless) { 'ja' } else { 'nein' }
            Write-Host ("Provider meldet · Runtime-OS {0} · cgroup {1} · Rootless {2}" -f
                $facts.ProviderFacts.OperatingSystem,$facts.ProviderFacts.CgroupVersion,$rootless)
        } else {
            Write-Host 'Runtime-OS, cgroup-Version und Rootless-Modus konnten für diese Auswahl nicht beobachtet werden.'
        }
        if ($facts.Controllers) {
            Write-Host ("Controller {0} · fehlend {1} · unbekannt {2}" -f $facts.Controllers.Status,
                ($facts.Controllers.Missing -join ', '),($facts.Controllers.Unknown -join ', '))
        }
        if ($facts.ResourceCapacity) {
            Write-Host ("Gesamtkapazität für das Profil · RAM {0} · vCPU {1}" -f $facts.ResourceCapacity.MemoryStatus,$facts.ResourceCapacity.CpuStatus)
        }
    }
    Write-Host 'Keine Ausführungsfreigabe. Freie Ressourcen, WSL-Konflikte, Zielrechte und SQL-Sprachausführung bleiben ungeprüft.'
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
