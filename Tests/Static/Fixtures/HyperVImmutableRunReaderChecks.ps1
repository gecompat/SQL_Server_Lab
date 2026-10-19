#Requires -Version 7.2
[CmdletBinding()]
param([string]$RepoRoot=(Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path)
$ErrorActionPreference='Stop'
$tokens=$null;$errors=$null
$path=Join-Path $RepoRoot 'Private/HyperVLabEnvironment.ps1'
$ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'IMMUTABLE_READER_SOURCE_PARSE_FAILED'}
$functions=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Get-HyperVLabWorkflowRun'},$false))
if($functions.Count -ne 1){throw 'IMMUTABLE_READER_FUNCTION_NOT_UNIQUE'}
$module=New-Module -Name ('ImmutableRunReader_'+[guid]::NewGuid().ToString('N')) -ScriptBlock {
    param($Definition)
    . ([scriptblock]::Create($Definition))
} -ArgumentList $functions[0].Extent.Text
try{
    $result=& $module {
        $script:passed=0;$script:failed=0
        $expected=[guid]'81e2bc82-dcf4-4b12-a931-673730142aac'
        $other=[guid]'24583954-1178-4e99-9b81-e50ccb1b896d'
        $fixtureRunId='51029e3d-9b6f-4848-8565-de62325fdf67'
        $fixtureScopeId='b9f2b8f7-5099-4631-931c-afcbb29c348b'
        $root=Join-Path ([IO.Path]::GetTempPath()) 'synthetic-immutable-state'
        function Check([bool]$Value,[string]$Label){
            if($Value){$script:passed++;Write-Host ('PASS: '+$Label)}else{$script:failed++;Write-Host ('FAIL: '+$Label)}
        }
        function Reset-ReaderCase {
            $script:reads=0;$script:writes=0;$script:poolChecks=0;$script:defaultRoots=0;$script:vmReads=0
            $script:storedId=$expected.ToString();$script:storedName='synthetic-old-name'
            $script:duplicateInstance=$false
            $script:storedRun=[pscustomobject]@{runId=$fixtureRunId;scopeId=$fixtureScopeId;metadata=[pscustomobject]@{workflowKind='hyperv-lab'}}
            $script:native=@([pscustomobject]@{VMId=$expected.ToString();VMName='synthetic-renamed-vm'})
            $script:vmArguments=$null
        }
        function Get-LabStateRoot {$script:defaultRoots++;return $root}
        function Get-LabRunState {
            param($RunId,$StateRoot)
            $script:reads++
            $script:storedRun
        }
        function Test-Path {param($LiteralPath,$PathType) $true}
        function Get-Content {
            param($LiteralPath,[switch]$Raw,$Encoding)
            $instances=@(@{provider='hyperv';vmName=$script:storedName;vmId=$script:storedId;id='primary'})
            if($script:duplicateInstance){$instances+=@(@{provider='hyperv';vmName='synthetic-second';vmId=$other.ToString();id='secondary'})}
            @{instances=$instances}|ConvertTo-Json -Depth 5 -Compress
        }
        function Get-HyperVLabVMs {
            param($RunId,$ScopeId)
            $script:vmReads++;$script:vmArguments=@($RunId,$ScopeId)
            if((-not $RunId -or $RunId -ieq $fixtureRunId) -and (-not $ScopeId -or $ScopeId -ieq $fixtureScopeId)){$script:native}
        }
        function Assert-LabWindowsPoolMutationAllowed {$script:poolChecks++}
        function Write-LabArtifactJsonAtomic {$script:writes++}
        function Reject-Reader([hashtable]$Arguments,[string]$Code){
            $rejected=$false
            try{$null=Get-HyperVLabWorkflowRun @Arguments}catch{$rejected=$_.Exception.Message -ceq $Code}
            Check ($rejected -and $script:writes -eq 0 -and $script:poolChecks -eq 0) $Code
            if($Code -ceq 'HYPERV_LAB_EXPECTED_VM_RUN_BINDING_INVALID'){Check ($script:vmReads -eq 0) 'Invalid Run/Scope never opens native discovery'}
        }
        Reset-ReaderCase
        $value=$null
        try{$value=Get-HyperVLabWorkflowRun -RunId $fixtureRunId -StateRoot $root -ExpectedVmId $expected}catch{}
        Check ($value -and $value.Instance.vmName -ceq 'synthetic-renamed-vm' -and $value.Instance.vmId -ceq $expected.ToString() -and $script:writes -eq 0 -and $script:poolChecks -eq 0) 'Strict same-ID rename is projected in memory without write or invalidation'
        Check ($script:vmReads -eq 1 -and ($script:vmArguments -join '/') -ceq ($fixtureRunId+'/'+$fixtureScopeId)) 'Strict native discovery binds actual run and scope'
        Reset-ReaderCase
        Reject-Reader @{RunId=$fixtureRunId;StateRoot=$root;ExpectedVmId=[guid]::Empty} 'HYPERV_LAB_EXPECTED_VM_ID_REQUIRED'
        Check ($script:reads -eq 0 -and $script:defaultRoots -eq 0) 'Empty strict ID rejects before state discovery'
        Reset-ReaderCase
        Reject-Reader @{RunId=$fixtureRunId;ExpectedVmId=$expected} 'HYPERV_LAB_EXPECTED_VM_STATE_ROOT_REQUIRED'
        Check ($script:reads -eq 0 -and $script:defaultRoots -eq 0) 'Strict reader never resolves an omitted default root'
        Reset-ReaderCase
        Reject-Reader @{RunId=$fixtureRunId;StateRoot=' ';ExpectedVmId=$expected} 'HYPERV_LAB_EXPECTED_VM_STATE_ROOT_REQUIRED'
        Reset-ReaderCase
        $script:storedId=$other.ToString()
        Reject-Reader @{RunId=$fixtureRunId;StateRoot=$root;ExpectedVmId=$expected} 'HYPERV_LAB_EXPECTED_VM_ID_MISMATCH'
        Check ($script:vmReads -eq 0) 'Stored-ID mismatch rejects before native discovery'
        Reset-ReaderCase
        $script:storedId='not-a-guid'
        Reject-Reader @{RunId=$fixtureRunId;StateRoot=$root;ExpectedVmId=$expected} 'HYPERV_LAB_EXPECTED_VM_ID_MISMATCH'
        Reset-ReaderCase
        $script:storedId=$null
        Reject-Reader @{RunId=$fixtureRunId;StateRoot=$root;ExpectedVmId=$expected} 'HYPERV_LAB_EXPECTED_VM_ID_MISMATCH'
        Reset-ReaderCase
        $script:duplicateInstance=$true
        Reject-Reader @{RunId=$fixtureRunId;StateRoot=$root;ExpectedVmId=$expected} 'HYPERV_LAB_EXPECTED_VM_ID_MISMATCH'
        Reset-ReaderCase
        $script:native=@([pscustomobject]@{VMId=$other.ToString();VMName='synthetic-renamed-vm'})
        Reject-Reader @{RunId=$fixtureRunId;StateRoot=$root;ExpectedVmId=$expected} 'HYPERV_LAB_EXPECTED_VM_RUNTIME_MISMATCH'
        Reset-ReaderCase
        $script:native=@()
        Reject-Reader @{RunId=$fixtureRunId;StateRoot=$root;ExpectedVmId=$expected} 'HYPERV_LAB_EXPECTED_VM_RUNTIME_MISMATCH'
        Reset-ReaderCase
        $script:native+=@([pscustomobject]@{VMId=$other.ToString();VMName='synthetic-second-vm'})
        Reject-Reader @{RunId=$fixtureRunId;StateRoot=$root;ExpectedVmId=$expected} 'HYPERV_LAB_EXPECTED_VM_RUNTIME_MISMATCH'
        Reset-ReaderCase
        $script:native=@([pscustomobject]@{VMId=$expected.ToString();VMName=' '})
        Reject-Reader @{RunId=$fixtureRunId;StateRoot=$root;ExpectedVmId=$expected} 'HYPERV_LAB_EXPECTED_VM_RUNTIME_MISMATCH'
        Reset-ReaderCase
        $script:storedId=$expected.ToString().ToUpperInvariant()
        $value=$null
        try{$value=Get-HyperVLabWorkflowRun -RunId $fixtureRunId -StateRoot $root -ExpectedVmId $expected}catch{}
        Check ($value -and $script:writes -eq 0 -and $script:poolChecks -eq 0) 'GUID identity is case-independent without rewriting the stored ID'
        Reset-ReaderCase
        $script:native=@([pscustomobject]@{VMId=$expected.ToString();VMName=$script:storedName})
        $value=$null
        try{$value=Get-HyperVLabWorkflowRun -RunId $fixtureRunId -StateRoot $root -ExpectedVmId $expected}catch{}
        Check ($value -and $value.Instance.vmName -ceq $script:storedName -and $script:writes -eq 0 -and $script:poolChecks -eq 0) 'Strict unchanged-name reader remains read-only'
        Reset-ReaderCase
        $value=Get-HyperVLabWorkflowRun -RunId $fixtureRunId -StateRoot $root
        Check ($value.Instance.vmName -ceq 'synthetic-renamed-vm' -and $script:writes -eq 1 -and $script:poolChecks -eq 1) 'Omitted strict ID preserves legacy rename reconciliation'
        Reset-ReaderCase
        $value=Get-HyperVLabWorkflowRun -RunId $fixtureRunId
        Check ($value.StateRoot -ceq $root -and $script:defaultRoots -eq 1 -and $script:writes -eq 1) 'Omitted strict ID preserves default-root selection'
        foreach($invalidRun in @($null,' ','malformed-run',$other.ToString(),[guid]::Empty.ToString())){
            Reset-ReaderCase
            $script:storedRun.runId=$invalidRun
            Reject-Reader @{RunId=$fixtureRunId;StateRoot=$root;ExpectedVmId=$expected} 'HYPERV_LAB_EXPECTED_VM_RUN_BINDING_INVALID'
        }
        foreach($invalidScope in @($null,' ','malformed-scope',[guid]::Empty.ToString())){
            Reset-ReaderCase
            $script:storedRun.scopeId=$invalidScope
            Reject-Reader @{RunId=$fixtureRunId;StateRoot=$root;ExpectedVmId=$expected} 'HYPERV_LAB_EXPECTED_VM_RUN_BINDING_INVALID'
        }
        Reset-ReaderCase
        $script:storedRun.PSObject.Properties.Remove('scopeId')
        Reject-Reader @{RunId=$fixtureRunId;StateRoot=$root;ExpectedVmId=$expected} 'HYPERV_LAB_EXPECTED_VM_RUN_BINDING_INVALID'
        Reset-ReaderCase
        $script:storedRun.scopeId=$other.ToString()
        Reject-Reader @{RunId=$fixtureRunId;StateRoot=$root;ExpectedVmId=$expected} 'HYPERV_LAB_EXPECTED_VM_RUNTIME_MISMATCH'
        Reset-ReaderCase
        Reject-Reader @{RunId='malformed-selected-run';StateRoot=$root;ExpectedVmId=$expected} 'HYPERV_LAB_EXPECTED_VM_RUN_BINDING_INVALID'
        Check ($script:reads -eq 0) 'Malformed selected RunId rejects before state discovery'
        [pscustomobject]@{Success=($script:failed -eq 0);Passed=$script:passed;Failed=$script:failed;NativeActions=0}
    }
    Write-Host ('Immutable run reader: '+$result.Passed+' PASS, '+$result.Failed+' FAIL; native NOT_EXECUTED')
    return $result
}finally{Remove-Module $module -Force -ErrorAction SilentlyContinue}
