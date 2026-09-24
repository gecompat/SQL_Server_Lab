#Requires -Version 7.2
[CmdletBinding()]param()
$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
. (Join-Path $PSScriptRoot '../Common/CheckResult.ps1')
$failures=[Collections.Generic.List[string]]::new();$passed=0
$module=Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru
try {
    $model='a'*64;$profile='b'*64;$inventory='c'*64
    function Device($kind,$id){[pscustomobject]@{Kind=$kind;DeviceId=$id}}
    function Candidate($id,$backend,$runtime,$devices,$eligible=$true,$blockers=@()){
        [pscustomobject]@{CandidateId=$id;Backend=$backend;RuntimeSha256=$runtime;Devices=@($devices);Eligible=$eligible;Blockers=@($blockers)}
    }
    function Benchmark($candidate,$runtime,$throughput,$latency,$memory,$success=5,$total=5){
        [pscustomobject]@{Contract='SqlServerLab.AiComputeBenchmark/1.0';CandidateId=$candidate;WorkloadKey='sql-ai-generation';ModelSha256=$model;BenchmarkProfileSha256=$profile;InventorySha256=$inventory;RuntimeSha256=$runtime;ThroughputPerSecond=$throughput;P95LatencyMilliseconds=$latency;PeakWorkingSetBytes=$memory;SuccessfulIterations=$success;TotalIterations=$total;EvidenceStatus='BENCHMARK_VERIFIED'}
    }
    function Reject([scriptblock]$action,[string]$pattern){try{& $action|Out-Null;$false}catch{$_.Exception.Message -like $pattern}}
    $cpu=Candidate cpu LlamaCppOpenVino ('1'*64) (Device CPU cpu0)
    $npu=Candidate npu LlamaCppOpenVino ('2'*64) (Device NPU npu0)
    $multi=Candidate cuda-multi LlamaCppCuda ('3'*64) @((Device CPU cpu0),(Device GPU cuda0),(Device GPU cuda1))
    $blocked=Candidate unsupported LlamaCppCuda ('4'*64) (Device NPU npu0) $false @('AI_COMPUTE_BACKEND_DEVICE_UNSUPPORTED')
    $cpuBench=Benchmark cpu ('1'*64) 12 80 1000
    $npuBench=Benchmark npu ('2'*64) 18 55 800
    $multiBench=Benchmark cuda-multi ('3'*64) 42 35 5000
    $selection=Get-SqlServerLabAiComputeSelection -WorkloadKey sql-ai-generation -ModelSha256 $model -BenchmarkProfileSha256 $profile -InventorySha256 $inventory -Candidate @($blocked,$npu,$cpu,$multi) -Benchmark @($npuBench,$multiBench,$cpuBench)
    Add-CheckResult 'Auto ist Standard und wählt höchsten Durchsatz aus vollständiger Evidence' ($selection.SelectionMode -ceq 'AUTO_FASTEST' -and $selection.CandidateId -ceq 'cuda-multi' -and $selection.SelectedBenchmark.ThroughputPerSecond -eq 42)
    Add-CheckResult 'Mehr-GPU- und gemischter Gerätesatz bleibt vollständig gebunden' ($selection.Devices.Count -eq 3 -and @($selection.Devices|Where-Object Kind -eq GPU).Count -eq 2 -and @($selection.Devices|Where-Object Kind -eq CPU).Count -eq 1)
    Add-CheckResult 'Ungeeignete Option wird mit Blocker sichtbar ausgeschlossen' ($selection.ExcludedCandidates.Count -eq 1 -and $selection.ExcludedCandidates[0].CandidateId -ceq 'unsupported')
    Add-CheckResult 'Auswahlreceipt entspricht Schema' (($selection|ConvertTo-Json -Depth 20) | Test-Json -SchemaFile (Join-Path $repoRoot 'Schemas/ai-compute-selection.schema.json'))
    $reordered=Get-SqlServerLabAiComputeSelection -WorkloadKey sql-ai-generation -ModelSha256 $model -BenchmarkProfileSha256 $profile -InventorySha256 $inventory -Candidate @($multi,$cpu,$npu,$blocked) -Benchmark @($cpuBench,$npuBench,$multiBench)
    Add-CheckResult 'Eingabereihenfolge ändert weder Sieger noch SelectionKey' ($reordered.CandidateId -ceq $selection.CandidateId -and $reordered.SelectionKey -ceq $selection.SelectionKey)
    $pinned=Get-SqlServerLabAiComputeSelection -WorkloadKey sql-ai-generation -ModelSha256 $model -BenchmarkProfileSha256 $profile -InventorySha256 $inventory -Candidate @($cpu,$npu,$multi,$blocked) -PinnedCandidateId npu
    Add-CheckResult 'Explizite Fixierung überschreibt Auto ohne Benchmarkpflicht' ($pinned.SelectionMode -ceq 'PINNED' -and $pinned.CandidateId -ceq 'npu' -and $null -eq $pinned.SelectedBenchmark -and $pinned.RankedCandidates.Count -eq 0)
    Add-CheckResult 'Fixierung auf ungeeignete Option fällt geschlossen aus' (Reject {Get-SqlServerLabAiComputeSelection -WorkloadKey sql-ai-generation -ModelSha256 $model -BenchmarkProfileSha256 $profile -InventorySha256 $inventory -Candidate @($cpu,$blocked) -PinnedCandidateId unsupported} 'AI_COMPUTE_PINNED_CANDIDATE_INELIGIBLE*')
    Add-CheckResult 'Auto blockiert unvollständige Benchmarkabdeckung' (Reject {Get-SqlServerLabAiComputeSelection -WorkloadKey sql-ai-generation -ModelSha256 $model -BenchmarkProfileSha256 $profile -InventorySha256 $inventory -Candidate @($cpu,$npu,$multi) -Benchmark @($cpuBench,$multiBench)} 'AI_COMPUTE_BENCHMARK_COVERAGE_INCOMPLETE: npu')
    $mismatch=$npuBench|ConvertTo-Json|ConvertFrom-Json;$mismatch.WorkloadKey='other'
    Add-CheckResult 'Nicht vergleichbare Workloadbindung wird abgewiesen' (Reject {Get-SqlServerLabAiComputeSelection -WorkloadKey sql-ai-generation -ModelSha256 $model -BenchmarkProfileSha256 $profile -InventorySha256 $inventory -Candidate @($npu) -Benchmark @($mismatch)} 'AI_COMPUTE_BENCHMARK_BINDING_MISMATCH*')
    $inventoryMismatch=$npuBench|ConvertTo-Json|ConvertFrom-Json;$inventoryMismatch.InventorySha256='d'*64
    Add-CheckResult 'Benchmark eines anderen Hardwarebestands wird abgewiesen' (Reject {Get-SqlServerLabAiComputeSelection -WorkloadKey sql-ai-generation -ModelSha256 $model -BenchmarkProfileSha256 $profile -InventorySha256 $inventory -Candidate @($npu) -Benchmark @($inventoryMismatch)} 'AI_COMPUTE_BENCHMARK_BINDING_MISMATCH*')
    Add-CheckResult 'Doppelter Benchmark wird abgewiesen' (Reject {Get-SqlServerLabAiComputeSelection -WorkloadKey sql-ai-generation -ModelSha256 $model -BenchmarkProfileSha256 $profile -InventorySha256 $inventory -Candidate @($cpu) -Benchmark @($cpuBench,$cpuBench)} 'AI_COMPUTE_BENCHMARK_DUPLICATE*')
    $failed=Benchmark cpu ('1'*64) 12 80 1000 4 5
    Add-CheckResult 'Teilweise fehlgeschlagener Benchmark ist keine Auswahl-Evidence' (Reject {Get-SqlServerLabAiComputeSelection -WorkloadKey sql-ai-generation -ModelSha256 $model -BenchmarkProfileSha256 $profile -InventorySha256 $inventory -Candidate @($cpu) -Benchmark @($failed)} 'AI_COMPUTE_BENCHMARK_INVALID*')
    $nan=Benchmark cpu ('1'*64) ([double]::NaN) 80 1000
    Add-CheckResult 'Nicht endlicher Durchsatz wird abgewiesen' (Reject {Get-SqlServerLabAiComputeSelection -WorkloadKey sql-ai-generation -ModelSha256 $model -BenchmarkProfileSha256 $profile -InventorySha256 $inventory -Candidate @($cpu) -Benchmark @($nan)} 'AI_COMPUTE_BENCHMARK_INVALID*')
    $textNumber=Benchmark cpu ('1'*64) '12' 80 1000
    Add-CheckResult 'Text statt numerischem Durchsatz wird abgewiesen' (Reject {Get-SqlServerLabAiComputeSelection -WorkloadKey sql-ai-generation -ModelSha256 $model -BenchmarkProfileSha256 $profile -InventorySha256 $inventory -Candidate @($cpu) -Benchmark @($textNumber)} 'AI_COMPUTE_BENCHMARK_INVALID*')
    $fractional=Benchmark cpu ('1'*64) 12 80 1.5
    Add-CheckResult 'Nicht ganzzahliger Speicherwert wird abgewiesen' (Reject {Get-SqlServerLabAiComputeSelection -WorkloadKey sql-ai-generation -ModelSha256 $model -BenchmarkProfileSha256 $profile -InventorySha256 $inventory -Candidate @($cpu) -Benchmark @($fractional)} 'AI_COMPUTE_BENCHMARK_INVALID*')
    $duplicateDevice=Candidate bad-devices LlamaCppCuda ('5'*64) @((Device GPU cuda0),(Device GPU CUDA0))
    Add-CheckResult 'Doppelte Geräte-ID im Kandidaten wird abgewiesen' (Reject {Get-SqlServerLabAiComputeSelection -WorkloadKey sql-ai-generation -ModelSha256 $model -BenchmarkProfileSha256 $profile -InventorySha256 $inventory -Candidate @($duplicateDevice) -PinnedCandidateId bad-devices} 'AI_COMPUTE_DEVICE_INVALID')
    $cpuAlias=Candidate cpu-alias LlamaCppOpenVino ('1'*64) (Device CPU CPU0)
    Add-CheckResult 'Doppelte Backend-/Runtime-/Gerätekombination wird unabhängig von Großschreibung abgewiesen' (Reject {Get-SqlServerLabAiComputeSelection -WorkloadKey sql-ai-generation -ModelSha256 $model -BenchmarkProfileSha256 $profile -InventorySha256 $inventory -Candidate @($cpu,$cpuAlias) -PinnedCandidateId cpu} 'AI_COMPUTE_CANDIDATE_DUPLICATE')
    $cpuOtherRuntime=Candidate cpu-other LlamaCppOpenVino ('8'*64) (Device CPU CPU0)
    $runtimeVariant=Get-SqlServerLabAiComputeSelection -WorkloadKey sql-ai-generation -ModelSha256 $model -BenchmarkProfileSha256 $profile -InventorySha256 $inventory -Candidate @($cpu,$cpuOtherRuntime) -PinnedCandidateId cpu-other
    Add-CheckResult 'Unterschiedliche Runtimehashes dürfen dieselbe Backend-Gerätekombination vergleichen' ($runtimeVariant.CandidateId -ceq 'cpu-other')
    $extra=$cpu|ConvertTo-Json -Depth 5|ConvertFrom-Json;$extra|Add-Member Surprise value
    Add-CheckResult 'Unbekanntes Kandidatenfeld wird abgewiesen' (Reject {Get-SqlServerLabAiComputeSelection -WorkloadKey sql-ai-generation -ModelSha256 $model -BenchmarkProfileSha256 $profile -InventorySha256 $inventory -Candidate @($extra) -PinnedCandidateId cpu} 'AI_COMPUTE_CANDIDATE_INVALID')
    $tieA=Candidate tie-a LlamaCppCuda ('6'*64) (Device GPU cuda2);$tieB=Candidate tie-b LlamaCppRocm ('7'*64) (Device GPU rocm0)
    $tieABench=Benchmark tie-a ('6'*64) 20 40 2000;$tieBBench=Benchmark tie-b ('7'*64) 20 35 3000
    $tie=Get-SqlServerLabAiComputeSelection -WorkloadKey sql-ai-generation -ModelSha256 $model -BenchmarkProfileSha256 $profile -InventorySha256 $inventory -Candidate @($tieA,$tieB) -Benchmark @($tieABench,$tieBBench)
    Add-CheckResult 'P95-Latenz entscheidet deterministisch bei gleichem Durchsatz' ($tie.CandidateId -ceq 'tie-b')
    Add-CheckResult 'Öffentlicher Befehl ist manifestexportiert' ((Get-Command Get-SqlServerLabAiComputeSelection).Source -ceq 'SqlServerLab')
}
finally {Remove-Module $module -Force}
if($failures.Count){throw ($failures -join '; ')}
Write-Host "AI COMPUTE SELECTION CONTRACT: PASS ($passed)"
