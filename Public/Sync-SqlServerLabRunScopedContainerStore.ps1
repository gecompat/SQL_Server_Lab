<#
.SYNOPSIS
    Registriert einen laufenden, rungebundenen Containerstore im Persistent-Storage-Katalog.
.DESCRIPTION
    Liest Run-State, Desired State und Connection-Evidence read-only, revalidiert
    danach Volume-Labels und die exakt eine erwartete Containerbindung und
    registriert erst dann revisionsgeschuetzt. Das Cmdlet erzeugt keine Runtime-
    Ressource und uebernimmt keine ungebundenen oder historischen Volumes.
.PARAMETER RunId
    Stabile ID des laufenden Runs.
.PARAMETER InstanceId
    Eindeutige Container-Instanz-ID aus dem Run-Sollzustand.
.PARAMETER DataRoot
    Registrierter Lab_Data-Root, in dessen controllergebundenen Katalog registriert wird.
.PARAMETER StateRoot
    Optionaler State-Root des Runs.
.OUTPUTS
    PSCustomObject mit Status, stabiler PersistentStorageId und Katalogrevision.
#>
function Sync-SqlServerLabRunScopedContainerStore {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='Medium')]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F-]{36}$')][string]$RunId,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$')][string]$InstanceId,
        [Parameter(Mandatory)][string]$DataRoot,
        [string]$StateRoot
    )

    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
    $DataRoot = Resolve-LabDataRootForUse -DataRoot $DataRoot
    $run = Get-LabRunState -RunId $RunId -StateRoot $StateRoot
    if ([string]$run.state -notin @('SQL_READY','DATABASES_CREATED','RUNNING')) { throw 'RUN_SCOPED_CONTAINER_STORE_RUN_NOT_ACTIVE' }
    $desired = Get-LabPersistedDesiredState -RunId $RunId -StateRoot $StateRoot
    if ([string]$desired.Status -ne 'VALID') { throw 'RUN_SCOPED_CONTAINER_STORE_DESIRED_STATE_INVALID' }
    $instance = @($desired.Snapshot.Instances | Where-Object { [string]$_.Id -eq $InstanceId })
    if ($instance.Count -ne 1 -or [string]$instance[0].Provider -notin @('docker','podman')) { throw 'RUN_SCOPED_CONTAINER_STORE_INSTANCE_UNRESOLVED' }
    $drive = @($instance[0].Intents.Drives | Where-Object { [string]$_.Id -eq 'runtime-mssql' -and [string]$_.Persistence -eq 'run-scoped-runtime-volume' })
    if ($drive.Count -ne 1 -or [string]$drive[0].PersistentStorageId -notmatch '^[0-9a-fA-F-]{36}$') { throw 'RUN_SCOPED_CONTAINER_STORE_DRIVE_UNRESOLVED' }
    $connectionPath = Join-Path (Join-Path (Join-Path $StateRoot 'runs') $RunId) 'connection-info.json'
    if (-not (Test-Path -LiteralPath $connectionPath -PathType Leaf)) { throw 'RUN_SCOPED_CONTAINER_STORE_CONNECTION_EVIDENCE_MISSING' }
    $connection = Get-Content -LiteralPath $connectionPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 20 -ErrorAction Stop
    $connectionInstance = @($connection.instances | Where-Object { [string]$_.id -eq $InstanceId })
    if ($connectionInstance.Count -ne 1 -or [string]$connectionInstance[0].containerId -notmatch '^[0-9a-fA-F]{12,64}$' -or [string]$connectionInstance[0].containerName -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,200}$') { throw 'RUN_SCOPED_CONTAINER_STORE_CONNECTION_EVIDENCE_INVALID' }
    $volumeName = "sql-lab-$([string]$connectionInstance[0].containerName)-runtime-mssql"
    $displayName = "$([string]$desired.Snapshot.LabName) / $InstanceId / SQL $([string]$instance[0].Version)"
    $configuration = Get-LabStorageConfiguration -DataRoot $DataRoot
    $preview = Register-LabRunScopedContainerStore -Provider ([string]$instance[0].Provider) -VolumeName $volumeName -RunId $RunId -ScopeId ([string]$run.scopeId) -ContainerId ([string]$connectionInstance[0].containerId) -SqlVersion ([string]$instance[0].Version) -DisplayName $displayName -DataRoot $DataRoot -Configuration $configuration -Preview
    if ([string]$preview.Store.PersistentStorageId -ne [string]$drive[0].PersistentStorageId) { throw 'RUN_SCOPED_CONTAINER_STORE_STABLE_ID_MISMATCH' }
    if (-not $preview.Changed) { return [PSCustomObject]@{ Status='NO_CHANGE'; RunId=$RunId; InstanceId=$InstanceId; PersistentStorageId=[string]$preview.Store.PersistentStorageId; Changed=$false; WouldChange=$false; CatalogRevision=[int]$preview.CatalogRevision } }
    if (-not $PSCmdlet.ShouldProcess("$RunId/$InstanceId", 'rungebundenen Containerstore katalogisieren')) { return [PSCustomObject]@{ Status=if($WhatIfPreference){'PLANNED'}else{'CANCELLED'}; RunId=$RunId; InstanceId=$InstanceId; PersistentStorageId=[string]$preview.Store.PersistentStorageId; Changed=$false; WouldChange=$true; CatalogRevision=[int]$preview.CatalogRevision } }
    $registered = Register-LabRunScopedContainerStore -Provider ([string]$instance[0].Provider) -VolumeName $volumeName -RunId $RunId -ScopeId ([string]$run.scopeId) -ContainerId ([string]$connectionInstance[0].containerId) -SqlVersion ([string]$instance[0].Version) -DisplayName $displayName -DataRoot $DataRoot -Configuration $configuration -ExpectedRevision ([int]$preview.CatalogRevision)
    [PSCustomObject]@{ Status=if($registered.Changed){'SYNCED'}else{'NO_CHANGE'}; RunId=$RunId; InstanceId=$InstanceId; PersistentStorageId=[string]$registered.Store.PersistentStorageId; Changed=[bool]$registered.Changed; WouldChange=[bool]$registered.Changed; CatalogRevision=[int]$registered.CatalogRevision }
}
