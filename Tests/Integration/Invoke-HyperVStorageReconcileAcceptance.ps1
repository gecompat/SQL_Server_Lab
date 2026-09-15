#Requires -Version 7.2
<#
.SYNOPSIS
    Runs the bounded native HV-603 host-storage reconcile acceptance.
.DESCRIPTION
    Creates one operation-owned clone of an explicitly selected stopped Windows
    2025 slot, verifies the initial
    manifest-bound SCSI additions and proves read-only planning, WhatIf,
    repair, guest receipt, restart/readiness and no-op.  SQL file-path
    relocation/rebinding (HV-603A) is deliberately out
    of scope.  The product's controlled HOST_APPLIED interruption/resume
    contract remains covered by Invoke-HyperVStorageReconcileChecks.ps1; this
    native runner does not add a production fault-injection seam.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$CloneSourceRunId,
    [string]$MediaRoot='D:\Lab_Base',
    [ValidateSet('Enterprise','Standard','Eval')][string]$MediaEdition='Enterprise',
    [string]$StateRoot,
    [string]$OperationId=('local-hv-storage-'+[guid]::NewGuid().ToString('N')),
    [switch]$KeepOnFailure
)
$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$modulePath=Join-Path $repoRoot 'SqlServerLab.psd1'
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-hv-storage-'+[guid]::NewGuid().ToString('N'))
$previousStateRoot=$env:SQL_SERVER_LAB_STATE
$module=$null;$lab=$null;$ownedPaths=@();$completed=$false;$script:saPassword=$null
$mutex=[Threading.Mutex]::new($false,'Global\SQL_Server_Lab_HyperV_Storage_Reconcile_Acceptance');$mutexAcquired=$false

function Assert-HyperVStorageAcceptance { param([bool]$Condition,[string]$Description) if(-not $Condition){throw "HYPERV_STORAGE_ACCEPTANCE_FAILED: $Description"};Write-Host "PASS: $Description" -ForegroundColor Green }
function Invoke-Private { param([scriptblock]$ScriptBlock,[object[]]$Arguments=@()) & $module $ScriptBlock @Arguments }
function Get-Context { param([string]$RunId) Invoke-Private {param($Id,$Root)Get-HyperVLabWorkflowRun -RunId $Id -StateRoot $Root} @($RunId,$StateRoot) }
function Get-OwnedManagedVm { param($Context) Invoke-Private {param($Name,$Id,$Scope)Get-HyperVManagedVM -VMName $Name -ExpectedRunId $Id -ExpectedScopeId $Scope} @([string]$Context.Instance.vmName,[string]$Context.Run.runId,[string]$Context.Run.scopeId) }
function New-SqlConnection { param($Context) if(-not $script:saPassword.IsReadOnly()){$script:saPassword.MakeReadOnly()};$c=[Data.SqlClient.SqlConnection]::new();$c.ConnectionString="Server=$([string]$Context.Instance.host),$([int]$Context.Instance.port);Database=master;Encrypt=True;TrustServerCertificate=True;Connect Timeout=30;";$c.Credential=[Data.SqlClient.SqlCredential]::new('sa',$script:saPassword);$c }
function Wait-StorageSqlReady { param($Context) $deadline=[datetime]::UtcNow.AddMinutes(5);do{try{$c=New-SqlConnection $Context;$c.Open();$cmd=$c.CreateCommand();$cmd.CommandText='SELECT 1;';if([int]$cmd.ExecuteScalar() -eq 1){return $true}}catch{}finally{if($c){$c.Dispose()}};Start-Sleep -Seconds 5}while([datetime]::UtcNow -lt $deadline);throw 'HYPERV_STORAGE_ACCEPTANCE_SQL_READINESS_TIMEOUT' }
function Test-ScopedTemporaryRoot { param([string]$Path) $resolved=[IO.Path]::GetFullPath($Path).TrimEnd('\');$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\');[IO.Directory]::GetParent($resolved).FullName.TrimEnd('\').Equals($temp,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($resolved) -match '^sql-lab-hv-storage-[a-f0-9]{32}$' }
function New-StorageManifest {
    param([string]$Path,[string]$Name,[string]$PreparedArtifactId)
    $value=[ordered]@{'$schema'=(Join-Path $repoRoot 'Schemas/lab-manifest.schema.json');name=$Name;automation=[ordered]@{mode='unattended'};instances=@([ordered]@{id='primary';version='2025';provider='hyperv';os='windows';profile='standard';autostart='off';network=[ordered]@{intent='hostOnly';exposure='host'};windowsActivation=[ordered]@{ContractVersion='SqlServerLab.WindowsActivationIntent/1.0';Strategy='EvaluationOnline';EgressPolicy='AllowTemporary'};hyperv=[ordered]@{preparedImageId=$PreparedArtifactId;memoryStartupMB=6144;processorCount=4;sqlPort=1433;guestPasswordMode='prompt'};drives=@([ordered]@{id='data';containerPath='E:\SQLData';sizeLimitGB=4;type='ssd'},[ordered]@{id='log';containerPath='L:\SQLLog';sizeLimitGB=2;type='ssd'})})}
    if($CloneSourceRunId){$value.instances[0].hyperv.Remove('preparedImageId');$value.instances[0].windowsActivation.Strategy='VerifyOnly';$value.instances[0].windowsActivation.EgressPolicy='Denied'}
    $value|ConvertTo-Json -Depth 30|Set-Content -LiteralPath $Path -Encoding utf8
}
function New-OwnedRun {
    param([string]$ManifestPath,[securestring]$GuestPassword,[securestring]$SqlPassword)
    if($CloneSourceRunId){
        $helper=Join-Path $repoRoot 'Tests/Common/HyperVResourceAcceptanceSlotClone.ps1'
        return Invoke-Private {param($Helper,$Source,$Path,$Op,$Media,$Edition,$Sql,$Root). $Helper;New-HyperVResourceAcceptanceSlotClone -SourceRunId $Source -ManifestPath $Path -OperationId $Op -MediaRoot $Media -MediaEdition $Edition -SqlPassword $Sql -StateRoot $Root} @($helper,$CloneSourceRunId,$ManifestPath,$OperationId,$MediaRoot,$MediaEdition,$SqlPassword,$StateRoot)
    }
    Invoke-Private {param($Path,$Op,$Guest,$Sql,$Root)Invoke-WithLabWorkflowOperationContext -OperationId $Op -ScriptBlock {New-SqlServerLab -Manifest $Path -GuestPassword $Guest -SqlSaPassword $Sql -NonInteractive -StateRoot $Root -Region AT -SystemLocale de-AT -UiLanguage en-US -InputLocale '0407:00000407' -TimeZone 'W. Europe Standard Time'}} @($ManifestPath,$OperationId,$GuestPassword,$SqlPassword,$StateRoot)
}

try {
    $mutexAcquired=$mutex.WaitOne([TimeSpan]::FromMinutes(15));if(-not $mutexAcquired){throw 'HYPERV_STORAGE_ACCEPTANCE_HOST_LOCK_TIMEOUT'}
    $principal=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent());Assert-HyperVStorageAcceptance $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) 'Runner arbeitet erhoeht'
    Get-Command Get-VM,Get-VHD,Get-VMHardDiskDrive -ErrorAction Stop|Out-Null
    $null=New-Item -ItemType Directory -Path $testRoot -Force
    $module=Import-Module $modulePath -Force -PassThru
    if(-not $StateRoot){$StateRoot=Invoke-Private {Get-LabStateRoot}};$env:SQL_SERVER_LAB_STATE=$StateRoot
    $manifestPath=Join-Path $testRoot 'storage.json';New-StorageManifest $manifestPath ('hv-storage-'+[guid]::NewGuid().ToString('N').Substring(0,8)) $null
    Assert-HyperVStorageAcceptance (Test-SqlServerLabManifest -Path $manifestPath).IsValid 'Manifest mit zwei gebundenen SCSI-Lanes ist gueltig'
    $guest=Invoke-Private {New-HyperVSqlUnattendedPassword};$script:saPassword=Invoke-Private {New-HyperVSqlUnattendedPassword}
    $lab=New-OwnedRun $manifestPath $guest $script:saPassword;Assert-HyperVStorageAcceptance ([string]$lab.State -eq 'RUNNING') 'Isolierter operationseigener SQL-2025-Run ist bereit'
    $context=Get-Context $lab.RunId;$managed=Get-OwnedManagedVm $context;$initial=@($managed.Identity.additionalDrives)
    if($CloneSourceRunId){
        $addJournal=Join-Path $context.RunDirectory 'hyperv-storage-reconcile.local.journal.json';$addPlan=Get-SqlServerLabReconcilePlan -RunId $lab.RunId -HyperVStorage -InstanceId primary -StateRoot $StateRoot
        Assert-HyperVStorageAcceptance ($initial.Count -eq 0 -and [string]$addPlan.HighestChangeClass -eq 'live' -and @($addPlan.Diff.Kind|Sort-Object -Unique) -join ',' -eq 'add') 'Operationseigener Windows-Clone plant die manifestgebundenen SCSI-Additionen'
        $addWhatIf=Invoke-SqlServerLabReconcileAction -RunId $lab.RunId -RepairHyperVStorage -InstanceId primary -StateRoot $StateRoot -WhatIf
        Assert-HyperVStorageAcceptance ([string]$addWhatIf.ExecutionSummary.Status -eq 'WOULD_EXECUTE' -and -not(Test-Path -LiteralPath $addJournal)) 'Add-WhatIf schreibt weder VHDX noch Journal'
        $addResult=Invoke-SqlServerLabReconcileAction -RunId $lab.RunId -RepairHyperVStorage -InstanceId primary -StateRoot $StateRoot -Confirm:$false
        $context=Get-Context $lab.RunId;$managed=Get-OwnedManagedVm $context;$initial=@($managed.Identity.additionalDrives)
        Assert-HyperVStorageAcceptance ([string]$addResult.ExecutionSummary.Status -eq 'SUCCEEDED' -and $initial.Count -eq 2) 'Clone-Add-Reconcile vervollstaendigt die zwei verwalteten Storage-Lanes'
    }
    $ownedPaths=@([string]$managed.Identity.childVhdxPath)+@($managed.Identity.additionalDrives|ForEach-Object{[string]$_.path});$attachments=@(Get-VMHardDiskDrive -VM $managed.VM -ErrorAction Stop)
    $data=@($initial|Where-Object id -eq 'data')[0];$log=@($initial|Where-Object id -eq 'log')[0]
    Assert-HyperVStorageAcceptance ($initial.Count -eq 2 -and [long]$data.sizeBytes -eq 4GB -and [long]$log.sizeBytes -eq 2GB -and @($attachments|Where-Object{[int]$_.ControllerNumber -eq 0 -and [int]$_.ControllerLocation -in @(1,2)}).Count -eq 2 -and @($initial|Where-Object{[string]$_.diskIdentifier -notmatch '^[A-Fa-f0-9-]{36}$'}).Count -eq 0) 'Manifestgebundene SCSI-Additionen besitzen Host-VHDX, feste Slots und Disk-Identitaeten'
    $guestReceipts=@($managed.Identity.guestDriveInitialization);$connection=Get-Content (Join-Path $context.RunDirectory 'connection-info.json') -Raw|ConvertFrom-Json -Depth 30
    Assert-HyperVStorageAcceptance (@($guestReceipts|Where-Object{[string]$_.id -in @('data','log') -and [string]$_.status -in @('INITIALIZED','VERIFIED','EXTENDED') -and [long]$_.diskSizeBytes -gt 0}).Count -eq 2 -and @($connection.instances[0].additionalDrives|Where-Object{[string]$_.id -in @('data','log') -and [string]$_.state -eq 'GUEST_VERIFIED'}).Count -eq 2) 'Gast-Receipt und Connection-Status binden beide Storage-Lanes verifiziert'
    Assert-HyperVStorageAcceptance (Wait-StorageSqlReady $context) 'SQL ist nach der Storage-Reparatur bereit'
    $vm=Get-OwnedManagedVm $context;Stop-VM -VM $vm.VM -Confirm:$false -ErrorAction Stop;Start-VM -VM $vm.VM -ErrorAction Stop;Assert-HyperVStorageAcceptance (Wait-StorageSqlReady $context) 'SQL ist nach VM-Neustart erneut bereit'
    $noOp=Get-SqlServerLabReconcilePlan -RunId $lab.RunId -HyperVStorage -InstanceId primary -StateRoot $StateRoot
    Assert-HyperVStorageAcceptance ($noOp.IsNoOp -and @($noOp.Actions).Count -eq 0) 'Wiederholter Storage-Plan ist No-op; Resume erzeugt keine doppelte Hostmutation'
    $cleanup=Remove-SqlServerLab -RunId $lab.RunId -StateRoot $StateRoot -Force -Confirm:$false;Assert-HyperVStorageAcceptance ([string]$cleanup.Status -in @('REMOVED','COMPLETED')) 'Operationseigener Run wurde scopegebunden entfernt';$lab=$null;foreach($path in $ownedPaths){Assert-HyperVStorageAcceptance (-not(Test-Path -LiteralPath $path)) 'Run-eigene VHDX wurde entfernt'};$completed=$true
}
catch { if($lab -and $KeepOnFailure){Write-Host "RECOVERY_RUN_ID=$([string]$lab.RunId)";Write-Host "RECOVERY_MANIFEST_ROOT=$testRoot"};throw }
finally {
    $script:saPassword=$null
    if($lab -and -not $KeepOnFailure){try{Remove-SqlServerLab -RunId ([string]$lab.RunId) -StateRoot $StateRoot -Force -Confirm:$false|Out-Null}catch{Write-Warning 'HYPERV_STORAGE_ACCEPTANCE_OWNED_CLEANUP_FAILED'}}
    if(($completed -or -not $KeepOnFailure) -and (Test-Path $testRoot)){if(-not(Test-ScopedTemporaryRoot $testRoot)){throw 'HYPERV_STORAGE_ACCEPTANCE_TEMP_SCOPE_INVALID'};Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue}
    if($previousStateRoot){$env:SQL_SERVER_LAB_STATE=$previousStateRoot}else{Remove-Item Env:SQL_SERVER_LAB_STATE -ErrorAction SilentlyContinue};if($mutexAcquired){$mutex.ReleaseMutex()};$mutex.Dispose()
}
Write-Host 'Native Hyper-V-Storage-Reconcile-Akzeptanz erfolgreich.' -ForegroundColor Green
