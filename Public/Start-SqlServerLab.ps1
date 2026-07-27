<#
.SYNOPSIS
    Startet eine gestoppte SQL_Server_Lab-Umgebung.
.DESCRIPTION
    Startet alle Container der Umgebung mit dem Provider, der in
    connection-info.json fuer den Run gespeichert ist. Danach wird optional
    die SQL- und Datenbank-Bereitschaft geprueft und der State auf RUNNING gesetzt.
.PARAMETER RunId
    RunId der zu startenden Umgebung.
.PARAMETER SkipReadyCheck
    SQL- und Datenbank-Readiness-Pruefung ueberspringen.
.PARAMETER TimeoutSeconds
    Maximale Wartezeit fuer SQL- und Datenbank-Bereitschaft pro Instanz.
.EXAMPLE
    Start-SqlServerLab -RunId $lab.RunId
#>
function Start-SqlServerLab {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [string]$RunId,
        [switch]$SkipReadyCheck,
        [int]$TimeoutSeconds = 60
    )

    process {
        $stateRoot = Get-LabStateRoot
        $run = Get-LabRunState -RunId $RunId -StateRoot $stateRoot

        if ($run.state -ne 'STOPPED') {
            Write-LabWarning "Lab '$RunId' ist nicht im Status STOPPED (aktuell: $($run.state)). Nichts zu tun."
            return [PSCustomObject]@{
                RunId  = $RunId
                Status = $run.state
                Action = 'SKIPPED'
            }
        }

        $runDirectory = Join-Path (Join-Path $stateRoot 'runs') $RunId
        $connectionInfoPath = Join-Path $runDirectory 'connection-info.json'
        $connectionInfo = if (Test-Path -LiteralPath $connectionInfoPath -PathType Leaf) {
            Get-Content -LiteralPath $connectionInfoPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 20
        }
        else {
            $null
        }

        $providers = @(
            $connectionInfo.instances |
                ForEach-Object { $_.provider } |
                Where-Object { $_ } |
                Sort-Object -Unique
        )

        if ($providers.Count -gt 1) {
            throw "Run '$RunId' verwendet mehrere Provider. Der gemeinsame Lifecycle fuer gemischte Provider ist noch nicht implementiert."
        }

        $preferredRuntime = if ($providers.Count -eq 1) { $providers[0] } else { $null }
        $runtime = Get-ContainerRuntime -PreferredRuntime $preferredRuntime
        if (-not $runtime) {
            throw "Container-Runtime '$preferredRuntime' ist nicht verfuegbar."
        }

        $runPrefix = $RunId.Substring(0, 8)
        Write-LabInfo "Starte Lab ${runPrefix}... ($($run.metadata.name)) mit $runtime"

        $containerIds = @(
            & $runtime ps -a -q --filter "label=sql-server-lab.run-id=$RunId" 2>$null |
                Where-Object { $_ }
        )

        if ($containerIds.Count -eq 0) {
            Write-LabError '  Keine Container fuer diesen Run gefunden.'
            return [PSCustomObject]@{
                RunId  = $RunId
                Status = 'STOPPED'
                Action = 'FAILED'
                Errors = 1
            }
        }

        $errors = 0
        $startedCount = 0

        foreach ($containerIdValue in $containerIds) {
            $containerId = ([string]$containerIdValue).Trim()
            if (-not $containerId) {
                continue
            }

            $containerName = ([string](& $runtime inspect $containerId --format '{{.Name}}' 2>$null)).Trim().TrimStart('/')

            try {
                $runningText = [string](& $runtime inspect $containerId --format '{{.State.Running}}' 2>$null)
                if ($LASTEXITCODE -ne 0) {
                    throw "Container-Status konnte nicht gelesen werden: $containerId"
                }

                $isRunning = $runningText.Trim().ToLowerInvariant() -eq 'true'
                if (-not $isRunning) {
                    & $runtime start $containerId | Out-Null
                    if ($LASTEXITCODE -ne 0) {
                        throw "Container start fehlgeschlagen: $containerId"
                    }
                    Write-LabSuccess "  Gestartet: $containerName"
                }
                else {
                    Write-LabInfo "  Laeuft bereits: $containerName"
                }

                $startedCount++
            }
            catch {
                Write-LabError "  Fehler bei ${containerName}: $_"
                $errors++
            }
        }

        if ($startedCount -eq 0) {
            Write-LabError 'Kein Container konnte gestartet werden.'
            return [PSCustomObject]@{
                RunId  = $RunId
                Status = 'STOPPED'
                Action = 'FAILED'
                Errors = $errors
            }
        }

        if (-not $SkipReadyCheck -and $connectionInfo -and $connectionInfo.instances) {
            $saPassword = Get-LabSecret -Path $runDirectory -Name 'sa-password'
            foreach ($instance in $connectionInfo.instances) {
                if (-not $instance.port) {
                    continue
                }

                try {
                    $sqlReadiness = Wait-SqlReady `
                        -HostName $(if ($instance.host) { $instance.host } else { '127.0.0.1' }) `
                        -Port $instance.port `
                        -SaPassword $saPassword `
                        -TimeoutSeconds $TimeoutSeconds

                    if (-not $sqlReadiness.Ready) {
                        throw $sqlReadiness.Message
                    }

                    foreach ($database in @($instance.databases | Where-Object { $_ -and $_ -ne 'master' })) {
                        $databaseReadiness = Wait-LabDatabaseReady `
                            -HostName $(if ($instance.host) { $instance.host } else { '127.0.0.1' }) `
                            -Port $instance.port `
                            -SaPassword $saPassword `
                            -Database $database `
                            -TimeoutSeconds $TimeoutSeconds

                        if (-not $databaseReadiness.Ready) {
                            throw $databaseReadiness.Message
                        }
                    }
                }
                catch {
                    Write-LabWarning "  Readiness-Check fuer '$($instance.id)' fehlgeschlagen: $_ (Container laeuft trotzdem)"
                    $errors++
                }
            }
        }

        $null = Set-LabRunState `
            -RunId $RunId `
            -NewState 'RUNNING' `
            -Reason 'Start-SqlServerLab' `
            -StateRoot $stateRoot

        Write-LabSuccess "Lab gestartet: ${runPrefix}..."

        return [PSCustomObject]@{
            RunId  = $RunId
            Status = 'RUNNING'
            Action = 'STARTED'
            Errors = $errors
        }
    }
}
