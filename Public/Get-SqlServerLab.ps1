<#
.SYNOPSIS
    Zeigt Status aller oder einzelner SQL_Server_Lab-Umgebungen.
.PARAMETER RunId
    Optional: Nur diese RunId anzeigen.
.PARAMETER Detailed
    Erweiterte Informationen wie State-History und Fehler anzeigen.
.EXAMPLE
    Get-SqlServerLab
.EXAMPLE
    Get-SqlServerLab -RunId $lab.RunId -Detailed
#>
function Get-SqlServerLab {
    [CmdletBinding()]
    param(
        [string]$RunId,
        [switch]$Detailed
    )

    $stateRoot = Get-LabStateRoot

    $runs = if ($RunId) {
        @(Get-LabRunState -RunId $RunId -StateRoot $stateRoot)
    }
    else {
        @(Get-LabActiveRuns -StateRoot $stateRoot)
    }

    if ($runs.Count -eq 0) {
        Write-LabInfo 'Keine aktiven Lab-Umgebungen gefunden.'
        return @()
    }

    $results = @()

    foreach ($run in $runs) {
        $runDirectory = Join-Path (Join-Path $stateRoot 'runs') $run.runId
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

        $containerMap = @{}
        $runtimeError = $null

        if ($providers.Count -le 1) {
            $preferredRuntime = if ($providers.Count -eq 1) { $providers[0] } else { $null }
            $runtime = Get-ContainerRuntime -PreferredRuntime $preferredRuntime

            if ($runtime) {
                $containerIds = @(
                    & $runtime ps -a -q --filter "label=sql-server-lab.run-id=$($run.runId)" 2>$null |
                        Where-Object { $_ }
                )

                foreach ($containerIdValue in $containerIds) {
                    $containerId = ([string]$containerIdValue).Trim()
                    if (-not $containerId) {
                        continue
                    }

                    try {
                        $inspectJson = & $runtime inspect $containerId 2>$null | ConvertFrom-Json -Depth 30
                        if (-not $inspectJson) {
                            continue
                        }

                        $inspectItem = @($inspectJson)[0]
                        $labels = $inspectItem.Config.Labels
                        $instanceId = $labels.'sql-server-lab.instance-id'
                        $healthStatus = if ($inspectItem.State.Health) { $inspectItem.State.Health.Status } else { $null }

                        $containerMap[$instanceId] = @{
                            Name    = ([string]$inspectItem.Name).TrimStart('/')
                            Running = $inspectItem.State.Status -eq 'running'
                            Healthy = $healthStatus -eq 'healthy'
                        }
                    }
                    catch {
                        $runtimeError = "Container-Status konnte nicht gelesen werden: $($_.Exception.Message)"
                    }
                }
            }
            elseif ($preferredRuntime) {
                $runtimeError = "Container-Runtime '$preferredRuntime' ist lokal nicht verfuegbar."
            }
        }
        else {
            $runtimeError = 'Gemischte Provider werden im gemeinsamen Lifecycle noch nicht unterstuetzt.'
        }

        $instances = @()
        $instanceList = if ($connectionInfo -and $connectionInfo.instances) {
            @($connectionInfo.instances)
        }
        else {
            @()
        }

        foreach ($instance in $instanceList) {
            $containerInfo = $containerMap[$instance.id]
            $instances += [PSCustomObject]@{
                Id            = $instance.id
                Version       = $instance.version
                Provider      = $instance.provider
                Host          = $instance.host
                Port          = $instance.port
                ContainerName = if ($containerInfo) { $containerInfo.Name } else { '' }
                ContainerUp   = if ($containerInfo) { $containerInfo.Running } else { $false }
                Healthy       = if ($containerInfo) { $containerInfo.Healthy } else { $false }
            }
        }

        $labInfo = [PSCustomObject]@{
            RunId       = $run.runId
            ScopeId     = $run.scopeId
            State       = $run.state
            Name        = $run.metadata.name
            CreatedAt   = $run.createdAt
            UpdatedAt   = $run.updatedAt
            Instances   = $instances
            RuntimeNote = $runtimeError
        }

        if ($Detailed) {
            $labInfo | Add-Member -NotePropertyName 'StateHistory' -NotePropertyValue $run.stateHistory
            $labInfo | Add-Member -NotePropertyName 'Errors' -NotePropertyValue $run.errors
        }

        $results += $labInfo
    }

    Write-LabHeader 'SQL Server Lab - Status'

    foreach ($lab in $results) {
        Write-Host ''
        Write-LabStatus -Label 'RunId' -Value "$($lab.RunId)  [$($lab.State)]"
        Write-LabStatus -Label 'Name' -Value $lab.Name
        Write-LabStatus -Label 'Erstellt' -Value $lab.CreatedAt

        foreach ($instance in $lab.Instances) {
            $upText = if ($instance.ContainerUp) { '[UP]' } else { '[DOWN]' }
            $healthText = if ($instance.Healthy) { ' healthy' } else { '' }
            Write-LabStatus `
                -Label "  $($instance.Id)" `
                -Value "$($instance.Host):$($instance.Port) (SQL $($instance.Version), $($instance.Provider)) $upText$healthText"
        }

        if ($lab.RuntimeNote) {
            Write-LabWarning "  $($lab.RuntimeNote)"
        }

        if ($Detailed -and $lab.Errors.Count -gt 0) {
            Write-LabWarning "  Fehler: $($lab.Errors.Count)"
            foreach ($errorItem in $lab.Errors) {
                Write-Host "    $($errorItem.timestamp): $($errorItem.message)" -ForegroundColor Red
            }
        }
    }

    return $results
}
