function Get-LabSqlServerCollationCatalog {
    [CmdletBinding()]
    param()

    $catalogPath = Join-Path $script:CatalogsPath 'sql-server-collations.json'
    $schemaPath = Join-Path $script:SchemasPath 'sql-server-collation-catalog.schema.json'
    $json = Get-Content -LiteralPath $catalogPath -Raw -Encoding utf8
    if (-not ($json | Test-Json -SchemaFile $schemaPath -ErrorAction SilentlyContinue)) {
        throw 'SQL_COLLATION_CATALOG_INVALID'
    }
    $catalog = $json | ConvertFrom-Json -Depth 20
    $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $catalog.collations) {
        if (-not $names.Add([string]$entry.name)) { throw 'SQL_COLLATION_CATALOG_DUPLICATE_NAME' }
    }
    return $catalog
}

function Resolve-LabSqlServerCollation {
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyString()][string]$Name,
        [Parameter(Mandatory)][string]$SqlVersion
    )

    if ([string]::IsNullOrEmpty($Name)) { $Name = 'SQL_Latin1_General_CP1_CI_AS' }
    if ($Name -cnotmatch '^[A-Za-z0-9_]{1,128}$') { throw 'SQL_COLLATION_NAME_INVALID' }
    $version = Get-SqlServerVersion -VersionId $SqlVersion
    if (-not $version -or [string]$version.id -notin @('2019', '2022', '2025')) {
        throw 'SQL_COLLATION_VERSION_NOT_CATALOGED'
    }
    $entries = @(Get-LabSqlServerCollationCatalog | Select-Object -ExpandProperty collations | Where-Object {
        [string]::Equals([string]$_.name, $Name, [StringComparison]::OrdinalIgnoreCase) -and
        [string]$version.id -in @($_.supportedSqlVersions)
    })
    if ($entries.Count -ne 1) {
        throw 'SQL_COLLATION_NOT_CATALOGED: Vollstaendigen Namen mit Find-SqlServerLabCollation fuer die SQL-Version auswaehlen.'
    }
    return [string]$entries[0].name
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
