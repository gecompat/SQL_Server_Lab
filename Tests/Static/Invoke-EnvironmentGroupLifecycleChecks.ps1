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
        param($root)
        $script:groupFixtureRuns = @{}
        $script:groupFixtureRuntime = @{}
        $script:groupFixtureSubRuns = @{}
        $null = New-Item -ItemType Directory -Path $root -Force
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
        function Get-LabRunRuntimeStatus { param($Run,$StateRoot) $state=[string]$script:groupFixtureRuntime[[string]$Run.runId]; [PSCustomObject]@{State=$state;Instances=@([PSCustomObject]@{Id='primary';Provider='docker';State=$state})} }
        function Test-LabAutomatedTestEnvironmentRun { param($RunId,$OutputDirectory) $false }
        function Assert-LabWindowsPoolMutationAllowed { param($RunId,$StateRoot,$InvalidateEvidence) if ($script:groupFixtureProtected -contains [string]$RunId) { throw 'WINDOWS_POOL_MEMBER_RESERVED' } }
        function Start-SqlServerLab {
            param($RunId,$TimeoutSeconds,$SkipReadyCheck,$StateRoot)
            $script:groupFixtureRuns[[string]$RunId].state='RUNNING'
            $script:groupFixtureRuntime[[string]$RunId]='RUNNING'
            [PSCustomObject]@{Status='STARTED';Errors=0}
        }
        function Stop-SqlServerLab {
            param($RunId,$Force,$SkipHostMemoryRelease,$StateRoot,$Confirm)
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
        $startA=Start-SqlServerLabEnvironmentGroup -GroupId $groupA.groupId -StateRoot $root
        $startB=Start-SqlServerLabEnvironmentGroup -GroupId $groupB.groupId -StateRoot $root
        $stopA=Stop-SqlServerLabEnvironmentGroup -GroupId $groupA.groupId -StateRoot $root
        $stateAfterA=[string]$script:groupFixtureRuntime[$runId]
        $stopB=Stop-SqlServerLabEnvironmentGroup -GroupId $groupB.groupId -StateRoot $root
        $stateAfterB=[string]$script:groupFixtureRuntime[$runId]
        $removeAfterStop=Remove-SqlServerLabEnvironmentGroupMember -GroupId $groupB.groupId -RunId $runId -StateRoot $root
        $groupAfterRemove=Get-SqlServerLabEnvironmentGroup -GroupId $groupB.groupId -StateRoot $root
        $addAfterStop=Add-SqlServerLabEnvironmentGroupMember -GroupId $groupB.groupId -RunId $runId -StateRoot $root
        $groupAfterAdd=Get-SqlServerLabEnvironmentGroup -GroupId $groupB.groupId -StateRoot $root

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
        . (Join-Path $repoRoot 'Public/Start-SqlServerLab.ps1')
        . (Join-Path $repoRoot 'Public/Stop-SqlServerLab.ps1')
        $lockScopeStart=Start-SqlServerLab -RunId $scopeRunId -StateRoot $root
        $lockScopeStartReleased=(-not $script:groupRegistryLockHeld -and -not $script:groupRunLockHeld)
        $lockScopeStop=Stop-SqlServerLab -RunId $scopeRunId -StateRoot $root -Confirm:$false
        $lockScopeStopReleased=(-not $script:groupRegistryLockHeld -and -not $script:groupRunLockHeld)

        [PSCustomObject]@{RunId=$runId;GroupA=$groupA;GroupB=$groupB;StartA=$startA;StartB=$startB;StopA=$stopA;StopB=$stopB;StateAfterA=$stateAfterA;StateAfterB=$stateAfterB;RemoveAfterStop=$removeAfterStop;GroupAfterRemove=$groupAfterRemove;AddAfterStop=$addAfterStop;GroupAfterAdd=$groupAfterAdd;LockScopeStart=$lockScopeStart;LockScopeObserved=$script:groupLockScopeObserved;LockScopeStartReleased=$lockScopeStartReleased;LockScopeStop=$lockScopeStop;StopLockScopeObserved=$script:groupStopLockScopeObserved;LockScopeStopReleased=$lockScopeStopReleased}
    } $stateRoot

    Add-CheckResult -Name 'Ein Run kann in zwei Gruppen gebunden werden und nur einmal starten' -Success (
        $result.StartA.Status -eq 'STARTED' -and $result.StartB.Status -eq 'STARTED' -and
        @($result.StartB.Members | Where-Object { $_.status -eq 'UNCHANGED' }).Count -eq 1)
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
