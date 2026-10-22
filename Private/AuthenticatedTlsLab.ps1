#Requires -Version 7.2
# Windows current user -> own explicitly selected, closed SQL/CU profiles.
function Get-LabTlsSqlProfile {
    param([string]$Version)
    switch -CaseSensitive ($Version){
        '2025-CU9' {$major='2025';$patch='cu9';$build='17.0.5005.3';$tag='2025-CU9-ubuntu-24.04'}
        '2022-CU27' {$major='2022';$patch='cu27';$build='16.0.4295.3';$tag='2022-CU27-ubuntu-22.04'}
        '2019-CU32' {$major='2019';$patch='cu32';$build='15.0.4430.1';$tag='2019-CU32-ubuntu-20.04'}
        default {throw 'TLS_LAB_SQL_PROFILE_UNSUPPORTED'}
    }
    return [pscustomobject]@{Version=$Version;SqlVersion=$major;Patch=$patch;SqlBuild=$build;ImageTag=$tag;Image=('mcr.microsoft.com/mssql/server:'+$tag);ExportKey=('LINUX_SQL'+$major+'_'+$patch.ToUpperInvariant()+'_TLS')}
}

function Assert-LabTlsSqlCatalogProfile {
    param([object]$Profile)
    # The closed qualification profile must still match the project catalog.
    # A future catalog edit never silently authorizes another build or image.
    $catalog=Get-Content -LiteralPath (Join-Path $script:ModuleRoot 'Catalogs/sql-server-versions.json') -Raw|ConvertFrom-Json -Depth 20
    $versions=@($catalog.versions|Where-Object id -CEQ $Profile.SqlVersion)
    $rows=@($versions.docker.builds|Where-Object tag -CEQ $Profile.ImageTag)
    if($versions.Count -ne 1 -or $rows.Count -ne 1 -or $rows[0].build -cne $Profile.SqlBuild -or $rows[0].cu.ToLowerInvariant() -cne $Profile.Patch){throw 'TLS_LAB_SQL_CATALOG_CHANGED'}
}

function Get-LabTlsBindingSqlProfile {
    param([object]$Record)
    if($Record.ContractVersion -cin @('SqlServerLab.AuthenticatedTlsLab/0.1','SqlServerLab.AuthenticatedTlsLab/0.2') -and -not $Record.PSObject.Properties['SqlProfileId']){
        return Get-LabTlsSqlProfile '2025-CU9'
    }
    if($Record.ContractVersion -ceq 'SqlServerLab.AuthenticatedTlsLab/0.3' -and $Record.SqlProfileId -cin @('2022-CU27','2019-CU32')){
        return Get-LabTlsSqlProfile $Record.SqlProfileId
    }
    throw 'TLS_LAB_BINDING_SQL_PROFILE_INVALID'
}
function Read-LabTlsBoundJson {
    param([byte[]]$Bytes,[string[]]$Names)
    if($Bytes.Length -lt 1 -or $Bytes.Length -gt 65536){throw 'TLS_BOUND_JSON_INVALID'}
    $options=[Text.Json.JsonDocumentOptions]::new();$options.MaxDepth=12
    $text=[Text.UTF8Encoding]::new($false,$true).GetString($Bytes)
    $document=[Text.Json.JsonDocument]::Parse($text,$options)
    try{
        $null=Get-LabTlsIndexFields $document.RootElement $Names
        $pending=[Collections.Generic.Stack[Text.Json.JsonElement]]::new();$pending.Push($document.RootElement);$count=0
        while($pending.Count){
            if(++$count -gt 4096){throw 'TLS_BOUND_JSON_INVALID'}
            $node=$pending.Pop()
            if($node.ValueKind -eq [Text.Json.JsonValueKind]::Object){
                $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
                foreach($property in $node.EnumerateObject()){if(-not $seen.Add($property.Name)){throw 'TLS_BOUND_JSON_INVALID'};$pending.Push($property.Value)}
            }elseif($node.ValueKind -eq [Text.Json.JsonValueKind]::Array){foreach($child in $node.EnumerateArray()){$pending.Push($child)}}
        }
        return ConvertFrom-Json -InputObject $text -Depth 12 -DateKind String
    }finally{$document.Dispose()}
}

function Invoke-LabTlsContainer {
    param([string[]]$Arguments,[string]$InputText,[object]$Budget)
    Assert-LabTlsRuntimeBudget $Budget 1
    if($InputText.Length -gt 16384){throw 'TLS_LAB_RUNTIME_INPUT_TOO_LARGE'}
    $start=New-LabTlsRuntimeProcessInfo -Arguments $Arguments -Budget $Budget
    $process=[Diagnostics.Process]::new();$process.StartInfo=$start;$started=$false
    try{
        $started=$process.Start();$stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
        if($InputText){$write=$process.StandardInput.WriteAsync($InputText);if(-not $write.Wait(10000)){throw 'TLS_LAB_RUNTIME_INPUT_TIMEOUT'};$null=$write.GetAwaiter().GetResult()};$process.StandardInput.Close()
        if(-not $process.WaitForExit(45000)){throw 'TLS_LAB_RUNTIME_TIMEOUT'}
        $output=$stdout.GetAwaiter().GetResult();$null=$stderr.GetAwaiter().GetResult()
        if($process.ExitCode -ne 0 -or $output.Length -gt 1048576){throw 'TLS_LAB_RUNTIME_COMMAND_FAILED'}
        return $output.TrimEnd("`r","`n")
    }finally{
        if($started -and -not $process.HasExited){$process.Kill($true);$process.WaitForExit()};$process.Dispose()
    }
}

function Assert-LabTlsRuntimeBudget {
    param([object]$Budget,[int]$Commands)
    if($null -eq $Budget -or $Budget.Provider -cnotin @('docker','podman')){throw 'TLS_LAB_RUNTIME_BUDGET_REQUIRED'}
    $Budget.Commands=[int]$Budget.Commands+$Commands
    if($Budget.Commands -gt 100){throw 'TLS_LAB_RUNTIME_COMMAND_BUDGET_EXCEEDED'}
    if([datetime]::UtcNow -gt $Budget.DeadlineUtc){throw 'TLS_LAB_RUNTIME_TIME_BUDGET_EXCEEDED'}
}

function Get-LabTlsRuntimePin {
    param([object]$Budget)
    if($Budget.Record -and $Budget.Record.ContractVersion -cin @('SqlServerLab.AuthenticatedTlsLab/0.2','SqlServerLab.AuthenticatedTlsLab/0.3')){
        $recorded=Get-LabTlsRecordedRuntimePin $Budget.Record $Budget.StateRoot
        if($Budget.RuntimeContext){
            foreach($name in @('Provider','Invocation','Endpoint','IdentityPath','IdentitySha256','RuntimeScopeId','RoutingKey','IncarnationKey','MachineName')){
                if([string]$Budget.RuntimeContext.$name -cne [string]$recorded.$name){throw 'TLS_LAB_RUNTIME_PIN_CHANGED'}
            }
        }else{$Budget.RuntimeContext=$recorded}
    }
    if(-not $Budget.RuntimeContext){
        # Existing discovery executes at most six bounded commands including the
        # incarnation read. Charge the conservative maximum before discovery.
        Assert-LabTlsRuntimeBudget $Budget 6
        $context=Get-LabRunArtifactRuntimeContext -Provider $Budget.Provider -StateRoot $Budget.StateRoot
        $incarnation=Get-LabRunArtifactRuntimeIncarnation -Context $context -StateRoot $Budget.StateRoot
        $context|Add-Member -NotePropertyName IncarnationKey -NotePropertyValue $incarnation
        $context|Add-Member -NotePropertyName Invocation -NotePropertyValue (Get-LabHostToolInvocation -Name $Budget.Provider)
        $Budget.RuntimeContext=$context
    }
    if($Budget.RuntimeContext.Provider -cne $Budget.Provider){throw 'TLS_LAB_RUNTIME_PROVIDER_CHANGED'}
    return $Budget.RuntimeContext
}

function New-LabTlsRuntimeProcessInfo {
    param([string[]]$Arguments,[object]$Budget)
    if(-not $Arguments.Count -or $Arguments[0].StartsWith('-') -or
        @($Arguments|Where-Object {$_ -cmatch '^(--host|--context|--connection|--url|--identity|--remote)(=|$)'}).Count){throw 'TLS_LAB_RUNTIME_ROUTE_OVERRIDE_FORBIDDEN'}
    $context=Get-LabTlsRuntimePin $Budget
    if($context.IdentityPath){
        $null=Assert-LabRunArtifactPath $context.IdentityPath
        if((Get-FileHash -LiteralPath $context.IdentityPath).Hash.ToLowerInvariant() -cne $context.IdentitySha256){throw 'TLS_LAB_RUNTIME_IDENTITY_CHANGED'}
    }
    if($Budget.StateRoot -and ((Test-Path -LiteralPath (Join-Path $Budget.StateRoot 'owned-host-required')) -or
        (Test-Path -LiteralPath (Join-Path $Budget.StateRoot 'owned-host-policy.json')))){
        $policy=Get-LabOwnedHostPolicy -StateRoot $Budget.StateRoot -Required
        Assert-LabTlsPolicyPin $policy $context
        Assert-LabOwnedHostCommandScope -StateRoot $Budget.StateRoot -Provider $context.Provider -Arguments $Arguments
    }
    $start=[Diagnostics.ProcessStartInfo]::new($context.Invocation)
    $start.UseShellExecute=$false;$start.CreateNoWindow=$true
    $start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true;$start.RedirectStandardInput=$true
    foreach($name in @('DOCKER_HOST','DOCKER_CONTEXT','DOCKER_TLS','DOCKER_TLS_VERIFY','DOCKER_CERT_PATH',
        'CONTAINER_HOST','CONTAINER_CONNECTION','CONTAINER_SSHKEY','PODMAN_SSHKEY','PODMAN_CONNECTIONS_CONF','SSH_AUTH_SOCK','SSH_AGENT_PID')){$null=$start.Environment.Remove($name)}
    $prefix=if($context.Provider -ceq 'docker'){@('--host',$context.Endpoint)}else{@('--remote','--url',$context.Endpoint,'--identity',$context.IdentityPath)}
    foreach($argument in @($prefix)+$Arguments){$start.ArgumentList.Add($argument)}
    return $start
}

function New-LabTlsRuntimeBudget {
    param([ValidateSet('docker','podman')][string]$Provider='docker',[string]$StateRoot,[object]$Record)
    return [pscustomobject]@{Provider=$Provider;StateRoot=$StateRoot;Record=$Record;RuntimeContext=$null;Commands=0;DeadlineUtc=[datetime]::UtcNow.AddMinutes(20)}
}

function Assert-LabTlsLabRoot {
    param([string]$StateRoot)
    if((Test-Path -LiteralPath (Join-Path $StateRoot 'owned-host-required')) -or
        (Test-Path -LiteralPath (Join-Path $StateRoot 'owned-host-policy.json'))){
        # This stronger owner-only root is distinct from CA and export/file ACLs.
        return Get-LabOwnedHostPolicy -StateRoot $StateRoot -Required
    }
    Assert-LabTlsCaPrivateAcl $StateRoot (Get-LabTlsWindowsProcessFacts).UserSid -Directory
    return $null
}

function Assert-LabTlsPolicyPin {
    param([object]$Policy,[object]$Context)
    $pins=@($Policy.RuntimePins)
    if($pins.Count -ne 1 -or $pins[0].Provider -cne $Context.Provider){throw 'TLS_LAB_POLICY_PROVIDER_CHANGED'}
    foreach($name in @('Invocation','Endpoint','IdentityPath','IdentitySha256')){
        if([string]$pins[0].$name -cne [string]$Context.$name){throw 'TLS_LAB_POLICY_PIN_CHANGED'}
    }
}

function Get-LabTlsRecordedRuntimePin {
    param([object]$Record,[string]$StateRoot)
    $r=$Record.RuntimeBinding
    Assert-LabOwnedHostProperties $r @('PolicyId','PolicySha256','RuntimeScopeId','RoutingKey','IncarnationKey','Invocation','Endpoint','IdentityPath','IdentitySha256','MachineName')
    if(-not (Test-LabTlsRequestReference $r.PolicyId) -or $r.PolicySha256 -cnotmatch '\A[a-f0-9]{64}\z' -or
        $r.RuntimeScopeId -cnotmatch '\Aruntime-scope-[a-f0-9]{24}\z' -or $r.RoutingKey -cnotmatch '\A[a-f0-9]{64}\z' -or
        $r.IncarnationKey -cnotmatch '\A[a-f0-9]{64}\z' -or ($Record.Provider -ceq 'docker' -and $r.MachineName) -or
        ($Record.Provider -ceq 'podman' -and $r.MachineName -cnotmatch '\A[A-Za-z0-9][A-Za-z0-9_.-]{0,127}\z')){throw 'TLS_LAB_RUNTIME_BINDING_INVALID'}
    $policy=Get-LabOwnedHostPolicy -StateRoot $StateRoot -Required
    if($policy.PolicyId -cne $r.PolicyId -or $policy.ParentOperationId -cne $Record.AuditId -or
        (Get-FileHash -LiteralPath (Join-Path $StateRoot 'owned-host-policy.json')).Hash.ToLowerInvariant() -cne $r.PolicySha256){throw 'TLS_LAB_POLICY_BINDING_CHANGED'}
    $context=[pscustomobject]@{Provider=$Record.Provider;Invocation=$r.Invocation;Endpoint=$r.Endpoint;IdentityPath=$r.IdentityPath;
        IdentitySha256=$r.IdentitySha256;RuntimeScopeId=$r.RuntimeScopeId;RoutingKey=$r.RoutingKey;IncarnationKey=$r.IncarnationKey;
        MachineName=$r.MachineName;StateRoot=$null}
    Assert-LabTlsPolicyPin $policy $context
    if((Get-LabRetainedStoreHash @($context.Provider,$context.Endpoint,$context.IdentitySha256)) -cne $context.RoutingKey){throw 'TLS_LAB_RUNTIME_ROUTING_KEY_CHANGED'}
    # Keep the original readonly context for the engine/machine observation.
    # A policy RuntimeScope projection is not an engine generation.
    return $context
}

function New-LabTlsRuntimeBinding {
    param([object]$Policy,[object]$Context,[string]$StateRoot)
    return [pscustomobject]@{PolicyId=$Policy.PolicyId;PolicySha256=(Get-FileHash -LiteralPath (Join-Path $StateRoot 'owned-host-policy.json')).Hash.ToLowerInvariant();
        RuntimeScopeId=$Context.RuntimeScopeId;RoutingKey=$Context.RoutingKey;IncarnationKey=$Context.IncarnationKey;
        Invocation=$Context.Invocation;Endpoint=$Context.Endpoint;IdentityPath=[string]$Context.IdentityPath;IdentitySha256=[string]$Context.IdentitySha256;MachineName=[string]$Context.MachineName}
}

function Get-LabTlsBindingProvider {
    param([object]$Record)
    if($Record.ContractVersion -ceq 'SqlServerLab.AuthenticatedTlsLab/0.1' -and -not $Record.PSObject.Properties['Provider']){return 'docker'}
    if($Record.ContractVersion -cin @('SqlServerLab.AuthenticatedTlsLab/0.2','SqlServerLab.AuthenticatedTlsLab/0.3') -and $Record.Provider -cin @('docker','podman')){return [string]$Record.Provider}
    throw 'TLS_LAB_BINDING_PROVIDER_INVALID'
}

function Read-LabTlsLabRecord {
    param([byte[]]$Bytes)
    $fields=@('ContractVersion','AuditId','DataRoot','ControllerId','LocationId','AuthorityRef','ClientRef','RegistrySha256',
        'RunId','InstanceId','ScopeId','ContainerId','ImageId','Port','CertificateSha256','CertificateDer','NotAfterUtc','StartedAt','ServerPath')
    # Each closed shape has its own version; missing profile data never falls back.
    $shape='SqlServerLab.AuthenticatedTlsLab/0.1'
    try{$record=Read-LabTlsBoundJson $Bytes $fields}catch{
        $shape='SqlServerLab.AuthenticatedTlsLab/0.2'
        try{$record=Read-LabTlsBoundJson $Bytes @($fields+'Provider'+'RuntimeBinding')}catch{
            $shape='SqlServerLab.AuthenticatedTlsLab/0.3'
            $record=Read-LabTlsBoundJson $Bytes @($fields+'Provider'+'RuntimeBinding'+'SqlProfileId')
        }
    }
    if($record.ContractVersion -cne $shape){throw 'TLS_LAB_BINDING_SHAPE_INVALID'}
    $null=Get-LabTlsBindingProvider $record
    $null=Get-LabTlsBindingSqlProfile $record
    return $record
}

function Get-LabTlsOwnedRuntimeContext {
    param([string]$RunId,[string]$StateRoot,[object]$Budget)
    $root=Assert-LabDiagnosticPath ([IO.Path]::GetFullPath($StateRoot))
    $policy=Assert-LabTlsLabRoot $root
    if($RunId -cnotmatch '\A[A-Za-z0-9_-]{1,128}\z'){throw 'TLS_LAB_RUN_ID_INVALID'}
    $run=Get-LabRunState -RunId $RunId -StateRoot $root
    $directory=Join-Path (Join-Path $root 'runs') $RunId;$connectionPath=Join-Path $directory 'connection-info.json'
    $connection=Read-LabDiagnosticJson $connectionPath
    $rows=@($connection.instances)
    if($rows.Count -ne 1 -or $rows[0].id -cne 'primary' -or $rows[0].provider -cnotin @('docker','podman') -or
        $rows[0].provider -cne $Budget.Provider -or
        $rows[0].containerId -cnotmatch '\A[0-9a-f]{64}\z'){throw 'TLS_LAB_INSTANCE_BINDING_INVALID'}
    $instance=$rows[0]
    $pin=Get-LabTlsRuntimePin $Budget
    Assert-LabTlsRuntimeBudget $Budget 1
    $incarnation=Get-LabRunArtifactRuntimeIncarnation -Context $pin -StateRoot $root -Invocation $pin.Invocation
    if($pin.IncarnationKey -cne $incarnation){throw 'TLS_LAB_RUNTIME_ORIGIN_CHANGED'}
    if($policy){
        $runPolicy=Get-LabOwnedHostRunPolicy -RunId $RunId -StateRoot $root
        if($runPolicy.PolicyId -cne $policy.PolicyId){throw 'TLS_LAB_POLICY_BINDING_CHANGED'}
        Assert-LabTlsPolicyPin $runPolicy $pin
    }else{
        $origin=@($run.metadata.artifactRemovalRuntimeScopes|Where-Object Provider -CEQ $Budget.Provider)
        if($origin.Count -ne 1 -or $origin[0].Status -cne 'AVAILABLE' -or $origin[0].OriginStatus -cne 'PINNED_CREATION' -or
            $origin[0].RuntimeScopeId -cne $pin.RuntimeScopeId -or $origin[0].RoutingKey -cne $pin.RoutingKey -or
            $origin[0].IncarnationKey -cne $incarnation){throw 'TLS_LAB_RUNTIME_ORIGIN_CHANGED'}
    }
    # All fresh native observations use the same counted, timed process boundary.
    $observed=@((Invoke-LabTlsContainer @('inspect',$instance.containerId) -Budget $Budget)|ConvertFrom-Json -Depth 50 -DateKind String)
    if($observed.Count -ne 1){throw 'TLS_LAB_INSPECT_AMBIGUOUS'}
    $inspect=$observed[0]
    if($inspect.Id -cne $instance.containerId -or $inspect.Config.Labels.'sql-server-lab.run-id' -cne $RunId -or
        $inspect.Config.Labels.'sql-server-lab.scope-id' -cne $run.scopeId -or $inspect.Config.Labels.'sql-server-lab.instance-id' -cne 'primary'){
        throw 'TLS_LAB_OWNERSHIP_CHANGED'
    }
    $ports=@($inspect.NetworkSettings.Ports.'1433/tcp')
    if($ports.Count -lt 1 -or $ports.Count -gt 2 -or @($ports|Where-Object {[int]$_.HostPort -ne [int]$instance.port}).Count){throw 'TLS_LAB_PORT_CHANGED'}
    return [pscustomobject]@{Run=$run;RunId=$RunId;RunDirectory=$directory;ConnectionPath=$connectionPath;Connection=$connection;Instance=$instance;
        Provider=$Budget.Provider;PolicyBound=[bool]$policy;ContainerId=$inspect.Id;Inspect=$inspect;CurrentPort=[int]$instance.port;WasRunning=[bool]$inspect.State.Running}
}

function ConvertTo-LabTlsImageId {
    param([string]$Value)
    if($Value -cmatch '\A(?:sha256:)?(?<digest>[a-f0-9]{64})\z'){return ('sha256:'+$Matches['digest'])}
    throw 'TLS_LAB_IMAGE_ID_INVALID'
}

function Assert-LabTlsOwnContainer {
    param([object]$Record,[string]$StateRoot,[object]$Budget)
    $provider=Get-LabTlsBindingProvider $Record
    if($Budget.Provider -cne $provider){throw 'TLS_LAB_RUNTIME_PROVIDER_CHANGED'}
    $context=Get-LabTlsOwnedRuntimeContext -RunId $Record.RunId -StateRoot $StateRoot -Budget $Budget
    $imageId=$context.Inspect.Image;$configImage=$context.Inspect.Config.Image
    $expectedConfigImage='mcr.microsoft.com/mssql/server:2025-CU9-ubuntu-24.04'
    if($Record.ContractVersion -cin @('SqlServerLab.AuthenticatedTlsLab/0.2','SqlServerLab.AuthenticatedTlsLab/0.3')){
        $imageId=ConvertTo-LabTlsImageId $imageId;$configImage=ConvertTo-LabTlsImageId $configImage
        $expectedConfigImage=$Record.ImageId
    }
    if(($Record.ContractVersion -cin @('SqlServerLab.AuthenticatedTlsLab/0.2','SqlServerLab.AuthenticatedTlsLab/0.3') -and -not $context.PolicyBound) -or
        $context.Provider -cne $provider -or $context.ContainerId -cne $Record.ContainerId -or $context.Run.scopeId -cne $Record.ScopeId -or
        $imageId -cne $Record.ImageId -or $context.CurrentPort -ne $Record.Port -or -not $context.WasRunning -or
        $context.Instance.host -cne '127.0.0.1' -or $configImage -cne $expectedConfigImage){
        throw 'TLS_LAB_TARGET_CHANGED'
    }
    return $context
}

function Get-LabTlsOwnBinding {
    param([string]$StateRoot,[string]$RunId,[string]$InstanceId)
    $native=Get-LabTlsWindowsProcessFacts
    $root=Assert-LabDiagnosticPath ([IO.Path]::GetFullPath($StateRoot))
    $null=Assert-LabTlsLabRoot $root
    $bytes=Read-LabTlsCaPrivateFile (Join-Path $root 'authenticated-tls-lab.json') $native.UserSid 32768
    $record=Read-LabTlsLabRecord $bytes
    if($record.ContractVersion -cin @('SqlServerLab.AuthenticatedTlsLab/0.2','SqlServerLab.AuthenticatedTlsLab/0.3')){$null=Get-LabTlsRecordedRuntimePin $record $root}
    if(-not (Test-LabTlsRequestReference $record.AuditId) -or
        $record.RunId -cne $RunId -or $record.InstanceId -cne $InstanceId -or
        $record.ServerPath -cne ('/var/opt/mssql/tls-'+$record.AuditId.Replace('-',''))){throw 'TLS_LAB_BINDING_INVALID'}
    $expected=Join-Path $record.DataRoot ('State/authenticated-tls-labs/'+$record.AuditId)
    if(-not [string]::Equals($root,[IO.Path]::GetFullPath($expected),[StringComparison]::OrdinalIgnoreCase)){throw 'TLS_LAB_ROOT_CHANGED'}
    $authority=Get-LabTlsOperationalAuthority $record.DataRoot $record.ControllerId $record.LocationId $record.AuthorityRef $record.ClientRef
    if($authority.RegistrySha256 -cne $record.RegistrySha256){throw 'TLS_LAB_REGISTRY_CHANGED'}
    return [pscustomobject]@{Record=$record;Authority=$authority;Bytes=$bytes;StateRoot=$root}
}

function Assert-LabTlsSqlCertificateBinding {
    param([object]$Record,[string]$StateRoot,[object]$Budget)
    $context=Assert-LabTlsOwnContainer $Record $StateRoot $Budget
    if($context.Inspect.State.StartedAt -cne $Record.StartedAt){throw 'TLS_LAB_RESTART_REQUIRES_REBIND'}
    $cid=$context.ContainerId;$path=$Record.ServerPath
    $actual=Invoke-LabTlsContainer @('exec',$cid,'cat',($path+'/server.pem')) -Budget $Budget
    $cert=[Security.Cryptography.X509Certificates.X509Certificate2]::CreateFromPem($actual)
    try{
        if((Get-LabTlsCaByteDigest $cert.RawData) -cne $Record.CertificateSha256 -or
            [Convert]::ToBase64String($cert.RawData) -cne $Record.CertificateDer -or
            $cert.NotAfter.ToUniversalTime() -le [datetime]::UtcNow -or $cert.NotBefore.ToUniversalTime() -gt [datetime]::UtcNow){throw 'TLS_LAB_LEAF_CHANGED_OR_EXPIRED'}
    }finally{$cert.Dispose()}
    $mode=Invoke-LabTlsContainer @('exec',$cid,'stat','-c','%a:%u',($path+'/server.key')) -Budget $Budget
    if($mode -cne '600:10001'){throw 'TLS_LAB_SERVER_KEY_PERMISSIONS_CHANGED'}
    $config=Invoke-LabTlsContainer @('exec',$cid,'cat','/var/opt/mssql/mssql.conf') -Budget $Budget
    $network=$false;$sections=0;$settings=@{}
    foreach($line in ($config -split "`n")){
        $line=$line.Trim()
        if($line -match '^\[([^\]]+)\]$'){$network=$Matches[1] -ceq 'network';if($network){$sections++};continue}
        if($network -and $line -match '^(tlscert|tlskey|forceencryption)\s*=\s*(.+)$'){
            if($settings.ContainsKey($Matches[1])){throw 'TLS_LAB_SQL_CONFIG_AMBIGUOUS'};$settings[$Matches[1]]=$Matches[2].Trim()
        }
    }
    if($sections -ne 1 -or $settings.tlscert -cne ($path+'/server.pem') -or $settings.tlskey -cne ($path+'/server.key') -or $settings.forceencryption -cne '1'){throw 'TLS_LAB_SQL_CONFIG_CHANGED'}
    # The fresh process must report loading these exact paths. This is a file/config
    # binding, not a wire certificate fingerprint or protection against a host admin.
    $log=Invoke-LabTlsContainer @('logs','--since',$Record.StartedAt,$cid) -Budget $Budget
    $expected="The certificate [Certificate File:'$path/server.pem', Private Key File:'$path/server.key'] was successfully loaded for encryption."
    if(-not $log.Contains($expected,[StringComparison]::Ordinal)){throw 'TLS_LAB_SQL_CERTIFICATE_LOAD_UNCONFIRMED'}
    return $context
}

function New-LabAuthenticatedTlsEnvironment {
    param([hashtable]$Parameters)
    $allowed=@('TrustServerCertificate','TlsCandidateId','TlsControllerId','TlsLocationId','DataRoot','Version','Provider','Profile','Port','InstanceId',
        'SaPassword','GenerateSaPassword','NonInteractive','Cpu','MemoryMB','SkipAssessment','AllowResourceOvercommit','AutoStart','LabName','Verbose','ErrorAction')
    if(@($Parameters.Keys|Where-Object {$_ -cnotin $allowed}).Count -or $Parameters.Version -cnotin @('2025-CU9','2022-CU27','2019-CU32') -or
        ($Parameters.ContainsKey('Provider') -and $Parameters.Provider -cnotin @('docker','podman')) -or
        ($Parameters.ContainsKey('InstanceId') -and $Parameters.InstanceId -cne 'primary') -or
        ($Parameters.ContainsKey('AutoStart') -and $Parameters.AutoStart -cne 'off') -or -not $Parameters.DataRoot){throw 'TLS_LAB_CAPABILITY_UNSUPPORTED: Windows, Docker or Podman, 2025-CU9, 2022-CU27 or 2019-CU32 and explicit DataRoot required; primary, autostart off; no manifest, mounts or existing StateRoot.'}
    foreach($key in @('TlsCandidateId','TlsControllerId','TlsLocationId')){if(-not (Test-LabTlsRequestReference $Parameters[$key])){throw 'TLS_LAB_CA_SELECTION_REQUIRED'}}
    Assert-LabTlsCaCandidateCapability
    $profile=Get-LabTlsSqlProfile $Parameters.Version
    Assert-LabTlsSqlCatalogProfile $profile
    $provider=if($Parameters.ContainsKey('Provider')){[string]$Parameters.Provider}else{'docker'}
    $budget=New-LabTlsRuntimeBudget -Provider $provider
    $format=if($provider -ceq 'docker'){'{{.ServerVersion}}'}else{'json'}
    $null=Invoke-LabTlsContainer @('info','--format',$format) -Budget $budget
    $expectedImageId=ConvertTo-LabTlsImageId (Invoke-LabTlsContainer @('image','inspect',$profile.Image,'--format','{{.Id}}') -Budget $budget).Trim()
    $authority=Register-LabTlsOperationalAuthority $Parameters.DataRoot $Parameters.TlsControllerId $Parameters.TlsLocationId $Parameters.TlsCandidateId
    if([DateTimeOffset]::ParseExact($authority.Authority.NotAfterUtc,'o',[Globalization.CultureInfo]::InvariantCulture) -le [DateTimeOffset]::UtcNow.AddDays(1)){throw 'TLS_LAB_CA_LIFETIME_INSUFFICIENT'}
    $sid=$authority.Native.UserSid;$audit=[guid]::NewGuid().ToString('D')
    $parent=Join-Path $Parameters.DataRoot 'State/authenticated-tls-labs'
    Initialize-LabTlsCaPrivateDirectory $parent $sid
    $state=Join-Path $parent $audit
    $pin=Get-LabTlsRuntimePin $budget
    $runtimePin=[pscustomobject]@{Provider=$provider;Invocation=$pin.Invocation;Endpoint=$pin.Endpoint;IdentityPath=[string]$pin.IdentityPath;IdentitySha256=[string]$pin.IdentitySha256}
    $policy=Initialize-LabOwnedHostPolicy -StateRoot $state -RuntimePins @($runtimePin) -ParentOperationId $audit
    $budget.StateRoot=$state
    $intent=[pscustomobject]@{AuditId=$audit;Status='OWNED_CREATE_PENDING';Cleanup='Remove-SqlServerLab only this StateRoot/run; retain recovery on unconfirmed cleanup'}
    Write-LabTlsCaPrivateFile (Join-Path $state 'intent.json') $sid (ConvertTo-LabTlsRegistryWriterBytes $intent)
    $inner=@{};foreach($key in $Parameters.Keys){if($key -cnotin @('TrustServerCertificate','TlsCandidateId','TlsControllerId','TlsLocationId','DataRoot')){$inner[$key]=$Parameters[$key]}}
    $inner.StateRoot=$state;$inner.Provider=$provider;$inner.InstanceId='primary';$inner.AutoStart='off'
    $run=$null
    try{
        $run=New-SqlServerLab @inner
        $context=Get-LabTlsOwnedRuntimeContext -RunId $run.RunId -StateRoot $state -Budget $budget
        if((ConvertTo-LabTlsImageId $context.Inspect.Image) -cne $expectedImageId){throw 'TLS_LAB_IMAGE_CHANGED'}
        $record=[ordered]@{ContractVersion='SqlServerLab.AuthenticatedTlsLab/0.2';Provider=$provider;RuntimeBinding=(New-LabTlsRuntimeBinding $policy $pin $state);AuditId=$audit;DataRoot=$Parameters.DataRoot;ControllerId=$Parameters.TlsControllerId;LocationId=$Parameters.TlsLocationId;
            AuthorityRef=$authority.Authority.Ref;ClientRef=$authority.Client.Ref;RegistrySha256=$authority.RegistrySha256;RunId=$run.RunId;InstanceId='primary';ScopeId=$context.Run.scopeId;
            ContainerId=$context.ContainerId;ImageId=$expectedImageId;Port=$context.CurrentPort;CertificateSha256='';CertificateDer='';NotAfterUtc='';StartedAt='';ServerPath=('/var/opt/mssql/tls-'+$audit.Replace('-',''))}
        if($profile.Version -cin @('2022-CU27','2019-CU32')){$record.ContractVersion='SqlServerLab.AuthenticatedTlsLab/0.3';$record.SqlProfileId=$profile.Version}
        $budget.Record=[pscustomobject]$record
        $null=Assert-LabTlsOwnContainer ([pscustomobject]$record) $state $budget
        Write-LabTlsCaPrivateFile (Join-Path $state 'target-intent.json') $sid (ConvertTo-LabTlsRegistryWriterBytes ([pscustomobject]$record))
        $cid=$context.ContainerId;$path=$record.ServerPath
        $command="umask 077; mkdir '$path' && openssl req -new -newkey rsa:3072 -nodes -sha256 -subj '/CN=SQL_Server_Lab Server Leaf' -keyout '$path/server.key' -out '$path/server.csr' -outform DER -addext 'subjectAltName=IP:127.0.0.1'"
        $null=Invoke-LabTlsContainer @('exec','--user','10001',$cid,'sh','-c',$command) -Budget $budget
        $csr=[Convert]::FromBase64String((Invoke-LabTlsContainer @('exec',$cid,'base64','-w0',($path+'/server.csr')) -Budget $budget))
        $leaf=New-LabAuthenticatedTlsServerLeaf $Parameters.DataRoot $Parameters.TlsControllerId $Parameters.TlsLocationId CURRENT_WINDOWS_PROCESS $Parameters.TlsCandidateId $csr ([pscustomobject]@{Kind='IP';Value='127.0.0.1'}) ([int]1)
        if(-not $leaf.Success){throw 'TLS_LAB_LEAF_ISSUANCE_REJECTED'}
        $record.CertificateSha256=$leaf.Value.CertificateSha256;$record.CertificateDer=[Convert]::ToBase64String($leaf.Value.CertificateDer);$record.NotAfterUtc=$leaf.Value.NotAfterUtc
        $pem=[Security.Cryptography.PemEncoding]::WriteString('CERTIFICATE',$leaf.Value.CertificateDer)
        $null=Invoke-LabTlsContainer @('exec','-i','--user','10001',$cid,'sh','-c',"umask 077; cat > '$path/server.pem'") ($pem+"`n") -Budget $budget
        foreach($setting in @(@('network.tlscert',($path+'/server.pem')),@('network.tlskey',($path+'/server.key')),@('network.forceencryption','1'))){
            $null=Invoke-LabTlsContainer @('exec','--user','0',$cid,'/opt/mssql/bin/mssql-conf','set',$setting[0],$setting[1]) -Budget $budget
        }
        $null=Stop-SqlServerLab -RunId $run.RunId -StateRoot $state -Force -SkipHostMemoryRelease -Confirm:$false
        $null=Start-SqlServerLab -RunId $run.RunId -StateRoot $state
        $context=Assert-LabTlsOwnContainer ([pscustomobject]$record) $state $budget;$record.StartedAt=$context.Inspect.State.StartedAt
        Write-LabTlsCaPrivateFile (Join-Path $state 'authenticated-tls-lab.json') $sid (ConvertTo-LabTlsRegistryWriterBytes ([pscustomobject]$record))
        $qualified=Test-LabAuthenticatedTlsEnvironment -RunId $run.RunId -InstanceId primary -StateRoot $state -Budget $budget
        # Store explicit flags only after both real stacks have succeeded.
        $context=Get-LabTlsOwnedRuntimeContext -RunId $run.RunId -StateRoot $state -Budget $budget
        $builder=[Data.SqlClient.SqlConnectionStringBuilder]::new($context.Instance.connectionString);$builder['Encrypt']=$true;$builder['TrustServerCertificate']=$false
        $context.Instance.connectionString=$builder.ConnectionString
        Write-LabArtifactJsonAtomic -Path $context.ConnectionPath -InputObject $context.Connection
        $run.Instances[0].ConnectionString=$builder.ConnectionString
        $run|Add-Member -NotePropertyName TlsQualification -NotePropertyValue $qualified -Force
        return $run
    }catch{
        $failure=$_
        # New's ordinary compensation owns pre-return failures. For a returned run,
        # remove only this exact newly allocated run; cleanup failure stays visible.
        if($run){
            $removed=Remove-SqlServerLab -RunId $run.RunId -StateRoot $state -Force -Confirm:$false
            if($removed.Status -cne 'REMOVED'){throw 'TLS_LAB_FAILED_CLEANUP_RECOVERY_REQUIRED'}
        }else{
            # Failure before the ordinary creator even arranged a run: remove only
            # the one known intent and the otherwise empty newly allocated root.
            $children=@(Get-ChildItem -LiteralPath $state -Force)
            if($children.Count -eq 1 -and $children[0].Name -ceq 'intent.json' -and -not $children[0].PSIsContainer){
                $resolved=Assert-LabDiagnosticPath $state
                if([IO.Path]::GetDirectoryName($resolved) -cne (Assert-LabDiagnosticPath $parent) -or [IO.Path]::GetFileName($resolved) -cne $audit){throw 'TLS_LAB_CLEANUP_SCOPE_INVALID'}
                Remove-Item -LiteralPath (Join-Path $resolved 'intent.json') -Force
                Remove-Item -LiteralPath $resolved
            }
        }
        throw $failure
    }
}
