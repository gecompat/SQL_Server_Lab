param([Parameter(Mandatory)]$Module, [Parameter(Mandatory)][string]$Repository)

$ErrorActionPreference = 'Stop'
& $Module {
    param($Repo)
    $original = ${function:Get-LabAiComputeBenchmarkOptions}
    $candidate = [pscustomobject]@{CandidateId='cpu';Backend='LlamaCppCpu';RuntimeSha256=('a'*64);Eligible=$true;Devices=@([pscustomobject]@{DeviceId='cpu0'})}
    $options = [pscustomobject]@{
        ModelPath='C:/Synthetic/model.gguf'; Inventory=[pscustomobject]@{Status='COMPLETE'}
        CandidateSet=[pscustomobject]@{Candidates=@($candidate)}
        Packages=@([pscustomobject]@{RuntimeSha256=('a'*64);Directory='C:/Synthetic/llama'})
    }
    $trace = [Collections.Generic.List[object]]::new()
    function Get-LabAiComputeBenchmarkOptions { param($ModelPath) $trace.Add(@{Plan=$ModelPath}); $options }
    function Get-LabAiComputeBenchmarkModel { param($ModelPath) [pscustomobject]@{Name='model.gguf';FullName=$ModelPath} }
    function Read-LabConsoleTextInput { param($Prompt) [pscustomobject]@{Status='Confirmed';Value='C:/Synthetic/model.gguf'} }
    $benchmarkMenuChoices = [Collections.Generic.Queue[string]]::new()
    function Select-LabConsoleDataItem { param($ScreenId,$Title,$Items) $id = $benchmarkMenuChoices.Dequeue(); ($Items | Where-Object Id -ceq $id).Data }
    $decisions = [Collections.Generic.Queue[bool]]::new()
    function Read-LabConfirm { param($Prompt,$Default) if ($Default) {throw 'UNSAFE_DEFAULT'}; $decisions.Dequeue() }
    function Wait-LabConsoleAcknowledgement { $null }
    function Write-LabError { param($Message) throw $Message }
    function Measure-SqlServerLabAiComputeCandidate {
        [CmdletBinding(SupportsShouldProcess)] param($Inventory,$ModelPath,$BenchmarkMode,$WorkloadKey,$RuntimeDirectory,$Candidate)
        $trace.Add(@{Measure='single';Mode=$BenchmarkMode;Workload=$WorkloadKey;Package=$RuntimeDirectory;Candidate=$Candidate.CandidateId})
        [pscustomobject]@{CandidateId=$Candidate.CandidateId;ThroughputPerSecond=12;P95LatencyMilliseconds=10}
    }
    function Measure-SqlServerLabAiComputeCandidateSet {
        [CmdletBinding(SupportsShouldProcess)] param($Inventory,$ModelPath,$BenchmarkMode,$WorkloadKey,$RuntimeDirectory,$Candidate)
        $trace.Add(@{Measure='set';Mode=$BenchmarkMode;Workload=$WorkloadKey;Packages=@($RuntimeDirectory);Candidates=@($Candidate)})
        [pscustomobject]@{Selection=[pscustomobject]@{CandidateId='cpu';Backend='LlamaCppCpu'};Benchmarks=@(1)}
    }
    foreach ($choice in @('candidate-cpu','embedding','candidate-cpu','embedding','all','generation')) { $benchmarkMenuChoices.Enqueue($choice) }
    $decisions.Enqueue($false);$decisions.Enqueue($true);$decisions.Enqueue($true)
    Invoke-LabMenuAction -ActionName AiComputeBenchmark
    if (@($trace | Where-Object Measure).Count) { throw 'DECLINED_BENCHMARK_EXECUTED' }
    Invoke-LabMenuAction -ActionName AiComputeBenchmark
    Invoke-LabMenuAction -ActionName AiComputeBenchmark
    $measurements = @($trace | Where-Object Measure)
    if ($measurements.Count -ne 2 -or $measurements[0].Candidate -ne 'cpu' -or $measurements[0].Workload -ne 'sql-ai-embedding' -or
        $measurements[0].Package -ne 'C:/Synthetic/llama' -or $measurements[1].Measure -ne 'set' -or
        $measurements[1].Candidates.Count -ne 1 -or $measurements[1].Workload -ne 'sql-ai-generation') { throw 'GUIDED_BENCHMARK_MAPPING_FAILED' }

    $tokens = $null; $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $Repo 'Tools/Start-SqlServerLabUi.ps1'), [ref]$tokens, [ref]$parseErrors)
    $route = $ast.Find({param($node) $node -is [Management.Automation.Language.IfStatementAst] -and
        $node.Clauses[0].Item1.Extent.Text -ceq '$path -ceq ''/api/ai-compute-benchmark-options'''}, $true)
    if ($parseErrors.Count -or -not $route) { throw 'GUIDED_BENCHMARK_ROUTE_MISSING' }
    $routeScript = [scriptblock]::Create('foreach ($once in @(1)) ' + $route.Clauses[0].Item2.Extent.Text)
    $context = [pscustomobject]@{ Request = [pscustomobject]@{HttpMethod='POST';HasEntityBody=$true;Url=[uri]'http://127.0.0.1:39000/api/ai-compute-benchmark-options'} }
    $responses = [Collections.Generic.List[object]]::new()
    function Write-UiResponse { param($Context,$Body,$ContentType,$StatusCode=200) $responses.Add(@{Status=$StatusCode;Body=$Body}) }
    $inputs = [Collections.Generic.Queue[string]]::new()
    foreach ($value in @('{"ModelPath":"other","ModelPath":"C:/Synthetic/model.gguf"}','{"ModelPath":"C:/Synthetic/model.gguf"}')) { $inputs.Enqueue($value) }
    function Read-UiJsonRequestBody { param($Request,$MaxBytes) [pscustomobject]@{Allowed=$true;Body=$inputs.Dequeue()} }
    $script:guidedBenchmarkTestOptions = $options
    try {
        function script:Get-LabAiComputeBenchmarkOptions {
            param($ModelPath)
            if ($ModelPath -ne 'C:/Synthetic/model.gguf') { throw 'MODEL_MAPPING_FAILED' }
            $script:guidedBenchmarkTestOptions
        }
        & $routeScript
        & $routeScript
        if ($responses.Count -ne 2 -or $responses[0].Status -ne 400 -or $responses[1].Status -ne 200 -or
            ($responses[1].Body | ConvertFrom-Json).ModelPath -ne 'C:/Synthetic/model.gguf') { throw 'WEB_BENCHMARK_OPTIONS_FAILED' }
    }
    finally {
        Set-Item Function:script:Get-LabAiComputeBenchmarkOptions $original
        Remove-Variable -Scope Script -Name guidedBenchmarkTestOptions
    }
    Write-Host 'PASS: Einzel- und Satzmessung sind gebunden; die Optionsprüfung startet keine Ausführung.'
} $Repository
