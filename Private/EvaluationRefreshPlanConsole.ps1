# Geführter Ersatzentscheid: registrierte Metadaten lesen, nichts ausführen.
function Get-LabEvaluationRefreshConsoleRuns {
    param([Parameter(Mandatory)][string]$DataRoot)
    $root=Assert-LabDiagnosticPath -Path $DataRoot
    $directory=Assert-LabDiagnosticPath -Path (Join-Path $root 'State/runs')
    if(-not[IO.Directory]::Exists($directory)){throw 'EVALUATION_REFRESH_BINDING_UNAVAILABLE'}
    $directories=@(Get-ChildItem -LiteralPath $directory -Directory -Force -ErrorAction Stop)
    if($directories.Count-gt64){throw 'EVALUATION_REFRESH_SCOPE_UNSUPPORTED'}
    foreach($item in $directories|Sort-Object Name){
        if(-not(Test-LabDiagnosticGuid $item.Name)){continue}
        try {
            # This is only candidate discovery; the snapshot reader authenticates it.
            $run=Read-LabDiagnosticJson -Path (Join-Path $item.FullName 'run-state.json')
            $instances=@($run.metadata.desiredState.Instances)
            if($instances.Count-ne1){continue}
            $snapshot=Read-LabEvaluationRefreshSnapshot -RunId $item.Name -InstanceId $instances[0].Id -DataRoot $root
        } catch {continue}
        [pscustomobject]@{RunId=$snapshot.Binding.Run.runId;ScopeId=$snapshot.Binding.Run.scopeId;
            InstanceId=$snapshot.Instance.id;DataRoot=$root;State=$snapshot.Binding.Run.state;Digest=$snapshot.Digest}
    }
}

function Invoke-LabEvaluationRefreshPlanInteractive {
    [CmdletBinding()]param()
    try {
        $inputRoot=Read-LabConsoleTextInput -Prompt 'Vorhandenes registriertes Lab_Data-Verzeichnis (nur lesen)'
        if($inputRoot.Status-cne'Confirmed'){return}
        $runs=@(Get-LabEvaluationRefreshConsoleRuns -DataRoot ([string]$inputRoot.Value))
        if(-not$runs.Count){Write-LabInfo 'Keine vollständig gebundene einzelne Hyper-V-SQL-Instanz verfügbar.';$null=Wait-LabConsoleAcknowledgement;return}
        $runItems=@(foreach($run in $runs){New-LabConsoleItem -Id $run.RunId -Label $run.InstanceId -Value ("Hyper-V · {0} · Lab {1}"-f$run.State,$run.RunId) -Data $run})
        $choice=Invoke-LabConsoleMenu -ScreenId 'evaluation-refresh-run' -Title 'SQL-Instanz für den Ersatzentscheid auswählen' `
            -Subtitle 'Gespeicherte Metadaten; keine Lizenz- oder SQL-Abfrage. Esc: Zurück.' -Items $runItems
        if($choice.Status-cne'Selected'){return}
        $matched=@($runs|Where-Object RunId -CEQ $choice.SelectedItem.Id)
        if($matched.Count-ne1){throw 'EVALUATION_REFRESH_INPUT_INVALID'}
        $selected=$matched[0]
        $modes=@(
            New-LabConsoleItem -Id FREE_SLOT_REPLACEMENT -Label 'Freien Slot ersetzen' -Value 'Slot und neues Ziel separat prüfen'
            New-LabConsoleItem -Id RECONSTRUCT_LAB -Label 'Lab rekonstruieren' -Value 'Deklarativen und entbehrlichen Zustand klären'
            New-LabConsoleItem -Id STATEFUL_MIGRATION -Label 'Instanzzustand migrieren' -Value 'Inventar, Gleichwertigkeit und Rückfall fehlen'
        )
        $modeChoice=Invoke-LabConsoleMenu -ScreenId 'evaluation-refresh-mode' -Title 'Ersatz oder Migration: Entscheidungsart' `
            -Subtitle 'Alle Modi bleiben blockierte Vorschauen; keine Speicherung oder Ausführung.' -Items $modes
        if($modeChoice.Status-cne'Selected'){return}
        $mode=[string]$modeChoice.SelectedItem.Id
        if($mode-cnotin@($modes.Id)){throw 'EVALUATION_REFRESH_INPUT_INVALID'}
        $review=Invoke-LabConsoleMenu -ScreenId 'evaluation-refresh-preview' -Title 'Reinen Ersatzentscheid lesen' `
            -Subtitle ("{0} · {1} · SQL nicht geprüft; keine Lizenzfreigabe oder Übernahme."-f$selected.InstanceId,$modeChoice.SelectedItem.Label) -Items @(
                New-LabConsoleItem -Id preview -Label 'Vorschau lesen (keine Änderung)'
                New-LabConsoleItem -Id back -Label 'Zurück / Abbrechen'
            )
        if($review.Status-cne'Selected'-or$review.SelectedItem.Id-ceq'back'){return}
        if($review.SelectedItem.Id-cne'preview'){throw 'EVALUATION_REFRESH_INPUT_INVALID'}
        $fresh=Read-LabEvaluationRefreshSnapshot -RunId $selected.RunId -InstanceId $selected.InstanceId -DataRoot $selected.DataRoot
        if($fresh.Digest-cne$selected.Digest-or$fresh.Binding.Run.scopeId-cne$selected.ScopeId-or$fresh.Binding.Run.state-cne$selected.State){throw 'EVALUATION_REFRESH_BINDING_CHANGED'}
        $plan=Get-SqlServerLabEvaluationRefreshPlan -RunId $selected.RunId -InstanceId $selected.InstanceId -DataRoot $selected.DataRoot -Mode $mode
        Write-LabInfo 'BLOCKED: reine Planung. SQL-Bereitschaft NOT_CHECKED; keine Aktionen, Speicherung, Übernahme oder Gleichwertigkeitsbestätigung.'
        foreach($evaluation in $plan.Evaluations){
            $component=if($evaluation.Component-ceq'Windows'){'Windows'}else{'SQL Server'}
            $expiry=if($evaluation.EvaluationExpiresAt){$evaluation.EvaluationExpiresAt}else{'Nicht belegt / nicht anwendbar'}
            $days=if($null-ne$evaluation.DaysRemaining){[string]$evaluation.DaysRemaining}else{'Unbekannt / nicht anwendbar'}
            Write-LabInfo ("{0}: {1} · Quelle: {2} · Evidence: {3} · Frist UTC: {4} · Resttage: {5}"-f$component,$evaluation.Status,$evaluation.DeadlineSource,$evaluation.EvidenceStatus,$expiry,$days)
        }
        Write-LabInfo 'Windows-Aktivierung ist historische Metadaten, keine frische Lizenzprüfung. SQL-Evidence ist keine neue Gastabfrage.'
        foreach($blocker in $plan.Blockers){Write-LabInfo ("Offen: {0}"-f$blocker)}
        foreach($step in $plan.NextSteps){Write-LabInfo $step}
        $null=Wait-LabConsoleAcknowledgement
    } catch {
        $known=@('EVALUATION_REFRESH_BINDING_CHANGED','EVALUATION_REFRESH_SCOPE_UNSUPPORTED','EVALUATION_REFRESH_BINDING_INVALID','EVALUATION_REFRESH_INPUT_INVALID','EVALUATION_REFRESH_MODE_INVALID')
        $code=if($_.Exception.Message-cin$known){$_.Exception.Message}else{'EVALUATION_REFRESH_BINDING_UNAVAILABLE'}
        Write-LabWarning ("{0}: Vorschau nicht verfügbar; registrierte Metadaten prüfen. Keine Änderung ausgeführt."-f$code)
        $null=Wait-LabConsoleAcknowledgement
    }
}
