function Read-LabAiPersistentDocumentsInteractive {
    param([ValidateSet('Apply','Query','Sync','Migrate')][string]$Action)

    $selection = Read-LabConsoleTextInput -Prompt 'Absoluter Pfad zur lokalen JSON-Datei' -MaskInput
    if ($selection.Status -ne 'Confirmed') { return $null }
    try {
        $file = Get-LabLlamaStartPlanItem -Path $selection.Value
        if ($file.Extension -ine '.json' -or $file.Length -lt 1 -or $file.Length -gt 512KB) { throw 'invalid' }
        $buffer = [byte[]]::new(512KB + 1)
        try {
            $stream = [IO.File]::Open($file.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
            try {
                $count = 0
                while ($count -lt $buffer.Length) {
                    $received = $stream.Read($buffer, $count, $buffer.Length - $count)
                    if ($received -eq 0) { break }
                    $count += $received
                }
            }
            finally { $stream.Dispose() }
            if ($count -lt 1 -or $count -gt 512KB) { throw 'invalid' }
            $json = [Text.UTF8Encoding]::new($false, $true).GetString($buffer, 0, $count).TrimStart([char]0xfeff)
            $payload = ConvertFrom-Json -InputObject $json -AsHashtable -NoEnumerate -Depth 6 -ErrorAction Stop
        }
        finally { [Array]::Clear($buffer) }
        $required = @('Documents')
        if ($Action -eq 'Sync') { $required += 'ExpectedDocuments' }
        if ($Action -eq 'Query') { $required += 'Question' }
        $allowed = @($required)
        if ($Action -ne 'Migrate') { $allowed += 'EmbeddingModelKey' }
        if ($payload -isnot [Collections.IDictionary] -or @($required | Where-Object { $_ -cnotin $payload.Keys }).Count -or
            @($payload.Keys | Where-Object { $_ -cnotin $allowed }).Count) { throw 'invalid' }
        foreach ($key in $required | Where-Object { $_ -cne 'Question' }) {
            $documents = $payload[$key]
            if ($documents -isnot [array] -or $documents.Count -notin (1..16)) { throw 'invalid' }
            foreach ($document in $documents) {
                if ($document -isnot [Collections.IDictionary] -or $document.Count -ne 2 -or 'Id' -cnotin $document.Keys -or
                    'Content' -cnotin $document.Keys -or $document.Id -isnot [string] -or $document.Content -isnot [string]) { throw 'invalid' }
            }
            $null = ConvertTo-LabAiPersistentDocuments $documents
        }
        if ($Action -eq 'Query' -and ($payload.Question -isnot [string] -or [string]::IsNullOrWhiteSpace($payload.Question) -or
            $payload.Question.Length -gt 1000)) { throw 'invalid' }
        if ('EmbeddingModelKey' -cin $payload.Keys) {
            $metadata = (Get-Command Invoke-SqlServerLabAiPersistentRetrieval).Parameters['EmbeddingModelKey'].Attributes
            $models = ($metadata | Where-Object { $_ -is [Management.Automation.ValidateSetAttribute] }).ValidValues
            if ($payload.EmbeddingModelKey -isnot [string] -or $payload.EmbeddingModelKey -cnotin $models) { throw 'invalid' }
        }
        return $payload
    }
    catch { throw 'AI_PERSISTENT_DOCUMENT_FILE_INVALID' }
}

function Invoke-LabAiPersistentFixtureInteractive {
    try {
        $targets = @(Get-LabContainerSqlConsoleTargets | Where-Object {
            $_.SqlVersion -match '^2025(?:[-_]|$)' -and $_.InstanceId -cmatch '^[A-Za-z][A-Za-z0-9_-]{0,63}\z'
        })
        if (-not $targets.Count) {
            Write-LabInfo 'Für persistentes Retrieval wird ein laufender SQL-2025-Container benötigt.'
            $null = Wait-LabConsoleAcknowledgement
            return
        }
        $choices = @(for ($index = 0; $index -lt $targets.Count; $index++) {
            New-LabConsoleItem -Id "sql-$index" -Label $targets[$index].Label -Data $targets[$index]
        })
        $target = Select-LabConsoleDataItem -ScreenId 'persistent-fixture-target' -Title 'SQL-2025-Instanz für persistentes Retrieval' -Items $choices
        if (-not $target) { return }
        $operation = Select-LabConsoleDataItem -ScreenId 'persistent-fixture-action' -Title 'Persistente Retrieval-Collections' -Items @(
            New-LabConsoleItem -Id 'initial' -Label 'Beispieldaten anlegen' -Data @{Action='Apply'; FixtureRevision='Initial'}
            New-LabConsoleItem -Id 'delta' -Label 'Beispieldaten aktualisieren' -Data @{Action='Apply'; FixtureRevision='Delta'}
            New-LabConsoleItem -Id 'backup' -Label 'Beispielfrage zu Backups stellen' -Data @{Action='Query'; QueryId='backup'}
            New-LabConsoleItem -Id 'cleanup' -Label 'Beispielfrage zur Bereinigung stellen' -Data @{Action='Query'; QueryId='cleanup'}
            New-LabConsoleItem -Id 'migrate' -Label 'Beispielsammlung auf Nomic Embed v2 umstellen' -Data @{Action='Migrate'; FixtureRevision='Delta'; TargetModelKey='ollama-nomic-embed-text-v2-moe'}
            New-LabConsoleItem -Id 'own-apply' -Label 'Eigene Dokumente aus JSON anlegen' -Data @{Action='Apply'; OwnDocuments=$true}
            New-LabConsoleItem -Id 'own-query' -Label 'Eigene Collection mit freier Frage abfragen' -Data @{Action='Query'; OwnDocuments=$true}
            New-LabConsoleItem -Id 'own-sync' -Label 'Eigene Collection mit JSON synchronisieren' -Data @{Action='Sync'; OwnDocuments=$true}
            New-LabConsoleItem -Id 'own-migrate' -Label 'Eigene Collection auf Nomic Embed v2 umstellen' -Data @{Action='Migrate'; OwnDocuments=$true; TargetModelKey='ollama-nomic-embed-text-v2-moe'}
            New-LabConsoleItem -Id 'prune' -Label 'Alte Generationen einer eigenen Collection löschen' -Data @{Action='Prune'}
            New-LabConsoleItem -Id 'remove' -Label 'Datenbank einer eigenen Collection löschen' -Data @{Action='Remove'}
        )
        if (-not $operation) { return }
        $idDefault = if ($operation.Action -eq 'Apply' -and ($operation.OwnDocuments -or $operation.FixtureRevision -eq 'Initial')) { [guid]::NewGuid().ToString('D') } else { '' }
        $value = Read-LabConsoleTextInput -Prompt 'Collection-ID (GUID)' -Default $idDefault
        if ($value.Status -ne 'Confirmed') { return }
        $collection = [guid]::Empty
        if (-not [guid]::TryParseExact($value.Value, 'D', [ref]$collection) -or $collection -eq [guid]::Empty) { throw 'AI_PERSISTENT_IDENTITY_INVALID' }
        $parameters = $operation.Clone()
        $parameters.Remove('OwnDocuments')
        $parameters.RunId = $target.RunId
        $parameters.InstanceId = $target.InstanceId
        $parameters.CollectionId = $collection.ToString('D')
        if ($operation.OwnDocuments) {
            $payload = Read-LabAiPersistentDocumentsInteractive -Action $operation.Action
            if ($null -eq $payload) { return }
            foreach ($field in $payload.Keys) { $parameters[$field] = $payload[$field] }
        }
        if ($operation.Action -eq 'Prune') {
            $retention = Read-LabConsoleTextInput -Prompt 'Anzahl der jüngsten Generationen, die erhalten bleiben (1–31)' -Default '2'
            if ($retention.Status -ne 'Confirmed') { return }
            if ($retention.Value -cnotmatch '^(?:[1-9]|[12][0-9]|3[01])\z') { throw 'AI_PERSISTENT_RETENTION_INVALID' }
            $parameters.KeepGenerations = [int]$retention.Value
        }
        if ($operation.Action -in @('Apply', 'Migrate', 'Sync')) {
            $parameters.Resume = Read-LabConfirm -Prompt 'Bereits begonnenen Auftrag mit derselben Collection-ID fortsetzen?' -Default $false
        }
        $effect = switch ($operation.Action) {
            'Apply' { "Synthetische Generation $($operation.FixtureRevision) schreiben" }
            'Query' { 'Synthetische Frage an die aktive Generation stellen' }
            'Migrate' { 'Beispielsammlung neu einbetten und auf Nomic Embed v2 umstellen' }
            'Sync' { "Erwarteten Bestand von $($parameters.ExpectedDocuments.Count) Dokumenten prüfen und durch $($parameters.Documents.Count) Dokumente ersetzen" }
            'Prune' { "Nur die jüngsten $($parameters.KeepGenerations) Generationen behalten und die übrigen dauerhaft löschen. Die aktive Generation bleibt erhalten" }
            'Remove' { 'Die gesamte Collection-Datenbank mit allen Dokumenten und Generationen dauerhaft löschen' }
        }
        if ($operation.OwnDocuments -and $operation.Action -ne 'Sync') {
            $effect = switch ($operation.Action) {
                'Apply' { "$($parameters.Documents.Count) eigene Dokumente als neue Collection schreiben" }
                'Query' { "Freie Frage für die gebundene Collection mit $($parameters.Documents.Count) Dokumenten stellen" }
                'Migrate' { "$($parameters.Documents.Count) eigene Dokumente neu einbetten und auf Nomic Embed v2 umstellen" }
            }
        }
        Write-LabInfo "Collection-ID: $collection · Ziel: $($target.Label) · Run-ID: $($target.RunId)"
        if (-not (Read-LabConfirm -Prompt "${effect}?" -Default $false)) { return }
        $result = Invoke-SqlServerLabAiPersistentRetrieval @parameters -Confirm:$false -ErrorAction Stop
        Write-LabInfo ('Status: {0} · Generation: {1} · Embedding-Requests: {2}' -f $result.Status, $result.Generation, $result.EmbeddingRequests)
        if ($operation.Action -eq 'Query') { Write-LabInfo ('Treffer in Rangfolge: {0}' -f ($result.Ranked.ChunkId -join ', ')) }
        if ($operation.Action -eq 'Prune') { Write-LabInfo ('Erhaltene Generationen: {0} · Gelöschte Generationen: {1}' -f $result.RetainedGenerations, $result.DeletedGenerations) }
    }
    catch {
        $code = if ($_.Exception.Message -cmatch '^AI_PERSISTENT_[A-Z_]{1,65}$') { $_.Exception.Message } else { 'AI_PERSISTENT_REQUEST_UNCONFIRMED' }
        Write-LabError "Der Retrieval-Schritt ist nicht bestätigt ($code). Prüfe SQL-2025-Instanz, Collection-ID und die Voraussetzungen des Schritts."
    }
    $null = Wait-LabConsoleAcknowledgement
}
