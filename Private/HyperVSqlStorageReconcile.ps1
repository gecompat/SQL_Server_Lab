<#
.SYNOPSIS
    Plant und repariert die SQL-Dateiplatzierung eines gebundenen Hyper-V-Runs.
.DESCRIPTION
    Der Plan liest Default- und TempDB-Pfade im Gast, bleibt aber frei von
    Host-, VM- und Gastpfaden. Eine Mutation ist erst erlaubt, wenn der
    Host-/Gast-Storage-Reconcile ein No-op ist. Der Executor verwendet den
    vorhandenen StorageRuntimeReceipt-Vertrag und dessen RECOVERY_REQUIRED-
    Resume-Pfad; Systemdatenbanken und User-Datenbankdateien werden nicht
    automatisch verschoben.
#>

function Get-LabHyperVSqlStorageReconcileCredentials {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunDirectory)

    $guestPassword = Get-LabSecret -Path $RunDirectory -Name 'guest-administrator-password'
    $saPassword = Get-LabSecret -Path $RunDirectory -Name 'generated-sql-sa-password'
    if (-not $saPassword) { $saPassword = Get-LabSecret -Path $RunDirectory -Name 'sa-password' }
    if (-not $guestPassword -or -not $saPassword) { throw 'HYPERV_SQL_STORAGE_RECONCILE_CREDENTIAL_REQUIRED' }
    return [PSCustomObject]@{
        GuestCredential = [PSCredential]::new('Administrator', $guestPassword)
        SqlSaPassword = $saPassword
    }
}

function Get-LabHyperVSqlStorageReconcileContext {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunId, [Parameter(Mandatory)][string]$InstanceId, [string]$StateRoot)

    $storageContext = Get-LabHyperVStorageReconcileContext -RunId $RunId -InstanceId $InstanceId -StateRoot $StateRoot
    $hostPlan = New-LabHyperVStorageReconcilePlan -RunId $RunId -InstanceId $InstanceId -StateRoot $storageContext.StateRoot
    if (-not $hostPlan.IsNoOp) { throw 'HYPERV_SQL_STORAGE_RECONCILE_HOST_DRIFT_PENDING' }
    if ([string]$storageContext.VM.State -ne 'Running') { throw 'HYPERV_SQL_STORAGE_RECONCILE_VM_RUNNING_REQUIRED' }

    $boundPath = Join-Path $storageContext.RunDirectory 'storage-bound-plan.json'
    if (-not (Test-Path -LiteralPath $boundPath -PathType Leaf)) { throw 'HYPERV_SQL_STORAGE_RECONCILE_BOUND_PLAN_REQUIRED' }
    $boundPlan = Get-Content -LiteralPath $boundPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 40
    $null = Assert-LabStorageBoundPlan -Plan $boundPlan
    if ([string]$boundPlan.RunId -ne $RunId -or [string]$boundPlan.InstanceId -ne $InstanceId -or
        [string]$boundPlan.Provider -ne 'hyperv' -or [string]$boundPlan.Status -ne 'READY') {
        throw 'HYPERV_SQL_STORAGE_RECONCILE_BOUND_PLAN_IDENTITY_MISMATCH'
    }
    $runtime = Resolve-LabStorageRuntimeSqlPlan -Plan $boundPlan `
        -DriveReceipts @($storageContext.Managed.Identity.guestDriveInitialization) `
        -ManagedDrives @($storageContext.Managed.Identity.additionalDrives)
    $managedFiles = @($runtime.SqlFiles | Where-Object { [string]$_.Role -in @('default-data','default-log','backup','tempdb-data','tempdb-log') })
    if ($managedFiles.Count -eq 0) { throw 'HYPERV_SQL_STORAGE_RECONCILE_SQL_FILE_PLAN_REQUIRED' }

    $receiptPath = Join-Path $storageContext.RunDirectory 'storage-runtime-receipt.json'
    $receipt = $null
    if (Test-Path -LiteralPath $receiptPath -PathType Leaf) {
        $receipt = Get-Content -LiteralPath $receiptPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 40
        $null = Assert-LabStorageRuntimeReceipt -Receipt $receipt
        if ([string]$receipt.RunId -ne $RunId -or [string]$receipt.InstanceId -ne $InstanceId -or [string]$receipt.Provider -ne 'hyperv') {
            throw 'HYPERV_SQL_STORAGE_RECONCILE_RECEIPT_IDENTITY_MISMATCH'
        }
    }
    $secretDirectory = Join-Path $storageContext.RunDirectory 'secrets'
    $credentialAvailable = (Test-Path -LiteralPath (Join-Path $secretDirectory 'guest-administrator-password.secret') -PathType Leaf) -and
        ((Test-Path -LiteralPath (Join-Path $secretDirectory 'generated-sql-sa-password.secret') -PathType Leaf) -or
         (Test-Path -LiteralPath (Join-Path $secretDirectory 'sa-password.secret') -PathType Leaf))
    return [PSCustomObject]@{
        RunId=$RunId; InstanceId=$InstanceId; StateRoot=$storageContext.StateRoot
        RunDirectory=$storageContext.RunDirectory; ScopeId=$storageContext.ScopeId
        VM=$storageContext.VM; Managed=$storageContext.Managed; ConnectionInstance=$storageContext.ConnectionInstance
        BoundPlan=$boundPlan; Runtime=$runtime; ManagedSqlFiles=$managedFiles
        RuntimeReceipt=$receipt; ReceiptPath=$receiptPath; CredentialAvailable=[bool]$credentialAvailable
    }
}

function Get-LabHyperVSqlStorageActualState {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)]$Credentials)

    $result = Invoke-HyperVPowerShellDirect -VMName ([string]$Context.ConnectionInstance.vmName) `
        -ExpectedRunId ([string]$Context.RunId) -ExpectedScopeId ([string]$Context.ScopeId) `
        -Credential $Credentials.GuestCredential -ArgumentList @($Credentials.SqlSaPassword) -ScriptBlock {
        param($SqlSaPassword)
        $ErrorActionPreference = 'Stop'
        Add-Type -AssemblyName System.Data
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SqlSaPassword)
        $plain = $null
        try {
            $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
            $builder = [Data.SqlClient.SqlConnectionStringBuilder]::new()
            $builder['Data Source']='localhost'; $builder['Initial Catalog']='master'; $builder['User ID']='sa'
            $builder['Password']=$plain; $builder['Encrypt']=$true; $builder['TrustServerCertificate']=$true; $builder['Connect Timeout']=30
            $connection = [Data.SqlClient.SqlConnection]::new($builder.ConnectionString)
            try {
                $connection.Open()
                $command=$connection.CreateCommand(); $command.CommandTimeout=30
                $command.CommandText="SELECT CAST(SERVERPROPERTY('InstanceDefaultDataPath') AS nvarchar(4000)),CAST(SERVERPROPERTY('InstanceDefaultLogPath') AS nvarchar(4000));"
                $reader=$command.ExecuteReader(); $null=$reader.Read()
                $defaults=@(
                    [PSCustomObject]@{Role='default-data';Path=[string]$reader.GetValue(0)},
                    [PSCustomObject]@{Role='default-log';Path=[string]$reader.GetValue(1)}
                ); $reader.Dispose()
                $command=$connection.CreateCommand()
                $command.CommandText="DECLARE @p nvarchar(4000); EXEC master.dbo.xp_instance_regread N'HKEY_LOCAL_MACHINE',N'Software\Microsoft\MSSQLServer\MSSQLServer',N'BackupDirectory',@p OUTPUT; SELECT @p;"
                $defaults += [PSCustomObject]@{Role='backup';Path=[string]$command.ExecuteScalar()}
                $command=$connection.CreateCommand()
                $command.CommandText="SELECT name,physical_name,size/128,CASE WHEN is_percent_growth=1 THEN CAST(growth AS varchar(20))+'%' ELSE CAST(growth/128 AS varchar(20))+'MB' END,type FROM sys.master_files WHERE database_id=2 ORDER BY file_id;"
                $reader=$command.ExecuteReader(); $tempDb=@()
                while($reader.Read()){
                    $tempDb += [PSCustomObject]@{
                        LogicalName=[string]$reader.GetString(0);Path=[string]$reader.GetString(1)
                        SizeMB=[Convert]::ToInt32($reader.GetValue(2),[Globalization.CultureInfo]::InvariantCulture)
                        Growth=[string]$reader.GetString(3);Type=[Convert]::ToInt32($reader.GetValue(4),[Globalization.CultureInfo]::InvariantCulture)
                    }
                }
                $reader.Dispose()
                [PSCustomObject]@{Status='AVAILABLE';SqlService='Running';Defaults=$defaults;TempDb=$tempDb;ObservedAt=[datetime]::UtcNow.ToString('o')}
            }
            finally { $connection.Dispose() }
        }
        finally { $plain=$null; [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    }
    $actual = @($result)[-1]
    if (-not $actual -or [string]$actual.Status -ne 'AVAILABLE') { throw 'HYPERV_SQL_STORAGE_RECONCILE_ACTUAL_UNAVAILABLE' }
    return $actual
}

function Get-LabHyperVSqlStorageReconcileDiff {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)]$Actual)

    $diff = [Collections.Generic.List[object]]::new()
    foreach ($role in @('default-data','default-log','backup')) {
        $desired=@($Context.ManagedSqlFiles|Where-Object Role -eq $role); $current=@($Actual.Defaults|Where-Object Role -eq $role)
        if($desired.Count -gt 1 -or $current.Count -ne 1){$diff.Add([PSCustomObject]@{Kind='default-contract';Role=$role;LogicalName=$null;Supported=$false});continue}
        if($desired.Count -eq 1 -and -not ([string]$current[0].Path).TrimEnd('\').Equals(([string]$desired[0].SqlPhysicalPath).TrimEnd('\'),[StringComparison]::OrdinalIgnoreCase)){
            $diff.Add([PSCustomObject]@{Kind='default-path';Role=$role;LogicalName=$null;Supported=$true})
        }
    }
    $desiredTemp=@($Context.ManagedSqlFiles|Where-Object Role -in @('tempdb-data','tempdb-log'))
    foreach($file in $desiredTemp){
        $current=@($Actual.TempDb|Where-Object LogicalName -eq ([string]$file.LogicalName))
        if($current.Count -ne 1){$diff.Add([PSCustomObject]@{Kind='tempdb-add';Role=[string]$file.Role;LogicalName=[string]$file.LogicalName;Supported=$true});continue}
        if(-not ([string]$current[0].Path).Equals([string]$file.SqlPhysicalPath,[StringComparison]::OrdinalIgnoreCase) -or
            [int]$current[0].SizeMB -lt [int]$file.SizeMB -or [string]$current[0].Growth -ne [string]$file.Growth){
            $diff.Add([PSCustomObject]@{Kind='tempdb-configure';Role=[string]$file.Role;LogicalName=[string]$file.LogicalName;Supported=$true})
        }
    }
    $desiredNames=@($desiredTemp.LogicalName)
    foreach($extra in @($Actual.TempDb|Where-Object LogicalName -notin $desiredNames)){
        if([int]$extra.Type -eq 1){$diff.Add([PSCustomObject]@{Kind='tempdb-extra-log';Role='tempdb-log';LogicalName='extra-tempdb-log';Supported=$false})}
        else{$diff.Add([PSCustomObject]@{Kind='tempdb-remove';Role='tempdb-data';LogicalName='extra-tempdb-data';Supported=$true})}
    }
    return @($diff)
}

function New-LabHyperVSqlStorageReconcilePlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunId,[Parameter(Mandatory)][string]$InstanceId,[string]$StateRoot)
    try{
        $context=Get-LabHyperVSqlStorageReconcileContext -RunId $RunId -InstanceId $InstanceId -StateRoot $StateRoot
        if(-not $context.CredentialAvailable){throw 'HYPERV_SQL_STORAGE_RECONCILE_CREDENTIAL_REQUIRED'}
        $credentials=Get-LabHyperVSqlStorageReconcileCredentials -RunDirectory $context.RunDirectory
        $actual=Get-LabHyperVSqlStorageActualState -Context $context -Credentials $credentials
    }catch{
        $code=if($_.Exception.Message -cmatch '[A-Z][A-Z0-9_]{5,127}'){[string]$Matches[0]}else{'HYPERV_SQL_STORAGE_RECONCILE_UNAVAILABLE'}
        return [PSCustomObject]@{Contract=[PSCustomObject]@{Name='SqlServerLab.HyperVSqlStorageReconcilePlan';Version='1.0'};RunId=$RunId;InstanceId=$InstanceId;Provider='hyperv';Desired=[PSCustomObject]@{ManagedRoleCount=0;TempDbFileCount=0};Actual=[PSCustomObject]@{Status='UNAVAILABLE';TempDbFileCount=0};Diff=@();Actions=@();HighestChangeClass='unsupported';IsNoOp=$false;MutationAllowed=$false;Warnings=@('Der SQL-Dateizustand ist nicht eindeutig steuerbar.');ReasonCodes=@($code)}
    }
    $diff=@(Get-LabHyperVSqlStorageReconcileDiff -Context $context -Actual $actual)
    $pending=$context.RuntimeReceipt -and [string]$context.RuntimeReceipt.PlanId -eq [string]$context.BoundPlan.PlanId -and
        [string]$context.RuntimeReceipt.Status -eq 'RECOVERY_REQUIRED' -and [string]$context.RuntimeReceipt.Recovery.Status -eq 'RETRY_APPLY'
    $unsupported=@($diff|Where-Object{-not $_.Supported})
    $changeClass=if($unsupported.Count){'unsupported'}elseif($diff.Count -eq 0 -and -not $pending){'no-op'}else{'restart'}
    $actions=if($changeClass -eq 'restart'){@([PSCustomObject]@{Operation=if($pending){'ResumeHyperVSqlStorage'}else{'RepairHyperVSqlStorage'};ChangeClass='restart';RepairKinds=@($diff.Kind|Sort-Object -Unique);RequiresSqlServiceRestart=$true;RecoveryPending=[bool]$pending})}else{@()}
    return [PSCustomObject]@{
        Contract=[PSCustomObject]@{Name='SqlServerLab.HyperVSqlStorageReconcilePlan';Version='1.0'};RunId=$RunId;InstanceId=$InstanceId;Provider='hyperv'
        Desired=[PSCustomObject]@{ManagedRoleCount=@($context.ManagedSqlFiles|Select-Object Role -Unique).Count;TempDbFileCount=@($context.ManagedSqlFiles|Where-Object Role -in @('tempdb-data','tempdb-log')).Count}
        Actual=[PSCustomObject]@{Status='AVAILABLE';SqlService=[string]$actual.SqlService;TempDbFileCount=@($actual.TempDb).Count}
        Diff=@($diff|ForEach-Object{[PSCustomObject]@{Kind=[string]$_.Kind;Role=[string]$_.Role;LogicalName=[string]$_.LogicalName;ChangeClass=if($_.Supported){$changeClass}else{'unsupported'}}})
        Actions=$actions;HighestChangeClass=$changeClass;IsNoOp=($changeClass -eq 'no-op');MutationAllowed=$false
        Warnings=if($unsupported.Count){@('Zusaetzliche TempDB-Logfiles und uneindeutige SQL-Dateivertraege werden nicht automatisch mutiert.')}elseif($changeClass -eq 'restart'){@('Die Reparatur startet den SQL-Dienst kontrolliert neu; die Hyper-V-VM bleibt eingeschaltet.')}else{@()}
        ReasonCodes=@($(if($pending){'HYPERV_SQL_STORAGE_RECONCILE_RECOVERY_PENDING'});@($unsupported|ForEach-Object{"HYPERV_SQL_STORAGE_RECONCILE_$([string]$_.Kind -replace '-','_')_UNSUPPORTED".ToUpperInvariant()}))
    }
}

function Invoke-LabHyperVSqlStorageReconcileRepair {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunId,[Parameter(Mandatory)][string]$InstanceId,[string]$StateRoot)
    $mutex=[Threading.Mutex]::new($false,"Global\SQL_Server_Lab_HyperV_SQL_Storage_Reconcile_$($RunId.Replace('-',''))")
    $acquired=$false
    try{
        $acquired=$mutex.WaitOne([TimeSpan]::FromMinutes(5));if(-not $acquired){throw 'HYPERV_SQL_STORAGE_RECONCILE_LOCK_TIMEOUT'}
        $context=Get-LabHyperVSqlStorageReconcileContext -RunId $RunId -InstanceId $InstanceId -StateRoot $StateRoot
        $plan=New-LabHyperVSqlStorageReconcilePlan -RunId $RunId -InstanceId $InstanceId -StateRoot $context.StateRoot
        if($plan.IsNoOp){return [PSCustomObject]@{Status='NO_OP';RunId=$RunId;InstanceId=$InstanceId;Changed=$false;RepairKinds=@()}}
        if([string]$plan.HighestChangeClass -ne 'restart' -or @($plan.Actions).Count -ne 1){throw 'HYPERV_SQL_STORAGE_RECONCILE_UNSUPPORTED'}
        $credentials=Get-LabHyperVSqlStorageReconcileCredentials -RunDirectory $context.RunDirectory
        $receipt=Invoke-HyperVLabStoragePlan -RunId $RunId -Plan $context.BoundPlan -Credential $credentials.GuestCredential -SqlSaPassword $credentials.SqlSaPassword -StateRoot $context.StateRoot
        if([string]$receipt.Status -ne 'VERIFIED'){throw 'HYPERV_SQL_STORAGE_RECONCILE_RECEIPT_NOT_VERIFIED'}
        $finalContext=Get-LabHyperVSqlStorageReconcileContext -RunId $RunId -InstanceId $InstanceId -StateRoot $context.StateRoot
        $actual=Get-LabHyperVSqlStorageActualState -Context $finalContext -Credentials $credentials
        $remaining=@(Get-LabHyperVSqlStorageReconcileDiff -Context $finalContext -Actual $actual)
        if($remaining.Count){throw "HYPERV_SQL_STORAGE_RECONCILE_POSTCONDITION_FAILED: $(@($remaining.Kind)-join ',')"}
        return [PSCustomObject]@{Status='SUCCEEDED';RunId=$RunId;InstanceId=$InstanceId;Changed=$true;RepairKinds=@($plan.Actions[0].RepairKinds);ReceiptStatus='VERIFIED'}
    }catch{throw "HYPERV_SQL_STORAGE_RECONCILE_RECOVERY_REQUIRED: $($_.Exception.Message)"}
    finally{if($acquired){try{$mutex.ReleaseMutex()}catch{}};$mutex.Dispose()}
}
