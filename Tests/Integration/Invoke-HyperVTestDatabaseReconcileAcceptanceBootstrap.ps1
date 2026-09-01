#Requires -Version 7.2
<#
.SYNOPSIS
    Baut ein isoliertes SQL-Prepared-Artifact und fuehrt den nativen
    Hyper-V-Testdatenbank-Reconcile aus.
.DESCRIPTION
    Verwendet den realen N4-Prepared-Image-Runner mit expliziter Aufbewahrung,
    uebergibt dessen Artifact-ID und State Root an die Testdatenbank-Abnahme und
    entfernt beide nur nach vollstaendig erfolgreichem Add/Remove-/Cleanup-Lauf.
    Bei einem Fehler bleibt der exakte State Root samt Artifact und etwaigem
    Recovery-Run sichtbar.
#>
[CmdletBinding()]
param(
    [string]$MediaRoot = 'D:\Lab_Base',
    [ValidateRange(300,3600)][int]$TimeoutSeconds = 1200,
    [ValidateRange(600,10800)][int]$SetupTimeoutSeconds = 7200,
    [ValidateRange(300,3600)][int]$ReconcileOobeTimeoutSeconds = 1200
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$modulePath = Join-Path $repoRoot 'SqlServerLab.psd1'
$preparedRunner = Join-Path $PSScriptRoot 'Invoke-HyperVSqlPreparedImageAcceptance.ps1'
$reconcileRunner = Join-Path $PSScriptRoot 'Invoke-HyperVTestDatabaseReconcileAcceptance.ps1'
$retainedStateRoot = $null
$retainedArtifactId = $null
$productionStateRoot = $null
$testFailed = $false

function Invoke-BootstrapChildProcess {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $lines = [Collections.Generic.List[string]]::new()
    & pwsh @Arguments 2>&1 | ForEach-Object {
        $line = [string]$_
        $lines.Add($line)
        Write-Host $line
    }
    [PSCustomObject]@{ExitCode=$LASTEXITCODE;Lines=@($lines)}
}

function Assert-RetainedStateRootScope {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$ExpectedParent)
    $resolvedPath = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $resolvedParent = [IO.Path]::GetFullPath($ExpectedParent).TrimEnd('\')
    $actualParent = [IO.Directory]::GetParent($resolvedPath).FullName.TrimEnd('\')
    $leaf = [IO.Path]::GetFileName($resolvedPath)
    if (-not $actualParent.Equals($resolvedParent,[StringComparison]::OrdinalIgnoreCase) -or
        $leaf -notmatch '^n4sql-[a-f0-9]{8}$') {
        throw 'HYPERV_TEST_DATABASE_BOOTSTRAP_STATE_SCOPE_INVALID'
    }
    $resolvedPath
}

try {
    $principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'HYPERV_TEST_DATABASE_BOOTSTRAP_REQUIRES_ELEVATED_RUNNER'
    }
    $resolvedMediaRoot = (Resolve-Path -LiteralPath $MediaRoot -ErrorAction Stop).Path
    Import-Module $modulePath -Force
    $module = Get-Module SqlServerLab
    $productionStateRoot = & $module { Get-LabStateRoot }

    Write-Host 'Testdatenbank-Bootstrap 1/2: isoliertes SQL-2025-Prepared-Artifact erstellen.' -ForegroundColor Cyan
    $prepared = Invoke-BootstrapChildProcess -Arguments @(
        '-NoProfile','-File',$preparedRunner,
        '-MediaRoot',$resolvedMediaRoot,
        '-TimeoutSeconds',[string]$TimeoutSeconds,
        '-SetupTimeoutSeconds',[string]$SetupTimeoutSeconds,
        '-RetainPreparedArtifact'
    )
    if ([int]$prepared.ExitCode -ne 0) {
        throw "HYPERV_TEST_DATABASE_BOOTSTRAP_PREPARED_FAILED: ExitCode=$($prepared.ExitCode)"
    }
    $stateMarkers = @($prepared.Lines | Where-Object { $_ -like 'RETAINED_STATE_ROOT=*' })
    $artifactMarkers = @($prepared.Lines | Where-Object { $_ -like 'RETAINED_ARTIFACT_ID=*' })
    if ($stateMarkers.Count -ne 1 -or $artifactMarkers.Count -ne 1) {
        throw 'HYPERV_TEST_DATABASE_BOOTSTRAP_MARKERS_INVALID'
    }
    $retainedStateRoot = Assert-RetainedStateRootScope `
        -Path $stateMarkers[0].Substring('RETAINED_STATE_ROOT='.Length) `
        -ExpectedParent $productionStateRoot
    $retainedArtifactId = $artifactMarkers[0].Substring('RETAINED_ARTIFACT_ID='.Length)
    if ($retainedArtifactId -notmatch '^hyperv-sql-prepared-sealed-[a-f0-9]{64}$') {
        throw 'HYPERV_TEST_DATABASE_BOOTSTRAP_ARTIFACT_ID_INVALID'
    }

    Write-Host 'Testdatenbank-Bootstrap 2/2: nativen Plan/WhatIf/Add/No-op/Remove-Zyklus ausfuehren.' -ForegroundColor Cyan
    $reconcile = Invoke-BootstrapChildProcess -Arguments @(
        '-NoProfile','-File',$reconcileRunner,
        '-ArtifactId',$retainedArtifactId,
        '-StateRoot',$retainedStateRoot,
        '-OobeTimeoutSeconds',[string]$ReconcileOobeTimeoutSeconds,
        '-KeepOnFailure'
    )
    if ([int]$reconcile.ExitCode -ne 0) {
        throw "HYPERV_TEST_DATABASE_BOOTSTRAP_RECONCILE_FAILED: ExitCode=$($reconcile.ExitCode)"
    }
}
catch {
    $testFailed = $true
    Write-Host "FAIL: $($_.Exception.Message)" -ForegroundColor Red
}
finally {
    if ($retainedStateRoot) {
        try {
            $validatedRoot = Assert-RetainedStateRootScope -Path $retainedStateRoot -ExpectedParent $productionStateRoot
            if ($testFailed) {
                throw 'HYPERV_TEST_DATABASE_BOOTSTRAP_RECOVERY_REQUIRED: StateRoot und Prepared-Artifact bleiben erhalten.'
            }
            if (-not $retainedArtifactId) {
                throw 'HYPERV_TEST_DATABASE_BOOTSTRAP_ARTIFACT_ID_REQUIRED_FOR_CLEANUP'
            }
            $artifactCleanup = & $module {
                param($ArtifactId,$Root)
                Remove-HyperVImageArtifact -ArtifactId $ArtifactId -StateRoot $Root
            } $retainedArtifactId $validatedRoot
            if ([string]$artifactCleanup.Status -ne 'REMOVED') {
                throw "HYPERV_TEST_DATABASE_BOOTSTRAP_ARTIFACT_CLEANUP_INCOMPLETE: $([string]$artifactCleanup.Status)"
            }
            $remainingArtifact = & $module {
                param($ArtifactId,$Root)
                Get-HyperVImageArtifact -ArtifactId $ArtifactId -StateRoot $Root -SkipIntegrityCheck
            } $retainedArtifactId $validatedRoot
            if ($remainingArtifact) {
                throw 'HYPERV_TEST_DATABASE_BOOTSTRAP_ARTIFACT_CLEANUP_POSTCONDITION_FAILED'
            }
            if (Test-Path -LiteralPath $validatedRoot -PathType Container) {
                Remove-Item -LiteralPath $validatedRoot -Recurse -Force -ErrorAction Stop
            }
            if (Test-Path -LiteralPath $validatedRoot) {
                throw 'HYPERV_TEST_DATABASE_BOOTSTRAP_STATE_CLEANUP_INCOMPLETE'
            }
            Write-Host 'PASS: Isoliertes Prepared-Artifact und State Root wurden entfernt.' -ForegroundColor Green
        }
        catch {
            $testFailed = $true
            Write-Host "RECOVERY_REQUIRED: $($_.Exception.Message)" -ForegroundColor Red
            Write-Host "RETAINED_STATE_ROOT=$retainedStateRoot"
            if ($retainedArtifactId) { Write-Host "RETAINED_ARTIFACT_ID=$retainedArtifactId" }
        }
    }
}

if ($testFailed) { exit 1 }
Write-Host 'Native Hyper-V-Testdatenbank-Reconcile-Abnahme mit isoliertem Bootstrap erfolgreich.' -ForegroundColor Green
exit 0
