#Requires -Version 7.2
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$checkout = (& git -C $repoRoot rev-parse HEAD)
if ($LASTEXITCODE -or $env:GITHUB_EVENT_NAME -cne 'workflow_dispatch' -or
    $env:GITHUB_REPOSITORY -cne 'gecompat/SQL_Server_Lab' -or
    $env:SQL_SERVER_LAB_CI_EVENT_REPOSITORY -cne $env:GITHUB_REPOSITORY -or
    $checkout -cne $env:GITHUB_SHA -or $env:COMPUTERNAME -ine 'Key18') {
    throw 'TEST_GROUP_CI_SCOPE_INVALID'
}

. (Join-Path $repoRoot 'Tests/Common/HyperVPreparedLocaleSupervisor.ps1')
$root = New-HyperVPreparedLocaleSupervisorRoot
$stateRoot = Join-Path $root 'state'
$exportRoot = Join-Path $root 'exports'
$operationId = [guid]::NewGuid().ToString('D')
$log = Join-Path $root 'test-group.private.log'
$mutex = [Threading.Mutex]::new($false, 'Global\SQL_Server_Lab_Runtime_Smoke')
$acquired = $false
$previousState = $env:SQL_SERVER_LAB_STATE
try {
    try { $acquired = $mutex.WaitOne([TimeSpan]::FromMinutes(5)) }
    catch [Threading.AbandonedMutexException] {
        $acquired = $true
        throw 'TEST_GROUP_RUNTIME_LEASE_ABANDONED'
    }
    if (-not $acquired) { throw 'TEST_GROUP_RUNTIME_LEASE_BUSY' }
    $module = Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru 3>$null
    $env:SQL_SERVER_LAB_STATE = $stateRoot
    $evidence = & $module {
        param($RepoRoot, $StateRoot, $ExportRoot, $OperationId)
        . (Join-Path $RepoRoot 'Tests/Common/HyperVPreparedLocaleAcceptance.ps1')

        $stage = 'PREFLIGHT'
        $failure = $null
        $cleanup = 'NOT_REQUIRED'
        $arrangeStarted = $false
        $binding = @{}
        try {
            if (-not (Test-LabAdministrator) -or -not (Test-HyperVAvailable).Available) {
                throw 'TEST_GROUP_HYPERV_ELEVATION_REQUIRED'
            }
            $network = Resolve-LabHyperVNetworkBoundPlan -Intent hostOnly
            if ($network.Status -cne 'READY' -or @($network.Actions).Count -ne 0) {
                throw 'TEST_GROUP_EXISTING_HOST_NETWORK_REQUIRED'
            }
            $eligible = @(Get-LabTestGroupWindowsArtifact -StateRoot $StateRoot |
                Where-Object { $_.SqlVersion -ceq '2025' -and $_.Build -ceq '17.0.1000.7' })
            if (-not $eligible.Count) { throw 'TEST_GROUP_SQL_2025_IMAGE_UNAVAILABLE' }
            $image = Get-HyperVImageArtifact -StateRoot $StateRoot -SkipIntegrityCheck |
                Where-Object { $_.artifactId -cin $eligible.ArtifactId } |
                Sort-Object @{ Expression = { [datetimeoffset]$_.registeredAt }; Descending = $true }, artifactId |
                Select-Object -First 1
            $artifactId = [string]$image.artifactId
            if (-not $artifactId) { throw 'TEST_GROUP_SQL_2025_IMAGE_UNAVAILABLE' }
            Write-Information ('Selected artifact: ' + $artifactId) -InformationAction Continue
            $inventoryBefore = @(Get-VM -ErrorAction Stop | ForEach-Object { $_.Id.ToString('D') } | Sort-Object)
            $scope = @{ OutputDirectory = $ExportRoot }
            $create = Get-LabTestGroupManagementPlan -Operation CreateWindows -ArtifactId $ArtifactId @scope
            if (-not $create.CanApply) { throw 'TEST_GROUP_CREATE_PREVIEW_BLOCKED' }

            $stage = 'CREATE'
            $arrangeStarted = $true
            $created = Invoke-WithLabWorkflowOperationContext -OperationId $OperationId -ArgumentList @($ArtifactId, $create.PlanKey, $ExportRoot) -ScriptBlock {
                param($Id, $PlanKey, $Output)
                Invoke-LabTestGroupManagementPlan -Operation CreateWindows -ArtifactId $Id -ExpectedPlanKey $PlanKey -OutputDirectory $Output
            }
            $owned = Get-LabOperationOwnedRun -OperationId $OperationId -StateRoot $StateRoot
            $entries = @((Get-LabTestEnvironmentRegistry @scope).environments)
            if ($created.Status -cne 'REGISTERED' -or -not $created.GroupReady -or -not $owned -or
                $entries.Count -ne 1 -or $entries[0].runId -cne $owned.runId -or $entries[0].key -cne $created.Key) {
                throw 'TEST_GROUP_CREATE_POSTCONDITION'
            }
            $context = Get-HyperVLabWorkflowRun -RunId $owned.runId -StateRoot $StateRoot
            $binding = @{ RunId = $owned.runId; ScopeId = $owned.scopeId; VmId = $context.Instance.vmId }
            $null = Get-HyperVPreparedLocaleBoundContext @binding -OperationId $OperationId -StateRoot $StateRoot

            $stage = 'STOP'
            $stop = Get-LabTestGroupPowerPlan -PowerAction Stop -StateRoot $StateRoot @scope
            $stopped = Invoke-LabTestGroupPowerPlan -PowerAction Stop -ExpectedPlanKey $stop.PlanKey -Confirmed -StateRoot $StateRoot @scope
            $context = Get-HyperVPreparedLocaleBoundContext @binding -OperationId $OperationId -StateRoot $StateRoot
            if ($stopped.Status -cne 'COMPLETED' -or $context.BoundVmState -cne 'Off') { throw 'TEST_GROUP_STOP_POSTCONDITION' }

            $stage = 'REPAIR'
            $repair = Get-LabTestGroupManagementPlan -Operation Repair @scope
            if (-not $repair.CanApply -or $repair.Members.Count -ne 1) { throw 'TEST_GROUP_REPAIR_PREVIEW_BLOCKED' }
            $repaired = Invoke-LabTestGroupManagementPlan -Operation Repair -ExpectedPlanKey $repair.PlanKey @scope
            $context = Get-HyperVPreparedLocaleBoundContext @binding -OperationId $OperationId -StateRoot $StateRoot
            if ($repaired.Status -cne 'READY' -or $repaired.Count -ne 1 -or $context.BoundVmState -cne 'Running') {
                throw 'TEST_GROUP_REPAIR_POSTCONDITION'
            }

            $stage = 'REMOVE'
            $managed = Get-HyperVManagedVM -VMName $context.Instance.vmName -ExpectedRunId $binding.RunId -ExpectedScopeId $binding.ScopeId
            if (-not $managed -or [string]$managed.VM.Id -cne $binding.VmId -or
                -not (Test-Path -LiteralPath $managed.Identity.childVhdxPath -PathType Leaf)) {
                throw 'TEST_GROUP_REMOVE_DISK_BINDING_MISSING'
            }
            $diskPaths = @($managed.Identity.childVhdxPath) + @($managed.Identity.additionalVhdxPaths)
            $remove = Get-LabTestGroupManagementPlan -Operation Remove @scope
            if (-not $remove.CanApply -or $remove.Members.Count -ne 1) { throw 'TEST_GROUP_REMOVE_PREVIEW_BLOCKED' }
            $removed = Invoke-LabTestGroupManagementPlan -Operation Remove -ExpectedPlanKey $remove.PlanKey @scope
            if ($removed.Status -cne 'REMOVED' -or $removed.Count -ne 1 -or
                (Get-LabOperationOwnedRun -OperationId $OperationId -StateRoot $StateRoot) -or
                @(Get-ChildItem -LiteralPath $ExportRoot -Force).Count -or
                @($diskPaths | Where-Object { $_ -and (Test-Path -LiteralPath $_) }).Count) {
                throw 'TEST_GROUP_REMOVE_POSTCONDITION'
            }
            $inventoryAfter = @(Get-VM -ErrorAction Stop | ForEach-Object { $_.Id.ToString('D') } | Sort-Object)
            if (($inventoryBefore -join ',') -cne ($inventoryAfter -join ',')) { throw 'TEST_GROUP_HYPERV_INVENTORY_CHANGED' }
            $cleanup = 'CONFIRMED'
            $stage = 'COMPLETE'
        }
        catch { $failure = $_ }
        finally {
            if ($arrangeStarted -and $stage -cne 'COMPLETE') {
                try {
                    $active = Get-LabOperationOwnedRun -OperationId $OperationId -StateRoot $StateRoot
                    if ($active) {
                        $null = Remove-HyperVPreparedLocaleOwnRun -OperationId $OperationId -StateRoot $StateRoot @binding
                    }
                    $cleanup = 'VERIFY_LOCAL_EVIDENCE'
                }
                catch {
                    Write-Information ($_ | Out-String) -InformationAction Continue
                    $cleanup = 'RECOVERY_REQUIRED'
                }
            }
        }
        if ($failure) { Write-Information ($failure | Out-String) -InformationAction Continue }
        [pscustomobject]@{ Stage = $stage; Cleanup = $cleanup }
    } $repoRoot $stateRoot $exportRoot $operationId 3>&1 4>&1 5>&1 6>&1 | ForEach-Object {
        if ($_.PSObject.Properties['Stage'] -and $_.PSObject.Properties['Cleanup']) { $_ }
        else { $_ | Out-String | Add-Content -LiteralPath $log -Encoding utf8 }
    }
    Write-Host "HYPERV_TEST_GROUP_ACCEPTANCE $($evidence.Stage) $($evidence.Cleanup)"
    if ($evidence.Stage -cne 'COMPLETE') { throw 'TEST_GROUP_NATIVE_ACCEPTANCE_FAILED' }
}
finally {
    $env:SQL_SERVER_LAB_STATE = $previousState
    if ($acquired) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
