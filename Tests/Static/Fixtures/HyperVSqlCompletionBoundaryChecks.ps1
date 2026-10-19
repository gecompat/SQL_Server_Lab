#Requires -Version 7.2
[CmdletBinding()]
param([string]$RepoRoot=(Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path)
$ErrorActionPreference='Stop'
function Get-BoundaryFunctionAst([string]$Path,[string]$Name){
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$errors)
    if($errors.Count){throw 'BOUNDARY_SOURCE_PARSE_FAILED'}
    $found=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $Name},$false))
    if($found.Count -ne 1){throw 'BOUNDARY_FUNCTION_NOT_UNIQUE'}
    return $found[0]
}
$environment=Join-Path $RepoRoot 'Private/HyperVLabEnvironment.ps1'
$cases=@(foreach($entry in @(
    @{Path=$environment;Name='Complete-HyperVLabSqlImage'},
    @{Path=$environment;Name='Enable-HyperVLabHostSqlAccess'},
    @{Path=$environment;Name='Repair-HyperVLabSqlWmiProvider'},
    @{Path=(Join-Path $RepoRoot 'Private/LabNetwork.ps1');Name='Initialize-HyperVGuestLabNetwork'}
)){
    $fn=Get-BoundaryFunctionAst $entry.Path $entry.Name
    $calls=@($fn.FindAll({param($n)$n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -ceq 'Invoke-HyperVPowerShellDirect'},$true))
    if($calls.Count -ne 1){throw 'BOUNDARY_GUEST_CALL_NOT_UNIQUE'}
    [pscustomobject]@{Name=$entry.Name;Text=$calls[0].Extent.Text}
})
$transport=Get-BoundaryFunctionAst (Join-Path $RepoRoot 'Providers/HyperV/HyperVProvider.ps1') 'Invoke-HyperVPowerShellDirect'
$module=New-Module -Name ('SqlCompletionBoundary_'+[guid]::NewGuid().ToString('N')) -ScriptBlock {
    param($PublicPath,$TransportText)
    . $PublicPath
    . ([scriptblock]::Create($TransportText))
} -ArgumentList (Join-Path $RepoRoot 'Public/Invoke-SqlServerLabWorkflowAction.ps1'),$transport.Extent.Text
try{
    $result=& $module {
        param($Cases)
        $script:passed=0;$script:failed=0
        function Check([bool]$Value,[string]$Label){
            if($Value){$script:passed++;Write-Host ('PASS: '+$Label)}else{$script:failed++;Write-Host ('FAIL: '+$Label)}
        }
        function Write-LabInfo {}
        function Write-LabSuccess {}
        function Test-HyperVAvailable {[pscustomobject]@{Available=$true;Message='synthetic'}}
        Set-Variable -Name IsWindows -Scope Script -Value $true -Force
        $script:completionCalls=0
        function Complete-HyperVLabSqlImage {
            param($RunId,$Credential,$SqlSaPassword,$StateRoot='synthetic-default-state',$MediaRoot='synthetic-default-media')
            $script:completionCalls++
            [pscustomobject]@{Run=$RunId;State=$StateRoot;Media=$MediaRoot;StateBound=$PSBoundParameters.ContainsKey('StateRoot');MediaBound=$PSBoundParameters.ContainsKey('MediaRoot');User=$Credential.UserName;SaLength=$SqlSaPassword.Length}
        }
        $password=[Security.SecureString]::new();$password.AppendChar('x');$password.MakeReadOnly()
        $sa=[Security.SecureString]::new();$sa.AppendChar('y');$sa.AppendChar('z');$sa.MakeReadOnly()
        try{
            foreach($inputs in @(@{StateRoot='C:/synthetic/own-state';MediaRoot='D:/synthetic/own-media'},@{StateRoot='C:/synthetic/own-state'},@{MediaRoot='D:/synthetic/own-media'})){
                $v=Invoke-SqlServerLabWorkflowAction -Action CompleteHyperVLabSql -BuildId own-run -GuestPassword $password -SaPassword $sa @inputs
                Check ($v.Result.Run -ceq 'own-run' -and $v.Result.User -ceq 'Administrator' -and $v.Result.SaLength -eq 2) 'Public completion preserves run, transient credential and separate SQL password'
                Check ($v.Result.StateBound -eq $inputs.ContainsKey('StateRoot') -and $v.Result.MediaBound -eq $inputs.ContainsKey('MediaRoot')) 'Only explicitly supplied completion roots reach the core'
                if($inputs.ContainsKey('StateRoot')){Check ($v.Result.State -ceq $inputs.StateRoot) 'Explicit state root reaches the actual public completion branch unchanged'}
                if($inputs.ContainsKey('MediaRoot')){Check ($v.Result.Media -ceq $inputs.MediaRoot) 'Explicit media root reaches the actual public completion branch unchanged'}
            }
            $v=Invoke-SqlServerLabWorkflowAction -Action CompleteHyperVLabSql -BuildId own-run -GuestPassword $password
            Check (-not $v.Result.StateBound -and -not $v.Result.MediaBound -and $v.Result.SaLength -eq 1) 'Omitted roots retain core defaults and legacy password fallback'
            foreach($name in @('StateRoot','MediaRoot')){
                foreach($bad in @($null,'',' ')){
                    $before=$script:completionCalls;$rejected=$false;$override=@{};$override[$name]=$bad
                    try{$null=Invoke-SqlServerLabWorkflowAction -Action CompleteHyperVLabSql -BuildId own-run -GuestPassword $password @override}
                    catch{$rejected=$_.Exception.Message -cmatch '^HYPERV_LAB_SQL_COMPLETE_(STATE|MEDIA)_ROOT_REQUIRED$'}
                    Check ($rejected -and $script:completionCalls -eq $before) ('Empty explicit '+$name+' rejects before target/core access')
                }
            }
            $script:guestTransport='direct'
            function Get-HyperVManagedVM {[pscustomobject]@{VM=[pscustomobject]@{State='Running'};Identity=[pscustomobject]@{guestTransport=$script:guestTransport}}}
            function Start-LabActionProgress {[pscustomobject]@{Synthetic=$true}}
            function Update-LabActionProgress {}
            function Stop-LabActionProgress {}
            function Wait-LabProgressDelay {}
            function Invoke-Command {$script:directCalls++;$script:consumerWrites++;[pscustomobject]@{Id=1}}
            function Receive-LabProgressJob {
                throw [Management.Automation.ErrorRecord]::new([Exception]::new('SYNTHETIC_REPLY_LOST'),'SYNTHETIC_REPLY_LOST',[Management.Automation.ErrorCategory]::OpenError,$null)
            }
            function Invoke-HyperVWinRmFallback {$script:fallbackCalls++;$script:consumerWrites++;throw 'SYNTHETIC_FALLBACK_REPLY_LOST'}
            $Credential=[pscredential]::new('Administrator',$password)
            $SqlSaPassword=$sa;$SqlPort=1433;$usesLan=$false
            $lab=[pscustomobject]@{Instance=[pscustomobject]@{vmName='synthetic-own-vm'};Run=[pscustomobject]@{runId='own-run';scopeId='own-scope'}}
            $VMName='synthetic-own-vm';$ExpectedRunId='own-run';$ExpectedScopeId='own-scope'
            $fallbackAddress='192.0.2.10';$address='192.0.2.10';$addressMode='static';$gateway=$null;$dnsServers=@()
            $Network=[pscustomobject]@{PrefixLength=24;Name='synthetic-internal';HostAddress='192.0.2.1'}
            $networkReceipt=[pscustomobject]@{Address='192.0.2.10'}
            $vmBinding=@{} # The omitted selector lane now uses an explicit empty splat in the actual callers.
            $observations=@(foreach($case in $Cases){
                $script:directCalls=0;$script:fallbackCalls=0;$script:consumerWrites=0;$failed=$false
                # Real producer arguments and real transport; only native leaves are injected.
                # Invoke-Command models a consumer write; Receive then loses its reply.
                # The supplied guest ScriptBlock is never executed.
                try{$null=& ([scriptblock]::Create($case.Text))}catch{$failed=$true}
                Check ($failed -and $script:directCalls -eq 1 -and $script:fallbackCalls -eq 0 -and $script:consumerWrites -eq 1) ($case.Name+' propagates lost reply after one synthetic consumer write without transport/fallback replay')
                [pscustomobject]@{Caller=$case.Name;DirectCalls=$script:directCalls;FallbackCalls=$script:fallbackCalls;SyntheticConsumerWrites=$script:consumerWrites;ErrorPropagated=$failed}
            })
            $script:guestTransport='lab-winrm'
            foreach($case in $Cases){
                $script:directCalls=0;$script:fallbackCalls=0;$script:consumerWrites=0;$failed=$false
                try{$null=& ([scriptblock]::Create($case.Text))}catch{$failed=$true}
                Check ($failed -and $script:directCalls -eq 0 -and $script:fallbackCalls -eq 1 -and $script:consumerWrites -eq 1) ($case.Name+' preserves one explicitly bound Lab-WinRM attempt without trying Direct')
            }
            [pscustomobject]@{Success=($script:failed -eq 0);Passed=$script:passed;Failed=$script:failed;Observations=$observations;NativeActions=0}
        }finally{$password.Dispose();$sa.Dispose()}
    } $cases
    Write-Host ('SQL completion boundary: '+$result.Passed+' PASS, '+$result.Failed+' FAIL; native setup/SQL NOT_EXECUTED')
    return $result
}finally{Remove-Module $module -Force -ErrorAction SilentlyContinue}
