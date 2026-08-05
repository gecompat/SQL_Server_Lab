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
        [ValidateSet('New', 'Manifest', 'Status', 'Stop', 'Start', 'Restart', 'Remove', 'Clear', 'Script', 'Database', 'Image')]
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
            'i' { Invoke-LabAction -ActionName 'Image' }
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
            Write-Host "    [$($run.state.PadRight(10))] ${prefix}... - $name" -ForegroundColor Gray
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
    Write-Host "    [i] Hyper-V Windows-Image verwalten" -ForegroundColor Yellow
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

            # Testdatenbanken (optional, Mehrfachauswahl)
            $selectedSamples = @(Select-LabSampleSelection -SqlVersion $version)

            $newLabArguments = @{
                Version  = $version
                Provider = $provider
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

            # Port aus connection-info lesen
            $stateRoot = Get-LabStateRoot
            $connInfoPath = Join-Path $stateRoot "runs/$runId/connection-info.json"
            if (-not (Test-Path $connInfoPath)) {
                Write-LabError "Connection-Info nicht gefunden."
                return
            }
            $connInfo = Get-Content $connInfoPath -Raw | ConvertFrom-Json
            $port = $connInfo.instances[0].port

            $dbName = Read-Host "  Datenbankname"
            if (-not $dbName) { return }

            $pw = Read-Host "  SA-Passwort" -AsSecureString
            New-SqlServerLabDatabase -Port $port -SaPassword $pw -DatabaseName $dbName
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

    Write-Host '  Hyper-V Image-Lifecycle:' -ForegroundColor White
    Write-Host ''
    Write-Host '    Empfohlener Prepared-Image-Pfad: 7 -> 9 (Windows installieren) -> 10 -> 11.' -ForegroundColor Yellow
    Write-Host '    Er installiert Windows und SQL in einer frischen VM und verwendet genau einen finalen Sysprep.' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '    Windows-OS-Baseline' -ForegroundColor DarkGray
    Write-Host '    [1] Neuen Windows-Builder aus Media Root vorbereiten' -ForegroundColor Yellow
    Write-Host '    [2] Windows-Build-Status anzeigen' -ForegroundColor White
    Write-Host '    [3] Windows-Builder starten und VMConnect oeffnen' -ForegroundColor White
    Write-Host '    [4] Installiertes Windows generalisieren' -ForegroundColor White
    Write-Host '    [5] Windows-Image veroeffentlichen' -ForegroundColor White
    Write-Host '    [6] Unfertigen Windows-Builder aufraeumen' -ForegroundColor Red
    Write-Host ''
    Write-Host '    SQL-Prepared-Image aus frischer Windows-ISO' -ForegroundColor DarkGray
    Write-Host '    [7] Frischen SQL-Image-Builder vorbereiten (Windows + SQL, ein Sysprep)' -ForegroundColor Yellow
    Write-Host '    [8] SQL-Image-Build-Status anzeigen' -ForegroundColor White
    Write-Host '    [9] SQL-Builder starten und Windows-Installation in VMConnect abschliessen' -ForegroundColor White
    Write-Host '    [10] SQL PrepareImage automatisch installieren und Windows-Sysprep ausfuehren' -ForegroundColor White
    Write-Host '    [11] SQL-Prepared-Image veroeffentlichen' -ForegroundColor White
    Write-Host '    [12] Unfertigen SQL-Builder aufraeumen' -ForegroundColor Red
    Write-Host ''
    Write-Host '    Run-lokale Windows-SQL-Abnahmeumgebung (Alternative zu 9 -> 10 -> 11)' -ForegroundColor DarkGray
    Write-Host '    [13] OOBE und vollstaendiges SQL automatisch installieren' -ForegroundColor Yellow
    Write-Host '    [14] SQL-Abnahmetest ausfuehren' -ForegroundColor White
    Write-Host '    [15] SQL-2019/2022/2025-Abnahmematrix anzeigen' -ForegroundColor White
    Write-Host '    [16] OOBE manuell abgeschlossen: uebernehmen und vollstaendiges SQL installieren' -ForegroundColor White
    Write-Host '    [17] Nach Sysprep ohne Gastpasswort offline pruefen und Prepared-Image fortsetzen' -ForegroundColor Yellow
    Write-Host '    [a] Legacy: SQL-Abnahme-Builder aus vorhandener OS-Baseline erzeugen' -ForegroundColor DarkGray
    Write-Host '    [0] Zurueck' -ForegroundColor DarkGray
    Write-Host ''
    $choice = Read-Host '  Auswahl'

    switch ($choice) {
        '0' { return }
        '1' { New-LabHyperVImageBuildInteractive }
        '2' { Show-LabHyperVImageBuilds }
        '3' { Start-LabHyperVImageBuildInteractive }
        '4' { Invoke-LabHyperVImageGeneralizationInteractive }
        '5' { Publish-LabHyperVImageBuildInteractive }
        '6' { Remove-LabHyperVImageBuildInteractive }
        '7' { New-LabHyperVSqlImageBuildInteractive }
        '8' { Show-LabHyperVSqlImageBuilds }
        '9' { Start-LabHyperVSqlImageBuildInteractive }
        '10' { Invoke-LabHyperVSqlPrepareInteractive }
        '11' { Publish-LabHyperVSqlImageBuildInteractive }
        '12' { Remove-LabHyperVSqlImageBuildInteractive }
        '13' { Invoke-LabHyperVSqlAcceptanceInstallInteractive }
        '14' { Test-LabHyperVSqlAcceptanceInteractive }
        '15' { Show-LabHyperVSqlAcceptanceMatrix }
        '16' { Invoke-LabHyperVSqlManualOobeAcceptanceInstallInteractive }
        '17' { Resume-LabHyperVSqlPreparedImageGeneralizationInteractive }
        'a' { New-LabHyperVSqlAcceptanceBuildInteractive }
        default { Write-LabWarning "Ungueltige Auswahl: $choice" }
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

    $version = Read-Host '  Windows Server Version [2025]'
    if (-not $version) { $version = '2025' }
    if ($version -notin @('2022', '2025')) {
        Write-LabError "Nicht unterstuetzte Windows-Server-Version: $version"
        return
    }
    $operatingSystemId = "windows-server-$version"
    $edition = Read-Host '  Edition [standard-evaluation]'
    if (-not $edition) { $edition = 'standard-evaluation' }
    $installationType = Read-Host '  Installationstyp: core oder desktop-experience [desktop-experience]'
    if (-not $installationType) { $installationType = 'desktop-experience' }
    if ($installationType -notin @('core', 'desktop-experience')) {
        Write-LabError "Ungueltiger Installationstyp: $installationType"
        return
    }

    try {
        $media = Resolve-HyperVWindowsInstallationMedia `
            -MediaRoot $mediaRoot `
            -OperatingSystemId $operatingSystemId
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
                -OperatingSystemId $operatingSystemId
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

    $build = Select-LabHyperVImageBuild -AllowedStates @(
        'MEDIA_VERIFIED', 'BUILDER_READY', 'MANUAL_ACTION_REQUIRED', 'REBOOT_REQUIRED', 'RESUME_PENDING', 'FAILED'
    )
    if (-not $build) { return }
    Write-LabWarning "VM und buildlokale VHDX von '$($build.buildId)' werden entfernt."
    if (-not (Read-LabConfirm -Prompt '  Builder wirklich aufraeumen?' -Default $false)) { return }
    try {
        $result = Remove-HyperVWindowsImageBuild -BuildId $build.buildId
        if ($result.Status -eq 'CLEANUP_SUCCEEDED') {
            Write-LabSuccess 'Builder-Ressourcen wurden entfernt.'
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
    }
    return $builds
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
        Write-Host '    2. Gewuenschte Edition und Desktop Experience/Core waehlen, OOBE abschliessen.' -ForegroundColor White
        Write-Host '    3. Lokales Administratorpasswort setzen und einmal anmelden.' -ForegroundColor White
        Write-Host '    4. Zurueck im Image-Menue Aktion 10 waehlen: SQL PrepareImage und genau ein finaler Windows-Sysprep.' -ForegroundColor White
        Write-Host '  Die zweite DVD enthaelt bereits die verifizierte SQL-ISO; sie wird von Aktion 10 verwendet.' -ForegroundColor DarkGray
        return
    }
    Write-Host '  Unbeaufsichtigter Windows-OOBE-Schritt:' -ForegroundColor Yellow
    Write-Host "    VM: $($Build.builder.vmName)" -ForegroundColor White
    Write-Host '    Aktion 13 setzt Region Deutschland, UI en-US und deutsche Tastatur.' -ForegroundColor White
    Write-Host '    Danach wird SQL Server ohne weitere GUI-Interaktion installiert.' -ForegroundColor White
    Write-Host '  Zufallspasswoerter liegen nur lokal und DPAPI-geschuetzt im Build-Verzeichnis.' -ForegroundColor DarkGray
    Write-Host '  Die temporaere Unattend.xml wird nach erfolgreichem OOBE aus dem Gast entfernt.' -ForegroundColor DarkGray
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

    $windowsEdition = Read-Host '  Windows-Edition [standard-evaluation]'
    if (-not $windowsEdition) { $windowsEdition = 'standard-evaluation' }
    $installationType = Read-Host '  Windows-Typ: core oder desktop-experience [desktop-experience]'
    if (-not $installationType) { $installationType = 'desktop-experience' }
    if ($windowsEdition -notin @('standard-evaluation', 'datacenter-evaluation') -or $installationType -notin @('core', 'desktop-experience')) {
        Write-LabError 'Windows-Edition oder Installationstyp ist ungueltig.'; return
    }
    $sqlVersion = Read-Host '  SQL Server Version: 2019, 2022 oder 2025 [2025]'
    if (-not $sqlVersion) { $sqlVersion = '2025' }
    if ($sqlVersion -notin @('2019', '2022', '2025')) { Write-LabError 'SQL-Version ist ungueltig.'; return }
    $defaultEdition = if ($sqlVersion -eq '2025') { 'Enterprise' } else { 'Eval' }
    $mediaEdition = Read-Host "  SQL-Medien-Edition [$defaultEdition]"
    if (-not $mediaEdition) { $mediaEdition = $defaultEdition }
    if ($mediaEdition -notin @('Eval', 'Enterprise', 'Standard')) { Write-LabError 'SQL-Medien-Edition ist ungueltig.'; return }

    try {
        $windowsMedia = Resolve-HyperVWindowsInstallationMedia -MediaRoot $mediaRoot -OperatingSystemId windows-server-2025
        if ($windowsMedia.HashStatus -eq 'MISSING') {
            Write-LabWarning 'Fuer die Windows-ISO existiert noch kein SHA-256-Sidecar.'
            if (-not (Read-LabConfirm -Prompt '  Windows-SHA-256 jetzt berechnen und lokal festschreiben?' -Default $false)) { return }
            Write-LabInfo 'Windows-SHA-256 wird berechnet; grosse ISOs benoetigen mehrere Minuten.'
            $windowsMedia = New-HyperVWindowsMediaHashSidecar -MediaRoot $mediaRoot -OperatingSystemId windows-server-2025
        }
        $sqlMedia = Resolve-HyperVSqlInstallationMedia -MediaRoot $mediaRoot -SqlVersion $sqlVersion -MediaEdition $mediaEdition
        if ($sqlMedia.HashStatus -eq 'MISSING') {
            Write-LabWarning 'Fuer die SQL-ISO existiert noch kein SHA-256-Sidecar.'
            if (-not (Read-LabConfirm -Prompt '  SQL-SHA-256 jetzt berechnen und lokal festschreiben?' -Default $false)) { return }
            Write-LabInfo 'SQL-SHA-256 wird berechnet; grosse ISOs benoetigen mehrere Minuten.'
            $sqlMedia = New-HyperVSqlMediaHashSidecar -MediaRoot $mediaRoot -SqlVersion $sqlVersion -MediaEdition $mediaEdition
        }
        Write-Host ''
        Write-Host "  Windows: Windows Server 2025 / $windowsEdition / $installationType" -ForegroundColor DarkGray
        Write-Host "  SQL:     $sqlVersion $mediaEdition; SQLENGINE, FULLTEXT, REPLICATION" -ForegroundColor DarkGray
        Write-Host '  Ablauf: Windows installieren -> SQL PrepareImage -> ein finaler Sysprep.' -ForegroundColor Yellow
        if (-not (Read-LabConfirm -Prompt '  Frischen SQL-Prepared-Image-Builder jetzt erzeugen?' -Default $false)) { return }
        $build = Initialize-HyperVSqlFreshPreparedImageBuild -MediaRoot $mediaRoot -OperatingSystemId windows-server-2025 `
            -WindowsEdition $windowsEdition -InstallationType $installationType -SqlVersion $sqlVersion -MediaEdition $mediaEdition
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
    $sqlVersion = Read-Host '  SQL Server Version: 2019, 2022 oder 2025 [2019]'
    if (-not $sqlVersion) { $sqlVersion = '2019' }
    if ($sqlVersion -notin @('2019', '2022', '2025')) { Write-LabError 'SQL-Version ist ungueltig.'; return }
    $defaultEdition = if ($sqlVersion -eq '2025') { 'Enterprise' } else { 'Eval' }
    $mediaEdition = Read-Host "  Medien-Edition [$defaultEdition]"
    if (-not $mediaEdition) { $mediaEdition = $defaultEdition }
    if ($mediaEdition -notin @('Eval', 'Enterprise', 'Standard')) { Write-LabError 'Medien-Edition ist ungueltig.'; return }
    $artifact = Select-LabHyperVOsArtifact
    if (-not $artifact) { return }

    try {
        $media = Resolve-HyperVSqlInstallationMedia -MediaRoot $mediaRoot -SqlVersion $sqlVersion -MediaEdition $mediaEdition
        if ($media.HashStatus -eq 'MISSING') {
            Write-LabWarning 'Fuer die SQL-ISO existiert noch kein SHA-256-Sidecar.'
            Write-Host "  ISO: $($media.IsoPath)" -ForegroundColor DarkGray
            if (-not (Read-LabConfirm -Prompt '  SHA-256 jetzt berechnen und lokal festschreiben?' -Default $false)) { return }
            $media = New-HyperVSqlMediaHashSidecar -MediaRoot $mediaRoot -SqlVersion $sqlVersion -MediaEdition $mediaEdition
        }
        Write-Host "  Parent: $($artifact.artifactId)" -ForegroundColor DarkGray
        Write-Host "  SQL:    $sqlVersion $mediaEdition; SQLENGINE, FULLTEXT, REPLICATION" -ForegroundColor DarkGray
        Write-Host '  Die Evaluation-Ablaufzeit der OS-Baseline wird in das neue Artifact uebernommen.' -ForegroundColor DarkGray
        if (-not (Read-LabConfirm -Prompt '  SQL-Image-Builder jetzt erzeugen?' -Default $false)) { return }
        $build = Initialize-HyperVSqlPreparedImageBuild -MediaRoot $mediaRoot -ImageArtifactId $artifact.artifactId `
            -SqlVersion $sqlVersion -MediaEdition $mediaEdition
        Write-LabSuccess "SQL-Builder erstellt. BuildId: $($build.buildId)"
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

function Invoke-LabHyperVSqlPrepareInteractive {
    [CmdletBinding()]
    param()
    $build = Select-LabHyperVSqlImageBuild -AllowedStates @('MANUAL_ACTION_REQUIRED', 'REBOOT_REQUIRED') -RequireExistingVm
    if (-not $build) { return }
    $userName = Read-Host '  Lokaler Gast-Administrator [Administrator]'
    if (-not $userName) { $userName = 'Administrator' }
    $password = Read-Host '  Gastpasswort' -AsSecureString
    $credential = [PSCredential]::new($userName, $password)
    if (-not (Read-LabConfirm -Prompt '  SQL PrepareImage und anschliessend Windows-Sysprep ausfuehren?' -Default $false)) { return }
    try {
        $result = Invoke-HyperVSqlPrepareAndGeneralize -BuildId $build.buildId -Credential $credential
        if ($result.state -eq 'REBOOT_REQUIRED') {
            Write-LabInfo 'SQL Setup hat einen Neustart angefordert. Nach dem Neustart Aktion 10 erneut ausfuehren.'
        }
        else { Write-LabSuccess "SQL PrepareImage und Generalisierung verifiziert. State: $($result.state)" }
    }
    catch { Write-LabError $_.Exception.Message }
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
    $build = Select-LabHyperVSqlImageBuild -AllowedStates @(
        'MEDIA_VERIFIED', 'MANUAL_ACTION_REQUIRED', 'OOBE_AUTOMATION_RUNNING', 'OOBE_COMPLETED',
        'REBOOT_REQUIRED', 'RESUME_PENDING', 'SQL_INSTALL_RUNNING', 'SQL_INSTALL_REBOOT_REQUIRED', 'FAILED'
    )
    if (-not $build) { return }
    Write-LabWarning "VM und buildlokale VHDX von '$($build.buildId)' werden entfernt."
    if (-not (Read-LabConfirm -Prompt '  SQL-Builder wirklich aufraeumen?' -Default $false)) { return }
    try {
        $result = Remove-HyperVSqlImageBuild -BuildId $build.buildId
        if ($result.Status -eq 'CLEANUP_SUCCEEDED') { Write-LabSuccess 'SQL-Builder-Ressourcen wurden entfernt.' }
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
        [Parameter(Mandatory)][string]$SqlVersion
    )

    $variants = @(Get-LabExecutableSampleVariant -SqlVersion $SqlVersion)
    if ($variants.Count -eq 0) {
        return @()
    }
    if (-not (Read-LabConfirm -Prompt '  Testdatenbanken aus dem Katalog hinzufuegen?' -Default $false)) {
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
        Write-Host "    [$($i+1)] ${prefix}... - $($Runs[$i].metadata.name) [$($Runs[$i].state)]" -ForegroundColor White
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
