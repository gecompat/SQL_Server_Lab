#Requires -Version 7.2
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Fuehrt den isolierten GitHub-CI-Nachweis fuer Hyper-V External Runtimes aus.
.DESCRIPTION
    Der Einstieg akzeptiert weder bestehende Runs noch Clone-Quellen. Er erzeugt
    genau einen neuen, ueber den GitHub-Workflow-Operationskontext gebundenen
    SQL-2022/Windows-2025-Run aus einem verifizierten OS_SEALED-Artifact. Die
    eigentliche Reconcile-Acceptance bleibt im bestehenden oeffentlichen Runner.
    Auf Erfolg wie Fehlern entfernt dieser Einstieg nur den exakt gebundenen Run
    ueber Remove-SqlServerLab; fremde oder mehrdeutige Ownership wird gesperrt.
#>
[CmdletBinding()]
param(
    [string]$ArtifactId,
    [string]$MediaRoot = 'D:\Lab_Base',
    [string]$StateRoot
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$modulePath = Join-Path $repoRoot 'SqlServerLab.psd1'
$acceptanceRunner = Join-Path $PSScriptRoot 'Invoke-HyperVExternalRuntimeReconcileAcceptance.ps1'
$operationId = [string]$env:SQL_SERVER_LAB_TEST_OPERATION_ID
$module = $null
$previousStateRoot = $env:SQL_SERVER_LAB_STATE
$createdRunId = $null
$primaryFailure = $null
$cleanupFailure = $null
$mutex = [Threading.Mutex]::new($false, 'Global\SQL_Server_Lab_HyperV_External_Runtime_CI_Acceptance')
$mutexAcquired = $false

function Assert-HyperVExternalRuntimeCiAcceptance {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$ReasonCode)
    if (-not $Condition) { throw $ReasonCode }
}

function Test-HyperVExternalRuntimeCiMediaRoot {
    param([Parameter(Mandatory)][string]$Path)
    $expected = [IO.Path]::GetFullPath('D:\Lab_Base').TrimEnd('\')
    $actual = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    return $actual.Equals($expected, [StringComparison]::OrdinalIgnoreCase)
}

function Get-HyperVExternalRuntimeCiOwnedRun {
    param([Parameter(Mandatory)]$Module, [Parameter(Mandatory)][string]$OperationId, [Parameter(Mandatory)][string]$StateRoot)
    & $Module {
        param($ExpectedOperationId, $Root)
        $owned = Get-LabOperationOwnedRun -OperationId $ExpectedOperationId -StateRoot $Root
        if (-not $owned) { return $null }
        if ([string]$owned.runId -notmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' -or
            [string]$owned.scopeId -notmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' -or
            [string]$owned.metadata.workflowOperationId -cne $ExpectedOperationId -or
            (-not [string]::IsNullOrWhiteSpace([string]$owned.metadata.workflowKind) -and [string]$owned.metadata.workflowKind -cne 'hyperv-lab')) {
            throw 'HYPERV_EXTERNAL_RUNTIME_CI_OWNED_RUN_STATE_INVALID'
        }
        $providerSubRuns = @(Get-LabProviderSubRuns -RunId ([string]$owned.runId) -StateRoot $Root)
        if ($providerSubRuns.Count -ne 1 -or [string]$providerSubRuns[0].provider -cne 'hyperv') {
            throw 'HYPERV_EXTERNAL_RUNTIME_CI_OWNED_RUN_PROVIDER_INVALID'
        }
        $runDirectory = Join-Path (Join-Path $Root 'runs') ([string]$owned.runId)
        $plan = Get-CleanupPlan -RunDir $runDirectory
        if ([string]$plan.runId -cne [string]$owned.runId -or [string]$plan.scopeId -cne [string]$owned.scopeId -or
            @($plan.steps | Where-Object { [string]$_.provider -ne 'hyperv' }).Count -gt 0) {
            throw 'HYPERV_EXTERNAL_RUNTIME_CI_OWNED_RUN_CLEANUP_PLAN_INVALID'
        }
        $connectionPath = Join-Path $runDirectory 'connection-info.json'
        if (Test-Path -LiteralPath $connectionPath -PathType Leaf) {
            $context = Get-HyperVLabWorkflowRun -RunId ([string]$owned.runId) -StateRoot $Root
            if ([string]$context.Run.scopeId -cne [string]$owned.scopeId -or
                [string]$context.Instance.provider -cne 'hyperv' -or
                [string]::IsNullOrWhiteSpace([string]$context.Instance.vmName) -or
                [string]::IsNullOrWhiteSpace([string]$context.Instance.vmId)) {
                throw 'HYPERV_EXTERNAL_RUNTIME_CI_OWNED_RUN_CONNECTION_INVALID'
            }
            $managed = Get-HyperVManagedVM -VMName ([string]$context.Instance.vmName) -ExpectedRunId ([string]$owned.runId) -ExpectedScopeId ([string]$owned.scopeId)
            if (-not $managed -or [string]$managed.VM.Id -cne [string]$context.Instance.vmId) {
                throw 'HYPERV_EXTERNAL_RUNTIME_CI_OWNED_VM_OWNERSHIP_INVALID'
            }
        }
        return [PSCustomObject]@{ RunId=[string]$owned.runId; ScopeId=[string]$owned.scopeId }
    } $OperationId $StateRoot
}

function Invoke-HyperVExternalRuntimeCiCleanup {
    param([Parameter(Mandatory)]$Module, [Parameter(Mandatory)][string]$OperationId, [Parameter(Mandatory)][string]$StateRoot)
    $owned = Get-HyperVExternalRuntimeCiOwnedRun -Module $Module -OperationId $OperationId -StateRoot $StateRoot
    if (-not $owned) { return $null }
    $result = & $Module { param($RunId, $Root) Remove-SqlServerLab -RunId $RunId -StateRoot $Root -Force -Confirm:$false } $owned.RunId $StateRoot
    if ([string]$result.RunId -cne [string]$owned.RunId -or [string]$result.Status -notin @('REMOVED','COMPLETED')) {
        throw 'HYPERV_EXTERNAL_RUNTIME_CI_OWNED_RUN_CLEANUP_FAILED'
    }
    return $result
}

try {
    Assert-HyperVExternalRuntimeCiAcceptance ($operationId -match '^github-[0-9]+-[0-9]+$') 'HYPERV_EXTERNAL_RUNTIME_CI_OPERATION_CONTEXT_INVALID'
    Assert-HyperVExternalRuntimeCiAcceptance (Test-HyperVExternalRuntimeCiMediaRoot -Path $MediaRoot) 'HYPERV_EXTERNAL_RUNTIME_CI_MEDIA_ROOT_INVALID'
    $mutexAcquired = $mutex.WaitOne([TimeSpan]::FromMinutes(15))
    Assert-HyperVExternalRuntimeCiAcceptance $mutexAcquired 'HYPERV_EXTERNAL_RUNTIME_CI_HOST_LOCK_TIMEOUT'
    $principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    Assert-HyperVExternalRuntimeCiAcceptance ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) 'HYPERV_EXTERNAL_RUNTIME_CI_RUNNER_NOT_ELEVATED'
    Get-Command Get-VM -ErrorAction Stop | Out-Null
    $module = Import-Module $modulePath -Force -PassThru
    if (-not $StateRoot) { $StateRoot = & $module { Get-LabStateRoot } }
    $env:SQL_SERVER_LAB_STATE = $StateRoot

    if ($ArtifactId) {
        $artifact = & $module { param($Id, $Root) Get-HyperVImageArtifact -ArtifactId $Id -StateRoot $Root } $ArtifactId $StateRoot
    }
    else {
        $artifact = & $module {
            param($Root)
            @(Get-HyperVImageArtifact -StateRoot $Root -SkipIntegrityCheck | Where-Object {
                [string]$_.artifactState -eq 'OS_SEALED' -and
                [string]$_.operatingSystem.version -eq '2025' -and
                [string]$_.license.type -eq 'evaluation' -and
                [string]$_.licenseType -ne 'test-only'
            } | Sort-Object { [datetime]$_.registeredAt } -Descending | Select-Object -First 1)[0]
        } $StateRoot
    }
    Assert-HyperVExternalRuntimeCiAcceptance ($artifact -and [string]$artifact.artifactState -eq 'OS_SEALED' -and [string]$artifact.operatingSystem.version -eq '2025' -and [string]$artifact.license.type -eq 'evaluation') 'HYPERV_EXTERNAL_RUNTIME_CI_OS_SEALED_ARTIFACT_INVALID'
    $ArtifactId = [string]$artifact.artifactId

    $manifest = & $module {
        param($Artifact, $RepositoryRoot)
        . (Join-Path $RepositoryRoot 'Tests/Common/HyperVExternalRuntimeReconcileAcceptanceManifest.ps1')
        $value = Get-HyperVExternalRuntimeReconcileAcceptanceManifest
        $value['$schema'] = (Join-Path $RepositoryRoot 'Schemas/lab-manifest.schema.json')
        $value.name = 'external-runtime-ci-' + [guid]::NewGuid().ToString('N').Substring(0,8)
        $value.instances[0].hyperv = [ordered]@{ preparedImageId=[string]$Artifact.artifactId; memoryStartupMB=8192; processorCount=4; sqlPort=1433; guestPasswordMode='prompt' }
        $value.instances[0].windowsActivation = [ordered]@{ ContractVersion='SqlServerLab.WindowsActivationIntent/1.0'; Strategy='EvaluationOnline'; EgressPolicy='AllowTemporary' }
        return $value
    } $artifact $repoRoot
    $manifestPath = Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-hv-external-runtime-ci-' + [guid]::NewGuid().ToString('N') + '.json')
    try {
        $manifest | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $manifestPath -Encoding utf8
        $validation = & $module { param($Path) Test-SqlServerLabManifest -Path $Path } $manifestPath
        Assert-HyperVExternalRuntimeCiAcceptance $validation.IsValid 'HYPERV_EXTERNAL_RUNTIME_CI_MANIFEST_INVALID'
        $guestPassword = & $module { New-HyperVSqlUnattendedPassword }
        $sqlPassword = & $module { New-HyperVSqlUnattendedPassword }
        $lab = & $module {
            param($OperationId, $ManifestPath, $GuestPassword, $SqlPassword, $Root)
            Invoke-WithLabWorkflowOperationContext -OperationId $OperationId -ScriptBlock {
                New-SqlServerLab -Manifest $ManifestPath -GuestPassword $GuestPassword -SqlSaPassword $SqlPassword -NonInteractive -StateRoot $Root -Region AT -SystemLocale de-AT -UiLanguage en-US -InputLocale '0407:00000407' -TimeZone 'W. Europe Standard Time'
            }
        } $operationId $manifestPath $guestPassword $sqlPassword $StateRoot
        $createdRunId = [string]$lab.RunId
        $owned = Get-HyperVExternalRuntimeCiOwnedRun -Module $module -OperationId $operationId -StateRoot $StateRoot
        Assert-HyperVExternalRuntimeCiAcceptance ($owned -and [string]$owned.RunId -ceq $createdRunId) 'HYPERV_EXTERNAL_RUNTIME_CI_CREATED_RUN_OWNERSHIP_INVALID'
        # Der bestehende Wrapper bleibt der einzige fachliche Reconcile-Runner. Seine
        # gesamte Ausgabe (inklusive lokaler Evidence-Pfade) wird nicht an GitHub ausgegeben.
        $runnerOutput = @(& $acceptanceRunner -RunId $createdRunId -MediaRoot $MediaRoot -ArtifactId $ArtifactId -CleanupOnSuccess:$false *>&1)
        if (-not $?) { throw 'HYPERV_EXTERNAL_RUNTIME_CI_RECONCILE_FAILED' }
        Write-Host 'PASS: Isolierter Hyper-V External-Runtime-Reconcile wurde ausgefuehrt.' -ForegroundColor Green
    }
    finally {
        if (Test-Path -LiteralPath $manifestPath) { Remove-Item -LiteralPath $manifestPath -Force -ErrorAction SilentlyContinue }
    }
}
catch {
    $primaryFailure = $_
}
finally {
    if ($module) {
        try { $null = Invoke-HyperVExternalRuntimeCiCleanup -Module $module -OperationId $operationId -StateRoot $StateRoot }
        catch { $cleanupFailure = $_ }
    }
    if ($module) { Remove-Module $module.Name -Force -ErrorAction SilentlyContinue }
    if ($previousStateRoot) { $env:SQL_SERVER_LAB_STATE = $previousStateRoot } else { Remove-Item Env:SQL_SERVER_LAB_STATE -ErrorAction SilentlyContinue }
    if ($mutexAcquired) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
if ($primaryFailure -and $cleanupFailure) { throw 'HYPERV_EXTERNAL_RUNTIME_CI_EXECUTION_AND_CLEANUP_FAILED' }
if ($primaryFailure) { throw 'HYPERV_EXTERNAL_RUNTIME_CI_EXECUTION_FAILED' }
if ($cleanupFailure) { throw 'HYPERV_EXTERNAL_RUNTIME_CI_CLEANUP_FAILED' }
Write-Host 'Native Hyper-V External-Runtime-Reconcile-CI-Akzeptanz erfolgreich.' -ForegroundColor Green
