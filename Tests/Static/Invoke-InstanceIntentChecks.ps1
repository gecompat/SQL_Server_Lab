#Requires -Version 7.2
<#
.SYNOPSIS
    Prueft providerneutrale, geheimnisfreie Instance Intents.
#>
[CmdletBinding()]
param([Alias('h','help','?')][switch]$ShowHelp)

if ($ShowHelp) { Get-Help -Full -Name $PSCommandPath | Out-Host; return }

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$modulePath = Join-Path $repoRoot 'SqlServerLab.psd1'
$failures = [System.Collections.Generic.List[string]]::new()
$passed = 0
. (Join-Path $PSScriptRoot '..' 'Common' 'CheckResult.ps1')

Write-Host ''
Write-Host 'SQL_Server_Lab - Instance Intent Checks' -ForegroundColor Cyan

try {
    Import-Module $modulePath -Force -ErrorAction Stop
    $module = Get-Module SqlServerLab
    $result = & $module {
        $resolved = [PSCustomObject]@{
            name = 'Intent check'
            instances = @(
                [PSCustomObject]@{
                    id = 'container'; provider = 'docker'; version = '2022'; profile = 'standard'; networkName = 'host-specific-network-name'
                    databases = @([PSCustomObject]@{ name = 'IntentDb' })
                    drives = @([PSCustomObject]@{
                        id = 'data'; containerPath = '/var/opt/mssql/data'; hostPath = 'C:\private\must-not-persist'
                        readOnly = $false; sizeLimitGB = 20; type = 'ssd'
                    })
                    software = @([PSCustomObject]@{
                        id = 'sqlpackage'; optional = $false; source = 'url'; package = 'private-package'
                        url = 'https://private.invalid/tool'; command = 'secret command must not persist'
                    })
                    hyperv = $null
                },
                [PSCustomObject]@{
                    id = 'vm'; provider = 'hyperv'; version = '2022'; profile = 'performance'; networkName = $null
                    databases = @(); drives = @([PSCustomObject]@{
                        id = 'log'; containerPath = 'L:\Log'; hostPath = $null; readOnly = $false; sizeLimitGB = 40; type = 'ssd'
                    })
                    software = @(); hyperv = [PSCustomObject]@{
                        switchName = 'private-physical-switch'; processorCount=6; dynamicMemoryEnabled=$true
                        memoryMinimumMB=2048; memoryStartupMB=4096; memoryMaximumMB=12288
                    }
                },
                [PSCustomObject]@{
                    id = 'vm-isolated'; provider = 'hyperv'; version = '2022'; profile = 'standard'; networkName = $null
                    network = [PSCustomObject]@{ intent = 'isolated'; exposure = 'none' }
                    databases = @(); drives = @(); software = @(); hyperv = $null
                }
            )
        }

        $snapshot = New-LabDesiredStateSnapshot -ResolvedLab $resolved -ProvisioningMode manifest -PersistentData $false
        $container = $snapshot.Instances | Where-Object Id -eq 'container' | Select-Object -First 1
        $vm = $snapshot.Instances | Where-Object Id -eq 'vm' | Select-Object -First 1
        $isolatedVm = $snapshot.Instances | Where-Object Id -eq 'vm-isolated' | Select-Object -First 1
        $serialized = $snapshot | ConvertTo-Json -Depth 20

        [PSCustomObject]@{
            Contract = $container.Intents.Contract.Name -eq 'SqlServerLab.InstanceIntent' -and $container.Intents.Contract.Version -eq '1.0'
            Drive = $container.Intents.Drives[0].Role -eq 'sqlData' -and
                $container.Intents.Drives[0].GuestPath -eq '/var/opt/mssql/data' -and
                $container.Intents.Drives[0].Binding -eq 'host-mount' -and
                $container.Intents.Drives[0].CapabilityStatus -eq 'DECLARED_SUPPORTED'
            Network = $container.Intents.Network.Intent -eq 'nat' -and
                $container.Intents.Network.Exposure -eq 'host' -and
                $container.Intents.Network.Binding -eq 'managed-bridge-nat' -and
                $container.Intents.Network.RequiredCapability -eq 'nat-network' -and
                $container.Intents.Network.CapabilityStatus -eq 'DECLARED_SUPPORTED'
            SoftwareBoundary = $container.Intents.Software.Items[0].Id -eq 'sqlpackage' -and
                $container.Intents.Software.CapabilityStatus -eq 'DECLARED_UNSUPPORTED'
            HyperV = $vm.Intents.Drives[0].Role -eq 'sqlLog' -and
                $vm.Intents.Drives[0].RequiredCapability -eq 'run-local-additional-vhdx' -and
                $vm.Intents.Drives[0].CapabilityStatus -eq 'DECLARED_SUPPORTED' -and
                $vm.Intents.Network.Intent -eq 'hostOnly' -and
                $vm.Intents.Network.Binding -eq 'internal-switch' -and
                $vm.Intents.Network.CapabilityStatus -eq 'DECLARED_SUPPORTED'
            HyperVResources = $vm.Intents.Resources.Contract.Name -eq 'SqlServerLab.HyperVResourceIntent' -and
                $vm.Intents.Resources.ProcessorCount -eq 6 -and $vm.Intents.Resources.DynamicMemoryEnabled -and
                $vm.Intents.Resources.MemoryMinimumMB -eq 2048 -and $vm.Intents.Resources.MemoryStartupMB -eq 4096 -and
                $vm.Intents.Resources.MemoryMaximumMB -eq 12288 -and
                $vm.Intents.Resources.RequiredCapability -eq 'hyperv-resource-reconcile'
            HyperVIsolated = $isolatedVm.Intents.Network.Intent -eq 'isolated' -and
                $isolatedVm.Intents.Network.Exposure -eq 'none' -and
                $isolatedVm.Intents.Network.Binding -eq 'private-switch' -and
                -not $isolatedVm.Intents.Network.ManagedBinding -and
                $isolatedVm.Intents.Network.CapabilityStatus -eq 'DECLARED_SUPPORTED'
            Sanitized = $serialized -notmatch '(?i)host-specific-network-name|private-physical-switch|must-not-persist|secret command|hostPath|https://'
        }
    }

    Add-CheckResult -Name 'Desired State enthaelt versionierten InstanceIntent-Contract' -Success $result.Contract
    Add-CheckResult -Name 'Drive Intent normalisiert Rolle, Gastpfad, Binding und Capability' -Success $result.Drive
    Add-CheckResult -Name 'Network Intent normalisiert Hostzugriff und Provider-Evidenz' -Success $result.Network
    Add-CheckResult -Name 'Nicht implementierte Software-Bindung bleibt sichtbar unsupported' -Success $result.SoftwareBoundary
    Add-CheckResult -Name 'Hyper-V-HostOnly-Intent bindet internen Switch und implementierte Drives' -Success $result.HyperV
    Add-CheckResult -Name 'Hyper-V-Ressourcenintent bindet vCPU und RAM-Modus mit Min-/Startup-/Max' -Success $result.HyperVResources
    Add-CheckResult -Name 'Hyper-V-Isolated-Intent bindet privaten Switch ohne Host-Exposure' -Success $result.HyperVIsolated
    Add-CheckResult -Name 'Intent Snapshot persistiert keine hostlokalen Pfade, Namen, URLs oder Befehle' -Success $result.Sanitized
}
catch {
    Add-CheckResult -Name 'Instance Intent Testausfuehrung' -Success $false -Message $_.Exception.Message
}

Write-Host ''
Write-Host "Ergebnis: $passed PASS, $($failures.Count) FAIL" -ForegroundColor Cyan
if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
exit 0
