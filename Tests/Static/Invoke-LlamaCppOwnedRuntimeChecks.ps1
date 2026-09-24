#Requires -Version 7.2
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification='Synthetic test key generated only for this isolated acceptance run; no real credential is embedded.')]
[CmdletBinding()]param()
$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
. (Join-Path $PSScriptRoot '../Common/CheckResult.ps1')
$failures=[Collections.Generic.List[string]]::new();$passed=0
$module=Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-llama-selection-'+[guid]::NewGuid().ToString('N'))
try {
    function Coverage($kind){[pscustomobject]@{Kind=$kind;Status='VERIFIED';Method=('TEST_'+$kind)}}
    function Device($kind,$source,$vendor,$product,$name){[pscustomobject]@{Kind=$kind;SourceId=$source;VendorId=$vendor;ProductId=$product;DisplayName=$name}}
    function Reject([scriptblock]$action,[string]$pattern){try{& $action|Out-Null;$false}catch{$_.Exception.Message -like $pattern}}
    $good="load_tensors: offloaded 13/13 layers to GPU`nCUDA0 compute buffer size = 21 MiB"
    $test={param($log,$backend,$accelerator) Test-LabLlamaCppAcceleratorLog -Log $log -Backend $backend -Accelerator $accelerator}
    Add-CheckResult 'CUDA verlangt vollständigen Offload und Compute-Puffer' (& $module $test $good LlamaCppCuda GPU)
    Add-CheckResult 'Teilweiser Offload wird abgewiesen' (-not (& $module $test ($good.Replace('13/13','12/13')) LlamaCppCuda GPU))
    Add-CheckResult 'Geräteinventar allein ist kein Ausführungsnachweis' (-not (& $module $test 'using device CUDA0' LlamaCppCuda GPU))
    Add-CheckResult 'Fallback wird trotz positiver Zeilen abgewiesen' (-not (& $module $test ($good+"`nfallback to CPU") LlamaCppCuda GPU))
    Add-CheckResult 'OpenVINO bindet exakt das angeforderte Gerät' (& $module $test "OpenVINO: using device NPU`nOPENVINO0`noffloaded 13/13 layers" LlamaCppOpenVino NPU)
    Add-CheckResult 'OpenVINO-GPU belegt keine NPU' (-not (& $module $test "OpenVINO: using device GPU`nOPENVINO0`noffloaded 13/13 layers" LlamaCppOpenVino NPU))
    $syntheticRoot=Join-Path ([IO.Path]::GetTempPath()) 'synthetic-operation'
    $openVinoEnvironment={param($accelerator,$root) Get-LabLlamaCppOpenVinoEnvironment -Accelerator $accelerator -OperationRoot $root}
    $npuEnvironment=& $module $openVinoEnvironment NPU $syntheticRoot
    $gpuEnvironment=& $module $openVinoEnvironment GPU $syntheticRoot
    Add-CheckResult 'NPU setzt Gerät und Stateless ohne nicht unterstützte Cachepfade' ($npuEnvironment.GGML_OPENVINO_DEVICE -eq 'NPU' -and $npuEnvironment.GGML_OPENVINO_STATEFUL_EXECUTION -eq '0' -and -not $npuEnvironment.ContainsKey('GGML_OPENVINO_CACHE_DIR') -and -not $npuEnvironment.ContainsKey('GGML_OPENVINO_MODEL_CACHE_DIR'))
    Add-CheckResult 'OpenVINO-GPU behält operationsgebundene Cachepfade' ($gpuEnvironment.GGML_OPENVINO_CACHE_DIR -eq (Join-Path $syntheticRoot 'ov-cache') -and $gpuEnvironment.GGML_OPENVINO_MODEL_CACHE_DIR -eq (Join-Path $syntheticRoot 'ov-model-cache'))
    $computeFailure={param($log,$backend,$accelerator) Test-LabLlamaCppComputeFailureLog -Log $log -Backend $backend -Accelerator $accelerator}
    Add-CheckResult 'OpenVINO-Graphfehler wird als Accelerator-Computefehler erkannt' (& $module $computeFailure 'GGML OpenVINO backend std::exception: inp_pos not found in cgraph' LlamaCppOpenVino NPU)
    Add-CheckResult 'Generische HTTP-Fehler werden nicht als Accelerator-Computefehler umgedeutet' (-not (& $module $computeFailure 'HTTP 500 synthetic fixture' LlamaCppOpenVino NPU))
    Add-CheckResult 'CUDA-Logs werden nicht als OpenVINO-Computefehler umgedeutet' (-not (& $module $computeFailure 'graph_compute: failed with error -1' LlamaCppCuda GPU))
    Add-CheckResult 'Explizite CPU erfordert CPU-Compute ohne Gerätebuffer' (& $module $test 'CPU compute buffer size = 3 MiB' LlamaCppCuda CPU)
    Add-CheckResult 'CPU-Claim lehnt GPU-Modellbuffer ab' (-not (& $module $test "CPU compute buffer size = 3 MiB`nCUDA0 model buffer size = 7 MiB" LlamaCppCuda CPU))
    $multiLog="load_tensors: offloaded 13/13 layers to GPU`nCUDA0 compute buffer size = 21 MiB`nCUDA1 compute buffer size = 21 MiB"
    Add-CheckResult 'Mehr-GPU-Log attestiert jeden ausgewählten CUDA-Selector' (& $module {param($l)Test-LabLlamaCppAcceleratorLog -Log $l -Backend LlamaCppCuda -Accelerator GPU -RuntimeSelector @('CUDA0','CUDA1')} $multiLog)
    Add-CheckResult 'Fehlender Mehr-GPU-Selector fällt geschlossen aus' (-not (& $module {param($l)Test-LabLlamaCppAcceleratorLog -Log $l -Backend LlamaCppCuda -Accelerator GPU -RuntimeSelector @('CUDA0','CUDA1')} ($multiLog -replace 'CUDA1','other')))
    Add-CheckResult 'ROCm- und Vulkan-Selektoren nutzen denselben vollständigen Offloadvertrag' (
        (& $module {Test-LabLlamaCppAcceleratorLog -Log "offloaded 7/7 layers`nROCm0 compute buffer size = 3 MiB" -Backend LlamaCppRocm -Accelerator GPU -RuntimeSelector ROCm0}) -and
        (& $module {Test-LabLlamaCppAcceleratorLog -Log "offloaded 7/7 layers`nVulkan0 model buffer size = 3 MiB" -Backend LlamaCppVulkan -Accelerator GPU -RuntimeSelector Vulkan0})
    )
    $linuxListen='0: 0100007F:4BEB 00000000:0000 0A 00000000:00000000 00:00000000 00000000 1000 0 77123 1 0000000000000000 100 0 0 10 0'
    Add-CheckResult 'Linux-Listener wird über Port, LISTEN-State und Socket-Inode dem eigenen Prozess zugeordnet' (
        (& $module {param($l)Test-LabLlamaCppListenerOwner -Port 19435 -ProcessId 42 -TcpRecord $l -DescriptorTarget 'socket:[77123]'} $linuxListen) -and
        -not (& $module {param($l)Test-LabLlamaCppListenerOwner -Port 19435 -ProcessId 42 -TcpRecord $l -DescriptorTarget 'socket:[77124]'} $linuxListen)
    )
    $workerText=Get-Content -LiteralPath (Join-Path $repoRoot 'Tools/Invoke-LlamaCppOwnedWorker.ps1') -Raw
    Add-CheckResult 'Linux-Worker verlangt Parent-Death-Signal vor dem Serverstart' ($workerText -match "--pdeathsig','KILL','--" -and $workerText -notmatch 'if\(-not \$IsWindows\)\{throw ''LLAMA_WINDOWS_REQUIRED''\}')
    $permissionRoot=Join-Path $fixture 'permissions';$null=New-Item -ItemType Directory -Path $permissionRoot -Force
    $permissionFile=Join-Path $permissionRoot 'api-key.txt';[IO.File]::WriteAllText($permissionFile,'synthetic')
    & $module {param($d,$f)Protect-LabLlamaCppOperationPath -Path $d;Protect-LabLlamaCppOperationPath -Path $f -File} $permissionRoot $permissionFile
    $permissionsProtected=if($IsWindows){(Get-Acl -LiteralPath $permissionRoot).AreAccessRulesProtected -and (Get-Acl -LiteralPath $permissionFile).AreAccessRulesProtected}else{
        [IO.File]::GetUnixFileMode($permissionRoot) -eq ([IO.UnixFileMode]::UserRead-bor[IO.UnixFileMode]::UserWrite-bor[IO.UnixFileMode]::UserExecute) -and
        [IO.File]::GetUnixFileMode($permissionFile) -eq ([IO.UnixFileMode]::UserRead-bor[IO.UnixFileMode]::UserWrite)
    }
    Add-CheckResult 'Operationsverzeichnis und API-Key erhalten plattformgerechte restriktive Rechte' $permissionsProtected
    $probe=[pscustomobject]@{Platform='Windows';Coverage=@((Coverage CPU),(Coverage GPU),(Coverage NPU));Devices=@(
        (Device CPU cpu0 8086 cpu 'Intel CPU'),(Device GPU gpu0 10de nvidia 'NVIDIA GPU 0'),(Device GPU gpu1 10de nvidia 'NVIDIA GPU 1')
    )}
    $inventory=& $module {param($p)Get-LabAiComputeInventory -ProbeResult $p} $probe
    $package=Join-Path $fixture 'llama-b300-bin-cuda';$null=New-Item -ItemType Directory -Path $package -Force
    foreach($name in @('llama-server.exe','ggml-cuda.dll')){[IO.File]::WriteAllText((Join-Path $package $name),('synthetic-'+$name))}
    $model=Join-Path $fixture 'model.gguf';[IO.File]::WriteAllText($model,'GGUFsynthetic-model')
    $runtime=@(Get-SqlServerLabLlamaCppRuntime -SearchRoot $package)[0]
    $capabilities=Get-SqlServerLabAiRuntimeCapability -Inventory $inventory -Runtime $runtime
    $candidates=Get-SqlServerLabAiComputeCandidate -Inventory $inventory -RuntimeCapability $capabilities.Capabilities
    $multi=@($candidates.Candidates|Where-Object {$_.Backend -eq 'LlamaCppCuda' -and $_.Devices.Count -eq 2})[0]
    $modelHash=(Get-FileHash -LiteralPath $model -Algorithm SHA256).Hash.ToLowerInvariant()
    $selection=Get-SqlServerLabAiComputeSelection -WorkloadKey sql-ai-embedding -ModelSha256 $modelHash -BenchmarkProfileSha256 ('b'*64) -InventorySha256 $inventory.InventorySha256 -Candidate $candidates.Candidates -PinnedCandidateId $multi.CandidateId
    $runner={param($i,$a,$e,$t)[pscustomobject]@{ExitCode=0;StdOut="Available devices:`nCUDA1: NVIDIA GPU 1 (NVIDIA) (1 MiB, 1 MiB free)`nCUDA0: NVIDIA GPU 0 (NVIDIA) (1 MiB, 1 MiB free)";PeakWorkingSetBytes=1}}
    $configuration=& $module {param($s,$i,$r,$m,$run)Resolve-LabLlamaCppComputeSelection -ComputeSelection $s -Inventory $i -Runtime $r -ModelPath $m -ProcessRunner $run} $selection $inventory $runtime $model $runner
    Add-CheckResult 'ComputeSelection bindet Mehr-GPU-Start an Runtime, Modell, Inventar und Selektoren' ($configuration.Backend -ceq 'LlamaCppCuda' -and $configuration.Accelerator -ceq 'GPU' -and ($configuration.RuntimeSelectors -join ',') -ceq 'CUDA0,CUDA1')
    $wrongModel=$selection|ConvertTo-Json -Depth 30|ConvertFrom-Json;$wrongModel.ModelSha256='a'*64
    Add-CheckResult 'Abweichender Modellhash blockiert vor Start' (Reject {& $module {param($s,$i,$r,$m,$run)Resolve-LabLlamaCppComputeSelection -ComputeSelection $s -Inventory $i -Runtime $r -ModelPath $m -ProcessRunner $run} $wrongModel $inventory $runtime $model $runner} 'LLAMA_COMPUTE_MODEL_MISMATCH')
    $wrongWorkload=$selection|ConvertTo-Json -Depth 30|ConvertFrom-Json;$wrongWorkload.WorkloadKey='sql-ai-generation'
    Add-CheckResult 'Embeddingserver lehnt Generationsauswahl ab' (Reject {& $module {param($s,$i,$r,$m,$run)Resolve-LabLlamaCppComputeSelection -ComputeSelection $s -Inventory $i -Runtime $r -ModelPath $m -ProcessRunner $run} $wrongWorkload $inventory $runtime $model $runner} 'LLAMA_COMPUTE_WORKLOAD_MISMATCH')
    $wrongBindings=@($multi.Devices|ForEach-Object -Begin {$n=0} -Process {[pscustomobject]@{DeviceId=$_.DeviceId;RuntimeSelector=('Vulkan'+$n)};$n++})
    Add-CheckResult 'Explizite Startbindung darf den ausgewählten Backendtyp nicht wechseln' (Reject {& $module {param($s,$i,$r,$m,$b,$run)Resolve-LabLlamaCppComputeSelection -ComputeSelection $s -Inventory $i -Runtime $r -ModelPath $m -DeviceBinding $b -ProcessRunner $run} $selection $inventory $runtime $model $wrongBindings $runner} 'LLAMA_COMPUTE_DEVICE_BINDING_MISMATCH')
    $key=ConvertTo-SecureString ('x'*24) -AsPlainText -Force
    try {
        $preview=@(Start-SqlServerLabLlamaCppRuntime -RuntimeDirectory missing -Backend LlamaCppCuda -Accelerator GPU -ModelPath missing -ModelName synthetic -Dimension 3 -Pooling mean -Port 19435 -CertificatePath missing -PrivateKeyPath missing -ApiKey $key -WhatIf)
        $selectedPreview=@(Start-SqlServerLabLlamaCppRuntime -RuntimeDirectory missing -ComputeSelection $selection -Inventory $inventory -ModelPath missing -ModelName synthetic -Dimension 3 -Pooling mean -Port 19435 -CertificatePath missing -PrivateKeyPath missing -ApiKey $key -WhatIf)
        Add-CheckResult 'WhatIf führt keine Dateiprüfung oder Mutation aus' ($preview.Count -eq 0 -and $selectedPreview.Count -eq 0)
    } finally {$key.Dispose()}
    $code='';try{Stop-SqlServerLabLlamaCppRuntime -OperationId ([guid]::NewGuid().ToString('D'))}catch{$code=$_.Exception.Message}
    Add-CheckResult 'Fremde Operation wird ohne Prozesszugriff abgewiesen' ($code -eq 'LLAMA_OWNERSHIP_NOT_FOUND')
    Add-CheckResult 'Start verlangt keinen Hashparameter' (-not (Get-Command Start-SqlServerLabLlamaCppRuntime).Parameters.ContainsKey('RuntimeSha256') -and -not (Get-Command Start-SqlServerLabLlamaCppRuntime).Parameters.ContainsKey('ModelSha256'))
}
finally {if((Split-Path $fixture -Parent) -eq [IO.Path]::GetTempPath().TrimEnd([IO.Path]::DirectorySeparatorChar) -and (Split-Path $fixture -Leaf) -like 'sql-lab-llama-selection-*'){Remove-Item -LiteralPath $fixture -Recurse -Force};Remove-Module $module -Force}
if($failures.Count){throw ($failures -join '; ')}
Write-Host "LLAMA OWNED CONTRACT: PASS ($passed)"
