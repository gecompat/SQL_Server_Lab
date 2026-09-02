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
.PARAMETER AbortSchedulerOnce
    Beendet den ersten Scheduler-Prozess hart, sobald eine echte Providerressource
    des Batch sichtbar ist, und prueft danach Recovery und idempotentes Resume.
.PARAMETER ManifestRerun
    Erstellt den Batch aus einem temporaeren Manifest, prueft die deduplizierte
    offene Einreichung und fuehrt das abgeschlossene Manifest nach Cleanup erneut aus.
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

    [switch]$AbortSchedulerOnce,

    [switch]$ManifestRerun,

    [switch]$KeepOnFailure
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$modulePath = Join-Path $repoRoot 'SqlServerLab.psd1'
$hostToolInitializer = Join-Path $repoRoot 'Tools\Initialize-SqlServerLabHostTools.ps1'
$stateRoot = Join-Path ([IO.Path]::GetTempPath()) ('sql-server-lab-batch-smoke-' + [Guid]::NewGuid().ToString('N'))
$secretVariable = 'SQL_SERVER_LAB_SECRET_BATCH_SMOKE_SA_PASSWORD'
$previousSecret = [Environment]::GetEnvironmentVariable($secretVariable)
$previousStateRoot = $env:SQL_SERVER_LAB_STATE
$batch = $null
$operations = @()
$testFailed = $false
$testArtifactDirectory = $null
$schedulerProcess = $null
$abortedOwnedRunId = $null
$interruptedOperationIds = @()
$manifestPath = $null

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

    $resolution = @(& $hostToolInitializer -Name $Name)[0]
    if (-not $resolution.Available -or
        [string]::IsNullOrWhiteSpace([string]$resolution.Invocation)) {
        return $false
    }
    & ([string]$resolution.Invocation) info 1>$null 2>$null
    return $LASTEXITCODE -eq 0
}

function Get-BatchOwnedRunState {
    param(
        [Parameter(Mandatory)][string[]]$OperationId,
        [switch]$IncludeTerminal
    )

    $runsRoot = Join-Path $stateRoot 'runs'
    if (-not (Test-Path -LiteralPath $runsRoot -PathType Container)) {
        return @()
    }
    return @(
        Get-ChildItem -LiteralPath $runsRoot -Directory -ErrorAction SilentlyContinue |
            ForEach-Object {
                $statePath = Join-Path $_.FullName 'run-state.json'
                if (Test-Path -LiteralPath $statePath -PathType Leaf) {
                    Get-Content -LiteralPath $statePath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 20
                }
            } |
            Where-Object {
                [string]$_.metadata.workflowOperationId -in $OperationId -and
                ($IncludeTerminal -or [string]$_.state -notin @('CLEANED_UP', 'REMOVED'))
            }
    )
}

function Get-BatchProviderResourceId {
    param(
        [Parameter(Mandatory)][string]$RuntimeProvider,
        [Parameter(Mandatory)][string]$RunId
    )

    if ($RuntimeProvider -in @('docker', 'podman')) {
        $resourceIds = @(& $RuntimeProvider ps -a --filter "label=sql-server-lab.run-id=$RunId" --format '{{.ID}}' 2>$null)
        if ($LASTEXITCODE -ne 0) { return @() }
        return @($resourceIds | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
    }

    if ($RuntimeProvider -eq 'hyperv') {
        return @(
            Get-VM -ErrorAction Stop |
                Where-Object { [string]$_.Notes -match [regex]::Escape(('"runId":"' + $RunId + '"')) } |
                ForEach-Object { [string]$_.VMId }
        )
    }
    return @()
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

    $batchItems = @(
        [pscustomobject]@{
            id = 'sql-runtime'
            kind = $kind
            count = 2
            intent = [pscustomobject]@{ LabName = "batch-smoke-$Provider" }
        }
    )
    if ($ManifestRerun) {
        $manifestPath = Join-Path $stateRoot 'batch-smoke.manifest.json'
        [pscustomobject][ordered]@{
            contract = 'SqlServerLab.BatchManifest/1.0'
            name = "Batch manifest smoke $Provider"
            priority = 'Normal'
            defaults = $defaults
            items = $batchItems
        } | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $manifestPath -Encoding utf8
        $batch = New-SqlServerLabBatch -Manifest $manifestPath -StateRoot $stateRoot
        $sameOpenBatch = New-SqlServerLabBatch -Manifest $manifestPath -StateRoot $stateRoot
        Assert-BatchSmoke -Condition ($sameOpenBatch.batchId -eq $batch.batchId) -Description 'Erneute offene Manifest-Einreichung verwendete denselben Batch'
        Assert-BatchSmoke -Condition ((@($sameOpenBatch.operationIds) -join ',') -eq (@($batch.operationIds) -join ',')) -Description 'Erneute offene Manifest-Einreichung erzeugte keine doppelten Operationen'
    }
    else {
        $batch = New-SqlServerLabBatch -Name "Batch smoke $Provider" -StateRoot $stateRoot -Defaults $defaults -Items $batchItems
    }

    Assert-BatchSmoke -Condition ($batch.status -eq 'Queued') -Description 'Batch wurde atomar eingereiht'
    Assert-BatchSmoke -Condition (@($batch.operationIds).Count -eq 2) -Description 'count=2 erzeugte zwei persistente Operationen'

    if ($AbortSchedulerOnce) {
        $moduleLiteral = $modulePath.Replace("'", "''")
        $stateRootLiteral = $stateRoot.Replace("'", "''")
        $schedulerCommand = "Import-Module '$moduleLiteral' -Force; Invoke-SqlServerLabScheduler -UntilIdle -MaxWorkers 2 -StateRoot '$stateRootLiteral' | Out-Null"
        $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($schedulerCommand))
        $schedulerProcessParameters = @{
            FilePath = (Get-Process -Id $PID).Path
            ArgumentList = @('-NoLogo', '-NoProfile', '-EncodedCommand', $encodedCommand)
            PassThru = $true
        }
        if ($IsWindows) { $schedulerProcessParameters['WindowStyle'] = 'Hidden' }
        $schedulerProcess = Start-Process @schedulerProcessParameters

        $deadline = [DateTime]::UtcNow.AddMinutes(4)
        $abortOperation = $null
        while ([DateTime]::UtcNow -lt $deadline -and -not $schedulerProcess.HasExited) {
            $candidateOperations = @(Get-SqlServerLabOperation -BatchId $batch.batchId -StateRoot $stateRoot)
            $runningOperation = @($candidateOperations | Where-Object status -eq 'Running' | Select-Object -First 1)
            if ($runningOperation.Count -eq 1) {
                $ownedRuns = @(Get-BatchOwnedRunState -OperationId @([string]$runningOperation[0].operationId))
                foreach ($ownedRun in $ownedRuns) {
                    $resourceIds = @(Get-BatchProviderResourceId -RuntimeProvider $Provider -RunId ([string]$ownedRun.runId))
                    if ($resourceIds.Count -gt 0) {
                        $abortOperation = $runningOperation[0]
                        $abortedOwnedRunId = [string]$ownedRun.runId
                        break
                    }
                }
            }
            if ($null -ne $abortOperation) { break }
            Start-Sleep -Milliseconds 200
            $schedulerProcess.Refresh()
        }
        Assert-BatchSmoke -Condition ($null -ne $abortOperation) -Description 'Scheduler-Abbruchpunkt mit echter Providerressource wurde erreicht'
        Stop-Process -Id $schedulerProcess.Id -Force -ErrorAction Stop
        Wait-Process -Id $schedulerProcess.Id -Timeout 30 -ErrorAction SilentlyContinue
        $schedulerProcess.Refresh()
        Assert-BatchSmoke -Condition $schedulerProcess.HasExited -Description 'Separater Scheduler-Prozess wurde waehrend einer realen Provideroperation beendet'

        $interruptedOperations = @(
            Get-SqlServerLabOperation -BatchId $batch.batchId -StateRoot $stateRoot |
                Where-Object { $_.status -eq 'Running' -and [int]$_.worker.processId -eq $schedulerProcess.Id }
        )
        $interruptedOperationIds = @($interruptedOperations.operationId)
        Assert-BatchSmoke -Condition ($interruptedOperationIds.Count -gt 0 -and $abortOperation.operationId -in $interruptedOperationIds) -Description 'Alle vom abgebrochenen Prozess beanspruchten Worker blieben fuer die deterministische Recovery persistent erkennbar'

        & $module {
            param($Root)
            Invoke-SqlServerLabScheduler -UntilIdle -MaxWorkers 2 -StateRoot $Root | Out-Null
        } $stateRoot
    }
    else {
        & $module {
            param($Root)
            Invoke-SqlServerLabScheduler -UntilIdle -MaxWorkers 2 -StateRoot $Root | Out-Null
        } $stateRoot
    }

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
    if ($AbortSchedulerOnce) {
        $recoveredOperationIds = @(
            $operations |
                Where-Object { @($_.events | Where-Object type -eq 'WorkerRecovered').Count -gt 0 } |
                ForEach-Object operationId |
                Sort-Object
        )
        Assert-BatchSmoke -Condition (($recoveredOperationIds -join ',') -eq (@($interruptedOperationIds | Sort-Object) -join ',')) -Description 'Jede vom Prozessabbruch betroffene Operation besitzt genau den erwarteten WorkerRecovered-Nachweis'
        $allOwnedRuns = @(Get-BatchOwnedRunState -OperationId @($batch.operationIds) -IncludeTerminal)
        $activeOwnedRuns = @($allOwnedRuns | Where-Object state -notin @('CLEANED_UP', 'REMOVED'))
        Assert-BatchSmoke -Condition ($activeOwnedRuns.Count -eq 2) -Description 'Resume hinterliess genau einen aktiven Operation-Run je Batchposition'
        Assert-BatchSmoke -Condition (@($activeOwnedRuns.metadata.workflowOperationId | Sort-Object -Unique).Count -eq 2) -Description 'Operation-zu-Run-Eigentum blieb nach Recovery eindeutig'
        $abortedRunState = @($allOwnedRuns | Where-Object runId -eq $abortedOwnedRunId | Select-Object -First 1)
        Assert-BatchSmoke -Condition ($abortedRunState.Count -eq 1 -and [string]$abortedRunState[0].state -in @('RUNNING', 'STOPPED', 'REMOVED')) -Description 'Der beim Abbruch sichtbare Run wurde uebernommen oder scopegebunden finalisiert'
    }

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

    if ($ManifestRerun) {
        $firstBatchId = [string]$batch.batchId
        $firstOperationIds = @($batch.operationIds)
        $batch = New-SqlServerLabBatch -Manifest $manifestPath -StateRoot $stateRoot
        Assert-BatchSmoke -Condition ($batch.batchId -ne $firstBatchId) -Description 'Abgeschlossenes und bereinigtes Manifest erzeugte einen neuen Batch'
        $sameRerunBatch = New-SqlServerLabBatch -Manifest $manifestPath -StateRoot $stateRoot
        Assert-BatchSmoke -Condition ($sameRerunBatch.batchId -eq $batch.batchId) -Description 'Offene Manifest-Wiederholung blieb auch im zweiten Lauf dedupliziert'

        & $module {
            param($Root)
            Invoke-SqlServerLabScheduler -UntilIdle -MaxWorkers 2 -StateRoot $Root | Out-Null
        } $stateRoot
        $rerunBatch = Get-SqlServerLabBatch -BatchId $batch.batchId -StateRoot $stateRoot
        $rerunOperations = @(Get-SqlServerLabOperation -BatchId $batch.batchId -StateRoot $stateRoot)
        Assert-BatchSmoke -Condition ($rerunBatch.status -eq 'Completed' -and @($rerunOperations | Where-Object status -eq 'Completed').Count -eq 2) -Description 'Manifest-Rerun wurde mit beiden Operationen abgeschlossen'
        $rerunIds = @($rerunOperations.runId)
        Assert-BatchSmoke -Condition (@($rerunIds | Where-Object { $_ -in $runIds }).Count -eq 0) -Description 'Manifest-Rerun erhielt neue RunIds statt alte Ressourcen zu uebernehmen'
        Assert-BatchSmoke -Condition (@(Get-BatchOwnedRunState -OperationId $firstOperationIds).Count -eq 0) -Description 'Erster Manifest-Lauf hinterliess nach Cleanup keine aktiven operationseigenen Runs'
        Assert-BatchSmoke -Condition (@(Get-BatchOwnedRunState -OperationId @($batch.operationIds)).Count -eq 2) -Description 'Manifest-Rerun besitzt genau einen aktiven Run je Position'

        & $module {
            param($Root)
            Invoke-SqlServerLabScheduler -UntilIdle -MaxWorkers 2 -StateRoot $Root | Out-Null
        } $stateRoot
        $rerunAfterResume = @(Get-SqlServerLabOperation -BatchId $batch.batchId -StateRoot $stateRoot)
        Assert-BatchSmoke -Condition ((@($rerunAfterResume.runId | Sort-Object -Unique) -join ',') -eq (@($rerunIds | Sort-Object -Unique) -join ',')) -Description 'Manifest-Rerun blieb bei erneutem Scheduler-Aufruf idempotent'

        Stop-SqlServerLabBatch -BatchId $batch.batchId -Cleanup -IncludeCompleted -StateRoot $stateRoot -Confirm:$false | Out-Null
        & $module {
            param($Root)
            Invoke-SqlServerLabScheduler -UntilIdle -MaxWorkers 2 -StateRoot $Root | Out-Null
        } $stateRoot
        $rerunOperations = @(Get-SqlServerLabOperation -BatchId $batch.batchId -StateRoot $stateRoot)
        Assert-BatchSmoke -Condition (@($rerunOperations | Where-Object { $_.cleanupResult.success -and @($_.cleanupResult.remaining).Count -eq 0 }).Count -eq 2) -Description 'Manifest-Rerun wurde vollstaendig scopegebunden bereinigt'
    }
    $batch = $null
}
catch {
    $testFailed = $true
    Write-Host "FAIL: $($_.Exception.Message)" -ForegroundColor Red
}
finally {
    if ($schedulerProcess) {
        $schedulerProcess.Refresh()
        if (-not $schedulerProcess.HasExited) {
            Stop-Process -Id $schedulerProcess.Id -Force -ErrorAction SilentlyContinue
            Wait-Process -Id $schedulerProcess.Id -Timeout 30 -ErrorAction SilentlyContinue
        }
    }
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
