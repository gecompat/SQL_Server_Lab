[CmdletBinding()]
param(
    [Parameter()]
    [string] $RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$schemaTests = @(
    @{
        Instance = 'Lab/Validation/Fixtures/Valid/lab-config.example.json'
        Schema = 'Lab/Contracts/lab-config.schema.json'
    }
    @{
        Instance = 'Lab/Config/host-capabilities.example.json'
        Schema = 'Lab/Contracts/host-capability.schema.json'
    }
    @{
        Instance = 'Lab/Validation/Fixtures/Valid/topology.example.json'
        Schema = 'Lab/Contracts/topology.schema.json'
    }
    @{
        Instance = 'Lab/Validation/Fixtures/Valid/scenario.example.json'
        Schema = 'Lab/Contracts/scenario.schema.json'
    }
    @{
        Instance = 'Lab/Validation/Fixtures/Valid/evidence.example.json'
        Schema = 'Lab/Contracts/evidence.schema.json'
    }
    @{
        Instance = 'Lab/Validation/Fixtures/Valid/finding-expectation.example.json'
        Schema = 'Lab/Contracts/finding-expectation.schema.json'
    }
    @{
        Instance = 'Lab/Scenarios/Core/LAB-BASE-001/scenario.json'
        Schema = 'Lab/Contracts/scenario.schema.json'
    }
    @{
        Instance = 'Lab/Scenarios/Core/LAB-BASE-002/scenario.json'
        Schema = 'Lab/Contracts/scenario.schema.json'
    }
    @{
        Instance = 'Lab/Scenarios/Infrastructure/wave4-topology-profiles.json'
        Schema = 'Lab/Contracts/wave4-topology-profile.schema.json'
    }
    @{
        Instance = 'Lab/Scenarios/Infrastructure/LAB-LS-001/scenario.json'
        Schema = 'Lab/Contracts/scenario.schema.json'
    }
    @{
        Instance = 'Lab/Scenarios/Infrastructure/LAB-LS-001/runbook.json'
        Schema = 'Lab/Contracts/scenario-runbook.schema.json'
    }
    @{
        Instance = 'Lab/HyperV/Images/image-pipeline-contract.json'
        Schema = 'Lab/Contracts/hyperv-image-pipeline.schema.json'
    }
)

foreach ($test in $schemaTests) {
    $instancePath = Join-Path $RepositoryRoot $test.Instance
    $schemaPath = Join-Path $RepositoryRoot $test.Schema
    $json = Get-Content -LiteralPath $instancePath -Raw -Encoding utf8
    $valid = Test-Json -Json $json -SchemaFile $schemaPath -ErrorAction Stop
    if (-not $valid) {
        throw "LAB-001 JSON schema validation failed for $($test.Instance)."
    }
}

$performanceRoot = Join-Path $RepositoryRoot 'Lab/Scenarios/Performance'
$scenarioSchemaPath = Join-Path (
    $RepositoryRoot
) 'Lab/Contracts/scenario.schema.json'
$runbookSchemaPath = Join-Path (
    $RepositoryRoot
) 'Lab/Contracts/scenario-runbook.schema.json'
foreach ($directory in @(
        Get-ChildItem `
            -LiteralPath $performanceRoot `
            -Directory |
            Where-Object { $_.Name -ne '_Shared' }
    )) {
    foreach ($contract in @(
            @{
                Path = Join-Path $directory.FullName 'scenario.json'
                Schema = $scenarioSchemaPath
            }
            @{
                Path = Join-Path $directory.FullName 'runbook.json'
                Schema = $runbookSchemaPath
            }
        )) {
        $json = Get-Content `
            -LiteralPath $contract.Path `
            -Raw `
            -Encoding utf8
        if (-not (Test-Json `
                -Json $json `
                -SchemaFile $contract.Schema `
                -ErrorAction Stop)) {
            throw "LAB-001 JSON schema validation failed for $($contract.Path)."
        }
    }
}

$fixturePath = Join-Path (
    $performanceRoot
) 'LAB-DEAD-004/fixture.json'
$fixtureSchemaPath = Join-Path (
    $RepositoryRoot
) 'Lab/Contracts/contract-fixture.schema.json'
if (-not (Test-Json `
        -Json (Get-Content `
            -LiteralPath $fixturePath `
            -Raw `
            -Encoding utf8) `
        -SchemaFile $fixtureSchemaPath `
        -ErrorAction Stop)) {
    throw 'LAB-001 contract fixture schema validation failed.'
}

$topologySchemaPath = Join-Path $RepositoryRoot 'Lab/Contracts/topology.schema.json'
$topologyCatalogPath = Join-Path $RepositoryRoot 'Lab/Scenarios/Catalog/topologies.json'
$topologyCatalog = Get-Content -LiteralPath $topologyCatalogPath -Raw -Encoding utf8 |
    ConvertFrom-Json -Depth 100

foreach ($topology in $topologyCatalog.Topologies) {
    $topologyJson = $topology | ConvertTo-Json -Depth 100
    $valid = Test-Json -Json $topologyJson -SchemaFile $topologySchemaPath -ErrorAction Stop
    if (-not $valid) {
        throw 'LAB-001 topology catalog contains an invalid topology contract.'
    }
}

$pythonExecutable = $null
$pythonCandidates = @($env:PYTHON_COMMAND, 'python3', 'python') |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
    Select-Object -Unique
foreach ($candidate in $pythonCandidates) {
    $pythonCommand = Get-Command $candidate -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -eq $pythonCommand) {
        continue
    }
    & $pythonCommand.Source --version *> $null
    if ($LASTEXITCODE -eq 0) {
        $pythonExecutable = $pythonCommand.Source
        break
    }
}
if ($null -eq $pythonExecutable) {
    throw 'Python is unavailable for LAB-001 validation.'
}

foreach ($validator in @(
        'Code/Tests/Static/988_Validate_LAB001_Wave0_Contracts.py'
        'Code/Tests/Static/989_Validate_LAB001_Wave1_Orchestrator.py'
        'Code/Tests/Static/990_Validate_LAB001_Wave2_ContainerBaseline.py'
        'Code/Tests/Static/Validate_LAB001_Wave3_CorePerformance.py'
        'Code/Tests/Static/Validate_LAB001_Wave4_ContractFoundation.py'
        'Code/Tests/Static/Validate_LAB001_Wave4_MultiContainerRuntime.py'
        'Code/Tests/Static/Validate_LAB001_Wave4_LogShipping.py'
        'Code/Tests/Static/Validate_LAB001_Wave5_ImagePipelineFoundation.py'
    )) {
    $validatorPath = Join-Path $RepositoryRoot $validator
    & $pythonExecutable $validatorPath --repository-root $RepositoryRoot
    if ($LASTEXITCODE -ne 0) {
        throw "LAB-001 validation failed with exit code $LASTEXITCODE."
    }
}

Write-Output 'LAB-001 PowerShell JSON-schema and static validation passed including LAB-LS-001.'
