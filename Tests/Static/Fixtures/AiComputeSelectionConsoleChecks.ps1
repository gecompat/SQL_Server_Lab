param([Parameter(Mandatory)]$Module, [Parameter(Mandatory)]$CandidateSet, [Parameter(Mandatory)]$BenchmarkSet)

$ErrorActionPreference = 'Stop'
& $Module {
    param($Candidates, $Benchmarks)
    $receipts = [Collections.Generic.Queue[object]]::new()
    function Read-LabAiComputeReceiptInteractive { param($Prompt) $receipts.Dequeue() }
    function Select-LabConsoleDataItem { param($ScreenId,$Title,$Items) ($Items | Where-Object Id -ceq 'candidate-cpu').Data }
    function Wait-LabConsoleAcknowledgement { $null }
    function Write-LabError { param($Message) throw $Message }
    $receipts.Enqueue($Candidates); $receipts.Enqueue($Benchmarks)
    $output = @(Invoke-LabMenuAction -ActionName AiComputeSelection 6>&1) -join "`n"
    if ($output -notmatch 'Auswahl: cpu.*Modus: PINNED' -or $output -notmatch 'Belegschlüssel: [a-f0-9]{64}') {
        throw 'GUIDED_COMPUTE_SELECTION_INVALID'
    }
    $command = Get-LabPublicCommandWebCatalog | Where-Object Name -ceq 'Get-SqlServerLabAiComputeSelection'
    $browserArgs = @{CommandName=$command.Name;ParameterSetName='Auto';Confirmed=$true;Parameters=@{
        Candidate=$Candidates.Candidates; InventorySha256=$Candidates.InventorySha256; Benchmark=$Benchmarks.Benchmarks
        WorkloadKey=$Benchmarks.Selection.WorkloadKey; ModelSha256=$Benchmarks.Selection.ModelSha256
        BenchmarkProfileSha256=$Benchmarks.Selection.BenchmarkProfileSha256
    }}
    $result = Invoke-LabPublicCommandWebRequest @browserArgs
    if ($result.Result[0].SelectionMode -ne 'AUTO_FASTEST' -or $result.Result[0].CandidateId -ne 'npu') {
        throw 'WEB_COMPUTE_SELECTION_INVALID'
    }
    Write-Host 'PASS: Geführte Auswahl berechnet Auto und Pinned mit den öffentlichen Vertragseingaben.'
} $CandidateSet $BenchmarkSet
