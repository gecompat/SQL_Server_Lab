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
        [ValidateSet('raw','nomic-search','snowflake-search')][string]$InputProfile = 'raw'
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
    if ($Backend -eq 'OpenVinoModelServer' -and $TlsMode -ne 'Gateway') { $blockers.Add('AI_EXTERNAL_MODEL_OVMS_GATEWAY_REQUIRED') }
    if ($Backend -ne 'OpenVinoModelServer' -and $TlsMode -eq 'Gateway') { $warnings.Add('AI_EXTERNAL_MODEL_GATEWAY_REQUIRES_SEPARATE_BINDING') }
    if ($Backend -eq 'LlamaCppSnapdragonHexagon') { $warnings.Add('AI_EXTERNAL_MODEL_SNAPDRAGON_HEXAGON_OPT_IN') }

    $normalizedLocation = if ($uri) { $uri.AbsoluteUri } else { $Location }
    $credentialName = if ($uri) { '{0}://{1}' -f $uri.Scheme, $uri.Authority } else { $null }
    $identity = [ordered]@{
        Contract='SqlServerLab.AiExternalModelPlan/1.0';Backend=$Backend;Accelerator=$Accelerator
        Location=$normalizedLocation;ExternalModelName=$ExternalModelName;RuntimeModel=$RuntimeModel
        Dimension=$Dimension;InputProfile=$InputProfile;TlsMode=$TlsMode
        ModelSha256=$ModelSha256.ToLowerInvariant();RuntimeSha256=$RuntimeSha256.ToLowerInvariant()
        ServerCertificateSha256=$ServerCertificateSha256.ToLowerInvariant()
    }
    [PSCustomObject]@{
        Contract=[PSCustomObject]@{Name='SqlServerLab.AiExternalModelPlan';Version='1.0'}
        Status=if ($blockers.Count) { 'BLOCKED' } else { 'NOT_PROBED' }
        EvidenceStatus='CONFIGURATION_ONLY'
        Backend=$Backend;Accelerator=$Accelerator;ApiFormat='OpenAI';Location=$normalizedLocation
        EndpointPath=$expectedPath;CredentialName=$credentialName;ExternalModelName=$ExternalModelName
        RuntimeModel=$RuntimeModel;ModelType='EMBEDDINGS';Dimension=$Dimension;InputProfile=$InputProfile
        TlsMode=$TlsMode;ModelSha256=$identity.ModelSha256;RuntimeSha256=$identity.RuntimeSha256
        ServerCertificateSha256=$identity.ServerCertificateSha256
        RequiredEvidence=@('HTTPS_CERTIFICATE_MATCH','RUNTIME_BINARY_MATCH','MODEL_FILE_MATCH','EMBEDDING_DIMENSION_MATCH','ACCELERATOR_RUNTIME_ATTESTATION')
        Blockers=@($blockers);Warnings=@($warnings);PlanKey=Get-LabAiPlanKey -InputObject $identity
    }
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
    return -not [double]::IsNaN($number) -and -not [double]::IsInfinity($number)
}

function Resolve-LabAiExternalModelPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Plan)

    if ([string]$Plan.Contract.Name -cne 'SqlServerLab.AiExternalModelPlan' -or [string]$Plan.Contract.Version -cne '1.0') {
        throw 'AI_EXTERNAL_MODEL_PLAN_INVALID'
    }
    try {
        $canonicalPlan=New-LabAiExternalModelPlan -Backend ([string]$Plan.Backend) -Accelerator ([string]$Plan.Accelerator) `
            -Location ([string]$Plan.Location) -ExternalModelName ([string]$Plan.ExternalModelName) `
            -RuntimeModel ([string]$Plan.RuntimeModel) -Dimension ([int]$Plan.Dimension) `
            -ModelSha256 ([string]$Plan.ModelSha256) -RuntimeSha256 ([string]$Plan.RuntimeSha256) `
            -ServerCertificateSha256 ([string]$Plan.ServerCertificateSha256) -TlsMode ([string]$Plan.TlsMode) `
            -InputProfile ([string]$Plan.InputProfile)
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
            'HTTPS_CERTIFICATE_MATCH','OPENAI_RESPONSE_SHAPE_MATCH','EMBEDDING_DIMENSION_MATCH',
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
        $message = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Post, [Uri]$Location)
        $message.Content = [Net.Http.StringContent]::new(($Request.Body | ConvertTo-Json -Depth 10 -Compress), [Text.Encoding]::UTF8, 'application/json')
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
    $data = @($response.Body.data)
    if ($data.Count -ne 1 -or $null -eq $data[0].embedding) { throw 'AI_EXTERNAL_MODEL_RESPONSE_INVALID' }
    $vector = @($data[0].embedding)
    if ($vector.Count -ne [int]$Plan.Dimension) { throw 'AI_EXTERNAL_MODEL_DIMENSION_MISMATCH' }
    if (@($vector | Where-Object { -not (Test-LabAiExternalModelNumericValue -Value $_) }).Count -gt 0) {
        throw 'AI_EXTERNAL_MODEL_VECTOR_INVALID'
    }

    return [PSCustomObject]@{
        Contract=[PSCustomObject]@{Name='SqlServerLab.AiExternalModelEndpointReceipt';Version='1.0'}
        Status='ENDPOINT_VERIFIED';EvidenceStatus='LIVE_ENDPOINT';PlanKey=[string]$Plan.PlanKey
        Backend=[string]$Plan.Backend;Dimension=[int]$Plan.Dimension;HttpStatus=$statusCode
        ServerCertificateSha256=$observedPin;DurationMilliseconds=[Math]::Max(0,[int64]$started.ElapsedMilliseconds)
        VerifiedEvidence=@('HTTPS_CERTIFICATE_MATCH','OPENAI_RESPONSE_SHAPE_MATCH','EMBEDDING_DIMENSION_MATCH','FINITE_NUMERIC_VECTOR_MATCH')
        PendingEvidence=@('RUNTIME_BINARY_MATCH','MODEL_FILE_MATCH','ACCELERATOR_RUNTIME_ATTESTATION')
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
