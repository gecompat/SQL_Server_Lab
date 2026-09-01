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

function Get-LabHyperVSqlConfigurationOwnershipPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunDirectory)
    Join-Path $RunDirectory 'hyperv-sql-configuration-ownership.local.json'
}

function Assert-LabHyperVSqlConfigurationOwnershipReceipt {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Receipt)
    $schemaPath=Join-Path $script:SchemasPath 'hyperv-sql-configuration-ownership.schema.json'
    if(-not (($Receipt|ConvertTo-Json -Depth 20)|Test-Json -SchemaFile $schemaPath -ErrorAction SilentlyContinue)){
        throw 'HYPERV_SQL_CONFIGURATION_OWNERSHIP_SCHEMA_INVALID'
    }
    return $true
}

function Write-LabHyperVSqlConfigurationOwnershipReceipt {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Receipt,[Parameter(Mandatory)][string]$Path)
    $Receipt.TraceFlags=@($Receipt.TraceFlags|ForEach-Object{[int]$_}|Sort-Object -Unique)
    if(@($Receipt.TraceFlags|Where-Object{$_ -le 0}).Count){throw 'HYPERV_SQL_CONFIGURATION_OWNERSHIP_TRACE_FLAG_INVALID'}
    $Receipt.UpdatedAt=Get-LabTimestamp
    $null=Assert-LabHyperVSqlConfigurationOwnershipReceipt -Receipt $Receipt
    Write-LabArtifactJsonAtomic -Path $Path -InputObject $Receipt
    return $Receipt
}

function ConvertTo-LabHyperVSqlConfigurationOwnershipReceipt {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$ScopeId,
        [Parameter(Mandatory)][string]$InstanceId,
        [Parameter(Mandatory)][string]$VMId,
        [int[]]$TraceFlags=@()
    )
    return [PSCustomObject]@{
        ContractVersion='SqlServerLab.HyperVSqlConfigurationOwnership/1.0'
        RunId=$RunId;ScopeId=$ScopeId;InstanceId=$InstanceId;Provider='hyperv';VMId=$VMId
        TraceFlags=@($TraceFlags|ForEach-Object{[int]$_}|Sort-Object -Unique);UpdatedAt=Get-LabTimestamp
    }
}

function Read-LabHyperVSqlConfigurationOwnershipReceipt {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)]$Context)
    if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){return $null}
    $receipt=Get-Content -LiteralPath $Path -Raw -Encoding utf8|ConvertFrom-Json -Depth 20
    $null=Assert-LabHyperVSqlConfigurationOwnershipReceipt -Receipt $receipt
    if([string]$receipt.RunId -ne [string]$Context.RunId -or [string]$receipt.ScopeId -ne [string]$Context.ScopeId -or
       [string]$receipt.InstanceId -ne [string]$Context.InstanceId -or [string]$receipt.VMId -ne [string]$Context.VM.Id){
        throw 'HYPERV_SQL_CONFIGURATION_OWNERSHIP_IDENTITY_MISMATCH'
    }
    return $receipt
}

function Initialize-LabHyperVSqlConfigurationOwnershipReceipt {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Lab,[int[]]$TraceFlags=@())
    $path=Get-LabHyperVSqlConfigurationOwnershipPath -RunDirectory ([string]$Lab.RunDirectory)
    $receipt=ConvertTo-LabHyperVSqlConfigurationOwnershipReceipt -RunId ([string]$Lab.Run.runId) `
        -ScopeId ([string]$Lab.Run.scopeId) -InstanceId ([string]$Lab.Instance.id) `
        -VMId ([string]$Lab.Instance.vmId) -TraceFlags $TraceFlags
    if(Test-Path -LiteralPath $path -PathType Leaf){
        $existing=Get-Content -LiteralPath $path -Raw -Encoding utf8|ConvertFrom-Json -Depth 20
        $null=Assert-LabHyperVSqlConfigurationOwnershipReceipt -Receipt $existing
        if([string]$existing.RunId -ne [string]$receipt.RunId -or [string]$existing.ScopeId -ne [string]$receipt.ScopeId -or
           [string]$existing.InstanceId -ne [string]$receipt.InstanceId -or [string]$existing.VMId -ne [string]$receipt.VMId){
            throw 'HYPERV_SQL_CONFIGURATION_OWNERSHIP_IDENTITY_MISMATCH'
        }
    }
    return Write-LabHyperVSqlConfigurationOwnershipReceipt -Receipt $receipt -Path $path
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
        [Parameter(Mandatory)][ValidateSet('PREPARED','CONFIGURATION_APPLIED','TRACE_FLAGS_REMOVED','SERVICE_RESTARTED','VERIFIED','OWNERSHIP_UPDATED','DESIRED_STATE_UPDATED','COMPLETED','RECOVERY_REQUIRED')][string]$Status,
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

function Get-LabHyperVSqlConfigurationInstanceFingerprint {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Instance)
    return [ordered]@{
        Id=[string]$Instance.Id;Provider=[string]$Instance.Provider;Version=[string]$Instance.Version
        Profile=[string]$Instance.Profile;AutoStart=[string]$Instance.AutoStart;DatabaseNames=@($Instance.DatabaseNames)
        Drives=@($Instance.Intents.Drives);Network=$Instance.Intents.Network;Resources=$Instance.Intents.Resources
        SqlEndpoint=$Instance.Intents.SqlEndpoint;Databases=$Instance.Intents.Databases
        Software=$Instance.Intents.Software;Storage=$Instance.Intents.Storage
    }
}

function Get-LabHyperVSqlConfigurationReconcileContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$InstanceId,
        [string]$ManifestPath,
        [string]$StateRoot
    )

    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
    $run = Get-LabRunState -RunId $RunId -StateRoot $StateRoot
    if ([string]$run.metadata.workflowKind -ne 'hyperv-lab') { throw 'HYPERV_SQL_CONFIGURATION_RECONCILE_HYPERV_RUN_REQUIRED' }
    $guard = Get-LabHyperVResourceMigrationLifecycleGuard -RunId $RunId -StateRoot $StateRoot
    if (-not $guard.Allowed) { throw "HYPERV_SQL_CONFIGURATION_RECONCILE_MIGRATION_BLOCKED: $([string]$guard.ReasonCode)" }
    $persisted=Get-LabPersistedDesiredState -RunId $RunId -StateRoot $StateRoot
    if([string]$persisted.Status -ne 'VALID'){throw 'HYPERV_SQL_CONFIGURATION_RECONCILE_DESIRED_STATE_INVALID'}
    $currentSnapshot=$persisted.Snapshot
    $desiredSnapshot=$currentSnapshot
    if($ManifestPath){
        $resolved=Read-LabManifest -Path $ManifestPath
        $desiredSnapshot=New-LabDesiredStateSnapshot -ResolvedLab $resolved `
            -ProvisioningMode ([string]$currentSnapshot.ProvisioningMode) -PersistentData ([bool]$currentSnapshot.PersistentData)
        if([string]$resolved.name -ne [string]$currentSnapshot.LabName){throw 'HYPERV_SQL_CONFIGURATION_RECONCILE_LAB_IDENTITY_CHANGED'}
        $currentIds=@($currentSnapshot.Instances|ForEach-Object{[string]$_.Id}|Sort-Object)
        $targetIds=@($desiredSnapshot.Instances|ForEach-Object{[string]$_.Id}|Sort-Object)
        if(($currentIds -join ',') -cne ($targetIds -join ',')){throw 'HYPERV_SQL_CONFIGURATION_RECONCILE_INSTANCE_SET_CHANGED'}
        foreach($other in @($currentSnapshot.Instances|Where-Object{[string]$_.Id -ne $InstanceId})){
            $targetOther=@($desiredSnapshot.Instances|Where-Object{[string]$_.Id -eq [string]$other.Id})
            if($targetOther.Count -ne 1 -or (($other|ConvertTo-Json -Depth 50 -Compress) -cne ($targetOther[0]|ConvertTo-Json -Depth 50 -Compress))){
                throw "HYPERV_SQL_CONFIGURATION_RECONCILE_OTHER_INSTANCE_CHANGED: $($other.Id)"
            }
        }
    }
    $currentInstances=@($currentSnapshot.Instances|Where-Object{[string]$_.Id -eq $InstanceId})
    $desiredInstances=@($desiredSnapshot.Instances|Where-Object{[string]$_.Id -eq $InstanceId})
    if($currentInstances.Count -ne 1 -or $desiredInstances.Count -ne 1 -or [string]$desiredInstances[0].Provider -ne 'hyperv'){
        throw 'HYPERV_SQL_CONFIGURATION_RECONCILE_INSTANCE_NOT_UNIQUE'
    }
    if($ManifestPath){
        $currentFingerprint=Get-LabHyperVSqlConfigurationInstanceFingerprint -Instance $currentInstances[0]
        $targetFingerprint=Get-LabHyperVSqlConfigurationInstanceFingerprint -Instance $desiredInstances[0]
        if(($currentFingerprint|ConvertTo-Json -Depth 50 -Compress) -cne ($targetFingerprint|ConvertTo-Json -Depth 50 -Compress)){
            throw 'HYPERV_SQL_CONFIGURATION_RECONCILE_NON_CONFIGURATION_DRIFT'
        }
    }
    $currentDesired=$currentInstances[0].Intents.SqlConfiguration
    $desired=$desiredInstances[0].Intents.SqlConfiguration
    if (-not $desired -or -not $desired.Contract -or
        [string]$desired.Contract.Name -ne 'SqlServerLab.SqlConfigurationIntent' -or
        [string]$desired.Contract.Version -ne '1.0') {
        throw 'HYPERV_SQL_CONFIGURATION_RECONCILE_INTENT_MISSING'
    }
    if ([string]$desired.CapabilityStatus -ne 'DECLARED_SUPPORTED') { throw 'HYPERV_SQL_CONFIGURATION_RECONCILE_INTENT_UNSUPPORTED' }
    if(-not $currentDesired){
        if(-not $ManifestPath){throw 'HYPERV_SQL_CONFIGURATION_RECONCILE_INTENT_MISSING'}
        $currentDesired=[PSCustomObject]@{
            Contract=[PSCustomObject]@{Name='SqlServerLab.SqlConfigurationIntent';Version='1.0'}
            Configurations=@();TraceFlags=@();RequiredCapability='hyperv-sql-configuration-reconcile';CapabilityStatus='DECLARED_SUPPORTED'
        }
    }
    $removedConfigurations=@($currentDesired.Configurations|Where-Object{
        [string]$_.Name -notin @($desired.Configurations|ForEach-Object{[string]$_.Name})
    })
    if($removedConfigurations.Count){throw 'HYPERV_SQL_CONFIGURATION_RECONCILE_CONFIGURATION_REMOVAL_UNSUPPORTED'}
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
    $context=[PSCustomObject]@{
        RunId=$RunId; ScopeId=[string]$run.scopeId; InstanceId=$InstanceId; StateRoot=$StateRoot
        RunDirectory=$runDirectory; ConnectionInstance=$instances[0]; Managed=$managed; VM=$managed.VM
        Run=$run;PersistedSnapshot=$currentSnapshot;DesiredSnapshot=$desiredSnapshot
        CurrentDesired=$currentDesired;Desired=$desired
        DesiredStateChanged=(($currentDesired|ConvertTo-Json -Depth 30 -Compress) -cne ($desired|ConvertTo-Json -Depth 30 -Compress))
        CredentialAvailable=[bool]$credentialAvailable
    }
    $ownershipPath=Get-LabHyperVSqlConfigurationOwnershipPath -RunDirectory $runDirectory
    $context|Add-Member -NotePropertyName OwnershipPath -NotePropertyValue $ownershipPath
    $ownership=Read-LabHyperVSqlConfigurationOwnershipReceipt -Path $ownershipPath -Context $context
    if(-not $ownership){
        $ownership=ConvertTo-LabHyperVSqlConfigurationOwnershipReceipt -RunId $RunId -ScopeId ([string]$run.scopeId) `
            -InstanceId $InstanceId -VMId ([string]$managed.VM.Id)
    }
    $context|Add-Member -NotePropertyName Ownership -NotePropertyValue $ownership
    return $context
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
        $instanceMap=Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL' -ErrorAction Stop
        $sqlInstanceId=[string]$instanceMap.MSSQLSERVER
        if([string]::IsNullOrWhiteSpace($sqlInstanceId)){throw 'HYPERV_SQL_CONFIGURATION_RECONCILE_DEFAULT_INSTANCE_NOT_UNIQUE'}
        $parameterPath="HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$sqlInstanceId\MSSQLServer\Parameters"
        $parameters=Get-ItemProperty -LiteralPath $parameterPath -ErrorAction Stop
        $startupTraceFlags=@($parameters.PSObject.Properties | Where-Object Name -like 'SQLArg*' | ForEach-Object {
            $argument=[string]$_.Value
            if($argument -match '(?i)^-T\s*(\d+)$'){[int]$Matches[1]}
        } | Sort-Object -Unique)
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
                    Configurations=$configurations;TraceFlags=$traceFlags;StartupTraceFlags=$startupTraceFlags;ObservedAt=[datetime]::UtcNow.ToString('o')
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
    param(
        [Parameter(Mandatory)]$Desired,
        [Parameter(Mandatory)]$Actual,
        $CurrentDesired,
        $Ownership,
        [bool]$DesiredStateChanged=$false
    )

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
    $targetFlags=@($Desired.TraceFlags|ForEach-Object{[int]$_}|Sort-Object -Unique)
    $currentFlags=if($CurrentDesired){@($CurrentDesired.TraceFlags|ForEach-Object{[int]$_}|Sort-Object -Unique)}else{@()}
    $ownedFlags=if($Ownership){@($Ownership.TraceFlags|ForEach-Object{[int]$_}|Sort-Object -Unique)}else{@()}
    $removalCandidates=@(@($currentFlags)+@($ownedFlags)|Where-Object{[int]$_ -notin $targetFlags}|Sort-Object -Unique)
    foreach($traceFlag in $removalCandidates){
        $active=@($Actual.TraceFlags) -contains [int]$traceFlag
        $owned=$ownedFlags -contains [int]$traceFlag
        $startup=@($Actual.StartupTraceFlags) -contains [int]$traceFlag
        if($active -and $startup){
            $diff.Add([PSCustomObject]@{
                Kind='trace-flag-remove-startup';Name="trace-flag-$traceFlag";Desired=0;Actual=1
                Supported=$false;ChangeClass='unsupported';RequiresApply=$false;RequiresServiceRestart=$false
            })
        }elseif($active -and -not $owned){
            $diff.Add([PSCustomObject]@{
                Kind='trace-flag-remove-unowned';Name="trace-flag-$traceFlag";Desired=0;Actual=1
                Supported=$false;ChangeClass='unsupported';RequiresApply=$false;RequiresServiceRestart=$false
            })
        }elseif($active){
            $diff.Add([PSCustomObject]@{
                Kind='trace-flag-remove';Name="trace-flag-$traceFlag";Desired=0;Actual=1
                Supported=$true;ChangeClass='live';RequiresApply=$true;RequiresServiceRestart=$false
            })
        }elseif($owned){
            $diff.Add([PSCustomObject]@{
                Kind='trace-flag-ownership-prune';Name="trace-flag-$traceFlag";Desired=0;Actual=0
                Supported=$true;ChangeClass='live';RequiresApply=$false;RequiresServiceRestart=$false
            })
        }
    }
    if($DesiredStateChanged){
        $diff.Add([PSCustomObject]@{
            Kind='desired-state-sync';Name='sql-configuration-intent';Desired=1;Actual=0
            Supported=$true;ChangeClass='live';RequiresApply=$false;RequiresServiceRestart=$false
        })
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
    param([Parameter(Mandatory)][string]$RunId, [Parameter(Mandatory)][string]$InstanceId, [string]$ManifestPath, [string]$StateRoot)
    try {
        $context=Get-LabHyperVSqlConfigurationReconcileContext -RunId $RunId -InstanceId $InstanceId -ManifestPath $ManifestPath -StateRoot $StateRoot
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
    $diff=@(Get-LabHyperVSqlConfigurationReconcileDiff -Desired $context.Desired -Actual $actual `
        -CurrentDesired $context.CurrentDesired -Ownership $context.Ownership -DesiredStateChanged ([bool]$context.DesiredStateChanged))
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
            @('Startup- oder nicht run-eigene Trace Flags sowie fehlende oder mehrdeutige SQL-Konfiguration werden nicht mutiert.')
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
        [bool]$ApplyTraceFlags=$true,
        [int[]]$TraceFlags
    )

    $configurations=@($Context.Desired.Configurations | Sort-Object Name | ForEach-Object {[PSCustomObject]@{Name=[string]$_.Name;Value=[long]$_.Value}})
    $traceFlags=if($PSBoundParameters.ContainsKey('TraceFlags')){
        @($TraceFlags|ForEach-Object{[int]$_}|Sort-Object -Unique)
    }else{
        @($Context.Desired.TraceFlags|ForEach-Object{[int]$_}|Sort-Object -Unique)
    }
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

function Invoke-LabHyperVSqlConfigurationTraceFlagRemoval {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)]$Access,
        [Parameter(Mandatory)][int[]]$TraceFlags
    )
    $flags=@($TraceFlags|ForEach-Object{[int]$_}|Sort-Object -Unique)
    if(-not $flags.Count -or @($flags|Where-Object{$_ -le 0}).Count){throw 'HYPERV_SQL_CONFIGURATION_RECONCILE_TRACE_FLAG_INVALID'}
    $result=Invoke-HyperVPowerShellDirect -VMName ([string]$Context.ConnectionInstance.vmName) `
        -ExpectedRunId ([string]$Context.RunId) -ExpectedScopeId ([string]$Context.ScopeId) `
        -Credential $Access.GuestCredential -ArgumentList @($Access.SqlSaPassword,$flags) -ScriptBlock {
        param($SqlSecret,$TraceFlags)
        $ErrorActionPreference='Stop';Add-Type -AssemblyName System.Data
        $flags=@($TraceFlags|ForEach-Object{[int]$_}|Sort-Object -Unique)
        if(-not $flags.Count -or @($flags|Where-Object{$_ -le 0}).Count){throw 'HYPERV_SQL_CONFIGURATION_RECONCILE_TRACE_FLAG_INVALID'}
        $instanceMap=Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL' -ErrorAction Stop
        $sqlInstanceId=[string]$instanceMap.MSSQLSERVER
        if([string]::IsNullOrWhiteSpace($sqlInstanceId)){throw 'HYPERV_SQL_CONFIGURATION_RECONCILE_DEFAULT_INSTANCE_NOT_UNIQUE'}
        $parameters=Get-ItemProperty -LiteralPath "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$sqlInstanceId\MSSQLServer\Parameters" -ErrorAction Stop
        $startupFlags=@($parameters.PSObject.Properties|Where-Object Name -like 'SQLArg*'|ForEach-Object{
            $argument=[string]$_.Value;if($argument -match '(?i)^-T\s*(\d+)$'){[int]$Matches[1]}
        }|Sort-Object -Unique)
        if(@($flags|Where-Object{$_ -in $startupFlags}).Count){throw 'HYPERV_SQL_CONFIGURATION_RECONCILE_STARTUP_TRACE_FLAG_REMOVAL_BLOCKED'}
        $bstr=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($SqlSecret);$plain=$null
        try{
            $plain=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
            $builder=[Data.SqlClient.SqlConnectionStringBuilder]::new();$builder['Data Source']='localhost';$builder['Initial Catalog']='master';$builder['User ID']='sa'
            $builder['Password']=$plain;$builder['Encrypt']=$true;$builder['TrustServerCertificate']=$true;$builder['Connect Timeout']=30
            $connection=[Data.SqlClient.SqlConnection]::new($builder.ConnectionString)
            try{
                $connection.Open();$command=$connection.CreateCommand();$command.CommandTimeout=30
                $command.CommandText="DBCC TRACEOFF ($($flags -join ', '), -1) WITH NO_INFOMSGS;";$null=$command.ExecuteNonQuery()
            }finally{$connection.Dispose()}
        }finally{$plain=$null;[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)}
        [PSCustomObject]@{Status='REMOVED';TraceFlags=$flags;ObservedAt=[datetime]::UtcNow.ToString('o')}
    }
    $receipt=@($result)[-1]
    if(-not $receipt -or [string]$receipt.Status -ne 'REMOVED' -or
       ((@($receipt.TraceFlags|ForEach-Object{[int]$_}|Sort-Object -Unique) -join ',') -cne ($flags -join ','))){
        throw 'HYPERV_SQL_CONFIGURATION_RECONCILE_TRACE_FLAG_REMOVAL_RECEIPT_INVALID'
    }
    return $receipt
}

function Sync-LabHyperVSqlConfigurationDesiredState {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context)
    $Context.Run.metadata|Add-Member -NotePropertyName desiredState -NotePropertyValue $Context.DesiredSnapshot -Force
    $Context.Run.updatedAt=Get-LabTimestamp
    Write-LabArtifactJsonAtomic -Path (Join-Path $Context.RunDirectory 'run-state.json') -InputObject $Context.Run
}

function Invoke-LabHyperVSqlConfigurationReconcileRepair {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunId,[Parameter(Mandatory)][string]$InstanceId,[string]$ManifestPath,[string]$StateRoot)

    $mutex=[Threading.Mutex]::new($false,"Global\SQL_Server_Lab_HyperV_SQL_Configuration_Reconcile_$($RunId.Replace('-',''))")
    $acquired=$false;$journal=$null;$journalPath=$null
    try{
        $acquired=$mutex.WaitOne([TimeSpan]::FromMinutes(5));if(-not $acquired){throw 'HYPERV_SQL_CONFIGURATION_RECONCILE_LOCK_TIMEOUT'}
        $context=Get-LabHyperVSqlConfigurationReconcileContext -RunId $RunId -InstanceId $InstanceId -ManifestPath $ManifestPath -StateRoot $StateRoot
        $journalPath=Get-LabHyperVSqlConfigurationReconcileJournalPath -RunDirectory $context.RunDirectory
        $journal=Read-LabHyperVSqlConfigurationReconcileJournal -Path $journalPath -Context $context
        $plan=New-LabHyperVSqlConfigurationReconcilePlan -RunId $RunId -InstanceId $InstanceId -ManifestPath $ManifestPath -StateRoot $context.StateRoot
        if($journal -and [string]$journal.Status -ne 'COMPLETED'){$journal.Recovery.Attempts=[int]$journal.Recovery.Attempts+1}
        elseif($journal -and [string]$journal.Status -eq 'COMPLETED' -and $plan.IsNoOp){return [PSCustomObject]@{Status='NO_OP';RunId=$RunId;InstanceId=$InstanceId;Changed=$false;RepairKinds=@()}}
        elseif($journal -and [string]$journal.Status -eq 'COMPLETED'){$journal=$null}
        if(-not $journal){
            if($plan.IsNoOp){return [PSCustomObject]@{Status='NO_OP';RunId=$RunId;InstanceId=$InstanceId;Changed=$false;RepairKinds=@()}}
            if([string]$plan.HighestChangeClass -notin @('live','restart') -or @($plan.Actions).Count -ne 1){throw 'HYPERV_SQL_CONFIGURATION_RECONCILE_UNSUPPORTED'}
            $credentials=Get-LabHyperVSqlConfigurationReconcileCredentials -RunDirectory $context.RunDirectory
            $initialActual=Get-LabHyperVSqlConfigurationActualState -Context $context -Access $credentials
            $initialDiff=@(Get-LabHyperVSqlConfigurationReconcileDiff -Desired $context.Desired -Actual $initialActual `
                -CurrentDesired $context.CurrentDesired -Ownership $context.Ownership -DesiredStateChanged ([bool]$context.DesiredStateChanged))
            if(@($initialDiff|Where-Object{-not $_.Supported}).Count){throw 'HYPERV_SQL_CONFIGURATION_RECONCILE_UNSUPPORTED'}
            $initialRestart=@($initialDiff|Where-Object{[bool]$_.RequiresServiceRestart}).Count -gt 0
            $traceFlagAdditions=if($initialRestart){
                @($context.Desired.TraceFlags|ForEach-Object{[int]$_}|Where-Object{$_ -notin @($initialActual.StartupTraceFlags)}|Sort-Object -Unique)
            }else{
                @($initialDiff|Where-Object Kind -eq 'trace-flag-add'|ForEach-Object{[int]([string]$_.Name -replace '^trace-flag-','')}|Sort-Object -Unique)
            }
            $traceFlagRemovals=@($initialDiff|Where-Object{$_.Kind -in @('trace-flag-remove','trace-flag-ownership-prune')}|ForEach-Object{[int]([string]$_.Name -replace '^trace-flag-','')}|Sort-Object -Unique)
            $journal=[PSCustomObject]@{
                ContractVersion='SqlServerLab.HyperVSqlConfigurationReconcileJournal/1.0';OperationId=[Guid]::NewGuid().ToString('D')
                RunId=$RunId;ScopeId=[string]$context.ScopeId;InstanceId=$InstanceId;Provider='hyperv';ChangeClass=[string]$plan.HighestChangeClass;Status='PREPARED'
                Target=[PSCustomObject]@{
                    Configurations=@($context.Desired.Configurations | Sort-Object Name | ForEach-Object {[PSCustomObject]@{Name=[string]$_.Name;Value=[long]$_.Value}})
                    TraceFlags=@($context.Desired.TraceFlags | ForEach-Object {[int]$_} | Sort-Object -Unique)
                }
                Runtime=[PSCustomObject]@{VMId=[string]$context.VM.Id;ServiceName='MSSQLSERVER'}
                TraceFlagAdditions=@($traceFlagAdditions);TraceFlagRemovals=@($traceFlagRemovals)
                Recovery=[PSCustomObject]@{Status='RETRY_SQL_CONFIGURATION_RECONCILE';Attempts=0;ErrorCode=$null;Errors=@()};UpdatedAt=Get-LabTimestamp
            }
            $null=Write-LabHyperVSqlConfigurationReconcileJournal -Journal $journal -Path $journalPath
        }
        if(-not($journal.PSObject.Properties.Name -contains 'TraceFlagAdditions')){$journal|Add-Member -NotePropertyName TraceFlagAdditions -NotePropertyValue @()}
        if(-not($journal.PSObject.Properties.Name -contains 'TraceFlagRemovals')){$journal|Add-Member -NotePropertyName TraceFlagRemovals -NotePropertyValue @()}
        $credentials=Get-LabHyperVSqlConfigurationReconcileCredentials -RunDirectory $context.RunDirectory
        $actual=Get-LabHyperVSqlConfigurationActualState -Context $context -Access $credentials
        $before=@(Get-LabHyperVSqlConfigurationReconcileDiff -Desired $context.Desired -Actual $actual `
            -CurrentDesired $context.CurrentDesired -Ownership $context.Ownership -DesiredStateChanged ([bool]$context.DesiredStateChanged))
        if(@($before | Where-Object {-not $_.Supported}).Count){throw 'HYPERV_SQL_CONFIGURATION_RECONCILE_UNSUPPORTED'}
        $configurationApplyRequired=@($before | Where-Object {$_.Kind -like 'configuration*' -and [bool]$_.RequiresApply}).Count -gt 0
        $traceFlagApplyRequired=@($before | Where-Object {$_.Kind -eq 'trace-flag-add'}).Count -gt 0
        $traceFlagsToAdd=@($before|Where-Object Kind -eq 'trace-flag-add'|ForEach-Object{[int]([string]$_.Name -replace '^trace-flag-','')}|Sort-Object -Unique)
        $serviceRestartRequired=@($before | Where-Object {[bool]$_.RequiresServiceRestart}).Count -gt 0
        if($configurationApplyRequired -or ($traceFlagApplyRequired -and -not $serviceRestartRequired)){
            Set-LabHyperVSqlConfigurationValues -Context $context -Access $credentials `
                -ApplyConfigurations $configurationApplyRequired -ApplyTraceFlags ($traceFlagApplyRequired -and -not $serviceRestartRequired) `
                -TraceFlags $traceFlagsToAdd
            $null=Set-LabHyperVSqlConfigurationReconcileJournalStatus -Journal $journal -Path $journalPath -Status CONFIGURATION_APPLIED
        }
        if(-not $serviceRestartRequired){
            $activeRemovals=@($journal.TraceFlagRemovals|ForEach-Object{[int]$_}|Where-Object{$_ -in @($actual.TraceFlags)}|Sort-Object -Unique)
            if($activeRemovals.Count){
                $owned=@($context.Ownership.TraceFlags|ForEach-Object{[int]$_})
                if(@($activeRemovals|Where-Object{$_ -notin $owned -or $_ -in @($actual.StartupTraceFlags)}).Count){
                    throw 'HYPERV_SQL_CONFIGURATION_RECONCILE_TRACE_FLAG_REMOVAL_NOT_OWNED'
                }
                $null=Invoke-LabHyperVSqlConfigurationTraceFlagRemoval -Context $context -Access $credentials -TraceFlags $activeRemovals
            }
            if(@($journal.TraceFlagRemovals).Count){
                $null=Set-LabHyperVSqlConfigurationReconcileJournalStatus -Journal $journal -Path $journalPath -Status TRACE_FLAGS_REMOVED
            }
        }
        if($serviceRestartRequired){
            $restartReceipt=Invoke-LabHyperVSqlConfigurationServiceRestart -Context $context -Access $credentials
            if([string]$restartReceipt.ServiceStatus -ne 'Running'){throw 'HYPERV_SQL_CONFIGURATION_RECONCILE_SERVICE_RESTART_FAILED'}
            $null=Set-LabHyperVSqlConfigurationReconcileJournalStatus -Journal $journal -Path $journalPath -Status SERVICE_RESTARTED
        }
        $afterRuntimeChange=Get-LabHyperVSqlConfigurationActualState -Context $context -Access $credentials
        $missingTargetFlags=@($context.Desired.TraceFlags|ForEach-Object{[int]$_}|Where-Object{$_ -notin @($afterRuntimeChange.TraceFlags)})
        if($missingTargetFlags.Count){
            Set-LabHyperVSqlConfigurationValues -Context $context -Access $credentials -ApplyConfigurations $false -ApplyTraceFlags $true -TraceFlags $missingTargetFlags
        }
        $context=Get-LabHyperVSqlConfigurationReconcileContext -RunId $RunId -InstanceId $InstanceId -ManifestPath $ManifestPath -StateRoot $context.StateRoot
        $actual=Get-LabHyperVSqlConfigurationActualState -Context $context -Access $credentials
        $remaining=@(Get-LabHyperVSqlConfigurationReconcileDiff -Desired $context.Desired -Actual $actual `
            -CurrentDesired $context.CurrentDesired -Ownership $context.Ownership -DesiredStateChanged ([bool]$context.DesiredStateChanged))
        $runtimeRemaining=@($remaining|Where-Object{$_.Kind -notin @('trace-flag-ownership-prune','desired-state-sync')})
        if($runtimeRemaining.Count){throw "HYPERV_SQL_CONFIGURATION_RECONCILE_POSTCONDITION_FAILED: $(@($runtimeRemaining.Name)-join ',')"}
        if(@($journal.TraceFlagRemovals|ForEach-Object{[int]$_}|Where-Object{$_ -in @($actual.TraceFlags)}).Count){
            throw 'HYPERV_SQL_CONFIGURATION_RECONCILE_TRACE_FLAG_REMOVAL_POSTCONDITION_FAILED'
        }
        $null=Set-LabHyperVSqlConfigurationReconcileJournalStatus -Journal $journal -Path $journalPath -Status VERIFIED
        $targetFlags=@($context.Desired.TraceFlags|ForEach-Object{[int]$_})
        $ownedFlags=@(@($context.Ownership.TraceFlags|ForEach-Object{[int]$_})+@($journal.TraceFlagAdditions|ForEach-Object{[int]$_})|Where-Object{
            $_ -in $targetFlags -and $_ -notin @($journal.TraceFlagRemovals)
        }|Sort-Object -Unique)
        $context.Ownership.TraceFlags=@($ownedFlags)
        $null=Write-LabHyperVSqlConfigurationOwnershipReceipt -Receipt $context.Ownership -Path $context.OwnershipPath
        $null=Set-LabHyperVSqlConfigurationReconcileJournalStatus -Journal $journal -Path $journalPath -Status OWNERSHIP_UPDATED
        Sync-LabHyperVSqlConfigurationDesiredState -Context $context
        $null=Set-LabHyperVSqlConfigurationReconcileJournalStatus -Journal $journal -Path $journalPath -Status DESIRED_STATE_UPDATED
        $null=Set-LabHyperVSqlConfigurationReconcileJournalStatus -Journal $journal -Path $journalPath -Status COMPLETED
        [PSCustomObject]@{Status='SUCCEEDED';RunId=$RunId;InstanceId=$InstanceId;Changed=$true;RepairKinds=@($before | ForEach-Object { [string]$_.Kind } | Sort-Object -Unique);JournalStatus='COMPLETED'}
    }
    catch{
        $code=if($_.Exception.Message -cmatch '[A-Z][A-Z0-9_]{5,127}'){[string]$Matches[0]}else{'HYPERV_SQL_CONFIGURATION_RECONCILE_FAILED'}
        if($journal -and $journalPath){try{$null=Set-LabHyperVSqlConfigurationReconcileJournalStatus -Journal $journal -Path $journalPath -Status RECOVERY_REQUIRED -ErrorCode $code}catch{}}
        if($journal -and $journalPath){throw "HYPERV_SQL_CONFIGURATION_RECONCILE_RECOVERY_REQUIRED: $code"}
        throw
    }
    finally{if($acquired){try{$mutex.ReleaseMutex()}catch{}};$mutex.Dispose()}
}
