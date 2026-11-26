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
        $targetCandidates = @($runs | Where-Object { $_.RunId -cne $selected.RunId -and $_.ScopeId -cne $selected.ScopeId })
        $reviewItems = @(
            New-LabConsoleItem -Id preview -Label 'Vorschau lesen (keine Änderung)'
            if ($selected.State -ceq 'RUNNING') {
                New-LabConsoleItem -Id observe-windows -Label 'Windows-Lizenz im laufenden Gast lesen'
            }
            if ($mode -ceq 'STATEFUL_MIGRATION' -and $selected.State -ceq 'RUNNING') {
                New-LabConsoleItem -Id observe -Label 'SQL-Quellzähler im laufenden Gast lesen'
                New-LabConsoleItem -Id observe-source-database -Label 'Migrationsabhängigkeiten einer Quelldatenbank lesen'
            }
            if ($mode -ceq 'STATEFUL_MIGRATION' -and $targetCandidates.Count) {
                New-LabConsoleItem -Id target -Label 'Registriertes Ziellab vorprüfen'
                if (@($targetCandidates | Where-Object State -CEQ 'RUNNING').Count) {
                    New-LabConsoleItem -Id observe-target-windows -Label 'Windows-Lizenz im laufenden Ziellab lesen'
                    New-LabConsoleItem -Id observe-target-sql -Label 'SQL-Bereitschaft und Edition im laufenden Ziellab prüfen'
                    New-LabConsoleItem -Id observe-target-storage -Label 'Freien Speicher im laufenden Ziellab prüfen'
                    if ($selected.State -ceq 'RUNNING') {
                        New-LabConsoleItem -Id compare-file-allocation -Label 'SQL-Quelldateigrößen mit freiem Zielspeicher vergleichen'
                    }
                }
            }
            New-LabConsoleItem -Id back -Label 'Zurück / Abbrechen'
        )
        $review=Invoke-LabConsoleMenu -ScreenId 'evaluation-refresh-preview' -Title 'Ersatzentscheid lesen' `
            -Subtitle ("{0} · {1} · Keine Lizenzfreigabe, Speicherung oder Übernahme."-f$selected.InstanceId,$modeChoice.SelectedItem.Label) -Items $reviewItems
        if($review.Status-cne'Selected'-or$review.SelectedItem.Id-ceq'back'){return}
        if($review.SelectedItem.Id-cnotin$reviewItems.Id){throw 'EVALUATION_REFRESH_INPUT_INVALID'}
        $planArgs = @{
            RunId=$selected.RunId; InstanceId=$selected.InstanceId; DataRoot=$selected.DataRoot
            Mode=$mode; ExpectedSnapshotDigest=$selected.Digest
        }
        if ($review.SelectedItem.Id -ceq 'observe') { $planArgs.ObserveSqlSource = $true }
        if ($review.SelectedItem.Id -ceq 'observe-source-database') {
            $database = Read-LabConsoleTextInput -Prompt 'Name der regulären Benutzerdatenbank in der gewählten Quelle'
            if ($database.Status -cne 'Confirmed') { return }
            $planArgs.SourceDatabaseName = [string]$database.Value
            $planArgs.ObserveSqlSource = $true
        }
        if ($review.SelectedItem.Id -ceq 'observe-windows') { $planArgs.ObserveWindowsLicense = $true }
        if ($review.SelectedItem.Id -cin @('target','observe-target-windows','observe-target-sql','observe-target-storage','compare-file-allocation')) {
            $readTargetWindows = $review.SelectedItem.Id -ceq 'observe-target-windows'
            $readTargetSql = $review.SelectedItem.Id -ceq 'observe-target-sql'
            $readTargetStorage = $review.SelectedItem.Id -ceq 'observe-target-storage'
            $compareFileAllocation = $review.SelectedItem.Id -ceq 'compare-file-allocation'
            $candidates = if ($readTargetWindows -or $readTargetSql -or $readTargetStorage -or $compareFileAllocation) { @($targetCandidates | Where-Object State -CEQ 'RUNNING') } else { $targetCandidates }
            $targetItems = @($runItems | Where-Object { $_.Id -cin $candidates.RunId })
            $targetTitle = $review.SelectedItem.Label
            $targetChoice = Invoke-LabConsoleMenu -ScreenId 'evaluation-refresh-target' -Title $targetTitle `
                -Subtitle 'Separates SQL-2025-Lab unter demselben Lab_Data auswählen. Keine Änderung.' -Items $targetItems
            if ($targetChoice.Status -cne 'Selected') { return }
            $target = @($candidates | Where-Object RunId -CEQ $targetChoice.SelectedItem.Id)
            if ($target.Count -ne 1) { throw 'EVALUATION_REFRESH_TARGET_SELECTION_INVALID' }
            $planArgs.TargetRunId = $target[0].RunId
            $planArgs.TargetInstanceId = $target[0].InstanceId
            $planArgs.ExpectedTargetSnapshotDigest = $target[0].Digest
            if ($readTargetWindows) { $planArgs.ObserveTargetWindowsLicense = $true }
            if ($readTargetSql) { $planArgs.ObserveTargetSqlReadiness = $true }
            if ($readTargetStorage) { $planArgs.ObserveTargetStorage = $true }
            if ($compareFileAllocation) { $planArgs.CompareFileAllocation = $true }
        }
        $plan=New-LabEvaluationRefreshPlan @planArgs
        Write-LabInfo 'BLOCKED: reine Planung. SQL-Bereitschaft der Quelle NOT_CHECKED; keine Aktionen, Speicherung, Übernahme oder Gleichwertigkeitsbestätigung.'
        foreach($evaluation in $plan.Evaluations){
            $component=if($evaluation.Component-ceq'Windows'){'Windows'}else{'SQL Server'}
            $expiry=if($evaluation.EvaluationExpiresAt){$evaluation.EvaluationExpiresAt}else{'Nicht belegt / nicht anwendbar'}
            $days=if($null-ne$evaluation.DaysRemaining){[string]$evaluation.DaysRemaining}else{'Unbekannt / nicht anwendbar'}
            Write-LabInfo ("{0}: {1} · Quelle: {2} · Evidence: {3} · Frist UTC: {4} · Resttage: {5}"-f$component,$evaluation.Status,$evaluation.DeadlineSource,$evaluation.EvidenceStatus,$expiry,$days)
        }
        Write-LabInfo 'Die beiden Fristzeilen zeigen gespeicherte Windows- und SQL-Evidence.'
        if ($plan.WindowsLicenseObservation) {
            $windows = $plan.WindowsLicenseObservation
            Write-LabInfo ("Windows-Lizenz im Gast: {0} · Lizenz: {1} · Beobachtet UTC: {2} · Frist UTC: {3}" -f
                $windows.Status, $windows.LicenseState, $windows.ObservedAt, $windows.EvaluationExpiresAt)
        }
        if ($plan.SqlSourceInventory) {
            Write-LabInfo ("SQL-Quellzähler im Gast: {0}. Vollständige Instanzinventur bleibt offen." -f $plan.SqlSourceInventory.Status)
            foreach ($item in $plan.SqlSourceInventory.Items) { Write-LabInfo ("{0}: {1}" -f $item.Category,$item.Count) }
            $allocated = $plan.SqlSourceInventory.AllocatedFileStorage
            if ($allocated.Status -ceq 'OBSERVED') {
                Write-LabInfo ("SQL-Quelldateigrößen laut Katalog · Daten: {0} Bytes · Log: {1} Bytes" -f $allocated.DataBytes,$allocated.LogBytes)
                Write-LabInfo 'Nur reguläre Benutzerdatenbanken. Zielbedarf und Backupgröße bleiben offen.'
            } else { Write-LabInfo 'SQL-Quelldateigrößen konnten nicht bestimmt werden.' }
            foreach ($finding in $plan.SqlSourceInventory.DependencyFindings) {
                Write-LabInfo ("Vor Übernahme prüfen: {0} · {1} ({2})" -f $finding.Code,$finding.Category,$finding.Count)
            }
            foreach ($line in Format-LabEvaluationRefreshDatabaseDependencies -Observation $plan.SqlSourceInventory.PSObject.Properties['DatabaseDependencies']?.Value) {
                Write-LabInfo $line
            }
        }
        if ($plan.TargetAssessment) {
            $targetView = $plan.TargetAssessment
            Write-LabInfo ("Ziellab {0} / {1} · SQL {2} · registriert als {3} · {4}" -f
                $targetView.RunId,$targetView.InstanceId,$targetView.SqlVersion,$targetView.RegisteredState,$targetView.Status)
            if ($targetView.PSObject.Properties['WindowsLicenseObservation']) {
                $targetLicense = $targetView.WindowsLicenseObservation
                Write-LabInfo ("Windows-Lizenz im Ziellab: {0} · Lizenz: {1} · Beobachtet UTC: {2} · Frist UTC: {3}" -f
                    $targetLicense.Status, $targetLicense.LicenseState, $targetLicense.ObservedAt, $targetLicense.EvaluationExpiresAt)
            }
            if ($targetView.PSObject.Properties['SqlReadinessObservation']) {
                $targetSql = $targetView.SqlReadinessObservation
                Write-LabInfo ("SQL-Bereitschaft im Ziellab: {0} · Beobachtet UTC: {1}" -f $targetSql.Status, $targetSql.ObservedAt)
                $edition = $targetView.SqlEditionObservation
                Write-LabInfo ("SQL-Edition im Ziellab: {0} · {1} · Evaluationsfrist: {2}" -f $edition.Status,$edition.Classification,$edition.EvaluationDeadlineStatus)
            }
            if ($targetView.PSObject.Properties['StorageObservation']) {
                $storage = $targetView.StorageObservation
                Write-LabInfo ("Freier Gast-Speicher im Ziellab: {0} · Beobachtet UTC: {1}" -f $storage.Status, $storage.ObservedAt)
                foreach ($volume in $storage.Volumes) {
                    Write-LabInfo ("{0}: {1} Bytes frei" -f ($volume.Roles -join ' / '), $volume.AvailableBytes)
                }
                Write-LabInfo 'Hostkapazität und erforderlicher Transferspeicher werden separat geprüft.'
            }
            if ($targetView.PSObject.Properties['FileAllocationComparison']) {
                $comparison = $targetView.FileAllocationComparison
                Write-LabInfo ("Vergleich zugewiesener SQL-Dateien: {0}" -f $comparison.Status)
                foreach ($volume in $comparison.Volumes) {
                    Write-LabInfo ("{0}: {1} Bytes zugewiesen / {2} Bytes frei" -f ($volume.Roles -join ' / '),$volume.AllocatedBytes,$volume.AvailableBytes)
                }
                Write-LabInfo 'Backupplatz, Wachstum, Hostkapazität und Übernahme erfordern eigene Nachweise.'
            }
            foreach ($check in $targetView.Checks) { Write-LabInfo ("Zielprüfung: {0}" -f $check) }
        }
        foreach($blocker in $plan.Blockers){Write-LabInfo ("Offen: {0}"-f$blocker)}
        foreach($step in $plan.NextSteps){Write-LabInfo $step}
        $null=Wait-LabConsoleAcknowledgement
    } catch {
        $known=@('EVALUATION_REFRESH_BINDING_CHANGED','EVALUATION_REFRESH_SCOPE_UNSUPPORTED','EVALUATION_REFRESH_BINDING_INVALID','EVALUATION_REFRESH_INPUT_INVALID','EVALUATION_REFRESH_MODE_INVALID',
            'EVALUATION_REFRESH_TARGET_SELECTION_INVALID','EVALUATION_REFRESH_TARGET_UNAVAILABLE','EVALUATION_REFRESH_TARGET_SCOPE_UNSUPPORTED')
        $code=if($_.Exception.Message-cin$known){$_.Exception.Message}else{'EVALUATION_REFRESH_BINDING_UNAVAILABLE'}
        Write-LabWarning ("{0}: Vorschau nicht verfügbar; registrierte Metadaten prüfen. Keine Änderung ausgeführt."-f$code)
        $null=Wait-LabConsoleAcknowledgement
    }
}
