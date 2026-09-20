#Requires -Version 7.2
[CmdletBinding()]param()
$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$root=Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-transfer-checks-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $root
$module=Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru
$results=[Collections.Generic.List[object]]::new()
function Check {param([string]$Name,[bool]$Passed)$results.Add([pscustomobject]@{Name=$Name;Passed=$Passed});Write-Host "$(if($Passed){'PASS'}else{'FAIL'}): $Name"}
try {
    $checks=& $module {
        param($Root)
        $script:TransferRealBinding=${function:Get-LabTransferBinding}
        $script:TransferRealWrite=${function:Write-LabTransferJournal}
        $script:TransferRealComparison=${function:Invoke-LabRelationalCoreComparison}
        $script:TransferRealConnection=${function:New-LabTransferConnection}
        $script:TransferChecks=[Collections.Generic.List[object]]::new()
        function Add-TransferCheck {param($Name,$Passed)$script:TransferChecks.Add([pscustomobject]@{Name=$Name;Passed=[bool]$Passed})}
        $script:TransferSourceId='11111111-1111-1111-1111-111111111111';$script:TransferTargetId='22222222-2222-2222-2222-222222222222'
        $script:TransferGuid='44444444-4444-4444-4444-444444444444'
        function New-TransferFixture {
            $script:TransferMode='';$script:TransferRestoreCalls=0;$script:TransferCleanupCalls=0;$script:TransferCreateCalls=0;$script:TransferOwned=$false;$script:TransferRemoved=$false
            $script:TransferRequest=[pscustomobject][ordered]@{OperationId=[guid]::NewGuid().ToString('D');SourceRunId=$script:TransferSourceId;SourceInstanceId='primary';SourceDatabaseName='SourceDb';BackupSetId='33333333-3333-3333-3333-333333333333';TargetDatabaseName='TargetDb';RestoreTimeoutSeconds=600}
            return $script:TransferRequest
        }
        function script:Get-LabTransferBinding {
            param($RunId,$InstanceId,$StateRoot,$OperationId)
            if($OperationId -and $script:TransferMode -eq 'Ownership'){throw 'TRANSFER_OPERATION_OWNERSHIP_INVALID'}
            [pscustomobject]@{RunId=$RunId;ScopeId='scope';InstanceId=$InstanceId;Provider='docker';RuntimeScopeId='runtime';ContainerId=if($RunId -eq $script:TransferSourceId){'a'*64}else{'b'*64};Volumes=if($OperationId){@('owned-volume')}else{@()};HostName='127.0.0.1';Port=14333}
        }
        function script:Get-LabTransferSourceObservation {param($Binding,$DatabaseName,$StateRoot)[pscustomobject][ordered]@{DatabaseId=5;DatabaseGuid=$script:TransferGuid;CreatedAt='2026-01-01'}}
        function script:Get-LabTransferBackup {param($Request,$DataRoot)[pscustomobject]@{Public=[pscustomobject]@{Sha256=('c'*64);Bytes=1024};SourcePath='synthetic.bak'}}
        function script:Get-LabOperationOwnedRun {param($OperationId,$StateRoot)if($script:TransferOwned -and -not $script:TransferRemoved){[pscustomobject]@{runId=$script:TransferTargetId}}}
        function script:New-SqlServerLab {
            param($Version,$Provider,$Profile,$Cpu,$MemoryMB,$LabName,$StateRoot,$GenerateSaPassword,$NonInteractive,$Drives)
            $script:TransferCreateCalls++;$script:TransferOwned=$true
            if($script:TransferMode -eq 'LostCreate'){throw 'synthetic create response loss'}
            [pscustomobject]@{RunId=$script:TransferTargetId}
        }
        function script:Remove-SqlServerLab {
            param($RunId,$StateRoot,[switch]$Force,$Confirm)
            $script:TransferCleanupCalls++
            if($script:TransferMode -eq 'CleanupFailure'){return [pscustomobject]@{Status='RECOVERY_REQUIRED'}}
            $script:TransferRemoved=$true;[pscustomobject]@{Status='REMOVED'}
        }
        function script:Get-LabRunState {param($RunId,$StateRoot)[pscustomobject]@{state=if($script:TransferRemoved){'REMOVED'}else{'RUNNING'}}}
        function script:Get-LabContainerRuntimeScope {param($Provider)[pscustomobject]@{Status='AVAILABLE';RuntimeId='runtime'}}
        function script:Invoke-LabTransferNative {
            param($Provider,$Arguments,$TimeoutSeconds)
            if($Arguments -contains 'sha256sum'){return ('c'*64)+'  /var/opt/mssql/transfer-'+$script:TransferRequest.OperationId+'.bak'}
            if($Arguments -contains 'stat'){return '1024'}
            if($Arguments -contains 'df'){return @('Avail','2147483648')}
        }
        function script:Get-LabRelationalCoreSecret {param($RunId,$StateRoot)$secret=[Security.SecureString]::new();foreach($character in 'synthetic-fixture-only'.ToCharArray()){$secret.AppendChar($character)};return $secret}
        function script:Invoke-LabPortableContainerTransferPreflightSql {param($Binding,$Secret,$SqlBackupPath,$ExpectedDatabaseName)}
        function script:New-LabTransferConnection {
            param($Binding,$OperationId,$StateRoot)
            $connection=[pscustomobject]@{}
            $connection|Add-Member ScriptMethod Open {}
            $connection|Add-Member ScriptMethod Dispose {}
            $connection|Add-Member ScriptMethod CreateCommand {
                $parameters=[pscustomobject]@{};$parameters|Add-Member ScriptMethod AddWithValue {param($Key,$Value)}
                $command=[pscustomobject]@{CommandText='';CommandTimeout=0;Parameters=$parameters}
                $command|Add-Member ScriptMethod Dispose {}
                $command|Add-Member ScriptMethod ExecuteNonQuery {
                    if($this.CommandText -match 'RESTORE DATABASE'){
                        $script:TransferRestoreCalls++
                        if($script:TransferMode -in @('LostRestore','CleanupFailure')){throw 'synthetic lost SQL acknowledgement'}
                    }
                    return 0
                }
                return $command
            }
            return $connection
        }
        function script:Invoke-LabTransferSqlRows {
            param($Connection,$Query,$Parameters,$TimeoutSeconds)
            if($Query -match 'HEADERONLY'){return [pscustomobject]@{IsReadOnly=$true;BindingID=[guid]$script:TransferGuid}}
            if($Query -match 'FILELISTONLY'){
                return @([pscustomobject]@{LogicalName='Data';Type='D';IsPresent=$true;FileId=[long]1;Size=[decimal]8388608;TDEThumbprint=[DBNull]::Value},[pscustomobject]@{LogicalName='Log';Type='L';IsPresent=$true;FileId=[long]2;Size=[decimal]8388608;TDEThumbprint=[DBNull]::Value})
            }
            if($Query -match 'UserDatabases'){return [pscustomobject]@{UserDatabases=if($script:TransferMode -eq 'Collision'){1}else{0}}}
            if($Query -match 'sys.master_files'){return @([pscustomobject]@{LogicalName='Data';Path="/var/opt/mssql/data/transfer-$($script:TransferRequest.OperationId)-1.mdf"},[pscustomobject]@{LogicalName='Log';Path="/var/opt/mssql/data/transfer-$($script:TransferRequest.OperationId)-2.ldf"})}
            throw 'unexpected fixture query'
        }
        function script:Invoke-LabRelationalCoreComparison {param($ComparisonPair,$StateRoot,$TimeoutSeconds,$ExpectedBindings)[pscustomobject]@{Status=if($script:TransferMode -eq 'Mismatch'){'DIFFERENT'}else{'MATCH'}}}
        function script:Write-LabTransferJournal {
            param($Journal,$Path)
            if($script:TransferMode -eq 'JournalBeforeCreate' -and $Journal.Status -eq 'INTENT'){throw 'TRANSFER_JOURNAL_WRITE_FAILED'}
            if($script:TransferMode -eq 'JournalBeforeRestore' -and $Journal.Status -eq 'RESTORE_STARTED'){throw 'TRANSFER_JOURNAL_WRITE_FAILED'}
            & $script:TransferRealWrite -Journal $Journal -Path $Path
        }
        $state=Join-Path $Root 'state';$data=Join-Path $Root 'data'
        $request=New-TransferFixture
        $connectionFixture=Get-LabTransferBinding -RunId $script:TransferTargetId -InstanceId primary -OperationId $request.OperationId
        $realConnection=& $script:TransferRealConnection -Binding $connectionFixture -OperationId $request.OperationId -StateRoot $state
        try {
            $builder=[Data.SqlClient.SqlConnectionStringBuilder]::new($realConnection.ConnectionString)
            Add-TransferCheck 'Echter SqlClient-Builder bindet Application Name und Credential ohne Connect' ($builder['Application Name'] -ceq "SqlServerLab.Transfer.$($request.OperationId)" -and $realConnection.Credential.UserId -ceq 'sa')
        } finally {$realConnection.Dispose()}
        $comparisonConnection=New-LabRelationalCoreConnection -Binding $connectionFixture -DatabaseName SourceDb -Secret (Get-LabRelationalCoreSecret -RunId $script:TransferSourceId -StateRoot $state)
        try{
            $comparisonBuilder=[Data.SqlClient.SqlConnectionStringBuilder]::new($comparisonConnection.ConnectionString)
            Add-TransferCheck 'Relationaler SqlClient behält nach Dispose keinen Connection-Pool und keine Secretinfos' (-not $comparisonBuilder['Pooling'] -and -not $comparisonBuilder['Persist Security Info'])
        }finally{$comparisonConnection.Dispose()}
        $result=Invoke-LabPortableContainerTransfer -Request $request -DataRoot $data -StateRoot $state
        Add-TransferCheck 'Eigener Ziel-Run bleibt nur nach MATCH und Stage-Cleanup erhalten' ($result.Status -eq 'SUCCEEDED' -and $result.Comparison -eq 'MATCH' -and $script:TransferRestoreCalls -eq 1 -and $script:TransferCleanupCalls -eq 0)
        $again=Invoke-LabPortableContainerTransfer -Request $request -DataRoot $data -StateRoot $state
        Add-TransferCheck 'Identische terminale Operation erzeugt und restauriert kein zweites Mal' ($again.Status -eq 'SUCCEEDED' -and $script:TransferCreateCalls -eq 1 -and $script:TransferRestoreCalls -eq 1)
        $request.TargetDatabaseName='Changed';$blocked=$false
        try{Invoke-LabPortableContainerTransfer -Request $request -DataRoot $data -StateRoot $state|Out-Null}catch{$blocked=$_.Exception.Message -eq 'TRANSFER_REQUEST_CHANGED'}
        Add-TransferCheck 'Gleiche Operation mit geändertem Request wird abgewiesen' $blocked
        foreach($mode in @('LostCreate','LostRestore','Collision','JournalBeforeRestore','Mismatch')){
            $request=New-TransferFixture;$script:TransferMode=$mode
            $result=Invoke-LabPortableContainerTransfer -Request $request -DataRoot $data -StateRoot $state
            $expectedRestore=if($mode -in @('LostRestore','Mismatch')){1}else{0}
            Add-TransferCheck "$mode bleibt auf Whole-Run-Cleanup begrenzt" ($result.Status -eq 'FAILED_CLEANED' -and $script:TransferCleanupCalls -eq 1 -and $script:TransferRestoreCalls -eq $expectedRestore)
            $null=Invoke-LabPortableContainerTransfer -Request $request -DataRoot $data -StateRoot $state
            Add-TransferCheck "$mode wiederholt beim Resume keinen Restore" ($script:TransferRestoreCalls -eq $expectedRestore -and $script:TransferCleanupCalls -eq 1)
        }
        $request=New-TransferFixture;$script:TransferMode='CleanupFailure'
        $result=Invoke-LabPortableContainerTransfer -Request $request -DataRoot $data -StateRoot $state
        Add-TransferCheck 'Fehlgeschlagenes Remove-Ergebnis bleibt RECOVERY_REQUIRED' ($result.Status -eq 'RECOVERY_REQUIRED' -and $script:TransferRestoreCalls -eq 1)
        $script:TransferMode='';$result=Invoke-LabPortableContainerTransfer -Request $request -DataRoot $data -StateRoot $state
        Add-TransferCheck 'Cleanup-Resume entfernt nur den eigenen Run ohne zweiten Restore' ($result.Status -eq 'FAILED_CLEANED' -and $script:TransferCleanupCalls -eq 2 -and $script:TransferRestoreCalls -eq 1)
        $request=New-TransferFixture;$script:TransferMode='Ownership';$result=Invoke-LabPortableContainerTransfer -Request $request -DataRoot $data -StateRoot $state
        Add-TransferCheck 'Unbeweisbare Zielownership löst weder Restore noch Remove aus' ($result.Status -eq 'RECOVERY_REQUIRED' -and $script:TransferCleanupCalls -eq 0 -and $script:TransferRestoreCalls -eq 0)
        $request=New-TransferFixture;$script:TransferMode='JournalBeforeCreate';$blocked=$false
        try{Invoke-LabPortableContainerTransfer -Request $request -DataRoot $data -StateRoot $state|Out-Null}catch{$blocked=$true}
        Add-TransferCheck 'Fehlender dauerhafter Erstjournal verhindert Create' ($blocked -and $script:TransferCreateCalls -eq 0)
        $request=New-TransferFixture;$lockPath=Join-Path (Join-Path $state 'portable-container-transfers') ($request.OperationId+'.lock')
        $held=[IO.File]::Open($lockPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None);$blocked=$false
        try{try{Invoke-LabPortableContainerTransfer -Request $request -DataRoot $data -StateRoot $state|Out-Null}catch{$blocked=$_.Exception.Message -eq 'TRANSFER_OPERATION_LOCKED'}}finally{$held.Dispose()}
        Add-TransferCheck 'Parallele gleiche Operation wird vor Create abgewiesen' ($blocked -and $script:TransferCreateCalls -eq 0)
        $row=[pscustomobject]@{LogicalName='Data';Type='S';IsPresent=$true;FileId=[long]1;Size=[decimal]8388608;TDEThumbprint=[DBNull]::Value};$blocked=$false
        try{ConvertTo-LabTransferFilePlan -Rows @($row) -OperationId $request.OperationId|Out-Null}catch{$blocked=$_.Exception.Message -eq 'TRANSFER_FILELIST_UNSUPPORTED'}
        Add-TransferCheck 'Unbekannter FILELIST-Typ wird vor Restore blockiert' $blocked
        $row.Type='D';$row.Size=[decimal]2147483648;$blocked=$false
        try{ConvertTo-LabTransferFilePlan -Rows @($row) -OperationId $request.OperationId|Out-Null}catch{$blocked=$_.Exception.Message -eq 'TRANSFER_FILELIST_LIMIT_EXCEEDED'}
        Add-TransferCheck 'Komprimiertes Backup kann Restoregrößenlimit nicht umgehen' $blocked
        $expected=Get-LabTransferBindingIdentity (Get-LabTransferBinding -RunId $script:TransferSourceId -InstanceId primary);$expected.ContainerId='f'*64;$blocked=$false
        try{Assert-LabTransferBinding -Expected $expected -StateRoot $state|Out-Null}catch{$blocked=$_.Exception.Message -eq 'TRANSFER_LIVE_BINDING_DRIFT'}
        Add-TransferCheck 'Containeridentity-Drift wird fail-closed erkannt' $blocked
        $script:TransferEndpoint='127.0.0.1';$script:TransferForeignVolume=$false;$script:TransferSharedVolume=$false;$script:TransferResidue=$false
        function script:Get-LabRunState {param($RunId,$StateRoot)[pscustomobject]@{state='RUNNING';scopeId='scope';metadata=[pscustomobject]@{workflowOperationId=$script:TransferRequest.OperationId;persistentData=$false}}}
        function script:Resolve-LabRunInstance {param($RunId,$InstanceId,$StateRoot)[pscustomobject]@{Provider='docker';Version='2025';ContainerName='synthetic';HostName=$script:TransferEndpoint;Port=14333}}
        function script:Invoke-LabTransferNative {
            param($Provider,$Arguments,$TimeoutSeconds)
            if($Arguments[0] -eq 'inspect'){
                return [pscustomobject]@{Id=('b'*64);Os='linux';State=[pscustomobject]@{Running=$true};Config=[pscustomobject]@{Labels=@{'sql-server-lab.run-id'=$script:TransferTargetId;'sql-server-lab.scope-id'='scope';'sql-server-lab.instance-id'='primary'}};NetworkSettings=[pscustomobject]@{Ports=@{'1433/tcp'=@([pscustomobject]@{HostPort='14333';HostIp='127.0.0.1'})}};Mounts=@([pscustomobject]@{Type='volume';Destination='/var/opt/mssql';RW=$true;Name='owned-volume'})}|ConvertTo-Json -Depth 20 -Compress
            }
            if($Arguments[0] -eq 'volume' -and $Arguments[1] -eq 'inspect'){
                return [pscustomobject]@{Labels=@{'sql-server-lab.run-id'=$(if($script:TransferForeignVolume){$script:TransferSourceId}else{$script:TransferTargetId});'sql-server-lab.scope-id'='scope';'sql-server-lab.instance-id'='primary'}}|ConvertTo-Json -Depth 10 -Compress
            }
            if($Arguments -contains 'volume=owned-volume'){if($script:TransferSharedVolume){return @(('b'*64),('a'*64))};return 'b'*64}
            if($script:TransferResidue -and $Arguments[0] -eq 'volume'){return 'owned-volume'}
        }
        $binding=& $script:TransferRealBinding -RunId $script:TransferTargetId -InstanceId primary -OperationId $request.OperationId -StateRoot $state
        Add-TransferCheck 'Produktiver Guard akzeptiert nur exakt gebundene eigene Volume-Anbindung' ($binding.ContainerId -eq ('b'*64))
        $script:TransferEndpoint='example.invalid';$blocked=$false
        try{& $script:TransferRealBinding -RunId $script:TransferTargetId -InstanceId primary -OperationId $request.OperationId -StateRoot $state|Out-Null}catch{$blocked=$_.Exception.Message -eq 'TRANSFER_ENDPOINT_BINDING_INVALID'}
        Add-TransferCheck 'Fremder State-Endpunkt erreicht keine SQL-Credentialverbindung' $blocked
        $script:TransferEndpoint='::1';$blocked=$false
        try{& $script:TransferRealBinding -RunId $script:TransferTargetId -InstanceId primary -OperationId $request.OperationId -StateRoot $state|Out-Null}catch{$blocked=$_.Exception.Message -eq 'TRANSFER_ENDPOINT_BINDING_INVALID'}
        Add-TransferCheck 'Loopback-Adresse muss exakt zur veröffentlichten Portbindung passen' $blocked
        $script:TransferEndpoint='127.0.0.1';$script:TransferForeignVolume=$true;$blocked=$false
        try{& $script:TransferRealBinding -RunId $script:TransferTargetId -InstanceId primary -OperationId $request.OperationId -StateRoot $state|Out-Null}catch{$blocked=$_.Exception.Message -eq 'TRANSFER_VOLUME_OWNERSHIP_INVALID'}
        Add-TransferCheck 'Fremdes Volume-Label verhindert Zielbindung' $blocked
        $script:TransferForeignVolume=$false;$script:TransferSharedVolume=$true;$blocked=$false
        try{& $script:TransferRealBinding -RunId $script:TransferTargetId -InstanceId primary -OperationId $request.OperationId -StateRoot $state|Out-Null}catch{$blocked=$_.Exception.Message -eq 'TRANSFER_VOLUME_SHARED'}
        Add-TransferCheck 'Weiterer Volume-Konsument verhindert Zielbindung' $blocked
        $script:TransferSharedVolume=$false;$script:TransferResidue=$true;$blocked=$false
        try{Assert-LabTransferNoResidue -Binding $binding}catch{$blocked=$_.Exception.Message -eq 'TRANSFER_CLEANUP_RESIDUE'}
        Add-TransferCheck 'REMOVED ohne bestätigte Volume-Abwesenheit ist kein Cleanup-Erfolg' $blocked
        $script:TransferSecretReads=0
        function script:Get-LabRelationalCoreSecret {param($RunId,$StateRoot)$script:TransferSecretReads++;throw 'must not read secret'}
        function script:Get-LabRelationalCoreLiveBinding {param($RunId,$InstanceId,$StateRoot)[pscustomobject]@{Provider='docker';RuntimeScopeId='runtime';ContainerId=if($RunId -eq $script:TransferSourceId){'a'*64}else{'b'*64};HostName='example.invalid';Port=14333}}
        $pair=[pscustomobject]@{PairId='transfer';SourceRunId=$script:TransferSourceId;SourceInstanceId='primary';SourceDatabaseName='SourceDb';TargetRunId=$script:TransferTargetId;TargetInstanceId='primary';TargetDatabaseName='TargetDb'}
        $comparison=& $script:TransferRealComparison -ComparisonPair @($pair) -StateRoot $state -ExpectedBindings ([pscustomobject]@{Source=$binding;Target=$binding})
        Add-TransferCheck 'Vergleichs-Rebinding prüft erwarteten Endpunkt vor Secretauflösung' ($comparison.Status -ne 'MATCH' -and $script:TransferSecretReads -eq 0)
        function script:Invoke-LabRelationalCoreReader {
            param($Connection,$Query)
            $reader=[pscustomobject]@{FieldCount=4;Ordinal=-1;ReadCount=0}
            $reader|Add-Member ScriptMethod Read {$this.ReadCount++;return $this.ReadCount -eq 1}
            $reader|Add-Member ScriptMethod IsDBNull {param($Ordinal)if($Ordinal -lt $this.Ordinal){throw 'SEQUENTIAL_ORDINAL_REGRESSION'};$this.Ordinal=$Ordinal;return $false}
            $reader|Add-Member ScriptMethod GetString {param($Ordinal)if($Ordinal -lt $this.Ordinal){throw 'SEQUENTIAL_ORDINAL_REGRESSION'};$this.Ordinal=$Ordinal;if($Ordinal -eq 0){return 'SourceDb'};return 'ONLINE'}
            $reader|Add-Member ScriptMethod GetInt32 {param($Ordinal)throw 'DB_ID_IS_SQL_SMALLINT'}
            $reader|Add-Member ScriptMethod GetValue {param($Ordinal)if($Ordinal -lt $this.Ordinal){throw 'SEQUENTIAL_ORDINAL_REGRESSION'};$this.Ordinal=$Ordinal;return [int16]5}
            $reader|Add-Member ScriptMethod GetBoolean {param($Ordinal)if($Ordinal -lt $this.Ordinal){throw 'SEQUENTIAL_ORDINAL_REGRESSION'};$this.Ordinal=$Ordinal;return $true}
            $reader|Add-Member ScriptMethod Dispose {}
            $command=[pscustomobject]@{};$command|Add-Member ScriptMethod Dispose {}
            return @($command,$reader)
        }
        $connection=[Data.SqlClient.SqlConnection]::new();$sequential=$false
        try{Assert-LabRelationalCoreDatabaseBinding -Connection $connection -RequestedDatabaseName SourceDb;$sequential=$true}finally{$connection.Dispose()}
        Add-TransferCheck 'SequentialAccess liest SQL-smallint-DB_ID ohne Ordinalrücksprung oder Int32-Unboxing' $sequential
        return @($script:TransferChecks)
    } $root
    foreach($item in $checks){Check $item.Name $item.Passed}
    $whatIfRoot=Join-Path $root 'whatif'
    $result=Invoke-SqlServerLabPortableContainerTransfer -SourceRunId '11111111-1111-1111-1111-111111111111' -SourceInstanceId primary -SourceDatabaseName SourceDb -BackupSetId '33333333-3333-3333-3333-333333333333' -TargetDatabaseName TargetDb -OperationId ([guid]::NewGuid()) -DataRoot $whatIfRoot -StateRoot $whatIfRoot -WhatIf
    Check 'Öffentliches WhatIf erzeugt weder State noch Ressourcen' ($result.Status -eq 'WHATIF' -and -not(Test-Path -LiteralPath $whatIfRoot))
} finally {
    Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
    $resolved=[IO.Path]::GetFullPath($root);$boundary=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    if(-not $resolved.StartsWith($boundary,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notlike 'sql-lab-transfer-checks-*'){throw 'TRANSFER_TEST_CLEANUP_SCOPE_INVALID'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
$failures=@($results|Where-Object {-not $_.Passed})
if($failures.Count){throw "PORTABLE CONTAINER TRANSFER CHECKS FAILED: $($failures.Name -join '; ')"}
Write-Host "PORTABLE CONTAINER TRANSFER CHECKS: PASS ($($results.Count))"
