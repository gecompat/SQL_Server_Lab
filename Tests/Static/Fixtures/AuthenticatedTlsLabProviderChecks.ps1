# Actual provider selection/origin/process construction with synthetic native
# observations only. No provider, SQL, CA, trust or filesystem mutation.
function Invoke-TlsLabProviderFixture {
    foreach($id in @(('sha256:'+('b'*64)),('b'*64))){
        Add-CheckResult 'Full native image ID normalizes to a canonical digest' ((ConvertTo-LabTlsImageId $id) -ceq ('sha256:'+('b'*64)))
    }
    foreach($id in @(('b'*12),'image:tag',('sha256:'+('b'*63)),('SHA256:'+('b'*64)),('B'*64))){
        Add-CheckResult 'Short, tagged or noncanonical image identity rejected' (Test-TlsLabReject {ConvertTo-LabTlsImageId $id})
    }
    Add-CheckResult 'Legacy 0.1 binding remains Docker-only' ((Get-LabTlsBindingProvider ([pscustomobject]@{ContractVersion='SqlServerLab.AuthenticatedTlsLab/0.1'})) -ceq 'docker')
    foreach($bad in @(
        @{ContractVersion='SqlServerLab.AuthenticatedTlsLab/0.1';Provider='podman'},
        @{ContractVersion='SqlServerLab.AuthenticatedTlsLab/0.2'},
        @{ContractVersion='SqlServerLab.AuthenticatedTlsLab/0.2';Provider='hyperv'},
        @{ContractVersion='unknown';Provider='docker'})){
        Add-CheckResult 'Unknown or rebound historical provider rejected' (Test-TlsLabReject {Get-LabTlsBindingProvider ([pscustomobject]$bad)})
    }
    $syntheticRoot=Join-Path ([IO.Path]::GetTempPath()) 'sql-lab-synthetic-provider-no-io'
    $run=[pscustomobject]@{scopeId='synthetic-scope';metadata=[pscustomobject]@{artifactRemovalRuntimeScopes=@()}}
    $connection=[pscustomobject]@{instances=@([pscustomobject]@{id='primary';provider='docker';containerId=('a'*64);port=14333;host='127.0.0.1'})}
    $observation=[pscustomobject]@{Id=('a'*64);Image=('sha256:'+('b'*64));Config=[pscustomobject]@{Image='mcr.microsoft.com/mssql/server:2025-CU9-ubuntu-24.04';Labels=@{
        'sql-server-lab.run-id'='synthetic-run';'sql-server-lab.scope-id'='synthetic-scope';'sql-server-lab.instance-id'='primary'}};
        State=[pscustomobject]@{Running=$true};NetworkSettings=[pscustomobject]@{Ports=@{'1433/tcp'=@([pscustomobject]@{HostPort='14333'})}}}
    function Assert-LabDiagnosticPath {param($Path) [IO.Path]::GetFullPath($Path)}
    function Assert-LabTlsCaPrivateAcl {param($Path,$UserSid,[switch]$Directory) $null=$Path,$UserSid,$Directory}
    $fixturePolicy=$null
    function Assert-LabTlsLabRoot {param($StateRoot) $null=$StateRoot;return $fixturePolicy}
    function Get-LabOwnedHostRunPolicy {param($StateRoot,$RunId) $null=$StateRoot,$RunId;return $fixturePolicy}
    function Get-LabTlsWindowsProcessFacts {[pscustomobject]@{UserSid='synthetic-sid'}}
    function Get-LabRunState {param($RunId,$StateRoot) $null=$RunId,$StateRoot;return $run}
    function Read-LabDiagnosticJson {param($Path) $null=$Path;return $connection}
    function Get-LabRunArtifactRuntimeIncarnation {param($Context,$StateRoot) $null=$Context,$StateRoot;return ('c'*64)}
    function Invoke-LabTlsContainer {
        param($Arguments,$InputText,$Budget) $null=$InputText
        if($Arguments.Count -ne 2 -or $Arguments[0] -cne 'inspect' -or $Budget.Provider -cne $connection.instances[0].provider){throw 'SYNTHETIC_UNEXPECTED_PROVIDER_EFFECT'}
        return $observation|ConvertTo-Json -Depth 8 -Compress
    }
    foreach($provider in @('docker','podman')){
        $record=[pscustomobject]@{ContractVersion='SqlServerLab.AuthenticatedTlsLab/0.2';Provider=$provider;RunId='synthetic-run';ScopeId='synthetic-scope';ContainerId=('a'*64);ImageId=('sha256:'+('b'*64));Port=14333}
        Add-CheckResult "Explicit 0.2 $provider binding accepted" ((Get-LabTlsBindingProvider $record) -ceq $provider)
        $budget=New-LabTlsRuntimeBudget -Provider $provider
        $budget.RuntimeContext=[pscustomobject]@{Provider=$provider;RuntimeScopeId='synthetic-runtime';RoutingKey=('d'*64);IncarnationKey=('c'*64);
            Invocation='synthetic-runtime.exe';Endpoint='synthetic-pinned-endpoint';IdentityPath='';StateRoot=$null}
        $start=New-LabTlsRuntimeProcessInfo @('inspect',('a'*64)) $budget
        $expectedPrefix=if($provider -ceq 'docker'){'--host'}else{'--remote'}
        Add-CheckResult "$provider process is pinned instead of using an ambient default" ($start.ArgumentList[0] -ceq $expectedPrefix -and $start.ArgumentList.Contains('synthetic-pinned-endpoint'))
        Add-CheckResult "$provider process removes all ambient routing selectors" (@($start.Environment.Keys|Where-Object {$_ -cin @('DOCKER_HOST','DOCKER_CONTEXT','DOCKER_CERT_PATH','CONTAINER_HOST','CONTAINER_CONNECTION','CONTAINER_SSHKEY','PODMAN_SSHKEY','PODMAN_CONNECTIONS_CONF','SSH_AUTH_SOCK')}).Count -eq 0)
        Add-CheckResult "$provider rejects a caller routing override before native start" (Test-TlsLabReject {New-LabTlsRuntimeProcessInfo @('inspect','--url=synthetic-other') $budget})
        $connection.instances[0].provider=$provider
        $origin=[pscustomobject]@{Provider=$provider;Status='AVAILABLE';OriginStatus='PINNED_CREATION';RuntimeScopeId='synthetic-runtime';RoutingKey=('d'*64);IncarnationKey=('c'*64)}
        $run.metadata.artifactRemovalRuntimeScopes=@($origin)
        $context=Get-LabTlsOwnedRuntimeContext $record.RunId $syntheticRoot $budget
        Add-CheckResult "$provider owner check preserves exact provider/run/scope/container binding" ($context.Provider -ceq $provider -and $context.ContainerId -ceq $record.ContainerId)
        foreach($field in @('Provider','RoutingKey','IncarnationKey','RuntimeScopeId','OriginStatus')){
            $saved=$origin.$field
            try{
                $origin.$field='synthetic-other';$rejected=$false
                try{$null=Get-LabTlsOwnedRuntimeContext $record.RunId $syntheticRoot $budget}catch{$rejected=$_.Exception.Message -ceq 'TLS_LAB_RUNTIME_ORIGIN_CHANGED'}
                Add-CheckResult "$provider rejects original-runtime $field drift at the origin guard" $rejected
            }finally{$origin.$field=$saved}
        }
        $other=if($provider -ceq 'docker'){'podman'}else{'docker'}
        $connection.instances[0].provider=$other
        Add-CheckResult "$provider rejects a connection record bound to $other" (Test-TlsLabReject {Assert-LabTlsOwnContainer $record $syntheticRoot $budget})
        $connection.instances[0].provider=$provider
        Add-CheckResult "$provider cannot borrow the other provider's operation budget" (Test-TlsLabReject {Assert-LabTlsOwnContainer $record $syntheticRoot (New-LabTlsRuntimeBudget -Provider $other)})
        $fixturePolicy=[pscustomobject]@{PolicyId='synthetic-policy';RuntimePins=@([pscustomobject]@{Provider=$provider;Invocation='synthetic-runtime.exe';Endpoint='synthetic-pinned-endpoint';IdentityPath='';IdentitySha256=''})}
        $budget.RuntimeContext|Add-Member -NotePropertyName IdentitySha256 -NotePropertyValue '' -Force
        $observation.Config.Image=$record.ImageId
        $context=Assert-LabTlsOwnContainer $record $syntheticRoot $budget
        Add-CheckResult "$provider 0.2 target requires the bound policy and run custody lane" ($context.PolicyBound -and $context.Provider -ceq $provider)
        foreach($configImage in @('mcr.microsoft.com/mssql/server:2025-CU9-ubuntu-24.04',('sha256:'+('f'*64)))){
            try{$observation.Config.Image=$configImage;Add-CheckResult "$provider owned target rejects a tag or another digest in actual launch configuration" (Test-TlsLabReject {Assert-LabTlsOwnContainer $record $syntheticRoot $budget})}finally{$observation.Config.Image=$record.ImageId}
        }
        $observation.Config.Image='b'*64
        Add-CheckResult "$provider full unprefixed launch ID retains the same immutable target" ((Assert-LabTlsOwnContainer $record $syntheticRoot $budget).ContainerId -ceq $record.ContainerId)
        $observation.Config.Image=$record.ImageId
        $fixturePolicy.RuntimePins[0].Endpoint='synthetic-other-endpoint'
        Add-CheckResult "$provider rejects durable policy endpoint drift" (Test-TlsLabReject {Assert-LabTlsOwnContainer $record $syntheticRoot $budget})
        $fixturePolicy=$null
        Add-CheckResult "$provider 0.2 cannot fall back to the historical non-policy lane" (Test-TlsLabReject {Assert-LabTlsOwnContainer $record $syntheticRoot $budget})
        if($provider -ceq 'docker'){
            $legacy=[pscustomobject]@{ContractVersion='SqlServerLab.AuthenticatedTlsLab/0.1';RunId=$record.RunId;ScopeId=$record.ScopeId;ContainerId=$record.ContainerId;ImageId=$record.ImageId;Port=$record.Port}
            $observation.Config.Image='mcr.microsoft.com/mssql/server:2025-CU9-ubuntu-24.04'
            Add-CheckResult 'Legacy 0.1 Docker target retains the exact launch tag' ((Assert-LabTlsOwnContainer $legacy $syntheticRoot $budget).Provider -ceq 'docker')
            $observation.Config.Image=$record.ImageId
            Add-CheckResult 'Legacy 0.1 Docker target cannot silently acquire the digest launch contract' (Test-TlsLabReject {Assert-LabTlsOwnContainer $legacy $syntheticRoot $budget})
        }
    }
}
Invoke-TlsLabProviderFixture
