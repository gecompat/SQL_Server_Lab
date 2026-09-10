<#
.SYNOPSIS
    Durchsucht den versionsgebundenen SQL-Server-Collation-Katalog.
.DESCRIPTION
    Filtert alle Suchwörter gegen Collation-Namen und Locale ohne Runtime- oder
    State-Mutation. Die Ausgabe ist eine kuratierte Auswahl; eine spätere
    Installation prüft ihre tatsächlich verfügbaren Collations zusätzlich in
    SQL Server.
.PARAMETER Query
    Leer oder ein oder mehrere Suchwörter, etwa `Latin1 UTF8`.
.PARAMETER SqlVersion
    SQL-Major-Version des Ziel-Labs.
.OUTPUTS
    Sanitisierte Collation-Metadaten ohne lokale Pfade oder Secrets.
#>
function Find-SqlServerLabCollation {
    [CmdletBinding()]
    param(
        [string]$Query,
        [ValidateSet('2019', '2022', '2025')][string]$SqlVersion = '2025'
    )

    return Find-LabSqlServerCollation -Query $Query -SqlVersion $SqlVersion
}
