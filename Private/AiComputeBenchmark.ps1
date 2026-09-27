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
    # Match the owned runtime: discovery and measurement use only bound backend overrides.
    foreach($name in @($start.Environment.Keys)){
        if($name -match '^(LLAMA|GGML|CUDA|HIP|OPENVINO|OV_|HF_|HUGGING_FACE|ROCR)'){$null=$start.Environment.Remove($name)}
    }
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
        $stdout=$stdoutTask.GetAwaiter().GetResult();$stderr=$stderrTask.GetAwaiter().GetResult()
        [PSCustomObject]@{ExitCode=$process.ExitCode;StdOut=$stdout;StdErr=$stderr;PeakWorkingSetBytes=$peak}
    } catch {
        if($_.Exception.Message -like 'AI_COMPUTE_BENCHMARK_*'){throw}
        throw 'AI_COMPUTE_BENCHMARK_START_FAILED'
    } finally {$process.Dispose()}
}

function Invoke-LabOpenVinoNativeDeviceProbe {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$LibraryPath)
    # Only called by the isolated discovery child; native libraries never enter the caller.
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class SqlLabOpenVinoProbe {
 [StructLayout(LayoutKind.Sequential)] struct Devices { public IntPtr Names; public UIntPtr Count; }
 [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int Create(out IntPtr core);
 [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate void FreeCore(IntPtr core);
 [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int Available(IntPtr core, out Devices devices);
 [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate void FreeDevices(ref Devices devices);
 [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int Property(IntPtr core, [MarshalAs(UnmanagedType.LPUTF8Str)] string device, [MarshalAs(UnmanagedType.LPUTF8Str)] string key, out IntPtr value);
 [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate void FreeValue(IntPtr value);
 static T Export<T>(IntPtr lib,string name) where T:Delegate { return Marshal.GetDelegateForFunctionPointer<T>(NativeLibrary.GetExport(lib,name)); }
 public static Dictionary<string,string>[] Query(string path) {
  var lib=NativeLibrary.Load(path,typeof(SqlLabOpenVinoProbe).Assembly,DllImportSearchPath.UseDllDirectoryForDependencies|DllImportSearchPath.SafeDirectories);
  try {
   var create=Export<Create>(lib,"ov_core_create");var freeCore=Export<FreeCore>(lib,"ov_core_free");
   var available=Export<Available>(lib,"ov_core_get_available_devices");var freeDevices=Export<FreeDevices>(lib,"ov_available_devices_free");
   var property=Export<Property>(lib,"ov_core_get_property");var freeValue=Export<FreeValue>(lib,"ov_free");
   IntPtr core;var status=create(out core);if(status!=0)throw new Exception("CORE_CREATE_FAILED");
   try {
    Devices devices;status=available(core,out devices);if(status!=0)throw new Exception("DEVICE_QUERY_FAILED");
    try {
     var count=devices.Count.ToUInt64();if(count<1||count>16||devices.Names==IntPtr.Zero)throw new Exception("DEVICE_COUNT_INVALID");
     var result=new List<Dictionary<string,string>>();
     for(int index=0;index<(int)count;index++) {
      var name=Marshal.PtrToStringUTF8(Marshal.ReadIntPtr(devices.Names,index*IntPtr.Size));
      IntPtr value;status=property(core,name,"FULL_DEVICE_NAME",out value);
      try {if(status!=0||value==IntPtr.Zero)throw new Exception("DEVICE_PROPERTY_FAILED");result.Add(new Dictionary<string,string>{{"RuntimeDevice",name},{"FullName",Marshal.PtrToStringUTF8(value)}});}
      finally {if(value!=IntPtr.Zero)freeValue(value);}
     }
     return result.ToArray();
    }finally {freeDevices(ref devices);}
   }finally {freeCore(core);}
  }finally {NativeLibrary.Free(lib);}
 }
}
'@
    [SqlLabOpenVinoProbe]::Query($LibraryPath)
}

function Resolve-LabOpenVinoBenchmarkDevice {
    [CmdletBinding()]
    param($Inventory,$Candidate,[string]$BenchmarkInvocation,[int]$TimeoutSeconds,[scriptblock]$ProcessRunner)
    if(@($Candidate.Devices).Count -ne 1){throw 'AI_COMPUTE_DEVICE_BINDING_UNRESOLVED'}
    $target=@($Inventory.Devices|Where-Object DeviceId -CEQ $Candidate.Devices[0].DeviceId)
    if($target.Count -ne 1){throw 'AI_COMPUTE_DEVICE_BINDING_UNRESOLVED'}
    $library=Join-Path (Split-Path $BenchmarkInvocation -Parent) 'openvino_c.dll'
    if(-not $ProcessRunner -and (-not $IsWindows -or -not (Test-Path -LiteralPath $library -PathType Leaf))){throw 'AI_COMPUTE_DEVICE_DISCOVERY_UNAVAILABLE'}
    $source=Join-Path $script:ModuleRoot 'Private/AiComputeBenchmark.ps1'
    $command="`$ErrorActionPreference='Stop';try{. '"+$source.Replace("'","''")+"';ConvertTo-Json -InputObject @(Invoke-LabOpenVinoNativeDeviceProbe -LibraryPath '"+$library.Replace("'","''")+"') -Compress -Depth 4}catch{[Console]::Error.Write('OPENVINO_DEVICE_PROBE_FAILED');exit 1}"
    $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $pwsh=Join-Path $PSHOME $(if($IsWindows){'pwsh.exe'}else{'pwsh'})
    $arguments=@('-NoLogo','-NoProfile','-NonInteractive','-EncodedCommand',$encoded)
    try{$probe=if($ProcessRunner){& $ProcessRunner $pwsh $arguments @{} ([Math]::Min(30,$TimeoutSeconds))}else{Invoke-LabAiBenchmarkProcess -Invocation $pwsh -ArgumentList $arguments -Environment @{} -TimeoutSeconds ([Math]::Min(30,$TimeoutSeconds))}}catch{throw 'AI_COMPUTE_DEVICE_DISCOVERY_FAILED'}
    if($null -eq $probe -or $probe.ExitCode -ne 0 -or ([string]$probe.StdOut).Length -gt 16384){throw 'AI_COMPUTE_DEVICE_DISCOVERY_FAILED'}
    try{$devices=@($probe.StdOut|ConvertFrom-Json -Depth 5 -ErrorAction Stop)}catch{throw 'AI_COMPUTE_DEVICE_DISCOVERY_INVALID'}
    if($devices.Count -lt 1 -or $devices.Count -gt 16){throw 'AI_COMPUTE_DEVICE_DISCOVERY_INVALID'}
    $ids=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($device in $devices){
        Assert-LabAiComputeProperties $device @('RuntimeDevice','FullName') 'AI_COMPUTE_DEVICE_DISCOVERY_INVALID'
        if($device.RuntimeDevice -isnot [string] -or $device.RuntimeDevice -cnotmatch '^(CPU|GPU|NPU)(\.[0-9]{1,3})?$' -or -not $ids.Add($device.RuntimeDevice) -or $device.FullName -isnot [string] -or [string]::IsNullOrWhiteSpace($device.FullName) -or $device.FullName.Length -gt 512){throw 'AI_COMPUTE_DEVICE_DISCOVERY_INVALID'}
    }
    $name=ConvertTo-LabAiRuntimeDeviceName $target[0].DisplayName
    if(@($Inventory.Devices|Where-Object {$_.Kind -ceq $target[0].Kind -and (ConvertTo-LabAiRuntimeDeviceName $_.DisplayName) -ceq $name}).Count -ne 1){throw 'AI_COMPUTE_DEVICE_BINDING_AMBIGUOUS'}
    $matches=@($devices|Where-Object {($_.RuntimeDevice -split '\.')[0] -ceq $target[0].Kind -and (ConvertTo-LabAiRuntimeDeviceName ($_.FullName -replace '\s+\((?:iGPU|dGPU)\)$','')) -ceq $name})
    if($matches.Count -gt 1){throw 'AI_COMPUTE_DEVICE_BINDING_AMBIGUOUS'}
    if($matches.Count -ne 1){throw 'AI_COMPUTE_DEVICE_BINDING_UNRESOLVED'}
    return [string]$matches[0].RuntimeDevice
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
        [ValidateSet('Generation','Embedding')][string]$BenchmarkMode='Generation',
        [ValidateRange(1,4096)][int]$PromptTokens=512,
        [ValidateRange(1,4096)][int]$BatchSize=512,
        [ValidateRange(1,4096)][int]$MicroBatchSize=128,
        [ValidateRange(1,3600)][int]$TimeoutSeconds=900,
        [scriptblock]$ProcessRunner
    )
    if($BenchmarkMode -eq 'Embedding' -and $WorkloadKey -cne 'sql-ai-embedding'){throw 'AI_COMPUTE_BENCHMARK_WORKLOAD_MISMATCH'}
    if($BenchmarkMode -eq 'Generation' -and $WorkloadKey -ceq 'sql-ai-embedding'){throw 'AI_COMPUTE_BENCHMARK_WORKLOAD_MISMATCH'}
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
    $openVinoDevice=$null;$openVinoSelector=$null
    if($backend -eq 'LlamaCppOpenVino'){
        $openVinoDevice=Resolve-LabOpenVinoBenchmarkDevice -Inventory $Inventory -Candidate $validation -BenchmarkInvocation $bench[0].FullName -TimeoutSeconds $TimeoutSeconds -ProcessRunner $ProcessRunner
        $discoveryEnvironment=@{GGML_OPENVINO_DEVICE=$openVinoDevice}
        try{$discovery=if($ProcessRunner){& $ProcessRunner $bench[0].FullName @('--list-devices') $discoveryEnvironment $TimeoutSeconds}else{Invoke-LabAiBenchmarkProcess -Invocation $bench[0].FullName -ArgumentList @('--list-devices') -Environment $discoveryEnvironment -TimeoutSeconds $TimeoutSeconds}}catch{throw 'AI_COMPUTE_DEVICE_DISCOVERY_FAILED'}
        if($null -eq $discovery -or $discovery.ExitCode -ne 0){throw 'AI_COMPUTE_DEVICE_DISCOVERY_FAILED'}
        $found=[regex]::Matches([string]$discovery.StdOut,'(?m)^\s*(OPENVINO[0-9]+):[^\r\n]+\r?$')
        $actual=[regex]::Matches([string]$discovery.StdErr,'(?m)^OpenVINO: using device ([A-Za-z0-9._-]+)\s*$')
        if($found.Count -ne 1 -or $actual.Count -ne 1 -or $actual[0].Groups[1].Value -cne $openVinoDevice -or $discovery.StdErr -match '(?i)fallback|falling back'){throw 'AI_COMPUTE_DEVICE_BINDING_UNRESOLVED'}
        $openVinoSelector=$found[0].Groups[1].Value
    }
    $effectiveBindings=if($null -eq $DeviceBinding -or $DeviceBinding.Count -eq 0){
        if($backend -eq 'LlamaCppOpenVino'){@([PSCustomObject]@{DeviceId=$validation.Devices[0].DeviceId;RuntimeSelector=$openVinoSelector})}
        else{@(Resolve-LabAiRuntimeDeviceBinding -Inventory $Inventory -Candidate $validation -BenchmarkInvocation $bench[0].FullName -TimeoutSeconds $TimeoutSeconds -ProcessRunner $ProcessRunner)}
    }else{@($DeviceBinding)}
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
    if($backend -eq 'LlamaCppOpenVino' -and ($selectors.Count -ne 1 -or $selectors[0] -cne $openVinoSelector)){throw 'AI_COMPUTE_BENCHMARK_DEVICE_BINDING_MISMATCH'}
    if($backend -eq 'LlamaCppCpu' -and ($selectors.Count -ne 1 -or $selectors[0] -cne 'none')){throw 'AI_COMPUTE_BENCHMARK_DEVICE_BINDING_MISMATCH'}
    if($backend -ne 'LlamaCppCpu'){
        $selectorPrefixes=switch($backend){LlamaCppCuda{@('CUDA')};LlamaCppRocm{@('ROCm','HIP')};LlamaCppVulkan{@('Vulkan')};LlamaCppSycl{@('SYCL')};LlamaCppOpenVino{@('OpenVINO')};default{@()}}
        if(@($selectors|Where-Object {$selector=$_;@($selectorPrefixes|Where-Object {$selector.StartsWith($_,[StringComparison]::OrdinalIgnoreCase)}).Count -eq 0}).Count){throw 'AI_COMPUTE_BENCHMARK_DEVICE_BINDING_MISMATCH'}
    }
    $profile=[ordered]@{Contract='SqlServerLab.AiComputeBenchmarkProfile/1.0';ProcessEnvironmentPolicy='ISOLATED_MODEL_BACKEND_V1';WorkloadKey=$WorkloadKey;BenchmarkMode=$BenchmarkMode;Repetitions=$Repetitions;GeneratedTokens=$GeneratedTokens;PromptTokens=$PromptTokens;BatchSize=$BatchSize;MicroBatchSize=$MicroBatchSize}
    $profileHash=Get-LabAiPlanKey $profile
    $expectedPrompt=if($BenchmarkMode -eq 'Embedding'){$PromptTokens}else{0};$expectedGeneration=if($BenchmarkMode -eq 'Embedding'){0}else{$GeneratedTokens}
    $arguments=@('-m',$modelItem.FullName,'-o','json','-r',[string]$Repetitions,'-p',[string]$expectedPrompt,'-n',[string]$expectedGeneration)
    if($BenchmarkMode -eq 'Embedding'){$arguments+=@('-embd','1')}
    $arguments+=@('-b',[string]$BatchSize,'-ub',[string]$MicroBatchSize,'-ngl',$(if($backend -eq 'LlamaCppCpu'){'0'}else{'99'}),'-dev',($selectors -join '/'),'-sm',$(if($selectors.Count -gt 1){'layer'}else{'none'}),'--offline')
    $environment=@{}
    if($backend -eq 'LlamaCppOpenVino'){$environment.GGML_OPENVINO_DEVICE=$openVinoDevice;$arguments+='--verbose'}
    try{
        $result=if($ProcessRunner){& $ProcessRunner $bench[0].FullName $arguments $environment $TimeoutSeconds}else{Invoke-LabAiBenchmarkProcess -Invocation $bench[0].FullName -ArgumentList $arguments -Environment $environment -TimeoutSeconds $TimeoutSeconds}
    }catch{if($_.Exception.Message -like 'AI_COMPUTE_BENCHMARK_*'){throw};throw 'AI_COMPUTE_BENCHMARK_EXECUTION_FAILED'}
    if($null -eq $result -or [int]$result.ExitCode -ne 0 -or [long]$result.PeakWorkingSetBytes -lt 0){throw 'AI_COMPUTE_BENCHMARK_EXECUTION_FAILED'}
    if($backend -eq 'LlamaCppOpenVino'){
        $log=if($result.PSObject.Properties['StdErr']){[string]$result.StdErr}else{''}
        $deviceEvidence=[regex]::Matches($log,'(?m)^OpenVINO: using device ([A-Za-z0-9._-]+)\s*$')
        if($deviceEvidence.Count -ne 1 -or $deviceEvidence[0].Groups[1].Value -cne $environment.GGML_OPENVINO_DEVICE -or
            (Test-LabLlamaCppComputeFailureLog -Log $log -Backend $backend -Accelerator $validation.Devices[0].Kind) -or
            -not (Test-LabLlamaCppAcceleratorLog -Log $log -Backend $backend -Accelerator $environment.GGML_OPENVINO_DEVICE -RuntimeSelector $selectors)){
            throw 'AI_COMPUTE_BENCHMARK_DEVICE_EVIDENCE_INVALID'
        }
    }
    try{$records=@(([string]$result.StdOut|ConvertFrom-Json -Depth 30 -ErrorAction Stop))}catch{throw 'AI_COMPUTE_BENCHMARK_OUTPUT_INVALID'}
    if($records.Count -ne 1){throw 'AI_COMPUTE_BENCHMARK_OUTPUT_INVALID'};$record=$records[0]
    $samplesNs=@($record.samples_ns);$samplesTs=@($record.samples_ts)
    # backends beschreibt das Runtimepaket, nicht die gewaehlte CPU-Ausfuehrung.
    $backendOutputValid=if($backend -eq 'LlamaCppCpu'){
        ($record.n_gpu_layers -is [int] -or $record.n_gpu_layers -is [long]) -and
        $record.n_gpu_layers -eq 0 -and -not [string]::IsNullOrWhiteSpace([string]$record.backends)
    }else{[string]$record.backends -match ('(?i)'+$expectedToken)}
    if($samplesNs.Count -ne $Repetitions -or $samplesTs.Count -ne $Repetitions -or [int]$record.n_prompt -ne $expectedPrompt -or [int]$record.n_gen -ne $expectedGeneration -or [string]$record.devices -cne ($selectors -join '/') -or -not $backendOutputValid){throw 'AI_COMPUTE_BENCHMARK_OUTPUT_MISMATCH'}
    if(@($samplesNs|Where-Object {-not (Test-LabAiComputeFiniteNumber $_) -or [double]$_ -le 0}).Count -or @($samplesTs|Where-Object {-not (Test-LabAiComputeFiniteNumber $_) -or [double]$_ -le 0}).Count -or -not (Test-LabAiComputeFiniteNumber $record.avg_ts) -or [double]$record.avg_ts -le 0){throw 'AI_COMPUTE_BENCHMARK_OUTPUT_INVALID'}
    $throughput=(@($samplesTs|ForEach-Object {[double]$_})|Measure-Object -Average).Average
    if([Math]::Abs($throughput-[double]$record.avg_ts)/$throughput -gt 0.005){throw 'AI_COMPUTE_BENCHMARK_OUTPUT_INVALID'}
    $orderedNs=@($samplesNs|ForEach-Object {[double]$_}|Sort-Object)
    $p95Index=[Math]::Max(0,[Math]::Ceiling(0.95*$orderedNs.Count)-1)
    $packageAfter=Get-LabAiRuntimePackageSha256 -Runtime $runtime[0];$modelAfter=Get-LabAiExternalModelFileSha256 -Path $modelItem.FullName -ArtifactKind MODEL
    if($packageAfter.RuntimeSha256 -cne $packageBefore.RuntimeSha256 -or $modelAfter -cne $modelHash){throw 'AI_COMPUTE_BENCHMARK_ARTIFACT_CHANGED'}
    [PSCustomObject]@{Contract='SqlServerLab.AiComputeBenchmark/1.0';CandidateId=[string]$validation.CandidateId;WorkloadKey=$WorkloadKey;ModelSha256=$modelHash;BenchmarkProfileSha256=$profileHash;InventorySha256=[string]$Inventory.InventorySha256;RuntimeSha256=[string]$validation.RuntimeSha256;ThroughputPerSecond=[double]$throughput;P95LatencyMilliseconds=([double]$orderedNs[$p95Index]/1000000);PeakWorkingSetBytes=[long]$result.PeakWorkingSetBytes;SuccessfulIterations=$Repetitions;TotalIterations=$Repetitions;EvidenceStatus='BENCHMARK_VERIFIED'}
}

function Invoke-LabAiComputeBenchmarkSet {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Inventory,
        [Parameter(Mandatory)][ValidateCount(1,64)][object[]]$Candidate,
        [Parameter(Mandatory)][ValidateCount(1,64)][string[]]$RuntimeDirectory,
        [Parameter(Mandatory)][string]$ModelPath,
        [Parameter(Mandatory)][ValidatePattern('^[a-z0-9][a-z0-9._-]{0,127}$')][string]$WorkloadKey,
        [ValidateRange(3,30)][int]$Repetitions=5,
        [ValidateRange(1,4096)][int]$GeneratedTokens=128,
        [ValidateSet('Generation','Embedding')][string]$BenchmarkMode='Generation',
        [ValidateRange(1,4096)][int]$PromptTokens=512,
        [ValidateRange(1,4096)][int]$BatchSize=512,
        [ValidateRange(1,4096)][int]$MicroBatchSize=128,
        [ValidateRange(1,3600)][int]$TimeoutSeconds=900,
        [scriptblock]$BenchmarkAction
    )
    $Inventory=Assert-LabAiComputeInventoryReceipt -Inventory $Inventory
    $eligibleInput=@($Candidate|Where-Object {$null -ne $_ -and $_.PSObject.Properties['Eligible'] -and $_.Eligible -eq $true})
    $probeId=if($eligibleInput.Count){[string]$eligibleInput[0].CandidateId}else{'missing'}
    $null=Get-LabAiComputeSelection -WorkloadKey $WorkloadKey -ModelSha256 ('0'*64) -BenchmarkProfileSha256 ('0'*64) `
        -InventorySha256 $Inventory.InventorySha256 -Candidate $Candidate -PinnedCandidateId $probeId
    $eligible=@($Candidate|Where-Object {$_.Eligible -eq $true}|Sort-Object CandidateId)
    $supported=@('LlamaCppCpu','LlamaCppCuda','LlamaCppRocm','LlamaCppVulkan','LlamaCppSycl','LlamaCppOpenVino')
    $unsupported=@($eligible|Where-Object {$_.Backend -cnotin $supported}|ForEach-Object CandidateId)
    if($unsupported.Count){throw ('AI_COMPUTE_BENCHMARK_SET_UNSUPPORTED: '+($unsupported -join ','))}

    $runtimeByHash=@{}
    foreach($path in $RuntimeDirectory){
        try{$root=[IO.Path]::GetFullPath($path).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)}catch{throw 'AI_COMPUTE_BENCHMARK_RUNTIME_INVALID'}
        try{$runtime=@(Find-LabLlamaCppRuntime -SearchRoot $root|Where-Object InstallationPath -EQ $root)}catch{throw 'AI_COMPUTE_BENCHMARK_RUNTIME_INVALID'}
        if($runtime.Count -ne 1){throw 'AI_COMPUTE_BENCHMARK_RUNTIME_INVALID'}
        $package=Get-LabAiRuntimePackageSha256 -Runtime $runtime[0];$hash=[string]$package.RuntimeSha256
        if($runtimeByHash.ContainsKey($hash)){throw "AI_COMPUTE_BENCHMARK_RUNTIME_AMBIGUOUS: $hash"}
        $runtimeByHash[$hash]=$root
    }
    $receipts=[Collections.Generic.List[object]]::new()
    foreach($item in $eligible){
        $runtimeHash=([string]$item.RuntimeSha256).ToLowerInvariant()
        if(-not $runtimeByHash.ContainsKey($runtimeHash)){throw "AI_COMPUTE_BENCHMARK_RUNTIME_MISSING: $($item.CandidateId)"}
        $arguments=@{Inventory=$Inventory;Candidate=$item;RuntimeDirectory=$runtimeByHash[$runtimeHash];ModelPath=$ModelPath;WorkloadKey=$WorkloadKey;Repetitions=$Repetitions;GeneratedTokens=$GeneratedTokens;BenchmarkMode=$BenchmarkMode;PromptTokens=$PromptTokens;BatchSize=$BatchSize;MicroBatchSize=$MicroBatchSize;TimeoutSeconds=$TimeoutSeconds}
        $receipt=if($BenchmarkAction){& $BenchmarkAction $arguments}else{Invoke-LabAiComputeBenchmark @arguments}
        if($null -eq $receipt){throw "AI_COMPUTE_BENCHMARK_SET_INCOMPLETE: $($item.CandidateId)"}
        $receipts.Add($receipt)
    }
    $modelHashes=@($receipts.ModelSha256|Sort-Object -Unique);$profileHashes=@($receipts.BenchmarkProfileSha256|Sort-Object -Unique)
    if($modelHashes.Count -ne 1 -or $profileHashes.Count -ne 1){throw 'AI_COMPUTE_BENCHMARK_SET_NOT_COMPARABLE'}
    $selection=Get-LabAiComputeSelection -WorkloadKey $WorkloadKey -ModelSha256 $modelHashes[0] -BenchmarkProfileSha256 $profileHashes[0] `
        -InventorySha256 $Inventory.InventorySha256 -Candidate $Candidate -Benchmark @($receipts)
    [PSCustomObject]@{Contract='SqlServerLab.AiComputeBenchmarkSet/1.0';Status='SELECTED';Selection=$selection;Benchmarks=@($receipts|Sort-Object CandidateId)}
}
