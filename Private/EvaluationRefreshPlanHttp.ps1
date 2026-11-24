# Dedicated read-only browser boundary for the existing evaluation decision.
function Assert-LabEvaluationRefreshHttpShape {
    param($Value,[string[]]$Names)
    if($Value-isnot[pscustomobject]-or@($Value.PSObject.Properties).Count-ne$Names.Count){throw 'EVALUATION_REFRESH_HTTP_INVALID'}
    foreach($name in $Value.PSObject.Properties.Name){if($name-cnotin$Names){throw 'EVALUATION_REFRESH_HTTP_INVALID'}}
}

function Assert-LabEvaluationRefreshHttpSelection {
    param($Selection)
    Assert-LabEvaluationRefreshHttpShape $Selection @('RunId','ScopeId','InstanceId','State','Digest')
    if($Selection.RunId-isnot[string]-or$Selection.ScopeId-isnot[string]-or-not(Test-LabDiagnosticGuid $Selection.RunId)-or-not(Test-LabDiagnosticGuid $Selection.ScopeId)-or
        $Selection.InstanceId-isnot[string]-or$Selection.InstanceId-cnotmatch'^[A-Za-z][A-Za-z0-9_-]{0,63}$'-or
        $Selection.State-isnot[string]-or$Selection.State-cnotin@('RUNNING','STOPPED')-or
        $Selection.Digest-isnot[string]-or$Selection.Digest-cnotmatch'^[a-f0-9]{64}$'){throw 'EVALUATION_REFRESH_HTTP_INVALID'}
}

function Assert-LabEvaluationRefreshHttpCurrentSelection {
    param($Selection, [string]$DataRoot)
    $fresh = Read-LabEvaluationRefreshSnapshot -RunId $Selection.RunId -InstanceId $Selection.InstanceId -DataRoot $DataRoot
    if ($fresh.Digest -cne $Selection.Digest -or $fresh.Binding.Run.scopeId -cne $Selection.ScopeId -or
        $fresh.Binding.Run.state -cne $Selection.State) { throw 'EVALUATION_REFRESH_BINDING_CHANGED' }
}

function ConvertTo-LabEvaluationRefreshBrowserPlan {
    param($Plan,$Selection,[string]$Mode,$Target)
    if($Plan.ContractVersion-cne'SqlServerLab.EvaluationRefreshPlan/1.0'-or$Plan.Status-cne'BLOCKED'-or$Plan.Mode-cne$Mode-or
        $Plan.RunId-cne$Selection.RunId-or$Plan.ScopeId-cne$Selection.ScopeId-or$Plan.InstanceId-cne$Selection.InstanceId-or
        $Plan.ObservedContentSha256-cne$Selection.Digest-or$Plan.Provider-cne'hyperv'-or
        $Plan.MutationAllowed-isnot[bool]-or$Plan.MutationAllowed-or$Plan.ExecutionSupported-isnot[bool]-or$Plan.ExecutionSupported-or
        $Plan.FullInstanceMigration-isnot[bool]-or$Plan.FullInstanceMigration-or$Plan.EquivalenceStatus-cne'NOT_VERIFIED'-or
        $Plan.SqlReadiness-cne'NOT_CHECKED'-or$Plan.TransferAuthority-cne'NONE'-or$Plan.Actions-isnot[array]-or$Plan.Actions.Count-ne0-or
        $Plan.Evaluations-isnot[array]-or$Plan.Evaluations.Count-ne2){throw 'EVALUATION_REFRESH_HTTP_INVALID'}
    $evaluations=@(for($index=0;$index-lt2;$index++){
        $item=$Plan.Evaluations[$index]
        $component=if($index-eq0){'Windows'}else{'SqlServer'}
        $sources=if($index-eq0){@('PERSISTED_WINDOWS_ACTIVATION','PERSISTED_WINDOWS_ACTIVATION_MISSING_OR_INVALID')}else{@('SQL_GUEST_OBSERVED','SQL_GUEST_NO_DEADLINE','EVIDENCE_MISSING','EVIDENCE_INVALID')}
        $statuses=if($index-eq0){@('HISTORICAL_METADATA')}else{@('CURRENT','EVIDENCE_MISSING','EVIDENCE_INVALID','EVIDENCE_STALE','NOT_EVALUATION','DEADLINE_UNKNOWN')}
        if($item.Component-cne$component-or$item.Status-cnotin@('OK','WARNING','CRITICAL','EXPIRED','UNKNOWN','NOT_APPLICABLE')-or
            $item.DeadlineSource-cnotin$sources-or$item.EvidenceStatus-cnotin$statuses){throw 'EVALUATION_REFRESH_HTTP_INVALID'}
        if($index-eq0-and($item.FreshLicenseProof-isnot[bool]-or$item.FreshLicenseProof)){throw 'EVALUATION_REFRESH_HTTP_INVALID'}
        if($index-eq1-and$item.SqlReadiness-cne'NOT_CHECKED'){throw 'EVALUATION_REFRESH_HTTP_INVALID'}
        $expiry=$item.EvaluationExpiresAt
        if($null-ne$expiry-and($expiry-isnot[string]-or$expiry-cnotmatch'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{7}Z$'-or
            $null-eq(ConvertFrom-LabSqlGuestEvaluationEvidenceUtcTimestamp -Value $expiry))){throw 'EVALUATION_REFRESH_HTTP_INVALID'}
        if($null-ne$item.DaysRemaining-and($item.DaysRemaining-isnot[int]-or$item.DaysRemaining-lt0)){throw 'EVALUATION_REFRESH_HTTP_INVALID'}
        [pscustomobject]@{Component=$component;Status=$item.Status;DeadlineSource=$item.DeadlineSource;EvidenceStatus=$item.EvidenceStatus;
            EvaluationExpiresAt=$expiry;DaysRemaining=$item.DaysRemaining}
    })
    $allowed=@('CURRENT_WINDOWS_LICENSE_PROOF_NOT_AVAILABLE','SQL_EVALUATION_EVIDENCE_REQUIRED','SLOT_MEMBERSHIP_AND_REPLACEMENT_TARGET_NOT_ASSESSED',
        'DECLARATIVE_RECONSTRUCTION_AND_DATA_DISPOSABILITY_NOT_VERIFIED','FULL_INSTANCE_INVENTORY_NOT_AVAILABLE','EQUIVALENCE_CUTOVER_AND_ROLLBACK_NOT_VERIFIED')
    if($Plan.Blockers-isnot[array]-or$Plan.Blockers.Count-lt2-or$Plan.Blockers.Count-gt4){throw 'EVALUATION_REFRESH_HTTP_INVALID'}
    foreach($code in $Plan.Blockers){if($code-isnot[string]-or$code-cnotin$allowed){throw 'EVALUATION_REFRESH_HTTP_INVALID'}}
    # Browser guidance is fixed, never arbitrary text from metadata or an exception.
    $steps=switch -CaseSensitive ($Mode){
        'FREE_SLOT_REPLACEMENT' {@('Freien Slot und getrennte Restlaufzeiten prüfen.','Neue Medien und Zielbindung separat bestätigen; ein Clone erneuert keine Evaluation.')}
        'RECONSTRUCT_LAB' {@('Deklarative Rekonstruktion und entbehrlichen Zustand klären.','Datenübernahme, Gleichwertigkeit und Rückfall separat nachweisen.')}
        'STATEFUL_MIGRATION' {@('Serverobjekte, Schlüssel und externe Abhängigkeiten getrennt inventarisieren.','DATABASE_FILES_ONLY ist kein vollständiger Instanztransfer; Cutover und Rückfall fehlen.')}
    }
    $result = [pscustomobject]@{ContractVersion='SqlServerLab.EvaluationRefreshBrowser/1.0';Status='BLOCKED';Mode=$Mode;
        RunId=$Selection.RunId;ScopeId=$Selection.ScopeId;InstanceId=$Selection.InstanceId;Evaluations=$evaluations;Blockers=@($Plan.Blockers);NextSteps=@($steps);
        SqlReadiness='NOT_CHECKED';FreshWindowsLicenseProof=$false;FullInstanceMigration=$false;EquivalenceStatus='NOT_VERIFIED';TransferAuthority='NONE';
        Actions=@();MutationAllowed=$false;ExecutionSupported=$false}
    if ($Target) {
        $view = $Plan.TargetAssessment
        $checks = @('TARGET_WINDOWS_LICENSE_NOT_VERIFIED','TARGET_SQL_READINESS_NOT_CHECKED','TARGET_STORAGE_AND_TRANSFER_NOT_VERIFIED')
        if ($view.Status -cne 'METADATA_ONLY' -or $view.RunId -cne $Target.RunId -or $view.ScopeId -cne $Target.ScopeId -or
            $view.InstanceId -cne $Target.InstanceId -or $view.RegisteredState -cne $Target.State -or
            $view.ObservedContentSha256 -cne $Target.Digest -or $view.SqlVersion -cne '2025' -or
            ($view.Checks -join ',') -cne ($checks -join ',')) { throw 'EVALUATION_REFRESH_BINDING_CHANGED' }
        $result | Add-Member -NotePropertyName TargetAssessment -NotePropertyValue ([pscustomobject]@{
            Status='METADATA_ONLY'; RunId=$Target.RunId; ScopeId=$Target.ScopeId; InstanceId=$Target.InstanceId
            RegisteredState=$Target.State; ObservedContentSha256=$Target.Digest; SqlVersion='2025'; Checks=$checks
        })
    }
    return $result
}

function Invoke-LabEvaluationRefreshHttpRequest {
    [CmdletBinding()]param([Parameter(Mandatory)]$Request)
    try {
        if($Request.HttpMethod-cne'POST'-or$Request.ContentType-notmatch'^application/json(?:;|$)'){throw 'EVALUATION_REFRESH_HTTP_INVALID'}
        $origin=[string]$Request.Headers['Origin']
        if($origin-and$origin-cne$Request.Url.GetLeftPart([UriPartial]::Authority)){throw 'EVALUATION_REFRESH_HTTP_INVALID'}
        $reader=[IO.StreamReader]::new($Request.InputStream,$Request.ContentEncoding)
        try{$buffer=[char[]]::new(16385);$length=$reader.ReadBlock($buffer,0,$buffer.Length);if($length-gt16384){throw 'EVALUATION_REFRESH_HTTP_INVALID'};$text=[string]::new($buffer,0,$length)}finally{$reader.Dispose()}
        $options=[Text.Json.JsonDocumentOptions]::new();$options.MaxDepth=12
        $document=[Text.Json.JsonDocument]::Parse($text,$options)
        try{
            $pending=[Collections.Generic.Stack[Text.Json.JsonElement]]::new();$pending.Push($document.RootElement);$nodes=0
            while($pending.Count){
                if(++$nodes-gt256){throw 'EVALUATION_REFRESH_HTTP_INVALID'};$element=$pending.Pop()
                if($element.ValueKind-eq[Text.Json.JsonValueKind]::Object){
                    $keys=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
                    foreach($property in $element.EnumerateObject()){if(-not$keys.Add($property.Name)){throw 'EVALUATION_REFRESH_HTTP_INVALID'};$pending.Push($property.Value)}
                }elseif($element.ValueKind-eq[Text.Json.JsonValueKind]::Array){foreach($child in $element.EnumerateArray()){$pending.Push($child)}}
            }
        }finally{$document.Dispose()}
        $payload=$text|ConvertFrom-Json -Depth 12 -ErrorAction Stop
        if($payload-isnot[pscustomobject]-or$payload.Action-cnotin@('Read','Preview')-or$payload.DataRoot-isnot[string]-or-not$payload.DataRoot-or$payload.DataRoot.Length-gt2048){throw 'EVALUATION_REFRESH_HTTP_INVALID'}
        $names=if($payload.Action-ceq'Read'){@('Action','DataRoot')}else{@('Action','DataRoot','Selection','Mode')}
        $hasTarget = $null -ne $payload.PSObject.Properties['Target']
        if ($hasTarget -and $payload.Action -ceq 'Preview' -and $payload.Mode -ceq 'STATEFUL_MIGRATION') { $names += 'Target' }
        Assert-LabEvaluationRefreshHttpShape $payload $names
        $root=Assert-LabDiagnosticPath -Path $payload.DataRoot
        if($payload.Action-ceq'Read'){
            $runs=@(Get-LabEvaluationRefreshConsoleRuns -DataRoot $root|ForEach-Object{[pscustomobject]@{RunId=$_.RunId;ScopeId=$_.ScopeId;InstanceId=$_.InstanceId;State=$_.State;Digest=$_.Digest}})
            return [pscustomobject]@{ContractVersion='SqlServerLab.EvaluationRefreshBrowser/1.0';Status='METADATA_ONLY';Runs=$runs;
                SqlReadiness='NOT_CHECKED';Actions=@();MutationAllowed=$false;ExecutionSupported=$false}
        }
        $selected=$payload.Selection
        Assert-LabEvaluationRefreshHttpSelection $selected
        if($payload.Mode-isnot[string]-or
            $payload.Mode-cnotin@('FREE_SLOT_REPLACEMENT','RECONSTRUCT_LAB','STATEFUL_MIGRATION')){throw 'EVALUATION_REFRESH_HTTP_INVALID'}
        $planArgs=@{RunId=$selected.RunId; InstanceId=$selected.InstanceId; DataRoot=$root; Mode=$payload.Mode}
        $target = $null
        if ($hasTarget) {
            $target = $payload.Target
            Assert-LabEvaluationRefreshHttpSelection $target
            if ($target.RunId -ceq $selected.RunId -or $target.ScopeId -ceq $selected.ScopeId) { throw 'EVALUATION_REFRESH_TARGET_SELECTION_INVALID' }
            $planArgs.TargetRunId = $target.RunId
            $planArgs.TargetInstanceId = $target.InstanceId
        }
        Assert-LabEvaluationRefreshHttpCurrentSelection $selected $root
        if ($target) { Assert-LabEvaluationRefreshHttpCurrentSelection $target $root }
        $plan=Get-SqlServerLabEvaluationRefreshPlan @planArgs
        ConvertTo-LabEvaluationRefreshBrowserPlan -Plan $plan -Selection $selected -Mode $payload.Mode -Target $target
    }catch{
        $known=@('EVALUATION_REFRESH_HTTP_INVALID','EVALUATION_REFRESH_BINDING_CHANGED','EVALUATION_REFRESH_SCOPE_UNSUPPORTED','EVALUATION_REFRESH_BINDING_INVALID','EVALUATION_REFRESH_INPUT_INVALID','EVALUATION_REFRESH_MODE_INVALID','EVALUATION_REFRESH_BINDING_UNAVAILABLE',
            'EVALUATION_REFRESH_TARGET_SELECTION_INVALID','EVALUATION_REFRESH_TARGET_UNAVAILABLE','EVALUATION_REFRESH_TARGET_SCOPE_UNSUPPORTED')
        if($_.Exception.Message-cin$known){throw $_.Exception.Message};throw 'EVALUATION_REFRESH_BINDING_UNAVAILABLE'
    }
}
