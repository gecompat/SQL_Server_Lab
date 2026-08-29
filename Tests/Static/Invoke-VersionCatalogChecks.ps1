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

$sql2019Builds = & $module { @(Get-SqlServerBuilds -VersionId '2019') }
Add-CheckResult -Name 'Unterstützte SQL-Versionen sind auf den verifizierten CU-Ständen katalogisiert' -Success (
    $sql2019Builds[0].cu -eq 'CU32' -and $sql2019Builds[0].build -eq '15.0.4430.1' -and
    $sql2019Builds[0].kb -eq 'KB5054833' -and $sql2019Builds[0].released -eq '2025-02-27' -and
    $sql2022Builds[0].cu -eq 'CU26' -and $sql2022Builds[0].build -eq '16.0.4265.3' -and
    $sql2022Builds[0].kb -eq 'KB5093420' -and $sql2022Builds[0].released -eq '2026-07-16'
)

$sql2025Builds = & $module { @(Get-SqlServerBuilds -VersionId '2025') }
Add-CheckResult -Name 'SQL Server 2025 enthält CU1 bis CU8 ohne alten CTP-Eintrag' -Success (
    $sql2025Builds.Count -eq 8 -and @($sql2025Builds.cu) -notcontains 'CTP' -and
    $sql2025Builds[0].cu -eq 'CU8' -and $sql2025Builds[0].build -eq '17.0.4075.5' -and
    $sql2025Builds[0].kb -eq 'KB5104822' -and $sql2025Builds[0].released -eq '2026-08-13'
)

$catalog = Get-Content -LiteralPath (Join-Path $repoRoot 'Catalogs\sql-server-versions.json') -Raw | ConvertFrom-Json -Depth 30
$sql2025 = $catalog.versions | Where-Object id -eq '2025' | Select-Object -First 1
$sql2025Cus = @($sql2025.docker.builds | Where-Object { $_.cu -match '^CU\d+$' })
Add-CheckResult -Name 'Alle katalogisierten Builds unterstützter SQL-Versionen besitzen verifizierbare Kernmetadaten' -Success (
    @($catalog.versions | Where-Object status -eq 'SUPPORTED' | ForEach-Object { $_.docker.builds } | Where-Object {
        -not $_.build -or -not $_.kb -or -not $_.released
    }).Count -eq 0
)

$cuWatchText = Get-Content -LiteralPath (Join-Path $repoRoot 'Tools/Get-SqlServerCuStatus.ps1') -Raw -Encoding utf8
Add-CheckResult -Name 'CU-Watch begrenzt den Standardlauf auf unterstützte Katalogversionen' -Success (
    $cuWatchText -match 'Status\s*=\s*\[string\]\$entry\.status' -and
    $cuWatchText -match 'Where-Object\s*\{\s*\$_\.Status\s+-eq\s+''SUPPORTED''\s*\}' -and
    $cuWatchText -match 'Ohne Angabe werden ausschließlich Katalogeinträge mit Status SUPPORTED geprüft'
)
Add-CheckResult -Name 'Windows-CU-Metadaten sind vollständig und Downloads nur mit SHA-256 erlaubt' -Success (
    $sql2025Cus.Count -eq 8 -and
    @($sql2025Cus | Where-Object {
        -not $_.build -or -not $_.kb -or -not $_.released -or -not $_.windows.relativePath -or
        ($_.windows.downloadUrl -and -not $_.windows.sha256)
    }).Count -eq 0
)

$runtimeWorkflowPaths = @(
    (Join-Path $repoRoot '.github/workflows/runtime-smoke-docker.yml'),
    (Join-Path $repoRoot '.github/workflows/runtime-smoke-podman.yml')
)
$invalidRuntimeWorkflows = @($runtimeWorkflowPaths | Where-Object {
    $workflowText = Get-Content -LiteralPath $_ -Raw -Encoding utf8
    $workflowText -match '(?m)-FullMatrix|(?m)-IncludeParallel' -or
    @([regex]::Matches($workflowText, '(?m)-ReferenceVersion\s+2025')).Count -ne 1 -or
    @([regex]::Matches($workflowText, '(?m)-Version\s+2025')).Count -ne 2 -or
    @([regex]::Matches($workflowText, '(?m)-Version\s+2022-CU18')).Count -ne 1 -or
    $workflowText -match '(?m)-(?:Reference)?Version\s+(?:2017|2019)(?:\s|$)' -or
    $workflowText -match '(?m)-(?:Reference)?Version\s+2022(?!-CU18)(?:\s|$)'
})
Add-CheckResult -Name 'Docker- und Podman-Gates trennen SQL-2025-Lifecycle von SQL-2022-CU18-CLI-Acceptance' -Success (
    $invalidRuntimeWorkflows.Count -eq 0
) -Message (($invalidRuntimeWorkflows | ForEach-Object { Split-Path -Leaf $_ }) -join ', ')

$referenceFiles = @(
    (Join-Path $repoRoot 'Tests/Integration/Invoke-RestoreSmokeTest.ps1'),
    (Join-Path $repoRoot 'Tests/Integration/Invoke-AdapterSmokeTest.ps1'),
    (Join-Path $repoRoot 'Tests/Integration/Invoke-MixedProviderSmokeTest.ps1'),
    (Join-Path $repoRoot 'Schemas/example-mixed-provider-lab.json'),
    (Join-Path $repoRoot '.github/workflows/runtime-smoke-docker-github-hosted.yml'),
    (Join-Path $repoRoot '.github/workflows/adapter-smoke-github-hosted.yml'),
    (Join-Path $repoRoot '.github/workflows/runtime-smoke-hyperv-sql-fresh-acceptance.yml')
)
$nonReferenceRuntimeHits = @($referenceFiles | Where-Object {
    (Get-Content -LiteralPath $_ -Raw -Encoding utf8) -match '(?m)(?:Version\s*=\s*|Version\s+|"version"\s*:\s*|versions=\()["'']?(?:2019|2022)'
})
Add-CheckResult -Name 'Reguläre Runtime-, Mixed-, Restore-, Adapter- und Hyper-V-Gates sind auf SQL 2025 vereinheitlicht' -Success (
    $nonReferenceRuntimeHits.Count -eq 0
)

$defaultCollationFiles = @(
    (Join-Path $repoRoot 'Private/ManifestParser.ps1'),
    (Join-Path $repoRoot 'Providers/Docker/DockerProvider.ps1'),
    (Join-Path $repoRoot 'Providers/Podman/PodmanProvider.ps1'),
    (Join-Path $repoRoot 'Public/New-SqlServerLab.ps1'),
    (Join-Path $repoRoot 'Public/New-SqlServerLabDatabase.ps1'),
    (Join-Path $repoRoot 'Schemas/lab-manifest.schema.json')
)
$invalidDefaultCollationFiles = @($defaultCollationFiles | Where-Object {
    (Get-Content -LiteralPath $_ -Raw -Encoding utf8) -notmatch 'SQL_Latin1_General_CP1_CI_AS'
})
$manifestSchemaText = Get-Content -LiteralPath (Join-Path $repoRoot 'Schemas/lab-manifest.schema.json') -Raw -Encoding utf8
Add-CheckResult -Name 'Standardpfade verwenden die native SQL-Containercollation CI_AS' -Success (
    $invalidDefaultCollationFiles.Count -eq 0 -and
    $manifestSchemaText -match '"default"\s*:\s*"SQL_Latin1_General_CP1_CI_AS"'
)

$containerProviderText = @(
    Get-Content -LiteralPath (Join-Path $repoRoot 'Providers/Docker/DockerProvider.ps1') -Raw -Encoding utf8
    Get-Content -LiteralPath (Join-Path $repoRoot 'Providers/Podman/PodmanProvider.ps1') -Raw -Encoding utf8
) -join "`n"
Add-CheckResult -Name 'Provider übergeben MSSQL_COLLATION nur für eine explizite Custom-Collation' -Success (
    @([regex]::Matches($containerProviderText, "Collation\s+-ne\s+'SQL_Latin1_General_CP1_CI_AS'")).Count -eq 2 -and
    @([regex]::Matches($containerProviderText, 'MSSQL_COLLATION=\$Collation')).Count -eq 2
)

if ($failures.Count -gt 0) {
    foreach ($failure in $failures) { Write-Host "FAIL: $failure" -ForegroundColor Red }
    exit 1
}
Write-Host "Version Catalog Checks: $passed PASS" -ForegroundColor Green
