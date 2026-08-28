#Requires -Version 7.2
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$failures = [Collections.Generic.List[string]]::new()
$passed = 0
. (Join-Path $PSScriptRoot '..\Common\CheckResult.ps1')

Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
$module = Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru -ErrorAction Stop

$results = & $module {
    $cancelled = ConvertTo-LabActionResult -Action Remove -InputObject @([pscustomobject]@{ RunId='r1'; Cleanup='CANCELLED' }) -BeforeFingerprint a -AfterFingerprint a
    $noChange = ConvertTo-LabActionResult -Action Stop -InputObject @([pscustomobject]@{ RunId='r2'; Action='SKIPPED'; Status='STOPPED' }) -BeforeFingerprint b -AfterFingerprint b
    $changed = ConvertTo-LabActionResult -Action Start -InputObject @([pscustomobject]@{ RunId='r3'; Action='STARTED'; Status='RUNNING' }) -BeforeFingerprint c -AfterFingerprint d
    $resources = ConvertTo-LabActionResult -Action Resources -InputObject @([pscustomobject]@{ RunId='r4'; Action='UPDATED' }) -BeforeFingerprint e -AfterFingerprint f
    $failed = ConvertTo-LabActionResult -Action Restart -InputObject @([pscustomobject]@{ RunId='r5'; Status='RECOVERY_REQUIRED' }) -BeforeFingerprint g -AfterFingerprint h
    $genericManage = ConvertTo-LabActionResult -Action Manage -InputObject @() -BeforeFingerprint i -AfterFingerprint j
    $managedRuntime = New-LabActionResult -Action Manage -Status Changed -ConnectionCenterImpact RuntimeState
    $syncCounter = [pscustomobject]@{ Value = 0 }
    $syncAction = { $syncCounter.Value++ }.GetNewClosure()
    $syncExecutions = @(
        Invoke-LabActionResultSynchronization -ActionResult $cancelled -SynchronizationAction $syncAction
        Invoke-LabActionResultSynchronization -ActionResult $noChange -SynchronizationAction $syncAction
        Invoke-LabActionResultSynchronization -ActionResult $changed -SynchronizationAction $syncAction
        Invoke-LabActionResultSynchronization -ActionResult $resources -SynchronizationAction $syncAction
        Invoke-LabActionResultSynchronization -ActionResult $failed -SynchronizationAction $syncAction
    )
    [pscustomobject]@{
        Cancelled = $cancelled
        NoChange = $noChange
        Changed = $changed
        Resources = $resources
        Failed = $failed
        GenericManage = $genericManage
        ManagedRuntime = $managedRuntime
        CancelSync = Test-LabActionResultRequiresConnectionCenterSync -ActionResult $cancelled
        NoChangeSync = Test-LabActionResultRequiresConnectionCenterSync -ActionResult $noChange
        ChangedSync = Test-LabActionResultRequiresConnectionCenterSync -ActionResult $changed
        ResourcesSync = Test-LabActionResultRequiresConnectionCenterSync -ActionResult $resources
        FailedSync = Test-LabActionResultRequiresConnectionCenterSync -ActionResult $failed
        GenericManageSync = Test-LabActionResultRequiresConnectionCenterSync -ActionResult $genericManage
        ManagedRuntimeSync = Test-LabActionResultRequiresConnectionCenterSync -ActionResult $managedRuntime
        SyncCounter = $syncCounter.Value
        SyncExecutions = $syncExecutions
    }
}

Add-CheckResult -Name 'ActionResult unterscheidet Cancelled, NoChange, Changed und Failed' -Success (
    $results.Cancelled.Status -eq 'Cancelled' -and $results.NoChange.Status -eq 'NoChange' -and
    $results.Changed.Status -eq 'Changed' -and $results.Failed.Status -eq 'Failed'
)
Add-CheckResult -Name 'Nicht mutierende Ergebnisse tragen weder Mutationen noch Connection-Center-Impact' -Success (
    $results.Cancelled.ConnectionCenterImpact -eq 'None' -and @($results.Cancelled.Mutations).Count -eq 0 -and
    $results.NoChange.ConnectionCenterImpact -eq 'None' -and @($results.NoChange.Mutations).Count -eq 0 -and
    $results.Failed.ConnectionCenterImpact -eq 'None' -and @($results.Failed.Mutations).Count -eq 0
)
Add-CheckResult -Name 'Runtime-Mutation fordert genau den vorgesehenen Sync-Gate-Pfad an' -Success (
    $results.Changed.ConnectionCenterImpact -eq 'RuntimeState' -and $results.ChangedSync -and
    -not $results.CancelSync -and -not $results.NoChangeSync -and -not $results.FailedSync
)
Add-CheckResult -Name 'Cancelled, NoChange, Changed, Resources und Failed erzeugen zusammen genau einen Sync-Aufruf' -Success (
    $results.SyncCounter -eq 1 -and @($results.SyncExecutions | Where-Object { $_ }).Count -eq 1
)
Add-CheckResult -Name 'Ressourcenaenderung bleibt trotz Mutation ohne Connection-Center-Sync' -Success (
    $results.Resources.Status -eq 'Changed' -and $results.Resources.ConnectionCenterImpact -eq 'None' -and -not $results.ResourcesSync
)
Add-CheckResult -Name 'Manage synchronisiert nur mit dem Impact der konkret gewaehlten Unteraktion' -Success (
    $results.GenericManage.Status -eq 'Changed' -and $results.GenericManage.ConnectionCenterImpact -eq 'None' -and
    -not $results.GenericManageSync -and $results.ManagedRuntimeSync
)

$menuSource = Get-Content -LiteralPath (Join-Path $repoRoot 'Public\Invoke-SqlServerLab.ps1') -Raw -Encoding utf8
Add-CheckResult -Name 'Gemeinsamer UI-Orchestrator synchronisiert ausschließlich über ActionResult' -Success (
    $menuSource -match 'function Invoke-LabActionWithResult' -and
    $menuSource -match 'Invoke-LabActionResultSynchronization' -and
    $menuSource -match 'New-LabActionResult -Action Manage' -and
    $menuSource -notmatch "\$Action -in @\('New', 'Stop'.+Sync-LabConnectionCenterAfterLifecycle"
)

if ($failures.Count -gt 0) {
    Write-Host "Action Result Checks: $passed PASS, $($failures.Count) FAIL" -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
Write-Host "Action Result Checks: $passed PASS" -ForegroundColor Green
