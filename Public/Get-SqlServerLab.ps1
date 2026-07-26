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
        # Container-Status live abfragen
        $instances = @()
        foreach ($inst in $run.instances) {
            $containerStatus = $null
            if ($inst.containerName) {
                $containerStatus = Get-DockerInstanceStatus -ContainerIdOrName $inst.containerName
            }

            $instances += [PSCustomObject]@{
                Id            = $inst.instanceId
                Version       = $inst.version
                Provider      = $inst.provider
                Host          = $inst.host
                Port          = $inst.port
                ContainerName = $inst.containerName
                ContainerUp   = if ($containerStatus) { $containerStatus.Running } else { $false }
                Healthy       = if ($containerStatus) { $containerStatus.Healthy } else { $false }
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
