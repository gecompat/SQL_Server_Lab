[CmdletBinding()]
param(
    [Parameter()]
    [string] $RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$modulePath = Join-Path (
    $RepositoryRoot
) 'Lab/Orchestration/Modules/DiagnosticLab/DiagnosticLab.psd1'
Import-Module -Name $modulePath -Force -ErrorAction Stop

try {
    foreach ($functionName in @(
            'Invoke-LabScenario',
            'Invoke-LabUp',
            'Invoke-LabVersionMatrix',
            'Test-LabScenario'
        )) {
        if ($null -eq (Get-Command $functionName -ErrorAction SilentlyContinue)) {
            throw "Required Welle 3 function is missing: $functionName"
        }
    }

    $performanceRoot = Join-Path (
        $RepositoryRoot
    ) 'Lab/Scenarios/Performance'
    $scenarioDirectories = @(
        Get-ChildItem `
            -LiteralPath $performanceRoot `
            -Directory |
            Where-Object { $_.Name -ne '_Shared' }
    )
    if ($scenarioDirectories.Count -ne 39) {
        throw 'Welle 3 must contain exactly 39 scenario directories.'
    }

    $scenarioSchema = Join-Path (
        $RepositoryRoot
    ) 'Lab/Contracts/scenario.schema.json'
    $runbookSchema = Join-Path (
        $RepositoryRoot
    ) 'Lab/Contracts/scenario-runbook.schema.json'
    foreach ($directory in $scenarioDirectories) {
        foreach ($contract in @(
                @{
                    Path = Join-Path $directory.FullName 'scenario.json'
                    Schema = $scenarioSchema
                }
                @{
                    Path = Join-Path $directory.FullName 'runbook.json'
                    Schema = $runbookSchema
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
                throw "Invalid Welle 3 JSON contract: $($contract.Path)"
            }
        }
    }

    $fixturePath = Join-Path (
        $performanceRoot
    ) 'LAB-DEAD-004/fixture.json'
    $fixtureSchema = Join-Path (
        $RepositoryRoot
    ) 'Lab/Contracts/contract-fixture.schema.json'
    if (-not (Test-Json `
            -Json (Get-Content `
                -LiteralPath $fixturePath `
                -Raw `
                -Encoding utf8) `
            -SchemaFile $fixtureSchema `
            -ErrorAction Stop)) {
        throw 'LAB-DEAD-004 fixture contract is invalid.'
    }

    $exampleLock = Get-Content `
        -LiteralPath (Join-Path (
            $RepositoryRoot
        ) 'Lab/Config/image-lock.example.json') `
        -Raw `
        -Encoding utf8 |
        ConvertFrom-Json -Depth 20
    $sqlVersions = @(
        $exampleLock.Images |
            Where-Object { $_.ProductFamily -eq 'SQL_SERVER' } |
            ForEach-Object { [int] $_.ProductVersion } |
            Sort-Object
    )
    if (
        $sqlVersions.Count -ne 3 -or
        ($sqlVersions -join ',') -ne '2019,2022,2025'
    ) {
        throw 'The public image lock does not expose all three version lanes.'
    }
    if (@(
            $exampleLock.Images |
                Where-Object {
                    $_.ProductFamily -eq 'SQL_SERVER' -and
                    (
                        $_.Status -ne 'UNRESOLVED_EXAMPLE' -or
                        $_.Digest -ne 'SHA256_DIGEST_REQUIRED'
                    )
                }
        ).Count -gt 0) {
        throw 'The public image lock contains a fabricated resolved digest.'
    }

    $configPath = Join-Path (
        $RepositoryRoot
    ) 'Lab/Config/lab.config.example.psd1'
    $matrixPreview = @(
        Invoke-LabVersionMatrix `
            -ConfigPath $configPath `
            -WhatIf `
            -Confirm:$false
    )
    if (
        $matrixPreview.Count -ne 1 -or
        $matrixPreview[0].Status -ne 'WHATIF' -or
        (@($matrixPreview[0].SqlVersions) -join ',') -ne '2019,2022,2025'
    ) {
        throw 'The version-matrix WhatIf contract is invalid.'
    }

    $stateRoot = Join-Path (
        [IO.Path]::GetTempPath()
    ) ('lab001-wave3-' + [Guid]::NewGuid().ToString('N'))
    try {
        [IO.Directory]::CreateDirectory($stateRoot) | Out-Null
        $labRunId = 'LAB-20000101T000000Z-00000001'
        $fixtureResult = Invoke-LabScenario `
            -LabRunId $labRunId `
            -ScenarioId LAB-DEAD-004 `
            -StateRoot $stateRoot
        if (
            $fixtureResult.AnalyzerStatus -ne 'CONTRACT_FIXTURE' -or
            $fixtureResult.CleanupStatus -ne 'NOT_REQUIRED'
        ) {
            throw 'The fixture runtime boundary is invalid.'
        }
        $validation = Test-LabScenario `
            -LabRunId $labRunId `
            -ScenarioId LAB-DEAD-004 `
            -StateRoot $stateRoot
        if ($validation.ValidationStatus -ne 'PASS') {
            throw 'The fixture validation contract failed.'
        }
    }
    finally {
        if (Test-Path -LiteralPath $stateRoot -PathType Container) {
            [IO.Directory]::Delete($stateRoot, $true)
        }
    }

    $validatorPath = Join-Path (
        $RepositoryRoot
    ) 'Code/Tests/Static/Validate_LAB001_Wave3_CorePerformance.py'
    $python = Get-Command python3 -ErrorAction SilentlyContinue
    if ($null -eq $python) {
        $python = Get-Command python -ErrorAction Stop
    }
    & $python.Source $validatorPath --repository-root $RepositoryRoot
    if ($LASTEXITCODE -ne 0) {
        throw "Welle 3 static validation failed with exit code $LASTEXITCODE."
    }
}
finally {
    Remove-Module -Name DiagnosticLab -Force -ErrorAction SilentlyContinue
}

Write-Output 'LAB-001 Welle 3 PowerShell contract tests passed.'
