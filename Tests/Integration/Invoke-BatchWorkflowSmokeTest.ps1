#Requires -Version 7.2
<#
.SYNOPSIS
    End-to-End-Smoke-Test fuer Batch, Queue, Scheduler und Cleanup.
.DESCRIPTION
    Plant zwei kompakte SQL-Server-Umgebungen fuer einen Container-Provider,
    fuehrt sie mit zwei Scheduler-Workern aus, prueft persistente Operationen,
    eindeutige Runs und idempotentes Resume und baut danach den vollstaendigen
    Batch-Scope wieder ab. State und SA-Passwort werden nur temporaer erzeugt.
.PARAMETER Provider
    Zu pruefender Container-Provider: docker oder podman.
.PARAMETER Version
    SQL-Server-Referenzversion. Default: 2025.
.PARAMETER ArtifactId
    Fuer Hyper-V erforderliche veroeffentlichte OS- oder SQL-Prepared-ArtifactId.
.PARAMETER ArtifactStateRoot
    Optionaler Quell-StateRoot des immutable Hyper-V-Artefakts.
.PARAMETER KeepOnFailure
    Behaelt State und Labressourcen nach einem Fehler fuer die Diagnose.
.EXAMPLE
    .\Tests\Integration\Invoke-BatchWorkflowSmokeTest.ps1 -Provider docker
#>
[CmdletBinding()]
param(
    [ValidateSet('docker', 'podman', 'hyperv')]
    [string]$Provider = 'docker',

    [string]$Version = '2025',

    [string]$ArtifactId,

    [string]$ArtifactStateRoot,

    [switch]$KeepOnFailure
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$modulePath = Join-Path $repoRoot 'SqlServerLab.psd1'
$stateRoot = Join-Path ([IO.Path]::GetTempPath()) ('sql-server-lab-batch-smoke-' + [Guid]::NewGuid().ToString('N'))
$secretVariable = 'SQL_SERVER_LAB_SECRET_BATCH_SMOKE_SA_PASSWORD'
$previousSecret = [Environment]::GetEnvironmentVariable($secretVariable)
$previousStateRoot = $env:SQL_SERVER_LAB_STATE
$batch = $null
$operations = @()
$testFailed = $false
$testArtifactDirectory = $null

function Assert-BatchSmoke {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Description
    )

    if (-not $Condition) {
        throw $Description
    }
    Write-Host "PASS: $Description" -ForegroundColor Green
}

function Test-BatchRuntime {
    param([Parameter(Mandatory)][string]$Name)

    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        return $false
    }
    & $Name info 1>$null 2>$null
    return $LASTEXITCODE -eq 0
}

try {
    Write-Host "Batch-/Queue-Smoke-Test: $Provider" -ForegroundColor Cyan
    if ($Provider -eq 'podman') {
        $null = & (Join-Path $PSScriptRoot 'Initialize-PodmanRuntime.ps1')
    }
    New-Item -Path $stateRoot -ItemType Directory -Force | Out-Null
    $env:SQL_SERVER_LAB_STATE = $stateRoot

    Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
    Import-Module $modulePath -Force
    $module = Get-Module SqlServerLab

    if ($Provider -eq 'hyperv') {
        $hyperVAvailable = & $module { [bool](Test-HyperVAvailable).Available }
        Assert-BatchSmoke -Condition $hyperVAvailable -Description "Runtime '$Provider' ist erreichbar"
        if ([string]::IsNullOrWhiteSpace($ArtifactId)) {
            throw 'Fuer den Hyper-V-Batch-Smoke ist -ArtifactId erforderlich.'
        }
        if ([string]::IsNullOrWhiteSpace($ArtifactStateRoot)) {
            $ArtifactStateRoot = if (-not [string]::IsNullOrWhiteSpace($previousStateRoot)) {
                $previousStateRoot
            }
            else {
                Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'SqlServerLab'
            }
        }
        $sourceArtifact = & $module {
            param($Id, $Root)
            Get-HyperVImageArtifact -ArtifactId $Id -StateRoot $Root
        } $ArtifactId $ArtifactStateRoot
        if ($null -eq $sourceArtifact) {
            throw "HYPERV_BATCH_SMOKE_ARTIFACT_NOT_FOUND: $ArtifactId"
        }
        $sourceArtifactDirectory = Split-Path -Parent ([string]$sourceArtifact.Path)
        $testArtifactDirectory = Join-Path (Join-Path $stateRoot 'artifacts\hyperv\images') $ArtifactId
        New-Item -Path (Split-Path -Parent $testArtifactDirectory) -ItemType Directory -Force | Out-Null
        New-Item -ItemType Junction -Path $testArtifactDirectory -Target $sourceArtifactDirectory | Out-Null
        Assert-BatchSmoke -Condition ((Get-Item -LiteralPath (Join-Path $testArtifactDirectory 'parent.vhdx')).IsReadOnly) -Description 'Immutable Parent-VHDX ist schreibgeschuetzt in den isolierten Test-State eingebunden'
    }
    else {
        Assert-BatchSmoke -Condition (Test-BatchRuntime -Name $Provider) -Description "Runtime '$Provider' ist erreichbar"
        $passwordToken = [Guid]::NewGuid().ToString('N').Substring(0, 16)
        [Environment]::SetEnvironmentVariable($secretVariable, "BatchSmoke_${passwordToken}!Aa7")
    }

    $defaults = if ($Provider -eq 'hyperv') {
        [pscustomobject]@{
            ProviderPreference = 'hyperv'
            ArtifactId = $ArtifactId
            MemoryStartupMB = 2048
            ProcessorCount = 2
            AutoStart = $false
            RequiresUserSetup = $false
        }
    }
    else {
        [pscustomobject]@{
            ProviderPreference = $Provider
            Version = $Version
            Profile = 'compact'
            Cpu = 2
            MemoryMB = 2048
            AutoStart = $false
            SaPasswordEnvironmentVariable = $secretVariable
        }
    }
    $kind = if ($Provider -eq 'hyperv') { 'WindowsSlot' } else { 'SqlEnvironment' }

    $batch = New-SqlServerLabBatch `
        -Name "Batch smoke $Provider" `
        -StateRoot $stateRoot `
        -Defaults $defaults `
        -Items @(
            [pscustomobject]@{
                id = 'sql-runtime'
                kind = $kind
                count = 2
                intent = [pscustomobject]@{ LabName = "batch-smoke-$Provider" }
            }
        )

    Assert-BatchSmoke -Condition ($batch.status -eq 'Queued') -Description 'Batch wurde atomar eingereiht'
    Assert-BatchSmoke -Condition (@($batch.operationIds).Count -eq 2) -Description 'count=2 erzeugte zwei persistente Operationen'

    & $module {
        param($Root)
        Invoke-SqlServerLabScheduler -UntilIdle -MaxWorkers 2 -StateRoot $Root | Out-Null
    } $stateRoot

    $batch = Get-SqlServerLabBatch -BatchId $batch.batchId -StateRoot $stateRoot
    $operations = @(Get-SqlServerLabOperation -BatchId $batch.batchId -StateRoot $stateRoot)
    if ($batch.status -ne 'Completed') {
        foreach ($operation in $operations) {
            $errorMessage = if ($operation.error) { [string]$operation.error.message } else { '' }
            Write-Host ("Operation {0}: Status={1}; RunId={2}; Fehler={3}" -f $operation.operationId, $operation.status, $operation.runId, $errorMessage) -ForegroundColor Yellow
        }
    }
    Assert-BatchSmoke -Condition ($batch.status -eq 'Completed') -Description 'Batch wurde vollstaendig abgeschlossen'
    Assert-BatchSmoke -Condition (@($operations | Where-Object status -eq 'Completed').Count -eq 2) -Description 'Beide Operationen wurden unabhaengig abgeschlossen'

    $runIds = @($operations | ForEach-Object runId)
    Assert-BatchSmoke -Condition (@($runIds | Sort-Object -Unique).Count -eq 2) -Description 'Operationen besitzen eindeutige RunIds'
    foreach ($runId in $runIds) {
        $run = @(Get-SqlServerLab -RunId $runId -Detailed)[0]
        Assert-BatchSmoke -Condition ($null -ne $run) -Description "Run '$runId' ist lesbar"
        Assert-BatchSmoke -Condition (@($run.Instances | Where-Object Provider -eq $Provider).Count -eq 1) -Description "Run '$runId' verwendet $Provider"
    }

    & $module {
        param($Root)
        Invoke-SqlServerLabScheduler -UntilIdle -MaxWorkers 2 -StateRoot $Root | Out-Null
    } $stateRoot
    $resumedOperations = @(Get-SqlServerLabOperation -BatchId $batch.batchId -StateRoot $stateRoot)
    Assert-BatchSmoke -Condition ((@($resumedOperations.runId | Sort-Object -Unique) -join ',') -eq (@($runIds | Sort-Object -Unique) -join ',')) -Description 'Erneuter Scheduler-Lauf erzeugte keine doppelten Runs'

    Stop-SqlServerLabBatch -BatchId $batch.batchId -Cleanup -IncludeCompleted -StateRoot $stateRoot -Confirm:$false | Out-Null
    & $module {
        param($Root)
        Invoke-SqlServerLabScheduler -UntilIdle -MaxWorkers 2 -StateRoot $Root | Out-Null
    } $stateRoot
    $operations = @(Get-SqlServerLabOperation -BatchId $batch.batchId -StateRoot $stateRoot)
    Assert-BatchSmoke -Condition (@($operations | Where-Object { $_.cleanupResult.success -and @($_.cleanupResult.remaining).Count -eq 0 }).Count -eq 2) -Description 'Scopegebundener Batch-Cleanup war fuer beide Runs erfolgreich'
    $batch = $null
}
catch {
    $testFailed = $true
    Write-Host "FAIL: $($_.Exception.Message)" -ForegroundColor Red
}
finally {
    $canRemoveStateRoot = $true
    if ($batch -and -not $KeepOnFailure) {
        try {
            Stop-SqlServerLabBatch -BatchId $batch.batchId -Cleanup -IncludeCompleted -StateRoot $stateRoot -Confirm:$false | Out-Null
            $module = Get-Module SqlServerLab
            & $module { param($Root) Invoke-SqlServerLabScheduler -UntilIdle -MaxWorkers 2 -StateRoot $Root | Out-Null } $stateRoot
        }
        catch {
            Write-Host "Batch-Cleanup-Fehler: $($_.Exception.Message)" -ForegroundColor Red
            $testFailed = $true
        }
    }

    if (-not $KeepOnFailure -and $testArtifactDirectory -and (Test-Path -LiteralPath $testArtifactDirectory)) {
        $artifactLink = Get-Item -LiteralPath $testArtifactDirectory -Force
        if (-not ($artifactLink.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            Write-Host "TEMP_ARTIFACT_LINK_NOT_REPARSE_POINT: $testArtifactDirectory" -ForegroundColor Red
            $testFailed = $true
            $canRemoveStateRoot = $false
        }
        else {
            Remove-Item -LiteralPath $testArtifactDirectory -Force
        }
    }
    if (-not $KeepOnFailure -and $canRemoveStateRoot -and (Test-Path -LiteralPath $stateRoot -PathType Container)) {
        Remove-Item -LiteralPath $stateRoot -Recurse -Force
    }
    [Environment]::SetEnvironmentVariable($secretVariable, $previousSecret)
    $env:SQL_SERVER_LAB_STATE = $previousStateRoot
}

if ($testFailed) {
    exit 1
}

Write-Host 'Batch-/Queue-Smoke-Test erfolgreich.' -ForegroundColor Green
exit 0
