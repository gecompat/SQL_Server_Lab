<#
.SYNOPSIS
    Plant die SQL-2025-Objekte für einen live verifizierten External-Model-Endpunkt.
.DESCRIPTION
    Bindet einen unveränderten External-Model-Plan an dessen frisches
    Endpoint-Receipt und erzeugt eine geheime-freie Mutations- und Cleanupfolge.
    Der Befehl verbindet sich nicht mit SQL Server und erzeugt keine Objekte.
.PARAMETER Plan
    Ergebnis von Get-SqlServerLabAiExternalModelPlan.
.PARAMETER EndpointReceipt
    Passendes Ergebnis von Test-SqlServerLabAiExternalModelEndpoint.
.PARAMETER DatabaseName
    Ziel-Datenbankname. Der Plan unterstützt absichtlich nur einen eng begrenzten
    portablen Bezeichner.
.PARAMETER MaxEndpointAgeSeconds
    Maximales Alter des Endpoint-Nachweises zwischen 30 und 3600 Sekunden.
.OUTPUTS
    SqlServerLab.AiExternalModelSqlPlan/1.0 ohne Secret oder SQL-Mutation.
.EXAMPLE
    Get-SqlServerLabAiExternalModelSqlPlan -Plan $plan -EndpointReceipt $receipt -DatabaseName AiLab
#>
function Get-SqlServerLabAiExternalModelSqlPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)]$EndpointReceipt,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z_][A-Za-z0-9_]{0,127}$')][string]$DatabaseName,
        [ValidateRange(30,3600)][int]$MaxEndpointAgeSeconds = 300
    )
    New-LabAiExternalModelSqlPlan @PSBoundParameters
}
