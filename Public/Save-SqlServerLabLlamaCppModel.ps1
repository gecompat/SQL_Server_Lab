<#
.SYNOPSIS
    Lädt ein ausgewähltes kuratiertes GGUF bei Bedarf sicher herunter.
.DESCRIPTION
    Verwendet ausschließlich die im Repository fest gebundene HTTPS-Quelle.
    Die Datei wird im MediaRoot unter AI/Models temporär geschrieben und erst
    nach Größen-, SHA-256- und GGUF-Prüfung atomisch veröffentlicht. Vorhandene
    Dateien werden vollständig revalidiert; ungültige Dateien bleiben unberührt
    und blockieren. Es gibt keinen Modell- oder Quellenfallback.
.PARAMETER Id
    Exakter Katalogschlüssel aus Get-SqlServerLabLlamaCppModel.
.PARAMETER MediaRoot
    Bereits vorhandene, nicht umgeleitete Medienwurzel für große Binärartefakte.
.OUTPUTS
    SqlServerLab.LlamaCppModelAcquisition/1.0 mit validiertem lokalen Modellpfad.
.EXAMPLE
    Save-SqlServerLabLlamaCppModel -Id qwen3-4b-q4_k_m -MediaRoot D:\Lab_Base -Confirm:$false
#>
function Save-SqlServerLabLlamaCppModel {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='Medium')]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[a-z0-9][a-z0-9._-]{0,127}$')][string]$Id,
        [Parameter(Mandatory)][string]$MediaRoot
    )
    $model = Get-LabLlamaCppModel -Id $Id
    if ($PSCmdlet.ShouldProcess((Join-Path $MediaRoot ('AI/Models/' + $model.fileName)), "Download $Id")) {
        Save-LabLlamaCppModelFile -Model $model -MediaRoot $MediaRoot
    }
}
