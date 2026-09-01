<#
.SYNOPSIS
    Plant und repariert SQL-Instanzkonfiguration eines Hyper-V-Runs.
.DESCRIPTION
    Der read-only Plan vergleicht den persistierten serverConfig-Sollzustand
    ueber PowerShell Direct mit sys.configurations und global aktiven Trace
    Flags. Dynamische Werte und additive Trace Flags werden live angewendet;
    nicht dynamische Werte verwenden einen eng begrenzten Neustart genau des
    SQL-Standardinstanzdiensts. Der Executor bindet jede Mutation an Run,
    Scope, Instanz und VM und setzt unvollstaendige Operationen aus einem
    lokalen Journal idempotent fort. SQL-Port, TempDB-Dateipfade und
    Datenbanken sind absichtlich nicht Teil dieses Vertrags.
#>

function Get-LabHyperVSqlConfigurationReconcileJournalPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunDirectory)
    Join-Path $RunDirectory 'hyperv-sql-configuration-reconcile.local.journal.json'
}

function Assert-LabHyperVSqlConfigurationReconcileJournal {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Journal)
    $schemaPath = Join-Path $script:SchemasPath 'hyperv-sql-configuration-reconcile-journal.schema.json'
    if (-not (($Journal | ConvertTo-Json -Depth 30) | Test-Json -SchemaFile $schemaPath -ErrorAction SilentlyContinue)) {
        throw 'HYPERV_SQL_CONFIGURATION_RECONCILE_JOURNAL_SCHEMA_INVALID'
    }
    return $true
}

function Write-LabHyperVSqlConfigurationReconcileJournal {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Journal, [Parameter(Mandatory)][string]$Path)
    $Journal.UpdatedAt = Get-LabTimestamp
    $null = Assert-LabHyperVSqlConfigurationReconcileJournal -Journal $Journal
    Write-LabArtifactJsonAtomic -Path $Path -InputObject $Journal
    return $Journal
}

function Set-LabHyperVSqlConfigurationReconcileJournalStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Journal,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidateSet('PREPARED','CONFIGURATION_APPLIED','SERVICE_RESTARTED','VERIFIED','COMPLETED','RECOVERY_REQUIRED')][string]$Status,
        [string]$ErrorCode
    )
    $Journal.Status = $Status
    if ($ErrorCode) {
        $Journal.Recovery.ErrorCode = $ErrorCode
        $Journal.Recovery.Errors = @($Journal.Recovery.Errors) + @($ErrorCode)
    }
    if ($Status -eq 'COMPLETED') { $Journal.Recovery.Status = 'NOT_REQUIRED' }
    elseif ($Status -eq 'RECOVERY_REQUIRED') { $Journal.Recovery.Status = 'RETRY_SQL_CONFIGURATION_RECONCILE' }
    return Write-LabHyperVSqlConfigurationReconcileJournal -Journal $Journal -Path $Path
}

function Get-LabHyperVSqlConfigurationReconcileCredentials {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunDirectory)

    $guestPassword = Get-LabSecret -Path $RunDirectory -Name 'guest-administrator-password'
    $saPassword = Get-LabSecret -Path $RunDirectory -Name 'generated-sql-sa-password'
    if (-not $saPassword) { $saPassword = Get-LabSecret -Path $RunDirectory -Name 'sa-password' }
    if (-not $guestPassword -or -not $saPassword) { throw 'HYPERV_SQL_CONFIGURATION_RECONCILE_CREDENTIAL_REQUIRED' }
    [PSCustomObject]@{
        GuestCredential = [PSCredential]::new('Administrator', $guestPassword)
        SqlSaPassword = $saPassword
    }
}

function Get-LabHyperVSqlConfigurationReconcileContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$InstanceId,
        [string]$StateRoot
    )

    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
    $run = Get-LabRunState -RunId $RunId -StateRoot $StateRoot
    if ([string]$run.metadata.workflowKind -ne 'hyperv-lab') { throw 'HYPERV_SQL_CONFIGURATION_RECONCILE_HYPERV_RUN_REQUIRED' }
    $guard = Get-LabHyperVResourceMigrationLifecycleGuard -RunId $RunId -StateRoot $StateRoot
    if (-not $guard.Allowed) { throw "HYPERV_SQL_CONFIGURATION_RECONCILE_MIGRATION_BLOCKED: $([string]$guard.ReasonCode)" }
    $targetState = if ([string]$run.state -eq 'STOPPED') { 'STOPPED' } else { 'RUNNING' }
    $desiredState = New-LabDesiredState -Run $run -TargetState $targetState -StateRoot $StateRoot
    if (-not $desiredState.IsValid) { throw 'HYPERV_SQL_CONFIGURATION_RECONCILE_DESIRED_STATE_INVALID' }
    $desiredInstances = @($desiredState.Instances | Where-Object { [string]$_.Id -eq $InstanceId -and [string]$_.Provider -eq 'hyperv' })
    if ($desiredInstances.Count -ne 1) { throw 'HYPERV_SQL_CONFIGURATION_RECONCILE_INSTANCE_NOT_UNIQUE' }
    $desired = $desiredInstances[0].SqlConfiguration
    if (-not $desired -or -not $desired.Contract -or
        [string]$desired.Contract.Name -ne 'SqlServerLab.SqlConfigurationIntent' -or
        [string]$desired.Contract.Version -ne '1.0') {
        throw 'HYPERV_SQL_CONFIGURATION_RECONCILE_INTENT_MISSING'
    }
    if ([string]$desired.CapabilityStatus -ne 'DECLARED_SUPPORTED') { throw 'HYPERV_SQL_CONFIGURATION_RECONCILE_INTENT_UNSUPPORTED' }
    foreach ($item in @($desired.Configurations)) {
        if ([string]::IsNullOrWhiteSpace([string]$item.Name) -or [string]$item.Name -notmatch '^[A-Za-z0-9 ()_-]+$') {
            throw 'HYPERV_SQL_CONFIGURATION_RECONCILE_TARGET_INVALID'
        }
        $null = [long]$item.Value
    }
    if (@($desired.TraceFlags | Where-Object { [int]$_ -le 0 }).Count -gt 0) {
        throw 'HYPERV_SQL_CONFIGURATION_RECONCILE_TRACE_FLAG_INVALID'
    }

    $runDirectory = Join-Path (Join-Path $StateRoot 'runs') $RunId
    $connectionPath = Join-Path $runDirectory 'connection-info.json'
    if (-not (Test-Path -LiteralPath $connectionPath -PathType Leaf)) { throw 'HYPERV_SQL_CONFIGURATION_RECONCILE_CONNECTION_MISSING' }
    $connection = Get-Content -LiteralPath $connectionPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 30
    $instances = @($connection.instances | Where-Object { [string]$_.id -eq $InstanceId -and [string]$_.provider -eq 'hyperv' })
    if ($instances.Count -ne 1 -or [string]::IsNullOrWhiteSpace([string]$instances[0].vmName)) {
        throw 'HYPERV_SQL_CONFIGURATION_RECONCILE_CONNECTION_INSTANCE_NOT_UNIQUE'
    }
    $managed = Get-HyperVManagedVM -VMName ([string]$instances[0].vmName) `
        -ExpectedRunId $RunId -ExpectedScopeId ([string]$run.scopeId)
    if (-not $managed) { throw 'HYPERV_SQL_CONFIGURATION_RECONCILE_VM_NOT_FOUND' }
    if ($instances[0].vmId -and [string]$instances[0].vmId -ne [string]$managed.VM.Id) {
        throw 'HYPERV_SQL_CONFIGURATION_RECONCILE_VM_IDENTITY_MISMATCH'
    }
    if ([string]$managed.VM.State -ne 'Running') { throw 'HYPERV_SQL_CONFIGURATION_RECONCILE_VM_RUNNING_REQUIRED' }
    $secretDirectory = Join-Path $runDirectory 'secrets'
    $credentialAvailable = (Test-Path -LiteralPath (Join-Path $secretDirectory 'guest-administrator-password.secret') -PathType Leaf) -and
        ((Test-Path -LiteralPath (Join-Path $secretDirectory 'generated-sql-sa-password.secret') -PathType Leaf) -or
         (Test-Path -LiteralPath (Join-Path $secretDirectory 'sa-password.secret') -PathType Leaf))
    [PSCustomObject]@{
        RunId=$RunId; ScopeId=[string]$run.scopeId; InstanceId=$InstanceId; StateRoot=$StateRoot
        RunDirectory=$runDirectory; ConnectionInstance=$instances[0]; Managed=$managed; VM=$managed.VM
        Desired=$desired; CredentialAvailable=[bool]$credentialAvailable
    }
}

function Get-LabHyperVSqlConfigurationActualState {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)]$Access)

    $names = @($Context.Desired.Configurations | ForEach-Object { [string]$_.Name })
    $result = Invoke-HyperVPowerShellDirect -VMName ([string]$Context.ConnectionInstance.vmName) `
        -ExpectedRunId ([string]$Context.RunId) -ExpectedScopeId ([string]$Context.ScopeId) `
        -Credential $Access.GuestCredential -ArgumentList @($Access.SqlSaPassword, $names) -ScriptBlock {
        param($SqlSecret, $ConfigurationNames)
        $ErrorActionPreference = 'Stop'
        Add-Type -AssemblyName System.Data
        $services = @(Get-Service -Name 'MSSQLSERVER' -ErrorAction SilentlyContinue)
        if ($services.Count -ne 1) { throw 'HYPERV_SQL_CONFIGURATION_RECONCILE_DEFAULT_INSTANCE_NOT_UNIQUE' }
        if ([string]$services[0].Status -ne 'Running') { throw 'HYPERV_SQL_CONFIGURATION_RECONCILE_SERVICE_RUNNING_REQUIRED' }
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SqlSecret)
        $plain = $null
        try {
            $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
            $builder = [Data.SqlClient.SqlConnectionStringBuilder]::new()
            $builder['Data Source']='localhost'; $builder['Initial Catalog']='master'; $builder['User ID']='sa'
            $builder['Password']=$plain; $builder['Encrypt']=$true; $builder['TrustServerCertificate']=$true; $builder['Connect Timeout']=30
            $connection = [Data.SqlClient.SqlConnection]::new($builder.ConnectionString)
            try {
                $connection.Open()
                $command = $connection.CreateCommand(); $command.CommandTimeout=30
                $command.CommandText="SELECT CONVERT(nvarchar(128),SERVERPROPERTY('InstanceName'));"
                $instanceName=$command.ExecuteScalar()
                if ($null -ne $instanceName -and $instanceName -isnot [DBNull] -and -not [string]::IsNullOrWhiteSpace([string]$instanceName)) {
                    throw 'HYPERV_SQL_CONFIGURATION_RECONCILE_DEFAULT_INSTANCE_NOT_UNIQUE'
                }
                $command.CommandText='SELECT name,CAST(value_in_use AS bigint),CAST(value AS bigint),CAST(is_dynamic AS int) FROM sys.configurations;'
                $reader=$command.ExecuteReader(); $all=@()
                while($reader.Read()) {
                    $all += [PSCustomObject]@{
                        Name=[string]$reader.GetString(0)
                        ValueInUse=[Convert]::ToInt64($reader.GetValue(1),[Globalization.CultureInfo]::InvariantCulture)
                        ConfiguredValue=[Convert]::ToInt64($reader.GetValue(2),[Globalization.CultureInfo]::InvariantCulture)
                        IsDynamic=[Convert]::ToInt32($reader.GetValue(3),[Globalization.CultureInfo]::InvariantCulture) -eq 1
                    }
                }
                $reader.Dispose()
                $requested = @($ConfigurationNames | ForEach-Object { [string]$_ })
                $configurations = @($all | Where-Object { [string]$_.Name -in $requested })
                $command=$connection.CreateCommand(); $command.CommandTimeout=30
                $command.CommandText='DBCC TRACESTATUS(-1) WITH NO_INFOMSGS;'
                $table=[Data.DataTable]::new(); $reader=$command.ExecuteReader(); $table.Load($reader); $reader.Dispose()
                $traceFlags=@($table.Rows | Where-Object { [int]$_.Global -eq 1 -and [int]$_.Status -eq 1 } | ForEach-Object { [int]$_.TraceFlag })
                [PSCustomObject]@{
                    Status='AVAILABLE';ServiceName='MSSQLSERVER';ServiceStatus='Running'
                    Configurations=$configurations;TraceFlags=$traceFlags;ObservedAt=[datetime]::UtcNow.ToString('o')
                }
            }
            finally { $connection.Dispose() }
        }
        finally { $plain=$null; [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    }
    $actual = @($result)[-1]
    if (-not $actual -or [string]$actual.Status -ne 'AVAILABLE') { throw 'HYPERV_SQL_CONFIGURATION_RECONCILE_ACTUAL_UNAVAILABLE' }
    return $actual
}

function Get-LabHyperVSqlConfigurationReconcileDiff {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Desired, [Parameter(Mandatory)]$Actual)

    $diff = [Collections.Generic.List[object]]::new()
    foreach ($target in @($Desired.Configurations)) {
        $configurationMatches = @($Actual.Configurations | Where-Object { [string]$_.Name -ieq [string]$target.Name })
        if ($configurationMatches.Count -ne 1) {
            $diff.Add([PSCustomObject]@{
                Kind='configuration-missing';Name=[string]$target.Name;Desired=[long]$target.Value;Actual=$null
                Supported=$false;ChangeClass='unsupported';RequiresApply=$false;RequiresServiceRestart=$false
            })
            continue
        }
        $current = $configurationMatches[0]
        if ([long]$current.ValueInUse -ne [long]$target.Value) {
            $isDynamic = [bool]$current.IsDynamic
            $configuredMatches = [long]$current.ConfiguredValue -eq [long]$target.Value
            $kind = if ($isDynamic) { 'configuration' } elseif ($configuredMatches) { 'configuration-restart-pending' } else { 'configuration-restart' }
            $diff.Add([PSCustomObject]@{
                Kind=$kind;Name=[string]$target.Name;Desired=[long]$target.Value;Actual=[long]$current.ValueInUse
                Supported=$true;ChangeClass=if($isDynamic){'live'}else{'restart'}
                RequiresApply=($isDynamic -or -not $configuredMatches);RequiresServiceRestart=(-not $isDynamic)
            })
        }
    }
    foreach ($traceFlag in @($Desired.TraceFlags | Sort-Object -Unique)) {
        if (@($Actual.TraceFlags) -notcontains [int]$traceFlag) {
            $diff.Add([PSCustomObject]@{
                Kind='trace-flag-add';Name="trace-flag-$traceFlag";Desired=1;Actual=0
                Supported=$true;ChangeClass='live';RequiresApply=$true;RequiresServiceRestart=$false
            })
        }
    }
    return @($diff)
}

function Read-LabHyperVSqlConfigurationReconcileJournal {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Context)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $journal = Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json -Depth 30
    $null = Assert-LabHyperVSqlConfigurationReconcileJournal -Journal $journal
    if ([string]$journal.RunId -ne [string]$Context.RunId -or [string]$journal.ScopeId -ne [string]$Context.ScopeId -or
        [string]$journal.InstanceId -ne [string]$Context.InstanceId -or [string]$journal.Runtime.VMId -ne [string]$Context.VM.Id) {
        throw 'HYPERV_SQL_CONFIGURATION_RECONCILE_JOURNAL_IDENTITY_MISMATCH'
    }
    $expectedTarget = [PSCustomObject]@{
        Configurations=@($Context.Desired.Configurations | Sort-Object Name | ForEach-Object { [PSCustomObject]@{Name=[string]$_.Name;Value=[long]$_.Value} })
        TraceFlags=@($Context.Desired.TraceFlags | ForEach-Object {[int]$_} | Sort-Object -Unique)
    }
    if (($journal.Target | ConvertTo-Json -Depth 10 -Compress) -cne ($expectedTarget | ConvertTo-Json -Depth 10 -Compress)) {
        if ([string]$journal.Status -eq 'COMPLETED') { return $null }
        throw 'HYPERV_SQL_CONFIGURATION_RECONCILE_JOURNAL_TARGET_MISMATCH'
    }
    if ($journal.Runtime.PSObject.Properties.Name -contains 'ServiceName' -and [string]$journal.Runtime.ServiceName -ne 'MSSQLSERVER') {
        throw 'HYPERV_SQL_CONFIGURATION_RECONCILE_JOURNAL_SQL_IDENTITY_MISMATCH'
    }
    return $journal
}

function New-LabHyperVSqlConfigurationReconcilePlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunId, [Parameter(Mandatory)][string]$InstanceId, [string]$StateRoot)
    try {
        $context=Get-LabHyperVSqlConfigurationReconcileContext -RunId $RunId -InstanceId $InstanceId -StateRoot $StateRoot
        if(-not $context.CredentialAvailable){throw 'HYPERV_SQL_CONFIGURATION_RECONCILE_CREDENTIAL_REQUIRED'}
        $credentials=Get-LabHyperVSqlConfigurationReconcileCredentials -RunDirectory $context.RunDirectory
        $actual=Get-LabHyperVSqlConfigurationActualState -Context $context -Access $credentials
        $journalPath=Get-LabHyperVSqlConfigurationReconcileJournalPath -RunDirectory $context.RunDirectory
        $journal=Read-LabHyperVSqlConfigurationReconcileJournal -Path $journalPath -Context $context
    }
    catch {
        $code=if($_.Exception.Message -cmatch '[A-Z][A-Z0-9_]{5,127}'){[string]$Matches[0]}else{'HYPERV_SQL_CONFIGURATION_RECONCILE_UNAVAILABLE'}
        return [PSCustomObject]@{
            Contract=[PSCustomObject]@{Name='SqlServerLab.HyperVSqlConfigurationReconcilePlan';Version='1.0'}
            RunId=$RunId;InstanceId=$InstanceId;Provider='hyperv';Desired=[PSCustomObject]@{ConfigurationCount=0;TraceFlagCount=0}
            Actual=[PSCustomObject]@{Status='UNAVAILABLE';ConfigurationCount=0;ActiveDesiredTraceFlagCount=0}
            Diff=@();Actions=@();HighestChangeClass='unsupported';IsNoOp=$false;MutationAllowed=$false
            Warnings=@('Der SQL-Konfigurationszustand ist nicht eindeutig steuerbar.');ReasonCodes=@($code)
        }
    }
    $diff=@(Get-LabHyperVSqlConfigurationReconcileDiff -Desired $context.Desired -Actual $actual)
    $unsupported=@($diff | Where-Object {-not $_.Supported})
    $recoveryPending=$journal -and [string]$journal.Status -ne 'COMPLETED'
    $restartRequired=@($diff | Where-Object {$_.Supported -and [bool]$_.RequiresServiceRestart}).Count -gt 0
    $changeClass=if($unsupported.Count){
        'unsupported'
    }elseif($restartRequired -or ($recoveryPending -and [string]$journal.ChangeClass -eq 'restart')){
        'restart'
    }elseif($diff.Count -or $recoveryPending){
        'live'
    }else{
        'no-op'
    }
    $repairKinds=@($diff | Where-Object Supported | ForEach-Object { [string]$_.Kind } | Sort-Object -Unique)
    if($recoveryPending -and $diff.Count -eq 0){$repairKinds=@('recovery-finalize')}
    $actions=if($changeClass -in @('live','restart')){
        @([PSCustomObject]@{
            Operation=if($recoveryPending){'ResumeHyperVSqlConfiguration'}else{'RepairHyperVSqlConfiguration'}
            ChangeClass=$changeClass;RepairKinds=$repairKinds;RequiresRestart=[bool]$restartRequired
            RequiresServiceRestart=[bool]$restartRequired;RequiresVmRestart=$false;RecoveryPending=[bool]$recoveryPending
        })
    }else{@()}
    [PSCustomObject]@{
        Contract=[PSCustomObject]@{Name='SqlServerLab.HyperVSqlConfigurationReconcilePlan';Version='1.0'}
        RunId=$RunId;InstanceId=$InstanceId;Provider='hyperv'
        Desired=[PSCustomObject]@{ConfigurationCount=@($context.Desired.Configurations).Count;TraceFlagCount=@($context.Desired.TraceFlags).Count}
        Actual=[PSCustomObject]@{Status='AVAILABLE';ConfigurationCount=@($actual.Configurations).Count;ActiveDesiredTraceFlagCount=@($context.Desired.TraceFlags | Where-Object {@($actual.TraceFlags) -contains [int]$_}).Count}
        Diff=@($diff | ForEach-Object {[PSCustomObject]@{
            Kind=[string]$_.Kind;Name=[string]$_.Name;Desired=$_.Desired;Actual=$_.Actual;ChangeClass=[string]$_.ChangeClass
        }})
        Actions=$actions;HighestChangeClass=$changeClass;IsNoOp=($changeClass -eq 'no-op');MutationAllowed=$false
        Warnings=if($unsupported.Count){
            @('Fehlende oder mehrdeutige SQL-Konfiguration wird nicht teilweise mutiert.')
        }elseif($changeClass -eq 'restart'){
            @('Die Reparatur startet ausschliesslich den SQL-Dienst neu; die Hyper-V-VM bleibt gestartet.')
        }elseif($changeClass -eq 'live'){
            @('Die Reparatur ist online; SQL-Dienst und Hyper-V-VM bleiben gestartet.')
        }else{@()}
        ReasonCodes=@($(if($recoveryPending){'HYPERV_SQL_CONFIGURATION_RECONCILE_RECOVERY_PENDING'});$(if($unsupported.Count){'HYPERV_SQL_CONFIGURATION_RECONCILE_UNSUPPORTED'}))
    }
}

function Set-LabHyperVSqlConfigurationValues {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)]$Access,
        [bool]$ApplyConfigurations=$true,
        [bool]$ApplyTraceFlags=$true
    )

    $configurations=@($Context.Desired.Configurations | Sort-Object Name | ForEach-Object {[PSCustomObject]@{Name=[string]$_.Name;Value=[long]$_.Value}})
    $traceFlags=@($Context.Desired.TraceFlags | ForEach-Object {[int]$_} | Sort-Object -Unique)
    foreach($flag in $traceFlags){if($flag -le 0){throw 'HYPERV_SQL_CONFIGURATION_RECONCILE_TRACE_FLAG_INVALID'}}
    $null=Invoke-HyperVPowerShellDirect -VMName ([string]$Context.ConnectionInstance.vmName) `
        -ExpectedRunId ([string]$Context.RunId) -ExpectedScopeId ([string]$Context.ScopeId) `
        -Credential $Access.GuestCredential -ArgumentList @($Access.SqlSaPassword,$configurations,$traceFlags,$ApplyConfigurations,$ApplyTraceFlags) -ScriptBlock {
        param($SqlSecret,$Configurations,$TraceFlags,$ApplyConfigurations,$ApplyTraceFlags)
        $ErrorActionPreference='Stop';Add-Type -AssemblyName System.Data
        $bstr=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($SqlSecret);$plain=$null
        try{
            $plain=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
            $builder=[Data.SqlClient.SqlConnectionStringBuilder]::new();$builder['Data Source']='localhost';$builder['Initial Catalog']='master';$builder['User ID']='sa'
            $builder['Password']=$plain;$builder['Encrypt']=$true;$builder['TrustServerCertificate']=$true;$builder['Connect Timeout']=30
            $connection=[Data.SqlClient.SqlConnection]::new($builder.ConnectionString)
            try{
                $connection.Open()
                if($ApplyConfigurations -and @($Configurations).Count -gt 0){
                    $command=$connection.CreateCommand();$command.CommandTimeout=30
                    $command.CommandText="EXEC sys.sp_configure N'show advanced options',1;RECONFIGURE;";$null=$command.ExecuteNonQuery()
                }
                foreach($item in $(if($ApplyConfigurations){@($Configurations)}else{@()})){
                    $name=[string]$item.Name;$value=[long]$item.Value
                    if($name -notmatch '^[A-Za-z0-9 ()_-]+$'){throw 'HYPERV_SQL_CONFIGURATION_RECONCILE_TARGET_INVALID'}
                    $probe=$connection.CreateCommand();$probe.CommandText='SELECT COUNT_BIG(*) FROM sys.configurations WHERE name=@name;'
                    $null=$probe.Parameters.Add('@name',[Data.SqlDbType]::NVarChar,128);$probe.Parameters['@name'].Value=$name
                    $count=$probe.ExecuteScalar();if($null -eq $count -or $count -is [DBNull] -or [long]$count -ne 1){throw 'HYPERV_SQL_CONFIGURATION_RECONCILE_TARGET_NOT_UNIQUE'}
                    $command=$connection.CreateCommand();$command.CommandTimeout=30
                    $command.CommandText='EXEC sys.sp_configure @name,@value;RECONFIGURE;'
                    $null=$command.Parameters.Add('@name',[Data.SqlDbType]::NVarChar,128);$command.Parameters['@name'].Value=$name
                    $null=$command.Parameters.Add('@value',[Data.SqlDbType]::BigInt);$command.Parameters['@value'].Value=$value
                    $null=$command.ExecuteNonQuery()
                }
                $flags=@($TraceFlags | ForEach-Object {[int]$_} | Sort-Object -Unique)
                if($ApplyTraceFlags -and $flags.Count -gt 0){
                    if(@($flags | Where-Object {$_ -le 0}).Count){throw 'HYPERV_SQL_CONFIGURATION_RECONCILE_TRACE_FLAG_INVALID'}
                    $command=$connection.CreateCommand();$command.CommandTimeout=30
                    $command.CommandText="DBCC TRACEON ($($flags -join ', '), -1) WITH NO_INFOMSGS;";$null=$command.ExecuteNonQuery()
                }
            }finally{$connection.Dispose()}
        }finally{$plain=$null;[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)}
    }
}

function Invoke-LabHyperVSqlConfigurationServiceRestart {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)]$Access)

    $receipt=Invoke-HyperVPowerShellDirect -VMName ([string]$Context.ConnectionInstance.vmName) `
        -ExpectedRunId ([string]$Context.RunId) -ExpectedScopeId ([string]$Context.ScopeId) `
        -Credential $Access.GuestCredential -ArgumentList @($Access.SqlSaPassword) -ScriptBlock {
        param($SqlSecret)
        $ErrorActionPreference='Stop'
        $services=@(Get-Service -Name 'MSSQLSERVER' -ErrorAction SilentlyContinue)
        if($services.Count -ne 1){throw 'HYPERV_SQL_CONFIGURATION_RECONCILE_DEFAULT_INSTANCE_NOT_UNIQUE'}
        if([string]$services[0].Status -ne 'Running'){throw 'HYPERV_SQL_CONFIGURATION_RECONCILE_SERVICE_RUNNING_REQUIRED'}
        Restart-Service -Name 'MSSQLSERVER' -ErrorAction Stop
        $service=Get-Service -Name 'MSSQLSERVER' -ErrorAction Stop
        $service.WaitForStatus([ServiceProcess.ServiceControllerStatus]::Running,[TimeSpan]::FromSeconds(120))
        Add-Type -AssemblyName System.Data
        $bstr=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($SqlSecret);$plain=$null
        try{
            $plain=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
            $builder=[Data.SqlClient.SqlConnectionStringBuilder]::new();$builder['Data Source']='localhost';$builder['Initial Catalog']='master';$builder['User ID']='sa'
            $builder['Password']=$plain;$builder['Encrypt']=$true;$builder['TrustServerCertificate']=$true;$builder['Connect Timeout']=30
            $connection=[Data.SqlClient.SqlConnection]::new($builder.ConnectionString)
            try{
                $connection.Open();$command=$connection.CreateCommand();$command.CommandTimeout=30
                $command.CommandText="SELECT DB_NAME(),CONVERT(nvarchar(128),SERVERPROPERTY('InstanceName'));"
                $reader=$command.ExecuteReader()
                if(-not $reader.Read() -or [string]$reader.GetString(0) -ne 'master'){throw 'HYPERV_SQL_CONFIGURATION_RECONCILE_SQL_POSTCONDITION_FAILED'}
                if(-not $reader.IsDBNull(1) -and -not [string]::IsNullOrWhiteSpace([string]$reader.GetString(1))){throw 'HYPERV_SQL_CONFIGURATION_RECONCILE_DEFAULT_INSTANCE_NOT_UNIQUE'}
                $reader.Dispose()
            }finally{$connection.Dispose()}
        }finally{$plain=$null;[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)}
        [PSCustomObject]@{Status='RESTARTED';ServiceName='MSSQLSERVER';ServiceStatus='Running';ObservedAt=[datetime]::UtcNow.ToString('o')}
    }
    $receipt=@($receipt)[-1]
    if(-not $receipt -or [string]$receipt.Status -ne 'RESTARTED' -or [string]$receipt.ServiceName -ne 'MSSQLSERVER' -or [string]$receipt.ServiceStatus -ne 'Running'){
        throw 'HYPERV_SQL_CONFIGURATION_RECONCILE_SERVICE_RESTART_FAILED'
    }
    return $receipt
}

function Invoke-LabHyperVSqlConfigurationReconcileRepair {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunId,[Parameter(Mandatory)][string]$InstanceId,[string]$StateRoot)

    $mutex=[Threading.Mutex]::new($false,"Global\SQL_Server_Lab_HyperV_SQL_Configuration_Reconcile_$($RunId.Replace('-',''))")
    $acquired=$false;$journal=$null;$journalPath=$null
    try{
        $acquired=$mutex.WaitOne([TimeSpan]::FromMinutes(5));if(-not $acquired){throw 'HYPERV_SQL_CONFIGURATION_RECONCILE_LOCK_TIMEOUT'}
        $context=Get-LabHyperVSqlConfigurationReconcileContext -RunId $RunId -InstanceId $InstanceId -StateRoot $StateRoot
        $journalPath=Get-LabHyperVSqlConfigurationReconcileJournalPath -RunDirectory $context.RunDirectory
        $journal=Read-LabHyperVSqlConfigurationReconcileJournal -Path $journalPath -Context $context
        $plan=New-LabHyperVSqlConfigurationReconcilePlan -RunId $RunId -InstanceId $InstanceId -StateRoot $context.StateRoot
        if($journal -and [string]$journal.Status -ne 'COMPLETED'){$journal.Recovery.Attempts=[int]$journal.Recovery.Attempts+1}
        elseif($journal -and [string]$journal.Status -eq 'COMPLETED' -and $plan.IsNoOp){return [PSCustomObject]@{Status='NO_OP';RunId=$RunId;InstanceId=$InstanceId;Changed=$false;RepairKinds=@()}}
        elseif($journal -and [string]$journal.Status -eq 'COMPLETED'){$journal=$null}
        if(-not $journal){
            if($plan.IsNoOp){return [PSCustomObject]@{Status='NO_OP';RunId=$RunId;InstanceId=$InstanceId;Changed=$false;RepairKinds=@()}}
            if([string]$plan.HighestChangeClass -notin @('live','restart') -or @($plan.Actions).Count -ne 1){throw 'HYPERV_SQL_CONFIGURATION_RECONCILE_UNSUPPORTED'}
            $journal=[PSCustomObject]@{
                ContractVersion='SqlServerLab.HyperVSqlConfigurationReconcileJournal/1.0';OperationId=[Guid]::NewGuid().ToString('D')
                RunId=$RunId;ScopeId=[string]$context.ScopeId;InstanceId=$InstanceId;Provider='hyperv';ChangeClass=[string]$plan.HighestChangeClass;Status='PREPARED'
                Target=[PSCustomObject]@{
                    Configurations=@($context.Desired.Configurations | Sort-Object Name | ForEach-Object {[PSCustomObject]@{Name=[string]$_.Name;Value=[long]$_.Value}})
                    TraceFlags=@($context.Desired.TraceFlags | ForEach-Object {[int]$_} | Sort-Object -Unique)
                }
                Runtime=[PSCustomObject]@{VMId=[string]$context.VM.Id;ServiceName='MSSQLSERVER'}
                Recovery=[PSCustomObject]@{Status='RETRY_SQL_CONFIGURATION_RECONCILE';Attempts=0;ErrorCode=$null;Errors=@()};UpdatedAt=Get-LabTimestamp
            }
            $null=Write-LabHyperVSqlConfigurationReconcileJournal -Journal $journal -Path $journalPath
        }
        $credentials=Get-LabHyperVSqlConfigurationReconcileCredentials -RunDirectory $context.RunDirectory
        $actual=Get-LabHyperVSqlConfigurationActualState -Context $context -Access $credentials
        $before=@(Get-LabHyperVSqlConfigurationReconcileDiff -Desired $context.Desired -Actual $actual)
        if(@($before | Where-Object {-not $_.Supported}).Count){throw 'HYPERV_SQL_CONFIGURATION_RECONCILE_UNSUPPORTED'}
        $configurationApplyRequired=@($before | Where-Object {$_.Kind -like 'configuration*' -and [bool]$_.RequiresApply}).Count -gt 0
        $traceFlagApplyRequired=@($before | Where-Object {$_.Kind -eq 'trace-flag-add'}).Count -gt 0
        $serviceRestartRequired=@($before | Where-Object {[bool]$_.RequiresServiceRestart}).Count -gt 0
        if($configurationApplyRequired -or ($traceFlagApplyRequired -and -not $serviceRestartRequired)){
            Set-LabHyperVSqlConfigurationValues -Context $context -Access $credentials `
                -ApplyConfigurations $configurationApplyRequired -ApplyTraceFlags ($traceFlagApplyRequired -and -not $serviceRestartRequired)
            $null=Set-LabHyperVSqlConfigurationReconcileJournalStatus -Journal $journal -Path $journalPath -Status CONFIGURATION_APPLIED
        }
        if($serviceRestartRequired){
            $restartReceipt=Invoke-LabHyperVSqlConfigurationServiceRestart -Context $context -Access $credentials
            if([string]$restartReceipt.ServiceStatus -ne 'Running'){throw 'HYPERV_SQL_CONFIGURATION_RECONCILE_SERVICE_RESTART_FAILED'}
            $null=Set-LabHyperVSqlConfigurationReconcileJournalStatus -Journal $journal -Path $journalPath -Status SERVICE_RESTARTED
            if(@($context.Desired.TraceFlags).Count -gt 0){
                Set-LabHyperVSqlConfigurationValues -Context $context -Access $credentials -ApplyConfigurations $false -ApplyTraceFlags $true
            }
        }
        $context=Get-LabHyperVSqlConfigurationReconcileContext -RunId $RunId -InstanceId $InstanceId -StateRoot $context.StateRoot
        $actual=Get-LabHyperVSqlConfigurationActualState -Context $context -Access $credentials
        $remaining=@(Get-LabHyperVSqlConfigurationReconcileDiff -Desired $context.Desired -Actual $actual)
        if($remaining.Count){throw "HYPERV_SQL_CONFIGURATION_RECONCILE_POSTCONDITION_FAILED: $(@($remaining.Name)-join ',')"}
        $null=Set-LabHyperVSqlConfigurationReconcileJournalStatus -Journal $journal -Path $journalPath -Status VERIFIED
        $null=Set-LabHyperVSqlConfigurationReconcileJournalStatus -Journal $journal -Path $journalPath -Status COMPLETED
        [PSCustomObject]@{Status='SUCCEEDED';RunId=$RunId;InstanceId=$InstanceId;Changed=($before.Count -gt 0);RepairKinds=@($before | ForEach-Object { [string]$_.Kind } | Sort-Object -Unique);JournalStatus='COMPLETED'}
    }
    catch{
        $code=if($_.Exception.Message -cmatch '[A-Z][A-Z0-9_]{5,127}'){[string]$Matches[0]}else{'HYPERV_SQL_CONFIGURATION_RECONCILE_FAILED'}
        if($journal -and $journalPath){try{$null=Set-LabHyperVSqlConfigurationReconcileJournalStatus -Journal $journal -Path $journalPath -Status RECOVERY_REQUIRED -ErrorCode $code}catch{}}
        if($journal -and $journalPath){throw "HYPERV_SQL_CONFIGURATION_RECONCILE_RECOVERY_REQUIRED: $code"}
        throw
    }
    finally{if($acquired){try{$mutex.ReleaseMutex()}catch{}};$mutex.Dispose()}
}
