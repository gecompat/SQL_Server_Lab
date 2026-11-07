#Requires -Version 7.2
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
. (Join-Path $PSScriptRoot '..\Common\CheckResult.ps1')
$failures = [Collections.Generic.List[string]]::new()
$passed = 0
$module = Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru -ErrorAction Stop
$stateRoot = Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-environment-groups-' + [guid]::NewGuid().ToString('N'))

try {
    $result = & $module {
        param($root,$sourceRoot)
        $script:groupFixtureRuns = @{}
        $script:groupFixtureRuntime = @{}
        $script:groupFixtureSubRuns = @{}
        $registryLockDefinition=(Get-Command Enter-LabEnvironmentGroupsLock -CommandType Function -ErrorAction Stop).Definition
        $registryLockWaitsBoundedly=$registryLockDefinition -match 'WaitOne\(\[TimeSpan\]::FromSeconds\(10\)\)'
        $null = New-Item -ItemType Directory -Path $root -Force
        $script:groupFixtureRoot=$root
        $script:groupRegistryLockDepth=0
        $script:groupRunLockDepth=0
        $script:realEnterGroupsLock=(Get-Command Enter-LabEnvironmentGroupsLock -CommandType Function).ScriptBlock
        $script:realExitGroupsLock=(Get-Command Exit-LabEnvironmentGroupsLock -CommandType Function).ScriptBlock
        $script:realEnterGroupRunLock=(Get-Command Enter-LabEnvironmentGroupRunResourceLock -CommandType Function).ScriptBlock
        $script:realExitGroupRunLock=(Get-Command Exit-LabEnvironmentGroupRunResourceLock -CommandType Function).ScriptBlock
        function Enter-LabEnvironmentGroupsLock { param($StateRoot) $mutex=& $script:realEnterGroupsLock -StateRoot $StateRoot; $script:groupRegistryLockDepth++; return $mutex }
        function Exit-LabEnvironmentGroupsLock { param($Mutex) $script:groupRegistryLockDepth--; & $script:realExitGroupsLock -Mutex $Mutex }
        function Enter-LabEnvironmentGroupRunResourceLock { param($RunId,$StateRoot) $lock=& $script:realEnterGroupRunLock -RunId $RunId -StateRoot $StateRoot; $script:groupRunLockDepth++; return $lock }
        function Exit-LabEnvironmentGroupRunResourceLock { param($Mutex) $script:groupRunLockDepth--; & $script:realExitGroupRunLock -Mutex $Mutex }
        $script:groupLockProbeEnabled=$false
        $script:groupStartLockScopeObserved=$false
        $script:groupStopLockScopeObserved=$false
        $script:groupActiveNoOpProbeEnabled=$false
        $script:groupActiveNoOpRegistryLockObserved=$false
        $script:groupActiveNoOpRunLockObserved=$false
        $script:groupConcurrentGroupName=$null
        $script:groupConcurrentGroupId=$null
        $script:groupFailStartRunId=$null
        function Get-LabRunState { param($RunId,$StateRoot) $script:groupFixtureRuns[[string]$RunId] }
        function Set-LabRunState {
            param($RunId,$NewState,$Reason,$StateRoot)
            $script:groupFixtureRuns[[string]$RunId].state=$NewState
            $script:groupFixtureRuns[[string]$RunId]
        }
        function Get-LabProviderSubRuns { param($RunId,$StateRoot) @($script:groupFixtureSubRuns[[string]$RunId]) }
        function Set-LabProviderSubRunState {
            param($RunId,$Provider,$NewState,$Reason,$StateRoot)
            $script:groupFixtureSubRuns[[string]$RunId].state=$NewState
        }
        function Get-LabRunRuntimeStatus {
            param($Run,$StateRoot)
            if ($script:groupActiveNoOpProbeEnabled) {
                $script:groupActiveNoOpRegistryLockObserved=($script:groupActiveNoOpRegistryLockObserved -or $script:groupRegistryLockDepth -gt 0)
                $script:groupActiveNoOpRunLockObserved=($script:groupActiveNoOpRunLockObserved -or $script:groupRunLockDepth -gt 0)
            }
            $state=[string]$script:groupFixtureRuntime[[string]$Run.runId]
            [PSCustomObject]@{State=$state;Instances=@([PSCustomObject]@{Id='primary';Provider='docker';State=$state})}
        }
        function Test-LabAutomatedTestEnvironmentRun { param($RunId,$OutputDirectory) $false }
        function Assert-LabWindowsPoolMutationAllowed { param($RunId,$StateRoot,[switch]$InvalidateEvidence) if ($script:groupFixtureProtected -contains [string]$RunId) { throw 'WINDOWS_POOL_MEMBER_RESERVED' } }
        function Start-SqlServerLab {
            param($RunId,$TimeoutSeconds,$SkipReadyCheck,$StateRoot)
            if ($script:groupLockProbeEnabled) {
                if ($script:groupRunLockDepth -gt 0) { $script:groupStartLockScopeObserved=($script:groupStartLockScopeObserved -or (-not $script:groupRegistryLockDepth -and $script:groupRunLockDepth -gt 0)) }
            }
            if ($script:groupConcurrentGroupName) {
                $created=New-SqlServerLabEnvironmentGroup -Name $script:groupConcurrentGroupName -StateRoot $script:groupFixtureRoot -Confirm:$false
                $script:groupConcurrentGroupId=[string]$created.Group.groupId
                $script:groupConcurrentGroupName=$null
            }
            if ($script:groupFailStartRunId -and [string]$RunId -ceq [string]$script:groupFailStartRunId) { throw 'SYNTHETIC_GROUP_START_FAILURE' }
            $script:groupFixtureRuns[[string]$RunId].state='RUNNING'
            $script:groupFixtureRuntime[[string]$RunId]='RUNNING'
            [PSCustomObject]@{Status='STARTED';Errors=0}
        }
        function Stop-SqlServerLab {
            param($RunId,$Force,$SkipHostMemoryRelease,$StateRoot,$Confirm)
            if ($script:groupLockProbeEnabled -and $script:groupRunLockDepth -gt 0) { $script:groupStopLockScopeObserved=($script:groupStopLockScopeObserved -or (-not $script:groupRegistryLockDepth -and $script:groupRunLockDepth -gt 0)) }
            $script:groupFixtureRuns[[string]$RunId].state='STOPPED'
            $script:groupFixtureRuntime[[string]$RunId]='STOPPED'
            [PSCustomObject]@{Action='STOPPED';Errors=0}
        }

        $runId=[guid]::NewGuid().ToString('D'); $scopeId=[guid]::NewGuid().ToString('D')
        $script:groupFixtureRuns[$runId]=[PSCustomObject]@{runId=$runId;scopeId=$scopeId;state='STOPPED';metadata=[PSCustomObject]@{windowsPoolMember=$null}}
        $script:groupFixtureRuntime[$runId]='STOPPED'
        $script:groupFixtureSubRuns[$runId]=[PSCustomObject]@{provider='docker';state='STOPPED'}
        $runDirectory=Join-Path (Join-Path $root 'runs') $runId
        $null=New-Item -ItemType Directory -Path $runDirectory -Force
        $connection=[ordered]@{runId=$runId;scopeId=$scopeId;instances=@([ordered]@{id='primary';provider='docker';containerId='fixture-container'})}
        $connection | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $runDirectory 'connection-info.json') -Encoding utf8

        $groupA=(New-SqlServerLabEnvironmentGroup -Name 'Shared A' -StateRoot $root).Group
        $groupB=(New-SqlServerLabEnvironmentGroup -Name 'Shared B' -StateRoot $root).Group
        $null=Add-SqlServerLabEnvironmentGroupMember -GroupId $groupA.groupId -RunId $runId -StateRoot $root
        $null=Add-SqlServerLabEnvironmentGroupMember -GroupId $groupB.groupId -RunId $runId -StateRoot $root
        $defaultGroupList=@(Get-SqlServerLabEnvironmentGroup -StateRoot $root)
        $defaultListHasBindingStatus=$defaultGroupList[0].members[0].PSObject.Properties['bindingStatus'] -ne $null
        $bindingGroupList=@(Get-SqlServerLabEnvironmentGroup -IncludeBindingStatus -StateRoot $root)
        $sharedBindingStatuses=@($bindingGroupList | Where-Object { [string]$_.groupId -in @([string]$groupA.groupId,[string]$groupB.groupId) } | ForEach-Object { [string]$_.members[0].bindingStatus })
        $connectionPath=Join-Path $runDirectory 'connection-info.json'
        $originalConnectionBytes=[IO.File]::ReadAllBytes($connectionPath)
        $driftedConnection=[Text.UTF8Encoding]::new($false).GetString($originalConnectionBytes).Replace('fixture-container','fixture-container-drift')
        [IO.File]::WriteAllText($connectionPath,$driftedConnection,[Text.UTF8Encoding]::new($false))
        $staleBindingGroupList=@(Get-SqlServerLabEnvironmentGroup -IncludeBindingStatus -StateRoot $root)
        $staleSharedBindingStatuses=@($staleBindingGroupList | Where-Object { [string]$_.groupId -in @([string]$groupA.groupId,[string]$groupB.groupId) } | ForEach-Object { [string]$_.members[0].bindingStatus })
        [IO.File]::WriteAllBytes($connectionPath,$originalConnectionBytes)
        $script:groupLockProbeEnabled=$true
        $script:groupConcurrentGroupName='Concurrent Registry Update'
        $startA=Start-SqlServerLabEnvironmentGroup -GroupId $groupA.groupId -StateRoot $root
        $groupCountAfterConcurrentWrite=@((Get-LabEnvironmentGroupsRegistry -StateRoot $root).groups).Count
        $startB=Start-SqlServerLabEnvironmentGroup -GroupId $groupB.groupId -StateRoot $root
        $script:groupActiveNoOpProbeEnabled=$true
        $activeNoOp=Start-SqlServerLabEnvironmentGroup -GroupId $groupA.groupId -StateRoot $root
        $script:groupActiveNoOpProbeEnabled=$false
        $stopA=Stop-SqlServerLabEnvironmentGroup -GroupId $groupA.groupId -StateRoot $root
        $stateAfterA=[string]$script:groupFixtureRuntime[$runId]
        $raceRegistryLock=Enter-LabEnvironmentGroupsLock -StateRoot $root
        try {
            $raceRegistry=Get-LabEnvironmentGroupsRegistry -StateRoot $root
            $raceGroupA=@($raceRegistry.groups | Where-Object { [string]$_.groupId -ceq [string]$groupA.groupId }) | Select-Object -First 1
            $raceGroupA.lifecycleState='STOPPING'
            $raceGroupA.operation.state='IN_PROGRESS'
            Write-LabEnvironmentGroupsRegistry -Registry $raceRegistry -StateRoot $root
        }
        finally { Exit-LabEnvironmentGroupsLock -Mutex $raceRegistryLock }
        $claimsAfterRetain=@(Get-LabEnvironmentGroupRunClaims -RunId $runId -Registry (Get-LabEnvironmentGroupsRegistry -StateRoot $root))
        $stopB=Stop-SqlServerLabEnvironmentGroup -GroupId $groupB.groupId -StateRoot $root
        $stateAfterB=[string]$script:groupFixtureRuntime[$runId]
        $null=Set-LabEnvironmentGroupLifecycleResult -GroupId $groupA.groupId -OperationId ([string]$stopA.OperationId) -LifecycleState STOPPED -OperationState COMPLETED -StateRoot $root
        $removeAfterStop=Remove-SqlServerLabEnvironmentGroupMember -GroupId $groupB.groupId -RunId $runId -StateRoot $root
        $groupAfterRemove=Get-SqlServerLabEnvironmentGroup -GroupId $groupB.groupId -StateRoot $root
        $addAfterStop=Add-SqlServerLabEnvironmentGroupMember -GroupId $groupB.groupId -RunId $runId -StateRoot $root
        $groupAfterAdd=Get-SqlServerLabEnvironmentGroup -GroupId $groupB.groupId -StateRoot $root

        $failedRunId=[guid]::NewGuid().ToString('D'); $failedScopeId=[guid]::NewGuid().ToString('D')
        $script:groupFixtureRuns[$failedRunId]=[PSCustomObject]@{runId=$failedRunId;scopeId=$failedScopeId;state='STOPPED';metadata=[PSCustomObject]@{windowsPoolMember=$null}}
        $script:groupFixtureRuntime[$failedRunId]='STOPPED'
        $script:groupFixtureSubRuns[$failedRunId]=[PSCustomObject]@{provider='docker';state='STOPPED'}
        $failedRunDirectory=Join-Path (Join-Path $root 'runs') $failedRunId
        $null=New-Item -ItemType Directory -Path $failedRunDirectory -Force
        [ordered]@{runId=$failedRunId;scopeId=$failedScopeId;instances=@([ordered]@{id='primary';provider='docker';containerId='fixture-failure-container'})} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $failedRunDirectory 'connection-info.json') -Encoding utf8
        $null=Add-SqlServerLabEnvironmentGroupMember -GroupId $script:groupConcurrentGroupId -RunId $failedRunId -StateRoot $root
        $script:groupFailStartRunId=$failedRunId
        $failedStartObserved=$false
        try { $null=Start-SqlServerLabEnvironmentGroup -GroupId $script:groupConcurrentGroupId -StateRoot $root }
        catch { $failedStartObserved=$_.Exception.Message -like '*SYNTHETIC_GROUP_START_FAILURE*' }
        $script:groupFailStartRunId=$null
        $failedGroup=Get-SqlServerLabEnvironmentGroup -GroupId $script:groupConcurrentGroupId -StateRoot $root
        $failedRegistry=Get-LabEnvironmentGroupsRegistry -StateRoot $root
        $failedClaims=@(Get-LabEnvironmentGroupRunClaims -RunId $failedRunId -Registry $failedRegistry)
        $failedClaimBlocked=$false
        try { Assert-LabEnvironmentGroupRunMutation -RunId $failedRunId -Action Start -Registry $failedRegistry }
        catch { $failedClaimBlocked=$_.Exception.Message -like 'LAB_ENVIRONMENT_GROUP_RUN_CLAIMED*' }

        $scopeRunId=[guid]::NewGuid().ToString('D')
        $script:groupFixtureRuns[$scopeRunId]=[PSCustomObject]@{runId=$scopeRunId;scopeId=[guid]::NewGuid().ToString('D');state='STOPPED';metadata=[PSCustomObject]@{windowsPoolMember=$null;workflowKind='hyperv-lab';ownedHostIntegration=$false}}
        $script:groupRegistryLockHeld=$false
        $script:groupRunLockHeld=$false
        $script:groupLockScopeObserved=$false
        function Enter-LabEnvironmentGroupsLock { param($StateRoot) $script:groupRegistryLockHeld=$true; [PSCustomObject]@{Lock='Registry'} }
        function Exit-LabEnvironmentGroupsLock { param($Mutex) $script:groupRegistryLockHeld=$false }
        function Enter-LabEnvironmentGroupRunResourceLock { param($RunId,$StateRoot) $script:groupRunLockHeld=$true; [PSCustomObject]@{Lock='Run'} }
        function Exit-LabEnvironmentGroupRunResourceLock { param($Mutex) $script:groupRunLockHeld=$false }
        function Get-LabEnvironmentGroupsRegistry { param($StateRoot) [PSCustomObject]@{groups=@()} }
        function Assert-LabEnvironmentGroupRunMutation { param($RunId,$Action,$Registry,$GroupOperationContext) }
        function Sync-LabRunRuntimeState { param($Run,$StateRoot) [PSCustomObject]@{Run=$Run} }
        function Start-HyperVLabEnvironment { param($RunId,$StateRoot) $script:groupLockScopeObserved=(-not $script:groupRegistryLockHeld -and $script:groupRunLockHeld); $script:groupFixtureRuns[$RunId].state='RUNNING'; [PSCustomObject]@{RunId=$RunId;Status='RUNNING';Action='STARTED'} }
        function Stop-HyperVLabEnvironment { param($RunId,$StateRoot) $script:groupStopLockScopeObserved=(-not $script:groupRegistryLockHeld -and $script:groupRunLockHeld); $script:groupFixtureRuns[$RunId].state='STOPPED'; [PSCustomObject]@{RunId=$RunId;Status='STOPPED';Action='STOPPED'} }
        function Remove-LabTlsLinuxClientIfPresent { param($StateRoot,$RunId) }
        function Invoke-CleanupPlan { param($RunDir,$ScopeId) $script:groupRemoveLockScopeObserved=(-not $script:groupRegistryLockHeld -and $script:groupRunLockHeld); [PSCustomObject]@{Status='CLEANUP_SUCCEEDED';Steps=0;Errors=0;ProviderSubRuns=@()} }
        function Get-LabProviderSubRuns { param($RunId,$StateRoot) @() }
        function Resolve-LabHostTool { param($Name) [PSCustomObject]@{Available=$true} }
        function Get-DockerLabContainers { param($RunId,$StateRoot) @() }
        function Remove-LabSecrets { param($Path) }
        function Write-LabHeader { param($Message) }
        function Write-LabStatus { param($Label,$Value) }
        function Write-LabInfo { param($Message) }
        function Write-LabSuccess { param($Message) }
        . (Join-Path $sourceRoot 'Public/Start-SqlServerLab.ps1')
        . (Join-Path $sourceRoot 'Public/Stop-SqlServerLab.ps1')
        . (Join-Path $sourceRoot 'Public/Remove-SqlServerLab.ps1')
        $lockScopeStart=Start-SqlServerLab -RunId $scopeRunId -StateRoot $root
        $lockScopeStartReleased=(-not $script:groupRegistryLockHeld -and -not $script:groupRunLockHeld)
        $lockScopeStop=Stop-SqlServerLab -RunId $scopeRunId -StateRoot $root -Confirm:$false
        $lockScopeStopReleased=(-not $script:groupRegistryLockHeld -and -not $script:groupRunLockHeld)

        $removeRunId=[guid]::NewGuid().ToString('D'); $removeScopeId=[guid]::NewGuid().ToString('D')
        $script:groupFixtureRuns[$removeRunId]=[PSCustomObject]@{runId=$removeRunId;scopeId=$removeScopeId;state='RUNNING';metadata=[PSCustomObject]@{windowsPoolMember=$null;ownedHostIntegration=$false}}
        $removeRunDirectory=Join-Path (Join-Path $root 'runs') $removeRunId
        $null=New-Item -ItemType Directory -Path $removeRunDirectory -Force
        [ordered]@{runId=$removeRunId;scopeId=$removeScopeId;instances=@([ordered]@{id='primary';provider='docker'})} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $removeRunDirectory 'connection-info.json') -Encoding utf8
        $lockScopeRemove=Remove-SqlServerLab -RunId $removeRunId -StateRoot $root -Force -Confirm:$false
        $lockScopeRemoveReleased=(-not $script:groupRegistryLockHeld -and -not $script:groupRunLockHeld)

        [PSCustomObject]@{RunId=$runId;GroupA=$groupA;GroupB=$groupB;DefaultListHasBindingStatus=$defaultListHasBindingStatus;SharedBindingStatuses=$sharedBindingStatuses;StaleSharedBindingStatuses=$staleSharedBindingStatuses;StartA=$startA;StartB=$startB;ActiveNoOp=$activeNoOp;ActiveNoOpRegistryLockObserved=$script:groupActiveNoOpRegistryLockObserved;ActiveNoOpRunLockObserved=$script:groupActiveNoOpRunLockObserved;StopA=$stopA;StopB=$stopB;StateAfterA=$stateAfterA;StateAfterB=$stateAfterB;ClaimsAfterRetain=$claimsAfterRetain;RemoveAfterStop=$removeAfterStop;GroupAfterRemove=$groupAfterRemove;AddAfterStop=$addAfterStop;GroupAfterAdd=$groupAfterAdd;GroupCountAfterConcurrentWrite=$groupCountAfterConcurrentWrite;GroupLockScopeObserved=$script:groupStartLockScopeObserved;GroupStopLockScopeObserved=$script:groupStopLockScopeObserved;FailedStartObserved=$failedStartObserved;FailedGroupState=$failedGroup.lifecycleState;FailedGroupOperationState=$failedGroup.operation.state;FailedMemberState=@($failedGroup.operation.members|Where-Object{[string]$_.runId -ieq $failedRunId}|Select-Object -ExpandProperty status);FailedClaimCount=$failedClaims.Count;FailedClaimBlocked=$failedClaimBlocked;LockScopeStart=$lockScopeStart;LockScopeObserved=$script:groupLockScopeObserved;LockScopeStartReleased=$lockScopeStartReleased;LockScopeStop=$lockScopeStop;StopLockScopeObserved=$script:groupStopLockScopeObserved;LockScopeStopReleased=$lockScopeStopReleased;LockScopeRemove=$lockScopeRemove;RemoveLockScopeObserved=$script:groupRemoveLockScopeObserved;LockScopeRemoveReleased=$lockScopeRemoveReleased;RegistryLockWaitsBoundedly=$registryLockWaitsBoundedly}
    } $stateRoot $repoRoot

    Add-CheckResult -Name 'Ein Run kann in zwei Gruppen gebunden werden und nur einmal starten' -Success (
        $result.StartA.Status -eq 'STARTED' -and $result.StartB.Status -eq 'STARTED' -and
        @($result.StartB.Members | Where-Object { $_.status -eq 'UNCHANGED' }).Count -eq 1)
    Add-CheckResult -Name 'Optionale Bindungsprüfung listet aktuelle gemeinsame Run-Bindungen ohne Änderung des Standard-Listverhaltens' -Success (
        -not $result.DefaultListHasBindingStatus -and @($result.SharedBindingStatuses).Count -eq 2 -and
        @($result.SharedBindingStatuses | Where-Object { $_ -ne 'CURRENT' }).Count -eq 0)
    Add-CheckResult -Name 'Optionale Bindungsprüfung kennzeichnet geänderte Connection-Info-Metadaten als STALE' -Success (
        @($result.StaleSharedBindingStatuses).Count -eq 2 -and @($result.StaleSharedBindingStatuses | Where-Object { $_ -ne 'STALE' }).Count -eq 0)
    Add-CheckResult -Name 'Gruppen-Stop behält ein gemeinsam beanspruchtes Mitglied aktiv' -Success (
        $result.StopA.Status -eq 'STOPPED' -and $result.StateAfterA -eq 'RUNNING' -and
        @($result.StopA.Members | Where-Object { $_.status -eq 'RETAINED_SHARED' }).Count -eq 1)
    Add-CheckResult -Name 'Letzter Gruppen-Stop beendet und bestätigt das exklusive Mitglied' -Success (
        $result.StopB.Status -eq 'STOPPED' -and $result.StateAfterB -eq 'STOPPED' -and
        @($result.StopB.Members | Where-Object { $_.status -eq 'STOPPED' }).Count -eq 1)
    Add-CheckResult -Name 'Mitglied nach Gruppen-Stop lösen hält die Registry lesbar' -Success (
        $result.RemoveAfterStop.Status -eq 'REMOVED' -and $result.GroupAfterRemove.lifecycleState -eq 'STOPPED' -and
        @($result.GroupAfterRemove.members).Count -eq 0 -and $null -eq $result.GroupAfterRemove.operation)
    Add-CheckResult -Name 'Mitglied nach Gruppen-Stop erneut binden hält Registry und Run lesbar' -Success (
        $result.AddAfterStop.Status -eq 'ADDED' -and $result.GroupAfterAdd.lifecycleState -eq 'STOPPED' -and
        @($result.GroupAfterAdd.members).Count -eq 1 -and $result.StateAfterB -eq 'STOPPED')
    Add-CheckResult -Name 'Einzel-Start gibt Registry-Sperre nach Claim-Prüfung frei und hält Run-Sperre bis zum Abschluss' -Success (
        $result.LockScopeStart.Action -eq 'STARTED' -and $result.LockScopeObserved -and $result.LockScopeStartReleased)
    Add-CheckResult -Name 'Einzel-Stop gibt Registry-Sperre nach Claim-Prüfung frei und hält Run-Sperre bis zum Abschluss' -Success (
        $result.LockScopeStop.Action -eq 'STOPPED' -and $result.StopLockScopeObserved -and $result.LockScopeStopReleased)
    Add-CheckResult -Name 'Einzel-Remove gibt Registry-Sperre vor Provider-Cleanup frei und hält Run-Sperre bis zum Abschluss' -Success (
        $result.LockScopeRemove.Status -eq 'REMOVED' -and $result.RemoveLockScopeObserved -and $result.LockScopeRemoveReleased)
    Add-CheckResult -Name 'Registry-Mutex wartet begrenzt auf parallele Run-Transaktionen' -Success $result.RegistryLockWaitsBoundedly
    Add-CheckResult -Name 'Gruppen-Provideraktionen laufen ohne Registry-Sperre und halten ihre Run-Sperre' -Success ($result.GroupLockScopeObserved -and $result.GroupStopLockScopeObserved)
    Add-CheckResult -Name 'ACTIVE-No-op führt Laufzeitinventur ohne globale Registry-Sperre, aber mit Run-Sperre aus' -Success (
        $result.ActiveNoOp.Status -eq 'ALREADY_ACTIVE' -and -not $result.ActiveNoOpRegistryLockObserved -and $result.ActiveNoOpRunLockObserved)
    Add-CheckResult -Name 'Retained-Claim während parallelem Stop gibt den Run für den nächsten Stopper frei' -Success (
        $result.StateAfterA -eq 'RUNNING' -and $result.ClaimsAfterRetain.Count -eq 1 -and
        [string]$result.ClaimsAfterRetain[0].GroupId -ceq [string]$result.GroupB.groupId -and
        $result.StopB.Status -eq 'STOPPED' -and $result.StateAfterB -eq 'STOPPED')
    Add-CheckResult -Name 'Parallele unabhängige Registry-Schreibvorgänge bleiben erhalten' -Success ($result.GroupCountAfterConcurrentWrite -eq 3)
    Add-CheckResult -Name 'Fehlgeschlagener Gruppenstart behält Recovery-Zustand und Run-Anspruch' -Success (
        $result.FailedStartObserved -and $result.FailedGroupState -eq 'RECOVERY_REQUIRED' -and
        $result.FailedGroupOperationState -eq 'RECOVERY_REQUIRED' -and @($result.FailedMemberState) -contains 'IN_PROGRESS' -and
        $result.FailedClaimCount -eq 1 -and $result.FailedClaimBlocked)
}
catch {
    Add-CheckResult -Name 'Environment-Group-Lifecycle-Testausführung' -Success $false -Message "$($_.Exception.Message) [$($_.ScriptStackTrace)]"
}
finally {
    Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $stateRoot) { Remove-Item -LiteralPath $stateRoot -Recurse -Force }
}

if ($failures.Count -gt 0) {
    Write-Host "Environment Group Lifecycle Checks: $passed PASS, $($failures.Count) FAIL" -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
Write-Host "Environment Group Lifecycle Checks: $passed PASS" -ForegroundColor Green
exit 0
