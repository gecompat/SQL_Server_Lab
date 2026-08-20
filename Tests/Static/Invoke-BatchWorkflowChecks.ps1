#Requires -Version 7.2
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$modulePath = Join-Path $repoRoot 'SqlServerLab.psd1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('sql-server-lab-batch-checks-' + [Guid]::NewGuid().ToString('n'))

function Assert-Check {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

try {
    Import-Module $modulePath -Force -ErrorAction Stop
    $module = Get-Module SqlServerLab

    $batch = New-SqlServerLabBatch -Name 'Expansion' -StateRoot $testRoot -Items @(
        [pscustomobject]@{ id = 'slot'; kind = 'Test'; count = 3; intent = [pscustomobject]@{ DelayMilliseconds = 150; ResourceClass = 'RuntimeNormal' } }
    )
    Assert-Check ($batch.contract -eq 'SqlServerLab.Batch/1.0') 'Batch-Vertrag fehlt.'
    Assert-Check (@($batch.items).Count -eq 3) 'count=3 wurde nicht in drei Positionen expandiert.'
    Assert-Check ((@($batch.items.itemId) -join ',') -eq 'slot-001,slot-002,slot-003') 'Expandierte ItemIds sind nicht deterministisch.'
    Assert-Check (@($batch.operationIds).Count -eq 3) 'Es wurden nicht drei Kindvorgaenge angelegt.'

    $queue = Get-SqlServerLabQueue -StateRoot $testRoot
    Assert-Check ($queue.maxWorkers -eq 2) 'Scheduler-Default ist nicht zwei Worker.'
    Assert-Check ($queue.length -eq 3) 'Queue enthaelt nicht alle Kindvorgaenge.'

    & $module { param($Root) Invoke-SqlServerLabScheduler -UntilIdle -StateRoot $Root | Out-Null } $testRoot
    $expandedOperations = @(Get-SqlServerLabOperation -BatchId $batch.batchId -StateRoot $testRoot)
    Assert-Check (@($expandedOperations | Where-Object status -eq 'Completed').Count -eq 3) 'Expandierte Vorgaenge wurden nicht abgeschlossen.'

    $mixed = New-SqlServerLabBatch -Name 'Unabhaengige Fehler' -StateRoot $testRoot -Items @(
        [pscustomobject]@{ id = 'ok'; kind = 'Test'; intent = [pscustomobject]@{} }
        [pscustomobject]@{ id = 'fail'; kind = 'Test'; intent = [pscustomobject]@{ Fail = $true; FailureMessage = 'beabsichtigt' } }
        [pscustomobject]@{ id = 'also-ok'; kind = 'Test'; intent = [pscustomobject]@{} }
    )
    & $module { param($Root) Invoke-SqlServerLabScheduler -UntilIdle -StateRoot $Root | Out-Null } $testRoot
    $mixedOperations = @(Get-SqlServerLabOperation -BatchId $mixed.batchId -StateRoot $testRoot)
    Assert-Check (@($mixedOperations | Where-Object status -eq 'Completed').Count -eq 2) 'Ein Fehler hat unabhaengige Positionen gestoppt.'
    Assert-Check (@($mixedOperations | Where-Object status -eq 'Failed').Count -eq 1) 'Fehlerhafte Position wurde nicht isoliert markiert.'
    Assert-Check ((Get-SqlServerLabBatch -BatchId $mixed.batchId -StateRoot $testRoot).status -eq 'CompletedWithErrors') 'Gemischter Batch endet nicht als CompletedWithErrors.'

    $gateBatch = New-SqlServerLabBatch -Name 'User Gate' -StateRoot $testRoot -Items @(
        [pscustomobject]@{
            id = 'manual'; kind = 'Test'
            intent = [pscustomobject]@{
                RequireUserAction = $true
                UserReason = 'Testbenutzeraktion'
                UserInstructions = @('Schritt A ausfuehren.', 'Schritt B pruefen.')
                ExpectedResult = 'Receipt ist bestaetigt.'
            }
        }
    )
    & $module { param($Root) Invoke-SqlServerLabScheduler -UntilIdle -StateRoot $Root | Out-Null } $testRoot
    $gateOperation = Get-SqlServerLabOperation -BatchId $gateBatch.batchId -StateRoot $testRoot | Select-Object -First 1
    Assert-Check ($gateOperation.status -eq 'WaitingForUser') 'User-Gate gibt den Worker nicht als WaitingForUser frei.'
    Assert-Check (@($gateOperation.userGate.instructions).Count -eq 2) 'Vollstaendige User-Schritte wurden nicht persistiert.'
    & $module { param($Id, $Root) Invoke-SqlServerLabOperationProbe -OperationId $Id -StateRoot $Root | Out-Null } $gateOperation.operationId $testRoot
    $gateOperation = Get-SqlServerLabOperation -OperationId $gateOperation.operationId -StateRoot $testRoot
    Assert-Check ($gateOperation.status -eq 'CandidateSatisfied') 'Read-only-Probe markiert den Kandidaten nicht.'
    Assert-Check ($gateOperation.currentStep -eq 1) 'CandidateSatisfied hat den Vorgang ohne Okay fortgesetzt.'
    $confirmation = Confirm-SqlServerLabOperationUserAction -OperationId $gateOperation.operationId -StateRoot $testRoot
    Assert-Check ($confirmation.success) 'User-Gate-Bestaetigung wurde nicht akzeptiert.'
    Assert-Check ((Get-SqlServerLabOperation -OperationId $gateOperation.operationId -StateRoot $testRoot).status -eq 'Completed') 'Bestaetigtes Gate wurde nicht abgeschlossen.'

    $control = New-SqlServerLabBatch -Name 'Queue Steuerung' -StateRoot $testRoot -Items @(
        [pscustomobject]@{ id = 'first'; kind = 'Test'; intent = [pscustomobject]@{} }
        [pscustomobject]@{ id = 'second'; kind = 'Test'; intent = [pscustomobject]@{} }
    )
    $controlOperations = @(Get-SqlServerLabOperation -BatchId $control.batchId -StateRoot $testRoot)
    Suspend-SqlServerLabOperation -OperationId $controlOperations[0].operationId -StateRoot $testRoot | Out-Null
    Assert-Check ((Get-SqlServerLabOperation -OperationId $controlOperations[0].operationId -StateRoot $testRoot).status -eq 'Paused') 'Pause wurde nicht persistiert.'
    Resume-SqlServerLabOperation -OperationId $controlOperations[0].operationId -StateRoot $testRoot | Out-Null
    Set-SqlServerLabOperationPriority -OperationId $controlOperations[1].operationId -Priority High -StateRoot $testRoot | Out-Null
    Assert-Check ((Get-SqlServerLabOperation -OperationId $controlOperations[1].operationId -StateRoot $testRoot).priority -eq 'High') 'Individuelle Prioritaet wurde nicht persistiert.'
    & $module { param($Id, $Root) Set-SqlServerLabBatchPriority -BatchId $Id -Priority Low -StateRoot $Root | Out-Null } $control.batchId $testRoot
    Assert-Check ((Get-SqlServerLabOperation -OperationId $controlOperations[0].operationId -StateRoot $testRoot).priority -eq 'Low') 'Batch-Prioritaet wurde nicht weitergegeben.'
    Assert-Check ((Get-SqlServerLabOperation -OperationId $controlOperations[1].operationId -StateRoot $testRoot).priority -eq 'High') 'Individuell ueberschriebene Prioritaet wurde unzulaessig ersetzt.'

    $abandoned = Get-SqlServerLabOperation -OperationId $controlOperations[0].operationId -StateRoot $testRoot
    $abandoned.status = 'Running'
    $abandoned.worker = [pscustomobject]@{ host = [Environment]::MachineName; processId = 2147483000; heartbeatAt = [DateTime]::UtcNow.AddMinutes(-1).ToString('o') }
    & $module { param($Operation, $Root) Write-LabOperationState -Operation $Operation -StateRoot $Root | Out-Null } $abandoned $testRoot
    & $module { param($Root) Invoke-SqlServerLabScheduler -UntilIdle -StateRoot $Root | Out-Null } $testRoot
    Assert-Check ((Get-SqlServerLabOperation -OperationId $abandoned.operationId -StateRoot $testRoot).status -eq 'Completed') 'Verlassener Worker wurde nicht am persistenten Schritt fortgesetzt.'

    $heavy = New-SqlServerLabBatch -Name 'Heavy Limit' -StateRoot $testRoot -Items @(
        [pscustomobject]@{ id = 'heavy-a'; kind = 'Test'; intent = [pscustomobject]@{ ResourceClass = 'HyperVHeavy'; DelayMilliseconds = 80 } }
        [pscustomobject]@{ id = 'heavy-b'; kind = 'Test'; intent = [pscustomobject]@{ ResourceClass = 'HyperVHeavy'; DelayMilliseconds = 80 } }
    )
    & $module { param($Root) Invoke-SqlServerLabScheduler -UntilIdle -StateRoot $Root | Out-Null } $testRoot
    $heavyOperations = @(Get-SqlServerLabOperation -BatchId $heavy.batchId -StateRoot $testRoot | Sort-Object startedAt)
    Assert-Check (@($heavyOperations | Where-Object status -eq 'Completed').Count -eq 2) 'HyperVHeavy-Vorgaenge wurden nicht abgeschlossen.'
    Assert-Check (([DateTime]$heavyOperations[1].startedAt) -ge ([DateTime]$heavyOperations[0].completedAt)) 'Mehr als ein HyperVHeavy-Vorgang lief gleichzeitig.'

    $availability = & $module {
        $original = ${function:Test-ProviderAvailability}
        try {
            function Test-ProviderAvailability {
                param([string]$Provider)
                [pscustomobject]@{ Status = if ($Provider -eq 'docker') { 'RESOURCE_OK' } else { 'RESOURCE_HARD_BLOCK' } }
            }
            Get-LabProviderAvailabilityMap
        }
        finally {
            Set-Item -Path function:Test-ProviderAvailability -Value $original
        }
    }
    Assert-Check ($availability.docker -and -not $availability.podman) 'Resource-Assessment-Status wird nicht korrekt in Batch-Providerverfuegbarkeit uebersetzt.'

    $schemaPath = Join-Path $repoRoot 'Schemas\lab-batch.schema.json'
    Assert-Check (Test-Path -LiteralPath $schemaPath -PathType Leaf) 'Batch-Manifest-Schema fehlt.'
    $schema = Get-Content -LiteralPath $schemaPath -Raw -Encoding utf8 | ConvertFrom-Json
    Assert-Check ($schema.title -eq 'SqlServerLab.BatchManifest/1.0') 'Batch-Manifest-Schema hat den falschen Vertrag.'

    $batchRuntimeSource = Get-Content -LiteralPath (Join-Path $repoRoot 'Private\BatchWorkflow.ps1') -Raw -Encoding utf8
    Assert-Check ($batchRuntimeSource -match [regex]::Escape("-Name 'Profile' -Default 'compact'")) 'Container-Batches verwenden kein gueltiges Standardprofil.'
    Assert-Check ($batchRuntimeSource -match [regex]::Escape("if (`$autoStartValue) { 'on' } else { 'off' }")) 'Container-Batches normalisieren boolesches AutoStart nicht auf den oeffentlichen on/off-Vertrag.'
    Assert-Check ($batchRuntimeSource -match [regex]::Escape('BATCH_SA_PASSWORD_ENVIRONMENT_VARIABLE_REQUIRED')) 'Container-Batches brechen ohne Secret-Referenz nicht eindeutig ab.'
    Assert-Check ($batchRuntimeSource -match [regex]::Escape("Get-LabManifestEnvironmentSecret -Name `$saPasswordEnvironmentVariable")) 'Container-Batches loesen die eng benannte Secret-Referenz nicht erst im Worker auf.'

    $batchSmokePath = Join-Path $repoRoot 'Tests\Integration\Invoke-BatchWorkflowSmokeTest.ps1'
    Assert-Check (Test-Path -LiteralPath $batchSmokePath -PathType Leaf) 'Realer Batch-/Queue-Runtime-Smoke fehlt.'
    $batchSmokeSource = Get-Content -LiteralPath $batchSmokePath -Raw -Encoding utf8
    Assert-Check ($batchSmokeSource -match [regex]::Escape("[ValidateSet('docker', 'podman', 'hyperv')]")) 'Batch-Smoke deckt nicht alle drei Provider ab.'
    Assert-Check ($batchSmokeSource -match [regex]::Escape('New-Item -ItemType Junction') -and
        $batchSmokeSource -match [regex]::Escape('TEMP_ARTIFACT_LINK_NOT_REPARSE_POINT') -and
        $batchSmokeSource -notmatch [regex]::Escape('New-Item -ItemType HardLink')) 'Hyper-V-Smoke bindet das immutable Parent nicht ueber eine sicher gepruefte Junction ein.'

    Write-Host 'BATCH-/QUEUE-/RESUME-VERTRAGSPRUEFUNGEN: PASS' -ForegroundColor Green
}
finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
