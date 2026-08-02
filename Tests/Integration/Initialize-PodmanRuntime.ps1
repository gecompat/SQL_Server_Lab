#Requires -Version 7.2
<#
.SYNOPSIS
    Stellt eine installierte Podman-Runtime fuer Integrationstests bereit.
.DESCRIPTION
    Beendet sich sofort, wenn `podman info` erfolgreich ist. Ist Podman
    installiert, aber keine Runtime erreichbar, wird eine vorhandene gestoppte
    Podman-Machine gestartet. Anschliessend wartet das Skript begrenzt auf eine
    erfolgreiche Verbindung.

    Das Skript erstellt keine neue Podman-Machine und veraendert keine
    Connection-Auswahl. Bei mehreren gestoppten Machines wird bevorzugt
    `podman-machine-default` verwendet; ohne eindeutiges Ziel bricht es ab.
.PARAMETER TimeoutSeconds
    Maximale Wartezeit nach dem Start. Default: 90 Sekunden.
.PARAMETER PollIntervalSeconds
    Abstand zwischen Erreichbarkeitspruefungen. Default: 2 Sekunden.
.EXAMPLE
    .\Tests\Integration\Initialize-PodmanRuntime.ps1
.OUTPUTS
    PSCustomObject mit Status, MachineName und StartedByScript.
#>
[CmdletBinding()]
param(
    [ValidateRange(10, 600)]
    [int]$TimeoutSeconds = 90,

    [ValidateRange(1, 30)]
    [int]$PollIntervalSeconds = 2
)

$ErrorActionPreference = 'Stop'

function Test-PodmanRuntimeReady {
    & podman info 1>$null 2>$null
    return $LASTEXITCODE -eq 0
}

function Get-PodmanMachineName {
    param([Parameter(Mandatory)]$Machine)

    foreach ($propertyName in @('Name', 'name')) {
        $property = $Machine.PSObject.Properties[$propertyName]
        if ($property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
            return [string]$property.Value
        }
    }

    return $null
}

if (-not (Get-Command podman -ErrorAction SilentlyContinue)) {
    throw 'Podman ist auf diesem Host nicht installiert oder nicht im PATH verfuegbar.'
}

$mutexName = if ($IsWindows) {
    'Global\SQL_Server_Lab_Podman_Bootstrap'
}
else {
    'SQL_Server_Lab_Podman_Bootstrap'
}
$mutex = [System.Threading.Mutex]::new($false, $mutexName)
$acquired = $false

try {
    $acquired = $mutex.WaitOne([TimeSpan]::FromMinutes(2))
    if (-not $acquired) {
        throw 'Podman-Bootstrap-Lock konnte innerhalb von zwei Minuten nicht erworben werden.'
    }

    if (Test-PodmanRuntimeReady) {
        Write-Host 'Podman-Runtime ist bereits erreichbar.' -ForegroundColor Green
        return [pscustomobject]@{
            Status          = 'READY'
            MachineName     = $null
            StartedByScript = $false
        }
    }

    $machineOutput = @(& podman machine list --format json 2>&1)
    $machineExitCode = $LASTEXITCODE
    $machineText = $machineOutput -join "`n"
    if ($machineExitCode -ne 0) {
        throw "Podman ist installiert, aber die Machine-Liste konnte nicht gelesen werden: $machineText"
    }

    try {
        $machines = @($machineText | ConvertFrom-Json)
    }
    catch {
        throw "Podman-Machine-Liste ist kein gueltiges JSON: $($_.Exception.Message)"
    }

    $machines = @($machines | Where-Object { Get-PodmanMachineName -Machine $_ })
    if ($machines.Count -eq 0) {
        throw 'Podman ist installiert, aber es existiert keine Machine, die automatisch gestartet werden kann.'
    }

    $target = @(
        $machines | Where-Object { (Get-PodmanMachineName -Machine $_) -eq 'podman-machine-default' }
    ) | Select-Object -First 1

    if (-not $target -and $machines.Count -eq 1) {
        $target = $machines[0]
    }
    if (-not $target) {
        $names = @($machines | ForEach-Object { Get-PodmanMachineName -Machine $_ })
        throw "Mehrere Podman-Machines vorhanden; automatisches Startziel ist nicht eindeutig: $($names -join ', ')."
    }

    $targetName = Get-PodmanMachineName -Machine $target
    Write-Host "Podman-Runtime ist nicht erreichbar. Starte Machine '$targetName' ..." -ForegroundColor Yellow
    $startOutput = @(& podman machine start $targetName 2>&1)
    $startExitCode = $LASTEXITCODE
    if ($startExitCode -ne 0) {
        throw "Podman-Machine '$targetName' konnte nicht gestartet werden: $($startOutput -join "`n")"
    }

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    do {
        if (Test-PodmanRuntimeReady) {
            $stopwatch.Stop()
            Write-Host "Podman-Machine '$targetName' ist erreichbar." -ForegroundColor Green
            return [pscustomobject]@{
                Status          = 'READY'
                MachineName     = $targetName
                StartedByScript = $true
            }
        }

        Start-Sleep -Seconds $PollIntervalSeconds
    } while ($stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds)

    $stopwatch.Stop()
    throw "Podman-Machine '$targetName' wurde gestartet, war aber nach $TimeoutSeconds Sekunden nicht erreichbar."
}
finally {
    if ($acquired) {
        $mutex.ReleaseMutex()
    }
    $mutex.Dispose()
}
