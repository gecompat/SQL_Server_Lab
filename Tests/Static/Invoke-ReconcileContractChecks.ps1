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
        $topUnknown = @($snapshot.PSObject.Properties.Name | Where-Object { $_ -notin @('Contract', 'ProvisioningMode', 'LabName', 'PersistentData', 'Ai', 'Instances') })
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

    $networkContract = & $module {
        param($Root)

        $desiredSnapshot = [PSCustomObject]@{
            Contract=[PSCustomObject]@{ Name='SqlServerLab.RunDesiredState'; Version='1.0' }
            ProvisioningMode='manifest'; LabName='Hyper-V network reconcile'; PersistentData=$false
            Instances=@([PSCustomObject]@{
                Id='primary'; Provider='hyperv'; Version='2025'; Profile='standard'; DatabaseNames=@()
                Intents=[PSCustomObject]@{
                    Contract=[PSCustomObject]@{ Name='SqlServerLab.InstanceIntent'; Version='1.0' }
                    Network=[PSCustomObject]@{ Intent='hostOnly'; Exposure='host'; Binding='internal-switch' }
                }
            })
        }
        $run = New-LabRunState -StateRoot $Root -Metadata @{ name='Hyper-V network reconcile'; workflowKind='hyperv-lab'; desiredState=$desiredSnapshot } `
            -ProviderSubRuns @([PSCustomObject]@{ provider='hyperv'; instanceIds=@('primary') })
        Write-LabArtifactJsonAtomic -Path (Join-Path $run.RunDir 'connection-info.json') -InputObject ([PSCustomObject]@{
            instances = @([PSCustomObject]@{
                id='primary'; provider='hyperv'; vmName='host-value-must-not-leak'
                labNetwork=[PSCustomObject]@{
                    name='SQL_LAB_HYPERV'; intent='hostOnly'; subnet='172.28.0.0/24'
                    prefixLength=24; hostAddress='172.28.0.1'; address='172.28.0.42'; gateway=$null; dnsServers=@()
                }
            })
        })
        $desiredInstance = [PSCustomObject]@{
            Id='primary'; Provider='hyperv'; TargetState='RUNNING'
            Network=[PSCustomObject]@{ Intent='hostOnly'; Exposure='host'; Binding='internal-switch' }
        }

        $script:networkReconcileMode = 'matched'
        function Get-HyperVLabWorkflowRun {
            [PSCustomObject]@{ Instance=[PSCustomObject]@{ vmName='host-value-must-not-leak' } }
        }
        function Get-VMNetworkAdapter {
            if ($script:networkReconcileMode -eq 'unavailable') { throw 'simulated provider read failure' }
            if ($script:networkReconcileMode -eq 'detached') { return @() }
            if ($script:networkReconcileMode -eq 'lan') { return [PSCustomObject]@{ SwitchName='SQL_LAB_LAN'; IPAddresses=@('192.0.2.99') } }
            [PSCustomObject]@{ SwitchName='SQL_LAB_HYPERV'; IPAddresses=@('172.28.0.42') }
        }
        function Get-VMSwitch {
            if ($script:networkReconcileMode -eq 'lan') { return [PSCustomObject]@{ Name='SQL_LAB_LAN'; SwitchType='External' } }
            [PSCustomObject]@{ Name='SQL_LAB_HYPERV'; SwitchType='Internal' }
        }
        function Resolve-LabHyperVNetworkBoundPlan {
            [PSCustomObject]@{ Status='READY'; Actions=@(); Blockers=@() }
        }
        function Get-LabRunRuntimeStatus {
            [PSCustomObject]@{
                State='RUNNING'; Source='mock'
                Instances=@([PSCustomObject]@{ Id='primary'; Provider='hyperv'; State='RUNNING' })
            }
        }

        $matched = Get-LabHyperVNetworkReconcileActual -Run $run -DesiredInstance $desiredInstance -StateRoot $Root
        $matchedPlan = New-LabReconcilePlan -RunId $run.runId -TargetState RUNNING -StateRoot $Root
        $script:networkReconcileMode = 'detached'
        $drift = Get-LabHyperVNetworkReconcileActual -Run $run -DesiredInstance $desiredInstance -StateRoot $Root
        $script:networkReconcileMode = 'unavailable'
        $unavailable = Get-LabHyperVNetworkReconcileActual -Run $run -DesiredInstance $desiredInstance -StateRoot $Root

        $desired = [PSCustomObject]@{ IsValid=$true; TargetState='RUNNING'; Instances=@($desiredInstance) }
        $matchedComparison = Compare-LabDesiredActualState -Desired $desired -Actual ([PSCustomObject]@{
            State='RUNNING'; Instances=@([PSCustomObject]@{ Id='primary'; Provider='hyperv'; State='RUNNING'; Network=$matched })
        })
        $driftComparison = Compare-LabDesiredActualState -Desired $desired -Actual ([PSCustomObject]@{
            State='RUNNING'; Instances=@([PSCustomObject]@{ Id='primary'; Provider='hyperv'; State='RUNNING'; Network=$drift })
        })
        $unsupportedDesired = [PSCustomObject]@{
            IsValid=$true; TargetState='RUNNING'; Instances=@([PSCustomObject]@{
                Id='primary'; Provider='hyperv'; TargetState='RUNNING'
                Network=[PSCustomObject]@{
                    Intent='lan'; Exposure='lan'; Binding='external-switch'
                    PlanStatus='DECLARED_UNSUPPORTED'; CapabilityStatus='DECLARED_UNSUPPORTED'
                    ReasonCode='NETWORK_INTENT_PROVIDER_UNSUPPORTED'
                }
            })
        }
        $unsupportedComparison = Compare-LabDesiredActualState -Desired $unsupportedDesired -Actual ([PSCustomObject]@{
            State='RUNNING'; Instances=@([PSCustomObject]@{ Id='primary'; Provider='hyperv'; State='RUNNING'; Network=$matched })
        })

        $lanSnapshot = $desiredSnapshot | ConvertTo-Json -Depth 20 | ConvertFrom-Json -Depth 20
        $lanSnapshot.Instances[0].Intents.Network.Intent='lan'; $lanSnapshot.Instances[0].Intents.Network.Exposure='lan'; $lanSnapshot.Instances[0].Intents.Network.Binding='external-switch'
        $lanRun = New-LabRunState -StateRoot $Root -Metadata @{ name='Hyper-V LAN reconcile'; workflowKind='hyperv-lab'; desiredState=$lanSnapshot } `
            -ProviderSubRuns @([PSCustomObject]@{ provider='hyperv'; instanceIds=@('primary') })
        Write-LabArtifactJsonAtomic -Path (Join-Path $lanRun.RunDir 'connection-info.json') -InputObject ([PSCustomObject]@{
            instances=@([PSCustomObject]@{ id='primary'; provider='hyperv'; vmName='host-value-must-not-leak'; labNetwork=[PSCustomObject]@{
                name='SQL_LAB_LAN'; intent='lan'; addressMode='dhcp'; address='192.0.2.44'; prefixLength=24
            } })
        })
        Write-LabArtifactJsonAtomic -Path (Join-Path $lanRun.RunDir 'network-bound-plan.json') -InputObject ([PSCustomObject]@{
            Name='SQL_LAB_LAN'; AdapterId='11111111-1111-1111-1111-111111111111'
        })
        $script:networkReconcileMode = 'lan'
        $lanActual = Get-LabHyperVNetworkReconcileActual -Run $lanRun -DesiredInstance ([PSCustomObject]@{
            Id='primary'; Provider='hyperv'; TargetState='RUNNING'; Network=[PSCustomObject]@{ Intent='lan'; Exposure='lan'; Binding='external-switch' }
        }) -StateRoot $Root

        [PSCustomObject]@{
            Matched=$matched; MatchedPlan=$matchedPlan; Drift=$drift; Unavailable=$unavailable
            MatchedComparison=$matchedComparison; DriftComparison=$driftComparison; UnsupportedComparison=$unsupportedComparison; Lan=$lanActual
        }
    } $tempRoot

    Add-CheckResult `
        -Name 'Hyper-V-Netzwerk-Actual-State erkennt semantischen No-op ohne Hostwerte' `
        -Success ($networkContract.Matched.Status -eq 'MATCHED' -and
            $networkContract.Matched.AttachmentStatus -eq 'MATCHED' -and
            $networkContract.Matched.InfrastructureStatus -eq 'MATCHED' -and
            $networkContract.Matched.GuestAddressStatus -eq 'MATCHED' -and
            $networkContract.MatchedComparison.ChangeClass -eq 'no-op' -and
            $networkContract.MatchedPlan.IsNoOp -and
            @($networkContract.MatchedPlan.Diff | Where-Object Kind -eq 'network').Count -eq 1 -and
            (($networkContract.Matched | ConvertTo-Json -Depth 10) -notmatch 'SQL_LAB_HYPERV|172\.28|host-value'))
    Add-CheckResult `
        -Name 'Hyper-V-Netzwerkdrift blockiert Lifecycle-Teilaktionen fail-closed' `
        -Success ($networkContract.Drift.Status -eq 'DRIFT' -and
            $networkContract.Drift.ReasonCodes -contains 'HYPERV_NETWORK_ADAPTER_MISSING' -and
            $networkContract.DriftComparison.ChangeClass -eq 'unsupported' -and
            @($networkContract.DriftComparison.Actions).Count -eq 0)
    Add-CheckResult `
        -Name 'Nicht lesbarer Hyper-V-Netzwerkzustand bleibt explizit UNAVAILABLE' `
        -Success ($networkContract.Unavailable.Status -eq 'UNAVAILABLE' -and
            $networkContract.Unavailable.ReasonCodes -contains 'HYPERV_NETWORK_ACTUAL_STATE_UNAVAILABLE')
    Add-CheckResult `
        -Name 'Nicht gebundener Hyper-V-Network-Intent bleibt trotz beobachtbarer Runtime unsupported' `
        -Success ($networkContract.UnsupportedComparison.ChangeClass -eq 'unsupported' -and
            $networkContract.UnsupportedComparison.NetworkDiff[0].ActualStatus -eq 'DECLARED_UNSUPPORTED' -and
            $networkContract.UnsupportedComparison.NetworkDiff[0].ReasonCodes -contains 'NETWORK_INTENT_PROVIDER_UNSUPPORTED')
    Add-CheckResult `
        -Name 'Hyper-V-LAN-Reconcile akzeptiert einen DHCP-Adresswechsel ohne Hostwerte offenzulegen' `
        -Success ($networkContract.Lan.Status -eq 'MATCHED' -and
            $networkContract.Lan.ObservedBinding -eq 'external-switch' -and
            $networkContract.Lan.InfrastructureStatus -eq 'MATCHED' -and
            $networkContract.Lan.GuestAddressStatus -eq 'MATCHED' -and
            (($networkContract.Lan | ConvertTo-Json -Depth 10) -notmatch 'SQL_LAB_LAN|192\.0\.2|11111111'))
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
