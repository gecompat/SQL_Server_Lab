<#
.SYNOPSIS
    Leitet hashgebundene KI-Runtime-Fähigkeiten aus lokalen llama.cpp-Paketen ab.
.DESCRIPTION
    Validiert ein vollständiges Hardwareinventar und FILES_ONLY-Receipts aus
    Get-SqlServerLabLlamaCppRuntime. Alle unmittelbaren Runtime-Binärdateien
    werden bei gehaltenen Lesesperren gehasht. Die Ausgabe enthält keine Pfade
    und unterscheidet Artefakteignung ausdrücklich von Geräteausführung.
.PARAMETER Inventory
    Vollständiges SqlServerLab.AiComputeInventory/1.0-Receipt.
.PARAMETER Runtime
    Ein bis 16 lokale SqlServerLab.LlamaCppRuntime/1.0-Receipts.
.OUTPUTS
    SqlServerLab.AiRuntimeCapabilitySet/1.0.
#>
function Get-SqlServerLabAiRuntimeCapability {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Inventory,[Parameter(Mandatory)][ValidateCount(1,16)][object[]]$Runtime)
    Get-LabAiRuntimeCapabilitySet @PSBoundParameters
}
