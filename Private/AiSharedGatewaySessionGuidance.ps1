function Invoke-LabAiSharedGatewaySessionStartInteractive {
    param([Parameter(Mandatory)]$Plan)

    $keys = @{}
    $upstreamKey = $null
    $startRequested = $false
    try {
        $canonical = Resolve-LabAiSharedGatewayPlan -Plan $Plan
        $stateRoot = Get-LabStateRoot
        $status = Get-SqlServerLabAiSharedGatewayStatus -Plan $canonical -StateRoot $stateRoot
        if ($status.Status -cne 'REGISTERED_STOPPED' -or $status.PlanKey -cne $canonical.PlanKey) {
            Write-LabWarning 'Start nicht verfügbar. Prüfe den Status der geschützten Registrierung und ob der Gateway-Port frei ist.'
            $null = Wait-LabConsoleAcknowledgement
            return
        }

        $leaseInput = Read-LabConsoleTextInput -Prompt 'Maximale Sitzungsdauer in Sekunden (60 bis 3600)' -Default '900'
        if ($leaseInput.Status -cne 'Confirmed') { return }
        $lease = 0
        if ($leaseInput.Value -isnot [string] -or $leaseInput.Value -cnotmatch '^[0-9]{1,4}$' -or
            -not [int]::TryParse($leaseInput.Value,[ref]$lease) -or $lease -lt 60 -or $lease -gt 3600) {
            Write-LabWarning 'Ungültige Sitzungsdauer. Gib 60 bis 3600 Sekunden ein.'
            $null = Wait-LabConsoleAcknowledgement
            return
        }

        Write-LabInfo ("Gateway {0} · Loopback-Port {1} · {2} Verbraucher · maximal {3} Sekunden" -f
            $canonical.GatewayId,$canonical.Port,$canonical.Consumers.Count,$lease)
        Write-LabInfo 'Der Start prüft Registrierung und Upstream erneut und startet einen befristeten Worker mit temporärem Schlüsselzustand. Dieselbe Modulsitzung behalten. Der Start bindet keine SQL-Verbraucher und richtet keinen Host-Autostart ein.'
        if (-not (Read-LabConfirm -Prompt 'Genau diese Gateway-Sitzung vorbereiten und nach Eingabe der Schlüssel starten?' -Default $false)) { return }

        foreach ($consumer in $canonical.Consumers) {
            $name = [string]$consumer.ApiKeyReference
            $entry = Read-LabConsoleTextInput -Prompt "Gateway-Schlüssel für $name (maskiert)" -AsSecureString
            if ($entry.Status -cne 'Confirmed') { return }
            if ($entry.Value -isnot [Security.SecureString]) { throw 'AI_SHARED_GATEWAY_CONSOLE_KEY_INVALID' }
            $keys[$name] = $entry.Value
            if (-not (Test-LabAiSharedGatewayServiceSecretValue -Secret $entry.Value)) { throw 'AI_SHARED_GATEWAY_CONSOLE_KEY_INVALID' }
        }

        $entry = Read-LabConsoleTextInput -Prompt 'Optionaler Upstream-Schlüssel (maskiert, leer für keinen Schlüssel)' -AsSecureString
        if ($entry.Status -cne 'Confirmed') { return }
        if ($entry.Value -isnot [Security.SecureString]) { throw 'AI_SHARED_GATEWAY_CONSOLE_KEY_INVALID' }
        $upstreamKey = $entry.Value
        $arguments = @{Plan=$canonical; StateRoot=$stateRoot; ApiKeyByReference=$keys; LeaseSeconds=$lease}
        if ($upstreamKey.Length) {
            if (-not (Test-LabAiSharedGatewayServiceSecretValue -Secret $upstreamKey)) { throw 'AI_SHARED_GATEWAY_CONSOLE_KEY_INVALID' }
            $arguments.UpstreamApiKey = $upstreamKey
        }

        $startRequested = $true
        $results = @(Start-SqlServerLabAiSharedGatewaySession @arguments)
        $result = $results | Select-Object -First 1
        if ($results.Count -ne 1 -or $result.Status -cne 'SESSION_ENDPOINT_VERIFIED' -or $result.PlanKey -cne $canonical.PlanKey -or
            $result.GatewayId -cne $canonical.GatewayId -or $result.LeaseSeconds -ne $lease -or
            [string]$result.OperationId -cnotmatch '^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$') {
            throw 'AI_SHARED_GATEWAY_CONSOLE_RESULT_UNCONFIRMED'
        }
        Write-LabInfo ("Gateway-Endpunkt bestätigt · eigene Sitzung {0} · SQL-Ausführung ungeprüft." -f $result.OperationId)
    } catch [Management.Automation.PipelineStoppedException] { throw }
    catch {
        $message = if ($startRequested) {
            'Start unbestätigt. Wähle gegebenenfalls die vorhandene eigene Gateway-Sitzung in diesem Modulhost. Keine automatische Wiederholung.'
        } else {
            'Vorbereitung abgebrochen. Prüfe Registrierung und Schlüssel. Schlüssel benötigen 24 bis 256 ASCII-Buchstaben oder Ziffern, Unterstriche oder Bindestriche.'
        }
        Write-LabWarning $message
    } finally {
        foreach ($key in $keys.Values) { $key.Dispose() }
        $keys.Clear()
        if ($upstreamKey) { $upstreamKey.Dispose() }
    }
    $null = Wait-LabConsoleAcknowledgement
}

function Invoke-LabAiSharedGatewaySessionStopInteractive {
    $owners = $script:AiSharedGatewaySessions
    $presented = @{}
    $items = @(if ($owners) {
        foreach ($id in ($owners.Keys | Sort-Object)) {
            $session = $owners[$id]
            $presented[$id] = $session
            $status = if ($session.Worker.HasExited) { 'Cleanup offen' } else { 'Eigener Worker' }
            New-LabConsoleItem -Id $id -Label ("{0} · Port {1} · {2}" -f $session.GatewayId,$session.Port,$id) -Value $status
        }
    })
    $items += New-LabConsoleItem -Id back -Label 'Zurück' -Shortcut 0
    $selection = Invoke-LabConsoleMenu -ScreenId 'ai-shared-gateway-session-stop' -Title 'Eigene Gateway-Sitzung stoppen' `
        -Subtitle 'Hier erscheinen ausschließlich Sitzungen dieses Modulhosts.' -Items $items
    if ($selection.Status -cne 'Selected' -or $selection.SelectedItem.Id -ceq 'back') { return }

    $id = [string]$selection.SelectedItem.Id
    if (-not $presented.ContainsKey($id)) { return }
    $session = $presented[$id]
    if (-not (Read-LabConfirm -Prompt ("Gateway {0} auf Port {1} stoppen? Auch unbekannte SQL-Verbraucher können die Verbindung verlieren." -f
        $session.GatewayId,$session.Port) -Default $false)) { return }

    try {
        $current = $script:AiSharedGatewaySessions
        if (-not $current -or -not $current.ContainsKey($id) -or -not [object]::ReferenceEquals($current[$id],$session)) {
            throw 'AI_SHARED_GATEWAY_SESSION_OWNERSHIP_NOT_FOUND'
        }
        $results = @(Stop-SqlServerLabAiSharedGatewaySession -OperationId $id)
        if ($results.Count -ne 1 -or $results[0].Status -cne 'CLEANUP_SUCCEEDED' -or $results[0].OperationId -cne $id) {
            throw 'AI_SHARED_GATEWAY_CONSOLE_RESULT_UNCONFIRMED'
        }
        Write-LabInfo 'Eigene Gateway-Sitzung beendet und temporärer Zustand bereinigt.'
    } catch [Management.Automation.PipelineStoppedException] { throw }
    catch { Write-LabWarning 'Ende und Bereinigung konnten nicht bestätigt werden. Prüfe den eigenen Sitzungsstatus in diesem Modulhost.' }
    $null = Wait-LabConsoleAcknowledgement
}
