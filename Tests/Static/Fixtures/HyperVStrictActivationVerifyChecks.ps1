#Requires -Version 7.2
[CmdletBinding()]
param([string]$RepoRoot=(Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path)
$ErrorActionPreference='Stop'
$definitions=@()
foreach($source in @(
    @{Path='Private/WindowsActivationIntent.ps1';Names=@('Resolve-LabWindowsActivationIntent','Get-LabWindowsActivationDecision','Invoke-LabWindowsSlotActivationReconcile')},
    @{Path='Private/HyperVLabEnvironment.ps1';Names=@('Get-HyperVWindowsSlotLicenseStatus','Set-HyperVWindowsSlotActivationEvidence')},
    @{Path='Providers/HyperV/HyperVProvider.ps1';Names=@('Wait-HyperVPowerShellDirect')}
)){
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot $source.Path),[ref]$tokens,[ref]$errors)
    if($errors.Count){throw 'STRICT_ACTIVATION_SOURCE_PARSE_FAILED'}
    foreach($name in $source.Names){
        $found=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$false))
        if($found.Count -ne 1){throw 'STRICT_ACTIVATION_FUNCTION_NOT_UNIQUE'}
        $definitions+=$found[0].Extent.Text
    }
}
$module=New-Module -Name ('StrictActivation_'+[guid]::NewGuid().ToString('N')) -ScriptBlock {
    param($Definitions)
    foreach($definition in $Definitions){. ([scriptblock]::Create($definition))}
} -ArgumentList (,$definitions)
try{
    & $module {
        $script:passed=0;$script:failed=0
        $script:fixtureVm=[guid]'c1eefcb5-08b4-460f-82a6-8b955a6b0218'
        $script:otherVm=[guid]'9c16cf30-850e-42eb-a660-44eb18187681'
        $script:fixtureRun='5db1ad6b-7162-44be-a0b9-099b7aa87cde'
        $script:fixtureScope='4342a219-7041-47a8-93f1-d7c87c86d13a'
        $script:fixtureRoot=Join-Path ([IO.Path]::GetTempPath()) 'synthetic-strict-activation'
        $script:credential=[pscredential]::new('synthetic-user',[securestring]::new())
        function Check([bool]$Value,[string]$Label){if($Value){$script:passed++;Write-Host "PASS: $Label"}else{$script:failed++;Write-Host "FAIL: $Label"}}
        function Reset-Case {
            $script:events=[Collections.Generic.List[string]]::new()
            $script:readerCalls=0;$script:managedCalls=0;$script:remoteCalls=0;$script:writes=0;$script:pool=0;$script:legacy=0
            $script:nativeId=$script:fixtureVm;$script:replaceAtManaged=0;$script:replaceAtReader=0
            $script:strictExpected=$true;$script:transportIds=[Collections.Generic.List[string]]::new()
            $script:storedIntent=[pscustomobject]@{ContractVersion='SqlServerLab.WindowsActivationIntent/1.0';Strategy='VerifyOnly';EgressPolicy='Denied'}
            $script:journal=$null;$script:badJson=$false;$script:journalKind='file';$script:journalJson=$null;$script:journalLength=256
            $script:receipt=[pscustomobject]@{edition='ServerStandardEval';productName='Evaluation';licenseStatus=1;evaluationMinutesRemaining=100;evaluationExpiresAt='2099-01-01T00:00:00Z';evaluationEndDate=$null;observedAt='2026-10-18T00:00:00Z'}
        }
        function Get-HyperVLabWorkflowRun {
            param($RunId,$StateRoot,[guid]$ExpectedVmId)
            $script:readerCalls++;$script:events.Add('read')
            if($PSBoundParameters.ContainsKey('ExpectedVmId')){
                if($ExpectedVmId -eq [guid]::Empty){throw 'HYPERV_LAB_EXPECTED_VM_ID_REQUIRED'}
                if([string]::IsNullOrWhiteSpace($StateRoot)){throw 'HYPERV_LAB_EXPECTED_VM_STATE_ROOT_REQUIRED'}
                if($script:replaceAtReader -eq $script:readerCalls){throw 'HYPERV_LAB_EXPECTED_VM_RUNTIME_MISMATCH'}
            }elseif($script:strictExpected){throw 'FIXTURE_STRICT_READER_BINDING_LOST'}
            [pscustomobject]@{Run=[pscustomobject]@{runId=$script:fixtureRun;scopeId=$script:fixtureScope;metadata=[pscustomobject]@{networkIntent='isolated'}};Instance=[pscustomobject]@{vmId=$script:fixtureVm.ToString();vmName='renamed-synthetic-vm';windowsActivationIntent=$script:storedIntent};RunDirectory=$script:fixtureRoot;StateRoot=$StateRoot;Connection=[pscustomobject]@{}}
        }
        function Get-HyperVManagedVM {
            param($VMName,$ExpectedRunId,$ExpectedScopeId)
            $script:managedCalls++;$script:events.Add('managed')
            $id=if($script:replaceAtManaged -eq $script:managedCalls){$script:otherVm}else{$script:nativeId}
            [pscustomobject]@{VM=[pscustomobject]@{Id=$id;State='Running'}}
        }
        function Invoke-HyperVPowerShellDirect {
            param($VMName,$ExpectedRunId,$ExpectedScopeId,$Credential,$FallbackAddress,$ScriptBlock,$TimeoutSeconds,$Progress,[guid]$ExpectedVmId,$Build,$BuildStateRoot)
            $script:remoteCalls++;$script:events.Add('transport')
            if($script:strictExpected -and (-not $PSBoundParameters.ContainsKey('ExpectedVmId') -or $ExpectedVmId -ne $script:fixtureVm -or $FallbackAddress)){throw 'FIXTURE_STRICT_TRANSPORT_BINDING_LOST'}
            $script:transportIds.Add($(if($PSBoundParameters.ContainsKey('ExpectedVmId')){$ExpectedVmId.ToString()}else{'omitted'}))
            # Never execute the guest body. Only synthetic native leaves return receipts.
            if($ScriptBlock.ToString() -match 'SoftwareLicensingProduct'){$script:receipt}else{[pscustomobject]@{computerName='synthetic';imageState='IMAGE_STATE_COMPLETE'}}
        }
        function Assert-LabWindowsPoolMutationAllowed {$script:pool++;$script:events.Add('pool')}
        function Write-LabArtifactJsonAtomic {$script:writes++;$script:events.Add('write')}
        function Get-LabTimestamp {'2026-10-18T00:00:00Z'}
        function Get-LabSecret {throw 'FIXTURE_SECRET_LOOKUP_UNEXPECTED'}
        function Invoke-HyperVWindowsSlotActivation {param($RunId,$Credential,$StateRoot,$WindowsActivation,[switch]$ExplicitWindowsActivation,$ExternalSwitchName)$script:legacy++;[pscustomobject]@{State='LEGACY_DEFAULT'}}
        function Test-Path {
            param($LiteralPath,$PathType)
            if($script:journalKind -eq 'denied'){Write-Error -Message 'Synthetic denied journal lookup' -ErrorAction Continue;return $false}
            if($script:journalKind -eq 'directory' -and $PathType -eq 'Leaf'){return $false}
            $null -ne $script:journal -or $script:badJson -or $null -ne $script:journalJson
        }
        function Get-Item {
            [CmdletBinding()]param($LiteralPath,[switch]$Force)
            if($script:journalKind -eq 'denied'){throw [UnauthorizedAccessException]::new('synthetic-denied')}
            if($script:journalKind -eq 'directory'){return [IO.DirectoryInfo]::new($script:fixtureRoot)}
            if($null -eq $script:journal -and -not $script:badJson -and $null -eq $script:journalJson){throw [Management.Automation.ItemNotFoundException]::new('synthetic-absent')}
            $item=[IO.FileInfo]::new((Join-Path $script:fixtureRoot 'windows-activation-network.json'))
            $attributes=if($script:journalKind -eq 'reparse'){[IO.FileAttributes]::ReparsePoint}else{[IO.FileAttributes]::Normal}
            $item|Add-Member -NotePropertyName Attributes -NotePropertyValue $attributes -Force
            $item|Add-Member -NotePropertyName Length -NotePropertyValue $script:journalLength -Force
            return $item
        }
        function Get-Content {
            [CmdletBinding()]param($LiteralPath,[switch]$Raw)
            if($script:journalKind -eq 'unreadable'){throw [IO.IOException]::new('synthetic-read-denied')}
            if($script:journalJson){return $script:journalJson}
            if($script:badJson){'{'}else{$script:journal|ConvertTo-Json -Compress}
        }
        function Start-LabActionProgress {[pscustomobject]@{}}
        function Update-LabActionProgress {}
        function Stop-LabActionProgress {}
        function Wait-LabProgressDelay {throw 'FIXTURE_UNEXPECTED_RETRY'}
        function Assert-HyperVBuildGuestTransportAuthority {}
        function Strict-Reconcile {Invoke-LabWindowsSlotActivationReconcile -RunId $script:fixtureRun -StateRoot $script:fixtureRoot -Credential $script:credential -ExpectedVmId $script:fixtureVm @args}
        function Reject-Reconcile([string]$Code,[hashtable]$Extra=@{}){
            $blocked=$false;try{$null=Strict-Reconcile @Extra}catch{$blocked=$_.Exception.Message -ceq $Code}
            Check ($blocked -and $script:remoteCalls -eq 0 -and $script:pool -eq 0 -and $script:writes -eq 0 -and $script:legacy -eq 0) $Code
        }
        Reset-Case
        $value=$null;try{$value=Strict-Reconcile}catch{}
        Check ($value -and $value.State -ceq 'EVALUATION_ACTIVE' -and $script:legacy -eq 0 -and $script:writes -eq 1) 'Strict active evaluation only reads guest and persists bound evidence'
        Check ($script:remoteCalls -eq 2 -and @($script:transportIds|Where-Object {$_ -ne $script:fixtureVm.ToString()}).Count -eq 0) 'Both readiness and license probe carry exact VMId without fallback'
        Check (($script:events -join ',') -match 'read,pool,read,write$') 'Strict evidence rebinds before pool invalidation and again before write'
        foreach($intent in @(@{Strategy='EvaluationOnline';EgressPolicy='Denied'},@{Strategy='VerifyOnly';EgressPolicy='ExistingOnly'},@{Strategy='NotRequested';EgressPolicy='Denied'})){
            Reset-Case;$script:storedIntent.Strategy=$intent.Strategy;$script:storedIntent.EgressPolicy=$intent.EgressPolicy
            Reject-Reconcile 'HYPERV_STRICT_ACTIVATION_VERIFY_ONLY_REQUIRED'
        }
        Reset-Case
        Reject-Reconcile 'HYPERV_STRICT_ACTIVATION_VERIFY_ONLY_REQUIRED' @{WindowsActivation=[pscustomobject]@{ContractVersion='SqlServerLab.WindowsActivationIntent/1.0';Strategy='EvaluationOnline';EgressPolicy='Denied'}}
        Reset-Case
        Reject-Reconcile 'HYPERV_STRICT_ACTIVATION_EXTERNAL_SWITCH_FORBIDDEN' @{ExternalSwitchName='synthetic-external'}
        foreach($status in @('CREATED','RECOVERY_REQUIRED','unknown')){
            Reset-Case;$script:journal=[pscustomobject]@{ContractVersion='SqlServerLab.WindowsActivationNetwork/1.0';RunId=$script:fixtureRun;ScopeId=$script:fixtureScope;VMId=$script:fixtureVm;Status=$status}
            Reject-Reconcile 'HYPERV_STRICT_ACTIVATION_NETWORK_RECOVERY_REQUIRED'
        }
        foreach($field in @('RunId','ScopeId','VMId','ContractVersion')){
            Reset-Case;$script:journal=[pscustomobject]@{ContractVersion='SqlServerLab.WindowsActivationNetwork/1.0';RunId=$script:fixtureRun;ScopeId=$script:fixtureScope;VMId=$script:fixtureVm.ToString();Status='CLEANED'}
            $script:journal.$field='foreign'
            Reject-Reconcile 'HYPERV_STRICT_ACTIVATION_NETWORK_RECOVERY_REQUIRED'
        }
        Reset-Case;$script:badJson=$true
        Reject-Reconcile 'HYPERV_STRICT_ACTIVATION_NETWORK_RECOVERY_REQUIRED'
        foreach($kind in @('directory','denied','reparse','unreadable')){
            Reset-Case;$script:journalKind=$kind;$script:journal=[pscustomobject]@{ContractVersion='SqlServerLab.WindowsActivationNetwork/1.0';RunId=$script:fixtureRun;ScopeId=$script:fixtureScope;VMId=$script:fixtureVm.ToString();Status='CLEANED'}
            Reject-Reconcile 'HYPERV_STRICT_ACTIVATION_NETWORK_RECOVERY_REQUIRED'
        }
        Reset-Case;$script:journal=[pscustomobject]@{ContractVersion='SqlServerLab.WindowsActivationNetwork/1.0';RunId=$script:fixtureRun;ScopeId=$script:fixtureScope;VMId=$script:fixtureVm.ToString();Status='CLEANED'}
        $script:journalJson='['+($script:journal|ConvertTo-Json -Compress)+']'
        Reject-Reconcile 'HYPERV_STRICT_ACTIVATION_NETWORK_RECOVERY_REQUIRED'
        Reset-Case;$script:journalLength=1048577;$script:journal=[pscustomobject]@{ContractVersion='SqlServerLab.WindowsActivationNetwork/1.0';RunId=$script:fixtureRun;ScopeId=$script:fixtureScope;VMId=$script:fixtureVm.ToString();Status='CLEANED'}
        Reject-Reconcile 'HYPERV_STRICT_ACTIVATION_NETWORK_RECOVERY_REQUIRED'
        Reset-Case;$script:journal=@([pscustomobject]@{ContractVersion='SqlServerLab.WindowsActivationNetwork/1.0';RunId=$script:fixtureRun;ScopeId=$script:fixtureScope;VMId=$script:fixtureVm.ToString();Status='CLEANED'},[pscustomobject]@{Status='CLEANED'})
        Reject-Reconcile 'HYPERV_STRICT_ACTIVATION_NETWORK_RECOVERY_REQUIRED'
        Reset-Case;$script:journal=[pscustomobject]@{ContractVersion='SqlServerLab.WindowsActivationNetwork/1.0';RunId=$script:fixtureRun;ScopeId=$script:fixtureScope;VMId=$script:fixtureVm.ToString();Status=@('CLEANED','CLEANED')}
        Reject-Reconcile 'HYPERV_STRICT_ACTIVATION_NETWORK_RECOVERY_REQUIRED'
        Reset-Case;$script:journal=[pscustomobject]@{ContractVersion='SqlServerLab.WindowsActivationNetwork/1.0';RunId=$script:fixtureRun;ScopeId=$script:fixtureScope;VMId=$script:fixtureVm.ToString();Status='CLEANED'}
        $value=$null;try{$value=Strict-Reconcile}catch{}
        Check ($value -and $value.State -ceq 'EVALUATION_ACTIVE' -and $script:journal.Status -ceq 'CLEANED' -and $script:legacy -eq 0 -and $script:writes -eq 1) 'Bound CLEANED journal is retained without network cleanup/replay'
        Reset-Case;$script:nativeId=$script:otherVm
        Reject-Reconcile 'HYPERV_GUEST_VM_ID_MISMATCH'
        Reset-Case;$script:replaceAtManaged=2
        Reject-Reconcile 'HYPERV_GUEST_VM_ID_MISMATCH'
        Reset-Case;$script:replaceAtReader=3
        $blocked=$false;try{$null=Strict-Reconcile}catch{$blocked=$_.Exception.Message -ceq 'HYPERV_LAB_EXPECTED_VM_RUNTIME_MISMATCH'}
        Check ($blocked -and $script:writes -eq 0 -and $script:pool -eq 0) 'Persist rebind failure does not invalidate evidence or write'
        Reset-Case;$script:replaceAtReader=4
        $blocked=$false;try{$null=Strict-Reconcile}catch{$blocked=$_.Exception.Message -ceq 'HYPERV_LAB_EXPECTED_VM_RUNTIME_MISMATCH'}
        Check ($blocked -and $script:writes -eq 0 -and $script:pool -eq 1) 'Drift after pool guard prevents connection write'
        Reset-Case;$script:receipt.licenseStatus=0;$script:receipt.evaluationMinutesRemaining=0
        $blocked=$false;try{$null=Strict-Reconcile}catch{$blocked=$_.Exception.Message -ceq 'WINDOWS_ACTIVATION_VERIFY_ONLY'}
        Check ($blocked -and $script:legacy -eq 0 -and $script:writes -eq 1) 'Inactive evaluation is recorded then blocked, never activated'
        Reset-Case;$script:strictExpected=$false
        $value=Invoke-LabWindowsSlotActivationReconcile -RunId $script:fixtureRun -Credential $script:credential -StateRoot $script:fixtureRoot
        Check ($value.State -ceq 'LEGACY_DEFAULT' -and $script:legacy -eq 1 -and $script:remoteCalls -eq 0) 'Omitted option retains original activation dispatch'
        Reset-Case;$script:strictExpected=$false
        $value=Get-HyperVWindowsSlotLicenseStatus -RunId $script:fixtureRun -Credential $script:credential -StateRoot $script:fixtureRoot -Persist
        Check ($value.State -ceq 'EVALUATION_ACTIVE' -and $script:writes -eq 1 -and ($script:transportIds -join ',') -ceq 'omitted,omitted') 'Omitted status option keeps default transport and evidence persistence'
        Reset-Case
        $value=Wait-HyperVPowerShellDirect -VMName synthetic -ExpectedRunId $script:fixtureRun -ExpectedScopeId $script:fixtureScope -Credential $script:credential -Build ([pscustomobject]@{builder=[pscustomobject]@{vmId=$script:fixtureVm.ToString()}}) -BuildStateRoot $script:fixtureRoot
        Check ($value.Ready -and ($script:transportIds -join ',') -ceq $script:fixtureVm.ToString()) 'Existing Build-derived VM binding remains intact without new option'
        foreach($extra in @(@{ExpectedVmId=[guid]::Empty},@{ExpectedVmId=$script:fixtureVm;FallbackAddress='192.0.2.1'},@{ExpectedVmId=$script:fixtureVm;GuestInitializationScript='throw 1'},@{ExpectedVmId=$script:fixtureVm;ExpectedRunId=' '},@{ExpectedVmId=$script:fixtureVm;ExpectedScopeId='foreign'})){
            Reset-Case;$argsMap=@{VMName='synthetic';ExpectedRunId=$script:fixtureRun;ExpectedScopeId=$script:fixtureScope;Credential=$script:credential}
            foreach($key in $extra.Keys){$argsMap[$key]=$extra[$key]}
            $blocked=$false;try{$null=Wait-HyperVPowerShellDirect @argsMap}catch{$blocked=$_.Exception.Message -ceq 'HYPERV_STRICT_GUEST_WAIT_BINDING_INVALID'}
            Check ($blocked -and $script:managedCalls -eq 0 -and $script:remoteCalls -eq 0) 'Strict wait rejects invalid selection/fallback/initialization before native discovery'
        }
        foreach($extra in @(@{ExpectedVmId=[guid]::Empty;StateRoot=$script:fixtureRoot},@{ExpectedVmId=$script:fixtureVm;StateRoot=' '})){
            Reset-Case;$blocked=$false
            try{$null=Get-HyperVWindowsSlotLicenseStatus -RunId $script:fixtureRun -Credential $script:credential @extra}catch{$blocked=$true}
            Check ($blocked -and $script:remoteCalls -eq 0 -and $script:managedCalls -eq 0 -and $script:pool -eq 0) 'Strict status cannot lose explicit ID/root before guest call'
        }
        Write-Host "STRICT ACTIVATION VERIFY: $script:passed PASS / $script:failed FAIL"
        if($script:failed){throw 'STRICT_ACTIVATION_VERIFY_FAILED'}
    }
}finally{Remove-Module $module -Force}
