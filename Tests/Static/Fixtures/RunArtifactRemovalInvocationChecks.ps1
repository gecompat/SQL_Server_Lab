# Exercise the actual incarnation/native/process chain, replacing only process
# start and discovery. Fixture leaves are never executed; no provider is called.
& {
    $fixture=Join-Path $Root 'invocation-fixture'
    $null=New-Item -ItemType Directory -Path $fixture -Force
    $original=Join-Path $fixture 'original.exe';$shadow=Join-Path $fixture 'shadow.exe'
    [IO.File]::WriteAllText($original,'synthetic original executable marker')
    [IO.File]::WriteAllText($shadow,'synthetic PATH shadow marker')
    $saved=@{}
    foreach($name in @('Get-LabHostToolInvocation','Invoke-LabOwnedHostNativeProcess','Get-LabOwnedHostPolicy','Invoke-LabOwnedHostPinnedCommand')){
        $saved[$name]=(Get-Command $name).ScriptBlock
    }
    $script:invocationDiscovery=0;$script:invocationDispatch=0;$script:ownedInvocationDispatch=0
    try{
        Set-Item Function:script:Get-LabHostToolInvocation -Value {param($Name) $script:invocationDiscovery++;return $shadow}
        Set-Item Function:script:Invoke-LabOwnedHostNativeProcess -Value {
            param($StartInfo,$TimeoutSeconds)
            $script:invocationDispatch++;$script:observedInvocation=$StartInfo.FileName
            $script:invocationArguments=@($StartInfo.ArgumentList)
            $output=if($StartInfo.ArgumentList.Contains('machine')){'[{"Name":"synthetic-machine","Created":"synthetic-created","ConfigDir":"synthetic-config"}]'}else{'"synthetic-engine"'}
            [pscustomobject]@{ExitCode=0;Stdout=$output;Stderr=''}
        }
        Set-Item Function:script:Get-LabOwnedHostPolicy -Value {param($StateRoot,[switch]$Required)
            [pscustomobject]@{RuntimePins=@([pscustomobject]@{Provider='docker';Invocation=$script:policyInvocation})}
        }
        Set-Item Function:script:Invoke-LabOwnedHostPinnedCommand -Value {param($StateRoot,$Provider,$Arguments,$TimeoutSeconds)
            $script:ownedInvocationDispatch++;[pscustomobject]@{ExitCode=0;Stdout='"synthetic-engine"';Stderr=''}
        }
        foreach($provider in @('docker','podman')){
            $context=[pscustomobject]@{Provider=$provider;Invocation=$original;Endpoint='synthetic-endpoint';IdentityPath='';StateRoot=$null;MachineName='synthetic-machine'}
            $before=$script:invocationDiscovery
            $incarnation=Get-LabRunArtifactRuntimeIncarnation -Context $context -StateRoot $fixture -Invocation $original
            $expected=if($provider -ceq 'docker'){Get-LabRetainedStoreHash @('docker','synthetic-engine')}else{Get-LabRetainedStoreHash @('podman','synthetic-machine','synthetic-created','synthetic-config')}
            Assert-RunArtifact ($incarnation -ceq $expected -and $script:observedInvocation -ceq $original -and $script:invocationDiscovery -eq $before) "$provider incarnation retains explicit executable without discovery"
            $prefix=if($provider -ceq 'docker'){'--host'}else{'--remote'}
            Assert-RunArtifact ($script:invocationArguments[0] -ceq $prefix -and $script:invocationArguments.Contains('synthetic-endpoint')) "$provider explicit executable retains pinned route"
            $null=Get-LabRunArtifactRuntimeIncarnation -Context $context -StateRoot $fixture
            Assert-RunArtifact ($script:observedInvocation -ceq $shadow -and $script:invocationDiscovery -eq ($before+1)) "$provider omitted invocation preserves legacy discovery instead of trusting Context.Invocation"
            foreach($invalid in @($null,'','original.exe',(Join-Path $fixture 'missing.exe'),$fixture)){
                $beforeDispatch=$script:invocationDispatch;$beforeDiscovery=$script:invocationDiscovery;$rejected=$false
                try{$null=Get-LabRunArtifactRuntimeIncarnation -Context $context -StateRoot $fixture -Invocation $invalid}catch{$rejected=$_.Exception.Message -ceq 'RUN_ARTIFACT_INVOCATION_INVALID'}
                Assert-RunArtifact ($rejected -and $script:invocationDispatch -eq $beforeDispatch -and $script:invocationDiscovery -eq $beforeDiscovery) "$provider invalid explicit invocation rejects before discovery or dispatch"
            }
        }
        if($IsWindows){
            $junction=Join-Path $fixture 'reparse';$null=New-Item -ItemType Junction -Path $junction -Target $fixture
            try{
                $beforeDispatch=$script:invocationDispatch;$rejected=$false
                try{$null=Invoke-LabRunArtifactNative -Context $context -Arguments @('info') -Invocation (Join-Path $junction 'original.exe')}catch{$rejected=$_.Exception.Message -ceq 'RUN_ARTIFACT_REPARSE_PATH'}
                Assert-RunArtifact ($rejected -and $script:invocationDispatch -eq $beforeDispatch) 'Explicit executable rejects a reparse ancestor before dispatch'
            }finally{[IO.Directory]::Delete($junction)}
        }
        $context=[pscustomobject]@{Provider='docker';Endpoint='synthetic-endpoint';IdentityPath='';StateRoot=$fixture}
        $script:policyInvocation=$original
        $null=Invoke-LabRunArtifactNative -Context $context -Arguments @('info') -Invocation $original
        Assert-RunArtifact ($script:ownedInvocationDispatch -eq 1) 'Owned explicit invocation requires and accepts the current policy pin'
        $script:policyInvocation=$shadow;$rejected=$false
        try{$null=Invoke-LabRunArtifactNative -Context $context -Arguments @('info') -Invocation $original}catch{$rejected=$_.Exception.Message -ceq 'RUN_ARTIFACT_INVOCATION_POLICY_CHANGED'}
        Assert-RunArtifact ($rejected -and $script:ownedInvocationDispatch -eq 1) 'Changed owned policy pin rejects before command dispatch'
        $null=Invoke-LabRunArtifactNative -Context $context -Arguments @('info')
        Assert-RunArtifact ($script:ownedInvocationDispatch -eq 2) 'Owned omitted invocation keeps its existing pinned command boundary'
    }finally{
        foreach($name in $saved.Keys){Set-Item ("Function:script:"+$name) -Value $saved[$name]}
    }
}
