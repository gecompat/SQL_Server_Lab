<#
.SYNOPSIS
    Wählt für eine KI-Operation eine benchmarkte Gerätekombination oder eine explizite Fixierung.
.DESCRIPTION
    Auto ist der Standard und verlangt genau einen vergleichbaren, erfolgreichen
    Benchmark für jeden geeigneten Kandidaten. Kandidaten können CPU, NPU, eine
    GPU, mehrere GPUs oder gemischte Geräte enthalten. Die Rangfolge verwendet
    Durchsatz, danach P95-Latenz, Peak Working Set und Kandidaten-ID. Fehlende
    Evidence blockiert; es gibt keinen stillen Fallback. Pinned wählt nur den
    expliziten geeigneten Kandidaten und benötigt keine Benchmarkentscheidung.
.PARAMETER WorkloadKey
    Stabiler Schlüssel des identischen, von allen Benchmarks verwendeten Workloads.
.PARAMETER ModelSha256
    SHA-256 der für alle Kandidaten identischen Modelldatei.
.PARAMETER BenchmarkProfileSha256
    SHA-256 des identischen Warmup-, Input-, Iterations- und Messprofils.
.PARAMETER InventorySha256
    SHA-256 des vollständigen Hardwareinventars, an das alle Benchmarks gebunden sind.
.PARAMETER Candidate
    Strikte Objekte mit CandidateId, Backend, RuntimeSha256, Devices, Eligible und Blockers.
.PARAMETER Benchmark
    In Auto genau ein BENCHMARK_VERIFIED-Objekt je geeignetem Kandidaten.
.PARAMETER PinnedCandidateId
    Explizite geeignete Kandidaten-ID; aktiviert den Pinned-Modus.
.OUTPUTS
    SqlServerLab.AiComputeSelection/1.0.
#>
function Get-SqlServerLabAiComputeSelection {
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
    Get-LabAiComputeSelection @PSBoundParameters
}
