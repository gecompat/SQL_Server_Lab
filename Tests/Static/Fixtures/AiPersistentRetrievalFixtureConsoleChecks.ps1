param([Parameter(Mandatory)]$Module)

$ErrorActionPreference='Stop'
& $Module {
    $originalRuntime = ${function:Invoke-LabAiPersistentRetrieval}
    $script:fixturePlans = [Collections.Generic.List[object]]::new()
    $documentFile = Join-Path ([IO.Path]::GetTempPath()) ('lab-retrieval-input-' + [guid]::NewGuid().ToString('N') + '.json')
    try {
        [IO.File]::WriteAllText($documentFile, '{"ExpectedDocuments":[{"Id":"sample-doc","Content":"Synthetic old"}],"Documents":[{"Id":"sample-doc","Content":"Synthetic new"}]}')
        function script:Invoke-LabAiPersistentRetrieval {
            param($Plan,$StateRoot)
            $script:fixturePlans.Add($Plan)
            $status = switch ($Plan.Action) { 'Prune' { 'PRUNED' }; 'Remove' { 'REMOVED' }; default { 'COMMITTED' } }
            [pscustomobject]@{Status=$status;Generation=$Plan.Generation;EmbeddingRequests=0;RetainedGenerations=3;DeletedGenerations=1}
        }
        $runId = '11111111-1111-1111-1111-111111111111'
        $collection = '22222222-2222-2222-2222-222222222222'
        $operations = [Collections.Generic.Queue[string]]::new()
        foreach ($operation in @('delta','delta','prune','remove','remove','own-sync')) { $operations.Enqueue($operation) }
        function Get-LabContainerSqlConsoleTargets {
            [pscustomobject]@{RunId=$runId;InstanceId='primary';Label='Synthetic SQL';Provider='docker';SqlVersion='2025-CU9'}
            [pscustomobject]@{RunId=$collection;InstanceId='legacy';Label='Legacy SQL';Provider='podman';SqlVersion='2022'}
        }
        function Select-LabConsoleDataItem {
            param($ScreenId,$Title,$Items)
            if ($ScreenId -ceq 'persistent-fixture-target' -and $Items.Count -eq 1) { return $Items[0].Data }
            if ($ScreenId -ceq 'persistent-fixture-action') {
                $selected = $operations.Dequeue()
                return ($Items | Where-Object Id -ceq $selected).Data
            }
            throw 'UNEXPECTED_SELECTION'
        }
        function Read-LabConsoleTextInput {
            param($Prompt,$Default,[switch]$MaskInput)
            if ($MaskInput) { return [pscustomobject]@{Status='Confirmed';Value=$documentFile} }
            if ($Default -eq '2') { return [pscustomobject]@{Status='Confirmed';Value='3'} }
            if ($Default) { throw 'UNEXPECTED_COLLECTION_DEFAULT' }
            [pscustomobject]@{Status='Confirmed';Value=$collection}
        }
        $decisions = [Collections.Generic.Queue[bool]]::new()
        foreach ($decision in @($false, $false, $true, $true, $true, $false, $true, $false, $true)) { $decisions.Enqueue($decision) }
        function Read-LabConfirm { param($Prompt,$Default) if ($Default) { throw 'UNSAFE_DEFAULT' }; $decisions.Dequeue() }
        function Wait-LabConsoleAcknowledgement { $null }
        function Write-LabError { param($Message) throw $Message }
        Invoke-LabMenuAction -ActionName PersistentFixture
        if ($script:fixturePlans.Count -ne 0) { throw 'DECLINED_RETRIEVAL_EXECUTED' }
        Invoke-LabMenuAction -ActionName PersistentFixture
        $plan = $script:fixturePlans[0]
        if ($script:fixturePlans.Count -ne 1 -or $plan.RunId -ne $runId -or $plan.CollectionId -ne $collection -or
            $plan.Revision -ne 'Delta' -or $plan.DatasetMode -ne 'Fixture' -or -not $plan.Resume) {
            throw 'GUIDED_RETRIEVAL_BINDING_MISMATCH'
        }
        $command = Get-LabPublicCommandWebCatalog | Where-Object Name -ceq 'Invoke-SqlServerLabAiPersistentRetrieval'
        $arguments = @{CommandName=$command.Name;ParameterSetName=$command.ParameterSets[0].Name;Confirmed=$true
            Parameters=@{RunId=$runId; InstanceId='primary'; CollectionId=$collection; Action='Query'; QueryId='backup'}}
        $null = Invoke-LabPublicCommandWebRequest @arguments
        if ($script:fixturePlans.Count -ne 2 -or $script:fixturePlans[1].DatasetMode -ne 'Fixture' -or
            $script:fixturePlans[1].QueryId -ne 'backup' -or $script:fixturePlans[1].Resume) { throw 'WEB_RETRIEVAL_BINDING_MISMATCH' }
        Invoke-LabMenuAction -ActionName PersistentFixture
        if ($script:fixturePlans.Count -ne 3 -or $script:fixturePlans[2].Action -cne 'Prune' -or
            $script:fixturePlans[2].KeepGenerations -ne 3 -or $script:fixturePlans[2].CollectionId -cne $collection) { throw 'GUIDED_PRUNE_BINDING_MISMATCH' }
        Invoke-LabMenuAction -ActionName PersistentFixture
        if ($script:fixturePlans.Count -ne 3) { throw 'DECLINED_REMOVE_EXECUTED' }
        Invoke-LabMenuAction -ActionName PersistentFixture
        if ($script:fixturePlans.Count -ne 4 -or $script:fixturePlans[3].Action -cne 'Remove' -or
            $script:fixturePlans[3].RunId -cne $runId -or $script:fixturePlans[3].CollectionId -cne $collection) { throw 'GUIDED_REMOVE_BINDING_MISMATCH' }
        $arguments.Parameters.Action = 'Prune'
        $arguments.Parameters.Remove('QueryId')
        $arguments.Parameters.KeepGenerations = 3
        $arguments.Confirmed = $false
        try { $null = Invoke-LabPublicCommandWebRequest @arguments; throw 'UNCONFIRMED_WEB_PRUNE_EXECUTED' }
        catch { if ($_.Exception.Message -cne 'PUBLIC_COMMAND_UI_CONFIRMATION_REQUIRED') { throw } }
        if ($script:fixturePlans.Count -ne 4) { throw 'UNCONFIRMED_WEB_PRUNE_DISPATCHED' }
        $arguments.Confirmed = $true
        $null = Invoke-LabPublicCommandWebRequest @arguments
        if ($script:fixturePlans.Count -ne 5 -or $script:fixturePlans[4].Action -cne 'Prune' -or
            $script:fixturePlans[4].KeepGenerations -ne 3 -or $script:fixturePlans[4].CollectionId -cne $collection) { throw 'WEB_PRUNE_BINDING_MISMATCH' }
        Invoke-LabMenuAction -ActionName PersistentFixture
        $sync = $script:fixturePlans[5]
        if ($script:fixturePlans.Count -ne 6 -or $decisions.Count -or $sync.Action -cne 'Sync' -or
            $sync.DatasetMode -cne 'CallerSupplied' -or $sync.ExpectedDocuments[0].Content -cne 'Synthetic old' -or
            $sync.Documents[0].Content -cne 'Synthetic new' -or $sync.CollectionId -cne $collection) { throw 'GUIDED_SYNC_BINDING_MISMATCH' }
        $arguments.Parameters.Remove('KeepGenerations')
        $arguments.Parameters.Action = 'Sync'
        $webDocuments = [IO.File]::ReadAllText($documentFile) | ConvertFrom-Json -AsHashtable
        $arguments.Parameters.Documents = $webDocuments.Documents
        $arguments.Parameters.ExpectedDocuments = $webDocuments.ExpectedDocuments
        $null = Invoke-LabPublicCommandWebRequest @arguments
        if ($script:fixturePlans.Count -ne 7 -or $script:fixturePlans[6].PlanKey -cne $sync.PlanKey -or
            $script:fixturePlans[6].ExpectedPlanKey -cne $sync.ExpectedPlanKey) { throw 'WEB_SYNC_BINDING_MISMATCH' }
        [IO.File]::WriteAllText($documentFile, '{"RunId":"unbound","Documents":[{"Id":"sample-doc","Content":"Synthetic input"}]}')
        try { $null = Read-LabAiPersistentDocumentsInteractive -Action Apply; throw 'UNEXPECTED_DOCUMENT_FIELDS_ACCEPTED' }
        catch { if ($_.Exception.Message -cne 'AI_PERSISTENT_DOCUMENT_FILE_INVALID') { throw } }
        Write-Host 'PASS: Geführte Retrieval-Schritte binden Run und Collection-ID und starten nur nach Bestätigung.'
    }
    finally {
        [IO.File]::Delete($documentFile)
        Set-Item Function:script:Invoke-LabAiPersistentRetrieval $originalRuntime
        Remove-Variable -Scope Script -Name fixturePlans
    }
}
