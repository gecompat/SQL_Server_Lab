# Geschlossene Rückgabeprojektion; VM-Antworten und Remotingfelder werden nie durchgereicht.
function ConvertTo-LabSsisExecutionDiagnosticObservation {
    [CmdletBinding()]
    param($Value,[long]$ExecutionId,[long]$ExpectedProjectLsn,[guid]$ExpectedCatalogDatabaseGuid)
    function Assert-SsisExecutionFields($Item,[string[]]$Names){if($null -eq $Item){throw 'INVALID'};foreach($name in $Names){if($null -eq $Item.PSObject.Properties[$name]){throw 'INVALID'}}}
    function ConvertTo-SsisExecutionFileRecords($Items,[bool]$Complete) {
        if($null -eq $Items -or $Items -is [string] -or @($Items).Count -gt 6){throw 'INVALID'}
        $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $output=@(foreach($item in $Items){
            Assert-SsisExecutionFields $item @('Role','Status','FileMajor','FileVersion','Sha256','Machine')
            if($item.Role -isnot [string] -or $item.Role -cnotin @('EXECUTOR','CORE','CONNECTIONS','PIPELINE','LOGGING','EXECUTE_PACKAGE') -or -not $seen.Add($item.Role) -or $item.Status -cnotin @('OBSERVED','MISSING','UNAVAILABLE')){throw 'INVALID'}
            if($item.Status -ceq 'OBSERVED'){
                if($item.FileMajor -isnot [int] -or $item.FileMajor -lt 1 -or $item.FileMajor -gt 65535 -or $item.FileVersion -isnot [string] -or $item.FileVersion -cnotmatch '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' -or $item.FileVersion.Length -gt 64 -or $item.Sha256 -isnot [string] -or $item.Sha256 -cnotmatch '^[A-Fa-f0-9]{64}$' -or $item.Machine -cnotin @('AMD64','I386','OTHER')){throw 'INVALID'}
                if([int]$item.FileVersion.Split('.')[0] -ne $item.FileMajor){throw 'INVALID'}
            }elseif($null -ne $item.FileMajor -or $null -ne $item.FileVersion -or $null -ne $item.Sha256 -or $null -ne $item.Machine){throw 'INVALID'}
            [pscustomobject]@{Role=[string]$item.Role;Status=[string]$item.Status;FileMajor=$item.FileMajor;FileVersion=$item.FileVersion;Sha256=$item.Sha256;Machine=$item.Machine}
        })
        if($Complete -and $output.Count -ne 6){throw 'INVALID'}
        return ,$output
    }
    Assert-SsisExecutionFields $Value @('ContractVersion','Status','ReasonCode','Snapshot','InstalledFiles','Registration','ComRegistration','Worker','ErrorCodes','ErrorCodesTruncated')
    if($Value.ContractVersion -cne 'SqlServerLab.SsisExecutionGuest/1.0' -or $Value.Status -cnotin @('OBSERVED','INCONCLUSIVE') -or $Value.ReasonCode -cnotin @('NONE','SQL_OBSERVATION_UNAVAILABLE','SQL_BINDING_MISMATCH','CAPTURE_FAILED','EVENT_LIMIT') -or $Value.ErrorCodesTruncated -isnot [bool]){throw 'INVALID'}
    $complete=$Value.Status -ceq 'OBSERVED';$snapshot=$null
    if($null -ne $Value.Snapshot){
        $s=$Value.Snapshot;Assert-SsisExecutionFields $s @('ExecutionId','ProjectLsn','CatalogDatabaseGuid','ObservedExecutionStatus','Use32BitRuntime','AuthScheme')
        if($s.ExecutionId -isnot [string] -or $s.ExecutionId -cne $ExecutionId.ToString() -or $s.ProjectLsn -isnot [string] -or $s.ProjectLsn -cne $ExpectedProjectLsn.ToString() -or $s.CatalogDatabaseGuid -isnot [string] -or $s.CatalogDatabaseGuid -cnotmatch '^[A-Fa-f0-9-]{36}$' -or [guid]$s.CatalogDatabaseGuid -ne $ExpectedCatalogDatabaseGuid -or $s.ObservedExecutionStatus -isnot [int] -or $s.ObservedExecutionStatus -notin @(1,2,3,4,5,6,7,8,9) -or $s.Use32BitRuntime -isnot [bool] -or $s.AuthScheme -cnotin @('NTLM','KERBEROS')){throw 'INVALID'}
        $snapshot=[pscustomobject]@{ExecutionId=$s.ExecutionId;ProjectLsn=$s.ProjectLsn;CatalogDatabaseGuid=([guid]$s.CatalogDatabaseGuid).ToString('D');ObservedExecutionStatus=[int]$s.ObservedExecutionStatus;Use32BitRuntime=[bool]$s.Use32BitRuntime;AuthScheme=[string]$s.AuthScheme}
    }
    if(($complete -and ($null -eq $snapshot -or $Value.ReasonCode -cne 'NONE' -or $Value.ErrorCodesTruncated)) -or ((-not $complete) -and $Value.ReasonCode -ceq 'NONE')){throw 'INVALID'}
    $files=ConvertTo-SsisExecutionFileRecords $Value.InstalledFiles $complete
    if($null -eq $Value.Registration -or @($Value.Registration).Count -gt 2 -or $null -eq $Value.ComRegistration -or @($Value.ComRegistration).Count -gt 6){throw 'INVALID'}
    $views=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $registration=@(foreach($item in $Value.Registration){
        Assert-SsisExecutionFields $item @('View','Status','Edition','EditionType')
        if($item.View -cnotin @('X64','X86') -or -not $views.Add([string]$item.View) -or $item.Status -cnotin @('OBSERVED','MISSING','UNAVAILABLE')){throw 'INVALID'}
        foreach($edition in @($item.Edition,$item.EditionType)){if($edition -cnotin @('ENTERPRISE_DEVELOPER','STANDARD_DEVELOPER','DEVELOPER','ENTERPRISE','STANDARD','EVALUATION','UNKNOWN')){throw 'INVALID'}}
        [pscustomobject]@{View=[string]$item.View;Status=[string]$item.Status;Edition=[string]$item.Edition;EditionType=[string]$item.EditionType}
    })
    $pairs=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $com=@(foreach($item in $Value.ComRegistration){
        Assert-SsisExecutionFields $item @('View','Role','Status','ServerLocation','ServerFileMajor')
        if($item.View -cnotin @('X64','X86') -or $item.Role -cnotin @('EXECUTE_PACKAGE','CONNECTIONS','PIPELINE') -or -not $pairs.Add(([string]$item.View+':'+$item.Role)) -or $item.Status -cnotin @('REGISTERED','MISSING','UNAVAILABLE') -or $item.ServerLocation -cnotin @('EXPECTED_DTS_BINN','OTHER','UNREPORTED') -or ($null -ne $item.ServerFileMajor -and ($item.ServerFileMajor -isnot [int] -or $item.ServerFileMajor -lt 1 -or $item.ServerFileMajor -gt 65535))){throw 'INVALID'}
        if($item.ServerLocation -cne 'EXPECTED_DTS_BINN' -and $null -ne $item.ServerFileMajor){throw 'INVALID'}
        [pscustomobject]@{View=[string]$item.View;Role=[string]$item.Role;Status=[string]$item.Status;ServerLocation=[string]$item.ServerLocation;ServerFileMajor=$item.ServerFileMajor}
    })
    if($complete -and ($registration.Count -ne 2 -or $com.Count -ne 6)){throw 'INVALID'}
    Assert-SsisExecutionFields $Value.Worker @('Status','ProcessId','StartTimeUtc','Files');$w=$Value.Worker
    if($w.Status -cnotin @('NOT_ATTEMPTED','NOT_REPORTED','NOT_INSPECTED_TERMINAL','NOT_RUNNING','PID_IDENTITY_UNPROVEN','RUNNING_CANDIDATE','ENDED_DURING_READ','INSPECTION_FAILED') -or ($null -ne $w.ProcessId -and ($w.ProcessId -isnot [int] -or $w.ProcessId -lt 1))){throw 'INVALID'}
    $start=$null;if($null -ne $w.StartTimeUtc){$stamp=[datetimeoffset]::MinValue;if($w.StartTimeUtc -isnot [string] -or $w.StartTimeUtc.Length -gt 64 -or -not [datetimeoffset]::TryParseExact($w.StartTimeUtc,'o',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$stamp)){throw 'INVALID'};$start=$stamp.ToUniversalTime().ToString('o')}
    $workerFiles=ConvertTo-SsisExecutionFileRecords $w.Files $false
    if($w.Status -ceq 'RUNNING_CANDIDATE' -and ($null -eq $w.ProcessId -or $null -eq $start -or @($workerFiles|Where-Object Role -CEQ 'EXECUTOR').Count -ne 1)){throw 'INVALID'}
    if($w.Status -ceq 'RUNNING_CANDIDATE' -and ($null -eq $snapshot -or $snapshot.ObservedExecutionStatus -notin @(2,5,8))){throw 'INVALID'}
    if($w.Status -ceq 'NOT_REPORTED' -and ($null -ne $w.ProcessId -or $null -ne $start -or $workerFiles.Count -ne 0)){throw 'INVALID'}
    if($w.Status -ceq 'NOT_INSPECTED_TERMINAL' -and ($null -eq $w.ProcessId -or $null -eq $snapshot -or $snapshot.ObservedExecutionStatus -in @(2,5,8) -or $null -ne $start -or $workerFiles.Count -ne 0)){throw 'INVALID'}
    if($complete -and $w.Status -ceq 'NOT_ATTEMPTED'){throw 'INVALID'}
    if($null -eq $Value.ErrorCodes -or $Value.ErrorCodes -is [string] -or @($Value.ErrorCodes).Count -gt 64){throw 'INVALID'}
    $codes=@(foreach($code in $Value.ErrorCodes){if($code -isnot [int]){throw 'INVALID'};[int]$code});if(@($codes|Sort-Object -Unique).Count -ne $codes.Count){throw 'INVALID'}
    [pscustomobject]@{ContractVersion='SqlServerLab.SsisExecutionGuest/1.0';Status=[string]$Value.Status;ReasonCode=[string]$Value.ReasonCode;Snapshot=$snapshot;InstalledFiles=@($files);Registration=$registration;ComRegistration=$com;Worker=[pscustomobject]@{Status=[string]$w.Status;ProcessId=$w.ProcessId;StartTimeUtc=$start;Files=@($workerFiles)};ErrorCodes=$codes;ErrorCodesTruncated=[bool]$Value.ErrorCodesTruncated}
}

function Invoke-LabSsisExecutionDiagnostic {
    [CmdletBinding()]
    param([guid]$RunId,[string]$InstanceId,[string]$StateRoot,[long]$ExecutionId,[long]$ExpectedProjectLsn,[guid]$ExpectedCatalogDatabaseGuid,[int]$TimeoutSeconds)
    $credential=$null;$observation=$null;$reason='NONE'
    try {
        $context=Get-LabSsisPrerequisiteContext -RunId $RunId -InstanceId $InstanceId -StateRoot $StateRoot
        if($context.ExpectedMajor -ne 17){throw 'SSIS_EXECUTION_DIAGNOSTIC_SQL2025_REQUIRED'}
        $credential=Get-LabSecret -Path $context.Directory -Name 'guest-administrator-password'
        if(-not $credential){throw 'SSIS_EXECUTION_DIAGNOSTIC_CREDENTIAL_UNAVAILABLE'}
        $fresh=Get-LabSsisPrerequisiteContext -RunId $RunId -InstanceId $InstanceId -StateRoot $StateRoot
        if($fresh.Fingerprint -cne $context.Fingerprint){throw 'SSIS_EXECUTION_DIAGNOSTIC_BINDING_CHANGED'}
        $result=@(Invoke-HyperVPowerShellDirect -VMName ([string]$context.Instance.vmName) -ExpectedRunId $RunId.ToString() -ExpectedScopeId ([string]$context.Run.scopeId) -ExpectedVmId ([guid]$context.Instance.vmId) -Credential ([pscredential]::new('Administrator',$credential)) -ScriptBlock (Get-LabSsisExecutionDiagnosticGuest) -ArgumentList @([int]$context.Instance.port,[string]$context.ExpectedInstance,$ExecutionId,$ExpectedProjectLsn,$ExpectedCatalogDatabaseGuid,$TimeoutSeconds) -NoRetry -TimeoutSeconds $TimeoutSeconds -ErrorAction Stop 3>$null 4>$null 5>$null 6>$null)
        $fresh=Get-LabSsisPrerequisiteContext -RunId $RunId -InstanceId $InstanceId -StateRoot $StateRoot
        if($fresh.Fingerprint -cne $context.Fingerprint){throw 'SSIS_EXECUTION_DIAGNOSTIC_BINDING_CHANGED'}
        if($result.Count -ne 1){throw 'SSIS_EXECUTION_DIAGNOSTIC_RESULT_INVALID'}
        try{$observation=ConvertTo-LabSsisExecutionDiagnosticObservation -Value $result[0] -ExecutionId $ExecutionId -ExpectedProjectLsn $ExpectedProjectLsn -ExpectedCatalogDatabaseGuid $ExpectedCatalogDatabaseGuid}catch{throw 'SSIS_EXECUTION_DIAGNOSTIC_RESULT_INVALID'}
    }catch{$reason=$_.Exception.Message;if($reason -cnotin @('SSIS_EXECUTION_DIAGNOSTIC_SQL2025_REQUIRED','SSIS_EXECUTION_DIAGNOSTIC_CREDENTIAL_UNAVAILABLE','SSIS_EXECUTION_DIAGNOSTIC_BINDING_CHANGED','SSIS_EXECUTION_DIAGNOSTIC_RESULT_INVALID')){$reason='SSIS_EXECUTION_DIAGNOSTIC_TARGET_OR_TRANSPORT_UNAVAILABLE'}}finally{if($credential){$credential.Dispose()}}
    [pscustomobject]@{ContractVersion='SqlServerLab.SsisExecutionDiagnostic/1.0';Target=[pscustomobject]@{RunId=$RunId.ToString();InstanceId=$InstanceId;Provider='hyperv'};Status=$(if($observation){$observation.Status}else{'INCONCLUSIVE'});ReasonCode=$(if($observation){$observation.ReasonCode}else{$reason});Observation=$observation;ReadOnly=$true;ExecutionStatus='NOT_STARTED_BY_DIAGNOSTIC'}
}
