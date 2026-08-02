#Requires -Version 7.2
<#
.SYNOPSIS
    End-to-End-Smoke-Test fuer einen Run mit Docker und Podman.
.DESCRIPTION
    Provisioniert zwei kompakte SQL-Server-Instanzen aus dem Mixed-Provider-
    Beispielmanifest, prueft Status, Stop, Start und vollstaendigen Cleanup.
    Der Test verwendet ausschliesslich einen temporaeren StateRoot und ein zur
    Laufzeit erzeugtes synthetisches SA-Passwort.
.PARAMETER Version
    SQL-Server-Version fuer beide Testinstanzen. Default: 2022.
.PARAMETER KeepOnFailure
    Behaelt den temporaeren StateRoot und die Labressourcen bei einem Fehler.
.EXAMPLE
    .\Tests\Integration\Invoke-MixedProviderSmokeTest.ps1
#>
[CmdletBinding()]
param(
    [string]$Version = '2022',
    [switch]$KeepOnFailure
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$modulePath = Join-Path $repoRoot 'SqlServerLab.psd1'
$sourceManifestPath = Join-Path $repoRoot 'Schemas\example-mixed-provider-lab.json'
$stateRoot = Join-Path ([System.IO.Path]::GetTempPath()) "sql-server-lab-mixed-$([guid]::NewGuid().ToString('N'))"
$previousStateRoot = $env:SQL_SERVER_LAB_STATE
$lab = $null
$testFailed = $false

function Assert-True {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Description
    )

    if (-not $Condition) {
        throw $Description
    }

    Write-Host "PASS: $Description" -ForegroundColor Green
}

function Test-RuntimeCommand {
    param([Parameter(Mandatory)][string]$Name)

    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        return $false
    }

    & $Name info 1>$null 2>$null
    return $LASTEXITCODE -eq 0
}

try {
    Write-Host 'Mixed-Provider-Smoke-Test: Docker + Podman' -ForegroundColor Cyan
    $null = & (Join-Path $PSScriptRoot 'Initialize-PodmanRuntime.ps1')
    foreach ($provider in @('docker', 'podman')) {
        Assert-True `
            -Condition (Test-RuntimeCommand -Name $provider) `
            -Description "Runtime '$provider' ist erreichbar"
    }

    $env:SQL_SERVER_LAB_STATE = $stateRoot
    Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
    Import-Module $modulePath -Force

    $manifest = Get-Content -LiteralPath $sourceManifestPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 30
    foreach ($instance in @($manifest.instances)) {
        $instance.version = $Version
    }
    $effectiveManifestPath = Join-Path $stateRoot 'mixed-provider-smoke.json'
    New-Item -Path $stateRoot -ItemType Directory -Force | Out-Null
    $manifest | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $effectiveManifestPath -Encoding utf8

    $assessment = Test-SqlServerLabPrerequisite -Provider @('docker', 'podman') -Instances @($manifest.instances)
    Assert-True `
        -Condition ($assessment.Status -ne 'RESOURCE_HARD_BLOCK') `
        -Description 'Gemischtes Resource Assessment ist nicht HARD_BLOCK'

    $passwordToken = [guid]::NewGuid().ToString('N').Substring(0, 16)
    $saPassword = ConvertTo-SecureString "MixedSmoke_${passwordToken}!Aa7" -AsPlainText -Force
    $lab = New-SqlServerLab `
        -Manifest $effectiveManifestPath `
        -SaPassword $saPassword `
        -SkipAssessment

    $actualProviders = @($lab.Instances | ForEach-Object { $_.Provider } | Sort-Object -Unique)
    Assert-True -Condition ($actualProviders -join ',' -eq 'docker,podman') -Description 'Beide Provider wurden provisioniert'
    Assert-True -Condition ($lab.Instances.Count -eq 2) -Description 'Zwei Instanzen wurden provisioniert'

    $status = @(Get-SqlServerLab -RunId $lab.RunId -Detailed)[0]
    Assert-True -Condition (@($status.Instances | Where-Object { $_.ContainerUp }).Count -eq 2) -Description 'Beide Container sind running'
    Assert-True -Condition (@($status.ProviderSubRuns | Where-Object { $_.State -eq 'RUNNING' }).Count -eq 2) -Description 'Beide ProviderSubRuns sind RUNNING'

    $stopResult = Stop-SqlServerLab -RunId $lab.RunId -Force
    Assert-True -Condition ($stopResult.Status -eq 'STOPPED') -Description 'Gemischter Run wurde gestoppt'
    Assert-True -Condition (@($stopResult.ProviderSubRuns | Where-Object { $_.Status -eq 'STOPPED' }).Count -eq 2) -Description 'Beide ProviderSubRuns wurden gestoppt'

    $stoppedStatus = @(Get-SqlServerLab -RunId $lab.RunId)[0]
    Assert-True -Condition (@($stoppedStatus.Instances | Where-Object { $_.ContainerUp }).Count -eq 0) -Description 'Kein Container laeuft nach Stop'

    $startResult = Start-SqlServerLab -RunId $lab.RunId
    Assert-True -Condition ($startResult.Status -eq 'RUNNING') -Description 'Gemischter Run wurde gestartet'
    Assert-True -Condition (@($startResult.ProviderSubRuns | Where-Object { $_.Status -eq 'STARTED' }).Count -eq 2) -Description 'Beide ProviderSubRuns wurden gestartet'

    $startedStatus = @(Get-SqlServerLab -RunId $lab.RunId -Detailed)[0]
    Assert-True -Condition (@($startedStatus.Instances | Where-Object { $_.ContainerUp }).Count -eq 2) -Description 'Beide Container laufen nach Start'
    Assert-True -Condition (@($startedStatus.ProviderSubRuns | Where-Object { $_.State -eq 'RUNNING' }).Count -eq 2) -Description 'Beide ProviderSubRuns sind nach Start RUNNING'

    $removeResult = Remove-SqlServerLab -RunId $lab.RunId -StateRoot $stateRoot -Force
    Assert-True -Condition ($removeResult.Status -eq 'REMOVED') -Description 'Gemischter Run wurde vollstaendig entfernt'
    $lab = $null
}
catch {
    $testFailed = $true
    Write-Host "FAIL: $($_.Exception.Message)" -ForegroundColor Red
}
finally {
    if ($lab -and -not $KeepOnFailure) {
        try {
            Remove-SqlServerLab -RunId $lab.RunId -StateRoot $stateRoot -Force | Out-Null
        }
        catch {
            Write-Host "Cleanup-Fehler: $($_.Exception.Message)" -ForegroundColor Red
            $testFailed = $true
        }
    }

    if (-not $KeepOnFailure -and (Test-Path -LiteralPath $stateRoot -PathType Container)) {
        Remove-Item -LiteralPath $stateRoot -Recurse -Force
    }

    $env:SQL_SERVER_LAB_STATE = $previousStateRoot
}

if ($testFailed) {
    exit 1
}

Write-Host 'Mixed-Provider-Smoke-Test erfolgreich.' -ForegroundColor Green
exit 0
