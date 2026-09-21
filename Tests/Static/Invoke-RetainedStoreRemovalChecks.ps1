#Requires -Version 7.2
[CmdletBinding()]
param([switch]$CancellationChild)
$ErrorActionPreference='Stop'
$repo=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$root=Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-retained-remove-check-'+[guid]::NewGuid().ToString('N'))
$module=Import-Module (Join-Path $repo 'SQLServerLab.psd1') -Force -PassThru
try {
    & $module {
        param($Root,$Repo,$Cancel)
        . (Join-Path $Repo 'Tests/Common/PersistentStorageRecoveryFixture.ps1')
        $script:count=0
        $script:realWrite=${function:Write-LabArtifactJsonAtomic}
        function Assert-Removal {param([bool]$Condition,[string]$Name)
            if(-not $Condition){throw "RETAINED_REMOVAL_CHECK_FAILED: $Name"}
            $script:count++; Write-Host "PASS: $Name"
        }
        function Reset-Removal {
            param([string]$Provider='docker',[switch]$Recovered)
            $script:fixture=New-TestPersistentStorageRecoveryFixture -Root (Join-Path $Root ([guid]::NewGuid().ToString('N'))) -Provider $Provider
            $script:fixture.Runtime | Add-Member -NotePropertyMembers @{CreatedAt='2026-09-20T10:00:00Z';Driver='local';Options=$null}
            $script:exists=$false; $script:sidecar=$false; $script:unknown=$false; $script:deletes=0
            $script:scope=$script:fixture.RuntimeScopeId; $script:deleteMode='SUCCESS'; $script:onRead=$null
            $script:writeFault=$null; $script:readCount=0; $script:writeEvents=@()
            $script:removalArguments=@{PersistentStorageId=$script:fixture.StorageId;DataRoot=$script:fixture.DataRoot;StateRoot=$script:fixture.Run.StateRoot}
            if($Recovered){
                $script:exists=$true
                Repair-SqlServerLabPersistentStorageCatalog -OriginalRunId $script:fixture.Run.RunId -InstanceId primary `
                    -ExpectedPersistentStorageId $script:fixture.StorageId -ExpectedRuntimeScopeId $script:scope `
                    -DataRoot $script:fixture.DataRoot -StateRoot $script:fixture.Run.StateRoot -Confirm:$false | Out-Null
            }
            else {
                $lease=Register-LabContainerInstanceStoreLease -Provider $Provider -VolumeName $script:fixture.Runtime.VolumeName `
                    -RunId $script:fixture.Run.RunId -ScopeId $script:fixture.Run.ScopeId -SqlVersion 2025 `
                    -DisplayName 'Removal fixture' -DataRoot $script:fixture.DataRoot -Configuration $script:fixture.Configuration
                $script:exists=$true
                Unregister-LabContainerInstanceStoreLease -Provider $Provider -VolumeName $script:fixture.Runtime.VolumeName `
                    -RunId $script:fixture.Run.RunId -ScopeId $script:fixture.Run.ScopeId `
                    -DataRoot $script:fixture.DataRoot -Configuration $script:fixture.Configuration | Out-Null
                Assert-Removal (-not $lease.Store.RuntimeBinding) 'Normaler Producer bleibt ohne implizite RuntimeBinding-Migration'
            }
        }
        function Snapshot-Removal {
            $paths=@($script:fixture.Configuration.LabDataLocations | ForEach-Object {Join-Path $_.LabDataRoot 'Catalog/persistent-stores.json'})
            $paths+=@(Get-ChildItem -LiteralPath $script:fixture.Run.StateRoot -Recurse -File | ForEach-Object FullName)
            @($paths | Sort-Object -Unique | ForEach-Object {if(Test-Path -LiteralPath $_){(Get-FileHash -LiteralPath $_).Hash}else{'MISSING'}}) -join '|'
        }
        function Get-Record { (Get-LabPersistentStorageCatalog -Configuration $script:fixture.Configuration).Document.Stores[0] }
        function Edit-Record {
            param([scriptblock]$Change)
            Invoke-LabPersistentStorageCatalogMutation -Configuration $script:fixture.Configuration -MutationName TEST_SYNTHETIC_CHANGE -Mutation $Change | Out-Null
        }
        function Resume-Removal {
            param($Result)
            Invoke-SqlServerLabRetainedStoreRemoval @script:removalArguments -OperationId $Result.OperationId -Confirm:$false
        }
        function Apply-Removal {
            param($Plan)
            if(-not $Plan){$Plan=Get-SqlServerLabRetainedStoreRemovalPlan @script:removalArguments}
            Invoke-SqlServerLabRetainedStoreRemoval @script:removalArguments -ExpectedCatalogRevision $Plan.CatalogRevision -ExpectedPlanKey $Plan.PlanKey -Confirm:$false
        }
        function Assert-Rejected {
            param([string]$Name,[scriptblock]$Action)
            $before=Snapshot-Removal; $caught=$false; $deletes=$script:deletes
            try { & $Action | Out-Null } catch {$caught=$true}
            Assert-Removal ($caught -and $before -ceq (Snapshot-Removal) -and $deletes -eq $script:deletes) $Name
        }
        Set-Item Function:Resolve-LabDataRootForUse -Value {param($DataRoot)$DataRoot}
        Set-Item Function:Get-LabStorageConfiguration -Value {param($DataRoot)$script:fixture.Configuration}
        Set-Item Function:Test-LabDataRootOwnership -Value {param($DataRoot,$ControllerId)$true}
        Set-Item Function:New-LabPersistentStorageId -Value {$script:fixture.StorageId}
        Set-Item Function:Get-LabContainerRuntimeScope -Value {param($Provider)[pscustomobject]@{Status='AVAILABLE';RuntimeId=$script:scope}}
        Set-Item Function:Get-LabRetainedStoreRuntimeContext -Value {
            param($Provider)
            [pscustomobject]@{Provider=$Provider;RuntimeScopeId=$script:scope;Arguments=@('--context','fixture');CheckedAt=[datetime]::UtcNow}
        }
        Set-Item Function:Get-LabRetainedStoreVolume -Value {
            param($Context,$VolumeName)
            $script:readCount++
            if($script:onRead){& $script:onRead $VolumeName}
            if($script:unknown){throw 'RETAINED_STORE_ABSENCE_UNVERIFIABLE'}
            if($VolumeName -cne $script:fixture.Runtime.VolumeName){
                return [pscustomobject]@{Status=if($script:sidecar){'AVAILABLE'}else{'MISSING'}}
            }
            if(-not $script:exists){return [pscustomobject]@{Status='MISSING';VolumeName=$VolumeName}}
            $script:fixture.Runtime | ConvertTo-Json -Depth 15 | ConvertFrom-Json -Depth 15
        }
        Set-Item Function:Get-LabContainerInstanceStoreRuntimeInspection -Value {
            param($Provider,$VolumeName,[switch]$RequireMissingEvidence)
            Get-LabRetainedStoreVolume -Context ([pscustomobject]@{Provider=$Provider}) -VolumeName $VolumeName
        }
        Set-Item Function:Remove-LabRetainedStoreVolume -Value {
            param($Context,$VolumeName)
            $script:deletes++
            Assert-Removal ((Get-Record).State -ceq 'DELETE_PENDING') 'Delete erfolgt erst nach dauerhafter CAS-Reservierung'
            $journal=Get-ChildItem -LiteralPath (Join-Path $script:fixture.Run.StateRoot 'retained-store-removals') -File | Get-Content -Raw | ConvertFrom-Json
            Assert-Removal ($journal.Phase -ceq 'DELETE_REQUESTED') 'Delete hat bereits ein atomar persistiertes Journal'
            if($script:deleteMode -ceq 'FAIL'){throw 'RETAINED_STORE_DELETE_NOT_CONFIRMED'}
            $script:exists=$false
            if($script:deleteMode -ceq 'LOST_REPLY'){throw 'RETAINED_STORE_DELETE_NOT_CONFIRMED'}
        }
        Set-Item Function:Write-LabArtifactJsonAtomic -Value {
            param($Path,$InputObject)
            $script:writeEvents+=@([pscustomobject]@{Path=$Path;Object=$InputObject})
            if($script:writeFault){& $script:writeFault $Path $InputObject}
            & $script:realWrite -Path $Path -InputObject $InputObject
        }
        foreach($provider in @('docker','podman')){
            foreach($recovered in @($false,$true)){
                Reset-Removal -Provider $provider -Recovered:$recovered
                $before=Snapshot-Removal
                $plan=Get-SqlServerLabRetainedStoreRemovalPlan @script:removalArguments
                $again=Get-SqlServerLabRetainedStoreRemovalPlan @script:removalArguments
                Assert-Removal ($plan.PlanKey -ceq $again.PlanKey -and $before -ceq (Snapshot-Removal)) 'Preview-Key ist stabil trotz wechselnder Beobachtungszeit'
                if($Cancel){
                    $cancelled=Invoke-SqlServerLabRetainedStoreRemoval @script:removalArguments -ExpectedCatalogRevision $plan.CatalogRevision -ExpectedPlanKey $plan.PlanKey -Confirm
                    Assert-Removal ($cancelled.Status -ceq 'CANCELLED' -and $before -ceq (Snapshot-Removal)) 'Benutzerabbruch bleibt schreibfrei'
                    Write-Host 'RETAINED_REMOVAL_CANCEL_PASS'
                    return
                }
                $whatif=Invoke-SqlServerLabRetainedStoreRemoval @script:removalArguments -ExpectedCatalogRevision $plan.CatalogRevision -ExpectedPlanKey $plan.PlanKey -WhatIf
                Assert-Removal ($whatif.Status -ceq 'PLANNED' -and $before -ceq (Snapshot-Removal) -and $script:deletes -eq 0) 'WhatIf erhält Bytes, Revision und Runtime'
                $removed=Apply-Removal $plan
                Assert-Removal ($removed.Status -ceq 'REMOVED' -and -not $script:exists -and $script:deletes -eq 1 -and (Get-Record).State -ceq 'REMOVED') "Producer $provider recovered=$recovered endet als Tombstone ($($removed.Reason))"
                $before=Snapshot-Removal
                $repeat=Invoke-SqlServerLabRetainedStoreRemoval @script:removalArguments -OperationId $removed.OperationId -Confirm:$false
                Assert-Removal ($repeat.Status -ceq 'REMOVED' -and $before -ceq (Snapshot-Removal) -and $script:deletes -eq 1) 'Terminales Resume ist byte- und revisionsidentisch'
            }
        }
        foreach($fault in @('LOST_REPLY','FAIL')){
            Reset-Removal
            $script:deleteMode=$fault
            $result=Apply-Removal
            Assert-Removal ($result.Status -ceq 'RECOVERY_REQUIRED' -and (Get-Record).State -ceq 'DELETE_PENDING') "$fault behält eigene Reservierung"
            $script:deleteMode='SUCCESS'
            $resumed=Invoke-SqlServerLabRetainedStoreRemoval @script:removalArguments -OperationId $result.OperationId -Confirm:$false
            Assert-Removal ($resumed.Status -ceq 'REMOVED' -and $script:deletes -eq $(if($fault -ceq 'LOST_REPLY'){1}else{2})) "$fault wird ausschließlich vorwärts fortgesetzt"
        }
        foreach($negative in @('LABEL','ATTACHED','SIDECAR','UNKNOWN','SOURCE','RUNTIME','REPLACED')){
            Reset-Removal
            $plan=Get-SqlServerLabRetainedStoreRemovalPlan @script:removalArguments
            switch($negative){
                LABEL {$script:fixture.Runtime.Labels.'sql-server-lab.scope-id'=[guid]::NewGuid().ToString('D')}
                ATTACHED {$script:fixture.Runtime.AttachedContainers=@('b'*64)}
                SIDECAR {$script:sidecar=$true}
                UNKNOWN {$script:unknown=$true}
                SOURCE {$script:fixture.State.state='RUNNING'; & $script:realWrite -Path (Join-Path $script:fixture.Run.RunDir 'run-state.json') -InputObject $script:fixture.State}
                RUNTIME {$script:scope='runtime-scope-'+('2'*24)}
                REPLACED {$script:fixture.Runtime.CreatedAt='2026-09-21T10:00:00Z'}
            }
            Assert-Rejected "$negative zwischen Preview und Apply wird schreibfrei abgewiesen" {Apply-Removal $plan}
        }
        foreach($negative in @('REVISION','LEASE','REFERENCE','DUPLICATE','RETENTION','LEGACY')){
            Reset-Removal
            $plan=Get-SqlServerLabRetainedStoreRemovalPlan @script:removalArguments
            switch($negative){
                REVISION { Edit-Record {param($doc)$doc.Stores[0].DisplayName='Renamed synthetic store'} }
                LEASE {
                    Register-LabContainerInstanceStoreLease -Provider docker -VolumeName $script:fixture.Runtime.VolumeName `
                        -RunId $script:fixture.Run.RunId -ScopeId $script:fixture.Run.ScopeId -SqlVersion 2025 `
                        -DisplayName 'Continued fixture' -DataRoot $script:fixture.DataRoot -Configuration $script:fixture.Configuration | Out-Null
                }
                REFERENCE { Edit-Record {param($doc)$doc.Stores[0].References+=@([pscustomobject]@{ReferenceId=[guid]::NewGuid().ToString('D');Kind='DATABASE';State='ACTIVE';TargetId='synthetic-reference'})} }
                DUPLICATE { Edit-Record {param($doc)$copy=$doc.Stores[0]|ConvertTo-Json -Depth 20|ConvertFrom-Json -Depth 20;$copy.PersistentStorageId=[guid]::NewGuid().ToString('D');$doc.Stores+=@($copy)} }
                RETENTION { Edit-Record {param($doc)$doc.Stores[0].Retention='RUN_SCOPED';$doc.Stores[0].CleanupDisposition='RUN_CLEANUP'} }
                LEGACY {$script:fixture.Runtime.Labels.'sql-server-lab.persistent-storage-id'=$null}
            }
            Assert-Rejected "$negative sperrt veraltetes Apply ohne weitere Mutation" {Apply-Removal $plan}
        }
        # Inject failures in the real atomic writer, not a replacement executor.
        foreach($fault in @('PREPARED','RESERVATION_MIRROR','DELETE_REQUESTED','TERMINAL_MIRROR','TERMINAL_JOURNAL')){
            Reset-Removal
            $script:faultMode=$fault; $script:faultTriggered=$false
            $script:writeFault={param($path,$value)
                $isCatalog=$value.ContractVersion -ceq 'SqlServerLab.PersistentStorageCatalog/1.0'
                $isSecond=$path.StartsWith([string]$script:fixture.Configuration.LabDataLocations[1].LabDataRoot,[StringComparison]::OrdinalIgnoreCase)
                $isJournal=$value.ContractVersion -ceq 'SqlServerLab.RetainedStoreRemovalJournal/1.0'
                $hit=switch($script:faultMode){
                    PREPARED {$isJournal -and $value.Phase -ceq 'PREPARED'}
                    RESERVATION_MIRROR {$isCatalog -and $isSecond -and $value.Stores[0].State -ceq 'DELETE_PENDING'}
                    DELETE_REQUESTED {$isJournal -and $value.Phase -ceq 'DELETE_REQUESTED'}
                    TERMINAL_MIRROR {$isCatalog -and $isSecond -and $value.Stores[0].State -ceq 'REMOVED'}
                    TERMINAL_JOURNAL {$isJournal -and $value.Phase -ceq 'REMOVED'}
                }
                if($hit -and -not $script:faultTriggered){$script:faultTriggered=$true;throw 'SYNTHETIC_PRIVATE_HOST_DIAGNOSTIC'}
            }
            $result=Apply-Removal
            $catalog=Get-LabPersistentStorageCatalog -Configuration $script:fixture.Configuration
            $expectedState=switch($fault){PREPARED {'DETACHED'};RESERVATION_MIRROR {'DETACHED'};TERMINAL_JOURNAL {'REMOVED'};default{'DELETE_PENDING'}}
            Assert-Removal ($script:faultTriggered -and $result.Status -cin @('BLOCKED','RECOVERY_REQUIRED') -and
                $catalog.Status -ceq 'AVAILABLE' -and (Get-Record).State -ceq $expectedState) "$fault erhält konsistenten fortsetzbaren Katalog"
            Assert-Removal (($result|ConvertTo-Json -Compress) -notmatch 'SYNTHETIC_PRIVATE_HOST_DIAGNOSTIC') "$fault veröffentlicht keine rohe Schreibdiagnose"
            if($fault -cin @('PREPARED','RESERVATION_MIRROR','DELETE_REQUESTED')){
                Assert-Removal ($script:deletes -eq 0 -and $script:exists) "$fault findet vor dem ersten Delete statt"
            }
            else {Assert-Removal ($script:deletes -eq 1 -and -not $script:exists) "$fault verliert den erfolgreichen Delete nicht"}
            $script:writeFault=$null
            $done=if($fault -ceq 'PREPARED'){Apply-Removal}else{Resume-Removal $result}
            Assert-Removal ($done.Status -ceq 'REMOVED' -and $script:deletes -eq 1) "$fault setzt vorwärts ohne doppelte erfolgreiche Löschung fort"
        }
        foreach($negative in @('REPLACED','RUNTIME','UNKNOWN','ATTACHED','SOURCE')){
            Reset-Removal
            $script:deleteMode='FAIL'; $result=Apply-Removal; $script:deleteMode='SUCCESS'
            switch($negative){
                REPLACED {$script:fixture.Runtime.CreatedAt='2026-09-21T11:00:00Z'}
                RUNTIME {$script:scope='runtime-scope-'+('3'*24)}
                UNKNOWN {$script:unknown=$true}
                ATTACHED {$script:fixture.Runtime.AttachedContainers=@('c'*64)}
                SOURCE {$script:fixture.State.metadata | Add-Member -NotePropertyName syntheticChange -NotePropertyValue $true; & $script:realWrite -Path (Join-Path $script:fixture.Run.RunDir 'run-state.json') -InputObject $script:fixture.State}
            }
            $before=Snapshot-Removal; $attempts=$script:deletes
            $blocked=Resume-Removal $result
            Assert-Removal ($blocked.Status -ceq 'RECOVERY_REQUIRED' -and $before -ceq (Snapshot-Removal) -and $attempts -eq $script:deletes) "$negative verhindert Resume ohne Journal- oder Runtime-Mutation"
        }
        Reset-Removal
        $script:deleteMode='FAIL'; $result=Apply-Removal
        $catalog=Get-LabPersistentStorageCatalog -Configuration $script:fixture.Configuration
        foreach($action in @('CONTINUE','CLONE')){
            $intent=[pscustomobject]@{
                ContractVersion='SqlServerLab.ContainerInstanceStoreIntent/1.0';OperationId=[guid]::NewGuid().ToString('D');Action=$action
                SourcePersistentStorageId=$script:fixture.StorageId;TargetPersistentStorageId=if($action -ceq 'CLONE'){[guid]::NewGuid().ToString('D')}else{$null}
                TargetVolumeName=if($action -ceq 'CLONE'){'sql-lab-synthetic-target'}else{$null};Provider='docker'
                TargetRunId=[guid]::NewGuid().ToString('D');TargetScopeId=[guid]::NewGuid().ToString('D');TargetSqlMajorVersion='2025'
                HelperImage=if($action -ceq 'CLONE'){'mcr.microsoft.com/mssql/server:2025-latest'}else{$null};IncludeExternalRuntimeSidecars=$false
            }
            $blocked=Get-LabContainerInstanceStorePlan -Intent $intent -Catalog $catalog -RuntimeInspection $script:fixture.Runtime
            Assert-Removal ($blocked.Status -ceq 'BLOCKED') "$action wird durch DELETE_PENDING blockiert"
        }
        Assert-Rejected 'Lease-Erwerb kann DELETE_PENDING nicht übernehmen' {
            Register-LabContainerInstanceStoreLease -Provider docker -VolumeName $script:fixture.Runtime.VolumeName `
                -RunId $script:fixture.Run.RunId -ScopeId $script:fixture.Run.ScopeId -SqlVersion 2025 `
                -DisplayName 'Blocked fixture' -DataRoot $script:fixture.DataRoot -Configuration $script:fixture.Configuration
        }
        Assert-Rejected 'Recovery kann DELETE_PENDING nicht zurücksetzen' {
            Repair-SqlServerLabPersistentStorageCatalog -OriginalRunId $script:fixture.Run.RunId -InstanceId primary `
                -ExpectedPersistentStorageId $script:fixture.StorageId -ExpectedRuntimeScopeId $script:scope `
                -DataRoot $script:fixture.DataRoot -StateRoot $script:fixture.Run.StateRoot -Confirm:$false
        }
        Assert-Rejected 'Fremde Operation kann Reservierung nicht übernehmen' {
            Invoke-SqlServerLabRetainedStoreRemoval @script:removalArguments -OperationId ([guid]::NewGuid()) -Confirm:$false
        }
        $script:deleteMode='SUCCESS'; $null=Resume-Removal $result
        $catalog=Get-LabPersistentStorageCatalog -Configuration $script:fixture.Configuration
        $empty=[pscustomobject]@{Objects=@()}
        $projection=Get-LabPersistentStoragePlan -Catalog $catalog -ResidencyInventory $empty
        Assert-Removal ($projection.Status -ceq 'READY' -and $projection.Stores[0].ObservationStatus -ceq 'NOT_REQUIRED' -and
            $projection.Actions[0].Reason -ceq 'STORAGE_REMOVED' -and @((Get-LabRetainedStoreRemovalCandidates -Catalog $catalog)).Count -eq 0) 'Tombstone ist kein vermisster oder auswählbarer Store'
        $reappeared=[pscustomobject]@{Objects=@([pscustomobject]@{
            ObjectId=(Get-Record).LocationBinding.InventoryObjectId;Provider='docker';LogicalName=$script:fixture.Runtime.VolumeName
            Lifecycle='RETAINED';AuditStatus='VERIFIED';RunIds=@();Details=[pscustomobject]@{}
        })}
        $projection=Get-LabPersistentStoragePlan -Catalog $catalog -ResidencyInventory $reappeared
        Assert-Removal ($projection.Status -ceq 'BLOCKED' -and $projection.Summary.RegistrationCandidates -eq 0) 'Wiedererschienene Bindung ist Konflikt statt Registrierungskandidat'
        Assert-Rejected 'Tombstone kann nicht aus dem Katalog gelöscht werden' {Edit-Record {param($doc)$doc.Stores=@()}}
        Assert-Rejected 'Tombstone-ID kann nicht reaktiviert werden' {Edit-Record {param($doc)$doc.Stores[0].State='DETACHED';$doc.Stores[0].PSObject.Properties.Remove('Deletion')}}
        $script:exists=$true
        Assert-Rejected 'Recovery kann terminale Identität nicht wiederverwenden' {
            Repair-SqlServerLabPersistentStorageCatalog -OriginalRunId $script:fixture.Run.RunId -InstanceId primary `
                -ExpectedPersistentStorageId $script:fixture.StorageId -ExpectedRuntimeScopeId $script:scope `
                -DataRoot $script:fixture.DataRoot -StateRoot $script:fixture.Run.StateRoot -Confirm:$false
        }
        $before=Snapshot-Removal; $attempts=$script:deletes
        $blocked=Resume-Removal $result
        Assert-Removal ($blocked.Status -ceq 'RECOVERY_REQUIRED' -and $attempts -eq $script:deletes -and $before -ceq (Snapshot-Removal)) 'Terminales Resume löscht ein wiedererschienenes Volume niemals'
        Set-Item Function:Get-LabDataRootDefault -Value {$script:fixture.DataRoot}
        Set-Item Function:Get-LabStateRoot -Value {$script:fixture.Run.StateRoot}
        Set-Item Function:Invoke-LabConsoleMenu -Value {
            param($ScreenId,$Title,$Subtitle,$Items)
            [pscustomobject]@{Cancelled=$false;Id=$script:fixture.StorageId}
        }
        Set-Item Function:Read-LabConfirm -Value {param($Prompt,$Default)$script:confirmed}
        Set-Item Function:Write-LabInfo -Value {param($Message)}
        Set-Item Function:Write-LabStatus -Value {param($Label,$Value)}
        Set-Item Function:Write-LabSuccess -Value {param($Message)}
        Reset-Removal
        $script:confirmed=$false;$before=Snapshot-Removal
        Invoke-LabRetainedStoreRemovalInteractive
        Assert-Removal ($before -ceq (Snapshot-Removal) -and $script:deletes -eq 0) 'CLI-Abbruch verändert keine Bytes oder Ressourcen'
        $script:confirmed=$true
        Invoke-LabRetainedStoreRemovalInteractive
        Assert-Removal ((Get-Record).State -ceq 'REMOVED' -and $script:deletes -eq 1) 'CLI bestätigt und nutzt den echten öffentlichen Executor'
        Reset-Removal
        $script:deleteMode='FAIL';$caught=$false
        try{Invoke-LabRetainedStoreRemovalInteractive}catch{$caught=$_.Exception.Message -match '^RETAINED_STORE_RECOVERY_REQUIRED:'}
        Assert-Removal ($caught -and (Get-Record).State -ceq 'DELETE_PENDING') 'CLI meldet Deletefehler als Fehler statt erfolgreichen Abschluss'
        $script:deleteMode='SUCCESS'
        Invoke-LabRetainedStoreRemovalInteractive
        Assert-Removal ((Get-Record).State -ceq 'REMOVED') 'CLI setzt nur die katalogisierte eigene Operation fort'
        Reset-Removal
        $workflow=@{Action='RemoveRetainedStore';PersistentStorageId=$script:fixture.StorageId;DataRoot=$script:fixture.DataRoot}
        Assert-Rejected 'Workflow benötigt eine konkrete geprüfte Vorschau' {Invoke-SqlServerLabWorkflowAction @workflow}
        $plan=Get-SqlServerLabRetainedStoreRemovalPlan @script:removalArguments
        $script:deleteMode='FAIL';$caught=$false
        try{Invoke-SqlServerLabWorkflowAction @workflow -ExpectedCatalogRevision $plan.CatalogRevision -ExpectedPlanKey $plan.PlanKey}catch{$caught=$_.Exception.Message -match '^RETAINED_STORE_RECOVERY_REQUIRED:'}
        Assert-Removal ($caught -and (Get-Record).State -ceq 'DELETE_PENDING') 'Workflow gibt einen fehlgeschlagenen Delete nicht als abgeschlossen aus'
        $script:deleteMode='SUCCESS'
        $completed=Invoke-SqlServerLabWorkflowAction @workflow -PersistentStorageOperationId (Get-Record).Deletion.OperationId
        Assert-Removal ($completed.Result.Status -ceq 'REMOVED' -and (Get-Record).State -ceq 'REMOVED') 'Workflow-Resume verwendet den öffentlichen eigenen Vorgang'
        Write-Host "Retained store removal checks passed: $script:count"
    } $root $repo ([bool]$CancellationChild)
    if(-not $CancellationChild){
        $start=[Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
        foreach($argument in @('-NoProfile','-File',$PSCommandPath,'-CancellationChild')){$start.ArgumentList.Add($argument)}
        $start.UseShellExecute=$false;$start.CreateNoWindow=$true
        $start.RedirectStandardInput=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
        $child=[Diagnostics.Process]::Start($start)
        try{
            $output=$child.StandardOutput.ReadToEndAsync();$errors=$child.StandardError.ReadToEndAsync()
            $child.StandardInput.WriteLine('n');$child.StandardInput.Close()
            if(-not $child.WaitForExit(30000)){throw 'RETAINED_REMOVAL_CANCEL_TIMEOUT'}
            if($child.ExitCode -ne 0 -or $output.GetAwaiter().GetResult() -notmatch 'RETAINED_REMOVAL_CANCEL_PASS'){
                throw ('RETAINED_REMOVAL_CANCEL_FAILED: '+$errors.GetAwaiter().GetResult())
            }
            Write-Host "CANCELLATION_CHILD_EXITCODE: $($child.ExitCode)"
        }
        finally{
            if(-not $child.HasExited){$child.Kill($true);if(-not $child.WaitForExit(5000)){throw 'RETAINED_REMOVAL_CANCEL_TERMINATION_UNCONFIRMED'}}
            $child.Dispose()
        }
    }
}
finally {
    Remove-Module $module -Force
    # This root was generated by this test and contains synthetic files only.
    if(Test-Path -LiteralPath $root){
        $resolved=[IO.Path]::GetFullPath($root);$parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        if(-not $resolved.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notlike 'sql-lab-retained-remove-check-*'){throw 'TEST_CLEANUP_SCOPE_INVALID'}
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
