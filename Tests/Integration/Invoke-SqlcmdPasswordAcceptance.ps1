#Requires -Version 7.2
<#
.SYNOPSIS
    Prueft fuehrendes Minus in einem synthetischen SA-Passwort am eigenen SQL-2025-Run.
.DESCRIPTION
    Exklusive Runtime-Sperre, operationgebundener Run mit eigenem Named Volume,
    Host-sqlcmd und Container-Healthcheck; PASS erst nach bestaetigtem Cleanup.
    Bei unklarer Ownership oder fehlgeschlagenem Cleanup bleibt der Test-State erhalten.
#>
[CmdletBinding()]
param([Parameter(Mandatory)][ValidateSet('docker','podman')][string]$Provider)
$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$root=Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-sqlcmd-password-'+[guid]::NewGuid().ToString('N'))
$state=Join-Path $root 'state';$data=Join-Path $root 'Lab_Data';$operation=[guid]::NewGuid().ToString('D')
$module=$null;$binding=$null;$complete=$false;$cleanupFailed=$false;$arrangeStarted=$false;$mutex=$null;$acquired=$false;$credential=$null
$oldState=$env:SQL_SERVER_LAB_STATE;$oldData=$env:SQL_SERVER_LAB_DATA_ROOT
try {
    $mutex=[Threading.Mutex]::new($false,$(if($IsWindows){'Global\SQL_Server_Lab_Runtime_Smoke'}else{'SQL_Server_Lab_Runtime_Smoke'}))
    try{$acquired=$mutex.WaitOne([TimeSpan]::FromMinutes(30))}catch [Threading.AbandonedMutexException]{$acquired=$true}
    if(-not $acquired){throw 'SQLCMD_ACCEPTANCE_LOCKED'}
    $resolution=@(& (Join-Path $repoRoot 'Tools/Initialize-SqlServerLabHostTools.ps1') -Name $Provider)[0]
    if(-not $resolution.Available){throw 'SQLCMD_ACCEPTANCE_RUNTIME_UNRESOLVED'}
    $readiness=& (Join-Path $repoRoot 'Tools/Test-SqlServerLabClientReadiness.ps1') -Provider $Provider -Operation Create
    if($readiness.Status -notin @('READY','READY_WITH_WARNINGS')){throw 'SQLCMD_ACCEPTANCE_CLIENT_NOT_READY'}
    $module=Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru
    $env:SQL_SERVER_LAB_STATE=$state;$env:SQL_SERVER_LAB_DATA_ROOT=$data
    $null=New-Item -ItemType Directory -Path $root
    & $module {param($Data)$null=Initialize-LabManagedDataRoot -DataRoot $Data -ControllerId ([guid]::NewGuid().ToString('D')) -Confirm:$false} $data
    $credential=[securestring]::new()
    foreach($character in ('-'+[guid]::NewGuid().ToString('N')+'aA1!').ToCharArray()){$credential.AppendChar($character)}
    $credential.MakeReadOnly()
    $arrangeStarted=$true
    $lab=& $module {
        param($Provider,$State,$Operation,$Credential)
        Invoke-WithLabWorkflowOperationContext -OperationId $Operation -ScriptBlock {
            param($Provider,$State,$Credential)
            New-SqlServerLab -Version 2025 -Provider $Provider -Profile compact -Port 0 -Cpu 1 -MemoryMB 2560 -LabName 'sqlcmd-password-acceptance' -StateRoot $State -SaPassword $Credential -NonInteractive -Drives @([pscustomobject]@{id='sql-data';containerPath='/var/opt/mssql'})
        } -ArgumentList @($Provider,$State,$Credential)
    } $Provider $state $operation $credential
    $binding=& $module {param($Run,$State,$Op)Get-LabTransferBinding -RunId $Run -InstanceId primary -StateRoot $State -OperationId $Op} $lab.RunId $state $operation
    & $module {
        param($Binding,$Credential)
        $bstr=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($Credential)
        try{$plain=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)}finally{[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)}
        try{$answer=@(Invoke-SqlQuery -HostName $Binding.HostName -Port $Binding.Port -SaPlain $plain -Query 'SET NOCOUNT ON; SELECT 17;' -TimeoutSeconds 15);if(($answer -join "`n") -notmatch '(?m)^\s*17\s*$'){throw 'SQLCMD_ACCEPTANCE_QUERY_FAILED'}}finally{$plain=$null}
    } $binding $credential
    Write-Host 'PASS: Eigener SQL-2025-Run und Host-sqlcmd mit fuehrendem Minus'
    $deadline=[datetime]::UtcNow.AddSeconds(90);$healthy=$false
    do {
        $healthy=& $module {
            param($Binding,$State,$Op)
            $fresh=Get-LabTransferBinding -RunId $Binding.RunId -InstanceId primary -StateRoot $State -OperationId $Op
            if($fresh.ContainerId -cne $Binding.ContainerId){throw 'SQLCMD_ACCEPTANCE_CONTAINER_DRIFT'}
            $inspect=@((Invoke-LabTransferNative -Provider $Binding.Provider -Arguments @('inspect',$Binding.ContainerId)) -join "`n"|ConvertFrom-Json -Depth 30)
            $inspect.Count -eq 1 -and $inspect[0].State.Health.Status -eq 'healthy'
        } $binding $state $operation
        if(-not $healthy){Start-Sleep -Seconds 2}
    }while(-not $healthy -and [datetime]::UtcNow -lt $deadline)
    if(-not $healthy){throw 'SQLCMD_ACCEPTANCE_HEALTH_FAILED'}
    Write-Host 'PASS: Gebundener Container-Healthcheck healthy'
    $complete=$true
}finally {
    if($module -and $arrangeStarted){
        try {
            $owned=& $module {param($Op,$State)Get-LabOperationOwnedRun -OperationId $Op -StateRoot $State} $operation $state
            if($owned){
                $binding=& $module {param($Run,$State,$Op)Get-LabTransferBinding -RunId $Run -InstanceId primary -StateRoot $State -OperationId $Op} $owned.runId $state $operation
                $removed=Remove-SqlServerLab -RunId $owned.runId -StateRoot $state -Force -Confirm:$false
                if($removed.Status -ne 'REMOVED' -or $removed.Cleanup -ne 'CLEANUP_SUCCEEDED'){throw 'SQLCMD_ACCEPTANCE_CLEANUP_FAILED'}
            }
            if(-not $binding){throw 'SQLCMD_ACCEPTANCE_CLEANUP_UNVERIFIABLE'}
            & $module {param($Binding)Assert-LabTransferNoResidue -Binding $Binding} $binding
        }catch{$cleanupFailed=$true;Write-Warning 'SQLCMD_ACCEPTANCE_CLEANUP_RECOVERY_REQUIRED'}
    }
    if($credential){$credential.Dispose()}
    $env:SQL_SERVER_LAB_STATE=$oldState;$env:SQL_SERVER_LAB_DATA_ROOT=$oldData
    if($module){Remove-Module $module.Name -Force -ErrorAction SilentlyContinue}
    if($mutex){if($acquired){$mutex.ReleaseMutex()};$mutex.Dispose()}
    if(-not $cleanupFailed -and (Test-Path -LiteralPath $root)){
        $absolute=[IO.Path]::GetFullPath($root);$boundary=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
        if(-not $absolute.StartsWith($boundary,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($absolute) -notmatch '^sql-lab-sqlcmd-password-[a-f0-9]{32}$'){throw 'SQLCMD_ACCEPTANCE_TEMP_SCOPE_INVALID'}
        Remove-Item -LiteralPath $absolute -Recurse -Force
    }
}
if(-not $complete -or $cleanupFailed){throw 'SQLCMD_ACCEPTANCE_INCOMPLETE'}
Write-Host "SQLCMD PASSWORD ACCEPTANCE: PASS ($Provider; query; healthy; own run/volume cleanup)"
