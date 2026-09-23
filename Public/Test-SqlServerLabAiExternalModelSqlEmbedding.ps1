<#
.SYNOPSIS
    Prüft ein angewendetes SQL External Model mit einem synthetischen Embedding.
.DESCRIPTION
    Bindet Plan und Apply-Receipt erneut an den eigenen Run, validiert das
    SQL-Ownership-Receipt und führt genau einen festen, parametrisierten
    AI_GENERATE_EMBEDDINGS-Aufruf aus. Text und Vektor werden nicht ausgegeben.
.PARAMETER SqlPlan
    Unveränderter Plan des zuvor ausgeführten SQL-Apply.
.PARAMETER ApplyReceipt
    Passendes Ergebnis von Invoke-SqlServerLabAiExternalModelSqlApply.
.PARAMETER RunId
    Eigener SQL-2025-Docker-/Podman-Run.
.PARAMETER InstanceId
    SQL-Instanz, standardmäßig primary.
.PARAMETER StateRoot
    Optionaler lokaler Run-State.
.OUTPUTS
    Sanitisiertes SqlServerLab.AiExternalModelSqlEmbeddingReceipt/1.0.
#>
function Test-SqlServerLabAiExternalModelSqlEmbedding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$SqlPlan,
        [Parameter(Mandatory)]$ApplyReceipt,
        [Parameter(Mandatory)][ValidatePattern('^[a-f0-9-]{36}$')][string]$RunId,
        [ValidatePattern('^[a-zA-Z][a-zA-Z0-9_-]{0,63}$')][string]$InstanceId='primary',
        [string]$StateRoot
    )
    $arguments=@{SqlPlan=$SqlPlan;ApplyReceipt=$ApplyReceipt;RunId=$RunId;InstanceId=$InstanceId}
    if($PSBoundParameters.ContainsKey('StateRoot')){$arguments.StateRoot=$StateRoot}
    Invoke-LabAiExternalModelSqlEmbeddingProbe @arguments
}
