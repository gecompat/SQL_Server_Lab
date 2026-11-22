function Show-LabResourcePlanInteractive {
    $choices = @(
        New-LabConsoleItem -Id 'all' -Label 'Beispieldaten und Laufzeitmedien' -Data 'All'
        New-LabConsoleItem -Id 'sample' -Label 'Nur Beispieldaten' -Data 'Sample'
        New-LabConsoleItem -Id 'software' -Label 'Nur Windows-/Hyper-V-Laufzeitmedien' -Data 'Software'
    )
    $kind = Select-LabConsoleDataItem -ScreenId 'resource-plan-selection' -Title 'Lokalen Ressourcenbedarf prüfen' -Items $choices
    if (-not $kind) { return }
    try {
        $records = @(Get-SqlServerLabResourcePlan -ResourceKind $kind -SummaryOnly -ErrorAction Stop)
        if (-not $records.Count) { Write-LabInfo 'Für die Auswahl sind keine Ressourcen katalogisiert.' }
        foreach ($record in $records) {
            Write-LabInfo ('{0} · {1}/{2} bereit · {3}' -f $record.ResourceId, $record.ReadyCount, $record.ArtifactCount, $record.Acquisition)
        }
    }
    catch {
        $code = if ($_.Exception.Message -match '^([A-Z_]{12,90})(?:\z|:)') { $Matches[1] } else { 'RESOURCE_SET_PLAN_UNAVAILABLE' }
        Write-LabError "Ressourcenbedarf nicht bestätigt ($code). Prüfe den konfigurierten Medienordner."
    }
    $null = Wait-LabConsoleAcknowledgement
}
