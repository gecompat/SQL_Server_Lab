#Requires -Version 7.2
[CmdletBinding()]
param()

$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$results=[Collections.Generic.List[object]]::new()
function Add-CheckResult {
    param([string]$Name,[bool]$Success)
    $results.Add([PSCustomObject]@{Name=$Name;Success=$Success})
    Write-Host "$(if($Success){'PASS'}else{'FAIL'}): $Name" -ForegroundColor $(if($Success){'Green'}else{'Red'})
}

$scenarioPath=Join-Path $repoRoot 'Scenarios/Ai/vector-core-ci/1.0/scenario.json'
$scenarioSchema=Join-Path $repoRoot 'Schemas/ai-scenario.schema.json'
$manifestPath=Join-Path $repoRoot 'Schemas/example-ai-vector-core.json'
$manifestSchema=Join-Path $repoRoot 'Schemas/lab-manifest.schema.json'

Add-CheckResult 'KI-Szenario erfüllt den versionierten Packagevertrag' (
    (Get-Content $scenarioPath -Raw -Encoding utf8) | Test-Json -SchemaFile $scenarioSchema -ErrorAction SilentlyContinue)
Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
$module=Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru
$temporaryRoot=Join-Path ([IO.Path]::GetTempPath()) "sql-lab-ai-static-$([guid]::NewGuid().ToString('N'))"
try {
    $result=& $module {
        param($ManifestPath,$TemporaryRoot)
        $manifestJson=Get-Content -LiteralPath $ManifestPath -Raw -Encoding utf8
        $manifestSchemaResult=Test-LabManifestSchema -Json $manifestJson
        $resolved=Read-LabManifest -Path $ManifestPath
        $desired=New-LabDesiredStateSnapshot -ResolvedLab $resolved -ProvisioningMode manifest -PersistentData $false
        $runId='11111111-2222-4333-8444-555555555555'
        $runDirectory=Join-Path (Join-Path $TemporaryRoot 'runs') $runId
        New-Item -Path $runDirectory -ItemType Directory -Force | Out-Null
        Write-LabArtifactJsonAtomic -Path (Join-Path $runDirectory 'run-state.json') -InputObject ([PSCustomObject]@{
            runId=$runId;scopeId='aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee';state='READY';instances=@();providerSubRuns=@()
            metadata=[PSCustomObject]@{desiredState=$desired};errors=@()
        })
        Write-LabArtifactJsonAtomic -Path (Join-Path $runDirectory 'connection-info.json') -InputObject ([PSCustomObject]@{
            instances=@(
                [PSCustomObject]@{id='primary';provider='docker';containerName='synthetic-ai-target';host='127.0.0.1';port=14330;version='2025'},
                [PSCustomObject]@{id='hyperv-ai';provider='hyperv';vmName='synthetic-ai-vm';host='192.0.2.10';port=1433;sqlVersion='2025'}
            )
        })

        $catalogPlan=Get-SqlServerLabAiScenario -ScenarioId vector-core-ci
        $runPlan=Get-SqlServerLabAiScenario -ScenarioId vector-core-ci -RunId $runId -StateRoot $TemporaryRoot
        $password=[SecureString]::new()
        $whatIf=Invoke-SqlServerLabAiScenario -ScenarioId vector-core-ci -RunId $runId -StateRoot $TemporaryRoot -SaPassword $password -WhatIf
        $journalPath=Get-LabAiScenarioJournalPath -RunDirectory $runDirectory -ScenarioId vector-core-ci -Version 1.0 -InstanceId primary

        $manifest=Get-Content -LiteralPath $ManifestPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 50
        $manifest.ai.models[0].provider='openai'
        $manifest.ai.models[0] | Add-Member NoteProperty endpointRef cloud-endpoint
        $manifest.ai.models[0] | Add-Member NoteProperty credentialRef SQL_SERVER_LAB_SECRET_AI_API_KEY
        $egressValidation=Get-LabAiManifestValidationResult -Ai $manifest.ai -Manifest $manifest

        $pathRejected=$false
        try{$null=Resolve-LabAiScenarioArtifactPath -ScenarioDirectory (Get-LabAiScenarioRoot) -RelativePath '../outside.sql'}
        catch{$pathRejected=$_.Exception.Message -match 'AI_SCENARIO_ARTIFACT_PATH_INVALID'}

        $providerCapabilities=@(Get-LabProviderCapabilityContract)
        $hyperVTarget=Resolve-LabRunInstance -RunId $runId -InstanceId hyperv-ai -StateRoot $TemporaryRoot
        [PSCustomObject]@{
            ManifestSchemaResult=$manifestSchemaResult;Resolved=$resolved;Desired=$desired;CatalogPlan=$catalogPlan;RunPlan=$runPlan;WhatIf=$whatIf
            JournalAbsent=-not (Test-Path -LiteralPath $journalPath)
            EgressRejected=(-not $egressValidation.IsValid -and @($egressValidation.Errors) -match "Cloud-Modell.*benötigt 'explicit'")
            PathRejected=$pathRejected
            DockerCapability='sql2025-vector-core' -in @($providerCapabilities|Where-Object Provider -eq docker|ForEach-Object Capabilities|ForEach-Object SourceKey)
            PodmanCapability='sql2025-vector-core' -in @($providerCapabilities|Where-Object Provider -eq podman|ForEach-Object Capabilities|ForEach-Object SourceKey)
            HyperVTarget=$hyperVTarget
        }
    } $manifestPath $temporaryRoot

    Add-CheckResult 'KI-Beispiel erfüllt den lokalen erweiterten Manifestvertrag ohne Netzwerkauflösung' $result.ManifestSchemaResult.IsValid
    Add-CheckResult 'Manifestauflösung persistiert nur portablen KI-Intent und stabile PlanKeys' (
        $result.Resolved.ai.Contract.Name -eq 'SqlServerLab.AiIntent' -and
        $result.Resolved.ai.PlanKey -match '^[a-f0-9]{64}$' -and
        @($result.Resolved.ai.Models|Where-Object PlanKey -notmatch '^[a-f0-9]{64}$').Count -eq 0 -and
        @($result.Resolved.ai.Scenarios|Where-Object PlanKey -notmatch '^[a-f0-9]{64}$').Count -eq 0)
    Add-CheckResult 'Desired State übernimmt den KI-Intent ohne Secretwert, Hostpfad oder Endpoint-URL' (
        $result.Desired.Ai.PlanKey -eq $result.Resolved.ai.PlanKey -and
        (($result.Desired.Ai|ConvertTo-Json -Depth 30) -notmatch 'Synthetic-Ai-Only|127\.0\.0\.1|D:\\|https?://'))
    Add-CheckResult 'Katalogprojektion enthält keine internen Szenario- oder Artifactpfade' (
        $result.CatalogPlan.Status -eq 'CATALOG_SUPPORTED' -and
        $result.CatalogPlan.PlanKey -match '^[a-f0-9]{64}$' -and
        (($result.CatalogPlan|ConvertTo-Json -Depth 30) -notmatch 'InternalDefinition|ScriptPath|ScenarioDirectory'))
    Add-CheckResult 'Run-Plan bindet Manifestintent, SQL 2025 und Docker-Capability zu READY' (
        $result.RunPlan.Status -eq 'READY' -and $result.RunPlan.Provider -eq 'docker' -and $result.RunPlan.SqlVersion -eq '2025')
    Add-CheckResult 'WhatIf bleibt mutationsfrei und erzeugt kein Journal' (
        $result.WhatIf.Status -eq 'PLAN_ONLY' -and $result.JournalAbsent)
    Add-CheckResult 'Cloudmodell mit verweigertem Egress wird fachlich abgelehnt' $result.EgressRejected
    Add-CheckResult 'Szenario-Artefakte außerhalb des Package-Roots werden abgelehnt' $result.PathRejected
    Add-CheckResult 'Docker und Podman deklarieren Vector-Core getrennt' ($result.DockerCapability -and $result.PodmanCapability)
    Add-CheckResult 'Hyper-V-Connection-Info löst sqlVersion als KI-Zielversion auf' (
        $result.HyperVTarget.Provider -eq 'hyperv' -and $result.HyperVTarget.Version -eq '2025' -and $result.HyperVTarget.VMName -eq 'synthetic-ai-vm')

    $scenario=Get-Content $scenarioPath -Raw -Encoding utf8|ConvertFrom-Json -Depth 50
    $scenarioDirectory=Split-Path $scenarioPath -Parent
    $allHashesMatch=$true
    foreach($step in @($scenario.steps)){
        $actual=& $module { param($Path) Get-LabAiArtifactSha256 -Path $Path } (Join-Path $scenarioDirectory $step.script)
        if($actual -cne [string]$step.sha256){$allHashesMatch=$false}
    }
    $datasetHash=& $module { param($Path) Get-LabAiArtifactSha256 -Path $Path } (Join-Path $scenarioDirectory $scenario.dataset.artifact)
    Add-CheckResult 'Dataset und alle T-SQL-Schritte stimmen mit den gebundenen SHA-256-Werten überein' (
        $allHashesMatch -and $datasetHash -ceq [string]$scenario.dataset.contentDigest)

    $contractFiles=@(
        @{Data='Catalogs/ai-models.json';Schema='Schemas/ai-model-catalog.schema.json'},
        @{Data='Scenarios/Ai/rag-local-vector/1.0/golden-dataset.json';Schema='Schemas/ai-retrieval-golden-dataset.schema.json'},
        @{Data=$null;Schema='Schemas/ai-endpoint-plan.schema.json'},
        @{Data=$null;Schema='Schemas/ai-runtime-journal.schema.json'},
        @{Data=$null;Schema='Schemas/ai-query-result.schema.json'}
    )
    $contractsValid=$true
    foreach($contractFile in $contractFiles){
        $schemaFile=Join-Path $repoRoot $contractFile.Schema
        try{$null=Get-Content -LiteralPath $schemaFile -Raw -Encoding utf8|ConvertFrom-Json -Depth 100}
        catch{$contractsValid=$false;continue}
        if($contractFile.Data){
            $dataFile=Join-Path $repoRoot $contractFile.Data
            if(-not ((Get-Content -LiteralPath $dataFile -Raw -Encoding utf8)|Test-Json -SchemaFile $schemaFile -ErrorAction SilentlyContinue)){$contractsValid=$false}
        }
    }
    Add-CheckResult 'KI-Modell-, Endpoint-, Journal- und Ergebnisverträge sind lokal parse- und schema-valide' $contractsValid

    $stubPlan=& $module { New-LabAiEndpointPlan -ModelKey ollama-embeddinggemma-300m-q4 -EndpointRef deterministic-stub -Lane stub -RetryCount 1 }
    $vector=@(1..768 | ForEach-Object { [double]$_ / 768 })
    $retryResult=& $module {
        param($Plan,$Vector)
        $transport={
            param($Request)
            if ($Request.Attempt -eq 1) { return [PSCustomObject]@{StatusCode=429;Body=$null} }
            return [PSCustomObject]@{StatusCode=200;Body=[PSCustomObject]@{embeddings=[object[]]@(,[double[]]$Vector)}}
        }.GetNewClosure()
        Invoke-LabAiEndpointRequest -Plan $Plan -InputText 'synthetisch' -Transport $transport
    } $stubPlan $vector
    Add-CheckResult 'Deterministischer Ollama-Stub verwendet /api/embed und begrenzten Retry ohne Fallback' (
        $retryResult.Status -eq 'SUCCEEDED' -and $retryResult.Attempts -eq 2 -and $retryResult.Vector.Count -eq 768)

    $dimensionRejected=$false
    try {
        & $module {
            param($Plan)
            Invoke-LabAiEndpointRequest -Plan $Plan -InputText 'synthetisch' -Transport {
                [PSCustomObject]@{StatusCode=200;Body=[PSCustomObject]@{embeddings=[object[]]@(,[double[]]@(0.1,0.2,0.3))}}
            }
        } $stubPlan
    } catch { $dimensionRejected=$_.Exception.Message -eq 'AI_ENDPOINT_DIMENSION_MISMATCH' }
    Add-CheckResult 'Dimensionskonflikt wird vor Nutzung der Vektoren fail-closed abgelehnt' $dimensionRejected

    $timeoutRejected=$false
    try {
        & $module {
            param($Plan)
            Invoke-LabAiEndpointRequest -Plan $Plan -InputText 'synthetisch' -Transport {
                throw [System.Threading.Tasks.TaskCanceledException]::new('payload darf nicht erscheinen')
            }
        } $stubPlan
    } catch { $timeoutRejected=$_.Exception.Message -eq 'AI_ENDPOINT_TIMEOUT' }
    Add-CheckResult 'Timeout wird begrenzt wiederholt und ohne Payloadtext ausgegeben' $timeoutRejected

    foreach($case in @(
        @{Name='Rate Limit nach Retry';Status=429;Reason='AI_ENDPOINT_HTTP_429'},
        @{Name='Ungültige Antwort';Status=200;Reason='AI_ENDPOINT_EMBEDDING_RESPONSE_INVALID'}
    )) {
        $rejected=$false
        try {
            & $module {
                param($Plan,$Case)
                Invoke-LabAiEndpointRequest -Plan $Plan -InputText 'synthetisch' -Transport {
                    if ($Case.Status -eq 200) { return [PSCustomObject]@{StatusCode=200;Body=[PSCustomObject]@{embeddings=@()}} }
                    return [PSCustomObject]@{StatusCode=$Case.Status;Body=[PSCustomObject]@{secret='nicht-ausgeben'}}
                }
            } $stubPlan $case
        } catch { $rejected=$_.Exception.Message -eq $case.Reason }
        Add-CheckResult "Stubfehler bleibt sanitisiert und fail-closed: $($case.Name)" $rejected
    }

    $cloudBlocked=& $module { New-LabAiEndpointPlan -ModelKey ollama-gpt-oss-120b-cloud -EndpointRef ollama-cloud }
    $cloudReady=& $module { New-LabAiEndpointPlan -ModelKey ollama-gpt-oss-120b-cloud -EndpointRef ollama-cloud -AllowCloudEgress }
    Add-CheckResult 'Cloudplan verlangt expliziten Egress und projiziert nur CredentialRef und Zielhost' (
        $cloudBlocked.Status -eq 'BLOCKED' -and $cloudBlocked.Blockers -contains 'AI_ENDPOINT_CLOUD_EGRESS_NOT_ALLOWED' -and
        $cloudReady.Status -eq 'NOT_PROBED' -and $cloudReady.CredentialRef -eq 'SQL_SERVER_LAB_SECRET_OLLAMA' -and
        $cloudReady.TargetHost -eq 'ollama.com' -and ($cloudReady | ConvertTo-Json -Depth 10) -notmatch 'Bearer|api_key')

    $missingSecretPath=Join-Path $temporaryRoot 'does-not-exist.env'
    $publicCloudPlan=& $module {
        param($MissingSecretPath)
        Invoke-SqlServerLabAiModel -ModelKey ollama-gpt-oss-120b-cloud -InputText 'synthetisch' `
            -DataClassification synthetic-only -AllowCloudEgress -SecretFilePath $MissingSecretPath -WhatIf
    } $missingSecretPath
    $endpointSchema=Join-Path $repoRoot 'Schemas/ai-endpoint-plan.schema.json'
    Add-CheckResult 'Cloud-WhatIf liest kein Secret und erfüllt den geheimnisfreien Endpointvertrag' (
        (($publicCloudPlan | ConvertTo-Json -Depth 20) | Test-Json -SchemaFile $endpointSchema -ErrorAction SilentlyContinue) -and
        $publicCloudPlan.Status -eq 'NOT_PROBED')

    $secretFixture=Join-Path $temporaryRoot 'synthetic.env'
    [IO.File]::WriteAllLines($secretFixture,@(('OLLA'+'MA=')+'synthetic-value'),[Text.Encoding]::UTF8)
    $secretRead=& $module {
        param($SecretFixture)
        $resolved=Get-LabAiDotEnvSecret -Path $SecretFixture
        $plain=ConvertFrom-LabSecureString -SecureString $resolved.Secret
        try { [PSCustomObject]@{Matches=$plain -eq 'synthetic-value';Warnings=@($resolved.Warnings)} }
        finally { $plain=$null }
    } $secretFixture
    Add-CheckResult 'Dotenv-Resolver liest ausschließlich den festen OLLAMA-Schlüssel als SecureString' $secretRead.Matches

    $duplicateLines=@((('OLLA'+'MA=')+'first'),(('OLLA'+'MA=')+'second'))
    [IO.File]::WriteAllLines($secretFixture,$duplicateLines,[Text.Encoding]::UTF8)
    $duplicateSecretRejected=$false
    try { & $module { param($SecretFixture) Get-LabAiDotEnvSecret -Path $SecretFixture } $secretFixture }
    catch { $duplicateSecretRejected=$_.Exception.Message -eq 'AI_SECRET_OLLAMA_MISSING_OR_DUPLICATE' }
    Add-CheckResult 'Fehlender oder doppelter OLLAMA-Schlüssel wird fail-closed abgelehnt' $duplicateSecretRejected

    $publicLocalPlan=& $module {
        Invoke-SqlServerLabAiModel -ModelKey ollama-embeddinggemma-300m-q4 -Lane local -LocalPort 23456 `
            -InputText 'synthetisch' -DataClassification synthetic-only -WhatIf
    }
    Add-CheckResult 'Lokaler WhatIf-Plan bindet dynamischen Loopback-Port ohne Credential oder Egress' (
        (($publicLocalPlan | ConvertTo-Json -Depth 20) | Test-Json -SchemaFile $endpointSchema -ErrorAction SilentlyContinue) -and
        $publicLocalPlan.Port -eq 23456 -and $null -eq $publicLocalPlan.CredentialRef -and $publicLocalPlan.Egress -eq 'denied')

    $laneMismatch=& $module {
        New-LabAiEndpointPlan -ModelKey ollama-gpt-oss-120b-cloud -EndpointRef ollama-local -Lane local
    }
    Add-CheckResult 'Cloudmodell kann nicht still auf die lokale Lane wechseln' (
        $laneMismatch.Status -eq 'BLOCKED' -and $laneMismatch.Blockers -contains 'AI_ENDPOINT_MODEL_LANE_MISMATCH')

    $capabilities=& $module { Get-LabProviderCapabilityContract }
    $dockerAi=@(($capabilities | Where-Object Provider -eq docker).Capabilities.SourceKey)
    $podmanAi=@(($capabilities | Where-Object Provider -eq podman).Capabilities.SourceKey)
    $hyperVAi=@(($capabilities | Where-Object Provider -eq hyperv).Capabilities.SourceKey)
    Add-CheckResult 'Docker und Podman deklarieren lokale Ollama-Evidence getrennt von Hyper-V' (
        $dockerAi -contains 'ollama-local' -and $podmanAi -contains 'ollama-local' -and $hyperVAi -notcontains 'ollama-local')
    Add-CheckResult 'Docker und Podman deklarieren native lokale SQL-RAG-Evidence getrennt von Hyper-V' (
        $dockerAi -contains 'sql2025-rag-local' -and $podmanAi -contains 'sql2025-rag-local' -and $hyperVAi -notcontains 'sql2025-rag-local')

    $perfect=Measure-SqlServerLabAiRetrieval -ExpectedDocumentId doc-1,doc-2 -RankedDocumentId doc-1,doc-2,doc-3 -K 2
    $degraded=Measure-SqlServerLabAiRetrieval -ExpectedDocumentId doc-1,doc-2 -RankedDocumentId doc-3,doc-1,doc-4 -K 3 `
        -MinimumRecall 1 -MinimumMrr 0.75 -MinimumNdcg 0.9
    $evaluationSchema=Join-Path $repoRoot 'Schemas/ai-retrieval-evaluation.schema.json'
    Add-CheckResult 'Perfektes Retrieval erfüllt blockierende Recall-, MRR- und nDCG-Schwellen' (
        $perfect.Status -eq 'PASSED' -and $perfect.RecallAtK -eq 1 -and $perfect.Mrr -eq 1 -and $perfect.NdcgAtK -eq 1 -and
        (($perfect|ConvertTo-Json -Depth 10)|Test-Json -SchemaFile $evaluationSchema -ErrorAction SilentlyContinue))
    Add-CheckResult 'Degradiertes Retrieval liefert deterministische blockierende Reason-Codes' (
        $degraded.Status -eq 'BLOCKED' -and $degraded.Blockers -contains 'AI_EVALUATION_RECALL_BELOW_THRESHOLD' -and
        $degraded.Blockers -contains 'AI_EVALUATION_MRR_BELOW_THRESHOLD' -and $degraded.Blockers -contains 'AI_EVALUATION_NDCG_BELOW_THRESHOLD')
    $duplicateRankingRejected=$false
    try { Measure-SqlServerLabAiRetrieval -ExpectedDocumentId doc-1 -RankedDocumentId doc-1,doc-1 }
    catch { $duplicateRankingRejected=$_.Exception.Message -eq 'AI_EVALUATION_RANKED_ID_DUPLICATE' }
    Add-CheckResult 'Doppelte Ranking-IDs werden vor einer irreführenden Metrik abgelehnt' $duplicateRankingRejected

    $rag=& $module {
        $documents=@([PSCustomObject]@{Id='doc-alpha';Content='Alpha ist der erste synthetische Eintrag.'},[PSCustomObject]@{Id='doc-beta';Content='Beta ist der zweite synthetische Eintrag.'})
        $plan=New-LabAiRagPlan -RunId '11111111-2222-4333-8444-555555555555' -InstanceId primary -Question 'Was ist Alpha?' -Document $documents -EmbeddingModelKey ollama-embeddinggemma-300m-q4 -GenerationModelKey ollama-gemma3-1b-local -LocalPort 11434 -TopK 2
        $embeddingTransport={param($request)[PSCustomObject]@{StatusCode=200;Body=[PSCustomObject]@{embeddings=@(,@(1..768|ForEach-Object{if($_ -eq 1){1.0}else{0.0}}))}}}
        $generationTransport={param($request)[PSCustomObject]@{StatusCode=200;Body=[PSCustomObject]@{response='Alpha ist der erste Eintrag [doc-alpha].'}}}
        $sqlExecutor={param($query) @('AI_RAG_ROW|doc-alpha|0.0','AI_RAG_ROW|doc-beta|0.5')}
        $password=[SecureString]::new()
        $publicPlan=Invoke-SqlServerLabAiRag -RunId '11111111-2222-4333-8444-555555555555' -SaPassword $password -Question 'Was ist Alpha?' -Document $documents -TopK 2 -WhatIf
        $result=Invoke-LabAiRag -Plan $plan -SaPassword $password -Target ([PSCustomObject]@{Version='2025';Provider='hyperv';HostName='192.0.2.10';Port=1433}) -Question 'Was ist Alpha?' -EmbeddingTransport $embeddingTransport -GenerationTransport $generationTransport -SqlExecutor $sqlExecutor
        [PSCustomObject]@{Plan=$plan;PublicPlan=$publicPlan;Result=$result}
    }
    Add-CheckResult 'Providerneutraler Controller bindet Hyper-V-SQL an lokales Ollama-RAG' (
        $rag.Plan.Status -eq 'READY' -and $rag.Result.Status -eq 'SUCCEEDED' -and
        @($rag.Result.Citations) -join ',' -eq 'doc-alpha,doc-beta' -and $rag.Result.ToolExecutions[0].RowCount -eq 2)
    Add-CheckResult 'RAG-Ergebnis erfüllt den geheimnisfreien Query-Result-Vertrag' (
        (($rag.Result|ConvertTo-Json -Depth 20)|Test-Json -SchemaFile (Join-Path $repoRoot 'Schemas/ai-query-result.schema.json') -ErrorAction SilentlyContinue) -and
        (($rag.PublicPlan|ConvertTo-Json -Depth 20) -notmatch 'Alpha ist|Beta ist|Was ist'))

    $goldenRag=& $module {
        $golden=Read-LabAiRetrievalGoldenDataset -DatasetId sql-lab-rag-de -Version 1.0
        $case=Get-LabAiRetrievalGoldenCase -GoldenDataset $golden -CaseId backup-frequency
        $binding=[PSCustomObject]@{DatasetId='sql-lab-rag-de';DatasetVersion='1.0';DatasetHash=$golden.DatasetHash;CaseId='backup-frequency'}
        $plan=New-LabAiRagPlan -RunId '11111111-2222-4333-8444-555555555555' -InstanceId primary `
            -Question $case.question -Document @($golden.Dataset.documents) `
            -EmbeddingModelKey $golden.Dataset.models.embedding -GenerationModelKey $golden.Dataset.models.generation `
            -LocalPort 11434 -TopK $case.topK -EvaluationBinding $binding
        $embeddingTransport={param($request)[PSCustomObject]@{StatusCode=200;Body=[PSCustomObject]@{embeddings=@(,@(1..768|ForEach-Object{if($_ -eq 1){1.0}else{0.0}}))}}}
        $generationTransport={param($request)[PSCustomObject]@{StatusCode=200;Body=[PSCustomObject]@{response='Sicherungen werden täglich geprüft [backup-policy].'}}}
        $sqlExecutor={param($query) @('AI_RAG_ROW|backup-policy|0.0','AI_RAG_ROW|network-policy|0.5')}
        $password=[SecureString]::new()
        $result=Invoke-LabAiRag -Plan $plan -SaPassword $password -Target ([PSCustomObject]@{Version='2025';Provider='docker';HostName='127.0.0.1';Port=1433}) -Question $case.question -EmbeddingTransport $embeddingTransport -GenerationTransport $generationTransport -SqlExecutor $sqlExecutor
        [PSCustomObject]@{Golden=$golden;Plan=$plan;Result=$result}
    }
    $goldenEvaluation=Measure-SqlServerLabAiRetrieval -QueryResult $goldenRag.Result -CaseId backup-frequency
    $goldenWhatIf=Invoke-SqlServerLabAiRag -RunId '11111111-2222-4333-8444-555555555555' `
        -SaPassword ([SecureString]::new()) -CaseId backup-frequency -WhatIf
    Add-CheckResult 'Golden Dataset bindet Frage, Dokumente, Modelle und Plan vor dem SQL-RAG-Lauf' (
        $goldenWhatIf.EvaluationBinding.DatasetId -eq 'sql-lab-rag-de' -and
        $goldenWhatIf.EvaluationBinding.CaseId -eq 'backup-frequency' -and
        $goldenWhatIf.EvaluationBinding.DatasetHash -match '^[a-f0-9]{64}$' -and
        $goldenWhatIf.DocumentCount -eq 3 -and $goldenWhatIf.TopK -eq 2 -and
        (($goldenWhatIf|ConvertTo-Json -Depth 20) -notmatch 'Sicherungen|Testressourcen|Frage'))
    Add-CheckResult 'Ausgeführtes SQL-RAG wird gegen den gebundenen Golden-Fall blockierend bewertet' (
        $goldenEvaluation.Status -eq 'PASSED' -and $goldenEvaluation.RecallAtK -eq 1 -and
        $goldenEvaluation.Mrr -eq 1 -and $goldenEvaluation.NdcgAtK -eq 1 -and
        $goldenEvaluation.Binding.RunId -eq $goldenRag.Result.RunId -and
        $goldenEvaluation.Binding.PlanKey -eq $goldenRag.Result.PlanKey -and
        (($goldenRag.Result|ConvertTo-Json -Depth 20)|Test-Json -SchemaFile (Join-Path $repoRoot 'Schemas/ai-query-result.schema.json') -ErrorAction SilentlyContinue) -and
        (($goldenEvaluation|ConvertTo-Json -Depth 20)|Test-Json -SchemaFile (Join-Path $repoRoot 'Schemas/ai-retrieval-evaluation.schema.json') -ErrorAction SilentlyContinue))
    $goldenMismatchRejected=$false
    try {
        $tampered=$goldenRag.Result|ConvertTo-Json -Depth 20|ConvertFrom-Json -Depth 20
        $tampered.EvaluationBinding.DatasetHash='0000000000000000000000000000000000000000000000000000000000000000'
        Measure-SqlServerLabAiRetrieval -QueryResult $tampered -CaseId backup-frequency | Out-Null
    }
    catch { $goldenMismatchRejected=$_.Exception.Message -eq 'AI_EVALUATION_GOLDEN_BINDING_MISMATCH' }
    Add-CheckResult 'Manipulierte oder fallfremde Golden-Bindung wird vor der Metrik abgelehnt' $goldenMismatchRejected

    $agent=& $module {
        param($TemporaryRoot)
        $runId='11111111-2222-4333-8444-555555555555';$runDirectory=Join-Path (Join-Path $TemporaryRoot 'runs') $runId;New-Item $runDirectory -ItemType Directory -Force|Out-Null
        $plan=New-LabAiDiagnosticAgentPlan -RunId $runId -InstanceId primary -Question 'Wie ist der Zustand?' -ToolId server-summary,wait-statistics -GenerationModelKey ollama-gemma3-1b-local -LocalPort 11434
        $script:calls=[Collections.Generic.List[object]]::new()
        $sqlExecutor={param($credential,$sql,$nonQuery)$script:calls.Add([PSCustomObject]@{User=$credential.UserName;Sql=$sql;NonQuery=$nonQuery});if($sql-match'dm_os_sys_info'){return [PSCustomObject]@{ProductVersion='17.0';CpuCount=4;PhysicalMemoryKb=8192}};if($sql-match'dm_os_wait_stats'){return [PSCustomObject]@{WaitType='TEST_WAIT';WaitingTasks=1;WaitTimeMs=2}};@()}
        $transport={param($request)[PSCustomObject]@{StatusCode=200;Body=[PSCustomObject]@{response='Keine kritische synthetische Auffälligkeit.'}}}
        $password=[SecureString]::new();$result=Invoke-LabAiDiagnosticAgent -Plan $plan -SaPassword $password -Target ([PSCustomObject]@{Version='2025';Provider='hyperv';HostName='192.0.2.10';Port=1433}) -Question 'Wie ist der Zustand?' -StateRoot $TemporaryRoot -GenerationTransport $transport -SqlExecutor $sqlExecutor
        $journal=Get-Content (Get-ChildItem (Join-Path $runDirectory 'ai-agent') -File|Select-Object -First 1).FullName -Raw|ConvertFrom-Json
        [PSCustomObject]@{Plan=$plan;Result=$result;Calls=@($script:calls);Journal=$journal}
    } $temporaryRoot
    Add-CheckResult 'Providerneutraler Diagnose-Agent nutzt unter Hyper-V nur katalogisierte SELECT-Werkzeuge' (
        $agent.Result.Status -eq 'SUCCEEDED' -and $agent.Result.ToolExecutions.Count -eq 2 -and
        @($agent.Calls|Where-Object Sql -match '^CREATE LOGIN').Count -eq 1 -and @($agent.Calls|Where-Object Sql -match '^DROP LOGIN').Count -eq 1 -and
        @($agent.Calls|Where-Object {-not $_.NonQuery -and $_.Sql -notmatch '^SELECT '}).Count -eq 0)
    Add-CheckResult 'Agentjournal bleibt inhaltsfrei und dokumentiert erfolgreichen Cleanup' (
        $agent.Journal.status -eq 'SUCCEEDED' -and $agent.Journal.cleanupStatus -eq 'SUCCEEDED' -and
        (($agent.Journal|ConvertTo-Json -Depth 10) -notmatch 'TEST_WAIT|ProductVersion|Keine kritische') -and
        (($agent.Journal|ConvertTo-Json -Depth 10)|Test-Json -SchemaFile (Join-Path $repoRoot 'Schemas/ai-runtime-journal.schema.json') -ErrorAction SilentlyContinue))
    $unknownToolRejected=$false
    try { & $module { New-LabAiDiagnosticAgentPlan -RunId '11111111-2222-4333-8444-555555555555' -InstanceId primary -Question test -ToolId arbitrary-sql -GenerationModelKey ollama-gemma3-1b-local -LocalPort 11434 } }
    catch { $unknownToolRejected=$_.Exception.Message -match 'AI_AGENT_TOOL_NOT_ALLOWED' }
    Add-CheckResult 'Unbekannte und damit freie SQL-Werkzeuge werden fail-closed abgelehnt' $unknownToolRejected
    $capabilities=@(& $module { Get-LabProviderCapabilityContract });$dockerAgent=@(($capabilities|Where-Object Provider -eq docker).Capabilities.SourceKey);$podmanAgent=@(($capabilities|Where-Object Provider -eq podman).Capabilities.SourceKey);$hyperVAgent=@(($capabilities|Where-Object Provider -eq hyperv).Capabilities.SourceKey)
    Add-CheckResult 'Docker und Podman deklarieren native Agent-Evidence getrennt von Hyper-V' (
        'sql2025-ai-diagnostic-agent' -in $dockerAgent -and 'sql2025-ai-diagnostic-agent' -in $podmanAgent -and 'sql2025-ai-diagnostic-agent' -notin $hyperVAgent)
}
finally {
    Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$failed=@($results|Where-Object{-not $_.Success})
if($failed.Count -gt 0){throw "AI SCENARIO CHECKS FAILED: $($failed.Name -join '; ')"}
Write-Host "AI SCENARIO CHECKS: PASS ($($results.Count))" -ForegroundColor Green
