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

function Get-LabContainerInstanceStoreSidecarDefinitions {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BaseVolumeName)

    @(
        [PSCustomObject]@{
            Role='EXTERNAL_LANGUAGES'; ContainerPath='/var/opt/mssql-extensibility/externallanguages'
            VolumeName="${BaseVolumeName}-external-languages"
        },
        [PSCustomObject]@{
            Role='EXTERNAL_LIBRARIES'; ContainerPath='/var/opt/mssql-extensibility/externallibraries'
            VolumeName="${BaseVolumeName}-external-libraries"
        }
    )
}

function Get-LabContainerInstanceStoreRuntimeInspection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('docker','podman')][string]$Provider,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_.-]{0,254}$')][string]$VolumeName
    )

    $invocation = Get-LabHostToolInvocation -Name $Provider
    $raw = @(& $invocation volume inspect $VolumeName 2>$null)
    if ($LASTEXITCODE -ne 0) {
        return [PSCustomObject]@{ Status='MISSING'; Provider=$Provider; VolumeName=$VolumeName; VolumeId=$null; Labels=[PSCustomObject]@{}; AttachedContainers=@() }
    }
    try { $inspection = @($raw | ConvertFrom-Json -Depth 40 -ErrorAction Stop)[0] }
    catch { throw 'CONTAINER_INSTANCE_STORE_VOLUME_INSPECT_INVALID' }
    $attached = @(& $invocation ps -a -q --filter "volume=$VolumeName" 2>$null | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
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
        [Parameter(Mandatory)]$RuntimeInspection,
        [array]$SidecarRuntimeInspection = @()
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
    $operationLease = $false
    if ($store) {
        $operationReferences = @($store.References | Where-Object {
            [string]$_.ReferenceId -eq [string]$Intent.OperationId -and
            [string]$_.Kind -eq 'RUN' -and [string]$_.State -eq 'ACTIVE' -and
            [string]$_.TargetId -eq [string]$Intent.TargetRunId
        })
        $operationLease = [string]$Intent.Action -eq 'CLONE' -and $store.Lease -and
            [string]$store.Lease.LeaseId -eq [string]$Intent.OperationId -and
            [string]$store.Lease.RunId -eq [string]$Intent.TargetRunId -and
            [string]$store.Lease.ScopeId -eq [string]$Intent.TargetScopeId -and
            [string]$store.Lease.Mode -eq 'EXCLUSIVE' -and $operationReferences.Count -eq 1
        if ([string]$store.StorageClass -ne 'INSTANCE_STORE') { $issues.Add('SOURCE_STORAGE_CLASS_INVALID') }
        if ([string]$store.Provider -ne [string]$Intent.Provider) { $issues.Add('SOURCE_PROVIDER_MISMATCH') }
        if ([string]$store.State -notin @('AVAILABLE','DETACHED') -and
            -not ($operationLease -and [string]$store.State -eq 'IN_USE')) { $issues.Add('SOURCE_STATE_NOT_DETACHED') }
        if ($store.Lease -and -not $operationLease) { $issues.Add('SOURCE_LEASE_ACTIVE') }
        $foreignActiveReferences = @($store.References | Where-Object {
            [string]$_.State -eq 'ACTIVE' -and
            -not ($operationLease -and [string]$_.ReferenceId -eq [string]$Intent.OperationId)
        })
        if ($foreignActiveReferences.Count -gt 0) { $issues.Add('SOURCE_REFERENCE_ACTIVE') }
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

    $sourceSidecars = @()
    if ([bool]$Intent.IncludeExternalRuntimeSidecars) {
        $sidecarDefinitions = if ([string]::IsNullOrWhiteSpace($expectedVolumeName)) {
            $issues.Add('SOURCE_SIDECAR_GROUP_UNRESOLVED')
            @()
        }
        else { @(Get-LabContainerInstanceStoreSidecarDefinitions -BaseVolumeName $expectedVolumeName) }
        foreach ($definition in $sidecarDefinitions) {
            $matches = @($SidecarRuntimeInspection | Where-Object {
                [string]$_.VolumeName -eq [string]$definition.VolumeName
            })
            $inspection = if ($matches.Count -eq 1) { $matches[0] } else { $null }
            if ($matches.Count -ne 1 -or [string]$inspection.Status -ne 'AVAILABLE') {
                $issues.Add("SOURCE_SIDECAR_$([string]$definition.Role)_NOT_OBSERVED")
            }
            elseif ([string]$inspection.Provider -ne [string]$Intent.Provider -or
                [string]$inspection.VolumeName -ne [string]$definition.VolumeName) {
                $issues.Add("SOURCE_SIDECAR_$([string]$definition.Role)_IDENTITY_MISMATCH")
            }
            if ($inspection -and @($inspection.AttachedContainers).Count -gt 0) {
                $issues.Add("SOURCE_SIDECAR_$([string]$definition.Role)_ATTACHED")
            }
            if ($inspection -and
                ([string]$inspection.Labels.'sql-server-lab.persistent-storage-id' -ne [string]$Intent.SourcePersistentStorageId -or
                 [string]$inspection.Labels.'sql-server-lab.sql-major-version' -ne [string]$Intent.TargetSqlMajorVersion -or
                 [string]$inspection.Labels.'sql-server-lab.storage-role' -ne [string]$definition.Role)) {
                $issues.Add("SOURCE_SIDECAR_$([string]$definition.Role)_LABEL_MISMATCH")
            }
            $sourceSidecars += [PSCustomObject]@{
                Role=[string]$definition.Role; ContainerPath=[string]$definition.ContainerPath
                VolumeName=[string]$definition.VolumeName
                VolumeId=if ($inspection -and $inspection.VolumeId) { [string]$inspection.VolumeId } else { $null }
                AttachedContainers=@($inspection.AttachedContainers | Where-Object { $_ })
            }
        }
    }

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
            AttachedContainers=@($RuntimeInspection.AttachedContainers); Sidecars=@($sourceSidecars)
        }
        Target=if ([string]$Intent.Action -eq 'CLONE') {
            [PSCustomObject]@{
                PersistentStorageId=[string]$Intent.TargetPersistentStorageId; VolumeName=[string]$Intent.TargetVolumeName
                RunId=[string]$Intent.TargetRunId; ScopeId=[string]$Intent.TargetScopeId
                SqlMajorVersion=[string]$Intent.TargetSqlMajorVersion; HelperImage=[string]$Intent.HelperImage
                Sidecars=@(if ([bool]$Intent.IncludeExternalRuntimeSidecars) {
                    Get-LabContainerInstanceStoreSidecarDefinitions -BaseVolumeName ([string]$Intent.TargetVolumeName) | ForEach-Object {
                        [PSCustomObject]@{ Role=[string]$_.Role; ContainerPath=[string]$_.ContainerPath; VolumeName=[string]$_.VolumeName; VolumeId=$null; AttachedContainers=@() }
                    }
                })
            }
        } else { $null }
        Steps=$steps; Blockers=$blockers
        Preview=[PSCustomObject]@{ SourceMutation=$false; SourceDeletion=$false; TargetCreated=([string]$Intent.Action -eq 'CLONE'); RequiresDetachedSource=$true; CatalogCommitRequired=([string]$Intent.Action -eq 'CLONE') }
    }
    $schemaPath = Join-Path $script:SchemasPath 'container-instance-store-plan.schema.json'
    $schemaErrors = @()
    if (-not (($plan | ConvertTo-Json -Depth 30) | Test-Json -SchemaFile $schemaPath -ErrorAction SilentlyContinue -ErrorVariable +schemaErrors)) {
        $detail = @($schemaErrors | ForEach-Object { $_.Exception.Message } | Where-Object { $_ } | Select-Object -First 1)
        throw "CONTAINER_INSTANCE_STORE_PLAN_SCHEMA_INVALID$(if ($detail.Count -eq 1) { ": $($detail[0])" })"
    }
    return $plan
}

function New-LabContainerInstanceStoreSelectionPlan {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification='Erzeugt ausschliesslich einen in-memory Auswahlplan; Runtime- und Katalogmutationen erfolgen spaeter.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F-]{36}$')][string]$SourcePersistentStorageId,
        [Parameter(Mandatory)][ValidateSet('CONTINUE','CLONE')][string]$Action,
        [Parameter(Mandatory)][ValidateSet('docker','podman')][string]$Provider,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F-]{36}$')][string]$TargetRunId,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F-]{36}$')][string]$TargetScopeId,
        [Parameter(Mandatory)][string]$TargetSqlVersion,
        [Parameter(Mandatory)]$Configuration,
        [ValidatePattern('^[0-9a-fA-F-]{36}$')][string]$OperationId,
        [ValidatePattern('^[0-9a-fA-F-]{36}$')][string]$TargetPersistentStorageId,
        [switch]$IncludeExternalRuntimeSidecars
    )

    if ($TargetSqlVersion.Length -lt 4 -or $TargetSqlVersion.Substring(0,4) -notmatch '^\d{4}$') {
        throw 'CONTAINER_INSTANCE_STORE_TARGET_SQL_VERSION_INVALID'
    }
    $sqlMajorVersion = $TargetSqlVersion.Substring(0,4)
    $catalog = Get-LabPersistentStorageCatalog -Configuration $Configuration
    $document = if ($catalog.PSObject.Properties['Document']) { $catalog.Document } else { $null }
    $sourceStores = @($document.Stores | Where-Object {
        [string]$_.PersistentStorageId -eq $SourcePersistentStorageId
    })
    $sourceVolumeName = if ($sourceStores.Count -eq 1) {
        [string]$sourceStores[0].LocationBinding.ProviderResourceId
    }
    else { '__unresolved_instance_store__' }
    $runtimeInspection = if ($sourceStores.Count -eq 1 -and $sourceVolumeName) {
        Get-LabContainerInstanceStoreRuntimeInspection -Provider $Provider -VolumeName $sourceVolumeName
    }
    else {
        [PSCustomObject]@{
            Status='MISSING'; Provider=$Provider; VolumeName=$sourceVolumeName; VolumeId=$null
            Labels=[PSCustomObject]@{}; AttachedContainers=@()
        }
    }
    $sidecarRuntimeInspection = if ($IncludeExternalRuntimeSidecars -and $sourceStores.Count -eq 1 -and $sourceVolumeName) {
        @(Get-LabContainerInstanceStoreSidecarDefinitions -BaseVolumeName $sourceVolumeName | ForEach-Object {
            Get-LabContainerInstanceStoreRuntimeInspection -Provider $Provider -VolumeName ([string]$_.VolumeName)
        })
    }
    else { @() }

    $resolvedOperationId = if ($OperationId) { $OperationId } else { [Guid]::NewGuid().ToString('D') }
    $resolvedTargetStorageId = if ($Action -eq 'CLONE') {
        if ($TargetPersistentStorageId) { $TargetPersistentStorageId } else { [Guid]::NewGuid().ToString('D') }
    }
    else { $null }
    $targetVolumeName = if ($Action -eq 'CLONE') {
        "sql-lab-persistent-clone-$($resolvedTargetStorageId.Replace('-',''))"
    }
    else { $null }
    $intent = [PSCustomObject][ordered]@{
        ContractVersion='SqlServerLab.ContainerInstanceStoreIntent/1.0'; OperationId=$resolvedOperationId
        Action=$Action; SourcePersistentStorageId=$SourcePersistentStorageId
        TargetPersistentStorageId=$resolvedTargetStorageId; TargetVolumeName=$targetVolumeName; Provider=$Provider
        TargetRunId=$TargetRunId; TargetScopeId=$TargetScopeId; TargetSqlMajorVersion=$sqlMajorVersion
        HelperImage=if ($Action -eq 'CLONE') { Get-SqlServerDockerImage -VersionId $TargetSqlVersion } else { $null }
        IncludeExternalRuntimeSidecars=[bool]$IncludeExternalRuntimeSidecars
    }
    return Get-LabContainerInstanceStorePlan -Intent $intent -Catalog $catalog -RuntimeInspection $runtimeInspection `
        -SidecarRuntimeInspection $sidecarRuntimeInspection
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
    $invocation = Get-LabHostToolInvocation -Name $Provider
    $output = @(& $invocation @Arguments 2>&1)
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
        [Parameter(Mandatory)][string]$OperationDirectory,
        [Parameter(Mandatory)]$Configuration
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
            Sidecars=@($Plan.Source.Sidecars | ForEach-Object {
                $sourceSidecar = $_
                $targetSidecar = @($Plan.Target.Sidecars | Where-Object Role -eq ([string]$sourceSidecar.Role))[0]
                [PSCustomObject]@{
                    Role=[string]$sourceSidecar.Role; ContainerPath=[string]$sourceSidecar.ContainerPath
                    Source=[PSCustomObject]@{ PersistentStorageId=[string]$Plan.Source.PersistentStorageId; VolumeName=[string]$sourceSidecar.VolumeName; VolumeId=[string]$sourceSidecar.VolumeId; Evidence=$null }
                    Target=[PSCustomObject]@{ PersistentStorageId=[string]$Plan.Target.PersistentStorageId; VolumeName=[string]$targetSidecar.VolumeName; VolumeId=$null; Evidence=$null }
                }
            })
            TargetRunId=[string]$Plan.Target.RunId; TargetScopeId=[string]$Plan.Target.ScopeId
            SqlMajorVersion=[string]$Plan.Target.SqlMajorVersion; HelperImage=[string]$Plan.Target.HelperImage
            Recovery=[PSCustomObject]@{ Status='RETRY_CLONE'; Attempts=0; ErrorCode=$null; Errors=@() }; UpdatedAt=Get-LabTimestamp
        }
    }
    if (-not $journal.PSObject.Properties['Sidecars']) {
        # Bereits begonnene Main-Volume-Clones aus Vertrag 1.0 bleiben ohne
        # stillen Scopewechsel fortsetzbar. Sidecars werden niemals nachträglich
        # in eine bestehende Operation aufgenommen.
        $journal | Add-Member -NotePropertyName Sidecars -NotePropertyValue @()
    }
    if ([string]$journal.OperationId -ne [string]$Plan.OperationId -or [string]$journal.Provider -ne [string]$Plan.Provider -or
        [string]$journal.Source.PersistentStorageId -ne [string]$Plan.Source.PersistentStorageId -or
        [string]$journal.Target.PersistentStorageId -ne [string]$Plan.Target.PersistentStorageId -or
        @($journal.Sidecars).Count -ne @($Plan.Source.Sidecars).Count) {
        throw 'CONTAINER_INSTANCE_STORE_JOURNAL_IDENTITY_MISMATCH'
    }
    foreach ($sidecar in @($Plan.Source.Sidecars)) {
        $journalSidecar = @($journal.Sidecars | Where-Object Role -eq ([string]$sidecar.Role))
        $targetSidecar = @($Plan.Target.Sidecars | Where-Object Role -eq ([string]$sidecar.Role))
        if ($journalSidecar.Count -ne 1 -or $targetSidecar.Count -ne 1 -or
            [string]$journalSidecar[0].Source.VolumeName -ne [string]$sidecar.VolumeName -or
            [string]$journalSidecar[0].Target.VolumeName -ne [string]$targetSidecar[0].VolumeName) {
            throw 'CONTAINER_INSTANCE_STORE_JOURNAL_IDENTITY_MISMATCH'
        }
    }
    if ([string]$journal.Status -eq 'COMPLETED') {
        $null = Register-LabContainerInstanceStoreClone -Plan $Plan -Journal $journal -Configuration $Configuration
        return $journal
    }

    $journal.Recovery.Attempts = [int]$journal.Recovery.Attempts + 1
    try {
        $null = Set-LabContainerInstanceStoreCloneLease -Plan $Plan -Configuration $Configuration
        $copies = @([PSCustomObject]@{
            Role='SYSTEM'; SourcePlan=$Plan.Source; TargetPlan=$Plan.Target
            SourceJournal=$journal.Source; TargetJournal=$journal.Target
        }) + @($Plan.Source.Sidecars | ForEach-Object {
            $sourcePlan = $_
            $targetPlan = @($Plan.Target.Sidecars | Where-Object Role -eq ([string]$sourcePlan.Role))[0]
            $sidecarJournal = @($journal.Sidecars | Where-Object Role -eq ([string]$sourcePlan.Role))[0]
            [PSCustomObject]@{
                Role=[string]$sourcePlan.Role; SourcePlan=$sourcePlan; TargetPlan=$targetPlan
                SourceJournal=$sidecarJournal.Source; TargetJournal=$sidecarJournal.Target
            }
        })

        foreach ($copy in $copies) {
            $source = Get-LabContainerInstanceStoreRuntimeInspection -Provider ([string]$Plan.Provider) -VolumeName ([string]$copy.SourcePlan.VolumeName)
            $sourceRoleValid = [string]$copy.Role -eq 'SYSTEM' -or
                [string]$source.Labels.'sql-server-lab.storage-role' -eq [string]$copy.Role
            if ([string]$source.Status -ne 'AVAILABLE' -or [string]$source.VolumeId -ne [string]$copy.SourcePlan.VolumeId -or
                @($source.AttachedContainers).Count -gt 0 -or -not $sourceRoleValid -or
                [string]$source.Labels.'sql-server-lab.persistent-storage-id' -ne [string]$Plan.Source.PersistentStorageId -or
                [string]$source.Labels.'sql-server-lab.sql-major-version' -ne [string]$Plan.Target.SqlMajorVersion) {
                throw 'CONTAINER_INSTANCE_STORE_SOURCE_REVALIDATION_FAILED'
            }
            $sourceEvidence = Get-LabContainerVolumeContentEvidence -Provider ([string]$Plan.Provider) -VolumeName ([string]$copy.SourcePlan.VolumeName) -HelperImage ([string]$Plan.Target.HelperImage)
            if ($copy.SourceJournal.Evidence -and [string]$copy.SourceJournal.Evidence.Sha256 -ne [string]$sourceEvidence.Sha256) {
                throw 'CONTAINER_INSTANCE_STORE_SOURCE_DRIFTED'
            }
            $copy.SourceJournal.Evidence = $sourceEvidence

            $target = Get-LabContainerInstanceStoreRuntimeInspection -Provider ([string]$Plan.Provider) -VolumeName ([string]$copy.TargetPlan.VolumeName)
            if ([string]$target.Status -eq 'MISSING') {
                $arguments = @(
                    'volume','create',
                    '--label',"sql-server-lab.persistent-storage-id=$([string]$Plan.Target.PersistentStorageId)",
                    '--label',"sql-server-lab.clone-source-id=$([string]$Plan.Source.PersistentStorageId)",
                    '--label',"sql-server-lab.operation-id=$([string]$Plan.OperationId)",
                    '--label',"sql-server-lab.run-id=$([string]$Plan.Target.RunId)",
                    '--label',"sql-server-lab.scope-id=$([string]$Plan.Target.ScopeId)",
                    '--label',"sql-server-lab.sql-major-version=$([string]$Plan.Target.SqlMajorVersion)",
                    '--label','sql-server-lab.retention=retained'
                )
                if ([string]$copy.Role -ne 'SYSTEM') {
                    $arguments += @('--label',"sql-server-lab.storage-role=$([string]$copy.Role)")
                }
                $arguments += [string]$copy.TargetPlan.VolumeName
                $null = Invoke-LabContainerInstanceStoreRuntimeCommand -Provider ([string]$Plan.Provider) `
                    -Arguments $arguments -ErrorCode 'CONTAINER_INSTANCE_STORE_TARGET_CREATE_FAILED'
                $target = Get-LabContainerInstanceStoreRuntimeInspection -Provider ([string]$Plan.Provider) -VolumeName ([string]$copy.TargetPlan.VolumeName)
            }
            $targetRoleValid = [string]$copy.Role -eq 'SYSTEM' -or
                [string]$target.Labels.'sql-server-lab.storage-role' -eq [string]$copy.Role
            if ([string]$target.Status -ne 'AVAILABLE' -or @($target.AttachedContainers).Count -gt 0 -or -not $targetRoleValid -or
                [string]$target.Labels.'sql-server-lab.persistent-storage-id' -ne [string]$Plan.Target.PersistentStorageId -or
                [string]$target.Labels.'sql-server-lab.operation-id' -ne [string]$Plan.OperationId) {
                throw 'CONTAINER_INSTANCE_STORE_TARGET_SCOPE_MISMATCH'
            }
            $copy.TargetJournal.VolumeId = [string]$target.VolumeId
        }
        $journal.Status = 'TARGET_CREATED'
        $null = Write-LabContainerInstanceStoreJournal -Journal $journal -Path $path

        $copyScript = 'set -eu; find /target -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +; cp -a /source/. /target/'
        foreach ($copy in $copies) {
            $null = Invoke-LabContainerInstanceStoreRuntimeCommand -Provider ([string]$Plan.Provider) -Arguments @(
                'run','--rm','--user','0:0','--entrypoint','/bin/sh',
                '-v',"$([string]$copy.SourcePlan.VolumeName):/source:ro",'-v',"$([string]$copy.TargetPlan.VolumeName):/target",
                [string]$Plan.Target.HelperImage,'-c',$copyScript
            ) -ErrorCode 'CONTAINER_INSTANCE_STORE_COPY_FAILED'
        }
        $journal.Status = 'CONTENT_COPIED'
        $null = Write-LabContainerInstanceStoreJournal -Journal $journal -Path $path

        foreach ($copy in $copies) {
            $sourceEvidence = $copy.SourceJournal.Evidence
            $sourceAfter = Get-LabContainerVolumeContentEvidence -Provider ([string]$Plan.Provider) -VolumeName ([string]$copy.SourcePlan.VolumeName) -HelperImage ([string]$Plan.Target.HelperImage)
            $targetEvidence = Get-LabContainerVolumeContentEvidence -Provider ([string]$Plan.Provider) -VolumeName ([string]$copy.TargetPlan.VolumeName) -HelperImage ([string]$Plan.Target.HelperImage)
            if ([string]$sourceAfter.Sha256 -ne [string]$sourceEvidence.Sha256 -or [long]$sourceAfter.FileCount -ne [long]$sourceEvidence.FileCount -or
                [long]$sourceAfter.TotalBytes -ne [long]$sourceEvidence.TotalBytes) { throw 'CONTAINER_INSTANCE_STORE_SOURCE_DRIFTED' }
            if ([string]$targetEvidence.Sha256 -ne [string]$sourceEvidence.Sha256 -or [long]$targetEvidence.FileCount -ne [long]$sourceEvidence.FileCount -or
                [long]$targetEvidence.TotalBytes -ne [long]$sourceEvidence.TotalBytes) { throw 'CONTAINER_INSTANCE_STORE_POSTCONDITION_FAILED' }
            $copy.TargetJournal.Evidence = $targetEvidence
        }
        $journal.Status = 'VERIFIED'; $journal.Recovery.Status = 'NOT_REQUIRED'; $journal.Recovery.ErrorCode = $null
        $null = Write-LabContainerInstanceStoreJournal -Journal $journal -Path $path
        $null = Register-LabContainerInstanceStoreClone -Plan $Plan -Journal $journal -Configuration $Configuration
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
