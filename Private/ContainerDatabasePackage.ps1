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
    $operationId=[guid]::NewGuid().ToString('D')
    $exportRoot=Join-Path $context.RunDirectory 'database-package-export'
    $operationRoot=Join-Path $exportRoot ([guid]$operationId).ToString('N')
    $stage=Join-Path $operationRoot 'payload'
    $journalPath=Join-Path $operationRoot 'source-journal.json'
    $lockMaterial=[Text.Encoding]::UTF8.GetBytes("$($context.Provider)|$($context.ContainerId)|$($DatabaseName.ToUpperInvariant())")
    $lockToken=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($lockMaterial))
    $mutexName=$(if($IsWindows){'Global\'})+"SQL_Server_Lab_Package_Export_$lockToken"
    $mutex=[Threading.Mutex]::new($false,$mutexName)
    $acquired=$false;$journal=$null;$sourceMutationStarted=$false;$publicationStarted=$false;$primaryFailure=$null
    $progress = Start-LabActionProgress -Phase Transfer
    try {
        $lockDeadline=[datetime]::UtcNow.AddSeconds(30)
        do {
            try{$acquired=$mutex.WaitOne(200)}catch [Threading.AbandonedMutexException]{$acquired=$true}
            if(-not $acquired){Update-LabActionProgress -Progress $progress -Phase Transfer}
        } while(-not $acquired -and [datetime]::UtcNow -lt $lockDeadline)
        if(-not $acquired){throw 'CONTAINER_DATABASE_PACKAGE_EXPORT_LOCK_TIMEOUT'}
        $fresh=Get-LabContainerReconcileContext -RunId $RunId -InstanceId $InstanceId -StateRoot $StateRoot
        if(-not $fresh.WasRunning -or $fresh.ContainerId -ne $context.ContainerId){throw 'CONTAINER_DATABASE_PACKAGE_SOURCE_BINDING_CHANGED'}
        $context=$fresh
        $databaseHost=if($context.Instance.host){[string]$context.Instance.host}else{'127.0.0.1'}
        Assert-LabContainerPackageExportPath -RunDirectory $context.RunDirectory -Path $journalPath
        if(Test-Path -LiteralPath $exportRoot -PathType Container){
            foreach($entry in Get-ChildItem -LiteralPath $exportRoot -Directory){
                if($entry.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'CONTAINER_DATABASE_PACKAGE_EXPORT_REPARSE_POINT'}
                $pendingPath=Join-Path $entry.FullName 'source-journal.json'
                Assert-LabContainerPackageExportPath -RunDirectory $context.RunDirectory -Path $pendingPath
                if(-not (Test-Path -LiteralPath $pendingPath -PathType Leaf)){continue}
                $pending=Get-Content -LiteralPath $pendingPath -Raw | ConvertFrom-Json -Depth 12
                Assert-LabContainerPackageExportJournal -Journal $pending
                if($entry.Name -cne ([guid]$pending.OperationId).ToString('N') -or $pending.RunId -ne $RunId -or $pending.ScopeId -ne $context.Run.scopeId -or $pending.InstanceId -ne $InstanceId -or $pending.Provider -ne $context.Provider){throw 'CONTAINER_DATABASE_PACKAGE_EXPORT_JOURNAL_INVALID'}
                if(-not [string]::Equals($pending.DatabaseName,$DatabaseName,[StringComparison]::OrdinalIgnoreCase)){continue}
                $pendingCleanup=$pending.CleanupState -ne 'CLEANED'
                if($pendingCleanup -and $pending.PublishedResult){$pending.Status='RECOVERY_REQUIRED';$pending.SourceRecovery='PRESERVE_OFFLINE'}
                if($pending.CleanupState -ne 'CLEANED'){
                    Remove-LabContainerPackageExportPayload -RunDirectory $context.RunDirectory -Path (Join-Path $entry.FullName 'payload')
                    $pending.CleanupState='CLEANED'
                    Write-LabContainerPackageExportJournal -Journal $pending -Path $pendingPath
                }
                if($pending.PublishedResult -and ($pendingCleanup -or $pending.Status -ne 'COMPLETED')){
                    $existing=Get-LabContainerPackagePublishedResult -Journal $pending -DataRoot $DataRoot
                    $pending.Status='COMPLETED';$pending.SourceRecovery='NOT_REQUIRED'
                    Write-LabContainerPackageExportJournal -Journal $pending -Path $pendingPath
                    return $existing
                }
                if($pending.Status -in @('COMPLETED','ROLLED_BACK')){continue}
                if($pending.Status -eq 'PUBLISHING' -or $pending.SourceRecovery -eq 'PRESERVE_OFFLINE'){throw 'CONTAINER_DATABASE_PACKAGE_LIBRARY_RECOVERY_REQUIRED'}
                Restore-LabContainerPackageExportSource -Context $context -Journal $pending -SaPlain $plain
                $pending.Status='ROLLED_BACK';$pending.SourceRecovery='RESTORED'
                Write-LabContainerPackageExportJournal -Journal $pending -Path $pendingPath
            }
        }
        $sourceState=Get-LabContainerPackageDatabaseState -Context $context -DatabaseName $DatabaseName -SaPlain $plain
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
        $journal=[pscustomobject]@{
            ContractVersion='SqlServerLab.ContainerDatabasePackageExportJournal/1.0';OperationId=$operationId
            RunId=$RunId;ScopeId=[string]$context.Run.scopeId;InstanceId=$InstanceId;Provider=[string]$context.Provider;ContainerId=[string]$context.ContainerId
            DatabaseName=$DatabaseName;DatabaseGuid=$sourceState.DatabaseGuid;FileIdentity=$sourceState.FileIdentity;OriginalState=$sourceState.State;OriginalAccess=$sourceState.Access
            Status='PREPARED';FailureCode=$null;SourceRecovery='RESTORE_ORIGINAL_STATE';CleanupState='PENDING';PublishedResult=$null;UpdatedAt=Get-LabTimestamp
        }
        Write-LabContainerPackageExportJournal -Journal $journal -Path $journalPath
        $sourceMutationStarted=$true
        $sourceGuard=Get-LabContainerPackageSourceGuardSql -DatabaseName $DatabaseName -DatabaseGuid $sourceState.DatabaseGuid -FileIdentity $sourceState.FileIdentity
        $null = Invoke-SqlQuery -HostName $databaseHost -Port ([int]$context.CurrentPort) -SaPlain $plain -Database master -TimeoutSeconds 120 -Query ($sourceGuard+" ALTER DATABASE [$identifier] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; ALTER DATABASE [$identifier] SET OFFLINE;")
        $state = @(Invoke-SqlQuery -HostName $databaseHost -Port ([int]$context.CurrentPort) -SaPlain $plain -Database master -Query "SELECT state_desc FROM sys.databases WHERE name=N'$literal';" | ForEach-Object { ([string]$_).Trim() })
        if ($state -notcontains 'OFFLINE') { throw 'CONTAINER_DATABASE_PACKAGE_OFFLINE_POSTCONDITION_FAILED' }
        $lockedSource=Get-LabContainerPackageDatabaseState -Context $context -DatabaseName $DatabaseName -SaPlain $plain
        if(($sourceState.DatabaseGuid -and $lockedSource.DatabaseGuid -and $lockedSource.DatabaseGuid -ne $sourceState.DatabaseGuid) -or
            (Get-LabContainerPackageIdentitySignature $lockedSource.FileIdentity) -cne (Get-LabContainerPackageIdentitySignature $sourceState.FileIdentity) -or
            $lockedSource.State -ne 'OFFLINE' -or $lockedSource.Access -ne 'SINGLE_USER'){throw 'CONTAINER_DATABASE_PACKAGE_SOURCE_IDENTITY_CHANGED'}
        $lockedFiles=@(Invoke-SqlQuery -HostName $databaseHost -Port ([int]$context.CurrentPort) -SaPlain $plain -Database master -TimeoutSeconds 120 -Query $inventoryQuery | ForEach-Object {([string]$_).Trim()} | Where-Object {$_ -like 'PKG_FILE|*'})
        if(($lockedFiles -join "`n") -cne ($files -join "`n")){throw 'CONTAINER_DATABASE_PACKAGE_FILE_INVENTORY_CHANGED'}
        $journal.Status='COPYING'
        Write-LabContainerPackageExportJournal -Journal $journal -Path $journalPath
        $null = New-Item -ItemType Directory -Path $stage -Force
        $runtime = Get-LabHostToolInvocation -Name ([string]$context.Provider)
        $localInventory = [Collections.Generic.List[object]]::new()
        $ordinal = 0
        foreach ($file in $parsed) {
            $target = Join-Path $stage ("file-$ordinal")
            $copyResult = Invoke-LabProgressNativeCommand -FilePath $runtime -ArgumentList @('cp',"$($context.ContainerId):$($file.ContainerPath)",$target) -Phase Transfer -Progress $progress
            if ($copyResult.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $target -PathType Leaf)) { throw 'CONTAINER_DATABASE_PACKAGE_COPY_FAILED' }
            $localInventory.Add([PSCustomObject]@{ LogicalName=$file.LogicalName; Type=$file.Type; FullPath=$target })
            $ordinal++
        }
        $sourceEvidence = [PSCustomObject]@{ DatabaseState='OFFLINE'; DetachState='CLEAN_OFFLINE'; AccessMode='EXCLUSIVE'; WriterCount=0; StateObservedAfterLock=$true }
        $metadata = [PSCustomObject]@{ HasFileStream=$false; FileStreamInventoryComplete=$true; IsEncrypted=([int]$metaParts[2] -eq 1); TdeKeyEvidenceVerified=$false }
        $journal.Status='PUBLISHING';$journal.SourceRecovery='PRESERVE_OFFLINE'
        Write-LabContainerPackageExportJournal -Journal $journal -Path $journalPath
        $publicationStarted=$true
        $published=New-LabDatabasePackage -DatabaseName $DatabaseName -Provider ([string]$context.Provider) -SqlMajorVersion ([string]$metaParts[1]) -RunId $RunId -InstanceId $InstanceId -SourceEvidence $sourceEvidence -DatabaseMetadata $metadata -FileInventory @($localInventory) -DataRoot $DataRoot -MigrationDependencyInventory $dependency
        $journal.PublishedResult=[pscustomobject]@{Status='REUSABLE';DatabasePackageId=[string]$published.DatabasePackageId;PersistentStorageId=[string]$published.PersistentStorageId}
        $journal.Status='COMPLETED';$journal.SourceRecovery='NOT_REQUIRED'
        Write-LabContainerPackageExportJournal -Journal $journal -Path $journalPath
        return $published
    }
    catch {
        $primaryFailure=$_
        if($journal){
            $journal.FailureCode=if($_.Exception.Message -match '(?:CONTAINER_DATABASE_PACKAGE|DATABASE_PACKAGE)_[A-Z0-9_]+'){$Matches[0]}else{'CONTAINER_DATABASE_PACKAGE_EXPORT_FAILED'}
            $journal.Status='RECOVERY_REQUIRED'
            if(-not $publicationStarted){
                try {
                    if($sourceMutationStarted){Restore-LabContainerPackageExportSource -Context $context -Journal $journal -SaPlain $plain}
                    $journal.Status='ROLLED_BACK';$journal.SourceRecovery='RESTORED'
                }
                catch {$journal.SourceRecovery='RESTORE_ORIGINAL_STATE'}
            }
            try {Write-LabContainerPackageExportJournal -Journal $journal -Path $journalPath}
            catch {Write-Warning 'CONTAINER_DATABASE_PACKAGE_RECOVERY_JOURNAL_WRITE_FAILED'}
        }
        $PSCmdlet.ThrowTerminatingError($primaryFailure)
    }
    finally {
        $plain = $null
        try {
            if ($progress) { Stop-LabActionProgress -Progress $progress }
            try {
                Remove-LabContainerPackageExportPayload -RunDirectory $context.RunDirectory -Path $stage
                if($journal){$journal.CleanupState='CLEANED';Write-LabContainerPackageExportJournal -Journal $journal -Path $journalPath}
            }
            catch {
                if($journal){
                    $journal.CleanupState='FAILED'
                    try {Write-LabContainerPackageExportJournal -Journal $journal -Path $journalPath}
                    catch {Write-Warning 'CONTAINER_DATABASE_PACKAGE_RECOVERY_JOURNAL_WRITE_FAILED'}
                }
                if($primaryFailure){Write-Warning 'CONTAINER_DATABASE_PACKAGE_PAYLOAD_CLEANUP_FAILED'}
                else {throw 'CONTAINER_DATABASE_PACKAGE_PAYLOAD_CLEANUP_FAILED'}
            }
        }
        finally {if($acquired){$mutex.ReleaseMutex()};$mutex.Dispose()}
    }
}
