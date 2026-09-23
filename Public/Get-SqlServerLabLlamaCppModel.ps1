<#
.SYNOPSIS
    Listet kuratierte, direkt beschaffbare llama.cpp-Generationsmodelle.
.DESCRIPTION
    Liefert nur Modelle mit fest gebundener Herstellerquelle, Revision, Größe,
    SHA-256 und nicht gesperrter Lizenz. Die Hardwarestufe ist eine grobe
    Kapazitätsklasse und kein Benchmark- oder Beschleunigernachweis.
.PARAMETER Id
    Optionaler exakter Katalogschlüssel.
.OUTPUTS
    SqlServerLab.LlamaCppModel/1.0; enthält keine lokalen Pfade.
#>
function Get-SqlServerLabLlamaCppModel {
    [CmdletBinding()]
    param([string]$Id)
    @(Get-LabLlamaCppModel @PSBoundParameters) | ForEach-Object {
        [PSCustomObject]@{
            Contract='SqlServerLab.LlamaCppModel/1.0'; Id=$_.id; DisplayName=$_.displayName
            Family=$_.family; Purpose=$_.purpose; ParameterCountBillions=$_.parameterCountBillions
            Quantization=$_.quantization; HardwareTier=$_.hardwareTier; FileName=$_.fileName
            SizeBytes=[long]$_.sizeBytes; Sha256=$_.sha256; Publisher=$_.source.publisher
            Repository=$_.source.repository; Revision=$_.source.revision; License=$_.source.license
            LicenseUrl=$_.source.licenseUrl; DirectDownload=$true
        }
    }
}
