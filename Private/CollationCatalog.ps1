function Get-LabSqlServerCollationCatalog {
    [CmdletBinding()]
    param()

    $catalogPath = Join-Path $script:CatalogsPath 'sql-server-collations.json'
    $schemaPath = Join-Path $script:SchemasPath 'sql-server-collation-catalog.schema.json'
    $json = Get-Content -LiteralPath $catalogPath -Raw -Encoding utf8
    if (-not ($json | Test-Json -SchemaFile $schemaPath -ErrorAction SilentlyContinue)) {
        throw 'SQL_COLLATION_CATALOG_INVALID'
    }
    return $json | ConvertFrom-Json -Depth 20
}

function Find-LabSqlServerCollation {
    [CmdletBinding()]
    param(
        [string]$Query,
        [ValidateSet('2019', '2022', '2025')][string]$SqlVersion = '2025'
    )

    $tokens = @($Query -split '[^A-Za-z0-9]+' | Where-Object { $_ } | ForEach-Object { $_.ToLowerInvariant() })
    $matches = @(Get-LabSqlServerCollationCatalog | Select-Object -ExpandProperty collations | Where-Object {
        $entry = $_
        $searchText = ("$($entry.name) $($entry.locale)").ToLowerInvariant()
        $SqlVersion -in @($entry.supportedSqlVersions) -and
        @($tokens | Where-Object { $searchText -notlike "*$_*" }).Count -eq 0
    })
    return @($matches | Sort-Object name | ForEach-Object {
        [PSCustomObject]@{
            Name = [string]$_.name; Locale = [string]$_.locale; CodePage = [int]$_.codePage; Lcid = [int]$_.lcid
            CaseSensitivity = [string]$_.caseSensitivity; AccentSensitivity = [string]$_.accentSensitivity
            Utf8 = [bool]$_.utf8; Status = [string]$_.status; SqlVersion = $SqlVersion
        }
    })
}
