<#
.SYNOPSIS
    Providerneutrale, inhaltsadressierte SQL-Backup-Bibliothek unter Lab_Data.
.DESCRIPTION
    Ein Backup wird erst nach BACKUP CHECKSUM, RESTORE VERIFYONLY WITH CHECKSUM,
    Host-Hash und sanitisierter Datenbankmetadaten-Evidence als REUSABLE
    veröffentlicht. Runtime-Adressen, Credentials und Gastpfade werden nicht
    persistiert.
#>

function Get-LabBackupLibraryPaths {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DataRoot)

    $root = Resolve-LabDataRootForUse -DataRoot $DataRoot
    $libraryRoot = Join-Path $root 'Backups'
    [PSCustomObject]@{
        DataRoot = $root
        LibraryRoot = $libraryRoot
        ObjectsRoot = Join-Path $libraryRoot 'Objects'
        RegistryPath = Join-Path $libraryRoot 'backup-library.json'
    }
}

function Test-LabBackupLibraryDocument {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Document)

    try {
        $valid = $Document | ConvertTo-Json -Depth 40 | Test-Json `
            -SchemaFile (Join-Path $script:SchemasPath 'backup-library.schema.json') -ErrorAction Stop
    }
    catch { throw "BACKUP_LIBRARY_SCHEMA_INVALID: $($_.Exception.Message)" }
    if (-not $valid) { throw 'BACKUP_LIBRARY_SCHEMA_INVALID' }

    $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($backup in @($Document.Backups)) {
        if (-not $ids.Add([string]$backup.BackupSetId)) { throw 'BACKUP_LIBRARY_ID_DUPLICATE' }
        if ([IO.Path]::IsPathFullyQualified([string]$backup.Artifact.RelativePath) -or
            [string]$backup.Artifact.RelativePath -match '(^|[\\/])\.\.([\\/]|$)') {
            throw 'BACKUP_LIBRARY_RELATIVE_PATH_INVALID'
        }
    }
    return $true
}

function Get-LabBackupLibraryDocument {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Paths)

    if (-not (Test-Path -LiteralPath $Paths.RegistryPath -PathType Leaf)) {
        return [PSCustomObject][ordered]@{
            ContractVersion = 'SqlServerLab.BackupLibrary/1.0'
            Revision = 0
            UpdatedAt = Get-LabTimestamp
            Backups = @()
        }
    }
    try {
        $document = Get-Content -LiteralPath $Paths.RegistryPath -Raw -Encoding utf8 |
            ConvertFrom-Json -Depth 40 -ErrorAction Stop
        $null = Test-LabBackupLibraryDocument -Document $document
        return $document
    }
    catch { throw "BACKUP_LIBRARY_INVALID: $($_.Exception.Message)" }
}

function Invoke-LabBackupLibraryLock {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$LibraryRoot,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock
    )

    $material = [Text.Encoding]::UTF8.GetBytes([IO.Path]::GetFullPath($LibraryRoot).ToLowerInvariant())
    $token = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($material)).Substring(0,16)
    $name = if ($IsWindows) { "Global\SQL_Server_Lab_Backup_Library_$token" } else { "SQL_Server_Lab_Backup_Library_$token" }
    $mutex = [Threading.Mutex]::new($false,$name)
    $acquired = $false
    try {
        $acquired = $mutex.WaitOne([TimeSpan]::FromSeconds(30))
        if (-not $acquired) { throw 'BACKUP_LIBRARY_LOCK_TIMEOUT' }
        return & $ScriptBlock
    }
    finally {
        if ($acquired) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Get-LabDatabaseBackupMetadata {
    [CmdletBinding()]
    param(
        [string]$HostName = '127.0.0.1',
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][string]$SaPlain,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z][A-Za-z0-9_]{0,127}$')][string]$DatabaseName
    )

    $escaped = $DatabaseName.Replace(']',']]')
    $query = @"
SET NOCOUNT ON;
IF DB_ID(N'$($DatabaseName.Replace("'","''"))') IS NULL THROW 51000, 'BACKUP_DATABASE_NOT_FOUND', 1;
USE [$escaped];
SELECT CONCAT(
    CONVERT(nvarchar(10),SERVERPROPERTY('ProductMajorVersion')), N'|',
    CONVERT(nvarchar(10),(SELECT COUNT_BIG(*) FROM sys.database_files)), N'|',
    CONVERT(nvarchar(10),(SELECT COUNT_BIG(*) FROM sys.database_files WHERE type = 2)), N'|',
    CONVERT(nvarchar(10),(SELECT COUNT_BIG(*) FROM sys.tables WHERE is_filetable = 1)), N'|',
    CONVERT(nvarchar(1),(SELECT is_encrypted FROM sys.databases WHERE database_id = DB_ID()))
);
"@
    $output = @(& sqlcmd -S "${HostName},${Port}" -U sa -P $SaPlain -C -b -d master `
        -Q $query -h -1 -W 2>&1)
    $exitCode = $LASTEXITCODE
    $text = ($output | ForEach-Object { [string]$_ }) -join "`n"
    if ($exitCode -ne 0 -or $text -match 'Msg \d+, Level (1[1-9]|[2-9]\d)') {
        throw "BACKUP_METADATA_QUERY_FAILED: $text"
    }
    $line = @($output | ForEach-Object { ([string]$_).Trim() } |
        Where-Object { $_ -match '^\d+\|\d+\|\d+\|\d+\|[01]$' } | Select-Object -First 1)
    if ($line.Count -ne 1) { throw 'BACKUP_METADATA_RESULT_INVALID' }
    $parts = $line[0].Split('|')
    [PSCustomObject][ordered]@{
        SqlMajorVersion = $parts[0]
        FileCount = [int]$parts[1]
        FileStreamFileCount = [int]$parts[2]
        FileTableCount = [int]$parts[3]
        HasFileStream = [int]$parts[2] -gt 0
        IsEncrypted = [int]$parts[4] -eq 1
    }
}

function Register-LabDatabaseBackupArtifact {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BackupPath,
        [Parameter(Mandatory)][string]$DatabaseName,
        [Parameter(Mandatory)][ValidateSet('docker','podman','hyperv')][string]$Provider,
        [Parameter(Mandatory)]$Metadata,
        [AllowNull()]$MigrationDependencyInventory,
        [string]$RunId,
        [string]$InstanceId,
        [Parameter(Mandatory)][string]$DataRoot
    )

    $paths = Get-LabBackupLibraryPaths -DataRoot $DataRoot
    $sha256 = (Get-FileHash -LiteralPath $BackupPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $bytes = (Get-Item -LiteralPath $BackupPath).Length
    if ($bytes -le 0) { throw 'BACKUP_LIBRARY_ARTIFACT_EMPTY' }
    $backupSetId = [Guid]::NewGuid().ToString('D')
    $relativePath = Join-Path 'Objects' "$sha256.bak"
    $objectPath = Join-Path $paths.LibraryRoot $relativePath
    $now = Get-LabTimestamp
    if($MigrationDependencyInventory){
        if([string]$MigrationDependencyInventory.DatabaseName -ne $DatabaseName){throw 'BACKUP_LIBRARY_DEPENDENCY_DATABASE_MISMATCH'}
        if([string]$MigrationDependencyInventory.Source.SqlMajorVersion -ne [string]$Metadata.SqlMajorVersion){throw 'BACKUP_LIBRARY_DEPENDENCY_SQL_VERSION_MISMATCH'}
        if([bool]$MigrationDependencyInventory.Database.IsEncrypted -ne [bool]$Metadata.IsEncrypted){throw 'BACKUP_LIBRARY_DEPENDENCY_ENCRYPTION_MISMATCH'}
    }
    $migrationBoundary=Get-LabDatabaseArtifactMigrationBoundary -DependencyInventory $MigrationDependencyInventory

    return Invoke-LabBackupLibraryLock -LibraryRoot $paths.LibraryRoot -ScriptBlock {
        foreach ($directory in @($paths.LibraryRoot,$paths.ObjectsRoot)) {
            if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
                New-Item -ItemType Directory -Path $directory -Force | Out-Null
            }
        }
        if (Test-Path -LiteralPath $objectPath -PathType Leaf) {
            $existingHash = (Get-FileHash -LiteralPath $objectPath -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($existingHash -ne $sha256) { throw 'BACKUP_LIBRARY_OBJECT_HASH_CONFLICT' }
        }
        else {
            $temporaryObject = "$objectPath.$([Guid]::NewGuid().ToString('N')).tmp"
            try {
                Copy-Item -LiteralPath $BackupPath -Destination $temporaryObject
                if ((Get-FileHash -LiteralPath $temporaryObject -Algorithm SHA256).Hash.ToLowerInvariant() -ne $sha256) {
                    throw 'BACKUP_LIBRARY_COPY_HASH_MISMATCH'
                }
                [IO.File]::Move($temporaryObject,$objectPath)
            }
            finally { if (Test-Path -LiteralPath $temporaryObject) { Remove-Item -LiteralPath $temporaryObject -Force } }
        }

        $document = Get-LabBackupLibraryDocument -Paths $paths
        $record = [PSCustomObject][ordered]@{
            BackupSetId = $backupSetId
            Status = 'REUSABLE'
            DatabaseName = $DatabaseName
            Source = [PSCustomObject][ordered]@{
                Provider = $Provider
                RunId = if ($RunId) { $RunId } else { $null }
                InstanceId = if ($InstanceId) { $InstanceId } else { $null }
                SqlMajorVersion = [string]$Metadata.SqlMajorVersion
            }
            DatabaseMetadata = [PSCustomObject][ordered]@{
                FileCount = [int]$Metadata.FileCount
                FileStreamFileCount = [int]$Metadata.FileStreamFileCount
                FileTableCount = [int]$Metadata.FileTableCount
                HasFileStream = [bool]$Metadata.HasFileStream
                IsEncrypted = [bool]$Metadata.IsEncrypted
                MigrationBoundary = $migrationBoundary
            }
            Artifact = [PSCustomObject][ordered]@{
                RelativePath = $relativePath
                Sha256 = $sha256
                Bytes = [long]$bytes
            }
            Verification = [PSCustomObject][ordered]@{
                BackupChecksum = $true
                RestoreVerifyOnly = $true
                VerifiedAt = $now
                RestoreVerifications = @()
            }
            CreatedAt = $now
            UpdatedAt = $now
        }
        $document.Revision = [int]$document.Revision + 1
        $document.UpdatedAt = $now
        $document.Backups = @($document.Backups) + @($record)
        $null = Test-LabBackupLibraryDocument -Document $document
        Write-LabArtifactJsonAtomic -Path $paths.RegistryPath -InputObject $document
        [PSCustomObject]@{ Record=$record; Path=$objectPath; RegistryPath=$paths.RegistryPath }
    }
}

function Get-LabDatabaseBackup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F-]{36}$')][string]$BackupSetId,
        [Parameter(Mandatory)][string]$DataRoot
    )

    $paths = Get-LabBackupLibraryPaths -DataRoot $DataRoot
    $document = Get-LabBackupLibraryDocument -Paths $paths
    $matches = @($document.Backups | Where-Object BackupSetId -eq $BackupSetId)
    if ($matches.Count -ne 1) { throw 'BACKUP_LIBRARY_SET_NOT_FOUND' }
    $record = $matches[0]
    if ([string]$record.Status -ne 'REUSABLE') { throw 'BACKUP_LIBRARY_SET_NOT_REUSABLE' }
    if (-not [bool]$record.Verification.BackupChecksum -or -not [bool]$record.Verification.RestoreVerifyOnly) {
        throw 'BACKUP_LIBRARY_SET_NOT_VERIFIED'
    }
    $path = Join-Path $paths.LibraryRoot ([string]$record.Artifact.RelativePath)
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'BACKUP_LIBRARY_OBJECT_MISSING' }
    $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($hash -ne [string]$record.Artifact.Sha256) { throw 'BACKUP_LIBRARY_OBJECT_HASH_MISMATCH' }
    [PSCustomObject]@{ Record=$record; Path=$path; RegistryPath=$paths.RegistryPath }
}

function Get-LabDatabaseBackupSelection {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DataRoot)

    $paths = Get-LabBackupLibraryPaths -DataRoot $DataRoot
    $document = Get-LabBackupLibraryDocument -Paths $paths
    @($document.Backups | Sort-Object CreatedAt -Descending | ForEach-Object {
        $record = $_
        $objectPath = Join-Path $paths.LibraryRoot ([string]$record.Artifact.RelativePath)
        $verified = [bool]$record.Verification.BackupChecksum -and [bool]$record.Verification.RestoreVerifyOnly
        $availability = if ([string]$record.Status -ne 'REUSABLE' -or -not $verified) {
            'BLOCKED'
        }
        elseif (-not (Test-Path -LiteralPath $objectPath -PathType Leaf)) {
            'MISSING'
        }
        else {
            'SELECTABLE'
        }
        [PSCustomObject][ordered]@{
            BackupSetId = [string]$record.BackupSetId
            Availability = $availability
            DatabaseName = [string]$record.DatabaseName
            SourceProvider = [string]$record.Source.Provider
            SourceSqlMajorVersion = [string]$record.Source.SqlMajorVersion
            Bytes = [long]$record.Artifact.Bytes
            HasFileStream = [bool]$record.DatabaseMetadata.HasFileStream
            IsEncrypted = [bool]$record.DatabaseMetadata.IsEncrypted
            MigrationBoundary = [string]$record.DatabaseMetadata.MigrationBoundary.ArtifactScope
            RestoreVerificationCount = @($record.Verification.RestoreVerifications).Count
            CreatedAt = [string]$record.CreatedAt
        }
    })
}

function Add-LabDatabaseBackupRestoreVerification {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BackupSetId,
        [Parameter(Mandatory)][ValidateSet('docker','podman','hyperv')][string]$TargetProvider,
        [Parameter(Mandatory)][string]$TargetSqlMajorVersion,
        [Parameter(Mandatory)][ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$ContentSha256,
        [Parameter(Mandatory)][bool]$FileStreamContentVerified,
        [Parameter(Mandatory)][string]$DataRoot
    )

    $paths = Get-LabBackupLibraryPaths -DataRoot $DataRoot
    Invoke-LabBackupLibraryLock -LibraryRoot $paths.LibraryRoot -ScriptBlock {
        $document = Get-LabBackupLibraryDocument -Paths $paths
        $matches = @($document.Backups | Where-Object BackupSetId -eq $BackupSetId)
        if ($matches.Count -ne 1) { throw 'BACKUP_LIBRARY_SET_NOT_FOUND' }
        $record = $matches[0]
        if ([bool]$record.DatabaseMetadata.HasFileStream -and -not $FileStreamContentVerified) {
            throw 'BACKUP_LIBRARY_FILESTREAM_CONTENT_EVIDENCE_REQUIRED'
        }
        $now = Get-LabTimestamp
        $evidence = [PSCustomObject][ordered]@{
            TargetProvider = $TargetProvider
            TargetSqlMajorVersion = $TargetSqlMajorVersion
            ContentSha256 = $ContentSha256.ToLowerInvariant()
            FileStreamContentVerified = $FileStreamContentVerified
            VerifiedAt = $now
        }
        $record.Verification.RestoreVerifications = @($record.Verification.RestoreVerifications) + @($evidence)
        $record.UpdatedAt = $now
        $document.Revision = [int]$document.Revision + 1
        $document.UpdatedAt = $now
        $null = Test-LabBackupLibraryDocument -Document $document
        Write-LabArtifactJsonAtomic -Path $paths.RegistryPath -InputObject $document
        return $evidence
    }
}

function New-LabDatabaseLibraryBackup {
    [CmdletBinding()]
    param(
        [string]$HostName = '127.0.0.1',
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][SecureString]$SaPassword,
        [ValidateSet('docker','podman','hyperv')][string]$Provider,
        [string]$ContainerName,
        [string]$RunId,
        [string]$InstanceId = 'primary',
        [PSCredential]$GuestCredential,
        [Parameter(Mandatory)][string]$DatabaseName,
        [Parameter(Mandatory)][string]$DataRoot,
        [string]$StateRoot
    )

    $workingDirectory = Join-Path ([IO.Path]::GetTempPath()) "sql-server-lab-backup-$([Guid]::NewGuid().ToString('N'))"
    $backupFileName = "backup-$([Guid]::NewGuid().ToString('N')).bak"
    $hostBackupPath = Join-Path $workingDirectory $backupFileName
    New-Item -ItemType Directory -Path $workingDirectory -Force | Out-Null
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SaPassword)
    try { $saPlain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    try {
        $metadata = Get-LabDatabaseBackupMetadata -HostName $HostName -Port $Port -SaPlain $saPlain -DatabaseName $DatabaseName
        $dependencyInventory = New-LabDatabaseMigrationDependencyInventory -DatabaseName $DatabaseName -Provider $(if($Provider){$Provider}else{'external'}) -RunId $RunId -InstanceId $InstanceId -Observation (Get-LabDatabaseMigrationDependencySqlObservation -HostName $HostName -Port $Port -SaPlain $saPlain -DatabaseName $DatabaseName)
        if ([bool]$metadata.IsEncrypted) {
            throw 'BACKUP_LIBRARY_TDE_DEPENDENCY_UNSUPPORTED: Verschlüsselte Datenbanken werden ohne separaten Zertifikat- und Recovery-Vertrag nicht als wiederverwendbar veröffentlicht.'
        }
        $targetArguments = @{ Port=$Port; ContainerName=$ContainerName; RunId=$RunId; InstanceId=$InstanceId; GuestCredential=$GuestCredential; StateRoot=$StateRoot }
        if ($Provider) { $targetArguments.Provider=$Provider }
        $target = Initialize-LabSampleBaselineBackupTarget @targetArguments
        $runtimeBackupPath = if ([string]$target.Provider -eq 'hyperv') {
            Get-LabStorageGuestChildPath -Root ([string]$target.BackupRoot) -Child $backupFileName
        } else { "/var/opt/mssql/backup/$backupFileName" }
        $escapedDatabase = $DatabaseName.Replace(']',']]')
        $escapedPath = $runtimeBackupPath.Replace("'","''")
        $null = Invoke-SqlQuery -HostName $HostName -Port $Port -SaPlain $saPlain -TimeoutSeconds 600 -Query @"
BACKUP DATABASE [$escapedDatabase] TO DISK = N'$escapedPath' WITH COPY_ONLY, INIT, CHECKSUM;
RESTORE VERIFYONLY FROM DISK = N'$escapedPath' WITH CHECKSUM;
"@
        $export = Export-LabSampleBaselineBackup -Target $target -RuntimeBackupPath $runtimeBackupPath -DestinationPath $hostBackupPath -Port $Port
        $registered = Register-LabDatabaseBackupArtifact -BackupPath $hostBackupPath -DatabaseName $DatabaseName `
            -Provider ([string]$export.Provider) -Metadata $metadata -MigrationDependencyInventory $dependencyInventory -RunId $RunId -InstanceId $InstanceId -DataRoot $DataRoot
        [PSCustomObject]@{
            Status='BACKUP_REUSABLE'; BackupSetId=[string]$registered.Record.BackupSetId
            DatabaseName=$DatabaseName; Provider=[string]$export.Provider
            Path=[string]$registered.Path; Sha256=[string]$registered.Record.Artifact.Sha256
            Bytes=[long]$registered.Record.Artifact.Bytes; HasFileStream=[bool]$registered.Record.DatabaseMetadata.HasFileStream
            MigrationBoundary=$registered.Record.DatabaseMetadata.MigrationBoundary
            RegistryPath=[string]$registered.RegistryPath
        }
    }
    finally {
        $saPlain=$null
        if (Test-Path -LiteralPath $hostBackupPath) { Remove-Item -LiteralPath $hostBackupPath -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $workingDirectory) { Remove-Item -LiteralPath $workingDirectory -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
