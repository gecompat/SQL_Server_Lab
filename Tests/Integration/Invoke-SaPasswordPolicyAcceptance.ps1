#Requires -Version 7.2
<#
.SYNOPSIS
    Prueft eine bewusst kuerzere SA-Mindestlaenge an einem eigenen SQL-2025-Container.
.DESCRIPTION
    Getrennt fuer Docker oder Podman: frischer operationseigener Run mit eigener
    Systemvolume, SQL-Anmeldung, Configerhalt nach Restart und gebundenes Cleanup.
    Bei unklarer Ownership bleibt der lokale Scope fuer Recovery erhalten.
#>
[CmdletBinding()]
param([Parameter(Mandatory)][ValidateSet('docker','podman')][string]$Provider)
$ErrorActionPreference='Stop'
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$root=Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-sa-password-'+[guid]::NewGuid().ToString('N'))
$state=Join-Path $root 'state';$data=Join-Path $root 'Lab_Data';$operation=[guid]::NewGuid().ToString('D')
$module=$null;$binding=$null;$complete=$false;$cleanupFailed=$false;$arrangeStarted=$false
$mutex=$null;$acquired=$false;$credential=$null
$oldState=$env:SQL_SERVER_LAB_STATE;$oldData=$env:SQL_SERVER_LAB_DATA_ROOT
try {
    $mutex=[Threading.Mutex]::new($false,$(if($IsWindows){'Global\SQL_Server_Lab_Runtime_Smoke'}else{'SQL_Server_Lab_Runtime_Smoke'}))
    try{$acquired=$mutex.WaitOne([TimeSpan]::FromMinutes(30))}catch [Threading.AbandonedMutexException]{$acquired=$true}
    if(-not $acquired){throw 'SA_PASSWORD_ACCEPTANCE_LOCKED'}
    $resolution=@(& (Join-Path $repo 'Tools/Initialize-SqlServerLabHostTools.ps1') -Name $Provider)[0]
    if(-not $resolution.Available -or -not [IO.Path]::IsPathFullyQualified([string]$resolution.Invocation) -or
        -not (Test-Path -LiteralPath $resolution.Invocation -PathType Leaf)){
        throw 'SA_PASSWORD_ACCEPTANCE_RUNTIME_UNRESOLVED'
    }
    $readiness=& (Join-Path $repo 'Tools/Test-SqlServerLabClientReadiness.ps1') -Provider $Provider -Operation Create
    if($readiness.Status -notin @('READY','READY_WITH_WARNINGS')){throw 'SA_PASSWORD_ACCEPTANCE_CLIENT_NOT_READY'}
    $module=Import-Module (Join-Path $repo 'SqlServerLab.psd1') -Force -PassThru
    if(Test-Path -LiteralPath $root){throw 'SA_PASSWORD_ACCEPTANCE_ROOT_EXISTS'}
    $null=New-Item -ItemType Directory -Path $root
    $env:SQL_SERVER_LAB_STATE=$state;$env:SQL_SERVER_LAB_DATA_ROOT=$data
    & $module {param($Data)$null=Initialize-LabManagedDataRoot -DataRoot $Data -ControllerId ([guid]::NewGuid().ToString('D')) -Confirm:$false} $data
    $builds=@(& $module {Get-SqlServerBuilds -VersionId '2025'} | Where-Object {[string]$_.cu -match '^CU[0-9]+$'} | Sort-Object {[int](([string]$_.cu).Substring(2))} -Descending)
    if($builds.Count -lt 1){throw 'SA_PASSWORD_ACCEPTANCE_CATALOG_BUILD_MISSING'}
    $version='2025-'+[string]$builds[0].cu
    $credential=[securestring]::new()
    foreach($character in @([char]65,[char]98,[char]51)){$credential.AppendChar($character)}
    $credential.MakeReadOnly()
    $arrangeStarted=$true
    $lab=& $module {
        param($Selected,$State,$Operation,$Credential,$Version)
        Invoke-WithLabWorkflowOperationContext -OperationId $Operation -ScriptBlock {
            param($Provider,$StateRoot,$Password,$VersionId)
            New-SqlServerLab -Version $VersionId -Provider $Provider -Profile compact -Port 0 -Cpu 1 -MemoryMB 2560 `
                -LabName 'sa-password-acceptance' -StateRoot $StateRoot -SaPassword $Password -SaPasswordMinimumLength 3 -NonInteractive -SkipAssessment
        } -ArgumentList @($Selected,$State,$Credential,$Version)
    } $Provider $state $operation $credential $version
    if(-not $lab -or [string]$lab.State -cne 'Running'){throw 'SA_PASSWORD_ACCEPTANCE_CREATION_FAILED'}
    $binding=& $module {param($Run,$State,$Op)Get-LabTransferBinding -RunId $Run -InstanceId primary -StateRoot $State -OperationId $Op} $lab.RunId $state $operation
    $expectedBinding=& $module {param($Value)Get-LabTransferBindingIdentity $Value} $binding
    $config=@(& $module {param($Bound,$State)Invoke-LabTransferNative -Provider $Bound.Provider -Arguments @('exec',$Bound.ContainerId,'cat','/var/opt/mssql/mssql.conf') -StateRoot $State} $binding $state)
    if(($config -join "`n") -cnotmatch '(?m)^\[passwordpolicy\]\s*$' -or
        ($config -join "`n") -cnotmatch '(?m)^passwordminimumlength=3\s*$') {throw 'SA_PASSWORD_ACCEPTANCE_CONFIG_INVALID'}
    function Assert-SyntheticSqlLogin($Module,$Bound,$Password) {
        & $Module {
            param($Binding,$Credential)
            $bstr=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($Credential)
            try{$plain=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)}finally{[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)}
            try {
                $answer=@(Invoke-SqlQuery -HostName $Binding.HostName -Port $Binding.Port -SaPlain $plain -Query 'SET NOCOUNT ON; SELECT 17;' -TimeoutSeconds 15)
                if(($answer -join "`n") -notmatch '(?m)^\s*17\s*$'){throw 'SA_PASSWORD_ACCEPTANCE_LOGIN_FAILED'}
            }
            finally {$plain=$null}
        } $Bound $Password
    }
    Assert-SyntheticSqlLogin $module $binding $credential
    $restart=Restart-SqlServerLab -RunId $lab.RunId -StateRoot $state -Force -Confirm:$false -TimeoutSeconds 120
    if([string]$restart.Status -cne 'RUNNING'){throw 'SA_PASSWORD_ACCEPTANCE_RESTART_FAILED'}
    $fresh=& $module {param($Expected,$State,$Op)Assert-LabTransferBinding -Expected $Expected -StateRoot $State -OperationId $Op} $expectedBinding $state $operation
    $configAfter=@(& $module {param($Bound,$State)Invoke-LabTransferNative -Provider $Bound.Provider -Arguments @('exec',$Bound.ContainerId,'cat','/var/opt/mssql/mssql.conf') -StateRoot $State} $fresh $state)
    if(($config -join "`n") -cne ($configAfter -join "`n")){throw 'SA_PASSWORD_ACCEPTANCE_CONFIG_DRIFT'}
    Assert-SyntheticSqlLogin $module $fresh $credential
    $complete=$true
}
finally {
    if($module -and $arrangeStarted){
        try {
            $owned=& $module {param($Op,$State)Get-LabOperationOwnedRun -OperationId $Op -StateRoot $State} $operation $state
            if($owned){
                if(-not $binding){$binding=& $module {param($Run,$State,$Op)Get-LabTransferBinding -RunId $Run -InstanceId primary -StateRoot $State -OperationId $Op} $owned.runId $state $operation}
                $removed=Remove-SqlServerLab -RunId $owned.runId -StateRoot $state -Force -Confirm:$false
                if($removed.Status -ne 'REMOVED' -or $removed.Cleanup -ne 'CLEANUP_SUCCEEDED'){throw 'SA_PASSWORD_ACCEPTANCE_CLEANUP_FAILED'}
            }
            if(-not $binding){throw 'SA_PASSWORD_ACCEPTANCE_CLEANUP_UNVERIFIABLE'}
            & $module {param($Bound,$State)Assert-LabTransferNoResidue -Binding $Bound -StateRoot $State} $binding $state
        }
        catch {$cleanupFailed=$true;Write-Warning 'SA_PASSWORD_ACCEPTANCE_CLEANUP_RECOVERY_REQUIRED'}
    }
    if($credential){$credential.Dispose()}
    $env:SQL_SERVER_LAB_STATE=$oldState;$env:SQL_SERVER_LAB_DATA_ROOT=$oldData
    if($module){Remove-Module $module.Name -Force -ErrorAction SilentlyContinue}
    if($mutex){if($acquired){$mutex.ReleaseMutex()};$mutex.Dispose()}
    if(-not $cleanupFailed -and (Test-Path -LiteralPath $root)){
        $absolute=[IO.Path]::GetFullPath($root)
        $boundary=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
        if(-not $absolute.StartsWith($boundary,[StringComparison]::OrdinalIgnoreCase) -or
            [IO.Path]::GetFileName($absolute) -notmatch '^sql-lab-sa-password-[a-f0-9]{32}$' -or
            (Get-Item -LiteralPath $absolute).Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)){throw 'SA_PASSWORD_ACCEPTANCE_TEMP_SCOPE_INVALID'}
        Remove-Item -LiteralPath $absolute -Recurse -Force
    }
}
if(-not $complete -or $cleanupFailed){throw 'SA_PASSWORD_ACCEPTANCE_INCOMPLETE'}
Write-Host "SA PASSWORD ACCEPTANCE: PASS ($Provider; SQL login; restart; config; own cleanup)"
