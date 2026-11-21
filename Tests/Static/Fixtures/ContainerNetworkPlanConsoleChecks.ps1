param([Parameter(Mandatory)]$Module)

$ErrorActionPreference = 'Stop'
& $Module {
    $previousExit = $global:LASTEXITCODE
    try {
        $script:syntheticNetworkMode = 'unavailable'
        $script:syntheticNetworkProbes = [Collections.Generic.List[string]]::new()
        function Get-LabRuntimeNetwork { param($Provider) [pscustomobject]@{Name='LabNetwork'} }
        function Get-LabHostToolInvocation {
            param($Name)
            {
                $script:syntheticNetworkProbes.Add($args -join ' ')
                if (($args -join ' ') -eq 'network ls --format {{.Name}}') {
                    $global:LASTEXITCODE = if ($script:syntheticNetworkMode -eq 'unavailable') { 1 } else { 0 }
                    if ($script:syntheticNetworkMode -notin @('unavailable', 'missing')) { 'LabNetwork' }
                    return
                }
                if (($args -join ' ') -eq 'network inspect LabNetwork') {
                    $global:LASTEXITCODE = if ($script:syntheticNetworkMode -eq 'inspect-failed') { 1 } else { 0 }
                    '[{"Name":"LabNetwork","IPAM":{"Config":[{"Subnet":"172.26.0.0/16"}]}}]'
                    return
                }
                throw 'UNEXPECTED_RUNTIME_CALL'
            }
        }
        function Get-LabKnownIpv4Subnets { param($Provider) @('172.26.0.0/16') }
        function Assert-LabRuntimeNetworkAvailable { param($Network,$KnownSubnets) throw 'LAB_NETWORK_SUBNET_CONFLICT: synthetic' }
        function Resolve-LabAvailableContainerNetwork { param($Provider,$Network) [pscustomobject]@{Subnet='198.18.0.0/24'} }
        function Get-LabManagedContainersOnNetwork {
            param($Provider,$NetworkName)
            [pscustomobject]@{RunId='11111111-1111-1111-1111-111111111111';Name='Synthetic';WasRunning=$true}
        }
        function Invoke-LabContainerNetworkMigration { throw 'PREVIEW_ATTEMPTED_MUTATION' }
        function Select-LabConsoleDataItem { param($ScreenId,$Title,$Items) $Items[0].Data }
        function Wait-LabConsoleAcknowledgement { $null }
        foreach ($sample in @(
            @{Mode='unavailable'; Expected='nicht eindeutig geprüft'; Probes=1},
            @{Mode='missing'; Expected='kein Lab-Netz gefunden'; Probes=1},
            @{Mode='inspect-failed'; Expected='nicht eindeutig geprüft'; Probes=2}
        )) {
            $script:syntheticNetworkMode = $sample.Mode
            $script:syntheticNetworkProbes.Clear()
            $result = @(Invoke-LabMenuAction -ActionName ContainerNetworkPlan 6>&1) -join "`n"
            if ($result -notmatch $sample.Expected -or $script:syntheticNetworkProbes.Count -ne $sample.Probes) {
                throw "WRONG_GUIDED_NETWORK_PREVIEW: $($sample.Mode)"
            }
        }
        $script:syntheticNetworkMode = 'conflict'
        $command = Get-LabPublicCommandWebCatalog | Where-Object Name -ceq 'Move-SqlServerLabContainerNetwork'
        $arguments = @{ CommandName=$command.Name; ParameterSetName=$command.ParameterSets[0].Name; Parameters=@{Provider='docker';WhatIf=$true}; Confirmed=$true }
        $browser = Invoke-LabPublicCommandWebRequest @arguments
        if ($browser.Result[0].Status -ne 'MIGRATION_REQUIRED' -or $browser.Result[0].Desired.Subnet -ne '198.18.0.0/24') {
            throw 'WEB_NETWORK_PREVIEW_INVALID'
        }
        Write-Host 'PASS: Vorschau unterscheidet fehlendes Netz von Lesefehlern; CLI und Browser führen keine Migration aus.'
    }
    finally {
        $global:LASTEXITCODE = $previousExit
        Remove-Variable -Name syntheticNetworkMode,syntheticNetworkProbes -Scope Script
    }
}
