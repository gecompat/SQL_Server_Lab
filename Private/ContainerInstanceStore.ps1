<#
.SYNOPSIS
    Plant und klont katalogisierte Docker-/Podman-Instanzstores.
.DESCRIPTION
    Die stabile PersistentStorageId bleibt von Runtime-Volumenamen getrennt.
    CONTINUE liefert eine revalidierte Drive-Bindung; CLONE kopiert nur aus
    einem ungebundenen Quellvolume in ein neues, operationsgebundenes Ziel.
    Ein lokales Journal erlaubt die sichere Wiederaufnahme ohne Quellloeschung.
#>

function Test-LabContainerInstanceStoreIntent {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Intent)

    $schemaPath = Join-Path $script:SchemasPath 'container-instance-store-intent.schema.json'
    try {
        $valid = $Intent | ConvertTo-Json -Depth 30 | Test-Json -SchemaFile $schemaPath -ErrorAction Stop
    }
    catch { throw "CONTAINER_INSTANCE_STORE_INTENT_SCHEMA_INVALID: $($_.Exception.Message)" }
    if (-not $valid) { throw 'CONTAINER_INSTANCE_STORE_INTENT_SCHEMA_INVALID' }
    return $true
}

function Get-LabContainerInstanceStoreRuntimeInspection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('docker','podman')][string]$Provider,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_.-]{0,254}$')][string]$VolumeName
    )

    $raw = @(& $Provider volume inspect $VolumeName 2>$null)
    if ($LASTEXITCODE -ne 0) {
        return [PSCustomObject]@{ Status='MISSING'; Provider=$Provider; VolumeName=$VolumeName; VolumeId=$null; Labels=[PSCustomObject]@{}; AttachedContainers=@() }
    }
    try { $inspection = @($raw | ConvertFrom-Json -Depth 40 -ErrorAction Stop)[0] }
    catch { throw 'CONTAINER_INSTANCE_STORE_VOLUME_INSPECT_INVALID' }
    $attached = @(& $Provider ps -a -q --filter "volume=$VolumeName" 2>$null | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
    if ($LASTEXITCODE -ne 0) { throw 'CONTAINER_INSTANCE_STORE_ATTACHMENT_QUERY_FAILED' }
    $labels = if ($inspection.Labels) { $inspection.Labels } else { [PSCustomObject]@{} }
    [PSCustomObject]@{
        Status='AVAILABLE'; Provider=$Provider; VolumeName=[string]$inspection.Name
        VolumeId=if ($inspection.PSObject.Properties['Name']) { [string]$inspection.Name } else { $VolumeName }
        Labels=$labels; AttachedContainers=@($attached | Sort-Object -Unique)
    }
}

function Get-LabContainerInstanceStorePlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Intent,
        [Parameter(Mandatory)]$Catalog,
        [Parameter(Mandatory)]$RuntimeInspection
    )

    $null = Test-LabContainerInstanceStoreIntent -Intent $Intent
    $issues = [Collections.Generic.List[string]]::new()
    $catalogStatus = if ($Catalog.PSObject.Properties['Status']) { [string]$Catalog.Status } else { 'AVAILABLE' }
    $document = if ($Catalog.PSObject.Properties['Document']) { $Catalog.Document } else { $Catalog }
    if ($catalogStatus -ne 'AVAILABLE') { $issues.Add("CATALOG_$catalogStatus") }
    if (-not $document -or [string]::IsNullOrWhiteSpace([string]$document.ControllerId) -or
        [string]$document.ContractVersion -ne 'SqlServerLab.PersistentStorageCatalog/1.0') {
        $issues.Add('CATALOG_CONTRACT_INVALID')
    }

    $stores = @($document.Stores | Where-Object { [string]$_.PersistentStorageId -eq [string]$Intent.SourcePersistentStorageId })
    if ($stores.Count -ne 1) { $issues.Add('SOURCE_STORAGE_NOT_FOUND') }
    $store = if ($stores.Count -eq 1) { $stores[0] } else { $null }
    if ($store) {
        if ([string]$store.StorageClass -ne 'INSTANCE_STORE') { $issues.Add('SOURCE_STORAGE_CLASS_INVALID') }
        if ([string]$store.Provider -ne [string]$Intent.Provider) { $issues.Add('SOURCE_PROVIDER_MISMATCH') }
        if ([string]$store.State -notin @('AVAILABLE','DETACHED')) { $issues.Add('SOURCE_STATE_NOT_DETACHED') }
        if ($store.Lease) { $issues.Add('SOURCE_LEASE_ACTIVE') }
        if (@($store.References | Where-Object State -eq 'ACTIVE').Count -gt 0) { $issues.Add('SOURCE_REFERENCE_ACTIVE') }
        if ([string]$store.LocationBinding.Residency -ne 'NATIVE_RUNTIME' -or
            [string]::IsNullOrWhiteSpace([string]$store.LocationBinding.ProviderResourceId)) {
            $issues.Add('SOURCE_RUNTIME_BINDING_INVALID')
        }
    }

    $expectedVolumeName = if ($store) { [string]$store.LocationBinding.ProviderResourceId } else { $null }
    if ([string]$RuntimeInspection.Status -ne 'AVAILABLE') { $issues.Add('SOURCE_VOLUME_NOT_OBSERVED') }
    if ([string]$RuntimeInspection.Provider -ne [string]$Intent.Provider -or
        [string]$RuntimeInspection.VolumeName -ne $expectedVolumeName) { $issues.Add('SOURCE_RUNTIME_IDENTITY_MISMATCH') }
    if (@($RuntimeInspection.AttachedContainers).Count -gt 0) { $issues.Add('SOURCE_VOLUME_ATTACHED') }

    $sourceStorageLabel = [string]$RuntimeInspection.Labels.'sql-server-lab.persistent-storage-id'
    if ($sourceStorageLabel -ne [string]$Intent.SourcePersistentStorageId) { $issues.Add('SOURCE_STORAGE_LABEL_MISMATCH') }
    $sourceSqlMajor = [string]$RuntimeInspection.Labels.'sql-server-lab.sql-major-version'
    if ($sourceSqlMajor -notmatch '^\d{4}$') { $issues.Add('SOURCE_SQL_VERSION_UNVERIFIED') }
    elseif ($sourceSqlMajor -ne [string]$Intent.TargetSqlMajorVersion) { $issues.Add('SOURCE_SQL_VERSION_INCOMPATIBLE') }

    if ([string]$Intent.Action -eq 'CLONE') {
        if ([string]$Intent.TargetPersistentStorageId -eq [string]$Intent.SourcePersistentStorageId) { $issues.Add('TARGET_STORAGE_ID_REUSED') }
        if ([string]$Intent.TargetVolumeName -eq $expectedVolumeName) { $issues.Add('TARGET_VOLUME_NAME_REUSED') }
        if (@($document.Stores | Where-Object { [string]$_.PersistentStorageId -eq [string]$Intent.TargetPersistentStorageId }).Count -gt 0) {
            $issues.Add('TARGET_STORAGE_ID_ALREADY_CATALOGED')
        }
    }

    $blockers = @($issues | Sort-Object -Unique)
    $steps = if ([string]$Intent.Action -eq 'CONTINUE') {
        @(
            [PSCustomObject]@{ Order=1; Action='REVALIDATE_SOURCE'; Mutation='NONE'; FailureState='BLOCKED' },
            [PSCustomObject]@{ Order=2; Action='BIND_EXISTING_VOLUME'; Mutation='RUNTIME'; FailureState='RECOVERY_REQUIRED' },
            [PSCustomObject]@{ Order=3; Action='VERIFY_SQL_READINESS_AND_DATA'; Mutation='SQL'; FailureState='RECOVERY_REQUIRED' }
        )
    }
    else {
        @(
            [PSCustomObject]@{ Order=1; Action='REVALIDATE_SOURCE'; Mutation='NONE'; FailureState='BLOCKED' },
            [PSCustomObject]@{ Order=2; Action='CREATE_EMPTY_TARGET'; Mutation='RUNTIME'; FailureState='RECOVERY_REQUIRED' },
            [PSCustomObject]@{ Order=3; Action='COPY_SOURCE_READ_ONLY'; Mutation='RUNTIME'; FailureState='RECOVERY_REQUIRED' },
            [PSCustomObject]@{ Order=4; Action='VERIFY_CONTENT_DIGEST'; Mutation='RUNTIME'; FailureState='RECOVERY_REQUIRED' },
            [PSCustomObject]@{ Order=5; Action='REGISTER_TARGET_CANDIDATE'; Mutation='CATALOG'; FailureState='RECOVERY_REQUIRED' }
        )
    }
    $plan = [PSCustomObject]@{
        ContractVersion='SqlServerLab.ContainerInstanceStorePlan/1.0'
        Status=if ($blockers.Count -eq 0) { 'READY' } else { 'BLOCKED' }
        OperationId=[string]$Intent.OperationId; Action=[string]$Intent.Action; Provider=[string]$Intent.Provider
        Source=[PSCustomObject]@{
            PersistentStorageId=[string]$Intent.SourcePersistentStorageId; VolumeName=$expectedVolumeName
            VolumeId=if ($RuntimeInspection.VolumeId) { [string]$RuntimeInspection.VolumeId } else { $null }
            State=if ($store) { [string]$store.State } else { $null }; SqlMajorVersion=if ($sourceSqlMajor) { $sourceSqlMajor } else { $null }
            AttachedContainers=@($RuntimeInspection.AttachedContainers)
        }
        Target=if ([string]$Intent.Action -eq 'CLONE') {
            [PSCustomObject]@{ PersistentStorageId=[string]$Intent.TargetPersistentStorageId; VolumeName=[string]$Intent.TargetVolumeName; RunId=[string]$Intent.TargetRunId; ScopeId=[string]$Intent.TargetScopeId; SqlMajorVersion=[string]$Intent.TargetSqlMajorVersion; HelperImage=[string]$Intent.HelperImage }
        } else { $null }
        Steps=$steps; Blockers=$blockers
        Preview=[PSCustomObject]@{ SourceMutation=$false; SourceDeletion=$false; TargetCreated=([string]$Intent.Action -eq 'CLONE'); RequiresDetachedSource=$true; CatalogCommitRequired=([string]$Intent.Action -eq 'CLONE') }
    }
    $schemaPath = Join-Path $script:SchemasPath 'container-instance-store-plan.schema.json'
    if (-not (($plan | ConvertTo-Json -Depth 30) | Test-Json -SchemaFile $schemaPath -ErrorAction SilentlyContinue)) {
        throw 'CONTAINER_INSTANCE_STORE_PLAN_SCHEMA_INVALID'
    }
    return $plan
}

function Get-LabContainerInstanceStoreDriveBinding {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Plan)
    if ([string]$Plan.Status -ne 'READY' -or [string]$Plan.Action -ne 'CONTINUE') {
        throw 'CONTAINER_INSTANCE_STORE_CONTINUE_PLAN_REQUIRED'
    }
    [PSCustomObject]@{
        id='persistent-mssql'; containerPath='/var/opt/mssql'; volumeName=[string]$Plan.Source.VolumeName
        persistence='cataloged-runtime-volume'; persistentStorageId=[string]$Plan.Source.PersistentStorageId
    }
}

function Get-LabContainerInstanceStoreJournalPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$OperationDirectory)
    return (Join-Path $OperationDirectory 'container-instance-store-journal.json')
}

function Write-LabContainerInstanceStoreJournal {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Journal, [Parameter(Mandatory)][string]$Path)
    $Journal.UpdatedAt = Get-LabTimestamp
    $schemaPath = Join-Path $script:SchemasPath 'container-instance-store-journal.schema.json'
    if (-not (($Journal | ConvertTo-Json -Depth 40) | Test-Json -SchemaFile $schemaPath -ErrorAction SilentlyContinue)) {
        throw 'CONTAINER_INSTANCE_STORE_JOURNAL_SCHEMA_INVALID'
    }
    Write-LabArtifactJsonAtomic -Path $Path -InputObject $Journal
    return $Journal
}

function Invoke-LabContainerInstanceStoreRuntimeCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('docker','podman')][string]$Provider,
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$ErrorCode
    )
    $output = @(& $Provider @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "${ErrorCode}: $($output -join ' ')" }
    return @($output)
}

function Get-LabContainerVolumeContentEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('docker','podman')][string]$Provider,
        [Parameter(Mandatory)][string]$VolumeName,
        [Parameter(Mandatory)][string]$HelperImage
    )
    $scriptText = @'
set -eu; cd /store; c=$(find . -type f | wc -l); b=$(find . -type f -printf '%s\n' | awk '{s+=$1} END {print s+0}'); h=$(find . -type f -print0 | sort -z | xargs -0 -r sha256sum | sha256sum | awk '{print $1}'); printf '%s|%s|%s\n' "$c" "$b" "$h"
'@
    $output = Invoke-LabContainerInstanceStoreRuntimeCommand -Provider $Provider -Arguments @(
        'run','--rm','--user','0:0','--entrypoint','/bin/sh','-v',"${VolumeName}:/store:ro",$HelperImage,'-c',$scriptText
    ) -ErrorCode 'CONTAINER_INSTANCE_STORE_EVIDENCE_FAILED'
    $line = @($output | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ -match '^\d+\|\d+\|[a-f0-9]{64}$' } | Select-Object -Last 1)
    if ($line.Count -ne 1) { throw 'CONTAINER_INSTANCE_STORE_EVIDENCE_INVALID' }
    $parts = [string]$line[0] -split '\|'
    [PSCustomObject]@{ FileCount=[long]$parts[0]; TotalBytes=[long]$parts[1]; Sha256=[string]$parts[2] }
}

function Invoke-LabContainerInstanceStoreClone {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)][string]$OperationDirectory
    )
    if ([string]$Plan.Status -ne 'READY' -or [string]$Plan.Action -ne 'CLONE') {
        throw 'CONTAINER_INSTANCE_STORE_CLONE_PLAN_REQUIRED'
    }
    if (-not (Test-Path -LiteralPath $OperationDirectory -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $OperationDirectory -Force
    }
    $path = Get-LabContainerInstanceStoreJournalPath -OperationDirectory $OperationDirectory
    $journal = if (Test-Path -LiteralPath $path -PathType Leaf) {
        Get-Content -LiteralPath $path -Raw -Encoding utf8 | ConvertFrom-Json -Depth 40
    }
    else {
        [PSCustomObject]@{
            ContractVersion='SqlServerLab.ContainerInstanceStoreJournal/1.0'; OperationId=[string]$Plan.OperationId
            Provider=[string]$Plan.Provider; Status='PREPARED'
            Source=[PSCustomObject]@{ PersistentStorageId=[string]$Plan.Source.PersistentStorageId; VolumeName=[string]$Plan.Source.VolumeName; VolumeId=[string]$Plan.Source.VolumeId; Evidence=$null }
            Target=[PSCustomObject]@{ PersistentStorageId=[string]$Plan.Target.PersistentStorageId; VolumeName=[string]$Plan.Target.VolumeName; VolumeId=$null; Evidence=$null }
            TargetRunId=[string]$Plan.Target.RunId; TargetScopeId=[string]$Plan.Target.ScopeId
            SqlMajorVersion=[string]$Plan.Target.SqlMajorVersion; HelperImage=[string]$Plan.Target.HelperImage
            Recovery=[PSCustomObject]@{ Status='RETRY_CLONE'; Attempts=0; ErrorCode=$null; Errors=@() }; UpdatedAt=Get-LabTimestamp
        }
    }
    if ([string]$journal.OperationId -ne [string]$Plan.OperationId -or [string]$journal.Provider -ne [string]$Plan.Provider -or
        [string]$journal.Source.PersistentStorageId -ne [string]$Plan.Source.PersistentStorageId -or
        [string]$journal.Target.PersistentStorageId -ne [string]$Plan.Target.PersistentStorageId) {
        throw 'CONTAINER_INSTANCE_STORE_JOURNAL_IDENTITY_MISMATCH'
    }
    if ([string]$journal.Status -eq 'COMPLETED') { return $journal }

    $journal.Recovery.Attempts = [int]$journal.Recovery.Attempts + 1
    try {
        $source = Get-LabContainerInstanceStoreRuntimeInspection -Provider ([string]$Plan.Provider) -VolumeName ([string]$Plan.Source.VolumeName)
        if ([string]$source.Status -ne 'AVAILABLE' -or [string]$source.VolumeId -ne [string]$Plan.Source.VolumeId -or
            @($source.AttachedContainers).Count -gt 0 -or
            [string]$source.Labels.'sql-server-lab.persistent-storage-id' -ne [string]$Plan.Source.PersistentStorageId) {
            throw 'CONTAINER_INSTANCE_STORE_SOURCE_REVALIDATION_FAILED'
        }
        $sourceEvidence = Get-LabContainerVolumeContentEvidence -Provider ([string]$Plan.Provider) -VolumeName ([string]$Plan.Source.VolumeName) -HelperImage ([string]$Plan.Target.HelperImage)
        if ($journal.Source.Evidence -and [string]$journal.Source.Evidence.Sha256 -ne [string]$sourceEvidence.Sha256) {
            throw 'CONTAINER_INSTANCE_STORE_SOURCE_DRIFTED'
        }
        $journal.Source.Evidence = $sourceEvidence

        $target = Get-LabContainerInstanceStoreRuntimeInspection -Provider ([string]$Plan.Provider) -VolumeName ([string]$Plan.Target.VolumeName)
        if ([string]$target.Status -eq 'MISSING') {
            $null = Invoke-LabContainerInstanceStoreRuntimeCommand -Provider ([string]$Plan.Provider) -Arguments @(
                'volume','create',
                '--label',"sql-server-lab.persistent-storage-id=$([string]$Plan.Target.PersistentStorageId)",
                '--label',"sql-server-lab.clone-source-id=$([string]$Plan.Source.PersistentStorageId)",
                '--label',"sql-server-lab.operation-id=$([string]$Plan.OperationId)",
                '--label',"sql-server-lab.run-id=$([string]$Plan.Target.RunId)",
                '--label',"sql-server-lab.scope-id=$([string]$Plan.Target.ScopeId)",
                '--label',"sql-server-lab.sql-major-version=$([string]$Plan.Target.SqlMajorVersion)",
                '--label','sql-server-lab.retention=retained',
                [string]$Plan.Target.VolumeName
            ) -ErrorCode 'CONTAINER_INSTANCE_STORE_TARGET_CREATE_FAILED'
            $target = Get-LabContainerInstanceStoreRuntimeInspection -Provider ([string]$Plan.Provider) -VolumeName ([string]$Plan.Target.VolumeName)
        }
        if ([string]$target.Status -ne 'AVAILABLE' -or @($target.AttachedContainers).Count -gt 0 -or
            [string]$target.Labels.'sql-server-lab.persistent-storage-id' -ne [string]$Plan.Target.PersistentStorageId -or
            [string]$target.Labels.'sql-server-lab.operation-id' -ne [string]$Plan.OperationId) {
            throw 'CONTAINER_INSTANCE_STORE_TARGET_SCOPE_MISMATCH'
        }
        $journal.Target.VolumeId = [string]$target.VolumeId
        $journal.Status = 'TARGET_CREATED'
        $null = Write-LabContainerInstanceStoreJournal -Journal $journal -Path $path

        $copyScript = 'set -eu; find /target -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +; cp -a /source/. /target/'
        $null = Invoke-LabContainerInstanceStoreRuntimeCommand -Provider ([string]$Plan.Provider) -Arguments @(
            'run','--rm','--user','0:0','--entrypoint','/bin/sh',
            '-v',"$([string]$Plan.Source.VolumeName):/source:ro",'-v',"$([string]$Plan.Target.VolumeName):/target",
            [string]$Plan.Target.HelperImage,'-c',$copyScript
        ) -ErrorCode 'CONTAINER_INSTANCE_STORE_COPY_FAILED'
        $journal.Status = 'CONTENT_COPIED'
        $null = Write-LabContainerInstanceStoreJournal -Journal $journal -Path $path

        $sourceAfter = Get-LabContainerVolumeContentEvidence -Provider ([string]$Plan.Provider) -VolumeName ([string]$Plan.Source.VolumeName) -HelperImage ([string]$Plan.Target.HelperImage)
        $targetEvidence = Get-LabContainerVolumeContentEvidence -Provider ([string]$Plan.Provider) -VolumeName ([string]$Plan.Target.VolumeName) -HelperImage ([string]$Plan.Target.HelperImage)
        if ([string]$sourceAfter.Sha256 -ne [string]$sourceEvidence.Sha256 -or [long]$sourceAfter.FileCount -ne [long]$sourceEvidence.FileCount -or
            [long]$sourceAfter.TotalBytes -ne [long]$sourceEvidence.TotalBytes) { throw 'CONTAINER_INSTANCE_STORE_SOURCE_DRIFTED' }
        if ([string]$targetEvidence.Sha256 -ne [string]$sourceEvidence.Sha256 -or [long]$targetEvidence.FileCount -ne [long]$sourceEvidence.FileCount -or
            [long]$targetEvidence.TotalBytes -ne [long]$sourceEvidence.TotalBytes) { throw 'CONTAINER_INSTANCE_STORE_POSTCONDITION_FAILED' }
        $journal.Target.Evidence = $targetEvidence
        $journal.Status = 'VERIFIED'; $journal.Recovery.Status = 'NOT_REQUIRED'; $journal.Recovery.ErrorCode = $null
        $null = Write-LabContainerInstanceStoreJournal -Journal $journal -Path $path
        $journal.Status = 'COMPLETED'
        return (Write-LabContainerInstanceStoreJournal -Journal $journal -Path $path)
    }
    catch {
        $code = if ($_.Exception.Message -cmatch '[A-Z][A-Z0-9_]{5,127}') { [string]$Matches[0] } else { 'CONTAINER_INSTANCE_STORE_CLONE_FAILED' }
        $journal.Status = 'RECOVERY_REQUIRED'; $journal.Recovery.Status = 'RETRY_CLONE'; $journal.Recovery.ErrorCode = $code
        $journal.Recovery.Errors = @($journal.Recovery.Errors) + @($code)
        $null = Write-LabContainerInstanceStoreJournal -Journal $journal -Path $path
        throw "CONTAINER_INSTANCE_STORE_RECOVERY_REQUIRED: $code"
    }
}
