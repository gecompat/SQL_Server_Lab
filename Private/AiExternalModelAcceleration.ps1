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
