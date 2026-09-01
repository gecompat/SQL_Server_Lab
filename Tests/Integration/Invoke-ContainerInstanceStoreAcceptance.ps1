#Requires -Version 7.2
<#
.SYNOPSIS
    Reale Docker-/Podman-Abnahme fuer Continue und Clone eines Instanzstores.
.DESCRIPTION
    Erzeugt einen test-eigenen katalogisierbaren SQL-Systemstore, bestaetigt
    Server- und Benutzerdaten nach kontrolliertem Container-Recreate, klont den
    detached Store journalisiert und bestaetigt dieselben Daten im Clone.
    Quelle, Ziel und Container werden im finally-Scope entfernt.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('docker','podman')][string]$Provider,
    [string]$Image = 'mcr.microsoft.com/mssql/server:2025-latest',
    [switch]$KeepOnFailure
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$modulePath = Join-Path $repoRoot 'SqlServerLab.psd1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) "sql-lab-psr005-$Provider-$([guid]::NewGuid().ToString('N'))"
$token = [guid]::NewGuid().ToString('N').Substring(0,12)
$sourceVolume = "sql-lab-psr005-$Provider-$token-source"
$targetVolume = "sql-lab-psr005-$Provider-$token-clone"
$sourceContainer = "sql-lab-psr005-$Provider-$token-source"
$continueContainer = "sql-lab-psr005-$Provider-$token-continue"
$cloneContainer = "sql-lab-psr005-$Provider-$token-clone"
$sourceId = [guid]::NewGuid().ToString('D')
$targetId = [guid]::NewGuid().ToString('D')
$runId = [guid]::NewGuid().ToString('D')
$scopeId = [guid]::NewGuid().ToString('D')
$saPlain = "Psr005_${token}!Aa7"
$completed = $false
$mutexName = if ($IsWindows) { 'Global\SQL_Server_Lab_Runtime_Smoke' } else { 'SQL_Server_Lab_Runtime_Smoke' }
$runtimeMutex = [Threading.Mutex]::new($false,$mutexName)
$mutexAcquired = $false

function Assert-InstanceStoreAcceptance {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Description)
    if (-not $Condition) { throw "CONTAINER_INSTANCE_STORE_ACCEPTANCE_FAILED: $Description" }
    Write-Host "PASS: $Description" -ForegroundColor Green
}

function Get-InstanceStoreFreePort {
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
    try { $listener.Start(); return ([Net.IPEndPoint]$listener.LocalEndpoint).Port }
    finally { $listener.Stop() }
}

function Invoke-InstanceStoreRuntime {
    param([Parameter(Mandatory)][string[]]$Arguments, [switch]$AllowFailure)
    $output = @(& $Provider @Arguments 2>&1)
    if (-not $AllowFailure -and $LASTEXITCODE -ne 0) { throw "CONTAINER_INSTANCE_STORE_RUNTIME_FAILED: $($output -join ' ')" }
    return @($output)
}

function Start-InstanceStoreSqlContainer {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Volume, [Parameter(Mandatory)][int]$Port)
    $mount = if ($Provider -eq 'podman') { "${Volume}:/var/opt/mssql:U" } else { "${Volume}:/var/opt/mssql" }
    $null = Invoke-InstanceStoreRuntime -Arguments @(
        'run','-d','--name',$Name,'-p',"127.0.0.1:${Port}:1433",
        '-e','ACCEPT_EULA=Y','-e',"MSSQL_SA_PASSWORD=$saPlain",'-e','MSSQL_PID=Developer','-e','MSSQL_AGENT_ENABLED=true',
        '--label',"sql-server-lab.run-id=$runId",'--label',"sql-server-lab.scope-id=$scopeId",'-v',$mount,$Image
    )
}

function Wait-InstanceStoreSql {
    param([Parameter(Mandatory)][int]$Port)
    $deadline=[DateTime]::UtcNow.AddSeconds(180)
    do {
        $output=@(& sqlcmd -S "127.0.0.1,$Port" -U sa -P $saPlain -C -b -Q 'SET NOCOUNT ON; SELECT 1;' -h -1 -W 2>$null)
        if ($LASTEXITCODE -eq 0 -and (($output | ForEach-Object { ([string]$_).Trim() }) -contains '1')) { return }
        Start-Sleep -Seconds 2
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'CONTAINER_INSTANCE_STORE_SQL_READINESS_TIMEOUT'
}

function Invoke-InstanceStoreSqlScalar {
    param([Parameter(Mandatory)][int]$Port, [Parameter(Mandatory)][string]$Query, [string]$Database='master')
    $effectiveQuery = "SET NOCOUNT ON; $Query"
    $output=@(& sqlcmd -S "127.0.0.1,$Port" -U sa -P $saPlain -C -b -d $Database -Q $effectiveQuery -h -1 -W 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "CONTAINER_INSTANCE_STORE_SQLCMD_FAILED: $($output -join ' ')" }
    return (($output | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ -and $_ -notmatch '^Changed database context' }) -join '')
}

function Stop-Remove-InstanceStoreContainer {
    param([Parameter(Mandatory)][string]$Name)
    $null = Invoke-InstanceStoreRuntime -Arguments @('stop',$Name) -AllowFailure
    $null = Invoke-InstanceStoreRuntime -Arguments @('rm','-f',$Name) -AllowFailure
}

try {
    Write-Host "PSR-005-Instanzstore-Abnahme: $Provider" -ForegroundColor Cyan
    $mutexAcquired=$runtimeMutex.WaitOne([TimeSpan]::FromMinutes(10))
    if (-not $mutexAcquired) { throw 'CONTAINER_INSTANCE_STORE_RUNTIME_LOCK_TIMEOUT' }
    if ($Provider -eq 'podman') { & (Join-Path $PSScriptRoot 'Initialize-PodmanRuntime.ps1') | Out-Host }
    foreach ($command in @($Provider,'sqlcmd')) {
        Assert-InstanceStoreAcceptance ([bool](Get-Command $command -ErrorAction SilentlyContinue)) "Befehl '$command' ist verfuegbar"
    }
    $null = Invoke-InstanceStoreRuntime -Arguments @('image','inspect',$Image)
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
    Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
    $module=Import-Module $modulePath -Force -PassThru
    & $module {
        param($Runtime,$Volume,$ImageName,$Run,$Scope,$StorageId)
        if ($Runtime -eq 'docker') {
            $null=Initialize-DockerSqlNamedVolume -VolumeName $Volume -Image $ImageName -RunId $Run -ScopeId $Scope -VersionId '2025' -InstanceId 'primary' -ContainerPath '/var/opt/mssql' -PersistentStorageId $StorageId -Persistence 'cataloged-runtime-volume'
        }
        else {
            $null=Initialize-PodmanSqlNamedVolume -VolumeName $Volume -Image $ImageName -RunId $Run -ScopeId $Scope -VersionId '2025' -InstanceId 'primary' -ContainerPath '/var/opt/mssql' -PersistentStorageId $StorageId -Persistence 'cataloged-runtime-volume'
        }
    } $Provider $sourceVolume $Image $runId $scopeId $sourceId

    $initialPort=Get-InstanceStoreFreePort
    Start-InstanceStoreSqlContainer -Name $sourceContainer -Volume $sourceVolume -Port $initialPort
    Wait-InstanceStoreSql -Port $initialPort
    $null=Invoke-InstanceStoreSqlScalar -Port $initialPort -Query "IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name=N'psr005_login') CREATE LOGIN psr005_login WITH PASSWORD=N'Unused_${token}!Aa7'; IF DB_ID(N'Psr005Evidence') IS NULL CREATE DATABASE Psr005Evidence; SELECT 1;"
    $null=Invoke-InstanceStoreSqlScalar -Port $initialPort -Database 'Psr005Evidence' -Query "IF OBJECT_ID(N'dbo.Evidence',N'U') IS NULL BEGIN CREATE TABLE dbo.Evidence(Id int NOT NULL PRIMARY KEY, Marker nvarchar(64) NOT NULL); INSERT dbo.Evidence VALUES(1,N'psr005-$token'); END; SELECT COUNT_BIG(*) FROM dbo.Evidence;"
    Stop-Remove-InstanceStoreContainer -Name $sourceContainer

    $catalog=[PSCustomObject]@{ Status='AVAILABLE'; Document=[PSCustomObject]@{
        ContractVersion='SqlServerLab.PersistentStorageCatalog/1.0'; ControllerId=[guid]::NewGuid().ToString('D'); Revision=1
        Stores=@([PSCustomObject]@{
            PersistentStorageId=$sourceId; DisplayName='PSR005 source'; StorageClass='INSTANCE_STORE'; State='DETACHED'; Provider=$Provider
            LocationBinding=[PSCustomObject]@{ Residency='NATIVE_RUNTIME'; LocationId=$null; ProviderResourceId=$sourceVolume; InventoryObjectId='storage-object-111111111111111111111111'; RelativePath=$null }
            References=@(); Lease=$null; Retention='RETAINED'; CleanupDisposition='PRESERVE'; CreatedAt='2026-09-01T00:00:00Z'; UpdatedAt='2026-09-01T00:00:00Z'
        })
    } }
    $continueIntent=[PSCustomObject]@{ ContractVersion='SqlServerLab.ContainerInstanceStoreIntent/1.0'; OperationId=[guid]::NewGuid().ToString('D'); Action='CONTINUE'; SourcePersistentStorageId=$sourceId; TargetPersistentStorageId=$null; TargetVolumeName=$null; Provider=$Provider; TargetRunId=$runId; TargetScopeId=$scopeId; TargetSqlMajorVersion='2025'; HelperImage=$null }
    $continueEvidence=& $module { param($Intent,$Catalog,$Runtime,$Volume) $inspection=Get-LabContainerInstanceStoreRuntimeInspection -Provider $Runtime -VolumeName $Volume; $plan=Get-LabContainerInstanceStorePlan -Intent $Intent -Catalog $Catalog -RuntimeInspection $inspection; [PSCustomObject]@{ Plan=$plan; Drive=Get-LabContainerInstanceStoreDriveBinding -Plan $plan } } $continueIntent $catalog $Provider $sourceVolume
    Assert-InstanceStoreAcceptance ($continueEvidence.Plan.Status -eq 'READY' -and $continueEvidence.Drive.volumeName -eq $sourceVolume) 'Detached Store wurde ueber stabile Storage-ID fuer Continue ausgewaehlt'
    $alreadyInitialized=& $module {
        param($Runtime,$Drive,$ImageName,$Run,$Scope)
        if ($Runtime -eq 'docker') {
            return Initialize-DockerSqlNamedVolume -VolumeName ([string]$Drive.volumeName) -Image $ImageName -RunId $Run -ScopeId $Scope -VersionId '2025' -InstanceId 'primary' -ContainerPath '/var/opt/mssql' -PersistentStorageId ([string]$Drive.persistentStorageId) -Persistence 'cataloged-runtime-volume'
        }
        return Initialize-PodmanSqlNamedVolume -VolumeName ([string]$Drive.volumeName) -Image $ImageName -RunId $Run -ScopeId $Scope -VersionId '2025' -InstanceId 'primary' -ContainerPath '/var/opt/mssql' -PersistentStorageId ([string]$Drive.persistentStorageId) -Persistence 'cataloged-runtime-volume'
    } $Provider $continueEvidence.Drive $Image $runId $scopeId
    Assert-InstanceStoreAcceptance (-not $alreadyInitialized) 'Provider revalidiert stabile ID und SQL-Major-Version ohne Reinitialisierung'

    $continuePort=Get-InstanceStoreFreePort
    Start-InstanceStoreSqlContainer -Name $continueContainer -Volume $continueEvidence.Drive.volumeName -Port $continuePort
    Wait-InstanceStoreSql -Port $continuePort
    Assert-InstanceStoreAcceptance ((Invoke-InstanceStoreSqlScalar -Port $continuePort -Query "SELECT COUNT_BIG(*) FROM sys.server_principals WHERE name=N'psr005_login';") -eq '1') 'Continue erhaelt den Serverzustand'
    Assert-InstanceStoreAcceptance ((Invoke-InstanceStoreSqlScalar -Port $continuePort -Database 'Psr005Evidence' -Query 'SELECT COUNT_BIG(*) FROM dbo.Evidence WHERE Id=1;') -eq '1') 'Continue erhaelt die Benutzerdatenbank live'
    Stop-Remove-InstanceStoreContainer -Name $continueContainer

    $cloneIntent=[PSCustomObject]@{ ContractVersion='SqlServerLab.ContainerInstanceStoreIntent/1.0'; OperationId=[guid]::NewGuid().ToString('D'); Action='CLONE'; SourcePersistentStorageId=$sourceId; TargetPersistentStorageId=$targetId; TargetVolumeName=$targetVolume; Provider=$Provider; TargetRunId=[guid]::NewGuid().ToString('D'); TargetScopeId=[guid]::NewGuid().ToString('D'); TargetSqlMajorVersion='2025'; HelperImage=$Image }
    $cloneJournal=& $module { param($Intent,$Catalog,$Runtime,$Volume,$Root) $inspection=Get-LabContainerInstanceStoreRuntimeInspection -Provider $Runtime -VolumeName $Volume; $plan=Get-LabContainerInstanceStorePlan -Intent $Intent -Catalog $Catalog -RuntimeInspection $inspection; Invoke-LabContainerInstanceStoreClone -Plan $plan -OperationDirectory $Root } $cloneIntent $catalog $Provider $sourceVolume $testRoot
    Assert-InstanceStoreAcceptance ($cloneJournal.Status -eq 'COMPLETED' -and $cloneJournal.Source.Evidence.Sha256 -eq $cloneJournal.Target.Evidence.Sha256) 'Clone wurde journalisiert und inhaltlich verifiziert'

    $clonePort=Get-InstanceStoreFreePort
    Start-InstanceStoreSqlContainer -Name $cloneContainer -Volume $targetVolume -Port $clonePort
    Wait-InstanceStoreSql -Port $clonePort
    Assert-InstanceStoreAcceptance ((Invoke-InstanceStoreSqlScalar -Port $clonePort -Query "SELECT COUNT_BIG(*) FROM sys.server_principals WHERE name=N'psr005_login';") -eq '1') 'Clone enthaelt den Serverzustand live'
    Assert-InstanceStoreAcceptance ((Invoke-InstanceStoreSqlScalar -Port $clonePort -Database 'Psr005Evidence' -Query "SELECT COUNT_BIG(*) FROM dbo.Evidence WHERE Marker=N'psr005-$token';") -eq '1') 'Clone enthaelt die Benutzerdatenbank live'
    $completed=$true
}
finally {
    if ($completed -or -not $KeepOnFailure) {
        foreach ($container in @($sourceContainer,$continueContainer,$cloneContainer)) {
            $null=Invoke-InstanceStoreRuntime -Arguments @('rm','-f',$container) -AllowFailure
        }
        foreach ($volume in @($sourceVolume,$targetVolume)) {
            $null=Invoke-InstanceStoreRuntime -Arguments @('volume','rm','-f',$volume) -AllowFailure
        }
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    $saPlain=$null
    if ($mutexAcquired) { $runtimeMutex.ReleaseMutex(); $mutexAcquired=$false }
    $runtimeMutex.Dispose()
}
Write-Host 'CONTAINER INSTANCE STORE ACCEPTANCE: PASS' -ForegroundColor Green
