param([Parameter(Mandatory)]$Module)

$ErrorActionPreference = 'Stop'
& $Module {
    $previousExit = $global:LASTEXITCODE
    try {
        $script:syntheticNetworkMode = 'unavailable'
        $script:syntheticNetworkProbes = [Collections.Generic.List[string]]::new()
        $script:syntheticNetworkRoot = Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-network-plan-'+[guid]::NewGuid().ToString('N'))
        function Get-LabStateRoot { $script:syntheticNetworkRoot }
        function Get-LabRuntimeNetwork { param($Provider) [pscustomobject]@{Name='LabNetwork';Subnet='172.26.0.0/16'} }
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
                    $id = if ($script:syntheticNetworkMode -eq 'network-replaced') { 'b'*64 } else { 'a'*64 }
                    $label = if ($script:syntheticNetworkMode -eq 'unmanaged') { 'other' } else { 'managed' }
                    ConvertTo-Json -InputObject @(@{Name='LabNetwork';Id=$id;Driver='bridge';Internal=$false;
                        Labels=@{'sql-server-lab.network'=$label};IPAM=@{Config=@(@{Subnet='172.26.0.0/16'})}}) -Depth 6 -Compress
                    return
                }
                throw 'UNEXPECTED_RUNTIME_CALL'
            }
        }
        function Get-LabKnownIpv4Subnets { param($Provider,$ExcludeNetworkId) @('172.26.0.0/16') }
        function Resolve-LabAvailableContainerNetwork { param($Provider,$Network,[switch]$PlanOnly)
            if (-not $PlanOnly) { throw 'PREVIEW_ATTEMPTED_PROCESS_CHANGE' }
            [pscustomobject]@{Subnet='198.18.0.0/24'}
        }
        function Get-LabManagedContainersOnNetwork {
            param($Provider,$NetworkName,$StateRoot)
            if ($script:syntheticNetworkMode -eq 'foreign-member') { throw 'LAB_NETWORK_MIGRATION_UNVERIFIED_MEMBER' }
            [pscustomobject]@{Id=('c'*64);RunId='11111111-1111-1111-1111-111111111111';ScopeId='22222222-2222-2222-2222-222222222222';
                InstanceId='primary';Name='Synthetic';WasRunning=$true;Aliases=@('synthetic')}
        }
        function Invoke-LabContainerNetworkMigration { throw 'PREVIEW_ATTEMPTED_MUTATION' }
        function Select-LabConsoleDataItem { param($ScreenId,$Title,$Items) $Items[0].Data }
        function Read-LabConsoleTextInput { param($Prompt) [pscustomobject]@{Status='Confirmed';Value=''} }
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
        if ($browser.Result[0].Status -ne 'MIGRATION_REQUIRED' -or $browser.Result[0].Desired.Subnet -ne '198.18.0.0/24' -or
            $browser.Result[0].PlanKey -cnotmatch '^[a-f0-9]{64}$') {
            throw 'WEB_NETWORK_PREVIEW_INVALID'
        }
        $key = $browser.Result[0].PlanKey
        $explicit = Move-SqlServerLabContainerNetwork -Provider docker -TargetSubnet '198.18.2.0/24' -WhatIf
        if ($explicit.Status -cne 'MIGRATION_REQUIRED' -or $explicit.Desired.Subnet -cne '198.18.2.0/24' -or $explicit.PlanKey -ceq $key) {
            throw 'EXPLICIT_NETWORK_TARGET_NOT_BOUND'
        }
        foreach ($case in @(
            @{Subnet='172.26.2.0/24';Code='LAB_NETWORK_MIGRATION_TARGET_CONFLICT'},
            @{Subnet='198.300.2.0/24';Code='LAB_NETWORK_MIGRATION_TARGET_INVALID'}
        )) {
            try { Move-SqlServerLabContainerNetwork -Provider docker -TargetSubnet $case.Subnet -WhatIf | Out-Null; throw 'UNSAFE_TARGET_ACCEPTED' }
            catch { if ($_.Exception.Message -cne $case.Code) { throw } }
        }
        foreach ($example in @(@{ Mode='unmanaged'; Reason='LAB_NETWORK_MIGRATION_UNVERIFIED_NETWORK' },
                               @{ Mode='foreign-member'; Reason='LAB_NETWORK_MIGRATION_UNVERIFIED_MEMBER' })) {
            $script:syntheticNetworkMode=$example.Mode
            $blocked=Move-SqlServerLabContainerNetwork -Provider docker -Confirm:$false
            if ($blocked.Status -cne 'MIGRATION_BLOCKED' -or $blocked.Reason -cne $example.Reason -or @($blocked.Actions).Count) {
                throw 'UNSAFE_NETWORK_MIGRATION_PLAN_ACCEPTED'
            }
        }
        $script:syntheticNetworkMode='network-replaced'
        $staleVeto = try { Move-SqlServerLabContainerNetwork -Provider docker -ExpectedPlanKey $key -Confirm:$false | Out-Null; $false }
            catch { $_.Exception.Message -ceq 'LAB_NETWORK_MIGRATION_PREVIEW_CHANGED' }
        if (-not $staleVeto) { throw 'REPLACED_NETWORK_ACCEPTED' }
        Write-Host 'PASS: Vorschau unterscheidet fehlendes Netz von Lesefehlern und sperrt fremde oder ausgetauschte Ressourcen.'
    }
    finally {
        $global:LASTEXITCODE = $previousExit
        Remove-Variable -Name syntheticNetworkMode,syntheticNetworkProbes,syntheticNetworkRoot -Scope Script
    }
}
