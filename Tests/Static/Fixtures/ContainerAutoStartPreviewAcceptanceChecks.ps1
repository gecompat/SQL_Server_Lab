#Requires -Version 7.2
[CmdletBinding()]param([switch]$ConsoleOnly)
$ErrorActionPreference='Stop'
$repositoryRoot=Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
$root=Join-Path ([IO.Path]::GetTempPath()) ('SqlServerLab-AutoStartPreview-'+[guid]::NewGuid().ToString('N'))
$module=Import-Module (Join-Path $repositoryRoot SqlServerLab.psd1) -Force -PassThru
try {
    & $module {
        param($Root,$Repository,$Module,$ConsoleOnly)
        . (Join-Path $Repository 'Tests/Common/ContainerPortPreviewAcceptance.ps1')
        . (Join-Path $Repository 'Tests/Common/ContainerAutoStartPreviewAcceptance.ps1')
        $script:checks=0
        function Assert-AutoStart($condition,$name) {
            if (-not $condition) { throw ('AUTOSTART_PREVIEW_CHECK_FAILED: '+$name) }
            $script:checks++; Write-Host ('PASS: '+$name)
        }
        # Execute the actual entry's first three try statements. Only the exact
        # constructor expression is replaced with a synthetic mutex leaf; no
        # global/real mutex, provider initialization or native process can run.
        $tokens=$null;$errors=$null
        $entry=[Management.Automation.Language.Parser]::ParseFile((Join-Path $Repository 'Tests/Integration/Invoke-ContainerAutoStartPreviewAcceptance.ps1'),[ref]$tokens,[ref]$errors)
        $tries=@($entry.FindAll({param($n)$n -is [Management.Automation.Language.TryStatementAst]},$false))
        $statements=@($tries[0].Body.Statements)
        Assert-AutoStart (@($errors).Count -eq 0 -and $statements[0] -is [Management.Automation.Language.AssignmentStatementAst] -and $statements[0].Left.Extent.Text -ceq '$mutex' -and
            $statements[1] -is [Management.Automation.Language.AssignmentStatementAst] -and $statements[1].Left.Extent.Text -ceq '$locked' -and $statements[2] -is [Management.Automation.Language.IfStatementAst]) 'Actual entry mutex statements execute directly, not as a bare scriptblock'
        $constructor=$statements[0].Right.Extent.Text
        if($constructor -notmatch '^\[Threading\.Mutex\]::new\('){throw 'AUTOSTART_FIXTURE_MUTEX_CONSTRUCTOR_CHANGED'}
        $excerpt=($statements[0..2].Extent.Text -join "`n").Replace($constructor,'(New-SyntheticAcceptanceMutex)')
        foreach($expected in @($true,$false)){
            $proof=& {
                param($Text,$Expected)
                $script:entryWaitCalls=0;$script:entryFactories=0;$script:entryExpected=$Expected
                function New-SyntheticAcceptanceMutex {
                    $script:entryFactories++
                    $value=[pscustomobject]@{Expected=$script:entryExpected}
                    $value|Add-Member -MemberType ScriptMethod -Name WaitOne -Value {param($Timeout)$script:entryWaitCalls++;if($Timeout.TotalMinutes -ne 10){throw 'WRONG_SYNTHETIC_TIMEOUT'};return $this.Expected}
                    return $value
                }
                $mutex=$null;$locked=$false;$failure=$null;$output=@()
                try{$output=@(. ([scriptblock]::Create($Text)))}catch{$failure=$_.Exception.Message}
                [pscustomobject]@{Factory=$script:entryFactories;Wait=$script:entryWaitCalls;Locked=$locked;Output=$output;Failure=$failure}
            } $excerpt $expected
            Assert-AutoStart ($proof.Factory -eq 1 -and $proof.Wait -eq 1 -and $proof.Locked -eq $expected -and $proof.Output.Count -eq 0 -and
                (($expected -and $null -eq $proof.Failure) -or (-not $expected -and $proof.Failure -ceq 'PORT_ACCEPTANCE_MUTEX_TIMEOUT'))) 'Actual entry excerpt calls WaitOne and enforces lock/veto with no emitted scriptblock'
        }
        function Write-AutoStartJson($path,$value) {
            $null=New-Item -ItemType Directory (Split-Path $path) -Force
            $value|ConvertTo-Json -Depth 60|Set-Content -LiteralPath $path -Encoding utf8
        }
        function Get-AutoStartFiles {
            @((Get-ChildItem $Root -Recurse -File|Sort-Object FullName|ForEach-Object {$_.FullName+':'+(Get-FileHash $_.FullName).Hash})) -join '|'
        }
        $dataRoot=Join-Path $Root data; $state=Join-Path $dataRoot State
        $controller=[guid]::NewGuid().ToString('D');$location=[guid]::NewGuid().ToString('D')
        Write-AutoStartJson (Join-Path $dataRoot '.sql-server-lab-root.json') @{ContractVersion='SqlServerLab.DataRoot/2.0';ManagedBy='SQL_Server_Lab';ControllerId=$controller;VolumeId='PRIVATE_VOLUME_CANARY';DataRoot=$dataRoot}
        $catalogPath=Join-Path $dataRoot 'Catalog/storage-locations.json'
        $catalog=@{ContractVersion='SqlServerLab.Storage/2.0';ControllerId=$controller;LabDataLocations=@(@{LocationId=$location;ControllerId=$controller;LabDataRoot=$dataRoot;VolumeId='PRIVATE_VOLUME_CANARY'})}
        Write-AutoStartJson $catalogPath $catalog
        $tool=Join-Path $Root inspect-spy.ps1
        # The actual context executes this synthetic tool for its sole inspect.
        # No Docker/Podman process, SQL, listener or state mutation is possible.
        Set-Content $tool '$global:autoStartInspectCalls++; if ($global:autoStartToolFail) { throw "PRIVATE_RUNTIME_ERROR_CANARY" }; if ($args.Count -ne 2 -or $args[0] -cne "inspect" -or $args[1] -cne ("a"*64)) { throw "WRONG_INSPECT_ARGV" }; $global:autoStartInspect | ConvertTo-Json -Depth 60' -Encoding utf8
        function Get-LabHostToolInvocation { return $tool }
        function Test-LabAutomatedTestEnvironmentRun { return $script:protected }
        function Get-LabConnectionCenterCmsConfiguration { if($script:cms){return [pscustomobject]@{RunId=$script:currentRun}} }
        function Test-LabEndpointBinding { $script:forbidden++;throw 'FORBIDDEN_ENDPOINT' }
        function Get-LabSecret { $script:forbidden++;throw 'FORBIDDEN_SECRET' }
        function Invoke-SqlQuery { $script:forbidden++;throw 'FORBIDDEN_SQL' }
        function Repair-LabContainerReconcileJournal { $script:forbidden++;throw 'FORBIDDEN_RECOVERY' }
        $journalFactory=${function:New-LabContainerReconcileJournal}
        function New-LabContainerReconcileJournal { $script:forbidden++;throw 'FORBIDDEN_JOURNAL' }
        function Invoke-LabContainerReconcileCommand { $script:forbidden++;throw 'FORBIDDEN_MUTATION' }
        function New-AutoStartInspect($run) {
            [pscustomobject]@{
                Id=('a'*64);Name='/PRIVATE_NAME_CANARY';Image=('sha256:'+('b'*64))
                State=[pscustomobject]@{Running=$true}
                Config=[pscustomobject]@{Labels=[pscustomobject]@{'sql-server-lab.run-id'=$run.RunId;'sql-server-lab.scope-id'=$run.ScopeId;'sql-server-lab.instance-id'='primary';'sql-server-lab.autostart'='off'};Env=@('MSSQL_SA_PASSWORD=PRIVATE_SECRET_CANARY')}
                HostConfig=[pscustomobject]@{NanoCpus=2000000000L;Memory=2048MB;NetworkMode='PRIVATE_NETWORK_CANARY';RestartPolicy=[pscustomobject]@{Name='no'};PortBindings=[pscustomobject]@{'1433/tcp'=@([pscustomobject]@{HostIp='127.0.0.1';HostPort='14333'})}}
                NetworkSettings=[pscustomobject]@{Ports=[pscustomobject]@{'1433/tcp'=@([pscustomobject]@{HostIp='127.0.0.1';HostPort='14333'})};Networks=[pscustomobject]@{PRIVATE_NETWORK_CANARY=[pscustomobject]@{Aliases=@();IPAMConfig=$null}}}
                Mounts=@([pscustomobject]@{Type='volume';Name='PRIVATE_MOUNT_CANARY';Source='/PRIVATE_SOURCE_CANARY';Destination='/data';RW=$true})
            }
        }
        function Invoke-AutoStartPlan($run,$autoStart='on') {
            $global:autoStartInspectCalls=0;$script:forbidden=0
            $before=Get-AutoStartFiles
            $plan=Get-SqlServerLabReconcilePlan -RunId $run.RunId -InstanceId primary -ContainerAutoStartPreview -AutoStart $autoStart -StateRoot $state
            Assert-AutoStart ((Get-AutoStartFiles) -ceq $before -and $script:forbidden -eq 0) 'No state write, repair, SQL, listener or mutation boundary'
            $json=$plan|ConvertTo-Json -Depth 30
            Assert-AutoStart ($json -notmatch 'PRIVATE_|14333|15433|HostIp|HostPort|containerId|runtimeId|MSSQL_SA_PASSWORD' -and $json -notmatch [regex]::Escape($Root)) 'Public DTO contains no host port, native ID, network, paths or secret'
            Assert-AutoStart (-not $plan.CanApply -and -not $plan.MutationAllowed -and $plan.Actions.Count -eq 0 -and $plan.Preview.Endpoint -ceq 'NOT_CHECKED') 'Always PLAN_ONLY authority and unprobed endpoint'
            $plan
        }
        if(-not $ConsoleOnly){foreach($provider in @('docker','podman')){
            $instance=[pscustomobject]@{id='primary';provider=$provider;version='2025';profile='standard';autostart='manual';drives=@();databases=@();software=@()}
            $desired=New-LabDesiredStateSnapshot -ResolvedLab ([pscustomobject]@{name='Synthetic SQL autostart acceptance';instances=@($instance)}) -ProvisioningMode adhoc -PersistentData $false
            $run=New-LabRunState -StateRoot $state -Metadata @{desiredState=$desired;persistentData=$false} -ProviderSubRuns @([pscustomobject]@{provider=$provider;instanceIds=@('primary')})
            $runPath=Join-Path $run.RunDir run-state.json
            $stored=Get-Content $runPath -Raw|ConvertFrom-Json -Depth 60
            $stored.state='RUNNING';$stored.providerSubRuns[0].state='RUNNING';Write-AutoStartJson $runPath $stored
            Write-AutoStartJson (Join-Path $run.RunDir connection-info.json) @{instances=@(@{id='primary';provider=$provider;containerId=('a'*64);containerName='PRIVATE_NAME_CANARY';port=1})}
            $script:currentRun=$run.RunId;$script:protected=$false;$script:cms=$false;$script:forbidden=0
            $scope=[pscustomobject]@{DataRoot=$dataRoot;StateRoot=$state}
            $global:autoStartInspect=New-AutoStartInspect $run;$global:autoStartInspectCalls=0
            $evidence=New-PortPreviewAcceptanceEvidenceDirectory -Module $Module -RepositoryRoot $Repository
            $before=Get-AutoStartFiles
            $result=Invoke-AutoStartPreviewAcceptanceObservations -Module $Module -Scope $scope -RunId $run.RunId -Provider $provider -RepositoryRoot $Repository -EvidenceRoot $evidence
            Assert-AutoStart ($result.PublicPreviewCalls -eq 5 -and $global:autoStartInspectCalls -eq 5 -and $script:forbidden -eq 0) 'Five actual public/module/context calls with synthetic native leaf; no extra read/effect'
            Assert-AutoStart ($result.StateBytesEqual -and $result.RepeatObservedContentEqual -and $before -ceq (Get-AutoStartFiles)) 'State and measured restartpolicy contents unchanged through no-op/change/repeat/case requests'
            Assert-AutoStart ($result.PublicObservationEvidence.Count -eq 5 -and $result.DedicatedCli -ceq 'NOT_EXECUTED' -and $result.HostLogin -ceq 'NOT_CHECKED') 'Bounded core proof does not claim UI or host-login acceptance'
            foreach($record in $result.PublicObservationEvidence){
                $path=Join-Path $evidence $record.RelativeEvidencePath;$text=Get-Content $path -Raw
                Assert-AutoStart ((Get-FileHash $path).Hash -ceq $record.Sha256 -and (Get-Item $path).Length -eq $record.Bytes) 'Actual category file byte binding'
                Assert-AutoStart ($text -notmatch 'PRIVATE_|14333|ObservationKey|HostPort|HostIp|StateRoot|containerId|MSSQL_SA_PASSWORD' -and $text -notmatch [regex]::Escape($Root)) 'Only fixed categories/counts; no native identities, policy strings, paths, keys or secrets'
            }
            $global:autoStartInspect.Config.Labels.'sql-server-lab.autostart'=$null;$global:autoStartInspectCalls=0
            $failedEvidence=New-PortPreviewAcceptanceEvidenceDirectory -Module $Module -RepositoryRoot $Repository
            $thrown=$false
            try{$null=Invoke-AutoStartPreviewAcceptanceObservations -Module $Module -Scope $scope -RunId $run.RunId -Provider $provider -RepositoryRoot $Repository -EvidenceRoot $failedEvidence}catch{$thrown=$_.Exception.Message -ceq 'AUTOSTART_ACCEPTANCE_MEASURED_OFF_REQUIRED'}
            $record=Get-Content (Join-Path $failedEvidence autostart-preview-01.private.json) -Raw|ConvertFrom-Json
            Assert-AutoStart ($thrown -and $record.Status -ceq 'BLOCKED' -and $record.Reason -ceq 'AUTOSTART_PREVIEW_POLICY_UNKNOWN' -and $global:autoStartInspectCalls -eq 1 -and $before -ceq (Get-AutoStartFiles)) 'Actual veto category retained before throw with one public call and unchanged state'
            $global:autoStartInspect=New-AutoStartInspect $run
            $good=Get-SqlServerLabReconcilePlan -RunId $run.RunId -InstanceId primary -ContainerAutoStartPreview -AutoStart off -StateRoot $state
            foreach($case in @('Reason','Status','Mode','Authority','MountCount','UnknownReason','MissingMounts','MissingKey','WrongSuccessReason')){
                $bad=$good|ConvertTo-Json -Depth 20|ConvertFrom-Json
                switch($case){
                    Reason {$bad.Reason=@($bad.Reason)}
                    Status {$bad.Status=@($bad.Status)}
                    Mode {$bad.Mode=@($bad.Mode)}
                    Authority {$bad.CanApply=$true}
                    MountCount {$bad.Preview.Mounts.TotalMountCount='PRIVATE_RAW_CANARY'}
                    UnknownReason {$bad.Reason='PRIVATE_RAW_CANARY'}
                    MissingMounts {$bad.Preview.Mounts=$null}
                    MissingKey {$bad.ObservationKey=$null}
                    WrongSuccessReason {$bad.Reason='AUTOSTART_PREVIEW_BINDING_UNAVAILABLE'}
                }
                $fresh=New-PortPreviewAcceptanceEvidenceDirectory -Module $Module -RepositoryRoot $Repository;$beforeCalls=$global:autoStartInspectCalls;$thrown=$false
                try{$null=Write-AutoStartPreviewAcceptanceObservation -Plan $bad -Provider $provider -Ordinal 1 -Scope $scope -RepositoryRoot $Repository -EvidenceRoot $fresh}catch{$thrown=$true}
                Assert-AutoStart ($thrown -and @(Get-ChildItem $fresh).Count -eq 0 -and $beforeCalls -eq $global:autoStartInspectCalls) 'Malformed/raw/authority DTO veto before write and no additional public/context call'
            }
            $calls=$global:autoStartInspectCalls;$thrown=$false
            try{$null=Write-AutoStartPreviewAcceptanceObservation -Plan $good -Provider $provider -Ordinal 1 -Scope $scope -RepositoryRoot $Repository -EvidenceRoot $evidence}catch{$thrown=$true}
            Assert-AutoStart ($thrown -and $calls -eq $global:autoStartInspectCalls -and (Get-FileHash (Join-Path $evidence autostart-preview-01.private.json)).Hash -ceq $result.PublicObservationEvidence[0].Sha256) 'Exclusive evidence write refuses overwrite; original byte binding retained'
            $thrown=$false
            try{$null=Write-AutoStartPreviewAcceptanceObservation -Plan $good -Provider $provider -Ordinal 1 -Scope $scope -RepositoryRoot $Repository -EvidenceRoot $dataRoot}catch{$thrown=$true}
            Assert-AutoStart ($thrown -and $before -ceq (Get-AutoStartFiles) -and $script:forbidden -eq 0) 'Runtime-root evidence veto preserves state and effect boundaries'
            if($IsWindows){
                $link=Join-Path $Repository ('.artifacts/test-runs/port-preview-'+[guid]::NewGuid().ToString('N'))
                if(Test-Path -LiteralPath $link -ErrorAction Stop){throw 'AUTOSTART_FIXTURE_LINK_EXISTS'}
                try{
                    $null=New-Item -ItemType Junction -Path $link -Target $Root -ErrorAction Stop
                    $thrown=$false
                    try{$null=Write-AutoStartPreviewAcceptanceObservation -Plan $good -Provider $provider -Ordinal 1 -Scope $scope -RepositoryRoot $Repository -EvidenceRoot $link}catch{$thrown=$true}
                    Assert-AutoStart ($thrown -and $before -ceq (Get-AutoStartFiles)) 'Actual evidence-root reparse veto prevents writes/effects'
                }finally{
                    $item=Get-Item -LiteralPath $link -Force -ErrorAction Stop
                    if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0 -or $item.FullName -ine [IO.Path]::GetFullPath($link)){throw 'AUTOSTART_FIXTURE_LINK_CHANGED'}
                    Remove-Item -LiteralPath $link -Force -ErrorAction Stop
                }
            }
            # Controlled synthetic leaf writes only this own fixture state. The
            # observation harness must notice the real byte change, not infer it.
            $originalTool=Get-Content -LiteralPath $tool -Raw
            try{
                Set-Content -LiteralPath $tool -Value ('$null=Add-Content -LiteralPath '+("'"+$runPath.Replace("'","''")+"'")+' -Value " ";'+$originalTool) -Encoding utf8
                $fresh=New-PortPreviewAcceptanceEvidenceDirectory -Module $Module -RepositoryRoot $Repository;$thrown=$false
                try{$null=Invoke-AutoStartPreviewAcceptanceObservations -Module $Module -Scope $scope -RunId $run.RunId -Provider $provider -RepositoryRoot $Repository -EvidenceRoot $fresh}catch{$thrown=$_.Exception.Message -ceq 'AUTOSTART_ACCEPTANCE_PREVIEW_STATE_WRITE'}
                Assert-AutoStart ($thrown -and @(Get-ChildItem $fresh -File).Count -eq 5) 'Actual synthetic state-byte change veto after fixed five-call evidence'
            }finally{Set-Content -LiteralPath $tool -Value $originalTool -Encoding utf8}
        }}
        # New console-only acceptance uses actual menu, both routers and public
        # core; only the inspect process leaf is synthetic in this static proof.
        foreach($provider in @('docker','podman')){
            $instance=[pscustomobject]@{id='primary';provider=$provider;version='2025';profile='standard';autostart='manual';drives=@();databases=@();software=@()}
            $desired=New-LabDesiredStateSnapshot -ResolvedLab ([pscustomobject]@{name='Synthetic SQL autostart console acceptance';instances=@($instance)}) -ProvisioningMode adhoc -PersistentData $false
            $run=New-LabRunState -StateRoot $state -Metadata @{desiredState=$desired;persistentData=$false} -ProviderSubRuns @([pscustomobject]@{provider=$provider;instanceIds=@('primary')})
            $runPath=Join-Path $run.RunDir run-state.json;$stored=Get-Content $runPath -Raw|ConvertFrom-Json -Depth 60
            $stored.state='RUNNING';$stored.providerSubRuns[0].state='RUNNING';Write-AutoStartJson $runPath $stored
            Write-AutoStartJson (Join-Path $run.RunDir connection-info.json) @{instances=@(@{id='primary';provider=$provider;containerId=('a'*64);containerName='PRIVATE_NAME_CANARY';port=1})}
            $script:currentRun=$run.RunId;$script:protected=$false;$script:cms=$false;$script:forbidden=0
            $scope=[pscustomobject]@{DataRoot=$dataRoot;StateRoot=$state}
            $global:autoStartInspect=New-AutoStartInspect $run;$global:autoStartInspectCalls=0
            $functionNames=@('Get-SqlServerLabReconcilePlan','Invoke-LabOwnedHostNativeProcess','Read-LabConsoleTextInput','Invoke-LabConsoleMenu','Write-LabInfo','Write-LabWarning','Write-LabError','Wait-LabConsoleAcknowledgement','Show-LabSubMenu','Get-LabSecret','Invoke-SqlQuery','Test-LabEndpointBinding','Repair-LabContainerReconcileJournal','New-LabContainerReconcileJournal','Invoke-LabContainerReconcileCommand','Update-SqlServerLabContainer','Invoke-SqlServerLabWorkflowAction','Invoke-LabActionWithResult','Read-LabConfirm')
            function Get-ConsoleFunctionProof {(@($functionNames|ForEach-Object{$item=Get-Item ('Function:'+$_) -ErrorAction SilentlyContinue;$_+':'+[string]$item.ScriptBlock}) -join '|')}
            $functions=Get-ConsoleFunctionProof;$before=Get-AutoStartFiles
            $fresh=New-PortPreviewAcceptanceEvidenceDirectory -Module $Module -RepositoryRoot $Repository
            $observation=Invoke-AutoStartConsoleAcceptanceObservations -Module $Module -Scope $scope -RunId $run.RunId -Provider $provider -RepositoryRoot $Repository -EvidenceRoot $fresh
            Assert-AutoStart ($observation.PublicPreviewCalls -eq 3 -and $global:autoStartInspectCalls -eq 3 -and $observation.DedicatedCli -ceq 'ACTUAL_MENU_DUAL_ROUTER_PASSED') 'Actual console-only menu and dual routers execute three real public/module/core calls with synthetic leaf'
            Assert-AutoStart ($observation.EarlyCancelInvalidPublicCalls -eq 0 -and $observation.EarlyCancelInvalidNativeReads -eq 0 -and $observation.CoreFiveCallRepeat -ceq 'NOT_EXECUTED') 'Early cancel/invalid/forged selection are read-free; original core five-call proof not repeated'
            Assert-AutoStart ($observation.StateBytesEqual -and $observation.RepeatObservedContentEqual -and $before -ceq (Get-AutoStartFiles) -and $functions -ceq (Get-ConsoleFunctionProof)) 'Actual console observations preserve state bytes and restore every function'
            foreach($record in $observation.PublicObservationEvidence){$recordPath=Join-Path $fresh $record.RelativeEvidencePath;$text=Get-Content $recordPath -Raw
                Assert-AutoStart ((Get-FileHash $recordPath).Hash -ceq $record.Sha256 -and (Get-Item $recordPath).Length -eq $record.Bytes -and $text -notmatch 'PRIVATE_|ObservationKey|HostIp|HostPort|StateRoot|containerId|MSSQL_SA_PASSWORD') 'Console ordinal category evidence is bytebound and privacy-safe'}
            $global:autoStartInspect.Config.Labels.'sql-server-lab.autostart'=$null;$global:autoStartInspectCalls=0
            $failed=New-PortPreviewAcceptanceEvidenceDirectory -Module $Module -RepositoryRoot $Repository;$thrown=$false
            try{$null=Invoke-AutoStartConsoleAcceptanceObservations -Module $Module -Scope $scope -RunId $run.RunId -Provider $provider -RepositoryRoot $Repository -EvidenceRoot $failed}catch{$thrown=$_.Exception.Message -ceq 'AUTOSTART_CONSOLE_ACCEPTANCE_NATIVE_FORM'}
            $category=Get-Content (Join-Path $failed autostart-preview-01.private.json) -Raw|ConvertFrom-Json
            Assert-AutoStart ($thrown -and $category.Status -ceq 'BLOCKED' -and $category.Reason -ceq 'AUTOSTART_PREVIEW_POLICY_UNKNOWN' -and $global:autoStartInspectCalls -eq 1 -and $functions -ceq (Get-ConsoleFunctionProof) -and $before -ceq (Get-AutoStartFiles)) 'Actual blocked console observation persists fixed reason before veto and restores original functions'
            $global:autoStartInspect=New-AutoStartInspect $run;$global:autoStartInspectCalls=0;$thrown=$false
            try{$null=Invoke-AutoStartConsoleAcceptanceObservations -Module $Module -Scope $scope -RunId $run.RunId -Provider $provider -RepositoryRoot $Repository -EvidenceRoot $dataRoot}catch{$thrown=$_.Exception.Message -ceq 'AUTOSTART_ACCEPTANCE_EVIDENCE_SCOPE'}
            Assert-AutoStart ($thrown -and $global:autoStartInspectCalls -eq 1 -and $functions -ceq (Get-ConsoleFunctionProof) -and $before -ceq (Get-AutoStartFiles)) 'Evidence-writer failure survives fixed console error handling and restores functions without extra calls'
            $global:autoStartInspectCalls=0;$thrown=$false
            try{$null=Invoke-AutoStartConsoleAcceptanceObservations -Module $Module -Scope $scope -RunId ([guid]::NewGuid().ToString('D')) -Provider $provider -RepositoryRoot $Repository -EvidenceRoot $fresh}catch{$thrown=$true}
            Assert-AutoStart ($thrown -and $global:autoStartInspectCalls -eq 0 -and $before -ceq (Get-AutoStartFiles)) 'Foreign run binding veto occurs before instrumentation or runtime reads'
            $actualPublic=${function:Get-SqlServerLabReconcilePlan};$thrown=$false;$global:autoStartInspectCalls=0
            try{
                Set-Item Function:script:Get-SqlServerLabReconcilePlan {throw 'PRIVATE_CONSOLE_READ_FAILURE'}
                $faultFunctions=Get-ConsoleFunctionProof
                $fresh=New-PortPreviewAcceptanceEvidenceDirectory -Module $Module -RepositoryRoot $Repository
                try{$null=Invoke-AutoStartConsoleAcceptanceObservations -Module $Module -Scope $scope -RunId $run.RunId -Provider $provider -RepositoryRoot $Repository -EvidenceRoot $fresh}catch{$thrown=$_.Exception.Message -ceq 'PRIVATE_CONSOLE_READ_FAILURE'}
                Assert-AutoStart ($thrown -and $faultFunctions -ceq (Get-ConsoleFunctionProof) -and $global:autoStartInspectCalls -eq 0 -and @(Get-ChildItem $fresh -File).Count -eq 0 -and $before -ceq (Get-AutoStartFiles)) 'Unexpected read exception survives UI fixed-error catch and every observer function is restored'
            }finally{Set-Item Function:script:Get-SqlServerLabReconcilePlan $actualPublic}
            $stored.state='REMOVED';Write-AutoStartJson $runPath $stored
        }
        Write-Host ('Ergebnis: '+$script:checks+' PASS, 0 FAIL; ProviderMutations=0; NativeRuntimeCalls=0')
    } $root $repositoryRoot $module $ConsoleOnly
}

finally {
    Remove-Variable autoStartInspect,autoStartInspectCalls,autoStartToolFail -Scope Global -ErrorAction SilentlyContinue
    Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
    if(Test-Path -LiteralPath $root -ErrorAction Stop){
        $absolute=[IO.Path]::GetFullPath($root);$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
        if([IO.Path]::GetDirectoryName($absolute) -ine $temp -or [IO.Path]::GetFileName($absolute) -cnotmatch '^SqlServerLab-AutoStartPreview-[a-f0-9]{32}$'){throw 'PORT_FIXTURE_CLEANUP_SCOPE'}
        $ancestor=$absolute
        while($ancestor){$item=Get-Item -LiteralPath $ancestor -Force -ErrorAction Stop
            if(-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'PORT_FIXTURE_CLEANUP_REPARSE'}
            $ancestor=[IO.Path]::GetDirectoryName($ancestor)}
        $pending=[Collections.Generic.Queue[string]]::new();$pending.Enqueue($absolute)
        while($pending.Count){foreach($item in @(Get-ChildItem -LiteralPath $pending.Dequeue() -Force -ErrorAction Stop)){
            if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or -not $item.FullName.StartsWith($absolute+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'PORT_FIXTURE_CLEANUP_REPARSE'}
            if($item.PSIsContainer){$pending.Enqueue($item.FullName)}
        }
        }
        Remove-Item -LiteralPath $absolute -Recurse -Force -ErrorAction Stop
    }
}
