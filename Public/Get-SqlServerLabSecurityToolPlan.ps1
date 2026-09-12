function Get-SqlServerLabSecurityToolPlan {
    <#
    .SYNOPSIS
        Prueft Security-Tool-Metadaten gegen den lokalen Katalog, ohne Mutation.
    .DESCRIPTION
        Bindet exakte IDs und ein vollstaendiges Zieltuple. Die produktive
        Allowlist ist leer und blockiert alle Anfragen. Auch ein synthetisch
        passender Plan erteilt keine Beschaffungs- oder Ausfuehrungsautoritaet.
        Keine Netzwerk-, Datei-, Prozess-, Provider- oder Manifestmutation.
    .PARAMETER ToolId
        Exakte katalogisierte Tool-ID; keine Wildcards oder freien Quellen.
    .PARAMETER VariantId
        Exakte Varianten-ID; kein implizites latest.
    .PARAMETER PurposeId
        Exakte ID des katalogisierten SQL-Labzwecks.
    .PARAMETER Target
        Geschlossenes Dictionary mit sqlVersion, os, distribution, osVersion,
        architecture und provider. Kein Auto-Detect und keine Runbindung.
    .EXAMPLE
        Get-SqlServerLabSecurityToolPlan -ToolId synthetic-tool -VariantId synthetic-linux -PurposeId sql-tls -Target @{ sqlVersion='2025'; os='linux'; distribution='synthetic-linux'; osVersion='1.0'; architecture='x64'; provider='docker' }
        Liefert BLOCKED mit UNKNOWN_TOOL, weil die produktive Allowlist leer ist.
    .OUTPUTS
        SqlServerLab.SecurityToolPlan/1.0 als PSCustomObject; immer Executable=false.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ToolId,
        [Parameter(Mandatory)][string]$VariantId,
        [Parameter(Mandatory)][string]$PurposeId,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Target
    )

    $request = [ordered]@{
        contract = 'SqlServerLab.SecurityToolRequest/1.0'
        toolId = $ToolId; variantId = $VariantId; purposeId = $PurposeId; target = $Target
    }
    Resolve-LabSecurityToolPlan -RequestJson (ConvertTo-Json -InputObject $request -Depth 20 -Compress) -CatalogJson (Get-LabSecurityToolCatalogJson)
}
