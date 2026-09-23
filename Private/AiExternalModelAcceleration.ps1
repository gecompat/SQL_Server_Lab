if (-not ('SqlServerLab.AiExternalModelCertificateValidatorV1' -as [type])) {
    Add-Type -TypeDefinition @'
namespace SqlServerLab {
    using System;
    using System.Net.Http;
    using System.Net.Security;
    using System.Security.Cryptography;
    using System.Security.Cryptography.X509Certificates;

    public sealed class AiExternalModelCertificateValidatorV1 {
        private readonly string expectedPin;
        private readonly X509Certificate2 trustedRoot;
        public string ObservedPin { get; private set; }
        public string FailureCode { get; private set; }
        public Func<HttpRequestMessage,X509Certificate2,X509Chain,SslPolicyErrors,bool> Callback { get; }

        public AiExternalModelCertificateValidatorV1(string expectedPin, X509Certificate2 trustedRoot) {
            this.expectedPin = expectedPin;
            this.trustedRoot = trustedRoot;
            Callback = Validate;
        }

        private bool Validate(HttpRequestMessage message, X509Certificate2 certificate, X509Chain chain, SslPolicyErrors errors) {
            if (certificate == null) { FailureCode = "AI_EXTERNAL_MODEL_TLS_CERTIFICATE_MISSING"; return false; }
            using (var leaf = new X509Certificate2(certificate)) {
                ObservedPin = leaf.GetCertHashString(HashAlgorithmName.SHA256).ToLowerInvariant();
                if (!String.Equals(ObservedPin, expectedPin, StringComparison.Ordinal)) {
                    FailureCode = "AI_EXTERNAL_MODEL_TLS_CERTIFICATE_MISMATCH"; return false;
                }
                if ((errors & SslPolicyErrors.RemoteCertificateNameMismatch) != 0) {
                    FailureCode = "AI_EXTERNAL_MODEL_TLS_NAME_MISMATCH"; return false;
                }
                if (trustedRoot != null) {
                    using (var customChain = new X509Chain()) {
                        customChain.ChainPolicy.TrustMode = X509ChainTrustMode.CustomRootTrust;
                        customChain.ChainPolicy.RevocationMode = X509RevocationMode.NoCheck;
                        customChain.ChainPolicy.CustomTrustStore.Add(trustedRoot);
                        if (!customChain.Build(leaf)) { FailureCode = "AI_EXTERNAL_MODEL_TLS_TRUST_FAILED"; return false; }
                        return true;
                    }
                }
                if (errors != SslPolicyErrors.None) { FailureCode = "AI_EXTERNAL_MODEL_TLS_TRUST_FAILED"; return false; }
                return true;
            }
        }
    }
}
'@
}

<#
.SYNOPSIS
    Erstellt einen gebundenen, nicht ausführbaren SQL-External-Model-Plan.
.DESCRIPTION
    Validiert einen vorhandenen HTTPS-Embedding-Endpunkt für SQL Server 2025.
    Der Plan führt weder Netzwerkproben noch Host-, Trust- oder Runtimeänderungen
    aus und behauptet deshalb keinen Beschleunigungsnachweis.
#>
function New-LabAiExternalModelPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('LlamaCppOpenVino','OpenVinoModelServer','LlamaCppRocm','LlamaCppCuda','LlamaCppSnapdragonOpenCl','LlamaCppSnapdragonHexagon')][string]$Backend,
        [Parameter(Mandatory)][ValidateSet('CPU','GPU','NPU')][string]$Accelerator,
        [Parameter(Mandatory)][ValidatePattern('^https://')][string]$Location,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z_][A-Za-z0-9_]{0,127}$')][string]$ExternalModelName,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._:/+-]{0,255}$')][string]$RuntimeModel,
        [Parameter(Mandatory)][ValidateRange(1,1998)][int]$Dimension,
        [Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ModelSha256,
        [Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$RuntimeSha256,
        [Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ServerCertificateSha256,
        [ValidateSet('Direct','Gateway')][string]$TlsMode = 'Direct',
        [ValidateSet('raw','nomic-search','snowflake-search')][string]$InputProfile = 'raw',
        [object]$GatewayBinding,
        [ValidatePattern('^[a-f0-9]{64}$')][string]$GatewayBindingKey
    )

    $blockers = [Collections.Generic.List[string]]::new()
    $warnings = [Collections.Generic.List[string]]::new()
    try { $uri = [Uri]::new($Location, [UriKind]::Absolute) }
    catch { $uri = $null; $blockers.Add('AI_EXTERNAL_MODEL_LOCATION_INVALID') }

    $expectedPath = if ($Backend -eq 'OpenVinoModelServer') { '/v3/embeddings' } else { '/v1/embeddings' }
    if ($uri) {
        if ($uri.Scheme -cne 'https' -or -not [string]::IsNullOrEmpty($uri.UserInfo) -or
            -not [string]::IsNullOrEmpty($uri.Query) -or -not [string]::IsNullOrEmpty($uri.Fragment)) {
            $blockers.Add('AI_EXTERNAL_MODEL_HTTPS_LOCATION_REQUIRED')
        }
        if ($uri.AbsolutePath -cne $expectedPath) { $blockers.Add('AI_EXTERNAL_MODEL_ENDPOINT_PATH_MISMATCH') }
    }

    $allowedAccelerators = switch ($Backend) {
        { $_ -in @('LlamaCppOpenVino','OpenVinoModelServer') } { @('CPU','GPU','NPU'); break }
        { $_ -in @('LlamaCppRocm','LlamaCppCuda','LlamaCppSnapdragonOpenCl') } { @('GPU'); break }
        'LlamaCppSnapdragonHexagon' { @('NPU'); break }
    }
    if ($Accelerator -notin $allowedAccelerators) { $blockers.Add('AI_EXTERNAL_MODEL_ACCELERATOR_UNSUPPORTED') }
    if($GatewayBinding -and $GatewayBindingKey){throw 'AI_EXTERNAL_MODEL_GATEWAY_BINDING_AMBIGUOUS'}
    $resolvedGateway=$null
    if($GatewayBinding){try{$resolvedGateway=Resolve-LabAiOvmsHttpsGatewayBinding -Binding $GatewayBinding;$GatewayBindingKey=$resolvedGateway.BindingKey}catch{$blockers.Add('AI_EXTERNAL_MODEL_OVMS_GATEWAY_BINDING_INVALID')}}
    if ($Backend -eq 'OpenVinoModelServer') {
        if ($TlsMode -ne 'Gateway') { $blockers.Add('AI_EXTERNAL_MODEL_OVMS_GATEWAY_REQUIRED') }
        elseif(-not $GatewayBindingKey -and -not $GatewayBinding){$blockers.Add('AI_EXTERNAL_MODEL_OVMS_GATEWAY_BINDING_REQUIRED')}
    }
    if ($Backend -ne 'OpenVinoModelServer' -and ($TlsMode -eq 'Gateway' -or $GatewayBindingKey)) { $blockers.Add('AI_EXTERNAL_MODEL_GATEWAY_BINDING_UNSUPPORTED') }
    if ($Backend -eq 'LlamaCppSnapdragonHexagon') { $warnings.Add('AI_EXTERNAL_MODEL_SNAPDRAGON_HEXAGON_OPT_IN') }

    $normalizedLocation = if ($uri) { $uri.AbsoluteUri } else { $Location }
    if($resolvedGateway -and ($resolvedGateway.Location -cne $normalizedLocation -or $resolvedGateway.RuntimeModel -cne $RuntimeModel -or
       $resolvedGateway.Dimension -ne $Dimension -or $resolvedGateway.ServerCertificateSha256 -cne $ServerCertificateSha256.ToLowerInvariant())){
        $blockers.Add('AI_EXTERNAL_MODEL_OVMS_GATEWAY_BINDING_MISMATCH')
    }
    $credentialName = if ($uri) { '{0}://{1}' -f $uri.Scheme, $uri.Authority } else { $null }
    $identity = [ordered]@{
        Contract='SqlServerLab.AiExternalModelPlan/1.0';Backend=$Backend;Accelerator=$Accelerator
        Location=$normalizedLocation;ExternalModelName=$ExternalModelName;RuntimeModel=$RuntimeModel
        Dimension=$Dimension;InputProfile=$InputProfile;TlsMode=$TlsMode
        ModelSha256=$ModelSha256.ToLowerInvariant();RuntimeSha256=$RuntimeSha256.ToLowerInvariant()
        ServerCertificateSha256=$ServerCertificateSha256.ToLowerInvariant()
    }
    if($GatewayBindingKey){$identity.GatewayBindingKey=$GatewayBindingKey}
    $plan=[ordered]@{
        Contract=[PSCustomObject]@{Name='SqlServerLab.AiExternalModelPlan';Version='1.0'}
        Status=if ($blockers.Count) { 'BLOCKED' } else { 'NOT_PROBED' }
        EvidenceStatus='CONFIGURATION_ONLY'
        Backend=$Backend;Accelerator=$Accelerator;ApiFormat='OpenAI';Location=$normalizedLocation
        EndpointPath=$expectedPath;CredentialName=$credentialName;ExternalModelName=$ExternalModelName
        RuntimeModel=$RuntimeModel;ModelType='EMBEDDINGS';Dimension=$Dimension;InputProfile=$InputProfile
        TlsMode=$TlsMode;ModelSha256=$identity.ModelSha256;RuntimeSha256=$identity.RuntimeSha256
        ServerCertificateSha256=$identity.ServerCertificateSha256
        RequiredEvidence=@('HTTPS_CERTIFICATE_MATCH','RUNTIME_BINARY_MATCH','MODEL_FILE_MATCH','RUNTIME_MODEL_MATCH','EMBEDDING_DIMENSION_MATCH','ACCELERATOR_RUNTIME_ATTESTATION')
        Blockers=@($blockers);Warnings=@($warnings)
    }
    if($GatewayBindingKey){$plan.GatewayBindingKey=$GatewayBindingKey;$plan.RequiredEvidence=@($plan.RequiredEvidence)+@('HTTPS_GATEWAY_BINDING','GATEWAY_PROCESS_OWNERSHIP')}
    $plan.PlanKey=Get-LabAiPlanKey -InputObject $identity
    [PSCustomObject]$plan
}

function Test-LabAiExternalModelNumericValue {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Value)

    if ($Value -is [bool] -or $Value -is [char]) { return $false }
    $typeCode = [Type]::GetTypeCode($Value.GetType())
    if ($typeCode -notin @(
        [TypeCode]::Byte,[TypeCode]::SByte,[TypeCode]::UInt16,[TypeCode]::UInt32,[TypeCode]::UInt64,
        [TypeCode]::Int16,[TypeCode]::Int32,[TypeCode]::Int64,[TypeCode]::Single,[TypeCode]::Double,[TypeCode]::Decimal
    )) { return $false }
    $number = [double]$Value
    return -not [double]::IsNaN($number) -and -not [double]::IsInfinity($number) -and
        [Math]::Abs($number) -le [float]::MaxValue
}

function Resolve-LabAiOvmsUpstreamLocation {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Location)

    try { $uri = [Uri]::new($Location, [UriKind]::Absolute) }
    catch { throw 'AI_OVMS_UPSTREAM_LOCATION_INVALID' }
    $address = $null
    if ($uri.Scheme -cne 'http' -or -not [string]::IsNullOrEmpty($uri.UserInfo) -or
        -not [string]::IsNullOrEmpty($uri.Query) -or -not [string]::IsNullOrEmpty($uri.Fragment) -or
        $uri.AbsolutePath -cne '/v3/embeddings' -or $uri.Port -lt 1024 -or $uri.Port -gt 65535 -or
        -not [Net.IPAddress]::TryParse($uri.Host, [ref]$address) -or -not [Net.IPAddress]::IsLoopback($address)) {
        throw 'AI_OVMS_UPSTREAM_LOCATION_INVALID'
    }
    return $uri
}

function Invoke-LabAiOvmsUpstreamHttpTransport {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Request,[Parameter(Mandatory)][Uri]$Location)

    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $handler.UseProxy = $false
    $client = [Net.Http.HttpClient]::new($handler, $true)
    $client.MaxResponseContentBufferSize = 1MB
    $message = $null
    try {
        $client.Timeout = [TimeSpan]::FromSeconds([int]$Request.TimeoutSeconds)
        $message = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Post, $Location)
        $message.Content = [Net.Http.StringContent]::new(
            ($Request.Body | ConvertTo-Json -Depth 10 -Compress), [Text.Encoding]::UTF8, 'application/json')
        $httpResponse = $client.SendAsync($message).GetAwaiter().GetResult()
        try {
            if (-not $httpResponse.IsSuccessStatusCode) {
                return [PSCustomObject]@{StatusCode=[int]$httpResponse.StatusCode;Body=$null}
            }
            $json = $httpResponse.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            try { $body = if ($json) { $json | ConvertFrom-Json -Depth 30 -ErrorAction Stop } else { $null } }
            catch { throw 'AI_OVMS_UPSTREAM_RESPONSE_INVALID' }
            finally { $json = $null }
            return [PSCustomObject]@{StatusCode=[int]$httpResponse.StatusCode;Body=$body}
        }
        finally { $httpResponse.Dispose() }
    }
    finally {
        if ($message) { $message.Dispose() }
        $client.Dispose()
    }
}

function Invoke-LabAiOvmsUpstreamProbe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Location,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._:/+-]{0,255}$')][string]$RuntimeModel,
        [Parameter(Mandatory)][ValidateRange(1,1998)][int]$Dimension,
        [ValidateRange(1,300)][int]$TimeoutSeconds = 30,
        [scriptblock]$Transport
    )

    $uri = Resolve-LabAiOvmsUpstreamLocation -Location $Location
    $identity = [ordered]@{
        Contract='SqlServerLab.AiOvmsUpstreamBinding/1.0';Location=$uri.AbsoluteUri
        RuntimeModel=$RuntimeModel;Dimension=$Dimension
    }
    $request = [PSCustomObject]@{
        Method='POST';Path='/v3/embeddings';TimeoutSeconds=$TimeoutSeconds
        Body=[ordered]@{model=$RuntimeModel;input=@('SQL Server Lab synthetic OVMS probe');encoding_format='float'}
    }
    $started = [Diagnostics.Stopwatch]::StartNew()
    try {
        try {
            if ($Transport) { $response = & $Transport $request }
            else { $response = Invoke-LabAiOvmsUpstreamHttpTransport -Request $request -Location $uri }
        }
        catch [System.Threading.Tasks.TaskCanceledException] { throw 'AI_OVMS_UPSTREAM_TIMEOUT' }
        catch [System.Net.Http.HttpRequestException] { throw 'AI_OVMS_UPSTREAM_NETWORK_FAILURE' }
    }
    finally { $started.Stop() }

    if ($null -eq $response -or $null -eq $response.StatusCode) { throw 'AI_OVMS_UPSTREAM_RESPONSE_INVALID' }
    $statusCode = [int]$response.StatusCode
    if ($statusCode -lt 200 -or $statusCode -ge 300) { throw "AI_OVMS_UPSTREAM_HTTP_$statusCode" }
    if ($null -eq $response.Body) { throw 'AI_OVMS_UPSTREAM_RESPONSE_INVALID' }
    if ([string]$response.Body.model -cne $RuntimeModel) { throw 'AI_OVMS_UPSTREAM_RUNTIME_MODEL_MISMATCH' }
    $data = @($response.Body.data)
    if ($data.Count -ne 1 -or $null -eq $data[0].embedding) { throw 'AI_OVMS_UPSTREAM_RESPONSE_INVALID' }
    $vector = @($data[0].embedding)
    if ($vector.Count -ne $Dimension) { throw 'AI_OVMS_UPSTREAM_DIMENSION_MISMATCH' }
    if (@($vector | Where-Object { -not (Test-LabAiExternalModelNumericValue -Value $_) }).Count -gt 0) {
        throw 'AI_OVMS_UPSTREAM_VECTOR_INVALID'
    }

    return [PSCustomObject]@{
        Contract=[PSCustomObject]@{Name='SqlServerLab.AiOvmsUpstreamReceipt';Version='1.0'}
        Status='UPSTREAM_VERIFIED';EvidenceStatus='LIVE_LOOPBACK_ENDPOINT'
        BindingKey=Get-LabAiPlanKey -InputObject $identity
        Dimension=$Dimension;HttpStatus=$statusCode
        DurationMilliseconds=[Math]::Max(0,[int64]$started.ElapsedMilliseconds)
        VerifiedEvidence=@('LOOPBACK_HTTP_BOUND','OVMS_V3_RESPONSE_SHAPE_MATCH','RUNTIME_MODEL_MATCH','EMBEDDING_DIMENSION_MATCH','FINITE_NUMERIC_VECTOR_MATCH')
        PendingEvidence=@('HTTPS_GATEWAY_BINDING','GATEWAY_PROCESS_OWNERSHIP','ACCELERATOR_RUNTIME_ATTESTATION')
    }
}

function Resolve-LabAiExternalModelPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Plan)

    if ([string]$Plan.Contract.Name -cne 'SqlServerLab.AiExternalModelPlan' -or [string]$Plan.Contract.Version -cne '1.0') {
        throw 'AI_EXTERNAL_MODEL_PLAN_INVALID'
    }
    try {
        $arguments=@{Backend=[string]$Plan.Backend;Accelerator=[string]$Plan.Accelerator;Location=[string]$Plan.Location
            ExternalModelName=[string]$Plan.ExternalModelName;RuntimeModel=[string]$Plan.RuntimeModel;Dimension=[int]$Plan.Dimension
            ModelSha256=[string]$Plan.ModelSha256;RuntimeSha256=[string]$Plan.RuntimeSha256
            ServerCertificateSha256=[string]$Plan.ServerCertificateSha256;TlsMode=[string]$Plan.TlsMode;InputProfile=[string]$Plan.InputProfile}
        if($Plan.PSObject.Properties['GatewayBindingKey']){$arguments.GatewayBindingKey=[string]$Plan.GatewayBindingKey}
        $canonicalPlan=New-LabAiExternalModelPlan @arguments
    }
    catch { throw 'AI_EXTERNAL_MODEL_PLAN_INVALID' }
    if ([string]$canonicalPlan.PlanKey -cne [string]$Plan.PlanKey) { throw 'AI_EXTERNAL_MODEL_PLAN_INVALID' }
    if ([string]$canonicalPlan.Status -eq 'BLOCKED') { throw 'AI_EXTERNAL_MODEL_PLAN_BLOCKED' }
    if ([string]$Plan.Status -cne 'NOT_PROBED' -or [string]$Plan.EvidenceStatus -cne 'CONFIGURATION_ONLY') {
        throw 'AI_EXTERNAL_MODEL_PLAN_INVALID'
    }
    return $canonicalPlan
}

function Get-LabAiExternalModelFileSha256 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidateSet('RUNTIME','MODEL')][string]$ArtifactKind
    )

    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if (-not ($item -is [IO.FileInfo])) { throw 'NOT_A_FILE' }
        $stream = [IO.File]::Open($item.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try {
            $sha = [Security.Cryptography.SHA256]::Create()
            try { return ([Convert]::ToHexString($sha.ComputeHash($stream))).ToLowerInvariant() }
            finally { $sha.Dispose() }
        }
        finally { $stream.Dispose() }
    }
    catch {
        throw "AI_EXTERNAL_MODEL_${ArtifactKind}_FILE_UNREADABLE"
    }
}

function Test-LabAiExternalModelArtifact {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)][string]$RuntimePath,
        [Parameter(Mandatory)][string]$ModelPath
    )

    $canonicalPlan = Resolve-LabAiExternalModelPlan -Plan $Plan
    try {
        $runtimeFullPath = [IO.Path]::GetFullPath($RuntimePath)
        $modelFullPath = [IO.Path]::GetFullPath($ModelPath)
    }
    catch { throw 'AI_EXTERNAL_MODEL_ARTIFACT_PATH_INVALID' }
    $pathComparison = if ([OperatingSystem]::IsWindows()) {
        [StringComparison]::OrdinalIgnoreCase
    }
    else {
        [StringComparison]::Ordinal
    }
    if ([string]::Equals($runtimeFullPath, $modelFullPath, $pathComparison)) {
        throw 'AI_EXTERNAL_MODEL_ARTIFACT_PATHS_MUST_DIFFER'
    }

    $runtimeSha256 = Get-LabAiExternalModelFileSha256 -Path $runtimeFullPath -ArtifactKind RUNTIME
    if ($runtimeSha256 -cne [string]$canonicalPlan.RuntimeSha256) {
        throw 'AI_EXTERNAL_MODEL_RUNTIME_HASH_MISMATCH'
    }
    $modelSha256 = Get-LabAiExternalModelFileSha256 -Path $modelFullPath -ArtifactKind MODEL
    if ($modelSha256 -cne [string]$canonicalPlan.ModelSha256) {
        throw 'AI_EXTERNAL_MODEL_MODEL_HASH_MISMATCH'
    }

    return [PSCustomObject]@{
        Contract=[PSCustomObject]@{Name='SqlServerLab.AiExternalModelArtifactReceipt';Version='1.0'}
        Status='ARTIFACTS_VERIFIED';EvidenceStatus='LOCAL_ARTIFACTS';PlanKey=[string]$canonicalPlan.PlanKey
        Backend=[string]$canonicalPlan.Backend;RuntimeSha256=$runtimeSha256;ModelSha256=$modelSha256
        VerifiedEvidence=@('RUNTIME_BINARY_MATCH','MODEL_FILE_MATCH')
        PendingEvidence=@(
            'HTTPS_CERTIFICATE_MATCH','OPENAI_RESPONSE_SHAPE_MATCH','RUNTIME_MODEL_MATCH','EMBEDDING_DIMENSION_MATCH',
            'FINITE_NUMERIC_VECTOR_MATCH','ACCELERATOR_RUNTIME_ATTESTATION'
        )
    }
}

function Invoke-LabAiExternalModelHttpTransport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Request,
        [Parameter(Mandatory)][ValidatePattern('^https://')][string]$Location,
        [Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ExpectedServerCertificateSha256,
        [SecureString]$ApiKey,
        [Security.Cryptography.X509Certificates.X509Certificate2]$TrustedRootCertificate
    )

    $expectedPin = $ExpectedServerCertificateSha256.ToLowerInvariant()
    $validator = [SqlServerLab.AiExternalModelCertificateValidatorV1]::new($expectedPin, $TrustedRootCertificate)
    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $handler.UseProxy = $false
    $handler.ServerCertificateCustomValidationCallback = $validator.Callback

    $client = [Net.Http.HttpClient]::new($handler, $true)
    $client.MaxResponseContentBufferSize = 1MB
    $message = $null
    $plainApiKey = $null
    try {
        $client.Timeout = [TimeSpan]::FromSeconds([int]$Request.TimeoutSeconds)
        $method = if ($Request.Method -eq 'GET') { [Net.Http.HttpMethod]::Get } else { [Net.Http.HttpMethod]::Post }
        $message = [Net.Http.HttpRequestMessage]::new($method, [Uri]$Location)
        if ($method -eq [Net.Http.HttpMethod]::Post) { $message.Content = [Net.Http.StringContent]::new(($Request.Body | ConvertTo-Json -Depth 10 -Compress), [Text.Encoding]::UTF8, 'application/json') }
        if ($ApiKey) {
            $plainApiKey = ConvertFrom-LabSecureString -SecureString $ApiKey
            $message.Headers.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $plainApiKey)
        }
        try { $httpResponse = $client.SendAsync($message).GetAwaiter().GetResult() }
        catch [Net.Http.HttpRequestException] {
            if($validator.FailureCode){throw $validator.FailureCode}
            throw
        }
        try {
            $statusCode = [int]$httpResponse.StatusCode
            $body = $null
            if ($statusCode -ge 200 -and $statusCode -lt 300) {
                $json = $httpResponse.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                try { $body = $json | ConvertFrom-Json -Depth 30 -ErrorAction Stop }
                catch { throw 'AI_EXTERNAL_MODEL_RESPONSE_INVALID' }
                finally { $json = $null }
            }
            return [PSCustomObject]@{StatusCode=$statusCode;Body=$body;ServerCertificateSha256=$validator.ObservedPin}
        }
        finally { $httpResponse.Dispose() }
    }
    finally {
        $plainApiKey = $null
        if ($message) { $message.Dispose() }
        $client.Dispose()
    }
}

function Invoke-LabAiExternalModelEndpointProbe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Plan,
        [SecureString]$ApiKey,
        [Security.Cryptography.X509Certificates.X509Certificate2]$TrustedRootCertificate,
        [ValidateRange(1,300)][int]$TimeoutSeconds = 30,
        [scriptblock]$Transport
    )

    $Plan = Resolve-LabAiExternalModelPlan -Plan $Plan

    $request = [PSCustomObject]@{
        Method='POST';Path=[string]$Plan.EndpointPath;TimeoutSeconds=$TimeoutSeconds
        Body=[ordered]@{model=[string]$Plan.RuntimeModel;input=@('SQL Server Lab synthetic embedding probe');encoding_format='float'}
    }
    $started = [Diagnostics.Stopwatch]::StartNew()
    try {
        if ($Transport) { $response = & $Transport $request }
        else {
            $response = Invoke-LabAiExternalModelHttpTransport -Request $request -Location ([string]$Plan.Location) `
                -ExpectedServerCertificateSha256 ([string]$Plan.ServerCertificateSha256) -ApiKey $ApiKey `
                -TrustedRootCertificate $TrustedRootCertificate
        }
    }
    catch [System.Threading.Tasks.TaskCanceledException] { throw 'AI_EXTERNAL_MODEL_ENDPOINT_TIMEOUT' }
    catch [System.Net.Http.HttpRequestException] { throw 'AI_EXTERNAL_MODEL_ENDPOINT_NETWORK_FAILURE' }
    finally { $started.Stop() }

    if ($null -eq $response -or $null -eq $response.StatusCode) { throw 'AI_EXTERNAL_MODEL_RESPONSE_INVALID' }
    $statusCode = [int]$response.StatusCode
    if ($statusCode -lt 200 -or $statusCode -ge 300) { throw "AI_EXTERNAL_MODEL_HTTP_$statusCode" }
    $observedPin = ([string]$response.ServerCertificateSha256).ToLowerInvariant()
    if ($observedPin -cne [string]$Plan.ServerCertificateSha256) { throw 'AI_EXTERNAL_MODEL_TLS_CERTIFICATE_MISMATCH' }
    if ($null -eq $response.Body) { throw 'AI_EXTERNAL_MODEL_RESPONSE_INVALID' }
    if ([string]$response.Body.model -cne [string]$Plan.RuntimeModel) { throw 'AI_EXTERNAL_MODEL_RUNTIME_MODEL_MISMATCH' }
    $data = @($response.Body.data)
    if ($data.Count -ne 1 -or $null -eq $data[0].embedding) { throw 'AI_EXTERNAL_MODEL_RESPONSE_INVALID' }
    $vector = @($data[0].embedding)
    if ($vector.Count -ne [int]$Plan.Dimension) { throw 'AI_EXTERNAL_MODEL_DIMENSION_MISMATCH' }
    if (@($vector | Where-Object { -not (Test-LabAiExternalModelNumericValue -Value $_) }).Count -gt 0) {
        throw 'AI_EXTERNAL_MODEL_VECTOR_INVALID'
    }

    $durationMilliseconds=[Math]::Max(0,[int64]$started.ElapsedMilliseconds)
    $verifiedAtUtc=[DateTime]::UtcNow.ToString('o',[Globalization.CultureInfo]::InvariantCulture)
    $receiptIdentity=[ordered]@{
        Contract='SqlServerLab.AiExternalModelEndpointReceiptBinding/1.0';PlanKey=[string]$Plan.PlanKey
        Backend=[string]$Plan.Backend;Dimension=[int]$Plan.Dimension;HttpStatus=$statusCode
        ServerCertificateSha256=$observedPin;DurationMilliseconds=$durationMilliseconds;VerifiedAtUtc=$verifiedAtUtc
    }
    return [PSCustomObject]@{
        Contract=[PSCustomObject]@{Name='SqlServerLab.AiExternalModelEndpointReceipt';Version='1.0'}
        Status='ENDPOINT_VERIFIED';EvidenceStatus='LIVE_ENDPOINT';PlanKey=[string]$Plan.PlanKey
        Backend=[string]$Plan.Backend;Dimension=[int]$Plan.Dimension;HttpStatus=$statusCode
        ServerCertificateSha256=$observedPin;DurationMilliseconds=$durationMilliseconds;VerifiedAtUtc=$verifiedAtUtc
        ReceiptKey=Get-LabAiPlanKey -InputObject $receiptIdentity
        VerifiedEvidence=@('HTTPS_CERTIFICATE_MATCH','OPENAI_RESPONSE_SHAPE_MATCH','RUNTIME_MODEL_MATCH','EMBEDDING_DIMENSION_MATCH','FINITE_NUMERIC_VECTOR_MATCH')
        PendingEvidence=@('RUNTIME_BINARY_MATCH','MODEL_FILE_MATCH','ACCELERATOR_RUNTIME_ATTESTATION')
    }
}

function Resolve-LabAiExternalModelEndpointReceipt {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)]$EndpointReceipt,
        [ValidateRange(30,3600)][int]$MaxEndpointAgeSeconds = 300
    )
    $canonicalPlan=Resolve-LabAiExternalModelPlan -Plan $Plan
    $verifiedAt=[DateTimeOffset]::MinValue
    if([string]$EndpointReceipt.Contract.Name -cne 'SqlServerLab.AiExternalModelEndpointReceipt' -or
       [string]$EndpointReceipt.Contract.Version -cne '1.0' -or [string]$EndpointReceipt.Status -cne 'ENDPOINT_VERIFIED' -or
       [string]$EndpointReceipt.EvidenceStatus -cne 'LIVE_ENDPOINT' -or [string]$EndpointReceipt.ReceiptKey -notmatch '^[a-f0-9]{64}$' -or
       [int64]$EndpointReceipt.DurationMilliseconds -lt 0 -or [int]$EndpointReceipt.HttpStatus -lt 200 -or
       [int]$EndpointReceipt.HttpStatus -gt 299 -or [string]$EndpointReceipt.ServerCertificateSha256 -notmatch '^[a-f0-9]{64}$' -or
       -not [DateTimeOffset]::TryParseExact([string]$EndpointReceipt.VerifiedAtUtc,'o',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$verifiedAt) -or
       $verifiedAt.Offset -ne [TimeSpan]::Zero){throw 'AI_EXTERNAL_MODEL_ENDPOINT_RECEIPT_INVALID'}
    $verified=@($EndpointReceipt.VerifiedEvidence)
    $pending=@($EndpointReceipt.PendingEvidence)
    $expectedVerified=@('HTTPS_CERTIFICATE_MATCH','OPENAI_RESPONSE_SHAPE_MATCH','RUNTIME_MODEL_MATCH','EMBEDDING_DIMENSION_MATCH','FINITE_NUMERIC_VECTOR_MATCH')
    $expectedPending=@('RUNTIME_BINARY_MATCH','MODEL_FILE_MATCH','ACCELERATOR_RUNTIME_ATTESTATION')
    if($verified.Count -ne $expectedVerified.Count -or $pending.Count -ne $expectedPending.Count -or
       @($expectedVerified|Where-Object {$_ -cnotin $verified}).Count -or @($expectedPending|Where-Object {$_ -cnotin $pending}).Count){
        throw 'AI_EXTERNAL_MODEL_ENDPOINT_RECEIPT_INVALID'
    }
    if([string]$EndpointReceipt.PlanKey -cne [string]$canonicalPlan.PlanKey -or
       [string]$EndpointReceipt.Backend -cne [string]$canonicalPlan.Backend -or
       [int]$EndpointReceipt.Dimension -ne [int]$canonicalPlan.Dimension -or
       [string]$EndpointReceipt.ServerCertificateSha256 -cne [string]$canonicalPlan.ServerCertificateSha256){
        throw 'AI_EXTERNAL_MODEL_ENDPOINT_RECEIPT_MISMATCH'
    }
    $receiptIdentity=[ordered]@{
        Contract='SqlServerLab.AiExternalModelEndpointReceiptBinding/1.0';PlanKey=[string]$EndpointReceipt.PlanKey
        Backend=[string]$EndpointReceipt.Backend;Dimension=[int]$EndpointReceipt.Dimension;HttpStatus=[int]$EndpointReceipt.HttpStatus
        ServerCertificateSha256=[string]$EndpointReceipt.ServerCertificateSha256
        DurationMilliseconds=[int64]$EndpointReceipt.DurationMilliseconds;VerifiedAtUtc=[string]$EndpointReceipt.VerifiedAtUtc
    }
    if((Get-LabAiPlanKey -InputObject $receiptIdentity) -cne [string]$EndpointReceipt.ReceiptKey){throw 'AI_EXTERNAL_MODEL_ENDPOINT_RECEIPT_INVALID'}
    $now=[DateTimeOffset]::UtcNow
    if($verifiedAt -gt $now.AddSeconds(60)){throw 'AI_EXTERNAL_MODEL_ENDPOINT_RECEIPT_INVALID'}
    if($verifiedAt -lt $now.AddSeconds(-$MaxEndpointAgeSeconds)){throw 'AI_EXTERNAL_MODEL_ENDPOINT_RECEIPT_EXPIRED'}
    [PSCustomObject]@{Plan=$canonicalPlan;VerifiedAtUtc=$verifiedAt;ReceiptKey=[string]$EndpointReceipt.ReceiptKey}
}

function New-LabAiExternalModelSqlPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)]$EndpointReceipt,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z_][A-Za-z0-9_]{0,127}$')][string]$DatabaseName,
        [ValidateRange(30,3600)][int]$MaxEndpointAgeSeconds = 300
    )
    $binding=Resolve-LabAiExternalModelEndpointReceipt -Plan $Plan -EndpointReceipt $EndpointReceipt -MaxEndpointAgeSeconds $MaxEndpointAgeSeconds
    $canonicalPlan=$binding.Plan
    $validUntil=$binding.VerifiedAtUtc.AddSeconds($MaxEndpointAgeSeconds).ToString('o',[Globalization.CultureInfo]::InvariantCulture)
    $identity=[ordered]@{
        Contract='SqlServerLab.AiExternalModelSqlPlan/1.0';DatabaseName=$DatabaseName;SqlMajorVersion=17
        ExternalModelName=[string]$canonicalPlan.ExternalModelName;CredentialName=[string]$canonicalPlan.CredentialName
        Location=[string]$canonicalPlan.Location;ApiFormat='OpenAI';RuntimeModel=[string]$canonicalPlan.RuntimeModel
        Dimension=[int]$canonicalPlan.Dimension;RetryCount=0;SourcePlanKey=[string]$canonicalPlan.PlanKey
        EndpointReceiptKey=$binding.ReceiptKey;ValidUntilUtc=$validUntil
    }
    $sqlPlan=[ordered]@{
        Contract=[PSCustomObject]@{Name='SqlServerLab.AiExternalModelSqlPlan';Version='1.0'}
        Status='PLANNED';EvidenceStatus='LIVE_ENDPOINT_BOUND';DatabaseName=$DatabaseName;SqlMajorVersion=17
        ExternalModelName=$identity.ExternalModelName;CredentialName=$identity.CredentialName;Location=$identity.Location
        ApiFormat='OpenAI';ModelType='EMBEDDINGS';RuntimeModel=$identity.RuntimeModel;Dimension=$identity.Dimension;RetryCount=0
        SourcePlanKey=$identity.SourcePlanKey;EndpointReceiptKey=$binding.ReceiptKey;ValidUntilUtc=$validUntil
        AuthenticationIdentity='HTTPEndpointHeaders';CredentialSecretRequired=$true
        MutationSequence=@('PREFLIGHT_DATABASE_VERSION_PERMISSIONS_AND_MASTER_KEY','CREATE_DATABASE_SCOPED_CREDENTIAL','CREATE_EXTERNAL_MODEL','VERIFY_EXTERNAL_MODEL_CATALOG')
        CleanupSequence=@('DROP_EXTERNAL_MODEL','DROP_DATABASE_SCOPED_CREDENTIAL','VERIFY_SQL_OBJECTS_REMOVED')
        RequiredPermissions=@('CONTROL_DATABASE','CREATE_EXTERNAL_MODEL')
        PendingEvidence=@('SQL_EXTERNAL_MODEL_CREATED','SQL_EMBEDDING_VERIFIED','SQL_RESTART_VERIFIED','ACCELERATOR_RUNTIME_ATTESTATION','SQL_CLEANUP_VERIFIED')
    }
    if($canonicalPlan.PSObject.Properties['GatewayBindingKey']){$sqlPlan.GatewayBindingKey=[string]$canonicalPlan.GatewayBindingKey}
    $sqlPlan.SqlPlanKey=Get-LabAiPlanKey -InputObject $identity
    [PSCustomObject]$sqlPlan
}

function Resolve-LabAiExternalModelSqlPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$SqlPlan)
    try{$valid=$SqlPlan|ConvertTo-Json -Depth 12|Test-Json -SchemaFile (Join-Path $script:SchemasPath 'ai-external-model-sql-plan.schema.json') -ErrorAction Stop}
    catch{throw 'AI_EXTERNAL_MODEL_SQL_PLAN_INVALID'}
    if(-not $valid){throw 'AI_EXTERNAL_MODEL_SQL_PLAN_INVALID'}
    $validUntil=[DateTimeOffset]::MinValue
    if(-not [DateTimeOffset]::TryParseExact([string]$SqlPlan.ValidUntilUtc,'o',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$validUntil) -or
       $validUntil.Offset -ne [TimeSpan]::Zero){throw 'AI_EXTERNAL_MODEL_SQL_PLAN_INVALID'}
    $identity=[ordered]@{
        Contract='SqlServerLab.AiExternalModelSqlPlan/1.0';DatabaseName=[string]$SqlPlan.DatabaseName;SqlMajorVersion=[int]$SqlPlan.SqlMajorVersion
        ExternalModelName=[string]$SqlPlan.ExternalModelName;CredentialName=[string]$SqlPlan.CredentialName
        Location=[string]$SqlPlan.Location;ApiFormat=[string]$SqlPlan.ApiFormat;RuntimeModel=[string]$SqlPlan.RuntimeModel
        Dimension=[int]$SqlPlan.Dimension;RetryCount=[int]$SqlPlan.RetryCount;SourcePlanKey=[string]$SqlPlan.SourcePlanKey
        EndpointReceiptKey=[string]$SqlPlan.EndpointReceiptKey;ValidUntilUtc=[string]$SqlPlan.ValidUntilUtc
    }
    if((Get-LabAiPlanKey -InputObject $identity) -cne [string]$SqlPlan.SqlPlanKey){throw 'AI_EXTERNAL_MODEL_SQL_PLAN_INVALID'}
    if($validUntil -lt [DateTimeOffset]::UtcNow){throw 'AI_EXTERNAL_MODEL_SQL_PLAN_EXPIRED'}
    $SqlPlan
}

function Invoke-LabAiExternalModelSqlPreflight {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$SqlPlan,
        [Parameter(Mandatory)][ValidatePattern('^[a-f0-9-]{36}$')][string]$RunId,
        [ValidatePattern('^[a-zA-Z][a-zA-Z0-9_-]{0,63}$')][string]$InstanceId='primary',
        [string]$StateRoot,
        [scriptblock]$SqlExecutor,
        $Binding,
        $BindingIdentity
    )
    $canonical=Resolve-LabAiExternalModelSqlPlan -SqlPlan $SqlPlan
    if(-not $StateRoot){$StateRoot=Get-LabStateRoot}
    if(-not $Binding){$Binding=Get-LabTransferBinding -RunId $RunId -InstanceId $InstanceId -StateRoot $StateRoot}
    if(-not $BindingIdentity){$BindingIdentity=Get-LabTransferBindingIdentity $Binding}
    if([string]$BindingIdentity.RunId -cne $RunId -or [string]$BindingIdentity.InstanceId -cne $InstanceId -or
       [string]$BindingIdentity.ScopeId -notmatch '^[a-f0-9-]{36}$' -or -not [string]$BindingIdentity.Provider){
        throw 'AI_EXTERNAL_MODEL_SQL_BINDING_INVALID'
    }
    $bindingKey=Get-LabAiPlanKey -InputObject $BindingIdentity
    $query=@'
SELECT CONVERT(int,SERVERPROPERTY('ProductMajorVersion')) AS SqlMajorVersion, DB_ID() AS DatabaseId,
 CONVERT(nvarchar(128),DB_NAME()) AS DatabaseName,
 CONVERT(nvarchar(60),DATABASEPROPERTYEX(DB_NAME(),'Status')) AS DatabaseStatus,
 CONVERT(bit,CASE WHEN DATABASEPROPERTYEX(DB_NAME(),'Updateability')='READ_WRITE' THEN 1 ELSE 0 END) AS IsReadWrite,
 CONVERT(varchar(36),database_guid) AS DatabaseGuid,
 CONVERT(bit,CASE WHEN EXISTS(SELECT 1 FROM sys.symmetric_keys WHERE name=N'##MS_DatabaseMasterKey##') THEN 1 ELSE 0 END) AS HasDatabaseMasterKey,
 CONVERT(bit,CASE WHEN EXISTS(SELECT 1 FROM sys.fn_my_permissions(NULL,'DATABASE') WHERE permission_name=N'CONTROL') THEN 1 ELSE 0 END) AS HasControlDatabase,
 CONVERT(bit,CASE WHEN EXISTS(SELECT 1 FROM sys.fn_my_permissions(NULL,'DATABASE') WHERE permission_name=N'CREATE EXTERNAL MODEL') THEN 1 ELSE 0 END) AS HasCreateExternalModel,
 CONVERT(bit,CASE WHEN EXISTS(SELECT 1 FROM sys.database_scoped_credentials WHERE name=@credential) THEN 1 ELSE 0 END) AS CredentialExists,
 CONVERT(bit,CASE WHEN EXISTS(SELECT 1 FROM sys.external_models WHERE name=@model) THEN 1 ELSE 0 END) AS ExternalModelExists
FROM sys.database_recovery_status WHERE database_id=DB_ID();
'@
    $parameters=@{credential=[string]$canonical.CredentialName;model=[string]$canonical.ExternalModelName}
    $connection=$null;$secret=$null
    try{
        if($SqlExecutor){$rows=@(& $SqlExecutor $query $parameters ([string]$canonical.DatabaseName))}
        else{
            $storedSecret=Get-LabRelationalCoreSecret -RunId $RunId -StateRoot $StateRoot
            try{$secret=$storedSecret.Copy();$secret.MakeReadOnly()}finally{$storedSecret.Dispose()}
            $connection=New-LabRelationalCoreConnection -Binding $Binding -DatabaseName ([string]$canonical.DatabaseName) -Secret $secret
            $connection.Open()
            $rows=@(Invoke-LabTransferSqlRows -Connection $connection -Query $query -Parameters $parameters -TimeoutSeconds 30)
        }
    } finally {
        if($connection){$connection.Dispose()}
        if($secret){$secret.Dispose()}
    }
    if($rows.Count -ne 1){throw 'AI_EXTERNAL_MODEL_SQL_PREFLIGHT_INVALID'}
    $row=$rows[0]
    if([int]$row.SqlMajorVersion -ne 17){throw 'AI_EXTERNAL_MODEL_SQL_VERSION_UNSUPPORTED'}
    if([int]$row.DatabaseId -le 4 -or [string]$row.DatabaseName -cne [string]$canonical.DatabaseName -or [string]$row.DatabaseGuid -notmatch '^[a-f0-9-]{36}$'){
        throw 'AI_EXTERNAL_MODEL_SQL_DATABASE_MISMATCH'
    }
    if([string]$row.DatabaseStatus -cne 'ONLINE' -or -not [bool]$row.IsReadWrite){throw 'AI_EXTERNAL_MODEL_SQL_DATABASE_UNAVAILABLE'}
    if(-not [bool]$row.HasDatabaseMasterKey){throw 'AI_EXTERNAL_MODEL_SQL_MASTER_KEY_REQUIRED'}
    if(-not [bool]$row.HasControlDatabase -or -not [bool]$row.HasCreateExternalModel){throw 'AI_EXTERNAL_MODEL_SQL_PERMISSION_DENIED'}
    if([bool]$row.CredentialExists -or [bool]$row.ExternalModelExists){throw 'AI_EXTERNAL_MODEL_SQL_OBJECT_COLLISION'}
    $verifiedAt=[DateTime]::UtcNow.ToString('o',[Globalization.CultureInfo]::InvariantCulture)
    $receiptIdentity=[ordered]@{Contract='SqlServerLab.AiExternalModelSqlPreflightBinding/1.0';SqlPlanKey=[string]$canonical.SqlPlanKey;BindingKey=$bindingKey;DatabaseGuid=[string]$row.DatabaseGuid;VerifiedAtUtc=$verifiedAt}
    [PSCustomObject][ordered]@{
        Contract=[PSCustomObject]@{Name='SqlServerLab.AiExternalModelSqlPreflightReceipt';Version='1.0'}
        Status='SQL_PREFLIGHT_VERIFIED';EvidenceStatus='LIVE_SQL_BOUND';SqlPlanKey=[string]$canonical.SqlPlanKey
        RunId=$RunId;ScopeId=[string]$BindingIdentity.ScopeId;InstanceId=$InstanceId;Provider=[string]$BindingIdentity.Provider
        BindingKey=$bindingKey;DatabaseName=[string]$canonical.DatabaseName;DatabaseGuid=[string]$row.DatabaseGuid
        SqlMajorVersion=17;VerifiedAtUtc=$verifiedAt;ReceiptKey=Get-LabAiPlanKey -InputObject $receiptIdentity
        VerifiedEvidence=@('SQL_2025_MATCH','DATABASE_ONLINE_READ_WRITE','DATABASE_MASTER_KEY_PRESENT','CONTROL_DATABASE_PERMISSION','CREATE_EXTERNAL_MODEL_PERMISSION','SQL_OBJECT_NAMES_AVAILABLE')
        PendingEvidence=@('SQL_EXTERNAL_MODEL_CREATED','SQL_EMBEDDING_VERIFIED','SQL_RESTART_VERIFIED','ACCELERATOR_RUNTIME_ATTESTATION','SQL_CLEANUP_VERIFIED')
    }
}
function Get-LabLlamaCppRuntimeCandidate {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DirectoryPath)

    $serverPath = Join-Path $DirectoryPath 'llama-server.exe'
    if (-not (Test-Path -LiteralPath $serverPath -PathType Leaf)) { return }
    $backends = [Collections.Generic.List[string]]::new()
    foreach ($entry in @(
        @('ggml-openvino.dll','LlamaCppOpenVino'), @('ggml-cuda.dll','LlamaCppCuda'),
        @('ggml-hip.dll','LlamaCppRocm'), @('ggml-vulkan.dll','LlamaCppVulkan'),
        @('ggml-sycl.dll','LlamaCppSycl')
    )) {
        if (Test-Path -LiteralPath (Join-Path $DirectoryPath $entry[0]) -PathType Leaf) { $backends.Add($entry[1]) }
    }
    $backend = if ($backends.Count -eq 1) { $backends[0] } elseif ($backends.Count -gt 1) { 'Ambiguous' } else { 'Unknown' }
    $accelerators = @('CPU')
    if ($backends.Count) { $accelerators += 'GPU' }
    if ('LlamaCppOpenVino' -in $backends) { $accelerators += 'NPU' }
    $package = Split-Path -Leaf $DirectoryPath
    $build = $null
    if ($package -match '^llama-b(?<build>[0-9]+)-bin-.+$') {
        $parsedBuild = 0L
        if ([long]::TryParse($Matches.build, [ref]$parsedBuild)) { $build = $parsedBuild }
    }
    [PSCustomObject]@{
        Contract = [PSCustomObject]@{ Name='SqlServerLab.LlamaCppRuntime'; Version='1.0' }
        Status = 'INSTALLED'; EvidenceStatus = 'FILES_ONLY'
        Backend = $backend; DetectedBackends = @($backends)
        Build = $build; Package = $package
        InstallationPath = $DirectoryPath; Invocation = $serverPath
        CandidateAccelerators = $accelerators
        SelectionEnvironment = if ($backend -eq 'LlamaCppOpenVino') { 'GGML_OPENVINO_DEVICE' } else { $null }
        PackageOrigin = 'UNVERIFIED'
        ReleaseReference = 'https://github.com/ggml-org/llama.cpp/releases'
    }
}

function Find-LabLlamaCppRuntime {
    [CmdletBinding()]
    param(
        [ValidateCount(1,32)][ValidateNotNullOrEmpty()][string[]]$SearchRoot,
        [ValidateSet('CPU','GPU','NPU')][string]$Accelerator
    )
    # Explicit roots isolate discovery from ambient host configuration.
    $roots = @($SearchRoot)
    if (-not $PSBoundParameters.ContainsKey('SearchRoot')) {
        $roots = @()
        if ($env:SQL_SERVER_LAB_LLAMA_ROOT) { $roots += $env:SQL_SERVER_LAB_LLAMA_ROOT }
        $command = Get-Command llama-server.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($command) { $roots += Split-Path -Parent $command.Source }
    }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $runtimes = foreach ($root in $roots) {
        try {
            $item = Get-Item -LiteralPath $root -Force -ErrorAction Stop
            if ($item -isnot [IO.DirectoryInfo]) { continue }
            if ($item.FullName -eq $item.Root.FullName) { throw 'LLAMA_DISCOVERY_DRIVE_ROOT_REJECTED' }
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            $children = @(Get-ChildItem -LiteralPath $item.FullName -Directory -ErrorAction Stop | Select-Object -First 257)
            if ($children.Count -gt 256) { throw 'LLAMA_DISCOVERY_ROOT_LIMIT_EXCEEDED' }
        }
        catch {
            if ($_.Exception.Message -like 'LLAMA_DISCOVERY_*') { throw }
            Write-Warning 'LLAMA_DISCOVERY_ROOT_UNREADABLE'
            continue
        }
        foreach ($directory in @($item) + $children) {
            if ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            if (-not $seen.Add($directory.FullName)) { continue }
            $runtime = Get-LabLlamaCppRuntimeCandidate -DirectoryPath $directory.FullName
            if ($runtime -and (-not $Accelerator -or $Accelerator -in $runtime.CandidateAccelerators)) { $runtime }
        }
    }
    @($runtimes | Sort-Object @{Expression={ if ($null -eq $_.Build) { 1 } else { 0 } }},
        @{Expression={ $_.Build }; Descending=$true}, InstallationPath)
}
