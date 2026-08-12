#Requires -Version 7.2
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$failures = [System.Collections.Generic.List[string]]::new(); $passed = 0
. (Join-Path $PSScriptRoot '..' 'Common' 'CheckResult.ps1')
Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -ErrorAction Stop
$module = Get-Module SqlServerLab

$versions = & $module { @(Get-SqlServerVersions -Status SUPPORTED | Where-Object { $_.docker.image }) }
Add-CheckResult -Name 'Container-Katalog enthält die unterstützten SQL-Versionen 2019 bis 2025' -Success (
    (@($versions.id | Sort-Object) -join ',') -eq '2019,2022,2025'
)

$deprecatedVersions = & $module { @(Get-SqlServerVersions -Status DEPRECATED | Where-Object { $_.docker.image }) }
Add-CheckResult -Name 'SQL Server 2017 bleibt als veralteter Containerpfad explizit katalogisiert' -Success (
    @($deprecatedVersions.id) -contains '2017'
)

$sql2017 = & $module { Get-SqlServerDockerImage -VersionId '2017' }
Add-CheckResult -Name 'SQL Server 2017 löst auf das offizielle latest-Image auf' -Success (
    $sql2017 -eq 'mcr.microsoft.com/mssql/server:2017-latest'
)

$sql2022Builds = & $module { @(Get-SqlServerBuilds -VersionId '2022') }
Add-CheckResult -Name 'SQL Server 2022 enthält eindeutige katalogisierte CU-Tags' -Success (
    $sql2022Builds.Count -gt 0 -and
    @($sql2022Builds.cu | Sort-Object -Unique).Count -eq $sql2022Builds.Count -and
    @($sql2022Builds.tag | Sort-Object -Unique).Count -eq $sql2022Builds.Count
)
$invalid2022Resolutions = @($sql2022Builds | Where-Object {
    $versionId = "2022-$($_.cu)"
    $resolvedImage = & $module { param($id) Get-SqlServerDockerImage -VersionId $id } $versionId
    $resolvedImage -ne "mcr.microsoft.com/mssql/server:$($_.tag)"
})
Add-CheckResult -Name 'Alle katalogisierten SQL-2022-CUs lösen auf ihren unveränderlichen MCR-Tag auf' -Success (
    $invalid2022Resolutions.Count -eq 0
)

$sql2025Builds = & $module { @(Get-SqlServerBuilds -VersionId '2025') }
Add-CheckResult -Name 'SQL Server 2025 enthält CU1 bis CU7 ohne alten CTP-Eintrag' -Success (
    $sql2025Builds.Count -eq 7 -and @($sql2025Builds.cu) -notcontains 'CTP'
)

$catalog = Get-Content -LiteralPath (Join-Path $repoRoot 'Catalogs\sql-server-versions.json') -Raw | ConvertFrom-Json -Depth 30
$sql2025 = $catalog.versions | Where-Object id -eq '2025' | Select-Object -First 1
$sql2025Cus = @($sql2025.docker.builds | Where-Object { $_.cu -match '^CU\d+$' })
Add-CheckResult -Name 'Windows-CU-Metadaten sind vollständig und Downloads nur mit SHA-256 erlaubt' -Success (
    $sql2025Cus.Count -eq 7 -and
    @($sql2025Cus | Where-Object {
        -not $_.build -or -not $_.kb -or -not $_.released -or -not $_.windows.relativePath -or
        ($_.windows.downloadUrl -and -not $_.windows.sha256)
    }).Count -eq 0
)

if ($failures.Count -gt 0) {
    foreach ($failure in $failures) { Write-Host "FAIL: $failure" -ForegroundColor Red }
    exit 1
}
Write-Host "Version Catalog Checks: $passed PASS" -ForegroundColor Green
