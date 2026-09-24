function Get-LabAiRuntimePackageSha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Runtime)
    $fields=@('Contract','Status','EvidenceStatus','Backend','DetectedBackends','Build','Package','InstallationPath','Invocation','CandidateAccelerators','SelectionEnvironment','PackageOrigin','ReleaseReference')
    Assert-LabAiComputeProperties $Runtime $fields 'AI_RUNTIME_RECEIPT_INVALID'
    Assert-LabAiComputeProperties $Runtime.Contract @('Name','Version') 'AI_RUNTIME_RECEIPT_INVALID'
    if([string]$Runtime.Contract.Name -cne 'SqlServerLab.LlamaCppRuntime' -or [string]$Runtime.Contract.Version -cne '1.0' -or
        [string]$Runtime.Status -cne 'INSTALLED' -or [string]$Runtime.EvidenceStatus -cne 'FILES_ONLY'){throw 'AI_RUNTIME_RECEIPT_INVALID'}
    $backendValues=@('LlamaCppOpenVino','LlamaCppCuda','LlamaCppRocm','LlamaCppVulkan','LlamaCppSycl')
    $backends=@($Runtime.DetectedBackends)
    if(@($backends|Where-Object {$_ -isnot [string] -or $_ -cnotin $backendValues}).Count -or @($backends|Sort-Object -Unique).Count -ne $backends.Count){throw 'AI_RUNTIME_RECEIPT_INVALID'}
    $expectedBackend=if($backends.Count -eq 0){'Unknown'}elseif($backends.Count -eq 1){$backends[0]}else{'Ambiguous'}
    try {
        $directory=Get-Item -LiteralPath ([string]$Runtime.InstallationPath) -Force -ErrorAction Stop
        $invocation=Get-Item -LiteralPath ([string]$Runtime.Invocation) -Force -ErrorAction Stop
    } catch {throw 'AI_RUNTIME_ARTIFACT_INVALID'}
    if($directory -isnot [IO.DirectoryInfo] -or $invocation -isnot [IO.FileInfo] -or ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
        $invocation.Directory.FullName -cne $directory.FullName -or $invocation.Name -cnotin @('llama-server.exe','llama-server')){throw 'AI_RUNTIME_ARTIFACT_INVALID'}
    $expectedBuild=$null;if($directory.Name -match '^llama-b(?<build>[0-9]+)-bin-.+$'){$parsed=0L;if([long]::TryParse($Matches.build,[ref]$parsed)){$expectedBuild=$parsed}}
    $actualBuild=if($null -eq $Runtime.Build){$null}else{ConvertTo-LabAiComputeInteger $Runtime.Build 0 ([long]::MaxValue) 'AI_RUNTIME_RECEIPT_INVALID'}
    $expectedAccelerators=@('CPU');if($backends.Count){$expectedAccelerators+='GPU'};if('LlamaCppOpenVino' -in $backends){$expectedAccelerators+='NPU'}
    $expectedSelection=if($expectedBackend -ceq 'LlamaCppOpenVino'){'GGML_OPENVINO_DEVICE'}else{$null}
    if([string]$Runtime.Backend -cne $expectedBackend -or [string]$Runtime.Package -cne $directory.Name -or $actualBuild -ne $expectedBuild -or
        (@($Runtime.CandidateAccelerators) -join ',') -cne ($expectedAccelerators -join ',') -or [string]$Runtime.SelectionEnvironment -cne [string]$expectedSelection -or
        [string]$Runtime.PackageOrigin -cne 'UNVERIFIED' -or [string]$Runtime.ReleaseReference -cne 'https://github.com/ggml-org/llama.cpp/releases'){throw 'AI_RUNTIME_RECEIPT_INVALID'}
    try {$packageFiles=@(Get-ChildItem -LiteralPath $directory.FullName -File -Force -ErrorAction Stop)}catch{throw 'AI_RUNTIME_ARTIFACT_INVALID'}
    $binaryFiles=@($packageFiles|Where-Object {$_.Name -ceq 'llama-server' -or $_.Name -match '(?i)(\.(exe|dll|dylib)$|\.so(?:\.[0-9]+)*$)'}|Sort-Object Name)
    if(-not $binaryFiles.Count -or $binaryFiles.Count -gt 256 -or $invocation.FullName -cnotin $binaryFiles.FullName){throw 'AI_RUNTIME_ARTIFACT_INVALID'}
    $backendFiles=@{
        LlamaCppOpenVino=@('ggml-openvino.dll','libggml-openvino.so*','libggml-openvino.dylib');LlamaCppCuda=@('ggml-cuda.dll','libggml-cuda.so*','libggml-cuda.dylib')
        LlamaCppRocm=@('ggml-hip.dll','libggml-hip.so*','libggml-hip.dylib');LlamaCppVulkan=@('ggml-vulkan.dll','libggml-vulkan.so*','libggml-vulkan.dylib')
        LlamaCppSycl=@('ggml-sycl.dll','libggml-sycl.so*','libggml-sycl.dylib')
    }
    $actualBackends=@($backendValues|Where-Object {$patterns=$backendFiles[$_];@($binaryFiles|Where-Object {$name=$_.Name;@($patterns|Where-Object {$name -like $_}).Count}).Count})
    if(($actualBackends -join ',') -cne (($backends|Sort-Object {$backendValues.IndexOf($_)}) -join ',')){throw 'AI_RUNTIME_ARTIFACT_INVALID'}
    $comparison=if($IsWindows){[StringComparison]::OrdinalIgnoreCase}else{[StringComparison]::Ordinal};$rootPrefix=$directory.FullName.TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar
    $binaryRecords=[Collections.Generic.List[object]]::new()
    foreach($file in $binaryFiles) {
        $target=$file
        if($file.Attributes -band [IO.FileAttributes]::ReparsePoint){try{$target=$file.ResolveLinkTarget($true)}catch{throw 'AI_RUNTIME_ARTIFACT_INVALID'}}
        if($target -isnot [IO.FileInfo] -or -not $target.FullName.StartsWith($rootPrefix,$comparison)){throw 'AI_RUNTIME_ARTIFACT_INVALID'}
        $binaryRecords.Add([PSCustomObject]@{Name=$file.Name;Path=$target.FullName})
    }
    $streams=[Collections.Generic.List[IO.FileStream]]::new();$evidence=[Collections.Generic.List[object]]::new()
    try {
        foreach($record in $binaryRecords){$streams.Add([IO.File]::Open($record.Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read))}
        for($index=0;$index -lt $binaryRecords.Count;$index++) {
            $hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($streams[$index])).ToLowerInvariant()
            $evidence.Add([PSCustomObject]@{Name=$binaryRecords[$index].Name;Length=[long]$streams[$index].Length;Sha256=$hash})
        }
        $identity=[ordered]@{Contract='SqlServerLab.AiRuntimePackage/1.0';Files=@($evidence)}
        [PSCustomObject]@{RuntimeSha256=(Get-LabAiPlanKey $identity);DetectedBackends=@($backends|Sort-Object)}
    } catch {throw 'AI_RUNTIME_ARTIFACT_INVALID'}
    finally {foreach($stream in $streams){$stream.Dispose()}}
}

function Get-LabAiRuntimeCapabilitySet {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Inventory,[Parameter(Mandatory)][ValidateCount(1,16)][object[]]$Runtime)
    $Inventory=Assert-LabAiComputeInventoryReceipt -Inventory $Inventory
    $capabilities=[Collections.Generic.List[object]]::new();$runtimeHashes=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $capabilityKeys=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    function Add-Capability([string]$Backend,[string]$Hash,[string]$Kind,[string[]]$Vendors) {
        $matches=@($Inventory.Devices|Where-Object {$_.Kind -ceq $Kind -and ('*' -in $Vendors -or $_.VendorId -in $Vendors)})
        $eligible=$matches.Count -gt 0;$maximum=[Math]::Max(1,[Math]::Min(16,$matches.Count));$key=$Backend+'|'+$Hash+'|'+$Kind+'|'+($Vendors -join ',')
        $blockers=[Collections.Generic.List[string]]::new();if(-not $eligible){$blockers.Add('AI_RUNTIME_COMPATIBLE_DEVICE_NOT_FOUND')}
        if($capabilityKeys.Add($key)){$capabilities.Add([PSCustomObject]@{Backend=$Backend;RuntimeSha256=$Hash;DeviceKinds=@($Kind);VendorIds=@($Vendors);MinimumDeviceCount=1;MaximumDeviceCount=$maximum;AllowMixedKinds=$false;Eligible=$eligible;Blockers=@($blockers)})}
    }
    foreach($runtimeReceipt in $Runtime) {
        $package=Get-LabAiRuntimePackageSha256 -Runtime $runtimeReceipt;$hash=[string]$package.RuntimeSha256;$null=$runtimeHashes.Add($hash)
        Add-Capability LlamaCppCpu $hash CPU @('*')
        foreach($backend in $package.DetectedBackends) {
            switch($backend) {
                LlamaCppCuda {Add-Capability $backend $hash GPU @('10de')}
                LlamaCppRocm {Add-Capability $backend $hash GPU @('1002')}
                LlamaCppVulkan {Add-Capability $backend $hash GPU @('*')}
                LlamaCppSycl {Add-Capability $backend $hash GPU @('8086')}
                LlamaCppOpenVino {Add-Capability $backend $hash CPU @('*');Add-Capability $backend $hash GPU @('8086');Add-Capability $backend $hash NPU @('8086')}
            }
        }
    }
    $ordered=@($capabilities|Sort-Object Backend,RuntimeSha256,{($_.DeviceKinds -join ',')},{($_.VendorIds -join ',')})
    if(-not @($ordered|Where-Object Eligible).Count){throw 'AI_RUNTIME_CAPABILITY_SET_EMPTY'}
    $identity=[ordered]@{Contract='SqlServerLab.AiRuntimeCapabilitySet/1.0';InventorySha256=$Inventory.InventorySha256;Capabilities=$ordered}
    [PSCustomObject]@{Contract='SqlServerLab.AiRuntimeCapabilitySet/1.0';Status='COMPLETE';EvidenceStatus='FILES_HASHED_NOT_EXECUTED';InventorySha256=$Inventory.InventorySha256;RuntimeCount=$runtimeHashes.Count;Capabilities=$ordered;CapabilitySetSha256=(Get-LabAiPlanKey $identity)}
}
