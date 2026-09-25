function Resolve-LabAiSharedGatewaySessionKeys {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Plan,[Parameter(Mandatory)][hashtable]$ApiKeyByReference)

    $required=@($Plan.Consumers|ForEach-Object {[string]$_.ApiKeyReference}|Sort-Object -Unique)
    $provided=@($ApiKeyByReference.Keys|ForEach-Object {[string]$_}|Sort-Object -Unique)
    if(($required -join "`n") -cne ($provided -join "`n")){throw 'AI_SHARED_GATEWAY_SESSION_API_KEY_SET_MISMATCH'}
    $plain=[Collections.Generic.List[string]]::new()
    try {
        foreach($reference in $required){
            $value=$ApiKeyByReference[$reference]
            if($value -isnot [SecureString]){throw 'AI_SHARED_GATEWAY_SESSION_API_KEY_INVALID'}
            $secret=ConvertFrom-LabSecureString -SecureString $value
            if($secret -cnotmatch '^[A-Za-z0-9_-]{24,256}$'){throw 'AI_SHARED_GATEWAY_SESSION_API_KEY_INVALID'}
            $plain.Add($secret);$secret=$null
        }
        if(@($plain|Sort-Object -Unique).Count -ne $plain.Count){throw 'AI_SHARED_GATEWAY_SESSION_API_KEY_DUPLICATE'}
        return @($plain)
    }
    catch {$plain.Clear();throw}
}

function Test-LabAiSharedGatewaySessionBearer {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Authorization,[Parameter(Mandatory)][string[]]$Secrets)
    $matched=$false
    foreach($secret in $Secrets){
        $actual=[Text.Encoding]::UTF8.GetBytes($Authorization);$expected=[Text.Encoding]::UTF8.GetBytes('Bearer '+$secret)
        $actualHash=$null;$expectedHash=$null
        try {$actualHash=[Security.Cryptography.SHA256]::HashData($actual);$expectedHash=[Security.Cryptography.SHA256]::HashData($expected);$matched=$matched -or [Security.Cryptography.CryptographicOperations]::FixedTimeEquals($actualHash,$expectedHash)}
        finally {[Array]::Clear($actual,0,$actual.Length);[Array]::Clear($expected,0,$expected.Length);if($actualHash){[Array]::Clear($actualHash,0,$actualHash.Length)};if($expectedHash){[Array]::Clear($expectedHash,0,$expectedHash.Length)}}
    }
    return $matched
}

function ConvertTo-LabAiSharedGatewaySessionUpstreamBody {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Json,[Parameter(Mandatory)][string]$ExpectedModel)
    try {ConvertTo-LabAiOvmsGatewayUpstreamBody -Json $Json -ExpectedModel $ExpectedModel}
    catch {
        if($_.Exception.Message -ceq 'AI_OVMS_GATEWAY_RUNTIME_MODEL_MISMATCH'){throw 'AI_SHARED_GATEWAY_SESSION_RUNTIME_MODEL_MISMATCH'}
        throw 'AI_SHARED_GATEWAY_SESSION_PAYLOAD_INVALID'
    }
}

function ConvertFrom-LabAiSharedGatewaySessionUpstreamResponse {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Json,[Parameter(Mandatory)][string]$ExpectedModel,[Parameter(Mandatory)][int]$Dimension)
    try {ConvertFrom-LabAiOvmsGatewayUpstreamResponse -Json $Json -ExpectedModel $ExpectedModel -Dimension $Dimension}
    catch {
        switch($_.Exception.Message){
            'AI_OVMS_GATEWAY_RUNTIME_MODEL_MISMATCH' {throw 'AI_SHARED_GATEWAY_SESSION_RUNTIME_MODEL_MISMATCH'}
            'AI_OVMS_GATEWAY_DIMENSION_MISMATCH' {throw 'AI_SHARED_GATEWAY_SESSION_DIMENSION_MISMATCH'}
            'AI_OVMS_GATEWAY_VECTOR_INVALID' {throw 'AI_SHARED_GATEWAY_SESSION_VECTOR_INVALID'}
            default {throw 'AI_SHARED_GATEWAY_SESSION_RESPONSE_INVALID'}
        }
    }
}

function Invoke-LabAiSharedGatewaySessionProbe {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Plan,[Parameter(Mandatory)][SecureString]$ApiKey,[ValidateRange(1,30)][int]$TimeoutSeconds=5)
    $uri=[Uri]$Plan.Location;$tcp=[Net.Sockets.TcpClient]::new();$stream=$null;$plain=$null;$output=$null
    try {
        $task=$tcp.ConnectAsync([Net.IPAddress]::Loopback,$uri.Port)
        if(-not $task.Wait([TimeSpan]::FromSeconds($TimeoutSeconds))){throw 'AI_SHARED_GATEWAY_SESSION_PROBE_TIMEOUT'}
        $expectedPin=[string]$Plan.ServerCertificateSha256
        $validation={param($sender,$certificate,$chain,$errors)if(-not $certificate){return $false};$copy=[Security.Cryptography.X509Certificates.X509Certificate2]::new($certificate);try{$actual=$copy.GetCertHashString([Security.Cryptography.HashAlgorithmName]::SHA256).ToLowerInvariant();return $actual -ceq $expectedPin}finally{$copy.Dispose()}}.GetNewClosure()
        $stream=[Net.Security.SslStream]::new($tcp.GetStream(),$false,$validation)
        $stream.ReadTimeout=$TimeoutSeconds*1000;$stream.WriteTimeout=$TimeoutSeconds*1000
        $stream.AuthenticateAsClient($uri.Host)
        $body=[ordered]@{model=$Plan.RuntimeModel;input=@('SQL Server Lab synthetic shared gateway session probe');encoding_format='float'}|ConvertTo-Json -Compress
        $plain=ConvertFrom-LabSecureString $ApiKey
        $bodyBytes=[Text.Encoding]::UTF8.GetBytes($body)
        $header=[Text.Encoding]::ASCII.GetBytes("POST /v1/embeddings HTTP/1.1`r`nHost: $($uri.Host):$($uri.Port)`r`nAuthorization: Bearer $plain`r`nContent-Type: application/json`r`nContent-Length: $($bodyBytes.Length)`r`nConnection: close`r`n`r`n")
        try{$stream.Write($header,0,$header.Length);$stream.Write($bodyBytes,0,$bodyBytes.Length);$stream.Flush()}finally{[Array]::Clear($header,0,$header.Length);$plain=$null}
        $output=[IO.MemoryStream]::new();$buffer=[byte[]]::new(8192)
        do{$read=$stream.Read($buffer,0,$buffer.Length);if($output.Length+$read -gt 1MB){throw 'AI_SHARED_GATEWAY_SESSION_PROBE_INVALID'};if($read){$output.Write($buffer,0,$read)}}while($read)
        $response=[Text.UTF8Encoding]::new($false,$true).GetString($output.ToArray())
        $separator=$response.IndexOf("`r`n`r`n",[StringComparison]::Ordinal)
        if($separator -lt 0 -or -not $response.StartsWith('HTTP/1.1 200 ',[StringComparison]::Ordinal)){throw 'AI_SHARED_GATEWAY_SESSION_PROBE_INVALID'}
        $json=$response.Substring($separator+4);$null=ConvertFrom-LabAiSharedGatewaySessionUpstreamResponse -Json $json -ExpectedModel $Plan.RuntimeModel -Dimension ([int]$Plan.Dimension)
    }
    catch {if($_.Exception.Message -like 'AI_SHARED_GATEWAY_SESSION_*'){throw};throw 'AI_SHARED_GATEWAY_SESSION_PROBE_FAILED'}
    finally {$plain=$null;if($output){$output.Dispose()};if($stream){$stream.Dispose()};$tcp.Dispose()}
}

function Test-LabAiSharedGatewaySessionListenerOwner {
    param([int]$Port,[int]$ProcessId)
    if(Get-Command Test-LabLlamaCppListenerOwner -CommandType Function -ErrorAction SilentlyContinue){return Test-LabLlamaCppListenerOwner -Port $Port -ProcessId $ProcessId}
    if($IsWindows){return [bool]@(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue|Where-Object OwningProcess -eq $ProcessId).Count}
    return $false
}

function Stop-LabAiSharedGatewaySession {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$OperationId)
    if(-not $script:AiSharedGatewaySessions -or -not $script:AiSharedGatewaySessions.ContainsKey($OperationId)){throw 'AI_SHARED_GATEWAY_SESSION_OWNERSHIP_NOT_FOUND'}
    $session=$script:AiSharedGatewaySessions[$OperationId];$worker=$session.Worker;$clean=$false
    try {
        if(-not $worker.HasExited){$worker.StandardInput.Close()}
        if(-not $worker.WaitForExit(20000)){$worker.Kill($true);if(-not $worker.WaitForExit(10000)){throw 'AI_SHARED_GATEWAY_SESSION_RECOVERY_REQUIRED'}}
        $same=Get-Process -Id $worker.Id -ErrorAction SilentlyContinue
        if($same -and $same.StartTime.ToUniversalTime().Ticks -eq $session.StartedAtUtcTicks){throw 'AI_SHARED_GATEWAY_SESSION_RECOVERY_REQUIRED'}
        if(Test-LabAiSharedGatewaySessionListenerOwner -Port $session.Port -ProcessId $worker.Id){throw 'AI_SHARED_GATEWAY_SESSION_RECOVERY_REQUIRED'}
        $root=[IO.Path]::GetFullPath($session.OperationRoot);$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
        if(-not $root.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($root) -notmatch '^sql-lab-shared-gateway-session-[a-f0-9-]{36}$'){throw 'AI_SHARED_GATEWAY_SESSION_RECOVERY_REQUIRED'}
        if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}
        $script:AiSharedGatewaySessions.Remove($OperationId);$clean=$true
        [pscustomobject][ordered]@{Contract='SqlServerLab.AiSharedGatewaySessionCleanup/1.0';OperationId=$OperationId;Status='CLEANUP_SUCCEEDED'}
    }
    finally {if($clean){$worker.Dispose()}}
}

function Start-LabAiSharedGatewaySession {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Plan,[Parameter(Mandatory)][hashtable]$ApiKeyByReference,[string]$StateRoot,
        [SecureString]$UpstreamApiKey,[ValidateRange(1,300)][int]$StartTimeoutSeconds=30,
        [ValidateRange(30,3600)][int]$LeaseSeconds=900
    )
    if(-not $IsWindows -and -not $IsLinux){throw 'AI_SHARED_GATEWAY_SESSION_PLATFORM_UNSUPPORTED'}
    if($LeaseSeconds -le $StartTimeoutSeconds){throw 'AI_SHARED_GATEWAY_SESSION_LEASE_MUST_EXCEED_START_TIMEOUT'}
    $canonical=Resolve-LabAiSharedGatewayPlan $Plan;if(-not $StateRoot){$StateRoot=Get-LabStateRoot}
    $root=Assert-LabAiSharedGatewayStoragePath $StateRoot;$gatewayRoot=Join-Path (Join-Path $root 'shared-ai-gateways') $canonical.GatewayId
    $storage=Read-LabAiSharedGatewayRegistration -Directory $gatewayRoot -ExpectedPlan $canonical
    if($UpstreamApiKey){$upstreamPlain=ConvertFrom-LabSecureString $UpstreamApiKey;try{if($upstreamPlain -cnotmatch '^[A-Za-z0-9_-]{24,256}$'){throw 'AI_SHARED_GATEWAY_SESSION_UPSTREAM_API_KEY_INVALID'}}finally{$upstreamPlain=$null}}
    $upstream=Test-LabAiSharedGatewayUpstream -Plan $canonical -StateRoot $root -ApiKey $UpstreamApiKey -TimeoutSeconds $StartTimeoutSeconds
    $uri=[Uri]$canonical.Location;$port=[int]$uri.Port
    if($script:AiSharedGatewaySessions -and @($script:AiSharedGatewaySessions.Values|Where-Object {$_.Port -eq $port -or $_.GatewayId -ceq $canonical.GatewayId}).Count){throw 'AI_SHARED_GATEWAY_SESSION_ALREADY_RUNNING'}
    $guard=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,$port);try{$guard.Start()}catch{throw 'AI_SHARED_GATEWAY_SESSION_PORT_UNAVAILABLE'}finally{$guard.Stop()}
    $operationId=[guid]::NewGuid().ToString('D');$ownerNonce=[Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(32)).ToLowerInvariant();$operationRoot=Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-shared-gateway-session-'+$operationId);$null=[IO.Directory]::CreateDirectory($operationRoot);Protect-LabAiSharedGatewayStoragePath $operationRoot
    $worker=$null;$registered=$false;$session=$null;$plainKeys=@()
    try {
        $plainKeys=@(Resolve-LabAiSharedGatewaySessionKeys -Plan $canonical -ApiKeyByReference $ApiKeyByReference)
        $keyPath=Join-Path $operationRoot 'consumer-keys.json';[IO.File]::WriteAllText($keyPath,($plainKeys|ConvertTo-Json -Compress));Protect-LabAiSharedGatewayStoragePath $keyPath -File;$plainKeys=@()
        if($UpstreamApiKey){$upstreamPlain=ConvertFrom-LabSecureString $UpstreamApiKey;try{if($upstreamPlain -cnotmatch '^[A-Za-z0-9_-]{24,256}$'){throw 'AI_SHARED_GATEWAY_SESSION_UPSTREAM_API_KEY_INVALID'};$upstreamPath=Join-Path $operationRoot 'upstream-key.txt';[IO.File]::WriteAllText($upstreamPath,$upstreamPlain);Protect-LabAiSharedGatewayStoragePath $upstreamPath -File}finally{$upstreamPlain=$null}}
        $request=[ordered]@{Contract='SqlServerLab.AiSharedGatewaySessionRequest/1.0';OperationId=$operationId;OwnerNonce=$ownerNonce;Port=$port;UpstreamBackend=$canonical.UpstreamBackend;UpstreamLocation=$canonical.UpstreamLocation;RuntimeModel=$canonical.RuntimeModel;Dimension=$canonical.Dimension;ServerCertificateSha256=$canonical.ServerCertificateSha256;CertificatePath=(Join-Path $gatewayRoot 'server-certificate.pem');PrivateKeyPath=(Join-Path $gatewayRoot 'server-private-key.pem');LeaseSeconds=$LeaseSeconds}
        $requestPath=Join-Path $operationRoot 'request.json';[IO.File]::WriteAllText($requestPath,($request|ConvertTo-Json -Compress));Protect-LabAiSharedGatewayStoragePath $requestPath -File
        $pwsh=(Get-Command pwsh -CommandType Application|Select-Object -First 1).Source;$start=[Diagnostics.ProcessStartInfo]::new($pwsh);$start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardInput=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
        foreach($arg in @('-NoLogo','-NoProfile','-NonInteractive','-File',(Join-Path $script:ModuleRoot 'Tools/Invoke-AiSharedGatewaySessionWorker.ps1'),'-RequestPath',$requestPath)){$start.ArgumentList.Add($arg)}
        $worker=[Diagnostics.Process]::Start($start);$out=$worker.StandardOutput.ReadToEndAsync();$err=$worker.StandardError.ReadToEndAsync();if(-not $script:AiSharedGatewaySessions){$script:AiSharedGatewaySessions=@{}}
        $session=@{Worker=$worker;OperationRoot=$operationRoot;ReceiptPath=(Join-Path $operationRoot 'receipt.json');Port=$port;GatewayId=$canonical.GatewayId;OwnerNonce=$ownerNonce;StartedAtUtcTicks=$worker.StartTime.ToUniversalTime().Ticks;OutTask=$out;ErrTask=$err};$script:AiSharedGatewaySessions[$operationId]=$session;$registered=$true
        $watch=[Diagnostics.Stopwatch]::StartNew();$ready=$false
        while($watch.Elapsed.TotalSeconds -lt $StartTimeoutSeconds){if($worker.HasExited){throw 'AI_SHARED_GATEWAY_SESSION_WORKER_EXITED'};$receipt=if(Test-Path -LiteralPath $session.ReceiptPath){Get-Content -LiteralPath $session.ReceiptPath -Raw|ConvertFrom-Json}else{$null};if($receipt -and ($receipt.OperationId -cne $operationId -or [int]$receipt.ProcessId -ne $worker.Id -or $receipt.OwnerNonce -cne $session.OwnerNonce)){throw 'AI_SHARED_GATEWAY_SESSION_PROCESS_BINDING_INVALID'};if($receipt.Status -ceq 'RUNNING' -and (Test-LabAiSharedGatewaySessionListenerOwner -Port $port -ProcessId $worker.Id)){$firstReference=[string]@($canonical.Consumers)[0].ApiKeyReference;Invoke-LabAiSharedGatewaySessionProbe -Plan $canonical -ApiKey $ApiKeyByReference[$firstReference] -TimeoutSeconds ([Math]::Min(5,$StartTimeoutSeconds));$ready=$true;break};if($receipt.Status -in @('FAILED','STOPPED')){throw 'AI_SHARED_GATEWAY_SESSION_START_FAILED'};Start-Sleep -Milliseconds 100}
        if(-not $ready){throw 'AI_SHARED_GATEWAY_SESSION_START_TIMEOUT'}
        $started=$worker.StartTime.ToUniversalTime().ToString('o');$identity=[ordered]@{Contract='SqlServerLab.AiSharedGatewaySessionReceipt/1.0';OperationId=$operationId;PlanKey=$canonical.PlanKey;StorageReceiptKey=$storage.ReceiptKey;UpstreamReceiptKey=$upstream.ReceiptKey;Location=$canonical.Location;LeaseSeconds=$LeaseSeconds;StartedAtUtc=$started}
        [pscustomobject][ordered]@{Contract=[pscustomobject]@{Name='SqlServerLab.AiSharedGatewaySession';Version='1.0'};Status='SESSION_ENDPOINT_VERIFIED';EvidenceStatus='OWNER_BOUND_LIVE_HTTPS_GATEWAY';OperationId=$operationId;GatewayId=$canonical.GatewayId;PlanKey=$canonical.PlanKey;StorageReceiptKey=$storage.ReceiptKey;UpstreamReceiptKey=$upstream.ReceiptKey;Location=$canonical.Location;RuntimeModel=$canonical.RuntimeModel;Dimension=$canonical.Dimension;ConsumerCount=@($canonical.Consumers).Count;ServerCertificateSha256=$canonical.ServerCertificateSha256;LeaseSeconds=$LeaseSeconds;StartedAtUtc=$started;VerifiedEvidence=@('PROTECTED_SHARED_STORAGE_REVALIDATED','LIVE_LOOPBACK_UPSTREAM','OWNER_BOUND_WORKER','IPV4_LOOPBACK_LISTENER','HTTPS_ENDPOINT_PROBED','ALL_CONSUMER_KEYS_BOUND');PendingEvidence=@('PERSISTENT_GATEWAY_SERVICE','SQL_CONSUMER_BINDINGS','BACKUP_RESTORE','ROTATION','ACCELERATOR_RUNTIME_ATTESTATION');ReceiptKey=Get-LabAiPlanKey $identity}
    }
    catch{$failure=$_.Exception.Message;if($registered){try{$null=Stop-LabAiSharedGatewaySession $operationId}catch{throw "AI_SHARED_GATEWAY_SESSION_RECOVERY_REQUIRED; OperationId=$operationId; OriginalFailure=$failure"}}elseif($worker){if(-not $worker.HasExited){$worker.Kill($true)};$worker.Dispose()};if(Test-Path -LiteralPath $operationRoot){Remove-Item -LiteralPath $operationRoot -Recurse -Force};throw $failure}
    finally {$plainKeys=@()}
}
