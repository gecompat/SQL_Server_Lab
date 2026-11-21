function Read-LabAiComputeReceiptInteractive {
    param([string]$Prompt)
    $inputResult = Read-LabConsoleTextInput -Prompt $Prompt
    if ($inputResult.Status -ne 'Confirmed') { return $null }
    $file = Get-LabLlamaStartPlanItem -Path $inputResult.Value
    if ($file.Extension -ine '.json' -or $file.Length -le 0 -or $file.Length -gt 256KB) { throw 'AI_COMPUTE_RECEIPT_FILE_INVALID' }
    $stream = [IO.File]::Open($file.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        if ($stream.Length -le 0 -or $stream.Length -gt 256KB) { throw 'AI_COMPUTE_RECEIPT_FILE_INVALID' }
        $reader = [IO.StreamReader]::new($stream)
        try { $reader.ReadToEnd() | ConvertFrom-Json -Depth 16 -ErrorAction Stop }
        finally { $reader.Dispose() }
    }
    finally { $stream.Dispose() }
}

function Invoke-LabAiComputeSelectionInteractive {
    try {
        $candidateSet = Read-LabAiComputeReceiptInteractive -Prompt 'Absoluter Pfad zum Kandidatensatz (JSON)'
        if (-not $candidateSet) { return }
        if ($candidateSet.Contract -cne 'SqlServerLab.AiComputeCandidateSet/1.0' -or $candidateSet.Status -cne 'COMPLETE' -or
            $candidateSet.Candidates -isnot [array]) { throw 'AI_COMPUTE_CANDIDATE_RECEIPT_INVALID' }
        $benchmarkSet = Read-LabAiComputeReceiptInteractive -Prompt 'Absoluter Pfad zum Benchmark-Satz desselben Inventars (JSON)'
        if (-not $benchmarkSet) { return }
        $selection = $benchmarkSet.Selection
        if ($benchmarkSet.Contract -cne 'SqlServerLab.AiComputeBenchmarkSet/1.0' -or $benchmarkSet.Status -cne 'SELECTED' -or
            $selection.Contract -cne 'SqlServerLab.AiComputeSelection/1.0' -or $benchmarkSet.Benchmarks -isnot [array] -or
            $candidateSet.InventorySha256 -cne $selection.InventorySha256) { throw 'AI_COMPUTE_BENCHMARK_RECEIPT_INVALID' }
        $choices = @(
            New-LabConsoleItem -Id 'auto' -Label 'Schnellsten gemessenen Kandidaten wählen' -Data ([pscustomobject]@{Pinned=$false})
            foreach ($candidate in $candidateSet.Candidates) {
                if ($candidate.Eligible -is [bool] -and $candidate.Eligible -and
                    $candidate.CandidateId -cmatch '^[a-z0-9][a-z0-9._-]{0,127}\z') {
                    New-LabConsoleItem -Id ('candidate-' + $candidate.CandidateId) -Label ([string]$candidate.CandidateId) `
                        -Value ([string]$candidate.Backend) -Data ([pscustomobject]@{Pinned=$true;Id=[string]$candidate.CandidateId})
                }
            }
        )
        $choice = Select-LabConsoleDataItem -ScreenId 'ai-compute-receipt-choice' -Title 'Gemessene KI-Gerätekombination wählen' -Items $choices
        if (-not $choice) { return }
        $parameters = @{
            WorkloadKey=$selection.WorkloadKey; ModelSha256=$selection.ModelSha256; BenchmarkProfileSha256=$selection.BenchmarkProfileSha256
            InventorySha256=$candidateSet.InventorySha256; Candidate=$candidateSet.Candidates; Benchmark=$benchmarkSet.Benchmarks
        }
        if ($choice.Pinned) {
            $parameters.Remove('Benchmark')
            $parameters.PinnedCandidateId = $choice.Id
        }
        $verified = Get-SqlServerLabAiComputeSelection @parameters -ErrorAction Stop
        Write-LabInfo ('Auswahl: {0} · Backend: {1} · Modus: {2}' -f $verified.CandidateId, $verified.Backend, $verified.SelectionMode)
        Write-LabInfo ('Belegschlüssel: {0}' -f $verified.SelectionKey)
    }
    catch { Write-LabError 'Die Auswahl konnte nicht berechnet werden. Prüfe, ob beide JSON-Belege zur selben vollständigen Messung gehören.' }
    $null = Wait-LabConsoleAcknowledgement
}
