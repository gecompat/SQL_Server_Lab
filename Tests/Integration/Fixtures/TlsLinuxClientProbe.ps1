#Requires -Version 7.5
# Runs only in the explicitly owned Linux client namespace. Input and passwords
# use stdin; only classified, credential-free results are written to stdout.
[CmdletBinding()]
param([ValidateSet('Pair','Clr')][string]$Mode='Pair',[switch]$Execute)
$ErrorActionPreference='Stop'
$script:TlsLinuxOdbcFailureFacts=$null

function Test-TlsLinuxCertificateFailure {
    param([string[]]$Types,[string]$Message)
    $typed=($Types -ccontains 'System.Data.SqlClient.SqlException') -and
        ($Types -ccontains 'System.Security.Authentication.AuthenticationException')
    return $typed -and $Message -match '(?i)certificate|RemoteCertificateValidationCallback'
}

function Get-TlsLinuxClrFailureCode {
    param([string[]]$Types,[string]$Message)
    if($Types -ccontains 'System.PlatformNotSupportedException'){return 'PLATFORM_UNSUPPORTED'}
    if(@($Types|Where-Object{$_ -cin @('System.TypeLoadException','System.IO.FileNotFoundException','System.IO.FileLoadException')}).Count){return 'ASSEMBLY_UNAVAILABLE'}
    if($Types -ccontains 'System.Security.Authentication.AuthenticationException' -or
        $Message -match '(?i)certificate|RemoteCertificateValidationCallback'){return 'CERTIFICATE'}
    if($Message -match '(?i)login failed'){return 'LOGIN'}
    if($Types -ccontains 'System.TimeoutException' -or $Message -match '(?i)timed out|timeout'){return 'TIMEOUT'}
    if($Types -ccontains 'System.Net.Sockets.SocketException'){return 'NETWORK'}
    if($Message -cmatch '\bTLS_LINUX_SQL_RESULT_INVALID\b'){return 'SQL_RESULT'}
    return 'UNCLASSIFIED'
}

function Get-TlsLinuxProbeFailureCode {
    param([string]$Message)
    $allowed=@('TLS_LINUX_CLR_PROBE_FAILED','TLS_LINUX_CLR_CHILD_FAILED','TLS_LINUX_CLR_RESULT_INVALID',
        'TLS_LINUX_ODBC_POSITIVE_FAILED','TLS_LINUX_ODBC_CERTIFICATE_REJECTION_MISSING','TLS_LINUX_DRIVER_CHANGED',
        'TLS_LINUX_SQLCMD_CHANGED','TLS_LINUX_PROBE_INPUT_INVALID','TLS_LINUX_TRUST_BYTES_CHANGED','TLS_LINUX_TRUST_PATH_INVALID',
        'TLS_LINUX_PARENT_CONTEXT_INVALID','TLS_LINUX_NON_LOOPBACK_RESOLUTION','TLS_LINUX_CHILD_BOUND_EXCEEDED',
        'TLS_LINUX_CHILD_OUTPUT_TOO_LARGE','TLS_LINUX_ODBC_AMBIGUOUS')
    foreach($suffix in @('EXIT_CERTIFICATE','EXIT_LOGIN','EXIT_LOGIN_TIMEOUT','EXIT_QUERY_TIMEOUT','EXIT_TIMEOUT','EXIT_NETWORK','EXIT_UNCLASSIFIED','STDERR','SQL_RESULT','DRIVER_NOT_OBSERVED','DRIVER_MAPS_UNREADABLE','DRIVER_PATTERN_MISSING')){$allowed+=('TLS_LINUX_ODBC_POSITIVE_'+$suffix)}
    foreach($code in @('PLATFORM_UNSUPPORTED','ASSEMBLY_UNAVAILABLE','CERTIFICATE','LOGIN','TIMEOUT','NETWORK','SQL_RESULT','UNCLASSIFIED')){
        foreach($stage in @('CONSTRUCT','OPEN','QUERY')){$allowed+=('TLS_LINUX_CLR_CLIENT_'+$code+'_'+$stage)}
    }
    if($Message -cin $allowed){return $Message}
    return 'TLS_LINUX_PROBE_UNCLASSIFIED'
}

function New-TlsLinuxClrConnection {
    param($InputRecord)
    $builder=[Data.SqlClient.SqlConnectionStringBuilder]::new()
    try{
        # PowerShell adapts this IDictionary: use actual connection keywords,
        # rather than property names such as DataSource/InitialCatalog.
        $builder['Data Source']='tcp:localhost,1433';$builder['Initial Catalog']='master';$builder['User ID']='sa'
        $builder['Encrypt']=$true;$builder['TrustServerCertificate']=[bool]$InputRecord.TrustServerCertificate
        $builder['Pooling']=$false;$builder['Connect Timeout']=5;$builder['ConnectRetryCount']=0;$builder['Password']=$InputRecord.Password
        return [Data.SqlClient.SqlConnection]::new($builder.ConnectionString)
    }finally{$builder.Clear()}
}

function Invoke-TlsLinuxClrProbe {
    param($InputRecord)
    $connection=$null;$opened=$false;$queries=0;$stage='CONSTRUCT'
    try {
        $connection=New-TlsLinuxClrConnection $InputRecord
        $stage='OPEN'
        $connection.Open();$opened=$true
        if(-not $InputRecord.Positive){throw 'TLS_LINUX_NEGATIVE_CONNECTION_OPENED'}
        $stage='QUERY'
        $command=$connection.CreateCommand();$command.CommandTimeout=10
        try {
            $command.CommandText="SELECT CONVERT(varchar(32),SERVERPROPERTY('ProductVersion')),encrypt_option FROM sys.dm_exec_connections WHERE session_id=@@SPID"
            $queries++;$reader=$command.ExecuteReader()
            try {
                if(-not $reader.Read() -or $reader.GetString(0) -cne $InputRecord.ExpectedBuild -or $reader.GetString(1) -cne 'TRUE' -or $reader.Read()){
                    throw 'TLS_LINUX_SQL_RESULT_INVALID'
                }
            }finally{$reader.Dispose()}
        }finally{$command.Dispose()}
        return @{Status='PASS';Opened=$true;Queries=$queries;Build=$InputRecord.ExpectedBuild;Encrypted=$true}
    }catch {
        $types=[Collections.Generic.List[string]]::new();$messages=[Collections.Generic.List[string]]::new();$exception=$_.Exception
        while($exception){$types.Add($exception.GetType().FullName);$messages.Add($exception.Message);$exception=$exception.InnerException}
        if(-not $InputRecord.Positive -and -not $opened -and $queries -eq 0 -and
            (Test-TlsLinuxCertificateFailure $types.ToArray() ($messages -join ' '))){
            return @{Status='CERTIFICATE_REJECTED';Opened=$false;Queries=0;TypedAuthenticationFailure=$true}
        }
        # Never emit exception text or connection data. These facts explain an
        # unexpected client failure and never qualify a negative TLS case.
        return @{Status='CLIENT_FAILED';FailureCode=(Get-TlsLinuxClrFailureCode $types.ToArray() ($messages -join ' '));Stage=$stage;Opened=$opened;Queries=$queries}
    }finally{if($connection){$connection.Dispose()}}
}

function Get-TlsLinuxOdbcPositiveFailureCode {
    param([int]$ExitCode,[string]$Stderr,[string]$Stdout,[string]$ExpectedBuild,[bool]$DriverObserved,
        [ValidateSet('NOT_OBSERVED','UNREADABLE','READABLE')][string]$Maps='NOT_OBSERVED')
    if($ExitCode -ne 0){
        $text=$Stdout+' '+$Stderr
        $category=if($text -match '(?i)certificate verify failed|certificate.*(not trusted|expired)|hostname mismatch|subject name.*(match|incorrect)|unable to get local issuer'){'CERTIFICATE'}
            elseif($text -match '(?i)login failed'){'LOGIN'}
            elseif($text -match '(?i)login timeout|login.*timed out'){'LOGIN_TIMEOUT'}
            elseif($text -match '(?i)query timeout|statement timeout|(?:query|statement).*timed out'){'QUERY_TIMEOUT'}
            elseif($text -match '(?i)timed out|timeout'){'TIMEOUT'}
            elseif($text -match '(?i)TCP Provider|network-related|connection.*(refused|reset)|server.*not found'){'NETWORK'}else{'UNCLASSIFIED'}
        return 'TLS_LINUX_ODBC_POSITIVE_EXIT_'+$category
    }
    if($Stderr){return 'TLS_LINUX_ODBC_POSITIVE_STDERR'}
    if($Stdout -cne ($ExpectedBuild+'|TRUE')){return 'TLS_LINUX_ODBC_POSITIVE_SQL_RESULT'}
    if(-not $DriverObserved){
        $category=switch($Maps){'READABLE'{'PATTERN_MISSING'};'UNREADABLE'{'MAPS_UNREADABLE'};default{'NOT_OBSERVED'}}
        return 'TLS_LINUX_ODBC_POSITIVE_DRIVER_'+$category
    }
    return $null
}

function Get-TlsLinuxLoopbackTcpDiagnostic {
    param([Net.IPAddress[]]$Addresses,[Net.Sockets.AddressFamily]$Family)
    if(-not $Addresses.Count -or @($Addresses|Where-Object{-not [Net.IPAddress]::IsLoopback($_)}).Count -or
        $Family -notin @([Net.Sockets.AddressFamily]::InterNetwork,[Net.Sockets.AddressFamily]::InterNetworkV6)){
        throw 'TLS_LINUX_NON_LOOPBACK_RESOLUTION'
    }
    $selected=@($Addresses|Where-Object{$_.AddressFamily -eq $Family})
    if(-not $selected.Count){return 'NOT_RESOLVED'}
    $client=[Net.Sockets.TcpClient]::new($Family);$cancel=[Threading.CancellationTokenSource]::new(1000)
    try{
        # Diagnostic only after an already failed ODBC positive probe. No SQL,
        # hostname substitution, TLS bypass or additional client retry occurs.
        $null=$client.ConnectAsync($selected[0],1433,$cancel.Token).AsTask().GetAwaiter().GetResult()
        return 'CONNECTED'
    }catch [OperationCanceledException]{return 'TIMEOUT'}
    catch [Net.Sockets.SocketException]{if($_.Exception.SocketErrorCode -eq [Net.Sockets.SocketError]::ConnectionRefused){return 'REFUSED'};return 'ERROR'}
    catch{return 'ERROR'}
    finally{$client.Dispose();$cancel.Dispose()}
}

function Get-TlsLinuxOdbcDiagnosticKinds {
    param([string]$Text)
    $patterns=[ordered]@{
        LOGIN_TIMEOUT='login timeout|login.*timed out'
        QUERY_TIMEOUT='query timeout|statement timeout|(?:query|statement).*timed out'
        CERTIFICATE='certificate verify failed|certificate.*(not trusted|expired)|hostname mismatch|subject name.*(match|incorrect)|unable to get local issuer'
        SSL_PROVIDER='SSL Provider'
        SSL_PROTOCOL='unsupported protocol|protocol version|wrong version number|version.*too low'
        SSL_CIPHER='no shared cipher|no ciphers available|dh key too small|legacy sigalg|ca md too weak'
        SSL_EOF='unexpected eof|EOF occurred|tlsv1 alert internal error'
        PRELOGIN='handshake|pre-login|prelogin'
        TCP_PROVIDER='TCP Provider'
        NETWORK_INSTANCE='network-related|instance-specific|server.*not found'
        NAME_RESOLUTION='name or service not known|temporary failure in name resolution|host.*not known'
        PASSWORD_PROMPT='(?m)^\s*Password\s*:'
        LOGIN_FAILED='login failed'
    }
    foreach($entry in $patterns.GetEnumerator()){if($Text -match ('(?i)'+$entry.Value)){$entry.Key}}
}

function Get-TlsLinuxTcpProviderErrorCode {
    param([string]$Text)
    $codes=@([regex]::Matches($Text,'(?i)TCP Provider:\s*Error code 0x([0-9a-f]{4,8})\b')|ForEach-Object{
        '0x'+[Convert]::ToUInt32($_.Groups[1].Value,16).ToString('X8')
    }|Select-Object -Unique)
    if($codes.Count -eq 1){return $codes[0]}
    if($codes.Count -gt 1){return 'AMBIGUOUS'}
    return 'NOT_OBSERVED'
}

function Invoke-TlsLinuxProbePair {
    param($InputRecord)
    if(-not $IsLinux -or $env:SSL_CERT_FILE -or $env:SSL_CERT_DIR){throw 'TLS_LINUX_PARENT_CONTEXT_INVALID'}
    if($InputRecord.ExpectedBuild -cnotin @('15.0.4430.1','16.0.4295.3','17.0.5005.3') -or
        $InputRecord.Positive -isnot [bool] -or $InputRecord.Trusted -isnot [bool] -or $InputRecord.TrustServerCertificate -isnot [bool] -or
        ($InputRecord.TrustServerCertificate -and -not $InputRecord.Positive)){throw 'TLS_LINUX_PROBE_INPUT_INVALID'}
    $addresses=@([Net.Dns]::GetHostAddresses('localhost'))
    if(-not $addresses.Count -or @($addresses|Where-Object{-not [Net.IPAddress]::IsLoopback($_)}).Count){throw 'TLS_LINUX_NON_LOOPBACK_RESOLUTION'}
    if(-not [IO.File]::Exists('/opt/tls-client/ca.pem') -or @(Get-ChildItem -LiteralPath '/opt/tls-client/empty' -Force).Count){throw 'TLS_LINUX_TRUST_PATH_INVALID'}
    $ca=[Security.Cryptography.X509Certificates.X509Certificate2]::CreateFromPem([IO.File]::ReadAllText('/opt/tls-client/ca.pem'))
    # The host also binds the installed public bytes; do not derive trust from
    # a certificate subject or a caller-supplied display name.
    $ca.Dispose()
    if((Get-FileHash -LiteralPath '/opt/tls-client/ca.pem').Hash -cne $InputRecord.CaPemSha256){throw 'TLS_LINUX_TRUST_BYTES_CHANGED'}
    $sqlcmd='/opt/mssql-tools18/bin/sqlcmd';$sqlcmdHash=(Get-FileHash -LiteralPath $sqlcmd).Hash
    $results=[Collections.Generic.List[object]]::new()
    foreach($stack in @('System.Data.SqlClient','ODBC-sqlcmd')){
        $start=[Diagnostics.ProcessStartInfo]::new();$start.UseShellExecute=$false;$start.CreateNoWindow=$true
        $start.RedirectStandardInput=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
        foreach($key in @($start.Environment.Keys)){
            if($key.StartsWith('SQLCMD',[StringComparison]::OrdinalIgnoreCase) -or $key -cin @('SSL_CERT_FILE','SSL_CERT_DIR')){$null=$start.Environment.Remove($key)}
        }
        $start.Environment['HOME']='/tmp';$start.Environment['POWERSHELL_TELEMETRY_OPTOUT']='1';$start.Environment['DOTNET_CLI_TELEMETRY_OPTOUT']='1'
        if($InputRecord.Trusted){$start.Environment['SSL_CERT_FILE']='/opt/tls-client/ca.pem';$start.Environment['SSL_CERT_DIR']='/opt/tls-client/empty'}
        if($stack -ceq 'System.Data.SqlClient'){
            $start.FileName='/opt/tls-client/pwsh/pwsh'
            foreach($arg in @('-NoLogo','-NoProfile','-File','/opt/tls-client/probe.ps1','-Mode','Clr','-Execute')){$start.ArgumentList.Add($arg)}
        }else{
            $start.FileName=$sqlcmd;$start.Environment['SQLCMDPASSWORD']=$InputRecord.Password
            $query=if($InputRecord.Positive){"SET NOCOUNT ON; WAITFOR DELAY '00:00:03'; SELECT CONVERT(varchar(32),SERVERPROPERTY('ProductVersion'))+'|'+encrypt_option FROM sys.dm_exec_connections WHERE session_id=@@SPID"}else{'-- TLS open only; no SQL work'}
            foreach($arg in @('-S','tcp:localhost,1433','-U','sa','-N','-b','-X1','-x','-l','5','-t','10','-h','-1','-W','-Q',$query)){$start.ArgumentList.Add($arg)}
            if($InputRecord.TrustServerCertificate){$start.ArgumentList.Add('-C')}
        }
        $process=[Diagnostics.Process]::new();$process.StartInfo=$start;$started=$false;$driver=$null;$mapsObservation='NOT_OBSERVED'
        $stdout=[IO.MemoryStream]::new();$stderr=[IO.MemoryStream]::new()
        $childClock=[Diagnostics.Stopwatch]::StartNew()
        try{
            $passwordEnvironmentPresent=$start.Environment.ContainsKey('SQLCMDPASSWORD') -and -not [string]::IsNullOrEmpty($start.Environment['SQLCMDPASSWORD'])
            $started=$process.Start();$null=$start.Environment.Remove('SQLCMDPASSWORD')
            $outTask=$process.StandardOutput.BaseStream.CopyToAsync($stdout);$errTask=$process.StandardError.BaseStream.CopyToAsync($stderr)
            if($stack -ceq 'System.Data.SqlClient'){$process.StandardInput.WriteLine(($InputRecord|ConvertTo-Json -Compress))};$process.StandardInput.Close()
            $deadline=[DateTimeOffset]::UtcNow.AddSeconds(25)
            while(-not $process.WaitForExit(25)){
                if([DateTimeOffset]::UtcNow -ge $deadline -or $stdout.Length -gt 32768 -or $stderr.Length -gt 32768){throw 'TLS_LINUX_CHILD_BOUND_EXCEEDED'}
                if($stack -ceq 'ODBC-sqlcmd' -and $InputRecord.Positive -and -not $driver){
                    $mapsPath='/proc/'+$process.Id+'/maps'
                    if([IO.File]::Exists($mapsPath)){
                        try{$mapLines=@(Get-Content -LiteralPath $mapsPath -ErrorAction Stop);$mapsObservation='READABLE'}catch{if($mapsObservation -cne 'READABLE'){$mapsObservation='UNREADABLE'};$mapLines=@()}
                        $paths=@($mapLines|ForEach-Object{if($_ -match '\s(/opt/microsoft/msodbcsql18/lib64/libmsodbcsql-18\.[0-9.]+\.so\.[0-9.]+)$'){$Matches[1]}}|Select-Object -Unique)
                        if($paths.Count -gt 1){throw 'TLS_LINUX_ODBC_AMBIGUOUS'}
                        if($paths.Count -eq 1){$driver=@{Path=$paths[0];Sha256=(Get-FileHash -LiteralPath $paths[0]).Hash;Observation='ACTUAL_CHILD_PROC_MAPS'}}
                    }
                }
            }
            $null=$outTask.GetAwaiter().GetResult();$null=$errTask.GetAwaiter().GetResult()
            if($stdout.Length -gt 32768 -or $stderr.Length -gt 32768){throw 'TLS_LINUX_CHILD_OUTPUT_TOO_LARGE'}
            $output=[Text.Encoding]::UTF8.GetString($stdout.ToArray()).Trim();$errorText=[Text.Encoding]::UTF8.GetString($stderr.ToArray()).Trim()
            if($stack -ceq 'System.Data.SqlClient'){
                if($process.ExitCode -ne 0 -or $errorText){throw 'TLS_LINUX_CLR_CHILD_FAILED'}
                $result=$output|ConvertFrom-Json
                if($result.Status -ceq 'CLIENT_FAILED'){
                    if($result.FailureCode -cnotin @('PLATFORM_UNSUPPORTED','ASSEMBLY_UNAVAILABLE','CERTIFICATE','LOGIN','TIMEOUT','NETWORK','SQL_RESULT','UNCLASSIFIED') -or
                        $result.Stage -cnotin @('CONSTRUCT','OPEN','QUERY')){throw 'TLS_LINUX_CLR_RESULT_INVALID'}
                    throw ('TLS_LINUX_CLR_CLIENT_'+$result.FailureCode+'_'+$result.Stage)
                }
                if($result.Status -cne $(if($InputRecord.Positive){'PASS'}else{'CERTIFICATE_REJECTED'})){throw 'TLS_LINUX_CLR_RESULT_INVALID'}
            }elseif($InputRecord.Positive){
                $failure=Get-TlsLinuxOdbcPositiveFailureCode -ExitCode $process.ExitCode -Stderr $errorText -Stdout $output -ExpectedBuild $InputRecord.ExpectedBuild -DriverObserved ([bool]$driver) -Maps $mapsObservation
                if($failure){
                    $childClock.Stop()
                    $diagnosticText=$output+[Environment]::NewLine+$errorText
                    $script:TlsLinuxOdbcFailureFacts=@{OdbcExitCode=$process.ExitCode;ChildElapsedMilliseconds=$childClock.ElapsedMilliseconds;
                        DriverMaps=$mapsObservation;DriverObserved=[bool]$driver;ActualOdbcAddressFamily='NOT_OBSERVED';
                        LoopbackIpv4=(Get-TlsLinuxLoopbackTcpDiagnostic $addresses ([Net.Sockets.AddressFamily]::InterNetwork));
                        LoopbackIpv6=(Get-TlsLinuxLoopbackTcpDiagnostic $addresses ([Net.Sockets.AddressFamily]::InterNetworkV6));
                        SqlcmdSha256=$sqlcmdHash;DriverSha256=$(if($driver){$driver.Sha256}else{'NOT_OBSERVED'});
                        PasswordEnvironmentPresentAtStart=$passwordEnvironmentPresent;
                        DiagnosticKinds=@(Get-TlsLinuxOdbcDiagnosticKinds $diagnosticText);
                        TcpProviderErrorCode=(Get-TlsLinuxTcpProviderErrorCode $diagnosticText)}
                    throw $failure
                }
                if((Get-FileHash -LiteralPath $driver.Path).Hash -cne $driver.Sha256){throw 'TLS_LINUX_DRIVER_CHANGED'}
                $result=@{Status='PASS';Build=$InputRecord.ExpectedBuild;Encrypted=$true;Driver=$driver}
            }else{
                if($process.ExitCode -eq 0 -or ($output+' '+$errorText) -notmatch '(?i)certificate verify failed|certificate.*(not trusted|expired)|hostname mismatch|subject name.*(match|incorrect)|unable to get local issuer'){
                    throw 'TLS_LINUX_ODBC_CERTIFICATE_REJECTION_MISSING'
                }
                $result=@{Status='CERTIFICATE_REJECTED';SqlWork='NOT_DISPATCHED';CertificateDiagnostic=$true}
            }
            $results.Add(@{Stack=$stack;Result=$result;Encrypt=$true;TrustServerCertificate=$InputRecord.TrustServerCertificate;Trusted=$InputRecord.Trusted;FreshProcess=$true})
        }finally{
            $null=$start.Environment.Remove('SQLCMDPASSWORD')
            if($started -and -not $process.HasExited){$process.Kill($true);$process.WaitForExit()}
            $process.Dispose();$stdout.Dispose();$stderr.Dispose()
        }
    }
    if((Get-FileHash -LiteralPath $sqlcmd).Hash -cne $sqlcmdHash){throw 'TLS_LINUX_SQLCMD_CHANGED'}
    return @{Status='PASS';Results=$results.ToArray();SqlcmdSha256=$sqlcmdHash;PowerShell=$PSVersionTable.PSVersion.ToString();DotNet=[Runtime.InteropServices.RuntimeInformation]::FrameworkDescription;AssemblyMvid=[Data.SqlClient.SqlConnection].Assembly.ManifestModule.ModuleVersionId.ToString();AssemblyDiskSha256=(Get-FileHash -LiteralPath ([Data.SqlClient.SqlConnection].Assembly.Location)).Hash;UtcNow=[DateTimeOffset]::UtcNow.ToString('o')}
}

if($Execute){
    try{
        $inputRecord=[Console]::In.ReadLine()|ConvertFrom-Json
        if($Mode -ceq 'Clr'){$result=Invoke-TlsLinuxClrProbe $inputRecord}else{$result=Invoke-TlsLinuxProbePair $inputRecord}
        $result|ConvertTo-Json -Depth 12 -Compress
    }catch{
        # Error formatting, terminal width and ANSI rendering are not a protocol.
        $failure=@{Schema='SqlServerLab.TlsLinuxProbeFailure/1.0';Status='FAIL';Code=(Get-TlsLinuxProbeFailureCode $_.Exception.Message)}
        if($script:TlsLinuxOdbcFailureFacts){$failure.Schema='SqlServerLab.TlsLinuxProbeFailure/2.1';$failure.Facts=$script:TlsLinuxOdbcFailureFacts}
        $failure|ConvertTo-Json -Depth 4 -Compress
        exit 1
    }
}
