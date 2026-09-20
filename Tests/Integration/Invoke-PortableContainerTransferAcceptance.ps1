#Requires -Version 7.2
<#
.SYNOPSIS
    Prüft den Ein-DB-Transfer auf eigenen SQL-2025-Linux-Runs.
.DESCRIPTION
    Erstellt eine synthetische read-only Quelle mit verwaltetem Backup, prüft
    WhatIf, echten Restore/MATCH und terminale Idempotenz. Ein danach absichtlich
    veraltetes Backup führt zum Inhaltsfehler und Whole-Run-Cleanup. Es werden
    ausschließlich eigene Runs angelegt und entfernt; bestehende Runs sind
    weder Quelle noch Ziel. Docker und Podman sind getrennte Nachweise.
#>
[CmdletBinding()]
param([Parameter(Mandatory)][ValidateSet('docker','podman')][string]$Provider,[switch]$RuntimeMutexAlreadyHeld)
$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$root=Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-transfer-acceptance-'+[guid]::NewGuid().ToString('N'))
$state=Join-Path $root 'state';$data=Join-Path $root 'Lab_Data'
$oldState=$env:SQL_SERVER_LAB_STATE;$oldData=$env:SQL_SERVER_LAB_DATA_ROOT
$source=$null;$targetId=$null;$module=$null;$mutex=$null;$acquired=$false;$cleanupFailed=$false;$complete=$false
$ownedBindings=[Collections.Generic.List[object]]::new()
$sourceOperation=[guid]::NewGuid().ToString('D');$operation=[guid]::NewGuid();$failureOperation=[guid]::NewGuid()
function Assert-TransferAcceptance {param([bool]$Condition,[string]$Name)if(-not $Condition){throw "TRANSFER_ACCEPTANCE_FAILED: $Name"};Write-Host "PASS: $Name"}
try {
    if(-not $RuntimeMutexAlreadyHeld){$mutex=[Threading.Mutex]::new($false,$(if($IsWindows){'Global\SQL_Server_Lab_Runtime_Smoke'}else{'SQL_Server_Lab_Runtime_Smoke'}));$acquired=$mutex.WaitOne([TimeSpan]::FromMinutes(10));if(-not $acquired){throw 'TRANSFER_ACCEPTANCE_LOCK_TIMEOUT'}}
    $resolution=@(& (Join-Path $repoRoot 'Tools/Initialize-SqlServerLabHostTools.ps1') -Name $Provider)[0]
    Assert-TransferAcceptance ([bool]$resolution.Available) 'Providerwerkzeug zentral aufgelöst'
    & ([string]$resolution.Invocation) info 1>$null 2>$null
    Assert-TransferAcceptance ($LASTEXITCODE -eq 0) 'Provider erreichbar'
    $null=New-Item -ItemType Directory -Path $root
    $env:SQL_SERVER_LAB_STATE=$state;$env:SQL_SERVER_LAB_DATA_ROOT=$data
    $module=Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru
    & $module {param($Data)$null=Initialize-LabManagedDataRoot -DataRoot $Data -ControllerId ([guid]::NewGuid().ToString('D')) -Confirm:$false} $data
    $source=& $module {
        param($Provider,$State,$Operation)
        Invoke-WithLabWorkflowOperationContext -OperationId $Operation -ScriptBlock {
            param($Provider,$State)
            New-SqlServerLab -Version 2025 -Provider $Provider -Profile compact -Cpu 1 -MemoryMB 2560 -LabName 'transfer-acceptance-source' -StateRoot $State -GenerateSaPassword -NonInteractive -Drives @([pscustomobject]@{id='transfer-data';containerPath='/var/opt/mssql'})
        } -ArgumentList @($Provider,$State)
    } $Provider $state $sourceOperation
    Assert-TransferAcceptance ($source.State -eq 'Running') 'Eigene SQL-2025-Quelle läuft'
    $sourceBinding=& $module {
        param($Run,$State,$Operation)
        $binding=Get-LabTransferBinding -RunId $Run -InstanceId primary -StateRoot $State -OperationId $Operation
        $connection=New-LabTransferConnection -Binding $binding -OperationId $Operation -StateRoot $State
        try{$connection.Open();$command=$connection.CreateCommand();$command.CommandTimeout=120;$command.CommandText="CREATE DATABASE TransferSource;";$null=$command.ExecuteNonQuery();$command.CommandText="USE TransferSource; CREATE TABLE dbo.TransferProbe(Id int NOT NULL PRIMARY KEY, Marker nvarchar(64) NOT NULL); INSERT dbo.TransferProbe VALUES(1,N'transfer-marker'); USE master; ALTER DATABASE TransferSource SET READ_ONLY;";$null=$command.ExecuteNonQuery();$command.Dispose()}finally{$connection.Dispose()}
        return $binding
    } $source.RunId $state $sourceOperation
    $ownedBindings.Add($sourceBinding)
    $readSource={param($Module,$Run,$State,$Operation)& $Module {
        param($Run,$State,$Operation)
        $binding=Get-LabTransferBinding -RunId $Run -InstanceId primary -StateRoot $State -OperationId $Operation
        $connection=New-LabTransferConnection -Binding $binding -OperationId $Operation -StateRoot $State
        try{$connection.Open();@(Invoke-LabTransferSqlRows -Connection $connection -Query "SELECT d.is_read_only AS IsReadOnly, t.Marker FROM sys.databases d CROSS JOIN TransferSource.dbo.TransferProbe t WHERE d.name=N'TransferSource' AND t.Id=1;")}
        finally{$connection.Dispose()}
    } $Run $State $Operation}
    $before=@(& $readSource $module $source.RunId $state $sourceOperation)
    Assert-TransferAcceptance ($before.Count -eq 1 -and $before[0].IsReadOnly -eq $true -and $before[0].Marker -ceq 'transfer-marker') 'Quelle ist vor dem Transfer read-only und enthält den erwarteten Marker'
    $backup=& $module {
        param($Run,$State,$Data)
        $secret=Get-LabRelationalCoreSecret -RunId $Run -StateRoot $State
        try{Backup-SqlServerLabDatabase -RunId $Run -InstanceId primary -DatabaseName TransferSource -SaPassword $secret -DataRoot $Data -StateRoot $State -Confirm:$false}finally{$secret=$null}
    } $source.RunId $state $data
    Assert-TransferAcceptance ($backup.Status -eq 'BACKUP_REUSABLE') 'Eigenes read-only Backup checksumverifiziert registriert'
    $parameters=@{SourceRunId=$source.RunId;SourceInstanceId='primary';SourceDatabaseName='TransferSource';BackupSetId=$backup.BackupSetId;TargetDatabaseName='TransferTarget';OperationId=$operation;DataRoot=$data;StateRoot=$state}
    $preview=Invoke-SqlServerLabPortableContainerTransfer @parameters -WhatIf
    Assert-TransferAcceptance ($preview.Status -eq 'WHATIF' -and -not(Test-Path (Join-Path $state "portable-container-transfers/$operation.json"))) 'WhatIf erzeugt keinen Operationsstate'
    $result=Invoke-SqlServerLabPortableContainerTransfer @parameters -Confirm:$false
    $targetId=$result.TargetRunId
    if($targetId){$targetBinding=& $module {param($Run,$State,$Op)Get-LabTransferBinding -RunId $Run -InstanceId primary -StateRoot $State -OperationId $Op} $targetId $state $operation.ToString('D');$ownedBindings.Add($targetBinding)}
    Assert-TransferAcceptance ($result.Status -eq 'SUCCEEDED' -and $result.Comparison -eq 'MATCH' -and $result.CleanupStatus -eq 'STAGE_CLEANED_TARGET_RETAINED') 'Echter Restore ergibt vollständigen read-only MATCH und Stage-Cleanup'
    $again=Invoke-SqlServerLabPortableContainerTransfer @parameters -Confirm:$false
    Assert-TransferAcceptance ($again.Status -eq 'SUCCEEDED' -and $again.TargetRunId -eq $targetId) 'Terminale Wiederholung behält denselben Ziel-Run'
    $after=@(& $readSource $module $source.RunId $state $sourceOperation)
    Assert-TransferAcceptance (($before|ConvertTo-Json -Compress) -ceq ($after|ConvertTo-Json -Compress)) 'Read-only-Status und Marker der Quelle bleiben durch Transfer und Replay unverändert'
    $removed=Remove-SqlServerLab -RunId $targetId -StateRoot $state -Force -Confirm:$false
    Assert-TransferAcceptance ($removed.Status -eq 'REMOVED') 'Erfolgreiches Ziel wurde vollständig entfernt'
    & $module {param($Binding)Assert-LabTransferNoResidue -Binding $Binding} $targetBinding
    $targetId=$null
    # Die Acceptance verändert ihre eigene Quelle zwischen zwei getrennten
    # Aufträgen. Der Executor selbst schaltet niemals eine Quelle schreibbar.
    & $module {
        param($Run,$State,$Operation)
        $binding=Get-LabTransferBinding -RunId $Run -InstanceId primary -StateRoot $State -OperationId $Operation
        $connection=New-LabTransferConnection -Binding $binding -OperationId $Operation -StateRoot $State
        try{$connection.Open();$command=$connection.CreateCommand();$command.CommandTimeout=120;$command.CommandText="ALTER DATABASE TransferSource SET READ_WRITE; USE TransferSource; UPDATE dbo.TransferProbe SET Marker=N'changed-after-backup'; USE master; ALTER DATABASE TransferSource SET READ_ONLY;";$null=$command.ExecuteNonQuery();$command.Dispose()}finally{$connection.Dispose()}
    } $source.RunId $state $sourceOperation
    $parameters.OperationId=$failureOperation
    $failure=Invoke-SqlServerLabPortableContainerTransfer @parameters -Confirm:$false
    $targetId=$failure.TargetRunId
    if($targetId){$failureJournal=Get-Content -LiteralPath (Join-Path $state "portable-container-transfers/$failureOperation.json") -Raw|ConvertFrom-Json -Depth 35;$ownedBindings.Add($failureJournal.Target)}
    Assert-TransferAcceptance ($failure.Status -eq 'FAILED_CLEANED' -and $failure.Comparison -eq 'DIFFERENT_OR_UNSUPPORTED' -and $failure.CleanupStatus -eq 'CLEANED') 'Veralteter Inhalt führt zu sichtbarem Fehler und eigenem Whole-Run-Cleanup'
    $repeat=Invoke-SqlServerLabPortableContainerTransfer @parameters -Confirm:$false
    Assert-TransferAcceptance ($repeat.Status -eq 'FAILED_CLEANED' -and $repeat.TargetRunId -eq $targetId) 'Fehlerwiederaufnahme restauriert nicht erneut'
    $targetId=$null;$complete=$true
} finally {
    if($module){
        foreach($op in @($operation.ToString('D'),$failureOperation.ToString('D'),$sourceOperation)){
            try{
                $owned=& $module {param($Op,$State)Get-LabOperationOwnedRun -OperationId $Op -StateRoot $State} $op $state
                if($owned){
                    $cleanupBinding=& $module {param($Run,$State,$Op)Get-LabTransferBinding -RunId $Run -InstanceId primary -StateRoot $State -OperationId $Op} $owned.runId $state $op
                    $ownedBindings.Add($cleanupBinding)
                    $cleanup=Remove-SqlServerLab -RunId $owned.runId -StateRoot $state -Force -Confirm:$false
                    if($cleanup.Status -ne 'REMOVED'){throw 'cleanup'}
                }
            }catch{$cleanupFailed=$true;Write-Warning 'Eigenes Acceptance-Cleanup benötigt Recovery; State bleibt erhalten.'}
        }
        foreach($binding in @($ownedBindings|Group-Object RunId|ForEach-Object {$_.Group[0]})){
            try{& $module {param($Binding)Assert-LabTransferNoResidue -Binding $Binding} $binding}
            catch{$cleanupFailed=$true;Write-Warning 'Run-/Volume-Restprüfung fehlgeschlagen; State bleibt erhalten.'}
        }
    }
    $env:SQL_SERVER_LAB_STATE=$oldState;$env:SQL_SERVER_LAB_DATA_ROOT=$oldData
    Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
    if($mutex){if($acquired){$mutex.ReleaseMutex()};$mutex.Dispose()}
    if(-not $cleanupFailed -and (Test-Path -LiteralPath $root)){
        $resolved=[IO.Path]::GetFullPath($root);$boundary=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
        if(-not $resolved.StartsWith($boundary,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notlike 'sql-lab-transfer-acceptance-*'){throw 'TRANSFER_ACCEPTANCE_CLEANUP_SCOPE_INVALID'}
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
if($cleanupFailed -or -not $complete){throw 'TRANSFER_ACCEPTANCE_INCOMPLETE'}
Write-Host "PORTABLE CONTAINER TRANSFER ACCEPTANCE: PASS ($Provider)"
