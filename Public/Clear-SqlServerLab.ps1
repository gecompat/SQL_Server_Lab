<#
.SYNOPSIS
    Raeumt alle SQL_Server_Lab-Ressourcen auf.
.DESCRIPTION
    Findet und entfernt alle Lab-Container (via Label sql-server-lab.run-id),
    unabhaengig davon ob sie im State-System erfasst sind. Bereinigt
    zusaetzlich verwaiste State-Eintraege.

    Typische Anwendungsfaelle:
    - Nach abgebrochenen Tests (Container ohne State)
    - Vergessene Lab-Umgebungen
    - Kompletter Reset der Lab-Infrastruktur
.PARAMETER Force
    Keine Bestaetigung abfragen.
.PARAMETER StateOnly
    Nur verwaiste State-Eintraege bereinigen, keine Container anfassen.
.PARAMETER ContainersOnly
    Nur Container entfernen, State nicht anfassen.
.EXAMPLE
    Clear-SqlServerLab
    # Zeigt alle gefundenen Ressourcen, fragt nach Bestaetigung
.EXAMPLE
    Clear-SqlServerLab -Force
    # Entfernt alles ohne Rueckfrage
#>
function Clear-SqlServerLab {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [switch]$Force,
        [switch]$StateOnly,
        [switch]$ContainersOnly
    )

    $ErrorActionPreference = 'Stop'

    Write-LabHeader 'SQL Server Lab - Cleanup'

    $containersFound = @()
    $stateRunsFound = @()
    $removed = @{ Containers = 0; StateRuns = 0; Errors = 0 }

    # =========================================================================
    # 1. Container finden
    # =========================================================================
    if (-not $StateOnly) {
        Write-LabInfo 'Suche Lab-Container (Label: sql-server-lab.run-id)...'

        # Einfaches Format ohne index-Syntax (Windows PowerShell verschluckt Quotes)
        $containerIds = docker ps -a -q --filter 'label=sql-server-lab.run-id' 2>$null
        if ($LASTEXITCODE -eq 0 -and $containerIds) {
            $containersFound = @($containerIds | ForEach-Object {
                $id = $_.Trim()
                if (-not $id) { return }
                # Details per docker inspect holen
                $inspectJson = docker inspect $id 2>$null | ConvertFrom-Json
                if ($inspectJson) {
                    $labels = $inspectJson[0].Config.Labels
                    $name = $inspectJson[0].Name.TrimStart('/')
                    $status = $inspectJson[0].State.Status
                    [PSCustomObject]@{
                        ContainerId = $id.Substring(0, [Math]::Min(12, $id.Length))
                        Name        = $name
                        Status      = $status
                        RunId       = $labels.'sql-server-lab.run-id'
                        Version     = $labels.'sql-server-lab.version'
                        InstanceId  = $labels.'sql-server-lab.instance-id'
                    }
                }
            })
        }

        if ($containersFound.Count -eq 0) {
            Write-LabInfo 'Keine Lab-Container gefunden.'
        }
        else {
            Write-LabWarning "$($containersFound.Count) Lab-Container gefunden:"
            foreach ($c in $containersFound) {
                $runPrefix = if ($c.RunId.Length -ge 8) { $c.RunId.Substring(0,8) } else { $c.RunId }
                Write-LabStatus -Label "  $($c.Name)" -Value "SQL $($c.Version), Run: ${runPrefix}..., $($c.Status)"
            }
        }
    }

    # =========================================================================
    # 2. Verwaiste State-Eintraege finden
    # =========================================================================
    if (-not $ContainersOnly) {
        Write-LabInfo 'Suche State-Eintraege...'

        $stateRoot = Get-LabStateRoot
        $runsDir = Join-Path $stateRoot 'runs'

        if (Test-Path $runsDir) {
            $runDirs = Get-ChildItem -Path $runsDir -Directory
            foreach ($dir in $runDirs) {
                $stateFile = Join-Path $dir.FullName 'run-state.json'
                if (Test-Path $stateFile) {
                    try {
                        $state = Get-Content $stateFile -Raw | ConvertFrom-Json
                        $stateRunsFound += [PSCustomObject]@{
                            RunId   = $dir.Name
                            State   = $state.state
                            Name    = $state.metadata.name
                            Created = $state.createdAt
                            Path    = $dir.FullName
                        }
                    }
                    catch {
                        $stateRunsFound += [PSCustomObject]@{
                            RunId   = $dir.Name
                            State   = '(CORRUPT)'
                            Name    = '?'
                            Created = '?'
                            Path    = $dir.FullName
                        }
                    }
                }
            }
        }

        # Nur nicht-REMOVED anzeigen (REMOVED = bereits aufgeraeumt)
        $activeStates = $stateRunsFound | Where-Object { $_.State -ne 'REMOVED' }

        if ($activeStates.Count -eq 0) {
            Write-LabInfo 'Keine aktiven State-Eintraege gefunden.'
        }
        else {
            Write-LabWarning "$($activeStates.Count) aktive State-Eintraege:"
            foreach ($s in $activeStates) {
                $runPrefix = if ($s.RunId.Length -ge 8) { $s.RunId.Substring(0,8) } else { $s.RunId }
                Write-LabStatus -Label "  ${runPrefix}..." -Value "$($s.State) - $($s.Name) ($($s.Created))"
            }
        }
    }

    # =========================================================================
    # 3. Nichts zu tun?
    # =========================================================================
    $totalWork = $containersFound.Count + ($stateRunsFound | Where-Object { $_.State -ne 'REMOVED' }).Count
    if ($totalWork -eq 0) {
        Write-LabSuccess 'Alles sauber. Nichts zu entfernen.'
        return [PSCustomObject]@{ Containers = 0; StateRuns = 0; Errors = 0; Status = 'CLEAN' }
    }

    # =========================================================================
    # 4. Bestaetigung
    # =========================================================================
    if (-not $Force) {
        Write-Host ''
        $confirm = Read-LabConfirm -Prompt "$($containersFound.Count) Container + $($activeStates.Count) State-Eintraege entfernen?"
        if (-not $confirm) {
            Write-LabInfo 'Abgebrochen.'
            return [PSCustomObject]@{ Containers = 0; StateRuns = 0; Errors = 0; Status = 'CANCELLED' }
        }
    }

    # =========================================================================
    # 5. Container entfernen
    # =========================================================================
    if (-not $StateOnly) {
        foreach ($c in $containersFound) {
            Write-LabInfo "Entferne Container: $($c.Name)..."
            try {
                docker rm -f $c.ContainerId 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    Write-LabSuccess "  Entfernt: $($c.Name)"
                    $removed.Containers++
                }
                else {
                    Write-LabError "  Fehler bei $($c.Name)"
                    $removed.Errors++
                }
            }
            catch {
                Write-LabError "  $($c.Name): $_"
                $removed.Errors++
            }
        }
    }

    # =========================================================================
    # 6. State-Eintraege bereinigen
    # =========================================================================
    if (-not $ContainersOnly) {
        foreach ($s in $activeStates) {
            Write-LabInfo "State bereinigen: $($s.RunId.Substring(0,8))... ($($s.State))..."
            try {
                # State auf REMOVED setzen
                $stateFile = Join-Path $s.Path 'run-state.json'
                $state = Get-Content $stateFile -Raw | ConvertFrom-Json
                $state.state = 'REMOVED'
                $state | ConvertTo-Json -Depth 10 | Set-Content $stateFile -Encoding utf8

                # Secrets loeschen
                $secretsDir = Join-Path $s.Path 'secrets'
                if (Test-Path $secretsDir) {
                    Get-ChildItem $secretsDir -File | Remove-Item -Force
                }

                Write-LabSuccess "  Bereinigt: $($s.RunId.Substring(0,8))..."
                $removed.StateRuns++
            }
            catch {
                Write-LabError "  State-Fehler: $_"
                $removed.Errors++
            }
        }
    }

    # =========================================================================
    # 7. Ergebnis
    # =========================================================================
    Write-Host ''
    Write-LabHeader 'Cleanup abgeschlossen'
    Write-LabStatus -Label 'Container entfernt' -Value $removed.Containers -Color 'Green'
    Write-LabStatus -Label 'State bereinigt' -Value $removed.StateRuns -Color 'Green'
    if ($removed.Errors -gt 0) {
        Write-LabStatus -Label 'Fehler' -Value $removed.Errors -Color 'Red'
    }

    return [PSCustomObject]@{
        Containers = $removed.Containers
        StateRuns  = $removed.StateRuns
        Errors     = $removed.Errors
        Status     = if ($removed.Errors -eq 0) { 'CLEAN' } else { 'PARTIAL' }
    }
}
