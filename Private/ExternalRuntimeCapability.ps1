# Prospective catalog decisions are separate from optional current host facts.
function Get-LabExternalRuntimeCapabilityReason {
    param([string]$Code)
    $known=@('SOFTWARE_NOT_CATALOGUED','SQL_VERSION_UNKNOWN','RUNTIME_COMBINATION_NOT_CATALOGUED',
        'SOFTWARE_PLAN_AMBIGUOUS','LEGACY_POST_START_MUTATION','IMAGE_BINDING_NOT_IMPLEMENTED',
        'PACKAGE_NOT_LOCKED','VARIANT_PREVIEW','VARIANT_UNSUPPORTED','PROVIDER_CAPABILITY_MISSING',
        'ARTIFACT_INTEGRITY_INCOMPLETE','PACKAGE_LOCK_INTEGRITY_INCOMPLETE')
    if ($Code -cin $known) { return $Code }
    return 'CATALOG_DECISION_UNAVAILABLE'
}

function Get-LabExternalRuntimeInfoArguments {
    param([string]$Provider)
    $format=if($Provider -ceq 'docker') {
        '{"OperatingSystem":{{json .OSType}},"CgroupVersion":{{json .CgroupVersion}},"SecurityOptions":{{json .SecurityOptions}}}'
    } elseif($Provider -ceq 'podman') {
        '{"OperatingSystem":{{json .Host.OS}},"CgroupVersion":{{json .Host.CgroupVersion}},"Rootless":{{json .Host.Security.Rootless}}}'
    } else { throw 'EXTERNAL_RUNTIME_CAPABILITY_INPUT_INVALID' }
    return @('info','--format',$format)
}

function Invoke-LabExternalRuntimeInfoProcess {
    param([string]$Invocation,[string[]]$ArgumentList)
    $start=[Diagnostics.ProcessStartInfo]::new($Invocation)
    $start.UseShellExecute=$false;$start.CreateNoWindow=$true
    $start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    foreach($argument in $ArgumentList) { $start.ArgumentList.Add($argument) }
    # Existing byte-bounded RAM-only transport. It never writes provider output.
    Invoke-LabDiagnosticBoundedProcess -StartInfo $start -TimeoutSeconds 20 -MaximumBytes 65536
}

function Read-LabExternalRuntimeHostFacts {
    param([string]$Provider)
    $result=[pscustomobject]@{Status='UNAVAILABLE';ReasonCode='PROVIDER_PROBE_FAILED';Facts=$null}
    try {
        $resolution=@(Initialize-LabHostToolPath -Name $Provider)
        if($resolution.Count -ne 1 -or $resolution[0].Available -ne $true) { $result.ReasonCode='TOOL_NOT_INSTALLED';return $result }
        $invocation=$resolution[0].Invocation
        if($invocation -isnot [string] -or -not [IO.Path]::IsPathFullyQualified($invocation)) {
            $result.ReasonCode='TOOL_NATIVE_PATH_REQUIRED';return $result
        }
        $response=Invoke-LabExternalRuntimeInfoProcess -Invocation $invocation -ArgumentList (Get-LabExternalRuntimeInfoArguments -Provider $Provider)
        if(-not $response.Success) {
            $result.ReasonCode=switch -CaseSensitive ($response.Reason) {
                'DIAGNOSTIC_READINESS_TIMEOUT' {'PROVIDER_PROBE_TIMEOUT'}
                'DIAGNOSTIC_READINESS_OUTPUT_LIMIT' {'PROVIDER_OUTPUT_LIMIT'}
                'DIAGNOSTIC_READINESS_TERMINATION_UNCONFIRMED' {'PROVIDER_TERMINATION_UNCONFIRMED'}
                'DIAGNOSTIC_READINESS_RESPONSE_INVALID' {'PROVIDER_RESPONSE_INVALID'}
                default {'PROVIDER_PROBE_FAILED'}
            }
            return $result
        }
        $result.Facts=ConvertTo-LabExternalRuntimeHostFacts -Provider $Provider -Value $response.Value
        $result.Status='OBSERVED';$result.ReasonCode='NONE'
    } catch { $result.Status='UNAVAILABLE';$result.ReasonCode='PROVIDER_RESPONSE_INVALID';$result.Facts=$null }
    return $result
}

function New-LabExternalRuntimeCapabilityDecision {
    param([string]$SqlVersion,[string]$Provider,[string]$OperatingSystem,
        [string]$SoftwareId,[string]$RuntimeVersion,[string]$VariantId,$HostObservation,[switch]$IncludeRecordedEvidence)
    if($Provider -cnotin @('docker','podman') -or $OperatingSystem -cne 'linux' -or
        $SoftwareId -cnotin @('sql-python','sql-r','sql-java') -or
        [string]::IsNullOrWhiteSpace($SqlVersion) -or [string]::IsNullOrWhiteSpace($RuntimeVersion) -or [string]::IsNullOrWhiteSpace($VariantId) -or
        $SqlVersion.Length -gt 32 -or $RuntimeVersion.Length -gt 64 -or $VariantId.Length -gt 128) {
        throw 'EXTERNAL_RUNTIME_CAPABILITY_INPUT_INVALID'
    }
    $catalog='BLOCKED';$reason='CATALOG_DECISION_UNAVAILABLE';$plan=$null;$recipe=$null
    try {
        $request=[pscustomobject]@{Id=$SoftwareId;Version=$RuntimeVersion;Variant=$VariantId;InstallMethod='catalog';Packages=@();RequestSource='capability-decision'}
        $plan=Resolve-LabExternalRuntimePlan -SoftwareItem $request -SqlVersion $SqlVersion -Provider $Provider -OperatingSystem $OperatingSystem
        if($plan.Status -ceq 'RESOLVED') { $catalog='DECLARED_SUPPORTED';$reason='NONE' }
        else { $reason=Get-LabExternalRuntimeCapabilityReason -Code $plan.ReasonCode }
    } catch {
        $reason=if($_.Exception.Message.StartsWith('SOFTWARE_PLAN_AMBIGUOUS:',[StringComparison]::Ordinal)){'SOFTWARE_PLAN_AMBIGUOUS'}else{'CATALOG_DECISION_UNAVAILABLE'}
    }
    $readiness='NOT_CHECKED';$hostReason='READINESS_NOT_REQUESTED';$required=$null;$launchMode=$null
    if($catalog -ceq 'DECLARED_SUPPORTED') {
        try {
            $recipe=Get-LabExternalRuntimeContainerRecipe -SqlVersion $SqlVersion -LaunchMode ([string]$plan.LaunchMode)
            $launchMode=[string]$recipe.launchContract.mode
            $required=[string]$recipe.launchContract.requiredCgroupVersion
            if($launchMode -cnotin @('sql2019-namespace-v1','sql2022-namespace-v1','sql2025-namespace-v1','sql2025-shared-user-v2') -or
                $required -cnotin @('1','2')) { throw 'INVALID_RECIPE' }
        } catch {
            $catalog='BLOCKED';$reason='CATALOG_DECISION_UNAVAILABLE';$required=$null
        }
    }
    if($null -ne $HostObservation) {
        $readiness='BLOCKED';$hostReason='CATALOG_BLOCKED'
        if($catalog -ceq 'DECLARED_SUPPORTED') {
            $hostReason='PROVIDER_RESPONSE_INVALID'
            $observedCodes=@('TOOL_NOT_INSTALLED','TOOL_NATIVE_PATH_REQUIRED','PROVIDER_PROBE_FAILED','PROVIDER_PROBE_TIMEOUT',
                'PROVIDER_OUTPUT_LIMIT','PROVIDER_TERMINATION_UNCONFIRMED','PROVIDER_RESPONSE_INVALID')
            if($HostObservation.Status -ceq 'UNAVAILABLE' -and $HostObservation.ReasonCode -cin $observedCodes) {
                $hostReason=$HostObservation.ReasonCode
            } elseif($HostObservation.Status -ceq 'OBSERVED') {
                $facts=$HostObservation.Facts
                if($facts.OperatingSystem -is [string] -and $facts.OperatingSystem -cin @('linux','windows') -and
                    $facts.CgroupVersion -is [string] -and $facts.CgroupVersion -cin @('1','2') -and $facts.Rootless -is [bool]) {
                    $runtimeInfo=if($Provider -ceq 'docker') {
                        [pscustomobject]@{OSType=$facts.OperatingSystem;CgroupVersion=$facts.CgroupVersion;SecurityOptions=@($(if($facts.Rootless){'name=rootless'}))}
                    } else {
                        [pscustomobject]@{host=[pscustomobject]@{os=$facts.OperatingSystem;cgroupVersion=$facts.CgroupVersion;security=[pscustomobject]@{rootless=$facts.Rootless}}}
                    }
                    $capability=Get-LabExternalRuntimeHostCapability -Provider $Provider -SqlVersion $SqlVersion -RequiredCgroupVersion $required `
                        -RuntimeInfo $runtimeInfo -ToolAvailable $true -RuntimeReachable $true
                    if($capability.Status -ceq 'READY' -and $capability.ReasonCode -ceq 'NONE') { $readiness='READY';$hostReason='NONE' }
                    elseif($capability.ReasonCode -cin @('CGROUP_V2_REQUIRES_SQL2025','LINUX_RUNTIME_REQUIRED','CGROUP_VERSION_UNSUPPORTED','ROOTFUL_STATUS_UNKNOWN','ROOTFUL_PROVIDER_REQUIRED')) {
                        $hostReason=$capability.ReasonCode
                    }
                }
            }
        }
    }
    # Identity values are echoed only after exact resolution to current catalog entries.
    $identity=if($catalog -ceq 'DECLARED_SUPPORTED') {
        [pscustomobject]@{SoftwareId=$plan.SoftwareId;VariantId=$plan.VariantId;RuntimeVersion=$plan.RuntimeVersion;Language=$plan.Language;SqlVersion=$plan.SqlVersion}
    }else{$null}
    $decision=[pscustomobject]@{
        Contract=[pscustomobject]@{Name='SqlServerLab.ExternalRuntimeCapability';Version='1.0';EvidenceBoundary='PROSPECTIVE_DECLARATION_AND_OPTIONAL_HOST_OBSERVATION'}
        Provider=$Provider;OperatingSystem=$OperatingSystem;Identity=$identity
        CatalogDecision=[pscustomobject]@{Status=$catalog;ReasonCode=$reason}
        CurrentReadiness=[pscustomobject]@{Status=$readiness;ReasonCode=$hostReason;RequiredCgroupVersion=$required;LaunchMode=$launchMode}
        HistoricalEvidence=[pscustomobject]@{Status='NOT_RECORDED';MappingStatus='NOT_DEFINED'}
        SqlLanguageExecution='NOT_CHECKED';TargetAuthorization='NOT_CHECKED';ExecutionSupported=$false;MutationAllowed=$false;Actions=@()
    }
    if($IncludeRecordedEvidence) {
        $decision.Contract.Version='1.1'
        $evidencePlan=if($catalog -ceq 'DECLARED_SUPPORTED'){$plan}else{$null}
        $decision.HistoricalEvidence=Get-LabExternalRuntimeRecordedEvidence -Plan $evidencePlan -Recipe $recipe -RepositoryRoot $script:ModuleRoot
        if([Text.Encoding]::UTF8.GetByteCount(($decision|ConvertTo-Json -Depth 30 -Compress)) -gt 262144) {
            $decision.HistoricalEvidence=New-LabExternalRuntimeHistoricalEvidenceResult 'UNAVAILABLE' 'UNAVAILABLE' 'EVIDENCE_OUTPUT_LIMIT'
        }
    }
    return $decision
}

function Get-LabExternalRuntimeCapabilityOptions {
    param([string]$SqlVersion,[string]$Provider,[string]$OperatingSystem,$HostObservation)
    $options=[Collections.Generic.List[object]]::new()
    foreach($definition in @((Get-LabSoftwareCatalog).software|Where-Object{ $_.id -cin @('sql-python','sql-r','sql-java')})) {
        foreach($variant in @($definition.variants)) {
            if($options.Count -ge 128) { throw 'EXTERNAL_RUNTIME_CAPABILITY_CATALOG_LIMIT' }
            $decision=New-LabExternalRuntimeCapabilityDecision -SqlVersion $SqlVersion -Provider $Provider -OperatingSystem $OperatingSystem `
                -SoftwareId $definition.id -RuntimeVersion $variant.runtimeVersion -VariantId $variant.id -HostObservation $HostObservation
            $options.Add([pscustomobject]@{SoftwareId=$definition.id;Language=$variant.language;VariantId=$variant.id;RuntimeVersion=$variant.runtimeVersion;Decision=$decision})
        }
    }
    return @($options|Sort-Object @{Expression={$_.Decision.CatalogDecision.Status -cne 'DECLARED_SUPPORTED'}},Language,RuntimeVersion,VariantId)
}
