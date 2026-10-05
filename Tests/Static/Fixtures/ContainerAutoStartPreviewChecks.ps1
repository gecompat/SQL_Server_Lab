#Requires -Version 7.2
$ErrorActionPreference='Stop'
$repositoryRoot=Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
$root=Join-Path ([IO.Path]::GetTempPath()) ('SqlServerLab-AutoStartPreview-'+[guid]::NewGuid().ToString('N'))
$module=Import-Module (Join-Path $repositoryRoot SqlServerLab.psd1) -Force -PassThru
try {
    & $module {
        param($Root)
        $script:checks=0
        function Assert-AutoStart($condition,$name) {
            if (-not $condition) { throw ('AUTOSTART_PREVIEW_CHECK_FAILED: '+$name) }
            $script:checks++; Write-Host ('PASS: '+$name)
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
        foreach($provider in @('docker','podman')) {
            $instance=[pscustomobject]@{id='primary';provider=$provider;version='2025';profile='standard';autostart='manual';drives=@();databases=@();software=@()}
            $desired=New-LabDesiredStateSnapshot -ResolvedLab ([pscustomobject]@{name='Synthetic SQL port plan';instances=@($instance)}) -ProvisioningMode adhoc -PersistentData $false
            $run=New-LabRunState -StateRoot $state -Metadata @{desiredState=$desired;persistentData=$false} -ProviderSubRuns @([pscustomobject]@{provider=$provider;instanceIds=@('primary')})
            $runPath=Join-Path $run.RunDir run-state.json
            $stored=Get-Content $runPath -Raw|ConvertFrom-Json -Depth 60
            $stored.state='RUNNING';$stored.providerSubRuns[0].state='RUNNING';Write-AutoStartJson $runPath $stored
            Write-AutoStartJson (Join-Path $run.RunDir connection-info.json) @{instances=@(@{id='primary';provider=$provider;containerId=('a'*64);containerName='PRIVATE_NAME_CANARY';port=1})}
            $script:currentRun=$run.RunId;$script:protected=$false;$script:cms=$false
            $global:autoStartInspect=New-AutoStartInspect $run
            $good=Invoke-AutoStartPlan $run
            Assert-AutoStart ($good.Status -ceq 'PLAN_ONLY' -and $good.Provider -ceq $provider -and $good.ChangeClass -ceq 'recreate' -and $good.ObservationKey -cmatch '^[a-f0-9]{64}$' -and $global:autoStartInspectCalls -eq 1) 'Real public/core/context route measures one inspect'
            $same=Invoke-AutoStartPlan $run off
            Assert-AutoStart ($same.NoChange -and $same.ChangeClass -ceq 'no-op' -and $same.Desired.AutoStartChange -ceq 'SAME_POLICY' -and $same.ObservationKey -cne $good.ObservationKey -and $global:autoStartInspectCalls -eq 1) 'Measured no-op and desired port change content key'
            $repeat=Invoke-AutoStartPlan $run
            Assert-AutoStart ($repeat.ObservationKey -ceq $good.ObservationKey) 'Same observed contents produce stable key'
            $upper=Invoke-AutoStartPlan $run ON
            $upperOff=Invoke-AutoStartPlan $run OFF
            Assert-AutoStart ($upper.ObservationKey -ceq $good.ObservationKey -and $upperOff.ObservationKey -ceq $same.ObservationKey -and $upperOff.NoChange -and $upperOff.ChangeClass -ceq 'no-op') 'Public ValidateSet case variants normalize before no-op and content binding'
            foreach($policyCase in @(
                @{Label='on';Policy='always';Status='PLAN_ONLY';Actual='ON'},
                @{Label='on';Policy='unless-stopped';Status='PLAN_ONLY';Actual='ON'},
                @{Label='off';Policy='';Status='PLAN_ONLY';Actual='OFF'},
                @{Label='off';Policy='no';Status='PLAN_ONLY';Actual='OFF'},
                @{Label=$null;Policy='no';Status='BLOCKED';Actual='UNKNOWN'},
                @{Label='';Policy='no';Status='BLOCKED';Actual='UNKNOWN'},
                @{Label=@('off');Policy='no';Status='BLOCKED';Actual='UNKNOWN'},
                @{Label=$false;Policy='no';Status='BLOCKED';Actual='UNKNOWN'},
                @{Label='off';Policy=$null;Status='BLOCKED';Actual='UNKNOWN'},
                @{Label='off';Policy=@('no');Status='BLOCKED';Actual='UNKNOWN'},
                @{Label='off';Policy=0;Status='BLOCKED';Actual='UNKNOWN'},
                @{Label='off';Policy='always';Status='BLOCKED';Actual='DRIFTED'},
                @{Label='on';Policy='no';Status='BLOCKED';Actual='DRIFTED'},
                @{Label='off';Policy='on-failure';Status='UNSUPPORTED';Actual='UNKNOWN'})) {
                $global:autoStartInspect=New-AutoStartInspect $run
                $global:autoStartInspect.Config.Labels.'sql-server-lab.autostart'=$policyCase.Label
                $global:autoStartInspect.HostConfig.RestartPolicy.Name=$policyCase.Policy
                $policyPlan=Invoke-AutoStartPlan $run
                Assert-AutoStart ($policyPlan.Status -ceq $policyCase.Status -and $policyPlan.Actual.AutoStart -ceq $policyCase.Actual -and $global:autoStartInspectCalls -eq 1) ('Strict raw policy evidence: '+$provider+'/'+$policyCase.Status+'/'+$policyCase.Actual)
            }
            $global:autoStartInspect=New-AutoStartInspect $run
            foreach($shapeCase in @('identity-array','run-label-array','scope-label-array','instance-label-array','mode-array','hostip-array','configured-port-array','aliases-scalar','ipam-false','exposed-array','publish-string','dns-false')) {
                $global:autoStartInspect=New-AutoStartInspect $run
                switch($shapeCase) {
                    identity-array {$global:autoStartInspect.Id=@(('a'*64))}
                    run-label-array {$global:autoStartInspect.Config.Labels.'sql-server-lab.run-id'=@($run.RunId)}
                    scope-label-array {$global:autoStartInspect.Config.Labels.'sql-server-lab.scope-id'=@($run.ScopeId)}
                    instance-label-array {$global:autoStartInspect.Config.Labels.'sql-server-lab.instance-id'=@('primary')}
                    mode-array {$global:autoStartInspect.HostConfig.NetworkMode=@('bridge')}
                    hostip-array {$global:autoStartInspect.NetworkSettings.Ports.'1433/tcp'[0].HostIp=@('127.0.0.1')}
                    configured-port-array {$global:autoStartInspect.HostConfig.PortBindings.'1433/tcp'[0].HostPort=@('14333')}
                    aliases-scalar {$global:autoStartInspect.NetworkSettings.Networks.PRIVATE_NETWORK_CANARY.Aliases='PRIVATE_NAME_CANARY'}
                    ipam-false {$global:autoStartInspect.NetworkSettings.Networks.PRIVATE_NETWORK_CANARY.IPAMConfig=$false}
                    exposed-array {$global:autoStartInspect.Config|Add-Member ExposedPorts @()}
                    publish-string {$global:autoStartInspect.HostConfig|Add-Member PublishAllPorts 'false'}
                    dns-false {$global:autoStartInspect.HostConfig|Add-Member Dns @($false)}
                }
                $shapePlan=Invoke-AutoStartPlan $run
                Assert-AutoStart ($shapePlan.Status -cin @('BLOCKED','UNSUPPORTED') -and $null -eq $shapePlan.ObservationKey -and $global:autoStartInspectCalls -eq 1) ('Raw identity/topology type veto: '+$shapeCase)
            }
            $global:autoStartInspect=New-AutoStartInspect $run
            foreach($aliasCase in @(
                [pscustomobject]@{Name='null';Value=$null;Accepted=$true},
                [pscustomobject]@{Name='empty-array';Value=@();Accepted=$true},
                [pscustomobject]@{Name='known-name';Value=@('PRIVATE_NAME_CANARY');Accepted=$true},
                [pscustomobject]@{Name='known-full-id';Value=@(('a'*64));Accepted=$true},
                [pscustomobject]@{Name='known-short-id';Value=@(('a'*12));Accepted=$true},
                [pscustomobject]@{Name='null-and-known';Value=@($null,'PRIVATE_NAME_CANARY');Accepted=$true},
                [pscustomobject]@{Name='nested-known';Value=@(,@('PRIVATE_NAME_CANARY'));Accepted=$false},
                [pscustomobject]@{Name='nested-empty';Value=@(,@());Accepted=$false},
                [pscustomobject]@{Name='object';Value=@([pscustomobject]@{Name='PRIVATE_NAME_CANARY'});Accepted=$false},
                [pscustomobject]@{Name='unknown';Value=@('foreign-alias');Accepted=$false},
                [pscustomobject]@{Name='null-and-unknown';Value=@($null,'foreign-alias');Accepted=$false},
                [pscustomobject]@{Name='empty-string';Value=@('');Accepted=$false},
                [pscustomobject]@{Name='false';Value=@($false);Accepted=$false},
                [pscustomobject]@{Name='zero';Value=@(0);Accepted=$false})) {
                $global:autoStartInspect=New-AutoStartInspect $run
                $global:autoStartInspect.NetworkSettings.Networks.PRIVATE_NETWORK_CANARY.Aliases=$aliasCase.Value
                $aliasPlan=Invoke-AutoStartPlan $run
                $accepted=$aliasPlan.Status -ceq 'PLAN_ONLY'
                Assert-AutoStart ($accepted -eq $aliasCase.Accepted -and $global:autoStartInspectCalls -eq 1 -and
                    ($accepted -or ($aliasPlan.Status -ceq 'UNSUPPORTED' -and $aliasPlan.Reason -ceq 'AUTOSTART_PREVIEW_TOPOLOGY_UNSUPPORTED'))) ('Actual public alias boundary: '+$provider+'/'+$aliasCase.Name)
            }
            $global:autoStartInspect=New-AutoStartInspect $run
            $global:autoStartInspect.Mounts=@()
            $empty=Invoke-AutoStartPlan $run
            Assert-AutoStart ($empty.Status -ceq 'PLAN_ONLY' -and $empty.Preview.Mounts.TotalMountCount -eq 0 -and $empty.ObservationKey -cne $good.ObservationKey) 'Explicit empty mounts are measured and content-bound'
            $global:autoStartInspect=New-AutoStartInspect $run
            $global:autoStartInspect.Mounts[0].Type='bind'
            $bind=Invoke-AutoStartPlan $run
            Assert-AutoStart ($bind.Status -ceq 'PLAN_ONLY' -and $bind.Preview.Mounts.WritableHostBindCount -eq 1) 'Valid bind guard and privacy-safe count'
            $global:autoStartInspect=New-AutoStartInspect $run
            $global:autoStartInspect.Config.Env=@('MSSQL_SA_PASSWORD=PRIVATE_OTHER_SECRET_CANARY')
            $changed=Invoke-AutoStartPlan $run
            Assert-AutoStart ($changed.ObservationKey -cne $good.ObservationKey) 'Private configuration content changes observation key without projecting contents'
            foreach($case in @('extraPort','extraBinding','scalarBinding','wildcard','ipv6','extraNetwork','missingMode','extraDns','aliases','staticIp','missingMemory','fractionalMemory','missingCpu','tmpfs','volumePath','wrongIdentity','wrongRunLabel','wrongScopeLabel','missingInstanceLabel','runtimeStopped','toolFailure')) {
                $global:autoStartInspect=New-AutoStartInspect $run
                switch($case) {
                    extraPort { $global:autoStartInspect.NetworkSettings.Ports|Add-Member '80/tcp' @([pscustomobject]@{HostIp='127.0.0.1';HostPort='18080'}) }
                    extraBinding { $global:autoStartInspect.NetworkSettings.Ports.'1433/tcp'+=[pscustomobject]@{HostIp='127.0.0.1';HostPort='14334'} }
                    scalarBinding { $global:autoStartInspect.NetworkSettings.Ports.'1433/tcp'=$global:autoStartInspect.NetworkSettings.Ports.'1433/tcp'[0] }
                    wildcard { $global:autoStartInspect.NetworkSettings.Ports.'1433/tcp'[0].HostIp='0.0.0.0' }
                    ipv6 { $global:autoStartInspect.NetworkSettings.Ports.'1433/tcp'[0].HostIp='::1' }
                    extraNetwork { $global:autoStartInspect.NetworkSettings.Networks|Add-Member other ([pscustomobject]@{}) }
                    missingMode { $global:autoStartInspect.HostConfig.NetworkMode='' }
                    extraDns { $global:autoStartInspect.HostConfig|Add-Member Dns @('192.0.2.2') }
                    aliases { $global:autoStartInspect.NetworkSettings.Networks.PRIVATE_NETWORK_CANARY.Aliases=@('foreign-alias') }
                    staticIp { $global:autoStartInspect.NetworkSettings.Networks.PRIVATE_NETWORK_CANARY.IPAMConfig=[pscustomobject]@{IPv4Address='192.0.2.1'} }
                    missingMemory { $global:autoStartInspect.HostConfig.Memory=0 }
                    fractionalMemory { $global:autoStartInspect.HostConfig.Memory=2048MB+1 }
                    missingCpu { $global:autoStartInspect.HostConfig.NanoCpus=0 }
                    tmpfs { $global:autoStartInspect.Mounts[0].Type='tmpfs' }
                    volumePath { $global:autoStartInspect.Mounts[0].Name='/path' }
                    wrongIdentity { $global:autoStartInspect.Id=('c'*64) }
                    wrongRunLabel { $global:autoStartInspect.Config.Labels.'sql-server-lab.run-id'=[guid]::NewGuid().ToString('D') }
                    wrongScopeLabel { $global:autoStartInspect.Config.Labels.'sql-server-lab.scope-id'=[guid]::NewGuid().ToString('D') }
                    missingInstanceLabel { $global:autoStartInspect.Config.Labels.PSObject.Properties.Remove('sql-server-lab.instance-id') }
                    runtimeStopped { $global:autoStartInspect.State.Running=$false }
                    toolFailure { $global:autoStartToolFail=$true }
                }
                $bad=Invoke-AutoStartPlan $run
                Assert-AutoStart ($bad.Status -cin @('BLOCKED','UNSUPPORTED') -and $null -eq $bad.ObservationKey -and $global:autoStartInspectCalls -eq 1) ('Fail closed actual inspect: '+$case)
                $global:autoStartToolFail=$false
            }
            $global:autoStartInspect=New-AutoStartInspect $run
            foreach($case in @('protected','cms','stopped','unregistered','nonterminalJournal')) {
                switch($case) {
                    protected {$script:protected=$true}
                    cms {$script:cms=$true}
                    stopped {$stored.state='STOPPED';Write-AutoStartJson $runPath $stored}
                    unregistered {Write-AutoStartJson $catalogPath @{ContractVersion='SqlServerLab.Storage/2.0';ControllerId=$controller;LabDataLocations=@()}}
                    nonterminalJournal {
                        $context=Get-LabContainerReconcileContext -RunId $run.RunId -InstanceId primary -StateRoot $state
                        $plan=[pscustomobject]@{HighestChangeClass='recreate';Actual=[pscustomobject]@{SqlMaxMemoryMB=$null};Desired=[pscustomobject]@{Cpu=2;MemoryMB=2048;Port=15433;SqlMemoryLimitMB=1638;SqlMaxMemoryMB=$null;AutoStart='off'}}
                        $journal=& $journalFactory -Context $context -Plan $plan
                    }
                }
                $bad=Invoke-AutoStartPlan $run
                Assert-AutoStart ($bad.Status -ceq 'BLOCKED' -and $null -eq $bad.ObservationKey -and $global:autoStartInspectCalls -eq 0) ('Reject before inspect: '+$case)
                $script:protected=$false;$script:cms=$false;$stored.state='RUNNING';Write-AutoStartJson $runPath $stored;Write-AutoStartJson $catalogPath $catalog
            }
            $journal.Journal.Status='COMPLETED'
            Write-AutoStartJson $journal.Path $journal.Journal
            $terminal=Invoke-AutoStartPlan $run
            Assert-AutoStart ($terminal.Status -ceq 'PLAN_ONLY' -and $terminal.ObservationKey -cne $good.ObservationKey) 'Terminal journal content participates in observation key'
            $journal.Journal.RunId=[guid]::NewGuid().ToString('D');Write-AutoStartJson $journal.Path $journal.Journal
            $foreign=Invoke-AutoStartPlan $run
            Assert-AutoStart ($foreign.Status -ceq 'BLOCKED' -and $global:autoStartInspectCalls -eq 0) 'Foreign terminal journal cannot authorize a preview'
            foreach($extra in @(@{Cpu=2},@{Container=$true},@{TargetState='STOPPED'})) {
                $global:autoStartInspectCalls=0;$thrown=$false
                try {$null=Get-SqlServerLabReconcilePlan -RunId $run.RunId -InstanceId primary -ContainerAutoStartPreview -AutoStart on -StateRoot $state @extra} catch {$thrown=$true}
                Assert-AutoStart ($thrown -and $global:autoStartInspectCalls -eq 0) 'Port-only parameter set rejects mixed executor/lifecycle arguments before inspect'
            }
        }
        Write-Host ('Ergebnis: '+$script:checks+' PASS, 0 FAIL; ProviderMutations=0')
    } $root
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
