$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$moduleLoaderSource = Get-Content -LiteralPath (Join-Path $repoRoot 'SqlServerLab.psm1') -Raw
$entrySource = Get-Content -LiteralPath (Join-Path $repoRoot 'Invoke-SqlServerLab.ps1') -Raw

$checks = @(
    [pscustomobject]@{ Name='Loader sammelt und verwirft keine Dateiladefehler'; Passed=($moduleLoaderSource -match 'ModuleLoadErrors' -and $moduleLoaderSource -match 'SQL_SERVER_LAB_MODULE_LOAD_FAILED') }
    [pscustomobject]@{ Name='Loader prueft den internen Ressourcenvertrag'; Passed=($moduleLoaderSource -match 'SQL_SERVER_LAB_MODULE_CONTRACT_INCOMPLETE' -and $moduleLoaderSource -match "'Get-LabEnvironmentResources'" -and $moduleLoaderSource -match "'Set-LabEnvironmentResources'") }
    [pscustomobject]@{ Name='Standalone-Starter importiert fail-closed'; Passed=($entrySource -match 'Import-Module \$modulePath -Force -ErrorAction Stop') }
    [pscustomobject]@{ Name='Standalone-Starter prueft Funktionen im Modulscope'; Passed=($entrySource -match '& \$loadedModule' -and $entrySource -match 'SQL_SERVER_LAB_MODULE_CONTRACT_INCOMPLETE') }
)

foreach ($check in $checks) {
    if (-not $check.Passed) { throw "FAIL: $($check.Name)" }
    Write-Host "  PASS  $($check.Name)" -ForegroundColor Green
}

Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -ErrorAction Stop
$module = Get-Module SqlServerLab -ErrorAction Stop
$available = @(& $module {
    @('Get-LabEnvironmentResources', 'Set-LabEnvironmentResources') | Where-Object {
        Get-Command $_ -CommandType Function -ErrorAction SilentlyContinue
    }
})
if ($available.Count -ne 2) { throw 'FAIL: Frischer Modulimport enthaelt den Ressourcenvertrag nicht.' }
Write-Host '  PASS  Frischer Modulimport enthaelt den Ressourcenvertrag' -ForegroundColor Green
Write-Host 'Module load contract checks: 5 PASS, 0 FAIL' -ForegroundColor Green
