#Requires -Version 7.2
<#
.SYNOPSIS
    Prüft Windows-Lizenz und SQL-Bereitschaft eines separaten SQL-2025-Ziellabs auf Hyper-V.
.DESCRIPTION
    Erstellt zwei eigene Labs aus demselben expliziten Developer-Prepared-Image.
    Die Quelle wird vor dem Start des Ziels gestoppt. Beide Bindungen bleiben
    bis zum Ende erhalten. Die Probe führt keinen SQL-Transfer und keine
    Lizenzänderung aus. Cleanup entfernt ausschließlich die eigenen Runs.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^hyperv-sql-prepared-sealed-[a-f0-9]{64}$')][string]$ArtifactId
)

$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$testRoot = Join-Path $repo ('.artifacts/test-runs/evaluation-target-license-' + [guid]::NewGuid().ToString('N'))
$sourceOperation = [guid]::NewGuid().ToString('D')
$targetOperation = [guid]::NewGuid().ToString('D')
$source = $null
$target = $null
$module = $null
$stateRoot = $null
$acquired = $false
$cleanupFailed = $false
$phase = 'PREFLIGHT'

function Assert-TargetLicenseAcceptance {
    param([bool]$Condition, [string]$Name)
    if (-not $Condition) { throw ('EVALUATION_TARGET_LICENSE_ASSERTION_FAILED: ' + $Name) }
    Write-Host "PASS: $Name"
}

function New-TargetLicenseAcceptanceRun {
    param([string]$Role, [string]$Operation)
    $manifestPath = Join-Path $testRoot ($Role + '.json')
    $manifest = @{
        name=('eval-license-' + $Role + '-' + $Operation.Substring(0,8)); automation=@{mode='unattended'}
        instances=@(@{
            id='primary'; version='2025'; provider='hyperv'; os='windows'; profile='standard'; autostart='off'
            network=@{intent='hostOnly';exposure='host'}
            windowsActivation=@{ContractVersion='SqlServerLab.WindowsActivationIntent/1.0';Strategy='EvaluationOnline';EgressPolicy='AllowTemporary'}
            hyperv=@{preparedImageId=$ArtifactId;memoryStartupMB=6144;processorCount=4;sqlPort=1433;guestPasswordMode='prompt'}
        })
    }
    $manifest | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath $manifestPath -Encoding utf8
    if (-not (Test-SqlServerLabManifest -Path $manifestPath -ErrorAction Stop).IsValid) { throw 'ACCEPTANCE_MANIFEST_INVALID' }
    $guest = $null
    $sql = $null
    try {
        $guest = & $module { New-HyperVSqlUnattendedPassword }
        $sql = & $module { New-HyperVSqlUnattendedPassword }
        & $module {
            param($Manifest, $Guest, $Sql, $Root, $OperationId)
            Invoke-WithLabWorkflowOperationContext -OperationId $OperationId -ScriptBlock {
                param($Path, $GuestPassword, $SqlPassword, $State)
                New-SqlServerLab -Manifest $Path -GuestPassword $GuestPassword -SqlSaPassword $SqlPassword -StateRoot $State -NonInteractive
            } -ArgumentList @($Manifest, $Guest, $Sql, $Root)
        } $manifestPath $guest $sql $stateRoot $Operation 3>$null 4>$null 5>$null 6>$null
    } finally {
        if ($guest) { $guest.Dispose() }
        if ($sql) { $sql.Dispose() }
    }
}

function Remove-TargetLicenseAcceptanceRun {
    param([string]$Operation, $ObservedRun)
    $owned = & $module { param($Id,$Root) Get-LabOperationOwnedRun -OperationId $Id -StateRoot $Root } $Operation $stateRoot
    if (-not $owned) {
        if ($ObservedRun) { throw 'EVALUATION_TARGET_LICENSE_OWNERSHIP_MISSING' }
        return
    }
    if ($ObservedRun -and [string]$owned.runId -cne [string]$ObservedRun.RunId) { throw 'EVALUATION_TARGET_LICENSE_OWNERSHIP_CHANGED' }
    $resources = @(& $module {
        param($Run)
        foreach ($vm in @(Get-HyperVLabVMs -RunId ([string]$Run.runId) -ScopeId ([string]$Run.scopeId))) {
            $managed = Get-HyperVManagedVM -VMName ([string]$vm.VMName) -ExpectedRunId ([string]$Run.runId) -ExpectedScopeId ([string]$Run.scopeId)
            [pscustomobject]@{Id=[guid]$managed.VM.Id;Paths=@($managed.Identity.childVhdxPath)+@($managed.Identity.additionalVhdxPaths)}
        }
    } $owned)
    $removed = Remove-SqlServerLab -RunId ([string]$owned.runId) -StateRoot $stateRoot -Force -Confirm:$false 3>$null 4>$null 5>$null 6>$null
    if ($removed.Status -cne 'REMOVED' -or $removed.Cleanup -cne 'CLEANUP_SUCCEEDED') { throw 'EVALUATION_TARGET_LICENSE_CLEANUP_INCOMPLETE' }
    $remaining = & $module { param($Id,$Scope) @(Get-HyperVLabVMs -RunId $Id -ScopeId $Scope).Count } ([string]$owned.runId) ([string]$owned.scopeId)
    if ($remaining -ne 0) { throw 'EVALUATION_TARGET_LICENSE_VM_REMAINS' }
    $currentVmIds = @(Get-VM -ErrorAction Stop | ForEach-Object Id)
    foreach ($item in $resources) {
        if ($item.Id -in $currentVmIds) { throw 'EVALUATION_TARGET_LICENSE_VM_REMAINS' }
        foreach ($path in $item.Paths) {
            if ($path -and (Test-Path -LiteralPath $path -ErrorAction Stop)) { throw 'EVALUATION_TARGET_LICENSE_DISK_REMAINS' }
        }
    }
}

$mutex = [Threading.Mutex]::new($false,'Global\SQL_Server_Lab_Runtime_Smoke')
try {
    $principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'ELEVATED_HYPERV_RUNNER_REQUIRED' }
    $acquired = $mutex.WaitOne([TimeSpan]::FromMinutes(10))
    if (-not $acquired) { throw 'RUNTIME_SMOKE_LEASE_TIMEOUT' }
    $module = Import-Module (Join-Path $repo 'SqlServerLab.psd1') -Force -PassThru 3>$null 4>$null 5>$null 6>$null
    $dataRoot = & $module { Assert-LabDiagnosticPath -Path (Resolve-LabDataRootForUse) }
    $stateRoot = & $module { param($Data) Assert-LabDiagnosticPath -Path (Join-Path $Data 'State') } $dataRoot
    Assert-TargetLicenseAcceptance ([IO.Directory]::Exists($stateRoot)) 'Expliziter State Root des registrierten Lab_Data existiert'
    $artifacts = @(& $module { param($Id,$Root) Get-HyperVImageArtifact -ArtifactId $Id -StateRoot $Root } $ArtifactId $stateRoot)
    Assert-TargetLicenseAcceptance ($artifacts.Count -eq 1 -and $artifacts[0].artifactState -ceq 'SQL_PREPARED_SEALED' -and
        $artifacts[0].sql.version -ceq '2025' -and $artifacts[0].sql.edition -match 'Developer' -and
        $artifacts[0].integrityVerification.status -cin @('VERIFIED_HASH','VERIFIED_CACHE')) 'Explizite SQL-2025-Developer-Vorlage ist verifiziert'
    $artifact = $artifacts[0]
    $parentHash = [string]$artifact.sha256
    $null = New-Item -ItemType Directory -Path $testRoot

    $phase = 'SOURCE_ARRANGE'
    $source = New-TargetLicenseAcceptanceRun -Role source -Operation $sourceOperation
    Assert-TargetLicenseAcceptance ($source.State -ceq 'RUNNING') 'Eigener Quell-Run wurde angelegt'
    $ownedSource = & $module { param($Id,$Root) Get-LabOperationOwnedRun -OperationId $Id -StateRoot $Root } $sourceOperation $stateRoot
    if ([string]$ownedSource.runId -cne [string]$source.RunId) { throw 'EVALUATION_TARGET_LICENSE_SOURCE_OWNERSHIP_CHANGED' }
    $null = Stop-SqlServerLab -RunId $source.RunId -StateRoot $stateRoot -SkipHostMemoryRelease -Force -Confirm:$false 3>$null 4>$null 5>$null 6>$null
    $sourceState = & $module { param($Id,$Root) Get-LabRunState -RunId $Id -StateRoot $Root } $source.RunId $stateRoot
    $sourceVmState = & $module {
        param($Id,$Data)
        $snapshot = Read-LabEvaluationRefreshSnapshot -RunId $Id -InstanceId primary -DataRoot $Data
        [string]((Get-VM -Id ([guid]$snapshot.Instance.vmId) -ErrorAction Stop).State)
    } $source.RunId $dataRoot
    Assert-TargetLicenseAcceptance ($sourceState.state -ceq 'STOPPED' -and $sourceVmState -ceq 'Off') 'Eigene Quelle vor dem Zielstart gestoppt'

    $phase = 'TARGET_ARRANGE'
    $target = New-TargetLicenseAcceptanceRun -Role target -Operation $targetOperation
    $ownedTarget = & $module { param($Id,$Root) Get-LabOperationOwnedRun -OperationId $Id -StateRoot $Root } $targetOperation $stateRoot
    Assert-TargetLicenseAcceptance ($target.State -ceq 'RUNNING' -and $target.RunId -cne $source.RunId -and
        [string]$ownedTarget.runId -ceq [string]$target.RunId) 'Separates eigenes Ziellab läuft'

    $phase = 'BOUND_TARGET_OBSERVATION'
    $request = @{
        RunId=$source.RunId; InstanceId='primary'; DataRoot=$dataRoot
        TargetRunId=$target.RunId; TargetInstanceId='primary'
    }
    $plan = Get-SqlServerLabEvaluationRefreshPlan @request -Mode STATEFUL_MIGRATION
    Assert-TargetLicenseAcceptance ($plan.TargetAssessment.Status -ceq 'METADATA_ONLY' -and $plan.TargetAssessment.RegisteredState -ceq 'RUNNING' -and
        $plan.Status -ceq 'BLOCKED' -and $plan.TransferAuthority -ceq 'NONE') 'Vorschau bindet getrennte Quelle und Ziel ohne Transferfreigabe'
    $paths = @(foreach ($runId in @($source.RunId,$target.RunId)) {
        $directory = Join-Path $stateRoot ('runs/' + $runId)
        Join-Path $directory 'run-state.json'
        Join-Path $directory 'connection-info.json'
    })
    $before = @($paths | ForEach-Object { (Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash })
    $operationRequest = $request.Clone()
    $operationRequest.ExpectedPlanKey = $plan.ObservedContentSha256
    $operationRequest.ExpectedTargetPlanKey = $plan.TargetAssessment.ObservedContentSha256
    $result = (Invoke-SqlServerLabWorkflowAction @operationRequest -Action ReadHyperVEvaluationWindowsLicense).Result
    $license = $result.WindowsLicenseObservation
    Assert-TargetLicenseAcceptance ($result.TargetRunId -ceq $target.RunId -and $result.TargetInstanceId -ceq 'primary' -and
        $license.Status -ceq 'OBSERVED' -and $license.ObservedAt -and
        (($license.LicenseState -ceq 'LICENSED' -and $null -eq $license.EvaluationExpiresAt) -or
            ($license.LicenseState -ceq 'EVALUATION_ACTIVE' -and $license.EvaluationExpiresAt))) 'Live-Windows-Lizenz der gebundenen Ziel-VM bestätigt'
    $phase = 'TARGET_SQL_READINESS'
    $readiness = (Invoke-SqlServerLabWorkflowAction @operationRequest -Action ReadHyperVEvaluationTargetSqlReadiness).Result
    Assert-TargetLicenseAcceptance ($readiness.TargetRunId -ceq $target.RunId -and $readiness.TargetInstanceId -ceq 'primary' -and
        $readiness.SqlReadinessObservation.Status -ceq 'OBSERVED' -and $readiness.SqlReadinessObservation.ObservedAt) 'SQL-Bereitschaft der gebundenen Ziel-VM bestätigt'
    $phase = 'TARGET_STORAGE_CAPACITY'
    $storage = (Invoke-SqlServerLabWorkflowAction @operationRequest -Action ReadHyperVEvaluationTargetStorage).Result
    $observation = $storage.StorageObservation
    $roles = @($observation.Volumes | ForEach-Object Roles | Sort-Object)
    Assert-TargetLicenseAcceptance ($storage.TargetRunId -ceq $target.RunId -and $storage.TargetInstanceId -ceq 'primary' -and
        $observation.Status -ceq 'OBSERVED' -and $observation.ObservedAt -and
        ($roles -join ',') -ceq 'Backup,Data,Log' -and
        @($observation.Volumes | Where-Object { $_.AvailableBytes -isnot [long] -or $_.AvailableBytes -lt 0 }).Count -eq 0) 'Freier Gastspeicher für Daten, Log und Backup ist am gebundenen Ziel beobachtet'
    $fresh = Get-SqlServerLabEvaluationRefreshPlan @request -Mode STATEFUL_MIGRATION
    $after = @($paths | ForEach-Object { (Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash })
    Assert-TargetLicenseAcceptance (($before -join ',') -ceq ($after -join ',') -and
        $fresh.ObservedContentSha256 -ceq $plan.ObservedContentSha256 -and
        $fresh.TargetAssessment.ObservedContentSha256 -ceq $plan.TargetAssessment.ObservedContentSha256) 'Quell- und Zielmetadaten blieben bytegleich'
    $parentAfter = & $module { param($Id,$Root) Get-HyperVImageArtifact -ArtifactId $Id -StateRoot $Root } $ArtifactId $stateRoot
    Assert-TargetLicenseAcceptance ($parentAfter.sha256 -ceq $parentHash) 'Prepared-Vorlage blieb unverändert'
} catch {
    $failure = [regex]::Match([string]$_.Exception.Message,'^[A-Z][A-Z0-9_]{2,100}(?=:|$)')
    $code = if ($failure.Success) { $failure.Value } else { 'UNCLASSIFIED_ERROR' }
    if ($code -ceq 'EVALUATION_TARGET_LICENSE_ASSERTION_FAILED') { Write-Host $_.Exception.Message }
    throw "EVALUATION_TARGET_LICENSE_FAILED: $phase / $code"
} finally {
    if ($module -and $acquired -and $stateRoot) {
        foreach ($entry in @(@{Operation=$targetOperation;Run=$target},@{Operation=$sourceOperation;Run=$source})) {
            try { Remove-TargetLicenseAcceptanceRun -Operation $entry.Operation -ObservedRun $entry.Run }
            catch { $cleanupFailed = $true; Write-Host 'RECOVERY_REQUIRED: Eigener Acceptance-Run benötigt scopegebundene Prüfung.' }
        }
    }
    if ($acquired) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
if ($cleanupFailed) { throw 'EVALUATION_TARGET_LICENSE_CLEANUP_FAILED' }
Write-Host 'PASS: Eigene Quell- und Ziel-Runs, VMs und Disks vollständig bereinigt'
Write-Host 'EVALUATION TARGET WINDOWS LICENSE ACCEPTANCE: PASS'
