#Requires -Version 7.2
$ErrorActionPreference='Stop'
$repositoryRoot=Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
$root=Join-Path ([IO.Path]::GetTempPath()) ('SqlServerLab-PortPreview-'+[guid]::NewGuid().ToString('N'))
$module=Import-Module (Join-Path $repositoryRoot SqlServerLab.psd1) -Force -PassThru
try {
    & $module {
        param($Root)
        $script:checks=0
        function Assert-Port($condition,$name) {
            if (-not $condition) { throw ('PORT_PREVIEW_CHECK_FAILED: '+$name) }
            $script:checks++; Write-Host ('PASS: '+$name)
        }
        function Write-PortJson($path,$value) {
            $null=New-Item -ItemType Directory (Split-Path $path) -Force
            $value|ConvertTo-Json -Depth 60|Set-Content -LiteralPath $path -Encoding utf8
        }
        function Get-PortFiles {
            @((Get-ChildItem $Root -Recurse -File|Sort-Object FullName|ForEach-Object {$_.FullName+':'+(Get-FileHash $_.FullName).Hash})) -join '|'
        }
        $dataRoot=Join-Path $Root data; $state=Join-Path $dataRoot State
        $controller=[guid]::NewGuid().ToString('D');$location=[guid]::NewGuid().ToString('D')
        Write-PortJson (Join-Path $dataRoot '.sql-server-lab-root.json') @{ContractVersion='SqlServerLab.DataRoot/2.0';ManagedBy='SQL_Server_Lab';ControllerId=$controller;VolumeId='PRIVATE_VOLUME_CANARY';DataRoot=$dataRoot}
        $catalogPath=Join-Path $dataRoot 'Catalog/storage-locations.json'
        $catalog=@{ContractVersion='SqlServerLab.Storage/2.0';ControllerId=$controller;LabDataLocations=@(@{LocationId=$location;ControllerId=$controller;LabDataRoot=$dataRoot;VolumeId='PRIVATE_VOLUME_CANARY'})}
        Write-PortJson $catalogPath $catalog
        $tool=Join-Path $Root inspect-spy.ps1
        # The actual context executes this synthetic tool for its sole inspect.
        # No Docker/Podman process, SQL, listener or state mutation is possible.
        Set-Content $tool '$global:portInspectCalls++; if ($global:portToolFail) { throw "PRIVATE_RUNTIME_ERROR_CANARY" }; if ($args.Count -ne 2 -or $args[0] -cne "inspect" -or $args[1] -cne ("a"*64)) { throw "WRONG_INSPECT_ARGV" }; $global:portInspect | ConvertTo-Json -Depth 60' -Encoding utf8
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
        function New-PortInspect($run) {
            [pscustomobject]@{
                Id=('a'*64);Name='/PRIVATE_NAME_CANARY';Image=('sha256:'+('b'*64))
                State=[pscustomobject]@{Running=$true}
                Config=[pscustomobject]@{Labels=[pscustomobject]@{'sql-server-lab.run-id'=$run.RunId;'sql-server-lab.scope-id'=$run.ScopeId;'sql-server-lab.instance-id'='primary'};Env=@('MSSQL_SA_PASSWORD=PRIVATE_SECRET_CANARY')}
                HostConfig=[pscustomobject]@{NanoCpus=2000000000L;Memory=2048MB;NetworkMode='PRIVATE_NETWORK_CANARY';RestartPolicy=[pscustomobject]@{Name='no'};PortBindings=[pscustomobject]@{'1433/tcp'=@([pscustomobject]@{HostIp='127.0.0.1';HostPort='14333'})}}
                NetworkSettings=[pscustomobject]@{Ports=[pscustomobject]@{'1433/tcp'=@([pscustomobject]@{HostIp='127.0.0.1';HostPort='14333'})};Networks=[pscustomobject]@{PRIVATE_NETWORK_CANARY=[pscustomobject]@{Aliases=@();IPAMConfig=$null}}}
                Mounts=@([pscustomobject]@{Type='volume';Name='PRIVATE_MOUNT_CANARY';Source='/PRIVATE_SOURCE_CANARY';Destination='/data';RW=$true})
            }
        }
        function Invoke-PortPlan($run,$port=15433) {
            $global:portInspectCalls=0;$script:forbidden=0
            $before=Get-PortFiles
            $plan=Get-SqlServerLabReconcilePlan -RunId $run.RunId -InstanceId primary -ContainerPortPreview -Port $port -StateRoot $state
            Assert-Port ((Get-PortFiles) -ceq $before -and $script:forbidden -eq 0) 'No state write, repair, SQL, listener or mutation boundary'
            $json=$plan|ConvertTo-Json -Depth 30
            Assert-Port ($json -notmatch 'PRIVATE_|14333|15433|HostIp|HostPort|containerId|runtimeId|MSSQL_SA_PASSWORD' -and $json -notmatch [regex]::Escape($Root)) 'Public DTO contains no host port, native ID, network, paths or secret'
            Assert-Port (-not $plan.CanApply -and -not $plan.MutationAllowed -and $plan.Actions.Count -eq 0 -and $plan.Preview.Endpoint -ceq 'NOT_CHECKED') 'Always PLAN_ONLY authority and unprobed endpoint'
            $plan
        }
        foreach($provider in @('docker','podman')) {
            $instance=[pscustomobject]@{id='primary';provider=$provider;version='2025';profile='standard';autostart='manual';drives=@();databases=@();software=@()}
            $desired=New-LabDesiredStateSnapshot -ResolvedLab ([pscustomobject]@{name='Synthetic SQL port plan';instances=@($instance)}) -ProvisioningMode adhoc -PersistentData $false
            $run=New-LabRunState -StateRoot $state -Metadata @{desiredState=$desired;persistentData=$false} -ProviderSubRuns @([pscustomobject]@{provider=$provider;instanceIds=@('primary')})
            $runPath=Join-Path $run.RunDir run-state.json
            $stored=Get-Content $runPath -Raw|ConvertFrom-Json -Depth 60
            $stored.state='RUNNING';$stored.providerSubRuns[0].state='RUNNING';Write-PortJson $runPath $stored
            Write-PortJson (Join-Path $run.RunDir connection-info.json) @{instances=@(@{id='primary';provider=$provider;containerId=('a'*64);containerName='PRIVATE_NAME_CANARY';port=1})}
            $script:currentRun=$run.RunId;$script:protected=$false;$script:cms=$false
            $global:portInspect=New-PortInspect $run
            $good=Invoke-PortPlan $run
            Assert-Port ($good.Status -ceq 'PLAN_ONLY' -and $good.Provider -ceq $provider -and $good.ChangeClass -ceq 'recreate' -and $good.ObservationKey -cmatch '^[a-f0-9]{64}$' -and $global:portInspectCalls -eq 1) 'Real public/core/context route measures one inspect'
            $same=Invoke-PortPlan $run 14333
            Assert-Port ($same.NoChange -and $same.ChangeClass -ceq 'no-op' -and $same.Desired.PortChange -ceq 'SAME_PORT' -and $same.ObservationKey -cne $good.ObservationKey -and $global:portInspectCalls -eq 1) 'Measured no-op and desired port change content key'
            $repeat=Invoke-PortPlan $run
            Assert-Port ($repeat.ObservationKey -ceq $good.ObservationKey) 'Same observed contents produce stable key'
            $global:portInspect.Mounts=@()
            $empty=Invoke-PortPlan $run
            Assert-Port ($empty.Status -ceq 'PLAN_ONLY' -and $empty.Preview.Mounts.TotalMountCount -eq 0 -and $empty.ObservationKey -cne $good.ObservationKey) 'Explicit empty mounts are measured and content-bound'
            $global:portInspect=New-PortInspect $run
            $global:portInspect.Mounts[0].Type='bind'
            $bind=Invoke-PortPlan $run
            Assert-Port ($bind.Status -ceq 'PLAN_ONLY' -and $bind.Preview.Mounts.WritableHostBindCount -eq 1) 'Valid bind guard and privacy-safe count'
            $global:portInspect=New-PortInspect $run
            $global:portInspect.Config.Env=@('MSSQL_SA_PASSWORD=PRIVATE_OTHER_SECRET_CANARY')
            $changed=Invoke-PortPlan $run
            Assert-Port ($changed.ObservationKey -cne $good.ObservationKey) 'Private configuration content changes observation key without projecting contents'
            foreach($case in @('extraPort','extraBinding','scalarBinding','wildcard','ipv6','extraNetwork','missingMode','extraDns','aliases','staticIp','missingMemory','fractionalMemory','missingCpu','tmpfs','volumePath','wrongIdentity','wrongRunLabel','wrongScopeLabel','missingInstanceLabel','runtimeStopped','toolFailure')) {
                $global:portInspect=New-PortInspect $run
                switch($case) {
                    extraPort { $global:portInspect.NetworkSettings.Ports|Add-Member '80/tcp' @([pscustomobject]@{HostIp='127.0.0.1';HostPort='18080'}) }
                    extraBinding { $global:portInspect.NetworkSettings.Ports.'1433/tcp'+=[pscustomobject]@{HostIp='127.0.0.1';HostPort='14334'} }
                    scalarBinding { $global:portInspect.NetworkSettings.Ports.'1433/tcp'=$global:portInspect.NetworkSettings.Ports.'1433/tcp'[0] }
                    wildcard { $global:portInspect.NetworkSettings.Ports.'1433/tcp'[0].HostIp='0.0.0.0' }
                    ipv6 { $global:portInspect.NetworkSettings.Ports.'1433/tcp'[0].HostIp='::1' }
                    extraNetwork { $global:portInspect.NetworkSettings.Networks|Add-Member other ([pscustomobject]@{}) }
                    missingMode { $global:portInspect.HostConfig.NetworkMode='' }
                    extraDns { $global:portInspect.HostConfig|Add-Member Dns @('192.0.2.2') }
                    aliases { $global:portInspect.NetworkSettings.Networks.PRIVATE_NETWORK_CANARY.Aliases=@('foreign-alias') }
                    staticIp { $global:portInspect.NetworkSettings.Networks.PRIVATE_NETWORK_CANARY.IPAMConfig=[pscustomobject]@{IPv4Address='192.0.2.1'} }
                    missingMemory { $global:portInspect.HostConfig.Memory=0 }
                    fractionalMemory { $global:portInspect.HostConfig.Memory=2048MB+1 }
                    missingCpu { $global:portInspect.HostConfig.NanoCpus=0 }
                    tmpfs { $global:portInspect.Mounts[0].Type='tmpfs' }
                    volumePath { $global:portInspect.Mounts[0].Name='/path' }
                    wrongIdentity { $global:portInspect.Id=('c'*64) }
                    wrongRunLabel { $global:portInspect.Config.Labels.'sql-server-lab.run-id'=[guid]::NewGuid().ToString('D') }
                    wrongScopeLabel { $global:portInspect.Config.Labels.'sql-server-lab.scope-id'=[guid]::NewGuid().ToString('D') }
                    missingInstanceLabel { $global:portInspect.Config.Labels.PSObject.Properties.Remove('sql-server-lab.instance-id') }
                    runtimeStopped { $global:portInspect.State.Running=$false }
                    toolFailure { $global:portToolFail=$true }
                }
                $bad=Invoke-PortPlan $run
                Assert-Port ($bad.Status -cin @('BLOCKED','UNSUPPORTED') -and $null -eq $bad.ObservationKey -and $global:portInspectCalls -eq 1) ('Fail closed actual inspect: '+$case)
                $global:portToolFail=$false
            }
            $global:portInspect=New-PortInspect $run
            foreach($case in @('protected','cms','stopped','unregistered','nonterminalJournal')) {
                switch($case) {
                    protected {$script:protected=$true}
                    cms {$script:cms=$true}
                    stopped {$stored.state='STOPPED';Write-PortJson $runPath $stored}
                    unregistered {Write-PortJson $catalogPath @{ContractVersion='SqlServerLab.Storage/2.0';ControllerId=$controller;LabDataLocations=@()}}
                    nonterminalJournal {
                        $context=Get-LabContainerReconcileContext -RunId $run.RunId -InstanceId primary -StateRoot $state
                        $plan=[pscustomobject]@{HighestChangeClass='recreate';Actual=[pscustomobject]@{SqlMaxMemoryMB=$null};Desired=[pscustomobject]@{Cpu=2;MemoryMB=2048;Port=15433;SqlMemoryLimitMB=1638;SqlMaxMemoryMB=$null;AutoStart='off'}}
                        $journal=& $journalFactory -Context $context -Plan $plan
                    }
                }
                $bad=Invoke-PortPlan $run
                Assert-Port ($bad.Status -ceq 'BLOCKED' -and $null -eq $bad.ObservationKey -and $global:portInspectCalls -eq 0) ('Reject before inspect: '+$case)
                $script:protected=$false;$script:cms=$false;$stored.state='RUNNING';Write-PortJson $runPath $stored;Write-PortJson $catalogPath $catalog
            }
            $journal.Journal.Status='COMPLETED'
            Write-PortJson $journal.Path $journal.Journal
            $terminal=Invoke-PortPlan $run
            Assert-Port ($terminal.Status -ceq 'PLAN_ONLY' -and $terminal.ObservationKey -cne $good.ObservationKey) 'Terminal journal content participates in observation key'
            $journal.Journal.RunId=[guid]::NewGuid().ToString('D');Write-PortJson $journal.Path $journal.Journal
            $foreign=Invoke-PortPlan $run
            Assert-Port ($foreign.Status -ceq 'BLOCKED' -and $global:portInspectCalls -eq 0) 'Foreign terminal journal cannot authorize a preview'
            foreach($extra in @(@{Cpu=2},@{Container=$true},@{TargetState='STOPPED'})) {
                $global:portInspectCalls=0;$thrown=$false
                try {$null=Get-SqlServerLabReconcilePlan -RunId $run.RunId -InstanceId primary -ContainerPortPreview -Port 15433 -StateRoot $state @extra} catch {$thrown=$true}
                Assert-Port ($thrown -and $global:portInspectCalls -eq 0) 'Port-only parameter set rejects mixed executor/lifecycle arguments before inspect'
            }
        }
        Write-Host ('Ergebnis: '+$script:checks+' PASS, 0 FAIL; ProviderMutations=0')
    } $root
}
finally {
    Remove-Variable portInspect,portInspectCalls,portToolFail -Scope Global -ErrorAction SilentlyContinue
    Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
    if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}
}
