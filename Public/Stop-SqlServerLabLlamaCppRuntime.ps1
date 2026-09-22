<#
.SYNOPSIS
    Beendet ausschließlich einen in dieser Modulsitzung gestarteten llama.cpp-Server.
.DESCRIPTION
    Schließt den Kontrollkanal des eigenen Workers, bestätigt dessen Ende und
    entfernt die temporäre API-Key-Datei. Fremde PIDs und Sitzungen blockieren.
    Laufzeitlogs bleiben lokal zur Diagnose; Caller-Zertifikate bleiben erhalten.
.PARAMETER OperationId
    Vom Start zurückgegebene OperationId aus derselben importierten Modulsitzung.
.OUTPUTS
    SqlServerLab.LlamaCppCleanup/1.0 mit separatem Cleanupstatus.
.EXAMPLE
    Stop-SqlServerLabLlamaCppRuntime -OperationId $runtime.OperationId
#>
function Stop-SqlServerLabLlamaCppRuntime {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][ValidatePattern('^[a-f0-9-]{36}$')][string]$OperationId)
    if ($PSCmdlet.ShouldProcess('owned llama.cpp runtime', 'Stop')) {
        $arguments = @{} + $PSBoundParameters
        $arguments.Remove('WhatIf'); $arguments.Remove('Confirm')
        Stop-LabLlamaCppOwnedRuntime @arguments
    }
}
