# Actual helper/Stop/Reconcile composition; all effects are isolated synthetic spies.
& {
    . "$root/Private/StoppedHostMemory.ps1"
    . "$root/Public/Stop-SqlServerLab.ps1"
    . "$root/Public/Invoke-SqlServerLabReconcileAction.ps1"
    $script:hostReads=0;$script:backendCalls=0;$script:providerCalls=0
    function Get-LabStopHostMemory {$script:hostReads++;[pscustomobject]@{TotalMB=100;AvailableMB=80}}
    function Get-LabStopMemoryTarget {$script:backendCalls++;throw 'Forbidden backend access'}
    function Invoke-LabStopMemoryCommand {$script:backendCalls++;throw 'Forbidden memory command'}
    function Write-LabWarning {}
    foreach($providers in @(@('hyperv'),@('unknown'),@('docker','hyperv'),@('docker','unknown'),@())) {
        $script:hostReads=0;$script:backendCalls=0
        $result=Invoke-LabStoppedHostMemoryRelease -Provider $providers
        Add-CheckResult ('Actual helper non-container set has no host access: '+($providers -join ',')) ($result.Status -eq 'NOT_APPLICABLE' -and $script:hostReads -eq 0 -and $script:backendCalls -eq 0)
        $result=Invoke-LabStoppedHostMemoryRelease -Provider $providers -Skip
        Add-CheckResult ('Actual helper explicit skip binds non-container set: '+($providers -join ',')) ($result.Status -eq 'DISABLED' -and $script:hostReads -eq 0 -and $script:backendCalls -eq 0)
    }
    foreach($providers in @(@('docker'),@('podman'),@('docker','podman'))) {
        $script:hostReads=0
        $result=Invoke-LabStoppedHostMemoryRelease -Provider $providers
        Add-CheckResult ('Container set keeps host decision: '+($providers -join ',')) ($result.Status -eq 'NOT_REQUIRED' -and $script:hostReads -eq 1 -and $script:backendCalls -eq 0)
    }
    $testRoot=Join-Path ([IO.Path]::GetTempPath()) ('stop-provider-contract-'+[guid]::NewGuid().ToString('N'))
    $runId='00000000-0000-0000-0000-000000000124'
    $runDirectory=Join-Path $testRoot "runs/$runId"
    $null=New-Item -ItemType Directory -Path $runDirectory
    function Test-LabAutomatedTestEnvironmentRun {return $false}
    function Assert-LabWindowsPoolMutationAllowed {}
    function Get-LabRunState {[pscustomobject]@{state='RUNNING';metadata=[pscustomobject]@{name='synthetic';workflowKind=$script:workflow}}}
    function Sync-LabRunRuntimeState {param($Run,$StateRoot)[pscustomobject]@{Run=$Run}}
    function Get-Command {return $null}
    function Get-ContainerRuntime {param($PreferredRuntime)$PreferredRuntime}
    function Get-LabHostToolInvocation {'Invoke-SyntheticStopProvider'}
    function Invoke-SyntheticStopProvider {param($Verb) $script:providerCalls++;$global:LASTEXITCODE=0;if($Verb -eq 'ps'){'synthetic-owned-container'}elseif($Verb -eq 'inspect'){'synthetic-owned-container'}}
    function Stop-HyperVLabEnvironment {[pscustomobject]@{Status='STOPPED';Action='STOPPED';SyntheticHyperV=$true}}
    function Set-LabProviderSubRunState {}
    function Set-LabRunState {}
    function Write-LabInfo {}
    function Write-LabSuccess {}
    function Write-LabError {}
    function Get-SqlServerLabReconcilePlan {[pscustomobject]@{Actions=@([pscustomobject]@{Operation='STOP';Provider='hyperv'});HighestChangeClass='RESTART';IsNoOp=$false;Warnings=@()}}
    try {
        $script:LabAutomatedTestEnvironmentGroupOperation=$false;$script:workflow='synthetic-modern'
        foreach($providers in @(@('hyperv'),@('docker','hyperv'),@('unknown'))) {
            @{instances=@($providers | ForEach-Object {@{provider=$_}})} | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $runDirectory 'connection-info.json')
            foreach($skip in @($false,$true)) {
                $script:hostReads=0;$script:backendCalls=0
                $result=Stop-SqlServerLab -RunId $runId -StateRoot $testRoot -SkipHostMemoryRelease:$skip -Confirm:$false
                Add-CheckResult ('Complete Stop binds actual helper '+($providers -join ',')+' skip='+$skip) ($result.Action -eq 'STOPPED' -and $result.HostMemory.Status -eq $(if($skip){'DISABLED'}else{'NOT_APPLICABLE'}) -and $script:hostReads -eq 0 -and $script:backendCalls -eq 0)
            }
        }
        $script:workflow='hyperv-lab';$script:hostReads=0
        $result=Stop-SqlServerLab -RunId $runId -StateRoot $testRoot -Confirm:$false
        Add-CheckResult 'Regular HyperV stop retains dedicated lifecycle and no host maintenance' ($result.SyntheticHyperV -and $script:hostReads -eq 0)
        $script:workflow='synthetic-modern';@{instances=@(@{provider='hyperv'})} | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $runDirectory 'connection-info.json')
        $script:hostReads=0;$script:backendCalls=0
        $result=Invoke-SqlServerLabReconcileAction -RunId $runId -TargetState STOPPED -StateRoot $testRoot -Confirm:$false
        Add-CheckResult 'Actual Reconcile STOP reaches complete Stop and helper without provider bind failure' ($result.ExecutionSummary.Status -eq 'SUCCEEDED' -and $result.ExecutionPlan[0].Result.HostMemory.Status -eq 'NOT_APPLICABLE' -and $script:hostReads -eq 0 -and $script:backendCalls -eq 0)
    } finally {
        Remove-Item -LiteralPath (Join-Path $runDirectory 'connection-info.json')
        Remove-Item -LiteralPath $runDirectory
        Remove-Item -LiteralPath (Join-Path $testRoot 'runs')
        Remove-Item -LiteralPath $testRoot
    }
}
