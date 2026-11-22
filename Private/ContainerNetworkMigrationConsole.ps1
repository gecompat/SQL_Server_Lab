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
            'MIGRATION_BLOCKED' {
                Write-LabInfo ('Die Migration ist gesperrt. Prüfe Netzbesitz, Containerbindungen und Recovery. Befund {0}.' -f $plan.Reason)
                if ($plan.Recovery) {
                    Write-LabInfo ('Gespeichertes Recovery-Journal · Letzte protokollierte Phase {0} · Fehlercode {1}.' -f $plan.Recovery.LastRecordedPhase,$plan.Recovery.FailureCode)
                }
            }
            'MIGRATION_REQUIRED' {
                Write-LabInfo ('Subnetz: {0} → {1}. Betroffene verwaltete Container: {2}.' -f $plan.Actual.Subnet, $plan.Desired.Subnet, @($plan.ManagedContainers).Count)
                foreach ($container in $plan.ManagedContainers) {
                    $state = if ($container.WasRunning) { 'läuft' } else { 'gestoppt' }
                    Write-LabInfo ('{0} · {1}' -f $container.Name, $state)
                }
                Write-LabInfo 'Eine Ausführung kann laufende SQL-Container unterbrechen. Prüfe die Zuständigkeit aller betroffenen Runs und den Recovery-Zustand.'
                if (Read-LabConfirm -Prompt 'Diesen gebundenen Migrationsplan ausführen?' -Default $false) {
                    $result = Move-SqlServerLabContainerNetwork -Provider $provider -TargetSubnet $plan.Desired.Subnet `
                        -ExpectedPlanKey $plan.PlanKey -Confirm:$false -ErrorAction Stop
                    if ($result.Status -cne 'SUCCEEDED') { throw 'CONTAINER_NETWORK_MIGRATION_UNCONFIRMED' }
                    Write-LabInfo ('Netzmigration abgeschlossen. Migrierte Container: {0}. SQL-Bereitschaft separat prüfen.' -f $result.MigratedContainers)
                }
            }
            default { throw 'CONTAINER_NETWORK_PLAN_UNRECOGNIZED' }
        }
    }
    catch {
        if ($_.Exception.Message -ceq 'LAB_NETWORK_MIGRATION_TARGET_INVALID') {
            Write-LabError 'Das Zielsubnetz muss ein IPv4-Netz in CIDR-Schreibweise sein.'
        } elseif ($_.Exception.Message -ceq 'LAB_NETWORK_MIGRATION_TARGET_CONFLICT') {
            Write-LabError 'Das gewählte Zielsubnetz überschneidet sich mit einem bekannten Netz.'
        } elseif ($_.Exception.Message -ceq 'LAB_NETWORK_MIGRATION_PREVIEW_CHANGED') {
            Write-LabError 'Die Netzbindung hat sich geändert. Lies eine neue Vorschau.'
        } elseif ($_.Exception.Message -cmatch '^LAB_NETWORK_MIGRATION_[A-Z_]+$') {
            Write-LabError ('Die Netzmigration wurde nicht belegt. Lies die Vorschau erneut und prüfe den Befund {0}.' -f $_.Exception.Message)
        } else {
            Write-LabError 'Das Lab-Netz konnte nicht eindeutig geprüft werden. Prüfe die Provider-Erreichbarkeit und Netzkonfiguration.'
        }
    }
    $null = Wait-LabConsoleAcknowledgement
}

function Invoke-LabContainerNetworkPlanRequest {
    param([string]$Method, [Collections.Specialized.NameValueCollection]$Query)

    $provider = [string]$Query['provider']
    $target = [string]$Query['targetSubnet']
    if ($Method -cne 'GET' -or $provider -cnotin @('docker','podman') -or
        @($Query.AllKeys | Where-Object { $_ -cnotin @('provider','targetSubnet') }).Count -or
        ($target -and $target -cnotmatch '^\d{1,3}(?:\.\d{1,3}){3}/\d{1,2}$')) {
        return @{StatusCode=400;View=@{Code='CONTAINER_NETWORK_PLAN_REQUEST_INVALID'}}
    }
    try {
        $plan = Move-SqlServerLabContainerNetwork -Provider $provider -TargetSubnet $target -WhatIf -ErrorAction Stop 6>$null
        $view = [ordered]@{ContractVersion='SqlServerLab.GuidedContainerNetworkPlan/1.0';Provider=$provider;Status=$plan.Status}
        if ($plan.Status -ceq 'MIGRATION_REQUIRED') {
            $view.PlanKey = $plan.PlanKey
            $view.CurrentSubnet = $plan.Actual.Subnet
            $view.TargetSubnet = $plan.Desired.Subnet
            $view.ContainerCount = @($plan.ManagedContainers).Count
        } elseif ($plan.Status -ceq 'MIGRATION_BLOCKED') {
            $view.Code = $plan.Reason
            if ($plan.Recovery) { $view.Recovery = $plan.Recovery }
        }
        return @{StatusCode=200;View=$view}
    }
    catch {
        $code = if ($_.Exception.Message -cin @('LAB_NETWORK_MIGRATION_TARGET_INVALID','LAB_NETWORK_MIGRATION_TARGET_CONFLICT')) {
            $_.Exception.Message
        } else { 'CONTAINER_NETWORK_PLAN_UNAVAILABLE' }
        return @{StatusCode=422;View=@{Code=$code}}
    }
}
