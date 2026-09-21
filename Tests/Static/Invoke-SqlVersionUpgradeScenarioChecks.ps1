#Requires -Version 7.2
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
. (Join-Path $repoRoot 'Tests/Common/SqlVersionUpgradeSupervisor.ps1')
$root=New-SqlUpgradeSupervisorRoot -Synthetic
$module=Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru
try {
    & $module {
        param($Repo,$Root)
        . (Join-Path $Repo 'Tests/Common/SqlVersionUpgradeScenario.ps1')
        $script:count=0
        function Check([bool]$Condition,[string]$Name) {
            if (-not $Condition) { throw "SQL_UPGRADE_CHECK_FAILED: $Name" }
            $script:count++; Write-Host "PASS: $Name"
        }
        function Reject([scriptblock]$Action,[string]$Code) {
            $caught=$null; try { & $Action | Out-Null } catch { $caught=$_.Exception.Message }
            Check ($caught -and $caught -match $Code) "Reject $Code"
        }
        $operation='1234567890abcdef1234567890abcdef'
        $script:runtime='runtime-scope-'+('b'*24)
        function Get-LabContainerRuntimeScope { param($Provider) [pscustomobject]@{Status='AVAILABLE';RuntimeId=$script:runtime} }
        function Get-LabRunState { param($RunId,$StateRoot) $script:run }
        function Resolve-LabRunInstance { param($RunId,$InstanceId,$StateRoot) $script:instance }
        function Invoke-LabTransferNative {
            param($Provider,$Arguments)
            switch ($Arguments[0]) {
                inspect { ConvertTo-Json -InputObject @($script:container) -Depth 15; return }
                volume { ConvertTo-Json -InputObject @($script:volume) -Depth 15; return }
                ps { $script:attachments; return }
            }
        }
        foreach ($version in @('2022','2025')) {
            foreach ($fault in @('none','operation','persistent','version','container-label','scope-label','endpoint','sidecar','volume-label','volume-shared')) {
                $runId=[guid]::NewGuid().ToString(); $scopeId=[guid]::NewGuid().ToString()
                $script:run=@{state='RUNNING';runId=$runId;scopeId=$scopeId;metadata=@{workflowOperationId=$operation;persistentData=$false}}
                $script:instance=@{Version=$version;Provider='docker';ContainerName='synthetic';HostName='127.0.0.1';Port=14333}
                $labels=@{'sql-server-lab.run-id'=$runId;'sql-server-lab.scope-id'=$scopeId;'sql-server-lab.instance-id'='primary'}
                $script:container=@{Id=('a'*64);Os='linux';State=@{Running=$true};Config=@{Labels=$labels.Clone()};NetworkSettings=@{Ports=@{'1433/tcp'=@(@{HostIp='127.0.0.1';HostPort='14333'})}};Mounts=@(@{Type='volume';Destination='/var/opt/mssql';RW=$true;Name='synthetic-volume'})}
                $script:volume=@{Name='synthetic-volume';Labels=$labels.Clone()}; $script:attachments=@('a'*64)
                switch ($fault) {
                    operation { $script:run.metadata.workflowOperationId='foreign' }
                    persistent { $script:run.metadata.persistentData=$true }
                    version { $script:instance.Version=if($version -ceq '2022'){'2025'}else{'2022'} }
                    container-label { $script:container.Config.Labels['sql-server-lab.run-id']='foreign' }
                    scope-label { $script:container.Config.Labels['sql-server-lab.scope-id']='foreign' }
                    endpoint { $script:container.NetworkSettings.Ports.'1433/tcp'[0].HostIp='0.0.0.0' }
                    sidecar { $script:container.Mounts+=@{Type='bind';Destination='/foreign'} }
                    volume-label { $script:volume.Labels['sql-server-lab.run-id']='foreign' }
                    volume-shared { $script:attachments+=('c'*64) }
                }
                $arguments=@{RunId=$runId;OperationId=$operation;Version=$version;StateRoot=$Root}
                if ($fault -ceq 'none') {
                    $binding=Get-SqlUpgradeBinding @arguments
                    Check ($binding.Version -ceq $version -and $binding.RuntimeScopeId -ceq $script:runtime) "Actual $version binding accepts own labels and runtime"
                    $old=$script:runtime; $script:runtime='runtime-scope-'+('d'*24)
                    Reject { Assert-SqlUpgradeBinding -Expected $binding -StateRoot $Root } 'LIVE_BINDING_CHANGED'
                    $script:runtime=$old
                } else { Reject { Get-SqlUpgradeBinding @arguments } 'SQL_UPGRADE_' }
            }
        }
        function Assert-SqlUpgradeBinding { param($Expected,$StateRoot) $Expected }
        function Get-LabRelationalCoreSecret { param($RunId,$StateRoot) $script:secret }
        function New-LabRelationalCoreConnection { param($Binding,$DatabaseName,$Secret) $script:connection }
        foreach ($failure in @($false,$true)) {
            $script:transportFailure=$failure; $script:commandDisposed=$false; $script:connectionDisposed=$false
            $tables=foreach ($value in @('16','17')) {
                $table=[Data.DataTable]::new(); $null=$table.Columns.Add('Value',[string]); $null=$table.Rows.Add($value); ,$table
            }
            $script:reader=[Data.DataTableReader]::new([Data.DataTable[]]$tables)
            $script:secret=[Security.SecureString]::new(); $script:secret.AppendChar('x')
            $script:command=[pscustomobject]@{CommandText='';CommandTimeout=0}
            $script:command | Add-Member ScriptMethod ExecuteReader { if($script:transportFailure){throw 'RAW_SQL_CANARY'}; return ,$script:reader }
            $script:command | Add-Member ScriptMethod Dispose { $script:commandDisposed=$true }
            $script:connection=[pscustomobject]@{}
            $script:connection | Add-Member ScriptMethod Open {}
            $script:connection | Add-Member ScriptMethod CreateCommand { $script:command }
            $script:connection | Add-Member ScriptMethod Dispose { $script:connectionDisposed=$true }
            if ($failure) { Reject { Invoke-SqlUpgradeQuery -Binding $binding -StateRoot $Root -Query 'synthetic' } '^SQL_UPGRADE_QUERY_FAILED$' }
            else { Check ((@(Invoke-SqlUpgradeQuery -Binding $binding -StateRoot $Root -Query 'synthetic') -join '|') -ceq '16|17') 'Real multi-result reader consumes every resultset' }
            $disposed=$false; try { $copy=$script:secret.Copy(); $copy.Dispose() } catch { $disposed=$true }
            Check ($script:commandDisposed -and $script:connectionDisposed -and $disposed -and $script:command.CommandTimeout -eq 45) 'Bounded transport disposes command, connection and secret on success/failure'
        }
        $script:atomicWriter=${function:Write-LabArtifactJsonAtomic}
        function Write-LabArtifactJsonAtomic {
            param($Path,$InputObject)
            if ($script:mode -ceq 'publish-target' -and [IO.Path]::GetFileName($Path) -ceq 'target-binding.json') {
                # Interrupted before atomic rename: the incomplete sibling must not become authority.
                [IO.File]::WriteAllText(($Path+'.synthetic.tmp'),'{')
                throw 'SYNTHETIC_BINDING_PUBLISH_INTERRUPTED'
            }
            & $script:atomicWriter -Path $Path -InputObject $InputObject
        }
        # Real Arrange, workload checks, operation context and disk-based lost-New discovery.
        function Initialize-LabManagedDataRoot {
            param($DataRoot,$ControllerId,[switch]$Confirm)
            $null=New-Item -ItemType Directory $DataRoot
        }
        function Get-SqlUpgradeBinding {
            param($RunId,$OperationId,$Version,$StateRoot)
            $role=if($Version -ceq '2022'){'source'}else{'target'}
            [pscustomobject]@{RunId=$RunId;ScopeId=$script:runs[$role].scopeId;OperationId=$OperationId;Version=$Version;Provider='docker';RuntimeScopeId=$script:runtime;ContainerId=($(if($role -ceq 'source'){'a'}else{'c'})*64);Volumes=@('synthetic-'+$role)}
        }
        function New-SqlServerLab {
            param($Version,$Provider,[Alias('Profile')]$LabProfile,$Cpu,$MemoryMB,$LabName,$StateRoot,[Security.SecureString]$SaPassword,[switch]$NonInteractive,[switch]$SkipAssessment,$Drives)
            $plain=ConvertFrom-SecureString -SecureString $SaPassword -AsPlainText
            try { Check ($plain -cmatch '^-[a-f0-9]{32}aA1!$') 'Own-run credentials cover leading-minus backup regression' }
            finally { $plain=$null }
            $role=if($Version -ceq '2022'){'source'}else{'target'}
            $intent=Get-Content (Join-Path $script:evidence 'intent.json') -Raw | ConvertFrom-Json
            Check ($intent.SourceOperationId -ceq ($script:operation+'-source') -and $intent.TargetOperationId -ceq ($script:operation+'-target') -and
                (Get-LabWorkflowOperationContext) -ceq ($script:operation+'-'+$role)) 'Both operation intents persisted before real New context'
            $run=@{runId=[guid]::NewGuid().ToString();scopeId=[guid]::NewGuid().ToString();state='RUNNING';metadata=@{workflowOperationId=(Get-LabWorkflowOperationContext);persistentData=$false}}
            $script:runs[$role]=$run
            $directory=Join-Path $StateRoot ('runs/'+$run.runId); $null=New-Item -ItemType Directory $directory -Force
            $run | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $directory 'run-state.json')
            $script:events.Add('new-'+$role)
            if ($script:mode -ceq ('lost-'+$role)) { throw 'SYNTHETIC_NEW_RESPONSE_LOST' }
            [pscustomobject]@{State='RUNNING';RunId=$run.runId;Instances=@(@{})}
        }
        function Get-LabRelationalCoreSecret { param($RunId,$StateRoot) $value=[Security.SecureString]::new(); $value.AppendChar('x'); $script:secrets.Add($value); return $value }
        function Backup-SqlServerLabDatabase {
            param($RunId,$InstanceId,$DatabaseName,[Security.SecureString]$SaPassword,$DataRoot,$StateRoot,[switch]$Confirm)
            Check ($RunId -ceq $script:runs.source.runId -and $SaPassword -is [Security.SecureString] -and $script:integrity.Contains('source-160')) 'Public full backup follows verified source and receives SecureString'
            $script:events.Add('backup'); $script:backupRows=@($script:rows.source)
            [pscustomobject]@{Status='BACKUP_REUSABLE';BackupSetId='11111111-2222-4333-8444-555555555555';Sha256=('e'*64)}
        }
        function Get-LabDatabaseBackup {
            param($BackupSetId,$DataRoot)
            if($script:mode -ceq 'hash-failed'){throw 'SYNTHETIC_HASH_MISMATCH'}
            $record=@{Status='REUSABLE';Source=@{RunId=$script:runs.source.runId;SqlMajorVersion='16';Provider='docker';InstanceId='primary'};DatabaseName=('UpgradeSource_'+$script:operation);DatabaseMetadata=@{HasFileStream=$false;IsEncrypted=$false};Verification=@{BackupChecksum=$true;RestoreVerifyOnly=$true};Artifact=@{Sha256=('e'*64)}}
            switch($script:mode){ checksum {$record.Verification.BackupChecksum=$false} verify {$record.Verification.RestoreVerifyOnly=$false} encrypted {$record.DatabaseMetadata.IsEncrypted=$true} filestream {$record.DatabaseMetadata.HasFileStream=$true} }
            [pscustomobject]@{Record=$record}
        }
        function Restore-SqlServerLabDatabase {
            param($RunId,$InstanceId,$DatabaseName,[Security.SecureString]$SaPassword,$BackupSetId,$DataRoot,$StateRoot,[switch]$Confirm)
            Check ($RunId -ceq $script:runs.target.runId -and $RunId -cne $script:runs.source.runId -and $BackupSetId -ceq '11111111-2222-4333-8444-555555555555' -and
                $DatabaseName -ceq ('UpgradeTarget_'+$script:operation) -and $SaPassword -is [Security.SecureString]) 'Public Restore receives registered BackupSetId on different fresh run/database'
            $script:events.Add('restore'); $script:rows.target=@($script:backupRows); $script:compat.target=160
            switch($script:mode){ restore {throw 'SYNTHETIC_RESTORE_FAILED'} compat {$script:compat.target=170} target-rows {$script:rows.target=@('bad')} source-changed {$script:rows.source=@('bad')} }
            [pscustomobject]@{Success=$true;BackupSetId=$BackupSetId;BackupSourceKind='LIBRARY';Provider='docker'}
        }
        function Invoke-SqlUpgradeQuery {
            param($Binding,$StateRoot,$Query)
            $role=if($Binding.Version -ceq '2022'){'source'}else{'target'}
            if($Query -match 'FROM sys.databases') {
                $major=if($role -ceq 'source'){16}else{17}
                if($script:mode -ceq 'source-version' -and $role -ceq 'source'){$major=15}
                return "$major|$($script:compat[$role])|ONLINE|0"
            }
            if($Query -match '^SELECT CONVERT.*ProductMajorVersion'){if($script:mode -ceq 'target-version'){return '16'};return '17'}
            if($Query -match '^CREATE DATABASE'){$script:compat.source=160;return}
            if($Query -match 'CREATE TABLE'){$script:rows.source=@('1|1|one|10.25','2|1|two|20.75','3|2|three|5.00');return}
            if($Query -match '^ALTER DATABASE') {
                Check ($script:integrity.Contains('target-160') -and $script:events.Contains('restore')) 'Explicit compatibility change occurs only after restored compat160 workload and CHECKDB'
                $script:compat.target=170; $script:events.Add('compat170');return
            }
            if($Query -match 'FROM \[.*\]\.dbo.Groups ORDER') {
                if($script:mode -ceq 'groups' -and $role -ceq 'target'){return 'changed'};return @('1|alpha','2|beta')
            }
            if($Query -match '^SELECT CONCAT\(Id'){return $script:rows[$role]}
            if($Query -match 'COUNT_BIG'){
                if($script:mode -ceq 'aggregate' -and $role -ceq 'target'){return 'bad'}
                return @('1|2|31.00','2|1|5.00')
            }
            if($Query -match 'BEGIN TRANSACTION') {
                if($script:mode -ceq 'transaction' -and $role -ceq 'target'){return 'FAILED'}
                if($script:mode -ceq 'rollback' -and $role -ceq 'target'){$script:rows.target=@('changed')}
                return 'TRANSACTION_AND_CONSTRAINTS_VERIFIED'
            }
            if($Query -match '^DBCC') {
                if($script:mode -ceq 'integrity' -and $role -ceq 'target'){return 'corruption'}
                $script:integrity.Add($role+'-'+$script:compat[$role]);return
            }
            throw 'SYNTHETIC_QUERY_UNHANDLED'
        }
        function Get-LabProviderSubRuns { param($RunId,$StateRoot) [pscustomobject]@{provider=$(if($script:mode -ceq 'provider-drift'){'podman'}else{'docker'})} }
        function Remove-SqlServerLab {
            param($RunId,$StateRoot,[switch]$Force,[switch]$Confirm)
            $role=if($RunId -ceq $script:runs.source.runId){'source'}else{'target'}
            $script:removed.Add($role)
            if($script:mode -ceq 'cleanup-target' -and $role -ceq 'target'){return [pscustomobject]@{Status='RECOVERY_REQUIRED';Cleanup='FAILED';Errors=1}}
            $script:runs[$role].state='REMOVED'
            $script:runs[$role] | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $StateRoot ('runs/'+$RunId+'/run-state.json'))
            [pscustomobject]@{Status='REMOVED';Cleanup='CLEANUP_SUCCEEDED';Errors=0}
        }
        function Invoke-LabTransferNative { param($Provider,$Arguments) if($script:mode -ceq 'residue'){return 'synthetic-residue'} }
        function Assert-LabTransferNoResidue { param($Binding) if($script:mode -ceq 'exact-residue'){throw 'SYNTHETIC_EXACT_RESIDUE'} }
        foreach($mode in @('success','source-version','target-version','hash-failed','checksum','verify','encrypted','filestream','restore','compat','target-rows','source-changed','groups','aggregate','transaction','rollback','integrity','lost-source','lost-target','publish-target','runtime-drift','provider-drift','cleanup-target','residue','exact-residue','operation-drift')) {
            $script:mode=$mode; $script:operation=$operation; $script:runtime='runtime-scope-'+('b'*24)
            $script:evidence=Join-Path $Root $mode; $null=New-Item -ItemType Directory $script:evidence
            $state=Join-Path $script:evidence 'state'
            $script:runs=@{}; $script:rows=@{}; $script:compat=@{}
            $script:events=[Collections.Generic.List[string]]::new();$script:integrity=[Collections.Generic.List[string]]::new()
            $script:removed=[Collections.Generic.List[string]]::new();$script:secrets=[Collections.Generic.List[Security.SecureString]]::new()
            $arguments=@{Provider='docker';OperationId=$operation;StateRoot=$state;EvidenceRoot=$script:evidence}
            $faults=@{ 'source-version'='DATABASE_STATE_INVALID';'target-version'='TARGET_VERSION_INVALID';'hash-failed'='HASH_MISMATCH';checksum='BACKUP_EVIDENCE_INVALID';verify='BACKUP_EVIDENCE_INVALID';encrypted='BACKUP_EVIDENCE_INVALID';filestream='BACKUP_EVIDENCE_INVALID';restore='RESTORE_FAILED';compat='DATABASE_STATE_INVALID';'target-rows'='ROWS_DIFFER';'source-changed'='ROWS_DIFFER';groups='GROUPS_DIFFER';aggregate='AGGREGATE_DIFFER';transaction='TRANSACTION_FAILED';rollback='ROLLBACK_DIFFER';integrity='INTEGRITY_FAILED';'lost-source'='NEW_RESPONSE_LOST';'lost-target'='NEW_RESPONSE_LOST';'publish-target'='BINDING_PUBLISH_INTERRUPTED'}
            if($faults.ContainsKey($mode)){Reject {Invoke-SqlUpgradeArrange @arguments} $faults[$mode]}
            else {
                $result=Invoke-SqlUpgradeArrange @arguments
                Check ($result.Status -ceq 'VERIFIED' -and $result.SourceMajor -eq 16 -and $result.TargetMajor -eq 17 -and
                    $script:compat.target -eq 170 -and $script:compat.source -eq 160 -and ($script:rows.source -join ';') -ceq ($script:rows.target -join ';')) 'Full orchestration verifies both target phases and unchanged source'
            }
            if ($mode -ceq 'publish-target') {
                Check (-not (Test-Path (Join-Path $script:evidence 'target-binding.json')) -and
                    (Test-Path (Join-Path $script:evidence 'target-binding.json.synthetic.tmp'))) 'Interrupted publish leaves no partial binding authority'
            }
            Check (-not (Get-LabWorkflowOperationContext)) 'New context restored after success or thrown lost response'
            foreach($secret in $script:secrets){$disposed=$false;try{$copy=$secret.Copy();$copy.Dispose()}catch{$disposed=$true};Check $disposed 'Backup/Restore secret disposed on every outcome'}
            if($mode -ceq 'runtime-drift'){$script:runtime='runtime-scope-'+('d'*24)}
            if($mode -ceq 'operation-drift') {
                $path=Join-Path $script:evidence 'target-binding.json';$record=Get-Content $path -Raw|ConvertFrom-Json;$record.OperationId='foreign';$record|ConvertTo-Json|Set-Content $path
            }
            if($mode -cin @('runtime-drift','provider-drift','cleanup-target','residue','exact-residue','operation-drift')) {
                Reject {Remove-SqlUpgradeOwnRuns @arguments} 'CLEANUP_INCOMPLETE'
                if($mode -cin @('runtime-drift','provider-drift')){Check ($script:removed.Count -eq 0) 'Changed cleanup authority prevents all mutations'}
                elseif($mode -ceq 'operation-drift'){Check (($script:removed -join '|') -ceq 'source') 'Conflicting target binding blocks only target; independent source still cleaned'}
                else {Check (($script:removed -join '|') -ceq 'target|source') 'Target failure/residue does not skip independent source cleanup'}
                Check (Test-Path (Join-Path $state 'runs')) 'Recovery state retained after incomplete cleanup'
            } else {
                Remove-SqlUpgradeOwnRuns @arguments
                $expected=if($script:runs.ContainsKey('target')){'target|source'}else{'source'}
                Check (($script:removed -join '|') -ceq $expected) "$mode discovers only own persisted runs and cleans target before source"
                foreach($role in $script:runs.Keys){Check ($null -eq (Get-LabOperationOwnedRun -OperationId ($operation+'-'+$role) -StateRoot $state)) 'Actual operation discovery finds no active owned run after cleanup'}
            }
        }
        Write-Host "SQL_UPGRADE SCENARIO: $script:count PASS"
    } $repoRoot $root
}
finally {
    $resolved=[IO.Path]::GetFullPath($root);$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if(-not $resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notlike 'sql-server-lab-upgrade-*'){throw 'SYNTHETIC_ROOT_INVALID'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
