<#
.SYNOPSIS
    Projektion deklarierter Provider-Capabilities ohne Runtime-Annahme.
#>
function Get-LabProviderCapabilityContract {
    [CmdletBinding()]
    param()

    return @($script:RegisteredProviders.Keys | Sort-Object | ForEach-Object {
        $provider = [string]$_
        $definition = $script:RegisteredProviders[$provider].Definition
        $requirements = if ($definition.requirements) { $definition.requirements } else { $null }
        [PSCustomObject]@{
            Contract = [PSCustomObject]@{ Name = 'SqlServerLab.ProviderCapability'; Version = '1.0'; EvidenceBoundary = 'provider-metadata' }
            Provider = $provider
            RuntimeStatus = if ($definition.runtimeStatus) { [string]$definition.runtimeStatus } else { 'declared' }
            SqlProvisioningScope = if ($definition.sqlProvisioningScope) { [string]$definition.sqlProvisioningScope } elseif ($definition.sqlProvisioning -eq $true) { 'declared' } else { 'none' }
            Capabilities = @($definition.capabilities | ForEach-Object {
                [PSCustomObject]@{ SourceKey = [string]$_; Status = 'DECLARED_SUPPORTED'; Scope = 'provider'; Evidence = 'provider.json' }
            })
            Limitations = @($definition.limitations | ForEach-Object {
                [PSCustomObject]@{ SourceKey = [string]$_; Status = 'DECLARED_LIMITATION'; Scope = 'provider'; Evidence = 'provider.json' }
            })
            Requirements = [PSCustomObject]@{
                Command = if ($requirements.command) { [string]$requirements.command } else { $null }
                MinVersion = if ($requirements.minVersion) { [string]$requirements.minVersion } else { $null }
                OperatingSystem = if ($requirements.os) { [string]$requirements.os } else { $null }
                Commands = @($requirements.commands | ForEach-Object { [string]$_ })
                RunnerLabels = @($requirements.runnerLabels | ForEach-Object { [string]$_ })
            }
        }
    })
}
