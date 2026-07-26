function Get-LabScenarioContract {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^LAB-[A-Z0-9]+-[0-9]{3}$')]
        [string] $ScenarioId
    )

    $locations = @(
        [pscustomobject] @{
            Category = 'CORE'
            Directory = Join-Path (
                $script:DiagnosticLabRoot
            ) "Scenarios/Core/$ScenarioId"
        }
        [pscustomobject] @{
            Category = 'PERFORMANCE'
            Directory = Join-Path (
                $script:DiagnosticLabRoot
            ) "Scenarios/Performance/$ScenarioId"
        }
    )
    $location = $locations |
        Where-Object {
            Test-Path `
                -LiteralPath (Join-Path $_.Directory 'scenario.json') `
                -PathType Leaf
        } |
        Select-Object -First 1
    if ($null -eq $location) {
        throw 'The requested LAB-001 scenario is not implemented.'
    }

    $definitionPath = Join-Path $location.Directory 'scenario.json'
    $definition = Get-Content `
        -LiteralPath $definitionPath `
        -Raw `
        -Encoding utf8 |
        ConvertFrom-Json -Depth 100
    $runbookPath = Join-Path $location.Directory 'runbook.json'
    $runbook = if (Test-Path -LiteralPath $runbookPath -PathType Leaf) {
        Get-Content `
            -LiteralPath $runbookPath `
            -Raw `
            -Encoding utf8 |
            ConvertFrom-Json -Depth 100
    }
    else {
        $null
    }

    return [pscustomobject] @{
        Category = $location.Category
        Directory = $location.Directory
        DefinitionPath = $definitionPath
        Definition = $definition
        RunbookPath = $runbookPath
        Runbook = $runbook
    }
}

function Copy-LabWave3RuntimeScripts {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $RunDirectory
    )

    $sourceDirectory = Join-Path (
        $script:DiagnosticLabRoot
    ) 'Scenarios/Performance/_Shared'
    $targetDirectory = Join-Path $RunDirectory 'runtime/scenarios/_shared'
    [IO.Directory]::CreateDirectory($targetDirectory) | Out-Null
    foreach ($fileName in @(
            'Setup.sql',
            'Worker.sql',
            'Observe.sql',
            'Cleanup.sql'
        )) {
        $sourcePath = Join-Path $sourceDirectory $fileName
        if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
            throw "The Welle 3 shared script is missing: $fileName"
        }
        [IO.File]::Copy(
            $sourcePath,
            (Join-Path $targetDirectory $fileName),
            $true
        )
    }
    return $targetDirectory
}

function Start-LabSqlWorker {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $DockerCommand,

        [Parameter(Mandatory)]
        [ValidatePattern('^[a-f0-9]{64}$')]
        [string] $ContainerId,

        [Parameter(Mandatory)]
        [hashtable] $SqlCmdVariables,

        [Parameter(Mandatory)]
        [ValidateRange(10, 120)]
        [int] $QueryTimeoutSeconds,

        [Parameter(Mandatory)]
        [ValidateRange(1, 8)]
        [int] $WorkerId
    )

    $workerVariables = @{}
    foreach ($name in $SqlCmdVariables.Keys) {
        $workerVariables[$name] = $SqlCmdVariables[$name]
    }
    $workerVariables.WorkerId = [string] $WorkerId

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $DockerCommand
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in (Get-LabSqlCmdDockerArguments `
            -ContainerId $ContainerId `
            -ContainerSqlPath '/lab/runtime/scenarios/_shared/Worker.sql' `
            -SqlCmdVariables $workerVariables `
            -QueryTimeoutSeconds $QueryTimeoutSeconds)) {
        $startInfo.ArgumentList.Add($argument)
    }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    if (-not $process.Start()) {
        throw 'A bounded LAB-001 SQL worker could not be started.'
    }
    $outputTask = $process.StandardOutput.ReadToEndAsync()
    $errorTask = $process.StandardError.ReadToEndAsync()
    return [pscustomobject] @{
        WorkerId = $WorkerId
        Process = $process
        OutputTask = $outputTask
        ErrorTask = $errorTask
    }
}

function Complete-LabSqlWorkers {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]] $Workers,

        [Parameter(Mandatory)]
        [int[]] $AllowedExitCodes
    )

    foreach ($worker in $Workers) {
        if (-not $worker.Process.HasExited) {
            if (-not $worker.Process.WaitForExit(10000)) {
                $worker.Process.Kill($true)
                $worker.Process.WaitForExit()
            }
        }
        $output = $worker.OutputTask.GetAwaiter().GetResult()
        $errorOutput = $worker.ErrorTask.GetAwaiter().GetResult()
        if ($worker.Process.ExitCode -notin $AllowedExitCodes) {
            throw (
                'A bounded SQL worker returned exit code ' +
                $worker.Process.ExitCode + '. ' +
                ([string] $errorOutput).Trim()
            )
        }
        $worker.Process.Dispose()
        $null = $output
    }
}

function ConvertFrom-LabScenarioOutput {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $ScenarioId,

        [Parameter(Mandatory)]
        [string[]] $CommandOutput
    )

    $prefix = 'LAB_ASSERTION_JSON='
    $line = $CommandOutput |
        Where-Object { $_.StartsWith($prefix, [StringComparison]::Ordinal) } |
        Select-Object -Last 1
    if ([string]::IsNullOrWhiteSpace($line)) {
        throw 'Scenario output did not contain its assertion envelope.'
    }
    $result = $line.Substring($prefix.Length) | ConvertFrom-Json -Depth 20
    if ($result.ScenarioId -ne $ScenarioId -or $result.Status -ne 'PASS') {
        throw 'Scenario assertion envelope is invalid.'
    }
    return $result
}

function Test-LabCleanupOutput {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $ScenarioId,

        [Parameter(Mandatory)]
        [string[]] $CommandOutput
    )

    $prefix = 'LAB_CLEANUP_JSON='
    $line = $CommandOutput |
        Where-Object { $_.StartsWith($prefix, [StringComparison]::Ordinal) } |
        Select-Object -Last 1
    if ([string]::IsNullOrWhiteSpace($line)) {
        throw 'Scenario cleanup did not contain its assertion envelope.'
    }
    $result = $line.Substring($prefix.Length) | ConvertFrom-Json -Depth 20
    if (
        $result.ScenarioId -ne $ScenarioId -or
        $result.Status -ne 'PASS' -or
        $result.ResetPolicy -ne 'EXACT_SYNTHETIC_SCOPE'
    ) {
        throw 'Scenario cleanup assertion is invalid.'
    }
}

function Write-LabScenarioResult {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $RunDirectory,

        [Parameter(Mandatory)]
        [string] $ScenarioId,

        [Parameter(Mandatory)]
        [pscustomobject] $Result,

        [Parameter(Mandatory)]
        [ValidateSet('PASS', 'NOT_REQUIRED')]
        [string] $CleanupStatus
    )

    $resultPath = Join-Path $RunDirectory "scenario-$ScenarioId.json"
    Write-LabJsonFile -Path $resultPath -InputObject ([ordered] @{
            SchemaVersion = '1.0'
            DataClassification = 'LOCAL_RUNTIME_STATE'
            ScenarioId = $Result.ScenarioId
            Status = $Result.Status
            AnalyzerStatus = $Result.AnalyzerStatus
            PrimaryAnalyzer = if (
                $null -ne $Result.PSObject.Properties['PrimaryAnalyzer']
            ) {
                $Result.PrimaryAnalyzer
            }
            else {
                ''
            }
            FindingCodes = @($Result.FindingCodes)
            ObservedValue = if (
                $null -ne $Result.PSObject.Properties['ObservedValue']
            ) {
                $Result.ObservedValue
            }
            else {
                $null
            }
            AlternativeEvidenceUsed = if (
                $null -ne $Result.PSObject.Properties[
                    'AlternativeEvidenceUsed'
                ]
            ) {
                [bool] $Result.AlternativeEvidenceUsed
            }
            else {
                $false
            }
            ProductMajorVersion = if (
                $null -ne $Result.PSObject.Properties['ProductMajorVersion']
            ) {
                $Result.ProductMajorVersion
            }
            else {
                $null
            }
            CleanupStatus = $CleanupStatus
            CompletedAtUtc = [DateTime]::UtcNow.ToString('o')
        })
    return Read-LabJsonFile -Path $resultPath
}

function New-LabFixtureScenarioResult {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Contract
    )

    $fixturePath = Join-Path $Contract.Directory 'fixture.json'
    if (-not (Test-Path -LiteralPath $fixturePath -PathType Leaf)) {
        throw 'The contract fixture file is missing.'
    }
    $fixture = Get-Content `
        -LiteralPath $fixturePath `
        -Raw `
        -Encoding utf8 |
        ConvertFrom-Json -Depth 50
    if (
        $fixture.ScenarioId -ne $Contract.Definition.ScenarioId -or
        $fixture.DataClassification -ne 'PUBLIC_FIXTURE' -or
        $fixture.RuntimeEvidenceClaim -ne 'NOT_CLAIMED' -or
        $fixture.Status -ne 'IMPLEMENTED_CONTRACT_FIXTURE' -or
        $fixture.FindingCode -ne $Contract.Runbook.FindingCode
    ) {
        throw 'The public contract fixture boundary is invalid.'
    }
    return [pscustomobject] @{
        ScenarioId = $fixture.ScenarioId
        Status = 'PASS'
        AnalyzerStatus = 'CONTRACT_FIXTURE'
        PrimaryAnalyzer = $Contract.Runbook.PrimaryAnalyzer
        FindingCodes = @($fixture.FindingCode)
        ObservedValue = 1
        AlternativeEvidenceUsed = $false
        ProductMajorVersion = $null
    }
}
