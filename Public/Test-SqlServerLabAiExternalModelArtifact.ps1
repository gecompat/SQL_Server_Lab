<#
.SYNOPSIS
    Prüft Runtime- und Modelldatei eines External-Model-Plans read-only.
.DESCRIPTION
    Berechnet SHA-256 über ausdrücklich angegebene lokale Dateien und vergleicht
    sie mit dem unveränderten Plan. Das Ergebnis enthält keine lokalen Pfade.
    Ein erfolgreicher Dateivergleich ist kein Accelerator- oder Prozessnachweis.
.PARAMETER Plan
    Ergebnis von Get-SqlServerLabAiExternalModelPlan.
.PARAMETER RuntimePath
    Lokale Serverruntime, deren Inhalt dem RuntimeSha256 des Plans entsprechen muss.
.PARAMETER ModelPath
    Lokale Modelldatei, deren Inhalt dem ModelSha256 des Plans entsprechen muss.
.OUTPUTS
    Sanitierte SqlServerLab.AiExternalModelArtifactReceipt/1.0.
.EXAMPLE
    $plan | Test-SqlServerLabAiExternalModelArtifact -RuntimePath C:\AI\llama-server.exe -ModelPath C:\AI\embedding.gguf
#>
function Test-SqlServerLabAiExternalModelArtifact {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory,ValueFromPipeline)]$Plan,
        [Parameter(Mandatory)][string]$RuntimePath,
        [Parameter(Mandatory)][string]$ModelPath
    )
    process {
        Test-LabAiExternalModelArtifact -Plan $Plan -RuntimePath $RuntimePath -ModelPath $ModelPath
    }
}
