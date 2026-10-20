#Requires -Version 7.2
function Get-TlsHyperVSourceInventory {
    param([string]$Root)
    # Hidden NoProfile workers can inherit an OEM console code page. Read git's
    # NUL-separated UTF-8 stream explicitly, including non-ASCII file names.
    $git=(Get-Command git -CommandType Application -ErrorAction Stop|Select-Object -First 1).Source
    $start=[Diagnostics.ProcessStartInfo]::new($git);$start.UseShellExecute=$false;$start.CreateNoWindow=$true
    $start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true;$start.StandardOutputEncoding=[Text.UTF8Encoding]::new($false,$true)
    foreach($arg in @('-C',$Root,'ls-files','-z','--cached','--others','--exclude-standard')){$start.ArgumentList.Add($arg)}
    $process=[Diagnostics.Process]::Start($start)
    try{
        $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync();$process.WaitForExit()
        $text=$stdout.GetAwaiter().GetResult();$null=$stderr.GetAwaiter().GetResult()
        if($process.ExitCode -ne 0){throw 'TLS_HV_SOURCE_INVENTORY_FAILED'}
        $paths=@($text.Split([char]0,[StringSplitOptions]::RemoveEmptyEntries)|Sort-Object -Unique)
        if(-not $paths.Count){throw 'TLS_HV_SOURCE_INVENTORY_FAILED'}
        return $paths
    }finally{$process.Dispose()}
}

function Get-TlsHyperVSourceSnapshot {
    param([string]$Root,$Module)
    $paths=@(Get-TlsHyperVSourceInventory $Root)
    $rows=@(foreach($path in $paths){[ordered]@{RelativePath=$path;Sha256=(Get-FileHash -LiteralPath (Join-Path $Root $path)).Hash}})
    $digest=& $Module {param($items)$atoms=@('SqlServerLab.TlsHyperVSource/0.1');foreach($item in $items){$atoms+=@($item.RelativePath,$item.Sha256.ToLowerInvariant())};Get-LabTlsPayloadDigest $atoms} $rows
    [pscustomobject]@{Sources=$rows;SourceDigest=$digest}
}

function Invoke-TlsHyperVSupervisedProcess {
    param($Child,[datetimeoffset]$DeadlineUtc,[string]$OperationId,[string]$SourceDigest,[scriptblock]$WriteEvidence,[scriptblock]$ReadResult)
    $started=$false
    try{
        if(-not $Child.Start()){throw 'TLS_HV_WORKER_START_FAILED'}
        $started=$true
        $stdout=$Child.StandardOutput.ReadToEndAsync();$stderr=$Child.StandardError.ReadToEndAsync()
        & $WriteEvidence 'worker-launch.private.json' @{Pid=$Child.Id;StartTicks=$Child.StartTime.ToUniversalTime().Ticks;SourceDigest=$SourceDigest}
        while(-not $Child.WaitForExit(1000)){if([datetimeoffset]::UtcNow -ge $DeadlineUtc){throw 'TLS_HV_WORKER_END_UNKNOWN'}}
        $null=$stdout.GetAwaiter().GetResult();$null=$stderr.GetAwaiter().GetResult()
        $observed=& $ReadResult
        if($Child.ExitCode -ne 0 -or $observed.ContractVersion -cne 'SqlServerLab.TlsHyperVResult/0.1' -or
            $observed.OperationId -cne $OperationId -or $observed.SourceDigest -cne $SourceDigest -or $observed.WorkerPid -ne $Child.Id -or
            $observed.Status -cne 'PASS' -or $observed.Phase -cne 'COMPLETED' -or $observed.NativeEndKnown -isnot [bool] -or -not $observed.NativeEndKnown -or
            $observed.Cases.Count -ne 9 -or @($observed.Cases|ForEach-Object Results).Count -ne 18){throw 'TLS_HV_WORKER_RESULT_NOT_PROVEN'}
        & $WriteEvidence 'supervisor-result.private.json' @{Status='PASS';OperationId=$OperationId;WorkerExited=$true;WorkerExitCode=$Child.ExitCode;WorkerPid=$Child.Id;SourceDigest=$SourceDigest}
    }catch{
        if($started){
            try{& $WriteEvidence 'cancel.private.json' @{Reason='SUPERVISOR_UNPROVEN_RESULT';OperationId=$OperationId}}catch{Write-Verbose 'Cancellation persistence failed; never terminate the native worker.'}
            try{& $WriteEvidence 'supervisor-result.private.json' @{Status='RECOVERY_REQUIRED';OperationId=$OperationId;WorkerEndUnknown=$true;WorkerPid=$Child.Id;NoKillStopOrRemoval=$true}}catch{Write-Verbose 'Supervisor recovery evidence could not be persisted.'}
        }
        throw
    }finally{$Child.Dispose()}
}

function New-TlsHyperVUntrustedLeaf {
    param([byte[]]$Csr,[string]$Address,[string]$MachineName,$Module)
    & $Module {param($bytes,$ip,$name)$null=Read-LabTlsServerLeafCsr $bytes ([pscustomobject]@{Kind='IP';Value=$ip}) -WindowsMachineName $name} $Csr $Address $MachineName
    $key=[Security.Cryptography.RSA]::Create(3072);$ca=$null;$leaf=$null
    try{
        $begin=[DateTimeOffset]::UtcNow;$end=$begin.AddHours(1)
        $root=[Security.Cryptography.X509Certificates.CertificateRequest]::new('CN=SqlServerLab HyperV Acceptance Untrusted CA',$key,[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pkcs1)
        $root.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new($true,$true,0,$true))
        $root.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509KeyUsageExtension]::new([Security.Cryptography.X509Certificates.X509KeyUsageFlags]::KeyCertSign,$true))
        $ca=$root.CreateSelfSigned($begin,$end.AddHours(1))
        $request=[Security.Cryptography.X509Certificates.CertificateRequest]::LoadSigningRequest($Csr,[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.X509Certificates.CertificateRequestLoadOptions]::Default,[Security.Cryptography.RSASignaturePadding]::Pkcs1)
        $request.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new($false,$false,0,$true))
        $request.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509KeyUsageExtension]::new([Security.Cryptography.X509Certificates.X509KeyUsageFlags]'DigitalSignature,KeyEncipherment',$true))
        $oids=[Security.Cryptography.OidCollection]::new();$null=$oids.Add([Security.Cryptography.Oid]::new('1.3.6.1.5.5.7.3.1'))
        $request.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]::new($oids,$false))
        $san=[Security.Cryptography.X509Certificates.SubjectAlternativeNameBuilder]::new();$san.AddIpAddress([Net.IPAddress]::Parse($Address));$request.CertificateExtensions.Add($san.Build($false))
        $serial=[byte[]]::new(16);[Security.Cryptography.RandomNumberGenerator]::Fill($serial);$serial[0]=1
        $leaf=$request.Create($ca,$begin,$end,$serial)
        return ,$leaf.Export([Security.Cryptography.X509Certificates.X509ContentType]::Cert)
    }finally{if($leaf){$leaf.Dispose()};if($ca){$ca.Dispose()};$key.Dispose()}
}

function Get-TlsHyperVFailureCategory {
    param([string]$Message)
    if($Message -match '(?i)login failed|login rejected|Anmeldung.*fehl|password.*expired|Kennwort.*abgelaufen'){return 'OTHER'}
    if($Message -notmatch '(?i)SSL|TLS|certificate|Zertifikat'){return 'OTHER'}
    if($Message -match '(?i)certificate chain.*(?:not trusted|untrusted)|Zertifikat(?:kette)?.*nicht vertrauens|80090325|800B0109'){return 'UNTRUSTED'}
    if($Message -match '(?i)target principal name is incorrect|Zielprinzipalname.*falsch|certificate.*name.*(?:mismatch|does not match)|800B010F|80090322'){return 'WRONG_SAN'}
    if($Message -match '(?i)certificate.*(?:expired|not time valid)|Zertifikat.*(?:abgelaufen|Gültigkeits)|800B0101|80090328'){return 'EXPIRED'}
    return 'OTHER'
}

function Get-TlsHyperVSqlClientProbeScript {
    return {
    $ErrorActionPreference='Stop'
    $buffer=[char[]]::new(16385);$length=0
    do{$read=[Console]::In.Read($buffer,$length,$buffer.Length-$length);$length+=$read;if($length -gt 16384){throw 'TLS_HV_SQLCLIENT_INPUT_TOO_LARGE'}}while($read -gt 0)
    $inputRecord=[string]::new($buffer,0,$length)|ConvertFrom-Json
    [Array]::Clear($buffer,0,$buffer.Length)
    $assembly=[Data.SqlClient.SqlConnection].Assembly
    if((Get-FileHash -LiteralPath $assembly.Location).Hash -ine $inputRecord.AssemblySha256 -or
        $assembly.ManifestModule.ModuleVersionId.ToString('D') -ine $inputRecord.AssemblyMvid){throw 'TLS_HV_SQLCLIENT_IMAGE_CHANGED'}
    $Address=$inputRecord.Address;$TrustServerCertificate=$inputRecord.TrustServerCertificate
    if([Net.IPAddress]::Parse($Address).ToString() -cne $Address -or $TrustServerCertificate -isnot [bool]){throw 'TLS_HV_CLIENT_ADDRESS_INVALID'}
    $builder=[Data.SqlClient.SqlConnectionStringBuilder]::new()
    $builder['Data Source']='tcp:'+$Address+',1433';$builder['Initial Catalog']='master';$builder['User ID']='sa'
    $builder['Encrypt']=$true;$builder['TrustServerCertificate']=$TrustServerCertificate;$builder['Pooling']=$false;$builder['Connect Timeout']=10;$builder['ConnectRetryCount']=0
    $builder['Password']=$inputRecord.Password;$inputRecord.Password=$null
    $connection=[Data.SqlClient.SqlConnection]::new($builder.get_ConnectionString());$builder.Clear();$category='PASS'
    try{
        $connection.Open();$command=$connection.CreateCommand();$command.CommandTimeout=10
        try{
            $command.CommandText="SELECT CONVERT(varchar(32),SERVERPROPERTY('ProductVersion')),encrypt_option FROM sys.dm_exec_connections WHERE session_id=@@SPID;"
            $reader=$command.ExecuteReader()
            try{if(-not $reader.Read() -or $reader.GetString(0) -cne '17.0.1000.7' -or $reader.GetString(1) -cne 'TRUE' -or $reader.Read()){throw 'TLS_HV_SQLCLIENT_RESULT_INVALID'}}finally{$reader.Dispose()}
        }finally{$command.Dispose()}
    }catch{$category=Get-TlsHyperVFailureCategory $_.Exception.ToString()}finally{$connection.Dispose()}
    if((Get-FileHash -LiteralPath $assembly.Location).Hash -ine $inputRecord.AssemblySha256){throw 'TLS_HV_SQLCLIENT_IMAGE_CHANGED'}
    [pscustomobject]@{Stack='System.Data.SqlClient';Encrypt=$true;TrustServerCertificate=$TrustServerCertificate;Observed=$category;FreshProcess=$true;AssemblySha256=$inputRecord.AssemblySha256;AssemblyMvid=$inputRecord.AssemblyMvid}|ConvertTo-Json -Compress
    }
}

function Invoke-TlsHyperVClientPair {
    param([string]$Address,[securestring]$Password,[bool]$TrustServerCertificate,[ValidateSet('PASS','UNTRUSTED','WRONG_SAN','EXPIRED')][string]$Expected,$Client,$Module)
    if([Net.IPAddress]::Parse($Address).ToString() -cne $Address){throw 'TLS_HV_CLIENT_ADDRESS_INVALID'}
    if($Password.Length -gt 1024){throw 'TLS_HV_CLIENT_PASSWORD_TOO_LONG'}
    $results=[Collections.Generic.List[object]]::new()
    # A fresh client process gives every certificate/expiry probe a new TLS context.
    $probe='function Get-TlsHyperVFailureCategory {'+(Get-Command Get-TlsHyperVFailureCategory).ScriptBlock.ToString()+"`n}"+(Get-TlsHyperVSqlClientProbeScript).ToString()
    $start=[Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME pwsh.exe));$start.UseShellExecute=$false;$start.CreateNoWindow=$true
    $start.RedirectStandardInput=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    foreach($arg in @('-NoLogo','-NoProfile','-EncodedCommand',[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($probe)))){$start.ArgumentList.Add($arg)}
    $process=[Diagnostics.Process]::new();$process.StartInfo=$start;$started=$false
    try{
        $started=$process.Start();$stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
        $pointer=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
        try{
            $payload=@{Address=$Address;TrustServerCertificate=$TrustServerCertificate;Password=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer);AssemblySha256=$Client.Details.SqlClientDiskSha256;AssemblyMvid=$Client.Details.SqlClientLoadedMvid}|ConvertTo-Json -Compress
            $null=$process.StandardInput.WriteAsync($payload).WaitAsync([timespan]::FromSeconds(10)).GetAwaiter().GetResult()
        }finally{$payload=$null;[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer);$process.StandardInput.Close()}
        if(-not $process.WaitForExit(35000)){throw 'TLS_HV_SQLCLIENT_TIMEOUT'}
        $output=$stdout.GetAwaiter().GetResult();$errorText=$stderr.GetAwaiter().GetResult()
        if($process.ExitCode -ne 0 -or $errorText.Trim().Length -ne 0 -or $output.Length -gt 16384){throw 'TLS_HV_SQLCLIENT_PROBE_FAILED'}
        $reply=$output|ConvertFrom-Json
        if($reply -isnot [pscustomobject] -or (@($reply.PSObject.Properties.Name|Sort-Object) -join ',') -cne 'AssemblyMvid,AssemblySha256,Encrypt,FreshProcess,Observed,Stack,TrustServerCertificate'){throw 'TLS_HV_SQLCLIENT_REPLY_INVALID'}
        if($reply.Stack -cne 'System.Data.SqlClient' -or $reply.FreshProcess -isnot [bool] -or -not $reply.FreshProcess -or $reply.Encrypt -isnot [bool] -or -not $reply.Encrypt -or
            $reply.TrustServerCertificate -isnot [bool] -or $reply.TrustServerCertificate -ne $TrustServerCertificate -or $reply.AssemblySha256 -cne $Client.Details.SqlClientDiskSha256 -or
            $reply.AssemblyMvid -cne $Client.Details.SqlClientLoadedMvid -or $reply.Observed -cne $Expected){throw 'TLS_HV_SQLCLIENT_EXPECTATION_FAILED'}
        $results.Add($reply)
    }finally{if($started -and -not $process.HasExited){$process.Kill($true);$process.WaitForExit()};$process.Dispose()}
    $exe=$Client.Details.SqlcmdPath
    $before=& $Module {param($p)Read-LabTlsContextBinaryMetadata $p 'sqlcmd.exe'} $exe
    if($before.DiskSha256 -cne $Client.Details.SqlcmdDiskSha256){throw 'TLS_HV_SQLCMD_CHANGED'}
    $start=[Diagnostics.ProcessStartInfo]::new($exe);$start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    foreach($key in @($start.Environment.Keys)){if($key.StartsWith('SQLCMD',[StringComparison]::OrdinalIgnoreCase)){$null=$start.Environment.Remove($key)}}
    foreach($arg in @('-S',('tcp:'+$Address+',1433'),'-U','sa','-N','-b','-l','10','-h','-1','-W','-s','|','-Q',"SET NOCOUNT ON; WAITFOR DELAY '00:00:03'; SELECT CONVERT(varchar(32),SERVERPROPERTY('ProductVersion')),encrypt_option FROM sys.dm_exec_connections WHERE session_id=@@SPID;")){$start.ArgumentList.Add($arg)}
    if($TrustServerCertificate){$start.ArgumentList.Add('-C')}
    $process=[Diagnostics.Process]::new();$process.StartInfo=$start;$driver=$null;$started=$false
    try{
        $pointer=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
        try{$start.Environment['SQLCMDPASSWORD']=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)}finally{[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)}
        $started=$process.Start();$null=$start.Environment.Remove('SQLCMDPASSWORD')
        $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync();$deadline=[datetime]::UtcNow.AddSeconds(25)
        while(-not $process.WaitForExit(50)){
            if([datetime]::UtcNow -ge $deadline){throw 'TLS_HV_SQLCMD_TIMEOUT'}
            if(-not $driver){
                $process.Refresh();$loaded=@($process.Modules|Where-Object {$_.ModuleName -match '^msodbcsql[0-9]+\.dll$'})
                if($loaded.Count -eq 1){$driver=& $Module {param($p,$n)Read-LabTlsContextBinaryMetadata $p $n} $loaded[0].FileName $loaded[0].ModuleName}
            }
        }
        $output=$stdout.GetAwaiter().GetResult().Trim();$errorText=$stderr.GetAwaiter().GetResult().Trim()
        if($process.ExitCode -eq 0){
            if($output -cne '17.0.1000.7|TRUE' -or $errorText.Length -ne 0 -or -not $driver){throw 'TLS_HV_SQLCMD_RESULT_INVALID'}
            $category='PASS'
        }else{$category=Get-TlsHyperVFailureCategory ($output+' '+$errorText)}
        if($category -cne $Expected){throw 'TLS_HV_SQLCMD_EXPECTATION_FAILED'}
        $after=& $Module {param($p)Read-LabTlsContextBinaryMetadata $p 'sqlcmd.exe'} $exe
        if($after.DiskSha256 -cne $before.DiskSha256){throw 'TLS_HV_SQLCMD_CHANGED'}
        if($driver){$again=& $Module {param($p,$n)Read-LabTlsContextBinaryMetadata $p $n} $driver.Path ([IO.Path]::GetFileName($driver.Path));if($again.DiskSha256 -cne $driver.DiskSha256){throw 'TLS_HV_ODBC_CHANGED'}}
        $results.Add([pscustomobject]@{Stack='ODBC sqlcmd';Encrypt=$true;TrustServerCertificate=$TrustServerCertificate;Observed=$category;SqlcmdSha256=$before.DiskSha256;LoadedOdbcSha256=$(if($driver){$driver.DiskSha256}else{$null})})
        return $results.ToArray()
    }finally{
        $null=$start.Environment.Remove('SQLCMDPASSWORD')
        if($started -and -not $process.HasExited){$process.Kill($true);$process.WaitForExit()};$process.Dispose()
    }
}

function Get-TlsHyperVCleanupGuestScript {
    return {
        param($OperationId,$Certificates,$OriginalContainer,$OriginalModulus,$RenewedContainer,$LastThumbprint,$OwnedRequests,[int]$ExpectedCertificateCount=5)
        $ErrorActionPreference='Stop';$ended=$true;$store=$null;$rsa=$null;$requests=$null
        try{
            if($OperationId -cnotmatch '\A[0-9a-f-]{36}\z' -or $RenewedContainer -cne ('SQLServerLab-TLS-Renew-'+$OperationId) -or $ExpectedCertificateCount -notin @(5,6) -or @($Certificates).Count -ne $ExpectedCertificateCount){throw 'TLS_HV_CLEANUP_SCOPE_INVALID'}
            if(@($Certificates|ForEach-Object Thumbprint|Sort-Object -Unique).Count -ne $ExpectedCertificateCount -or
                @($Certificates|ForEach-Object Sha256|Sort-Object -Unique).Count -ne $ExpectedCertificateCount){throw 'TLS_HV_CLEANUP_CERTIFICATE_DUPLICATE'}
            $folder=Join-Path $env:ProgramData ('SqlServerLab/TlsLeafAcceptance/'+$OperationId)
            $original=Get-Content -LiteralPath (Join-Path $folder 'original-binding.json') -Raw -ErrorAction Stop|ConvertFrom-Json
            if($original.OperationId -cne $OperationId -or $original.RegistryPath -cnotmatch '\AHKLM:\\SOFTWARE\\Microsoft\\Microsoft SQL Server\\MSSQL17\.[A-Za-z0-9_]+\\MSSQLServer\\SuperSocketNetLib\z' -or
                (Get-ItemPropertyValue -LiteralPath $original.RegistryPath -Name Certificate -ErrorAction Stop) -cne $LastThumbprint.ToLowerInvariant()){throw 'TLS_HV_CLEANUP_BINDING_CHANGED'}
            $store=[Security.Cryptography.X509Certificates.X509Store]::new('My','LocalMachine');$store.Open([Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
            foreach($record in $Certificates){
                $matches=@($store.Certificates|Where-Object Thumbprint -CEQ $record.Thumbprint)
                if($matches.Count -ne 1){throw 'TLS_HV_CLEANUP_CERTIFICATE_MISSING'}
                $sha=[Security.Cryptography.SHA256]::Create();try{$hash=([BitConverter]::ToString($sha.ComputeHash($matches[0].RawData))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
                if($hash -cne $record.Sha256){throw 'TLS_HV_CLEANUP_CERTIFICATE_CHANGED'}
            }
            $stream=[IO.File]::Open((Join-Path $folder 'cleanup-intent.json'),[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
            try{$bytes=[Text.Encoding]::UTF8.GetBytes((@{OperationId=$OperationId;Certificates=$Certificates}|ConvertTo-Json -Depth 4 -Compress));$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
            if($original.HadCertificate){Set-ItemProperty -LiteralPath $original.RegistryPath -Name Certificate -Value $original.Certificate -Type String -ErrorAction Stop}
            else{Remove-ItemProperty -LiteralPath $original.RegistryPath -Name Certificate -ErrorAction Stop}
            Set-ItemProperty -LiteralPath $original.RegistryPath -Name ForceEncryption -Value ([int]$original.ForceEncryption) -Type DWord -ErrorAction Stop
            $ended=$false
            Stop-Service MSSQLSERVER -ErrorAction Stop
            (Get-Service MSSQLSERVER -ErrorAction Stop).WaitForStatus([ServiceProcess.ServiceControllerStatus]::Stopped,[timespan]::FromSeconds(60))
            foreach($record in $Certificates){$matches=@($store.Certificates|Where-Object Thumbprint -CEQ $record.Thumbprint);$store.Remove($matches[0])}
            $requests=[Security.Cryptography.X509Certificates.X509Store]::new('REQUEST','LocalMachine');$requests.Open([Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
            foreach($record in $OwnedRequests){
                $matches=@($requests.Certificates|Where-Object Thumbprint -CEQ $record.Thumbprint)
                if($matches.Count -ne 1){throw 'TLS_HV_OWN_REQUEST_MISSING'}
                $sha=[Security.Cryptography.SHA256]::Create();try{$hash=([BitConverter]::ToString($sha.ComputeHash($matches[0].RawData))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
                if($hash -cne $record.Sha256){throw 'TLS_HV_OWN_REQUEST_CHANGED'}
                $requests.Remove($matches[0])
            }
            foreach($container in @($OriginalContainer,$RenewedContainer)){
                $parameters=[Security.Cryptography.CspParameters]::new(12,'Microsoft RSA SChannel Cryptographic Provider',$container)
                $parameters.KeyNumber=1;$parameters.Flags=[Security.Cryptography.CspProviderFlags]::UseExistingKey -bor [Security.Cryptography.CspProviderFlags]::UseMachineKeyStore
                $rsa=[Security.Cryptography.RSACryptoServiceProvider]::new($parameters)
                $path=Join-Path $env:ProgramData ('Microsoft/Crypto/RSA/MachineKeys/'+$rsa.CspKeyContainerInfo.UniqueKeyContainerName)
                $backup=Get-Content -LiteralPath (Join-Path $folder ($rsa.CspKeyContainerInfo.UniqueKeyContainerName+'.acl.json')) -Raw -ErrorAction Stop|ConvertFrom-Json
                if($backup.Path -cne $path -or $backup.Container -cne $container){throw 'TLS_HV_CLEANUP_KEY_BACKUP_INVALID'}
                $acl=Get-Acl -LiteralPath $path -ErrorAction Stop;$acl.SetSecurityDescriptorSddlForm($backup.Sddl,[Security.AccessControl.AccessControlSections]::Access);Set-Acl -LiteralPath $path -AclObject $acl -ErrorAction Stop
                if((Get-Acl -LiteralPath $path).Sddl -cne $backup.Sddl){throw 'TLS_HV_CLEANUP_ACL_NOT_RESTORED'}
                if($container -ceq $OriginalContainer){if([Convert]::ToBase64String($rsa.ExportParameters($false).Modulus) -cne $OriginalModulus){throw 'TLS_HV_ORIGINAL_KEY_CHANGED'}}
                else{$rsa.PersistKeyInCsp=$false;$rsa.Clear()}
                $rsa.Dispose();$rsa=$null
            }
            $parameters=[Security.Cryptography.CspParameters]::new(12,'Microsoft RSA SChannel Cryptographic Provider',$RenewedContainer)
            $parameters.KeyNumber=1;$parameters.Flags=[Security.Cryptography.CspProviderFlags]::UseExistingKey -bor [Security.Cryptography.CspProviderFlags]::UseMachineKeyStore
            $absent=$false
            try{$rsa=[Security.Cryptography.RSACryptoServiceProvider]::new($parameters)}catch [Security.Cryptography.CryptographicException]{if($_.Exception.GetBaseException().HResult -eq -2146893802){$absent=$true}else{throw}}
            if(-not $absent){throw 'TLS_HV_RENEWAL_KEY_REMAINS'}
            $store.Close();$store.Open([Security.Cryptography.X509Certificates.OpenFlags]::ReadOnly)
            if(@($store.Certificates|Where-Object {$_.Thumbprint -cin @($Certificates|ForEach-Object Thumbprint)}).Count){throw 'TLS_HV_CLEANUP_CERTIFICATE_REMAINS'}
            Start-Service MSSQLSERVER -ErrorAction Stop
            (Get-Service MSSQLSERVER -ErrorAction Stop).WaitForStatus([ServiceProcess.ServiceControllerStatus]::Running,[timespan]::FromSeconds(60))
            $ended=$true
            [pscustomobject]@{Success=$true;ConsumerEnded=$true;CertificatesRemoved=$ExpectedCertificateCount;OriginalKeyPreserved=$true;OriginalAclRestored=$true;RenewalKeyRemoved=$true;OriginalSqlBindingRestored=$true;SqlServiceRestarted=$true;Evidence='RETAINED_LOCAL_GUEST_JOURNALS_AND_PUBLIC_REQUESTS'}
        }catch{[pscustomobject]@{Success=$false;ConsumerEnded=$ended;ErrorCode='TLS_HV_CLEANUP_FAILED'}}
        finally{if($requests){$requests.Dispose()};if($rsa){$rsa.Dispose()};if($store){$store.Dispose()}}
    }
}
