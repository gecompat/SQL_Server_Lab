# Testinterner, operationsgebundener Clone; im Modulscope laden.
function Get-HyperVResourceAcceptanceSlotSource {
    [CmdletBinding()]
    param([Parameter(Mandatory)][guid]$SourceRunId,[Parameter(Mandatory)][string]$StateRoot)
    # Der allgemeine Workflowgetter repariert alte VM-Namen im Quell-State.
    # Die Clone-Quelle wird deshalb ausschliesslich lesend aufgeloest.
    $sourceRun=Get-LabRunState -RunId $SourceRunId.ToString() -StateRoot $StateRoot
    if([string]$sourceRun.metadata.workflowKind -ne 'hyperv-lab' -or [string]$sourceRun.runId -ine $SourceRunId.ToString()){
        throw 'HYPERV_RESOURCE_SLOT_SOURCE_RUN_INVALID'
    }
    $sourceDirectory=Join-Path (Join-Path $StateRoot 'runs') $SourceRunId.ToString()
    $connectionPath=Join-Path $sourceDirectory 'connection-info.json'
    $boundary=Test-LabPathWithinRoot -Root $StateRoot -Path $connectionPath
    if(-not $boundary.Valid){throw 'HYPERV_RESOURCE_SLOT_SOURCE_STATE_SCOPE_INVALID'}
    $sourceConnection=Get-Content -LiteralPath $connectionPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 20
    $sourceInstances=@($sourceConnection.instances)
    if($sourceInstances.Count -ne 1 -or [string]$sourceInstances[0].provider -ne 'hyperv'){
        throw 'HYPERV_RESOURCE_SLOT_SOURCE_INSTANCE_INVALID'
    }
    $source=[pscustomobject]@{Run=$sourceRun;RunDirectory=$sourceDirectory;Instance=$sourceInstances[0]}
    if([string]$source.Run.state -ne 'STOPPED' -or [string]$source.Instance.workload -ne 'windows' -or
       [string]$source.Instance.baseKind -ne 'windows-baseline' -or
       [string]$source.Instance.windowsProvisioning.state -ne 'COMPLETE' -or $source.Instance.sqlDeploymentPlan){
        throw 'HYPERV_RESOURCE_SLOT_SOURCE_NOT_ELIGIBLE'
    }
    $managed=Get-HyperVManagedVM -VMName ([string]$source.Instance.vmName) -ExpectedRunId $SourceRunId.ToString() -ExpectedScopeId ([string]$source.Run.scopeId)
    if(-not $managed -or [string]$managed.VM.State -ne 'Off' -or [int]$managed.VM.Generation -ne 2 -or
       [string]$managed.VM.Id -ne [string]$source.Instance.vmId -or @(Get-VMSnapshot -VM $managed.VM -ErrorAction Stop).Count){
        throw 'HYPERV_RESOURCE_SLOT_SOURCE_VM_INVALID'
    }
    $disks=@(Get-VMHardDiskDrive -VM $managed.VM -ErrorAction Stop)
    if($disks.Count -ne 1 -or [IO.Path]::GetExtension([string]$disks[0].Path) -ine '.vhdx'){
        throw 'HYPERV_RESOURCE_SLOT_SOURCE_DISK_INVALID'
    }
    $path=[IO.Path]::GetFullPath([string]$disks[0].Path)
    if(-not (Test-HyperVPathWithinRunDirectory -Path $path -RunDirectory $source.RunDirectory) -or
       $path -ine [IO.Path]::GetFullPath([string]$managed.Identity.childVhdxPath)){
        throw 'HYPERV_RESOURCE_SLOT_SOURCE_DISK_SCOPE_INVALID'
    }
    $artifact=Get-HyperVImageArtifact -ArtifactId ([string]$source.Instance.imageArtifactId) -StateRoot $StateRoot
    if(-not $artifact -or [string]$artifact.artifactState -ne 'OS_SEALED' -or
       [string]$artifact.operatingSystem.version -ne '2025' -or
       [string]$artifact.integrityVerification.status -notin @('VERIFIED_HASH','VERIFIED_CACHE')){
        throw 'HYPERV_RESOURCE_SLOT_SOURCE_ARTIFACT_INVALID'
    }
    $password=Get-LabSecret -Path $source.RunDirectory -Name 'guest-administrator-password'
    if(-not $password){throw 'HYPERV_RESOURCE_SLOT_SOURCE_SECRET_MISSING'}
    [pscustomobject]@{Lab=$source;Managed=$managed;Path=$path;Artifact=$artifact;Password=$password}
}

function New-HyperVResourceAcceptanceSlotClone {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][guid]$SourceRunId,
        [Parameter(Mandatory)][string]$ManifestPath,
        [Parameter(Mandatory)][string]$OperationId,
        [Parameter(Mandatory)][string]$MediaRoot,
        [ValidateSet('Enterprise','Standard','Eval')][string]$MediaEdition='Enterprise',
        [Parameter(Mandatory)][securestring]$SqlPassword,
        [Parameter(Mandatory)][string]$StateRoot
    )
    $source=Get-HyperVResourceAcceptanceSlotSource -SourceRunId $SourceRunId -StateRoot $StateRoot
    $resolved=Read-LabManifest -Path $ManifestPath
    $manifest=Get-Content -LiteralPath $ManifestPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 30
    $target=$manifest.instances[0].hyperv
    $media=Resolve-HyperVSqlInstallationMedia -MediaRoot $MediaRoot -SqlVersion 2025 -MediaEdition $MediaEdition
    if([string]$media.HashStatus -ne 'SIDECAR_READY'){throw 'HYPERV_RESOURCE_SLOT_SQL_MEDIA_UNVERIFIED'}
    $null=Confirm-HyperVSqlInstallationMediaVersion -IsoPath $media.IsoPath -SqlVersion 2025
    $networkPlan=Resolve-LabHyperVNetworkBoundPlan -Intent hostOnly
    if([string]$networkPlan.Status -ne 'READY'){throw 'HYPERV_RESOURCE_SLOT_NETWORK_NOT_READY'}
    $sourceLocks=[Collections.Generic.List[IDisposable]]::new()
    $chain=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $run=$null
    try {
        # Read-sharing prevents a source VM start/write while every backing file
        # is converted. No checkpoint or source configuration is changed.
        $path=$source.Path
        while($path){
            $path=[IO.Path]::GetFullPath($path)
            if(-not $chain.Add($path) -or $chain.Count -gt 16){throw 'HYPERV_RESOURCE_SLOT_SOURCE_CHAIN_INVALID'}
            if($path -ine $source.Path -and $path -ine [string]$source.Artifact.Path -and
               -not (Test-HyperVPathWithinRunDirectory -Path $path -RunDirectory $source.Lab.RunDirectory)){
                throw 'HYPERV_RESOURCE_SLOT_SOURCE_CHAIN_SCOPE_INVALID'
            }
            $item=Get-Item -LiteralPath $path -Force -ErrorAction Stop
            if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'HYPERV_RESOURCE_SLOT_SOURCE_REPARSE'}
            $sourceLocks.Add([IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read))
            $vhd=Get-VHD -Path $path -ErrorAction Stop
            $path=[string]$vhd.ParentPath
        }
        $before=Get-HyperVResourceAcceptanceSlotSource -SourceRunId $SourceRunId -StateRoot $StateRoot
        if([string]$before.Managed.VM.Id -cne [string]$source.Managed.VM.Id -or $before.Path -ine $source.Path){
            throw 'HYPERV_RESOURCE_SLOT_SOURCE_CHANGED'
        }
        $activation=[pscustomobject]@{ContractVersion='SqlServerLab.WindowsActivationIntent/1.0';Strategy='VerifyOnly';EgressPolicy='Denied'}
        $run=Invoke-WithLabWorkflowOperationContext -OperationId $OperationId -ScriptBlock {
            New-LabRunState -StateRoot $StateRoot -Metadata @{
                name=[string]$manifest.name;workflowKind='hyperv-lab';baseKind='managed-run-acceptance-clone';workload='windows'
                autostart='off';sourceRunId=$SourceRunId.ToString();purpose='resource-reconcile-native-evidence'
                windowsActivationIntent=$activation;windowsActivationIntentSource='parameters'
                desiredState=(New-LabDesiredStateSnapshot -ResolvedLab $resolved -ProvisioningMode adhoc -PersistentData:$false)
            } -ProviderSubRuns @([pscustomobject]@{id='provider-hyperv';provider='hyperv';instanceIds=@('primary')})
        }
        $null=New-CleanupPlan -RunDir $run.RunDir -RunId $run.RunId -ScopeId $run.ScopeId -ProviderSubRuns @([pscustomobject]@{id='provider-hyperv';provider='hyperv';instanceIds=@('primary')})
        $null=Set-LabRunState -RunId $run.RunId -NewState PROVISIONING -Reason 'Isolierter Ressourcen-Acceptance-Clone wird erstellt.' -StateRoot $StateRoot
        Set-LabProviderSubRunState -RunId $run.RunId -Provider hyperv -NewState PROVISIONING -Reason 'Eigene Kopie einer gestoppten Windows-Quelle.' -StateRoot $StateRoot
        $binding=Initialize-LabHyperVResourceBinding -ResourceId $run.RunId -ResourceClass Run -StateDirectory $run.RunDir
        $copy=Assert-LabHyperVBoundPath -Binding $binding -Path (Join-Path $binding.HyperVResourceRoot 'primary-source-parent.vhdx')
        $null=Add-CleanupStep -RunDir $run.RunDir -ResourceType vhdx -ResourceId $copy -Action remove -Provider hyperv -ProviderSubRunId provider-hyperv -Compensation 'Remove isolated resource acceptance parent copy'
        $null=New-Item -ItemType Directory -Path $binding.HyperVResourceRoot -Force
        Convert-VHD -Path $source.Path -DestinationPath $copy -VHDType Dynamic -ErrorAction Stop
        $copiedVhd=Get-VHD -Path $copy -ErrorAction Stop
        if([string]$copiedVhd.VhdType -ne 'Dynamic' -or $copiedVhd.ParentPath){throw 'HYPERV_RESOURCE_SLOT_COPY_NOT_INDEPENDENT'}
        (Get-Item -LiteralPath $copy -Force).IsReadOnly=$true
        $hash=(Get-FileHash -LiteralPath $copy -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
        $after=Get-HyperVResourceAcceptanceSlotSource -SourceRunId $SourceRunId -StateRoot $StateRoot
        if([string]$after.Managed.VM.Id -cne [string]$before.Managed.VM.Id -or $after.Path -ine $before.Path){throw 'HYPERV_RESOURCE_SLOT_SOURCE_CHANGED'}
    } finally {
        foreach($handle in $sourceLocks){$handle.Dispose()}
    }
    # Any failure leaves operation-bound state for the outer supervisor.
    $network=Invoke-LabHyperVNetworkBoundPlan -Plan $networkPlan
    $lease=Reserve-LabHyperVNetworkAddress -Network $network -RunId $run.RunId -ScopeId $run.ScopeId -InstanceId primary -StateRoot $StateRoot
    $null=Add-CleanupStep -RunDir $run.RunDir -ResourceType ipam-lease -ResourceId ([string]$lease.address) -Action release -Provider hyperv -ProviderSubRunId provider-hyperv -Compensation 'Release resource acceptance IPAM lease'
    $network | Add-Member -NotePropertyName address -NotePropertyValue ([string]$lease.address) -Force
    Write-LabArtifactJsonAtomic -Path (Join-Path $run.RunDir 'network-bound-plan.json') -InputObject $network
    $vm=New-HyperVInstance -ParentVhdxPath $copy -ParentSha256 $hash -RunDirectory $run.RunDir -RunId $run.RunId -ScopeId $run.ScopeId -InstanceId primary -LabName ([string]$manifest.name) -MemoryStartupBytes ([long]$target.memoryStartupMB * 1MB) -ProcessorCount ([int]$target.processorCount) -AutoStart off -SwitchName $network.Name
    $connection=[pscustomobject]@{schemaVersion=1;instances=@([pscustomobject]@{
        id='primary';provider='hyperv';vmName=$vm.VMName;vmId=$vm.VMId;autostart='off';workload='windows';baseKind='managed-run-acceptance-clone'
        imageArtifactId=[string]$source.Artifact.artifactId;sourceRunId=$SourceRunId.ToString();sourceParentCopyPath=$copy;sourceParentSha256=$hash
        sqlVersion=$null;sqlEdition=$null;host=$null;port=$null
        windowsActivationIntent=$activation;windowsActivationIntentSource='parameters'
        windowsProvisioning=[pscustomobject]@{state='COMPLETE';mode='managed-run-acceptance-clone';computerName=[string]$source.Lab.Instance.windowsProvisioning.computerName;imageState=[string]$source.Lab.Instance.windowsProvisioning.imageState;completedAt=Get-LabTimestamp}
        labNetwork=[pscustomobject]@{adapterBinding=$vm.NetworkBinding;name=$network.Name;intent=$network.Intent;subnet=$network.Subnet;prefixLength=$network.PrefixLength;hostAddress=$network.HostAddress;address=$lease.address;gateway=$network.Gateway;dnsServers=@($network.DnsServers);addressMode='static'}
    })}
    Save-LabSecret -Path $run.RunDir -Name guest-administrator-password -Secret $source.Password
    Write-LabArtifactJsonAtomic -Path (Join-Path $run.RunDir 'connection-info.json') -InputObject $connection
    foreach($state in @('SQL_READY','DATABASES_CREATED','RUNNING','STOPPED')){
        $null=Set-LabRunState -RunId $run.RunId -NewState $state -Reason 'Clone bereit fuer SQL-Slotinstallation.' -StateRoot $StateRoot
        Set-LabProviderSubRunState -RunId $run.RunId -Provider hyperv -NewState $state -Reason 'Clone bereit fuer SQL-Slotinstallation.' -StateRoot $StateRoot
    }
    $null=Set-HyperVLabSqlDeploymentPlan -RunId $run.RunId -SqlVersion 2025 -DeploymentMode adhoc-install -MediaEdition $MediaEdition -SqlMediaPath ([string]$media.RelativePath) -SqlFeatures SQLENGINE -MemoryStartupMB ([int]$target.memoryStartupMB) -ProcessorCount ([int]$target.processorCount) -StateRoot $StateRoot
    $owned=Get-HyperVManagedVM -VMName $vm.VMName -ExpectedRunId $run.RunId -ExpectedScopeId $run.ScopeId
    if([bool]$target.dynamicMemoryEnabled){
        Set-VMMemory -VM $owned.VM -DynamicMemoryEnabled $true -MinimumBytes ([long]$target.memoryMinimumMB*1MB) -StartupBytes ([long]$target.memoryStartupMB*1MB) -MaximumBytes ([long]$target.memoryMaximumMB*1MB) -ErrorAction Stop
    } else {
        Set-VMMemory -VM $owned.VM -DynamicMemoryEnabled $false -StartupBytes ([long]$target.memoryStartupMB*1MB) -ErrorAction Stop
    }
    $installed=Invoke-HyperVLabSqlSlotInstall -RunId $run.RunId -MediaRoot $MediaRoot -SqlSaPassword $SqlPassword -StateRoot $StateRoot
    if([string]$installed.State -ne 'SQL_SLOT_READY'){throw 'HYPERV_RESOURCE_SLOT_SQL_NOT_READY'}
    [pscustomobject]@{RunId=$run.RunId;State='RUNNING'}
}
