#Requires -Version 7.2
<#
.SYNOPSIS Prueft eigene StateRoot-Vertraege mit synthetischen Dateien und Transport-Spies.
.DESCRIPTION Keine Provider-, Task-, SQL-, WSL-, Desktop- oder Maschinenoperation.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$fixtureRoot = Join-Path $repoRoot ('.artifacts/test-runs/owned-host-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -Path $fixtureRoot -ItemType Directory
$module = New-Module -ArgumentList $repoRoot,$fixtureRoot -ScriptBlock {
    param($repoRoot,$fixtureRoot)
    . (Join-Path $repoRoot 'Private/Common.ps1')
    . (Join-Path $repoRoot 'Private/StateMachine.ps1')
    . (Join-Path $repoRoot 'Private/ContainerOwnedHostIntegration.ps1')
    . (Join-Path $repoRoot 'Private/ContainerRuntimeScope.ps1')
    . (Join-Path $repoRoot 'Private/RetainedStoreRuntime.ps1')
    . (Join-Path $repoRoot 'Private/ContainerInstanceStore.ps1')
    function Get-LabContainerRuntimeScopeEvidence { throw 'FORBIDDEN_DEFAULT_RUNTIME_DISCOVERY' }
    function Get-LabContainerRuntimeHostBackingEvidence { throw 'FORBIDDEN_HOST_BACKING_DISCOVERY' }
    $actualNativeProcess = (Get-Command Invoke-LabOwnedHostNativeProcess).ScriptBlock
    $script:passed = 0; $script:transportCalls = 0; $script:lastStart = $null
    function Assert-Own { param([bool]$Condition,[string]$Name)
        if (-not $Condition) { throw "OWNED_HOST_FIXTURE_FAILED: $Name" }
        $script:passed++; Write-Host "PASS: $Name"
    }
    function Assert-OwnThrows { param([scriptblock]$Action,[string]$Code,[string]$Name)
        $caught = $false
        try { $null = & $Action } catch { $caught = $_.Exception.Message -ceq $Code }
        Assert-Own $caught $Name
    }
    function Invoke-LabOwnedHostNativeProcess {
        param($StartInfo,$TimeoutSeconds,$MaximumBytes)
        $script:transportCalls++; $script:lastStart = $StartInfo
        if ($script:syntheticReply) { return (& $script:syntheticReply $StartInfo) }
        [pscustomobject]@{ ExitCode=0; Stdout='synthetic'; Stderr='' }
    }
    # Kein Modulimport/Toolresolver; sogar versehentliche neue Nativeleaves werfen.
    function Get-LabHostToolInvocation { throw 'FORBIDDEN_TOOL_RESOLUTION' }
    function Invoke-LabProgressNativeCommand { throw 'FORBIDDEN_NATIVE_PROCESS' }
    function Register-ScheduledTask { throw 'FORBIDDEN_TASK' }
    function Start-Process { throw 'FORBIDDEN_PROCESS' }
    function Invoke-LabStoppedHostMemoryRelease { throw 'FORBIDDEN_SHARED_MEMORY' }

    $imageFixture=New-Module -ArgumentList $repoRoot -ScriptBlock {
        param($Repository)
        . (Join-Path $Repository 'Private/ContainerOwnedHostIntegration.ps1')
        function Invoke-LabOwnedHostPinnedCommand {
            param($StateRoot,$Provider,$Arguments)
            if ($StateRoot -cne 'synthetic-root' -or ($Arguments -join '|') -cne 'image|inspect|synthetic-image') { throw 'UNEXPECTED_IMAGE_ROUTE' }
            [pscustomobject]@{ExitCode=$script:exitCode;Stdout=$script:body;Stderr=''}
        }
        function Invoke-ImageCase {
            param($Provider,$Body,[int]$ExitCode=0)
            $script:body=$Body;$script:exitCode=$ExitCode
            try {
                $observed=Get-LabOwnedHostImageObservation -StateRoot 'synthetic-root' -Provider $Provider -Image 'synthetic-image'
                [pscustomobject]@{Id=[string]$observed.Id;Missing=($null -eq $observed);ErrorCode=''}
            } catch { [pscustomobject]@{Id='';Missing=$false;ErrorCode=$_.Exception.Message} }
        }
        Export-ModuleMember -Function @()
    }
    $fullId='a'*64
    foreach($provider in @('docker','podman')) {
        $canonical=& $imageFixture {param($p,$id) Invoke-ImageCase $p ('[{"Id":"sha256:'+ $id+'","Config":{"Labels":{"synthetic":"preserved"}}}]')} $provider $fullId
        Assert-Own ($canonical.Id -ceq ('sha256:'+$fullId)) "Actual $provider observation retains full canonical image identity"
        foreach($body in @('[]','[{"Id":"sha256:abc"}]',('[{"Id":"'+('A'*64)+'"}]'),('[{"Id":"sha256:'+ $fullId+'"},{"Id":"sha256:'+ $fullId+'"}]'))) {
            $invalid=& $imageFixture {param($p,$b) Invoke-ImageCase $p $b} $provider $body
            Assert-Own ($invalid.ErrorCode -ceq 'OWNED_HOST_IMAGE_INSPECT_INVALID') "Actual $provider rejects incomplete or ambiguous image identity"
        }
        $missing=& $imageFixture {param($p) Invoke-ImageCase $p 'invalid-json' 1} $provider
        Assert-Own $missing.Missing "Actual $provider nonzero inspection remains absent observation"
    }
    $bareBody='[{"Id":"'+$fullId+'"}]'
    $barePodman=& $imageFixture {param($b) Invoke-ImageCase podman $b} $bareBody
    $bareDocker=& $imageFixture {param($b) Invoke-ImageCase docker $b} $bareBody
    Assert-Own ($barePodman.Id -ceq ('sha256:'+$fullId)) 'Actual Podman full bare identity becomes immutable canonical reference'
    Assert-Own ($bareDocker.ErrorCode -ceq 'OWNED_HOST_IMAGE_INSPECT_INVALID') 'Bare Docker identity cannot inherit Podman normalization'

    $volumeCleanupFixture=New-Module -ArgumentList $repoRoot,$fixtureRoot -ScriptBlock {
        param($Repository,$FixtureRoot)
        . (Join-Path $Repository 'Private/CleanupEngine.ps1')
        $script:root=Join-Path $FixtureRoot 'cleanup-presence'
        $null=New-Item -ItemType Directory -Path $script:root
        [IO.File]::WriteAllText((Join-Path $script:root 'owned-host-required'),'synthetic')
        function Get-LabOwnedHostRunPolicy { param($RunId,$StateRoot) if($script:mode -ceq 'policy-drift'){throw 'OWNED_HOST_RUN_REFERENCE_DRIFT'}; [pscustomobject]@{StateRoot=$StateRoot} }
        function Get-LabRunState { param($RunId,$StateRoot) [pscustomobject]@{scopeId=if($script:mode -ceq 'scope-drift'){'foreign-scope'}else{'synthetic-scope'}} }
        function Get-LabOwnedHostVolumeReceipt {
            param($StateRoot,$Provider,$VolumeName)
            $script:receiptReads++
            if($script:mode -ceq 'foreign-present'){throw 'OWNED_HOST_RECORD_MISSING'}
            [pscustomobject]@{Intent=[pscustomobject]@{RunId='synthetic-run';ScopeId='synthetic-scope'}}
        }
        function Invoke-LabOwnedHostPinnedCommand {
            param($StateRoot,$Provider,$Arguments)
            $script:calls+=,(@($Arguments) -join '|')
            if($StateRoot -cne $script:root){throw 'UNEXPECTED_VOLUME_ROOT'}
            if(($Arguments -join '|') -ceq 'volume|rm|synthetic-volume'){$script:deletes++;return [pscustomobject]@{ExitCode=0;Stdout=''}}
            if(($Arguments -join '|') -cne 'volume|ls|--filter|name=^synthetic-volume$|--format|{{.Name}}'){throw 'UNEXPECTED_VOLUME_ROUTE'}
            [pscustomobject]@{ExitCode=if($script:mode -ceq 'inventory-failure'){1}else{0};Stdout=if($script:mode -cin @('foreign-present','owned-present') -and -not $script:deletes){'synthetic-volume'}else{''}}
        }
        function Invoke-VolumeCase {
            param($Provider,$Mode)
            $script:mode=$Mode;$script:receiptReads=0;$script:deletes=0;$script:calls=@();$errorCode=''
            try { Remove-LabRuntimeResourceForCleanup -Provider $Provider -ResourceType volume -ResourceId 'synthetic-volume' -ExpectedRunId 'synthetic-run' -ExpectedScopeId 'synthetic-scope' -StateRoot $script:root }
            catch {$errorCode=$_.Exception.Message}
            [pscustomobject]@{ErrorCode=$errorCode;Deletes=$script:deletes;ReceiptReads=$script:receiptReads;Calls=$script:calls}
        }
        Export-ModuleMember -Function @()
    }
    foreach($provider in @('docker','podman')) {
        foreach($mode in @('absent','inventory-failure','foreign-present','scope-drift','policy-drift','owned-present')) {
            $result=& $volumeCleanupFixture {param($p,$m) Invoke-VolumeCase $p $m} $provider $mode
            $expected=switch($mode){'inventory-failure'{'OWNED_HOST_VOLUME_ABSENCE_UNVERIFIABLE'};'foreign-present'{'OWNED_HOST_RECORD_MISSING'};'scope-drift'{'OWNED_HOST_VOLUME_CLEANUP_SCOPE_DRIFT'};'policy-drift'{'OWNED_HOST_RUN_REFERENCE_DRIFT'};default{''}}
            Assert-Own ($result.ErrorCode -ceq $expected -and $result.Deletes -eq [int]($mode -ceq 'owned-present')) "Actual $provider cleanup $mode preserves error and deletion boundary"
            if($mode -ceq 'absent'){Assert-Own ($result.ReceiptReads -eq 0 -and $result.Calls.Count -eq 1) "Actual $provider confirmed absence requires no receipt or deletion"}
            if($mode -cin @('scope-drift','policy-drift')){Assert-Own ($result.Calls.Count -eq 0) "Actual $provider invalid run binding vetoes even absence observation"}
        }
    }

    foreach ($workflowName in @('runtime-smoke-docker','runtime-smoke-podman','runtime-smoke-mixed-providers')) {
        $workflow = [IO.File]::ReadAllText((Join-Path $repoRoot ('.github/workflows/'+$workflowName+'.yml')))
        $calls = @([regex]::Matches($workflow, '(?m)^.*-File\s+\.\\Tests\\Integration\\Invoke-[^\r\n]+'))
        Assert-Own ($calls.Count -gt 0 -and @($calls | Where-Object { $_.Value -cnotmatch '-StateRoot \$env:SQL_SERVER_LAB_CI_OWN_STATE_ROOT' }).Count -eq 0 -and
            $workflow.Contains('Initialize-OwnedHostTestRoot')) "Workflow $workflowName keeps an explicit root on every selected harness"
    }
    $hyperV = [IO.File]::ReadAllText((Join-Path $repoRoot 'Tests/Integration/Invoke-HyperVSmokeTest.ps1'))
    Assert-Own ($hyperV -match '(?s)New-HyperVLabEnvironment\s+.*?-Isolated' -and
        $hyperV.Contains("metadata.networkIntent -ceq 'isolated'") -and
        $hyperV.Contains('Get-VMNetworkAdapter -VM $reconcileVm')) 'HyperV harness uses existing isolated reconcile and observes actual adapter absence'

    $preflightTokens=$null;$preflightErrors=$null
    $preflightAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot 'Tests/Integration/Invoke-PortableContainerTransferPreflightAcceptance.ps1'),[ref]$preflightTokens,[ref]$preflightErrors)
    $newCarrier=@($preflightAst.FindAll({param($Node)$Node -is [Management.Automation.Language.FunctionDefinitionAst] -and $Node.Name -ceq 'New-TransferPreflightAcceptanceRun'},$true))
    $incompleteGuard=@($preflightAst.FindAll({param($Node)$Node -is [Management.Automation.Language.IfStatementAst] -and $Node.Clauses[0].Item1.Extent.Text -ceq '$requestedStateRoot -and $script:unreturnedCreation'},$true))
    $dataCleanupGuard=@($preflightAst.FindAll({param($Node)$Node -is [Management.Automation.Language.IfStatementAst] -and $Node.Clauses[0].Item1.Extent.Text.StartsWith('$requestedStateRoot -and $dataRoot -and -not $cleanupFailed')},$true))
    Assert-Own (-not $preflightErrors -and $newCarrier.Count -eq 1 -and $incompleteGuard.Count -eq 1 -and $dataCleanupGuard.Count -eq 1) 'Partial-New fixture uses actual carrier and cleanup guards'
    $partialNewEvidence=New-Module -ArgumentList $newCarrier[0].Extent.Text,$incompleteGuard[0].Extent.Text,$dataCleanupGuard[0].Extent.Text -ScriptBlock {
        param($Carrier,$RecoveryGuard,$DataGuard)
        . ([scriptblock]::Create($Carrier))
        $script:recoveryGuard=[scriptblock]::Create($RecoveryGuard);$script:dataGuard=[scriptblock]::Create($DataGuard)
        function New-SqlServerLab {
            param($StateRoot,$DataRoot,[switch]$PersistentData)
            $script:received=@{StateRoot=$StateRoot;DataRoot=$DataRoot;PersistentData=[bool]$PersistentData}
            if($script:reply -ceq 'throw'){throw 'SYNTHETIC_NEW_RECOVERY_REQUIRED'}
            if($script:reply -ceq 'no-id'){return [pscustomobject]@{State='Running'}}
            [pscustomobject]@{RunId='00000000-0000-0000-0000-000000000123';State='Running'}
        }
        function Remove-OwnedHostTestDataRoot {param($StateRoot,$DataRoot)$script:dataDeletes++}
        function Test-PartialNew {
            param($Reply)
            $script:reply=$Reply;$script:unreturnedCreation=$false;$script:dataDeletes=0
            $errorCode='NONE';$cleanupFailed=$false;$requestedStateRoot='synthetic-owned-root';$dataRoot='synthetic-owned-data';$completed=$false;$KeepOnFailure=$false
            try {$null=New-TransferPreflightAcceptanceRun -Parameters @{StateRoot=$requestedStateRoot;DataRoot=$dataRoot;PersistentData=$true}}
            catch {$errorCode=$_.Exception.Message}
            . $script:recoveryGuard 3>$null
            . $script:dataGuard
            [pscustomobject]@{ErrorCode=$errorCode;CleanupFailed=$cleanupFailed;DataDeletes=$script:dataDeletes;Received=$script:received}
        }
        Export-ModuleMember -Function @()
    }
    foreach($reply in @('throw','no-id','success')){
        $result=& $partialNewEvidence {param($Reply)Test-PartialNew $Reply} $reply
        $expectedError=switch($reply){throw{'SYNTHETIC_NEW_RECOVERY_REQUIRED'}'no-id'{'PREFLIGHT_ACCEPTANCE_NEW_RUN_ID_MISSING'}default{'NONE'}}
        Assert-Own ($result.ErrorCode -ceq $expectedError -and $result.CleanupFailed -eq ($reply -cne 'success') -and $result.DataDeletes -eq $(if($reply -ceq 'success'){1}else{0})) "Actual preflight $reply preserves partial creation data and primary error"
        Assert-Own ($result.Received.StateRoot -ceq 'synthetic-owned-root' -and $result.Received.DataRoot -ceq 'synthetic-owned-data' -and $result.Received.PersistentData) "Actual preflight $reply preserves New arguments"
    }

    $initializerEvidence=New-Module -ArgumentList $repoRoot,$fixtureRoot -ScriptBlock {
        param($Repository,$Fixture)
        . (Join-Path $Repository 'Tests/Common/OwnedHostTestScope.ps1')
        $script:identity=Join-Path $Fixture 'initializer-synthetic-identity'
        [IO.File]::WriteAllText($script:identity,'synthetic identity')
        $script:runtimeProviders=[Collections.Generic.List[string]]::new()
        function Get-LabHostToolInvocation { param($Name) (Get-Process -Id $PID).Path }
        function Assert-LabOwnedHostPath { param($Path) $Path }
        function Initialize-LabOwnedHostPolicy {
            param($StateRoot,$RuntimePins,$ParentOperationId)
            $script:initializedPins=@($RuntimePins)
            [pscustomobject]@{StateRoot=$StateRoot;PolicyId='synthetic-policy'}
        }
        function Get-LabOwnedHostRuntimeScope {
            param($StateRoot,[ValidateSet('docker','podman')][string]$Provider)
            $script:runtimeProviders.Add($Provider)
        }
        function Invoke-LabOwnedHostNativeProcess {
            param($StartInfo,$TimeoutSeconds,$MaximumBytes)
            $argv=@($StartInfo.ArgumentList)
            $text=switch($argv -join '|') {
                'context|show' {'synthetic-context'}
                'context|inspect|synthetic-context' {'[{"Endpoints":{"docker":{"Host":"npipe:////./pipe/synthetic"}}}]'}
                'system|connection|list|--format|json' {ConvertTo-Json -InputObject @([pscustomobject]@{Default=$true;URI='ssh://synthetic@127.0.0.1:12345/run/synthetic.sock';Identity=$script:identity}) -Compress}
                default {throw 'FORBIDDEN_INITIALIZER_NATIVE_CALL'}
            }
            [pscustomobject]@{ExitCode=0;Stdout=$text;Stderr=''}
        }
        function Get-InitializerEvidence {
            foreach($mode in @('docker','podman','mixed')) {
                $providers=if($mode -ceq 'mixed'){@('docker','podman')}else{@($mode)}
                $script:runtimeProviders.Clear()
                $result=Initialize-OwnedHostTestRoot -Module $ExecutionContext.SessionState.Module -StateRoot (Join-Path $Fixture ('initializer-'+$mode)) -Providers $providers -ParentOperationId 'synthetic'
                [pscustomobject]@{Mode=$mode;Ready=($result.Status -ceq 'READY' -and -not $result.NativeArrangeStarted);ExactProviders=(($script:runtimeProviders -join '|') -ceq ($providers -join '|') -and (@($script:initializedPins.Provider) -join '|') -ceq ($providers -join '|'))}
            }
        }
        Export-ModuleMember -Function @()
    }
    foreach($record in @(& $initializerEvidence { Get-InitializerEvidence })) {
        Assert-Own $record.Ready "Actual $($record.Mode) initializer completes before native Arrange"
        Assert-Own $record.ExactProviders "Actual $($record.Mode) initializer preserves selected provider names through connection discovery"
    }

    $carrierEvidence=New-Module -ArgumentList $repoRoot,$fixtureRoot -ScriptBlock {
        param($Repository,$Fixture)
        . (Join-Path $Repository 'Private/Common.ps1')
        . (Join-Path $Repository 'Private/ResourceAssessment.ps1')
        . (Join-Path $Repository 'Private/ResourceAssessmentDecision.ps1')
        . (Join-Path $Repository 'Public/Restart-SqlServerLab.ps1')
        $script:SchemasPath=Join-Path $Repository 'Schemas'
        $script:calls=[Collections.Generic.List[object]]::new()
        function Test-DockerAvailable {param([string]$StateRoot)
            $script:calls.Add(@{Provider='docker';Root=$StateRoot;Explicit=$PSBoundParameters.ContainsKey('StateRoot')})
            [pscustomobject]@{Available=$true;Version='fixture'}
        }
        function Test-PodmanAvailable {param([string]$StateRoot)
            $script:calls.Add(@{Provider='podman';Root=$StateRoot;Explicit=$PSBoundParameters.ContainsKey('StateRoot')})
            [pscustomobject]@{Available=$true;Version='fixture'}
        }
        function Test-RamAvailability {[pscustomobject]@{Category='RAM';Status='RESOURCE_OK';Message='fixture';Value=1}}
        function Test-StorageAvailability {[pscustomobject]@{Category='Storage';Status='RESOURCE_OK';Message='fixture';Value=1}}
        function Test-PortAvailability {[pscustomobject]@{Category='Ports';Status='RESOURCE_OK';Message='fixture';Value=1}}
        function Write-LabInfo {}
        function Write-LabStatus {}
        function Write-LabSuccess {}
        $record=Invoke-LabResourceAssessmentPreflight -Instances @([pscustomobject]@{provider='docker'}) -Provider docker,podman -StateRoot $Fixture
        $explicit=$record.Execution -ceq 'EXECUTED' -and $record.Status -ceq 'RESOURCE_OK' -and
            $script:calls.Count -eq 2 -and @($script:calls|Where-Object {$_.Root -cne $Fixture -or -not $_.Explicit}).Count -eq 0
        $script:calls.Clear()
        $null=Test-SqlServerLabPrerequisite -Provider docker,podman
        $legacy=@($script:calls|Where-Object {$_.Explicit}).Count -eq 0
        function Get-LabStateRoot { throw 'FORBIDDEN_AMBIENT_ROOT' }
        function Test-LabAutomatedTestEnvironmentRun {$false}
        function Get-LabRunState {param($RunId,$StateRoot)
            if($StateRoot -cne $Fixture){throw 'RESTART_ROOT_LOST'}
            [pscustomobject]@{state='RUNNING';metadata=@{name='fixture'}}
        }
        function Sync-LabRunRuntimeState {param($Run,$StateRoot)
            if($StateRoot -cne $Fixture){throw 'RESTART_SYNC_ROOT_LOST'}
            [pscustomobject]@{Run=$Run}
        }
        function Stop-SqlServerLab {param($RunId,$StateRoot,[switch]$Force,[switch]$SkipHostMemoryRelease)
            $script:stopPinned=$StateRoot -ceq $Fixture -and $Force -and $SkipHostMemoryRelease
            [pscustomobject]@{Action='STOPPED'}
        }
        function Start-SqlServerLab {param($RunId,$StateRoot,$TimeoutSeconds)
            $script:startPinned=$StateRoot -ceq $Fixture -and $TimeoutSeconds -eq 71
            [pscustomobject]@{Status='RUNNING'}
        }
        $restarted=Restart-SqlServerLab -RunId ([guid]::NewGuid().ToString('D')) -StateRoot $Fixture -TimeoutSeconds 71 -Force
        $script:carrierResult=[pscustomobject]@{Explicit=$explicit;Legacy=$legacy;Restart=$script:stopPinned -and $script:startPinned -and $restarted.Status -ceq 'RUNNING'}
        Export-ModuleMember -Function @()
    }
    $carrierResult=@(& $carrierEvidence { $script:carrierResult })
    Assert-Own ($carrierResult.Count -eq 1 -and $carrierResult[0].Explicit) 'Resource preflight preserves explicit root through both provider checks'
    Assert-Own ($carrierResult[0].Legacy) 'Resource assessment legacy calls do not gain a StateRoot argument'
    Assert-Own ($carrierResult[0].Restart) 'Public restart preserves explicit root, force, timeout and memory-release exclusion'

    # Execute production consumer control flow with fail-closed spies. The New
    # retry loop is selected by AST from the actual function, not copied code.
    # This bounded fixture is not a full public provisioning/native proof.
    $consumer=New-Module -ArgumentList $repoRoot,$fixtureRoot -ScriptBlock {
        param($Repository,$Fixture)
        $script:root=Join-Path $Fixture 'consumer-root'
        $null=New-Item -ItemType Directory -Path $script:root
        [IO.File]::WriteAllText((Join-Path $script:root 'owned-host-required'),'synthetic')
        $script:cid='a'*64;$script:runId=[guid]::NewGuid().ToString('D');$script:scopeId=[guid]::NewGuid().ToString('D')
        $script:checks=[Collections.Generic.List[string]]::new()
        $script:calls=[Collections.Generic.List[object]]::new()
        function Check-Consumer {param([bool]$Condition,[string]$Name)
            if(-not $Condition){throw "OWNED_HOST_CONSUMER_FAILED: $Name"};$script:checks.Add($Name)
        }
        function Require-ConsumerRoot {param([string]$Value)
            if($Value -cne $script:root){throw 'CONSUMER_DEFAULT_RUNTIME_DRIFT'}
        }
        function Write-LabInfo {}
        function Write-LabWarning {}
        function Write-LabSuccess {}
        function Get-LabTimestamp {'synthetic'}
        function Get-LabOwnedHostPolicy {param($StateRoot,[switch]$Required)
            Require-ConsumerRoot $StateRoot;[pscustomobject]@{StateRoot=$StateRoot}
        }
        function Get-LabHostToolInvocation {'synthetic-not-executable'}
        . (Join-Path $Repository 'Providers/Docker/DockerProvider.ps1')
        . (Join-Path $Repository 'Providers/Podman/PodmanProvider.ps1')
        . (Join-Path $Repository 'Private/SqlReadiness.ps1')
        . (Join-Path $Repository 'Private/PortableContainerTransferExecutor.ps1')
        . (Join-Path $Repository 'Private/PortableContainerTransferExecutorRuntime.ps1')
        . (Join-Path $Repository 'Tests/Common/PointInTimeRecoveryScenario.ps1')
        . (Join-Path $Repository 'Tests/Common/SqlVersionUpgradeScenario.ps1')
        . (Join-Path $Repository 'Tests/Common/AiPodmanSamplesReferenceScenario.ps1')
        $script:SchemasPath=Join-Path $Repository 'Schemas'
        function Invoke-LabContainerRuntimeCommand {param($Provider,$StateRoot,$Invocation,[string[]]$ArgumentList)
            Require-ConsumerRoot $StateRoot
            $script:calls.Add([pscustomobject]@{Provider=$Provider;Arguments=@($ArgumentList);Root=$StateRoot})
            $global:LASTEXITCODE=0
            if($ArgumentList[0] -ceq 'run'){return $script:cid}
            if($ArgumentList[0] -ceq 'ps'){
                if($script:inventoryMode -ceq 'fail'){$global:LASTEXITCODE=125;return}
                if($script:inventoryMode -ceq 'short'){return $script:cid.Substring(0,12)}
                if($script:inventoryMode -ceq 'empty'){return}
                return $script:cid
            }
            if($ArgumentList -contains '--format'){return ($script:cid+'|true')}
            if($script:inspectFail){$global:LASTEXITCODE=125;return}
            '[{"Id":"'+$script:cid+'","Name":"/synthetic","State":{"Status":"running"},"Config":{"Labels":{"sql-server-lab.run-id":"'+$script:runId+'"}}}]'
        }
        foreach($provider in @('docker','podman')){
            $getter='Get-'+$provider+'LabContainers'
            $script:inventoryMode='present'
            $rows=@(& $getter -RunId $script:runId -StateRoot $script:root)
            $argv=$script:calls[$script:calls.Count-2].Arguments
            Check-Consumer ($rows.Count -eq 1 -and $rows[0].ContainerId -ceq $script:cid -and
                ($argv -join '|') -ceq ('ps|-a|--no-trunc|-q|--filter|label=sql-server-lab.run-id='+$script:runId)) "$provider actual inventory has flat filter and full CID"
            foreach($mode in @('fail','short')){
                $script:inventoryMode=$mode;$caught=$false
                try{$null=& $getter -RunId $script:runId -StateRoot $script:root}catch{$caught=$_.Exception.Message -ceq $(if($mode -ceq 'fail'){'OWNED_HOST_CONTAINER_INVENTORY_FAILED'}else{'OWNED_HOST_CONTAINER_INVENTORY_ID_INVALID'})}
                Check-Consumer $caught "$provider inventory $mode cannot become empty cleanup evidence"
            }
            $script:inventoryMode='empty'
            Check-Consumer (@(& $getter -StateRoot $script:root).Count -eq 0) "$provider actual successful empty inventory remains empty"
            $script:inventoryMode='present';$script:inspectFail=$true;$caught=$false
            try{$null=& $getter -StateRoot $script:root}catch{$caught=$_.Exception.Message -ceq 'OWNED_HOST_CONTAINER_INVENTORY_INSPECT_FAILED'}
            Check-Consumer $caught "$provider failed inspect cannot silently drop inventory"
            $script:inspectFail=$false
        }
        function Get-SqlServerDockerImage {'synthetic/sql:fixture'}
        function Get-SqlServerPodmanImage {'synthetic/sql:fixture'}
        function Get-LabResourceProfile {[pscustomobject]@{maxMemoryMB=2048;maxCpus=1}}
        function Get-LabContainerRuntimeHostname {'synthetic'}
        function Get-LabOwnedHostImageObservation {[pscustomobject]@{Id='sha256:'+('b'*64)}}
        function Ensure-LabDockerNetwork {[pscustomobject]@{Name='existing-synthetic'}}
        function Ensure-LabPodmanNetwork {[pscustomobject]@{Name='existing-synthetic'}}
        function Test-LabEndpointBinding {[pscustomobject]@{Available=$true}}
        function Invoke-LabPortAllocationLock {param($Action)& $Action}
        function New-LabOwnedHostContainerIntent {[pscustomobject]@{synthetic=$true}}
        function Get-LabOwnedHostContainerLabels {@('--label','synthetic-own-label=true')}
        function Initialize-DockerSqlNamedVolume {}
        function Initialize-PodmanSqlNamedVolume {}
        function Assert-LabContainerStoreRuntimeScope {param($Provider,$RuntimeBinding,$StateRoot)
            Require-ConsumerRoot $StateRoot;$script:driveChecks++
        }
        function Invoke-LabProviderOperation {param($Action)
            $output=@(& $Action);[pscustomobject]@{Output=$output;ExitCode=$global:LASTEXITCODE;LogPath=$null}
        }
        function Register-LabOwnedHostContainer {[pscustomobject]@{ContainerId=$script:cid}}
        function Wait-DockerSqlPortBinding {$true}
        $secret=[Security.SecureString]::new()
        foreach($character in 'synthetic-consumer-only'.ToCharArray()){$secret.AppendChar($character)}
        foreach($provider in @('docker','podman')){
            foreach($driveCount in @(0,2)){
                $script:driveChecks=0
                $drives=@(for($i=0;$i -lt $driveCount;$i++){[pscustomobject]@{id="drive$i";containerPath="/synthetic/$i";volumeName="synthetic-volume-$i";runtimeBinding=@{synthetic=$true}}})
                $creator='New-'+$provider+'Instance'
                $created=& $creator -VersionId 2025 -RunId $script:runId -ScopeId $script:scopeId -InstanceId primary -ContainerName synthetic-consumer -Port 14337 -SaPassword $secret -StateRoot $script:root -Drives $drives
                $argv=$script:calls[$script:calls.Count-1].Arguments
                $mounts=@(for($i=0;$i -lt $argv.Count;$i++){if($argv[$i] -ceq '-v'){$argv[$i+1]}})
                Check-Consumer ($created.ContainerId -ceq $script:cid -and @($argv|Where-Object {[string]::IsNullOrEmpty($_)}).Count -eq 0 -and $argv[-1] -ceq ('sha256:'+('b'*64))) "$provider actual create $driveCount drives has no empty image-position arg"
                $mountSuffix=if($provider -ceq 'podman'){':U'}else{''}
                $expectedMounts="synthetic-volume-0:/synthetic/0${mountSuffix}|synthetic-volume-1:/synthetic/1${mountSuffix}"
                Check-Consumer ($mounts.Count -eq $driveCount -and $script:driveChecks -eq $driveCount -and
                    ($driveCount -eq 0 -or ($mounts -join '|') -ceq $expectedMounts)) "$provider actual multiple mount pairs and bound-drive root survive typed argv"
            }
        }
        # Public New retry branch executes the actual AST subtree in lexical
        # scope containing the real allocated run identity and a hostile $run.
        $token=$null;$parseErrors=$null
        $newAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $Repository 'Public/New-SqlServerLab.ps1'),[ref]$token,[ref]$parseErrors)
        $retry=@($newAst.FindAll({param($node)$node -is [Management.Automation.Language.ForEachStatementAst] -and $node.Variable.VariablePath.UserPath -ceq 'readinessAttempt'},$true))
        Check-Consumer ($parseErrors.Count -eq 0 -and $retry.Count -eq 1) 'Public New consumer fixture selects unique production retry loop AST'
        $effectiveStateRoot=$script:root;$runState=[pscustomobject]@{RunId=$script:runId;ScopeId=$script:scopeId}
        $run=[pscustomobject]@{StateRoot='foreign-default';RunId='foreign-default'}
        $instance=[pscustomobject]@{provider='podman';autostart='on';version='2025'}
        $versionDefinition=[pscustomobject]@{major=17};$containerImageArtifactsByInstance=@{};$SaPassword=$secret;$Port=14337
        $script:newCalls=[Collections.Generic.List[string]]::new();$script:readyAttempts=0
        function New-LabProviderContainer {[pscustomobject]@{Provider='podman';Port=14337;ContainerId=$script:cid}}
        function Resolve-PodmanWindowsHostName {param($StateRoot)Require-ConsumerRoot $StateRoot;$script:newCalls.Add('host');'127.0.0.1'}
        function Enable-LabContainerHostAutoStart {param($Provider,$StateRoot,$RunId)
            Require-ConsumerRoot $StateRoot;if($RunId -cne $script:runId){throw 'NEW_RUN_ID_LOST'};$script:newCalls.Add('task')
        }
        function Wait-SqlReady {param($StateRoot)
            Require-ConsumerRoot $StateRoot;$script:readyAttempts++
            [pscustomobject]@{Ready=$script:readyAttempts -eq 2;Message='LAB_SQL_TRANSIENT_LOGIN_STATE_115: synthetic'}
        }
        function Remove-LabProviderContainerForReadinessRetry {param($Container,$ScopeId,$StateRoot)
            Require-ConsumerRoot $StateRoot;if($ScopeId -cne $script:scopeId){throw 'NEW_SCOPE_LOST'};$script:newCalls.Add('retry')
        }
        function Start-Sleep {}
        & ([scriptblock]::Create($retry[0].Extent.Text))
        Check-Consumer (($script:newCalls -join '|') -ceq 'host|task|retry|host|task' -and $script:readyAttempts -eq 2) 'Public New actual retry branch keeps root and allocated identity despite hostile ambient run'
        # Full plan getter observes both bindings via bridge, never raw default.
        function Get-LabDatabaseBackup {throw 'synthetic-no-backup'}
        function Get-LabRunState {[pscustomobject]@{state='RUNNING'}}
        function Resolve-LabRunInstance {param($RunId)[pscustomobject]@{Provider=$(if($RunId -ceq $script:runId){'docker'}else{'podman'});Version='17.0';ContainerName='synthetic'}}
        function Get-LabContainerRuntimeScope {param($Provider,$StateRoot)
            Require-ConsumerRoot $StateRoot;[pscustomobject]@{Status='AVAILABLE';RuntimeId='runtime-scope-'+('a'*24)}
        }
        $targetRun=[guid]::NewGuid().ToString('D');$script:calls.Clear()
        $plan=Get-LabPortableContainerTransferExecutorPlan -SourceRunId $script:runId -SourceInstanceId primary -TargetRunId $targetRun -TargetInstanceId primary -BackupSetId ([guid]::NewGuid().ToString('D')) -TargetDatabaseName Synthetic -DataRoot $Fixture -StateRoot $script:root
        Check-Consumer ($plan.Status -ceq 'BLOCKED' -and $plan.Source.ContainerId -ceq $script:cid -and $plan.Target.ContainerId -ceq $script:cid -and $script:calls.Count -eq 2) 'Actual transfer-plan read-only binding uses both explicit provider routes'
        # Actual terminal cleanup functions call actual residue helper, whose
        # scope/transport spies reject a missing root/default endpoint drift.
        function Get-LabOperationOwnedRun {$null}
        $script:transferCalls=0
        function Invoke-LabTransferNative {param($Provider,$StateRoot,$Arguments,$TimeoutSeconds)
            Require-ConsumerRoot $StateRoot;$script:transferCalls++
            if($script:sampleInventory -and -not $script:sampleRemoved){
                if($Arguments[0] -ceq 'inspect'){
                    return ('[{"Id":"'+$script:cid+'","Config":{"Labels":{"sql-server-lab.run-id":"'+$script:runId+'","sql-server-lab.scope-id":"'+$script:scopeId+'","sql-server-lab.instance-id":"primary"}}}]')
                }
                if($Arguments[0] -ceq 'volume' -and $Arguments[1] -ceq 'inspect'){
                    return ('[{"Name":"synthetic-volume","Labels":{"sql-server-lab.run-id":"'+$script:runId+'","sql-server-lab.scope-id":"'+$script:scopeId+'","sql-server-lab.instance-id":"primary"}}]')
                }
                if($Arguments[0] -ceq 'volume'){return 'synthetic-volume'}
                if($Arguments[-1] -ceq '{{.ID}}|{{.Names}}'){return ($script:cid+'|synthetic')}
                return $script:cid
            }
        }
        $evidence=Join-Path $Fixture 'consumer-evidence';$null=New-Item -ItemType Directory $evidence
        $operation=[guid]::NewGuid().ToString('D');$scope='runtime-scope-'+('a'*24)
        $binding=[pscustomobject]@{Provider='docker';RuntimeScopeId=$scope;RunId=$script:runId;ScopeId=$script:scopeId;ContainerId=$script:cid;Volumes=@()}
        @{OperationId=$operation;Provider='docker';RuntimeScopeId=$scope;SourceOperationId=$operation+'-source';TargetOperationId=$operation+'-target'}|ConvertTo-Json|Set-Content (Join-Path $evidence 'intent.json')
        $binding|ConvertTo-Json|Set-Content (Join-Path $evidence 'binding.json')
        Remove-PitrOwnRun -Provider docker -OperationId $operation -StateRoot $script:root -EvidenceRoot $evidence
        Check-Consumer ($script:transferCalls -eq 4) 'Actual PITR terminal caller passes root through real residue helper after run removal'
        foreach($role in @('source','target')){$binding|Add-Member OperationId ($operation+'-'+$role) -Force;$binding|ConvertTo-Json|Set-Content (Join-Path $evidence ($role+'-binding.json'))}
        $script:transferCalls=0
        Remove-SqlUpgradeOwnRuns -Provider docker -OperationId $operation -StateRoot $script:root -EvidenceRoot $evidence
        Check-Consumer ($script:transferCalls -eq 8) 'Actual upgrade sibling terminal callers retain root through both residue proofs'
        function Assert-LabAiPersistentPath {}
        function Get-AiPodmanSamplesOperationRun {[pscustomobject]@{runId=$script:runId;scopeId=$script:scopeId;metadata=@{workflowOperationId=$operation;persistentData=$false}}}
        function Get-CleanupPlan {[pscustomobject]@{runId=$script:runId;scopeId=$script:scopeId;steps=@([pscustomobject]@{provider='podman';resourceType='container';resourceId=$script:cid},[pscustomobject]@{provider='podman';resourceType='volume';resourceId='synthetic-volume'})}}
        function Get-LabProviderSubRuns {[pscustomobject]@{provider='podman'}}
        function Remove-SqlServerLab {param($StateRoot)Require-ConsumerRoot $StateRoot;$script:sampleRemoved=$true;[pscustomobject]@{Status='REMOVED';Errors=@()}}
        $script:sampleInventory=$true;$script:sampleRemoved=$false;$script:transferCalls=0
        Remove-AiPodmanSamplesOwnedRun -Record ([pscustomobject]@{StateRoot=$script:root;RuntimeScopeId=$scope;OperationId=$operation;NewStarted=$true})
        Check-Consumer ($script:sampleRemoved -and $script:transferCalls -eq 11) 'Actual AI sample inventory inspect volume-attachment and terminal inventory all retain record root'
        # Real stopwatch waits beyond five seconds; SQL transport is synthetic.
        # Re-source restores the production Wait, replacing only its leaf probes.
        . (Join-Path $Repository 'Private/SqlReadiness.ps1')
        Remove-Item Function:Start-Sleep
        function sqlcmd {}
        function Start-LabActionProgress {[pscustomobject]@{synthetic=$true}}
        function Update-LabActionProgress {}
        function Stop-LabActionProgress {}
        function Resolve-LabHostTool {throw 'FORBIDDEN_WSL_MAINTENANCE'}
        function Get-LabContainerReadinessDiagnostic {param($StateRoot)Require-ConsumerRoot $StateRoot;[pscustomobject]@{Running=$true;Message='synthetic'}}
        function Invoke-LabSqlcmdProgress {
            if($script:sqlClock.Elapsed.TotalSeconds -lt 5.4){[pscustomobject]@{ExitCode=1;Output='synthetic startup'}}
            else{[pscustomobject]@{ExitCode=0;Output='17'}}
        }
        foreach($provider in @('docker','podman')){
            $script:sqlClock=[Diagnostics.Stopwatch]::StartNew()
            $ready=Wait-SqlReady -Port 14337 -SaPassword $secret -TimeoutSeconds 9 -PollIntervalMilliseconds 100 -RequiredConsecutiveSuccesses 2 -StabilitySeconds 1 -ExpectedMajorVersion 17 -Provider $provider -ContainerIdOrName $script:cid -StateRoot $script:root
            Check-Consumer ($ready.Ready -and $ready.Duration.TotalSeconds -gt 5 -and $ready.Duration.TotalSeconds -lt 9) "$provider actual configured SQL wait survives five-second maintenance exclusion"
        }
        Export-ModuleMember -Function @()
    }
    $consumerResult=@(& $consumer { $script:checks })
    foreach($name in $consumerResult){Assert-Own $true $name}

    $ordinary = New-LabRunState -StateRoot (Join-Path $fixtureRoot 'ordinary') -Metadata @{name='synthetic-standard'}
    $ordinaryState = Get-LabRunState -RunId $ordinary.RunId -StateRoot $ordinary.StateRoot
    Assert-Own (-not $ordinaryState.metadata.ownedHostIntegration -and -not $ordinaryState.metadata.workflowOperationId) 'Standard-New behaelt Metadata und allokiert keine neue Operation'
    Assert-OwnThrows { Assert-LabOwnedHostGuid '00000000-0000-0000-0000-000000000000' } 'OWNED_HOST_ID_INVALID' 'Leere Identitaet ist keine Autoritaet'
    $duplicatePath = Join-Path $fixtureRoot 'duplicate.json'
    [IO.File]::WriteAllText($duplicatePath, '{"PolicyId":"first","policyid":"second"}')
    Assert-OwnThrows { Read-LabOwnedHostRecord $duplicatePath } 'OWNED_HOST_RECORD_DUPLICATE_PROPERTY' 'Duplicate JSON Properties werden verweigert'
    Assert-OwnThrows { Assert-LabOwnedHostProperties ([pscustomobject]@{A=1;Unexpected=2}) @('A') } 'OWNED_HOST_RECORD_SHAPE_INVALID' 'Unbekannte Recordproperty wird verweigert'
    function New-SyntheticProcessStart {
        param([string]$Command)
        $start = [Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
        $start.UseShellExecute = $false; $start.CreateNoWindow = $true
        $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
        foreach ($argument in @('-NoProfile','-NonInteractive','-Command',$Command)) { $start.ArgumentList.Add($argument) }
        return $start
    }
    $childResult = & $actualNativeProcess -StartInfo (New-SyntheticProcessStart '[Console]::Out.Write("synthetic-out"); [Console]::Error.Write("synthetic-error"); exit 7') -TimeoutSeconds 10
    Assert-Own ($childResult.ExitCode -eq 7 -and $childResult.Stdout -ceq 'synthetic-out' -and $childResult.Stderr -ceq 'synthetic-error') 'Realer eigener PowerShell-Kindprozess bewahrt stdout stderr und Exitcode ohne Provider'
    Assert-OwnThrows { & $actualNativeProcess -StartInfo (New-SyntheticProcessStart '[Console]::Out.Write(("x" * 8192))') -TimeoutSeconds 10 -MaximumBytes 4096 } 'OWNED_HOST_COMMAND_OUTPUT_LIMIT' 'Bytegrenze verweigert uebergrosse Kindausgabe waehrend Drain'
    Assert-OwnThrows { & $actualNativeProcess -StartInfo (New-SyntheticProcessStart 'Start-Sleep -Seconds 20') -TimeoutSeconds 1 } 'OWNED_HOST_COMMAND_TIMEOUT' 'Kindtimeout bestaetigt eigene Terminierung und erhaelt Fehlerklasse'

    if ($IsWindows) {
        $docker = Join-Path $fixtureRoot 'docker.exe'; $podman = Join-Path $fixtureRoot 'podman.exe'
        $identity = Join-Path $fixtureRoot 'synthetic-identity'
        [IO.File]::WriteAllText($docker, 'synthetic-never-executed')
        [IO.File]::WriteAllText($podman, 'synthetic-never-executed')
        [IO.File]::WriteAllText($identity, 'synthetic-never-used')
        $pins = @(
            [pscustomobject]@{Provider='docker';Invocation=$docker;Endpoint='npipe:////./pipe/synthetic';IdentityPath='';IdentitySha256=''},
            [pscustomobject]@{Provider='podman';Invocation=$podman;Endpoint='ssh://synthetic@127.0.0.1:2222/run/podman/podman.sock';IdentityPath=$identity;IdentitySha256=(Get-FileHash $identity).Hash.ToLowerInvariant()}
        )
        $root = Join-Path $fixtureRoot 'owned'
        $policy = Initialize-LabOwnedHostPolicy -StateRoot $root -RuntimePins $pins -ParentOperationId 'synthetic-parent'
        $dataCoordinator=New-Module -ArgumentList $repoRoot -ScriptBlock {
            param($Repository)
            . (Join-Path $Repository 'Tests/Common/OwnedHostTestScope.ps1')
            Export-ModuleMember -Function @()
        }
        $dataPath=& $dataCoordinator {param($Root)New-OwnedHostTestDataRoot -StateRoot $Root -Purpose preflight} $root
        Assert-Own ($dataPath -ceq (Join-Path $root 'dpf')) 'Transfer test data is directly beneath the owned root'
        Assert-OwnThrows {& $dataCoordinator {param($Root)New-OwnedHostTestDataRoot -StateRoot $Root -Purpose preflight} $root} 'OWNED_HOST_TEST_DATA_ALREADY_EXISTS' 'Existing data directory is never adopted'
        $foreignData=Join-Path $root 'foreign-data';$null=New-Item -Path $foreignData -ItemType Directory
        Assert-OwnThrows {& $dataCoordinator {param($Root,$Data)Remove-OwnedHostTestDataRoot -StateRoot $Root -DataRoot $Data} $root $foreignData} 'OWNED_HOST_TEST_DATA_UNCLAIMED' 'Cleanup rejects unallocated directories'
        Assert-Own (Test-Path -LiteralPath $foreignData) 'Rejected cleanup preserves the foreign directory'
        $claimPath=Join-Path $dataPath 'test-data-claim.private';$claimText=[IO.File]::ReadAllText($claimPath)
        [IO.File]::WriteAllText($claimPath,'changed synthetic claim')
        Assert-OwnThrows {& $dataCoordinator {param($Root,$Data)Remove-OwnedHostTestDataRoot -StateRoot $Root -DataRoot $Data} $root $dataPath} 'OWNED_HOST_TEST_DATA_CLAIM_DRIFT' 'Changed allocation marker denies cleanup'
        [IO.File]::WriteAllText($claimPath,$claimText)
        $policyFile=Join-Path $root 'owned-host-policy.json';$policyText=[IO.File]::ReadAllText($policyFile)
        [IO.File]::WriteAllText($policyFile,$policyText.Replace('synthetic-parent','changed-parent'))
        Assert-OwnThrows {& $dataCoordinator {param($Root,$Data)Remove-OwnedHostTestDataRoot -StateRoot $Root -DataRoot $Data} $root $dataPath} 'OWNED_HOST_TEST_DATA_CLAIM_DRIFT' 'Changed valid policy denies data cleanup'
        [IO.File]::WriteAllText($policyFile,$policyText)
        $link=Join-Path $dataPath 'synthetic-link';$null=New-Item -Path $link -ItemType Junction -Target $foreignData
        Assert-OwnThrows {& $dataCoordinator {param($Root,$Data)Remove-OwnedHostTestDataRoot -StateRoot $Root -DataRoot $Data} $root $dataPath} 'OWNED_HOST_REPARSE_PATH' 'Descendant junction denies recursive data cleanup'
        [IO.Directory]::Delete($link)
        & $dataCoordinator {param($Root,$Data)Remove-OwnedHostTestDataRoot -StateRoot $Root -DataRoot $Data} $root $dataPath
        Assert-Own (-not(Test-Path -LiteralPath $dataPath) -and (Test-Path -LiteralPath $foreignData)) 'Exact allocated data cleanup preserves other root contents'
        Assert-OwnThrows {& $dataCoordinator {param($Root,$Data)Remove-OwnedHostTestDataRoot -StateRoot $Root -DataRoot $Data} $root $dataPath} 'OWNED_HOST_TEST_DATA_UNCLAIMED' 'Consumed allocation cannot authorize another deletion'
        $transferData=& $dataCoordinator {param($Root)New-OwnedHostTestDataRoot -StateRoot $Root -Purpose transfer} $root
        Assert-Own ($transferData -ceq (Join-Path $root 'dtr')) 'Transfer and preflight use separate short data allocations'
        & $dataCoordinator {param($Root,$Data)Remove-OwnedHostTestDataRoot -StateRoot $Root -DataRoot $Data} $root $transferData
        $imageFixture=New-Module -ArgumentList $repoRoot,$fixtureRoot,$pins -ScriptBlock {
            param($Repository,$Fixture,$Pins)
            . (Join-Path $Repository 'Private/Common.ps1')
            . (Join-Path $Repository 'Private/StateMachine.ps1')
            . (Join-Path $Repository 'Private/ArtifactResolver.ps1')
            . (Join-Path $Repository 'Private/ContainerToolImage.ps1')
            . (Join-Path $Repository 'Private/ContainerOwnedHostIntegration.ps1')
            $script:count=0;$script:removals=0;$script:image=$null;$script:probeFailure=$false
            function Invoke-LabOwnedHostEphemeralContainer {
                if($script:probeFailure){throw 'OWNED_HOST_SYNTHETIC_PROBE_FAILED'}
                '170.4.83.3'
            }
            function Invoke-LabOwnedHostNativeProcess {
                param($StartInfo,$TimeoutSeconds,$MaximumBytes)
                $script:count++
                $argv=@($StartInfo.ArgumentList)[2..($StartInfo.ArgumentList.Count-1)]
                $body='';$code=0
                if($argv[0] -ceq 'build'){
                    $labels=@{'sql-server-lab.container-tool.image-key'=$script:key;'sql-server-lab.container-tool.ids'='sqlpackage'}
                    for($i=0;$i -lt $argv.Count;$i++){if($argv[$i] -ceq '--label'){$pair=$argv[++$i]-split '=',2;$labels[$pair[0]]=$pair[1]}}
                    $script:tag=$argv[[array]::IndexOf($argv,'--tag')+1]
                    $script:image=[pscustomobject]@{Id=('sha256:'+('e'*64));Config=[pscustomobject]@{Labels=[pscustomobject]$labels}}
                }elseif($argv[0] -ceq 'image' -and $argv[1] -ceq 'inspect'){
                    if($argv[2] -cmatch '@sha256:'){$body=([pscustomobject]@{Id=('sha256:'+('f'*64));Config=@{Labels=@{}}}|ConvertTo-Json -Depth 6)}
                    elseif($script:reuse -and $argv[2] -cin @($script:canonical,('sha256:'+('d'*64)))){
                        $body=([pscustomobject]@{Id=('sha256:'+('d'*64));Config=@{Labels=@{'sql-server-lab.container-tool.image-key'=$script:key;'sql-server-lab.container-tool.ids'='sqlpackage'}}}|ConvertTo-Json -Depth 6)
                    }elseif($script:image -and $argv[2] -ceq $script:tag){$body=$script:image|ConvertTo-Json -Depth 7}
                    else{$code=1}
                }elseif($argv[0] -ceq 'image' -and $argv[1] -ceq 'rm'){
                    if($argv.Count -ne 4 -or $argv[2] -cne '--no-prune' -or $argv[3] -cne $script:tag){throw 'SYNTHETIC_IMAGE_REMOVAL_SCOPE_INVALID'}
                    $script:removals++;$script:image=$null
                }elseif(-not (($argv[0] -ceq 'image' -and $argv[1] -ceq 'ls') -or $argv[0] -ceq 'ps')){throw 'SYNTHETIC_IMAGE_COMMAND_UNEXPECTED'}
                [pscustomobject]@{ExitCode=$code;Stdout=$body;Stderr=''}
            }
            $script:evidence=[Collections.Generic.List[bool]]::new()
            foreach($case in @('reuse','build','failed-probe')){
                $script:reuse=$case -ceq 'reuse';$script:probeFailure=$case -ceq 'failed-probe';$script:image=$null
                $script:key=if($case -ceq 'reuse'){'a'*64}elseif($case -ceq 'build'){'b'*64}else{'c'*64}
                $script:canonical='sql-server-lab/container-tool:'+$script:key
                $caseRoot=Join-Path $Fixture ('image-'+$case)
                $policy=Initialize-LabOwnedHostPolicy -StateRoot $caseRoot -RuntimePins @($Pins[0])
                $run=New-LabRunState -StateRoot $caseRoot
                $plan=[pscustomobject]@{Provider='docker';ImageKey=$script:key;Image=$script:canonical
                    BaseImage=('source/base@sha256:'+('a'*64));ExtractorImage=('source/extractor@sha256:'+('b'*64))
                    BaseImageDigest=('a'*64);Containerfile=(Join-Path $Repository 'Images/Tools/Linux/Containerfile')
                    RecipeRoot=(Join-Path $Repository 'Images/Tools/Linux');SqlPackageArchiveUrl='https://synthetic.invalid/a';SqlPackageArchiveSha256=('a'*64)
                    RuntimeVersion='170.4.83.3';LibunwindDebUrl='https://synthetic.invalid/b';LibunwindDebSha256=('b'*64);LibunwindDebVersion='fixture'
                    RecipeVersion='fixture';SoftwarePlanKeys=@('fixture');ToolIds=@('sqlpackage');ContextEvidence=@()}
                if($case -ceq 'failed-probe'){
                    $caught=$false
                    try{$null=Invoke-LabOwnedHostToolImageBuild -ImagePlan $plan -StateRoot $caseRoot -RunId $run.RunId}
                    catch{$caught=$_.Exception.Message -ceq 'OWNED_HOST_SYNTHETIC_PROBE_FAILED'}
                    $script:evidence.Add($caught -and -not $script:image -and $script:removals -eq 2 -and
                        (Test-Path (Join-Path $caseRoot ('owned-host-tool-images/docker-'+$script:key+'.created.json'))))
                    continue
                }
                $built=Invoke-LabOwnedHostToolImageBuild -ImagePlan $plan -StateRoot $caseRoot -RunId $run.RunId
                if($case -ceq 'reuse'){
                    $preserved=Remove-LabOwnedHostToolImage -StateRoot $caseRoot -Provider docker -ImageKey $script:key
                    $script:evidence.Add($built.Reused -and $built.Image -ceq ('sha256:'+('d'*64)) -and
                        $preserved.Status -ceq 'PRESERVED_IMMUTABLE_REFERENCE' -and $script:removals -eq 0)
                }else{
                    $denied=$false
                    try{$null=Remove-LabOwnedHostToolImage -StateRoot $caseRoot -Provider docker -ImageKey $script:key}
                    catch{$denied=$_.Exception.Message -ceq 'OWNED_HOST_IMAGE_ACTIVE_RUN_REFERENCE'}
                    $script:evidence.Add($denied -and $script:removals -eq 0)
                    $statePath=Join-Path $caseRoot ('runs/'+$run.RunId+'/run-state.json')
                    $state=Get-LabRunState -RunId $run.RunId -StateRoot $caseRoot;$state.state='REMOVED'
                    [IO.File]::WriteAllText($statePath,($state|ConvertTo-Json -Depth 20))
                    $removed=Remove-LabOwnedHostToolImage -StateRoot $caseRoot -Provider docker -ImageKey $script:key
                    $script:evidence.Add($removed.Removed -and -not $script:image -and $script:removals -eq 1 -and
                        $built.Receipt.retention -ceq 'owned-root-explicit-terminal-removal')
                }
            }
            Export-ModuleMember -Function @()
        }
        $imageEvidence=& $imageFixture { [pscustomobject]@{Checks=$script:evidence.ToArray();Transports=$script:count} }
        Assert-Own ($imageEvidence.Checks[0]) 'Existing immutable ToolImage reuse preserves shared image and logical key'
        Assert-Own ($imageEvidence.Checks[1]) 'Own ToolImage cannot remove a tag while an actual run reference is active'
        Assert-Own ($imageEvidence.Checks[2]) 'Terminal own ToolImage cleanup removes exactly its tag without force or pruning'
        Assert-Own ($imageEvidence.Checks[3]) 'Failed tool version probe compensates its tag and preserves creation custody'
        $script:transportCalls+=$imageEvidence.Transports
        Assert-Own ($policy.PolicyId -cne $policy.RootScopeId) 'RootPolicy und Scope besitzen getrennte frische Identitaeten'
        Assert-OwnThrows { Initialize-LabOwnedHostPolicy -StateRoot $root -RuntimePins $pins } 'OWNED_HOST_ROOT_ALREADY_EXISTS' 'Bestehender Root wird nicht adoptiert oder umgeschrieben'
        foreach ($operation in @('synthetic-parent-source','synthetic-parent-target','synthetic-batch-1','synthetic-batch-2')) {
            $run = New-LabRunState -StateRoot $root -Metadata @{workflowOperationId=$operation}
            $state = Get-LabRunState -RunId $run.RunId -StateRoot $root
            $bound = Get-LabOwnedHostRunPolicy -RunId $run.RunId -StateRoot $root
            Assert-Own ($bound.PolicyId -ceq $policy.PolicyId -and $state.metadata.ownedHostIntegration.WorkflowOperationId -ceq $operation -and
                $state.metadata.ownedHostIntegration.OperationOrigin -ceq 'WORKFLOW_CONTEXT') "Tatsaechlicher New-State bewahrt Geschwisteroperation $operation"
        }
        $allocated = New-LabRunState -StateRoot $root
        $allocatedState = Get-LabRunState -RunId $allocated.RunId -StateRoot $root
        $ownedSchema = Join-Path $repoRoot 'Schemas/container-owned-host-integration.schema.json'
        Assert-Own (($policy|ConvertTo-Json -Depth 12)|Test-Json -SchemaFile $ownedSchema) 'Persisted policy satisfies its closed typed schema'
        Assert-Own (($allocatedState.metadata.ownedHostIntegration|ConvertTo-Json -Depth 12)|Test-Json -SchemaFile $ownedSchema) 'Actual allocated run reference satisfies its closed typed schema'
        . (Join-Path $repoRoot 'Tests/Common/OwnedHostTestScope.ps1')
        $artifact = Get-OwnedHostTestArtifactRoot -StateRoot $root -Name 'synthetic-evidence'
        Assert-Own (Test-OwnedHostTestEvidenceBinding -StateRoot $root -EvidenceRoot $artifact) 'Own coordinator accepts actual child evidence under the selected root'
        Assert-Own (-not (Test-OwnedHostTestEvidenceBinding -StateRoot $root -EvidenceRoot $fixtureRoot)) 'Own coordinator rejects cross-root evidence before a supervisor runs'
        Assert-OwnThrows { Initialize-OwnedHostTestRoot -Module $ExecutionContext.SessionState.Module -StateRoot $root -Providers docker -ParentOperationId 'synthetic' } 'OWNED_HOST_ROOT_ALREADY_EXISTS' 'Coordinator rejects an existing root before pin discovery or provider calls'
        Assert-Own ($allocatedState.metadata.ownedHostIntegration.OperationOrigin -ceq 'OWN_RUN_ALLOCATED' -and
            $allocatedState.metadata.workflowOperationId -cne $policy.ParentOperationId) 'New ohne Workflowcontext persistiert eigene kanonische Operation'
        $oldContext = $env:DOCKER_CONTEXT
        try {
            $env:DOCKER_CONTEXT = 'synthetic-foreign-default'
            $null = Invoke-LabOwnedHostPinnedCommand -StateRoot $root -Provider docker -Arguments @('inspect','synthetic-id')
            Assert-Own (($script:lastStart.ArgumentList -join '|') -ceq '--host|npipe:////./pipe/synthetic|inspect|synthetic-id' -and
                -not $script:lastStart.Environment.ContainsKey('DOCKER_CONTEXT') -and $env:DOCKER_CONTEXT -ceq 'synthetic-foreign-default' -and
                -not $script:lastStart.UseShellExecute) 'Expliziter Docker-Pin bleibt bei Defaultwechsel unveraendert; nur Child-ENV neutralisiert'
            $null = Invoke-LabOwnedHostPinnedCommand -StateRoot $root -Provider podman -Arguments @('info','--format','json')
            Assert-Own (($script:lastStart.ArgumentList -join '|') -ceq ('--remote|--url|ssh://synthetic@127.0.0.1:2222/run/podman/podman.sock|--identity|'+$identity+'|info|--format|json')) 'Podman-Info verwendet gespeicherte vollstaendige URL und Identity'
            $before = $script:transportCalls
            Assert-OwnThrows { Invoke-LabOwnedHostPinnedCommand -StateRoot $root -Provider docker -Arguments @('--host','foreign','info') } 'OWNED_HOST_ROUTE_OVERRIDE_FORBIDDEN' 'Caller kann Pin nicht uebersteuern'
            Assert-OwnThrows { Invoke-LabOwnedHostPinnedCommand -StateRoot $root -Provider docker -Arguments @('info','-H','foreign') } 'OWNED_HOST_ROUTE_OVERRIDE_FORBIDDEN' 'Docker short host override is rejected'
            Assert-OwnThrows { Invoke-LabOwnedHostPinnedCommand -StateRoot $root -Provider podman -Arguments @('info','-c','foreign') } 'OWNED_HOST_ROUTE_OVERRIDE_FORBIDDEN' 'Podman short connection override is rejected'
            Assert-Own ($script:transportCalls -eq $before) 'Abgewiesener Routingoverride hat zero transports'
        }
        finally { $env:DOCKER_CONTEXT = $oldContext }
        $script:syntheticReply = { param($StartInfo)
            $arguments=@($StartInfo.ArgumentList)
            $text=if ($arguments -contains 'inspect') { $script:containerJson } else { '' }
            [pscustomobject]@{ExitCode=0;Stdout=$text;Stderr=''}
        }
        $intent = New-LabOwnedHostContainerIntent -StateRoot $root -RunId $allocated.RunId -ScopeId $allocatedState.scopeId -InstanceId 'synthetic-instance' -Provider docker -ContainerName 'synthetic-container'
        Assert-Own (Test-Path (Join-Path $allocated.RunDir ('owned-host-containers/'+$intent.IntentId+'.intent.json'))) 'Containerabsicht ist vor erster Create-Mutation exklusiv persistiert'
        $cid='a'*64
        $labels=@{
            'sql-server-lab.run-id'=$intent.RunId; 'sql-server-lab.scope-id'=$intent.ScopeId
            'sql-server-lab.instance-id'=$intent.InstanceId; 'sql-server-lab.owned-host-policy-id'=$intent.PolicyId
            'sql-server-lab.owned-host-root-scope-id'=$intent.RootScopeId; 'sql-server-lab.owned-host-intent-id'=$intent.IntentId
        }
        $script:containerJson=@([pscustomobject]@{Id=$cid;Name='/synthetic-container';Config=[pscustomobject]@{Labels=$labels}})|ConvertTo-Json -Depth 12 -AsArray
        $created=Register-LabOwnedHostContainer -StateRoot $root -Intent $intent -ContainerIdOrName $cid
        $same=Register-LabOwnedHostContainer -StateRoot $root -Intent $intent -ContainerIdOrName $cid
        Assert-Own ($created.ContainerId -ceq $cid -and $same.IntentSha256 -ceq $created.IntentSha256) 'Identischer eigener Create-Nachweis ist wiederlesbar ohne Ueberschreiben'
        $null=Assert-LabOwnedHostContainerEffect -StateRoot $root -RunId $allocated.RunId -Provider docker -ContainerId $cid
        Assert-Own ($script:lastStart.ArgumentList -contains $cid) 'Effektpruefung inspiziert erneut vollstaendige gebundene CID am gleichen Pin'
        $null=Invoke-LabContainerRuntimeCommand -Provider docker -StateRoot $root -RunId $allocated.RunId -ArgumentList @('exec','--user','mssql','synthetic-container','synthetic-command')
        Assert-Own ($script:lastStart.ArgumentList -contains $cid -and $script:lastStart.ArgumentList -notcontains 'synthetic-container') 'Bridge resolves public names to fresh receipt-bound full CID before exec'
        Assert-OwnThrows { Assert-LabOwnedHostContainerEffect -StateRoot $root -RunId $allocated.RunId -Provider docker -ContainerId 'aaaaaaaaaaaa' } 'OWNED_HOST_FULL_CID_REQUIRED' 'Verkuerzte ID erteilt keine Effektfreigabe'
        $labels.'sql-server-lab.owned-host-intent-id'=[guid]::NewGuid().ToString('D')
        $script:containerJson=@([pscustomobject]@{Id=$cid;Name='/synthetic-container';Config=[pscustomobject]@{Labels=$labels}})|ConvertTo-Json -Depth 12 -AsArray
        Assert-OwnThrows { Resolve-LabOwnedHostContainerEffect -StateRoot $root -RunId $allocated.RunId -Provider docker -ContainerIdOrName $cid } 'OWNED_HOST_CONTAINER_BINDING_DRIFT' 'Fremde Intentlabel trotz gleicher CID verweigert Start Stop Remove'
        $script:podmanCreateCalls=0;$script:podmanCreateArguments=@()
        $script:syntheticReply={param($StartInfo)
            $all=@($StartInfo.ArgumentList)
            if($all[0] -cne '--remote' -or $all[1] -cne '--url' -or $all[3] -cne '--identity'){throw 'UNEXPECTED_PODMAN_PIN_PREFIX'}
            $args=$all[5..($all.Count-1)];$body=''
            if($args[0] -ceq 'ps'){$body=''}
            elseif($args[0] -ceq 'image' -and $args[1] -ceq 'inspect'){$body='[{"Id":"'+('c'*64)+'"}]'}
            elseif($args[0] -ceq 'create'){$script:podmanCreateCalls++;$script:podmanCreateArguments=$args;$body='b'*64}
            else{throw 'UNEXPECTED_PODMAN_CREATE_FIXTURE_COMMAND'}
            [pscustomobject]@{ExitCode=0;Stdout=$body;Stderr=''}
        }
        $shellIntent=New-LabOwnedHostContainerIntent -StateRoot $root -RunId $allocated.RunId -ScopeId $allocatedState.scopeId -InstanceId 'synthetic-shell' -Provider podman -ContainerName 'synthetic-podman-shell'
        $shellPrefix=@('create','--name',$shellIntent.ContainerName,
            '--label',('sql-server-lab.run-id='+$shellIntent.RunId),'--label',('sql-server-lab.scope-id='+$shellIntent.ScopeId),
            '--label',('sql-server-lab.instance-id='+$shellIntent.InstanceId))+@(Get-LabOwnedHostContainerLabels -Intent $shellIntent)+@('--entrypoint','/bin/sh')
        $shellImage='sha256:'+('c'*64)
        $shellResult=Invoke-LabOwnedHostPinnedCommand -StateRoot $root -Provider podman -Arguments ($shellPrefix+@($shellImage,'-c','synthetic-guest-command'))
        Assert-Own ($shellResult.ExitCode -eq 0 -and $script:podmanCreateCalls -eq 1 -and
            ($script:podmanCreateArguments[-3..-1] -join '|') -ceq ($shellImage+'|-c|synthetic-guest-command')) 'Actual pinned Podman create carries guest shell arguments after validated immutable image'
        foreach($override in @('-c','-c=foreign')){
            Assert-OwnThrows { Invoke-LabOwnedHostPinnedCommand -StateRoot $root -Provider podman -Arguments ($shellPrefix+@($override,'foreign',$shellImage)) } 'OWNED_HOST_CREATE_OPTION_UNSUPPORTED' 'Actual create parser rejects short connection option before image'
        }
        Assert-OwnThrows { Invoke-LabOwnedHostPinnedCommand -StateRoot $root -Provider podman -Arguments ($shellPrefix+@('--connection=foreign',$shellImage)) } 'OWNED_HOST_ROUTE_OVERRIDE_FORBIDDEN' 'Actual Podman create keeps long connection override veto'
        Assert-Own ($script:podmanCreateCalls -eq 1) 'Rejected create route options never dispatch a second synthetic creation'
        $script:syntheticVolumes=@{}; $script:syntheticContainers=@{}; $script:syntheticEffects=@()
        $script:syntheticReply={param($StartInfo)
            $args=@($StartInfo.ArgumentList); $args=$args[2..($args.Count-1)]
            [IO.File]::AppendAllText((Join-Path $fixtureRoot 'synthetic-commands.private.jsonl'),(($args|ConvertTo-Json -Compress)+[Environment]::NewLine))
            $text=''
            if ($args[0] -ceq 'volume') {
                $name=$args[-1]
                if ($args[1] -ceq 'ls') {
                    if ($script:foreignVolume) {$text='synthetic-volume'}
                } elseif ($args[1] -ceq 'create') {
                    $volumeLabels=@{}
                    for($i=2;$i -lt $args.Count-1;$i++){if($args[$i] -ceq '--label'){$pair=$args[++$i] -split '=',2;$volumeLabels[$pair[0]]=$pair[1]}}
                    $script:syntheticVolumes[$name]=[pscustomobject]@{Name=$name;Labels=$volumeLabels}
                    $script:syntheticEffects+=@('volume-create');$text=$name
                } elseif ($args[1] -ceq 'inspect') {$text=ConvertTo-Json -InputObject @($script:syntheticVolumes[$name]) -Depth 12 -Compress}
            } elseif ($args[0] -ceq 'create') {
                $name=$args[2];$containerLabels=@{}
                for($i=3;$i -lt $args.Count;$i++){if($args[$i] -ceq '--label'){$pair=$args[++$i] -split '=',2;$containerLabels[$pair[0]]=$pair[1]}}
                $script:syntheticContainers['b'*64]=[pscustomobject]@{Id=('b'*64);Name=('/'+$name);Config=[pscustomobject]@{Labels=$containerLabels};State=[pscustomobject]@{Running=$false;ExitCode=0}}
                [IO.File]::WriteAllText((Join-Path $fixtureRoot 'synthetic-model.private.json'),($script:syntheticContainers|ConvertTo-Json -Depth 12))
                $script:syntheticEffects+=@('container-create');$text='b'*64
            } elseif ($args[0] -ceq 'inspect') {
                $requestedName=$args[1]
                $item=if($requestedName -cmatch '^[a-f0-9]{64}$'){$script:syntheticContainers[$requestedName]}else{@($script:syntheticContainers.Values|Where-Object {$_.Name -ceq ('/'+$requestedName)})[0]}
                $text=ConvertTo-Json -InputObject @($item) -Depth 12 -Compress
                [IO.File]::WriteAllText((Join-Path $fixtureRoot 'synthetic-inspect.private.json'),$text)
            } elseif ($args[0] -ceq 'image' -and $args[1] -ceq 'inspect') {
                $text='[{"Id":"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"}]'
            } elseif ($args[0] -ceq 'start') {$script:syntheticEffects+=@('container-start');$text='synthetic-output'
            } elseif ($args[0] -ceq 'rm') {$script:syntheticEffects+=@('container-remove');$script:syntheticContainers.Remove($args[-1])
            } elseif ($args[0] -ceq 'ps') {
                if($script:syntheticContainers.Count){$text='b'*64}
            }
            [pscustomobject]@{ExitCode=0;Stdout=$text;Stderr=''}
        }
        $createdVolume=Initialize-LabOwnedHostSqlVolume -StateRoot $root -RunId $allocated.RunId -ScopeId $allocatedState.scopeId -Provider docker -VolumeName 'synthetic-volume' -Image ('sha256:'+('c'*64)) -InstanceId 'synthetic-instance' -VersionId '2025' -ContainerPath '/var/opt/mssql'
        $volume=Get-LabOwnedHostVolumeReceipt -StateRoot $root -Provider docker -VolumeName 'synthetic-volume'
        Assert-Own ($createdVolume -and $volume.Intent.RunId -ceq $allocated.RunId -and
            ($script:syntheticEffects -join '|') -ceq 'volume-create|container-create|container-start|container-remove') 'Eigener Volume-Creation-Nachweis bleibt nach voller CID-Probe-Kompensation erhalten'
        $beforeEffects=$script:syntheticEffects.Count
        $script:foreignVolume=$true
        Assert-OwnThrows { Initialize-LabOwnedHostSqlVolume -StateRoot $root -RunId $allocated.RunId -ScopeId $allocatedState.scopeId -Provider docker -VolumeName 'foreign-volume' -Image ('sha256:'+('c'*64)) -InstanceId 'synthetic-instance' -VersionId '2025' -ContainerPath '/var/opt/mssql' } 'OWNED_HOST_VOLUME_ABSENCE_UNVERIFIABLE' 'Vorhandenes Volume wird trotz aehnlichem Namen nicht adoptiert'
        Assert-Own ($script:syntheticEffects.Count -eq $beforeEffects) 'Volume-Kollision erzeugt keine Create Start oder Remove-Effekte'
        Assert-OwnThrows { Assert-LabOwnedHostContainerCreateInputs -StateRoot $root -Provider docker -Arguments @('create','--volume',($fixtureRoot+':/shared:rw'),('sha256:'+('c'*64))) } 'OWNED_HOST_BIND_WRITE_OUTSIDE_ROOT' 'Container creation denies shared host write mount before dispatch'
        Assert-OwnThrows { Assert-LabOwnedHostContainerCreateInputs -StateRoot $root -Provider docker -Arguments @('create','--privileged',('sha256:'+('c'*64))) } 'OWNED_HOST_CREATE_OPTION_UNSUPPORTED' 'Privileged container cannot inherit own CID authority'
        Assert-OwnThrows { Assert-LabOwnedHostContainerCreateInputs -StateRoot $root -Provider docker -Arguments @('create','shared:latest') } 'OWNED_HOST_IMMUTABLE_CONTAINER_IMAGE_REQUIRED' 'Mutable image cannot cause an implicit pull at container arrange'
        $backupFixture=New-Module -ArgumentList $repoRoot,$root,$allocated.RunId,$fixtureRoot -ScriptBlock {
            param($Repository,$Root,$RunId,$OutsideRoot)
            foreach($source in @('Common','StateMachine','ContainerOwnedHostIntegration','BackupLibrary')) { . (Join-Path $Repository ('Private/'+$source+'.ps1')) }
            $script:effects=0;$script:exportPath=$null;$script:failExport=$false;$script:failCleanup=$false;$script:compoundFailure=$false
            $actualPolicyReader=(Get-Command Get-LabOwnedHostPolicy).ScriptBlock
            function Get-LabOwnedHostPolicy {
                param($StateRoot,[switch]$Required)
                if($Required -and $script:failCleanup){throw 'SYNTHETIC_BACKUP_CLEANUP_FAILED'}
                & $actualPolicyReader -StateRoot $StateRoot -Required:$Required
            }
            function Get-LabDatabaseBackupMetadata { $script:effects++; [pscustomobject]@{IsEncrypted=$false} }
            function Get-LabDatabaseMigrationDependencySqlObservation { [pscustomobject]@{} }
            function New-LabDatabaseMigrationDependencyInventory { [pscustomobject]@{} }
            function Initialize-LabSampleBaselineBackupTarget { [pscustomobject]@{Provider='docker'} }
            function Invoke-SqlQuery { $script:effects++ }
            function Export-LabSampleBaselineBackup {
                param($DestinationPath)
                $script:effects++;$script:exportPath=$DestinationPath
                [IO.File]::WriteAllText($DestinationPath,'synthetic backup')
                if($script:failExport){$script:failCleanup=$script:compoundFailure;throw 'SYNTHETIC_BACKUP_EXPORT_FAILED'}
                [pscustomobject]@{Provider='docker'}
            }
            function Register-LabDatabaseBackupArtifact {
                param($BackupPath)
                $script:effects++
                [pscustomobject]@{Path=$BackupPath;Record=[pscustomobject]@{BackupSetId=[guid]::NewGuid().ToString('D');Artifact=[pscustomobject]@{Sha256=('a'*64);Bytes=16};DatabaseMetadata=[pscustomobject]@{HasFileStream=$false;MigrationBoundary='synthetic'}}}
            }
            $secret=[Security.SecureString]::new()
            foreach($character in 'Synthetic_Backup!Aa8'.ToCharArray()){$secret.AppendChar($character)}
            $secret.MakeReadOnly()
            $arguments=@{Port=14333;SaPassword=$secret;Provider='docker';RunId=$RunId;DatabaseName='SyntheticBackup';DataRoot=(Join-Path $Root 'Lab_Data');StateRoot=$Root}
            $result=New-LabDatabaseLibraryBackup @arguments
            $workingDirectory=Split-Path -Parent $script:exportPath
            $relative=[IO.Path]::GetRelativePath($Root,$workingDirectory)
            $script:checks=@($result.Status -ceq 'BACKUP_REUSABLE' -and -not [IO.Path]::IsPathRooted($relative) -and -not $relative.StartsWith('..') -and -not (Test-Path $workingDirectory))
            $before=$script:effects;$arguments.DataRoot=$OutsideRoot
            $denied=$false
            try{$null=New-LabDatabaseLibraryBackup @arguments}catch{$denied=$_.Exception.Message -ceq 'OWNED_HOST_BACKUP_DATA_ROOT_OUTSIDE_ROOT'}
            $script:checks+=@($denied -and $script:effects -eq $before)
            $arguments.DataRoot=Join-Path $Root 'Lab_Data';$arguments.RunId=''
            $denied=$false
            try{$null=New-LabDatabaseLibraryBackup @arguments}catch{$denied=$_.Exception.Message -ceq 'OWNED_HOST_BACKUP_RUN_REQUIRED'}
            $script:checks+=@($denied -and $script:effects -eq $before)
            $arguments.RunId=$RunId;$script:failExport=$true
            $failed=$false
            try{$null=New-LabDatabaseLibraryBackup @arguments}catch{$failed=$_.Exception.Message -ceq 'SYNTHETIC_BACKUP_EXPORT_FAILED'}
            $script:checks+=@($failed -and -not(Test-Path (Split-Path -Parent $script:exportPath)))
            $script:compoundFailure=$true
            $compound=$null
            try{$null=New-LabDatabaseLibraryBackup @arguments}catch{$compound=$_}
            $script:checks+=@($compound.Exception.Message -ceq 'SYNTHETIC_BACKUP_EXPORT_FAILED' -and
                $compound.Exception.Data['SqlServerLab.BackupCleanupStatus'] -ceq 'RECOVERY_REQUIRED' -and
                $compound.Exception.Data['SqlServerLab.BackupCleanupReason'] -ceq 'SYNTHETIC_BACKUP_CLEANUP_FAILED' -and
                (Test-Path -LiteralPath $script:exportPath))
            $script:failCleanup=$false
            $preservedDirectory=Split-Path -Parent $script:exportPath
            $null=Assert-LabOwnedHostPath $preservedDirectory
            if([IO.Path]::GetRelativePath($Root,$preservedDirectory).StartsWith('..')){throw 'SYNTHETIC_BACKUP_CLEANUP_SCOPE'}
            if(Test-Path -LiteralPath $preservedDirectory){Remove-Item -LiteralPath $preservedDirectory -Recurse -Force}
            Export-ModuleMember -Function @()
        }
        $backupEvidence=& $backupFixture { $script:checks }
        Assert-Own $backupEvidence[0] 'Actual backup core exports below own root and removes its temporary directory'
        Assert-Own $backupEvidence[1] 'Actual backup core denies shared DataRoot before SQL or export effects'
        Assert-Own $backupEvidence[2] 'Actual backup core requires bound own RunId before SQL or export effects'
        Assert-Own $backupEvidence[3] 'Actual backup core cleans temporary files after export failure without replacing the cause'
        Assert-Own $backupEvidence[4] 'Compound export and cleanup failures preserve original cause plus separate recovery metadata and retain files'
        $packageAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot 'Tests/Integration/Invoke-ContainerDatabasePackageExportAcceptance.ps1'),[ref]$null,[ref]$null)
        $copyFaultNodes=@($packageAst.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Invoke-LabOwnedHostNativeProcess'},$true))
        if($copyFaultNodes.Count -ne 1){throw 'PACKAGE_COPY_FAULT_FIXTURE_SHAPE'}
        $copyFaultFixture=New-Module -ArgumentList ([scriptblock]::Create($copyFaultNodes[0].Extent.Text)) -ScriptBlock {
            param($Definition)
            $originalOwnedNative={param($StartInfo,$TimeoutSeconds,$MaximumBytes)$script:forwarded++;[pscustomobject]@{ExitCode=0;Stdout='synthetic delegated';Stderr=''}}
            . $Definition
            $script:packageCopyInvocation='synthetic-runtime';$script:packageCopyContainerId='a'*64
            $script:checks=@()
            foreach($case in @('docker','podman','foreign-route','foreign-container','other-command','foreign-invocation')){
                $script:forwarded=0;$script:packageNativeCopyFault=$false
                $script:packageCopyPrefix=if($case -ceq 'podman'){@('--remote','--url','ssh://synthetic@127.0.0.1:22222','--identity','synthetic-key')}else{@('--host','npipe://synthetic')}
                $start=[Diagnostics.ProcessStartInfo]::new($script:packageCopyInvocation)
                foreach($argument in $script:packageCopyPrefix){$start.ArgumentList.Add($argument)}
                $start.ArgumentList.Add('cp');$start.ArgumentList.Add($script:packageCopyContainerId+':/synthetic.mdf');$start.ArgumentList.Add('synthetic-target')
                switch($case){
                    'foreign-route'{$start.ArgumentList[1]='npipe://foreign'}
                    'foreign-container'{$start.ArgumentList[$script:packageCopyPrefix.Count+1]=('b'*64)+':/synthetic.mdf'}
                    'other-command'{$start.ArgumentList[$script:packageCopyPrefix.Count]='inspect'}
                    'foreign-invocation'{$start.FileName='foreign-runtime'}
                }
                $result=Invoke-LabOwnedHostNativeProcess -StartInfo $start -TimeoutSeconds 10
                $expectedFault=$case -cin @('docker','podman')
                $script:checks+=@([pscustomobject]@{Case=$case;Passed=($script:packageNativeCopyFault -eq $expectedFault -and $script:forwarded -eq [int](-not $expectedFault) -and $result.ExitCode -eq [int]$expectedFault)})
            }
            Export-ModuleMember -Function @()
        }
        foreach($check in (& $copyFaultFixture {$script:checks})){Assert-Own $check.Passed ('Actual package copy fault intercepts only exact prepared own copy: '+$check.Case)}
        $script:foreignVolume=$false
        $script:syntheticTask=$null;$script:taskRegisters=0;$script:taskDeletes=0
        function Get-ScheduledTask {param($TaskPath,$TaskName,$ErrorAction) if($script:syntheticTask){$script:syntheticTask}}
        function New-ScheduledTaskAction {param($Execute,$Argument) [pscustomobject]@{Execute=$Execute;Arguments=$Argument;WorkingDirectory=''}}
        function New-ScheduledTaskTrigger {param([switch]$AtLogOn,$User) [pscustomobject]@{UserId=$User;CimClass=[pscustomobject]@{CimClassName='MSFT_TaskLogonTrigger'}}}
        function New-ScheduledTaskPrincipal {param($UserId,$LogonType,$RunLevel) [pscustomobject]@{UserId=$UserId;LogonType=$LogonType;RunLevel=$RunLevel}}
        function New-ScheduledTaskSettingsSet {param($ExecutionTimeLimit,$MultipleInstances) [pscustomobject]@{ExecutionTimeLimit=$ExecutionTimeLimit;MultipleInstances=$MultipleInstances}}
        function Register-ScheduledTask {param($TaskPath,$TaskName,$Action,$Trigger,$Principal,$Settings,$Description,$ErrorAction)
            $script:taskRegisters++;$script:syntheticTask=[pscustomobject]@{TaskPath=$TaskPath;TaskName=$TaskName;Actions=@($Action);Triggers=@($Trigger);Principal=$Principal}
        }
        function Unregister-ScheduledTask {
            [CmdletBinding(SupportsShouldProcess)]
            param($TaskPath,$TaskName)
            $script:taskDeletes++;$script:syntheticTask=$null
        }
        $task=Enable-LabOwnedHostAutoStart -StateRoot $root -RunId $allocated.RunId -Provider docker
        Assert-Own ($script:taskRegisters -eq 1 -and -not $task.LogonDispatchProven -and $task.TaskName.Contains($allocated.RunId.Replace('-',''))) 'Own-Task verwendet eigenen Run-Namen und behauptet keinen Logondispatch'
        $script:syntheticTask.Actions[0].Arguments='synthetic-foreign-action'
        Assert-OwnThrows { Remove-LabOwnedHostAutoStartIfUnused -StateRoot $root -RunId $allocated.RunId -Provider docker } 'OWNED_HOST_TASK_BINDING_DRIFT' 'Task mit abweichender Aktion wird nicht entfernt'
        Assert-Own ($script:taskDeletes -eq 0) 'Task-Drift hat zero Unregister-Aufrufe'
        $taskIntent=Read-LabOwnedHostRecord (Join-Path $allocated.RunDir 'owned-host-tasks/docker.intent.json')
        $script:syntheticTask.Actions[0].Arguments=$taskIntent.Arguments
        $ownerAccount=[Security.Principal.WindowsIdentity]::GetCurrent().Name
        $script:syntheticTask.Principal.UserId=$ownerAccount
        $script:syntheticTask.Triggers[0].UserId=$ownerAccount
        $revalidatedTask=Enable-LabOwnedHostAutoStart -StateRoot $root -RunId $allocated.RunId -Provider docker
        Assert-Own ($revalidatedTask.Enabled -and $script:taskRegisters -eq 1) 'Task account-name observations resolve to the exact owner SID without duplicate registration'
        $script:syntheticTask.Principal.UserId='S-1-5-21-101-202-303-404'
        Assert-OwnThrows { Remove-LabOwnedHostAutoStartIfUnused -StateRoot $root -RunId $allocated.RunId -Provider docker } 'OWNED_HOST_TASK_BINDING_DRIFT' 'Different principal SID cannot inherit own-task authority'
        $script:syntheticTask.Principal.UserId=$ownerAccount
        $script:syntheticTask.Triggers[0].UserId='S-1-5-21-101-202-303-404'
        Assert-OwnThrows { Remove-LabOwnedHostAutoStartIfUnused -StateRoot $root -RunId $allocated.RunId -Provider docker } 'OWNED_HOST_TASK_BINDING_DRIFT' 'Different trigger SID cannot inherit own-task authority'
        $script:syntheticTask.Triggers[0].UserId=($env:COMPUTERNAME+'\SQL_Server_Lab_Unmapped_'+[guid]::NewGuid().ToString('N'))
        Assert-OwnThrows { Remove-LabOwnedHostAutoStartIfUnused -StateRoot $root -RunId $allocated.RunId -Provider docker } 'OWNED_HOST_TASK_BINDING_DRIFT' 'Unmapped trigger account fails closed before unregister'
        $script:syntheticTask.Triggers[0].UserId=''
        Assert-OwnThrows { Remove-LabOwnedHostAutoStartIfUnused -StateRoot $root -RunId $allocated.RunId -Provider docker } 'OWNED_HOST_TASK_BINDING_DRIFT' 'Empty trigger account fails closed before unregister'
        Assert-Own ($script:taskDeletes -eq 0) 'Account and SID drift checks perform no unregister'
        $script:syntheticTask.Triggers[0].UserId=$ownerAccount
        $script:syntheticTask.Principal.RunLevel='Highest'
        Assert-OwnThrows { Remove-LabOwnedHostAutoStartIfUnused -StateRoot $root -RunId $allocated.RunId -Provider docker } 'OWNED_HOST_TASK_BINDING_DRIFT' 'Task principal elevation drift cannot inherit intention authority'
        $script:syntheticTask.Principal.RunLevel='Limited'
        $createdTaskPath=Join-Path $allocated.RunDir 'owned-host-tasks/docker.created.json'
        $createdTaskText=[IO.File]::ReadAllText($createdTaskPath)
        $createdTask=Read-LabOwnedHostRecord $createdTaskPath
        $createdTask.IntentSha256='0'*64
        [IO.File]::WriteAllText($createdTaskPath,($createdTask|ConvertTo-Json))
        Assert-OwnThrows { Remove-LabOwnedHostAutoStartIfUnused -StateRoot $root -RunId $allocated.RunId -Provider docker } 'OWNED_HOST_TASK_RECEIPT_DRIFT' 'Task receipt hash drift denies unregister'
        [IO.File]::WriteAllText($createdTaskPath,$createdTaskText)
        Remove-LabOwnedHostAutoStartIfUnused -StateRoot $root -RunId $allocated.RunId -Provider docker
        Assert-Own ($script:taskDeletes -eq 1 -and (Test-Path $taskIntent.ScriptPath)) 'Nur eigener gebundener Task wird entfernt; Recovery-Script bleibt erhalten'
        $script:syntheticReply=$null
        $script:syntheticReply={param($start)
            $argv=@($start.ArgumentList)
            if($argv -contains 'machine'){$body='[{"Name":"synthetic-machine","Running":true,"Port":2222,"VMType":"wsl"}]'}
            elseif($start.FileName -ceq $podman){$body='{"Version":{"Version":"synthetic-1"},"Store":{"GraphDriverName":"overlay","GraphRoot":"synthetic-root"},"Host":{"Security":{"Rootless":true}}}'}
            else{$body='{"OperatingSystem":"Docker Desktop","ServerVersion":"synthetic-1","Driver":"overlay2","DockerRootDir":"synthetic-root"}'}
            [pscustomobject]@{ExitCode=0;Stdout=$body;Stderr=''}
        }.GetNewClosure()
        foreach($provider in @('docker','podman')){
            $scope=Get-LabContainerRuntimeScope -Provider $provider -StateRoot $root
            Assert-Own ($scope.Status -ceq 'AVAILABLE' -and $scope.Binding.SelectedBy -ceq 'EXPLICIT_POLICY_PIN' -and $scope.Binding.DisplayName -ceq ('owned-policy-'+$policy.PolicyId) -and
                $scope.Ownership.MutationPolicy -ceq 'REPORT_ONLY' -and -not $scope.Summary.CanManageRuntime -and $scope.Binding.ConnectionCount -eq 0) "Scope $provider is truthful explicit projection without default discovery"
            $schema=Join-Path $repoRoot 'Schemas/container-runtime-scope.schema.json'
            Assert-Own (($scope|ConvertTo-Json -Depth 16)|Test-Json -SchemaFile $schema) "Scope $provider preserves coupled DTO schema"
            $expected=Get-LabContainerRuntimeScopeId -Provider $provider -IdentityKey ('owned-policy-'+$policy.PolicyId+'|'+(@($pins|Where-Object Provider -ceq $provider)[0].Endpoint)+'|'+$scope.Binding.BackendKind)
            Assert-Own ($scope.RuntimeId -ceq $expected) "Scope $provider preserves established identity formula"
        }
        $context=Get-LabRetainedStoreRuntimeContext -Provider docker -StateRoot $root
        Assert-Own ($context.StateRoot -ceq $root -and $context.RuntimeScopeId -cmatch '^runtime-scope-[a-f0-9]{24}$' -and @($context.Arguments).Count -eq 0) 'Retained store context retains actual pin route without default arguments'
        Assert-OwnThrows { Invoke-LabContainerInstanceStoreClone -Plan ([pscustomobject]@{}) -OperationDirectory $fixtureRoot -Configuration ([pscustomobject]@{}) -StateRoot $root } 'OWNED_HOST_INSTANCE_STORE_CLONE_UNSUPPORTED' 'Unsupported OwnRoot clone fails before journal or provider effects'
        $script:syntheticReply=$null
        $policyPath = Join-Path $root 'owned-host-policy.json'
        $original = [IO.File]::ReadAllText($policyPath)
        [IO.File]::WriteAllText($policyPath, $original.Replace(':2222/',':99999/'))
        Assert-OwnThrows { Get-LabOwnedHostPolicy -StateRoot $root -Required } 'OWNED_HOST_PODMAN_PIN_INVALID' 'Invalid loopback SSH port fails before transport'
        [IO.File]::WriteAllText($policyPath,$original)
        [IO.File]::WriteAllText($policyPath, $original.Replace('pipe/synthetic','pipe/synthetic-changed'))
        Assert-OwnThrows { Get-LabOwnedHostRunPolicy -RunId $allocated.RunId -StateRoot $root } 'OWNED_HOST_RUN_REFERENCE_DRIFT' 'Policyinhalt mit gleichen IDs ist Run-Drift'
        [IO.File]::WriteAllText($policyPath,$original)
        [IO.File]::Move($policyPath,(Join-Path $root 'policy-preserved.private.json'))
        Assert-OwnThrows { Get-LabOwnedHostRunPolicy -RunId $allocated.RunId -StateRoot $root } 'OWNED_HOST_POLICY_MISSING' 'Markierter Run faellt nach Profileverlust nicht auf Standard zurueck'
        Assert-OwnThrows { Get-LabOwnedHostPolicy -StateRoot $root } 'OWNED_HOST_POLICY_MISSING' 'Root marker vetoes optional policy fallback after loss'
        Assert-OwnThrows { New-LabRunState -StateRoot $root } 'OWNED_HOST_POLICY_MISSING' 'Root marker vetoes new unprofiled run after loss'
    }
    else {
        Assert-OwnThrows { Initialize-LabOwnedHostPolicy -StateRoot (Join-Path $fixtureRoot 'unsupported') -RuntimePins @([pscustomobject]@{}) } 'OWNED_HOST_PLATFORM_UNSUPPORTED' 'Windowsprofil lehnt andere Hosts vor Rootmutation ab'
    }
    [pscustomobject]@{Passed=$script:passed;NativeProviderCalls=0;NativeTaskCalls=0;SyntheticTransports=$script:transportCalls}
}
& $module { [pscustomobject]@{Passed=$script:passed;SyntheticTransports=$script:transportCalls} } | ConvertTo-Json -Compress
# Eigene synthetische Artefakte bleiben lokal ignoriert, kein Cleanup-Erfolg behauptet.
