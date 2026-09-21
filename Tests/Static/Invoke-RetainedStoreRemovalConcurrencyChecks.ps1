#Requires -Version 7.2
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$repo=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$root=Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-retained-race-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $root
$module=Import-Module (Join-Path $repo 'SQLServerLab.psd1') -Force -PassThru
$worker=$null
$observer=$null
try {
    $childScript=Join-Path $root 'worker.ps1'
    @'
param($Repo,$Root,$Mode)
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $Repo 'SQLServerLab.psd1') -Force -PassThru
& $module {
    param($Root,$Mode)
    $script:race=Get-Content -LiteralPath (Join-Path $Root 'input.json') -Raw | ConvertFrom-Json -Depth 20
    if($Mode -ceq 'ABANDON'){
        Invoke-LabPersistentStorageCatalogLock -ControllerId $script:race.Configuration.ControllerId -ScriptBlock {
            [IO.File]::WriteAllText((Join-Path $Root 'abandoned-ready'),'READY')
            [Environment]::Exit(0)
        }
        throw 'UNREACHABLE'
    }
    function Test-LabDataRootOwnership {param($DataRoot,$ControllerId)$true}
    function Get-LabContainerInstanceStoreRuntimeInspection {
        param($Provider,$VolumeName)
        [IO.File]::WriteAllText((Join-Path $Root 'worker-ready'),'READY')
        $script:race.Runtime
    }
    $rejected=$false
    try {
        Register-LabContainerInstanceStoreLease -Provider docker -VolumeName $script:race.Runtime.VolumeName `
            -RunId $script:race.RunId -ScopeId $script:race.ScopeId -SqlVersion 2025 -DisplayName 'Concurrent synthetic consumer' `
            -DataRoot $script:race.Configuration.LabDataLocations[0].LabDataRoot -Configuration $script:race.Configuration | Out-Null
    }
    catch { $rejected=$_.Exception.Message -match 'CONTAINER_INSTANCE_STORE_LEASE_CONFLICT' }
    if(-not $rejected){throw 'CONCURRENT_CONSUMER_NOT_REJECTED'}
    [IO.File]::WriteAllText((Join-Path $Root 'consumer-rejected'),'REJECTED')
} $Root $Mode
'@ | Set-Content -LiteralPath $childScript
    function Start-RaceWorker {
        param([string]$Mode)
        $start=[Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
        $start.UseShellExecute=$false;$start.CreateNoWindow=$true
        $start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
        foreach($argument in @('-NoProfile','-NonInteractive','-File',$childScript,'-Repo',$repo,'-Root',$root,'-Mode',$Mode)){$start.ArgumentList.Add($argument)}
        [Diagnostics.Process]::Start($start)
    }
    $inputPath=Join-Path $root 'input.json'
    & $module {
        param($Root,$InputPath)
        $script:raceConfig=[pscustomobject]@{ControllerId=[guid]::NewGuid().ToString('D');LabDataLocations=@(
            [pscustomobject]@{LocationId=[guid]::NewGuid().ToString('D');LabDataRoot=(Join-Path $Root 'data')})}
        $null=Initialize-LabManagedDataRoot -DataRoot $script:raceConfig.LabDataLocations[0].LabDataRoot -ControllerId $script:raceConfig.ControllerId -Confirm:$false
        $id=[guid]::NewGuid().ToString('D');$run=[guid]::NewGuid().ToString('D');$scope=[guid]::NewGuid().ToString('D')
        $now=Get-LabTimestamp
        $store=[pscustomobject]@{
            PersistentStorageId=$id;DisplayName='Synthetic deletion reservation';StorageClass='INSTANCE_STORE';State='DELETE_PENDING';Provider='docker'
            LocationBinding=[pscustomobject]@{Residency='NATIVE_RUNTIME';LocationId=$null;ProviderResourceId='sql-lab-synthetic-race';InventoryObjectId=(Get-LabStorageResidencyObjectId -Key 'runtime-volume|docker|sql-lab-synthetic-race');RelativePath=$null}
            References=@();Lease=$null;Retention='RETAINED';CleanupDisposition='PRESERVE';CreatedAt=$now;UpdatedAt=$now
            Deletion=[pscustomobject]@{OperationId=[guid]::NewGuid().ToString('D');PlanKey=('a'*64);RuntimeScopeId=('runtime-scope-'+('1'*24));VolumeFingerprint=('b'*64);RecordFingerprint=('c'*64);RequestedAt=$now;RemovedAt=$null;AbsenceVerifiedAt=$null}
        }
        $document=[pscustomobject]@{ContractVersion='SqlServerLab.PersistentStorageCatalog/1.0';ControllerId=$script:raceConfig.ControllerId;Revision=1;Stores=@($store)}
        Write-LabPersistentStorageCatalogDocument -Document $document -Configuration $script:raceConfig | Out-Null
        $runtime=[pscustomobject]@{Status='AVAILABLE';VolumeName='sql-lab-synthetic-race';AttachedContainers=@();Labels=[pscustomobject]@{'sql-server-lab.persistent-storage-id'=$id;'sql-server-lab.sql-major-version'='2025'}}
        Write-LabArtifactJsonAtomic -Path $InputPath -InputObject ([pscustomobject]@{Configuration=$script:raceConfig;Runtime=$runtime;RunId=$run;ScopeId=$scope})
    } $root $inputPath
    $launcher=${function:Start-RaceWorker}.GetNewClosure()
    $worker=& $module {
        param($Root,$Launcher)
        Invoke-LabPersistentStorageCatalogLock -ControllerId $script:raceConfig.ControllerId -ScriptBlock {
            $worker=& $Launcher CONSUMER
            $deadline=[datetime]::UtcNow.AddSeconds(20)
            try {
                while(-not(Test-Path -LiteralPath (Join-Path $Root 'worker-ready'))){
                    if([datetime]::UtcNow -gt $deadline -or $worker.HasExited){throw 'RACE_WORKER_HANDSHAKE_FAILED'}
                    Start-Sleep -Milliseconds 50
                }
                if($worker.WaitForExit(300) -or (Test-Path -LiteralPath (Join-Path $Root 'consumer-rejected'))){throw 'CONSUMER_BYPASSED_CONTROLLER_MUTEX'}
                return $worker
            }
            catch {
                if(-not $worker.HasExited){$worker.Kill($true);$null=$worker.WaitForExit(5000)}
                $worker.Dispose();throw
            }
        }
    } $root $launcher
    $output=$worker.StandardOutput.ReadToEndAsync();$errors=$worker.StandardError.ReadToEndAsync()
    if(-not $worker.WaitForExit(20000)){throw 'CONSUMER_RACE_TIMEOUT'}
    if($worker.ExitCode -ne 0 -or -not(Test-Path -LiteralPath (Join-Path $root 'consumer-rejected'))){throw 'CONSUMER_RACE_FAILED'}
    Write-Host 'PASS: Ein echter zweiter Prozess wartet auf den Katalogmutex und lehnt DELETE_PENDING danach ab'
    $worker.Dispose();$worker=$null
    # Keep a handle alive so Windows reports the abandoned mutex instead of
    # silently creating a new kernel object after the child exits.
    $controller=(Get-Content -LiteralPath $inputPath -Raw | ConvertFrom-Json -Depth 20).Configuration.ControllerId
    $hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($controller.ToLowerInvariant()))).Substring(0,16)
    $mutexName=if($IsWindows){"Global\SQL_Server_Lab_Persistent_Storage_$hash"}else{"SQL_Server_Lab_Persistent_Storage_$hash"}
    $observer=[Threading.Mutex]::new($false,$mutexName)
    $worker=Start-RaceWorker ABANDON
    $output=$worker.StandardOutput.ReadToEndAsync();$errors=$worker.StandardError.ReadToEndAsync()
    if(-not $worker.WaitForExit(20000) -or $worker.ExitCode -ne 0 -or -not(Test-Path -LiteralPath (Join-Path $root 'abandoned-ready'))){throw 'ABANDON_WORKER_FAILED'}
    $value=& $module {Invoke-LabPersistentStorageCatalogLock -ControllerId $script:raceConfig.ControllerId -ScriptBlock {'RECOVERED'}}
    if($value -cne 'RECOVERED'){throw 'ABANDONED_CATALOG_MUTEX_NOT_RECOVERABLE'}
    Write-Host 'PASS: Ein nach Prozessabbruch verlassener Mutex bleibt für Recovery nutzbar'
    Write-Host 'Retained store concurrency checks passed: 2'
}
finally {
    if($worker){if(-not $worker.HasExited){$worker.Kill($true);if(-not $worker.WaitForExit(5000)){throw 'RACE_WORKER_TERMINATION_UNCONFIRMED'}};$worker.Dispose()}
    if($observer){$observer.Dispose()}
    Remove-Module $module -Force
    $resolved=[IO.Path]::GetFullPath($root);$parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if(-not $resolved.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notlike 'sql-lab-retained-race-*'){throw 'TEST_CLEANUP_SCOPE_INVALID'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
