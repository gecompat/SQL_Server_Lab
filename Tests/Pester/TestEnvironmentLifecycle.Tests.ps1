#Requires -Version 7.2

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$modulePath = Join-Path $repoRoot 'SqlServerLab.psd1'
$null = Import-Module -Name $modulePath -Force -ErrorAction Stop

function Assert-LifecycleValue {
    param($Actual, $Expected, [string]$Name)
    if ($Actual -ne $Expected) { throw "$Name expected '$Expected', got '$Actual'." }
}

Describe 'Geschuetzter Windows-Testumgebungs-Lifecycle' {
    BeforeEach {
        Mock Get-LabStateRoot { 'state' } -ModuleName SqlServerLab
        Mock Get-LabTestEnvironmentExportDirectory { 'exports' } -ModuleName SqlServerLab
        Mock Get-LabTestEnvironmentRegistry {
            [PSCustomObject]@{
                environments=@(
                    [PSCustomObject]@{ key='WINDOWS_2019_CU32'; platform='windows'; sqlVersion='2019'; runId='run-windows'; instanceId='primary' },
                    [PSCustomObject]@{ key='LINUX_2019_LATEST'; platform='linux'; sqlVersion='2019'; runId='run-linux'; instanceId='primary' }
                )
            }
        } -ModuleName SqlServerLab
        Mock Get-HyperVLabWorkflowRun {
            [PSCustomObject]@{
                Run=[PSCustomObject]@{ runId='run-windows'; scopeId='scope-windows' }
                RunDirectory='run-directory'
                Instance=[PSCustomObject]@{ vmName='test-vm' }
                Connection=[PSCustomObject]@{ instances=@(
                    [PSCustomObject]@{ id='primary'; provider='hyperv'; host='192.0.2.10'; port=1433 }
                ) }
            }
        } -ModuleName SqlServerLab
        Mock Get-LabSecret {
            $secret = [Security.SecureString]::new()
            $secret.AppendChar('x')
            $secret.MakeReadOnly()
            $secret
        } -ModuleName SqlServerLab
        Mock Invoke-HyperVPowerShellDirect { [PSCustomObject]@{ Services=1; StartedServices=0 } } -ModuleName SqlServerLab
        Mock Wait-SqlReady { [PSCustomObject]@{ Ready=$true; Message='ready' } } -ModuleName SqlServerLab
        Mock Start-HyperVLabEnvironment { [PSCustomObject]@{ State='RUNNING' } } -ModuleName SqlServerLab
        Mock Stop-HyperVLabEnvironment { [PSCustomObject]@{ State='STOPPED' } } -ModuleName SqlServerLab
        Mock Sync-LabRunRuntimeState { [PSCustomObject]@{ State='RUNNING' } } -ModuleName SqlServerLab
        Mock Export-SqlServerLabTestEnvironment {
            [PSCustomObject]@{ GroupStatus='READY'; Ready=2; Entries=2 }
        } -ModuleName SqlServerLab
        Mock Sync-LabAutomatedTestEnvironmentConnectionCenter {} -ModuleName SqlServerLab
        Mock Write-LabError {} -ModuleName SqlServerLab
    }

    It 'exportiert beide oeffentlichen Gruppen-Cmdlets' {
        Assert-LifecycleValue (Get-Command Start-SqlServerLabAutomatedTestEnvironment -ErrorAction Stop).Name `
            'Start-SqlServerLabAutomatedTestEnvironment' 'Start command'
        Assert-LifecycleValue (Get-Command Stop-SqlServerLabAutomatedTestEnvironment -ErrorAction Stop).Name `
            'Stop-SqlServerLabAutomatedTestEnvironment' 'Stop command'
    }

    It 'veraendert bei Start -WhatIf keine Runtime und keinen Export' {
        $result = Start-SqlServerLabAutomatedTestEnvironment -StateRoot state -Force -WhatIf

        Assert-LifecycleValue $result.Status 'CANCELLED' 'Status'
        Assert-MockCalled Start-HyperVLabEnvironment -Times 0 -Exactly -ModuleName SqlServerLab -Scope It
        Assert-MockCalled Invoke-HyperVPowerShellDirect -Times 0 -Exactly -ModuleName SqlServerLab -Scope It
        Assert-MockCalled Export-SqlServerLabTestEnvironment -Times 0 -Exactly -ModuleName SqlServerLab -Scope It
    }

    It 'startet nur das registrierte Windows-Ziel scopegebunden und erneuert READY live' {
        Mock Get-HyperVInstanceStatus { [PSCustomObject]@{ Exists=$true; State='Off' } } -ModuleName SqlServerLab

        $result = Start-SqlServerLabAutomatedTestEnvironment -StateRoot state -Force -Confirm:$false

        Assert-LifecycleValue $result.Status 'READY' 'Status'
        Assert-LifecycleValue $result.Started 1 'Started'
        Assert-LifecycleValue $result.Ready 1 'Ready'
        Assert-LifecycleValue $result.Errors 0 'Errors'
        Assert-LifecycleValue $result.Details[0].Key 'WINDOWS_2019_CU32' 'Target key'
        Assert-MockCalled Start-HyperVLabEnvironment -Times 1 -Exactly -ModuleName SqlServerLab -Scope It -ParameterFilter { $RunId -eq 'run-windows' }
        Assert-MockCalled Get-HyperVInstanceStatus -Times 1 -Exactly -ModuleName SqlServerLab -Scope It -ParameterFilter {
            $VMName -eq 'test-vm' -and $ExpectedRunId -eq 'run-windows' -and $ExpectedScopeId -eq 'scope-windows'
        }
        Assert-MockCalled Invoke-HyperVPowerShellDirect -Times 1 -Exactly -ModuleName SqlServerLab -Scope It -ParameterFilter {
            $ExpectedRunId -eq 'run-windows' -and $ExpectedScopeId -eq 'scope-windows'
        }
        Assert-MockCalled Wait-SqlReady -Times 1 -Exactly -ModuleName SqlServerLab -Scope It -ParameterFilter { $ExpectedMajorVersion -eq 15 }
        Assert-MockCalled Export-SqlServerLabTestEnvironment -Times 1 -Exactly -ModuleName SqlServerLab -Scope It
    }

    It 'ist beim Start einer bereits laufenden VM idempotent' {
        Mock Get-HyperVInstanceStatus { [PSCustomObject]@{ Exists=$true; State='Running' } } -ModuleName SqlServerLab

        $result = Start-SqlServerLabAutomatedTestEnvironment -StateRoot state -Force -Confirm:$false

        Assert-LifecycleValue $result.Status 'READY' 'Status'
        Assert-LifecycleValue $result.Started 0 'Started'
        Assert-LifecycleValue $result.Unchanged 1 'Unchanged'
        Assert-LifecycleValue $result.Details[0].Action 'UNCHANGED' 'Action'
        Assert-MockCalled Start-HyperVLabEnvironment -Times 0 -Exactly -ModuleName SqlServerLab -Scope It
        Assert-MockCalled Wait-SqlReady -Times 1 -Exactly -ModuleName SqlServerLab -Scope It
    }

    It 'meldet einen SQL-Readiness-Fehler als Teilstatus und exportiert fail-closed' {
        Mock Get-HyperVInstanceStatus { [PSCustomObject]@{ Exists=$true; State='Off' } } -ModuleName SqlServerLab
        Mock Wait-SqlReady {
            [PSCustomObject]@{ Ready=$false; Message='Server=192.0.2.10,1433;Password=do-not-return' }
        } -ModuleName SqlServerLab
        Mock Export-SqlServerLabTestEnvironment {
            [PSCustomObject]@{ GroupStatus='INCOMPLETE'; Ready=1; Entries=2 }
        } -ModuleName SqlServerLab

        $result = Start-SqlServerLabAutomatedTestEnvironment -StateRoot state -Force -Confirm:$false

        Assert-LifecycleValue $result.Status 'INCOMPLETE' 'Status'
        Assert-LifecycleValue $result.Errors 1 'Errors'
        Assert-LifecycleValue $result.Details[0].Status 'FAILED' 'Target status'
        Assert-LifecycleValue $result.Details[0].Action 'PARTIAL' 'Action'
        if (-not $result.Details[0].VMStarted) { throw 'VMStarted expected true.' }
        if ($result.Details[0].Message -match '192\.0\.2\.10|do-not-return') {
            throw 'Lifecycle error exposed a target endpoint or password.'
        }
        Assert-LifecycleValue $result.Export.GroupStatus 'INCOMPLETE' 'Export status'
    }

    It 'veraendert bei Stop -WhatIf keine Runtime und keinen Export' {
        $result = Stop-SqlServerLabAutomatedTestEnvironment -StateRoot state -Force -WhatIf

        Assert-LifecycleValue $result.Status 'CANCELLED' 'Status'
        Assert-MockCalled Stop-HyperVLabEnvironment -Times 0 -Exactly -ModuleName SqlServerLab -Scope It
        Assert-MockCalled Export-SqlServerLabTestEnvironment -Times 0 -Exactly -ModuleName SqlServerLab -Scope It
    }

    It 'stoppt das registrierte Windows-Ziel scopegebunden und exportiert fail-closed' {
        $script:statusProbe = 0
        Mock Get-HyperVInstanceStatus {
            $script:statusProbe++
            if ($script:statusProbe -eq 1) { [PSCustomObject]@{ Exists=$true; State='Running' } }
            else { [PSCustomObject]@{ Exists=$true; State='Off' } }
        } -ModuleName SqlServerLab
        Mock Export-SqlServerLabTestEnvironment {
            [PSCustomObject]@{ GroupStatus='INCOMPLETE'; Ready=1; Entries=2 }
        } -ModuleName SqlServerLab

        $result = Stop-SqlServerLabAutomatedTestEnvironment -StateRoot state -Force -Confirm:$false

        Assert-LifecycleValue $result.Status 'STOPPED' 'Status'
        Assert-LifecycleValue $result.Released 1 'Released'
        Assert-LifecycleValue $result.Stopped 1 'Stopped'
        Assert-LifecycleValue $result.Errors 0 'Errors'
        Assert-LifecycleValue $result.Export.GroupStatus 'INCOMPLETE' 'Export status'
        Assert-MockCalled Stop-HyperVLabEnvironment -Times 1 -Exactly -ModuleName SqlServerLab -Scope It -ParameterFilter { $RunId -eq 'run-windows' }
        Assert-MockCalled Get-HyperVInstanceStatus -Times 2 -Exactly -ModuleName SqlServerLab -Scope It -ParameterFilter {
            $VMName -eq 'test-vm' -and $ExpectedRunId -eq 'run-windows' -and $ExpectedScopeId -eq 'scope-windows'
        }
        Assert-MockCalled Export-SqlServerLabTestEnvironment -Times 1 -Exactly -ModuleName SqlServerLab -Scope It
    }

    It 'ist beim Stop einer bereits ausgeschalteten VM idempotent' {
        Mock Get-HyperVInstanceStatus { [PSCustomObject]@{ Exists=$true; State='Off' } } -ModuleName SqlServerLab
        Mock Export-SqlServerLabTestEnvironment {
            [PSCustomObject]@{ GroupStatus='INCOMPLETE'; Ready=1; Entries=2 }
        } -ModuleName SqlServerLab

        $result = Stop-SqlServerLabAutomatedTestEnvironment -StateRoot state -Force -Confirm:$false

        Assert-LifecycleValue $result.Status 'STOPPED' 'Status'
        Assert-LifecycleValue $result.Released 0 'Released'
        Assert-LifecycleValue $result.Unchanged 1 'Unchanged'
        Assert-LifecycleValue $result.Details[0].Action 'UNCHANGED' 'Action'
        Assert-MockCalled Stop-HyperVLabEnvironment -Times 0 -Exactly -ModuleName SqlServerLab -Scope It
    }

    It 'meldet den Stopp nicht erfolgreich wenn der erneuerte Export unerwartet READY bleibt' {
        Mock Get-HyperVInstanceStatus { [PSCustomObject]@{ Exists=$true; State='Off' } } -ModuleName SqlServerLab

        $result = Stop-SqlServerLabAutomatedTestEnvironment -StateRoot state -Force -Confirm:$false

        Assert-LifecycleValue $result.Status 'PARTIAL' 'Status'
        Assert-LifecycleValue $result.Stopped 1 'Stopped'
        Assert-LifecycleValue $result.Export.GroupStatus 'READY' 'Export status'
    }
}
