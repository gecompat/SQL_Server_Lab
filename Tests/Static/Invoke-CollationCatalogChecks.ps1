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
}
finally { Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue }
if($failures.Count -gt 0){Write-Error "$($failures.Count) Checks fehlgeschlagen.";exit 1}
Write-Host "$passed Checks bestanden." -ForegroundColor Green
