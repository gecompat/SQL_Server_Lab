function ConvertTo-LabAiOvmsGatewayUpstreamBody {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Json,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._:/+-]{0,255}$')][string]$ExpectedModel
    )

    if ([Text.Encoding]::UTF8.GetByteCount($Json) -gt 64KB) { throw 'AI_OVMS_GATEWAY_PAYLOAD_INVALID' }
    try { $document=[Text.Json.JsonDocument]::Parse($Json) }
    catch { throw 'AI_OVMS_GATEWAY_PAYLOAD_INVALID' }
    try {
        if ($document.RootElement.ValueKind -ne [Text.Json.JsonValueKind]::Object) { throw 'AI_OVMS_GATEWAY_PAYLOAD_INVALID' }
        $properties=[Collections.Generic.Dictionary[string,Text.Json.JsonElement]]::new([StringComparer]::Ordinal)
        foreach($property in $document.RootElement.EnumerateObject()) {
            if ($property.Name -cnotin @('model','input','encoding_format') -or $properties.ContainsKey($property.Name)) {
                throw 'AI_OVMS_GATEWAY_PAYLOAD_INVALID'
            }
            $properties.Add($property.Name,$property.Value)
        }
        if (-not $properties.ContainsKey('model') -or -not $properties.ContainsKey('input')) { throw 'AI_OVMS_GATEWAY_PAYLOAD_INVALID' }
        if ($properties['model'].ValueKind -ne [Text.Json.JsonValueKind]::String -or
            $properties['model'].GetString() -cne $ExpectedModel) { throw 'AI_OVMS_GATEWAY_RUNTIME_MODEL_MISMATCH' }
        if ($properties.ContainsKey('encoding_format') -and
            ($properties['encoding_format'].ValueKind -ne [Text.Json.JsonValueKind]::String -or
             $properties['encoding_format'].GetString() -cne 'float')) { throw 'AI_OVMS_GATEWAY_PAYLOAD_INVALID' }

        $inputs=[Collections.Generic.List[string]]::new()
        $input=$properties['input']
        if ($input.ValueKind -eq [Text.Json.JsonValueKind]::String) { $inputs.Add($input.GetString()) }
        elseif ($input.ValueKind -eq [Text.Json.JsonValueKind]::Array) {
            foreach($item in $input.EnumerateArray()) {
                if ($item.ValueKind -ne [Text.Json.JsonValueKind]::String) { throw 'AI_OVMS_GATEWAY_PAYLOAD_INVALID' }
                $inputs.Add($item.GetString())
            }
        }
        else { throw 'AI_OVMS_GATEWAY_PAYLOAD_INVALID' }
        if ($inputs.Count -ne 1 -or [string]::IsNullOrEmpty($inputs[0]) -or $inputs[0].Length -gt 8192 -or
            [Text.Encoding]::UTF8.GetByteCount($inputs[0]) -gt 32768) { throw 'AI_OVMS_GATEWAY_PAYLOAD_INVALID' }
        return ([ordered]@{model=$ExpectedModel;input=@($inputs[0]);encoding_format='float'}|ConvertTo-Json -Depth 5 -Compress)
    }
    finally { $document.Dispose() }
}

function ConvertFrom-LabAiOvmsGatewayUpstreamResponse {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Json,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._:/+-]{0,255}$')][string]$ExpectedModel,
        [Parameter(Mandatory)][ValidateRange(1,1998)][int]$Dimension
    )

    if ([Text.Encoding]::UTF8.GetByteCount($Json) -gt 1MB) { throw 'AI_OVMS_GATEWAY_RESPONSE_INVALID' }
    try { $document=[Text.Json.JsonDocument]::Parse($Json) }
    catch { throw 'AI_OVMS_GATEWAY_RESPONSE_INVALID' }
    try {
        if ($document.RootElement.ValueKind -ne [Text.Json.JsonValueKind]::Object) { throw 'AI_OVMS_GATEWAY_RESPONSE_INVALID' }
        $properties=[Collections.Generic.Dictionary[string,Text.Json.JsonElement]]::new([StringComparer]::Ordinal)
        foreach($property in $document.RootElement.EnumerateObject()) {
            if ($properties.ContainsKey($property.Name)) { throw 'AI_OVMS_GATEWAY_RESPONSE_INVALID' }
            $properties.Add($property.Name,$property.Value)
        }
        if (-not $properties.ContainsKey('model') -or $properties['model'].ValueKind -ne [Text.Json.JsonValueKind]::String -or
            $properties['model'].GetString() -cne $ExpectedModel) { throw 'AI_OVMS_GATEWAY_RUNTIME_MODEL_MISMATCH' }
        if (-not $properties.ContainsKey('data') -or $properties['data'].ValueKind -ne [Text.Json.JsonValueKind]::Array -or
            $properties['data'].GetArrayLength() -ne 1) { throw 'AI_OVMS_GATEWAY_RESPONSE_INVALID' }
        $entry=$properties['data'][0]
        if ($entry.ValueKind -ne [Text.Json.JsonValueKind]::Object) { throw 'AI_OVMS_GATEWAY_RESPONSE_INVALID' }
        $embedding=$null;$embeddingCount=0;$index=0;$indexCount=0
        foreach($property in $entry.EnumerateObject()) {
            if ($property.Name -ceq 'embedding') {$embedding=$property.Value;$embeddingCount++}
            elseif($property.Name -ceq 'index') {
                $indexCount++
                if($indexCount -ne 1 -or $property.Value.ValueKind -ne [Text.Json.JsonValueKind]::Number -or -not $property.Value.TryGetInt32([ref]$index) -or $index -ne 0){throw 'AI_OVMS_GATEWAY_RESPONSE_INVALID'}
            }
        }
        if ($embeddingCount -ne 1 -or $embedding.ValueKind -ne [Text.Json.JsonValueKind]::Array -or
            $embedding.GetArrayLength() -ne $Dimension) { throw 'AI_OVMS_GATEWAY_DIMENSION_MISMATCH' }
        $vector=[Collections.Generic.List[double]]::new()
        foreach($element in $embedding.EnumerateArray()) {
            $number=0.0
            if($element.ValueKind -ne [Text.Json.JsonValueKind]::Number -or -not $element.TryGetDouble([ref]$number) -or
               [double]::IsNaN($number) -or [double]::IsInfinity($number) -or [Math]::Abs($number) -gt [float]::MaxValue) {
                throw 'AI_OVMS_GATEWAY_VECTOR_INVALID'
            }
            $vector.Add($number)
        }
        return ([ordered]@{object='list';data=@([ordered]@{object='embedding';index=0;embedding=@($vector)});model=$ExpectedModel}|ConvertTo-Json -Depth 8 -Compress)
    }
    finally { $document.Dispose() }
}

function Stop-LabAiOvmsHttpsGateway {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$OperationId)
    if(-not $script:AiOvmsGatewaySessions -or -not $script:AiOvmsGatewaySessions.ContainsKey($OperationId)){throw 'AI_OVMS_GATEWAY_OWNERSHIP_NOT_FOUND'}
    $session=$script:AiOvmsGatewaySessions[$OperationId];$worker=$session.Worker;$cleanupSucceeded=$false
    try {
        if(-not $worker.HasExited){$worker.StandardInput.Close()}
        if(-not $worker.WaitForExit(20000)){$worker.Kill();if(-not $worker.WaitForExit(10000)){throw 'AI_OVMS_GATEWAY_RECOVERY_REQUIRED'}}
        $sameProcess=Get-Process -Id $worker.Id -ErrorAction SilentlyContinue
        if($sameProcess -and $sameProcess.StartTime.ToUniversalTime().Ticks -eq $session.StartedAtUtcTicks){throw 'AI_OVMS_GATEWAY_RECOVERY_REQUIRED'}
        if(@(Get-NetTCPConnection -LocalPort $session.Port -State Listen -ErrorAction SilentlyContinue|Where-Object OwningProcess -eq $worker.Id).Count){throw 'AI_OVMS_GATEWAY_RECOVERY_REQUIRED'}
        $keyPath=Join-Path $session.OperationRoot 'api-key.txt';if(Test-Path -LiteralPath $keyPath){Remove-Item -LiteralPath $keyPath -Force}
        $script:AiOvmsGatewaySessions.Remove($OperationId);$cleanupSucceeded=$true
        [PSCustomObject]@{Contract='SqlServerLab.AiOvmsHttpsGatewayCleanup/1.0';OperationId=$OperationId;Status='CLEANUP_SUCCEEDED'}
    }
    finally {if($cleanupSucceeded){$worker.Dispose()}}
}

function Start-LabAiOvmsHttpsGateway {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$UpstreamLocation,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._:/+-]{0,255}$')][string]$RuntimeModel,
        [Parameter(Mandatory)][ValidateRange(1,1998)][int]$Dimension,
        [Parameter(Mandatory)][ValidateRange(1024,65535)][int]$Port,
        [Parameter(Mandatory)][string]$CertificatePath,
        [Parameter(Mandatory)][string]$PrivateKeyPath,
        [Parameter(Mandatory)][SecureString]$ApiKey,
        [string]$TrustedRootPath,
        [ValidateRange(1,300)][int]$StartTimeoutSeconds=30,
        [ValidateRange(30,3600)][int]$LeaseSeconds=900
    )
    if(-not $IsWindows){throw 'AI_OVMS_GATEWAY_WINDOWS_REQUIRED'}
    if($LeaseSeconds -le $StartTimeoutSeconds){throw 'AI_OVMS_GATEWAY_LEASE_MUST_EXCEED_START_TIMEOUT'}
    $upstreamUri=Resolve-LabAiOvmsUpstreamLocation -Location $UpstreamLocation
    $upstreamReceipt=Invoke-LabAiOvmsUpstreamProbe -Location $upstreamUri.AbsoluteUri -RuntimeModel $RuntimeModel -Dimension $Dimension -TimeoutSeconds $StartTimeoutSeconds
    foreach($path in @($CertificatePath,$PrivateKeyPath)){$item=Get-Item -LiteralPath $path -ErrorAction Stop;if($item -isnot [IO.FileInfo] -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'AI_OVMS_GATEWAY_INPUT_FILE_INVALID'}}
    $CertificatePath=(Get-Item -LiteralPath $CertificatePath).FullName;$PrivateKeyPath=(Get-Item -LiteralPath $PrivateKeyPath).FullName
    $certificate=[Security.Cryptography.X509Certificates.X509Certificate2]::CreateFromPemFile($CertificatePath,$PrivateKeyPath)
    try {if(-not $certificate.HasPrivateKey){throw 'AI_OVMS_GATEWAY_CERTIFICATE_KEY_MISMATCH'};$pin=$certificate.GetCertHashString([Security.Cryptography.HashAlgorithmName]::SHA256).ToLowerInvariant()} finally {$certificate.Dispose()}
    $rootCertificate=$null
    if($TrustedRootPath){$rootItem=Get-Item -LiteralPath $TrustedRootPath -ErrorAction Stop;if($rootItem -isnot [IO.FileInfo] -or ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'AI_OVMS_GATEWAY_INPUT_FILE_INVALID'};$rootCertificate=[Security.Cryptography.X509Certificates.X509Certificate2]::CreateFromPem([IO.File]::ReadAllText($rootItem.FullName))}
    $portGuard=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,$Port);try{$portGuard.Start()}catch{throw 'AI_OVMS_GATEWAY_PORT_UNAVAILABLE'}finally{$portGuard.Stop()}
    $operationId=[guid]::NewGuid().ToString('D');$operationRoot=Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-ovms-gateway-'+$operationId)
    $null=[IO.Directory]::CreateDirectory($operationRoot)
    $acl=[Security.AccessControl.DirectorySecurity]::new();$acl.SetAccessRuleProtection($true,$false);$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid,'FullControl','ContainerInherit,ObjectInherit','None','Allow'));Set-Acl -LiteralPath $operationRoot -AclObject $acl
    $keyPath=Join-Path $operationRoot 'api-key.txt';$worker=$null;$registered=$false
    try {
        $plain=ConvertFrom-LabSecureString $ApiKey
        try {if($plain -notmatch '^[A-Za-z0-9_-]{24,256}$'){throw 'AI_OVMS_GATEWAY_API_KEY_FORMAT'};[IO.File]::WriteAllText($keyPath,$plain)}finally{$plain=$null}
        $request=[ordered]@{Contract='SqlServerLab.AiOvmsHttpsGatewayRequest/1.0';OperationId=$operationId;UpstreamLocation=$upstreamUri.AbsoluteUri;ModelName=$RuntimeModel;Dimension=$Dimension;Port=$Port;CertificatePath=$CertificatePath;PrivateKeyPath=$PrivateKeyPath;LeaseSeconds=$LeaseSeconds}
        $requestPath=Join-Path $operationRoot 'request.json';[IO.File]::WriteAllText($requestPath,($request|ConvertTo-Json -Compress))
        $pwsh=(Get-Command pwsh -CommandType Application|Select-Object -First 1).Source;$start=[Diagnostics.ProcessStartInfo]::new($pwsh)
        $start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardInput=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
        foreach($arg in @('-NoLogo','-NoProfile','-NonInteractive','-File',(Join-Path $script:ModuleRoot 'Tools/Invoke-OvmsHttpsGatewayWorker.ps1'),'-RequestPath',$requestPath)){$start.ArgumentList.Add($arg)}
        $worker=[Diagnostics.Process]::Start($start);$out=$worker.StandardOutput.ReadToEndAsync();$err=$worker.StandardError.ReadToEndAsync()
        if(-not $script:AiOvmsGatewaySessions){$script:AiOvmsGatewaySessions=@{}}
        $session=@{Worker=$worker;OperationRoot=$operationRoot;ReceiptPath=(Join-Path $operationRoot 'receipt.json');Port=$Port;StartedAtUtcTicks=$worker.StartTime.ToUniversalTime().Ticks;OutTask=$out;ErrTask=$err}
        $script:AiOvmsGatewaySessions[$operationId]=$session;$registered=$true
        $watch=[Diagnostics.Stopwatch]::StartNew();$verified=$false;$location="https://127.0.0.1:$Port/v3/embeddings"
        while($watch.Elapsed.TotalSeconds -lt $StartTimeoutSeconds){
            if($worker.HasExited){throw 'AI_OVMS_GATEWAY_WORKER_EXITED'}
            $receipt=if(Test-Path -LiteralPath $session.ReceiptPath){Get-Content -LiteralPath $session.ReceiptPath -Raw|ConvertFrom-Json}else{$null}
            if($receipt.Status -eq 'RUNNING'){
                $listeners=@(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)
                if($listeners.Count -and @($listeners|Where-Object OwningProcess -ne $worker.Id).Count){throw 'AI_OVMS_GATEWAY_PORT_OWNERSHIP_MISMATCH'}
                if($listeners.Count){
                    try {$response=Invoke-LabAiExternalModelHttpTransport -Location $location -ExpectedServerCertificateSha256 $pin -ApiKey $ApiKey -TrustedRootCertificate $rootCertificate -Request @{Method='POST';TimeoutSeconds=5;Body=@{model=$RuntimeModel;input=@('SQL Server Lab synthetic gateway probe');encoding_format='float'}}
                        if($response.StatusCode -ne 200 -or [string]$response.Body.model -cne $RuntimeModel -or @($response.Body.data).Count -ne 1 -or @($response.Body.data[0].embedding).Count -ne $Dimension){throw 'AI_OVMS_GATEWAY_RESPONSE_INVALID'}
                        $verified=$true;break
                    }catch [Net.Http.HttpRequestException]{}catch [Threading.Tasks.TaskCanceledException]{}
                }
            }elseif($receipt.Status -in @('FAILED','STOPPED')){throw 'AI_OVMS_GATEWAY_START_FAILED'}
            Start-Sleep -Milliseconds 100
        }
        if(-not $verified){throw 'AI_OVMS_GATEWAY_START_TIMEOUT'}
        $binding=Get-LabAiPlanKey -InputObject ([ordered]@{Contract='SqlServerLab.AiOvmsHttpsGatewayBinding/1.0';UpstreamBindingKey=$upstreamReceipt.BindingKey;Location=$location;RuntimeModel=$RuntimeModel;Dimension=$Dimension;ServerCertificateSha256=$pin})
        [PSCustomObject]@{Contract='SqlServerLab.AiOvmsHttpsGateway/1.0';OperationId=$operationId;Status='ENDPOINT_VERIFIED';Location=$location;RuntimeModel=$RuntimeModel;Dimension=$Dimension;ServerCertificateSha256=$pin;LeaseSeconds=$LeaseSeconds;BindingKey=$binding}
    }
    catch {$failure=$_.Exception.Message;if($registered){try{$null=Stop-LabAiOvmsHttpsGateway $operationId;if($session.ErrTask.IsCompleted){$diagnostic=[string]$session.ErrTask.GetAwaiter().GetResult();if($diagnostic.Length -gt 4096){$diagnostic=$diagnostic.Substring(0,4096)};[IO.File]::WriteAllText((Join-Path $operationRoot 'worker-diagnostic.log'),$diagnostic)}}catch{throw "AI_OVMS_GATEWAY_RECOVERY_REQUIRED; OperationId=$operationId; OriginalFailure=$failure"}}elseif($worker){if(-not $worker.HasExited){$worker.Kill()};$worker.Dispose()};if(Test-Path -LiteralPath $keyPath){Remove-Item -LiteralPath $keyPath -Force};throw $failure}
    finally {if($rootCertificate){$rootCertificate.Dispose()}}
}

# Module removal closes every owner channel; each worker then removes its secret.
if($ExecutionContext.SessionState.Module){$ExecutionContext.SessionState.Module.OnRemove={if($script:AiOvmsGatewaySessions){foreach($session in @($script:AiOvmsGatewaySessions.Values)){try{if(-not $session.Worker.HasExited){$session.Worker.StandardInput.Close()}}catch{}}}}}
