function Get-LabCuStatusSourceConfiguration {
    [CmdletBinding()]
    param(
        [string]$Path = (Join-Path $script:CatalogsPath 'sql-server-cu-status-sources.json')
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "SQL_CU_STATUS_SOURCE_CATALOG_MISSING: $Path"
    }

    try {
        $configuration = Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json -Depth 8
    }
    catch {
        throw "SQL_CU_STATUS_SOURCE_CATALOG_INVALID: $($_.Exception.Message)"
    }

    if ([string]$configuration.contract -ne 'SqlServerLab.CuStatusSources/1.0' -or @($configuration.sources).Count -eq 0) {
        throw 'SQL_CU_STATUS_SOURCE_CATALOG_CONTRACT_INVALID'
    }

    foreach ($source in @($configuration.sources)) {
        $uri = try { [uri][string]$source.url } catch { $null }
        if (-not $uri -or $uri.Scheme -ne 'https' -or [string]::IsNullOrWhiteSpace([string]$source.id) -or
            @($source.allowedHosts).Count -eq 0 -or @($source.allowedHosts | Where-Object { [string]$_ -eq $uri.Host }).Count -ne 1) {
            throw "SQL_CU_STATUS_SOURCE_CATALOG_ENTRY_INVALID: $($source.id)"
        }
    }

    return @($configuration.sources)
}

function Invoke-LabCuStatusWebRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [scriptblock]$WebRequestAction
    )

    if ($WebRequestAction) {
        return & $WebRequestAction $Uri
    }

    return Invoke-WebRequest -Uri $Uri -UseBasicParsing -TimeoutSec 90 -Headers @{
        'User-Agent' = 'sql-server-lab-cuwatcher/2.0 (+https://github.com/gecompat/SQL_Server_Lab)'
    }
}

function Get-LabCuStatusContent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Source,
        [scriptblock]$WebRequestAction,
        [scriptblock]$ParserBudget
    )

    $sourceUrl = [string]$Source.url
    $response = Invoke-LabCuStatusWebRequest -Uri $sourceUrl -WebRequestAction $WebRequestAction
    $content = if ($response -is [string]) { [string]$response } else { [string]$response.Content }
    if ([string]::IsNullOrWhiteSpace($content)) {
        throw "SQL_CU_STATUS_SOURCE_EMPTY: $($Source.id)"
    }
    # The active Support article is read directly; legacy Git metadata is not authority here.
    if ($sourceUrl -ceq 'https://support.microsoft.com/en-us/servicing/sql/kb321185-download-and-install-latest-updates') {
        return [PSCustomObject]@{ Content=$content; EffectiveUrl=$sourceUrl }
    }

    $parseTimeout = if ($ParserBudget) { & $ParserBudget } else { [Text.RegularExpressions.Regex]::InfiniteMatchTimeout }
    $gitSourceMatch = [regex]::Match(
        $content,
        '(?is)<meta\s+name=["'']github_feedback_content_git_url["'']\s+content=["''](?<url>[^"'']+)["'']',
        [Text.RegularExpressions.RegexOptions]::None, $parseTimeout
    )
    if (-not $gitSourceMatch.Success) {
        return [PSCustomObject]@{ Content=$content; EffectiveUrl=$sourceUrl }
    }

    $gitSourceUrl = [string]$gitSourceMatch.Groups['url'].Value
    $rawSourceUrl = $gitSourceUrl -replace '^https://github\.com/([^/]+)/([^/]+)/blob/([^/]+)/(.*)$', 'https://raw.githubusercontent.com/$1/$2/$3/$4'
    $rawUri = try { [uri]$rawSourceUrl } catch { $null }
    if (-not $rawUri -or $rawUri.Scheme -ne 'https' -or @($Source.allowedHosts | Where-Object { [string]$_ -eq $rawUri.Host }).Count -ne 1) {
        throw "SQL_CU_STATUS_SOURCE_REDIRECT_NOT_ALLOWED: $gitSourceUrl"
    }

    $rawResponse = Invoke-LabCuStatusWebRequest -Uri $rawSourceUrl -WebRequestAction $WebRequestAction
    $rawContent = if ($rawResponse -is [string]) { [string]$rawResponse } else { [string]$rawResponse.Content }
    if ([string]::IsNullOrWhiteSpace($rawContent)) {
        throw "SQL_CU_STATUS_SOURCE_EMPTY: $($Source.id)"
    }
    return [PSCustomObject]@{ Content=$rawContent; EffectiveUrl=$rawSourceUrl }
}

function ConvertFrom-LabCuStatusSupportHtml {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Content,[scriptblock]$ParserBudget)
    # Normalize only the manufacturer's five-column CU tables, not arbitrary HTML.
    if ($Content.Length -gt 524288) { throw 'SQL_CU_STATUS_SOURCE_FORMAT_INVALID' }
    $timeout=if($ParserBudget){& $ParserBudget}else{[TimeSpan]::FromSeconds(1)}
    $sections=[regex]::Matches($Content,'(?is)<h3\b[^>]*>\s*SQL Server\s+(?<version>\d{4}(?:\s+R2)?)\s*</h3>(?<body>.*?)(?=<h[1-3]\b|\z)',[Text.RegularExpressions.RegexOptions]::None,$timeout)
    if(-not $sections.Count){throw 'SQL_CU_STATUS_SOURCE_FORMAT_INVALID'}
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $lines=[Collections.Generic.List[string]]::new()
    foreach($section in $sections){
        $version=$section.Groups['version'].Value
        if(-not $seen.Add($version)){throw 'SQL_CU_STATUS_SOURCE_FORMAT_INVALID'}
        # The SQL 2000 summary has no CU rows and remains outside the existing contract.
        if($version -ceq '2000'){continue}
        if($ParserBudget){$timeout=& $ParserBudget}
        $tables=[regex]::Matches($section.Groups['body'].Value,'(?is)<table\b[^>]*>.*?</table>',[Text.RegularExpressions.RegexOptions]::None,$timeout)
        if($tables.Count -ne 1){throw 'SQL_CU_STATUS_SOURCE_FORMAT_INVALID'}
        $table=$tables[0].Value
        $headers=[regex]::Matches($table,'(?is)<th\b[^>]*>(?<cell>.*?)</th>',[Text.RegularExpressions.RegexOptions]::None,$timeout)
        $names=@(foreach($header in $headers){[Net.WebUtility]::HtmlDecode([regex]::Replace($header.Groups['cell'].Value,'<[^>]*>','',[Text.RegularExpressions.RegexOptions]::None,$timeout)).Trim()})
        if(($names -join '|') -cne 'Build number or version|Service pack|Update|Knowledge Base number|Release date'){throw 'SQL_CU_STATUS_SOURCE_FORMAT_INVALID'}
        $lines.Add('### SQL Server '+$version)
        $rows=[regex]::Matches($table,'(?is)<tr\b[^>]*>(?<body>.*?)</tr>',[Text.RegularExpressions.RegexOptions]::None,$timeout)
        foreach($row in $rows){
            if($ParserBudget){$timeout=& $ParserBudget}
            $cells=[regex]::Matches($row.Groups['body'].Value,'(?is)<td\b[^>]*>(?<cell>.*?)</td>',[Text.RegularExpressions.RegexOptions]::None,$timeout)
            if(-not $cells.Count -and $row.Groups['body'].Value -match '(?i)<th\b'){continue}
            if($cells.Count -ne 5){throw 'SQL_CU_STATUS_SOURCE_FORMAT_INVALID'}
            $values=@(foreach($cell in $cells){[Net.WebUtility]::HtmlDecode([regex]::Replace($cell.Groups['cell'].Value,'<[^>]*>','',[Text.RegularExpressions.RegexOptions]::None,$timeout)).Trim()})
            if($values[2] -notmatch '^CU\d+$'){continue}
            # SQL 2005 lists three-part builds that the existing CU row contract ignores.
            if($version -ceq '2005' -and $values[0] -match '^\d+\.\d+\.\d+$'){continue}
            if($values[0] -notmatch '^\d+\.\d+\.\d+\.\d+$' -or $values[3] -notmatch '^KB\d+$' -or
                @($values|Where-Object{$_ -match '[|\r\n]'}).Count -or $values[4] -notmatch '^[A-Za-z]+ \d{1,2}, \d{4}$'){throw 'SQL_CU_STATUS_SOURCE_FORMAT_INVALID'}
            $lines.Add('| '+($values -join ' | ')+' |')
        }
    }
    $lines -join "`n"
}

function Get-LabCuStatusRows {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Sources,
        [scriptblock]$WebRequestAction,
        [scriptblock]$ParserBudget
    )

    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($source in @($Sources)) {
        $sourceContent = Get-LabCuStatusContent -Source $source -WebRequestAction $WebRequestAction -ParserBudget $ParserBudget
        if ([string]$Source.url -ceq 'https://support.microsoft.com/en-us/servicing/sql/kb321185-download-and-install-latest-updates' -and
            $sourceContent.Content -match '(?i)<h3\b') {
            $sourceContent.Content = ConvertFrom-LabCuStatusSupportHtml -Content $sourceContent.Content -ParserBudget $ParserBudget
        }
        $sectionPattern = '(?ms)^###\s*SQL Server\s+(?<version>\d{4}(?:\s*R2)?)\s*\n(?<body>.*?)(?=^###\s*SQL Server\s+\d{4}(?:\s*R2)?|\z)'
        $parseTimeout = if ($ParserBudget) { & $ParserBudget } else { [Text.RegularExpressions.Regex]::InfiniteMatchTimeout }
        $sectionMatches = [regex]::Matches($sourceContent.Content, $sectionPattern, ([System.Text.RegularExpressions.RegexOptions]::Multiline -bor [System.Text.RegularExpressions.RegexOptions]::IgnoreCase), $parseTimeout)
        foreach ($section in $sectionMatches) {
            if ($ParserBudget) { $null = & $ParserBudget }
            $majorMatch = [regex]::Match([string]$section.Groups['version'].Value, '\d{4}')
            if (-not $majorMatch.Success) { continue }
            foreach ($line in @([string]$section.Groups['body'].Value -split '\r?\n')) {
                if ($ParserBudget) { $null = & $ParserBudget }
                $cells = @($line.Trim().Trim('|').Split('|') | ForEach-Object { $_.Trim() })
                if ($cells.Count -lt 5 -or $cells[0] -notmatch '^\d+\.\d+\.\d+\.\d+$' -or $cells[2] -notmatch '(?i)^CU\d+$') { continue }
                $kbMatch = [regex]::Match([string]$cells[3], '(?i)KB\d+')
                if (-not $kbMatch.Success) { continue }
                $update = [string]$cells[2]
                $kb = $kbMatch.Value.ToUpperInvariant()
                $excluded = @($source.excludedUpdates | Where-Object {
                    [string]$_.version -eq $majorMatch.Value -and
                    [string]::Equals([string]$_.update, $update, [StringComparison]::OrdinalIgnoreCase) -and
                    [string]::Equals([string]$_.kb, $kb, [StringComparison]::OrdinalIgnoreCase)
                })
                if ($excluded.Count -gt 0) { continue }
                $rows.Add([PSCustomObject]@{
                    Version = $majorMatch.Value
                    Build = [string]$cells[0]
                    Update = $update
                    Kb = $kb
                    Released = [string]$cells[4]
                    SourceId = [string]$source.id
                    SourceUrl = [string]$sourceContent.EffectiveUrl
                })
            }
        }
    }
    return @($rows | Sort-Object Version, @{ Expression = { [version]$_.Build }; Descending = $true }, Kb -Unique)
}

function Invoke-LabCuStatusCheck {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CatalogPath,
        [Parameter(Mandatory)][object[]]$Sources,
        [string[]]$Version = @(),
        [ValidateRange(1, 100)][int]$MaxMissingEntries = 5,
        [scriptblock]$WebRequestAction,
        [scriptblock]$ParserBudget
    )

    if (-not (Test-Path -LiteralPath $CatalogPath -PathType Leaf)) {
        throw "SQL_CU_STATUS_VERSION_CATALOG_MISSING: $CatalogPath"
    }
    try { $catalog = Get-Content -LiteralPath $CatalogPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 20 }
    catch { throw "SQL_CU_STATUS_VERSION_CATALOG_INVALID: $($_.Exception.Message)" }

    $catalogByVersion = @{}
    foreach ($entry in @($catalog.versions)) { $catalogByVersion[[string]$entry.id] = $entry }
    $targetVersions = if ($Version.Count -gt 0) { @($Version | ForEach-Object { [string]$_.Trim() }) } else {
        @($catalog.versions | Where-Object { [string]$_.status -eq 'SUPPORTED' } | ForEach-Object { [string]$_.id } | Sort-Object)
    }

    try { $microsoftRows = @(Get-LabCuStatusRows -Sources $Sources -WebRequestAction $WebRequestAction -ParserBudget $ParserBudget) }
    catch {
        return [PSCustomObject]@{
            Contract = 'SqlServerLab.CuStatus/1.0'; Status = 'UNCLEAR'; CheckedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
            Sources = @($Sources | ForEach-Object { [PSCustomObject]@{ Id=[string]$_.id; Url=[string]$_.url } })
            CatalogPath = $CatalogPath; Versions = @(); Guidance = 'Microsoft-Quelle konnte nicht sicher ausgewertet werden. Katalog und lokale Medien bleiben unverändert.'; Reason = $_.Exception.Message
        }
    }
    if ($microsoftRows.Count -eq 0) {
        return [PSCustomObject]@{
            Contract = 'SqlServerLab.CuStatus/1.0'; Status = 'UNCLEAR'; CheckedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
            Sources = @($Sources | ForEach-Object { [PSCustomObject]@{ Id=[string]$_.id; Url=[string]$_.url } })
            CatalogPath = $CatalogPath; Versions = @(); Guidance = 'Microsoft-Quelle lieferte keine auswertbaren CU-Zeilen. Katalog und lokale Medien bleiben unverändert.'; Reason = 'SQL_CU_STATUS_NO_ROWS'
        }
    }

    $overallStatus = 'NO CHANGE'
    $results = [System.Collections.Generic.List[object]]::new()
    foreach ($versionId in $targetVersions) {
        if ($ParserBudget) { $null = & $ParserBudget }
        if (-not $catalogByVersion.ContainsKey($versionId)) {
            $overallStatus = 'UNCLEAR'
            $results.Add([PSCustomObject]@{ Version=$versionId; Status='UNCLEAR'; LatestCatalog=$null; LatestMicrosoft=$null; MissingCount=0; Missing=@(); Note='Version ist im Katalog nicht vorhanden.' })
            continue
        }
        $catalogBuilds = @($catalogByVersion[$versionId].docker.builds)
        $knownKbs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($build in $catalogBuilds) { if ($build.kb) { [void]$knownKbs.Add([string]$build.kb) } }
        $latestCatalog = @($catalogBuilds | Where-Object build | Sort-Object @{ Expression = { [version]$_.build }; Descending = $true } | Select-Object -First 1)[0]
        $rowsForVersion = @($microsoftRows | Where-Object Version -eq $versionId | Sort-Object @{ Expression = { [version]$_.Build }; Descending = $true })
        if ($rowsForVersion.Count -eq 0) {
            $overallStatus = 'UNCLEAR'
            $results.Add([PSCustomObject]@{ Version=$versionId; Status='UNCLEAR'; LatestCatalog=$latestCatalog; LatestMicrosoft=$null; MissingCount=0; Missing=@(); Note='Keine CU-Zeilen in Microsoft-Quelle für diese Version gefunden.' })
            continue
        }
        $missing = @($rowsForVersion | Where-Object { -not $knownKbs.Contains([string]$_.Kb) } | Select-Object -First $MaxMissingEntries)
        $entryStatus = if ($missing.Count -gt 0) { 'NEW' } else { 'NO CHANGE' }
        if ($entryStatus -eq 'NEW' -and $overallStatus -eq 'NO CHANGE') { $overallStatus = 'NEW' }
        $results.Add([PSCustomObject]@{
            Version=$versionId; Status=$entryStatus; LatestCatalog=$latestCatalog; LatestMicrosoft=$rowsForVersion[0]; MissingCount=$missing.Count; Missing=$missing
            Note=if ($missing.Count -gt 0) { 'Neue CU-Metadaten erkannt. Sie sind noch nicht für den Download freigegeben.' } else { 'Katalog ist auf dem Stand der Microsoft-Quelle.' }
        })
    }

    return [PSCustomObject]@{
        Contract = 'SqlServerLab.CuStatus/1.0'; Status=$overallStatus; CheckedAtUtc=(Get-Date).ToUniversalTime().ToString('o')
        Sources=@($Sources | ForEach-Object { [PSCustomObject]@{ Id=[string]$_.id; Url=[string]$_.url } }); CatalogPath=$CatalogPath; Versions=@($results)
        Guidance=if ($overallStatus -eq 'NEW') { 'Neue CUs zuerst mit MCR-Tag, Microsoft-Downloadquelle, SHA-256 und Signaturprüfung in den Versionskatalog übernehmen. Bis dahin bleibt kein neuer Download freigegeben.' } elseif ($overallStatus -eq 'UNCLEAR') { 'Quelle unklar; Katalog und lokale Medien bleiben unverändert.' } else { 'Der katalogisierte Stand kann sicher über die CU-Ressourcenfunktion in Lab_Base oder den Containercache geladen werden.' }
        Reason=$null
    }
}
