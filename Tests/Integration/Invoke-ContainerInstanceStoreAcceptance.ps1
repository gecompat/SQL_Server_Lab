#Requires -Version 7.2
<#
.SYNOPSIS
    Reale Docker-/Podman-Abnahme fuer Lease, Continue und Clone eines Instanzstores.
.DESCRIPTION
    Erzeugt einen test-eigenen katalogisierbaren SQL-Systemstore, bestaetigt
    Server- und Benutzerdaten nach kontrolliertem Container-Recreate, klont den
    detached Store journalisiert und bestaetigt dieselben Daten im Clone. Ein
    regulärer PersistentData-Store wird stabil gelabelt, geleast und freigegeben.
    Quelle, Ziel, Lease-Volume und Container werden im finally-Scope entfernt.
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
$sourceSidecarVolumes = @("${sourceVolume}-external-languages","${sourceVolume}-external-libraries")
$targetSidecarVolumes = @("${targetVolume}-external-languages","${targetVolume}-external-libraries")
$leaseVolume = "sql-lab-persistent-lease-$Provider-$token"
$sourceContainer = "sql-lab-psr005-$Provider-$token-source"
$continueContainer = "sql-lab-psr005-$Provider-$token-continue"
$cloneContainer = "sql-lab-psr005-$Provider-$token-clone"
$sourceId = [guid]::NewGuid().ToString('D')
$targetId = [guid]::NewGuid().ToString('D')
$runId = [guid]::NewGuid().ToString('D')
$scopeId = [guid]::NewGuid().ToString('D')
$controllerId = [guid]::NewGuid().ToString('D')
$locationId = [guid]::NewGuid().ToString('D')
$dataRoot = Join-Path $testRoot 'Lab_Data'
$saPlain = "Psr005_${token}!Aa7"
$completed = $false
$mutexName = if ($IsWindows) { 'Global\SQL_Server_Lab_Runtime_Smoke' } else { 'SQL_Server_Lab_Runtime_Smoke' }
$runtimeMutex = [Threading.Mutex]::new($false,$mutexName)
$mutexAcquired = $false
$runtimeInvocation = $null
$sqlcmdInvocation = $null

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
    if (-not $script:runtimeInvocation) { throw 'CONTAINER_INSTANCE_STORE_RUNTIME_NOT_RESOLVED' }
    $output = @(& $script:runtimeInvocation @Arguments 2>&1)
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
        $output=@(& $script:sqlcmdInvocation -S "127.0.0.1,$Port" -U sa -P $saPlain -C -b -Q 'SET NOCOUNT ON; SELECT 1;' -h -1 -W 2>$null)
        if ($LASTEXITCODE -eq 0 -and (($output | ForEach-Object { ([string]$_).Trim() }) -contains '1')) { return }
        Start-Sleep -Seconds 2
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'CONTAINER_INSTANCE_STORE_SQL_READINESS_TIMEOUT'
}

function Wait-InstanceStoreDatabase {
    param([Parameter(Mandatory)][int]$Port, [Parameter(Mandatory)][string]$Database)
    $escapedDatabase=$Database.Replace("'","''")
    $deadline=[DateTime]::UtcNow.AddSeconds(120)
    do {
        $output=@(& $script:sqlcmdInvocation -S "127.0.0.1,$Port" -U sa -P $saPlain -C -b -d master `
            -Q "SET NOCOUNT ON; SELECT state_desc FROM sys.databases WHERE name=N'$escapedDatabase';" -h -1 -W 2>$null)
        if ($LASTEXITCODE -eq 0 -and (($output | ForEach-Object { ([string]$_).Trim() }) -contains 'ONLINE')) { return }
        Start-Sleep -Seconds 2
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "CONTAINER_INSTANCE_STORE_DATABASE_READINESS_TIMEOUT: $Database"
}

function Invoke-InstanceStoreSqlScalar {
    param([Parameter(Mandatory)][int]$Port, [Parameter(Mandatory)][string]$Query, [string]$Database='master')
    $effectiveQuery = "SET NOCOUNT ON; $Query"
    $deadline=[DateTime]::UtcNow.AddSeconds(120)
    do {
        $output=@(& $script:sqlcmdInvocation -S "127.0.0.1,$Port" -U sa -P $saPlain -C -b -d $Database -Q $effectiveQuery -h -1 -W 2>&1)
        if ($LASTEXITCODE -eq 0) {
            return (($output | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ -and $_ -notmatch '^Changed database context' }) -join '')
        }
        $message=$output -join ' '
        $transientDatabaseLogin = $Database -ne 'master' -and
            $message -match "Login failed for user 'sa'.*Cannot open database|Cannot open database.*Login failed for user 'sa'"
        if (-not $transientDatabaseLogin -or [DateTime]::UtcNow -ge $deadline) {
            throw "CONTAINER_INSTANCE_STORE_SQLCMD_FAILED: $message"
        }
        Start-Sleep -Seconds 2
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "CONTAINER_INSTANCE_STORE_SQLCMD_TIMEOUT: $Database"
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
    Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
    $module=Import-Module $modulePath -Force -PassThru
    if ($Provider -eq 'podman') { & (Join-Path $PSScriptRoot 'Initialize-PodmanRuntime.ps1') | Out-Host }
    $runtimeInvocation=& $module { param($Name) Get-LabHostToolInvocation -Name $Name } $Provider
    $sqlcmdCommand=Get-Command sqlcmd -CommandType Application -ErrorAction Stop | Select-Object -First 1
    $sqlcmdInvocation=[string]$sqlcmdCommand.Source
    Assert-InstanceStoreAcceptance ([bool]$runtimeInvocation) "Befehl '$Provider' wurde zentral aufgeloest"
    Assert-InstanceStoreAcceptance ([bool]$sqlcmdInvocation) "Befehl 'sqlcmd' wurde zentral aufgeloest"
    $null = Invoke-InstanceStoreRuntime -Arguments @('image','inspect',$Image)
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
    & $module {
        param($Runtime,$Volume,$ImageName,$Run,$Scope,$StorageId)
        if ($Runtime -eq 'docker') {
            $null=Initialize-DockerSqlNamedVolume -VolumeName $Volume -Image $ImageName -RunId $Run -ScopeId $Scope -VersionId '2025' -InstanceId 'primary' -ContainerPath '/var/opt/mssql' -PersistentStorageId $StorageId -Persistence 'cataloged-runtime-volume'
        }
        else {
            $null=Initialize-PodmanSqlNamedVolume -VolumeName $Volume -Image $ImageName -RunId $Run -ScopeId $Scope -VersionId '2025' -InstanceId 'primary' -ContainerPath '/var/opt/mssql' -PersistentStorageId $StorageId -Persistence 'cataloged-runtime-volume'
        }
    } $Provider $sourceVolume $Image $runId $scopeId $sourceId
    $sidecarRoles=@('EXTERNAL_LANGUAGES','EXTERNAL_LIBRARIES')
    for ($sidecarIndex=0; $sidecarIndex -lt $sourceSidecarVolumes.Count; $sidecarIndex++) {
        $sidecarVolume=$sourceSidecarVolumes[$sidecarIndex]
        $sidecarRole=$sidecarRoles[$sidecarIndex]
        $null=Invoke-InstanceStoreRuntime -Arguments @(
            'volume','create','--label',"sql-server-lab.persistent-storage-id=$sourceId",
            '--label','sql-server-lab.sql-major-version=2025','--label',"sql-server-lab.storage-role=$sidecarRole",$sidecarVolume
        )
        $null=Invoke-InstanceStoreRuntime -Arguments @(
            'run','--rm','--user','0:0','--entrypoint','/bin/sh','-v',"${sidecarVolume}:/store",$Image,
            '-c',"printf '%s' '$sidecarRole-$token' > /store/psr005-sidecar-marker"
        )
    }

    $initialPort=Get-InstanceStoreFreePort
    Start-InstanceStoreSqlContainer -Name $sourceContainer -Volume $sourceVolume -Port $initialPort
    Wait-InstanceStoreSql -Port $initialPort
    $null=Invoke-InstanceStoreSqlScalar -Port $initialPort -Query "IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name=N'psr005_login') CREATE LOGIN psr005_login WITH PASSWORD=N'Unused_${token}!Aa7'; IF DB_ID(N'Psr005Evidence') IS NULL CREATE DATABASE Psr005Evidence; SELECT 1;"
    $null=Invoke-InstanceStoreSqlScalar -Port $initialPort -Database 'Psr005Evidence' -Query "IF OBJECT_ID(N'dbo.Evidence',N'U') IS NULL BEGIN CREATE TABLE dbo.Evidence(Id int NOT NULL PRIMARY KEY, Marker nvarchar(64) NOT NULL); INSERT dbo.Evidence VALUES(1,N'psr005-$token'); END; SELECT COUNT_BIG(*) FROM dbo.Evidence;"
    Stop-Remove-InstanceStoreContainer -Name $sourceContainer

    $configuration=[PSCustomObject]@{
        ControllerId=$controllerId
        LabDataLocations=@([PSCustomObject]@{ LocationId=$locationId; LabDataRoot=$dataRoot })
    }
    $catalog=& $module {
        param($Config,$Root,$Runtime,$Volume,$StorageId)
        $null=Initialize-LabManagedDataRoot -DataRoot $Root -ControllerId ([string]$Config.ControllerId) -Confirm:$false
        $document=[PSCustomObject]@{
            ContractVersion='SqlServerLab.PersistentStorageCatalog/1.0'; ControllerId=[string]$Config.ControllerId; Revision=1
            Stores=@([PSCustomObject]@{
                PersistentStorageId=$StorageId; DisplayName='PSR005 source'; StorageClass='INSTANCE_STORE'; State='DETACHED'; Provider=$Runtime
                LocationBinding=[PSCustomObject]@{
                    Residency='NATIVE_RUNTIME'; LocationId=$null; ProviderResourceId=$Volume
                    InventoryObjectId=(Get-LabStorageResidencyObjectId -Key "runtime-volume|$Runtime|$Volume"); RelativePath=$null
                }
                References=@(); Lease=$null; Retention='RETAINED'; CleanupDisposition='PRESERVE'; CreatedAt='2026-09-01T00:00:00Z'; UpdatedAt='2026-09-01T00:00:00Z'
            })
        }
        $null=Write-LabPersistentStorageCatalogDocument -Document $document -Configuration $Config
        Get-LabPersistentStorageCatalog -Configuration $Config
    } $configuration $dataRoot $Provider $sourceVolume $sourceId
    $leaseEvidence=& $module {
        param($Runtime,$Volume,$ImageName,$Run,$Scope,$Root,$Config)
        $lease=Register-LabContainerInstanceStoreLease -Provider $Runtime -VolumeName $Volume `
            -RunId $Run -ScopeId $Scope -SqlVersion '2025' -DisplayName 'Runtime lease acceptance' `
            -DataRoot $Root -Configuration $Config
        if ($Runtime -eq 'docker') {
            $null=Initialize-DockerSqlNamedVolume -VolumeName $Volume -Image $ImageName -RunId $Run -ScopeId $Scope `
                -VersionId '2025' -InstanceId 'lease' -ContainerPath '/var/opt/mssql' `
                -PersistentStorageId ([string]$lease.Store.PersistentStorageId) -Persistence 'data-root-runtime-volume'
        }
        else {
            $null=Initialize-PodmanSqlNamedVolume -VolumeName $Volume -Image $ImageName -RunId $Run -ScopeId $Scope `
                -VersionId '2025' -InstanceId 'lease' -ContainerPath '/var/opt/mssql' `
                -PersistentStorageId ([string]$lease.Store.PersistentStorageId) -Persistence 'data-root-runtime-volume'
        }
        $databaseReferences=Sync-LabContainerInstanceStoreDatabaseReference `
            -PersistentStorageId ([string]$lease.Store.PersistentStorageId) -RunId $Run -ScopeId $Scope `
            -DatabaseName @('LeaseEvidenceOne','LeaseEvidenceTwo') -Configuration $Config
        $released=Unregister-LabContainerInstanceStoreLease -Provider $Runtime -VolumeName $Volume `
            -RunId $Run -ScopeId $Scope -DataRoot $Root -Configuration $Config
        $inspection=Get-LabContainerInstanceStoreRuntimeInspection -Provider $Runtime -VolumeName $Volume
        [PSCustomObject]@{
            Lease=$lease; DatabaseReferences=$databaseReferences; Released=$released; Inspection=$inspection
            Catalog=Get-LabPersistentStorageCatalog -Configuration $Config
        }
    } $Provider $leaseVolume $Image $runId $scopeId $dataRoot $configuration
    $releasedLeaseStore=@($leaseEvidence.Catalog.Document.Stores | Where-Object {
        [string]$_.PersistentStorageId -eq [string]$leaseEvidence.Lease.Store.PersistentStorageId
    })
    Assert-InstanceStoreAcceptance ($leaseEvidence.DatabaseReferences.Changed -and
        @($leaseEvidence.DatabaseReferences.Store.References | Where-Object {
            $_.Kind -eq 'DATABASE' -and $_.State -eq 'ACTIVE'
        }).Count -eq 2 -and $releasedLeaseStore.Count -eq 1 -and $releasedLeaseStore[0].State -eq 'DETACHED' -and
        -not $releasedLeaseStore[0].Lease -and @($releasedLeaseStore[0].References | Where-Object State -eq 'RELEASED').Count -eq 3 -and
        @($releasedLeaseStore[0].References | Where-Object { $_.Kind -eq 'DATABASE' -and $_.State -eq 'ACTIVE' }).Count -eq 0 -and
        [string]$leaseEvidence.Inspection.Labels.'sql-server-lab.persistent-storage-id' -eq [string]$releasedLeaseStore[0].PersistentStorageId) `
        'Regulärer PersistentData-Store wird mit Datenbankreferenzen geleast und atomar ohne Volume-Löschung freigegeben'
    $continueIntent=[PSCustomObject]@{ ContractVersion='SqlServerLab.ContainerInstanceStoreIntent/1.0'; OperationId=[guid]::NewGuid().ToString('D'); Action='CONTINUE'; SourcePersistentStorageId=$sourceId; TargetPersistentStorageId=$null; TargetVolumeName=$null; Provider=$Provider; TargetRunId=$runId; TargetScopeId=$scopeId; TargetSqlMajorVersion='2025'; HelperImage=$null; IncludeExternalRuntimeSidecars=$true }
    $continueEvidence=& $module {
        param($Intent,$Catalog,$Runtime,$Volume,$Sidecars,$Root)
        $inspection=Get-LabContainerInstanceStoreRuntimeInspection -Provider $Runtime -VolumeName $Volume
        $sidecarInspection=@($Sidecars | ForEach-Object { Get-LabContainerInstanceStoreRuntimeInspection -Provider $Runtime -VolumeName $_ })
        $plan=Get-LabContainerInstanceStorePlan -Intent $Intent -Catalog $Catalog -RuntimeInspection $inspection -SidecarRuntimeInspection $sidecarInspection
        $instance=[PSCustomObject]@{ drives=@() }
        $null=Add-LabSelectedPersistentContainerDrive -Instance $instance -Plan $plan -Storage ([PSCustomObject]@{ BackupRoot=(Join-Path $Root 'backups') }) -IncludeExternalRuntimeState
        [PSCustomObject]@{ Plan=$plan; Drive=Get-LabContainerInstanceStoreDriveBinding -Plan $plan; Instance=$instance }
    } $continueIntent $catalog $Provider $sourceVolume $sourceSidecarVolumes $testRoot
    Assert-InstanceStoreAcceptance ($continueEvidence.Plan.Status -eq 'READY' -and $continueEvidence.Drive.volumeName -eq $sourceVolume -and
        @($continueEvidence.Instance.drives | Where-Object { $_.persistentStorageRole -in @('EXTERNAL_LANGUAGES','EXTERNAL_LIBRARIES') }).Count -eq 2) `
        'Detached Mehr-Volume-Store wurde ueber stabile Storage-ID fuer Continue ausgewaehlt'
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
    Wait-InstanceStoreDatabase -Port $continuePort -Database 'Psr005Evidence'
    Assert-InstanceStoreAcceptance ((Invoke-InstanceStoreSqlScalar -Port $continuePort -Database 'Psr005Evidence' -Query 'SELECT COUNT_BIG(*) FROM dbo.Evidence WHERE Id=1;') -eq '1') 'Continue erhaelt die Benutzerdatenbank live'
    Stop-Remove-InstanceStoreContainer -Name $continueContainer

    $cloneIntent=[PSCustomObject]@{ ContractVersion='SqlServerLab.ContainerInstanceStoreIntent/1.0'; OperationId=[guid]::NewGuid().ToString('D'); Action='CLONE'; SourcePersistentStorageId=$sourceId; TargetPersistentStorageId=$targetId; TargetVolumeName=$targetVolume; Provider=$Provider; TargetRunId=[guid]::NewGuid().ToString('D'); TargetScopeId=[guid]::NewGuid().ToString('D'); TargetSqlMajorVersion='2025'; HelperImage=$Image; IncludeExternalRuntimeSidecars=$true }
    $cloneResult=& $module {
        param($Intent,$Catalog,$Runtime,$Volume,$Sidecars,$Root,$Config)
        $inspection=Get-LabContainerInstanceStoreRuntimeInspection -Provider $Runtime -VolumeName $Volume
        $sidecarInspection=@($Sidecars | ForEach-Object { Get-LabContainerInstanceStoreRuntimeInspection -Provider $Runtime -VolumeName $_ })
        $plan=Get-LabContainerInstanceStorePlan -Intent $Intent -Catalog $Catalog -RuntimeInspection $inspection -SidecarRuntimeInspection $sidecarInspection
        $journal=Invoke-LabContainerInstanceStoreClone -Plan $plan -OperationDirectory $Root -Configuration $Config
        [PSCustomObject]@{ Journal=$journal; Catalog=Get-LabPersistentStorageCatalog -Configuration $Config }
    } $cloneIntent $catalog $Provider $sourceVolume $sourceSidecarVolumes $testRoot $configuration
    $cloneJournal=$cloneResult.Journal
    Assert-InstanceStoreAcceptance ($cloneJournal.Status -eq 'COMPLETED' -and $cloneJournal.Source.Evidence.Sha256 -eq $cloneJournal.Target.Evidence.Sha256 -and
        @($cloneJournal.Sidecars | Where-Object { $_.Source.Evidence.Sha256 -eq $_.Target.Evidence.Sha256 }).Count -eq 2) `
        'Mehr-Volume-Clone wurde journalisiert und fuer Hauptvolume plus Sidecars inhaltlich verifiziert'
    for ($sidecarIndex=0; $sidecarIndex -lt $targetSidecarVolumes.Count; $sidecarIndex++) {
        $marker=@(Invoke-InstanceStoreRuntime -Arguments @(
            'run','--rm','--entrypoint','/bin/sh','-v',"$($targetSidecarVolumes[$sidecarIndex]):/store:ro",$Image,
            '-c','cat /store/psr005-sidecar-marker'
        ) | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
        Assert-InstanceStoreAcceptance (($marker -join '') -eq "$($sidecarRoles[$sidecarIndex])-$token") `
            "Clone enthaelt den Marker des Sidecars $($sidecarRoles[$sidecarIndex])"
    }
    $catalogedTargets=@($cloneResult.Catalog.Document.Stores | Where-Object PersistentStorageId -eq $targetId)
    Assert-InstanceStoreAcceptance ($cloneResult.Catalog.Status -eq 'AVAILABLE' -and $catalogedTargets.Count -eq 1 -and
        $catalogedTargets[0].State -eq 'DETACHED' -and $catalogedTargets[0].LocationBinding.ProviderResourceId -eq $targetVolume) 'Clone-Ziel wurde controllergebunden in den persistenten Katalog committed'

    $clonePort=Get-InstanceStoreFreePort
    Start-InstanceStoreSqlContainer -Name $cloneContainer -Volume $targetVolume -Port $clonePort
    Wait-InstanceStoreSql -Port $clonePort
    Assert-InstanceStoreAcceptance ((Invoke-InstanceStoreSqlScalar -Port $clonePort -Query "SELECT COUNT_BIG(*) FROM sys.server_principals WHERE name=N'psr005_login';") -eq '1') 'Clone enthaelt den Serverzustand live'
    Wait-InstanceStoreDatabase -Port $clonePort -Database 'Psr005Evidence'
    Assert-InstanceStoreAcceptance ((Invoke-InstanceStoreSqlScalar -Port $clonePort -Database 'Psr005Evidence' -Query "SELECT COUNT_BIG(*) FROM dbo.Evidence WHERE Marker=N'psr005-$token';") -eq '1') 'Clone enthaelt die Benutzerdatenbank live'
    $completed=$true
}
finally {
    if ($completed -or -not $KeepOnFailure) {
        foreach ($container in @($sourceContainer,$continueContainer,$cloneContainer)) {
            $null=Invoke-InstanceStoreRuntime -Arguments @('rm','-f',$container) -AllowFailure
        }
        foreach ($volume in @($sourceVolume,$targetVolume,$leaseVolume) + $sourceSidecarVolumes + $targetSidecarVolumes) {
            $null=Invoke-InstanceStoreRuntime -Arguments @('volume','rm','-f',$volume) -AllowFailure
        }
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    $saPlain=$null
    if ($mutexAcquired) { $runtimeMutex.ReleaseMutex(); $mutexAcquired=$false }
    $runtimeMutex.Dispose()
}
Write-Host 'CONTAINER INSTANCE STORE ACCEPTANCE: PASS' -ForegroundColor Green
