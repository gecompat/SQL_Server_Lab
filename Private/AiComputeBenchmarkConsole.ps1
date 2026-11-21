function Get-LabAiComputeBenchmarkModel {
    param([string]$ModelPath)
    $file = Get-LabLlamaStartPlanItem -Path $ModelPath
    if ($file.Extension -ine '.gguf') { throw 'AI_COMPUTE_BENCHMARK_MODEL_INVALID' }
    return $file
}

function Get-LabAiComputeBenchmarkOptions {
    param([string]$ModelPath)
    $model = if ($ModelPath) { Get-LabAiComputeBenchmarkModel -ModelPath $ModelPath }
    $inventory = Get-SqlServerLabAiComputeInventory -WarningAction SilentlyContinue -ErrorAction Stop
    if ($inventory.Status -cne 'COMPLETE') { throw 'AI_COMPUTE_BENCHMARK_INVENTORY_INCOMPLETE' }
    $discoveryWarnings = @()
    $discovered = @(Get-SqlServerLabLlamaCppRuntime -WarningVariable discoveryWarnings -WarningAction SilentlyContinue -ErrorAction Stop)
    if ($discoveryWarnings.Count -or $discovered.Count -gt 16) { throw 'AI_COMPUTE_BENCHMARK_PACKAGE_SCAN_INCOMPLETE' }
    $runtimeByHash = @{}
    $capabilities = @(foreach ($runtime in $discovered) {
        $local = Get-LabLlamaStartPlanItem -Path $runtime.InstallationPath -Directory
        $bench = @(Get-ChildItem -LiteralPath $local.FullName -File -Force |
            Where-Object Name -CIn @('llama-bench', 'llama-bench.exe'))
        if ($bench.Count -ne 1) { continue }
        $null = Get-LabLlamaStartPlanItem -Path $bench[0].FullName
        $package = Get-SqlServerLabAiRuntimeCapability -Inventory $inventory -Runtime @($runtime) -ErrorAction Stop
        $hashes = @($package.Capabilities.RuntimeSha256 | Sort-Object -Unique)
        if ($hashes.Count -ne 1 -or $hashes[0] -cnotmatch '^[a-f0-9]{64}$') { throw 'AI_COMPUTE_BENCHMARK_PACKAGE_INVALID' }
        if ($runtimeByHash.ContainsKey($hashes[0])) { throw 'AI_COMPUTE_BENCHMARK_PACKAGE_AMBIGUOUS' }
        $runtimeByHash[$hashes[0]] = $local.FullName
        $package.Capabilities
    })
    if ($capabilities.Count -lt 1 -or $capabilities.Count -gt 16) { throw 'AI_COMPUTE_BENCHMARK_PACKAGE_COVERAGE_UNAVAILABLE' }
    $set = Get-SqlServerLabAiComputeCandidate -Inventory $inventory -RuntimeCapability $capabilities -ErrorAction Stop
    $eligible = @($set.Candidates | Where-Object Eligible)
    if (-not $eligible.Count) { throw 'AI_COMPUTE_BENCHMARK_NO_ELIGIBLE_CANDIDATE' }
    [pscustomobject]@{
        ModelPath = if ($model) { $model.FullName }
        Inventory = $inventory
        CandidateSet = $set
        Packages = @(foreach ($hash in $runtimeByHash.Keys | Sort-Object) {
            [pscustomobject]@{ RuntimeSha256=$hash; Directory=$runtimeByHash[$hash] }
        })
    }
}

function Invoke-LabAiComputeBenchmarkInteractive {
    try {
        $options = Get-LabAiComputeBenchmarkOptions
        $eligible = @($options.CandidateSet.Candidates | Where-Object Eligible)
        $choices = @(
            New-LabConsoleItem -Id 'all' -Label 'Alle geeigneten Kandidaten nacheinander messen' -Value "$($eligible.Count) Messungen" -Data 'all'
            foreach ($candidate in $eligible) {
                New-LabConsoleItem -Id ('candidate-' + $candidate.CandidateId) -Label $candidate.Backend `
                    -Value ($candidate.Devices.DeviceId -join ', ') -Data $candidate
            }
        )
        $choice = Select-LabConsoleDataItem -ScreenId 'ai-compute-benchmark-candidate' -Title 'llama.cpp-Benchmark' -Items $choices
        if (-not $choice) { return }
        $mode = Select-LabConsoleDataItem -ScreenId 'ai-compute-benchmark-mode' -Title 'Messprofil wählen' -Items @(
            New-LabConsoleItem -Id 'generation' -Label 'Textgeneration' -Value '128 Ausgabetokens' -Data 'Generation'
            New-LabConsoleItem -Id 'embedding' -Label 'Embedding' -Value '512 Eingabetokens' -Data 'Embedding'
        )
        if (-not $mode) { return }
        $path = Read-LabConsoleTextInput -Prompt 'Absoluter Pfad zur lokalen GGUF-Datei'
        if ($path.Status -ne 'Confirmed') { return }
        $model = Get-LabAiComputeBenchmarkModel -ModelPath $path.Value
        $all = $choice -is [string] -and $choice -ceq 'all'
        $directories = @(if ($all) { $options.Packages.Directory } else {
            ($options.Packages | Where-Object RuntimeSha256 -CEQ $choice.RuntimeSha256).Directory
        })
        if (-not $directories.Count -or (-not $all -and $directories.Count -ne 1)) { throw 'AI_COMPUTE_BENCHMARK_PACKAGE_INVALID' }
        foreach ($directory in $directories) { Write-LabInfo ("Runtime: {0}" -f [IO.Path]::GetFileName($directory.TrimEnd('\','/'))) }
        $count = if ($all) { $eligible.Count } else { 1 }
        if (-not (Read-LabConfirm -Prompt "Vertraust du den ausgewählten lokalen Paketen und möchtest $count Benchmark(s) mit $($model.Name) starten? Zeitlimit: 900 s je Kandidat." -Default $false)) { return }
        $parameters = @{
            Inventory=$options.Inventory; ModelPath=$model.FullName; BenchmarkMode=$mode
            WorkloadKey=if($mode -ceq 'Embedding'){'sql-ai-embedding'}else{'sql-ai-generation'}
        }
        if ($all) {
            $result = Measure-SqlServerLabAiComputeCandidateSet @parameters -RuntimeDirectory $directories `
                -Candidate $options.CandidateSet.Candidates -Confirm:$false -ErrorAction Stop
            Write-LabInfo ('Auswahl: {0} · Backend: {1} · vollständige Messungen: {2}' -f $result.Selection.CandidateId, $result.Selection.Backend, @($result.Benchmarks).Count)
        } else {
            $result = Measure-SqlServerLabAiComputeCandidate @parameters -RuntimeDirectory $directories[0] `
                -Candidate $choice -Confirm:$false -ErrorAction Stop
            Write-LabInfo ('{0}: {1} Token/s · P95 {2} ms' -f $result.CandidateId, $result.ThroughputPerSecond, $result.P95LatencyMilliseconds)
        }
    }
    catch {
        $code = if ($_.Exception.Message -cmatch '^AI_COMPUTE_BENCHMARK_[A-Z_]{1,64}$') { $_.Exception.Message } else { 'AI_COMPUTE_BENCHMARK_UNCONFIRMED' }
        Write-LabError "Die Messung konnte nicht bestätigt werden ($code). Prüfe Inventar, Runtime-Pakete und Modell."
    }
    $null = Wait-LabConsoleAcknowledgement
}
