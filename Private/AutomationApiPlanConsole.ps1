function Show-LabAutomationApiPlanInteractive {
    $action = Select-LabConsoleDataItem -ScreenId 'automation-api-plan-choice' -Title 'Automatisierungsschnittstelle ansehen' -Items @(
        New-LabConsoleItem -Id 'reconcile' -Label 'Ressourcenabgleich' -Data 'Reconcile'
        New-LabConsoleItem -Id 'maintenance' -Label 'Wartung' -Data 'Maintenance'
        New-LabConsoleItem -Id 'storage' -Label 'Entfernung persistenten Speichers' -Data 'PersistentStorageRemoval'
        New-LabConsoleItem -Id 'state' -Label 'Upgrade eines synthetischen Run-States' -Data 'RunStateUpgrade'
        New-LabConsoleItem -Id 'import' -Label 'Portabler Lab-Import' -Data 'PortableLabImport'
        New-LabConsoleItem -Id 'recovery' -Label 'Hyper-V-Wiederherstellungspunkt' -Data 'HyperVRecoveryPoint'
    )
    if (-not $action) { return }
    try {
        $plan = Get-SqlServerLabAutomationPlan -Action $action -ErrorAction Stop
        if ($plan.Status -cne 'READY' -or $plan.Request.Action -cne $action -or $plan.ExecutionImplemented -ne $false) {
            throw 'AUTOMATION_API_PLAN_UNAVAILABLE'
        }
        Write-LabInfo ('Fachplan: {0} · Vertrag: {1}' -f $plan.Plan.Command, $plan.Plan.ContractVersion)
        Write-LabInfo ('Pflichtparameter: {0}' -f $(if ($plan.Plan.RequiredParameters.Count) { $plan.Plan.RequiredParameters -join ', ' } else { 'keine' }))
        Write-LabInfo ('Separater Aktionsbefehl: {0}' -f ($plan.Result.ActionCommand ?? 'nicht verfügbar'))
        Write-LabInfo 'Diese Ansicht beschreibt die Schnittstelle. Sie startet keinen Vorgang.'
    }
    catch { Write-LabError 'Die Automatisierungsschnittstelle ist für diese Auswahl nicht verfügbar.' }
    $null = Wait-LabConsoleAcknowledgement
}
