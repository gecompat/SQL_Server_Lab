#Requires -Version 7.2
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
. (Join-Path $PSScriptRoot '../Common/CheckResult.ps1')
. (Join-Path $repoRoot 'Private/ScenarioCapabilityDecision.ps1')
$failures = [Collections.Generic.List[string]]::new()
$passed = 0
$contractJson = Get-Content (Join-Path $repoRoot 'Schemas/scenario-contract.example.json') -Raw
$decisionSchema = Join-Path $repoRoot 'Schemas/scenario-capability-decision.schema.json'
$now = [datetimeoffset]'2026-01-15T12:00:00Z'

function New-TestPlan {
    return [ordered]@{
        ContractVersion = 'SqlServerLab.InternalScenarioCapabilityPlan/0.1'
        ScenarioId = 'synthetic-scenario-contract'; ScenarioVersion = '1.0'
        RequiredCapabilities = @('sql-read-only-observation')
        AvailableCapabilityIds = @('sql-read-only-observation')
        AlternativeEvidence = @()
    }
}
function New-TestEvidence {
    return [ordered]@{
        EvidenceId = 'synthetic-observation'; CapabilityId = 'sql-read-only-observation'
        ScenarioId = 'synthetic-scenario-contract'; ScenarioVersion = '1.0'
        Classification = 'SYNTHETIC'; Result = 'PASSED'
        ObservedAtUtc = '2026-01-15T11:00:00Z'; ExpiresAtUtc = '2026-01-15T13:00:00Z'
    }
}
function Test-Decision {
    param([string]$Name, $Plan, [string]$Expected, [string]$Contract = $contractJson, [string]$Json, [datetimeoffset]$Time = $now)
    if (-not $PSBoundParameters.ContainsKey('Json')) { $Json = ConvertTo-Json -InputObject $Plan -Depth 20 -Compress }
    $first = @(Get-LabScenarioCapabilityDecision -ContractJson $Contract -PlanJson $Json -EvaluationTimeUtc $Time *>&1)
    $second = @(Get-LabScenarioCapabilityDecision -ContractJson $Contract -PlanJson $Json -EvaluationTimeUtc $Time *>&1)
    $serialized = ConvertTo-Json -InputObject $first[0] -Depth 20 -Compress
    $isValid = $first.Count -eq 1 -and $second.Count -eq 1 -and $first[0].Status -ceq $Expected -and
        ($serialized -ceq (ConvertTo-Json -InputObject $second[0] -Depth 20 -Compress)) -and
        (Test-Json -Json $serialized -SchemaFile $decisionSchema -ErrorAction SilentlyContinue) -and
        -not $first[0].ExecutionPerformed -and -not $first[0].RuntimeEvidenceVerified
    Add-CheckResult -Name $Name -Success $isValid
    return $first[0]
}

$plan = New-TestPlan
$null = Test-Decision 'Vorhandene deklarierte Capability ist ELIGIBLE ohne Ausfuehrung' $plan ELIGIBLE
$plan.AvailableCapabilityIds = @()
$null = Test-Decision 'Fehlende Capability ohne Alternative ist UNSUPPORTED' $plan UNSUPPORTED
$plan.AlternativeEvidence = @(New-TestEvidence)
$alternative = Test-Decision 'Gebundene synthetische Alternative ist NOT_EXECUTED' $plan NOT_EXECUTED
Add-CheckResult -Name 'Alternative wird nur als synthetische Evidence verwendet' -Success (
    $alternative.AlternativeEvidenceUsed -and $alternative.AlternativeEvidenceIds.Count -eq 1 -and
    $alternative.AlternativeEvidenceIds[0] -ceq 'synthetic-observation')
$null = Test-Decision 'ObservedAt-Grenze ist inklusive' $plan NOT_EXECUTED -Time ([datetimeoffset]'2026-01-15T11:00:00Z')
$null = Test-Decision 'ExpiresAt-Grenze ist exklusiv' $plan BLOCKED -Time ([datetimeoffset]'2026-01-15T13:00:00Z')
$plan.AlternativeEvidence[0].ExpiresAtUtc = '2026-01-16T11:00:00Z'
$null = Test-Decision 'Genau 24 Stunden Gueltigkeit sind erlaubt' $plan NOT_EXECUTED
$plan.AlternativeEvidence[0].ExpiresAtUtc = '2026-01-16T11:00:01Z'
$null = Test-Decision 'Mehr als 24 Stunden Gueltigkeit blockiert' $plan BLOCKED

$negativeEvidence = @(
    @{ Field = 'CapabilityId'; Value = 'sql-foreign-capability' },
    @{ Field = 'ScenarioId'; Value = 'foreign-scenario' },
    @{ Field = 'ScenarioVersion'; Value = '2.0' },
    @{ Field = 'EvidenceId'; Value = 'foreign-evidence' },
    @{ Field = 'Classification'; Value = 'SANITIZED_METADATA' },
    @{ Field = 'Result'; Value = 'FAILED' },
    @{ Field = 'Result'; Value = 'NOT_EXECUTED' },
    @{ Field = 'ObservedAtUtc'; Value = '2026-01-15T12:00:01Z' },
    @{ Field = 'ExpiresAtUtc'; Value = '2026-01-15T12:00:00Z' },
    @{ Field = 'ExpiresAtUtc'; Value = '2026-01-15T10:00:00Z' },
    @{ Field = 'ExpiresAtUtc'; Value = '2026-01-17T13:00:00Z' },
    @{ Field = 'ExpiresAtUtc'; Value = '2026-02-30T13:00:00Z' },
    @{ Field = 'ExpiresAtUtc'; Value = '2026-01-15T13:00:00+00:00' },
    @{ Field = 'Command'; Value = 'Invoke-Anything' },
    @{ Field = 'Path'; Value = '/synthetic/private-data' },
    @{ Field = 'Secret'; Value = 'synthetic-marker-not-a-credential' },
    @{ Field = 'Extra'; Value = $null }
)
foreach ($case in $negativeEvidence) {
    $invalid = New-TestEvidence
    $invalid[$case.Field] = $case.Value
    $plan.AlternativeEvidence = @($invalid)
    $null = Test-Decision "Alternative: $($case.Field)=$($case.Value) blockiert" $plan BLOCKED
}
$plan.AlternativeEvidence = @((New-TestEvidence), (New-TestEvidence))
$null = Test-Decision 'Doppelte Alternative blockiert' $plan BLOCKED
$plan.AlternativeEvidence = @(New-TestEvidence)
$plan.AvailableCapabilityIds = @('sql-read-only-observation')
$null = Test-Decision 'Unbenutzte Alternative fuer verfuegbare Capability blockiert' $plan BLOCKED
$plan.AlternativeEvidence[0].Secret = 'synthetic-marker-not-a-credential'
$null = Test-Decision 'Ungueltige Alternative blockiert auch bei vollstaendigen Capabilities' $plan BLOCKED

foreach ($field in @('Command','Path','Secret','Provider','Unknown')) {
    $invalidPlan = New-TestPlan
    $invalidPlan[$field] = 'synthetic-marker'
    $null = Test-Decision "Unbekanntes Planfeld $field blockiert" $invalidPlan BLOCKED
}
foreach ($field in @('ContractVersion','ScenarioId','ScenarioVersion','RequiredCapabilities','AvailableCapabilityIds','AlternativeEvidence')) {
    $invalidPlan = New-TestPlan
    $invalidPlan.Remove($field)
    $null = Test-Decision "Fehlendes Pflichtfeld $field blockiert" $invalidPlan BLOCKED
}
foreach ($badId in @('UPPER-CASE','with space','../synthetic','synthetic/host',"synthetic-id`n",'abc;exit',('x' * 65))) {
    $invalidPlan = New-TestPlan
    $invalidPlan.AvailableCapabilityIds = @($badId)
    $null = Test-Decision 'Nicht sanitisiertes Capability-Format blockiert' $invalidPlan BLOCKED
}
$invalidPlan = New-TestPlan
$invalidPlan.RequiredCapabilities = @('sql-other-capability')
$null = Test-Decision 'Plan muss exakt alle Contract-Capabilities binden' $invalidPlan BLOCKED
$invalidPlan = New-TestPlan
$invalidPlan.RequiredCapabilities += 'sql-read-only-observation'
$null = Test-Decision 'Doppelte RequiredCapability blockiert' $invalidPlan BLOCKED
$invalidPlan = New-TestPlan
$invalidPlan.AvailableCapabilityIds += 'sql-read-only-observation'
$null = Test-Decision 'Doppelte AvailableCapability blockiert' $invalidPlan BLOCKED
foreach ($field in @('RequiredCapabilities','AvailableCapabilityIds','AlternativeEvidence')) {
    foreach ($badValue in @($null, 1, 'sql-read-only-observation', @{ Invalid = 'synthetic' })) {
        $invalidPlan = New-TestPlan
        $invalidPlan[$field] = $badValue
        $null = Test-Decision "Falscher Typ fuer $field blockiert" $invalidPlan BLOCKED
    }
}
$invalidPlan = New-TestPlan
$invalidPlan.RequiredCapabilities = @()
$null = Test-Decision 'Leere RequiredCapabilities blockiert' $invalidPlan BLOCKED
$invalidPlan = New-TestPlan
$invalidPlan.ScenarioId = 'foreign-scenario'
$null = Test-Decision 'Fremdes Plan-Scenario blockiert' $invalidPlan BLOCKED
$invalidPlan = New-TestPlan
$invalidPlan.ScenarioVersion = '2.0'
$null = Test-Decision 'Fremde Plan-Version blockiert' $invalidPlan BLOCKED
$null = Test-Decision 'Nicht-UTC-Auswertungszeit blockiert' (New-TestPlan) BLOCKED -Time ([datetimeoffset]'2026-01-15T13:00:00+01:00')

foreach ($badJson in @('', '{}', 'null', '[]', '{', (' ' * 65537))) {
    $null = Test-Decision 'Leeres, defektes oder zu grosses Plan-JSON blockiert' $null BLOCKED -Json $badJson
}
$validJson = ConvertTo-Json -InputObject (New-TestPlan) -Depth 20 -Compress
foreach ($duplicate in @('ScenarioId','scenarioid')) {
    $badJson = $validJson.Replace('{', ('{"' + $duplicate + '":"foreign-scenario",'))
    $null = Test-Decision 'Doppeltes oder anders geschriebenes JSON-Feld blockiert' $null BLOCKED -Json $badJson
}
$nestedDuplicate = (ConvertTo-Json -InputObject (New-TestEvidence) -Compress).Replace('{', '{"CapabilityId":"sql-read-only-observation",')
$nestedPlan = (New-TestPlan)
$nestedPlan.AvailableCapabilityIds = @()
$nestedJson = (ConvertTo-Json -InputObject $nestedPlan -Compress).Replace('"AlternativeEvidence":[]', ('"AlternativeEvidence":[' + $nestedDuplicate + ']'))
$null = Test-Decision 'Doppeltes verschachteltes Evidencefeld blockiert' $null BLOCKED -Json $nestedJson

foreach ($mutation in @('execution','provider','foreign-schema','duplicate-evidence','missing-evidence','missing-outcome','nonsynthetic')) {
    $badContract = ConvertFrom-Json -InputObject $contractJson -AsHashtable
    switch ($mutation) {
        'execution' { $badContract.ExecutionImplemented = $true }
        'provider' { $badContract.Scenario.Provider = 'docker' }
        'foreign-schema' { $badContract['$schema'] = 'https://synthetic.invalid/schema.json' }
        'duplicate-evidence' { $badContract.Evidence += $badContract.Evidence[0] }
        'missing-evidence' { $badContract.Steps[0].EvidenceIds = @('missing-evidence') }
        'missing-outcome' { $badContract.Steps[0].OutcomeIds = @('missing-outcome') }
        'nonsynthetic' { $badContract.Evidence[0].Classification = 'SANITIZED_METADATA' }
    }
    $plan = New-TestPlan
    $plan.AvailableCapabilityIds = @()
    $plan.AlternativeEvidence = @(New-TestEvidence)
    $null = Test-Decision "Contract-Verletzung $mutation blockiert" $plan BLOCKED -Contract (ConvertTo-Json -InputObject $badContract -Depth 20)
}

# Multi-capability coverage is all-or-nothing and independent of input ordering.
$multiContract = ConvertFrom-Json -InputObject $contractJson -AsHashtable
$multiContract.Scenario.RequiredSqlCapabilities += 'sql-second-observation'
$multiJson = ConvertTo-Json -InputObject $multiContract -Depth 20
$multiPlan = New-TestPlan
$multiPlan.RequiredCapabilities = @('sql-second-observation','sql-read-only-observation')
$multiPlan.AvailableCapabilityIds = @()
$multiPlan.AlternativeEvidence = @(New-TestEvidence)
$partial = Test-Decision 'Partielle Alternative bleibt UNSUPPORTED ohne Evidenceverbrauch' $multiPlan UNSUPPORTED -Contract $multiJson
Add-CheckResult -Name 'Partielle Evidence wird nicht als genutzt markiert' -Success (-not $partial.AlternativeEvidenceUsed -and $partial.AlternativeEvidenceIds.Count -eq 0)
$secondEvidence = New-TestEvidence
$secondEvidence.CapabilityId = 'sql-second-observation'
$secondEvidence.EvidenceId = 'synthetic-assertion'
$multiPlan.AlternativeEvidence += $secondEvidence
$complete = Test-Decision 'Alle fehlenden Capabilities exakt synthetisch belegt' $multiPlan NOT_EXECUTED -Contract $multiJson
$multiPlan.RequiredCapabilities = @('sql-read-only-observation','sql-second-observation')
$multiPlan.AlternativeEvidence = @($secondEvidence, (New-TestEvidence))
$reordered = Test-Decision 'Umgeordnete Eingaben bleiben semantisch gleich' $multiPlan NOT_EXECUTED -Contract $multiJson
Add-CheckResult -Name 'Ausgabeordnung ist ordinal und deterministisch' -Success (
    (ConvertTo-Json -InputObject $complete -Depth 20 -Compress) -ceq (ConvertTo-Json -InputObject $reordered -Depth 20 -Compress))
$snapshot = ConvertTo-Json -InputObject $multiPlan -Depth 20 -Compress
$null = Get-LabScenarioCapabilityDecision -ContractJson $multiJson -PlanJson $snapshot -EvaluationTimeUtc $now
Add-CheckResult -Name 'Aufruferplan und Contract bleiben unveraendert' -Success (
    $snapshot -ceq (ConvertTo-Json -InputObject $multiPlan -Depth 20 -Compress) -and
    $multiJson -ceq (ConvertTo-Json -InputObject $multiContract -Depth 20))

$sourcePath = Join-Path $repoRoot 'Private/ScenarioCapabilityDecision.ps1'
$tokens = $null; $parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$parseErrors)
$allowedCommands = @('Test-LabScenarioDecisionJsonProperties','Test-Json','Join-Path','ConvertFrom-Json','Select-Object','Where-Object')
$commands = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] }, $true))
Add-CheckResult -Name 'Geschlossene Befehlsliste ohne Discovery, Runtime, SQL oder Dateischreiben' -Success (
    $parseErrors.Count -eq 0 -and @($commands | Where-Object { $_.GetCommandName() -cnotin $allowedCommands -or $_.InvocationOperator -ne 'Unknown' }).Count -eq 0)
$allowedMethods = @('Add','ContainsKey','Dispose','EnumerateArray','EnumerateObject','GetProperty','GetString','IsNullOrWhiteSpace','new','Parse','Sort','TryParseExact')
$members = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.InvokeMemberExpressionAst] }, $true))
$allowedTypes = @('Array','Collections.Generic.HashSet[string]','Collections.Generic.List[System.Text.Json.JsonDocument]',
    'datetimeoffset','Globalization.CultureInfo','Globalization.DateTimeStyles','string','StringComparer',
    'System.Text.Json.JsonDocument','System.Text.Json.JsonDocumentOptions','System.Text.Json.JsonValueKind','timespan')
$types = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.TypeExpressionAst] }, $true))
Add-CheckResult -Name 'Geschlossene .NET-Methoden und Typen ohne externe Seiteneffekte' -Success (
    @($members | Where-Object { $_.Member.Value -cnotin $allowedMethods }).Count -eq 0 -and
    @($types | Where-Object { $_.TypeName.FullName -cnotin $allowedTypes }).Count -eq 0)
$manifest = Import-PowerShellDataFile (Join-Path $repoRoot 'SqlServerLab.psd1')
Add-CheckResult -Name 'Evaluator bleibt privat' -Success ('Get-LabScenarioCapabilityDecision' -notin $manifest.FunctionsToExport)
$originalContract = ConvertFrom-Json -InputObject $contractJson
Add-CheckResult -Name 'SCN-801 bleibt ExecutionImplemented=false' -Success (-not $originalContract.ExecutionImplemented)

if ($failures.Count) { throw "SCENARIO CAPABILITY DECISION CHECKS: $($failures.Count) FAIL: $($failures -join '; ')" }
Write-Host "SCENARIO CAPABILITY DECISION CHECKS: $passed PASS, 0 FAIL" -ForegroundColor Green
