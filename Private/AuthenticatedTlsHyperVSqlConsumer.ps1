#Requires -Version 7.2
# Guest code is intentionally compatible with Windows PowerShell 5.1.
function Get-LabTlsSqlSetupGuestScript {
    return {
        param($ExpectedRunId,$ExpectedScopeId,$SaPassword,$OperationId)
        $ErrorActionPreference='Stop'
        if($OperationId -cnotmatch '\A[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\z'){throw 'TLS_SQL_GUEST_OPERATION_INVALID'}
        function Assert-InstallerIdle {
            $installers=@(Get-CimInstance Win32_Process -ErrorAction Stop|Where-Object {$_.Name -match '^(?:setup|setup100|scenarioengine|msiexec)\.exe$'})
            if($installers.Count -or (Get-Service msiserver -ErrorAction Stop).Status -ne 'Stopped'){return $false}
            $mutex=$null;$held=$false
            try{
                try{$mutex=[Threading.Mutex]::OpenExisting('Global\_MSIExecute')}
                catch [Threading.WaitHandleCannotBeOpenedException]{return $true}
                try{$held=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$held=$true;throw 'TLS_SQL_MSI_ABANDONED'}
                return $held
            }finally{if($held){$mutex.ReleaseMutex()};if($mutex){$mutex.Dispose()}}
        }
        if(-not (Assert-InstallerIdle)){throw 'TLS_SQL_INSTALLER_NOT_IDLE'}
        $beforeBoot=(Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime.ToUniversalTime().ToString('o')
        $mediaDeadline=[datetime]::UtcNow.AddSeconds(60)
        do{
            $setup=@(Get-PSDrive -PSProvider FileSystem|ForEach-Object {
                $candidate=Join-Path $_.Root 'setup.exe'
                if(Test-Path -LiteralPath $candidate -PathType Leaf){Get-Item -LiteralPath $candidate -ErrorAction Stop}
            })
            if($setup.Count -eq 1 -or [datetime]::UtcNow -ge $mediaDeadline){break}
            Start-Sleep -Seconds 1
        }while($true)
        if($setup.Count -ne 1){throw 'TLS_SQL_SETUP_MEDIA_NOT_UNIQUE'}
        $intentRoot=Join-Path $env:ProgramData 'SqlServerLab/TlsSqlConsumers'
        $null=New-Item -ItemType Directory -Path $intentRoot -Force
        $intent=Join-Path $intentRoot ($OperationId+'.intent.json')
        $stream=$null;$pointer=[IntPtr]::Zero;$process=$null
        try{
            $pointer=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($SaPassword)
            $plain=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
            if($plain -match '[\s"]'){throw 'TLS_SQL_PASSWORD_COMMAND_LINE_UNSAFE'}
            $start=[datetime]::UtcNow
            $bytes=[Text.Encoding]::UTF8.GetBytes((@{OperationId=$OperationId;RunId=$ExpectedRunId;ScopeId=$ExpectedScopeId;Boot=$beforeBoot;StartedUtc=$start.ToString('o')}|ConvertTo-Json -Compress))
            $stream=[IO.File]::Open($intent,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
            $stream.Write($bytes,0,$bytes.Length);$stream.Flush($true);$stream.Dispose();$stream=$null
            $arguments=@('/Q','/ACTION=CompleteImage','/INSTANCEID=MSSQLSERVER','/INSTANCENAME=MSSQLSERVER','/SQLSYSADMINACCOUNTS="BUILTIN\Administrators"','/SECURITYMODE=SQL',"/SAPWD=$plain",'/TCPENABLED=1','/IACCEPTSQLSERVERLICENSETERMS','/INDICATEPROGRESS')
            $launch=[Diagnostics.ProcessStartInfo]::new();$launch.FileName=$setup[0].FullName;$launch.Arguments=$arguments -join ' '
            $launch.UseShellExecute=$false;$launch.CreateNoWindow=$true;$launch.RedirectStandardOutput=$true;$launch.RedirectStandardError=$true
            $process=[Diagnostics.Process]::Start($launch)
            $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
            $launch.Arguments=''
            $plain=$null;$arguments=$null
            # Timeout is deliberately non-destructive: no parent/child kill or reboot.
            if(-not $process.WaitForExit(5400000)){throw 'TLS_SQL_SETUP_TIMEOUT_RECOVERY_REQUIRED'}
            $null=$stdout.GetAwaiter().GetResult();$null=$stderr.GetAwaiter().GetResult()
            if($null -eq $process.ExitCode){throw 'TLS_SQL_SETUP_EXIT_UNKNOWN'}
            $exitCode=[int]$process.ExitCode
            if($exitCode -notin @(0,3010)){throw 'TLS_SQL_SETUP_FAILED_RECOVERY_REQUIRED'}
            $summaryRoot=Join-Path $env:ProgramFiles 'Microsoft SQL Server/170/Setup Bootstrap/Log'
            $summaries=@(Get-ChildItem -LiteralPath $summaryRoot -Filter Summary.txt -File -ErrorAction Stop|Where-Object {$_.LastWriteTimeUtc -ge $start.AddSeconds(-2)})
            if($summaries.Count -ne 1 -or $summaries[0].Length -gt 1048576){throw 'TLS_SQL_TERMINAL_SUMMARY_MISSING'}
            $text=[IO.File]::ReadAllText($summaries[0].FullName)
            if($text -notmatch '(?im)^\s*Final result:\s*Passed\s*$' -or $text -notmatch '(?im)^\s*Requested action:\s*CompleteImage\s*$' -or
                $text -notmatch ('(?im)^\s*Exit code \(Decimal\):\s*'+$exitCode+'\s*$')){throw 'TLS_SQL_TERMINAL_SUMMARY_INVALID'}
            $summaryDigest=(Get-FileHash -LiteralPath $summaries[0].FullName -Algorithm SHA256 -ErrorAction Stop).Hash
            $deadline=[datetime]::UtcNow.AddMinutes(10);$idleSince=$null
            do{
                if(Assert-InstallerIdle){if($null -eq $idleSince){$idleSince=[datetime]::UtcNow}}else{$idleSince=$null}
                if($null -ne $idleSince -and ([datetime]::UtcNow-$idleSince).TotalSeconds -ge 10){break}
                if([datetime]::UtcNow -ge $deadline){throw 'TLS_SQL_INSTALLER_QUIESCENCE_TIMEOUT'}
                Start-Sleep -Seconds 1
            }while($true)
            [pscustomobject]@{runId=$ExpectedRunId;scopeId=$ExpectedScopeId;operationId=$OperationId;exitCode=$exitCode;
                bootTimeBeforeRestart=$beforeBoot;summarySha256=$summaryDigest;installerIdle=$true;
                serviceName='MSSQLSERVER';completedAt=[datetime]::UtcNow.ToString('o')}
        }finally{
            $plain=$null;$arguments=$null
            if($stream){$stream.Dispose()};if($process){$process.Dispose()}
            if($pointer -ne [IntPtr]::Zero){[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)}
        }
    }
}

function Get-LabTlsSqlPostBootGuestScript {
    return {
        param($ExpectedSummarySha256)
        $ErrorActionPreference='Stop'
        $boot=(Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime.ToUniversalTime()
        if(([datetime]::UtcNow-$boot).TotalSeconds -lt 60){throw 'TLS_SQL_BOOT_SETTLING'}
        $idleSince=[datetime]::UtcNow
        do{
        $installers=@(Get-CimInstance Win32_Process -ErrorAction Stop|Where-Object {$_.Name -match '^(?:setup|setup100|scenarioengine|msiexec)\.exe$'})
        if($installers.Count -or (Get-Service msiserver -ErrorAction Stop).Status -ne 'Stopped'){throw 'TLS_SQL_BOOT_INSTALLER_ACTIVE'}
        $mutex=$null;$held=$false
        try{
            try{$mutex=[Threading.Mutex]::OpenExisting('Global\_MSIExecute')}catch [Threading.WaitHandleCannotBeOpenedException]{$mutex=$null}
            if($mutex){
                try{$held=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$held=$true;throw 'TLS_SQL_BOOT_MSI_ABANDONED'}
                if(-not $held){throw 'TLS_SQL_BOOT_MSI_ACTIVE'}
            }
        }finally{if($held){$mutex.ReleaseMutex()};if($mutex){$mutex.Dispose()}}
        foreach($key in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\InProgress','HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending','HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')){
            if(Test-Path -LiteralPath $key){throw 'TLS_SQL_BOOT_PENDING_INSTALLER'}
        }
        $rename=Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -ErrorAction Stop
        if($rename.PSObject.Properties['PendingFileRenameOperations'] -and @($rename.PendingFileRenameOperations|Where-Object {$_}).Count){throw 'TLS_SQL_BOOT_PENDING_RENAME'}
        foreach($path in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\RunOnce')){
            if(Test-Path -LiteralPath $path){if(@((Get-ItemProperty -LiteralPath $path -ErrorAction Stop).PSObject.Properties|Where-Object {$_.Name -notmatch '^PS'}).Count){throw 'TLS_SQL_BOOT_PENDING_RUNONCE'}}
        }
        $summary=Join-Path $env:ProgramFiles 'Microsoft SQL Server/170/Setup Bootstrap/Log/Summary.txt'
        if((Get-FileHash -LiteralPath $summary -Algorithm SHA256 -ErrorAction Stop).Hash -cne $ExpectedSummarySha256){throw 'TLS_SQL_BOOT_SUMMARY_CHANGED'}
        if((Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime.ToUniversalTime() -ne $boot){throw 'TLS_SQL_BOOT_EPOCH_CHANGED'}
        if(([datetime]::UtcNow-$idleSince).TotalSeconds -ge 10){break}
        Start-Sleep -Seconds 1
        }while($true)
        [pscustomobject]@{Boot=$boot.ToString('o');InstallerIdle=$true}
    }
}

function Get-LabTlsSqlReadinessGuestScript {
    return {
        $ErrorActionPreference='Stop';$deadline=[datetime]::UtcNow.AddSeconds(60);$connection=$null;$lastNumbers=@()
        do{
            try{
                $connection=[Data.SqlClient.SqlConnection]::new('Server=localhost,1433;Database=master;Integrated Security=True;Encrypt=True;TrustServerCertificate=True;Connect Timeout=5;Pooling=False;ConnectRetryCount=0;')
                $connection.Open();$command=$connection.CreateCommand();$command.CommandTimeout=5
                try{$command.CommandText="SELECT CONVERT(varchar(32),SERVERPROPERTY('ProductVersion'))+'|'+CONVERT(varchar(8),COUNT(*)) FROM sys.databases WHERE name IN('master','model','msdb','tempdb') AND state=0;";$actual=[string]$command.ExecuteScalar()}finally{$command.Dispose()}
                if($actual -cne '17.0.1000.7|4'){throw 'TLS_SQL_DATABASES_NOT_READY'}
                return [pscustomobject]@{Success=$true;ConsumerEnded=$true;Build='17.0.1000.7';OnlineSystemDatabases=4;ObservedUtc=[datetime]::UtcNow.ToString('o')}
            }catch{
                $failure=$_.Exception.GetBaseException()
                if($failure -is [Data.SqlClient.SqlException]){$lastNumbers=@($failure.Errors|ForEach-Object Number)}
                if([datetime]::UtcNow -ge $deadline){return [pscustomobject]@{Success=$false;ConsumerEnded=$true;ErrorCode='TLS_SQL_READINESS_TIMEOUT';SqlErrorNumbers=$lastNumbers}}
            }finally{if($connection){$connection.Dispose();$connection=$null}}
            Start-Sleep -Seconds 1
        }while($true)
    }
}

function Get-LabTlsSqlPostSetupGuestScript {
    $script={
        param($OperationId,$ExpectedAddress,$HostAddress,$ExpectedRunId,$ExpectedScopeId)
        $ErrorActionPreference='Stop';$ended=$true;$connection=$null
        try{
            # POST_SETUP: fixed single-instance TCP and host-only firewall scope.
            if([Net.IPAddress]::Parse($ExpectedAddress).ToString() -cne $ExpectedAddress -or [Net.IPAddress]::Parse($HostAddress).ToString() -cne $HostAddress -or
                @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop|Where-Object IPAddress -CEQ $ExpectedAddress).Count -ne 1 -or
                @(Get-NetRoute -AddressFamily IPv4 -ErrorAction Stop|Where-Object DestinationPrefix -CEQ '0.0.0.0/0').Count){throw 'TLS_SQL_POSTSETUP_NETWORK_CHANGED'}
            $map=Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL' -ErrorAction Stop
            $names=@($map.PSObject.Properties|Where-Object {$_.Name -notmatch '^PS'})
            if($names.Count -ne 1 -or $names[0].Name -cne 'MSSQLSERVER' -or $names[0].Value -cnotmatch '\AMSSQL17\.[A-Za-z0-9_]+\z'){throw 'TLS_SQL_POSTSETUP_INSTANCE_INVALID'}
            $instance=[string]$names[0].Value;$tcp='HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\'+$instance+'\MSSQLServer\SuperSocketNetLib\Tcp'
            $rule='SqlServerLab-Tls-HyperV-'+$OperationId
            if(Get-NetFirewallRule -Name $rule -ErrorAction SilentlyContinue){throw 'TLS_SQL_POSTSETUP_FIREWALL_PREEXISTING'}
            $intent=Join-Path $env:ProgramData ('SqlServerLab/TlsSqlConsumers/'+$OperationId+'.postsetup.json')
            $stream=[IO.File]::Open($intent,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
            try{$bytes=[Text.Encoding]::UTF8.GetBytes((@{OperationId=$OperationId;Rule=$rule;Address=$ExpectedAddress;RemoteAddress=$HostAddress;Port=1433}|ConvertTo-Json -Compress));$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
            Set-ItemProperty -LiteralPath $tcp -Name Enabled -Value 1 -Type DWord -ErrorAction Stop
            Set-ItemProperty -LiteralPath (Join-Path $tcp 'IPAll') -Name TcpDynamicPorts -Value '' -Type String -ErrorAction Stop
            Set-ItemProperty -LiteralPath (Join-Path $tcp 'IPAll') -Name TcpPort -Value '1433' -Type String -ErrorAction Stop
            $null=New-NetFirewallRule -Name $rule -DisplayName $rule -Direction Inbound -Action Allow -Protocol TCP -LocalPort 1433 -LocalAddress $ExpectedAddress -RemoteAddress $HostAddress -Profile Any -ErrorAction Stop
            $ended=$false;Restart-Service MSSQLSERVER -ErrorAction Stop
            (Get-Service MSSQLSERVER -ErrorAction Stop).WaitForStatus([ServiceProcess.ServiceControllerStatus]::Running,[timespan]::FromSeconds(60));$ended=$true
            $readiness=& {
                #FIXED_TLS_SQL_READINESS#
            }
            if(-not $readiness.Success){throw 'TLS_SQL_POSTSETUP_DATABASES_NOT_READY'}
            [pscustomobject]@{Success=$true;ConsumerEnded=$true;Build='17.0.1000.7';OnlineSystemDatabases=4;FirewallRule=$rule;
                runId=$ExpectedRunId;scopeId=$ExpectedScopeId;inspectedAt=[datetime]::UtcNow.ToString('o');
                instances=@([pscustomobject]@{name='MSSQLSERVER';instanceId=$instance;isDefault=$true;serviceName='MSSQLSERVER';serviceStatus='Running';tcpPort=1433})}
        }catch{[pscustomobject]@{Success=$false;ConsumerEnded=$ended;ErrorCode=$(if($_.Exception.Message -cmatch '\ATLS_SQL_[A-Z0-9_]+\z'){$_.Exception.Message}else{'TLS_SQL_POSTSETUP_FAILED'})}}
        finally{if($connection){$connection.Dispose()}}
    }
    # Only a fixed project-owned block is embedded; no caller code is accepted.
    return [scriptblock]::Create($script.ToString().Replace('#FIXED_TLS_SQL_READINESS#',(Get-LabTlsSqlReadinessGuestScript).ToString()))
}

function Assert-LabTlsSqlConsumerBudget {
    param([datetimeoffset]$DeadlineUtc,[string]$CancellationPath)
    if([datetimeoffset]::UtcNow -ge $DeadlineUtc -or ($CancellationPath -and (Test-Path -LiteralPath $CancellationPath))){throw 'TLS_SQL_CONSUMER_BUDGET_EXHAUSTED'}
}

function Invoke-LabTlsHyperVSqlCompletion {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session,[Parameter(Mandatory)][pscredential]$Credential,
        [Parameter(Mandatory)][securestring]$SqlSaPassword,[Parameter(Mandatory)][string]$MediaRoot,
        [ValidateRange(1,300)][int]$BootTimeoutSeconds=300,
        [datetimeoffset]$DeadlineUtc=[datetimeoffset]::UtcNow.AddMinutes(110),[string]$CancellationPath)
    Assert-LabTlsSqlConsumerBudget $DeadlineUtc $CancellationPath
    $ids=$Session.Ids;$stateRoot=Join-Path $Session.Binding.Root.DataRoot 'State'
    $binding=@{RunId=$ids.RunId;StateRoot=$stateRoot;ExpectedVmId=[guid]$ids.VmId}
    Assert-LabTlsRegistryWriterBinding $Session.Binding $ids.RootDigest $Session.Binding.ActorDigest
    $lab=Get-HyperVLabWorkflowRun @binding
    if($lab.Run.scopeId -cne $ids.ScopeId -or $lab.Instance.sqlCompletion -or
        $lab.Instance.windowsActivationIntent.Strategy -cne 'VerifyOnly' -or $lab.Instance.windowsActivationIntent.EgressPolicy -cne 'Denied'){throw 'TLS_SQL_COMPLETION_PRECONDITION_INVALID'}
    $managed=Assert-HyperVLabSqlVmBinding -Lab $lab -ExpectedVmId ([guid]$ids.VmId)
    $null=Assert-HyperVLabSqlExistingNetwork -Lab $lab -Managed $managed
    if([string]$managed.VM.State -cne 'Running'){throw 'TLS_SQL_COMPLETION_RUNNING_VM_REQUIRED'}
    $artifact=Get-HyperVImageArtifact -ArtifactId $lab.Instance.imageArtifactId -StateRoot $stateRoot
    if($artifact.artifactState -cne 'SQL_PREPARED_SEALED' -or $artifact.sql.version -cne '2025' -or $artifact.sql.build -notmatch '^2025\.0170\.1000\.07(?:\s|$)'){throw 'TLS_SQL_COMPLETION_SQL2025_RTM_PREPARED_REQUIRED'}
    $edition=ConvertTo-HyperVSqlMediaEdition $artifact.sql.edition
    $candidates=@(Get-HyperVSqlInstallationMediaCandidates -MediaRoot $MediaRoot|Where-Object {$_.State -ceq 'READY' -and $_.SqlVersion -ceq '2025' -and $_.MediaEdition -ceq $edition})
    if($candidates.Count -ne 1){throw 'TLS_SQL_COMPLETION_MEDIA_NOT_UNIQUE'}
    $media=Resolve-HyperVSqlInstallationMedia -MediaRoot $MediaRoot -SqlVersion '2025' -MediaEdition $edition -SqlMediaPath $candidates[0].MediaId
    if($media.HashStatus -cne 'SIDECAR_READY' -or (Get-FileHash -LiteralPath $media.IsoPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $media.ExpectedSha256){throw 'TLS_SQL_COMPLETION_MEDIA_HASH_INVALID'}
    $direct=@{VMName=$lab.Instance.vmName;ExpectedRunId=$ids.RunId;ExpectedScopeId=$ids.ScopeId;ExpectedVmId=[guid]$ids.VmId;Credential=$Credential;NoRetry=$true}
    # Reserve dispatch before media attachment, secret persistence or guest effects.
    $null=Write-LabTlsSqlConsumerStage $Session DISPATCHED
    try{
        Assert-LabTlsSqlConsumerBudget $DeadlineUtc $CancellationPath
        $managed=Assert-HyperVLabSqlVmBinding -Lab $lab -ExpectedVmId ([guid]$ids.VmId)
        $dvd=@(Get-VMDvdDrive -VM $managed.VM -ErrorAction Stop)
        if($dvd.Count -ne 0){throw 'TLS_SQL_COMPLETION_DVD_MUST_BE_ABSENT'}
        $null=Add-VMDvdDrive -VM $managed.VM -Path $media.IsoPath -ErrorAction Stop
        Save-LabHyperVSqlSaPassword -RunDirectory $lab.RunDirectory -SqlSaPassword $SqlSaPassword
        Assert-LabTlsSqlConsumerBudget $DeadlineUtc $CancellationPath
        $reply=@(Invoke-HyperVPowerShellDirect @direct -TimeoutSeconds 6060 -ScriptBlock (Get-LabTlsSqlSetupGuestScript) -ArgumentList @($ids.RunId,$ids.ScopeId,$SqlSaPassword,$ids.OperationId))
        if($reply.Count -ne 1 -or $reply[0].operationId -cne $ids.OperationId -or $reply[0].runId -cne $ids.RunId -or $reply[0].scopeId -cne $ids.ScopeId -or
            $reply[0].exitCode -notin @(0,3010) -or $reply[0].installerIdle -isnot [bool] -or -not $reply[0].installerIdle -or $reply[0].summarySha256 -cnotmatch '\A[A-F0-9]{64}\z'){throw 'TLS_SQL_COMPLETION_REPLY_INVALID'}
        $receipt=$reply[0];$oldBoot=[datetimeoffset]::Parse($receipt.bootTimeBeforeRestart)
        $null=Write-LabTlsSqlConsumerStage $Session REPLY_OBSERVED
        Write-LabTlsSqlConsumerEvidence $Session 'setup-reply.json' $receipt
        $null=Assert-HyperVLabSqlVmBinding -Lab $lab -ExpectedVmId ([guid]$ids.VmId)
        Assert-LabTlsSqlConsumerBudget $DeadlineUtc $CancellationPath
        Write-LabTlsSqlConsumerEvidence $Session 'reboot-intent.json' ([ordered]@{Binding=$ids;PreviousBoot=$oldBoot.ToString('o');SetupSummarySha256=$receipt.summarySha256;Method='Win32Shutdown(2)';Attempts=1})
        # No force flag or timed shutdown (which would imply force).
        Assert-LabTlsSqlConsumerBudget $DeadlineUtc $CancellationPath
        try{$restart=@(Invoke-HyperVPowerShellDirect @direct -TimeoutSeconds 30 -ScriptBlock {
            $ErrorActionPreference='Stop'
            $result=Invoke-CimMethod -InputObject (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop) -MethodName Win32Shutdown -Arguments @{Flags=2}
            if($result.ReturnValue -ne 0){throw 'TLS_SQL_ORDERLY_REBOOT_REJECTED'}
            [pscustomobject]@{Accepted=$true}
        })}catch{$restart=@();Write-Verbose 'Reboot reply unknown; only read-only new-boot observation may follow.'}
        $deadline=[datetime]::UtcNow.AddSeconds($BootTimeoutSeconds);$post=$null
        do{
            Assert-LabTlsSqlConsumerBudget $DeadlineUtc $CancellationPath
            $null=Get-HyperVLabWorkflowRun @binding
            try{
                $observed=@(Invoke-HyperVPowerShellDirect @direct -TimeoutSeconds 30 -ScriptBlock (Get-LabTlsSqlPostBootGuestScript) -ArgumentList @($receipt.summarySha256))
                if($observed.Count -eq 1 -and $observed[0].InstallerIdle -is [bool] -and $observed[0].InstallerIdle -and [datetimeoffset]::Parse($observed[0].Boot) -gt $oldBoot){$post=$observed[0];break}
            }catch{Write-Verbose 'Waiting for the same VM to complete its orderly reboot.'}
            if([datetime]::UtcNow -ge $deadline){throw 'TLS_SQL_NEW_BOOT_NOT_PROVEN'}
            Start-Sleep -Seconds 2
        }while($true)
        # The new epoch proves old consumers ended, separately from SQL readiness.
        Write-LabTlsSqlConsumerEvidence $Session 'consumer-end.json' ([ordered]@{ContractVersion='SqlServerLab.TlsSqlConsumerEnd/0.1';Binding=$ids;
            PreviousBoot=$oldBoot.ToString('o');NewBoot=$post.Boot;SetupExitCode=$receipt.exitCode;SetupSummarySha256=$receipt.summarySha256;InstallerIdle=$true;OldEpochEnded=$true})
        $null=Write-LabTlsSqlConsumerStage $Session RECOVERY_REQUIRED
        Assert-LabTlsSqlConsumerBudget $DeadlineUtc $CancellationPath
        $lab=Get-HyperVLabWorkflowRun @binding
        $null=Assert-HyperVLabSqlVmBinding -Lab $lab -ExpectedVmId ([guid]$ids.VmId)
        $null=Assert-HyperVLabSqlExistingNetwork -Lab $lab -Managed (Assert-HyperVLabSqlVmBinding -Lab $lab -ExpectedVmId ([guid]$ids.VmId))
        $postSetup=@(Invoke-HyperVPowerShellDirect @direct -TimeoutSeconds 180 -ScriptBlock (Get-LabTlsSqlPostSetupGuestScript) -ArgumentList @($ids.OperationId,$lab.Instance.labNetwork.address,$lab.Instance.labNetwork.hostAddress,$ids.RunId,$ids.ScopeId))
        Write-LabTlsSqlConsumerEvidence $Session 'postsetup-reply.json' @($postSetup)
        if($postSetup.Count -ne 1 -or $postSetup[0].Success -isnot [bool] -or -not $postSetup[0].Success -or $postSetup[0].ConsumerEnded -isnot [bool] -or -not $postSetup[0].ConsumerEnded -or
            $postSetup[0].OnlineSystemDatabases -ne 4 -or $postSetup[0].Build -cne '17.0.1000.7'){throw 'TLS_SQL_NATIVE_POSTCONDITION_FAILED'}
        $readiness=[pscustomobject]@{Ready=$true;Status='SQL_READY_RUN';Provider='hyperv';ProductVersion=$postSetup[0].Build;OnlineSystemDatabases=4;MajorVersion=17;ObservedAt=$postSetup[0].inspectedAt}
        $completion=[pscustomobject]@{state='COMPLETE';completedAt=[datetime]::UtcNow.ToString('o');sqlReadiness=$readiness;consumerEndOperationId=$ids.OperationId}
        Assert-LabTlsSqlConsumerBudget $DeadlineUtc $CancellationPath
        $lab=Get-HyperVLabWorkflowRun @binding
        $lab.Instance|Add-Member -NotePropertyName host -NotePropertyValue ([string]$lab.Instance.labNetwork.address) -Force
        $lab.Instance|Add-Member -NotePropertyName sqlReadiness -NotePropertyValue $readiness -Force
        $null=Save-HyperVLabSqlInstanceReceipt -Lab $lab -Receipt $postSetup[0] -ExpectedVmId ([guid]$ids.VmId)
        $lab.Instance|Add-Member -NotePropertyName sqlCompletion -NotePropertyValue $completion -Force
        $null=Assert-HyperVLabSqlVmBinding -Lab $lab -ExpectedVmId ([guid]$ids.VmId)
        Write-LabArtifactJsonAtomic -Path (Join-Path $lab.RunDirectory 'connection-info.json') -InputObject $lab.Connection
        return $completion
    }catch{
        # Preserve the original error; no automatic Stop, Remove or replay.
        $failure=$_
        try{$null=Write-LabTlsSqlConsumerStage $Session RECOVERY_REQUIRED}catch{Write-Verbose 'Original reservation remains recovery-required.'}
        throw $failure
    }
}
