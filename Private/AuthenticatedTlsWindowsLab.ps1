#Requires -Version 7.5
# Eigener Windows-SQL-2025-Run. Containerformen und historische native
# Referenzen werden nicht als Windows-Export oder neue Ausführung umgedeutet.
function Get-LabTlsWindowsProfile {
    [pscustomobject]@{Version='2025';SqlVersion='2025';Patch='base';SqlBuild='17.0.1000.7';ExportKey='WINDOWS_SQL2025_BASE_TLS'}
}

function Get-LabTlsWindowsRecordPath {
    param([string]$StateRoot,[string]$RunId,[string]$InstanceId)
    if(-not (Test-LabTlsRequestReference $RunId) -or $InstanceId -cne 'primary'){throw 'TLS_WINDOWS_SELECTION_INVALID'}
    $root=Assert-LabDiagnosticPath ([IO.Path]::GetFullPath($StateRoot))
    return Assert-LabDiagnosticPath (Join-Path $root ('runs/'+$RunId+'/authenticated-tls-windows/binding.json'))
}

function New-LabTlsWindowsBudget {
    [pscustomobject]@{Provider='hyperv';Commands=0;DeadlineUtc=[datetime]::UtcNow.AddMinutes(20)}
}

function Get-LabTlsWindowsSqlSecret {
    param([string]$RunDirectory)
    $secret=Get-LabSecret -Path $RunDirectory -Name 'generated-sql-sa-password'
    if(-not $secret){$secret=Get-LabSecret -Path $RunDirectory -Name 'sa-password'}
    if(-not $secret){throw 'TLS_WINDOWS_SQL_SECRET_REQUIRED'}
    return $secret
}

function New-LabTlsWindowsCreateManifest {
    param([hashtable]$Parameters,[string]$ArtifactId,[string]$AuditId)
    $profile=if($Parameters.ContainsKey('Profile')){$Parameters.Profile}else{'standard'}
    $resources=Get-LabResourceProfile -Name $profile
    $cpu=if($Parameters.ContainsKey('Cpu') -and $Parameters.Cpu -gt 0){[decimal]$Parameters.Cpu}else{[decimal]$resources.maxCpus}
    $memory=if($Parameters.ContainsKey('MemoryMB') -and $Parameters.MemoryMB -gt 0){[int]$Parameters.MemoryMB}else{[int]$resources.maxMemoryMB}
    if($cpu -ne [decimal]::Truncate($cpu) -or $cpu -lt 1 -or $cpu -gt 64 -or $memory -lt 512 -or $memory -gt 1048576){throw 'TLS_WINDOWS_RESOURCE_INTENT_INVALID'}
    $port=if($Parameters.ContainsKey('Port') -and $Parameters.Port -gt 0){[int]$Parameters.Port}else{1433}
    $manifest=[ordered]@{name=$(if($Parameters.ContainsKey('LabName')){$Parameters.LabName}else{'tls-windows-'+$AuditId.Substring(0,8)});
        instances=@([ordered]@{id='primary';version='2025';provider='hyperv';os='windows';profile=$profile;autostart='off';network=@{intent='hostOnly'};windowsActivation=(Resolve-LabWindowsActivationIntent -LegacyRequired);
            hyperv=@{preparedImageId=$ArtifactId;installationType='desktop-experience';processorCount=[int]$cpu;memoryStartupMB=$memory;sqlPort=$port}});
        automation=@{mode='unattended'}}
    $bytes=ConvertTo-LabTlsRegistryWriterBytes $manifest
    if(-not(Test-LabManifestSchema -Json ([Text.Encoding]::UTF8.GetString($bytes))).IsValid){throw 'TLS_WINDOWS_CREATE_MANIFEST_INVALID'}
    return ,$bytes
}

function Invoke-LabTlsWindowsGuest {
    param([object]$Context,[scriptblock]$ScriptBlock,[object[]]$Arguments,[object]$Budget)
    if($null -eq $Budget -or $Budget.Provider -cne 'hyperv' -or $Budget.Commands -ge 60 -or [datetime]::UtcNow -ge $Budget.DeadlineUtc){throw 'TLS_WINDOWS_OPERATION_BUDGET'}
    $Budget.Commands++
    $fresh=Get-LabSsisPrerequisiteContext -RunId $Context.Run.runId -InstanceId primary -StateRoot $Context.StateRoot
    if($fresh.Fingerprint -cne $Context.Fingerprint){throw 'TLS_WINDOWS_RUN_BINDING_CHANGED'}
    $secret=Get-LabSecret -Path $Context.Directory -Name 'guest-administrator-password'
    if(-not $secret){throw 'TLS_WINDOWS_GUEST_CREDENTIAL_REQUIRED'}
    try{
        $reply=@(Invoke-HyperVPowerShellDirect -VMName ([string]$fresh.Instance.vmName) -ExpectedRunId ([string]$fresh.Run.runId) -ExpectedScopeId ([string]$fresh.Run.scopeId) -ExpectedVmId ([guid]$fresh.Instance.vmId) -Credential ([pscredential]::new('Administrator',$secret)) -NoRetry -TimeoutSeconds 120 -ScriptBlock $ScriptBlock -ArgumentList $Arguments)
        if($reply.Count -ne 1 -or $reply[0].Success -isnot [bool] -or $reply[0].ConsumerEnded -isnot [bool] -or -not $reply[0].ConsumerEnded){throw 'TLS_WINDOWS_CONSUMER_END_UNKNOWN'}
        if(-not $reply[0].Success){$guestFailure=[InvalidOperationException]::new('TLS_WINDOWS_GUEST_OPERATION_FAILED_ENDED');$guestFailure.Data['ConsumerEnded']=$true;throw $guestFailure}
        return $reply[0]
    }finally{$secret.Dispose()}
}

function Get-LabTlsWindowsPrepareGuest {
    return {
        param($OperationId)
        $ErrorActionPreference='Stop'
        try{
            if($OperationId -cnotmatch '\A[0-9a-f-]{36}\z'){throw 'INVALID'}
            $folder=Join-Path $env:ProgramData ('SqlServerLab/TlsLeafAcceptance/'+$OperationId)
            if(Test-Path -LiteralPath $folder){throw 'EXISTS'}
            $null=New-Item -ItemType Directory -Path $folder
            $owner=[Security.Principal.WindowsIdentity]::GetCurrent().User
            $acl=[Security.AccessControl.DirectorySecurity]::new();$acl.SetOwner($owner);$acl.SetAccessRuleProtection($true,$false)
            foreach($sid in @($owner,[Security.Principal.SecurityIdentifier]::new('S-1-5-18'))){$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid,[Security.AccessControl.FileSystemRights]::FullControl,[Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit',[Security.AccessControl.PropagationFlags]::None,[Security.AccessControl.AccessControlType]::Allow))}
            Set-Acl -LiteralPath $folder -AclObject $acl -ErrorAction Stop
            [pscustomobject]@{Success=$true;ConsumerEnded=$true;ComputerName=[Environment]::MachineName;CertreqSha256=(Get-FileHash -LiteralPath (Join-Path $env:SystemRoot 'System32/certreq.exe')).Hash}
        }catch{[pscustomobject]@{Success=$false;ConsumerEnded=$true}}
    }
}

function Get-LabTlsWindowsObserveGuest {
    return {
        param($OperationId,$ComputerName,$Thumbprint,$CertificateSha256,$KeyContainer,$KeyModulus,$CertreqSha256,$ExpectedAddress,$ExpectedPort)
        $ErrorActionPreference='Stop';$store=$null;$rsa=$null
        try{
            if($OperationId -cnotmatch '\A[0-9a-f-]{36}\z' -or [Environment]::MachineName -cne $ComputerName -or $Thumbprint -cnotmatch '\A[0-9A-F]{40}\z' -or
                (Get-FileHash -LiteralPath (Join-Path $env:SystemRoot 'System32/certreq.exe')).Hash -cne $CertreqSha256){throw 'IDENTITY'}
            $map=Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL' -ErrorAction Stop
            $instance=[string]$map.MSSQLSERVER
            if($instance -cnotmatch '\AMSSQL17\.[A-Za-z0-9_]+\z'){throw 'INSTANCE'}
            $base='HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\'+$instance+'\MSSQLServer'
            $network=Get-ItemProperty -LiteralPath ($base+'\SuperSocketNetLib') -ErrorAction Stop
            if([string]$network.Certificate -ine $Thumbprint -or [int]$network.ForceEncryption -ne 1){throw 'BINDING'}
            $service=Get-CimInstance Win32_Service -Filter "Name='MSSQLSERVER'" -ErrorAction Stop
            if($service.State -cne 'Running' -or $service.StartName -ine 'NT Service\MSSQLSERVER' -or [int]$service.ProcessId -le 0){throw 'SERVICE'}
            $process=Get-Process -Id ([int]$service.ProcessId) -ErrorAction Stop
            $addresses=@(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop|Where-Object {$_.IPAddress -ceq $ExpectedAddress -and $_.AddressState -eq 'Preferred'})
            $listeners=@(Get-NetTCPConnection -State Listen -LocalPort ([int]$ExpectedPort) -ErrorAction Stop|Where-Object OwningProcess -EQ ([int]$service.ProcessId))
            if($addresses.Count -ne 1 -or $listeners.Count -lt 1){throw 'ENDPOINT'}
            $store=[Security.Cryptography.X509Certificates.X509Store]::new('My','LocalMachine');$store.Open([Security.Cryptography.X509Certificates.OpenFlags]::ReadOnly)
            $certificates=@($store.Certificates|Where-Object Thumbprint -CEQ $Thumbprint)
            if($certificates.Count -ne 1 -or -not $certificates[0].HasPrivateKey){throw 'CERTIFICATE'}
            $certificate=$certificates[0]
            $sha=[Security.Cryptography.SHA256]::Create()
            try{$hash=([BitConverter]::ToString($sha.ComputeHash($certificate.RawData))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
            if($hash -cne $CertificateSha256 -or $certificate.NotAfter.ToUniversalTime() -le [datetime]::UtcNow -or $certificate.NotBefore.ToUniversalTime() -gt [datetime]::UtcNow){throw 'CERTIFICATE'}
            $rsa=$certificate.PrivateKey
            if($rsa -isnot [Security.Cryptography.RSACryptoServiceProvider]){throw 'KEY'}
            $key=$rsa.CspKeyContainerInfo
            if($rsa.KeySize -ne 3072 -or $key.Exportable -or -not $key.MachineKeyStore -or $key.ProviderType -ne 12 -or [int]$key.KeyNumber -ne 1 -or
                $key.KeyContainerName -cne $KeyContainer -or [Convert]::ToBase64String($rsa.ExportParameters($false).Modulus) -cne $KeyModulus){throw 'KEY'}
            $keyFile=Join-Path $env:ProgramData ('Microsoft/Crypto/RSA/MachineKeys/'+$key.UniqueKeyContainerName)
            $keyAcl=Get-Acl -LiteralPath $keyFile -ErrorAction Stop
            $serviceSid=([Security.Principal.NTAccount]::new($service.StartName)).Translate([Security.Principal.SecurityIdentifier])
            $read=@($keyAcl.Access|Where-Object {$_.AccessControlType -eq 'Allow' -and $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -ceq $serviceSid.Value -and ($_.FileSystemRights -band [Security.AccessControl.FileSystemRights]::Read) -eq [Security.AccessControl.FileSystemRights]::Read})
            if($read.Count -ne 1){throw 'KEY_ACL'}
            $logArgument=Get-ItemPropertyValue -LiteralPath ($base+'\Parameters') -Name SQLArg1 -ErrorAction Stop
            if($logArgument -notlike '-e*'){throw 'LOG'}
            $log=Get-Content -LiteralPath $logArgument.Substring(2).Trim('"') -Raw -ErrorAction Stop
            if($log -notmatch ('(?i)Cert Hash\(sha1\)\s+"?'+[regex]::Escape($Thumbprint)+'"?.*successfully loaded')){throw 'LOAD'}
            $boot=(Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime.ToUniversalTime().ToString('o')
            [pscustomobject]@{Success=$true;ConsumerEnded=$true;ComputerName=$ComputerName;BootedAt=$boot;ProcessId=[int]$service.ProcessId;StartedAt=$process.StartTime.ToUniversalTime().ToString('o');CertificateSha256=$hash;CertificateLoaded=$true;NonExportableKey=$true;ForceEncryption=$true}
        }catch{[pscustomobject]@{Success=$false;ConsumerEnded=$true}}
        finally{if($rsa){$rsa.Dispose()};if($store){$store.Dispose()}}
    }
}

function Read-LabTlsWindowsRecord {
    param([byte[]]$Bytes)
    $names=@('ContractVersion','AuditId','DataRoot','StateRoot','ControllerId','LocationId','AuthorityRef','ClientRef','RegistrySha256','RunId','InstanceId','ScopeId','VmId','Host','Port','SqlVersion','Patch','SqlBuild','ComputerName','ProcessId','StartedAt','BootedAt','CertificateSha256','CertificateDer','CertificateThumbprint','NotAfterUtc','KeyContainer','KeyModulus','CertreqSha256')
    $record=Read-LabTlsBoundJson $Bytes $names
    $profile=Get-LabTlsWindowsProfile
    foreach($name in $names|Where-Object {$_ -cnotin @('Port','ProcessId')}){
        if($record.$name -isnot [string] -or [string]::IsNullOrEmpty($record.$name) -or $record.$name.Length -gt $(if($name -ceq 'CertificateDer'){24000}else{4096})){throw 'TLS_WINDOWS_RECORD_TYPES'}
    }
    if($record.ContractVersion -cne 'SqlServerLab.AuthenticatedTlsWindowsLab/0.1' -or $record.SqlVersion -cne $profile.SqlVersion -or $record.Patch -cne $profile.Patch -or $record.SqlBuild -cne $profile.SqlBuild -or
        $record.InstanceId -cne 'primary' -or -not (Test-LabTlsRequestReference $record.AuditId) -or -not (Test-LabTlsRequestReference $record.RunId) -or -not (Test-LabTlsRequestReference $record.VmId) -or
        ($record.Port -isnot [long] -and $record.Port -isnot [int]) -or $record.Port -lt 1 -or $record.Port -gt 65535 -or ($record.ProcessId -isnot [long] -and $record.ProcessId -isnot [int]) -or $record.ProcessId -lt 1 -or $record.CertificateSha256 -cnotmatch '\A[a-f0-9]{64}\z' -or $record.CertificateThumbprint -cnotmatch '\A[0-9A-F]{40}\z' -or
        $record.KeyContainer -cne ('SQLServerLab-TLS-Renew-'+$record.AuditId) -or $record.CertreqSha256 -cnotmatch '\A[0-9A-F]{64}\z'){throw 'TLS_WINDOWS_RECORD_INVALID'}
    $address=$null
    if(-not [Net.IPAddress]::TryParse($record.Host,[ref]$address) -or $address.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or $address.ToString() -cne $record.Host){throw 'TLS_WINDOWS_ENDPOINT_INVALID'}
    foreach($name in @('ControllerId','LocationId','AuthorityRef','ClientRef','ScopeId')){
        if(-not (Test-LabTlsRequestReference $record.$name)){throw 'TLS_WINDOWS_REFERENCE_INVALID'}
    }
    if($record.RegistrySha256 -cnotmatch '\A[a-f0-9]{64}\z' -or $record.ComputerName -cnotmatch '\A[A-Za-z0-9-]{1,15}\z' -or
        ([Convert]::FromBase64String($record.KeyModulus)).Length -ne 384){throw 'TLS_WINDOWS_RECORD_PROFILE_INVALID'}
    foreach($name in @('StartedAt','BootedAt','NotAfterUtc')){
        $date=[DateTimeOffset]::MinValue
        if(-not [DateTimeOffset]::TryParseExact($record.$name,'o',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$date) -or $date.Offset -ne [timespan]::Zero){throw 'TLS_WINDOWS_RECORD_DATE_INVALID'}
    }
    $der=[Convert]::FromBase64String($record.CertificateDer)
    if((Get-LabTlsCaByteDigest $der) -cne $record.CertificateSha256){throw 'TLS_WINDOWS_CERTIFICATE_BYTES_CHANGED'}
    $certificate=[Security.Cryptography.X509Certificates.X509Certificate2]::new($der);$public=$null
    try{
        $public=[Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPublicKey($certificate)
        if($certificate.Thumbprint -cne $record.CertificateThumbprint -or $public.KeySize -ne 3072 -or
            [Convert]::ToBase64String($public.ExportParameters($false).Modulus) -cne $record.KeyModulus -or
            $certificate.NotAfter.ToUniversalTime() -ne [DateTimeOffset]::Parse($record.NotAfterUtc).UtcDateTime){throw 'TLS_WINDOWS_CERTIFICATE_PROFILE_CHANGED'}
    }finally{if($public){$public.Dispose()};$certificate.Dispose()}
    return $record
}

function Get-LabTlsWindowsOwnBinding {
    param([string]$StateRoot,[string]$RunId,[string]$InstanceId)
    $native=Get-LabTlsWindowsProcessFacts
    $path=Get-LabTlsWindowsRecordPath $StateRoot $RunId $InstanceId
    $bytes=Read-LabTlsCaPrivateFile $path $native.UserSid 32768
    $record=Read-LabTlsWindowsRecord $bytes
    if($record.RunId -cne $RunId -or $record.InstanceId -cne $InstanceId -or -not [string]::Equals($record.StateRoot,[IO.Path]::GetFullPath($StateRoot),[StringComparison]::OrdinalIgnoreCase)){throw 'TLS_WINDOWS_SELECTION_CHANGED'}
    $authority=Get-LabTlsOperationalAuthority $record.DataRoot $record.ControllerId $record.LocationId $record.AuthorityRef $record.ClientRef
    if($authority.RegistrySha256 -cne $record.RegistrySha256){throw 'TLS_WINDOWS_AUTHORITY_CHANGED'}
    return [pscustomobject]@{Record=$record;Authority=$authority;Bytes=$bytes;StateRoot=$record.StateRoot}
}

function Assert-LabTlsWindowsCertificateBinding {
    param([object]$Bound,[object]$Budget)
    $record=$Bound.Record
    $context=Get-LabSsisPrerequisiteContext -RunId $record.RunId -InstanceId primary -StateRoot $record.StateRoot
    if([string]$context.Run.scopeId -cne $record.ScopeId -or [string]$context.Instance.vmId -cne $record.VmId -or [string]$context.Instance.host -cne $record.Host -or [int]$context.Instance.port -ne $record.Port -or
        [string]$context.Instance.sqlReadiness.ProductVersion -cne $record.SqlBuild -or $context.ExpectedMajor -ne 17 -or $context.ExpectedInstance -cne 'MSSQLSERVER'){throw 'TLS_WINDOWS_NATIVE_BINDING_CHANGED'}
    $reply=Invoke-LabTlsWindowsGuest $context (Get-LabTlsWindowsObserveGuest) @($record.AuditId,$record.ComputerName,$record.CertificateThumbprint,$record.CertificateSha256,$record.KeyContainer,$record.KeyModulus,$record.CertreqSha256,$record.Host,$record.Port) $Budget
    if($reply.BootedAt -cne $record.BootedAt -or $reply.StartedAt -cne $record.StartedAt -or $reply.ProcessId -ne $record.ProcessId -or -not $reply.CertificateLoaded -or -not $reply.NonExportableKey -or -not $reply.ForceEncryption){throw 'TLS_WINDOWS_RESTART_OR_CERTIFICATE_DRIFT'}
    return $context
}

function Test-LabAuthenticatedTlsWindowsEnvironment {
    param([string]$RunId,[string]$InstanceId,[string]$StateRoot,[object]$Budget)
    if($null -eq $Budget){$Budget=New-LabTlsWindowsBudget}
    $bound=Get-LabTlsWindowsOwnBinding $StateRoot $RunId $InstanceId
    $record=$bound.Record;$authority=$bound.Authority
    $context=Assert-LabTlsWindowsCertificateBinding $bound $Budget
    $password=Get-LabTlsWindowsSqlSecret $context.Directory
    try{
        Invoke-LabTlsStrictSqlClient -Port $record.Port -Password $password -ExpectedBuild $record.SqlBuild -HostName $record.Host
        $odbc=Invoke-LabTlsStrictSqlcmd -Port $record.Port -Password $password -Client $authority.Client -ExpectedBuild $record.SqlBuild -HostName $record.Host
    }finally{$password.Dispose()}
    $null=Assert-LabTlsWindowsCertificateBinding $bound $Budget
    $again=Get-LabTlsWindowsOwnBinding $StateRoot $RunId $InstanceId
    if((Get-LabTlsCaByteDigest $again.Bytes) -cne (Get-LabTlsCaByteDigest $bound.Bytes)){throw 'TLS_WINDOWS_BINDING_CHANGED'}
    $now=[DateTimeOffset]::UtcNow;$expires=$now.AddMinutes(15);$leafEnd=[DateTimeOffset]::Parse($record.NotAfterUtc)
    if($leafEnd -lt $expires){$expires=$leafEnd}
    return [pscustomobject][ordered]@{ContractVersion='SqlServerLab.TlsQualification/0.3';Status='QUALIFIED';Provider='hyperv';SqlVersion=$record.SqlVersion;Patch=$record.Patch;SqlBuild=$record.SqlBuild;RunId=$RunId;InstanceId=$InstanceId;
        QualifiedAt=$now.ToString('o');ExpiresAt=$expires.ToString('o');Encrypt=$true;TrustServerCertificate=$false;ScopeId=$record.ScopeId;VmId=$record.VmId;BootedAt=$record.BootedAt;StartedAt=$record.StartedAt;ProcessId=$record.ProcessId;
        Endpoint=[pscustomobject]@{Host=$record.Host;Port=$record.Port;IdentityKind='IP';Identity=$record.Host};AuthorityRef=$authority.Authority.Ref;AuthorityGeneration=$authority.Authority.Generation;ClientRef=$authority.Client.Ref;ClientGeneration=$authority.Client.Generation;
        TrustScopeRef=$authority.Authority.TrustScopeRef;Store='CURRENT_USER_ROOT';ActorDigest=$authority.ActorDigest;RootDigest=$authority.RootDigest;RegistrySha256=$authority.RegistrySha256;CaSha256=$authority.Authority.CertificateSha256;LeafSha256=$record.CertificateSha256;LeafNotAfterUtc=$record.NotAfterUtc;
        SqlClientSha256=$authority.Client.Details.SqlClientDiskSha256;SqlClientMvid=$authority.Client.Details.SqlClientLoadedMvid;SqlcmdSha256=$odbc.SqlcmdSha256;LoadedOdbcSha256=$odbc.LoadedOdbcSha256;LoadedOdbcBytes=$odbc.LoadedOdbcBytes;Evidence='FRESH_NATIVE_SQLCLIENT_AND_ODBC_SQLCMD';WireCertificateFingerprint='NOT_OBSERVED'}
}

# Geschlossene signierte Projektion. Die gemeinsame V2-Schicht prüft zusätzlich
# Schema, Entry-Digest, echte RSA-Signatur, Hosttrust und Frische. Diese Prüfung
# verhindert insbesondere eine Vermischung mit Container- oder Linuxnachweisen.
function Assert-LabTlsWindowsExportQualification {
    param([object]$Bound,[object]$Qualification,[object]$Entry)
    $r=$Bound.Record;$a=$Bound.Authority;$p=Get-LabTlsWindowsProfile
    $expected=[ordered]@{ContractVersion='SqlServerLab.TlsQualification/0.3';Status='QUALIFIED';Provider='hyperv';SqlVersion=$p.SqlVersion;Patch=$p.Patch;SqlBuild=$p.SqlBuild;
        RunId=$r.RunId;InstanceId=$r.InstanceId;Encrypt=$true;TrustServerCertificate=$false;ScopeId=$r.ScopeId;VmId=$r.VmId;BootedAt=$r.BootedAt;StartedAt=$r.StartedAt;ProcessId=$r.ProcessId;
        AuthorityRef=$a.Authority.Ref;AuthorityGeneration=$a.Authority.Generation;ClientRef=$a.Client.Ref;ClientGeneration=$a.Client.Generation;TrustScopeRef=$a.Authority.TrustScopeRef;Store='CURRENT_USER_ROOT';
        ActorDigest=$a.ActorDigest;RootDigest=$a.RootDigest;RegistrySha256=$a.RegistrySha256;CaSha256=$a.Authority.CertificateSha256;LeafSha256=$r.CertificateSha256;LeafNotAfterUtc=$r.NotAfterUtc;
        SqlClientSha256=$a.Client.Details.SqlClientDiskSha256;SqlClientMvid=$a.Client.Details.SqlClientLoadedMvid;SqlcmdSha256=$a.Client.Details.SqlcmdDiskSha256;
        Evidence='FRESH_NATIVE_SQLCLIENT_AND_ODBC_SQLCMD';WireCertificateFingerprint='NOT_OBSERVED'}
    $q=Read-LabTlsBoundJson (ConvertTo-LabTlsRegistryWriterBytes $Qualification) @($expected.Keys+'QualifiedAt'+'ExpiresAt'+'Endpoint'+'LoadedOdbcSha256'+'LoadedOdbcBytes')
    foreach($name in $expected.Keys){
        $value=$q.$name;$wanted=$expected[$name]
        if($wanted -is [bool]){$valid=$value -is [bool] -and $value -eq $wanted}
        elseif($wanted -is [ValueType]){$valid=($value -is [int] -or $value -is [long]) -and $value -eq $wanted}
        else{$valid=$value -is [string] -and $value -ceq [string]$wanted}
        if(-not $valid){throw 'TLS_WINDOWS_EXPORT_QUALIFICATION_CHANGED'}
    }
    $endpoint=Read-LabTlsBoundJson (ConvertTo-LabTlsRegistryWriterBytes $q.Endpoint) @('Host','Port','IdentityKind','Identity')
    if($endpoint.Host -cne $r.Host -or $endpoint.Identity -cne $r.Host -or $endpoint.IdentityKind -cne 'IP' -or
        ($endpoint.Port -isnot [int] -and $endpoint.Port -isnot [long]) -or $endpoint.Port -ne $r.Port -or
        $q.LoadedOdbcSha256 -isnot [string] -or $q.LoadedOdbcSha256 -cnotmatch '\A[a-f0-9]{64}\z' -or
        ($q.LoadedOdbcBytes -isnot [long] -and $q.LoadedOdbcBytes -isnot [int]) -or $q.LoadedOdbcBytes -le 0){throw 'TLS_WINDOWS_EXPORT_CLIENT_OR_ENDPOINT_CHANGED'}
    if($Entry.platform -cne 'windows' -or $Entry.provider -cne 'hyperv' -or $Entry.key -cne $p.ExportKey -or $Entry.sqlVersion -cne $p.SqlVersion -or $Entry.patch -cne $p.Patch -or $Entry.resolvedVersion -cne $p.SqlBuild -or
        $Entry.status -cne 'READY' -or $Entry.runtimeStatus -cne 'READY' -or $Entry.runId -cne $r.RunId -or $Entry.instanceId -cne $r.InstanceId -or
        $Entry.host -cne $r.Host -or $Entry.port -ne $r.Port -or $Entry.database -cne 'master' -or $Entry.username -cne 'sa' -or $Entry.autoStart -cne 'off'){throw 'TLS_WINDOWS_EXPORT_ENTRY_CHANGED'}
    $builder=[Data.SqlClient.SqlConnectionStringBuilder]::new($Entry.connectionString)
    try{if($builder.UserID -cne 'sa' -or $builder.IntegratedSecurity -or $builder.InitialCatalog -cne 'master'){throw 'TLS_WINDOWS_EXPORT_LOGIN_CHANGED'}}finally{$builder.Clear()}
    if([DateTimeOffset]::Parse($q.ExpiresAt) -gt [DateTimeOffset]::Parse($r.NotAfterUtc)){throw 'TLS_WINDOWS_EXPORT_EXCEEDS_LEAF_LIFETIME'}
}

# Interner gemeinsamer TLS-Abschluss für den vom Ersteller gebundenen eigenen
# Run. Kein öffentlicher Import-/Takeover-Einstieg. Ein unterbrochener eigener
# Labaufbau kann nach gebundener Recovery denselben Abschlusskern verwenden.
function Initialize-LabTlsWindowsOwnedRun {
    param([object]$Run,[hashtable]$Parameters,[object]$Authority,[string]$Operation,[string]$Audit,[string]$StateRoot)
    $operationExpected=Join-Path $Parameters.DataRoot ('State/authenticated-tls-windows-operations/'+$Audit)
    if(-not [string]::Equals([IO.Path]::GetFullPath($Operation),[IO.Path]::GetFullPath($operationExpected),[StringComparison]::OrdinalIgnoreCase) -or
        $Run.State -cne 'RUNNING' -or @($Run.Instances).Count -ne 1){throw 'TLS_WINDOWS_OWN_RUN_REQUIRED'}
    $sid=$Authority.Native.UserSid;$state=$StateRoot;$phase='bind';$ended=$true
    $intent=Read-LabTlsBoundJson (Read-LabTlsCaPrivateFile (Join-Path $Operation 'intent.json') $sid 4096) @('ContractVersion','AuditId','Status')
    if($intent.ContractVersion -cne 'SqlServerLab.WindowsTlsCreateIntent/0.1' -or $intent.AuditId -cne $Audit -or $intent.Status -cne 'NEW_OWN_RUN_PENDING'){throw 'TLS_WINDOWS_OWN_CREATE_INTENT_REQUIRED'}
    $create=Read-LabTlsBoundJson (Read-LabTlsCaPrivateFile (Join-Path $Operation 'create-manifest.json') $sid 8192) @('name','instances','automation')
    $bound=Get-HyperVLabWorkflowRun -RunId $Run.RunId -StateRoot $state
    if($bound.Run.scopeId -cne $Run.ScopeId -or $bound.Instance.vmId -cne $Run.Instances[0].vmId -or
        $bound.Instance.imageArtifactId -cne $create.instances[0].hyperv.preparedImageId -or $bound.Run.metadata.name -cne $create.name){throw 'TLS_WINDOWS_CREATE_RUN_BINDING_CHANGED'}
    try{
        Write-LabTlsCaPrivateFile (Join-Path $operation 'run.json') $sid (ConvertTo-LabTlsRegistryWriterBytes @{AuditId=$audit;RunId=$run.RunId;StateRoot=$state})
        $budget=New-LabTlsWindowsBudget
        $context=Get-LabSsisPrerequisiteContext -RunId $run.RunId -InstanceId primary -StateRoot $state
        $profile=Get-LabTlsWindowsProfile
        if([string]$context.Instance.sqlReadiness.ProductVersion -cne $profile.SqlBuild){throw 'TLS_WINDOWS_SQL_BUILD_UNSUPPORTED'}
        $hostName=[string]$context.Instance.host;$address=$null
        if(-not [Net.IPAddress]::TryParse($hostName,[ref]$address) -or $address.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or $address.ToString() -cne $hostName){throw 'TLS_WINDOWS_IPV4_REQUIRED'}
        $phase='prepare';$ended=$false
        $prepared=Invoke-LabTlsWindowsGuest $context (Get-LabTlsWindowsPrepareGuest) @($audit) $budget;$ended=$true
        $container='SQLServerLab-TLS-Renew-'+$audit
        $phase='csr';$ended=$false
        $csr=Invoke-LabTlsWindowsGuest $context (Get-LabTlsHyperVCsrGuestScript) @($audit,'renewed',$container,$hostName,$prepared.ComputerName,$true,$null,$prepared.CertreqSha256,$null) $budget;$ended=$true
        $identity=[pscustomobject]@{Kind='IP';Value=$hostName}
        $leaf=New-LabAuthenticatedTlsServerLeaf -DataRoot $Parameters.DataRoot -ControllerId $Parameters.TlsControllerId -LocationId $Parameters.TlsLocationId -Context CURRENT_WINDOWS_PROCESS -CandidateId $Parameters.TlsCandidateId -CsrDer ([Convert]::FromBase64String($csr.Csr)) -Identity $identity -ValidityDays 1 -WindowsMachineName $prepared.ComputerName
        if(-not $leaf.Success){throw 'TLS_WINDOWS_LEAF_ISSUANCE_REJECTED'}
        $phase='install';$ended=$false
        $installed=Invoke-LabTlsWindowsGuest $context (Get-LabTlsHyperVLeafInstallGuestScript) @($audit,'renewed',[Convert]::ToBase64String($leaf.Value.CertificateDer),$leaf.Value.CertificateSha256,$container,$csr.Modulus) $budget;$ended=$true
        $record=[pscustomobject][ordered]@{ContractVersion='SqlServerLab.AuthenticatedTlsWindowsLab/0.1';AuditId=$audit;DataRoot=$Parameters.DataRoot;StateRoot=$state;ControllerId=$Parameters.TlsControllerId;LocationId=$Parameters.TlsLocationId;AuthorityRef=$authority.Authority.Ref;ClientRef=$authority.Client.Ref;RegistrySha256=$authority.RegistrySha256;
            RunId=$run.RunId;InstanceId='primary';ScopeId=[string]$context.Run.scopeId;VmId=[string]$context.Instance.vmId;Host=$hostName;Port=[int]$context.Instance.port;SqlVersion='2025';Patch='base';SqlBuild=$profile.SqlBuild;ComputerName=[string]$prepared.ComputerName;ProcessId=0;StartedAt='';BootedAt='';CertificateSha256=$leaf.Value.CertificateSha256;CertificateDer=[Convert]::ToBase64String($leaf.Value.CertificateDer);CertificateThumbprint=$installed.Thumbprint;NotAfterUtc=$leaf.Value.NotAfterUtc;KeyContainer=$container;KeyModulus=$csr.Modulus;CertreqSha256=$prepared.CertreqSha256}
        $phase='observe';$ended=$false
        $observed=Invoke-LabTlsWindowsGuest $context (Get-LabTlsWindowsObserveGuest) @($audit,$record.ComputerName,$record.CertificateThumbprint,$record.CertificateSha256,$container,$csr.Modulus,$record.CertreqSha256,$record.Host,$record.Port) $budget;$ended=$true
        $record.ProcessId=$observed.ProcessId;$record.StartedAt=$observed.StartedAt;$record.BootedAt=$observed.BootedAt
        $path=Get-LabTlsWindowsRecordPath $state $run.RunId primary
        Initialize-LabTlsCaPrivateDirectory (Split-Path -Parent $path) $sid -NewOnly
        Write-LabTlsCaPrivateFile $path $sid (ConvertTo-LabTlsRegistryWriterBytes $record)
        $phase='qualification';$ended=$false
        $qualification=Test-LabAuthenticatedTlsWindowsEnvironment $run.RunId primary $state $budget;$ended=$true
        $live=Get-LabSsisPrerequisiteContext -RunId $run.RunId -InstanceId primary -StateRoot $state
        $builder=[Data.SqlClient.SqlConnectionStringBuilder]::new([string]$live.Instance.connectionString)
        $builder['Encrypt']=$true;$builder['TrustServerCertificate']=$false
        $connectionPath=Join-Path $live.Directory 'connection-info.json'
        $connectionHash=(Get-FileHash -LiteralPath $connectionPath).Hash
        $connectionInfo=Read-LabDiagnosticJson $connectionPath
        $instance=@($connectionInfo.instances|Where-Object id -CEQ 'primary')
        if($instance.Count -ne 1 -or [string]$instance[0].vmId -cne $record.VmId -or (Get-FileHash -LiteralPath $connectionPath).Hash -cne $connectionHash){throw 'TLS_WINDOWS_CONNECTION_METADATA_CHANGED'}
        $instance[0].connectionString=$builder.ConnectionString
        foreach($sql in @($instance[0].sqlInstances)){
            # Nur die Hostvorlagen sind durch den IPv4-SAN qualifiziert. Der
            # separate InVm-/localhost-Kontext behält seinen Functionalvertrag.
            foreach($name in @('ConnectionString','HostConnectionString')){
                if($sql.$name){$template=[Data.SqlClient.SqlConnectionStringBuilder]::new([string]$sql.$name);try{$template.Encrypt=$true;$template.TrustServerCertificate=$false;$sql.$name=$template.ConnectionString}finally{$template.Clear()}}
            }
        }
        Write-LabArtifactJsonAtomic -Path $connectionPath -InputObject $connectionInfo
        $run.Instances[0]=$instance[0]
        if($run.GeneratedSqlAccess -and $run.GeneratedSqlAccess.connectionString){
            $generated=[Data.SqlClient.SqlConnectionStringBuilder]::new([string]$run.GeneratedSqlAccess.connectionString)
            try{$generated.Encrypt=$true;$generated.TrustServerCertificate=$false;$run.GeneratedSqlAccess.connectionString=$generated.ConnectionString}finally{$generated.Clear()}
        }
        $builder.Clear()
        Write-LabTlsCaPrivateFile (Join-Path $operation 'ready.json') $sid (ConvertTo-LabTlsRegistryWriterBytes @{Status='READY';RunId=$run.RunId;ClientChecks=2;ConsumerEnded=$true})
        $run|Add-Member -NotePropertyName TlsQualification -NotePropertyValue $qualification -Force
        return $run
    }catch{
        $failure=$_.Exception;$cursor=$failure
        while($cursor){if($cursor.Data.Contains('ConsumerEnded') -and $cursor.Data['ConsumerEnded'] -is [bool]){$ended=$cursor.Data['ConsumerEnded'];break};$cursor=$cursor.InnerException}
        $wrapped=[InvalidOperationException]::new('TLS_WINDOWS_INITIALIZATION_FAILED',$failure)
        $wrapped.Data['ConsumerEnded']=$ended;$wrapped.Data['Phase']=$phase
        throw $wrapped
    }
}

function New-LabAuthenticatedTlsWindowsEnvironment {
    param([hashtable]$Parameters)
    $allowed=@('Version','Provider','TrustServerCertificate','TlsCandidateId','TlsControllerId','TlsLocationId','TlsClientPlatform','DataRoot','StateRoot','Profile','Cpu','MemoryMB','AutoStart','Port','InstanceId','LabName','NonInteractive','SkipAssessment','AllowResourceOvercommit','Verbose','ErrorAction')
    if(@($Parameters.Keys|Where-Object {$_ -cnotin $allowed}).Count -or $Parameters.Version -cne '2025' -or $Parameters.Provider -cne 'hyperv' -or -not $Parameters.DataRoot -or
        ($Parameters.ContainsKey('InstanceId') -and $Parameters.InstanceId -cne 'primary') -or ($Parameters.ContainsKey('AutoStart') -and $Parameters.AutoStart -cne 'off') -or
        ($Parameters.ContainsKey('TlsClientPlatform') -and $Parameters.TlsClientPlatform -cne 'Windows')){throw 'TLS_WINDOWS_CAPABILITY_UNSUPPORTED'}
    foreach($name in @('TlsCandidateId','TlsControllerId','TlsLocationId')){if(-not (Test-LabTlsRequestReference $Parameters[$name])){throw 'TLS_WINDOWS_CA_SELECTION_REQUIRED'}}
    # Offline-OOBE benötigt Mount-VHD. Vor Registry-/Run-/VM-Effekten die
    # tatsächliche Erhöhung verlangen; eine Hyper-V-Gruppenmitgliedschaft
    # allein erlaubt diesen Hostschritt nicht. Kein UAC-Start oder Retry hier.
    if(-not (Test-LabAdministrator)){throw 'TLS_WINDOWS_CREATE_ELEVATED_RUNNER_REQUIRED'}
    Assert-LabTlsCaCandidateCapability
    $stateArgument=if($Parameters.ContainsKey('StateRoot')){$Parameters.StateRoot}else{$null}
    $state=Get-LabStateRoot -ExplicitPath $stateArgument
    $selection=Get-HyperVManifestFallbackArtifactSelection -SqlVersion 2025 -InstallationType desktop-experience -MinimumEvaluationDaysRemaining 30 -StateRoot $state
    if(-not $selection.Selected -or [string]$selection.Selected.sql.version -cne '2025' -or [string]$selection.Selected.sql.build -cnotmatch '\A2025\.0170\.1000\.0?7(?:\s|$)'){throw 'TLS_WINDOWS_PREPARED_RTM_IMAGE_REQUIRED'}
    $audit=[guid]::NewGuid().ToString('D')
    # Der kanonische Manifestparser setzt auch Netzwerk-, Windows- und
    # Aktivierungsdefaults. Die vorgeprüfte Image-ID wird ausdrücklich fixiert;
    # keine zweite automatische Imagewahl im nachfolgenden Erstellungsaufruf.
    $createManifest=New-LabTlsWindowsCreateManifest $Parameters $selection.Selected.artifactId $audit
    $authority=Register-LabTlsOperationalAuthority $Parameters.DataRoot $Parameters.TlsControllerId $Parameters.TlsLocationId $Parameters.TlsCandidateId
    $sid=$authority.Native.UserSid
    $operations=Join-Path $Parameters.DataRoot 'State/authenticated-tls-windows-operations'
    Initialize-LabTlsCaPrivateDirectory $operations $sid
    $operation=Join-Path $operations $audit;Initialize-LabTlsCaPrivateDirectory $operation $sid -NewOnly
    Write-LabTlsCaPrivateFile (Join-Path $operation 'intent.json') $sid (ConvertTo-LabTlsRegistryWriterBytes @{ContractVersion='SqlServerLab.WindowsTlsCreateIntent/0.1';AuditId=$audit;Status='NEW_OWN_RUN_PENDING'})
    $manifestPath=Join-Path $operation 'create-manifest.json'
    Write-LabTlsCaPrivateFile $manifestPath $sid $createManifest
    $inner=@{Manifest=$manifestPath;StateRoot=$state;DataRoot=$Parameters.DataRoot;NonInteractive=$true}
    foreach($key in @('SkipAssessment','AllowResourceOvercommit','Verbose','ErrorAction')){if($Parameters.ContainsKey($key)){$inner[$key]=$Parameters[$key]}}
    $run=$null;$ended=$true;$phase='create'
    try{
        # Die kanonische nichtinteraktive Hyper-V-Erstellung verlangt ein
        # SecureString-Gastkennwort. Intern generieren und ausdrücklich übergeben
        # verhindert sowohl einen Dialog als auch die normale Einmalausgabe.
        $inner.GuestPassword=New-HyperVSqlUnattendedPassword
        try{$run=New-SqlServerLab @inner}finally{$inner.GuestPassword.Dispose();$inner.Remove('GuestPassword')}
        $ended=$false
        return Initialize-LabTlsWindowsOwnedRun -Run $run -Parameters $Parameters -Authority $authority -Operation $operation -Audit $audit -StateRoot $state
    }catch{
        $failure=$_.Exception
        $cause=$_.Exception
        while($cause){if($cause.Data.Contains('ConsumerEnded') -and $cause.Data['ConsumerEnded'] -is [bool]){$ended=$cause.Data['ConsumerEnded'];if($cause.Data.Contains('Phase')){$phase=[string]$cause.Data['Phase']};break};$cause=$cause.InnerException}
        # Ein fehlender Rückgabewert der kanonischen Erstellung ist kein Beleg
        # für fehlende Effekte oder beendete Gastoperationen. Deren persistente
        # Run-/Cleanupzustände bleiben erhalten; keine namensbasierte Suche/Entfernung.
        if($phase -ceq 'create' -and -not $run){$ended=$false}
        $failureCode=if($failure.Message -cmatch '\A([A-Z][A-Z0-9_]+)(?::|\z)'){$Matches[1]}else{'UNCLASSIFIED'}
        Write-LabTlsCaPrivateFile (Join-Path $operation 'failure.json') $sid (ConvertTo-LabTlsRegistryWriterBytes @{Status='FAILED';Phase=$phase;FailureCode=$failureCode;ConsumerEnded=$ended;Cleanup=$(if($ended){'OWN_RUN_ONLY'}else{'RECOVERY_RETAIN_OWN_RUN'})})
        if($run -and $ended){$removed=Remove-SqlServerLab -RunId $run.RunId -StateRoot $state -Force -Confirm:$false;if($removed.Status -cne 'REMOVED'){throw 'TLS_WINDOWS_FAILED_CLEANUP_RECOVERY_REQUIRED'}}
        if(-not $ended){throw [InvalidOperationException]::new('TLS_WINDOWS_CONSUMER_RECOVERY_REQUIRED',$failure)}
        throw [InvalidOperationException]::new(('TLS_WINDOWS_CREATE_FAILED_'+$phase.ToUpperInvariant()),$failure)
    }
}
