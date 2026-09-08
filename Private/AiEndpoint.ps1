<#
.SYNOPSIS
    Fail-closed Ollama-Endpunktplanung und gemeinsamer Requestvertrag.
.DESCRIPTION
    Liest ausschließlich katalogisierte Modellidentitäten, erzeugt einen
    geheimnisfreien Endpointplan und normalisiert Embed-/Generate-Antworten.
    Der optionale Transport dient deterministischen Offline-Vertragstests.
#>

function Get-LabAiModelCatalog {
    [CmdletBinding()]
    param()

    $path = Join-Path $script:CatalogsPath 'ai-models.json'
    $raw = Get-Content -LiteralPath $path -Raw -Encoding utf8
    if (-not ($raw | Test-Json -SchemaFile (Join-Path $script:SchemasPath 'ai-model-catalog.schema.json') -ErrorAction SilentlyContinue)) {
        throw 'AI_MODEL_CATALOG_INVALID'
    }
    return $raw | ConvertFrom-Json -Depth 30
}

function Get-LabAiModelCatalogEntry {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9-]{2,95}$')][string]$ModelKey)

    $matches = @((Get-LabAiModelCatalog).models | Where-Object { [string]$_.key -ceq $ModelKey })
    if ($matches.Count -ne 1) { throw "AI_MODEL_NOT_CATALOGED: $ModelKey" }
    return $matches[0]
}

function New-LabAiEndpointPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ModelKey,
        [Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9-]{2,63}$')][string]$EndpointRef,
        [ValidateSet('stub','local','cloud')][string]$Lane,
        [switch]$AllowCloudEgress,
        [int]$MaximumRequests = 10,
        [int]$MaximumOutputTokens = 512,
        [int]$TimeoutSeconds = 60,
        [int]$RetryCount = 1,
        [ValidateRange(1024,65535)][int]$LocalPort = 11434,
        [string]$StubBaseUri,
        [ValidatePattern('^[a-fA-F0-9]{64}$')][string]$StubServerCertificateSha256
    )

    $model = Get-LabAiModelCatalogEntry -ModelKey $ModelKey
    if (-not $Lane) { $Lane = [string]$model.lane }
    $blockers = [Collections.Generic.List[string]]::new()
    if ($Lane -ne 'stub' -and $Lane -cne [string]$model.lane) { $blockers.Add('AI_ENDPOINT_MODEL_LANE_MISMATCH') }
    if ([string]$model.status -notin @('PLANNED','SUPPORTED')) { $blockers.Add('AI_ENDPOINT_MODEL_BLOCKED') }
    if ($Lane -eq 'cloud' -and -not $AllowCloudEgress) { $blockers.Add('AI_ENDPOINT_CLOUD_EGRESS_NOT_ALLOWED') }

    $stubUri = $null
    if ($Lane -eq 'stub' -and ($StubBaseUri -or $StubServerCertificateSha256)) {
        if (-not $StubBaseUri) { $blockers.Add('AI_ENDPOINT_STUB_URI_REQUIRED') }
        if (-not $StubServerCertificateSha256) { $blockers.Add('AI_ENDPOINT_STUB_CERTIFICATE_PIN_REQUIRED') }
        if ($StubBaseUri) {
            try { $stubUri = [Uri]::new($StubBaseUri, [UriKind]::Absolute) }
            catch { $blockers.Add('AI_ENDPOINT_STUB_URI_INVALID') }
            if ($stubUri) {
                if ($stubUri.Scheme -cne 'https') { $blockers.Add('AI_ENDPOINT_STUB_TLS_REQUIRED') }
                if ($stubUri.Host -cne 'localhost') { $blockers.Add('AI_ENDPOINT_STUB_LOOPBACK_REQUIRED') }
                if (-not [string]::IsNullOrEmpty($stubUri.UserInfo) -or
                    -not [string]::IsNullOrEmpty($stubUri.Query) -or
                    -not [string]::IsNullOrEmpty($stubUri.Fragment) -or
                    $stubUri.AbsolutePath -cne '/') {
                    $blockers.Add('AI_ENDPOINT_STUB_URI_INVALID')
                }
                if ($stubUri.Port -lt 1024 -or $stubUri.Port -gt 65535) { $blockers.Add('AI_ENDPOINT_STUB_PORT_INVALID') }
            }
        }
    }
    elseif ($Lane -ne 'stub' -and ($StubBaseUri -or $StubServerCertificateSha256)) {
        $blockers.Add('AI_ENDPOINT_STUB_TRUST_UNEXPECTED')
    }

    $hostName = switch ($Lane) {
        'stub' { 'stub.invalid' }
        'local' { 'localhost' }
        'cloud' { 'ollama.com' }
    }
    $credentialRef = if ($Lane -eq 'cloud') { 'SQL_SERVER_LAB_SECRET_OLLAMA' } else { $null }
    $planIdentity = [ordered]@{
        Contract='SqlServerLab.AiEndpointPlan/1.0';Lane=$Lane;EndpointRef=$EndpointRef
        ModelKey=$ModelKey;Model=[string]$model.model;IdentityPolicy=[string]$model.identityPolicy
        Purpose=[string]$model.purpose;Dimension=if ($model.dimension) { [int]$model.dimension } else { $null }
        Port=if ($Lane -eq 'local') { $LocalPort } elseif ($stubUri) { $stubUri.Port } else { $null }
        ServerCertificateSha256=if ($StubServerCertificateSha256) { $StubServerCertificateSha256.ToLowerInvariant() } else { $null }
        CredentialRef=$credentialRef;Egress=if ($AllowCloudEgress) { 'explicit' } else { 'denied' }
        RequestBudget=[ordered]@{MaximumRequests=$MaximumRequests;MaximumOutputTokens=$MaximumOutputTokens;TimeoutSeconds=$TimeoutSeconds;RetryCount=$RetryCount}
    }
    return [PSCustomObject]@{
        Contract=[PSCustomObject]@{Name='SqlServerLab.AiEndpointPlan';Version='1.0'}
        Status=if ($blockers.Count) { 'BLOCKED' } else { 'NOT_PROBED' }
        Lane=$Lane;EndpointRef=$EndpointRef;TargetHost=if ($stubUri) { $stubUri.Host } else { $hostName };ModelKey=$ModelKey
        Purpose=[string]$model.purpose;Dimension=if ($model.dimension) { [int]$model.dimension } else { $null }
        Port=if ($Lane -eq 'local') { $LocalPort } elseif ($stubUri) { $stubUri.Port } else { $null }
        ServerCertificateSha256=if ($StubServerCertificateSha256) { $StubServerCertificateSha256.ToLowerInvariant() } else { $null }
        CredentialRef=$credentialRef;Egress=if ($AllowCloudEgress) { 'explicit' } else { 'denied' }
        RequestBudget=[PSCustomObject]$planIdentity.RequestBudget
        Blockers=@($blockers);Warnings=@();PlanKey=Get-LabAiPlanKey -InputObject $planIdentity
        InternalModel=[string]$model.model
        InternalBaseUri=switch ($Lane) { 'stub' { if ($stubUri) { $stubUri.AbsoluteUri.TrimEnd('/') } else { $null } }; 'local' { "http://127.0.0.1:$LocalPort" }; 'cloud' { 'https://ollama.com' } }
    }
}

function Get-LabAiCertificateSha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory)][Security.Cryptography.X509Certificates.X509Certificate2]$Certificate)

    return $Certificate.GetCertHashString([Security.Cryptography.HashAlgorithmName]::SHA256).ToLowerInvariant()
}

function Get-LabAiDotEnvSecret {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw 'AI_SECRET_FILE_MISSING' }
    $warnings = [Collections.Generic.List[string]]::new()
    if ($IsWindows) {
        try {
            $broad = @(Get-Acl -LiteralPath $Path -ErrorAction Stop).Access | Where-Object {
                [string]$_.IdentityReference -match '(?i)(Everyone|Authenticated Users|BUILTIN\\Users|Jeder|Authentifizierte Benutzer|Benutzer)$' -and
                [string]$_.AccessControlType -eq 'Allow' -and
                ([int64]$_.FileSystemRights -band [int64][Security.AccessControl.FileSystemRights]::ReadData)
            }
            if (@($broad).Count -gt 0) { $warnings.Add('AI_SECRET_FILE_ACL_BROAD_READ') }
        }
        catch { $warnings.Add('AI_SECRET_FILE_ACL_NOT_VERIFIED') }
    }

    try { $lines = [IO.File]::ReadAllLines((Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path, [Text.Encoding]::UTF8) }
    catch { throw 'AI_SECRET_FILE_READ_FAILED' }
    $matches = @($lines | Where-Object { $_ -match '^\s*OLLAMA\s*=' })
    if ($matches.Count -ne 1) { throw 'AI_SECRET_OLLAMA_MISSING_OR_DUPLICATE' }
    $value = [string]($matches[0] -replace '^\s*OLLAMA\s*=\s*', '')
    if (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'"))) {
        $value = $value.Substring(1, $value.Length - 2)
    }
    if ([string]::IsNullOrWhiteSpace($value)) { throw 'AI_SECRET_OLLAMA_EMPTY' }
    try {
        $secureValue = [SecureString]::new()
        foreach ($character in $value.ToCharArray()) { $secureValue.AppendChar($character) }
        $secureValue.MakeReadOnly()
        return [PSCustomObject]@{Secret=$secureValue;Warnings=@($warnings)}
    }
    finally { $value = $null; $lines = $null; $matches = $null }
}

function Invoke-LabOllamaHttpTransport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Request,
        [Parameter(Mandatory)][ValidatePattern('^https?://')][string]$BaseUri,
        [SecureString]$Credential,
        [Security.Cryptography.X509Certificates.X509Certificate2]$TrustedServerCertificate,
        [ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ExpectedServerCertificateSha256
    )

    $base = [Uri]::new($BaseUri, [UriKind]::Absolute)
    if ($TrustedServerCertificate -or $ExpectedServerCertificateSha256) {
        if ($base.Scheme -cne 'https') { throw 'AI_ENDPOINT_TLS_TRUST_REQUIRES_HTTPS' }
        if (-not $TrustedServerCertificate -or -not $ExpectedServerCertificateSha256) { throw 'AI_ENDPOINT_TLS_TRUST_INCOMPLETE' }
        if ((Get-LabAiCertificateSha256 -Certificate $TrustedServerCertificate) -cne $ExpectedServerCertificateSha256.ToLowerInvariant()) {
            throw 'AI_ENDPOINT_TLS_CERTIFICATE_MISMATCH'
        }
        $chainPolicy = [Security.Cryptography.X509Certificates.X509ChainPolicy]::new()
        $chainPolicy.TrustMode = [Security.Cryptography.X509Certificates.X509ChainTrustMode]::CustomRootTrust
        $chainPolicy.RevocationMode = [Security.Cryptography.X509Certificates.X509RevocationMode]::NoCheck
        $chainPolicy.CustomTrustStore.Add($TrustedServerCertificate)
        $sslOptions = [Net.Security.SslClientAuthenticationOptions]::new()
        $sslOptions.CertificateChainPolicy = $chainPolicy
        $handler = [Net.Http.SocketsHttpHandler]::new()
        $handler.SslOptions = $sslOptions
        $client = [Net.Http.HttpClient]::new($handler, $true)
    }
    else {
        $client = [Net.Http.HttpClient]::new()
    }
    $message = $null
    $plainCredential = $null
    try {
        $client.Timeout = [TimeSpan]::FromSeconds([int]$Request.TimeoutSeconds)
        $uri = [Uri]::new(([Uri]$BaseUri), [string]$Request.Path)
        $message = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Post, $uri)
        $message.Content = [Net.Http.StringContent]::new(($Request.Body | ConvertTo-Json -Depth 10 -Compress), [Text.Encoding]::UTF8, 'application/json')
        if ($Credential) {
            $plainCredential = ConvertFrom-LabSecureString -SecureString $Credential
            $message.Headers.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $plainCredential)
        }
        $httpResponse = $client.SendAsync($message).GetAwaiter().GetResult()
        try {
            $statusCode = [int]$httpResponse.StatusCode
            $body = $null
            if ($statusCode -ge 200 -and $statusCode -lt 300) {
                $json = $httpResponse.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                try { $body = $json | ConvertFrom-Json -Depth 30 -ErrorAction Stop }
                catch { throw 'AI_ENDPOINT_RESPONSE_INVALID' }
                finally { $json = $null }
            }
            return [PSCustomObject]@{StatusCode=$statusCode;Body=$body}
        }
        finally { $httpResponse.Dispose() }
    }
    finally {
        $plainCredential = $null
        if ($message) { $message.Dispose() }
        $client.Dispose()
    }
}

function Invoke-LabAiEndpointRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)][AllowEmptyString()][string]$InputText,
        [scriptblock]$Transport,
        [SecureString]$Credential,
        [Security.Cryptography.X509Certificates.X509Certificate2]$TrustedServerCertificate,
        [int]$RetryDelayMilliseconds = 0
    )

    if ([string]$Plan.Status -eq 'BLOCKED') { throw "AI_ENDPOINT_PLAN_BLOCKED: $(@($Plan.Blockers) -join ', ')" }
    if ([string]$Plan.Lane -eq 'cloud' -and $null -eq $Credential) { throw 'AI_ENDPOINT_CREDENTIAL_MISSING' }
    if ($TrustedServerCertificate -and -not $Plan.ServerCertificateSha256) { throw 'AI_ENDPOINT_TLS_TRUST_UNEXPECTED' }
    if (-not $Transport -and [string]$Plan.Lane -eq 'stub' -and -not $Plan.InternalBaseUri) { throw 'AI_ENDPOINT_STUB_TRANSPORT_REQUIRED' }
    if (-not $Transport -and $Plan.ServerCertificateSha256 -and -not $TrustedServerCertificate) { throw 'AI_ENDPOINT_TLS_TRUST_REQUIRED' }
    $path = if ([string]$Plan.Purpose -eq 'embedding') { '/api/embed' } else { '/api/generate' }
    $body = if ([string]$Plan.Purpose -eq 'embedding') {
        [ordered]@{model=[string]$Plan.InternalModel;input=@($InputText)}
    } else {
        [ordered]@{model=[string]$Plan.InternalModel;prompt=$InputText;stream=$false;options=[ordered]@{num_predict=[int]$Plan.RequestBudget.MaximumOutputTokens}}
    }
    $maximumAttempts = [Math]::Min([int]$Plan.RequestBudget.MaximumRequests, 1 + [int]$Plan.RequestBudget.RetryCount)
    $attempt = 0
    $response = $null
    while ($attempt -lt $maximumAttempts) {
        $attempt++
        try {
            if ($Transport) {
                $response = & $Transport ([PSCustomObject]@{Path=$path;Body=$body;TimeoutSeconds=[int]$Plan.RequestBudget.TimeoutSeconds;Attempt=$attempt})
            } else {
                $transportArguments = @{
                    Request = [PSCustomObject]@{Path=$path;Body=$body;TimeoutSeconds=[int]$Plan.RequestBudget.TimeoutSeconds;Attempt=$attempt}
                    BaseUri = [string]$Plan.InternalBaseUri
                    Credential = $Credential
                }
                if ($Plan.ServerCertificateSha256) {
                    $transportArguments.TrustedServerCertificate = $TrustedServerCertificate
                    $transportArguments.ExpectedServerCertificateSha256 = [string]$Plan.ServerCertificateSha256
                }
                $response = Invoke-LabOllamaHttpTransport @transportArguments
            }
        }
        catch [System.Threading.Tasks.TaskCanceledException] {
            if ($attempt -lt $maximumAttempts) { continue }
            throw 'AI_ENDPOINT_TIMEOUT'
        }
        catch [System.Net.Http.HttpRequestException] {
            if ($attempt -lt $maximumAttempts) { continue }
            throw 'AI_ENDPOINT_NETWORK_FAILURE'
        }
        if ($null -eq $response -or $null -eq $response.StatusCode) { throw 'AI_ENDPOINT_RESPONSE_INVALID' }
        $statusCode = [int]$response.StatusCode
        if ($statusCode -ge 200 -and $statusCode -lt 300) { break }
        $retryable = $statusCode -eq 408 -or $statusCode -eq 429 -or $statusCode -ge 500
        if (-not $retryable -or $attempt -ge $maximumAttempts) { throw "AI_ENDPOINT_HTTP_$statusCode" }
        if ($RetryDelayMilliseconds -gt 0) { Start-Sleep -Milliseconds $RetryDelayMilliseconds }
    }

    if ([string]$Plan.Purpose -eq 'embedding') {
        $vectors = @($response.Body.embeddings)
        if ($vectors.Count -ne 1) { throw 'AI_ENDPOINT_EMBEDDING_RESPONSE_INVALID' }
        $vector = @($vectors[0])
        if ($null -ne $Plan.Dimension -and $vector.Count -ne [int]$Plan.Dimension) { throw 'AI_ENDPOINT_DIMENSION_MISMATCH' }
        if (@($vector | Where-Object { $_ -isnot [ValueType] }).Count -gt 0) { throw 'AI_ENDPOINT_EMBEDDING_RESPONSE_INVALID' }
        return [PSCustomObject]@{Status='SUCCEEDED';Purpose='embedding';ModelKey=[string]$Plan.ModelKey;PlanKey=[string]$Plan.PlanKey;Attempts=$attempt;Vector=$vector}
    }
    if ([string]::IsNullOrWhiteSpace([string]$response.Body.response)) { throw 'AI_ENDPOINT_GENERATION_RESPONSE_INVALID' }
    return [PSCustomObject]@{Status='SUCCEEDED';Purpose='generation';ModelKey=[string]$Plan.ModelKey;PlanKey=[string]$Plan.PlanKey;Attempts=$attempt;Text=[string]$response.Body.response}
}
