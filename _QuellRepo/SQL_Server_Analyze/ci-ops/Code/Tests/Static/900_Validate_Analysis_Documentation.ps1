[CmdletBinding()]
param(
    [string]$RepositoryRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
}

$referencePath = Join-Path $RepositoryRoot 'Documentation/Reference/Procedure_Reference.md'
$pagesRoot = Join-Path $RepositoryRoot 'Documentation/Analysis_Guides/Procedures'
$objectIndexPath = Join-Path $RepositoryRoot 'Documentation/Analysis_Guides/Object_Index.md'
$technicalFoundationsPath = Join-Path $RepositoryRoot 'Documentation/Analysis_Guides/Technical_Foundations.md'
$objectReferencePath = Join-Path $RepositoryRoot 'Documentation/Reference/Object_Reference.md'
$callCatalogPath = Join-Path $RepositoryRoot 'Documentation/Reference/Call_Catalog.md'
$objectInventoryPath = Join-Path $RepositoryRoot 'Metadata/Inventory/Objects.csv'
$resultSetsPath = Join-Path $RepositoryRoot 'Metadata/Inventory/ResultSets.csv'
$reviewManifestPath = Join-Path $RepositoryRoot 'Metadata/Quality/Analysis_Documentation_Review.csv'
$rootReadmePath = Join-Path $RepositoryRoot 'README.md'
$documentationReadmePath = Join-Path $RepositoryRoot 'Documentation/README.md'
$codeRoot = Join-Path $RepositoryRoot 'Code'
$requiredHeadings = @(
    '## Eine Zeile bedeutet',
    '## So lesen',
    '## Warum kann das problematisch sein?',
    '## Wann ist es kein Problem?',
    '## Technische Vertiefung',
    '### Leitfrage',
    '### Technischer Hintergrund',
    '### Datenkette',
    '### Source Select',
    '### Zeit- und Scope-Modell',
    '### Bewertung und Gegenprobe',
    '### Typische Fehlinterpretation',
    '### Folgeanalyse'
)
$deepReviewedRequiredHeadings = @(
    '## Entscheidungsfrage und Einsatz',
    '## Nicht beantwortete Fragen',
    '## Sicherer Einstieg',
    '## Resultsets und Leserichtung',
    '## Beispiele und Gegenbeispiele',
    '## Leere oder partielle Ausgabe',
    '## Eigenlast und Grenzen',
    '## Primärquellen'
)
$deepReviewedCostDimensions = @(
    'Kostenklasse',
    'Standardpfad',
    'Teuerster Pfad',
    'Haupttreiber',
    'Skalierung',
    'Ressourcen',
    'Begrenzungswirkung',
    'Locking und Nebenwirkungen',
    'Schutzmechanismus',
    'Sicherer Einsatz',
    'Aussagegrenze'
)
$referenceDeepReviewedPages = @(
    'USP_CurrentRequests',
    'USP_IndexPhysicalStats',
    'USP_ExtendedEventsReadEvents'
)
$safeEntryRequiresHighImpact = @(
    'USP_DataCaptureDeepAnalysis',
    'USP_ExtendedEventsBlockedProcesses',
    'USP_ExtendedEventsDeadlocks',
    'USP_ExtendedEventsReadEvents',
    'USP_ExtendedEventsTargetRuntime',
    'USP_FullTextAnalysis',
    'USP_IndexPhysicalStats',
    'USP_IntelligentQueryProcessingAnalysis',
    'USP_PlanDetails',
    'USP_PlanCacheAnalysis',
    'USP_QueryHashAnalysis',
    'USP_SchemaDesignAnalysis',
    'USP_ServiceBrokerAnalysis',
    'USP_StatisticsDistributionAnalysis',
    'USP_TemporalAnalysis'
)
$minimumDeepReviewedCount = 89
$supportingRequiredDimensions = @(
    'Aufgabe',
    'Schnittstelle',
    'Verwendung',
    'Last und Sperren',
    'Vertrag'
)
$supportingMinimumWordCount = 90

$errors = [System.Collections.Generic.List[string]]::new()
$markdownAnchorCache = @{}

function ConvertTo-CanonicalParameterDeclarations {
    param([AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return @()
    }

    $normalized = [regex]::Replace($Text, '(?m)--.*$', '')
    $normalized = [regex]::Replace($normalized, '(?m)\r?\n\s*,\s*', ', ')
    $normalized = [regex]::Replace($normalized, '\s+', ' ').Trim()
    $normalized = $normalized.TrimStart(',').Trim()

    if ([string]::IsNullOrWhiteSpace($normalized)) {
        return @()
    }

    return @(
        [regex]::Split($normalized, ',\s*(?=@[A-Za-z_])') |
            ForEach-Object {
                $declaration = $_.Trim()
                $declaration = [regex]::Replace($declaration, '\s*=\s*', ' = ')
                $declaration = [regex]::Replace($declaration, '\s*,\s*', ',')
                $declaration = [regex]::Replace($declaration, '\s+', ' ')
                $declaration.Trim()
            } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
}

function Get-ParameterName {
    param([string]$Declaration)

    $match = [regex]::Match($Declaration, '^(@[A-Za-z_][A-Za-z0-9_]*)\b')
    if (-not $match.Success) {
        return $null
    }
    return $match.Groups[1].Value
}

function ConvertTo-MarkdownAnchor {
    param([string]$Heading)

    $value = [regex]::Replace($Heading.Trim(), '<[^>]+>', '')
    $value = [regex]::Replace($value, '[`*~]', '')
    $value = $value.ToLowerInvariant()
    $value = [regex]::Replace($value, '[^\p{L}\p{Nd}\- _]', '')
    $value = [regex]::Replace($value, ' +', '-')
    $value = [regex]::Replace($value, '-{2,}', '-')
    return $value.Trim('-')
}

function Get-MarkdownAnchors {
    param([string]$MarkdownPath)

    $fullPath = [System.IO.Path]::GetFullPath($MarkdownPath)
    if ($markdownAnchorCache.ContainsKey($fullPath)) {
        return @($markdownAnchorCache[$fullPath])
    }

    $text = Get-Content -LiteralPath $fullPath -Raw -Encoding UTF8
    $counts = @{}
    $anchors = [System.Collections.Generic.List[string]]::new()
    $headingMatches = [regex]::Matches($text, '(?m)^\s{0,3}#{1,6}\s+(.+?)\s*#*\s*$')

    foreach ($headingMatch in $headingMatches) {
        $baseAnchor = ConvertTo-MarkdownAnchor $headingMatch.Groups[1].Value
        if ([string]::IsNullOrWhiteSpace($baseAnchor)) {
            continue
        }

        if ($counts.ContainsKey($baseAnchor)) {
            $suffix = [int]$counts[$baseAnchor]
            $anchors.Add("$baseAnchor-$suffix")
            $counts[$baseAnchor] = $suffix + 1
        }
        else {
            $anchors.Add($baseAnchor)
            $counts[$baseAnchor] = 1
        }
    }

    $markdownAnchorCache[$fullPath] = @($anchors)
    return @($anchors)
}

foreach ($requiredPath in @($referencePath, $objectIndexPath, $technicalFoundationsPath, $objectReferencePath, $callCatalogPath, $objectInventoryPath, $resultSetsPath, $reviewManifestPath, $rootReadmePath, $documentationReadmePath)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Required documentation file not found: $requiredPath"
    }
}
foreach ($requiredDirectory in @($pagesRoot, $codeRoot)) {
    if (-not (Test-Path -LiteralPath $requiredDirectory -PathType Container)) {
        throw "Required directory not found: $requiredDirectory"
    }
}

$referenceText = Get-Content -LiteralPath $referencePath -Raw -Encoding UTF8
$objectIndexText = Get-Content -LiteralPath $objectIndexPath -Raw -Encoding UTF8
$objectReferenceText = Get-Content -LiteralPath $objectReferencePath -Raw -Encoding UTF8
$callCatalogText = Get-Content -LiteralPath $callCatalogPath -Raw -Encoding UTF8
$objectInventoryRows = @(Import-Csv -LiteralPath $objectInventoryPath -Encoding UTF8)
$expectedProcedureNames = @(
    $objectInventoryRows |
        Where-Object { $_.ObjectType -eq 'PROCEDURE' -and $_.ObjectName -match '^USP_' } |
        ForEach-Object { $_.ObjectName } |
        Sort-Object -Unique
)
$supportingObjectRows = @(
    $objectInventoryRows |
        Where-Object { -not ($_.ObjectType -eq 'PROCEDURE' -and $_.ObjectName -match '^USP_') }
)
$supportingReferenceSectionNames = @(
    [regex]::Matches(
        $objectReferenceText,
        '(?m)^### `\[[A-Za-z_][A-Za-z0-9_]*\]\.\[([A-Za-z_][A-Za-z0-9_]*)\]`\s*$'
    ) |
        ForEach-Object { $_.Groups[1].Value }
)
$duplicateSupportingReferenceSections = @(
    $supportingReferenceSectionNames |
        Group-Object |
        Where-Object { $_.Count -gt 1 }
)
foreach ($duplicate in $duplicateSupportingReferenceSections) {
    $errors.Add("Duplicate supporting-object reference section: $($duplicate.Name)")
}
foreach ($name in @($supportingReferenceSectionNames | Where-Object { $_ -notin $supportingObjectRows.ObjectName })) {
    $errors.Add("Object-reference section is missing from inventory: $name")
}

$sectionMatches = [regex]::Matches(
    $referenceText,
    '(?ms)^## `\[monitor\]\.\[(USP_[A-Za-z0-9_]+)\]`\s*$\s*(.*?)(?=^## `\[monitor\]\.\[USP_[A-Za-z0-9_]+\]`|\z)'
)

$referenceNames = @($sectionMatches | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
$callCatalogNames = @(
    [regex]::Matches($callCatalogText, '(?m)^## `\[monitor\]\.\[(USP_[A-Za-z0-9_]+)\]`\s*$') |
        ForEach-Object { $_.Groups[1].Value } |
        Sort-Object -Unique
)
$resultSetRows = @(Import-Csv -LiteralPath $resultSetsPath -Encoding UTF8)
$reviewRows = @(Import-Csv -LiteralPath $reviewManifestPath -Encoding UTF8)
$resultSetProcedureNames = @($resultSetRows | ForEach-Object { $_.ProcedureName } | Sort-Object -Unique)
$expectedResultSetProcedureNames = @(
    $referenceNames |
        Where-Object {
            $_ -notin @(
                'USP_PrepareDatabaseCandidates',
                'USP_PrepareNameFilters',
                'USP_ConfigureSnapshotTarget'
            )
        }
)
if ($resultSetProcedureNames.Count -ne $expectedResultSetProcedureNames.Count) {
    $errors.Add("Expected $($expectedResultSetProcedureNames.Count) procedures in the result-set inventory, found $($resultSetProcedureNames.Count).")
}
$pageFiles = @(Get-ChildItem -LiteralPath $pagesRoot -Filter 'USP_*.md' -File)
$pageNames = @($pageFiles | ForEach-Object { $_.BaseName } | Sort-Object -Unique)
$parameterNamesByProcedure = @{}
$declaredSourcePaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$reviewStatusByProcedure = @{}

if ($objectInventoryRows.Count -eq 0) {
    $errors.Add('Object inventory is empty.')
}
foreach ($row in $objectInventoryRows) {
    if ([string]::IsNullOrWhiteSpace($row.ObjectType) -or
        [string]::IsNullOrWhiteSpace($row.ObjectName) -or
        [string]::IsNullOrWhiteSpace($row.SourcePath)) {
        $errors.Add('Incomplete object-inventory row.')
        continue
    }

    $inventorySourcePath = Join-Path $RepositoryRoot $row.SourcePath
    if (-not (Test-Path -LiteralPath $inventorySourcePath -PathType Leaf)) {
        $errors.Add("Inventory source does not exist: $($row.ObjectType)/$($row.ObjectName)")
    }
}

foreach ($row in $supportingObjectRows) {
    $inventorySourcePath = Join-Path $RepositoryRoot $row.SourcePath
    if (-not (Test-Path -LiteralPath $inventorySourcePath -PathType Leaf)) {
        continue
    }

    $inventorySourceText = Get-Content -LiteralPath $inventorySourcePath -Raw -Encoding UTF8
    $declarationPattern = '(?ims)\bCREATE\s+(?:OR\s+ALTER\s+)?(?:TABLE|VIEW|FUNCTION|PROCEDURE)\s+' +
        '\[(?<Schema>[A-Za-z_][A-Za-z0-9_]*)\]\.\[' + [regex]::Escape($row.ObjectName) + '\]'
    $declarationMatch = [regex]::Match($inventorySourceText, $declarationPattern)
    if (-not $declarationMatch.Success) {
        $errors.Add("Supporting object declaration not found: $($row.ObjectType)/$($row.ObjectName)")
        continue
    }

    $schemaName = $declarationMatch.Groups['Schema'].Value
    $headingPattern = '(?m)^### `\[' + [regex]::Escape($schemaName) + '\]\.\[' + [regex]::Escape($row.ObjectName) + '\]`\s*$'
    if ($objectReferenceText -notmatch $headingPattern) {
        $errors.Add("Supporting object missing from object reference: $($row.ObjectType)/$($row.ObjectName)")
        continue
    }

    $sectionPattern = '(?ms)^### `\[' + [regex]::Escape($schemaName) + '\]\.\[' + [regex]::Escape($row.ObjectName) + '\]`\s*$\s*(.*?)(?=^### `\[[A-Za-z_][A-Za-z0-9_]*\]\.\[|\z)'
    $sectionMatch = [regex]::Match($objectReferenceText, $sectionPattern)
    if (-not $sectionMatch.Success -or $sectionMatch.Groups[1].Value -notmatch ('(?m)^Quelle:\s*`' + [regex]::Escape($row.SourcePath) + '`\s*$')) {
        $errors.Add("Supporting object has no canonical source declaration: $($row.ObjectType)/$($row.ObjectName)")
        continue
    }

    $supportingSectionBody = $sectionMatch.Groups[1].Value
    foreach ($dimension in $supportingRequiredDimensions) {
        $dimensionPattern = '(?m)^\|\s*' + [regex]::Escape($dimension) + '\s*\|\s*\S.*\|\s*$'
        if ($supportingSectionBody -notmatch $dimensionPattern) {
            $errors.Add("Supporting object is missing documentation dimension '$dimension': $($row.ObjectType)/$($row.ObjectName)")
        }
    }

    $supportingWordCount = [regex]::Matches(
        $supportingSectionBody,
        '[\p{L}\p{Nd}][\p{L}\p{Nd}_-]*'
    ).Count
    if ($supportingWordCount -lt $supportingMinimumWordCount) {
        $errors.Add("Supporting object documentation is below the $supportingMinimumWordCount-word substantive floor ($supportingWordCount): $($row.ObjectType)/$($row.ObjectName)")
    }
}

foreach ($name in @($expectedProcedureNames | Where-Object { $_ -notin $referenceNames })) {
    $errors.Add("Inventory procedure missing from procedure reference: $name")
}
foreach ($name in @($referenceNames | Where-Object { $_ -notin $expectedProcedureNames })) {
    $errors.Add("Procedure reference entry missing from object inventory: $name")
}
foreach ($name in @($expectedProcedureNames | Where-Object { $_ -notin $callCatalogNames })) {
    $errors.Add("Inventory procedure missing from call catalog: $name")
}
foreach ($name in @($callCatalogNames | Where-Object { $_ -notin $expectedProcedureNames })) {
    $errors.Add("Call-catalog procedure missing from object inventory: $name")
}

foreach ($name in @($referenceNames | Where-Object { $_ -notin $pageNames })) {
    $errors.Add("Missing procedure page: $name")
}
foreach ($name in @($pageNames | Where-Object { $_ -notin $referenceNames })) {
    $errors.Add("Procedure page without reference entry: $name")
}
foreach ($name in @($expectedResultSetProcedureNames | Where-Object { $_ -notin $resultSetProcedureNames })) {
    $errors.Add("Missing result-set inventory procedure: $name")
}
foreach ($name in @($resultSetProcedureNames | Where-Object { $_ -notin $expectedResultSetProcedureNames })) {
    $errors.Add("Unknown result-set inventory procedure: $name")
}

if ($reviewRows.Count -eq 0) {
    $errors.Add('Analysis documentation review manifest is empty.')
}
else {
    $requiredReviewColumns = @('ProcedureName', 'ReviewStatus', 'ReviewedUtc', 'ReviewContractVersion')
    $actualReviewColumns = @($reviewRows[0].PSObject.Properties.Name)
    foreach ($column in $requiredReviewColumns) {
        if ($column -notin $actualReviewColumns) {
            $errors.Add("Missing review-manifest column: $column")
        }
    }
}

$reviewProcedureNames = @(
    $reviewRows |
        ForEach-Object { $_.ProcedureName } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Sort-Object -Unique
)
foreach ($name in @($referenceNames | Where-Object { $_ -notin $reviewProcedureNames })) {
    $errors.Add("Missing review-manifest procedure: $name")
}
foreach ($name in @($reviewProcedureNames | Where-Object { $_ -notin $referenceNames })) {
    $errors.Add("Unknown review-manifest procedure: $name")
}

$duplicateReviewRows = @(
    $reviewRows |
        Group-Object -Property ProcedureName |
        Where-Object { $_.Count -gt 1 }
)
foreach ($duplicate in $duplicateReviewRows) {
    $errors.Add("Duplicate review-manifest procedure: $($duplicate.Name)")
}

foreach ($row in $reviewRows) {
    $procedureName = $row.ProcedureName
    if ([string]::IsNullOrWhiteSpace($procedureName)) {
        $errors.Add('Review-manifest row has no ProcedureName.')
        continue
    }

    $reviewStatusByProcedure[$procedureName] = $row.ReviewStatus
    switch ($row.ReviewStatus) {
        'BASELINE' {
            if (-not [string]::IsNullOrWhiteSpace($row.ReviewedUtc)) {
                $errors.Add("BASELINE review row must not have ReviewedUtc: $procedureName")
            }
            if ($row.ReviewContractVersion -ne '1') {
                $errors.Add("BASELINE review row must use contract version 1: $procedureName")
            }
        }
        'DEEP_REVIEWED' {
            if ($row.ReviewContractVersion -ne '3') {
                $errors.Add("DEEP_REVIEWED row must use contract version 3: $procedureName")
            }
            try {
                [void][datetime]::ParseExact(
                    $row.ReviewedUtc,
                    'yyyy-MM-dd',
                    [System.Globalization.CultureInfo]::InvariantCulture
                )
            }
            catch {
                $errors.Add("DEEP_REVIEWED row has invalid ReviewedUtc: $procedureName")
            }
        }
        default {
            $errors.Add("Invalid review status '$($row.ReviewStatus)': $procedureName")
        }
    }
}

$deepReviewedCount = @($reviewRows | Where-Object { $_.ReviewStatus -eq 'DEEP_REVIEWED' }).Count
if ($deepReviewedCount -lt $minimumDeepReviewedCount) {
    $errors.Add("Expected at least $minimumDeepReviewedCount DEEP_REVIEWED pages, found $deepReviewedCount.")
}
foreach ($name in $referenceDeepReviewedPages) {
    if (-not $reviewStatusByProcedure.ContainsKey($name) -or $reviewStatusByProcedure[$name] -ne 'DEEP_REVIEWED') {
        $errors.Add("Reference page must remain DEEP_REVIEWED: $name")
    }
}

foreach ($row in $resultSetRows) {
    if ([string]::IsNullOrWhiteSpace($row.ResultName) -or
        [string]::IsNullOrWhiteSpace($row.SourceTable) -or
        [string]::IsNullOrWhiteSpace($row.SourceSchema) -or
        $row.IsTableExportable -ne '1') {
        $errors.Add("Incomplete TABLE-exportable result-set inventory row: $($row.ProcedureName)/$($row.ResultName)")
    }
}

$duplicateResultSetKeys = @(
    $resultSetRows |
        Group-Object -Property ProcedureName,ResultName |
        Where-Object { $_.Count -gt 1 }
)
foreach ($duplicate in $duplicateResultSetKeys) {
    $errors.Add("Duplicate result-set inventory key: $($duplicate.Name)")
}

foreach ($name in $referenceNames) {
    $expectedIndexLink = "Procedures/$name.md"
    if ($objectIndexText.IndexOf($expectedIndexLink, [System.StringComparison]::Ordinal) -lt 0) {
        $errors.Add("Object index does not link procedure page: $name")
    }
}

foreach ($sectionMatch in $sectionMatches) {
    $procedureName = $sectionMatch.Groups[1].Value
    $sectionBody = $sectionMatch.Groups[2].Value
    $sourceMatch = [regex]::Match($sectionBody, '(?m)^Quelle:\s*`([^`]+)`\s*$')
    $signatureMatch = [regex]::Match($sectionBody, '(?ms)^```sql\s*$\s*(.*?)\s*^```\s*$')

    if (-not $sourceMatch.Success) {
        $errors.Add("Missing source path in procedure reference: $procedureName")
        continue
    }
    if (-not $signatureMatch.Success) {
        $errors.Add("Missing parameter signature in procedure reference: $procedureName")
        continue
    }

    $relativeSourcePath = $sourceMatch.Groups[1].Value.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
    $sourcePath = [System.IO.Path]::GetFullPath((Join-Path $RepositoryRoot $relativeSourcePath))
    [void]$declaredSourcePaths.Add($sourcePath)

    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        $errors.Add("Referenced SQL source does not exist: $procedureName")
        continue
    }

    $sourceText = Get-Content -LiteralPath $sourcePath -Raw -Encoding UTF8
    $sourceProcedureMatch = [regex]::Match(
        $sourceText,
        '(?ims)^\s*CREATE\s+OR\s+ALTER\s+PROCEDURE\s+\[monitor\]\.\[(USP_[A-Za-z0-9_]+)\]\s*(.*?)^\s*AS\s*$'
    )

    if (-not $sourceProcedureMatch.Success) {
        $errors.Add("CREATE OR ALTER PROCEDURE declaration not found in referenced source: $procedureName")
        continue
    }

    $sourceProcedureName = $sourceProcedureMatch.Groups[1].Value
    if (-not [string]::Equals($procedureName, $sourceProcedureName, [System.StringComparison]::Ordinal)) {
        $errors.Add("Procedure name differs between reference and source: $procedureName")
    }

    $referenceDeclarations = @(ConvertTo-CanonicalParameterDeclarations $signatureMatch.Groups[1].Value)
    $sourceDeclarations = @(ConvertTo-CanonicalParameterDeclarations $sourceProcedureMatch.Groups[2].Value)
    $referenceParameterNames = @($referenceDeclarations | ForEach-Object { Get-ParameterName $_ })
    $sourceParameterNames = @($sourceDeclarations | ForEach-Object { Get-ParameterName $_ })
    $parameterNamesByProcedure[$procedureName] = @($sourceParameterNames)

    if ($referenceDeclarations.Count -ne $sourceDeclarations.Count) {
        $errors.Add("Parameter count differs between reference and source: $procedureName")
        continue
    }

    for ($index = 0; $index -lt $referenceDeclarations.Count; $index++) {
        if (-not [string]::Equals($referenceParameterNames[$index], $sourceParameterNames[$index], [System.StringComparison]::Ordinal)) {
            $errors.Add("Parameter name or order differs at position $($index + 1): $procedureName")
            continue
        }
        if (-not [string]::Equals($referenceDeclarations[$index], $sourceDeclarations[$index], [System.StringComparison]::OrdinalIgnoreCase)) {
            $errors.Add("Parameter declaration or default differs for $($sourceParameterNames[$index]): $procedureName")
        }
    }
}

$sourceProcedureNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
$sqlFiles = @(
    Get-ChildItem -LiteralPath $codeRoot -Filter '*.sql' -File -Recurse |
        Where-Object {
            $_.FullName -notmatch '[\\/](Tests|Install)[\\/]'
        }
)
foreach ($sqlFile in $sqlFiles) {
    $sqlText = Get-Content -LiteralPath $sqlFile.FullName -Raw -Encoding UTF8
    if ([regex]::IsMatch($sqlText, '(?i)\bIN\s*\((?=[^)]*\b229\b)(?![^)]*\b371\b)[^)]*\)') -or
        [regex]::IsMatch($sqlText, "(?i)ERROR_NUMBER\(\)\s*=\s*229\s+THEN\s*'DENIED_PERMISSION'")) {
        $errors.Add("Permission error mappings must include SQL Server 2025 error 371: $($sqlFile.FullName)")
    }
    $procedureMatches = [regex]::Matches(
        $sqlText,
        '(?im)^\s*CREATE\s+OR\s+ALTER\s+PROCEDURE\s+\[monitor\]\.\[(USP_[A-Za-z0-9_]+)\]'
    )
    foreach ($procedureMatch in $procedureMatches) {
        [void]$sourceProcedureNames.Add($procedureMatch.Groups[1].Value)
    }
}

foreach ($name in @($referenceNames | Where-Object { -not $sourceProcedureNames.Contains($_) })) {
    $errors.Add("Referenced procedure not found in canonical SQL sources: $name")
}
foreach ($name in @($sourceProcedureNames | Where-Object { $_ -notin $referenceNames } | Sort-Object)) {
    $errors.Add("Canonical SQL procedure missing from procedure reference: $name")
}

foreach ($file in $pageFiles) {
    $text = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8
    $expectedTitle = "# [monitor].[$($file.BaseName)]"

    if (-not $text.StartsWith($expectedTitle, [System.StringComparison]::Ordinal)) {
        $errors.Add("Invalid or missing title: $($file.FullName)")
    }

    foreach ($heading in $requiredHeadings) {
        if ($text.IndexOf($heading, [System.StringComparison]::Ordinal) -lt 0) {
            $errors.Add("Missing heading '$heading': $($file.FullName)")
        }
    }

    $sourceSelectMatches = [regex]::Matches(
        $text,
        '(?ms)^### Source Select\s*$\s*(.*?)(?=^### |\z)'
    )
    if ($sourceSelectMatches.Count -ne 1) {
        $errors.Add("Expected exactly one Source Select section: $($file.FullName)")
    }
    else {
        $sourceSelectBody = $sourceSelectMatches[0].Groups[1].Value
        $hasSqlExample = $sourceSelectBody -match '(?m)^```sql\s*$'
        $hasExplainedNonSelectPath =
            $sourceSelectBody.Contains('Kein einzelnes Grundselect') -or
            $sourceSelectBody.Contains('Kein direktes `SELECT`') -or
            $sourceSelectBody.Contains('Kein `SELECT` auf eine DMV')

        if (-not $hasSqlExample -and -not $hasExplainedNonSelectPath) {
            $errors.Add("Source Select has neither SQL nor an explained non-SELECT path: $($file.FullName)")
        }
        if (-not $sourceSelectBody.Contains('**Wichtig für die Eigenlast:**')) {
            $errors.Add("Source Select has no resource-scope note: $($file.FullName)")
        }
    }

    if ($text -notmatch '\[Technische Detailbeschreibung\]\(') {
        $errors.Add("Missing technical detail link: $($file.FullName)")
    }

    if ($text -notmatch '\[Gemeinsames Execution-, Zeit- und Evidenzmodell\]\(\.\./Technical_Foundations\.md\)') {
        $errors.Add("Missing technical foundations link: $($file.FullName)")
    }

    if ($reviewStatusByProcedure.ContainsKey($file.BaseName) -and
        $reviewStatusByProcedure[$file.BaseName] -eq 'DEEP_REVIEWED') {
        foreach ($heading in $deepReviewedRequiredHeadings) {
            if ($text.IndexOf($heading, [System.StringComparison]::Ordinal) -lt 0) {
                $errors.Add("Missing DEEP_REVIEWED heading '$heading': $($file.FullName)")
            }
        }

        foreach ($dimension in $deepReviewedCostDimensions) {
            $dimensionPattern = '(?m)^\|\s*' + [regex]::Escape($dimension) + '\s*\|'
            if ($text -notmatch $dimensionPattern) {
                $errors.Add("Missing DEEP_REVIEWED cost dimension '$dimension': $($file.FullName)")
            }
        }

        if ($text -notmatch '(?m)^\*\*Beobachtungsart:\*\*\s+\S') {
            $errors.Add("Missing DEEP_REVIEWED observation type: $($file.FullName)")
        }
        if ($text -notmatch '(?m)^\*\*Kostenklasse:\*\*\s+\S') {
            $errors.Add("Missing DEEP_REVIEWED cost class: $($file.FullName)")
        }
        elseif ($text -notmatch '(?m)^\*\*Kostenklasse:\*\*\s+.*(?:LOW|MEDIUM|HIGH_OPT_IN)') {
            $errors.Add("Invalid DEEP_REVIEWED cost class: $($file.FullName)")
        }
        if ($text -match '(?m)^\|\s*Kostenklasse\s*\|\s*(?:None|TBD|N/?A|[-–])\s*\|') {
            $errors.Add("Placeholder DEEP_REVIEWED cost class: $($file.FullName)")
        }
        if ($file.BaseName -in $safeEntryRequiresHighImpact) {
            $safeEntryMatch = [regex]::Match(
                $text,
                '(?ms)^## Sicherer Einstieg\s*$\s*(.*?)(?=^## |\z)'
            )
            if (-not $safeEntryMatch.Success -or
                $safeEntryMatch.Groups[1].Value -notmatch '@HighImpactConfirmed\s*=\s*1') {
                $errors.Add("Safe entry must show required @HighImpactConfirmed = 1: $($file.FullName)")
            }
        }
        if ($text -notmatch '(?m)^## Primärquellen\s*$[\s\S]*https://learn\.microsoft\.com/') {
            $errors.Add("Missing Microsoft primary source in DEEP_REVIEWED page: $($file.FullName)")
        }
        $externalSectionMatch = [regex]::Match(
            $text,
            '(?ms)^## Weiterführende Vertiefung\s*$\s*(.*?)(?=^## |^\[Technische Detailbeschreibung\]|\z)'
        )
        if ($externalSectionMatch.Success) {
            $externalSection = $externalSectionMatch.Groups[1].Value
            if ($externalSection -notmatch 'https://(?!learn\.microsoft\.com/)[^\s)>]+') {
                $errors.Add("External deep-dive section has no non-Microsoft HTTPS source: $($file.FullName)")
            }
            if ($externalSection -match 'http://') {
                $errors.Add("External deep-dive source must use HTTPS: $($file.FullName)")
            }
            if ($externalSection -notmatch 'keine Grundlage für versions-, Berechtigungs- oder Engineaussagen') {
                $errors.Add("External deep-dive section does not state its evidence boundary: $($file.FullName)")
            }
        }
        if ($text.IndexOf('Example', [System.StringComparison]::Ordinal) -lt 0) {
            $errors.Add("Missing explicit synthetic Example* marker in DEEP_REVIEWED page: $($file.FullName)")
        }

        $wordCount = [regex]::Matches($text, '[\p{L}\p{Nd}][\p{L}\p{Nd}_-]*').Count
        if ($wordCount -lt 700) {
            $errors.Add("DEEP_REVIEWED page is below the 700-word substantive floor ($wordCount): $($file.FullName)")
        }
    }

    if ($parameterNamesByProcedure.ContainsKey($file.BaseName)) {
        $knownParameterNames = @($parameterNamesByProcedure[$file.BaseName])
        $procedurePattern = [regex]::Escape($file.BaseName)
        $codeBlockMatches = [regex]::Matches($text, '(?ms)```(?:sql|tsql)\s*(.*?)```')

        foreach ($codeBlockMatch in $codeBlockMatches) {
            $callMatches = [regex]::Matches(
                $codeBlockMatch.Groups[1].Value,
                "(?ims)\bEXEC(?:UTE)?\s+(?:\[monitor\]|monitor)\s*\.\s*(?:\[$procedurePattern\]|$procedurePattern)\b(?<Arguments>.*?)(?:;|\z)"
            )
            foreach ($callMatch in $callMatches) {
                $assignedParameters = [regex]::Matches($callMatch.Groups['Arguments'].Value, '(@[A-Za-z_][A-Za-z0-9_]*)\s*=')
                foreach ($assignedParameter in $assignedParameters) {
                    $parameterName = $assignedParameter.Groups[1].Value
                    if ($parameterName -notin $knownParameterNames) {
                        $errors.Add("Unknown parameter in documented EXEC example: $($file.BaseName) $parameterName")
                    }
                }
            }
        }
    }
}

$documentationRoot = [System.IO.Path]::GetFullPath((Join-Path $RepositoryRoot 'Documentation'))
$allMarkdown = @(Get-ChildItem -LiteralPath $documentationRoot -Filter '*.md' -File -Recurse)
$linkedMarkdownPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$navigationSources = @($allMarkdown) + @(Get-Item -LiteralPath $rootReadmePath)
foreach ($file in $navigationSources) {
    $text = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8
    $linkScanText = [regex]::Replace(
        $text,
        '(?ms)^[ \t]*```[^\r\n]*\r?\n.*?^[ \t]*```[ \t]*(?:\r?\n|\z)',
        ''
    )
    $relativeLinks = [regex]::Matches(
        $linkScanText,
        '\[[^\]]+\]\((?!https?://|mailto:)(?<Target>[^)#]*)(?:#(?<Fragment>[^)]+))?\)'
    )

    foreach ($match in $relativeLinks) {
        $target = [System.Uri]::UnescapeDataString($match.Groups['Target'].Value.Trim().Trim('<', '>'))
        $fragment = [System.Uri]::UnescapeDataString($match.Groups['Fragment'].Value.Trim())

        if ($target -match '^[A-Za-z][A-Za-z0-9+.-]*:') {
            continue
        }

        if ([string]::IsNullOrWhiteSpace($target)) {
            $resolved = $file.FullName
        }
        else {
            $resolved = [System.IO.Path]::GetFullPath((Join-Path $file.DirectoryName $target))
        }

        if (-not (Test-Path -LiteralPath $resolved)) {
            $errors.Add("Broken documentation link '$target': $($file.FullName)")
            continue
        }

        $resolvedFullPath = [System.IO.Path]::GetFullPath($resolved)
        $sourceFullPath = [System.IO.Path]::GetFullPath($file.FullName)
        if ((Test-Path -LiteralPath $resolved -PathType Leaf) -and
            [System.IO.Path]::GetExtension($resolved).Equals('.md', [System.StringComparison]::OrdinalIgnoreCase) -and
            $resolvedFullPath.StartsWith($documentationRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase) -and
            -not $resolvedFullPath.Equals($sourceFullPath, [System.StringComparison]::OrdinalIgnoreCase)) {
            [void]$linkedMarkdownPaths.Add($resolvedFullPath)
        }

        if (-not [string]::IsNullOrWhiteSpace($fragment) -and
            (Test-Path -LiteralPath $resolved -PathType Leaf) -and
            [System.IO.Path]::GetExtension($resolved).Equals('.md', [System.StringComparison]::OrdinalIgnoreCase)) {
            $anchors = @(Get-MarkdownAnchors $resolved)
            if ($fragment -notin $anchors) {
                $errors.Add("Broken documentation anchor '#$fragment': $($file.FullName)")
            }
        }
    }
}

foreach ($file in $allMarkdown) {
    if (-not $linkedMarkdownPaths.Contains([System.IO.Path]::GetFullPath($file.FullName))) {
        $relativePath = [System.IO.Path]::GetRelativePath($RepositoryRoot, $file.FullName)
        $errors.Add("Documentation page has no inbound Markdown link: $relativePath")
    }
}

$documentationReadmeText = Get-Content -LiteralPath $documentationReadmePath -Raw -Encoding UTF8
$plainNavigationPaths = [regex]::Matches(
    $documentationReadmeText,
    '(?m)^\s*[-*]\s+`(?<Path>(?:Documentation|Metadata)/[^`]+\.(?:md|csv|json))`\s*$'
)
foreach ($plainNavigationPath in $plainNavigationPaths) {
    $errors.Add("Documentation README contains a non-clickable file path: $($plainNavigationPath.Groups['Path'].Value)")
}

Write-Host "Referenced procedures:      $($referenceNames.Count)"
Write-Host "Canonical source procedures: $($sourceProcedureNames.Count)"
Write-Host "Procedure pages:             $($pageNames.Count)"
Write-Host "Call-catalog procedures:     $($callCatalogNames.Count)"
Write-Host "Supporting objects:          $($supportingObjectRows.Count)"
Write-Host "Referenced source files:     $($declaredSourcePaths.Count)"
Write-Host "Deep-reviewed pages:         $deepReviewedCount"

if ($referenceNames.Count -ne $expectedProcedureNames.Count) {
    $errors.Add("Expected $($expectedProcedureNames.Count) reference procedures from the object inventory, found $($referenceNames.Count).")
}
if ($sourceProcedureNames.Count -ne $expectedProcedureNames.Count) {
    $errors.Add("Expected $($expectedProcedureNames.Count) canonical SQL procedures from the object inventory, found $($sourceProcedureNames.Count).")
}
if ($pageNames.Count -ne $expectedProcedureNames.Count) {
    $errors.Add("Expected $($expectedProcedureNames.Count) procedure pages from the object inventory, found $($pageNames.Count).")
}
if ($callCatalogNames.Count -ne $expectedProcedureNames.Count) {
    $errors.Add("Expected $($expectedProcedureNames.Count) call-catalog procedures from the object inventory, found $($callCatalogNames.Count).")
}

if ($errors.Count -gt 0) {
    foreach ($validationError in ($errors | Sort-Object -Unique)) {
        [Console]::Error.WriteLine($validationError)
    }
    exit 1
}

Write-Host 'Analysis documentation validation succeeded.'
exit 0
