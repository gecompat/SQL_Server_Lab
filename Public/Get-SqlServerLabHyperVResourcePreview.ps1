<#
.SYNOPSIS
    Zeigt die read-only Zielvorschau fuer physische Hyper-V-Ressourcen.
.DESCRIPTION
    Loest die registrierte Lab_Data-Location, Volume-Identitaet, den freien
    Speicher und die Klassenroots fuer Run-, Build-, Image-, Staging- oder
    Recovery-Ressourcen auf. Der Befehl erzeugt weder State noch Hyper-V-
    Ressourcen und verwendet keine Legacy-Roots als Create-Ziel.
.PARAMETER ResourceClass
    Eine oder mehrere erwartete Ressourcenklassen. Ohne Angabe werden alle
    Hyper-V-Ressourcenklassen angezeigt.
.PARAMETER LocationId
    Optionale stabile Storage-Location. Ohne Angabe gilt die registrierte
    Default-Location.
.PARAMETER DataRoot
    Optionaler Einstieg in einen isolierten lokalen Storage-Katalog.
.OUTPUTS
    System.Management.Automation.PSCustomObject mit dem Vertrag
    SqlServerLab.HyperVResourceLocationPreview/1.0.
.EXAMPLE
    Get-SqlServerLabHyperVResourcePreview -ResourceClass Run,Build

    Zeigt die physischen Klassenroots fuer neue Slots und Builder, ohne eine
    VM, VHDX oder State-Datei anzulegen.
#>
function Get-SqlServerLabHyperVResourcePreview {
    [CmdletBinding()]
    param(
        [ValidateSet('Run', 'Build', 'Image', 'Staging', 'Recovery')]
        [string[]]$ResourceClass = @('Run', 'Build', 'Image', 'Staging', 'Recovery'),
        [string]$LocationId,
        [string]$DataRoot
    )

    return Get-LabHyperVResourceLocationPreview -ResourceClass $ResourceClass `
        -LocationId $LocationId -DataRoot $DataRoot
}
