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
        MutationSequence=@('PREFLIGHT_DATABASE_VERSION_PERMISSIONS_AND_MASTER_KEY','CREATE_OWNERSHIP_RECEIPT','CREATE_DATABASE_SCOPED_CREDENTIAL','CREATE_EXTERNAL_MODEL','VERIFY_EXTERNAL_MODEL_CATALOG')
        CleanupSequence=@('DROP_EXTERNAL_MODEL','DROP_DATABASE_SCOPED_CREDENTIAL','DROP_OWNERSHIP_RECEIPT','VERIFY_SQL_OBJECTS_REMOVED')
        RequiredPermissions=@('CONTROL_DATABASE','CREATE_EXTERNAL_MODEL')
        PendingEvidence=@('SQL_EXTERNAL_MODEL_CREATED','SQL_EMBEDDING_VERIFIED','SQL_RESTART_VERIFIED','ACCELERATOR_RUNTIME_ATTESTATION','SQL_CLEANUP_VERIFIED')
    }
    if($canonicalPlan.PSObject.Properties['GatewayBindingKey']){$sqlPlan.GatewayBindingKey=[string]$canonicalPlan.GatewayBindingKey}
    $sqlPlan.SqlPlanKey=Get-LabAiPlanKey -InputObject $identity
    $sqlPlan.OwnershipTableName='SqlServerLabAiOwner_'+$sqlPlan.SqlPlanKey.Substring(0,24)
    [PSCustomObject]$sqlPlan
}

function Resolve-LabAiExternalModelSqlPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$SqlPlan,[switch]$AllowExpired)
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
    if((Get-LabAiPlanKey -InputObject $identity) -cne [string]$SqlPlan.SqlPlanKey -or
       [string]$SqlPlan.OwnershipTableName -cne ('SqlServerLabAiOwner_'+([string]$SqlPlan.SqlPlanKey).Substring(0,24))){
        throw 'AI_EXTERNAL_MODEL_SQL_PLAN_INVALID'
    }
    if(-not $AllowExpired -and $validUntil -lt [DateTimeOffset]::UtcNow){throw 'AI_EXTERNAL_MODEL_SQL_PLAN_EXPIRED'}
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
 CONVERT(bit,CASE WHEN EXISTS(SELECT 1 FROM sys.external_models WHERE name=@model) THEN 1 ELSE 0 END) AS ExternalModelExists,
 CONVERT(bit,CASE WHEN OBJECT_ID(@ownerTable,N'U') IS NOT NULL THEN 1 ELSE 0 END) AS OwnershipTableExists
FROM sys.database_recovery_status WHERE database_id=DB_ID();
'@
    $parameters=@{credential=[string]$canonical.CredentialName;model=[string]$canonical.ExternalModelName;ownerTable=('dbo.'+[string]$canonical.OwnershipTableName)}
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
    if([bool]$row.CredentialExists -or [bool]$row.ExternalModelExists -or [bool]$row.OwnershipTableExists){throw 'AI_EXTERNAL_MODEL_SQL_OBJECT_COLLISION'}
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

function Resolve-LabAiExternalModelSqlPreflightReceipt {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$SqlPlan,
        [Parameter(Mandatory)]$PreflightReceipt,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$InstanceId,
        [Parameter(Mandatory)]$BindingIdentity,
        [ValidateRange(30,3600)][int]$MaxPreflightAgeSeconds=300,
        [switch]$AllowExpired
    )
    try{$valid=$PreflightReceipt|ConvertTo-Json -Depth 12|Test-Json -SchemaFile (Join-Path $script:SchemasPath 'ai-external-model-sql-preflight-receipt.schema.json') -ErrorAction Stop}
    catch{throw 'AI_EXTERNAL_MODEL_SQL_PREFLIGHT_RECEIPT_INVALID'}
    if(-not $valid){throw 'AI_EXTERNAL_MODEL_SQL_PREFLIGHT_RECEIPT_INVALID'}
    $verifiedAt=[DateTimeOffset]::MinValue
    if(-not [DateTimeOffset]::TryParseExact([string]$PreflightReceipt.VerifiedAtUtc,'o',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$verifiedAt) -or
       $verifiedAt.Offset -ne [TimeSpan]::Zero -or $verifiedAt -gt [DateTimeOffset]::UtcNow.AddSeconds(60)){
        throw 'AI_EXTERNAL_MODEL_SQL_PREFLIGHT_RECEIPT_INVALID'
    }
    $identity=[ordered]@{
        Contract='SqlServerLab.AiExternalModelSqlPreflightBinding/1.0';SqlPlanKey=[string]$PreflightReceipt.SqlPlanKey
        BindingKey=[string]$PreflightReceipt.BindingKey;DatabaseGuid=[string]$PreflightReceipt.DatabaseGuid
        VerifiedAtUtc=[string]$PreflightReceipt.VerifiedAtUtc
    }
    if((Get-LabAiPlanKey -InputObject $identity) -cne [string]$PreflightReceipt.ReceiptKey){throw 'AI_EXTERNAL_MODEL_SQL_PREFLIGHT_RECEIPT_INVALID'}
    $bindingKey=Get-LabAiPlanKey -InputObject $BindingIdentity
    if([string]$PreflightReceipt.SqlPlanKey -cne [string]$SqlPlan.SqlPlanKey -or
       [string]$PreflightReceipt.RunId -cne $RunId -or [string]$PreflightReceipt.InstanceId -cne $InstanceId -or
       [string]$BindingIdentity.RunId -cne $RunId -or [string]$BindingIdentity.InstanceId -cne $InstanceId -or
       [string]$PreflightReceipt.ScopeId -cne [string]$BindingIdentity.ScopeId -or
       [string]$PreflightReceipt.Provider -cne [string]$BindingIdentity.Provider -or
       [string]$PreflightReceipt.BindingKey -cne $bindingKey -or
       [string]$PreflightReceipt.DatabaseName -cne [string]$SqlPlan.DatabaseName){
        throw 'AI_EXTERNAL_MODEL_SQL_PREFLIGHT_RECEIPT_MISMATCH'
    }
    if(-not $AllowExpired -and $verifiedAt -lt [DateTimeOffset]::UtcNow.AddSeconds(-$MaxPreflightAgeSeconds)){
        throw 'AI_EXTERNAL_MODEL_SQL_PREFLIGHT_RECEIPT_EXPIRED'
    }
    $PreflightReceipt
}

function Get-LabAiExternalModelSqlApplyJournalPath {
    param([Parameter(Mandatory)][string]$StateRoot,[Parameter(Mandatory)][string]$RunId,[Parameter(Mandatory)][string]$InstanceId,[Parameter(Mandatory)][string]$SqlPlanKey)
    $root=[IO.Path]::GetFullPath($StateRoot)
    $directory=Join-Path (Join-Path (Join-Path $root 'runs') $RunId) 'ai-external-model'
    $path=Join-Path $directory ($InstanceId+'-'+$SqlPlanKey+'.json')
    foreach($target in @($directory,$path,"$path.lock")){
        $check=Test-LabPathWithinRoot -Root $root -Path $target
        if(-not $check.Valid){throw 'AI_EXTERNAL_MODEL_SQL_APPLY_STATE_PATH_INVALID'}
    }
    [pscustomobject]@{Directory=$directory;Path=$path;LockPath="$path.lock"}
}

function Write-LabAiExternalModelSqlApplyJournal {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)]$Journal)
    $json=$Journal|ConvertTo-Json -Depth 15
    if(-not ($json|Test-Json -SchemaFile (Join-Path $script:SchemasPath 'ai-external-model-sql-apply-journal.schema.json') -ErrorAction SilentlyContinue)){
        throw 'AI_EXTERNAL_MODEL_SQL_APPLY_JOURNAL_INVALID'
    }
    Write-LabArtifactJsonAtomic -Path $Path -InputObject $Journal
}

function Read-LabAiExternalModelSqlApplyJournal {
    param([Parameter(Mandatory)][string]$Path)
    try{$json=Get-Content -LiteralPath $Path -Raw -Encoding utf8;$journal=$json|ConvertFrom-Json -Depth 15}
    catch{throw 'AI_EXTERNAL_MODEL_SQL_APPLY_JOURNAL_INVALID'}
    if(-not ($json|Test-Json -SchemaFile (Join-Path $script:SchemasPath 'ai-external-model-sql-apply-journal.schema.json') -ErrorAction SilentlyContinue)){
        throw 'AI_EXTERNAL_MODEL_SQL_APPLY_JOURNAL_INVALID'
    }
    $journal
}

function Get-LabAiExternalModelSqlApplyObservation {
    param([Parameter(Mandatory)]$SqlPlan,[Parameter(Mandatory)][scriptblock]$ExecuteSql)
    $query=@'
DECLARE @ownerObject nvarchar(300)=N'dbo.'+QUOTENAME(@ownerName);
DECLARE @ownerExists bit=CONVERT(bit,CASE WHEN OBJECT_ID(@ownerObject,N'U') IS NULL THEN 0 ELSE 1 END);
DECLARE @ownerPlanKey varchar(64)=NULL,@ownerReceiptKey varchar(64)=NULL,@ownerBindingKey varchar(64)=NULL,
        @ownerOperationId varchar(36)=NULL,@ownerDatabaseGuid varchar(36)=NULL,@ownerStatus varchar(16)=NULL,
        @ownerCredentialId int=NULL,@ownerExternalModelId int=NULL;
IF @ownerExists=1
BEGIN
 DECLARE @read nvarchar(max)=N'SELECT @plan=SqlPlanKey,@receipt=PreflightReceiptKey,@binding=BindingKey,'+
  N'@operation=CONVERT(varchar(36),OperationId),@guid=CONVERT(varchar(36),DatabaseGuid),@status=Status,@credentialId=CredentialId,@modelId=ExternalModelId FROM dbo.'+QUOTENAME(@ownerName)+N' WHERE Singleton=1;';
 EXEC sys.sp_executesql @read,N'@plan varchar(64) OUTPUT,@receipt varchar(64) OUTPUT,@binding varchar(64) OUTPUT,@operation varchar(36) OUTPUT,@guid varchar(36) OUTPUT,@status varchar(16) OUTPUT,@credentialId int OUTPUT,@modelId int OUTPUT',
   @plan=@ownerPlanKey OUTPUT,@receipt=@ownerReceiptKey OUTPUT,@binding=@ownerBindingKey OUTPUT,@operation=@ownerOperationId OUTPUT,@guid=@ownerDatabaseGuid OUTPUT,@status=@ownerStatus OUTPUT,@credentialId=@ownerCredentialId OUTPUT,@modelId=@ownerExternalModelId OUTPUT;
END;
SELECT CONVERT(varchar(36),database_guid) AS DatabaseGuid,@ownerExists AS OwnershipTableExists,
 CONVERT(bit,CASE WHEN EXISTS(SELECT 1 FROM sys.database_scoped_credentials WHERE name=@credential) THEN 1 ELSE 0 END) AS CredentialExists,
 CONVERT(bit,CASE WHEN EXISTS(SELECT 1 FROM sys.external_models WHERE name=@model) THEN 1 ELSE 0 END) AS ExternalModelExists,
 (SELECT credential_id FROM sys.database_scoped_credentials WHERE name=@credential) AS CredentialId,
 (SELECT external_model_id FROM sys.external_models WHERE name=@model) AS ExternalModelId,
 @ownerPlanKey AS OwnerPlanKey,@ownerReceiptKey AS OwnerReceiptKey,@ownerBindingKey AS OwnerBindingKey,
 @ownerOperationId AS OwnerOperationId,@ownerDatabaseGuid AS OwnerDatabaseGuid,@ownerStatus AS OwnerStatus,
 @ownerCredentialId AS OwnerCredentialId,@ownerExternalModelId AS OwnerExternalModelId
FROM sys.database_recovery_status WHERE database_id=DB_ID();
'@
    $rows=@(& $ExecuteSql $query @{ownerName=[string]$SqlPlan.OwnershipTableName;credential=[string]$SqlPlan.CredentialName;model=[string]$SqlPlan.ExternalModelName} ([string]$SqlPlan.DatabaseName))
    if($rows.Count -ne 1){throw 'AI_EXTERNAL_MODEL_SQL_APPLY_OBSERVATION_INVALID'}
    $rows[0]
}

function Test-LabAiExternalModelSqlAppliedObservation {
    param([Parameter(Mandatory)]$Observation,[Parameter(Mandatory)]$Journal)
    [bool]$Observation.OwnershipTableExists -and [bool]$Observation.CredentialExists -and [bool]$Observation.ExternalModelExists -and
    [string]$Observation.DatabaseGuid -ceq [string]$Journal.DatabaseGuid -and
    [string]$Observation.OwnerDatabaseGuid -ceq [string]$Journal.DatabaseGuid -and
    [string]$Observation.OwnerPlanKey -ceq [string]$Journal.SqlPlanKey -and
    [string]$Observation.OwnerReceiptKey -ceq [string]$Journal.PreflightReceiptKey -and
    [string]$Observation.OwnerBindingKey -ceq [string]$Journal.BindingKey -and
    [string]$Observation.OwnerOperationId -ceq [string]$Journal.OperationId -and
    $null -ne $Observation.CredentialId -and $null -ne $Observation.ExternalModelId -and
    [int]$Observation.OwnerCredentialId -eq [int]$Observation.CredentialId -and
    [int]$Observation.OwnerExternalModelId -eq [int]$Observation.ExternalModelId -and
    [string]$Observation.OwnerStatus -ceq 'APPLIED'
}

function New-LabAiExternalModelSqlApplyReceipt {
    param([Parameter(Mandatory)]$Journal)
    $verifiedAt=[DateTime]::UtcNow.ToString('o',[Globalization.CultureInfo]::InvariantCulture)
    $identity=[ordered]@{Contract='SqlServerLab.AiExternalModelSqlApplyBinding/1.0';OperationId=[string]$Journal.OperationId;SqlPlanKey=[string]$Journal.SqlPlanKey;PreflightReceiptKey=[string]$Journal.PreflightReceiptKey;BindingKey=[string]$Journal.BindingKey;DatabaseGuid=[string]$Journal.DatabaseGuid;VerifiedAtUtc=$verifiedAt}
    $result=[pscustomobject][ordered]@{
        Contract=[pscustomobject]@{Name='SqlServerLab.AiExternalModelSqlApplyReceipt';Version='1.0'}
        Status='SQL_EXTERNAL_MODEL_APPLIED';EvidenceStatus='LIVE_SQL_BOUND';OperationId=[string]$Journal.OperationId
        SqlPlanKey=[string]$Journal.SqlPlanKey;PreflightReceiptKey=[string]$Journal.PreflightReceiptKey
        RunId=[string]$Journal.RunId;ScopeId=[string]$Journal.ScopeId;InstanceId=[string]$Journal.InstanceId
        Provider=[string]$Journal.Provider;BindingKey=[string]$Journal.BindingKey;DatabaseName=[string]$Journal.DatabaseName
        DatabaseGuid=[string]$Journal.DatabaseGuid;VerifiedAtUtc=$verifiedAt
        VerifiedEvidence=@('SQL_OWNERSHIP_RECEIPT_CREATED','DATABASE_SCOPED_CREDENTIAL_CREATED','SQL_EXTERNAL_MODEL_CREATED')
        PendingEvidence=@('SQL_EMBEDDING_VERIFIED','SQL_RESTART_VERIFIED','ACCELERATOR_RUNTIME_ATTESTATION','SQL_CLEANUP_VERIFIED')
        ReceiptKey=Get-LabAiPlanKey -InputObject $identity
    }
    if(-not ($result|ConvertTo-Json -Depth 12|Test-Json -SchemaFile (Join-Path $script:SchemasPath 'ai-external-model-sql-apply-receipt.schema.json') -ErrorAction SilentlyContinue)){
        throw 'AI_EXTERNAL_MODEL_SQL_APPLY_RECEIPT_INVALID'
    }
    $result
}

function Invoke-LabAiExternalModelSqlApply {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$SqlPlan,
        [Parameter(Mandatory)]$PreflightReceipt,
        [Parameter(Mandatory)][ValidatePattern('^[a-f0-9-]{36}$')][string]$RunId,
        [ValidatePattern('^[a-zA-Z][a-zA-Z0-9_-]{0,63}$')][string]$InstanceId='primary',
        [Parameter(Mandatory)][Security.SecureString]$CredentialSecret,
        [string]$StateRoot,
        [switch]$Resume,
        [scriptblock]$SqlExecutor,
        $Binding,
        $BindingIdentity,
        [scriptblock]$FaultInjector
    )
    if(-not $StateRoot){$StateRoot=Get-LabStateRoot}
    if($CredentialSecret.Length -lt 1 -or $CredentialSecret.Length -gt 4000){throw 'AI_EXTERNAL_MODEL_SQL_CREDENTIAL_SECRET_INVALID'}
    $StateRoot=[IO.Path]::GetFullPath($StateRoot)
    $allowExpired=[bool]$Resume
    $canonical=Resolve-LabAiExternalModelSqlPlan -SqlPlan $SqlPlan -AllowExpired:$allowExpired
    if(-not $Binding){$Binding=Get-LabTransferBinding -RunId $RunId -InstanceId $InstanceId -StateRoot $StateRoot}
    if(-not $BindingIdentity){$BindingIdentity=Get-LabTransferBindingIdentity $Binding}
    $receipt=Resolve-LabAiExternalModelSqlPreflightReceipt -SqlPlan $canonical -PreflightReceipt $PreflightReceipt -RunId $RunId -InstanceId $InstanceId -BindingIdentity $BindingIdentity -AllowExpired:$allowExpired
    $paths=Get-LabAiExternalModelSqlApplyJournalPath -StateRoot $StateRoot -RunId $RunId -InstanceId $InstanceId -SqlPlanKey ([string]$canonical.SqlPlanKey)
    $null=New-Item -ItemType Directory -Path $paths.Directory -Force
    $lock=$null;$connection=$null;$sqlSecret=$null;$pointer=[IntPtr]::Zero;$plain=$null;$parameters=$null
    try{$lock=[IO.File]::Open($paths.LockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}catch{throw 'AI_EXTERNAL_MODEL_SQL_APPLY_LOCKED'}
    try{
        $journal=$null
        if(Test-Path -LiteralPath $paths.Path){
            $journal=Read-LabAiExternalModelSqlApplyJournal -Path $paths.Path
            if([string]$journal.SqlPlanKey -cne [string]$canonical.SqlPlanKey -or [string]$journal.PreflightReceiptKey -cne [string]$receipt.ReceiptKey -or
               [string]$journal.BindingKey -cne [string]$receipt.BindingKey -or [string]$journal.DatabaseGuid -cne [string]$receipt.DatabaseGuid -or
               [string]$journal.RunId -cne $RunId -or [string]$journal.InstanceId -cne $InstanceId){
                throw 'AI_EXTERNAL_MODEL_SQL_APPLY_JOURNAL_MISMATCH'
            }
            if(-not $Resume){throw 'AI_EXTERNAL_MODEL_SQL_APPLY_RESUME_REQUIRED'}
        }elseif($Resume){throw 'AI_EXTERNAL_MODEL_SQL_APPLY_JOURNAL_NOT_FOUND'}
        if($journal -and [string]$journal.Status -in @('CLEANUP_PENDING','CLEANED')){throw 'AI_EXTERNAL_MODEL_SQL_APPLY_RECOVERY_REQUIRED'}
        if(-not $journal){
            $journal=[pscustomobject][ordered]@{
                Contract='SqlServerLab.AiExternalModelSqlApplyJournal/1.0';OperationId=[guid]::NewGuid().ToString('D');Status='APPLY_PENDING'
                SqlPlanKey=[string]$canonical.SqlPlanKey;PreflightReceiptKey=[string]$receipt.ReceiptKey;BindingKey=[string]$receipt.BindingKey
                RunId=$RunId;ScopeId=[string]$receipt.ScopeId;InstanceId=$InstanceId;Provider=[string]$receipt.Provider
                DatabaseName=[string]$canonical.DatabaseName;DatabaseGuid=[string]$receipt.DatabaseGuid
                OwnershipTableName=[string]$canonical.OwnershipTableName;ExternalModelName=[string]$canonical.ExternalModelName
                CredentialName=[string]$canonical.CredentialName;Recovery='RESUME_AND_VERIFY_SQL_RECEIPT';UpdatedAtUtc=[DateTime]::UtcNow.ToString('o',[Globalization.CultureInfo]::InvariantCulture)
            }
            Write-LabAiExternalModelSqlApplyJournal -Path $paths.Path -Journal $journal
        }
        if(-not $SqlExecutor){
            $storedSecret=Get-LabRelationalCoreSecret -RunId $RunId -StateRoot $StateRoot
            try{$sqlSecret=$storedSecret.Copy();$sqlSecret.MakeReadOnly()}finally{$storedSecret.Dispose()}
            $connection=New-LabRelationalCoreConnection -Binding $Binding -DatabaseName ([string]$canonical.DatabaseName) -Secret $sqlSecret
            $connection.Open()
        }
        $executeSql={param($query,$parameters,$database)
            if($SqlExecutor){return @(& $SqlExecutor $query $parameters $database)}
            @(Invoke-LabTransferSqlRows -Connection $connection -Query $query -Parameters $parameters -TimeoutSeconds 120)
        }.GetNewClosure()
        $observation=Get-LabAiExternalModelSqlApplyObservation -SqlPlan $canonical -ExecuteSql $executeSql
        if(Test-LabAiExternalModelSqlAppliedObservation -Observation $observation -Journal $journal){
            if([string]$journal.Status -cne 'APPLIED'){$journal.Status='APPLIED';$journal.Recovery='NOT_REQUIRED';$journal.UpdatedAtUtc=[DateTime]::UtcNow.ToString('o',[Globalization.CultureInfo]::InvariantCulture);Write-LabAiExternalModelSqlApplyJournal -Path $paths.Path -Journal $journal}
            return New-LabAiExternalModelSqlApplyReceipt -Journal $journal
        }
        if([string]$journal.Status -ceq 'APPLIED'){throw 'AI_EXTERNAL_MODEL_SQL_APPLY_RECOVERY_REQUIRED'}
        $anyObject=[bool]$observation.OwnershipTableExists -or [bool]$observation.CredentialExists -or [bool]$observation.ExternalModelExists
        if($anyObject){throw 'AI_EXTERNAL_MODEL_SQL_APPLY_RECOVERY_REQUIRED'}
        if($Resume -and ([DateTimeOffset]::Parse([string]$canonical.ValidUntilUtc) -lt [DateTimeOffset]::UtcNow -or [DateTimeOffset]::Parse([string]$receipt.VerifiedAtUtc) -lt [DateTimeOffset]::UtcNow.AddSeconds(-300))){
            throw 'AI_EXTERNAL_MODEL_SQL_APPLY_REPLAN_REQUIRED'
        }
        if($FaultInjector){& $FaultInjector 'BeforeSqlMutation'}
        $pointer=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($CredentialSecret)
        $plain=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
        $applyQuery=@'
SET XACT_ABORT ON;
BEGIN TRANSACTION;
DECLARE @lockResult int;
EXEC @lockResult=sys.sp_getapplock @Resource=@lockResource,@LockMode='Exclusive',@LockOwner='Transaction',@LockTimeout=0;
IF @lockResult<0 THROW 51000,'AI_EXTERNAL_MODEL_SQL_APPLY_LOCKED',1;
IF CONVERT(int,SERVERPROPERTY('ProductMajorVersion'))<>17 THROW 51000,'AI_EXTERNAL_MODEL_SQL_VERSION_UNSUPPORTED',1;
IF NOT EXISTS(SELECT 1 FROM sys.database_recovery_status WHERE database_id=DB_ID() AND CONVERT(varchar(36),database_guid)=@databaseGuid) THROW 51000,'AI_EXTERNAL_MODEL_SQL_DATABASE_MISMATCH',1;
IF CONVERT(nvarchar(60),DATABASEPROPERTYEX(DB_NAME(),'Status'))<>N'ONLINE' OR CONVERT(nvarchar(60),DATABASEPROPERTYEX(DB_NAME(),'Updateability'))<>N'READ_WRITE' THROW 51000,'AI_EXTERNAL_MODEL_SQL_DATABASE_NOT_WRITABLE',1;
IF NOT EXISTS(SELECT 1 FROM sys.symmetric_keys WHERE name=N'##MS_DatabaseMasterKey##') THROW 51000,'AI_EXTERNAL_MODEL_SQL_MASTER_KEY_REQUIRED',1;
IF NOT EXISTS(SELECT 1 FROM sys.fn_my_permissions(NULL,'DATABASE') WHERE permission_name=N'CONTROL') OR NOT EXISTS(SELECT 1 FROM sys.fn_my_permissions(NULL,'DATABASE') WHERE permission_name=N'CREATE EXTERNAL MODEL') THROW 51000,'AI_EXTERNAL_MODEL_SQL_PERMISSION_REQUIRED',1;
IF OBJECT_ID(N'dbo.'+QUOTENAME(@ownerName),N'U') IS NOT NULL OR EXISTS(SELECT 1 FROM sys.database_scoped_credentials WHERE name=@credential) OR EXISTS(SELECT 1 FROM sys.external_models WHERE name=@modelName) THROW 51000,'AI_EXTERNAL_MODEL_SQL_OBJECT_COLLISION',1;
DECLARE @ddl nvarchar(max)=N'CREATE TABLE dbo.'+QUOTENAME(@ownerName)+N'(Singleton tinyint NOT NULL PRIMARY KEY CHECK(Singleton=1),SqlPlanKey varchar(64) NOT NULL,PreflightReceiptKey varchar(64) NOT NULL,BindingKey varchar(64) NOT NULL,OperationId uniqueidentifier NOT NULL,DatabaseGuid uniqueidentifier NOT NULL,CredentialId int NULL,ExternalModelId int NULL,Status varchar(16) NOT NULL,CreatedAtUtc datetime2(7) NOT NULL);';
EXEC(@ddl);
SET @ddl=N'INSERT dbo.'+QUOTENAME(@ownerName)+N'(Singleton,SqlPlanKey,PreflightReceiptKey,BindingKey,OperationId,DatabaseGuid,Status,CreatedAtUtc) VALUES(1,@plan,@receipt,@binding,@operation,@guid,''APPLYING'',SYSUTCDATETIME());';
EXEC sys.sp_executesql @ddl,N'@plan varchar(64),@receipt varchar(64),@binding varchar(64),@operation uniqueidentifier,@guid uniqueidentifier',@plan=@planKey,@receipt=@preflightReceiptKey,@binding=@bindingKey,@operation=@operationId,@guid=@databaseGuid;
SET @ddl=N'CREATE DATABASE SCOPED CREDENTIAL '+QUOTENAME(@credential)+N' WITH IDENTITY=''HTTPEndpointHeaders'', SECRET='''+REPLACE(@credentialSecret,'''','''''')+N''';';
EXEC(@ddl);
SET @ddl=N'CREATE EXTERNAL MODEL '+QUOTENAME(@modelName)+N' WITH (LOCATION='''+REPLACE(@location,'''','''''')+N''',API_FORMAT=''OpenAI'',MODEL_TYPE=EMBEDDINGS,MODEL='''+REPLACE(@runtimeModel,'''','''''')+N''',CREDENTIAL='+QUOTENAME(@credential)+N',PARAMETERS=''{"sql_rest_options":{"retry_count":0}}'');';
EXEC(@ddl);
DECLARE @credentialId int=(SELECT credential_id FROM sys.database_scoped_credentials WHERE name=@credential);
DECLARE @externalModelId int=(SELECT external_model_id FROM sys.external_models WHERE name=@modelName AND credential_id=@credentialId);
IF @credentialId IS NULL OR @externalModelId IS NULL THROW 51000,'AI_EXTERNAL_MODEL_SQL_APPLY_POSTCONDITION_FAILED',1;
SET @ddl=N'UPDATE dbo.'+QUOTENAME(@ownerName)+N' SET CredentialId=@credentialId,ExternalModelId=@modelId,Status=''APPLIED'' WHERE Singleton=1 AND SqlPlanKey=@plan AND PreflightReceiptKey=@receipt AND BindingKey=@binding AND OperationId=@operation AND DatabaseGuid=@guid; IF @@ROWCOUNT<>1 THROW 51000,''AI_EXTERNAL_MODEL_SQL_OWNERSHIP_MISMATCH'',1;';
EXEC sys.sp_executesql @ddl,N'@credentialId int,@modelId int,@plan varchar(64),@receipt varchar(64),@binding varchar(64),@operation uniqueidentifier,@guid uniqueidentifier',@credentialId=@credentialId,@modelId=@externalModelId,@plan=@planKey,@receipt=@preflightReceiptKey,@binding=@bindingKey,@operation=@operationId,@guid=@databaseGuid;
COMMIT TRANSACTION;
'@
        $parameters=@{lockResource=('SqlServerLab.AiExternalModel.'+[string]$canonical.SqlPlanKey);ownerName=[string]$canonical.OwnershipTableName;credential=[string]$canonical.CredentialName;modelName=[string]$canonical.ExternalModelName;databaseGuid=[string]$receipt.DatabaseGuid;planKey=[string]$canonical.SqlPlanKey;preflightReceiptKey=[string]$receipt.ReceiptKey;bindingKey=[string]$receipt.BindingKey;operationId=[string]$journal.OperationId;credentialSecret=$plain;location=[string]$canonical.Location;runtimeModel=[string]$canonical.RuntimeModel}
        $null=@(& $executeSql $applyQuery $parameters ([string]$canonical.DatabaseName))
        $plain=$null;[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer);$pointer=[IntPtr]::Zero
        if($FaultInjector){& $FaultInjector 'AfterSqlMutation'}
        $observation=Get-LabAiExternalModelSqlApplyObservation -SqlPlan $canonical -ExecuteSql $executeSql
        if(-not (Test-LabAiExternalModelSqlAppliedObservation -Observation $observation -Journal $journal)){throw 'AI_EXTERNAL_MODEL_SQL_APPLY_RECOVERY_REQUIRED'}
        $journal.Status='APPLIED';$journal.Recovery='NOT_REQUIRED';$journal.UpdatedAtUtc=[DateTime]::UtcNow.ToString('o',[Globalization.CultureInfo]::InvariantCulture)
        Write-LabAiExternalModelSqlApplyJournal -Path $paths.Path -Journal $journal
        New-LabAiExternalModelSqlApplyReceipt -Journal $journal
    }catch{
        $code=[string]$_.Exception.Message
        if($code -match '^AI_EXTERNAL_MODEL_SQL_(PLAN|PREFLIGHT_RECEIPT|APPLY_JOURNAL|APPLY_STATE_PATH|APPLY_LOCKED|APPLY_RESUME|APPLY_REPLAN|APPLY_RECOVERY|APPLY_OBSERVATION|APPLY_RECEIPT)_[A-Z_]+$' -or $code -eq 'AI_EXTERNAL_MODEL_SQL_APPLY_LOCKED'){throw $code}
        throw 'AI_EXTERNAL_MODEL_SQL_APPLY_RECOVERY_REQUIRED'
    }finally{
        if($parameters){$parameters.credentialSecret=$null}
        $plain=$null
        if($pointer -ne [IntPtr]::Zero){[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)}
        if($connection){$connection.Dispose()};if($sqlSecret){$sqlSecret.Dispose()};if($lock){$lock.Dispose()}
    }
}

function Resolve-LabAiExternalModelSqlApplyReceipt {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$SqlPlan,
        [Parameter(Mandatory)]$ApplyReceipt,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$InstanceId,
        [Parameter(Mandatory)]$BindingIdentity,
        [Parameter(Mandatory)]$Journal
    )
    try{$valid=$ApplyReceipt|ConvertTo-Json -Depth 12|Test-Json -SchemaFile (Join-Path $script:SchemasPath 'ai-external-model-sql-apply-receipt.schema.json') -ErrorAction Stop}
    catch{throw 'AI_EXTERNAL_MODEL_SQL_APPLY_RECEIPT_INVALID'}
    if(-not $valid){throw 'AI_EXTERNAL_MODEL_SQL_APPLY_RECEIPT_INVALID'}
    $identity=[ordered]@{
        Contract='SqlServerLab.AiExternalModelSqlApplyBinding/1.0';OperationId=[string]$ApplyReceipt.OperationId
        SqlPlanKey=[string]$ApplyReceipt.SqlPlanKey;PreflightReceiptKey=[string]$ApplyReceipt.PreflightReceiptKey
        BindingKey=[string]$ApplyReceipt.BindingKey;DatabaseGuid=[string]$ApplyReceipt.DatabaseGuid
        VerifiedAtUtc=[string]$ApplyReceipt.VerifiedAtUtc
    }
    if((Get-LabAiPlanKey -InputObject $identity) -cne [string]$ApplyReceipt.ReceiptKey){throw 'AI_EXTERNAL_MODEL_SQL_APPLY_RECEIPT_INVALID'}
    $bindingKey=Get-LabAiPlanKey -InputObject $BindingIdentity
    if([string]$ApplyReceipt.SqlPlanKey -cne [string]$SqlPlan.SqlPlanKey -or
       [string]$ApplyReceipt.RunId -cne $RunId -or [string]$ApplyReceipt.InstanceId -cne $InstanceId -or
       [string]$BindingIdentity.RunId -cne $RunId -or [string]$BindingIdentity.InstanceId -cne $InstanceId -or
       [string]$ApplyReceipt.ScopeId -cne [string]$BindingIdentity.ScopeId -or
       [string]$ApplyReceipt.Provider -cne [string]$BindingIdentity.Provider -or
       [string]$ApplyReceipt.BindingKey -cne $bindingKey -or
       [string]$ApplyReceipt.DatabaseName -cne [string]$SqlPlan.DatabaseName -or
       [string]$ApplyReceipt.OperationId -cne [string]$Journal.OperationId -or
       [string]$ApplyReceipt.BindingKey -cne [string]$Journal.BindingKey -or
       [string]$ApplyReceipt.RunId -cne [string]$Journal.RunId -or [string]$ApplyReceipt.ScopeId -cne [string]$Journal.ScopeId -or
       [string]$ApplyReceipt.InstanceId -cne [string]$Journal.InstanceId -or [string]$ApplyReceipt.Provider -cne [string]$Journal.Provider -or
       [string]$ApplyReceipt.DatabaseName -cne [string]$Journal.DatabaseName -or
       [string]$ApplyReceipt.PreflightReceiptKey -cne [string]$Journal.PreflightReceiptKey -or
       [string]$ApplyReceipt.DatabaseGuid -cne [string]$Journal.DatabaseGuid){
        throw 'AI_EXTERNAL_MODEL_SQL_APPLY_RECEIPT_MISMATCH'
    }
    $ApplyReceipt
}

function New-LabAiExternalModelSqlEmbeddingReceipt {
    param([Parameter(Mandatory)]$Journal,[Parameter(Mandatory)]$ApplyReceipt,[Parameter(Mandatory)][int]$Dimension,[Parameter(Mandatory)][string]$BaseType)
    $verifiedAt=[DateTime]::UtcNow.ToString('o',[Globalization.CultureInfo]::InvariantCulture)
    $identity=[ordered]@{Contract='SqlServerLab.AiExternalModelSqlEmbeddingBinding/1.0';OperationId=[string]$Journal.OperationId;SqlPlanKey=[string]$Journal.SqlPlanKey;ApplyReceiptKey=[string]$ApplyReceipt.ReceiptKey;BindingKey=[string]$Journal.BindingKey;DatabaseGuid=[string]$Journal.DatabaseGuid;Dimension=$Dimension;BaseType=$BaseType;VerifiedAtUtc=$verifiedAt}
    $result=[pscustomobject][ordered]@{
        Contract=[pscustomobject]@{Name='SqlServerLab.AiExternalModelSqlEmbeddingReceipt';Version='1.0'}
        Status='SQL_EMBEDDING_VERIFIED';EvidenceStatus='LIVE_SQL_BOUND';OperationId=[string]$Journal.OperationId
        SqlPlanKey=[string]$Journal.SqlPlanKey;ApplyReceiptKey=[string]$ApplyReceipt.ReceiptKey
        RunId=[string]$Journal.RunId;ScopeId=[string]$Journal.ScopeId;InstanceId=[string]$Journal.InstanceId
        Provider=[string]$Journal.Provider;BindingKey=[string]$Journal.BindingKey;DatabaseName=[string]$Journal.DatabaseName
        DatabaseGuid=[string]$Journal.DatabaseGuid;Dimension=$Dimension;BaseType=$BaseType;NonZero=$true;VerifiedAtUtc=$verifiedAt
        VerifiedEvidence=@('SQL_OWNERSHIP_RECEIPT_REVALIDATED','SQL_EMBEDDING_DIMENSION_VERIFIED','SQL_EMBEDDING_FINITE_NONZERO_VERIFIED')
        ReceiptKey=Get-LabAiPlanKey -InputObject $identity
    }
    if(-not ($result|ConvertTo-Json -Depth 12|Test-Json -SchemaFile (Join-Path $script:SchemasPath 'ai-external-model-sql-embedding-receipt.schema.json') -ErrorAction SilentlyContinue)){
        throw 'AI_EXTERNAL_MODEL_SQL_EMBEDDING_RECEIPT_INVALID'
    }
    $result
}

function Invoke-LabAiExternalModelSqlEmbeddingProbe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$SqlPlan,
        [Parameter(Mandatory)]$ApplyReceipt,
        [Parameter(Mandatory)][ValidatePattern('^[a-f0-9-]{36}$')][string]$RunId,
        [ValidatePattern('^[a-zA-Z][a-zA-Z0-9_-]{0,63}$')][string]$InstanceId='primary',
        [string]$StateRoot,
        [scriptblock]$SqlExecutor,
        $Binding,
        $BindingIdentity
    )
    if(-not $StateRoot){$StateRoot=Get-LabStateRoot}
    $StateRoot=[IO.Path]::GetFullPath($StateRoot)
    $canonical=Resolve-LabAiExternalModelSqlPlan -SqlPlan $SqlPlan -AllowExpired
    if(-not $Binding){$Binding=Get-LabTransferBinding -RunId $RunId -InstanceId $InstanceId -StateRoot $StateRoot}
    if(-not $BindingIdentity){$BindingIdentity=Get-LabTransferBindingIdentity $Binding}
    $paths=Get-LabAiExternalModelSqlApplyJournalPath -StateRoot $StateRoot -RunId $RunId -InstanceId $InstanceId -SqlPlanKey ([string]$canonical.SqlPlanKey)
    if(-not (Test-Path -LiteralPath $paths.Path -PathType Leaf)){throw 'AI_EXTERNAL_MODEL_SQL_EMBEDDING_JOURNAL_NOT_FOUND'}
    $lock=$null;$connection=$null;$sqlSecret=$null
    try{$lock=[IO.File]::Open($paths.LockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}catch{throw 'AI_EXTERNAL_MODEL_SQL_EMBEDDING_LOCKED'}
    try{
        $journal=Read-LabAiExternalModelSqlApplyJournal -Path $paths.Path
        if([string]$journal.SqlPlanKey -cne [string]$canonical.SqlPlanKey -or [string]$journal.RunId -cne $RunId -or [string]$journal.InstanceId -cne $InstanceId){throw 'AI_EXTERNAL_MODEL_SQL_EMBEDDING_JOURNAL_MISMATCH'}
        if([string]$journal.Status -cne 'APPLIED'){throw 'AI_EXTERNAL_MODEL_SQL_EMBEDDING_STATE_INVALID'}
        $receipt=Resolve-LabAiExternalModelSqlApplyReceipt -SqlPlan $canonical -ApplyReceipt $ApplyReceipt -RunId $RunId -InstanceId $InstanceId -BindingIdentity $BindingIdentity -Journal $journal
        if(-not $SqlExecutor){
            $storedSecret=Get-LabRelationalCoreSecret -RunId $RunId -StateRoot $StateRoot
            try{$sqlSecret=$storedSecret.Copy();$sqlSecret.MakeReadOnly()}finally{$storedSecret.Dispose()}
            $connection=New-LabRelationalCoreConnection -Binding $Binding -DatabaseName ([string]$canonical.DatabaseName) -Secret $sqlSecret
            $connection.Open()
        }
        $executeSql={param($query,$parameters,$database)
            if($SqlExecutor){return @(& $SqlExecutor $query $parameters $database)}
            @(Invoke-LabTransferSqlRows -Connection $connection -Query $query -Parameters $parameters -TimeoutSeconds 120)
        }.GetNewClosure()
        $observation=Get-LabAiExternalModelSqlApplyObservation -SqlPlan $canonical -ExecuteSql $executeSql
        if(-not (Test-LabAiExternalModelSqlAppliedObservation -Observation $observation -Journal $journal)){throw 'AI_EXTERNAL_MODEL_SQL_EMBEDDING_OWNERSHIP_MISMATCH'}
        $probeQuery=@'
SET XACT_ABORT ON;
BEGIN TRY
 BEGIN TRANSACTION;
 DECLARE @lockResult int;
 EXEC @lockResult=sys.sp_getapplock @Resource=@lockResource,@LockMode='Shared',@LockOwner='Transaction',@LockTimeout=0;
 IF @lockResult<0 THROW 51000,'AI_EXTERNAL_MODEL_SQL_EMBEDDING_LOCKED',1;
 IF CONVERT(int,SERVERPROPERTY('ProductMajorVersion'))<>17 THROW 51000,'AI_EXTERNAL_MODEL_SQL_VERSION_UNSUPPORTED',1;
 IF NOT EXISTS(SELECT 1 FROM sys.database_recovery_status WHERE database_id=DB_ID() AND CONVERT(varchar(36),database_guid)=@databaseGuid) THROW 51000,'AI_EXTERNAL_MODEL_SQL_DATABASE_MISMATCH',1;
 IF OBJECT_ID(N'dbo.'+QUOTENAME(@ownerName),N'U') IS NULL THROW 51000,'AI_EXTERNAL_MODEL_SQL_EMBEDDING_OWNERSHIP_MISMATCH',1;
 DECLARE @owned bit=0,@sql nvarchar(max)=N'SELECT @match=CONVERT(bit,CASE WHEN EXISTS(SELECT 1 FROM dbo.'+QUOTENAME(@ownerName)+N' o JOIN sys.database_scoped_credentials c ON c.name=@credential AND c.credential_id=o.CredentialId JOIN sys.external_models m ON m.name=@model AND m.external_model_id=o.ExternalModelId AND m.credential_id=c.credential_id WHERE o.Singleton=1 AND o.SqlPlanKey=@plan AND o.PreflightReceiptKey=@receipt AND o.BindingKey=@binding AND o.OperationId=@operation AND o.DatabaseGuid=@guid AND o.Status=''APPLIED'') THEN 1 ELSE 0 END);';
 EXEC sys.sp_executesql @sql,N'@match bit OUTPUT,@credential sysname,@model sysname,@plan varchar(64),@receipt varchar(64),@binding varchar(64),@operation uniqueidentifier,@guid uniqueidentifier',@match=@owned OUTPUT,@credential=@credential,@model=@modelName,@plan=@planKey,@receipt=@preflightReceiptKey,@binding=@bindingKey,@operation=@operationId,@guid=@databaseGuid;
 IF @owned<>1 THROW 51000,'AI_EXTERNAL_MODEL_SQL_EMBEDDING_OWNERSHIP_MISMATCH',1;
 SET @sql=N'DECLARE @embedding vector('+CONVERT(nvarchar(10),@dimension)+N')=AI_GENERATE_EMBEDDINGS(@probeInput USE MODEL '+QUOTENAME(@modelName)+N'); SELECT CONVERT(int,VECTORPROPERTY(@embedding,''Dimensions'')) AS Dimension,CONVERT(nvarchar(16),VECTORPROPERTY(@embedding,''BaseType'')) AS BaseType,CONVERT(float,VECTOR_NORM(@embedding,''norm2'')) AS Norm2;';
 EXEC sys.sp_executesql @sql,N'@probeInput nvarchar(128)',@probeInput=@probeInput;
 COMMIT TRANSACTION;
END TRY
BEGIN CATCH
 IF XACT_STATE()<>0 ROLLBACK TRANSACTION;
 THROW;
END CATCH;
'@
        $parameters=@{lockResource=('SqlServerLab.AiExternalModel.'+[string]$canonical.SqlPlanKey);ownerName=[string]$canonical.OwnershipTableName;credential=[string]$canonical.CredentialName;modelName=[string]$canonical.ExternalModelName;databaseGuid=[string]$journal.DatabaseGuid;planKey=[string]$journal.SqlPlanKey;preflightReceiptKey=[string]$journal.PreflightReceiptKey;bindingKey=[string]$journal.BindingKey;operationId=[string]$journal.OperationId;dimension=[int]$canonical.Dimension;probeInput='sql-server-lab-embedding-postcondition-v1'}
        $rows=@(& $executeSql $probeQuery $parameters ([string]$canonical.DatabaseName))
        if($rows.Count -ne 1){throw 'AI_EXTERNAL_MODEL_SQL_EMBEDDING_RESULT_INVALID'}
        $dimension=0
        if(-not [int]::TryParse([string]$rows[0].Dimension,[ref]$dimension) -or $dimension -ne [int]$canonical.Dimension){throw 'AI_EXTERNAL_MODEL_SQL_EMBEDDING_DIMENSION_MISMATCH'}
        $baseType=[string]$rows[0].BaseType
        if($baseType -cne 'float32'){throw 'AI_EXTERNAL_MODEL_SQL_EMBEDDING_BASE_TYPE_INVALID'}
        $norm=0.0
        if(-not [double]::TryParse([string]$rows[0].Norm2,[Globalization.NumberStyles]::Float,[Globalization.CultureInfo]::InvariantCulture,[ref]$norm) -or [double]::IsNaN($norm) -or [double]::IsInfinity($norm) -or $norm -le 0){throw 'AI_EXTERNAL_MODEL_SQL_EMBEDDING_VECTOR_INVALID'}
        New-LabAiExternalModelSqlEmbeddingReceipt -Journal $journal -ApplyReceipt $receipt -Dimension $dimension -BaseType $baseType
    }catch{
        $code=[string]$_.Exception.Message
        if($code -match '^AI_EXTERNAL_MODEL_SQL_(PLAN|APPLY_RECEIPT|EMBEDDING)_[A-Z_]+$' -or $code -eq 'AI_EXTERNAL_MODEL_SQL_EMBEDDING_LOCKED'){throw $code}
        throw 'AI_EXTERNAL_MODEL_SQL_EMBEDDING_PROBE_FAILED'
    }finally{
        if($connection){$connection.Dispose()};if($sqlSecret){$sqlSecret.Dispose()};if($lock){$lock.Dispose()}
    }
}

function Test-LabAiExternalModelSqlCleanedObservation {
    param([Parameter(Mandatory)]$Observation,[Parameter(Mandatory)]$Journal)
    [string]$Observation.DatabaseGuid -ceq [string]$Journal.DatabaseGuid -and
    -not [bool]$Observation.OwnershipTableExists -and -not [bool]$Observation.CredentialExists -and -not [bool]$Observation.ExternalModelExists
}

function New-LabAiExternalModelSqlCleanupReceipt {
    param([Parameter(Mandatory)]$Journal,[Parameter(Mandatory)]$ApplyReceipt)
    $verifiedAt=[DateTime]::UtcNow.ToString('o',[Globalization.CultureInfo]::InvariantCulture)
    $identity=[ordered]@{Contract='SqlServerLab.AiExternalModelSqlCleanupBinding/1.0';OperationId=[string]$Journal.OperationId;SqlPlanKey=[string]$Journal.SqlPlanKey;ApplyReceiptKey=[string]$ApplyReceipt.ReceiptKey;BindingKey=[string]$Journal.BindingKey;DatabaseGuid=[string]$Journal.DatabaseGuid;VerifiedAtUtc=$verifiedAt}
    $result=[pscustomobject][ordered]@{
        Contract=[pscustomobject]@{Name='SqlServerLab.AiExternalModelSqlCleanupReceipt';Version='1.0'}
        Status='SQL_EXTERNAL_MODEL_CLEANED';EvidenceStatus='LIVE_SQL_ABSENCE_BOUND';OperationId=[string]$Journal.OperationId
        SqlPlanKey=[string]$Journal.SqlPlanKey;ApplyReceiptKey=[string]$ApplyReceipt.ReceiptKey
        RunId=[string]$Journal.RunId;ScopeId=[string]$Journal.ScopeId;InstanceId=[string]$Journal.InstanceId
        Provider=[string]$Journal.Provider;BindingKey=[string]$Journal.BindingKey;DatabaseName=[string]$Journal.DatabaseName
        DatabaseGuid=[string]$Journal.DatabaseGuid;VerifiedAtUtc=$verifiedAt
        VerifiedEvidence=@('SQL_EXTERNAL_MODEL_ABSENT','DATABASE_SCOPED_CREDENTIAL_ABSENT','SQL_OWNERSHIP_RECEIPT_ABSENT')
        ReceiptKey=Get-LabAiPlanKey -InputObject $identity
    }
    if(-not ($result|ConvertTo-Json -Depth 12|Test-Json -SchemaFile (Join-Path $script:SchemasPath 'ai-external-model-sql-cleanup-receipt.schema.json') -ErrorAction SilentlyContinue)){
        throw 'AI_EXTERNAL_MODEL_SQL_CLEANUP_RECEIPT_INVALID'
    }
    $result
}

function Invoke-LabAiExternalModelSqlCleanup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$SqlPlan,
        [Parameter(Mandatory)]$ApplyReceipt,
        [Parameter(Mandatory)][ValidatePattern('^[a-f0-9-]{36}$')][string]$RunId,
        [ValidatePattern('^[a-zA-Z][a-zA-Z0-9_-]{0,63}$')][string]$InstanceId='primary',
        [string]$StateRoot,
        [switch]$Resume,
        [scriptblock]$SqlExecutor,
        $Binding,
        $BindingIdentity,
        [scriptblock]$FaultInjector
    )
    if(-not $StateRoot){$StateRoot=Get-LabStateRoot}
    $StateRoot=[IO.Path]::GetFullPath($StateRoot)
    $canonical=Resolve-LabAiExternalModelSqlPlan -SqlPlan $SqlPlan -AllowExpired
    if(-not $Binding){$Binding=Get-LabTransferBinding -RunId $RunId -InstanceId $InstanceId -StateRoot $StateRoot}
    if(-not $BindingIdentity){$BindingIdentity=Get-LabTransferBindingIdentity $Binding}
    $paths=Get-LabAiExternalModelSqlApplyJournalPath -StateRoot $StateRoot -RunId $RunId -InstanceId $InstanceId -SqlPlanKey ([string]$canonical.SqlPlanKey)
    if(-not (Test-Path -LiteralPath $paths.Path -PathType Leaf)){throw 'AI_EXTERNAL_MODEL_SQL_CLEANUP_JOURNAL_NOT_FOUND'}
    $lock=$null;$connection=$null;$sqlSecret=$null
    try{$lock=[IO.File]::Open($paths.LockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}catch{throw 'AI_EXTERNAL_MODEL_SQL_CLEANUP_LOCKED'}
    try{
        $journal=Read-LabAiExternalModelSqlApplyJournal -Path $paths.Path
        if([string]$journal.SqlPlanKey -cne [string]$canonical.SqlPlanKey -or [string]$journal.RunId -cne $RunId -or [string]$journal.InstanceId -cne $InstanceId){throw 'AI_EXTERNAL_MODEL_SQL_CLEANUP_JOURNAL_MISMATCH'}
        $receipt=Resolve-LabAiExternalModelSqlApplyReceipt -SqlPlan $canonical -ApplyReceipt $ApplyReceipt -RunId $RunId -InstanceId $InstanceId -BindingIdentity $BindingIdentity -Journal $journal
        if(-not $SqlExecutor){
            $storedSecret=Get-LabRelationalCoreSecret -RunId $RunId -StateRoot $StateRoot
            try{$sqlSecret=$storedSecret.Copy();$sqlSecret.MakeReadOnly()}finally{$storedSecret.Dispose()}
            $connection=New-LabRelationalCoreConnection -Binding $Binding -DatabaseName ([string]$canonical.DatabaseName) -Secret $sqlSecret
            $connection.Open()
        }
        $executeSql={param($query,$parameters,$database)
            if($SqlExecutor){return @(& $SqlExecutor $query $parameters $database)}
            @(Invoke-LabTransferSqlRows -Connection $connection -Query $query -Parameters $parameters -TimeoutSeconds 120)
        }.GetNewClosure()
        $observation=Get-LabAiExternalModelSqlApplyObservation -SqlPlan $canonical -ExecuteSql $executeSql
        if([string]$journal.Status -ceq 'CLEANED'){
            if(-not (Test-LabAiExternalModelSqlCleanedObservation -Observation $observation -Journal $journal)){throw 'AI_EXTERNAL_MODEL_SQL_CLEANUP_RECOVERY_REQUIRED'}
            return New-LabAiExternalModelSqlCleanupReceipt -Journal $journal -ApplyReceipt $receipt
        }
        if([string]$journal.Status -ceq 'CLEANUP_PENDING'){
            if(-not $Resume){throw 'AI_EXTERNAL_MODEL_SQL_CLEANUP_RESUME_REQUIRED'}
            if(Test-LabAiExternalModelSqlCleanedObservation -Observation $observation -Journal $journal){
                $journal.Status='CLEANED';$journal.Recovery='NOT_REQUIRED';$journal.UpdatedAtUtc=[DateTime]::UtcNow.ToString('o',[Globalization.CultureInfo]::InvariantCulture)
                Write-LabAiExternalModelSqlApplyJournal -Path $paths.Path -Journal $journal
                return New-LabAiExternalModelSqlCleanupReceipt -Journal $journal -ApplyReceipt $receipt
            }
            if(-not (Test-LabAiExternalModelSqlAppliedObservation -Observation $observation -Journal $journal)){throw 'AI_EXTERNAL_MODEL_SQL_CLEANUP_RECOVERY_REQUIRED'}
        }elseif([string]$journal.Status -ceq 'APPLIED'){
            if(-not (Test-LabAiExternalModelSqlAppliedObservation -Observation $observation -Journal $journal)){throw 'AI_EXTERNAL_MODEL_SQL_CLEANUP_RECOVERY_REQUIRED'}
            $journal.Status='CLEANUP_PENDING';$journal.Recovery='RESUME_AND_VERIFY_SQL_CLEANUP';$journal.UpdatedAtUtc=[DateTime]::UtcNow.ToString('o',[Globalization.CultureInfo]::InvariantCulture)
            Write-LabAiExternalModelSqlApplyJournal -Path $paths.Path -Journal $journal
        }else{throw 'AI_EXTERNAL_MODEL_SQL_CLEANUP_RECOVERY_REQUIRED'}
        if($FaultInjector){& $FaultInjector 'BeforeSqlMutation'}
        $cleanupQuery=@'
SET XACT_ABORT ON;
BEGIN TRANSACTION;
DECLARE @lockResult int;
EXEC @lockResult=sys.sp_getapplock @Resource=@lockResource,@LockMode='Exclusive',@LockOwner='Transaction',@LockTimeout=0;
IF @lockResult<0 THROW 51000,'AI_EXTERNAL_MODEL_SQL_CLEANUP_LOCKED',1;
IF CONVERT(int,SERVERPROPERTY('ProductMajorVersion'))<>17 THROW 51000,'AI_EXTERNAL_MODEL_SQL_VERSION_UNSUPPORTED',1;
IF NOT EXISTS(SELECT 1 FROM sys.database_recovery_status WHERE database_id=DB_ID() AND CONVERT(varchar(36),database_guid)=@databaseGuid) THROW 51000,'AI_EXTERNAL_MODEL_SQL_DATABASE_MISMATCH',1;
IF CONVERT(nvarchar(60),DATABASEPROPERTYEX(DB_NAME(),'Status'))<>N'ONLINE' OR CONVERT(nvarchar(60),DATABASEPROPERTYEX(DB_NAME(),'Updateability'))<>N'READ_WRITE' THROW 51000,'AI_EXTERNAL_MODEL_SQL_DATABASE_NOT_WRITABLE',1;
IF NOT EXISTS(SELECT 1 FROM sys.fn_my_permissions(NULL,'DATABASE') WHERE permission_name=N'CONTROL') THROW 51000,'AI_EXTERNAL_MODEL_SQL_PERMISSION_REQUIRED',1;
IF OBJECT_ID(N'dbo.'+QUOTENAME(@ownerName),N'U') IS NULL OR NOT EXISTS(SELECT 1 FROM sys.database_scoped_credentials WHERE name=@credential) OR NOT EXISTS(SELECT 1 FROM sys.external_models WHERE name=@modelName) THROW 51000,'AI_EXTERNAL_MODEL_SQL_CLEANUP_STATE_MISMATCH',1;
DECLARE @owned bit=0,@ddl nvarchar(max)=N'SELECT @match=CONVERT(bit,CASE WHEN EXISTS(SELECT 1 FROM dbo.'+QUOTENAME(@ownerName)+N' o JOIN sys.database_scoped_credentials c ON c.name=@credential AND c.credential_id=o.CredentialId JOIN sys.external_models m ON m.name=@model AND m.external_model_id=o.ExternalModelId AND m.credential_id=c.credential_id WHERE o.Singleton=1 AND o.SqlPlanKey=@plan AND o.PreflightReceiptKey=@receipt AND o.BindingKey=@binding AND o.OperationId=@operation AND o.DatabaseGuid=@guid AND o.Status=''APPLIED'') THEN 1 ELSE 0 END);';
EXEC sys.sp_executesql @ddl,N'@match bit OUTPUT,@credential sysname,@model sysname,@plan varchar(64),@receipt varchar(64),@binding varchar(64),@operation uniqueidentifier,@guid uniqueidentifier',@match=@owned OUTPUT,@credential=@credential,@model=@modelName,@plan=@planKey,@receipt=@preflightReceiptKey,@binding=@bindingKey,@operation=@operationId,@guid=@databaseGuid;
IF @owned<>1 THROW 51000,'AI_EXTERNAL_MODEL_SQL_CLEANUP_OWNERSHIP_MISMATCH',1;
SET @ddl=N'DROP EXTERNAL MODEL '+QUOTENAME(@modelName)+N';'; EXEC(@ddl);
SET @ddl=N'DROP DATABASE SCOPED CREDENTIAL '+QUOTENAME(@credential)+N';'; EXEC(@ddl);
SET @ddl=N'DROP TABLE dbo.'+QUOTENAME(@ownerName)+N';'; EXEC(@ddl);
IF OBJECT_ID(N'dbo.'+QUOTENAME(@ownerName),N'U') IS NOT NULL OR EXISTS(SELECT 1 FROM sys.database_scoped_credentials WHERE name=@credential) OR EXISTS(SELECT 1 FROM sys.external_models WHERE name=@modelName) THROW 51000,'AI_EXTERNAL_MODEL_SQL_CLEANUP_POSTCONDITION_FAILED',1;
COMMIT TRANSACTION;
'@
        $parameters=@{lockResource=('SqlServerLab.AiExternalModel.'+[string]$canonical.SqlPlanKey);ownerName=[string]$canonical.OwnershipTableName;credential=[string]$canonical.CredentialName;modelName=[string]$canonical.ExternalModelName;databaseGuid=[string]$journal.DatabaseGuid;planKey=[string]$journal.SqlPlanKey;preflightReceiptKey=[string]$journal.PreflightReceiptKey;bindingKey=[string]$journal.BindingKey;operationId=[string]$journal.OperationId}
        $null=@(& $executeSql $cleanupQuery $parameters ([string]$canonical.DatabaseName))
        if($FaultInjector){& $FaultInjector 'AfterSqlMutation'}
        $observation=Get-LabAiExternalModelSqlApplyObservation -SqlPlan $canonical -ExecuteSql $executeSql
        if(-not (Test-LabAiExternalModelSqlCleanedObservation -Observation $observation -Journal $journal)){throw 'AI_EXTERNAL_MODEL_SQL_CLEANUP_RECOVERY_REQUIRED'}
        $journal.Status='CLEANED';$journal.Recovery='NOT_REQUIRED';$journal.UpdatedAtUtc=[DateTime]::UtcNow.ToString('o',[Globalization.CultureInfo]::InvariantCulture)
        Write-LabAiExternalModelSqlApplyJournal -Path $paths.Path -Journal $journal
        New-LabAiExternalModelSqlCleanupReceipt -Journal $journal -ApplyReceipt $receipt
    }catch{
        $code=[string]$_.Exception.Message
        if($code -match '^AI_EXTERNAL_MODEL_SQL_(PLAN|APPLY_RECEIPT|CLEANUP_JOURNAL|CLEANUP_LOCKED|CLEANUP_RESUME|CLEANUP_RECOVERY|CLEANUP_RECEIPT)_[A-Z_]+$' -or $code -eq 'AI_EXTERNAL_MODEL_SQL_CLEANUP_LOCKED'){throw $code}
        throw 'AI_EXTERNAL_MODEL_SQL_CLEANUP_RECOVERY_REQUIRED'
    }finally{
        if($connection){$connection.Dispose()};if($sqlSecret){$sqlSecret.Dispose()};if($lock){$lock.Dispose()}
    }
}
function Get-LabLlamaCppRuntimeCandidate {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DirectoryPath)

    $serverFiles=@('llama-server.exe','llama-server'|ForEach-Object {Join-Path $DirectoryPath $_}|Where-Object {Test-Path -LiteralPath $_ -PathType Leaf})
    if ($serverFiles.Count -ne 1) { return }
    $serverPath=$serverFiles[0]
    $backends = [Collections.Generic.List[string]]::new()
    foreach ($entry in @(
        @(@('ggml-openvino.dll','libggml-openvino.so*','libggml-openvino.dylib'),'LlamaCppOpenVino'),
        @(@('ggml-cuda.dll','libggml-cuda.so*','libggml-cuda.dylib'),'LlamaCppCuda'),
        @(@('ggml-hip.dll','libggml-hip.so*','libggml-hip.dylib'),'LlamaCppRocm'),
        @(@('ggml-vulkan.dll','libggml-vulkan.so*','libggml-vulkan.dylib'),'LlamaCppVulkan'),
        @(@('ggml-sycl.dll','libggml-sycl.so*','libggml-sycl.dylib'),'LlamaCppSycl')
    )) {
        $files=@(Get-ChildItem -LiteralPath $DirectoryPath -File -Force -ErrorAction SilentlyContinue)
        if (@($files|Where-Object {$name=$_.Name;@($entry[0]|Where-Object {$name -like $_}).Count}).Count) { $backends.Add($entry[1]) }
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
        $command = Get-Command $(if($IsWindows){'llama-server.exe'}else{'llama-server'}) -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
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
