#Requires -Version 7.2
<#
.SYNOPSIS
    Richtet Lab-Storage fuer vorhandene native Linux-/WSL-Containerprovider ein.
.DESCRIPTION
    Kein Hyper-V-Aufruf. Plan prueft den ausgewaehlten Provider ohne Runtime-Start.
    Initialize registriert explizite lokale Datenroots; vorhandene Defaults bleiben
    erhalten. Pakete, Kernel, Bootparameter und globale WSL-Einstellungen werden
    nicht veraendert. Test erzeugt und entfernt einen eigenen SQL-Sprachtestlauf.
.PARAMETER Backend
    Native fuer lokale Linux-Ausfuehrung; Wsl fuer eine laufende explizite Distribution.
.PARAMETER Distribution
    Exakter WSL-Distributionsname. Kein automatischer Start oder Defaultwechsel.
.PARAMETER RepositoryRoot
    Repositorypfad im Ziel-Linux-System; unter WSL zwingend explizit.
.PARAMETER DataRoot
    Absoluter Linux-Pfad fuer registriertes Lab_Data.
.PARAMETER MediaRoot
    Absoluter Linux-Pfad fuer Lab_Base.
.EXAMPLE
    ./Tools/Invoke-SqlServerLabNativeLinuxContainerHost.ps1 -Action Plan -Provider podman
.EXAMPLE
    ./Tools/Invoke-SqlServerLabNativeLinuxContainerHost.ps1 -Action Initialize -Provider docker -DataRoot /srv/sql-lab/Lab_Data -MediaRoot /srv/sql-lab/Lab_Base
.EXAMPLE
    ./Tools/Invoke-SqlServerLabNativeLinuxContainerHost.ps1 -Backend Wsl -Distribution Ubuntu -RepositoryRoot /opt/sql-server-lab -Action Plan -Provider podman
.OUTPUTS
    NativeLinuxContainerHost-Entscheid oder providergebundene SQL-Test-Evidence.
#>
[CmdletBinding(SupportsShouldProcess,ConfirmImpact='Medium')]
param(
    [ValidateSet('Plan','Initialize','Test')][string]$Action='Plan',
    [ValidateSet('Native','Wsl')][string]$Backend='Native',
    [ValidateSet('docker','podman')][string]$Provider='docker',
    [string]$Distribution,[string]$RepositoryRoot,[string]$DataRoot,[string]$MediaRoot
)
$ErrorActionPreference='Stop'
$sourceRoot=Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'Common/LinuxContainerHostContract.ps1')
. (Join-Path $PSScriptRoot 'Common/NativeLinuxContainerHost.ps1')
if($Backend -eq 'Wsl'){
    if(-not $IsWindows){throw 'NATIVE_HOST_WSL_REQUIRES_WINDOWS'}
    if($Distribution -notmatch '^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,63}$'){throw 'NATIVE_HOST_EXPLICIT_WSL_DISTRIBUTION_REQUIRED'}
    $running=Invoke-LinuxContainerHostNative wsl @('--list','--running','--quiet') 20
    $names=@(($running.Output -replace "`0",'') -split '\r?\n'|ForEach-Object {$_.Trim()}|Where-Object {$_})
    if($running.ExitCode -ne 0 -or $Distribution -cnotin $names){throw 'NATIVE_HOST_WSL_NOT_RUNNING: Start the selected distribution explicitly first.'}
    # Read the kernel before requiring PowerShell or a checkout inside the distro.
    $probe=Invoke-LinuxContainerHostNative wsl @('-d',$Distribution,'-u','root','--exec','sh','-c','if test -r /proc/config.gz; then zcat /proc/config.gz; else exit 3; fi') 20
    if($probe.ExitCode -eq 0 -and $probe.Output -match '(?m)^# CONFIG_MEMCG_V1 is not set\s*$'){
        if($Action -ne 'Plan'){throw 'NATIVE_HOST_KERNEL_MEMCG_V1_DISABLED: Kernel compatibility must be resolved before initialization.'}
        [pscustomobject]@{Contract='SqlServerLab.NativeLinuxContainerHost/1.0';Provider=$Provider;
            Status='BLOCKED';Reasons=@('KERNEL_MEMCG_V1_DISABLED');RuntimeCheck='NOT_EXECUTED';
            RequiresHyperV=$false;SqlLanguageEvidence='NOT_EXECUTED';HostChanges='NONE'}
        return
    }
    if(-not $RepositoryRoot -or -not $RepositoryRoot.StartsWith('/') -or $RepositoryRoot -match '[\r\n]'){throw 'NATIVE_HOST_WSL_REPOSITORY_REQUIRED'}
    $payload=@{Action=$Action;Provider=$Provider;RepositoryRoot=$RepositoryRoot;DataRoot=$DataRoot;MediaRoot=$MediaRoot}
    $json=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($payload|ConvertTo-Json -Compress)))
    $remote='$p=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('''+$json+'''))|ConvertFrom-Json -AsHashtable; & (Join-Path $p.RepositoryRoot ''Tools/Invoke-SqlServerLabNativeLinuxContainerHost.ps1'') @p'
    if($Action -ne 'Plan' -and -not $PSCmdlet.ShouldProcess($Distribution,"$Action native $Provider lab host")){return}
    $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($remote))
    $result=Invoke-LinuxContainerHostNative wsl @('-d',$Distribution,'-u','root','--exec','env','TEMP=/tmp','pwsh','-NoProfile','-OutputFormat','Text','-EncodedCommand',$encoded) $(if($Action -eq 'Test'){14400}else{120})
    if($result.Output){Write-Output $result.Output}
    if($result.ExitCode -ne 0){throw "NATIVE_HOST_WSL_OPERATION_FAILED: $($result.Error)"}
    return
}
if($Distribution){throw 'NATIVE_HOST_DISTRIBUTION_REQUIRES_WSL_BACKEND'}
if(-not $RepositoryRoot){$RepositoryRoot=$sourceRoot}
if($Action -ne 'Plan' -and -not $IsLinux){throw 'NATIVE_HOST_LINUX_REQUIRED: On Windows select Wsl with an explicit distribution.'}
$resolved=@(& (Join-Path $RepositoryRoot 'Tools/Initialize-SqlServerLabHostTools.ps1') -Name $Provider)[0]
$info=$null;$reachable=$false
if($resolved.Available){
    $arguments=if($Provider -eq 'docker'){@('info','--format','{{json .}}')}else{@('info','--format','json')}
    $result=Invoke-LinuxContainerHostNative $resolved.Invocation $arguments 30
    if($result.ExitCode -eq 0){try{$info=$result.Output|ConvertFrom-Json;$reachable=$true}catch{$reachable=$false}}
}
$recipe=Get-Content (Join-Path $RepositoryRoot 'Images/ExternalLanguages/Linux/recipe.json') -Raw|ConvertFrom-Json
$decision=Get-NativeLinuxContainerHostDecision -Provider $Provider -RuntimeInfo $info -ToolAvailable ([bool]$resolved.Available) -RuntimeReachable $reachable -RequiredCgroupVersion $recipe.launchContract.requiredCgroupVersion
if($Action -eq 'Plan'){$decision;return}
if($decision.Status -ne 'COMPATIBLE'){throw "NATIVE_HOST_BLOCKED: $($decision.Reasons -join ',')"}
$uid=Invoke-LinuxContainerHostNative id @('-u') 10
if($uid.ExitCode -ne 0 -or $uid.Output.Trim() -ne '0'){throw 'NATIVE_HOST_ROOT_REQUIRED'}
# Local storage must not be paired with a provider on another Linux host.
if($env:DOCKER_HOST -or $env:CONTAINER_HOST -or $env:CONTAINER_CONNECTION){throw 'NATIVE_HOST_REMOTE_OVERRIDE_REJECTED'}
if($Provider -eq 'docker'){
    $context=Invoke-LinuxContainerHostNative $resolved.Invocation @('context','inspect','--format','{{.Endpoints.docker.Host}}') 20
    if($context.ExitCode -ne 0 -or $context.Output.Trim() -notmatch '^unix:///'){throw 'NATIVE_HOST_LOCAL_PROVIDER_REQUIRED'}
} elseif($info.host.serviceIsRemote -eq $true){throw 'NATIVE_HOST_LOCAL_PROVIDER_REQUIRED'}
$module=Import-Module (Join-Path $RepositoryRoot 'SqlServerLab.psd1') -PassThru
$existing=& $module {[pscustomobject]@{Data=Get-LabDataRootDefault;Media=Get-LabMediaRootDefault}}
if(-not $DataRoot){$DataRoot=$existing.Data}
if(-not $MediaRoot){$MediaRoot=$existing.Media}
if(-not $DataRoot -or -not $MediaRoot){throw 'NATIVE_HOST_EXPLICIT_STORAGE_REQUIRED'}
Assert-NativeLinuxContainerHostStorage $DataRoot $MediaRoot $existing.Data $existing.Media
if(-not $PSCmdlet.ShouldProcess("$Provider on local Linux; $DataRoot; $MediaRoot",$Action)){return}
$previousTemp=$env:TEMP
$operationLock=$null;$journalPath=$null;$journal=$null
try {
    $env:TEMP=[IO.Path]::GetTempPath()
    if($Action -eq 'Initialize'){
        $client=& (Join-Path $RepositoryRoot 'Tools/Test-SqlServerLabClientReadiness.ps1') -Provider $Provider -Operation Inspect
        if($client.Status -notin @('READY','READY_WITH_WARNINGS') -or @($client.MissingPrerequisites).Count){throw "NATIVE_HOST_CLIENT_PREREQUISITES_MISSING: $($client.MissingPrerequisites -join ',')"}
        $operationRoot=Join-Path $RepositoryRoot '.local/native-linux-container-host'
        Assert-LinuxContainerHostPath -Path $operationRoot -Root $RepositoryRoot
        New-Item -ItemType Directory -Path $operationRoot -Force|Out-Null
        $operationLock=[IO.File]::Open((Join-Path $operationRoot 'initialize.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        # Re-read defaults inside the lock before writing any registration.
        $existing=& $module {[pscustomobject]@{Data=Get-LabDataRootDefault;Media=Get-LabMediaRootDefault}}
        Assert-NativeLinuxContainerHostStorage $DataRoot $MediaRoot $existing.Data $existing.Media
        $journalPath=Join-Path $operationRoot "$([guid]::NewGuid().ToString('N')).json"
        $journal=[ordered]@{Contract='SqlServerLab.NativeLinuxContainerHostSetup/1.0';Status='PREPARING';Provider=$Provider;
            DataRoot=$DataRoot;MediaRoot=$MediaRoot;PriorDataRoot=$existing.Data;PriorMediaRoot=$existing.Media;
            Recovery='Repeat Initialize with the same roots; no automatic removal of registered data.'}
        $journal|ConvertTo-Json|Set-Content -LiteralPath "$journalPath.tmp"
        [IO.File]::Move("$journalPath.tmp",$journalPath,$true)
        # Existing storage registration owns recovery/foreign-directory checks.
        # Only missing roots are registered; an existing global default is not moved.
        & $module {
            param($Data,$Media,$Existing)
            if(-not $Existing.Data){$null=Set-LabDataLocation -LabDataRoot $Data -SetDefault -Confirm:$false}
            if(-not $Existing.Media){New-Item -ItemType Directory -Path $Media -Force|Out-Null;$null=Set-LabMediaRootDefault -MediaRoot $Media}
            $prior=$env:SQL_SERVER_LAB_DATA_ROOT
            try{$env:SQL_SERVER_LAB_DATA_ROOT=$null;Set-LabProjectPreferenceValue -Name dataRoot -Value $Data;Set-LabProjectPreferenceValue -Name mediaRoot -Value $Media}
            finally{$env:SQL_SERVER_LAB_DATA_ROOT=$prior}
        } $DataRoot $MediaRoot $existing
    }
    $ready=& (Join-Path $RepositoryRoot 'Tools/Test-SqlServerLabClientReadiness.ps1') -Provider $Provider -Operation Create
    if($ready.Status -notin @('READY','READY_WITH_WARNINGS') -or @($ready.MissingPrerequisites).Count){throw "NATIVE_HOST_CREATE_PREREQUISITES_MISSING: $($ready.MissingPrerequisites -join ',')"}
    if($Action -eq 'Initialize'){
        $journal.Status='READY';$journal|ConvertTo-Json|Set-Content -LiteralPath "$journalPath.tmp";[IO.File]::Move("$journalPath.tmp",$journalPath,$true)
        $decision.Status='READY';$decision.HostChanges='LAB_STORAGE';$decision;return
    }
    $evidence=Join-Path ([IO.Path]::GetTempPath()) "sqllab-native-evidence-$([guid]::NewGuid().ToString('N')).json"
    try{
        & (Join-Path $RepositoryRoot 'Tests/Integration/Invoke-LinuxContainerHostAcceptance.ps1') -Provider $Provider -RepositoryRoot $RepositoryRoot -EvidencePath $evidence
        Get-Content -LiteralPath $evidence -Raw|ConvertFrom-Json
    } finally {if(Test-Path -LiteralPath $evidence){Remove-Item -LiteralPath $evidence -Force}}
} catch {
    $setupFailure=$_
    if($journalPath -and $journal){
        try{$journal.Status='RECOVERY_REQUIRED';$journal|ConvertTo-Json|Set-Content -LiteralPath "$journalPath.tmp";[IO.File]::Move("$journalPath.tmp",$journalPath,$true)}
        catch{Write-Warning 'NATIVE_HOST_JOURNAL_UPDATE_FAILED'}
    }
    throw $setupFailure
} finally {if($operationLock){$operationLock.Dispose()};$env:TEMP=$previousTemp}
