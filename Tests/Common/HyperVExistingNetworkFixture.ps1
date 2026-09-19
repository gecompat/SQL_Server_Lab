#Requires -Version 7.2
# Extract only the product function; all host and guest dependencies are mocks.
[CmdletBinding()]
param([Parameter(Mandatory)][string]$ProductPath)
$ErrorActionPreference='Stop'
$tokens=$null;$parseErrors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($ProductPath,[ref]$tokens,[ref]$parseErrors)
if($parseErrors.Count){throw 'EXISTING_NETWORK_FIXTURE_PARSE_FAILED'}
$definition=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Enable-HyperVLabHostSqlAccess'},$true))
if($definition.Count -ne 1){throw 'EXISTING_NETWORK_FIXTURE_FUNCTION_MISSING'}
foreach($case in @('ready','actions','blocked','hostDrift','subnetDrift','multiple','disconnected','lan')){
    $probe=& {
        param($Case,$Definition)
        . ([scriptblock]::Create($Definition))
        $state=@{GuestCalls=0;Mutations=0}
        $network=[pscustomobject]@{Status='READY';Actions=@();Name='synthetic-switch';Intent='hostOnly';Subnet='192.0.2.0/24';HostAddress='192.0.2.1';PrefixLength=24}
        $binding=[pscustomobject]@{name='synthetic-switch';intent='hostOnly';subnet='192.0.2.0/24';hostAddress='192.0.2.1';prefixLength=24}
        $adapter=[pscustomobject]@{SwitchName='synthetic-switch'}
        switch($Case){
            'actions' {$network.Actions=@('create-switch')}
            'blocked' {$network.Status='BLOCKED'}
            'hostDrift' {$network.HostAddress='192.0.2.2'}
            'subnetDrift' {$network.Subnet='198.51.100.0/24'}
            'disconnected' {$adapter.SwitchName=$null}
            'lan' {$binding.intent='lan'}
        }
        function Get-HyperVLabWorkflowRun { [pscustomobject]@{Run=[pscustomobject]@{runId='synthetic-run';scopeId='synthetic-scope'};Instance=[pscustomobject]@{vmName='synthetic-vm';labNetwork=$binding}} }
        function Get-HyperVManagedVM { [pscustomobject]@{VM=[pscustomobject]@{State='Running'}} }
        function Resolve-LabHyperVNetworkBoundPlan { $network }
        function Get-VMNetworkAdapter { if($Case -eq 'multiple'){@($adapter,$adapter)}else{$adapter} }
        function Resolve-LabHyperVNetwork { $state.Mutations++;throw 'FORBIDDEN_INFRASTRUCTURE' }
        function Invoke-LabHyperVNetworkBoundPlan { $state.Mutations++;throw 'FORBIDDEN_INFRASTRUCTURE' }
        function Add-VMNetworkAdapter { $state.Mutations++;throw 'FORBIDDEN_ADAPTER' }
        function Initialize-HyperVGuestLabNetwork { $state.GuestCalls++;throw 'SYNTHETIC_GUEST_BOUNDARY' }
        function Write-LabInfo {}
        $secret=[securestring]::new();$secret.AppendChar('x');$secret.MakeReadOnly()
        $credential=[pscredential]::new('synthetic-user',$secret)
        $failure=$null
        try{Enable-HyperVLabHostSqlAccess -RunId synthetic-run -Credential $credential -RequireExistingNetwork}catch{$failure=$_.Exception.Message}
        finally{$secret.Dispose()}
        [pscustomobject]@{Failure=$failure;GuestCalls=$state.GuestCalls;Mutations=$state.Mutations}
    } $case $definition[0].Extent.Text
    $expected=switch($case){
        'ready' {'SYNTHETIC_GUEST_BOUNDARY'}
        'lan' {'HYPERV_LAB_HOST_SQL_EXISTING_NETWORK_REQUIRED'}
        {$_ -in @('multiple','disconnected')} {'HYPERV_LAB_HOST_SQL_EXISTING_ADAPTER_REQUIRED'}
        default {'HYPERV_LAB_HOST_SQL_EXISTING_NETWORK_CHANGED'}
    }
    if($probe.Failure -ne $expected -or $probe.Mutations -ne 0 -or $probe.GuestCalls -ne [int]($case -eq 'ready')){
        throw "EXISTING_NETWORK_FIXTURE_FAILED: $case ($($probe.Failure))"
    }
}
Write-Host 'Existing-network product boundary: 8 PASS, 0 FAIL; no native calls.'
$true
