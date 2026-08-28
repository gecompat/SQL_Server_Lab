#Requires -Version 7.2
<#
.SYNOPSIS
    Reale Hyper-V-Abnahme fuer das persistente Windows-User-Gate.
.DESCRIPTION
    Erstellt genau einen test-eigenen Windows-Slot aus einem veroeffentlichten
    OS_SEALED-Artefakt. Der Test belegt, dass die read-only Probe nur
    CandidateSatisfied setzt, ein Scheduler-Rerun ohne ausdrueckliche
    Bestaetigung nichts fortsetzt und erst eine echte PowerShell-Direct-
    Credential-Verifikation den Gate-Schritt abschliesst. Anschliessend werden
    Batch, VM, Child-VHDX, Secrets und temporaerer State scopegebunden bereinigt.
.PARAMETER ArtifactId
    ID eines veroeffentlichten OS_SEALED-Hyper-V-Artefakts.
.PARAMETER ArtifactStateRoot
    Optionaler Quell-StateRoot des unveraenderlichen Artefakts.
.PARAMETER TimeoutSeconds
    Maximale Wartezeit auf die reale Windows-OOBE und PowerShell Direct.
.PARAMETER KeepOnFailure
    Behaelt test-eigenen State und Ressourcen nach einem Fehler zur Diagnose.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ArtifactId,

    [string]$ArtifactStateRoot,

    [ValidateRange(300, 3600)]
    [int]$TimeoutSeconds = 1200,

    [switch]$KeepOnFailure
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$modulePath = Join-Path $repoRoot 'SqlServerLab.psd1'
$stateRoot = Join-Path ([IO.Path]::GetTempPath()) ('sql-server-lab-user-gate-' + [Guid]::NewGuid().ToString('N'))
$previousStateRoot = $env:SQL_SERVER_LAB_STATE
$batch = $null
$operation = $null
$runId = $null
$testArtifactDirectory = $null
$testFailed = $false
$adminPassword = $null
$credential = $null

function Assert-UserGateAcceptance {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Description
    )

    if (-not $Condition) { throw $Description }
    Write-Host "PASS: $Description" -ForegroundColor Green
}

try {
    Write-Host 'Reale Windows-User-Gate-Abnahme' -ForegroundColor Cyan
    New-Item -Path $stateRoot -ItemType Directory -Force | Out-Null
    $env:SQL_SERVER_LAB_STATE = $stateRoot

    Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
    Import-Module $modulePath -Force
    $module = Get-Module SqlServerLab

    $hyperVAvailable = & $module { [bool](Test-HyperVAvailable).Available }
    Assert-UserGateAcceptance -Condition $hyperVAvailable -Description 'Hyper-V-Runtime ist erreichbar'

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
    Assert-UserGateAcceptance -Condition ($null -ne $sourceArtifact -and [string]$sourceArtifact.artifactState -eq 'OS_SEALED') -Description 'Veroeffentlichtes OS_SEALED-Artefakt ist verfuegbar'

    $sourceArtifactDirectory = Split-Path -Parent ([string]$sourceArtifact.Path)
    $testArtifactDirectory = Join-Path (Join-Path $stateRoot 'artifacts\hyperv\images') $ArtifactId
    New-Item -Path (Split-Path -Parent $testArtifactDirectory) -ItemType Directory -Force | Out-Null
    New-Item -ItemType Junction -Path $testArtifactDirectory -Target $sourceArtifactDirectory | Out-Null
    $artifactLink = Get-Item -LiteralPath $testArtifactDirectory -Force
    Assert-UserGateAcceptance -Condition (
        [bool]($artifactLink.Attributes -band [IO.FileAttributes]::ReparsePoint) -and
        (Get-Item -LiteralPath (Join-Path $testArtifactDirectory 'parent.vhdx')).IsReadOnly
    ) -Description 'Immutable Parent-VHDX ist ueber eine gepruefte Junction schreibgeschuetzt eingebunden'

    $adminPassword = [Security.SecureString]::new()
    $passwordToken = "Gate_$([Guid]::NewGuid().ToString('N'))!Aa7"
    foreach ($character in $passwordToken.ToCharArray()) { $adminPassword.AppendChar($character) }
    $passwordToken = $null
    $adminPassword.MakeReadOnly()
    $credential = [PSCredential]::new('Administrator', $adminPassword)

    $defaults = [pscustomobject]@{
        ProviderPreference = 'hyperv'
        ArtifactId = $ArtifactId
        MemoryStartupMB = 2048
        ProcessorCount = 2
        AutoStart = $false
        RequiresUserSetup = $true
    }
    $items = @([pscustomobject]@{
        id = 'windows-user-gate'
        kind = 'WindowsSlot'
        count = 1
        intent = [pscustomobject]@{ LabName = 'batch-user-gate-acceptance' }
    })
    $batch = New-SqlServerLabBatch -Name 'Windows user gate acceptance' -StateRoot $stateRoot -Defaults $defaults -Items $items
    Assert-UserGateAcceptance -Condition (@($batch.operationIds).Count -eq 1) -Description 'Genau eine test-eigene Gate-Operation wurde eingereiht'

    & $module { param($Root) Invoke-SqlServerLabScheduler -UntilIdle -MaxWorkers 1 -StateRoot $Root | Out-Null } $stateRoot
    $batch = Get-SqlServerLabBatch -BatchId $batch.batchId -StateRoot $stateRoot
    $operation = @(Get-SqlServerLabOperation -BatchId $batch.batchId -StateRoot $stateRoot)[0]
    $runId = [string]$operation.runId
    Assert-UserGateAcceptance -Condition ($operation.status -eq 'WaitingForUser' -and $batch.status -eq 'Waiting') -Description 'Realer Windows-Slot wartet persistent im User-Gate'
    Assert-UserGateAcceptance -Condition (-not [string]::IsNullOrWhiteSpace($runId) -and [string]$operation.userGate.verification.type -eq 'HyperVWindowsSetup') -Description 'User-Gate ist an den realen operationseigenen Hyper-V-Run gebunden'

    $runningDeadline = [DateTime]::UtcNow.AddSeconds(60)
    $vmStatus = $null
    do {
        $vmStatus = & $module {
            param($OwnedRunId, $Root)
            $lab = Get-HyperVLabWorkflowRun -RunId $OwnedRunId -StateRoot $Root
            Get-HyperVInstanceStatus -VMName ([string]$lab.Instance.vmName) `
                -ExpectedRunId $lab.Run.runId -ExpectedScopeId $lab.Run.scopeId
        } $runId $stateRoot
        if ([string]$vmStatus.State -ne 'Running') { Start-Sleep -Milliseconds 500 }
    } while ([string]$vmStatus.State -ne 'Running' -and [DateTime]::UtcNow -lt $runningDeadline)
    Assert-UserGateAcceptance -Condition ([string]$vmStatus.State -eq 'Running') -Description 'Hyper-V-VM erreichte vor der Probe den stabilen Zustand Running'

    $gateStep = [int]$operation.currentStep
    $receiptCount = @($operation.receipts).Count
    $probed = @(& $module {
        param($OperationId, $Root)
        Invoke-SqlServerLabOperationProbe -OperationId $OperationId -StateRoot $Root
    } $operation.operationId $stateRoot)[0]
    Write-Host ("Probe-Evidence: Status={0}; Candidate={1}; Success={2}; ProviderState={3}; Exists={4}; Message={5}" -f `
        $probed.status, $probed.userGate.verification.lastResult.candidate,
        $probed.userGate.verification.lastResult.success, $probed.userGate.verification.lastResult.result.State,
        $probed.userGate.verification.lastResult.result.Exists, $probed.userGate.verification.lastResult.message) -ForegroundColor DarkGray
    Assert-UserGateAcceptance -Condition ($probed.status -eq 'CandidateSatisfied' -and -not [bool]$probed.userGate.verification.lastResult.success -and [bool]$probed.userGate.verification.lastResult.candidate) -Description 'Read-only Probe setzte nur CandidateSatisfied'
    Assert-UserGateAcceptance -Condition ([int]$probed.currentStep -eq $gateStep -and @($probed.receipts).Count -eq $receiptCount) -Description 'Probe veraenderte weder Gate-Schritt noch Receipts'

    & $module { param($Root) Invoke-SqlServerLabScheduler -UntilIdle -MaxWorkers 1 -StateRoot $Root | Out-Null } $stateRoot
    $afterScheduler = Get-SqlServerLabOperation -OperationId $operation.operationId -StateRoot $stateRoot
    Assert-UserGateAcceptance -Condition ($afterScheduler.status -eq 'CandidateSatisfied' -and [int]$afterScheduler.currentStep -eq $gateStep -and @($afterScheduler.receipts).Count -eq $receiptCount -and [string]$afterScheduler.runId -eq $runId) -Description 'Scheduler-Rerun setzte CandidateSatisfied ohne Benutzerbestaetigung nicht fort'

    $missingCredential = @(Confirm-SqlServerLabOperationUserAction -OperationId $operation.operationId -StateRoot $stateRoot)[0]
    $afterMissingCredential = Get-SqlServerLabOperation -OperationId $operation.operationId -StateRoot $stateRoot
    Assert-UserGateAcceptance -Condition (-not [bool]$missingCredential.success -and $afterMissingCredential.status -eq 'WaitingForUser') -Description 'Explizite Bestaetigung ohne Credential blieb fail-closed im Gate'
    Assert-UserGateAcceptance -Condition ([int]$afterMissingCredential.currentStep -eq $gateStep -and @($afterMissingCredential.receipts).Count -eq $receiptCount) -Description 'Fehlgeschlagene Credential-Verifikation setzte keinen Schritt fort'

    & $module {
        param($OwnedRunId, $Root, $Password)
        $null = Stop-HyperVLabEnvironment -RunId $OwnedRunId -StateRoot $Root
        $lab = Get-HyperVLabWorkflowRun -RunId $OwnedRunId -StateRoot $Root
        $managed = Get-HyperVManagedVM -VMName ([string]$lab.Instance.vmName) -ExpectedRunId $lab.Run.runId -ExpectedScopeId $lab.Run.scopeId
        if (-not $managed -or [string]$managed.VM.State -ne 'Off') { throw 'USER_GATE_ACCEPTANCE_VM_NOT_OFF' }
        $childVhdx = [string]$managed.Identity.childVhdxPath
        if (-not (Test-Path -LiteralPath $childVhdx -PathType Leaf)) { throw 'USER_GATE_ACCEPTANCE_CHILD_VHDX_NOT_FOUND' }
        $unattend = $null
        try {
            $unattend = New-HyperVSqlOobeUnattendXml -AdministratorPassword $Password `
                -Network $lab.Instance.labNetwork -Identity $lab.Run.runId
            Set-HyperVSqlOfflineUnattend -VhdxPath $childVhdx `
                -MountRoot (Join-Path $lab.RunDirectory 'user-gate-oobe-mount') `
                -UnattendXml $unattend
        }
        finally { $unattend = $null }
        $null = Start-HyperVLabEnvironment -RunId $OwnedRunId -StateRoot $Root
    } $runId $stateRoot $adminPassword
    Assert-UserGateAcceptance -Condition $true -Description 'Testlokale OOBE wurde nur in die operationseigene Child-VHDX injiziert'

    $probedAfterOobeStart = @(& $module {
        param($OperationId, $Root)
        Invoke-SqlServerLabOperationProbe -OperationId $OperationId -StateRoot $Root
    } $operation.operationId $stateRoot)[0]
    Assert-UserGateAcceptance -Condition ($probedAfterOobeStart.status -eq 'CandidateSatisfied' -and [int]$probedAfterOobeStart.currentStep -eq $gateStep) -Description 'Erneute Probe blieb auch nach OOBE-Start reine Kandidatenerkennung'

    $confirmed = @(Confirm-SqlServerLabOperationUserAction -OperationId $operation.operationId -Credential $credential -StateRoot $stateRoot)[0]
    $afterConfirmation = Get-SqlServerLabOperation -OperationId $operation.operationId -StateRoot $stateRoot
    Assert-UserGateAcceptance -Condition ([bool]$confirmed.success -and $afterConfirmation.status -eq 'Queued') -Description 'Echte PowerShell-Direct-Credential-Verifikation reihte den Vorgang wieder ein'
    Assert-UserGateAcceptance -Condition ([int]$afterConfirmation.currentStep -eq ($gateStep + 1) -and @($afterConfirmation.receipts | Where-Object action -eq 'UserGateConfirmed').Count -eq 1) -Description 'Ausdrueckliche Bestaetigung schloss genau den Gate-Schritt mit Receipt ab'

    & $module { param($Root) Invoke-SqlServerLabScheduler -UntilIdle -MaxWorkers 1 -StateRoot $Root | Out-Null } $stateRoot
    $batch = Get-SqlServerLabBatch -BatchId $batch.batchId -StateRoot $stateRoot
    $operation = Get-SqlServerLabOperation -OperationId $operation.operationId -StateRoot $stateRoot
    Assert-UserGateAcceptance -Condition ($batch.status -eq 'Completed' -and $operation.status -eq 'Completed') -Description 'Bestaetigter Windows-Vorgang wurde vollstaendig abgeschlossen'
    $windowsState = & $module { param($OwnedRunId, $Root) (Get-HyperVLabWorkflowRun -RunId $OwnedRunId -StateRoot $Root).Instance.windowsProvisioning.state } $runId $stateRoot
    Assert-UserGateAcceptance -Condition ([string]$windowsState -eq 'COMPLETE') -Description 'Credential-Verifikation hinterliess den realen Windows-Slot als bereit'

    Stop-SqlServerLabBatch -BatchId $batch.batchId -Cleanup -IncludeCompleted -StateRoot $stateRoot -Confirm:$false | Out-Null
    & $module { param($Root) Invoke-SqlServerLabScheduler -UntilIdle -MaxWorkers 1 -StateRoot $Root | Out-Null } $stateRoot
    $operation = Get-SqlServerLabOperation -OperationId $operation.operationId -StateRoot $stateRoot
    Assert-UserGateAcceptance -Condition ($operation.cleanupResult.success -and @($operation.cleanupResult.remaining).Count -eq 0) -Description 'User-Gate-Batch wurde scopegebunden vollstaendig bereinigt'
    $remainingVmCount = & $module {
        param($OwnedRunId)
        @(Get-VM -ErrorAction SilentlyContinue | Where-Object { [string]$_.Notes -match [regex]::Escape(('"runId":"' + $OwnedRunId + '"')) }).Count
    } $runId
    Assert-UserGateAcceptance -Condition ([int]$remainingVmCount -eq 0) -Description 'Keine test-eigene Hyper-V-VM blieb zurueck'
    $batch = $null
}
catch {
    $testFailed = $true
    Write-Host "FAIL: $($_.Exception.Message)" -ForegroundColor Red
}
finally {
    if ($batch -and -not $KeepOnFailure) {
        try {
            Stop-SqlServerLabBatch -BatchId $batch.batchId -Cleanup -IncludeCompleted -StateRoot $stateRoot -Confirm:$false | Out-Null
            $module = Get-Module SqlServerLab
            & $module { param($Root) Invoke-SqlServerLabScheduler -UntilIdle -MaxWorkers 1 -StateRoot $Root | Out-Null } $stateRoot
        }
        catch {
            Write-Host "User-Gate-Cleanup-Fehler: $($_.Exception.Message)" -ForegroundColor Red
            $testFailed = $true
        }
    }

    $canRemoveStateRoot = $true
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
    $credential = $null
    if ($adminPassword) { $adminPassword.Dispose() }
    $env:SQL_SERVER_LAB_STATE = $previousStateRoot
}

if ($testFailed) { exit 1 }
Write-Host 'Reale Windows-User-Gate-Abnahme erfolgreich.' -ForegroundColor Green
exit 0
