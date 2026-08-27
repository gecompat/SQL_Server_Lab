#Requires -Version 7.2
[CmdletBinding()]
param(
    [string]$RunId,
    [string]$MediaRoot = 'D:\Lab_Base',
    [string]$ArtifactId = 'hyperv-os-sealed-01f5d9a11f91ee9641eb2cde936431b4d6258333b4f7a0e6e51032df74878be5',
    [switch]$CleanupOnSuccess
)

$ErrorActionPreference = 'Stop'
if (-not $IsWindows -or -not (Get-Command Get-VM -ErrorAction SilentlyContinue)) {
    throw 'HYPERV_EXTERNAL_RUNTIME_ACCEPTANCE_REQUIRES_WINDOWS_HYPERV'
}
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force
$module = Get-Module SqlServerLab

& $module {
    param($RequestedRunId,$MediaRoot,$ArtifactId,$CleanupOnSuccess)

    $stateRoot = Get-LabStateRoot
    if ($RequestedRunId) {
        $lab = Get-HyperVLabWorkflowRun -RunId $RequestedRunId -StateRoot $stateRoot
    }
    else {
        $guestPassword = New-HyperVSqlUnattendedPassword
        $created = New-HyperVLabEnvironment -ArtifactId $ArtifactId -LabName 'external-runtime-native-evidence' `
            -InstanceId 'sql2022-ext' -MemoryStartupMB 8192 -ProcessorCount 4 -AutoStart off -StateRoot $stateRoot
        $lab = Get-HyperVLabWorkflowRun -RunId $created.RunId -StateRoot $created.StateRoot
        Save-LabSecret -Path $lab.RunDirectory -Name 'guest-administrator-password' -Secret $guestPassword
    }
    $runId = [string]$lab.Run.runId
    $transcriptPath = Join-Path $lab.RunDirectory 'external-runtime-hyperv-acceptance.log'
    Start-Transcript -LiteralPath $transcriptPath -Append | Out-Null
    try {
        Write-Host "NATIVE_RUN_ID=$runId"
        $guestPassword = Get-LabSecret -Path $lab.RunDirectory -Name 'guest-administrator-password'
        if (-not $guestPassword) {
            $guestPassword = New-HyperVSqlUnattendedPassword
            Save-LabSecret -Path $lab.RunDirectory -Name 'guest-administrator-password' -Secret $guestPassword
        }
        $credential = [PSCredential]::new('Administrator', $guestPassword)

        $windowsSlotReady = $lab.Instance.windowsProvisioning -and
            [string]$lab.Instance.windowsProvisioning.state -eq 'COMPLETE'
        $oobeReady = $lab.Instance.oobeAutomation -and
            [string]$lab.Instance.oobeAutomation.status -eq 'COMPLETED'
        if (-not $windowsSlotReady -and -not $oobeReady) {
            $null = Invoke-HyperVLabUnattendedProvision -RunId $runId -AdministratorPassword $guestPassword `
                -PasswordSource generated -StateRoot $lab.StateRoot
            $lab = Get-HyperVLabWorkflowRun -RunId $runId -StateRoot $lab.StateRoot
        }

        if ([string]$lab.Instance.workload -eq 'windows') {
            $managed = Get-HyperVManagedVM -VMName ([string]$lab.Instance.vmName) `
                -ExpectedRunId $runId -ExpectedScopeId ([string]$lab.Run.scopeId)
            if ([string]$managed.VM.State -ne 'Off') {
                $null = Stop-HyperVLabEnvironment -RunId $runId -StateRoot $lab.StateRoot
            }
            if (-not $lab.Instance.sqlDeploymentPlan) {
                $null = Set-HyperVLabSqlDeploymentPlan -RunId $runId -SqlVersion 2022 -DeploymentMode adhoc-install `
                    -MediaEdition Eval -SqlMediaPath 'SQL/2022/Eval/ISO/SQLServer2022-x64-ENU.iso' `
                    -SqlFeatures SQLENGINE,FULLTEXT,REPLICATION,ADVANCEDANALYTICS `
                    -MemoryStartupMB 8192 -ProcessorCount 4 -StateRoot $lab.StateRoot
            }
            $sqlResult = Invoke-HyperVLabSqlSlotInstall -RunId $runId -MediaRoot $MediaRoot -StateRoot $lab.StateRoot
            if ([string]$sqlResult.State -ne 'SQL_SLOT_READY') { throw 'HYPERV_EXTERNAL_RUNTIME_SQL_SLOT_NOT_READY' }
            $lab = Get-HyperVLabWorkflowRun -RunId $runId -StateRoot $lab.StateRoot
        }

        $sqlPassword = Get-LabSecret -Path $lab.RunDirectory -Name 'sa-password'
        if (-not $sqlPassword) { throw 'HYPERV_EXTERNAL_RUNTIME_SQL_PASSWORD_NOT_STORED' }
        $plans = @()
        foreach ($softwareId in @('sql-python','sql-r','sql-java')) {
            $request = [PSCustomObject]@{
                Id=$softwareId; Version=$null; Variant=$null; InstallMethod=$null
                Packages=@(); RequestSource='native-evidence'
            }
            $plan = Resolve-LabExternalRuntimePlan -SoftwareItem $request -SqlVersion 2022 `
                -Provider hyperv -OperatingSystem windows
            if ([string]$plan.ReasonCode -ne 'VARIANT_PREVIEW') {
                throw "HYPERV_EXTERNAL_RUNTIME_CHARACTERIZATION_PLAN_UNEXPECTED: $softwareId / $($plan.ReasonCode)"
            }
            $plan.Status = 'RESOLVED'; $plan.ReasonCode = $null; $plan.Reason = $null
            $plans += $plan
        }

        $receipts = @(Install-LabHyperVExternalRuntimes -SoftwarePlans $plans -RunId $runId `
            -Credential $credential -SqlSaPassword $sqlPassword -MediaRoot $MediaRoot -StateRoot $lab.StateRoot)
        if (@($receipts | Where-Object Status -ne 'INSTALLED').Count -gt 0 -or $receipts.Count -ne 3) {
            throw 'HYPERV_EXTERNAL_RUNTIME_RECEIPTS_INVALID'
        }

        $null = Stop-HyperVLabEnvironment -RunId $runId -StateRoot $lab.StateRoot
        $null = Start-HyperVLabEnvironment -RunId $runId -StateRoot $lab.StateRoot
        $lab = Get-HyperVLabWorkflowRun -RunId $runId -StateRoot $lab.StateRoot
        $ready = Wait-HyperVPowerShellDirect -VMName ([string]$lab.Instance.vmName) -ExpectedRunId $runId `
            -ExpectedScopeId ([string]$lab.Run.scopeId) -Credential $credential -TimeoutSeconds 600
        if (-not $ready.Ready) { throw "HYPERV_EXTERNAL_RUNTIME_COLD_START_GUEST_NOT_READY: $($ready.Message)" }
        $versionDefinition = Get-SqlServerVersion -VersionId 2022
        $sqlReady = Wait-SqlReady -HostName ([string]$lab.Instance.host) -Port ([int]$lab.Instance.port) `
            -SaPassword $sqlPassword -ExpectedMajorVersion ([int]$versionDefinition.major) -TimeoutSeconds 600
        if (-not $sqlReady.Ready) { throw "HYPERV_EXTERNAL_RUNTIME_COLD_START_SQL_NOT_READY: $($sqlReady.Message)" }
        $pythonPlan = @($plans | Where-Object Language -eq 'Python')[0]
        $rPlan = @($plans | Where-Object Language -eq 'R')[0]
        $javaPlan = @($plans | Where-Object Language -eq 'Java')[0]
        $coldStartProbes = @(
            Invoke-LabPythonExternalRuntimeProbe -Plan $pythonPlan -HostName ([string]$lab.Instance.host) `
                -Port ([int]$lab.Instance.port) -SaPassword $sqlPassword
            Invoke-LabRExternalRuntimeProbe -Plan $rPlan -HostName ([string]$lab.Instance.host) `
                -Port ([int]$lab.Instance.port) -SaPassword $sqlPassword
            Invoke-LabJavaExternalRuntimeProbe -Plan $javaPlan -HostName ([string]$lab.Instance.host) `
                -Port ([int]$lab.Instance.port) -SaPassword $sqlPassword -Database master
        )

        $evidence = [PSCustomObject]@{
            contract = [PSCustomObject]@{ name='SqlServerLab.ExternalRuntimeHyperVAcceptance'; version='1.0' }
            runId = $runId
            provider = 'hyperv'
            operatingSystem = 'windows-server-2025'
            sqlVersion = '2022'
            sqlFeatures = @($lab.Instance.sqlDeploymentPlan.features)
            languages = @($receipts | ForEach-Object {
                [PSCustomObject]@{ softwareId=$_.SoftwareId; variantId=$_.VariantId; status=$_.Status; runtimeVersion=$_.RuntimeVersion }
            })
            coldStart = @($coldStartProbes | ForEach-Object {
                [PSCustomObject]@{ language=$_.Language; status=$_.Status; runtimeVersion=$_.RuntimeVersion; workerIdentity=$_.WorkerIdentity }
            })
            completedAt = Get-LabTimestamp
        }
        $evidencePath = Join-Path $lab.RunDirectory 'external-runtime-hyperv-evidence.json'
        Write-LabArtifactJsonAtomic -Path $evidencePath -InputObject $evidence
        Write-Host "NATIVE_EVIDENCE_PATH=$evidencePath"

        if ($CleanupOnSuccess) {
            $cleanup = Remove-SqlServerLab -RunId $runId -StateRoot $lab.StateRoot -Force -Confirm:$false
            if ([string]$cleanup.Status -ne 'REMOVED') {
                throw "HYPERV_EXTERNAL_RUNTIME_CLEANUP_FAILED: $($cleanup.Status)"
            }
        }
        return $evidence
    }
    finally { Stop-Transcript -ErrorAction SilentlyContinue | Out-Null }
} $RunId $MediaRoot $ArtifactId $CleanupOnSuccess
