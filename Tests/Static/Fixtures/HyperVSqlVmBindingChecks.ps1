#Requires -Version 7.2
[CmdletBinding()]
param([string]$RepoRoot=(Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path)
$ErrorActionPreference='Stop'
$definitions=@()
foreach($source in @(
    @{Path='Private/HyperVLabEnvironment.ps1';Names=@('Get-HyperVLabWorkflowRun','Assert-HyperVLabSqlVmBinding','Assert-HyperVLabSqlExistingNetwork','Complete-HyperVLabSqlImage','Enable-HyperVLabHostSqlAccess','Repair-HyperVLabSqlWmiProvider','Get-HyperVLabSqlInstanceReceipt','Save-HyperVLabSqlInstanceReceipt','Wait-HyperVLabSqlCompletionRestart')},
    @{Path='Private/LabNetwork.ps1';Names=@('Initialize-HyperVGuestLabNetwork')},
    @{Path='Providers/HyperV/HyperVProvider.ps1';Names=@('Invoke-HyperVPowerShellDirect','Wait-HyperVGuestSqlReady')},
    @{Path='Private/HyperVSqlPortReconcile.ps1';Names=@('Set-LabHyperVSqlPortBinding')}
)){
    $t=$null;$e=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot $source.Path),[ref]$t,[ref]$e)
    if($e.Count){throw 'SQL_VM_BINDING_SOURCE_PARSE'}
    foreach($name in $source.Names){
        $f=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$true))
        if($f.Count -ne 1){throw 'SQL_VM_BINDING_FUNCTION_NOT_UNIQUE'}
        $definitions+=$f[0].Extent.Text
    }
}
$module=New-Module -Name ('SqlVmBinding_'+[guid]::NewGuid().ToString('N')) -ScriptBlock {
    param($Definitions,$PublicPath)
    foreach($definition in $Definitions){. ([scriptblock]::Create($definition))}
    . $PublicPath
} -ArgumentList (,$definitions),(Join-Path $RepoRoot 'Public/Invoke-SqlServerLabWorkflowAction.ps1')
try{
    $result=& $module {
        $script:passed=0;$script:failed=0
        $script:vmId=[guid]'9633427c-2101-4dba-ab46-4af532c290a7'
        $script:otherId=[guid]'53a98178-a7d6-426f-b2a7-4730fb3e1418'
        $script:runId='8d140b7b-9294-4b85-a5e3-308854b4ea2e'
        $script:scopeId='a16f430c-9789-494b-ad8f-760b554661f3'
        $script:stateRoot='/synthetic/sql-binding-state'
        $script:credential=[pscredential]::new('synthetic-user',[securestring]::new())
        $password=[securestring]::new();$password.AppendChar('x');$password.MakeReadOnly()
        function Check([bool]$Value,[string]$Label){if($Value){$script:passed++;Write-Host "PASS: $Label"}else{$script:failed++;Write-Host "FAIL: $Label"}}
        function Copy-Value($Value){ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $Value -Depth 30) -Depth 30 -NoEnumerate}
        function Reset-Case([switch]$Network){
            $script:nativeId=$script:vmId;$script:lostStage='';$script:driftStage='';$script:afterDrift=$false;$script:foreignScopeReply=$false
            $script:poolWrites=0;$script:secretWrites=0;$script:metadataWrites=0;$script:notesWrites=0;$script:dvdWrites=0;$script:afterDriftWrites=0
            $script:sharedNetworkWrites=0;$script:adapterReads=0;$script:activationBound=$false;$script:adapterVMOnly=$true;$script:dvdVMOnly=$true
            $script:guestCalls=[Collections.Generic.List[object]]::new();$script:rootReads=[Collections.Generic.List[string]]::new()
            $script:run=[pscustomobject]@{runId=$script:runId;scopeId=$script:scopeId;metadata=[pscustomobject]@{workflowKind='hyperv-lab';networkIntent=$(if($Network){'hostOnly'}else{'isolated'});requireExistingNetwork=$false}}
            $instance=[pscustomobject]@{id='primary';provider='hyperv';vmName='synthetic-old-name';vmId=$script:vmId.ToString();imageArtifactId='synthetic-prepared-image';windowsActivationIntent=[pscustomobject]@{Strategy='VerifyOnly';EgressPolicy='Denied'}}
            if($Network){$instance|Add-Member NoteProperty labNetwork ([pscustomobject]@{name='synthetic-bound-switch';intent='hostOnly';subnet='192.0.2.0/24';hostAddress='192.0.2.1';prefixLength=24;address='192.0.2.2'})}
            $script:connection=[pscustomobject]@{instances=@($instance)}
        }
        function Write-LabInfo {}
        function Write-LabSuccess {}
        function Write-LabWarning {}
        function Get-LabTimestamp {'synthetic-time'}
        function Test-HyperVAvailable {[pscustomobject]@{Available=$true;Message='synthetic'}}
        Set-Variable -Name IsWindows -Scope Script -Value $true -Force
        function Get-LabRunState {param($RunId,$StateRoot)$script:rootReads.Add([string]$StateRoot);Copy-Value $script:run}
        function Test-Path {param($LiteralPath,$PathType) $LiteralPath -like '*connection-info.json'}
        function Get-Content {param($LiteralPath,[switch]$Raw,$Encoding,$Depth)ConvertTo-Json -InputObject $script:connection -Depth 30}
        function Get-HyperVLabVMs {param($RunId,$ScopeId)[pscustomobject]@{VMId=$script:nativeId.ToString();VMName='synthetic-current-name'}}
        function Get-HyperVManagedVM {
            param($VMName,$ExpectedRunId,$ExpectedScopeId)
            if($VMName -cne 'synthetic-current-name' -or $ExpectedRunId -cne $script:runId -or $ExpectedScopeId -cne $script:scopeId){throw 'FIXTURE_NATIVE_SELECTOR_MISMATCH'}
            [pscustomobject]@{VM=[pscustomobject]@{Id=$script:nativeId;Name='synthetic-current-name';State='Running'};Identity=[pscustomobject]@{guestTransport='lab-winrm';windowsSpecialization=[pscustomobject]@{status='WINDOWS_SPECIALIZED'}}}
        }
        function Assert-LabWindowsPoolMutationAllowed {param($RunId,$StateRoot,[switch]$InvalidateEvidence)$script:poolWrites++}
        function Assert-LabWindowsPoolProviderMutation {param($Managed,$StateRoot)if($StateRoot -cne $script:stateRoot){throw 'FIXTURE_PROVIDER_ROOT_CHANGED'}}
        function Assert-LabHyperVResourceMigrationLifecycleAllowed {}
        function Get-HyperVImageArtifact {[pscustomobject]@{artifactState='SQL_PREPARED_SEALED';sql=[pscustomobject]@{edition='EnterpriseDeveloper';version='2025'}}}
        function ConvertTo-HyperVSqlMediaEdition {'Enterprise'}
        function Get-HyperVSqlInstallationMediaCandidates {[pscustomobject]@{State='READY';SqlVersion='2025';MediaEdition='Enterprise';MediaId='synthetic-media'}}
        function Resolve-HyperVSqlInstallationMedia {[pscustomobject]@{HashStatus='SIDECAR_READY';IsoPath='D:/synthetic/sql.iso'}}
        function Get-HyperVSqlMajorVersionFromVersion {17}
        function Get-LabSecret {if($script:driftStage -ceq 'SecretRead'){$script:nativeId=$script:otherId;$script:afterDrift=$true};$script:credential.Password}
        function Save-LabHyperVSqlSaPassword {param($RunDirectory,$SqlSaPassword,[switch]$Generated)$script:secretWrites++;if($RunDirectory -cne (Join-Path (Join-Path $script:stateRoot 'runs') $script:runId)){throw 'FIXTURE_SECRET_ROOT_CHANGED'}}
        function Invoke-LabWindowsSlotActivationReconcile {param($RunId,$Credential,$StateRoot,[guid]$ExpectedVmId)$script:activationBound=$ExpectedVmId -eq $script:vmId -and $StateRoot -ceq $script:stateRoot}
        function Resolve-LabHyperVNetworkBoundPlan {[pscustomobject]@{Status='READY';Actions=@();Name='synthetic-bound-switch';Intent='hostOnly';Subnet='192.0.2.0/24';HostAddress='192.0.2.1';PrefixLength=24}}
        function Get-LabNetworkGuestAddress {param($Network,$Identity)if($Identity -cne $script:runId){throw 'FIXTURE_NETWORK_IDENTITY_CHANGED'};'192.0.2.2'}
        function Resolve-LabHyperVNetwork {$script:sharedNetworkWrites++;throw 'FIXTURE_SHARED_NETWORK_REPAIR'}
        function Invoke-LabHyperVNetworkBoundPlan {$script:sharedNetworkWrites++;throw 'FIXTURE_SHARED_NETWORK_REPAIR'}
        function Get-VMNetworkAdapter {
            [CmdletBinding()]param($VM,$VMName)
            $script:adapterReads++;$script:adapterVMOnly=$script:adapterVMOnly -and $PSBoundParameters.ContainsKey('VM') -and -not $PSBoundParameters.ContainsKey('VMName') -and $VM.Id -eq $script:vmId
            [pscustomobject]@{SwitchName='synthetic-bound-switch'}
        }
        function Add-VMNetworkAdapter {$script:sharedNetworkWrites++;throw 'FIXTURE_ADAPTER_ADD'}
        function Get-VMDvdDrive {[CmdletBinding()]param($VM,$VMName)$script:dvdVMOnly=$PSBoundParameters.ContainsKey('VM') -and -not $PSBoundParameters.ContainsKey('VMName') -and $VM.Id -eq $script:vmId}
        function Add-VMDvdDrive {[CmdletBinding()]param($VM,$VMName,$Path)$script:dvdWrites++;$script:dvdVMOnly=$script:dvdVMOnly -and $PSBoundParameters.ContainsKey('VM') -and -not $PSBoundParameters.ContainsKey('VMName') -and $VM.Id -eq $script:vmId}
        function Write-LabArtifactJsonAtomic {
            param($Path,$InputObject)
            $script:metadataWrites++;if($script:afterDrift){$script:afterDriftWrites++}
            if($Path -cne (Join-Path (Join-Path (Join-Path $script:stateRoot 'runs') $script:runId) 'connection-info.json')){throw 'FIXTURE_METADATA_ROOT_CHANGED'}
            $script:connection=Copy-Value $InputObject
        }
        function Set-HyperVManagedVMIdentityProperty {param($ManagedVM,$PropertyName,$Value,$ContractVersion,$StateRoot)$script:notesWrites++;if($script:afterDrift){$script:afterDriftWrites++};if($ManagedVM.VM.Id -ne $script:vmId -or $StateRoot -cne $script:stateRoot){throw 'FIXTURE_NOTES_BINDING_CHANGED'}}
        function Start-LabActionProgress {[pscustomobject]@{}}
        function Update-LabActionProgress {}
        function Stop-LabActionProgress {}
        function Wait-LabProgressDelay {}
        function Invoke-HyperVWinRmFallback {throw 'FIXTURE_FALLBACK_FORBIDDEN'}
        function Invoke-Command {
            [CmdletBinding()]param([guid]$VMId,$VMName,$Credential,$ScriptBlock,$ArgumentList,[switch]$AsJob)
            $text=$ScriptBlock.ToString();$stage='HostSQL'
            if($text.Contains('HYPERV_LAB_SQL_COMPLETE_TIMEOUT')){$stage='Complete'}
            elseif($text.Contains('HYPERV_LAB_SQL_WMI_INSTANCE_VERSION_NOT_FOUND')){$stage='WMI'}
            elseif($text.Contains('inspectedAt')){$stage='Inspect'}
            elseif($text.Contains('HYPERV_SQL_PORT_RECONCILE_')){$stage='Port'}
            elseif($text.Contains('LAB_NETWORK_GUEST_ADAPTER_NOT_FOUND')){$stage='Network'}
            elseif($text.Contains('SQL_READY_RUN')){$stage='Ready'}
            elseif($text.Contains('LastBootUpTime')){$stage='Restart'}
            $script:guestCalls.Add([pscustomobject]@{Stage=$stage;Id=$VMId;IdBound=$PSBoundParameters.ContainsKey('VMId');NameBound=$PSBoundParameters.ContainsKey('VMName')})
            $receipt=switch($stage){
                Complete {[pscustomobject]@{runId=$script:runId;scopeId=$script:scopeId;exitCode=0;serviceName='MSSQLSERVER';serviceStatus='Running';completedAt='synthetic-time'}}
                WMI {[pscustomobject]@{runId=$script:runId;scopeId=$script:scopeId;repaired=$false;observedAt='synthetic-time'}}
                Inspect {[pscustomobject]@{runId=$script:runId;scopeId=$script:scopeId;inspectedAt='synthetic-time';instances=@([pscustomobject]@{name='MSSQLSERVER';instanceId='MSSQL17.MSSQLSERVER';isDefault=$true;serviceName='MSSQLSERVER';serviceStatus='Running';tcpPort=15433})}}
                Port {[pscustomobject]@{Status='APPLIED';Port=15433;ServiceName='MSSQLSERVER';ServiceStatus='Running'}}
                Network {[pscustomobject]@{contractVersion='1';network='synthetic-bound-switch';addressMode='static';address='192.0.2.2';prefixLength=24;addressState='Preferred';gateway=$null;dnsServers=@()}}
                Ready {[pscustomobject]@{status='SQL_READY_RUN';instanceName='MSSQLSERVER';onlineSystemDatabases=4;majorVersion=17;productVersion='17.0.synthetic';edition='Synthetic';observedAt='synthetic-time'}}
                Restart {[pscustomobject]@{bootTime='new-synthetic-boot';imageState='IMAGE_STATE_COMPLETE'}}
                HostSQL {[pscustomobject]@{runId=$script:runId;scopeId=$script:scopeId;observedAt='synthetic-time'}}
            }
            [pscustomobject]@{Id=1;Stage=$stage;Receipt=$receipt}
        }
        function Receive-LabProgressJob {
            param($Job)
            if($Job.Stage -ceq $script:lostStage){throw 'SYNTHETIC_REPLY_LOST'}
            if($Job.Stage -ceq 'Complete' -and $script:foreignScopeReply){$Job.Receipt.scopeId='004b1b43-6e47-4605-b93c-dd93c90e0a75'}
            if($Job.Stage -ceq $script:driftStage){$script:nativeId=$script:otherId;$script:afterDrift=$true}
            $Job.Receipt
        }
        function Invoke-Complete {Complete-HyperVLabSqlImage -RunId $script:runId -Credential $script:credential -SqlPort 15433 -MediaRoot 'D:/synthetic/media' -StateRoot $script:stateRoot -ExpectedVmId $script:vmId}
        function Invoke-Host {Enable-HyperVLabHostSqlAccess -RunId $script:runId -Credential $script:credential -SqlPort 15433 -StateRoot $script:stateRoot -ExpectedVmId $script:vmId}
        function Check-SelectedCalls {
            Check ($script:guestCalls.Count -gt 0 -and @($script:guestCalls|Where-Object{-not $_.IdBound -or $_.NameBound -or $_.Id -ne $script:vmId}).Count -eq 0) 'Every actual downstream guestcall uses the selected VMId Direct selector'
            Check (@($script:rootReads|Where-Object{$_ -cne $script:stateRoot}).Count -eq 0) 'All actual workflow rereads retain selected StateRoot'
            Check ($script:sharedNetworkWrites -eq 0) 'Selected workflow does not repair shared network or add an adapter'
        }
        Reset-Case
        $value=$null;$errorText='';try{$value=Invoke-Complete}catch{$errorText=$_.Exception.Message}
        Check ($value -and $value.state -ceq 'COMPLETE' -and $value.sqlReadiness.status -ceq 'SQL_READY_RUN') ('Isolated actual Complete/port/inspection/readiness succeeds: '+$errorText)
        Check ($script:activationBound -and $script:dvdWrites -eq 1 -and $script:dvdVMOnly) 'Actual Complete propagates activation identity and uses native DVD VM object'
        Check ($script:metadataWrites -gt 0 -and $script:notesWrites -eq 1) 'Actual selected chain reaches protected synthetic metadata and Notes leaves'
        Check-SelectedCalls
        Reset-Case -Network
        $value=$null;$errorText='';try{$value=Invoke-Complete}catch{$errorText=$_.Exception.Message}
        Check ($value -and $value.state -ceq 'COMPLETE' -and $value.hostSqlAccess) ('Actual Complete reaches actual HostSQL/WMI/network/receipt chain: '+$errorText)
        Check ($script:adapterReads -gt 0 -and $script:adapterVMOnly) 'Host adapter reads use the native VM object'
        Check-SelectedCalls
        Reset-Case -Network
        $value=$null;try{$value=Invoke-Host}catch{}
        Check ($value -and $value.Sql -and $script:guestCalls.Count -eq 4) 'Actual standalone strict HostSQL completes network, WMI, SQL and inspection'
        Check-SelectedCalls
        Check ($script:connection.instances[0].labNetwork.subnet -ceq '192.0.2.0/24') 'Successful selected HostSQL preserves the bound subnet in persisted metadata'
        $second=$null;try{$second=Invoke-Host}catch{}
        Check ($second -and $second.Sql -and $script:guestCalls.Count -eq 8 -and $script:sharedNetworkWrites -eq 0) 'A new request after completed HostSQL accepts the same unchanged network binding'
        Reset-Case;$script:foreignScopeReply=$true;$blocked=$false
        try{$null=Invoke-Complete}catch{$blocked=$_.Exception.Message -ceq 'HYPERV_LAB_SQL_COMPLETE_RECEIPT_INVALID'}
        Check ($blocked -and $script:guestCalls.Count -eq 1 -and $script:metadataWrites -eq 0 -and $script:notesWrites -eq 0) 'A foreign CompleteImage reply scope blocks WMI/port/metadata follow-up without replay'
        foreach($stage in @('Complete','WMI','Port')){
            Reset-Case;$script:lostStage=$stage;$blocked=$false
            try{$null=Invoke-Complete}catch{$blocked=$_.Exception.Message -ceq 'SYNTHETIC_REPLY_LOST'}
            Check ($blocked -and @($script:guestCalls|Where-Object Stage -CEQ $stage).Count -eq 1) ('Lost reply after synthetic '+$stage+' write is not replayed')
        }
        foreach($stage in @('Network','HostSQL')){
            Reset-Case -Network;$script:lostStage=$stage;$blocked=$false
            try{$null=Invoke-Host}catch{$blocked=$_.Exception.Message -ceq 'SYNTHETIC_REPLY_LOST'}
            Check ($blocked -and @($script:guestCalls|Where-Object Stage -CEQ $stage).Count -eq 1) ('Lost reply after synthetic '+$stage+' write is not replayed')
        }
        foreach($stage in @('WMI','Port','Ready')){
            Reset-Case;$script:driftStage=$stage;$blocked=$false
            try{$null=Invoke-Complete}catch{$blocked=$_.Exception.Message -match '^HYPERV_(LAB_EXPECTED_VM|LAB_SQL_VM_BINDING|GUEST_VM_ID)'}
            Check ($blocked -and $script:afterDriftWrites -eq 0) ('VM drift after '+$stage+' reply blocks later metadata/Notes writes')
        }
        Reset-Case;$script:driftStage='SecretRead';$blocked=$false
        try{$null=Invoke-Complete}catch{$blocked=$_.Exception.Message -match '^HYPERV_(LAB_EXPECTED_VM|LAB_SQL_VM_BINDING|GUEST_VM_ID)'}
        Check ($blocked -and $script:secretWrites -eq 0 -and $script:dvdWrites -eq 0 -and $script:guestCalls.Count -eq 0) 'VM drift during secret selection blocks secret persistence and later effects'
        foreach($invalid in @('Empty','Stored','Native','Scope','Root')){
            Reset-Case;$selected=$script:vmId;$runInput=$script:runId;$rootInput=$script:stateRoot
            switch($invalid){Empty{$selected=[guid]::Empty};Stored{$script:connection.instances[0].vmId=$script:otherId.ToString()};Native{$script:nativeId=$script:otherId};Scope{$script:run.scopeId=' '};Root{$rootInput=' '}}
            $blocked=$false;try{$null=Complete-HyperVLabSqlImage -RunId $runInput -Credential $script:credential -StateRoot $rootInput -ExpectedVmId $selected}catch{$blocked=$true}
            Check ($blocked -and $script:poolWrites -eq 0 -and $script:guestCalls.Count -eq 0 -and $script:secretWrites -eq 0 -and $script:dvdWrites -eq 0 -and $script:metadataWrites -eq 0) ('Invalid '+$invalid+' binding blocks before pool, secrets, DVD or guest effects')
        }
        Reset-Case -Network;$script:connection.instances[0].labNetwork.intent='lan'
        $blocked=$false;try{$null=Invoke-Host}catch{$blocked=$_.Exception.Message -ceq 'HYPERV_LAB_HOST_SQL_EXISTING_NETWORK_REQUIRED'}
        Check ($blocked -and $script:poolWrites -eq 0 -and $script:sharedNetworkWrites -eq 0 -and $script:guestCalls.Count -eq 0) 'Strict HostSQL rejects an unqualified network before effects'
        Reset-Case -Network
        $blocked=$false;try{$null=Enable-HyperVLabHostSqlAccess -RunId $script:runId -Credential $script:credential -StateRoot $script:stateRoot -ExpectedVmId $script:vmId -SwitchName 'foreign-switch'}catch{$blocked=$_.Exception.Message -ceq 'HYPERV_LAB_HOST_SQL_EXISTING_NETWORK_REQUIRED'}
        Check ($blocked -and $script:poolWrites -eq 0 -and $script:guestCalls.Count -eq 0) 'Strict HostSQL cannot replace the bound switch'
        Reset-Case
        $lab=Get-HyperVLabWorkflowRun -RunId $script:runId -StateRoot $script:stateRoot -ExpectedVmId $script:vmId
        $r=Wait-HyperVLabSqlCompletionRestart -Lab $lab -Credential $script:credential -PreviousBootTime 'old-synthetic-boot' -ExpectedVmId $script:vmId -TimeoutSeconds 30
        Check ($r.Ready -and $script:guestCalls.Count -eq 1) 'Actual restart wait propagates immutable Direct identity'
        Reset-Case
        $lab=Get-HyperVLabWorkflowRun -RunId $script:runId -StateRoot $script:stateRoot -ExpectedVmId $script:vmId
        $blocked=$false
        try{$null=Save-HyperVLabSqlInstanceReceipt -Lab $lab -Receipt ([pscustomobject]@{runId='foreign';scopeId=$script:scopeId;instances=@()}) -ExpectedVmId $script:vmId}catch{$blocked=$_.Exception.Message -ceq 'HYPERV_LAB_SQL_INSPECTION_RECEIPT_INVALID'}
        Check ($blocked -and $script:metadataWrites -eq 0) 'Selected receipt writer rejects foreign receipt ownership before write'
        foreach($name in @('Get-HyperVLabSqlInstanceReceipt','Repair-HyperVLabSqlWmiProvider','Wait-HyperVLabSqlCompletionRestart','Wait-HyperVGuestSqlReady','Initialize-HyperVGuestLabNetwork')){
            Reset-Case;$blocked=$false
            try{
                switch($name){
                    Get-HyperVLabSqlInstanceReceipt {$null=Get-HyperVLabSqlInstanceReceipt -Lab ([pscustomobject]@{}) -Credential $script:credential -FallbackAddress '192.0.2.2' -ExpectedVmId $script:vmId}
                    Repair-HyperVLabSqlWmiProvider {$null=Repair-HyperVLabSqlWmiProvider -RunId $script:runId -StateRoot $script:stateRoot -Credential $script:credential -FallbackAddress '192.0.2.2' -ExpectedVmId $script:vmId}
                    Wait-HyperVLabSqlCompletionRestart {$null=Wait-HyperVLabSqlCompletionRestart -Lab ([pscustomobject]@{}) -Credential $script:credential -PreviousBootTime 'old' -FallbackAddress '192.0.2.2' -ExpectedVmId $script:vmId}
                    Wait-HyperVGuestSqlReady {$null=Wait-HyperVGuestSqlReady -VMName 'synthetic-current-name' -ExpectedRunId $script:runId -ExpectedScopeId $script:scopeId -StateRoot $script:stateRoot -Credential $script:credential -SaPassword $password -FallbackAddress '192.0.2.2' -ExpectedVmId $script:vmId}
                    Initialize-HyperVGuestLabNetwork {$null=Initialize-HyperVGuestLabNetwork -VMName 'synthetic-current-name' -ExpectedRunId $script:runId -ExpectedScopeId $script:scopeId -Credential $script:credential -Network ([pscustomobject]@{}) -Identity $script:runId -FallbackAddress '192.0.2.2' -ExpectedVmId $script:vmId}
                }
            }catch{$blocked=$_.Exception.Message -ceq 'HYPERV_GUEST_VM_ID_BINDING_INVALID'}
            Check ($blocked -and $script:guestCalls.Count -eq 0 -and $script:poolWrites -eq 0 -and $script:rootReads.Count -eq 0) ($name+' rejects selected fallback before reads or effects')
        }
        [pscustomobject]@{Passed=$script:passed;Failed=$script:failed;NativeEffects=0;GuestBodies=0;ActualFunctions=14}
    }
    Write-Host ('SQL VM BINDING: '+$result.Passed+' PASS / '+$result.Failed+' FAIL; native NOT_EXECUTED')
    if($result.Failed){throw 'SQL_VM_BINDING_COUNTEREXAMPLES_FAILED'}
    $result
}finally{Remove-Module $module -Force}
