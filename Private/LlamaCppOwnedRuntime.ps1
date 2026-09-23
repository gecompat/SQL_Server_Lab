function Stop-LabLlamaCppOwnedRuntime {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$OperationId)
    if(-not $script:LlamaCppOwnedSessions -or -not $script:LlamaCppOwnedSessions.ContainsKey($OperationId)){throw 'LLAMA_OWNERSHIP_NOT_FOUND'}
    $session=$script:LlamaCppOwnedSessions[$OperationId]
    $worker=$session.Worker;$cleanupSucceeded=$false
    try {
        if(-not $worker.HasExited){$worker.StandardInput.Close()}
        if(-not $worker.WaitForExit(20000)){$worker.Kill();if(-not $worker.WaitForExit(10000)){throw 'LLAMA_RECOVERY_REQUIRED'}}
        # Job closure has terminated descendants. Never kill by an externally supplied PID.
        $receipt=if(Test-Path -LiteralPath $session.ReceiptPath){Get-Content -LiteralPath $session.ReceiptPath -Raw|ConvertFrom-Json}else{$null}
        if($receipt -and $receipt.ProcessId){
            $exitWatch=[Diagnostics.Stopwatch]::StartNew()
            do {
                $childProcess=Get-Process -Id $receipt.ProcessId -ErrorAction SilentlyContinue
                $sameProcess=$childProcess -and $childProcess.StartTime.ToUniversalTime().Ticks -eq $receipt.StartedAtUtcTicks
                if(-not $sameProcess){break}
                Start-Sleep -Milliseconds 100
            } while($exitWatch.Elapsed.TotalSeconds -lt 5)
            if($sameProcess){throw 'LLAMA_RECOVERY_REQUIRED'}
            $remaining=@(Get-NetTCPConnection -LocalPort $session.Port -State Listen -ErrorAction SilentlyContinue|Where-Object OwningProcess -eq $receipt.ProcessId)
            if($remaining.Count){throw 'LLAMA_RECOVERY_REQUIRED'}
        }
        $keyPath=Join-Path $session.OperationRoot 'api-key.txt'
        if(Test-Path -LiteralPath $keyPath){Remove-Item -LiteralPath $keyPath -Force}
        $script:LlamaCppOwnedSessions.Remove($OperationId);$cleanupSucceeded=$true
        [PSCustomObject]@{Contract='SqlServerLab.LlamaCppCleanup/1.0';OperationId=$OperationId;Status='CLEANUP_SUCCEEDED'}
    }
    finally {if($cleanupSucceeded){$worker.Dispose()}}
}

function Start-LabLlamaCppOwnedRuntime {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RuntimeDirectory,
        [Parameter(Mandatory)][ValidateSet('LlamaCppCuda','LlamaCppOpenVino')][string]$Backend,
        [Parameter(Mandatory)][ValidateSet('CPU','GPU','NPU')][string]$Accelerator,
        [Parameter(Mandatory)][string]$ModelPath,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$')][string]$ModelName,
        [Parameter(Mandatory)][ValidateRange(1,1998)][int]$Dimension,
        [Parameter(Mandatory)][ValidateSet('mean','cls','last')][string]$Pooling,
        [Parameter(Mandatory)][ValidateRange(1024,65535)][int]$Port,
        [Parameter(Mandatory)][string]$CertificatePath,
        [Parameter(Mandatory)][string]$PrivateKeyPath,
        [Parameter(Mandatory)][SecureString]$ApiKey,
        [string]$TrustedRootPath,
        [ValidateRange(1,600)][int]$StartTimeoutSeconds=120,
        [ValidateRange(30,3600)][int]$LeaseSeconds=900,
        [ValidateRange(32,8192)][int]$ContextSize=512,
        [switch]$CaptureArtifactEvidence
    )
    if(-not $IsWindows){throw 'LLAMA_WINDOWS_REQUIRED'}
    if($LeaseSeconds -le $StartTimeoutSeconds){throw 'LLAMA_LEASE_MUST_EXCEED_START_TIMEOUT'}
    $runtime=@(Find-LabLlamaCppRuntime -SearchRoot $RuntimeDirectory | Where-Object InstallationPath -eq ([IO.Path]::GetFullPath($RuntimeDirectory).TrimEnd('\')))
    if($runtime.Count -ne 1 -or $runtime[0].Backend -ne $Backend){throw 'LLAMA_RUNTIME_SELECTION_MISMATCH'}
    if($Backend -eq 'LlamaCppCuda' -and $Accelerator -eq 'NPU'){throw 'LLAMA_ACCELERATOR_UNSUPPORTED'}
    $runtime=$runtime[0]
    foreach($path in @($ModelPath,$CertificatePath,$PrivateKeyPath)) {
        $item=Get-Item -LiteralPath $path -ErrorAction Stop
        if($item -isnot [IO.FileInfo] -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'LLAMA_INPUT_FILE_INVALID'}
    }
    $ModelPath=(Get-Item -LiteralPath $ModelPath).FullName
    $CertificatePath=(Get-Item -LiteralPath $CertificatePath).FullName
    $PrivateKeyPath=(Get-Item -LiteralPath $PrivateKeyPath).FullName
    $stream=[IO.File]::OpenRead($ModelPath)
    try{$magic=[byte[]]::new(4);if($stream.Read($magic,0,4) -ne 4 -or [Text.Encoding]::ASCII.GetString($magic) -cne 'GGUF'){throw 'LLAMA_GGUF_REQUIRED'}}finally{$stream.Dispose()}
    $certificate=[Security.Cryptography.X509Certificates.X509Certificate2]::CreateFromPemFile($CertificatePath,$PrivateKeyPath)
    try{$pin=$certificate.GetCertHashString([Security.Cryptography.HashAlgorithmName]::SHA256).ToLowerInvariant()}finally{$certificate.Dispose()}
    $rootCertificate=$null
    if($TrustedRootPath){$rootCertificate=[Security.Cryptography.X509Certificates.X509Certificate2]::CreateFromPem([IO.File]::ReadAllText((Get-Item -LiteralPath $TrustedRootPath).FullName))}
    $portGuard=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,$Port)
    try{$portGuard.Start()}catch{throw 'LLAMA_PORT_UNAVAILABLE'}finally{$portGuard.Stop()}
    $operationId=[guid]::NewGuid().ToString('D')
    $operationRoot=Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-llama-owned-'+$operationId)
    $null=[IO.Directory]::CreateDirectory($operationRoot)
    $acl=[Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true,$false)
    $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User
    $rule=[Security.AccessControl.FileSystemAccessRule]::new($sid,'FullControl','ContainerInherit,ObjectInherit','None','Allow')
    $acl.AddAccessRule($rule)
    Set-Acl -LiteralPath $operationRoot -AclObject $acl
    $keyPath=Join-Path $operationRoot 'api-key.txt'
    $worker=$null;$registered=$false;$modelReadLock=$null;$runtimeReadLock=$null
    try {
        $modelReadLock=[IO.File]::Open($ModelPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        $runtimeReadLock=[IO.File]::Open($runtime.Invocation,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        $plain=ConvertFrom-LabSecureString $ApiKey
        try{if($plain -notmatch '^[A-Za-z0-9_-]{24,256}$'){throw 'LLAMA_API_KEY_FORMAT'};[IO.File]::WriteAllText($keyPath,$plain)}finally{$plain=$null}
        $environment=@{}
        $device=if($Accelerator -eq 'CPU' -and $Backend -eq 'LlamaCppCuda'){'none'}elseif($Backend -eq 'LlamaCppCuda'){'CUDA0'}else{'OPENVINO0'}
        $layers=if($device -eq 'none'){'0'}else{'999'}
        if($Backend -eq 'LlamaCppOpenVino') {$environment=Get-LabLlamaCppOpenVinoEnvironment -Accelerator $Accelerator -OperationRoot $operationRoot}
        $arguments=@('--model',$ModelPath,'--alias',$ModelName,'--embedding','--pooling',$Pooling,
            '--ctx-size',[string]$ContextSize,'--batch-size',[string]$ContextSize,'--ubatch-size',[string]$ContextSize,
            '--parallel','1','--device',$device,'--gpu-layers',$layers,'--fit','off','--offline','--log-verbosity','4',
            '--host','127.0.0.1','--port',[string]$Port,'--ssl-cert-file',$CertificatePath,
            '--ssl-key-file',$PrivateKeyPath,'--api-key-file',$keyPath,'--no-webui')
        $request=[ordered]@{Contract='SqlServerLab.LlamaCppOwnedRequest/1.0';CleanupPolicy='OWN_JOB_TERMINATE_AND_REMOVE_API_KEY';OperationId=$operationId;Invocation=$runtime.Invocation;Arguments=$arguments;Environment=$environment;LeaseSeconds=$LeaseSeconds;StartTimeoutSeconds=$StartTimeoutSeconds}
        $requestPath=Join-Path $operationRoot 'request.json'
        [IO.File]::WriteAllText($requestPath,($request|ConvertTo-Json -Depth 10))
        $start=[Diagnostics.ProcessStartInfo]::new((Get-Command pwsh -CommandType Application | Select-Object -First 1).Source)
        $start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardInput=$true
        $start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
        foreach($arg in @('-NoProfile','-NonInteractive','-File',(Join-Path $script:ModuleRoot 'Tools/Invoke-LlamaCppOwnedWorker.ps1'),'-RequestPath',$requestPath)){$start.ArgumentList.Add($arg)}
        $worker=[Diagnostics.Process]::Start($start)
        $out=$worker.StandardOutput.ReadToEndAsync();$err=$worker.StandardError.ReadToEndAsync()
        if(-not $script:LlamaCppOwnedSessions){$script:LlamaCppOwnedSessions=@{}}
        $session=@{Worker=$worker;OperationRoot=$operationRoot;ReceiptPath=(Join-Path $operationRoot 'receipt.json');Port=$Port;OutTask=$out;ErrTask=$err}
        $script:LlamaCppOwnedSessions[$operationId]=$session;$registered=$true
        $watch=[Diagnostics.Stopwatch]::StartNew();$verified=$false
        $location="https://127.0.0.1:$Port/v1/embeddings"
        while($watch.Elapsed.TotalSeconds -lt $StartTimeoutSeconds) {
            if($worker.HasExited){throw 'LLAMA_WORKER_EXITED'}
            $receipt=if(Test-Path -LiteralPath $session.ReceiptPath){Get-Content -LiteralPath $session.ReceiptPath -Raw|ConvertFrom-Json}else{$null}
            if($receipt.Status -eq 'RUNNING') {
                $listeners=@(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)
                if($listeners.Count -and @($listeners|Where-Object OwningProcess -ne $receipt.ProcessId).Count){throw 'LLAMA_PORT_OWNERSHIP_MISMATCH'}
                if($listeners.Count) {
                    try {
                        $common=@{ExpectedServerCertificateSha256=$pin;ApiKey=$ApiKey;TrustedRootCertificate=$rootCertificate}
                        $models=Invoke-LabAiExternalModelHttpTransport @common -Location "https://127.0.0.1:$Port/v1/models" -Request @{Method='GET';TimeoutSeconds=2}
                        if($models.StatusCode -eq 503){Start-Sleep -Milliseconds 200;continue}
                        if($models.StatusCode -ne 200 -or @($models.Body.data).Count -ne 1 -or $models.Body.data[0].id -cne $ModelName){throw 'LLAMA_MODEL_IDENTITY_MISMATCH'}
                        $response=Invoke-LabAiExternalModelHttpTransport @common -Location $location -Request @{Method='POST';TimeoutSeconds=5;Body=@{model=$ModelName;input=@('SQL Server Lab synthetic embedding probe');encoding_format='float'}}
                        if($response.StatusCode -ne 200) {
                            $computeLog=Get-Content -LiteralPath (Join-Path $operationRoot 'stderr.log') -Raw -ErrorAction SilentlyContinue
                            if(Test-LabLlamaCppComputeFailureLog -Log $computeLog -Backend $Backend -Accelerator $Accelerator){throw 'LLAMA_ACCELERATOR_COMPUTE_FAILED'}
                            throw 'LLAMA_EMBEDDING_RESPONSE_INVALID'
                        }
                        if($response.Body.model -cne $ModelName){throw 'LLAMA_EMBEDDING_RESPONSE_INVALID'}
                        $data=@($response.Body.data)
                        if($data.Count -ne 1 -or @($data[0].embedding).Count -ne $Dimension){throw 'LLAMA_DIMENSION_MISMATCH'}
                        foreach($value in $data[0].embedding){if($null -eq $value -or -not (Test-LabAiExternalModelNumericValue $value)){throw 'LLAMA_VECTOR_INVALID'}}
                        $verified=$true;break
                    }
                    catch [Net.Http.HttpRequestException] { }
                    catch [Threading.Tasks.TaskCanceledException] { }
                }
            }
            elseif($receipt.Status -in @('FAILED','STOPPED','RECOVERY_REQUIRED')){throw 'LLAMA_START_FAILED'}
            Start-Sleep -Milliseconds 200
        }
        if(-not $verified){throw 'LLAMA_START_TIMEOUT'}
        $log=Get-Content -LiteralPath (Join-Path $operationRoot 'stderr.log') -Raw
        if(-not (Test-LabLlamaCppAcceleratorLog -Log $log -Backend $Backend -Accelerator $Accelerator)){throw 'LLAMA_ACCELERATOR_NOT_VERIFIED'}
        [IO.File]::WriteAllText((Join-Path $operationRoot 'ready'),'ENDPOINT_VERIFIED')
        $artifacts=$null
        if($CaptureArtifactEvidence){$artifacts=[PSCustomObject]@{RuntimeSha256=(Get-LabAiExternalModelFileSha256 $runtime.Invocation RUNTIME);ModelSha256=(Get-LabAiExternalModelFileSha256 $ModelPath MODEL)}}
        if($worker.HasExited -or -not @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue|Where-Object OwningProcess -eq $receipt.ProcessId).Count){throw 'LLAMA_ENDPOINT_LEASE_ENDED'}
        [PSCustomObject]@{Contract='SqlServerLab.LlamaCppOwnedRuntime/1.0';OperationId=$operationId;Status='ENDPOINT_VERIFIED';Backend=$Backend;Accelerator=$Accelerator;ModelName=$ModelName;Dimension=$Dimension;Location=$location;ServerCertificateSha256=$pin;LeaseSeconds=$LeaseSeconds;ArtifactEvidence=$artifacts}
    }
    catch {
        $failure=$_.Exception.Message
        if($registered){try{$null=Stop-LabLlamaCppOwnedRuntime $operationId}catch{throw "LLAMA_RECOVERY_REQUIRED; OperationId=$operationId; OriginalFailure=$failure"}}
        elseif($worker){if(-not $worker.HasExited){$worker.Kill()};$worker.Dispose()}
        if(Test-Path -LiteralPath $keyPath){Remove-Item -LiteralPath $keyPath -Force}
        throw $failure
    }
    finally {if($rootCertificate){$rootCertificate.Dispose()};if($modelReadLock){$modelReadLock.Dispose()};if($runtimeReadLock){$runtimeReadLock.Dispose()}}
}

function Get-LabLlamaCppOpenVinoEnvironment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('CPU','GPU','NPU')][string]$Accelerator,
        [Parameter(Mandatory)][string]$OperationRoot
    )
    $environment=@{
        GGML_OPENVINO_DEVICE=$Accelerator
        GGML_OPENVINO_STATEFUL_EXECUTION='0'
    }
    # Upstream does not support the OpenVINO cache directories on NPU.
    if($Accelerator -ne 'NPU') {
        $environment.GGML_OPENVINO_CACHE_DIR=Join-Path $OperationRoot 'ov-cache'
        $environment.GGML_OPENVINO_MODEL_CACHE_DIR=Join-Path $OperationRoot 'ov-model-cache'
    }
    return $environment
}

function Test-LabLlamaCppComputeFailureLog {
    [CmdletBinding()]
    param(
        [AllowEmptyString()][string]$Log,
        [string]$Backend,
        [string]$Accelerator
    )
    if($Backend -ne 'LlamaCppOpenVino' -or $Accelerator -notin @('CPU','GPU','NPU')){return $false}
    return $Log -match '(?i)(GGML OpenVINO backend[^\r\n]*(exception|error)|graph_compute[^\r\n]*failed|process_ubatch[^\r\n]*failed to compute|srv\s+send_error:[^\r\n]*Compute error)'
}

function Test-LabLlamaCppAcceleratorLog {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Log,[string]$Backend,[string]$Accelerator)
    if($Log -match '(?i)falling back|fallback to'){return $false}
    if($Backend -eq 'LlamaCppCuda' -and $Accelerator -eq 'CPU') {
        return $Log -match 'CPU\s+compute buffer size' -and $Log -notmatch '(CUDA[0-9]+|OPENVINO[0-9]+)\s+(model|compute) buffer size'
    }
    $offload=[regex]::Match($Log,'offloaded ([1-9][0-9]*)/([1-9][0-9]*) layers')
    if(-not $offload.Success -or $offload.Groups[1].Value -ne $offload.Groups[2].Value){return $false}
    if($Backend -eq 'LlamaCppCuda') {return $Log -match 'CUDA0\s+compute buffer size'}
    return $Log -match ('OpenVINO: using device '+[regex]::Escape($Accelerator)+'(?:\s|$)') -and $Log -match 'OPENVINO0'
}

# Removing the module relinquishes ownership; the worker observes EOF and cleans up.
$ExecutionContext.SessionState.Module.OnRemove = {
    if($script:LlamaCppOwnedSessions) {
        foreach($session in @($script:LlamaCppOwnedSessions.Values)) {
            try {if(-not $session.Worker.HasExited){$session.Worker.StandardInput.Close()}} catch { }
        }
    }
    if($script:AiOvmsGatewaySessions) {
        foreach($session in @($script:AiOvmsGatewaySessions.Values)) {
            try {if(-not $session.Worker.HasExited){$session.Worker.StandardInput.Close()}} catch { }
        }
    }
}
