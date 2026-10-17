#Requires -Version 7.2
# First operational lane: Windows current user -> own Docker SQL 2025 CU9.
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

function Invoke-LabTlsDocker {
    param([string[]]$Arguments,[string]$InputText,[object]$Budget)
    if($null -eq $Budget){throw 'TLS_LAB_RUNTIME_BUDGET_REQUIRED'}
    $Budget.Commands=[int]$Budget.Commands+1
    if($Budget.Commands -gt 100){throw 'TLS_LAB_RUNTIME_COMMAND_BUDGET_EXCEEDED'}
    if([datetime]::UtcNow -gt $Budget.DeadlineUtc){throw 'TLS_LAB_RUNTIME_TIME_BUDGET_EXCEEDED'}
    $start=[Diagnostics.ProcessStartInfo]::new((Get-LabHostToolInvocation -Name docker))
    $start.UseShellExecute=$false;$start.CreateNoWindow=$true
    $start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true;$start.RedirectStandardInput=$true
    foreach($argument in $Arguments){$start.ArgumentList.Add($argument)}
    $process=[Diagnostics.Process]::new();$process.StartInfo=$start
    try{
        $null=$process.Start();$stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
        if($InputText){$process.StandardInput.Write($InputText)};$process.StandardInput.Close()
        if(-not $process.WaitForExit(45000)){$process.Kill($true);$process.WaitForExit();throw 'TLS_LAB_RUNTIME_TIMEOUT'}
        $output=$stdout.GetAwaiter().GetResult();$null=$stderr.GetAwaiter().GetResult()
        if($process.ExitCode -ne 0 -or $output.Length -gt 1048576){throw 'TLS_LAB_RUNTIME_COMMAND_FAILED'}
        return $output.TrimEnd("`r","`n")
    }finally{$process.Dispose()}
}

function New-LabTlsDockerBudget {
    return [pscustomobject]@{Commands=0;DeadlineUtc=[datetime]::UtcNow.AddMinutes(20)}
}

function Get-LabTlsOwnedRuntimeContext {
    param([string]$RunId,[string]$StateRoot,[object]$Budget)
    $root=Assert-LabDiagnosticPath ([IO.Path]::GetFullPath($StateRoot))
    Assert-LabTlsCaPrivateAcl $root (Get-LabTlsWindowsProcessFacts).UserSid -Directory
    if($RunId -cnotmatch '\A[A-Za-z0-9_-]{1,128}\z'){throw 'TLS_LAB_RUN_ID_INVALID'}
    $run=Get-LabRunState -RunId $RunId -StateRoot $root
    $directory=Join-Path (Join-Path $root 'runs') $RunId;$connectionPath=Join-Path $directory 'connection-info.json'
    $connection=Read-LabDiagnosticJson $connectionPath
    $rows=@($connection.instances)
    if($rows.Count -ne 1 -or $rows[0].id -cne 'primary' -or $rows[0].provider -cne 'docker' -or
        $rows[0].containerId -cnotmatch '\A[0-9a-f]{64}\z'){throw 'TLS_LAB_INSTANCE_BINDING_INVALID'}
    $instance=$rows[0]
    # All fresh native observations use the same counted, timed process boundary.
    $observed=@((Invoke-LabTlsDocker @('inspect',$instance.containerId) -Budget $Budget)|ConvertFrom-Json -Depth 50 -DateKind String)
    if($observed.Count -ne 1){throw 'TLS_LAB_INSPECT_AMBIGUOUS'}
    $inspect=$observed[0]
    if($inspect.Id -cne $instance.containerId -or $inspect.Config.Labels.'sql-server-lab.run-id' -cne $RunId -or
        $inspect.Config.Labels.'sql-server-lab.scope-id' -cne $run.scopeId -or $inspect.Config.Labels.'sql-server-lab.instance-id' -cne 'primary'){
        throw 'TLS_LAB_OWNERSHIP_CHANGED'
    }
    $ports=@($inspect.NetworkSettings.Ports.'1433/tcp')
    if($ports.Count -lt 1 -or $ports.Count -gt 2 -or @($ports|Where-Object {[int]$_.HostPort -ne [int]$instance.port}).Count){throw 'TLS_LAB_PORT_CHANGED'}
    return [pscustomobject]@{Run=$run;RunId=$RunId;RunDirectory=$directory;ConnectionPath=$connectionPath;Connection=$connection;Instance=$instance;
        Provider='docker';ContainerId=$inspect.Id;Inspect=$inspect;CurrentPort=[int]$instance.port;WasRunning=[bool]$inspect.State.Running}
}

function Assert-LabTlsOwnContainer {
    param([object]$Record,[string]$StateRoot,[object]$Budget)
    $context=Get-LabTlsOwnedRuntimeContext -RunId $Record.RunId -StateRoot $StateRoot -Budget $Budget
    if($context.Provider -cne 'docker' -or $context.ContainerId -cne $Record.ContainerId -or $context.Run.scopeId -cne $Record.ScopeId -or
        $context.Inspect.Image -cne $Record.ImageId -or $context.CurrentPort -ne $Record.Port -or -not $context.WasRunning -or
        $context.Instance.host -cne '127.0.0.1' -or $context.Inspect.Config.Image -cne 'mcr.microsoft.com/mssql/server:2025-CU9-ubuntu-24.04'){
        throw 'TLS_LAB_TARGET_CHANGED'
    }
    return $context
}

function Get-LabTlsOwnBinding {
    param([string]$StateRoot,[string]$RunId,[string]$InstanceId)
    $native=Get-LabTlsWindowsProcessFacts
    $root=Assert-LabDiagnosticPath ([IO.Path]::GetFullPath($StateRoot))
    Assert-LabTlsCaPrivateAcl $root $native.UserSid -Directory
    $bytes=Read-LabTlsCaPrivateFile (Join-Path $root 'authenticated-tls-lab.json') $native.UserSid 32768
    $record=Read-LabTlsBoundJson $bytes @('ContractVersion','AuditId','DataRoot','ControllerId','LocationId','AuthorityRef','ClientRef','RegistrySha256',
        'RunId','InstanceId','ScopeId','ContainerId','ImageId','Port','CertificateSha256','CertificateDer','NotAfterUtc','StartedAt','ServerPath')
    if($record.ContractVersion -cne 'SqlServerLab.AuthenticatedTlsLab/0.1' -or -not (Test-LabTlsRequestReference $record.AuditId) -or
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
    $actual=Invoke-LabTlsDocker @('exec',$cid,'cat',($path+'/server.pem')) -Budget $Budget
    $cert=[Security.Cryptography.X509Certificates.X509Certificate2]::CreateFromPem($actual)
    try{
        if((Get-LabTlsCaByteDigest $cert.RawData) -cne $Record.CertificateSha256 -or
            [Convert]::ToBase64String($cert.RawData) -cne $Record.CertificateDer -or
            $cert.NotAfter.ToUniversalTime() -le [datetime]::UtcNow -or $cert.NotBefore.ToUniversalTime() -gt [datetime]::UtcNow){throw 'TLS_LAB_LEAF_CHANGED_OR_EXPIRED'}
    }finally{$cert.Dispose()}
    $mode=Invoke-LabTlsDocker @('exec',$cid,'stat','-c','%a:%u',($path+'/server.key')) -Budget $Budget
    if($mode -cne '600:10001'){throw 'TLS_LAB_SERVER_KEY_PERMISSIONS_CHANGED'}
    $config=Invoke-LabTlsDocker @('exec',$cid,'cat','/var/opt/mssql/mssql.conf') -Budget $Budget
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
    $log=Invoke-LabTlsDocker @('logs','--since',$Record.StartedAt,$cid) -Budget $Budget
    $expected="The certificate [Certificate File:'$path/server.pem', Private Key File:'$path/server.key'] was successfully loaded for encryption."
    if(-not $log.Contains($expected,[StringComparison]::Ordinal)){throw 'TLS_LAB_SQL_CERTIFICATE_LOAD_UNCONFIRMED'}
    return $context
}

function New-LabAuthenticatedTlsEnvironment {
    param([hashtable]$Parameters)
    $allowed=@('TrustServerCertificate','TlsCandidateId','TlsControllerId','TlsLocationId','DataRoot','Version','Provider','Profile','Port','InstanceId',
        'SaPassword','GenerateSaPassword','NonInteractive','Cpu','MemoryMB','SkipAssessment','AllowResourceOvercommit','AutoStart','LabName','Verbose','ErrorAction')
    if(@($Parameters.Keys|Where-Object {$_ -cnotin $allowed}).Count -or $Parameters.Version -cne '2025-CU9' -or
        ($Parameters.ContainsKey('Provider') -and $Parameters.Provider -cne 'docker') -or
        ($Parameters.ContainsKey('InstanceId') -and $Parameters.InstanceId -cne 'primary') -or
        ($Parameters.ContainsKey('AutoStart') -and $Parameters.AutoStart -cne 'off') -or -not $Parameters.DataRoot){throw 'TLS_LAB_CAPABILITY_UNSUPPORTED: Windows, Docker, 2025-CU9 and explicit DataRoot required; primary, autostart off; no manifest, mounts or existing StateRoot.'}
    foreach($key in @('TlsCandidateId','TlsControllerId','TlsLocationId')){if(-not (Test-LabTlsRequestReference $Parameters[$key])){throw 'TLS_LAB_CA_SELECTION_REQUIRED'}}
    Assert-LabTlsCaCandidateCapability
    $budget=New-LabTlsDockerBudget
    $null=Invoke-LabTlsDocker @('info','--format','{{.ServerVersion}}') -Budget $budget
    $null=Invoke-LabTlsDocker @('image','inspect','mcr.microsoft.com/mssql/server:2025-CU9-ubuntu-24.04','--format','{{.Id}}') -Budget $budget
    $authority=Register-LabTlsOperationalAuthority $Parameters.DataRoot $Parameters.TlsControllerId $Parameters.TlsLocationId $Parameters.TlsCandidateId
    if([DateTimeOffset]::ParseExact($authority.Authority.NotAfterUtc,'o',[Globalization.CultureInfo]::InvariantCulture) -le [DateTimeOffset]::UtcNow.AddDays(1)){throw 'TLS_LAB_CA_LIFETIME_INSUFFICIENT'}
    $sid=$authority.Native.UserSid;$audit=[guid]::NewGuid().ToString('D')
    $parent=Join-Path $Parameters.DataRoot 'State/authenticated-tls-labs'
    Initialize-LabTlsCaPrivateDirectory $parent $sid
    $state=Join-Path $parent $audit;Initialize-LabTlsCaPrivateDirectory $state $sid -NewOnly
    $intent=[pscustomobject]@{AuditId=$audit;Status='OWNED_CREATE_PENDING';Cleanup='Remove-SqlServerLab only this StateRoot/run; retain recovery on unconfirmed cleanup'}
    Write-LabTlsCaPrivateFile (Join-Path $state 'intent.json') $sid (ConvertTo-LabTlsRegistryWriterBytes $intent)
    $inner=@{};foreach($key in $Parameters.Keys){if($key -cnotin @('TrustServerCertificate','TlsCandidateId','TlsControllerId','TlsLocationId','DataRoot')){$inner[$key]=$Parameters[$key]}}
    $inner.StateRoot=$state;$inner.Provider='docker';$inner.InstanceId='primary';$inner.AutoStart='off'
    $run=$null
    try{
        $run=New-SqlServerLab @inner
        $context=Get-LabTlsOwnedRuntimeContext -RunId $run.RunId -StateRoot $state -Budget $budget
        $record=[ordered]@{ContractVersion='SqlServerLab.AuthenticatedTlsLab/0.1';AuditId=$audit;DataRoot=$Parameters.DataRoot;ControllerId=$Parameters.TlsControllerId;LocationId=$Parameters.TlsLocationId;
            AuthorityRef=$authority.Authority.Ref;ClientRef=$authority.Client.Ref;RegistrySha256=$authority.RegistrySha256;RunId=$run.RunId;InstanceId='primary';ScopeId=$context.Run.scopeId;
            ContainerId=$context.ContainerId;ImageId=$context.Inspect.Image;Port=$context.CurrentPort;CertificateSha256='';CertificateDer='';NotAfterUtc='';StartedAt='';ServerPath=('/var/opt/mssql/tls-'+$audit.Replace('-',''))}
        $null=Assert-LabTlsOwnContainer ([pscustomobject]$record) $state $budget
        Write-LabTlsCaPrivateFile (Join-Path $state 'target-intent.json') $sid (ConvertTo-LabTlsRegistryWriterBytes ([pscustomobject]$record))
        $cid=$context.ContainerId;$path=$record.ServerPath
        $command="umask 077; mkdir '$path' && openssl req -new -newkey rsa:3072 -nodes -sha256 -subj '/CN=SQL_Server_Lab Server Leaf' -keyout '$path/server.key' -out '$path/server.csr' -outform DER -addext 'subjectAltName=IP:127.0.0.1'"
        $null=Invoke-LabTlsDocker @('exec','--user','10001',$cid,'sh','-c',$command) -Budget $budget
        $csr=[Convert]::FromBase64String((Invoke-LabTlsDocker @('exec',$cid,'base64','-w0',($path+'/server.csr')) -Budget $budget))
        $leaf=New-LabAuthenticatedTlsServerLeaf $Parameters.DataRoot $Parameters.TlsControllerId $Parameters.TlsLocationId CURRENT_WINDOWS_PROCESS $Parameters.TlsCandidateId $csr ([pscustomobject]@{Kind='IP';Value='127.0.0.1'}) ([int]1)
        if(-not $leaf.Success){throw 'TLS_LAB_LEAF_ISSUANCE_REJECTED'}
        $record.CertificateSha256=$leaf.Value.CertificateSha256;$record.CertificateDer=[Convert]::ToBase64String($leaf.Value.CertificateDer);$record.NotAfterUtc=$leaf.Value.NotAfterUtc
        $pem=[Security.Cryptography.PemEncoding]::WriteString('CERTIFICATE',$leaf.Value.CertificateDer)
        $null=Invoke-LabTlsDocker @('exec','-i','--user','10001',$cid,'sh','-c',"umask 077; cat > '$path/server.pem'") ($pem+"`n") -Budget $budget
        foreach($setting in @(@('network.tlscert',($path+'/server.pem')),@('network.tlskey',($path+'/server.key')),@('network.forceencryption','1'))){
            $null=Invoke-LabTlsDocker @('exec','--user','0',$cid,'/opt/mssql/bin/mssql-conf','set',$setting[0],$setting[1]) -Budget $budget
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
