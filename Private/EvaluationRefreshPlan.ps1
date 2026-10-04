# Gemeinsame reine Fristklassifikation; keine Lizenzprüfung oder Erneuerung.
function Get-LabEvaluationDeadlineStatus {
    param([AllowNull()]$ExpiresAt,[datetime]$Now,[int]$WarningDaysRemaining,[int]$CriticalDaysRemaining)
    if($null-eq$ExpiresAt){return 'UNKNOWN'}
    $days=[Math]::Max(0,[int][Math]::Ceiling(($ExpiresAt-$Now).TotalDays))
    if($ExpiresAt-le$Now){return 'EXPIRED'}
    if($days-le$CriticalDaysRemaining){return 'CRITICAL'}
    if($days-le$WarningDaysRemaining){return 'WARNING'}
    return 'OK'
}

function Read-LabEvaluationRefreshSnapshot {
    [CmdletBinding()]
    param([string]$RunId,[string]$InstanceId,[string]$DataRoot)
    $binding=Get-LabDiagnosticBinding -RunId $RunId -InstanceId $InstanceId -DataRoot $DataRoot
    $run=$binding.Run
    if($binding.Provider-cne'hyperv'-or@($run.metadata.desiredState.Instances).Count-ne1-or$run.state-cnotin@('RUNNING','STOPPED')-or
        $run.metadata.workflowKind-cne'hyperv-lab'-or$run.metadata.workload-cne'sql') {throw 'EVALUATION_REFRESH_SCOPE_UNSUPPORTED'}
    $connection=Read-LabDiagnosticJson -Path (Join-Path $binding.Directory connection-info.json)
    $instances=@($connection.instances)
    if($connection.schemaVersion-ne1-or$connection.instances-isnot[array]-or$instances.Count-ne1-or$instances[0].id-cne$InstanceId-or$instances[0].provider-cne'hyperv'-or
        $instances[0].workload-cne'sql'-or-not$instances[0].vmId-or-not$run.metadata.imageArtifactId-or
        $instances[0].imageArtifactId-cne$run.metadata.imageArtifactId){throw 'EVALUATION_REFRESH_BINDING_INVALID'}
    # Authenticate bounded, duplicate-free local bytes before the existing guest reader.
    $evidence=Read-LabDiagnosticJson -Path (Join-Path $binding.Directory sql-guest-evaluation-evidence.json) -Optional
    $guest=Get-LabSqlGuestEvaluationEvidence -RunId $RunId -StateRoot $binding.StateRoot
    if($guest.RunId-cne$RunId-or($guest.InstanceId-and$guest.InstanceId-cne$InstanceId)){throw 'EVALUATION_REFRESH_BINDING_INVALID'}
    if($guest.Status-ceq'VALID'-and($guest.Evidence.ScopeId-cne$run.scopeId-or$guest.Evidence.InstanceId-cne$InstanceId)){
        throw 'EVALUATION_REFRESH_BINDING_INVALID'
    }
    if($guest.Status-ceq'VALID'-and($guest.Evidence|ConvertTo-Json -Depth 20 -Compress)-cne($evidence|ConvertTo-Json -Depth 20 -Compress)){
        throw 'EVALUATION_REFRESH_BINDING_CHANGED'
    }
    $material=[ordered]@{Run=$run;Connection=$connection;Evidence=$evidence;
        Marker=Read-LabDiagnosticJson -Path (Join-Path $binding.Root '.sql-server-lab-root.json') -MaximumBytes 16384 -MaximumDepth 8;
        Catalog=Read-LabDiagnosticJson -Path (Join-Path $binding.Root 'Catalog/storage-locations.json') -MaximumBytes 65536 -MaximumDepth 12}
    $json=$material|ConvertTo-Json -Depth 40 -Compress
    $digest=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($json))).ToLowerInvariant()
    [pscustomobject]@{Binding=$binding;Instance=$instances[0];Guest=$guest;Digest=$digest}
}

function New-LabEvaluationRefreshPlan {
    param([string]$RunId,[string]$InstanceId,[string]$DataRoot,[string]$Mode)
    try {
        $snapshot=Read-LabEvaluationRefreshSnapshot -RunId $RunId -InstanceId $InstanceId -DataRoot $DataRoot
    } catch {
        if($_.Exception.Message-cin@('EVALUATION_REFRESH_SCOPE_UNSUPPORTED','EVALUATION_REFRESH_BINDING_INVALID','EVALUATION_REFRESH_BINDING_CHANGED')){throw $_.Exception.Message}
        throw 'EVALUATION_REFRESH_BINDING_UNAVAILABLE'
    }
    $now=[datetime]::UtcNow
    $sql=ConvertTo-LabSqlGuestEvaluationWatchItem -ReaderResult $snapshot.Guest -RegistrationState $snapshot.Binding.Run.state `
        -Now $now -WarningDaysRemaining 30 -CriticalDaysRemaining 7
    $activation=$snapshot.Instance.windowsActivation
    $expiry=ConvertFrom-LabSqlGuestEvaluationEvidenceUtcTimestamp -Value $activation.evaluationExpiresAt
    $windows=[pscustomobject]@{Component='Windows';Status=Get-LabEvaluationDeadlineStatus -ExpiresAt $expiry -Now $now -WarningDaysRemaining 30 -CriticalDaysRemaining 7;
        DeadlineSource=if($expiry){'PERSISTED_WINDOWS_ACTIVATION'}else{'PERSISTED_WINDOWS_ACTIVATION_MISSING_OR_INVALID'};
        EvaluationExpiresAt=if($expiry){$expiry.ToString('o')}else{$null};DaysRemaining=if($expiry){[Math]::Max(0,[int][Math]::Ceiling(($expiry-$now).TotalDays))}else{$null};EvidenceStatus='HISTORICAL_METADATA';FreshLicenseProof=$false}
    $sqlProjection=[pscustomobject]@{Component='SqlServer';Status=$sql.Status;DeadlineSource=$sql.DeadlineSource;
        EvidenceStatus=$sql.EvidenceStatus;EvaluationExpiresAt=$sql.EvaluationExpiresAt;DaysRemaining=$sql.DaysRemaining;SqlReadiness='NOT_CHECKED'}
    $blockers=[Collections.Generic.List[string]]::new()
    $blockers.Add('CURRENT_WINDOWS_LICENSE_PROOF_NOT_AVAILABLE')
    if($sql.EvidenceStatus-cnotin@('CURRENT','NOT_EVALUATION')){$blockers.Add('SQL_EVALUATION_EVIDENCE_REQUIRED')}
    $steps=switch -CaseSensitive ($Mode) {
        'FREE_SLOT_REPLACEMENT' {$blockers.Add('SLOT_MEMBERSHIP_AND_REPLACEMENT_TARGET_NOT_ASSESSED');@('Freien Slot und getrennte Restlaufzeiten über den bestehenden Poolvertrag prüfen.','Neue Medien und Zielbindung separat bestätigen; ein Clone setzt keine Evaluation zurück.')}
        'RECONSTRUCT_LAB' {$blockers.Add('DECLARATIVE_RECONSTRUCTION_AND_DATA_DISPOSABILITY_NOT_VERIFIED');@('Deklarative Rekonstruktion sowie entbehrlichen Zustand und erforderliche Datenübernahme klassifizieren.','Neue Umgebung separat planen; Gleichwertigkeit und Rückfall vor Änderungen nachweisen.')}
        'STATEFUL_MIGRATION' {$blockers.Add('FULL_INSTANCE_INVENTORY_NOT_AVAILABLE');$blockers.Add('EQUIVALENCE_CUTOVER_AND_ROLLBACK_NOT_VERIFIED');@('Datenbank-, Serverobjekt-, Schlüssel- und externe Abhängigkeiten getrennt inventarisieren.','DATABASE_FILES_ONLY ist kein vollständiger Instanztransfer. Cutover und Rückfall nach Zielschreibzugriffen separat planen.')}
        default {throw 'EVALUATION_REFRESH_MODE_INVALID'}
    }
    try {$fresh=Read-LabEvaluationRefreshSnapshot -RunId $RunId -InstanceId $InstanceId -DataRoot $DataRoot}
    catch {throw 'EVALUATION_REFRESH_BINDING_CHANGED'}
    if($fresh.Digest-cne$snapshot.Digest){throw 'EVALUATION_REFRESH_BINDING_CHANGED'}
    [pscustomobject]@{ContractVersion='SqlServerLab.EvaluationRefreshPlan/1.0';Mode=$Mode;Status='BLOCKED';
        RunId=$RunId;ScopeId=$snapshot.Binding.Run.scopeId;InstanceId=$InstanceId;Provider='hyperv';
        ObservedContentSha256=$snapshot.Digest;Evaluations=@($windows,$sqlProjection);Blockers=@($blockers);NextSteps=@($steps);
        FullInstanceMigration=$false;EquivalenceStatus='NOT_VERIFIED';SqlReadiness='NOT_CHECKED';
        ExecutionSupported=$false;MutationAllowed=$false;Actions=@();TransferAuthority='NONE';GeneratedAt=$now.ToString('o')}
}
