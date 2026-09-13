#Requires -Version 7.2
<#
.SYNOPSIS
    Belegt die native SQL-2025-Medienvorpruefung eines bestehenden Container-Ziels.
.DESCRIPTION
    Erstellt zwei isolierte SQL-2025-Runs desselben Providers, publiziert ein
    synthetisches CHECKSUM-/VERIFYONLY-Backup der Quelle in einer temporären
    Lab_Data-Bibliothek und führt den öffentlichen Preflight am persistenten
    Backup-Bind-Mount des Ziels aus. Der Test führt keinen Restore und keinen
    Transfer aus. Er verlangt HEADERONLY, VERIFYONLY und vollständiges Cleanup
    der operationseigenen Stage-Dateien und Journale.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText','',Justification='Nur zufällig erzeugte synthetische Credentials für isolierte Test-Runs.')]
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('docker','podman')][string]$Provider,
    [switch]$RuntimeMutexAlreadyHeld,
    [switch]$KeepOnFailure
)

$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$modulePath=Join-Path $repoRoot 'SqlServerLab.psd1'
$testRoot=Join-Path ([IO.Path]::GetTempPath()) "sql-lab-transfer-preflight-$Provider-$([Guid]::NewGuid().ToString('N'))"
$stateRoot=Join-Path $testRoot 'state';$dataRoot=Join-Path $testRoot 'Lab_Data'
$previousStateRoot=$env:SQL_SERVER_LAB_STATE;$previousDataRoot=$env:SQL_SERVER_LAB_DATA_ROOT
$sourceLab=$null;$targetLab=$null;$module=$null;$completed=$false;$cleanupFailed=$false;$mutex=$null;$mutexAcquired=$false

function Assert-TransferPreflightAcceptance {
    param([Parameter(Mandatory)][bool]$Condition,[Parameter(Mandatory)][string]$Description)
    if(-not $Condition){throw "PORTABLE_CONTAINER_TRANSFER_PREFLIGHT_ACCEPTANCE_FAILED: $Description"}
    Write-Host "PASS: $Description" -ForegroundColor Green
}

try {
    if(-not $RuntimeMutexAlreadyHeld){
        $mutex=[Threading.Mutex]::new($false,$(if($IsWindows){'Global\SQL_Server_Lab_Runtime_Smoke'}else{'SQL_Server_Lab_Runtime_Smoke'}))
        $mutexAcquired=$mutex.WaitOne([TimeSpan]::FromMinutes(10))
        if(-not $mutexAcquired){throw 'PORTABLE_CONTAINER_TRANSFER_PREFLIGHT_ACCEPTANCE_LOCK_TIMEOUT'}
    }
    $runtimeResolution=@(& (Join-Path $repoRoot 'Tools\Initialize-SqlServerLabHostTools.ps1') -Name $Provider)[0]
    if($Provider -eq 'podman'){& (Join-Path $PSScriptRoot 'Initialize-PodmanRuntime.ps1')|Out-Host}
    Assert-TransferPreflightAcceptance ([bool]$runtimeResolution.Available) "Runtime '$Provider' ist zentral auflösbar"
    & ([string]$runtimeResolution.Invocation) info 1>$null 2>$null
    Assert-TransferPreflightAcceptance ($LASTEXITCODE -eq 0) "Runtime '$Provider' ist erreichbar"

    New-Item -ItemType Directory -Path $testRoot -Force|Out-Null
    $env:SQL_SERVER_LAB_STATE=$stateRoot;$env:SQL_SERVER_LAB_DATA_ROOT=$dataRoot
    Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
    $module=Import-Module $modulePath -Force -PassThru
    & $module {param($Root)$null=Initialize-LabManagedDataRoot -DataRoot $Root -ControllerId ([Guid]::NewGuid().ToString('D')) -Confirm:$false} $dataRoot
    $assessment=Test-SqlServerLabPrerequisite -Provider $Provider
    Assert-TransferPreflightAcceptance ($assessment.Status -eq 'RESOURCE_OK') 'Ressourcenpruefung erlaubt die zwei isolierten SQL-2025-Runs'

    $token=[Guid]::NewGuid().ToString('N').Substring(0,16)
    $password=ConvertTo-SecureString "TransferPreflight_${token}!Aa7" -AsPlainText -Force
    $sourceLab=New-SqlServerLab -Version 2025 -Provider $Provider -Profile compact -Cpu 1 -MemoryMB 2560 -LabName "transfer-source-$($token.Substring(0,8))" -StateRoot $stateRoot -SaPassword $password -SkipAssessment
    Assert-TransferPreflightAcceptance ($sourceLab.State -eq 'Running') 'Isolierter SQL-2025-Quellrun wurde provisioniert'
    $targetLab=New-SqlServerLab -Version 2025 -Provider $Provider -Profile compact -Cpu 1 -MemoryMB 2560 -LabName "transfer-target-$($token.Substring(0,8))" -DataRoot $dataRoot -PersistentData -StateRoot $stateRoot -SaPassword $password -SkipAssessment
    Assert-TransferPreflightAcceptance ($targetLab.State -eq 'Running') 'Isolierter SQL-2025-Zielrun mit persistentem Backup-Bind-Mount wurde provisioniert'

    $sourceInstance=@($sourceLab.Instances)[0];$targetInstance=@($targetLab.Instances)[0]
    $sourceDatabase='TransferPreflightSource';$targetDatabase='TransferPreflightTarget'
    $null=New-SqlServerLabDatabase -HostName ([string]$sourceInstance.Host) -Port ([int]$sourceInstance.Port) -SaPassword $password -DatabaseName $sourceDatabase
    & $module {
        param($HostName,$Port,$Secret,$DatabaseName)
        $plain=ConvertFrom-LabSecureString -SecureString $Secret
        try {Invoke-SqlQuery -HostName $HostName -Port $Port -SaPlain $plain -Database $DatabaseName -Query "CREATE TABLE dbo.PreflightProbe (Id int NOT NULL PRIMARY KEY, Marker nvarchar(64) NOT NULL); INSERT dbo.PreflightProbe VALUES (1,N'portable-transfer-preflight');" -TimeoutSeconds 120|Out-Null}
        finally {$plain=$null}
    } ([string]$sourceInstance.Host) ([int]$sourceInstance.Port) $password $sourceDatabase
    Assert-TransferPreflightAcceptance $true 'Synthetische Quelldatenbank wurde ausschließlich im eigenen SQL-Run angelegt'

    $backup=Backup-SqlServerLabDatabase -RunId $sourceLab.RunId -InstanceId primary -SaPassword $password -DatabaseName $sourceDatabase -DataRoot $dataRoot -StateRoot $stateRoot -Confirm:$false
    Assert-TransferPreflightAcceptance ($backup.Status -eq 'BACKUP_REUSABLE' -and $backup.BackupSetId -match '^[0-9a-f-]{36}$') 'Echtes SQL-2025-Backup wurde checksum- und VERIFYONLY-verifiziert in die Bibliothek publiziert'

    $result=Invoke-SqlServerLabPortableContainerTransferPreflight -SourceRunId $sourceLab.RunId -SourceInstanceId primary -TargetRunId $targetLab.RunId -TargetInstanceId primary -DatabaseTransfers @([pscustomobject]@{SourceDatabaseName=$sourceDatabase;TargetDatabaseName=$targetDatabase;BackupSetId=$backup.BackupSetId}) -DataRoot $dataRoot -StateRoot $stateRoot -Confirm:$false
    Assert-TransferPreflightAcceptance ($result.Status -eq 'PRECHECKED' -and $result.CleanupStatus -eq 'CLEANED' -and $result.TransferExecutorStatus -eq 'BLOCKED' -and -not $result.TransferExecutionImplemented) "Öffentlicher Preflight bleibt nach erfolgreichem Mediencheck transfer-blockiert (Status=$($result.Status); Cleanup=$($result.CleanupStatus); Blockers=$(@($result.Blockers) -join ','))"
    Assert-TransferPreflightAcceptance (@($result.Blockers).Count -eq 0) "Erfolgsweg meldet keine Preflight-Blocker (Status=$($result.Status); Cleanup=$($result.CleanupStatus); Blockers=$(@($result.Blockers) -join ','))"
    Assert-TransferPreflightAcceptance (@($result.Transfers).Count -eq 1 -and $result.Transfers[0].HeaderOnly -eq 'PASSED' -and $result.Transfers[0].VerifyOnly -eq 'PASSED') 'Echtes SQL-2025 HEADERONLY und VERIFYONLY WITH CHECKSUM bestehen'
    $postcondition=& $module {
        param($RunId,$State,$ExpectedDatabase)
        $request=[pscustomobject]@{TargetRunId=$RunId;TargetInstanceId='primary'}
        $binding=Get-LabPortableContainerTransferPreflightTargetBinding -Request $request -StateRoot $State
        $context=Get-LabContainerReconcileContext -RunId $RunId -InstanceId primary -StateRoot $State
        $secret=Get-LabSecret -Path $context.RunDirectory -Name 'sa-password';$plain=ConvertFrom-LabSecureString -SecureString $secret
        try {$targetMissing=@(Invoke-SqlQuery -HostName ([string]$context.Instance.host) -Port ([int]$context.CurrentPort) -SaPlain $plain -Database master -Query "SET NOCOUNT ON; SELECT CASE WHEN DB_ID(N'$ExpectedDatabase') IS NULL THEN N'MISSING' ELSE N'PRESENT' END;"|ForEach-Object{([string]$_).Trim()}) -contains 'MISSING'}finally{$plain=$null}
        [pscustomobject]@{Binding=$binding;TargetMissing=$targetMissing;OperationResidue=@(Get-ChildItem -LiteralPath $binding.HostRoot -Force -ErrorAction Stop|Where-Object {$_.Name -like 'transfer-preflight-*'}).Count}
    } $targetLab.RunId $stateRoot $targetDatabase
    Assert-TransferPreflightAcceptance ($postcondition.Binding.Available -and $postcondition.TargetMissing -and $postcondition.OperationResidue -eq 0) 'Preflight erzeugt keine Ziel-Datenbank und entfernt nur seine vollständigen Stage- und Journalreste'
    $completed=$true
}
finally {
    foreach($lab in @($targetLab,$sourceLab)|Where-Object {$_}){
        try {$cleanup=Remove-SqlServerLab -RunId $lab.RunId -StateRoot $stateRoot -Force -Confirm:$false;if($cleanup.Status -ne 'REMOVED'){throw 'PORTABLE_CONTAINER_TRANSFER_PREFLIGHT_ACCEPTANCE_RUN_CLEANUP_FAILED'}}catch{$cleanupFailed=$true;Write-Warning 'Run-Cleanup fehlgeschlagen; der eigene Test-State bleibt für Recovery erhalten.'}
    }
    $env:SQL_SERVER_LAB_STATE=$previousStateRoot;$env:SQL_SERVER_LAB_DATA_ROOT=$previousDataRoot
    Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
    if($mutex){if($mutexAcquired){try{$mutex.ReleaseMutex()}catch{}};$mutex.Dispose()}
    if($cleanupFailed -or ($KeepOnFailure -and -not $completed)){Write-Warning 'Acceptance-Arbeitsbereich bleibt für Recovery erhalten.'}
    elseif(Test-Path -LiteralPath $testRoot){
        $resolved=[IO.Path]::GetFullPath($testRoot);$boundary=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar
        if(-not $resolved.StartsWith($boundary,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notlike 'sql-lab-transfer-preflight-*'){throw 'PORTABLE_CONTAINER_TRANSFER_PREFLIGHT_ACCEPTANCE_CLEANUP_SCOPE_INVALID'}
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
if($cleanupFailed){throw 'PORTABLE_CONTAINER_TRANSFER_PREFLIGHT_ACCEPTANCE_CLEANUP_FAILED'}
if(-not $completed){throw 'PORTABLE_CONTAINER_TRANSFER_PREFLIGHT_ACCEPTANCE_INCOMPLETE'}
Write-Host "Portable-Container-Transfer-Preflight-Acceptance erfolgreich: $Provider" -ForegroundColor Green
