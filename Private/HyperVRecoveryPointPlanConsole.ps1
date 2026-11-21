function Show-LabHyperVRecoveryPointPlanInteractive {
    $stateRoot = Get-LabStateRoot
    $runs = @(Get-LabActiveRuns -StateRoot $stateRoot -NoWrite | Where-Object { $_.metadata.workflowKind -ceq 'hyperv-lab' })
    if (-not $runs.Count) {
        Write-Host 'Kein registriertes Hyper-V-Lab gefunden.'
        $null = Wait-LabConsoleAcknowledgement
        return
    }
    $runId = Select-LabRun -Runs $runs -Prompt 'Hyper-V-Lab für Checkpoint-Inventar' -DisableAutomatedTestEnvironments -DisableSystemServices
    if (-not $runId) { return }
    try {
        $parsedRunId = [guid]::Empty
        if (-not [guid]::TryParseExact($runId, 'D', [ref]$parsedRunId) -or $parsedRunId -eq [guid]::Empty) {
            throw 'HYPERV_RECOVERY_POINT_INVALID_RUN'
        }
        $connectionPath = Join-Path $stateRoot "runs/$($parsedRunId.ToString('D'))/connection-info.json"
        $connection = Get-Content -LiteralPath $connectionPath -Raw -Encoding utf8 -ErrorAction Stop | ConvertFrom-Json -Depth 30
        $instances = @($connection.instances | Where-Object { $_.provider -ceq 'hyperv' })
        if ($instances.Count -ne 1) { throw 'HYPERV_RECOVERY_POINT_CONNECTION_INSTANCE_NOT_UNIQUE' }
        $plan = Get-SqlServerLabHyperVRecoveryPointPlan -RunId $parsedRunId.ToString('D') -InstanceId $instances[0].id -StateRoot $stateRoot -ErrorAction Stop
        switch ($plan.Status) {
            'READY' {
                foreach ($point in $plan.RecoveryPoints) {
                    Write-Host ('{0} · {1} · {2}' -f $point.CreatedAt, $point.Kind, $point.RecoveryPointId)
                }
            }
            'NO_ACTION' { Write-Host 'Für dieses Lab sind keine Checkpoints vorhanden.' }
            'BLOCKED' { Write-Host ('Inventar nicht verfügbar ({0}).' -f ($plan.Blockers -join ', ')) -ForegroundColor Yellow }
            default { throw 'HYPERV_RECOVERY_POINT_PLAN_INVALID' }
        }
    }
    catch { Write-Host 'Die Wiederherstellungspunkte des gewählten Labs konnten nicht gelesen werden.' -ForegroundColor Red }
    $null = Wait-LabConsoleAcknowledgement
}
