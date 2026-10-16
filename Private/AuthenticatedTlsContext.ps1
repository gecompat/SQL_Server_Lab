#Requires -Version 7.2
# Private Vorschau: Hostdaten bleiben lokal; keine Registrierung oder Key-/Trustaktion.

function Test-LabAuthenticatedTlsContextRequest {
    [CmdletBinding()]
    param([object]$Request)
    $bad=[pscustomobject][ordered]@{Success=$false;Value=$null;ErrorCode='TLS_CONTEXT_REQUEST_INVALID'}
    $common=@('ContractVersion','RequestId','Kind','Context')
    $fields=Get-LabTlsRequestFields $Request ($common+@('ClientRef','Store','ClientStacks','SignerContextRef','Backend'))
    if($null -eq $fields){return $bad}
    foreach($name in $common){if(-not $fields.ContainsKey($name)){return $bad}}
    if(-not (Test-LabTlsRequestEnum $fields.ContractVersion @('SqlServerLab.AuthenticatedTlsContextRequest/0.1')) -or
        -not (Test-LabTlsRequestReference $fields.RequestId) -or
        -not (Test-LabTlsRequestEnum $fields.Context @('CURRENT_WINDOWS_PROCESS')) -or
        -not (Test-LabTlsRequestEnum $fields.Kind @('CLIENT_CONTEXT','SIGNER_CONTEXT'))){return $bad}
    $value=[ordered]@{ContractVersion=$fields.ContractVersion;RequestId=$fields.RequestId;Kind=$fields.Kind;Context=$fields.Context}
    if([string]::Equals($fields.Kind,'CLIENT_CONTEXT',[StringComparison]::Ordinal)){
        if($fields.Count -ne 7){return $bad}
        foreach($name in @('ClientRef','Store','ClientStacks')){if(-not $fields.ContainsKey($name)){return $bad}}
        if(-not (Test-LabTlsRequestReference $fields.ClientRef) -or
            -not (Test-LabTlsRequestEnum $fields.Store @('CURRENT_USER_ROOT')) -or
            ($fields.ClientStacks -isnot [object[]] -and $fields.ClientStacks -isnot [string[]]) -or
            [array].GetProperty('Length').GetValue($fields.ClientStacks) -ne 2){return $bad}
        $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach($stack in $fields.ClientStacks){
            if(-not (Test-LabTlsRequestEnum $stack @('SYSTEM_DATA_SQLCLIENT','ODBC_SQLCMD')) -or -not $seen.Add($stack)){return $bad}
        }
        $value.ClientRef=$fields.ClientRef;$value.Store='CURRENT_USER_ROOT';$value.ClientStacks=@('SYSTEM_DATA_SQLCLIENT','ODBC_SQLCMD')
    }else{
        if($fields.Count -ne 6 -or -not $fields.ContainsKey('SignerContextRef') -or -not $fields.ContainsKey('Backend')){return $bad}
        if(-not (Test-LabTlsRequestReference $fields.SignerContextRef) -or -not (Test-LabTlsRequestEnum $fields.Backend @('DOTNET_X509'))){return $bad}
        $value.SignerContextRef=$fields.SignerContextRef;$value.Backend='DOTNET_X509'
    }
    return [pscustomobject][ordered]@{Success=$true;Value=[pscustomobject]$value;ErrorCode=$null}
}

function Get-LabTlsWindowsProcessFacts {
    if(-not [Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)){
        throw 'TLS_CONTEXT_PLATFORM_UNSUPPORTED'
    }
    $identity=$null;$process=$null;$machine=$null;$users=$null;$current=$null
    $crypto=$null;$profileKey=$null;$hive=$null;$volatile=$null
    try{
        $identity=[Security.Principal.WindowsIdentity]::GetCurrent([Security.Principal.TokenAccessLevels]::Query)
        if($null -eq $identity.User -or $identity.IsAnonymous -or $identity.IsGuest -or $identity.IsSystem -or
            $identity.ImpersonationLevel -ne [Security.Principal.TokenImpersonationLevel]::None){throw 'TLS_CONTEXT_IDENTITY_UNAVAILABLE'}
        $sid=$identity.User.Value
        # Erste Lane: regulaere lokale/Domain- oder AAD-Benutzer, keine Service-SIDs.
        if($sid -cnotmatch '\AS-1-(?:5-21|12-1)(?:-[0-9]+){4}\z'){throw 'TLS_CONTEXT_IDENTITY_UNAVAILABLE'}
        $machine=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine,[Microsoft.Win32.RegistryView]::Registry64)
        $users=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::Users,[Microsoft.Win32.RegistryView]::Registry64)
        $current=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::CurrentUser,[Microsoft.Win32.RegistryView]::Registry64)
        $crypto=$machine.OpenSubKey('SOFTWARE\Microsoft\Cryptography',$false)
        if($null -eq $crypto){throw 'TLS_CONTEXT_HOST_UNAVAILABLE'}
        $marker=$crypto.GetValue('MachineGuid',$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $parsed=[guid]::Empty
        if($marker -isnot [string] -or -not [guid]::TryParseExact($marker,'D',[ref]$parsed) -or $parsed -eq [guid]::Empty){throw 'TLS_CONTEXT_HOST_UNAVAILABLE'}
        $profileKey=$machine.OpenSubKey(('SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\'+$sid),$false)
        $hive=$users.OpenSubKey($sid,$false);$volatile=$current.OpenSubKey('Volatile Environment',$false)
        if($null -eq $profileKey -or $null -eq $hive -or $null -eq $volatile){throw 'TLS_CONTEXT_PROFILE_UNAVAILABLE'}
        $profilePath=$profileKey.GetValue('ProfileImagePath',$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $currentPath=$volatile.GetValue('USERPROFILE',$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        if($profilePath -isnot [string] -or $currentPath -isnot [string] -or $profilePath.Contains('%') -or $currentPath.Contains('%')){
            throw 'TLS_CONTEXT_PROFILE_UNAVAILABLE'
        }
        $profileFull=Assert-LabDiagnosticPath -Path $profilePath
        $currentFull=Assert-LabDiagnosticPath -Path $currentPath
        if(-not [IO.Directory]::Exists($profileFull) -or -not [string]::Equals($profileFull,$currentFull,[StringComparison]::OrdinalIgnoreCase)){
            throw 'TLS_CONTEXT_PROFILE_UNAVAILABLE'
        }
        if([IO.DriveInfo]::new([IO.Path]::GetPathRoot($profileFull)).DriveType -ne [IO.DriveType]::Fixed){throw 'TLS_CONTEXT_PROFILE_UNAVAILABLE'}
        $process=[Diagnostics.Process]::GetCurrentProcess()
        $processPath=Assert-LabDiagnosticPath -Path $process.MainModule.FileName
        return [pscustomobject][ordered]@{
            UserSid=$sid;HostMarker=$parsed.ToString('D');HostMarkerStatus='LOCAL_REGISTRY_MARKER_ONLY'
            ProfilePath=$profileFull;ProfileStatus='OBSERVED_HIVE_AND_PATH';ActorStatus='NON_IMPERSONATING_PROCESS_TOKEN'
            ProcessId=[int]$process.Id;ProcessStartUtcTicks=[long]$process.StartTime.ToUniversalTime().Ticks;ProcessPath=$processPath
        }
    }finally{
        foreach($resource in @($volatile,$hive,$profileKey,$crypto,$current,$users,$machine,$process,$identity)){
            if($null -ne $resource){$resource.Dispose()}
        }
    }
}

function Read-LabTlsContextBinaryMetadata {
    param([string]$Path,[string]$FileName)
    $full=Assert-LabDiagnosticPath -Path $Path
    if(-not [string]::Equals([IO.Path]::GetFileName($full),$FileName,[StringComparison]::OrdinalIgnoreCase) -or
        [IO.DriveInfo]::new([IO.Path]::GetPathRoot($full)).DriveType -ne [IO.DriveType]::Fixed){throw 'TLS_CONTEXT_BINARY_UNAVAILABLE'}
    $stream=$null;$hash=$null
    try{
        $stream=[IO.File]::Open($full,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        if($stream.Length -lt 1 -or $stream.Length -gt 67108864){throw 'TLS_CONTEXT_BINARY_UNAVAILABLE'}
        $hash=[Security.Cryptography.SHA256]::Create()
        $digest=[Convert]::ToHexString($hash.ComputeHash($stream)).ToLowerInvariant()
        return [pscustomobject][ordered]@{Path=$full;DiskSha256=$digest;DiskBytes=[long]$stream.Length;Evidence='ON_DISK_BYTES_ONLY'}
    }finally{if($null -ne $hash){$hash.Dispose()};if($null -ne $stream){$stream.Dispose()}}
}

function Get-LabTlsWindowsClientBinaryMetadata {
    $assemblies=@([AppDomain]::CurrentDomain.GetAssemblies()|Where-Object {
        [string]::Equals($_.GetName().Name,'System.Data.SqlClient',[StringComparison]::Ordinal) -and
        $null -ne $_.GetType('System.Data.SqlClient.SqlConnection',$false,$false)
    })
    if($assemblies.Count -ne 1 -or [string]::IsNullOrWhiteSpace($assemblies[0].Location)){throw 'TLS_CONTEXT_BINARY_UNAVAILABLE'}
    # Keine Assembly.LoadFrom-, PATH-Schreib- oder Codeausfuehrung. Dieselbe erste
    # Application-Auswahl wie SqlReadiness, ohne Alias-/Funktionsfallback.
    $command=Get-Command -Name sqlcmd -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if($null -eq $command){throw 'TLS_CONTEXT_BINARY_UNAVAILABLE'}
    $sqlClient=Read-LabTlsContextBinaryMetadata -Path $assemblies[0].Location -FileName 'System.Data.SqlClient.dll'
    $sqlcmd=Read-LabTlsContextBinaryMetadata -Path $command.Path -FileName 'sqlcmd.exe'
    return [pscustomobject][ordered]@{
        SqlClient=$sqlClient;SqlClientAssembly=$assemblies[0].FullName;SqlClientLoadedMvid=$assemblies[0].ManifestModule.ModuleVersionId.ToString('D')
        Sqlcmd=$sqlcmd;LoadedImageDigestStatus='NOT_MEASURED';SqlcmdFlavorStatus='NOT_QUALIFIED';LoadedOdbcDriverStatus='NOT_EXECUTED'
    }
}

function Get-LabAuthenticatedTlsContextPreview {
    [CmdletBinding()]
    param([object]$Request)
    $bad=[pscustomobject][ordered]@{Success=$false;Value=$null;ErrorCode='TLS_CONTEXT_REQUEST_INVALID'}
    $checked=Test-LabAuthenticatedTlsContextRequest -Request $Request
    if(-not $checked.Success){return $bad}
    try{
        $native=Get-LabTlsWindowsProcessFacts
        $value=[ordered]@{
            ContractVersion='SqlServerLab.AuthenticatedTlsContextPreview/0.1';RequestId=$checked.Value.RequestId
            Kind=$checked.Value.Kind;Context='CURRENT_WINDOWS_PROCESS';Status='PRIVATE_METADATA_PREVIEW'
            Process=$native;RegistrationStatus='NOT_REGISTERED';QualificationStatus='NOT_EXECUTED';Ready=$false;MutationAllowed=$false
        }
        if([string]::Equals($checked.Value.Kind,'CLIENT_CONTEXT',[StringComparison]::Ordinal)){
            $value.ClientRef=$checked.Value.ClientRef;$value.Store='CURRENT_USER_ROOT'
            $value.ClientStacks=@('SYSTEM_DATA_SQLCLIENT','ODBC_SQLCMD');$value.Binaries=Get-LabTlsWindowsClientBinaryMetadata
            $value.TrustStatus='NOT_EVALUATED'
        }else{
            $backend=Get-LabAuthenticatedTlsBackendMetadata -Context CURRENT_PROCESS
            if(-not $backend.Success){throw 'TLS_CONTEXT_BACKEND_UNAVAILABLE'}
            $value.SignerContextRef=$checked.Value.SignerContextRef;$value.Backend=$backend.Value
            $value.KeyProtectionStatus='NOT_EVALUATED'
        }
        return [pscustomobject][ordered]@{Success=$true;Value=[pscustomobject]$value;ErrorCode=$null}
    }catch{
        $code=$_.Exception.Message
        $known=@('TLS_CONTEXT_PLATFORM_UNSUPPORTED','TLS_CONTEXT_IDENTITY_UNAVAILABLE','TLS_CONTEXT_HOST_UNAVAILABLE',
            'TLS_CONTEXT_PROFILE_UNAVAILABLE','TLS_CONTEXT_BINARY_UNAVAILABLE','TLS_CONTEXT_BACKEND_UNAVAILABLE')
        $bad.ErrorCode=if(Test-LabTlsRequestEnum $code $known){$code}else{'TLS_CONTEXT_PREVIEW_UNAVAILABLE'}
        return $bad
    }
}
