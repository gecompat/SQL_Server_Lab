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
        $captureOperation='abcdefabcdefabcdefabcdefabcdefab'
        $captureRun=[guid]::NewGuid().ToString(); $captureScope=[guid]::NewGuid().ToString()
        $captureContainer=('c'*64); $captureRuntime='runtime-scope-'+('d'*24)
        $captureEvidence=Join-Path $Root 'readiness-capture'; $null=New-Item -ItemType Directory $captureEvidence
        $script:captureMode='own'; $script:captureCalls=0
        function Get-LabContainerRuntimeScope { param($Provider) [pscustomobject]@{Status='AVAILABLE';RuntimeId=$captureRuntime} }
        function Get-LabOperationOwnedRun { param($OperationId,$StateRoot)
            if ($script:captureMode -eq 'foreign') { return [pscustomobject]@{runId=$captureRun;scopeId=$captureScope;metadata=@{workflowOperationId='foreign';persistentData=$false}} }
            [pscustomobject]@{runId=$captureRun;scopeId=$captureScope;metadata=@{workflowOperationId=$captureOperation;persistentData=$false}}
        }
        function Get-LabProviderSubRuns { param($RunId,$StateRoot)
            [pscustomobject]@{provider='docker';state='PROVISIONING'}
        }
        function Get-CleanupPlan { param($RunDir)
            [pscustomobject]@{runId=$captureRun;scopeId=$captureScope;providerSubRuns=@([pscustomobject]@{provider='docker'})}
        }
        function Invoke-LabTransferNative {
            param($Provider,$Arguments,$TimeoutSeconds)
            $script:captureCalls++
            if ($script:captureMode -eq 'throw' -and $Arguments[0] -eq 'logs') { throw 'SYNTHETIC_CAPTURE_FAILURE' }
            if ($Arguments[0] -eq 'inspect') {
                $labels=@{'sql-server-lab.run-id'=$captureRun;'sql-server-lab.scope-id'=$captureScope;'sql-server-lab.instance-id'='primary'}
                if ($script:captureMode -eq 'labels') { $labels.'sql-server-lab.run-id'='foreign' }
                return (@([pscustomobject]@{Id=$captureContainer;State=[pscustomobject]@{Running=$false};Config=[pscustomobject]@{Labels=$labels}})|ConvertTo-Json -Depth 8 -Compress)
            }
            if ($Arguments[0] -eq 'logs') { return 'engine failure password=synthetic-secret CANARY_PRIVATE_LOG' }
            throw 'SYNTHETIC_NATIVE_ARGUMENT_INVALID'
        }
        function Get-LabContainerReadinessDiagnostic {
            param($Provider,$ContainerIdOrName,[switch]$IncludeLogs)
            [pscustomobject]@{Status='exited';Running=$false;Message='ORIGINAL_DIAGNOSTIC_CANARY'}
        }
        $originalReadiness=(Get-Command Get-LabContainerReadinessDiagnostic -CommandType Function).ScriptBlock
        $captureParameters=@{Provider='docker';OperationId=$captureOperation;StateRoot=$Root;EvidenceRoot=$captureEvidence;RuntimeScopeId=$captureRuntime}
        $result=Invoke-PitrReadinessDiagnosticWithCapture -Original $originalReadiness @captureParameters -ContainerIdOrName $captureContainer -IncludeLogs
        $capturePath=Join-Path $captureEvidence 'readiness-failure.log'
        $captured=Get-Content -LiteralPath $capturePath -Raw
        Check ($result.Message -ceq 'ORIGINAL_DIAGNOSTIC_CANARY' -and $captured -match 'CANARY_PRIVATE_LOG' -and
            $captured -notmatch 'synthetic-secret' -and $captured -match 'password=\*\*\*' -and
            -not (Test-Path -LiteralPath (Join-Path $Root ("runs/$captureRun/connection-info.json")))) 'Own stopped container captures before connection-info exists while original diagnostic remains unchanged'
        $null=Invoke-PitrNewWithReadinessCapture @captureParameters -Action { 'SYNTHETIC_NEW_SUCCESS' }
        Check (((Get-Command Get-LabContainerReadinessDiagnostic -CommandType Function).ScriptBlock.ToString()) -eq $originalReadiness.ToString()) 'Readiness wrapper is restored after successful New boundary'
        Remove-Item -LiteralPath $capturePath -Force
        $script:captureCalls=0
        $null=Invoke-PitrReadinessDiagnosticWithCapture -Original $originalReadiness @captureParameters -ContainerIdOrName $captureContainer
        Check (-not (Test-Path -LiteralPath $capturePath) -and $script:captureCalls -eq 0) 'Diagnostic without IncludeLogs performs no extra runtime capture'
        foreach ($mode in @('foreign','labels')) {
            $script:captureMode=$mode; $script:captureCalls=0
            $null=Invoke-PitrReadinessDiagnosticWithCapture -Original $originalReadiness @captureParameters -ContainerIdOrName $captureContainer -IncludeLogs
            $expectedCalls=if ($mode -eq 'foreign') { 0 } else { 1 }
            Check (-not (Test-Path -LiteralPath $capturePath) -and $script:captureCalls -eq $expectedCalls) "$mode ownership validation skips logs before foreign or unverifiable access"
        }
        $script:captureMode='throw'; $primary=$null
        try {
            $null=Invoke-PitrReadinessDiagnosticWithCapture -Original $originalReadiness @captureParameters -ContainerIdOrName $captureContainer -IncludeLogs
            throw 'SYNTHETIC_PRIMARY_FAILURE'
        }
        catch { $primary=$_.Exception.Message }
        Check ($primary -ceq 'SYNTHETIC_PRIMARY_FAILURE' -and -not (Test-Path -LiteralPath $capturePath) -and
            ((Get-Command Get-LabContainerReadinessDiagnostic -CommandType Function).ScriptBlock.ToString()) -eq $originalReadiness.ToString()) 'Capture failure preserves primary failure and restores readiness wrapper'
        $operation='1234567890abcdef1234567890abcdef'
        $script:binding=[pscustomobject]@{Provider='docker';ContainerId=('a'*64);RuntimeScopeId=('runtime-scope-'+('b'*24));RunId=[guid]::NewGuid().ToString();ScopeId=[guid]::NewGuid().ToString()}
        function Assert-LabTransferBinding {
            param($Expected,$StateRoot,$OperationId)
            if ($script:mode -ceq 'binding') { throw 'TRANSFER_LIVE_BINDING_DRIFT' }
            return $script:binding
        }
        function Invoke-LabTransferNative {
            param($Provider,$Arguments,$TimeoutSeconds)
            if (-not $script:readinessFailure) { return }
            if ($Arguments[0] -eq 'inspect') {
                return (@([pscustomobject]@{Id=$captureContainer;State=[pscustomobject]@{Running=$false};Config=[pscustomobject]@{Labels=@{'sql-server-lab.run-id'=$captureRun;'sql-server-lab.scope-id'=$captureScope;'sql-server-lab.instance-id'='primary'}}}) | ConvertTo-Json -Depth 8 -Compress)
            }
            if ($Arguments[0] -eq 'logs') { return 'failure password=synthetic-secret MODULE_WRAPPER_CANARY' }
        }
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
        function Get-LabProviderSubRuns {param($RunId,$StateRoot)[pscustomobject]@{provider=$script:provider;state='PROVISIONING'}}
        function New-SqlServerLab {
            param($Version,$Provider,$Profile,$Cpu,$MemoryMB,$LabName,$StateRoot,[switch]$GenerateSaPassword,[switch]$NonInteractive,[switch]$SkipAssessment,$Drives)
            Check ((Get-LabWorkflowOperationContext) -ceq $script:operation -and (Test-Path (Join-Path $script:evidence 'intent.json'))) 'Real New boundary receives operation context after durable intent'
            $installed=(Get-Command Get-LabContainerReadinessDiagnostic -CommandType Function).ScriptBlock
            Check ($installed.ToString() -match 'captureDiagnostic') 'Actual New boundary observes the temporary module readiness wrapper'
            $script:owned=[pscustomobject]@{runId=$script:binding.RunId;scopeId=$script:binding.ScopeId;metadata=@{workflowOperationId=$script:operation;persistentData=$false}}
            $diagnostic=Get-LabContainerReadinessDiagnostic -Provider docker -ContainerIdOrName $script:binding.ContainerId -IncludeLogs:$script:readinessFailure
            if ($script:readinessFailure) {
                $captured=Get-Content -LiteralPath (Join-Path $script:evidence 'readiness-failure.log') -Raw
                Check ($diagnostic.Message -ceq 'ORIGINAL_DIAGNOSTIC_CANARY' -and $captured -match 'MODULE_WRAPPER_CANARY' -and $captured -notmatch 'synthetic-secret') 'Actual New failure captures private logs before primary failure'
                throw 'SYNTHETIC_PRIMARY_FAILURE'
            }
            Check ($diagnostic.Message -ceq 'ORIGINAL_DIAGNOSTIC_CANARY' -and -not (Test-Path (Join-Path $script:evidence 'readiness-failure.log'))) 'Actual New boundary delegates unchanged readiness result without log capture'
            if ($script:lostNew) { throw 'SYNTHETIC_NEW_RESPONSE_LOST' }
            [pscustomobject]@{State='RUNNING';RunId=$script:binding.RunId;Instances=@([pscustomobject]@{})}
        }
        function Remove-SqlServerLab {
            param($RunId,$StateRoot,[switch]$Force,[switch]$Confirm)
            $script:removed++
            [pscustomobject]@{Status=if($script:cleanupFailure){'RECOVERY_REQUIRED'}else{'REMOVED'};Cleanup='CLEANUP_SUCCEEDED';Errors=0}
        }
        function Assert-LabTransferNoResidue {param($Binding) if ($script:residue) { throw 'TRANSFER_CLEANUP_RESIDUE' }}
        $ordinaryBinding=$script:binding
        $script:binding=[pscustomobject]@{Provider='docker';ContainerId=$captureContainer;RuntimeScopeId=$captureRuntime;RunId=$captureRun;ScopeId=$captureScope}
        $script:operation=$captureOperation; $script:runtimeId=$captureRuntime; $script:provider='docker'; $script:owned=$null
        $script:readinessFailure=$true; $script:evidence=$captureEvidence
        Reject { Invoke-PitrArrange -Provider docker -OperationId $captureOperation -StateRoot $Root -EvidenceRoot $captureEvidence } 'SYNTHETIC_PRIMARY_FAILURE'
        Check (((Get-Command Get-LabContainerReadinessDiagnostic -CommandType Function).ScriptBlock.ToString()) -eq $originalReadiness.ToString()) 'Actual New failure restores module readiness wrapper after capture and primary failure'
        Remove-Item -LiteralPath (Join-Path $captureEvidence 'readiness-failure.log') -Force
        $script:binding=$ordinaryBinding; $script:readinessFailure=$false
        foreach ($mode in @('success','lost-new','operation-drift','runtime-drift','provider-drift','cleanup-failed','residue')) {
            $script:mode='success'; $script:operation=$operation; $script:runtimeId=$script:binding.RuntimeScopeId
            $script:provider='docker'; $script:owned=$null; $script:removed=0
            $script:lostNew=($mode -ceq 'lost-new'); $script:cleanupFailure=($mode -ceq 'cleanup-failed'); $script:residue=($mode -ceq 'residue'); $script:readinessFailure=$false
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
