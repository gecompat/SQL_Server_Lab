param([Parameter(Mandatory)]$Module)

$ErrorActionPreference = 'Stop'
& $Module {
    $originalCore = ${function:Invoke-LabRelationalCoreComparison}
    $script:guidedComparisonCalls = [Collections.Generic.List[object]]::new()
    try {
        function script:Invoke-LabRelationalCoreComparison {
            param($ComparisonPair, $StateRoot)
            $script:guidedComparisonCalls.Add($ComparisonPair)
            [pscustomobject]@{ Pairs = @([pscustomobject]@{Status='MATCH'; TablesCompared=1; RowsCompared=3; Findings=@()}) }
        }
        $source = [pscustomobject]@{ RunId = '11111111-1111-1111-1111-111111111111'; InstanceId = 'primary'; Label = 'Docker' }
        $target = [pscustomobject]@{ RunId = '22222222-2222-2222-2222-222222222222'; InstanceId = 'other'; Label = 'Podman' }
        & {
            function Get-LabStateRoot { $PSScriptRoot }
            function Get-LabActiveRuns {
                param($StateRoot, [switch]$NoWrite)
                if (-not $NoWrite) { throw 'DISCOVERY_MUST_NOT_WRITE' }
                [pscustomobject]@{ state='RUNNING'; runId=$source.RunId; metadata=@{name='Docker'} }
                [pscustomobject]@{ state='STOPPED'; runId=$target.RunId; metadata=@{name='Podman'} }
                [pscustomobject]@{ state='RUNNING'; runId='bad-id'; metadata=@{name='invalid'} }
            }
            function Get-Content {
                [CmdletBinding()] param($LiteralPath, [switch]$Raw, $Encoding)
                if ($LiteralPath -notlike "*/$($source.RunId)/connection-info.json" -and
                    $LiteralPath -notlike "*\$($source.RunId)\connection-info.json") { throw 'UNEXPECTED_CATALOG_PATH' }
                '{"instances":[{"id":"primary","provider":"docker"},{"id":"dup","provider":"podman"},{"id":"dup","provider":"podman"},{"id":"guest","provider":"hyperv"}]}'
            }
            $visible = @(Get-LabRelationalComparisonConsoleTargets)
            if ($visible.Count -ne 1 -or $visible[0].InstanceId -ne 'primary') { throw 'GUIDED_COMPARISON_DISCOVERY_INVALID' }
            Write-Host 'PASS: Die Instanzauswahl liest nur gültige laufende Container-Runs und blendet doppelte IDs aus.'
        }
        function Get-LabRelationalComparisonConsoleTargets { $source; $target }
        function Select-LabConsoleDataItem {
            param($ScreenId, $Title, $Items)
            if ($ScreenId -ceq 'relational-compare-Source' -and $Items.Count -eq 2) { return $Items[0].Data }
            if ($ScreenId -ceq 'relational-compare-Target' -and $Items.Count -eq 1 -and $Items[0].Data.RunId -eq $target.RunId) { return $Items[0].Data }
            throw 'UNEXPECTED_SELECTION'
        }
        $inputValues = [Collections.Generic.Queue[string]]::new()
        function Read-LabConsoleTextInput { param($Prompt) [pscustomobject]@{Status='Confirmed'; Value=$inputValues.Dequeue()} }
        $decisions = [Collections.Generic.Queue[bool]]::new()
        function Read-LabConfirm { param($Prompt, $Default) if ($Default) { throw 'UNSAFE_DEFAULT' }; $decisions.Dequeue() }
        function Write-LabError { param($Message) if ($Message -notmatch 'Unterstriche') { throw $Message } }
        function Wait-LabConsoleAcknowledgement { $null }
        foreach ($value in @('Bad-Name', 'SrcDb', 'DstDb', 'SrcDb', 'DstDb')) { $inputValues.Enqueue($value) }
        $decisions.Enqueue($false); $decisions.Enqueue($true)
        Invoke-LabRelationalComparisonInteractive
        if ($script:guidedComparisonCalls.Count -ne 0) { throw 'DECLINED_COMPARISON_EXECUTED' }
        Invoke-LabMenuAction -ActionName 'RelationalCompare'
        if ($script:guidedComparisonCalls.Count -ne 1 -or $inputValues.Count -ne 0) { throw 'GUIDED_COMPARISON_NOT_EXECUTED' }
        $pair = $script:guidedComparisonCalls[0][0]
        if ($pair.SourceRunId -ne $source.RunId -or $pair.TargetRunId -ne $target.RunId -or
            $pair.SourceDatabaseName -ne 'SrcDb' -or $pair.TargetDatabaseName -ne 'DstDb') { throw 'GUIDED_COMPARISON_WRONG_PAIR' }
        $command = Get-LabPublicCommandWebCatalog | Where-Object Name -ceq 'Test-SqlServerLabRelationalCoreComparison'
        $json = @{ComparisonPair=@($pair)} | ConvertTo-Json -Depth 5 | ConvertFrom-Json -Depth 5
        $receipt = Invoke-LabPublicCommandWebRequest -CommandName $command.Name -ParameterSetName $command.ParameterSets[0].Name -Parameters @{ComparisonPair=$json.ComparisonPair} -Confirmed
        if ($script:guidedComparisonCalls.Count -ne 2 -or $receipt.Result[0].Pairs[0].Status -ne 'MATCH') { throw 'BROWSER_COMPARISON_MAPPING_FAILED' }
        Write-Host 'PASS: CLI- und Browser-Katalog binden dasselbe synthetische Datenbankpaar.'
    }
    finally {
        Set-Item Function:script:Invoke-LabRelationalCoreComparison $originalCore
        Remove-Variable -Name guidedComparisonCalls -Scope Script
    }
}
