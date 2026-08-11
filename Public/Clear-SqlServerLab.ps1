<#
.SYNOPSIS
    Bereinigt bekannte Runs und verwaiste SQL_Server_Lab-Container.
.DESCRIPTION
    Bekannte Runs werden ueber Remove-SqlServerLab provider- und scopegebunden
    entfernt. Anschliessend werden echte Orphan-Container getrennt in Docker
    und Podman gesucht. State wird bei unvollstaendigem Cleanup nicht als
    erfolgreich entfernt markiert.
.PARAMETER Force
    Keine interaktive Bestaetigung abfragen.
.PARAMETER StateOnly
    Nur nachweislich verwaiste State-Eintraege bereinigen.
.PARAMETER ContainersOnly
    Nur Container entfernen; vorhandener Run-State bleibt erhalten.
.OUTPUTS
    System.Management.Automation.PSCustomObject. Liefert eine Zusammenfassung
    der erkannten und bereinigten Container und State-Runs.
.EXAMPLE
    Clear-SqlServerLab -Force
#>
function Clear-SqlServerLab {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [switch]$Force,
        [switch]$StateOnly,
        [switch]$ContainersOnly
    )

    $ErrorActionPreference = 'Stop'

    if ($StateOnly -and $ContainersOnly) {
        throw 'StateOnly und ContainersOnly duerfen nicht gemeinsam verwendet werden.'
    }

    Write-LabHeader 'SQL Server Lab - Cleanup'
    $auditBefore = Get-SqlServerLabCleanupAudit

    $stateRoot = Get-LabStateRoot
    $activeRuns = @(Get-LabActiveRuns -StateRoot $stateRoot)
    $windowsImageBuilds = if (-not $StateOnly -and -not $ContainersOnly) { @(Get-HyperVImageBuildPlans -StateRoot $stateRoot) } else { @() }
    $sqlImageBuilds = if (-not $StateOnly -and -not $ContainersOnly) { @(Get-HyperVSqlImageBuildPlans -StateRoot $stateRoot) } else { @() }
    $dataRoot = if (-not $StateOnly -and -not $ContainersOnly) { Get-LabDataRootDefault } else { $null }
    $dataLabsRoot = if ($dataRoot) { Join-Path $dataRoot 'Labs' } else { $null }
    $dataLabDirectories = if ($dataLabsRoot -and (Test-Path -LiteralPath $dataLabsRoot -PathType Container)) {
        @(Get-ChildItem -LiteralPath $dataLabsRoot -Directory -Force)
    }
    else { @() }
    $knownRunIds = @($activeRuns | ForEach-Object { $_.runId })
    $runtimeStatus = @{}
    $allContainers = @()

    foreach ($runtime in @('docker', 'podman')) {
        $command = Get-Command $runtime -ErrorAction SilentlyContinue
        if (-not $command) {
            $runtimeStatus[$runtime] = 'NOT_INSTALLED'
            continue
        }

        & $runtime info 1>$null 2>$null
        if ($LASTEXITCODE -ne 0) {
            $runtimeStatus[$runtime] = 'UNAVAILABLE'
            continue
        }

        $runtimeStatus[$runtime] = 'AVAILABLE'
        $runtimeContainers = switch ($runtime) {
            'docker' { @(Get-DockerLabContainers) }
            'podman' { @(Get-PodmanLabContainers) }
        }

        foreach ($container in $runtimeContainers) {
            $allContainers += [PSCustomObject]@{
                Provider    = $runtime
                ContainerId = $container.ContainerId
                Name        = $container.Name
                Status      = $container.Status
                RunId       = $container.RunId
                ScopeId     = $container.ScopeId
                Version     = $container.Version
                InstanceId  = $container.InstanceId
            }
        }
    }

    $orphanContainers = @(
        $allContainers | Where-Object {
            -not $_.RunId -or $_.RunId -notin $knownRunIds
        }
    )

    Write-LabStatus -Label 'Aktive Runs' -Value $activeRuns.Count
    Write-LabStatus -Label 'Lab-Container' -Value $allContainers.Count
    Write-LabStatus -Label 'Orphan-Container' -Value $orphanContainers.Count
    Write-LabStatus -Label 'Hyper-V Windows-Builder' -Value $windowsImageBuilds.Count
    Write-LabStatus -Label 'Hyper-V SQL-Builder' -Value $sqlImageBuilds.Count
    Write-LabStatus -Label 'Data-Root-Labverzeichnisse' -Value $dataLabDirectories.Count
    Write-LabInfo 'Veröffentlichte OS- und SQL-Vorlagen bleiben erhalten und werden ausschließlich unter Hyper-V -> Veröffentlichte Vorlagen verwaltet.'
    foreach ($runtime in @('docker', 'podman')) {
        Write-LabStatus -Label "Runtime $runtime" -Value $runtimeStatus[$runtime]
    }

    $workCount = if ($StateOnly) {
        $activeRuns.Count
    }
    elseif ($ContainersOnly) {
        $allContainers.Count
    }
    else {
        $activeRuns.Count + $orphanContainers.Count + $windowsImageBuilds.Count + $sqlImageBuilds.Count + $dataLabDirectories.Count
    }

    if ($workCount -eq 0) {
        Write-LabSuccess 'Alles sauber. Nichts zu entfernen.'
        return [PSCustomObject]@{
            Containers = 0
            StateRuns  = 0
            Errors     = 0
            Status     = 'CLEAN'
            AuditBefore = $auditBefore
            AuditAfter = $auditBefore
        }
    }

    if (-not $PSCmdlet.ShouldProcess(
        "$($activeRuns.Count) Run(s), $($allContainers.Count) Container",
        'SQL_Server_Lab-Bereinigung ausfuehren'
    )) {
        return [PSCustomObject]@{
            Containers = 0
            StateRuns  = 0
            Errors     = 0
            Status     = 'CANCELLED'
        }
    }

    if (-not $Force) {
        $confirmed = Read-LabConfirm -Prompt "$workCount Cleanup-Einheit(en) verarbeiten?"
        if (-not $confirmed) {
            Write-LabInfo 'Abgebrochen.'
            return [PSCustomObject]@{
                Containers = 0
                StateRuns  = 0
                Errors     = 0
                Status     = 'CANCELLED'
            }
        }
    }

    $removedContainers = 0
    $removedStateRuns = 0
    $removedImageBuilds = 0
    $removedDataLabDirectories = 0
    $errors = 0

    if ($StateOnly) {
        foreach ($run in $activeRuns) {
            $runDirectory = Join-Path (Join-Path $stateRoot 'runs') $run.runId
            $connectionInfoPath = Join-Path $runDirectory 'connection-info.json'
            $expectedProviders = @()

            if (Test-Path -LiteralPath $connectionInfoPath -PathType Leaf) {
                try {
                    $connectionInfo = Get-Content -LiteralPath $connectionInfoPath -Raw -Encoding utf8 |
                        ConvertFrom-Json -Depth 20
                    $expectedProviders = @(
                        $connectionInfo.instances |
                            ForEach-Object { $_.provider } |
                            Where-Object { $_ } |
                            Sort-Object -Unique
                    )
                }
                catch {
                    Write-LabError "Run $($run.runId): Connection-Info unlesbar: $($_.Exception.Message)"
                    $errors++
                    continue
                }
            }

            if ($expectedProviders.Count -eq 0) {
                $expectedProviders = @('docker', 'podman')
            }

            $unverifiableProviders = @(
                $expectedProviders | Where-Object { $runtimeStatus[$_] -ne 'AVAILABLE' }
            )
            if ($unverifiableProviders.Count -gt 0) {
                Write-LabWarning "Run $($run.runId): State nicht entfernt; Provider nicht pruefbar: $($unverifiableProviders -join ', ')."
                $errors++
                continue
            }

            $containersForRun = @(
                $allContainers | Where-Object { $_.RunId -eq $run.runId }
            )
            if ($containersForRun.Count -gt 0) {
                Write-LabWarning "Run $($run.runId): State ist nicht verwaist; $($containersForRun.Count) Container vorhanden."
                $errors++
                continue
            }

            try {
                $current = Get-LabRunState -RunId $run.runId -StateRoot $stateRoot
                if ($current.state -notin @('CLEANED_UP', 'REMOVED')) {
                    if ($current.state -eq 'RECOVERY_REQUIRED') {
                        $null = Set-LabRunState -RunId $run.runId -NewState 'CLEANUP_PENDING' -Reason 'Verwaisten State bereinigen' -StateRoot $stateRoot
                    }
                    elseif ($current.state -notin @('CLEANUP_PENDING', 'CLEANUP_RUNNING')) {
                        $null = Set-LabRunState -RunId $run.runId -NewState 'CLEANUP_PENDING' -Reason 'Verwaisten State bereinigen' -StateRoot $stateRoot
                    }

                    $current = Get-LabRunState -RunId $run.runId -StateRoot $stateRoot
                    if ($current.state -eq 'CLEANUP_PENDING') {
                        $null = Set-LabRunState -RunId $run.runId -NewState 'CLEANUP_RUNNING' -Reason 'Keine Runtime-Ressourcen vorhanden' -StateRoot $stateRoot
                    }

                    $current = Get-LabRunState -RunId $run.runId -StateRoot $stateRoot
                    if ($current.state -eq 'CLEANUP_RUNNING') {
                        $null = Set-LabRunState -RunId $run.runId -NewState 'CLEANED_UP' -Reason 'State war nachweislich verwaist' -StateRoot $stateRoot
                    }
                }

                $current = Get-LabRunState -RunId $run.runId -StateRoot $stateRoot
                if ($current.state -eq 'CLEANED_UP') {
                    $null = Set-LabRunState -RunId $run.runId -NewState 'REMOVED' -Reason 'Verwaisten State finalisiert' -StateRoot $stateRoot
                }
                $null = Remove-LabSecrets -Path $runDirectory
                $removedStateRuns++
            }
            catch {
                Write-LabError "State $($run.runId) konnte nicht bereinigt werden: $($_.Exception.Message)"
                $errors++
            }
        }
    }
    elseif ($ContainersOnly) {
        foreach ($container in $allContainers) {
            if (-not $container.ScopeId) {
                Write-LabError "Container '$($container.Name)' besitzt kein Scope-Label; Entfernung verweigert."
                $errors++
                continue
            }

            try {
                switch ($container.Provider) {
                    'docker' {
                        $null = Remove-DockerInstance -ContainerIdOrName $container.ContainerId -ExpectedScopeId $container.ScopeId
                    }
                    'podman' {
                        $null = Remove-PodmanInstance -ContainerIdOrName $container.ContainerId -ExpectedScopeId $container.ScopeId
                    }
                }
                $removedContainers++
            }
            catch {
                Write-LabError "Container '$($container.Name)' konnte nicht entfernt werden: $($_.Exception.Message)"
                $errors++
            }
        }
    }
    else {
        foreach ($run in $activeRuns) {
            try {
                $result = Remove-SqlServerLab -RunId $run.runId -StateRoot $stateRoot -Force
                if ($result.Status -eq 'REMOVED') {
                    $removedStateRuns++
                    $removedContainers += @($allContainers | Where-Object { $_.RunId -eq $run.runId }).Count
                }
                else {
                    $errors += [Math]::Max(1, [int]$result.Errors)
                }
            }
            catch {
                Write-LabError "Run '$($run.runId)' konnte nicht entfernt werden: $($_.Exception.Message)"
                $errors++
            }
        }

        foreach ($container in $orphanContainers) {
            if (-not $container.ScopeId) {
                Write-LabError "Orphan '$($container.Name)' besitzt kein Scope-Label; Entfernung verweigert."
                $errors++
                continue
            }

            try {
                switch ($container.Provider) {
                    'docker' {
                        $null = Remove-DockerInstance -ContainerIdOrName $container.ContainerId -ExpectedScopeId $container.ScopeId
                    }
                    'podman' {
                        $null = Remove-PodmanInstance -ContainerIdOrName $container.ContainerId -ExpectedScopeId $container.ScopeId
                    }
                }
                $removedContainers++
            }
            catch {
                Write-LabError "Orphan '$($container.Name)' konnte nicht entfernt werden: $($_.Exception.Message)"
                $errors++
            }
        }

        foreach ($build in $windowsImageBuilds) {
            try {
                $result = Remove-HyperVWindowsImageBuild -BuildId ([string]$build.buildId) -StateRoot $stateRoot
                if ([string]$result.Status -eq 'CLEANUP_SUCCEEDED') { $removedImageBuilds++ } else { $errors++ }
            }
            catch { Write-LabError "Windows-Builder '$($build.buildId)' konnte nicht entfernt werden: $($_.Exception.Message)"; $errors++ }
        }
        foreach ($build in $sqlImageBuilds) {
            try {
                $result = Remove-HyperVSqlImageBuild -BuildId ([string]$build.buildId) -StateRoot $stateRoot
                if ([string]$result.Status -eq 'CLEANUP_SUCCEEDED') { $removedImageBuilds++ } else { $errors++ }
            }
            catch { Write-LabError "SQL-Builder '$($build.buildId)' konnte nicht entfernt werden: $($_.Exception.Message)"; $errors++ }
        }
        if ($dataLabDirectories.Count -gt 0) {
            $canonicalLabsRoot = [IO.Path]::GetFullPath($dataLabsRoot).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
            foreach ($directory in $dataLabDirectories) {
                try {
                    $canonicalDirectory = [IO.Path]::GetFullPath($directory.FullName)
                    if (-not $canonicalDirectory.StartsWith($canonicalLabsRoot, [StringComparison]::OrdinalIgnoreCase)) {
                        throw 'DATA_ROOT_LAB_DIRECTORY_SCOPE_VIOLATION'
                    }
                    Remove-Item -LiteralPath $canonicalDirectory -Recurse -Force -ErrorAction Stop
                    $removedDataLabDirectories++
                }
                catch { Write-LabError "Data-Root-Labverzeichnis '$($directory.FullName)' konnte nicht entfernt werden: $($_.Exception.Message)"; $errors++ }
            }
        }
    }

    $status = if ($errors -eq 0) { 'CLEAN' } else { 'PARTIAL' }
    $auditAfter = Get-SqlServerLabCleanupAudit
    Write-LabHeader 'Cleanup abgeschlossen'
    Write-LabStatus -Label 'Container entfernt' -Value $removedContainers -Color 'Green'
    Write-LabStatus -Label 'State-Runs bereinigt' -Value $removedStateRuns -Color 'Green'
    Write-LabStatus -Label 'Image-Builder entfernt' -Value $removedImageBuilds -Color 'Green'
    Write-LabStatus -Label 'Data-Root-Labverzeichnisse entfernt' -Value $removedDataLabDirectories -Color 'Green'
    if ($errors -gt 0) {
        Write-LabStatus -Label 'Fehler' -Value $errors -Color 'Red'
    }

    return [PSCustomObject]@{
        Containers = $removedContainers
        StateRuns  = $removedStateRuns
        ImageBuilds = $removedImageBuilds
        DataLabDirectories = $removedDataLabDirectories
        Errors     = $errors
        Status     = $status
        AuditBefore = $auditBefore
        AuditAfter = $auditAfter
    }
}
