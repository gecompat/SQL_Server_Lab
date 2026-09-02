function Get-SqlServerLabCuStatus {
    <#
    .SYNOPSIS
        Vergleicht den lokalen CU-Katalog mit den offiziellen Microsoft-Buildtabellen.
    .DESCRIPTION
        Liest ausschließlich die konfigurierten Microsoft-Quellen und meldet neue
        CU-Metadaten für die unterstützten SQL-Versionen. Der Befehl verändert
        weder den Katalog noch Lab_Base. Neue Funde sind erst nach Bindung von
        MCR-Tag, Microsoft-Downloadquelle, SHA-256 und Signaturprüfung als
        Download verfügbar.
    .PARAMETER Version
        Beschränkt den Abgleich auf SQL-Produktjahre, beispielsweise 2019, 2022
        und 2025. Ohne Angabe werden alle unterstützten Versionen geprüft.
    .PARAMETER SourceUrl
        Wartungs-Override für eine offizielle Microsoft-Learn-Quellseite. Ohne
        Angabe wird der versionierte Quellenkatalog verwendet.
    .PARAMETER MaxMissingEntries
        Höchstzahl der je Version zurückgegebenen noch nicht katalogisierten CUs.
    .EXAMPLE
        Get-SqlServerLabCuStatus
    .EXAMPLE
        Get-SqlServerLabCuStatus -Version 2022,2025
    .OUTPUTS
        SqlServerLab.CuStatus/1.0 mit Status, Quelle, bekannten und neuen CUs.
    #>
    [CmdletBinding()]
    param(
        [string[]]$Version = @(),
        [string]$SourceUrl,
        [ValidateRange(1, 100)][int]$MaxMissingEntries = 5
    )

    $sources = if ([string]::IsNullOrWhiteSpace($SourceUrl)) {
        Get-LabCuStatusSourceConfiguration
    }
    else {
        $uri = try { [uri]$SourceUrl } catch { $null }
        if (-not $uri -or $uri.Scheme -ne 'https' -or $uri.Host -ne 'learn.microsoft.com') {
            throw 'SQL_CU_STATUS_SOURCE_OVERRIDE_NOT_ALLOWED: Es sind nur HTTPS-Quellen von learn.microsoft.com zulässig.'
        }
        @([PSCustomObject]@{ id='maintenance-override'; url=$uri.AbsoluteUri; allowedHosts=@('learn.microsoft.com','github.com','raw.githubusercontent.com'); description='Expliziter Microsoft-Learn-Wartungs-Override' })
    }

    return Invoke-LabCuStatusCheck -CatalogPath (Join-Path $script:CatalogsPath 'sql-server-versions.json') -Sources $sources -Version $Version -MaxMissingEntries $MaxMissingEntries
}
