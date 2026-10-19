# Windows-only SQL feature operations on an owned Hyper-V guest.
function Assert-LabHyperVSqlFeatureConsumersEnded {
    [CmdletBinding()]
    param($Context)
    try {
        $ended=@(Invoke-LabSqlFeatureGuest -Context $Context -ScriptBlock {
            $ErrorActionPreference='Stop'
            $active=@(Get-Process -ErrorAction Stop|Where-Object ProcessName -in @('setup','ScenarioEngine'))
            [bool]($active.Count -eq 0)
        })
    } catch {throw 'SQL_FEATURE_SETUP_CONSUMER_END_UNKNOWN_NO_REPLAY'}
    if($ended.Count -ne 1 -or $ended[0] -isnot [bool]){throw 'SQL_FEATURE_SETUP_CONSUMER_END_UNKNOWN_NO_REPLAY'}
    if(-not $ended[0]){throw 'SQL_FEATURE_SETUP_CONSUMER_ACTIVE_NO_REPLAY'}
}

function Invoke-LabHyperVFileStreamChange {
    [CmdletBinding()]
    param($Context,[bool]$Enabled)
    $null=Invoke-LabSqlFeatureGuest -Context $Context -Arguments @([int]$Enabled) -TimeoutSeconds 240 -ScriptBlock {
        param([int]$Level)
        $ErrorActionPreference='Stop'
        function Assert-FileStreamWmiOutcome {
            param($Outcome)
            if($null -eq $Outcome -or $null -eq $Outcome.ReturnValue){throw 'SQL_FEATURE_FILESTREAM_WMI_OUTCOME_UNKNOWN_NO_REPLAY'}
            $code=[uint32]$Outcome.ReturnValue
            # ERROR_SUCCESS_RESTART_REQUIRED (3011), also wrapped as an HRESULT.
            # A service restart follows; an OS reboot request (3010) is different.
            if($code -notin @([uint32]0,[uint32]3011,[uint32]2147945411)){
                throw ('SQL_FEATURE_FILESTREAM_WMI_FAILED: 0x{0:X8}' -f $code)
            }
            if($code -ne 0){Write-Information ('SQL_FEATURE_FILESTREAM_SERVICE_RESTART_REQUIRED: 0x{0:X8}' -f $code) -InformationAction Continue}
        }
        $connection=[Data.SqlClient.SqlConnection]::new('Server=localhost;Integrated Security=True;Encrypt=True;TrustServerCertificate=True')
        try {
            $connection.Open();$cmd=$connection.CreateCommand();$cmd.CommandText="SELECT CONVERT(int,SERVERPROPERTY('ProductMajorVersion'))";$major=[int]$cmd.ExecuteScalar()
            $settings=@(Get-CimInstance -Namespace "root\Microsoft\SqlServer\ComputerManagement$major" -ClassName FilestreamSettings -Filter "InstanceName='MSSQLSERVER'")
            if($settings.Count -ne 1){throw 'SQL_FEATURE_FILESTREAM_WMI_UNAVAILABLE'}
            $result=Invoke-CimMethod -InputObject $settings[0] -MethodName EnableFilestream -Arguments @{AccessLevel=[uint32]$Level;ShareName='MSSQLSERVER'}
            Assert-FileStreamWmiOutcome -Outcome $result
        } finally {$connection.Dispose()}
        $dependentServices=@((Get-Service MSSQLSERVER).DependentServices|Where-Object Status -eq Running|ForEach-Object Name)
        Restart-Service MSSQLSERVER -Force -ErrorAction Stop
        (Get-Service MSSQLSERVER).WaitForStatus('Running',[timespan]::FromSeconds(90))
        foreach($name in $dependentServices){Start-Service -Name $name -ErrorAction Stop}
        $connection=[Data.SqlClient.SqlConnection]::new('Server=localhost;Integrated Security=True;Encrypt=True;TrustServerCertificate=True')
        try{
            $deadline=[datetime]::UtcNow.AddSeconds(60)
            do{try{$connection.Open();break}catch{if([datetime]::UtcNow -ge $deadline){throw};Start-Sleep -Seconds 2}}while($true)
            $cmd=$connection.CreateCommand();$cmd.CommandText="EXEC sys.sp_configure N'filestream access level',$Level;RECONFIGURE;";$null=$cmd.ExecuteNonQuery()
        }finally{$connection.Dispose()}
    }
}

function Open-LabSqlFeatureMedia {
    [CmdletBinding()]
    param($Context,[bool]$Enabled,[string]$MediaRoot,[string]$SqlMediaPath)
    if (-not $MediaRoot) { $MediaRoot=Get-LabMediaRootDefault }
    $version=([string]$Context.SqlVersion -split '-')[0]
    $media=Resolve-HyperVSqlInstallationMedia -MediaRoot $MediaRoot -SqlVersion $version -MediaEdition Enterprise -SqlMediaPath $SqlMediaPath
    if ($media.HashStatus -ne 'SIDECAR_READY') { throw 'SQL_FEATURE_VERIFIED_MEDIA_REQUIRED' }
    $handle=[IO.FileStream]::new($media.IsoPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try {
        $sha=[Security.Cryptography.SHA256]::Create()
        try {$actual=[Convert]::ToHexString($sha.ComputeHash($handle))}finally{$sha.Dispose()}
        if($actual -ine $media.ExpectedSha256){throw 'SQL_FEATURE_MEDIA_HASH_MISMATCH'}
        [pscustomobject]@{Media=$media;Handle=$handle;Version=$version}
    }catch{$handle.Dispose();throw}
}

function Invoke-LabHyperVFullTextChange {
    [CmdletBinding()]
    param($Context,[bool]$Enabled,$MediaBinding)
    $media=$MediaBinding.Media;$version=$MediaBinding.Version
    $dvd=$null;$consumerEnded=$true
    try {
        $existing=@(Get-VMDvdDrive -VM $Context.VM | Where-Object Path -eq $media.IsoPath)
        if(-not $existing.Count){$dvd=Add-VMDvdDrive -VM $Context.VM -Path $media.IsoPath -Passthru}
        $consumerEnded=$false
        $result=@(Invoke-LabSqlFeatureGuest -Context $Context -Arguments @($Enabled,(Get-HyperVSqlSetupVersionPattern -SqlVersion $version)) -TimeoutSeconds 1800 -ScriptBlock {
            param([bool]$Enabled,[string]$VersionPattern)
            $ErrorActionPreference='Stop'
            if(@(Get-Process setup,ScenarioEngine -ErrorAction SilentlyContinue).Count){throw 'SQL_FEATURE_INSTALLER_BUSY'}
            $setups=@(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=5' | ForEach-Object {Get-Item -LiteralPath (Join-Path ($_.DeviceID+'\') 'setup.exe') -ErrorAction SilentlyContinue} | Where-Object {[string]$_.VersionInfo.FileVersion -match $VersionPattern})
            if($setups.Count -ne 1){throw 'SQL_FEATURE_MEDIA_NOT_UNIQUE'}
            $action=if($Enabled){'Install'}else{'Uninstall'}
            $arguments=@('/Q',"/ACTION=$action",'/FEATURES=FULLTEXT','/INSTANCENAME=MSSQLSERVER','/IACCEPTSQLSERVERLICENSETERMS','/INDICATEPROGRESS')
            if($Enabled){$arguments+=@('/UpdateEnabled=False','/USEMICROSOFTUPDATE=False')}
            $dependentServices=@((Get-Service MSSQLSERVER).DependentServices|Where-Object Status -eq Running|ForEach-Object Name)
            $setupDeadline=[datetime]::UtcNow.AddSeconds(1500)
            $process=Start-Process -FilePath $setups[0].FullName -ArgumentList $arguments -PassThru -WindowStyle Hidden
            if(-not $process.WaitForExit(1500000)){throw 'SQL_FEATURE_SETUP_TIMEOUT_NO_REPLAY'}
            do {
                $consumers=@(Get-Process setup,ScenarioEngine -ErrorAction SilentlyContinue|Where-Object Id -ne $process.Id)
                if(-not $consumers.Count){break}
                if([datetime]::UtcNow -ge $setupDeadline){throw 'SQL_FEATURE_SETUP_CONSUMER_END_UNKNOWN_NO_REPLAY'}
                Start-Sleep -Seconds 2
            } while($true)
            if($process.ExitCode -ne 0){return [pscustomobject]@{ConsumerEnded=$true;ExitCode=$process.ExitCode}}
            Restart-Service MSSQLSERVER -Force
            (Get-Service MSSQLSERVER).WaitForStatus('Running',[timespan]::FromSeconds(90))
            foreach($name in $dependentServices){
                # Removing FULLTEXT also removes its own launcher service.
                if(-not $Enabled -and $name -eq 'MSSQLFDLauncher'){continue}
                Start-Service -Name $name -ErrorAction Stop
            }
            [pscustomobject]@{ConsumerEnded=$true;ExitCode=0}
        })
        if($result.Count -ne 1 -or $result[0].ConsumerEnded -ne $true){throw 'SQL_FEATURE_SETUP_OUTCOME_UNKNOWN_NO_REPLAY'}
        $consumerEnded=$true
        if([int]$result[0].ExitCode -ne 0){throw 'SQL_FEATURE_SETUP_INCOMPLETE_NO_REPLAY'}
    } finally {
        if($dvd -and $consumerEnded){
            $current=@(Get-VMDvdDrive -VM $Context.VM | Where-Object {$_.ControllerNumber -eq $dvd.ControllerNumber -and $_.ControllerLocation -eq $dvd.ControllerLocation -and $_.Path -ceq $media.IsoPath})
            if($current.Count -ne 1){throw 'SQL_FEATURE_MEDIA_CLEANUP_BINDING_CHANGED'}
            Remove-VMDvdDrive -VMDvdDrive $current[0]
        }
    }
}
