param([Parameter(Mandatory)]$Module)

$ErrorActionPreference='Stop'
& $Module {
    $originalRuntime = ${function:Invoke-LabAiPersistentRetrieval}
    $script:fixturePlans = [Collections.Generic.List[object]]::new()
    try {
        function script:Invoke-LabAiPersistentRetrieval {
            param($Plan,$StateRoot)
            $script:fixturePlans.Add($Plan)
            [pscustomobject]@{Status='COMMITTED';Generation=$Plan.Generation;EmbeddingRequests=0}
        }
        $runId = '11111111-1111-1111-1111-111111111111'
        $collection = '22222222-2222-2222-2222-222222222222'
        function Get-LabContainerSqlConsoleTargets {
            [pscustomobject]@{RunId=$runId;InstanceId='primary';Label='Synthetic SQL';Provider='docker';SqlVersion='2025-CU9'}
            [pscustomobject]@{RunId=$collection;InstanceId='legacy';Label='Legacy SQL';Provider='podman';SqlVersion='2022'}
        }
        function Select-LabConsoleDataItem {
            param($ScreenId,$Title,$Items)
            if ($ScreenId -ceq 'persistent-fixture-target' -and $Items.Count -eq 1) { return $Items[0].Data }
            if ($ScreenId -ceq 'persistent-fixture-action' -and @($Items.Id) -cnotcontains 'remove') {
                return ($Items | Where-Object Id -ceq 'delta').Data
            }
            throw 'UNEXPECTED_SELECTION'
        }
        function Read-LabConsoleTextInput { param($Prompt,$Default) [pscustomobject]@{Status='Confirmed';Value=$collection} }
        $decisions = [Collections.Generic.Queue[bool]]::new()
        foreach ($decision in @($false, $false, $true, $true)) { $decisions.Enqueue($decision) }
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
        Write-Host 'PASS: Geführtes Retrieval bindet die synthetische Collection und startet nur nach Bestätigung.'
    }
    finally {
        Set-Item Function:script:Invoke-LabAiPersistentRetrieval $originalRuntime
        Remove-Variable -Scope Script -Name fixturePlans
    }
}
