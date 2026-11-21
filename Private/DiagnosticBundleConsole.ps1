function Show-LabDiagnosticBundleInteractive {
    $dataRoot = Get-LabDataRootDefault
    if (-not $dataRoot) {
        Write-Host 'Für den Diagnosebefund muss ein Lab_Data-Standard registriert sein.' -ForegroundColor Yellow
        $null = Wait-LabConsoleAcknowledgement
        return
    }
    $runs = @(Get-LabActiveRuns -StateRoot (Join-Path $dataRoot 'State') -NoWrite | Where-Object { $_.metadata.desiredState.Instances })
    if (-not $runs.Count) {
        Write-Host 'Im Standard-Lab_Data ist keine Umgebung mit versioniertem Sollzustand registriert.'
        $null = Wait-LabConsoleAcknowledgement
        return
    }
    $runId = Select-LabRun -Runs $runs -Prompt 'Lab für registrierten Diagnosebefund' -DisableAutomatedTestEnvironments -DisableSystemServices
    if (-not $runId) { return }
    $selected = @($runs | Where-Object runId -CEQ $runId)
    if ($selected.Count -ne 1) { return }
    $items = @(foreach ($instance in $selected[0].metadata.desiredState.Instances) {
        if ($instance.Id -cmatch '\A[A-Za-z][A-Za-z0-9_-]{0,63}\z' -and $instance.Provider -cin @('docker','podman','hyperv')) {
            New-LabConsoleItem -Id $instance.Id -Label $instance.Id -Value $instance.Provider -Data $instance
        }
    })
    if (-not $items.Count) {
        Write-Host 'Für dieses Lab ist keine Diagnoseinstanz auswählbar.'
        $null = Wait-LabConsoleAcknowledgement
        return
    }
    $target = Select-LabConsoleDataItem -ScreenId 'diagnostic-bundle-instance' -Title 'Instanz für gespeicherten Diagnosebefund' -Items $items
    if (-not $target) { return }
    $result = Get-SqlServerLabDiagnosticBundle -RunId $runId -InstanceId $target.Id -Provider $target.Provider -DataRoot $dataRoot -SkipReadiness
    if ($result.Status -ceq 'OBSERVED') {
        Write-Host ('Provider: {0} · gespeicherter Zustand: {1} · Recovery: {2} · Fehler: {3}' -f
            $result.Binding.Provider, $result.History.RunState, $result.History.RecoveryStatus, $result.History.ErrorCount)
        Write-Host ('Cleanup: {0} · offen: {1} · fehlgeschlagen: {2}' -f
            $result.Cleanup.Status, $result.Cleanup.PendingSteps, $result.Cleanup.FailedSteps)
    }
    else { Write-Host ('Kein gebundener Diagnosebefund ({0}).' -f $result.Binding.Reason) -ForegroundColor Yellow }
    Write-Host 'Gespeicherte Evidence. SQL und Provider wurden nicht live geprüft.'
    $null = Wait-LabConsoleAcknowledgement
}
