#Requires -Version 7.2
# Actual test helpers and finalizer, with isolated synthetic boundary functions.
$ErrorActionPreference='Stop'
$repo=Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
. (Join-Path $repo Tests/Common/ContainerPortPreviewAcceptance.ps1)
$checks=0
function Check($value,$name){if(-not $value){throw ('PORT_ACCEPTANCE_CHECK_FAILED: '+$name)};$script:checks++;Write-Host ('PASS: '+$name)}
$sandbox=Join-Path ([IO.Path]::GetTempPath()) ('port-acceptance-fixture-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $sandbox
try {
    $valid=Join-Path $sandbox ('sql-lab-port-preview-'+[guid]::NewGuid().ToString('N'))
    Check ((Assert-PortPreviewAcceptanceLayout $valid $repo) -ceq $valid) 'Fresh full-GUID external root'
    foreach($bad in @('relative','sql-lab-port-preview-short',(Join-Path $repo ('sql-lab-port-preview-'+[guid]::NewGuid().ToString('N'))))){
        $thrown=$false;try{Assert-PortPreviewAcceptanceLayout $bad $repo|Out-Null}catch{$thrown=$true};Check $thrown 'Reject relative, short or repository root'
    }
    $null=New-Item -ItemType Directory -Path $valid
    [IO.File]::WriteAllText((Join-Path $valid sentinel),'unchanged')
    $thrown=$false;try{Assert-PortPreviewAcceptanceLayout $valid $repo|Out-Null}catch{$thrown=$true};Check ($thrown -and (Get-Content (Join-Path $valid sentinel) -Raw) -ceq 'unchanged') 'Existing root is never adopted'
    $bindings=Get-PortPreviewAcceptanceFileBinding $valid
    Check ($bindings.Count -eq 1 -and $bindings[0].Bytes -eq 9) 'Actual bounded state-byte binding'
    if($IsWindows){
        $evidenceRepo=Join-Path $sandbox evidence-repo;$outside=Join-Path $sandbox outside-evidence
        $null=New-Item -ItemType Directory -Path $evidenceRepo,$outside
        [IO.File]::WriteAllText((Join-Path $outside sentinel),'unchanged')
        $null=New-Item -ItemType Junction -Path (Join-Path $evidenceRepo .artifacts) -Target $outside
        $pathModule=New-Module -ArgumentList $repo -ScriptBlock {param($Repo);. (Join-Path $Repo Private/ContainerOwnedHostIntegration.ps1);Export-ModuleMember -Function @()}
        $thrown=$false
        try {New-PortPreviewAcceptanceEvidenceDirectory $pathModule $evidenceRepo|Out-Null}catch{$thrown=$true}finally{Remove-Module $pathModule -Force}
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
            $root=Join-Path $sandbox ('sql-lab-port-preview-'+[guid]::NewGuid().ToString('N'));$state=Join-Path $root State
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
                function Get-LabOwnedHostVolumeReceipt {param($StateRoot,$Provider,$VolumeName);[pscustomobject]@{RunId=$Run;Provider=$Provider;VolumeName=$VolumeName}}
                function Get-LabRunState {param($RunId,$StateRoot);[pscustomobject]@{scopeId=$ScopeId;state=$(if($Case -ceq 'run-not-removed'){'RUNNING'}else{'REMOVED'})}}
                function Assert-LabOwnedHostPath {param($Path);if($Case -ceq 'evidence-drift' -and $Path.EndsWith('evidence')){throw 'OWNED_HOST_REPARSE_PATH'};[IO.Path]::GetFullPath($Path)}
                function Invoke-LabOwnedHostPinnedCommand {
                    param($StateRoot,$Provider,$Arguments)
                    $kind=if($Arguments[0] -ceq 'ps'){'container'}else{'volume'}
                    $expected=if($kind -ceq 'container'){'name=^own\.name$'}else{'name=^own\.volume$'}
                    if($Arguments -cnotcontains $expected){throw 'FILTER_NOT_EXACT'}
                    [pscustomobject]@{ExitCode=$(if($Case -ceq ($kind+'-read-failed')){1}else{0});Stdout=$(if($Case -ceq ($kind+'-present')){'present'}else{''})}
                }
                Export-ModuleMember -Function @()
            }
            $result=$null;$thrown=$false
            try{$result=Remove-PortPreviewAcceptanceScope $m $scope $(if($case -ceq 'missing-custody'){$null}else{$custody}) $provider ($case -ceq 'unreturned') ($case -cne 'not-completed') $evidence}catch{$thrown=$true}
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
    # Actual public core + console menu/dialog + HTTP server AST. Only the
    # provider observation and owned-origin boundary are synthetic here;
    # genuine native custody remains a separate, not-executed acceptance.
    $actual=Import-Module (Join-Path $repo SqlServerLab.psd1) -Force -PassThru
    $oldData=$env:SQL_SERVER_LAB_DATA_ROOT
    try {
        $data=Join-Path $sandbox orchestration;$state=Join-Path $data State
        $env:SQL_SERVER_LAB_DATA_ROOT=$data
        & $actual {
            param($Root,$State)
            function script:Write-PortFixtureJson($Path,$Value){$null=New-Item -ItemType Directory -Path (Split-Path $Path) -Force;$Value|ConvertTo-Json -Depth 60|Set-Content -LiteralPath $Path}
            if($IsWindows){
                $tools=Join-Path (Split-Path $Root) native-tools;$null=New-Item -ItemType Directory $tools
                foreach($provider in @('docker','podman')){[IO.File]::WriteAllText((Join-Path $tools ($provider+'.exe')),'synthetic not executable')}
                $identity=Join-Path $tools synthetic.key;[IO.File]::WriteAllText($identity,'synthetic no credential')
                $pins=@([pscustomobject]@{Provider='docker';Invocation=(Join-Path $tools docker.exe);Endpoint='npipe:////./pipe/synthetic';IdentityPath='';IdentitySha256=''},
                    [pscustomobject]@{Provider='podman';Invocation=(Join-Path $tools podman.exe);Endpoint='ssh://synthetic@127.0.0.1:2222/run/podman/podman.sock';IdentityPath=$identity;IdentitySha256=(Get-FileHash $identity).Hash.ToLowerInvariant()})
                $parent=Initialize-LabOwnedHostPolicy -StateRoot $Root -RuntimePins $pins -ParentOperationId ('f'*32)
                $script:childPolicy=Initialize-LabOwnedHostPolicy -StateRoot $State -RuntimePins $pins -ParentOperationId $parent.ParentOperationId
                $script:fixtureTools=$tools
                function script:Invoke-LabOwnedHostNativeProcess {
                    param($StartInfo,[int]$TimeoutSeconds,[int]$MaximumBytes)
                    $global:portAcceptanceSyntheticReads++
                    $arguments=@($StartInfo.ArgumentList)
                    $output=if($arguments -ccontains 'inspect'){$global:portAcceptanceSyntheticInspect|ConvertTo-Json -Depth 60 -Compress}else{''}
                    [pscustomobject]@{ExitCode=0;Stdout=$output;Stderr='';Output=$output}
                }
                function script:Get-LabHostToolInvocation {param($Name);Join-Path $script:fixtureTools ($Name+'.exe')}
            }
            $controller=[guid]::NewGuid().ToString('D');$location=[guid]::NewGuid().ToString('D')
            Write-PortFixtureJson (Join-Path $Root '.sql-server-lab-root.json') @{ContractVersion='SqlServerLab.DataRoot/2.0';ManagedBy='SQL_Server_Lab';ControllerId=$controller;VolumeId='SYNTHETIC';DataRoot=$Root}
            Write-PortFixtureJson (Join-Path $Root 'Catalog/storage-locations.json') @{ContractVersion='SqlServerLab.Storage/2.0';ControllerId=$controller;LabDataLocations=@(@{LocationId=$location;ControllerId=$controller;LabDataRoot=$Root;VolumeId='SYNTHETIC'})}
            $script:fixtureRoot=$Root;$script:fixtureState=$State
            function script:Get-LabDataRootDefault {$script:fixtureRoot}
            if(-not $IsWindows){function script:Get-LabOwnedHostRunPolicy {param($RunId,$StateRoot);[pscustomobject]@{StateRoot=$script:fixtureState}}}
            function script:Test-LabAutomatedTestEnvironmentRun {$false}
            function script:Get-LabConnectionCenterCmsConfiguration {$null}
            $script:tool=Join-Path $Root synthetic-inspect.ps1
            Set-Content $script:tool '$global:portAcceptanceSyntheticReads++;$global:portAcceptanceSyntheticInspect|ConvertTo-Json -Depth 60'
            if(-not $IsWindows){function script:Get-LabHostToolInvocation {$script:tool}}
        } $data $state
        foreach($provider in @('docker','podman')){
            $run=& $actual {
                param($Root,$State,$Provider)
                $instance=[pscustomobject]@{id='primary';provider=$Provider;version='2025';profile='compact';autostart='manual';drives=@();databases=@();software=@()}
                $desired=New-LabDesiredStateSnapshot -ResolvedLab ([pscustomobject]@{name='Synthetic native acceptance orchestration';instances=@($instance)}) -ProvisioningMode adhoc -PersistentData $false
                $run=New-LabRunState -StateRoot $State -Metadata @{desiredState=$desired;persistentData=$false} -ProviderSubRuns @([pscustomobject]@{provider=$Provider;instanceIds=@('primary')})
                $path=Join-Path $run.RunDir run-state.json;$stored=Get-Content $path -Raw|ConvertFrom-Json -Depth 60;$stored.state='RUNNING';$stored.providerSubRuns[0].state='RUNNING';Write-PortFixtureJson $path $stored
                Write-PortFixtureJson (Join-Path $run.RunDir connection-info.json) @{instances=@(@{id='primary';provider=$Provider;containerId=('a'*64);containerName='synthetic';port=1})}
                $run
            } $data $state $provider
            $global:portAcceptanceSyntheticReads=0
            $global:portAcceptanceSyntheticInspect=[pscustomobject]@{Id=('a'*64);Name='/synthetic';Image=('sha256:'+('b'*64));State=[pscustomobject]@{Running=$true};
                Config=[pscustomobject]@{Labels=[pscustomobject]@{'sql-server-lab.run-id'=$run.RunId;'sql-server-lab.scope-id'=$run.ScopeId;'sql-server-lab.instance-id'='primary'};Env=@('MSSQL_SA_PASSWORD=SYNTHETIC_PRIVATE')};
                HostConfig=[pscustomobject]@{NanoCpus=1000000000L;Memory=2560MB;NetworkMode='synthetic';RestartPolicy=[pscustomobject]@{Name='no'};PortBindings=[pscustomobject]@{'1433/tcp'=@([pscustomobject]@{HostIp='127.0.0.1';HostPort='14333'})}};
                NetworkSettings=[pscustomobject]@{Ports=[pscustomobject]@{'1433/tcp'=@([pscustomobject]@{HostIp='127.0.0.1';HostPort='14333'})};Networks=[pscustomobject]@{synthetic=[pscustomobject]@{Aliases=@();IPAMConfig=$null}}};Mounts=@()}
            if($IsWindows){
                & $actual {
                    param($State,$Run,$Provider)
                    $intent=New-LabOwnedHostContainerIntent -StateRoot $State -RunId $Run.RunId -ScopeId $Run.ScopeId -InstanceId primary -Provider $Provider -ContainerName synthetic
                    foreach($entry in @{'sql-server-lab.owned-host-policy-id'=$intent.PolicyId;'sql-server-lab.owned-host-root-scope-id'=$intent.RootScopeId;'sql-server-lab.owned-host-intent-id'=$intent.IntentId}.GetEnumerator()){
                        $global:portAcceptanceSyntheticInspect.Config.Labels|Add-Member $entry.Key $entry.Value
                    }
                    $null=Register-LabOwnedHostContainer -StateRoot $State -Intent $intent -ContainerIdOrName ('a'*64)
                } $state $run $provider
            }
            $scope=[pscustomobject]@{DataRoot=$data;StateRoot=$state}
            $bindings=Get-PortPreviewAcceptanceFileBinding $data
            $original=& $actual {@(${function:Get-SqlServerLabReconcilePlan}.ToString(),${function:Invoke-LabOwnedHostNativeProcess}.ToString(),${function:Get-LabSecret}.ToString()) -join '|'}
            $outcome=Invoke-PortPreviewAcceptanceObservations $actual $scope $run.RunId $provider $repo
            Check ($outcome.PublicPreviewCalls -eq 5 -and $outcome.Http -ceq 'ACTUAL_INPROCESS_SERVER_ROUTE_PASSED' -and $outcome.RenderedBrowser -ceq 'NOT_EXECUTED') "$provider actual public/core/menu/HTTP orchestration"
            if($IsWindows){Check ($outcome.PinnedReadCalls -gt $outcome.PublicPreviewCalls) 'Actual pinned ownership reads are retained and counted separately'}
            Check (($bindings|ConvertTo-Json -Depth 5 -Compress) -ceq ((Get-PortPreviewAcceptanceFileBinding $data)|ConvertTo-Json -Depth 5 -Compress)) 'All actual preview routes preserve state bytes'
            Check ($original -ceq (& $actual {@(${function:Get-SqlServerLabReconcilePlan}.ToString(),${function:Invoke-LabOwnedHostNativeProcess}.ToString(),${function:Get-LabSecret}.ToString()) -join '|'})) 'Instrumentation restored on success'
            # Initial context stays readable; core vetoes topology after the
            # transparent instrumentation has been installed.
            $global:portAcceptanceSyntheticInspect.NetworkSettings.Networks|Add-Member other ([pscustomobject]@{})
            $thrown=$false;try{Invoke-PortPreviewAcceptanceObservations $actual $scope $run.RunId $provider $repo|Out-Null}catch{$thrown=$true}
            Check ($thrown -and $original -ceq (& $actual {@(${function:Get-SqlServerLabReconcilePlan}.ToString(),${function:Invoke-LabOwnedHostNativeProcess}.ToString(),${function:Get-LabSecret}.ToString()) -join '|'})) 'Instrumentation restored after actual core failure'
        }
    } finally {$env:SQL_SERVER_LAB_DATA_ROOT=$oldData;Remove-Module $actual -Force;Remove-Variable portAcceptanceSyntheticInspect,portAcceptanceSyntheticReads -Scope Global -ErrorAction SilentlyContinue}
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo Tests/Integration/Invoke-ContainerPortPreviewAcceptance.ps1),[ref]$tokens,[ref]$errors)
    Check ($errors.Count -eq 0) 'Actual owned-only harness parses'
    $text=$ast.Extent.Text
    Check ($text -notmatch 'Initialize-PodmanRuntime|Set-LabGlobal|Register-LabDataRoot|Start-SqlServerLabUi') 'No provider start, default mutation, global registration or listener'
    Check ($text -match '\$unreturnedCreation=\$true' -and $text -match 'Get-PortPreviewAcceptanceCustody' -and $text.IndexOf('$unreturnedCreation=$false', $text.IndexOf('$unreturnedCreation=$true')) -gt $text.IndexOf('$custody=Get-PortPreviewAcceptanceCustody')) 'Returned creation clears only after actual custody boundary'
    [pscustomobject]@{Passed=$checks;RuntimeCalls=0;NativeAcceptance='NOT_EXECUTED'}|ConvertTo-Json -Compress
} finally {
    # Only this fresh synthetic fixture sandbox is removed.
    if([IO.Path]::GetFullPath($sandbox).StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase)){Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction Stop}
}
