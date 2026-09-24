#Requires -Version 7.2
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][ValidateCount(1,16)][string[]]$RuntimeDirectory,
    [Parameter(Mandatory)][string]$ModelPath,
    [Parameter(Mandatory)][ValidatePattern('^[a-z0-9][a-z0-9._-]{0,127}$')][string]$WorkloadKey,
    [ValidateRange(3,30)][int]$Repetitions=5,
    [ValidateRange(1,4096)][int]$GeneratedTokens=128,
    [ValidateSet('Generation','Embedding')][string]$BenchmarkMode='Generation',
    [ValidateRange(1,4096)][int]$PromptTokens=512,
    [ValidateRange(1,4096)][int]$BatchSize=512,
    [ValidateRange(1,4096)][int]$MicroBatchSize=128,
    [ValidateRange(1,3600)][int]$TimeoutSeconds=900,
    [string]$EvidencePath,
    [switch]$Force
)
$ErrorActionPreference='Stop'
if(-not $PSCmdlet.ShouldProcess("$($RuntimeDirectory.Count) llama.cpp runtime package(s)",'Run native AI compute benchmark acceptance')){return}

$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$module=Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru
try {
    $inventory=Get-SqlServerLabAiComputeInventory
    if($inventory.Contract -cne 'SqlServerLab.AiComputeInventory/1.0' -or $inventory.Status -cne 'COMPLETE' -or [string]::IsNullOrWhiteSpace([string]$inventory.InventorySha256)){
        throw 'AI_COMPUTE_ACCEPTANCE_INVENTORY_INCOMPLETE'
    }

    $comparison=if($IsWindows){[StringComparison]::OrdinalIgnoreCase}else{[StringComparison]::Ordinal}
    $runtimeReceipts=[Collections.Generic.List[object]]::new()
    $resolvedRuntimePaths=[Collections.Generic.List[string]]::new()
    foreach($directory in $RuntimeDirectory){
        try{$resolved=[IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($directory))}catch{throw 'AI_COMPUTE_ACCEPTANCE_RUNTIME_INVALID'}
        if($resolvedRuntimePaths.Exists([Predicate[string]]{param($item)$item.Equals($resolved,$comparison)})){throw 'AI_COMPUTE_ACCEPTANCE_RUNTIME_DUPLICATE'}
        $runtimeMatches=@(Get-SqlServerLabLlamaCppRuntime -SearchRoot $resolved | Where-Object {[string]$_.InstallationPath -and ([IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath([string]$_.InstallationPath))).Equals($resolved,$comparison)})
        if($runtimeMatches.Count -ne 1){throw 'AI_COMPUTE_ACCEPTANCE_RUNTIME_NOT_UNIQUE'}
        $resolvedRuntimePaths.Add($resolved);$runtimeReceipts.Add($runtimeMatches[0])
    }

    $capabilitySet=Get-SqlServerLabAiRuntimeCapability -Inventory $inventory -Runtime @($runtimeReceipts)
    if($capabilitySet.Status -cne 'COMPLETE' -or [string]::IsNullOrWhiteSpace([string]$capabilitySet.CapabilitySetSha256)){throw 'AI_COMPUTE_ACCEPTANCE_CAPABILITY_INCOMPLETE'}
    $candidateSet=Get-SqlServerLabAiComputeCandidate -Inventory $inventory -RuntimeCapability @($capabilitySet.Capabilities)
    if($candidateSet.Status -cne 'COMPLETE' -or [string]::IsNullOrWhiteSpace([string]$candidateSet.CandidateSetSha256)){throw 'AI_COMPUTE_ACCEPTANCE_CANDIDATE_INCOMPLETE'}
    $eligible=@($candidateSet.Candidates|Where-Object Eligible)
    if($eligible.Count -lt 1){throw 'AI_COMPUTE_ACCEPTANCE_NO_ELIGIBLE_CANDIDATE'}

    $measureArgs=@{Inventory=$inventory;Candidate=@($candidateSet.Candidates);RuntimeDirectory=@($resolvedRuntimePaths);ModelPath=$ModelPath;WorkloadKey=$WorkloadKey;Repetitions=$Repetitions;GeneratedTokens=$GeneratedTokens;BenchmarkMode=$BenchmarkMode;PromptTokens=$PromptTokens;BatchSize=$BatchSize;MicroBatchSize=$MicroBatchSize;TimeoutSeconds=$TimeoutSeconds;Confirm=$false}
    $benchmarkSet=Measure-SqlServerLabAiComputeCandidateSet @measureArgs
    $benchmarks=@($benchmarkSet.Benchmarks);$ranked=@($benchmarkSet.Selection.RankedCandidates)
    if($benchmarks.Count -ne $eligible.Count){throw 'AI_COMPUTE_ACCEPTANCE_COVERAGE_MISMATCH'}
    if($ranked.Count -ne $eligible.Count -or $benchmarkSet.Selection.CandidateId -cne $ranked[0].CandidateId){throw 'AI_COMPUTE_ACCEPTANCE_RANKING_MISMATCH'}
    $maximum=[double](($benchmarks|Measure-Object ThroughputPerSecond -Maximum).Maximum)
    if([double]$benchmarkSet.Selection.SelectedBenchmark.ThroughputPerSecond -ne $maximum){throw 'AI_COMPUTE_ACCEPTANCE_FASTEST_MISMATCH'}
    foreach($candidate in $eligible){
        $candidateReceipts=@($benchmarks|Where-Object CandidateId -CEQ ([string]$candidate.CandidateId))
        if($candidateReceipts.Count -ne 1 -or $candidateReceipts[0].RuntimeSha256 -cne $candidate.RuntimeSha256){throw 'AI_COMPUTE_ACCEPTANCE_BINDING_MISMATCH'}
    }
    if(@($benchmarks|Where-Object {$_.InventorySha256 -cne $inventory.InventorySha256 -or $_.ModelSha256 -cne $benchmarkSet.Selection.ModelSha256 -or $_.BenchmarkProfileSha256 -cne $benchmarkSet.Selection.BenchmarkProfileSha256}).Count){throw 'AI_COMPUTE_ACCEPTANCE_BINDING_MISMATCH'}
    $selectedCandidates=@($eligible|Where-Object CandidateId -CEQ ([string]$benchmarkSet.Selection.CandidateId))
    if($selectedCandidates.Count -ne 1 -or $benchmarkSet.Selection.RuntimeSha256 -cne $selectedCandidates[0].RuntimeSha256){throw 'AI_COMPUTE_ACCEPTANCE_BINDING_MISMATCH'}

    $selection=$benchmarkSet.Selection
    $receipt=[ordered]@{
        Contract='SqlServerLab.AiComputeBenchmarkAcceptance/1.0';Status='PASSED';ExecutedAtUtc=[DateTimeOffset]::UtcNow.ToString('o');Platform=if($IsWindows){'Windows'}else{'Linux'}
        InventorySha256=[string]$inventory.InventorySha256;CapabilitySetSha256=[string]$capabilitySet.CapabilitySetSha256;CandidateSetSha256=[string]$candidateSet.CandidateSetSha256
        EligibleCandidateCount=$eligible.Count;BenchmarkCount=$benchmarks.Count;SelectionKey=[string]$selection.SelectionKey;SelectedCandidateId=[string]$selection.CandidateId;SelectedBackend=[string]$selection.Backend
        SelectedDevices=@($selection.Devices|ForEach-Object {[ordered]@{Kind=[string]$_.Kind;DeviceId=[string]$_.DeviceId}})
        SelectedThroughputPerSecond=[double]$selection.SelectedBenchmark.ThroughputPerSecond;SelectedP95LatencyMilliseconds=[double]$selection.SelectedBenchmark.P95LatencyMilliseconds;SelectedPeakWorkingSetBytes=[long]$selection.SelectedBenchmark.PeakWorkingSetBytes
        RankedCandidates=@($ranked|ForEach-Object {[ordered]@{CandidateId=[string]$_.CandidateId;ThroughputPerSecond=[double]$_.ThroughputPerSecond;P95LatencyMilliseconds=[double]$_.P95LatencyMilliseconds;PeakWorkingSetBytes=[long]$_.PeakWorkingSetBytes}})
    }
    $json=$receipt|ConvertTo-Json -Depth 12
    if(-not ($json|Test-Json -SchemaFile (Join-Path $repoRoot 'Schemas/ai-compute-benchmark-acceptance.schema.json'))){throw 'AI_COMPUTE_ACCEPTANCE_RECEIPT_INVALID'}
    if($EvidencePath){
        $target=[IO.Path]::GetFullPath($EvidencePath);$parent=Split-Path $target -Parent
        if(-not (Test-Path -LiteralPath $parent -PathType Container) -or ((Get-Item -LiteralPath $parent -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'AI_COMPUTE_ACCEPTANCE_EVIDENCE_PARENT_INVALID'}
        if(Test-Path -LiteralPath $target){
            $targetItem=Get-Item -LiteralPath $target -Force
            if($targetItem.PSIsContainer -or ($targetItem.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'AI_COMPUTE_ACCEPTANCE_EVIDENCE_TARGET_INVALID'}
            if(-not $Force){throw 'AI_COMPUTE_ACCEPTANCE_EVIDENCE_EXISTS'}
        }
        $temporary=Join-Path $parent ('.'+[IO.Path]::GetFileName($target)+'.'+[guid]::NewGuid().ToString('N')+'.tmp')
        try{[IO.File]::WriteAllText($temporary,$json,[Text.UTF8Encoding]::new($false));[IO.File]::Move($temporary,$target,$Force.IsPresent)}catch{if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary -Force};throw 'AI_COMPUTE_ACCEPTANCE_EVIDENCE_WRITE_FAILED'}
    }
    [pscustomobject]$receipt
}
finally {Remove-Module $module -Force -ErrorAction SilentlyContinue}
