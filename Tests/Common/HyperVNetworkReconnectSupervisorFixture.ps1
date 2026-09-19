#Requires -Version 7.2
[CmdletBinding()]
param([Parameter(Mandatory)][string]$HelperPath)
$ErrorActionPreference='Stop'
. $HelperPath
foreach($case in @('success','failure','timeout','unconfirmed','waitThrows','killThrows')){
    $process=[pscustomobject]@{Case=$case;WaitCalls=0;KillCalls=0;ExitCode=$(if($case -eq 'failure'){7}else{0})}
    $process | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value {
        param($Milliseconds)
        $this.WaitCalls++
        if($this.Case -eq 'waitThrows' -and $this.WaitCalls -eq 1){throw 'SYNTHETIC_WAIT_FAILURE'}
        if($this.Case -in @('success','failure')){return $true}
        if($this.Case -eq 'unconfirmed'){return $false}
        return $this.WaitCalls -gt 1
    }
    $process | Add-Member -MemberType ScriptMethod -Name Kill -Value {
        param($EntireProcessTree)
        if(-not $EntireProcessTree){throw 'TREE_KILL_REQUIRED'}
        $this.KillCalls++
        if($this.Case -eq 'killThrows'){throw 'SYNTHETIC_KILL_FAILURE'}
    }
    $result=Wait-HyperVNetworkAcceptanceChild -Process $process -TimeoutSeconds 1
    $ok=switch($case){
        'success' {$result.Terminated -and -not $result.TimedOut -and $result.ExitCode -eq 0 -and $process.KillCalls -eq 0}
        'failure' {$result.Terminated -and $result.ExitCode -eq 7 -and $process.KillCalls -eq 0}
        'timeout' {$result.Terminated -and $result.TimedOut -and $null -eq $result.ExitCode -and $process.KillCalls -eq 1}
        'unconfirmed' {-not $result.Terminated -and $result.TimedOut}
        'waitThrows' {$result.Terminated -and $null -eq $result.ExitCode -and $process.KillCalls -eq 1}
        'killThrows' {-not $result.Terminated -and $null -eq $result.ExitCode}
    }
    if(-not $ok){throw "NETWORK_SUPERVISOR_FIXTURE_FAILED: $case"}
}
# Invoke the real cleanup function through a disposable module with fake
# resources. The source and ambiguous ownership must never reach removal.
foreach($case in @('none','source','operation','sourceBinding','foreignStep','foreignPath','cleanupFailure','vhdRemains','valid')){
    $module=New-Module -ArgumentList $case -ScriptBlock {
        param($Case)
        $script:case=$Case;$script:removes=0
        function Get-LabOperationOwnedRun {
            if($script:case -eq 'none'){return $null}
            [pscustomobject]@{
                runId=$(if($script:case -eq 'source'){'11111111-1111-1111-1111-111111111111'}else{'22222222-2222-2222-2222-222222222222'})
                scopeId='33333333-3333-3333-3333-333333333333'
                metadata=[pscustomobject]@{workflowKind='hyperv-lab';workflowOperationId=$(if($script:case -eq 'operation'){'foreign'}else{'synthetic-op'});sourceRunId=$(if($script:case -eq 'sourceBinding'){'foreign'}else{'11111111-1111-1111-1111-111111111111'})}
            }
        }
        function Get-CleanupPlan {
            [pscustomobject]@{runId='22222222-2222-2222-2222-222222222222';scopeId='33333333-3333-3333-3333-333333333333';steps=@(
                [pscustomobject]@{provider='hyperv';resourceType=$(if($script:case -eq 'foreignStep'){'switch'}else{'vhdx'});resourceId='synthetic-vhdx'}
            )}
        }
        function Test-HyperVPathWithinRunDirectory {$script:case -ne 'foreignPath'}
        function Remove-SqlServerLab {$script:removes++;[pscustomobject]@{Status=$(if($script:case -eq 'cleanupFailure'){'FAILED'}else{'REMOVED'})}}
        function Test-Path {$script:case -eq 'vhdRemains'}
        Export-ModuleMember -Function @()
    }
    try {
        $errorCode=$null
        try{Remove-HyperVNetworkAcceptanceOwnedRun -Module $module -OperationId synthetic-op -SourceRunId '11111111-1111-1111-1111-111111111111' -StateRoot ([IO.Path]::GetTempPath())}catch{$errorCode=$_.Exception.Message}
        $removes=& $module {$script:removes}
        $expected=switch($case){
            {$_ -in @('none','valid')} {$null}
            {$_ -in @('source','operation','sourceBinding')} {'HYPERV_NETWORK_ACCEPTANCE_CLEANUP_OWNERSHIP_INVALID'}
            'foreignStep' {'HYPERV_NETWORK_ACCEPTANCE_CLEANUP_PLAN_INVALID'}
            'foreignPath' {'HYPERV_NETWORK_ACCEPTANCE_CLEANUP_PATH_INVALID'}
            'cleanupFailure' {'HYPERV_NETWORK_ACCEPTANCE_CLEANUP_FAILED'}
            'vhdRemains' {'HYPERV_NETWORK_ACCEPTANCE_VHDX_REMAINS'}
        }
        $expectedRemoves=[int]($case -in @('valid','cleanupFailure','vhdRemains'))
        if($errorCode -ne $expected -or $removes -ne $expectedRemoves){throw "NETWORK_CLEANUP_FIXTURE_FAILED: $case ($errorCode)"}
    } finally {Remove-Module -ModuleInfo $module -Force -ErrorAction SilentlyContinue}
}
Write-Host 'Network supervisor/recovery: 15 PASS, 0 FAIL; no native calls.'
$true
