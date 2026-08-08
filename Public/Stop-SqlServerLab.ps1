<#
.SYNOPSIS
    Stoppt eine laufende SQL_Server_Lab-Umgebung.
.DESCRIPTION
    Stoppt Container-Labs je ProviderSubRun. Reguläre Hyper-V-Labs werden
    anhand ihres Workflow-Kinds direkt an den Hyper-V-Lifecycle delegiert.
    Persistente Daten und Run-State bleiben erhalten.
.PARAMETER RunId
    RunId der zu stoppenden Umgebung.
.PARAMETER TimeoutSeconds
    Graceful-Shutdown-Timeout fuer die Container-Runtime.
.PARAMETER Force
    Keine Bestaetigung abfragen.
.PARAMETER StateRoot
    Optionaler State-Root fuer den Lauf. Ohne Angabe wird `Get-LabStateRoot`
    verwendet.
.INPUTS
    System.Object. Objekte mit einer RunId-Eigenschaft koennen ueber die
    Pipeline gebunden werden.
.OUTPUTS
    System.Management.Automation.PSCustomObject. Liefert RunId, Status, Action
    und bei Fehlern deren Anzahl.
.EXAMPLE
    Stop-SqlServerLab -RunId $lab.RunId
#>
function Stop-SqlServerLab {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [string]$RunId,
        [int]$TimeoutSeconds = 10,
        [switch]$Force,
        [string]$StateRoot
    )

    process {
        $stateRoot = if ([string]::IsNullOrWhiteSpace($StateRoot)) { Get-LabStateRoot } else { $StateRoot }
        $run = Get-LabRunState -RunId $RunId -StateRoot $stateRoot
        $run = (Sync-LabRunRuntimeState -Run $run -StateRoot $stateRoot).Run

        if ([string]$run.metadata.workflowKind -eq 'hyperv-lab') {
            if ($run.state -ne 'RUNNING') {
                Write-LabWarning "Lab '$RunId' ist nicht im Status RUNNING (aktuell: $($run.state)). Nichts zu tun."
                return [PSCustomObject]@{ RunId = $RunId; Status = $run.state; Action = 'SKIPPED' }
            }
            if (-not $Force -and -not $PSCmdlet.ShouldProcess($RunId, 'Stop')) {
                return [PSCustomObject]@{ RunId = $RunId; Status = 'RUNNING'; Action = 'CANCELLED' }
            }
            return Stop-HyperVLabEnvironment -RunId $RunId -StateRoot $stateRoot
        }

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

        $providerGroups = @(
            $connectionInfo.instances |
                Where-Object { $_.provider } |
                Group-Object -Property provider |
                Sort-Object Name
        )
        if ($providerGroups.Count -eq 0) {
            throw "Connection-Info fuer Run '$RunId' enthaelt keine verwaltbaren Providerinstanzen."
        }

        $runPrefix = $RunId.Substring(0, 8)
        Write-LabInfo "Stoppe Lab ${runPrefix}... ($($run.metadata.name))"

        $providerResults = @()
        $errors = 0
        foreach ($providerGroup in $providerGroups) {
            $provider = ([string]$providerGroup.Name).ToLowerInvariant()
            $providerErrors = 0
            $stoppedCount = 0
            $runtime = Get-ContainerRuntime -PreferredRuntime $provider
            if (-not $runtime) {
                Write-LabError "  Runtime '$provider' ist fuer den ProviderSubRun nicht verfuegbar."
                $providerResults += [PSCustomObject]@{
                    Provider = $provider
                    Status   = 'FAILED'
                    Stopped  = 0
                    Errors   = 1
                }
                $errors++
                continue
            }

            Write-LabInfo "  ProviderSubRun '$provider' mit $runtime stoppen..."
            $containerIds = @(
                & $runtime ps -q --filter "label=sql-server-lab.run-id=$RunId" 2>$null |
                    Where-Object { $_ }
            )
            if ($containerIds.Count -eq 0) {
                Write-LabInfo "    Keine laufenden Container bei '$provider' gefunden."
            }

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
                    Write-LabSuccess "    Gestoppt: $containerName"
                    $stoppedCount++
                }
                catch {
                    Write-LabError "    Fehler bei ${containerName}: $_"
                    $providerErrors++
                }
            }

            $providerStatus = if ($providerErrors -eq 0) { 'STOPPED' } else { 'FAILED' }
            if ($providerStatus -eq 'STOPPED') {
                Set-LabProviderSubRunState `
                    -RunId $RunId `
                    -Provider $provider `
                    -NewState 'STOPPED' `
                    -Reason 'Stop-SqlServerLab' `
                    -StateRoot $stateRoot
            }
            $providerResults += [PSCustomObject]@{
                Provider = $provider
                Status   = $providerStatus
                Stopped  = $stoppedCount
                Errors   = $providerErrors
            }
            $errors += $providerErrors
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
                ProviderSubRuns = $providerResults
            }
        }

        Write-LabWarning "Lab gestoppt mit $errors Fehler(n)"
        return [PSCustomObject]@{
            RunId  = $RunId
            Status = 'STOPPED_WITH_ERRORS'
            Action = 'PARTIAL'
            Errors = $errors
            ProviderSubRuns = $providerResults
        }
    }
}
