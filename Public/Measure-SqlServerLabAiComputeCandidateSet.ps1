<#
.SYNOPSIS
    Misst alle geeigneten llama.cpp-Kandidaten und wählt die schnellste Option.
.DESCRIPTION
    Führt dasselbe gebundene llama-bench-Profil nacheinander für jeden geeigneten
    Kandidaten aus. Fehlende Runtimes oder Messungen brechen geschlossen ab. Das
    Ergebnis enthält alle vollständigen Receipts und die automatisch nach
    Durchsatz, P95-Latenz und Speicherbedarf gewählte ComputeSelection.
.PARAMETER Inventory
    Vollständiges, verifiziertes Hardwareinventar des Zielhosts.
.PARAMETER Candidate
    Vollständige Kandidatenmenge aus Get-SqlServerLabAiComputeCandidate.
.PARAMETER RuntimeDirectory
    Verzeichnisse aller benötigten, inhaltsgebundenen llama.cpp-Runtimepakete.
.PARAMETER ModelPath
    Lokaler Pfad zur identischen GGUF-Modelldatei für alle Messungen.
.PARAMETER WorkloadKey
    Stabiler Schlüssel für den gemessenen KI-Workload.
.PARAMETER Repetitions
    Anzahl der Messwiederholungen je geeignetem Kandidaten.
.PARAMETER GeneratedTokens
    Anzahl der pro Generationswiederholung zu erzeugenden Tokens.
.PARAMETER BenchmarkMode
    Generation misst Tokenausgabe; Embedding misst Promptverarbeitung.
.PARAMETER PromptTokens
    Anzahl verarbeiteter Prompttokens je Embedding-Wiederholung.
.PARAMETER BatchSize
    Logische llama.cpp-Batchgröße für jeden Kandidaten.
.PARAMETER MicroBatchSize
    Physische llama.cpp-Microbatchgröße für jeden Kandidaten.
.PARAMETER TimeoutSeconds
    Maximale Laufzeit jedes einzelnen Benchmarkprozesses.
.OUTPUTS
    SqlServerLab.AiComputeBenchmarkSet/1.0 mit Selection und Benchmarks.
#>
function Measure-SqlServerLabAiComputeCandidateSet {
    [CmdletBinding(SupportsShouldProcess)]
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
        [ValidateRange(1,3600)][int]$TimeoutSeconds=900
    )
    if($PSCmdlet.ShouldProcess("$(@($Candidate|Where-Object Eligible).Count) eligible compute candidates",'Run complete llama.cpp benchmark set and select fastest')){
        $arguments=@{}+$PSBoundParameters;$arguments.Remove('WhatIf');$arguments.Remove('Confirm')
        Invoke-LabAiComputeBenchmarkSet @arguments
    }
}
