[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$sqlReadinessPath = Join-Path $repoRoot 'Private\SqlReadiness.ps1'
$startPath = Join-Path $repoRoot 'Public\Start-SqlServerLab.ps1'
$documentationPath = Join-Path $repoRoot 'Documentation\HowTo\PODMAN_WINDOWS_NETWORKING.md'

$failures = [System.Collections.Generic.List[string]]::new()

function Assert-Contains {
    param(
        [Parameter(Mandatory)][string]$Content,
        [Parameter(Mandatory)][string]$Pattern,
        [Parameter(Mandatory)][string]$Description
    )

    if ($Content -notmatch $Pattern) {
        $failures.Add($Description)
    }
}

foreach ($path in @($sqlReadinessPath, $startPath, $documentationPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        $failures.Add("Datei fehlt: $path")
    }
}

if ($failures.Count -eq 0) {
    $sqlReadiness = Get-Content -LiteralPath $sqlReadinessPath -Raw -Encoding utf8
    $start = Get-Content -LiteralPath $startPath -Raw -Encoding utf8
    $documentation = Get-Content -LiteralPath $documentationPath -Raw -Encoding utf8

    Assert-Contains $sqlReadiness 'function\s+Get-PodmanWindowsLocalhostDiagnostic' 'Podman-Windows-Diagnosefunktion fehlt.'
    Assert-Contains $sqlReadiness 'networkingMode=mirrored' 'Konkreter WSL-Mirrored-Networking-Hinweis fehlt.'
    Assert-Contains $sqlReadiness 'SQL Server is now ready for client connections' 'Containerinterne SQL-Bereitschaft wird nicht geprueft.'
    Assert-Contains $sqlReadiness 'Start-Sleep\s+-Milliseconds' 'Readiness verwendet kein kurzes Millisekunden-Polling.'
    Assert-Contains $sqlReadiness 'function\s+Wait-LabDatabaseReady' 'Datenbank-Readiness-Funktion fehlt.'
    Assert-Contains $sqlReadiness 'Wait-LabDatabaseReady[\s\S]+Invoke-LabSqlScript' 'Skriptausfuehrung ist nicht gegen Datenbank-Readiness abgesichert.'

    Assert-Contains $start 'Wait-SqlReady' 'Start-SqlServerLab prueft die SQL-Readiness nicht.'
    Assert-Contains $start 'Wait-LabDatabaseReady' 'Start-SqlServerLab wartet nicht auf gespeicherte Benutzerdatenbanken.'
    Assert-Contains $start '\$instance\.databases' 'Start-SqlServerLab verwendet die gespeicherten Datenbanken nicht.'

    Assert-Contains $documentation 'networkingMode=mirrored' 'Podman-Windows-How-to dokumentiert mirrored networking nicht.'
    Assert-Contains $documentation 'eth0' 'Diagnose-Fallback ueber eth0 fehlt in der Dokumentation.'
}

if ($failures.Count -gt 0) {
    Write-Host 'READINESS CONTRACT CHECK: FAIL' -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}

Write-Host 'READINESS CONTRACT CHECK: PASS' -ForegroundColor Green
exit 0
