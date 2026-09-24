function ConvertTo-LabAiInventoryName {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Value)
    $name=($Value -replace '[\x00-\x1f\x7f]',' ' -replace '\s+',' ').Trim()
    if(-not $name){return 'Unknown device'}
    if($name.Length -gt 128){return $name.Substring(0,128)}
    return $name
}

function Get-LabAiInventoryToken {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Value,[Parameter(Mandatory)][string]$FallbackSeed)
    $token=($Value.Trim().ToLowerInvariant() -replace '^0x','')
    if($token -match '^[a-z0-9][a-z0-9._-]{0,63}$'){return $token}
    $bytes=[Text.Encoding]::UTF8.GetBytes($FallbackSeed)
    $hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
    return 'id-'+$hash.Substring(0,16)
}

function Get-LabAiWindowsHardwareIdentity {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$InstanceId,[AllowEmptyString()][string]$Name)
    $vendor=[regex]::Match($InstanceId,'(?i)VEN_([0-9a-f]{4})')
    $product=[regex]::Match($InstanceId,'(?i)DEV_([0-9a-f]{4})')
    return [PSCustomObject]@{
        VendorId=Get-LabAiInventoryToken $(if($vendor.Success){$vendor.Groups[1].Value}else{''}) ($Name+'|vendor')
        ProductId=Get-LabAiInventoryToken $(if($product.Success){$product.Groups[1].Value}else{''}) ($Name+'|product')
    }
}

function Get-LabAiComputeWindowsProbe {
    [CmdletBinding()]
    param()
    $devices=[Collections.Generic.List[object]]::new();$coverage=[Collections.Generic.List[object]]::new()
    try {
        foreach($cpu in @(Get-CimInstance -ClassName Win32_Processor -Property DeviceID,Manufacturer,Name -ErrorAction Stop)) {
            $vendor=if([string]$cpu.Manufacturer -match '(?i)intel'){'8086'}elseif([string]$cpu.Manufacturer -match '(?i)(amd|advanced micro devices)'){'1022'}elseif([string]$cpu.Manufacturer -match '(?i)qualcomm'){'17cb'}else{''}
            $name=ConvertTo-LabAiInventoryName ([string]$cpu.Name)
            $devices.Add([PSCustomObject]@{Kind='CPU';SourceId=[string]$cpu.DeviceID;VendorId=(Get-LabAiInventoryToken $vendor ($name+'|vendor'));ProductId=(Get-LabAiInventoryToken '' ($name+'|product'));DisplayName=$name})
        }
        $coverage.Add([PSCustomObject]@{Kind='CPU';Status='VERIFIED';Method='WINDOWS_CIM_PROCESSOR'})
    } catch {$coverage.Add([PSCustomObject]@{Kind='CPU';Status='UNAVAILABLE';Method='WINDOWS_CIM_PROCESSOR'})}
    try {
        foreach($gpu in @(Get-CimInstance -ClassName Win32_VideoController -Property PNPDeviceID,Name,ConfigManagerErrorCode -ErrorAction Stop|Where-Object {$null -eq $_.ConfigManagerErrorCode -or $_.ConfigManagerErrorCode -eq 0})) {
            $name=ConvertTo-LabAiInventoryName ([string]$gpu.Name);$ids=Get-LabAiWindowsHardwareIdentity ([string]$gpu.PNPDeviceID) $name
            $devices.Add([PSCustomObject]@{Kind='GPU';SourceId=[string]$gpu.PNPDeviceID;VendorId=$ids.VendorId;ProductId=$ids.ProductId;DisplayName=$name})
        }
        $coverage.Add([PSCustomObject]@{Kind='GPU';Status='VERIFIED';Method='WINDOWS_CIM_VIDEO'})
    } catch {$coverage.Add([PSCustomObject]@{Kind='GPU';Status='UNAVAILABLE';Method='WINDOWS_CIM_VIDEO'})}
    try {
        if(-not (Get-Command Get-PnpDevice -ErrorAction SilentlyContinue)){throw 'PNP_CMDLET_UNAVAILABLE'}
        foreach($npu in @(Get-PnpDevice -PresentOnly -Class ComputeAccelerator -ErrorAction Stop)) {
            $name=ConvertTo-LabAiInventoryName ([string]$npu.FriendlyName);$ids=Get-LabAiWindowsHardwareIdentity ([string]$npu.InstanceId) $name
            $devices.Add([PSCustomObject]@{Kind='NPU';SourceId=[string]$npu.InstanceId;VendorId=$ids.VendorId;ProductId=$ids.ProductId;DisplayName=$name})
        }
        $coverage.Add([PSCustomObject]@{Kind='NPU';Status='VERIFIED';Method='WINDOWS_PNP_COMPUTE_ACCELERATOR'})
    } catch {$coverage.Add([PSCustomObject]@{Kind='NPU';Status='UNAVAILABLE';Method='WINDOWS_PNP_COMPUTE_ACCELERATOR'})}
    return [PSCustomObject]@{Platform='Windows';Coverage=@($coverage);Devices=@($devices)}
}

function Get-LabAiComputeLinuxProbe {
    [CmdletBinding()]
    param()
    $devices=[Collections.Generic.List[object]]::new();$coverage=[Collections.Generic.List[object]]::new()
    try {
        $cpuInfo=[IO.File]::ReadAllText('/proc/cpuinfo')
        $name=ConvertTo-LabAiInventoryName ([regex]::Match($cpuInfo,'(?im)^(?:model name|hardware)\s*:\s*(.+)$').Groups[1].Value)
        $vendorText=[regex]::Match($cpuInfo,'(?im)^vendor_id\s*:\s*(.+)$').Groups[1].Value
        $vendor=if($vendorText -match 'GenuineIntel'){'8086'}elseif($vendorText -match 'AuthenticAMD'){'1022'}elseif($name -match '(?i)qualcomm'){'17cb'}else{''}
        $devices.Add([PSCustomObject]@{Kind='CPU';SourceId='cpu-package-0';VendorId=(Get-LabAiInventoryToken $vendor ($name+'|vendor'));ProductId=(Get-LabAiInventoryToken '' ($name+'|product'));DisplayName=$name})
        $coverage.Add([PSCustomObject]@{Kind='CPU';Status='VERIFIED';Method='LINUX_PROC_CPUINFO'})
    } catch {$coverage.Add([PSCustomObject]@{Kind='CPU';Status='UNAVAILABLE';Method='LINUX_PROC_CPUINFO'})}
    try {
        foreach($card in @(Get-ChildItem -LiteralPath '/sys/class/drm' -Directory -ErrorAction Stop|Where-Object Name -Match '^card[0-9]+$')) {
            $devicePath=Join-Path $card.FullName 'device';if(-not (Test-Path -LiteralPath $devicePath -PathType Container)){continue}
            $resolved=(Resolve-Path -LiteralPath $devicePath -ErrorAction Stop).Path
            $vendor=[IO.File]::ReadAllText((Join-Path $devicePath 'vendor')).Trim();$product=[IO.File]::ReadAllText((Join-Path $devicePath 'device')).Trim()
            $devices.Add([PSCustomObject]@{Kind='GPU';SourceId=$resolved;VendorId=(Get-LabAiInventoryToken $vendor ($resolved+'|vendor'));ProductId=(Get-LabAiInventoryToken $product ($resolved+'|product'));DisplayName=(ConvertTo-LabAiInventoryName "PCI display $vendor`:$product")})
        }
        $coverage.Add([PSCustomObject]@{Kind='GPU';Status='VERIFIED';Method='LINUX_DRM_SYSFS'})
    } catch {$coverage.Add([PSCustomObject]@{Kind='GPU';Status='UNAVAILABLE';Method='LINUX_DRM_SYSFS'})}
    try {
        if(Test-Path -LiteralPath '/sys/class/accel' -PathType Container) {
            foreach($accel in @(Get-ChildItem -LiteralPath '/sys/class/accel' -Directory -ErrorAction Stop|Where-Object Name -Match '^accel[0-9]+$')) {
                $devicePath=Join-Path $accel.FullName 'device';$resolved=(Resolve-Path -LiteralPath $devicePath -ErrorAction Stop).Path
                $vendorPath=Join-Path $devicePath 'vendor';$productPath=Join-Path $devicePath 'device'
                $vendor=if(Test-Path -LiteralPath $vendorPath){[IO.File]::ReadAllText($vendorPath).Trim()}else{''}
                $product=if(Test-Path -LiteralPath $productPath){[IO.File]::ReadAllText($productPath).Trim()}else{''}
                $devices.Add([PSCustomObject]@{Kind='NPU';SourceId=$resolved;VendorId=(Get-LabAiInventoryToken $vendor ($resolved+'|vendor'));ProductId=(Get-LabAiInventoryToken $product ($resolved+'|product'));DisplayName=(ConvertTo-LabAiInventoryName "Compute accelerator $vendor`:$product")})
            }
        }
        $coverage.Add([PSCustomObject]@{Kind='NPU';Status='VERIFIED';Method='LINUX_ACCEL_SYSFS'})
    } catch {$coverage.Add([PSCustomObject]@{Kind='NPU';Status='UNAVAILABLE';Method='LINUX_ACCEL_SYSFS'})}
    return [PSCustomObject]@{Platform='Linux';Coverage=@($coverage);Devices=@($devices)}
}

function Get-LabAiComputeHostProbe {
    [CmdletBinding()]
    param()
    if($IsWindows){return Get-LabAiComputeWindowsProbe}
    if($IsLinux){return Get-LabAiComputeLinuxProbe}
    return [PSCustomObject]@{Platform='Unsupported';Coverage=@('CPU','GPU','NPU'|ForEach-Object {[PSCustomObject]@{Kind=$_;Status='UNAVAILABLE';Method='PLATFORM_UNSUPPORTED'}});Devices=@()}
}

function Get-LabAiComputeInventory {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$ProbeResult)
    Assert-LabAiComputeProperties $ProbeResult @('Platform','Coverage','Devices') 'AI_COMPUTE_INVENTORY_PROBE_INVALID'
    $platform=[string]$ProbeResult.Platform;if($platform -cnotin @('Windows','Linux','Unsupported')){throw 'AI_COMPUTE_INVENTORY_PROBE_INVALID'}
    $coverageFields=@('Kind','Status','Method');$coverage=[Collections.Generic.List[object]]::new();$kinds=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($entry in @($ProbeResult.Coverage)) {
        Assert-LabAiComputeProperties $entry $coverageFields 'AI_COMPUTE_INVENTORY_COVERAGE_INVALID'
        $kind=[string]$entry.Kind;$status=[string]$entry.Status;$method=[string]$entry.Method
        if($kind -cnotin @('CPU','GPU','NPU') -or -not $kinds.Add($kind) -or $status -cnotin @('VERIFIED','UNAVAILABLE') -or $method -notmatch '^[A-Z][A-Z0-9_]{2,63}$'){throw 'AI_COMPUTE_INVENTORY_COVERAGE_INVALID'}
        $coverage.Add([PSCustomObject]@{Kind=$kind;Status=$status;Method=$method})
    }
    if($kinds.Count -ne 3){throw 'AI_COMPUTE_INVENTORY_COVERAGE_INVALID'}
    $deviceFields=@('Kind','SourceId','VendorId','ProductId','DisplayName');$raw=[Collections.Generic.List[object]]::new();$sourceIds=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($item in @($ProbeResult.Devices)) {
        Assert-LabAiComputeProperties $item $deviceFields 'AI_COMPUTE_INVENTORY_DEVICE_INVALID'
        $kind=[string]$item.Kind;$sourceId=[string]$item.SourceId
        if($kind -cnotin @('CPU','GPU','NPU') -or -not $sourceId -or -not $sourceIds.Add($sourceId)){throw 'AI_COMPUTE_INVENTORY_DEVICE_INVALID'}
        $coverageMatch=@($coverage|Where-Object Kind -CEQ $kind)[0]
        if($coverageMatch.Status -ne 'VERIFIED'){throw 'AI_COMPUTE_INVENTORY_DEVICE_WITHOUT_COVERAGE'}
        $raw.Add([PSCustomObject]@{Kind=$kind;SourceId=$sourceId;VendorId=(Get-LabAiInventoryToken ([string]$item.VendorId) ($sourceId+'|vendor'));ProductId=(Get-LabAiInventoryToken ([string]$item.ProductId) ($sourceId+'|product'));DisplayName=(ConvertTo-LabAiInventoryName ([string]$item.DisplayName))})
    }
    $ordered=@($raw|Sort-Object {[Convert]::ToHexString([Text.Encoding]::UTF8.GetBytes($_.Kind+'|'+$_.VendorId+'|'+$_.ProductId+'|'+$_.SourceId))})
    $ordinals=@{};$devices=[Collections.Generic.List[object]]::new()
    foreach($item in $ordered) {
        $key=$item.Kind+'|'+$item.VendorId+'|'+$item.ProductId;$ordinal=if($ordinals.ContainsKey($key)){[int]$ordinals[$key]}else{0};$ordinals[$key]=$ordinal+1
        $devices.Add([PSCustomObject]@{Kind=$item.Kind;DeviceId=($item.Kind.ToLowerInvariant()+':'+$item.VendorId+':'+$item.ProductId+':'+$ordinal);VendorId=$item.VendorId;ProductId=$item.ProductId;DisplayName=$item.DisplayName})
    }
    $coverageArray=@($coverage|Sort-Object Kind);$deviceArray=@($devices)
    $blockers=[Collections.Generic.List[string]]::new()
    foreach($entry in @($coverageArray|Where-Object Status -ne VERIFIED)){$blockers.Add('AI_COMPUTE_INVENTORY_'+$entry.Kind+'_UNAVAILABLE')}
    if(-not @($deviceArray|Where-Object Kind -eq CPU).Count){$blockers.Add('AI_COMPUTE_INVENTORY_CPU_MISSING')}
    $status=if($blockers.Count){'INCOMPLETE'}else{'COMPLETE'}
    $identity=[ordered]@{Contract='SqlServerLab.AiComputeInventory/1.0';Platform=$platform;Coverage=$coverageArray;Devices=@($deviceArray|Select-Object Kind,DeviceId,VendorId,ProductId)}
    [PSCustomObject]@{Contract='SqlServerLab.AiComputeInventory/1.0';Status=$status;Platform=$platform;Coverage=$coverageArray;Devices=$deviceArray;Blockers=@($blockers|Sort-Object -Unique);InventorySha256=if($status -eq 'COMPLETE'){Get-LabAiPlanKey $identity}else{$null}}
}

function Get-LabAiComputeCandidateSet {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Inventory,
        [Parameter(Mandatory)][ValidateCount(1,16)][object[]]$RuntimeCapability
    )
    Assert-LabAiComputeProperties $Inventory @('Contract','Status','Platform','Coverage','Devices','Blockers','InventorySha256') 'AI_COMPUTE_INVENTORY_RECEIPT_INVALID'
    if([string]$Inventory.Contract -cne 'SqlServerLab.AiComputeInventory/1.0' -or [string]$Inventory.Status -cne 'COMPLETE' -or [string]$Inventory.Platform -cnotin @('Windows','Linux') -or
        [string]$Inventory.InventorySha256 -notmatch '^[a-f0-9]{64}$' -or @($Inventory.Blockers).Count){throw 'AI_COMPUTE_INVENTORY_INCOMPLETE'}
    $coverageFields=@('Kind','Status','Method');$coverageKinds=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal);$coverage=[Collections.Generic.List[object]]::new()
    foreach($entry in @($Inventory.Coverage)) {
        Assert-LabAiComputeProperties $entry $coverageFields 'AI_COMPUTE_INVENTORY_RECEIPT_INVALID'
        $kind=[string]$entry.Kind;$status=[string]$entry.Status;$method=[string]$entry.Method
        if($kind -cnotin @('CPU','GPU','NPU') -or -not $coverageKinds.Add($kind) -or $status -cne 'VERIFIED' -or $method -notmatch '^[A-Z][A-Z0-9_]{2,63}$'){throw 'AI_COMPUTE_INVENTORY_RECEIPT_INVALID'}
        $coverage.Add([PSCustomObject]@{Kind=$kind;Status=$status;Method=$method})
    }
    if($coverageKinds.Count -ne 3){throw 'AI_COMPUTE_INVENTORY_RECEIPT_INVALID'}
    $probeDevices=[Collections.Generic.List[object]]::new()
    $deviceIds=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($device in @($Inventory.Devices)) {
        Assert-LabAiComputeProperties $device @('Kind','DeviceId','VendorId','ProductId','DisplayName') 'AI_COMPUTE_INVENTORY_RECEIPT_INVALID'
        $kind=[string]$device.Kind;$deviceId=[string]$device.DeviceId;$vendorId=[string]$device.VendorId;$productId=[string]$device.ProductId;$name=[string]$device.DisplayName
        $expectedPrefix=$kind.ToLowerInvariant()+':'+$vendorId+':'+$productId+':'
        if($kind -cnotin @('CPU','GPU','NPU') -or $vendorId -notmatch '^[a-z0-9][a-z0-9._-]{0,63}$' -or $productId -notmatch '^[a-z0-9][a-z0-9._-]{0,63}$' -or
            $deviceId -notmatch '^(cpu|gpu|npu):[a-z0-9][a-z0-9._-]{0,63}:[a-z0-9][a-z0-9._-]{0,63}:[0-9]+$' -or -not $deviceId.StartsWith($expectedPrefix,[StringComparison]::Ordinal) -or
            -not $deviceIds.Add($deviceId) -or -not $name -or $name.Length -gt 128 -or (ConvertTo-LabAiInventoryName $name) -cne $name){throw 'AI_COMPUTE_INVENTORY_RECEIPT_INVALID'}
        $probeDevices.Add([PSCustomObject]@{Kind=[string]$device.Kind;DeviceId=[string]$device.DeviceId;VendorId=[string]$device.VendorId;ProductId=[string]$device.ProductId})
    }
    if(-not @($probeDevices|Where-Object Kind -CEQ CPU).Count){throw 'AI_COMPUTE_INVENTORY_RECEIPT_INVALID'}
    $identity=[ordered]@{Contract='SqlServerLab.AiComputeInventory/1.0';Platform=[string]$Inventory.Platform;Coverage=@($coverage);Devices=$probeDevices}
    if((Get-LabAiPlanKey $identity) -cne [string]$Inventory.InventorySha256){throw 'AI_COMPUTE_INVENTORY_HASH_MISMATCH'}
    $backendValues=@('LlamaCppCuda','LlamaCppOpenVino','LlamaCppRocm','LlamaCppSnapdragonOpenCl','LlamaCppSnapdragonHexagon','OpenVinoModelServer','Ollama')
    $fields=@('Backend','RuntimeSha256','DeviceKinds','VendorIds','MinimumDeviceCount','MaximumDeviceCount','AllowMixedKinds','Eligible','Blockers')
    $capabilityIds=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal);$candidates=[Collections.Generic.List[object]]::new()
    foreach($capability in $RuntimeCapability) {
        Assert-LabAiComputeProperties $capability $fields 'AI_COMPUTE_RUNTIME_CAPABILITY_INVALID'
        $backend=[string]$capability.Backend;$runtimeHash=[string]$capability.RuntimeSha256
        if($backend -cnotin $backendValues -or $runtimeHash -notmatch '^[a-fA-F0-9]{64}$' -or $capability.AllowMixedKinds -isnot [bool] -or $capability.Eligible -isnot [bool]){throw 'AI_COMPUTE_RUNTIME_CAPABILITY_INVALID'}
        $runtimeHash=$runtimeHash.ToLowerInvariant();if(-not $capabilityIds.Add($backend+'|'+$runtimeHash)){throw 'AI_COMPUTE_RUNTIME_CAPABILITY_DUPLICATE'}
        $deviceKinds=@($capability.DeviceKinds)
        if(-not $deviceKinds.Count -or @($deviceKinds|Where-Object {$_ -isnot [string] -or $_ -cnotin @('CPU','GPU','NPU')}).Count -or @($deviceKinds|Sort-Object -Unique).Count -ne $deviceKinds.Count){throw 'AI_COMPUTE_RUNTIME_CAPABILITY_INVALID'}
        $vendorIds=@($capability.VendorIds)
        if(-not $vendorIds.Count -or @($vendorIds|Where-Object {$_ -isnot [string] -or ($_ -cne '*' -and $_ -notmatch '^[a-z0-9][a-z0-9._-]{0,63}$')}).Count -or @($vendorIds|Sort-Object -Unique).Count -ne $vendorIds.Count -or ('*' -in $vendorIds -and $vendorIds.Count -ne 1)){throw 'AI_COMPUTE_RUNTIME_CAPABILITY_INVALID'}
        $errorCode='AI_COMPUTE_RUNTIME_CAPABILITY_INVALID';$minimum=[int](ConvertTo-LabAiComputeInteger $capability.MinimumDeviceCount 1 16 $errorCode);$maximum=[int](ConvertTo-LabAiComputeInteger $capability.MaximumDeviceCount 1 16 $errorCode)
        if($minimum -gt $maximum){throw $errorCode}
        $blockers=@($capability.Blockers)
        if(@($blockers|Where-Object {$_ -isnot [string] -or $_ -notmatch '^[A-Z][A-Z0-9_]{2,127}$'}).Count -or ([bool]$capability.Eligible -and $blockers.Count) -or (-not [bool]$capability.Eligible -and -not $blockers.Count)){throw 'AI_COMPUTE_RUNTIME_CAPABILITY_INVALID'}
        $eligibleDevices=@($Inventory.Devices|Where-Object {$_.Kind -in $deviceKinds -and ('*' -in $vendorIds -or $_.VendorId -in $vendorIds)}|Sort-Object {[Convert]::ToHexString([Text.Encoding]::UTF8.GetBytes($_.DeviceId))})
        if([bool]$capability.Eligible -and $eligibleDevices.Count -lt $minimum){throw "AI_COMPUTE_RUNTIME_CAPABILITY_WITHOUT_DEVICE: $backend"}
        if($eligibleDevices.Count -gt 16){throw 'AI_COMPUTE_CANDIDATE_SET_TOO_LARGE'}
        $upper=[Math]::Min($maximum,$eligibleDevices.Count);$maskLimit=1 -shl $eligibleDevices.Count
        for($mask=1;$mask -lt $maskLimit;$mask++) {
            $selectedDevices=[Collections.Generic.List[object]]::new()
            for($index=0;$index -lt $eligibleDevices.Count;$index++){if($mask -band (1 -shl $index)){$selectedDevices.Add([PSCustomObject]@{Kind=$eligibleDevices[$index].Kind;DeviceId=$eligibleDevices[$index].DeviceId})}}
            if($selectedDevices.Count -lt $minimum -or $selectedDevices.Count -gt $upper){continue}
            if(-not [bool]$capability.AllowMixedKinds -and @($selectedDevices.Kind|Sort-Object -Unique).Count -gt 1){continue}
            $deviceKey=($selectedDevices|ForEach-Object {$_.Kind+':'+$_.DeviceId}) -join ','
            $deviceHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($deviceKey))).ToLowerInvariant().Substring(0,16)
            $candidateId=($backend.ToLowerInvariant() -replace '[^a-z0-9]+','-').Trim('-')+'-'+$runtimeHash.Substring(0,12)+'-'+$deviceHash
            $candidates.Add([PSCustomObject]@{CandidateId=$candidateId;Backend=$backend;RuntimeSha256=$runtimeHash;Devices=@($selectedDevices);Eligible=[bool]$capability.Eligible;Blockers=@($blockers|Sort-Object -Unique)})
            if($candidates.Count -gt 64){throw 'AI_COMPUTE_CANDIDATE_SET_TOO_LARGE'}
        }
    }
    if(-not $candidates.Count){throw 'AI_COMPUTE_CANDIDATE_SET_EMPTY'}
    $candidateArray=@($candidates|Sort-Object {[Convert]::ToHexString([Text.Encoding]::UTF8.GetBytes($_.CandidateId))})
    $setIdentity=[ordered]@{Contract='SqlServerLab.AiComputeCandidateSet/1.0';InventorySha256=[string]$Inventory.InventorySha256;Candidates=$candidateArray}
    [PSCustomObject]@{Contract='SqlServerLab.AiComputeCandidateSet/1.0';Status='COMPLETE';InventorySha256=[string]$Inventory.InventorySha256;Candidates=$candidateArray;CandidateSetSha256=(Get-LabAiPlanKey $setIdentity)}
}
