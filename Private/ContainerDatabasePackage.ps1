<#
.SYNOPSIS
    Materialisiert ein offline verifiziertes Container-Datenbankpaket in Lab_Data.
.DESCRIPTION
    Der Export akzeptiert weder freie Containernamen noch Hostpfade. Er leitet
    Provider, Container, Port, Run und Scope ausschließlich aus der live
    revalidierten Containerbindung ab. Nach dem SQL-Offline-Commit werden nur
    die von sys.master_files gemeldeten Dateien kopiert und vor der Übergabe an
    die unveränderliche Paketbibliothek nochmals gehasht.
#>

function Export-LabContainerDatabasePackage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$InstanceId,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z][A-Za-z0-9_]{0,127}$')][string]$DatabaseName,
        [Parameter(Mandatory)][string]$DataRoot,
        [string]$StateRoot
    )

    $context = Get-LabContainerReconcileContext -RunId $RunId -InstanceId $InstanceId -StateRoot $StateRoot
    if (-not $context.WasRunning) { throw 'CONTAINER_DATABASE_PACKAGE_SOURCE_NOT_RUNNING' }
    $password = Get-LabSecret -Path $context.RunDirectory -Name 'sa-password'
    if (-not $password) { throw 'CONTAINER_DATABASE_PACKAGE_SA_SECRET_MISSING' }
    $plain = ConvertFrom-LabSecureString -SecureString $password
    $literal = $DatabaseName.Replace("'", "''")
    $identifier = $DatabaseName.Replace(']', ']]')
    $databaseHost = if ($context.Instance.host) { [string]$context.Instance.host } else { '127.0.0.1' }
    $stage = Join-Path $context.RunDirectory (Join-Path 'database-package-export' ([Guid]::NewGuid().ToString('N')))
    try {
        $inventoryQuery = @"
SET NOCOUNT ON;
IF DB_ID(N'$literal') IS NULL THROW 51000, 'CONTAINER_DATABASE_PACKAGE_DATABASE_NOT_FOUND', 1;
SELECT CONCAT(N'PKG_META|', CONVERT(nvarchar(10),SERVERPROPERTY('ProductMajorVersion')), N'|', CONVERT(nvarchar(1),d.is_encrypted), N'|', CONVERT(nvarchar(10),SUM(CASE WHEN mf.type = 2 THEN 1 ELSE 0 END)))
FROM sys.databases d JOIN sys.master_files mf ON mf.database_id=d.database_id WHERE d.name=N'$literal' GROUP BY d.database_id,d.is_encrypted;
SELECT CONCAT(
    N'PKG_FILE|', CONVERT(nvarchar(60), mf.type_desc) COLLATE Latin1_General_100_BIN2, N'|',
    CONVERT(nvarchar(128), mf.name) COLLATE Latin1_General_100_BIN2, N'|',
    CONVERT(nvarchar(4000), mf.physical_name) COLLATE Latin1_General_100_BIN2)
FROM sys.master_files mf WHERE mf.database_id=DB_ID(N'$literal') ORDER BY mf.file_id;
"@
        $lines = @(Invoke-SqlQuery -HostName $databaseHost -Port ([int]$context.CurrentPort) -SaPlain $plain -Database master -TimeoutSeconds 120 -Query $inventoryQuery | ForEach-Object { ([string]$_).Trim() })
        $meta = @($lines | Where-Object { $_ -match '^PKG_META\|\d+\|[01]\|\d+$' })
        $files = @($lines | Where-Object { $_ -match '^PKG_FILE\|' })
        if ($meta.Count -ne 1 -or $files.Count -lt 1) { throw 'CONTAINER_DATABASE_PACKAGE_INVENTORY_INVALID' }
        $metaParts = $meta[0].Split('|')
        if ([int]$metaParts[3] -ne 0) { throw 'CONTAINER_DATABASE_PACKAGE_FILESTREAM_NOT_YET_SUPPORTED' }
        $parsed = [Collections.Generic.List[object]]::new()
        foreach ($line in $files) {
            $parts = $line.Split('|', 4)
            if ($parts.Count -ne 4 -or $parts[1] -notin @('ROWS','LOG') -or [string]::IsNullOrWhiteSpace($parts[2]) -or [string]::IsNullOrWhiteSpace($parts[3]) -or $parts[3] -notmatch '^/') { throw 'CONTAINER_DATABASE_PACKAGE_FILE_INVENTORY_INVALID' }
            $parsed.Add([PSCustomObject]@{ Type=if($parts[1] -eq 'LOG'){'LOG'}else{'DATA'}; LogicalName=$parts[2]; ContainerPath=$parts[3] })
        }
        if ([int]$metaParts[2] -eq 1) { throw 'CONTAINER_DATABASE_PACKAGE_TDE_RECOVERY_EVIDENCE_REQUIRED' }
        $dependency = Get-LabDatabaseMigrationDependencyInventory -HostName $databaseHost -Port ([int]$context.CurrentPort) -SaPassword $password -DatabaseName $DatabaseName -Provider $context.Provider -RunId $RunId -InstanceId $InstanceId
        $null = Invoke-SqlQuery -HostName $databaseHost -Port ([int]$context.CurrentPort) -SaPlain $plain -Database master -TimeoutSeconds 120 -Query "ALTER DATABASE [$identifier] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; ALTER DATABASE [$identifier] SET OFFLINE;"
        $state = @(Invoke-SqlQuery -HostName $databaseHost -Port ([int]$context.CurrentPort) -SaPlain $plain -Database master -Query "SELECT state_desc FROM sys.databases WHERE name=N'$literal';" | ForEach-Object { ([string]$_).Trim() })
        if ($state -notcontains 'OFFLINE') { throw 'CONTAINER_DATABASE_PACKAGE_OFFLINE_POSTCONDITION_FAILED' }
        $null = New-Item -ItemType Directory -Path $stage -Force
        $runtime = Get-LabHostToolInvocation -Name ([string]$context.Provider)
        $localInventory = [Collections.Generic.List[object]]::new()
        $ordinal = 0
        foreach ($file in $parsed) {
            $target = Join-Path $stage ("file-$ordinal")
            $null = & $runtime cp "$($context.ContainerName):$($file.ContainerPath)" $target 2>&1
            if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $target -PathType Leaf)) { throw 'CONTAINER_DATABASE_PACKAGE_COPY_FAILED' }
            $localInventory.Add([PSCustomObject]@{ LogicalName=$file.LogicalName; Type=$file.Type; FullPath=$target })
            $ordinal++
        }
        $sourceEvidence = [PSCustomObject]@{ DatabaseState='OFFLINE'; DetachState='CLEAN_OFFLINE'; AccessMode='EXCLUSIVE'; WriterCount=0; StateObservedAfterLock=$true }
        $metadata = [PSCustomObject]@{ HasFileStream=$false; FileStreamInventoryComplete=$true; IsEncrypted=([int]$metaParts[2] -eq 1); TdeKeyEvidenceVerified=$false }
        New-LabDatabasePackage -DatabaseName $DatabaseName -Provider ([string]$context.Provider) -SqlMajorVersion ([string]$metaParts[1]) -RunId $RunId -InstanceId $InstanceId -SourceEvidence $sourceEvidence -DatabaseMetadata $metadata -FileInventory @($localInventory) -DataRoot $DataRoot -MigrationDependencyInventory $dependency
    }
    finally {
        $plain = $null
        if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
