function Invoke-LabAiSharedGatewayUpstreamHttpTransport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Request,
        [Parameter(Mandatory)][Uri]$Location,
        [SecureString]$ApiKey
    )

    $handler=[Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect=$false
    $handler.UseProxy=$false
    $client=[Net.Http.HttpClient]::new($handler,$true)
    $client.MaxResponseContentBufferSize=1MB
    $message=$null;$plainApiKey=$null
    try {
        $client.Timeout=[TimeSpan]::FromSeconds([int]$Request.TimeoutSeconds)
        $message=[Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Post,$Location)
        $message.Content=[Net.Http.StringContent]::new(($Request.Body|ConvertTo-Json -Depth 10 -Compress),[Text.Encoding]::UTF8,'application/json')
        if($ApiKey){
            $plainApiKey=ConvertFrom-LabSecureString -SecureString $ApiKey
            $message.Headers.Authorization=[Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer',$plainApiKey)
        }
        $httpResponse=$client.SendAsync($message).GetAwaiter().GetResult()
        try {
            $statusCode=[int]$httpResponse.StatusCode;$body=$null
            if($statusCode -ge 200 -and $statusCode -lt 300){
                $json=$httpResponse.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                try{$body=$json|ConvertFrom-Json -Depth 30 -ErrorAction Stop}catch{throw 'AI_SHARED_GATEWAY_UPSTREAM_RESPONSE_INVALID'}finally{$json=$null}
            }
            [pscustomobject]@{StatusCode=$statusCode;Body=$body}
        }
        finally{$httpResponse.Dispose()}
    }
    finally{
        $plainApiKey=$null
        if($message){$message.Dispose()}
        $client.Dispose()
    }
}

function Test-LabAiSharedGatewayUpstream {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Plan,
        [string]$StateRoot,
        [SecureString]$ApiKey,
        [ValidateRange(1,300)][int]$TimeoutSeconds=30,
        [scriptblock]$Transport
    )

    $canonical=Resolve-LabAiSharedGatewayPlan $Plan
    if(-not $StateRoot){$StateRoot=Get-LabStateRoot}
    $root=Assert-LabAiSharedGatewayStoragePath $StateRoot
    $gatewayRoot=Join-Path (Join-Path $root 'shared-ai-gateways') $canonical.GatewayId
    $storage=Read-LabAiSharedGatewayRegistration -Directory $gatewayRoot -ExpectedPlan $canonical
    $uri=[Uri]$canonical.UpstreamLocation
    $request=[pscustomobject]@{
        Method='POST';Path=$uri.AbsolutePath;TimeoutSeconds=$TimeoutSeconds
        Body=[ordered]@{model=$canonical.RuntimeModel;input=@('SQL Server Lab synthetic shared gateway probe');encoding_format='float'}
    }
    $watch=[Diagnostics.Stopwatch]::StartNew()
    try {
        try {
            if($Transport){$response=& $Transport $request}
            else{$response=Invoke-LabAiSharedGatewayUpstreamHttpTransport -Request $request -Location $uri -ApiKey $ApiKey}
        }
        catch [Threading.Tasks.TaskCanceledException]{throw 'AI_SHARED_GATEWAY_UPSTREAM_TIMEOUT'}
        catch [Net.Http.HttpRequestException]{throw 'AI_SHARED_GATEWAY_UPSTREAM_NETWORK_FAILURE'}
    }
    finally{$watch.Stop()}

    if($null -eq $response -or $null -eq $response.StatusCode){throw 'AI_SHARED_GATEWAY_UPSTREAM_RESPONSE_INVALID'}
    $statusCode=[int]$response.StatusCode
    if($statusCode -lt 200 -or $statusCode -ge 300){throw "AI_SHARED_GATEWAY_UPSTREAM_HTTP_$statusCode"}
    if($null -eq $response.Body){throw 'AI_SHARED_GATEWAY_UPSTREAM_RESPONSE_INVALID'}
    if([string]$response.Body.model -cne $canonical.RuntimeModel){throw 'AI_SHARED_GATEWAY_UPSTREAM_MODEL_MISMATCH'}
    $data=@($response.Body.data)
    if($data.Count -ne 1 -or $null -eq $data[0].embedding){throw 'AI_SHARED_GATEWAY_UPSTREAM_RESPONSE_INVALID'}
    $vector=@($data[0].embedding)
    if($vector.Count -ne [int]$canonical.Dimension){throw 'AI_SHARED_GATEWAY_UPSTREAM_DIMENSION_MISMATCH'}
    if(@($vector|Where-Object{-not(Test-LabAiExternalModelNumericValue $_)}).Count){throw 'AI_SHARED_GATEWAY_UPSTREAM_VECTOR_INVALID'}

    $verifiedAt=[datetime]::UtcNow.ToString('o')
    $duration=[Math]::Max(0,[int64]$watch.ElapsedMilliseconds)
    $bindingIdentity=[ordered]@{Contract='SqlServerLab.AiSharedGatewayUpstreamBinding/1.0';PlanKey=$canonical.PlanKey;Backend=$canonical.UpstreamBackend;Location=$canonical.UpstreamLocation;RuntimeModel=$canonical.RuntimeModel;Dimension=$canonical.Dimension}
    $bindingKey=Get-LabAiPlanKey $bindingIdentity
    $receiptIdentity=[ordered]@{Contract='SqlServerLab.AiSharedGatewayUpstreamReceipt/1.0';PlanKey=$canonical.PlanKey;StorageReceiptKey=$storage.ReceiptKey;UpstreamBindingKey=$bindingKey;HttpStatus=$statusCode;DurationMilliseconds=$duration;VerifiedAtUtc=$verifiedAt}
    [pscustomobject][ordered]@{
        Contract=[pscustomobject]@{Name='SqlServerLab.AiSharedGatewayUpstreamReceipt';Version='1.0'}
        Status='UPSTREAM_VERIFIED';EvidenceStatus='LIVE_LOOPBACK_UPSTREAM';GatewayId=$canonical.GatewayId
        PlanKey=$canonical.PlanKey;StorageReceiptKey=$storage.ReceiptKey;UpstreamBindingKey=$bindingKey
        Backend=$canonical.UpstreamBackend;RuntimeModel=$canonical.RuntimeModel;Dimension=$canonical.Dimension
        HttpStatus=$statusCode;DurationMilliseconds=$duration;VerifiedAtUtc=$verifiedAt
        VerifiedEvidence=@('PROTECTED_SHARED_STORAGE_REVALIDATED','LOOPBACK_UPSTREAM_BOUND','OPENAI_RESPONSE_SHAPE_MATCH','RUNTIME_MODEL_MATCH','EMBEDDING_DIMENSION_MATCH','FINITE_NUMERIC_VECTOR_MATCH')
        PendingEvidence=@('PERSISTENT_GATEWAY_SERVICE','LIVE_HTTPS_GATEWAY_ENDPOINT','SQL_CONSUMER_BINDINGS','BACKUP_RESTORE','ROTATION','ACCELERATOR_RUNTIME_ATTESTATION')
        ReceiptKey=Get-LabAiPlanKey $receiptIdentity
    }
}
