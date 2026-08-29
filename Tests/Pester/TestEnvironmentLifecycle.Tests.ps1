#Requires -Version 7.2

Describe 'Geschuetzter provideruebergreifender Testumgebungs-Lifecycle' {
    BeforeAll {
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        $modulePath = Join-Path $repoRoot 'SqlServerLab.psd1'
        $null = Import-Module -Name $modulePath -Force -ErrorAction Stop

        function Assert-LifecycleValue {
            param($Actual, $Expected, [string]$Name)
            if ($Actual -ne $Expected) { throw "$Name expected '$Expected', got '$Actual'." }
        }
    }

    BeforeEach {
        Mock Get-LabStateRoot { 'state' } -ModuleName SqlServerLab
        Mock Get-LabTestEnvironmentExportDirectory { 'exports' } -ModuleName SqlServerLab
        Mock Get-LabTestEnvironmentRegistry {
            [PSCustomObject]@{
                environments=@(
                    [PSCustomObject]@{ key='WINDOWS_2019_CU32'; platform='windows'; sqlVersion='2019'; runId='run-windows'; instanceId='primary' }
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
            [PSCustomObject]@{ GroupStatus='READY'; Ready=1; Entries=1 }
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

    Context 'Provideruebergreifender Gruppen-Lifecycle' {
        BeforeEach {
            Mock Get-LabTestEnvironmentRegistry {
                [PSCustomObject]@{ environments=@(
                    [PSCustomObject]@{ key='LINUX_2019_DOCKER'; platform='linux'; sqlVersion='2019'; runId='run-docker'; instanceId='primary' },
                    [PSCustomObject]@{ key='LINUX_2022_PODMAN'; platform='linux'; sqlVersion='2022'; runId='run-podman'; instanceId='primary' }
                ) }
            } -ModuleName SqlServerLab
            Mock Get-LabAutomatedTestEnvironmentContainerContext {
                $provider = if ([string]$Entry.runId -eq 'run-docker') { 'docker' } else { 'podman' }
                [PSCustomObject]@{
                    Run=[PSCustomObject]@{ runId=[string]$Entry.runId; state='RUNNING' }
                    RunDirectory="run-directory-$provider"
                    Instance=[PSCustomObject]@{
                        id='primary'; provider=$provider; host='127.0.0.1'; port=1433
                        containerId="container-$provider"
                    }
                }
            } -ModuleName SqlServerLab
            Mock Start-SqlServerLab { [PSCustomObject]@{ Action='STARTED'; Status='RUNNING' } } -ModuleName SqlServerLab
            Mock Stop-SqlServerLab { [PSCustomObject]@{ Action='STOPPED'; Status='STOPPED' } } -ModuleName SqlServerLab
        }

        It 'startet Docker und Podman gemeinsam und prueft ihre SQL-Major-Version' {
            Mock Get-LabTestEnvironmentLiveRuntimeStatus { 'STOPPED' } -ModuleName SqlServerLab
            Mock Export-SqlServerLabTestEnvironment { [PSCustomObject]@{ GroupStatus='READY'; Ready=2; Entries=2 } } -ModuleName SqlServerLab

            $result = Start-SqlServerLabAutomatedTestEnvironment -StateRoot state -Force -Confirm:$false

            Assert-LifecycleValue $result.Status 'READY' 'Status'
            Assert-LifecycleValue $result.Started 2 'Started'
            Assert-LifecycleValue $result.Ready 2 'Ready'
            Assert-MockCalled Start-SqlServerLab -Times 2 -Exactly -ModuleName SqlServerLab -Scope It -ParameterFilter {
                $SkipReadyCheck
            }
            Assert-MockCalled Wait-SqlReady -Times 1 -Exactly -ModuleName SqlServerLab -Scope It -ParameterFilter {
                $Provider -eq 'docker' -and $ExpectedMajorVersion -eq 15 -and $ContainerIdOrName -eq 'container-docker'
            }
            Assert-MockCalled Wait-SqlReady -Times 1 -Exactly -ModuleName SqlServerLab -Scope It -ParameterFilter {
                $Provider -eq 'podman' -and $ExpectedMajorVersion -eq 16 -and $ContainerIdOrName -eq 'container-podman'
            }
        }

        It 'stoppt Docker und Podman gemeinsam ohne Registrierung oder Daten zu entfernen' {
            $global:SqlServerLabTestContainerStatusCalls = @{}
            Mock Get-LabTestEnvironmentLiveRuntimeStatus {
                $provider = [string]$Instance.provider
                if (-not $global:SqlServerLabTestContainerStatusCalls.ContainsKey($provider)) {
                    $global:SqlServerLabTestContainerStatusCalls[$provider] = 0
                }
                $global:SqlServerLabTestContainerStatusCalls[$provider]++
                if ($global:SqlServerLabTestContainerStatusCalls[$provider] -eq 1) { 'RUNNING' } else { 'STOPPED' }
            } -ModuleName SqlServerLab
            Mock Export-SqlServerLabTestEnvironment { [PSCustomObject]@{ GroupStatus='INCOMPLETE'; Ready=0; Entries=2 } } -ModuleName SqlServerLab

            try {
                $result = Stop-SqlServerLabAutomatedTestEnvironment -StateRoot state -Force -Confirm:$false

                Assert-LifecycleValue $result.Status 'STOPPED' 'Status'
                Assert-LifecycleValue $result.Released 2 'Released'
                Assert-LifecycleValue $result.Stopped 2 'Stopped'
                Assert-MockCalled Stop-SqlServerLab -Times 2 -Exactly -ModuleName SqlServerLab -Scope It
                Assert-MockCalled Export-SqlServerLabTestEnvironment -Times 1 -Exactly -ModuleName SqlServerLab -Scope It
            }
            finally { Remove-Variable -Name SqlServerLabTestContainerStatusCalls -Scope Global -ErrorAction SilentlyContinue }
        }
    }
}
