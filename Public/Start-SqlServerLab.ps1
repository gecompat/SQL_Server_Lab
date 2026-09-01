<#
.SYNOPSIS
    Startet eine gestoppte SQL_Server_Lab-Umgebung.
.DESCRIPTION
    Startet Container-Labs je ProviderSubRun. Reguläre Hyper-V-Labs werden
    anhand ihres Workflow-Kinds direkt an den Hyper-V-Lifecycle delegiert;
    sie werden nie als Container interpretiert. Bei Container-Labs wird danach
    optional die SQL- und Datenbank-Bereitschaft geprueft.
.PARAMETER RunId
    RunId der zu startenden Umgebung.
.PARAMETER SkipReadyCheck
    SQL- und Datenbank-Readiness-Pruefung ueberspringen.
.PARAMETER TimeoutSeconds
    Maximale Wartezeit fuer SQL- und Datenbank-Bereitschaft pro Instanz.
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
    Start-SqlServerLab -RunId $lab.RunId
#>
function Start-SqlServerLab {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [string]$RunId,
        [switch]$SkipReadyCheck,
        [int]$TimeoutSeconds = 60,
        [string]$StateRoot
    )

    process {
        $stateRoot = if ([string]::IsNullOrWhiteSpace($StateRoot)) { Get-LabStateRoot } else { $StateRoot }
        if ((Test-LabAutomatedTestEnvironmentRun -RunId $RunId) -and
            -not [bool]$script:LabAutomatedTestEnvironmentGroupOperation) {
            throw 'TEST_ENVIRONMENT_GROUP_PROTECTED: Einzelnes Starten ist gesperrt; Testumgebungen verwenden AutoStart=on.'
        }
        $run = Get-LabRunState -RunId $RunId -StateRoot $stateRoot
        $run = (Sync-LabRunRuntimeState -Run $run -StateRoot $stateRoot).Run

        # Reguläre Hyper-V-Labs besitzen ebenfalls einen ProviderSubRun. Dieser
        # ist aber ausdrücklich keine Container-Runtime. Die generische
        # Hauptmenüaktion muss daher vor jeder docker/podman-Auflösung an den
        # zustandsgeführten Hyper-V-Workflow delegieren.
        if ([string]$run.metadata.workflowKind -eq 'hyperv-lab') {
            if ($run.state -ne 'STOPPED') {
                Write-LabWarning "Lab '$RunId' ist nicht im Status STOPPED (aktuell: $($run.state)). Nichts zu tun."
                return [PSCustomObject]@{ RunId = $RunId; Status = $run.state; Action = 'SKIPPED' }
            }
            return Start-HyperVLabEnvironment -RunId $RunId -StateRoot $stateRoot
        }

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
        Write-LabInfo "Starte Lab ${runPrefix}... ($($run.metadata.name))"

        $providerResults = @()
        $errors = 0
        $startedCount = 0

        foreach ($providerGroup in $providerGroups) {
            $provider = ([string]$providerGroup.Name).ToLowerInvariant()
            $providerErrors = 0
            $providerStarted = 0
            $runtime = Get-ContainerRuntime -PreferredRuntime $provider
            if (-not $runtime) {
                Write-LabError "  Runtime '$provider' ist fuer den ProviderSubRun nicht verfuegbar."
                $providerResults += [PSCustomObject]@{
                    Provider = $provider
                    Status   = 'FAILED'
                    Started  = 0
                    Errors   = 1
                }
                $errors++
                continue
            }
            $runtimeInvocation = Get-LabHostToolInvocation -Name $runtime

            Write-LabInfo "  ProviderSubRun '$provider' mit $runtime starten..."
            $containerIds = @(
                & $runtimeInvocation ps -a -q --filter "label=sql-server-lab.run-id=$RunId" 2>$null |
                    Where-Object { $_ }
            )
            if ($containerIds.Count -lt $providerGroup.Count) {
                Write-LabError "  ProviderSubRun '$provider': Erwartet $($providerGroup.Count) Container, gefunden: $($containerIds.Count)."
                $providerErrors++
            }

            foreach ($containerIdValue in $containerIds) {
                $containerId = ([string]$containerIdValue).Trim()
                if (-not $containerId) {
                    continue
                }

                $containerName = ([string](& $runtimeInvocation inspect $containerId --format '{{.Name}}' 2>$null)).Trim().TrimStart('/')
                try {
                    $runningText = [string](& $runtimeInvocation inspect $containerId --format '{{.State.Running}}' 2>$null)
                    if ($LASTEXITCODE -ne 0) {
                        throw "Container-Status konnte nicht gelesen werden: $containerId"
                    }

                    $isRunning = $runningText.Trim().ToLowerInvariant() -eq 'true'
                    if (-not $isRunning) {
                        & $runtimeInvocation start $containerId | Out-Null
                        if ($LASTEXITCODE -ne 0) {
                            throw "Container start fehlgeschlagen: $containerId"
                        }
                        Write-LabSuccess "    Gestartet: $containerName"
                    }
                    else {
                        Write-LabInfo "    Laeuft bereits: $containerName"
                    }

                    $providerStarted++
                    $startedCount++
                }
                catch {
                    Write-LabError "    Fehler bei ${containerName}: $_"
                    $providerErrors++
                }
            }

            $providerStatus = if ($providerErrors -eq 0 -and $providerStarted -ge $providerGroup.Count) { 'STARTED' } else { 'FAILED' }
            if ($providerStatus -eq 'STARTED') {
                Set-LabProviderSubRunState `
                    -RunId $RunId `
                    -Provider $provider `
                    -NewState 'RUNNING' `
                    -Reason 'Start-SqlServerLab' `
                    -StateRoot $stateRoot
            }
            $providerResults += [PSCustomObject]@{
                Provider = $provider
                Status   = $providerStatus
                Started  = $providerStarted
                Errors   = $providerErrors
            }
            $errors += $providerErrors
        }

        if ($startedCount -eq 0) {
            Write-LabError 'Kein Container konnte gestartet werden.'
            return [PSCustomObject]@{
                RunId  = $RunId
                Status = 'STOPPED'
                Action = 'FAILED'
                Errors = $errors
                ProviderSubRuns = $providerResults
            }
        }

        if ($errors -gt 0) {
            Write-LabWarning "Lab wurde nur teilweise gestartet ($errors Fehler). Bereits gestartete ProviderSubRuns werden zurueckgerollt."
            $rollbackErrors = 0
            foreach ($providerResult in @($providerResults | Where-Object { $_.Status -eq 'STARTED' })) {
                $providerRollbackErrors = 0
                $runtime = Get-ContainerRuntime -PreferredRuntime $providerResult.Provider
                if (-not $runtime) {
                    $rollbackErrors++
                    continue
                }
                $runtimeInvocation = Get-LabHostToolInvocation -Name $runtime

                $containerIds = @(
                    & $runtimeInvocation ps -q --filter "label=sql-server-lab.run-id=$RunId" 2>$null |
                        Where-Object { $_ }
                )
                foreach ($containerIdValue in $containerIds) {
                    $containerId = ([string]$containerIdValue).Trim()
                    if (-not $containerId) {
                        continue
                    }
                    & $runtimeInvocation stop $containerId 1>$null 2>$null
                    if ($LASTEXITCODE -ne 0) {
                        $providerRollbackErrors++
                        $rollbackErrors++
                    }
                }

                if ($providerRollbackErrors -eq 0) {
                    Set-LabProviderSubRunState `
                        -RunId $RunId `
                        -Provider $providerResult.Provider `
                        -NewState 'STOPPED' `
                        -Reason 'Start-SqlServerLab Rollback' `
                        -StateRoot $stateRoot
                    $providerResult.Status = 'ROLLED_BACK'
                }
            }

            $errors += $rollbackErrors
            if ($rollbackErrors -gt 0) {
                $null = Set-LabRunState `
                    -RunId $RunId `
                    -NewState 'CLEANUP_PENDING' `
                    -Reason 'Start-Rollback unvollstaendig' `
                    -StateRoot $stateRoot
                foreach ($providerSubRun in @(Get-LabProviderSubRuns -RunId $RunId -StateRoot $stateRoot)) {
                    if ($providerSubRun.state -notin @('CLEANUP_PENDING', 'CLEANUP_RUNNING', 'CLEANED_UP', 'REMOVED')) {
                        Set-LabProviderSubRunState `
                            -RunId $RunId `
                            -Provider $providerSubRun.provider `
                            -NewState 'CLEANUP_PENDING' `
                            -Reason 'Start-Rollback unvollstaendig' `
                            -StateRoot $stateRoot
                    }
                }
                return [PSCustomObject]@{
                    RunId  = $RunId
                    Status = 'RECOVERY_REQUIRED'
                    Action = 'PARTIAL'
                    Errors = $errors
                    ProviderSubRuns = $providerResults
                }
            }

            return [PSCustomObject]@{
                RunId  = $RunId
                Status = 'STOPPED_WITH_ERRORS'
                Action = 'PARTIAL'
                Errors = $errors
                ProviderSubRuns = $providerResults
            }
        }

        if (-not $SkipReadyCheck -and $connectionInfo -and $connectionInfo.instances) {
            $saPassword = Get-LabSecret -Path $runDirectory -Name 'sa-password'
            foreach ($instance in $connectionInfo.instances) {
                if (-not $instance.port) {
                    continue
                }

                try {
                    $readinessProvider = ([string]$instance.provider).ToLowerInvariant()
                    $readinessContainer = @([string]$instance.containerId, [string]$instance.containerName) | Where-Object { $_ } | Select-Object -First 1
                    $sqlReadiness = Wait-SqlReady `
                        -HostName $(if ($instance.host) { $instance.host } else { '127.0.0.1' }) `
                        -Port $instance.port `
                        -SaPassword $saPassword `
                        -TimeoutSeconds $TimeoutSeconds `
                        -Provider $readinessProvider `
                        -ContainerIdOrName $readinessContainer

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
            ProviderSubRuns = $providerResults
        }
    }
}
