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
        [int]$RetryCount = 1
    )

    $model = Get-LabAiModelCatalogEntry -ModelKey $ModelKey
    if (-not $Lane) { $Lane = [string]$model.lane }
    $blockers = [Collections.Generic.List[string]]::new()
    if ($Lane -ne 'stub' -and $Lane -cne [string]$model.lane) { $blockers.Add('AI_ENDPOINT_MODEL_LANE_MISMATCH') }
    if ([string]$model.status -notin @('PLANNED','SUPPORTED')) { $blockers.Add('AI_ENDPOINT_MODEL_BLOCKED') }
    if ($Lane -eq 'cloud' -and -not $AllowCloudEgress) { $blockers.Add('AI_ENDPOINT_CLOUD_EGRESS_NOT_ALLOWED') }

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
        CredentialRef=$credentialRef;Egress=if ($AllowCloudEgress) { 'explicit' } else { 'denied' }
        RequestBudget=[ordered]@{MaximumRequests=$MaximumRequests;MaximumOutputTokens=$MaximumOutputTokens;TimeoutSeconds=$TimeoutSeconds;RetryCount=$RetryCount}
    }
    return [PSCustomObject]@{
        Contract=[PSCustomObject]@{Name='SqlServerLab.AiEndpointPlan';Version='1.0'}
        Status=if ($blockers.Count) { 'BLOCKED' } else { 'NOT_PROBED' }
        Lane=$Lane;EndpointRef=$EndpointRef;TargetHost=$hostName;ModelKey=$ModelKey
        Purpose=[string]$model.purpose;Dimension=if ($model.dimension) { [int]$model.dimension } else { $null }
        CredentialRef=$credentialRef;Egress=if ($AllowCloudEgress) { 'explicit' } else { 'denied' }
        RequestBudget=[PSCustomObject]$planIdentity.RequestBudget
        Blockers=@($blockers);Warnings=@();PlanKey=Get-LabAiPlanKey -InputObject $planIdentity
        InternalModel=[string]$model.model
        InternalBaseUri=switch ($Lane) { 'stub' { $null }; 'local' { 'http://127.0.0.1:11434' }; 'cloud' { 'https://ollama.com' } }
    }
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
        [SecureString]$Credential
    )

    $client = [Net.Http.HttpClient]::new()
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
        [int]$RetryDelayMilliseconds = 0
    )

    if ([string]$Plan.Status -eq 'BLOCKED') { throw "AI_ENDPOINT_PLAN_BLOCKED: $(@($Plan.Blockers) -join ', ')" }
    if ([string]$Plan.Lane -eq 'cloud' -and $null -eq $Credential) { throw 'AI_ENDPOINT_CREDENTIAL_MISSING' }
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
                $response = Invoke-LabOllamaHttpTransport -Request ([PSCustomObject]@{Path=$path;Body=$body;TimeoutSeconds=[int]$Plan.RequestBudget.TimeoutSeconds;Attempt=$attempt}) `
                    -BaseUri ([string]$Plan.InternalBaseUri) -Credential $Credential
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
