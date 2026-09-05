<#
.SYNOPSIS
    Providerneutrale KI-Intent- und Szenarioverträge für SQL Server 2025.
.DESCRIPTION
    Validiert katalogisierte Szenariopakete, erzeugt portable PlanKeys und
    führt ausschließlich hashgebundene T-SQL-Schritte aus dem Modul-Root aus.
#>

function Get-LabAiSha256Text {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

function Get-LabAiArtifactSha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $text = Get-Content -LiteralPath $Path -Raw -Encoding utf8
    $canonicalText = $text.Replace("`r`n", "`n").Replace("`r", "`n")
    return Get-LabAiSha256Text -Text $canonicalText
}

function ConvertTo-LabAiCanonicalValue {
    [CmdletBinding()]
    param([AllowNull()]$InputObject)

    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [string] -or $InputObject -is [ValueType]) { return $InputObject }
    if ($InputObject -is [Collections.IDictionary]) {
        $ordered = [ordered]@{}
        foreach ($key in @($InputObject.Keys | ForEach-Object { [string]$_ } | Sort-Object)) {
            $ordered[$key] = ConvertTo-LabAiCanonicalValue -InputObject $InputObject[$key]
        }
        return $ordered
    }
    if ($InputObject -is [Collections.IEnumerable]) {
        return @($InputObject | ForEach-Object { ConvertTo-LabAiCanonicalValue -InputObject $_ })
    }

    $properties = [ordered]@{}
    foreach ($property in @($InputObject.PSObject.Properties | Sort-Object Name)) {
        $properties[$property.Name] = ConvertTo-LabAiCanonicalValue -InputObject $property.Value
    }
    return $properties
}

function Get-LabAiPlanKey {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$InputObject)

    $canonical = ConvertTo-LabAiCanonicalValue -InputObject $InputObject
    return Get-LabAiSha256Text -Text ($canonical | ConvertTo-Json -Depth 50 -Compress)
}

function Get-LabAiScenarioRoot {
    [CmdletBinding()]
    param()

    return Join-Path $script:ModuleRoot 'Scenarios/Ai'
}

function Resolve-LabAiScenarioArtifactPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ScenarioDirectory,
        [Parameter(Mandatory)][string]$RelativePath
    )

    if ([IO.Path]::IsPathRooted($RelativePath) -or $RelativePath -match '(^|[\\/])\.\.([\\/]|$)') {
        throw "AI_SCENARIO_ARTIFACT_PATH_INVALID: $RelativePath"
    }
    $root = [IO.Path]::GetFullPath($ScenarioDirectory).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $candidate = [IO.Path]::GetFullPath((Join-Path $root $RelativePath))
    if (-not $candidate.StartsWith("$root$([IO.Path]::DirectorySeparatorChar)", [StringComparison]::OrdinalIgnoreCase)) {
        throw "AI_SCENARIO_ARTIFACT_OUTSIDE_ROOT: $RelativePath"
    }
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        throw "AI_SCENARIO_ARTIFACT_MISSING: $RelativePath"
    }
    return $candidate
}

function Read-LabAiScenarioDefinition {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9-]{2,63}$')][string]$ScenarioId,
        [Parameter(Mandatory)][ValidatePattern('^[1-9][0-9]*\.[0-9]+$')][string]$Version
    )

    $scenarioRoot = Get-LabAiScenarioRoot
    $scenarioDirectory = Join-Path (Join-Path $scenarioRoot $ScenarioId) $Version
    $scenarioPath = Join-Path $scenarioDirectory 'scenario.json'
    if (-not (Test-Path -LiteralPath $scenarioPath -PathType Leaf)) {
        throw "AI_SCENARIO_NOT_FOUND: $ScenarioId/$Version"
    }

    $raw = Get-Content -LiteralPath $scenarioPath -Raw -Encoding utf8
    $schemaPath = Join-Path $script:SchemasPath 'ai-scenario.schema.json'
    $schemaErrors = @()
    $valid = Test-Json -Json $raw -SchemaFile $schemaPath -ErrorAction SilentlyContinue -ErrorVariable schemaErrors
    if (-not $valid) {
        $details = @($schemaErrors | ForEach-Object { $_.Exception.Message } | Select-Object -Unique) -join '; '
        throw "AI_SCENARIO_SCHEMA_INVALID: $ScenarioId/$Version - $details"
    }

    $scenario = $raw | ConvertFrom-Json -Depth 50
    if ([string]$scenario.id -cne $ScenarioId -or [string]$scenario.version -cne $Version) {
        throw "AI_SCENARIO_IDENTITY_MISMATCH: $ScenarioId/$Version"
    }

    $datasetPath = Resolve-LabAiScenarioArtifactPath -ScenarioDirectory $scenarioDirectory -RelativePath ([string]$scenario.dataset.artifact)
    $datasetHash = Get-LabAiArtifactSha256 -Path $datasetPath
    if ($datasetHash -cne [string]$scenario.dataset.contentDigest) {
        throw "AI_SCENARIO_DATASET_HASH_MISMATCH: $($scenario.dataset.id)"
    }

    $stepPlans = [Collections.Generic.List[object]]::new()
    $stepIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($step in @($scenario.steps)) {
        if (-not $stepIds.Add([string]$step.id)) { throw "AI_SCENARIO_STEP_DUPLICATE: $($step.id)" }
        $scriptPath = Resolve-LabAiScenarioArtifactPath -ScenarioDirectory $scenarioDirectory -RelativePath ([string]$step.script)
        $actualHash = Get-LabAiArtifactSha256 -Path $scriptPath
        if ($actualHash -cne [string]$step.sha256) {
            throw "AI_SCENARIO_STEP_HASH_MISMATCH: $($step.id)"
        }
        $stepPlans.Add([PSCustomObject]@{
            Id = [string]$step.id
            Phase = [string]$step.phase
            Database = if ($step.database) { [string]$step.database } else { 'master' }
            ScriptPath = $scriptPath
            Sha256 = $actualHash
        })
    }
    if (-not $stepIds.Contains([string]$scenario.cleanup.stepId)) {
        throw "AI_SCENARIO_CLEANUP_STEP_MISSING: $($scenario.cleanup.stepId)"
    }
    $cleanupStep = @($stepPlans | Where-Object { [string]$_.Id -ceq [string]$scenario.cleanup.stepId })
    if ($cleanupStep.Count -ne 1 -or $cleanupStep[0].Phase -ne 'cleanup') {
        throw "AI_SCENARIO_CLEANUP_STEP_INVALID: $($scenario.cleanup.stepId)"
    }

    $identity = [ordered]@{
        Contract = 'SqlServerLab.AiScenarioPlan/1.0'
        Id = [string]$scenario.id
        Version = [string]$scenario.version
        Requirements = $scenario.requirements
        ModelBindings = $scenario.modelBindings
        Dataset = $scenario.dataset
        PromptSet = $scenario.promptSet
        Tools = @($scenario.tools)
        Steps = @($stepPlans | ForEach-Object { [ordered]@{ Id=$_.Id; Phase=$_.Phase; Database=$_.Database; Sha256=$_.Sha256 } })
        Assertions = @($scenario.assertions)
        Evaluation = $scenario.evaluation
        Cleanup = $scenario.cleanup
    }

    return [PSCustomObject]@{
        Scenario = $scenario
        ScenarioDirectory = $scenarioDirectory
        DatasetSha256 = $datasetHash
        Steps = @($stepPlans)
        PlanKey = Get-LabAiPlanKey -InputObject $identity
    }
}

function Get-LabAiManifestValidationResult {
    [CmdletBinding()]
    param(
        $Ai,
        [Parameter(Mandatory)]$Manifest
    )

    $errors = [Collections.Generic.List[string]]::new()
    $warnings = [Collections.Generic.List[string]]::new()
    if ($null -eq $Ai) {
        return [PSCustomObject]@{ IsValid=$true; Errors=@(); Warnings=@() }
    }

    $models = @($Ai.models)
    foreach ($duplicate in @($models | Group-Object id | Where-Object Count -gt 1)) {
        $errors.Add("ai.models: Modell-ID '$($duplicate.Name)' ist nicht eindeutig.")
    }
    foreach ($model in $models) {
        if ([string]$model.provider -in @('precomputed','onnx') -and $model.endpointRef) {
            $errors.Add("ai.models[$($model.id)].endpointRef: Provider '$($model.provider)' verwendet keinen Endpoint.")
        }
        if ([string]$model.provider -eq 'precomputed' -and $model.credentialRef) {
            $errors.Add("ai.models[$($model.id)].credentialRef: Vorberechnete Vektoren verwenden kein Credential.")
        }
        if ([string]$Ai.policies.egress -eq 'denied' -and [string]$model.provider -in @('openai','azure-openai')) {
            $errors.Add("ai.policies.egress: Cloud-Modell '$($model.id)' benötigt 'explicit'.")
        }
    }

    $scenarioReferences = @($Ai.scenarios)
    foreach ($duplicate in @($scenarioReferences | Group-Object { "$($_.id)/$($_.version)/$($_.instanceId)" } | Where-Object Count -gt 1)) {
        $errors.Add("ai.scenarios: Szenarioreferenz '$($duplicate.Name)' ist nicht eindeutig.")
    }
    foreach ($reference in $scenarioReferences) {
        $instances = @($Manifest.instances | Where-Object { [string]$_.id -ceq [string]$reference.instanceId })
        if ($instances.Count -ne 1) {
            $errors.Add("ai.scenarios[$($reference.id)].instanceId: Instanz '$($reference.instanceId)' ist nicht eindeutig vorhanden.")
            continue
        }
        try {
            $definition = Read-LabAiScenarioDefinition -ScenarioId ([string]$reference.id) -Version ([string]$reference.version)
            $scenario = $definition.Scenario
            $provider = if ($instances[0].provider) { [string]$instances[0].provider } else { Resolve-ProviderAutoSelect -Instance $instances[0] }
            if ($provider -notin @($scenario.requirements.providers)) {
                $errors.Add("ai.scenarios[$($reference.id)]: Provider '$provider' ist für dieses Szenario nicht freigegeben.")
            }
            if (([string]$instances[0].version -split '-', 2)[0] -ne '2025') {
                $errors.Add("ai.scenarios[$($reference.id)]: Das Szenario benötigt SQL Server 2025.")
            }
            foreach ($bindingProperty in $scenario.modelBindings.PSObject.Properties) {
                $bound = @($models | Where-Object { [string]$_.id -ceq [string]$bindingProperty.Value })
                if ($bound.Count -ne 1) {
                    $errors.Add("ai.scenarios[$($reference.id)].modelBindings.$($bindingProperty.Name): Modell '$($bindingProperty.Value)' fehlt oder ist nicht eindeutig.")
                    continue
                }
                if ([string]$bound[0].purpose -cne [string]$bindingProperty.Name) {
                    $errors.Add("ai.models[$($bound[0].id)].purpose: Erwartet '$($bindingProperty.Name)'.")
                }
            }
            if ([string]$scenario.status -ne 'SUPPORTED') {
                $warnings.Add("ai.scenarios[$($reference.id)]: Status '$($scenario.status)' ist kein Runtime-Nachweis.")
            }
        }
        catch {
            $errors.Add("ai.scenarios[$($reference.id)]: $($_.Exception.Message)")
        }
    }

    return [PSCustomObject]@{
        IsValid = $errors.Count -eq 0
        Errors = @($errors | Select-Object -Unique)
        Warnings = @($warnings | Select-Object -Unique)
    }
}

function Resolve-LabAiManifestIntent {
    [CmdletBinding()]
    param($Ai)

    if ($null -eq $Ai) { return $null }
    $models = @($Ai.models | ForEach-Object {
        $model = [ordered]@{
            Id = [string]$_.id
            Purpose = [string]$_.purpose
            Provider = [string]$_.provider
            Variant = [string]$_.variant
            EndpointRef = if ($_.endpointRef) { [string]$_.endpointRef } else { $null }
            CredentialRef = if ($_.credentialRef) { [string]$_.credentialRef } else { $null }
            Dimension = if ($_.dimension) { [int]$_.dimension } else { $null }
            TimeoutSeconds = [int]$_.timeoutSeconds
            RetryCount = [int]$_.retryCount
        }
        [PSCustomObject]($model + [ordered]@{ PlanKey = Get-LabAiPlanKey -InputObject ([ordered]@{ Contract='SqlServerLab.AiModelPlan/1.0'; Model=$model }) })
    })
    $scenarios = @($Ai.scenarios | ForEach-Object {
        $definition = Read-LabAiScenarioDefinition -ScenarioId ([string]$_.id) -Version ([string]$_.version)
        [PSCustomObject]@{
            Id = [string]$_.id
            Version = [string]$_.version
            InstanceId = [string]$_.instanceId
            PlanKey = [string]$definition.PlanKey
        }
    })
    $policies = [PSCustomObject]@{
        DataClassification = [string]$Ai.policies.dataClassification
        Egress = [string]$Ai.policies.egress
        AllowedTools = @($Ai.policies.allowedTools | ForEach-Object { [string]$_ } | Sort-Object -Unique)
        ContentLogging = [string]$Ai.policies.contentLogging
        Fallback = [string]$Ai.policies.fallback
    }
    $portable = [ordered]@{ Contract='SqlServerLab.AiIntent/1.0'; Models=$models; Policies=$policies; Scenarios=$scenarios }
    return [PSCustomObject]@{
        Contract = [PSCustomObject]@{ Name='SqlServerLab.AiIntent'; Version='1.0' }
        Models = $models
        Policies = $policies
        Scenarios = $scenarios
        PlanKey = Get-LabAiPlanKey -InputObject $portable
    }
}

function Get-LabAiScenarioJournalPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunDirectory,
        [Parameter(Mandatory)][string]$ScenarioId,
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][string]$InstanceId
    )

    return Join-Path (Join-Path $RunDirectory 'ai-scenarios') "$ScenarioId-$Version-$InstanceId.json"
}

function Get-LabAiScenarioPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ScenarioId,
        [Parameter(Mandatory)][string]$Version,
        [string]$RunId,
        [string]$InstanceId = 'primary',
        [string]$StateRoot
    )

    $definition = Read-LabAiScenarioDefinition -ScenarioId $ScenarioId -Version $Version
    $blockers = [Collections.Generic.List[string]]::new()
    $provider = $null
    $sqlVersion = $null
    $lastEvidence = $null
    if ($RunId) {
        if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
        $target = Resolve-LabRunInstance -RunId $RunId -InstanceId $InstanceId -StateRoot $StateRoot
        $provider = [string]$target.Provider
        $sqlVersion = [string]$target.Version
        if ($provider -notin @($definition.Scenario.requirements.providers)) {
            $blockers.Add("AI_SCENARIO_PROVIDER_UNSUPPORTED: $provider")
        }
        if (($sqlVersion -split '-', 2)[0] -ne '2025') {
            $blockers.Add("AI_SCENARIO_SQL_VERSION_UNSUPPORTED: $sqlVersion")
        }

        $desired = Get-LabPersistedDesiredState -RunId $RunId -StateRoot $StateRoot
        if ($desired.Status -ne 'VALID' -or -not $desired.Snapshot.Ai) {
            $blockers.Add('AI_SCENARIO_INTENT_NOT_DECLARED')
        }
        else {
            $reference = @($desired.Snapshot.Ai.Scenarios | Where-Object {
                [string]$_.Id -ceq $ScenarioId -and [string]$_.Version -ceq $Version -and [string]$_.InstanceId -ceq $InstanceId
            })
            if ($reference.Count -ne 1 -or [string]$reference[0].PlanKey -cne [string]$definition.PlanKey) {
                $blockers.Add('AI_SCENARIO_INTENT_PLAN_MISMATCH')
            }
            foreach ($binding in $definition.Scenario.modelBindings.PSObject.Properties) {
                $models = @($desired.Snapshot.Ai.Models | Where-Object { [string]$_.Id -ceq [string]$binding.Value })
                if ($models.Count -ne 1 -or [string]$models[0].Purpose -cne [string]$binding.Name) {
                    $blockers.Add("AI_SCENARIO_MODEL_BINDING_INVALID: $($binding.Name)")
                }
                elseif ([string]$models[0].Provider -ne 'precomputed') {
                    $blockers.Add("AI_SCENARIO_MODEL_PROVIDER_NOT_IMPLEMENTED: $($models[0].Provider)")
                }
            }
        }

        $providerContract = @(Get-LabProviderCapabilityContract | Where-Object Provider -eq $provider | Select-Object -First 1)
        $declaredCapabilities = @($providerContract.Capabilities | ForEach-Object { [string]$_.SourceKey })
        foreach ($capability in @($definition.Scenario.requirements.requiredCapabilities)) {
            if ($declaredCapabilities -notcontains [string]$capability) {
                $blockers.Add("AI_SCENARIO_CAPABILITY_MISSING: $capability")
            }
        }

        $runDirectory = Join-Path (Join-Path $StateRoot 'runs') $RunId
        $journalPath = Get-LabAiScenarioJournalPath -RunDirectory $runDirectory -ScenarioId $ScenarioId -Version $Version -InstanceId $InstanceId
        if (Test-Path -LiteralPath $journalPath -PathType Leaf) {
            $journal = Get-Content -LiteralPath $journalPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 30
            $lastEvidence = [PSCustomObject]@{
                Status = [string]$journal.status
                PlanKey = [string]$journal.planKey
                StartedAt = [string]$journal.startedAt
                CompletedAt = [string]$journal.completedAt
                CleanupStatus = [string]$journal.cleanupStatus
                StepCount = @($journal.steps).Count
            }
        }
    }

    return [PSCustomObject]@{
        Contract = [PSCustomObject]@{ Name='SqlServerLab.AiScenarioPlan'; Version='1.0' }
        ScenarioId = $ScenarioId
        Version = $Version
        Status = if ($blockers.Count -eq 0) { if ($RunId) { 'READY' } else { 'CATALOG_SUPPORTED' } } else { 'BLOCKED' }
        PlanKey = [string]$definition.PlanKey
        RunId = $RunId
        InstanceId = $InstanceId
        Provider = $provider
        SqlVersion = $sqlVersion
        RequiredCapabilities = @($definition.Scenario.requirements.requiredCapabilities)
        ModelBindings = $definition.Scenario.modelBindings
        Dataset = [PSCustomObject]@{ Id=[string]$definition.Scenario.dataset.id; Version=[string]$definition.Scenario.dataset.version; ContentDigest=[string]$definition.DatasetSha256 }
        Assertions = @($definition.Scenario.assertions | ForEach-Object { [PSCustomObject]@{ Id=[string]$_.id; Description=[string]$_.description } })
        Evaluation = $definition.Scenario.evaluation
        CleanupMode = [string]$definition.Scenario.cleanup.mode
        Blockers = @($blockers | Select-Object -Unique)
        LastEvidence = $lastEvidence
        InternalDefinition = $definition
    }
}

function Invoke-LabAiScenario {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$InstanceId,
        [Parameter(Mandatory)][string]$ScenarioId,
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][SecureString]$SaPassword,
        [string]$StateRoot,
        [switch]$Force
    )

    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
    $plan = Get-LabAiScenarioPlan -ScenarioId $ScenarioId -Version $Version -RunId $RunId -InstanceId $InstanceId -StateRoot $StateRoot
    if ($plan.Status -ne 'READY') { throw "AI_SCENARIO_PLAN_BLOCKED: $(@($plan.Blockers) -join ', ')" }
    if (-not $Force -and $plan.LastEvidence -and $plan.LastEvidence.Status -eq 'SUCCEEDED' -and $plan.LastEvidence.PlanKey -eq $plan.PlanKey) {
        return [PSCustomObject]@{
            Contract=[PSCustomObject]@{Name='SqlServerLab.AiScenarioResult';Version='1.0'}
            Status='NO_OP';RunId=$RunId;InstanceId=$InstanceId;ScenarioId=$ScenarioId;Version=$Version
            PlanKey=$plan.PlanKey;CleanupStatus=[string]$plan.LastEvidence.CleanupStatus;Steps=@()
        }
    }

    $target = Resolve-LabRunInstance -RunId $RunId -InstanceId $InstanceId -StateRoot $StateRoot
    $runDirectory = Join-Path (Join-Path $StateRoot 'runs') $RunId
    $journalPath = Get-LabAiScenarioJournalPath -RunDirectory $runDirectory -ScenarioId $ScenarioId -Version $Version -InstanceId $InstanceId
    $definition = $plan.InternalDefinition
    $journal = [PSCustomObject]@{
        contract=[PSCustomObject]@{name='SqlServerLab.AiScenarioJournal';version='1.0'}
        runId=$RunId;instanceId=$InstanceId;scenarioId=$ScenarioId;scenarioVersion=$Version
        planKey=$plan.PlanKey;status='PENDING';startedAt=Get-LabTimestamp;completedAt=$null
        cleanupStatus='NOT_STARTED';steps=@()
    }
    Write-LabArtifactJsonAtomic -Path $journalPath -InputObject $journal

    $errorRecord = $null
    $cleanupError = $null
    try {
        foreach ($step in @($definition.Steps | Where-Object Phase -ne 'cleanup')) {
            $stepStarted = Get-LabTimestamp
            $result = Invoke-LabSqlScript -ScriptPath $step.ScriptPath -HostName $target.HostName -Port $target.Port `
                -SaPassword $SaPassword -Database $step.Database -KeepConnection
            if (-not $result.Success) { throw "AI_SCENARIO_STEP_FAILED: $($step.Id)" }
            $journal.steps += [PSCustomObject]@{id=$step.Id;phase=$step.Phase;status='SUCCEEDED';startedAt=$stepStarted;completedAt=Get-LabTimestamp}
            Write-LabArtifactJsonAtomic -Path $journalPath -InputObject $journal
        }
        $journal.status = 'SUCCEEDED'
    }
    catch {
        $errorRecord = $_
        $journal.status = 'FAILED'
        $journal.steps += [PSCustomObject]@{id='failed-step';phase='unknown';status='FAILED';startedAt=$null;completedAt=Get-LabTimestamp;reasonCode='AI_SCENARIO_STEP_FAILED'}
    }
    finally {
        if ([string]$definition.Scenario.cleanup.mode -eq 'always' -or $null -ne $errorRecord) {
            try {
                $cleanupStep = @($definition.Steps | Where-Object { [string]$_.Id -ceq [string]$definition.Scenario.cleanup.stepId })[0]
                $cleanupResult = Invoke-LabSqlScript -ScriptPath $cleanupStep.ScriptPath -HostName $target.HostName -Port $target.Port `
                    -SaPassword $SaPassword -Database $cleanupStep.Database -KeepConnection
                if (-not $cleanupResult.Success) { throw "AI_SCENARIO_CLEANUP_FAILED: $($cleanupStep.Id)" }
                $journal.cleanupStatus = 'SUCCEEDED'
                $journal.steps += [PSCustomObject]@{id=$cleanupStep.Id;phase='cleanup';status='SUCCEEDED';startedAt=$null;completedAt=Get-LabTimestamp}
            }
            catch {
                $cleanupError = $_
                $journal.cleanupStatus = 'RECOVERY_REQUIRED'
                $journal.status = 'RECOVERY_REQUIRED'
            }
        }
        else { $journal.cleanupStatus = 'NOT_REQUESTED' }
        $journal.completedAt = Get-LabTimestamp
        Write-LabArtifactJsonAtomic -Path $journalPath -InputObject $journal
    }

    if ($errorRecord -or $cleanupError) {
        $failure = if ($errorRecord) { $errorRecord.Exception.Message } else { $cleanupError.Exception.Message }
        throw "AI_SCENARIO_EXECUTION_FAILED: $failure; Cleanup=$($journal.cleanupStatus)"
    }

    return [PSCustomObject]@{
        Contract=[PSCustomObject]@{Name='SqlServerLab.AiScenarioResult';Version='1.0'}
        Status=[string]$journal.status;RunId=$RunId;InstanceId=$InstanceId;ScenarioId=$ScenarioId;Version=$Version
        PlanKey=$plan.PlanKey;CleanupStatus=[string]$journal.cleanupStatus
        Steps=@($journal.steps | ForEach-Object { [PSCustomObject]@{Id=[string]$_.id;Phase=[string]$_.phase;Status=[string]$_.status} })
    }
}
