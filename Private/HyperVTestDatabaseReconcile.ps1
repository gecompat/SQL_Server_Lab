<#
.SYNOPSIS
    Plant und reconciliert katalogisierte Testdatenbanken eines Hyper-V-Runs.
.DESCRIPTION
    Nur Datenbanken mit einem lokalen, VM-gebundenen Ownership-Receipt duerfen
    entfernt werden. Additionen verwenden den bestehenden verifizierten
    Sample-Handler. Vor jedem Drop wird im SQL-Default-Backupverzeichnis ein
    CHECKSUM-/VERIFYONLY-geprueftes Recovery-Backup erzeugt. Ein vor der ersten
    Mutation geschriebenes Journal ermoeglicht ausschliesslich die
    Vorwaertsfortsetzung des exakt gebundenen Zielmanifests.
#>

function Get-LabHyperVTestDatabaseOwnershipPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunDirectory)
    Join-Path $RunDirectory 'hyperv-test-database-ownership.local.json'
}

function Get-LabHyperVTestDatabaseReconcileJournalPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunDirectory)
    Join-Path $RunDirectory 'hyperv-test-database-reconcile.local.journal.json'
}

function Assert-LabHyperVTestDatabaseOwnershipReceipt {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Receipt)
    $schemaPath = Join-Path $script:SchemasPath 'hyperv-test-database-ownership.schema.json'
    if (-not (($Receipt | ConvertTo-Json -Depth 30) | Test-Json -SchemaFile $schemaPath -ErrorAction SilentlyContinue)) {
        throw 'HYPERV_TEST_DATABASE_OWNERSHIP_SCHEMA_INVALID'
    }
    return $true
}

function Assert-LabHyperVTestDatabaseReconcileJournal {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Journal)
    $schemaPath = Join-Path $script:SchemasPath 'hyperv-test-database-reconcile-journal.schema.json'
    if (-not (($Journal | ConvertTo-Json -Depth 40) | Test-Json -SchemaFile $schemaPath -ErrorAction SilentlyContinue)) {
        throw 'HYPERV_TEST_DATABASE_RECONCILE_JOURNAL_SCHEMA_INVALID'
    }
    return $true
}

function Write-LabHyperVTestDatabaseOwnershipReceipt {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Receipt, [Parameter(Mandatory)][string]$Path)
    $Receipt.Entries = @($Receipt.Entries | Sort-Object PlanKey)
    $Receipt.UpdatedAt = Get-LabTimestamp
    $null = Assert-LabHyperVTestDatabaseOwnershipReceipt -Receipt $Receipt
    Write-LabArtifactJsonAtomic -Path $Path -InputObject $Receipt
    return $Receipt
}

function Write-LabHyperVTestDatabaseReconcileJournal {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Journal, [Parameter(Mandatory)][string]$Path)
    $Journal.UpdatedAt = Get-LabTimestamp
    $null = Assert-LabHyperVTestDatabaseReconcileJournal -Journal $Journal
    Write-LabArtifactJsonAtomic -Path $Path -InputObject $Journal
    return $Journal
}

function Set-LabHyperVTestDatabaseReconcileJournalStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Journal,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidateSet('PREPARED','REMOVALS_APPLIED','ADDITIONS_APPLIED','VERIFIED','OWNERSHIP_UPDATED','DESIRED_STATE_UPDATED','RECOVERY_CLEANED','COMPLETED','RECOVERY_REQUIRED')][string]$Status,
        [string]$ErrorCode
    )
    $Journal.Status = $Status
    if ($ErrorCode) {
        $Journal.Recovery.ErrorCode = $ErrorCode
        $Journal.Recovery.Errors = @($Journal.Recovery.Errors) + @($ErrorCode)
    }
    if ($Status -eq 'COMPLETED') { $Journal.Recovery.Status = 'NOT_REQUIRED' }
    elseif ($Status -eq 'RECOVERY_REQUIRED') { $Journal.Recovery.Status = 'RETRY_TEST_DATABASE_RECONCILE' }
    return Write-LabHyperVTestDatabaseReconcileJournal -Journal $Journal -Path $Path
}

function New-LabHyperVTestDatabaseOwnershipEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$RestoreDefinition,
        [Parameter(Mandatory)]$SampleResult
    )
    $sha256 = if ($SampleResult.Artifact -and $SampleResult.Artifact.Sha256) { ([string]$SampleResult.Artifact.Sha256).ToLowerInvariant() } else { $null }
    if ($sha256 -notmatch '^[a-f0-9]{64}$') { throw 'HYPERV_TEST_DATABASE_ARTIFACT_HASH_MISSING' }
    return [PSCustomObject]@{
        PlanKey = Get-LabTestDatabasePlanKey -RestoreDefinition $RestoreDefinition
        SampleId = [string]$RestoreDefinition.sampleId
        SampleVariant = [string]$RestoreDefinition.sampleVariant
        DatabaseNames = @($SampleResult.DatabaseNames | ForEach-Object { [string]$_ } | Sort-Object -Unique)
        ArtifactSha256 = $sha256
        HandlerContractVersion = [string]$RestoreDefinition.handlerContractVersion
        InstalledAt = Get-LabTimestamp
    }
}

function Initialize-LabHyperVTestDatabaseOwnershipReceipt {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Lab)
    $receipt = [PSCustomObject]@{
        ContractVersion = 'SqlServerLab.HyperVTestDatabaseOwnership/1.0'
        RunId = [string]$Lab.Run.runId
        ScopeId = [string]$Lab.Run.scopeId
        InstanceId = [string]$Lab.Instance.id
        Provider = 'hyperv'
        VMId = [string]$Lab.Instance.vmId
        Entries = @()
        UpdatedAt = Get-LabTimestamp
    }
    $path = Get-LabHyperVTestDatabaseOwnershipPath -RunDirectory $Lab.RunDirectory
    return Write-LabHyperVTestDatabaseOwnershipReceipt -Receipt $receipt -Path $path
}

function Add-LabHyperVTestDatabaseOwnershipEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Receipt,
        [Parameter(Mandatory)]$Entry,
        [Parameter(Mandatory)][string]$RunDirectory
    )
    $conflicts = @($Receipt.Entries | Where-Object {
        [string]$_.PlanKey -eq [string]$Entry.PlanKey -or
        @($_.DatabaseNames | Where-Object { [string]$_ -in @($Entry.DatabaseNames) }).Count -gt 0
    })
    if ($conflicts.Count -gt 0) { throw 'HYPERV_TEST_DATABASE_OWNERSHIP_CONFLICT' }
    $Receipt.Entries = @($Receipt.Entries) + @($Entry)
    $path = Get-LabHyperVTestDatabaseOwnershipPath -RunDirectory $RunDirectory
    return Write-LabHyperVTestDatabaseOwnershipReceipt -Receipt $Receipt -Path $path
}

function Get-LabHyperVTestDatabaseCredentials {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunDirectory, [SecureString]$SqlSaPassword)
    $guestPassword = Get-LabSecret -Path $RunDirectory -Name 'guest-administrator-password'
    if (-not $SqlSaPassword) { $SqlSaPassword = Get-LabSecret -Path $RunDirectory -Name 'generated-sql-sa-password' }
    if (-not $SqlSaPassword) { $SqlSaPassword = Get-LabSecret -Path $RunDirectory -Name 'sa-password' }
    if (-not $guestPassword) { throw 'HYPERV_TEST_DATABASE_GUEST_CREDENTIAL_REQUIRED' }
    return [PSCustomObject]@{
        GuestCredential = [PSCredential]::new('Administrator', $guestPassword)
        SqlSaPassword = $SqlSaPassword
    }
}

function Get-LabHyperVTestDatabaseInstanceFingerprint {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Instance)
    return [ordered]@{
        Id=[string]$Instance.Id;Provider=[string]$Instance.Provider;Version=[string]$Instance.Version
        Profile=[string]$Instance.Profile;AutoStart=[string]$Instance.AutoStart
        Drives=@($Instance.Intents.Drives);Network=$Instance.Intents.Network;Resources=$Instance.Intents.Resources
        SqlEndpoint=$Instance.Intents.SqlEndpoint;SqlConfiguration=$Instance.Intents.SqlConfiguration
        Software=$Instance.Intents.Software;Storage=$Instance.Intents.Storage
    }
}

function Get-LabHyperVTestDatabaseTargetHash {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$Samples)
    $canonical = [ordered]@{
        Contract='SqlServerLab.HyperVTestDatabaseTarget/1.0'
        Samples=@($Samples | Sort-Object PlanKey | ForEach-Object {
            [ordered]@{PlanKey=[string]$_.PlanKey;SampleId=[string]$_.SampleId;SampleVariant=[string]$_.SampleVariant;DatabaseNames=@($_.DatabaseNames|Sort-Object)}
        })
    }
    return Get-LabSampleBaselineSha256Text -Text ($canonical | ConvertTo-Json -Depth 20 -Compress)
}

function Get-LabHyperVTestDatabaseTrustStatusReadOnly {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$RestoreDefinition,
        [string]$StateRoot
    )
    if ([string]$RestoreDefinition.expectedSha256 -match '^[A-Fa-f0-9]{64}$') { return 'catalog-verified' }
    $paths = Get-LabArtifactStorePaths -StateRoot $StateRoot
    if (-not (Test-Path -LiteralPath $paths.TrustStorePath -PathType Leaf)) { return 'TRUST_REQUIRED' }
    $store = Get-Content -LiteralPath $paths.TrustStorePath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 30
    $source = Get-LabCanonicalArtifactSource -Source ([string]$RestoreDefinition.source)
    $match = @($store.records | Where-Object {
        [string]$_.source -eq $source -and [string]$_.sampleId -eq [string]$RestoreDefinition.sampleId -and
        [string]$_.sampleVariant -eq [string]$RestoreDefinition.sampleVariant -and [string]$_.sha256 -match '^[a-f0-9]{64}$'
    } | Select-Object -First 1)
    if ($match.Count -eq 1) { return [string]$match[0].integrityOrigin }
    return 'TRUST_REQUIRED'
}

function Read-LabHyperVTestDatabaseOwnershipReceipt {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Context)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw 'HYPERV_TEST_DATABASE_OWNERSHIP_MISSING' }
    $receipt = Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json -Depth 30
    $null = Assert-LabHyperVTestDatabaseOwnershipReceipt -Receipt $receipt
    if ([string]$receipt.RunId -ne [string]$Context.RunId -or [string]$receipt.ScopeId -ne [string]$Context.ScopeId -or
        [string]$receipt.InstanceId -ne [string]$Context.InstanceId -or [string]$receipt.VMId -ne [string]$Context.VM.Id) {
        throw 'HYPERV_TEST_DATABASE_OWNERSHIP_IDENTITY_MISMATCH'
    }
    return $receipt
}

function Read-LabHyperVTestDatabaseReconcileJournal {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Context)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $journal = Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json -Depth 40
    $null = Assert-LabHyperVTestDatabaseReconcileJournal -Journal $journal
    if ([string]$journal.RunId -ne [string]$Context.RunId -or [string]$journal.ScopeId -ne [string]$Context.ScopeId -or
        [string]$journal.InstanceId -ne [string]$Context.InstanceId -or [string]$journal.Runtime.VMId -ne [string]$Context.VM.Id) {
        throw 'HYPERV_TEST_DATABASE_RECONCILE_JOURNAL_IDENTITY_MISMATCH'
    }
    if ([string]$journal.TargetHash -ne [string]$Context.TargetHash) {
        if ([string]$journal.Status -eq 'COMPLETED') { return $null }
        throw 'HYPERV_TEST_DATABASE_RECONCILE_JOURNAL_TARGET_MISMATCH'
    }
    return $journal
}

function Get-LabHyperVTestDatabaseReconcileContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$ManifestPath,
        [Parameter(Mandatory)][string]$InstanceId,
        [string]$StateRoot
    )
    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
    $run = Get-LabRunState -RunId $RunId -StateRoot $StateRoot
    if ([string]$run.metadata.workflowKind -ne 'hyperv-lab') { throw 'HYPERV_TEST_DATABASE_RECONCILE_HYPERV_RUN_REQUIRED' }
    if ([string]$run.state -ne 'RUNNING') { throw "HYPERV_TEST_DATABASE_RECONCILE_RUN_NOT_RUNNING: $($run.state)" }
    $guard = Get-LabHyperVResourceMigrationLifecycleGuard -RunId $RunId -StateRoot $StateRoot
    if (-not $guard.Allowed) { throw "HYPERV_TEST_DATABASE_RECONCILE_MIGRATION_BLOCKED: $([string]$guard.ReasonCode)" }
    $persisted = Get-LabPersistedDesiredState -RunId $RunId -StateRoot $StateRoot
    if ([string]$persisted.Status -ne 'VALID') { throw 'HYPERV_TEST_DATABASE_RECONCILE_DESIRED_STATE_INVALID' }
    $resolved = Read-LabManifest -Path $ManifestPath
    $desiredSnapshot = New-LabDesiredStateSnapshot -ResolvedLab $resolved -ProvisioningMode ([string]$persisted.Snapshot.ProvisioningMode) -PersistentData ([bool]$persisted.Snapshot.PersistentData)
    if ([string]$resolved.name -ne [string]$persisted.Snapshot.LabName) { throw 'HYPERV_TEST_DATABASE_RECONCILE_LAB_IDENTITY_CHANGED' }
    $currentIds = @($persisted.Snapshot.Instances | ForEach-Object { [string]$_.Id } | Sort-Object)
    $targetIds = @($desiredSnapshot.Instances | ForEach-Object { [string]$_.Id } | Sort-Object)
    if (($currentIds -join ',') -cne ($targetIds -join ',')) { throw 'HYPERV_TEST_DATABASE_RECONCILE_INSTANCE_SET_CHANGED' }
    $currentInstances = @($persisted.Snapshot.Instances | Where-Object { [string]$_.Id -eq $InstanceId })
    $targetInstances = @($desiredSnapshot.Instances | Where-Object { [string]$_.Id -eq $InstanceId })
    $resolvedInstances = @($resolved.instances | Where-Object { [string]$_.id -eq $InstanceId })
    if ($currentInstances.Count -ne 1 -or $targetInstances.Count -ne 1 -or $resolvedInstances.Count -ne 1) {
        throw 'HYPERV_TEST_DATABASE_RECONCILE_TARGET_NOT_UNIQUE'
    }
    if ([string]$targetInstances[0].Provider -ne 'hyperv') { throw 'HYPERV_TEST_DATABASE_RECONCILE_PROVIDER_UNSUPPORTED' }
    foreach ($other in @($persisted.Snapshot.Instances | Where-Object { [string]$_.Id -ne $InstanceId })) {
        $targetOther = @($desiredSnapshot.Instances | Where-Object { [string]$_.Id -eq [string]$other.Id })
        if ($targetOther.Count -ne 1 -or (($other | ConvertTo-Json -Depth 50 -Compress) -cne ($targetOther[0] | ConvertTo-Json -Depth 50 -Compress))) {
            throw "HYPERV_TEST_DATABASE_RECONCILE_OTHER_INSTANCE_CHANGED: $($other.Id)"
        }
    }
    $currentDbIntent = $currentInstances[0].Intents.Databases
    $targetDbIntent = $targetInstances[0].Intents.Databases
    if (-not $currentDbIntent -or [string]$currentDbIntent.Contract.Name -ne 'SqlServerLab.DatabaseIntent' -or
        [string]$currentDbIntent.Contract.Version -ne '1.0') { throw 'HYPERV_TEST_DATABASE_RECONCILE_CURRENT_INTENT_MISSING' }
    if (-not $targetDbIntent -or [string]$targetDbIntent.Contract.Name -ne 'SqlServerLab.DatabaseIntent' -or
        [string]$targetDbIntent.Contract.Version -ne '1.0') { throw 'HYPERV_TEST_DATABASE_RECONCILE_TARGET_INTENT_MISSING' }
    $currentFingerprint = (Get-LabHyperVTestDatabaseInstanceFingerprint -Instance $currentInstances[0]) | ConvertTo-Json -Depth 50 -Compress
    $targetFingerprint = (Get-LabHyperVTestDatabaseInstanceFingerprint -Instance $targetInstances[0]) | ConvertTo-Json -Depth 50 -Compress
    if ($currentFingerprint -cne $targetFingerprint) { throw 'HYPERV_TEST_DATABASE_RECONCILE_NON_DATABASE_DRIFT' }
    $currentNonSamples = @($currentDbIntent.Items | Where-Object Type -ne 'catalog-sample' | Sort-Object Type,Name)
    $targetNonSamples = @($targetDbIntent.Items | Where-Object Type -ne 'catalog-sample' | Sort-Object Type,Name)
    if (($currentNonSamples | ConvertTo-Json -Depth 30 -Compress) -cne ($targetNonSamples | ConvertTo-Json -Depth 30 -Compress)) {
        throw 'HYPERV_TEST_DATABASE_RECONCILE_NON_SAMPLE_CHANGE_UNSUPPORTED'
    }
    if (@($resolvedInstances[0].databases).Count -gt 0) {
        if (-not $resolvedInstances[0].storageIntent) { throw 'HYPERV_TEST_DATABASE_RECONCILE_STORAGE_INTENT_REQUIRED' }
        $null = Assert-LabStorageManifestDatabaseCoverage -StorageIntent $resolvedInstances[0].storageIntent -Databases @($resolvedInstances[0].databases)
    }
    $desiredSamples = [Collections.Generic.List[object]]::new()
    foreach ($database in @($resolvedInstances[0].databases | Where-Object { $_.restore -and $_.restore.sampleId })) {
        $intent = @($targetDbIntent.Items | Where-Object { [string]$_.Type -eq 'catalog-sample' -and [string]$_.Name -eq [string]$database.name })
        if ($intent.Count -ne 1 -or -not $intent[0].ReconcileSupported) { throw 'HYPERV_TEST_DATABASE_RECONCILE_SAMPLE_INTENT_INVALID' }
        $trustStatus = Get-LabHyperVTestDatabaseTrustStatusReadOnly -RestoreDefinition $database.restore -StateRoot $StateRoot
        $desiredSamples.Add([PSCustomObject]@{
            PlanKey=[string]$intent[0].PlanKey;SampleId=[string]$database.restore.sampleId;SampleVariant=[string]$database.restore.sampleVariant
            DatabaseNames=@($intent[0].ExpectedDatabaseNames);RestoreDefinition=$database.restore;TrustStatus=[string]$trustStatus
        })
    }
    if (@($desiredSamples | Group-Object PlanKey | Where-Object Count -gt 1).Count -gt 0) { throw 'HYPERV_TEST_DATABASE_RECONCILE_DUPLICATE_SAMPLE' }
    $allOutputs = @($desiredSamples | ForEach-Object { @($_.DatabaseNames) })
    if (@($allOutputs | Group-Object | Where-Object Count -gt 1).Count -gt 0) { throw 'HYPERV_TEST_DATABASE_RECONCILE_OUTPUT_COLLISION' }

    $runDirectory = Join-Path (Join-Path $StateRoot 'runs') $RunId
    $connectionPath = Join-Path $runDirectory 'connection-info.json'
    if (-not (Test-Path -LiteralPath $connectionPath -PathType Leaf)) { throw 'HYPERV_TEST_DATABASE_RECONCILE_CONNECTION_MISSING' }
    $connection = Get-Content -LiteralPath $connectionPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 50
    $connectionInstances = @($connection.instances | Where-Object { [string]$_.id -eq $InstanceId -and [string]$_.provider -eq 'hyperv' })
    if ($connectionInstances.Count -ne 1 -or -not $connectionInstances[0].vmName) { throw 'HYPERV_TEST_DATABASE_RECONCILE_CONNECTION_INSTANCE_NOT_UNIQUE' }
    $managed = Get-HyperVManagedVM -VMName ([string]$connectionInstances[0].vmName) -ExpectedRunId $RunId -ExpectedScopeId ([string]$run.scopeId)
    if (-not $managed -or [string]$managed.VM.State -ne 'Running') { throw 'HYPERV_TEST_DATABASE_RECONCILE_VM_RUNNING_REQUIRED' }
    if ($connectionInstances[0].vmId -and [string]$connectionInstances[0].vmId -ne [string]$managed.VM.Id) { throw 'HYPERV_TEST_DATABASE_RECONCILE_VM_IDENTITY_MISMATCH' }
    $context = [PSCustomObject]@{
        RunId=$RunId;ScopeId=[string]$run.scopeId;InstanceId=$InstanceId;StateRoot=$StateRoot;Run=$run
        RunDirectory=$runDirectory;ConnectionPath=$connectionPath;Connection=$connection;ConnectionInstance=$connectionInstances[0]
        VM=$managed.VM;Managed=$managed;PersistedSnapshot=$persisted.Snapshot;DesiredSnapshot=$desiredSnapshot
        ResolvedManifest=$resolved;ResolvedInstance=$resolvedInstances[0];DesiredSamples=@($desiredSamples)
        TargetHash=Get-LabHyperVTestDatabaseTargetHash -Samples @($desiredSamples)
    }
    $ownershipPath = Get-LabHyperVTestDatabaseOwnershipPath -RunDirectory $runDirectory
    $context | Add-Member -NotePropertyName OwnershipPath -NotePropertyValue $ownershipPath
    $context | Add-Member -NotePropertyName Ownership -NotePropertyValue (Read-LabHyperVTestDatabaseOwnershipReceipt -Path $ownershipPath -Context $context)
    return $context
}

function Get-LabHyperVTestDatabaseActualState {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][PSCredential]$Credential)
    $result = Invoke-HyperVPowerShellDirect -VMName ([string]$Context.ConnectionInstance.vmName) -ExpectedRunId ([string]$Context.RunId) `
        -ExpectedScopeId ([string]$Context.ScopeId) -Credential $Credential -ScriptBlock {
        $ErrorActionPreference='Stop';Add-Type -AssemblyName System.Data
        $connection=[Data.SqlClient.SqlConnection]::new('Server=localhost;Database=master;Integrated Security=True;Encrypt=True;TrustServerCertificate=True;Connect Timeout=30;')
        try {
            $connection.Open();$command=$connection.CreateCommand();$command.CommandText="SET NOCOUNT ON; SELECT name,state_desc FROM sys.databases WHERE database_id > 4 ORDER BY name;"
            $reader=$command.ExecuteReader();$items=@();while($reader.Read()){$items+=[PSCustomObject]@{Name=[string]$reader.GetString(0);State=[string]$reader.GetString(1)}}
            $reader.Dispose();[PSCustomObject]@{Status='AVAILABLE';Databases=$items;ObservedAt=[datetime]::UtcNow.ToString('o')}
        }
        finally{$connection.Dispose()}
    }
    $actual=@($result)[-1]
    if(-not$actual -or [string]$actual.Status -ne 'AVAILABLE'){throw 'HYPERV_TEST_DATABASE_RECONCILE_ACTUAL_UNAVAILABLE'}
    return $actual
}

function Get-LabHyperVTestDatabaseReconcileDiff {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context,[Parameter(Mandatory)]$Actual,$Journal)
    $diff=[Collections.Generic.List[object]]::new()
    $actualOnline=@($Actual.Databases|Where-Object State -eq 'ONLINE'|ForEach-Object{[string]$_.Name})
    $actualNames=@($Actual.Databases|ForEach-Object{[string]$_.Name})
    $owned=@($Context.Ownership.Entries)
    $desired=@($Context.DesiredSamples)
    $removals=@($owned|Where-Object{[string]$_.PlanKey -notin @($desired.PlanKey)})
    $removalNames=@($removals|ForEach-Object{@($_.DatabaseNames)})
    foreach($entry in $owned|Where-Object{[string]$_.PlanKey -in @($desired.PlanKey)}){
        if(@($entry.DatabaseNames|Where-Object{[string]$_ -notin $actualOnline}).Count -gt 0){
            $diff.Add([PSCustomObject]@{Kind='owned-output-drift';Supported=$false;Entry=$entry})
        }
    }
    foreach($sample in $desired|Where-Object{[string]$_.PlanKey -notin @($owned.PlanKey)}){
        $conflicts=@($sample.DatabaseNames|Where-Object{[string]$_ -in $actualNames -and [string]$_ -notin $removalNames})
        $recovering=$Journal -and [string]$Journal.Status -ne 'COMPLETED' -and @($Journal.Additions|Where-Object{[string]$_.PlanKey -eq [string]$sample.PlanKey -and [string]$_.Status -eq 'APPLYING'}).Count -eq 1
        if($conflicts.Count -gt 0 -and -not$recovering){$diff.Add([PSCustomObject]@{Kind='unowned-output-conflict';Supported=$false;Entry=$sample})}
        elseif([string]$sample.TrustStatus -eq 'TRUST_REQUIRED'){$diff.Add([PSCustomObject]@{Kind='artifact-trust-required';Supported=$false;Entry=$sample})}
        elseif((-not$Context.ConnectionInstance.host)-or [int]$Context.ConnectionInstance.port -lt 1){$diff.Add([PSCustomObject]@{Kind='host-sql-access-required-for-addition';Supported=$false;Entry=$sample})}
        else{$diff.Add([PSCustomObject]@{Kind='add-sample';Supported=$true;Entry=$sample})}
    }
    foreach($entry in $removals){$diff.Add([PSCustomObject]@{Kind='remove-owned-sample';Supported=$true;Entry=$entry})}
    return @($diff)
}

function New-LabHyperVTestDatabaseReconcilePlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunId,[Parameter(Mandatory)][string]$ManifestPath,[Parameter(Mandatory)][string]$InstanceId,[string]$StateRoot)
    try{
        $context=Get-LabHyperVTestDatabaseReconcileContext @PSBoundParameters
        $credentials=Get-LabHyperVTestDatabaseCredentials -RunDirectory $context.RunDirectory
        $actual=Get-LabHyperVTestDatabaseActualState -Context $context -Credential $credentials.GuestCredential
        $journalPath=Get-LabHyperVTestDatabaseReconcileJournalPath -RunDirectory $context.RunDirectory
        $journal=Read-LabHyperVTestDatabaseReconcileJournal -Path $journalPath -Context $context
        $diff=@(Get-LabHyperVTestDatabaseReconcileDiff -Context $context -Actual $actual -Journal $journal)
    }
    catch{
        $code=if($_.Exception.Message -cmatch '[A-Z][A-Z0-9_]{5,127}'){[string]$Matches[0]}else{'HYPERV_TEST_DATABASE_RECONCILE_UNAVAILABLE'}
        return [PSCustomObject]@{
            Contract=[PSCustomObject]@{Name='SqlServerLab.HyperVTestDatabaseReconcilePlan';Version='1.0'};RunId=$RunId;InstanceId=$InstanceId;Provider='hyperv'
            Desired=[PSCustomObject]@{Status='DECLARED';Samples=@()};Actual=[PSCustomObject]@{Status='UNAVAILABLE';ManagedSampleCount=0;OnlineOutputCount=0}
            Diff=@();Actions=@();HighestChangeClass='unsupported';IsNoOp=$false;MutationAllowed=$false;Warnings=@('Der Testdatenbankzustand ist nicht eindeutig steuerbar.');ReasonCodes=@($code)
        }
    }
    $unsupported=@($diff|Where-Object{-not$_.Supported});$recoveryPending=$journal -and [string]$journal.Status -ne 'COMPLETED'
    $changeClass=if($unsupported.Count){'unsupported'}elseif($diff.Count -or $recoveryPending){'live'}else{'no-op'}
    $actions=if($changeClass -eq 'live'){@([PSCustomObject]@{Operation=if($recoveryPending){'ResumeHyperVTestDatabases'}else{'ReconcileHyperVTestDatabases'};ChangeClass='live';AddCount=@($diff|Where-Object Kind -eq 'add-sample').Count;RemoveCount=@($diff|Where-Object Kind -eq 'remove-owned-sample').Count;RecoveryPending=[bool]$recoveryPending})}else{@()}
    return [PSCustomObject]@{
        Contract=[PSCustomObject]@{Name='SqlServerLab.HyperVTestDatabaseReconcilePlan';Version='1.0'};RunId=$RunId;InstanceId=$InstanceId;Provider='hyperv'
        Desired=[PSCustomObject]@{Status='RESOLVED';Samples=@($context.DesiredSamples|Sort-Object PlanKey|ForEach-Object{[PSCustomObject]@{SampleId=[string]$_.SampleId;Variant=[string]$_.SampleVariant;DatabaseNames=@($_.DatabaseNames)}})}
        Actual=[PSCustomObject]@{Status='AVAILABLE';ManagedSampleCount=@($context.Ownership.Entries).Count;OnlineOutputCount=@($actual.Databases|Where-Object State -eq 'ONLINE').Count}
        Diff=@($diff|ForEach-Object{[PSCustomObject]@{Kind=[string]$_.Kind;SampleId=[string]$_.Entry.SampleId;Variant=[string]$_.Entry.SampleVariant;DatabaseNames=@($_.Entry.DatabaseNames);ChangeClass=if($_.Supported){'live'}else{'unsupported'}}})
        Actions=$actions;HighestChangeClass=$changeClass;IsNoOp=($changeClass -eq 'no-op');MutationAllowed=$false
        Warnings=if($unsupported.Count){@('Nur eindeutig eigentumsgebundene Sample-Ausgaben werden mutiert; Konflikte bleiben fail-closed.')}elseif(@($diff|Where-Object Kind -eq 'remove-owned-sample').Count){@('Entfernte run-eigene Samples werden vor dem Drop mit CHECKSUM gesichert und per RESTORE VERIFYONLY geprueft.')}else{@()}
        ReasonCodes=@($(if($recoveryPending){'HYPERV_TEST_DATABASE_RECONCILE_RECOVERY_PENDING'});$(if($unsupported.Count){'HYPERV_TEST_DATABASE_RECONCILE_UNSUPPORTED'}))
    }
}

function Invoke-LabHyperVTestDatabaseRemoval {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context,[Parameter(Mandatory)][PSCredential]$Credential,[Parameter(Mandatory)][string]$OperationId,[Parameter(Mandatory)][string[]]$DatabaseNames)
    $result=Invoke-HyperVPowerShellDirect -VMName ([string]$Context.ConnectionInstance.vmName) -ExpectedRunId ([string]$Context.RunId) -ExpectedScopeId ([string]$Context.ScopeId) `
        -Credential $Credential -ArgumentList @($OperationId,@($DatabaseNames)) -ScriptBlock {
        param($OperationId,$DatabaseNames)
        $ErrorActionPreference='Stop';Add-Type -AssemblyName System.Data
        if($OperationId -notmatch '^[a-f0-9-]{36}$'){throw 'HYPERV_TEST_DATABASE_OPERATION_ID_INVALID'}
        $connection=[Data.SqlClient.SqlConnection]::new('Server=localhost;Database=master;Integrated Security=True;Encrypt=True;TrustServerCertificate=True;Connect Timeout=30;')
        try{
            $connection.Open();$results=@()
            foreach($name in @($DatabaseNames)){
                if([string]$name -notmatch '^[A-Za-z][A-Za-z0-9_]*$'){throw 'HYPERV_TEST_DATABASE_NAME_INVALID'}
                $check=$connection.CreateCommand();$check.CommandText='SELECT COUNT_BIG(*) FROM sys.databases WHERE name=@name;';$null=$check.Parameters.Add('@name',[Data.SqlDbType]::NVarChar,128);$check.Parameters['@name'].Value=$name
                if([long]$check.ExecuteScalar() -eq 0){$results+=[PSCustomObject]@{DatabaseName=$name;Status='ALREADY_ABSENT'};continue}
                $pathCommand=$connection.CreateCommand();$pathCommand.CommandText="SELECT CONVERT(nvarchar(4000),SERVERPROPERTY('InstanceDefaultBackupPath'));";$backupRoot=[string]$pathCommand.ExecuteScalar()
                if([string]::IsNullOrWhiteSpace($backupRoot)){throw 'HYPERV_TEST_DATABASE_BACKUP_ROOT_MISSING'}
                $backupPath=Join-Path $backupRoot ("SqlServerLab-Reconcile-$OperationId-$name.bak");$escapedPath=$backupPath.Replace("'","''")
                $command=$connection.CreateCommand();$command.CommandTimeout=900;$command.CommandText="BACKUP DATABASE [$name] TO DISK=N'$escapedPath' WITH COPY_ONLY,CHECKSUM,INIT; RESTORE VERIFYONLY FROM DISK=N'$escapedPath' WITH CHECKSUM; ALTER DATABASE [$name] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$name];";$null=$command.ExecuteNonQuery()
                $results+=[PSCustomObject]@{DatabaseName=$name;Status='BACKED_UP_VERIFIED_AND_DROPPED'}
            }
            [PSCustomObject]@{Status='APPLIED';Databases=$results}
        }
        finally{$connection.Dispose()}
    }
    $receipt=@($result)[-1];if(-not$receipt -or [string]$receipt.Status -ne 'APPLIED'){throw 'HYPERV_TEST_DATABASE_REMOVAL_RECEIPT_INVALID'};return $receipt
}

function Remove-LabHyperVTestDatabasePartialOutputs {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context,[Parameter(Mandatory)][PSCredential]$Credential,[Parameter(Mandatory)][string[]]$DatabaseNames)
    $null=Invoke-HyperVPowerShellDirect -VMName ([string]$Context.ConnectionInstance.vmName) -ExpectedRunId ([string]$Context.RunId) -ExpectedScopeId ([string]$Context.ScopeId) `
        -Credential $Credential -ArgumentList @(,@($DatabaseNames)) -ScriptBlock {
        param($DatabaseNames);$ErrorActionPreference='Stop';Add-Type -AssemblyName System.Data
        $connection=[Data.SqlClient.SqlConnection]::new('Server=localhost;Database=master;Integrated Security=True;Encrypt=True;TrustServerCertificate=True;Connect Timeout=30;')
        try{$connection.Open();foreach($name in @($DatabaseNames)){if([string]$name -notmatch '^[A-Za-z][A-Za-z0-9_]*$'){throw 'HYPERV_TEST_DATABASE_NAME_INVALID'};$command=$connection.CreateCommand();$command.CommandText="IF DB_ID(N'$name') IS NOT NULL BEGIN ALTER DATABASE [$name] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$name]; END";$null=$command.ExecuteNonQuery()}}
        finally{$connection.Dispose()}
    }
}

function Remove-LabHyperVTestDatabaseRecoveryBackups {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context,[Parameter(Mandatory)][PSCredential]$Credential,[Parameter(Mandatory)][string]$OperationId)
    $null=Invoke-HyperVPowerShellDirect -VMName ([string]$Context.ConnectionInstance.vmName) -ExpectedRunId ([string]$Context.RunId) -ExpectedScopeId ([string]$Context.ScopeId) `
        -Credential $Credential -ArgumentList @($OperationId) -ScriptBlock {
        param($OperationId);$ErrorActionPreference='Stop';Add-Type -AssemblyName System.Data
        $connection=[Data.SqlClient.SqlConnection]::new('Server=localhost;Database=master;Integrated Security=True;Encrypt=True;TrustServerCertificate=True;Connect Timeout=30;')
        try{$connection.Open();$command=$connection.CreateCommand();$command.CommandText="SELECT CONVERT(nvarchar(4000),SERVERPROPERTY('InstanceDefaultBackupPath'));";$root=[string]$command.ExecuteScalar()}
        finally{$connection.Dispose()}
        if($root -and (Test-Path -LiteralPath $root -PathType Container)){Get-ChildItem -LiteralPath $root -Filter "SqlServerLab-Reconcile-$OperationId-*.bak" -File -ErrorAction Stop|Remove-Item -Force -ErrorAction Stop}
    }
}

function Sync-LabHyperVTestDatabaseState {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context,[Parameter(Mandatory)]$Actual,[Parameter(Mandatory)]$Ownership)
    $Context.ConnectionInstance | Add-Member -NotePropertyName databases -NotePropertyValue @($Actual.Databases|ForEach-Object{[string]$_.Name}|Sort-Object) -Force
    Write-LabArtifactJsonAtomic -Path $Context.ConnectionPath -InputObject $Context.Connection
    $Context.Run.metadata | Add-Member -NotePropertyName desiredState -NotePropertyValue $Context.DesiredSnapshot -Force
    $Context.Run.updatedAt=Get-LabTimestamp
    Write-LabArtifactJsonAtomic -Path (Join-Path $Context.RunDirectory 'run-state.json') -InputObject $Context.Run
}

function Invoke-LabHyperVTestDatabaseReconcileRepair {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunId,[Parameter(Mandatory)][string]$ManifestPath,[Parameter(Mandatory)][string]$InstanceId,[SecureString]$SqlSaPassword,[string]$StateRoot)
    $mutex=[Threading.Mutex]::new($false,"Global\SQL_Server_Lab_HyperV_Test_Database_Reconcile_$($RunId.Replace('-',''))");$acquired=$false;$journal=$null;$journalPath=$null
    try{
        $acquired=$mutex.WaitOne([TimeSpan]::FromMinutes(5));if(-not$acquired){throw 'HYPERV_TEST_DATABASE_RECONCILE_LOCK_TIMEOUT'}
        $context=Get-LabHyperVTestDatabaseReconcileContext -RunId $RunId -ManifestPath $ManifestPath -InstanceId $InstanceId -StateRoot $StateRoot
        $credentials=Get-LabHyperVTestDatabaseCredentials -RunDirectory $context.RunDirectory -SqlSaPassword $SqlSaPassword
        $journalPath=Get-LabHyperVTestDatabaseReconcileJournalPath -RunDirectory $context.RunDirectory;$journal=Read-LabHyperVTestDatabaseReconcileJournal -Path $journalPath -Context $context
        $actual=Get-LabHyperVTestDatabaseActualState -Context $context -Credential $credentials.GuestCredential
        $diff=@(Get-LabHyperVTestDatabaseReconcileDiff -Context $context -Actual $actual -Journal $journal)
        if(@($diff|Where-Object{-not$_.Supported}).Count){throw 'HYPERV_TEST_DATABASE_RECONCILE_UNSUPPORTED'}
        if($journal -and [string]$journal.Status -ne 'COMPLETED'){$journal.Recovery.Attempts=[int]$journal.Recovery.Attempts+1;$null=Write-LabHyperVTestDatabaseReconcileJournal -Journal $journal -Path $journalPath}
        elseif($journal -and [string]$journal.Status -eq 'COMPLETED' -and $diff.Count -eq 0){return [PSCustomObject]@{Status='NO_OP';RunId=$RunId;InstanceId=$InstanceId;Changed=$false;Added=0;Removed=0}}
        elseif($journal -and [string]$journal.Status -eq 'COMPLETED'){$journal=$null}
        if(-not$journal){
            if($diff.Count -eq 0){return [PSCustomObject]@{Status='NO_OP';RunId=$RunId;InstanceId=$InstanceId;Changed=$false;Added=0;Removed=0}}
            $journal=[PSCustomObject]@{
                ContractVersion='SqlServerLab.HyperVTestDatabaseReconcileJournal/1.0';OperationId=[Guid]::NewGuid().ToString('D');RunId=$RunId;ScopeId=[string]$context.ScopeId;InstanceId=$InstanceId;Provider='hyperv';ChangeClass='live';Status='PREPARED';TargetHash=[string]$context.TargetHash
                Runtime=[PSCustomObject]@{VMId=[string]$context.VM.Id}
                Additions=@($diff|Where-Object Kind -eq 'add-sample'|ForEach-Object{[PSCustomObject]@{PlanKey=[string]$_.Entry.PlanKey;SampleId=[string]$_.Entry.SampleId;SampleVariant=[string]$_.Entry.SampleVariant;DatabaseNames=@($_.Entry.DatabaseNames);ArtifactSha256=$null;HandlerContractVersion=$null;Status='PENDING'}})
                Removals=@($diff|Where-Object Kind -eq 'remove-owned-sample'|ForEach-Object{[PSCustomObject]@{PlanKey=[string]$_.Entry.PlanKey;SampleId=[string]$_.Entry.SampleId;SampleVariant=[string]$_.Entry.SampleVariant;DatabaseNames=@($_.Entry.DatabaseNames);ArtifactSha256=[string]$_.Entry.ArtifactSha256;HandlerContractVersion=[string]$_.Entry.HandlerContractVersion;Status='PENDING'}})
                Recovery=[PSCustomObject]@{Status='RETRY_TEST_DATABASE_RECONCILE';Attempts=0;ErrorCode=$null;Errors=@()};UpdatedAt=Get-LabTimestamp
            };$null=Write-LabHyperVTestDatabaseReconcileJournal -Journal $journal -Path $journalPath
        }
        foreach($item in @($journal.Removals|Where-Object Status -ne 'APPLIED')){$item.Status='APPLYING';$null=Write-LabHyperVTestDatabaseReconcileJournal -Journal $journal -Path $journalPath;$null=Invoke-LabHyperVTestDatabaseRemoval -Context $context -Credential $credentials.GuestCredential -OperationId ([string]$journal.OperationId) -DatabaseNames @($item.DatabaseNames);$item.Status='APPLIED';$null=Write-LabHyperVTestDatabaseReconcileJournal -Journal $journal -Path $journalPath}
        $null=Set-LabHyperVTestDatabaseReconcileJournalStatus -Journal $journal -Path $journalPath -Status REMOVALS_APPLIED
        foreach($item in @($journal.Additions|Where-Object Status -ne 'APPLIED')){
            if([string]$item.Status -eq 'APPLYING'){Remove-LabHyperVTestDatabasePartialOutputs -Context $context -Credential $credentials.GuestCredential -DatabaseNames @($item.DatabaseNames);$item.Status='PENDING';$null=Write-LabHyperVTestDatabaseReconcileJournal -Journal $journal -Path $journalPath}
            if(-not$credentials.SqlSaPassword){throw 'HYPERV_TEST_DATABASE_SQL_CREDENTIAL_REQUIRED'}
            $sample=@($context.DesiredSamples|Where-Object{[string]$_.PlanKey -eq [string]$item.PlanKey});if($sample.Count -ne 1){throw 'HYPERV_TEST_DATABASE_RECONCILE_SAMPLE_PLAN_MISSING'}
            $item.Status='APPLYING';$null=Write-LabHyperVTestDatabaseReconcileJournal -Journal $journal -Path $journalPath
            $result=Install-LabSampleDatabase -Provider hyperv -HostName ([string]$context.ConnectionInstance.host) -Port ([int]$context.ConnectionInstance.port) -SaPassword $credentials.SqlSaPassword -RunId $RunId -InstanceId $InstanceId -GuestCredential $credentials.GuestCredential -RestoreDefinition $sample[0].RestoreDefinition -SqlVersion ([string]$context.ResolvedInstance.version) -NonInteractive -RunDirectory $context.RunDirectory -StateRoot $context.StateRoot
            if(-not$result.Success){throw "HYPERV_TEST_DATABASE_SAMPLE_INSTALL_FAILED: $($result.Status)"}
            $entry=New-LabHyperVTestDatabaseOwnershipEntry -RestoreDefinition $sample[0].RestoreDefinition -SampleResult $result;$item.ArtifactSha256=[string]$entry.ArtifactSha256;$item.HandlerContractVersion=[string]$entry.HandlerContractVersion;$item.Status='APPLIED';$null=Write-LabHyperVTestDatabaseReconcileJournal -Journal $journal -Path $journalPath
        }
        $null=Set-LabHyperVTestDatabaseReconcileJournalStatus -Journal $journal -Path $journalPath -Status ADDITIONS_APPLIED
        $actual=Get-LabHyperVTestDatabaseActualState -Context $context -Credential $credentials.GuestCredential;$online=@($actual.Databases|Where-Object State -eq 'ONLINE'|ForEach-Object{[string]$_.Name});$actualNames=@($actual.Databases|ForEach-Object{[string]$_.Name})
        foreach($sample in @($context.DesiredSamples)){if(@($sample.DatabaseNames|Where-Object{[string]$_ -notin $online}).Count){throw 'HYPERV_TEST_DATABASE_RECONCILE_POSTCONDITION_MISSING'}}
        foreach($item in @($journal.Removals)){if(@($item.DatabaseNames|Where-Object{[string]$_ -in $actualNames}).Count){throw 'HYPERV_TEST_DATABASE_RECONCILE_POSTCONDITION_REMOVAL_FAILED'}}
        $null=Set-LabHyperVTestDatabaseReconcileJournalStatus -Journal $journal -Path $journalPath -Status VERIFIED
        $entries=[Collections.Generic.List[object]]::new();foreach($sample in @($context.DesiredSamples)){$existing=@($context.Ownership.Entries|Where-Object{[string]$_.PlanKey -eq [string]$sample.PlanKey});if($existing.Count -eq 1){$entries.Add($existing[0])}else{$item=@($journal.Additions|Where-Object{[string]$_.PlanKey -eq [string]$sample.PlanKey});if($item.Count -ne 1 -or [string]$item.ArtifactSha256 -notmatch '^[a-f0-9]{64}$'){throw 'HYPERV_TEST_DATABASE_RECONCILE_OWNERSHIP_ENTRY_MISSING'};$entries.Add([PSCustomObject]@{PlanKey=[string]$item.PlanKey;SampleId=[string]$item.SampleId;SampleVariant=[string]$item.SampleVariant;DatabaseNames=@($item.DatabaseNames);ArtifactSha256=[string]$item.ArtifactSha256;HandlerContractVersion=[string]$item.HandlerContractVersion;InstalledAt=Get-LabTimestamp})}}
        $context.Ownership.Entries=@($entries);$null=Write-LabHyperVTestDatabaseOwnershipReceipt -Receipt $context.Ownership -Path $context.OwnershipPath;$null=Set-LabHyperVTestDatabaseReconcileJournalStatus -Journal $journal -Path $journalPath -Status OWNERSHIP_UPDATED
        Sync-LabHyperVTestDatabaseState -Context $context -Actual $actual -Ownership $context.Ownership;$null=Set-LabHyperVTestDatabaseReconcileJournalStatus -Journal $journal -Path $journalPath -Status DESIRED_STATE_UPDATED
        Remove-LabHyperVTestDatabaseRecoveryBackups -Context $context -Credential $credentials.GuestCredential -OperationId ([string]$journal.OperationId);$null=Set-LabHyperVTestDatabaseReconcileJournalStatus -Journal $journal -Path $journalPath -Status RECOVERY_CLEANED
        $null=Set-LabHyperVTestDatabaseReconcileJournalStatus -Journal $journal -Path $journalPath -Status COMPLETED
        return [PSCustomObject]@{Status='SUCCEEDED';RunId=$RunId;InstanceId=$InstanceId;Changed=$true;Added=@($journal.Additions).Count;Removed=@($journal.Removals).Count;JournalStatus='COMPLETED'}
    }
    catch{$code=if($_.Exception.Message -cmatch '[A-Z][A-Z0-9_]{5,127}'){[string]$Matches[0]}else{'HYPERV_TEST_DATABASE_RECONCILE_FAILED'};if($journal -and $journalPath){try{$null=Set-LabHyperVTestDatabaseReconcileJournalStatus -Journal $journal -Path $journalPath -Status RECOVERY_REQUIRED -ErrorCode $code}catch{};throw "HYPERV_TEST_DATABASE_RECONCILE_RECOVERY_REQUIRED: $code"};throw}
    finally{if($acquired){try{$mutex.ReleaseMutex()}catch{}};$mutex.Dispose()}
}
