<#
.SYNOPSIS
    Vergleicht verwaltete Containerdatenbanken nach RELATIONAL_CORE/1.0 read-only.
.DESCRIPTION
    Der Befehl akzeptiert ausschließlich Paaridentitäten. Connection Strings,
    Hosts, SQL-Texte und Secrets sind keine Parameter. Jede Seite wird vor dem
    Vergleich an einen laufenden, verwalteten Docker-/Podman-Container und den
    aktuellen RuntimeScope gebunden. Der Transfer-Executor bleibt BLOCKED.
.PARAMETER ComparisonPair
    Paarobjekte mit PairId, SourceRunId, SourceInstanceId, SourceDatabaseName,
    TargetRunId, TargetInstanceId und TargetDatabaseName.
.PARAMETER StateRoot
    Optionaler lokaler State-Root für die Run- und Secret-Auflösung.
.OUTPUTS
    SqlServerLab.RelationalCoreComparison/1.0 ohne Datenwerte oder Secrets.
.EXAMPLE
    Test-SqlServerLabRelationalCoreComparison -ComparisonPair $pairs
#>
function Test-SqlServerLabRelationalCoreComparison {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][object[]]$ComparisonPair,[string]$StateRoot)
    Invoke-LabRelationalCoreComparison -ComparisonPair $ComparisonPair -StateRoot $StateRoot
}
