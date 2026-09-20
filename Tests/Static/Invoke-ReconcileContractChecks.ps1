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
        $intentUnknown = @($snapshot.Instances | ForEach-Object {
            $_.Intents.PSObject.Properties.Name | Where-Object { $_ -notin @('Contract','Drives','Network','Resources','SqlEndpoint','SqlConfiguration','Databases','Software','CapabilityAssessment','Storage','WindowsLocale','WindowsActivation') }
        })
        [PSCustomObject]@{
            Snapshot = $snapshot
            TopUnknown = $topUnknown
            InstanceUnknown = @($instanceUnknown | Where-Object { $_ })
            IntentUnknown = $intentUnknown
            Serialized = $snapshot | ConvertTo-Json -Depth 10
        }
    }

    Add-CheckResult `
        -Name 'DesiredState-Snapshot enthält nur erlaubte Felder' `
        -Success ($desiredSnapshot.TopUnknown.Count -eq 0 -and $desiredSnapshot.InstanceUnknown.Count -eq 0 -and $desiredSnapshot.IntentUnknown.Count -eq 0)
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

            $identityCases = @(
                @{ Name='identisch'; Providers=@('docker','docker'); Ids=@('primary','primary'); Duplicate=$true },
                @{ Name='Id-Grossschreibung'; Providers=@('docker','docker'); Ids=@('primary','PRIMARY'); Duplicate=$true },
                @{ Name='Provider-Grossschreibung'; Providers=@('docker','DOCKER'); Ids=@('primary','primary'); Duplicate=$true },
                @{ Name='mehrfache gemischte Grossschreibung'; Providers=@('docker','DOCKER','Docker'); Ids=@('primary','PRIMARY','Primary'); Duplicate=$true },
                @{ Name='verschiedene Provider'; Providers=@('docker','podman'); Ids=@('primary','PRIMARY'); Duplicate=$false }
            )
            $identities = @(foreach ($case in $identityCases) {
                $identitySnapshot = [PSCustomObject]@{
                    Contract = [PSCustomObject]@{ Name='SqlServerLab.RunDesiredState'; Version='1.0' }
                    ProvisioningMode='manifest'; PersistentData=$false
                    Instances = @(for ($i=0; $i -lt $case.Ids.Count; $i++) {
                        [PSCustomObject]@{
                            Id=$case.Ids[$i]; Provider=$case.Providers[$i]; Profile='standard'
                            Host='secret-host.invalid'; ContainerId='container-secret-id'; ConnectionString='Password=not-in-plan'
                        }
                    })
                }
                $identityRun = New-LabRunState -StateRoot $Root -Metadata @{ name='Reconcile identity'; desiredState=$identitySnapshot } -ProviderSubRuns @(
                    [PSCustomObject]@{ provider='docker'; instanceIds=@('fallback') }
                )
                $identityStatePath = Join-Path $identityRun.RunDir 'run-state.json'
                $identityConnectionPath = Join-Path $identityRun.RunDir 'connection-info.json'
                Write-LabArtifactJsonAtomic -Path $identityConnectionPath -InputObject $connection
                $beforeIdentityState = [Convert]::ToBase64String([IO.File]::ReadAllBytes($identityStatePath))
                $beforeIdentityConnection = [Convert]::ToBase64String([IO.File]::ReadAllBytes($identityConnectionPath))
                $persistedIdentity = Get-LabPersistedDesiredState -RunId $identityRun.RunId -StateRoot $Root
                $identityPlans = @(foreach ($target in @('RUNNING','STOPPED')) {
                    $script:reconcileRuntimeState = if ($target -eq 'RUNNING') { 'STOPPED' } else { 'RUNNING' }
                    $script:reconcileRuntimeInstances = @(
                        [PSCustomObject]@{ Id='primary'; Provider='docker'; State=$script:reconcileRuntimeState },
                        [PSCustomObject]@{ Id='PRIMARY'; Provider='podman'; State=$script:reconcileRuntimeState }
                    )
                    Get-SqlServerLabReconcilePlan -RunId $identityRun.RunId -TargetState $target -StateRoot $Root
                })
                [PSCustomObject]@{
                    Name=$case.Name; Duplicate=$case.Duplicate; Status=$persistedIdentity.Status; Reason=$persistedIdentity.Reason
                    Plans=$identityPlans
                    StateUnchanged=$beforeIdentityState -ceq [Convert]::ToBase64String([IO.File]::ReadAllBytes($identityStatePath))
                    ConnectionUnchanged=$beforeIdentityConnection -ceq [Convert]::ToBase64String([IO.File]::ReadAllBytes($identityConnectionPath))
                }
            })
            $identityGrammarCases = @(
                @{ Name='ungueltige Id beginnt mit Ziffer'; Id='1primary'; Provider='docker'; Expected=@('DESIRED_INSTANCE_ID_INVALID') },
                @{ Name='ungueltige Id mit Leerzeichen'; Id='primary node'; Provider='docker'; Expected=@('DESIRED_INSTANCE_ID_INVALID') },
                @{ Name='ungueltige numerische Id bleibt nicht missing'; Id=0; Provider='docker'; Expected=@('DESIRED_INSTANCE_ID_INVALID') },
                @{ Name='ungueltige boolesche False-Id bleibt nicht missing'; Id=$false; Provider='docker'; Expected=@('DESIRED_INSTANCE_ID_INVALID') },
                @{ Name='ungueltige boolesche True-Id bleibt nicht missing'; Id=$true; Provider='docker'; Expected=@('DESIRED_INSTANCE_ID_INVALID') },
                @{ Name='ungueltiger Provider'; Id='primary'; Provider='kubernetes'; Expected=@('DESIRED_INSTANCE_PROVIDER_INVALID') },
                @{ Name='ungueltiger boolescher Provider bleibt nicht missing'; Id='primary'; Provider=$false; Expected=@('DESIRED_INSTANCE_PROVIDER_INVALID') },
                @{ Name='kombinierte ungueltige Identitaet'; Id='1primary'; Provider='kubernetes'; Expected=@('DESIRED_INSTANCE_ID_INVALID','DESIRED_INSTANCE_PROVIDER_INVALID') },
                @{ Name='Provider Grossschreibung bleibt gueltig'; Id='primary'; Provider='HyPeRv'; Expected=@() }
            )
            $identityGrammar = @(foreach ($case in $identityGrammarCases) {
                $grammarSnapshot = [PSCustomObject]@{
                    Contract = [PSCustomObject]@{ Name='SqlServerLab.RunDesiredState'; Version='1.0' }
                    ProvisioningMode='manifest'; PersistentData=$false
                    Instances = @([PSCustomObject]@{ Id=$case.Id; Provider=$case.Provider; Profile='standard' })
                }
                $grammarRun = New-LabRunState -StateRoot $Root -Metadata @{ name='Reconcile identity grammar'; desiredState=$grammarSnapshot } -ProviderSubRuns @(
                    [PSCustomObject]@{ provider='docker'; instanceIds=@('fallback') }
                )
                $grammarStatePath = Join-Path $grammarRun.RunDir 'run-state.json'
                $grammarConnectionPath = Join-Path $grammarRun.RunDir 'connection-info.json'
                Write-LabArtifactJsonAtomic -Path $grammarConnectionPath -InputObject $connection
                $beforeGrammarState = [Convert]::ToBase64String([IO.File]::ReadAllBytes($grammarStatePath))
                $beforeGrammarConnection = [Convert]::ToBase64String([IO.File]::ReadAllBytes($grammarConnectionPath))
                $persistedGrammar = Get-LabPersistedDesiredState -RunId $grammarRun.RunId -StateRoot $Root
                $grammarPlans = @(foreach ($target in @('RUNNING','STOPPED')) {
                    $script:reconcileRuntimeState = if ($target -eq 'RUNNING') { 'STOPPED' } else { 'RUNNING' }
                    $script:reconcileRuntimeInstances = @([PSCustomObject]@{ Id='primary'; Provider='docker'; State=$script:reconcileRuntimeState })
                    Get-SqlServerLabReconcilePlan -RunId $grammarRun.RunId -TargetState $target -StateRoot $Root
                })
                [PSCustomObject]@{
                    Name=$case.Name; Expected=@($case.Expected); Status=$persistedGrammar.Status
                    Reason=$persistedGrammar.Reason; ReasonCodes=@($persistedGrammar.ReasonCodes)
                    PersistedProvider=if ($persistedGrammar.Snapshot.Instances[0]) { [string]$persistedGrammar.Snapshot.Instances[0].Provider } else { $null }
                    OriginalProvider=$case.Provider; Plans=$grammarPlans
                    StateUnchanged=$beforeGrammarState -ceq [Convert]::ToBase64String([IO.File]::ReadAllBytes($grammarStatePath))
                    ConnectionUnchanged=$beforeGrammarConnection -ceq [Convert]::ToBase64String([IO.File]::ReadAllBytes($grammarConnectionPath))
                }
            })
            $topLevelCases = @(
                @{ Name='manifest und false bleiben gueltig'; ProvisioningMode='manifest'; PersistentData=$false; Expected=@() },
                @{ Name='adhoc und true bleiben gueltig'; ProvisioningMode='adhoc'; PersistentData=$true; Expected=@() },
                @{ Name='fehlender ProvisioningMode'; PersistentData=$false; Expected=@('DESIRED_STATE_PROVISIONING_MODE_INVALID') },
                @{ Name='boolescher ProvisioningMode'; ProvisioningMode=$false; PersistentData=$false; Expected=@('DESIRED_STATE_PROVISIONING_MODE_INVALID') },
                @{ Name='numerischer ProvisioningMode'; ProvisioningMode=0; PersistentData=$false; Expected=@('DESIRED_STATE_PROVISIONING_MODE_INVALID') },
                @{ Name='ungueltiger ProvisioningMode-Wert'; ProvisioningMode='Manifest'; PersistentData=$false; Expected=@('DESIRED_STATE_PROVISIONING_MODE_INVALID') },
                @{ Name='fehlendes PersistentData'; ProvisioningMode='manifest'; Expected=@('DESIRED_STATE_PERSISTENT_DATA_INVALID') },
                @{ Name='string PersistentData'; ProvisioningMode='manifest'; PersistentData='false'; Expected=@('DESIRED_STATE_PERSISTENT_DATA_INVALID') },
                @{ Name='numerisches PersistentData'; ProvisioningMode='manifest'; PersistentData=0; Expected=@('DESIRED_STATE_PERSISTENT_DATA_INVALID') },
                @{ Name='null PersistentData'; ProvisioningMode='manifest'; PersistentData=$null; Expected=@('DESIRED_STATE_PERSISTENT_DATA_INVALID') },
                @{ Name='kombinierte Top-Level-Fehler'; ProvisioningMode='invalid'; PersistentData='false'; Expected=@('DESIRED_STATE_PERSISTENT_DATA_INVALID','DESIRED_STATE_PROVISIONING_MODE_INVALID') }
            )
            $topLevel = @(foreach ($case in $topLevelCases) {
                $topLevelSnapshot = [PSCustomObject]@{
                    Contract = [PSCustomObject]@{ Name='SqlServerLab.RunDesiredState'; Version='1.0' }
                    LabName = 'Reconcile top-level options'
                    Instances = @([PSCustomObject]@{ Id='primary'; Provider='docker'; Profile='standard' })
                }
                if ($case.ContainsKey('ProvisioningMode')) { Add-Member -InputObject $topLevelSnapshot -MemberType NoteProperty -Name ProvisioningMode -Value $case.ProvisioningMode }
                if ($case.ContainsKey('PersistentData')) { Add-Member -InputObject $topLevelSnapshot -MemberType NoteProperty -Name PersistentData -Value $case.PersistentData }
                $topLevelRun = New-LabRunState -StateRoot $Root -Metadata @{ name='Reconcile top-level options'; desiredState=$topLevelSnapshot } -ProviderSubRuns @(
                    [PSCustomObject]@{ provider='docker'; instanceIds=@('fallback') }
                )
                $topLevelStatePath = Join-Path $topLevelRun.RunDir 'run-state.json'
                $topLevelConnectionPath = Join-Path $topLevelRun.RunDir 'connection-info.json'
                Write-LabArtifactJsonAtomic -Path $topLevelConnectionPath -InputObject $connection
                $beforeTopLevelState = [Convert]::ToBase64String([IO.File]::ReadAllBytes($topLevelStatePath))
                $beforeTopLevelConnection = [Convert]::ToBase64String([IO.File]::ReadAllBytes($topLevelConnectionPath))
                $persistedTopLevel = Get-LabPersistedDesiredState -RunId $topLevelRun.RunId -StateRoot $Root
                $topLevelPlans = @(foreach ($target in @('RUNNING','STOPPED')) {
                    $script:reconcileRuntimeState = if ($target -eq 'RUNNING') { 'STOPPED' } else { 'RUNNING' }
                    $script:reconcileRuntimeInstances = @([PSCustomObject]@{ Id='primary'; Provider='docker'; State=$script:reconcileRuntimeState })
                    Get-SqlServerLabReconcilePlan -RunId $topLevelRun.RunId -TargetState $target -StateRoot $Root
                })
                [PSCustomObject]@{
                    Name=$case.Name; Expected=@($case.Expected); Status=$persistedTopLevel.Status
                    Reason=$persistedTopLevel.Reason; ReasonCodes=@($persistedTopLevel.ReasonCodes); Plans=$topLevelPlans
                    StateUnchanged=$beforeTopLevelState -ceq [Convert]::ToBase64String([IO.File]::ReadAllBytes($topLevelStatePath))
                    ConnectionUnchanged=$beforeTopLevelConnection -ceq [Convert]::ToBase64String([IO.File]::ReadAllBytes($topLevelConnectionPath))
                }
            })
            $sanitizationSnapshot = [PSCustomObject]@{
                Contract = [PSCustomObject]@{ Name='SqlServerLab.RunDesiredState'; Version='1.0' }
                ProvisioningMode='manifest'; PersistentData=$false
                Instances = @(
                    [PSCustomObject]@{
                        Id='persisted-instance-secret-9'; Provider='docker'; Host='secret-host.invalid'; ConnectionString='Password=not-in-plan'
                        Intents=[PSCustomObject]@{
                            Contract=[PSCustomObject]@{ Name='invalid'; Version='9.9' }
                            Network='invalid-network-intent'
                            CapabilityAssessment=[PSCustomObject]@{ Invalid='invalid-assessment' }
                        }
                    },
                    [PSCustomObject]@{ Id='PERSISTED-INSTANCE-SECRET-9'; Provider='DOCKER' },
                    [PSCustomObject]@{ Id=$null; Provider=$null; Host='other-secret-host.invalid' }
                )
            }
            $sanitizationRun = New-LabRunState -StateRoot $Root -Metadata @{ name='Reconcile sanitization'; desiredState=$sanitizationSnapshot } -ProviderSubRuns @(
                [PSCustomObject]@{ provider='docker'; instanceIds=@('fallback') }
            )
            $sanitizationStatePath = Join-Path $sanitizationRun.RunDir 'run-state.json'
            $sanitizationConnectionPath = Join-Path $sanitizationRun.RunDir 'connection-info.json'
            Write-LabArtifactJsonAtomic -Path $sanitizationConnectionPath -InputObject $connection
            $beforeSanitizationState = [Convert]::ToBase64String([IO.File]::ReadAllBytes($sanitizationStatePath))
            $beforeSanitizationConnection = [Convert]::ToBase64String([IO.File]::ReadAllBytes($sanitizationConnectionPath))
            $persistedSanitization = Get-LabPersistedDesiredState -RunId $sanitizationRun.RunId -StateRoot $Root
            $sanitizationPlans = @(foreach ($target in @('RUNNING','STOPPED')) {
                $script:reconcileRuntimeState = if ($target -eq 'RUNNING') { 'STOPPED' } else { 'RUNNING' }
                $script:reconcileRuntimeInstances = @([PSCustomObject]@{ Id='primary'; Provider='docker'; State=$script:reconcileRuntimeState })
                Get-SqlServerLabReconcilePlan -RunId $sanitizationRun.RunId -TargetState $target -StateRoot $Root
            })
            $sanitization = [PSCustomObject]@{
                Status=$persistedSanitization.Status; Reason=$persistedSanitization.Reason; ReasonCodes=@($persistedSanitization.ReasonCodes)
                Plans=$sanitizationPlans
                StateUnchanged=$beforeSanitizationState -ceq [Convert]::ToBase64String([IO.File]::ReadAllBytes($sanitizationStatePath))
                ConnectionUnchanged=$beforeSanitizationConnection -ceq [Convert]::ToBase64String([IO.File]::ReadAllBytes($sanitizationConnectionPath))
            }
        }
        finally {
            Set-Item Function:Get-LabRunRuntimeStatus -Value $originalRuntime
        }

        [PSCustomObject]@{
            NoOp = $noOp; Restart = $restart; Partial = $partial; Invalid = $invalid; MigrationBlocked = $migrationBlocked
            Identities = $identities; IdentityGrammar = $identityGrammar
            TopLevel = $topLevel
            Sanitization = $sanitization
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
    foreach ($identity in $contract.Identities) {
        if ($identity.Duplicate) {
            Add-CheckResult -Name "Doppelte Sollidentitaet ($($identity.Name)) liefert genau einen sanitisierten Grund" `
                -Success ($identity.Status -eq 'INVALID' -and $identity.Reason -ceq 'DESIRED_INSTANCE_IDENTITY_DUPLICATE')
            foreach ($plan in $identity.Plans) {
                Add-CheckResult -Name "Doppelte Sollidentitaet ($($identity.Name)) blockiert $($plan.Desired.TargetState) ohne Fallback" `
                    -Success ($plan.HighestChangeClass -eq 'unsupported' -and $plan.Actions.Count -eq 0 -and
                        -not $plan.MutationAllowed -and -not $plan.IsNoOp -and -not $plan.Desired.IsValid -and
                        $plan.Desired.Source -eq 'persisted-desired-state-invalid' -and $plan.Desired.Instances.Count -eq 0 -and
                        $plan.Desired.ValidationError -ceq 'DESIRED_INSTANCE_IDENTITY_DUPLICATE')
            }
        }
        else {
            Add-CheckResult -Name 'Gleiche Id bei verschiedenen Providern bleibt gueltig' `
                -Success ($identity.Status -eq 'VALID' -and $null -eq $identity.Reason)
            foreach ($plan in $identity.Plans) {
                $expectedOperation = if ($plan.Desired.TargetState -eq 'RUNNING') { 'Start' } else { 'Stop' }
                Add-CheckResult -Name "Providergebundene gleiche Id plant $expectedOperation getrennt" `
                    -Success ($plan.Desired.IsValid -and $plan.Desired.Instances.Count -eq 2 -and
                        $plan.HighestChangeClass -eq 'restart' -and $plan.Actions.Count -eq 2 -and
                        @($plan.Actions | Where-Object Operation -eq $expectedOperation).Count -eq 2 -and
                        (($plan.Actions.Provider | Sort-Object) -join ',') -eq 'docker,podman')
            }
        }
        Add-CheckResult -Name "Identitaetspruefung ($($identity.Name)) erhaelt State- und Connection-Bytes" `
            -Success ($identity.StateUnchanged -and $identity.ConnectionUnchanged)
    }
    foreach ($grammar in $contract.IdentityGrammar) {
        if ($grammar.Expected.Count -eq 0) {
            Add-CheckResult -Name "Persistierte Identitaetsgrammatik ($($grammar.Name)) bleibt ohne Normalisierung gueltig" `
                -Success ($grammar.Status -eq 'VALID' -and $null -eq $grammar.Reason -and
                    $grammar.PersistedProvider -ceq $grammar.OriginalProvider)
            foreach ($plan in $grammar.Plans) {
                Add-CheckResult -Name "Gueltige persistierte Identitaetsgrammatik ($($grammar.Name)) plant $($plan.Desired.TargetState)" `
                    -Success ($plan.Desired.IsValid -and $plan.Desired.Source -eq 'persisted-desired-state' -and
                        $plan.Desired.Instances.Count -eq 1)
            }
        }
        else {
            Add-CheckResult -Name "Persistierte Identitaetsgrammatik ($($grammar.Name)) liefert deduplizierte ordinale Gruende" `
                -Success ($grammar.Status -eq 'INVALID' -and
                    (($grammar.ReasonCodes -join ',') -ceq ($grammar.Expected -join ',')) -and
                    $grammar.Reason -ceq ($grammar.Expected -join ','))
            foreach ($plan in $grammar.Plans) {
                Add-CheckResult -Name "Ungueltige persistierte Identitaetsgrammatik ($($grammar.Name)) blockiert $($plan.Desired.TargetState) fail-closed" `
                    -Success ($plan.HighestChangeClass -eq 'unsupported' -and $plan.Actions.Count -eq 0 -and
                        -not $plan.MutationAllowed -and -not $plan.IsNoOp -and -not $plan.Desired.IsValid -and
                        $plan.Desired.Source -eq 'persisted-desired-state-invalid' -and $plan.Desired.Instances.Count -eq 0 -and
                        (($plan.Diff[0].Reasons -join ',') -ceq (@($grammar.Expected | ForEach-Object { "Persisted desired state ist ungültig: $_" }) -join ',')))
            }
        }
        Add-CheckResult -Name "Persistierte Identitaetsgrammatik ($($grammar.Name)) erhaelt State- und Connection-Bytes" `
            -Success ($grammar.StateUnchanged -and $grammar.ConnectionUnchanged)
    }
    foreach ($topLevel in $contract.TopLevel) {
        if ($topLevel.Expected.Count -eq 0) {
            Add-CheckResult -Name "Gueltige persistierte Top-Level-Optionen ($($topLevel.Name)) bleiben akzeptiert" `
                -Success ($topLevel.Status -eq 'VALID' -and $null -eq $topLevel.Reason -and $topLevel.ReasonCodes.Count -eq 0)
            foreach ($plan in $topLevel.Plans) {
                Add-CheckResult -Name "Gueltige persistierte Top-Level-Optionen ($($topLevel.Name)) erlauben $($plan.Desired.TargetState)" `
                    -Success ($plan.Desired.IsValid -and $plan.Desired.Source -eq 'persisted-desired-state' -and
                        $plan.Desired.Instances.Count -eq 1)
            }
        }
        else {
            Add-CheckResult -Name "Ungueltige persistierte Top-Level-Optionen ($($topLevel.Name)) liefern deduplizierte ordinale Gruende" `
                -Success ($topLevel.Status -eq 'INVALID' -and
                    (($topLevel.ReasonCodes -join ',') -ceq ($topLevel.Expected -join ',')) -and
                    $topLevel.Reason -ceq ($topLevel.Expected -join ','))
            foreach ($plan in $topLevel.Plans) {
                Add-CheckResult -Name "Ungueltige persistierte Top-Level-Optionen ($($topLevel.Name)) blockieren $($plan.Desired.TargetState) fail-closed" `
                    -Success ($plan.HighestChangeClass -eq 'unsupported' -and $plan.Actions.Count -eq 0 -and
                        -not $plan.MutationAllowed -and -not $plan.IsNoOp -and -not $plan.Desired.IsValid -and
                        $plan.Desired.Source -eq 'persisted-desired-state-invalid' -and $plan.Desired.Instances.Count -eq 0 -and
                        (($plan.Diff[0].Reasons -join ',') -ceq (@($topLevel.Expected | ForEach-Object { "Persisted desired state ist ungültig: $_" }) -join ',')))
            }
        }
        Add-CheckResult -Name "Persistierte Top-Level-Optionen ($($topLevel.Name)) erhalten State- und Connection-Bytes" `
            -Success ($topLevel.StateUnchanged -and $topLevel.ConnectionUnchanged)
    }
    $expectedSanitizedCodes = @(
        'DESIRED_INSTANCE_IDENTITY_DUPLICATE',
        'DESIRED_INSTANCE_ID_MISSING',
        'DESIRED_INSTANCE_INTENT_CONTRACT_INVALID',
        'DESIRED_INSTANCE_NETWORK_INTENT_INVALID',
        'DESIRED_INSTANCE_PROVIDER_MISSING',
        'INSTANCE_CAPABILITY_ASSESSMENT_INVALID'
    )
    Add-CheckResult `
        -Name 'Persistierte Mehrfachfehler liefern eindeutige ordinal sortierte ReasonCodes' `
        -Success ($contract.Sanitization.Status -eq 'INVALID' -and
            (($contract.Sanitization.ReasonCodes -join ',') -ceq ($expectedSanitizedCodes -join ',')) -and
            $contract.Sanitization.Reason -ceq ($expectedSanitizedCodes -join ','))
    foreach ($plan in $contract.Sanitization.Plans) {
        Add-CheckResult -Name "Persistierte Mehrfachfehler blockieren $($plan.Desired.TargetState) sanitisiert und fail-closed" `
            -Success ($plan.HighestChangeClass -eq 'unsupported' -and $plan.Actions.Count -eq 0 -and
                -not $plan.MutationAllowed -and -not $plan.IsNoOp -and -not $plan.Desired.IsValid -and
                $plan.Desired.Instances.Count -eq 0 -and
                (($plan.Diff[0].Reasons -join ',') -ceq (@($expectedSanitizedCodes | ForEach-Object { "Persisted desired state ist ungültig: $_" }) -join ',')) -and
                (($plan.Warnings -join ',') -ceq 'Persisted desired state validation blocks lifecycle reconcile; fail-closed without partial mutation.'))
    }
    $serializedSanitization = $contract.Sanitization | ConvertTo-Json -Depth 20
    Add-CheckResult `
        -Name 'Persistierte Mehrfachfehler reflektieren keine dynamischen Persistenzwerte' `
        -Success (-not ($serializedSanitization -match 'persisted-instance-secret-9|secret-host\.invalid|not-in-plan|invalid-assessment'))
    Add-CheckResult `
        -Name 'Persistierte Mehrfachfehler erhalten State- und Connection-Bytes' `
        -Success ($contract.Sanitization.StateUnchanged -and $contract.Sanitization.ConnectionUnchanged)
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

    $persistedNetworkContract = & $module {
        param($Root)

        function New-TestPersistedNetworkIntent {
            param([string]$Provider, [string]$Intent)
            $resolved = Resolve-LabNetworkIntentPlan -Provider $Provider -Network ([PSCustomObject]@{
                intent=$Intent
                exposure=switch($Intent){ 'isolated'{'none'}; 'lan'{'lan'}; default{'host'} }
            })
            [PSCustomObject]@{
                Intent=[string]$resolved.Intent; Exposure=[string]$resolved.Exposure; Binding=[string]$resolved.Binding
                ManagedBinding=([string]$resolved.Intent -ne 'isolated'); RequiredCapability=[string]$resolved.RequiredCapability
                CapabilityStatus=if([string]$resolved.Status -eq 'RESOLVED'){'DECLARED_SUPPORTED'}else{'DECLARED_UNSUPPORTED'}
                PlanStatus=[string]$resolved.Status; ReasonCode=$resolved.ReasonCode
            }
        }

        $cases = @(
            @{ Name='Docker NAT'; Provider='docker'; Intent='nat'; Kind='valid'; Valid=$true },
            @{ Name='Podman NAT mit deklarativ fehlender Capability'; Provider='podman'; Intent='nat'; Kind='declared-unsupported'; Valid=$true },
            @{ Name='Hyper-V isolated'; Provider='hyperv'; Intent='isolated'; Kind='valid'; Valid=$true },
            @{ Name='Hyper-V hostOnly'; Provider='hyperv'; Intent='hostOnly'; Kind='valid'; Valid=$true },
            @{ Name='Hyper-V NAT'; Provider='hyperv'; Intent='nat'; Kind='valid'; Valid=$true },
            @{ Name='Hyper-V LAN'; Provider='hyperv'; Intent='lan'; Kind='valid'; Valid=$true },
            @{ Name='Legacy ohne Network'; Provider='hyperv'; Intent='hostOnly'; Kind='legacy'; Valid=$true },
            @{ Name='Network falscher Typ'; Provider='hyperv'; Intent='hostOnly'; Kind='type'; Valid=$false },
            @{ Name='Binding fehlt'; Provider='hyperv'; Intent='hostOnly'; Kind='missing-binding'; Valid=$false },
            @{ Name='Exposure passt nicht zum Intent'; Provider='hyperv'; Intent='hostOnly'; Kind='exposure'; Valid=$false },
            @{ Name='Binding passt nicht zum Provider'; Provider='hyperv'; Intent='hostOnly'; Kind='binding'; Valid=$false },
            @{ Name='ManagedBinding passt nicht zum Intent'; Provider='hyperv'; Intent='hostOnly'; Kind='managed-binding'; Valid=$false },
            @{ Name='Capability passt nicht zum Intent'; Provider='hyperv'; Intent='nat'; Kind='capability'; Valid=$false },
            @{ Name='CapabilityStatus ist ungueltig'; Provider='hyperv'; Intent='nat'; Kind='capability-status'; Valid=$false },
            @{ Name='Reason passt nicht zum unsupported Intent'; Provider='docker'; Intent='hostOnly'; Kind='reason'; Valid=$false },
            @{ Name='PlanStatus passt nicht zum Resolver'; Provider='docker'; Intent='nat'; Kind='plan-status'; Valid=$false },
            @{ Name='Hostwert im Network-Snapshot'; Provider='hyperv'; Intent='hostOnly'; Kind='unknown-field'; Valid=$false }
        )
        $originalRuntime = (Get-Command Get-LabRunRuntimeStatus).ScriptBlock
        $script:invalidPersistedNetworkRuntimeCalls = 0
        try {
            Set-Item Function:Get-LabRunRuntimeStatus -Value {
                $script:invalidPersistedNetworkRuntimeCalls++
                throw 'RUNTIME_MUST_NOT_BE_READ_FOR_INVALID_PERSISTED_NETWORK'
            }
            $results = @($cases | ForEach-Object {
                $case = $_
                $intents = [PSCustomObject]@{ Contract=[PSCustomObject]@{ Name='SqlServerLab.InstanceIntent'; Version='1.0' } }
                if ($case.Kind -ne 'legacy') {
                    $network = New-TestPersistedNetworkIntent -Provider $case.Provider -Intent $case.Intent
                    switch ($case.Kind) {
                        'type' { $network = 'not-a-network-object' }
                        'missing-binding' { $network.PSObject.Properties.Remove('Binding') }
                        'exposure' { $network.Exposure = 'none' }
                        'binding' { $network.Binding = 'managed-bridge-nat' }
                        'managed-binding' { $network.ManagedBinding = $false }
                        'capability' { $network.RequiredCapability = 'managed-lab-network' }
                        'declared-unsupported' { $network.CapabilityStatus = 'DECLARED_UNSUPPORTED' }
                        'capability-status' { $network.CapabilityStatus = 'NOT_REQUESTED' }
                        'reason' { $network.ReasonCode = 'NETWORK_INTENT_UNKNOWN' }
                        'plan-status' { $network.PlanStatus = 'DECLARED_UNSUPPORTED' }
                        'unknown-field' { $network | Add-Member -NotePropertyName HostAddress -NotePropertyValue '192.0.2.10' }
                    }
                    $intents | Add-Member -NotePropertyName Network -NotePropertyValue $network
                }
                $snapshot = [PSCustomObject]@{
                    Contract=[PSCustomObject]@{ Name='SqlServerLab.RunDesiredState'; Version='1.0' }
                    ProvisioningMode='manifest'; PersistentData=$false
                    Instances=@([PSCustomObject]@{ Id='primary'; Provider=$case.Provider; Profile='standard'; Intents=$intents })
                }
                $run = New-LabRunState -StateRoot $Root -Metadata @{ name='persisted network intent'; desiredState=$snapshot } `
                    -ProviderSubRuns @([PSCustomObject]@{ provider=$case.Provider; instanceIds=@('primary') })
                $statePath = Join-Path $run.RunDir 'run-state.json'
                $connectionPath = Join-Path $run.RunDir 'connection-info.json'
                Write-LabArtifactJsonAtomic -Path $connectionPath -InputObject ([PSCustomObject]@{ instances=@([PSCustomObject]@{ id='primary'; provider=$case.Provider; host='must-not-fallback.invalid' }) })
                $beforeState = [Convert]::ToBase64String([IO.File]::ReadAllBytes($statePath))
                $beforeConnection = [Convert]::ToBase64String([IO.File]::ReadAllBytes($connectionPath))
                $persisted = Get-LabPersistedDesiredState -RunId $run.RunId -StateRoot $Root
                $plans = @()
                if (-not $case.Valid) {
                    foreach ($target in @('RUNNING','STOPPED')) {
                        $plans += Get-SqlServerLabReconcilePlan -RunId $run.RunId -TargetState $target -StateRoot $Root
                    }
                }
                [PSCustomObject]@{
                    Name=$case.Name; Valid=$case.Valid; Status=$persisted.Status; ReasonCodes=@($persisted.ReasonCodes); Plans=@($plans)
                    StateUnchanged=$beforeState -ceq [Convert]::ToBase64String([IO.File]::ReadAllBytes($statePath))
                    ConnectionUnchanged=$beforeConnection -ceq [Convert]::ToBase64String([IO.File]::ReadAllBytes($connectionPath))
                }
            })
            [PSCustomObject]@{ Cases=$results; RuntimeCalls=$script:invalidPersistedNetworkRuntimeCalls }
        }
        finally { Set-Item Function:Get-LabRunRuntimeStatus -Value $originalRuntime }
    } $tempRoot
    foreach ($networkCase in @($persistedNetworkContract.Cases)) {
        if ($networkCase.Valid) {
            Add-CheckResult -Name "Persistierter Network-Intent ($($networkCase.Name)) bleibt kanonisch oder legacy-gueltig" `
                -Success ($networkCase.Status -eq 'VALID' -and $networkCase.ReasonCodes.Count -eq 0)
        }
        else {
            Add-CheckResult -Name "Ungueltiger persistierter Network-Intent ($($networkCase.Name)) liefert den festen Grund" `
                -Success ($networkCase.Status -eq 'INVALID' -and ($networkCase.ReasonCodes -join ',') -ceq 'DESIRED_INSTANCE_NETWORK_INTENT_INVALID')
            foreach ($plan in $networkCase.Plans) {
                Add-CheckResult -Name "Ungueltiger persistierter Network-Intent ($($networkCase.Name)) blockiert $($plan.Desired.TargetState) ohne Runtime-Fallback" `
                    -Success ($plan.HighestChangeClass -eq 'unsupported' -and $plan.Actions.Count -eq 0 -and -not $plan.MutationAllowed -and
                        -not $plan.IsNoOp -and -not $plan.Desired.IsValid -and $plan.Desired.Instances.Count -eq 0 -and
                        $plan.Actual.Source -eq 'persisted-desired-state-invalid')
            }
        }
        Add-CheckResult -Name "Persistierter Network-Intent ($($networkCase.Name)) erhaelt State- und Connection-Bytes" `
            -Success ($networkCase.StateUnchanged -and $networkCase.ConnectionUnchanged)
    }
    Add-CheckResult -Name 'Ungueltige persistierte Network-Intents rufen keine Runtime oder Hyper-V-Providerpfade auf' `
        -Success ($persistedNetworkContract.RuntimeCalls -eq 0)

    $persistedDockerNetworkWhatIf = & $module {
        $resolved = Resolve-LabNetworkIntentPlan -Provider docker -Network ([PSCustomObject]@{ intent='nat'; exposure='host' })
        $network = [PSCustomObject]@{
            Intent=[string]$resolved.Intent; Exposure=[string]$resolved.Exposure; Binding=[string]$resolved.Binding
            ManagedBinding=([string]$resolved.Intent -ne 'isolated'); RequiredCapability=[string]$resolved.RequiredCapability
            CapabilityStatus='DECLARED_SUPPORTED'; PlanStatus=[string]$resolved.Status; ReasonCode=$resolved.ReasonCode
        }
        $previousWhatIfPreference = $WhatIfPreference
        try {
            $WhatIfPreference = $true
            Test-LabPersistedNetworkIntent -Network $network -Provider docker
        }
        finally {
            $WhatIfPreference = $previousWhatIfPreference
        }
    }
    Add-CheckResult -Name 'Kanonischer persistierter Docker-Network-Intent bleibt unter WhatIf gueltig' `
        -Success ($persistedDockerNetworkWhatIf -eq $true)

    $persistedSqlEndpointContract = & $module {
        param($Root)

        function New-TestPersistedSqlEndpointIntent {
            [PSCustomObject]@{
                Contract=[PSCustomObject]@{ Name='SqlServerLab.SqlEndpointIntent'; Version='1.0' }
                Protocol='tcp'; Port=[int]1433; RequiredCapability='hyperv-sql-port-reconcile'; CapabilityStatus='DECLARED_SUPPORTED'
            }
        }

        $cases = @(
            @{ Name='kanonisch'; Kind='valid'; Valid=$true },
            @{ Name='legacy fehlt'; Kind='legacy'; Valid=$true },
            @{ Name='legacy null'; Kind='null'; Valid=$true },
            @{ Name='boolescher Port'; Kind='bool-port'; Valid=$false },
            @{ Name='string Port'; Kind='string-port'; Valid=$false },
            @{ Name='Gleitkomma-Port'; Kind='float-port'; Valid=$false },
            @{ Name='Port ausserhalb des Bereichs'; Kind='range-port'; Valid=$false },
            @{ Name='falsches Protokoll'; Kind='protocol'; Valid=$false },
            @{ Name='falsche Capability'; Kind='capability'; Valid=$false },
            @{ Name='falscher CapabilityStatus'; Kind='status'; Valid=$false },
            @{ Name='unbekanntes Feld'; Kind='unknown-field'; Valid=$false },
            @{ Name='falscher Anbieter'; Kind='provider'; Valid=$false }
        )
        $originalRuntime = (Get-Command Get-LabRunRuntimeStatus).ScriptBlock
        $script:invalidPersistedSqlEndpointRuntimeCalls=0
        try {
            Set-Item Function:Get-LabRunRuntimeStatus -Value {
                $script:invalidPersistedSqlEndpointRuntimeCalls++
                throw 'RUNTIME_MUST_NOT_BE_READ_FOR_INVALID_PERSISTED_SQL_ENDPOINT'
            }
            $results=@($cases | ForEach-Object {
                $case=$_
                $intents=[PSCustomObject]@{ Contract=[PSCustomObject]@{ Name='SqlServerLab.InstanceIntent'; Version='1.0' } }
                if($case.Kind -ne 'legacy') {
                    $endpoint=if($case.Kind -eq 'null'){$null}else{New-TestPersistedSqlEndpointIntent}
                    switch($case.Kind) {
                        'bool-port' { $endpoint.Port=$true }
                        'string-port' { $endpoint.Port='1433' }
                        'float-port' { $endpoint.Port=[double]1433 }
                        'range-port' { $endpoint.Port=[int]65536 }
                        'protocol' { $endpoint.Protocol='TCP' }
                        'capability' { $endpoint.RequiredCapability='other-capability' }
                        'status' { $endpoint.CapabilityStatus='SUPPORTED' }
                        'unknown-field' { $endpoint | Add-Member -NotePropertyName Host -NotePropertyValue 'must-not-persist.invalid' }
                    }
                    $intents | Add-Member -NotePropertyName SqlEndpoint -NotePropertyValue $endpoint
                }
                $provider=if($case.Kind -eq 'provider'){'docker'}else{'hyperv'}
                $snapshot=[PSCustomObject]@{
                    Contract=[PSCustomObject]@{ Name='SqlServerLab.RunDesiredState'; Version='1.0' }
                    ProvisioningMode='manifest'; PersistentData=$false
                    Instances=@([PSCustomObject]@{ Id='primary'; Provider=$provider; Profile='standard'; Intents=$intents })
                }
                $run=New-LabRunState -StateRoot $Root -Metadata @{ name='persisted SQL endpoint intent'; desiredState=$snapshot } `
                    -ProviderSubRuns @([PSCustomObject]@{ provider=$provider; instanceIds=@('primary') })
                $statePath=Join-Path $run.RunDir 'run-state.json';$connectionPath=Join-Path $run.RunDir 'connection-info.json'
                Write-LabArtifactJsonAtomic -Path $connectionPath -InputObject ([PSCustomObject]@{instances=@([PSCustomObject]@{id='primary';provider=$provider;host='must-not-fallback.invalid'})})
                $beforeState=[Convert]::ToBase64String([IO.File]::ReadAllBytes($statePath))
                $beforeConnection=[Convert]::ToBase64String([IO.File]::ReadAllBytes($connectionPath))
                $persisted=Get-LabPersistedDesiredState -RunId $run.RunId -StateRoot $Root
                $plans=@()
                if(-not $case.Valid){foreach($target in @('RUNNING','STOPPED')){$plans+=Get-SqlServerLabReconcilePlan -RunId $run.RunId -TargetState $target -StateRoot $Root}}
                [PSCustomObject]@{Name=$case.Name;Valid=$case.Valid;Status=$persisted.Status;ReasonCodes=@($persisted.ReasonCodes);Plans=@($plans)
                    StateUnchanged=$beforeState -ceq [Convert]::ToBase64String([IO.File]::ReadAllBytes($statePath));ConnectionUnchanged=$beforeConnection -ceq [Convert]::ToBase64String([IO.File]::ReadAllBytes($connectionPath))}
            })
            [PSCustomObject]@{Cases=$results;RuntimeCalls=$script:invalidPersistedSqlEndpointRuntimeCalls}
        }
        finally {Set-Item Function:Get-LabRunRuntimeStatus -Value $originalRuntime}
    } $tempRoot
    foreach($sqlEndpointCase in @($persistedSqlEndpointContract.Cases)) {
        if($sqlEndpointCase.Valid) {
            Add-CheckResult -Name "Persistierter SQL-Endpoint-Intent ($($sqlEndpointCase.Name)) bleibt kanonisch oder legacy-gueltig" `
                -Success ($sqlEndpointCase.Status -eq 'VALID' -and $sqlEndpointCase.ReasonCodes.Count -eq 0)
        }
        else {
            Add-CheckResult -Name "Ungueltiger persistierter SQL-Endpoint-Intent ($($sqlEndpointCase.Name)) liefert den festen Grund" `
                -Success ($sqlEndpointCase.Status -eq 'INVALID' -and ($sqlEndpointCase.ReasonCodes -join ',') -ceq 'DESIRED_INSTANCE_SQL_ENDPOINT_INTENT_INVALID')
            foreach($plan in $sqlEndpointCase.Plans) {
                Add-CheckResult -Name "Ungueltiger persistierter SQL-Endpoint-Intent ($($sqlEndpointCase.Name)) blockiert $($plan.Desired.TargetState) ohne Runtime-Fallback" `
                    -Success ($plan.HighestChangeClass -eq 'unsupported' -and $plan.Actions.Count -eq 0 -and -not $plan.MutationAllowed -and
                        -not $plan.IsNoOp -and -not $plan.Desired.IsValid -and $plan.Desired.Instances.Count -eq 0 -and
                        $plan.Actual.Source -eq 'persisted-desired-state-invalid')
            }
        }
        Add-CheckResult -Name "Persistierter SQL-Endpoint-Intent ($($sqlEndpointCase.Name)) erhaelt State- und Connection-Bytes" `
            -Success ($sqlEndpointCase.StateUnchanged -and $sqlEndpointCase.ConnectionUnchanged)
    }
    Add-CheckResult -Name 'Ungueltige persistierte SQL-Endpoint-Intents rufen keine Runtime oder Hyper-V-Providerpfade auf' `
        -Success ($persistedSqlEndpointContract.RuntimeCalls -eq 0)

    $persistedSqlConfigurationContract = & $module {
        param($Root)

        function New-TestPersistedSqlConfigurationIntent {
            [PSCustomObject]@{
                Contract=[PSCustomObject]@{ Name='SqlServerLab.SqlConfigurationIntent'; Version='1.0' }
                Configurations=@([PSCustomObject]@{Name='max degree of parallelism';Value=[int]4})
                TraceFlags=@([int]3226)
                RequiredCapability='hyperv-sql-configuration-reconcile'
                CapabilityStatus='DECLARED_SUPPORTED'
            }
        }

        $cases = @(
            @{ Name='kanonisch'; Kind='valid'; Valid=$true },
            @{ Name='legacy fehlt'; Kind='legacy'; Valid=$true },
            @{ Name='legacy null'; Kind='null'; Valid=$true },
            @{ Name='unbekanntes Feld'; Kind='unknown-field'; Valid=$false },
            @{ Name='falscher Contract'; Kind='contract'; Valid=$false },
            @{ Name='unbekanntes Contract-Feld'; Kind='contract-field'; Valid=$false },
            @{ Name='Konfigurationen kein Array'; Kind='config-scalar'; Valid=$false },
            @{ Name='Konfiguration unbekanntes Feld'; Kind='config-field'; Valid=$false },
            @{ Name='Konfigurationsname ungueltig'; Kind='config-name'; Valid=$false },
            @{ Name='Konfigurationswert boolesch'; Kind='config-bool'; Valid=$false },
            @{ Name='Konfigurationswert String'; Kind='config-string'; Valid=$false },
            @{ Name='Konfigurationswert Gleitkomma'; Kind='config-double'; Valid=$false },
            @{ Name='Konfigurationswert Int32-Grenze'; Kind='config-int32-boundary'; Valid=$true },
            @{ Name='Konfigurationswert oberhalb Int32'; Kind='config-int32-overrange'; Valid=$false },
            @{ Name='Konfigurationswert UInt64-Ueberlauf'; Kind='config-uint64-overrange'; Valid=$false },
            @{ Name='Konfigurationsname doppelt'; Kind='config-duplicate'; Valid=$false },
            @{ Name='TraceFlags kein Array'; Kind='trace-scalar'; Valid=$false },
            @{ Name='TraceFlag boolesch'; Kind='trace-bool'; Valid=$false },
            @{ Name='TraceFlag String'; Kind='trace-string'; Valid=$false },
            @{ Name='TraceFlag Gleitkomma'; Kind='trace-double'; Valid=$false },
            @{ Name='TraceFlag null'; Kind='trace-null'; Valid=$false },
            @{ Name='TraceFlag nicht positiv'; Kind='trace-zero'; Valid=$false },
            @{ Name='TraceFlag oberhalb Int32'; Kind='trace-int32-overrange'; Valid=$false },
            @{ Name='TraceFlag UInt64-Ueberlauf'; Kind='trace-uint64-overflow'; Valid=$false },
            @{ Name='TraceFlag doppelt'; Kind='trace-duplicate'; Valid=$false },
            @{ Name='falsche Capability'; Kind='capability'; Valid=$false },
            @{ Name='falscher CapabilityStatus'; Kind='status'; Valid=$false },
            @{ Name='falscher Anbieter'; Kind='provider'; Valid=$false }
        )
        $originalRuntime = (Get-Command Get-LabRunRuntimeStatus).ScriptBlock
        $script:invalidPersistedSqlConfigurationRuntimeCalls=0
        try {
            Set-Item Function:Get-LabRunRuntimeStatus -Value {
                $script:invalidPersistedSqlConfigurationRuntimeCalls++
                throw 'RUNTIME_MUST_NOT_BE_READ_FOR_INVALID_PERSISTED_SQL_CONFIGURATION'
            }
            $results=@($cases | ForEach-Object {
                $case=$_
                $intents=[PSCustomObject]@{ Contract=[PSCustomObject]@{ Name='SqlServerLab.InstanceIntent'; Version='1.0' } }
                if($case.Kind -ne 'legacy') {
                    $configuration=if($case.Kind -eq 'null'){$null}else{New-TestPersistedSqlConfigurationIntent}
                    switch($case.Kind) {
                        'unknown-field' { $configuration | Add-Member -NotePropertyName Host -NotePropertyValue 'must-not-persist.invalid' }
                        'contract' { $configuration.Contract.Version='2.0' }
                        'contract-field' { $configuration.Contract | Add-Member -NotePropertyName Extra -NotePropertyValue 'invalid' }
                        'config-scalar' { $configuration.Configurations=$configuration.Configurations[0] }
                        'config-field' { $configuration.Configurations[0] | Add-Member -NotePropertyName Extra -NotePropertyValue 'invalid' }
                        'config-name' { $configuration.Configurations[0].Name='bad;name' }
                        'config-bool' { $configuration.Configurations[0].Value=$true }
                        'config-string' { $configuration.Configurations[0].Value='4' }
                        'config-double' { $configuration.Configurations[0].Value=[double]4 }
                        'config-int32-boundary' { $configuration.Configurations[0].Value=[long][int]::MaxValue }
                        'config-int32-overrange' { $configuration.Configurations[0].Value=[long]([int]::MaxValue + 1) }
                        'config-uint64-overrange' { $configuration.Configurations[0].Value=[uint64]::MaxValue }
                        'config-duplicate' { $configuration.Configurations+=,[PSCustomObject]@{Name='MAX DEGREE OF PARALLELISM';Value=[int]4} }
                        'trace-scalar' { $configuration.TraceFlags=$configuration.TraceFlags[0] }
                        'trace-bool' { $configuration.TraceFlags=@($true) }
                        'trace-string' { $configuration.TraceFlags=@('3226') }
                        'trace-double' { $configuration.TraceFlags=@([double]3226) }
                        'trace-null' { $configuration.TraceFlags=@($null) }
                        'trace-zero' { $configuration.TraceFlags=@([int]0) }
                        'trace-int32-overrange' { $configuration.TraceFlags=@([long]([int]::MaxValue + 1)) }
                        'trace-uint64-overflow' { $configuration.TraceFlags=@([uint64]::MaxValue) }
                        'trace-duplicate' { $configuration.TraceFlags=@([int]3226,[int]3226) }
                        'capability' { $configuration.RequiredCapability='other-capability' }
                        'status' { $configuration.CapabilityStatus='SUPPORTED' }
                    }
                    $intents | Add-Member -NotePropertyName SqlConfiguration -NotePropertyValue $configuration
                }
                $provider=if($case.Kind -eq 'provider'){'docker'}else{'hyperv'}
                $snapshot=[PSCustomObject]@{
                    Contract=[PSCustomObject]@{ Name='SqlServerLab.RunDesiredState'; Version='1.0' }
                    ProvisioningMode='manifest'; PersistentData=$false
                    Instances=@([PSCustomObject]@{ Id='primary'; Provider=$provider; Profile='standard'; Intents=$intents })
                }
                $run=New-LabRunState -StateRoot $Root -Metadata @{ name='persisted SQL configuration intent'; desiredState=$snapshot } `
                    -ProviderSubRuns @([PSCustomObject]@{ provider=$provider; instanceIds=@('primary') })
                $statePath=Join-Path $run.RunDir 'run-state.json';$connectionPath=Join-Path $run.RunDir 'connection-info.json'
                Write-LabArtifactJsonAtomic -Path $connectionPath -InputObject ([PSCustomObject]@{instances=@([PSCustomObject]@{id='primary';provider=$provider;host='must-not-fallback.invalid'})})
                $beforeState=[Convert]::ToBase64String([IO.File]::ReadAllBytes($statePath))
                $beforeConnection=[Convert]::ToBase64String([IO.File]::ReadAllBytes($connectionPath))
                $persisted=Get-LabPersistedDesiredState -RunId $run.RunId -StateRoot $Root
                $plans=@()
                if(-not $case.Valid){foreach($target in @('RUNNING','STOPPED')){$plans+=Get-SqlServerLabReconcilePlan -RunId $run.RunId -TargetState $target -StateRoot $Root}}
                [PSCustomObject]@{Name=$case.Name;Valid=$case.Valid;Status=$persisted.Status;ReasonCodes=@($persisted.ReasonCodes);Plans=@($plans)
                    StateUnchanged=$beforeState -ceq [Convert]::ToBase64String([IO.File]::ReadAllBytes($statePath));ConnectionUnchanged=$beforeConnection -ceq [Convert]::ToBase64String([IO.File]::ReadAllBytes($connectionPath))}
            })
            [PSCustomObject]@{Cases=$results;RuntimeCalls=$script:invalidPersistedSqlConfigurationRuntimeCalls}
        }
        finally {Set-Item Function:Get-LabRunRuntimeStatus -Value $originalRuntime}
    } $tempRoot
    foreach($sqlConfigurationCase in @($persistedSqlConfigurationContract.Cases)) {
        if($sqlConfigurationCase.Valid) {
            Add-CheckResult -Name "Persistierter SQL-Konfigurations-Intent ($($sqlConfigurationCase.Name)) bleibt kanonisch oder legacy-gueltig" `
                -Success ($sqlConfigurationCase.Status -eq 'VALID' -and $sqlConfigurationCase.ReasonCodes.Count -eq 0)
        }
        else {
            Add-CheckResult -Name "Ungueltiger persistierter SQL-Konfigurations-Intent ($($sqlConfigurationCase.Name)) liefert den festen Grund" `
                -Success ($sqlConfigurationCase.Status -eq 'INVALID' -and ($sqlConfigurationCase.ReasonCodes -join ',') -ceq 'DESIRED_INSTANCE_SQL_CONFIGURATION_INTENT_INVALID')
            foreach($plan in $sqlConfigurationCase.Plans) {
                Add-CheckResult -Name "Ungueltiger persistierter SQL-Konfigurations-Intent ($($sqlConfigurationCase.Name)) blockiert $($plan.Desired.TargetState) ohne Runtime-Fallback" `
                    -Success ($plan.HighestChangeClass -eq 'unsupported' -and $plan.Actions.Count -eq 0 -and -not $plan.MutationAllowed -and
                        -not $plan.IsNoOp -and -not $plan.Desired.IsValid -and $plan.Desired.Instances.Count -eq 0 -and
                        $plan.Actual.Source -eq 'persisted-desired-state-invalid')
            }
        }
        Add-CheckResult -Name "Persistierter SQL-Konfigurations-Intent ($($sqlConfigurationCase.Name)) erhaelt State- und Connection-Bytes" `
            -Success ($sqlConfigurationCase.StateUnchanged -and $sqlConfigurationCase.ConnectionUnchanged)
    }
    Add-CheckResult -Name 'Ungueltige persistierte SQL-Konfigurations-Intents rufen keine Runtime oder Hyper-V-Providerpfade auf' `
        -Success ($persistedSqlConfigurationContract.RuntimeCalls -eq 0)

    $networkContract = & $module {
        param($Root)

        $desiredSnapshot = [PSCustomObject]@{
            Contract=[PSCustomObject]@{ Name='SqlServerLab.RunDesiredState'; Version='1.0' }
            ProvisioningMode='manifest'; LabName='Hyper-V network reconcile'; PersistentData=$false
            Instances=@([PSCustomObject]@{
                Id='primary'; Provider='hyperv'; Version='2025'; Profile='standard'; DatabaseNames=@()
                Intents=[PSCustomObject]@{
                    Contract=[PSCustomObject]@{ Name='SqlServerLab.InstanceIntent'; Version='1.0' }
                    Network=[PSCustomObject]@{
                        Intent='hostOnly'; Exposure='host'; Binding='internal-switch'; ManagedBinding=$true
                        RequiredCapability='managed-lab-network'; CapabilityStatus='DECLARED_SUPPORTED'; PlanStatus='RESOLVED'; ReasonCode=$null
                    }
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
        $lanSnapshot.Instances[0].Intents.Network.ManagedBinding=$true; $lanSnapshot.Instances[0].Intents.Network.RequiredCapability='external-network-binding'
        $lanSnapshot.Instances[0].Intents.Network.CapabilityStatus='DECLARED_SUPPORTED'; $lanSnapshot.Instances[0].Intents.Network.PlanStatus='RESOLVED'; $lanSnapshot.Instances[0].Intents.Network.ReasonCode=$null
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
