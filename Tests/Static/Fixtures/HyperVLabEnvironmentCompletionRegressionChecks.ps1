#Requires -Version 7.2
[CmdletBinding()]
param([string]$RepoRoot=(Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path)
$ErrorActionPreference='Stop'
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-completion-regression-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $fixture
$definitions=@()
foreach($source in @(
    @{Path='Private/HyperVLabEnvironment.ps1';Names=@('Get-HyperVLabWorkflowRun','Assert-HyperVLabSqlVmBinding','Assert-HyperVLabSqlExistingNetwork','Get-HyperVLabHostSqlNetworkLeaseAddress','Enable-HyperVLabHostSqlAccess')},
    @{Path='Private/HyperVSqlCollation.ps1';Names=@('Test-LabHyperVSqlCollationRuntimeEvidence')},
    @{Path='Private/LabNetwork.ps1';Names=@('ConvertTo-LabIpv4UInt32','ConvertFrom-LabIpv4UInt32','ConvertTo-LabIpv4Subnet','Get-LabHyperVIpamPath','Invoke-LabHyperVIpamLock','Initialize-HyperVGuestLabNetwork')}
)) {
    $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot $source.Path),[ref]$null,[ref]$errors)
    if($errors){throw 'COMPLETION_REGRESSION_SOURCE_PARSE_FAILED'}
    foreach($name in $source.Names){
        $function=$ast.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name},$false)
        if(-not $function){throw 'COMPLETION_REGRESSION_SOURCE_MISSING'}
        $definitions+=$function.Extent.Text
    }
}
$transportAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot 'Providers/HyperV/HyperVProvider.ps1'),[ref]$null,[ref]$null)
$transport=$transportAst.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Invoke-HyperVPowerShellDirect'},$false)
$module=New-Module -ScriptBlock {
    param($Definitions,$ParamBlock)
    foreach($definition in $Definitions){. ([scriptblock]::Create($definition))}
    # Only the original parameter binder runs. No productive transport or guest body runs.
    $spy={
        $script:calls.Add([pscustomobject]@{VmIdBound=$PSBoundParameters.ContainsKey('ExpectedVmId');VmId=$ExpectedVmId;NoRetry=[bool]$NoRetry;Fallback=$FallbackAddress})
        if($VMName -cne 'synthetic-vm' -or $ExpectedRunId -cne $script:runId -or $ExpectedScopeId -cne $script:scopeId -or
            -not [object]::ReferenceEquals($Credential,$script:credential) -or -not $NoRetry){throw 'FIXTURE_TRANSPORT_BINDING_CHANGED'}
        if($PSBoundParameters.ContainsKey('ExpectedVmId') -and ($ExpectedVmId -ne $script:vmId -or $FallbackAddress)){throw 'FIXTURE_DIRECT_BINDING_CHANGED'}
        if($script:lostReply){throw 'SYNTHETIC_REPLY_LOST'}
        if($ScriptBlock.ToString().Contains('sys.fn_helpcollations()')){return $script:sqlReceipt}
        if($ScriptBlock.ToString().Contains('LAB_NETWORK_GUEST_ADAPTER_NOT_FOUND')){
            $script:guestAddress=[string]$ArgumentList[1]
            return [pscustomobject]@{contractVersion='1';network=$ArgumentList[3];addressMode=$ArgumentList[0];address=$ArgumentList[1];prefixLength=$ArgumentList[2];addressState='Preferred';observedAt='synthetic-time'}
        }
        [pscustomobject]@{runId=$ExpectedRunId;scopeId=$ExpectedScopeId;observedAt='synthetic-time'}
    }
    Set-Item Function:Invoke-HyperVPowerShellDirect -Value ([scriptblock]::Create($ParamBlock+[Environment]::NewLine+$spy.ToString()))
} -ArgumentList (,$definitions),$transport.Body.ParamBlock.Extent.Text
try {
    $count=& $module {
        param($Fixture)
        $script:checks=0;$script:root=$Fixture
        $script:runId='8d140b7b-9294-4b85-a5e3-308854b4ea2e';$script:scopeId='a16f430c-9789-494b-ad8f-760b554661f3'
        $script:vmId=[guid]'9633427c-2101-4dba-ab46-4af532c290a7'
        $script:credential=[pscredential]::new('synthetic-user',[securestring]::new())
        $script:runDirectory=Join-Path (Join-Path $Fixture 'runs') $script:runId
        $script:connectionPath=Join-Path $script:runDirectory 'connection-info.json'
        $script:boundPath=Join-Path $script:runDirectory 'network-bound-plan.json'
        $script:ipamPath=Join-Path (Join-Path $Fixture 'network') 'hyperv-ipam.json'
        $null=New-Item -ItemType Directory -Path $script:runDirectory,(Split-Path -Parent $script:ipamPath) -Force
        function Check([bool]$Value,[string]$Name){if(-not $Value){throw "COMPLETION_REGRESSION_FAILED: $Name"};$script:checks++;Write-Host "PASS: $Name"}
        function Save-Fixture($Path,$Value){ConvertTo-Json -InputObject $Value -Depth 30|Set-Content -LiteralPath $Path}
        function Reset-Case {
            $script:calls=[Collections.Generic.List[object]]::new();$script:rootReads=@();$script:writes=0;$script:lostReply=$false;$script:guestAddress=''
            $script:bound=[pscustomobject]@{Name='synthetic-switch';Intent='hostOnly';Subnet='192.0.2.0/24';HostAddress='192.0.2.1';PrefixLength=24;address='192.0.2.42'}
            $script:lease=[pscustomobject]@{runId=$script:runId;scopeId=$script:scopeId;instanceId='primary';state='ACTIVE';network=$script:bound.Name;subnet=$script:bound.Subnet;address=$script:bound.address}
            $script:registry=[pscustomobject]@{contractVersion='1';leases=@($script:lease)}
            $script:run=[pscustomobject]@{runId=$script:runId;scopeId=$script:scopeId;metadata=[pscustomobject]@{workflowKind='hyperv-lab';requireExistingNetwork=$true}}
            $script:instance=[pscustomobject]@{id='primary';provider='hyperv';vmName='synthetic-vm';vmId=$script:vmId.ToString();labNetwork=($script:bound|ConvertTo-Json|ConvertFrom-Json);sqlCompletion=[pscustomobject]@{state='COLLATION_PENDING'}}
            Save-Fixture $script:connectionPath ([pscustomobject]@{instances=@($script:instance)})
            Save-Fixture $script:boundPath $script:bound;Save-Fixture $script:ipamPath $script:registry
            $script:sqlReceipt=[pscustomobject]@{RunId=$script:runId;ScopeId=$script:scopeId;InstanceName='MSSQLSERVER';MajorVersion=17;CatalogAvailable=$true;ObservedAt='synthetic-time';ServerCollation='SQL_Latin1_General_CP1_CS_AS';MasterCollation='SQL_Latin1_General_CP1_CS_AS';TempdbCollation='SQL_Latin1_General_CP1_CS_AS'}
        }
        function Get-LabRunState {param($RunId,$StateRoot)if($RunId -cne $script:runId -or $StateRoot -cne $script:root){throw 'FIXTURE_ROOT_CHANGED'};$script:rootReads+=@($StateRoot);$script:run}
        function Get-HyperVLabVMs {param($RunId,$ScopeId)if($RunId -cne $script:runId -or $ScopeId -cne $script:scopeId){throw 'FIXTURE_RUN_CHANGED'};[pscustomobject]@{VMId=$script:vmId;VMName='synthetic-vm'}}
        function Get-HyperVManagedVM {param($VMName,$ExpectedRunId,$ExpectedScopeId)if($VMName -cne 'synthetic-vm' -or $ExpectedRunId -cne $script:runId -or $ExpectedScopeId -cne $script:scopeId){throw 'FIXTURE_VM_CHANGED'};[pscustomobject]@{VM=[pscustomobject]@{Id=$script:vmId;State='Running'}}}
        function Assert-LabWindowsPoolMutationAllowed {param($RunId,$StateRoot,[switch]$InvalidateEvidence)if($RunId -cne $script:runId -or $StateRoot -cne $script:root){throw 'FIXTURE_ADMISSION_ROOT_CHANGED'}}
        function Resolve-LabHyperVNetworkBoundPlan {param($Intent,$SwitchName,$Subnet)[pscustomobject]@{Status='READY';Actions=@();Name=$script:bound.Name;Intent='hostOnly';Subnet=$script:bound.Subnet;HostAddress=$script:bound.HostAddress;PrefixLength=$script:bound.PrefixLength}}
        function Get-VMNetworkAdapter {[CmdletBinding()]param($VM,$VMName)[pscustomobject]@{SwitchName='synthetic-switch'}}
        function Add-VMNetworkAdapter {throw 'NATIVE_MUTATION_FORBIDDEN'}
        function Repair-HyperVLabSqlWmiProvider {}
        function Get-HyperVLabSqlInstanceReceipt {}
        function Save-HyperVLabSqlInstanceReceipt {param($Lab,$Receipt,$ExpectedVmId)if($Lab.StateRoot -cne $script:root){throw 'FIXTURE_WRITE_ROOT_CHANGED'};$script:writes++;Save-Fixture $script:connectionPath $Lab.Connection}
        function Write-LabInfo {}
        function Write-LabSuccess {}
        function Resolve-LabSqlServerCollation {param($Name,$SqlVersion)$Name}
        function Get-HyperVSqlMajorVersionFromVersion {param($SqlVersion)17}
        function Get-SqlServerVersion {param($VersionId)[pscustomobject]@{id=$VersionId}}
        function Invoke-Host([switch]$Direct){$binding=@{};if($Direct){$binding.ExpectedVmId=$script:vmId};Enable-HyperVLabHostSqlAccess -RunId $script:runId -StateRoot $script:root -Credential $script:credential @binding}
        function Invoke-Evidence([switch]$Direct){$binding=@{};if($Direct){$binding.ExpectedVmId=$script:vmId};$lab=Get-HyperVLabWorkflowRun -RunId $script:runId -StateRoot $script:root @binding;Test-LabHyperVSqlCollationRuntimeEvidence -Lab $lab -Credential $script:credential -Collation SQL_Latin1_General_CP1_CS_AS -SqlVersion 2025 @binding}

        foreach($direct in @($false,$true)){
            Reset-Case
            $result=Invoke-Host -Direct:$direct
            $saved=Get-Content -LiteralPath $script:connectionPath -Raw|ConvertFrom-Json -Depth 30
            Check ($result.Network.Address -ceq $script:lease.address -and $script:guestAddress -ceq $script:lease.address -and $saved.instances[0].host -ceq $script:lease.address -and $saved.instances[0].labNetwork.subnet -ceq $script:bound.Subnet) "Lease, guest argument, host receipt and connection agree (Direct=$direct)"
            Check ($script:calls.Count -eq 2 -and @($script:calls|Where-Object{-not $_.NoRetry -or $_.VmIdBound -ne $direct}).Count -eq 0 -and $script:rootReads.Count -gt 0) "Actual HostSQL preserves selected root, identity, credential and NoRetry (Direct=$direct)"
        }
        foreach($case in @('missing','malformed','registryArray','empty','released','duplicate','scope','run','instance','network','subnet','address','addressCollision','savedAddress','missingPlan','planAddress')){
            Reset-Case
            switch($case){
                empty {$script:registry.leases=@()}
                released {$script:lease.state='RELEASED'}
                duplicate {$script:registry.leases=@($script:lease,$script:lease)}
                scope {$script:lease.scopeId='53a98178-a7d6-426f-b2a7-4730fb3e1418'}
                run {$script:lease.runId='53a98178-a7d6-426f-b2a7-4730fb3e1418'}
                instance {$script:lease.instanceId='foreign'}
                network {$script:lease.network='foreign'}
                subnet {$script:lease.subnet='198.51.100.0/24'}
                address {$script:lease.address='192.0.2.43'}
                addressCollision {$foreign=$script:lease.PSObject.Copy();$foreign.runId='53a98178-a7d6-426f-b2a7-4730fb3e1418';$script:registry.leases=@($script:lease,$foreign)}
                savedAddress {$script:instance.labNetwork.address='192.0.2.43';Save-Fixture $script:connectionPath ([pscustomobject]@{instances=@($script:instance)})}
                planAddress {$script:bound.address='192.0.2.43';Save-Fixture $script:boundPath $script:bound}
            }
            Save-Fixture $script:ipamPath $script:registry
            switch($case){missing{Remove-Item -LiteralPath $script:ipamPath} malformed{'not-json'|Set-Content -LiteralPath $script:ipamPath} registryArray{Save-Fixture $script:ipamPath @($script:registry)} missingPlan{Remove-Item -LiteralPath $script:boundPath}}
            $code='';try{$null=Invoke-Host -Direct}catch{$code=$_.Exception.Message}
            Check ($code -ceq 'HYPERV_LAB_HOST_SQL_LEASE_BINDING_INVALID' -and $script:calls.Count -eq 0 -and $script:writes -eq 0) "Inconsistent lease blocks before guest dispatch and writes: $case"
        }
        Reset-Case
        $lab=Get-HyperVLabWorkflowRun -RunId $script:runId -StateRoot $script:root
        $lab.RunDirectory=Join-Path $script:root 'foreign'
        $code='';try{Get-HyperVLabHostSqlNetworkLeaseAddress -Lab $lab -Network $script:bound}catch{$code=$_.Exception.Message}
        Check ($code -ceq 'HYPERV_LAB_HOST_SQL_LEASE_BINDING_INVALID' -and $script:calls.Count -eq 0) 'Run directory cannot escape selected root/run binding'

        foreach($direct in @($false,$true)){
            Reset-Case;$result=Invoke-Evidence -Direct:$direct
            Check ($result.Status -ceq 'VERIFIED' -and $script:calls.Count -eq 1 -and $script:calls[0].NoRetry -and $script:calls[0].VmIdBound -eq $direct) "Actual collation caller binds original transport signature (Direct=$direct)"
        }
        foreach($field in @('ServerCollation','MasterCollation','TempdbCollation')){
            foreach($case in @('absent','null','dbnull','empty','whitespace','number','invalid','different')){
                Reset-Case
                switch($case){absent{$script:sqlReceipt.PSObject.Properties.Remove($field)} null{$script:sqlReceipt.$field=$null} dbnull{$script:sqlReceipt.$field=[DBNull]::Value} empty{$script:sqlReceipt.$field=''} whitespace{$script:sqlReceipt.$field=' '} number{$script:sqlReceipt.$field=17} invalid{$script:sqlReceipt.$field='invalid value'} different{$script:sqlReceipt.$field='SQL_Latin1_General_CP1_CI_AS'}}
                $expected=if($case -ceq 'different'){'HYPERV_SQL_COLLATION_POSTCONDITION_FAILED'}else{'HYPERV_SQL_COLLATION_RECEIPT_INVALID'}
                $code='';try{$null=Invoke-Evidence -Direct}catch{$code=$_.Exception.Message}
                Check ($code -ceq $expected -and $script:writes -eq 0) "Evidence classification $field/$case"
            }
        }
        Reset-Case;$script:sqlReceipt.MasterCollation='SQL_Latin1_General_CP1_CI_AS';$script:sqlReceipt.TempdbCollation=$null
        $code='';try{$null=Invoke-Evidence}catch{$code=$_.Exception.Message}
        Check ($code -ceq 'HYPERV_SQL_COLLATION_RECEIPT_INVALID') 'Missing evidence takes precedence over a simultaneous observed mismatch'
        Reset-Case;$script:lostReply=$true
        $code='';try{$null=Invoke-Evidence}catch{$code=$_.Exception.Message}
        Check ($code -ceq 'HYPERV_SQL_COLLATION_QUERY_FAILED' -and $script:calls.Count -eq 1 -and $script:calls[0].NoRetry) 'Lost query reply cannot produce evidence or a collation mismatch'
        Reset-Case
        $before=$script:calls.Count;$code=''
        try{Invoke-HyperVPowerShellDirect -StateRoot $script:root -VMName synthetic-vm -ExpectedRunId $script:runId -ExpectedScopeId $script:scopeId -Credential $script:credential -ScriptBlock {throw 'GUEST_FORBIDDEN'}}catch{$code=$_.FullyQualifiedErrorId}
        Check ($code -like 'NamedParameterNotFound*' -and $script:calls.Count -eq $before) 'Original ParamBlock rejects unsupported named parameters before the closed body'
        $script:checks
    } $fixture
    Write-Host "Completion regression: $count PASS, 0 FAIL; closed transports only"
    [pscustomobject]@{Passed=$count;Failed=0}
} finally {
    Remove-Module $module -Force
    $tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar
    if(-not [IO.Path]::GetFullPath($fixture).StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase)){throw 'FIXTURE_CLEANUP_OUTSIDE_TEMP'}
    Remove-Item -LiteralPath $fixture -Recurse -Force
}
