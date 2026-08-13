<#
.SYNOPSIS
    Entfernt eine SQL_Server_Lab-Umgebung provider- und scopegebunden.
.DESCRIPTION
    Fuehrt den Cleanup-Plan aus, sucht fehlende Container beim aufgezeichneten
    Provider, entfernt Secrets erst nach vollstaendigem Cleanup und markiert
    Teilfehler als RECOVERY_REQUIRED.
.PARAMETER RunId
    RunId der zu entfernenden Umgebung. Ohne Angabe wird eine vorhandene
    Umgebung automatisch gewaehlt oder interaktiv abgefragt.
.PARAMETER StateRoot
    Optionales State-Stammverzeichnis. Ohne Angabe wird der Framework-Default
    verwendet.
.PARAMETER Force
    Ueberspringt die zusaetzliche interaktive Bestaetigung. WhatIf und Confirm
    stehen weiterhin ueber SupportsShouldProcess zur Verfuegung.
.OUTPUTS
    System.Management.Automation.PSCustomObject. Liefert RunId, Status und das
    Cleanup-Ergebnis.
.EXAMPLE
    Remove-SqlServerLab -RunId $lab.RunId
#>
function Remove-SqlServerLab {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$RunId,
        [string]$StateRoot,
        [switch]$Force
    )

    $ErrorActionPreference = 'Stop'

    if (-not $StateRoot) {
        $StateRoot = Get-LabStateRoot
    }

    if (-not $RunId) {
        $activeRuns = @(Get-LabActiveRuns -StateRoot $StateRoot)
        if ($activeRuns.Count -eq 0) {
            Write-LabInfo 'Keine aktiven Lab-Umgebungen gefunden.'
            return [PSCustomObject]@{
                RunId   = $null
                Status  = 'NOT_FOUND'
                Cleanup = 'NOT_REQUIRED'
            }
        }

        if ($activeRuns.Count -eq 1) {
            $RunId = $activeRuns[0].runId
        }
        else {
            Write-LabInfo "$($activeRuns.Count) aktive Umgebungen gefunden:"
            for ($index = 0; $index -lt $activeRuns.Count; $index++) {
                $run = $activeRuns[$index]
                Write-LabStatus `
                    -Label "[$($index + 1)]" `
                    -Value "$($run.runId.Substring(0, 8))... ($($run.state)) - $($run.metadata.name)"
            }

            $choice = Read-LabChoice `
                -Options ($activeRuns | ForEach-Object { "$($_.runId.Substring(0, 8))... ($($_.state))" }) `
                -Prompt 'Welche Umgebung entfernen?'
            $RunId = $activeRuns[$choice].runId
        }
    }

    if ((Test-LabAutomatedTestEnvironmentRun -RunId $RunId) -and -not $script:LabAutomatedTestEnvironmentGroupOperation) {
        throw 'TEST_ENVIRONMENT_GROUP_PROTECTED: Einzelnes Löschen ist gesperrt. Clear-SqlServerLabAutomatedTestEnvironment verwenden.'
    }

    $state = Get-LabRunState -RunId $RunId -StateRoot $StateRoot
    $runDirectory = Join-Path (Join-Path $StateRoot 'runs') $RunId

    Write-LabHeader "Lab entfernen: $($state.metadata.name)"
    Write-LabStatus -Label 'RunId' -Value $RunId
    Write-LabStatus -Label 'ScopeId' -Value $state.scopeId
    Write-LabStatus -Label 'Status' -Value $state.state

    if ($state.state -eq 'REMOVED') {
        Write-LabInfo 'Die Umgebung ist bereits als REMOVED markiert.'
        return [PSCustomObject]@{
            RunId   = $RunId
            Status  = 'REMOVED'
            Cleanup = 'ALREADY_REMOVED'
        }
    }

    if (-not $PSCmdlet.ShouldProcess($RunId, 'SQL_Server_Lab-Umgebung entfernen')) {
        return [PSCustomObject]@{
            RunId   = $RunId
            Status  = $state.state
            Cleanup = 'CANCELLED'
        }
    }

    if (-not $Force) {
        $confirmed = Read-LabConfirm -Prompt 'Umgebung unwiderruflich entfernen?'
        if (-not $confirmed) {
            Write-LabInfo 'Abgebrochen.'
            return [PSCustomObject]@{
                RunId   = $RunId
                Status  = $state.state
                Cleanup = 'CANCELLED'
            }
        }
    }

    if ($state.state -eq 'CLEANED_UP') {
        $null = Set-LabRunState `
            -RunId $RunId `
            -NewState 'REMOVED' `
            -Reason 'Bereits bereinigten Run finalisiert' `
            -StateRoot $StateRoot
        foreach ($providerSubRun in @(Get-LabProviderSubRuns -RunId $RunId -StateRoot $StateRoot)) {
            if ($providerSubRun.state -eq 'CLEANED_UP') {
                Set-LabProviderSubRunState `
                    -RunId $RunId `
                    -Provider $providerSubRun.provider `
                    -NewState 'REMOVED' `
                    -Reason 'Bereits bereinigten Run finalisiert' `
                    -StateRoot $StateRoot
            }
        }
        $null = Remove-LabSecrets -Path $runDirectory

        return [PSCustomObject]@{
            RunId   = $RunId
            Status  = 'REMOVED'
            Cleanup = 'CLEANUP_SUCCEEDED'
        }
    }

    $cleanupPlanPath = Join-Path $runDirectory 'cleanup-plan.json'
    if (Test-Path -LiteralPath $cleanupPlanPath -PathType Leaf) {
        try {
            $cleanupPlan = Get-Content -LiteralPath $cleanupPlanPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 20
            foreach ($step in @($cleanupPlan.steps | Where-Object { $_.state -eq 'FAILED' })) {
                $step.state = 'PENDING'
                $step.error = $null
                $step.executedAt = $null
            }
            $cleanupPlan.status = 'PENDING'
            $cleanupPlan | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $cleanupPlanPath -Encoding utf8
        }
        catch {
            throw "Cleanup-Plan konnte nicht fuer einen Wiederholungsversuch vorbereitet werden: $($_.Exception.Message)"
        }
    }

    $state = Get-LabRunState -RunId $RunId -StateRoot $StateRoot
    if ($state.state -eq 'RECOVERY_REQUIRED') {
        $null = Set-LabRunState `
            -RunId $RunId `
            -NewState 'CLEANUP_PENDING' `
            -Reason 'Cleanup-Wiederholungsversuch' `
            -StateRoot $StateRoot
    }
    elseif ($state.state -notin @('CLEANUP_PENDING', 'CLEANUP_RUNNING')) {
        $null = Set-LabRunState `
            -RunId $RunId `
            -NewState 'CLEANUP_PENDING' `
            -Reason 'Benutzer-Entfernung' `
            -StateRoot $StateRoot
    }

    foreach ($providerSubRun in @(Get-LabProviderSubRuns -RunId $RunId -StateRoot $StateRoot)) {
        if ($providerSubRun.state -notin @('CLEANED_UP', 'REMOVED', 'CLEANUP_PENDING', 'CLEANUP_RUNNING')) {
            Set-LabProviderSubRunState `
                -RunId $RunId `
                -Provider $providerSubRun.provider `
                -NewState 'CLEANUP_PENDING' `
                -Reason 'Benutzer-Entfernung' `
                -StateRoot $StateRoot
        }
    }

    $state = Get-LabRunState -RunId $RunId -StateRoot $StateRoot
    if ($state.state -eq 'CLEANUP_PENDING') {
        $null = Set-LabRunState `
            -RunId $RunId `
            -NewState 'CLEANUP_RUNNING' `
            -Reason 'Cleanup gestartet' `
            -StateRoot $StateRoot
        foreach ($providerSubRun in @(Get-LabProviderSubRuns -RunId $RunId -StateRoot $StateRoot)) {
            if ($providerSubRun.state -eq 'CLEANUP_PENDING') {
                Set-LabProviderSubRunState `
                    -RunId $RunId `
                    -Provider $providerSubRun.provider `
                    -NewState 'CLEANUP_RUNNING' `
                    -Reason 'Cleanup gestartet' `
                    -StateRoot $StateRoot
            }
        }
    }

    Write-LabInfo 'Cleanup-Plan ausfuehren...'
    $cleanupResult = Invoke-CleanupPlan `
        -RunDir $runDirectory `
        -ScopeId $state.scopeId

    Write-LabStatus `
        -Label 'Cleanup' `
        -Value "$($cleanupResult.Status) ($($cleanupResult.Steps) Steps, $($cleanupResult.Errors) Fehler)"

    foreach ($providerCleanup in @($cleanupResult.ProviderSubRuns)) {
        $providerState = if ($providerCleanup.Errors -eq 0) { 'CLEANED_UP' } else { 'RECOVERY_REQUIRED' }
        Set-LabProviderSubRunState `
            -RunId $RunId `
            -Provider $providerCleanup.Provider `
            -NewState $providerState `
            -Reason "Cleanup: $($providerCleanup.Status)" `
            -StateRoot $StateRoot
    }

    $providers = @()
    $connectionInfoPath = Join-Path $runDirectory 'connection-info.json'
    if (Test-Path -LiteralPath $connectionInfoPath -PathType Leaf) {
        try {
            $connectionInfo = Get-Content -LiteralPath $connectionInfoPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 20
            $providers = @($connectionInfo.instances | ForEach-Object { $_.provider })
        }
        catch {
            Write-LabWarning "Connection-Info konnte fuer die Orphan-Suche nicht gelesen werden: $($_.Exception.Message)"
        }
    }

    if ($providers.Count -eq 0 -and (Test-Path -LiteralPath $cleanupPlanPath -PathType Leaf)) {
        try {
            $cleanupPlan = Get-Content -LiteralPath $cleanupPlanPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 20
            $providers = @(
                $cleanupPlan.steps | ForEach-Object {
                    if ($_.provider) {
                        $_.provider
                    }
                    elseif ([string]$_.compensation -match '^\s*(docker|podman)\b') {
                        $Matches[1].ToLowerInvariant()
                    }
                }
            )
        }
        catch {
            Write-LabWarning "Provider konnte nicht aus dem Cleanup-Plan gelesen werden: $($_.Exception.Message)"
        }
    }

    $providers = @($providers | Where-Object { $_ -in @('docker', 'podman') } | Sort-Object -Unique)
    if ($providers.Count -eq 0) {
        foreach ($candidate in @('docker', 'podman')) {
            if (Get-Command $candidate -ErrorAction SilentlyContinue) {
                $providers += $candidate
            }
        }
    }

    $orphanErrors = 0
    foreach ($provider in $providers) {
        if (-not (Get-Command $provider -ErrorAction SilentlyContinue)) {
            Write-LabWarning "Runtime '$provider' ist fuer die Orphan-Suche nicht verfuegbar."
            $orphanErrors++
            continue
        }

        $orphans = switch ($provider) {
            'docker' { @(Get-DockerLabContainers -RunId $RunId) }
            'podman' { @(Get-PodmanLabContainers -RunId $RunId) }
        }

        foreach ($orphan in $orphans) {
            Write-LabWarning "Orphan-Container bei $provider gefunden: $($orphan.Name)"
            try {
                switch ($provider) {
                    'docker' {
                        $null = Remove-DockerInstance `
                            -ContainerIdOrName $orphan.ContainerId `
                            -ExpectedScopeId $state.scopeId
                    }
                    'podman' {
                        $null = Remove-PodmanInstance `
                            -ContainerIdOrName $orphan.ContainerId `
                            -ExpectedScopeId $state.scopeId
                    }
                }
            }
            catch {
                $orphanErrors++
                Write-LabError "Orphan nicht entfernbar: $($_.Exception.Message)"
            }
        }
    }

    $totalErrors = [int]$cleanupResult.Errors + $orphanErrors
    if ($totalErrors -gt 0) {
        $message = "Cleanup unvollstaendig: $totalErrors Fehler."
        $null = Add-LabRunError `
            -RunId $RunId `
            -Message $message `
            -Component 'Remove-SqlServerLab' `
            -StateRoot $StateRoot
        $null = Set-LabRunState `
            -RunId $RunId `
            -NewState 'RECOVERY_REQUIRED' `
            -Reason $message `
            -StateRoot $StateRoot
        foreach ($providerSubRun in @(Get-LabProviderSubRuns -RunId $RunId -StateRoot $StateRoot)) {
            if ($providerSubRun.state -in @('CLEANUP_RUNNING', 'CLEANED_UP')) {
                Set-LabProviderSubRunState `
                    -RunId $RunId `
                    -Provider $providerSubRun.provider `
                    -NewState 'RECOVERY_REQUIRED' `
                    -Reason $message `
                    -StateRoot $StateRoot
            }
        }

        Write-LabError "$message Run-State bleibt fuer einen Wiederholungsversuch erhalten."
        return [PSCustomObject]@{
            RunId   = $RunId
            Status  = 'RECOVERY_REQUIRED'
            Cleanup = if ($cleanupResult.Status -eq 'CLEANUP_SUCCEEDED') { 'ORPHAN_CLEANUP_FAILED' } else { $cleanupResult.Status }
            Errors  = $totalErrors
        }
    }

    $null = Set-LabRunState `
        -RunId $RunId `
        -NewState 'CLEANED_UP' `
        -Reason $cleanupResult.Status `
        -StateRoot $StateRoot
    foreach ($providerSubRun in @(Get-LabProviderSubRuns -RunId $RunId -StateRoot $StateRoot)) {
        if ($providerSubRun.state -eq 'CLEANUP_RUNNING') {
            Set-LabProviderSubRunState `
                -RunId $RunId `
                -Provider $providerSubRun.provider `
                -NewState 'CLEANED_UP' `
                -Reason $cleanupResult.Status `
                -StateRoot $StateRoot
        }
    }
    $null = Set-LabRunState `
        -RunId $RunId `
        -NewState 'REMOVED' `
        -Reason 'Vollstaendig entfernt' `
        -StateRoot $StateRoot
    foreach ($providerSubRun in @(Get-LabProviderSubRuns -RunId $RunId -StateRoot $StateRoot)) {
        if ($providerSubRun.state -eq 'CLEANED_UP') {
            Set-LabProviderSubRunState `
                -RunId $RunId `
                -Provider $providerSubRun.provider `
                -NewState 'REMOVED' `
                -Reason 'Vollstaendig entfernt' `
                -StateRoot $StateRoot
        }
    }
    $null = Remove-LabSecrets -Path $runDirectory

    Write-LabSuccess "Umgebung entfernt: $RunId"

    return [PSCustomObject]@{
        RunId   = $RunId
        Status  = 'REMOVED'
        Cleanup = $cleanupResult.Status
        Errors  = 0
    }
}
