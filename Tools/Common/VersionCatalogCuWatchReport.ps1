# Pure projection of public CU metadata; never publish CatalogPath or raw Reason/Note.
function Invoke-LabCuWatchEvaluation {
    [CmdletBinding()]
    param([Parameter(Mandatory)][scriptblock]$Check)
    $ErrorActionPreference='Stop'
    $stage='CHECK'
    try {
        $outputs=@(& $Check 2>&1 3>$null 4>$null 5>$null 6>$null)
        if(@($outputs | Where-Object { $_ -is [Management.Automation.ErrorRecord] }).Count -gt 0){
            throw 'CU_WATCH_CHECK_ERROR_STREAM'
        }
        if($outputs.Count -ne 1){throw 'CU_WATCH_CHECK_RESULT_COUNT'}
        $result=$outputs[0]
        $stage='REPORT'
        $report=ConvertTo-LabCuWatchReport -Result $result
        return [pscustomobject]@{
            Status=[string]$result.Status
            CheckFailed=($result.Status -eq 'UNCLEAR')
            ReasonCode=$(if($result.Status -eq 'UNCLEAR'){'CU_WATCH_INCONCLUSIVE'}else{'CU_WATCH_COMPLETED'})
            NewCount=@($result.Versions | Where-Object Status -eq 'NEW').Count
            UnclearCount=@($result.Versions | Where-Object Status -eq 'UNCLEAR').Count
            Report=$report
        }
    } catch {
        $code=if($stage -eq 'CHECK'){'CU_WATCH_CHECK_FAILED'}else{'CU_WATCH_REPORT_FAILED'}
        return [pscustomobject]@{
            Status='UNCLEAR';CheckFailed=$true;ReasonCode=$code;NewCount=0;UnclearCount=0
            Report="# SQL Server CU Watch – Prüfung fehlgeschlagen`n`n- Status: **UNCLEAR**`n- Fehlercode: $code`n- Keine Aktualitätsbestätigung.`n- Handlung: Prüflauf, Quelle und Katalog kontrollieren; danach erneut prüfen. Vorhandene Kataloge und Medien bleiben unverändert."
        }
    }
}

function ConvertTo-LabCuWatchReport {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Result)
    if($Result.Contract -ne 'SqlServerLab.CuStatus/1.0' -or $Result.Status -notin @('NEW','NO CHANGE','UNCLEAR')){
        throw 'CU_WATCH_REPORT_CONTRACT_INVALID'
    }
    if(@($Result.Sources).Count -eq 0 -or ($Result.Status -ne 'UNCLEAR' -and @($Result.Versions).Count -eq 0)){
        throw 'CU_WATCH_REPORT_INCOMPLETE'
    }
    $lines=[Collections.Generic.List[string]]::new()
    $lines.Add('# SQL Server CU Watch – Ergebnis')
    $lines.Add('')
    $lines.Add("- Status: **$($Result.Status)**")
    $checked=[datetimeoffset]::MinValue
    if($Result.CheckedAtUtc -is [datetime] -or $Result.CheckedAtUtc -is [datetimeoffset]){
        $checked=[datetimeoffset]$Result.CheckedAtUtc
    }elseif(-not [datetimeoffset]::TryParse([string]$Result.CheckedAtUtc,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$checked)){
        throw 'CU_WATCH_REPORT_TIME_INVALID'
    }
    $lines.Add('- Geprüft am: '+$checked.ToUniversalTime().ToString('o'))
    foreach($source in @($Result.Sources)){
        $uri=$null
        if(-not [uri]::TryCreate([string]$source.Url,[UriKind]::Absolute,[ref]$uri) -or
            $uri.Scheme -ne 'https' -or ($uri.Host -ne 'learn.microsoft.com' -and
                $uri.AbsoluteUri -cne 'https://support.microsoft.com/en-us/servicing/sql/kb321185-download-and-install-latest-updates') -or
            $uri.UserInfo -or $uri.Query -or $uri.Fragment -or -not $uri.IsDefaultPort -or
            $uri.AbsolutePath -notmatch '^/[a-zA-Z0-9/_-]+$'){
            throw 'CU_WATCH_REPORT_SOURCE_INVALID'
        }
        $lines.Add('- Quelle: '+$uri.AbsoluteUri)
    }
    $lines.Add('')
    $lines.Add('## Diff je Version')
    foreach($entry in @($Result.Versions)){
        if([string]$entry.Version -notmatch '^\d{4}( R2)?$' -or $entry.Status -notin @('NEW','NO CHANGE','UNCLEAR')){
            throw 'CU_WATCH_REPORT_VERSION_INVALID'
        }
        $lines.Add('')
        $lines.Add("### SQL $($entry.Version) – $($entry.Status)")
        $catalogKb=if($entry.LatestCatalog){[string]$entry.LatestCatalog.kb}else{''}
        if($catalogKb -and $catalogKb -notmatch '^KB\d+$'){throw 'CU_WATCH_REPORT_KB_INVALID'}
        $lines.Add('- Katalog-Latest-KB: '+$(if($catalogKb){$catalogKb}else{'unbekannt'}))
        foreach($build in @($entry.LatestMicrosoft)+@($entry.Missing)){
            if($null -eq $build){continue}
            if([string]$build.Build -notmatch '^\d+\.\d+\.\d+\.\d+$' -or [string]$build.Kb -notmatch '^KB\d+$'){
                throw 'CU_WATCH_REPORT_BUILD_INVALID'
            }
        }
        if($entry.LatestMicrosoft){$lines.Add("- Letzter Microsoft-Stand: $($entry.LatestMicrosoft.Build) / $($entry.LatestMicrosoft.Kb)")}
        $lines.Add('- Fehlende Einträge: '+@($entry.Missing).Count)
        foreach($missing in @($entry.Missing)){$lines.Add("  - $($missing.Build) / $($missing.Kb)")}
        if($entry.Status -eq 'UNCLEAR'){$lines.Add('- Hinweis: Versionsprüfung unklar; Quelle und Katalog manuell prüfen.')}
    }
    if(@($Result.Versions).Count -eq 0){$lines.Add('Keine Versionsdaten ausgewertet.')}
    $lines.Add('')
    $lines.Add($(switch($Result.Status){
        'UNCLEAR' {'Handlung: Prüfung unklar; Quelle und Katalog manuell prüfen. Keine Aktualitätsbestätigung.'}
        'NEW' {'Handlung: Fehlende Builds vor Katalogübernahme auf Quelle, Integrität und Kompatibilität prüfen.'}
        'NO CHANGE' {'Handlung: Keine neuen CU-Einträge im geprüften Scope.'}
    }))
    return $lines -join "`n"
}
