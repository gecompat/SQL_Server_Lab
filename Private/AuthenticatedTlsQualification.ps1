#Requires -Version 7.2
function Invoke-LabTlsStrictSqlClient {
    param([int]$Port,[securestring]$Password,[Parameter(Mandatory)][string]$ExpectedBuild,[ValidatePattern('^[0-9.]+$')][string]$HostName='127.0.0.1')
    $builder=[Data.SqlClient.SqlConnectionStringBuilder]::new()
    $builder['Data Source']="tcp:$HostName,$Port";$builder['Initial Catalog']='master';$builder['User ID']='sa'
    $builder['Encrypt']=$true;$builder['TrustServerCertificate']=$false;$builder['Pooling']=$false
    $builder['Connect Timeout']=10;$builder['ConnectRetryCount']=0
    $pointer=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
    try{$builder['Password']=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)}finally{[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)}
    $connection=[Data.SqlClient.SqlConnection]::new($builder.ConnectionString);$builder.Clear()
    try{
        $connection.Open();$command=$connection.CreateCommand();$command.CommandTimeout=10
        try{
            $command.CommandText="SELECT CONVERT(varchar(32),SERVERPROPERTY('ProductVersion')),encrypt_option FROM sys.dm_exec_connections WHERE session_id=@@SPID;"
            $reader=$command.ExecuteReader()
            try{if(-not $reader.Read() -or $reader.GetString(0) -cne $ExpectedBuild -or $reader.GetString(1) -cne 'TRUE' -or $reader.Read()){throw 'TLS_QUALIFICATION_SQLCLIENT_RESULT_INVALID'}}finally{$reader.Dispose()}
        }finally{$command.Dispose()}
    }catch{throw 'TLS_QUALIFICATION_SQLCLIENT_FAILED'}finally{$connection.Dispose()}
}

function Invoke-LabTlsStrictSqlcmd {
    param([int]$Port,[securestring]$Password,[object]$Client,[Parameter(Mandatory)][string]$ExpectedBuild,[ValidatePattern('^[0-9.]+$')][string]$HostName='127.0.0.1')
    $exe=$Client.Details.SqlcmdPath;$before=Read-LabTlsContextBinaryMetadata $exe 'sqlcmd.exe'
    if($before.DiskSha256 -cne $Client.Details.SqlcmdDiskSha256){throw 'TLS_QUALIFICATION_SQLCMD_CHANGED'}
    $start=[Diagnostics.ProcessStartInfo]::new($exe);$start.UseShellExecute=$false;$start.CreateNoWindow=$true
    $start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    foreach($key in @($start.Environment.Keys)){if($key.StartsWith('SQLCMD',[StringComparison]::OrdinalIgnoreCase)){$null=$start.Environment.Remove($key)}}
    foreach($arg in @('-S',"tcp:$HostName,$Port",'-U','sa','-N','-b','-l','10','-h','-1','-W','-s','|','-Q',
        "SET NOCOUNT ON; WAITFOR DELAY '00:00:03'; SELECT CONVERT(varchar(32),SERVERPROPERTY('ProductVersion')),encrypt_option FROM sys.dm_exec_connections WHERE session_id=@@SPID;")){$start.ArgumentList.Add($arg)}
    $process=[Diagnostics.Process]::new();$process.StartInfo=$start;$driver=$null;$started=$false
    try{
        $pointer=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
        try{$start.Environment['SQLCMDPASSWORD']=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)}finally{[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)}
        $started=$process.Start();$null=$start.Environment.Remove('SQLCMDPASSWORD')
        $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync();$deadline=[datetime]::UtcNow.AddSeconds(25)
        while(-not $process.WaitForExit(100)){
            if([datetime]::UtcNow -ge $deadline){$process.Kill($true);$process.WaitForExit();throw 'TLS_QUALIFICATION_SQLCMD_TIMEOUT'}
            if(-not $driver){
                $process.Refresh()
                $loaded=@($process.Modules|Where-Object {$_.ModuleName -match '^msodbcsql[0-9]+\.dll$'})
                if($loaded.Count -eq 1){$driver=Read-LabTlsContextBinaryMetadata $loaded[0].FileName $loaded[0].ModuleName}
            }
        }
        if($process.ExitCode -ne 0 -or $stdout.GetAwaiter().GetResult().Trim() -cne ($ExpectedBuild+'|TRUE') -or
            $stderr.GetAwaiter().GetResult().Trim().Length -ne 0 -or -not $driver){throw 'TLS_QUALIFICATION_SQLCMD_FAILED'}
        if((Read-LabTlsContextBinaryMetadata $exe 'sqlcmd.exe').DiskSha256 -cne $before.DiskSha256 -or
            (Read-LabTlsContextBinaryMetadata $driver.Path ([IO.Path]::GetFileName($driver.Path))).DiskSha256 -cne $driver.DiskSha256){throw 'TLS_QUALIFICATION_BINARY_CHANGED'}
        return [pscustomobject]@{SqlcmdSha256=$before.DiskSha256;LoadedOdbcSha256=$driver.DiskSha256;LoadedOdbcBytes=$driver.DiskBytes}
    }catch{throw 'TLS_QUALIFICATION_SQLCMD_FAILED'}finally{
        $null=$start.Environment.Remove('SQLCMDPASSWORD')
        if($started -and -not $process.HasExited){$process.Kill($true);$process.WaitForExit()};$process.Dispose()
    }
}

function Test-LabAuthenticatedTlsEnvironment {
    param([string]$RunId,[string]$InstanceId,[string]$StateRoot,[object]$Budget,[object]$RestartCandidate,[string]$ExpectedSourceSha256,[object]$RebindLock,[string]$RecoveryTransactionId)
    $bound=Get-LabTlsOwnBinding $StateRoot $RunId $InstanceId
    $record=$bound.Record;$authority=$bound.Authority
    if($record.ContractVersion -ceq 'SqlServerLab.AuthenticatedTlsWindowsLab/0.1'){
        if($PSBoundParameters.ContainsKey('RestartCandidate')){throw 'TLS_WINDOWS_RESTART_REQUIRES_NEW_QUALIFICATION'}
        return Test-LabAuthenticatedTlsWindowsEnvironment $RunId $InstanceId $StateRoot $Budget
    }
    if($PSBoundParameters.ContainsKey('RestartCandidate')){
        if($ExpectedSourceSha256 -cnotmatch '\A[0-9a-f]{64}\z' -or (Get-LabTlsCaByteDigest $bound.Bytes) -cne $ExpectedSourceSha256){throw 'TLS_REBIND_SOURCE_CHANGED'}
        Assert-LabTlsRebindCandidateLock $RebindLock $StateRoot
        if($RecoveryTransactionId){
            $binding=[pscustomobject]@{Directory=(Join-Path $StateRoot 'authenticated-tls-rebind');Native=$authority.Native}
            $history=Get-LabTlsRebindHistoryState $binding $record $bound.Bytes -AllowIncomplete
            if(-not $history.Pending -or $history.Pending.Id -cne $RecoveryTransactionId -or $history.Pending.Status -cne 'PENDING' -or
                (Get-LabTlsCaByteDigest (ConvertTo-LabTlsRegistryWriterBytes $RestartCandidate)) -cne $history.Pending.CandidateSha256){throw 'TLS_REBIND_RECOVERY_CANDIDATE_INVALID'}
            Assert-LabTlsRestartCandidate $history.Pending.Original $RestartCandidate
        }else{Assert-LabTlsRestartCandidate $record $RestartCandidate}
        $record=$RestartCandidate
    }else{Assert-LabTlsRebindCommitted $bound $StateRoot}
    $profile=Get-LabTlsBindingSqlProfile $record
    Assert-LabTlsSqlCatalogProfile $profile
    $provider=Get-LabTlsBindingProvider $record
    if($null -eq $Budget){$Budget=New-LabTlsRuntimeBudget -Provider $provider -StateRoot $StateRoot -Record $record}
    $context=Assert-LabTlsSqlCertificateBinding $record $StateRoot $Budget
    if($record.ContractVersion-ceq'SqlServerLab.AuthenticatedTlsLab/0.4'){
        if($PSBoundParameters.ContainsKey('RestartCandidate')){throw 'TLS_LINUX_RESTART_REQUIRES_NEW_CLIENT_GENERATION'}
        return Test-LabTlsLinuxEnvironment $bound $Budget
    }
    $password=Get-LabSecret -Path $context.RunDirectory -Name 'sa-password'
    if(-not $password){throw 'TLS_QUALIFICATION_SECRET_UNAVAILABLE'}
    Invoke-LabTlsStrictSqlClient $record.Port $password $profile.SqlBuild
    $odbc=Invoke-LabTlsStrictSqlcmd $record.Port $password $authority.Client $profile.SqlBuild
    $null=Assert-LabTlsSqlCertificateBinding $record $StateRoot $Budget
    $again=Get-LabTlsOwnBinding $StateRoot $RunId $InstanceId
    if((Get-LabTlsCaByteDigest $again.Bytes) -cne (Get-LabTlsCaByteDigest $bound.Bytes)){throw 'TLS_QUALIFICATION_BINDING_CHANGED'}
    if($PSBoundParameters.ContainsKey('RestartCandidate')){Assert-LabTlsRebindCandidateLock $RebindLock $StateRoot}
    else{Assert-LabTlsRebindCommitted $again $StateRoot}
    $now=[DateTimeOffset]::UtcNow;$expires=$now.AddMinutes(15)
    $leafEnd=[DateTimeOffset]::ParseExact($record.NotAfterUtc,'o',[Globalization.CultureInfo]::InvariantCulture)
    if($leafEnd -lt $expires){$expires=$leafEnd}
    return [pscustomobject][ordered]@{ContractVersion='SqlServerLab.TlsQualification/0.1';Status='QUALIFIED';QualifiedAt=$now.ToString('O');ExpiresAt=$expires.ToString('O');
        Encrypt=$true;TrustServerCertificate=$false;Provider=$provider;SqlVersion=$profile.SqlVersion;Patch=$profile.Patch;SqlBuild=$profile.SqlBuild;
        RunId=$RunId;InstanceId=$InstanceId;ScopeId=$record.ScopeId;ContainerId=$record.ContainerId;ImageId=$record.ImageId;StartedAt=$record.StartedAt;
        Endpoint=[pscustomobject]@{Host='127.0.0.1';Port=$record.Port;IdentityKind='IP';Identity='127.0.0.1'};
        AuthorityRef=$authority.Authority.Ref;AuthorityGeneration=$authority.Authority.Generation;ClientRef=$authority.Client.Ref;ClientGeneration=$authority.Client.Generation;
        TrustScopeRef=$authority.Authority.TrustScopeRef;Store='CURRENT_USER_ROOT';ActorDigest=$authority.ActorDigest;RootDigest=$authority.RootDigest;RegistrySha256=$authority.RegistrySha256;
        CaSha256=$authority.Authority.CertificateSha256;LeafSha256=$record.CertificateSha256;LeafNotAfterUtc=$record.NotAfterUtc;
        SqlClientSha256=$authority.Client.Details.SqlClientDiskSha256;SqlClientMvid=$authority.Client.Details.SqlClientLoadedMvid;
        SqlcmdSha256=$odbc.SqlcmdSha256;LoadedOdbcSha256=$odbc.LoadedOdbcSha256;LoadedOdbcBytes=$odbc.LoadedOdbcBytes;
        Evidence='FRESH_NATIVE_SQLCLIENT_AND_ODBC_SQLCMD';WireCertificateFingerprint='NOT_OBSERVED'}
}

function Export-LabAuthenticatedTlsEnvironment {
    param([string]$OutputDirectory,[string]$StateRoot,[string]$RunId,[string]$InstanceId)
    if(-not $OutputDirectory -or -not $StateRoot -or -not $RunId -or -not $InstanceId){throw 'TLS_EXPORT_EXPLICIT_SELECTION_REQUIRED'}
    $bound=Get-LabTlsOwnBinding $StateRoot $RunId $InstanceId;$sid=$bound.Authority.Native.UserSid
    $windows=$bound.Record.ContractVersion -ceq 'SqlServerLab.AuthenticatedTlsWindowsLab/0.1'
    if(-not $windows){Assert-LabTlsRebindCommitted $bound $StateRoot}
    $provider=Get-LabTlsBindingProvider $bound.Record
    $profile=Get-LabTlsBindingSqlProfile $bound.Record
    $budget=if($windows){New-LabTlsWindowsBudget}else{New-LabTlsRuntimeBudget -Provider $provider -StateRoot $StateRoot -Record $bound.Record}
    $directory=Assert-LabDiagnosticPath ([IO.Path]::GetFullPath($OutputDirectory))
    # A fresh dedicated directory prevents overwriting the protected default group.
    if(Test-Path -LiteralPath $directory){throw 'TLS_EXPORT_NEW_DIRECTORY_REQUIRED'}
    $qualification=Test-LabAuthenticatedTlsEnvironment $RunId $InstanceId $StateRoot $budget
    $record=$bound.Record
    if($windows){
        $context=Assert-LabTlsWindowsCertificateBinding $bound $budget
        $secret=Get-LabTlsWindowsSqlSecret $context.Directory
    }else{
        $context=Assert-LabTlsOwnContainer $record $StateRoot $budget
        $secret=Get-LabSecret -Path $context.RunDirectory -Name 'sa-password'
    }
    $hostName='127.0.0.1';$port=$record.Port
    if($windows){$hostName=$record.Host}
    if($record.ContractVersion-ceq'SqlServerLab.AuthenticatedTlsLab/0.4'){$hostName='localhost';$port=1433}
    try{$connection=New-SqlConnectionString -HostName $hostName -Port $port -IncludePassword -SaPassword $secret}finally{if($windows -and $secret){$secret.Dispose()}}
    $builder=[Data.SqlClient.SqlConnectionStringBuilder]::new($connection);$builder['TrustServerCertificate']=$false;$builder['Data Source']="tcp:$hostName,$port"
    $entry=[pscustomobject][ordered]@{key=$profile.ExportKey;status='READY';runtimeStatus='READY';platform=$(if($windows){'windows'}else{'linux'});provider=$provider;sqlVersion=$profile.SqlVersion;patch=$profile.Patch;resolvedVersion=$profile.SqlBuild;
        runId=$RunId;instanceId=$InstanceId;host=$hostName;port=$port;database='master';username='sa';password=$builder.Password;encrypt=$true;trustServerCertificate=$false;autoStart='off';connectionString=$builder.ConnectionString}
    $builder.Clear()
    $entryBytes=ConvertTo-LabTlsRegistryWriterBytes $entry
    $body=[pscustomobject][ordered]@{ContractVersion='SqlServerLab.SignedTlsExport/0.1';EnvironmentSha256=(Get-LabTlsCaByteDigest $entryBytes);Qualification=$qualification}
    $bodyBytes=ConvertTo-LabTlsRegistryWriterBytes $body
    $ca=Get-LabTlsCaCandidateBinding $record.DataRoot $record.ControllerId $record.LocationId $bound.Authority.Authority.CandidateId
    $entropy=[Text.Encoding]::UTF8.GetBytes((Get-LabTlsPayloadDigest @('SqlServerLab.TlsCaCandidateKey/0.1',$bound.Authority.Authority.CandidateId,$record.ControllerId,$record.LocationId,$ca.RootMetadataDigest,$ca.ActorDigest)))
    $key=$null
    try{$key=Open-LabTlsCaSigningKey $ca.Encrypted $entropy $ca.Der;$signature=$key.SignData($bodyBytes,[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pkcs1)}finally{if($key){$key.Dispose()}}
    $selectionRule='explicit own Windows current-user qualified Docker or Podman '+$profile.Version+' only; validate signature, freshness and current bindings before use'
    if($windows){$selectionRule='explicit own Windows Hyper-V SQL2025 RTM only; validate signature, freshness and current VM, boot, service and certificate bindings before each login'}
    if($record.ContractVersion-ceq'SqlServerLab.AuthenticatedTlsLab/0.4'){$selectionRule='explicit own isolated Linux client and SQL network namespace, Windows controller; validate same signed bytes and current child/parent bindings before each login through the live session'}
    $document=[pscustomobject][ordered]@{'$schema'='./TestUmgebung.schema.json';contractVersion='SqlServerLab.TestEnvironment/2.0';generatedAt=[DateTimeOffset]::UtcNow.ToString('O');groupStatus='READY';
        selectionRule=$selectionRule;containsPlainTextSecrets=$true;environments=@($entry);
        qualification=[pscustomobject]@{algorithm='RSA3072_SHA256_PKCS1';payload=[Convert]::ToBase64String($bodyBytes);signature=[Convert]::ToBase64String($signature);caDer=[Convert]::ToBase64String($ca.Der)}}
    $publish=Get-LabTlsOwnBinding $StateRoot $RunId $InstanceId
    if($windows){
        if((Get-LabTlsCaByteDigest $publish.Bytes) -cne (Get-LabTlsCaByteDigest $bound.Bytes)){throw 'TLS_EXPORT_BINDING_CHANGED'}
        $null=Assert-LabTlsWindowsCertificateBinding $publish $budget
    }else{Assert-LabTlsRebindCommitted $publish $StateRoot}
    Initialize-LabTlsCaPrivateDirectory $directory $sid -NewOnly
    try{
        Write-LabTlsCaPrivateFile (Join-Path $directory 'TestUmgebung.json') $sid (ConvertTo-LabTlsRegistryWriterBytes $document)
        $schema=Read-LabTlsRegistryFileBytes (Join-Path $script:ModuleRoot 'Schemas/test-environment-authenticated.schema.json')
        Write-LabTlsCaPrivateFile (Join-Path $directory 'TestUmgebung.schema.json') $sid $schema
        $text="# Qualifizierter SQL-TLS-Export`n`nEncrypt=True;TrustServerCertificate=False. SqlServerLab.TestEnvironment/2.0.`nWindows CurrentUser/Root, SqlClient und ODBC sqlcmd -N ohne -C. Keine automatische Discoveryumschaltung.`nVor Verwendung Read-SqlServerLabQualifiedTestEnvironment mit ausdrücklicher RunId, InstanceId und StateRoot aufrufen. Dessen ExportBytes vor späterer Nutzung erneut prüfen; keinen Exportpfad nachlesen.`nSignatur, Ablauf und aktuelle CA-/Client-/Runbindung bleiben verbindlich; veraltete Exporte erneut explizit erzeugen. Ein Schemaoverride erteilt keine Qualifikation.`nJSON und Readerergebnis enthalten Klartextkennwörter. Nur im aktuellen Benutzerkontext verwenden; nicht ausgeben, weitergeben oder versionieren.`n"
        if($record.ContractVersion-ceq'SqlServerLab.AuthenticatedTlsLab/0.4'){$text=Get-LabTlsLinuxExportUsageText}
        Write-LabTlsCaPrivateFile (Join-Path $directory 'TestUmgebung.prompt.md') $sid ([Text.Encoding]::UTF8.GetBytes($text))
        Write-LabTlsCaPrivateFile (Join-Path $directory 'TestUmgebung.md') $sid ([Text.Encoding]::UTF8.GetBytes($text))
        $lines=[Collections.Generic.List[string]]::new()
        $lines.Add('# Klartextkennwort; signiertes TestUmgebung.json ist autoritativ. Vor Verwendung frisch validieren.')
        $lines.Add('SQL_SERVER_LAB_TEST_ENV_CONTRACT="SqlServerLab.TestEnvironment/2.0"')
        foreach($pair in ([ordered]@{HOST=$entry.host;PORT=[string]$entry.port;RUN_ID=$RunId;INSTANCE_ID=$InstanceId;PASSWORD=$entry.password;
            CONNECTION_STRING=$entry.connectionString;ENCRYPT='true';TRUST_SERVER_CERTIFICATE='false';QUALIFICATION_EXPIRES_AT=$qualification.ExpiresAt}).GetEnumerator()){
            $lines.Add('SQL_SERVER_LAB_'+$profile.ExportKey+'_'+$pair.Key+'='+(ConvertTo-LabDotEnvValue ([string]$pair.Value)))
        }
        Write-LabTlsCaPrivateFile (Join-Path $directory 'TestUmgebung.env') $sid ([Text.Encoding]::UTF8.GetBytes(($lines -join "`n")+"`n"))
        $verified=Test-LabTlsQualifiedExport -Path (Join-Path $directory 'TestUmgebung.json') -StateRoot $StateRoot -RunId $RunId -InstanceId $InstanceId -Budget $budget
        if(-not $verified){throw 'TLS_EXPORT_READBACK_INVALID'}
        return [pscustomobject]@{Directory=$directory;JsonPath=(Join-Path $directory 'TestUmgebung.json');SchemaPath=(Join-Path $directory 'TestUmgebung.schema.json');PromptPath=(Join-Path $directory 'TestUmgebung.prompt.md');
            MarkdownPath=(Join-Path $directory 'TestUmgebung.md');EnvPath=(Join-Path $directory 'TestUmgebung.env');GroupStatus='READY';Entries=1;Ready=1;Encrypt=$true;TrustServerCertificate=$false;QualificationExpiresAt=$qualification.ExpiresAt}
    }catch{throw 'TLS_EXPORT_INCOMPLETE_RECOVERY_REQUIRED'}
}

function Get-LabTlsQualifiedExportUtcNow { return [DateTimeOffset]::UtcNow }

function Read-LabTlsQualifiedExportSnapshot {
    param([string]$Path,[string]$StateRoot,[string]$RunId,[string]$InstanceId,[object]$Budget,[byte[]]$ExportBytes,[switch]$FromBytes,[switch]$AllowLinuxController)
    # Own the bytes before parsing or invoking any observation. Consumers can
    # revalidate this same snapshot without reopening the original export path.
    if($FromBytes){
        if($null -eq $ExportBytes -or $ExportBytes.Length -eq 0 -or $ExportBytes.Length -gt 65536){throw 'TLS_EXPORT_BYTES_INVALID'}
        $bytes=[byte[]]$ExportBytes.Clone()
    }
    $bound=Get-LabTlsOwnBinding $StateRoot $RunId $InstanceId
    if($bound.Record.ContractVersion-ceq'SqlServerLab.AuthenticatedTlsLab/0.4'-and-not$AllowLinuxController){throw 'TLS_LINUX_LIVE_SESSION_REQUIRED'}
    $windows=$bound.Record.ContractVersion -ceq 'SqlServerLab.AuthenticatedTlsWindowsLab/0.1'
    if(-not $windows){Assert-LabTlsRebindCommitted $bound $StateRoot}
    $provider=Get-LabTlsBindingProvider $bound.Record
    $profile=Get-LabTlsBindingSqlProfile $bound.Record
    if($null -eq $Budget){$Budget=if($windows){New-LabTlsWindowsBudget}else{New-LabTlsRuntimeBudget -Provider $provider -StateRoot $StateRoot -Record $bound.Record}}
    if($Budget.Provider -cne $provider){return $false}
    if(-not $FromBytes){$bytes=Read-LabTlsCaPrivateFile $Path $bound.Authority.Native.UserSid 65536}
    $document=Read-LabTlsBoundJson $bytes @('$schema','contractVersion','generatedAt','groupStatus','selectionRule','containsPlainTextSecrets','environments','qualification')
    $schema=Join-Path $script:ModuleRoot 'Schemas/test-environment-authenticated.schema.json'
    if(-not (Test-Json -Json ([Text.UTF8Encoding]::new($false,$true).GetString($bytes)) -SchemaFile $schema -ErrorAction SilentlyContinue)){return $false}
    if($document.contractVersion -cne 'SqlServerLab.TestEnvironment/2.0' -or $document.groupStatus -cne 'READY' -or $document.environments.Count -ne 1 -or $document.qualification.algorithm -cne 'RSA3072_SHA256_PKCS1'){return $false}
    $entry=$document.environments[0];$signed=[Convert]::FromBase64String($document.qualification.payload)
    $body=Read-LabTlsBoundJson $signed @('ContractVersion','EnvironmentSha256','Qualification')
    if($body.ContractVersion -cne 'SqlServerLab.SignedTlsExport/0.1' -or $body.EnvironmentSha256 -cne (Get-LabTlsCaByteDigest (ConvertTo-LabTlsRegistryWriterBytes $entry)) -or
        $entry.encrypt -isnot [bool] -or $entry.encrypt -ne $true -or $entry.trustServerCertificate -isnot [bool] -or $entry.trustServerCertificate -ne $false){return $false}
    $q=$body.Qualification;$r=$bound.Record;$a=$bound.Authority
    $observedAt=Get-LabTlsQualifiedExportUtcNow
    $qualifiedAt=[DateTimeOffset]::Parse($q.QualifiedAt,[Globalization.CultureInfo]::InvariantCulture)
    $expiresAt=[DateTimeOffset]::Parse($q.ExpiresAt,[Globalization.CultureInfo]::InvariantCulture)
    $linux=$r.ContractVersion-ceq'SqlServerLab.AuthenticatedTlsLab/0.4'
    if($windows){
        Assert-LabTlsWindowsExportQualification $bound $q $entry
        if($qualifiedAt -gt $observedAt -or $expiresAt -le $observedAt -or $expiresAt -le $qualifiedAt -or ($expiresAt-$qualifiedAt).TotalMinutes -gt 15){return $false}
    }elseif($linux){
        Assert-LabTlsLinuxExportQualification $bound $Budget $q $entry
        if($qualifiedAt-gt$observedAt-or$expiresAt-le$observedAt-or($expiresAt-$qualifiedAt).TotalMinutes-gt15-or$expiresAt-le$qualifiedAt){return $false}
    }elseif($q.Provider -cne $provider -or $entry.provider -cne $provider -or
        $q.SqlVersion -cne $profile.SqlVersion -or $q.Patch -cne $profile.Patch -or $q.SqlBuild -cne $profile.SqlBuild -or
        $entry.sqlVersion -cne $profile.SqlVersion -or $entry.patch -cne $profile.Patch -or $entry.resolvedVersion -cne $profile.SqlBuild -or $entry.key -cne $profile.ExportKey -or
        $q.RunId -cne $RunId -or $q.InstanceId -cne $InstanceId -or $q.RegistrySha256 -cne $a.RegistrySha256 -or $q.ActorDigest -cne $a.ActorDigest -or
        $q.AuthorityRef -cne $a.Authority.Ref -or $q.ClientRef -cne $a.Client.Ref -or $q.LeafSha256 -cne $r.CertificateSha256 -or
        $q.Status -cne 'QUALIFIED' -or $q.ContainerId -cne $r.ContainerId -or $q.ScopeId -cne $r.ScopeId -or $q.ImageId -cne $r.ImageId -or $q.StartedAt -cne $r.StartedAt -or
        $q.ClientGeneration -ne $a.Client.Generation -or $q.AuthorityGeneration -ne $a.Authority.Generation -or $q.TrustScopeRef -cne $a.Authority.TrustScopeRef -or
        $q.SqlClientSha256 -cne $a.Client.Details.SqlClientDiskSha256 -or $q.SqlcmdSha256 -cne $a.Client.Details.SqlcmdDiskSha256 -or
        $entry.runId -cne $RunId -or $entry.instanceId -cne $InstanceId -or $entry.port -ne $r.Port -or $entry.host -cne '127.0.0.1' -or
        $q.Endpoint.Port -ne $r.Port -or $q.Endpoint.Host -cne '127.0.0.1' -or
        $qualifiedAt -gt $observedAt -or $expiresAt -le $observedAt -or ($expiresAt-$qualifiedAt).TotalMinutes -gt 15){return $false}
    $der=[Convert]::FromBase64String($document.qualification.caDer)
    if((Get-LabTlsCaByteDigest $der) -cne $a.Authority.CertificateSha256 -or (Get-LabTlsCaExistingTrust $der) -cne 'IDENTICAL_PREEXISTING_NOT_OWNED'){return $false}
    $cert=[Security.Cryptography.X509Certificates.X509Certificate2]::new($der);$public=$null
    try{
        $public=[Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPublicKey($cert)
        if(-not $public.VerifyData($signed,[Convert]::FromBase64String($document.qualification.signature),[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pkcs1)){return $false}
    }finally{if($public){$public.Dispose()};$cert.Dispose()}
    $builder=[Data.SqlClient.SqlConnectionStringBuilder]::new($entry.connectionString)
    $expectedSource=if($windows){"tcp:$($r.Host),$($r.Port)"}elseif($linux){'tcp:localhost,1433'}else{"tcp:127.0.0.1,$($r.Port)"}
    if(-not $builder.Encrypt -or $builder.TrustServerCertificate -or $builder.DataSource -cne $expectedSource -or $builder.Password -cne $entry.password){return $false}
    $null=Assert-LabTlsSqlCertificateBinding $r $StateRoot $Budget
    $again=Get-LabTlsOwnBinding $StateRoot $RunId $InstanceId
    if((Get-LabTlsCaByteDigest $again.Bytes) -cne (Get-LabTlsCaByteDigest $bound.Bytes)){throw 'TLS_EXPORT_BINDING_CHANGED'}
    if(-not $windows){Assert-LabTlsRebindCommitted $again $StateRoot}
    $verifiedAt=Get-LabTlsQualifiedExportUtcNow
    if($expiresAt -le $verifiedAt){return $false}
    return [pscustomobject][ordered]@{
        ContractVersion='SqlServerLab.QualifiedTestEnvironmentSnapshot/0.1'
        ExportSha256=Get-LabTlsCaByteDigest $bytes
        ExportBytes=[byte[]]$bytes.Clone()
        Contract=$document
        Qualification=$q
        VerifiedAtUtc=$verifiedAt.ToString('o')
    }
}

function Test-LabTlsQualifiedExport {
    param([string]$Path,[string]$StateRoot,[string]$RunId,[string]$InstanceId,[object]$Budget)
    $snapshot=Read-LabTlsQualifiedExportSnapshot -Path $Path -StateRoot $StateRoot -RunId $RunId -InstanceId $InstanceId -Budget $Budget -AllowLinuxController
    return $null -ne $snapshot -and $snapshot -isnot [bool]
}
