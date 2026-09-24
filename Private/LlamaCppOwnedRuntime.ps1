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
            if(Test-LabLlamaCppListenerOwner -Port $session.Port -ProcessId $receipt.ProcessId){throw 'LLAMA_RECOVERY_REQUIRED'}
        }
        $keyPath=Join-Path $session.OperationRoot 'api-key.txt'
        if(Test-Path -LiteralPath $keyPath){Remove-Item -LiteralPath $keyPath -Force}
        $script:LlamaCppOwnedSessions.Remove($OperationId);$cleanupSucceeded=$true
        [PSCustomObject]@{Contract='SqlServerLab.LlamaCppCleanup/1.0';OperationId=$OperationId;Status='CLEANUP_SUCCEEDED'}
    }
    finally {if($cleanupSucceeded){$worker.Dispose()}}
}

function Protect-LabLlamaCppOperationPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path,[switch]$File)
    if($IsWindows){
        if($File){
            $acl=[Security.AccessControl.FileSecurity]::new()
        }else{$acl=[Security.AccessControl.DirectorySecurity]::new()}
        $acl.SetAccessRuleProtection($true,$false)
        $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User
        $rights=if($File){'Read,Write'}else{'FullControl'}
        $inheritance=if($File){'None'}else{'ContainerInherit,ObjectInherit'}
        $rule=[Security.AccessControl.FileSystemAccessRule]::new($sid,$rights,$inheritance,'None','Allow')
        $acl.AddAccessRule($rule);Set-Acl -LiteralPath $Path -AclObject $acl
        return
    }
    if($IsLinux){
        $mode=[IO.UnixFileMode]::UserRead-bor[IO.UnixFileMode]::UserWrite
        if(-not $File){$mode=$mode-bor[IO.UnixFileMode]::UserExecute}
        [IO.File]::SetUnixFileMode($Path,$mode);return
    }
    throw 'LLAMA_PLATFORM_UNSUPPORTED'
}

function Test-LabLlamaCppListenerOwner {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][int]$ProcessId,
        [string]$ProcRoot='/proc',
        [string[]]$TcpRecord,
        [string[]]$DescriptorTarget
    )
    if($IsWindows -and -not $PSBoundParameters.ContainsKey('TcpRecord')){
        return [bool]@(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue|Where-Object OwningProcess -eq $ProcessId).Count
    }
    $wantedPort=$Port.ToString('X4',[Globalization.CultureInfo]::InvariantCulture)
    $inodes=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $records=if($PSBoundParameters.ContainsKey('TcpRecord')){@($TcpRecord)}else{
        @(@('tcp','tcp6')|ForEach-Object {$table=Join-Path $ProcRoot "net/$_";if(Test-Path -LiteralPath $table -PathType Leaf){Get-Content -LiteralPath $table -ErrorAction Stop|Select-Object -Skip 1}})
    }
    foreach($line in $records){
        $fields=@($line.Trim()-split '\s+')
        if($fields.Count -ge 10 -and $fields[1] -match (':'+$wantedPort+'$') -and $fields[3] -ceq '0A'){$null=$inodes.Add([string]$fields[9])}
    }
    if(-not $inodes.Count){return $false}
    $targets=if($PSBoundParameters.ContainsKey('DescriptorTarget')){@($DescriptorTarget)}else{
        $fdRoot=Join-Path $ProcRoot "$ProcessId/fd"
        if(-not (Test-Path -LiteralPath $fdRoot -PathType Container)){return $false}
        @(Get-ChildItem -LiteralPath $fdRoot -Force -ErrorAction Stop|ForEach-Object {if($_.Target){[string]$_.Target}elseif($_.PSObject.Properties.Name -contains 'LinkTarget'){[string]$_.LinkTarget}})
    }
    foreach($target in $targets){
        if($target -match '^socket:\[(?<inode>[0-9]+)\]$' -and $inodes.Contains($Matches.inode)){return $true}
    }
    return $false
}

function Resolve-LabLlamaCppComputeSelection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$ComputeSelection,
        [Parameter(Mandatory)]$Inventory,
        [Parameter(Mandatory)]$Runtime,
        [Parameter(Mandatory)][string]$ModelPath,
        [ValidateCount(1,16)][object[]]$DeviceBinding,
        [ValidateRange(1,600)][int]$TimeoutSeconds=30,
        [scriptblock]$ProcessRunner
    )
    $schema=Join-Path $script:ModuleRoot 'Schemas/ai-compute-selection.schema.json'
    try{$valid=$ComputeSelection|ConvertTo-Json -Depth 30|Test-Json -SchemaFile $schema -ErrorAction Stop}catch{$valid=$false}
    if(-not $valid){throw 'LLAMA_COMPUTE_SELECTION_INVALID'}
    if([string]$ComputeSelection.WorkloadKey -cne 'sql-ai-embedding'){throw 'LLAMA_COMPUTE_WORKLOAD_MISMATCH'}
    $Inventory=Assert-LabAiComputeInventoryReceipt -Inventory $Inventory
    if([string]$ComputeSelection.InventorySha256 -cne [string]$Inventory.InventorySha256){throw 'LLAMA_COMPUTE_INVENTORY_MISMATCH'}
    $package=Get-LabAiRuntimePackageSha256 -Runtime $Runtime
    if([string]$ComputeSelection.RuntimeSha256 -cne [string]$package.RuntimeSha256){throw 'LLAMA_COMPUTE_RUNTIME_MISMATCH'}
    $modelHash=Get-LabAiExternalModelFileSha256 -Path $ModelPath -ArtifactKind MODEL
    if([string]$ComputeSelection.ModelSha256 -cne $modelHash){throw 'LLAMA_COMPUTE_MODEL_MISMATCH'}
    $backend=[string]$ComputeSelection.Backend
    if($backend -cnotin @('LlamaCppCpu','LlamaCppCuda','LlamaCppOpenVino','LlamaCppRocm','LlamaCppVulkan','LlamaCppSycl')){throw 'LLAMA_COMPUTE_BACKEND_UNSUPPORTED'}
    if($backend -ne 'LlamaCppCpu' -and $backend -cnotin @($package.DetectedBackends)){throw 'LLAMA_COMPUTE_BACKEND_MISMATCH'}
    $devices=@($ComputeSelection.Devices)
    $candidateIds=@($devices.DeviceId)
    $inventoryDevices=@($Inventory.Devices|Where-Object {$_.DeviceId -cin $candidateIds})
    if($inventoryDevices.Count -ne $candidateIds.Count){throw 'LLAMA_COMPUTE_DEVICE_MISMATCH'}
    $kinds=@($devices.Kind|Sort-Object -Unique)
    if($kinds.Count -ne 1){throw 'LLAMA_COMPUTE_DEVICE_MISMATCH'}
    $accelerator=[string]$kinds[0]
    $deviceContractValid=switch($backend){
        LlamaCppCpu {$accelerator -ceq 'CPU' -and $devices.Count -eq 1}
        LlamaCppCuda {$accelerator -ceq 'GPU' -and -not @($inventoryDevices|Where-Object VendorId -ne '10de').Count}
        LlamaCppRocm {$accelerator -ceq 'GPU' -and -not @($inventoryDevices|Where-Object VendorId -ne '1002').Count}
        LlamaCppVulkan {$accelerator -ceq 'GPU'}
        LlamaCppSycl {$accelerator -ceq 'GPU' -and -not @($inventoryDevices|Where-Object VendorId -ne '8086').Count}
        LlamaCppOpenVino {$accelerator -in @('CPU','GPU','NPU') -and -not @($inventoryDevices|Where-Object {$_.Kind -in @('GPU','NPU') -and $_.VendorId -ne '8086'}).Count}
    }
    if(-not $deviceContractValid){throw 'LLAMA_COMPUTE_DEVICE_MISMATCH'}
    $bindings=if($null -eq $DeviceBinding -or $DeviceBinding.Count -eq 0){
        @(Resolve-LabAiRuntimeDeviceBinding -Inventory $Inventory -Candidate $ComputeSelection -BenchmarkInvocation $Runtime.Invocation -TimeoutSeconds $TimeoutSeconds -ProcessRunner $ProcessRunner)
    }else{@($DeviceBinding)}
    $bindingIds=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal);$bindingSelectors=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($binding in $bindings){
        Assert-LabAiComputeProperties $binding @('DeviceId','RuntimeSelector') 'LLAMA_COMPUTE_DEVICE_BINDING_INVALID'
        $id=[string]$binding.DeviceId;$selector=[string]$binding.RuntimeSelector
        if(-not $bindingIds.Add($id) -or -not $bindingSelectors.Add($selector) -or $selector -notmatch '^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$'){throw 'LLAMA_COMPUTE_DEVICE_BINDING_INVALID'}
    }
    if((($candidateIds|Sort-Object) -join ',') -cne ((@($bindings.DeviceId)|Sort-Object) -join ',')){throw 'LLAMA_COMPUTE_DEVICE_BINDING_MISMATCH'}
    $selectors=@($devices|ForEach-Object {$id=$_.DeviceId;[string]@($bindings|Where-Object DeviceId -CEQ $id)[0].RuntimeSelector})
    $prefixes=switch($backend){LlamaCppCpu{@('none')};LlamaCppCuda{@('CUDA')};LlamaCppRocm{@('ROCm','HIP')};LlamaCppVulkan{@('Vulkan')};LlamaCppSycl{@('SYCL')};LlamaCppOpenVino{@('OpenVINO')}}
    if(@($selectors|Where-Object {$selector=$_;@($prefixes|Where-Object {if($_ -ceq 'none'){$selector -ceq 'none'}else{$selector.StartsWith($_,[StringComparison]::OrdinalIgnoreCase)}}).Count -eq 0}).Count){throw 'LLAMA_COMPUTE_DEVICE_BINDING_MISMATCH'}
    [PSCustomObject]@{Backend=$backend;Accelerator=$accelerator;RuntimeSelectors=$selectors;RuntimeSha256=$package.RuntimeSha256;ModelSha256=$modelHash;CandidateId=[string]$ComputeSelection.CandidateId;SelectionMode=[string]$ComputeSelection.SelectionMode}
}

function Start-LabLlamaCppOwnedRuntime {
    [CmdletBinding(DefaultParameterSetName='Explicit')]
    param(
        [Parameter(Mandatory)][string]$RuntimeDirectory,
        [Parameter(Mandatory,ParameterSetName='Explicit')][ValidateSet('LlamaCppCuda','LlamaCppOpenVino')][string]$Backend,
        [Parameter(Mandatory,ParameterSetName='Explicit')][ValidateSet('CPU','GPU','NPU')][string]$Accelerator,
        [Parameter(Mandatory,ParameterSetName='Selected')][object]$ComputeSelection,
        [Parameter(Mandatory,ParameterSetName='Selected')][object]$Inventory,
        [Parameter(ParameterSetName='Selected')][ValidateCount(1,16)][object[]]$DeviceBinding,
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
    if(-not $IsWindows -and -not $IsLinux){throw 'LLAMA_PLATFORM_UNSUPPORTED'}
    if($LeaseSeconds -le $StartTimeoutSeconds){throw 'LLAMA_LEASE_MUST_EXCEED_START_TIMEOUT'}
    $runtimeRoot=[IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($RuntimeDirectory))
    $pathComparer=if($IsWindows){[StringComparer]::OrdinalIgnoreCase}else{[StringComparer]::Ordinal}
    $runtime=@(Find-LabLlamaCppRuntime -SearchRoot $RuntimeDirectory | Where-Object {$pathComparer.Equals([string]$_.InstallationPath,$runtimeRoot)})
    if($runtime.Count -ne 1){throw 'LLAMA_RUNTIME_SELECTION_MISMATCH'}
    if($PSCmdlet.ParameterSetName -eq 'Explicit' -and $runtime[0].Backend -ne $Backend){throw 'LLAMA_RUNTIME_SELECTION_MISMATCH'}
    if($PSCmdlet.ParameterSetName -eq 'Explicit' -and $Backend -eq 'LlamaCppCuda' -and $Accelerator -eq 'NPU'){throw 'LLAMA_ACCELERATOR_UNSUPPORTED'}
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
    $selectedConfiguration=$null
    if($PSCmdlet.ParameterSetName -eq 'Selected'){
        $selectionArguments=@{ComputeSelection=$ComputeSelection;Inventory=$Inventory;Runtime=$runtime;ModelPath=$ModelPath;TimeoutSeconds=[Math]::Min(30,$StartTimeoutSeconds)}
        if($DeviceBinding){$selectionArguments.DeviceBinding=$DeviceBinding}
        $selectedConfiguration=Resolve-LabLlamaCppComputeSelection @selectionArguments
        $Backend=$selectedConfiguration.Backend;$Accelerator=$selectedConfiguration.Accelerator
    }
    $certificate=[Security.Cryptography.X509Certificates.X509Certificate2]::CreateFromPemFile($CertificatePath,$PrivateKeyPath)
    try{$pin=$certificate.GetCertHashString([Security.Cryptography.HashAlgorithmName]::SHA256).ToLowerInvariant()}finally{$certificate.Dispose()}
    $rootCertificate=$null
    if($TrustedRootPath){$rootCertificate=[Security.Cryptography.X509Certificates.X509Certificate2]::CreateFromPem([IO.File]::ReadAllText((Get-Item -LiteralPath $TrustedRootPath).FullName))}
    $portGuard=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,$Port)
    try{$portGuard.Start()}catch{throw 'LLAMA_PORT_UNAVAILABLE'}finally{$portGuard.Stop()}
    $operationId=[guid]::NewGuid().ToString('D')
    $operationRoot=Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-llama-owned-'+$operationId)
    $null=[IO.Directory]::CreateDirectory($operationRoot)
    Protect-LabLlamaCppOperationPath -Path $operationRoot
    $keyPath=Join-Path $operationRoot 'api-key.txt'
    $worker=$null;$registered=$false;$modelReadLock=$null;$runtimeReadLock=$null
    try {
        $modelReadLock=[IO.File]::Open($ModelPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        $runtimeReadLock=[IO.File]::Open($runtime.Invocation,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        $plain=ConvertFrom-LabSecureString $ApiKey
        try{if($plain -notmatch '^[A-Za-z0-9_-]{24,256}$'){throw 'LLAMA_API_KEY_FORMAT'};[IO.File]::WriteAllText($keyPath,$plain);Protect-LabLlamaCppOperationPath -Path $keyPath -File}finally{$plain=$null}
        $environment=@{}
        $selectors=if($selectedConfiguration){@($selectedConfiguration.RuntimeSelectors)}else{@($(if($Accelerator -eq 'CPU' -and $Backend -eq 'LlamaCppCuda'){'none'}elseif($Backend -eq 'LlamaCppCuda'){'CUDA0'}else{'OPENVINO0'}))}
        $device=$selectors -join ','
        $layers=if($selectors.Count -eq 1 -and $selectors[0] -ceq 'none'){'0'}else{'999'}
        if($Backend -eq 'LlamaCppOpenVino') {$environment=Get-LabLlamaCppOpenVinoEnvironment -Accelerator $Accelerator -OperationRoot $operationRoot}
        $arguments=@('--model',$ModelPath,'--alias',$ModelName,'--embedding','--pooling',$Pooling,
            '--ctx-size',[string]$ContextSize,'--batch-size',[string]$ContextSize,'--ubatch-size',[string]$ContextSize,
            '--parallel','1','--device',$device,'--split-mode',$(if($selectors.Count -gt 1){'layer'}else{'none'}),'--gpu-layers',$layers,'--fit','off','--offline','--log-verbosity','4',
            '--host','127.0.0.1','--port',[string]$Port,'--ssl-cert-file',$CertificatePath,
            '--ssl-key-file',$PrivateKeyPath,'--api-key-file',$keyPath,'--no-webui')
        $supervisor=$null
        if($IsLinux){
            $supervisor=(Get-Command setpriv -CommandType Application -ErrorAction SilentlyContinue|Select-Object -First 1).Source
            if(-not $supervisor){throw 'LLAMA_LINUX_SUPERVISOR_REQUIRED'}
            $supervisorItem=Get-Item -LiteralPath $supervisor -Force -ErrorAction Stop
            if($supervisorItem -isnot [IO.FileInfo] -or ($supervisorItem.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'LLAMA_LINUX_SUPERVISOR_INVALID'}
            $supervisor=$supervisorItem.FullName
        }
        $request=[ordered]@{Contract='SqlServerLab.LlamaCppOwnedRequest/1.0';CleanupPolicy=if($IsWindows){'OWN_JOB_TERMINATE_AND_REMOVE_API_KEY'}else{'PARENT_DEATH_SIGNAL_TERMINATE_AND_REMOVE_API_KEY'};OperationId=$operationId;Invocation=$runtime.Invocation;SupervisorInvocation=$supervisor;Arguments=$arguments;Environment=$environment;LeaseSeconds=$LeaseSeconds;StartTimeoutSeconds=$StartTimeoutSeconds}
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
                $ownedListener=Test-LabLlamaCppListenerOwner -Port $Port -ProcessId $receipt.ProcessId
                if($ownedListener) {
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
        if(-not (Test-LabLlamaCppAcceleratorLog -Log $log -Backend $Backend -Accelerator $Accelerator -RuntimeSelector $selectors)){throw 'LLAMA_ACCELERATOR_NOT_VERIFIED'}
        if($selectedConfiguration){
            $packageAfter=Get-LabAiRuntimePackageSha256 -Runtime $runtime
            if([string]$packageAfter.RuntimeSha256 -cne [string]$selectedConfiguration.RuntimeSha256 -or (Get-LabAiExternalModelFileSha256 $ModelPath MODEL) -cne [string]$selectedConfiguration.ModelSha256){throw 'LLAMA_COMPUTE_ARTIFACT_CHANGED'}
        }
        [IO.File]::WriteAllText((Join-Path $operationRoot 'ready'),'ENDPOINT_VERIFIED')
        $artifacts=$null
        if($CaptureArtifactEvidence){$artifacts=[PSCustomObject]@{RuntimeSha256=(Get-LabAiExternalModelFileSha256 $runtime.Invocation RUNTIME);ModelSha256=(Get-LabAiExternalModelFileSha256 $ModelPath MODEL)}}
        if($worker.HasExited -or -not (Test-LabLlamaCppListenerOwner -Port $Port -ProcessId $receipt.ProcessId)){throw 'LLAMA_ENDPOINT_LEASE_ENDED'}
        [PSCustomObject]@{Contract='SqlServerLab.LlamaCppOwnedRuntime/1.0';OperationId=$operationId;Status='ENDPOINT_VERIFIED';Backend=$Backend;Accelerator=$Accelerator;ModelName=$ModelName;Dimension=$Dimension;Location=$location;ServerCertificateSha256=$pin;LeaseSeconds=$LeaseSeconds;ArtifactEvidence=$artifacts;CandidateId=if($selectedConfiguration){$selectedConfiguration.CandidateId}else{$null};SelectionMode=if($selectedConfiguration){$selectedConfiguration.SelectionMode}else{'EXPLICIT_LEGACY'};RuntimeSelectors=$selectors}
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
    param([Parameter(Mandatory)][string]$Log,[string]$Backend,[string]$Accelerator,[string[]]$RuntimeSelector)
    if($Log -match '(?i)falling back|fallback to'){return $false}
    if((-not $RuntimeSelector -and $Accelerator -eq 'CPU') -or ($RuntimeSelector.Count -eq 1 -and $RuntimeSelector[0] -ceq 'none')) {
        return $Log -match 'CPU\s+compute buffer size' -and $Log -notmatch '(CUDA|ROCm|HIP|Vulkan|SYCL|OPENVINO)[0-9]+\s+(model|compute) buffer size'
    }
    $selectors=if($RuntimeSelector){@($RuntimeSelector)}elseif($Backend -eq 'LlamaCppCuda' -and $Accelerator -eq 'CPU'){@('none')}elseif($Backend -eq 'LlamaCppCuda'){@('CUDA0')}else{@('OPENVINO0')}
    $offload=[regex]::Match($Log,'offloaded ([1-9][0-9]*)/([1-9][0-9]*) layers')
    if(-not $offload.Success -or $offload.Groups[1].Value -ne $offload.Groups[2].Value){return $false}
    if($Backend -eq 'LlamaCppOpenVino' -and $Log -notmatch ('OpenVINO: using device '+[regex]::Escape($Accelerator)+'(?:\s|$)')){return $false}
    foreach($selector in $selectors){
        $pattern=if($Backend -eq 'LlamaCppOpenVino'){'(?im)'+[regex]::Escape($selector)}else{'(?im)'+[regex]::Escape($selector)+'[^\r\n]*(model|compute) buffer size'}
        if($Log -notmatch $pattern){return $false}
    }
    return $true
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
