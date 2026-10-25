function ConvertTo-LabHostMatrixProvider {
    param([string]$Provider,[string]$HostOperatingSystem,$Observation)
    $result=[pscustomobject]@{
        Provider=$Provider;Presence='UNKNOWN';Readiness='UNKNOWN';ReasonCode='PROVIDER_OBSERVATION_INVALID'
        Source='SqlServerLab.DiagnosticProviderReadiness/1.0';ObservedAtUtc=$null
    }
    if($null -eq $Observation) {
        $result.Readiness='NOT_CHECKED';$result.ReasonCode='PROVIDER_NOT_CHECKED';return $result
    }
    $result.ObservedAtUtc=[DateTime]::UtcNow.ToString('o')
    # The shared reader has already removed native output, paths and advice. Do not
    # turn failed transport, incomplete installation or unknown codes into absence.
    if($Observation.EvidenceStatus -ceq 'UNAVAILABLE') {
        if($Observation.Reason -cin @('DIAGNOSTIC_READINESS_FAILED','DIAGNOSTIC_READINESS_TIMEOUT',
            'DIAGNOSTIC_READINESS_OUTPUT_LIMIT','DIAGNOSTIC_READINESS_TERMINATION_UNCONFIRMED','DIAGNOSTIC_READINESS_RESPONSE_INVALID')) {
            $result.ReasonCode=$Observation.Reason
        }
        return $result
    }
    if($Observation.EvidenceStatus -cne 'OBSERVED' -or @($Observation.Checks).Count -ne 1) {return $result}
    $check=$Observation.Checks[0]
    $expected=if($check.Status -ceq 'PASS'){'READY'}elseif($check.Status -ceq 'BLOCKED'){'NOT_READY'}else{'INVALID'}
    if($Observation.Status -cne $expected) {return $result}
    $category=switch -CaseSensitive ($check.Code) {
        'PROVIDER_REACHABLE' {'Reachability'}
        'PROVIDER_OS_UNSUPPORTED' {'Provider'}
        {$_ -cin @('TOOL_NOT_INSTALLED','PROVIDER_NOT_INSTALLED','PROVIDER_INSTALLATION_INCOMPLETE','TOOL_RESOLUTION_FAILED','TOOL_NATIVE_PATH_REQUIRED')} {'Installation'}
        {$_ -cin @('PROVIDER_ACCESS_DENIED','TOOL_EXECUTION_DENIED')} {'Permission'}
        {$_ -cin @('PROVIDER_UNREACHABLE','PROVIDER_PROBE_TIMEOUT','PROVIDER_PROBE_FAILED','PROVIDER_RESPONSE_INVALID')} {'Reachability'}
        default {''}
    }
    if(-not $category -or $check.Category -cne $category -or
        (($check.Code -ceq 'PROVIDER_REACHABLE') -ne ($check.Status -ceq 'PASS'))) {return $result}
    if($Provider -ceq 'hyperv' -and $HostOperatingSystem -cne 'windows' -and $check.Code -cne 'PROVIDER_OS_UNSUPPORTED') {return $result}
    if($check.Code -ceq 'PROVIDER_OS_UNSUPPORTED' -and ($Provider -cne 'hyperv' -or $HostOperatingSystem -ceq 'windows')) {return $result}
    $result.ReasonCode=$check.Code
    switch -CaseSensitive ($check.Code) {
        'PROVIDER_REACHABLE' {$result.Presence='PRESENT';$result.Readiness='READY'}
        {$_ -cin @('TOOL_NOT_INSTALLED','PROVIDER_NOT_INSTALLED')} {$result.Presence='MISSING';$result.Readiness='NOT_READY'}
        'PROVIDER_OS_UNSUPPORTED' {$result.Presence='HOST_UNSUPPORTED';$result.Readiness='NOT_READY'}
        'PROVIDER_INSTALLATION_INCOMPLETE' {$result.Presence='INCOMPLETE';$result.Readiness='NOT_READY'}
        {$_ -cin @('PROVIDER_ACCESS_DENIED','TOOL_EXECUTION_DENIED','PROVIDER_UNREACHABLE','PROVIDER_PROBE_TIMEOUT','PROVIDER_PROBE_FAILED')} {
            $result.Presence='PRESENT';$result.Readiness='NOT_READY'
        }
        'PROVIDER_RESPONSE_INVALID' {$result.Presence='PRESENT'}
    }
    return $result
}

function Get-LabHostMatrixProfile {
    param([object[]]$Providers)
    if($Providers.Count -ne 3) {return 'PARTIAL_SELECTION'}
    if(@($Providers | Where-Object Readiness -CEQ 'NOT_CHECKED').Count -eq 3) {return 'NOT_CHECKED'}
    if(@($Providers | Where-Object {$_.Presence -cnotin @('PRESENT','MISSING','HOST_UNSUPPORTED')}).Count) {return 'UNKNOWN'}
    $present=@($Providers | Where-Object Presence -CEQ 'PRESENT' | ForEach-Object Provider)
    switch(($present -join '+')) {
        '' {'NO_PROVIDER'}
        'docker' {'DOCKER_ONLY'}
        'podman' {'PODMAN_ONLY'}
        'hyperv' {'HYPERV_ONLY'}
        'docker+podman' {'DOCKER_PODMAN'}
        'docker+hyperv' {'DOCKER_HYPERV'}
        'podman+hyperv' {'PODMAN_HYPERV'}
        'docker+podman+hyperv' {'ALL_PROVIDERS'}
        default {'UNKNOWN'}
    }
}

function New-LabHostCapabilityMatrix {
    param([string]$SqlVersion,[string[]]$Provider,[string]$HostOperatingSystem,[switch]$CheckProviderReadiness)
    # Reject unknown/alias SQL inputs before any provider observation. Only exact
    # loaded catalog identities may enter the public projection.
    $sql=@($script:VersionCatalog.versions | Where-Object {$_.id -ceq $SqlVersion})
    if($sql.Count -ne 1) {throw 'HOST_MATRIX_SQL_VERSION_UNKNOWN'}
    $catalog=Get-LabSoftwareCatalog
    $definitions=@($catalog.software | Where-Object {$_.id -cin @('sql-python','sql-r','sql-java')})
    if($definitions.Count -ne 3) {throw 'HOST_MATRIX_CATALOG_UNAVAILABLE'}
    $providers=[Collections.Generic.List[object]]::new();$rows=[Collections.Generic.List[object]]::new()
    foreach($name in @('docker','podman','hyperv') | Where-Object {$_ -in $Provider}) {
        $observation=$null
        if($CheckProviderReadiness) {$observation=Get-LabDiagnosticReadiness -Provider $name -Operation Inspect}
        $providerResult=ConvertTo-LabHostMatrixProvider -Provider $name -HostOperatingSystem $HostOperatingSystem -Observation $observation
        $providers.Add($providerResult)
        $target=if($name -ceq 'hyperv'){'windows'}else{'linux'}
        foreach($definition in $definitions) {
            $variants=@($definition.variants | Where-Object {
                [string]$_.operatingSystem -ceq $target -and @($_.sqlMajorVersions) -contains [int]$sql[0].major
            })
            if(-not $variants.Count) {$variants=@($null)}
            foreach($variant in $variants) {
                if($rows.Count -ge 128) {throw 'HOST_MATRIX_CATALOG_LIMIT'}
                $request=[pscustomobject]@{Id=$definition.id;Variant=$variant.id;Version=$variant.runtimeVersion}
                $plan=$null;$catalogStatus='UNKNOWN';$catalogReason='CATALOG_DECISION_UNAVAILABLE'
                try {
                    $plan=Resolve-LabExternalRuntimePlan -SoftwareItem $request -SqlVersion $SqlVersion -Provider $name -OperatingSystem $target
                    if($plan.Status -ceq 'RESOLVED') {$catalogStatus='DECLARED_SUPPORTED';$catalogReason='NONE'}
                    else {$catalogStatus='BLOCKED';$catalogReason=Get-LabExternalRuntimeCapabilityReason $plan.ReasonCode}
                } catch { }
                $availability='UNKNOWN';$reason=$catalogReason;$next='RECHECK_CATALOG'
                if($catalogStatus -ceq 'BLOCKED') {$availability='CATALOG_BLOCKED';$next='REVIEW_CATALOG_SCOPE'}
                elseif($catalogStatus -ceq 'DECLARED_SUPPORTED') {
                    $reason=$providerResult.ReasonCode
                    switch($providerResult.Readiness) {
                        'NOT_CHECKED' {$availability='NOT_CHECKED';$next='CHECK_PROVIDER_READINESS'}
                        'NOT_READY' {$availability='PRECONDITION_MISSING';$next='REVIEW_PROVIDER_READINESS'}
                        'READY' {$availability='INCOMPLETE';$reason='HOST_REQUIREMENTS_NOT_CHECKED';$next='ASSESS_LAUNCH_REQUIREMENTS'}
                        default {$next='RECHECK_PROVIDER_READINESS'}
                    }
                }
                $rows.Add([pscustomobject]@{
                    Provider=$name;TargetOperatingSystem=$target;Language=[string]$definition.name
                    SoftwareId=[string]$definition.id;VariantId=$variant.id;RuntimeVersion=$variant.runtimeVersion
                    CatalogStatus=$catalogStatus;CatalogReasonCode=$catalogReason
                    Availability=$availability;ReasonCode=$reason;NextStep=$next
                    Explanation=$(switch($availability){
                        'NOT_CHECKED' {'Die aktuelle Providerbereitschaft wurde nicht geprüft.'}
                        'PRECONDITION_MISSING' {'Die aktuelle Providerprüfung meldet eine fehlende Voraussetzung.'}
                        'INCOMPLETE' {'Der Provider ist erreichbar; die Anforderungen des konkreten SQL-Sprachstarts sind noch ungeprüft.'}
                        'CATALOG_BLOCKED' {'Für dieses SQL-/Provider-/Gastziel wurde keine nutzbare Katalogvariante aufgelöst.'}
                        default {'Die verfügbaren Daten erlauben keine verlässliche aktuelle Entscheidung.'}
                    })
                    RequiredCapabilities=@($variant.requiresCapabilities | ForEach-Object {[string]$_})
                    ExplicitSelectionRequired=($variant.explicitSelectionOnly -eq $true)
                })
                # Use the catalog's language identity, not its display/product name.
                $rows[$rows.Count-1].Language=switch($definition.id){'sql-python'{'Python'}'sql-r'{'R'}'sql-java'{'Java'}}
            }
        }
        $rows.Add([pscustomobject]@{
            Provider=$name;TargetOperatingSystem=$target;Language='C#';SoftwareId=$null;VariantId=$null;RuntimeVersion=$null
            CatalogStatus='NOT_EVALUATED';CatalogReasonCode='LANGUAGE_USER_DEFERRED';Availability='USER_DEFERRED'
            ReasonCode='LANGUAGE_USER_DEFERRED';NextStep='USER_DECISION_REQUIRED';RequiredCapabilities=@();ExplicitSelectionRequired=$false
            Explanation='C# bleibt durch Benutzerentscheidung zurückgestellt.'
        })
    }
    # Bind to the authority actually loaded in this module, never hash newer disk
    # content and imply that it was used to calculate this result.
    $binding=[ordered]@{Sql=$script:VersionCatalog;Software=$catalog;Providers=@(
        foreach($name in @('docker','podman','hyperv')) {$script:RegisteredProviders[$name].Definition}
    )} | ConvertTo-Json -Depth 60 -Compress
    $fingerprint=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($binding))).ToLowerInvariant()
    $matrix=[pscustomobject]@{
        Contract=[pscustomobject]@{Name='SqlServerLab.HostCapabilityMatrix';Version='1.0';EvidenceBoundary='CATALOG_AND_OPTIONAL_PROVIDER_BOOTSTRAP_ONLY'}
        Feature='SqlExternalRuntime';SqlVersion=[string]$sql[0].id;HostOperatingSystem=$HostOperatingSystem
        GeneratedAtUtc=[DateTime]::UtcNow.ToString('o');CatalogFingerprint=$fingerprint
        ProviderProfile=Get-LabHostMatrixProfile -Providers @($providers)
        Providers=@($providers);Capabilities=@($rows)
        Unassessed=@('SQL_BUILD','GUEST_OPERATING_SYSTEM','KERNEL_AND_CGROUP_CONTROLLERS','WSL_SHARED_KERNEL',
            'ROOTLESS_AND_LAUNCH_MODE','RESOURCES','TARGET_AUTHORIZATION','HISTORICAL_EVIDENCE','SQL_LANGUAGE_EXECUTION')
        ManufacturerSupport='NOT_ASSESSED';ProjectAcceptance='NOT_ASSESSED'
        ExecutionSupported=$false;MutationAllowed=$false;Actions=@()
    }
    if([Text.Encoding]::UTF8.GetByteCount(($matrix | ConvertTo-Json -Depth 30 -Compress)) -gt 262144) {throw 'HOST_MATRIX_OUTPUT_LIMIT'}
    return $matrix
}
