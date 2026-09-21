#Requires -Version 7.2
<#
.SYNOPSIS
    Belegt öffentliche Katalog-Recovery eines eigenen retained Docker-/Podman-Stores.
.DESCRIPTION
    Erzeugt einen frischen PersistentData-Run mit SQL-Marker und Serverobjekt,
    entfernt den Run, simuliert ausschließlich in dessen isoliertem Testkatalog
    eine verlorene Bindung und verwendet anschließend Repair und Continue.
    Keine vorhandenen Benutzerstores, Labels oder Hostdefaults werden geändert.
#>
[CmdletBinding()]
param([Parameter(Mandatory)][ValidateSet('docker','podman')][string]$Provider,[string]$Version='2025')
$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-recovery-acceptance-'+[guid]::NewGuid().ToString('N'))
$stateRoot=Join-Path $testRoot 'state';$dataRoot=Join-Path $testRoot 'Lab_Data'
$previous=@{State=$env:SQL_SERVER_LAB_STATE;Data=$env:SQL_SERVER_LAB_DATA_ROOT;TestData=$env:SQL_SERVER_LAB_TEST_DATA_ROOT}
$module=$null;$runtimeInvocation=$null;$volume=$null;$original=$null;$continued=$null;$ownedScope=$null;$storageId=$null;$runtimeId=$null
$token=[guid]::NewGuid().ToString('N');$plain="Recovery_${token}!Aa7";$completed=$false;$cleanupErrors=[Collections.Generic.List[string]]::new()
$mutex=[Threading.Mutex]::new($false,$(if($IsWindows){'Global\SQL_Server_Lab_Runtime_Smoke'}else{'SQL_Server_Lab_Runtime_Smoke'}));$acquired=$false
function Assert-RecoveryAcceptance {param([bool]$Success,[string]$Name)if(-not $Success){throw "RECOVERY_ACCEPTANCE_FAILED: $Name"};Write-Host "PASS: $Name"}
try {
    $acquired=$mutex.WaitOne([TimeSpan]::FromSeconds(30));if(-not $acquired){throw 'RECOVERY_ACCEPTANCE_LOCK_TIMEOUT'}
    New-Item -ItemType Directory -Path $testRoot | Out-Null
    $env:SQL_SERVER_LAB_STATE=$stateRoot;$env:SQL_SERVER_LAB_DATA_ROOT=$dataRoot;$env:SQL_SERVER_LAB_TEST_DATA_ROOT=Join-Path $testRoot 'test-data'
    $module=Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru
    $resolution=@(& (Join-Path $repoRoot 'Tools/Initialize-SqlServerLabHostTools.ps1') -Name $Provider)[0]
    if(-not $resolution.Available){throw 'RECOVERY_ACCEPTANCE_RUNTIME_UNAVAILABLE'};$runtimeInvocation=[string]$resolution.Invocation
    $scope=& $module {param($p)Get-LabContainerRuntimeScope -Provider $p} $Provider
    Assert-RecoveryAcceptance ($scope.Status -ceq 'AVAILABLE') 'Provider-Runtime ist eindeutig gebunden'
    $runtimeId=$scope.RuntimeId
    & $module {param($root)Initialize-LabManagedDataRoot -DataRoot $root -ControllerId ([guid]::NewGuid().ToString('D')) -Confirm:$false | Out-Null} $dataRoot
    $password=ConvertTo-SecureString $plain -AsPlainText -Force
    $newArgs=@{Version=$Version;Provider=$Provider;PersistentData=$true;Profile='compact';Cpu=1;MemoryMB=2560;LabName=('recovery-'+$token.Substring(0,8));
        DataRoot=$dataRoot;StateRoot=$stateRoot;SaPassword=$password;SkipAssessment=$true}
    $original=New-SqlServerLab @newArgs
    Assert-RecoveryAcceptance ($original.State -ceq 'Running') 'Eigener retained SQL-Run wurde erstellt'
    $ownedScope=$original.ScopeId
    $store=& $module {param($root,$run)$config=Get-LabStorageConfiguration -DataRoot $root;@( (Get-LabPersistentStorageCatalog -Configuration $config).Document.Stores|Where-Object {$_.Lease.RunId -eq $run})[0]} $dataRoot $original.RunId
    $storageId=[string]$store.PersistentStorageId;$volume=[string]$store.LocationBinding.ProviderResourceId
    Assert-RecoveryAcceptance ($store.Retention -ceq 'RETAINED' -and $store.Lease.ScopeId -ceq $ownedScope) 'Store ist ausschließlich an den eigenen Run gebunden'
    $labelsBefore=& $module {param($p,$v)(Get-LabContainerInstanceStoreRuntimeInspection -Provider $p -VolumeName $v).Labels|ConvertTo-Json -Compress} $Provider $volume
    $instance=$original.Instances[0]
    & $module {param($hostName,$port,$secret,$marker)
        Invoke-SqlQuery -HostName $hostName -Port $port -SaPlain $secret -Query "CREATE LOGIN RecoveryProbe WITH PASSWORD=N'Unused_${marker}!Aa7'; CREATE DATABASE RecoveryProbe;" | Out-Null
        Invoke-SqlQuery -HostName $hostName -Port $port -SaPlain $secret -Database RecoveryProbe -Query "CREATE TABLE dbo.Probe(Id int NOT NULL PRIMARY KEY, Marker varchar(32) NOT NULL); INSERT dbo.Probe VALUES(1,'$marker');" | Out-Null
    } $instance.Host $instance.Port $plain $token
    $removed=Remove-SqlServerLab -RunId $original.RunId -StateRoot $stateRoot -Force -Confirm:$false
    Assert-RecoveryAcceptance ($removed.Errors -eq 0 -and $removed.Cleanup -ceq 'CLEANUP_SUCCEEDED') 'Ursprünglicher Run ist sauber entfernt; SQL-Store bleibt detached'
    & $module {param($root,$id,$expectedRun,$expectedScope)
        $config=Get-LabStorageConfiguration -DataRoot $root;$catalog=Get-LabPersistentStorageCatalog -Configuration $config
        $mutation={param($doc)
            $own=@($doc.Stores|Where-Object PersistentStorageId -eq $id)
            if($doc.Stores.Count -ne 1 -or $own.Count -ne 1 -or $own[0].State -cne 'DETACHED' -or $own[0].Lease -or @($own[0].References|Where-Object State -eq 'ACTIVE').Count -gt 0 -or
                @($own[0].References|Where-Object {$_.Kind -ceq 'RUN' -and $_.TargetId -ceq $expectedRun -and $_.State -ceq 'RELEASED'}).Count -ne 1){throw 'RECOVERY_ACCEPTANCE_LOST_CATALOG_SCOPE_INVALID'}
            $doc.Stores=@()
        }.GetNewClosure()
        Invoke-LabPersistentStorageCatalogMutation -Configuration $config -MutationName SIMULATE_OWN_LOST_BINDING -ExpectedRevision $catalog.Document.Revision -Mutation $mutation | Out-Null
    } $dataRoot $storageId $original.RunId $ownedScope
    $repairArgs=@{OriginalRunId=$original.RunId;InstanceId='primary';ExpectedPersistentStorageId=$storageId;ExpectedRuntimeScopeId=$runtimeId;DataRoot=$dataRoot;StateRoot=$stateRoot}
    $preview=Repair-SqlServerLabPersistentStorageCatalog @repairArgs -WhatIf
    Assert-RecoveryAcceptance ($preview.Status -ceq 'PLANNED') 'Öffentliche Recovery-Vorschau ist ausführbar'
    $repaired=Repair-SqlServerLabPersistentStorageCatalog @repairArgs -Confirm:$false
    $repeat=Repair-SqlServerLabPersistentStorageCatalog @repairArgs -Confirm:$false
    Assert-RecoveryAcceptance ($repaired.Status -ceq 'RECOVERED' -and $repeat.Status -ceq 'NO_CHANGE' -and $repaired.PersistentStorageId -ceq $storageId) 'Recovery erhält UUID und bleibt idempotent'
    $newArgs.LabName='continued-'+$token.Substring(0,8);$newArgs.PersistentStorageId=$storageId;$newArgs.PersistentStorageAction='CONTINUE'
    $continued=New-SqlServerLab @newArgs
    $instance=$continued.Instances[0]
    $proof=& $module {param($hostName,$port,$secret,$marker)
        Invoke-SqlQuery -HostName $hostName -Port $port -SaPlain $secret -Query "IF NOT EXISTS(SELECT 1 FROM sys.server_principals WHERE name=N'RecoveryProbe') THROW 51000,'SERVER_OBJECT_MISSING',1; IF NOT EXISTS(SELECT 1 FROM RecoveryProbe.dbo.Probe WHERE Id=1 AND Marker='$marker') THROW 51000,'DATABASE_MARKER_MISSING',1; SELECT 'RECOVERY_CONTENT_PASS';"
    } $instance.Host $instance.Port $plain $token
    Assert-RecoveryAcceptance (($proof -join '') -match 'RECOVERY_CONTENT_PASS') 'Öffentliches Continue erhält Serverobjekt und SQL-Marker'
    $labelsAfter=& $module {param($p,$v)(Get-LabContainerInstanceStoreRuntimeInspection -Provider $p -VolumeName $v).Labels|ConvertTo-Json -Compress} $Provider $volume
    Assert-RecoveryAcceptance ($labelsBefore -ceq $labelsAfter) 'Originale Volume-Labels bleiben unverändert'
    $completed=$true
}
finally {
    if($module -and -not $volume -and (Test-Path -LiteralPath (Join-Path $dataRoot 'Catalog/persistent-stores.json'))){
        try {
            $candidate=& $module {param($root,$states)
                $catalog=Get-LabPersistentStorageCatalog -Configuration (Get-LabStorageConfiguration -DataRoot $root)
                $stores=@($catalog.Document.Stores)
                if($stores.Count -gt 1){throw 'OWN_PARTIAL_STORE_AMBIGUOUS'}
                if($stores.Count -eq 1){
                    $runs=@($stores[0].References|Where-Object Kind -eq RUN)
                    if($runs.Count -ne 1){throw 'OWN_PARTIAL_STORE_RUN_UNRESOLVED'}
                    $state=Get-LabRunState -RunId $runs[0].TargetId -StateRoot $states
                    if(-not $state -or $state.runId -cne $runs[0].TargetId){throw 'OWN_PARTIAL_STORE_RUN_UNRESOLVED'}
                    [pscustomobject]@{Store=$stores[0];Scope=$state.scopeId}
                }
            } $dataRoot $stateRoot
            if($candidate){$volume=[string]$candidate.Store.LocationBinding.ProviderResourceId;$storageId=[string]$candidate.Store.PersistentStorageId;$ownedScope=[string]$candidate.Scope}
        }catch{$cleanupErrors.Add($_.Exception.Message)}
    }
    if($module -and (Test-Path -LiteralPath (Join-Path $stateRoot 'runs'))){
        foreach($runDir in @(Get-ChildItem -LiteralPath (Join-Path $stateRoot 'runs') -Directory)){
            try {
                $result=Remove-SqlServerLab -RunId $runDir.Name -StateRoot $stateRoot -Force -Confirm:$false
                if($result.Errors -gt 0){throw 'OWN_RUN_CLEANUP_FAILED'}
            }catch{$cleanupErrors.Add($_.Exception.Message)}
        }
    }
    if($module -and $volume -and $runtimeInvocation){
        try {
            $inspection=& $module {param($p,$v,$rid)Assert-LabContainerStoreRuntimeScope -Provider $p -RuntimeBinding ([pscustomobject]@{RuntimeScopeId=$rid});Get-LabContainerInstanceStoreRuntimeInspection -Provider $p -VolumeName $v} $Provider $volume $runtimeId
            if($inspection.Status -ceq 'MISSING') {
                & $module {param($p,$v)Get-LabContainerInstanceStoreRuntimeInspection -Provider $p -VolumeName $v -RequireMissingEvidence | Out-Null} $Provider $volume
            }
            else {
                if($inspection.Status -cne 'AVAILABLE' -or @($inspection.AttachedContainers).Count -gt 0 -or $inspection.Labels.'sql-server-lab.persistent-storage-id' -cne $storageId -or $inspection.Labels.'sql-server-lab.scope-id' -cne $ownedScope){throw 'OWN_VOLUME_CLEANUP_BINDING_INVALID'}
                & $runtimeInvocation volume rm $volume | Out-Null
                if($LASTEXITCODE -ne 0){throw 'OWN_VOLUME_CLEANUP_FAILED'}
            }
        }catch{$cleanupErrors.Add($_.Exception.Message)}
    }
    $plain=$null;$password=$null
    $env:SQL_SERVER_LAB_STATE=$previous.State;$env:SQL_SERVER_LAB_DATA_ROOT=$previous.Data;$env:SQL_SERVER_LAB_TEST_DATA_ROOT=$previous.TestData
    if($acquired){$mutex.ReleaseMutex()};$mutex.Dispose()
    if($cleanupErrors.Count -eq 0 -and (Test-Path -LiteralPath $testRoot)){
        $resolved=[IO.Path]::GetFullPath($testRoot);$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        if(-not $resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notlike 'sql-lab-recovery-acceptance-*'){throw 'OWN_TEST_ROOT_INVALID'}
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
    if($cleanupErrors.Count -gt 0){throw "RECOVERY_ACCEPTANCE_CLEANUP_REQUIRED: $($cleanupErrors -join '; ')"}
    Write-Host 'CLEANUP_SUCCEEDED: own runs and retained volume; errors=0'
}
if($completed){Write-Host "PERSISTENT_STORAGE_RECOVERY_ACCEPTANCE: PASS ($Provider)"}
