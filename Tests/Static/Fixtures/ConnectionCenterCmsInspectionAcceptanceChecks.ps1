#Requires -Version 7.2
# Actual test helpers and finalizer, with isolated synthetic boundary functions.
$ErrorActionPreference='Stop'
$repo=Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
. (Join-Path $repo Tests/Common/ConnectionCenterCmsInspectionAcceptance.ps1)
$checks=0
function Check($value,$name){if(-not $value){throw ('CMS_ACCEPTANCE_CHECK_FAILED: '+$name)};$script:checks++;Write-Host ('PASS: '+$name)}
function Remove-CmsInspectionFixtureTempRoot {
    param([string]$Path,[string]$TempBase,[ValidateSet('cms-custody-fixture-','cms-acceptance-fixture-')][string]$Prefix)
    $comparison=if($IsWindows){[StringComparison]::OrdinalIgnoreCase}else{[StringComparison]::Ordinal}
    if(-not [IO.Path]::IsPathFullyQualified($Path) -or -not [IO.Path]::IsPathFullyQualified($TempBase)){throw 'FIXTURE_DELETE_SCOPE'}
    $root=[IO.Path]::GetFullPath($Path).TrimEnd('\','/');$base=[IO.Path]::GetFullPath($TempBase).TrimEnd('\','/')
    if(-not $base.Equals([IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/'),$comparison) -or
        -not ([IO.Path]::GetDirectoryName($root)).Equals($base,$comparison) -or
        [IO.Path]::GetFileName($root) -cnotmatch ('^'+[regex]::Escape($Prefix)+'[a-f0-9]{32}$')){throw 'FIXTURE_DELETE_SCOPE'}
    $cursor=$root
    while($cursor){
        if(Test-Path -LiteralPath $cursor -ErrorAction Stop){if((Get-Item -LiteralPath $cursor -Force -ErrorAction Stop).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'FIXTURE_DELETE_REPARSE'}}
        $parent=[IO.Path]::GetDirectoryName($cursor);if($parent -eq $cursor){break};$cursor=$parent
    }
    if(-not (Test-Path -LiteralPath $root -ErrorAction Stop)){return}
    $item=Get-Item -LiteralPath $root -Force -ErrorAction Stop
    if(-not $item.PSIsContainer -or -not $item.FullName.TrimEnd('\','/').Equals($root,$comparison)){throw 'FIXTURE_DELETE_SCOPE'}
    $pending=[Collections.Generic.Queue[string]]::new();$pending.Enqueue($root)
    while($pending.Count){foreach($child in Get-ChildItem -LiteralPath $pending.Dequeue() -Force -ErrorAction Stop){
        if($child.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'FIXTURE_DELETE_REPARSE'}
        if($child.PSIsContainer){$pending.Enqueue($child.FullName)}
    }}
    # Same-user filesystem races remain non-atomic; guard failure retains root.
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction Stop
}
function Invoke-CmsInspectionFixtureCleanupChecks {
    param([string]$RepositoryRoot)
    $base=[IO.Path]::GetTempPath();$owned=Join-Path $base ('cms-acceptance-fixture-'+[guid]::NewGuid().ToString('N'))
    $outside=Join-Path $base ('cms-custody-fixture-'+[guid]::NewGuid().ToString('N'))
    $null=New-Item -ItemType Directory $owned,$outside
    [IO.File]::WriteAllText((Join-Path $outside sentinel),'unchanged')
    try {
        $thrown=$false;try{Remove-CmsInspectionFixtureTempRoot $RepositoryRoot $base 'cms-acceptance-fixture-'}catch{$thrown=$true}
        Check ($thrown -and (Test-Path $RepositoryRoot)) 'Fixture cleanup rejects outside-temp repository'
        $thrown=$false;try{Remove-CmsInspectionFixtureTempRoot $outside $base 'cms-acceptance-fixture-'}catch{$thrown=$true}
        Check ($thrown -and (Get-Content (Join-Path $outside sentinel) -Raw) -ceq 'unchanged') 'Fixture cleanup rejects wrong own prefix without deleting sentinel'
        if($IsWindows){
            $link=Join-Path $owned link;$null=New-Item -ItemType Junction -Path $link -Target $outside
            $thrown=$false;try{Remove-CmsInspectionFixtureTempRoot $owned $base 'cms-acceptance-fixture-'}catch{$thrown=$true}
            Check ($thrown -and (Test-Path $owned) -and (Get-Content (Join-Path $outside sentinel) -Raw) -ceq 'unchanged') 'Fixture cleanup rejects descendant reparse and retains both roots'
            Remove-Item -LiteralPath $link -Force
        }
        Remove-CmsInspectionFixtureTempRoot $owned $base 'cms-acceptance-fixture-'
        Check (-not (Test-Path $owned)) 'Fixture cleanup removes exact fresh full-GUID temp child'
    }finally{
        Remove-CmsInspectionFixtureTempRoot $owned $base 'cms-acceptance-fixture-'
        Remove-CmsInspectionFixtureTempRoot $outside $base 'cms-custody-fixture-'
    }
}
function Invoke-CmsInspectionAcceptanceCustodyChecks {
    param([string]$RepositoryRoot)
    $testRoot=Join-Path ([IO.Path]::GetTempPath()) ('cms-custody-fixture-'+[guid]::NewGuid().ToString('N'))
    $null=New-Item -ItemType Directory $testRoot
    try {
        foreach($provider in @('docker','podman')){
            foreach($case in @('primary-probe','history','duplicate-current','probe-claim-drift','intent-hash-drift','missing-current','record-limit','filename-drift','record-array','operation-drift','volume-label-drift','volume-claim-drift','volume-scope-drift')){
                $module=Import-Module (Join-Path $RepositoryRoot SqlServerLab.psd1) -Force -PassThru
                try {
                    $state=Join-Path $testRoot ($provider+'-'+$case)
                    $fixture=& $module {
                        param($State,$Provider,$Case)
                        $tools=Join-Path (Split-Path $State) ('tools-'+[guid]::NewGuid().ToString('N'));$null=New-Item -ItemType Directory $tools
                        [IO.File]::WriteAllText((Join-Path $tools ($Provider+'.exe')),'synthetic never executed')
                        $identity=Join-Path $tools synthetic.key;[IO.File]::WriteAllText($identity,'synthetic no credential')
                        $pin=[pscustomobject]@{Provider=$Provider;Invocation=(Join-Path $tools ($Provider+'.exe'));Endpoint=$(if($Provider -ceq 'docker'){'npipe:////./pipe/synthetic'}else{'ssh://synthetic@127.0.0.1:2222/run/podman/podman.sock'});IdentityPath=$(if($Provider -ceq 'podman'){$identity}else{''});IdentitySha256=$(if($Provider -ceq 'podman'){(Get-FileHash $identity).Hash.ToLowerInvariant()}else{''})}
                        if($IsWindows){$policy=Initialize-LabOwnedHostPolicy -StateRoot $State -RuntimePins @($pin) -ParentOperationId ('f'*32)}
                        else {
                            # Portable selector fixture; Windows ACL/pin evidence is separate.
                            $null=New-Item -ItemType Directory $State
                            $policy=[pscustomobject]@{PolicyId=[guid]::NewGuid().ToString('D');RootScopeId=[guid]::NewGuid().ToString('D');ParentOperationId=('f'*32);StateRoot=$State}
                            $script:custodyPolicy=$policy
                            function script:Get-LabOwnedHostPolicy {param($StateRoot,[switch]$Required);$script:custodyPolicy}
                            function script:Get-LabOwnedHostRunPolicy {param($StateRoot,$RunId);$script:custodyPolicy}
                            function script:Assert-LabOwnedHostContainerEffect {param($StateRoot,$RunId,$Provider,$ContainerId)}
                        }
                        $script:custodyInspect=$null;$script:custodyReads=0
                        function script:Invoke-LabOwnedHostNativeProcess {
                            param($StartInfo,[int]$TimeoutSeconds,[int]$MaximumBytes)
                            if(-not (@($StartInfo.ArgumentList) -ccontains 'inspect') -and -not (@($StartInfo.ArgumentList) -ccontains 'ps')){throw 'UNEXPECTED_NATIVE_MUTATION'}
                            $script:custodyReads++
                            $output=if(@($StartInfo.ArgumentList) -ccontains 'volume'){$script:custodyVolumeInspect|ConvertTo-Json -Depth 30 -Compress}elseif(@($StartInfo.ArgumentList) -ccontains 'inspect'){$script:custodyInspect|ConvertTo-Json -Depth 30 -Compress}else{''}
                            [pscustomobject]@{ExitCode=0;Stdout=$output;Stderr='';Output=$output}
                        }
                        $run=New-LabRunState -StateRoot $State -Metadata @{workflowOperationId=[guid]::NewGuid().ToString('D')} -ProviderSubRuns @([pscustomobject]@{provider=$Provider;instanceIds=@('primary')})
                        $stored=Get-LabRunState -StateRoot $State -RunId $run.RunId
                        $script:custodyContext=[pscustomobject]@{Run=$stored;Provider=$Provider;ContainerId=('a'*64);ContainerName='synthetic-primary';Inspect=[pscustomobject]@{Mounts=@([pscustomobject]@{Type='volume';Name='synthetic-volume'})}}
                        function script:Get-LabContainerReconcileContext {param($RunId,$InstanceId,$StateRoot);$script:custodyContext}
                        $directory=Join-Path $run.RunDir owned-host-containers;$null=New-Item -ItemType Directory $directory -Force
                        function Write-CustodyFixtureRecord($Instance,$Id,$Name){
                            $intent=[pscustomobject][ordered]@{ContractVersion='SqlServerLab.OwnedHostContainerIntent/1.0';IntentId=[guid]::NewGuid().ToString('D');PolicyId=$policy.PolicyId;RootScopeId=$policy.RootScopeId;RunId=$run.RunId;ScopeId=$run.ScopeId;WorkflowOperationId=$stored.metadata.workflowOperationId;InstanceId=$Instance;Provider=$Provider;ContainerName=$Name}
                            $ip=Join-Path $directory ($intent.IntentId+'.intent.json');Write-LabOwnedHostRecordExclusive -Path $ip -Record $intent
                            $receipt=[pscustomobject][ordered]@{ContractVersion='SqlServerLab.OwnedHostContainerReceipt/1.0';IntentId=$intent.IntentId;PolicyId=$policy.PolicyId;RootScopeId=$policy.RootScopeId;RunId=$run.RunId;ScopeId=$run.ScopeId;InstanceId=$Instance;Provider=$Provider;ContainerId=$Id;IntentSha256=(Get-FileHash $ip).Hash.ToLowerInvariant()}
                            $rp=Join-Path $directory ($intent.IntentId+'.created.json');Write-LabOwnedHostRecordExclusive -Path $rp -Record $receipt
                            [pscustomobject]@{Intent=$intent;Receipt=$receipt;IntentPath=$ip;ReceiptPath=$rp}
                        }
                        $primary=Write-CustodyFixtureRecord primary ('a'*64) synthetic-primary
                        $primaryHash=(Get-FileHash $primary.ReceiptPath).Hash
                        $probe=Write-CustodyFixtureRecord ('probe-'+[guid]::NewGuid().ToString('N')) ('b'*64) synthetic-probe
                        $volumeDirectory=Join-Path $State owned-host-volumes;$null=New-Item -ItemType Directory $volumeDirectory
                        $volumeIntent=[pscustomobject][ordered]@{ContractVersion='SqlServerLab.OwnedHostVolumeIntent/1.0';PolicyId=$policy.PolicyId;RootScopeId=$policy.RootScopeId;Provider=$Provider;VolumeName='synthetic-volume';IntentId=[guid]::NewGuid().ToString('D');RunId=$run.RunId;ScopeId=$run.ScopeId;InstanceId='primary';VersionId='2025';PersistentStorageId='';PersistentStorageRole=''}
                        $volumeIntentPath=Join-Path $volumeDirectory ($Provider+'-synthetic-volume.intent.json');Write-LabOwnedHostRecordExclusive -Path $volumeIntentPath -Record $volumeIntent
                        $volumeReceipt=[pscustomobject][ordered]@{ContractVersion='SqlServerLab.OwnedHostVolumeReceipt/1.0';PolicyId=$policy.PolicyId;RootScopeId=$policy.RootScopeId;Provider=$Provider;VolumeName='synthetic-volume';IntentId=$volumeIntent.IntentId;RunId=$run.RunId;ScopeId=$run.ScopeId;IntentSha256=(Get-FileHash $volumeIntentPath).Hash.ToLowerInvariant()}
                        $volumeReceiptPath=Join-Path $volumeDirectory ($Provider+'-synthetic-volume.created.json');Write-LabOwnedHostRecordExclusive -Path $volumeReceiptPath -Record $volumeReceipt
                        $volumeCustody=[pscustomobject]@{Name='synthetic-volume';ReceiptHash=(Get-FileHash $volumeReceiptPath).Hash;IntentHash=(Get-FileHash $volumeIntentPath).Hash}
                        $script:custodyVolumeInspect=[pscustomobject]@{Name='synthetic-volume';Labels=[pscustomobject]@{'sql-server-lab.run-id'=$run.RunId;'sql-server-lab.scope-id'=$run.ScopeId;'sql-server-lab.owned-host-policy-id'=$policy.PolicyId;'sql-server-lab.owned-host-root-scope-id'=$policy.RootScopeId;'sql-server-lab.owned-host-intent-id'=$volumeIntent.IntentId}}
                        if(-not $IsWindows){
                            # Keep the real getter/claim validation on portable hosts; only dispatch is synthetic.
                            function script:Invoke-LabOwnedHostPinnedCommand {param($StateRoot,$Provider,$Arguments);if(($Arguments -join ',') -cne 'volume,inspect,synthetic-volume'){throw 'UNEXPECTED_NATIVE_MUTATION'};[pscustomobject]@{ExitCode=0;Stdout=($script:custodyVolumeInspect|ConvertTo-Json -Depth 10 -Compress)}}
                        }
                        $script:custodyInspect=[pscustomobject]@{Id=('a'*64);Name='/synthetic-primary';Image=('sha256:'+('c'*64));State=[pscustomobject]@{Running=$true};Config=[pscustomobject]@{Labels=[pscustomobject]@{'sql-server-lab.run-id'=$run.RunId;'sql-server-lab.scope-id'=$run.ScopeId;'sql-server-lab.instance-id'='primary';'sql-server-lab.owned-host-policy-id'=$policy.PolicyId;'sql-server-lab.owned-host-root-scope-id'=$policy.RootScopeId;'sql-server-lab.owned-host-intent-id'=$primary.Intent.IntentId}}}
                        switch($Case){
                            history {$null=Write-CustodyFixtureRecord primary ('d'*64) synthetic-history}
                            duplicate-current {$null=Write-CustodyFixtureRecord primary ('a'*64) synthetic-primary}
                            probe-claim-drift {$probe.Receipt.ScopeId=[guid]::NewGuid().ToString('D');$probe.Receipt|ConvertTo-Json|Set-Content $probe.ReceiptPath}
                            intent-hash-drift {Add-Content $probe.IntentPath ' '}
                            missing-current {Remove-Item $primary.ReceiptPath}
                            record-limit {foreach($index in 1..127){[IO.File]::WriteAllText((Join-Path $directory (([guid]::NewGuid().ToString('D'))+'.created.json')),'{}')}}
                            filename-drift {Move-Item $probe.ReceiptPath (Join-Path $directory ([guid]::NewGuid().ToString('D')+'.created.json'))}
                            record-array {$probe.Receipt.Provider=@($Provider);$probe.Receipt|ConvertTo-Json -Depth 5|Set-Content $probe.ReceiptPath}
                            operation-drift {$probe.Intent.WorkflowOperationId=[guid]::NewGuid().ToString('D');$probe.Intent|ConvertTo-Json|Set-Content $probe.IntentPath;$probe.Receipt.IntentSha256=(Get-FileHash $probe.IntentPath).Hash.ToLowerInvariant();$probe.Receipt|ConvertTo-Json|Set-Content $probe.ReceiptPath}
                            volume-label-drift {$script:custodyVolumeInspect.Labels.'sql-server-lab.run-id'=[guid]::NewGuid().ToString('D')}
                            volume-claim-drift {$volumeReceipt.RunId=[guid]::NewGuid().ToString('D');$volumeReceipt|ConvertTo-Json|Set-Content $volumeReceiptPath}
                            volume-scope-drift {$differentScope=[guid]::NewGuid().ToString('D');$volumeReceipt.ScopeId=$differentScope;$volumeIntent.ScopeId=$differentScope;$volumeIntent|ConvertTo-Json|Set-Content $volumeIntentPath;$volumeReceipt.IntentSha256=(Get-FileHash $volumeIntentPath).Hash.ToLowerInvariant();$volumeReceipt|ConvertTo-Json|Set-Content $volumeReceiptPath;$script:custodyVolumeInspect.Labels.'sql-server-lab.scope-id'=$differentScope}
                        }
                        [pscustomobject]@{RunId=$run.RunId;ScopeId=$run.ScopeId;PrimaryIntent=$primary.Intent.IntentId;PrimaryReceiptHash=$primaryHash;Policy=$policy;VolumeCustody=$volumeCustody;BeforeCount=@(Get-ChildItem $directory -Filter '*.created.json').Count}
                    } $state $provider $case
                    $scope=[pscustomobject]@{StateRoot=$state;ParentOperationId=('f'*32)}
                    $thrown=$false;$custody=$null
                    try {$custody=Get-CmsInspectionAcceptanceCustody -Module $module -Scope $scope -RunId $fixture.RunId -Provider $provider}catch{$thrown=$true}
                    if($case -cin @('primary-probe','history')){
                        Check (-not $thrown -and $custody.IntentId -ceq $fixture.PrimaryIntent -and $custody.ContainerId -ceq ('a'*64) -and $custody.ContainerReceiptHash -ceq $fixture.PrimaryReceiptHash -and @($custody.Volumes).Count -eq 1 -and $custody.Volumes[0].Name -ceq 'synthetic-volume') "$provider exact primary and actual volume envelope with $case"
                    }else{Check $thrown "$provider custody veto $case"}
                    if($IsWindows -and $case -cin @('primary-probe','history')){Check ((& $module {$script:custodyReads}) -gt 0) 'Actual pinned ownership inspection uses synthetic process leaf'}
                    if($case -cin @('primary-probe','history','volume-label-drift','volume-claim-drift','volume-scope-drift')){
                        $tokens=$null;$parseErrors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $RepositoryRoot Tests/Common/ConnectionCenterCmsInspectionAcceptance.ps1),[ref]$tokens,[ref]$parseErrors)
                        $finalizer=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Remove-CmsInspectionAcceptanceScope'},$true))[0]
                        $volumeConsumer=@($finalizer.FindAll({param($n)$n -is [Management.Automation.Language.ForEachStatementAst] -and $n.Variable.VariablePath.UserPath -ceq 'volume' -and $n.Extent.Text.Contains('Get-LabOwnedHostVolumeReceipt')},$true))
                        if($parseErrors.Count -or $volumeConsumer.Count -ne 1){throw 'VOLUME_CONSUMER_AST_NOT_UNIQUE'}
                        $candidate=[pscustomobject]@{RunId=$fixture.RunId;ScopeId=$fixture.ScopeId;Volumes=@($fixture.VolumeCustody)}
                        $veto=$false
                        try{& $module {param($Scope,$Custody,$Provider,$Body);. $Body} $scope $candidate $provider ([scriptblock]::Create($volumeConsumer[0].Extent.Text))}catch{$veto=$true}
                        Check ($veto -eq ($case -cnotin @('primary-probe','history'))) "$provider actual pre-Remove volume envelope $case"
                    }
                }finally{Remove-Module $module -Force}
            }
        }
    }finally{Remove-CmsInspectionFixtureTempRoot -Path $testRoot -TempBase ([IO.Path]::GetTempPath()) -Prefix 'cms-custody-fixture-'}
}
$sandbox=Join-Path ([IO.Path]::GetTempPath()) ('cms-acceptance-fixture-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $sandbox
try {
    Invoke-CmsInspectionFixtureCleanupChecks -RepositoryRoot $repo
    Invoke-CmsInspectionAcceptanceCustodyChecks -RepositoryRoot $repo
    $valid=Join-Path $sandbox ('sql-lab-cms-inspection-'+[guid]::NewGuid().ToString('N'))
    Check ((Assert-CmsInspectionAcceptanceLayout $valid $repo) -ceq $valid) 'Fresh full-GUID external root'
    foreach($bad in @('relative','sql-lab-cms-inspection-short',(Join-Path $sandbox ('sql-lab-port-preview-'+[guid]::NewGuid().ToString('N'))),(Join-Path $repo ('sql-lab-cms-inspection-'+[guid]::NewGuid().ToString('N'))))){
        $thrown=$false;try{Assert-CmsInspectionAcceptanceLayout $bad $repo|Out-Null}catch{$thrown=$true};Check $thrown 'Reject relative, short or repository root'
    }
    $null=New-Item -ItemType Directory -Path $valid
    [IO.File]::WriteAllText((Join-Path $valid sentinel),'unchanged')
    $thrown=$false;try{Assert-CmsInspectionAcceptanceLayout $valid $repo|Out-Null}catch{$thrown=$true};Check ($thrown -and (Get-Content (Join-Path $valid sentinel) -Raw) -ceq 'unchanged') 'Existing root is never adopted'
    $bindings=Get-CmsInspectionAcceptanceFileBinding $valid
    Check ($bindings.Count -eq 1 -and $bindings[0].Bytes -eq 9) 'Actual bounded state-byte binding'
    if($IsWindows){
        $evidenceRepo=Join-Path $sandbox evidence-repo;$outside=Join-Path $sandbox outside-evidence
        $null=New-Item -ItemType Directory -Path $evidenceRepo,$outside
        [IO.File]::WriteAllText((Join-Path $outside sentinel),'unchanged')
        $null=New-Item -ItemType Junction -Path (Join-Path $evidenceRepo .artifacts) -Target $outside
        $pathModule=New-Module -ArgumentList $repo -ScriptBlock {param($Repo);. (Join-Path $Repo Private/ContainerOwnedHostIntegration.ps1);Export-ModuleMember -Function @()}
        $thrown=$false
        try {New-CmsInspectionAcceptanceEvidenceDirectory $pathModule $evidenceRepo|Out-Null}catch{$thrown=$true}finally{Remove-Module $pathModule -Force}
        Check ($thrown -and @(Get-ChildItem $outside -Force).Count -eq 1 -and (Get-Content (Join-Path $outside sentinel) -Raw) -ceq 'unchanged') 'Actual evidence-ancestor reparse veto before writes/runtime'
        Remove-Item -LiteralPath (Join-Path $evidenceRepo .artifacts) -Force
    }
    $script:removeCalls=0
    function Remove-SqlServerLab {
        param($RunId,$StateRoot,[switch]$Force,[bool]$Confirm)
        $script:removeCalls++
        if($RunId -cne $script:expectedRun -or $StateRoot -cne $script:expectedState -or -not $Force -or $Confirm){throw 'WRONG_CLEANUP_AUTHORITY'}
        [pscustomobject]@{Status=$(if($script:case -ceq 'remove-unconfirmed'){'RECOVERY_REQUIRED'}else{'REMOVED'})}
    }
    foreach($provider in @('docker','podman')){
        foreach($case in @('success','unreturned','missing-custody','not-completed','remove-unconfirmed','policy-drift','claim-drift','evidence-drift','evidence-copy-failed','container-receipt-drift','container-intent-drift','volume-receipt-drift','volume-intent-drift','run-not-removed','plan-missing','plan-partial','container-present','container-read-failed','volume-present','volume-read-failed','extra-run')){
            $script:case=$case;$script:removeCalls=0
            $root=Join-Path $sandbox ('sql-lab-cms-inspection-'+[guid]::NewGuid().ToString('N'));$state=Join-Path $root State
            $run=[guid]::NewGuid().ToString('D');$scopeId=[guid]::NewGuid().ToString('D');$script:expectedRun=$run;$script:expectedState=$state
            $null=New-Item -ItemType Directory -Path (Join-Path $state "runs/$run") -Force
            $scope=[pscustomobject]@{DataRoot=$root;StateRoot=$state;ParentOperationId=('f'*32)}
            $evidence=Join-Path $sandbox ('evidence-'+[guid]::NewGuid().ToString('N')+'/evidence');$null=New-Item -ItemType Directory -Path $evidence -Force
            if($case -ceq 'evidence-copy-failed'){[IO.File]::WriteAllText((Join-Path $evidence terminal-run-state.private.json),'unmodified sentinel')}
            foreach($entry in @(@{Path=(Join-Path $root owned-host-policy.json);Field='ParentPolicyHash'},@{Path=(Join-Path $state owned-host-policy.json);Field='StatePolicyHash'},@{Path=(Join-Path $root .sql-server-lab-root.json);Field='MarkerHash'},@{Path=(Join-Path $root Catalog/storage-locations.json);Field='CatalogHash'})){
                $null=New-Item -ItemType Directory -Path (Split-Path $entry.Path) -Force
                [IO.File]::WriteAllText($entry.Path,'synthetic immutable binding')
                $scope|Add-Member $entry.Field (Get-FileHash $entry.Path).Hash
            }
            $intent=[guid]::NewGuid().ToString('D');$directory=Join-Path $state "runs/$run/owned-host-containers"
            $null=New-Item -ItemType Directory -Path $directory -Force
            $receiptPath=Join-Path $directory ($intent+'.created.json');$intentPath=Join-Path $directory ($intent+'.intent.json')
            @{ContainerId=('a'*64);RunId=$run;Provider=$provider}|ConvertTo-Json|Set-Content $receiptPath
            @{ContainerName='own.name'}|ConvertTo-Json|Set-Content $intentPath
            $volumeDirectory=Join-Path $state owned-host-volumes;$null=New-Item -ItemType Directory $volumeDirectory
            $volumeReceipt=Join-Path $volumeDirectory ($provider+'-own.volume.created.json');$volumeIntent=Join-Path $volumeDirectory ($provider+'-own.volume.intent.json')
            [IO.File]::WriteAllText($volumeReceipt,'synthetic volume receipt');[IO.File]::WriteAllText($volumeIntent,'synthetic volume intent')
            $custody=[pscustomobject]@{RunId=$run;ScopeId=$scopeId;IntentId=$intent;ContainerId=('a'*64);ContainerName='own.name';ContainerReceiptHash=(Get-FileHash $receiptPath).Hash;IntentHash=(Get-FileHash $intentPath).Hash;
                Volumes=@([pscustomobject]@{Name='own.volume';ReceiptHash=(Get-FileHash $volumeReceipt).Hash;IntentHash=(Get-FileHash $volumeIntent).Hash})}
            $drift=@{'container-receipt-drift'=$receiptPath;'container-intent-drift'=$intentPath;'volume-receipt-drift'=$volumeReceipt;'volume-intent-drift'=$volumeIntent}
            if($drift.ContainsKey($case)){[IO.File]::AppendAllText($drift[$case],'drift')}
            if($case -ceq 'claim-drift'){[IO.File]::AppendAllText((Join-Path $root .sql-server-lab-root.json),'drift')}
            if($case -ceq 'extra-run'){$null=New-Item -ItemType Directory -Path (Join-Path $state 'runs/foreign')}
            @{state='REMOVED';scopeId=$scopeId}|ConvertTo-Json|Set-Content (Join-Path $state "runs/$run/run-state.json")
            if($case -cne 'plan-missing'){@{runId=$run;scopeId=$scopeId;status=$(if($case -ceq 'plan-partial'){'PARTIAL'}else{'COMPLETED'});steps=@(@{state='COMPLETED'})}|ConvertTo-Json -Depth 5|Set-Content (Join-Path $state "runs/$run/cleanup-plan.json")}
            $m=New-Module -ArgumentList $scope,$case,$run,$scopeId -ScriptBlock {
                param($Scope,$Case,$Run,$ScopeId)
                function Get-LabOwnedHostPolicy {param($StateRoot,[switch]$Required);[pscustomobject]@{ParentOperationId=$(if($Case -ceq 'policy-drift'){'different'}else{$Scope.ParentOperationId})}}
                function Get-LabOwnedHostRunPolicy {param($StateRoot,$RunId);Get-LabOwnedHostPolicy -StateRoot $StateRoot -Required}
                function Read-LabOwnedHostRecord {param($Path);Get-Content -LiteralPath $Path -Raw|ConvertFrom-Json}
                function Assert-LabOwnedHostContainerEffect {}
                function Get-LabOwnedHostVolumeReceipt {param($StateRoot,$Provider,$VolumeName);[pscustomobject]@{Receipt=[pscustomobject]@{RunId=$Run;ScopeId=$ScopeId;Provider=$Provider;VolumeName=$VolumeName};Intent=[pscustomobject]@{};Observation=[pscustomobject]@{}}}
                function Get-LabRunState {param($RunId,$StateRoot);[pscustomobject]@{scopeId=$ScopeId;state=$(if($Case -ceq 'run-not-removed'){'RUNNING'}else{'REMOVED'})}}
                function Assert-LabOwnedHostPath {param($Path);if($Case -ceq 'evidence-drift' -and $Path.EndsWith('evidence')){throw 'OWNED_HOST_REPARSE_PATH'};[IO.Path]::GetFullPath($Path)}
                function Invoke-LabOwnedHostPinnedCommand {
                    param($StateRoot,$Provider,$Arguments)
                    $kind=if($Arguments[0] -ceq 'ps'){'container'}else{'volume'}
                    $expected=if($kind -ceq 'container'){'id='+('a'*64)}else{'name=^own\.volume$'}
                    if($Arguments -cnotcontains $expected){throw 'FILTER_NOT_EXACT'}
                    [pscustomobject]@{ExitCode=$(if($Case -ceq ($kind+'-read-failed')){1}else{0});Stdout=$(if($Case -ceq ($kind+'-present')){'present'}else{''})}
                }
                Export-ModuleMember -Function @()
            }
            $result=$null;$thrown=$false
            try{$result=Remove-CmsInspectionAcceptanceScope $m $scope $(if($case -ceq 'missing-custody'){$null}else{$custody}) $provider ($case -ceq 'unreturned') ($case -cne 'not-completed') $evidence}catch{$thrown=$true}
            finally{Remove-Module $m -Force}
            $exists=Test-Path -LiteralPath $root
            Check ($(if($case -ceq 'success'){-not $thrown -and -not $exists -and $result.Status -ceq 'CLEANED'}else{$exists -and ($thrown -or -not $result.RootRemoved)})) "$provider ${case}: exact finalizer deletion veto/closure"
            if($case -cin @('unreturned','missing-custody')){Check ($script:removeCalls -eq 0) 'Unknown/unreturned creation has zero cleanup calls'}
            if($case -cin @('policy-drift','claim-drift','evidence-drift') -or $drift.ContainsKey($case)){Check ($script:removeCalls -eq 0) 'Claim/creation receipt drift vetoes before PublicRemove'}
            if($case -ceq 'evidence-copy-failed'){Check ((Get-Content (Join-Path $evidence terminal-run-state.private.json) -Raw) -ceq 'unmodified sentinel') 'Failed terminal copy retains root and never overwrites existing evidence'}
            if($case -ceq 'success'){
                Check ($result.TerminalEvidence.Count -eq 2 -and @($result.TerminalEvidence|Where-Object {$path=Join-Path $evidence $_.RelativeEvidencePath;(Get-FileHash $path).Hash -cne $_.Sha256 -or (Get-Item $path).Length -ne $_.Bytes}).Count -eq 0) 'Both actual terminal JSON records survive parent deletion byte-exact'
            }
        }
    }
    $redirects=@('DOCKER_HOST','DOCKER_CONTEXT','CONTAINER_HOST','CONTAINER_CONNECTION','CONTAINER_SSHKEY','PODMAN_CONNECTIONS_CONF','PODMAN_SSHKEY')
    foreach($file in @('Tests/Common/ConnectionCenterCmsInspectionAcceptance.ps1','Tests/Integration/Invoke-ConnectionCenterCmsInspectionAcceptance.ps1','Tests/Static/Fixtures/ConnectionCenterCmsInspectionAcceptanceChecks.ps1')){
        foreach($path in @($file,$file.Replace('/','\'))){
            $selected=& (Join-Path $repo Tools/Get-CiTestSelection.ps1) -ChangedPath @($path)
            Check ('Invoke-ConnectionCenterCmsChecks.ps1' -in $selected.StaticChecks) ('Isolated CMS acceptance path selects its actual fixture: '+$path)
        }
    }
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo Tests/Common/ConnectionCenterCmsInspectionAcceptance.ps1),[ref]$tokens,[ref]$errors)
    $sql=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Invoke-CmsInspectionAcceptanceSql'},$true))[0]
    $bodies=@($sql.FindAll({param($n)$n -is [Management.Automation.Language.ScriptBlockAst] -and $n.Parent -is [Management.Automation.Language.ScriptBlockExpressionAst] -and $n.Extent.Text.Contains('$selection=Get-LabCmsInspectionSelection')},$true))
    if($errors.Count -or $bodies.Count -ne 1){throw 'CMS_ACCEPTANCE_SQL_BODY_NOT_UNIQUE'}
    $bodyText=$bodies[0].Extent.Text;$body=[scriptblock]::Create($bodyText.Substring(1,$bodyText.Length-2))
    $own=[pscustomobject]@{RunId=[guid]::NewGuid().ToString('D');ScopeId=[guid]::NewGuid().ToString('D');Provider='docker';ContainerId=('a'*64)}
    foreach($case in @('cid-drift','provider-drift','run-drift','scope-drift','root-drift','instance-drift','not-running')){
        $selection=[pscustomobject]@{RunId=$own.RunId;Provider='docker';StateRoot=$sandbox;Run=[pscustomobject]@{scopeId=$own.ScopeId;state='RUNNING'};Instance=[pscustomobject]@{id='primary';containerId=('a'*64)}}
        switch($case){
            cid-drift {$selection.Instance.containerId='b'*64}
            provider-drift {$selection.Provider='podman'}
            run-drift {$selection.RunId=[guid]::NewGuid().ToString('D')}
            scope-drift {$selection.Run.scopeId=[guid]::NewGuid().ToString('D')}
            root-drift {$selection.StateRoot=Join-Path $sandbox other}
            instance-drift {$selection.Instance.id='secondary'}
            not-running {$selection.Run.state='STOPPED'}
        }
        $m=New-Module -ArgumentList $selection -ScriptBlock {
            param($Selection)
            $script:sqlSelection=$Selection;$script:effects=0;$script:secretReads=0
            function Get-LabCmsInspectionSelection {param($StateRoot);$script:sqlSelection}
            function Assert-LabOwnedHostContainerEffect {$script:effects++;throw 'UNEXPECTED_EFFECT'}
            function Get-LabSecret {$script:secretReads++;throw 'UNEXPECTED_SECRET'}
            Export-ModuleMember -Function @()
        }
        $code=$null
        try{& $m $body ([pscustomobject]@{StateRoot=$sandbox}) $own $true}catch{$code=$_.Exception.Message}
        try{Check ($code -ceq 'CMS_ACCEPTANCE_SQL_SCOPE' -and (& $m {$script:effects}) -eq 0 -and (& $m {$script:secretReads}) -eq 0) ('Actual SQL Arrange body veto before effect/secret: '+$case)}finally{Remove-Module $m -Force}
    }
    $saved=@{};foreach($name in $redirects){$saved[$name]=[Environment]::GetEnvironmentVariable($name);[Environment]::SetEnvironmentVariable($name,$null)}
    try{
        foreach($provider in @('docker','podman')){
            foreach($case in @('same-route','endpoint-drift','identity-drift','engine-drift','tool-drift','native-failed','environment-override')){
                $m=New-Module -ArgumentList $provider,$case,$sandbox -ScriptBlock {
                    param($Provider,$Case,$Sandbox)
                    $script:routeProvider=$Provider;$script:routeCase=$Case
                    $script:routePin=[pscustomobject]@{Provider=$Provider;Invocation=(Join-Path $Sandbox ($Provider+'.exe'));Endpoint=$(if($Provider -ceq 'docker'){'npipe:////./pipe/synthetic'}else{'ssh://synthetic@127.0.0.1:2222/run/podman.sock'});IdentityPath=(Join-Path $Sandbox synthetic.key);IdentitySha256='synthetic-hash'}
                    $script:routeInfo=[pscustomobject]@{ID='synthetic-engine';Host=[pscustomobject]@{Hostname='synthetic-host'};Store=[pscustomobject]@{GraphRoot='/synthetic'};Version=[pscustomobject]@{Version='synthetic-version'}}
                    function Get-LabOwnedHostPolicy {param($StateRoot,[switch]$Required);[pscustomobject]@{RuntimePins=@($script:routePin)}}
                    function Get-LabHostToolInvocation {param($Name);if($script:routeCase -ceq 'tool-drift'){'wrong-tool'}else{$script:routePin.Invocation}}
                    function Get-FileHash {param($LiteralPath);[pscustomobject]@{Hash=$(if($script:routeCase -ceq 'identity-drift'){'drift'}else{'synthetic-hash'})}}
                    function Invoke-LabOwnedHostNativeProcess {
                        param($StartInfo,$TimeoutSeconds,$MaximumBytes)
                        if($StartInfo.UseShellExecute -or -not $StartInfo.CreateNoWindow -or $TimeoutSeconds -ne 10 -or $MaximumBytes -ne 1048576){throw 'SYNTHETIC_ROUTE_TRANSPORT'}
                        $endpoint=if($script:routeCase -ceq 'endpoint-drift'){'wrong-endpoint'}else{$script:routePin.Endpoint}
                        $value=if($StartInfo.ArgumentList[0] -ceq 'context'){@([pscustomobject]@{Endpoints=[pscustomobject]@{docker=[pscustomobject]@{Host=$endpoint}}})}
                            elseif($StartInfo.ArgumentList[0] -ceq 'system'){@([pscustomobject]@{Default=$true;URI=$endpoint;Identity=$script:routePin.IdentityPath})}
                            else{$script:routeInfo}
                        [pscustomobject]@{ExitCode=$(if($script:routeCase -ceq 'native-failed'){1}else{0});Stdout=(ConvertTo-Json -InputObject $value -Depth 8 -Compress)}
                    }
                    function Invoke-LabOwnedHostPinnedCommand {
                        param($StateRoot,$Provider,$Arguments,$TimeoutSeconds)
                        $value=$script:routeInfo|ConvertTo-Json -Depth 8|ConvertFrom-Json
                        if($script:routeCase -ceq 'engine-drift'){$value.ID='different';$value.Host.Hostname='different'}
                        [pscustomobject]@{ExitCode=0;Stdout=($value|ConvertTo-Json -Depth 8 -Compress)}
                    }
                    Export-ModuleMember -Function @()
                }
                if($case -ceq 'environment-override'){[Environment]::SetEnvironmentVariable('DOCKER_HOST','synthetic-override')}
                $thrown=$false
                try{Assert-CmsInspectionAcceptanceRoute $m ([pscustomobject]@{StateRoot=$sandbox}) $provider}catch{$thrown=$true}
                finally{[Environment]::SetEnvironmentVariable('DOCKER_HOST',$null);Remove-Module $m -Force}
                Check ($thrown -eq ($case -cne 'same-route' -and -not ($provider -ceq 'docker' -and $case -ceq 'identity-drift'))) ($provider+' actual route boundary '+$case)
            }
        }
    }finally{foreach($name in $redirects){[Environment]::SetEnvironmentVariable($name,$saved[$name])}}
    $candidate=[pscustomobject]@{ContractVersion='SqlServerLab.CmsInspection/1.0';Status='OBSERVED';Code='CMS_INSPECTION_OBSERVED';RunId=[guid]::NewGuid().ToString('D');InstanceId='primary';Provider='docker';SelectionKey=('a'*64);ObservedAt=[datetime]::UtcNow.ToString('o');SqlMajor=17;ManagedGroupCount=2L;ManagedServerCount=1L;Notice='fixed fixture notice'}
    $custody=[pscustomobject]@{RunId=$candidate.RunId}
    Assert-CmsInspectionAcceptanceResult $candidate $custody docker ('a'*64) OBSERVED CMS_INSPECTION_OBSERVED
    Check $true 'Actual observed DTO accepts fixed managed counts'
    foreach($case in @('extra-field','wrong-run','wrong-provider','wrong-key','negative-group','wrong-major','null-server','wrong-code','string-count')){
        $bad=$candidate|ConvertTo-Json|ConvertFrom-Json
        switch($case){
            extra-field {$bad|Add-Member RawSecret synthetic}
            wrong-run {$bad.RunId=[guid]::NewGuid().ToString('D')}
            wrong-provider {$bad.Provider='podman'}
            wrong-key {$bad.SelectionKey='b'*64}
            negative-group {$bad.ManagedGroupCount=-1}
            wrong-major {$bad.SqlMajor=16}
            null-server {$bad.ManagedServerCount=$null}
            wrong-code {$bad.Code='CMS_INSPECTION_UNKNOWN'}
            string-count {$bad.ManagedGroupCount='2'}
        }
        $thrown=$false;try{Assert-CmsInspectionAcceptanceResult $bad $custody docker ('a'*64) OBSERVED CMS_INSPECTION_OBSERVED}catch{$thrown=$true}
        Check $thrown ('Actual DTO acceptance veto: '+$case)
    }
    $candidate.Status='UNKNOWN';$candidate.Code='CMS_INSPECTION_SQL_RESULT_INVALID';$candidate.SqlMajor=$null;$candidate.ManagedGroupCount=$null;$candidate.ManagedServerCount=$null
    Assert-CmsInspectionAcceptanceResult $candidate $custody docker ('a'*64) UNKNOWN CMS_INSPECTION_SQL_RESULT_INVALID
    Check $true 'Actual UNKNOWN DTO requires null counts'
    $candidate.ManagedGroupCount=0L
    $thrown=$false;try{Assert-CmsInspectionAcceptanceResult $candidate $custody docker ('a'*64) UNKNOWN CMS_INSPECTION_SQL_RESULT_INVALID}catch{$thrown=$true}
    Check $thrown 'Unknown zero is not a confirmed observation'
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo Tests/Integration/Invoke-ConnectionCenterCmsInspectionAcceptance.ps1),[ref]$tokens,[ref]$errors)
    Check ($errors.Count -eq 0) 'Actual native CMS runner parses'
    [pscustomobject]@{Passed=$checks;RuntimeCalls=0;NativeAcceptance='NOT_EXECUTED'}|ConvertTo-Json -Compress
}finally{
    Remove-CmsInspectionFixtureTempRoot -Path $sandbox -TempBase ([IO.Path]::GetTempPath()) -Prefix 'cms-acceptance-fixture-'
}
