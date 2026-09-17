#Requires -Version 7.2
<#
.SYNOPSIS
    Runs the bounded native HV-603A SQL-storage reconcile acceptance.
.DESCRIPTION
    Uses one operation-owned clone of an explicitly selected stopped Windows
    2025 slot.  It first establishes the HV-603 SCSI/storage receipt and only
    then verifies receipt-bound SQL default and TempDB path reconciliation.
    Fault/resume injection remains in the synthetic contract; this runner does
    not add a production fault-injection seam.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$CloneSourceRunId,
    [Parameter(Mandatory)][string]$MediaRoot,
    [ValidateSet('Enterprise','Standard','Eval')][string]$MediaEdition='Enterprise',
    [string]$StateRoot,
    [string]$OperationId=('local-hv-sql-storage-'+[guid]::NewGuid().ToString('N')),
    [switch]$KeepOnFailure
)
$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$modulePath=Join-Path $repoRoot 'SqlServerLab.psd1'
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-hv-sql-storage-'+[guid]::NewGuid().ToString('N'))
$previousStateRoot=$env:SQL_SERVER_LAB_STATE
$module=$null;$lab=$null;$ownedPaths=@();$completed=$false;$script:saPassword=$null
$mutex=[Threading.Mutex]::new($false,'Global\SQL_Server_Lab_HyperV_SQL_Storage_Reconcile_Acceptance');$mutexAcquired=$false

function Assert-HyperVSqlStorageAcceptance { param([bool]$Condition,[string]$Description) if(-not $Condition){throw "HYPERV_SQL_STORAGE_ACCEPTANCE_FAILED: $Description"};Write-Host "PASS: $Description" -ForegroundColor Green }
function Invoke-Private { param([scriptblock]$ScriptBlock,[object[]]$Arguments=@()) & $module $ScriptBlock @Arguments }
function Get-Context { param([string]$RunId) Invoke-Private {param($Id,$Root)Get-HyperVLabWorkflowRun -RunId $Id -StateRoot $Root} @($RunId,$StateRoot) }
function Get-OwnedManagedVm { param($Context) Invoke-Private {param($Name,$Id,$Scope)Get-HyperVManagedVM -VMName $Name -ExpectedRunId $Id -ExpectedScopeId $Scope} @([string]$Context.Instance.vmName,[string]$Context.Run.runId,[string]$Context.Run.scopeId) }
function New-SqlConnection { param($Context) if(-not $script:saPassword.IsReadOnly()){$script:saPassword.MakeReadOnly()};$c=[Data.SqlClient.SqlConnection]::new();$c.ConnectionString="Server=$([string]$Context.Instance.host),$([int]$Context.Instance.port);Database=master;Encrypt=True;TrustServerCertificate=True;Connect Timeout=30;";$c.Credential=[Data.SqlClient.SqlCredential]::new('sa',$script:saPassword);$c }
function Invoke-SqlRows {
    param($Context,[string]$Query)
    $c=New-SqlConnection $Context;try{$c.Open();$cmd=$c.CreateCommand();$cmd.CommandTimeout=120;$cmd.CommandText=$Query;$table=[Data.DataTable]::new();$reader=$cmd.ExecuteReader();$table.Load($reader);$reader.Dispose();@($table.Rows|ForEach-Object{$row=$_;$value=[ordered]@{};foreach($column in $table.Columns){$value[$column.ColumnName]=[string]$row[$column.ColumnName]};[pscustomobject]$value})}finally{$c.Dispose()}
}
function Wait-StorageSqlReady { param($Context) $deadline=[datetime]::UtcNow.AddMinutes(5);do{try{$c=New-SqlConnection $Context;$c.Open();$cmd=$c.CreateCommand();$cmd.CommandText='SELECT 1;';if([int]$cmd.ExecuteScalar() -eq 1){return $true}}catch{}finally{if($c){$c.Dispose()}};Start-Sleep -Seconds 5}while([datetime]::UtcNow -lt $deadline);throw 'HYPERV_SQL_STORAGE_ACCEPTANCE_SQL_READINESS_TIMEOUT' }
function Get-SqlStorageObservation {
    param($Context)
    $defaults=Invoke-SqlRows $Context "DECLARE @b nvarchar(4000); EXEC master.dbo.xp_instance_regread N'HKEY_LOCAL_MACHINE',N'Software\Microsoft\MSSQLServer\MSSQLServer',N'BackupDirectory',@b OUTPUT; SELECT CAST(SERVERPROPERTY('InstanceDefaultDataPath') AS nvarchar(4000)) AS DefaultData,CAST(SERVERPROPERTY('InstanceDefaultLogPath') AS nvarchar(4000)) AS DefaultLog,@b AS BackupDirectory,CONVERT(varchar(33),sqlserver_start_time,126) AS SqlStartTime FROM sys.dm_os_sys_info;"
    $tempdb=Invoke-SqlRows $Context "SELECT name AS LogicalName,physical_name AS SqlPhysicalPath,CONVERT(varchar(20),size/128) AS SizeMB,CASE WHEN is_percent_growth=1 THEN CONVERT(varchar(20),growth)+'%' ELSE CONVERT(varchar(20),growth/128)+'MB' END AS Growth,CONVERT(varchar(20),type) AS FileType FROM sys.master_files WHERE database_id=2 ORDER BY file_id;"
    [pscustomobject]@{Defaults=$defaults[0];TempDb=@($tempdb)}
}
function Get-GuestBootTime { param($Context,$Credential) [string](Invoke-Private {param($Name,$Id,$Scope,$Cred)$value=Invoke-HyperVPowerShellDirect -VMName $Name -ExpectedRunId $Id -ExpectedScopeId $Scope -Credential $Cred -ScriptBlock {(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')};[string]@($value)[-1]} @([string]$Context.Instance.vmName,[string]$Context.Run.runId,[string]$Context.Run.scopeId,$Credential)) }
function Test-ScopedTemporaryRoot { param([string]$Path) $resolved=[IO.Path]::GetFullPath($Path).TrimEnd('\');$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\');[IO.Directory]::GetParent($resolved).FullName.TrimEnd('\').Equals($temp,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($resolved) -match '^sql-lab-hv-sql-storage-[a-f0-9]{32}$' }
function New-StorageManifest {
    param([string]$Path,[string]$Name)
    $value=[ordered]@{'$schema'=(Join-Path $repoRoot 'Schemas/lab-manifest.schema.json');name=$Name;automation=[ordered]@{mode='unattended'};instances=@([ordered]@{id='primary';version='2025';provider='hyperv';os='windows';profile='standard';autostart='off';network=[ordered]@{intent='hostOnly';exposure='host'};windowsActivation=[ordered]@{ContractVersion='SqlServerLab.WindowsActivationIntent/1.0';Strategy='VerifyOnly';EgressPolicy='Denied'};hyperv=[ordered]@{memoryStartupMB=6144;processorCount=4;sqlPort=1433;guestPasswordMode='prompt'};storageIntent=[ordered]@{contractVersion='SqlServerLab.StorageIntent/1.0';placementPolicy='logical-only';physicalIsolation='not-required';roles=[ordered]@{defaultData=[ordered]@{selector='default'};defaultLog=[ordered]@{selector='default'};backup=[ordered]@{selector='default'}};tempDb=[ordered]@{distribution='single-location';dataFileCount=4;dataLocationSelectors=@('default');logPlacement=[ordered]@{selector='default';logicalName='templog';fileName='templog.ldf';sizeMB=64;growth='32MB'}};databaseFiles=@();restoreRules=@()}})}
    $value|ConvertTo-Json -Depth 30|Set-Content -LiteralPath $Path -Encoding utf8
}
function New-OwnedRun {
    param([string]$ManifestPath,[securestring]$SqlPassword)
    $helper=Join-Path $repoRoot 'Tests/Common/HyperVResourceAcceptanceSlotClone.ps1'
    Invoke-Private {param($Helper,$Source,$Path,$Op,$Media,$Edition,$Sql,$Root). $Helper;New-HyperVResourceAcceptanceSlotClone -SourceRunId $Source -ManifestPath $Path -OperationId $Op -MediaRoot $Media -MediaEdition $Edition -SqlPassword $Sql -StateRoot $Root} @($helper,$CloneSourceRunId,$ManifestPath,$OperationId,$MediaRoot,$MediaEdition,$SqlPassword,$StateRoot)
}

try {
    $mutexAcquired=$mutex.WaitOne([TimeSpan]::FromMinutes(15));if(-not $mutexAcquired){throw 'HYPERV_SQL_STORAGE_ACCEPTANCE_HOST_LOCK_TIMEOUT'}
    $principal=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent());Assert-HyperVSqlStorageAcceptance $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) 'Runner arbeitet erhoeht'
    Get-Command Get-VM,Get-VHD,Get-VMHardDiskDrive -ErrorAction Stop|Out-Null
    $null=New-Item -ItemType Directory -Path $testRoot -Force;$module=Import-Module $modulePath -Force -PassThru
    if(-not $StateRoot){$StateRoot=Invoke-Private {Get-LabStateRoot}};$env:SQL_SERVER_LAB_STATE=$StateRoot
    $manifestPath=Join-Path $testRoot 'sql-storage.json';New-StorageManifest $manifestPath ('hv-sql-storage-'+[guid]::NewGuid().ToString('N').Substring(0,8))
    Assert-HyperVSqlStorageAcceptance (Test-SqlServerLabManifest -Path $manifestPath).IsValid 'VerifyOnly-Manifest mit gebundenem Storage-Intent ist gueltig'
    $script:saPassword=Invoke-Private {New-HyperVSqlUnattendedPassword};$lab=New-OwnedRun $manifestPath $script:saPassword
    Assert-HyperVSqlStorageAcceptance ([string]$lab.State -eq 'RUNNING') 'Operationseigener SQL-2025-Clone ist bereit'
    $context=Get-Context $lab.RunId;$managed=Get-OwnedManagedVm $context
    Assert-HyperVSqlStorageAcceptance (@($managed.Identity.additionalDrives).Count -eq 0) 'Clone beginnt ohne run-eigene Storage-Lanes'
    $intent=(Get-Content -LiteralPath $manifestPath -Raw -Encoding utf8|ConvertFrom-Json -Depth 30).instances[0].storageIntent
    $bound=Invoke-Private {param($Intent,$RunId,$Name)New-LabStorageBoundPlan -StorageIntent $Intent -RunId $RunId -LabName $Name -InstanceId primary -Provider hyperv} @($intent,[string]$lab.RunId,[string]$lab.RunId)
    Assert-HyperVSqlStorageAcceptance ([string]$bound.Status -eq 'READY') 'Storage-Intent ist für den operationseigenen Run gebunden'
    Invoke-Private {param($Path,$Plan)Write-LabArtifactJsonAtomic -Path $Path -InputObject $Plan} @((Join-Path $context.RunDirectory 'storage-bound-plan.json'),$bound)
    $hostJournal=Join-Path $context.RunDirectory 'hyperv-storage-reconcile.local.journal.json'
    $hostPlan=Get-SqlServerLabReconcilePlan -RunId $lab.RunId -HyperVStorage -InstanceId primary -StateRoot $StateRoot
    $hostReasonCodes=@($hostPlan.ReasonCodes|Where-Object{$_}) -join ','
    Assert-HyperVSqlStorageAcceptance ([string]$hostPlan.HighestChangeClass -in @('live','restart') -and @($hostPlan.Actions).Count -eq 1 -and [string]$hostPlan.Actions[0].Operation -eq 'RepairHyperVStorage' -and @($hostPlan.Diff).Count -ge 1) "HV-603 plant die gebundene Storage-Lane eigentumsgeprueft: $hostReasonCodes"
    $hostWhatIf=Invoke-SqlServerLabReconcileAction -RunId $lab.RunId -RepairHyperVStorage -InstanceId primary -StateRoot $StateRoot -WhatIf
    Assert-HyperVSqlStorageAcceptance ([string]$hostWhatIf.ExecutionSummary.Status -eq 'WOULD_EXECUTE' -and -not(Test-Path -LiteralPath $hostJournal)) 'HV-603-WhatIf schreibt weder VHDX noch Journal'
    $hostResult=Invoke-SqlServerLabReconcileAction -RunId $lab.RunId -RepairHyperVStorage -InstanceId primary -StateRoot $StateRoot -Confirm:$false
    Assert-HyperVSqlStorageAcceptance ([string]$hostResult.ExecutionSummary.Status -eq 'SUCCEEDED') 'HV-603 erstellt die operationseigenen Storage-Lanes'
    $context=Get-Context $lab.RunId;$managed=Get-OwnedManagedVm $context;$ownedPaths=@([string]$managed.Identity.childVhdxPath)+@($managed.Identity.additionalDrives|ForEach-Object{[string]$_.path})
    $hostNoOp=Get-SqlServerLabReconcilePlan -RunId $lab.RunId -HyperVStorage -InstanceId primary -StateRoot $StateRoot
    Assert-HyperVSqlStorageAcceptance ($hostNoOp.IsNoOp -and @($hostNoOp.Actions).Count -eq 0 -and @($managed.Identity.guestDriveInitialization).Count -eq 1) 'HV-603 ist vor SQL-Mutation No-op und besitzt den gebundenen Gast-Receipt'
    if([string]$managed.VM.State -eq 'Off'){
        Invoke-Private {param($VM)Start-VM -VM $VM -ErrorAction Stop} @($managed.VM)
        $context=Get-Context $lab.RunId
    }
    Assert-HyperVSqlStorageAcceptance (Wait-StorageSqlReady $context) 'SQL ist nach Host-Storage-Reconcile bereit'
    $receiptPath=Join-Path $context.RunDirectory 'storage-runtime-receipt.json'
    Assert-HyperVSqlStorageAcceptance (-not(Test-Path -LiteralPath $receiptPath -PathType Leaf)) 'HV-603 persistiert noch keinen SQL-Runtime-Receipt'
    $before=Get-SqlStorageObservation $context;$sqlPlan=Get-SqlServerLabReconcilePlan -RunId $lab.RunId -HyperVSqlStorage -InstanceId primary -StateRoot $StateRoot
    Assert-HyperVSqlStorageAcceptance ([string]$sqlPlan.HighestChangeClass -eq 'restart' -and @($sqlPlan.Actions).Count -eq 1 -and $sqlPlan.Actions[0].RequiresSqlServiceRestart -and -not $sqlPlan.MutationAllowed) 'HV-603A plant receiptgebundene SQL-Pfad-Reparatur als SQL-Dienstrestart'
    Assert-HyperVSqlStorageAcceptance (($sqlPlan|ConvertTo-Json -Depth 30) -notmatch 'SQLData|SQLLog|private-|\.vhdx') 'Oeffentlicher SQL-Storage-Plan bleibt hostwertfrei'
    $sqlWhatIf=Invoke-SqlServerLabReconcileAction -RunId $lab.RunId -RepairHyperVSqlStorage -InstanceId primary -StateRoot $StateRoot -WhatIf;$afterWhatIf=Get-SqlStorageObservation $context
    Assert-HyperVSqlStorageAcceptance ([string]$sqlWhatIf.ExecutionSummary.Status -eq 'WOULD_EXECUTE' -and -not(Test-Path -LiteralPath $receiptPath -PathType Leaf) -and $afterWhatIf.Defaults.SqlStartTime -eq $before.Defaults.SqlStartTime) 'HV-603A-WhatIf veraendert weder SQL noch Runtime-Receipt'
    $guestCredential=[PSCredential]::new('Administrator',(Invoke-Private {param($RunDirectory)(Get-LabSecret -Path $RunDirectory -Name 'guest-administrator-password')} @($context.RunDirectory)))
    $bootBefore=Get-GuestBootTime $context $guestCredential;$sqlStartBefore=$before.Defaults.SqlStartTime
    $result=Invoke-SqlServerLabReconcileAction -RunId $lab.RunId -RepairHyperVSqlStorage -InstanceId primary -StateRoot $StateRoot -Confirm:$false
    $after=Get-SqlStorageObservation $context;$bootAfter=Get-GuestBootTime $context $guestCredential;$receiptAfter=Get-Content -LiteralPath $receiptPath -Raw -Encoding utf8|ConvertFrom-Json -Depth 40
    $expected=@($receiptAfter.FileBindings);$normalizePath={param([string]$Path) ([string]$Path).Trim().TrimEnd('\','/')}
    $defaultSource=@(
        [pscustomobject]@{Role='default-data';Expected=[string](@($expected|Where-Object Role -eq 'default-data')[0].SqlPhysicalPath);Actual=[string]$after.Defaults.DefaultData}
        [pscustomobject]@{Role='default-log';Expected=[string](@($expected|Where-Object Role -eq 'default-log')[0].SqlPhysicalPath);Actual=[string]$after.Defaults.DefaultLog}
        [pscustomobject]@{Role='backup';Expected=[string](@($expected|Where-Object Role -eq 'backup')[0].SqlPhysicalPath);Actual=[string]$after.Defaults.BackupDirectory}
    )
    $defaultEvidence=@($defaultSource|ForEach-Object{[pscustomobject]@{Role=$_.Role;Exact=([string]$_.Expected).Equals([string]$_.Actual,[StringComparison]::OrdinalIgnoreCase);Normalized=((&$normalizePath $_.Expected).Equals((&$normalizePath $_.Actual),[StringComparison]::OrdinalIgnoreCase));ExpectedLength=$_.Expected.Length;ActualLength=$_.Actual.Length}})
    $tempEvidence=@($expected|Where-Object Role -in @('tempdb-data','tempdb-log')|ForEach-Object{$expectedFile=$_;$actual=@($after.TempDb|Where-Object LogicalName -eq [string]$expectedFile.LogicalName);$actualPath=if($actual.Count -eq 1){[string]$actual[0].SqlPhysicalPath}else{''};[pscustomobject]@{LogicalName=[string]$expectedFile.LogicalName;Count=$actual.Count;Exact=($actual.Count -eq 1 -and $actualPath.Equals([string]$expectedFile.SqlPhysicalPath,[StringComparison]::OrdinalIgnoreCase));Normalized=($actual.Count -eq 1 -and (&$normalizePath $actualPath).Equals((&$normalizePath ([string]$expectedFile.SqlPhysicalPath)),[StringComparison]::OrdinalIgnoreCase));ExpectedLength=([string]$expectedFile.SqlPhysicalPath).Length;ActualLength=$actualPath.Length}})
    $defaultsOk=@($defaultEvidence|Where-Object Exact).Count -eq $defaultEvidence.Count;$tempOk=@($tempEvidence|Where-Object Exact).Count -eq $tempEvidence.Count
    $resultOk=[string]$result.ExecutionSummary.Status -eq 'SUCCEEDED';$receiptResultOk=[string]$result.ExecutionPlan[0].Result.ReceiptStatus -eq 'VERIFIED';$receiptOk=[string]$receiptAfter.Status -eq 'VERIFIED';$sqlRestarted=$after.Defaults.SqlStartTime -ne $sqlStartBefore;$guestBootUnchanged=$bootAfter -eq $bootBefore;$vmRunning=[string]((Get-OwnedManagedVm $context).VM.State) -eq 'Running'
    $convergenceEvidence="result=$resultOk receiptResult=$receiptResultOk receipt=$receiptOk defaults=$defaultsOk tempdb=$tempOk sqlRestarted=$sqlRestarted guestBootUnchanged=$guestBootUnchanged vmRunning=$vmRunning expectedFiles=$(@($expected).Count) observedTempDb=$(@($after.TempDb).Count) defaultsDetail=$((@($defaultEvidence|ForEach-Object{"$($_.Role):exact=$($_.Exact),normalized=$($_.Normalized),length=$($_.ExpectedLength)/$($_.ActualLength)"}) -join ';')) tempdbDetail=$((@($tempEvidence|ForEach-Object{"$($_.LogicalName):count=$($_.Count),exact=$($_.Exact),normalized=$($_.Normalized),length=$($_.ExpectedLength)/$($_.ActualLength)"}) -join ';'))"
    Assert-HyperVSqlStorageAcceptance ($resultOk -and $receiptResultOk -and $receiptOk -and $defaultsOk -and $tempOk -and $sqlRestarted -and $guestBootUnchanged -and $vmRunning) "Receipt, SQL-Defaults und TempDB konvergieren nach SQL-Dienstrestart ohne VM-Neustart: $convergenceEvidence"
    $noOp=Get-SqlServerLabReconcilePlan -RunId $lab.RunId -HyperVSqlStorage -InstanceId primary -StateRoot $StateRoot
    Assert-HyperVSqlStorageAcceptance ($noOp.IsNoOp -and @($noOp.Actions).Count -eq 0) 'Wiederholter HV-603A-Plan ist No-op'
    $cleanup=Remove-SqlServerLab -RunId $lab.RunId -StateRoot $StateRoot -Force -Confirm:$false;Assert-HyperVSqlStorageAcceptance ([string]$cleanup.Status -in @('REMOVED','COMPLETED')) 'Operationseigener Run wurde scopegebunden entfernt';$lab=$null;foreach($path in $ownedPaths){Assert-HyperVSqlStorageAcceptance (-not(Test-Path -LiteralPath $path)) 'Run-eigene VHDX wurde entfernt'};$completed=$true
}
catch { if($lab -and $KeepOnFailure){Write-Host "RECOVERY_RUN_ID=$([string]$lab.RunId)";Write-Host "RECOVERY_MANIFEST_ROOT=$testRoot"};throw }
finally { $script:saPassword=$null;if($lab -and -not $KeepOnFailure){try{Remove-SqlServerLab -RunId ([string]$lab.RunId) -StateRoot $StateRoot -Force -Confirm:$false|Out-Null}catch{Write-Warning 'HYPERV_SQL_STORAGE_ACCEPTANCE_OWNED_CLEANUP_FAILED'}};if(($completed -or -not $KeepOnFailure) -and (Test-Path $testRoot)){if(-not(Test-ScopedTemporaryRoot $testRoot)){throw 'HYPERV_SQL_STORAGE_ACCEPTANCE_TEMP_SCOPE_INVALID'};Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue};if($previousStateRoot){$env:SQL_SERVER_LAB_STATE=$previousStateRoot}else{Remove-Item Env:SQL_SERVER_LAB_STATE -ErrorAction SilentlyContinue};if($mutexAcquired){$mutex.ReleaseMutex()};$mutex.Dispose() }
Write-Host 'Native Hyper-V-SQL-Storage-Reconcile-Akzeptanz erfolgreich.' -ForegroundColor Green
