function Read-PitrSqlResults {
    param([Parameter(Mandatory)]$Reader)
    $values=[Collections.Generic.List[string]]::new()
    do {
        while ($Reader.Read()) {
            if ($Reader.FieldCount -gt 0 -and -not $Reader.IsDBNull(0)) { $values.Add([string]$Reader.GetValue(0)) }
        }
    } while ($Reader.NextResult())
    return $values.ToArray()
}

function Invoke-PitrSql {
    param([Parameter(Mandatory)]$Binding,[string]$OperationId,[string]$StateRoot,[string]$Query)
    $connection=$null; $command=$null; $reader=$null; $secret=$null
    try {
        $actual=Assert-LabTransferBinding -Expected $Binding -StateRoot $StateRoot -OperationId $OperationId
        $connection=New-LabTransferConnection -Binding $actual -OperationId $OperationId -StateRoot $StateRoot
        $secret=$connection.Credential.Password
        $connection.Open()
        $command=$connection.CreateCommand(); $command.CommandTimeout=45; $command.CommandText=$Query
        $reader=$command.ExecuteReader()
        Read-PitrSqlResults -Reader $reader
    }
    catch { throw 'PITR_SQL_FAILED' }
    finally {
        if ($reader) { $reader.Dispose() }; if ($command) { $command.Dispose() }
        if ($connection) { $connection.Dispose() }; if ($secret) { $secret.Dispose() }
    }
}

function Assert-PitrCutoff {
    param([string]$Value)
    $parsed=[datetime]::MinValue
    if ($Value -cnotmatch '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}$' -or
        -not [datetime]::TryParseExact($Value,'yyyy-MM-dd HH:mm:ss.fff',[Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::None,[ref]$parsed)) { throw 'PITR_CUTOFF_INVALID' }
}

function Invoke-PitrRecovery {
    param([Parameter(Mandatory)]$Binding,[string]$OperationId,[string]$StateRoot)
    if ($OperationId -cnotmatch '^[a-f0-9]{32}$') { throw 'PITR_OPERATION_INVALID' }
    $source='PitrSource_'+$OperationId; $target='PitrTarget_'+$OperationId
    $directory='/var/opt/mssql/backup/pitr-'+$OperationId
    $parameters=@{Binding=$Binding;OperationId=$OperationId;StateRoot=$StateRoot}
    $actual=Assert-LabTransferBinding -Expected $Binding -StateRoot $StateRoot -OperationId $OperationId
    $null=Invoke-LabTransferNative -Provider $actual.Provider -Arguments @('exec',$actual.ContainerId,'mkdir','-p',$directory) -TimeoutSeconds 30
    $major=@(Invoke-PitrSql @parameters -Query "SELECT CONVERT(int,SERVERPROPERTY('ProductMajorVersion'));")
    if ($major.Count -ne 1 -or $major[0] -cne '17') { throw 'PITR_SQL_VERSION_INVALID' }
    $null=Invoke-PitrSql @parameters -Query "CREATE DATABASE [$source];"
    $null=Invoke-PitrSql @parameters -Query "ALTER DATABASE [$source] SET RECOVERY FULL;"
    $null=Invoke-PitrSql @parameters -Query "USE [$source]; CREATE TABLE dbo.RecoveryRows(Id int NOT NULL PRIMARY KEY, Marker nvarchar(40) NOT NULL);"
    $null=Invoke-PitrSql @parameters -Query "BACKUP DATABASE [$source] TO DISK=N'$directory/full.bak' WITH INIT,CHECKSUM;"
    $null=Invoke-PitrSql @parameters -Query "USE [$source]; INSERT dbo.RecoveryRows VALUES(1,N'good-marker');"
    # STOPAT takes datetime in server local time. Delay before capture avoids
    # datetime rounding preceding the good commit; delay afterward separates the bad commit.
    $cutoff=@(Invoke-PitrSql @parameters -Query "WAITFOR DELAY '00:00:00.050'; SELECT CONVERT(varchar(23),CONVERT(datetime,SYSDATETIME()),121);")
    if ($cutoff.Count -ne 1) { throw 'PITR_CUTOFF_INVALID' }
    Assert-PitrCutoff $cutoff[0]
    $null=Invoke-PitrSql @parameters -Query "WAITFOR DELAY '00:00:00.050';"
    $null=Invoke-PitrSql @parameters -Query "USE [$source]; INSERT dbo.RecoveryRows VALUES(2,N'bad-mutation');"
    $sourceQuery="SELECT CONCAT(Id,N':',Marker) FROM [$source].dbo.RecoveryRows ORDER BY Id;"
    $sourceRows=@(Invoke-PitrSql @parameters -Query $sourceQuery)
    if (($sourceRows -join '|') -cne '1:good-marker|2:bad-mutation') { throw 'PITR_SOURCE_CONTENT_INVALID' }
    # The bad committed row must be present in this log backup, not excluded by backup order.
    $null=Invoke-PitrSql @parameters -Query "BACKUP LOG [$source] TO DISK=N'$directory/chain.trn' WITH INIT,CHECKSUM;"
    $clock=[Diagnostics.Stopwatch]::StartNew()
    try {
        $null=Invoke-PitrSql @parameters -Query "RESTORE DATABASE [$target] FROM DISK=N'$directory/full.bak' WITH MOVE N'$source' TO N'/var/opt/mssql/data/$target.mdf', MOVE N'${source}_log' TO N'/var/opt/mssql/data/${target}_log.ldf', NORECOVERY,CHECKSUM;"
        $null=Invoke-PitrSql @parameters -Query "DECLARE @cutoff datetime=CONVERT(datetime,N'$($cutoff[0])',121); RESTORE LOG [$target] FROM DISK=N'$directory/chain.trn' WITH STOPAT=@cutoff,RECOVERY,CHECKSUM;"
    }
    finally { $clock.Stop() }
    $after=@(Invoke-PitrSql @parameters -Query $sourceQuery)
    if (($after -join '|') -cne ($sourceRows -join '|')) { throw 'PITR_SOURCE_CHANGED' }
    $online=@(Invoke-PitrSql @parameters -Query "SELECT state_desc FROM sys.databases WHERE name=N'$target';")
    $rows=@(Invoke-PitrSql @parameters -Query "SELECT CONCAT(Id,N':',Marker) FROM [$target].dbo.RecoveryRows ORDER BY Id;")
    if ($online.Count -ne 1 -or $online[0] -cne 'ONLINE') { throw 'PITR_TARGET_NOT_ONLINE' }
    if (($rows -join '|') -cne '1:good-marker') { throw 'PITR_TARGET_CONTENT_INVALID' }
    $integrity=@(Invoke-PitrSql @parameters -Query "DBCC CHECKDB(N'$target') WITH NO_INFOMSGS,ALL_ERRORMSGS;")
    if ($integrity.Count -ne 0) { throw 'PITR_INTEGRITY_FAILED' }
    [pscustomobject]@{Status='VERIFIED';RecoveryMilliseconds=$clock.Elapsed.TotalMilliseconds;SqlMajor=17}
}

function Invoke-PitrArrange {
    param([string]$Provider,[string]$OperationId,[string]$StateRoot,[string]$EvidenceRoot)
    $scope=Get-LabContainerRuntimeScope -Provider $Provider
    if ($scope.Status -cne 'AVAILABLE' -or $scope.RuntimeId -cnotmatch '^runtime-scope-[a-f0-9]{24}$') { throw 'PITR_RUNTIME_UNAVAILABLE' }
    $intent=@{OperationId=$OperationId;Provider=$Provider;RuntimeScopeId=$scope.RuntimeId}
    $intent | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $EvidenceRoot 'intent.json')
    $lab=Invoke-WithLabWorkflowOperationContext -OperationId $OperationId -ScriptBlock {
        param($Provider,$StateRoot)
        New-SqlServerLab -Version 2025 -Provider $Provider -Profile compact -Cpu 1 -MemoryMB 2560 `
            -LabName 'pitr-acceptance' -StateRoot $StateRoot -GenerateSaPassword -NonInteractive -SkipAssessment `
            -Drives @([pscustomobject]@{id='pitr-data';containerPath='/var/opt/mssql'})
    } -ArgumentList @($Provider,$StateRoot)
    if ($lab.State -ine 'RUNNING' -or @($lab.Instances).Count -ne 1) { throw 'PITR_NEW_FAILED' }
    $binding=Get-LabTransferBinding -RunId $lab.RunId -InstanceId primary -StateRoot $StateRoot -OperationId $OperationId
    if ($binding.Provider -cne $Provider -or $binding.RuntimeScopeId -cne $scope.RuntimeId) { throw 'PITR_RUNTIME_CHANGED' }
    $identity=Get-LabTransferBindingIdentity $binding
    $identity | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $EvidenceRoot 'binding.json')
    Invoke-PitrRecovery -Binding $identity -OperationId $OperationId -StateRoot $StateRoot
}

function Remove-PitrOwnRun {
    param([string]$Provider,[string]$OperationId,[string]$StateRoot,[string]$EvidenceRoot)
    $owned=Get-LabOperationOwnedRun -OperationId $OperationId -StateRoot $StateRoot
    $intentPath=Join-Path $EvidenceRoot 'intent.json'
    if (-not (Test-Path -LiteralPath $intentPath)) {
        if ($owned) { throw 'PITR_CLEANUP_INTENT_MISSING' }
        return
    }
    $intent=Get-Content -LiteralPath $intentPath -Raw | ConvertFrom-Json
    $scope=Get-LabContainerRuntimeScope -Provider $Provider
    if ($intent.OperationId -cne $OperationId -or $intent.Provider -cne $Provider -or
        $scope.Status -cne 'AVAILABLE' -or $scope.RuntimeId -cne $intent.RuntimeScopeId) { throw 'PITR_CLEANUP_BINDING_CHANGED' }
    $bindingPath=Join-Path $EvidenceRoot 'binding.json'
    $binding=if (Test-Path -LiteralPath $bindingPath) { Get-Content -LiteralPath $bindingPath -Raw | ConvertFrom-Json } else { $null }
    if ($owned) {
        if ($owned.metadata.workflowOperationId -cne $OperationId -or $owned.metadata.persistentData -or
            ($binding -and ($binding.RunId -cne $owned.runId -or $binding.ScopeId -cne $owned.scopeId))) {
            throw 'PITR_CLEANUP_OWNERSHIP_INVALID'
        }
        $subRuns=@(Get-LabProviderSubRuns -RunId $owned.runId -StateRoot $StateRoot)
        if ($subRuns.Count -ne 1 -or $subRuns[0].provider -cne $Provider) { throw 'PITR_CLEANUP_PROVIDER_INVALID' }
        $removed=Remove-SqlServerLab -RunId $owned.runId -StateRoot $StateRoot -Force -Confirm:$false
        if ($removed.Status -cne 'REMOVED' -or $removed.Cleanup -cne 'CLEANUP_SUCCEEDED' -or $removed.Errors) { throw 'PITR_CLEANUP_FAILED' }
        foreach ($kind in @('containers','volumes')) {
            $arguments=if ($kind -ceq 'containers') { @('ps','-a','--filter',"label=sql-server-lab.run-id=$($owned.runId)",'--format','{{.ID}}') }
                else { @('volume','ls','--filter',"label=sql-server-lab.run-id=$($owned.runId)",'--format','{{.Name}}') }
            if (@(Invoke-LabTransferNative -Provider $Provider -Arguments $arguments).Count) { throw 'PITR_CLEANUP_RESIDUE' }
        }
    }
    if ($binding) { Assert-LabTransferNoResidue -Binding $binding }
}
