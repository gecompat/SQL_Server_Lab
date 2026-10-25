# Test-only finalizer for a fresh, protected CI policy root. Never scans sibling
# roots, adopts resources by name, or removes a shared developer runtime.
function Invoke-OwnedHostTestCleanup {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StateRoot,[Parameter(Mandatory)]$Module)
    & $Module {
        param($Root)
        $policy=Get-LabOwnedHostPolicy -StateRoot $Root -Required
        $runRoot=Join-Path $policy.StateRoot 'runs'
        $directories=if(Test-Path -LiteralPath $runRoot){@(Get-ChildItem -LiteralPath $runRoot -Directory -Force -ErrorAction Stop)}else{@()}
        if($directories.Count -gt 256){throw 'OWNED_TEST_CLEANUP_RUN_LIMIT'}
        # Validate the complete selection before any mutation. Even a failed New
        # that never returned its RunId remains discoverable in this own root.
        $runs=@(foreach($directory in $directories){
            $null=Assert-LabOwnedHostPath $directory.FullName
            if($directory.Name -cnotmatch '^[a-f0-9-]{36}$'){throw 'OWNED_TEST_CLEANUP_RUN_ID'}
            $run=Get-LabRunState -RunId $directory.Name -StateRoot $Root
            $binding=Get-LabOwnedHostRunPolicy -RunId $directory.Name -StateRoot $Root
            if($binding.PolicyId -cne $policy.PolicyId -or $run.runId -cne $directory.Name){throw 'OWNED_TEST_CLEANUP_POLICY_DRIFT'}
            $run
        })
        $failed=0
        foreach($run in $runs){
            try{
                $removed=Remove-SqlServerLab -RunId $run.runId -StateRoot $Root -Force -Confirm:$false
                if($removed.Status -cne 'REMOVED'){throw 'OWNED_TEST_CLEANUP_RUN_REMAINS'}
                foreach($pin in $policy.RuntimePins){
                    Remove-LabOwnedHostAutoStartIfUnused -StateRoot $Root -RunId $run.runId -Provider $pin.Provider
                }
                if($run.metadata.persistentData){
                    $data=Assert-LabOwnedHostPath ([string]$run.metadata.dataRoot)
                    $relative=[IO.Path]::GetRelativePath($policy.StateRoot,$data)
                    if([IO.Path]::IsPathRooted($relative) -or $relative -ceq '..' -or $relative.StartsWith('..'+[IO.Path]::DirectorySeparatorChar) -or $relative -ceq '.'){
                        throw 'OWNED_TEST_CLEANUP_DATA_OUTSIDE_POLICY'
                    }
                    $configuration=Get-LabStorageConfiguration -DataRoot $data
                    $ids=@($run.metadata.desiredState.Instances|ForEach-Object {$_.Intents.Drives}|Where-Object {$_.Persistence -ceq 'data-root-runtime-volume'}|ForEach-Object PersistentStorageId|Sort-Object -Unique)
                    if(-not $ids.Count){throw 'OWNED_TEST_CLEANUP_STORE_BINDING_MISSING'}
                    foreach($id in $ids){
                        $catalog=Get-LabPersistentStorageCatalog -Configuration $configuration
                        $store=@($catalog.Document.Stores|Where-Object PersistentStorageId -CEQ $id)
                        if($catalog.Status -cne 'AVAILABLE' -or $store.Count -ne 1){throw 'OWNED_TEST_CLEANUP_STORE_UNRESOLVED'}
                        if($store[0].State -ceq 'REMOVED'){continue}
                        $plan=Get-SqlServerLabRetainedStoreRemovalPlan -PersistentStorageId ([guid]$id) -DataRoot $data -StateRoot $Root
                        if($plan.Status -cne 'READY'){throw 'OWNED_TEST_CLEANUP_STORE_BLOCKED'}
                        $result=Invoke-SqlServerLabRetainedStoreRemoval -PersistentStorageId ([guid]$id) -DataRoot $data -StateRoot $Root -ExpectedCatalogRevision $plan.CatalogRevision -ExpectedPlanKey $plan.PlanKey -Confirm:$false
                        if($result.Status -cne 'REMOVED'){throw 'OWNED_TEST_CLEANUP_STORE_REMAINS'}
                    }
                }
                foreach($pin in $policy.RuntimePins){
                    foreach($kind in @('container','volume')){
                        $arguments=if($kind -ceq 'container'){@('ps','-a','--filter',('label=sql-server-lab.run-id='+$run.runId),'--format','{{.ID}}')}else{@('volume','ls','--filter',('label=sql-server-lab.run-id='+$run.runId),'--format','{{.Name}}')}
                        $observation=Invoke-LabOwnedHostPinnedCommand -StateRoot $Root -Provider $pin.Provider -Arguments $arguments
                        if($observation.ExitCode -ne 0 -or $observation.Stdout.Trim()){throw 'OWNED_TEST_CLEANUP_NATIVE_RESIDUE'}
                    }
                }
            }catch{
                $failed++
                # Actual diagnostics stay in the protected policy root.
                $_|Out-String|Add-Content -LiteralPath (Join-Path $Root 'test-cleanup.private.log')
            }
        }
        if($failed){throw 'OWNED_TEST_CLEANUP_RECOVERY_REQUIRED'}
        # A failure before the first returned run must not hide an orphan or
        # authorize payload deletion without a fresh policy-wide observation.
        foreach($pin in $policy.RuntimePins){
            foreach($kind in @('container','volume')){
                $arguments=if($kind -ceq 'container'){@('ps','-a','--filter',('label=sql-server-lab.owned-host-policy-id='+$policy.PolicyId),'--format','{{.ID}}')}else{@('volume','ls','--filter',('label=sql-server-lab.owned-host-policy-id='+$policy.PolicyId),'--format','{{.Name}}')}
                $observation=Invoke-LabOwnedHostPinnedCommand -StateRoot $Root -Provider $pin.Provider -Arguments $arguments
                if($observation.ExitCode -ne 0 -or $observation.Stdout.Trim()){throw 'OWNED_TEST_CLEANUP_POLICY_RESIDUE'}
            }
        }
        # Disposable payloads can be large. Keep the small policy/run receipts,
        # but clear these exact test-owned children only after verified cleanup.
        $current=Get-LabOwnedHostPolicy -StateRoot $Root -Required
        if($current.PolicyId -cne $policy.PolicyId){throw 'OWNED_TEST_CLEANUP_POLICY_DRIFT'}
        $payloads=@(foreach($leaf in @('test-artifacts','dpf','dtr')){
            $path=Assert-LabOwnedHostPath (Join-Path $policy.StateRoot $leaf)
            if(-not(Test-Path -LiteralPath $path)){continue}
            if(@(Get-ChildItem -LiteralPath $path -Recurse -Force -ErrorAction Stop|Where-Object {$_.Attributes -band [IO.FileAttributes]::ReparsePoint}).Count){throw 'OWNED_TEST_CLEANUP_ARTIFACT_LINK'}
            $path
        })
        foreach($path in $payloads){
            Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop
            if(Test-Path -LiteralPath $path){throw 'OWNED_TEST_CLEANUP_ARTIFACT_REMAINS'}
        }
        [pscustomobject]@{Status='CLEAN';Runs=$runs.Count}
    } $StateRoot
}
