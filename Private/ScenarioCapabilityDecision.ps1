# Internal SCN-803: deterministic synthetic capability decisions only.
# Caller claims are not runtime evidence and this evaluator grants no execution authority.

function Test-LabScenarioDecisionJsonProperties {
    param([System.Text.Json.JsonElement]$Element)
    if ($Element.ValueKind -eq [System.Text.Json.JsonValueKind]::Object) {
        $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($property in $Element.EnumerateObject()) {
            if (-not $names.Add($property.Name) -or -not (Test-LabScenarioDecisionJsonProperties $property.Value)) { return $false }
        }
    }
    elseif ($Element.ValueKind -eq [System.Text.Json.JsonValueKind]::Array) {
        foreach ($item in $Element.EnumerateArray()) {
            if (-not (Test-LabScenarioDecisionJsonProperties $item)) { return $false }
        }
    }
    elseif ($Element.ValueKind -eq [System.Text.Json.JsonValueKind]::String -and $Element.GetString() -match '[\x00-\x1f\x7f]') { return $false }
    return $true
}

function Get-LabScenarioCapabilityDecision {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$ContractJson,
        [Parameter(Mandatory)][AllowEmptyString()][string]$PlanJson,
        [Parameter(Mandatory)][datetimeoffset]$EvaluationTimeUtc
    )
    $ErrorActionPreference = 'Stop'
    $result = [ordered]@{
        ContractVersion = 'SqlServerLab.InternalScenarioCapabilityDecision/0.1'
        Status = 'BLOCKED'; ReasonCode = 'INPUT_INVALID'
        ScenarioId = $null; ScenarioVersion = $null
        MissingCapabilityIds = @(); AlternativeEvidenceIds = @()
        AlternativeEvidenceUsed = $false; ExecutionPerformed = $false
        RuntimeEvidenceVerified = $false
    }
    $documents = [Collections.Generic.List[System.Text.Json.JsonDocument]]::new()
    try {
        if ($EvaluationTimeUtc.Offset -ne [timespan]::Zero) { return [pscustomobject]$result }
        $options = [System.Text.Json.JsonDocumentOptions]::new()
        $options.MaxDepth = 20
        foreach ($inputPair in @(@($ContractJson, 'scenario-contract.schema.json'), @($PlanJson, 'scenario-capability-plan.schema.json'))) {
            if ([string]::IsNullOrWhiteSpace($inputPair[0]) -or $inputPair[0].Length -gt 65536) { return [pscustomobject]$result }
            $document = [System.Text.Json.JsonDocument]::Parse([string]$inputPair[0], $options)
            $documents.Add($document)
            if (-not (Test-LabScenarioDecisionJsonProperties $document.RootElement)) { return [pscustomobject]$result }
            if (-not (Test-Json -Json $inputPair[0] -SchemaFile (Join-Path $PSScriptRoot "../Schemas/$($inputPair[1])") -ErrorAction Stop)) { return [pscustomobject]$result }
        }
        $contract = ConvertFrom-Json -InputObject $ContractJson -Depth 20 -AsHashtable
        $plan = ConvertFrom-Json -InputObject $PlanJson -Depth 20 -AsHashtable
        # SCN-801 allows a schema hint, but this slice never accepts an external locator.
        if ($contract.ContainsKey('$schema') -and $contract['$schema'] -cne 'scenario-contract.schema.json') { return [pscustomobject]$result }
        foreach ($collection in @('Steps', 'Evidence', 'Outcomes')) {
            $ids = @($contract[$collection].Id)
            if ($ids.Count -ne @($ids | Select-Object -Unique).Count) { return [pscustomobject]$result }
        }
        foreach ($entry in @($contract.Steps) + @($contract.Outcomes)) {
            foreach ($id in $entry.EvidenceIds) {
                if ($id -cnotin @($contract.Evidence.Id)) { return [pscustomobject]$result }
            }
        }
        foreach ($step in $contract.Steps) {
            foreach ($id in $step.OutcomeIds) {
                if ($id -cnotin @($contract.Outcomes.Id)) { return [pscustomobject]$result }
            }
        }
        $required = [string[]]@($plan.RequiredCapabilities)
        [Array]::Sort($required, [StringComparer]::Ordinal)
        $contractRequired = [string[]]@($contract.Scenario.RequiredSqlCapabilities)
        [Array]::Sort($contractRequired, [StringComparer]::Ordinal)
        if ($plan.ScenarioId -cne $contract.Scenario.Id -or $plan.ScenarioVersion -cne $contract.Scenario.Version -or
            ($required -join ',') -cne ($contractRequired -join ',')) { return [pscustomobject]$result }
        $missing = @($required | Where-Object { $_ -cnotin $plan.AvailableCapabilityIds })
        $evidenceIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $covered = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        # Validate every supplied alternative before making any positive decision.
        foreach ($evidence in $documents[1].RootElement.GetProperty('AlternativeEvidence').EnumerateArray()) {
            $capabilityId = $evidence.GetProperty('CapabilityId').GetString()
            $evidenceId = $evidence.GetProperty('EvidenceId').GetString()
            if ($evidence.GetProperty('ScenarioId').GetString() -cne $plan.ScenarioId -or
                $evidence.GetProperty('ScenarioVersion').GetString() -cne $plan.ScenarioVersion -or
                $capabilityId -cnotin $missing -or -not $covered.Add($capabilityId) -or -not $evidenceIds.Add($evidenceId)) { return [pscustomobject]$result }
            $boundEvidence = @($contract.Evidence | Where-Object { $_.Id -ceq $evidenceId -and $_.Classification -ceq 'SYNTHETIC' })
            if ($boundEvidence.Count -ne 1) { return [pscustomobject]$result }
            $observed = [datetimeoffset]::MinValue
            $expires = [datetimeoffset]::MinValue
            $style = [Globalization.DateTimeStyles]::AssumeUniversal
            if (-not [datetimeoffset]::TryParseExact($evidence.GetProperty('ObservedAtUtc').GetString(), "yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture, $style, [ref]$observed) -or
                -not [datetimeoffset]::TryParseExact($evidence.GetProperty('ExpiresAtUtc').GetString(), "yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture, $style, [ref]$expires) -or
                $observed -gt $EvaluationTimeUtc -or $expires -le $EvaluationTimeUtc -or $expires -le $observed -or
                ($expires - $observed).TotalHours -gt 24) { return [pscustomobject]$result }
        }
        $result.ScenarioId = $plan.ScenarioId
        $result.ScenarioVersion = $plan.ScenarioVersion
        $result.MissingCapabilityIds = $missing
        if ($missing.Count -eq 0) {
            $result.Status = 'ELIGIBLE'; $result.ReasonCode = 'DECLARED_CAPABILITIES_AVAILABLE'
        }
        elseif ($covered.Count -eq $missing.Count) {
            $result.Status = 'NOT_EXECUTED'; $result.ReasonCode = 'SYNTHETIC_ALTERNATIVE_ONLY'
            $result.AlternativeEvidenceUsed = $true
            $sortedEvidence = [string[]]@($evidenceIds)
            [Array]::Sort($sortedEvidence, [StringComparer]::Ordinal)
            $result.AlternativeEvidenceIds = $sortedEvidence
        }
        else {
            $result.Status = 'UNSUPPORTED'; $result.ReasonCode = 'REQUIRED_CAPABILITY_MISSING'
        }
        return [pscustomobject]$result
    }
    catch {
        # Never expose input, paths, JSON diagnostics or native exception text.
        return [pscustomobject][ordered]@{
            ContractVersion = 'SqlServerLab.InternalScenarioCapabilityDecision/0.1'
            Status = 'BLOCKED'; ReasonCode = 'INPUT_INVALID'
            ScenarioId = $null; ScenarioVersion = $null
            MissingCapabilityIds = @(); AlternativeEvidenceIds = @()
            AlternativeEvidenceUsed = $false; ExecutionPerformed = $false; RuntimeEvidenceVerified = $false
        }
    }
    finally {
        foreach ($document in $documents) { $document.Dispose() }
    }
}
