<# Gemeinsame read-only Fachansicht; keine Ereignisregistrierung oder Runtimeprobe. #>
function Get-LabEvaluationWatchView {
    [CmdletBinding()]
    param()

    $watch = Get-SqlServerLabEvaluationWatch -WarningDaysRemaining 30 -CriticalDaysRemaining 7
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($group in @(
        @{ Scope = 'Vorlage'; Entries = @($watch.Items) },
        @{ Scope = 'Registrierte Instanz'; Entries = @($watch.InstanceItems) }
    )) {
        foreach ($entry in $group.Entries) {
            if ($null -eq $entry) { continue }
            $component = if ($entry.Component -eq 'SqlServer') { 'SQL Server' } else { 'Windows' }
            $reference = if ($group.Scope -eq 'Vorlage') { [string]$entry.ArtifactId } else { "$($entry.InstanceId) · $($entry.RunId)" }
            # Steuerzeichen aus alten Metadaten dürfen keine Terminalbefehle werden.
            $reference = $reference -replace '[\p{Cc}\p{Cf}]', ''
            $shortReference = if ($group.Scope -eq 'Vorlage') {
                '…' + $reference.Substring([math]::Max(0, $reference.Length - 12))
            } else {
                ([string]$entry.InstanceId -replace '[\p{Cc}\p{Cf}]', '') + ' · ' + ([string]$entry.RunId).Substring(0, [math]::Min(8, ([string]$entry.RunId).Length))
            }
            $status = switch ([string]$entry.Status) {
                'OK' { 'Außerhalb der Warnfrist' }
                'WARNING' { 'Warnfrist erreicht' }
                'CRITICAL' { 'Kritische Restlaufzeit' }
                'EXPIRED' { 'Abgelaufen' }
                'NOT_APPLICABLE' { 'Keine Evaluation laut Evidence' }
                default { 'Unbekannt; keine gültige Fristaussage' }
            }
            $source = if ($group.Scope -eq 'Vorlage') { 'Registrierte Vorlagenmetadaten; keine Gastbeobachtung' }
                elseif ($entry.DeadlineSource -eq 'PERSISTED_WINDOWS_ACTIVATION') { 'Gespeicherte Windows-Aktivierung; keine Liveprüfung' }
                elseif ($entry.DeadlineSource -eq 'SQL_GUEST_OBSERVED') { 'Gebundene SQL-Gast-Evidence; keine neue Gastabfrage' }
                elseif ($entry.DeadlineSource -eq 'SQL_GUEST_NO_DEADLINE') { 'SQL-Gast-Evidence ohne Evaluationsfrist' }
                else { 'Quelle fehlt oder ist nicht hinreichend belegt' }
            $freshness = if ($group.Scope -eq 'Vorlage' -or $entry.Component -eq 'Windows') {
                'Historische Metadaten; Evidencezeit und Aktualität unbekannt, nicht live geprüft'
            } else {
                switch ([string]$entry.EvidenceStatus) {
                    'CURRENT' { 'Frische, gebundene Evidence' }
                    'NOT_EVALUATION' { 'Frische Evidence: keine Evaluation' }
                    'EVIDENCE_STALE' { 'Veraltet; keine aktuelle Fristaussage' }
                    'EVIDENCE_MISSING' { 'Evidence fehlt' }
                    'EVIDENCE_INVALID' { 'Evidence ungültig' }
                    'DEADLINE_UNKNOWN' { 'Evidence vorhanden; Frist unbekannt' }
                    default { 'Evidence nicht hinreichend belegt' }
                }
            }
            $next = switch ([string]$entry.RefreshAction) {
                'MANUAL_REBUILD_REQUIRED' { 'Ersatz oder Migration fachlich planen. Dieser Dialog erneuert oder entfernt nichts.' }
                'MANUAL_REBUILD_RECOMMENDED' { 'Ersatz rechtzeitig planen; Datenübernahme und Rückfall separat klären.' }
                'CAPTURE_REQUIRED' { 'SQL-Gast-Evidence im gesonderten Capture-Verfahren prüfen oder erneuern; kein automatischer Gastzugriff.' }
                'NO_ACTION' { 'Aktuell keine Fristmaßnahme aus dieser Evidence; bei Bedarf ausdrücklich erneut lesen.' }
                default { 'Lizenz- und Fristquelle gesondert prüfen; unbekannt bedeutet nicht unbegrenzt gültig.' }
            }
            $fields = @(
                [pscustomobject]@{ Label = 'Geltungsbereich'; Value = "$($group.Scope) · $component" },
                [pscustomobject]@{ Label = 'Referenz'; Value = $reference },
                [pscustomobject]@{ Label = 'Bewertung'; Value = $status },
                [pscustomobject]@{ Label = 'Quelle'; Value = $source },
                [pscustomobject]@{ Label = 'Aktualität'; Value = $freshness },
                [pscustomobject]@{ Label = 'Frist (UTC)'; Value = $(if ($entry.EvaluationExpiresAt) { [string]$entry.EvaluationExpiresAt } else { 'Nicht belegt / nicht anwendbar' }) },
                [pscustomobject]@{ Label = 'Resttage'; Value = $(if ($null -ne $entry.DaysRemaining) { [string]$entry.DaysRemaining } else { 'Unbekannt / nicht anwendbar' }) },
                [pscustomobject]@{ Label = 'Nächster Schritt'; Value = $next }
            )
            $rows.Add([pscustomobject]@{
                Id = [string]$rows.Count
                Label = "$($group.Scope) · $component · $shortReference"
                Summary = $status
                Fields = $fields
            })
        }
    }
    [pscustomobject]@{
        GeneratedAt = [string]$watch.GeneratedAt
        Scope = 'Konfigurierter State-Root: registrierte Hyper-V-Vorlagen und Instanzen. Windows-Instanzen: RUNNING; SQL-Instanzen: RUNNING oder STOPPED. Kein vollständiges Hostinventar.'
        Notice = 'Nur gespeicherte Metadaten; keine Live-, Lizenz- oder SQL-Bereitschaftsprüfung. Warnung: 30 Tage; kritisch: 7 Tage. Es werden keine Ereignisse gespeichert.'
        EmptyMessage = 'Keine bewertbaren registrierten Einträge in diesem Scope. Das ist kein Nachweis gültiger Lizenzen oder fehlender Ablaufprobleme.'
        Rows = @($rows)
    }
}

function Show-LabEvaluationWatchInteractive {
    [CmdletBinding()]
    param()

    $view = $null
    $message = 'Gespeicherte Windows-/SQL-Fristen ausdrücklich lesen; kein Start, keine Änderung.'
    while ($true) {
        $items = @(
            New-LabConsoleItem -Id 'read' -Label 'Evaluationsfristen lesen / aktualisieren' -Shortcut 'r'
            if ($view) {
                foreach ($row in $view.Rows) {
                    New-LabConsoleItem -Id ('entry-' + $row.Id) -Label $row.Label -Value $row.Summary -Data $row
                }
            }
            New-LabConsoleItem -Id 'back' -Label 'Zurück' -Shortcut '0'
        )
        $selection = Invoke-LabConsoleMenu -ScreenId 'evaluation-watch-menu' -Title 'Windows-/SQL-Evaluationsfristen' -Subtitle $message -Items $items
        if ($selection.Status -eq 'Cancelled') { return }
        if ($selection.Status -ne 'Selected') { continue }
        if ($selection.SelectedItem.Id -eq 'back') { return }
        if ($selection.SelectedItem.Id -eq 'read') {
            try {
                $view = Get-LabEvaluationWatchView
                $message = if ($view.Rows.Count -eq 0) { $view.EmptyMessage } else { "Gelesen: $($view.GeneratedAt) · historische Evidence; Eintrag für Details wählen." }
            }
            catch {
                $view = $null
                $message = 'Evaluationsfristen konnten nicht gelesen werden. State-Konfiguration und Leserechte prüfen; danach erneut lesen. Keine gültige Fristaussage.'
            }
            continue
        }
        $row = $selection.SelectedItem.Data
        if (-not $row -or -not $view) { continue }
        Write-Host ''
        Write-Host $view.Scope
        Write-Host $view.Notice
        Write-Host ("Gelesen: {0}" -f $view.GeneratedAt)
        foreach ($field in $row.Fields) { Write-Host ("{0}: {1}" -f $field.Label, $field.Value) }
        $null = Wait-LabConsoleAcknowledgement -Prompt 'Enter oder Escape: Zurück zur Auswahl'
    }
}
