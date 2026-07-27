<#
.SYNOPSIS
    Interaktives Menue fuer SQL_Server_Lab.
.DESCRIPTION
    Single-Entry-Point mit Menue-Loop. Zeigt aktive Labs und bietet
    alle Operationen ueber nummerierte Auswahl an.
.PARAMETER Action
    Optionale Direkt-Aktion (ueberspringt das Menue).
.EXAMPLE
    Invoke-SqlServerLab
.EXAMPLE
    Invoke-SqlServerLab -Action Status
#>
function Invoke-SqlServerLab {
    [CmdletBinding()]
    param(
        [ValidateSet('New', 'Status', 'Stop', 'Start', 'Restart', 'Remove', 'Clear', 'Script', 'Database')]
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
            '2' { Invoke-LabAction -ActionName 'Status' }
            '3' { Invoke-LabAction -ActionName 'Stop' }
            '4' { Invoke-LabAction -ActionName 'Start' }
            '5' { Invoke-LabAction -ActionName 'Restart' }
            '6' { Invoke-LabAction -ActionName 'Remove' }
            '7' { Invoke-LabAction -ActionName 'Clear' }
            '8' { Invoke-LabAction -ActionName 'Database' }
            '9' { Invoke-LabAction -ActionName 'Script' }
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
    if ($providers.Count -gt 0) {
        Write-Host "  Provider: $($providers -join ', ')" -ForegroundColor DarkGray
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
    Write-Host "    [2] Status anzeigen" -ForegroundColor White
    Write-Host "    [3] Umgebung stoppen" -ForegroundColor White
    Write-Host "    [4] Umgebung starten" -ForegroundColor White
    Write-Host "    [5] Umgebung neustarten" -ForegroundColor White
    Write-Host "    [6] Umgebung entfernen" -ForegroundColor White
    Write-Host "    [7] Alles aufraeumen" -ForegroundColor Red
    Write-Host "    [8] Datenbank anlegen" -ForegroundColor White
    Write-Host "    [9] SQL-Skript ausfuehren" -ForegroundColor White
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

            $lab = New-SqlServerLab -Version $version -Provider $provider
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
            New-LabDatabase -Port $port -SaPassword $pw -DatabaseName $dbName
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
            Invoke-LabScript -ScriptPath $scriptPath -Port $port -SaPassword $pw -Database $db
        }
    }
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
