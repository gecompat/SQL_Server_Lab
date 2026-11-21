#Requires -Version 7.2
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
$module = Import-Module (Join-Path $repo 'SqlServerLab.psd1') -Force -PassThru
try {
    & $module {
        function Assert-Case([bool]$Condition, [string]$Name) {
            if (-not $Condition) { throw "AUTOSTART_RECOVERY_BROWSER_CHECK_FAILED: $Name" }
        }
        function Get-LabDataRootDefault { 'SYNTHETIC_ROOT' }
        function Get-LabContainerAutoStartRecoveryTargets {
            param($DataRoot)
            if ($DataRoot -cne 'SYNTHETIC_ROOT') { throw 'UNBOUND_ROOT' }
            $script:recoveryFixtureTarget.PSObject.Copy()
        }
        function Resume-SqlServerLabContainerAutoStart {
            param($RunId, $InstanceId, $StateRoot, $ExpectedOperationId, [switch]$Confirm)
            $script:recoveryFixtureCalls++
            $target = $script:recoveryFixtureTarget
            if ($RunId -cne $target.RunId -or $InstanceId -cne $target.InstanceId -or
                $StateRoot -cne $target.StateRoot -or $ExpectedOperationId -cne $target.OperationId -or
                -not $PSBoundParameters.ContainsKey('Confirm') -or $Confirm) { throw 'UNBOUND_EXECUTION' }
            [pscustomobject]@{ RunId = $RunId; InstanceId = $InstanceId; Provider = $target.Provider
                Status = 'RECOVERY_SUCCEEDED'; Changed = $true; OperationId = $ExpectedOperationId; Path = 'PRIVATE_CANARY' }
        }
        function Get-Body($Selection) {
            @{ Confirmed = $true; Selection = $Selection } | ConvertTo-Json -Compress
        }
        function Assert-Rejected([hashtable]$Store, [string]$Body, [string]$Code) {
            try {
                $null = Invoke-LabContainerAutoStartRecoveryBrowser -Selections $Store -Body $Body
                throw 'EXPECTED_REJECTION_MISSING'
            }
            catch { Assert-Case ($_.Exception.Message -ceq $Code) $Code }
        }

        $script:recoveryFixtureTarget = [pscustomobject]@{
            RunId = [guid]::NewGuid().ToString('D'); ScopeId = [guid]::NewGuid().ToString('D')
            InstanceId = 'primary'; Provider = 'docker'; StateRoot = 'PRIVATE_CANARY'
            OperationId = [guid]::NewGuid().ToString('D'); TargetAutoStart = 'on'
        }
        $script:recoveryFixtureCalls = 0
        $store = @{}
        $list = Read-LabContainerAutoStartRecoveryBrowser -Selections $store
        Assert-Case ($list.Items.Count -eq 1 -and ($list | ConvertTo-Json -Depth 5) -notmatch 'PRIVATE_CANARY|OperationId|ScopeId' -and
            $script:recoveryFixtureCalls -eq 0) 'read projects only selection and operator fields'
        $id = $list.Items[0].Selection
        Assert-Rejected $store ('{"Confirmed":false,"Selection":"' + $id + '"}') 'AUTOSTART_RECOVERY_BROWSER_CONFIRMATION_REQUIRED'
        Assert-Rejected $store ('{"Confirmed":false,"Confirmed":true,"Selection":"' + $id + '"}') 'AUTOSTART_RECOVERY_BROWSER_CONFIRMATION_REQUIRED'
        Assert-Rejected $store (Get-Body ('0' * 32)) 'AUTOSTART_RECOVERY_BROWSER_SELECTION_INVALID'
        $store[$id].Expires = [DateTime]::UtcNow.AddMinutes(-1)
        Assert-Rejected $store (Get-Body $id) 'AUTOSTART_RECOVERY_BROWSER_SELECTION_EXPIRED'
        $id = (Read-LabContainerAutoStartRecoveryBrowser -Selections $store).Items[0].Selection
        $script:recoveryFixtureTarget.OperationId = [guid]::NewGuid().ToString('D')
        Assert-Rejected $store (Get-Body $id) 'AUTOSTART_RECOVERY_BROWSER_SELECTION_CHANGED'
        Assert-Case ($script:recoveryFixtureCalls -eq 0) 'all rejected inputs remain read-only'
        $id = (Read-LabContainerAutoStartRecoveryBrowser -Selections $store).Items[0].Selection
        $receipt = Invoke-LabContainerAutoStartRecoveryBrowser -Selections $store -Body (Get-Body $id)
        Assert-Case ($receipt.Status -ceq 'RECOVERY_SUCCEEDED' -and $receipt.PSObject.Properties.Name.Count -eq 1) 'fixed receipt'
        Assert-Rejected $store (Get-Body $id) 'AUTOSTART_RECOVERY_BROWSER_SELECTION_INVALID'
        Assert-Case ($script:recoveryFixtureCalls -eq 1) 'confirmed selection consumed once'
    }
}
finally { Remove-Module $module -Force }
Write-Host 'CONTAINER AUTOSTART RECOVERY BROWSER: PASS'
