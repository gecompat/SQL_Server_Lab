<#
.SYNOPSIS
    Fail-closed Planungs- und Ausfuehrungsvertrag fuer External-Runtime-Container-Refresh.
.DESCRIPTION
    Ein Refresh baut zuerst ein neues inhaltsadressiertes Image, erstellt danach
    einen Ersatzcontainer unter demselben Run-Scope und schaltet erst nach echten
    SQL-Postconditions um. Ein lokales Journal erlaubt Rollback bzw. Abschluss
    nach einer Unterbrechung. Alte Images bleiben als wiederverwendbare Artefakte
    erhalten; der alte Container wird erst nach persistiertem State entfernt.
#>

function Get-LabExternalRuntimeReconcileContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$ManifestPath,
        [string]$InstanceId,
        [string]$StateRoot
    )

    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
    $run = Get-LabRunState -RunId $RunId -StateRoot $StateRoot
    if ([string]$run.state -ne 'RUNNING') {
        throw "EXTERNAL_RUNTIME_RECONCILE_RUN_NOT_RUNNING: $($run.state)"
    }
    $persisted = Get-LabPersistedDesiredState -RunId $RunId -StateRoot $StateRoot
    if ([string]$persisted.Status -ne 'VALID') {
        throw "EXTERNAL_RUNTIME_RECONCILE_DESIRED_STATE_INVALID: $($persisted.Status) $($persisted.Reason)"
    }

    $resolved = Read-LabManifest -Path $ManifestPath
    $desiredSnapshot = New-LabDesiredStateSnapshot -ResolvedLab $resolved `
        -ProvisioningMode ([string]$persisted.Snapshot.ProvisioningMode) `
        -PersistentData ([bool]$persisted.Snapshot.PersistentData)
    if ([string]$resolved.name -ne [string]$persisted.Snapshot.LabName) {
        throw 'EXTERNAL_RUNTIME_RECONCILE_LAB_IDENTITY_CHANGED'
    }
    $currentIds = @($persisted.Snapshot.Instances | ForEach-Object { [string]$_.Id } | Sort-Object)
    $desiredIds = @($desiredSnapshot.Instances | ForEach-Object { [string]$_.Id } | Sort-Object)
    if (($currentIds -join ',') -ne ($desiredIds -join ',')) {
        throw 'EXTERNAL_RUNTIME_RECONCILE_INSTANCE_SET_CHANGED'
    }

    $runDirectory = Join-Path (Join-Path $StateRoot 'runs') $RunId
    $connectionPath = Join-Path $runDirectory 'connection-info.json'
    if (-not (Test-Path -LiteralPath $connectionPath -PathType Leaf)) {
        throw 'EXTERNAL_RUNTIME_RECONCILE_CONNECTION_INFO_MISSING'
    }
    $connection = Get-Content -LiteralPath $connectionPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 50
    $eligible = @($connection.instances | Where-Object {
        [string]$_.provider -in @('docker', 'podman')
    })
    if ($InstanceId) {
        $eligible = @($eligible | Where-Object { [string]$_.id -eq $InstanceId })
    }
    if ($eligible.Count -ne 1) {
        throw "EXTERNAL_RUNTIME_RECONCILE_INSTANCE_NOT_UNIQUE: $($eligible.Count)"
    }
    $connectionInstance = $eligible[0]
    $InstanceId = [string]$connectionInstance.id
    if ($connectionInstance.externalRuntime -and
        [string]$connectionInstance.externalRuntime.Status -ne 'EXTENSIONS_READY_RUN') {
        throw "EXTERNAL_RUNTIME_RECONCILE_CURRENT_RUNTIME_NOT_READY: $($connectionInstance.externalRuntime.Status)"
    }
    $currentSnapshot = @($persisted.Snapshot.Instances | Where-Object { [string]$_.Id -eq $InstanceId })
    $targetSnapshot = @($desiredSnapshot.Instances | Where-Object { [string]$_.Id -eq $InstanceId })
    $targetResolved = @($resolved.instances | Where-Object { [string]$_.id -eq $InstanceId })
    if ($currentSnapshot.Count -ne 1 -or $targetSnapshot.Count -ne 1 -or $targetResolved.Count -ne 1) {
        throw 'EXTERNAL_RUNTIME_RECONCILE_TARGET_MISSING'
    }

    $toImmutableFingerprint = {
        param($item)
        [ordered]@{
            Id=[string]$item.Id; Provider=[string]$item.Provider; Version=[string]$item.Version
            Profile=[string]$item.Profile; AutoStart=[string]$item.AutoStart
            DatabaseNames=@($item.DatabaseNames | Sort-Object)
            Drives=@($item.Intents.Drives); Network=$item.Intents.Network
        }
    }
    $currentFingerprint = (& $toImmutableFingerprint $currentSnapshot[0]) | ConvertTo-Json -Depth 30 -Compress
    $targetFingerprint = (& $toImmutableFingerprint $targetSnapshot[0]) | ConvertTo-Json -Depth 30 -Compress
    if ($currentFingerprint -cne $targetFingerprint) {
        throw 'EXTERNAL_RUNTIME_RECONCILE_NON_SOFTWARE_DRIFT'
    }
    foreach ($currentOther in @($persisted.Snapshot.Instances | Where-Object { [string]$_.Id -ne $InstanceId })) {
        $desiredOther = @($desiredSnapshot.Instances | Where-Object { [string]$_.Id -eq [string]$currentOther.Id })
        if ($desiredOther.Count -ne 1) { throw 'EXTERNAL_RUNTIME_RECONCILE_INSTANCE_SET_CHANGED' }
        $normalizeOther = {
            param($item)
            [ordered]@{
                Immutable=(& $toImmutableFingerprint $item)
                Software=@($item.Intents.Software.Items | Sort-Object Id | ForEach-Object {
                    [ordered]@{
                        Id=[string]$_.Id; VariantId=[string]$_.VariantId; RuntimeVersion=[string]$_.RuntimeVersion
                        InstallationMethod=[string]$_.InstallationMethod; Status=[string]$_.Status
                    }
                })
            }
        }
        if (((& $normalizeOther $currentOther) | ConvertTo-Json -Depth 30 -Compress) -cne
            ((& $normalizeOther $desiredOther[0]) | ConvertTo-Json -Depth 30 -Compress)) {
            throw "EXTERNAL_RUNTIME_RECONCILE_OTHER_INSTANCE_CHANGED: $($currentOther.Id)"
        }
    }
    if ([string]$targetSnapshot[0].Provider -notin @('docker', 'podman') -or
        [string]$targetSnapshot[0].Version -notin @('2019', '2022', '2025')) {
        throw 'EXTERNAL_RUNTIME_RECONCILE_PROVIDER_OR_VERSION_UNSUPPORTED'
    }

    $desiredPlans = @(Resolve-LabExternalRuntimePlansForInstance -Instance $targetResolved[0])
    if (@($desiredPlans | Where-Object Status -ne 'RESOLVED').Count -gt 0) {
        throw 'EXTERNAL_RUNTIME_RECONCILE_DESIRED_PLAN_UNRESOLVED'
    }
    $currentPlans = if ($connectionInstance.externalRuntime) {
        @($connectionInstance.externalRuntime.Receipts | ForEach-Object {
            [PSCustomObject]@{
                SoftwareId=[string]$_.SoftwareId; PlanKey=[string]$_.PlanKey
                VariantId=[string]$_.VariantId; RuntimeVersion=[string]$_.RuntimeVersion
            }
        })
    }
    else { @() }
    if (@($currentPlans | Where-Object { $_.PlanKey -notmatch '^[a-f0-9]{64}$' }).Count -gt 0) {
        throw 'EXTERNAL_RUNTIME_RECONCILE_CURRENT_PLAN_KEYS_INVALID'
    }
    $removedIds = @($currentPlans.SoftwareId | Where-Object { $_ -notin @($desiredPlans.SoftwareId) })
    if ($desiredPlans.Count -eq 0) {
        throw 'EXTERNAL_RUNTIME_RECONCILE_LAST_RUNTIME_REMOVAL_UNSUPPORTED'
    }
    $imagePlan = New-LabExternalRuntimeContainerImagePlan -Provider ([string]$connectionInstance.provider) `
        -SqlVersion ([string]$connectionInstance.version) -SoftwarePlans $desiredPlans
    $preview = Get-LabExternalRuntimePlanPreview -DesiredPlans $desiredPlans -CurrentPlans $currentPlans
    $currentKeys = @($currentPlans.PlanKey | Sort-Object -Unique)
    $desiredKeys = @($desiredPlans.PlanKey | Sort-Object -Unique)

    return [PSCustomObject]@{
        Run=$run; RunDirectory=$runDirectory; ConnectionPath=$connectionPath; Connection=$connection
        ConnectionInstance=$connectionInstance; ResolvedManifest=$resolved; ResolvedInstance=$targetResolved[0]
        PersistedSnapshot=$persisted.Snapshot; DesiredSnapshot=$desiredSnapshot
        DesiredPlans=$desiredPlans; CurrentPlans=$currentPlans; Preview=$preview; ImagePlan=$imagePlan
        CurrentPlanKeys=$currentKeys; DesiredPlanKeys=$desiredKeys
        RemovedIds=@($removedIds | Sort-Object -Unique)
        IsNoOp=(($currentKeys -join ',') -ceq ($desiredKeys -join ','))
    }
}

function New-LabExternalRuntimeReconcilePlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$ManifestPath,
        [string]$InstanceId,
        [string]$StateRoot
    )
    $context = Get-LabExternalRuntimeReconcileContext @PSBoundParameters
    $instance = $context.ConnectionInstance
    $action = if ($context.IsNoOp) { @() } else {
        @([PSCustomObject]@{
            Operation=$(if ($context.CurrentPlans.Count -eq 0) { 'InstallExternalRuntime' } else { 'RefreshExternalRuntime' }); Provider=[string]$instance.provider
            InstanceId=[string]$instance.id; ChangeClass='recreate'
            ImageKey=[string]$context.ImagePlan.ImageKey
        })
    }
    return [PSCustomObject]@{
        Contract=[PSCustomObject]@{ Name='SqlServerLab.ReconcilePlan'; Version='1.1' }
        RunId=[string]$context.Run.runId; PlanKind='ExternalRuntime'; InstanceId=[string]$instance.id
        Desired=[PSCustomObject]@{
            Provider=[string]$instance.provider; SqlVersion=[string]$instance.version
            PlanKeys=@($context.DesiredPlanKeys); ImageKey=[string]$context.ImagePlan.ImageKey
            Software=@($context.DesiredPlans | Sort-Object SoftwareId | ForEach-Object {
                [PSCustomObject]@{ SoftwareId=[string]$_.SoftwareId; VariantId=[string]$_.VariantId; RuntimeVersion=[string]$_.RuntimeVersion; PlanKey=[string]$_.PlanKey }
            })
        }
        Actual=[PSCustomObject]@{
            State='RUNNING'; Provider=[string]$instance.provider; PlanKeys=@($context.CurrentPlanKeys)
            ImageKey=$(if ($instance.externalRuntime) { [string]$instance.externalRuntime.ImageKey } else { $null })
        }
        Diff=@(@($context.Preview.Entries | ForEach-Object {
            [PSCustomObject]@{ SoftwareId=[string]$_.SoftwareId; PlanKey=[string]$_.PlanKey; ChangeClassification=$_.ChangeClassification; Downtime=[string]$_.Downtime }
        }) + @($context.CurrentPlans | Where-Object { [string]$_.SoftwareId -in @($context.RemovedIds) } | ForEach-Object {
            [PSCustomObject]@{
                SoftwareId=[string]$_.SoftwareId; PlanKey=[string]$_.PlanKey
                ChangeClassification=[PSCustomObject]@{ Artifact='rebuild'; Service='restart'; Activation='recreate'; Highest='recreate'; Intent='remove' }
                Downtime='required'
            }
        }))
        Actions=$action; HighestChangeClass=if ($context.IsNoOp) { 'no-op' } else { 'recreate' }
        IsNoOp=[bool]$context.IsNoOp; MutationAllowed=$false
        Warnings=if ($context.IsNoOp) { @() } else { @('Downtime erforderlich. Das bisherige Image bleibt erhalten; der bisherige Container wird erst nach erfolgreicher SQL-Validierung entfernt.') }
    }
}

function Get-LabExternalRuntimeRefreshJournalPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunDirectory)
    Join-Path $RunDirectory 'external-runtime-refresh.json'
}

function Set-LabExternalRuntimeRefreshJournalStatus {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Journal, [Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Status)
    $Journal.status = $Status
    $Journal.updatedAt = Get-LabTimestamp
    Write-LabArtifactJsonAtomic -Path $Path -InputObject $Journal
}

function Test-LabRuntimeContainerExists {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Provider, [Parameter(Mandatory)][string]$Identity)
    $runtimeInvocation = Get-LabHostToolInvocation -Name $Provider
    $null = & $runtimeInvocation inspect $Identity 2>$null
    return $LASTEXITCODE -eq 0
}

function New-LabExternalRuntimeReplacementInstance {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$ResolvedInstance,
        [Parameter(Mandatory)]$ContainerInspect,
        [switch]$AllowNewExternalRuntimeVolumes,
        [switch]$PersistentData
    )

    # Recreate must bind the exact volumes already carrying master/model/msdb
    # and user databases. Deriving fresh volume names from a mutable lab display
    # name would silently create an empty SQL data root. External-language and
    # library artifacts must survive with their database metadata, while
    # LaunchPad data and sandboxes remain container-local to avoid retaining
    # namespace ownership and nested-mount state.
    $replacement = $ResolvedInstance | ConvertTo-Json -Depth 50 | ConvertFrom-Json -Depth 50
    $null = Add-LabRunScopedContainerSystemDrive -Instance $replacement -IncludeExternalRuntimeState
    $drives = @($replacement.drives | Where-Object { [string]$_.containerPath -ne '/var/opt/mssql-extensibility' })
    foreach ($drive in $drives) {
        if (-not $drive -or -not $drive.containerPath) { continue }
        $mount = @($ContainerInspect.Mounts | Where-Object {
            [string]$_.Destination -eq [string]$drive.containerPath
        })
        if ($mount.Count -eq 0 -and $AllowNewExternalRuntimeVolumes -and
            [string]$drive.containerPath -in @(
                '/var/opt/mssql-extensibility/externallanguages',
                '/var/opt/mssql-extensibility/externallibraries'
            )) {
            if ($PersistentData) {
                $systemDrive = @($drives | Where-Object { [string]$_.containerPath -eq '/var/opt/mssql' })[0]
                if (-not $systemDrive -or [string]::IsNullOrWhiteSpace([string]$systemDrive.volumeName)) {
                    throw 'EXTERNAL_RUNTIME_REFRESH_PERSISTENT_SYSTEM_VOLUME_MISSING'
                }
                $suffix = if ([string]$drive.containerPath -like '*/externallanguages') { 'external-languages' } else { 'external-libraries' }
                $drive | Add-Member -NotePropertyName volumeName -NotePropertyValue "$($systemDrive.volumeName)-$suffix" -Force
                $drive | Add-Member -NotePropertyName persistence -NotePropertyValue 'data-root-runtime-volume' -Force
            }
            continue
        }
        if ($mount.Count -ne 1 -or [string]$mount[0].Type -notin @('volume','bind')) {
            throw "EXTERNAL_RUNTIME_REFRESH_VOLUME_BINDING_INVALID: $($drive.containerPath)"
        }
        if ([string]$mount[0].Type -eq 'volume') {
            if ([string]::IsNullOrWhiteSpace([string]$mount[0].Name)) {
                throw "EXTERNAL_RUNTIME_REFRESH_VOLUME_BINDING_INVALID: $($drive.containerPath)"
            }
            $drive | Add-Member -NotePropertyName volumeName -NotePropertyValue ([string]$mount[0].Name) -Force
            $drive.PSObject.Properties.Remove('hostPath')
        }
        else {
            if ([string]::IsNullOrWhiteSpace([string]$mount[0].Source)) {
                throw "EXTERNAL_RUNTIME_REFRESH_BINDING_INVALID: $($drive.containerPath)"
            }
            $drive | Add-Member -NotePropertyName hostPath -NotePropertyValue ([string]$mount[0].Source) -Force
            $drive | Add-Member -NotePropertyName readOnly -NotePropertyValue (-not [bool]$mount[0].RW) -Force
            $drive.PSObject.Properties.Remove('volumeName')
        }
    }
    $boundDestinations = @($drives | ForEach-Object { [string]$_.containerPath })
    $additionalIndex = 0
    foreach ($mount in @($ContainerInspect.Mounts | Where-Object {
        [string]$_.Destination -notin @('/sys/fs/cgroup','/var/opt/mssql-extensibility') -and
        [string]$_.Destination -notin $boundDestinations
    })) {
        $additionalIndex++
        if ([string]$mount.Type -eq 'volume' -and -not [string]::IsNullOrWhiteSpace([string]$mount.Name)) {
            $drives += [PSCustomObject]@{
                id="existing-volume-$additionalIndex"; containerPath=[string]$mount.Destination
                volumeName=[string]$mount.Name; persistence='existing-runtime-binding'
            }
        }
        elseif ([string]$mount.Type -eq 'bind' -and -not [string]::IsNullOrWhiteSpace([string]$mount.Source)) {
            $drives += [PSCustomObject]@{
                id="existing-bind-$additionalIndex"; containerPath=[string]$mount.Destination
                hostPath=[string]$mount.Source; readOnly=(-not [bool]$mount.RW); persistence='existing-runtime-binding'
            }
        }
        else { throw "EXTERNAL_RUNTIME_REFRESH_UNSUPPORTED_MOUNT: $($mount.Destination)" }
    }
    $replacement | Add-Member -NotePropertyName drives -NotePropertyValue $drives -Force
    return $replacement
}

function Add-LabExternalRuntimeCleanupVolumes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunDirectory,
        [Parameter(Mandatory)][string]$Provider,
        [Parameter(Mandatory)][string]$ContainerName,
        [Parameter(Mandatory)]$ReplacementInstance,
        [Parameter(Mandatory)][object[]]$SoftwarePlans
    )

    $cleanupPath = Join-Path $RunDirectory 'cleanup-plan.json'
    if (-not (Test-Path -LiteralPath $cleanupPath -PathType Leaf)) {
        throw 'EXTERNAL_RUNTIME_REFRESH_CLEANUP_PLAN_MISSING'
    }
    $plan = Get-Content -LiteralPath $cleanupPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 50
    $containerSteps = @($plan.steps | Where-Object {
        [string]$_.resourceType -eq 'container' -and [string]$_.provider -eq $Provider -and
        [string]$_.resourceId -eq $ContainerName -and [string]$_.state -eq 'PENDING'
    })
    if ($containerSteps.Count -ne 1) { throw 'EXTERNAL_RUNTIME_REFRESH_CLEANUP_CONTAINER_STEP_INVALID' }
    $containerStep = $containerSteps[0]
    $softwareContract = [PSCustomObject]@{
        contract=[PSCustomObject]@{ name='SqlServerLab.SoftwareCleanupBinding'; version='1.0' }
        planKeys=@($SoftwarePlans.PlanKey | Sort-Object -Unique)
        softwareIds=@($SoftwarePlans.SoftwareId | Sort-Object -Unique)
        artifactRetention='reusable-artifacts-retained'
    }
    $newSteps = @()
    foreach ($drive in @($ReplacementInstance.drives | Where-Object {
        [string]$_.containerPath -in @(
            '/var/opt/mssql-extensibility/externallanguages',
            '/var/opt/mssql-extensibility/externallibraries'
        ) -and [string]$_.persistence -ne 'data-root-runtime-volume'
    })) {
        $volumeName = if ($drive.volumeName) { [string]$drive.volumeName } else { "sql-lab-${ContainerName}-$($drive.id)" }
        if (@($plan.steps | Where-Object { [string]$_.resourceType -eq 'volume' -and [string]$_.resourceId -eq $volumeName }).Count -gt 0) {
            continue
        }
        $newSteps += Add-CleanupStep -RunDir $RunDirectory -ResourceType volume -ResourceId $volumeName `
            -Action remove -Provider $Provider -ProviderSubRunId "provider-$Provider" `
            -SoftwareContract $softwareContract -Compensation "$Provider volume rm $volumeName"
    }
    if ($newSteps.Count -eq 0) { return }

    $plan = Get-Content -LiteralPath $cleanupPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 50
    $oldContainerOrder = [int]$containerStep.order
    $newContainerOrder = @($plan.steps).Count + 1
    $persistedContainer = @($plan.steps | Where-Object {
        [string]$_.resourceType -eq 'container' -and [string]$_.provider -eq $Provider -and
        [string]$_.resourceId -eq $ContainerName
    })[0]
    $persistedContainer.order = $newContainerOrder
    $providerSubRun = @($plan.providerSubRuns | Where-Object { [string]$_.id -eq "provider-$Provider" })[0]
    if ($providerSubRun) {
        $providerSubRun.stepOrders = @($providerSubRun.stepOrders | ForEach-Object {
            if ([int]$_ -eq $oldContainerOrder) { $newContainerOrder } else { [int]$_ }
        } | Sort-Object -Unique)
        $providerSubRun.updatedAt = Get-LabTimestamp
    }
    Write-LabArtifactJsonAtomic -Path $cleanupPath -InputObject $plan
}

function Get-LabExternalRuntimeJavaCleanupPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        $PreviousReceipts
    )

    if (@($Context.RemovedIds) -notcontains 'sql-java') { return $null }
    $currentJava = @($Context.CurrentPlans | Where-Object { [string]$_.SoftwareId -eq 'sql-java' })
    if ($currentJava.Count -ne 1) { throw 'EXTERNAL_RUNTIME_JAVA_REMOVAL_CURRENT_PLAN_INVALID' }
    $instanceReceipts = @($PreviousReceipts.instances | Where-Object {
        [string]$_.instanceId -eq [string]$Context.ConnectionInstance.id
    })
    $javaReceipts = @($instanceReceipts | ForEach-Object { @($_.receipts) } | Where-Object {
        [string]$_.SoftwareId -eq 'sql-java' -and [string]$_.PlanKey -eq [string]$currentJava[0].PlanKey
    })
    if ($javaReceipts.Count -ne 1) { throw 'EXTERNAL_RUNTIME_JAVA_REMOVAL_RECEIPT_INVALID' }
    $records = @($javaReceipts[0].Postconditions | Where-Object {
        [string]$_.Language -eq 'Java' -and $_.ManagedObjects
    } | ForEach-Object {
        if ([string]$_.Database -notmatch '^[A-Za-z][A-Za-z0-9_]{0,127}$') {
            throw 'EXTERNAL_RUNTIME_JAVA_REMOVAL_DATABASE_INVALID'
        }
        [PSCustomObject]@{
            Database=[string]$_.Database
            Registration=[PSCustomObject]@{
                CreatedLanguage=[bool]$_.ManagedObjects.CreatedLanguage
                CreatedSdk=[bool]$_.ManagedObjects.CreatedSdk
                CreatedProbe=[bool]$_.ManagedObjects.CreatedProbe
            }
        }
    })
    if ($records.Count -eq 0) { throw 'EXTERNAL_RUNTIME_JAVA_REMOVAL_OWNERSHIP_EVIDENCE_MISSING' }
    return [PSCustomObject]@{
        Software=[PSCustomObject]@{
            SoftwareId='sql-java'; PlanKey=[string]$currentJava[0].PlanKey
            VariantId=[string]$currentJava[0].VariantId; RuntimeVersion=[string]$currentJava[0].RuntimeVersion
        }
        Records=$records
    }
}

function Remove-LabExternalRuntimeManagedJavaObjects {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$CleanupPlan,
        [Parameter(Mandatory)][string]$HostName,
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][SecureString]$SaPassword
    )
    foreach ($record in @($CleanupPlan.Records)) {
        Undo-LabJavaExternalRuntimeDatabaseObjects -HostName $HostName -Port $Port -SaPassword $SaPassword `
            -Database ([string]$record.Database) -Registration $record.Registration
    }
}

function Restore-LabExternalRuntimeManagedJavaObjects {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Journal,
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][SecureString]$SaPassword
    )
    if (-not $Journal.javaCleanup -or @($Journal.javaCleanup.records).Count -eq 0) { return }
    $software = $Journal.javaCleanup.software
    $plan = Resolve-LabExternalRuntimePlan -SoftwareItem ([PSCustomObject]@{
        Id='sql-java'; Version=[string]$software.runtimeVersion; Variant=[string]$software.variantId
        InstallMethod=$null; Packages=@(); RequestSource='refresh-rollback'
    }) -SqlVersion ([string]$Context.ConnectionInstance.version) -Provider ([string]$Journal.provider) -OperatingSystem linux
    if ([string]$plan.Status -ne 'RESOLVED' -or [string]$plan.PlanKey -ne [string]$software.planKey) {
        throw 'EXTERNAL_RUNTIME_JAVA_ROLLBACK_PLAN_DRIFT'
    }
    foreach ($record in @($Journal.javaCleanup.records)) {
        $managed = $record.registration
        if (-not ([bool]$managed.CreatedLanguage -or [bool]$managed.CreatedSdk -or [bool]$managed.CreatedProbe)) { continue }
        $null = Register-LabJavaExternalRuntimeDatabaseObjects -Plan $plan `
            -HostName ([string]$Context.ConnectionInstance.host) -Port ([int]$Context.ConnectionInstance.port) `
            -SaPassword $SaPassword -Database ([string]$record.database)
    }
}

function Repair-LabExternalRuntimeRefreshJournal {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context)
    $path = Get-LabExternalRuntimeRefreshJournalPath -RunDirectory $Context.RunDirectory
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return }
    $journal = Get-Content -LiteralPath $path -Raw -Encoding utf8 | ConvertFrom-Json -Depth 50
    if ([string]$journal.contract.name -ne 'SqlServerLab.ExternalRuntimeRefreshJournal' -or
        [string]$journal.contract.version -ne '1.0' -or [string]$journal.runId -ne [string]$Context.Run.runId -or
        [string]$journal.scopeId -ne [string]$Context.Run.scopeId) {
        throw 'EXTERNAL_RUNTIME_REFRESH_JOURNAL_INVALID'
    }
    if ([string]$journal.status -in @('COMPLETED','ROLLED_BACK')) { return }
    $provider = [string]$journal.provider
    $runtimeInvocation = Get-LabHostToolInvocation -Name $provider
    $canonical = [string]$journal.containerName
    $backup = [string]$journal.backupName
    if ([string]$journal.status -eq 'STATE_COMMITTED') {
        if (Test-LabRuntimeContainerExists -Provider $provider -Identity $backup) {
            Remove-LabContainerForCleanup -Provider $provider -ContainerIdOrName $backup -ExpectedScopeId ([string]$journal.scopeId)
        }
        Set-LabExternalRuntimeRefreshJournalStatus -Journal $journal -Path $path -Status 'COMPLETED'
        return
    }
    if ([string]$journal.status -eq 'PREPARED') {
        if (Test-LabRuntimeContainerExists -Provider $provider -Identity $canonical) {
            $null = & $runtimeInvocation start $canonical 2>&1
            if ($LASTEXITCODE -ne 0) { throw 'EXTERNAL_RUNTIME_REFRESH_RECOVERY_START_FAILED' }
        }
    }
    elseif (Test-LabRuntimeContainerExists -Provider $provider -Identity $canonical) {
        Remove-LabContainerForCleanup -Provider $provider -ContainerIdOrName $canonical -ExpectedScopeId ([string]$journal.scopeId)
    }
    if (Test-LabRuntimeContainerExists -Provider $provider -Identity $backup) {
        $output = @(& $runtimeInvocation rename $backup $canonical 2>&1)
        if ($LASTEXITCODE -ne 0) { throw "EXTERNAL_RUNTIME_REFRESH_RECOVERY_RENAME_FAILED: $($output -join ' ')" }
        $null = & $runtimeInvocation start $canonical 2>&1
        if ($LASTEXITCODE -ne 0) { throw 'EXTERNAL_RUNTIME_REFRESH_RECOVERY_START_FAILED' }
    }
    if ($journal.javaCleanup -and @($journal.javaCleanup.records).Count -gt 0) {
        $rollbackPassword = Get-LabSecret -Path $Context.RunDirectory -Name 'sa-password'
        if (-not $rollbackPassword) { throw 'EXTERNAL_RUNTIME_REFRESH_SA_SECRET_MISSING' }
        Restore-LabExternalRuntimeManagedJavaObjects -Journal $journal -Context $Context -SaPassword $rollbackPassword
    }
    if ($journal.previousConnection) { Write-LabArtifactJsonAtomic -Path $Context.ConnectionPath -InputObject $journal.previousConnection }
    if ($journal.previousRunState) { Write-LabArtifactJsonAtomic -Path (Join-Path $Context.RunDirectory 'run-state.json') -InputObject $journal.previousRunState }
    $receiptPath = Join-Path $Context.RunDirectory 'software-installation-receipts.json'
    if ($journal.previousReceipts) {
        Write-LabArtifactJsonAtomic -Path $receiptPath -InputObject $journal.previousReceipts
    }
    elseif (Test-Path -LiteralPath $receiptPath -PathType Leaf) {
        Remove-Item -LiteralPath $receiptPath -Force
    }
    if ($journal.previousCleanupPlan) {
        Write-LabArtifactJsonAtomic -Path (Join-Path $Context.RunDirectory 'cleanup-plan.json') -InputObject $journal.previousCleanupPlan
    }
    Set-LabExternalRuntimeRefreshJournalStatus -Journal $journal -Path $path -Status 'ROLLED_BACK'
}

function Invoke-LabExternalRuntimeReconcileRefresh {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$ManifestPath,
        [string]$InstanceId,
        [ValidateRange(30,900)][int]$ReadinessTimeoutSeconds=300,
        [string]$StateRoot
    )
    $context = Get-LabExternalRuntimeReconcileContext -RunId $RunId -ManifestPath $ManifestPath -InstanceId $InstanceId -StateRoot $StateRoot
    Repair-LabExternalRuntimeRefreshJournal -Context $context
    $context = Get-LabExternalRuntimeReconcileContext -RunId $RunId -ManifestPath $ManifestPath -InstanceId $InstanceId -StateRoot $StateRoot
    if ($context.IsNoOp) { return [PSCustomObject]@{ Status='NO_OP'; RunId=$RunId; InstanceId=[string]$context.ConnectionInstance.id; Changed=$false } }

    $provider = [string]$context.ConnectionInstance.provider
    $runtimeInvocation = Get-LabHostToolInvocation -Name $provider
    $identity = @([string]$context.ConnectionInstance.containerId,[string]$context.ConnectionInstance.containerName,[string]$context.ConnectionInstance.id) | Where-Object { $_ } | Select-Object -First 1
    $inspect = @(& $runtimeInvocation inspect $identity 2>$null | ConvertFrom-Json -Depth 50)[0]
    if (-not $inspect -or -not [bool]$inspect.State.Running) { throw 'EXTERNAL_RUNTIME_REFRESH_CONTAINER_NOT_RUNNING' }
    if ([string]$inspect.Config.Labels.'sql-server-lab.scope-id' -ne [string]$context.Run.scopeId -or
        [string]$inspect.Config.Labels.'sql-server-lab.run-id' -ne $RunId -or
        [string]$inspect.Config.Labels.'sql-server-lab.instance-id' -ne [string]$context.ConnectionInstance.id) {
        throw 'EXTERNAL_RUNTIME_REFRESH_SCOPE_MISMATCH'
    }
    $name = ([string]$inspect.Name).TrimStart('/')
    if ($name -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,254}$') {
        throw 'EXTERNAL_RUNTIME_REFRESH_CONTAINER_NAME_INVALID'
    }
    $isInitialInstall = $context.CurrentPlans.Count -eq 0
    $replacementInstance = New-LabExternalRuntimeReplacementInstance `
        -ResolvedInstance $context.ResolvedInstance -ContainerInspect $inspect `
        -AllowNewExternalRuntimeVolumes:$isInitialInstall `
        -PersistentData:([bool]$context.PersistedSnapshot.PersistentData)
    $backupName = "$name-runtime-refresh-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    $saPassword = Get-LabSecret -Path $context.RunDirectory -Name 'sa-password'
    if (-not $saPassword) { throw 'EXTERNAL_RUNTIME_REFRESH_SA_SECRET_MISSING' }
    $receiptPath = Join-Path $context.RunDirectory 'software-installation-receipts.json'
    $previousReceipts = if (Test-Path -LiteralPath $receiptPath -PathType Leaf) {
        Get-Content -LiteralPath $receiptPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 50
    } else { $null }
    $cleanupPath = Join-Path $context.RunDirectory 'cleanup-plan.json'
    $previousCleanupPlan = if (Test-Path -LiteralPath $cleanupPath -PathType Leaf) {
        Get-Content -LiteralPath $cleanupPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 50
    } else { $null }
    $javaCleanup = Get-LabExternalRuntimeJavaCleanupPlan -Context $context -PreviousReceipts $previousReceipts
    $artifact = Invoke-LabExternalRuntimeContainerImageBuild -ImagePlan $context.ImagePlan -StateRoot $StateRoot
    $journalPath = Get-LabExternalRuntimeRefreshJournalPath -RunDirectory $context.RunDirectory
    $journal = [PSCustomObject]@{
        contract=[PSCustomObject]@{ name='SqlServerLab.ExternalRuntimeRefreshJournal'; version='1.0' }
        runId=$RunId; scopeId=[string]$context.Run.scopeId; instanceId=[string]$context.ConnectionInstance.id
        provider=$provider; containerName=$name; backupName=$backupName
        previousImageKey=$(if ($context.ConnectionInstance.externalRuntime) { [string]$context.ConnectionInstance.externalRuntime.ImageKey } else { $null })
        desiredImageKey=[string]$artifact.ImageKey; status='PREPARED'; updatedAt=Get-LabTimestamp
        javaCleanup=if ($javaCleanup) { [PSCustomObject]@{
            software=$javaCleanup.Software; records=@($javaCleanup.Records)
        } } else { $null }
        previousConnection=$context.Connection; previousRunState=$context.Run; previousReceipts=$previousReceipts
        previousCleanupPlan=$previousCleanupPlan
    }
    Write-LabArtifactJsonAtomic -Path $journalPath -InputObject $journal

    $replacement = $null
    $javaCompensations = @()
    $stateCommitted = $false
    try {
        $null = & $runtimeInvocation stop $name 2>&1
        $renameOutput = @(& $runtimeInvocation rename $name $backupName 2>&1)
        if ($LASTEXITCODE -ne 0) { throw "EXTERNAL_RUNTIME_REFRESH_RENAME_FAILED: $($renameOutput -join ' ')" }
        Set-LabExternalRuntimeRefreshJournalStatus -Journal $journal -Path $journalPath -Status 'ORIGINAL_RENAMED'

        $replacement = New-LabProviderContainer -Instance $replacementInstance -RunState ([PSCustomObject]@{
            RunId=$RunId; ScopeId=[string]$context.Run.scopeId; metadata=$context.Run.metadata
        }) -SaPassword $saPassword -Port ([int]$context.ConnectionInstance.port) `
            -ContainerImageArtifact $artifact -ContainerName $name `
            -EndpointBindingIgnoreContainerName $backupName
        if ($isInitialInstall) {
            Add-LabExternalRuntimeCleanupVolumes -RunDirectory $context.RunDirectory -Provider $provider `
                -ContainerName $name -ReplacementInstance $replacementInstance -SoftwarePlans $context.DesiredPlans
        }
        Set-LabExternalRuntimeRefreshJournalStatus -Journal $journal -Path $journalPath -Status 'REPLACEMENT_CREATED'
        $versionDefinition = Get-SqlServerVersion -VersionId ([string]$context.ConnectionInstance.version)
        $readiness = Wait-SqlReady -HostName ([string]$context.ConnectionInstance.host) -Port ([int]$replacement.Port) `
            -SaPassword $saPassword -TimeoutSeconds $ReadinessTimeoutSeconds -ExpectedMajorVersion ([int]$versionDefinition.major) `
            -Provider $provider -ContainerIdOrName ([string]$replacement.ContainerId)
        if (-not $readiness.Ready) { throw "EXTERNAL_RUNTIME_REFRESH_READINESS_FAILED: $($readiness.Message)" }
        $labInstance = [PSCustomObject]@{
            Id=[string]$context.ConnectionInstance.id; Version=[string]$context.ConnectionInstance.version
            Provider=$provider; Host=[string]$context.ConnectionInstance.host; Port=[int]$replacement.Port
            ContainerId=[string]$replacement.ContainerId; Databases=@($context.ConnectionInstance.databases)
        }
        $receipts = @(Initialize-LabExternalRuntimes -SoftwarePlans $context.DesiredPlans -LabInstance $labInstance `
            -ImageArtifact $artifact -SaPassword $saPassword -RunDirectory $context.RunDirectory `
            -ResourceGovernorConfig $context.ResolvedInstance.serverConfig.externalScripts.resourceGovernor `
            -CompensationRecords ([ref]$javaCompensations))
        if ($javaCleanup) {
            Set-LabExternalRuntimeRefreshJournalStatus -Journal $journal -Path $journalPath -Status 'JAVA_CLEANUP_PREPARED'
            Remove-LabExternalRuntimeManagedJavaObjects -CleanupPlan $javaCleanup `
                -HostName ([string]$context.ConnectionInstance.host) -Port ([int]$replacement.Port) -SaPassword $saPassword
            Set-LabExternalRuntimeRefreshJournalStatus -Journal $journal -Path $journalPath -Status 'JAVA_CLEANUP_COMPLETED'
        }
        Set-LabExternalRuntimeRefreshJournalStatus -Journal $journal -Path $journalPath -Status 'VERIFIED'

        $instance = $context.ConnectionInstance
        $instance | Add-Member -NotePropertyName containerId -NotePropertyValue ([string]$replacement.ContainerId) -Force
        $instance | Add-Member -NotePropertyName containerName -NotePropertyValue ([string]$replacement.ContainerName) -Force
        $instance | Add-Member -NotePropertyName runtimeId -NotePropertyValue ([string]$replacement.ContainerId) -Force
        $instance | Add-Member -NotePropertyName externalRuntime -NotePropertyValue ([PSCustomObject]@{
            ImageKey=[string]$artifact.ImageKey; SoftwarePlanKeys=@($context.ImagePlan.SoftwarePlanKeys)
            LaunchMode=[string]$artifact.LaunchMode; VariantIds=@($context.ImagePlan.VariantIds)
            Languages=@($context.ImagePlan.Languages); Status='EXTENSIONS_READY_RUN'
            Receipts=@($receipts | ForEach-Object { [PSCustomObject]@{
                SoftwareId=[string]$_.SoftwareId; PlanKey=[string]$_.PlanKey; VariantId=[string]$_.VariantId
                RuntimeVersion=[string]$_.RuntimeVersion; Status=[string]$_.Status; CompletedAt=[string]$_.CompletedAt
            } })
        }) -Force
        $context.Run.metadata.desiredState = $context.DesiredSnapshot
        Write-LabArtifactJsonAtomic -Path $context.ConnectionPath -InputObject $context.Connection
        Write-LabArtifactJsonAtomic -Path (Join-Path $context.RunDirectory 'run-state.json') -InputObject $context.Run
        Set-LabExternalRuntimeRefreshJournalStatus -Journal $journal -Path $journalPath -Status 'STATE_COMMITTED'
        $stateCommitted = $true
        Remove-LabContainerForCleanup -Provider $provider -ContainerIdOrName $backupName -ExpectedScopeId ([string]$context.Run.scopeId)
        Set-LabExternalRuntimeRefreshJournalStatus -Journal $journal -Path $journalPath -Status 'COMPLETED'
        return [PSCustomObject]@{
            Status='SUCCEEDED'; RunId=$RunId; InstanceId=[string]$instance.id; Provider=$provider; Changed=$true
            ImageKey=[string]$artifact.ImageKey; PlanKeys=@($context.DesiredPlanKeys); Receipts=@($receipts)
        }
    }
    catch {
        $failure = $_
        $recoveryErrors = [Collections.Generic.List[string]]::new()
        if (-not $stateCommitted -and $replacement -and @($javaCompensations).Count -gt 0) {
            for ($index = @($javaCompensations).Count - 1; $index -ge 0; $index--) {
                try {
                    $record = @($javaCompensations)[$index]
                    Undo-LabJavaExternalRuntimeDatabaseObjects -HostName ([string]$context.ConnectionInstance.host) `
                        -Port ([int]$replacement.Port) -SaPassword $saPassword -Database ([string]$record.Database) `
                        -Registration $record.Registration
                }
                catch { $recoveryErrors.Add($_.Exception.Message) }
            }
        }
        try { Repair-LabExternalRuntimeRefreshJournal -Context $context }
        catch { $recoveryErrors.Add($_.Exception.Message) }
        if ($recoveryErrors.Count -gt 0) {
            throw "EXTERNAL_RUNTIME_REFRESH_AND_RECOVERY_FAILED: $($failure.Exception.Message) / $($recoveryErrors -join ' | ')"
        }
        throw $failure
    }
}
