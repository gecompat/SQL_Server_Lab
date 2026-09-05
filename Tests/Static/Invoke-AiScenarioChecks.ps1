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
Add-CheckResult 'KI-Beispiel erfüllt den erweiterten Manifestvertrag' (
    (Get-Content $manifestPath -Raw -Encoding utf8) | Test-Json -SchemaFile $manifestSchema -ErrorAction SilentlyContinue)

Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
$module=Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru
$temporaryRoot=Join-Path ([IO.Path]::GetTempPath()) "sql-lab-ai-static-$([guid]::NewGuid().ToString('N'))"
try {
    $result=& $module {
        param($ManifestPath,$TemporaryRoot)
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
            instances=@([PSCustomObject]@{id='primary';provider='docker';containerName='synthetic-ai-target';host='127.0.0.1';port=14330;version='2025'})
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
        [PSCustomObject]@{
            Resolved=$resolved;Desired=$desired;CatalogPlan=$catalogPlan;RunPlan=$runPlan;WhatIf=$whatIf
            JournalAbsent=-not (Test-Path -LiteralPath $journalPath)
            EgressRejected=(-not $egressValidation.IsValid -and @($egressValidation.Errors) -match "Cloud-Modell.*benötigt 'explicit'")
            PathRejected=$pathRejected
            DockerCapability='sql2025-vector-core' -in @($providerCapabilities|Where-Object Provider -eq docker|ForEach-Object Capabilities|ForEach-Object SourceKey)
            PodmanCapability='sql2025-vector-core' -in @($providerCapabilities|Where-Object Provider -eq podman|ForEach-Object Capabilities|ForEach-Object SourceKey)
        }
    } $manifestPath $temporaryRoot

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
}
finally {
    Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$failed=@($results|Where-Object{-not $_.Success})
if($failed.Count -gt 0){throw "AI SCENARIO CHECKS FAILED: $($failed.Name -join '; ')"}
Write-Host "AI SCENARIO CHECKS: PASS ($($results.Count))" -ForegroundColor Green
