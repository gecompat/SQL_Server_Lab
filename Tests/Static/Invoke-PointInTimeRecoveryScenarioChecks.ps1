#Requires -Version 7.2
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
. (Join-Path $repoRoot 'Tests/Common/PointInTimeRecoverySupervisor.ps1')
$root=New-PitrSupervisorRoot -Synthetic
$module=Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru
try {
    & $module {
        param($Repo,$Root)
        . (Join-Path $Repo 'Tests/Common/PointInTimeRecoveryScenario.ps1')
        $script:count=0
        function Check([bool]$Condition,[string]$Name) {
            if (-not $Condition) { throw "PITR_CHECK_FAILED: $Name" }
            $script:count++; Write-Host "PASS: $Name"
        }
        function Reject([scriptblock]$Action,[string]$Code) {
            $caught=$null; try { & $Action | Out-Null } catch { $caught=$_.Exception.Message }
            Check ($caught -and $caught -match $Code) "Reject $Code"
        }
        $tables=foreach ($value in @('ONLINE','1:good-marker')) {
            $table=[Data.DataTable]::new(); $null=$table.Columns.Add('Value',[string]); $null=$table.Rows.Add($value); ,$table
        }
        $reader=[Data.DataTableReader]::new([Data.DataTable[]]$tables)
        try { Check ((@(Read-PitrSqlResults $reader) -join '|') -ceq 'ONLINE|1:good-marker') 'Real multi-result reader consumes ONLINE and content resultsets' }
        finally { $reader.Dispose() }
        function Assert-LabTransferBinding {param($Expected,$StateRoot,$OperationId) $Expected}
        function New-LabTransferConnection {param($Binding,$OperationId,$StateRoot) $script:connection}
        foreach ($transportFailure in @($false,$true)) {
            $script:commandDisposed=$false; $script:connectionDisposed=$false; $script:opened=$false
            $script:transportFailure=$transportFailure
            $script:queryReader=[Data.DataTableReader]::new([Data.DataTable[]]$tables)
            $script:command=[pscustomobject]@{CommandText='';CommandTimeout=0}
            $script:command | Add-Member ScriptMethod ExecuteReader {
                if ($script:transportFailure) { throw 'RAW_SQL_ERROR_CANARY' }; return ,$script:queryReader
            }
            $script:command | Add-Member ScriptMethod Dispose { $script:commandDisposed=$true }
            $secret=[Security.SecureString]::new()
            $secret.AppendChar('x')
            $script:connection=[pscustomobject]@{Credential=[pscustomobject]@{Password=$secret}}
            $script:connection | Add-Member ScriptMethod Open { $script:opened=$true }
            $script:connection | Add-Member ScriptMethod CreateCommand { $script:command }
            $script:connection | Add-Member ScriptMethod Dispose { $script:connectionDisposed=$true }
            if ($transportFailure) { Reject { Invoke-PitrSql -Binding @{} -OperationId synthetic -StateRoot $Root -Query synthetic } '^PITR_SQL_FAILED$' }
            else {
                $values=@(Invoke-PitrSql -Binding @{} -OperationId synthetic -StateRoot $Root -Query synthetic)
                Check (($values -join '|') -ceq 'ONLINE|1:good-marker') 'Actual transport consumes all resultsets'
            }
            $disposed=$false; try { $copy=$secret.Copy(); $copy.Dispose() } catch { $disposed=$true }
            Check ($script:opened -and $script:command.CommandTimeout -eq 45 -and $script:commandDisposed -and
                $script:connectionDisposed -and $disposed) 'Actual SQL transport bounds commands and disposes command, connection and secret on both paths'
            $script:queryReader.Dispose()
        }
        Assert-PitrCutoff '2026-01-02 03:04:05.123'
        foreach ($cutoff in @('2026-01-02T03:04:05.1234567','2026-01-02 03:04:05.123Z','2026-02-30 03:04:05.123',"2026-01-02 03:04:05.123'; DROP DATABASE master;--")) {
            Reject { Assert-PitrCutoff $cutoff } 'CUTOFF_INVALID'
        }
        $operation='1234567890abcdef1234567890abcdef'
        $script:binding=[pscustomobject]@{Provider='docker';ContainerId=('a'*64);RuntimeScopeId=('runtime-scope-'+('b'*24));RunId=[guid]::NewGuid().ToString();ScopeId=[guid]::NewGuid().ToString()}
        function Assert-LabTransferBinding {
            param($Expected,$StateRoot,$OperationId)
            if ($script:mode -ceq 'binding') { throw 'TRANSFER_LIVE_BINDING_DRIFT' }
            return $script:binding
        }
        function Invoke-LabTransferNative { param($Provider,$Arguments,$TimeoutSeconds) }
        function Invoke-PitrSql {
            param($Binding,$OperationId,$StateRoot,$Query)
            $script:queries.Add($Query)
            switch -Regex ($Query) {
                'ProductMajorVersion' { if ($script:mode -ceq 'version') { return '16' }; return '17' }
                '^BACKUP DATABASE' { $script:full=@($script:rows); return }
                'INSERT .*good-marker' { $script:rows+=('1:good-marker'); return }
                'SYSDATETIME' {
                    Check (($script:rows -join '|') -ceq '1:good-marker') 'Cutoff is captured after actual good insertion'
                    $script:captured=$true
                    if ($script:mode -ceq 'cutoff') { return '2026-01-02T03:04:05.1234567' }
                    return '2026-01-02 03:04:05.123'
                }
                "^WAITFOR DELAY" { Check $script:captured 'Explicit server delay follows cutoff'; $script:delayed=$true; return }
                'INSERT .*bad-mutation' { Check $script:delayed 'Bad commit follows server delay'; $script:rows+=('2:bad-mutation'); return }
                '^BACKUP LOG' {
                    Check (($script:rows -join '|') -ceq '1:good-marker|2:bad-mutation') 'Log backup really contains both commits'
                    $script:log=@($script:rows); return
                }
                '^RESTORE DATABASE' {
                    Check ($script:log.Count -eq 2 -and $script:full.Count -eq 0 -and $Query -match 'NORECOVERY' -and
                        $Query -match 'PitrTarget_' -and $Query -notmatch 'REPLACE') 'Fresh moved target starts from pre-marker full backup after log capture'
                    $script:restored=@($script:full); $script:restoring=$true; return
                }
                '^DECLARE @cutoff' {
                    Check ($script:restoring -and $Query -match "2026-01-02 03:04:05.123" -and $Query -match 'STOPAT=@cutoff,RECOVERY') 'Actual restore receives the exact captured cutoff'
                    if ($script:mode -ceq 'restore-failure') { throw 'PITR_SQL_FAILED' }
                    $script:restored=@($script:log | Where-Object { $_ -ceq '1:good-marker' })
                    if ($script:mode -ceq 'target-bad') { $script:restored=@($script:log) }
                    if ($script:mode -ceq 'source-changed') { $script:rows=@('1:good-marker') }
                    return
                }
                'SELECT CONCAT.*PitrSource_' { return $script:rows }
                'SELECT CONCAT.*PitrTarget_' { return $script:restored }
                'SELECT state_desc' { if ($script:mode -ceq 'offline') { return 'RESTORING' }; return 'ONLINE' }
                '^DBCC CHECKDB' { if ($script:mode -ceq 'integrity') { throw 'PITR_SQL_FAILED' }; $script:checked=$true; return }
            }
        }
        foreach ($mode in @('success','version','cutoff','binding','restore-failure','target-bad','source-changed','offline','integrity')) {
            $script:mode=$mode; $script:rows=@(); $script:queries=[Collections.Generic.List[string]]::new()
            $script:captured=$false; $script:delayed=$false; $script:checked=$false; $script:restoring=$false
            $parameters=@{Binding=$script:binding;OperationId=$operation;StateRoot=$Root}
            if ($mode -ceq 'success') {
                $result=Invoke-PitrRecovery @parameters
                Check ($result.Status -ceq 'VERIFIED' -and $result.RecoveryMilliseconds -gt 0 -and $script:checked) 'Complete real orchestration verifies rows, CHECKDB and measured restore interval'
            }
            else {
                $code=switch ($mode) {
                    version {'VERSION_INVALID'} cutoff {'CUTOFF_INVALID'} binding {'LIVE_BINDING_DRIFT'}
                    restore-failure {'SQL_FAILED'} target-bad {'TARGET_CONTENT_INVALID'} source-changed {'SOURCE_CHANGED'}
                    offline {'TARGET_NOT_ONLINE'} integrity {'SQL_FAILED'}
                }
                Reject { Invoke-PitrRecovery @parameters } $code
                if ($mode -cin @('version','cutoff','binding')) { Check (-not $script:restoring) "$mode fails before any restore" }
            }
        }
        function Get-LabContainerRuntimeScope {param($Provider)[pscustomobject]@{Status='AVAILABLE';RuntimeId=$script:runtimeId}}
        function Get-LabTransferBinding {param($RunId,$InstanceId,$StateRoot,$OperationId) $script:binding}
        function Get-LabTransferBindingIdentity {param($Binding) $Binding}
        function Get-LabOperationOwnedRun {param($OperationId,$StateRoot) $script:owned}
        function Get-LabProviderSubRuns {param($RunId,$StateRoot)[pscustomobject]@{provider=$script:provider}}
        function New-SqlServerLab {
            param($Version,$Provider,$Profile,$Cpu,$MemoryMB,$LabName,$StateRoot,[switch]$GenerateSaPassword,[switch]$NonInteractive,[switch]$SkipAssessment,$Drives)
            Check ((Get-LabWorkflowOperationContext) -ceq $script:operation -and (Test-Path (Join-Path $script:evidence 'intent.json'))) 'Real New boundary receives operation context after durable intent'
            $script:owned=[pscustomobject]@{runId=$script:binding.RunId;scopeId=$script:binding.ScopeId;metadata=@{workflowOperationId=$script:operation;persistentData=$false}}
            if ($script:lostNew) { throw 'SYNTHETIC_NEW_RESPONSE_LOST' }
            [pscustomobject]@{State='RUNNING';RunId=$script:binding.RunId;Instances=@([pscustomobject]@{})}
        }
        function Remove-SqlServerLab {
            param($RunId,$StateRoot,[switch]$Force,[switch]$Confirm)
            $script:removed++
            [pscustomobject]@{Status=if($script:cleanupFailure){'RECOVERY_REQUIRED'}else{'REMOVED'};Cleanup='CLEANUP_SUCCEEDED';Errors=0}
        }
        function Assert-LabTransferNoResidue {param($Binding) if ($script:residue) { throw 'TRANSFER_CLEANUP_RESIDUE' }}
        foreach ($mode in @('success','lost-new','operation-drift','runtime-drift','provider-drift','cleanup-failed','residue')) {
            $script:mode='success'; $script:operation=$operation; $script:runtimeId=$script:binding.RuntimeScopeId
            $script:provider='docker'; $script:owned=$null; $script:removed=0
            $script:lostNew=($mode -ceq 'lost-new'); $script:cleanupFailure=($mode -ceq 'cleanup-failed'); $script:residue=($mode -ceq 'residue')
            $script:rows=@(); $script:queries=[Collections.Generic.List[string]]::new(); $script:captured=$false; $script:delayed=$false
            $script:evidence=Join-Path $Root $mode; $null=New-Item -ItemType Directory $script:evidence
            $parameters=@{Provider='docker';OperationId=$operation;StateRoot=$Root;EvidenceRoot=$script:evidence}
            if ($script:lostNew) { Reject { Invoke-PitrArrange @parameters } 'NEW_RESPONSE_LOST' }
            else { $null=Invoke-PitrArrange @parameters }
            switch ($mode) {
                operation-drift { $script:owned.metadata.workflowOperationId='other' }
                runtime-drift { $script:runtimeId='runtime-scope-'+('c'*24) }
                provider-drift { $script:provider='podman' }
            }
            if ($mode -cin @('success','lost-new')) {
                Remove-PitrOwnRun @parameters
                Check ($script:removed -eq 1) "$mode discovers and removes exactly the owned run"
            }
            else {
                Reject { Remove-PitrOwnRun @parameters } 'CLEANUP_'
                if ($mode -like '*drift') { Check ($script:removed -eq 0) "$mode blocks cleanup mutation" }
                Check (Test-Path (Join-Path $script:evidence 'intent.json')) "$mode preserves recovery evidence"
            }
        }
        Write-Host "PITR SCENARIO: $script:count PASS"
    } $repoRoot $root
}
finally {
    $path=[IO.Path]::GetFullPath($root); $temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if (-not $path.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($path) -notlike 'sql-server-lab-pitr-*') { throw 'TEST_ROOT_INVALID' }
    Remove-Item -LiteralPath $path -Recurse -Force
}
