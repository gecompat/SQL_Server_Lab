<#
.SYNOPSIS
    Prueft explizit ausgewaehlte Backupsets im bereits gebundenen SQL-Backup-Mount vor.
.DESCRIPTION
    Dieser Vertrag ist kein Transferexecutor. Er akzeptiert nur explizite
    DatabaseTransfers, bindet einen bereits laufenden verwalteten Docker- oder
    Podman-Zielcontainer und verwendet ausschliesslich dessen bereits vorhandenen
    persistent-backups Bind-Mount. Vor der ersten Staging-Kopie werden die ganze
    Auswahl, die Backup-Receipts, die Zielbindung und der Mount vollstaendig
    revalidiert. SQL fuehrt danach nur HEADERONLY und VERIFYONLY aus; Restore,
    Datenbankerzeugung sowie Container-, Mount- und Lifecyclemutationen bleiben
    ausgeschlossen.
#>

function Get-LabPortableContainerTransferPreflightSelectionDigest {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$DatabaseTransfers)

    $normalized=@($DatabaseTransfers | ForEach-Object {
        [PSCustomObject][ordered]@{
            SourceDatabaseName=([string]$_.SourceDatabaseName)
            TargetDatabaseName=([string]$_.TargetDatabaseName)
            BackupSetId=([string]$_.BackupSetId).ToLowerInvariant()
        }
    } | Sort-Object SourceDatabaseName,TargetDatabaseName,BackupSetId)
    $bytes=[Text.Encoding]::UTF8.GetBytes(($normalized|ConvertTo-Json -Depth 5 -Compress))
    try { return ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))).ToLowerInvariant() }
    finally { [Array]::Clear($bytes,0,$bytes.Length) }
}

function New-LabPortableContainerTransferPreflightRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceRunId,
        [Parameter(Mandatory)][string]$SourceInstanceId,
        [Parameter(Mandatory)][string]$TargetRunId,
        [Parameter(Mandatory)][string]$TargetInstanceId,
        [Parameter(Mandatory)][object[]]$DatabaseTransfers
    )

    $seenTarget=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $normalized=[Collections.Generic.List[object]]::new()
    foreach($entry in $DatabaseTransfers) {
        $sourceName=[string]$entry.SourceDatabaseName;$targetName=[string]$entry.TargetDatabaseName;$backupSetId=[string]$entry.BackupSetId
        if($sourceName -notmatch '^[A-Za-z][A-Za-z0-9_]{0,127}$' -or $targetName -notmatch '^[A-Za-z][A-Za-z0-9_]{0,127}$' -or $backupSetId -notmatch '^[0-9a-fA-F-]{36}$') { throw 'PORTABLE_CONTAINER_TRANSFER_PREFLIGHT_DATABASE_SELECTION_INVALID' }
        if(-not $seenTarget.Add($targetName)) { throw 'PORTABLE_CONTAINER_TRANSFER_PREFLIGHT_TARGET_DATABASE_DUPLICATE' }
        $normalized.Add([PSCustomObject][ordered]@{SourceDatabaseName=$sourceName;TargetDatabaseName=$targetName;BackupSetId=$backupSetId.ToLowerInvariant()})
    }
    if($normalized.Count -eq 0) { throw 'PORTABLE_CONTAINER_TRANSFER_PREFLIGHT_DATABASE_SELECTION_REQUIRED' }
    $request=[PSCustomObject][ordered]@{
        ContractVersion='SqlServerLab.PortableContainerTransferPreflightRequest/1.0'
        OperationId=[guid]::NewGuid().ToString('D')
        SourceRunId=$SourceRunId.ToLowerInvariant()
        SourceInstanceId=$SourceInstanceId
        TargetRunId=$TargetRunId.ToLowerInvariant()
        TargetInstanceId=$TargetInstanceId
        DatabaseTransfers=@($normalized | Sort-Object SourceDatabaseName,TargetDatabaseName,BackupSetId)
        SelectionDigest=(Get-LabPortableContainerTransferPreflightSelectionDigest -DatabaseTransfers @($normalized))
        CreatedAt=Get-LabTimestamp
    }
    $schema=Join-Path $script:SchemasPath 'portable-container-transfer-preflight-request.schema.json'
    if(-not ($request|ConvertTo-Json -Depth 10|Test-Json -SchemaFile $schema -ErrorAction Stop)) { throw 'PORTABLE_CONTAINER_TRANSFER_PREFLIGHT_REQUEST_INVALID' }
    return $request
}

function Get-LabPortableContainerTransferPreflightBackups {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Request,[Parameter(Mandatory)][string]$DataRoot)

    $blockers=[Collections.Generic.List[string]]::new();$records=[Collections.Generic.List[object]]::new()
    foreach($transfer in @($Request.DatabaseTransfers)) {
        $view=[ordered]@{BackupSetId=[string]$transfer.BackupSetId;SourceDatabaseName=[string]$transfer.SourceDatabaseName;TargetDatabaseName=[string]$transfer.TargetDatabaseName;Sha256=$null;Bytes=0;HeaderOnly='NOT_EXECUTED';VerifyOnly='NOT_EXECUTED'}
        try {
            $backup=Get-LabDatabaseBackup -BackupSetId ([string]$transfer.BackupSetId) -DataRoot $DataRoot
            $item=Get-Item -LiteralPath $backup.Path -ErrorAction Stop
            $record=$backup.Record
            $expectedHash=[string]$record.Artifact.Sha256;$expectedBytes=[long]$record.Artifact.Bytes
            $actualHash=(Get-LabProgressFileHash -LiteralPath $backup.Path -Algorithm SHA256).Hash.ToLowerInvariant()
            $view.Sha256=$expectedHash;$view.Bytes=$expectedBytes
            if($actualHash -ne $expectedHash -or $item.Length -ne $expectedBytes) { $blockers.Add('BACKUP_SHA256_OR_SIZE_MISMATCH') }
            if(-not [bool]$record.Verification.BackupChecksum -or -not [bool]$record.Verification.RestoreVerifyOnly) { $blockers.Add('BACKUP_CHECKSUM_OR_VERIFYONLY_EVIDENCE_MISSING') }
            if([string]$record.Source.RunId -cne [string]$Request.SourceRunId -or [string]$record.Source.InstanceId -cne [string]$Request.SourceInstanceId) { $blockers.Add('BACKUP_SOURCE_BINDING_MISMATCH') }
            if([string]$record.Source.SqlMajorVersion -ne '17' -or [bool]$record.DatabaseMetadata.HasFileStream -or [bool]$record.DatabaseMetadata.IsEncrypted) { $blockers.Add('BACKUP_SCOPE_UNSUPPORTED') }
            $records.Add([PSCustomObject]@{ Public=[PSCustomObject]$view; SourcePath=(Resolve-Path -LiteralPath $backup.Path -ErrorAction Stop).Path; StageFileName="$($transfer.BackupSetId.ToLowerInvariant()).bak" })
        } catch { $blockers.Add('BACKUP_LOCAL_OWNERSHIP_OR_INTEGRITY_UNVERIFIABLE') }
    }
    return [PSCustomObject]@{ Records=@($records); Blockers=@($blockers|Sort-Object -Unique) }
}

function Get-LabPortableContainerTransferPreflightTargetBinding {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Request,[string]$StateRoot)

    $public=[ordered]@{Provider=$null;RunId=[string]$Request.TargetRunId;InstanceId=[string]$Request.TargetInstanceId;RuntimeScopeId=$null;ContainerId=$null;BindingStatus='UNAVAILABLE'}
    try {
        $run=Get-LabRunState -RunId ([string]$Request.TargetRunId) -StateRoot $StateRoot
        $target=Resolve-LabRunInstance -RunId ([string]$Request.TargetRunId) -InstanceId ([string]$Request.TargetInstanceId) -StateRoot $StateRoot
        if([string]$run.state -ne 'RUNNING' -or [string]$target.Provider -notin @('docker','podman')) { return [PSCustomObject]@{Available=$false;Code='SQL_VISIBLE_STAGING_BINDING_UNAVAILABLE';Public=[PSCustomObject]$public} }
        $public.Provider=[string]$target.Provider
        $scope=Get-LabContainerRuntimeScope -Provider ([string]$target.Provider)
        if([string]$scope.Status -ne 'AVAILABLE' -or [string]::IsNullOrWhiteSpace([string]$scope.RuntimeId)) { return [PSCustomObject]@{Available=$false;Code='SQL_VISIBLE_STAGING_BINDING_UNAVAILABLE';Public=[PSCustomObject]$public} }
        $public.RuntimeScopeId=[string]$scope.RuntimeId
        $drive=@($target.drives | Where-Object { $_ -and [string]$_.id -eq 'persistent-backups' -and [string]$_.containerPath -eq '/var/opt/mssql/backup' })
        if($drive.Count -ne 1 -or [string]::IsNullOrWhiteSpace([string]$drive[0].hostPath)) { return [PSCustomObject]@{Available=$false;Code='SQL_VISIBLE_STAGING_BINDING_UNAVAILABLE';Public=[PSCustomObject]$public} }
        $hostRoot=(Resolve-Path -LiteralPath ([string]$drive[0].hostPath) -ErrorAction Stop).Path
        $runtime=Get-LabHostToolInvocation -Name ([string]$target.Provider)
        $inspection=@(& $runtime inspect ([string]$target.ContainerName) 2>$null)
        if($LASTEXITCODE -ne 0 -or $inspection.Count -eq 0) { return [PSCustomObject]@{Available=$false;Code='SQL_VISIBLE_STAGING_BINDING_UNAVAILABLE';Public=[PSCustomObject]$public} }
        $container=($inspection -join "`n")|ConvertFrom-Json -Depth 30
        if($container -is [array]) { if($container.Count -ne 1){return [PSCustomObject]@{Available=$false;Code='SQL_VISIBLE_STAGING_BINDING_UNAVAILABLE';Public=[PSCustomObject]$public}};$container=$container[0] }
        if(-not $container.State.Running -or [string]::IsNullOrWhiteSpace([string]$container.Id)) { return [PSCustomObject]@{Available=$false;Code='SQL_VISIBLE_STAGING_BINDING_UNAVAILABLE';Public=[PSCustomObject]$public} }
        $mount=@($container.Mounts | Where-Object { $_ -and [string]$_.Type -eq 'bind' -and [string]$_.Destination -eq '/var/opt/mssql/backup' -and [bool]$_.RW })
        if($mount.Count -ne 1) { return [PSCustomObject]@{Available=$false;Code='SQL_VISIBLE_STAGING_BINDING_UNAVAILABLE';Public=[PSCustomObject]$public} }
        $mountedSource=(Resolve-Path -LiteralPath ([string]$mount[0].Source) -ErrorAction Stop).Path
        if(-not [string]::Equals($hostRoot,$mountedSource,[StringComparison]::OrdinalIgnoreCase)) { return [PSCustomObject]@{Available=$false;Code='SQL_VISIBLE_STAGING_BINDING_UNAVAILABLE';Public=[PSCustomObject]$public} }
        if([string]::IsNullOrWhiteSpace([string]$target.HostName) -or [int]$target.Port -lt 1) { return [PSCustomObject]@{Available=$false;Code='SQL_ENDPOINT_UNAVAILABLE';Public=[PSCustomObject]$public} }
        $public.ContainerId=([string]$container.Id).ToLowerInvariant();$public.BindingStatus='VERIFIED'
        return [PSCustomObject]@{Available=$true;Code=$null;Public=[PSCustomObject]$public;HostRoot=$hostRoot;HostName=[string]$target.HostName;Port=[int]$target.Port}
    } catch { return [PSCustomObject]@{Available=$false;Code='SQL_VISIBLE_STAGING_BINDING_UNAVAILABLE';Public=[PSCustomObject]$public} }
}

function Write-LabPortableContainerTransferPreflightJournal {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Journal,[Parameter(Mandatory)][string]$Path)
    $Journal.UpdatedAt=Get-LabTimestamp
    $schema=Join-Path $script:SchemasPath 'portable-container-transfer-preflight-journal.schema.json'
    if(-not ($Journal|ConvertTo-Json -Depth 20|Test-Json -SchemaFile $schema -ErrorAction Stop)) { throw 'PORTABLE_CONTAINER_TRANSFER_PREFLIGHT_JOURNAL_INVALID' }
    Write-LabArtifactJsonAtomic -Path $Path -InputObject $Journal
}

function New-LabPortableContainerTransferPreflightSqlConnection {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Binding,[Parameter(Mandatory)][SecureString]$Secret)

    if(-not $Secret.IsReadOnly()) { $Secret.MakeReadOnly() }
    $credential=[System.Data.SqlClient.SqlCredential]::new('sa',$Secret)
    $connection=[System.Data.SqlClient.SqlConnection]::new()
    $connection.ConnectionString="Data Source=$($Binding.HostName),$($Binding.Port);Initial Catalog=master;Encrypt=True;TrustServerCertificate=True;Connect Timeout=15;Application Name=SqlServerLab.PortableContainerTransferPreflight"
    $connection.Credential=$credential
    return $connection
}

function Test-LabPortableContainerTransferPreflightSqlConnection {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Binding,[Parameter(Mandatory)][SecureString]$Secret)

    $connection=New-LabPortableContainerTransferPreflightSqlConnection -Binding $Binding -Secret $Secret
    try { $connection.Open() } finally { $connection.Dispose() }
}

function Invoke-LabPortableContainerTransferPreflightSql {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Binding,[Parameter(Mandatory)][SecureString]$Secret,[Parameter(Mandatory)][string]$SqlBackupPath)

    $connection=New-LabPortableContainerTransferPreflightSqlConnection -Binding $Binding -Secret $Secret
    try {
        $connection.Open()
        $header=$connection.CreateCommand();$header.CommandText='RESTORE HEADERONLY FROM DISK = @backupPath;';$header.CommandTimeout=120
        $null=$header.Parameters.Add('@backupPath',[Data.SqlDbType]::NVarChar,4000);$header.Parameters['@backupPath'].Value=$SqlBackupPath
        try {$reader=$header.ExecuteReader();try { if(-not $reader.Read()){throw 'SQL_MEDIA_HEADERONLY_EMPTY'} } finally {$reader.Dispose()} } finally {$header.Dispose()}
        $verify=$connection.CreateCommand();$verify.CommandText='RESTORE VERIFYONLY FROM DISK = @backupPath WITH CHECKSUM, STOP_ON_ERROR;';$verify.CommandTimeout=120
        $null=$verify.Parameters.Add('@backupPath',[Data.SqlDbType]::NVarChar,4000);$verify.Parameters['@backupPath'].Value=$SqlBackupPath
        try {$null=$verify.ExecuteNonQuery()} finally {$verify.Dispose()}
    } finally { $connection.Dispose() }
}

function New-LabPortableContainerTransferPreflightResult {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Request,[Parameter(Mandatory)]$Target,[Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Transfers,[Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Blockers,[Parameter(Mandatory)][string]$Status,[Parameter(Mandatory)][string]$CleanupStatus)
    [PSCustomObject][ordered]@{
        ContractVersion='SqlServerLab.PortableContainerTransferPreflightResult/1.0'
        OperationId=[string]$Request.OperationId
        SelectionDigest=[string]$Request.SelectionDigest
        Status=$Status
        TransferExecutionImplemented=$false
        TransferExecutorStatus='BLOCKED'
        Target=$Target
        Transfers=$Transfers
        Blockers=@($Blockers|Sort-Object -Unique)
        CleanupStatus=$CleanupStatus
        CompletedAt=Get-LabTimestamp
    }
}

function Invoke-LabPortableContainerTransferPreflight {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Request,[Parameter(Mandatory)][string]$DataRoot,[string]$StateRoot)

    $backupPreflight=Get-LabPortableContainerTransferPreflightBackups -Request $Request -DataRoot $DataRoot
    $target=Get-LabPortableContainerTransferPreflightTargetBinding -Request $Request -StateRoot $StateRoot
    $transfers=@($backupPreflight.Records|ForEach-Object {$_.Public})
    $blockers=[Collections.Generic.List[string]]::new();foreach($code in @($backupPreflight.Blockers)){[void]$blockers.Add($code)};if(-not $target.Available){[void]$blockers.Add([string]$target.Code)}
    $targetSecret=$null
    if($blockers.Count -eq 0) {
        try { $targetSecret=Get-LabRelationalCoreSecret -RunId ([string]$Request.TargetRunId) -StateRoot $StateRoot;Test-LabPortableContainerTransferPreflightSqlConnection -Binding $target -Secret $targetSecret }
        catch { [void]$blockers.Add('SQL_MEDIA_PREFLIGHT_MANAGED_SECRET_OR_CONNECTION_UNAVAILABLE') }
    }
    if($blockers.Count -gt 0) { return New-LabPortableContainerTransferPreflightResult -Request $Request -Target $target.Public -Transfers $transfers -Blockers @($blockers) -Status 'BLOCKED' -CleanupStatus 'NO_MUTATION_PERFORMED' }

    $operationDirectory=Join-Path $target.HostRoot "transfer-preflight-$($Request.OperationId)";$journalPath=Join-Path $operationDirectory 'private.journal.json';$journal=$null;$cleanupStatus='NOT_STARTED';$runtimeFailure=$null
    try {
        if(Test-Path -LiteralPath $operationDirectory) { throw 'SQL_MEDIA_PREFLIGHT_OPERATION_DIRECTORY_COLLISION' }
        New-Item -ItemType Directory -Path $operationDirectory -ErrorAction Stop|Out-Null
        $journal=[PSCustomObject][ordered]@{ContractVersion='SqlServerLab.PortableContainerTransferPreflightJournal/1.0';OperationId=[string]$Request.OperationId;SelectionDigest=[string]$Request.SelectionDigest;Status='STAGING';StagingDirectory=$operationDirectory;Transfers=@($transfers);UpdatedAt=Get-LabTimestamp}
        Write-LabPortableContainerTransferPreflightJournal -Journal $journal -Path $journalPath
        foreach($record in @($backupPreflight.Records)) {
            $stagePath=Join-Path $operationDirectory $record.StageFileName
            Copy-Item -LiteralPath $record.SourcePath -Destination $stagePath -ErrorAction Stop
            $stageItem=Get-Item -LiteralPath $stagePath -ErrorAction Stop;$stageHash=(Get-LabProgressFileHash -LiteralPath $stagePath -Algorithm SHA256).Hash.ToLowerInvariant()
            if($stageItem.Length -ne [long]$record.Public.Bytes -or $stageHash -ne [string]$record.Public.Sha256) { throw 'SQL_MEDIA_PREFLIGHT_STAGING_HASH_OR_SIZE_MISMATCH' }
        }
        $journal.Status='SQL_MEDIA_PRECHECK';Write-LabPortableContainerTransferPreflightJournal -Journal $journal -Path $journalPath
        foreach($transfer in $transfers) {
            $sqlPath="/var/opt/mssql/backup/transfer-preflight-$($Request.OperationId)/$($transfer.BackupSetId).bak"
            Invoke-LabPortableContainerTransferPreflightSql -Binding $target -Secret $targetSecret -SqlBackupPath $sqlPath
            $transfer.HeaderOnly='PASSED';$transfer.VerifyOnly='PASSED';$journal.Transfers=@($transfers);Write-LabPortableContainerTransferPreflightJournal -Journal $journal -Path $journalPath
        }
        $journal.Status='PRECHECKED';Write-LabPortableContainerTransferPreflightJournal -Journal $journal -Path $journalPath
    } catch { $runtimeFailure='SQL_MEDIA_PREFLIGHT_FAILED';if($journal){$journal.Status='RECOVERY_REQUIRED';try{Write-LabPortableContainerTransferPreflightJournal -Journal $journal -Path $journalPath}catch{}} }
    finally {
        if(Test-Path -LiteralPath $operationDirectory) {
            try { Remove-Item -LiteralPath $operationDirectory -Recurse -Force -ErrorAction Stop;$cleanupStatus='CLEANED' }
            catch { $cleanupStatus='RECOVERY_REQUIRED';$runtimeFailure='SQL_MEDIA_PREFLIGHT_CLEANUP_REQUIRED' }
        } else { $cleanupStatus='CLEANED' }
    }
    if($runtimeFailure) {[void]$blockers.Add($runtimeFailure)}
    $status=if($cleanupStatus -eq 'RECOVERY_REQUIRED'){'RECOVERY_REQUIRED'}elseif($runtimeFailure){'BLOCKED'}else{'PRECHECKED'}
    return New-LabPortableContainerTransferPreflightResult -Request $Request -Target $target.Public -Transfers $transfers -Blockers @($blockers) -Status $status -CleanupStatus $cleanupStatus
}
