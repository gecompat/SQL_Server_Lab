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

    # Expansion und Reihenfolge sind hier der Vertrag. Die reale Zwei-Worker-
    # Parallelitaet wird im Batch-Smoke belegt; ein einzelner Worker verhindert,
    # dass ThreadJob-Startlatenz diesen statischen Vertragstest flakey macht.
    & $module { param($Root) Invoke-SqlServerLabScheduler -UntilIdle -MaxWorkers 1 -StateRoot $Root | Out-Null } $testRoot
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

    $persistedVmProbe = & $module {
        param($Root)
        $originalStatus = Get-Item Function:Get-HyperVInstanceStatus
        try {
            function Get-HyperVInstanceStatus {
                param($VMName, $ExpectedRunId)
                if ($VMName -ne 'persisted-user-gate-vm' -or $ExpectedRunId -ne 'persisted-user-gate-run') {
                    throw 'PERSISTED_USER_GATE_BINDING_INVALID'
                }
                [pscustomobject]@{ Exists=$true; State='Running'; VMName=$VMName; RunId=$ExpectedRunId }
            }
            $operation = [pscustomobject]@{
                operationId = 'persisted-user-gate-operation'
                runId = 'persisted-user-gate-run'
                userGate = [pscustomobject]@{
                    verification = [pscustomobject]@{
                        type = 'HyperVWindowsSetup'
                        data = [pscustomobject]@{ runId='persisted-user-gate-run'; vmName='persisted-user-gate-vm' }
                    }
                }
            }
            Test-LabOperationUserGateVerification -Operation $operation -StateRoot $Root -ProbeOnly
        }
        finally {
            Set-Item Function:Get-HyperVInstanceStatus -Value $originalStatus
        }
    } $testRoot
    Assert-Check (-not $persistedVmProbe.success -and $persistedVmProbe.candidate -and $persistedVmProbe.result.VMName -eq 'persisted-user-gate-vm') 'Windows-Probe verwendet den persistenten Gate-VM-Namen nicht als read-only Kandidatenbindung.'

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

    $operationContext = & $module {
        Invoke-WithLabWorkflowOperationContext -OperationId 'op-context-check' -ScriptBlock {
            Get-LabWorkflowOperationContext
        }
    }
    Assert-Check ($operationContext -eq 'op-context-check') 'Operation-zu-Run-Kontext wird nicht runspacegebunden weitergegeben.'
    Assert-Check ($null -eq (& $module { Get-LabWorkflowOperationContext })) 'Operation-zu-Run-Kontext bleibt nach der Ausführung im Modul erhalten.'

    $readyRecovery = & $module {
        param($Root)
        $operationId = 'op-owned-ready'
        $run = New-LabRunState -StateRoot $Root -Metadata @{ name = 'Owned ready'; workflowOperationId = $operationId } `
            -ProviderSubRuns @([pscustomobject]@{ id = 'provider-docker'; provider = 'docker'; instanceIds = @('primary') })
        $null = Set-LabRunState -RunId $run.RunId -NewState 'PROVISIONING' -Reason 'Test' -StateRoot $Root
        $null = Set-LabRunState -RunId $run.RunId -NewState 'SQL_READY' -Reason 'Test' -StateRoot $Root
        $null = Set-LabRunState -RunId $run.RunId -NewState 'DATABASES_CREATED' -Reason 'Test' -StateRoot $Root
        $null = Set-LabRunState -RunId $run.RunId -NewState 'RUNNING' -Reason 'Test' -StateRoot $Root
        Write-LabArtifactJsonAtomic -Path (Join-Path $run.RunDir 'connection-info.json') -InputObject ([pscustomobject]@{
            schemaVersion = 1
            instances = @([pscustomobject]@{ id = 'primary'; provider = 'docker'; containerName = 'synthetic-only' })
        })
        Resolve-LabOperationOwnedRun -Operation ([pscustomobject]@{ operationId = $operationId; provider = 'docker' }) -StateRoot $Root
    } $testRoot
    Assert-Check ($readyRecovery.action -eq 'Reuse' -and -not [string]::IsNullOrWhiteSpace([string]$readyRecovery.runId)) 'Fertig persistierter Operation-Run wird nach Workerabbruch nicht übernommen.'

    $emptyRecovery = & $module {
        param($Root)
        $operationId = 'op-owned-empty'
        $run = New-LabRunState -StateRoot $Root -Metadata @{ name = 'Owned empty'; workflowOperationId = $operationId } `
            -ProviderSubRuns @([pscustomobject]@{ id = 'provider-docker'; provider = 'docker'; instanceIds = @('primary') })
        $resolution = Resolve-LabOperationOwnedRun -Operation ([pscustomobject]@{ operationId = $operationId; provider = 'docker' }) -StateRoot $Root
        [pscustomobject]@{ resolution = $resolution; state = Get-LabRunState -RunId $run.RunId -StateRoot $Root }
    } $testRoot
    Assert-Check ($emptyRecovery.resolution.action -eq 'Cleaned' -and $emptyRecovery.state.state -eq 'REMOVED') 'Leere Operation-Run-Reservierung wird nicht sicher finalisiert.'

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

    $preflightSecret = 'SQL_SERVER_LAB_SECRET_BATCH_PREFLIGHT_CHECK'
    [Environment]::SetEnvironmentVariable($preflightSecret, $null, 'Process')
    $containerBatch = New-SqlServerLabBatch -Name 'Preflight' -StateRoot $testRoot -Queue:$false -Items @(
        [pscustomobject]@{ id = 'sql-a'; kind = 'SqlEnvironment'; provider = 'podman'; overrides = [pscustomobject]@{ LabName = 'preflight-a'; Version = '2022' } }
    )
    $submitRejected = $false
    $submitRejectionMessage = ''
    try { $null = & $module { param($Id, $Root) Submit-SqlServerLabBatch -BatchId $Id -StateRoot $Root } $containerBatch.batchId $testRoot }
    catch { $submitRejected = $true; $submitRejectionMessage = [string]$_.Exception.Message }
    $storedBatch = & $module { param($Id, $Root) Read-LabWorkflowJson -Path (Get-LabBatchStatePath -BatchId $Id -StateRoot $Root) } $containerBatch.batchId $testRoot
    Assert-Check ($submitRejected -and $submitRejectionMessage -match 'BATCH_SA_PASSWORD_ENVIRONMENT_VARIABLE_REQUIRED') 'Container-Batch wird ohne Secret-Referenz eingereiht statt im Preflight abgelehnt.'
    Assert-Check ($submitRejectionMessage -match 'sql-a') 'Die Preflight-Ablehnung benennt die betroffene Position nicht.'
    Assert-Check ($storedBatch.status -in @('Draft', 'Validated')) 'Ein abgelehnter Submit veraendert den Batchstatus.'

    $blockedQueue = Get-SqlServerLabQueue -StateRoot $testRoot
    $blockedRow = @($blockedQueue.items | Where-Object batchId -eq $containerBatch.batchId)[0]
    Assert-Check ($null -ne $blockedRow -and $blockedRow.batchStatus -in @('Draft', 'Validated')) 'Die Queue weist den Batchstatus einer Position nicht aus.'
    Assert-Check ($blockedRow.blockedReason -match 'noch nicht uebergeben') 'Ein nicht uebergebener Batch nennt in der Queue keinen Blockierungsgrund.'
    Assert-Check (-not $blockedRow.startable) 'Ein nicht uebergebener Vorgang wird faelschlich als startbereit ausgewiesen.'

    $missingReferenceRejected = $false
    & $module {
        param($Id, $Root, $Name)
        $operation = Read-LabWorkflowJson -Path (Get-LabOperationStatePath -OperationId $Id -StateRoot $Root)
        $operation.executor.effective | Add-Member -NotePropertyName 'SaPasswordEnvironmentVariable' -NotePropertyValue $Name -Force
        Write-LabOperationState -Operation $operation -StateRoot $Root | Out-Null
    } (@($containerBatch.operationIds)[0]) $testRoot $preflightSecret
    try { $null = & $module { param($Id, $Root) Submit-SqlServerLabBatch -BatchId $Id -StateRoot $Root } $containerBatch.batchId $testRoot }
    catch { $missingReferenceRejected = [string]$_.Exception.Message -match 'BATCH_SA_PASSWORD_ENVIRONMENT_VARIABLE_MISSING' }
    Assert-Check $missingReferenceRejected 'Eine Referenz auf eine nicht gesetzte Prozessvariable wird nicht als eigener Fehlerfall erkannt.'

    [Environment]::SetEnvironmentVariable($preflightSecret, 'Str3ng-Test-Kennwort!', 'Process')
    try {
        $submittedBatch = & $module { param($Id, $Root) Submit-SqlServerLabBatch -BatchId $Id -StateRoot $Root } $containerBatch.batchId $testRoot
        Assert-Check ($submittedBatch.status -eq 'Queued') 'Ein vollstaendig referenzierter Container-Batch wird nicht eingereiht.'
        $releasedRow = @((Get-SqlServerLabQueue -StateRoot $testRoot).items | Where-Object batchId -eq $containerBatch.batchId)[0]
        Assert-Check ([string]::IsNullOrEmpty([string]$releasedRow.blockedReason)) 'Nach dem Einreihen bleibt der Blockierungsgrund stehen.'
    }
    finally { [Environment]::SetEnvironmentVariable($preflightSecret, $null, 'Process') }

    $queueConsoleSource = Get-Content -LiteralPath (Join-Path $repoRoot 'Public\BatchConsole.ps1') -Raw -Encoding utf8
    Assert-Check ($queueConsoleSource -notmatch [regex]::Escape('Invoke-SqlServerLabScheduler -UntilIdle | Out-Null')) 'Der Scheduler-Menuepunkt verwirft sein Ergebnis weiterhin.'
    Assert-Check ($queueConsoleSource -match [regex]::Escape('$started = @(Invoke-SqlServerLabScheduler -UntilIdle)') -and
        $queueConsoleSource -match 'Kein Vorgang wurde gestartet' -and
        $queueConsoleSource -match [regex]::Escape('$item.blockedReason')) 'Der Scheduler-Menuepunkt nennt bei leerem Ergebnis keinen Grund.'

    Assert-Check ((& $module { Get-LabBatchSecretVariableName -ItemName 'SQL2025 latest' }) -eq 'SQL_SERVER_LAB_SECRET_SQL2025_LATEST') 'Der Variablenname wird nicht eng benannt aus dem Positionsnamen abgeleitet.'
    Assert-Check ((& $module { Get-LabBatchSecretVariableName -ItemName '--x--' }) -eq 'SQL_SERVER_LAB_SECRET_X') 'Sonderzeichen werden beim Variablennamen nicht normalisiert.'
    Assert-Check ((& $module { Get-LabBatchSecretVariableName -ItemName '' }) -eq 'SQL_SERVER_LAB_SECRET_BATCH') 'Ein leerer Positionsname erzeugt keinen gueltigen Variablennamen.'
    Assert-Check ((& $module { Get-LabBatchSecretVariableName -ItemName 'a b' }) -match '^SQL_SERVER_LAB_SECRET_[A-Z0-9_]+$') 'Der abgeleitete Name erfuellt das Secret-Namensmuster nicht.'

    $secretListing = & $module {
        [Environment]::SetEnvironmentVariable('SQL_SERVER_LAB_SECRET_COMPOSER_SET', 'wert', 'Process')
        [Environment]::SetEnvironmentVariable('SQL_SERVER_LAB_SECRET_COMPOSER_EMPTY', '', 'Process')
        try { @(Get-LabAvailableSecretVariableName) }
        finally {
            [Environment]::SetEnvironmentVariable('SQL_SERVER_LAB_SECRET_COMPOSER_SET', $null, 'Process')
            [Environment]::SetEnvironmentVariable('SQL_SERVER_LAB_SECRET_COMPOSER_EMPTY', $null, 'Process')
        }
    }
    Assert-Check ($secretListing -contains 'SQL_SERVER_LAB_SECRET_COMPOSER_SET') 'Gesetzte Secret-Variablen werden im Composer nicht angeboten.'
    Assert-Check (-not ($secretListing -contains 'SQL_SERVER_LAB_SECRET_COMPOSER_EMPTY')) 'Eine leere Secret-Variable wird faelschlich als verwendbar angeboten.'

    Assert-Check ($queueConsoleSource -match [regex]::Escape("ScreenId 'batch-sa-secret'")) 'Der Composer bietet keinen Bildschirm zur Secret-Referenz an.'
    Assert-Check ($queueConsoleSource -match [regex]::Escape("`$table['SaPasswordEnvironmentVariable'] = `$secretVariable")) 'Die Containerposition uebernimmt die gewaehlte Secret-Referenz nicht.'
    Assert-Check ($queueConsoleSource -match [regex]::Escape("`$matrixIntent['SaPasswordEnvironmentVariable'] = `$matrixSecretVariable")) 'Der Matrixpfad bindet keine Secret-Referenz.'
    Assert-Check ($queueConsoleSource -notmatch 'SaPassword\s*=\s*\$plain' -and
        $queueConsoleSource -match [regex]::Escape('[Runtime.InteropServices.Marshal]::ZeroFreeBSTR')) 'Das Kennwort wird nicht kontrolliert wieder freigegeben.'
    Assert-Check ($queueConsoleSource -match [regex]::Escape("SetEnvironmentVariable(`$VariableName, `$plain, 'Process')")) 'Das Kennwort wird nicht ausschliesslich als Prozessvariable gehalten.'
    Assert-Check ($queueConsoleSource -notmatch [regex]::Escape("SetEnvironmentVariable(`$VariableName, `$plain, 'User')") -and
        $queueConsoleSource -notmatch [regex]::Escape("SetEnvironmentVariable(`$VariableName, `$plain, 'Machine')")) 'Das Kennwort wird dauerhaft persistiert.'

    $schemaPath = Join-Path $repoRoot 'Schemas\lab-batch.schema.json'
    Assert-Check (Test-Path -LiteralPath $schemaPath -PathType Leaf) 'Batch-Manifest-Schema fehlt.'
    $schema = Get-Content -LiteralPath $schemaPath -Raw -Encoding utf8 | ConvertFrom-Json
    Assert-Check ($schema.title -eq 'SqlServerLab.BatchManifest/1.0') 'Batch-Manifest-Schema hat den falschen Vertrag.'

    $batchRuntimeSource = Get-Content -LiteralPath (Join-Path $repoRoot 'Private\BatchWorkflow.ps1') -Raw -Encoding utf8
    Assert-Check ($batchRuntimeSource -match [regex]::Escape("-Name 'Profile' -Default 'compact'")) 'Container-Batches verwenden kein gueltiges Standardprofil.'
    Assert-Check ($batchRuntimeSource -match [regex]::Escape("if (`$autoStartValue) { 'on' } else { 'off' }")) 'Container-Batches normalisieren boolesches AutoStart nicht auf den oeffentlichen on/off-Vertrag.'
    Assert-Check ($batchRuntimeSource -match [regex]::Escape('BATCH_SA_PASSWORD_ENVIRONMENT_VARIABLE_REQUIRED')) 'Container-Batches brechen ohne Secret-Referenz nicht eindeutig ab.'
    Assert-Check ($batchRuntimeSource -match [regex]::Escape("Get-LabManifestEnvironmentSecret -Name `$saPasswordEnvironmentVariable")) 'Container-Batches loesen die eng benannte Secret-Referenz nicht erst im Worker auf.'
    Assert-Check ($batchRuntimeSource -match [regex]::Escape('function Get-LabRunHyperVVmName') -and
        $batchRuntimeSource -match [regex]::Escape("Get-LabWorkflowValue -InputObject `$verification.data -Name 'vmName' -Default ''") -and
        $batchRuntimeSource -match [regex]::Escape("Add-Member -NotePropertyName 'vmName' -NotePropertyValue `$resolvedVmName -Force") -and
        $batchRuntimeSource -match [regex]::Escape('Das persistente Windows-User-Gate enthaelt keinen pruefbaren VM-Namen.')) 'Windows-User-Gate-Probes verwenden den persistenten VM-Namen nicht fail-closed.'

    $batchSmokePath = Join-Path $repoRoot 'Tests\Integration\Invoke-BatchWorkflowSmokeTest.ps1'
    Assert-Check (Test-Path -LiteralPath $batchSmokePath -PathType Leaf) 'Realer Batch-/Queue-Runtime-Smoke fehlt.'
    $batchSmokeSource = Get-Content -LiteralPath $batchSmokePath -Raw -Encoding utf8
    Assert-Check ($batchSmokeSource -match [regex]::Escape("[ValidateSet('docker', 'podman', 'hyperv')]")) 'Batch-Smoke deckt nicht alle drei Provider ab.'
    Assert-Check ($batchSmokeSource -match [regex]::Escape('[switch]$AbortSchedulerOnce') -and
        $batchSmokeSource -match [regex]::Escape('Stop-Process -Id $schedulerProcess.Id -Force') -and
        $batchSmokeSource -match [regex]::Escape("Where-Object type -eq 'WorkerRecovered'")) 'Batch-Smoke weist keinen echten Scheduler-Prozessabbruch mit Recovery-Receipt nach.'
    Assert-Check ($batchSmokeSource -match [regex]::Escape('[switch]$ManifestRerun') -and
        $batchSmokeSource -match [regex]::Escape('New-SqlServerLabBatch -Manifest $manifestPath') -and
        $batchSmokeSource -match [regex]::Escape('Abgeschlossenes und bereinigtes Manifest erzeugte einen neuen Batch') -and
        $batchSmokeSource -match [regex]::Escape('Manifest-Rerun wurde vollstaendig scopegebunden bereinigt')) 'Batch-Smoke weist keinen deduplizierten offenen und vollstaendigen realen Manifest-Rerun nach.'
    Assert-Check ($batchSmokeSource -match [regex]::Escape('New-Item -ItemType Junction') -and
        $batchSmokeSource -match [regex]::Escape('TEMP_ARTIFACT_LINK_NOT_REPARSE_POINT') -and
        $batchSmokeSource -notmatch [regex]::Escape('New-Item -ItemType HardLink')) 'Hyper-V-Smoke bindet das immutable Parent nicht ueber eine sicher gepruefte Junction ein.'

    $userGateAcceptancePath = Join-Path $repoRoot 'Tests\Integration\Invoke-BatchUserGateAcceptance.ps1'
    Assert-Check (Test-Path -LiteralPath $userGateAcceptancePath -PathType Leaf) 'Reale Windows-User-Gate-Abnahme fehlt.'
    $userGateAcceptanceSource = Get-Content -LiteralPath $userGateAcceptancePath -Raw -Encoding utf8
    Assert-Check ($userGateAcceptanceSource -match [regex]::Escape('Read-only Probe setzte nur CandidateSatisfied') -and
        $userGateAcceptanceSource -match [regex]::Escape('Scheduler-Rerun setzte CandidateSatisfied ohne Benutzerbestaetigung nicht fort') -and
        $userGateAcceptanceSource -match [regex]::Escape('Confirm-SqlServerLabOperationUserAction -OperationId $operation.operationId -Credential $credential') -and
        $userGateAcceptanceSource -match [regex]::Escape('UserGateConfirmed') -and
        $userGateAcceptanceSource -match [regex]::Escape('User-Gate-Batch wurde scopegebunden vollstaendig bereinigt')) 'Windows-User-Gate-Abnahme bindet Probe, explizite Credential-Bestaetigung und Cleanup nicht real.'

    Write-Host 'BATCH-/QUEUE-/RESUME-VERTRAGSPRUEFUNGEN: PASS' -ForegroundColor Green
}
finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
