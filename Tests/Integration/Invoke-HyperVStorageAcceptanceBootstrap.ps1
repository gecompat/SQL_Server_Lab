#Requires -Version 7.2
<#
.SYNOPSIS
    Baut ein isoliertes SQL-2025-Prepared-Artifact, fuehrt damit Gate N5 aus
    und entfernt den vollstaendigen Test-State anschliessend scopegebunden.
.DESCRIPTION
    Der Wrapper ist fuer Hosts gedacht, die drei geeignete physische
    Storage-Locations besitzen, aber kein dauerhaftes SQL_PREPARED_SEALED-
    Artifact vorhalten. Zuerst laeuft die reale N4-Abnahme mit expliziter
    temporaerer Artifact-Aufbewahrung. Danach verwendet der normale N5-Runner
    exakt dieses Artifact und State-Root. Das isolierte N4-State-Root wird auch
    bei einem N5-Fehler nur nach strikter Parent- und Namenspruefung entfernt.
.PARAMETER StorageIntentPath
    Portabler SqlServerLab.StorageIntent/1.0 fuer den N5-Lauf.
.PARAMETER MediaRoot
    Externer Media Root mit den hashverifizierten Windows- und SQL-Medien.
.PARAMETER TimeoutSeconds
    Timeout fuer Windows-OOBE, Neustarts und Sysprep im N4-Bootstrap.
.PARAMETER SetupTimeoutSeconds
    Maximale Laufzeit fuer SQL Server PrepareImage im N4-Bootstrap.
.PARAMETER N5OobeTimeoutSeconds
    Timeout fuer die SQL-Prepared-Spezialisierung im N5-Lauf.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$StorageIntentPath,
    [string]$MediaRoot = 'D:\Lab_Base',
    [ValidateRange(300, 3600)][int]$TimeoutSeconds = 1200,
    [ValidateRange(600, 10800)][int]$SetupTimeoutSeconds = 7200,
    [ValidateRange(60, 3600)][int]$N5OobeTimeoutSeconds = 1200
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$modulePath = Join-Path $repoRoot 'SqlServerLab.psd1'
$n4Runner = Join-Path $PSScriptRoot 'Invoke-HyperVSqlPreparedImageAcceptance.ps1'
$n5Runner = Join-Path $PSScriptRoot 'Invoke-HyperVStorageAcceptance.ps1'
$retainedStateRoot = $null
$testFailed = $false

function Invoke-BootstrapChildProcess {
    param([Parameter(Mandatory)][string[]]$Arguments)

    $lines = [Collections.Generic.List[string]]::new()
    & pwsh @Arguments 2>&1 | ForEach-Object {
        $line = [string]$_
        $lines.Add($line)
        Write-Host $line
    }
    [PSCustomObject]@{ ExitCode = $LASTEXITCODE; Lines = @($lines) }
}

function Assert-RetainedStateRootScope {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ExpectedParent
    )

    $resolvedPath = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $resolvedParent = [IO.Path]::GetFullPath($ExpectedParent).TrimEnd('\')
    $actualParent = [IO.Directory]::GetParent($resolvedPath).FullName.TrimEnd('\')
    $leaf = [IO.Path]::GetFileName($resolvedPath)
    if (-not $actualParent.Equals($resolvedParent, [StringComparison]::OrdinalIgnoreCase) -or
        $leaf -notmatch '^n4sql-[a-f0-9]{8}$') {
        throw 'HYPERV_STORAGE_BOOTSTRAP_STATE_SCOPE_INVALID'
    }
    $resolvedPath
}

try {
    $resolvedIntentPath = (Resolve-Path -LiteralPath $StorageIntentPath -ErrorAction Stop).Path
    $resolvedMediaRoot = (Resolve-Path -LiteralPath $MediaRoot -ErrorAction Stop).Path
    Import-Module $modulePath -Force
    $module = Get-Module SqlServerLab
    $productionStateRoot = & $module { Get-LabStateRoot }

    Write-Host 'N5-Bootstrap 1/2: isoliertes SQL-2025-Prepared-Artifact erstellen und verifizieren.' -ForegroundColor Cyan
    $n4 = Invoke-BootstrapChildProcess -Arguments @(
        '-NoProfile', '-File', $n4Runner,
        '-TimeoutSeconds', [string]$TimeoutSeconds,
        '-SetupTimeoutSeconds', [string]$SetupTimeoutSeconds,
        '-RetainPreparedArtifact'
    )
    if ([int]$n4.ExitCode -ne 0) {
        throw "HYPERV_STORAGE_BOOTSTRAP_N4_FAILED: ExitCode=$($n4.ExitCode)"
    }

    $stateMarkers = @($n4.Lines | Where-Object { $_ -like 'RETAINED_STATE_ROOT=*' })
    $artifactMarkers = @($n4.Lines | Where-Object { $_ -like 'RETAINED_ARTIFACT_ID=*' })
    if ($stateMarkers.Count -ne 1 -or $artifactMarkers.Count -ne 1) {
        throw 'HYPERV_STORAGE_BOOTSTRAP_MARKERS_INVALID'
    }
    $retainedStateRoot = Assert-RetainedStateRootScope `
        -Path $stateMarkers[0].Substring('RETAINED_STATE_ROOT='.Length) `
        -ExpectedParent $productionStateRoot
    $artifactId = $artifactMarkers[0].Substring('RETAINED_ARTIFACT_ID='.Length)
    if ($artifactId -notmatch '^hyperv-sql-prepared-sealed-[a-f0-9]{64}$') {
        throw 'HYPERV_STORAGE_BOOTSTRAP_ARTIFACT_ID_INVALID'
    }

    Write-Host 'N5-Bootstrap 2/2: physischen Drei-Geraete-Storage-Vertrag ausfuehren.' -ForegroundColor Cyan
    $n5 = Invoke-BootstrapChildProcess -Arguments @(
        '-NoProfile', '-File', $n5Runner,
        '-StorageIntentPath', $resolvedIntentPath,
        '-MediaRoot', $resolvedMediaRoot,
        '-ArtifactId', $artifactId,
        '-OobeTimeoutSeconds', [string]$N5OobeTimeoutSeconds,
        '-StateRoot', $retainedStateRoot
    )
    if ([int]$n5.ExitCode -ne 0) {
        throw "HYPERV_STORAGE_BOOTSTRAP_N5_FAILED: ExitCode=$($n5.ExitCode)"
    }
}
catch {
    $testFailed = $true
    Write-Host "FAIL: $($_.Exception.Message)" -ForegroundColor Red
}
finally {
    if ($retainedStateRoot -and (Test-Path -LiteralPath $retainedStateRoot -PathType Container)) {
        try {
            $validatedRoot = Assert-RetainedStateRootScope -Path $retainedStateRoot -ExpectedParent $productionStateRoot
            Remove-Item -LiteralPath $validatedRoot -Recurse -Force -ErrorAction Stop
            if (Test-Path -LiteralPath $validatedRoot) {
                throw 'HYPERV_STORAGE_BOOTSTRAP_STATE_CLEANUP_INCOMPLETE'
            }
            Write-Host 'PASS: Isoliertes Prepared-Artifact und testlokales State-Root wurden entfernt.' -ForegroundColor Green
        }
        catch {
            $testFailed = $true
            Write-Host "RECOVERY_REQUIRED: $($_.Exception.Message)" -ForegroundColor Red
        }
    }
}

if ($testFailed) { exit 1 }
Write-Host 'Reale N5-Hyper-V-Storage-Abnahme mit isoliertem Artifact-Bootstrap erfolgreich.' -ForegroundColor Green
exit 0
