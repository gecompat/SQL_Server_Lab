#Requires -Version 7.2
[CmdletBinding()]
param([Parameter(Mandatory)][string]$RepositoryRoot)
$ErrorActionPreference='Stop'
function Get-ProductFunction([string]$Path,[string]$Name) {
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$errors)
    if($errors.Count){throw 'CREATE_EXISTING_NETWORK_PARSE_FAILED'}
    $found=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name},$true))
    if($found.Count -ne 1){throw 'CREATE_EXISTING_NETWORK_FUNCTION_MISSING'}
    $found[0].Extent.Text
}
$apply=Get-ProductFunction (Join-Path $RepositoryRoot 'Private/LabNetwork.ps1') Invoke-LabHyperVNetworkBoundPlan
$create=Get-ProductFunction (Join-Path $RepositoryRoot 'Private/HyperVLabEnvironment.ps1') New-HyperVLabEnvironment
$cases=0
foreach($case in @('ready','actions','initialActions','blocked','name','subnet','prefix','address','nat')) {
    $observed=& {
        param($Definition,$Case)
        . ([scriptblock]::Create($Definition))
        $state=@{Mutations=0}
        $plan=[pscustomobject]@{Contract=[pscustomobject]@{Name='SqlServerLab.HyperVNetworkBoundPlan'};Status='READY';Intent='hostOnly';Name='synthetic-switch';Subnet='192.0.2.0/24';PrefixLength=24;HostAddress='192.0.2.1';Gateway=$null;NatName=$null;AddressMode='static';AdapterId=$null;Actions=@();Blockers=@()}
        $fresh=$plan.PSObject.Copy()
        switch($Case) {
            actions {$fresh.Actions=@('assign-host-address')}
            initialActions {$plan.Actions=@('create-internal-switch')}
            blocked {$fresh.Status='BLOCKED'}
            name {$fresh.Name='other-switch'}
            subnet {$fresh.Subnet='198.51.100.0/24'}
            prefix {$fresh.PrefixLength=25}
            address {$fresh.HostAddress='192.0.2.2'}
            nat {$plan.Intent='nat';$fresh.Intent='nat'}
        }
        function Resolve-LabHyperVNetworkBoundPlan {$fresh}
        function Get-VMSwitch {throw 'NATIVE_QUERY_FORBIDDEN'}
        function New-VMSwitch {$state.Mutations++;throw 'MUTATION_FORBIDDEN'}
        function New-NetIPAddress {$state.Mutations++;throw 'MUTATION_FORBIDDEN'}
        function New-NetNat {$state.Mutations++;throw 'MUTATION_FORBIDDEN'}
        function Remove-VMSwitch {$state.Mutations++;throw 'MUTATION_FORBIDDEN'}
        function Remove-NetIPAddress {$state.Mutations++;throw 'MUTATION_FORBIDDEN'}
        function Remove-NetNat {$state.Mutations++;throw 'MUTATION_FORBIDDEN'}
        $failure=$null;$result=$null
        try{$result=Invoke-LabHyperVNetworkBoundPlan -Plan $plan -RequireExistingNetwork}catch{$failure=$_.Exception.Message}
        [pscustomobject]@{Failure=$failure;Result=$result;Mutations=$state.Mutations}
    } $apply $case
    if($observed.Mutations -ne 0 -or ($case -eq 'ready' -and ($observed.Failure -or $observed.Result.Name -cne 'synthetic-switch')) -or
        ($case -ne 'ready' -and $observed.Failure -notmatch '^LAB_NETWORK_HYPERV_(EXISTING_NETWORK_|BOUND_PLAN_STALE)')) {throw "CREATE_EXISTING_NETWORK_APPLY_FAILED: $case"}
    $cases++
}
foreach($case in @('ready','actions','nat','isolated','missingSwitch','default')) {
    $observed=& {
        param($Definition,$Case)
        . ([scriptblock]::Create($Definition))
        $state=@{Metadata=$null;NativeCalls=0}
        function Write-LabInfo {}
        function Test-HyperVAvailable {[pscustomobject]@{Available=$true}}
        function Get-HyperVImageArtifact {[pscustomobject]@{artifactState='SQL_PREPARED_SEALED'}}
        function Test-HyperVImageArtifactChildValidationEligibility {[pscustomobject]@{Eligible=$true}}
        function Resolve-LabWindowsActivationIntent {$null}
        function Resolve-LabHyperVNetworkBoundPlan {[pscustomobject]@{Status='READY';Actions=$(if($Case -eq 'actions'){@('create-internal-switch')}else{@()})}}
        function Get-LabWorkflowOperationContext {$null}
        function New-LabRunState {param($Metadata) $state.Metadata=$Metadata;throw 'SYNTHETIC_RUN_BOUNDARY'}
        function New-HyperVInstance {$state.NativeCalls++;throw 'MUTATION_FORBIDDEN'}
        $parameters=@{ArtifactId='synthetic-artifact';LabName='synthetic-lab';InstanceId='primary';StateRoot='synthetic-root';SwitchName='synthetic-switch';RequireExistingNetwork=($Case -ne 'default')}
        if($Case -eq 'nat'){$parameters.NetworkIntent='nat'}
        if($Case -eq 'isolated'){$parameters.Isolated=$true}
        if($Case -eq 'missingSwitch'){$parameters.SwitchName=$null}
        $failure=$null
        try{New-HyperVLabEnvironment @parameters}catch{$failure=$_.Exception.Message}
        [pscustomobject]@{Failure=$failure;Metadata=$state.Metadata;NativeCalls=$state.NativeCalls}
    } $create $case
    $expected=if($case -in @('ready','default')){'SYNTHETIC_RUN_BOUNDARY'}elseif($case -eq 'actions'){'HYPERV_LAB_EXISTING_NETWORK_ACTIONS_FORBIDDEN'}else{'HYPERV_LAB_EXISTING_HOSTONLY_SWITCH_REQUIRED'}
    if($observed.Failure -cne $expected -or $observed.NativeCalls -ne 0 -or
        ($case -eq 'ready' -and $observed.Metadata.requireExistingNetwork -ne $true) -or
        ($case -eq 'default' -and $observed.Metadata.ContainsKey('requireExistingNetwork'))) {throw "CREATE_EXISTING_NETWORK_PREFLIGHT_FAILED: $case ($($observed.Failure))"}
    $cases++
}
Write-Host "Prepared existing-network boundary: $cases PASS, 0 FAIL; no native calls."
$true
