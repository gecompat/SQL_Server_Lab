<#
.SYNOPSIS
    Prüft ein kataloggebundenes Container-Tool in einer verwalteten Lab-Instanz.
.DESCRIPTION
    Die Prüfung führt ausschließlich `sqlpackage /Version` im bereits laufenden,
    per Run- und Scope-Label gebundenen Container aus. Beliebige Argumente,
    Dateiübertragungen und Tool-Mutationen sind kein Teil dieses Cmdlets.
.PARAMETER RunId
    Eindeutige RunId der laufenden Labumgebung.
.PARAMETER InstanceId
    Instanz-ID innerhalb des Runs.
.PARAMETER StateRoot
    Optionaler abweichender State-Stamm.
.OUTPUTS
    PSCustomObject mit ToolId, RuntimeVersion und PASS-Status.
.EXAMPLE
    Test-SqlServerLabContainerTool -RunId $lab.RunId
#>
function Test-SqlServerLabContainerTool {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F-]{36}$')][string]$RunId,
        [string]$InstanceId = 'primary',
        [string]$StateRoot
    )
    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
    $run = Get-LabRunState -RunId $RunId -StateRoot $StateRoot
    $ownedHostPolicy = if ($run.metadata.ownedHostIntegration -or (((Test-Path (Join-Path $StateRoot 'owned-host-required')) -or (Test-Path -LiteralPath (Join-Path $StateRoot 'owned-host-policy.json'))))) { Get-LabOwnedHostRunPolicy -RunId $RunId -StateRoot $StateRoot } else { $null }
    if ([string]$run.state -ne 'RUNNING') { throw "CONTAINER_TOOL_RUN_NOT_RUNNING: $RunId / $($run.state)" }
    $target = Resolve-LabRunInstance -RunId $RunId -InstanceId $InstanceId -StateRoot $StateRoot
    if ([string]$target.Provider -notin @('docker','podman')) { throw "CONTAINER_TOOL_PROVIDER_UNSUPPORTED: $($target.Provider)" }
    $runtime = Get-LabHostToolInvocation -Name ([string]$target.Provider)
    $inspectJson = @($(if ($ownedHostPolicy) { Invoke-LabContainerRuntimeCommand -Provider ([string]$target.Provider) -StateRoot $StateRoot -RunId $RunId -Invocation $runtime -ArgumentList @('inspect', $target.ContainerName) } else { & $runtime inspect $target.ContainerName }) 2>$null) -join "`n"
    if ($LASTEXITCODE -ne 0 -or -not $inspectJson) { throw 'CONTAINER_TOOL_INSPECTION_FAILED' }
    try { $records = @($inspectJson | ConvertFrom-Json -Depth 30 -ErrorAction Stop) }
    catch { throw 'CONTAINER_TOOL_INSPECTION_FAILED' }
    if ($records.Count -ne 1) { throw 'CONTAINER_TOOL_INSPECTION_FAILED' }
    $inspect = $records[0]
    if (-not $inspect -or [string]$inspect.Config.Labels.'sql-server-lab.run-id' -ne $RunId -or
        [string]$inspect.Config.Labels.'sql-server-lab.scope-id' -ne [string]$run.scopeId -or
        [string]$inspect.Config.Labels.'sql-server-lab.instance-id' -ne $InstanceId) { throw 'CONTAINER_TOOL_OWNERSHIP_MISMATCH' }
    $containerId = [string]$inspect.Id
    if ($containerId -cnotmatch '\A[a-f0-9]{64}\z') { throw 'CONTAINER_TOOL_OWNERSHIP_MISMATCH' }
    if ([string]$inspect.State.Status -ne 'running' -or [string]$inspect.Config.Labels.'sql-server-lab.container-tool.ids' -ne 'sqlpackage') { throw 'CONTAINER_TOOL_NOT_READY' }
    $ownedContainerId = if ($ownedHostPolicy) { Resolve-LabOwnedHostContainerEffect -StateRoot $StateRoot -Provider $target.Provider -ContainerIdOrName $containerId -RunId $RunId } else { $containerId }
    $output = @($(if ($ownedHostPolicy) { Invoke-LabContainerRuntimeCommand -Provider ([string]$target.Provider) -StateRoot $StateRoot -RunId $RunId -Invocation $runtime -ArgumentList @('exec', '--user', 'mssql', $ownedContainerId, '/opt/sql-server-lab/tools/sqlpackage/sqlpackage', '/Version') } else { & $runtime exec --user mssql $containerId /opt/sql-server-lab/tools/sqlpackage/sqlpackage /Version }) 2>&1)
    if ($LASTEXITCODE -ne 0 -or (@($output) -join "`n") -notmatch '(?<version>[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)') { throw 'CONTAINER_TOOL_VERSION_PROBE_FAILED' }
    [PSCustomObject]@{ RunId=$RunId; InstanceId=$InstanceId; Provider=[string]$target.Provider; ToolId='sqlpackage'; RuntimeVersion=[string]$Matches.version; Status='PASS' }
}
