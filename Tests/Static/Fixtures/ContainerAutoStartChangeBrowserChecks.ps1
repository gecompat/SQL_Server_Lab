#Requires -Version 7.2
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
$module = Import-Module (Join-Path $repo 'SqlServerLab.psd1') -Force -PassThru
try {
    & $module {
        function Assert-Case([bool]$Condition, [string]$Name) {
            if (-not $Condition) { throw "AUTOSTART_CHANGE_BROWSER_CHECK_FAILED: $Name" }
        }
        function Get-LabDataRootDefault { $script:changeRoot }
        function Get-LabContainerPortConsoleTargets {
            param($DataRoot)
            if ($DataRoot -cne 'SYNTHETIC_ROOT') { throw 'UNBOUND_ROOT' }
            $script:changeTarget.PSObject.Copy()
        }
        function Get-SqlServerLabContainerAutoStartPlan {
            param($RunId, $InstanceId, $StateRoot, $AutoStart)
            $script:planCalls++
            if ($RunId -cne $script:changeTarget.RunId -or $InstanceId -cne 'primary' -or $StateRoot -cne 'PRIVATE_CANARY') { throw 'UNBOUND_TARGET' }
            $noChange = $AutoStart -ceq 'off'
            [pscustomobject]@{
                Contract = [pscustomobject]@{ Name = 'SqlServerLab.ContainerAutoStartPlan'; Version = '1.0' }
                RunId = $RunId; InstanceId = $InstanceId; Provider = 'docker'
                Actual = [pscustomobject]@{ AutoStart = 'OFF'; Lifecycle = 'RUNNING' }
                Desired = [pscustomobject]@{ AutoStart = $AutoStart.ToUpperInvariant() }
                ChangeClass = if ($noChange) { 'no-op' } else { 'live' }
                Preview = [pscustomobject]@{ Downtime = 'NONE'; DataImpact = 'NONE'; Recovery = 'RESUME_STATE_COMMIT' }
                NoChange = $noChange; CanApply = $true; MutationAllowed = -not $noChange; PlanKey = ('f' * 64)
            }
        }
        function Set-SqlServerLabContainerAutoStart {
            param($RunId, $InstanceId, $StateRoot, $AutoStart, $ExpectedAutoStartPlanKey, [switch]$Confirm)
            $script:setCalls++
            if ($RunId -cne $script:changeTarget.RunId -or $InstanceId -cne 'primary' -or $StateRoot -cne 'PRIVATE_CANARY' -or
                $AutoStart -cne 'on' -or $ExpectedAutoStartPlanKey -cne ('f' * 64) -or
                -not $PSBoundParameters.ContainsKey('Confirm') -or $Confirm) { throw 'UNBOUND_EXECUTION' }
            [pscustomobject]@{ RunId = $RunId; InstanceId = $InstanceId; Provider = 'docker'
                Status = 'SUCCEEDED'; AutoStart = $AutoStart; Changed = $true; NoChange = $false; Path = 'PRIVATE_CANARY' }
        }
        function Send-Change([hashtable]$Payload) {
            Invoke-LabContainerAutoStartChangeBrowser -Store $store -Body ($Payload | ConvertTo-Json -Compress)
        }
        function Reject([hashtable]$Payload, [string]$Code) {
            try { $null = Send-Change $Payload; throw 'EXPECTED_REJECTION_MISSING' }
            catch { Assert-Case ($_.Exception.Message -ceq $Code) $Code }
        }

        $script:changeRoot = 'SYNTHETIC_ROOT'
        $script:changeTarget = [pscustomobject]@{
            RunId = [guid]::NewGuid().ToString('D'); ScopeId = [guid]::NewGuid().ToString('D')
            InstanceId = 'primary'; Provider = 'docker'; StateRoot = 'PRIVATE_CANARY'
        }
        $script:setCalls = 0; $script:planCalls = 0
        $store = @{}
        $list = Read-LabContainerAutoStartChangeBrowser -Store $store
        $selection = $list.Items[0].Selection
        Assert-Case ($list.Items.Count -eq 1 -and ($list | ConvertTo-Json -Depth 4) -notmatch 'PRIVATE_CANARY|StateRoot|ScopeId' -and
            $script:planCalls -eq 0 -and $script:setCalls -eq 0) 'read only exposes bound target metadata'
        Reject @{ Action = 'Apply'; Confirmed = $true; Selection = $selection } 'AUTOSTART_CHANGE_BROWSER_PLAN_INVALID'
        $scope = $script:changeTarget.ScopeId
        $script:changeTarget.ScopeId = [guid]::NewGuid().ToString('D')
        Reject @{ Action = 'Plan'; AutoStart = 'on'; Selection = $selection } 'AUTOSTART_CHANGE_BROWSER_SELECTION_CHANGED'
        Assert-Case ($script:planCalls -eq 0 -and $script:setCalls -eq 0) 'changed scope fails before plan or set'
        $script:changeTarget.ScopeId = $scope
        $plan = Send-Change @{ Action = 'Plan'; AutoStart = 'off'; Selection = $selection }
        Assert-Case ($plan.NoChange -and $null -eq $plan.Selection -and $script:setCalls -eq 0) 'no-op has no confirmation token'
        $plan = Send-Change @{ Action = 'Plan'; AutoStart = 'on'; Selection = $selection }
        Assert-Case ($plan.Selection -cmatch '^[a-f0-9]{32}$' -and $plan.Desired -ceq 'ON' -and $plan.Current -ceq 'OFF' -and
            ($plan | ConvertTo-Json) -notmatch 'PlanKey|PRIVATE_CANARY' -and $script:setCalls -eq 0) 'plan stays read-only and hides executor key'
        Reject @{ Action = 'Apply'; Confirmed = $false; Selection = $plan.Selection } 'AUTOSTART_CHANGE_BROWSER_CONFIRMATION_REQUIRED'
        Reject @{ Action = 'Apply'; Confirmed = $true; Selection = $plan.Selection; AutoStart = 'off' } 'AUTOSTART_CHANGE_BROWSER_CONFIRMATION_REQUIRED'
        $superseded = $plan.Selection
        $plan = Send-Change @{ Action = 'Plan'; AutoStart = 'on'; Selection = $selection }
        Reject @{ Action = 'Apply'; Confirmed = $true; Selection = $superseded } 'AUTOSTART_CHANGE_BROWSER_PLAN_INVALID'
        $receipt = Send-Change @{ Action = 'Apply'; Confirmed = $true; Selection = $plan.Selection }
        Assert-Case ($receipt.Status -ceq 'SUCCEEDED' -and $receipt.PSObject.Properties.Name.Count -eq 1) 'fixed apply receipt'
        Reject @{ Action = 'Apply'; Confirmed = $true; Selection = $plan.Selection } 'AUTOSTART_CHANGE_BROWSER_SELECTION_EXPIRED'
        Assert-Case ($script:setCalls -eq 1) 'only the confirmed current plan reached the setter'
    }
}
finally { Remove-Module $module -Force }
Write-Host 'CONTAINER AUTOSTART CHANGE BROWSER: PASS'
