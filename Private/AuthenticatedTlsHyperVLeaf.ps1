#Requires -Version 7.2
# Explicit private acceptance lane; no implicit public Hyper-V False capability.
function Get-LabTlsHyperVOriginalKeyGuestScript {
    return {
        param($Container,$ExpectedModulus,$ExpectedMachineName,$ExpectedCertreqSha256)
        $ErrorActionPreference='Stop';$rsa=$null
        try{
            if($Container -cnotmatch '\ASQLServerLab-CSP-[0-9a-f-]{36}\z' -or [Environment]::MachineName -cne $ExpectedMachineName){throw 'TLS_HV_ORIGINAL_KEY_BINDING_INVALID'}
            $parameters=[Security.Cryptography.CspParameters]::new(12,'Microsoft RSA SChannel Cryptographic Provider',$Container)
            $parameters.KeyNumber=1;$parameters.Flags=[Security.Cryptography.CspProviderFlags]::UseExistingKey -bor [Security.Cryptography.CspProviderFlags]::UseMachineKeyStore
            $rsa=[Security.Cryptography.RSACryptoServiceProvider]::new($parameters);$profile=$rsa.CspKeyContainerInfo
            if($rsa.KeySize -ne 3072 -or $profile.Exportable -or -not $profile.MachineKeyStore -or $profile.ProviderType -ne 12 -or
                $profile.ProviderName -cne 'Microsoft RSA SChannel Cryptographic Provider' -or [int]$profile.KeyNumber -ne 1 -or
                $profile.KeyContainerName -cne $Container -or [Convert]::ToBase64String($rsa.ExportParameters($false).Modulus) -cne $ExpectedModulus -or
                (Get-FileHash -LiteralPath (Join-Path $env:SystemRoot 'System32/certreq.exe') -Algorithm SHA256).Hash -cne $ExpectedCertreqSha256){throw 'TLS_HV_ORIGINAL_KEY_CHANGED'}
            [pscustomobject]@{Success=$true;ConsumerEnded=$true;OriginalKeyBound=$true;Container=$Container;MachineName=[Environment]::MachineName;KeySize=3072;ProviderType=12;KeySpec=1;Exportable=$false;Modulus=$ExpectedModulus}
        }finally{if($rsa){$rsa.Dispose()}}
    }
}

function Get-LabTlsHyperVCsrGuestScript {
    return {
        param($OperationId,$Case,$Container,$Address,$ExpectedMachineName,$CreateKey,$ExpectedModulus,$ExpectedCertreqSha256,$RetryFailedInfSha256)
        $ErrorActionPreference='Stop';$process=$null;$rsa=$null;$ended=$true;$requests=$null;$nativeText=$null;$nativeExit=$null
        try{
            if($OperationId -cnotmatch '\A[0-9a-f-]{36}\z' -or $Case -cnotin @('valid','wrong-san','short','renewed') -or
                $Container -cnotmatch '\ASQLServerLab-(?:CSP|TLS-Renew)-[0-9a-f-]{36}\z' -or [Environment]::MachineName -cne $ExpectedMachineName -or
                [Net.IPAddress]::Parse($Address).ToString() -cne $Address){throw 'TLS_HV_CSR_INPUT_INVALID'}
            $parameters=[Security.Cryptography.CspParameters]::new(12,'Microsoft RSA SChannel Cryptographic Provider',$Container)
            $parameters.KeyNumber=1;$parameters.Flags=[Security.Cryptography.CspProviderFlags]::UseExistingKey -bor [Security.Cryptography.CspProviderFlags]::UseMachineKeyStore
            $exists=$false
            try{$rsa=[Security.Cryptography.RSACryptoServiceProvider]::new($parameters);$exists=$true}catch [Security.Cryptography.CryptographicException]{
                if($_.Exception.GetBaseException().HResult -ne -2146893802){throw}
            }
            if($CreateKey -isnot [bool] -or $exists -eq $CreateKey -or ($CreateKey -and ($Case -cne 'renewed' -or $Container -cne ('SQLServerLab-TLS-Renew-'+$OperationId)))){throw 'TLS_HV_CSR_KEY_PRECONDITION'}
            if($rsa){
                $profile=$rsa.CspKeyContainerInfo
                if($rsa.KeySize -ne 3072 -or $profile.Exportable -or -not $profile.MachineKeyStore -or $profile.ProviderType -ne 12 -or [int]$profile.KeyNumber -ne 1 -or [Convert]::ToBase64String($rsa.ExportParameters($false).Modulus) -cne $ExpectedModulus){throw 'TLS_HV_ORIGINAL_KEY_CHANGED'}
                $rsa.Dispose();$rsa=$null
            }
            $requests=[Security.Cryptography.X509Certificates.X509Store]::new('REQUEST','LocalMachine');$requests.Open([Security.Cryptography.X509Certificates.OpenFlags]::ReadOnly)
            $before=@{};foreach($item in $requests.Certificates){$before[$item.Thumbprint]=[Convert]::ToBase64String($item.RawData)};$requests.Close()
            $folder=Join-Path $env:ProgramData ('SqlServerLab/TlsLeafAcceptance/'+$OperationId)
            $prefix=$Case
            if($Case -ceq 'valid'){
                if(Test-Path -LiteralPath $folder){
                    if($RetryFailedInfSha256 -cnotmatch '\A[A-F0-9]{64}\z' -or $CreateKey -or
                        @(Get-ChildItem -LiteralPath $folder -Force).Count -ne 1 -or
                        (Get-FileHash -LiteralPath (Join-Path $folder 'valid.inf') -Algorithm SHA256).Hash -cne $RetryFailedInfSha256 -or
                        @(Get-CimInstance Win32_Process|Where-Object Name -CEQ certreq.exe).Count){throw 'TLS_HV_CSR_OPERATION_ALREADY_EXISTS'}
                    $prefix='valid-corrected'
                }else{
                if($RetryFailedInfSha256){throw 'TLS_HV_CSR_RETRY_EVIDENCE_MISSING'}
                $null=New-Item -ItemType Directory -Path $folder -Force
                $owner=[Security.Principal.WindowsIdentity]::GetCurrent().User
                $acl=[Security.AccessControl.DirectorySecurity]::new();$acl.SetOwner($owner);$acl.SetAccessRuleProtection($true,$false)
                foreach($sid in @($owner,[Security.Principal.SecurityIdentifier]::new('S-1-5-18'))){$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid,[Security.AccessControl.FileSystemRights]::FullControl,[Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit',[Security.AccessControl.PropagationFlags]::None,[Security.AccessControl.AccessControlType]::Allow))}
                Set-Acl -LiteralPath $folder -AclObject $acl -ErrorAction Stop
                }
            }elseif(-not (Test-Path -LiteralPath $folder -PathType Container)){throw 'TLS_HV_CSR_OPERATION_MISSING'}
            if((Get-Item -LiteralPath $folder -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'TLS_HV_CSR_SCOPE_REPARSE'}
            $inf=Join-Path $folder ($prefix+'.inf');$request=Join-Path $folder ($prefix+'.csr.der')
            $baseline=Join-Path $folder ($prefix+'.request-baseline.json')
            $stream=[IO.File]::Open($baseline,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
            try{$data=[Text.Encoding]::UTF8.GetBytes(($before|ConvertTo-Json -Compress));$stream.Write($data,0,$data.Length);$stream.Flush($true)}finally{$stream.Dispose()}
            # Existing-key enrollment cannot set key creation/export properties.
            $creationSettings=if($CreateKey){"KeyLength=3072`r`nExportable=FALSE"}else{''}
            $text=@"
[Version]
Signature="`$Windows NT`$"
[NewRequest]
Subject="CN=$ExpectedMachineName"
KeyContainer="$Container"
KeySpec=1
$creationSettings
MachineKeySet=TRUE
ProviderName="Microsoft RSA SChannel Cryptographic Provider"
ProviderType=12
RequestType=PKCS10
HashAlgorithm=SHA256
AlternateSignatureAlgorithm=FALSE
UseExistingKeySet=$(if($CreateKey){'FALSE'}else{'TRUE'})
SuppressDefaults=TRUE
Silent=TRUE
SMIME=FALSE
[Extensions]
2.5.29.17="{text}"
_continue_="IPAddress=$Address"
"@
            [byte[]]$bytes=[Text.Encoding]::Unicode.GetPreamble()+[Text.Encoding]::Unicode.GetBytes($text)
            $stream=[IO.File]::Open($inf,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
            try{$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
            if(Test-Path -LiteralPath $request){throw 'TLS_HV_CSR_REPLAY'}
            $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=Join-Path $env:SystemRoot 'System32/certreq.exe'
            if($ExpectedCertreqSha256 -cnotmatch '\A[A-F0-9]{64}\z' -or (Get-FileHash -LiteralPath $start.FileName -Algorithm SHA256).Hash -cne $ExpectedCertreqSha256){throw 'TLS_HV_CERTREQ_BINARY_CHANGED'}
            $start.Arguments='-q -new -machine -binary "'+$inf+'" "'+$request+'"';$start.UseShellExecute=$false;$start.CreateNoWindow=$true
            $start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
            $process=[Diagnostics.Process]::Start($start);$ended=$false
            $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
            if(-not $process.WaitForExit(60000)){throw 'TLS_HV_CERTREQ_TIMEOUT'}
            $ended=$true;$nativeText=($stdout.GetAwaiter().GetResult()+' '+$stderr.GetAwaiter().GetResult());$nativeExit=$process.ExitCode
            if($process.ExitCode -ne 0){throw 'TLS_HV_CERTREQ_FAILED'}
            if((Get-FileHash -LiteralPath $start.FileName -Algorithm SHA256).Hash -cne $ExpectedCertreqSha256){throw 'TLS_HV_CERTREQ_BINARY_CHANGED'}
            $rsa=[Security.Cryptography.RSACryptoServiceProvider]::new($parameters);$info=$rsa.CspKeyContainerInfo
            if($rsa.KeySize -ne 3072 -or $info.Exportable -or -not $info.MachineKeyStore -or $info.ProviderType -ne 12 -or [int]$info.KeyNumber -ne 1){throw 'TLS_HV_CSP_PROFILE_INVALID'}
            $public=$rsa.ExportParameters($false);$der=[IO.File]::ReadAllBytes($request)
            if($der.Length -gt 16384 -or [Convert]::ToBase64String($public.Exponent) -cne 'AQAB'){throw 'TLS_HV_CSR_PROFILE_INVALID'}
            $requests.Open([Security.Cryptography.X509Certificates.OpenFlags]::ReadOnly);$owned=@()
            foreach($thumb in $before.Keys){$found=@($requests.Certificates|Where-Object Thumbprint -CEQ $thumb);if($found.Count -ne 1 -or [Convert]::ToBase64String($found[0].RawData) -cne $before[$thumb]){throw 'TLS_HV_PREEXISTING_REQUEST_CHANGED'}}
            foreach($item in $requests.Certificates){if(-not $before.ContainsKey($item.Thumbprint)){
                $requestKey=$item.PrivateKey
                try{if($requestKey -isnot [Security.Cryptography.RSACryptoServiceProvider] -or $requestKey.CspKeyContainerInfo.UniqueKeyContainerName -cne $info.UniqueKeyContainerName -or
                    $requestKey.CspKeyContainerInfo.ProviderType -ne 12 -or [int]$requestKey.CspKeyContainerInfo.KeyNumber -ne 1 -or
                    [Convert]::ToBase64String($requestKey.ExportParameters($false).Modulus) -cne [Convert]::ToBase64String($public.Modulus)){throw 'TLS_HV_NEW_REQUEST_UNBOUND'}}finally{if($requestKey){$requestKey.Dispose()}}
                $sha=[Security.Cryptography.SHA256]::Create();try{$hash=([BitConverter]::ToString($sha.ComputeHash($item.RawData))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
                $owned+=,[pscustomobject]@{Thumbprint=$item.Thumbprint;Sha256=$hash}
            }}
            [pscustomobject]@{Success=$true;ConsumerEnded=$true;Csr=[Convert]::ToBase64String($der);Modulus=[Convert]::ToBase64String($public.Modulus);UniqueContainer=$info.UniqueKeyContainerName;MachineName=$ExpectedMachineName;Container=$Container;OwnedRequests=$owned}
        }catch{[pscustomobject]@{Success=$false;ConsumerEnded=$ended;ErrorCode=$(if($_.Exception.Message -cmatch '\ATLS_HV_[A-Z0-9_]+\z'){$_.Exception.Message}else{'TLS_HV_CSR_FAILED'});FailureType=$_.Exception.GetBaseException().GetType().FullName;HResult=$_.Exception.GetBaseException().HResult;CertreqExitCode=$nativeExit;CertreqText=$(if($nativeText){$nativeText.Substring(0,[math]::Min(8192,$nativeText.Length))}else{$null})}}
        finally{if($requests){$requests.Dispose()};if($rsa){$rsa.Dispose()};if($process){$process.Dispose()}}
    }
}

function Get-LabTlsHyperVLeafInstallGuestScript {
    return {
        param($OperationId,$Case,$CertificateBase64,$ExpectedSha256,$ExpectedContainer,$ExpectedModulus)
        $ErrorActionPreference='Stop';$process=$null;$cert=$null;$private=$null;$ended=$true;$store=$null
        try{
            if($OperationId -cnotmatch '\A[0-9a-f-]{36}\z' -or $Case -cnotin @('untrusted','valid','wrong-san','short','short-isolated','renewed') -or $ExpectedSha256 -cnotmatch '\A[a-f0-9]{64}\z'){throw 'TLS_HV_LEAF_INPUT_INVALID'}
            $bytes=[Convert]::FromBase64String($CertificateBase64);$sha=[Security.Cryptography.SHA256]::Create()
            try{$digest=([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
            if($bytes.Length -gt 16384 -or $digest -cne $ExpectedSha256){throw 'TLS_HV_LEAF_HASH_INVALID'}
            $cert=[Security.Cryptography.X509Certificates.X509Certificate2]::new($bytes)
            $store=[Security.Cryptography.X509Certificates.X509Store]::new('My','LocalMachine');$store.Open([Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
            if(@($store.Certificates|Where-Object Thumbprint -CEQ $cert.Thumbprint).Count){throw 'TLS_HV_LEAF_PREEXISTING'}
            $map=Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL' -ErrorAction Stop
            $instance=[string]$map.MSSQLSERVER
            if($instance -cnotmatch '\AMSSQL17\.[A-Za-z0-9_]+\z'){throw 'TLS_HV_SQL_INSTANCE_INVALID'}
            $key='HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\'+$instance+'\MSSQLServer\SuperSocketNetLib'
            $service=Get-CimInstance Win32_Service -Filter "Name='MSSQLSERVER'" -ErrorAction Stop
            if($service.StartName -ine 'NT Service\MSSQLSERVER'){throw 'TLS_HV_SQL_SERVICE_IDENTITY_UNSUPPORTED'}
            $folder=Join-Path $env:ProgramData ('SqlServerLab/TlsLeafAcceptance/'+$OperationId)
            if(-not (Test-Path -LiteralPath $folder -PathType Container)){throw 'TLS_HV_LEAF_CSR_SCOPE_REQUIRED'}
            $original=Join-Path $folder 'original-binding.json'
            if(-not (Test-Path -LiteralPath $original)){
                $settings=Get-ItemProperty -LiteralPath $key -ErrorAction Stop
                $record=@{OperationId=$OperationId;RegistryPath=$key;HadCertificate=($null -ne $settings.PSObject.Properties['Certificate']);Certificate=[string]$settings.Certificate;ForceEncryption=[int]$settings.ForceEncryption}
                $stream=[IO.File]::Open($original,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
                try{$data=[Text.Encoding]::UTF8.GetBytes(($record|ConvertTo-Json -Compress));$stream.Write($data,0,$data.Length);$stream.Flush($true)}finally{$stream.Dispose()}
            }
            $intent=Join-Path $folder ($Case+'.install-intent.json');$stream=[IO.File]::Open($intent,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
            try{$data=[Text.Encoding]::UTF8.GetBytes((@{OperationId=$OperationId;Case=$Case;Sha256=$ExpectedSha256;Thumbprint=$cert.Thumbprint;Container=$ExpectedContainer}|ConvertTo-Json -Compress));$stream.Write($data,0,$data.Length);$stream.Flush($true)}finally{$stream.Dispose()}
            $path=Join-Path $folder ($Case+'.cer');[IO.File]::WriteAllBytes($path,$bytes)
            # .NET Framework guest association names the existing machine CSP key;
            # no PFX or private key export/import is involved.
            $parameters=[Security.Cryptography.CspParameters]::new(12,'Microsoft RSA SChannel Cryptographic Provider',$ExpectedContainer)
            $parameters.KeyNumber=1;$parameters.Flags=[Security.Cryptography.CspProviderFlags]::UseExistingKey -bor [Security.Cryptography.CspProviderFlags]::UseMachineKeyStore
            $private=[Security.Cryptography.RSACryptoServiceProvider]::new($parameters)
            $expectedUnique=$private.CspKeyContainerInfo.UniqueKeyContainerName
            if([Convert]::ToBase64String($private.ExportParameters($false).Modulus) -cne $ExpectedModulus){throw 'TLS_HV_LEAF_KEY_MISMATCH'}
            $cert.PrivateKey=$private
            $store.Add($cert)
            $private.Dispose();$private=$null
            $store.Close();$store.Open([Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
            $installed=@($store.Certificates|Where-Object Thumbprint -CEQ $cert.Thumbprint)
            if($installed.Count -ne 1 -or -not $installed[0].HasPrivateKey){throw 'TLS_HV_LEAF_PRIVATE_KEY_MISSING'}
            $private=$installed[0].PrivateKey
            if($private -isnot [Security.Cryptography.RSACryptoServiceProvider] -or $private.CspKeyContainerInfo.UniqueKeyContainerName -cne $expectedUnique -or
                $private.CspKeyContainerInfo.Exportable -or [int]$private.CspKeyContainerInfo.KeyNumber -ne 1 -or $private.CspKeyContainerInfo.ProviderType -ne 12 -or
                [Convert]::ToBase64String($private.ExportParameters($false).Modulus) -cne $ExpectedModulus){throw 'TLS_HV_LEAF_KEY_BINDING_INVALID'}
            $keyFile=Join-Path $env:ProgramData ('Microsoft/Crypto/RSA/MachineKeys/'+$private.CspKeyContainerInfo.UniqueKeyContainerName)
            $item=Get-Item -LiteralPath $keyFile -Force -ErrorAction Stop
            if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'TLS_HV_LEAF_KEY_REPARSE'}
            $acl=Get-Acl -LiteralPath $keyFile -ErrorAction Stop
            $aclBackup=Join-Path $folder ($private.CspKeyContainerInfo.UniqueKeyContainerName+'.acl.json')
            if(-not (Test-Path -LiteralPath $aclBackup)){
                $stream=[IO.File]::Open($aclBackup,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
                try{$data=[Text.Encoding]::UTF8.GetBytes((@{Path=$keyFile;Sddl=$acl.Sddl;Container=$ExpectedContainer}|ConvertTo-Json -Compress));$stream.Write($data,0,$data.Length);$stream.Flush($true)}finally{$stream.Dispose()}
            }
            $sid=([Security.Principal.NTAccount]::new($service.StartName)).Translate([Security.Principal.SecurityIdentifier])
            $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid,[Security.AccessControl.FileSystemRights]::Read,[Security.AccessControl.AccessControlType]::Allow))
            Set-Acl -LiteralPath $keyFile -AclObject $acl -ErrorAction Stop
            Set-ItemProperty -LiteralPath $key -Name Certificate -Value $cert.Thumbprint.ToLowerInvariant() -Type String -ErrorAction Stop
            Set-ItemProperty -LiteralPath $key -Name ForceEncryption -Value 1 -Type DWord -ErrorAction Stop
            $ended=$false
            Restart-Service -Name MSSQLSERVER -ErrorAction Stop
            (Get-Service MSSQLSERVER -ErrorAction Stop).WaitForStatus([ServiceProcess.ServiceControllerStatus]::Running,[timespan]::FromSeconds(60))
            $errorLog=Get-ItemPropertyValue -LiteralPath ('HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\'+$instance+'\MSSQLServer\Parameters') -Name SQLArg1 -ErrorAction Stop
            if($errorLog -notlike '-e*'){throw 'TLS_HV_SQL_ERRORLOG_PATH_INVALID'}
            $content=Get-Content -LiteralPath $errorLog.Substring(2).Trim('"') -Raw -ErrorAction Stop
            if($content -notmatch ('(?i)Cert Hash\(sha1\)\s+"?'+[regex]::Escape($cert.Thumbprint)+'"?.*successfully loaded')){throw 'TLS_HV_SQL_CERTIFICATE_NOT_LOADED'}
            $ended=$true
            [pscustomobject]@{Success=$true;ConsumerEnded=$true;Thumbprint=$cert.Thumbprint;Sha256=$ExpectedSha256;Container=$ExpectedContainer;ServiceSid=$sid.Value;Loaded=$true;SqlServiceRestarted=$true}
        }catch{[pscustomobject]@{Success=$false;ConsumerEnded=$ended;ErrorCode='TLS_HV_LEAF_INSTALL_FAILED'}}
        finally{if($process){$process.Dispose()};if($private){$private.Dispose()};if($store){$store.Dispose()};if($cert){$cert.Dispose()}}
    }
}
