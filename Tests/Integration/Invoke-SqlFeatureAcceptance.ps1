#Requires -Version 7.2
<#
.SYNOPSIS
    Native FTS-Abnahme je Provider; FILESTREAM-Inhalt unter Hyper-V.
.DESCRIPTION
    Erzeugt einen eigenen Run, Volltextkatalog/-index und Suchdaten. Prüft
    CONTAINS, FREETEXT, CONTAINSTABLE, Dependency-Guard, Remove/Add und Restart.
    Hyper-V prüft zusätzlich FILESTREAM-BLOBs und Disable nach eigenem Cleanup.
    Es werden keine vorhandenen Runs verändert. Volle Logs bleiben lokal.
#>
[CmdletBinding()]
param([Parameter(Mandatory)][ValidateSet('docker','podman','hyperv')][string]$Provider,
    [string]$StateRoot,[string]$ArtifactId,[string]$MediaRoot,[string]$SqlMediaPath,[string]$SwitchName,
    [ValidateRange(0,3600)][int]$HostLockWaitSeconds=60)
$ErrorActionPreference='Stop'
$repo=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$token=[guid]::NewGuid().ToString('N');$root=Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-features-'+$token)
$database='Feature'+$token;$lab=$null;$module=$null;$arrange=$false;$complete=$false;$cleanup=$false;$nativeBinding=$null
$operation=[guid]::NewGuid().ToString('D');$oldState=$env:SQL_SERVER_LAB_STATE;$oldData=$env:SQL_SERVER_LAB_DATA_ROOT
$mutex=[Threading.Mutex]::new($false,$(if($IsWindows){'Global\SQL_Server_Lab_Runtime_Smoke'}else{'SQL_Server_Lab_Runtime_Smoke'}));$locked=$false
function Assert-NativeFeature {param([bool]$Condition,[string]$Name)if(-not $Condition){throw "SQL_FEATURE_ACCEPTANCE_FAILED: $Name"};Write-Host "PASS: $Name"}
function Invoke-FeatureSql {param([string]$Query) & $module {param($Run,$State,$Sql)$context=Get-LabSqlFeatureContext -RunId $Run -InstanceId primary -StateRoot $State;Invoke-LabSqlFeatureSql -Context $context -Query $Sql} $lab.RunId $StateRoot $Query}
function Wait-FeatureSql {
    param([ValidateRange(0,180)][int]$TimeoutSeconds=180)
    if($Provider -eq 'hyperv'){
        # Master accepts connections before user databases can autostart.
        # Open our database read-only before proceeding; never retry fixture DDL.
        $deadline=[datetime]::UtcNow.AddSeconds($TimeoutSeconds)
        do {
            try {
                & $module {
                    param($Run,$State,$DatabaseName)
                    $context=Get-LabSqlFeatureContext -RunId $Run -InstanceId primary -StateRoot $State
                    $null=Get-LabSqlFeatureObservation -Context $context
                    $rows=@(Invoke-LabSqlFeatureSql -Context $context -Query ("USE ["+$DatabaseName+"];SELECT CONVERT(nvarchar(60),DATABASEPROPERTYEX(DB_NAME(),'Status')) AS DatabaseStatus;"))
                    if($rows.Count -ne 1 -or $rows[0].DatabaseStatus -cne 'ONLINE'){throw 'SQL_FEATURE_ACCEPTANCE_DATABASE_NOT_READY'}
                } $lab.RunId $StateRoot $database
                return
            } catch {
                if([datetime]::UtcNow -ge $deadline){throw}
                Start-Sleep -Seconds 2
            }
        } while($true)
    }
}
function Set-Feature {param([string]$Feature,[bool]$Enabled) Set-SqlServerLabFeature -RunId $lab.RunId -InstanceId primary -Feature $Feature -Enabled $Enabled -StateRoot $StateRoot -MediaRoot $MediaRoot -SqlMediaPath $SqlMediaPath -Confirm:$false}
try {
    Write-Host 'WAIT: global runtime slot; no resources arranged'
    try{$locked=$mutex.WaitOne([timespan]::FromSeconds($HostLockWaitSeconds))}catch [Threading.AbandonedMutexException]{$locked=$true}
    if(-not $locked){throw 'SQL_FEATURE_ACCEPTANCE_HOST_BUSY'}
    if($Provider -in @('docker','podman')){
        $resolution=@(& (Join-Path $repo 'Tools/Initialize-SqlServerLabHostTools.ps1') -Name $Provider)[0]
        if(-not $resolution.Available){throw 'SQL_FEATURE_ACCEPTANCE_TOOL_UNRESOLVED'}
    }
    $readiness=& (Join-Path $repo 'Tools/Test-SqlServerLabClientReadiness.ps1') -Provider $Provider -Operation Create
    if($readiness.Status -notin @('READY','READY_WITH_WARNINGS')){throw 'SQL_FEATURE_ACCEPTANCE_CLIENT_NOT_READY'}
    $module=Import-Module (Join-Path $repo 'SqlServerLab.psd1') -Force -PassThru
    $null=New-Item -ItemType Directory -Path $root
    if($Provider -eq 'hyperv'){
        # This prepared-image clone injects OOBE through Mount-VHD, which needs
        # elevation even when ordinary Hyper-V lifecycle access is available.
        $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
        try {
            if(-not ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'SQL_FEATURE_ACCEPTANCE_OFFLINE_OOBE_ELEVATION_REQUIRED'}
        } finally {$identity.Dispose()}
        if(-not $ArtifactId){throw 'SQL_FEATURE_ACCEPTANCE_PREPARED_ARTIFACT_REQUIRED'}
        if(-not $StateRoot){$StateRoot=& $module {Get-LabStateRoot}}
        $network=& $module {param($Name)Resolve-LabHyperVNetworkBoundPlan -Intent hostOnly -SwitchName $Name} $SwitchName
        if($network.Status -cne 'READY' -or @($network.Actions).Count){throw 'SQL_FEATURE_ACCEPTANCE_EXISTING_HOSTONLY_NETWORK_REQUIRED'}
        # SQL feature tests do not require Windows online activation. Select the
        # supported non-activation intent explicitly; never add activation egress.
        $draft=[ordered]@{name='sql-feature-acceptance';instances=@([ordered]@{id='primary';version='2025';provider='hyperv';os='windows';network=@{intent='hostOnly';exposure='host'};windowsActivation=@{ContractVersion='SqlServerLab.WindowsActivationIntent/1.0';Strategy='NotRequested';EgressPolicy='Denied'};sqlFeatures=@{fullText=$true;fileStream=$true};hyperv=@{preparedImageId=$ArtifactId;switchName=[string]$network.Name;memoryStartupMB=6144;dynamicMemoryEnabled=$false;processorCount=2}})}
        $manifest=Join-Path $root 'lab.json';$draft|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $manifest
        $arrange=$true
        $lab=& $module {param($Manifest,$State,$Op)Invoke-WithLabWorkflowOperationContext -OperationId $Op -ScriptBlock {param($M,$S)New-SqlServerLab -Manifest $M -StateRoot $S -GuestPassword (New-HyperVSqlUnattendedPassword) -SqlSaPassword (New-HyperVSqlUnattendedPassword) -NonInteractive -RequireExistingHyperVNetwork} -ArgumentList @($Manifest,$State)} $manifest $StateRoot $operation
    } else {
        $StateRoot=Join-Path $root 'state';$data=Join-Path $root 'Lab_Data'
        $env:SQL_SERVER_LAB_STATE=$StateRoot;$env:SQL_SERVER_LAB_DATA_ROOT=$data
        & $module {param($Data)$null=Initialize-LabManagedDataRoot -DataRoot $Data -ControllerId ([guid]::NewGuid().ToString('D')) -Confirm:$false} $data
        $arrange=$true
        $lab=& $module {param($P,$S,$Op)Invoke-WithLabWorkflowOperationContext -OperationId $Op -ScriptBlock {param($P,$S)New-SqlServerLab -Version 2025 -Provider $P -LabName sql-feature-acceptance -StateRoot $S -GenerateSaPassword -NonInteractive -Cpu 1 -MemoryMB 2560 -FullText $true -FileStream $false -Drives @([pscustomobject]@{id='feature-data';containerPath='/var/opt/mssql'})} -ArgumentList @($P,$S)} $Provider $StateRoot $operation
        $rejected=$false;try{$null=Set-Feature FileStream $true}catch{$rejected=$_.Exception.Message -like 'SQL_FEATURE_FILESTREAM_WINDOWS_REQUIRED*'}
        Assert-NativeFeature $rejected 'Linux FILESTREAM activation rejects'
    }
    Assert-NativeFeature ($lab.State -ieq 'RUNNING') 'Public create with feature intent'
    if($Provider -ne 'hyperv'){$nativeBinding=& $module {param($Run,$State,$Op)Get-LabTransferBinding -RunId $Run -InstanceId primary -StateRoot $State -OperationId $Op} $lab.RunId $StateRoot $operation}
    $null=Invoke-FeatureSql "CREATE DATABASE [$database];"
    $fixtureSql=@"
USE [$database];
CREATE TABLE dbo.Documents(Id int NOT NULL CONSTRAINT PK_Documents PRIMARY KEY,Body nvarchar(400) NOT NULL);
INSERT dbo.Documents VALUES(1,N'backup recovery protects database'),(2,N'network switches route traffic'),(3,N'backup archive recovery');
CREATE FULLTEXT CATALOG FeatureCatalog;
CREATE FULLTEXT INDEX ON dbo.Documents(Body LANGUAGE 1033) KEY INDEX PK_Documents ON FeatureCatalog WITH CHANGE_TRACKING AUTO,STOPLIST=OFF;
"@
    $null=Invoke-FeatureSql $fixtureSql
    $queries=@"
USE [$database];
DECLARE @deadline datetime2=DATEADD(second,90,SYSUTCDATETIME());
WHILE (SELECT COUNT(*) FROM dbo.Documents WHERE CONTAINS(Body,'backup'))<>2 AND SYSUTCDATETIME()<@deadline WAITFOR DELAY '00:00:01';
SELECT (SELECT COUNT(*) FROM sys.fulltext_indexes) AS IndexCount,
 (SELECT COUNT(*) FROM dbo.Documents WHERE CONTAINS(Body,'backup') AND Id IN (1,3)) AS ContainsHits,
 (SELECT COUNT(*) FROM dbo.Documents WHERE FREETEXT(Body,'backup')) AS FreeTextHits,
 (SELECT COUNT(*) FROM CONTAINSTABLE(dbo.Documents,Body,'backup') WHERE [KEY] IN (1,3) AND [RANK]>0) AS RankedHits,
 (SELECT COUNT(*) FROM dbo.Documents WHERE CONTAINS(Body,'unfindabletoken')) AS NegativeHits;
"@
    $hits=@(Invoke-FeatureSql $queries)
    Assert-NativeFeature ($hits.Count -eq 1 -and $hits[0].IndexCount -eq 1 -and $hits[0].ContainsHits -eq 2 -and $hits[0].FreeTextHits -eq 2 -and $hits[0].RankedHits -eq 2 -and $hits[0].NegativeHits -eq 0) 'Real index: CONTAINS/FREETEXT/CONTAINSTABLE and negative search'
    $blocked=$false;try{$null=Set-Feature FullText $false}catch{$blocked=$_.Exception.Message -like '*SQL_FEATURE_DEPENDENCIES_EXIST*'}
    Assert-NativeFeature $blocked 'FullText removal preserves dependent index'
    $null=Restart-SqlServerLab -RunId $lab.RunId -StateRoot $StateRoot -Confirm:$false
    Wait-FeatureSql
    $hits=@(Invoke-FeatureSql $queries)
    Assert-NativeFeature ($hits[0].ContainsHits -eq 2 -and $hits[0].RankedHits -eq 2) 'Index and search survive restart'
    $null=Invoke-FeatureSql "ALTER DATABASE [$database] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;DROP DATABASE [$database];"
    $off=Set-Feature FullText $false
    Assert-NativeFeature ($off.Status -eq 'VERIFIED' -and -not $off.Enabled) 'FullText physically removed after own DB cleanup'
    $on=Set-Feature FullText $true
    Assert-NativeFeature ($on.Status -eq 'VERIFIED' -and $on.Enabled) 'FullText added again on same engine build'
    $null=Invoke-FeatureSql "CREATE DATABASE [$database];"
    $null=Invoke-FeatureSql $fixtureSql
    $hits=@(Invoke-FeatureSql $queries)
    Assert-NativeFeature ($hits[0].ContainsHits -eq 2 -and $hits[0].FreeTextHits -eq 2 -and $hits[0].RankedHits -eq 2) 'Reinstalled FullText executes actual index/search again'
    $null=Invoke-FeatureSql "ALTER DATABASE [$database] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;DROP DATABASE [$database];"
    if($Provider -eq 'hyperv'){
        $null=Invoke-FeatureSql @"
DECLARE @path nvarchar(4000)=CONVERT(nvarchar(4000),SERVERPROPERTY('InstanceDefaultDataPath'))+N'${database}_FS';
DECLARE @sql nvarchar(max)=N'CREATE DATABASE [$database] ON PRIMARY (NAME=N''${database}_Data'',FILENAME=N'''+REPLACE(CONVERT(nvarchar(4000),SERVERPROPERTY('InstanceDefaultDataPath'))+N'${database}.mdf','''','''''')+N'''),FILEGROUP FeatureFS CONTAINS FILESTREAM (NAME=N''${database}_FS'',FILENAME=N'''+REPLACE(@path,'''','''''')+N''');';
EXEC(@sql);
"@
        $blob=@(Invoke-FeatureSql @"
USE [$database];
CREATE TABLE dbo.Blobs(Id uniqueidentifier ROWGUIDCOL NOT NULL UNIQUE,Payload varbinary(max) FILESTREAM NULL);
INSERT dbo.Blobs VALUES(NEWID(),0x010203040506);
SELECT COUNT(*) AS Stored FROM dbo.Blobs WHERE Payload=0x010203040506;
UPDATE dbo.Blobs SET Payload=0x0A0B0C;
SELECT COUNT(*) AS Updated FROM dbo.Blobs WHERE Payload=0x0A0B0C;
"@)
        Assert-NativeFeature ($blob.Count -eq 2 -and $blob[0].Stored -eq 1 -and $blob[1].Updated -eq 1) 'FILESTREAM stores and updates actual BLOB bytes'
        $null=Restart-SqlServerLab -RunId $lab.RunId -StateRoot $StateRoot -Confirm:$false
        Wait-FeatureSql
        $persisted=@(Invoke-FeatureSql "USE [$database];SELECT COUNT(*) AS Preserved FROM dbo.Blobs WHERE Payload=0x0A0B0C;")
        Assert-NativeFeature ($persisted.Count -eq 1 -and $persisted[0].Preserved -eq 1) 'FILESTREAM BLOB bytes survive restart'
        $blocked=$false;try{$null=Set-Feature FileStream $false}catch{$blocked=$_.Exception.Message -like '*SQL_FEATURE_DEPENDENCIES_EXIST*'}
        Assert-NativeFeature $blocked 'FILESTREAM disable preserves dependent data'
        $null=Invoke-FeatureSql "ALTER DATABASE [$database] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;DROP DATABASE [$database];"
        $off=Set-Feature FileStream $false
        Assert-NativeFeature ($off.Status -eq 'VERIFIED' -and -not $off.Enabled) 'FILESTREAM disabled after own DB cleanup'
    }
    $complete=$true
} finally {
    if($arrange -and $module){
        try {
            $owned=& $module {param($Op,$State)Get-LabOperationOwnedRun -OperationId $Op -StateRoot $State} $operation $StateRoot
            if($owned){
                $result=Remove-SqlServerLab -RunId $owned.runId -StateRoot $StateRoot -Force -Confirm:$false
                Assert-NativeFeature ($result.Status -eq 'REMOVED') 'Own run removed'
                if($nativeBinding){& $module {param($Binding)Assert-LabTransferNoResidue -Binding $Binding} $nativeBinding}
                if($Provider -eq 'hyperv' -and $lab){$remaining=Get-VM -Id ([guid]$lab.Instances[0].vmId) -ErrorAction SilentlyContinue;Assert-NativeFeature (-not $remaining) 'Own VM absent after public cleanup'}
                $cleanup=$true
            }
            elseif(-not $lab){$cleanup=$true}
        } catch {Write-Warning 'SQL_FEATURE_ACCEPTANCE_CLEANUP_RECOVERY_REQUIRED'}
    }
    $env:SQL_SERVER_LAB_STATE=$oldState;$env:SQL_SERVER_LAB_DATA_ROOT=$oldData
    if($module){Remove-Module $module.Name -Force}
    if($locked){$mutex.ReleaseMutex()};$mutex.Dispose()
}
if(-not $complete -or -not $cleanup){throw 'SQL_FEATURE_ACCEPTANCE_INCOMPLETE'}
Write-Host "SQL FEATURE ACCEPTANCE: PASS ($Provider; native SQL; own cleanup)"
