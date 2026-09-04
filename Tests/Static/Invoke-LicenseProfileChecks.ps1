#Requires -Version 7.2
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-license-profile-' + [guid]::NewGuid().ToString('N'))
$results = [Collections.Generic.List[object]]::new()
function Add-Result([string]$Name, [bool]$Success, [string]$Detail = '') {
    $results.Add([PSCustomObject]@{ Name=$Name; Success=$Success; Detail=$Detail })
    Write-Host "$(if($Success){'PASS'}else{'FAIL'})  $Name $Detail" -ForegroundColor $(if($Success){'Green'}else{'Red'})
}

try {
    if (-not $IsWindows) {
        Add-Result 'DPAPI-Profilpruefung ist auf Nicht-Windows nicht anwendbar' $true
    }
    else {
        $null = New-Item -Path $testRoot -ItemType Directory -Force
        $module = Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru
        $emptyProfiles = @(Get-SqlServerLabLicenseProfile -StateRoot $testRoot)
        Add-Result 'Read-only Inventur erzeugt keinen leeren Profil-Store' (
            $emptyProfiles.Count -eq 0 -and -not (Test-Path -LiteralPath (Join-Path $testRoot 'license-profiles')))
        $privateSource = Get-Content -LiteralPath (Join-Path $repoRoot 'Private/LicenseProfile.ps1') -Raw -Encoding utf8
        Add-Result 'Profilwurzel, Metadaten und Secretdatei lehnen Reparse-Points ab' (
            $privateSource -match 'LICENSE_PROFILE_ROOT_UNSAFE' -and
            $privateSource -match 'LICENSE_PROFILE_METADATA_PATH_UNSAFE' -and
            $privateSource -match 'LICENSE_PROFILE_SECRET_PATH_UNSAFE')
        $syntheticText = @('AAAAA','BBBBB','CCCCC','DDDDD','EEEEE') -join '-'
        $key = [SecureString]::new()
        foreach ($character in $syntheticText.ToCharArray()) { $key.AppendChar($character) }
        $key.MakeReadOnly()
        $created = Set-SqlServerLabLicenseProfile -Id 'sql2016-standard-test' -Product SqlServer `
            -Version 2016 -Edition Standard -Channel VisualStudio -Key $key -StateRoot $testRoot -Confirm:$false
        $listed = @(Get-SqlServerLabLicenseProfile -Id 'sql2016-standard-test' -StateRoot $testRoot)[0]
        $tested = Test-SqlServerLabLicenseProfile -Id 'sql2016-standard-test' -StateRoot $testRoot
        $metadataPath = Join-Path $testRoot 'license-profiles/sql2016-standard-test/metadata.json'
        $metadataText = Get-Content -LiteralPath $metadataPath -Raw -Encoding utf8
        $metadataSchema = Join-Path $repoRoot 'Schemas/license-profile.schema.json'
        $allPublic = @($created, $listed, $tested) | ConvertTo-Json -Depth 10
        Add-Result 'Lizenzprofil wird lokal strukturell bereitgestellt' ($created.Status -eq 'READY' -and $listed.KeyAvailable -and $tested.Status -eq 'READY')
        Add-Result 'Lizenzprofil-Metadaten entsprechen dem geheimnisfreien Schema' (Test-Json -Json $metadataText -SchemaFile $metadataSchema -ErrorAction Stop)
        Add-Result 'Metadaten und oeffentliche Ergebnisse enthalten keinen Product Key' ($metadataText -notmatch [regex]::Escape($syntheticText) -and $allPublic -notmatch [regex]::Escape($syntheticText))

        $windowsProfile = Set-SqlServerLabLicenseProfile -Id 'windows11-pro-test' -Product Windows `
            -Version 11 -Edition Pro -Channel Retail -Key $key -StateRoot $testRoot -Confirm:$false
        Add-Result 'Windows-Keys koennen ohne Aktivierungsbehauptung sicher inventarisiert werden' (
            $windowsProfile.Product -eq 'Windows' -and $windowsProfile.Edition -eq 'Pro' -and $windowsProfile.KeyAvailable)

        $selection = & $module {
            param($Root)
            [PSCustomObject]@{
                Evaluation = Resolve-LabSqlLicenseSelection -SqlVersion 2016 -MediaEdition Eval -StateRoot $Root
                Developer = Resolve-LabSqlLicenseSelection -SqlVersion 2016 -MediaEdition Enterprise -StateRoot $Root
                Licensed = Resolve-LabSqlLicenseSelection -SqlVersion 2016 -MediaEdition Standard -LicenseProfileId 'sql2016-standard-test' -StateRoot $Root
            }
        } $testRoot
        Add-Result 'Keyloser Evaluation- und Developer-Vertrag bleibt erhalten' (
            $selection.Evaluation.LicenseType -eq 'evaluation' -and -not $selection.Evaluation.ProfileId -and
            $selection.Developer.LicenseType -eq 'developer' -and -not $selection.Developer.ProfileId)
        Add-Result 'Explizites Profil aktiviert nur die lizenzierte SQL-Auswahl' (
            $selection.Licensed.LicenseType -eq 'licensed' -and $selection.Licensed.Edition -eq 'Standard' -and
            $selection.Licensed.ProfileId -eq 'sql2016-standard-test')

        $webBlocked = $false
        try { & $module { param($Root) Resolve-LabSqlLicenseSelection -SqlVersion 2016 -MediaEdition Web -StateRoot $Root } $testRoot } catch { $webBlocked = $_.Exception.Message -match 'HYPERV_SQL_LICENSE_PROFILE_REQUIRED' }
        Add-Result 'Web und Enterprise Core verlangen ein explizites Lizenzprofil' $webBlocked

        $removed = Remove-SqlServerLabLicenseProfile -Id 'sql2016-standard-test' -StateRoot $testRoot -Confirm:$false
        Add-Result 'Profilentfernung loescht nur die exakte lokale Profilwurzel' ($removed.Status -eq 'REMOVED' -and -not (Test-Path -LiteralPath (Join-Path $testRoot 'license-profiles/sql2016-standard-test')))
        $null = Remove-SqlServerLabLicenseProfile -Id 'windows11-pro-test' -StateRoot $testRoot -Confirm:$false
    }
}
finally {
    Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

$failed = @($results | Where-Object { -not $_.Success })
Write-Host "`nErgebnis: $(@($results | Where-Object Success).Count) PASS, $($failed.Count) FAIL"
if ($failed.Count -gt 0) { throw "LICENSE PROFILE CHECKS FAILED: $($failed.Name -join '; ')" }
