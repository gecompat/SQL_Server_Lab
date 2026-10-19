# Optional instance features. Intent is explicit; absent fields preserve legacy behaviour.
function Get-LabSqlFeatureIntentFingerprint {
    [CmdletBinding()]
    param($Intent)
    if($null -eq $Intent){return $null}
    $result=[ordered]@{}
    foreach($name in @('fullText','fileStream')){
        $present=if($Intent -is [Collections.IDictionary]){$Intent.Contains($name)}else{$null -ne $Intent.PSObject.Properties[$name]}
        if($present){
            if($Intent.$name -isnot [bool]){throw 'SQL_FEATURE_INTENT_STATE_INVALID'}
            $result[$name]=$Intent.$name
        }
    }
    if(-not $result.Count){throw 'SQL_FEATURE_INTENT_STATE_INVALID'}
    [pscustomobject]$result
}

function Assert-LabSqlFeatureRecoveryClear {
    [CmdletBinding()]
    param([string]$RunId,[string]$StateRoot)
    if(-not $StateRoot){$StateRoot=Get-LabStateRoot}
    $directory=Join-Path (Join-Path $StateRoot 'runs') $RunId
    if(Test-Path -LiteralPath $directory -PathType Container){
        foreach($file in @(Get-ChildItem -LiteralPath $directory -Filter 'sql-feature-*.json' -File -ErrorAction Stop)){
            $operation=Get-Content -LiteralPath $file.FullName -Raw|ConvertFrom-Json
            if($operation.Status -cne 'COMPLETED'){throw 'SQL_FEATURE_RECOVERY_REQUIRED_NO_REPLAY'}
        }
    }
}

function Enter-LabSqlFeatureConflictGuard {
    [CmdletBinding()]
    param([string]$RunId,[string]$StateRoot,[switch]$AllowFeatureRecovery)
    if(-not $StateRoot){$StateRoot=Get-LabStateRoot}
    $name=Get-LabContainerResourceLockName -StateRoot $StateRoot -RunId $RunId
    # GUI, elevated guest work and CI may run in different Windows sessions.
    if($IsWindows){$name='Global\'+$name}
    $mutex=[Threading.Mutex]::new($false,$name);$acquired=$false
    try {
        try{$acquired=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$acquired=$true}
        if(-not $acquired){throw 'SQL_FEATURE_OPERATION_BUSY'}
        if(-not $AllowFeatureRecovery){Assert-LabSqlFeatureRecoveryClear -RunId $RunId -StateRoot $StateRoot}
        return $mutex
    } catch {
        if($acquired){$mutex.ReleaseMutex()}
        $mutex.Dispose()
        throw
    }
}

function Resolve-LabSqlFeatureIntent {
    [CmdletBinding()]
    param($Intent,[Parameter(Mandatory)][string]$Provider,[Parameter(Mandatory)][string]$SqlVersion)
    if ($null -eq $Intent) { return $null }
    $properties = if ($Intent -is [Collections.IDictionary]) { @($Intent.Keys) } else { @($Intent.PSObject.Properties.Name) }
    if ($Intent -is [string] -or $Intent -is [array] -or $Intent -is [bool] -or
        $properties.Count -eq 0 -or @($properties | Where-Object { $_ -cnotin @('fullText','fileStream') }).Count) { throw 'SQL_FEATURE_INTENT_INVALID' }
    $result = [ordered]@{}
    foreach ($name in $properties) {
        if ($Intent.$name -isnot [bool]) { throw 'SQL_FEATURE_INTENT_INVALID' }
        if ($name -ceq 'fileStream' -and $Intent.$name -and $Provider -ne 'hyperv') { throw 'SQL_FEATURE_FILESTREAM_WINDOWS_REQUIRED: FILESTREAM benötigt Windows/Hyper-V; SQL Server auf Linux unterstützt FILESTREAM nicht.' }
        if ($SqlVersion -notmatch '^(2019|2022|2025)(?:$|-)' -or $Provider -notin @('docker','podman','hyperv')) { throw 'SQL_FEATURE_VERSION_PROVIDER_UNSUPPORTED' }
        $result[$name] = $Intent.$name
    }
    [pscustomobject]$result
}

function Get-LabSqlFeatureVersion {
    param([Parameter(Mandatory)]$Instance)
    $version=if($Instance.provider -eq 'hyperv'){[string]$Instance.sqlVersion}else{[string]$Instance.version}
    if([string]::IsNullOrWhiteSpace($version)){throw 'SQL_FEATURE_ENGINE_VERSION_UNKNOWN'}
    $version
}

function Get-LabSqlFeatureContext {
    [CmdletBinding()]
    param([string]$RunId,[string]$InstanceId,[string]$StateRoot,[securestring]$SaPassword,[pscredential]$GuestCredential)
    $environment = Get-LabEnvironmentResourceContext -RunId $RunId -StateRoot $StateRoot
    $instances = @($environment.Connection.instances | Where-Object { [string]$_.id -ceq $InstanceId })
    if ($instances.Count -ne 1 -or $environment.Run.state -cne 'RUNNING') { throw 'SQL_FEATURE_RUNNING_INSTANCE_REQUIRED' }
    $instance = $instances[0]
    $context = [pscustomobject]@{
        RunId=$RunId; InstanceId=$InstanceId; StateRoot=$environment.StateRoot; RunDirectory=$environment.RunDirectory
        Run=$environment.Run; Provider=[string]$instance.provider; Instance=$instance; SqlVersion=(Get-LabSqlFeatureVersion -Instance $instance); RuntimeId=$null
        GuestCredential=$GuestCredential; SaPassword=$SaPassword; Container=$null; VM=$null
    }
    if ($context.Provider -in @('docker','podman')) {
        $context.Container = Get-LabContainerReconcileContext -RunId $RunId -InstanceId $InstanceId -StateRoot $environment.StateRoot
        if (-not $context.Container.WasRunning) { throw 'SQL_FEATURE_RUNNING_INSTANCE_REQUIRED' }
        $ports = @($context.Container.Inspect.NetworkSettings.Ports.'1433/tcp')
        if ($ports.Count -ne 1 -or $ports[0].HostIp -notin @('127.0.0.1','::1') -or [int]$ports[0].HostPort -ne [int]$instance.port) { throw 'SQL_FEATURE_ENDPOINT_BINDING_INVALID' }
        $context.RuntimeId = [string]$context.Container.ContainerId
        if (-not $context.SaPassword) {
            $context.SaPassword = Get-LabSecret -Path $environment.RunDirectory -Name 'generated-sql-sa-password'
            if (-not $context.SaPassword) { $context.SaPassword = Get-LabSecret -Path $environment.RunDirectory -Name 'sa-password' }
        }
        if (-not $context.SaPassword) { throw 'SQL_FEATURE_SQL_CREDENTIAL_REQUIRED' }
    }
    elseif ($context.Provider -eq 'hyperv') {
        $managed = Get-HyperVManagedVM -VMName ([string]$instance.vmName) -ExpectedRunId $RunId -ExpectedScopeId ([string]$environment.Run.scopeId)
        if (-not $managed -or [string]$managed.VM.Id -cne [string]$instance.vmId -or [string]$managed.VM.State -ne 'Running') { throw 'SQL_FEATURE_VM_BINDING_INVALID' }
        $context.VM = $managed.VM; $context.RuntimeId = [string]$managed.VM.Id
        if (-not $context.GuestCredential) {
            $secret = Get-LabSecret -Path $environment.RunDirectory -Name 'guest-administrator-password'
            if (-not $secret) { throw 'SQL_FEATURE_GUEST_CREDENTIAL_REQUIRED' }
            $context.GuestCredential = [pscredential]::new('Administrator',$secret)
        }
    }
    else { throw 'SQL_FEATURE_PROVIDER_UNSUPPORTED' }
    $context
}

function Invoke-LabSqlFeatureGuest {
    [CmdletBinding()]
    param($Context,[scriptblock]$ScriptBlock,[object[]]$Arguments=@(),[int]$TimeoutSeconds=120)
    Invoke-HyperVPowerShellDirect -VMName ([string]$Context.Instance.vmName) -ExpectedRunId $Context.RunId `
        -ExpectedScopeId ([string]$Context.Run.scopeId) -ExpectedVmId ([guid]$Context.RuntimeId) `
        -Credential $Context.GuestCredential -ScriptBlock $ScriptBlock -ArgumentList $Arguments -NoRetry -TimeoutSeconds $TimeoutSeconds
}

function Invoke-LabSqlFeatureSql {
    [CmdletBinding()]
    param($Context,[string]$Query,[int]$TimeoutSeconds=120)
    if ($Context.Provider -eq 'hyperv') {
        return Invoke-LabSqlFeatureGuest -Context $Context -Arguments @($Query,$TimeoutSeconds) -TimeoutSeconds ($TimeoutSeconds+30) -ScriptBlock {
            param($Query,$TimeoutSeconds)
            $ErrorActionPreference='Stop'
            $connection=[Data.SqlClient.SqlConnection]::new('Server=localhost;Integrated Security=True;Encrypt=True;TrustServerCertificate=True;Connect Timeout=15')
            try {
                $connection.Open(); $command=$connection.CreateCommand(); $command.CommandText=$Query; $command.CommandTimeout=$TimeoutSeconds
                $reader=$command.ExecuteReader()
                do { while($reader.Read()) { $row=[ordered]@{}; for($i=0;$i -lt $reader.FieldCount;$i++){$row[$reader.GetName($i)] = if($reader.IsDBNull($i)){$null}else{$reader.GetValue($i)}}; [pscustomobject]$row } } while($reader.NextResult())
            } finally { $connection.Dispose() }
        }
    }
    $hostName = if ($Context.Provider -eq 'podman') { Resolve-PodmanWindowsHostName -StateRoot $Context.StateRoot } else { '127.0.0.1' }
    $builder=[Data.SqlClient.SqlConnectionStringBuilder]::new(); $builder['Data Source']="$hostName,$($Context.Container.CurrentPort)"
    $builder['Encrypt']=$true; $builder['TrustServerCertificate']=$true; $builder['Connect Timeout']=15
    $secret=$Context.SaPassword.Copy(); $secret.MakeReadOnly()
    $connection=[Data.SqlClient.SqlConnection]::new($builder.ConnectionString,[Data.SqlClient.SqlCredential]::new('sa',$secret))
    try { $connection.Open(); @(Invoke-LabTransferSqlRows -Connection $connection -Query $Query -TimeoutSeconds $TimeoutSeconds) }
    finally { $connection.Dispose(); $secret.Dispose() }
}

function Get-LabSqlFeatureObservation {
    [CmdletBinding()]
    param($Context,[int]$WaitSeconds=0)
    $deadline=[datetime]::UtcNow.AddSeconds($WaitSeconds)
    do {
        try {
            $rows=@(Invoke-LabSqlFeatureSql -Context $Context -Query @'
SELECT CONVERT(int,FULLTEXTSERVICEPROPERTY('IsFullTextInstalled')) AS FullText,
       CONVERT(int,SERVERPROPERTY('FilestreamEffectiveLevel')) AS FileStream,
       CONVERT(varchar(32),SERVERPROPERTY('ProductVersion')) AS Build;
'@)
            if ($rows.Count -ne 1 -or $null -eq $rows[0].FullText -or $rows[0].FullText -notin @(0,1) -or [string]$rows[0].Build -notmatch '^\d+\.\d+\.\d+\.\d+$') { throw 'SQL_FEATURE_OBSERVATION_UNKNOWN' }
            if($Context.Provider -eq 'hyperv' -and ($null -eq $rows[0].FileStream -or [int]$rows[0].FileStream -notin @(0,1,2,3))){throw 'SQL_FEATURE_OBSERVATION_UNKNOWN'}
            if($Context.Provider -in @('docker','podman') -and $null -eq $rows[0].FileStream){$rows[0].FileStream=0}
            $expectedMajor=@{'2019'=15;'2022'=16;'2025'=17}[([string]$Context.SqlVersion -split '-')[0]]
            if(-not $expectedMajor -or [int]($rows[0].Build -split '\.')[0] -ne $expectedMajor){throw 'SQL_FEATURE_ENGINE_VERSION_MISMATCH'}
            return $rows[0]
        } catch {if([datetime]::UtcNow -ge $deadline){throw};Start-Sleep -Seconds 2}
    } while([datetime]::UtcNow -lt $deadline)
    throw 'SQL_FEATURE_OBSERVATION_UNAVAILABLE'
}

function Assert-LabSqlFeatureRemovalSafe {
    [CmdletBinding()]
    param($Context,[ValidateSet('FullText','FileStream')][string]$Feature)
    $predicate = if ($Feature -eq 'FullText') { 'EXISTS(SELECT 1 FROM sys.fulltext_catalogs)' } else { 'EXISTS(SELECT 1 FROM sys.database_files WHERE type=2) OR EXISTS(SELECT 1 FROM sys.columns WHERE is_filestream=1)' }
    $query = @'
SET NOCOUNT ON;
IF ISNULL(IS_SRVROLEMEMBER(N'sysadmin'),0)<>1
    THROW 51000,'SQL_FEATURE_SYSADMIN_REQUIRED',1;
IF EXISTS(SELECT 1 FROM sys.databases WHERE database_id<>2 AND (state<>0 OR ISNULL(HAS_DBACCESS(name),0)<>1))
    THROW 51000,'SQL_FEATURE_DATABASE_INVENTORY_UNAVAILABLE',1;
DECLARE @db sysname,@sql nvarchar(max);
DECLARE dbs CURSOR LOCAL FAST_FORWARD FOR SELECT name FROM sys.databases WHERE database_id<>2;
OPEN dbs; FETCH NEXT FROM dbs INTO @db;
WHILE @@FETCH_STATUS=0 BEGIN
    SET @sql=N'USE '+QUOTENAME(@db)+N'; IF (__PREDICATE__) THROW 51000,''SQL_FEATURE_DEPENDENCIES_EXIST'',1;';
    EXEC sys.sp_executesql @sql;
    FETCH NEXT FROM dbs INTO @db;
END;
CLOSE dbs; DEALLOCATE dbs;
'@
    $null=Invoke-LabSqlFeatureSql -Context $Context -Query ($query.Replace('__PREDICATE__',$predicate))
}

function Invoke-LabContainerFullTextChange {
    [CmdletBinding()]
    param($Context,[bool]$Enabled)
    $observation=Get-LabSqlFeatureObservation -Context $Context
    if([string]$observation.Build -notmatch '^\d+\.\d+\.\d+\.\d+$'){throw 'SQL_FEATURE_ENGINE_BUILD_UNKNOWN'}
    $year=([string]$Context.SqlVersion -split '-')[0]
    $scriptText=(Get-Content -LiteralPath (Join-Path $script:ModuleRoot 'Tools/Set-SqlServerLabFullText.sh') -Raw).Replace("`r`n","`n")
    $result=Invoke-LabContainerRuntimeCommand -Provider $Context.Provider -StateRoot $Context.StateRoot -RunId $Context.RunId `
        -ArgumentList @('exec','--user','0:0',$Context.RuntimeId,'/bin/sh','-c',$scriptText,'sql-lab-fulltext',$(if($Enabled){'on'}else{'off'}),[string]$observation.Build,$year) -NativeResult -TimeoutSeconds 600 -Phase ImageBuild
    if ($result.ExitCode -ne 0) {
        $directory=Join-Path (Join-Path (Join-Path $Context.StateRoot 'runs') $Context.RunId) 'diagnostics'
        $null=New-Item -ItemType Directory -Force -Path $directory
        @($result.Output)|Set-Content -LiteralPath (Join-Path $directory 'sql-feature-package.private.log')
        throw 'SQL_FEATURE_PACKAGE_CHANGE_FAILED'
    }
    foreach ($restartArguments in @(@('stop','--time','60',$Context.RuntimeId),@('start',$Context.RuntimeId))) {
        $result=Invoke-LabContainerRuntimeCommand -Provider $Context.Provider -StateRoot $Context.StateRoot -RunId $Context.RunId -ArgumentList $restartArguments -NativeResult -TimeoutSeconds 90
        if ($result.ExitCode -ne 0) { throw 'SQL_FEATURE_CONTAINER_RESTART_FAILED' }
    }
    $ready=Wait-SqlReady -HostName $(if($Context.Provider -eq 'podman'){Resolve-PodmanWindowsHostName -StateRoot $Context.StateRoot}else{'127.0.0.1'}) `
        -Port $Context.Container.CurrentPort -SaPassword $Context.SaPassword -Provider $Context.Provider -ContainerIdOrName $Context.RuntimeId -StateRoot $Context.StateRoot -TimeoutSeconds 180
    if (-not $ready.Ready) { throw 'SQL_FEATURE_SQL_RESTART_FAILED' }
}

function Invoke-LabInitialSqlFeatures {
    [CmdletBinding()]
    param([object[]]$Instances,[string]$RunId,[string]$StateRoot,[securestring]$SaPassword)
    foreach($instance in $Instances){
        if($instance.sqlFeatures){
            foreach($property in $instance.sqlFeatures.PSObject.Properties){
                $feature=if($property.Name -ceq 'fullText'){'FullText'}else{'FileStream'}
                $null=Set-SqlServerLabFeature -RunId $RunId -InstanceId $instance.id -Feature $feature -Enabled $property.Value -StateRoot $StateRoot -SaPassword $SaPassword -Confirm:$false
            }
        }
    }
}

function Invoke-LabInitialContainerSqlFeatures {
    [CmdletBinding()]
    param($Instance,$RunState,$Container,[securestring]$SaPassword)
    if(-not $Instance.sqlFeatures){return}
    $context=[pscustomobject]@{
        Provider=[string]$Container.Provider;StateRoot=$RunState.StateRoot;RunId=[string]$RunState.RunId
        Run=$RunState;RuntimeId=[string]$Container.ContainerId;SaPassword=$SaPassword;Instance=$Instance;SqlVersion=[string]$Instance.version
        Container=[pscustomobject]@{CurrentPort=[int]$Container.Port}
    }
    $before=Get-LabSqlFeatureObservation -Context $context
    if($Instance.sqlFeatures.PSObject.Properties['fullText'] -and ([bool]$before.FullText -ne [bool]$Instance.sqlFeatures.fullText)){
        if(-not $Instance.sqlFeatures.fullText){Assert-LabSqlFeatureRemovalSafe -Context $context -Feature FullText}
        Invoke-LabContainerFullTextChange -Context $context -Enabled $Instance.sqlFeatures.fullText
        $after=Get-LabSqlFeatureObservation -Context $context
        if([bool]$after.FullText -ne [bool]$Instance.sqlFeatures.fullText -or $after.Build -cne $before.Build){throw 'SQL_FEATURE_POSTCONDITION_FAILED'}
    }
}
