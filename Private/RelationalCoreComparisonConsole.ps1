function Get-LabContainerSqlConsoleTargets {
    $stateRoot = Get-LabStateRoot
    foreach ($run in Get-LabActiveRuns -StateRoot $stateRoot -NoWrite) {
        $runId = [guid]::Empty
        if ($run.state -ne 'RUNNING' -or -not [guid]::TryParseExact([string]$run.runId, 'D', [ref]$runId)) { continue }
        $connectionPath = Join-Path $stateRoot 'runs' $runId 'connection-info.json'
        try { $connection = Get-Content -LiteralPath $connectionPath -Raw -Encoding utf8 -ErrorAction Stop | ConvertFrom-Json -Depth 20 -ErrorAction Stop }
        catch { continue }
        foreach ($instance in $connection.instances) {
            $instanceId = [string]$instance.id
            if ($instance.provider -notin @('docker', 'podman') -or -not $instanceId -or
                @($connection.instances | Where-Object id -eq $instanceId).Count -ne 1) { continue }
            [pscustomobject]@{
                RunId = $runId.ToString('D')
                InstanceId = $instanceId
                Provider = [string]$instance.provider
                Label = '{0} · {1} · {2}' -f ($run.metadata.name ?? $runId), $instanceId, $instance.provider
            }
        }
    }
}

function Invoke-LabRelationalComparisonInteractive {
    try {
        $targets = @(Get-LabContainerSqlConsoleTargets)
        if ($targets.Count -lt 2) {
            Write-LabInfo 'Für den Vergleich sind zwei registrierte, laufende SQL-Containerinstanzen nötig.'
            $null = Wait-LabConsoleAcknowledgement
            return
        }
        $pair = [pscustomobject]@{ PairId = 'GuidedComparison' }
        $source = $null
        foreach ($side in @('Source', 'Target')) {
            $label = if ($side -eq 'Source') { 'Quelle' } else { 'Ziel' }
            $items = @(for ($index = 0; $index -lt $targets.Count; $index++) {
                $target = $targets[$index]
                if ($target -eq $source) { continue }
                New-LabConsoleItem -Id "target-$index" -Label $target.Label -Data $target
            })
            $selected = Select-LabConsoleDataItem -ScreenId "relational-compare-$side" -Title "$label für Datenbankvergleich auswählen" -Items $items
            if (-not $selected) { return }
            if ($side -eq 'Source') { $source = $selected }
            do {
                $database = Read-LabConsoleTextInput -Prompt "Datenbankname der Seite $label"
                if ($database.Status -ne 'Confirmed') { return }
                $valid = $database.Value -cmatch '^[A-Za-z][A-Za-z0-9_]{0,127}\z'
                if (-not $valid) { Write-LabError 'Der Name muss mit einem Buchstaben beginnen und darf nur Buchstaben, Ziffern oder Unterstriche enthalten.' }
            } until ($valid)
            $pair | Add-Member -NotePropertyName "${side}RunId" -NotePropertyValue $selected.RunId
            $pair | Add-Member -NotePropertyName "${side}InstanceId" -NotePropertyValue $selected.InstanceId
            $pair | Add-Member -NotePropertyName "${side}DatabaseName" -NotePropertyValue $database.Value
        }
        if (-not (Read-LabConfirm -Prompt 'Beide Datenbanken müssen ONLINE und READ_ONLY sein. Lesenden Vergleich starten? Das kann länger dauern.' -Default $false)) { return }
        $comparison = Test-SqlServerLabRelationalCoreComparison -ComparisonPair @($pair) -ErrorAction Stop
        $results = @($comparison.Pairs)
        if ($results.Count -ne 1 -or $results[0].Status -cnotin @('MATCH', 'DIFFERENT', 'UNSUPPORTED')) { throw 'COMPARISON_RESULT_INVALID' }
        $result = $results[0]
        Write-LabInfo ('RELATIONAL_CORE/1.0: {0} · Tabellen: {1} · Zeilen: {2}' -f $result.Status, $result.TablesCompared, $result.RowsCompared)
        foreach ($finding in $result.Findings) { Write-LabInfo ('{0} · Tabelle Nr. {1}' -f $finding.Code, $finding.TableOrdinal) }
    }
    catch { Write-LabError 'Der Datenbankvergleich konnte nicht bestätigt werden. Prüfe die gebundenen Instanzen und den Datenbanknamen.' }
    $null = Wait-LabConsoleAcknowledgement
}
