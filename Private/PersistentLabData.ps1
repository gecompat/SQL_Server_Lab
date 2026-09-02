<#
.SYNOPSIS
    Vertrag für ausdrücklich aktivierte, langlebige Lab-Daten.
.DESCRIPTION
    Der Data Root liegt außerhalb des Run-State. Seine Inhalte werden deshalb
    niemals in einen regulären Cleanup-Plan aufgenommen.
#>

function ConvertTo-LabDataPathSegment {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Value)

    $normalized = $Value.Trim().ToLowerInvariant() -replace '[^a-z0-9_-]+', '-' -replace '-+', '-'
    $normalized = $normalized.Trim('-')
    if (-not $normalized -or $normalized.Length -gt 64) { throw 'LAB_DATA_IDENTIFIER_INVALID' }
    return $normalized
}

function Get-LabPersistentInstanceStorage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DataRoot,
        [Parameter(Mandatory)][string]$LabName,
        [Parameter(Mandatory)][ValidateSet('docker', 'podman', 'hyperv')][string]$Provider,
        [Parameter(Mandatory)][string]$InstanceId,
        [Parameter(Mandatory)][string]$SqlVersion,
        [switch]$Create
    )

    $root = Resolve-LabDataRootForUse -DataRoot $DataRoot
    if (-not (Test-Path -LiteralPath (Join-Path $root 'Labs') -PathType Container)) {
        throw 'LAB_DATA_ROOT_LAYOUT_REQUIRED'
    }
    $labSegment = ConvertTo-LabDataPathSegment -Value $LabName
    $instanceSegment = ConvertTo-LabDataPathSegment -Value $InstanceId
    $versionSegment = ConvertTo-LabDataPathSegment -Value $SqlVersion
    $instanceRoot = Join-Path $root (Join-Path 'Labs' (Join-Path $labSegment (Join-Path 'Instances' (Join-Path $Provider $instanceSegment))))
    $sqlRoot = Join-Path $instanceRoot (Join-Path 'SqlServer' $versionSegment)
    $paths = [PSCustomObject]@{
        DataRoot = $root; LabId = $labSegment; Provider = $Provider; InstanceId = $instanceSegment; SqlVersion = $versionSegment
        InstanceRoot = $instanceRoot; SqlRoot = $sqlRoot
        ContainerMssqlRoot = Join-Path $sqlRoot 'mssql'
        HyperVVhdxPath = Join-Path $sqlRoot 'sql-data.vhdx'
        BackupRoot = Join-Path $sqlRoot 'backups'
        DataRootPath = Join-Path $sqlRoot 'data'
        LogRoot = Join-Path $sqlRoot 'log'
    }
    if ($Create) {
        foreach ($path in @($paths.InstanceRoot, $paths.SqlRoot, $paths.ContainerMssqlRoot, $paths.BackupRoot, $paths.DataRootPath, $paths.LogRoot)) {
            if (-not (Test-Path -LiteralPath $path -PathType Container)) { New-Item -Path $path -ItemType Directory -Force | Out-Null }
        }
    }
    return $paths
}

function Add-LabPersistentContainerDrive {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Instance, [Parameter(Mandatory)]$Storage, [switch]$IncludeExternalRuntimeState)

    $existing = @($Instance.drives | Where-Object { $_ -and $_.containerPath -eq '/var/opt/mssql' })
    if ($existing.Count -gt 0) { throw 'LAB_DATA_CONTAINER_MSSQL_MOUNT_ALREADY_CONFIGURED' }

    # SQL Server 2025 kann auf Docker Desktop unter Windows beim direkten
    # Bind-Mount eines NTFS-Ordners auf /var/opt/mssql abstuerzen. Das
    # SQL-System bleibt deshalb in einem stabil benannten Runtime-Volume.
    # Der Data Root bleibt fuer BAK-Dateien sichtbar und der Volume-Name wird
    # als Metadatum im Run gespeichert. Damit ueberlebt der SQL-Systemzustand
    # auch das Entfernen eines einzelnen Containers, ohne den Windows-Mount als
    # Linux-Systemdateisystem zu missbrauchen.
    $volumeName = "sql-lab-persistent-$($Storage.LabId)-$($Storage.Provider)-$($Storage.InstanceId)-sql$($Storage.SqlVersion)"
    $Instance.drives += [PSCustomObject]@{
        id = 'persistent-mssql'; containerPath = '/var/opt/mssql'; volumeName = $volumeName
        persistence = 'data-root-runtime-volume'
    }
    if ($IncludeExternalRuntimeState) {
        $Instance.drives += [PSCustomObject]@{
            id = 'persistent-mssql-external-languages'; containerPath = '/var/opt/mssql-extensibility/externallanguages'; volumeName = "${volumeName}-external-languages"
            persistence = 'data-root-runtime-volume'; persistentStorageRole = 'EXTERNAL_LANGUAGES'
        }
        $Instance.drives += [PSCustomObject]@{
            id = 'persistent-mssql-external-libraries'; containerPath = '/var/opt/mssql-extensibility/externallibraries'; volumeName = "${volumeName}-external-libraries"
            persistence = 'data-root-runtime-volume'; persistentStorageRole = 'EXTERNAL_LIBRARIES'
        }
    }
    $Instance.drives += [PSCustomObject]@{
        id = 'persistent-backups'; containerPath = '/var/opt/mssql/backup'; hostPath = [string]$Storage.BackupRoot
        persistence = 'data-root-backup-bind'
    }
    return $Instance
}

function Add-LabSelectedPersistentContainerDrive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Instance,
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)]$Storage,
        [switch]$IncludeExternalRuntimeState
    )

    if ([string]$Plan.Status -ne 'READY' -or [string]$Plan.Action -notin @('CONTINUE','CLONE')) {
        throw 'CONTAINER_INSTANCE_STORE_READY_PLAN_REQUIRED'
    }
    if (@($Instance.drives | Where-Object { $_ -and $_.containerPath -eq '/var/opt/mssql' }).Count -gt 0) {
        throw 'LAB_DATA_CONTAINER_MSSQL_MOUNT_ALREADY_CONFIGURED'
    }
    $binding = if ([string]$Plan.Action -eq 'CONTINUE') {
        Get-LabContainerInstanceStoreDriveBinding -Plan $Plan
    }
    else {
        [PSCustomObject]@{
            id='persistent-mssql'; containerPath='/var/opt/mssql'; volumeName=[string]$Plan.Target.VolumeName
            persistence='cataloged-runtime-volume'; persistentStorageId=[string]$Plan.Target.PersistentStorageId
        }
    }
    $Instance.drives += $binding
    if ($IncludeExternalRuntimeState) {
        $sidecars = if ([string]$Plan.Action -eq 'CONTINUE') { @($Plan.Source.Sidecars) } else { @($Plan.Target.Sidecars) }
        if ($sidecars.Count -ne 2) { throw 'CONTAINER_INSTANCE_STORE_SIDECAR_PLAN_REQUIRED' }
        foreach ($sidecar in $sidecars) {
            $driveId = if ([string]$sidecar.Role -eq 'EXTERNAL_LANGUAGES') {
                'persistent-mssql-external-languages'
            }
            elseif ([string]$sidecar.Role -eq 'EXTERNAL_LIBRARIES') {
                'persistent-mssql-external-libraries'
            }
            else { throw 'CONTAINER_INSTANCE_STORE_SIDECAR_ROLE_INVALID' }
            $Instance.drives += [PSCustomObject]@{
                id=$driveId; containerPath=[string]$sidecar.ContainerPath; volumeName=[string]$sidecar.VolumeName
                persistence='cataloged-runtime-volume'; persistentStorageId=[string]$binding.persistentStorageId
                persistentStorageRole=[string]$sidecar.Role
            }
        }
    }
    $Instance.drives += [PSCustomObject]@{
        id='persistent-backups'; containerPath='/var/opt/mssql/backup'; hostPath=[string]$Storage.BackupRoot
        persistence='data-root-backup-bind'
    }
    return $Instance
}

function Add-LabRunScopedContainerSystemDrive {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Instance, [switch]$IncludeExternalRuntimeState)

    $currentDrives = @($Instance.drives)
    # Auch eine kurzlebige Lab-Umgebung muss einen kontrollierten Container-
    # Recreate ohne Verlust von master/model/msdb, Datenbankregistrierungen und
    # der zugehoerigen External-Language-/Library-Artefakte ueberstehen. Die
    # fluechtigen LaunchPad-Verzeichnisse data und sandboxes bleiben bewusst
    # containerlokal. Diese Volumes werden beim rungebundenen Lab-Cleanup
    # entfernt und sind daher nicht mit dem langlebigen Data-Root-Vertrag
    # gleichzusetzen.
    $required = @([PSCustomObject]@{ id='runtime-mssql'; containerPath='/var/opt/mssql'; persistence='run-scoped-runtime-volume' })
    if ($IncludeExternalRuntimeState) {
        $required += [PSCustomObject]@{ id='runtime-mssql-external-languages'; containerPath='/var/opt/mssql-extensibility/externallanguages'; persistence='run-scoped-runtime-volume' }
        $required += [PSCustomObject]@{ id='runtime-mssql-external-libraries'; containerPath='/var/opt/mssql-extensibility/externallibraries'; persistence='run-scoped-runtime-volume' }
    }
    $missing = @($required | Where-Object { $path = $_.containerPath; @($currentDrives | Where-Object containerPath -eq $path).Count -eq 0 })
    $Instance | Add-Member -NotePropertyName drives -NotePropertyValue (@($missing) + $currentDrives) -Force
    return $Instance
}
