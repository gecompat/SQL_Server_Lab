#Requires -Version 7.2
<#
.SYNOPSIS
    Prueft den read-only Reconcile-Vertrag ohne Provider- oder Run-Mutation.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$modulePath = Join-Path $repoRoot 'SqlServerLab.psd1'
$reconcilePath = Join-Path $repoRoot 'Private\ReconcileContract.ps1'
$failures = [System.Collections.Generic.List[string]]::new()
$passed = 0
. (Join-Path $PSScriptRoot '..' 'Common' 'CheckResult.ps1')

Write-Host ''
Write-Host 'SQL_Server_Lab - Reconcile Contract Checks' -ForegroundColor Cyan
Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
Import-Module $modulePath -Force -ErrorAction Stop

Add-CheckResult `
    -Name 'Export verfuegbar: Get-SqlServerLabReconcilePlan' `
    -Success ([bool](Get-Command Get-SqlServerLabReconcilePlan -Module SqlServerLab -ErrorAction SilentlyContinue))

$source = Get-Content -LiteralPath $reconcilePath -Raw -Encoding utf8
$forbiddenPlannerMutations = @('Sync-LabRunRuntimeState', 'Set-LabRunState', 'Set-LabProviderSubRunState', 'Set-Content', 'Write-LabArtifactJsonAtomic')
$forbiddenPresent = @($forbiddenPlannerMutations | Where-Object { $source -match [regex]::Escape($_) })
    Add-CheckResult `
        -Name 'Reconcile-Plan bleibt ohne State- oder Runtime-Mutation' `
        -Success ($forbiddenPresent.Count -eq 0) `
        -Message ($forbiddenPresent -join ', ')

    $module = Get-Module SqlServerLab
    $desiredSnapshot = & $module {
        param()
        $snapshotInput = [PSCustomObject]@{
            name = 'snapshot-check'
            instances = @(
                [PSCustomObject]@{
                    id = 'primary'
                    provider = 'docker'
                    version = '2019'
                    profile = 'standard'
                    databases = @([PSCustomObject]@{ name = 'db1' }, [PSCustomObject]@{ name = 'db2' })
                    automation = [PSCustomObject]@{ EnvironmentVariable = 'DO_NOT_PERSIST' }
                    persistentStorage = [PSCustomObject]@{
                        mode = 'data-root-runtime-volume'
                        root = 'C:\host\should-not-persist'
                        backupHostPath = 'D:\should-not-persist'
                    }
                    drives = @(
                        [PSCustomObject]@{ id = 'data'; containerPath = '/var/opt/mssql' ; hostPath = 'C:\host\should-not-persist' }
                    )
                }
            )
        }

        $snapshot = New-LabDesiredStateSnapshot -ResolvedLab $snapshotInput -ProvisioningMode 'manifest' -PersistentData $true
        $topUnknown = @($snapshot.PSObject.Properties.Name | Where-Object { $_ -notin @('Contract', 'ProvisioningMode', 'LabName', 'PersistentData', 'Instances') })
        $instanceUnknown = @(
            $snapshot.Instances | ForEach-Object {
                @($_.PSObject.Properties.Name | Where-Object { $_ -notin @('Id', 'Provider', 'Version', 'Profile', 'AutoStart', 'DatabaseNames', 'Intents') })
            }
        ) | ForEach-Object { $_ }
        [PSCustomObject]@{
            Snapshot = $snapshot
            TopUnknown = $topUnknown
            InstanceUnknown = @($instanceUnknown | Where-Object { $_ })
            Serialized = $snapshot | ConvertTo-Json -Depth 10
        }
    }

    Add-CheckResult `
        -Name 'DesiredState-Snapshot enthält nur erlaubte Felder' `
        -Success ($desiredSnapshot.TopUnknown.Count -eq 0 -and $desiredSnapshot.InstanceUnknown.Count -eq 0)
        Add-CheckResult `
        -Name 'DesiredState-Snapshot ist frei von Host-/Secret-bezogenen Inhalten' `
        -Success ($desiredSnapshot.Serialized -notmatch 'C:\\|D:\\|hostPath|automation|EnvironmentVariable|not-persist')

    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("sql-lab-reconcile-check-" + [guid]::NewGuid().ToString('N'))
try {
    $contract = & $module {
        param($Root)
        $desiredSnapshot = [PSCustomObject]@{
            Contract = [PSCustomObject]@{ Name = 'SqlServerLab.RunDesiredState'; Version = '1.0' }
            ProvisioningMode = 'manifest'
            LabName = 'Reconcile check'
            PersistentData = $false
            Instances = @(
                [PSCustomObject]@{ Id = 'primary'; Provider = 'podman'; Version = '2019'; Profile = 'standard'; DatabaseNames = @('master') },
                [PSCustomObject]@{ Id = 'secondary'; Provider = 'docker'; Version = '2019'; Profile = 'standard'; DatabaseNames = @('db1', 'db2') }
            )
        }
        $run = New-LabRunState -StateRoot $Root -Metadata @{ name = 'Reconcile check'; desiredState = $desiredSnapshot } -ProviderSubRuns @(
            [PSCustomObject]@{ provider = 'docker'; instanceIds = @('primary') }
        )
        $connection = [PSCustomObject]@{
            instances = @(
                [PSCustomObject]@{ id = 'primary'; provider = 'docker'; host = 'secret-host.invalid'; port = 1433; containerId = 'container-secret-id'; connectionString = 'Password=not-in-plan' },
                [PSCustomObject]@{ id = 'ghost'; provider = 'docker'; host = 'secret-host.invalid'; port = 1434; containerId = 'container-secret-id-2'; connectionString = 'Password=not-in-plan' }
            )
        }
        $connectionPath = Join-Path $run.RunDir 'connection-info.json'
        Write-LabArtifactJsonAtomic -Path $connectionPath -InputObject $connection
        $statePath = Join-Path $run.RunDir 'run-state.json'
        $beforeState = Get-Content -LiteralPath $statePath -Raw -Encoding utf8
        $beforeConnection = Get-Content -LiteralPath $connectionPath -Raw -Encoding utf8

        $originalRuntime = (Get-Command Get-LabRunRuntimeStatus).ScriptBlock
        try {
            $script:reconcileRuntimeState = 'RUNNING'
            $script:reconcileRuntimeInstances = @(
                [PSCustomObject]@{ Id = 'primary'; Provider = 'docker'; State = 'RUNNING' },
                [PSCustomObject]@{ Id = 'secondary'; Provider = 'podman'; State = 'RUNNING' }
            )
            Set-Item Function:Get-LabRunRuntimeStatus -Value {
                [PSCustomObject]@{ State = $script:reconcileRuntimeState; Source = 'mock'; Instances = $script:reconcileRuntimeInstances }
            }
            $migrationRun = New-LabRunState -StateRoot $Root -Metadata @{ name='Reconcile migration block'; workflowKind='hyperv-lab' } `
                -ProviderSubRuns @([PSCustomObject]@{ provider='hyperv'; instanceIds=@('primary') })
            Write-LabArtifactJsonAtomic -Path (Join-Path $migrationRun.RunDir 'hyperv-resource-migration.local.journal.json') -InputObject ([PSCustomObject]@{
                ContractVersion='SqlServerLab.HyperVResourceMigrationJournal/1.0'; RunId=$migrationRun.RunId
                Status='RECOVERY_REQUIRED'; CurrentStep='failed'; BindingCommitted=$false
            })
            $script:reconcileRuntimeState = 'STOPPED'
            $script:reconcileRuntimeInstances = @([PSCustomObject]@{ Id='primary'; Provider='hyperv'; State='STOPPED' })
            $migrationBlocked = Get-SqlServerLabReconcilePlan -RunId $migrationRun.RunId -TargetState RUNNING -StateRoot $Root

            $script:reconcileRuntimeState = 'RUNNING'
            $script:reconcileRuntimeInstances = @(
                [PSCustomObject]@{ Id = 'primary'; Provider = 'docker'; State = 'RUNNING' },
                [PSCustomObject]@{ Id = 'secondary'; Provider = 'podman'; State = 'RUNNING' }
            )
            $noOp = Get-SqlServerLabReconcilePlan -RunId $run.RunId -TargetState RUNNING -StateRoot $Root
            $script:reconcileRuntimeState = 'STOPPED'
            $restart = Get-SqlServerLabReconcilePlan -RunId $run.RunId -TargetState RUNNING -StateRoot $Root
            $script:reconcileRuntimeState = 'PARTIAL'
            $partial = Get-SqlServerLabReconcilePlan -RunId $run.RunId -TargetState STOPPED -StateRoot $Root

            $invalidSnapshot = [PSCustomObject]@{
                Contract = [PSCustomObject]@{ Name = 'SqlServerLab.RunDesiredState'; Version = '9.9' }
                Instances = @()
            }
            $invalidRun = New-LabRunState -StateRoot $Root -Metadata @{ name = 'Reconcile invalid'; desiredState = $invalidSnapshot } -ProviderSubRuns @(
                [PSCustomObject]@{ provider = 'docker'; instanceIds = @('fallback') }
            )
            $invalid = Get-SqlServerLabReconcilePlan -RunId $invalidRun.RunId -TargetState RUNNING -StateRoot $Root
        }
        finally {
            Set-Item Function:Get-LabRunRuntimeStatus -Value $originalRuntime
        }

        [PSCustomObject]@{
            NoOp = $noOp; Restart = $restart; Partial = $partial; Invalid = $invalid; MigrationBlocked = $migrationBlocked
            StateUnchanged = $beforeState -eq (Get-Content -LiteralPath $statePath -Raw -Encoding utf8)
            ConnectionUnchanged = $beforeConnection -eq (Get-Content -LiteralPath $connectionPath -Raw -Encoding utf8)
        }
    } $tempRoot

    Add-CheckResult `
        -Name 'Gleicher Ziel- und Runtime-State erzeugt vollstaendigen No-op' `
        -Success ($contract.NoOp.Contract.Name -eq 'SqlServerLab.ReconcilePlan' -and $contract.NoOp.Contract.Version -eq '1.0' -and $contract.NoOp.IsNoOp -and $contract.NoOp.Actions.Count -eq 0 -and -not $contract.NoOp.MutationAllowed)
    Add-CheckResult `
        -Name 'Stopped nach Running plant nur providergebundene Startvorschlaege' `
        -Success ($contract.Restart.HighestChangeClass -eq 'restart' -and @($contract.Restart.Actions).Count -eq 2 -and @($contract.Restart.Actions | Where-Object Operation -eq 'Start').Count -eq 2 -and @($contract.Restart.Actions.Provider | Sort-Object) -join ',' -eq 'docker,podman')
    Add-CheckResult `
        -Name 'Persistierter Sollzustand wird verwendet' `
        -Success ($contract.NoOp.Desired.Source -eq 'persisted-desired-state' -and @($contract.NoOp.Desired.Instances | ForEach-Object Provider) -join ',' -eq 'podman,docker')
    Add-CheckResult `
        -Name 'Partial Runtime bleibt fail-closed und plant keine Teilmutation' `
        -Success ($contract.Partial.HighestChangeClass -eq 'unsupported' -and $contract.Partial.Actions.Count -eq 0 -and -not $contract.Partial.MutationAllowed -and $contract.Partial.Warnings.Count -gt 0)
    Add-CheckResult `
        -Name 'Persistierter ungültiger Sollzustand bleibt fail-closed' `
        -Success ($contract.Invalid.HighestChangeClass -eq 'unsupported' -and $contract.Invalid.Actions.Count -eq 0 -and $contract.Invalid.Desired.IsValid -eq $false -and $contract.Invalid.Warnings.Count -gt 0 -and -not $contract.Invalid.MutationAllowed)
    Add-CheckResult `
        -Name 'Nichtterminale Hyper-V-Ressourcenmigration blockiert Reconcile read-only' `
        -Success ($contract.MigrationBlocked.HighestChangeClass -eq 'unsupported' -and $contract.MigrationBlocked.Actions.Count -eq 0 -and
            -not $contract.MigrationBlocked.HyperVResourceMigration.Allowed -and
            $contract.MigrationBlocked.HyperVResourceMigration.JournalStatus -eq 'RECOVERY_REQUIRED' -and
            $contract.MigrationBlocked.HyperVResourceMigration.ReasonCode -eq 'HYPERV_RESOURCE_MIGRATION_LIFECYCLE_BLOCKED')
    $serializedContract = $contract | ConvertTo-Json -Depth 20
    $containsForbiddenRuntimeData = $serializedContract -match 'not-in-plan|secret-host\.invalid|container-secret-id' -or
        $serializedContract -match '(?i)"port"\s*:\s*143[34](?:\s*[,}])'
    Add-CheckResult `
        -Name 'Plan enthaelt keine Secrets, Hostwerte, Ports oder Runtime-IDs' `
        -Success (-not $containsForbiddenRuntimeData)
    Add-CheckResult `
        -Name 'Read-only Plan veraendert weder Run-State noch Connection-Info' `
        -Success ($contract.StateUnchanged -and $contract.ConnectionUnchanged)
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
