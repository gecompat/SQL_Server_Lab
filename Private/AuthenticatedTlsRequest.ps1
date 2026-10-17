#Requires -Version 7.2
# Private Formpruefung im Speicher; keine Autorisierung oder PKI-/Provideraktion.

function Get-LabTlsRequestFields {
    param([object]$Value, [string[]]$AllowedNames)
    if ($null -eq $Value) { return $null }
    # Stark typisierte offene CLR-Getter bewahren den PSObject-Wrapper. Ein
    # object-basierter Reflection-Aufruf wuerde ihn beim Binden auspacken.
    $baseGetter = [psobject].GetProperty('BaseObject').GetGetMethod().CreateDelegate([Func[psobject,object]])
    $propertiesGetter = [psobject].GetProperty('Properties').GetGetMethod().CreateDelegate(
        [Func[psobject,Management.Automation.PSMemberInfoCollection[Management.Automation.PSPropertyInfo]]])
    if ([object].GetMethod('GetType').Invoke($baseGetter.Invoke($Value), $null) -ne [Management.Automation.PSCustomObject]) { return $null }
    $fields = @{}
    $allowed = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($allowedName in $AllowedNames) { [void]$allowed.Add($allowedName) }
    $nameProperty = [Management.Automation.PSMemberInfo].GetProperty('Name')
    $valueProperty = [Management.Automation.PSNoteProperty].GetProperty('Value')
    foreach ($property in $propertiesGetter.Invoke($Value)) {
        if ($fields.Count -ge $AllowedNames.Count -or
            [object].GetMethod('GetType').Invoke($property, $null) -ne [Management.Automation.PSNoteProperty]) { return $null }
        # CLR-Zugriff umgeht auch ETS-Getter auf dem Metadatenobjekt selbst.
        $name = $nameProperty.GetValue($property)
        if (-not $allowed.Contains($name)) { return $null }
        $fields.Add($name, $valueProperty.GetValue($property))
    }
    return $fields
}

function Test-LabTlsRequestEnum {
    param([object]$Value, [string[]]$AllowedValues)
    if ($Value -isnot [string]) { return $false }
    foreach ($candidate in $AllowedValues) {
        if ([string]::Equals($Value, $candidate, [StringComparison]::Ordinal)) { return $true }
    }
    return $false
}

function Test-LabTlsRequestReference {
    param([object]$Value)
    return ($Value -is [string] -and $Value -cmatch '\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z' -and
        -not [string]::Equals($Value, '00000000-0000-0000-0000-000000000000', [StringComparison]::Ordinal))
}

function Get-LabTlsRequestProfile {
    param([object]$Value, [int]$MaximumDays)
    $profile = Get-LabTlsRequestFields $Value @('Algorithm','RsaBits','Signature','ValidityDays','RenewBeforeDays')
    if ($null -eq $profile -or $profile.Count -ne 5 -or
        -not (Test-LabTlsRequestEnum $profile.Algorithm @('RSA')) -or
        $profile.RsaBits -isnot [int] -or $profile.RsaBits -ne 3072 -or
        -not (Test-LabTlsRequestEnum $profile.Signature @('SHA256')) -or
        $profile.ValidityDays -isnot [int] -or $profile.ValidityDays -lt 2 -or $profile.ValidityDays -gt $MaximumDays -or
        $profile.RenewBeforeDays -isnot [int] -or $profile.RenewBeforeDays -lt 1 -or $profile.RenewBeforeDays -ge $profile.ValidityDays) { return $null }
    return [pscustomobject][ordered]@{
        Algorithm = 'RSA'; RsaBits = 3072; Signature = 'SHA256'
        ValidityDays = $profile.ValidityDays; RenewBeforeDays = $profile.RenewBeforeDays
    }
}

function Get-LabTlsRequestIdentity {
    param([object]$Value)
    $identity = Get-LabTlsRequestFields $Value @('Kind','Value')
    if ($null -eq $identity -or $identity.Count -ne 2 -or $identity.Kind -isnot [string] -or
        $identity.Value -isnot [string] -or $identity.Value -cnotmatch '\A[\x00-\x7f]{1,253}\z') { return $null }
    if ([string]::Equals($identity.Kind, 'IP', [StringComparison]::Ordinal)) {
        $address = $null
        if ($identity.Value -cmatch '%' -or -not [Net.IPAddress]::TryParse($identity.Value, [ref]$address) -or
            -not [string]::Equals($identity.Value, $address.ToString(), [StringComparison]::Ordinal) -or $address.Equals([Net.IPAddress]::Any) -or
            $address.Equals([Net.IPAddress]::IPv6Any)) { return $null }
    }
    elseif ([string]::Equals($identity.Kind, 'DNS', [StringComparison]::Ordinal)) {
        $label = '[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?'
        if ($identity.Value -cnotmatch ('\A' + $label + '(?:\.' + $label + ')*\z')) { return $null }
        # Numerische Adressen koennen ihre typisierte IP-SAN-Pflicht nicht umgehen.
        $address = $null
        if ([Net.IPAddress]::TryParse($identity.Value, [ref]$address)) { return $null }
    }
    else { return $null }
    return [pscustomobject][ordered]@{ Kind = $identity.Kind; Value = $identity.Value }
}

function Test-LabAuthenticatedTlsRequest {
    [CmdletBinding()]
    param([object]$Request)

    $rejected = [pscustomobject][ordered]@{ Success = $false; Value = $null; ErrorCode = 'TLS_REQUEST_INVALID' }
    $common = @('ContractVersion','RequestId','AuthorityRef','Kind')
    $fields = Get-LabTlsRequestFields $Request ($common + @('Profile','TargetRef','Provider','SqlVersion','Port','Identity',
        'ClientRef','Platform','Store','CertificateSha256','ClientStacks'))
    if ($null -eq $fields) { return $rejected }
    foreach ($name in $common) { if (-not $fields.ContainsKey($name)) { return $rejected } }
    if (-not (Test-LabTlsRequestEnum $fields.ContractVersion @('SqlServerLab.AuthenticatedTlsRequest/0.1')) -or
        -not (Test-LabTlsRequestReference $fields.RequestId) -or -not (Test-LabTlsRequestReference $fields.AuthorityRef) -or
        -not (Test-LabTlsRequestEnum $fields.Kind @('CA_PROFILE','LEAF_PROFILE','CLIENT_TRUST'))) { return $rejected }
    $value = [ordered]@{ ContractVersion = $fields.ContractVersion; RequestId = $fields.RequestId; AuthorityRef = $fields.AuthorityRef; Kind = $fields.Kind }
    switch -CaseSensitive ($fields.Kind) {
        'CA_PROFILE' {
            if ($fields.Count -ne 5 -or -not $fields.ContainsKey('Profile')) { return $rejected }
            $profile = Get-LabTlsRequestProfile $fields.Profile 365
            if ($null -eq $profile) { return $rejected }
            $value.Profile = $profile
        }
        'LEAF_PROFILE' {
            $required = $common + @('TargetRef','Provider','SqlVersion','Port','Identity','Profile')
            if ($fields.Count -ne $required.Count) { return $rejected }
            foreach ($name in $required) { if (-not $fields.ContainsKey($name)) { return $rejected } }
            if (-not (Test-LabTlsRequestReference $fields.TargetRef) -or
                -not (Test-LabTlsRequestEnum $fields.Provider @('docker','podman','hyperv')) -or
                ($fields.SqlVersion -isnot [string] -or
                    (-not (Test-LabTlsRequestEnum $fields.SqlVersion @('2019','2022','2025')) -and
                    ($fields.Provider -cnotin @('docker','podman') -or $fields.SqlVersion -cnotmatch
                        '\A(?:2019|2022|2025)-CU[1-9][0-9]{0,3}(?:-[a-z0-9][a-z0-9.-]{0,63})?\z'))) -or
                $fields.Port -isnot [int] -or $fields.Port -lt 1 -or $fields.Port -gt 65535) { return $rejected }
            $profile = Get-LabTlsRequestProfile $fields.Profile 30
            $identity = Get-LabTlsRequestIdentity $fields.Identity
            if ($null -eq $profile -or $null -eq $identity) { return $rejected }
            $value.TargetRef = $fields.TargetRef; $value.Provider = $fields.Provider; $value.SqlVersion = $fields.SqlVersion
            $value.Port = $fields.Port; $value.Identity = $identity; $value.Profile = $profile
        }
        'CLIENT_TRUST' {
            $required = $common + @('ClientRef','Platform','Store','CertificateSha256','ClientStacks')
            if ($fields.Count -ne $required.Count) { return $rejected }
            foreach ($name in $required) { if (-not $fields.ContainsKey($name)) { return $rejected } }
            if (-not (Test-LabTlsRequestReference $fields.ClientRef) -or
                -not (Test-LabTlsRequestEnum $fields.Platform @('windows','linux')) -or
                $fields.Store -isnot [string] -or
                ([string]::Equals($fields.Platform,'windows',[StringComparison]::Ordinal) -and -not (Test-LabTlsRequestEnum $fields.Store @('CURRENT_USER_ROOT'))) -or
                ([string]::Equals($fields.Platform,'linux',[StringComparison]::Ordinal) -and -not (Test-LabTlsRequestEnum $fields.Store @('ISOLATED_CLIENT_CA_STORE'))) -or
                $fields.CertificateSha256 -isnot [string] -or $fields.CertificateSha256 -cnotmatch '\A[0-9a-f]{64}\z' -or
                ($fields.ClientStacks -isnot [object[]] -and $fields.ClientStacks -isnot [string[]]) -or
                [array].GetProperty('Length').GetValue($fields.ClientStacks) -ne 2) { return $rejected }
            $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            foreach ($stack in $fields.ClientStacks) {
                if (-not (Test-LabTlsRequestEnum $stack @('SYSTEM_DATA_SQLCLIENT','ODBC_SQLCMD')) -or -not $seen.Add($stack)) { return $rejected }
            }
            $value.ClientRef = $fields.ClientRef; $value.Platform = $fields.Platform; $value.Store = $fields.Store
            $value.CertificateSha256 = $fields.CertificateSha256; $value.ClientStacks = @('SYSTEM_DATA_SQLCLIENT','ODBC_SQLCMD')
        }
        default { return $rejected }
    }
    return [pscustomobject][ordered]@{ Success = $true; Value = [pscustomobject]$value; ErrorCode = $null }
}
