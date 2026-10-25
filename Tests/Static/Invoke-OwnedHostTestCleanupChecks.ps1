#Requires -Version 7.2
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '../Common/OwnedHostTestCleanup.ps1')
$passed=0
foreach($scenario in @('nonpersistent','persistent','already-removed-store','foreign-policy','outside-data','remove-failure','native-residue','daemon-failure','no-runs','policy-orphan','missing-data-clean','missing-data-residue')){
    $root=Join-Path ([IO.Path]::GetTempPath()) ('owned-cleanup-check-'+[guid]::NewGuid().ToString('N'))
    $id=[guid]::NewGuid().ToString('D')
    $null=New-Item -ItemType Directory -Path (Join-Path $root ('runs/'+$id)) -Force
    foreach($leaf in @('test-artifacts','dpf','dtr')){
        if($leaf -eq 'dpf' -and $scenario -like 'missing-data-*'){continue}
        $null=New-Item -ItemType Directory -Path (Join-Path $root $leaf)
        [IO.File]::WriteAllText((Join-Path $root ($leaf+'/synthetic.bin')),'owned payload')
    }
    if($scenario -in @('no-runs','policy-orphan')){
        [IO.Directory]::Delete((Join-Path $root ('runs/'+$id)),$false)
        [IO.Directory]::Delete((Join-Path $root 'runs'),$false)
    }
    $module=New-Module -ArgumentList $root,$id,$scenario -ScriptBlock {
        param($Root,$Id,$Scenario)
        $script:root=$Root;$script:id=$Id;$script:scenario=$Scenario
        $script:removed=0;$script:tasks=0;$script:stores=0;$script:observations=0;$script:configurations=0
        function Get-LabOwnedHostPolicy {param($StateRoot,[switch]$Required)[pscustomobject]@{StateRoot=$script:root;PolicyId='owned-policy';RuntimePins=@([pscustomobject]@{Provider='docker'})}}
        function Assert-LabOwnedHostPath {param($Path)[IO.Path]::GetFullPath($Path)}
        function Get-LabRunState {param($RunId,$StateRoot)
            $persistent=$script:scenario -in @('persistent','already-removed-store','outside-data','missing-data-clean','missing-data-residue')
            $data=if($script:scenario -eq 'outside-data'){Split-Path $script:root -Parent}else{Join-Path $script:root 'dpf'}
            [pscustomobject]@{runId=$script:id;metadata=[pscustomobject]@{persistentData=$persistent;dataRoot=$data;desiredState=[pscustomobject]@{Instances=@([pscustomobject]@{Intents=[pscustomobject]@{Drives=@([pscustomobject]@{Persistence='data-root-runtime-volume';PersistentStorageId='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'})}})}}}
        }
        function Get-LabOwnedHostRunPolicy {param($RunId,$StateRoot)[pscustomobject]@{PolicyId=$(if($script:scenario -eq 'foreign-policy'){'foreign'}else{'owned-policy'})}}
        function Remove-SqlServerLab {
            [CmdletBinding(SupportsShouldProcess)]
            param($RunId,$StateRoot,[switch]$Force)
            $script:removed++;if($script:scenario -eq 'remove-failure'){throw 'synthetic remove failure'};[pscustomobject]@{Status='REMOVED'}
        }
        function Remove-LabOwnedHostAutoStartIfUnused {param($StateRoot,$RunId,$Provider)$script:tasks++}
        function Get-LabStorageConfiguration {param($DataRoot)
            $script:configurations++
            if(-not(Test-Path -LiteralPath $DataRoot)){throw 'Acceptance data root already removed'}
            if($DataRoot -ne (Join-Path $script:root 'dpf')){throw 'Foreign data root reached'}
            'synthetic-configuration'
        }
        function Get-LabPersistentStorageCatalog {param($Configuration)
            [pscustomobject]@{Status='AVAILABLE';Document=[pscustomobject]@{Stores=@([pscustomobject]@{PersistentStorageId='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';State=$(if($script:scenario -eq 'already-removed-store'){'REMOVED'}else{'DETACHED'})})}}
        }
        function Get-SqlServerLabRetainedStoreRemovalPlan {param($PersistentStorageId,$DataRoot,$StateRoot)[pscustomobject]@{Status='READY';CatalogRevision=19;PlanKey='bound-plan'}}
        function Invoke-SqlServerLabRetainedStoreRemoval {
            [CmdletBinding(SupportsShouldProcess)]
            param($PersistentStorageId,$DataRoot,$StateRoot,$ExpectedCatalogRevision,$ExpectedPlanKey)
            if($PersistentStorageId -ne [guid]'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' -or $ExpectedCatalogRevision -ne 19 -or $ExpectedPlanKey -ne 'bound-plan'){throw 'Unbound store deletion'}
            $script:stores++;[pscustomobject]@{Status='REMOVED'}
        }
        function Invoke-LabOwnedHostPinnedCommand {param($StateRoot,$Provider,$Arguments)
            $script:observations++
            if($StateRoot -ne $script:root -or $Provider -ne 'docker' -or (('label=sql-server-lab.run-id='+$script:id) -notin $Arguments -and 'label=sql-server-lab.owned-host-policy-id=owned-policy' -notin $Arguments)){throw 'Unbound provider inventory'}
            [pscustomobject]@{ExitCode=$(if($script:scenario -eq 'daemon-failure'){125}else{0});Stdout=$(if($script:scenario -in @('native-residue','policy-orphan','missing-data-residue')){'own residue'}else{''})}
        }
    }
    try{
        $blocked=$false
        try{$result=Invoke-OwnedHostTestCleanup -StateRoot $root -Module $module}catch{$blocked=$true}
        $expectedFailure=$scenario -in @('foreign-policy','outside-data','remove-failure','native-residue','daemon-failure','policy-orphan','missing-data-residue')
        if($blocked -ne $expectedFailure){throw "Wrong finalizer result: $scenario"}
        $counts=& $module {[pscustomobject]@{Runs=$script:removed;Tasks=$script:tasks;Stores=$script:stores;Observations=$script:observations;Configurations=$script:configurations}}
        if($scenario -eq 'foreign-policy' -and $counts.Runs -ne 0){throw 'Mutation before complete ownership preflight'}
        if($scenario -eq 'persistent' -and $counts.Stores -ne 1){throw 'Persistent test store not removed'}
        if($scenario -in @('outside-data','already-removed-store') -and $counts.Stores -ne 0){throw 'Unsafe or duplicate store removal'}
        if($scenario -like 'missing-data-*' -and ($counts.Configurations -ne 0 -or $counts.Stores -ne 0 -or $counts.Observations -eq 0)){throw 'Completed acceptance must still verify native absence without a deleted catalog'}
        if(-not(Test-Path -LiteralPath $root)){throw 'Durable recovery state erased'}
        foreach($leaf in @('test-artifacts','dpf','dtr')){
            $expectedPayload=$expectedFailure -and -not($leaf -eq 'dpf' -and $scenario -like 'missing-data-*')
            if((Test-Path -LiteralPath (Join-Path $root $leaf)) -ne $expectedPayload){throw "Wrong temporary payload disposition: $scenario/$leaf"}
        }
        $passed++
    }finally{
        Remove-Module $module -Force
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}
Write-Host "OWNED HOST TEST CLEANUP: PASS ($passed scenarios; no provider or task mutation)"
