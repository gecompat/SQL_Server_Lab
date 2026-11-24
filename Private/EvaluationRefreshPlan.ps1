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
    $binding=Get-LabDiagnosticBinding -RunId $RunId -InstanceId $InstanceId -DataRoot $DataRoot -AllowHyperVManifestWithoutRunPersistence
    $run=$binding.Run
    if($binding.Provider-cne'hyperv'-or@($run.metadata.desiredState.Instances).Count-ne1-or$run.state-cnotin@('RUNNING','STOPPED')-or
        $run.metadata.workflowKind-cne'hyperv-lab'-or$run.metadata.workload-cne'sql') {throw 'EVALUATION_REFRESH_SCOPE_UNSUPPORTED'}
    $connection=Read-LabDiagnosticJson -Path (Join-Path $binding.Directory connection-info.json)
    $instances=@($connection.instances)
    if($connection.schemaVersion-ne1-or$connection.instances-isnot[array]-or$instances.Count-ne1-or$instances[0].id-cne$InstanceId-or$instances[0].provider-cne'hyperv'-or
        $instances[0].workload-cne'sql'-or-not$instances[0].vmId-or-not$run.metadata.imageArtifactId-or
        $instances[0].imageArtifactId-cne$run.metadata.imageArtifactId){throw 'EVALUATION_REFRESH_BINDING_INVALID'}
    if ($binding.OmittedHyperVManifestPersistenceFlag -and $instances[0].PSObject.Properties['persistentStorage']) {
        throw 'EVALUATION_REFRESH_BINDING_INVALID'
    }
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

function Get-LabEvaluationSqlSourceInventory {
    param([Parameter(Mandatory)]$Snapshot)
    $unavailable = [pscustomobject]@{ Status='NOT_OBSERVED'; Items=@(); DependencyFindings=@() }
    if (-not $IsWindows -or $Snapshot.Binding.Run.state -cne 'RUNNING' -or $Snapshot.Instance.sqlVersion -cne '2025') {
        return $unavailable
    }

    $runId = [guid]$Snapshot.Binding.Run.runId
    try {
        $context = Get-LabSqlGuestCaptureContext -RunId $runId -StateRoot $Snapshot.Binding.StateRoot
        if ($context.Run.scopeId -cne $Snapshot.Binding.Run.scopeId -or $context.Instance.id -cne $Snapshot.Instance.id -or
            $context.Instance.vmId -cne $Snapshot.Instance.vmId -or $context.Instance.imageArtifactId -cne $Snapshot.Instance.imageArtifactId) {
            throw 'EVALUATION_REFRESH_BINDING_CHANGED'
        }
        $observed = Invoke-LabSqlGuestCaptureProbe -Context $context -TimeoutSeconds 60 -IncludeSourceInventory 3>$null 4>$null 5>$null 6>$null
        $fresh = Get-LabSqlGuestCaptureContext -RunId $runId -StateRoot $Snapshot.Binding.StateRoot
        if ($fresh.Fingerprint -cne $context.Fingerprint) { throw 'EVALUATION_REFRESH_BINDING_CHANGED' }
        if ($observed.MajorVersion -ne 17 -or $observed.InstanceName -cne $context.Instance.sqlReadiness.instanceName -or
            $observed.Edition -cne $context.Instance.sqlReadiness.edition) { return $unavailable }
    }
    catch {
        if ($_.Exception.Message -cin @('EVALUATION_REFRESH_BINDING_CHANGED','SQL_GUEST_CAPTURE_BINDING_CHANGED')) {
            throw 'EVALUATION_REFRESH_BINDING_CHANGED'
        }
        return $unavailable
    }

    $categories = @('UserDatabases','NonOnlineUserDatabases','EncryptedUserDatabases','DatabaseSnapshots',
        'FilestreamFileDatabases','SsisCatalogCandidateDatabases','ServerPrincipals','Credentials','LinkedServers','AgentJobs','AgentProxies')
    $counts = $observed.SourceInventory
    if (-not $counts -or @($counts.PSObject.Properties).Count -ne $categories.Count) {
        return $unavailable
    }
    foreach ($category in $categories) {
        $count = $counts.PSObject.Properties[$category]?.Value
        if ($count -isnot [long] -or $count -lt 0) { return $unavailable }
    }
    if ($counts.NonOnlineUserDatabases -gt $counts.UserDatabases -or $counts.EncryptedUserDatabases -gt $counts.UserDatabases -or
        $counts.FilestreamFileDatabases -gt $counts.UserDatabases -or $counts.SsisCatalogCandidateDatabases -gt [Math]::Min([long]1, $counts.UserDatabases)) {
        return $unavailable
    }
    $items = @(foreach ($category in $categories) {
        [pscustomobject]@{ Category=$category; Count=$counts.$category }
    })
    $dependencyCodes = [ordered]@{
        NonOnlineUserDatabases='DATABASE_STATE_REVIEW_REQUIRED'
        EncryptedUserDatabases='TDE_KEY_TRANSFER_REQUIRED'
        DatabaseSnapshots='DATABASE_SNAPSHOT_DISPOSITION_REQUIRED'
        FilestreamFileDatabases='FILESTREAM_STORAGE_REVIEW_REQUIRED'
        SsisCatalogCandidateDatabases='SSIS_CATALOG_REVIEW_REQUIRED'
        Credentials='CREDENTIAL_REBIND_REQUIRED'
        LinkedServers='LINKED_SERVER_REBIND_REQUIRED'
        AgentJobs='SQL_AGENT_JOB_INVENTORY_REQUIRED'
        AgentProxies='SQL_AGENT_PROXY_REBIND_REQUIRED'
    }
    $findings = @(foreach ($entry in $dependencyCodes.GetEnumerator()) {
        $count = $counts.($entry.Key)
        if ($count -gt 0) {
            [pscustomobject]@{ Category=$entry.Key; Count=$count; Code=$entry.Value }
        }
    })
    [pscustomobject]@{ Status='PARTIALLY_OBSERVED'; Items=$items; DependencyFindings=$findings }
}

function Get-LabEvaluationWindowsLicenseObservation {
    param([Parameter(Mandatory)]$Snapshot)

    $unavailable = [pscustomobject]@{ Status='NOT_OBSERVED'; LicenseState=$null; ObservedAt=$null; EvaluationExpiresAt=$null }
    $vmId = [guid]::Empty
    if (-not $IsWindows -or $Snapshot.Binding.Run.state -cne 'RUNNING' -or
        -not [guid]::TryParseExact([string]$Snapshot.Instance.vmId, 'D', [ref]$vmId) -or $vmId -eq [guid]::Empty) {
        return $unavailable
    }
    $startedAt = [datetime]::UtcNow
    try {
        $license = Get-HyperVWindowsSlotLicenseStatus -RunId $Snapshot.Binding.Run.runId -StateRoot $Snapshot.Binding.StateRoot `
            -ExpectedVmId $vmId -ExpectedScopeId $Snapshot.Binding.Run.scopeId -ExpectedInstanceId $Snapshot.Instance.id `
            -TimeoutSeconds 30 -BoundReadOnly 3>$null 4>$null 5>$null 6>$null
    }
    catch {
        if ($_.Exception.Message -cin @('HYPERV_WINDOWS_LICENSE_READ_BINDING_CHANGED', 'HYPERV_LAB_EXPECTED_VM_ID_MISMATCH',
            'HYPERV_LAB_EXPECTED_VM_RUNTIME_MISMATCH', 'HYPERV_GUEST_VM_ID_MISMATCH')) {
            throw 'EVALUATION_REFRESH_BINDING_CHANGED'
        }
        return $unavailable
    }
    $finishedAt = [datetime]::UtcNow
    $observedAt = ConvertFrom-LabSqlGuestEvaluationEvidenceUtcTimestamp -Value $license.ObservedAt
    if ($license.RunId -cne $Snapshot.Binding.Run.runId -or -not $observedAt -or
        $observedAt -lt $startedAt.AddSeconds(-30) -or $observedAt -gt $finishedAt.AddSeconds(30)) { return $unavailable }

    $expiry = $null
    switch -CaseSensitive ($license.State) {
        'LICENSED' { if ($license.LicenseStatus -ne 1) { return $unavailable } }
        'EVALUATION_ACTIVE' {
            if ($license.LicenseStatus -ne 1) { return $unavailable }
            $expiry = ConvertFrom-LabSqlGuestEvaluationEvidenceUtcTimestamp -Value $license.EvaluationEndDate
            if (-not $expiry -and -not $license.EvaluationEndDate) {
                $expiry = ConvertFrom-LabSqlGuestEvaluationEvidenceUtcTimestamp -Value $license.EvaluationExpiresAt
            }
            if (-not $expiry -or $expiry -le $observedAt) { return $unavailable }
        }
        'EVALUATION_EXPIRED' {
            $expiry = ConvertFrom-LabSqlGuestEvaluationEvidenceUtcTimestamp -Value $license.EvaluationEndDate
            if (-not $expiry -or $expiry -gt $observedAt) { return $unavailable }
        }
        default { return $unavailable }
    }
    [pscustomobject]@{ Status='OBSERVED'; LicenseState=[string]$license.State; ObservedAt=$observedAt.ToString('o')
        EvaluationExpiresAt=if($expiry){$expiry.ToString('o')}else{$null} }
}

function New-LabEvaluationRefreshPlan {
    param([string]$RunId,[string]$InstanceId,[string]$DataRoot,[string]$Mode,[switch]$ObserveSqlSource,[switch]$ObserveWindowsLicense,
        [string]$ExpectedSnapshotDigest,[string]$TargetRunId,[string]$TargetInstanceId,[string]$ExpectedTargetSnapshotDigest,
        [switch]$ObserveTargetWindowsLicense)
    if ($ObserveSqlSource -and $Mode -cne 'STATEFUL_MIGRATION') { throw 'EVALUATION_REFRESH_SQL_SOURCE_MODE_INVALID' }
    $hasTarget = $TargetRunId -or $TargetInstanceId -or $ExpectedTargetSnapshotDigest -or $ObserveTargetWindowsLicense
    if ($hasTarget -and ($Mode -cne 'STATEFUL_MIGRATION' -or -not $TargetRunId -or -not $TargetInstanceId -or
        $RunId -ieq $TargetRunId)) { throw 'EVALUATION_REFRESH_TARGET_SELECTION_INVALID' }
    try {
        $snapshot=Read-LabEvaluationRefreshSnapshot -RunId $RunId -InstanceId $InstanceId -DataRoot $DataRoot
    } catch {
        if($_.Exception.Message-cin@('EVALUATION_REFRESH_SCOPE_UNSUPPORTED','EVALUATION_REFRESH_BINDING_INVALID','EVALUATION_REFRESH_BINDING_CHANGED')){throw $_.Exception.Message}
        throw 'EVALUATION_REFRESH_BINDING_UNAVAILABLE'
    }
    if ($ExpectedSnapshotDigest -and $snapshot.Digest -cne $ExpectedSnapshotDigest) { throw 'EVALUATION_REFRESH_BINDING_CHANGED' }
    $targetSnapshot = $null
    if ($hasTarget) {
        try { $targetSnapshot = Read-LabEvaluationRefreshSnapshot -RunId $TargetRunId -InstanceId $TargetInstanceId -DataRoot $DataRoot }
        catch { throw 'EVALUATION_REFRESH_TARGET_UNAVAILABLE' }
        if ($ExpectedTargetSnapshotDigest -and $targetSnapshot.Digest -cne $ExpectedTargetSnapshotDigest) {
            throw 'EVALUATION_REFRESH_BINDING_CHANGED'
        }
        $sourceVmId = [guid]::Empty
        $targetVmId = [guid]::Empty
        if ($targetSnapshot.Binding.StateRoot -cne $snapshot.Binding.StateRoot -or
            $targetSnapshot.Binding.Run.scopeId -ceq $snapshot.Binding.Run.scopeId -or
            -not [guid]::TryParseExact([string]$snapshot.Instance.vmId, 'D', [ref]$sourceVmId) -or
            -not [guid]::TryParseExact([string]$targetSnapshot.Instance.vmId, 'D', [ref]$targetVmId) -or
            $sourceVmId -eq [guid]::Empty -or $targetVmId -eq [guid]::Empty -or $sourceVmId -eq $targetVmId) {
            throw 'EVALUATION_REFRESH_TARGET_SELECTION_INVALID'
        }
        if ($snapshot.Instance.sqlVersion -cne '2025' -or $targetSnapshot.Instance.sqlVersion -cne '2025') {
            throw 'EVALUATION_REFRESH_TARGET_SCOPE_UNSUPPORTED'
        }
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
    $windowsObservation = if ($ObserveWindowsLicense) { Get-LabEvaluationWindowsLicenseObservation -Snapshot $snapshot }
    $blockers=[Collections.Generic.List[string]]::new()
    if (-not $windowsObservation -or $windowsObservation.Status -cne 'OBSERVED') { $blockers.Add('CURRENT_WINDOWS_LICENSE_PROOF_NOT_AVAILABLE') }
    elseif ($windowsObservation.LicenseState -ceq 'EVALUATION_EXPIRED') { $blockers.Add('WINDOWS_EVALUATION_EXPIRED') }
    if($sql.EvidenceStatus-cnotin@('CURRENT','NOT_EVALUATION')){$blockers.Add('SQL_EVALUATION_EVIDENCE_REQUIRED')}
    $steps=switch -CaseSensitive ($Mode) {
        'FREE_SLOT_REPLACEMENT' {$blockers.Add('SLOT_MEMBERSHIP_AND_REPLACEMENT_TARGET_NOT_ASSESSED');@('Freien Slot und getrennte Restlaufzeiten über den bestehenden Poolvertrag prüfen.','Neue Medien und Zielbindung separat bestätigen; ein Clone setzt keine Evaluation zurück.')}
        'RECONSTRUCT_LAB' {$blockers.Add('DECLARATIVE_RECONSTRUCTION_AND_DATA_DISPOSABILITY_NOT_VERIFIED');@('Deklarative Rekonstruktion sowie entbehrlichen Zustand und erforderliche Datenübernahme klassifizieren.','Neue Umgebung separat planen; Gleichwertigkeit und Rückfall vor Änderungen nachweisen.')}
        'STATEFUL_MIGRATION' {$blockers.Add('FULL_INSTANCE_INVENTORY_NOT_AVAILABLE');$blockers.Add('EQUIVALENCE_CUTOVER_AND_ROLLBACK_NOT_VERIFIED');@('Datenbank-, Serverobjekt-, Schlüssel- und externe Abhängigkeiten getrennt inventarisieren.','DATABASE_FILES_ONLY ist kein vollständiger Instanztransfer. Cutover und Rückfall nach Zielschreibzugriffen separat planen.')}
        default {throw 'EVALUATION_REFRESH_MODE_INVALID'}
    }
    $sourceInventory = if ($ObserveSqlSource) { Get-LabEvaluationSqlSourceInventory -Snapshot $snapshot }
    $targetWindows = if ($ObserveTargetWindowsLicense) { Get-LabEvaluationWindowsLicenseObservation -Snapshot $targetSnapshot }
    try {$fresh=Read-LabEvaluationRefreshSnapshot -RunId $RunId -InstanceId $InstanceId -DataRoot $DataRoot}
    catch {throw 'EVALUATION_REFRESH_BINDING_CHANGED'}
    if($fresh.Digest-cne$snapshot.Digest){throw 'EVALUATION_REFRESH_BINDING_CHANGED'}
    if ($targetSnapshot) {
        try { $freshTarget = Read-LabEvaluationRefreshSnapshot -RunId $TargetRunId -InstanceId $TargetInstanceId -DataRoot $DataRoot }
        catch { throw 'EVALUATION_REFRESH_BINDING_CHANGED' }
        if ($freshTarget.Digest -cne $targetSnapshot.Digest) { throw 'EVALUATION_REFRESH_BINDING_CHANGED' }
    }
    $result = [pscustomobject]@{ContractVersion='SqlServerLab.EvaluationRefreshPlan/1.0';Mode=$Mode;Status='BLOCKED';
        RunId=$RunId;ScopeId=$snapshot.Binding.Run.scopeId;InstanceId=$InstanceId;Provider='hyperv';
        ObservedContentSha256=$snapshot.Digest;Evaluations=@($windows,$sqlProjection);Blockers=@($blockers);NextSteps=@($steps);
        FullInstanceMigration=$false;EquivalenceStatus='NOT_VERIFIED';SqlReadiness='NOT_CHECKED';
        ExecutionSupported=$false;MutationAllowed=$false;Actions=@();TransferAuthority='NONE';GeneratedAt=$now.ToString('o')}
    if ($ObserveSqlSource) { $result | Add-Member -NotePropertyName SqlSourceInventory -NotePropertyValue $sourceInventory }
    if ($ObserveWindowsLicense) { $result | Add-Member -NotePropertyName WindowsLicenseObservation -NotePropertyValue $windowsObservation }
    if ($targetSnapshot) {
        $targetObserved = $null -ne $targetWindows -and $targetWindows.Status -ceq 'OBSERVED'
        $windowsCheck = if (-not $targetObserved) { 'TARGET_WINDOWS_LICENSE_NOT_VERIFIED' }
            elseif ($targetWindows.LicenseState -ceq 'EVALUATION_EXPIRED') { 'TARGET_WINDOWS_EVALUATION_EXPIRED' }
            else { 'TARGET_WINDOWS_LICENSE_OBSERVED' }
        $targetAssessment = [pscustomobject]@{
            Status=$(if ($targetObserved) { 'WINDOWS_LICENSE_OBSERVED' } else { 'METADATA_ONLY' })
            RunId=$targetSnapshot.Binding.Run.runId; ScopeId=$targetSnapshot.Binding.Run.scopeId
            InstanceId=$targetSnapshot.Instance.id; RegisteredState=$targetSnapshot.Binding.Run.state
            ObservedContentSha256=$targetSnapshot.Digest; SqlVersion='2025'
            Checks=@($windowsCheck,'TARGET_SQL_READINESS_NOT_CHECKED','TARGET_STORAGE_AND_TRANSFER_NOT_VERIFIED')
        }
        if ($ObserveTargetWindowsLicense) {
            $targetAssessment | Add-Member -NotePropertyName WindowsLicenseObservation -NotePropertyValue $targetWindows
        }
        $result | Add-Member -NotePropertyName TargetAssessment -NotePropertyValue $targetAssessment
    }
    return $result
}
