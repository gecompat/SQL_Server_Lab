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
$slotPlan = Get-BoundaryFunctionAst $environment 'Get-LabHyperVSqlSlotBrowserPlan'
$slotInstall = Get-BoundaryFunctionAst $environment 'Invoke-HyperVLabSqlSlotInstall'
$guestSetup = @($slotInstall.FindAll({
    param($node)
    $node -is [Management.Automation.Language.ScriptBlockExpressionAst] -and
        'ExpectedSetupVersionPattern' -in $node.ScriptBlock.ParamBlock.Parameters.Name.VariablePath.UserPath
}, $true))
if ($guestSetup.Count -ne 1) { throw 'BOUNDARY_SQL_SETUP_SCRIPT_NOT_UNIQUE' }
$module=New-Module -Name ('SqlCompletionBoundary_'+[guid]::NewGuid().ToString('N')) -ScriptBlock {
    param($PublicPath,$TransportText,$SlotPlanText,$SlotInstallText)
    . $PublicPath
    . ([scriptblock]::Create($TransportText))
    . ([scriptblock]::Create($SlotPlanText))
    . ([scriptblock]::Create($SlotInstallText))
} -ArgumentList (Join-Path $RepoRoot 'Public/Invoke-SqlServerLabWorkflowAction.ps1'),$transport.Extent.Text,$slotPlan.Extent.Text,$slotInstall.Extent.Text
try{
    $result=& $module {
        param($Cases,$GuestSetupSource)
        $script:passed=0;$script:failed=0
        function Check([bool]$Value,[string]$Label){
            if($Value){$script:passed++;Write-Host ('PASS: '+$Label)}else{$script:failed++;Write-Host ('FAIL: '+$Label)}
        }
        function Write-LabInfo {}
        function Write-LabSuccess {}
        function Test-HyperVAvailable {[pscustomobject]@{Available=$true;Message='synthetic'}}
        Set-Variable -Name IsWindows -Scope Script -Value $true -Force
        & {
            function Get-LabMediaRootDefault { 'synthetic-media' }
            function Get-LabTimestamp { '2026-11-23T00:00:00Z' }
            function Get-LabWindowsPoolPlanKey {
                param($Plan)
                [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes(($Plan | ConvertTo-Json -Depth 20 -Compress)))).ToLowerInvariant()
            }
            $script:slotCalls = 0
            $runId = [guid]::NewGuid().ToString()
            $scopeId = [guid]::NewGuid().ToString()
            $vmId = [guid]::NewGuid().ToString()
            $member = [pscustomobject]@{ state='CONSUMED'; runId=$runId; scopeId=$scopeId; vmId=$vmId; instanceId='primary'; revision=1 }
            $run = [pscustomobject]@{ runId=$runId; scopeId=$scopeId; state='STOPPED'; metadata=[pscustomobject]@{windowsPoolMember=$member} }
            $plan = [pscustomobject]@{ deploymentMode='adhoc-install'; networkMode='host-access'; state='PLANNED'; sqlVersion='2025'; mediaEdition='Enterprise'; features=@('SQLENGINE','FULLTEXT'); sqlMediaPath='synthetic-private-path' }
            $instance = [pscustomobject]@{ id='primary'; vmId=$vmId; sqlDeploymentPlan=$plan }
            $preview = Get-LabHyperVSqlSlotBrowserPlan -Run $run -Instance $instance -StateRoot synthetic-root -MediaRoot synthetic-media -VmState Off
            Check ($preview.State -ceq 'PLANNED' -and $preview.PlanKey -cmatch '^[a-f0-9]{64}$' -and
                ($preview | ConvertTo-Json) -cnotmatch 'synthetic-private-path|synthetic-root|synthetic-media') 'Browser slot preview projects safe fields'
            Check (-not (Get-LabHyperVSqlSlotBrowserPlan -Run $run -Instance $instance -StateRoot synthetic-root -MediaRoot synthetic-media -VmState Running)) 'First setup requires a stopped VM'
            $plan.state = 'PATCH_PENDING'
            $resume = Get-LabHyperVSqlSlotBrowserPlan -Run $run -Instance $instance -StateRoot synthetic-root -MediaRoot synthetic-media -VmState Running
            Check ($resume.State -ceq 'PATCH_PENDING' -and $resume.PlanKey -cne $preview.PlanKey) 'Resume is bound to the saved phase and actual VM state'
            $member.state = 'CLAIMED'
            Check (-not (Get-LabHyperVSqlSlotBrowserPlan -Run $run -Instance $instance -StateRoot synthetic-root -MediaRoot synthetic-media -VmState Off)) 'A protected pool claim has no install action'
            $member.state = 'CONSUMED'
            $syntheticLab = [pscustomobject]@{ Run=$run; Instance=$instance }
            $script:networkChecks = 0
            $script:effectChecks = 0
            function Get-LabWorkflowHash {
                param($Text,$Length)
                [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Text)))
            }
            function Get-HyperVLabWorkflowRun {
                param($RunId,$StateRoot,$ExpectedVmId,[switch]$NoWrite)
                if (-not $NoWrite -or $RunId -cne $run.runId -or $StateRoot -cne 'synthetic-root') { throw 'SYNTHETIC_UNBOUND_READ' }
                $syntheticLab
            }
            function Assert-HyperVLabSqlVmBinding {
                param($Lab,$ExpectedVmId)
                if ($ExpectedVmId -ne [guid]$Lab.Instance.vmId) { throw 'SYNTHETIC_VM_BINDING_FAILED' }
                [pscustomobject]@{VM=[pscustomobject]@{Id=$ExpectedVmId;State='Running'}}
            }
            function Assert-HyperVLabSqlExistingNetwork { $script:networkChecks++ }
            function Assert-LabWindowsPoolMutationAllowed {
                $script:effectChecks++
                throw 'SYNTHETIC_FIRST_EFFECT_BOUNDARY'
            }
            foreach ($case in @(
                @{ Key=$preview.PlanKey; Code='HYPERV_LAB_SQL_INSTALL_PREVIEW_STALE'; Checks=0 },
                @{ Key=$resume.PlanKey; Code='SYNTHETIC_FIRST_EFFECT_BOUNDARY'; Checks=1 })) {
                $observed = $null
                try { $null = Invoke-HyperVLabSqlSlotInstall -RunId $runId -StateRoot synthetic-root -MediaRoot synthetic-media -ExpectedPlanKey $case.Key }
                catch { $observed = $_.Exception.Message }
                Check ($observed -ceq $case.Code -and $script:networkChecks -eq $case.Checks -and $script:effectChecks -eq $case.Checks) ('Install core validates the current plan and network before effects: ' + $case.Code)
            }
            $script:setupFailureMessage = $null
            function Invoke-HyperVLabSqlSlotInstall {
                param($RunId,$MediaRoot,$ExpectedPlanKey,[switch]$RequireExistingNetwork)
                $script:slotCalls++
                if (-not $RequireExistingNetwork -or $MediaRoot -cne 'synthetic-media' -or $ExpectedPlanKey -cne $resume.PlanKey) { throw 'SYNTHETIC_BOUNDARY_FAILED' }
                if ($script:setupFailureMessage) { throw $script:setupFailureMessage }
                [pscustomobject]@{RunId=$RunId;State='SQL_SLOT_READY';GeneratedSqlAccess='SYNTHETIC_SECRET_MUST_NOT_BE_RETURNED'}
            }
            $slot = Invoke-SqlServerLabWorkflowAction -Action InstallHyperVLabSqlSlot -RunId $runId -ExpectedPlanKey $resume.PlanKey
            Check ($script:slotCalls -eq 1 -and $slot.Result.State -ceq 'SQL_SLOT_READY' -and
                ($slot | ConvertTo-Json -Depth 4) -cnotmatch 'GeneratedSqlAccess|SYNTHETIC_SECRET') 'Slot action installs against the bound default and returns only its public receipt'
            $rejected = $false
            try { $null = Invoke-SqlServerLabWorkflowAction -Action InstallHyperVLabSqlSlot -RunId $runId -ExpectedPlanKey $resume.PlanKey -MediaRoot foreign }
            catch { $rejected = $_.Exception.Message -ceq 'HYPERV_LAB_SQL_INSTALL_PREVIEW_REQUIRED' }
            Check ($rejected -and $script:slotCalls -eq 1) 'Slot action rejects a caller-supplied media root before delegation'
            foreach ($case in @(
                @{Message='SQL_SETUP_MEDIA_NOT_UNIQUE: SYNTHETIC_SECRET'; Code='SQL_SETUP_MEDIA_NOT_UNIQUE'},
                @{Message='SQL_SETUP_MEDIA_NOT_UNIQUE: 0'; Code='SQL_SETUP_MEDIA_NOT_UNIQUE'; MediaCount=0},
                @{Message='SQL_SETUP_GUEST_PROCESS_START_FAILED: -2147024894'; Code='SQL_SETUP_GUEST_PROCESS_START_FAILED'; HResult=-2147024894},
                @{Message='SQL_SETUP_GUEST_PROCESS_START_FAILED: -2147024894 SYNTHETIC_SECRET'; Code='SQL_SETUP_GUEST_PROCESS_START_FAILED'},
                @{Message='SQL_SETUP_MEDIA_NOT_UNIQUE_PRIVATE: SYNTHETIC_SECRET'; Code='UNCLASSIFIED'},
                @{Message='Raw setup message: SYNTHETIC_SECRET'; Code='UNCLASSIFIED'})) {
                $script:setupFailureMessage = $case.Message
                $failure = try { $null = Invoke-SqlServerLabWorkflowAction -Action InstallHyperVLabSqlSlot -RunId $runId -ExpectedPlanKey $resume.PlanKey; $null }
                    catch { $_.Exception }
                Check ($failure.Message -ceq 'HYPERV_LAB_SQL_INSTALL_FAILED' -and $null -eq $failure.InnerException -and
                    $failure.Data['LabSqlSlotCauseCode'] -ceq $case.Code -and
                    $failure.Data['LabSqlSlotMediaCount'] -eq $case.MediaCount -and $failure.Data['LabSqlSlotProcessHResult'] -eq $case.HResult -and
                    -not (($failure.Data | ConvertTo-Json -Depth 4) -match 'SYNTHETIC_SECRET')) ('Slot setup retains bounded phase code: '+$case.Code)
            }
        }
        & {
            $script:guestSetupProcessStarts = 0
            function Get-CimInstance {
                param($ClassName,$Filter)
                if ($ClassName -eq 'Win32_LogicalDisk') {
                    if ($fault -eq 'MediaRead') { throw 'SYNTHETIC_PRIVATE_DETAIL' }
                    if ($fault -ne 'MissingMedia') { [pscustomobject]@{DeviceID='C:'} }
                }
                elseif ($fault -eq 'ProcessRead') { throw 'SYNTHETIC_PRIVATE_DETAIL' }
            }
            function Join-Path { 'synthetic-setup-exe' }
            function Test-Path { $true }
            function Get-Item { [pscustomobject]@{FullName='synthetic-setup-exe';VersionInfo=[pscustomobject]@{FileVersion='17.0.1000.7'}} }
            function Start-Process {
                $script:guestSetupProcessStarts++
                throw [ComponentModel.Win32Exception]::new(2, 'SYNTHETIC_PRIVATE_DETAIL')
            }
            $guestBlock = [scriptblock]::Create($GuestSetupSource)
            $guestSa = [Security.SecureString]::new()
            $guestSa.AppendChar('x')
            try {
                foreach ($case in @(
                    @{Fault='MediaRead'; Code='SQL_SETUP_GUEST_MEDIA_DISCOVERY_FAILED'; Category=$true; Starts=0},
                    @{Fault='MissingMedia'; Code='SQL_SETUP_MEDIA_NOT_UNIQUE: 0'; Starts=0},
                    @{Fault='UnboundPassword'; Code='SQL_SETUP_GUEST_PASSWORD_BINDING_FAILED'; Category=$true; Starts=0},
                    @{Fault='ProcessRead'; Code='SQL_SETUP_GUEST_PROCESS_INVENTORY_FAILED'; Category=$true; Starts=0},
                    @{Fault='ProcessStart'; Code='SQL_SETUP_GUEST_PROCESS_START_FAILED: '+[ComponentModel.Win32Exception]::new(2).HResult; Starts=1})) {
                    $fault = $case.Fault
                    $password = if ($fault -ne 'UnboundPassword') { $guestSa }
                    $failureCode = try { $null = & $guestBlock '2025' '^17\.' 'SQLENGINE' $password; $null }
                        catch { $_.Exception.Message }
                    $expectedFailure = if ($case.Category) {
                        $failureCode -cmatch ('^'+$case.Code+': (?<category>[A-Za-z]+)$') -and
                            $Matches.category -cin [Enum]::GetNames([System.Management.Automation.ErrorCategory])
                    } else { $failureCode -ceq $case.Code }
                    Check ($expectedFailure -and $script:guestSetupProcessStarts -eq $case.Starts) ('Setup guest failure preserves only bounded evidence: '+$fault)
                }
            }
            finally { $guestSa.Dispose() }
        }
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
    } $cases $guestSetup[0].Extent.Text.Substring(1, $guestSetup[0].Extent.Text.Length - 2)
    Write-Host ('SQL completion boundary: '+$result.Passed+' PASS, '+$result.Failed+' FAIL; native setup/SQL NOT_EXECUTED')
    return $result
}finally{Remove-Module $module -Force -ErrorAction SilentlyContinue}
