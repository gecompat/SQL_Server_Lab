function Resolve-LabWindowsHostInputLocale {
    [CmdletBinding()]
    param(
        [AllowNull()]$LanguageList,
        [bool]$IsWindowsHost=$IsWindows,
        [bool]$IsInteractiveUser=[Environment]::UserInteractive,
        [Nullable[bool]]$IsSystemIdentity
    )

    $fallback='0407:00000407'
    if(-not $IsWindowsHost){return [pscustomobject]@{InputLocale=$fallback;Source='compatibility-default';ReasonCode='HOST_INPUT_LOCALE_NON_WINDOWS'}}
    if(-not $IsInteractiveUser){return [pscustomobject]@{InputLocale=$fallback;Source='compatibility-default';ReasonCode='HOST_INPUT_LOCALE_NON_INTERACTIVE'}}
    if($null -eq $IsSystemIdentity){
        try{$IsSystemIdentity=[Security.Principal.WindowsIdentity]::GetCurrent().IsSystem}
        catch{return [pscustomobject]@{InputLocale=$fallback;Source='compatibility-default';ReasonCode='HOST_INPUT_LOCALE_IDENTITY_UNAVAILABLE'}}
    }
    if($IsSystemIdentity){return [pscustomobject]@{InputLocale=$fallback;Source='compatibility-default';ReasonCode='HOST_INPUT_LOCALE_SYSTEM_CONTEXT'}}
    if($null -eq $LanguageList){
        $command=Get-Command Get-WinUserLanguageList -ErrorAction SilentlyContinue
        if(-not $command){return [pscustomobject]@{InputLocale=$fallback;Source='compatibility-default';ReasonCode='HOST_INPUT_LOCALE_PROBE_UNAVAILABLE'}}
        try{$LanguageList=@(Get-WinUserLanguageList -ErrorAction Stop)}
        catch{return [pscustomobject]@{InputLocale=$fallback;Source='compatibility-default';ReasonCode='HOST_INPUT_LOCALE_PROBE_FAILED'}}
    }
    $tips=@($LanguageList | ForEach-Object {@($_.InputMethodTips)} | Where-Object {-not [string]::IsNullOrWhiteSpace([string]$_)} | ForEach-Object {[string]$_.Trim().ToUpperInvariant()} | Select-Object -Unique)
    if($tips.Count -eq 0){return [pscustomobject]@{InputLocale=$fallback;Source='compatibility-default';ReasonCode='HOST_INPUT_LOCALE_MISSING'}}
    if($tips.Count -ne 1){return [pscustomobject]@{InputLocale=$fallback;Source='compatibility-default';ReasonCode='HOST_INPUT_LOCALE_AMBIGUOUS'}}
    $tip=[string]$tips[0]
    if($tip -notmatch '^[0-9A-F]{4}:([0-9A-F]{8})$' -or $Matches[1] -notin @('00000407','00000409','00000809','00000807','0000100C','0000040C')){
        return [pscustomobject]@{InputLocale=$fallback;Source='compatibility-default';ReasonCode='HOST_INPUT_LOCALE_UNSUPPORTED'}
    }
    return [pscustomobject]@{InputLocale=$tip;Source='host-current-user';ReasonCode=$null}
}

function Get-LabWindowsInputLocaleReasonDescription {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$ReasonCode)
    switch($ReasonCode){
        'HOST_INPUT_LOCALE_NON_WINDOWS' {'Der aktuelle Host ist kein Windows-System.'}
        'HOST_INPUT_LOCALE_NON_INTERACTIVE' {'Der aktuelle Prozess besitzt keinen interaktiven Benutzerkontext.'}
        'HOST_INPUT_LOCALE_IDENTITY_UNAVAILABLE' {'Die Windows-Benutzeridentitaet konnte nicht sicher gelesen werden.'}
        'HOST_INPUT_LOCALE_SYSTEM_CONTEXT' {'Ein System- oder Dienstkonto wird nicht als Benutzerpraeferenz uebernommen.'}
        'HOST_INPUT_LOCALE_PROBE_UNAVAILABLE' {'Get-WinUserLanguageList ist in diesem Prozess nicht verfuegbar.'}
        'HOST_INPUT_LOCALE_PROBE_FAILED' {'Die Windows-Benutzersprachen konnten nicht gelesen werden.'}
        'HOST_INPUT_LOCALE_MISSING' {'Im aktuellen Benutzerprofil ist keine Eingabemethode eingetragen.'}
        'HOST_INPUT_LOCALE_AMBIGUOUS' {'Im aktuellen Benutzerprofil sind mehrere verschiedene Eingabemethoden eingetragen.'}
        'HOST_INPUT_LOCALE_UNSUPPORTED' {'Die eindeutige Eingabemethode gehoert nicht zum freigegebenen Layoutkatalog.'}
        default {'Die Hostpraeferenz ist nicht eindeutig verwendbar.'}
    }
}

function Resolve-LabWindowsLocaleIntent {
    [CmdletBinding()]
    param([AllowNull()]$Intent,[hashtable]$Overrides=@{})

    $fields=@('Region','SystemLocale','UiLanguage','InputLocale','TimeZone')
    if(@($Overrides.Keys | Where-Object {$_ -notin $fields}).Count){throw 'WINDOWS_LOCALE_OVERRIDE_FIELD_INVALID'}
    if($Intent -and $Overrides.Count){
        $resolved=Resolve-LabWindowsLocaleIntent -Intent $Intent
        $candidate=Resolve-LabWindowsLocaleIntent -Overrides $Overrides
        foreach($field in $Overrides.Keys){
            if([string]$resolved.$field -cne [string]$candidate.$field){throw 'WINDOWS_LOCALE_MANIFEST_OVERRIDE_CONFLICT'}
        }
        return $resolved
    }
    $values=@{Region='DE';SystemLocale='de-DE';UiLanguage='en-US';InputLocale='0407:00000407';TimeZone='W. Europe Standard Time'}
    $inputLocaleSource='compatibility-default'
    $inputLocaleReason='HOST_INPUT_LOCALE_NOT_REQUESTED'
    if($Intent){
        $keys=if($Intent -is [Collections.IDictionary]){@($Intent.Keys)}else{@($Intent.PSObject.Properties.Name)}
        if(@($keys | Where-Object {$_ -notin ($fields+@('ContractVersion','InputLocaleSource','InputLocaleReasonCode'))}).Count){throw 'WINDOWS_LOCALE_INTENT_FIELD_INVALID'}
        if([string]$Intent.ContractVersion -ne 'SqlServerLab.WindowsLocaleIntent/1.0'){throw 'WINDOWS_LOCALE_CONTRACT_UNSUPPORTED'}
        foreach($field in $fields){
            if($field -notin $keys -or [string]::IsNullOrWhiteSpace([string]$Intent.$field)){throw 'WINDOWS_LOCALE_INTENT_INCOMPLETE'}
            $values[$field]=[string]$Intent.$field
        }
        $inputLocaleSource=if($keys -contains 'InputLocaleSource' -and [string]$Intent.InputLocaleSource -in @('explicit-intent','explicit-override','host-current-user','compatibility-default')){[string]$Intent.InputLocaleSource}else{'explicit-intent'}
        $inputLocaleReason=if($inputLocaleSource -eq 'compatibility-default' -and $keys -contains 'InputLocaleReasonCode' -and [string]$Intent.InputLocaleReasonCode -match '^HOST_INPUT_LOCALE_[A-Z_]+$'){[string]$Intent.InputLocaleReasonCode}else{$null}
    }
    foreach($field in $Overrides.Keys){$values[$field]=[string]$Overrides[$field]}
    if($Overrides.ContainsKey('InputLocale')){$inputLocaleSource='explicit-override';$inputLocaleReason=$null}
    elseif(-not $Intent){
        $hostPreference=Resolve-LabWindowsHostInputLocale
        $values.InputLocale=[string]$hostPreference.InputLocale
        $inputLocaleSource=[string]$hostPreference.Source
        $inputLocaleReason=[string]$hostPreference.ReasonCode
    }
    $region=$values.Region.Trim().Replace('_','-').ToUpperInvariant()
    if($region -match '^[A-Z]{2}-([A-Z]{2})$'){$region=$Matches[1]}
    if($region -notmatch '^[A-Z]{2}$'){throw 'WINDOWS_LOCALE_REGION_INVALID'}
    try {
        $regionInfo=[Globalization.RegionInfo]::new($region)
        if($regionInfo.GeoId -le 0 -or $regionInfo.TwoLetterISORegionName -ne $region){throw 'UNSUPPORTED'}
    }
    catch {throw 'WINDOWS_LOCALE_REGION_INVALID'}
    foreach($field in @('SystemLocale','UiLanguage')){
        $name=$values[$field].Trim().Replace('_','-')
        $culture=@([Globalization.CultureInfo]::GetCultures([Globalization.CultureTypes]::SpecificCultures) | Where-Object Name -eq $name)
        if($culture.Count -ne 1){throw 'WINDOWS_LOCALE_CULTURE_INVALID'}
        $values[$field]=$culture[0].Name
    }
    $inputTip=$values.InputLocale.Trim().ToUpperInvariant()
    if($inputTip -notmatch '^([0-9A-F]{4}):([0-9A-F]{8})$'){throw 'WINDOWS_LOCALE_INPUT_METHOD_INVALID'}
    $languageId=[Convert]::ToInt32($Matches[1],16)
    $keyboardId=$Matches[2]
    # Belegte eingebaute Layouts; keine Host-Registry als portable Capability.
    # Microsoft: windows-hardware/manufacture/desktop/windows-language-pack-default-values
    if($keyboardId -notin @('00000407','00000409','00000809','00000807','0000100C','0000040C')){
        throw 'WINDOWS_LOCALE_INPUT_METHOD_UNSUPPORTED'
    }
    try {
        $inputCulture=[Globalization.CultureInfo]::GetCultureInfo($languageId)
        if($inputCulture.IsNeutralCulture -or $inputCulture.LCID -eq 4096 -or -not $inputCulture.Name -or $inputCulture.LCID -ne $languageId){throw 'UNSUPPORTED'}
    }
    catch {throw 'WINDOWS_LOCALE_INPUT_LANGUAGE_INVALID'}
    $iana=$null;$windowsZone=$null
    if(-not [TimeZoneInfo]::TryConvertWindowsIdToIanaId($values.TimeZone.Trim(),[ref]$iana) -or
        -not [TimeZoneInfo]::TryConvertIanaIdToWindowsId($iana,[ref]$windowsZone)){
        throw 'WINDOWS_LOCALE_TIME_ZONE_INVALID'
    }
    $result=[pscustomobject]@{
        ContractVersion='SqlServerLab.WindowsLocaleIntent/1.0'
        Region=$region;SystemLocale=$values.SystemLocale;UiLanguage=$values.UiLanguage
        InputLocale=$inputTip;InputLocaleSource=$inputLocaleSource;TimeZone=$windowsZone
    }
    if($inputLocaleReason){$result|Add-Member -NotePropertyName InputLocaleReasonCode -NotePropertyValue $inputLocaleReason}
    return $result
}

function Assert-LabWindowsLocaleImageCapability {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Intent,[Parameter(Mandatory)]$Artifact)
    $normalized=Resolve-LabWindowsLocaleIntent -Intent $Intent
    if(-not $Artifact.operatingSystem -or [string]::IsNullOrWhiteSpace([string]$Artifact.operatingSystem.language)){
        throw 'WINDOWS_LOCALE_IMAGE_LANGUAGE_EVIDENCE_REQUIRED'
    }
    if([string]$Artifact.operatingSystem.language -ne [string]$normalized.UiLanguage){
        throw 'WINDOWS_LOCALE_IMAGE_UI_LANGUAGE_UNSUPPORTED'
    }
}

function Assert-LabWindowsLocaleReceipt {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Receipt,[Parameter(Mandatory)]$Intent,[Parameter(Mandatory)][string]$RunId)
    $normalized=Resolve-LabWindowsLocaleIntent -Intent $Intent
    if([string]$Receipt.ContractVersion -ne 'SqlServerLab.WindowsLocaleReceipt/1.0' -or
        [string]$Receipt.RunId -ne $RunId -or [string]$Receipt.Status -ne 'POST_OOBE_VERIFIED'){
        throw 'WINDOWS_LOCALE_RECEIPT_INVALID'
    }
    $null=Resolve-LabWindowsLocaleIntent -Intent $Receipt.Intent -Overrides @{
        Region=$normalized.Region;SystemLocale=$normalized.SystemLocale;UiLanguage=$normalized.UiLanguage
        InputLocale=$normalized.InputLocale;TimeZone=$normalized.TimeZone
    }
    if([int]$Receipt.Observed.GeoId -ne [Globalization.RegionInfo]::new($normalized.Region).GeoId){throw 'WINDOWS_LOCALE_RECEIPT_OBSERVATION_MISMATCH'}
    foreach($field in @('SystemLocale','UiLanguage','InputLocale','TimeZone')){
        if([string]$Receipt.Observed.$field -cne [string]$normalized.$field){throw 'WINDOWS_LOCALE_RECEIPT_OBSERVATION_MISMATCH'}
    }
}
