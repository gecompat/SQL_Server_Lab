<#
.SYNOPSIS
    Stoppt eine laufende SQL_Server_Lab-Umgebung.
.DESCRIPTION
    Stoppt alle Container der Umgebung ueber den im Run gespeicherten Provider
    und setzt den State auf STOPPED. Persistente Daten und Run-State bleiben erhalten.
.PARAMETER RunId
    RunId der zu stoppenden Umgebung.
.PARAMETER TimeoutSeconds
    Graceful-Shutdown-Timeout fuer die Container-Runtime.
.PARAMETER Force
    Keine Bestaetigung abfragen.
.EXAMPLE
    Stop-SqlServerLab -RunId $lab.RunId
#>
function Stop-SqlServerLab {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [string]$RunId,
        [int]$TimeoutSeconds = 10,
        [switch]$Force
    )

    process {
        $stateRoot = Get-LabStateRoot
        $run = Get-LabRunState -RunId $RunId -StateRoot $stateRoot

        if ($run.state -ne 'RUNNING') {
            Write-LabWarning "Lab '$RunId' ist nicht im Status RUNNING (aktuell: $($run.state)). Nichts zu tun."
            return [PSCustomObject]@{
                RunId  = $RunId
                Status = $run.state
                Action = 'SKIPPED'
            }
        }

        if (-not $Force -and -not $PSCmdlet.ShouldProcess($RunId, 'Stop')) {
            return [PSCustomObject]@{
                RunId  = $RunId
                Status = 'RUNNING'
                Action = 'CANCELLED'
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
        Write-LabInfo "Stoppe Lab ${runPrefix}... ($($run.metadata.name)) mit $runtime"

        $containerIds = @(
            & $runtime ps -q --filter "label=sql-server-lab.run-id=$RunId" 2>$null |
                Where-Object { $_ }
        )

        if ($containerIds.Count -eq 0) {
            Write-LabInfo '  Keine laufenden Container gefunden.'
        }

        $errors = 0
        foreach ($containerIdValue in $containerIds) {
            $containerId = ([string]$containerIdValue).Trim()
            if (-not $containerId) {
                continue
            }

            $containerName = ([string](& $runtime inspect $containerId --format '{{.Name}}' 2>$null)).Trim().TrimStart('/')

            try {
                & $runtime stop -t $TimeoutSeconds $containerId | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    throw "Container stop fehlgeschlagen: $containerId"
                }
                Write-LabSuccess "  Gestoppt: $containerName"
            }
            catch {
                Write-LabError "  Fehler bei ${containerName}: $_"
                $errors++
            }
        }

        if ($errors -eq 0) {
            $null = Set-LabRunState `
                -RunId $RunId `
                -NewState 'STOPPED' `
                -Reason 'Stop-SqlServerLab' `
                -StateRoot $stateRoot

            Write-LabSuccess "Lab gestoppt: ${runPrefix}..."
            return [PSCustomObject]@{
                RunId  = $RunId
                Status = 'STOPPED'
                Action = 'STOPPED'
            }
        }

        Write-LabWarning "Lab gestoppt mit $errors Fehler(n)"
        return [PSCustomObject]@{
            RunId  = $RunId
            Status = 'STOPPED_WITH_ERRORS'
            Action = 'PARTIAL'
            Errors = $errors
        }
    }
}
