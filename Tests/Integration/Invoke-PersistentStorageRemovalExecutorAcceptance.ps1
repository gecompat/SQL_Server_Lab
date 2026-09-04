#Requires -Version 7.2
<#
.SYNOPSIS
    Belegt den PSR-004-Executor gegen eine reale Docker- oder Podman-Runtime.
.DESCRIPTION
    Erstellt einen isolierten persistenten Container-Run und eine Datenbank,
    führt eine wählbare Artefakt- oder Run-Delete-Policy über den öffentlichen
    Befehl aus und bestätigt Backup, Paket oder beide unabhängigen Nachweise
    beziehungsweise den Missing-Volume-Nachweis, den entfernten Run und den
    passenden finalen Katalogzustand.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('docker','podman')][string]$Provider,
    [string]$Version='2022-CU18',
    [ValidateSet('BACKUP_ON_REMOVE','PACKAGE_ON_REMOVE','BACKUP_AND_PACKAGE','DELETE_WITH_RUN')][string]$Policy='BACKUP_ON_REMOVE',
    [switch]$KeepOnFailure
)

$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$modulePath=Join-Path $repoRoot 'SqlServerLab.psd1'
$testRoot=Join-Path ([IO.Path]::GetTempPath()) "sql-lab-psr004-$Provider-$([Guid]::NewGuid().ToString('N'))"
$stateRoot=Join-Path $testRoot 'state'
$dataRoot=Join-Path $testRoot 'Lab_Data'
$testDataRoot=Join-Path $testRoot 'test-data'
$previousStateRoot=$env:SQL_SERVER_LAB_STATE
$previousDataRoot=$env:SQL_SERVER_LAB_DATA_ROOT
$previousTestDataRoot=$env:SQL_SERVER_LAB_TEST_DATA_ROOT
$lab=$null;$module=$null;$persistentVolume=$null;$completed=$false
$databaseName='Psr004Evidence'
$isDeleteWithRun=$Policy -eq 'DELETE_WITH_RUN'
$runtimeMutex=[Threading.Mutex]::new($false,$(if($IsWindows){'Global\SQL_Server_Lab_Runtime_Smoke'}else{'SQL_Server_Lab_Runtime_Smoke'}))
$mutexAcquired=$false

function Assert-RemovalAcceptance {
    param([Parameter(Mandatory)][bool]$Condition,[Parameter(Mandatory)][string]$Description)
    if(-not $Condition){throw "PERSISTENT_STORAGE_REMOVAL_ACCEPTANCE_FAILED: $Description"}
    Write-Host "PASS: $Description" -ForegroundColor Green
}

try {
    Write-Host "PSR-004-Executor-Abnahme: $Provider" -ForegroundColor Cyan
    $mutexAcquired=$runtimeMutex.WaitOne([TimeSpan]::FromMinutes(10))
    if(-not $mutexAcquired){throw 'PERSISTENT_STORAGE_REMOVAL_ACCEPTANCE_LOCK_TIMEOUT'}
    New-Item -ItemType Directory -Path $testRoot -Force|Out-Null
    $env:SQL_SERVER_LAB_STATE=$stateRoot
    $env:SQL_SERVER_LAB_DATA_ROOT=$dataRoot
    $env:SQL_SERVER_LAB_TEST_DATA_ROOT=$testDataRoot
    Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
    $module=Import-Module $modulePath -Force -PassThru
    $runtimeResolution=@(& (Join-Path $repoRoot 'Tools\Initialize-SqlServerLabHostTools.ps1') -Name $Provider)[0]
    if($Provider -eq 'podman'){& (Join-Path $PSScriptRoot 'Initialize-PodmanRuntime.ps1')|Out-Host}
    Assert-RemovalAcceptance ([bool]$runtimeResolution.Available) "Runtime '$Provider' ist zentral auflösbar"
    $runtimeInvocation=[string]$runtimeResolution.Invocation
    & $runtimeInvocation info 1>$null 2>$null
    Assert-RemovalAcceptance ($LASTEXITCODE -eq 0) "Runtime '$Provider' ist erreichbar"
    & $module {param($Root)$null=Initialize-LabManagedDataRoot -DataRoot $Root -ControllerId ([Guid]::NewGuid().ToString('D')) -Confirm:$false} $dataRoot

    $token=[Guid]::NewGuid().ToString('N').Substring(0,16)
    $saPassword=ConvertTo-SecureString "Psr004_${token}!Aa7" -AsPlainText -Force
    $newLabArguments=@{ Version=$Version;Provider=$Provider;Profile='compact';Cpu=1;MemoryMB=2560
        LabName="psr004-$Provider-$($token.Substring(0,8))";DataRoot=$dataRoot;SaPassword=$saPassword;StateRoot=$stateRoot;SkipAssessment=$true }
    if(-not $isDeleteWithRun){$newLabArguments.PersistentData=$true}
    $lab=New-SqlServerLab @newLabArguments
    $provisionedDescription=if($isDeleteWithRun){'Rungebundener Test-Run wurde provisioniert'}else{'Persistenter Test-Run wurde provisioniert'}
    Assert-RemovalAcceptance ($lab.State -eq 'Running') $provisionedDescription
    $instance=$lab.Instances[0]
    $null=New-SqlServerLabDatabase -HostName ([string]$instance.Host) -Port ([int]$instance.Port) `
        -SaPassword $saPassword -DatabaseName $databaseName

    $catalogEvidence=& $module {
        param($Root,$State,$Run,$Scope,$Database,$DeleteWithRun)
        $configuration=Get-LabStorageConfiguration -DataRoot $Root
        if($DeleteWithRun){
            $sync=Sync-SqlServerLabRunScopedContainerStore -RunId $Run -InstanceId primary -DataRoot $Root -StateRoot $State -Confirm:$false
            $catalog=Get-LabPersistentStorageCatalog -Configuration $configuration
            $stores=@($catalog.Document.Stores|Where-Object {[string]$_.PersistentStorageId -eq [string]$sync.PersistentStorageId})
            if($stores.Count -ne 1){throw 'PERSISTENT_STORAGE_REMOVAL_ACCEPTANCE_RUN_SCOPED_STORE_UNRESOLVED'}
            return [PSCustomObject]@{Store=$stores[0];Catalog=$catalog}
        }
        $catalog=Get-LabPersistentStorageCatalog -Configuration $configuration
        $stores=@($catalog.Document.Stores|Where-Object {$_.StorageClass -eq 'INSTANCE_STORE' -and [string]$_.Lease.RunId -eq $Run})
        if($stores.Count -ne 1){throw 'PERSISTENT_STORAGE_REMOVAL_ACCEPTANCE_STORE_UNRESOLVED'}
        $sync=Sync-LabContainerInstanceStoreDatabaseReference -PersistentStorageId ([string]$stores[0].PersistentStorageId) `
            -RunId $Run -ScopeId $Scope -DatabaseName @($Database) -Configuration $configuration
        [PSCustomObject]@{Store=$sync.Store;Catalog=Get-LabPersistentStorageCatalog -Configuration $configuration}
    } $dataRoot $stateRoot $lab.RunId $lab.ScopeId $databaseName $isDeleteWithRun
    $store=$catalogEvidence.Store
    $persistentVolume=[string]$store.LocationBinding.ProviderResourceId
    $databaseReference=@($store.References|Where-Object {$_.Kind -eq 'DATABASE' -and $_.State -eq 'ACTIVE' -and $_.TargetId -eq $databaseName})
    if($isDeleteWithRun){
        Assert-RemovalAcceptance ($store.Retention -eq 'RUN_SCOPED' -and $store.CleanupDisposition -eq 'RUN_CLEANUP' -and $store.State -eq 'IN_USE') 'Run-Store ist mit RUN_SCOPED/RUN_CLEANUP und aktiver Lease registriert'
    } else {
        Assert-RemovalAcceptance ($databaseReference.Count -eq 1) 'Datenbank ist über stabile aktive Referenz an den Instanzstore gebunden'
    }

    $selection=@([PSCustomObject]@{
        PersistentStorageId=[string]$store.PersistentStorageId
        Policy=$Policy
        DatabaseReferenceIds=if($isDeleteWithRun){@()}else{@([string]$databaseReference[0].ReferenceId)}
    })
    $plan=Get-SqlServerLabPersistentStorageRemovalPlan -RunId $lab.RunId -Selection $selection -StateRoot $stateRoot -DataRoot $dataRoot
    Assert-RemovalAcceptance ($plan.Status -eq 'READY' -and $plan.Execution.Status -eq 'EXECUTABLE' -and @($plan.Stores).Count -eq 1 -and
        ((-not $isDeleteWithRun) -or $plan.Stores[0].Outcome -eq 'DELETE_RUN_RESOURCE')) 'Frischer Removal-Plan ist blockerfrei und ausführbar'
    $result=Invoke-SqlServerLabPersistentStorageRemoval -RunId $lab.RunId -Selection $selection `
        -StateRoot $stateRoot -DataRoot $dataRoot -Force -Confirm:$false
    $requiresBackup=$Policy -in @('BACKUP_ON_REMOVE','BACKUP_AND_PACKAGE')
    $requiresPackage=$Policy -in @('PACKAGE_ON_REMOVE','BACKUP_AND_PACKAGE')
    Assert-RemovalAcceptance ($result.Status -eq 'REMOVED' -and $result.JournalStatus -eq 'COMPLETED' -and
        ((-not $requiresBackup) -or @($result.BackupSetIds).Count -eq 1) -and
        ((-not $requiresPackage) -or @($result.DatabasePackageIds).Count -eq 1)) "Executor schließt $Policy und Run-Entfernung journalisiert ab"

    $runState=& $module {param($Run,$State)Get-LabRunState -RunId $Run -StateRoot $State} $lab.RunId $stateRoot
    $backup=if($requiresBackup){& $module {param($Id,$Root)Get-LabDatabaseBackup -BackupSetId $Id -DataRoot $Root} ([string]$result.BackupSetIds[0]) $dataRoot}else{$null}
    $package=if($requiresPackage){& $module {param($Id,$Root)Get-LabDatabasePackage -DatabasePackageId $Id -DataRoot $Root} ([string]$result.DatabasePackageIds[0]) $dataRoot}else{$null}
    $finalStore=& $module {
        param($Root,$StorageId)
        $configuration=Get-LabStorageConfiguration -DataRoot $Root
        @(Get-LabPersistentStorageCatalog -Configuration $configuration).Document.Stores|Where-Object PersistentStorageId -eq $StorageId|Select-Object -First 1
    } $dataRoot ([string]$store.PersistentStorageId)
    $null=& $runtimeInvocation volume inspect $persistentVolume 2>$null
    $volumeExists=$LASTEXITCODE -eq 0
    $volumeDescription=if($isDeleteWithRun){'Rungebundener Instanzstore wurde gelöscht'}else{'Persistenter Instanzstore wurde nicht gelöscht'}
    Assert-RemovalAcceptance ($volumeExists -eq (-not $isDeleteWithRun)) $volumeDescription
    Assert-RemovalAcceptance ($runState.state -eq 'REMOVED' -and $finalStore.State -eq 'DETACHED' -and -not $finalStore.Lease) 'Run ist entfernt und Store exakt detached'
    if($isDeleteWithRun){
        Assert-RemovalAcceptance ($finalStore.Retention -eq 'RUN_SCOPED' -and $finalStore.CleanupDisposition -eq 'RUN_CLEANUP') 'Delete-Abschluss behält nur die revisionsgebundene Katalogevidence'
    } else {
        Assert-RemovalAcceptance ((-not $requiresBackup -or ($backup.Record.DatabaseName -eq $databaseName -and [string]$backup.Record.Artifact.Sha256 -match '^[a-f0-9]{64}$')) -and
            (-not $requiresPackage -or ($package.Record.DatabaseName -eq $databaseName -and [string]$package.Record.ManifestSha256 -match '^[a-f0-9]{64}$'))) "$Policy ist in Lab_Data per SHA-256 wiederverwendbar"
    }
    $lab=$null;$completed=$true
}
finally {
    if($lab -and -not $KeepOnFailure){try{Remove-SqlServerLab -RunId $lab.RunId -StateRoot $stateRoot -Force -Confirm:$false|Out-Null}catch{Write-Warning $_.Exception.Message}}
    if($persistentVolume -and ($completed -or -not $KeepOnFailure)){$null=& $runtimeInvocation volume rm -f $persistentVolume 2>$null}
    if(($completed -or -not $KeepOnFailure) -and (Test-Path -LiteralPath $testRoot)){Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue}
    $env:SQL_SERVER_LAB_STATE=$previousStateRoot
    $env:SQL_SERVER_LAB_DATA_ROOT=$previousDataRoot
    $env:SQL_SERVER_LAB_TEST_DATA_ROOT=$previousTestDataRoot
    if($mutexAcquired){try{$runtimeMutex.ReleaseMutex()}catch{}}
    $runtimeMutex.Dispose()
}

Write-Host "PSR-004-Executor-Abnahme erfolgreich: $Provider" -ForegroundColor Green
