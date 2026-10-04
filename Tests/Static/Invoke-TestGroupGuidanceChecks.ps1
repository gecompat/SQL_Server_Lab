#Requires -Version 7.2
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-group-guidance-' + [guid]::NewGuid().ToString('N'))
try {
    $null = New-Item -ItemType Directory -Path $testRoot
    $module = Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru
    & $module {
        param($Root)
        $script:groupTestRoot = $Root; $script:groupCalls = @(); $script:groupPower = @{ docker='STOPPED'; podman='STOPPED' }; $script:groupFail = ''; $script:groupExtra = $false
        $script:groupRuns = @{ docker=[guid]::NewGuid().ToString(); podman=[guid]::NewGuid().ToString() }
        $script:groupIds = @{ docker=('a'*64); podman=('b'*64) }; $script:groupScope = [guid]::NewGuid().ToString()
        function Get-LabStateRoot { Join-Path $script:groupTestRoot 'State' }
        function Get-LabDataRootDefault { Join-Path $script:groupTestRoot 'Lab_Data' }
        function Get-LabConnectionCenterCmsConfiguration { param($StateRoot) return $null }
        function Get-LabHostToolInvocation { param($Name) if ($Name -eq 'docker') { 'Invoke-GroupDocker' } else { 'Invoke-GroupPodman' } }
        function Invoke-GroupDocker { Invoke-GroupNative -Provider docker -Arguments $args }
        function Invoke-GroupPodman { Invoke-GroupNative -Provider podman -Arguments $args }
        function Invoke-GroupNative {
            param($Provider,$Arguments)
            $global:LASTEXITCODE = 0
            if ($Arguments[0] -eq 'ps') { $script:groupIds[$Provider]; if ($script:groupExtra) { 'unexpected-id' }; return }
            if ($Arguments[-1] -ne $script:groupIds[$Provider]) { throw 'Mutation did not use immutable ID' }
            $script:groupCalls += "$Provider/$($Arguments[0])"
            if ($script:groupFail -eq $Provider) { $global:LASTEXITCODE=1; return }
            $script:groupPower[$Provider] = if ($Arguments[0] -eq 'start') { 'RUNNING' } else { 'STOPPED' }
        }
        function Get-GroupInspect {
            param($Provider)
            [pscustomobject]@{ Available=$true; Exists=$true; Inspect=[pscustomobject]@{
                Id=$script:groupIds[$Provider]; State=@{Status=$(if ($script:groupPower[$Provider] -eq 'RUNNING') {'running'} else {'exited'})}
                Config=@{Labels=@{'sql-server-lab.run-id'=$script:groupRuns[$Provider];'sql-server-lab.scope-id'=$script:groupScope;'sql-server-lab.instance-id'='primary'}}
            } }
        }
        function Get-DockerInstanceStatus { param($ContainerIdOrName) Get-GroupInspect docker }
        function Get-PodmanInstanceStatus { param($ContainerIdOrName) Get-GroupInspect podman }
        function Invoke-LabProviderOperation { param($Provider,$Phase,$RunId,[switch]$Native,$Command,$Action) & $Action | Out-Null; [pscustomobject]@{Succeeded=($global:LASTEXITCODE -eq 0);ExitCode=$global:LASTEXITCODE;Output=@()} }
        foreach ($forbidden in @('Get-LabRunRuntimeStatus','Get-HyperVLabWorkflowRun','Export-SqlServerLabTestEnvironment','Sync-LabRunRuntimeState','Sync-LabAutomatedTestEnvironmentConnectionCenter','Wait-SqlReady','Invoke-LabStoppedHostMemoryRelease')) { Set-Item "Function:$forbidden" { throw 'Forbidden implicit effect' } }
        $directory = Get-LabTestEnvironmentExportDirectory
        $null = New-Item -ItemType Directory -Path $directory -Force
        $entries = @()
        foreach ($provider in @('docker','podman')) {
            $id = $script:groupRuns[$provider]; $runPath = Join-Path (Join-Path (Get-LabStateRoot) 'runs') $id
            $null = New-Item -ItemType Directory -Path $runPath -Force
            @{runId=$id;scopeId=$script:groupScope;state='STOPPED';metadata=@{};providerSubRuns=@(@{provider=$provider;state='STOPPED'})} | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $runPath 'run-state.json')
            @{instances=@(@{id='primary';provider=$provider;containerId=$script:groupIds[$provider]})} | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $runPath 'connection-info.json')
            $entries += @{key=$provider.ToUpperInvariant();runId=$id;platform='linux';instanceId='primary';sqlVersion='2025'}
        }
        $registryPath = Get-LabTestEnvironmentRegistryPath
        @{contractVersion='SqlServerLab.TestEnvironmentRegistry/1.0';environments=$entries} | ConvertTo-Json -Depth 10 | Set-Content $registryPath
        $script:groupChecks = 0
        function Check-Group { param($Condition,$Message) if (-not $Condition) { throw $Message }; $script:groupChecks++ }
        function Reject-Group { param([scriptblock]$Action) try { & $Action; throw 'EXPECTED_REJECTION_MISSING' } catch { if ($_.Exception.Message -eq 'EXPECTED_REJECTION_MISSING') { throw } }; $script:groupChecks++ }
        $before = (Get-FileHash $registryPath).Hash
        $plan = Get-LabTestGroupPowerPlan
        Check-Group ($plan.CanApply -and $plan.Total -eq 2 -and $plan.PowerStatus -eq 'STOPPED' -and $plan.SqlReadiness -eq 'NOT_CHECKED') 'Measured group preview failed'
        $cancel = Invoke-LabTestGroupPowerPlan -PowerAction Start -ExpectedPlanKey $plan.PlanKey
        Check-Group ($cancel.Status -eq 'CANCELLED' -and -not $script:groupCalls.Count) 'Cancel mutated'
        $stopPlan = Get-LabTestGroupPowerPlan -PowerAction Stop
        $noop = Invoke-LabTestGroupPowerPlan -PowerAction Stop -ExpectedPlanKey $stopPlan.PlanKey -Confirmed
        Check-Group ($noop.Status -eq 'NO_OP' -and -not $script:groupCalls.Count) 'No-op reached provider'
        $script:groupExtra = $true
        Check-Group (-not (Get-LabTestGroupPowerPlan).CanApply) 'Extra runtime accepted'
        Reject-Group { Invoke-LabTestGroupPowerPlan -PowerAction Start -ExpectedPlanKey $plan.PlanKey -Confirmed }
        $script:groupExtra = $false
        $script:groupPower.docker = 'RUNNING'
        Reject-Group { Invoke-LabTestGroupPowerPlan -PowerAction Start -ExpectedPlanKey $plan.PlanKey -Confirmed }
        $script:groupPower.docker = 'STOPPED'; $script:groupFail = 'podman'
        $plan = Get-LabTestGroupPowerPlan
        $partial = Invoke-LabTestGroupPowerPlan -PowerAction Start -ExpectedPlanKey $plan.PlanKey -Confirmed
        Check-Group ($partial.Status -eq 'PARTIAL' -and $partial.Details.Count -eq 2 -and $partial.Details[0].Status -eq 'RUNNING' -and $partial.Details[1].Attempted) 'Partial member results missing'
        $script:groupFail = ''; $script:groupCalls = @(); $plan = Get-LabTestGroupPowerPlan
        $retry = Invoke-LabTestGroupPowerPlan -PowerAction Start -ExpectedPlanKey $plan.PlanKey -Confirmed
        Check-Group ($retry.Status -eq 'COMPLETED' -and $script:groupCalls.Count -eq 1 -and $script:groupCalls[0] -eq 'podman/start') 'Fresh retry restarted fulfilled member'
        $plan = Get-LabTestGroupPowerPlan -PowerAction Stop
        $stop = Invoke-LabTestGroupPowerPlan -PowerAction Stop -ExpectedPlanKey $plan.PlanKey -Confirmed
        Check-Group ($stop.Status -eq 'COMPLETED' -and $script:groupPower.docker -eq 'STOPPED' -and $script:groupPower.podman -eq 'STOPPED') 'Group power stop failed'
        Check-Group ((Get-FileHash $registryPath).Hash -eq $before -and -not $script:LabAutomatedTestEnvironmentGroupOperation) 'Registry changed or global bypass set'
        $runPath = Join-Path (Join-Path (Get-LabStateRoot) 'runs') $script:groupRuns.docker
        $statePath = Join-Path $runPath 'run-state.json'; $original = Get-Content $statePath -Raw
        $state = $original | ConvertFrom-Json; $state.state='RECOVERY_REQUIRED'; $state | ConvertTo-Json -Depth 10 | Set-Content $statePath
        Check-Group (-not (Get-LabTestGroupPowerPlan).CanApply) 'Recovery allowed'
        Set-Content $statePath $original -NoNewline
        $connectionPath = Join-Path $runPath 'connection-info.json'; $original = Get-Content $connectionPath -Raw
        $connection = $original | ConvertFrom-Json; $connection.instances += $connection.instances[0]; $connection | ConvertTo-Json -Depth 10 | Set-Content $connectionPath
        Check-Group (-not (Get-LabTestGroupPowerPlan).CanApply) 'Multi-instance run accepted'
        Set-Content $connectionPath $original -NoNewline
        $plan = Get-LabTestGroupPowerPlan
        $registryOriginal = Get-Content $registryPath -Raw; Add-Content $registryPath ' '
        Reject-Group { Invoke-LabTestGroupPowerPlan -PowerAction Start -ExpectedPlanKey $plan.PlanKey -Confirmed }
        Set-Content $registryPath $registryOriginal -NoNewline
        # Lock conflict runs in another runspace; both canonical aliases share one mutex.
        $lock = Enter-LabTestGroupLock
        try {
            $worker = [powershell]::Create()
            try {
                $null = $worker.AddScript({ param($Module,$Directory) Import-Module $Module -Force; & (Get-Module SqlServerLab) { param($d)
                    foreach ($name in @('Register-LabTestEnvironmentIntent','Register-LabTestEnvironmentRun','Clear-SqlServerLabAutomatedTestEnvironment','Repair-SqlServerLabAutomatedTestEnvironment','Start-SqlServerLabAutomatedTestEnvironment','Stop-SqlServerLabAutomatedTestEnvironment')) {
                        $arguments = @{OutputDirectory=$d}
                        if ($name -like 'Register-*') { $arguments.Platform='linux';$arguments.SqlVersion='2025';$arguments.Patch='latest';$arguments.InstanceId='primary';if ($name -eq 'Register-LabTestEnvironmentRun') {$arguments.RunId=[guid]::NewGuid().ToString()} }
                        else { $arguments.WhatIf=$true }
                        try { & $name @arguments | Out-Null; 'UNEXPECTED' } catch { $_.Exception.Message }
                    }
                } $Directory }).AddArgument((Join-Path $script:ModuleRoot 'SqlServerLab.psd1')).AddArgument(($directory + [IO.Path]::DirectorySeparatorChar))
                $answer = @($worker.Invoke())
                Check-Group ($answer.Count -eq 6 -and @($answer | Where-Object { $_ -ne 'TEST_GROUP_BUSY' }).Count -eq 0) 'Actual registry/lifecycle writers escaped alias lock'
            } finally { $worker.Dispose() }
        } finally { Exit-LabTestGroupLock $lock }
        if ($IsWindows) {
            $name = 'Global\SqlServerLab.TestGroup.' + (Get-LabWorkflowHash -Text (Get-LabCanonicalResourceRoot -StateRoot $directory) -Length 32)
            $lock = Enter-LabTestGroupLock
            try { $globalLock = [Threading.Mutex]::OpenExisting($name); $globalLock.Dispose(); Check-Group $true 'Global namespace mutex missing' }
            finally { Exit-LabTestGroupLock $lock }
        }
        $alias = Join-Path $script:groupTestRoot 'group-alias'
        $null = New-Item -ItemType $(if ($IsWindows) {'Junction'} else {'SymbolicLink'}) -Path $alias -Target $directory
        try {
            foreach ($name in @('Register-LabTestEnvironmentIntent','Register-LabTestEnvironmentRun','Clear-SqlServerLabAutomatedTestEnvironment','Repair-SqlServerLabAutomatedTestEnvironment','Start-SqlServerLabAutomatedTestEnvironment','Stop-SqlServerLabAutomatedTestEnvironment')) {
                $arguments = @{OutputDirectory=$alias}
                if ($name -like 'Register-*') { $arguments.Platform='linux';$arguments.SqlVersion='2025';$arguments.Patch='latest';$arguments.InstanceId='primary';if ($name -eq 'Register-LabTestEnvironmentRun') {$arguments.RunId=[guid]::NewGuid().ToString()} } else { $arguments.WhatIf=$true }
                $reason=''; try { & $name @arguments | Out-Null } catch { $reason=$_.Exception.Message }
                Check-Group ($reason -eq 'TEST_GROUP_REPARSE_POINT') 'Registry writer accepted linked authority'
            }
            $reason=''; try { Get-LabTestGroupPowerPlan -OutputDirectory $alias | Out-Null } catch { $reason=$_.Exception.Message }
            Check-Group ($reason -eq 'TEST_GROUP_REPARSE_POINT') 'Guidance accepted linked authority'
        } finally { Remove-Item -LiteralPath $alias -Force }
        # Real CLI handler, only console boundaries mocked.
        $script:groupChoices = [Collections.Generic.Queue[string]]::new(); @('refresh','Stop','Start','back') | ForEach-Object { $script:groupChoices.Enqueue($_) }
        function Select-LabConsoleDataItem { param($ScreenId,$Title,$Items) $Items[0].Data }
        $script:groupRealMenu = (Get-Command Invoke-LabConsoleMenu).ScriptBlock
        $script:groupFrames = [Collections.Generic.List[object]]::new()
        function Update-LabConsoleAttentionSnapshot { return $null }
        function Invoke-LabConsoleMenu {
            param($ScreenId,$Title,$Subtitle,$Items)
            if ($script:groupFallback) {
                return & $script:groupRealMenu -ScreenId $ScreenId -Title $Title -Subtitle $Subtitle -Items $Items -Snapshot $null -ForceFallback -ReadInput { $script:groupChoices.Dequeue() }
            }
            & $script:groupRealMenu -ScreenId $ScreenId -Title $Title -Subtitle $Subtitle -Items $Items -Snapshot $null `
                -Capability ([pscustomobject]@{Supported=$true;Mode='CURSOR'}) -GetViewport { [pscustomobject]@{Width=140;Height=30} } `
                -SessionFactory { [pscustomobject]@{OriginTop=0;PreviousLineCount=0;ForegroundColor='Gray'} } -SessionCompleter {} `
                -FrameWriter { param($s,$f) $script:groupFrames.Add($f) } -ReadKey {
                    switch ($script:groupChoices.Dequeue()) {
                        refresh { [pscustomobject]@{Key='F5';KeyChar=[char]0;Modifiers=0} }
                        back { [pscustomobject]@{Key='Escape';KeyChar=[char]27;Modifiers=0} }
                        Start { [pscustomobject]@{Key='D1';KeyChar=[char]'1';Modifiers=0} }
                        Stop { [pscustomobject]@{Key='D2';KeyChar=[char]'2';Modifiers=0} }
                    }
                }
        }
        function Read-LabConfirm { param($Prompt,$Default) return $false }
        function Wait-LabConsoleAcknowledgement { }
        function Write-LabInfo { param($Message) }
        function Write-LabError { param($Message) throw $Message }
        $script:groupCalls = @(); $cli = Invoke-LabActionWithResult -ActionName AutomatedTestEnvironmentLifecycle
        Check-Group (-not $script:groupCalls.Count -and -not $script:groupChoices.Count -and $cli.Status -eq 'Cancelled' -and $cli.ConnectionCenterImpact -eq 'None') 'CLI refresh/no-op/cancel/back mutated or misrouted'
        Check-Group ($script:groupFrames.Count -ge 4 -and @($script:groupFrames | Where-Object { ($_.Lines -join ' ') -notmatch 'DOCKER.*STOPPED' -or ($_.Lines -join ' ') -notmatch 'PODMAN.*STOPPED' }).Count -eq 0) 'Cursor frames lost persistent group members or F5 refresh'
        $script:groupFallback=$true
        @('invalid','3','2','0') | ForEach-Object { $script:groupChoices.Enqueue($_) }
        $fallbackOutput = @(Invoke-LabActionWithResult -ActionName AutomatedTestEnvironmentLifecycle 6>&1)
        $script:groupFallback=$false
        Check-Group (-not $script:groupChoices.Count -and -not $script:groupCalls.Count -and ($fallbackOutput -join ' ') -match 'DOCKER.*STOPPED' -and ($fallbackOutput -join ' ') -match 'PODMAN.*STOPPED') 'Actual fallback lost members, refresh, invalid input retry or cancel'
        function Read-LabConfirm { param($Prompt,$Default) return $true }
        @('Start','back') | ForEach-Object { $script:groupChoices.Enqueue($_) }
        $cli = Invoke-LabActionWithResult -ActionName AutomatedTestEnvironmentLifecycle
        Check-Group ($cli.Status -eq 'Changed' -and $cli.ConnectionCenterImpact -eq 'None' -and $script:groupCalls.Count -eq 2) 'CLI wrapper lost mutation outcome or requested forbidden sync'
        $script:groupPower.docker='STOPPED'; $script:groupPower.podman='STOPPED'; $script:groupCalls=@()
        $plan = Get-LabTestGroupPowerPlan
        $result = Invoke-SqlServerLabWorkflowAction -Action StartTestGroupPower -ExpectedPlanKey $plan.PlanKey 6>$null
        Check-Group ($result.Result.Status -eq 'COMPLETED' -and $script:groupCalls.Count -eq 2) 'Real workflow adapter missed shared bound executor'
        $script:groupVm = [pscustomobject]@{ Id=[guid]::NewGuid().ToString(); Name='synthetic-group-vm'; State='Off'; Notes=($script:HyperVLabNotesPrefix + (@{provider='hyperv';runId=$script:groupRuns.docker;scopeId=$script:groupScope;instanceId='primary'} | ConvertTo-Json -Compress)) }
        function Get-VM { param($Name,$ErrorAction) $script:groupVm }
        function Start-VM { param($VM,$ErrorAction) $VM.State='Running' }
        function Stop-VM { param($VM,[switch]$Force,$ErrorAction) $VM.State='Off' }
        $vmArguments = @{VMName=$script:groupVm.Name;ExpectedRunId=$script:groupRuns.docker;ExpectedScopeId=$script:groupScope;ExpectedVMId='different-id'}
        Reject-Group { Start-HyperVInstance @vmArguments }
        Check-Group ($script:groupVm.State -eq 'Off') 'Hyper-V ID mismatch mutated neighbour'
        $vmArguments.ExpectedVMId = $script:groupVm.Id
        $vmArguments.ExpectedInstanceId = 'wrong-instance'
        Reject-Group { Start-HyperVInstance @vmArguments }
        $vmArguments.ExpectedInstanceId = 'primary'
        $directState=Get-Content $statePath -Raw|ConvertFrom-Json
        $directState.metadata=@{workflowKind='hyperv-lab'};$directState.providerSubRuns=@(@{provider='hyperv';state='STOPPED'})
        $directState|ConvertTo-Json -Depth 10|Set-Content $statePath
        @{instances=@(@{id='primary';provider='hyperv';vmId=$script:groupVm.Id;vmName=$script:groupVm.Name})}|ConvertTo-Json -Depth 10|Set-Content $connectionPath
        $null = Start-HyperVInstance @vmArguments
        Check-Group ($script:groupVm.State -eq 'Running') 'Bound Hyper-V primitive failed'
        $null = Stop-HyperVInstance @vmArguments
        Check-Group ($script:groupVm.State -eq 'Off') 'Bound Hyper-V stop failed'
        # Exercise the actual read-only Hyper-V branch; forbidden workflow repair remains mocked to throw.
        $state = Get-Content $statePath -Raw | ConvertFrom-Json; $state.metadata = @{workflowKind='hyperv-lab'}; $state.providerSubRuns=@(@{provider='hyperv';state='STOPPED'}); $state | ConvertTo-Json -Depth 10 | Set-Content $statePath
        @{instances=@(@{id='primary';provider='hyperv';vmId=$script:groupVm.Id;vmName=$script:groupVm.Name})} | ConvertTo-Json -Depth 10 | Set-Content $connectionPath
        $registry = Get-Content $registryPath -Raw | ConvertFrom-Json; $registry.environments[0].platform='windows'; $registry | ConvertTo-Json -Depth 10 | Set-Content $registryPath
        $hyperVPlan = Get-LabTestGroupPowerPlan
        Check-Group ($hyperVPlan.CanApply -and $hyperVPlan.Members[0].Power -eq 'STOPPED' -and $hyperVPlan.Members[0].SqlReadiness -eq 'NOT_CHECKED') 'Hyper-V preview repaired or invented SQL readiness'
        foreach ($subrun in @(@{provider='hyperv';state='RECOVERY_REQUIRED'},@{provider='docker';state='STOPPED'})) {
            $state.providerSubRuns=@($subrun); $state | ConvertTo-Json -Depth 10 | Set-Content $statePath
            Check-Group (-not (Get-LabTestGroupPowerPlan).CanApply) 'Hyper-V unsafe subrun accepted'
            Reject-Group { Invoke-LabTestGroupPowerPlan -PowerAction Start -ExpectedPlanKey $hyperVPlan.PlanKey -Confirmed }
        }
        $state.providerSubRuns=@(); $state | ConvertTo-Json -Depth 10 | Set-Content $statePath
        Check-Group ((Get-LabTestGroupPowerPlan).CanApply) 'Legacy Hyper-V missing subrun rejected'
        '{}' | Set-Content (Join-Path $runPath 'unexpected.journal.json')
        Check-Group (-not (Get-LabTestGroupPowerPlan).CanApply) 'Unknown recovery journal accepted'
        $serverSource = Get-Content (Join-Path $script:ModuleRoot 'Tools/Start-SqlServerLabUi.ps1') -Raw
        $serverAst = [Management.Automation.Language.Parser]::ParseInput($serverSource,[ref]$null,[ref]$null)
        $route = $serverAst.Find({param($node) $node -is [Management.Automation.Language.IfStatementAst] -and $node.Extent.Text.StartsWith('if ($path -eq ''/api/actions''')},$true)
        function New-SqlServerLabBatch { throw 'Power action entered replayable batch' }
        function Start-UiWorkflowJob { param($Action,$Parameters) $script:groupUiAction=$Action; $script:groupUiParameters=$Parameters; [pscustomobject]@{Id='synthetic-group-job';Action=$Action} }
        function Write-UiResponse { param($Context,$Body,$ContentType,$StatusCode) $script:groupUiResponse=$Body | ConvertFrom-Json }
        $bytes = [Text.Encoding]::UTF8.GetBytes((@{action='StopTestGroupPower';parameters=@{ExpectedPlanKey=('a'*64)}} | ConvertTo-Json))
        $stream = [IO.MemoryStream]::new($bytes)
        try {
            $context = [pscustomobject]@{Request=[pscustomobject]@{HttpMethod='POST';InputStream=$stream;ContentEncoding=[Text.Encoding]::UTF8}}
            $path='/api/actions'; $jobs=@{}
            . ([scriptblock]::Create('foreach ($once in @(1)) { ' + $route.Extent.Text + ' }'))
            Check-Group ($script:groupUiAction -eq 'StopTestGroupPower' -and $script:groupUiParameters.ExpectedPlanKey -eq ('a'*64) -and $jobs.Count -eq 1 -and $script:groupUiResponse.id -eq 'synthetic-group-job') 'Real HTTP route failed one-shot job binding'
        } finally { $stream.Dispose() }
        Write-Host "Test group guidance: $script:groupChecks PASS, 0 FAIL"
    } $testRoot
}
finally {
    if ($testRoot -and [IO.Path]::GetFullPath($testRoot).StartsWith([IO.Path]::GetTempPath(),[StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
