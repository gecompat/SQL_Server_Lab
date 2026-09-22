<#
.SYNOPSIS
    Ermittelt lokale Windows-llama.cpp-Pakete für SQL-Embedding-Endpunkte.
.DESCRIPTION
    Prüft maximal 32 Suchwurzeln und jeweils höchstens 256 unmittelbare
    Unterverzeichnisse auf llama-server.exe und Backend-DLLs. Ohne SearchRoot
    werden SQL_SERVER_LAB_LLAMA_ROOT und der erste Prozess-PATH-Treffer genutzt.
    Laufwerkswurzeln sind ausgeschlossen. Keine Hashes oder Prozessstarts.
    FILES_ONLY bestätigt weder Paketursprung noch Geräte- oder Modellnutzung.
.PARAMETER SearchRoot
    Explizite Verzeichnisse ersetzen die Suche über Prozessvariable und PATH.
.PARAMETER Accelerator
    Filtert Paketkandidaten für CPU, GPU oder NPU; kein Gerätenachweis.
.OUTPUTS
    SqlServerLab.LlamaCppRuntime/1.0; enthält lokale Pfade, nicht versionieren.
.EXAMPLE
    Get-SqlServerLabLlamaCppRuntime -SearchRoot 'C:\Pfad\llama' -Accelerator NPU
#>
function Get-SqlServerLabLlamaCppRuntime {
    [CmdletBinding()]
    param(
        [ValidateCount(1,32)][ValidateNotNullOrEmpty()][string[]]$SearchRoot,
        [ValidateSet('CPU','GPU','NPU')][string]$Accelerator
    )
    Find-LabLlamaCppRuntime @PSBoundParameters
}
