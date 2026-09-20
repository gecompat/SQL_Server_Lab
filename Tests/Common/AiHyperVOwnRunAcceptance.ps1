# Gemeinsame, offline prüfbare Grenzen der isolierten Hyper-V-KI-Abnahme.
function Get-OwnHyperVAiPreflight {
    param($Module,[string]$ArtifactId,[string]$StateRoot,[int]$LocalPort)
    & $Module {
        param($ArtifactId,$StateRoot,$LocalPort)
        $artifact=Get-HyperVImageArtifact -ArtifactId $ArtifactId -StateRoot $StateRoot -SkipIntegrityCheck
        if(-not $artifact -or [string]$artifact.artifactId -cne $ArtifactId -or $artifact.artifactState -cne 'SQL_PREPARED_SEALED' -or [string]$artifact.sql.version -cne '2025' -or [string]$artifact.sql.license.type -cne 'developer'){throw 'AI_HYPERV_PREPARED_ARTIFACT_INVALID'}
        if($artifact.license.type -eq 'evaluation' -and (-not $artifact.license.evaluationExpiresAt -or [datetimeoffset]$artifact.license.evaluationExpiresAt -le [datetimeoffset]::UtcNow.AddDays(1))){throw 'AI_HYPERV_PARENT_LICENSE_NOT_ELIGIBLE'}
        $path=[IO.Path]::GetFullPath([string]$artifact.Path)
        Assert-LabPortableContainerTransferPreflightNoReparsePath -Root ([IO.Path]::GetPathRoot($path)) -Path $path
        $item=Get-Item -LiteralPath $path -Force -ErrorAction Stop
        $hash=(Get-LabProgressFileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        if(-not $item.IsReadOnly -or $hash -cne [string]$artifact.sha256){throw 'AI_HYPERV_PARENT_INTEGRITY_INVALID'}
        $storage=Resolve-LabHyperVResourceBinding -ResourceId 'ai-hyperv-preflight' -ResourceClass Run
        $models=@(foreach($key in @('ollama-embeddinggemma-latest','ollama-qwen25-coder-7b-local')){
            $plan=New-LabAiEndpointPlan -ModelKey $key -EndpointRef ollama-local -Lane local -LocalPort $LocalPort
            Get-LabAiHostModelBinding -Plan $plan
        })
        [pscustomobject]@{Artifact=$artifact;ParentHash=$hash;ParentLength=$item.Length;ParentWriteTicks=$item.LastWriteTimeUtc.Ticks;StorageLocationId=$storage.LocationId;Models=$models}
    } $ArtifactId $StateRoot $LocalPort
}

function Get-OwnHyperVAiBinding {
    param($Module,[string]$RunId,[string]$StateRoot,[string]$OperationId,[string]$ArtifactId,[string]$ExpectedVmId,[switch]$RequireReady)
    & $Module {
        param($RunId,$StateRoot,$OperationId,$ArtifactId,$ExpectedVmId,$RequireReady)
        if(Test-LabAutomatedTestEnvironmentRun -RunId $RunId){throw 'AI_HYPERV_SHARED_GROUP_FORBIDDEN'}
        $run=Get-LabRunState -RunId $RunId -StateRoot $StateRoot
        if([string]$run.metadata.workflowOperationId -cne $OperationId -or [string]$run.metadata.imageArtifactId -cne $ArtifactId -or $run.metadata.workflowKind -cne 'hyperv-lab'){throw 'AI_HYPERV_RUN_OWNERSHIP_INVALID'}
        $directory=Join-Path (Join-Path $StateRoot 'runs') $RunId
        $connection=Get-Content -LiteralPath (Join-Path $directory 'connection-info.json') -Raw -Encoding utf8|ConvertFrom-Json -Depth 25
        $instances=@($connection.instances)
        if($instances.Count -ne 1 -or $instances[0].provider -cne 'hyperv' -or $instances[0].id -cne 'primary' -or $instances[0].imageArtifactId -cne $ArtifactId){throw 'AI_HYPERV_INSTANCE_BINDING_INVALID'}
        $instance=$instances[0]
        $managed=Get-HyperVManagedVM -VMName $instance.vmName -ExpectedRunId $RunId -ExpectedScopeId $run.scopeId
        if(-not $managed -or [string]$managed.VM.Id -cne [string]$instance.vmId -or ($ExpectedVmId -and [string]$managed.VM.Id -cne $ExpectedVmId)){throw 'AI_HYPERV_VM_ID_DRIFT'}
        if([string]$managed.Identity.instanceId -cne 'primary'){throw 'AI_HYPERV_VM_INSTANCE_DRIFT'}
        if($RequireReady -and ($run.state -ne 'RUNNING' -or $managed.VM.State -ne 'Running' -or [string]$instance.sqlVersion -notmatch '^2025(?:-|$)' -or -not $instance.host -or [int]$instance.port -lt 1)){throw 'AI_HYPERV_SQL_NOT_READY'}
        $resource=Read-LabHyperVResourceBinding -StateDirectory $directory
        if(-not $resource -or [string]$resource.ResourceId -cne $RunId){throw 'AI_HYPERV_RESOURCE_BINDING_INVALID'}
        $paths=@([string]$managed.Identity.childVhdxPath)+@($managed.Identity.additionalDrives|ForEach-Object{[string]$_.path})
        foreach($path in $paths){if(-not $path -or -not (Test-LabHyperVBoundPath -Binding $resource -Path $path).Valid){throw 'AI_HYPERV_CHILD_BINDING_INVALID'}}
        $attached=@(Get-VMHardDiskDrive -VMId ([guid]$managed.VM.Id) -ErrorAction Stop)
        if($attached.Count -ne $paths.Count -or @($attached|Where-Object{[IO.Path]::GetFullPath([string]$_.Path) -notin @($paths|ForEach-Object{[IO.Path]::GetFullPath($_)})}).Count){throw 'AI_HYPERV_DISK_ATTACHMENT_DRIFT'}
        $artifact=Get-HyperVImageArtifact -ArtifactId $ArtifactId -StateRoot $StateRoot -SkipIntegrityCheck
        $child=Get-VHD -Path ([string]$managed.Identity.childVhdxPath) -ErrorAction Stop
        if(-not $artifact -or $child.VhdType -ne 'Differencing' -or -not $child.ParentPath -or [IO.Path]::GetFullPath([string]$child.ParentPath) -cne [IO.Path]::GetFullPath([string]$artifact.Path)){throw 'AI_HYPERV_ACTUAL_PARENT_DRIFT'}
        [pscustomobject]@{RunId=$RunId;ScopeId=[string]$run.scopeId;VmId=[string]$managed.VM.Id;Instance=$instance;OwnedPaths=$paths;ResourceRoot=$resource.HyperVResourceRoot}
    } $RunId $StateRoot $OperationId $ArtifactId $ExpectedVmId ([bool]$RequireReady)
}

function Get-OwnHyperVAiBootTime {
    param([string]$VmId,[PSCredential]$Credential)
    $job=$null
    try{
        $job=Invoke-Command -VMId ([guid]$VmId) -Credential $Credential -AsJob -ScriptBlock {(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')}
        if(-not (Wait-Job -Job $job -Timeout 60) -or $job.State -ne 'Completed'){throw 'AI_HYPERV_BOOT_PROBE_FAILED'}
        $values=@(Receive-Job -Job $job -ErrorAction Stop)
        if($values.Count -ne 1){throw 'AI_HYPERV_BOOT_PROBE_INVALID'}
        ([datetimeoffset]::Parse([string]$values[0])).UtcDateTime.ToString('o')
    }finally{if($job){if($job.State -eq 'Running'){Stop-Job -Job $job -ErrorAction SilentlyContinue};Remove-Job -Job $job -Force -ErrorAction SilentlyContinue}}
}

function Assert-OwnHyperVAiNoResidue {
    param($Module,$Binding,[string]$StateRoot)
    & $Module {
        param($Binding,$StateRoot)
        if(@(Get-VM -ErrorAction Stop|Where-Object{[string]$_.Id -ceq $Binding.VmId}).Count){throw 'AI_HYPERV_VM_RESIDUE'}
        if(@(Get-HyperVLabVMs -RunId $Binding.RunId -ScopeId $Binding.ScopeId).Count){throw 'AI_HYPERV_SCOPE_VM_RESIDUE'}
        foreach($path in @($Binding.OwnedPaths)){if(Test-Path -LiteralPath $path){throw 'AI_HYPERV_CHILD_RESIDUE'}}
        $ipamPath=Get-LabHyperVIpamPath -StateRoot $StateRoot
        if(-not(Test-Path -LiteralPath $ipamPath -PathType Leaf)){throw 'AI_HYPERV_IPAM_UNVERIFIABLE'}
        $ipam=Get-Content -LiteralPath $ipamPath -Raw -Encoding utf8|ConvertFrom-Json -Depth 20
        if(@($ipam.leases|Where-Object{[string]$_.runId -ceq $Binding.RunId -and [string]$_.scopeId -ceq $Binding.ScopeId -and $_.state -eq 'ACTIVE'}).Count){throw 'AI_HYPERV_IPAM_RESIDUE'}
        $run=Get-LabRunState -RunId $Binding.RunId -StateRoot $StateRoot
        if($run.state -notin @('REMOVED','CLEANED_UP')){throw 'AI_HYPERV_RUN_NOT_REMOVED'}
    } $Binding $StateRoot
}
