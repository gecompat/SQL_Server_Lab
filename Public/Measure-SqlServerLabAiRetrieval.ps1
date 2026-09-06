<#
.SYNOPSIS
    Misst ein geordnetes Retrieval-Ergebnis deterministisch.
.DESCRIPTION
    Berechnet Recall@k, Precision@k, MRR und nDCG ohne Modell-Judge oder
    Netzwerkzugriff. Unterschrittene Schwellwerte ergeben einen blockierenden,
    maschinenlesbaren Status; Dokumentinhalte werden nicht verarbeitet.
.PARAMETER ExpectedDocumentId
    Eindeutige IDs aller für die Anfrage relevanten Dokumente.
.PARAMETER RankedDocumentId
    Eindeutige Dokument-IDs in der tatsächlich gelieferten Rangfolge.
.PARAMETER K
    Bewertete Top-k-Grenze.
.PARAMETER MinimumRecall
    Blockierender Mindestwert für Recall@k.
.PARAMETER MinimumMrr
    Blockierender Mindestwert für MRR.
.PARAMETER MinimumNdcg
    Blockierender Mindestwert für nDCG@k.
.OUTPUTS
    SqlServerLab.AiRetrievalEvaluation/1.0.
.EXAMPLE
    Measure-SqlServerLabAiRetrieval -ExpectedDocumentId doc-1,doc-2 -RankedDocumentId doc-1,doc-3,doc-2 -K 3
#>
function Measure-SqlServerLabAiRetrieval {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string[]]$ExpectedDocumentId,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$RankedDocumentId,
        [ValidateRange(1,100)][int]$K = 5,
        [ValidateRange(0,1)][double]$MinimumRecall = 1,
        [ValidateRange(0,1)][double]$MinimumMrr = 1,
        [ValidateRange(0,1)][double]$MinimumNdcg = 1
    )
    return Measure-LabAiRetrieval @PSBoundParameters
}
