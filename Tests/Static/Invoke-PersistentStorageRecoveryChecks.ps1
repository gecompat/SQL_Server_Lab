#Requires -Version 7.2
[CmdletBinding()]
param([switch]$CancellationChild)
$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-recovery-check-'+[guid]::NewGuid().ToString('N'))
$module=Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru
try {
    & $module {
        param($Root,$Repo,$Cancel)
        . (Join-Path $Repo 'Tests/Common/PersistentStorageRecoveryFixture.ps1')
        $script:recoveryChecks=0
        function Assert-Recovery { param([bool]$Success,[string]$Name) if(-not $Success){throw "RECOVERY_CHECK_FAILED: $Name"};$script:recoveryChecks++;Write-Host "PASS: $Name" }
        function Reset-RecoveryFixture {
            param([switch]$RunScoped)
            $script:fixture=New-TestPersistentStorageRecoveryFixture -Root (Join-Path $Root ([guid]::NewGuid().ToString('N'))) -RunScoped:$RunScoped
            $script:observedScope=$script:fixture.RuntimeScopeId; $script:sidecarPresent=$false; $script:ownsRoot=$true; $script:sidecarUnknown=$false
            $script:runtimeReads=0; $script:onRuntimeRead=$null
            $script:arguments=@{OriginalRunId=$script:fixture.Run.RunId;InstanceId='primary';ExpectedPersistentStorageId=$script:fixture.StorageId;
                ExpectedRuntimeScopeId=$script:fixture.RuntimeScopeId;DataRoot=$script:fixture.DataRoot;StateRoot=$script:fixture.Run.StateRoot}
        }
        function Get-RecoverySnapshot {
            @($script:fixture.Configuration.LabDataLocations | ForEach-Object {
                $path=Join-Path $_.LabDataRoot 'Catalog/persistent-stores.json'
                if(Test-Path -LiteralPath $path){(Get-FileHash -LiteralPath $path).Hash}else{'MISSING'}
            }) -join '|'
        }
        function Assert-RecoveryRejected {
            param([string]$Name,[scriptblock]$Action,[string]$Pattern='RECOVER|CONTAINER_STORE|CONTAINER_INSTANCE_STORE|REVISION_CONFLICT')
            $before=Get-RecoverySnapshot; $labels=$script:fixture.Runtime.Labels|ConvertTo-Json -Compress
            $caught=$null; try { & $Action | Out-Null } catch { $caught=$_.Exception.Message }
            Assert-Recovery ($caught -match $Pattern -and $before -ceq (Get-RecoverySnapshot) -and
                $labels -ceq ($script:fixture.Runtime.Labels|ConvertTo-Json -Compress)) "$Name (unveränderte Katalogbytes/Labels; Fehler=$caught)"
        }
        Set-Item Function:Resolve-LabDataRootForUse -Value {param($DataRoot)$DataRoot}
        Set-Item Function:Get-LabStorageConfiguration -Value {param($DataRoot)$script:fixture.Configuration}
        Set-Item Function:Test-LabDataRootOwnership -Value {param($DataRoot,$ControllerId)$script:ownsRoot}
        Set-Item Function:Get-LabContainerRuntimeScope -Value {param($Provider)[pscustomobject]@{Status='AVAILABLE';RuntimeId=$script:observedScope}}
        Set-Item Function:Get-LabContainerInstanceStoreRuntimeInspection -Value {
            param($Provider,$VolumeName,[switch]$RequireMissingEvidence)
            $script:runtimeReads++
            if($script:onRuntimeRead){ & $script:onRuntimeRead }
            if($VolumeName -cne $script:fixture.Runtime.VolumeName){
                if($script:sidecarUnknown){throw 'CONTAINER_INSTANCE_STORE_ABSENCE_UNVERIFIABLE'}
                return [pscustomobject]@{Status=if($script:sidecarPresent){'AVAILABLE'}else{'MISSING'};AttachedContainers=@()}
            }
            $script:fixture.Runtime | ConvertTo-Json -Depth 12 | ConvertFrom-Json -Depth 12
        }
        Reset-RecoveryFixture
        if($Cancel){
            $before=Get-RecoverySnapshot
            $result=Repair-SqlServerLabPersistentStorageCatalog @script:arguments -Confirm
            Assert-Recovery ($result.Status -ceq 'CANCELLED' -and $before -ceq (Get-RecoverySnapshot)) 'Öffentliche Ablehnung ohne Mutation'
            Write-Host 'RECOVERY_CANCEL_PASS'
            return
        }
        # Real producer-shaped desired state, including the UUID on data-root drives.
        $script:fixture.State.metadata.desiredState.Instances[0].Intents.Drives[0].Persistence='data-root-runtime-volume'
        $script:fixture.Connection.instances[0].persistentStorage.mode='data-root-runtime-volume'
        $script:fixture.Runtime.Labels.'sql-server-lab.persistence'='data-root-runtime-volume'
        Write-LabArtifactJsonAtomic -Path (Join-Path $script:fixture.Run.RunDir 'run-state.json') -InputObject $script:fixture.State
        Write-LabArtifactJsonAtomic -Path (Join-Path $script:fixture.Run.RunDir 'connection-info.json') -InputObject $script:fixture.Connection
        $valid=Get-LabPersistedDesiredState -RunId $script:fixture.Run.RunId -StateRoot $script:fixture.Run.StateRoot
        Assert-Recovery ($valid.Status -ceq 'VALID') 'Aktueller PersistentData-Produzent mit UUID bleibt gültig'
        $before=Get-RecoverySnapshot
        $preview=Repair-SqlServerLabPersistentStorageCatalog @script:arguments -WhatIf
        Assert-Recovery ($preview.Status -ceq 'PLANNED' -and $before -ceq (Get-RecoverySnapshot)) 'Öffentliches WhatIf schreibt keine Spiegel'
        $applied=Repair-SqlServerLabPersistentStorageCatalog @script:arguments -Confirm:$false
        $after=Get-RecoverySnapshot
        $repeat=Repair-SqlServerLabPersistentStorageCatalog @script:arguments -Confirm:$false
        $catalog=Get-LabPersistentStorageCatalog -Configuration $script:fixture.Configuration
        $store=$catalog.Document.Stores[0]
        Assert-Recovery ($applied.Status -ceq 'RECOVERED' -and $applied.CatalogRevision -eq 1 -and $repeat.Status -ceq 'NO_CHANGE' -and $after -ceq (Get-RecoverySnapshot) -and
            $store.RuntimeBinding.RuntimeScopeId -ceq $script:fixture.RuntimeScopeId -and $store.RuntimeBinding.RecoverySource.ScopeId -ceq $script:fixture.Run.ScopeId -and
            $store.PersistentStorageId -ceq $script:fixture.StorageId -and $store.State -ceq 'DETACHED' -and -not $store.Lease) 'Öffentlicher Commit und Wiederholung binden unabhängige Runtime- und Run-Identitäten'
        $plan=New-LabContainerInstanceStoreSelectionPlan -SourcePersistentStorageId $store.PersistentStorageId -Action CONTINUE -Provider docker -TargetRunId ([guid]::NewGuid().ToString('D')) -TargetScopeId ([guid]::NewGuid().ToString('D')) -TargetSqlVersion 2025 -Configuration $script:fixture.Configuration
        Assert-Recovery ($plan.Status -ceq 'READY' -and $plan.Source.RuntimeBinding.RuntimeScopeId -ceq $script:fixture.RuntimeScopeId) 'Wiederhergestellter Store liefert öffentlichen Continue-Fachplan'
        foreach($provider in @('docker','podman')) {
            $script:fixture.Runtime.Provider=$provider
            $command=if($provider -eq 'docker'){'Initialize-DockerSqlNamedVolume'}else{'Initialize-PodmanSqlNamedVolume'}
            $initialized=& $command -VolumeName $script:fixture.Runtime.VolumeName -Image synthetic:2025 -RunId $script:fixture.Run.RunId -ScopeId $script:fixture.Run.ScopeId -VersionId 2025 -InstanceId primary -ContainerPath /var/opt/mssql -PersistentStorageId $script:fixture.StorageId -RuntimeBinding $store.RuntimeBinding -SyncImageContent
            Assert-Recovery (-not $initialized) "$provider initialisiert oder erzeugt gebundenen bestehenden Store niemals erneut"
        }
        $script:fixture.Runtime.Provider='docker'
        $script:observedScope='runtime-scope-'+('2'*24)
        Assert-RecoveryRejected 'Runtimewechsel vor Continue-Lease' {
            Register-LabContainerInstanceStoreLease -Provider docker -VolumeName $script:fixture.Runtime.VolumeName -RunId ([guid]::NewGuid().ToString('D')) -ScopeId ([guid]::NewGuid().ToString('D')) -SqlVersion 2025 -DisplayName test -DataRoot $script:fixture.DataRoot -Configuration $script:fixture.Configuration
        } 'LEASE_RUNTIME_CONFLICT'
        foreach($provider in @('docker','podman')) {
            Assert-RecoveryRejected "Runtimewechsel vor $provider Initialisierung" {
                $command=if($provider -eq 'docker'){'Initialize-DockerSqlNamedVolume'}else{'Initialize-PodmanSqlNamedVolume'}
                & $command -VolumeName $script:fixture.Runtime.VolumeName -Image synthetic:2025 -RunId $script:fixture.Run.RunId -ScopeId $script:fixture.Run.ScopeId -VersionId 2025 -InstanceId primary -ContainerPath /var/opt/mssql -PersistentStorageId $script:fixture.StorageId -RuntimeBinding $store.RuntimeBinding
            } 'INITIALIZATION_BLOCKED'
        }
        $script:observedScope=$script:fixture.RuntimeScopeId
        $clonePlan=New-LabContainerInstanceStoreSelectionPlan -SourcePersistentStorageId $store.PersistentStorageId -Action CLONE -Provider docker -TargetRunId ([guid]::NewGuid().ToString('D')) -TargetScopeId ([guid]::NewGuid().ToString('D')) -TargetSqlVersion 2025 -Configuration $script:fixture.Configuration
        $script:observedScope='runtime-scope-'+('2'*24)
        Assert-RecoveryRejected 'Runtimewechsel vor Clone-Lease' {Set-LabContainerInstanceStoreCloneLease -Plan $clonePlan -Configuration $script:fixture.Configuration} 'RUNTIME_BINDING_CHANGED'
        Assert-RecoveryRejected 'Runtimewechsel vor Clone-Executor' {Invoke-LabContainerInstanceStoreClone -Plan $clonePlan -Configuration $script:fixture.Configuration -OperationDirectory (Join-Path $Root 'unstarted-clone')}
        Assert-Recovery (-not(Test-Path -LiteralPath (Join-Path $Root 'unstarted-clone'))) 'Blockierter Clone erzeugt kein Journal'
        $inventory=[pscustomobject]@{Objects=@([pscustomobject]@{ObjectId=$store.LocationBinding.InventoryObjectId;Provider='docker';LogicalName=$script:fixture.Runtime.VolumeName;RunIds=@();Lifecycle='RETAINED';AuditStatus='VERIFIED';Details=[pscustomobject]@{RuntimeScopeId=$script:observedScope}})}
        $residency=Get-LabPersistentStoragePlan -Catalog $catalog -ResidencyInventory $inventory
        Assert-Recovery ($residency.Stores[0].ObservationStatus -ceq 'MISSING') 'Residency meldet fremden Runtime-Kontext nicht als Match'
        $script:observedScope=$script:fixture.RuntimeScopeId
        $savedCatalog=(Get-LabPersistentStorageCatalog -Configuration $script:fixture.Configuration).Document
        $unbound=$savedCatalog | ConvertTo-Json -Depth 30 | ConvertFrom-Json -Depth 30
        $unbound.Stores[0].PSObject.Properties.Remove('RuntimeBinding')
        Write-LabPersistentStorageCatalogDocument -Configuration $script:fixture.Configuration -Document $unbound | Out-Null
        Assert-RecoveryRejected 'Entfernte Katalog-Runtimebindung invalidiert bestehenden Clone-Plan' {
            Set-LabContainerInstanceStoreCloneLease -Plan $clonePlan -Configuration $script:fixture.Configuration
        } 'RUNTIME_BINDING_CHANGED'
        Write-LabPersistentStorageCatalogDocument -Configuration $script:fixture.Configuration -Document $savedCatalog | Out-Null
        $script:runtimeReads=0
        $script:onRuntimeRead={if($script:runtimeReads -eq 2){$script:fixture.Runtime.AttachedContainers=@('concurrent-attachment')}}
        Assert-RecoveryRejected 'Continue revalidiert Attachment unter Katalog-Lock' {
            Register-LabContainerInstanceStoreLease -Provider docker -VolumeName $script:fixture.Runtime.VolumeName -RunId ([guid]::NewGuid().ToString('D')) -ScopeId ([guid]::NewGuid().ToString('D')) -SqlVersion 2025 -DisplayName test -DataRoot $script:fixture.DataRoot -Configuration $script:fixture.Configuration
        } 'LEASE_RUNTIME_CONFLICT'
        $script:onRuntimeRead=$null;$script:fixture.Runtime.AttachedContainers=@()
        $leaseRun=[guid]::NewGuid().ToString('D');$leaseScope=[guid]::NewGuid().ToString('D')
        $lease=Register-LabContainerInstanceStoreLease -Provider docker -VolumeName $script:fixture.Runtime.VolumeName -RunId $leaseRun -ScopeId $leaseScope -SqlVersion 2025 -DisplayName test -DataRoot $script:fixture.DataRoot -Configuration $script:fixture.Configuration
        Assert-Recovery ($lease.Store.State -ceq 'IN_USE') 'Gebundener Continue-Lease-Erwerb bleibt ausführbar'
        $script:observedScope='runtime-scope-'+('2'*24)
        $releaseError=$null
        try{Unregister-LabContainerInstanceStoreLease -Provider docker -VolumeName $script:fixture.Runtime.VolumeName -RunId $leaseRun -ScopeId $leaseScope -DataRoot $script:fixture.DataRoot -Configuration $script:fixture.Configuration|Out-Null}catch{$releaseError=$_.Exception.Message}
        $recoveryStore=(Get-LabPersistentStorageCatalog -Configuration $script:fixture.Configuration).Document.Stores[0]
        Assert-Recovery ($releaseError -match 'RELEASE_RUNTIME_VERIFICATION_FAILED' -and $recoveryStore.State -ceq 'RECOVERY_REQUIRED' -and $recoveryStore.Lease.RunId -ceq $leaseRun) 'Release bei Runtimewechsel bewahrt Lease und meldet Recovery'
        foreach($case in @('runscoped','legacy-idless','old-snapshot','foreign-root','unknown-root','active','cleanup','run-id','connection','instance-label','scope-label','storage-label','version-label','attached','sidecar-declared','sidecar-observed','sidecar-unknown','runtime')) {
            Reset-RecoveryFixture -RunScoped:($case -eq 'runscoped')
            switch($case) {
                old-snapshot {$script:fixture.State.metadata.desiredState.Instances[0].Intents.Drives=@()}
                foreign-root {$script:ownsRoot=$false}
                unknown-root {$script:fixture.State.metadata.dataRoot=Join-Path $Root 'unregistered'}
                sidecar-unknown {$script:sidecarUnknown=$true}
                legacy-idless {$script:fixture.State.metadata.desiredState.Instances[0].Intents.Drives[0].Persistence='data-root-runtime-volume';$script:fixture.State.metadata.desiredState.Instances[0].Intents.Drives[0].PersistentStorageId=$null}
                active {$script:fixture.State.state='RUNNING'}
                cleanup {$script:fixture.State.state='CLEANUP_RUNNING'}
                run-id {$script:fixture.State.runId=[guid]::NewGuid().ToString('D')}
                connection {$script:fixture.Connection.scopeId=[guid]::NewGuid().ToString('D')}
                instance-label {$script:fixture.Runtime.Labels.'sql-server-lab.instance-id'='other'}
                scope-label {$script:fixture.Runtime.Labels.'sql-server-lab.scope-id'=[guid]::NewGuid().ToString('D')}
                storage-label {$script:fixture.Runtime.Labels.'sql-server-lab.persistent-storage-id'=[guid]::NewGuid().ToString('D')}
                version-label {$script:fixture.Runtime.Labels.'sql-server-lab.sql-major-version'='2022'}
                attached {$script:fixture.Runtime.AttachedContainers=@('container')}
                sidecar-declared {$script:fixture.Connection.instances[0].externalRuntime=@([pscustomobject]@{language='python'})}
                sidecar-observed {$script:sidecarPresent=$true}
                runtime {$script:observedScope='runtime-scope-'+('2'*24)}
            }
            Write-LabArtifactJsonAtomic -Path (Join-Path $script:fixture.Run.RunDir 'run-state.json') -InputObject $script:fixture.State
            Write-LabArtifactJsonAtomic -Path (Join-Path $script:fixture.Run.RunDir 'connection-info.json') -InputObject $script:fixture.Connection
            if($case -eq 'legacy-idless') { Assert-Recovery ((Get-LabPersistedDesiredState -RunId $script:fixture.Run.RunId -StateRoot $script:fixture.Run.StateRoot).Status -ceq 'VALID') 'UUID-lose Legacy-Gruppe bleibt lesbar' }
            Assert-RecoveryRejected $case {Repair-SqlServerLabPersistentStorageCatalog @script:arguments -Confirm:$false}
        }
        foreach($case in @('different-id','active-lease','source-drift','revision','rollback')) {
            Reset-RecoveryFixture
            $source=Get-LabContainerStoreRecoverySource -OriginalRunId $script:fixture.Run.RunId -InstanceId primary -PersistentStorageId $script:fixture.StorageId -StateRoot $script:fixture.Run.StateRoot -Configuration $script:fixture.Configuration
            $core=@{Source=$source;StateRoot=$script:fixture.Run.StateRoot;RuntimeScopeId=$script:fixture.RuntimeScopeId;Configuration=$script:fixture.Configuration}
            $planned=Repair-LabContainerStoreCatalog @core -Preview
            if($case -in @('different-id','active-lease')) {
                $conflict=$planned.Store
                if($case -eq 'different-id'){$conflict.PersistentStorageId=[guid]::NewGuid().ToString('D')}
                else {$conflict.State='IN_USE';$conflict.References[0].State='ACTIVE';$conflict.Lease=[pscustomobject]@{LeaseId=[guid]::NewGuid().ToString('D');RunId=$script:fixture.Run.RunId;ScopeId=$script:fixture.Run.ScopeId;Mode='EXCLUSIVE';AcquiredAt=Get-LabTimestamp;ExpiresAt=$null}}
                Write-LabPersistentStorageCatalogDocument -Configuration $script:fixture.Configuration -Document ([pscustomobject]@{ContractVersion='SqlServerLab.PersistentStorageCatalog/1.0';ControllerId=$script:fixture.Configuration.ControllerId;Revision=1;Stores=@($conflict)}) | Out-Null
                Assert-RecoveryRejected $case {Repair-SqlServerLabPersistentStorageCatalog @script:arguments -Confirm:$false}
            }
            elseif($case -eq 'source-drift') {
                $script:fixture.State | Add-Member -NotePropertyName unrelated -NotePropertyValue 'changed'
                Write-LabArtifactJsonAtomic -Path (Join-Path $script:fixture.Run.RunDir 'run-state.json') -InputObject $script:fixture.State
                Assert-RecoveryRejected $case {Repair-LabContainerStoreCatalog @core -ExpectedRevision 0} 'SOURCE_CHANGED'
            }
            elseif($case -eq 'revision') { Assert-RecoveryRejected $case {Repair-LabContainerStoreCatalog @core -ExpectedRevision 7} }
            else {
                $script:realAtomic=${function:Write-LabArtifactJsonAtomic};$script:atomicCount=0
                Set-Item Function:Write-LabArtifactJsonAtomic -Value {param($Path,$InputObject)$script:atomicCount++;if($script:atomicCount -eq 2){throw 'SYNTHETIC_MIRROR_FAILURE'};& $script:realAtomic -Path $Path -InputObject $InputObject}
                try {Assert-RecoveryRejected $case {Repair-LabContainerStoreCatalog @core -ExpectedRevision 0} 'CATALOG_WRITE_FAILED'}
                finally {Set-Item Function:Write-LabArtifactJsonAtomic -Value $script:realAtomic}
            }
        }
        Reset-RecoveryFixture
        $script:realRepair=${function:Repair-LabContainerStoreCatalog}
        Set-Item Function:Repair-LabContainerStoreCatalog -Value {
            param($Source,$StateRoot,$RuntimeScopeId,$Configuration,[int]$ExpectedRevision=-1,[switch]$Preview)
            $result=& $script:realRepair -Source $Source -StateRoot $StateRoot -RuntimeScopeId $RuntimeScopeId -Configuration $Configuration -ExpectedRevision $ExpectedRevision -Preview:$Preview
            if($Preview){
                $script:fixture.Connection.instances[0].containerId='b'*64
                Write-LabArtifactJsonAtomic -Path (Join-Path $script:fixture.Run.RunDir 'connection-info.json') -InputObject $script:fixture.Connection
            }
            $result
        }
        try {Assert-RecoveryRejected 'Öffentlicher Apply revalidiert Connection nach Preview' {Repair-SqlServerLabPersistentStorageCatalog @script:arguments -Confirm:$false} 'SOURCE_CHANGED'}
        finally {Set-Item Function:Repair-LabContainerStoreCatalog -Value $script:realRepair}
        Reset-RecoveryFixture
        $script:onRuntimeRead={
            if($script:runtimeReads -eq 4){
                $script:fixture.State.state='CLEANUP_RUNNING'
                Write-LabArtifactJsonAtomic -Path (Join-Path $script:fixture.Run.RunDir 'run-state.json') -InputObject $script:fixture.State
            }
        }
        Assert-RecoveryRejected 'Lifecyclewechsel während Commit-Vorbereitung' {Repair-SqlServerLabPersistentStorageCatalog @script:arguments -Confirm:$false} 'RUN_STATE_INVALID'
        Write-Host "PERSISTENT_STORAGE_RECOVERY_CHECKS: PASS ($script:recoveryChecks)"
    } $testRoot $repoRoot $CancellationChild
    if(-not $CancellationChild){
        $start=[Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
        foreach($arg in @('-NoProfile','-File',$PSCommandPath,'-CancellationChild')){$start.ArgumentList.Add($arg)}
        $start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardInput=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
        $child=[Diagnostics.Process]::Start($start)
        try {
            $output=$child.StandardOutput.ReadToEndAsync();$errors=$child.StandardError.ReadToEndAsync()
            $child.StandardInput.WriteLine('n');$child.StandardInput.Close()
            if(-not $child.WaitForExit(30000)){throw 'RECOVERY_CANCELLATION_CHILD_TIMEOUT'}
            $out=$output.GetAwaiter().GetResult();$err=$errors.GetAwaiter().GetResult()
            if($child.ExitCode -ne 0 -or $out -notmatch 'RECOVERY_CANCEL_PASS'){throw "RECOVERY_CANCELLATION_FAILED: $err $out"}
            Write-Host "CANCELLATION_CHILD_EXITCODE: $($child.ExitCode)"
        } finally {if(-not $child.HasExited){$child.Kill();$child.WaitForExit()};$child.Dispose()}
    }
} finally {
    Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
    if(Test-Path -LiteralPath $testRoot){
        $resolved=[IO.Path]::GetFullPath($testRoot);$parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        if(-not $resolved.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notlike 'sql-lab-recovery-check-*'){throw 'TEST_CLEANUP_SCOPE_INVALID'}
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
