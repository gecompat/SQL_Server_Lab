# Session-only observations. No catalog, preference, media or monitoring-state writes.
$script:ResourceWatchCache = $null
$script:ResourceWatchLock = [object]::new()
$script:ResourceWatchBusy = $false

function Get-LabResourceWatchConfiguration {
    $paths = @('software.json', 'sql-server-versions.json', 'sql-server-cu-status-sources.json')
    $texts = @($paths | ForEach-Object { Get-Content -LiteralPath (Join-Path $script:CatalogsPath $_) -Raw -ErrorAction Stop })
    $software = $texts[0] | ConvertFrom-Json -Depth 30 -ErrorAction Stop
    $variants = @($software.software | Where-Object id -eq 'sqlpackage' | ForEach-Object variants | Where-Object id -eq 'sql2022-sqlpackage170-linux-derived')
    $url = 'https://learn.microsoft.com/en-us/sql/tools/sqlpackage/sqlpackage-download?view=sql-server-ver17'
    if ($variants.Count -ne 1 -or [string]$variants[0].runtimeVersion -notmatch '^\d+\.\d+\.\d+\.\d+$' -or $url -cnotin @($variants[0].sourceUrls)) { throw 'RESOURCE_WATCH_CATALOG_INVALID' }
    $sources = @(Get-LabCuStatusSourceConfiguration)
    if ($sources.Count -ne 1 -or $sources[0].url -cne 'https://support.microsoft.com/en-us/servicing/sql/kb321185-download-and-install-latest-updates') { throw 'RESOURCE_WATCH_SOURCE_INVALID' }
    $key = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes(('ResourceWatch/1|' + $url + '|sql2022-sqlpackage170-linux-derived|' + ($texts -join '|')))))
    $catalog=$texts[1] | ConvertFrom-Json -Depth 30 -ErrorAction Stop
    $versions=@(foreach($entry in @($catalog.versions | Where-Object status -eq 'SUPPORTED')) {
        if([string]$entry.id -notmatch '^\d{4}$' -or @($entry.docker.builds | Where-Object {[string]$_.build -notmatch '^\d+\.\d+\.\d+\.\d+$'}).Count){throw 'RESOURCE_WATCH_CATALOG_INVALID'}
        $latest=@($entry.docker.builds | Sort-Object {[version]$_.build} -Descending | Select-Object -First 1)
        if($latest.Count -ne 1){throw 'RESOURCE_WATCH_CATALOG_INVALID'}
        [pscustomobject]@{Version=[string]$entry.id;Build=[string]$latest[0].build}
    })
    if(-not $versions.Count){throw 'RESOURCE_WATCH_CATALOG_INVALID'}
    [pscustomobject]@{ Key=$key; SqlPackageVersion=[string]$variants[0].runtimeVersion; SqlPackageUrl=$url; Sources=$sources; CuVersions=$versions; CatalogPath=(Join-Path $script:CatalogsPath 'sql-server-versions.json') }
}

function Assert-LabResourceWatchUri {
    param([string]$Uri)
    # Exact sources only, including the existing CU parser's HTML-to-Markdown hop.
    if ($Uri -cnotin @(
        'https://learn.microsoft.com/en-us/sql/tools/sqlpackage/sqlpackage-download?view=sql-server-ver17',
        'https://support.microsoft.com/en-us/servicing/sql/kb321185-download-and-install-latest-updates',
        'https://learn.microsoft.com/en-us/troubleshoot/sql/releases/download-and-install-latest-updates',
        'https://raw.githubusercontent.com/MicrosoftDocs/SupportArticles-docs/main/support/sql/releases/download-and-install-latest-updates.md'
    )) { throw 'RESOURCE_WATCH_SOURCE_INVALID' }
}

function Invoke-LabResourceWatchRequest {
    param([string]$Uri, [Parameter(Mandatory)][Diagnostics.Stopwatch]$Clock, [ValidateRange(1,45000)][int]$MaximumElapsedMilliseconds=45000)
    Assert-LabResourceWatchUri $Uri
    $remaining = $MaximumElapsedMilliseconds - [int]$Clock.ElapsedMilliseconds
    if ($remaining -le 0) { throw 'RESOURCE_WATCH_TIMEOUT' }
    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect=$false; $handler.UseProxy=$false; $handler.UseCookies=$false
    $handler.UseDefaultCredentials=$false; $handler.Credentials=$null
    $handler.AutomaticDecompression=[Net.DecompressionMethods]::None
    $client=[Net.Http.HttpClient]::new($handler)
    $client.Timeout=[Threading.Timeout]::InfiniteTimeSpan
    $cancel=[Threading.CancellationTokenSource]::new($remaining)
    $response=$null; $stream=$null; $memory=[IO.MemoryStream]::new()
    try {
        $request=[Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get,$Uri)
        try { $response=$client.SendAsync($request,[Net.Http.HttpCompletionOption]::ResponseHeadersRead,$cancel.Token).GetAwaiter().GetResult() }
        finally { $request.Dispose() }
        if ([int]$response.StatusCode -eq 429) { throw 'RESOURCE_WATCH_RATE_LIMITED' }
        if ([int]$response.StatusCode -ge 300 -and [int]$response.StatusCode -lt 400) { throw 'RESOURCE_WATCH_REDIRECT_REJECTED' }
        if (-not $response.IsSuccessStatusCode) { throw 'RESOURCE_WATCH_HTTP_ERROR' }
        if ($response.Content.Headers.ContentEncoding.Count -gt 0) { throw 'RESOURCE_WATCH_ENCODING_UNSUPPORTED' }
        if ($response.Content.Headers.ContentLength -gt 524288) { throw 'RESOURCE_WATCH_RESPONSE_TOO_LARGE' }
        $stream=$response.Content.ReadAsStreamAsync($cancel.Token).GetAwaiter().GetResult()
        $buffer=[byte[]]::new(8192)
        while (($read=$stream.ReadAsync($buffer,0,$buffer.Length,$cancel.Token).GetAwaiter().GetResult()) -gt 0) {
            if ($memory.Length + $read -gt 524288) { throw 'RESOURCE_WATCH_RESPONSE_TOO_LARGE' }
            $memory.Write($buffer,0,$read)
        }
        $utf8=[Text.UTF8Encoding]::new($false,$true)
        $content=$utf8.GetString($memory.ToArray())
        if ([string]::IsNullOrWhiteSpace($content)) { throw 'RESOURCE_WATCH_PARSE_ERROR' }
        [pscustomobject]@{Content=$content}
    } catch {
        $message=[string]$_.Exception.Message
        if ($message -match '^RESOURCE_WATCH_[A-Z_]+$') { throw $message }
        if ($cancel.IsCancellationRequested -or $Clock.ElapsedMilliseconds -ge $MaximumElapsedMilliseconds) { throw 'RESOURCE_WATCH_TIMEOUT' }
        if ($_.Exception -is [Text.DecoderFallbackException]) { throw 'RESOURCE_WATCH_PARSE_ERROR' }
        throw 'RESOURCE_WATCH_SOURCE_UNAVAILABLE'
    } finally {
        if($stream){$stream.Dispose()}; if($response){$response.Dispose()}
        $memory.Dispose(); $cancel.Dispose(); $client.Dispose(); $handler.Dispose()
    }
}

function ConvertFrom-LabSqlPackageWatchContent {
    param([string]$Content, [scriptblock]$ParserBudget)
    # Only the explicitly labelled stable build field; never infer from archive URLs.
    $pattern='(?im)(?:<li>\s*(?:Build number:|<strong>\s*Build number:\s*</strong>)\s*(?<build>\d+\.\d+\.\d+\.\d+)\s*</li>|^\s*[-*]\s*(?:Build number:|\*\*Build number:\*\*)\s*(?<build>\d+\.\d+\.\d+\.\d+)\s*$)'
    $timeout=if($ParserBudget){& $ParserBudget}else{[TimeSpan]::FromSeconds(1)}
    $buildMatches=[regex]::Matches($Content,$pattern,[Text.RegularExpressions.RegexOptions]::None,$timeout)
    if ($buildMatches.Count -ne 1) { throw 'RESOURCE_WATCH_PARSE_ERROR' }
    $timeout=if($ParserBudget){& $ParserBudget}else{[TimeSpan]::FromSeconds(1)}
    $headings=[regex]::Matches($Content.Substring(0,$buildMatches[0].Index),'(?ims)<h(?<htmlLevel>[1-6])\b[^>]*>(?<htmlTitle>.*?)</h[1-6]>|^(?<markdownLevel>#{1,6})[ \t]+(?<markdownTitle>[^\r\n]+)',[Text.RegularExpressions.RegexOptions]::None,$timeout)
    $ancestors=@{}
    foreach($heading in $headings){
        if($ParserBudget){$timeout=& $ParserBudget}
        $level=if($heading.Groups['htmlLevel'].Success){[int]$heading.Groups['htmlLevel'].Value}else{$heading.Groups['markdownLevel'].Value.Length}
        foreach($oldLevel in @($ancestors.Keys)){if($oldLevel -ge $level){$ancestors.Remove($oldLevel)}}
        $title=if($heading.Groups['htmlLevel'].Success){$heading.Groups['htmlTitle'].Value}else{$heading.Groups['markdownTitle'].Value}
        $plainTitle=[Net.WebUtility]::HtmlDecode([regex]::Replace($title,'<[^>]*>','',[Text.RegularExpressions.RegexOptions]::None,$timeout))
        $ancestors[$level]=$plainTitle -match '(?i)\bpreview\b'
    }
    if(@($ancestors.Values|Where-Object {$_}).Count){throw 'RESOURCE_WATCH_PARSE_ERROR'}
    try { return ([version]$buildMatches[0].Groups['build'].Value).ToString(4) }
    catch { throw 'RESOURCE_WATCH_PARSE_ERROR' }
}

function Get-LabResourceWatchState {
    param([datetimeoffset]$Now=[datetimeoffset]::UtcNow)
    $notice='Nur Metadatenvergleich. Kein Download, keine Installation oder Supportfreigabe. Sitzungscache; nach Neustart nicht geprüft.'
    try { $configuration=Get-LabResourceWatchConfiguration }
    catch { return [pscustomobject]@{Contract='SqlServerLab.ResourceWatch/1.0';Status='UNCLEAR';ReasonCode='RESOURCE_WATCH_CATALOG_INVALID';CheckedAtUtc=$null;Items=@();Notice=$notice} }
    $cache=$script:ResourceWatchCache
    if (-not $cache -or $cache.Key -cne $configuration.Key) {
        $pending=@(foreach($version in $configuration.CuVersions){[pscustomobject]@{Id=('sql-cu-'+$version.Version);Name=('SQL Server '+$version.Version+' CUs');CatalogVersion=$version.Build;SourceUrl=[string]$configuration.Sources[0].url}})
        $pending+= [pscustomobject]@{Id='sqlpackage';Name='SqlPackage · SQL-2022-Linux-Katalog';CatalogVersion=$configuration.SqlPackageVersion;SourceUrl=$configuration.SqlPackageUrl}
        foreach($item in $pending){$item | Add-Member -NotePropertyMembers @{Status='NOT_CHECKED';ReasonCode='RESOURCE_WATCH_NOT_CHECKED';ObservedVersion=$null;LastSuccessfulVersion=$null;LastSuccessfulAtUtc=$null}}
        return [pscustomobject]@{Contract='SqlServerLab.ResourceWatch/1.0';Status='NOT_CHECKED';ReasonCode='RESOURCE_WATCH_NOT_CHECKED';CheckedAtUtc=$null;Items=$pending;Notice=$notice}
    }
    # Return detached data so callers cannot change the cache or its observation history.
    $result=$cache.Result | ConvertTo-Json -Depth 12 | ConvertFrom-Json -Depth 12
    if (($Now - $cache.CheckedAt).TotalMinutes -ge 15 -or $Now -lt $cache.CheckedAt) {
        $result.Status='EXPIRED'; $result.ReasonCode='RESOURCE_WATCH_CACHE_EXPIRED'
        foreach($item in $result.Items){$item.Status='EXPIRED'}
    }
    $result.Notice=$notice
    return $result
}

function Invoke-LabResourceWatchRefresh {
    [CmdletBinding()]
    param([scriptblock]$WebRequestAction, [datetimeoffset]$Now=[datetimeoffset]::UtcNow)
    $ownsRefresh=$false
    if (-not [Threading.Monitor]::TryEnter($script:ResourceWatchLock)) { throw 'RESOURCE_WATCH_BUSY' }
    try {
        if($script:ResourceWatchBusy){throw 'RESOURCE_WATCH_BUSY'}
        $script:ResourceWatchBusy=$true;$ownsRefresh=$true
        try { $configuration=Get-LabResourceWatchConfiguration } catch { $script:ResourceWatchCache=$null; return Get-LabResourceWatchState -Now $Now }
        $previous=if($script:ResourceWatchCache -and $script:ResourceWatchCache.Key -ceq $configuration.Key){$script:ResourceWatchCache}else{$null}
        $clock=[Diagnostics.Stopwatch]::StartNew()
        $transportState=@{Failure=$null}
        $watchValidate = (Get-Command Assert-LabResourceWatchUri).ScriptBlock
        $watchTransport = (Get-Command Invoke-LabResourceWatchRequest).ScriptBlock
        $watchInjected = $WebRequestAction
        $request={
            param($Uri)
            try {
                & $watchValidate $Uri
                if($clock.ElapsedMilliseconds -ge 45000){throw 'RESOURCE_WATCH_TIMEOUT'}
                if($watchInjected){$response=& $watchInjected $Uri}else{$response=& $watchTransport -Uri $Uri -Clock $clock}
                if($clock.ElapsedMilliseconds -ge 45000){throw 'RESOURCE_WATCH_TIMEOUT'}
                return $response
            } catch {
                $code=[string]$_.Exception.Message
                $transportState.Failure=if($code -cmatch '^RESOURCE_WATCH_(TIMEOUT|RATE_LIMITED|REDIRECT_REJECTED|HTTP_ERROR|ENCODING_UNSUPPORTED|RESPONSE_TOO_LARGE|PARSE_ERROR|SOURCE_UNAVAILABLE|SOURCE_INVALID)$'){$code}else{'RESOURCE_WATCH_SOURCE_UNAVAILABLE'}
                throw $transportState.Failure
            }
        }
        $items=[Collections.Generic.List[object]]::new()
        $parseBudget={$remaining=45000-$clock.ElapsedMilliseconds;if($remaining -le 0){$transportState.Failure='RESOURCE_WATCH_TIMEOUT';throw 'RESOURCE_WATCH_TIMEOUT'};[TimeSpan]::FromMilliseconds([Math]::Min(1000,$remaining))}.GetNewClosure()
        try { $cu=Invoke-LabCuStatusCheck -CatalogPath $configuration.CatalogPath -Sources $configuration.Sources -WebRequestAction $request -ParserBudget $parseBudget }
        catch { $cu=[pscustomobject]@{Status='UNCLEAR'} }
        if($cu.Status -eq 'UNCLEAR') {
            foreach($entry in $configuration.CuVersions){$items.Add([pscustomobject]@{Id=('sql-cu-'+$entry.Version);Name=('SQL Server '+$entry.Version+' CUs');CatalogVersion=$entry.Build;ObservedVersion=$null;SourceUrl=[string]$configuration.Sources[0].url;Status='UNCLEAR';ReasonCode=$(if($transportState.Failure){$transportState.Failure}else{'RESOURCE_WATCH_PARSE_ERROR'})})}
        } else {
            foreach($entry in $cu.Versions) {
                $known=[string]$entry.LatestCatalog.build; $observed=[string]$entry.LatestMicrosoft.Build
                $valid=$known -match '^\d+\.\d+\.\d+\.\d+$' -and $observed -match '^\d+\.\d+\.\d+\.\d+$' -and [version]$observed -ge [version]$known
                $items.Add([pscustomobject]@{Id=('sql-cu-'+$entry.Version);Name=('SQL Server '+$entry.Version+' CUs');CatalogVersion=$known;ObservedVersion=$(if($valid){$observed}else{$null});SourceUrl=[string]$configuration.Sources[0].url;Status=$(if(-not $valid){'UNCLEAR'}elseif($entry.Status -eq 'NEW'){'NEW'}else{'NO_CHANGE'});ReasonCode=$(if($valid){'RESOURCE_WATCH_COMPLETED'}else{'RESOURCE_WATCH_PARSE_ERROR'})})
            }
        }
        $status='UNCLEAR';$reason='RESOURCE_WATCH_PARSE_ERROR';$observed=$null;$transportState.Failure=$null
        try {
            $response=& $request $configuration.SqlPackageUrl
            $observed=ConvertFrom-LabSqlPackageWatchContent -Content ([string]$response.Content) -ParserBudget $parseBudget
            if([version]$observed -lt [version]$configuration.SqlPackageVersion){throw 'RESOURCE_WATCH_SOURCE_BEHIND'}
            $status=if([version]$observed -gt [version]$configuration.SqlPackageVersion){'NEW'}else{'NO_CHANGE'}
            $reason='RESOURCE_WATCH_COMPLETED'
        } catch {
            $reason=if($transportState.Failure){$transportState.Failure}elseif($_.Exception.Message -eq 'RESOURCE_WATCH_SOURCE_BEHIND'){'RESOURCE_WATCH_SOURCE_BEHIND'}else{'RESOURCE_WATCH_PARSE_ERROR'}
            $observed=$null
        }
        $items.Add([pscustomobject]@{Id='sqlpackage';Name='SqlPackage · SQL-2022-Linux-Katalog';CatalogVersion=$configuration.SqlPackageVersion;ObservedVersion=$observed;SourceUrl=$configuration.SqlPackageUrl;Status=$status;ReasonCode=$reason})
        foreach($item in $items) {
            if($clock.ElapsedMilliseconds -ge 45000){$item.Status='UNCLEAR';$item.ReasonCode='RESOURCE_WATCH_TIMEOUT';$item.ObservedVersion=$null}
            $old=@($previous.Result.Items | Where-Object Id -eq $item.Id | Select-Object -First 1)
            $last=if($old.Count){$old[0]}else{$null}
            $tuple=$configuration.Key+'|'+$item.Id+'|'+$item.CatalogVersion+'|'+$item.ObservedVersion+'|'+$item.Status+'|'+$item.ReasonCode
            $finding=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($tuple)))
            $success=$item.Status -in @('NEW','NO_CHANGE')
            $item | Add-Member -NotePropertyMembers @{
                FindingKey=$finding; RepeatedFinding=($last -and $last.FindingKey -ceq $finding)
                PreviousSuccessfulVersion=$(if($last){$last.LastSuccessfulVersion}else{$null})
                LastSuccessfulVersion=$(if($success){$item.ObservedVersion}elseif($last){$last.LastSuccessfulVersion}else{$null})
                LastSuccessfulAtUtc=$(if($success){$Now.ToUniversalTime().ToString('o')}elseif($last){$last.LastSuccessfulAtUtc}else{$null})
            }
        }
        $overall=if(@($items|Where-Object Status -eq 'UNCLEAR').Count){'UNCLEAR'}elseif(@($items|Where-Object Status -eq 'NEW').Count){'NEW'}else{'NO_CHANGE'}
        $result=[pscustomobject]@{Contract='SqlServerLab.ResourceWatch/1.0';Status=$overall;ReasonCode=$(if($overall -eq 'UNCLEAR'){'RESOURCE_WATCH_INCONCLUSIVE'}else{'RESOURCE_WATCH_COMPLETED'});CheckedAtUtc=$Now.ToUniversalTime().ToString('o');Items=@($items);Notice=''}
        $fresh=Get-LabResourceWatchConfiguration
        if($fresh.Key -cne $configuration.Key){$result.Status='UNCLEAR';$result.ReasonCode='RESOURCE_WATCH_CATALOG_CHANGED';$result.Items=@()}
        $script:ResourceWatchCache=[pscustomobject]@{Key=$fresh.Key;CheckedAt=$Now;Result=$result}
        return Get-LabResourceWatchState -Now $Now
    } finally { if($ownsRefresh){$script:ResourceWatchBusy=$false}; [Threading.Monitor]::Exit($script:ResourceWatchLock) }
}

function Show-LabResourceWatchInteractive {
    while($true) {
        $view=(Invoke-SqlServerLabWorkflowAction -Action GetResourceWatchState).Result
        $choice=Invoke-LabConsoleMenu -ScreenId 'resource-watch' -Title 'Ressourcenstand prüfen' -Subtitle ($view.Status+' · Nur explizite Prüfung greift auf Microsoft zu') -Items @(
            New-LabConsoleItem -Id Check -Label 'Jetzt bei Microsoft prüfen' -Shortcut 1
            New-LabConsoleItem -Id Details -Label 'Gespeicherten Sitzungsbefund ansehen' -Shortcut 2
            New-LabConsoleItem -Id Back -Label 'Zurück' -Shortcut 0
        )
        if($choice.Status -eq 'Refresh'){continue}
        if($choice.Status -ne 'Selected' -or $choice.SelectedItem.Id -eq 'Back'){return}
        try {
            if($choice.SelectedItem.Id -eq 'Check'){$view=(Invoke-SqlServerLabWorkflowAction -Action RefreshResourceWatch).Result}
            Write-Host ($view.Status+' · '+$view.ReasonCode+' · '+$view.CheckedAtUtc)
            foreach($item in $view.Items){Write-Host ($item.Name+' | Katalog: '+$item.CatalogVersion+' | Quelle: '+$item.ObservedVersion+' | '+$item.Status+' | '+$item.ReasonCode);Write-Host ('Letzte erfolgreiche Beobachtung: '+$item.LastSuccessfulVersion+' · '+$item.LastSuccessfulAtUtc);Write-Host $item.SourceUrl}
            Write-Host $view.Notice
        } catch { Write-LabWarning 'RESOURCE_WATCH_UNAVAILABLE: Quellenprüfung nicht bestätigt.' }
        Wait-LabConsoleAcknowledgement
    }
}
