# Test-only independent oracle for the public observation. It never calls the
# product projector and does not interpret private authority or export records.
function Assert-OwnedTlsLiveObservation {
    param([object]$Observation,[object]$Expected,[object]$Lab,[string]$Provider,
        [DateTimeOffset]$Before,[DateTimeOffset]$After)
    $fields=@('ContractVersion','Status','RunId','InstanceId','Provider','SqlVersion','Patch','SqlBuild',
        'Encrypt','TrustServerCertificate','QualifiedAtUtc','ObservedAtUtc','ExpiresAtUtc',
        'ClientChecks','Evidence','WireCertificateFingerprint')
    if($Observation -isnot [pscustomobject] -or
        (@($Observation.PSObject.Properties.Name|Sort-Object) -join '|') -cne (($fields|Sort-Object) -join '|')){
        throw 'TLS_LIVE_ACCEPTANCE_CLOSED_RESULT_REQUIRED'
    }
    Assert-OwnedTlsAcceptanceSelection -Expected $Expected -Qualification $Observation
    if($Observation.ContractVersion -cne 'SqlServerLab.TlsLiveQualificationResult/0.1' -or
        $Observation.Status -cne 'QUALIFIED_AT_OBSERVATION' -or $Observation.RunId -cne $Lab.RunId -or
        $Observation.InstanceId -cne 'primary' -or $Observation.Provider -cne $Provider -or
        $Observation.Encrypt -isnot [bool] -or -not $Observation.Encrypt -or
        $Observation.TrustServerCertificate -isnot [bool] -or $Observation.TrustServerCertificate -or
        (@($Observation.ClientChecks) -join '|') -cne 'SYSTEM_DATA_SQLCLIENT|ODBC_SQLCMD' -or
        $Observation.Evidence -cne 'FRESH_NATIVE_SQLCLIENT_AND_ODBC_SQLCMD' -or
        $Observation.WireCertificateFingerprint -cne 'NOT_OBSERVED'){
        throw 'TLS_LIVE_ACCEPTANCE_OBSERVATION_INVALID'
    }
    $qualified=[DateTimeOffset]::ParseExact($Observation.QualifiedAtUtc,'o',[Globalization.CultureInfo]::InvariantCulture)
    $observed=[DateTimeOffset]::ParseExact($Observation.ObservedAtUtc,'o',[Globalization.CultureInfo]::InvariantCulture)
    $expires=[DateTimeOffset]::ParseExact($Observation.ExpiresAtUtc,'o',[Globalization.CultureInfo]::InvariantCulture)
    if($After -lt $Before -or $qualified -lt $Before -or $observed -lt $qualified -or $observed -gt $After -or
        $expires -le $After -or ($expires-$qualified).TotalMinutes -gt 15){
        throw 'TLS_LIVE_ACCEPTANCE_FRESH_OBSERVATION_REQUIRED'
    }
}

function Assert-OwnedTlsLiveRejected {
    param([string]$RunId,[string]$InstanceId,[string]$StateRoot)
    $message=''
    try{$null=Test-SqlServerLabTlsQualification -RunId $RunId -InstanceId $InstanceId -StateRoot $StateRoot}
    catch{$message=$_.Exception.Message}
    if($message -cne 'TLS_LIVE_QUALIFICATION_REJECTED'){throw 'TLS_LIVE_ACCEPTANCE_REJECTION_REQUIRED'}
}

function Assert-OwnedTlsLiveContinue {
    param([string]$StopFile)
    if($StopFile -and (Test-Path -LiteralPath $StopFile)){throw 'TLS_LIVE_ACCEPTANCE_STOP_REQUESTED'}
}

function Invoke-OwnedTlsLiveQualificationScenario {
    param([object]$Lab,[object]$Expected,[string]$Provider,[string]$EvidenceDirectory,
        [Collections.Generic.List[object]]$Results,[string]$StopFile)
    Assert-OwnedTlsLiveContinue $StopFile
    $before=[DateTimeOffset]::UtcNow
    $first=Test-SqlServerLabTlsQualification -RunId $Lab.RunId -InstanceId primary -StateRoot $Lab.StateRoot
    Assert-OwnedTlsLiveObservation $first $Expected $Lab $Provider $before ([DateTimeOffset]::UtcNow)
    $Results.Add(@{Case='LIVE_EXPLICIT_BOTH_STRICT_STACKS';Status='PASS';StrictClientResults=2})
    [IO.File]::WriteAllText((Join-Path $EvidenceDirectory 'live-first.private.json'),($first|ConvertTo-Json -Depth 4))
    Assert-OwnedTlsLiveContinue $StopFile
    Assert-OwnedTlsLiveRejected -RunId ([guid]::NewGuid().ToString()) -InstanceId primary -StateRoot $Lab.StateRoot
    $Results.Add(@{Case='LIVE_WRONG_RUN_REJECTED';Status='PASS'})
    Assert-OwnedTlsLiveRejected -RunId $Lab.RunId -InstanceId other -StateRoot $Lab.StateRoot
    $Results.Add(@{Case='LIVE_WRONG_INSTANCE_REJECTED';Status='PASS'})
    Assert-OwnedTlsLiveContinue $StopFile
    $stopped=Stop-SqlServerLab -RunId $Lab.RunId -StateRoot $Lab.StateRoot -Force -SkipHostMemoryRelease -Confirm:$false
    if($stopped.Status -cne 'STOPPED' -or $stopped.Errors -gt 0){throw 'TLS_LIVE_ACCEPTANCE_STOP_FAILED'}
    $started=Start-SqlServerLab -RunId $Lab.RunId -StateRoot $Lab.StateRoot
    if($started.Status -cne 'RUNNING' -or $started.Errors -gt 0){throw 'TLS_LIVE_ACCEPTANCE_START_FAILED'}
    Assert-OwnedTlsLiveRejected -RunId $Lab.RunId -InstanceId primary -StateRoot $Lab.StateRoot
    $Results.Add(@{Case='LIVE_RESTART_REJECTED_NO_STALE_SUCCESS';Status='PASS'})
    Assert-OwnedTlsLiveContinue $StopFile
    $rebound=Update-SqlServerLabTlsBinding -RunId $Lab.RunId -InstanceId primary -StateRoot $Lab.StateRoot -Confirm:$false
    if($rebound.Status -cne 'QUALIFIED_METADATA_COMMITTED' -or -not $rebound.BindingUpdated -or
        $rebound.QualificationStatus -cne 'QUALIFIED' -or $rebound.SqlBuild -cne $Expected.SqlBuild -or
        $rebound.Provider -cne $Provider -or -not $rebound.Encrypt -or $rebound.TrustServerCertificate){
        throw 'TLS_LIVE_ACCEPTANCE_REBIND_FAILED'
    }
    Assert-OwnedTlsLiveContinue $StopFile
    $before=[DateTimeOffset]::UtcNow
    $fresh=Test-SqlServerLabTlsQualification -RunId $Lab.RunId -InstanceId primary -StateRoot $Lab.StateRoot
    Assert-OwnedTlsLiveObservation $fresh $Expected $Lab $Provider $before ([DateTimeOffset]::UtcNow)
    if($fresh.QualifiedAtUtc -ceq $first.QualifiedAtUtc){throw 'TLS_LIVE_ACCEPTANCE_CACHED_RESULT_REJECTED'}
    $Results.Add(@{Case='LIVE_REBOUND_BOTH_STRICT_STACKS';Status='PASS';StrictClientResults=2})
    [IO.File]::WriteAllText((Join-Path $EvidenceDirectory 'live-rebound.private.json'),($fresh|ConvertTo-Json -Depth 4))
}
