<#
.SYNOPSIS
    Plant und reconciliert additive External Runtimes eines Hyper-V-SQL-Runs.
.DESCRIPTION
    Der Vertrag akzeptiert ausschliesslich neue, katalogisierte Python-, R- und
    Java-PlanKeys. Removal, Variantenwechsel und andere Manifestdrift bleiben
    fail-closed. Vor der Gastmutation wird ein VM- und Zielhash-gebundenes
    Journal persistiert. Die vorhandene idempotente Offline-Medieninstallation
    prueft anschliessend echte SQL-Postconditions; erst danach wird der Desired
    State fortgeschrieben. Teilfehler bleiben vorwaerts fortsetzbar.
#>

function Get-LabHyperVExternalRuntimeReconcileJournalPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunDirectory)
    Join-Path $RunDirectory 'hyperv-external-runtime-reconcile.local.journal.json'
}

function Get-LabHyperVExternalRuntimeTargetHash {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Plans)
    $canonical = [ordered]@{
        Contract = 'SqlServerLab.HyperVExternalRuntimeTarget/1.0'
        PlanKeys = @($Plans | ForEach-Object { ([string]$_.PlanKey).ToLowerInvariant() } | Sort-Object -Unique)
    } | ConvertTo-Json -Depth 10 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($canonical)
    return ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))).ToLowerInvariant()
}

function Assert-LabHyperVExternalRuntimeReconcileJournal {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Journal)
    $schemaPath = Join-Path $script:SchemasPath 'hyperv-external-runtime-reconcile-journal.schema.json'
    if (-not (($Journal | ConvertTo-Json -Depth 40) | Test-Json -SchemaFile $schemaPath -ErrorAction SilentlyContinue)) {
        throw 'HYPERV_EXTERNAL_RUNTIME_RECONCILE_JOURNAL_SCHEMA_INVALID'
    }
    return $true
}

function Write-LabHyperVExternalRuntimeReconcileJournal {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Journal, [Parameter(Mandatory)][string]$Path)
    $Journal.UpdatedAt = Get-LabTimestamp
    $null = Assert-LabHyperVExternalRuntimeReconcileJournal -Journal $Journal
    Write-LabArtifactJsonAtomic -Path $Path -InputObject $Journal
    return $Journal
}

function Set-LabHyperVExternalRuntimeReconcileJournalStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Journal,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidateSet('PREPARED','INSTALLING','VERIFIED','DESIRED_STATE_UPDATED','COMPLETED','RECOVERY_REQUIRED')][string]$Status,
        [string]$ErrorCode
    )
    $Journal.Status = $Status
    if ($ErrorCode) {
        $Journal.Recovery.ErrorCode = $ErrorCode
        $Journal.Recovery.Errors = @($Journal.Recovery.Errors) + @($ErrorCode)
    }
    if ($Status -eq 'COMPLETED') { $Journal.Recovery.Status = 'NOT_REQUIRED' }
    elseif ($Status -eq 'RECOVERY_REQUIRED') { $Journal.Recovery.Status = 'RETRY_HYPERV_EXTERNAL_RUNTIME_RECONCILE' }
    return Write-LabHyperVExternalRuntimeReconcileJournal -Journal $Journal -Path $Path
}

function Read-LabHyperVExternalRuntimeReconcileJournal {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Context)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $journal = Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json -Depth 40
    $null = Assert-LabHyperVExternalRuntimeReconcileJournal -Journal $journal
    if ([string]$journal.RunId -ne [string]$Context.RunId -or
        [string]$journal.ScopeId -ne [string]$Context.ScopeId -or
        [string]$journal.InstanceId -ne [string]$Context.InstanceId -or
        [string]$journal.Runtime.VMId -ne [string]$Context.VM.Id) {
        throw 'HYPERV_EXTERNAL_RUNTIME_RECONCILE_JOURNAL_IDENTITY_MISMATCH'
    }
    if ([string]$journal.TargetHash -ne [string]$Context.TargetHash) {
        if ([string]$journal.Status -eq 'COMPLETED') { return $null }
        throw 'HYPERV_EXTERNAL_RUNTIME_RECONCILE_JOURNAL_TARGET_MISMATCH'
    }
    return $journal
}

function Get-LabHyperVExternalRuntimeInstallationReceipts {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunDirectory, [Parameter(Mandatory)][string]$InstanceId)
    $path = Join-Path $RunDirectory 'software-installation-receipts.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return @() }
    $document = Get-Content -LiteralPath $path -Raw -Encoding utf8 | ConvertFrom-Json -Depth 50
    if (-not $document.contract -or [string]$document.contract.name -ne 'SqlServerLab.RunSoftwareInstallationReceipts' -or
        [string]$document.contract.version -ne '1.0') {
        throw 'HYPERV_EXTERNAL_RUNTIME_RECONCILE_RECEIPT_DOCUMENT_INVALID'
    }
    $instances = @($document.instances | Where-Object { [string]$_.instanceId -eq $InstanceId })
    if ($instances.Count -gt 1) { throw 'HYPERV_EXTERNAL_RUNTIME_RECONCILE_RECEIPT_INSTANCE_DUPLICATE' }
    if ($instances.Count -eq 0) { return @() }
    $receipts = @($instances[0].receipts)
    foreach ($receipt in $receipts) {
        if (-not $receipt.Contract -or [string]$receipt.Contract.Name -ne 'SqlServerLab.SoftwareInstallationReceipt' -or
            [string]$receipt.Contract.Version -ne '1.0' -or [string]$receipt.Provider -ne 'hyperv' -or
            [string]$receipt.Status -ne 'EXTENSIONS_READY_RUN' -or [string]$receipt.PlanKey -notmatch '^[a-f0-9]{64}$') {
            throw 'HYPERV_EXTERNAL_RUNTIME_RECONCILE_RECEIPT_INVALID'
        }
    }
    if (@($receipts | Group-Object SoftwareId | Where-Object Count -gt 1).Count -gt 0) {
        throw 'HYPERV_EXTERNAL_RUNTIME_RECONCILE_RECEIPT_SOFTWARE_DUPLICATE'
    }
    return @($receipts | Sort-Object SoftwareId)
}

function Get-LabHyperVExternalRuntimeReconcileCredentials {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunDirectory, [SecureString]$SqlSaPassword)
    $guestPassword = Get-LabSecret -Path $RunDirectory -Name 'guest-administrator-password'
    if (-not $SqlSaPassword) { $SqlSaPassword = Get-LabSecret -Path $RunDirectory -Name 'generated-sql-sa-password' }
    if (-not $SqlSaPassword) { $SqlSaPassword = Get-LabSecret -Path $RunDirectory -Name 'sa-password' }
    if (-not $guestPassword -or -not $SqlSaPassword) {
        throw 'HYPERV_EXTERNAL_RUNTIME_RECONCILE_CREDENTIAL_REQUIRED'
    }
    $warnings = @($unsupportedReasons)
    if (-not $isNoOp -and $unsupportedReasons.Count -eq 0) {
        $warnings += 'SQL Server und Launchpad werden im Gast kontrolliert neu gestartet; die VM bleibt gestartet.'
    }
    return [PSCustomObject]@{
        GuestCredential = [PSCredential]::new('Administrator', $guestPassword)
        SqlSaPassword = $SqlSaPassword
    }
}

function Get-LabHyperVExternalRuntimeInstanceFingerprint {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Instance)
    return [ordered]@{
        Id=[string]$Instance.Id;Provider=[string]$Instance.Provider;Version=[string]$Instance.Version
        Profile=[string]$Instance.Profile;AutoStart=[string]$Instance.AutoStart;DatabaseNames=@($Instance.DatabaseNames)
        Drives=@($Instance.Intents.Drives);Network=$Instance.Intents.Network;Resources=$Instance.Intents.Resources
        SqlEndpoint=$Instance.Intents.SqlEndpoint;SqlConfiguration=$Instance.Intents.SqlConfiguration
        Databases=$Instance.Intents.Databases;Storage=$Instance.Intents.Storage
    }
}

function Get-LabHyperVExternalRuntimeReconcileContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$ManifestPath,
        [Parameter(Mandatory)][string]$InstanceId,
        [string]$StateRoot
    )
    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
    $run = Get-LabRunState -RunId $RunId -StateRoot $StateRoot
    if ([string]$run.metadata.workflowKind -ne 'hyperv-lab') { throw 'HYPERV_EXTERNAL_RUNTIME_RECONCILE_HYPERV_RUN_REQUIRED' }
    if ([string]$run.state -ne 'RUNNING') { throw "HYPERV_EXTERNAL_RUNTIME_RECONCILE_RUN_NOT_RUNNING: $($run.state)" }
    $guard = Get-LabHyperVResourceMigrationLifecycleGuard -RunId $RunId -StateRoot $StateRoot
    if (-not $guard.Allowed) { throw "HYPERV_EXTERNAL_RUNTIME_RECONCILE_MIGRATION_BLOCKED: $([string]$guard.ReasonCode)" }
    $persisted = Get-LabPersistedDesiredState -RunId $RunId -StateRoot $StateRoot
    if ([string]$persisted.Status -ne 'VALID') { throw 'HYPERV_EXTERNAL_RUNTIME_RECONCILE_DESIRED_STATE_INVALID' }
    $resolved = Read-LabManifest -Path $ManifestPath
    $desiredSnapshot = New-LabDesiredStateSnapshot -ResolvedLab $resolved `
        -ProvisioningMode ([string]$persisted.Snapshot.ProvisioningMode) -PersistentData ([bool]$persisted.Snapshot.PersistentData)
    if ([string]$resolved.name -ne [string]$persisted.Snapshot.LabName) { throw 'HYPERV_EXTERNAL_RUNTIME_RECONCILE_LAB_IDENTITY_CHANGED' }
    $currentIds = @($persisted.Snapshot.Instances | ForEach-Object { [string]$_.Id } | Sort-Object)
    $targetIds = @($desiredSnapshot.Instances | ForEach-Object { [string]$_.Id } | Sort-Object)
    if (($currentIds -join ',') -cne ($targetIds -join ',')) { throw 'HYPERV_EXTERNAL_RUNTIME_RECONCILE_INSTANCE_SET_CHANGED' }
    $currentInstances = @($persisted.Snapshot.Instances | Where-Object { [string]$_.Id -eq $InstanceId })
    $targetInstances = @($desiredSnapshot.Instances | Where-Object { [string]$_.Id -eq $InstanceId })
    $resolvedInstances = @($resolved.instances | Where-Object { [string]$_.id -eq $InstanceId })
    if ($currentInstances.Count -ne 1 -or $targetInstances.Count -ne 1 -or $resolvedInstances.Count -ne 1) {
        throw 'HYPERV_EXTERNAL_RUNTIME_RECONCILE_TARGET_NOT_UNIQUE'
    }
    if ([string]$targetInstances[0].Provider -ne 'hyperv') { throw 'HYPERV_EXTERNAL_RUNTIME_RECONCILE_PROVIDER_UNSUPPORTED' }
    foreach ($other in @($persisted.Snapshot.Instances | Where-Object { [string]$_.Id -ne $InstanceId })) {
        $targetOther = @($desiredSnapshot.Instances | Where-Object { [string]$_.Id -eq [string]$other.Id })
        if ($targetOther.Count -ne 1 -or (($other | ConvertTo-Json -Depth 50 -Compress) -cne ($targetOther[0] | ConvertTo-Json -Depth 50 -Compress))) {
            throw "HYPERV_EXTERNAL_RUNTIME_RECONCILE_OTHER_INSTANCE_CHANGED: $($other.Id)"
        }
    }
    $currentFingerprint = (Get-LabHyperVExternalRuntimeInstanceFingerprint -Instance $currentInstances[0]) | ConvertTo-Json -Depth 50 -Compress
    $targetFingerprint = (Get-LabHyperVExternalRuntimeInstanceFingerprint -Instance $targetInstances[0]) | ConvertTo-Json -Depth 50 -Compress
    if ($currentFingerprint -cne $targetFingerprint) { throw 'HYPERV_EXTERNAL_RUNTIME_RECONCILE_NON_SOFTWARE_DRIFT' }
    $desiredPlans = @(Resolve-LabExternalRuntimePlansForInstance -Instance $resolvedInstances[0])
    if (@($desiredPlans | Where-Object Status -ne 'RESOLVED').Count -gt 0) {
        throw 'HYPERV_EXTERNAL_RUNTIME_RECONCILE_DESIRED_PLAN_UNRESOLVED'
    }
    if (@($desiredPlans | Group-Object SoftwareId | Where-Object Count -gt 1).Count -gt 0) {
        throw 'HYPERV_EXTERNAL_RUNTIME_RECONCILE_DESIRED_SOFTWARE_DUPLICATE'
    }

    $runDirectory = Join-Path (Join-Path $StateRoot 'runs') $RunId
    $connectionPath = Join-Path $runDirectory 'connection-info.json'
    if (-not (Test-Path -LiteralPath $connectionPath -PathType Leaf)) { throw 'HYPERV_EXTERNAL_RUNTIME_RECONCILE_CONNECTION_MISSING' }
    $connection = Get-Content -LiteralPath $connectionPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 50
    $connectionInstances = @($connection.instances | Where-Object { [string]$_.id -eq $InstanceId -and [string]$_.provider -eq 'hyperv' })
    if ($connectionInstances.Count -ne 1 -or -not $connectionInstances[0].vmName) {
        throw 'HYPERV_EXTERNAL_RUNTIME_RECONCILE_CONNECTION_INSTANCE_NOT_UNIQUE'
    }
    $managed = Get-HyperVManagedVM -VMName ([string]$connectionInstances[0].vmName) `
        -ExpectedRunId $RunId -ExpectedScopeId ([string]$run.scopeId)
    if (-not $managed -or [string]$managed.VM.State -ne 'Running') { throw 'HYPERV_EXTERNAL_RUNTIME_RECONCILE_VM_RUNNING_REQUIRED' }
    if ($connectionInstances[0].vmId -and [string]$connectionInstances[0].vmId -ne [string]$managed.VM.Id) {
        throw 'HYPERV_EXTERNAL_RUNTIME_RECONCILE_VM_IDENTITY_MISMATCH'
    }
    $currentReceipts = @(Get-LabHyperVExternalRuntimeInstallationReceipts -RunDirectory $runDirectory -InstanceId $InstanceId)
    $targetHash = Get-LabHyperVExternalRuntimeTargetHash -Plans $desiredPlans
    $context = [PSCustomObject]@{
        RunId=$RunId;ScopeId=[string]$run.scopeId;InstanceId=$InstanceId;StateRoot=$StateRoot;Run=$run
        RunDirectory=$runDirectory;ConnectionPath=$connectionPath;Connection=$connection;ConnectionInstance=$connectionInstances[0]
        VM=$managed.VM;Managed=$managed;PersistedSnapshot=$persisted.Snapshot;DesiredSnapshot=$desiredSnapshot
        ResolvedManifest=$resolved;ResolvedInstance=$resolvedInstances[0];DesiredPlans=$desiredPlans;CurrentReceipts=$currentReceipts
        TargetHash=$targetHash
    }
    $journalPath = Get-LabHyperVExternalRuntimeReconcileJournalPath -RunDirectory $runDirectory
    $journal = Read-LabHyperVExternalRuntimeReconcileJournal -Path $journalPath -Context $context
    $runtimeStatus = [string]$connectionInstances[0].externalRuntime.status
    if ($currentReceipts.Count -gt 0 -and $runtimeStatus -ne 'EXTENSIONS_READY_RUN' -and
        (-not $journal -or [string]$journal.Status -eq 'COMPLETED')) {
        throw "HYPERV_EXTERNAL_RUNTIME_RECONCILE_CURRENT_RUNTIME_NOT_READY: $runtimeStatus"
    }
    if ($currentReceipts.Count -eq 0 -and $runtimeStatus -eq 'EXTENSIONS_READY_RUN') {
        throw 'HYPERV_EXTERNAL_RUNTIME_RECONCILE_READY_RECEIPTS_MISSING'
    }
    $context | Add-Member -NotePropertyName JournalPath -NotePropertyValue $journalPath
    $context | Add-Member -NotePropertyName Journal -NotePropertyValue $journal
    return $context
}

function New-LabHyperVExternalRuntimeReconcilePlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$ManifestPath,
        [Parameter(Mandatory)][string]$InstanceId,
        [string]$StateRoot
    )
    $context = Get-LabHyperVExternalRuntimeReconcileContext @PSBoundParameters
    $currentIds = @($context.CurrentReceipts | ForEach-Object { [string]$_.SoftwareId })
    $desiredIds = @($context.DesiredPlans | ForEach-Object { [string]$_.SoftwareId })
    $removed = @($context.CurrentReceipts | Where-Object { [string]$_.SoftwareId -notin $desiredIds })
    $changed = @($context.DesiredPlans | Where-Object {
        $desired = $_
        @($context.CurrentReceipts | Where-Object {
            [string]$_.SoftwareId -eq [string]$desired.SoftwareId -and [string]$_.PlanKey -ne [string]$desired.PlanKey
        }).Count -gt 0
    })
    $additions = @($context.DesiredPlans | Where-Object { [string]$_.SoftwareId -notin $currentIds })
    $unsupportedReasons = @(
        if ($removed.Count -gt 0) { 'HYPERV_EXTERNAL_RUNTIME_REMOVAL_UNSUPPORTED' }
        if ($changed.Count -gt 0) { 'HYPERV_EXTERNAL_RUNTIME_VARIANT_CHANGE_UNSUPPORTED' }
    )
    $resumeRequired = $context.Journal -and [string]$context.Journal.Status -ne 'COMPLETED'
    $currentKeys = @($context.CurrentReceipts.PlanKey | Sort-Object -Unique)
    $desiredKeys = @($context.DesiredPlans.PlanKey | Sort-Object -Unique)
    $isNoOp = $unsupportedReasons.Count -eq 0 -and -not $resumeRequired -and
        (($currentKeys -join ',') -ceq ($desiredKeys -join ','))
    $preview = Get-LabExternalRuntimePlanPreview -DesiredPlans $context.DesiredPlans -CurrentPlans $context.CurrentReceipts
    $action = if ($unsupportedReasons.Count -gt 0 -or $isNoOp) { @() } else {
        @([PSCustomObject]@{
            Operation=if ($resumeRequired) { 'ResumeHyperVExternalRuntime' } elseif ($currentKeys.Count -eq 0) { 'InstallHyperVExternalRuntime' } else { 'AddHyperVExternalRuntime' }
            Provider='hyperv';InstanceId=$InstanceId;ChangeClass='reprovision';TargetHash=[string]$context.TargetHash
        })
    }
    return [PSCustomObject]@{
        Contract=[PSCustomObject]@{Name='SqlServerLab.ReconcilePlan';Version='1.1'}
        RunId=$RunId;PlanKind='ExternalRuntime';InstanceId=$InstanceId
        Desired=[PSCustomObject]@{
            Provider='hyperv';SqlVersion=[string]$context.ConnectionInstance.sqlVersion;PlanKeys=$desiredKeys;ImageKey=$null
            Software=@($context.DesiredPlans | Sort-Object SoftwareId | ForEach-Object {
                [PSCustomObject]@{SoftwareId=[string]$_.SoftwareId;VariantId=[string]$_.VariantId;RuntimeVersion=[string]$_.RuntimeVersion;PlanKey=[string]$_.PlanKey}
            })
        }
        Actual=[PSCustomObject]@{State='RUNNING';Provider='hyperv';PlanKeys=$currentKeys;ImageKey=$null;RuntimeStatus=[string]$context.ConnectionInstance.externalRuntime.status}
        Diff=@(
            @($preview.Entries | ForEach-Object {
                [PSCustomObject]@{SoftwareId=[string]$_.SoftwareId;PlanKey=[string]$_.PlanKey;ChangeClassification=$_.ChangeClassification;Downtime=[string]$_.Downtime;Supported=([string]$_.SoftwareId -notin @($changed.SoftwareId))}
            }) +
            @($removed | ForEach-Object {
                [PSCustomObject]@{SoftwareId=[string]$_.SoftwareId;PlanKey=[string]$_.PlanKey;ChangeClassification=[PSCustomObject]@{Artifact='none';Service='none';Activation='none';Highest='unsupported';Intent='remove'};Downtime='unknown';Supported=$false}
            })
        )
        Actions=$action;HighestChangeClass=if($unsupportedReasons.Count -gt 0){'unsupported'}elseif($isNoOp){'no-op'}else{'reprovision'}
        IsNoOp=[bool]$isNoOp;MutationAllowed=$false
        Warnings=$warnings
    }
}

function Invoke-LabHyperVExternalRuntimeReconcileRepair {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$ManifestPath,
        [Parameter(Mandatory)][string]$InstanceId,
        [SecureString]$SqlSaPassword,
        [string]$MediaRoot,
        [string]$StateRoot
    )
    $context = Get-LabHyperVExternalRuntimeReconcileContext -RunId $RunId -ManifestPath $ManifestPath -InstanceId $InstanceId -StateRoot $StateRoot
    $plan = New-LabHyperVExternalRuntimeReconcilePlan -RunId $RunId -ManifestPath $ManifestPath -InstanceId $InstanceId -StateRoot $StateRoot
    if ($plan.HighestChangeClass -eq 'unsupported') { throw "HYPERV_EXTERNAL_RUNTIME_RECONCILE_UNSUPPORTED: $($plan.Warnings -join ', ')" }
    if ($plan.IsNoOp) { return [PSCustomObject]@{Status='NO_OP';RunId=$RunId;InstanceId=$InstanceId;Provider='hyperv';Changed=$false;PlanKeys=@($plan.Desired.PlanKeys)} }
    if (-not $MediaRoot) { $MediaRoot = Get-LabMediaRootDefault }
    if (-not $MediaRoot) { throw 'HYPERV_EXTERNAL_RUNTIME_RECONCILE_MEDIA_ROOT_REQUIRED' }
    $journal = $context.Journal
    if (-not $journal) {
        $currentIds = @($context.CurrentReceipts.SoftwareId)
        $journal = [PSCustomObject]@{
            ContractVersion='SqlServerLab.HyperVExternalRuntimeReconcileJournal/1.0';OperationId=[guid]::NewGuid().ToString('D')
            RunId=$RunId;ScopeId=[string]$context.ScopeId;InstanceId=$InstanceId;Provider='hyperv';ChangeClass='reprovision'
            Status='PREPARED';TargetHash=[string]$context.TargetHash;Runtime=[PSCustomObject]@{VMId=[string]$context.VM.Id}
            PreviousPlanKeys=@($context.CurrentReceipts.PlanKey | Sort-Object -Unique);DesiredPlanKeys=@($context.DesiredPlans.PlanKey | Sort-Object -Unique)
            Additions=@($context.DesiredPlans | Where-Object { [string]$_.SoftwareId -notin $currentIds } | Sort-Object SoftwareId | ForEach-Object {
                [PSCustomObject]@{SoftwareId=[string]$_.SoftwareId;PlanKey=[string]$_.PlanKey;Status='PENDING'}
            })
            Recovery=[PSCustomObject]@{Status='NOT_REQUIRED';Attempts=0;ErrorCode=$null;Errors=@()};UpdatedAt=Get-LabTimestamp
        }
        $journal = Write-LabHyperVExternalRuntimeReconcileJournal -Journal $journal -Path $context.JournalPath
    }
    elseif ([string]$journal.Status -eq 'RECOVERY_REQUIRED') {
        $journal.Recovery.Attempts = [int]$journal.Recovery.Attempts + 1
        $journal.Recovery.ErrorCode = $null
        $journal.Recovery.Status = 'NOT_REQUIRED'
        $journal = Write-LabHyperVExternalRuntimeReconcileJournal -Journal $journal -Path $context.JournalPath
    }

    try {
        if ([string]$journal.Status -notin @('VERIFIED','DESIRED_STATE_UPDATED','COMPLETED')) {
            $credentials = Get-LabHyperVExternalRuntimeReconcileCredentials -RunDirectory $context.RunDirectory -SqlSaPassword $SqlSaPassword
            foreach ($addition in @($journal.Additions)) { if ([string]$addition.Status -ne 'APPLIED') { $addition.Status = 'APPLYING' } }
            $journal = Set-LabHyperVExternalRuntimeReconcileJournalStatus -Journal $journal -Path $context.JournalPath -Status INSTALLING
            $receipts = @(Install-LabHyperVExternalRuntimes -SoftwarePlans $context.DesiredPlans -RunId $RunId `
                -Credential $credentials.GuestCredential -SqlSaPassword $credentials.SqlSaPassword -MediaRoot $MediaRoot `
                -ResourceGovernorConfig $context.ResolvedInstance.serverConfig.externalScripts.resourceGovernor -StateRoot $context.StateRoot)
            $receiptKeys = @($receipts.PlanKey | Sort-Object -Unique)
            if (($receiptKeys -join ',') -cne (@($context.DesiredPlans.PlanKey | Sort-Object -Unique) -join ',')) {
                throw 'HYPERV_EXTERNAL_RUNTIME_RECONCILE_POSTCONDITION_PLAN_KEYS_MISMATCH'
            }
            foreach ($addition in @($journal.Additions)) { $addition.Status = 'APPLIED' }
            $journal = Set-LabHyperVExternalRuntimeReconcileJournalStatus -Journal $journal -Path $context.JournalPath -Status VERIFIED
        }
        if ([string]$journal.Status -eq 'VERIFIED') {
            $currentReceipts = @(Get-LabHyperVExternalRuntimeInstallationReceipts -RunDirectory $context.RunDirectory -InstanceId $InstanceId)
            if ((@($currentReceipts.PlanKey | Sort-Object -Unique) -join ',') -cne (@($context.DesiredPlans.PlanKey | Sort-Object -Unique) -join ',')) {
                throw 'HYPERV_EXTERNAL_RUNTIME_RECONCILE_PERSISTED_RECEIPTS_MISMATCH'
            }
            $connection = Get-Content -LiteralPath $context.ConnectionPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 50
            $connectionInstance = @($connection.instances | Where-Object { [string]$_.id -eq $InstanceId -and [string]$_.provider -eq 'hyperv' })
            if ($connectionInstance.Count -ne 1 -or [string]$connectionInstance[0].externalRuntime.status -ne 'EXTENSIONS_READY_RUN' -or
                (@($connectionInstance[0].externalRuntime.receipts.PlanKey | Sort-Object -Unique) -join ',') -cne (@($context.DesiredPlans.PlanKey | Sort-Object -Unique) -join ',')) {
                throw 'HYPERV_EXTERNAL_RUNTIME_RECONCILE_CONNECTION_POSTCONDITION_FAILED'
            }
            $context.Run.metadata.desiredState = $context.DesiredSnapshot
            Write-LabArtifactJsonAtomic -Path (Join-Path $context.RunDirectory 'run-state.json') -InputObject $context.Run
            $journal = Set-LabHyperVExternalRuntimeReconcileJournalStatus -Journal $journal -Path $context.JournalPath -Status DESIRED_STATE_UPDATED
        }
        $journal = Set-LabHyperVExternalRuntimeReconcileJournalStatus -Journal $journal -Path $context.JournalPath -Status COMPLETED
        return [PSCustomObject]@{Status='SUCCEEDED';RunId=$RunId;InstanceId=$InstanceId;Provider='hyperv';Changed=$true;PlanKeys=@($context.DesiredPlans.PlanKey | Sort-Object -Unique)}
    }
    catch {
        $failure = $_
        $errorCode = if ($failure.Exception.Message -match '^[A-Z0-9_]+' ) { $Matches[0] } else { 'HYPERV_EXTERNAL_RUNTIME_RECONCILE_FAILED' }
        try { $null = Set-LabHyperVExternalRuntimeReconcileJournalStatus -Journal $journal -Path $context.JournalPath -Status RECOVERY_REQUIRED -ErrorCode $errorCode } catch { }
        throw $failure
    }
}
