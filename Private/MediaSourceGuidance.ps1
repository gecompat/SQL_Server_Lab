# Alternative addresses for the same catalogued SQL 2025 bootstrapper bytes only.
function Get-LabMediaOverrideIds {
    @('sql-server-2025-enterprise-developer-bootstrapper', 'sql-server-2025-standard-developer-bootstrapper', 'sql-server-2025-express-bootstrapper')
}

function Assert-LabMediaOverrideUrl {
    param([Parameter(Mandatory)][string]$Url, [Parameter(Mandatory)][object]$Source)
    $uri = $null
    if ($Url.Length -gt 2048 -or $Url -cmatch '[^\x21-\x7e]|[%\\?#]' -or
        $Url -cnotmatch '^https://download\.microsoft\.com(?::443)?/download/' -or
        -not [uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -cne 'https' -or $uri.Host -cne 'download.microsoft.com' -or $uri.Port -ne 443 -or
        $uri.UserInfo -or $uri.Query -or $uri.Fragment) { throw 'MEDIA_SOURCE_OVERRIDE_URL_INVALID' }
    $rawPath = $Url -creplace '^https://download\.microsoft\.com(?::443)?', ''
    $parts = $rawPath.Substring(1).Split('/')
    if (@($parts | Where-Object { $_ -in @('', '.', '..') -or $_ -cnotmatch '^[A-Za-z0-9._-]+$' }).Count -or
        $parts[-1] -cne [IO.Path]::GetFileName(([uri]$Source.DownloadUrl).AbsolutePath)) { throw 'MEDIA_SOURCE_OVERRIDE_URL_INVALID' }
}

function Get-LabMediaOverrideContext {
    $snapshot = Get-LabPreferencesSnapshot
    $sources = @(Get-LabMediaSourceCatalog -RepositoryOnly | Where-Object { $_.Id -in (Get-LabMediaOverrideIds) })
    if ($sources.Count -ne 3 -or @($sources | Where-Object { $_.Version -cne '2025' -or $_.MediaKind -cne 'BOOTSTRAPPER' -or
        $_.Acquisition -cne 'DIRECT_MICROSOFT_DOWNLOAD' -or -not $_.ExpectedBytes -or -not $_.ExpectedSha256 }).Count) { throw 'MEDIA_SOURCE_OVERRIDE_CATALOG_INVALID' }
    $map = [ordered]@{}
    $valid = $true
    if ($snapshot.Document.Contains('mediaSourceOverrides')) {
        $map = $snapshot.Document['mediaSourceOverrides']
        if ($map -isnot [Collections.IDictionary]) { $valid=$false }
        else {
            foreach ($key in $map.Keys) {
                if ($key -cnotin (Get-LabMediaOverrideIds) -or $map[$key] -isnot [string]) { $valid=$false; continue }
                try { Assert-LabMediaOverrideUrl -Url $map[$key] -Source ($sources | Where-Object Id -CEQ $key) }
                catch { $valid=$false }
            }
        }
    }
    [pscustomobject]@{ Snapshot=$snapshot; Sources=$sources; Map=$map; Valid=$valid
        CatalogKey=$sources[0].RepositoryCatalogKey }
}

function Get-LabMediaOverrideState {
    try { $context = Get-LabMediaOverrideContext }
    catch {
        # Keep unrelated catalog families visible; affected entries never fall back silently.
        $context = [pscustomobject]@{ Sources=@(Get-LabMediaSourceCatalog -RepositoryOnly | Where-Object { $_.Id -in (Get-LabMediaOverrideIds) }); Map=$null; Valid=$false }
    }
    $items = foreach ($source in $context.Sources) {
        $hasOverride = $context.Map -is [Collections.IDictionary] -and $context.Map.Contains($source.Id)
        [pscustomobject]@{ Id=$source.Id; DisplayName=$source.DisplayName; Edition=$source.Edition; MediaKind=$source.MediaKind
            RepositoryUrl=$source.DownloadUrl; EffectiveUrl=$(if (-not $context.Valid) { $null } elseif ($hasOverride) { $context.Map[$source.Id] } else { $source.DownloadUrl })
            Provenance=$(if (-not $context.Valid) { 'INVALID' } elseif ($hasOverride) { 'LOCAL_OVERRIDE' } else { 'REPOSITORY_DEFAULT' })
            HasOverride=$hasOverride; ExpectedBytes=$source.ExpectedBytes; ExpectedSha256=$source.ExpectedSha256 }
    }
    [pscustomobject]@{ Status=$(if ($context.Valid) { 'READY' } else { 'INVALID' }); Items=@($items)
        Notice='Nur alternative Bezugsadresse für dieselben Bootstrapper-Bytes; keine ISO, Installation oder Verfügbarkeitsprüfung. Größe, Hash und Microsoft-Signatur bleiben bindend.' }
}

function New-LabMediaOverridePlan {
    param([Parameter(Mandatory)][string]$Id, [ValidateSet('Edit','Reset')][string]$Operation='Edit', [string]$Url)
    if ($Id -cnotin (Get-LabMediaOverrideIds)) { throw 'MEDIA_SOURCE_OVERRIDE_ID_INVALID' }
    $context = Get-LabMediaOverrideContext
    if ($context.Map -isnot [Collections.IDictionary] -or (-not $context.Valid -and $Operation -ne 'Reset')) { throw 'MEDIA_SOURCE_OVERRIDE_INVALID' }
    $source = $context.Sources | Where-Object Id -CEQ $Id
    if ($Operation -eq 'Edit') { Assert-LabMediaOverrideUrl -Url $Url -Source $source }
    elseif ($Url) { throw 'MEDIA_SOURCE_OVERRIDE_RESET_URL_INVALID' }
    $hasOverride = $context.Map.Contains($Id)
    $effective = if ($Operation -eq 'Reset') { $source.DownloadUrl } else { $Url }
    $key = Get-LabPreferencesDigest -Text ($context.Snapshot.Key + ':' + $context.CatalogKey + ':' + $Id + ':' + $Operation + ':' + $effective)
    [pscustomobject]@{ ContractVersion='SqlServerLab.MediaSourceOverridePlan/1.0'; Id=$Id; Operation=$Operation; Url=$Url
        PreviousKey=$context.Snapshot.Key; CatalogKey=$context.CatalogKey; PlanKey=$key
        RepositoryUrl=$source.DownloadUrl; EffectiveUrl=$effective; ExpectedBytes=$source.ExpectedBytes; ExpectedSha256=$source.ExpectedSha256
        IsNoOp=$(if ($Operation -eq 'Reset') { -not $hasOverride } else { $hasOverride -and $context.Map[$Id] -ceq $Url })
        Notice='Nur lokale Quellenzuordnung speichern; kein Download. Alle Integritätswerte bleiben unverändert.' }
}

function Invoke-LabMediaOverridePlan {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][object]$Plan)
    if ($Plan.ContractVersion -cne 'SqlServerLab.MediaSourceOverridePlan/1.0') { throw 'MEDIA_SOURCE_OVERRIDE_PLAN_INVALID' }
    $snapshot = Get-LabPreferencesSnapshot
    $applyCmdlet = $PSCmdlet
    Invoke-WithLabPreferencesLock -Path $snapshot.Path -Body {
        if ((Get-LabPreferencesSnapshot).Path -cne $snapshot.Path) { throw 'PREFERENCES_PREVIEW_STALE' }
        $fresh = New-LabMediaOverridePlan -Id $Plan.Id -Operation $Plan.Operation -Url $Plan.Url
        if ($fresh.PlanKey -cne $Plan.PlanKey -or $fresh.PreviousKey -cne $Plan.PreviousKey -or $fresh.CatalogKey -cne $Plan.CatalogKey) { throw 'PREFERENCES_PREVIEW_STALE' }
        if (-not $fresh.IsNoOp -and $applyCmdlet.ShouldProcess('Lokale SQL-2025-Bootstrapperquelle', $fresh.Operation)) {
            $context = Get-LabMediaOverrideContext
            if ($context.Snapshot.Key -cne $fresh.PreviousKey -or $context.CatalogKey -cne $fresh.CatalogKey) { throw 'PREFERENCES_PREVIEW_STALE' }
            if ($fresh.Operation -eq 'Reset') { $context.Map.Remove($fresh.Id) } else { $context.Map[$fresh.Id]=$fresh.Url }
            Set-LabPreferencesEntry -Name mediaSourceOverrides -Value $context.Map -ExpectedKey $fresh.PreviousKey
        }
        Get-LabMediaOverrideState
    }
}

function Show-LabMediaOverrideInteractive {
    [CmdletBinding()]
    param()
    while ($true) {
        try { $view = (Invoke-SqlServerLabWorkflowAction -Action GetMediaOverrideState).Result }
        catch { Write-LabWarning 'Quellenkonfiguration konnte nicht gelesen werden; Preferences separat prüfen.'; Wait-LabConsoleAcknowledgement; return }
        $items = @($view.Items | ForEach-Object { New-LabConsoleItem -Id $_.Id -Label $_.DisplayName -Value $_.Provenance })
        $items += New-LabConsoleItem -Id back -Label 'Zurück' -Shortcut 0
        $choice = Invoke-LabConsoleMenu -ScreenId 'media-overrides' -Title 'SQL-2025-Bootstrapperquellen' -Subtitle $view.Notice -Items $items
        if ($choice.Status -eq 'Refresh') { continue }
        if ($choice.Status -ne 'Selected' -or $choice.SelectedItem.Id -eq 'back') { return }
        $source = $view.Items | Where-Object Id -CEQ $choice.SelectedItem.Id
        if (-not $source) { continue }
        Write-Host ($source | ConvertTo-Json -Depth 4)
        Wait-LabConsoleAcknowledgement
        $action = Invoke-LabConsoleMenu -ScreenId 'media-override-edit' -Title $source.DisplayName -Subtitle $source.Provenance -Items @(
            New-LabConsoleItem -Id Edit -Label 'Alternative Adresse eingeben' -Shortcut 1 -Disabled:($view.Status -ne 'READY') -DisabledReason 'Ungültige Quellenkonfiguration zuerst gezielt zurücksetzen oder separat prüfen.'
            New-LabConsoleItem -Id Reset -Label 'Auf Repositorydefault zurücksetzen' -Shortcut 2
            New-LabConsoleItem -Id back -Label 'Abbrechen' -Shortcut 0
        )
        if ($action.Status -ne 'Selected' -or $action.SelectedItem.Id -eq 'back') { continue }
        $url = ''
        if ($action.SelectedItem.Id -eq 'Edit') {
            $inputResult = Read-LabConsoleTextInput -Prompt 'Alternative HTTPS-Adresse derselben Bootstrapper-Datei'
            if ($inputResult.Status -ne 'Confirmed') { continue }
            $url = [string]$inputResult.Value
        }
        try {
            $plan = (Invoke-SqlServerLabWorkflowAction -Action PlanMediaOverride -MediaSourceId $source.Id -MediaSourceOperation $action.SelectedItem.Id -MediaSourceUrl $url).Result
            Write-Host "Aktion: $($plan.Operation) · Keine Änderung: $($plan.IsNoOp)"
            Write-Host "Repository: $($plan.RepositoryUrl)"
            Write-Host "Zieladresse: $($plan.EffectiveUrl)"
            Write-Host "Unverändert: $($plan.ExpectedBytes) Bytes · SHA-256: $($plan.ExpectedSha256)"
            Write-Host $plan.Notice
            if (-not $plan.IsNoOp -and (Read-LabConfirm -Prompt 'Angezeigte Quellenzuordnung revalidieren und speichern (kein Download)?' -Default $false)) {
                $null = Invoke-SqlServerLabWorkflowAction -Action ApplyMediaOverride -MediaSourcePlan $plan -ConfirmMediaSource
                Write-LabInfo 'Quellenzuordnung gespeichert; kein Medium heruntergeladen.'
            }
        }
        catch { Write-LabWarning 'Quellenänderung abgelehnt; Eingabe, Katalog und Preferences erneut prüfen.' }
        Wait-LabConsoleAcknowledgement
    }
}
