function Invoke-LabSqlGuestEvaluationCaptureInteractive {
    try {
        $runs = @(foreach ($run in Get-LabActiveRuns) {
            if ($run.state -cne 'RUNNING' -or $run.metadata.workflowKind -cne 'hyperv-lab') { continue }
            try { $lab = Get-HyperVLabWorkflowRun -RunId $run.runId } catch { continue }
            $instances = @($lab.Connection.instances)
            if ($instances.Count -eq 1 -and $instances[0].workload -ceq 'sql' -and
                [string]$instances[0].sqlVersion -ceq '2025' -and $instances[0].sqlReadiness.status -ceq 'SQL_READY_RUN') {
                $run
            }
        })
        if (-not $runs.Count) {
            Write-LabInfo 'Kein laufendes vorbereitetes Hyper-V-Lab mit SQL Server 2025 gefunden.'
            $null = Wait-LabConsoleAcknowledgement
            return
        }
        $runId = Select-LabRun -Runs $runs -Prompt 'SQL-2025-Lab für neue Editionsbeobachtung' -DisableAutomatedTestEnvironments -DisableSystemServices
        if (-not $runId) { return }
        if (-not (Read-LabConfirm -Prompt 'SQL-Edition im gewählten Gast lesen und den lokalen Beleg aktualisieren?' -Default $false)) { return }

        $result = Update-SqlServerLabSqlGuestEvaluationEvidence -RunId $runId -Confirm:$false -ErrorAction Stop
        if ($result.Status -cne 'UPDATED') { throw 'SQL_GUEST_CAPTURE_UNCONFIRMED' }
        Write-LabSuccess 'Der lokale SQL-Editionsbeleg wurde aktualisiert. Öffne die Evaluationsfristen für die aktuelle Auswertung.'
    }
    catch {
        $code = if ($_.Exception.Message -cmatch '^SQL_GUEST_CAPTURE_[A-Z_]{1,64}$') { $_.Exception.Message } else { 'SQL_GUEST_CAPTURE_FAILED' }
        Write-LabError ('Der SQL-Editionsbeleg konnte nicht aktualisiert werden ({0}).' -f $code)
    }
    $null = Wait-LabConsoleAcknowledgement
}
