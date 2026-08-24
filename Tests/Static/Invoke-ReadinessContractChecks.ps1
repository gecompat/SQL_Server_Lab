[CmdletBinding()]
param(
    [Alias('h','help','?')][switch]$ShowHelp,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$RemainingArgs)

$showHelpRequested = $ShowHelp.IsPresent -or @($RemainingArgs) -contains '/?' -or @($RemainingArgs) -contains '-?' -or @($RemainingArgs) -contains '-h' -or @($RemainingArgs) -contains '--help'

if ($showHelpRequested) {

    Get-Help -Full -Name $PSCommandPath | Out-Host

    return

}

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$sqlReadinessPath = Join-Path $repoRoot 'Private\SqlReadiness.ps1'
$portAllocationPath = Join-Path $repoRoot 'Private\PortAllocation.ps1'
$startPath = Join-Path $repoRoot 'Public\Start-SqlServerLab.ps1'
$newLabPath = Join-Path $repoRoot 'Public\New-SqlServerLab.ps1'
$menuPath = Join-Path $repoRoot 'Public\Invoke-SqlServerLab.ps1'
$dockerProviderPath = Join-Path $repoRoot 'Providers\Docker\DockerProvider.ps1'
$podmanProviderPath = Join-Path $repoRoot 'Providers\Podman\PodmanProvider.ps1'
$podmanBootstrapPath = Join-Path $repoRoot 'Tests\Integration\Initialize-PodmanRuntime.ps1'
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

function Assert-NotContains {
    param(
        [Parameter(Mandatory)][string]$Content,
        [Parameter(Mandatory)][string]$Pattern,
        [Parameter(Mandatory)][string]$Description
    )

    if ($Content -match $Pattern) {
        $failures.Add($Description)
    }
}

foreach ($path in @(
    $sqlReadinessPath,
    $portAllocationPath,
    $startPath,
    $newLabPath,
    $menuPath,
    $dockerProviderPath,
    $podmanProviderPath,
    $podmanBootstrapPath,
    $documentationPath
)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        $failures.Add("Datei fehlt: $path")
    }
}

if ($failures.Count -eq 0) {
    $sqlReadiness = Get-Content -LiteralPath $sqlReadinessPath -Raw -Encoding utf8
    $portAllocation = Get-Content -LiteralPath $portAllocationPath -Raw -Encoding utf8
    $start = Get-Content -LiteralPath $startPath -Raw -Encoding utf8
    $newLab = Get-Content -LiteralPath $newLabPath -Raw -Encoding utf8
    $menu = Get-Content -LiteralPath $menuPath -Raw -Encoding utf8
    $dockerProvider = Get-Content -LiteralPath $dockerProviderPath -Raw -Encoding utf8
    $podmanProvider = Get-Content -LiteralPath $podmanProviderPath -Raw -Encoding utf8
    $podmanBootstrap = Get-Content -LiteralPath $podmanBootstrapPath -Raw -Encoding utf8
    $documentation = Get-Content -LiteralPath $documentationPath -Raw -Encoding utf8

    Assert-Contains $sqlReadiness 'function\s+Get-PodmanWindowsLocalhostDiagnostic' 'Podman-Windows-Diagnosefunktion fehlt.'
    Assert-Contains $sqlReadiness 'function\s+Resolve-PodmanWindowsHostName' 'Podman-Windows-Hostauflösung fehlt.'
    Assert-Contains $sqlReadiness 'podman\s+machine\s+list\s+--format\s+json' 'Podman-Windows-Hostauflösung ermittelt die aktive Machine nicht strukturiert.'
    Assert-Contains $sqlReadiness 'ip\s+-4\s+-o\s+addr\s+show\s+dev\s+eth0' 'Podman-Windows-Hostauflösung ermittelt keine IPv4-Adresse der WSL-Machine.'
    Assert-Contains $sqlReadiness 'networkingMode=mirrored' 'Konkreter WSL-Mirrored-Networking-Hinweis fehlt.'
    Assert-Contains $sqlReadiness 'SQL Server is now ready for client connections' 'Containerinterne SQL-Bereitschaft wird nicht geprueft.'
    Assert-Contains $sqlReadiness 'LAB_SQL_TRANSIENT_LOGIN_STATE_115' 'SQL-2025-State-115-Diagnosecode fehlt.'
    Assert-Contains $newLab "retryableSql2025State[\s\S]+instance\.version\s+-match\s+'\^2025" 'Readiness-Retry ist nicht auf SQL Server 2025 begrenzt.'
    Assert-Contains $newLab 'Remove-LabProviderContainerForReadinessRetry[\s\S]+-ScopeId\s+\$runState\.ScopeId' 'Readiness-Retry entfernt den Container nicht mit der erwarteten Scope-ID.'
    Assert-Contains $newLab 'readinessAttempt\s+-ge\s+2' 'SQL-2025-State-115-Retry ist nicht auf einen Versuch begrenzt.'
    Assert-Contains $newLab 'Resolve-PodmanWindowsHostName[\s\S]+Wait-SqlReady[\s\S]+-HostName\s+\$containerHost' 'Podman-Hostauflösung wird nicht für die SQL-Readiness verwendet.'
    Assert-Contains $newLab 'New-SqlConnectionString\s+-HostName\s+\$containerHost' 'Die gespeicherte Verbindung verwendet nicht den aufgelösten Podman-Host.'
    Assert-Contains $sqlReadiness 'Start-Sleep\s+-Milliseconds' 'Readiness verwendet kein kurzes Millisekunden-Polling.'
    Assert-Contains $sqlReadiness 'function\s+Wait-LabDatabaseReady' 'Datenbank-Readiness-Funktion fehlt.'
    Assert-Contains $sqlReadiness 'Wait-LabDatabaseReady[\s\S]+Invoke-LabSqlScript' 'Skriptausfuehrung ist nicht gegen Datenbank-Readiness abgesichert.'
    Assert-Contains $sqlReadiness 'if\s+\(\$KeepConnection\)[\s\S]+-i\s+\$tempScriptPath' 'KeepConnection fuehrt das Skript nicht in einem einzelnen sqlcmd-Prozess aus.'
    Assert-Contains $sqlReadiness 'WriteAllText\([\s\S]+UTF8Encoding\]::new\(\$true\)' 'KeepConnection erzeugt keine explizite UTF-8-BOM-Eingabedatei.'
    Assert-Contains $sqlReadiness '-X1[\s\S]+-x' 'KeepConnection deaktiviert die sqlcmd-Skriptebene nicht vollstaendig.'

    Assert-Contains $portAllocation 'function\s+Get-LabReservedSqlPorts' 'Runtimeuebergreifende Portermittlung fehlt.'
    Assert-Contains $portAllocation 'function\s+Find-LabAvailablePort' 'Gemeinsame freie Portsuche fehlt.'
    Assert-Contains $portAllocation 'function\s+Invoke-LabPortAllocationLock' 'Hostweiter Port-Lock fehlt.'
    Assert-Contains $portAllocation 'Global\\SQL_Server_Lab_Port_Allocation' 'Windows-Port-Lock ist nicht global benannt.'
    Assert-Contains $portAllocation "@\('docker',\s*'podman'\)" 'Portermittlung prueft Docker und Podman nicht gemeinsam.'

    Assert-Contains $dockerProvider 'Invoke-LabPortAllocationLock[\s\S]+docker\s+@dockerArguments' 'Docker bindet den Port nicht innerhalb des atomaren Locks.'
    Assert-Contains $dockerProvider 'Find-LabAvailablePort' 'Docker verwendet nicht die gemeinsame Portermittlung.'
    Assert-Contains $dockerProvider 'address already in use[\s\S]+\$nextPort\s*=\s*\$selectedPort\s*\+\s*1' 'Docker wiederholt automatische Portbindungskonflikte nicht mit dem naechsten Port.'
    Assert-Contains $dockerProvider 'docker\s+rm\s+-f\s+\$containerName' 'Docker entfernt einen bei Bindungsfehler teilweise angelegten Container nicht vor dem Retry.'

    Assert-Contains $podmanProvider 'Invoke-LabPortAllocationLock[\s\S]+podman\s+@podmanArguments' 'Podman bindet den Port nicht innerhalb des atomaren Locks.'
    Assert-Contains $podmanProvider 'Find-LabAvailablePort' 'Podman verwendet nicht die gemeinsame Portermittlung.'
    Assert-Contains $podmanProvider 'cannot bind tcp port[\s\S]+\$nextPort\s*=\s*\$selectedPort\s*\+\s*1' 'Podman wiederholt automatische Portbindungskonflikte nicht mit dem naechsten Port.'
    Assert-Contains $podmanProvider 'podman\s+rm\s+-f\s+\$containerName' 'Podman entfernt einen bei Bindungsfehler teilweise angelegten Container nicht vor dem Retry.'

    Assert-Contains $podmanBootstrap 'function\s+Test-PodmanRuntimeReady' 'Podman-Bootstrap prueft die Runtime-Erreichbarkeit nicht.'
    Assert-Contains $podmanBootstrap 'podman\s+machine\s+list\s+--format\s+json' 'Podman-Bootstrap ermittelt vorhandene Machines nicht strukturiert.'
    Assert-Contains $podmanBootstrap 'podman\s+machine\s+start\s+\$targetName' 'Podman-Bootstrap startet eine gestoppte Machine nicht.'
    Assert-Contains $podmanBootstrap 'SQL_Server_Lab_Podman_Bootstrap' 'Podman-Bootstrap besitzt keinen hostweiten Start-Lock.'
    Assert-Contains $podmanBootstrap 'Elapsed\.TotalSeconds\s+-lt\s+\$TimeoutSeconds' 'Podman-Bootstrap wartet nicht begrenzt auf Erreichbarkeit.'

    Assert-Contains $start 'Wait-SqlReady' 'Start-SqlServerLab prueft die SQL-Readiness nicht.'
    Assert-Contains $start 'Wait-LabDatabaseReady' 'Start-SqlServerLab wartet nicht auf gespeicherte Benutzerdatenbanken.'
    Assert-Contains $start '\$instance\.databases' 'Start-SqlServerLab verwendet die gespeicherten Datenbanken nicht.'

    Assert-Contains $menu 'function\s+Invoke-SqlServerLab' 'Interaktiver Einstiegspunkt fehlt.'
    Assert-Contains $menu 'Show-LabBanner' 'Menuebanner wird nicht aufgerufen.'
    Assert-Contains $menu 'Show-LabMenu' 'Menueauswahl wird nicht aufgerufen.'
    Assert-NotContains $menu 'function\s+Invoke-SqlServerLab[\s\S]{0,2500}Import-Module[\s\S]{0,100}-Force' 'Invoke-SqlServerLab darf das laufende Modul nicht selbst mit -Force neu laden.'
    Assert-Contains $menu '\$hyperv\s*=\s*Test-HyperVAvailable[\s\S]{0,180}if\s*\(\$hyperv\.Available\)' 'Das Menue muss Hyper-V über den vollständigen Provider-Readiness-Test freigeben.'

    Assert-Contains $documentation 'networkingMode=mirrored' 'Podman-Windows-How-to dokumentiert mirrored networking nicht.'
    Assert-Contains $documentation 'eth0' 'Diagnose-Fallback ueber eth0 fehlt in der Dokumentation.'
}

if ($failures.Count -gt 0) {
    Write-Host 'READINESS MENU AND PORT CONTRACT CHECK: FAIL' -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}

Write-Host 'READINESS MENU AND PORT CONTRACT CHECK: PASS' -ForegroundColor Green
exit 0



