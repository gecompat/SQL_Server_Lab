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
        [scriptblock]$WebRequestAction
    )

    $sourceUrl = [string]$Source.url
    $response = Invoke-LabCuStatusWebRequest -Uri $sourceUrl -WebRequestAction $WebRequestAction
    $content = if ($response -is [string]) { [string]$response } else { [string]$response.Content }
    if ([string]::IsNullOrWhiteSpace($content)) {
        throw "SQL_CU_STATUS_SOURCE_EMPTY: $($Source.id)"
    }

    $gitSourceMatch = [regex]::Match(
        $content,
        '(?is)<meta\s+name=["'']github_feedback_content_git_url["'']\s+content=["''](?<url>[^"'']+)["'']'
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

function Get-LabCuStatusRows {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Sources,
        [scriptblock]$WebRequestAction
    )

    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($source in @($Sources)) {
        $sourceContent = Get-LabCuStatusContent -Source $source -WebRequestAction $WebRequestAction
        $sectionPattern = '(?ms)^###\s*SQL Server\s+(?<version>\d{4}(?:\s*R2)?)\s*\n(?<body>.*?)(?=^###\s*SQL Server\s+\d{4}(?:\s*R2)?|\z)'
        $sectionMatches = [regex]::Matches($sourceContent.Content, $sectionPattern, [System.Text.RegularExpressions.RegexOptions]::Multiline -bor [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        foreach ($section in $sectionMatches) {
            $majorMatch = [regex]::Match([string]$section.Groups['version'].Value, '\d{4}')
            if (-not $majorMatch.Success) { continue }
            foreach ($line in @([string]$section.Groups['body'].Value -split '\r?\n')) {
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
        [scriptblock]$WebRequestAction
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

    try { $microsoftRows = @(Get-LabCuStatusRows -Sources $Sources -WebRequestAction $WebRequestAction) }
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
