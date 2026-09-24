function Invoke-LabAiBenchmarkProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Invocation,
        [Parameter(Mandatory)][string[]]$ArgumentList,
        [Parameter(Mandatory)][hashtable]$Environment,
        [Parameter(Mandatory)][ValidateRange(1,3600)][int]$TimeoutSeconds
    )
    $start=[Diagnostics.ProcessStartInfo]::new()
    $start.FileName=$Invocation;$start.WorkingDirectory=Split-Path $Invocation -Parent
    $start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    foreach($argument in $ArgumentList){$null=$start.ArgumentList.Add($argument)}
    foreach($name in $Environment.Keys){$start.Environment[$name]=[string]$Environment[$name]}
    $process=[Diagnostics.Process]::new();$process.StartInfo=$start;$peak=0L
    try {
        if(-not $process.Start()){throw 'AI_COMPUTE_BENCHMARK_START_FAILED'}
        $stdoutTask=$process.StandardOutput.ReadToEndAsync();$stderrTask=$process.StandardError.ReadToEndAsync()
        $timer=[Diagnostics.Stopwatch]::StartNew()
        while(-not $process.WaitForExit(50)){
            try{$process.Refresh();$peak=[Math]::Max($peak,[long]$process.PeakWorkingSet64)}catch{}
            if($timer.Elapsed.TotalSeconds -ge $TimeoutSeconds){try{$process.Kill($true)}catch{};$null=$process.WaitForExit(10000);throw 'AI_COMPUTE_BENCHMARK_TIMEOUT'}
        }
        try{$process.Refresh();$peak=[Math]::Max($peak,[long]$process.PeakWorkingSet64)}catch{}
        $stdout=$stdoutTask.GetAwaiter().GetResult();$null=$stderrTask.GetAwaiter().GetResult()
        [PSCustomObject]@{ExitCode=$process.ExitCode;StdOut=$stdout;PeakWorkingSetBytes=$peak}
    } catch {
        if($_.Exception.Message -like 'AI_COMPUTE_BENCHMARK_*'){throw}
        throw 'AI_COMPUTE_BENCHMARK_START_FAILED'
    } finally {$process.Dispose()}
}

function ConvertTo-LabAiRuntimeDeviceName {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Value)
    return (($Value.ToLowerInvariant() -replace '[^a-z0-9]+',' ').Trim() -replace '\s+',' ')
}

function Resolve-LabAiRuntimeDeviceBinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Inventory,
        [Parameter(Mandatory)]$Candidate,
        [Parameter(Mandatory)][string]$BenchmarkInvocation,
        [Parameter(Mandatory)][ValidateRange(1,3600)][int]$TimeoutSeconds,
        [scriptblock]$ProcessRunner
    )
    $backend=[string]$Candidate.Backend
    if($backend -ceq 'LlamaCppCpu'){
        if(@($Candidate.Devices).Count -ne 1 -or [string]$Candidate.Devices[0].Kind -cne 'CPU'){throw 'AI_COMPUTE_DEVICE_BINDING_UNRESOLVED'}
        return @([PSCustomObject]@{DeviceId=[string]$Candidate.Devices[0].DeviceId;RuntimeSelector='none'})
    }
    $prefixes=switch($backend){LlamaCppCuda{@('CUDA')};LlamaCppRocm{@('ROCm','HIP')};LlamaCppVulkan{@('Vulkan')};LlamaCppSycl{@('SYCL')};LlamaCppOpenVino{@('OpenVINO')};default{throw 'AI_COMPUTE_DEVICE_BINDING_UNSUPPORTED'}}
    $environment=@{}
    if($backend -ceq 'LlamaCppOpenVino'){
        $kinds=@($Candidate.Devices.Kind|Sort-Object -Unique)
        if($kinds.Count -ne 1){throw 'AI_COMPUTE_DEVICE_BINDING_UNRESOLVED'}
        $environment.GGML_OPENVINO_DEVICE=$kinds[0]
    }
    try{$result=if($ProcessRunner){& $ProcessRunner $BenchmarkInvocation @('--list-devices') $environment $TimeoutSeconds}else{Invoke-LabAiBenchmarkProcess -Invocation $BenchmarkInvocation -ArgumentList @('--list-devices') -Environment $environment -TimeoutSeconds $TimeoutSeconds}}catch{throw 'AI_COMPUTE_DEVICE_DISCOVERY_FAILED'}
    if($null -eq $result -or [int]$result.ExitCode -ne 0){throw 'AI_COMPUTE_DEVICE_DISCOVERY_FAILED'}
    $runtimeDevices=[Collections.Generic.List[object]]::new();$selectors=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($line in @(([string]$result.StdOut) -split "`r?`n")){
        if($line -notmatch '^\s*(?<Selector>[A-Za-z][A-Za-z0-9._-]{0,63})\s*:\s*(?<Description>.+?)\s*$'){continue}
        $selector=[string]$Matches.Selector
        if(@($prefixes|Where-Object {$selector.StartsWith($_,[StringComparison]::OrdinalIgnoreCase)}).Count -eq 0){continue}
        if(-not $selectors.Add($selector)){throw 'AI_COMPUTE_DEVICE_DISCOVERY_INVALID'}
        $description=([string]$Matches.Description -replace '\s+\([0-9]+\s+MiB(?:,\s*[0-9]+\s+MiB\s+free)?\)\s*$','').Trim()
        $key=ConvertTo-LabAiRuntimeDeviceName $description
        if(-not $key){throw 'AI_COMPUTE_DEVICE_DISCOVERY_INVALID'}
        $runtimeDevices.Add([PSCustomObject]@{RuntimeSelector=$selector;NameKey=$key})
    }
    if(-not $runtimeDevices.Count){throw 'AI_COMPUTE_DEVICE_BINDING_UNRESOLVED'}
    $candidateIds=@($Candidate.Devices.DeviceId)
    $inventoryDevices=@($Inventory.Devices|Where-Object {$_.DeviceId -cin $candidateIds})
    if($inventoryDevices.Count -ne $candidateIds.Count){throw 'AI_COMPUTE_DEVICE_BINDING_UNRESOLVED'}
    $bindings=[Collections.Generic.List[object]]::new();$matchedSelectors=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($group in @($inventoryDevices|Group-Object {ConvertTo-LabAiRuntimeDeviceName ([string]$_.DisplayName)})){
        $kind=[string]$group.Group[0].Kind
        $allInventoryMatches=@($Inventory.Devices|Where-Object {$_.Kind -ceq $kind -and (ConvertTo-LabAiRuntimeDeviceName ([string]$_.DisplayName)) -ceq $group.Name})
        $runtimeMatches=@($runtimeDevices|Where-Object {$_.NameKey -ceq $group.Name -or $_.NameKey.StartsWith($group.Name+' ',[StringComparison]::Ordinal)})
        if($group.Count -ne $allInventoryMatches.Count){throw 'AI_COMPUTE_DEVICE_BINDING_AMBIGUOUS'}
        if(-not $runtimeMatches.Count){throw 'AI_COMPUTE_DEVICE_BINDING_UNRESOLVED'}
        if($runtimeMatches.Count -ne $group.Count -or @($runtimeMatches|Where-Object {-not $matchedSelectors.Add($_.RuntimeSelector)}).Count){throw 'AI_COMPUTE_DEVICE_BINDING_AMBIGUOUS'}
        $orderedIds=@($group.Group.DeviceId|Sort-Object);$orderedSelectors=@($runtimeMatches.RuntimeSelector|Sort-Object)
        for($index=0;$index -lt $orderedIds.Count;$index++){$bindings.Add([PSCustomObject]@{DeviceId=[string]$orderedIds[$index];RuntimeSelector=[string]$orderedSelectors[$index]})}
    }
    if($bindings.Count -ne $candidateIds.Count){throw 'AI_COMPUTE_DEVICE_BINDING_UNRESOLVED'}
    return @($bindings)
}

function Invoke-LabAiComputeBenchmark {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Inventory,
        [Parameter(Mandatory)]$Candidate,
        [Parameter(Mandatory)][string]$RuntimeDirectory,
        [Parameter(Mandatory)][string]$ModelPath,
        [Parameter(Mandatory)][ValidatePattern('^[a-z0-9][a-z0-9._-]{0,127}$')][string]$WorkloadKey,
        [ValidateCount(1,16)][object[]]$DeviceBinding,
        [ValidateRange(3,30)][int]$Repetitions=5,
        [ValidateRange(1,4096)][int]$GeneratedTokens=128,
        [ValidateRange(1,4096)][int]$BatchSize=512,
        [ValidateRange(1,4096)][int]$MicroBatchSize=128,
        [ValidateRange(1,3600)][int]$TimeoutSeconds=900,
        [scriptblock]$ProcessRunner
    )
    $Inventory=Assert-LabAiComputeInventoryReceipt -Inventory $Inventory
    $validation=Get-LabAiComputeSelection -WorkloadKey $WorkloadKey -ModelSha256 ('0'*64) -BenchmarkProfileSha256 ('0'*64) -InventorySha256 $Inventory.InventorySha256 -Candidate @($Candidate) -PinnedCandidateId ([string]$Candidate.CandidateId)
    $knownIds=@($Inventory.Devices.DeviceId)
    if(@($validation.Devices|Where-Object {$_.DeviceId -cnotin $knownIds}).Count){throw 'AI_COMPUTE_BENCHMARK_DEVICE_MISMATCH'}
    try{$runtimeRoot=[IO.Path]::GetFullPath($RuntimeDirectory).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)}catch{throw 'AI_COMPUTE_BENCHMARK_RUNTIME_INVALID'}
    try{$runtime=@(Find-LabLlamaCppRuntime -SearchRoot $runtimeRoot|Where-Object InstallationPath -EQ $runtimeRoot)}catch{throw 'AI_COMPUTE_BENCHMARK_RUNTIME_INVALID'}
    if($runtime.Count -ne 1){throw 'AI_COMPUTE_BENCHMARK_RUNTIME_INVALID'}
    $packageBefore=Get-LabAiRuntimePackageSha256 -Runtime $runtime[0]
    if([string]$packageBefore.RuntimeSha256 -cne [string]$validation.RuntimeSha256){throw 'AI_COMPUTE_BENCHMARK_RUNTIME_MISMATCH'}
    try{
        $directory=Get-Item -LiteralPath $runtime[0].InstallationPath -Force -ErrorAction Stop
        $bench=@(Get-ChildItem -LiteralPath $directory.FullName -File -Force -ErrorAction Stop|Where-Object Name -in @('llama-bench','llama-bench.exe'))
    }catch{throw 'AI_COMPUTE_BENCHMARK_TOOL_MISSING'}
    if($bench.Count -ne 1 -or $bench[0].Directory.FullName -cne $directory.FullName){throw 'AI_COMPUTE_BENCHMARK_TOOL_MISSING'}
    try{
        $modelItem=Get-Item -LiteralPath $ModelPath -Force -ErrorAction Stop
        if($modelItem -isnot [IO.FileInfo]){throw 'invalid'}
        $modelStream=[IO.File]::Open($modelItem.FullName,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        try{$magic=[byte[]]::new(4);if($modelStream.Read($magic,0,4) -ne 4 -or [Text.Encoding]::ASCII.GetString($magic) -cne 'GGUF'){throw 'invalid'}}
        finally{$modelStream.Dispose()}
    }catch{throw 'AI_COMPUTE_BENCHMARK_MODEL_INVALID'}
    $modelHash=Get-LabAiExternalModelFileSha256 -Path $modelItem.FullName -ArtifactKind MODEL
    $backend=[string]$validation.Backend
    $expectedToken=switch($backend){LlamaCppCpu{'CPU'};LlamaCppCuda{'CUDA'};LlamaCppRocm{'ROCm|HIP'};LlamaCppVulkan{'Vulkan'};LlamaCppSycl{'SYCL'};LlamaCppOpenVino{'OpenVINO'};default{throw 'AI_COMPUTE_BENCHMARK_BACKEND_UNSUPPORTED'}}
    if($backend -ne 'LlamaCppCpu' -and $backend -cnotin @($packageBefore.DetectedBackends)){throw 'AI_COMPUTE_BENCHMARK_BACKEND_MISMATCH'}
    $selectedInventoryDevices=@($validation.Devices|ForEach-Object {$id=$_.DeviceId;@($Inventory.Devices|Where-Object DeviceId -CEQ $id)[0]})
    $deviceContractValid=switch($backend){
        LlamaCppCpu {@($selectedInventoryDevices|Where-Object Kind -ne CPU).Count -eq 0}
        LlamaCppCuda {@($selectedInventoryDevices|Where-Object {$_.Kind -ne 'GPU' -or $_.VendorId -ne '10de'}).Count -eq 0}
        LlamaCppRocm {@($selectedInventoryDevices|Where-Object {$_.Kind -ne 'GPU' -or $_.VendorId -ne '1002'}).Count -eq 0}
        LlamaCppVulkan {@($selectedInventoryDevices|Where-Object Kind -ne GPU).Count -eq 0}
        LlamaCppSycl {@($selectedInventoryDevices|Where-Object {$_.Kind -ne 'GPU' -or $_.VendorId -ne '8086'}).Count -eq 0}
        LlamaCppOpenVino {@($selectedInventoryDevices.Kind|Sort-Object -Unique).Count -eq 1 -and -not @($selectedInventoryDevices|Where-Object {$_.Kind -in @('GPU','NPU') -and $_.VendorId -ne '8086'}).Count}
    }
    if(-not $deviceContractValid){throw 'AI_COMPUTE_BENCHMARK_DEVICE_MISMATCH'}
    $effectiveBindings=if($null -eq $DeviceBinding -or $DeviceBinding.Count -eq 0){@(Resolve-LabAiRuntimeDeviceBinding -Inventory $Inventory -Candidate $validation -BenchmarkInvocation $bench[0].FullName -TimeoutSeconds $TimeoutSeconds -ProcessRunner $ProcessRunner)}else{@($DeviceBinding)}
    $bindingFields=@('DeviceId','RuntimeSelector');$bindings=[Collections.Generic.List[object]]::new();$bindingIds=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $bindingSelectors=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($binding in $effectiveBindings){
        Assert-LabAiComputeProperties $binding $bindingFields 'AI_COMPUTE_BENCHMARK_DEVICE_BINDING_INVALID'
        $id=[string]$binding.DeviceId;$selector=[string]$binding.RuntimeSelector
        if(-not $bindingIds.Add($id) -or -not $bindingSelectors.Add($selector) -or $selector -notmatch '^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$'){throw 'AI_COMPUTE_BENCHMARK_DEVICE_BINDING_INVALID'}
        $bindings.Add([PSCustomObject]@{DeviceId=$id;RuntimeSelector=$selector})
    }
    $candidateIds=@($validation.Devices.DeviceId|Sort-Object)
    if(($candidateIds -join ',') -cne ((@($bindings.DeviceId)|Sort-Object) -join ',')){throw 'AI_COMPUTE_BENCHMARK_DEVICE_BINDING_MISMATCH'}
    $selectors=@($validation.Devices|ForEach-Object {$id=$_.DeviceId;@($bindings|Where-Object DeviceId -CEQ $id)[0].RuntimeSelector})
    if($backend -eq 'LlamaCppCpu' -and ($selectors.Count -ne 1 -or $selectors[0] -cne 'none')){throw 'AI_COMPUTE_BENCHMARK_DEVICE_BINDING_MISMATCH'}
    if($backend -ne 'LlamaCppCpu'){
        $selectorPrefixes=switch($backend){LlamaCppCuda{@('CUDA')};LlamaCppRocm{@('ROCm','HIP')};LlamaCppVulkan{@('Vulkan')};LlamaCppSycl{@('SYCL')};LlamaCppOpenVino{@('OpenVINO')};default{@()}}
        if(@($selectors|Where-Object {$selector=$_;@($selectorPrefixes|Where-Object {$selector.StartsWith($_,[StringComparison]::OrdinalIgnoreCase)}).Count -eq 0}).Count){throw 'AI_COMPUTE_BENCHMARK_DEVICE_BINDING_MISMATCH'}
    }
    $profile=[ordered]@{Contract='SqlServerLab.AiComputeBenchmarkProfile/1.0';WorkloadKey=$WorkloadKey;Repetitions=$Repetitions;GeneratedTokens=$GeneratedTokens;BatchSize=$BatchSize;MicroBatchSize=$MicroBatchSize}
    $profileHash=Get-LabAiPlanKey $profile
    $arguments=@('-m',$modelItem.FullName,'-o','json','-r',[string]$Repetitions,'-p','0','-n',[string]$GeneratedTokens,'-b',[string]$BatchSize,'-ub',[string]$MicroBatchSize,'-ngl',$(if($backend -eq 'LlamaCppCpu'){'0'}else{'99'}),'-dev',($selectors -join '/'),'-sm',$(if($selectors.Count -gt 1){'layer'}else{'none'}),'--offline')
    $environment=@{}
    if($backend -eq 'LlamaCppOpenVino'){$kinds=@($validation.Devices.Kind|Sort-Object -Unique);if($kinds.Count -ne 1){throw 'AI_COMPUTE_BENCHMARK_DEVICE_BINDING_MISMATCH'};$environment.GGML_OPENVINO_DEVICE=$kinds[0]}
    try{
        $result=if($ProcessRunner){& $ProcessRunner $bench[0].FullName $arguments $environment $TimeoutSeconds}else{Invoke-LabAiBenchmarkProcess -Invocation $bench[0].FullName -ArgumentList $arguments -Environment $environment -TimeoutSeconds $TimeoutSeconds}
    }catch{if($_.Exception.Message -like 'AI_COMPUTE_BENCHMARK_*'){throw};throw 'AI_COMPUTE_BENCHMARK_EXECUTION_FAILED'}
    if($null -eq $result -or [int]$result.ExitCode -ne 0 -or [long]$result.PeakWorkingSetBytes -lt 0){throw 'AI_COMPUTE_BENCHMARK_EXECUTION_FAILED'}
    try{$records=@(([string]$result.StdOut|ConvertFrom-Json -Depth 30 -ErrorAction Stop))}catch{throw 'AI_COMPUTE_BENCHMARK_OUTPUT_INVALID'}
    if($records.Count -ne 1){throw 'AI_COMPUTE_BENCHMARK_OUTPUT_INVALID'};$record=$records[0]
    $samplesNs=@($record.samples_ns);$samplesTs=@($record.samples_ts)
    if($samplesNs.Count -ne $Repetitions -or $samplesTs.Count -ne $Repetitions -or [int]$record.n_prompt -ne 0 -or [int]$record.n_gen -ne $GeneratedTokens -or [string]$record.devices -cne ($selectors -join '/') -or [string]$record.backends -notmatch ('(?i)'+$expectedToken)){throw 'AI_COMPUTE_BENCHMARK_OUTPUT_MISMATCH'}
    if(@($samplesNs|Where-Object {-not (Test-LabAiComputeFiniteNumber $_) -or [double]$_ -le 0}).Count -or @($samplesTs|Where-Object {-not (Test-LabAiComputeFiniteNumber $_) -or [double]$_ -le 0}).Count -or -not (Test-LabAiComputeFiniteNumber $record.avg_ts) -or [double]$record.avg_ts -le 0){throw 'AI_COMPUTE_BENCHMARK_OUTPUT_INVALID'}
    $throughput=(@($samplesTs|ForEach-Object {[double]$_})|Measure-Object -Average).Average
    if([Math]::Abs($throughput-[double]$record.avg_ts)/$throughput -gt 0.005){throw 'AI_COMPUTE_BENCHMARK_OUTPUT_INVALID'}
    $orderedNs=@($samplesNs|ForEach-Object {[double]$_}|Sort-Object)
    $p95Index=[Math]::Max(0,[Math]::Ceiling(0.95*$orderedNs.Count)-1)
    $packageAfter=Get-LabAiRuntimePackageSha256 -Runtime $runtime[0];$modelAfter=Get-LabAiExternalModelFileSha256 -Path $modelItem.FullName -ArtifactKind MODEL
    if($packageAfter.RuntimeSha256 -cne $packageBefore.RuntimeSha256 -or $modelAfter -cne $modelHash){throw 'AI_COMPUTE_BENCHMARK_ARTIFACT_CHANGED'}
    [PSCustomObject]@{Contract='SqlServerLab.AiComputeBenchmark/1.0';CandidateId=[string]$validation.CandidateId;WorkloadKey=$WorkloadKey;ModelSha256=$modelHash;BenchmarkProfileSha256=$profileHash;InventorySha256=[string]$Inventory.InventorySha256;RuntimeSha256=[string]$validation.RuntimeSha256;ThroughputPerSecond=[double]$throughput;P95LatencyMilliseconds=([double]$orderedNs[$p95Index]/1000000);PeakWorkingSetBytes=[long]$result.PeakWorkingSetBytes;SuccessfulIterations=$Repetitions;TotalIterations=$Repetitions;EvidenceStatus='BENCHMARK_VERIFIED'}
}
