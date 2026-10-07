#Requires -Version 7.2
[CmdletBinding()] param()
$ErrorActionPreference='Stop'
$repo=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$root=Join-Path $parent ('sql-lab-maintenance-guidance-'+[guid]::NewGuid().ToString('N'))
$module=Import-Module (Join-Path $repo 'SqlServerLab.psd1') -Force -PassThru
try {
    & $module {
        param($Root,$Repo)
        . (Join-Path $Repo 'Tests/Common/PersistentStorageRecoveryFixture.ps1')
        $script:count=0
        function Assert-Guidance($Condition,$Name) { if (-not $Condition) {throw "ASSERT: $Name"}; $script:count++ }
        function Snapshot {
            (@(Get-ChildItem -LiteralPath $Root -File -Recurse | Sort-Object FullName | ForEach-Object { $_.FullName + ':' + (Get-FileHash -LiteralPath $_.FullName).Hash }) -join '|')
        }
        function Rejected([scriptblock]$Action) { $before=Snapshot; try { & $Action | Out-Null; return $false } catch { return $before -ceq (Snapshot) } }
        $script:fixture=New-TestPersistentStorageRecoveryFixture -Root $Root
        $script:volume=$script:fixture.Runtime
        $script:volume | Add-Member CreatedAt '2026-09-01T00:00:00Z'
        $script:volume | Add-Member Driver 'local'
        $script:volume | Add-Member Options ([pscustomobject]@{})
        function Resolve-LabDataRootForUse {param($DataRoot) $script:fixture.DataRoot}
        function Get-LabStorageConfiguration {param($DataRoot) $script:fixture.Configuration}
        function Test-LabDataRootOwnership {param($DataRoot,$ControllerId) $true}
        function Get-LabRetainedStoreRuntimeContext {param($Provider) [pscustomobject]@{RuntimeScopeId=$script:fixture.RuntimeScopeId;Provider=$Provider}}
        function Get-LabContainerRuntimeScope {param($Provider) [pscustomobject]@{Status='AVAILABLE';RuntimeId=$script:fixture.RuntimeScopeId}}
        function Get-LabRetainedStoreVolume {
            param($Context,$VolumeName)
            if ($VolumeName -ne $script:volume.VolumeName) {return [pscustomobject]@{Status='MISSING'}}
            $script:volume | ConvertTo-Json -Depth 15 | ConvertFrom-Json -Depth 15
        }
        function Get-LabContainerInstanceStoreRuntimeInspection {
            param($Provider,$VolumeName,[switch]$RequireMissingEvidence)
            Get-LabRetainedStoreVolume -VolumeName $VolumeName
        }
        $script:realObservation=(Get-Command Get-LabRetainedStoreObservation).ScriptBlock
        $script:lateObservation=$null; $script:expectedObservationCount=0
        function Get-LabRetainedStoreObservation {
            param($Store,$Configuration,$StateRoot,$Expected)
            $result=& $script:realObservation -Store $Store -Configuration $Configuration -StateRoot $StateRoot -Expected $Expected
            if ($Expected) {
                $script:expectedObservationCount++
                if ($script:expectedObservationCount -eq 2 -and $script:lateObservation) { & $script:lateObservation }
            }
            $result
        }
        $state=$script:fixture.Run.StateRoot
        $sources=Get-LabMaintenanceGuidanceSources -StateRoot $state -Configuration $script:fixture.Configuration
        Assert-Guidance ($sources.Candidates.Count -eq 1 -and -not $sources.Incomplete) 'server-derived modern candidate'
        $id=$sources.Candidates[0].Id
        $arguments=@{CandidateId=$id;StateRoot=$state;DataRoot=$script:fixture.DataRoot}
        $script:fixture.Configuration.LabDataLocations[0] | Add-Member FreeBytes 100L
        $before=Snapshot
        $plan=Get-LabMaintenanceRepairPlan @arguments
        Assert-Guidance ($plan.Status -ceq 'READY' -and $before -ceq (Snapshot)) 'real repair preview preserves all source and catalog bytes'
        $script:fixture.Configuration.LabDataLocations[0].FreeBytes=90L
        $capacityRefresh=Get-LabMaintenanceRepairPlan @arguments
        Assert-Guidance ($capacityRefresh.ExpectedKey -ceq $plan.ExpectedKey -and $before -ceq (Snapshot)) 'volatile free capacity is not root authority or stale-plan drift'
        $dto=ConvertTo-LabMaintenanceRepairView $plan
        Assert-Guidance (($dto.PSObject.Properties.Name -join ',') -eq 'CandidateId,ExpectedKey,Status,Provider,InstanceId,Notice') 'DTO allowlist excludes source/root/native evidence'
        $cancel=Invoke-LabMaintenanceRepair @arguments -ExpectedKey $plan.ExpectedKey
        Assert-Guidance ($cancel.Status -eq 'CANCELLED' -and $before -ceq (Snapshot)) 'cancel has no writes'
        $script:volume.CreatedAt='2026-09-02T00:00:00Z'
        Assert-Guidance (Rejected {Invoke-LabMaintenanceRepair @arguments -ExpectedKey $plan.ExpectedKey -Confirmed}) 'same labels but recreated volume rejects stale key'
        $script:volume.CreatedAt='2026-09-01T00:00:00Z'
        $script:volume.AttachedContainers=@('synthetic-neighbor')
        Assert-Guidance (Rejected {Get-LabMaintenanceRepairPlan @arguments}) 'attached volume blocked'
        $script:volume.AttachedContainers=@()
        $script:volume.CreatedAt=$null
        Assert-Guidance (Rejected {Get-LabMaintenanceRepairPlan @arguments}) 'missing native creation identity blocked'
        $script:volume.CreatedAt='2026-09-01T00:00:00Z'
        $bad=Join-Path (Join-Path $state 'runs') ([guid]::NewGuid().ToString('D'))
        $null=New-Item -ItemType Directory -Path $bad
        $badFile=Join-Path $bad 'run-state.json'; Set-Content -LiteralPath $badFile -Value '{broken'
        $script:warningWrites=0
        function Write-LabWarning {param($Message) $script:warningWrites++}
        $before=Snapshot; $null=@(Get-LabActiveRuns -StateRoot $state -NoWrite)
        Assert-Guidance ($script:warningWrites -eq 0 -and $before -ceq (Snapshot)) 'NoWrite malformed run does not write warning journal'
        Assert-Guidance (Rejected {Get-LabMaintenanceRepairPlan @arguments}) 'unreadable other run blocks supposedly missing references'
        Remove-Item -LiteralPath $badFile
        Remove-Item -LiteralPath $bad
        $activeId=[guid]::NewGuid().ToString('D'); $activeDirectory=Join-Path (Join-Path $state 'runs') $activeId
        $null=New-Item -ItemType Directory -Path $activeDirectory
        $activeState=$script:fixture.State | ConvertTo-Json -Depth 50 | ConvertFrom-Json -Depth 50
        $activeState.runId=$activeId; $activeState.scopeId=[guid]::NewGuid().ToString('D'); $activeState.state='RUNNING'
        $activePath=Join-Path $activeDirectory 'run-state.json'
        $activeState|ConvertTo-Json -Depth 50|Set-Content -LiteralPath $activePath
        $activeSources=Get-LabMaintenanceGuidanceSources -StateRoot $state -Configuration $script:fixture.Configuration
        Assert-Guidance ($script:fixture.StorageId -cin $activeSources.ActiveStorageIds -and (Rejected {Get-LabMaintenanceRepairPlan @arguments})) 'active desired reference blocks even without catalog lease or native attachment'
        $activeState.metadata.desiredState=$null; $activeState|ConvertTo-Json -Depth 50|Set-Content -LiteralPath $activePath
        Assert-Guidance (Rejected {Get-LabMaintenanceRepairPlan @arguments}) 'unverifiable active desired references block'
        Remove-Item -LiteralPath $activePath
        Remove-Item -LiteralPath $activeDirectory
        $registryDirectory=Join-Path $script:fixture.DataRoot 'Exports'; $null=New-Item -ItemType Directory -Path $registryDirectory
        $registryPath=Join-Path $registryDirectory 'TestUmgebung.registry.json'
        @{contractVersion='SqlServerLab.TestEnvironmentRegistry/1.0';environments=@(@{runId=$script:fixture.Run.RunId})} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $registryPath
        Assert-Guidance (Rejected {Get-LabMaintenanceRepairPlan @arguments}) 'protected registration blocks catalog repair'
        Set-Content -LiteralPath $registryPath -Value '{broken'
        Assert-Guidance (Rejected {Get-LabMaintenanceRepairPlan @arguments}) 'malformed registry is not an empty registry'
        Set-Content -LiteralPath $registryPath -Value '{"contractVersion":"SqlServerLab.TestEnvironmentRegistry/1.0"}'
        Assert-Guidance (Rejected {Get-LabMaintenanceRepairPlan @arguments}) 'missing registry member array cannot authorize repair'
        Remove-Item -LiteralPath $registryPath
        $journal=Join-Path $script:fixture.Run.RunDir 'synthetic.journal.json'
        '{"Status":"RECOVERY_REQUIRED"}' | Set-Content -LiteralPath $journal
        Assert-Guidance (Rejected {Get-LabMaintenanceRepairPlan @arguments}) 'open recovery blocks'
        Remove-Item -LiteralPath $journal
        # Inject after the actual last native observation, not into a stubbed
        # planner. The existing mutation callback must still refuse its commit.
        $script:lateRegistryPath=$registryPath; $script:lateActivePath=$activePath; $script:lateJournalPath=$journal
        $script:lateActiveState=$activeState | ConvertTo-Json -Depth 50 | ConvertFrom-Json -Depth 50
        $script:lateActiveState.metadata.desiredState=$script:fixture.State.metadata.desiredState
        foreach ($kind in @('Registry','ActiveReference','Recovery')) {
            $script:lateKind=$kind; $script:expectedObservationCount=0
            $script:lateObservation={
                switch ($script:lateKind) {
                    Registry { @{contractVersion='SqlServerLab.TestEnvironmentRegistry/1.0';environments=@(@{runId=$script:fixture.Run.RunId})}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath $script:lateRegistryPath }
                    ActiveReference { $null=New-Item -ItemType Directory -Path (Split-Path $script:lateActivePath -Parent); $script:lateActiveState|ConvertTo-Json -Depth 50|Set-Content -LiteralPath $script:lateActivePath }
                    Recovery { '{"Status":"RECOVERY_REQUIRED"}'|Set-Content -LiteralPath $script:lateJournalPath }
                }
            }
            $caught=$null
            try {Invoke-LabMaintenanceRepair @arguments -ExpectedKey $plan.ExpectedKey -Confirmed|Out-Null}catch{$caught=$_.Exception.Message}
            $catalogAfter=Get-LabPersistentStorageCatalog -Configuration $script:fixture.Configuration
            Assert-Guidance ($script:expectedObservationCount -eq 2 -and $caught -match 'PROTECTED_GROUP|ACTIVE_REFERENCE|RECOVERY_REQUIRED' -and $catalogAfter.Document.Revision -eq 0 -and $catalogAfter.Document.Stores.Count -eq 0) "last observation $kind drift refuses actual catalog commit"
            if(Test-Path -LiteralPath $registryPath){Remove-Item -LiteralPath $registryPath}
            if(Test-Path -LiteralPath $activePath){Remove-Item -LiteralPath $activePath;Remove-Item -LiteralPath $activeDirectory}
            if(Test-Path -LiteralPath $journal){Remove-Item -LiteralPath $journal}
        }
        $writerFixture=Join-Path $Root 'writer-fixture.json'
        @{Module=(Join-Path $Repo 'SqlServerLab.psd1');RunId=$script:fixture.Run.RunId;Roots=@($script:fixture.Configuration.LabDataLocations|ForEach-Object {Join-Path $_.LabDataRoot 'Exports'})}|ConvertTo-Json -Depth 4|Set-Content -LiteralPath $writerFixture
        $script:writerScript=Join-Path $Root 'writer-child.ps1'; $script:writerFixture=$writerFixture
        $writerText='param($Fixture); $ErrorActionPreference="Stop"; $f=Get-Content -LiteralPath $Fixture -Raw|ConvertFrom-Json; $m=Import-Module $f.Module -Force -PassThru -DisableNameChecking; & $m {param($f) foreach($root in $f.Roots){try{Register-LabTestEnvironmentRun -RunId $f.RunId -Platform linux -SqlVersion 2025 -Patch rtm -InstanceId primary -OutputDirectory $root|Out-Null;throw "WRITER_NOT_BLOCKED"}catch{if($_.Exception.Message -cne "TEST_GROUP_BUSY"){throw "WRITER_GUARD_FAILED"};Write-Output "BLOCKED"}}} $f'
        Set-Content -LiteralPath $script:writerScript -Value $writerText
        $script:expectedObservationCount=0; $script:writerBlocked=$false
        $script:lateObservation={
            $start=[Diagnostics.ProcessStartInfo]::new(); $start.FileName=(Get-Command pwsh).Source
            $start.UseShellExecute=$false; $start.CreateNoWindow=$true; $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
            foreach($argument in @('-NoLogo','-NoProfile','-File',$script:writerScript,$script:writerFixture)){$start.ArgumentList.Add($argument)}
            $writer=[Diagnostics.Process]::new(); $writer.StartInfo=$start
            try {
                $null=$writer.Start(); $output=$writer.StandardOutput.ReadToEndAsync(); $errors=$writer.StandardError.ReadToEndAsync()
                if(-not $writer.WaitForExit(15000)){throw 'WRITER_TIMEOUT'}
                $script:writerBlocked=$writer.ExitCode -eq 0 -and @($output.GetAwaiter().GetResult() -split '\r?\n'|Where-Object {$_ -ceq 'BLOCKED'}).Count -eq 2
                $null=$errors.GetAwaiter().GetResult()
            }
            finally {if(-not $writer.HasExited){$writer.Kill($true);$null=$writer.WaitForExit(5000)};$writer.Dispose()}
        }
        $applied=Invoke-LabMaintenanceRepair @arguments -ExpectedKey $plan.ExpectedKey -Confirmed
        Assert-Guidance ($script:writerBlocked -and -not(Test-Path -LiteralPath $registryPath)) 'actual concurrent registry writer blocked on every registered root through final observation'
        $script:lateObservation=$null
        Assert-Guidance ($applied.Status -eq 'RECOVERED' -and $applied.Changed) 'existing executor commits under catalog lock'
        $before=Snapshot
        $repeat=Get-LabMaintenanceRepairPlan @arguments
        $noop=Invoke-LabMaintenanceRepair @arguments -ExpectedKey $repeat.ExpectedKey -Confirmed
        Assert-Guidance ($repeat.Status -eq 'NO_CHANGE' -and $noop.Status -eq 'NO_CHANGE' -and $before -ceq (Snapshot)) 'fresh matching catalog association is byte-preserving no-op'
        Assert-Guidance (Rejected {Invoke-LabMaintenanceRepair @arguments -ExpectedKey $plan.ExpectedKey -Confirmed}) 'old catalog revision rejected after successful apply'
        $originalConnection=Get-Content -LiteralPath (Join-Path $script:fixture.Run.RunDir 'connection-info.json') -Raw
        $lockFixture=Join-Path $Root 'lock-fixture.json'; $marker=Join-Path $Root 'locked'
        @{Module=(Join-Path $Repo 'SqlServerLab.psd1');Controller=$script:fixture.Configuration.ControllerId;Marker=$marker;Connection=(Join-Path $script:fixture.Run.RunDir 'connection-info.json')}|ConvertTo-Json|Set-Content -LiteralPath $lockFixture
        $childText='param($Fixture); $f=Get-Content -LiteralPath $Fixture -Raw|ConvertFrom-Json; $m=Import-Module $f.Module -Force -PassThru; & $m {param($f) Invoke-LabPersistentStorageCatalogLock -ControllerId $f.Controller -ScriptBlock { [IO.File]::AppendAllText($f.Connection,"`n"); [IO.File]::WriteAllText($f.Marker,"locked"); Start-Sleep -Milliseconds 900 }} $f'
        $childScript=Join-Path $Root 'lock-child.ps1'; Set-Content -LiteralPath $childScript -Value $childText
        $start=[Diagnostics.ProcessStartInfo]::new(); $start.FileName=(Get-Command pwsh).Source
        $start.UseShellExecute=$false; $start.CreateNoWindow=$true; $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
        foreach($arg in @('-NoLogo','-NoProfile','-File',$childScript,$lockFixture)){$start.ArgumentList.Add($arg)}
        $child=[Diagnostics.Process]::new(); $child.StartInfo=$start
        try {
            $null=$child.Start(); $stdout=$child.StandardOutput.ReadToEndAsync(); $stderr=$child.StandardError.ReadToEndAsync()
            $clock=[Diagnostics.Stopwatch]::StartNew()
            while(-not(Test-Path -LiteralPath $marker) -and $clock.Elapsed.TotalSeconds -lt 15 -and -not $child.HasExited){Start-Sleep -Milliseconds 20}
            if(-not(Test-Path -LiteralPath $marker)){throw 'LOCK_CHILD_NOT_READY'}
            $clock.Restart(); $caught=$null
            try {Invoke-LabMaintenanceRepair @arguments -ExpectedKey $repeat.ExpectedKey -Confirmed|Out-Null}catch{$caught=$_.Exception.Message}
            Assert-Guidance ($clock.ElapsedMilliseconds -ge 300 -and $caught -match 'CONFLICT|CHANGED|STALE') 'actual cross-process controller lock serializes and rejects changed source'
            if(-not $child.WaitForExit(5000) -or $child.ExitCode -ne 0){throw 'LOCK_CHILD_FAILED'}
            $null=$stdout.GetAwaiter().GetResult(); $null=$stderr.GetAwaiter().GetResult()
        }
        finally {if(-not $child.HasExited){$child.Kill($true);$null=$child.WaitForExit(5000)};$child.Dispose()}
        [IO.File]::WriteAllText((Join-Path $script:fixture.Run.RunDir 'connection-info.json'),$originalConnection)
        # Actual HTTP handler, imported from the server AST, with only provider
        # boundaries promoted into this isolated module process.
        foreach ($name in @('Resolve-LabDataRootForUse','Get-LabStorageConfiguration','Test-LabDataRootOwnership','Get-LabRetainedStoreRuntimeContext','Get-LabContainerRuntimeScope','Get-LabRetainedStoreVolume','Get-LabContainerInstanceStoreRuntimeInspection')) {
            Set-Item -Path ('Function:script:'+$name) -Value (Get-Command $name).ScriptBlock
        }
        . (Join-Path $Repo 'Tools/WorkflowUiJsonBody.ps1')
        $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $Repo 'Tools/Start-SqlServerLabUi.ps1'),[ref]$null,[ref]$null)
        $handler=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-UiMaintenanceRequest'},$true)
        . ([scriptblock]::Create($handler.Extent.Text))
        function New-Request($Body,$Origin='http://127.0.0.1:12345') {
            [pscustomobject]@{HttpMethod='POST';ContentType='application/json';Headers=@{Origin=$Origin};Url=[uri]'http://127.0.0.1:12345/api/maintenance';ContentEncoding=[Text.Encoding]::UTF8;InputStream=[IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes($Body))}
        }
        $oldState=$env:SQL_SERVER_LAB_STATE; $env:SQL_SERVER_LAB_STATE=$state
        try {
            $body=@{action='preview';candidateId=$id}|ConvertTo-Json
            $http=Invoke-UiMaintenanceRequest -Request (New-Request $body)
            Assert-Guidance ($http.Status -eq 'NO_CHANGE' -and -not $http.Source -and -not $http.Configuration) 'real HTTP handler projects actual common plan'
            Assert-Guidance (Rejected {Invoke-UiMaintenanceRequest -Request (New-Request $body 'https://example.invalid')}) 'HTTP cross-origin rejected'
            Assert-Guidance (Rejected {Invoke-UiMaintenanceRequest -Request (New-Request (@{action='apply';candidateId=$id;expectedKey=$http.ExpectedKey;confirmed='true'}|ConvertTo-Json))}) 'HTTP string confirmation rejected'
            Assert-Guidance (Rejected {Invoke-UiMaintenanceRequest -Request (New-Request (@{action='preview';candidateId=$id;Source=@{Provider='docker'}}|ConvertTo-Json))}) 'HTTP cannot supply source authority'
            Assert-Guidance (Rejected {Invoke-UiMaintenanceRequest -Request (New-Request ('x'*1025))}) 'HTTP request bounded'
            $before=Snapshot
            $httpNoop=Invoke-UiMaintenanceRequest -Request (New-Request (@{action='apply';candidateId=$id;expectedKey=$http.ExpectedKey;confirmed=$true}|ConvertTo-Json))
            Assert-Guidance ($httpNoop.Status -eq 'NO_CHANGE' -and $before -ceq (Snapshot)) 'actual HTTP apply no-op preserves bytes'
            function Get-SqlServerLabCleanupAudit {
                param([switch]$NoWrite,$DataRoot,$StateRoot)
                if (-not $NoWrite) {throw 'AUDIT_WRITE_NOT_ALLOWED'}
                [pscustomobject]@{Audit=[pscustomobject]@{StateRoot=$script:fixture.Run.StateRoot;CreatedAt='synthetic';StateReadIssues=@();StorageResidency=[pscustomobject]@{Objects=@()};Findings=[pscustomobject]@{};Summary=[pscustomobject]@{UnverifiableProviders=1}}}
            }
            $view=Get-LabMaintenanceGuidanceView
            Assert-Guidance ($view.Rows.Count -eq 1 -and $view.UnavailableProviders -eq 1) 'real view projects supported candidate without native audit writes'
            $script:realMenu=(Get-Command Invoke-LabConsoleMenu).ScriptBlock
            $script:choices=[Collections.Generic.Queue[string]]::new()
            $script:frames=[Collections.Generic.List[object]]::new()
            function Update-LabConsoleAttentionSnapshot { $null }
            function Invoke-LabConsoleMenu {
                param($ScreenId,$Title,$Subtitle,$Items)
                if ($script:guidanceFallback) {
                    return & $script:realMenu -ScreenId $ScreenId -Title $Title -Subtitle $Subtitle -Items $Items -Snapshot $null -ForceFallback -ReadInput {$script:choices.Dequeue()}
                }
                & $script:realMenu -ScreenId $ScreenId -Title $Title -Subtitle $Subtitle -Items $Items -Snapshot $null `
                    -Capability ([pscustomobject]@{Supported=$true;Mode='CURSOR'}) -GetViewport { [pscustomobject]@{Width=140;Height=30} } `
                    -SessionFactory { [pscustomobject]@{OriginTop=0;PreviousLineCount=0;ForegroundColor='Gray'} } -SessionCompleter {} `
                    -FrameWriter {param($s,$f) $script:frames.Add($f)} -ReadKey {
                        switch ($script:choices.Dequeue()) {
                            refresh {[pscustomobject]@{Key='F5';KeyChar=[char]0;Modifiers=0}}
                            down {[pscustomobject]@{Key='DownArrow';KeyChar=[char]0;Modifiers=0}}
                            select {[pscustomobject]@{Key='Enter';KeyChar=[char]13;Modifiers=0}}
                            back {[pscustomobject]@{Key='Escape';KeyChar=[char]27;Modifiers=0}}
                        }
                    }
            }
            function Read-LabConfirm {param($Prompt,$Default) $false}
            function Wait-LabConsoleAcknowledgement { }
            @('refresh','down','select','back')|ForEach-Object {$script:choices.Enqueue($_)}
            $before=Snapshot; $cli=Show-LabMaintenanceGuidanceInteractive 6>$null
            Assert-Guidance ($script:choices.Count -eq 0 -and $cli.Status -eq 'NoChange' -and $before -ceq (Snapshot)) 'real CLI cursor F5 selection cancel and back preserve bytes'
            Assert-Guidance (@($script:frames|Where-Object {($_.Lines -join ' ') -match 'SQL-Speicherzuordnung'}).Count -ge 1) 'candidate persists in actual cursor frame'
            $script:guidanceFallback=$true
            @('r','0')|ForEach-Object {$script:choices.Enqueue($_)}
            $before=Snapshot; $fallback=@(Show-LabMaintenanceGuidanceInteractive 6>&1)
            Assert-Guidance ($script:choices.Count -eq 0 -and $before -ceq (Snapshot) -and ($fallback -join ' ') -match 'SQL-Speicherzuordnung') 'real fallback read and back preserve persistent candidate and bytes'
        }
        finally {$env:SQL_SERVER_LAB_STATE=$oldState}
        Write-Host "MAINTENANCE GUIDANCE: $script:count PASS"
    } $root $repo
}
finally {
    $resolved=[IO.Path]::GetFullPath($root)
    if (-not $resolved.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notlike 'sql-lab-maintenance-guidance-*') {throw 'TEST_CLEANUP_SCOPE'}
    if (Test-Path -LiteralPath $resolved) {Remove-Item -LiteralPath $resolved -Recurse -Force}
}
