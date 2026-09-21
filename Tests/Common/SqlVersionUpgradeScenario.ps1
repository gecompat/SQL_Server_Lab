# Fixed own-run SQL 2022 -> 2025 reference; no public migration API.
function Get-SqlUpgradeBinding {
    param([string]$RunId,[string]$OperationId,[ValidateSet('2022','2025')][string]$Version,[string]$StateRoot)
    $run=Get-LabRunState -RunId $RunId -StateRoot $StateRoot
    $instance=Resolve-LabRunInstance -RunId $RunId -InstanceId primary -StateRoot $StateRoot
    $catalog=Get-SqlServerVersion -VersionId $instance.Version
    if ($run.state -cne 'RUNNING' -or $run.metadata.workflowOperationId -cne $OperationId -or
        $run.metadata.persistentData -or $catalog.id -cne $Version -or $instance.Provider -cnotin @('docker','podman')) {
        throw 'SQL_UPGRADE_RUN_BINDING_INVALID'
    }
    $scope=Get-LabContainerRuntimeScope -Provider $instance.Provider
    if ($scope.Status -cne 'AVAILABLE' -or $scope.RuntimeId -cnotmatch '^runtime-scope-[a-f0-9]{24}$') { throw 'SQL_UPGRADE_RUNTIME_UNAVAILABLE' }
    $inspection=@((Invoke-LabTransferNative -Provider $instance.Provider -Arguments @('inspect',$instance.ContainerName)) -join "`n" | ConvertFrom-Json -Depth 30)
    if ($inspection.Count -ne 1) { throw 'SQL_UPGRADE_CONTAINER_AMBIGUOUS' }
    $container=$inspection[0]; $labels=$container.Config.Labels
    if ($container.State.Running -ne $true -or $container.Id -cnotmatch '^[a-f0-9]{64}$' -or
        ($container.Os -and $container.Os -cne 'linux') -or $labels.'sql-server-lab.run-id' -cne $RunId -or
        $labels.'sql-server-lab.scope-id' -cne $run.scopeId -or $labels.'sql-server-lab.instance-id' -cne 'primary') {
        throw 'SQL_UPGRADE_CONTAINER_OWNERSHIP_INVALID'
    }
    $ports=@($container.NetworkSettings.Ports.'1433/tcp')
    if ($ports.Count -ne 1 -or [int]$ports[0].HostPort -ne [int]$instance.Port -or
        $ports[0].HostIp -cnotin @('127.0.0.1','::1') -or $instance.HostName -cne $ports[0].HostIp) { throw 'SQL_UPGRADE_ENDPOINT_INVALID' }
    $mounts=@($container.Mounts)
    if ($mounts.Count -ne 1 -or $mounts[0].Type -cne 'volume' -or $mounts[0].Destination -cne '/var/opt/mssql' -or $mounts[0].RW -ne $true) {
        throw 'SQL_UPGRADE_VOLUME_INVALID'
    }
    $volumes=@((Invoke-LabTransferNative -Provider $instance.Provider -Arguments @('volume','inspect',$mounts[0].Name)) -join "`n" | ConvertFrom-Json -Depth 30)
    if ($volumes.Count -ne 1) { throw 'SQL_UPGRADE_VOLUME_INVALID' }
    $vl=$volumes[0].Labels
    if ($vl.'sql-server-lab.run-id' -cne $RunId -or $vl.'sql-server-lab.scope-id' -cne $run.scopeId -or
        $vl.'sql-server-lab.instance-id' -cne 'primary' -or $vl.'sql-server-lab.persistent-storage-id' -or $vl.'sql-server-lab.persistence') {
        throw 'SQL_UPGRADE_VOLUME_OWNERSHIP_INVALID'
    }
    $attachments=@(Invoke-LabTransferNative -Provider $instance.Provider -Arguments @('ps','-a','--no-trunc','--filter',"volume=$($mounts[0].Name)",'--format','{{.ID}}'))
    if ($attachments.Count -ne 1 -or $attachments[0] -cne $container.Id) { throw 'SQL_UPGRADE_VOLUME_SHARED' }
    [pscustomobject][ordered]@{
        RunId=$RunId; ScopeId=$run.scopeId; OperationId=$OperationId; Version=$Version; InstanceId='primary'
        Provider=$instance.Provider; RuntimeScopeId=$scope.RuntimeId; ContainerId=$container.Id
        Volumes=@($mounts[0].Name); HostName=$instance.HostName; Port=[int]$instance.Port
    }
}

function Assert-SqlUpgradeBinding {
    param($Expected,[string]$StateRoot)
    $actual=Get-SqlUpgradeBinding -RunId $Expected.RunId -OperationId $Expected.OperationId -Version $Expected.Version -StateRoot $StateRoot
    if ((Get-LabTransferHash $actual) -cne (Get-LabTransferHash $Expected)) { throw 'SQL_UPGRADE_LIVE_BINDING_CHANGED' }
    return $actual
}

function Invoke-SqlUpgradeQuery {
    param($Binding,[string]$StateRoot,[string]$Query)
    $secret=$null; $connection=$null; $command=$null; $reader=$null
    try {
        $actual=Assert-SqlUpgradeBinding -Expected $Binding -StateRoot $StateRoot
        $secret=Get-LabRelationalCoreSecret -RunId $actual.RunId -StateRoot $StateRoot
        $connection=New-LabRelationalCoreConnection -Binding $actual -DatabaseName master -Secret $secret
        $connection.Open(); $command=$connection.CreateCommand(); $command.CommandText=$Query; $command.CommandTimeout=45
        $reader=$command.ExecuteReader(); $values=[Collections.Generic.List[string]]::new()
        do { while ($reader.Read()) { if ($reader.FieldCount -gt 0 -and -not $reader.IsDBNull(0)) { $values.Add([string]$reader.GetValue(0)) } } } while ($reader.NextResult())
        return $values.ToArray()
    }
    catch { throw 'SQL_UPGRADE_QUERY_FAILED' }
    finally {
        if ($reader) { $reader.Dispose() }; if ($command) { $command.Dispose() }
        if ($connection) { $connection.Dispose() }; if ($secret) { $secret.Dispose() }
    }
}

function Assert-SqlUpgradeDatabase {
    param($Binding,[string]$StateRoot,[string]$Database,[int]$Major,[int]$Compatibility)
    $query="SELECT CONCAT(CONVERT(int,SERVERPROPERTY('ProductMajorVersion')),N'|',compatibility_level,N'|',state_desc,N'|',is_encrypted) FROM sys.databases WHERE name=N'$Database';"
    $result=@(Invoke-SqlUpgradeQuery -Binding $Binding -StateRoot $StateRoot -Query $query)
    if ($result.Count -ne 1 -or $result[0] -cne "$Major|$Compatibility|ONLINE|0") { throw 'SQL_UPGRADE_DATABASE_STATE_INVALID' }
}

function Test-SqlUpgradeWorkload {
    param($Binding,[string]$StateRoot,[string]$Database,[int]$Major,[int]$Compatibility)
    $clock=[Diagnostics.Stopwatch]::StartNew()
    $parameters=@{Binding=$Binding;StateRoot=$StateRoot}
    Assert-SqlUpgradeDatabase @parameters -Database $Database -Major $Major -Compatibility $Compatibility
    $rowsQuery="SELECT CONCAT(Id,N'|',GroupId,N'|',Name,N'|',CONVERT(varchar(32),Balance)) FROM [$Database].dbo.Accounts ORDER BY Id;"
    $rows=@(Invoke-SqlUpgradeQuery @parameters -Query $rowsQuery)
    if (($rows -join ';') -cne '1|1|one|10.25;2|1|two|20.75;3|2|three|5.00') { throw 'SQL_UPGRADE_ROWS_DIFFER' }
    $groups=@(Invoke-SqlUpgradeQuery @parameters -Query "SELECT CONCAT(Id,N'|',Label) FROM [$Database].dbo.Groups ORDER BY Id;")
    if (($groups -join ';') -cne '1|alpha;2|beta') { throw 'SQL_UPGRADE_GROUPS_DIFFER' }
    $aggregate=@(Invoke-SqlUpgradeQuery @parameters -Query "SELECT CONCAT(g.Id,N'|',COUNT_BIG(*),N'|',CONVERT(varchar(32),SUM(a.Balance))) FROM [$Database].dbo.Accounts a JOIN [$Database].dbo.Groups g ON g.Id=a.GroupId GROUP BY g.Id ORDER BY g.Id;")
    if (($aggregate -join ';') -cne '1|2|31.00;2|1|5.00') { throw 'SQL_UPGRADE_AGGREGATE_DIFFER' }
    $transaction=@"
USE [$Database]; SET NOCOUNT ON; SET XACT_ABORT OFF;
BEGIN TRY
  BEGIN TRANSACTION;
  UPDATE dbo.Accounts SET Balance=Balance+7 WHERE Id=1;
  IF NOT EXISTS(SELECT 1 FROM dbo.Accounts WHERE Id=1 AND Balance=17.25) THROW 51000,'SYNTHETIC_TRANSACTION_FAILED',1;
  ROLLBACK TRANSACTION;
END TRY BEGIN CATCH
  IF @@TRANCOUNT>0 ROLLBACK TRANSACTION;
  THROW;
END CATCH;
DECLARE @check bit=0,@fk bit=0,@pk bit=0;
BEGIN TRY UPDATE dbo.Accounts SET Balance=-1 WHERE Id=2; END TRY
BEGIN CATCH IF ERROR_NUMBER()=547 SET @check=1; ELSE THROW; END CATCH;
BEGIN TRY INSERT dbo.Accounts VALUES(4,999,N'four',1.00); END TRY
BEGIN CATCH IF ERROR_NUMBER()=547 SET @fk=1; ELSE THROW; END CATCH;
BEGIN TRY INSERT dbo.Accounts VALUES(1,1,N'duplicate',1.00); END TRY
BEGIN CATCH IF ERROR_NUMBER()=2627 SET @pk=1; ELSE THROW; END CATCH;
IF @check<>1 OR @fk<>1 OR @pk<>1 THROW 51001,'SYNTHETIC_CONSTRAINT_FAILED',1;
SELECT N'TRANSACTION_AND_CONSTRAINTS_VERIFIED';
"@
    $result=@(Invoke-SqlUpgradeQuery @parameters -Query $transaction)
    if ($result.Count -ne 1 -or $result[0] -cne 'TRANSACTION_AND_CONSTRAINTS_VERIFIED') { throw 'SQL_UPGRADE_TRANSACTION_FAILED' }
    $after=@(Invoke-SqlUpgradeQuery @parameters -Query $rowsQuery)
    if (($after -join ';') -cne ($rows -join ';')) { throw 'SQL_UPGRADE_ROLLBACK_DIFFER' }
    if (@(Invoke-SqlUpgradeQuery @parameters -Query "DBCC CHECKDB(N'$Database') WITH NO_INFOMSGS,ALL_ERRORMSGS;").Count) { throw 'SQL_UPGRADE_INTEGRITY_FAILED' }
    $clock.Stop()
    [pscustomobject]@{Status='VERIFIED';Compatibility=$Compatibility;ObservedMilliseconds=$clock.Elapsed.TotalMilliseconds}
}

function New-SqlUpgradeOwnRun {
    param([string]$Provider,[string]$OperationId,[ValidateSet('source','target')][string]$Role,[string]$StateRoot,[string]$EvidenceRoot,$Intent)
    $version=if ($Role -ceq 'source') { '2022' } else { '2025' }
    $scope=Get-LabContainerRuntimeScope -Provider $Provider
    if ($scope.Status -cne 'AVAILABLE' -or $scope.RuntimeId -cne $Intent.RuntimeScopeId) { throw 'SQL_UPGRADE_RUNTIME_CHANGED' }
    $roleOperation=$OperationId+'-'+$Role
    $lab=Invoke-WithLabWorkflowOperationContext -OperationId $roleOperation -ScriptBlock {
        param($Provider,$StateRoot,$Version,$Role)
        # Exercise the public backup path with an option-like generated value.
        $secret=[Security.SecureString]::new()
        foreach ($character in ('-'+[guid]::NewGuid().ToString('N')+'aA1!').ToCharArray()) {
            $secret.AppendChar($character)
        }
        $secret.MakeReadOnly()
        try {
            New-SqlServerLab -Version $Version -Provider $Provider -Profile compact -Cpu 1 -MemoryMB 2560 `
                -LabName ('upgrade-'+$Role) -StateRoot $StateRoot -SaPassword $secret -NonInteractive -SkipAssessment `
                -Drives @([pscustomobject]@{id='upgrade-data';containerPath='/var/opt/mssql'})
        }
        finally { $secret.Dispose() }
    } -ArgumentList @($Provider,$StateRoot,$version,$Role)
    if ($lab.State -ine 'RUNNING' -or @($lab.Instances).Count -ne 1) { throw 'SQL_UPGRADE_NEW_FAILED' }
    $binding=Get-SqlUpgradeBinding -RunId $lab.RunId -OperationId $roleOperation -Version $version -StateRoot $StateRoot
    if ($binding.Provider -cne $Provider -or $binding.RuntimeScopeId -cne $Intent.RuntimeScopeId) { throw 'SQL_UPGRADE_RUNTIME_CHANGED' }
    Write-LabArtifactJsonAtomic -Path (Join-Path $EvidenceRoot ($Role+'-binding.json')) -InputObject $binding
    return $binding
}

function Invoke-SqlUpgradeArrange {
    param([string]$Provider,[string]$OperationId,[string]$StateRoot,[string]$EvidenceRoot)
    $scope=Get-LabContainerRuntimeScope -Provider $Provider
    if ($scope.Status -cne 'AVAILABLE' -or $scope.RuntimeId -cnotmatch '^runtime-scope-[a-f0-9]{24}$') { throw 'SQL_UPGRADE_RUNTIME_UNAVAILABLE' }
    $intent=@{OperationId=$OperationId;Provider=$Provider;RuntimeScopeId=$scope.RuntimeId;SourceOperationId=($OperationId+'-source');TargetOperationId=($OperationId+'-target')}
    Write-LabArtifactJsonAtomic -Path (Join-Path $EvidenceRoot 'intent.json') -InputObject $intent
    $dataRoot=Join-Path $EvidenceRoot 'Lab_Data'
    $null=Initialize-LabManagedDataRoot -DataRoot $dataRoot -ControllerId ([guid]::NewGuid().ToString('D')) -Confirm:$false
    $parameters=@{Provider=$Provider;OperationId=$OperationId;StateRoot=$StateRoot;EvidenceRoot=$EvidenceRoot;Intent=$intent}
    $source=New-SqlUpgradeOwnRun @parameters -Role source
    $sourceDb='UpgradeSource_'+$OperationId; $targetDb='UpgradeTarget_'+$OperationId
    $null=Invoke-SqlUpgradeQuery -Binding $source -StateRoot $StateRoot -Query "CREATE DATABASE [$sourceDb]; ALTER DATABASE [$sourceDb] SET COMPATIBILITY_LEVEL=160;"
    $null=Invoke-SqlUpgradeQuery -Binding $source -StateRoot $StateRoot -Query @"
USE [$sourceDb];
CREATE TABLE dbo.Groups(Id int NOT NULL PRIMARY KEY,Label nvarchar(16) NOT NULL UNIQUE);
CREATE TABLE dbo.Accounts(Id int NOT NULL PRIMARY KEY,GroupId int NOT NULL REFERENCES dbo.Groups(Id),Name nvarchar(16) NOT NULL UNIQUE,Balance decimal(12,2) NOT NULL CHECK(Balance>=0));
INSERT dbo.Groups VALUES(1,N'alpha'),(2,N'beta');
INSERT dbo.Accounts VALUES(1,1,N'one',10.25),(2,1,N'two',20.75),(3,2,N'three',5.00);
"@
    $sourceEvidence=Test-SqlUpgradeWorkload -Binding $source -StateRoot $StateRoot -Database $sourceDb -Major 16 -Compatibility 160
    $secret=$null
    try {
        $null=Assert-SqlUpgradeBinding -Expected $source -StateRoot $StateRoot
        $secret=Get-LabRelationalCoreSecret -RunId $source.RunId -StateRoot $StateRoot
        $backup=Backup-SqlServerLabDatabase -RunId $source.RunId -InstanceId primary -DatabaseName $sourceDb -SaPassword $secret -DataRoot $dataRoot -StateRoot $StateRoot -Confirm:$false
    }
    finally { if ($secret) { $secret.Dispose() }; $secret=$null }
    if ($backup.Status -cne 'BACKUP_REUSABLE') { throw 'SQL_UPGRADE_BACKUP_FAILED' }
    $selection=Get-LabDatabaseBackup -BackupSetId $backup.BackupSetId -DataRoot $dataRoot
    $record=$selection.Record
    if ($record.Status -cne 'REUSABLE' -or $record.Source.RunId -cne $source.RunId -or
        $record.Source.Provider -cne $Provider -or $record.Source.InstanceId -cne 'primary' -or $record.Source.SqlMajorVersion -cne '16' -or
        $record.DatabaseName -cne $sourceDb -or $record.DatabaseMetadata.HasFileStream -ne $false -or $record.DatabaseMetadata.IsEncrypted -ne $false -or
        $record.Verification.BackupChecksum -ne $true -or $record.Verification.RestoreVerifyOnly -ne $true -or
        $record.Artifact.Sha256 -cnotmatch '^[a-f0-9]{64}$' -or $record.Artifact.Sha256 -cne $backup.Sha256) { throw 'SQL_UPGRADE_BACKUP_EVIDENCE_INVALID' }
    $target=New-SqlUpgradeOwnRun @parameters -Role target
    if ($target.RunId -ceq $source.RunId -or $target.ContainerId -ceq $source.ContainerId) { throw 'SQL_UPGRADE_TARGET_NOT_NEW' }
    $targetMajor=@(Invoke-SqlUpgradeQuery -Binding $target -StateRoot $StateRoot -Query "SELECT CONVERT(int,SERVERPROPERTY('ProductMajorVersion'));" )
    if ($targetMajor.Count -ne 1 -or $targetMajor[0] -cne '17') { throw 'SQL_UPGRADE_TARGET_VERSION_INVALID' }
    $restoreClock=[Diagnostics.Stopwatch]::StartNew()
    try {
        $null=Assert-SqlUpgradeBinding -Expected $target -StateRoot $StateRoot
        $secret=Get-LabRelationalCoreSecret -RunId $target.RunId -StateRoot $StateRoot
        $restore=Restore-SqlServerLabDatabase -RunId $target.RunId -InstanceId primary -DatabaseName $targetDb -SaPassword $secret `
            -BackupSetId $backup.BackupSetId -DataRoot $dataRoot -StateRoot $StateRoot -Confirm:$false
    }
    finally { $restoreClock.Stop(); if ($secret) { $secret.Dispose() }; $secret=$null }
    if ($restore.Success -ne $true -or $restore.BackupSetId -cne $backup.BackupSetId -or
        $restore.BackupSourceKind -cne 'LIBRARY' -or $restore.Provider -cne $Provider) { throw 'SQL_UPGRADE_RESTORE_FAILED' }
    $retained=Test-SqlUpgradeWorkload -Binding $target -StateRoot $StateRoot -Database $targetDb -Major 17 -Compatibility 160
    $null=Assert-SqlUpgradeDatabase -Binding $source -StateRoot $StateRoot -Database $sourceDb -Major 16 -Compatibility 160
    $null=Invoke-SqlUpgradeQuery -Binding $target -StateRoot $StateRoot -Query "ALTER DATABASE [$targetDb] SET COMPATIBILITY_LEVEL=170;"
    $changed=Test-SqlUpgradeWorkload -Binding $target -StateRoot $StateRoot -Database $targetDb -Major 17 -Compatibility 170
    $sourceAfter=Test-SqlUpgradeWorkload -Binding $source -StateRoot $StateRoot -Database $sourceDb -Major 16 -Compatibility 160
    [pscustomobject]@{
        Status='VERIFIED';SourceMajor=16;TargetMajor=17;PreservedCompatibility=160;ChangedCompatibility=170
        SourceMilliseconds=$sourceEvidence.ObservedMilliseconds;RestoreMilliseconds=$restoreClock.Elapsed.TotalMilliseconds
        Compatibility160Milliseconds=$retained.ObservedMilliseconds;Compatibility170Milliseconds=$changed.ObservedMilliseconds
        SourceAfterMilliseconds=$sourceAfter.ObservedMilliseconds
    }
}

function Remove-SqlUpgradeOwnRuns {
    param([string]$Provider,[string]$OperationId,[string]$StateRoot,[string]$EvidenceRoot)
    $failures=[Collections.Generic.List[string]]::new()
    # Independent attempts: a failed target cleanup must not strand the source.
    foreach ($role in @('target','source')) {
        try {
            $roleOperation=$OperationId+'-'+$role
            $owned=Get-LabOperationOwnedRun -OperationId $roleOperation -StateRoot $StateRoot
            $intentPath=Join-Path $EvidenceRoot 'intent.json'
            if (-not (Test-Path -LiteralPath $intentPath)) {
                if ($owned) { throw 'SQL_UPGRADE_CLEANUP_INTENT_MISSING' }
                continue
            }
            $intent=Get-Content -LiteralPath $intentPath -Raw | ConvertFrom-Json
            $scope=Get-LabContainerRuntimeScope -Provider $Provider
            if ($intent.OperationId -cne $OperationId -or $intent.Provider -cne $Provider -or
                $intent.SourceOperationId -cne ($OperationId+'-source') -or
                $intent.TargetOperationId -cne ($OperationId+'-target') -or
                $scope.Status -cne 'AVAILABLE' -or $scope.RuntimeId -cne $intent.RuntimeScopeId) {
                throw 'SQL_UPGRADE_CLEANUP_BINDING_CHANGED'
            }
            $bindingPath=Join-Path $EvidenceRoot ($role+'-binding.json')
            $binding=if (Test-Path -LiteralPath $bindingPath) { Get-Content -LiteralPath $bindingPath -Raw | ConvertFrom-Json } else { $null }
            if ($binding -and ($binding.Provider -cne $Provider -or $binding.RuntimeScopeId -cne $scope.RuntimeId -or
                $binding.OperationId -cne $roleOperation)) { throw 'SQL_UPGRADE_CLEANUP_BINDING_CHANGED' }
            if ($owned) {
                if ($owned.metadata.workflowOperationId -cne $roleOperation -or $owned.metadata.persistentData -or
                    ($binding -and ($binding.RunId -cne $owned.runId -or $binding.ScopeId -cne $owned.scopeId))) {
                    throw 'SQL_UPGRADE_CLEANUP_OWNERSHIP_INVALID'
                }
                $subRuns=@(Get-LabProviderSubRuns -RunId $owned.runId -StateRoot $StateRoot)
                if ($subRuns.Count -ne 1 -or $subRuns[0].provider -cne $Provider) { throw 'SQL_UPGRADE_CLEANUP_PROVIDER_INVALID' }
                $removed=Remove-SqlServerLab -RunId $owned.runId -StateRoot $StateRoot -Force -Confirm:$false
                if ($removed.Status -cne 'REMOVED' -or $removed.Cleanup -cne 'CLEANUP_SUCCEEDED' -or $removed.Errors) {
                    throw 'SQL_UPGRADE_CLEANUP_FAILED'
                }
                foreach ($kind in @('containers','volumes')) {
                    $arguments=if ($kind -ceq 'containers') {
                        @('ps','-a','--filter',"label=sql-server-lab.run-id=$($owned.runId)",'--format','{{.ID}}')
                    } else { @('volume','ls','--filter',"label=sql-server-lab.run-id=$($owned.runId)",'--format','{{.Name}}') }
                    if (@(Invoke-LabTransferNative -Provider $Provider -Arguments $arguments).Count) { throw 'SQL_UPGRADE_CLEANUP_RESIDUE' }
                }
            }
            if ($binding) { Assert-LabTransferNoResidue -Binding $binding }
        }
        catch { $failures.Add($role) }
    }
    # Preserve both the failed primary result and all local recovery state.
    if ($failures.Count) { throw 'SQL_UPGRADE_CLEANUP_INCOMPLETE' }
}
