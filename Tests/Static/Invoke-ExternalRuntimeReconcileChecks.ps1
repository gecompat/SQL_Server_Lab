#Requires -Version 7.2
<#
.SYNOPSIS
    Prueft den fail-closed External-Runtime-Reconcile- und Refreshvertrag.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$modulePath = Join-Path $repoRoot 'SqlServerLab.psd1'
$implementationPath = Join-Path $repoRoot 'Private\ExternalRuntimeReconcile.ps1'
$failures = [System.Collections.Generic.List[string]]::new()
$passed = 0
. (Join-Path $PSScriptRoot '..' 'Common' 'CheckResult.ps1')

Write-Host ''
Write-Host 'SQL_Server_Lab - External Runtime Reconcile Checks' -ForegroundColor Cyan
Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
Import-Module $modulePath -Force -ErrorAction Stop
$module = Get-Module SqlServerLab

$getCommand = Get-Command Get-SqlServerLabReconcilePlan -Module SqlServerLab
$invokeCommand = Get-Command Invoke-SqlServerLabReconcileAction -Module SqlServerLab
Add-CheckResult -Name 'Public Reconcile APIs besitzen getrennten ExternalRuntime-Parametersatz' -Success (
    @($getCommand.ParameterSets | Where-Object Name -eq 'ExternalRuntime').Count -eq 1 -and
    @($invokeCommand.ParameterSets | Where-Object Name -eq 'ExternalRuntime').Count -eq 1 -and
    $getCommand.Parameters.ContainsKey('ManifestPath') -and $invokeCommand.Parameters.ContainsKey('ReadinessTimeoutSeconds')
)

$source = Get-Content -LiteralPath $implementationPath -Raw -Encoding utf8
$buildIndex = $source.IndexOf('Invoke-LabExternalRuntimeContainerImageBuild -ImagePlan')
$journalIndex = $source.IndexOf("status='PREPARED'")
$renameIndex = $source.IndexOf('& $provider rename $name $backupName')
$verifyIndex = $source.IndexOf('Initialize-LabExternalRuntimes -SoftwarePlans')
$stateCommitIndex = $source.IndexOf("-Status 'STATE_COMMITTED'")
$removeOldIndex = $source.LastIndexOf('Remove-LabContainerForCleanup -Provider $provider -ContainerIdOrName $backupName')
Add-CheckResult -Name 'Refresh-Reihenfolge ist Build, Journal, Ersatz, SQL-Validierung, State-Commit, Alt-Cleanup' -Success (
    $buildIndex -ge 0 -and $buildIndex -lt $journalIndex -and $journalIndex -lt $renameIndex -and
    $renameIndex -lt $verifyIndex -and $verifyIndex -lt $stateCommitIndex -and $stateCommitIndex -lt $removeOldIndex
)
Add-CheckResult -Name 'Refresh verwendet Scope-Pruefung, atomaren State und resolvergebundene Providererstellung' -Success (
    $source -match 'sql-server-lab\.scope-id' -and $source -match 'Write-LabArtifactJsonAtomic' -and
    $source -match 'New-LabProviderContainer' -and $source -match 'New-LabExternalRuntimeContainerImagePlan'
)
Add-CheckResult -Name 'Journal unterscheidet Rollback vor und Finalisierung nach State-Commit' -Success (
    $source -match "status -eq 'PREPARED'" -and $source -match "status -eq 'STATE_COMMITTED'" -and
    $source -match "-Status 'ROLLED_BACK'" -and $source -match "-Status 'COMPLETED'"
)
Add-CheckResult -Name 'Rollback kompensiert neue Java-DDL vor der Providerwiederherstellung' -Success (
    $source -match 'CompensationRecords' -and $source -match 'Undo-LabJavaExternalRuntimeDatabaseObjects' -and
    $source.IndexOf('Undo-LabJavaExternalRuntimeDatabaseObjects') -lt $source.LastIndexOf('Repair-LabExternalRuntimeRefreshJournal -Context')
)

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("sql-lab-runtime-reconcile-" + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    $currentManifestPath = Join-Path $tempRoot 'current.json'
    $desiredManifestPath = Join-Path $tempRoot 'desired.json'
    $driftManifestPath = Join-Path $tempRoot 'drift.json'
    $removalManifestPath = Join-Path $tempRoot 'removal.json'
    $baseInstance = [ordered]@{
        id='external-runtime'; version='2022'; provider='docker'; os='linux'; profile='standard'; autostart='off'
        databases=@([ordered]@{ name='app' })
        software=@([ordered]@{ id='sql-python'; scope='sqlExternalRuntime' })
        serverConfig=[ordered]@{ externalScripts=[ordered]@{ enabled=$true; resourceGovernor=[ordered]@{ maxMemoryPercent=40; maxProcesses=32 } } }
    }
    [ordered]@{ name='runtime-reconcile'; instances=@($baseInstance) } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $currentManifestPath -Encoding utf8
    $desiredInstance = $baseInstance | ConvertTo-Json -Depth 20 | ConvertFrom-Json -AsHashtable
    $desiredInstance.software = @(
        [ordered]@{ id='sql-python'; scope='sqlExternalRuntime' },
        [ordered]@{ id='sql-r'; scope='sqlExternalRuntime' }
    )
    [ordered]@{ name='runtime-reconcile'; instances=@($desiredInstance) } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $desiredManifestPath -Encoding utf8
    $driftInstance = $desiredInstance | ConvertTo-Json -Depth 20 | ConvertFrom-Json -AsHashtable; $driftInstance.profile = 'performance'
    [ordered]@{ name='runtime-reconcile'; instances=@($driftInstance) } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $driftManifestPath -Encoding utf8
    $removalInstance = $baseInstance | ConvertTo-Json -Depth 20 | ConvertFrom-Json -AsHashtable; $removalInstance.software = @([ordered]@{ id='sql-r'; scope='sqlExternalRuntime' })
    [ordered]@{ name='runtime-reconcile'; instances=@($removalInstance) } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $removalManifestPath -Encoding utf8

    $fixture = & $module {
        param($Root,$ManifestPath)
        $resolved = Read-LabManifest -Path $ManifestPath
        $snapshot = New-LabDesiredStateSnapshot -ResolvedLab $resolved -ProvisioningMode manifest -PersistentData $false
        $run = New-LabRunState -StateRoot $Root -Metadata @{ name='runtime-reconcile'; desiredState=$snapshot } -ProviderSubRuns @(
            [PSCustomObject]@{ provider='docker'; instanceIds=@('external-runtime') }
        )
        $runRecord = Get-LabRunState -RunId $run.RunId -StateRoot $Root
        $runRecord.state = 'RUNNING'
        Write-LabArtifactJsonAtomic -Path (Join-Path $run.RunDir 'run-state.json') -InputObject $runRecord
        $plan = @(Resolve-LabExternalRuntimePlansForInstance -Instance $resolved.instances[0])[0]
        $connection = [PSCustomObject]@{
            runId=$run.RunId; scopeId=$run.ScopeId; instances=@([PSCustomObject]@{
                id='external-runtime'; provider='docker'; version='2022'; host='secret-host.invalid'; port=14331
                containerId='secret-container-id'; containerName='runtime-reconcile-external-runtime'; databases=@('app')
                externalRuntime=[PSCustomObject]@{
                    ImageKey=('a' * 64); SoftwarePlanKeys=@($plan.PlanKey); Status='EXTENSIONS_READY_RUN'
                    Receipts=@([PSCustomObject]@{ SoftwareId=$plan.SoftwareId; PlanKey=$plan.PlanKey; VariantId=$plan.VariantId; RuntimeVersion=$plan.RuntimeVersion; Status='EXTENSIONS_READY_RUN' })
                }
            })
        }
        $connectionPath = Join-Path $run.RunDir 'connection-info.json'
        Write-LabArtifactJsonAtomic -Path $connectionPath -InputObject $connection
        [PSCustomObject]@{
            RunId=$run.RunId; StateRoot=$Root; StatePath=(Join-Path $run.RunDir 'run-state.json'); ConnectionPath=$connectionPath
            StateBefore=(Get-Content -LiteralPath (Join-Path $run.RunDir 'run-state.json') -Raw -Encoding utf8)
            ConnectionBefore=(Get-Content -LiteralPath $connectionPath -Raw -Encoding utf8)
        }
    } $tempRoot $currentManifestPath

    $plan = Get-SqlServerLabReconcilePlan -RunId $fixture.RunId -ManifestPath $desiredManifestPath -InstanceId external-runtime -StateRoot $fixture.StateRoot
    Add-CheckResult -Name 'Additiver Resolverplan erzeugt sanitisierten Recreate-Plan' -Success (
        $plan.Contract.Version -eq '1.1' -and $plan.PlanKind -eq 'ExternalRuntime' -and $plan.HighestChangeClass -eq 'recreate' -and
        @($plan.Actions).Count -eq 1 -and $plan.Actions[0].Operation -eq 'RefreshExternalRuntime' -and @($plan.Desired.Software).Count -eq 2
    )
    $serialized = $plan | ConvertTo-Json -Depth 30
    Add-CheckResult -Name 'External-Runtime-Plan leakt keine Host-, Port-, Runtime-ID- oder Manifestpfade' -Success (
        $serialized -notmatch 'secret-host|secret-container|14331|current\.json|desired\.json|connectionString'
    )
    $whatIf = Invoke-SqlServerLabReconcileAction -RunId $fixture.RunId -ManifestPath $desiredManifestPath -InstanceId external-runtime -StateRoot $fixture.StateRoot -WhatIf
    Add-CheckResult -Name 'WhatIf plant Refresh ohne State- oder Provider-Mutation' -Success (
        $whatIf.ExecutionSummary.Status -eq 'WOULD_EXECUTE' -and -not $whatIf.MutationAllowed -and
        (Get-Content -LiteralPath $fixture.StatePath -Raw -Encoding utf8) -eq $fixture.StateBefore -and
        (Get-Content -LiteralPath $fixture.ConnectionPath -Raw -Encoding utf8) -eq $fixture.ConnectionBefore
    )
    $driftRejected = $false
    try { $null = Get-SqlServerLabReconcilePlan -RunId $fixture.RunId -ManifestPath $driftManifestPath -InstanceId external-runtime -StateRoot $fixture.StateRoot }
    catch { $driftRejected = $_.Exception.Message -match 'NON_SOFTWARE_DRIFT' }
    Add-CheckResult -Name 'Nicht-Software-Drift wird vor jeder Mutation abgelehnt' -Success $driftRejected
    $removalRejected = $false
    try { $null = Get-SqlServerLabReconcilePlan -RunId $fixture.RunId -ManifestPath $removalManifestPath -InstanceId external-runtime -StateRoot $fixture.StateRoot }
    catch { $removalRejected = $_.Exception.Message -match 'REMOVAL_UNSUPPORTED' }
    Add-CheckResult -Name 'Runtime-Entfernung bleibt ohne DDL-Cleanup-Vertrag fail-closed' -Success $removalRejected
}
finally {
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}

if ($failures.Count -gt 0) {
    Write-Host "`nErgebnis: $passed PASS, $($failures.Count) FAIL" -ForegroundColor Red
    foreach ($failure in $failures) { Write-Host "  - $failure" -ForegroundColor Red }
    exit 1
}
Write-Host "`nErgebnis: $passed PASS, 0 FAIL" -ForegroundColor Green
exit 0
