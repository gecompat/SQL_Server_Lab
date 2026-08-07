<#
.SYNOPSIS
    Interaktives Menue fuer SQL_Server_Lab.
.DESCRIPTION
    Single-Entry-Point mit Menue-Loop. Zeigt aktive Labs und bietet
    alle Operationen ueber nummerierte Auswahl an.
.PARAMETER Action
    Optionale Direkt-Aktion (ueberspringt das Menue).
.OUTPUTS
    Keine. Die Funktion ist eine interaktive Benutzeroberflaeche und delegiert
    die gewaehlte Aktion an die entsprechenden SqlServerLab-Commands.
.EXAMPLE
    Invoke-SqlServerLab
.EXAMPLE
    Invoke-SqlServerLab -Action Status
#>
function Invoke-SqlServerLab {
    [CmdletBinding()]
    param(
        [ValidateSet('New', 'Manifest', 'Status', 'Stop', 'Start', 'Restart', 'Remove', 'Clear', 'Script', 'Database', 'Image', 'MediaRoot', 'DataRoot', 'Rename')]
        [string]$Action
    )

    # Das Modul darf sich waehrend einer laufenden Modul-Funktion nicht selbst
    # mit -Force neu laden. Dabei werden die aktuelle Funktion und ihre
    # Hilfsfunktionen aus dem Session-State entfernt.

    # Direkt-Aktion ohne Menue
    if ($Action) {
        Invoke-LabAction -ActionName $Action
        return
    }

    # Interaktiver Menue-Loop
    $exit = $false
    while (-not $exit) {
        Show-LabBanner
        $choice = Show-LabMenu

        switch ($choice) {
            '1' { Invoke-LabAction -ActionName 'New' }
            'm' { Invoke-LabAction -ActionName 'Manifest' }
            '2' { Invoke-LabAction -ActionName 'Status' }
            '3' { Invoke-LabAction -ActionName 'Stop' }
            '4' { Invoke-LabAction -ActionName 'Start' }
            '5' { Invoke-LabAction -ActionName 'Restart' }
            '6' { Invoke-LabAction -ActionName 'Remove' }
            '7' { Invoke-LabAction -ActionName 'Clear' }
            '8' { Invoke-LabAction -ActionName 'Database' }
            '9' { Invoke-LabAction -ActionName 'Script' }
            'n' { Invoke-LabAction -ActionName 'Rename' }
            'i' { Invoke-LabAction -ActionName 'Image' }
            'r' { Invoke-LabAction -ActionName 'MediaRoot' }
            'd' { Invoke-LabAction -ActionName 'DataRoot' }
            '0' { $exit = $true }
            'q' { $exit = $true }
            default { Write-Host "  Ungueltige Auswahl: $choice" -ForegroundColor Red }
        }

        if (-not $exit) {
            Write-Host ""
            Write-Host "  [Enter] fuer Menue..." -ForegroundColor DarkGray -NoNewline
            Read-Host | Out-Null
        }
    }

    Write-Host ""
    Write-LabInfo "Auf Wiedersehen."
}

# =============================================================================
# Interne Hilfsfunktionen
# =============================================================================

function Show-LabBanner {
    Clear-Host
    Write-Host ""
    Write-Host "  =====================================================================" -ForegroundColor Cyan
    Write-Host "   SQL Server Lab" -ForegroundColor White
    Write-Host "   Isolierte, reproduzierbare SQL-Server-Testumgebungen" -ForegroundColor DarkGray
    Write-Host "  =====================================================================" -ForegroundColor Cyan

    # Verfuegbare Provider anzeigen
    $providers = @(Get-AvailableLabProviders)
    $hyperVInstalled = $IsWindows -and $null -ne (Get-Command Get-VM -ErrorAction SilentlyContinue)
    $providerLabel = if ($providers.Count -gt 0) { $providers -join ', ' } else { 'KEIN Container-Provider' }
    if ($hyperVInstalled) {
        $hyperV = Test-HyperVAvailable
        $providerLabel += if ($hyperV.Available) { ', hyperv' } else { ', hyperv (UAC erforderlich)' }
    }
    if ($providers.Count -gt 0 -or $hyperVInstalled) {
        Write-Host "  Provider: $providerLabel" -ForegroundColor DarkGray
    }
    else {
        Write-Host "  Provider: KEINER VERFUEGBAR" -ForegroundColor Red
    }

    # Aktive Labs kurz anzeigen
    $stateRoot = Get-LabStateRoot
    $runs = @(Get-LabActiveRuns -StateRoot $stateRoot)

    if ($runs.Count -gt 0) {
        Write-Host ""
        Write-Host "  Aktive Umgebungen: $($runs.Count)" -ForegroundColor Green
        foreach ($run in $runs) {
            $prefix = $run.runId.Substring(0, 8)
            $name = $run.metadata.name
            $runtime = Get-LabRunRuntimeStatus -Run $run -StateRoot $stateRoot
            Write-Host "    [Live: $($runtime.State.PadRight(11))] ${prefix}... - $name  (Workflow: $($run.state))" -ForegroundColor Gray
        }
    }
    else {
        Write-Host ""
        Write-Host "  Keine aktiven Umgebungen." -ForegroundColor DarkGray
    }
    Write-Host ""
}

function Show-LabMenu {
    Write-Host "  -------------------------" -ForegroundColor DarkCyan
    Write-Host "  Aktionen:" -ForegroundColor White
    Write-Host ""
    Write-Host "    [1] Neue Umgebung erstellen" -ForegroundColor Yellow
    Write-Host "    [m] Manifest erstellen und pruefen" -ForegroundColor Yellow
    Write-Host "    [2] Status anzeigen" -ForegroundColor White
    Write-Host "    [3] Umgebung stoppen" -ForegroundColor White
    Write-Host "    [4] Umgebung starten" -ForegroundColor White
    Write-Host "    [5] Umgebung neustarten" -ForegroundColor White
    Write-Host "    [6] Umgebung entfernen" -ForegroundColor White
    Write-Host "    [7] Alles aufraeumen" -ForegroundColor Red
    Write-Host "    [8] Datenbank anlegen" -ForegroundColor White
    Write-Host "    [9] SQL-Skript ausfuehren" -ForegroundColor White
    Write-Host "    [n] Umgebung umbenennen" -ForegroundColor White
    Write-Host "    [i] Hyper-V Windows-Image verwalten" -ForegroundColor Yellow
    Write-Host "    [r] Media Root konfigurieren" -ForegroundColor White
    Write-Host "    [d] Persistenten Data Root konfigurieren" -ForegroundColor White
    Write-Host ""
    Write-Host "    [0/q] Beenden" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  -------------------------" -ForegroundColor DarkCyan
    $choice = Read-Host "  Auswahl"
    return $choice
}

function Invoke-LabAction {
    param([Parameter(Mandatory)][string]$ActionName)

    Write-Host ""

    switch ($ActionName) {
        'MediaRoot' {
            $currentMediaRoot = Get-LabMediaRootDefault
            $prompt = if ($currentMediaRoot) { "  Neuer Media Root [$currentMediaRoot]" } else { '  Neuer Media Root' }
            $candidate = Read-Host $prompt
            if ([string]::IsNullOrWhiteSpace($candidate)) {
                Write-LabInfo 'Media Root unverändert.'
                return
            }
            try {
                $savedMediaRoot = Set-LabMediaRootDefault -MediaRoot $candidate
                Write-LabSuccess "Media Root gespeichert: $savedMediaRoot"
            }
            catch {
                Write-LabError "Media Root konnte nicht gespeichert werden: $($_.Exception.Message)"
            }
        }
        'DataRoot' {
            $currentDataRoot = Get-LabDataRootDefault
            $prompt = if ($currentDataRoot) { "  Neuer Data Root [$currentDataRoot]" } else { '  Neuer Data Root' }
            $candidate = Read-Host $prompt
            if ([string]::IsNullOrWhiteSpace($candidate)) {
                Write-LabInfo 'Data Root unverändert.'
                return
            }
            try {
                $savedDataRoot = Set-LabDataRootDefault -DataRoot $candidate
                Write-LabSuccess "Data Root gespeichert: $savedDataRoot"
            }
            catch {
                Write-LabError "Data Root konnte nicht gespeichert werden: $($_.Exception.Message)"
                Write-Host '  Der Ordner muss vorher mit .\Tools\Initialize-SqlServerLabDataRoot.ps1 initialisiert werden.' -ForegroundColor DarkGray
            }
        }
        'Manifest' {
            $manifestPath = Read-Host '  Manifest-Zielpfad [.\lab-manifest.json]'
            if (-not $manifestPath) {
                $manifestPath = '.\lab-manifest.json'
            }

            $null = New-SqlServerLabManifest -Path $manifestPath
            if ((Test-Path -LiteralPath $manifestPath -PathType Leaf) -and
                (Read-LabConfirm -Prompt 'Umgebung jetzt aus diesem Manifest erstellen?' -Default $false)) {
                $lab = New-SqlServerLab -Manifest $manifestPath
                Write-LabSuccess "Lab erstellt. RunId: $($lab.RunId)"
            }
        }
        'Rename' { Rename-LabEnvironmentInteractive }
        'New' {
            # Verfuegbare Provider ermitteln
            $availableProviders = @(Get-AvailableLabProviders)

            if ($availableProviders.Count -eq 0) {
                Write-LabError "Kein implementierter Container-Provider gefunden (docker, podman)."
                return
            }

            # Provider-Auswahl (automatisch wenn nur einer)
            if ($availableProviders.Count -eq 1) {
                $provider = $availableProviders[0]
                Write-LabInfo "Provider: $provider (einziger verfuegbarer)"
            }
            else {
                Write-Host "  Verfuegbare Provider:" -ForegroundColor DarkGray
                for ($i = 0; $i -lt $availableProviders.Count; $i++) {
                    Write-Host "    [$($i+1)] $($availableProviders[$i])" -ForegroundColor White
                }
                $provSel = Read-Host "  Provider [$($availableProviders[0])]"
                if (-not $provSel) {
                    $provider = $availableProviders[0]
                }
                elseif ($provSel -match '^\d+$' -and [int]$provSel -ge 1 -and [int]$provSel -le $availableProviders.Count) {
                    $provider = $availableProviders[[int]$provSel - 1]
                }
                elseif ($provSel -in $availableProviders) {
                    $provider = $provSel
                }
                else {
                    Write-LabError "Ungueltige Provider-Auswahl: $provSel"
                    return
                }
            }

            # Version abfragen
            Write-Host "  Verfuegbare Versionen: 2019, 2022, 2025" -ForegroundColor DarkGray
            $version = Read-Host "  SQL-Server-Version [2025]"
            if (-not $version) { $version = '2025' }

            $profile = Read-Host '  Ressourcenprofil: compact, standard, performance [standard]'
            if (-not $profile) { $profile = 'standard' }
            if ($profile -notin @('compact', 'standard', 'performance')) {
                Write-LabError "Ungueltiges Ressourcenprofil: $profile"
                return
            }
            $labName = Read-Host "  Labname [adhoc-$version-$provider]"
            if (-not $labName) { $labName = "adhoc-$version-$provider" }
            $instanceId = Read-Host '  Instanzname [primary]'
            if (-not $instanceId) { $instanceId = 'primary' }

            # Testdatenbanken (optional, Mehrfachauswahl)
            $selectedSamples = @(Select-LabSampleSelection -SqlVersion $version)

            $newLabArguments = @{
                Version  = $version
                Provider = $provider
                Profile = $profile
                LabName = $labName
                InstanceId = $instanceId
            }
            $defaultDataRoot = Get-LabDataRootDefault
            if ($defaultDataRoot) {
                Write-LabInfo "Optionaler Data Root verfügbar: $defaultDataRoot"
                if (Read-LabConfirm -Prompt '  SQL-System- und Datenbanken persistent im Data Root einbinden?' -Default $false) {
                    $newLabArguments.PersistentData = $true
                    $newLabArguments.DataRoot = $defaultDataRoot
                }
            }
            else {
                Write-LabInfo 'Kein initialisierter Data Root gespeichert; die Containerdaten bleiben run-lokal und werden beim Cleanup entfernt.'
            }
            if ($selectedSamples.Count -gt 0) {
                $newLabArguments.Sample = $selectedSamples
            }

            $lab = New-SqlServerLab @newLabArguments
            Write-Host ""
            Write-LabSuccess "Lab erstellt auf $provider. RunId: $($lab.RunId)"
        }

        'Status' {
            $runs = @(Get-LabActiveRuns)
            if ($runs.Count -eq 0) {
                Write-LabInfo "Keine aktiven Labs."
                return
            }
            $runId = Select-LabRun -Runs $runs -Prompt "Status anzeigen"
            if ($runId) { $null = Get-SqlServerLab -RunId $runId -Detailed }
        }

        'Stop' {
            $runs = @(Get-LabActiveRuns) | Where-Object { $_.state -eq 'RUNNING' }
            if ($runs.Count -eq 0) {
                Write-LabInfo "Keine laufenden Labs."
                return
            }
            $runId = Select-LabRun -Runs $runs -Prompt "Stoppen"
            if ($runId) { Stop-SqlServerLab -RunId $runId -Force }
        }

        'Start' {
            $runs = @(Get-LabActiveRuns) | Where-Object { $_.state -eq 'STOPPED' }
            if ($runs.Count -eq 0) {
                Write-LabInfo "Keine gestoppten Labs."
                return
            }
            $runId = Select-LabRun -Runs $runs -Prompt "Starten"
            if ($runId) { Start-SqlServerLab -RunId $runId }
        }

        'Restart' {
            $runs = @(Get-LabActiveRuns) | Where-Object { $_.state -in @('RUNNING','STOPPED') }
            if ($runs.Count -eq 0) {
                Write-LabInfo "Keine Labs zum Neustarten."
                return
            }
            $runId = Select-LabRun -Runs $runs -Prompt "Neustarten"
            if ($runId) { Restart-SqlServerLab -RunId $runId -Force }
        }

        'Remove' {
            $runs = @(Get-LabActiveRuns)
            if ($runs.Count -eq 0) {
                Write-LabInfo "Keine aktiven Labs."
                return
            }
            $runId = Select-LabRun -Runs $runs -Prompt "Entfernen"
            if ($runId) {
                $confirm = Read-Host "  Wirklich entfernen? (j/n) [n]"
                if ($confirm -eq 'j') { Remove-SqlServerLab -RunId $runId -Force }
            }
        }

        'Clear' {
            Clear-SqlServerLab
        }

        'Database' {
            $runs = @(Get-LabActiveRuns) | Where-Object { $_.state -eq 'RUNNING' }
            if ($runs.Count -eq 0) {
                Write-LabInfo "Keine laufenden Labs."
                return
            }
            $runId = Select-LabRun -Runs $runs -Prompt "Datenbank anlegen auf"
            if (-not $runId) { return }

            $stateRoot = Get-LabStateRoot
            $connectionInfoPath = Join-Path (Join-Path (Join-Path $stateRoot 'runs') $runId) 'connection-info.json'
            if (-not (Test-Path -LiteralPath $connectionInfoPath -PathType Leaf)) { Write-LabError 'Connection-Info nicht gefunden.'; return }
            $connectionInfo = Get-Content -LiteralPath $connectionInfoPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 20
            $instanceId = [string](@($connectionInfo.instances | Select-Object -First 1)[0].id)
            if (-not $instanceId) { Write-LabError 'Keine Container-Instanz im Run gespeichert.'; return }
            try { $target = Resolve-LabRunInstance -RunId $runId -InstanceId $instanceId -StateRoot $stateRoot }
            catch { Write-LabError $_.Exception.Message; return }

            if (Read-LabConfirm -Prompt '  Testdatenbank aus dem Katalog wiederherstellen?' -Default $false) {
                $selectedSamples = @(Select-LabSampleSelection -SqlVersion $target.Version -SkipInitialConfirm)
                if ($selectedSamples.Count -eq 0) { return }
                $pw = Read-Host '  SA-Passwort' -AsSecureString
                $runDirectory = Join-Path (Join-Path $stateRoot 'runs') $runId
                foreach ($sampleSpec in $selectedSamples) {
                    $parts = ([string]$sampleSpec).Split(':', 2)
                    $sample = Get-LabSampleDatabase -Id $parts[0]
                    $variantName = if ($parts.Count -gt 1 -and $parts[1]) { $parts[1] } else { 'full' }
                    if (-not $sample) { Write-LabError "Sample nicht gefunden: $sampleSpec"; continue }
                    $variant = @($sample.versions.PSObject.Properties | Where-Object Name -eq $variantName | Select-Object -First 1)
                    if ($variant.Count -ne 1) { Write-LabError "Sample-Variante nicht gefunden: $sampleSpec"; continue }
                    $outputs = @($variant[0].Value.expectedOutputs)
                    if ($outputs.Count -ne 1 -or -not $outputs[0].name) { Write-LabError "Sample besitzt keinen eindeutigen Datenbank-Output: $sampleSpec"; continue }
                    try {
                        $restoreDefinition = Resolve-LabSampleRestore -SampleDefinition ([PSCustomObject]@{ id = $parts[0]; variant = $variantName }) -SqlVersion $target.Version -TargetDatabaseName ([string]$outputs[0].name)
                        $result = Install-LabSampleDatabase -HostName $target.HostName -Port $target.Port -SaPassword $pw -ContainerName $target.ContainerName -RestoreDefinition $restoreDefinition -RunDirectory $runDirectory -StateRoot $stateRoot
                        if ($result.Success) { Write-LabSuccess $result.Message } else { Write-LabError "$($result.Status): $($result.Message)" }
                    }
                    catch { Write-LabError $_.Exception.Message }
                }
                return
            }

            $dbName = Read-Host "  Datenbankname"
            if (-not $dbName) { return }

            $pw = Read-Host "  SA-Passwort" -AsSecureString
            New-SqlServerLabDatabase -HostName $target.HostName -Port $target.Port -SaPassword $pw -DatabaseName $dbName
        }

        'Script' {
            $runs = @(Get-LabActiveRuns) | Where-Object { $_.state -eq 'RUNNING' }
            if ($runs.Count -eq 0) {
                Write-LabInfo "Keine laufenden Labs."
                return
            }
            $runId = Select-LabRun -Runs $runs -Prompt "Skript ausfuehren auf"
            if (-not $runId) { return }

            # Port aus connection-info lesen
            $stateRoot = Get-LabStateRoot
            $connInfoPath = Join-Path $stateRoot "runs/$runId/connection-info.json"
            $connInfo = Get-Content $connInfoPath -Raw | ConvertFrom-Json
            $port = $connInfo.instances[0].port

            $scriptPath = Read-Host "  Skript-Pfad"
            if (-not $scriptPath -or -not (Test-Path $scriptPath)) {
                Write-LabError "Skript nicht gefunden: $scriptPath"
                return
            }

            $db = Read-Host "  Datenbank [master]"
            if (-not $db) { $db = 'master' }

            $pw = Read-Host "  SA-Passwort" -AsSecureString
            Invoke-SqlServerLabScript -ScriptPath $scriptPath -Port $port -SaPassword $pw -Database $db
        }

        'Image' {
            Invoke-LabHyperVImageAction
        }
    }
}

function Invoke-LabHyperVImageAction {
    [CmdletBinding()]
    param()

    if (-not (Test-LabAdministrator)) {
        try {
            $elevation = Start-LabElevatedAction -Action Image
            if ($elevation.Started) {
                Write-LabInfo 'Hyper-V-Aktion wird in einem erhoehten PowerShell-Fenster fortgesetzt.'
            }
        }
        catch {
            Write-LabError "Hyper-V-Aktion benoetigt Administratorrechte: $($_.Exception.Message)"
        }
        return
    }

    $availability = Test-HyperVAvailable
    if (-not $availability.Available) {
        $installCapability = Test-LabHyperVInstallCapability
        if ($installCapability.Supported) {
            Write-LabWarning "Hyper-V ist noch nicht bereit: $($availability.Message)"
            Write-Host '  Die Installation umfasst Hyper-V-Plattform, PowerShell-Modul und Verwaltungstools; ein Neustart kann erforderlich sein.' -ForegroundColor DarkGray
            if (Read-LabConfirm -Prompt '  Fehlende Hyper-V-Komponenten jetzt installieren?' -Default $false) {
                try {
                    $install = Install-LabHyperVPrerequisites
                    if (-not $install.Succeeded) { Write-LabError 'Die Hyper-V-Installation wurde nicht erfolgreich abgeschlossen.'; return }
                    if ($install.RestartRequired) {
                        Write-LabWarning 'Hyper-V wurde installiert. Windows jetzt neu starten und danach den Image-Menuepunkt erneut waehlen.'
                        return
                    }
                    $availability = Test-HyperVAvailable
                }
                catch { Write-LabError "Hyper-V-Installation fehlgeschlagen: $($_.Exception.Message)"; return }
            }
        }
    }
    if (-not $availability.Available) {
        Write-LabError "Hyper-V nicht verfuegbar: $($availability.Message)"
        return
    }

    $exitImageMenu = $false
    while (-not $exitImageMenu) {
        Clear-Host
        Write-Host '  Hyper-V' -ForegroundColor White
        Write-Host ''
        Write-Host '    Standardpfad: Windows + SQL aus ISO installieren, einmal Sysprep, als Prepared-Image veröffentlichen.' -ForegroundColor Yellow
        Write-Host '    Technische Einzelaktionen, OS-Baselines und Abnahme-VMs liegen unter Erweitert.' -ForegroundColor DarkGray
        Write-Host ''
        Write-Host '    [1] Neues SQL-Prepared-Image erstellen' -ForegroundColor Yellow
        Write-Host '    [2] Offenen Prepared-Image-Builder fortsetzen' -ForegroundColor White
        Write-Host '    [3] Neue Hyper-V-Umgebung aus Prepared-Image erstellen' -ForegroundColor Yellow
        Write-Host '    [4] Hyper-V-Umgebungen verwalten' -ForegroundColor White
        Write-Host '    [5] Veröffentlichte Images verwalten' -ForegroundColor White
        Write-Host '    [e] Erweitert: OS-Baselines, Abnahme und Reparatur' -ForegroundColor DarkGray
        Write-Host '    [0] Zurueck' -ForegroundColor DarkGray
        Write-Host ''
        $choice = Read-Host '  Auswahl'
        switch ($choice) {
            '0' { $exitImageMenu = $true }
            '1' { Invoke-LabHyperVMenuAction -Title 'Neues SQL-Prepared-Image' -Action { New-LabHyperVSqlImageBuildInteractive } }
            '2' { Invoke-LabHyperVPreparedImageWorkflowMenu }
            '3' { Invoke-LabHyperVMenuAction -Title 'Neue Hyper-V-Umgebung' -Action { New-LabHyperVEnvironmentInteractive } }
            '4' { Invoke-LabHyperVMenuAction -Title 'Hyper-V-Umgebungen verwalten' -Action { Manage-LabHyperVEnvironmentInteractive } }
            '5' { Invoke-LabHyperVPublishedImageMenu }
            'e' { Invoke-LabHyperVAdvancedMenu }
            default { Write-LabWarning "Ungueltige Auswahl: $choice" }
        }
    }
}

function Show-LabHyperVMenuActionHeader {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Title)

    Clear-Host
    Write-Host ''
    Write-Host "  Hyper-V – $Title" -ForegroundColor Cyan
    Write-Host '  ---------------------------------------------------------------------' -ForegroundColor DarkCyan
    Write-Host ''
}

function Invoke-LabHyperVMenuAction {
    <#
    .SYNOPSIS
        Führt eine Hyper-V-Menüaktion sichtbar aus und kehrt erst nach Enter
        zu einem anschließend bereinigten Menü zurück.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][scriptblock]$Action
    )

    Show-LabHyperVMenuActionHeader -Title $Title
    & $Action
    $null = Read-Host '  [Enter] für Menü ...'
}

function Invoke-LabHyperVPreparedImageWorkflowMenu {
    [CmdletBinding()]
    param()

    $exitMenu = $false
    while (-not $exitMenu) {
        Clear-Host
        Write-Host ''
        Write-Host '  Prepared-Image-Builder fortsetzen' -ForegroundColor White
        Write-Host '    Folge: Windows installieren -> SQL PrepareImage -> finaler Sysprep -> veröffentlichen.' -ForegroundColor Yellow
        Show-LabHyperVSqlNextActions
        Write-Host ''
        Write-Host '    [1] Builder starten und VMConnect öffnen' -ForegroundColor White
        Write-Host '    [2] Windows-Installation bestätigen' -ForegroundColor White
        Write-Host '    [3] SQL PrepareImage und finalen Sysprep ausführen' -ForegroundColor Yellow
        Write-Host '    [4] Prepared-Image veröffentlichen' -ForegroundColor White
        Write-Host '    [5] Builder-Status anzeigen' -ForegroundColor White
        Write-Host '    [r] Sysprep offline prüfen und Wiederaufnahme versuchen' -ForegroundColor DarkYellow
        Write-Host '    [c] Unfertigen Builder aufräumen' -ForegroundColor Red
        Write-Host '    [0] Zurück' -ForegroundColor DarkGray
        $choice = Read-Host '  Auswahl'
        switch ($choice) {
            '0' { $exitMenu = $true }
            '1' { Invoke-LabHyperVMenuAction -Title 'Builder starten' -Action { Start-LabHyperVSqlImageBuildInteractive } }
            '2' { Invoke-LabHyperVMenuAction -Title 'Windows-Installation bestätigen' -Action { Confirm-LabHyperVSqlWindowsInstallationInteractive } }
            '3' { Invoke-LabHyperVMenuAction -Title 'SQL PrepareImage und Sysprep' -Action { Invoke-LabHyperVSqlPrepareInteractive } }
            '4' { Invoke-LabHyperVMenuAction -Title 'Prepared-Image veröffentlichen' -Action { Publish-LabHyperVSqlImageBuildInteractive } }
            '5' { Invoke-LabHyperVMenuAction -Title 'Builder-Status' -Action { $null = Show-LabHyperVSqlImageBuilds } }
            'r' { Invoke-LabHyperVMenuAction -Title 'Sysprep-Recovery' -Action { Resume-LabHyperVSqlPreparedImageGeneralizationInteractive } }
            'c' { Invoke-LabHyperVMenuAction -Title 'Unfertigen Builder aufräumen' -Action { Remove-LabHyperVSqlImageBuildInteractive } }
            default { Write-LabWarning "Ungueltige Auswahl: $choice" }
        }
    }
}

function Invoke-LabHyperVPublishedImageMenu {
    [CmdletBinding()]
    param()

    $exitMenu = $false
    while (-not $exitMenu) {
        Clear-Host
        Write-Host ''
        Write-Host '  Veröffentlichte Images verwalten' -ForegroundColor White
        Write-Host '    [1] Namen ändern' -ForegroundColor White
        Write-Host '    [2] Image löschen' -ForegroundColor Red
        Write-Host '    [0] Zurück' -ForegroundColor DarkGray
        $choice = Read-Host '  Auswahl'
        switch ($choice) {
            '0' { $exitMenu = $true }
            '1' { Invoke-LabHyperVMenuAction -Title 'Image-Namen ändern' -Action { Rename-LabHyperVImageArtifactInteractive } }
            '2' { Invoke-LabHyperVMenuAction -Title 'Image löschen' -Action { Remove-LabHyperVImageArtifactInteractive } }
            default { Write-LabWarning "Ungueltige Auswahl: $choice" }
        }
    }
}

function Invoke-LabHyperVAdvancedMenu {
    [CmdletBinding()]
    param()

    $exitMenu = $false
    while (-not $exitMenu) {
        Clear-Host
        Write-Host ''
        Write-Host '  Hyper-V – Erweitert / Reparatur' -ForegroundColor DarkYellow
        Write-Host '    [1] Windows-OS-Baselines verwalten (Expertenpfad)' -ForegroundColor DarkGray
        Write-Host '    [2] SQL-Builder aus einer OS-Baseline erstellen (Expertenpfad)' -ForegroundColor DarkGray
        Write-Host '    [3] Run-lokale Windows-/SQL-Abnahmeumgebung' -ForegroundColor DarkGray
        Write-Host '    [4] Sysprep offline prüfen und Wiederaufnahme versuchen' -ForegroundColor DarkYellow
        Write-Host '    [5] Neue Umgebung aus vorhandener ausgeschalteter Windows-VM' -ForegroundColor White
        Write-Host '    [0] Zurück' -ForegroundColor DarkGray
        $choice = Read-Host '  Auswahl'
        switch ($choice) {
            '0' { $exitMenu = $true }
            '1' { Invoke-LabHyperVWindowsBaselineMenu }
            '2' { Invoke-LabHyperVMenuAction -Title 'SQL-Builder aus OS-Baseline' -Action { New-LabHyperVSqlAcceptanceBuildInteractive } }
            '3' { Invoke-LabHyperVSqlAcceptanceMenu }
            '4' { Invoke-LabHyperVMenuAction -Title 'Sysprep-Recovery' -Action { Resume-LabHyperVSqlPreparedImageGeneralizationInteractive } }
            '5' { Invoke-LabHyperVMenuAction -Title 'Neue Umgebung aus vorhandener Windows-VM' -Action { New-LabHyperVEnvironmentFromExistingVmInteractive } }
            default { Write-LabWarning "Ungueltige Auswahl: $choice" }
        }
    }
}

function Invoke-LabHyperVWindowsBaselineMenu {
    [CmdletBinding()]
    param()

    $exitMenu = $false
    while (-not $exitMenu) {
        Clear-Host
        Write-Host ''
        Write-Host '  Windows-OS-Baselines – Expertenpfad' -ForegroundColor DarkYellow
        Write-Host '    [1] Windows-Builder aus Media Root vorbereiten' -ForegroundColor White
        Write-Host '    [2] Windows-Build-Status anzeigen' -ForegroundColor White
        Write-Host '    [3] Windows-Builder starten und VMConnect öffnen' -ForegroundColor White
        Write-Host '    [4] Installiertes Windows generalisieren' -ForegroundColor White
        Write-Host '    [5] Windows-Image veröffentlichen' -ForegroundColor White
        Write-Host '    [6] Unfertigen Windows-Builder aufräumen' -ForegroundColor Red
        Write-Host '    [0] Zurück' -ForegroundColor DarkGray
        $choice = Read-Host '  Auswahl'
        switch ($choice) {
            '0' { $exitMenu = $true }
            '1' { Invoke-LabHyperVMenuAction -Title 'Windows-Builder vorbereiten' -Action { New-LabHyperVImageBuildInteractive } }
            '2' { Invoke-LabHyperVMenuAction -Title 'Windows-Build-Status' -Action { $null = Show-LabHyperVImageBuilds } }
            '3' { Invoke-LabHyperVMenuAction -Title 'Windows-Builder starten' -Action { Start-LabHyperVImageBuildInteractive } }
            '4' { Invoke-LabHyperVMenuAction -Title 'Windows generalisieren' -Action { Invoke-LabHyperVImageGeneralizationInteractive } }
            '5' { Invoke-LabHyperVMenuAction -Title 'Windows-Image veröffentlichen' -Action { Publish-LabHyperVImageBuildInteractive } }
            '6' { Invoke-LabHyperVMenuAction -Title 'Windows-Builder aufräumen' -Action { Remove-LabHyperVImageBuildInteractive } }
            default { Write-LabWarning "Ungueltige Auswahl: $choice" }
        }
    }
}

function Invoke-LabHyperVSqlAcceptanceMenu {
    [CmdletBinding()]
    param()

    $exitMenu = $false
    while (-not $exitMenu) {
        Clear-Host
        Write-Host ''
        Write-Host '  Run-lokale Windows-/SQL-Abnahmeumgebung' -ForegroundColor DarkYellow
        Write-Host '    Dies ist kein Prepared-Image-Pfad; hier wird eine vollständige Testinstanz installiert.' -ForegroundColor DarkGray
        Write-Host '    [1] OOBE und vollständiges SQL automatisch installieren' -ForegroundColor White
        Write-Host '    [2] SQL-Abnahmetest ausführen' -ForegroundColor White
        Write-Host '    [3] SQL-2019/2022/2025-Abnahmematrix anzeigen' -ForegroundColor White
        Write-Host '    [4] Manuell abgeschlossene OOBE übernehmen und vollständiges SQL installieren' -ForegroundColor White
        Write-Host '    [0] Zurück' -ForegroundColor DarkGray
        $choice = Read-Host '  Auswahl'
        switch ($choice) {
            '0' { $exitMenu = $true }
            '1' { Invoke-LabHyperVMenuAction -Title 'OOBE und SQL-Setup' -Action { Invoke-LabHyperVSqlAcceptanceInstallInteractive } }
            '2' { Invoke-LabHyperVMenuAction -Title 'SQL-Abnahmetest' -Action { Test-LabHyperVSqlAcceptanceInteractive } }
            '3' { Invoke-LabHyperVMenuAction -Title 'SQL-Abnahmematrix' -Action { Show-LabHyperVSqlAcceptanceMatrix } }
            '4' { Invoke-LabHyperVMenuAction -Title 'Manuelle OOBE übernehmen' -Action { Invoke-LabHyperVSqlManualOobeAcceptanceInstallInteractive } }
            default { Write-LabWarning "Ungueltige Auswahl: $choice" }
        }
    }
}

function Show-LabHyperVImageBuilds {
    [CmdletBinding()]
    param()

    $builds = @(Get-HyperVImageBuildPlans)
    if ($builds.Count -eq 0) {
        Write-LabInfo 'Keine Hyper-V-Image-Builds vorhanden.'
        return @()
    }

    Write-Host ''
    Write-Host '  Image-Builds:' -ForegroundColor White
    for ($i = 0; $i -lt $builds.Count; $i++) {
        $build = $builds[$i]
        $vmName = if ($build.builder -and $build.builder.vmName) { [string]$build.builder.vmName } else { '-' }
        Write-Host ("    [{0}] {1}  {2}" -f ($i + 1), $build.buildId, $build.state) -ForegroundColor White
        Write-Host ("        OS: {0} | Edition: {1} | Typ: {2} | VM: {3}" -f `
            $build.operatingSystem.id, $build.operatingSystem.edition, $build.operatingSystem.installationType, $vmName) -ForegroundColor DarkGray
    }
    return $builds
}

function Select-LabHyperVImageBuild {
    [CmdletBinding()]
    param([string[]]$AllowedStates = @())

    $builds = @(Get-HyperVImageBuildPlans)
    if ($AllowedStates.Count -gt 0) {
        $builds = @($builds | Where-Object { $_.state -in $AllowedStates })
    }
    if ($builds.Count -eq 0) {
        Write-LabInfo 'Kein passender Image-Build vorhanden.'
        return $null
    }
    if ($builds.Count -eq 1) {
        Write-LabInfo "Build: $($builds[0].buildId) [$($builds[0].state)]"
        return $builds[0]
    }

    Write-Host ''
    for ($i = 0; $i -lt $builds.Count; $i++) {
        Write-Host "    [$($i + 1)] $($builds[$i].buildId) [$($builds[$i].state)]" -ForegroundColor White
    }
    $selection = Read-Host '  Build (Nummer)'
    if ($selection -notmatch '^\d+$') {
        Write-LabWarning 'Ungueltige Auswahl.'
        return $null
    }
    $index = [int]$selection - 1
    if ($index -lt 0 -or $index -ge $builds.Count) {
        Write-LabWarning 'Ungueltige Auswahl.'
        return $null
    }
    return $builds[$index]
}

function New-LabHyperVImageBuildInteractive {
    [CmdletBinding()]
    param()

    $defaultRoot = Get-LabMediaRootDefault
    $rootPrompt = if ($defaultRoot) { "  Media Root [$defaultRoot]" } else { '  Media Root' }
    $mediaRoot = Read-Host $rootPrompt
    if (-not $mediaRoot) { $mediaRoot = $defaultRoot }
    if (-not $mediaRoot) {
        Write-LabError 'Media Root ist erforderlich.'
        return
    }
    try { $mediaRoot = Set-LabMediaRootDefault -MediaRoot $mediaRoot }
    catch { Write-LabError "Media Root ist ungueltig: $($_.Exception.Message)"; return }

    $candidates = @(Get-HyperVWindowsInstallationMediaCandidates -MediaRoot $mediaRoot | Where-Object { $_.State -eq 'READY' })
    if ($candidates.Count -eq 0) {
        Write-LabError 'Kein erkennbares Windows-Evaluation-Installationsmedium im Media Root gefunden.'
        return
    }
    Write-Host '  Erkannte Windows-Installationsmedien:' -ForegroundColor White
    for ($i = 0; $i -lt $candidates.Count; $i++) {
        $candidate = $candidates[$i]
        Write-Host ("    [{0}] {1} · {2} · {3}" -f ($i + 1), $candidate.ImageName, $candidate.WindowsEdition, $candidate.MediaId) -ForegroundColor White
    }
    $selection = Read-Host '  Windows-Installationsmedium (Nummer) [1]'
    if (-not $selection) { $selection = '1' }
    if ($selection -notmatch '^\d+$' -or [int]$selection -lt 1 -or [int]$selection -gt $candidates.Count) {
        Write-LabError 'Ungültige Medienauswahl.'
        return
    }
    $selectedMedia = $candidates[[int]$selection - 1]
    $operatingSystemId = [string]$selectedMedia.OperatingSystemId
    $edition = [string]$selectedMedia.WindowsEdition
    $installationType = [string]$selectedMedia.InstallationType
    $windowsMediaPath = [string]$selectedMedia.MediaId

    try {
        $media = Resolve-HyperVWindowsInstallationMedia `
            -MediaRoot $mediaRoot `
            -OperatingSystemId $operatingSystemId -WindowsEdition $edition -InstallationType $installationType -WindowsMediaPath $windowsMediaPath
        if ($media.HashStatus -eq 'MISSING') {
            Write-LabWarning 'Fuer die ISO existiert noch kein SHA-256-Sidecar.'
            Write-Host "  ISO: $($media.IsoPath)" -ForegroundColor DarkGray
            if (-not (Read-LabConfirm -Prompt '  SHA-256 jetzt berechnen und lokal festschreiben?' -Default $false)) {
                Write-LabInfo 'Ohne SHA-256 wurde kein Build angelegt.'
                return
            }
            Write-LabInfo 'SHA-256 wird berechnet; grosse ISOs benoetigen mehrere Minuten.'
            $media = New-HyperVWindowsMediaHashSidecar `
                -MediaRoot $mediaRoot `
                -OperatingSystemId $operatingSystemId -WindowsEdition $edition -InstallationType $installationType -WindowsMediaPath $windowsMediaPath
        }

        Write-Host ''
        Write-Host "  ISO:       $($media.IsoPath)" -ForegroundColor DarkGray
        Write-Host "  SHA-256:   $($media.ExpectedSha256)" -ForegroundColor DarkGray
        Write-Host "  Ziel:      $operatingSystemId / $edition / $installationType" -ForegroundColor DarkGray
        Write-Host '  Ressourcen: 80 GB dynamische OS-VHDX, 4 GB RAM, 4 vCPU' -ForegroundColor DarkGray
        if (-not (Read-LabConfirm -Prompt '  Resumierbaren Hyper-V-Builder jetzt erzeugen?' -Default $false)) {
            return
        }

        $build = Initialize-HyperVWindowsImageBuild `
            -MediaRoot $mediaRoot `
            -OperatingSystemId $operatingSystemId `
            -Edition $edition `
            -InstallationType $installationType `
            -WindowsMediaPath $windowsMediaPath `
            -LicenseType evaluation
        Write-LabSuccess "Builder erstellt. BuildId: $($build.buildId)"
        Show-LabHyperVManualInstallInstructions -Build $build

        if (Read-LabConfirm -Prompt '  Builder starten und VMConnect oeffnen?' -Default $true) {
            Open-LabHyperVImageBuildConsole -Build $build
            Start-Sleep -Milliseconds 1500
            $null = Start-HyperVWindowsImageBuildVM -BuildId $build.buildId
        }
    }
    catch {
        Write-LabError $_.Exception.Message
    }
}

function Show-LabHyperVManualInstallInstructions {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Build)

    Write-Host ''
    Write-Host '  Manuelle Windows-Installation:' -ForegroundColor Yellow
    Write-Host "    1. VM '$($Build.builder.vmName)' in VMConnect oeffnen." -ForegroundColor White
    Write-Host "    2. $($Build.operatingSystem.edition) mit '$($Build.operatingSystem.installationType)' auswaehlen." -ForegroundColor White
    Write-Host '    3. Benutzerdefinierte Installation auf die einzige leere OS-Disk ausfuehren.' -ForegroundColor White
    Write-Host '    4. Ein lokales Administrator-Passwort setzen und sicher verwahren.' -ForegroundColor White
    Write-Host '    5. Nach dem ersten vollstaendigen Login zum Image-Menue zurueckkehren.' -ForegroundColor White
    Write-Host '  Der Builder besitzt absichtlich keinen Netzwerkadapter.' -ForegroundColor DarkGray
}

function Open-LabHyperVImageBuildConsole {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Build)

    $vmConnect = Join-Path $env:SystemRoot 'System32/vmconnect.exe'
    if (-not (Test-Path -LiteralPath $vmConnect -PathType Leaf)) {
        Write-LabWarning "VMConnect nicht gefunden. Manuell verbinden mit VM: $($Build.builder.vmName)"
        return
    }
    Start-Process -FilePath $vmConnect `
        -ArgumentList @($env:COMPUTERNAME, [string]$Build.builder.vmName)
}

function Start-LabHyperVImageBuildInteractive {
    [CmdletBinding()]
    param()

    $build = Select-LabHyperVImageBuild -AllowedStates @('BUILDER_READY', 'MANUAL_ACTION_REQUIRED')
    if (-not $build) { return }
    try {
        Show-LabHyperVManualInstallInstructions -Build $build
        Open-LabHyperVImageBuildConsole -Build $build
        Start-Sleep -Milliseconds 1500
        $null = Start-HyperVWindowsImageBuildVM -BuildId $build.buildId
    }
    catch { Write-LabError $_.Exception.Message }
}

function Invoke-LabHyperVImageGeneralizationInteractive {
    [CmdletBinding()]
    param()

    $build = Select-LabHyperVImageBuild -AllowedStates @('MANUAL_ACTION_REQUIRED', 'REBOOT_REQUIRED')
    if (-not $build) { return }
    $credential = $null
    if ($build.state -eq 'MANUAL_ACTION_REQUIRED') {
        $userName = Read-Host '  Lokaler Gast-Administrator [Administrator]'
        if (-not $userName) { $userName = 'Administrator' }
        $password = Read-Host '  Gastpasswort' -AsSecureString
        $credential = [PSCredential]::new($userName, $password)
        try {
            $build = Confirm-HyperVWindowsImageInstallation `
                -BuildId $build.buildId `
                -Credential $credential
        }
        catch {
            if ($_.Exception.Message -notmatch '^HYPERV_IMAGE_INSTALLATION_TYPE_MISMATCH:') {
                Write-LabError $_.Exception.Message
                return
            }
            Write-LabWarning $_.Exception.Message
            if (-not (Read-LabConfirm -Prompt '  Erkannten Installationstyp fuer diesen Build uebernehmen?' -Default $false)) {
                return
            }
            try {
                $build = Confirm-HyperVWindowsImageInstallation `
                    -BuildId $build.buildId `
                    -Credential $credential `
                    -AcceptDetectedInstallationType
            }
            catch {
                Write-LabError $_.Exception.Message
                return
            }
        }
        Write-LabSuccess ("Windows verifiziert: {0}, {1}, Build {2}" -f `
            $build.installationEvidence.editionId,
            $build.installationEvidence.installationType,
            $build.installationEvidence.currentBuild)
    }
    if (-not (Read-LabConfirm -Prompt '  Sysprep /generalize ausfuehren und Gast herunterfahren?' -Default $false)) {
        return
    }
    try {
        $result = Invoke-HyperVWindowsImageGeneralization `
            -BuildId $build.buildId `
            -Credential $credential
        Write-LabSuccess "Generalisierung verifiziert. State: $($result.state)"
    }
    catch { Write-LabError $_.Exception.Message }
}

function Publish-LabHyperVImageBuildInteractive {
    [CmdletBinding()]
    param()

    $build = Select-LabHyperVImageBuild -AllowedStates @('RESUME_PENDING')
    if (-not $build) { return }
    $expiry = $null
    if ($build.license.type -eq 'evaluation') {
        $defaultExpiry = (Get-Date).Date.AddDays(180).ToString('yyyy-MM-dd')
        $expiryInput = Read-Host "  Evaluation endet am [$defaultExpiry]"
        if (-not $expiryInput) { $expiryInput = $defaultExpiry }
        $parsedExpiry = [datetime]::MinValue
        if (-not [datetime]::TryParseExact($expiryInput, 'yyyy-MM-dd', $null, 'AssumeLocal', [ref]$parsedExpiry)) {
            Write-LabError 'Datum muss YYYY-MM-DD entsprechen.'
            return
        }
        $expiry = $parsedExpiry
    }
    if (-not (Read-LabConfirm -Prompt '  Generalisierte VHDX immutable in der Registry veroeffentlichen?' -Default $false)) {
        return
    }
    try {
        $result = Publish-HyperVWindowsImageBuild `
            -BuildId $build.buildId `
            -EvaluationExpiresAt $expiry
        Write-LabSuccess "Image veroeffentlicht. ArtifactId: $($result.Artifact.artifactId)"
    }
    catch { Write-LabError $_.Exception.Message }
}

function Remove-LabHyperVImageBuildInteractive {
    [CmdletBinding()]
    param()

    $allowedStates = @(
        'MEDIA_VERIFIED', 'BUILDER_READY', 'MANUAL_ACTION_REQUIRED', 'REBOOT_REQUIRED', 'RESUME_PENDING', 'FAILED'
    )
    $builds = @(Get-HyperVImageBuildPlans | Where-Object state -In $allowedStates)
    if ($builds.Count -eq 0) { Write-LabInfo 'Kein unfertiger Windows-Image-Builder vorhanden.'; return }

    Write-Host ''
    for ($i = 0; $i -lt $builds.Count; $i++) {
        Write-Host "    [$($i + 1)] Windows [$($builds[$i].state)] $($builds[$i].buildId)" -ForegroundColor White
    }
    Write-Host "    [ALL] Alle $($builds.Count) angezeigten unfertigen Windows-Builder aufraeumen" -ForegroundColor Yellow
    $selection = Read-Host '  Build (Nummer oder ALL)'
    if ($selection -ieq 'ALL') {
        Write-LabWarning "Alle $($builds.Count) angezeigten Builder inklusive VMs und buildlokaler VHDX werden entfernt."
        if (-not (Read-LabConfirm -Prompt '  WIRKLICH ALLE Windows-Builder aufraeumen?' -Default $false)) { return }
        $succeeded = 0; $failed = 0
        foreach ($candidate in $builds) {
            Write-LabInfo "Cleanup $($succeeded + $failed + 1)/$($builds.Count): $($candidate.buildId)"
            try {
                $result = Remove-HyperVWindowsImageBuild -BuildId $candidate.buildId
                if ($result.Status -eq 'CLEANUP_SUCCEEDED') { $succeeded++ }
                else { $failed++; Write-LabError "$($candidate.buildId): Cleanup-Status $($result.Status)" }
            }
            catch { $failed++; Write-LabError "$($candidate.buildId): $($_.Exception.Message)" }
        }
        if ($failed -eq 0) { Write-LabSuccess "Alle $succeeded Windows-Builder-Ressourcen wurden entfernt." }
        else { Write-LabWarning "Cleanup abgeschlossen: $succeeded erfolgreich, $failed fehlgeschlagen." }
        return
    }
    if ($selection -notmatch '^\d+$' -or [int]$selection -lt 1 -or [int]$selection -gt $builds.Count) {
        Write-LabWarning 'Ungueltige Auswahl.'; return
    }
    $build = $builds[[int]$selection - 1]
    Write-LabWarning "VM und buildlokale VHDX von '$($build.buildId)' werden entfernt."
    if (-not (Read-LabConfirm -Prompt '  Builder wirklich aufraeumen?' -Default $false)) { return }
    try {
        $result = Remove-HyperVWindowsImageBuild -BuildId $build.buildId
        if ($result.Status -eq 'CLEANUP_SUCCEEDED') {
            Write-LabSuccess 'Builder-Ressourcen wurden entfernt und aus der offenen Liste ausgeblendet.'
        }
        else {
            Write-LabError "Cleanup-Status: $($result.Status)"
        }
    }
    catch { Write-LabError $_.Exception.Message }
}

function Show-LabHyperVSqlImageBuilds {
    [CmdletBinding()]
    param()

    $builds = @(Get-HyperVSqlImageBuildPlans)
    if ($builds.Count -eq 0) {
        Write-LabInfo 'Keine Hyper-V-SQL-Image-Builds vorhanden.'
        return @()
    }
    Write-Host ''
    Write-Host '  SQL-Image-Builds:' -ForegroundColor White
    for ($i = 0; $i -lt $builds.Count; $i++) {
        $build = $builds[$i]
        $vmName = if ($build.builder) { [string]$build.builder.vmName } else { '-' }
        Write-Host ("    [{0}] {1}  {2}" -f ($i + 1), $build.buildId, $build.state) -ForegroundColor White
        Write-Host ("        SQL {0} {1} | VM: {2} | Parent: {3}" -f `
            $build.sql.version, $build.sql.edition, $vmName, $build.parentArtifact.artifactId) -ForegroundColor DarkGray
        Write-Host ("        Naechster Schritt: {0}" -f (Get-LabHyperVSqlImageNextStep -Build $build)) -ForegroundColor Yellow
    }
    return $builds
}

function Get-LabHyperVSqlImageNextStep {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Build)

    $isFreshPreparedImage = [string]$Build.provisioningMode -eq 'fresh-windows-media'
    switch ([string]$Build.state) {
        'MANUAL_ACTION_REQUIRED' {
            if ($isFreshPreparedImage) { return 'Prepared-Image-Builder fortsetzen: VMConnect öffnen, Windows installieren und einmal als Administrator anmelden.' }
            return 'Prepared-Image-Builder fortsetzen: VMConnect öffnen, OOBE der OS-Baseline abschließen und danach SQL PrepareImage ausführen.'
        }
        'OOBE_AUTOMATION_RUNNING' { return 'Erweitert -> Abnahmeumgebung öffnen und den OOBE-Fortschritt fortsetzen.' }
        'OOBE_COMPLETED' { return 'Erweitert -> Abnahmeumgebung: vollständiges SQL installieren.' }
        'REBOOT_REQUIRED' { return 'Prepared-Image-Builder fortsetzen: VM booten; danach SQL PrepareImage erneut ausführen.' }
        'RESUME_PENDING' { return 'Prepared-Image-Builder fortsetzen: Prepared-Image jetzt veröffentlichen.' }
        'SQL_INSTALL_RUNNING' { return 'Erweitert -> Abnahmeumgebung erneut aufrufen; der Installationsfortschritt wird fortgesetzt.' }
        'SQL_INSTALL_REBOOT_REQUIRED' { return 'Erweitert -> Abnahmeumgebung: VM booten und SQL-Setup fortsetzen.' }
        'SQL_READY_RUN' { return 'Erweitert -> Abnahmeumgebung: SQL-Abnahmetest ausführen.' }
        'TESTS_PASSED' { return 'Fertig. Bei Bedarf den run-lokalen Abnahme-Builder aufräumen.' }
        'SQL_PREPARED_SEALED' { return 'Fertig. Das immutable Prepared-Image wurde veroeffentlicht.' }
        'FAILED' { return 'Fehler prüfen; nach fehlgeschlagenem Sysprep im Prepared-Image-Builder die Offline-Recovery wählen, andernfalls aufräumen.' }
        default { return 'Builder-Status prüfen oder den zuletzt ausgegebenen Hinweis befolgen.' }
    }
}

function Show-LabHyperVSqlNextActions {
    [CmdletBinding()]
    param()

    $builds = @(Get-HyperVSqlImageBuildPlans | Where-Object {
        [string]$_.state -notin @('SQL_PREPARED_SEALED', 'TESTS_PASSED')
    })
    if ($builds.Count -eq 0) { return }
    Write-Host ''
    Write-Host '    Offene SQL-Builder – naechster Schritt:' -ForegroundColor Cyan
    foreach ($build in $builds) {
        $shortId = ([string]$build.buildId).Substring(0, 8)
        Write-Host ("      SQL {0} ({1}...): {2}" -f $build.sql.version, $shortId, (Get-LabHyperVSqlImageNextStep -Build $build)) -ForegroundColor Yellow
    }
}

function Select-LabHyperVSqlImageBuild {
    [CmdletBinding()]
    param(
        [string[]]$AllowedStates = @(),
        [switch]$RequireExistingVm
    )

    $builds = @(Get-HyperVSqlImageBuildPlans)
    if ($AllowedStates.Count -gt 0) { $builds = @($builds | Where-Object state -In $AllowedStates) }
    if ($RequireExistingVm) {
        $availableBuilds = [System.Collections.Generic.List[object]]::new()
        foreach ($candidate in $builds) {
            if (-not $candidate.builder -or -not [string]$candidate.builder.vmName) { continue }
            try {
                $managed = Get-HyperVManagedVM -VMName ([string]$candidate.builder.vmName) `
                    -ExpectedRunId ([string]$candidate.buildId) -ExpectedScopeId ([string]$candidate.scopeId)
                if ($managed) { $availableBuilds.Add($candidate) }
            }
            catch { }
        }
        $builds = @($availableBuilds)
    }
    if ($builds.Count -eq 0) { Write-LabInfo 'Kein passender SQL-Image-Build vorhanden.'; return $null }
    if ($builds.Count -eq 1) { return $builds[0] }
    Write-Host ''
    for ($i = 0; $i -lt $builds.Count; $i++) {
        Write-Host "    [$($i + 1)] SQL $($builds[$i].sql.version) [$($builds[$i].state)] $($builds[$i].buildId)" -ForegroundColor White
    }
    $selection = Read-Host '  Build (Nummer)'
    if ($selection -notmatch '^\d+$' -or [int]$selection -lt 1 -or [int]$selection -gt $builds.Count) {
        Write-LabWarning 'Ungueltige Auswahl.'; return $null
    }
    return $builds[[int]$selection - 1]
}

function Rename-LabHyperVImageArtifactInteractive {
    [CmdletBinding()]
    param()

    # Die Auswahl darf nicht jede große Parent-VHDX erneut hashen. Die
    # referenzgeprüfte Entfernung validiert Besitz und Ziel anschließend
    # selbst; für die Anzeige reicht die lokale Registry.
    $artifacts = @(Get-HyperVImageArtifact -SkipIntegrityCheck | Where-Object { $_.artifactState -in @('OS_SEALED', 'SQL_PREPARED_SEALED') })
    if ($artifacts.Count -eq 0) {
        Write-LabInfo 'Keine veröffentlichten OS- oder SQL-Images vorhanden.'
        return
    }
    Write-Host '  Veröffentlichte Images:' -ForegroundColor White
    for ($i = 0; $i -lt $artifacts.Count; $i++) {
        $artifact = $artifacts[$i]
        $fallback = if ($artifact.artifactState -eq 'SQL_PREPARED_SEALED') {
            "SQL Server $($artifact.sql.version) · $($artifact.sql.edition)"
        } else {
            "$($artifact.operatingSystem.id) · $($artifact.operatingSystem.edition)"
        }
        $name = if ($artifact.displayName) { [string]$artifact.displayName } else { $fallback }
        Write-Host ("    [{0}] {1}" -f ($i + 1), $name) -ForegroundColor White
        Write-Host ("        {0}" -f $artifact.artifactId) -ForegroundColor DarkGray
    }
    $selection = Read-Host '  Image (Nummer)'
    if ($selection -notmatch '^\d+$' -or [int]$selection -lt 1 -or [int]$selection -gt $artifacts.Count) {
        Write-LabWarning 'Keine gültige Image-Auswahl.'
        return
    }
    $newName = Read-Host '  Neuer Anzeigename'
    if ([string]::IsNullOrWhiteSpace($newName)) { Write-LabWarning 'Ein Name ist erforderlich.'; return }
    if ($newName.Trim().Length -gt 80) { Write-LabWarning 'Der Name darf höchstens 80 Zeichen enthalten.'; return }
    try {
        $renamed = Rename-HyperVImageArtifact -ArtifactId $artifacts[[int]$selection - 1].artifactId -DisplayName $newName
        Write-LabSuccess "Image-Name gespeichert: $($renamed.displayName)"
    }
    catch { Write-LabError $_.Exception.Message }
}

function Remove-LabHyperVImageArtifactInteractive {
    <#
    .SYNOPSIS Entfernt ein veröffentlichtes Hyper-V-Image nach expliziter Auswahl.
    .DESCRIPTION Die Registry verweigert die Entfernung weiterhin, solange ein
    aktiver Builder oder Lab-Run das immutable Parent-Image referenziert.
    #>
    [CmdletBinding()]
    param()

    # Die Auswahl darf nicht jede große Parent-VHDX erneut hashen. Die
    # referenzgeprüfte Entfernung validiert Besitz und Ziel anschließend
    # selbst; für die Anzeige reicht die lokale Registry.
    $artifacts = @(Get-HyperVImageArtifact -SkipIntegrityCheck | Where-Object { $_.artifactState -in @('OS_SEALED', 'SQL_PREPARED_SEALED') })
    if ($artifacts.Count -eq 0) {
        Write-LabInfo 'Keine veröffentlichten OS- oder SQL-Images vorhanden.'
        return
    }
    Write-Host '  Veröffentlichte Images:' -ForegroundColor White
    for ($i = 0; $i -lt $artifacts.Count; $i++) {
        $artifact = $artifacts[$i]
        $label = if ($artifact.displayName) { [string]$artifact.displayName } else { [string]$artifact.artifactId }
        Write-Host ("    [{0}] {1} · {2} · {3}" -f ($i + 1), $artifact.artifactState, $label, $artifact.artifactId) -ForegroundColor White
    }
    Write-Host '    [ALL] Alle oben angezeigten Images löschen' -ForegroundColor Red
    $selection = Read-Host '  Image auswählen'
    if ([string]::IsNullOrWhiteSpace($selection)) { return }
    $selected = if ($selection -ieq 'ALL') { @($artifacts) }
    elseif ($selection -match '^\d+$' -and [int]$selection -ge 1 -and [int]$selection -le $artifacts.Count) { @($artifacts[[int]$selection - 1]) }
    else { Write-LabWarning 'Ungültige Auswahl.'; return }

    $countText = if ($selected.Count -eq 1) { 'dieses Image' } else { "alle $($selected.Count) Images" }
    Write-LabWarning "Es werden $countText inklusive ihrer schreibgeschützten Parent-VHDX entfernt. Referenzierte Images werden sicher übersprungen."
    if (-not (Read-LabConfirm -Prompt '  Wirklich löschen?' -Default $false)) { return }
    $removed = 0; $blocked = 0
    foreach ($artifact in $selected) {
        try {
            Remove-HyperVImageArtifact -ArtifactId ([string]$artifact.artifactId) | Out-Null
            $removed++
            Write-LabSuccess "Image entfernt: $($artifact.artifactId)"
        }
        catch {
            $blocked++
            Write-LabWarning "Image nicht entfernt: $($artifact.artifactId) – $($_.Exception.Message)"
        }
    }
    if ($blocked -eq 0) { Write-LabSuccess "$removed Image(s) entfernt." }
    else { Write-LabWarning "Löschen abgeschlossen: $removed entfernt, $blocked nicht entfernt." }
}

function Select-LabHyperVOsArtifact {
    [CmdletBinding()]
    param()

    $artifacts = @(Get-HyperVImageArtifact -SkipIntegrityCheck | Where-Object {
        $_.artifactState -eq 'OS_SEALED' -and $_.operatingSystem.id -eq 'windows-server-2025'
    })
    if ($artifacts.Count -eq 0) { Write-LabError 'Keine Windows-Server-2025-OS_SEALED-Baseline vorhanden.'; return $null }
    if ($artifacts.Count -eq 1) { return $artifacts[0] }
    Write-Host ''
    for ($i = 0; $i -lt $artifacts.Count; $i++) {
        Write-Host "    [$($i + 1)] $($artifacts[$i].operatingSystem.edition) / $($artifacts[$i].operatingSystem.installationType)" -ForegroundColor White
        Write-Host "        $($artifacts[$i].artifactId)" -ForegroundColor DarkGray
    }
    $selection = Read-Host '  OS-Baseline (Nummer)'
    if ($selection -notmatch '^\d+$' -or [int]$selection -lt 1 -or [int]$selection -gt $artifacts.Count) {
        Write-LabWarning 'Ungueltige Auswahl.'; return $null
    }
    return $artifacts[[int]$selection - 1]
}

function Show-LabHyperVSqlManualInstructions {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Build)

    Write-Host ''
    if ([string]$Build.provisioningMode -eq 'fresh-windows-media') {
        Write-Host '  Frische Windows-Installation fuer das SQL-Prepared-Image:' -ForegroundColor Yellow
        Write-Host "    VM: $($Build.builder.vmName)" -ForegroundColor White
        Write-Host '    1. Windows Server 2025 in VMConnect auf der leeren OS-Disk installieren.' -ForegroundColor White
        $editionLabel = if ([string]$Build.operatingSystem.edition -eq 'standard-evaluation') { 'Windows Server 2025 Standard Evaluation' } else { 'Windows Server 2025 Datacenter Evaluation' }
        $typeLabel = if ([string]$Build.operatingSystem.installationType -eq 'core') { 'Server Core Installation' } else { 'Desktop Experience' }
        Write-Host "    2. Im Windows-Setup exakt '$editionLabel ($typeLabel)' auswählen und OOBE abschließen." -ForegroundColor White
        Write-Host '    3. Lokales Administratorpasswort setzen und einmal anmelden.' -ForegroundColor White
        Write-Host '    4. Zurueck im Image-Menue Aktion 10 waehlen: SQL PrepareImage und genau ein finaler Windows-Sysprep.' -ForegroundColor White
        Write-Host '  Die zweite DVD enthaelt bereits die verifizierte SQL-ISO; sie wird von Aktion 10 verwendet.' -ForegroundColor DarkGray
        return
    }
    Write-Host '  SQL-Prepared-Image aus OS-Baseline:' -ForegroundColor Yellow
    Write-Host "    VM: $($Build.builder.vmName)" -ForegroundColor White
    Write-Host '    1. VMConnect öffnen, die kurze OOBE der OS-Baseline abschließen und lokales Administratorpasswort setzen.' -ForegroundColor White
    Write-Host '    2. Zurück im Image-Menü Aktion 10 wählen: SQL PrepareImage und genau ein finaler Windows-Sysprep.' -ForegroundColor White
    Write-Host '  Windows wird nicht erneut installiert: Die OS-Baseline bleibt unverändert, der Builder verwendet nur eine eigene differenzierende VHDX.' -ForegroundColor DarkGray
}

function Select-LabSqlInstallationMedia {
    <#
    .SYNOPSIS
        Wählt ein tatsächlich vorhandenes SQL-Installationsmedium aus dem Media Root.
    .DESCRIPTION
        Die Auswahl leitet Version und Medienedition direkt aus dem Pfad der ISO
        ab. Damit funktionieren auch Developer-, Enterprise_Developer- und
        Standard_Developer-Ordner, ohne dass der Benutzer einen künstlichen
        Verzeichnisnamen eingeben muss.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$MediaRoot)

    $sqlRoot = Join-Path $MediaRoot 'SQL'
    if (-not (Test-Path -LiteralPath $sqlRoot -PathType Container)) {
        Write-LabError "SQL-Medienverzeichnis nicht gefunden: $sqlRoot"
        return $null
    }

    $choices = @(
        Get-ChildItem -LiteralPath $sqlRoot -File -Recurse -Filter '*.iso' -ErrorAction SilentlyContinue |
            ForEach-Object {
                $mediaId = [IO.Path]::GetRelativePath($MediaRoot, $_.FullName).Replace('\', '/')
                if ($mediaId -notmatch '^SQL/(?<version>\d{4})/') { return }
                $edition = Get-HyperVSqlMediaEditionFromPath -Path $mediaId
                if (-not $edition) { return }
                [PSCustomObject]@{
                    SqlVersion = $Matches.version
                    MediaEdition = $edition
                    MediaId = $mediaId
                    FileName = $_.Name
                }
            } |
            Sort-Object @{ Expression = { [int]$_.SqlVersion }; Descending = $true }, MediaEdition, FileName
    )
    if ($choices.Count -eq 0) {
        Write-LabError "Keine SQL-ISOs unter $sqlRoot gefunden. Erwartet werden z. B. SQL/2025/Enterprise_Developer/ISO/*.iso."
        return $null
    }

    $versions = @($choices.SqlVersion | Select-Object -Unique | Sort-Object { [int]$_ } -Descending)
    $defaultVersion = $versions[0]
    Write-Host "  Verfügbare SQL Server Versionen: $($versions -join ', ')" -ForegroundColor White
    $sqlVersion = Read-Host "  SQL Server Version [$defaultVersion]"
    if (-not $sqlVersion) { $sqlVersion = $defaultVersion }
    if ($sqlVersion -notin $versions) {
        Write-LabError "SQL-Version ist nicht als ISO verfügbar: $sqlVersion"
        return $null
    }

    $versionChoices = @($choices | Where-Object SqlVersion -eq $sqlVersion)
    Write-Host '  Verfügbare SQL-Installationsmedien:' -ForegroundColor White
    for ($i = 0; $i -lt $versionChoices.Count; $i++) {
        $choice = $versionChoices[$i]
        Write-Host ("    [{0}] {1} · {2}" -f ($i + 1), $choice.MediaEdition, $choice.MediaId) -ForegroundColor White
    }
    $selection = Read-Host '  SQL-Installationsmedium (Nummer) [1]'
    if (-not $selection) { $selection = '1' }
    if ($selection -notmatch '^\d+$' -or [int]$selection -lt 1 -or [int]$selection -gt $versionChoices.Count) {
        Write-LabError 'Ungültige SQL-Medienauswahl.'
        return $null
    }
    return $versionChoices[[int]$selection - 1]
}

function New-LabHyperVSqlImageBuildInteractive {
    [CmdletBinding()]
    param()

    $defaultRoot = Get-LabMediaRootDefault
    $mediaRoot = Read-Host $(if ($defaultRoot) { "  Media Root [$defaultRoot]" } else { '  Media Root' })
    if (-not $mediaRoot) { $mediaRoot = $defaultRoot }
    if (-not $mediaRoot) { Write-LabError 'Media Root ist erforderlich.'; return }
    try { $mediaRoot = Set-LabMediaRootDefault -MediaRoot $mediaRoot }
    catch { Write-LabError "Media Root ist ungueltig: $($_.Exception.Message)"; return }

    $windowsCandidates = @(Get-HyperVWindowsInstallationMediaCandidates -MediaRoot $mediaRoot | Where-Object { $_.State -eq 'READY' -and $_.OperatingSystemId -eq 'windows-server-2025' })
    if ($windowsCandidates.Count -eq 0) { Write-LabError 'Kein erkanntes Windows Server 2025-Installationsmedium vorhanden.'; return }
    Write-Host '  Erkannte Windows-Installationsvarianten:' -ForegroundColor White
    for ($i = 0; $i -lt $windowsCandidates.Count; $i++) {
        $candidate = $windowsCandidates[$i]
        Write-Host ("    [{0}] {1} · {2} · {3}" -f ($i + 1), $candidate.ImageName, $candidate.WindowsEdition, $candidate.MediaId) -ForegroundColor White
    }
    $windowsSelection = Read-Host '  Windows-Variante (Nummer) [1]'
    if (-not $windowsSelection) { $windowsSelection = '1' }
    if ($windowsSelection -notmatch '^\d+$' -or [int]$windowsSelection -lt 1 -or [int]$windowsSelection -gt $windowsCandidates.Count) { Write-LabError 'Ungültige Windows-Medienauswahl.'; return }
    $selectedWindowsMedia = $windowsCandidates[[int]$windowsSelection - 1]
    $windowsEdition = [string]$selectedWindowsMedia.WindowsEdition
    $installationType = [string]$selectedWindowsMedia.InstallationType
    $windowsMediaPath = [string]$selectedWindowsMedia.MediaId
    $selectedSqlMedia = Select-LabSqlInstallationMedia -MediaRoot $mediaRoot
    if (-not $selectedSqlMedia) { return }
    $sqlVersion = [string]$selectedSqlMedia.SqlVersion
    $mediaEdition = [string]$selectedSqlMedia.MediaEdition
    $sqlMediaPath = [string]$selectedSqlMedia.MediaId
    $imageName = Read-Host '  Frei wählbarer Image-Name (optional)'
    if ($imageName -and $imageName.Trim().Length -gt 80) { Write-LabError 'Der Image-Name darf höchstens 80 Zeichen enthalten.'; return }

    try {
        $windowsMedia = Resolve-HyperVWindowsInstallationMedia -MediaRoot $mediaRoot -OperatingSystemId windows-server-2025 -WindowsMediaPath $windowsMediaPath -WindowsEdition $windowsEdition -InstallationType $installationType
        if ($windowsMedia.HashStatus -eq 'MISSING') {
            Write-LabWarning 'Fuer die Windows-ISO existiert noch kein SHA-256-Sidecar.'
            if (-not (Read-LabConfirm -Prompt '  Windows-SHA-256 jetzt berechnen und lokal festschreiben?' -Default $false)) { return }
            Write-LabInfo 'Windows-SHA-256 wird berechnet; grosse ISOs benoetigen mehrere Minuten.'
            $windowsMedia = New-HyperVWindowsMediaHashSidecar -MediaRoot $mediaRoot -OperatingSystemId windows-server-2025 -WindowsMediaPath $windowsMediaPath -WindowsEdition $windowsEdition -InstallationType $installationType
        }
        $sqlMedia = Resolve-HyperVSqlInstallationMedia -MediaRoot $mediaRoot -SqlVersion $sqlVersion -MediaEdition $mediaEdition -SqlMediaPath $sqlMediaPath
        if ($sqlMedia.HashStatus -eq 'MISSING') {
            Write-LabWarning 'Fuer die SQL-ISO existiert noch kein SHA-256-Sidecar.'
            if (-not (Read-LabConfirm -Prompt '  SQL-SHA-256 jetzt berechnen und lokal festschreiben?' -Default $false)) { return }
            Write-LabInfo 'SQL-SHA-256 wird berechnet; grosse ISOs benoetigen mehrere Minuten.'
            $sqlMedia = New-HyperVSqlMediaHashSidecar -MediaRoot $mediaRoot -SqlVersion $sqlVersion -MediaEdition $mediaEdition -SqlMediaPath $sqlMediaPath
        }
        Write-Host ''
        Write-Host "  Windows: Windows Server 2025 / $windowsEdition / $installationType" -ForegroundColor DarkGray
        Write-Host "  SQL:     $sqlVersion $mediaEdition; SQLENGINE, FULLTEXT, REPLICATION" -ForegroundColor DarkGray
        Write-Host '  Ablauf: Windows installieren -> SQL PrepareImage -> ein finaler Sysprep.' -ForegroundColor Yellow
        if (-not (Read-LabConfirm -Prompt '  Frischen SQL-Prepared-Image-Builder jetzt erzeugen?' -Default $false)) { return }
        $build = Initialize-HyperVSqlFreshPreparedImageBuild -MediaRoot $mediaRoot -OperatingSystemId windows-server-2025 `
            -WindowsEdition $windowsEdition -InstallationType $installationType -WindowsMediaPath $windowsMediaPath -SqlVersion $sqlVersion -MediaEdition $mediaEdition -SqlMediaPath $sqlMediaPath -ImageName $imageName
        Write-LabSuccess "Frischer SQL-Builder erstellt. BuildId: $($build.buildId)"
        Show-LabHyperVSqlManualInstructions -Build $build
        if (Read-LabConfirm -Prompt '  Builder starten und VMConnect oeffnen?' -Default $true) {
            Open-LabHyperVImageBuildConsole -Build $build
            Start-Sleep -Milliseconds 1500
            $null = Start-HyperVSqlImageBuildVM -BuildId $build.buildId
        }
    }
    catch { Write-LabError $_.Exception.Message }
}

function New-LabHyperVSqlAcceptanceBuildInteractive {
    [CmdletBinding()]
    param()

    $defaultRoot = Get-LabMediaRootDefault
    $mediaRoot = Read-Host $(if ($defaultRoot) { "  Media Root [$defaultRoot]" } else { '  Media Root' })
    if (-not $mediaRoot) { $mediaRoot = $defaultRoot }
    if (-not $mediaRoot) { Write-LabError 'Media Root ist erforderlich.'; return }
    try { $mediaRoot = Set-LabMediaRootDefault -MediaRoot $mediaRoot }
    catch { Write-LabError "Media Root ist ungueltig: $($_.Exception.Message)"; return }
    $selectedSqlMedia = Select-LabSqlInstallationMedia -MediaRoot $mediaRoot
    if (-not $selectedSqlMedia) { return }
    $sqlVersion = [string]$selectedSqlMedia.SqlVersion
    $mediaEdition = [string]$selectedSqlMedia.MediaEdition
    $sqlMediaPath = [string]$selectedSqlMedia.MediaId
    $artifact = Select-LabHyperVOsArtifact
    if (-not $artifact) { return }
    $imageName = Read-Host '  Frei wählbarer Image-Name (optional)'
    if ($imageName -and $imageName.Trim().Length -gt 80) { Write-LabError 'Der Image-Name darf höchstens 80 Zeichen enthalten.'; return }

    try {
        $media = Resolve-HyperVSqlInstallationMedia -MediaRoot $mediaRoot -SqlVersion $sqlVersion -MediaEdition $mediaEdition -SqlMediaPath $sqlMediaPath
        if ($media.HashStatus -eq 'MISSING') {
            Write-LabWarning 'Fuer die SQL-ISO existiert noch kein SHA-256-Sidecar.'
            Write-Host "  ISO: $($media.IsoPath)" -ForegroundColor DarkGray
            if (-not (Read-LabConfirm -Prompt '  SHA-256 jetzt berechnen und lokal festschreiben?' -Default $false)) { return }
            $media = New-HyperVSqlMediaHashSidecar -MediaRoot $mediaRoot -SqlVersion $sqlVersion -MediaEdition $mediaEdition -SqlMediaPath $sqlMediaPath
        }
        Write-Host "  Parent: $($artifact.artifactId)" -ForegroundColor DarkGray
        Write-Host "  SQL:    $sqlVersion $mediaEdition; SQLENGINE, FULLTEXT, REPLICATION" -ForegroundColor DarkGray
        Write-Host '  Die OS-Baseline bleibt unverändert; Windows wird nicht erneut installiert.' -ForegroundColor DarkGray
        Write-Host '  Die Evaluation-Ablaufzeit der OS-Baseline wird in das neue Artifact übernommen.' -ForegroundColor DarkGray
        if (-not (Read-LabConfirm -Prompt '  SQL-Prepared-Image-Builder aus OS-Baseline jetzt erzeugen?' -Default $false)) { return }
        $build = Initialize-HyperVSqlPreparedImageBuild -MediaRoot $mediaRoot -ImageArtifactId $artifact.artifactId `
            -SqlVersion $sqlVersion -MediaEdition $mediaEdition -SqlMediaPath $sqlMediaPath -ImageName $imageName
        Write-LabSuccess "SQL-Prepared-Image-Builder aus OS-Baseline erstellt. BuildId: $($build.buildId)"
        Show-LabHyperVSqlManualInstructions -Build $build
        if (Read-LabConfirm -Prompt '  Builder starten und VMConnect oeffnen?' -Default $true) {
            Open-LabHyperVImageBuildConsole -Build $build
            Start-Sleep -Milliseconds 1500
            $null = Start-HyperVSqlImageBuildVM -BuildId $build.buildId
        }
    }
    catch { Write-LabError $_.Exception.Message }
}

function Start-LabHyperVSqlImageBuildInteractive {
    [CmdletBinding()]
    param()
    $build = Select-LabHyperVSqlImageBuild -AllowedStates @('MANUAL_ACTION_REQUIRED', 'REBOOT_REQUIRED') -RequireExistingVm
    if (-not $build) { return }
    Show-LabHyperVSqlManualInstructions -Build $build
    Open-LabHyperVImageBuildConsole -Build $build
    Start-Sleep -Milliseconds 1500
    try { $null = Start-HyperVSqlImageBuildVM -BuildId $build.buildId } catch { Write-LabError $_.Exception.Message }
}

function Confirm-LabHyperVSqlWindowsInstallationInteractive {
    [CmdletBinding()]
    param()

    $build = Select-LabHyperVSqlImageBuild -AllowedStates @('MANUAL_ACTION_REQUIRED') -RequireExistingVm
    if (-not $build) { return }
    if ([string]$build.provisioningMode -ne 'fresh-windows-media') {
        Write-LabInfo 'Diese Prüfung ist nur für frische Windows-ISO-basierte SQL-Prepared-Image-Builds erforderlich.'
        return
    }
    $userName = Read-Host '  Lokaler Gast-Administrator [Administrator]'
    if (-not $userName) { $userName = 'Administrator' }
    $password = Read-Host '  Gastpasswort' -AsSecureString
    $credential = [PSCredential]::new($userName, $password)
    try {
        $confirmed = Confirm-HyperVSqlFreshWindowsInstallation -Build $build -Credential $credential
        Write-LabSuccess ("Windows bestätigt: {0} / {1}. Jetzt Aktion 10 für SQL PrepareImage wählen." -f $confirmed.operatingSystem.edition, $confirmed.operatingSystem.installationType)
    }
    catch { Write-LabError $_.Exception.Message }
}

function Invoke-LabHyperVSqlPrepareInteractive {
    [CmdletBinding()]
    param()
    $build = Select-LabHyperVSqlImageBuild -AllowedStates @('MANUAL_ACTION_REQUIRED', 'REBOOT_REQUIRED') -RequireExistingVm
    if (-not $build) { return }
    Write-Host ''
    Write-Host ("  Ziel-Builder: SQL {0} {1} | VM: {2}" -f $build.sql.version, $build.sql.edition, $build.builder.vmName) -ForegroundColor Yellow
    Write-Host ("  Build-ID: {0}" -f $build.buildId) -ForegroundColor DarkGray
    $userName = Read-Host '  Lokaler Gast-Administrator [Administrator]'
    if (-not $userName) { $userName = 'Administrator' }
    $password = Read-Host '  Gastpasswort' -AsSecureString
    $credential = [PSCredential]::new($userName, $password)
    if (-not (Read-LabConfirm -Prompt '  SQL PrepareImage und anschliessend Windows-Sysprep ausfuehren?' -Default $false)) { return }
    try {
        $result = Invoke-HyperVSqlPrepareAndGeneralize -BuildId $build.buildId -Credential $credential
        if ($result.state -eq 'REBOOT_REQUIRED') {
            Write-LabInfo 'SQL Setup hat einen Neustart angefordert. Naechster Schritt: [9] booten, danach [10] erneut ausfuehren.'
        }
        elseif ($result.state -eq 'RESUME_PENDING') {
            Write-LabSuccess 'SQL PrepareImage und Sysprep sind fertig. Naechster Schritt: [11] Prepared-Image veroeffentlichen.'
        }
        else { Write-LabInfo "SQL-Schritt beendet. Naechster Schritt: $(Get-LabHyperVSqlImageNextStep -Build $result)" }
    }
    catch {
        Write-LabError $_.Exception.Message
        if ($_.Exception.Message -match '^WINDOWS_SYSPREP_STATE_INVALID: IMAGE_STATE_UNDEPLOYABLE') {
            Write-LabWarning 'Sysprep hat innerhalb des Wartefensters keinen finalen Zustand gemeldet. Aktion [17] prueft den ausgeschalteten Builder offline und zeigt gegebenenfalls die konkrete Sysprep-Ursache an. Den Builder davor nicht erneut starten.'
        }
    }
}

function Publish-LabHyperVSqlImageBuildInteractive {
    [CmdletBinding()]
    param()
    $build = Select-LabHyperVSqlImageBuild -AllowedStates @('RESUME_PENDING') -RequireExistingVm
    if (-not $build) { return }
    $expiry = $null
    if ([string]$build.license.type -eq 'evaluation' -and -not $build.parentArtifact.license.evaluationExpiresAt) {
        $defaultExpiry = (Get-Date).Date.AddDays(180).ToString('yyyy-MM-dd')
        $expiryInput = Read-Host "  Windows-Evaluation endet am [$defaultExpiry]"
        if (-not $expiryInput) { $expiryInput = $defaultExpiry }
        $parsedExpiry = [datetime]::MinValue
        if (-not [datetime]::TryParseExact($expiryInput, 'yyyy-MM-dd', $null, 'AssumeLocal', [ref]$parsedExpiry)) {
            Write-LabError 'Datum muss YYYY-MM-DD entsprechen.'; return
        }
        $expiry = $parsedExpiry
    }
    if (-not (Read-LabConfirm -Prompt '  SQL-Prepared-Image flatten und immutable veroeffentlichen?' -Default $false)) { return }
    try {
        $result = Publish-HyperVSqlPreparedImageBuild -BuildId $build.buildId -EvaluationExpiresAt $expiry
        Write-LabSuccess "SQL-Prepared-Image veroeffentlicht: $($result.Artifact.artifactId)"
    }
    catch { Write-LabError $_.Exception.Message }
}

function Remove-LabHyperVSqlImageBuildInteractive {
    [CmdletBinding()]
    param()
    $allowedStates = @(
        'MEDIA_VERIFIED', 'MANUAL_ACTION_REQUIRED', 'OOBE_AUTOMATION_RUNNING', 'OOBE_COMPLETED',
        'REBOOT_REQUIRED', 'RESUME_PENDING', 'SQL_INSTALL_RUNNING', 'SQL_INSTALL_REBOOT_REQUIRED', 'FAILED'
    )
    $builds = @(Get-HyperVSqlImageBuildPlans | Where-Object state -In $allowedStates)
    if ($builds.Count -eq 0) { Write-LabInfo 'Kein unfertiger SQL-Image-Builder vorhanden.'; return }

    Write-Host ''
    for ($i = 0; $i -lt $builds.Count; $i++) {
        Write-Host "    [$($i + 1)] SQL $($builds[$i].sql.version) [$($builds[$i].state)] $($builds[$i].buildId)" -ForegroundColor White
    }
    Write-Host "    [ALL] Alle $($builds.Count) angezeigten unfertigen SQL-Builder aufraeumen" -ForegroundColor Yellow
    $selection = Read-Host '  Build (Nummer oder ALL)'
    if ($selection -ieq 'ALL') {
        Write-LabWarning "Alle $($builds.Count) angezeigten Builder inklusive VMs und buildlokaler VHDX werden entfernt."
        if (-not (Read-LabConfirm -Prompt '  WIRKLICH ALLE SQL-Builder aufraeumen?' -Default $false)) { return }
        $succeeded = 0; $failed = 0
        foreach ($build in $builds) {
            Write-LabInfo "Cleanup $($succeeded + $failed + 1)/$($builds.Count): $($build.buildId)"
            try {
                $result = Remove-HyperVSqlImageBuild -BuildId $build.buildId
                if ($result.Status -eq 'CLEANUP_SUCCEEDED') { $succeeded++ }
                else { $failed++; Write-LabError "$($build.buildId): Cleanup-Status $($result.Status)" }
            }
            catch { $failed++; Write-LabError "$($build.buildId): $($_.Exception.Message)" }
        }
        if ($failed -eq 0) { Write-LabSuccess "Alle $succeeded SQL-Builder-Ressourcen wurden entfernt." }
        else { Write-LabWarning "Cleanup abgeschlossen: $succeeded erfolgreich, $failed fehlgeschlagen." }
        return
    }
    if ($selection -notmatch '^\d+$' -or [int]$selection -lt 1 -or [int]$selection -gt $builds.Count) {
        Write-LabWarning 'Ungueltige Auswahl.'; return
    }
    $build = $builds[[int]$selection - 1]
    Write-LabWarning "VM und buildlokale VHDX von '$($build.buildId)' werden entfernt."
    if (-not (Read-LabConfirm -Prompt '  SQL-Builder wirklich aufraeumen?' -Default $false)) { return }
    try {
        $result = Remove-HyperVSqlImageBuild -BuildId $build.buildId
        if ($result.Status -eq 'CLEANUP_SUCCEEDED') { Write-LabSuccess 'SQL-Builder-Ressourcen wurden entfernt und aus der offenen Liste ausgeblendet.' }
        else { Write-LabError "Cleanup-Status: $($result.Status)" }
    }
    catch { Write-LabError $_.Exception.Message }
}

function Resume-LabHyperVSqlPreparedImageGeneralizationInteractive {
    [CmdletBinding()]
    param()

    $build = Select-LabHyperVSqlImageBuild -AllowedStates @('MANUAL_ACTION_REQUIRED') -RequireExistingVm
    if (-not $build) { return }
    if (-not $build.setupEvidence -or [string]$build.setupEvidence.action -ne 'PrepareImage') {
        Write-LabInfo 'Dieser Builder besitzt noch kein erfolgreiches SQL-PrepareImage und kann nicht offline uebernommen werden.'
        return
    }
    Write-LabWarning "Die VM '$($build.builder.vmName)' wird ausgeschaltet und ihr Windows-ImageState offline geprueft."
    Write-Host '  Diese Aktion ist nur fuer eine unterbrochene Wiederaufnahme nach SQL PrepareImage/Sysprep gedacht.' -ForegroundColor DarkGray
    if (-not (Read-LabConfirm -Prompt '  Offline-Wiederaufnahme jetzt ausfuehren?' -Default $false)) { return }
    try {
        $result = Resume-HyperVSqlPreparedImageGeneralization -BuildId $build.buildId
        Write-LabSuccess "Generalisierung offline verifiziert. State: $($result.state). Als Naechstes Aktion 11 waehlen."
    }
    catch { Write-LabError $_.Exception.Message }
}

function Invoke-LabHyperVSqlAcceptanceInstallInteractive {
    [CmdletBinding()]
    param()

    $build = Select-LabHyperVSqlImageBuild -AllowedStates @(
        'MANUAL_ACTION_REQUIRED', 'OOBE_AUTOMATION_RUNNING', 'OOBE_COMPLETED',
        'SQL_INSTALL_RUNNING', 'SQL_INSTALL_REBOOT_REQUIRED', 'SQL_READY_RUN', 'TESTS_PASSED'
    ) -RequireExistingVm
    if (-not $build) { return }
    if ([string]$build.provisioningMode -eq 'fresh-windows-media') {
        Write-LabInfo 'Dieser frische Builder ist fuer SQL PrepareImage bestimmt. Zuerst Windows manuell installieren, dann Aktion 10 waehlen.'
        return
    }
    Write-Host ("  Ziel: SQL {0} | VM {1}" -f $build.sql.version, $build.builder.vmName) -ForegroundColor White
    Write-Host '  Windows: Region Deutschland, UI en-US, Tastatur Deutsch, Zeitzone Wien/Berlin.' -ForegroundColor DarkGray
    Write-Host '  Netzwerk bleibt getrennt; Setup wird ausschliesslich vom eingebundenen ISO ausgefuehrt.' -ForegroundColor DarkGray
    if (-not (Read-LabConfirm -Prompt '  OOBE und SQL-Installation jetzt unbeaufsichtigt ausfuehren?' -Default $false)) { return }
    try {
        if ($build.state -in @('MANUAL_ACTION_REQUIRED', 'OOBE_AUTOMATION_RUNNING')) {
            $build = Invoke-HyperVSqlUnattendedOobe -BuildId $build.buildId
            Write-LabSuccess "Windows-OOBE verifiziert. State: $($build.state)"
        }
        $credential = Get-HyperVSqlGuestCredential -Build $build
        $saPassword = Get-LabSecret -Path $build.BuildDirectory -Name 'sa-password'
        if (-not $saPassword) { $saPassword = New-HyperVSqlUnattendedPassword }
        $result = Invoke-HyperVSqlTestEnvironmentInstall -BuildId $build.buildId `
            -Credential $credential -SaPassword $saPassword
        if ($result.state -eq 'SQL_INSTALL_REBOOT_REQUIRED') {
            Write-LabInfo 'SQL Setup hat einen Neustart angefordert. Aktion 13 nach dem Gast-Neustart erneut ausfuehren.'
        }
        else { Write-LabSuccess "Windows-SQL-Testumgebung ist bereit. State: $($result.state)" }
    }
    catch { Write-LabError $_.Exception.Message }
}

function Test-LabHyperVSqlAcceptanceInteractive {
    [CmdletBinding()]
    param()

    $build = Select-LabHyperVSqlImageBuild -AllowedStates @('SQL_READY_RUN', 'TESTS_PASSED') -RequireExistingVm
    if (-not $build) { return }
    if (-not (Read-LabConfirm -Prompt '  Create/Insert/Backup/Restore-Verify/Drop-Abnahmetest ausfuehren?' -Default $true)) { return }
    try {
        $credential = Get-HyperVSqlGuestCredential -Build $build
        $result = Test-HyperVSqlAcceptanceEnvironment -BuildId $build.buildId -Credential $credential
        Write-LabSuccess "SQL $($result.sql.version) wurde abgenommen. State: $($result.state)"
    }
    catch { Write-LabError $_.Exception.Message }
}

function Invoke-LabHyperVSqlManualOobeAcceptanceInstallInteractive {
    [CmdletBinding()]
    param()

    $build = Select-LabHyperVSqlImageBuild -AllowedStates @('MANUAL_ACTION_REQUIRED') -RequireExistingVm
    if (-not $build) { return }
    $userName = Read-Host '  Lokaler Gast-Administrator [Administrator]'
    if (-not $userName) { $userName = 'Administrator' }
    $guestPassword = Read-Host '  Gastpasswort' -AsSecureString
    $credential = [PSCredential]::new($userName, $guestPassword)
    $saPassword = Get-LabSecret -Path $build.BuildDirectory -Name 'sa-password'
    if (-not $saPassword) { $saPassword = New-HyperVSqlUnattendedPassword }
    if (-not (Read-LabConfirm -Prompt '  OOBE ist abgeschlossen; SQL jetzt unbeaufsichtigt installieren?' -Default $false)) { return }
    try {
        $result = Invoke-HyperVSqlTestEnvironmentInstall -BuildId $build.buildId `
            -Credential $credential -SaPassword $saPassword
        if ($result.state -eq 'SQL_INSTALL_REBOOT_REQUIRED') {
            Write-LabInfo 'SQL Setup hat einen Neustart angefordert. Danach Aktion 13 erneut ausfuehren.'
        }
        else { Write-LabSuccess "Windows-SQL-Testumgebung ist bereit. State: $($result.state)" }
    }
    catch { Write-LabError $_.Exception.Message }
}

function Show-LabHyperVSqlAcceptanceMatrix {
    [CmdletBinding()]
    param()

    $matrix = @(Get-HyperVSqlAcceptanceMatrix)
    if ($matrix.Count -eq 0) { Write-LabInfo 'Keine SQL-Abnahmeumgebungen vorhanden.'; return @() }
    Write-Host ''
    Write-Host '  Windows-SQL-Abnahmematrix:' -ForegroundColor White
    foreach ($entry in $matrix) {
        $marker = if ($entry.TestsPassed) { '[PASS]' } elseif ($entry.Ready) { '[READY]' } else { '[----]' }
        $color = if ($entry.TestsPassed) { 'Green' } elseif ($entry.Ready) { 'Yellow' } else { 'DarkGray' }
        Write-Host ("    {0} SQL {1} | {2} | {3}" -f $marker, $entry.SqlVersion, $entry.State, $entry.VMName) -ForegroundColor $color
        if ($entry.ProductVersion) {
            Write-Host ("           {0} | {1} | Computer: {2}" -f $entry.ProductVersion, $entry.Edition, $entry.ComputerName) -ForegroundColor DarkGray
        }
    }
    return $matrix
}

function Select-LabSampleSelection {
    <#
    .SYNOPSIS Menuegefuehrte Mehrfachauswahl katalogisierter Testdatenbanken.
    .DESCRIPTION Zeigt alle mit dem Backup-Handler installierbaren Varianten
                 einschliesslich Groesse, Lizenz, Trust- und Cache-Status und
                 verhindert kollidierende Zieldatenbanken.
    .OUTPUTS String-Array im Format 'sampleId:variante' fuer New-SqlServerLab -Sample.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SqlVersion,
        [switch]$SkipInitialConfirm
    )

    $variants = @(Get-LabExecutableSampleVariant -SqlVersion $SqlVersion)
    if ($variants.Count -eq 0) {
        return @()
    }
    if (-not $SkipInitialConfirm -and -not (Read-LabConfirm -Prompt '  Testdatenbanken aus dem Katalog hinzufuegen?' -Default $false)) {
        return @()
    }

    # Trust- und Cache-Status einmalig ermitteln; die Cache-Pruefung hasht
    # vorhandene Artefakte und ist fuer grosse Backups nicht kostenlos.
    $localStatus = @{}
    foreach ($variant in $variants) {
        $key = "$($variant.SampleId):$($variant.Variant)"
        $localStatus[$key] = Get-LabSampleArtifactLocalStatus `
            -Source $variant.Source `
            -SampleId $variant.SampleId `
            -SampleVariant $variant.Variant `
            -ExpectedSha256 $variant.ExpectedSha256
    }

    $selection = [System.Collections.Generic.List[string]]::new()
    while ($true) {
        Write-Host ''
        Write-Host '  Testdatenbanken (Backup-Handler):' -ForegroundColor White
        for ($i = 0; $i -lt $variants.Count; $i++) {
            $variant = $variants[$i]
            $key = "$($variant.SampleId):$($variant.Variant)"
            $marker = if ($selection.Contains($key)) { '[x]' } else { '[ ]' }
            $status = $localStatus[$key]
            Write-Host ("    {0} [{1,2}] {2} ({3})" -f $marker, ($i + 1), $variant.DisplayName, $variant.Variant) -ForegroundColor White
            Write-Host ("           DB: {0} | Download: {1} MB | Lizenz: {2} | Trust: {3} | Cache: {4}" -f `
                $variant.ExpectedDatabase, $variant.DownloadSizeMB, $variant.License, $status.TrustStatus, $status.CacheStatus) -ForegroundColor DarkGray
        }
        Write-Host ''
        Write-Host '    [Nummer] Auswahl umschalten, [d Nummer] Details, [Enter] uebernehmen, [0] keine Testdatenbank' -ForegroundColor DarkGray
        $choice = Read-Host '  Auswahl'

        if ([string]::IsNullOrWhiteSpace($choice)) {
            break
        }
        if ($choice.Trim() -eq '0') {
            return @()
        }

        if ($choice -match '^[dD]\s*(\d+)$') {
            $detailIndex = [int]$Matches[1] - 1
            if ($detailIndex -lt 0 -or $detailIndex -ge $variants.Count) {
                Write-LabWarning 'Ungueltige Nummer.'
                continue
            }
            $variant = $variants[$detailIndex]
            $status = $localStatus["$($variant.SampleId):$($variant.Variant)"]
            Write-Host ''
            Write-Host "  $($variant.DisplayName) ($($variant.SampleId):$($variant.Variant))" -ForegroundColor White
            Write-Host "    $($variant.Description)" -ForegroundColor DarkGray
            Write-Host "    Erwartete Datenbank:   $($variant.ExpectedDatabase)" -ForegroundColor DarkGray
            Write-Host "    Quellseite:            $($variant.SourcePage)" -ForegroundColor DarkGray
            Write-Host "    Artifact-URL:          $($variant.Source)" -ForegroundColor DarkGray
            Write-Host "    Download:              $($variant.DownloadSizeMB) MB" -ForegroundColor DarkGray
            Write-Host "    Lizenz:                $($variant.License)" -ForegroundColor DarkGray
            Write-Host "    Mindest-SQL-Version:   $($variant.MinSqlVersion)" -ForegroundColor DarkGray
            Write-Host "    Trust-Status:          $($status.TrustStatus)" -ForegroundColor DarkGray
            Write-Host "    Cache-Status:          $($status.CacheStatus)" -ForegroundColor DarkGray
            if ($status.TrustStatus -eq 'TRUST_REQUIRED') {
                Write-Host '    Hinweis: Ohne bekannte SHA-256 fragt die Provisionierung einmalig nach Vertrauen.' -ForegroundColor Yellow
            }
            continue
        }

        if ($choice -notmatch '^\d+$') {
            Write-LabWarning "Ungueltige Eingabe: $choice"
            continue
        }

        $index = [int]$choice - 1
        if ($index -lt 0 -or $index -ge $variants.Count) {
            Write-LabWarning 'Ungueltige Nummer.'
            continue
        }

        $variant = $variants[$index]
        $key = "$($variant.SampleId):$($variant.Variant)"
        if ($selection.Contains($key)) {
            $null = $selection.Remove($key)
            continue
        }

        $conflict = $null
        foreach ($selectedKey in $selection) {
            $selectedVariant = $variants | Where-Object { "$($_.SampleId):$($_.Variant)" -eq $selectedKey } | Select-Object -First 1
            if ($selectedVariant -and $selectedVariant.ExpectedDatabase -eq $variant.ExpectedDatabase) {
                $conflict = $selectedKey
                break
            }
        }
        if ($conflict) {
            Write-LabWarning "SAMPLE_OUTPUT_CONFLICT: '$key' und '$conflict' erzeugen beide die Datenbank '$($variant.ExpectedDatabase)'."
            continue
        }

        $selection.Add($key)
    }

    return @($selection)
}

function Select-LabHyperVPreparedArtifact {
    [CmdletBinding()]
    param()

    $artifacts = @(Get-HyperVImageArtifact | Where-Object { $_.artifactState -eq 'SQL_PREPARED_SEALED' })
    if ($artifacts.Count -eq 0) { Write-LabInfo 'Kein veröffentlichtes SQL-Prepared-Image vorhanden.'; return $null }
    for ($i = 0; $i -lt $artifacts.Count; $i++) {
        $artifact = $artifacts[$i]
        Write-Host ("    [{0}] Windows {1} · SQL Server {2} {3} · {4}" -f ($i + 1), $artifact.operatingSystem.id, $artifact.sql.version, $artifact.sql.edition, $artifact.artifactId) -ForegroundColor White
    }
    $selection = Read-Host '  Prepared-Image auswählen [1]'
    if (-not $selection) { $selection = '1' }
    if ($selection -notmatch '^\d+$' -or [int]$selection -lt 1 -or [int]$selection -gt $artifacts.Count) { Write-LabWarning 'Ungültige Auswahl.'; return $null }
    return $artifacts[[int]$selection - 1]
}

function Select-LabHyperVVirtualSwitch {
    <#
    .SYNOPSIS
        Wählt einen vorhandenen Hyper-V-Switch oder bewusst keine Anbindung.
    .DESCRIPTION
        Die Switch-Liste wird erst unmittelbar vor der Lab-Erstellung gelesen,
        damit zwischenzeitlich neu angelegte oder entfernte Switches korrekt
        berücksichtigt werden. Eine leere Auswahl bedeutet weiterhin eine
        isolierte VM ohne Netzwerkadapter.
    #>
    [CmdletBinding()]
    param()

    try {
        $switches = @(Get-VMSwitch -ErrorAction Stop | Sort-Object Name)
    }
    catch {
        Write-LabWarning "Virtuelle Hyper-V-Switches konnten nicht gelesen werden: $($_.Exception.Message)"
        return $null
    }

    if ($switches.Count -eq 0) {
        Write-LabInfo 'Keine virtuellen Hyper-V-Switches vorhanden. Die VM bleibt isoliert.'
        return $null
    }

    Write-Host ''
    Write-Host '  Virtueller Switch:' -ForegroundColor White
    Write-Host '    [0] Kein Switch = isoliert' -ForegroundColor DarkGray
    for ($i = 0; $i -lt $switches.Count; $i++) {
        $switch = $switches[$i]
        Write-Host ("    [{0}] {1} · {2}" -f ($i + 1), $switch.Name, $switch.SwitchType) -ForegroundColor White
    }
    $selection = Read-Host '  Virtuellen Switch auswählen [0]'
    if (-not $selection -or $selection -eq '0') { return $null }
    if ($selection -notmatch '^\d+$' -or [int]$selection -lt 1 -or [int]$selection -gt $switches.Count) {
        Write-LabWarning 'Ungültige Auswahl. Die VM bleibt isoliert.'
        return $null
    }
    return [string]$switches[[int]$selection - 1].Name
}

function New-LabHyperVEnvironmentInteractive {
    [CmdletBinding()]
    param()

    $artifact = Select-LabHyperVPreparedArtifact
    if (-not $artifact) { return }
    $name = Read-Host '  Labname [hyperv-sql-lab]'
    if (-not $name) { $name = 'hyperv-sql-lab' }
    $instanceId = Read-Host '  Instanzname [primary]'
    if (-not $instanceId) { $instanceId = 'primary' }
    $memory = Read-Host '  Startspeicher MB [4096]'
    if (-not $memory) { $memory = 4096 }
    $cpu = Read-Host '  vCPU [4]'
    if (-not $cpu) { $cpu = 4 }
    $switchName = Select-LabHyperVVirtualSwitch
    $persistentData = $false
    $dataRoot = Get-LabDataRootDefault
    $persistentDataDiskGB = 128
    if ($dataRoot) {
        Write-LabInfo "Optionaler Data Root verfügbar: $dataRoot"
        $persistentData = Read-LabConfirm -Prompt '  Langlebige Daten-VHDX im Data Root anhängen?' -Default $false
        if ($persistentData) {
            $persistentDataDiskGB = Read-Host '  Größe Daten-VHDX in GB [128]'
            if (-not $persistentDataDiskGB) { $persistentDataDiskGB = 128 }
        }
    }
    Write-Host '  Gastpasswort: [1] selbst festlegen, [2] zufällig erzeugen und anzeigen [2]' -ForegroundColor White
    $passwordMode = Read-Host '  Auswahl'
    if (-not $passwordMode) { $passwordMode = '2' }
    if ($passwordMode -notin @('1', '2')) { Write-LabWarning 'Ungültige Auswahl.'; return }
    $passwordSource = if ($passwordMode -eq '2') { 'generated' } else { 'user' }
    if ($passwordSource -eq 'generated') {
        $guestPassword = New-HyperVSqlUnattendedPassword
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($guestPassword)
        try { Write-Host ("  Einmaliges Administratorpasswort (jetzt kopieren): {0}" -f [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)) -ForegroundColor Yellow }
        finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    }
    else {
        $guestPassword = Read-Host '  Lokales Administratorpasswort' -AsSecureString
        $confirmation = Read-Host '  Passwort bestätigen' -AsSecureString
        $firstBstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($guestPassword)
        $secondBstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($confirmation)
        try {
            if ([System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($firstBstr) -ne [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($secondBstr)) {
                Write-LabWarning 'Passwörter stimmen nicht überein.'
                return
            }
        }
        finally {
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($firstBstr)
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($secondBstr)
        }
    }
    Write-Host "  Image: $($artifact.artifactId)" -ForegroundColor DarkGray
    Write-Host '  Es wird eine differenzierende VM erstellt, automatisch per Unattend.xml eingerichtet und anschließend mit SQL CompleteImage vervollständigt.' -ForegroundColor DarkGray
    if (-not (Read-LabConfirm -Prompt '  Hyper-V-Umgebung jetzt erstellen?' -Default $false)) { return }
    try {
        $lab = New-HyperVLabEnvironment -ArtifactId $artifact.artifactId -LabName $name -InstanceId $instanceId -MemoryStartupMB ([int]$memory) -ProcessorCount ([int]$cpu) -SwitchName $switchName
        if ($persistentData) {
            $null = Enable-HyperVLabPersistentData -RunId $lab.RunId -DataRoot $dataRoot -SizeGB ([int]$persistentDataDiskGB)
        }
        $null = Invoke-HyperVLabUnattendedProvision -RunId $lab.RunId -AdministratorPassword $guestPassword -PasswordSource $passwordSource
        Write-LabSuccess "Hyper-V-Umgebung bereitgestellt: $($lab.VMName) (Run $($lab.RunId))"
        Write-LabInfo 'Die OOBE, SQL CompleteImage und eine optionale Daten-VHDX-Initialisierung wurden automatisch ausgeführt.'
    }
    catch { Write-LabError $_.Exception.Message }
}

function New-LabHyperVEnvironmentFromExistingVmInteractive {
    [CmdletBinding()]
    param()

    $sources = @(Get-HyperVExistingVmLabSource)
    if ($sources.Count -eq 0) {
        Write-LabInfo 'Keine kompatible Quell-VM gefunden. Erforderlich: ausgeschaltet, Generation 2, nicht durch SQL_Server_Lab verwaltet und genau eine System-VHDX.'
        return
    }
    Write-Host ''
    Write-Host '  Sichere vorhandene Windows-VM als Basis:' -ForegroundColor White
    for ($i = 0; $i -lt $sources.Count; $i++) {
        $source = $sources[$i]
        Write-Host ("    [{0}] {1} · {2} MB · {3} vCPU" -f ($i + 1), $source.VMName, $source.MemoryStartupMB, $source.ProcessorCount) -ForegroundColor White
        Write-Host ("        {0}" -f $source.LicenseNotice) -ForegroundColor DarkYellow
    }
    $selection = Read-Host '  Quell-VM auswählen [1]'
    if (-not $selection) { $selection = '1' }
    if ($selection -notmatch '^\d+$' -or [int]$selection -lt 1 -or [int]$selection -gt $sources.Count) { Write-LabWarning 'Ungültige Auswahl.'; return }
    $source = $sources[[int]$selection - 1]
    $name = Read-Host '  Labname [windows-dev-lab]'
    if (-not $name) { $name = 'windows-dev-lab' }
    $instanceId = Read-Host '  Instanzname [primary]'
    if (-not $instanceId) { $instanceId = 'primary' }
    $memory = Read-Host "  Startspeicher MB [$($source.MemoryStartupMB)]"
    if (-not $memory) { $memory = $source.MemoryStartupMB }
    $cpu = Read-Host "  vCPU [$($source.ProcessorCount)]"
    if (-not $cpu) { $cpu = $source.ProcessorCount }
    $switchName = Select-LabHyperVVirtualSwitch
    $persistentData = $false
    $dataRoot = Get-LabDataRootDefault
    $persistentDataDiskGB = 128
    if ($dataRoot) {
        Write-LabInfo "Optionaler Data Root verfügbar: $dataRoot"
        $persistentData = Read-LabConfirm -Prompt '  Langlebige Daten-VHDX im Data Root anhängen?' -Default $false
        if ($persistentData) {
            $persistentDataDiskGB = Read-Host '  Größe Daten-VHDX in GB [128]'
            if (-not $persistentDataDiskGB) { $persistentDataDiskGB = 128 }
        }
    }
    Write-LabWarning 'Die Original-VM und ihre VHDX bleiben unverändert. Es wird eine eigene, schreibgeschützte Arbeitskopie als Parent erstellt.'
    if (-not (Read-LabConfirm -Prompt '  Lizenz- und Ablaufstatus der Quell-VM geprüft und Lab-VM erstellen?' -Default $false)) { return }
    try {
        $lab = New-HyperVLabEnvironmentFromExistingVm -SourceVMName $source.VMName -LabName $name -InstanceId $instanceId -MemoryStartupMB ([int]$memory) -ProcessorCount ([int]$cpu) -SwitchName $switchName -ConfirmSourceLicense
        if ($persistentData) {
            $null = Enable-HyperVLabPersistentData -RunId $lab.RunId -DataRoot $dataRoot -SizeGB ([int]$persistentDataDiskGB)
        }
        Write-LabSuccess "Hyper-V-Umgebung erstellt: $($lab.VMName) (Run $($lab.RunId)); Quelle '$($lab.SourceVMName)' blieb unverändert."
        Write-LabInfo 'Nächster Schritt: [19] wählen, VM starten und VMConnect öffnen.'
    }
    catch { Write-LabError $_.Exception.Message }
}

function Manage-LabHyperVEnvironmentInteractive {
    [CmdletBinding()]
    param()

    $runs = @(Get-LabActiveRuns | Where-Object { [string]$_.metadata.workflowKind -eq 'hyperv-lab' })
    if ($runs.Count -eq 0) { Write-LabInfo 'Keine regulären Hyper-V-Umgebungen vorhanden.'; return }
    for ($i = 0; $i -lt $runs.Count; $i++) {
        try {
            $lab = Get-HyperVLabWorkflowRun -RunId $runs[$i].runId
            $status = Get-HyperVInstanceStatus -VMName $lab.Instance.vmName -ExpectedRunId $lab.Run.runId -ExpectedScopeId $lab.Run.scopeId
            Write-Host ("    [{0}] {1} · Live: {2} · Workflow: {3} · VM {4}" -f ($i + 1), $runs[$i].metadata.name, $status.State, $runs[$i].state, $lab.Instance.vmName) -ForegroundColor White
            if ($lab.Instance.connectionString) { Write-Host "        Connection String (in VM): $($lab.Instance.connectionString)" -ForegroundColor DarkGray }
            if ($lab.Instance.persistentStorage) { Write-Host "        Persistente Daten: $($lab.Instance.persistentStorage.hostPath) [$($lab.Instance.persistentStorage.state)]" -ForegroundColor DarkGray }
        }
        catch { Write-Host ("    [{0}] {1} · {2}" -f ($i + 1), $runs[$i].metadata.name, $runs[$i].state) -ForegroundColor Yellow }
    }
    $selection = Read-Host '  Umgebung auswählen'
    if ($selection -notmatch '^\d+$' -or [int]$selection -lt 1 -or [int]$selection -gt $runs.Count) { Write-LabWarning 'Ungültige Auswahl.'; return }
    $runId = [string]$runs[[int]$selection - 1].runId
    $action = Read-Host '  Aktion: [s]tarten, [v]mconnect, sto[p]pen, [d]aten-VHDX, [i]nitialisieren, [c]ompleteimage, SQL-[q] prüfen, [e]ntfernen'
    try {
        switch ($action) {
            's' { $result = Start-HyperVLabEnvironment -RunId $runId; Write-LabSuccess "VM gestartet: $($result.VMName)" }
            'v' { $result = Open-HyperVLabEnvironmentConsole -RunId $runId; Write-LabInfo "VMConnect geöffnet: $($result.VMName)" }
            'p' { $result = Stop-HyperVLabEnvironment -RunId $runId; Write-LabSuccess "VM gestoppt: $($result.VMName)" }
            'd' {
                $dataRoot = Get-LabDataRootDefault
                if (-not $dataRoot) { Write-LabError 'Kein Data Root gespeichert. Zuerst Hauptmenü [d] konfigurieren.'; return }
                $sizeGB = Read-Host '  Größe Daten-VHDX in GB [128]'
                if (-not $sizeGB) { $sizeGB = 128 }
                $storage = Enable-HyperVLabPersistentData -RunId $runId -DataRoot $dataRoot -SizeGB ([int]$sizeGB)
                Write-LabSuccess "Daten-VHDX angehängt: $($storage.hostPath)"
            }
            'i' {
                $userName = Read-Host '  Lokaler Gast-Administrator [Administrator]'
                if (-not $userName) { $userName = 'Administrator' }
                $credential = [PSCredential]::new($userName, (Read-Host '  Gastpasswort' -AsSecureString))
                $null = Initialize-HyperVLabPersistentData -RunId $runId -Credential $credential
                Write-LabSuccess 'Daten-VHDX wurde im Gast als D:\SQLData initialisiert.'
            }
            'c' {
                $userName = Read-Host '  Lokaler Gast-Administrator [Administrator]'
                if (-not $userName) { $userName = 'Administrator' }
                $credential = [PSCredential]::new($userName, (Read-Host '  Gastpasswort' -AsSecureString))
                $result = Complete-HyperVLabSqlImage -RunId $runId -Credential $credential
                Write-LabSuccess "SQL CompleteImage abgeschlossen. State: $($result.State)"
            }
            'q' {
                $userName = Read-Host '  Lokaler Gast-Administrator [Administrator]'
                if (-not $userName) { $userName = 'Administrator' }
                $credential = [PSCredential]::new($userName, (Read-Host '  Gastpasswort' -AsSecureString))
                $instances = @(Inspect-HyperVLabSqlInstances -RunId $runId -Credential $credential)
                foreach ($instance in $instances) {
                    Write-Host ("    {0} · Dienst {1} · TCP {2}" -f $instance.Name, $instance.ServiceStatus, $instance.TcpPort) -ForegroundColor White
                    Write-Host "      Connection String (in VM): $($instance.ConnectionString)" -ForegroundColor DarkGray
                }
            }
            'e' {
                if (Read-LabConfirm -Prompt '  VM und run-lokale differenzierende VHDX wirklich entfernen?' -Default $false) {
                    $result = Remove-SqlServerLab -RunId $runId -Force -Confirm:$false
                    Write-LabSuccess "Entfernt: $($result.RunId)"
                }
            }
            default { Write-LabWarning 'Ungültige Aktion.' }
        }
    }
    catch { Write-LabError $_.Exception.Message }
}

function Get-AvailableLabProviders {
    <#
    .SYNOPSIS Ermittelt alle lokal verfuegbaren und implementierten Provider.
    .DESCRIPTION Prueft dynamisch, welche implementierten Container-Runtimes erreichbar sind.
    .OUTPUTS String-Array der verfuegbaren Provider-Namen.
    #>
    [CmdletBinding()]
    param()

    $available = @()

    if (Get-Command 'docker' -ErrorAction SilentlyContinue) {
        $null = docker version --format '{{.Server.Version}}' 2>&1
        if ($LASTEXITCODE -eq 0) { $available += 'docker' }
    }
    if (Get-Command 'podman' -ErrorAction SilentlyContinue) {
        $null = podman info 2>&1
        if ($LASTEXITCODE -eq 0) { $available += 'podman' }
    }

    # Hyper-V wird erst angeboten, wenn der Provider implementiert ist.
    return @($available | Sort-Object -Unique)
}

function Select-LabRun {
    param(
        [Parameter(Mandatory)][array]$Runs,
        [string]$Prompt = "Auswahl"
    )

    if ($Runs.Count -eq 1) {
        $prefix = $Runs[0].runId.Substring(0, 8)
        Write-LabInfo "Einziges Lab: ${prefix}... ($($Runs[0].metadata.name))"
        return $Runs[0].runId
    }

    Write-Host ""
    for ($i = 0; $i -lt $Runs.Count; $i++) {
        $prefix = $Runs[$i].runId.Substring(0, 8)
        $runtime = Get-LabRunRuntimeStatus -Run $Runs[$i]
        Write-Host "    [$($i+1)] ${prefix}... - $($Runs[$i].metadata.name) [Live: $($runtime.State); Workflow: $($Runs[$i].state)]" -ForegroundColor White
    }
    Write-Host ""
    $sel = Read-Host "  $Prompt (Nummer)"
    $idx = [int]$sel - 1

    if ($idx -ge 0 -and $idx -lt $Runs.Count) {
        return $Runs[$idx].runId
    }

    Write-LabWarning "Ungueltige Auswahl."
    return $null
}

function Rename-LabEnvironmentInteractive {
    <#
    .SYNOPSIS
        Ändert den Anzeigenamen einer laufenden oder gestoppten Lab-Umgebung.
    .DESCRIPTION
        Die Runtime-Objekte werden zusammen mit den Metadaten als
        <Name>-<RunId-Präfix> umbenannt. Bei Hyper-V ist das nur für eine
        ausgeschaltete VM möglich; Docker und Podman erlauben es auch laufend.
    #>
    [CmdletBinding()]
    param()

    $runs = @(Get-LabActiveRuns)
    if ($runs.Count -eq 0) { Write-LabInfo 'Keine aktiven Lab-Umgebungen vorhanden.'; return }
    $runId = Select-LabRun -Runs $runs -Prompt 'Umgebung zum Umbenennen'
    if (-not $runId) { return }
    $run = Get-LabRunState -RunId $runId
    $currentName = [string]$run.metadata.name
    $newName = Read-Host "  Neuer Anzeigename [$currentName]"
    if (-not $newName) { Write-LabInfo 'Name unverändert.'; return }
    try {
        $renamed = if ([string]$run.metadata.workflowKind -eq 'hyperv-lab') {
            Rename-HyperVLabEnvironment -RunId $runId -DisplayName $newName
        }
        else {
            Rename-ContainerLabEnvironment -RunId $runId -DisplayName $newName
        }
        if ($renamed.Changed) {
            Write-LabSuccess "Umgebung umbenannt: $($renamed.PreviousName) -> $($renamed.Name)"
            if ($renamed.PSObject.Properties['VMRenamed'] -and $renamed.VMRenamed) { Write-LabInfo "Hyper-V-VM umbenannt: $($renamed.PreviousVMName) -> $($renamed.VMName)" }
            if ($renamed.PSObject.Properties['RuntimeRenamed'] -and $renamed.RuntimeRenamed) { Write-LabInfo 'Docker-/Podman-Container wurden synchron umbenannt.' }
        }
        else { Write-LabInfo 'Name unverändert.' }
    }
    catch { Write-LabError $_.Exception.Message }
}
