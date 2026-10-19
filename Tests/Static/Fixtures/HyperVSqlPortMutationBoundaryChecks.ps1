#Requires -Version 7.2
[CmdletBinding()]
param([string]$RepoRoot=(Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path)
$ErrorActionPreference='Stop'
$definitions=@()
foreach($source in @(
    @{Path='Private/HyperVSqlPortReconcile.ps1';Name='Set-LabHyperVSqlPortBinding'},
    @{Path='Providers/HyperV/HyperVProvider.ps1';Name='Invoke-HyperVPowerShellDirect'}
)){
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot $source.Path),[ref]$tokens,[ref]$errors)
    if($errors.Count){throw 'PORT_MUTATION_SOURCE_PARSE_FAILED'}
    $function=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $source.Name},$false))
    if($function.Count -ne 1){throw 'PORT_MUTATION_FUNCTION_NOT_UNIQUE'}
    $definitions+=$function[0].Extent.Text
}
$module=New-Module -Name ('PortMutationBoundary_'+[guid]::NewGuid().ToString('N')) -ScriptBlock {
    param($Definitions)
    foreach($definition in $Definitions){. ([scriptblock]::Create($definition))}
} -ArgumentList (,$definitions)
try{
    $result=& $module {
        $script:passed=0;$script:failed=0
        $fixtureVm=[guid]'18f73038-d5f5-47cd-84bb-9d8ad03ea2e9'
        $otherVm=[guid]'529894c9-0bda-4876-93b3-34a2f0857e28'
        $fixtureRun='27c36648-0c5c-4574-a2d4-84ee7336414e'
        $fixtureScope='d594f37f-c6d0-4f36-a640-62903d099ae5'
        $credential=[pscredential]::new('synthetic-user',[securestring]::new())
        function Check([bool]$Value,[string]$Label){if($Value){$script:passed++;Write-Host "PASS: $Label"}else{$script:failed++;Write-Host "FAIL: $Label"}}
        function Reset-PortCase {
            $script:direct=0;$script:writes=0;$script:fallback=0;$script:managedReads=0
            $script:selector=$null;$script:producerArguments=$null;$script:identityArguments=$null
            $script:nativeId=$fixtureVm;$script:nativeState='Running';$script:missingVm=$false
            $script:lostReply=$false;$script:guestTransport='direct';$script:badReceipt=$false
            $script:context=[pscustomobject]@{RunId=$fixtureRun;ScopeId=$fixtureScope;ConnectionInstance=[pscustomobject]@{vmName='synthetic-port-vm';vmId=$fixtureVm.ToString()};Desired=[pscustomobject]@{Port=15433};FirewallRequired=$false;FirewallRemoteAddress=$null}
        }
        function Get-HyperVManagedVM {
            param($VMName,$ExpectedRunId,$ExpectedScopeId)
            $script:managedReads++;$script:identityArguments=@($VMName,$ExpectedRunId,$ExpectedScopeId)
            if(-not $script:missingVm){[pscustomobject]@{VM=[pscustomobject]@{Id=$script:nativeId;Name='synthetic-renamed-vm';State=$script:nativeState};Identity=[pscustomobject]@{guestTransport=$script:guestTransport}}}
        }
        function Start-LabActionProgress {[pscustomobject]@{}}
        function Update-LabActionProgress {}
        function Stop-LabActionProgress {}
        function Wait-LabProgressDelay {}
        function Write-LabInfo {}
        function Invoke-Command {
            [CmdletBinding()]param([guid]$VMId,[string]$VMName,$Credential,$ScriptBlock,$ArgumentList,[switch]$AsJob)
            $script:direct++;$script:writes++
            $script:selector=[pscustomobject]@{VmIdBound=$PSBoundParameters.ContainsKey('VMId');VmId=$VMId;VmNameBound=$PSBoundParameters.ContainsKey('VMName');VmName=$VMName}
            $script:producerArguments=$ArgumentList
            # Model the consumer write without executing any supplied guest body.
            [pscustomobject]@{Id=1}
        }
        function Receive-LabProgressJob {
            if($script:lostReply){throw [Management.Automation.ErrorRecord]::new([Exception]::new('SYNTHETIC_PORT_REPLY_LOST'),'SYNTHETIC_PORT_REPLY_LOST',[Management.Automation.ErrorCategory]::OpenError,$null)}
            [pscustomobject]@{Status='APPLIED';Port=$(if($script:badReceipt){15434}else{15433});ServiceName='MSSQLSERVER';ServiceStatus='Running'}
        }
        function Invoke-HyperVWinRmFallback {$script:fallback++;throw 'FIXTURE_UNEXPECTED_FALLBACK'}
        function Invoke-PortCase([hashtable]$Extra=@{}){Set-LabHyperVSqlPortBinding -Context $script:context -Credential $credential @Extra}
        function Reject-Port([string]$Code,[hashtable]$Extra){
            $blocked=$false;try{$null=Invoke-PortCase $Extra}catch{$blocked=$_.Exception.Message -ceq $Code}
            Check ($blocked -and $script:direct -eq 0 -and $script:writes -eq 0 -and $script:fallback -eq 0) $Code
        }
        Reset-PortCase;$script:lostReply=$true
        $blocked=$false;try{$null=Invoke-PortCase}catch{$blocked=$_.Exception.Message -ceq 'SYNTHETIC_PORT_REPLY_LOST'}
        $legacyObservation=[pscustomobject]@{Direct=$script:direct;SyntheticWrites=$script:writes;Fallback=$script:fallback}
        Check ($blocked -and $script:direct -eq 1 -and $script:writes -eq 1 -and $script:fallback -eq 0) 'Lost reply is propagated after one synthetic port write without replay'
        Reset-PortCase;$script:lostReply=$true
        $blocked=$false;try{$null=Invoke-PortCase @{ExpectedVmId=$fixtureVm}}catch{$blocked=$_.Exception.Message -ceq 'SYNTHETIC_PORT_REPLY_LOST'}
        Check ($blocked -and $script:direct -eq 1 -and $script:writes -eq 1 -and $script:fallback -eq 0 -and $script:selector.VmIdBound -and -not $script:selector.VmNameBound) 'Strict lost reply keeps immutable VMId and single mutation attempt'
        Reset-PortCase
        $value=$null;try{$value=Invoke-PortCase @{ExpectedVmId=$fixtureVm}}catch{}
        Check ($value -and $value.Status -ceq 'APPLIED' -and $script:selector.VmIdBound -and $script:selector.VmId -eq $fixtureVm -and -not $script:selector.VmNameBound) 'Strict success invokes the VMId selector despite a native rename'
        Check (($script:identityArguments -join '/') -ceq ('synthetic-port-vm/'+$fixtureRun+'/'+$fixtureScope)) 'Actual transport receives exact run and scope ownership selectors'
        Check ($script:producerArguments.Count -eq 4 -and $script:producerArguments[0] -eq 15433 -and -not $script:producerArguments[1] -and -not $script:producerArguments[2] -and $script:producerArguments[3] -ceq 'SQL_Server_Lab SQL TCP Host') 'Port, isolated firewall choice and rule identifier remain unchanged'
        Reset-PortCase
        Reject-Port 'HYPERV_SQL_PORT_RECONCILE_VM_BINDING_INVALID' @{ExpectedVmId=[guid]::Empty}
        Check ($script:managedReads -eq 0) 'Empty selected VMId rejects before native discovery'
        foreach($field in @('RunId','ScopeId')){
            foreach($bad in @($null,' ','foreign',[guid]::Empty.ToString())){
                Reset-PortCase;$script:context.$field=$bad
                Reject-Port 'HYPERV_SQL_PORT_RECONCILE_VM_BINDING_INVALID' @{ExpectedVmId=$fixtureVm}
                Check ($script:managedReads -eq 0) 'Malformed ownership selector never expands native filters'
            }
        }
        foreach($bad in @($null,'foreign',$otherVm.ToString())){
            Reset-PortCase;$script:context.ConnectionInstance.vmId=$bad
            Reject-Port 'HYPERV_SQL_PORT_RECONCILE_VM_BINDING_INVALID' @{ExpectedVmId=$fixtureVm}
            Check ($script:managedReads -eq 0) 'Missing or foreign stored VMId rejects before native discovery'
        }
        Reset-PortCase;$script:context.ConnectionInstance.vmName=' '
        Reject-Port 'HYPERV_SQL_PORT_RECONCILE_VM_BINDING_INVALID' @{ExpectedVmId=$fixtureVm}
        Reset-PortCase;$script:nativeId=$otherVm
        Reject-Port 'HYPERV_GUEST_VM_ID_MISMATCH' @{ExpectedVmId=$fixtureVm}
        Check ($script:managedReads -eq 1) 'Same-name native replacement blocks at the actual transport boundary'
        Reset-PortCase;$script:guestTransport='lab-winrm'
        $value=$null;try{$value=Invoke-PortCase @{ExpectedVmId=$fixtureVm}}catch{}
        Check ($value -and $script:direct -eq 1 -and $script:fallback -eq 0 -and $script:selector.VmIdBound) 'Lab-WinRM identity cannot bypass selected Direct-only port mutation'
        Reset-PortCase;$script:badReceipt=$true
        $blocked=$false;try{$null=Invoke-PortCase @{ExpectedVmId=$fixtureVm}}catch{$blocked=$_.Exception.Message -ceq 'HYPERV_SQL_PORT_RECONCILE_APPLY_RECEIPT_INVALID'}
        Check ($blocked -and $script:direct -eq 1 -and $script:writes -eq 1) 'A mismatching port receipt is rejected without another guest invocation'
        Reset-PortCase
        $value=Invoke-PortCase
        Check ($value.Status -ceq 'APPLIED' -and $script:selector.VmNameBound -and -not $script:selector.VmIdBound) 'Omitted option retains legacy VMName selection and valid receipt'
        Reset-PortCase;$script:nativeState='Off'
        $blocked=$false;try{$null=Invoke-PortCase @{ExpectedVmId=$fixtureVm}}catch{$blocked=$_.Exception.Message -like 'PowerShell Direct erfordert*'}
        Check ($blocked -and $script:direct -eq 0) 'Stopped selected VM cannot enter a guest block'
        [pscustomobject]@{Passed=$script:passed;Failed=$script:failed;LegacyLostReply=$legacyObservation;NativeGuestBodies=0;NativeActions=0}
    }
    Write-Host ('PORT MUTATION BOUNDARY: '+$result.Passed+' PASS / '+$result.Failed+' FAIL; legacy lostreply Direct='+$result.LegacyLostReply.Direct+'; native NOT_EXECUTED')
    if($result.Failed){throw 'PORT_MUTATION_BOUNDARY_FAILED'}
    return $result
}finally{Remove-Module $module -Force}
