$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("sql-lab-resource-test-" + [guid]::NewGuid().ToString('N'))
$runId = 'resource-test-run'
$runDirectory = Join-Path (Join-Path $testRoot 'runs') $runId
New-Item -Path $runDirectory -ItemType Directory -Force | Out-Null

$script:run = [pscustomobject]@{
    runId = $runId
    scopeId = 'resource-test-scope'
    updatedAt = 'initial'
    metadata = [pscustomobject]@{ name = 'Resource Test'; workflowKind = 'hyperv-lab' }
}
$script:vm = [pscustomobject]@{
    Name = 'resource-test-vm'
    State = 'Off'
    MemoryStartup = [long](4GB)
    ProcessorCount = 4
}
$connection = [pscustomobject]@{
    instances = @([pscustomobject]@{ id='vm'; provider='hyperv'; vmName='resource-test-vm' })
}
$connection | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $runDirectory 'connection-info.json') -Encoding utf8

function Get-LabStateRoot { $testRoot }
function Get-LabRunState { param($RunId, $StateRoot) $script:run }
function Get-HyperVManagedVM { param($VMName, $ExpectedRunId, $ExpectedScopeId) [pscustomobject]@{ VM=$script:vm } }
function Get-LabTimestamp { [datetime]::UtcNow.ToString('o') }
function Write-LabArtifactJsonAtomic { param($Path, $InputObject) $InputObject | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $Path -Encoding utf8 }
function Set-VMProcessor { param($VM, $Count, $ErrorAction) $VM.ProcessorCount = $Count }
function Set-VMMemory { param($VM, $DynamicMemoryEnabled, $MinimumBytes, $StartupBytes, $MaximumBytes, $ErrorAction) $VM.MemoryStartup = $StartupBytes }

try {
    . (Join-Path $repoRoot 'Private/EnvironmentResources.ps1')
    $before = Get-LabEnvironmentResources -RunId $runId -StateRoot $testRoot
    if ($before.Instances.Count -ne 1 -or $before.Instances[0].MemoryStartupMB -ne 4096 -or $before.Instances[0].ProcessorCount -ne 4) {
        throw 'Get-LabEnvironmentResources liefert nicht die erwarteten Hyper-V-Werte.'
    }
    $changed = Set-LabEnvironmentResources -RunId $runId -MemoryMB 6144 -ProcessorCount 6 -StateRoot $testRoot
    if (-not $changed.Changed -or $changed.NoChange -or $script:vm.MemoryStartup -ne 6GB -or $script:vm.ProcessorCount -ne 6) {
        throw 'Set-LabEnvironmentResources wendet die Hyper-V-Werte nicht korrekt an.'
    }
    $unchanged = Set-LabEnvironmentResources -RunId $runId -MemoryMB 6144 -ProcessorCount 6 -StateRoot $testRoot
    if ($unchanged.Changed -or -not $unchanged.NoChange) { throw 'Identische Ressourcenwerte muessen NoChange liefern.' }

    $entrySource = Get-Content -LiteralPath (Join-Path $repoRoot 'Public/Invoke-SqlServerLab.ps1') -Raw
    $resourceAction = [regex]::Match($entrySource, 'function Set-LabResourcesInteractive \{[\s\S]+?(?=\r?\nfunction Manage-LabEnvironmentInteractive)')
    if (-not $resourceAction.Success -or $resourceAction.Value -notmatch 'catch \{[\s\S]+?Write-LabError[\s\S]+?Wait-LabConsoleAcknowledgement') {
        throw 'Interaktive Ressourcenfehler warten nicht auf eine Rueckkehrbestaetigung.'
    }
    Write-Host 'Environment resource checks: 4 PASS, 0 FAIL' -ForegroundColor Green
}
finally {
    $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
    $resolvedTempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if ($resolvedTestRoot.StartsWith($resolvedTempRoot, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
