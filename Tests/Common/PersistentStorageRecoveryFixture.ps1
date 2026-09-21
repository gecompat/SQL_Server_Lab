function New-TestPersistentStorageRecoveryFixture {
    param([string]$Root, [string]$Provider='docker', [switch]$RunScoped)
    $storageId=[guid]::NewGuid().ToString('D')
    $configuration=[pscustomobject]@{ControllerId=[guid]::NewGuid().ToString('D');LabDataLocations=@(
        [pscustomobject]@{LocationId=[guid]::NewGuid().ToString('D');LabDataRoot=(Join-Path $Root 'data-one')},
        [pscustomobject]@{LocationId=[guid]::NewGuid().ToString('D');LabDataRoot=(Join-Path $Root 'data-two')})}
    foreach($location in $configuration.LabDataLocations){New-Item -ItemType Directory -Path (Join-Path $location.LabDataRoot 'Catalog') -Force | Out-Null}
    $persistence=if($RunScoped){'run-scoped-runtime-volume'}else{'cataloged-runtime-volume'}
    $driveId=if($RunScoped){'runtime-mssql'}else{'persistent-mssql'}
    $volume=if($RunScoped){'sql-lab-recovery-fixture-runtime-mssql'}else{'sql-lab-persistent-recovery-fixture'}
    $instance=[pscustomobject]@{id='primary';provider=$Provider;version='2025';profile='standard';autostart='manual';databases=@();software=@();
        drives=@([pscustomobject]@{id=$driveId;containerPath='/var/opt/mssql';volumeName=$volume;persistence=$persistence;persistentStorageId=$storageId})}
    $resolved=[pscustomobject]@{name='Recovery fixture';instances=@($instance)}
    $finalDrives=$instance.drives
    if(-not $RunScoped){$instance.drives=@()}
    $snapshot=New-LabDesiredStateSnapshot -ResolvedLab $resolved -ProvisioningMode adhoc -PersistentData (-not $RunScoped)
    $run=New-LabRunState -StateRoot (Join-Path $Root 'state') -Metadata @{desiredState=$snapshot;persistentData=(-not $RunScoped);dataRoot=$configuration.LabDataLocations[0].LabDataRoot}
    if(-not $RunScoped){
        $instance.drives=$finalDrives
        Update-LabPersistentContainerDesiredState -ResolvedLab $resolved -RunId $run.RunId -ScopeId $run.ScopeId -StateRoot $run.StateRoot -ProvisioningMode adhoc
    }
    $state=Get-LabRunState -RunId $run.RunId -StateRoot $run.StateRoot
    $state.state='REMOVED'
    Write-LabArtifactJsonAtomic -Path (Join-Path $run.RunDir 'run-state.json') -InputObject $state
    $connection=[pscustomobject]@{runId=$run.RunId;scopeId=$run.ScopeId;instances=@([pscustomobject]@{
        id='primary';provider=$Provider;version='2025';containerId=('a'*64);containerName='recovery-fixture';externalRuntime=@();
        persistentStorage=[pscustomobject]@{mode=$persistence;persistentStorageId=$storageId;containerVolume=$volume}})}
    Write-LabArtifactJsonAtomic -Path (Join-Path $run.RunDir 'connection-info.json') -InputObject $connection
    $runtime=[pscustomobject]@{Status='AVAILABLE';Provider=$Provider;VolumeName=$volume;VolumeId=$volume;AttachedContainers=@();Labels=[pscustomobject]@{
        'sql-server-lab.persistent-storage-id'=$storageId;'sql-server-lab.run-id'=$run.RunId;'sql-server-lab.scope-id'=$run.ScopeId;
        'sql-server-lab.instance-id'='primary';'sql-server-lab.sql-major-version'='2025';'sql-server-lab.persistence'=$persistence}}
    [pscustomobject]@{Run=$run;State=$state;Connection=$connection;Configuration=$configuration;Runtime=$runtime;StorageId=$storageId;
        RuntimeScopeId=('runtime-scope-'+('1'*24));DataRoot=$configuration.LabDataLocations[0].LabDataRoot}
}
