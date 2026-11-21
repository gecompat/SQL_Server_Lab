function Show-LabContainerNetworkMigrationPlanInteractive {
    $provider = Select-LabConsoleDataItem -ScreenId 'container-network-provider' -Title 'Lab-Netz prüfen' -Items @(
        New-LabConsoleItem -Id 'docker' -Label 'Docker' -Data 'docker'
        New-LabConsoleItem -Id 'podman' -Label 'Podman' -Data 'podman'
    )
    if (-not $provider) { return }
    $target = Read-LabConsoleTextInput -Prompt 'IPv4-Zielsubnetz in CIDR-Schreibweise (leer für automatische Auswahl)'
    if ($target.Status -ne 'Confirmed') { return }
    try {
        $plan = Move-SqlServerLabContainerNetwork -Provider $provider -TargetSubnet ([string]$target.Value).Trim() -WhatIf -ErrorAction Stop
        switch -CaseSensitive ($plan.Status) {
            'NO_NETWORK' { Write-LabInfo 'Für den Provider wurde kein Lab-Netz gefunden.' }
            'NO_CONFLICT' { Write-LabInfo 'Das Lab-Netz hat keinen erkannten Subnetzkonflikt.' }
            'MIGRATION_BLOCKED' { Write-LabInfo ('Die Migration ist gesperrt. Prüfe Netzbesitz, Containerbindungen und Recovery. Befund {0}.' -f $plan.Reason) }
            'MIGRATION_REQUIRED' {
                Write-LabInfo ('Subnetz: {0} → {1}. Betroffene verwaltete Container: {2}.' -f $plan.Actual.Subnet, $plan.Desired.Subnet, @($plan.ManagedContainers).Count)
                foreach ($container in $plan.ManagedContainers) {
                    $state = if ($container.WasRunning) { 'läuft' } else { 'gestoppt' }
                    Write-LabInfo ('{0} · {1}' -f $container.Name, $state)
                }
                Write-LabInfo 'Eine Ausführung kann laufende SQL-Container unterbrechen. Prüfe die Zuständigkeit aller betroffenen Runs und den Recovery-Zustand.'
            }
            default { throw 'CONTAINER_NETWORK_PLAN_UNRECOGNIZED' }
        }
    }
    catch {
        if ($_.Exception.Message -ceq 'LAB_NETWORK_MIGRATION_TARGET_INVALID') {
            Write-LabError 'Das Zielsubnetz muss ein IPv4-Netz in CIDR-Schreibweise sein.'
        } elseif ($_.Exception.Message -ceq 'LAB_NETWORK_MIGRATION_TARGET_CONFLICT') {
            Write-LabError 'Das gewählte Zielsubnetz überschneidet sich mit einem bekannten Netz.'
        } else {
            Write-LabError 'Das Lab-Netz konnte nicht eindeutig geprüft werden. Prüfe die Provider-Erreichbarkeit und Netzkonfiguration.'
        }
    }
    $null = Wait-LabConsoleAcknowledgement
}
