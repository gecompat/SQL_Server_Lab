$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$catalog = Get-Content -LiteralPath (Join-Path $root 'Catalogs\sql-server-versions.json') -Raw | ConvertFrom-Json -Depth 30
$sql2025 = $catalog.versions | Where-Object id -eq '2025' | Select-Object -First 1
$cus = @($sql2025.docker.builds | Where-Object { $_.cu -match '^CU\d+$' })
if ($cus.Count -lt 1) { throw 'VERSION_CATALOG_SQL2025_CUS_MISSING' }
if (@($cus.cu | Sort-Object -Unique).Count -ne $cus.Count) { throw 'VERSION_CATALOG_DUPLICATE_CU' }
foreach ($cu in $cus) {
    if (-not $cu.tag -or -not $cu.build -or -not $cu.kb -or -not $cu.released) { throw "VERSION_CATALOG_CU_INCOMPLETE: $($cu.cu)" }
    if (-not $cu.windows.relativePath) { throw "VERSION_CATALOG_WINDOWS_PATH_MISSING: $($cu.cu)" }
    if ($cu.windows.downloadUrl -and -not $cu.windows.sha256) { throw "VERSION_CATALOG_UNTRUSTED_AUTODOWNLOAD: $($cu.cu)" }
}
Write-Host "VERSION CATALOG CHECKS: PASS ($($cus.Count) SQL-2025-CUs)" -ForegroundColor Green
