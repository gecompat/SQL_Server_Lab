function Assert-LabHostMatrixHttpShape {
    param($Value,[string[]]$Names)
    if($Value -isnot [pscustomobject] -or @($Value.PSObject.Properties).Count -ne $Names.Count -or
        @($Value.PSObject.Properties.Name | Where-Object {$_ -cnotin $Names}).Count) {throw 'HOST_MATRIX_HTTP_INVALID'}
}

function Test-LabHostMatrixHttpTimestamp {
    param($Value)
    $parsed=[DateTimeOffset]::MinValue
    return $Value -is [string] -and $Value -cmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{7}Z$' -and
        [DateTimeOffset]::TryParse($Value,[ref]$parsed)
}

function ConvertTo-LabHostMatrixHttpProjection {
    param($Matrix,[string]$SqlVersion,[string[]]$Provider,[bool]$CheckProviderReadiness)
    Assert-LabHostMatrixHttpShape $Matrix @('Contract','Feature','SqlVersion','HostOperatingSystem','GeneratedAtUtc','CatalogFingerprint',
        'ProviderProfile','Providers','Capabilities','Unassessed','ManufacturerSupport','ProjectAcceptance','ExecutionSupported','MutationAllowed','Actions')
    Assert-LabHostMatrixHttpShape $Matrix.Contract @('Name','Version','EvidenceBoundary')
    foreach($value in @($Matrix.Contract.Name,$Matrix.Contract.Version,$Matrix.Contract.EvidenceBoundary,$Matrix.Feature,
        $Matrix.SqlVersion,$Matrix.HostOperatingSystem,$Matrix.ProviderProfile,$Matrix.ManufacturerSupport,$Matrix.ProjectAcceptance)) {
        if($value -isnot [string]) {throw 'HOST_MATRIX_HTTP_INVALID'}
    }
    if($Matrix.Contract.Name -cne 'SqlServerLab.HostCapabilityMatrix' -or $Matrix.Contract.Version -cne '1.0' -or
        $Matrix.Contract.EvidenceBoundary -cne 'CATALOG_AND_OPTIONAL_PROVIDER_BOOTSTRAP_ONLY' -or
        $Matrix.Feature -cne 'SqlExternalRuntime' -or $Matrix.SqlVersion -cne $SqlVersion -or
        $Matrix.HostOperatingSystem -cnotin @('windows','linux','unknown') -or
        -not (Test-LabHostMatrixHttpTimestamp $Matrix.GeneratedAtUtc) -or
        $Matrix.CatalogFingerprint -isnot [string] -or $Matrix.CatalogFingerprint -cnotmatch '^[a-f0-9]{64}$' -or
        $Matrix.ExecutionSupported -isnot [bool] -or $Matrix.ExecutionSupported -or
        $Matrix.MutationAllowed -isnot [bool] -or $Matrix.MutationAllowed -or
        $Matrix.Actions -isnot [array] -or $Matrix.Actions.Count -ne 0 -or
        $Matrix.ManufacturerSupport -cne 'NOT_ASSESSED' -or $Matrix.ProjectAcceptance -cne 'NOT_ASSESSED') {throw 'HOST_MATRIX_HTTP_INVALID'}
    $unassessed=@('SQL_BUILD','GUEST_OPERATING_SYSTEM','KERNEL_AND_CGROUP_CONTROLLERS','WSL_SHARED_KERNEL',
        'ROOTLESS_AND_LAUNCH_MODE','RESOURCES','TARGET_AUTHORIZATION','HISTORICAL_EVIDENCE','SQL_LANGUAGE_EXECUTION')
    if($Matrix.Unassessed -isnot [array] -or ($Matrix.Unassessed -join ',') -cne ($unassessed -join ',')) {throw 'HOST_MATRIX_HTTP_INVALID'}
    $providerCodes=@('PROVIDER_NOT_CHECKED','PROVIDER_OBSERVATION_INVALID','DIAGNOSTIC_READINESS_FAILED','DIAGNOSTIC_READINESS_TIMEOUT',
        'DIAGNOSTIC_READINESS_OUTPUT_LIMIT','DIAGNOSTIC_READINESS_TERMINATION_UNCONFIRMED','DIAGNOSTIC_READINESS_RESPONSE_INVALID',
        'PROVIDER_REACHABLE','PROVIDER_OS_UNSUPPORTED','TOOL_NOT_INSTALLED','PROVIDER_NOT_INSTALLED','PROVIDER_INSTALLATION_INCOMPLETE',
        'TOOL_RESOLUTION_FAILED','TOOL_NATIVE_PATH_REQUIRED','PROVIDER_ACCESS_DENIED','TOOL_EXECUTION_DENIED',
        'PROVIDER_UNREACHABLE','PROVIDER_PROBE_TIMEOUT','PROVIDER_PROBE_FAILED','PROVIDER_RESPONSE_INVALID')
    if($Matrix.Providers -isnot [array] -or ($Matrix.Providers.Provider -join ',') -cne ($Provider -join ',') -or
        $Matrix.ProviderProfile -cne (Get-LabHostMatrixProfile -Providers $Matrix.Providers)) {throw 'HOST_MATRIX_HTTP_INVALID'}
    foreach($item in $Matrix.Providers) {
        Assert-LabHostMatrixHttpShape $item @('Provider','Presence','Readiness','ReasonCode','Source','ObservedAtUtc')
        foreach($value in @($item.Provider,$item.Presence,$item.Readiness,$item.ReasonCode,$item.Source)) {
            if($value -isnot [string]) {throw 'HOST_MATRIX_HTTP_INVALID'}
        }
        if($item.Presence -cnotin @('UNKNOWN','PRESENT','MISSING','INCOMPLETE','HOST_UNSUPPORTED') -or
            $item.Readiness -cnotin @('NOT_CHECKED','UNKNOWN','READY','NOT_READY') -or $item.ReasonCode -cnotin $providerCodes -or
            $item.Source -cne 'SqlServerLab.DiagnosticProviderReadiness/1.0') {throw 'HOST_MATRIX_HTTP_INVALID'}
        if(-not $CheckProviderReadiness) {
            if($item.Readiness -cne 'NOT_CHECKED' -or $item.Presence -cne 'UNKNOWN' -or
                $item.ReasonCode -cne 'PROVIDER_NOT_CHECKED' -or $null -ne $item.ObservedAtUtc) {throw 'HOST_MATRIX_HTTP_INVALID'}
        } elseif($item.Readiness -ceq 'NOT_CHECKED' -or -not (Test-LabHostMatrixHttpTimestamp $item.ObservedAtUtc)) {throw 'HOST_MATRIX_HTTP_INVALID'}
        $expected=switch -CaseSensitive ($item.ReasonCode) {
            'PROVIDER_NOT_CHECKED' {@('UNKNOWN','NOT_CHECKED')}
            'PROVIDER_REACHABLE' {@('PRESENT','READY')}
            {$_ -cin @('TOOL_NOT_INSTALLED','PROVIDER_NOT_INSTALLED')} {@('MISSING','NOT_READY')}
            'PROVIDER_OS_UNSUPPORTED' {@('HOST_UNSUPPORTED','NOT_READY')}
            'PROVIDER_INSTALLATION_INCOMPLETE' {@('INCOMPLETE','NOT_READY')}
            {$_ -cin @('PROVIDER_ACCESS_DENIED','TOOL_EXECUTION_DENIED','PROVIDER_UNREACHABLE','PROVIDER_PROBE_TIMEOUT','PROVIDER_PROBE_FAILED')} {@('PRESENT','NOT_READY')}
            'PROVIDER_RESPONSE_INVALID' {@('PRESENT','UNKNOWN')}
            default {@('UNKNOWN','UNKNOWN')}
        }
        if($item.Presence -cne $expected[0] -or $item.Readiness -cne $expected[1]) {throw 'HOST_MATRIX_HTTP_INVALID'}
        if($item.ReasonCode -ceq 'PROVIDER_OS_UNSUPPORTED' -and ($item.Provider -cne 'hyperv' -or $Matrix.HostOperatingSystem -ceq 'windows')) {throw 'HOST_MATRIX_HTTP_INVALID'}
        if($item.Provider -ceq 'hyperv' -and $Matrix.HostOperatingSystem -cne 'windows' -and
            $item.ReasonCode -cin @('PROVIDER_REACHABLE','TOOL_NOT_INSTALLED','PROVIDER_NOT_INSTALLED','PROVIDER_INSTALLATION_INCOMPLETE',
                'TOOL_RESOLUTION_FAILED','TOOL_NATIVE_PATH_REQUIRED','PROVIDER_ACCESS_DENIED','TOOL_EXECUTION_DENIED',
                'PROVIDER_UNREACHABLE','PROVIDER_PROBE_TIMEOUT','PROVIDER_PROBE_FAILED','PROVIDER_RESPONSE_INVALID')) {throw 'HOST_MATRIX_HTTP_INVALID'}
    }
    $catalogCodes=@('NONE','CATALOG_DECISION_UNAVAILABLE','SOFTWARE_NOT_CATALOGUED','SQL_VERSION_UNKNOWN','RUNTIME_COMBINATION_NOT_CATALOGUED',
        'SOFTWARE_PLAN_AMBIGUOUS','LEGACY_POST_START_MUTATION','IMAGE_BINDING_NOT_IMPLEMENTED','PACKAGE_NOT_LOCKED','VARIANT_PREVIEW',
        'VARIANT_UNSUPPORTED','PROVIDER_CAPABILITY_MISSING','ARTIFACT_INTEGRITY_INCOMPLETE','PACKAGE_LOCK_INTEGRITY_INCOMPLETE','LANGUAGE_USER_DEFERRED')
    $nextSteps=@('RECHECK_CATALOG','REVIEW_CATALOG_SCOPE','CHECK_PROVIDER_READINESS','REVIEW_PROVIDER_READINESS',
        'ASSESS_LAUNCH_REQUIREMENTS','RECHECK_PROVIDER_READINESS','USER_DECISION_REQUIRED')
    if($Matrix.Capabilities -isnot [array] -or $Matrix.Capabilities.Count -lt 4 -or $Matrix.Capabilities.Count -gt 131) {throw 'HOST_MATRIX_HTTP_INVALID'}
    $rows=@(foreach($row in $Matrix.Capabilities) {
        Assert-LabHostMatrixHttpShape $row @('Provider','TargetOperatingSystem','Language','SoftwareId','VariantId','RuntimeVersion',
            'CatalogStatus','CatalogReasonCode','Availability','ReasonCode','NextStep','Explanation','RequiredCapabilities','ExplicitSelectionRequired')
        foreach($value in @($row.Provider,$row.TargetOperatingSystem,$row.Language,$row.CatalogStatus,$row.CatalogReasonCode,
            $row.Availability,$row.ReasonCode,$row.NextStep)) {if($value -isnot [string]) {throw 'HOST_MATRIX_HTTP_INVALID'}}
        $target=if($row.Provider -ceq 'hyperv'){'windows'}else{'linux'}
        if($row.Provider -cnotin $Provider -or $row.TargetOperatingSystem -cne $target -or
            $row.Language -cnotin @('Python','R','Java','C#') -or
            $row.CatalogStatus -cnotin @('DECLARED_SUPPORTED','BLOCKED','UNKNOWN','NOT_EVALUATED') -or
            $row.CatalogReasonCode -cnotin $catalogCodes -or
            $row.Availability -cnotin @('UNKNOWN','CATALOG_BLOCKED','NOT_CHECKED','PRECONDITION_MISSING','INCOMPLETE','USER_DEFERRED') -or
            $row.ReasonCode -cnotin ($catalogCodes+$providerCodes+@('HOST_REQUIREMENTS_NOT_CHECKED')) -or
            $row.NextStep -cnotin $nextSteps -or $row.ExplicitSelectionRequired -isnot [bool] -or
            $row.RequiredCapabilities -isnot [array] -or $row.RequiredCapabilities.Count -gt 16) {throw 'HOST_MATRIX_HTTP_INVALID'}
        foreach($capability in $row.RequiredCapabilities) {
            if($capability -isnot [string] -or $capability -cnotmatch '^[a-zA-Z][a-zA-Z0-9._-]{0,127}$') {throw 'HOST_MATRIX_HTTP_INVALID'}
        }
        if($row.Language -ceq 'C#') {
            if($null -ne $row.SoftwareId -or $null -ne $row.VariantId -or $null -ne $row.RuntimeVersion -or
                $row.CatalogStatus -cne 'NOT_EVALUATED' -or $row.CatalogReasonCode -cne 'LANGUAGE_USER_DEFERRED' -or
                $row.Availability -cne 'USER_DEFERRED' -or $row.ReasonCode -cne 'LANGUAGE_USER_DEFERRED' -or
                $row.NextStep -cne 'USER_DECISION_REQUIRED' -or $row.RequiredCapabilities.Count -ne 0 -or $row.ExplicitSelectionRequired) {throw 'HOST_MATRIX_HTTP_INVALID'}
        } else {
            $software=switch($row.Language){'Python'{'sql-python'}'R'{'sql-r'}'Java'{'sql-java'}}
            if($row.SoftwareId -cne $software -or $row.Availability -ceq 'USER_DEFERRED' -or $row.CatalogStatus -ceq 'NOT_EVALUATED' -or
                ($null -ne $row.VariantId -and ($row.VariantId -isnot [string] -or $row.VariantId -cnotmatch '^[a-z0-9][a-z0-9_-]{0,127}$')) -or
                ($null -ne $row.RuntimeVersion -and ($row.RuntimeVersion -isnot [string] -or $row.RuntimeVersion -cnotmatch '^\d{1,3}(\.\d{1,3}){0,3}$'))) {throw 'HOST_MATRIX_HTTP_INVALID'}
            if($row.CatalogStatus -ceq 'DECLARED_SUPPORTED' -and ($row.CatalogReasonCode -cne 'NONE' -or
                $null -eq $row.VariantId -or $null -eq $row.RuntimeVersion)) {throw 'HOST_MATRIX_HTTP_INVALID'}
            if(($null -eq $row.VariantId) -ne ($null -eq $row.RuntimeVersion) -or
                ($null -eq $row.VariantId -and ($row.RequiredCapabilities.Count -ne 0 -or $row.ExplicitSelectionRequired))) {throw 'HOST_MATRIX_HTTP_INVALID'}
            $observed=@($Matrix.Providers | Where-Object Provider -CEQ $row.Provider)[0]
            $expected=if($row.CatalogStatus -ceq 'DECLARED_SUPPORTED') {
                switch($observed.Readiness) {
                    'NOT_CHECKED' {@('NOT_CHECKED',$observed.ReasonCode,'CHECK_PROVIDER_READINESS')}
                    'NOT_READY' {@('PRECONDITION_MISSING',$observed.ReasonCode,'REVIEW_PROVIDER_READINESS')}
                    'READY' {@('INCOMPLETE','HOST_REQUIREMENTS_NOT_CHECKED','ASSESS_LAUNCH_REQUIREMENTS')}
                    default {@('UNKNOWN',$observed.ReasonCode,'RECHECK_PROVIDER_READINESS')}
                }
            } elseif($row.CatalogStatus -ceq 'BLOCKED') {
                if($row.CatalogReasonCode -cin @('NONE','LANGUAGE_USER_DEFERRED')) {throw 'HOST_MATRIX_HTTP_INVALID'}
                @('CATALOG_BLOCKED',$row.CatalogReasonCode,'REVIEW_CATALOG_SCOPE')
            } else {
                if($row.CatalogReasonCode -cne 'CATALOG_DECISION_UNAVAILABLE') {throw 'HOST_MATRIX_HTTP_INVALID'}
                @('UNKNOWN','CATALOG_DECISION_UNAVAILABLE','RECHECK_CATALOG')
            }
            if($row.Availability -cne $expected[0] -or $row.ReasonCode -cne $expected[1] -or $row.NextStep -cne $expected[2]) {throw 'HOST_MATRIX_HTTP_INVALID'}
        }
        # Exclude free explanation text; the browser translates finite status and
        # next-step codes. No native diagnostics or host strings cross this DTO.
        $row | Select-Object Provider,TargetOperatingSystem,Language,SoftwareId,VariantId,RuntimeVersion,CatalogStatus,
            CatalogReasonCode,Availability,ReasonCode,NextStep,RequiredCapabilities,ExplicitSelectionRequired
    })
    $result=$Matrix.PSObject.Copy();$result.Capabilities=$rows
    if([Text.Encoding]::UTF8.GetByteCount(($result | ConvertTo-Json -Depth 20 -Compress)) -gt 262144) {throw 'HOST_MATRIX_HTTP_INVALID'}
    return $result
}

function Invoke-LabHostCapabilityMatrixHttpRequest {
    param([Parameter(Mandatory)]$Request,[Parameter(Mandatory)][ValidateRange(1024,65535)][int]$ListenerPort)
    try {
        $authority="http://127.0.0.1:$ListenerPort"
        if($Request.HttpMethod -cne 'POST' -or $Request.ContentType -cnotmatch '^application/json(?:;\s*charset=utf-8)?$' -or
            $Request.LocalEndPoint.Address.ToString() -cne '127.0.0.1' -or $Request.LocalEndPoint.Port -ne $ListenerPort -or
            $Request.Url.GetLeftPart([UriPartial]::Authority) -cne $authority -or $Request.Url.AbsolutePath -cne '/api/host-capability-matrix' -or
            $Request.Url.Query -or [string]$Request.Headers['Origin'] -cne $authority) {throw 'HOST_MATRIX_HTTP_INVALID'}
        $buffer=[byte[]]::new(2049);$count=0
        while($count -lt $buffer.Length) {$read=$Request.InputStream.Read($buffer,$count,$buffer.Length-$count);if($read -eq 0){break};$count+=$read}
        if($count -gt 2048) {throw 'HOST_MATRIX_HTTP_INVALID'}
        $text=[Text.UTF8Encoding]::new($false,$true).GetString($buffer,0,$count)
        $options=[Text.Json.JsonDocumentOptions]::new();$options.MaxDepth=2
        $document=[Text.Json.JsonDocument]::Parse($text,$options)
        try {
            if($document.RootElement.ValueKind -ne [Text.Json.JsonValueKind]::Object) {throw 'HOST_MATRIX_HTTP_INVALID'}
            $keys=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            foreach($property in $document.RootElement.EnumerateObject()) {
                if(-not $keys.Add($property.Name) -or $keys.Count -gt 4 -or
                    $property.Value.ValueKind -notin @([Text.Json.JsonValueKind]::String,[Text.Json.JsonValueKind]::True,[Text.Json.JsonValueKind]::False)) {throw 'HOST_MATRIX_HTTP_INVALID'}
            }
        } finally {$document.Dispose()}
        $payload=$text | ConvertFrom-Json -Depth 2 -ErrorAction Stop
        if($payload.Action -isnot [string]) {throw 'HOST_MATRIX_HTTP_INVALID'}
        if($payload.Action -ceq 'ReadVersions') {
            Assert-LabHostMatrixHttpShape $payload @('Action')
            $versions=@($script:VersionCatalog.versions.id)
            if($versions.Count -lt 1 -or $versions.Count -gt 32 -or @($versions | Where-Object {$_ -isnot [string] -or $_ -cnotmatch '^\d{4}$'}).Count) {throw 'HOST_MATRIX_HTTP_INVALID'}
            return [pscustomobject]@{ContractVersion='SqlServerLab.HostCapabilityMatrixBrowser/1.0';Status='VERSIONS';Versions=$versions}
        }
        Assert-LabHostMatrixHttpShape $payload @('Action','SqlVersion','Provider','CheckProviderReadiness')
        if($payload.Action -cne 'ReadMatrix' -or $payload.SqlVersion -isnot [string] -or
            $payload.SqlVersion -cnotin @($script:VersionCatalog.versions.id) -or
            $payload.Provider -isnot [string] -or $payload.Provider -cnotin @('all','docker','podman','hyperv') -or $payload.CheckProviderReadiness -isnot [bool] -or
            ($payload.CheckProviderReadiness -and $payload.Provider -ceq 'all')) {throw 'HOST_MATRIX_HTTP_INVALID'}
        $providers=if($payload.Provider -ceq 'all'){@('docker','podman','hyperv')}else{@($payload.Provider)}
        $matrix=Get-SqlServerLabHostCapabilityMatrix -SqlVersion $payload.SqlVersion -Provider $providers -CheckProviderReadiness:$payload.CheckProviderReadiness
        $projection=ConvertTo-LabHostMatrixHttpProjection -Matrix $matrix -SqlVersion $payload.SqlVersion -Provider $providers -CheckProviderReadiness $payload.CheckProviderReadiness
        $view=[pscustomobject]@{ContractVersion='SqlServerLab.HostCapabilityMatrixBrowser/1.0';Status='MATRIX';Matrix=$projection}
        if([Text.Encoding]::UTF8.GetByteCount(($view | ConvertTo-Json -Depth 20 -Compress)) -gt 262144) {throw 'HOST_MATRIX_HTTP_INVALID'}
        return $view
    } catch {throw 'HOST_MATRIX_HTTP_INVALID'}
}
