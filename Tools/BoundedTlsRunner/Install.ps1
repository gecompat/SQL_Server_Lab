#Requires -Version 7.5
#Requires -RunAsAdministrator
<# .SYNOPSIS
    Installiert genau eine befristete, fest gebundene Windows-TLS-Testaufgabe.
#>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$PlanPath,[Parameter(Mandatory)][ValidatePattern('\A[0-9A-F]{64}\z')][string]$ExpectedPlanSha256)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')
Assert-BoundedTlsAdministrator
$plan=Read-BoundedTlsPinnedJson $PlanPath $ExpectedPlanSha256
Assert-BoundedTlsPlan $plan
if([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -cne $plan.ActorSid){throw 'BOUNDED_TLS_INSTALL_ACTOR_CHANGED'}
Assert-BoundedTlsBinaryPins $plan
$environmentNames=@('PATH','PSModulePath','GIT_CONFIG_NOSYSTEM','GIT_CONFIG_GLOBAL','GIT_CONFIG_SYSTEM','DOTNET_EnableDiagnostics',
    'DOTNET_STARTUP_HOOKS','DOTNET_ADDITIONAL_DEPS','DOTNET_SHARED_STORE','DOTNET_ROOT','DOTNET_ROOT_X64','CORECLR_ENABLE_PROFILING','CORECLR_PROFILER',
    'CORECLR_PROFILER_PATH','CORECLR_PROFILER_PATH_32','CORECLR_PROFILER_PATH_64','COR_ENABLE_PROFILING','COR_PROFILER','COR_PROFILER_PATH','COR_PROFILER_PATH_32','COR_PROFILER_PATH_64')+@(Get-ChildItem Env:|Where-Object Name -like 'GIT_*'|Select-Object -ExpandProperty Name)
$savedEnvironment=@{};foreach($name in $environmentNames){$savedEnvironment[$name]=[Environment]::GetEnvironmentVariable($name,'Process')}
Set-BoundedTlsProcessEnvironment $plan
$taskCreated=$false;$rootCreated=$false
try{
$package=@(Get-AppxPackage|Where-Object PackageFamilyName -CEQ $plan.PackageFamilyName)
if($package.Count -ne 1 -or @((Get-AppxPackageManifest -Package $package[0].PackageFullName).Package.Applications.Application|Where-Object Id -CEQ $plan.AppId).Count -ne 1){throw 'BOUNDED_TLS_REGISTERED_PACKAGE_REQUIRED'}
$base=Split-Path $plan.InstallRoot -Parent
if(-not (Test-Path -LiteralPath $base)){
    $null=New-Item -ItemType Directory -Path $base
    Set-BoundedTlsAccess $base $plan.ActorSid -Directory
}else{
    Assert-BoundedTlsAccess $base $plan.ActorSid
}
if(Test-Path -LiteralPath $plan.InstallRoot){throw 'BOUNDED_TLS_NEW_INSTALL_ROOT_REQUIRED'}
$null=New-Item -ItemType Directory -Path $plan.InstallRoot
$rootCreated=$true
Set-BoundedTlsAccess $plan.InstallRoot $plan.ActorSid -Directory
Set-BoundedTlsLabel $plan.InstallRoot
$source=Join-Path $plan.InstallRoot 'source'
$null=New-Item -ItemType Directory -Path $source
foreach($row in $plan.Sources){
    $from=Assert-BoundedTlsSourceRow $row $plan.StageSourceRoot
    $item=Get-Item -LiteralPath $from -Force
    if($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'BOUNDED_TLS_SOURCE_INVALID'}
    $inputStream=[IO.File]::Open($from,'Open','Read','Read')
    try{
        if([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($inputStream)) -cne $row.Sha256){throw 'BOUNDED_TLS_STAGE_SOURCE_CHANGED'}
        $inputStream.Position=0;$to=Join-Path $source $row.RelativePath
        $null=New-Item -ItemType Directory -Path (Split-Path $to -Parent) -Force
        $outputStream=[IO.File]::Open($to,'CreateNew','Write','None')
        try{$inputStream.CopyTo($outputStream);$outputStream.Flush($true)}finally{$outputStream.Dispose()}
    }finally{$inputStream.Dispose()}
}
# A new local index contains no inherited aliases, hooks, remote or credentials.
& $plan.Binaries.Git.Path -C $source init --initial-branch=frozen --quiet
if($LASTEXITCODE -ne 0){throw 'BOUNDED_TLS_SNAPSHOT_INDEX_FAILED'}
& $plan.Binaries.Git.Path -C $source config core.autocrlf false
& $plan.Binaries.Git.Path -C $source config core.fsmonitor false
& $plan.Binaries.Git.Path -C $source add --all
if($LASTEXITCODE -ne 0){throw 'BOUNDED_TLS_SNAPSHOT_INDEX_FAILED'}
foreach($item in @(Get-ChildItem -LiteralPath $source -Force -Recurse|Sort-Object FullName -Descending)){
    Set-BoundedTlsAccess $item.FullName $plan.ActorSid -Directory:$item.PSIsContainer
}
Set-BoundedTlsAccess $source $plan.ActorSid -Directory
$requests=Join-Path $plan.InstallRoot 'requests';$null=New-Item -ItemType Directory -Path $requests
Set-BoundedTlsAccess $requests $plan.ActorSid -Directory -Requests
Set-BoundedTlsLabel $requests -Medium
$work=Join-Path $plan.InstallRoot 'work'
$module=Import-Module (Join-Path $source 'SqlServerLab.psd1') -Force -PassThru
& $module {param($p,$s)Initialize-LabTlsCaPrivateDirectory $p $s -NewOnly} $work $plan.ActorSid
Set-BoundedTlsLabel $work
$probe=Join-Path $work 'write-protection-probe.private.json'
& $module {param($p,$s)Write-LabTlsCaPrivateFile $p $s ([Text.Encoding]::UTF8.GetBytes('{"Probe":"NO_WRITE_UP"}'))} $probe $plan.ActorSid
# Deliberately no explicit file label: the ordinary controller must prove that
# the high parent/creator label is inherited by this exact private writer.
# Task Scheduler serializes second precision. Bind the lease to the same
# whole-second instant, so its one-shot expiry trigger cannot fire too early.
$now=[datetimeoffset]::FromUnixTimeSeconds([datetimeoffset]::UtcNow.ToUnixTimeSeconds())
$plan|Add-Member NoteProperty InstalledAtUtc $now.ToString('o')
$plan|Add-Member NoteProperty ExpiresUtc $now.AddMinutes(120).ToString('o')
$plan|Add-Member NoteProperty TaskName ('SQL_Server_Lab-BoundedTls-'+$plan.RunnerId)
Assert-BoundedTlsPlan $plan -Installed
$protectedPlan=Join-Path $plan.InstallRoot 'plan.private.json'
Write-BoundedTlsJson $protectedPlan $plan
Set-BoundedTlsAccess $protectedPlan $plan.ActorSid
$hash=Get-BoundedTlsHash $protectedPlan
Write-BoundedTlsJson (Join-Path $plan.InstallRoot 'state.private.json') @{Status='INSTALLED';Attempts=0;LastRequestId=$null;ConsumedRequestIds=@();Results=@()}
$clear=@('DOTNET_STARTUP_HOOKS','DOTNET_ADDITIONAL_DEPS','DOTNET_SHARED_STORE','DOTNET_ROOT','DOTNET_ROOT_X64','CORECLR_ENABLE_PROFILING','CORECLR_PROFILER','CORECLR_PROFILER_PATH','CORECLR_PROFILER_PATH_32','CORECLR_PROFILER_PATH_64','COR_ENABLE_PROFILING','COR_PROFILER','COR_PROFILER_PATH','COR_PROFILER_PATH_32','COR_PROFILER_PATH_64')
$lines=@('@echo off','setlocal DisableDelayedExpansion')+@($clear|ForEach-Object {'set "'+$_+'="'})
$lines+=@('set "DOTNET_EnableDiagnostics=0"')
$lines+=('"'+$plan.Binaries.PowerShell.Path+'" -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -File "'+(Join-Path $source 'Tools/BoundedTlsRunner/Invoke.ps1')+'" -PlanPath "'+$protectedPlan+'" -ExpectedPlanSha256 '+$hash+' -Mode Bootstrap')
$launch=Join-Path $plan.InstallRoot 'launch.cmd'
[IO.File]::WriteAllLines($launch,$lines,[Text.ASCIIEncoding]::new())
Set-BoundedTlsAccess $launch $plan.ActorSid
$scheduler=New-Object -ComObject Schedule.Service;$scheduler.Connect()
$definition=$scheduler.NewTask(0)
$definition.RegistrationInfo.Description='Fixed Windows TLS acceptance lease '+$plan.RunnerId
$definition.Principal.UserId=$plan.ActorSid;$definition.Principal.LogonType=3;$definition.Principal.RunLevel=1
$definition.Settings.ExecutionTimeLimit='PT0S';$definition.Settings.MultipleInstances=2
$definition.Settings.AllowHardTerminate=$false
$definition.Settings.DisallowStartIfOnBatteries=$false;$definition.Settings.StopIfGoingOnBatteries=$false
$definition.Settings.StartWhenAvailable=$true;$definition.Settings.Hidden=$true;$definition.Settings.AllowDemandStart=$true
$trigger=$definition.Triggers.Create(1);$trigger.StartBoundary=$now.AddMinutes(120).UtcDateTime.ToString('s')+'Z';$trigger.Enabled=$true
$action=$definition.Actions.Create(0);$action.Path=Join-Path ([Environment]::GetFolderPath('Windows')) 'System32/cmd.exe';$action.Arguments='/d /s /c ""'+$launch+'""'
# TASK_CREATE | TASK_DONT_ADD_PRINCIPAL_ACE: permissions are atomic; no temporary
# full-control grant to the unelevated principal before tightening the task.
$null=$scheduler.GetFolder('\').RegisterTaskDefinition($plan.TaskName,$definition,18,$plan.ActorSid,$null,3,(Get-BoundedTlsTaskSddl $plan.ActorSid))
$taskCreated=$true
Write-BoundedTlsJson (Join-Path $plan.InstallRoot 'installed.private.json') @{Status='INSTALLED';RunnerId=$plan.RunnerId;PlanSha256=$hash;TaskName=$plan.TaskName;ExpiresUtc=$plan.ExpiresUtc}
[pscustomobject]@{Status='INSTALLED';RunnerId=$plan.RunnerId;TaskName=$plan.TaskName;ExpiresUtc=$plan.ExpiresUtc}
}catch{
    $originalFailure=$_
    $cleanup='NO_TASK_CREATED'
    if($taskCreated){
        try{
            $task=Get-ScheduledTask -TaskName $plan.TaskName -ErrorAction Stop
            if(@($task.Actions).Count -ne 1 -or $task.Actions[0].Arguments -cne ('/d /s /c ""'+(Join-Path $plan.InstallRoot 'launch.cmd')+'""')){throw 'BOUNDED_TLS_INSTALL_TASK_DRIFT'}
            Unregister-ScheduledTask -TaskName $plan.TaskName -Confirm:$false;$cleanup='OWN_TASK_REMOVED'
        }catch{$cleanup='RECOVERY_REQUIRED_OWN_TASK'}
    }
    if($rootCreated){Write-BoundedTlsJson (Join-Path $plan.InstallRoot 'install-failure.private.json') @{Status='FAIL';Cleanup=$cleanup;SourceRetained=$true;Error=$originalFailure.Exception.ToString()}}
    throw $originalFailure
}finally{
    foreach($name in $savedEnvironment.Keys){[Environment]::SetEnvironmentVariable($name,$savedEnvironment[$name],'Process')}
}
