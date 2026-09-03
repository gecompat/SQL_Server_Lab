<#
.SYNOPSIS
    Zeigt Status aller oder einzelner SQL_Server_Lab-Umgebungen.
.DESCRIPTION
    Liest den gespeicherten Run-State und ergaenzt ihn, soweit moeglich, um den
    Live-Status der zugeordneten Docker-/Podman-Container oder Hyper-V-VMs.
    Kataloggebundene Container-Tools werden als sanitisierte Identitaets- und
    Versionsmetadaten angezeigt; Quellen, lokale Image-IDs und Receipts bleiben
    außerhalb der öffentlichen Statussicht.
    Mehrere Provider innerhalb eines Runs werden getrennt abgefragt. Der
    Runtime-Status einer Hyper-V-VM wird nicht als ungepruefter SQL-Status
    ausgegeben. Das Cmdlet veraendert weder Run-State noch Providerressourcen.
.PARAMETER RunId
    Optional: Nur diese RunId anzeigen.
.PARAMETER Detailed
    Erweiterte Informationen wie State-History und Fehler anzeigen.
.OUTPUTS
    System.Management.Automation.PSCustomObject. Liefert pro Run Status,
    Metadaten und Instanzinformationen; ohne gefundene Runs wird nichts
    ausgegeben.
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

        $containerMap = @{}
        $runtimeNotes = @()
        $providerGroups = @(
            $connectionInfo.instances |
                Where-Object { $_.provider } |
                Group-Object -Property provider |
                Sort-Object Name
        )

        foreach ($providerGroup in $providerGroups) {
            $provider = ([string]$providerGroup.Name).ToLowerInvariant()
            if ($provider -notin @('docker', 'podman')) { continue }
            $runtime = Get-ContainerRuntime -PreferredRuntime $provider
            if (-not $runtime) {
                $runtimeNotes += "Container-Runtime '$provider' ist lokal nicht verfuegbar."
                continue
            }
            $runtimeInvocation = Get-LabHostToolInvocation -Name $runtime

            $containerIds = @(
                & $runtimeInvocation ps -a -q --filter "label=sql-server-lab.run-id=$($run.runId)" 2>$null |
                    Where-Object { $_ }
            )

            foreach ($containerIdValue in $containerIds) {
                $containerId = ([string]$containerIdValue).Trim()
                if (-not $containerId) {
                    continue
                }

                try {
                    $inspectJson = & $runtimeInvocation inspect $containerId 2>$null | ConvertFrom-Json -Depth 30
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
                        AutoStart = ([string]$inspectItem.HostConfig.RestartPolicy.Name -in @('always', 'unless-stopped') -and [string]$labels.'sql-server-lab.autostart' -eq 'on')
                    }
                }
                catch {
                    $runtimeNotes += "Container-Status fuer Provider '$provider' konnte nicht gelesen werden: $($_.Exception.Message)"
                }
            }
        }

        $instances = @()
        $instanceList = if ($connectionInfo -and $connectionInfo.instances) {
            @($connectionInfo.instances)
        }
        else {
            @()
        }

        foreach ($instance in $instanceList) {
            $provider = ([string]$instance.provider).ToLowerInvariant()
            $containerInfo = if ($provider -in @('docker', 'podman')) { $containerMap[$instance.id] } else { $null }
            $hyperVInfo = $null
            $instanceRuntimeNote = ''
            if ($provider -eq 'hyperv') {
                if ([string]::IsNullOrWhiteSpace([string]$instance.vmName)) {
                    $instanceRuntimeNote = "Hyper-V-Status fuer Instanz '$($instance.id)' ist ohne VM-Namen nicht pruefbar."
                }
                else {
                    try {
                        $hyperVInfo = Get-HyperVInstanceStatus -VMName ([string]$instance.vmName) `
                            -ExpectedRunId ([string]$run.runId) -ExpectedScopeId ([string]$run.scopeId)
                    }
                    catch {
                        $instanceRuntimeNote = "Hyper-V-Status fuer VM '$($instance.vmName)' konnte nicht gelesen werden: $($_.Exception.Message)"
                    }
                }
            }
            elseif ($provider -notin @('docker', 'podman')) {
                $instanceRuntimeNote = "Provider '$provider' besitzt keine Statusabfrage."
            }
            if ($instanceRuntimeNote) { $runtimeNotes += $instanceRuntimeNote }
            $runtimeName = if ($containerInfo) { [string]$containerInfo.Name } elseif ($hyperVInfo) { [string]$hyperVInfo.VMName } elseif ($instance.vmName) { [string]$instance.vmName } else { '' }
            $running = if ($containerInfo) { [bool]$containerInfo.Running } elseif ($hyperVInfo) { [bool]($hyperVInfo.Exists -and [string]$hyperVInfo.State -eq 'Running') } else { $false }
            $runtimeState = if ($containerInfo) { if ($containerInfo.Running) { 'Running' } else { 'Stopped' } } elseif ($hyperVInfo) { [string]$hyperVInfo.State } else { 'Unverifiable' }
            $instances += [PSCustomObject]@{
                Id            = $instance.id
                Version       = if ($instance.version) { [string]$instance.version } else { [string]$instance.sqlVersion }
                Workload      = if ($instance.workload) { [string]$instance.workload } elseif ($instance.version) { 'sql' } else { 'windows' }
                Provider      = $provider
                Host          = $instance.host
                Port          = $instance.port
                ContainerName = if ($containerInfo) { $containerInfo.Name } else { '' }
                ContainerUp   = if ($containerInfo) { $containerInfo.Running } else { $false }
                RuntimeName   = $runtimeName
                RuntimeState  = $runtimeState
                Running       = $running
                Healthy       = if ($containerInfo) { $containerInfo.Healthy } else { $false }
                SqlStatus     = if ($containerInfo) { if ($containerInfo.Healthy) { 'READY' } elseif ($containerInfo.Running) { 'STARTING_OR_UNHEALTHY' } else { 'STOPPED' } } elseif ($provider -eq 'hyperv' -and ([string]$instance.workload -eq 'sql' -or $instance.version)) { 'NOT_LIVE_VERIFIED' } else { 'NOT_APPLICABLE' }
                AutoStart     = if ($containerInfo) { if ($containerInfo.AutoStart) { 'on' } else { 'off' } } elseif ($hyperVInfo -and $hyperVInfo.AutoStart) { [string]$hyperVInfo.AutoStart } elseif ($instance.autostart) { [string]$instance.autostart } else { 'off' }
                ContainerTools = if ($instance.containerTools) {
                    [PSCustomObject]@{
                        ToolIds = @($instance.containerTools.toolIds | ForEach-Object { [string]$_ })
                        RuntimeVersion = [string]$instance.containerTools.runtimeVersion
                        Status = [string]$instance.containerTools.status
                        ImageKey = [string]$instance.containerTools.imageKey
                    }
                }
                else { $null }
                RuntimeNote   = $instanceRuntimeNote
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
            RuntimeNote = ($runtimeNotes -join ' ')
        }

        if ($Detailed) {
            $labInfo | Add-Member -NotePropertyName 'StateHistory' -NotePropertyValue $run.stateHistory
            $labInfo | Add-Member -NotePropertyName 'Errors' -NotePropertyValue $run.errors
            $labInfo | Add-Member -NotePropertyName 'ProviderSubRuns' -NotePropertyValue @(Get-LabProviderSubRuns -RunId $run.runId -StateRoot $stateRoot)
        }

        $results += $labInfo
    }

    Write-LabHeader 'SQL Server Lab - Status'

    foreach ($lab in $results) {
        Write-Host ''
        Write-LabStatus -Label 'RunId' -Value "$($lab.RunId)  [$($lab.State)]"
        Write-LabStatus -Label 'Name' -Value $lab.Name
        $createdAtText = try {
            ([DateTimeOffset]$lab.CreatedAt).ToLocalTime().ToString(
                'yyyy-MM-dd HH:mm:ss',
                [System.Globalization.CultureInfo]::InvariantCulture
            )
        }
        catch {
            [string]$lab.CreatedAt
        }
        Write-LabStatus -Label 'Erstellt' -Value $createdAtText

        foreach ($instance in $lab.Instances) {
            $autoStartText = if ($instance.AutoStart -eq 'on') { ' autostart' } else { '' }
            if ($instance.Provider -eq 'hyperv') {
                $upText = if ($instance.Running) { '[UP]' } elseif ($instance.RuntimeState -eq 'Unverifiable') { '[NICHT PRUEFBAR]' } else { '[DOWN]' }
                $workloadText = if ($instance.Workload -eq 'sql') { "SQL $($instance.Version)" } else { 'Windows' }
                $sqlText = if ($instance.SqlStatus -eq 'NOT_LIVE_VERIFIED') { ' · SQL nicht live geprueft' } else { '' }
                Write-LabStatus -Label "  $($instance.Id)" -Value "VM $($instance.RuntimeName) ($workloadText, hyperv) $upText$autoStartText$sqlText"
            }
            else {
                $upText = if ($instance.ContainerUp) { '[UP]' } else { '[DOWN]' }
                $healthText = if ($instance.Healthy) { ' healthy' } else { '' }
                Write-LabStatus `
                    -Label "  $($instance.Id)" `
                    -Value "$($instance.Host):$($instance.Port) (SQL $($instance.Version), $($instance.Provider)) $upText$healthText$autoStartText"
                if ($instance.ContainerTools) {
                    Write-LabStatus -Label '    Tools' -Value "$($instance.ContainerTools.ToolIds -join ', ') $($instance.ContainerTools.RuntimeVersion) [$($instance.ContainerTools.Status)]"
                }
            }
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
