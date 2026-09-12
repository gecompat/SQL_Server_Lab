<#
.SYNOPSIS
    Erstellt den bewusst blockierten, lokalen Executor-Preflight fuer genau ein BackupSet.
.DESCRIPTION
    Dieser erste Vertrag bindet ausschliesslich zwei bereits laufende verwaltete
    SQL-2025/Linux-Container und ein lokales REUSABLE BackupSet. Er schreibt
    keine Dateien und ruft nie RESTORE auf. RELATIONAL_CORE/1.0 ist noch nicht
    implementiert; deshalb bleibt jede Planung vor SQL- oder Containermutation
    mit einem expliziten Inhaltsvergleichsblocker stehen.
#>
function Get-LabPortableContainerTransferExecutorPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F-]{36}$')][string]$SourceRunId,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$SourceInstanceId,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F-]{36}$')][string]$TargetRunId,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$TargetInstanceId,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F-]{36}$')][string]$BackupSetId,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z][A-Za-z0-9_]{0,127}$')][string]$TargetDatabaseName,
        [Parameter(Mandatory)][string]$DataRoot,
        [string]$StateRoot
    )
    $blockers=[Collections.Generic.List[string]]::new()
    $backup=$null
    try { $backup=Get-LabDatabaseBackup -BackupSetId $BackupSetId -DataRoot $DataRoot }
    catch { $blockers.Add('BACKUP_LOCAL_OWNERSHIP_OR_INTEGRITY_UNVERIFIABLE') }
    $backupView=[ordered]@{BackupSetId=$BackupSetId.ToLowerInvariant();Sha256=$null;Bytes=0;LocalOwnership='LAB_DATA_LIBRARY';BackupChecksum=$false;RestoreVerifyOnly=$false;HeaderOnly='BLOCKED'}
    if($backup){
        $record=$backup.Record; $item=Get-Item -LiteralPath $backup.Path -ErrorAction Stop
        $hash=(Get-LabProgressFileHash -LiteralPath $backup.Path -Algorithm SHA256).Hash.ToLowerInvariant()
        $backupView.Sha256=[string]$record.Artifact.Sha256; $backupView.Bytes=[long]$record.Artifact.Bytes
        $backupView.BackupChecksum=[bool]$record.Verification.BackupChecksum; $backupView.RestoreVerifyOnly=[bool]$record.Verification.RestoreVerifyOnly
        if($hash -ne $backupView.Sha256 -or $item.Length -ne $backupView.Bytes){$blockers.Add('BACKUP_SHA256_OR_SIZE_MISMATCH')}
        if([string]$record.Source.RunId -cne $SourceRunId -or [string]$record.Source.InstanceId -cne $SourceInstanceId){$blockers.Add('BACKUP_SOURCE_BINDING_MISMATCH')}
        if([string]$record.Source.SqlMajorVersion -ne '17' -or [bool]$record.DatabaseMetadata.HasFileStream -or [bool]$record.DatabaseMetadata.IsEncrypted){$blockers.Add('BACKUP_SCOPE_UNSUPPORTED')}
        if(-not $backupView.BackupChecksum -or -not $backupView.RestoreVerifyOnly){$blockers.Add('BACKUP_CHECKSUM_OR_VERIFYONLY_EVIDENCE_MISSING')}
    }
    $makeBinding={param($runId,$instanceId,$side)
        $view=[ordered]@{Provider=$null;RunId=$runId.ToLowerInvariant();InstanceId=$instanceId;SqlMajorVersion='17';RuntimeScopeId=$null;ContainerId=$null;RunState='UNVERIFIABLE';ContainerState='UNVERIFIABLE'}
        try {$run=Get-LabRunState -RunId $runId -StateRoot $StateRoot;$target=Resolve-LabRunInstance -RunId $runId -InstanceId $instanceId -StateRoot $StateRoot
            $view.Provider=[string]$target.Provider;$view.RunState=[string]$run.state
            if($view.Provider -notin @('docker','podman') -or $view.RunState -ne 'RUNNING' -or [string]$target.Version -notmatch '^17(\.|$)'){$blockers.Add("${side}_RUN_OR_SQL_VERSION_NOT_ELIGIBLE");return [PSCustomObject]$view}
            $scope=Get-LabContainerRuntimeScope -Provider $view.Provider
            if([string]$scope.Status -ne 'AVAILABLE' -or -not $scope.RuntimeId){$blockers.Add("${side}_RUNTIME_SCOPE_UNVERIFIABLE");return [PSCustomObject]$view};$view.RuntimeScopeId=[string]$scope.RuntimeId
            $invocation=Get-LabHostToolInvocation -Name $view.Provider;$out=@(& $invocation inspect --format '{{.Id}}|{{.State.Running}}' $target.ContainerName 2>$null)
            if($LASTEXITCODE -ne 0 -or $out.Count -ne 1 -or $out[0] -notmatch '^([a-f0-9]{12,64})\|true$'){$blockers.Add("${side}_LIVE_CONTAINER_BINDING_UNVERIFIABLE");return [PSCustomObject]$view}
            $view.ContainerId=$Matches[1].ToLowerInvariant();$view.ContainerState='RUNNING'
        }catch{$blockers.Add("${side}_LIVE_BINDING_UNVERIFIABLE")}
        [PSCustomObject]$view }
    $source=& $makeBinding $SourceRunId $SourceInstanceId 'SOURCE';$target=& $makeBinding $TargetRunId $TargetInstanceId 'TARGET'
    if($SourceRunId -eq $TargetRunId -and $SourceInstanceId -eq $TargetInstanceId){$blockers.Add('SOURCE_AND_TARGET_MUST_BE_DISTINCT')}
    # No credential or SQL statement is accepted by this plan contract. Therefore
    # required HEADERONLY/CHECKSUM/VERIFYONLY revalidation must fail closed.
    $blockers.Add('BACKUP_HEADERONLY_AND_LIVE_CHECKSUM_VERIFYONLY_NOT_EXECUTED')
    $blockers.Add('CONTENT_COMPARISON_PROFILE_UNAVAILABLE')
    $plan=[PSCustomObject][ordered]@{ContractVersion='SqlServerLab.PortableContainerTransferExecutorPlan/1.0';OperationId=[guid]::NewGuid().ToString('D');Status='BLOCKED';ExecutionImplemented=$false;Source=$source;Target=$target;Backup=[PSCustomObject]$backupView;ContentComparison=[PSCustomObject]@{Profile='RELATIONAL_CORE/1.0';Status='UNAVAILABLE'};Blockers=@($blockers|Sort-Object -Unique);Steps=@([PSCustomObject]@{Order=1;Action='REVALIDATE_LOCAL_BACKUP_SHA256_AND_SIZE';Mutation='NONE'},[PSCustomObject]@{Order=2;Action='REVALIDATE_SOURCE_AND_TARGET_LIVE_BINDINGS';Mutation='NONE'},[PSCustomObject]@{Order=3;Action='REQUIRE_SOURCE_READ_ONLY';Mutation='NONE'},[PSCustomObject]@{Order=4;Action='EXECUTE_HEADERONLY_CHECKSUM_VERIFYONLY';Mutation='NONE'},[PSCustomObject]@{Order=5;Action='REQUIRE_NEW_TARGET_DATABASE';Mutation='NONE'},[PSCustomObject]@{Order=6;Action='COMPARE_RELATIONAL_CORE_CONTENT';Mutation='NONE'});PlannedAt=Get-LabTimestamp}
    $valid=$plan|ConvertTo-Json -Depth 20|Test-Json -SchemaFile (Join-Path $script:SchemasPath 'portable-container-transfer-executor-plan.schema.json') -ErrorAction Stop;if(-not $valid){throw 'PORTABLE_CONTAINER_TRANSFER_EXECUTOR_PLAN_INVALID'};return $plan
}
function New-LabPortableContainerTransferExecutorJournal {
    [CmdletBinding()]param([Parameter(Mandatory)]$Plan)
    $journal=[PSCustomObject][ordered]@{ContractVersion='SqlServerLab.PortableContainerTransferExecutorJournal/1.0';OperationId=[string]$Plan.OperationId;Status='BLOCKED';Plan=$Plan;Recovery='NO_MUTATION_PERFORMED';UpdatedAt=Get-LabTimestamp}
    $valid=$journal|ConvertTo-Json -Depth 30|Test-Json -SchemaFile (Join-Path $script:SchemasPath 'portable-container-transfer-executor-journal.schema.json') -ErrorAction Stop;if(-not $valid){throw 'PORTABLE_CONTAINER_TRANSFER_EXECUTOR_JOURNAL_INVALID'};return $journal
}
