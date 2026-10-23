function Assert-LabTlsLiveQualificationHost {
    if(-not $IsWindows -or $PSVersionTable.PSVersion -lt [version]'7.5'){
        throw 'TLS_LIVE_QUALIFICATION_WINDOWS_POWERSHELL_7_5_REQUIRED'
    }
}

function Get-LabTlsLiveQualificationUtcNow { return [DateTimeOffset]::UtcNow }

function ConvertTo-LabTlsLiveQualificationResult {
    param(
        [object]$Qualification,[string]$RunId,[string]$InstanceId,
        [DateTimeOffset]$StartedAt,[DateTimeOffset]$ObservedAt
    )
    if($Qualification -isnot [pscustomobject]){throw 'TLS_LIVE_QUALIFICATION_RESULT_INVALID'}
    $values=@{}
    foreach($name in @('ContractVersion','Status','RunId','InstanceId','Provider','SqlVersion','Patch','SqlBuild',
        'QualifiedAt','ExpiresAt','Evidence','WireCertificateFingerprint','Encrypt','TrustServerCertificate')){
        $property=$Qualification.PSObject.Properties[$name]
        if($null -eq $property -or $property.Name -cne $name -or $property.MemberType -ne 'NoteProperty'){
            throw 'TLS_LIVE_QUALIFICATION_RESULT_INVALID'
        }
        $value=$property.Value
        if($name -in @('Encrypt','TrustServerCertificate')){
            if($value -isnot [bool]){throw 'TLS_LIVE_QUALIFICATION_RESULT_INVALID'}
        }elseif($value -isnot [string] -or $value.Length -eq 0 -or $value.Length -gt 128){
            throw 'TLS_LIVE_QUALIFICATION_RESULT_INVALID'
        }
        $values[$name]=$value
    }
    if($values.ContractVersion -cne 'SqlServerLab.TlsQualification/0.1' -or $values.Status -cne 'QUALIFIED' -or
        $values.RunId -cne $RunId -or $values.InstanceId -cne $InstanceId -or
        $values.Provider -cnotin @('docker','podman') -or -not $values.Encrypt -or $values.TrustServerCertificate -or
        $values.Evidence -cne 'FRESH_NATIVE_SQLCLIENT_AND_ODBC_SQLCMD' -or $values.WireCertificateFingerprint -cne 'NOT_OBSERVED'){
        throw 'TLS_LIVE_QUALIFICATION_RESULT_INVALID'
    }
    $profile=Get-LabTlsSqlProfile ($values.SqlVersion+'-'+$values.Patch.ToUpperInvariant())
    if($values.SqlVersion -cne $profile.SqlVersion -or $values.Patch -cne $profile.Patch -or $values.SqlBuild -cne $profile.SqlBuild){
        throw 'TLS_LIVE_QUALIFICATION_RESULT_INVALID'
    }
    $qualified=[DateTimeOffset]::MinValue;$expires=[DateTimeOffset]::MinValue
    if(-not [DateTimeOffset]::TryParseExact($values.QualifiedAt,'o',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$qualified) -or
        -not [DateTimeOffset]::TryParseExact($values.ExpiresAt,'o',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$expires) -or
        $qualified -lt $StartedAt -or $ObservedAt -lt $StartedAt -or $qualified -gt $ObservedAt -or $expires -le $ObservedAt -or
        ($expires-$qualified).TotalMinutes -gt 15){
        throw 'TLS_LIVE_QUALIFICATION_RESULT_INVALID'
    }
    # Return only the observation. Private authority, endpoint, binary and
    # certificate metadata never becomes a public command result or a cache.
    return [pscustomobject][ordered]@{
        ContractVersion='SqlServerLab.TlsLiveQualificationResult/0.1'
        Status='QUALIFIED_AT_OBSERVATION'
        RunId=$RunId;InstanceId=$InstanceId;Provider=$values.Provider
        SqlVersion=$profile.SqlVersion;Patch=$profile.Patch;SqlBuild=$profile.SqlBuild
        Encrypt=$true;TrustServerCertificate=$false
        QualifiedAtUtc=$values.QualifiedAt;ObservedAtUtc=$ObservedAt.ToString('o');ExpiresAtUtc=$values.ExpiresAt
        ClientChecks=@('SYSTEM_DATA_SQLCLIENT','ODBC_SQLCMD')
        Evidence='FRESH_NATIVE_SQLCLIENT_AND_ODBC_SQLCMD'
        WireCertificateFingerprint='NOT_OBSERVED'
    }
}
