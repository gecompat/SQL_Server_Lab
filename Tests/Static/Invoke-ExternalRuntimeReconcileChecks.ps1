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
$lifecyclePath = Join-Path $repoRoot 'Private\ExternalRuntimeLifecycle.ps1'
$reconcileSource = Get-Content -LiteralPath (Join-Path $repoRoot 'Private\ExternalRuntimeReconcile.ps1') -Raw -Encoding utf8
$newLabSource = Get-Content -LiteralPath (Join-Path $repoRoot 'Public\New-SqlServerLab.ps1') -Raw -Encoding utf8
$dockerSource = Get-Content -LiteralPath (Join-Path $repoRoot 'Providers\Docker\DockerProvider.ps1') -Raw -Encoding utf8
$podmanSource = Get-Content -LiteralPath (Join-Path $repoRoot 'Providers\Podman\PodmanProvider.ps1') -Raw -Encoding utf8
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
$lifecycleSource = Get-Content -LiteralPath $lifecyclePath -Raw -Encoding utf8
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

$replacementBinding = & $module {
    $instance = [PSCustomObject]@{
        id='external-runtime'; drives=@(
            [PSCustomObject]@{ id='runtime-mssql'; containerPath='/var/opt/mssql'; persistence='run-scoped-runtime-volume' },
            [PSCustomObject]@{ id='data'; containerPath='/sqldata'; persistence='run-scoped-runtime-volume' },
            [PSCustomObject]@{ id='scripts'; containerPath='/scripts'; hostPath='/host/scripts'; readOnly=$true }
        )
    }
    New-LabExternalRuntimeReplacementInstance -ResolvedInstance $instance -ContainerInspect ([PSCustomObject]@{
        Mounts=@(
            [PSCustomObject]@{ Type='volume'; Name='stable-system-volume'; Destination='/var/opt/mssql' },
            [PSCustomObject]@{ Type='volume'; Name='stable-extensibility-volume'; Destination='/var/opt/mssql-extensibility' },
            [PSCustomObject]@{ Type='volume'; Name='stable-external-languages-volume'; Destination='/var/opt/mssql-extensibility/externallanguages' },
            [PSCustomObject]@{ Type='volume'; Name='stable-external-libraries-volume'; Destination='/var/opt/mssql-extensibility/externallibraries' },
            [PSCustomObject]@{ Type='volume'; Name='stable-data-volume'; Destination='/sqldata' },
            [PSCustomObject]@{ Type='bind'; Source='/host/scripts'; Destination='/scripts'; RW=$false },
            [PSCustomObject]@{ Type='bind'; Source='/host/backups'; Destination='/var/opt/mssql/backup'; RW=$true },
            [PSCustomObject]@{ Type='bind'; Source='/sys/fs/cgroup'; Destination='/sys/fs/cgroup'; RW=$true }
        )
    })
}
Add-CheckResult -Name 'Refresh bindet bestehende SQL-Volumes statt neue Namen abzuleiten' -Success (
    @($replacementBinding.drives | Where-Object id -eq 'runtime-mssql')[0].volumeName -eq 'stable-system-volume' -and
    @($replacementBinding.drives | Where-Object containerPath -eq '/var/opt/mssql-extensibility').Count -eq 0 -and
    @($replacementBinding.drives | Where-Object containerPath -eq '/var/opt/mssql-extensibility/externallanguages')[0].volumeName -eq 'stable-external-languages-volume' -and
    @($replacementBinding.drives | Where-Object containerPath -eq '/var/opt/mssql-extensibility/externallibraries')[0].volumeName -eq 'stable-external-libraries-volume' -and
    @($replacementBinding.drives | Where-Object id -eq 'data')[0].volumeName -eq 'stable-data-volume' -and
    @($replacementBinding.drives | Where-Object id -eq 'scripts')[0].hostPath -eq '/host/scripts' -and
    @($replacementBinding.drives | Where-Object containerPath -eq '/var/opt/mssql/backup')[0].hostPath -eq '/host/backups' -and
    @($replacementBinding.drives | Where-Object containerPath -eq '/sys/fs/cgroup').Count -eq 0 -and
    $source -match '-ContainerName \$name'
)
Add-CheckResult -Name 'External-Runtime-Reconcile akzeptiert alle drei aktiven SQL-Versionen für Docker und Podman' -Success (
    $reconcileSource -match "Version -notin @\('2019', '2022', '2025'\)" -and
    $reconcileSource -match "Provider -notin @\('docker', 'podman'\)"
)
Add-CheckResult -Name 'Atomarer Ersatz ignoriert ausschließlich den exakt benannten gestoppten Rollback-Container' -Success (
    $reconcileSource -match '-EndpointBindingIgnoreContainerName \$backupName' -and
    $newLabSource -match '-EndpointBindingIgnoreContainerName \$EndpointBindingIgnoreContainerName' -and
    $dockerSource -match 'StartsWith\("docker:\$EndpointBindingIgnoreContainerName \("' -and
    $podmanSource -match 'StartsWith\("podman:\$EndpointBindingIgnoreContainerName \("'
)

$initialInstallBinding = & $module {
    $instance = [PSCustomObject]@{
        id='external-runtime'; drives=@(
            [PSCustomObject]@{ id='runtime-mssql'; containerPath='/var/opt/mssql'; persistence='run-scoped-runtime-volume' }
        )
    }
    New-LabExternalRuntimeReplacementInstance -ResolvedInstance $instance -AllowNewExternalRuntimeVolumes `
        -ContainerInspect ([PSCustomObject]@{
            Mounts=@([PSCustomObject]@{ Type='volume'; Name='stable-system-volume'; Destination='/var/opt/mssql' })
        })
}
Add-CheckResult -Name 'Erstinstallation ergänzt neue External-Runtime-Volumes und bindet das vorhandene SQL-Systemvolume' -Success (
    @($initialInstallBinding.drives | Where-Object containerPath -eq '/var/opt/mssql')[0].volumeName -eq 'stable-system-volume' -and
    @($initialInstallBinding.drives | Where-Object containerPath -eq '/var/opt/mssql-extensibility/externallanguages').Count -eq 1 -and
    @($initialInstallBinding.drives | Where-Object containerPath -eq '/var/opt/mssql-extensibility/externallibraries').Count -eq 1
)

$persistentInstallBinding = & $module {
    $instance = [PSCustomObject]@{ id='external-runtime'; drives=@() }
    New-LabExternalRuntimeReplacementInstance -ResolvedInstance $instance -AllowNewExternalRuntimeVolumes -PersistentData `
        -ContainerInspect ([PSCustomObject]@{
            Mounts=@([PSCustomObject]@{ Type='volume'; Name='stable-persistent-system'; Destination='/var/opt/mssql' })
        })
}
Add-CheckResult -Name 'Erstinstallation in persistentem Lab verwendet langlebige Data-Root-Volume-Namen' -Success (
    @($persistentInstallBinding.drives | Where-Object containerPath -eq '/var/opt/mssql-extensibility/externallanguages')[0].volumeName -eq 'stable-persistent-system-external-languages' -and
    @($persistentInstallBinding.drives | Where-Object containerPath -eq '/var/opt/mssql-extensibility/externallibraries')[0].volumeName -eq 'stable-persistent-system-external-libraries' -and
    @($persistentInstallBinding.drives | Where-Object { [string]$_.containerPath -like '*/external*' -and [string]$_.persistence -ne 'data-root-runtime-volume' }).Count -eq 0
)

$javaCleanupPlan = & $module {
    $context = [PSCustomObject]@{
        RemovedIds=@('sql-java')
        CurrentPlans=@([PSCustomObject]@{
            SoftwareId='sql-java'; PlanKey=('b' * 64)
            VariantId='sql2022-java11-ubuntu2204-derived'; RuntimeVersion='11'
        })
        ConnectionInstance=[PSCustomObject]@{ id='external-runtime' }
    }
    $receipts = [PSCustomObject]@{ instances=@([PSCustomObject]@{
        instanceId='external-runtime'; receipts=@([PSCustomObject]@{
            SoftwareId='sql-java'; PlanKey=('b' * 64); Postconditions=@([PSCustomObject]@{
                Language='Java'; Database='app'; ManagedObjects=[PSCustomObject]@{
                    CreatedLanguage=$true; CreatedSdk=$true; CreatedProbe=$false
                }
            })
        })
    }) }
    Get-LabExternalRuntimeJavaCleanupPlan -Context $context -PreviousReceipts $receipts
}
Add-CheckResult -Name 'Java-Removal bindet nur receiptbelegte Lab-Objekte und Datenbanken' -Success (
    $javaCleanupPlan.Software.SoftwareId -eq 'sql-java' -and
    @($javaCleanupPlan.Records).Count -eq 1 -and $javaCleanupPlan.Records[0].Database -eq 'app' -and
    $javaCleanupPlan.Records[0].Registration.CreatedLanguage -and
    $javaCleanupPlan.Records[0].Registration.CreatedSdk -and
    -not $javaCleanupPlan.Records[0].Registration.CreatedProbe -and
    $source -match "-Status 'JAVA_CLEANUP_PREPARED'" -and
    $source -match 'Restore-LabExternalRuntimeManagedJavaObjects'
)

$retryContract = & $module {
    $retryState = [PSCustomObject]@{ Attempts=0; Recoveries=0; NonTransientAttempts=0 }
    $result = Invoke-LabExternalRuntimeProbeWithRetry -RetryDelaySeconds 0 -RecoveryOperation {
        $retryState.Recoveries++
    } -Operation {
        $retryState.Attempts++
        if ($retryState.Attempts -eq 1) { throw "Msg 39011`nSQL Server was unable to communicate with the LaunchPad service" }
        [PSCustomObject]@{ Status='PASS' }
    }
    $nonTransientRejected = $false
    try {
        $null = Invoke-LabExternalRuntimeProbeWithRetry -RetryDelaySeconds 0 -Operation {
            $retryState.NonTransientAttempts++
            throw 'SQL semantic failure'
        }
    }
    catch { $nonTransientRejected = $_.Exception.Message -eq 'SQL semantic failure' }
    [PSCustomObject]@{
        Attempts=$retryState.Attempts; Recoveries=$retryState.Recoveries; Status=[string]$result.Status
        NonTransientAttempts=$retryState.NonTransientAttempts; NonTransientRejected=$nonTransientRejected
    }
}
Add-CheckResult -Name 'Probe-Retry ist auf transiente LaunchPad-39011/39012-Fehler begrenzt' -Success (
    $retryContract.Attempts -eq 2 -and $retryContract.Recoveries -eq 1 -and $retryContract.Status -eq 'PASS' -and
    $retryContract.NonTransientAttempts -eq 1 -and $retryContract.NonTransientRejected -and
    $lifecycleSource -match '(?s)\$recoverProbeReadiness = \{.*?Restart-LabExternalRuntimeContainer.*?Wait-SqlReady'
)

$hostnameContract = & $module {
    [PSCustomObject]@{
        Stable=(Get-LabContainerRuntimeHostname -RuntimeName 'lab-run-external-runtime-deadbeef')
        Sanitized=(Get-LabContainerRuntimeHostname -RuntimeName 'lab_run.external-runtime-deadbeef')
        Long=(Get-LabContainerRuntimeHostname -RuntimeName (('a' * 80) + '-deadbeef'))
    }
}
$dockerProviderSource = Get-Content -LiteralPath (Join-Path $repoRoot 'Providers\Docker\DockerProvider.ps1') -Raw -Encoding utf8
$podmanProviderSource = Get-Content -LiteralPath (Join-Path $repoRoot 'Providers\Podman\PodmanProvider.ps1') -Raw -Encoding utf8
Add-CheckResult -Name 'Docker und Podman binden einen stabilen Linux-Hostname ueber Recreate' -Success (
    $hostnameContract.Stable -eq 'lab-run-external-runtime-deadbeef' -and
    $hostnameContract.Sanitized -match '^[a-z0-9-]+-[a-f0-9]{8}$' -and
    $hostnameContract.Long.Length -le 63 -and
    $dockerProviderSource.Contains("'--hostname', `$containerHostname") -and
    $podmanProviderSource.Contains("'--hostname', `$containerHostname")
)

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("sql-lab-runtime-reconcile-" + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    $currentManifestPath = Join-Path $tempRoot 'current.json'
    $desiredManifestPath = Join-Path $tempRoot 'desired.json'
    $driftManifestPath = Join-Path $tempRoot 'drift.json'
    $removalManifestPath = Join-Path $tempRoot 'removal.json'
    $lastRemovalManifestPath = Join-Path $tempRoot 'last-removal.json'
    $plainManifestPath = Join-Path $tempRoot 'plain.json'
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
    $lastRemovalInstance = $baseInstance | ConvertTo-Json -Depth 20 | ConvertFrom-Json -AsHashtable
    $lastRemovalInstance.software = @()
    $lastRemovalInstance.serverConfig.externalScripts.enabled = $false
    [ordered]@{ name='runtime-reconcile'; instances=@($lastRemovalInstance) } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $lastRemovalManifestPath -Encoding utf8
    $plainInstance = $baseInstance | ConvertTo-Json -Depth 20 | ConvertFrom-Json -AsHashtable
    $plainInstance.software = @()
    $plainInstance.serverConfig.externalScripts.enabled = $false
    [ordered]@{ name='runtime-reconcile'; instances=@($plainInstance) } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $plainManifestPath -Encoding utf8

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
    $plainFixture = & $module {
        param($Root,$ManifestPath)
        $resolved = Read-LabManifest -Path $ManifestPath
        $snapshot = New-LabDesiredStateSnapshot -ResolvedLab $resolved -ProvisioningMode manifest -PersistentData $false
        $run = New-LabRunState -StateRoot $Root -Metadata @{ name='runtime-reconcile'; desiredState=$snapshot } -ProviderSubRuns @(
            [PSCustomObject]@{ provider='docker'; instanceIds=@('external-runtime') }
        )
        $runRecord = Get-LabRunState -RunId $run.RunId -StateRoot $Root
        $runRecord.state = 'RUNNING'
        Write-LabArtifactJsonAtomic -Path (Join-Path $run.RunDir 'run-state.json') -InputObject $runRecord
        $providerSubRuns = @([PSCustomObject]@{ id='provider-docker'; provider='docker'; instanceIds=@('external-runtime') })
        $null = New-CleanupPlan -RunDir $run.RunDir -RunId $run.RunId -ScopeId $run.ScopeId -ProviderSubRuns $providerSubRuns
        $null = Add-CleanupStep -RunDir $run.RunDir -ResourceType container `
            -ResourceId 'runtime-reconcile-external-runtime' -Action remove -Provider docker `
            -ProviderSubRunId provider-docker
        Write-LabArtifactJsonAtomic -Path (Join-Path $run.RunDir 'connection-info.json') -InputObject ([PSCustomObject]@{
            runId=$run.RunId; scopeId=$run.ScopeId; instances=@([PSCustomObject]@{
                id='external-runtime'; provider='docker'; version='2022'; host='secret-host.invalid'; port=14332
                containerId='secret-plain-container'; containerName='runtime-reconcile-external-runtime'; databases=@('app')
            })
        })
        [PSCustomObject]@{ RunId=$run.RunId; RunDirectory=$run.RunDir; StateRoot=$Root }
    } $tempRoot $plainManifestPath
    $installPlan = Get-SqlServerLabReconcilePlan -RunId $plainFixture.RunId -ManifestPath $desiredManifestPath `
        -InstanceId external-runtime -StateRoot $plainFixture.StateRoot
    Add-CheckResult -Name 'SQL-2022-Container ohne bestehende Runtime erhält einen Erstinstallationsplan' -Success (
        @($installPlan.Actions).Count -eq 1 -and
        $installPlan.Actions[0].Operation -eq 'InstallExternalRuntime' -and
        @($installPlan.Actual.PlanKeys).Count -eq 0 -and
        $null -eq $installPlan.Actual.ImageKey -and
        @($installPlan.Desired.Software).Count -eq 2
    )
    $cleanupBinding = & $module {
        param($RunDirectory)
        $replacement = [PSCustomObject]@{ drives=@(
            [PSCustomObject]@{ id='runtime-mssql-external-languages'; containerPath='/var/opt/mssql-extensibility/externallanguages' },
            [PSCustomObject]@{ id='runtime-mssql-external-libraries'; containerPath='/var/opt/mssql-extensibility/externallibraries' }
        ) }
        $software = @([PSCustomObject]@{ SoftwareId='sql-python'; PlanKey=('c' * 64) })
        Add-LabExternalRuntimeCleanupVolumes -RunDirectory $RunDirectory -Provider docker `
            -ContainerName 'runtime-reconcile-external-runtime' -ReplacementInstance $replacement -SoftwarePlans $software
        Add-LabExternalRuntimeCleanupVolumes -RunDirectory $RunDirectory -Provider docker `
            -ContainerName 'runtime-reconcile-external-runtime' -ReplacementInstance $replacement -SoftwarePlans $software
        Get-Content -LiteralPath (Join-Path $RunDirectory 'cleanup-plan.json') -Raw -Encoding utf8 | ConvertFrom-Json -Depth 50
    } $plainFixture.RunDirectory
    $cleanupContainerStep = @($cleanupBinding.steps | Where-Object resourceType -eq 'container')[0]
    $cleanupVolumeSteps = @($cleanupBinding.steps | Where-Object resourceType -eq 'volume')
    Add-CheckResult -Name 'Erstinstallation registriert neue Volumes einmalig und vor dem Container-Cleanup' -Success (
        $cleanupVolumeSteps.Count -eq 2 -and
        @($cleanupVolumeSteps | Where-Object { [int]$_.order -ge [int]$cleanupContainerStep.order }).Count -eq 0 -and
        @($cleanupVolumeSteps | Where-Object { [string]$_.softwareContract.softwareIds -match 'sql-python' }).Count -eq 2
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
    $removalPlan = Get-SqlServerLabReconcilePlan -RunId $fixture.RunId -ManifestPath $removalManifestPath -InstanceId external-runtime -StateRoot $fixture.StateRoot
    Add-CheckResult -Name 'Einzelne Runtime-Entfernung wird als sanitisiertes Recreate geplant' -Success (
        @($removalPlan.Diff | Where-Object { $_.SoftwareId -eq 'sql-python' -and $_.ChangeClassification.Intent -eq 'remove' }).Count -eq 1 -and
        @($removalPlan.Diff | Where-Object SoftwareId -eq 'sql-r').Count -eq 1 -and
        $removalPlan.HighestChangeClass -eq 'recreate'
    )
    $lastRemovalRejected = $false
    try { $null = Get-SqlServerLabReconcilePlan -RunId $fixture.RunId -ManifestPath $lastRemovalManifestPath -InstanceId external-runtime -StateRoot $fixture.StateRoot }
    catch { $lastRemovalRejected = $_.Exception.Message -match 'LAST_RUNTIME_REMOVAL_UNSUPPORTED' }
    Add-CheckResult -Name 'Entfernung der letzten Runtime bleibt bis zum Basisimage-Rueckweg fail-closed' -Success $lastRemovalRejected
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
