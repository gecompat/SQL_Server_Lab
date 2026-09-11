#Requires -Version 7.2
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$modulePath=Join-Path $repoRoot 'SqlServerLab.psd1'
$failures=[Collections.Generic.List[string]]::new();$passed=0
. (Join-Path $PSScriptRoot '..\Common\CheckResult.ps1')
try {
    Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
    $module=Import-Module $modulePath -Force -PassThru
    $result=& $module {
        [PSCustomObject]@{
            Latin1=@(Find-SqlServerLabCollation -Query Latin1 -SqlVersion 2025)
            Utf8=@(Find-SqlServerLabCollation -Query 'Latin1 UTF8' -SqlVersion 2022)
            Japanese=@(Find-SqlServerLabCollation -Query 'Japanese BIN2' -SqlVersion 2019)
            Empty=@(Find-SqlServerLabCollation -SqlVersion 2025)
        }
    }
    Add-CheckResult -Name 'Collation-Katalog ist schema-valide und liefert navigierbare Latin1-Treffer' -Success (
        $result.Latin1.Count -ge 4 -and @($result.Latin1.Name | Where-Object {$_ -eq 'Latin1_General_100_CI_AS'}).Count -eq 1)
    Add-CheckResult -Name 'Token-Suche verbindet Latin1 und UTF8 ohne freie Namen zu akzeptieren' -Success (
        $result.Utf8.Count -eq 1 -and $result.Utf8[0].Name -eq 'Latin1_General_100_CI_AS_SC_UTF8' -and $result.Utf8[0].Utf8)
    Add-CheckResult -Name 'Versionfilter und technische Collation-Metadaten bleiben erhalten' -Success (
        $result.Japanese.Count -eq 1 -and $result.Japanese[0].CodePage -eq 932 -and $result.Japanese[0].Lcid -eq 1041 -and $result.Japanese[0].CaseSensitivity -eq 'BIN2' -and $result.Japanese[0].SqlVersion -eq '2019')
    Add-CheckResult -Name 'Leere Suche bleibt als katalogisierte Auswahl geheimnis- und pfadfrei' -Success (
        $result.Empty.Count -ge 6 -and (($result|ConvertTo-Json -Depth 10) -notmatch '(?i)password|secret|[A-Za-z]:\\'))

    $binding = & $module {
        $checks = [ordered]@{}
        foreach ($version in @('2019','2022','2025','2022-CU16','2022-CU16-ubuntu-22.04')) {
            $checks["Exakte Katalogbindung und kanonische Schreibweise fuer $version"] =
                (Resolve-LabSqlServerCollation -Name 'latin1_general_100_cs_as' -SqlVersion $version) -ceq 'Latin1_General_100_CS_AS'
        }
        $checks['Der katalogisierte DEPRECATED-Default bleibt zulaessig'] =
            (Resolve-LabSqlServerCollation -SqlVersion 2025) -ceq 'SQL_Latin1_General_CP1_CI_AS'
        foreach ($name in @('Latin1', 'Not_A_Collation', 'Latin1*', 'Latin1_General_100_CI_AS;DROP', ' Latin1_General_100_CI_AS', "Latin1_General_100_CI_AS`n")) {
            $rejected = $false
            try { $null = Resolve-LabSqlServerCollation -Name $name -SqlVersion 2025 }
            catch { $rejected = $_.Exception.Message -match '^SQL_COLLATION_' }
            $checks["Freie oder ungueltige Eingabe abgewiesen: $($name | ConvertTo-Json -Compress)"] = $rejected
        }
        $rejected = $false
        try { $null = Resolve-LabSqlServerCollation -SqlVersion 2017 }
        catch { $rejected = $_.Exception.Message -eq 'SQL_COLLATION_VERSION_NOT_CATALOGED' }
        $checks['Nicht katalogisierte Major-Version wird nicht geraten'] = $rejected

        $manifest = [PSCustomObject]@{ name='collation-check'; instances=@(
            [PSCustomObject]@{id='primary';version='2025';provider='docker';collation='latin1_general_100_cs_as';databases=@([PSCustomObject]@{name='SyntheticDb'})}
        ) }
        $valid = Test-SqlServerLabManifest -InputObject $manifest
        $resolved = Resolve-ManifestDefaults -Manifest $manifest
        $checks['Manifest akzeptiert den Katalogwert und vererbt den kanonischen Instanzdefault'] =
            $valid.IsValid -and $resolved.instances[0].collation -ceq 'Latin1_General_100_CS_AS' -and
            $resolved.instances[0].databases[0].collation -ceq 'Latin1_General_100_CS_AS'
        $manifest.instances[0].collation = 'Not_A_Collation'
        $invalid = Test-SqlServerLabManifest -InputObject $manifest
        $checks['Oeffentliche Manifestpruefung liefert den betroffenen Feldpfad'] =
            -not $invalid.IsValid -and [bool]($invalid.Errors -match 'instances\[primary\]\.collation: SQL_COLLATION_NOT_CATALOGED')
        $rejected = $false
        try { $null = Resolve-ManifestDefaults -Manifest $manifest }
        catch { $rejected = $_.Exception.Message -match '^SQL_COLLATION_NOT_CATALOGED' }
        $checks['Direkte Manifestnormalisierung blockiert unbekannte Instanzcollation'] = $rejected

        # Der Resolver muss vor jeder spaeteren Ad-hoc-Vorbereitung abbrechen.
        $originalProfile = ${function:script:Get-LabResourceProfile}
        try {
            function script:Get-LabResourceProfile { throw 'UNEXPECTED_ADHOC_PREPARATION' }
            $rejected = $false
            try { $null = New-SqlServerLab -Version 2025 -Provider docker -Collation 'Not_A_Collation' }
            catch { $rejected = $_.Exception.Message -match '^SQL_COLLATION_NOT_CATALOGED' }
            $checks['Oeffentlicher Ad-hoc-Pfad blockiert vor Ressourcen- und Runtimevorbereitung'] = $rejected
        }
        finally { Set-Item Function:script:Get-LabResourceProfile -Value $originalProfile }
        [PSCustomObject]$checks
    }
    foreach ($check in $binding.PSObject.Properties) { Add-CheckResult -Name $check.Name -Success $check.Value }

    $fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-collation-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $fixtureRoot
    try {
        $catalogChecks = & $module {
            param($FixtureRoot)
            $originalCatalogs = $script:CatalogsPath
            $catalog = Get-LabSqlServerCollationCatalog
            $file = Join-Path $FixtureRoot 'sql-server-collations.json'
            $checks = [ordered]@{}
            try {
                $script:CatalogsPath = $FixtureRoot
                $catalog.collations[1].supportedSqlVersions = @('2022')
                $catalog | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $file -Encoding utf8
                $checks['Suchfilter verwendet die tatsaechlichen versionsgebundenen Katalogmetadaten'] =
                    @(Find-LabSqlServerCollation -SqlVersion 2025 | Where-Object Name -eq 'Latin1_General_100_CI_AS').Count -eq 0
                $rejected = $false
                try { $null = Resolve-LabSqlServerCollation -Name 'Latin1_General_100_CI_AS' -SqlVersion 2025 }
                catch { $rejected = $_.Exception.Message -match '^SQL_COLLATION_NOT_CATALOGED' }
                $checks['Exakte Bindung lehnt einen nur fuer andere Versionen freigegebenen Namen ab'] = $rejected
                $duplicate = $catalog.collations[0] | ConvertTo-Json | ConvertFrom-Json
                $duplicate.name = $duplicate.name.ToLowerInvariant()
                $catalog.collations += $duplicate
                $catalog | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $file -Encoding utf8
                $rejected = $false
                try { $null = Resolve-LabSqlServerCollation -SqlVersion 2025 }
                catch { $rejected = $_.Exception.Message -eq 'SQL_COLLATION_CATALOG_DUPLICATE_NAME' }
                $checks['Doppelte Namen auch mit anderer Schreibweise sperren den Katalog'] = $rejected
                '{}' | Set-Content -LiteralPath $file -Encoding utf8
                $rejected = $false
                try { $null = Resolve-LabSqlServerCollation -SqlVersion 2025 }
                catch { $rejected = $_.Exception.Message -eq 'SQL_COLLATION_CATALOG_INVALID' }
                $checks['Schemafehler haben keinen Default-Fallback'] = $rejected
            }
            finally { $script:CatalogsPath = $originalCatalogs }
            [PSCustomObject]$checks
        } $fixtureRoot
        foreach ($check in $catalogChecks.PSObject.Properties) { Add-CheckResult -Name $check.Name -Success $check.Value }

        $manifestFile = Join-Path $fixtureRoot 'invalid-manifest.json'
        $invalidManifest = @{name='collation-check';instances=@(@{id='primary';version='2025';provider='docker';collation='Not_A_Collation'})}
        $rejected = $false
        try { New-SqlServerLabManifest -InputObject $invalidManifest -Path $manifestFile -Confirm:$false | Out-Null }
        catch { $rejected = $_.Exception.Message -match 'Validierungsfehler\(n\) nicht gespeichert' }
        Add-CheckResult -Name 'Wizard speichert keinen fachlich ungueltigen Collationwert' -Success ($rejected -and -not (Test-Path -LiteralPath $manifestFile))
        $invalidManifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $manifestFile -Encoding utf8
        $rejected = $false
        try { New-SqlServerLab -Manifest $manifestFile | Out-Null }
        catch { $rejected = $_.Exception.Message -match 'SQL_COLLATION_NOT_CATALOGED' }
        Add-CheckResult -Name 'Oeffentlicher Manifestpfad blockiert vor der Provisionierung' -Success $rejected
    }
    finally {
        $cleanupPath = [IO.Path]::GetFullPath($fixtureRoot)
        $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
        if (-not $cleanupPath.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or
            (Split-Path -Leaf $cleanupPath) -notmatch '^sql-lab-collation-[a-f0-9]{32}$') { throw 'COLLATION_FIXTURE_CLEANUP_SCOPE_INVALID' }
        Remove-Item -LiteralPath $cleanupPath -Recurse -Force
    }

    $consoleChecks = & $module {
        $originalMenu = ${function:script:Invoke-LabConsoleMenu}
        $originalAttention = ${function:script:Get-LabConsoleAttentionSnapshot}
        $originalReadHost = Get-Item Function:script:Read-Host -ErrorAction SilentlyContinue
        $originalConsoleMode = $script:LabConsoleMode
        $checks = [ordered]@{}
        try {
            $script:CollationTestActions = [Collections.Generic.Queue[string]]::new()
            foreach ($action in @('search','search','Latin1_General_100_CI_AS_SC_UTF8')) { $script:CollationTestActions.Enqueue($action) }
            $script:CollationTestQueries = [Collections.Generic.Queue[string]]::new()
            foreach ($query in @('NoMatchingCollation','Latin1 UTF8')) { $script:CollationTestQueries.Enqueue($query) }
            $script:CollationTestMenus = [Collections.Generic.List[object]]::new()
            function script:Read-Host { $script:CollationTestQueries.Dequeue() }
            function script:Invoke-LabConsoleMenu {
                param($Items)
                $script:CollationTestMenus.Add(@($Items))
                $id = $script:CollationTestActions.Dequeue()
                if ($id -eq 'cancel') { return [PSCustomObject]@{Status='Cancelled';SelectedItem=$null} }
                [PSCustomObject]@{Status='Selected';SelectedItem=($Items | Where-Object Id -eq $id | Select-Object -First 1)}
            }
            $selected = Select-LabSqlServerCollationInteractive -SqlVersion 2022 -Current 'SQL_Latin1_General_CP1_CI_AS'
            $checks['Konsole erlaubt erneute Suche nach null Treffern und bindet den ausgewaehlten Treffer'] =
                $selected -ceq 'Latin1_General_100_CI_AS_SC_UTF8' -and $script:CollationTestMenus[1].Count -eq 1 -and
                $script:CollationTestMenus[2].Count -eq 2
            $checks['Auswahl zeigt Codepage, LCID, Sensitivity, UTF8 und Status'] =
                $script:CollationTestMenus[2][1].Value -match 'CP 65001; LCID 1033; CI/AS; UTF8=True; SUPPORTED'
            $script:CollationTestActions.Enqueue('cancel')
            $checks['Abbruch behaelt den bisherigen Collationwert'] =
                (Select-LabSqlServerCollationInteractive -SqlVersion 2025 -Current 'Latin1_General_100_CS_AS') -ceq 'Latin1_General_100_CS_AS'
            Set-Item Function:script:Invoke-LabConsoleMenu -Value $originalMenu
            $script:LabConsoleMode = 'Fallback'
            function script:Get-LabConsoleAttentionSnapshot { return $null }
            foreach ($answer in @('s','Latin1 UTF8','1','0')) { $script:CollationTestQueries.Enqueue($answer) }
            $checks['Echter nummerierter Fallback sucht und uebernimmt nur den angezeigten Treffer'] =
                (Select-LabSqlServerCollationInteractive -SqlVersion 2022 -Current 'SQL_Latin1_General_CP1_CI_AS') -ceq 'Latin1_General_100_CI_AS_SC_UTF8'
            $checks['Null beendet den echten Fallback ohne Aenderung'] =
                (Select-LabSqlServerCollationInteractive -SqlVersion 2022 -Current 'Latin1_General_100_CS_AS') -ceq 'Latin1_General_100_CS_AS'
        }
        finally {
            Set-Item Function:script:Invoke-LabConsoleMenu -Value $originalMenu
            Set-Item Function:script:Get-LabConsoleAttentionSnapshot -Value $originalAttention
            $script:LabConsoleMode = $originalConsoleMode
            if ($originalReadHost) { Set-Item Function:script:Read-Host -Value $originalReadHost.ScriptBlock }
            else { Remove-Item Function:script:Read-Host -ErrorAction SilentlyContinue }
            Remove-Variable -Scope Script -Name CollationTestActions,CollationTestQueries,CollationTestMenus -ErrorAction SilentlyContinue
        }
        [PSCustomObject]$checks
    }
    foreach ($check in $consoleChecks.PSObject.Properties) { Add-CheckResult -Name $check.Name -Success $check.Value }
}
finally { Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue }
if($failures.Count -gt 0){Write-Error "$($failures.Count) Checks fehlgeschlagen.";exit 1}
Write-Host "$passed Checks bestanden." -ForegroundColor Green
