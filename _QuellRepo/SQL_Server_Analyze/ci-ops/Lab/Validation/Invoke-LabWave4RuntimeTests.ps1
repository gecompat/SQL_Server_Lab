[CmdletBinding()]
param(
    [Parameter()]
    [string] $RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$paths = @(
    'Lab/Orchestration/Invoke-DiagnosticLab.ps1'
    'Lab/Orchestration/Modules/DiagnosticLab/DiagnosticLab.psd1'
    'Lab/Orchestration/Modules/DiagnosticLab/DiagnosticLab.psm1'
    'Lab/Orchestration/Modules/DiagnosticLab/Private/MultiContainerRuntime.ps1'
    'Lab/Orchestration/Modules/DiagnosticLab/Private/ResourceMeasurement.ps1'
    'Lab/Orchestration/Modules/DiagnosticLab/Public/Invoke-LabMultiContainerUp.ps1'
)
foreach ($relativePath in $paths) {
    $tokens = $null
    $errors = $null
    [Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $RepositoryRoot $relativePath),
        [ref] $tokens,
        [ref] $errors
    ) | Out-Null
    if (@($errors).Count -gt 0) {
        $summary = @($errors | ForEach-Object { $_.Message }) -join '; '
        throw "PowerShell parser reported an error for ${relativePath}: $summary"
    }
}

$modulePath = Join-Path (
    $RepositoryRoot
) 'Lab/Orchestration/Modules/DiagnosticLab/DiagnosticLab.psd1'
Import-Module -Name $modulePath -Force -ErrorAction Stop
try {
    if ($null -eq (Get-Command Invoke-LabMultiContainerUp -ErrorAction SilentlyContinue)) {
        throw 'Invoke-LabMultiContainerUp is not exported.'
    }

    $module = Get-Module DiagnosticLab
    $pair = & $module {
        Get-LabWave4TopologyPlan -TopologyId CTR-PAIR
    }
    if (
        $pair.TopologyId -ne 'CTR-PAIR' -or
        $pair.ResourceProfile -ne 'Standard' -or
        $pair.ManagementPath -ne 'DOCKER_EXEC_OUT_OF_BAND' -or
        $pair.Nodes.Count -ne 2 -or
        (@($pair.Nodes.Role) -join ',') -ne 'SQL_PRIMARY,SQL_SECONDARY' -or
        (@($pair.NetworkSegments | Sort-Object) -join ',') -ne 'LAB_DATA,LAB_MANAGEMENT'
    ) {
        throw 'CTR-PAIR topology plan is invalid.'
    }

    $triple = & $module {
        Get-LabWave4TopologyPlan -TopologyId CTR-TRIPLE
    }
    if (
        $triple.Nodes.Count -ne 3 -or
        (@($triple.Nodes.Role) -join ',') -ne
        'SQL_PRIMARY,SQL_SECONDARY,SQL_TERTIARY'
    ) {
        throw 'CTR-TRIPLE topology plan is invalid.'
    }

    $budget = & $module {
        Get-LabContainerBudget -ResourceProfile Standard
    }
    if (
        $budget.MemoryMiB -ne 4096 -or
        $budget.LogicalProcessors -ne 2 -or
        $budget.SqlMemoryLimitMiB -ne 3072 -or
        $budget.MaximumStorageGiB -ne 48
    ) {
        throw 'Standard multi-container budget is invalid.'
    }

    $syntheticSnapshot = [pscustomobject] @{
        AvailableMemoryMiB = 30000
        AvailableStorageGiB = 300
    }
    $reserve = & $module {
        param($Snapshot, $Budget)
        Assert-LabResourceBudget `
            -Snapshot $Snapshot `
            -Budget $Budget `
            -Phase BEFORE_UP `
            -InstanceCount 3
    } $syntheticSnapshot $budget
    if (
        $reserve.RequiredMemoryMiB -ne 24576 -or
        $reserve.RequiredStorageGiB -ne 244 -or
        $reserve.InstanceCount -ne 3 -or
        $reserve.ReserveStatus -ne 'PASS'
    ) {
        throw 'Aggregate Welle 4 reserve calculation is invalid.'
    }

    $source = [IO.File]::ReadAllText(
        (Join-Path $RepositoryRoot 'Lab/Orchestration/Modules/DiagnosticLab/Public/Invoke-LabMultiContainerUp.ps1'),
        [Text.Encoding]::UTF8
    )
    $stateIndex = $source.IndexOf("LifecycleStatus = 'TOPOLOGY_CREATING'", [StringComparison]::Ordinal)
    $pullIndex = $source.IndexOf("@('image', 'pull', `$imageReference)", [StringComparison]::Ordinal)
    $loopIndex = $source.IndexOf('foreach ($node in $plan.Nodes)', $pullIndex, [StringComparison]::Ordinal)
    $composeIndex = $source.IndexOf('Invoke-LabWave4DockerCompose', $loopIndex, [StringComparison]::Ordinal)
    $registerIndex = $source.IndexOf('Register-LabResource', $composeIndex, [StringComparison]::Ordinal)
    $healthIndex = $source.IndexOf('Wait-LabSqlContainerHealthy', $registerIndex, [StringComparison]::Ordinal)
    if (
        -1 -in @($stateIndex, $pullIndex, $loopIndex, $composeIndex, $registerIndex, $healthIndex) -or
        -not ($stateIndex -lt $pullIndex -and
            $pullIndex -lt $loopIndex -and
            $loopIndex -lt $composeIndex -and
            $composeIndex -lt $registerIndex -and
            $registerIndex -lt $healthIndex)
    ) {
        throw 'Welle 4 state, startup, registration, and health order is invalid.'
    }
    if (
        $source.Contains("@('up', '--detach')", [StringComparison]::Ordinal) -or
        $source.Contains('ForEach-Object -Parallel', [StringComparison]::Ordinal)
    ) {
        throw 'Welle 4 starts multiple SQL nodes concurrently.'
    }

    $validatorPath = Join-Path (
        $RepositoryRoot
    ) 'Code/Tests/Static/Validate_LAB001_Wave4_MultiContainerRuntime.py'
    $python = Get-Command python3 -ErrorAction SilentlyContinue
    if ($null -eq $python) {
        $python = Get-Command python -ErrorAction Stop
    }
    & $python.Source $validatorPath --repository-root $RepositoryRoot
    if ($LASTEXITCODE -ne 0) {
        throw "Welle 4 runtime validation failed with exit code $LASTEXITCODE."
    }
}
finally {
    Remove-Module -Name DiagnosticLab -Force -ErrorAction SilentlyContinue
}

Write-Output 'LAB-001 Welle 4 multi-container runtime contracts passed.'
