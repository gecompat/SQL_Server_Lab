<#
.SYNOPSIS
    Erzeugt alle von Runtime-Fähigkeiten erlaubten KI-Gerätekandidaten.
.DESCRIPTION
    Verifiziert zuerst den vollständigen Hardwareinventar-Hash. Für jede strikt
    deklarierte Runtime-Fähigkeit werden danach alle erlaubten Gerätemengen
    zwischen MinimumDeviceCount und MaximumDeviceCount erzeugt. AllowMixedKinds
    steuert gemischte CPU-/GPU-/NPU-Sets. Mehr als 64 Kandidaten werden nicht
    abgeschnitten, sondern fail-closed abgewiesen.
.PARAMETER Inventory
    Vollständiges SqlServerLab.AiComputeInventory/1.0-Receipt.
.PARAMETER RuntimeCapability
    Strikte Runtimeobjekte mit Backend, Hash, Gerätearten, Hersteller-IDs,
    Größenbereich, Mixed-Schalter, Eignung und Blockern.
.OUTPUTS
    SqlServerLab.AiComputeCandidateSet/1.0.
#>
function Get-SqlServerLabAiComputeCandidate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Inventory,
        [Parameter(Mandatory)][ValidateCount(1,16)][object[]]$RuntimeCapability
    )
    Get-LabAiComputeCandidateSet @PSBoundParameters
}
