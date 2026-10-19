function Set-SqlServerLabFeature {
    <#
    .SYNOPSIS
        Fügt Volltext oder FILESTREAM einer eigenen laufenden SQL-Instanz hinzu oder entfernt die Funktion.
    .DESCRIPTION
        Volltext installiert/entfernt FULLTEXT beziehungsweise das versionsgleiche
        mssql-server-fts-Paket. FILESTREAM schaltet unter Windows T-SQL-Zugriff
        ein/aus; Linux lehnt Aktivierung vor Mutation ab. Abhängige Datenbanken
        blockieren Removal. SQL wird neu gestartet. Ein unklarer Ausgang bleibt
        journalisiert und wird nicht automatisch wiederholt.
    .PARAMETER RunId
        Eigener laufender Run.
    .PARAMETER InstanceId
        Eindeutige Zielinstanz.
    .PARAMETER Feature
        FullText oder FileStream.
    .PARAMETER Enabled
        true fügt die Funktion hinzu, false entfernt/deaktiviert sie ohne Datenlöschung.
    .PARAMETER SaPassword
        Optionales SQL-Kennwort; andernfalls wird das run-eigene Secret verwendet.
    .PARAMETER GuestCredential
        Optionaler Windows-Gastzugang; andernfalls wird das run-eigene Secret verwendet.
    .PARAMETER MediaRoot
        Verifizierte lokale SQL-Medien für Hyper-V-FULLTEXT-Änderungen.
    .PARAMETER SqlMediaPath
        Optionale SQL-ISO innerhalb des Media Root.
    .PARAMETER StateRoot
        Lokaler State Root.
    .PARAMETER Resume
        Bestätigt ausschließlich einen bereits erreichten Zielzustand nach Antwortverlust; kein Setup-Replay.
    .OUTPUTS
        Verifiziertes Objekt mit RunId, InstanceId, Provider, Feature, Enabled,
        Status, Changed und Build; keine Credentials oder Endpunkte.
    .EXAMPLE
        Set-SqlServerLabFeature -RunId $run.RunId -InstanceId primary -Feature FullText -Enabled $true
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][guid]$RunId,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z][A-Za-z0-9_-]*$')][string]$InstanceId,
        [Parameter(Mandatory)][ValidateSet('FullText','FileStream')][string]$Feature,
        [Parameter(Mandatory)][bool]$Enabled,
        [securestring]$SaPassword,[pscredential]$GuestCredential,[string]$MediaRoot,[string]$SqlMediaPath,[string]$StateRoot,[switch]$Resume
    )
    $Feature=if($Feature -ieq 'FullText'){'FullText'}else{'FileStream'}
    if(-not $StateRoot){$StateRoot=Get-LabStateRoot}
    $environment=Get-LabEnvironmentResourceContext -RunId $RunId -StateRoot $StateRoot
    $targets=@($environment.Connection.instances|Where-Object id -ceq $InstanceId)
    if($targets.Count -ne 1){throw 'SQL_FEATURE_RUNNING_INSTANCE_REQUIRED'}
    $field=if($Feature -eq 'FullText'){'fullText'}else{'fileStream'}
    $null=Resolve-LabSqlFeatureIntent -Intent ([pscustomobject]@{$field=$Enabled}) -Provider ([string]$targets[0].provider) -SqlVersion (Get-LabSqlFeatureVersion -Instance $targets[0])
    Assert-LabResourceChangeAllowed -RunId $RunId -StateRoot $StateRoot -SqlFeatureOperation
    $mutex=[Threading.Mutex]::new($false,(Get-LabContainerResourceLockName -StateRoot $StateRoot -RunId $RunId))
    $acquired=$false;$journal=$null;$path=$null;$mediaBinding=$null
    try {
        try{$acquired=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$acquired=$true}
        if(-not $acquired){throw 'SQL_FEATURE_OPERATION_BUSY'}
        $context=Get-LabSqlFeatureContext -RunId $RunId -InstanceId $InstanceId -StateRoot $StateRoot -SaPassword $SaPassword -GuestCredential $GuestCredential
        if($context.Run.metadata.desiredState){
            $persisted=Get-LabPersistedDesiredState -RunId $RunId -StateRoot $StateRoot
            if($persisted.Status -cne 'VALID'){throw 'SQL_FEATURE_DESIRED_STATE_INVALID'}
        }
        $existingIntents=$context.Run.metadata.sqlFeatureIntents
        if($null -ne $existingIntents -and $existingIntents -isnot [pscustomobject] -and $existingIntents -isnot [Collections.IDictionary]){throw 'SQL_FEATURE_INTENT_STATE_INVALID'}
        $field=if($Feature -eq 'FullText'){'fullText'}else{'fileStream'}
        $null=Resolve-LabSqlFeatureIntent -Intent ([pscustomobject]@{$field=$Enabled}) -Provider $context.Provider -SqlVersion $context.SqlVersion
        $path=Join-Path $context.RunDirectory ("sql-feature-$InstanceId-$Feature.json")
        foreach($name in @('container-reconcile-journal.json','container-autostart-journal.json','external-runtime-refresh.json','hyperv-sql-configuration-reconcile.local.journal.json','hyperv-sql-port-reconcile.local.journal.json','hyperv-resource-reconcile.local.journal.json','hyperv-storage-reconcile.local.journal.json','hyperv-external-runtime-reconcile.local.journal.json')){
            $otherPath=Join-Path $context.RunDirectory $name
            if(Test-Path -LiteralPath $otherPath -PathType Leaf){
                $other=Get-Content -LiteralPath $otherPath -Raw|ConvertFrom-Json
                if($other.Status -cnotin @('COMPLETED','ROLLED_BACK')){throw 'SQL_FEATURE_OTHER_RECOVERY_PENDING'}
            }
        }
        foreach($operationFile in @(Get-ChildItem -LiteralPath $context.RunDirectory -Filter 'sql-feature-*.json' -File)){
            if($operationFile.FullName -eq $path){continue}
            $operation=Get-Content -LiteralPath $operationFile.FullName -Raw|ConvertFrom-Json
            if($operation.Contract -cne 'SqlServerLab.SqlFeatureOperation/1.0' -or $operation.RunId -cne $RunId.ToString() -or $operation.ScopeId -cne [string]$context.Run.scopeId){throw 'SQL_FEATURE_JOURNAL_BINDING_INVALID'}
            if($operation.Status -cne 'COMPLETED'){throw 'SQL_FEATURE_RECOVERY_REQUIRED_NO_REPLAY'}
        }
        if(Test-Path -LiteralPath $path){
            $previous=Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            if($previous.Contract -cne 'SqlServerLab.SqlFeatureOperation/1.0' -or $previous.RunId -cne $RunId.ToString() -or $previous.ScopeId -cne [string]$context.Run.scopeId -or $previous.Provider -cne $context.Provider -or $previous.Feature -cne $Feature -or $previous.InstanceId -cne $InstanceId){throw 'SQL_FEATURE_JOURNAL_BINDING_INVALID'}
            if($previous.Status -cne 'COMPLETED'){
                if($previous.RuntimeId -cne $context.RuntimeId){throw 'SQL_FEATURE_JOURNAL_BINDING_INVALID'}
                if(-not $Resume -or $previous.Enabled -isnot [bool] -or $previous.Enabled -ne $Enabled){throw 'SQL_FEATURE_RECOVERY_REQUIRED_NO_REPLAY'}
                $journal=$previous
            }
        }
        $before=Get-LabSqlFeatureObservation -Context $context
        if($journal -and $journal.Build -cne $before.Build){throw 'SQL_FEATURE_RECOVERY_BUILD_CHANGED_NO_REPLAY'}
        $matches=if($Feature -eq 'FullText'){[bool]$before.FullText -eq $Enabled}else{([int]$before.FileStream -gt 0) -eq $Enabled}
        if($Resume -and -not $matches){throw 'SQL_FEATURE_RECOVERY_TARGET_NOT_REACHED_NO_REPLAY'}
        if(-not $PSCmdlet.ShouldProcess("$RunId/$InstanceId","$Feature = $Enabled; SQL-Neustart bei Änderung")){return}
        if(-not $matches){
            if(-not $Enabled){Assert-LabSqlFeatureRemovalSafe -Context $context -Feature $Feature}
            if($context.Provider -eq 'hyperv'){Assert-LabWindowsPoolMutationAllowed -RunId $RunId -StateRoot $StateRoot -InvalidateEvidence}
            if($context.Provider -eq 'hyperv' -and $Feature -eq 'FullText'){$mediaBinding=Open-LabSqlFeatureMedia -Context $context -MediaRoot $MediaRoot -SqlMediaPath $SqlMediaPath}
            $journal=[pscustomobject]@{Contract='SqlServerLab.SqlFeatureOperation/1.0';RunId=$RunId.ToString();ScopeId=[string]$context.Run.scopeId;InstanceId=$InstanceId;Provider=$context.Provider;RuntimeId=$context.RuntimeId;Feature=$Feature;Enabled=$Enabled;Build=$before.Build;Status='MUTATION_PENDING';Recovery='OBSERVE_ONLY_NO_REPLAY'}
            Write-LabArtifactJsonAtomic -Path $path -InputObject $journal
            $fresh=Get-LabSqlFeatureContext -RunId $RunId -InstanceId $InstanceId -StateRoot $StateRoot -SaPassword $SaPassword -GuestCredential $GuestCredential
            if($fresh.RuntimeId -cne $context.RuntimeId){throw 'SQL_FEATURE_RUNTIME_CHANGED'}
            if($context.Provider -in @('docker','podman')){Invoke-LabContainerFullTextChange -Context $context -Enabled $Enabled}
            elseif($Feature -eq 'FileStream'){Invoke-LabHyperVFileStreamChange -Context $context -Enabled $Enabled}
            else{Invoke-LabHyperVFullTextChange -Context $context -Enabled $Enabled -MediaBinding $mediaBinding}
            $afterContext=Get-LabSqlFeatureContext -RunId $RunId -InstanceId $InstanceId -StateRoot $StateRoot -SaPassword $SaPassword -GuestCredential $GuestCredential
            if($afterContext.RuntimeId -cne $context.RuntimeId){throw 'SQL_FEATURE_RUNTIME_CHANGED'}
            $after=Get-LabSqlFeatureObservation -Context $afterContext -WaitSeconds 90
            $matches=if($Feature -eq 'FullText'){[bool]$after.FullText -eq $Enabled}else{([int]$after.FileStream -gt 0) -eq $Enabled}
            if(-not $matches -or $after.Build -cne $before.Build){throw 'SQL_FEATURE_POSTCONDITION_FAILED'}
        }
        $environment=Get-LabEnvironmentResourceContext -RunId $RunId -StateRoot $StateRoot
        if(-not $environment.Run.metadata.PSObject.Properties['sqlFeatureIntents']){$environment.Run.metadata|Add-Member -NotePropertyName sqlFeatureIntents -NotePropertyValue ([pscustomobject]@{})}
        $intents=$environment.Run.metadata.sqlFeatureIntents
        if(-not $intents.PSObject.Properties[$InstanceId]){$intents|Add-Member -NotePropertyName $InstanceId -NotePropertyValue ([pscustomobject]@{})}
        $intents.$InstanceId|Add-Member -NotePropertyName $field -NotePropertyValue $Enabled -Force
        $desired=@($environment.Run.metadata.desiredState.Instances|Where-Object Id -ceq $InstanceId)
        if($environment.Run.metadata.desiredState){
            if($desired.Count -ne 1){throw 'SQL_FEATURE_DESIRED_INSTANCE_INVALID'}
            if(-not $desired[0].Intents.SqlFeatures){$desired[0].Intents|Add-Member -NotePropertyName SqlFeatures -NotePropertyValue ([pscustomobject]@{}) -Force}
            $desired[0].Intents.SqlFeatures|Add-Member -NotePropertyName $field -NotePropertyValue $Enabled -Force
        }
        Write-LabArtifactJsonAtomic -Path (Join-Path $context.RunDirectory 'run-state.json') -InputObject $environment.Run
        if($journal){$journal.Status='COMPLETED';$journal.Recovery='NOT_REQUIRED';Write-LabArtifactJsonAtomic -Path $path -InputObject $journal}
        [pscustomobject]@{RunId=$RunId.ToString();InstanceId=$InstanceId;Provider=$context.Provider;Feature=$Feature;Enabled=$Enabled;Status='VERIFIED';Changed=($null -ne $journal -and -not $Resume);Build=$before.Build}
    } catch {
        if($journal -and $path -and -not $WhatIfPreference){$journal.Status='RECOVERY_REQUIRED';try{Write-LabArtifactJsonAtomic -Path $path -InputObject $journal}catch{Write-Warning 'SQL_FEATURE_RECOVERY_JOURNAL_WRITE_FAILED'}}
        throw
    } finally {if($mediaBinding){$mediaBinding.Handle.Dispose()};if($acquired){$mutex.ReleaseMutex()};$mutex.Dispose()}
}
