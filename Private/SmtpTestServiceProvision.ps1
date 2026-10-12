# Run-scoped SMTP test-service provisioning.  This module deliberately keeps
# receiver credentials out of connection-info and all Lab_Data projections.

function Write-LabSmtpTestServiceJournal {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Journal,[Parameter(Mandatory)][string]$Path)
    $Journal.UpdatedAt=Get-LabTimestamp
    Write-LabArtifactJsonAtomic -Path $Path -InputObject $Journal | Out-Null
}

function Get-LabSmtpGatewayImageTag {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepositoryRoot)
    $source=Join-Path $RepositoryRoot 'Tools/SmtpTestServiceGateway.py'
    $dockerfile=Join-Path $RepositoryRoot 'Tools/SmtpTestServiceGateway.Dockerfile'
    if(-not(Test-Path -LiteralPath $source -PathType Leaf) -or -not(Test-Path -LiteralPath $dockerfile -PathType Leaf)){throw 'SMTP_TEST_GATEWAY_SOURCE_MISSING'}
    $material=([string](Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash)+([string](Get-FileHash -LiteralPath $dockerfile -Algorithm SHA256).Hash)
    $bytes=[Text.Encoding]::UTF8.GetBytes($material)
    try {
        $digest=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
    } finally { [Array]::Clear($bytes,0,$bytes.Length) }
    return ('sql-server-lab/smtp-gateway:'+ $digest.Substring(0,24))
}

function New-LabSmtpTestServiceRandomSecret {
    [CmdletBinding()]
    param()
    $bytes=[byte[]]::new(32)
    try {
        [Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
        $encoded=[Convert]::ToBase64String($bytes).Replace('+','-').Replace('/','_').TrimEnd('=')
        $secret=[Security.SecureString]::new()
        foreach($character in $encoded.ToCharArray()){$secret.AppendChar($character)}
        $secret.MakeReadOnly()
        return $secret
    } finally { [Array]::Clear($bytes,0,$bytes.Length) }
}

function New-LabSmtpTestServiceAuthFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunDirectory,[Parameter(Mandatory)]$Plan,[Parameter(Mandatory)][SecureString]$Password)
    $directory=Join-Path (Join-Path $RunDirectory 'smtp-test-service') 'secrets'
    $path=Join-Path $directory ($Plan.ScopeId+'-'+$Plan.ServiceId+'.mailpit-ui-auth')
    if(-not(Test-Path -LiteralPath $directory)){New-Item -ItemType Directory -Path $directory -Force -ErrorAction Stop|Out-Null}
    if(Test-Path -LiteralPath $path){throw 'SMTP_TEST_SERVICE_AUTH_FILE_COLLISION'}
    $ptr=[IntPtr]::Zero
    try {
        $ptr=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
        $plain=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
        [IO.File]::WriteAllText($path,('smtp-reader:'+ $plain),[Text.UTF8Encoding]::new($false))
    } finally {
        $plain=$null
        if($ptr -ne [IntPtr]::Zero){[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)}
    }
    return $path
}

function Remove-LabSmtpTestServiceSecretFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$RunDirectory)
    $root=[IO.Path]::GetFullPath((Join-Path $RunDirectory 'smtp-test-service'))
    $full=[IO.Path]::GetFullPath($Path)
    if(-not $full.StartsWith($root+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'SMTP_TEST_SECRET_CLEANUP_SCOPE_INVALID'}
    if(-not(Test-Path -LiteralPath $full -PathType Leaf)){return}
    $length=(Get-Item -LiteralPath $full -Force).Length
    [IO.File]::WriteAllBytes($full,[byte[]]::new($length))
    Remove-Item -LiteralPath $full -Force -ErrorAction Stop
}

function Invoke-LabSmtpRuntime {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('docker','podman')][string]$Provider,[Parameter(Mandatory)][string]$StateRoot,[Parameter(Mandatory)][string]$RunId,[Parameter(Mandatory)][string[]]$Arguments,[ValidateSet('Cleanup','ImageBuild','SqlQuery')][string]$Phase='Cleanup',[int]$TimeoutSeconds=120)
    $result=Invoke-LabContainerRuntimeCommand -Provider $Provider -StateRoot $StateRoot -RunId $RunId -ArgumentList $Arguments -NativeResult -Phase $Phase -TimeoutSeconds $TimeoutSeconds
    if($null -eq $result -or $result.ExitCode -ne 0){throw ('SMTP_TEST_RUNTIME_COMMAND_FAILED: '+($Arguments -join ' '))}
    return $result
}

function New-LabSmtpTestServiceDatabaseMailScript {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Plan)
    foreach($value in @($Plan.DatabaseMail.ProfileName,$Plan.DatabaseMail.AccountName,$Plan.DatabaseMail.GatewayHostName)){
        if($value -isnot [string] -or $value -cnotmatch '^[A-Za-z0-9_.-]{1,128}$'){throw 'SMTP_TEST_DATABASE_MAIL_PLAN_INVALID'}
    }
    $quote={param([string]$value) "N'"+$value.Replace("'","''")+"'"}
    $profile=&$quote $Plan.DatabaseMail.ProfileName;$account=&$quote $Plan.DatabaseMail.AccountName;$gatewayHost=&$quote $Plan.DatabaseMail.GatewayHostName
    @"
USE [msdb];
IF NOT EXISTS (SELECT 1 FROM sys.configurations WHERE name = N'Database Mail XPs' AND value_in_use = 1)
BEGIN
  EXEC sp_configure N'show advanced options', 1; RECONFIGURE;
  EXEC sp_configure N'Database Mail XPs', 1; RECONFIGURE;
END;
IF EXISTS (SELECT 1 FROM dbo.sysmail_account WHERE name = $account AND (email_address <> N'smtp-test@invalid' OR display_name <> N'SQL Server Lab SMTP Test'))
  THROW 51000, 'SMTP_TEST_DATABASE_MAIL_ACCOUNT_DRIFT', 1;
IF NOT EXISTS (SELECT 1 FROM dbo.sysmail_account WHERE name = $account)
  EXEC dbo.sysmail_add_account_sp @account_name=$account, @email_address=N'smtp-test@invalid', @display_name=N'SQL Server Lab SMTP Test', @mailserver_name=$gatewayHost, @port=$($Plan.DatabaseMail.GatewayPort);
IF EXISTS (SELECT 1 FROM dbo.sysmail_profile WHERE name = $profile)
  AND EXISTS (SELECT 1 FROM dbo.sysmail_profile WHERE name = $profile AND description <> N'Run-scoped SQL Server Lab SMTP test profile')
  THROW 51000, 'SMTP_TEST_DATABASE_MAIL_PROFILE_DRIFT', 1;
IF NOT EXISTS (SELECT 1 FROM dbo.sysmail_profile WHERE name = $profile)
  EXEC dbo.sysmail_add_profile_sp @profile_name=$profile, @description=N'Run-scoped SQL Server Lab SMTP test profile';
IF NOT EXISTS (SELECT 1 FROM dbo.sysmail_profileaccount pa JOIN dbo.sysmail_profile p ON p.profile_id=pa.profile_id JOIN dbo.sysmail_account a ON a.account_id=pa.account_id WHERE p.name=$profile AND a.name=$account)
  EXEC dbo.sysmail_add_profileaccount_sp @profile_name=$profile, @account_name=$account, @sequence_number=1;
IF (SELECT COUNT(*) FROM dbo.sysmail_profileaccount pa JOIN dbo.sysmail_profile p ON p.profile_id=pa.profile_id WHERE p.name=$profile) <> 1
  THROW 51000, 'SMTP_TEST_DATABASE_MAIL_PROFILE_DRIFT', 1;
"@
}

function Invoke-LabSmtpTestServiceProvision {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Plan,[Parameter(Mandatory)]$RunState,[Parameter(Mandatory)][object[]]$LabInstances,[Parameter(Mandatory)][SecureString]$SaPassword,[Parameter(Mandatory)][string]$StateRoot,[Parameter(Mandatory)][string]$RepositoryRoot)
    if($Plan.Contract.Name -cne 'SqlServerLab.SmtpTestServicePlan' -or $Plan.Contract.Version -cne '1.0'){throw 'SMTP_TEST_SERVICE_PLAN_INVALID'}
    if(Get-LabOwnedHostRunPolicy -RunId $RunState.RunId -StateRoot $StateRoot){throw 'SMTP_TEST_OWNED_HOST_UNSUPPORTED'}
    $senders=@($LabInstances | Where-Object {$Plan.SenderInstanceIds -contains [string]$_.Id})
    if($senders.Count -ne @($Plan.SenderInstanceIds).Count){throw 'SMTP_TEST_SERVICE_SENDER_BINDING_INVALID'}
    if(@($LabInstances | Select-Object -ExpandProperty Provider -Unique).Count -ne 1 -or [string]$senders[0].Provider -cne [string]$Plan.Provider){throw 'SMTP_TEST_SERVICE_PROVIDER_BINDING_INVALID'}
    $journalResult=New-LabSmtpTestServiceJournal -Plan $Plan -RunDirectory $RunState.RunDir
    $journal=$journalResult.Journal;$journalPath=$journalResult.Path;$provider=[string]$Plan.Provider
    $null=Add-CleanupStep -RunDir $RunState.RunDir -ResourceType network -ResourceId $Plan.ReceiverNetworkName -Action remove -Provider $provider -ProviderSubRunId ('provider-'+$provider) -Compensation 'Remove run-scoped SMTP receiver network'
    $null=Add-CleanupStep -RunDir $RunState.RunDir -ResourceType container -ResourceId $Plan.ReceiverContainerName -Action remove -Provider $provider -ProviderSubRunId ('provider-'+$provider) -Compensation 'Remove run-scoped SMTP receiver'
    $null=Add-CleanupStep -RunDir $RunState.RunDir -ResourceType container -ResourceId $Plan.GatewayContainerName -Action remove -Provider $provider -ProviderSubRunId ('provider-'+$provider) -Compensation 'Remove run-scoped SMTP gateway'
    $password=New-LabSmtpTestServiceRandomSecret
    Save-LabSecret -Path $RunState.RunDir -Name ('smtp-'+$Plan.ServiceId+'-ui-password') -Secret $password
    $authPath=New-LabSmtpTestServiceAuthFile -RunDirectory $RunState.RunDir -Plan $Plan -Password $password
    $journal.Status='PROVISIONING';Write-LabSmtpTestServiceJournal -Journal $journal -Path $journalPath
    try {
        $labels=@('--label',('sql-server-lab.run-id='+$RunState.RunId),'--label',('sql-server-lab.scope-id='+$RunState.ScopeId),'--label',('sql-server-lab.smtp-service-id='+$Plan.ServiceId))
        $senderNetwork=Invoke-LabSmtpRuntime -Provider $provider -StateRoot $StateRoot -RunId $RunState.RunId -Arguments (@('network','create','--internal')+$labels+@($Plan.SenderNetworkName))
        $journal.Resources.SenderNetworkId=([string]$senderNetwork.Output[-1]).Trim();Write-LabSmtpTestServiceJournal -Journal $journal -Path $journalPath
        # Docker does not publish a port from an internal bridge.  This bridge is
        # still run-private: only Mailpit and the gateway are attached and the
        # receiver API is bound to host loopback.
        $receiverNetwork=Invoke-LabSmtpRuntime -Provider $provider -StateRoot $StateRoot -RunId $RunState.RunId -Arguments (@('network','create')+$labels+@($Plan.ReceiverNetworkName))
        $journal.Resources.ReceiverNetworkId=([string]$receiverNetwork.Output[-1]).Trim();Write-LabSmtpTestServiceJournal -Journal $journal -Path $journalPath
        foreach($sender in $senders){$null=Invoke-LabSmtpRuntime -Provider $provider -StateRoot $StateRoot -RunId $RunState.RunId -Arguments @('network','connect',$Plan.SenderNetworkName,[string]$sender.ContainerId)}
        $mount='type=bind,source='+$authPath+',target=/run/smtp-auth,readonly'
        $receiverPort=Find-LabAvailablePort -RangeStart 18025 -RangeEnd 18124
        $receiver=Invoke-LabSmtpRuntime -Provider $provider -StateRoot $StateRoot -RunId $RunState.RunId -Arguments (@('run','-d','--name',$Plan.ReceiverContainerName,'--network',$Plan.ReceiverNetworkName,'-p',('127.0.0.1:'+$receiverPort+':8025'))+$labels+@('--mount',$mount,$Plan.Receiver.Image,'--ui-auth-file','/run/smtp-auth','--allowed-hosts',('127.0.0.1,localhost,'+$Plan.ReceiverContainerName)))
        $journal.Resources.ReceiverContainerId=([string]$receiver.Output[-1]).Trim();Write-LabSmtpTestServiceJournal -Journal $journal -Path $journalPath
        $gatewayTag=Get-LabSmtpGatewayImageTag -RepositoryRoot $RepositoryRoot
        $null=Invoke-LabSmtpRuntime -Provider $provider -StateRoot $StateRoot -RunId $RunState.RunId -Phase ImageBuild -TimeoutSeconds 600 -Arguments (@('build','--file',(Join-Path $RepositoryRoot $Plan.Gateway.ImageBuildFile),'--tag',$gatewayTag)+$labels+@($RepositoryRoot))
        $gateway=Invoke-LabSmtpRuntime -Provider $provider -StateRoot $StateRoot -RunId $RunState.RunId -Arguments (@('run','-d','--name',$Plan.GatewayContainerName,'--network',$Plan.SenderNetworkName,'--read-only','--tmpfs','/tmp:rw,noexec,nosuid,size=16m','--cap-drop','ALL','--security-opt','no-new-privileges','--mount',$mount)+$labels+@('-e',('SMTP_GATEWAY_API_URL=http://'+$Plan.ReceiverContainerName+':8025'),'-e','SMTP_GATEWAY_API_AUTH_FILE=/run/smtp-auth','-e',('SMTP_GATEWAY_MAX_MESSAGES='+$Plan.Gateway.MaxStoredMessages),'-e',('SMTP_GATEWAY_MAX_BYTES='+$Plan.Gateway.MaxStoredBytes),'-e',('SMTP_GATEWAY_MAX_MESSAGE_BYTES='+$Plan.Gateway.MaxMessageBytes),'-e',('SMTP_GATEWAY_MAX_PER_UTC60='+$Plan.Gateway.AcceptedMessagesPerUtc60Seconds),'-e',('SMTP_GATEWAY_UPSTREAM_HOST='+$Plan.ReceiverContainerName),'-e','SMTP_GATEWAY_UPSTREAM_PORT=1025',$gatewayTag))
        $journal.Resources.GatewayContainerId=([string]$gateway.Output[-1]).Trim();Write-LabSmtpTestServiceJournal -Journal $journal -Path $journalPath
        $null=Invoke-LabSmtpRuntime -Provider $provider -StateRoot $StateRoot -RunId $RunState.RunId -Arguments @('network','connect',$Plan.ReceiverNetworkName,$Plan.GatewayContainerName)
        $inspection=Invoke-LabSmtpRuntime -Provider $provider -StateRoot $StateRoot -RunId $RunState.RunId -Arguments @('inspect','--format','{{json .NetworkSettings.Ports}}',$Plan.ReceiverContainerName)
        try {$ports=(($inspection.Output -join "`n")|ConvertFrom-Json -Depth 16 -ErrorAction Stop);$binding=@($ports.'8025/tcp')[0]}catch{throw 'SMTP_TEST_RECEIVER_LOOPBACK_BINDING_PARSE_INVALID'}
        if($null -eq $binding){throw 'SMTP_TEST_RECEIVER_LOOPBACK_BINDING_MISSING'}
        if([string]$binding.HostIp -cne '127.0.0.1'){throw 'SMTP_TEST_RECEIVER_LOOPBACK_HOST_INVALID'}
        if([int]$binding.HostPort -ne $receiverPort){throw 'SMTP_TEST_RECEIVER_LOOPBACK_PORT_INVALID'}
        $port=$receiverPort
        foreach($sender in $senders){
            $script=New-LabSmtpTestServiceDatabaseMailScript -Plan $Plan
            $scriptPath=Join-Path (Split-Path -Parent $journalPath) ('database-mail-'+$sender.Id+'.sql')
            [IO.File]::WriteAllText($scriptPath,$script,[Text.UTF8Encoding]::new($true))
            $result=Invoke-LabSqlScript -ScriptPath $scriptPath -HostName $sender.Host -Port $sender.Port -SaPassword $SaPassword -Database 'master' -KeepConnection
            if(-not $result.Success){throw 'SMTP_TEST_DATABASE_MAIL_CONFIGURATION_FAILED'}
        }
        $journal.Status='READY';Write-LabSmtpTestServiceJournal -Journal $journal -Path $journalPath
        return [pscustomobject]@{ServiceId=$Plan.ServiceId;ProfileName=$Plan.DatabaseMail.ProfileName;GatewayHostName=$Plan.DatabaseMail.GatewayHostName;GatewayPort=$Plan.DatabaseMail.GatewayPort;Receiver=[pscustomobject]@{Host='127.0.0.1';Port=$port};JournalPath=$journalPath;SenderInstanceIds=@($Plan.SenderInstanceIds)}
    } catch { $journal.Status='FAILED';$journal.Recovery.ErrorCode='SMTP_TEST_SERVICE_PROVISION_FAILED';Write-LabSmtpTestServiceJournal -Journal $journal -Path $journalPath;throw }
}
