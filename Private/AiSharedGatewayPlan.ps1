function Test-LabAiSharedGatewayLocalHost {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$HostName)
    if($HostName -cin @('localhost','host.docker.internal','host.containers.internal')){return $true}
    $address=$null;if(-not [Net.IPAddress]::TryParse($HostName,[ref]$address)){return $false}
    if([Net.IPAddress]::IsLoopback($address) -or $address.IsIPv6LinkLocal){return $true}
    $bytes=$address.GetAddressBytes()
    if($address.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork){return $bytes[0] -eq 10 -or ($bytes[0] -eq 172 -and $bytes[1] -ge 16 -and $bytes[1] -le 31) -or ($bytes[0] -eq 192 -and $bytes[1] -eq 168) -or ($bytes[0] -eq 169 -and $bytes[1] -eq 254)}
    $bytes[0] -band 0xfe -eq 0xfc
}

function New-LabAiSharedGatewayPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9-]{0,62}$')][string]$GatewayId,
        [Parameter(Mandatory)][string]$Location,
        [Parameter(Mandatory)][ValidateSet('LlamaCppCpu','LlamaCppCuda','LlamaCppOpenVino','LlamaCppRocm','LlamaCppVulkan','LlamaCppSycl','OpenVinoModelServer')][string]$UpstreamBackend,
        [Parameter(Mandatory)][string]$UpstreamLocation,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._:/+-]{0,255}$')][string]$RuntimeModel,
        [Parameter(Mandatory)][ValidateRange(1,1998)][int]$Dimension,
        [ValidateSet('raw','nomic-search','snowflake-search')][string]$InputProfile='raw',
        [Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ModelSha256,
        [Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$RuntimeSha256,
        [Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ServerCertificateSha256,
        [Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$CertificateAuthoritySha256,
        [Parameter(Mandatory)][ValidateCount(1,64)][object[]]$Consumer
    )
    if($ServerCertificateSha256 -ceq $CertificateAuthoritySha256){throw 'AI_SHARED_GATEWAY_CERTIFICATE_HASHES_MUST_DIFFER'}
    try{$locationUri=[Uri]::new($Location,[UriKind]::Absolute)}catch{throw 'AI_SHARED_GATEWAY_LOCATION_INVALID'}
    if($locationUri.Scheme -cne 'https' -or $locationUri.AbsolutePath -cne '/v1/embeddings' -or
       -not [string]::IsNullOrEmpty($locationUri.UserInfo) -or -not [string]::IsNullOrEmpty($locationUri.Query) -or
       -not [string]::IsNullOrEmpty($locationUri.Fragment) -or $locationUri.Port -lt 1024 -or
       -not (Test-LabAiSharedGatewayLocalHost -HostName $locationUri.Host)){
        throw 'AI_SHARED_GATEWAY_LOCATION_INVALID'
    }
    try{$upstream=[Uri]::new($UpstreamLocation,[UriKind]::Absolute)}catch{throw 'AI_SHARED_GATEWAY_UPSTREAM_INVALID'}
    $address=$null
    $expectedPath=if($UpstreamBackend -ceq 'OpenVinoModelServer'){'/v3/embeddings'}else{'/v1/embeddings'}
    if($upstream.Scheme -cnotin @('http','https') -or $upstream.AbsolutePath -cne $expectedPath -or
       -not [string]::IsNullOrEmpty($upstream.UserInfo) -or -not [string]::IsNullOrEmpty($upstream.Query) -or
       -not [string]::IsNullOrEmpty($upstream.Fragment) -or $upstream.Port -lt 1024 -or
       -not [Net.IPAddress]::TryParse($upstream.Host,[ref]$address) -or -not [Net.IPAddress]::IsLoopback($address)){
        throw 'AI_SHARED_GATEWAY_UPSTREAM_INVALID'
    }
    $normalized=[Collections.Generic.List[object]]::new();$seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal);$seenSecrets=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($item in $Consumer){
        $names=@($item.PSObject.Properties.Name|Sort-Object)
        if(($names -join ',') -cne 'ApiKeyReference,DatabaseId,ExternalModelName,InstanceId,RunId'){throw 'AI_SHARED_GATEWAY_CONSUMER_INVALID'}
        $runId=[guid]::Empty;$databaseId=[guid]::Empty
        if(-not [guid]::TryParseExact([string]$item.RunId,'D',[ref]$runId) -or -not [guid]::TryParseExact([string]$item.DatabaseId,'D',[ref]$databaseId) -or
           [string]$item.InstanceId -notmatch '^[a-z][a-z0-9-]{0,62}$' -or [string]$item.ExternalModelName -notmatch '^[A-Za-z_][A-Za-z0-9_]{0,127}$' -or
           [string]$item.ApiKeyReference -notmatch '^SQL_SERVER_LAB_SECRET_[A-Z0-9_]{1,96}$'){
            throw 'AI_SHARED_GATEWAY_CONSUMER_INVALID'
        }
        $identity=('{0}|{1}|{2}' -f $runId.ToString('D'),[string]$item.InstanceId,$databaseId.ToString('D'))
        if(-not $seen.Add($identity)){throw 'AI_SHARED_GATEWAY_CONSUMER_DUPLICATE'}
        if(-not $seenSecrets.Add([string]$item.ApiKeyReference)){throw 'AI_SHARED_GATEWAY_SECRET_REFERENCE_DUPLICATE'}
        $normalized.Add([pscustomobject][ordered]@{RunId=$runId.ToString('D');InstanceId=[string]$item.InstanceId;DatabaseId=$databaseId.ToString('D');ExternalModelName=[string]$item.ExternalModelName;ApiKeyReference=[string]$item.ApiKeyReference})
    }
    $consumers=@($normalized|Sort-Object RunId,InstanceId,DatabaseId)
    $plan=[ordered]@{
        Contract=[ordered]@{Name='SqlServerLab.AiSharedGatewayPlan';Version='1.0'}
        Status='BLOCKED';EvidenceStatus='CONFIGURATION_ONLY';GatewayId=$GatewayId;ApiFormat='OpenAI'
        Location=$locationUri.AbsoluteUri;EndpointPath='/v1/embeddings';Port=$locationUri.Port
        UpstreamBackend=$UpstreamBackend;UpstreamLocation=$upstream.AbsoluteUri;RuntimeModel=$RuntimeModel;Dimension=$Dimension;InputProfile=$InputProfile
        ModelSha256=$ModelSha256.ToLowerInvariant();RuntimeSha256=$RuntimeSha256.ToLowerInvariant();ServerCertificateSha256=$ServerCertificateSha256.ToLowerInvariant();CertificateAuthoritySha256=$CertificateAuthoritySha256.ToLowerInvariant()
        Consumers=$consumers
        RequiredActions=@('ENSURE_PROTECTED_SHARED_STORAGE','ENSURE_GATEWAY_CERTIFICATE','ENSURE_PERSISTENT_GATEWAY_SERVICE','REGISTER_SQL_CONSUMERS','VERIFY_ENDPOINT_AND_CONSUMER_BINDINGS')
        Blockers=@('AI_SHARED_GATEWAY_EXECUTION_NOT_IMPLEMENTED');Warnings=@()
    }
    $plan.PlanKey=Get-LabAiPlanKey -InputObject $plan
    [pscustomobject]$plan
}

function Resolve-LabAiSharedGatewayPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Plan)

    $expectedNames=@('ApiFormat','Blockers','CertificateAuthoritySha256','Consumers','Contract','Dimension','EndpointPath','EvidenceStatus','GatewayId','InputProfile','Location','ModelSha256','PlanKey','Port','RequiredActions','RuntimeModel','RuntimeSha256','ServerCertificateSha256','Status','UpstreamBackend','UpstreamLocation','Warnings')
    $actualNames=@($Plan.PSObject.Properties.Name|Sort-Object)
    if(($actualNames -join ',') -cne (($expectedNames|Sort-Object)-join ',') -or
       [string]$Plan.Contract.Name -cne 'SqlServerLab.AiSharedGatewayPlan' -or [string]$Plan.Contract.Version -cne '1.0' -or
       [string]$Plan.PlanKey -notmatch '^[a-f0-9]{64}$'){
        throw 'AI_SHARED_GATEWAY_PLAN_INVALID'
    }
    try {
        $canonical=New-LabAiSharedGatewayPlan -GatewayId ([string]$Plan.GatewayId) -Location ([string]$Plan.Location) `
            -UpstreamBackend ([string]$Plan.UpstreamBackend) -UpstreamLocation ([string]$Plan.UpstreamLocation) `
            -RuntimeModel ([string]$Plan.RuntimeModel) -Dimension ([int]$Plan.Dimension) -InputProfile ([string]$Plan.InputProfile) `
            -ModelSha256 ([string]$Plan.ModelSha256) -RuntimeSha256 ([string]$Plan.RuntimeSha256) `
            -ServerCertificateSha256 ([string]$Plan.ServerCertificateSha256) `
            -CertificateAuthoritySha256 ([string]$Plan.CertificateAuthoritySha256) -Consumer @($Plan.Consumers)
    }
    catch {throw 'AI_SHARED_GATEWAY_PLAN_INVALID'}
    $identity=[ordered]@{}
    foreach($name in $actualNames){if($name -cne 'PlanKey'){$identity[$name]=$Plan.$name}}
    if((Get-LabAiPlanKey -InputObject $identity) -cne [string]$Plan.PlanKey -or $canonical.PlanKey -cne [string]$Plan.PlanKey){
        throw 'AI_SHARED_GATEWAY_PLAN_INVALID'
    }
    return $canonical
}
