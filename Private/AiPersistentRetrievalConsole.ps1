function Invoke-LabAiPersistentFixtureInteractive {
    try {
        $targets = @(Get-LabContainerSqlConsoleTargets | Where-Object {
            $_.SqlVersion -match '^2025(?:[-_]|$)' -and $_.InstanceId -cmatch '^[A-Za-z][A-Za-z0-9_-]{0,63}\z'
        })
        if (-not $targets.Count) {
            Write-LabInfo 'Für die Retrieval-Demo wird ein laufender SQL-2025-Container benötigt.'
            $null = Wait-LabConsoleAcknowledgement
            return
        }
        $choices = @(for ($index = 0; $index -lt $targets.Count; $index++) {
            New-LabConsoleItem -Id "sql-$index" -Label $targets[$index].Label -Data $targets[$index]
        })
        $target = Select-LabConsoleDataItem -ScreenId 'persistent-fixture-target' -Title 'SQL-2025-Instanz für Retrieval-Demo' -Items $choices
        if (-not $target) { return }
        $operation = Select-LabConsoleDataItem -ScreenId 'persistent-fixture-action' -Title 'Synthetische Retrieval-Collection' -Items @(
            New-LabConsoleItem -Id 'initial' -Label 'Beispieldaten anlegen' -Data @{Action='Apply'; FixtureRevision='Initial'}
            New-LabConsoleItem -Id 'delta' -Label 'Beispieldaten aktualisieren' -Data @{Action='Apply'; FixtureRevision='Delta'}
            New-LabConsoleItem -Id 'backup' -Label 'Beispielfrage zu Backups stellen' -Data @{Action='Query'; QueryId='backup'}
            New-LabConsoleItem -Id 'cleanup' -Label 'Beispielfrage zur Bereinigung stellen' -Data @{Action='Query'; QueryId='cleanup'}
            New-LabConsoleItem -Id 'migrate' -Label 'Beispielsammlung auf Nomic Embed v2 umstellen' -Data @{Action='Migrate'; FixtureRevision='Delta'; TargetModelKey='ollama-nomic-embed-text-v2-moe'}
        )
        if (-not $operation) { return }
        $idDefault = if ($operation.Action -eq 'Apply' -and $operation.FixtureRevision -eq 'Initial') { [guid]::NewGuid().ToString('D') } else { '' }
        $value = Read-LabConsoleTextInput -Prompt 'Collection-ID (GUID für Start und Wiederaufnahme)' -Default $idDefault
        if ($value.Status -ne 'Confirmed') { return }
        $collection = [guid]::Empty
        if (-not [guid]::TryParseExact($value.Value, 'D', [ref]$collection) -or $collection -eq [guid]::Empty) { throw 'AI_PERSISTENT_IDENTITY_INVALID' }
        $parameters = $operation.Clone()
        $parameters.RunId = $target.RunId
        $parameters.InstanceId = $target.InstanceId
        $parameters.CollectionId = $collection.ToString('D')
        if ($operation.Action -in @('Apply', 'Migrate')) {
            $parameters.Resume = Read-LabConfirm -Prompt 'Bereits begonnenen Auftrag mit derselben Collection-ID fortsetzen?' -Default $false
        }
        $effect = switch ($operation.Action) {
            'Apply' { "Synthetische Generation $($operation.FixtureRevision) schreiben" }
            'Query' { 'Synthetische Frage an die aktive Generation stellen' }
            'Migrate' { 'Beispielsammlung neu einbetten und auf Nomic Embed v2 umstellen' }
        }
        Write-LabInfo "Collection-ID: $collection · Ziel: $($target.Label)"
        if (-not (Read-LabConfirm -Prompt "${effect}?" -Default $false)) { return }
        $result = Invoke-SqlServerLabAiPersistentRetrieval @parameters -Confirm:$false -ErrorAction Stop
        Write-LabInfo ('Status: {0} · Generation: {1} · Embedding-Requests: {2}' -f $result.Status, $result.Generation, $result.EmbeddingRequests)
        if ($operation.Action -eq 'Query') { Write-LabInfo ('Treffer in Rangfolge: {0}' -f ($result.Ranked.ChunkId -join ', ')) }
    }
    catch {
        $code = if ($_.Exception.Message -cmatch '^AI_PERSISTENT_[A-Z_]{1,65}$') { $_.Exception.Message } else { 'AI_PERSISTENT_REQUEST_UNCONFIRMED' }
        Write-LabError "Die Retrieval-Demo ist nicht bestätigt ($code). Prüfe SQL-2025-Instanz, Collection-ID und lokales Modell."
    }
    $null = Wait-LabConsoleAcknowledgement
}
