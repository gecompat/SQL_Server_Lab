function Assert-LabTlsLinuxPowerShellPackage {
    param([string]$Path)
    if(-not$Path-or-not(Test-Path -LiteralPath $Path -PathType Leaf)){throw 'TLS_LINUX_PINNED_PACKAGE_REQUIRED'}
    $file=Get-Item -LiteralPath $Path -Force
    if($file.Attributes-band[IO.FileAttributes]::ReparsePoint-or$file.Length-ne75876271-or
        (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash-cne'DDBC4A2D113BBD46D283CFEDCBCD117A70CAEFD7673F41F2B4E0000BADF103BC'){
        throw 'TLS_LINUX_PINNED_PACKAGE_INVALID'
    }
}

function Get-LabTlsLinuxClientIntent {
    param([object]$Bound)
    $r=$Bound.Record;$root=$Bound.StateRoot
    if($r.ContractVersion-cne'SqlServerLab.AuthenticatedTlsLab/0.4'){throw 'TLS_LINUX_EXPLICIT_SELECTION_REQUIRED'}
    $sid=$Bound.Authority.Native.UserSid
    $bytes=Read-LabTlsCaPrivateFile (Join-Path $root 'linux-client-intent.json') $sid 32768
    $intent=Read-LabTlsBoundJson $bytes @('ContractVersion','ClientRef','ParentBindingSha256','Intent')
    if($intent.ContractVersion-cne'SqlServerLab.LinuxClientIntent/0.1'-or
        $intent.ClientRef-cne$r.LinuxClientRef-or$intent.ParentBindingSha256-cne(Get-LabTlsCaByteDigest $Bound.Bytes)-or
        $intent.Intent.RunId-cne$r.RunId-or$intent.Intent.ScopeId-cne$r.ScopeId-or
        $intent.Intent.Provider-cne$r.Provider-or$intent.Intent.InstanceId-cne'tls-linux-client'){throw 'TLS_LINUX_CLIENT_INTENT_CHANGED'}
    # The ordinary owner gateway rechecks the immutable original intention.
    return $intent.Intent
}

function Get-LabTlsLinuxClientObservation {
    param([object]$Bound,[object]$Budget,[object]$Intent,[string]$ContainerId)
    $r=$Bound.Record;$root=$Bound.StateRoot
    $sql=Assert-LabTlsSqlCertificateBinding $r $root $Budget
    $client=Get-LabOwnedHostContainerObservation $root $Intent $ContainerId
    Assert-LabOwnedHostContainerEffect -StateRoot $root -RunId $r.RunId -Provider $r.Provider -ContainerId $client.Id
    $binds=$client.HostConfig.Binds;$ports=$client.HostConfig.PortBindings
    if($client.State.Running-isnot[bool]-or-not$client.State.Running-or
        $client.Config.User-cne'10001:0'-or$client.HostConfig.ReadonlyRootfs-isnot[bool]-or-not$client.HostConfig.ReadonlyRootfs-or
        $client.HostConfig.Privileged-isnot[bool]-or$client.HostConfig.Privileged-or
        $client.HostConfig.NetworkMode-cne('container:'+$r.ContainerId)-or
        ($null-ne$binds-and@($binds).Count)-or($null-ne$ports-and@($ports.PSObject.Properties).Count)-or
        @($client.HostConfig.SecurityOpt)-cnotcontains'no-new-privileges'){throw 'TLS_LINUX_CLIENT_ISOLATION_CHANGED'}
    $program=Get-LabTlsLinuxObservationProgram
    $native=Invoke-LabTlsLinuxObservedProgram $Bound $Budget $client.Id $program $null
    $facts=Read-LabTlsBoundJson ([Text.Encoding]::UTF8.GetBytes($native)) @('NetNamespace','Trust','Binaries')
    $ns=Invoke-LabTlsContainer @('exec',$r.ContainerId,'/usr/bin/readlink','/proc/self/ns/net') -Budget $Budget -OperationStage 'linux-client-namespace-check'
    if($ns-cne$facts.NetNamespace-or$facts.Trust.CertificateSha256-cne$Bound.Authority.Authority.CertificateSha256){throw 'TLS_LINUX_NAMESPACE_OR_TRUST_CHANGED'}
    return [pscustomobject]@{Inspect=$client;Facts=$facts}
}

function Initialize-LabTlsLinuxClient {
    param([object]$Bound,[string]$Package,[object]$Budget)
    Assert-LabTlsLinuxPowerShellPackage $Package
    $r=$Bound.Record;$root=$Bound.StateRoot;$sid=$Bound.Authority.Native.UserSid
    if($r.ContractVersion-cne'SqlServerLab.AuthenticatedTlsLab/0.4'){throw 'TLS_LINUX_EXPLICIT_SELECTION_REQUIRED'}
    if(Test-Path -LiteralPath (Join-Path $root 'linux-client-intent.json')){throw 'TLS_LINUX_CLIENT_ALREADY_ALLOCATED'}
    $null=Assert-LabTlsSqlCertificateBinding $r $root $Budget
    $image=Get-LabOwnedHostImageObservation -StateRoot $root -Provider $r.Provider -Image 'mcr.microsoft.com/mssql/server:2025-CU9-ubuntu-24.04'
    if(-not$image){throw 'TLS_LINUX_STOCK_CLIENT_IMAGE_REQUIRED'}
    $intent=New-LabOwnedHostContainerIntent -StateRoot $root -RunId $r.RunId -ScopeId $r.ScopeId -InstanceId tls-linux-client -Provider $r.Provider -ContainerName ('tls-client-'+[guid]::NewGuid().ToString('N'))
    $journal=[pscustomobject]@{ContractVersion='SqlServerLab.LinuxClientIntent/0.1';ClientRef=$r.LinuxClientRef;ParentBindingSha256=(Get-LabTlsCaByteDigest $Bound.Bytes);Intent=$intent}
    # Journal and owner intent are durable before the first client effect.
    Write-LabTlsCaPrivateFile (Join-Path $root 'linux-client-intent.json') $sid (ConvertTo-LabTlsRegistryWriterBytes $journal)
    $id=Invoke-LabTlsContainer (Get-LabOwnedHostTlsLinuxClientArguments $intent $r.ContainerId $image.Id) -Budget $Budget -OperationStage 'linux-client-create'
    $receipt=Register-LabOwnedHostContainer $root $intent $id.Trim()
    $cid=$receipt.ContainerId
    $null=Invoke-LabTlsContainer @('start',$cid) -Budget $Budget -OperationStage 'linux-client-start'
    $null=Invoke-LabTlsContainer @('exec','--user','10001:0',$cid,'/bin/sh','-c','set -eu; umask 077; mkdir /opt/tls-client/pwsh /opt/tls-client/empty') -Budget $Budget -OperationStage 'linux-client-layout'
    $null=Invoke-LabTlsLinuxFileTransfer -Budget $Budget -Arguments @('exec','-i','--user','10001:0',$cid,'/bin/tar','-xz','--no-same-owner','-C','/opt/tls-client/pwsh') -InputPath $Package -ExpectedSha256 'ddbc4a2d113bbd46d283cfedcbcd117a70caefd7673f41f2b4e0000badf103bc' -ExpectedBytes 75876271
    $ca=Get-LabTlsCaCandidateBinding $r.DataRoot $r.ControllerId $r.LocationId $Bound.Authority.Authority.CandidateId
    $pem=[Security.Cryptography.PemEncoding]::WriteString('CERTIFICATE',$ca.Der)+[char]10
    $null=Invoke-LabTlsContainer @('exec','-i','--user','10001:0',$cid,'/bin/sh','-c','set -eu; umask 077; test ! -e /opt/tls-client/ca.pem; cat > /opt/tls-client/ca.pem') $pem -Budget $Budget -OperationStage 'linux-client-trust-write'
    $observation=Get-LabTlsLinuxClientObservation $Bound $Budget $intent $cid
    $i=$observation.Inspect;$f=$observation.Facts
    $record=[pscustomobject][ordered]@{
        ContractVersion='SqlServerLab.AuthenticatedTlsLinuxClient/0.1';ClientRef=$r.LinuxClientRef;Generation=1;Status='REGISTERED_NOT_QUALIFIED';CreatedAtUtc=[DateTimeOffset]::UtcNow.ToString('o')
        Parent=[pscustomobject]@{AuditId=$r.AuditId;ControllerId=$r.ControllerId;LocationId=$r.LocationId;AuthorityRef=$r.AuthorityRef;ParentControllerClientRef=$r.ClientRef
            RegistrySha256=$r.RegistrySha256;RuntimeBindingSha256=(Get-LabTlsCaByteDigest (ConvertTo-LabTlsRegistryWriterBytes $r.RuntimeBinding))
            RunId=$r.RunId;ScopeId=$r.ScopeId;InstanceId=$r.InstanceId;Provider=$r.Provider;SqlContainerId=$r.ContainerId;SqlImageId=$r.ImageId;SqlStartedAt=$r.StartedAt}
        Client=[pscustomobject]@{ContainerId=$cid;ImageId=(ConvertTo-LabTlsImageId $i.Image);StartedAt=$i.State.StartedAt;IntentId=$intent.IntentId
            Uid=10001;Gid=0;NetworkMode=('container:'+$r.ContainerId);NetNamespace=$f.NetNamespace;ReadOnlyRoot=$true;NoNewPrivileges=$true;Capabilities='NONE'}
        Endpoint=[pscustomobject]@{Kind='DNS';Host='localhost';Port=1433;Namespace=$f.NetNamespace};Trust=$f.Trust;Binaries=$f.Binaries
    }
    $bytes=ConvertTo-LabTlsRegistryWriterBytes $record
    $null=Read-LabTlsLinuxClientContextRecord $bytes
    Write-LabTlsCaPrivateFile (Join-Path $root 'linux-client-context.json') $sid $bytes
}

function Get-LabTlsLinuxClientBinding {
    param([object]$Bound,[object]$Budget)
    $r=$Bound.Record;$root=$Bound.StateRoot
    $intent=Get-LabTlsLinuxClientIntent $Bound
    $bytes=Read-LabTlsCaPrivateFile (Join-Path $root 'linux-client-context.json') $Bound.Authority.Native.UserSid 32768
    $metadata=Read-LabTlsLinuxClientContextRecord $bytes;$c=$metadata.Record
    $p=$c.Parent
    foreach($name in @('AuditId','ControllerId','LocationId','AuthorityRef','RegistrySha256','RunId','ScopeId','InstanceId','Provider')){
        if($p.$name-cne$r.$name){throw 'TLS_LINUX_PARENT_CHANGED'}
    }
    if($c.ClientRef-cne$r.LinuxClientRef-or$p.ParentControllerClientRef-cne$r.ClientRef-or
        $p.SqlContainerId-cne$r.ContainerId-or$p.SqlImageId-cne$r.ImageId-or$p.SqlStartedAt-cne$r.StartedAt-or
        $p.RuntimeBindingSha256-cne(Get-LabTlsCaByteDigest (ConvertTo-LabTlsRegistryWriterBytes $r.RuntimeBinding))-or
        $c.Client.IntentId-cne$intent.IntentId){throw 'TLS_LINUX_PARENT_CHANGED'}
    $fresh=Get-LabTlsLinuxClientObservation $Bound $Budget $intent $c.Client.ContainerId
    if((ConvertTo-LabTlsImageId $fresh.Inspect.Image)-cne$c.Client.ImageId-or
        $fresh.Inspect.State.StartedAt-cne$c.Client.StartedAt-or$fresh.Facts.NetNamespace-cne$c.Client.NetNamespace){throw 'TLS_LINUX_CLIENT_CHANGED'}
    foreach($name in @('Trust','Binaries')){Assert-LabTlsLinuxObservedFields $c.$name $fresh.Facts.$name}
    return [pscustomobject]@{Record=$c;Bytes=$bytes;Sha256=$metadata.Sha256;Intent=$intent}
}

function Assert-LabTlsLinuxObservedFields {
    param([object]$Expected,[object]$Actual)
    if($Expected-is[pscustomobject]){
        if($Actual-isnot[pscustomobject]-or@($Expected.PSObject.Properties).Count-ne@($Actual.PSObject.Properties).Count){throw 'TLS_LINUX_CONTEXT_CHANGED'}
        foreach($p in $Expected.PSObject.Properties){
            if(-not$Actual.PSObject.Properties[$p.Name]){throw 'TLS_LINUX_CONTEXT_CHANGED'}
            Assert-LabTlsLinuxObservedFields $p.Value $Actual.($p.Name)
        }
    }elseif($Expected-is[string]){
        if($Actual-isnot[string]-or$Actual-cne$Expected){throw 'TLS_LINUX_CONTEXT_CHANGED'}
    }elseif($Expected-is[bool]){
        if($Actual-isnot[bool]-or$Actual-ne$Expected){throw 'TLS_LINUX_CONTEXT_CHANGED'}
    }elseif(($Expected-is[int]-or$Expected-is[long])-and($Actual-is[int]-or$Actual-is[long])){
        if($Actual-ne$Expected){throw 'TLS_LINUX_CONTEXT_CHANGED'}
    }else{throw 'TLS_LINUX_CONTEXT_CHANGED'}
}

function Remove-LabTlsLinuxClientIfPresent {
    param([string]$StateRoot,[string]$RunId)
    $path=Join-Path $StateRoot 'linux-client-intent.json'
    if(-not(Test-Path -LiteralPath $path)){
        foreach($name in @('linux-client-context.json','linux-client-execution.json','tls-linux-process-recovery.json')){
            if(Test-Path -LiteralPath (Join-Path $StateRoot $name)){throw 'TLS_LINUX_MISSING_INTENT_RECOVERY_REQUIRED'}
        }
        $parent=Join-Path $StateRoot 'authenticated-tls-lab.json'
        if(Test-Path -LiteralPath $parent){
            $r=Read-LabTlsLabRecord (Read-LabTlsCaPrivateFile $parent (Get-LabTlsWindowsProcessFacts).UserSid 32768)
            if($r.ContractVersion-ceq'SqlServerLab.AuthenticatedTlsLab/0.4'){throw 'TLS_LINUX_MISSING_INTENT_RECOVERY_REQUIRED'}
        }
        return
    }
    $lease=Enter-LabTlsLinuxOperation $StateRoot -Cleanup
    try{
        $j=Read-LabTlsBoundJson (Read-LabTlsCaPrivateFile $path $lease.Sid 32768) @('ContractVersion','ClientRef','ParentBindingSha256','Intent')
        if($j.ContractVersion-cne'SqlServerLab.LinuxClientIntent/0.1'-or$j.Intent.RunId-cne$RunId-or$j.Intent.InstanceId-cne'tls-linux-client'){throw 'TLS_LINUX_CLEANUP_BINDING_INVALID'}
        $run=Get-LabRunState -RunId $RunId -StateRoot $StateRoot
        if($run.scopeId-cne$j.Intent.ScopeId){throw 'TLS_LINUX_CLEANUP_BINDING_INVALID'}
        Remove-LabOwnedHostFailedContainer -StateRoot $StateRoot -Intent $j.Intent
        $left=Invoke-LabOwnedHostPinnedCommand -StateRoot $StateRoot -Provider $j.Intent.Provider -Arguments @('ps','-aq','--filter',('label=sql-server-lab.owned-host-intent-id='+$j.Intent.IntentId))
        if($left.ExitCode-ne0-or$left.Stdout.Trim()){throw 'TLS_LINUX_CLEANUP_RECOVERY_REQUIRED'}
        $marker=Join-Path $StateRoot 'linux-client-execution.json'
        if(Test-Path -LiteralPath $marker){Remove-Item -LiteralPath $marker -Force -ErrorAction Stop}
    }finally{Exit-LabTlsLinuxOperation $lease}
    # Keep immutable intention/context as usage evidence; run REMOVED is the
    # terminal lifecycle fact. No authority retirement is implied.
}
