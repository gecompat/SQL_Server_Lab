<#
.SYNOPSIS
    Misst einen explizit gebundenen llama.cpp-Kandidaten mit llama-bench.
.DESCRIPTION
    Verifiziert Inventar, Kandidat, vollständiges Runtimepaket und GGUF vor und
    nach dem Lauf. Geräte werden explizit auf llama.cpp-Selektoren abgebildet.
    Das Ergebnis ist direkt für Get-SqlServerLabAiComputeSelection verwendbar.
.PARAMETER Inventory
    Vollständiges, verifiziertes Hardwareinventar des Zielhosts.
.PARAMETER Candidate
    Genau ein aus dem Inventar abgeleiteter, geeigneter Compute-Kandidat.
.PARAMETER RuntimeDirectory
    Verzeichnis des gebundenen llama.cpp-Runtimepakets mit llama-bench.
.PARAMETER ModelPath
    Lokaler Pfad zur zu messenden GGUF-Modelldatei.
.PARAMETER WorkloadKey
    Stabiler Schlüssel für den gemessenen KI-Workload.
.PARAMETER DeviceBinding
    Optionale vollständige Zuordnung aller Kandidatengeräte zu llama.cpp-Geräteselektoren.
    Ohne Angabe wird sie aus der aktuellen --list-devices-Ausgabe eindeutig abgeleitet.
.PARAMETER Repetitions
    Anzahl der von llama-bench auszuführenden Messwiederholungen.
.PARAMETER GeneratedTokens
    Anzahl der pro Wiederholung zu erzeugenden Tokens.
.PARAMETER BenchmarkMode
    Generation misst Tokenausgabe; Embedding misst Promptverarbeitung eines
    Embeddingmodells mit dem Workloadschlüssel sql-ai-embedding.
.PARAMETER PromptTokens
    Anzahl verarbeiteter Prompttokens je Embedding-Wiederholung.
.PARAMETER BatchSize
    Logische llama.cpp-Batchgröße.
.PARAMETER MicroBatchSize
    Physische llama.cpp-Microbatchgröße.
.PARAMETER TimeoutSeconds
    Maximale Laufzeit des eigenen Benchmarkprozesses in Sekunden.
.OUTPUTS
    BENCHMARK_VERIFIED-Receipt für Get-SqlServerLabAiComputeSelection.
#>
function Measure-SqlServerLabAiComputeCandidate {
    [CmdletBinding(SupportsShouldProcess)]
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
        [ValidateRange(1,3600)][int]$TimeoutSeconds=900
    )
    if($PSCmdlet.ShouldProcess([string]$Candidate.CandidateId,'Run bound llama.cpp benchmark')){
        $arguments=@{}+$PSBoundParameters;$arguments.Remove('WhatIf');$arguments.Remove('Confirm')
        Invoke-LabAiComputeBenchmark @arguments
    }
}
