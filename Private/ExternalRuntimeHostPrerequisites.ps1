# Opt-in composition of the existing typed native-host reducer, no new registry.
function ConvertTo-LabExternalRuntimePrerequisiteObservation {
    param([string]$Provider,$Value)
    if($Value -isnot [pscustomobject] -or $Provider -cnotin @('docker','podman')){throw 'PROVIDER_RESPONSE_INVALID'}
    $allowed=if($Provider -ceq 'docker'){@('OperatingSystem','CgroupVersion','SecurityOptions','MemoryLimit','PidsLimit','MemTotal','NCPU')}
        else{@('OperatingSystem','CgroupVersion','CgroupsVersion','Rootless','Controllers','MemTotal','Cpus')}
    if(@($Value.PSObject.Properties.Name|Where-Object {$_ -cnotin $allowed}).Count){throw 'PROVIDER_RESPONSE_INVALID'}
    $base=if($Provider -ceq 'docker'){
        [pscustomobject]@{OperatingSystem=$Value.OperatingSystem;CgroupVersion=$Value.CgroupVersion;SecurityOptions=$Value.SecurityOptions}
    }else{
        $primary=$Value.PSObject.Properties['CgroupVersion'];$alias=$Value.PSObject.Properties['CgroupsVersion']
        $selected=if($primary){$primary.Value}elseif($alias){$alias.Value}else{$null}
        $podmanFacts=ConvertTo-LabExternalRuntimeHostFacts -Provider podman -Value ([pscustomobject]@{
            OperatingSystem=$Value.OperatingSystem;CgroupVersion=$selected;Rootless=$Value.Rootless})
        if($primary -and $alias){
            $aliasFacts=ConvertTo-LabExternalRuntimeHostFacts -Provider podman -Value ([pscustomobject]@{
                OperatingSystem=$Value.OperatingSystem;CgroupVersion=$alias.Value;Rootless=$Value.Rootless})
            if($podmanFacts.CgroupVersion -cne $aliasFacts.CgroupVersion){throw 'PROVIDER_RESPONSE_INVALID'}
        }
        [pscustomobject]@{OperatingSystem=$podmanFacts.OperatingSystem;CgroupVersion=$podmanFacts.CgroupVersion;Rootless=$podmanFacts.Rootless}
    }
    $facts=ConvertTo-LabExternalRuntimeHostFacts -Provider $Provider -Value $base
    $optional=@{};foreach($name in $allowed){$property=$Value.PSObject.Properties[$name];$optional[$name]=if($property){$property.Value}else{$null}}
    $runtime=if($Provider -ceq 'docker'){
        [pscustomobject]@{OSType=$facts.OperatingSystem;CgroupVersion=$facts.CgroupVersion;
            SecurityOptions=@($(if($facts.Rootless){'name=rootless'}));MemoryLimit=$optional.MemoryLimit;PidsLimit=$optional.PidsLimit;
            MemTotal=$optional.MemTotal;NCPU=$optional.NCPU}
    }else{
        [pscustomobject]@{host=[pscustomobject]@{os=$facts.OperatingSystem;cgroupVersion=$facts.CgroupVersion;
            security=[pscustomobject]@{rootless=$facts.Rootless};cgroupControllers=$optional.Controllers;memTotal=$optional.MemTotal;cpus=$optional.Cpus}}
    }
    [pscustomobject]@{Facts=$facts;RuntimeInfo=$runtime}
}

function Add-LabExternalRuntimeHostPrerequisites {
    param($Decision,[string]$ResourceProfile,$Requirements,$HostObservation)
    $status='NOT_CHECKED';$reasons=@('READINESS_NOT_REQUESTED');$controllers=$null;$capacity=$null
    $shared=$null;$observed=$null
    # The same reducer used by the native Plan is loaded only for this opt-in.
    . (Join-Path $script:ModuleRoot 'Tools/Common/NativeLinuxContainerHost.ps1')
    $shared=Get-NativeLinuxSharedKernelEvidence
    if($Decision.CatalogDecision.Status -cne 'DECLARED_SUPPORTED'){
        $status='CATALOG_BLOCKED';$reasons=@('CATALOG_BLOCKED')
    }elseif($null -ne $HostObservation){
        $status='UNAVAILABLE';$reasons=@($Decision.CurrentReadiness.ReasonCode)
        if($HostObservation.Status -ceq 'OBSERVED' -and $HostObservation.PSObject.Properties['PrerequisiteRuntimeInfo']){
            $native=Get-NativeLinuxContainerHostDecision -Provider $Decision.Provider -RuntimeInfo $HostObservation.PrerequisiteRuntimeInfo `
                -ToolAvailable $true -RuntimeReachable $true -RequiredCgroupVersion $Decision.CurrentReadiness.RequiredCgroupVersion `
                -SqlVersion $Decision.Identity.SqlVersion -ResourceRequirements $Requirements
            $status=$native.Status;$reasons=@($native.Reasons);$controllers=$native.Controllers;$capacity=$native.ResourceCapacity;$shared=$native.SharedKernel
            $observed=[DateTime]::UtcNow.ToString('o')
            if($status -ceq 'COMPATIBLE'){$Decision.CurrentReadiness.Status='READY';$Decision.CurrentReadiness.ReasonCode='NONE'}
            else{$Decision.CurrentReadiness.Status='BLOCKED';$Decision.CurrentReadiness.ReasonCode=$reasons[0]}
        }elseif($HostObservation.Status -ceq 'OBSERVED'){
            $reasons=@('PROVIDER_RESPONSE_INVALID');$Decision.CurrentReadiness.Status='BLOCKED';$Decision.CurrentReadiness.ReasonCode='PROVIDER_RESPONSE_INVALID'
        }
    }
    $Decision.Contract.Version='1.2'
    $Decision.CurrentReadiness|Add-Member -NotePropertyName Scope -NotePropertyValue 'OS_CGROUP_ROOTFUL_CONTROLLERS_PROFILE_TOTAL_CAPACITY'
    $Decision|Add-Member -NotePropertyName HostPrerequisites -NotePropertyValue ([pscustomobject]@{
        Status=$status;ReasonCodes=$reasons;ResourceProfile=$ResourceProfile;Controllers=$controllers;ResourceCapacity=$capacity;
        SharedKernel=$shared;ObservedAtUtc=$observed;FullLaunchReadiness='INCOMPLETE';ExecutionSupported=$false;MutationAllowed=$false;
        EvidenceBoundary='CURRENT_PROVIDER_ADVERTISEMENT_NOT_SQL_OR_FREE_RESOURCE_PROOF'
    })
    if([Text.Encoding]::UTF8.GetByteCount(($Decision|ConvertTo-Json -Depth 30 -Compress)) -gt 262144){throw 'EXTERNAL_RUNTIME_CAPABILITY_OUTPUT_LIMIT'}
    $Decision
}
