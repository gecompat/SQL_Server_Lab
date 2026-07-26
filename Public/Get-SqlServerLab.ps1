<#
.SYNOPSIS
    Zeigt Status aller oder einzelner SQL_Server_Lab-Umgebungen.
.PARAMETER RunId
    Optional: Nur diese RunId anzeigen.
.PARAMETER Detailed
    Erweiterte Informationen (State-History, Fehler).
.EXAMPLE
    Get-SqlServerLab
.EXAMPLE
    Get-SqlServerLab -RunId '466cdd08-...' -Detailed
#>
function Get-SqlServerLab {
    [CmdletBinding()]
    param(
        [string]$RunId,
        [switch]$Detailed
    )

    $stateRoot = Get-LabStateRoot

    # Einzelner Run oder alle aktiven?
    if ($RunId) {
        $runs = @(Get-LabRunState -RunId $RunId -StateRoot $stateRoot)
    }
    else {
        $runs = @(Get-LabActiveRuns -StateRoot $stateRoot)
    }

    if ($runs.Count -eq 0) {
        Write-LabInfo 'Keine aktiven Lab-Umgebungen gefunden.'
        return @()
    }

    $results = @()

    foreach ($run in $runs) {
        # Instanz-Daten aus connection-info.json + Docker live-Status
        $instances = @()
        $connInfoPath = Join-Path $stateRoot 'runs' $run.runId 'connection-info.json'
        $connInfo = if (Test-Path $connInfoPath) {
            Get-Content $connInfoPath -Raw | ConvertFrom-Json
        } else { $null }

        # Container via Docker-Labels finden (live, zuverlaessig)
        $containers = docker ps -a -q --filter "label=sql-server-lab.run-id=$($run.runId)" 2>$null
        $containerMap = @{}
        if ($containers) {
            $containers | ForEach-Object {
                $id = $_.Trim()
                if (-not $id) { return }
                $inspectJson = docker inspect $id 2>$null | ConvertFrom-Json
                if ($inspectJson) {
                    $labels = $inspectJson[0].Config.Labels
                    $instId = $labels.'sql-server-lab.instance-id'
                    $containerMap[$instId] = @{
                        Name    = $inspectJson[0].Name.TrimStart('/')
                        Running = $inspectJson[0].State.Status -eq 'running'
                        Healthy = $inspectJson[0].State.Health.Status -eq 'healthy'
                    }
                }
            }
        }

        # Instanzen zusammenbauen
        $instList = if ($connInfo -and $connInfo.instances) { $connInfo.instances } else { @() }
        foreach ($inst in $instList) {
            $cInfo = $containerMap[$inst.id]
            $instances += [PSCustomObject]@{
                Id            = $inst.id
                Version       = $inst.version
                Provider      = $inst.provider
                Host          = $inst.host
                Port          = $inst.port
                ContainerName = if ($cInfo) { $cInfo.Name } else { '' }
                ContainerUp   = if ($cInfo) { $cInfo.Running } else { $false }
                Healthy       = if ($cInfo) { $cInfo.Healthy } else { $false }
            }
        }

        $labInfo = [PSCustomObject]@{
            RunId      = $run.runId
            ScopeId    = $run.scopeId
            State      = $run.state
            Name       = $run.metadata.name
            CreatedAt  = $run.createdAt
            UpdatedAt  = $run.updatedAt
            Instances  = $instances
        }

        if ($Detailed) {
            $labInfo | Add-Member -NotePropertyName 'StateHistory' -NotePropertyValue $run.stateHistory
            $labInfo | Add-Member -NotePropertyName 'Errors' -NotePropertyValue $run.errors
        }

        $results += $labInfo
    }

    # Ausgabe
    Write-LabHeader 'SQL Server Lab - Status'

    foreach ($lab in $results) {
        $runPrefix = $lab.RunId.Substring(0, 8)
        Write-Host ''
        Write-LabStatus -Label 'RunId' -Value "$($lab.RunId)  [$($lab.State)]"
        Write-LabStatus -Label 'Name' -Value $lab.Name
        Write-LabStatus -Label 'Erstellt' -Value $lab.CreatedAt

        foreach ($inst in $lab.Instances) {
            $upIcon = if ($inst.ContainerUp) { '[UP]' } else { '[DOWN]' }
            $healthIcon = if ($inst.Healthy) { ' healthy' } else { '' }
            Write-LabStatus -Label "  $($inst.Id)" -Value "$($inst.Host):$($inst.Port) (SQL $($inst.Version)) $upIcon$healthIcon"
        }

        if ($Detailed -and $lab.Errors.Count -gt 0) {
            Write-LabWarning "  Fehler: $($lab.Errors.Count)"
            foreach ($err in $lab.Errors) {
                Write-Host "    $($err.timestamp): $($err.message)" -ForegroundColor Red
            }
        }
    }

    return $results
}
