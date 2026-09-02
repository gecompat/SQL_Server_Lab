#Requires -Version 7.2
[CmdletBinding()]
param(
    [string]$RunId,
    [string]$CloneSourceRunId,
    [string]$MediaRoot = 'D:\Lab_Base',
    [string]$ArtifactId = 'hyperv-os-sealed-01f5d9a11f91ee9641eb2cde936431b4d6258333b4f7a0e6e51032df74878be5',
    [switch]$ReconcileAcceptance,
    [switch]$CleanupOnSuccess
)

$ErrorActionPreference = 'Stop'
if ($RunId -and $CloneSourceRunId) {
    throw 'HYPERV_EXTERNAL_RUNTIME_ACCEPTANCE_RUN_SOURCE_AMBIGUOUS'
}
if (-not $IsWindows -or -not (Get-Command Get-VM -ErrorAction SilentlyContinue)) {
    throw 'HYPERV_EXTERNAL_RUNTIME_ACCEPTANCE_REQUIRES_WINDOWS_HYPERV'
}
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$acceptanceManifestHelper = Join-Path $repoRoot 'Tests/Common/HyperVExternalRuntimeReconcileAcceptanceManifest.ps1'
Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force
$module = Get-Module SqlServerLab

& $module {
    param($RequestedRunId,$CloneSourceRunId,$MediaRoot,$ArtifactId,$ReconcileAcceptance,$CleanupOnSuccess,$ManifestHelperPath)

    . $ManifestHelperPath

    function New-ExternalRuntimeAcceptanceClone {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)][string]$SourceRunId,
            [Parameter(Mandatory)][string]$StateRoot
        )

        $sourceLab = Get-HyperVLabWorkflowRun -RunId $SourceRunId -StateRoot $StateRoot
        if ([string]$sourceLab.Instance.workload -ne 'windows' -or
            [string]$sourceLab.Instance.baseKind -ne 'windows-baseline' -or
            -not $sourceLab.Instance.windowsProvisioning -or
            [string]$sourceLab.Instance.windowsProvisioning.state -ne 'COMPLETE' -or
            $sourceLab.Instance.sqlDeploymentPlan) {
            throw 'HYPERV_EXTERNAL_RUNTIME_ACCEPTANCE_CLONE_REQUIRES_SPECIALIZED_WINDOWS_SOURCE'
        }

        $sourceVm = Get-HyperVManagedVM -VMName ([string]$sourceLab.Instance.vmName) `
            -ExpectedRunId ([string]$sourceLab.Run.runId) -ExpectedScopeId ([string]$sourceLab.Run.scopeId)
        if (-not $sourceVm -or [string]$sourceVm.VM.State -ne 'Off') {
            throw 'HYPERV_EXTERNAL_RUNTIME_ACCEPTANCE_CLONE_SOURCE_MUST_BE_OFF'
        }

        $sourceDisks = @(Get-VMHardDiskDrive -VMName ([string]$sourceLab.Instance.vmName) -ErrorAction Stop)
        if ($sourceDisks.Count -ne 1 -or -not $sourceDisks[0].Path -or
            [IO.Path]::GetExtension([string]$sourceDisks[0].Path) -ine '.vhdx') {
            throw 'HYPERV_EXTERNAL_RUNTIME_ACCEPTANCE_CLONE_SOURCE_DISK_INVALID'
        }
        $sourceDiskPath = [IO.Path]::GetFullPath([string]$sourceDisks[0].Path)
        if (-not (Test-HyperVPathWithinRunDirectory -Path $sourceDiskPath -RunDirectory $sourceLab.RunDirectory)) {
            throw 'HYPERV_EXTERNAL_RUNTIME_ACCEPTANCE_CLONE_SOURCE_SCOPE_VIOLATION'
        }
        $identityDiskPath = [IO.Path]::GetFullPath([string]$sourceVm.Identity.childVhdxPath)
        if (-not $sourceDiskPath.Equals($identityDiskPath, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'HYPERV_EXTERNAL_RUNTIME_ACCEPTANCE_CLONE_SOURCE_IDENTITY_MISMATCH'
        }

        $artifactId = [string]$sourceLab.Instance.imageArtifactId
        $artifact = Get-HyperVImageArtifact -ArtifactId $artifactId -StateRoot $StateRoot -SkipIntegrityCheck
        if (-not $artifact -or [string]$artifact.artifactState -ne 'OS_SEALED' -or
            -not [bool]$artifact.generalized -or [string]$artifact.license.type -ne 'evaluation') {
            throw 'HYPERV_EXTERNAL_RUNTIME_ACCEPTANCE_CLONE_REQUIRES_EVALUATION_ARTIFACT'
        }
        if ($artifact.license.evaluationExpiresAt -and
            ([datetime]$artifact.license.evaluationExpiresAt).ToUniversalTime() -le [datetime]::UtcNow) {
            throw 'HYPERV_EXTERNAL_RUNTIME_ACCEPTANCE_CLONE_EVALUATION_EXPIRED'
        }

        $guestPassword = Get-LabSecret -Path $sourceLab.RunDirectory -Name 'guest-administrator-password'
        if (-not $guestPassword) {
            throw 'HYPERV_EXTERNAL_RUNTIME_ACCEPTANCE_CLONE_GUEST_SECRET_MISSING'
        }
        $networkName = [string]$sourceLab.Instance.labNetwork.name
        if (-not $networkName) {
            throw 'HYPERV_EXTERNAL_RUNTIME_ACCEPTANCE_CLONE_NETWORK_REQUIRED'
        }
        $labNetwork = Resolve-LabHyperVNetwork -SwitchName $networkName

        $run = New-LabRunState -StateRoot $StateRoot -Metadata @{
            name = 'external-runtime-native-clone'; workflowKind = 'hyperv-lab'
            baseKind = 'managed-run-acceptance-clone'; workload = 'windows'; autostart = 'off'
            sourceRunId = $SourceRunId; imageArtifactId = $artifactId; network = $labNetwork.Name
            purpose = 'external-runtime-native-evidence'
        } -ProviderSubRuns @([PSCustomObject]@{
            id = 'provider-hyperv'; provider = 'hyperv'; instanceIds = @('sql2022-ext')
        })
        try {
            $null = New-CleanupPlan -RunDir $run.RunDir -RunId $run.RunId -ScopeId $run.ScopeId `
                -ProviderSubRuns @([PSCustomObject]@{
                    id = 'provider-hyperv'; provider = 'hyperv'; instanceIds = @('sql2022-ext')
                })
            $null = Set-LabRunState -RunId $run.RunId -NewState PROVISIONING `
                -Reason 'Isolierter External-Runtime-Acceptance-Clone wird erstellt.' -StateRoot $StateRoot
            Set-LabProviderSubRunState -RunId $run.RunId -Provider hyperv -NewState PROVISIONING `
                -Reason 'Spezialisierte Windows-Quelle wird unverändert kopiert.' -StateRoot $StateRoot

            $resourceBinding = Initialize-LabHyperVResourceBinding -ResourceId $run.RunId -ResourceClass Run `
                -StateDirectory $run.RunDir
            $resourceRoot = [string]$resourceBinding.HyperVResourceRoot
            $parentCopyPath = Assert-LabHyperVBoundPath -Binding $resourceBinding `
                -Path (Join-Path $resourceRoot 'sql2022-ext-source-parent.vhdx')
            $null = Add-CleanupStep -RunDir $run.RunDir -ResourceType vhdx -ResourceId $parentCopyPath `
                -Action remove -Provider hyperv -ProviderSubRunId provider-hyperv `
                -Compensation 'Remove isolated External Runtime acceptance parent copy'
            $null = New-Item -ItemType Directory -Path $resourceRoot -Force

            Write-Host "NATIVE_CLONE_SOURCE_RUN_ID=$SourceRunId"
            Write-LabInfo 'Acceptance-Clone: spezialisierte Quell-VHDX wird vollständig in den neuen Run kopiert.'
            Convert-VHD -Path $sourceDiskPath -DestinationPath $parentCopyPath -VHDType Dynamic -ErrorAction Stop
            if (-not (Test-Path -LiteralPath $parentCopyPath -PathType Leaf)) {
                throw 'HYPERV_EXTERNAL_RUNTIME_ACCEPTANCE_CLONE_COPY_POSTCONDITION_FAILED'
            }
            $parentItem = Get-Item -LiteralPath $parentCopyPath -Force
            $parentItem.IsReadOnly = $true
            $parentHash = (Get-FileHash -LiteralPath $parentCopyPath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()

            $vm = New-HyperVInstance -ParentVhdxPath $parentCopyPath -ParentSha256 $parentHash `
                -RunDirectory $run.RunDir -RunId $run.RunId -ScopeId $run.ScopeId -InstanceId 'sql2022-ext' `
                -LabName 'external-runtime-native-clone' -MemoryStartupBytes 8GB -ProcessorCount 4 `
                -AutoStart off -SwitchName $labNetwork.Name
            $connection = [PSCustomObject]@{
                schemaVersion = 1
                instances = @([PSCustomObject]@{
                    id = 'sql2022-ext'; provider = 'hyperv'; vmName = $vm.VMName; vmId = $vm.VMId
                    autostart = 'off'; workload = 'windows'; baseKind = 'managed-run-acceptance-clone'
                    imageArtifactId = $artifactId; sourceRunId = $SourceRunId
                    sourceParentCopyPath = $parentCopyPath; sourceParentSha256 = $parentHash
                    sqlVersion = $null; sqlEdition = $null; host = $null; port = $null
                    windowsProvisioning = [PSCustomObject]@{
                        state = 'COMPLETE'; mode = 'managed-run-acceptance-clone'
                        computerName = [string]$sourceLab.Instance.windowsProvisioning.computerName
                        imageState = [string]$sourceLab.Instance.windowsProvisioning.imageState
                        completedAt = Get-LabTimestamp
                    }
                    labNetwork = [PSCustomObject]@{
                        name = $labNetwork.Name; subnet = $labNetwork.Subnet
                        prefixLength = $labNetwork.PrefixLength; hostAddress = $labNetwork.HostAddress
                    }
                })
            }
            Save-LabSecret -Path $run.RunDir -Name 'guest-administrator-password' -Secret $guestPassword
            Write-LabArtifactJsonAtomic -Path (Join-Path $run.RunDir 'connection-info.json') -InputObject $connection

            foreach ($state in @('SQL_READY','DATABASES_CREATED','RUNNING','STOPPED')) {
                $null = Set-LabRunState -RunId $run.RunId -NewState $state `
                    -Reason "Acceptance-Clone: $state" -StateRoot $StateRoot
                Set-LabProviderSubRunState -RunId $run.RunId -Provider hyperv -NewState $state `
                    -Reason "Acceptance-Clone: $state" -StateRoot $StateRoot
            }
            return [PSCustomObject]@{
                RunId = $run.RunId; ScopeId = $run.ScopeId; StateRoot = $StateRoot
                VMName = $vm.VMName; SourceRunId = $SourceRunId; State = 'STOPPED'
            }
        }
        catch {
            try {
                $current = Get-LabRunState -RunId $run.RunId -StateRoot $StateRoot
                if ([string]$current.state -notin @('CLEANUP_PENDING','CLEANUP_RUNNING','CLEANED_UP','REMOVED')) {
                    $null = Set-LabRunState -RunId $run.RunId -NewState CLEANUP_PENDING `
                        -Reason 'Erstellung des isolierten External-Runtime-Acceptance-Clones fehlgeschlagen.' `
                        -StateRoot $StateRoot
                }
            }
            catch { }
            throw
        }
    }

    $stateRoot = Get-LabStateRoot
    $sqlMedia = Resolve-HyperVSqlInstallationMedia -MediaRoot $MediaRoot -SqlVersion 2022 `
        -MediaEdition Eval -SqlMediaPath 'SQL/2022/Eval/ISO/SQLServer2022-x64-ENU.iso'
    if ([string]$sqlMedia.HashStatus -ne 'SIDECAR_READY') {
        $sqlMedia = New-HyperVSqlMediaHashSidecar -MediaRoot $MediaRoot -SqlVersion 2022 `
            -MediaEdition Eval -SqlMediaPath 'SQL/2022/Eval/ISO/SQLServer2022-x64-ENU.iso' -Confirm:$false
    }
    if ([string]$sqlMedia.HashStatus -ne 'SIDECAR_READY') {
        throw 'HYPERV_EXTERNAL_RUNTIME_SQL_MEDIA_HASH_REQUIRED'
    }
    $null = Confirm-HyperVSqlInstallationMediaVersion -IsoPath $sqlMedia.IsoPath -SqlVersion 2022

    $plans = @()
    foreach ($softwareId in @('sql-python','sql-r','sql-java')) {
        $request = [PSCustomObject]@{
            Id=$softwareId; Version=$null; Variant=$null; InstallMethod=$null
            Packages=@(); RequestSource='native-evidence'
        }
        $plan = Resolve-LabExternalRuntimePlan -SoftwareItem $request -SqlVersion 2022 `
            -Provider hyperv -OperatingSystem windows
        if ([string]$plan.Status -ne 'RESOLVED') {
            throw "HYPERV_EXTERNAL_RUNTIME_CHARACTERIZATION_PLAN_UNEXPECTED: $softwareId / $($plan.ReasonCode)"
        }
        $plans += $plan
    }
    $runtimeMedia = @(Resolve-LabExternalRuntimeWindowsMedia -SoftwarePlans $plans -MediaRoot $MediaRoot -Acquire)
    if ($runtimeMedia.Count -lt 1) { throw 'HYPERV_EXTERNAL_RUNTIME_MEDIA_PREFLIGHT_EMPTY' }
    Write-Host "NATIVE_MEDIA_PREFLIGHT_COUNT=$($runtimeMedia.Count)"

    if ($RequestedRunId) {
        $lab = Get-HyperVLabWorkflowRun -RunId $RequestedRunId -StateRoot $stateRoot
    }
    elseif ($CloneSourceRunId) {
        $created = New-ExternalRuntimeAcceptanceClone -SourceRunId $CloneSourceRunId -StateRoot $stateRoot
        $lab = Get-HyperVLabWorkflowRun -RunId $created.RunId -StateRoot $stateRoot
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
        $reconcileEvidence = $null
        if ($ReconcileAcceptance) {
            $existingReceipts = @(Get-LabHyperVExternalRuntimeInstallationReceipts `
                -RunDirectory $lab.RunDirectory -InstanceId 'sql2022-ext')
            if ($existingReceipts.Count -gt 0 -or
                [string]$lab.Instance.externalRuntime.status -eq 'EXTENSIONS_READY_RUN') {
                throw 'HYPERV_EXTERNAL_RUNTIME_RECONCILE_ACCEPTANCE_BASELINE_NOT_EMPTY'
            }

            $baseManifestPath = Join-Path $lab.RunDirectory 'external-runtime-reconcile-base.json'
            $targetManifestPath = Join-Path $lab.RunDirectory 'external-runtime-reconcile-target.json'
            $baseManifest = Get-HyperVExternalRuntimeReconcileAcceptanceManifest
            $targetManifest = Get-HyperVExternalRuntimeReconcileAcceptanceManifest -IncludeSoftware
            Write-LabArtifactJsonAtomic -Path $baseManifestPath -InputObject $baseManifest
            Write-LabArtifactJsonAtomic -Path $targetManifestPath -InputObject $targetManifest
            foreach ($manifestPath in @($baseManifestPath,$targetManifestPath)) {
                $validation = Test-SqlServerLabManifest -Path $manifestPath
                if (-not $validation.IsValid) {
                    throw "HYPERV_EXTERNAL_RUNTIME_RECONCILE_ACCEPTANCE_MANIFEST_INVALID: $($validation.Errors -join '; ')"
                }
            }

            $resolvedBase = Read-LabManifest -Path $baseManifestPath
            $runState = Get-LabRunState -RunId $runId -StateRoot $lab.StateRoot
            $runState.metadata | Add-Member -NotePropertyName desiredState -NotePropertyValue `
                (New-LabDesiredStateSnapshot -ResolvedLab $resolvedBase -ProvisioningMode adhoc -PersistentData:$false) -Force
            Write-LabArtifactJsonAtomic -Path (Join-Path $lab.RunDirectory 'run-state.json') -InputObject $runState

            $journalPath = Get-LabHyperVExternalRuntimeReconcileJournalPath -RunDirectory $lab.RunDirectory
            if (Test-Path -LiteralPath $journalPath) {
                throw 'HYPERV_EXTERNAL_RUNTIME_RECONCILE_ACCEPTANCE_JOURNAL_PREEXISTS'
            }
            $bootBefore = [string]@(
                Invoke-HyperVPowerShellDirect -VMName ([string]$lab.Instance.vmName) `
                    -ExpectedRunId $runId -ExpectedScopeId ([string]$lab.Run.scopeId) -Credential $credential `
                    -ScriptBlock { (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o') }
            )[-1]
            $reconcilePlan = Get-SqlServerLabReconcilePlan -RunId $runId -ManifestPath $targetManifestPath `
                -InstanceId 'sql2022-ext' -StateRoot $lab.StateRoot
            if ([string]$reconcilePlan.HighestChangeClass -ne 'reprovision' -or
                [string]$reconcilePlan.Actions[0].Operation -ne 'InstallHyperVExternalRuntime' -or
                @($reconcilePlan.Desired.PlanKeys).Count -ne 3) {
                throw 'HYPERV_EXTERNAL_RUNTIME_RECONCILE_ACCEPTANCE_PLAN_INVALID'
            }
            $whatIf = Invoke-SqlServerLabReconcileAction -RunId $runId -ManifestPath $targetManifestPath `
                -InstanceId 'sql2022-ext' -SqlSaPassword $sqlPassword -MediaRoot $MediaRoot `
                -StateRoot $lab.StateRoot -WhatIf
            if ([string]$whatIf.ExecutionSummary.Status -ne 'WOULD_EXECUTE' -or
                (Test-Path -LiteralPath $journalPath)) {
                throw 'HYPERV_EXTERNAL_RUNTIME_RECONCILE_ACCEPTANCE_WHATIF_MUTATED'
            }
            $applied = Invoke-SqlServerLabReconcileAction -RunId $runId -ManifestPath $targetManifestPath `
                -InstanceId 'sql2022-ext' -SqlSaPassword $sqlPassword -MediaRoot $MediaRoot `
                -StateRoot $lab.StateRoot -Confirm:$false
            if ([string]$applied.ExecutionSummary.Status -ne 'SUCCEEDED' -or -not $applied.MutationAllowed) {
                throw "HYPERV_EXTERNAL_RUNTIME_RECONCILE_ACCEPTANCE_APPLY_FAILED: $($applied.ExecutionSummary.Errors -join '; ')"
            }
            $receipts = @(Get-LabHyperVExternalRuntimeInstallationReceipts `
                -RunDirectory $lab.RunDirectory -InstanceId 'sql2022-ext')
            $journal = Get-Content -LiteralPath $journalPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 40
            $noOpPlan = Get-SqlServerLabReconcilePlan -RunId $runId -ManifestPath $targetManifestPath `
                -InstanceId 'sql2022-ext' -StateRoot $lab.StateRoot
            $removalPlan = Get-SqlServerLabReconcilePlan -RunId $runId -ManifestPath $baseManifestPath `
                -InstanceId 'sql2022-ext' -StateRoot $lab.StateRoot
            $managedAfter = Get-HyperVManagedVM -VMName ([string]$lab.Instance.vmName) `
                -ExpectedRunId $runId -ExpectedScopeId ([string]$lab.Run.scopeId)
            $bootAfter = [string]@(
                Invoke-HyperVPowerShellDirect -VMName ([string]$lab.Instance.vmName) `
                    -ExpectedRunId $runId -ExpectedScopeId ([string]$lab.Run.scopeId) -Credential $credential `
                    -ScriptBlock { (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o') }
            )[-1]
            if ([string]$journal.Status -ne 'COMPLETED' -or -not $noOpPlan.IsNoOp -or
                [string]$removalPlan.HighestChangeClass -ne 'unsupported' -or
                'HYPERV_EXTERNAL_RUNTIME_REMOVAL_UNSUPPORTED' -notin @($removalPlan.Warnings) -or
                [string]$managedAfter.VM.State -ne 'Running' -or $bootAfter -ne $bootBefore) {
                throw 'HYPERV_EXTERNAL_RUNTIME_RECONCILE_ACCEPTANCE_POSTCONDITION_FAILED'
            }
            $reconcileEvidence = [PSCustomObject]@{
                planOperation = [string]$reconcilePlan.Actions[0].Operation
                whatIfStatus = [string]$whatIf.ExecutionSummary.Status
                applyStatus = [string]$applied.ExecutionSummary.Status
                journalStatus = [string]$journal.Status
                noOpVerified = [bool]$noOpPlan.IsNoOp
                removalReasonCode = 'HYPERV_EXTERNAL_RUNTIME_REMOVAL_UNSUPPORTED'
                vmRestartedDuringApply = $false
            }
        }
        else {
            $receipts = @(Install-LabHyperVExternalRuntimes -SoftwarePlans $plans -RunId $runId `
                -Credential $credential -SqlSaPassword $sqlPassword -MediaRoot $MediaRoot `
                -ResourceGovernorConfig ([PSCustomObject]@{ maxMemoryPercent=40; maxProcesses=32 }) `
                -StateRoot $lab.StateRoot)
        }
        if (@($receipts | Where-Object Status -ne 'EXTENSIONS_READY_RUN').Count -gt 0 -or $receipts.Count -ne 3) {
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
        if ($ReconcileAcceptance) {
            $evidence.contract.name = 'SqlServerLab.ExternalRuntimeHyperVReconcileAcceptance'
            $evidence | Add-Member -NotePropertyName reconcile -NotePropertyValue $reconcileEvidence
        }
        $evidencePath = Join-Path $lab.RunDirectory $(
            if($ReconcileAcceptance){'external-runtime-hyperv-reconcile-evidence.json'}else{'external-runtime-hyperv-evidence.json'}
        )
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
} $RunId $CloneSourceRunId $MediaRoot $ArtifactId $ReconcileAcceptance $CleanupOnSuccess $acceptanceManifestHelper
