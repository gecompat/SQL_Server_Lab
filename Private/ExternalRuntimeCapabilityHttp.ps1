# Dedicated prospective browser boundary; host observation requires an explicit request.
function Assert-LabExternalRuntimeHttpShape {
    param($Value,[string[]]$Names)
    if($Value -isnot [pscustomobject] -or @($Value.PSObject.Properties).Count -ne $Names.Count -or
        @($Value.PSObject.Properties.Name | Where-Object {$_ -cnotin $Names}).Count) {throw 'EXTERNAL_RUNTIME_HTTP_INVALID'}
}

function Assert-LabExternalRuntimeHttpDecision {
    param($Value,[switch]$IncludeRecordedEvidence)
    Assert-LabExternalRuntimeHttpShape $Value @('Contract','Provider','OperatingSystem','Identity','CatalogDecision','CurrentReadiness','HistoricalEvidence','SqlLanguageExecution','TargetAuthorization','ExecutionSupported','MutationAllowed','Actions')
    Assert-LabExternalRuntimeHttpShape $Value.Contract @('Name','Version','EvidenceBoundary')
    if($IncludeRecordedEvidence) {
        if($Value.Contract.Version -isnot [string] -or $Value.Contract.Version -cne '1.1' -or $Value.CurrentReadiness.Status -cne 'NOT_CHECKED') {throw 'EXTERNAL_RUNTIME_HTTP_INVALID'}
        $summary=ConvertTo-LabExternalRuntimeHttpHistorySummary $Value.HistoricalEvidence
        # Reuse the unchanged 1.0 authority/identity validator without mutating the public result.
        $legacy=$Value.PSObject.Copy();$legacy.Contract=$Value.Contract.PSObject.Copy();$legacy.Contract.Version='1.0'
        $legacy.HistoricalEvidence=[pscustomobject]@{Status='NOT_RECORDED';MappingStatus='NOT_DEFINED'}
        Assert-LabExternalRuntimeHttpDecision $legacy
        if($null -eq $Value.Identity -and $summary.ReasonCode -cne 'CATALOG_IDENTITY_UNRESOLVED') {throw 'EXTERNAL_RUNTIME_HTTP_INVALID'}
        return $summary
    }
    Assert-LabExternalRuntimeHttpShape $Value.CatalogDecision @('Status','ReasonCode')
    Assert-LabExternalRuntimeHttpShape $Value.CurrentReadiness @('Status','ReasonCode','RequiredCgroupVersion','LaunchMode')
    Assert-LabExternalRuntimeHttpShape $Value.HistoricalEvidence @('Status','MappingStatus')
    foreach($record in @($Value.Contract,$Value.CatalogDecision,$Value.HistoricalEvidence)) {
        foreach($property in $record.PSObject.Properties) {if($property.Value -isnot [string]) {throw 'EXTERNAL_RUNTIME_HTTP_INVALID'}}
    }
    foreach($property in @('Provider','OperatingSystem','SqlLanguageExecution','TargetAuthorization')) {
        if($Value.$property -isnot [string]) {throw 'EXTERNAL_RUNTIME_HTTP_INVALID'}
    }
    if($Value.CurrentReadiness.Status -isnot [string] -or $Value.CurrentReadiness.ReasonCode -isnot [string]) {throw 'EXTERNAL_RUNTIME_HTTP_INVALID'}
    $catalogCodes=@('NONE','CATALOG_DECISION_UNAVAILABLE','SOFTWARE_NOT_CATALOGUED','SQL_VERSION_UNKNOWN','RUNTIME_COMBINATION_NOT_CATALOGUED','SOFTWARE_PLAN_AMBIGUOUS','LEGACY_POST_START_MUTATION','IMAGE_BINDING_NOT_IMPLEMENTED','PACKAGE_NOT_LOCKED','VARIANT_PREVIEW','VARIANT_UNSUPPORTED','PROVIDER_CAPABILITY_MISSING','ARTIFACT_INTEGRITY_INCOMPLETE','PACKAGE_LOCK_INTEGRITY_INCOMPLETE')
    $hostCodes=@('NONE','READINESS_NOT_REQUESTED','CATALOG_BLOCKED','TOOL_NOT_INSTALLED','TOOL_NATIVE_PATH_REQUIRED','PROVIDER_PROBE_FAILED','PROVIDER_PROBE_TIMEOUT','PROVIDER_OUTPUT_LIMIT','PROVIDER_TERMINATION_UNCONFIRMED','PROVIDER_RESPONSE_INVALID','CGROUP_V2_REQUIRES_SQL2025','LINUX_RUNTIME_REQUIRED','CGROUP_VERSION_UNSUPPORTED','ROOTFUL_STATUS_UNKNOWN','ROOTFUL_PROVIDER_REQUIRED')
    if($Value.Contract.Name -cne 'SqlServerLab.ExternalRuntimeCapability' -or $Value.Contract.Version -cne '1.0' -or
        $Value.Contract.EvidenceBoundary -cne 'PROSPECTIVE_DECLARATION_AND_OPTIONAL_HOST_OBSERVATION' -or
        $Value.Provider -cnotin @('docker','podman') -or $Value.OperatingSystem -cne 'linux' -or
        $Value.CatalogDecision.Status -cnotin @('DECLARED_SUPPORTED','BLOCKED') -or $Value.CatalogDecision.ReasonCode -cnotin $catalogCodes -or
        $Value.CurrentReadiness.Status -cnotin @('NOT_CHECKED','READY','BLOCKED') -or $Value.CurrentReadiness.ReasonCode -cnotin $hostCodes -or
        $Value.HistoricalEvidence.Status -cne 'NOT_RECORDED' -or $Value.HistoricalEvidence.MappingStatus -cne 'NOT_DEFINED' -or
        $Value.SqlLanguageExecution -cne 'NOT_CHECKED' -or $Value.TargetAuthorization -cne 'NOT_CHECKED' -or
        $Value.ExecutionSupported -isnot [bool] -or $Value.ExecutionSupported -or $Value.MutationAllowed -isnot [bool] -or $Value.MutationAllowed -or
        $Value.Actions -isnot [array] -or $Value.Actions.Count) {throw 'EXTERNAL_RUNTIME_HTTP_INVALID'}
    foreach($pair in @(@($Value.CurrentReadiness.RequiredCgroupVersion,@('1','2')), @($Value.CurrentReadiness.LaunchMode,@('sql2019-namespace-v1','sql2022-namespace-v1','sql2025-namespace-v1','sql2025-shared-user-v2')))) {
        if($null -ne $pair[0] -and ($pair[0] -isnot [string] -or $pair[0] -cnotin $pair[1])) {throw 'EXTERNAL_RUNTIME_HTTP_INVALID'}
    }
    if($Value.CatalogDecision.Status -ceq 'BLOCKED') {
        if($null -ne $Value.Identity -or $Value.CatalogDecision.ReasonCode -ceq 'NONE' -or $Value.CurrentReadiness.Status -ceq 'READY') {throw 'EXTERNAL_RUNTIME_HTTP_INVALID'}
    } else {
        Assert-LabExternalRuntimeHttpShape $Value.Identity @('SoftwareId','VariantId','RuntimeVersion','Language','SqlVersion')
        Assert-LabExternalRuntimeHttpIdentity $Value.Identity
        if($Value.CatalogDecision.ReasonCode -cne 'NONE' -or $null -eq $Value.CurrentReadiness.RequiredCgroupVersion -or $null -eq $Value.CurrentReadiness.LaunchMode) {throw 'EXTERNAL_RUNTIME_HTTP_INVALID'}
    }
    if(($Value.CurrentReadiness.Status -ceq 'READY' -and $Value.CurrentReadiness.ReasonCode -cne 'NONE') -or
        ($Value.CurrentReadiness.Status -ceq 'NOT_CHECKED' -and $Value.CurrentReadiness.ReasonCode -cne 'READINESS_NOT_REQUESTED') -or
        ($Value.CurrentReadiness.Status -ceq 'BLOCKED' -and $Value.CurrentReadiness.ReasonCode -cin @('NONE','READINESS_NOT_REQUESTED'))) {throw 'EXTERNAL_RUNTIME_HTTP_INVALID'}
}

function ConvertTo-LabExternalRuntimeHttpHistorySummary {
    param($Value)
    Assert-LabExternalRuntimeHttpShape $Value @('Status','MappingStatus','ReasonCode','RecordCount','Cells','ReferenceVerificationStatus','EvidenceBoundary')
    $states=@{
        CATALOG_IDENTITY_UNRESOLVED=@('NOT_RECORDED','NOT_DEFINED')
        INDEX_LEGACY_IDENTITY_UNKNOWN=@('NOT_RECORDED','NOT_DEFINED')
        INDEX_NO_MATCH=@('NOT_RECORDED','DEFINED')
        INDEX_MATCH_RECORDED=@('RECORDED_HISTORY_ONLY','DEFINED')
        INDEX_NOT_PRESENT=@('UNAVAILABLE','UNAVAILABLE')
        INDEX_SCHEMA_UNSUPPORTED=@('UNAVAILABLE','UNAVAILABLE')
        INDEX_INVALID=@('UNAVAILABLE','UNAVAILABLE')
        EVIDENCE_OUTPUT_LIMIT=@('UNAVAILABLE','UNAVAILABLE')
    }
    foreach($name in @('Status','MappingStatus','ReasonCode','ReferenceVerificationStatus','EvidenceBoundary')) {
        if($Value.$name -isnot [string]) {throw 'EXTERNAL_RUNTIME_HTTP_INVALID'}
    }
    if($Value.ReasonCode -cnotin @($states.Keys) -or $Value.Status -cne $states[$Value.ReasonCode][0] -or
        $Value.MappingStatus -cne $states[$Value.ReasonCode][1] -or $Value.ReferenceVerificationStatus -cne 'NOT_VERIFIED' -or
        $Value.EvidenceBoundary -cne 'RECORDED_HISTORY_ONLY' -or ($Value.RecordCount -isnot [int] -and $Value.RecordCount -isnot [long]) -or
        $Value.RecordCount -lt 0 -or $Value.RecordCount -gt 128 -or $Value.Cells -isnot [array] -or $Value.Cells.Count -gt 128) {throw 'EXTERNAL_RUNTIME_HTTP_INVALID'}
    $count=0
    foreach($cell in $Value.Cells) {
        if($null -eq $cell -or ($cell.RecordCount -isnot [int] -and $cell.RecordCount -isnot [long]) -or $cell.RecordCount -lt 1 -or $cell.RecordCount -gt 128) {throw 'EXTERNAL_RUNTIME_HTTP_INVALID'}
        $count+=$cell.RecordCount
    }
    if($count -ne $Value.RecordCount -or (($Value.Status -ceq 'RECORDED_HISTORY_ONLY') -ne ($count -gt 0))) {throw 'EXTERNAL_RUNTIME_HTTP_INVALID'}
    # Deliberately project fixed metadata only; records, paths and references never cross this boundary.
    [pscustomobject]@{Status=$Value.Status;MappingStatus=$Value.MappingStatus;ReasonCode=$Value.ReasonCode;RecordCount=$count;
        ReferenceVerificationStatus='NOT_VERIFIED';EvidenceBoundary='RECORDED_HISTORY_ONLY'}
}

function Assert-LabExternalRuntimeHttpIdentity {
    param($Value)
    if($Value.SoftwareId -isnot [string] -or $Value.Language -isnot [string] -or $Value.SoftwareId -cnotin @('sql-python','sql-r','sql-java') -or $Value.Language -cnotin @('Python','R','Java') -or
        $Value.VariantId -isnot [string] -or $Value.VariantId -cnotmatch '^[a-z0-9][a-z0-9_-]{0,127}$' -or
        $Value.RuntimeVersion -isnot [string] -or $Value.RuntimeVersion -cnotmatch '^\d{1,3}(\.\d{1,3}){0,3}$') {throw 'EXTERNAL_RUNTIME_HTTP_INVALID'}
    # Only current catalog identities may cross the response boundary.
    $matches=@((Get-LabSoftwareCatalog).software | Where-Object {$_.id -ceq $Value.SoftwareId} | ForEach-Object {$_.variants} |
        Where-Object {$_.id -ceq $Value.VariantId -and $_.runtimeVersion -ceq $Value.RuntimeVersion -and $_.language -ceq $Value.Language})
    if($matches.Count -ne 1) {throw 'EXTERNAL_RUNTIME_HTTP_INVALID'}
    if($Value.PSObject.Properties.Name -ccontains 'SqlVersion') {
        if($Value.SqlVersion -isnot [string] -or $Value.SqlVersion -cnotmatch '^\d{4}$' -or
            @($script:VersionCatalog.versions | Where-Object {$_.id -ceq $Value.SqlVersion}).Count -ne 1) {throw 'EXTERNAL_RUNTIME_HTTP_INVALID'}
    }
}

function Invoke-LabExternalRuntimeCapabilityHttpRequest {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Request,[Parameter(Mandatory)][ValidateRange(1024,65535)][int]$ListenerPort)
    try {
        $authority="http://127.0.0.1:$ListenerPort"
        if($Request.HttpMethod -cne 'POST' -or $Request.ContentType -cnotmatch '^application/json(?:;\s*charset=utf-8)?$' -or
            $Request.LocalEndPoint.Address.ToString() -cne '127.0.0.1' -or $Request.LocalEndPoint.Port -ne $ListenerPort -or
            $Request.Url.GetLeftPart([UriPartial]::Authority) -cne $authority -or [string]$Request.Headers['Origin'] -cne $authority) {throw 'EXTERNAL_RUNTIME_HTTP_INVALID'}
        $buffer=[byte[]]::new(8193);$count=0
        while($count -lt $buffer.Length) {$read=$Request.InputStream.Read($buffer,$count,$buffer.Length-$count);if($read -eq 0){break};$count+=$read}
        if($count -gt 8192) {throw 'EXTERNAL_RUNTIME_HTTP_INVALID'}
        $text=[Text.UTF8Encoding]::new($false,$true).GetString($buffer,0,$count)
        if($text.Length -gt 4096) {throw 'EXTERNAL_RUNTIME_HTTP_INVALID'}
        $options=[Text.Json.JsonDocumentOptions]::new();$options.MaxDepth=2
        $document=[Text.Json.JsonDocument]::Parse($text,$options)
        try {
            if($document.RootElement.ValueKind -ne [Text.Json.JsonValueKind]::Object) {throw 'EXTERNAL_RUNTIME_HTTP_INVALID'}
            $keys=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase);$nodes=1
            foreach($property in $document.RootElement.EnumerateObject()) {
                if(++$nodes -gt 16 -or -not $keys.Add($property.Name) -or $property.Value.ValueKind -notin @([Text.Json.JsonValueKind]::String,[Text.Json.JsonValueKind]::True,[Text.Json.JsonValueKind]::False)) {throw 'EXTERNAL_RUNTIME_HTTP_INVALID'}
            }
        } finally {$document.Dispose()}
        $payload=$text | ConvertFrom-Json -Depth 2 -ErrorAction Stop
        if($payload.Action -cnotin @('ReadOptions','Evaluate','ReadRecordedEvidence')) {throw 'EXTERNAL_RUNTIME_HTTP_INVALID'}
        $names=@('Action','SqlVersion','Provider','OperatingSystem')
        if($payload.Action -ceq 'Evaluate') {$names+=@('SoftwareId','RuntimeVersion','VariantId','CheckProviderReadiness')}
        if($payload.Action -ceq 'ReadRecordedEvidence') {$names+=@('SoftwareId','RuntimeVersion','VariantId')}
        Assert-LabExternalRuntimeHttpShape $payload $names
        foreach($name in $names | Where-Object {$_ -cne 'CheckProviderReadiness'}) {
            if($payload.$name -isnot [string] -or [string]::IsNullOrWhiteSpace($payload.$name)) {throw 'EXTERNAL_RUNTIME_HTTP_INVALID'}
        }
        if($payload.Provider -cnotin @('docker','podman') -or $payload.OperatingSystem -cne 'linux' -or $payload.SqlVersion.Length -gt 32) {throw 'EXTERNAL_RUNTIME_HTTP_INVALID'}
        if($payload.Action -ceq 'ReadOptions') {
            $choices=@(Get-LabExternalRuntimeCapabilityOptions -SqlVersion $payload.SqlVersion -Provider $payload.Provider -OperatingSystem $payload.OperatingSystem)
            if($choices.Count -gt 128) {throw 'EXTERNAL_RUNTIME_HTTP_INVALID'}
            foreach($choice in $choices) {
                Assert-LabExternalRuntimeHttpShape $choice @('SoftwareId','Language','VariantId','RuntimeVersion','Decision')
                Assert-LabExternalRuntimeHttpIdentity $choice
                Assert-LabExternalRuntimeHttpDecision $choice.Decision
                if($choice.Decision.Provider -cne $payload.Provider -or $choice.Decision.CurrentReadiness.Status -cne 'NOT_CHECKED' -or
                    ($choice.Decision.Identity -and ($choice.Decision.Identity.SoftwareId -cne $choice.SoftwareId -or $choice.Decision.Identity.VariantId -cne $choice.VariantId -or $choice.Decision.Identity.RuntimeVersion -cne $choice.RuntimeVersion -or $choice.Decision.Identity.Language -cne $choice.Language -or $choice.Decision.Identity.SqlVersion -cne $payload.SqlVersion))) {throw 'EXTERNAL_RUNTIME_HTTP_INVALID'}
            }
            return [pscustomobject]@{ContractVersion='SqlServerLab.ExternalRuntimeCapabilityBrowser/1.0';Status='OPTIONS';Options=$choices}
        }
        if($payload.Action -ceq 'ReadRecordedEvidence') {
            if($payload.SoftwareId -cnotin @('sql-python','sql-r','sql-java') -or $payload.RuntimeVersion.Length -gt 64 -or $payload.VariantId.Length -gt 128) {throw 'EXTERNAL_RUNTIME_HTTP_INVALID'}
            $parameters=@{};foreach($name in $names|Where-Object {$_ -cne 'Action'}) {$parameters[$name]=$payload.$name}
            $parameters.IncludeRecordedEvidence=$true
            $decision=Get-SqlServerLabExternalRuntimeCapability @parameters
            $summary=Assert-LabExternalRuntimeHttpDecision $decision -IncludeRecordedEvidence
            if($decision.Provider -cne $payload.Provider -or ($decision.Identity -and
                ($decision.Identity.SoftwareId -cne $payload.SoftwareId -or $decision.Identity.VariantId -cne $payload.VariantId -or
                 $decision.Identity.RuntimeVersion -cne $payload.RuntimeVersion -or $decision.Identity.SqlVersion -cne $payload.SqlVersion))) {throw 'EXTERNAL_RUNTIME_HTTP_INVALID'}
            return [pscustomobject]@{ContractVersion='SqlServerLab.ExternalRuntimeCapabilityBrowser/1.1';Status='HISTORY';Provider=$decision.Provider;
                OperatingSystem='linux';Identity=$decision.Identity;HistoricalEvidence=$summary;CurrentReadinessStatus='NOT_CHECKED';
                SqlLanguageExecution='NOT_CHECKED';TargetAuthorization='NOT_CHECKED';ExecutionSupported=$false;MutationAllowed=$false;Actions=@()}
        }
        if($payload.CheckProviderReadiness -isnot [bool] -or $payload.SoftwareId -cnotin @('sql-python','sql-r','sql-java') -or
            $payload.RuntimeVersion.Length -gt 64 -or $payload.VariantId.Length -gt 128) {throw 'EXTERNAL_RUNTIME_HTTP_INVALID'}
        $parameters=@{};foreach($name in $names | Where-Object {$_ -cne 'Action'}) {$parameters[$name]=$payload.$name}
        $decision=Get-SqlServerLabExternalRuntimeCapability @parameters
        Assert-LabExternalRuntimeHttpDecision $decision
        if($decision.Provider -cne $payload.Provider -or (-not $payload.CheckProviderReadiness -and $decision.CurrentReadiness.Status -cne 'NOT_CHECKED') -or
            ($decision.Identity -and ($decision.Identity.SoftwareId -cne $payload.SoftwareId -or $decision.Identity.VariantId -cne $payload.VariantId -or $decision.Identity.RuntimeVersion -cne $payload.RuntimeVersion -or $decision.Identity.SqlVersion -cne $payload.SqlVersion))) {throw 'EXTERNAL_RUNTIME_HTTP_INVALID'}
        return [pscustomobject]@{ContractVersion='SqlServerLab.ExternalRuntimeCapabilityBrowser/1.0';Status='DECISION';Decision=$decision}
    } catch {throw 'EXTERNAL_RUNTIME_HTTP_INVALID'}
}
