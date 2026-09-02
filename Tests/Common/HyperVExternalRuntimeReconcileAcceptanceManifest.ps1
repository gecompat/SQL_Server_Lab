function Get-HyperVExternalRuntimeReconcileAcceptanceManifest {
    [CmdletBinding()]
    param([switch]$IncludeSoftware)

    $instance = [ordered]@{
        id = 'sql2022-ext'; version = '2022'; provider = 'hyperv'; os = 'windows'
        profile = 'performance'; autostart = 'off'
        network = [ordered]@{ intent='hostOnly'; exposure='host' }
        serverConfig = [ordered]@{
            externalScripts = [ordered]@{
                enabled = $true
                resourceGovernor = [ordered]@{ maxMemoryPercent=40; maxProcesses=32 }
            }
        }
    }
    if ($IncludeSoftware) {
        $instance.software = @(
            [ordered]@{ id='sql-python'; scope='sqlExternalRuntime' },
            [ordered]@{ id='sql-r'; scope='sqlExternalRuntime' },
            [ordered]@{ id='sql-java'; scope='sqlExternalRuntime' }
        )
    }
    return [ordered]@{
        name = 'external-runtime-reconcile-native'
        automation = [ordered]@{ mode='unattended' }
        instances = @($instance)
    }
}
