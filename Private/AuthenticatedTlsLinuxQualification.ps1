function Get-LabTlsLinuxExportUsageText {
    return (@(
        '# Qualifizierter isolierter Linux-TLS-Export'
        ''
        'SqlServerLab.TestEnvironment/2.0. Encrypt=True;TrustServerCertificate=False.'
        'Der Windowscontroller bindet einen eigenen Linuxclient mit isoliertem CA-Truststore, beiden echten Clientstacks und eigenem SQL-Netznamespace.'
        'localhost:1433 gilt ausschliesslich in diesem eigenen Gastnamespace, nicht als Hostendpoint.'
        'Auf dem Windowscontroller Invoke-SqlServerLabLinuxPreflight mit denselben privat erfassten ExportBytes, exakter RunId/InstanceId/StateRoot und ausdruecklich vertrauenswuerdigem ToolbeltRoot verwenden.'
        'Der Linuxreader benoetigt die dadurch privat gebootstrappte Live-Session; Export oder Schema erzeugen keine Sitzung oder Codeautoritaet.'
        'Vor jedem Login bleiben Signatur, Frist und aktuelle Eltern-/Kind-/Runtime-/Trustbindung verbindlich; kein Trust- oder Providerfallback.'
        'JSON und Readerergebnis enthalten Klartextkennwoerter. Nicht ausgeben, weitergeben oder versionieren.'
        ''
    ) -join [char]10)
}

function Get-LabTlsLinuxQualificationProgram {
    return @'
$ErrorActionPreference='Stop'
$inputObject=[Console]::In.ReadToEnd()|ConvertFrom-Json
$expected=$inputObject.SqlBuild
$builder=[Data.SqlClient.SqlConnectionStringBuilder]::new()
$builder.DataSource='tcp:localhost,1433';$builder.InitialCatalog='master';$builder.UserID='sa';$builder.Password=$inputObject.Password
$builder.Encrypt=$true;$builder.TrustServerCertificate=$false;$builder.Pooling=$false;$builder.ConnectTimeout=10;$builder.ConnectRetryCount=0
$connection=[Data.SqlClient.SqlConnection]::new($builder.ConnectionString);$builder.Clear()
try{
    $connection.Open()
    $command=$connection.CreateCommand();$command.CommandTimeout=10
    $command.CommandText="SET NOCOUNT ON; SELECT CONVERT(varchar(32),SERVERPROPERTY('ProductVersion')),encrypt_option FROM sys.dm_exec_connections WHERE session_id=@@SPID"
    try{
        $reader=$command.ExecuteReader()
        try{if(-not$reader.Read()-or$reader.GetString(0)-cne$expected-or$reader.GetString(1)-cne'TRUE'-or$reader.Read()){throw 'SQLCLIENT_RESULT'}}finally{$reader.Dispose()}
    }finally{$command.Dispose()}
}finally{$connection.Dispose()}
$info=[Diagnostics.ProcessStartInfo]::new('/opt/mssql-tools18/bin/sqlcmd')
$info.UseShellExecute=$false;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
foreach($key in @($info.Environment.Keys)){if($key.StartsWith('SQLCMD',[StringComparison]::OrdinalIgnoreCase)){$null=$info.Environment.Remove($key)}}
$info.Environment['SQLCMDPASSWORD']=$inputObject.Password
foreach($argument in @('-S','tcp:localhost,1433','-U','sa','-N','-b','-l','10','-h','-1','-W','-s','|','-Q',"SET NOCOUNT ON; WAITFOR DELAY '00:00:03'; SELECT CONVERT(varchar(32),SERVERPROPERTY('ProductVersion')),encrypt_option FROM sys.dm_exec_connections WHERE session_id=@@SPID;")){$info.ArgumentList.Add($argument)}
$inputObject.Password=$null
$process=[Diagnostics.Process]::new();$process.StartInfo=$info;$loaded=$null;$started=$false
try{
    $started=$process.Start();$null=$info.Environment.Remove('SQLCMDPASSWORD')
    $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync();$clock=[Diagnostics.Stopwatch]::StartNew()
    while(-not$process.WaitForExit(50)){
        if($clock.Elapsed.TotalSeconds-ge25){throw 'SQLCMD_TIMEOUT'}
        if(-not$loaded){
            $maps=Get-Content -LiteralPath ('/proc/'+$process.Id+'/maps') -ErrorAction Stop
            $paths=@($maps|ForEach-Object{if($_-match'(/opt/microsoft/msodbcsql18/lib64/libmsodbcsql-18[^\s]+)$'){$Matches[1]}}|Sort-Object -Unique)
            if($paths.Count-eq1){$loaded=$paths[0]}elseif($paths.Count-gt1){throw 'ODBC_AMBIGUOUS'}
        }
    }
    if($process.ExitCode-ne0-or$stdout.GetAwaiter().GetResult().Trim()-cne($expected+'|TRUE')-or$stderr.GetAwaiter().GetResult().Trim()-or-not$loaded){throw 'SQLCMD_RESULT'}
    @{SqlClient='PASS';Odbc='PASS';SqlBuild=$expected;Encrypt=$true;TrustServerCertificate=$false;LoadedOdbcPath=$loaded;LoadedOdbcSha256=(Get-FileHash -LiteralPath $loaded).Hash.ToLowerInvariant();LoadedOdbcBytes=[long](Get-Item -LiteralPath $loaded).Length}|ConvertTo-Json -Compress
}finally{
    $null=$info.Environment.Remove('SQLCMDPASSWORD')
    if($started-and-not$process.HasExited){$process.Kill($true);if(-not$process.WaitForExit(5000)){throw 'GUEST_CHILD_TERMINATION_UNCONFIRMED'}}
    $process.Dispose()
}
'@
}

function New-LabTlsLinuxQualificationDocument {
    param([object]$Bound,[object]$Client,[string]$QualifiedAt,[string]$ExpiresAt)
    $r=$Bound.Record;$a=$Bound.Authority;$c=$Client.Record;$profile=Get-LabTlsBindingSqlProfile $r
    return [pscustomobject][ordered]@{
        ContractVersion='SqlServerLab.TlsQualification/0.2';Status='QUALIFIED';QualifiedAt=$QualifiedAt;ExpiresAt=$ExpiresAt
        Encrypt=$true;TrustServerCertificate=$false;Provider=$r.Provider;SqlVersion=$profile.SqlVersion;Patch=$profile.Patch;SqlBuild=$profile.SqlBuild
        RunId=$r.RunId;InstanceId=$r.InstanceId;ScopeId=$r.ScopeId;ContainerId=$r.ContainerId;ImageId=$r.ImageId;StartedAt=$r.StartedAt
        Endpoint=[pscustomobject]@{Host='localhost';Port=1433;IdentityKind='DNS';Identity='localhost';Namespace=$c.Client.NetNamespace}
        AuthorityRef=$a.Authority.Ref;AuthorityGeneration=$a.Authority.Generation
        ParentControllerClientRef=$a.Client.Ref;ParentControllerClientGeneration=$a.Client.Generation
        ClientPlatform='linux';ClientRef=$c.ClientRef;ClientGeneration=$c.Generation;ClientContextDigest=$Client.Sha256
        ClientContainerId=$c.Client.ContainerId;ClientImageId=$c.Client.ImageId;ClientStartedAt=$c.Client.StartedAt
        TrustScopeRef=$a.Authority.TrustScopeRef;Store='ISOLATED_CLIENT_CA_STORE';TrustFileSha256=$c.Trust.FileSha256
        ActorDigest=$a.ActorDigest;RootDigest=$a.RootDigest;RegistrySha256=$a.RegistrySha256
        CaSha256=$a.Authority.CertificateSha256;LeafSha256=$r.CertificateSha256;LeafNotAfterUtc=$r.NotAfterUtc
        SqlClientSha256=$c.Binaries.SqlClient.Sha256;SqlcmdSha256=$c.Binaries.Sqlcmd.Sha256
        LoadedOdbcSha256=$c.Binaries.OdbcDriver.Sha256;LoadedOdbcBytes=$c.Binaries.OdbcDriver.Bytes
        Evidence='FRESH_NATIVE_SQLCLIENT_AND_ODBC_SQLCMD';WireCertificateFingerprint='NOT_OBSERVED'
    }
}

function Test-LabTlsLinuxEnvironment {
    param([object]$Bound,[object]$Budget)
    $r=$Bound.Record;$profile=Get-LabTlsBindingSqlProfile $r
    $client=Get-LabTlsLinuxClientBinding $Bound $Budget
    $password=Get-LabSecret -Path (Join-Path (Join-Path $Bound.StateRoot 'runs') $r.RunId) -Name sa-password
    if(-not$password){throw 'TLS_QUALIFICATION_SECRET_UNAVAILABLE'}
    $pointer=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($password);$text=$null
    try{
        $text=(@{Password=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer);SqlBuild=$profile.SqlBuild}|ConvertTo-Json -Compress)
        $output=Invoke-LabTlsLinuxObservedProgram $Bound $Budget $client.Record.Client.ContainerId (Get-LabTlsLinuxQualificationProgram) $text
    }finally{[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer);$text=$null}
    $result=Read-LabTlsBoundJson ([Text.Encoding]::UTF8.GetBytes($output)) @('SqlClient','Odbc','SqlBuild','Encrypt','TrustServerCertificate','LoadedOdbcPath','LoadedOdbcSha256','LoadedOdbcBytes')
    $expected=[pscustomobject]@{SqlClient='PASS';Odbc='PASS';SqlBuild=$profile.SqlBuild;Encrypt=$true;TrustServerCertificate=$false
        LoadedOdbcPath=$client.Record.Binaries.OdbcDriver.Path;LoadedOdbcSha256=$client.Record.Binaries.OdbcDriver.Sha256;LoadedOdbcBytes=$client.Record.Binaries.OdbcDriver.Bytes}
    Assert-LabTlsLinuxObservedFields $expected $result
    $again=Get-LabTlsOwnBinding $Bound.StateRoot $r.RunId $r.InstanceId
    Assert-LabTlsRebindCommitted $again $Bound.StateRoot
    $after=Get-LabTlsLinuxClientBinding $again $Budget
    if((Get-LabTlsCaByteDigest $again.Bytes)-cne(Get-LabTlsCaByteDigest $Bound.Bytes)-or$after.Sha256-cne$client.Sha256){throw 'TLS_LINUX_QUALIFICATION_BINDING_CHANGED'}
    $now=[DateTimeOffset]::UtcNow;$end=$now.AddMinutes(15);$leafEnd=[DateTimeOffset]::ParseExact($r.NotAfterUtc,'o',[Globalization.CultureInfo]::InvariantCulture)
    if($leafEnd-lt$end){$end=$leafEnd}
    return New-LabTlsLinuxQualificationDocument $Bound $client $now.ToString('o') $end.ToString('o')
}

function Assert-LabTlsLinuxExportQualification {
    param([object]$Bound,[object]$Budget,[object]$Qualification,[object]$Entry)
    $client=Get-LabTlsLinuxClientBinding $Bound $Budget
    if($Qualification.QualifiedAt-isnot[string]-or$Qualification.ExpiresAt-isnot[string]){throw 'TLS_LINUX_EXPORT_BINDING_INVALID'}
    $expected=New-LabTlsLinuxQualificationDocument $Bound $client $Qualification.QualifiedAt $Qualification.ExpiresAt
    Assert-LabTlsLinuxObservedFields $expected $Qualification
    $r=$Bound.Record;$profile=Get-LabTlsBindingSqlProfile $r
    $entryExpected=[pscustomobject][ordered]@{key=$profile.ExportKey;status='READY';runtimeStatus='READY';platform='linux';provider=$r.Provider;sqlVersion=$profile.SqlVersion;patch=$profile.Patch;resolvedVersion=$profile.SqlBuild
        runId=$r.RunId;instanceId=$r.InstanceId;host='localhost';port=1433;database='master';username='sa';password=$Entry.password;encrypt=$true;trustServerCertificate=$false;autoStart='off';connectionString=$Entry.connectionString}
    if($Entry.password-isnot[string]-or-not$Entry.password-or$Entry.connectionString-isnot[string]){throw 'TLS_LINUX_EXPORT_BINDING_INVALID'}
    Assert-LabTlsLinuxObservedFields $entryExpected $Entry
}
