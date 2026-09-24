function Assert-LabAiComputeProperties {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$InputObject,
        [Parameter(Mandatory)][string[]]$Required,
        [Parameter(Mandatory)][string]$ErrorCode
    )
    if ($null -eq $InputObject) { throw $ErrorCode }
    $names = @($InputObject.PSObject.Properties.Name)
    if (@($Required | Where-Object { $_ -notin $names }).Count -or
        @($names | Where-Object { $_ -notin $Required }).Count) { throw $ErrorCode }
}

function Test-LabAiComputeFiniteNumber {
    [CmdletBinding()]
    param($Value)
    if($null -eq $Value -or $Value -is [bool] -or $Value -is [char] -or $Value -is [string]){return $false}
    try { $number = [double]$Value } catch { return $false }
    return [double]::IsFinite($number)
}

function ConvertTo-LabAiComputeInteger {
    [CmdletBinding()]
    param($Value,[long]$Minimum,[long]$Maximum,[string]$ErrorCode)
    if(-not (Test-LabAiComputeFiniteNumber $Value)){throw $ErrorCode}
    try{$number=[decimal]$Value}catch{throw $ErrorCode}
    if($number -lt $Minimum -or $number -gt $Maximum -or [decimal]::Truncate($number) -ne $number){throw $ErrorCode}
    return [long]$number
}

function Get-LabAiComputeSelection {
    [CmdletBinding(DefaultParameterSetName='Auto')]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[a-z0-9][a-z0-9._-]{0,127}$')][string]$WorkloadKey,
        [Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ModelSha256,
        [Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$BenchmarkProfileSha256,
        [Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$InventorySha256,
        [Parameter(Mandatory)][ValidateCount(1,64)][object[]]$Candidate,
        [Parameter(Mandatory,ParameterSetName='Auto')][ValidateCount(1,64)][object[]]$Benchmark,
        [Parameter(Mandatory,ParameterSetName='Pinned')][ValidatePattern('^[a-z0-9][a-z0-9._-]{0,127}$')][string]$PinnedCandidateId
    )
    $modelHash=$ModelSha256.ToLowerInvariant();$profileHash=$BenchmarkProfileSha256.ToLowerInvariant();$inventoryHash=$InventorySha256.ToLowerInvariant()
    $candidateFields=@('CandidateId','Backend','RuntimeSha256','Devices','Eligible','Blockers')
    $deviceFields=@('Kind','DeviceId')
    $backendValues=@('LlamaCppCpu','LlamaCppCuda','LlamaCppOpenVino','LlamaCppRocm','LlamaCppVulkan','LlamaCppSycl','LlamaCppSnapdragonOpenCl','LlamaCppSnapdragonHexagon','OpenVinoModelServer','Ollama')
    $normalizedCandidates=[Collections.Generic.List[object]]::new()
    $candidateIds=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $candidateIdentities=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($item in $Candidate) {
        Assert-LabAiComputeProperties $item $candidateFields 'AI_COMPUTE_CANDIDATE_INVALID'
        $id=[string]$item.CandidateId;$runtimeHash=[string]$item.RuntimeSha256;$backend=[string]$item.Backend
        if($id -notmatch '^[a-z0-9][a-z0-9._-]{0,127}$' -or -not $candidateIds.Add($id) -or
            $backend -cnotin $backendValues -or $runtimeHash -notmatch '^[a-fA-F0-9]{64}$' -or
            $item.Eligible -isnot [bool]) { throw 'AI_COMPUTE_CANDIDATE_INVALID' }
        $devices=@($item.Devices)
        if($devices.Count -lt 1 -or $devices.Count -gt 16){throw 'AI_COMPUTE_DEVICE_SET_INVALID'}
        $normalizedDevices=[Collections.Generic.List[object]]::new();$deviceIds=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach($device in $devices) {
            Assert-LabAiComputeProperties $device $deviceFields 'AI_COMPUTE_DEVICE_INVALID'
            $kind=[string]$device.Kind;$deviceId=[string]$device.DeviceId
            if($kind -cnotin @('CPU','GPU','NPU') -or $deviceId -notmatch '^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$' -or
                -not $deviceIds.Add($deviceId)){throw 'AI_COMPUTE_DEVICE_INVALID'}
            $normalizedDevices.Add([PSCustomObject]@{Kind=$kind;DeviceId=$deviceId})
        }
        $normalizedDeviceArray=@($normalizedDevices|Sort-Object {[Convert]::ToHexString([Text.Encoding]::UTF8.GetBytes($_.Kind+':'+$_.DeviceId))})
        $blockers=@($item.Blockers)
        if(@($blockers|Where-Object {$_ -isnot [string] -or $_ -notmatch '^[A-Z][A-Z0-9_]{2,127}$'}).Count -or
            ([bool]$item.Eligible -and $blockers.Count) -or (-not [bool]$item.Eligible -and -not $blockers.Count)) {
            throw 'AI_COMPUTE_CANDIDATE_ELIGIBILITY_INVALID'
        }
        $identity=$backend+'|'+$runtimeHash.ToLowerInvariant()+'|'+(($normalizedDeviceArray|ForEach-Object {$_.Kind+':'+$_.DeviceId}) -join ',')
        if(-not $candidateIdentities.Add($identity)){throw 'AI_COMPUTE_CANDIDATE_DUPLICATE'}
        $normalizedCandidates.Add([PSCustomObject]@{CandidateId=$id;Backend=$backend;RuntimeSha256=$runtimeHash.ToLowerInvariant();Devices=$normalizedDeviceArray;Eligible=[bool]$item.Eligible;Blockers=@($blockers|Sort-Object -Unique)})
    }
    $candidateArray=@($normalizedCandidates|Sort-Object {[Convert]::ToHexString([Text.Encoding]::UTF8.GetBytes($_.CandidateId))})
    $eligible=@($candidateArray|Where-Object Eligible)
    if(-not $eligible.Count){throw 'AI_COMPUTE_NO_ELIGIBLE_CANDIDATE'}
    $excluded=@($candidateArray|Where-Object {-not $_.Eligible}|ForEach-Object {[PSCustomObject]@{CandidateId=$_.CandidateId;Blockers=$_.Blockers}})

    $ranked=@();$selected=$null;$selectedBenchmark=$null
    if($PSCmdlet.ParameterSetName -eq 'Pinned') {
        $matches=@($candidateArray|Where-Object CandidateId -CEQ $PinnedCandidateId)
        if($matches.Count -ne 1){throw "AI_COMPUTE_PINNED_CANDIDATE_NOT_FOUND: $PinnedCandidateId"}
        if(-not $matches[0].Eligible){throw "AI_COMPUTE_PINNED_CANDIDATE_INELIGIBLE: $PinnedCandidateId"}
        $selected=$matches[0]
    }
    else {
        $benchmarkFields=@('CandidateId','WorkloadKey','ModelSha256','BenchmarkProfileSha256','InventorySha256','RuntimeSha256','ThroughputPerSecond','P95LatencyMilliseconds','PeakWorkingSetBytes','SuccessfulIterations','TotalIterations','EvidenceStatus')
        $benchmarksById=@{}
        foreach($measurement in $Benchmark) {
            Assert-LabAiComputeProperties $measurement $benchmarkFields 'AI_COMPUTE_BENCHMARK_INVALID'
            $id=[string]$measurement.CandidateId
            $candidateMatch=@($candidateArray|Where-Object CandidateId -CEQ $id)
            if($candidateMatch.Count -ne 1){throw "AI_COMPUTE_BENCHMARK_CANDIDATE_UNKNOWN: $id"}
            if(-not $candidateMatch[0].Eligible){throw "AI_COMPUTE_BENCHMARK_CANDIDATE_INELIGIBLE: $id"}
            if($benchmarksById.ContainsKey($id)){throw "AI_COMPUTE_BENCHMARK_DUPLICATE: $id"}
            $measurementModel=[string]$measurement.ModelSha256;$measurementProfile=[string]$measurement.BenchmarkProfileSha256
            $measurementInventory=[string]$measurement.InventorySha256;$measurementRuntime=[string]$measurement.RuntimeSha256
            if($measurementModel -notmatch '^[a-fA-F0-9]{64}$' -or $measurementProfile -notmatch '^[a-fA-F0-9]{64}$' -or
                $measurementInventory -notmatch '^[a-fA-F0-9]{64}$' -or $measurementRuntime -notmatch '^[a-fA-F0-9]{64}$' -or
                [string]$measurement.WorkloadKey -cne $WorkloadKey -or $measurementModel.ToLowerInvariant() -cne $modelHash -or
                $measurementProfile.ToLowerInvariant() -cne $profileHash -or $measurementInventory.ToLowerInvariant() -cne $inventoryHash -or
                $measurementRuntime.ToLowerInvariant() -cne $candidateMatch[0].RuntimeSha256 -or
                [string]$measurement.EvidenceStatus -cne 'BENCHMARK_VERIFIED') { throw "AI_COMPUTE_BENCHMARK_BINDING_MISMATCH: $id" }
            $integerError="AI_COMPUTE_BENCHMARK_INVALID: $id"
            $peak=ConvertTo-LabAiComputeInteger $measurement.PeakWorkingSetBytes 0 ([long]::MaxValue) $integerError
            $successful=ConvertTo-LabAiComputeInteger $measurement.SuccessfulIterations 3 ([int]::MaxValue) $integerError
            $total=ConvertTo-LabAiComputeInteger $measurement.TotalIterations 3 ([int]::MaxValue) $integerError
            if(-not (Test-LabAiComputeFiniteNumber $measurement.ThroughputPerSecond) -or [double]$measurement.ThroughputPerSecond -le 0 -or
                -not (Test-LabAiComputeFiniteNumber $measurement.P95LatencyMilliseconds) -or [double]$measurement.P95LatencyMilliseconds -lt 0 -or
                $successful -ne $total) { throw $integerError }
            $benchmarksById[$id]=[PSCustomObject]@{CandidateId=$id;ThroughputPerSecond=[double]$measurement.ThroughputPerSecond;P95LatencyMilliseconds=[double]$measurement.P95LatencyMilliseconds;PeakWorkingSetBytes=$peak;SuccessfulIterations=[int]$successful;TotalIterations=[int]$total}
        }
        $missing=@($eligible|Where-Object {-not $benchmarksById.ContainsKey($_.CandidateId)}|ForEach-Object CandidateId)
        if($missing.Count){throw ('AI_COMPUTE_BENCHMARK_COVERAGE_INCOMPLETE: '+($missing -join ','))}
        $ranked=@($benchmarksById.Values|Sort-Object @{Expression='ThroughputPerSecond';Descending=$true},@{Expression='P95LatencyMilliseconds';Ascending=$true},@{Expression='PeakWorkingSetBytes';Ascending=$true},@{Expression={[Convert]::ToHexString([Text.Encoding]::UTF8.GetBytes($_.CandidateId))};Ascending=$true})
        $selectedBenchmark=$ranked[0]
        $selected=@($eligible|Where-Object CandidateId -CEQ $selectedBenchmark.CandidateId)[0]
    }
    $identity=[ordered]@{Contract='SqlServerLab.AiComputeSelection/1.0';SelectionMode=if($PSCmdlet.ParameterSetName -eq 'Pinned'){'PINNED'}else{'AUTO_FASTEST'};WorkloadKey=$WorkloadKey;ModelSha256=$modelHash;BenchmarkProfileSha256=$profileHash;InventorySha256=$inventoryHash;Candidates=$candidateArray;Benchmarks=$ranked;PinnedCandidateId=if($PinnedCandidateId){$PinnedCandidateId}else{$null};SelectedCandidateId=$selected.CandidateId}
    return [PSCustomObject]@{
        Contract='SqlServerLab.AiComputeSelection/1.0';Status='SELECTED';SelectionMode=$identity.SelectionMode
        CandidateId=$selected.CandidateId;Backend=$selected.Backend;Devices=$selected.Devices;RuntimeSha256=$selected.RuntimeSha256
        WorkloadKey=$WorkloadKey;ModelSha256=$modelHash;BenchmarkProfileSha256=$profileHash;InventorySha256=$inventoryHash
        SelectedBenchmark=$selectedBenchmark;RankedCandidates=@($ranked);ExcludedCandidates=$excluded
        SelectionKey=Get-LabAiPlanKey $identity
    }
}
