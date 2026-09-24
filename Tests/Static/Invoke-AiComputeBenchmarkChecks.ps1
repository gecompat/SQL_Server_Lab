#Requires -Version 7.2
[CmdletBinding()]param()
$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
. (Join-Path $PSScriptRoot '../Common/CheckResult.ps1')
$failures=[Collections.Generic.List[string]]::new();$passed=0
$module=Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-ai-benchmark-'+[guid]::NewGuid().ToString('N'))
try {
    function Coverage($kind){[pscustomobject]@{Kind=$kind;Status='VERIFIED';Method=('TEST_'+$kind)}}
    function Device($kind,$source,$vendor,$product,$name){[pscustomobject]@{Kind=$kind;SourceId=$source;VendorId=$vendor;ProductId=$product;DisplayName=$name}}
    function Reject([scriptblock]$action,[string]$pattern){try{& $action|Out-Null;$false}catch{$_.Exception.Message -like $pattern}}
    $probe=[pscustomobject]@{Platform='Windows';Coverage=@((Coverage CPU),(Coverage GPU),(Coverage NPU));Devices=@(
        (Device CPU cpu0 8086 cpu 'Intel CPU'),(Device GPU gpu0 10de nvidia 'NVIDIA GPU 0'),(Device GPU gpu1 10de nvidia 'NVIDIA GPU 1')
    )}
    $inventory=& $module {param($p)Get-LabAiComputeInventory -ProbeResult $p} $probe
    $package=Join-Path $fixture 'llama-b300-bin-cuda';$null=New-Item -ItemType Directory -Path $package -Force
    foreach($name in @('llama-server.exe','llama-bench.exe','ggml-cuda.dll')){[IO.File]::WriteAllText((Join-Path $package $name),('synthetic-'+$name))}
    $model=Join-Path $fixture 'model.gguf';[IO.File]::WriteAllText($model,'GGUFsynthetic-model')
    $runtime=@(Get-SqlServerLabLlamaCppRuntime -SearchRoot $package)[0]
    $capabilities=Get-SqlServerLabAiRuntimeCapability -Inventory $inventory -Runtime $runtime
    $candidateSet=Get-SqlServerLabAiComputeCandidate -Inventory $inventory -RuntimeCapability $capabilities.Capabilities
    $receipts=[Collections.Generic.List[object]]::new()
    foreach($candidate in @($candidateSet.Candidates|Where-Object Eligible)){
        $bindings=[Collections.Generic.List[object]]::new();$gpuOrdinal=0
        foreach($device in $candidate.Devices){
            $selector=if($device.Kind -eq 'CPU'){'none'}else{'CUDA'+$gpuOrdinal;$gpuOrdinal++}
            $bindings.Add([pscustomobject]@{DeviceId=$device.DeviceId;RuntimeSelector=$selector})
        }
        $runner={
            param($invocation,$arguments,$environment,$timeout)
            $device=$arguments[$arguments.IndexOf('-dev')+1]
            $generated=[int]$arguments[$arguments.IndexOf('-n')+1]
            $repetitions=[int]$arguments[$arguments.IndexOf('-r')+1]
            $throughput=if($device -like '*/*'){40}elseif($device -eq 'none'){10}else{20}
            $samples=@(1..$repetitions|ForEach-Object {100000000+($_*1000000)})
            $record=[ordered]@{backends=if($device -eq 'none'){'CPU'}else{'CUDA'};devices=$device;n_prompt=0;n_gen=$generated;avg_ts=$throughput;samples_ns=$samples;samples_ts=@(1..$repetitions|ForEach-Object {$throughput})}
            [pscustomobject]@{ExitCode=0;StdOut=($record|ConvertTo-Json -Compress);PeakWorkingSetBytes=4096}
        }
        $receipt=& $module {param($i,$c,$r,$m,$b,$run)Invoke-LabAiComputeBenchmark -Inventory $i -Candidate $c -RuntimeDirectory $r -ModelPath $m -WorkloadKey sql-ai-generation -DeviceBinding $b -ProcessRunner $run} $inventory $candidate $package $model @($bindings) $runner
        $receipts.Add($receipt)
    }
    Add-CheckResult 'Producer erzeugt vollständige CPU-, Einzel- und Mehr-GPU-Benchmarkreceipts' ($receipts.Count -eq 4 -and @($receipts|Where-Object EvidenceStatus -eq BENCHMARK_VERIFIED).Count -eq 4)
    Add-CheckResult 'Benchmarkreceipts entsprechen dem eigenständigen Schema' (@($receipts|Where-Object {-not ($_|ConvertTo-Json -Depth 10|Test-Json -SchemaFile (Join-Path $repoRoot 'Schemas/ai-compute-benchmark.schema.json'))}).Count -eq 0)
    Add-CheckResult 'Benchmarkprofil bleibt über alle Kandidaten identisch und Modell wird inhaltsgebunden' (@($receipts.BenchmarkProfileSha256|Sort-Object -Unique).Count -eq 1 -and @($receipts.ModelSha256|Sort-Object -Unique).Count -eq 1)
    Add-CheckResult 'P95-Latenz wird als Nearest-Rank aus den gebundenen Nanosekunden-Samples abgeleitet' (@($receipts|Where-Object {$_.P95LatencyMilliseconds -ne 105}).Count -eq 0)
    $multi=@($candidateSet.Candidates|Where-Object {$_.Backend -eq 'LlamaCppCuda' -and $_.Devices.Count -eq 2})[0]
    $autoRunner={
        param($invocation,$arguments,$environment,$timeout)
        if('--list-devices' -in $arguments){return [pscustomobject]@{ExitCode=0;StdOut="Available devices:`n  CUDA1: NVIDIA GPU 1 (NVIDIA) (16384 MiB, 16000 MiB free)`n  CUDA0: NVIDIA GPU 0 (NVIDIA) (16384 MiB, 16000 MiB free)";PeakWorkingSetBytes=1024}}
        & $runner $invocation $arguments $environment $timeout
    }
    $resolvedBindings=& $module {param($i,$c,$run)$v=Get-LabAiComputeSelection -WorkloadKey sql-ai-generation -ModelSha256 ('0'*64) -BenchmarkProfileSha256 ('0'*64) -InventorySha256 $i.InventorySha256 -Candidate @($c) -PinnedCandidateId $c.CandidateId;Resolve-LabAiRuntimeDeviceBinding -Inventory $i -Candidate $v -BenchmarkInvocation synthetic -TimeoutSeconds 5 -ProcessRunner $run} $inventory $multi $autoRunner
    Add-CheckResult 'Runtime-Geräteliste wird auf portable IDs abgebildet' (@($resolvedBindings).Count -eq 2)
    $autoReceipt=& $module {param($i,$c,$r,$m,$run)Invoke-LabAiComputeBenchmark -Inventory $i -Candidate $c -RuntimeDirectory $r -ModelPath $m -WorkloadKey sql-ai-generation -ProcessRunner $run} $inventory $multi $package $model $autoRunner
    Add-CheckResult 'Fehlende Gerätebindung wird eindeutig aus llama-bench --list-devices abgeleitet' ($autoReceipt.CandidateId -ceq $multi.CandidateId -and $autoReceipt.ThroughputPerSecond -eq 40)
    $selection=Get-SqlServerLabAiComputeSelection -WorkloadKey sql-ai-generation -ModelSha256 $receipts[0].ModelSha256 -BenchmarkProfileSha256 $receipts[0].BenchmarkProfileSha256 -InventorySha256 $inventory.InventorySha256 -Candidate $candidateSet.Candidates -Benchmark @($receipts)
    Add-CheckResult 'Auto-Auswahl übernimmt den vollständig benchmarkten Mehr-GPU-Sieger' ($selection.CandidateId -eq @($candidateSet.Candidates|Where-Object {$_.Devices.Count -eq 2})[0].CandidateId -and $selection.SelectedBenchmark.ThroughputPerSecond -eq 40)
    $cpu=@($candidateSet.Candidates|Where-Object Backend -eq LlamaCppCpu)[0]
    $secondaryPackage=Join-Path $fixture 'llama-b300-bin-cpu';$null=New-Item -ItemType Directory -Path $secondaryPackage
    foreach($name in @('llama-server.exe','llama-bench.exe')){[IO.File]::WriteAllText((Join-Path $secondaryPackage $name),('secondary-'+$name))}
    $secondaryRuntime=@(Get-SqlServerLabLlamaCppRuntime -SearchRoot $secondaryPackage)[0]
    $secondaryCapabilities=Get-SqlServerLabAiRuntimeCapability -Inventory $inventory -Runtime $secondaryRuntime
    $secondaryCandidates=Get-SqlServerLabAiComputeCandidate -Inventory $inventory -RuntimeCapability $secondaryCapabilities.Capabilities
    $secondaryCpu=@($secondaryCandidates.Candidates|Where-Object {$_.Eligible -and $_.Backend -eq 'LlamaCppCpu'})[0]
    $secondaryReceipt=@($receipts|Where-Object CandidateId -CEQ $cpu.CandidateId)[0]|ConvertTo-Json|ConvertFrom-Json
    $secondaryReceipt.CandidateId=$secondaryCpu.CandidateId;$secondaryReceipt.RuntimeSha256=$secondaryCpu.RuntimeSha256
    $setCandidates=@($candidateSet.Candidates)+@($secondaryCandidates.Candidates);$setReceipts=@($receipts)+@($secondaryReceipt)
    $setAction={param($arguments)@($setReceipts|Where-Object CandidateId -CEQ ([string]$arguments.Candidate.CandidateId))[0]}.GetNewClosure()
    $benchmarkSet=& $module {param($i,$c,$r,$m,$run)Invoke-LabAiComputeBenchmarkSet -Inventory $i -Candidate $c -RuntimeDirectory $r -ModelPath $m -WorkloadKey sql-ai-generation -BenchmarkAction $run} $inventory $setCandidates @($package,$secondaryPackage) $model $setAction
    Add-CheckResult 'Mengensmessung ordnet mehrere Runtimes zu, deckt alle geeigneten Kandidaten ab und wählt den schnellsten' ($benchmarkSet.Benchmarks.Count -eq 5 -and $benchmarkSet.Selection.CandidateId -ceq $selection.CandidateId -and $benchmarkSet.Selection.SelectionMode -ceq 'AUTO_FASTEST')
    Add-CheckResult 'Mengensmessung entspricht dem eigenständigen Schema' (($benchmarkSet|ConvertTo-Json -Depth 30)|Test-Json -SchemaFile (Join-Path $repoRoot 'Schemas/ai-compute-benchmark-set.schema.json'))
    Add-CheckResult 'Mengensmessung blockiert vor dem ersten Lauf bei fehlender Kandidatenruntime' (Reject {& $module {param($i,$c,$r,$m,$run)Invoke-LabAiComputeBenchmarkSet -Inventory $i -Candidate $c -RuntimeDirectory $r -ModelPath $m -WorkloadKey sql-ai-generation -BenchmarkAction $run} $inventory $setCandidates @($package) $model $setAction} "AI_COMPUTE_BENCHMARK_RUNTIME_MISSING: $($secondaryCpu.CandidateId)")
    $incompleteSetAction={param($arguments)if([string]$arguments.Candidate.CandidateId -ceq [string]$candidateSet.Candidates[0].CandidateId){return $null};@($setReceipts|Where-Object CandidateId -CEQ ([string]$arguments.Candidate.CandidateId))[0]}.GetNewClosure()
    Add-CheckResult 'Mengensmessung veröffentlicht keine Teilauswahl' (Reject {& $module {param($i,$c,$r,$m,$run)Invoke-LabAiComputeBenchmarkSet -Inventory $i -Candidate $c -RuntimeDirectory $r -ModelPath $m -WorkloadKey sql-ai-generation -BenchmarkAction $run} $inventory $candidateSet.Candidates @($package) $model $incompleteSetAction} 'AI_COMPUTE_BENCHMARK_SET_INCOMPLETE:*')
    $cpuAutoReceipt=& $module {param($i,$c,$r,$m,$run)Invoke-LabAiComputeBenchmark -Inventory $i -Candidate $c -RuntimeDirectory $r -ModelPath $m -WorkloadKey sql-ai-generation -ProcessRunner $run} $inventory $cpu $package $model $runner
    Add-CheckResult 'CPU wird ohne Discovery eindeutig auf none gebunden' ($cpuAutoReceipt.CandidateId -ceq $cpu.CandidateId -and $cpuAutoReceipt.ThroughputPerSecond -eq 10)
    $embeddingRunner={
        param($invocation,$arguments,$environment,$timeout)
        $prompt=[int]$arguments[$arguments.IndexOf('-p')+1];$generated=[int]$arguments[$arguments.IndexOf('-n')+1];$repetitions=[int]$arguments[$arguments.IndexOf('-r')+1]
        $record=[ordered]@{backends='CPU';devices='none';n_prompt=$prompt;n_gen=$generated;avg_ts=30;samples_ns=@(1..$repetitions|ForEach-Object {20000000+($_*1000000)});samples_ts=@(1..$repetitions|ForEach-Object {30})}
        [pscustomobject]@{ExitCode=0;StdOut=($record|ConvertTo-Json -Compress);PeakWorkingSetBytes=2048}
    }
    $embeddingReceipt=& $module {param($i,$c,$r,$m,$run)Invoke-LabAiComputeBenchmark -Inventory $i -Candidate $c -RuntimeDirectory $r -ModelPath $m -WorkloadKey sql-ai-embedding -BenchmarkMode Embedding -PromptTokens 64 -ProcessRunner $run} $inventory $cpu $package $model $embeddingRunner
    Add-CheckResult 'Embeddingmodus bindet Promptmessung ohne generierte Tokens' ($embeddingReceipt.WorkloadKey -ceq 'sql-ai-embedding' -and $embeddingReceipt.ThroughputPerSecond -eq 30 -and $embeddingReceipt.BenchmarkProfileSha256 -cne $cpuAutoReceipt.BenchmarkProfileSha256)
    Add-CheckResult 'Embedding-Workloadschlüssel darf keinen Generationsbenchmark tarnen' (Reject {& $module {param($i,$c,$r,$m,$run)Invoke-LabAiComputeBenchmark -Inventory $i -Candidate $c -RuntimeDirectory $r -ModelPath $m -WorkloadKey sql-ai-embedding -ProcessRunner $run} $inventory $cpu $package $model $runner} 'AI_COMPUTE_BENCHMARK_WORKLOAD_MISMATCH')
    Add-CheckResult 'CPU-Lane verlangt explizit den Selector none' (Reject {& $module {param($i,$c,$r,$m,$run)Invoke-LabAiComputeBenchmark -Inventory $i -Candidate $c -RuntimeDirectory $r -ModelPath $m -WorkloadKey sql-ai-generation -DeviceBinding @([pscustomobject]@{DeviceId=$c.Devices[0].DeviceId;RuntimeSelector='CUDA0'}) -ProcessRunner $run} $inventory $cpu $package $model $runner} 'AI_COMPUTE_BENCHMARK_DEVICE_BINDING_MISMATCH')
    $badRunner={param($i,$a,$e,$t)[pscustomobject]@{ExitCode=0;StdOut='[]';PeakWorkingSetBytes=1}}
    Add-CheckResult 'Leere oder ungebundene llama-bench-Ausgabe wird abgewiesen' (Reject {& $module {param($i,$c,$r,$m,$run)Invoke-LabAiComputeBenchmark -Inventory $i -Candidate $c -RuntimeDirectory $r -ModelPath $m -WorkloadKey sql-ai-generation -DeviceBinding @([pscustomobject]@{DeviceId=$c.Devices[0].DeviceId;RuntimeSelector='none'}) -ProcessRunner $run} $inventory $cpu $package $model $badRunner} 'AI_COMPUTE_BENCHMARK_OUTPUT_INVALID')
    $duplicateBindings=@($multi.Devices|ForEach-Object {[pscustomobject]@{DeviceId=$_.DeviceId;RuntimeSelector='CUDA0'}})
    Add-CheckResult 'Zwei portable Geräte dürfen nicht denselben Runtimeselector beanspruchen' (Reject {& $module {param($i,$c,$r,$m,$b,$run)Invoke-LabAiComputeBenchmark -Inventory $i -Candidate $c -RuntimeDirectory $r -ModelPath $m -WorkloadKey sql-ai-generation -DeviceBinding $b -ProcessRunner $run} $inventory $multi $package $model $duplicateBindings $runner} 'AI_COMPUTE_BENCHMARK_DEVICE_BINDING_INVALID')
    $wrongBackendBindings=@($multi.Devices|ForEach-Object -Begin {$ordinal=0} -Process {[pscustomobject]@{DeviceId=$_.DeviceId;RuntimeSelector=('Vulkan'+$ordinal)};$ordinal++})
    Add-CheckResult 'Explizite Bindung darf den Kandidatenbackend nicht wechseln' (Reject {& $module {param($i,$c,$r,$m,$b,$run)Invoke-LabAiComputeBenchmark -Inventory $i -Candidate $c -RuntimeDirectory $r -ModelPath $m -WorkloadKey sql-ai-generation -DeviceBinding $b -ProcessRunner $run} $inventory $multi $package $model $wrongBackendBindings $runner} 'AI_COMPUTE_BENCHMARK_DEVICE_BINDING_MISMATCH')
    $forged=$multi|ConvertTo-Json -Depth 10|ConvertFrom-Json;$forged.Backend='LlamaCppVulkan'
    Add-CheckResult 'Kandidat darf kein im Paket fehlendes Backend behaupten' (Reject {& $module {param($i,$c,$r,$m,$b,$run)Invoke-LabAiComputeBenchmark -Inventory $i -Candidate $c -RuntimeDirectory $r -ModelPath $m -WorkloadKey sql-ai-generation -DeviceBinding $b -ProcessRunner $run} $inventory $forged $package $model @([pscustomobject]@{DeviceId=$forged.Devices[0].DeviceId;RuntimeSelector='Vulkan0'},[pscustomobject]@{DeviceId=$forged.Devices[1].DeviceId;RuntimeSelector='Vulkan1'}) $runner} 'AI_COMPUTE_BENCHMARK_BACKEND_MISMATCH')
    $ambiguousProbe=[pscustomobject]@{Platform='Windows';Coverage=@((Coverage CPU),(Coverage GPU),(Coverage NPU));Devices=@(
        (Device CPU cpu0 8086 cpu 'Intel CPU'),(Device GPU gpu0 10de nvidia 'NVIDIA Twin GPU'),(Device GPU gpu1 10de nvidia 'NVIDIA Twin GPU')
    )}
    $ambiguousInventory=& $module {param($p)Get-LabAiComputeInventory -ProbeResult $p} $ambiguousProbe
    $ambiguousCapabilities=Get-SqlServerLabAiRuntimeCapability -Inventory $ambiguousInventory -Runtime $runtime
    $ambiguousCandidates=Get-SqlServerLabAiComputeCandidate -Inventory $ambiguousInventory -RuntimeCapability $ambiguousCapabilities.Capabilities
    $ambiguousSingle=@($ambiguousCandidates.Candidates|Where-Object {$_.Backend -eq 'LlamaCppCuda' -and $_.Devices.Count -eq 1})[0]
    $ambiguousMulti=@($ambiguousCandidates.Candidates|Where-Object {$_.Backend -eq 'LlamaCppCuda' -and $_.Devices.Count -eq 2})[0]
    $ambiguousRunner={param($i,$a,$e,$t)if('--list-devices' -in $a){[pscustomobject]@{ExitCode=0;StdOut="Available devices:`nCUDA0: NVIDIA Twin GPU (1 MiB, 1 MiB free)`nCUDA1: NVIDIA Twin GPU (1 MiB, 1 MiB free)";PeakWorkingSetBytes=1}}else{& $runner $i $a $e $t}}
    Add-CheckResult 'Teilmenge identischer GPUs bleibt ohne eindeutige Hardwarekennung blockiert' (Reject {& $module {param($i,$c,$r,$m,$run)Invoke-LabAiComputeBenchmark -Inventory $i -Candidate $c -RuntimeDirectory $r -ModelPath $m -WorkloadKey sql-ai-generation -ProcessRunner $run} $ambiguousInventory $ambiguousSingle $package $model $ambiguousRunner} 'AI_COMPUTE_DEVICE_BINDING_AMBIGUOUS')
    $identicalGroupReceipt=& $module {param($i,$c,$r,$m,$run)Invoke-LabAiComputeBenchmark -Inventory $i -Candidate $c -RuntimeDirectory $r -ModelPath $m -WorkloadKey sql-ai-generation -ProcessRunner $run} $ambiguousInventory $ambiguousMulti $package $model $ambiguousRunner
    Add-CheckResult 'Vollständige Gruppe identischer GPUs wird als geschlossene Menge gebunden' ($identicalGroupReceipt.CandidateId -ceq $ambiguousMulti.CandidateId)
    $missingNameRunner={param($i,$a,$e,$t)if('--list-devices' -in $a){[pscustomobject]@{ExitCode=0;StdOut="Available devices:`nCUDA0: Other GPU (1 MiB, 1 MiB free)";PeakWorkingSetBytes=1}}else{& $runner $i $a $e $t}}
    Add-CheckResult 'Nicht übereinstimmender Runtime-Gerätename fällt geschlossen aus' (Reject {& $module {param($i,$c,$r,$m,$run)Invoke-LabAiComputeBenchmark -Inventory $i -Candidate $c -RuntimeDirectory $r -ModelPath $m -WorkloadKey sql-ai-generation -ProcessRunner $run} $inventory $multi $package $model $missingNameRunner} 'AI_COMPUTE_DEVICE_BINDING_UNRESOLVED')
    $failedDiscoveryRunner={param($i,$a,$e,$t)if('--list-devices' -in $a){[pscustomobject]@{ExitCode=3;StdOut='private runtime error';PeakWorkingSetBytes=1}}else{& $runner $i $a $e $t}}
    Add-CheckResult 'Fehlgeschlagene Gerätediscovery liefert nur stabilen Fehlercode' (Reject {& $module {param($i,$c,$r,$m,$run)Invoke-LabAiComputeBenchmark -Inventory $i -Candidate $c -RuntimeDirectory $r -ModelPath $m -WorkloadKey sql-ai-generation -ProcessRunner $run} $inventory $multi $package $model $failedDiscoveryRunner} 'AI_COMPUTE_DEVICE_DISCOVERY_FAILED')
    $badModel=Join-Path $fixture 'bad.gguf';[IO.File]::WriteAllText($badModel,'not-a-gguf')
    Add-CheckResult 'Dateiendung ohne GGUF-Magic wird vor Prozessstart abgewiesen' (Reject {& $module {param($i,$c,$r,$m,$run)Invoke-LabAiComputeBenchmark -Inventory $i -Candidate $c -RuntimeDirectory $r -ModelPath $m -WorkloadKey sql-ai-generation -DeviceBinding @([pscustomobject]@{DeviceId=$c.Devices[0].DeviceId;RuntimeSelector='none'}) -ProcessRunner $run} $inventory $cpu $package $badModel $runner} 'AI_COMPUTE_BENCHMARK_MODEL_INVALID')
    $inconsistentRunner={param($i,$a,$e,$t)[pscustomobject]@{ExitCode=0;StdOut=([ordered]@{backends='CPU';devices='none';n_prompt=0;n_gen=128;avg_ts=99;samples_ns=@(100000000,101000000,102000000,103000000,104000000);samples_ts=@(10,10,10,10,10)}|ConvertTo-Json -Compress);PeakWorkingSetBytes=1}}
    Add-CheckResult 'Widersprüchlicher llama-bench-Durchschnitt wird abgewiesen' (Reject {& $module {param($i,$c,$r,$m,$run)Invoke-LabAiComputeBenchmark -Inventory $i -Candidate $c -RuntimeDirectory $r -ModelPath $m -WorkloadKey sql-ai-generation -DeviceBinding @([pscustomobject]@{DeviceId=$c.Devices[0].DeviceId;RuntimeSelector='none'}) -ProcessRunner $run} $inventory $cpu $package $model $inconsistentRunner} 'AI_COMPUTE_BENCHMARK_OUTPUT_INVALID')
    $failedRunner={param($i,$a,$e,$t)[pscustomobject]@{ExitCode=7;StdOut='sensitive diagnostic';PeakWorkingSetBytes=1}}
    Add-CheckResult 'Fehlgeschlagener Benchmarkprozess liefert nur den stabilen Fehlercode' (Reject {& $module {param($i,$c,$r,$m,$run)Invoke-LabAiComputeBenchmark -Inventory $i -Candidate $c -RuntimeDirectory $r -ModelPath $m -WorkloadKey sql-ai-generation -DeviceBinding @([pscustomobject]@{DeviceId=$c.Devices[0].DeviceId;RuntimeSelector='none'}) -ProcessRunner $run} $inventory $cpu $package $model $failedRunner} 'AI_COMPUTE_BENCHMARK_EXECUTION_FAILED')
    $mutatingRunner={param($i,$a,$e,$t)[IO.File]::WriteAllText($model,'GGUFchanged-during-run');& $runner $i $a $e $t}
    Add-CheckResult 'Modelländerung während der Messung verwirft die Evidence' (Reject {& $module {param($i,$c,$r,$m,$run)Invoke-LabAiComputeBenchmark -Inventory $i -Candidate $c -RuntimeDirectory $r -ModelPath $m -WorkloadKey sql-ai-generation -DeviceBinding @([pscustomobject]@{DeviceId=$c.Devices[0].DeviceId;RuntimeSelector='none'}) -ProcessRunner $run} $inventory $cpu $package $model $mutatingRunner} 'AI_COMPUTE_BENCHMARK_ARTIFACT_CHANGED')
    Add-CheckResult 'Öffentliche Benchmarkbefehle sind manifestexportiert und WhatIf startet nichts' ((Get-Command Measure-SqlServerLabAiComputeCandidate).ModuleName -eq 'SqlServerLab' -and (Get-Command Measure-SqlServerLabAiComputeCandidateSet).ModuleName -eq 'SqlServerLab' -and -not @(Measure-SqlServerLabAiComputeCandidate -Inventory $inventory -Candidate $cpu -RuntimeDirectory $package -ModelPath $model -WorkloadKey sql-ai-generation -DeviceBinding @([pscustomobject]@{DeviceId=$cpu.Devices[0].DeviceId;RuntimeSelector='none'}) -WhatIf).Count -and -not @(Measure-SqlServerLabAiComputeCandidateSet -Inventory $inventory -Candidate $candidateSet.Candidates -RuntimeDirectory $package -ModelPath $model -WorkloadKey sql-ai-generation -WhatIf).Count)
}
finally {if((Split-Path $fixture -Parent) -eq [IO.Path]::GetTempPath().TrimEnd([IO.Path]::DirectorySeparatorChar) -and (Split-Path $fixture -Leaf) -like 'sql-lab-ai-benchmark-*'){Remove-Item -LiteralPath $fixture -Recurse -Force};Remove-Module $module -Force -ErrorAction SilentlyContinue}
if($failures.Count){throw ($failures -join '; ')}
Write-Host "AI COMPUTE BENCHMARK CONTRACT: PASS ($passed)"
