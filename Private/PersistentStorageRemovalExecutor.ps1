<#
.SYNOPSIS
    Executes the supported persistent-storage removal policies journaled.
.DESCRIPTION
    Supports retained Docker/Podman instance stores with verified database
    backups or offline container database packages. The run is removed only
    after every selected artifact is reusable. FILESTREAM, TDE, combined
    policies, external release, and explicit storage deletion remain
    fail-closed boundaries.
#>

function Get-LabPersistentStorageRemovalJournalPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunDirectory)
    Join-Path $RunDirectory 'persistent-storage-removal.local.journal.json'
}

function Get-LabPersistentStorageRemovalSelectionFingerprint {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$Selection)

    $normalized = @($Selection | ForEach-Object {
        [PSCustomObject][ordered]@{
            PersistentStorageId = ([string]$_.PersistentStorageId).ToLowerInvariant()
            Policy = ([string]$_.Policy).ToUpperInvariant()
            DatabaseReferenceIds = @($_.DatabaseReferenceIds | ForEach-Object { ([string]$_).ToLowerInvariant() } | Sort-Object -Unique)
        }
    } | Sort-Object PersistentStorageId)
    $json = $normalized | ConvertTo-Json -Depth 10 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    try { ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))).ToLowerInvariant() }
    finally { [Array]::Clear($bytes,0,$bytes.Length) }
}

function Test-LabPersistentStorageRemovalJournal {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Journal)

    $schemaPath = Join-Path $script:SchemasPath 'persistent-storage-removal-journal.schema.json'
    try { $valid = $Journal | ConvertTo-Json -Depth 40 | Test-Json -SchemaFile $schemaPath -ErrorAction Stop }
    catch { throw "PERSISTENT_STORAGE_REMOVAL_JOURNAL_INVALID: $($_.Exception.Message)" }
    if (-not $valid) { throw 'PERSISTENT_STORAGE_REMOVAL_JOURNAL_INVALID' }
    return $true
}

function Write-LabPersistentStorageRemovalJournal {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification='Interner atomarer Journalcommit des bereits bestaetigten Executors.')]
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Journal, [Parameter(Mandatory)][string]$Path)

    $Journal.UpdatedAt = Get-LabTimestamp
    $null = Test-LabPersistentStorageRemovalJournal -Journal $Journal
    Write-LabArtifactJsonAtomic -Path $Path -InputObject $Journal
    return $Journal
}

function Read-LabPersistentStorageRemovalJournal {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try { $journal = Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json -Depth 40 -ErrorAction Stop }
    catch { throw "PERSISTENT_STORAGE_REMOVAL_JOURNAL_INVALID: $($_.Exception.Message)" }
    # Version 1.0 journals written before PACKAGE_ON_REMOVE was executable did
    # not carry a Packages array. They are semantically equivalent to an empty
    # array and remain resumable without weakening schema validation.
    if (-not $journal.PSObject.Properties['Packages']) { $journal | Add-Member -NotePropertyName Packages -NotePropertyValue @() }
    $null = Test-LabPersistentStorageRemovalJournal -Journal $journal
    return $journal
}

function Assert-LabPersistentStorageRemovalExecutablePlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Plan)

    if ([string]$Plan.ContractVersion -ne 'SqlServerLab.PersistentStorageRemovalPlan/1.0' -or [string]$Plan.Status -ne 'READY') {
        throw 'PERSISTENT_STORAGE_REMOVAL_EXECUTION_PLAN_NOT_READY'
    }
    $unsupported = @($Plan.Stores | Where-Object { [string]$_.Policy -notin @('RETAIN_INSTANCE_STORE','BACKUP_ON_REMOVE','PACKAGE_ON_REMOVE') })
    if ($unsupported.Count -gt 0) {
        $policies = @($unsupported.Policy | ForEach-Object { if ($_){[string]$_}else{'NONE'} } | Sort-Object -Unique)
        throw "PERSISTENT_STORAGE_REMOVAL_POLICY_NOT_EXECUTABLE: $($policies -join ',')"
    }
    foreach ($store in @($Plan.Stores)) {
        if ([string]$store.StorageClass -ne 'INSTANCE_STORE' -or [string]$store.Provider -notin @('docker','podman') -or
            [bool]$store.Destructive -or -not [bool]$store.RequiresSeparateStorageDelete) {
            throw 'PERSISTENT_STORAGE_REMOVAL_EXECUTION_STORE_UNSUPPORTED'
        }
    }
    return $true
}

function New-LabPersistentStorageRemovalExecutionContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)][object[]]$Selection,
        [Parameter(Mandatory)][string]$StateRoot,
        [Parameter(Mandatory)][string]$DataRoot
    )

    $runId = [string]$Plan.RunId
    $run = Get-LabRunState -RunId $runId -StateRoot $StateRoot
    $runDirectory = Join-Path (Join-Path $StateRoot 'runs') $runId
    $connectionPath = Join-Path $runDirectory 'connection-info.json'
    if (-not (Test-Path -LiteralPath $connectionPath -PathType Leaf)) { throw 'PERSISTENT_STORAGE_REMOVAL_CONNECTION_INFO_MISSING' }
    $connection = Get-Content -LiteralPath $connectionPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 30 -ErrorAction Stop
    if ([string]$connection.runId -ne $runId -or [string]$connection.scopeId -ne [string]$run.scopeId) {
        throw 'PERSISTENT_STORAGE_REMOVAL_RUN_SCOPE_CONFLICT'
    }

    $configuration = Get-LabStorageConfiguration -DataRoot $DataRoot
    $catalog = Get-LabPersistentStorageCatalog -Configuration $configuration
    if ([string]$catalog.Status -ne 'AVAILABLE' -or [int]$catalog.Document.Revision -ne [int]$Plan.CatalogRevision) {
        throw 'PERSISTENT_STORAGE_REMOVAL_CATALOG_REVISION_CONFLICT'
    }
    $backupTasks = [Collections.Generic.List[object]]::new(); $packageTasks = [Collections.Generic.List[object]]::new()
    foreach ($plannedStore in @($Plan.Stores)) {
        $storageId = [string]$plannedStore.PersistentStorageId
        $stores = @($catalog.Document.Stores | Where-Object PersistentStorageId -eq $storageId)
        if ($stores.Count -ne 1) { throw 'PERSISTENT_STORAGE_REMOVAL_STORE_UNRESOLVED' }
        $store = $stores[0]
        if ([string]$store.State -ne 'IN_USE' -or -not $store.Lease -or
            [string]$store.Lease.RunId -ne $runId -or [string]$store.Lease.ScopeId -ne [string]$run.scopeId) {
            throw 'PERSISTENT_STORAGE_REMOVAL_STORE_LEASE_CONFLICT'
        }
        $instances = @($connection.instances | Where-Object {
            $_.persistentStorage -and [string]$_.persistentStorage.persistentStorageId -eq $storageId
        })
        if ($instances.Count -ne 1) { throw 'PERSISTENT_STORAGE_REMOVAL_INSTANCE_UNRESOLVED' }
        if ([string]$plannedStore.Policy -eq 'BACKUP_ON_REMOVE') {
            foreach ($referenceId in @($plannedStore.DatabaseReferenceIds | Sort-Object -Unique)) {
                $references = @($store.References | Where-Object {
                    [string]$_.ReferenceId -eq [string]$referenceId -and [string]$_.Kind -eq 'DATABASE' -and [string]$_.State -eq 'ACTIVE'
                })
                if ($references.Count -ne 1) { throw 'PERSISTENT_STORAGE_REMOVAL_DATABASE_REFERENCE_UNRESOLVED' }
                $backupTasks.Add([PSCustomObject][ordered]@{
                    PersistentStorageId=$storageId; DatabaseReferenceId=[string]$referenceId
                    InstanceId=[string]$instances[0].id; DatabaseName=[string]$references[0].TargetId
                    Status='PENDING'; BackupSetId=$null; ArtifactPersistentStorageId=$null; Sha256=$null; Bytes=$null
                })
            }
        }
        if ([string]$plannedStore.Policy -eq 'PACKAGE_ON_REMOVE') {
            foreach ($referenceId in @($plannedStore.DatabaseReferenceIds | Sort-Object -Unique)) {
                $references = @($store.References | Where-Object { [string]$_.ReferenceId -eq [string]$referenceId -and [string]$_.Kind -eq 'DATABASE' -and [string]$_.State -eq 'ACTIVE' })
                if ($references.Count -ne 1) { throw 'PERSISTENT_STORAGE_REMOVAL_DATABASE_REFERENCE_UNRESOLVED' }
                $packageTasks.Add([PSCustomObject][ordered]@{ PersistentStorageId=$storageId; DatabaseReferenceId=[string]$referenceId; InstanceId=[string]$instances[0].id; DatabaseName=[string]$references[0].TargetId; Status='PENDING'; DatabasePackageId=$null; ArtifactPersistentStorageId=$null; ManifestSha256=$null })
            }
        }
    }
    [PSCustomObject]@{
        Run=$run; RunDirectory=$runDirectory; ScopeId=[string]$run.scopeId; Configuration=$configuration
        DataRoot=$DataRoot; StateRoot=$StateRoot; Selection=@($Selection); BackupTasks=@($backupTasks); PackageTasks=@($packageTasks)
        SaPassword=(Get-LabSecret -Path $runDirectory -Name 'sa-password')
    }
}

function New-LabPersistentStorageRemovalResumeContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Journal,
        [Parameter(Mandatory)][object[]]$Selection,
        [Parameter(Mandatory)][string]$StateRoot,
        [Parameter(Mandatory)][string]$DataRoot
    )
    $run=Get-LabRunState -RunId ([string]$Journal.RunId) -StateRoot $StateRoot
    if([string]$run.scopeId -ne [string]$Journal.ScopeId){throw 'PERSISTENT_STORAGE_REMOVAL_RUN_SCOPE_CONFLICT'}
    $runDirectory=Join-Path (Join-Path $StateRoot 'runs') ([string]$Journal.RunId)
    [PSCustomObject]@{
        Run=$run;RunDirectory=$runDirectory;ScopeId=[string]$run.scopeId
        Configuration=(Get-LabStorageConfiguration -DataRoot $DataRoot)
        DataRoot=$DataRoot;StateRoot=$StateRoot;Selection=@($Selection);BackupTasks=@();PackageTasks=@()
        SaPassword=(Get-LabSecret -Path $runDirectory -Name 'sa-password')
    }
}

function Assert-LabPersistentStorageRemovalPostcondition {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][object[]]$Selection,
        [Parameter(Mandatory)]$Configuration
    )

    $catalog = Get-LabPersistentStorageCatalog -Configuration $Configuration
    if ([string]$catalog.Status -ne 'AVAILABLE') { throw 'PERSISTENT_STORAGE_REMOVAL_POSTCONDITION_CATALOG_UNAVAILABLE' }
    foreach ($item in @($Selection)) {
        $stores = @($catalog.Document.Stores | Where-Object PersistentStorageId -eq ([string]$item.PersistentStorageId))
        if ($stores.Count -ne 1) { throw 'PERSISTENT_STORAGE_REMOVAL_POSTCONDITION_STORE_UNRESOLVED' }
        $store = $stores[0]
        $activeRun = @($store.References | Where-Object { $_.Kind -eq 'RUN' -and $_.State -eq 'ACTIVE' -and [string]$_.TargetId -eq $RunId })
        $activeDatabases = @($store.References | Where-Object { $_.Kind -eq 'DATABASE' -and $_.State -eq 'ACTIVE' })
        if ([string]$store.State -ne 'DETACHED' -or $store.Lease -or $activeRun.Count -gt 0 -or $activeDatabases.Count -gt 0) {
            throw 'PERSISTENT_STORAGE_REMOVAL_POSTCONDITION_NOT_DETACHED'
        }
    }
    return $true
}

function Invoke-LabPersistentStorageRemovalExecutor {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification='Aktionsparameter werden im journalisierten Executor als testbare Closures aufgerufen.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification='Interner Executor; die öffentliche Action bestätigt die Mutation.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)][object[]]$Selection,
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][scriptblock]$BackupAction,
        [Parameter(Mandatory)][scriptblock]$BackupVerificationAction,
        [Parameter(Mandatory)][scriptblock]$PackageAction,
        [Parameter(Mandatory)][scriptblock]$PackageVerificationAction,
        [Parameter(Mandatory)][scriptblock]$ReplanAction,
        [Parameter(Mandatory)][scriptblock]$RemoveAction,
        [Parameter(Mandatory)][scriptblock]$PostconditionAction
    )

    $fingerprint = Get-LabPersistentStorageRemovalSelectionFingerprint -Selection $Selection
    $journalPath = Get-LabPersistentStorageRemovalJournalPath -RunDirectory $Context.RunDirectory
    $mutexName = if ($IsWindows) { "Global\SQL_Server_Lab_Persistent_Removal_$(([string]$Plan.RunId).Replace('-',''))" } else { "SQL_Server_Lab_Persistent_Removal_$(([string]$Plan.RunId).Replace('-',''))" }
    $mutex = [Threading.Mutex]::new($false,$mutexName); $acquired=$false; $journal=$null
    try {
        $acquired=$mutex.WaitOne([TimeSpan]::FromMinutes(5)); if(-not $acquired){throw 'PERSISTENT_STORAGE_REMOVAL_LOCK_TIMEOUT'}
        $journal=Read-LabPersistentStorageRemovalJournal -Path $journalPath
        if ($journal) {
            if ([string]$journal.RunId -ne [string]$Plan.RunId -or [string]$journal.ScopeId -ne [string]$Context.ScopeId -or
                [string]$journal.SelectionFingerprint -ne $fingerprint) {
                throw 'PERSISTENT_STORAGE_REMOVAL_JOURNAL_IDENTITY_CONFLICT'
            }
            if ([string]$journal.Status -eq 'COMPLETED') { return $journal }
            $journal.Recovery.Attempts=[int]$journal.Recovery.Attempts+1
        }
        else {
            $null = Assert-LabPersistentStorageRemovalExecutablePlan -Plan $Plan
            $now=Get-LabTimestamp
            $journal=[PSCustomObject][ordered]@{
                ContractVersion='SqlServerLab.PersistentStorageRemovalJournal/1.0'; OperationId=[Guid]::NewGuid().ToString('D')
                IntentId=[string]$Plan.IntentId; RunId=[string]$Plan.RunId; ScopeId=[string]$Context.ScopeId
                SelectionFingerprint=$fingerprint; CatalogRevision=[int]$Plan.CatalogRevision; Status='PREPARED'
                Selections=@($Selection); Backups=@($Context.BackupTasks | Where-Object { $_ }); Packages=@($Context.PackageTasks | Where-Object { $_ })
                Removal=[PSCustomObject][ordered]@{ Status='PENDING'; Cleanup=$null }
                Recovery=[PSCustomObject][ordered]@{ Status='RETRY_EXECUTION'; Attempts=0; ErrorCode=$null; Errors=@() }
                CreatedAt=$now; UpdatedAt=$now
            }
            $null=Write-LabPersistentStorageRemovalJournal -Journal $journal -Path $journalPath
        }

        if ([string]$Context.Run.state -eq 'REMOVED') {
            if ([string]$journal.Removal.Status -notin @('STARTED','COMPLETED')) { throw 'PERSISTENT_STORAGE_REMOVAL_RUN_ALREADY_REMOVED' }
        }
        elseif ([string]$journal.Removal.Status -eq 'STARTED') {
            $removal=& $RemoveAction ([string]$journal.RunId) ([string]$Context.StateRoot)
            if ([string]$removal.Status -ne 'REMOVED' -or [int]$removal.Errors -gt 0) {
                throw 'PERSISTENT_STORAGE_REMOVAL_RUN_CLEANUP_FAILED'
            }
            $journal.Removal.Cleanup=[string]$removal.Cleanup
        }
        else {
            $freshPlan=& $ReplanAction ([string]$Plan.RunId) @($Selection)
            $null=Assert-LabPersistentStorageRemovalExecutablePlan -Plan $freshPlan
            $journal.CatalogRevision=[int]$freshPlan.CatalogRevision
            foreach ($backup in @($journal.Backups)) {
                if ([string]$backup.Status -eq 'COMPLETED') {
                    $verified=& $BackupVerificationAction ([string]$backup.BackupSetId) ([string]$Context.DataRoot)
                    if ([string]$verified.Record.DatabaseName -ne [string]$backup.DatabaseName -or
                        [string]$verified.Record.Artifact.Sha256 -ne [string]$backup.Sha256) {
                        throw 'PERSISTENT_STORAGE_REMOVAL_BACKUP_REVALIDATION_FAILED'
                    }
                    continue
                }
                if (-not $Context.SaPassword) { throw 'PERSISTENT_STORAGE_REMOVAL_SA_SECRET_MISSING' }
                $result=& $BackupAction ([string]$Plan.RunId) ([string]$backup.InstanceId) ([string]$backup.DatabaseName) `
                    ([string]$Context.DataRoot) ([string]$Context.StateRoot) $Context.SaPassword
                if ([string]$result.Status -ne 'BACKUP_REUSABLE' -or [string]$result.BackupSetId -notmatch '^[0-9a-fA-F-]{36}$' -or
                    [string]$result.PersistentStorageId -notmatch '^[0-9a-fA-F-]{36}$' -or [string]$result.Sha256 -notmatch '^[a-fA-F0-9]{64}$' -or [long]$result.Bytes -lt 1) {
                    throw 'PERSISTENT_STORAGE_REMOVAL_BACKUP_POSTCONDITION_FAILED'
                }
                $backup.Status='COMPLETED'; $backup.BackupSetId=[string]$result.BackupSetId
                $backup.ArtifactPersistentStorageId=[string]$result.PersistentStorageId
                $backup.Sha256=([string]$result.Sha256).ToLowerInvariant(); $backup.Bytes=[long]$result.Bytes
                $null=Write-LabPersistentStorageRemovalJournal -Journal $journal -Path $journalPath
            }
            foreach ($package in @($journal.Packages)) {
                if ([string]$package.Status -eq 'COMPLETED') {
                    $verified=& $PackageVerificationAction ([string]$package.DatabasePackageId) ([string]$Context.DataRoot)
                    if ([string]$verified.Record.DatabaseName -ne [string]$package.DatabaseName -or [string]$verified.Record.ManifestSha256 -ne [string]$package.ManifestSha256) { throw 'PERSISTENT_STORAGE_REMOVAL_PACKAGE_REVALIDATION_FAILED' }
                    continue
                }
                $result=& $PackageAction ([string]$Plan.RunId) ([string]$package.InstanceId) ([string]$package.DatabaseName) ([string]$Context.DataRoot) ([string]$Context.StateRoot)
                if ([string]$result.Status -ne 'REUSABLE' -or [string]$result.DatabasePackageId -notmatch '^[0-9a-fA-F-]{36}$' -or [string]$result.PersistentStorageId -notmatch '^[0-9a-fA-F-]{36}$' -or [string]$result.ManifestSha256 -notmatch '^[a-fA-F0-9]{64}$') { throw 'PERSISTENT_STORAGE_REMOVAL_PACKAGE_POSTCONDITION_FAILED' }
                $package.Status='COMPLETED';$package.DatabasePackageId=[string]$result.DatabasePackageId;$package.ArtifactPersistentStorageId=[string]$result.PersistentStorageId;$package.ManifestSha256=([string]$result.ManifestSha256).ToLowerInvariant()
                $null=Write-LabPersistentStorageRemovalJournal -Journal $journal -Path $journalPath
            }
            $journal.Status='BACKUPS_COMPLETED'
            $freshPlan=& $ReplanAction ([string]$Plan.RunId) @($Selection)
            $null=Assert-LabPersistentStorageRemovalExecutablePlan -Plan $freshPlan
            $journal.CatalogRevision=[int]$freshPlan.CatalogRevision
            $null=Write-LabPersistentStorageRemovalJournal -Journal $journal -Path $journalPath

            $journal.Status='REMOVAL_STARTED'; $journal.Removal.Status='STARTED'
            $null=Write-LabPersistentStorageRemovalJournal -Journal $journal -Path $journalPath
            $removal=& $RemoveAction ([string]$Plan.RunId) ([string]$Context.StateRoot)
            if ([string]$removal.Status -ne 'REMOVED' -or [int]$removal.Errors -gt 0) {
                throw 'PERSISTENT_STORAGE_REMOVAL_RUN_CLEANUP_FAILED'
            }
            $journal.Removal.Cleanup=[string]$removal.Cleanup
        }

        $null=& $PostconditionAction ([string]$Plan.RunId) @($Selection) $Context.Configuration
        foreach ($backup in @($journal.Backups)) {
            $null=& $BackupVerificationAction ([string]$backup.BackupSetId) ([string]$Context.DataRoot)
        }
        foreach ($package in @($journal.Packages)) { $null=& $PackageVerificationAction ([string]$package.DatabasePackageId) ([string]$Context.DataRoot) }
        $journal.Status='COMPLETED'; $journal.Removal.Status='COMPLETED'; $journal.Recovery.Status='NOT_REQUIRED'; $journal.Recovery.ErrorCode=$null
        $null=Write-LabPersistentStorageRemovalJournal -Journal $journal -Path $journalPath
        return $journal
    }
    catch {
        $errorCode=if($_.Exception.Message -cmatch '[A-Z][A-Z0-9_]{5,127}'){[string]$Matches[0]}else{'PERSISTENT_STORAGE_REMOVAL_EXECUTION_FAILED'}
        if($journal){
            $journal.Status='RECOVERY_REQUIRED';$journal.Recovery.Status='RETRY_EXECUTION';$journal.Recovery.ErrorCode=$errorCode
            $journal.Recovery.Errors=@($journal.Recovery.Errors)+@($errorCode)
            try{$null=Write-LabPersistentStorageRemovalJournal -Journal $journal -Path $journalPath}catch{}
            throw "PERSISTENT_STORAGE_REMOVAL_RECOVERY_REQUIRED: $errorCode"
        }
        throw
    }
    finally { if($acquired){try{$mutex.ReleaseMutex()}catch{}}; $mutex.Dispose() }
}
