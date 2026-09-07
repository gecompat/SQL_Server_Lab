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
.PARAMETER QueryResult
    Tatsächlich ausgeführtes, golden-dataset-gebundenes SqlServerLab.AiQueryResult/1.0.
.PARAMETER GoldenDatasetId
    Repository-gebundener Golden-Dataset-Schlüssel.
.PARAMETER GoldenDatasetVersion
    Version des Golden Datasets.
.PARAMETER CaseId
    Fall, dessen erwartete Dokumente und blockierende Schwellen gelten.
.OUTPUTS
    SqlServerLab.AiRetrievalEvaluation/1.0.
.EXAMPLE
    Measure-SqlServerLabAiRetrieval -ExpectedDocumentId doc-1,doc-2 -RankedDocumentId doc-1,doc-3,doc-2 -K 3
.EXAMPLE
    Measure-SqlServerLabAiRetrieval -QueryResult $ragResult -CaseId backup-frequency
#>
function Measure-SqlServerLabAiRetrieval {
    [CmdletBinding(DefaultParameterSetName='Manual')]
    param(
        [Parameter(Mandatory,ParameterSetName='Manual')][ValidateNotNullOrEmpty()][string[]]$ExpectedDocumentId,
        [Parameter(Mandatory,ParameterSetName='Manual')][AllowEmptyCollection()][string[]]$RankedDocumentId,
        [Parameter(ParameterSetName='Manual')][ValidateRange(1,100)][int]$K = 5,
        [Parameter(ParameterSetName='Manual')][ValidateRange(0,1)][double]$MinimumRecall = 1,
        [Parameter(ParameterSetName='Manual')][ValidateRange(0,1)][double]$MinimumMrr = 1,
        [Parameter(ParameterSetName='Manual')][ValidateRange(0,1)][double]$MinimumNdcg = 1,
        [Parameter(Mandatory,ParameterSetName='Golden')][ValidateNotNull()]$QueryResult,
        [Parameter(ParameterSetName='Golden')][ValidatePattern('^[a-z][a-z0-9-]{2,63}$')][string]$GoldenDatasetId='sql-lab-rag-de',
        [Parameter(ParameterSetName='Golden')][ValidatePattern('^[1-9][0-9]*\.[0-9]+$')][string]$GoldenDatasetVersion='1.0',
        [Parameter(Mandatory,ParameterSetName='Golden')][ValidatePattern('^[a-z][a-z0-9-]{2,63}$')][string]$CaseId
    )
    if ($PSCmdlet.ParameterSetName -eq 'Golden') {
        return Measure-LabAiGoldenRagResult -QueryResult $QueryResult -DatasetId $GoldenDatasetId `
            -DatasetVersion $GoldenDatasetVersion -CaseId $CaseId
    }
    return Measure-LabAiRetrieval @PSBoundParameters
}
