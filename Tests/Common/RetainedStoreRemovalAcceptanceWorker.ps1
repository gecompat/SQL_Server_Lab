# Invoked only by the bounded acceptance supervisor with its fresh private root.
[CmdletBinding()]
param([Parameter(Mandatory)][string]$EvidenceRoot,[Parameter(Mandatory)][guid]$OperationId,
    [Parameter(Mandatory)][ValidateSet('EXERCISE','CLEANUP')][string]$Stage)
$ErrorActionPreference='Stop'
$repo=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$root=[IO.Path]::GetFullPath($EvidenceRoot)
$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
if(-not $root.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -or
    [IO.Path]::GetFileName($root) -notlike 'sql-lab-retained-acceptance-*' -or
    ((Get-Item -LiteralPath $root).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'ACCEPTANCE_ROOT_INVALID'}
$inputObject=Get-Content -LiteralPath (Join-Path $root 'operation.json') -Raw | ConvertFrom-Json -Depth 10
if($inputObject.OperationId -cne $OperationId.ToString('D') -or $inputObject.Provider -cnotin @('docker','podman') -or
    $inputObject.RuntimeScopeId -cnotmatch '^runtime-scope-[a-f0-9]{24}$'){throw 'ACCEPTANCE_OPERATION_INVALID'}
$state=Join-Path $root 'state';$data=Join-Path $root 'Lab_Data'
$env:SQL_SERVER_LAB_STATE=$state;$env:SQL_SERVER_LAB_DATA_ROOT=$data
$env:SQL_SERVER_LAB_TEST_DATA_ROOT=Join-Path $root 'test-data'
$env:SQL_SERVER_LAB_CONTROLLER_ID=[string]$inputObject.ControllerId
$module=Import-Module (Join-Path $repo 'SQLServerLab.psd1') -Force -PassThru
$receipt=[ordered]@{OperationId=$OperationId.ToString('D');Stage=$Stage;Status='FAILED';Assertions=0}
try {
    $count=& $module {
        param($InputObject,$Root,$State,$Data,$Stage,$Repo)
        . (Join-Path $Repo 'Tests/Common/RetainedStoreRemovalAcceptanceCleanup.ps1')
        $provider=[string]$InputObject.Provider;$operation=[string]$InputObject.OperationId
        function Assert-Acceptance {param([bool]$Condition,[string]$Code)if(-not $Condition){throw $Code}}
        function Get-OwnContext {
            $context=Get-LabRetainedStoreRuntimeContext -Provider $provider
            Assert-Acceptance ($context.RuntimeScopeId -ceq $InputObject.RuntimeScopeId) 'ACCEPTANCE_RUNTIME_SCOPE_CHANGED'
            return $context
        }
        function Get-OwnRun {
            $runs=@(Get-ChildItem -LiteralPath (Join-Path $State 'runs') -Directory -ErrorAction SilentlyContinue |
                ForEach-Object {Get-LabRunState -RunId $_.Name -StateRoot $State})
            Assert-Acceptance ($runs.Count -le 1) 'ACCEPTANCE_RUN_AMBIGUOUS'
            foreach($run in $runs){
                Assert-Acceptance ($run.metadata.workflowOperationId -ceq $operation) 'ACCEPTANCE_OPERATION_MISMATCH'
                $instances=@($run.metadata.desiredState.Instances)
                Assert-Acceptance ($instances.Count -eq 1 -and $instances[0].Provider -ceq $provider) 'ACCEPTANCE_PROVIDER_MISMATCH'
                return $run
            }
        }
        function Assert-OwnResources {
            param($Run,$Context)
            foreach($kind in @('ps','volume')){
                $arguments=if($kind -ceq 'ps'){@('ps','-a','-q','--no-trunc')}else{@('volume','ls','-q')}
                $arguments+=@('--filter',"label=sql-server-lab.run-id=$($Run.runId)")
                $found=Invoke-LabRetainedStoreNative -Provider $provider -Arguments (@($Context.Arguments)+$arguments)
                Assert-Acceptance ($found.ExitCode -eq 0) 'ACCEPTANCE_RESOURCE_INVENTORY_FAILED'
                foreach($id in @($found.Output | Where-Object {$_})){
                    $inspectArgs=if($kind -ceq 'ps'){@('inspect',$id)}else{@('volume','inspect',$id)}
                    $raw=Invoke-LabRetainedStoreNative -Provider $provider -Arguments (@($Context.Arguments)+$inspectArgs)
                    Assert-Acceptance ($raw.ExitCode -eq 0) 'ACCEPTANCE_RESOURCE_INSPECT_FAILED'
                    $objects=@(($raw.Output -join "`n")|ConvertFrom-Json -Depth 30)
                    Assert-Acceptance ($objects.Count -eq 1) 'ACCEPTANCE_RESOURCE_AMBIGUOUS'
                    $labels=if($kind -ceq 'ps'){$objects[0].Config.Labels}else{$objects[0].Labels}
                    Assert-Acceptance ($labels.'sql-server-lab.run-id' -ceq $Run.runId -and
                        $labels.'sql-server-lab.scope-id' -ceq $Run.scopeId -and
                        $labels.'sql-server-lab.instance-id' -ceq 'primary') 'ACCEPTANCE_RESOURCE_OWNERSHIP_CHANGED'
                }
            }
        }
        function Remove-OwnStore {
            param($Run)
            $configuration=Get-LabStorageConfiguration -DataRoot $Data
            $catalog=Get-LabPersistentStorageCatalog -Configuration $configuration
            Assert-Acceptance ($catalog.Status -cin @('EMPTY','AVAILABLE')) 'ACCEPTANCE_CATALOG_UNVERIFIABLE'
            $stores=@($catalog.Document.Stores)
            Assert-Acceptance ($stores.Count -le 1) 'ACCEPTANCE_STORE_AMBIGUOUS'
            if($stores.Count){
                $store=$stores[0]
                Assert-Acceptance ($store.Provider -ceq $provider -and
                    @($store.References|Where-Object { $_.Kind -ceq 'RUN' -and $_.TargetId -ceq $Run.runId }).Count -eq 1) 'ACCEPTANCE_STORE_OWNERSHIP_CHANGED'
                $parameters=@{PersistentStorageId=$store.PersistentStorageId;DataRoot=$Data;StateRoot=$State;Confirm=$false}
                if($store.Deletion){$parameters.OperationId=$store.Deletion.OperationId}
                else {
                    try {$plan=Get-SqlServerLabRetainedStoreRemovalPlan -PersistentStorageId $store.PersistentStorageId -DataRoot $Data -StateRoot $State}
                    catch {
                        if($Stage -cne 'CLEANUP'){throw}
                        $ownContext=Get-OwnContext
                        foreach($extra in @(Get-LabContainerInstanceStoreSidecarDefinitions -BaseVolumeName $store.LocationBinding.ProviderResourceId)){
                            Assert-Acceptance ((Get-LabRetainedStoreVolume -Context $ownContext -VolumeName $extra.VolumeName).Status -ceq 'MISSING') 'ACCEPTANCE_PARTIAL_SIDECAR_UNSUPPORTED'
                        }
                        $volume=Get-LabRetainedStoreVolume -Context $ownContext -VolumeName $store.LocationBinding.ProviderResourceId
                        Assert-RetainedAcceptancePartialStore -InputObject $InputObject -Run $Run -Store $store -Volume $volume
                        if($volume.Status -ceq 'AVAILABLE'){
                            Remove-LabRetainedStoreVolume -Context $ownContext -VolumeName $volume.VolumeName
                        }
                        Assert-Acceptance ((Get-LabRetainedStoreVolume -Context (Get-OwnContext) -VolumeName $store.LocationBinding.ProviderResourceId).Status -ceq 'MISSING') 'ACCEPTANCE_PARTIAL_STORE_REMAINS'
                        return
                    }
                    $parameters.ExpectedCatalogRevision=$plan.CatalogRevision;$parameters.ExpectedPlanKey=$plan.PlanKey
                }
                $removed=Invoke-SqlServerLabRetainedStoreRemoval @parameters
                Assert-Acceptance ($removed.Status -ceq 'REMOVED') 'ACCEPTANCE_STORE_CLEANUP_REQUIRED'
            }
        }
        $context=Get-OwnContext
        if($Stage -ceq 'CLEANUP'){
            $run=Get-OwnRun
            if($run){
                Assert-OwnResources -Run $run -Context $context
                if($run.state -cnotin @('REMOVED','CLEANED_UP')){
                    $removed=Remove-SqlServerLab -RunId $run.runId -StateRoot $State -Force -Confirm:$false
                    Assert-Acceptance ($removed.Errors -eq 0 -and $removed.Cleanup -ceq 'CLEANUP_SUCCEEDED') 'ACCEPTANCE_RUN_CLEANUP_FAILED'
                    $run=Get-OwnRun
                }
                $null=Get-OwnContext
                Remove-OwnStore -Run $run
                foreach($arguments in @(
                    @('ps','-a','-q','--filter',"label=sql-server-lab.run-id=$($run.runId)"),
                    @('volume','ls','-q','--filter',"label=sql-server-lab.run-id=$($run.runId)")
                )){
                    $remaining=Invoke-LabRetainedStoreNative -Provider $provider -Arguments (@($context.Arguments)+$arguments)
                    Assert-Acceptance ($remaining.ExitCode -eq 0 -and @($remaining.Output|Where-Object {$_}).Count -eq 0) 'ACCEPTANCE_RESOURCES_REMAIN'
                }
            }
            return 1
        }
        Initialize-LabManagedDataRoot -DataRoot $Data -ControllerId $InputObject.ControllerId -Confirm:$false | Out-Null
        $lab=Invoke-WithLabWorkflowOperationContext -OperationId $operation -ScriptBlock {
            param($Provider,$State,$Data)
            New-SqlServerLab -Version 2025 -Provider $Provider -Profile compact -Cpu 1 -MemoryMB 2560 -Port 0 `
                -LabName 'retained-removal-acceptance' -StateRoot $State -DataRoot $Data -PersistentData `
                -GenerateSaPassword -NonInteractive -SkipAssessment
        } -ArgumentList @($provider,$State,$Data)
        Assert-Acceptance ($lab.State -ceq 'Running') 'ACCEPTANCE_ARRANGE_FAILED'
        $run=Get-OwnRun;$context=Get-OwnContext
        Assert-OwnResources -Run $run -Context $context
        $binding=Get-LabTransferBinding -RunId $run.runId -InstanceId primary -StateRoot $State
        Assert-Acceptance ($binding.RuntimeScopeId -ceq $InputObject.RuntimeScopeId -and $binding.Provider -ceq $provider) 'ACCEPTANCE_SQL_BINDING_CHANGED'
        $secret=Get-LabRelationalCoreSecret -RunId $run.runId -StateRoot $State
        $connection=$null;$command=$null
        try {
            $connection=New-LabRelationalCoreConnection -Binding $binding -DatabaseName master -Secret $secret
            $connection.Open();$command=$connection.CreateCommand();$command.CommandTimeout=45
            $command.CommandText="IF CONVERT(int,SERVERPROPERTY('ProductMajorVersion'))<>17 THROW 51000,'VERSION',1; CREATE DATABASE RetainedRemovalProbe;"
            $null=$command.ExecuteNonQuery()
            $command.CommandText="CREATE TABLE RetainedRemovalProbe.dbo.Marker(Id int NOT NULL PRIMARY KEY); INSERT RetainedRemovalProbe.dbo.Marker VALUES(1); SELECT COUNT(*) FROM RetainedRemovalProbe.dbo.Marker;"
            Assert-Acceptance ([int]$command.ExecuteScalar() -eq 1) 'ACCEPTANCE_SQL_MARKER_FAILED'
        }
        finally {if($command){$command.Dispose()};if($connection){$connection.Dispose()};if($secret){$secret.Dispose()}}
        $configuration=Get-LabStorageConfiguration -DataRoot $Data
        $store=(Get-LabPersistentStorageCatalog -Configuration $configuration).Document.Stores[0]
        $labels=(Get-LabRetainedStoreVolume -Context $context -VolumeName $store.LocationBinding.ProviderResourceId).Labels|ConvertTo-Json -Compress
        $removed=Remove-SqlServerLab -RunId $run.runId -StateRoot $State -Force -Confirm:$false
        Assert-Acceptance ($removed.Errors -eq 0 -and $removed.Cleanup -ceq 'CLEANUP_SUCCEEDED') 'ACCEPTANCE_DETACH_FAILED'
        $plan=Get-SqlServerLabRetainedStoreRemovalPlan -PersistentStorageId $store.PersistentStorageId -DataRoot $Data -StateRoot $State
        $parameters=@{PersistentStorageId=$store.PersistentStorageId;DataRoot=$Data;StateRoot=$State;ExpectedCatalogRevision=$plan.CatalogRevision;ExpectedPlanKey=$plan.PlanKey}
        $before=(Get-FileHash -LiteralPath (Join-Path $Data 'Catalog/persistent-stores.json')).Hash
        $preview=Invoke-SqlServerLabRetainedStoreRemoval @parameters -WhatIf
        $afterLabels=(Get-LabRetainedStoreVolume -Context $context -VolumeName $store.LocationBinding.ProviderResourceId).Labels|ConvertTo-Json -Compress
        Assert-Acceptance ($preview.Status -ceq 'PLANNED' -and $before -ceq (Get-FileHash -LiteralPath (Join-Path $Data 'Catalog/persistent-stores.json')).Hash -and $labels -ceq $afterLabels) 'ACCEPTANCE_WHATIF_CHANGED_STATE'
        $result=Invoke-SqlServerLabRetainedStoreRemoval @parameters -Confirm:$false
        Assert-Acceptance ($result.Status -ceq 'REMOVED') 'ACCEPTANCE_REMOVAL_FAILED'
        $before=(Get-FileHash -LiteralPath (Join-Path $Data 'Catalog/persistent-stores.json')).Hash
        $repeat=Invoke-SqlServerLabRetainedStoreRemoval -PersistentStorageId $store.PersistentStorageId -DataRoot $Data -StateRoot $State -OperationId $result.OperationId -Confirm:$false
        $terminal=(Get-LabPersistentStorageCatalog -Configuration $configuration).Document.Stores[0]
        Assert-Acceptance ($repeat.Status -ceq 'REMOVED' -and $terminal.State -ceq 'REMOVED' -and
            $terminal.PersistentStorageId -ceq $store.PersistentStorageId -and $before -ceq (Get-FileHash -LiteralPath (Join-Path $Data 'Catalog/persistent-stores.json')).Hash) 'ACCEPTANCE_TOMBSTONE_INVALID'
        Assert-Acceptance ((Get-LabRetainedStoreVolume -Context (Get-OwnContext) -VolumeName $store.LocationBinding.ProviderResourceId).Status -ceq 'MISSING') 'ACCEPTANCE_VOLUME_REMAINS'
        return 6
    } $inputObject $root $state $data $Stage $repo
    $receipt.Status='COMPLETED';$receipt.Assertions=[int]$count
}
catch {
    $_ | Out-String | Set-Content -LiteralPath (Join-Path $root ($Stage+'.private-error.log'))
}
finally {
    Remove-Module $module -Force
    $path=Join-Path $root ($Stage+'.receipt.json');$temporary=$path+'.tmp'
    [IO.File]::WriteAllText($temporary,($receipt|ConvertTo-Json -Compress));[IO.File]::Move($temporary,$path,$true)
}
if($receipt.Status -cne 'COMPLETED'){exit 1}
