#Requires -Version 7.2
<#
.SYNOPSIS
    Verifies fail-closed rehydration of persisted software-intent projections.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$modulePath = Join-Path $repoRoot 'SqlServerLab.psd1'
$containerSource = Get-Content -LiteralPath (Join-Path $repoRoot 'Private\ExternalRuntimeReconcile.ps1') -Raw -Encoding utf8
$hyperVSource = Get-Content -LiteralPath (Join-Path $repoRoot 'Private\HyperVExternalRuntimeReconcile.ps1') -Raw -Encoding utf8
$failures = [System.Collections.Generic.List[string]]::new()
$passed = 0
. (Join-Path $PSScriptRoot '..' 'Common' 'CheckResult.ps1')

Write-Host ''
Write-Host 'SQL_Server_Lab - Persisted Software Intent Checks' -ForegroundColor Cyan
Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
$module = Import-Module $modulePath -Force -PassThru
$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-persisted-software-' + [guid]::NewGuid().ToString('N'))

try {
    $result = & $module {
        param($Root)

        function New-TestSoftwareDesiredState {
            param([ValidateSet('docker','hyperv')][string]$Provider, [switch]$IncludeServerConfig, [double]$Cpu=4)
            $instance = [pscustomobject]@{
                id='primary'; provider=$Provider; os=$(if($Provider -eq 'hyperv'){'windows'}else{'linux'})
                version='2022'; profile='standard'; autostart='off'; databases=@(); drives=@(); networkName=$null
                hyperv=$null; serverConfig=$(if($IncludeServerConfig){[pscustomobject]@{maxDop=4}}else{$null})
                runtimeResources=[pscustomobject]@{cpu=$Cpu;memoryMB=4096}; collation='SQL_Latin1_General_CP1_CI_AS'
                software=@([pscustomobject]@{ id='sql-python'; version=$null; variant=$null; scope='sqlExternalRuntime'; installMethod='catalog'; packages=@(); optional=$false; requestSource='software' })
            }
            New-LabDesiredStateSnapshot -ResolvedLab ([pscustomobject]@{name="persisted-software-$Provider";instances=@($instance)}) -ProvisioningMode manifest -PersistentData:$false
        }

        function New-TestSoftwareRun {
            param($Desired, [string]$Provider, [string]$WorkflowKind)
            $run = New-LabRunState -StateRoot $Root -Metadata @{name='persisted software';workflowKind=$WorkflowKind;desiredState=$Desired} -ProviderSubRuns @([pscustomobject]@{provider=$Provider;instanceIds=@('primary')})
            $statePath = Join-Path $run.RunDir 'run-state.json'
            $state = Get-Content -LiteralPath $statePath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 50
            $state.state = 'RUNNING'
            Write-LabArtifactJsonAtomic -Path $statePath -InputObject $state
            return $run
        }

        $dockerDesired = New-TestSoftwareDesiredState docker
        $hyperVDesired = New-TestSoftwareDesiredState hyperv
        $genericContainerRuntime = New-LabContainerRuntimeIntentSnapshot -Instance ([pscustomobject]@{provider='docker';version=$null;profile='standard'})
        $genericVersionedContainerRuntime = New-LabContainerRuntimeIntentSnapshot -Instance ([pscustomobject]@{provider='docker';version='2022';profile='standard';collation='sql_latin1_general_cp1_ci_as'})
        $whitespaceVersionContainerRuntime = New-LabContainerRuntimeIntentSnapshot -Instance ([pscustomobject]@{provider='docker';version='   ';profile='standard'})
        $unknownVersionContainerRuntime = New-LabContainerRuntimeIntentSnapshot -Instance ([pscustomobject]@{provider='docker';version='2099';profile='standard'}) -ParserAuthorizedRuntime
        $deprecatedVersionMessage = ''
        try {
            $null = New-LabContainerRuntimeIntentSnapshot -Instance ([pscustomobject]@{provider='docker';version='2017';profile='standard';collation='sql_latin1_general_cp1_ci_as'}) -ParserAuthorizedRuntime
        }
        catch { $deprecatedVersionMessage = $_.Exception.Message }
        $knownContainerRuntime = New-LabContainerRuntimeIntentSnapshot -Instance ([pscustomobject]@{provider='docker';version='2022';profile='standard';collation='sql_latin1_general_cp1_ci_as'}) -ParserAuthorizedRuntime
        $invalidCollationMessage = ''
        try {
            $null = New-LabContainerRuntimeIntentSnapshot -Instance ([pscustomobject]@{provider='docker';version='2022';profile='standard';collation='Not_A_Collation'}) -ParserAuthorizedRuntime
        }
        catch { $invalidCollationMessage = $_.Exception.Message }
        $dockerConfigurationDesired = New-TestSoftwareDesiredState docker -IncludeServerConfig
        $dockerFractionalDesired = New-TestSoftwareDesiredState docker -Cpu 1.5
        $dockerHundredthsDesired = New-TestSoftwareDesiredState docker -Cpu 1.23
        $dockerRun = New-TestSoftwareRun $dockerDesired docker 'container-lab'
        $hyperVRun = New-TestSoftwareRun $hyperVDesired hyperv 'hyperv-lab'
        $dockerPersisted = Get-LabPersistedDesiredState -RunId $dockerRun.RunId -StateRoot $Root
        $hyperVPersisted = Get-LabPersistedDesiredState -RunId $hyperVRun.RunId -StateRoot $Root
        $dockerInstance = $dockerPersisted.Snapshot.Instances[0]
        $hyperVInstance = $hyperVPersisted.Snapshot.Instances[0]
        $dockerCapability = @(Get-LabProviderCapabilityContract | Where-Object Provider -eq 'docker')[0]
        $hyperVCapability = @(Get-LabProviderCapabilityContract | Where-Object Provider -eq 'hyperv')[0]
        $dockerPersistedPlans = @(Resolve-LabValidatedPersistedSoftwarePlans -Software $dockerInstance.Intents.Software -Instance $dockerInstance -ProviderCapability $dockerCapability)
        $hyperVPersistedPlans = @(Resolve-LabValidatedPersistedSoftwarePlans -Software $hyperVInstance.Intents.Software -Instance $hyperVInstance -ProviderCapability $hyperVCapability)
        $dockerConfigurationRun = New-TestSoftwareRun $dockerConfigurationDesired docker 'container-lab'
        $dockerConfigurationPersisted = Get-LabPersistedDesiredState -RunId $dockerConfigurationRun.RunId -StateRoot $Root
        $dockerFractionalRun = New-TestSoftwareRun $dockerFractionalDesired docker 'container-lab'
        $dockerFractionalPersisted = Get-LabPersistedDesiredState -RunId $dockerFractionalRun.RunId -StateRoot $Root
        $dockerHundredthsRun = New-TestSoftwareRun $dockerHundredthsDesired docker 'container-lab'
        $dockerHundredthsPersisted = Get-LabPersistedDesiredState -RunId $dockerHundredthsRun.RunId -StateRoot $Root
        $dockerInvalidCpu = $dockerDesired | ConvertTo-Json -Depth 50 | ConvertFrom-Json -Depth 50
        $dockerInvalidCpu.Instances[0].Intents.ContainerRuntime.Cpu = 1.234
        $dockerInvalidCpuRun = New-TestSoftwareRun $dockerInvalidCpu docker 'container-lab'
        $dockerInvalidCpuPersisted = Get-LabPersistedDesiredState -RunId $dockerInvalidCpuRun.RunId -StateRoot $Root
        $dockerConfigurationTampered = $dockerConfigurationDesired | ConvertTo-Json -Depth 50 | ConvertFrom-Json -Depth 50
        $dockerConfigurationTampered.Instances[0].Intents.SqlConfiguration.CapabilityStatus = 'DECLARED_SUPPORTED'
        $dockerConfigurationTamperedRun = New-TestSoftwareRun $dockerConfigurationTampered docker 'container-lab'
        $dockerConfigurationTamperedPersisted = Get-LabPersistedDesiredState -RunId $dockerConfigurationTamperedRun.RunId -StateRoot $Root

        $legacyMissing = $dockerDesired | ConvertTo-Json -Depth 50 | ConvertFrom-Json -Depth 50
        $legacyMissing.Instances[0].Intents.PSObject.Properties.Remove('Software')
        $legacyNull = $dockerDesired | ConvertTo-Json -Depth 50 | ConvertFrom-Json -Depth 50
        $legacyNull.Instances[0].Intents.Software = $null

        $mutations = @(
            @{Name='unknown-envelope-field'; Apply={param($d) $d.Instances[0].Intents.Software | Add-Member NoteProperty InstallerUrl 'https://invalid.example/installer'}},
            @{Name='duplicate-item'; Apply={param($d) $copy=$d.Instances[0].Intents.Software.Items[0]|ConvertTo-Json -Depth 30|ConvertFrom-Json -Depth 30; $d.Instances[0].Intents.Software.Items=@($d.Instances[0].Intents.Software.Items)+@($copy)}},
            @{Name='item-id'; Apply={param($d) $d.Instances[0].Intents.Software.Items[0].Id='sql-java'}},
            @{Name='plan-key'; Apply={param($d) $d.Instances[0].Intents.Software.Items[0].PlanKey=('a'*64)}},
            @{Name='capability-status'; Apply={param($d) $d.Instances[0].Intents.Software.CapabilityStatus='DECLARED_UNSUPPORTED'}},
            @{Name='artifact-relation'; Apply={param($d) $d.Instances[0].Intents.Software.Items[0].ArtifactRefs[0].Sha256=('b'*64)}},
            @{Name='package-relation'; Apply={param($d) $d.Instances[0].Intents.Software.Items[0].PackageLocks[0].Version='0.0.0'}},
            @{Name='restart-relation'; Apply={param($d) $d.Instances[0].Intents.Software.Items[0].Restart.sqlServer=$false}},
            @{Name='validation-relation'; Apply={param($d) $d.Instances[0].Intents.Software.Items[0].Validation.probeId='free-probe'}},
            @{Name='secret-field'; Apply={param($d) $d.Instances[0].Intents.Software.Items[0] | Add-Member NoteProperty CredentialRef 'secret'}}
        )
        $invalid = foreach($mutation in $mutations) {
            $desired = $dockerDesired | ConvertTo-Json -Depth 50 | ConvertFrom-Json -Depth 50
            & $mutation.Apply $desired
            $run = New-TestSoftwareRun $desired docker 'container-lab'
            $runDirectory = $run.RunDir
            $connectionPath = Join-Path $runDirectory 'connection-info.json'
            Write-LabArtifactJsonAtomic -Path $connectionPath -InputObject ([pscustomobject]@{instances=@([pscustomobject]@{id='primary';provider='docker';host='must-not-be-read'})})
            $beforeState = Get-Content -LiteralPath (Join-Path $runDirectory 'run-state.json') -Raw -Encoding utf8
            $beforeConnection = Get-Content -LiteralPath $connectionPath -Raw -Encoding utf8
            $persisted = Get-LabPersistedDesiredState -RunId $run.RunId -StateRoot $Root
            $message = ''
            try { Get-LabExternalRuntimeReconcileContext -RunId $run.RunId -ManifestPath (Join-Path $Root 'must-not-be-read.json') -InstanceId primary -StateRoot $Root | Out-Null } catch { $message=$_.Exception.Message }
            [pscustomobject]@{Name=$mutation.Name;Persisted=$persisted;Message=$message;StateUnchanged=($beforeState -ceq (Get-Content -LiteralPath (Join-Path $runDirectory 'run-state.json') -Raw -Encoding utf8));ConnectionUnchanged=($beforeConnection -ceq (Get-Content -LiteralPath $connectionPath -Raw -Encoding utf8))}
        }

        $hyperVInvalid = $hyperVDesired | ConvertTo-Json -Depth 50 | ConvertFrom-Json -Depth 50
        $hyperVInvalid.Instances[0].Intents.Software.Items[0].PlanKey=('c'*64)
        $hyperVInvalidRun = New-TestSoftwareRun $hyperVInvalid hyperv 'hyperv-lab'
        $hyperVConnectionPath = Join-Path $hyperVInvalidRun.RunDir 'connection-info.json'
        Write-LabArtifactJsonAtomic -Path $hyperVConnectionPath -InputObject ([pscustomobject]@{instances=@([pscustomobject]@{id='primary';provider='hyperv';vmName='must-not-be-read'})})
        $beforeHyperVState = Get-Content -LiteralPath (Join-Path $hyperVInvalidRun.RunDir 'run-state.json') -Raw -Encoding utf8
        $beforeHyperVConnection = Get-Content -LiteralPath $hyperVConnectionPath -Raw -Encoding utf8
        $hyperVMessage = ''
        try { Get-LabHyperVExternalRuntimeReconcileContext -RunId $hyperVInvalidRun.RunId -ManifestPath (Join-Path $Root 'must-not-be-read.json') -InstanceId primary -StateRoot $Root | Out-Null } catch { $hyperVMessage=$_.Exception.Message }

        [pscustomobject]@{
            DockerCanonical=$dockerPersisted; HyperVCanonical=$hyperVPersisted
            GenericContainerRuntime=$genericContainerRuntime; GenericVersionedContainerRuntime=$genericVersionedContainerRuntime; WhitespaceVersionContainerRuntime=$whitespaceVersionContainerRuntime
            UnknownVersionContainerRuntime=$unknownVersionContainerRuntime; DeprecatedVersionMessage=$deprecatedVersionMessage; KnownContainerRuntime=$knownContainerRuntime
            InvalidCollationMessage=$invalidCollationMessage
            DockerPersistedPlans=$dockerPersistedPlans; HyperVPersistedPlans=$hyperVPersistedPlans
            DockerConfigurationCanonical=$dockerConfigurationPersisted; DockerConfigurationTampered=$dockerConfigurationTamperedPersisted
            DockerFractional=$dockerFractionalPersisted
            DockerHundredths=$dockerHundredthsPersisted; DockerInvalidCpu=$dockerInvalidCpuPersisted
            LegacyMissing=(New-TestSoftwareRun $legacyMissing docker 'container-lab'); LegacyNull=(New-TestSoftwareRun $legacyNull docker 'container-lab')
            Invalid=@($invalid); HyperVMessage=$hyperVMessage
            HyperVStateUnchanged=($beforeHyperVState -ceq (Get-Content -LiteralPath (Join-Path $hyperVInvalidRun.RunDir 'run-state.json') -Raw -Encoding utf8))
            HyperVConnectionUnchanged=($beforeHyperVConnection -ceq (Get-Content -LiteralPath $hyperVConnectionPath -Raw -Encoding utf8))
        }
    } $temporaryRoot

    $legacyMissing = & $module { param($run,$root) Get-LabPersistedDesiredState -RunId $run.RunId -StateRoot $root } $result.LegacyMissing $temporaryRoot
    $legacyNull = & $module { param($run,$root) Get-LabPersistedDesiredState -RunId $run.RunId -StateRoot $root } $result.LegacyNull $temporaryRoot
    Add-CheckResult -Name 'Katalog-erzeugte Software-Snapshots überstehen Docker- und Hyper-V-JSON-Roundtrip' -Success ($result.DockerCanonical.Status -eq 'VALID' -and $result.HyperVCanonical.Status -eq 'VALID')
    Add-CheckResult -Name 'Nicht parserautorisierte sowie leerzeichenhafte oder unkatalogisierte Container-Snapshots erzeugen keinen Runtime-Intent; die autorisierte 2022-Version normalisiert die Collation' -Success (
        $null -eq $result.GenericContainerRuntime -and $null -eq $result.GenericVersionedContainerRuntime -and $null -eq $result.WhitespaceVersionContainerRuntime -and $null -eq $result.UnknownVersionContainerRuntime -and
        [string]$result.KnownContainerRuntime.Collation -eq 'SQL_Latin1_General_CP1_CI_AS')
    Add-CheckResult -Name 'Katalogisierte deprecated und bekannte Container-Versionen propagieren Collation-Katalogfehler' -Success (
        $result.DeprecatedVersionMessage -match '^SQL_COLLATION_VERSION_NOT_CATALOGED' -and $result.InvalidCollationMessage -match '^SQL_COLLATION_NOT_CATALOGED')
    Add-CheckResult -Name 'Persistierte Software-Projektion rehydriert Container- und Hyper-V-PlanKeys ohne Manifestinput' -Success (
        (@($result.DockerPersistedPlans.PlanKey) -join ',') -ceq (@($result.DockerCanonical.Snapshot.Instances[0].Intents.Software.Items.PlanKey) -join ',') -and
        (@($result.HyperVPersistedPlans.PlanKey) -join ',') -ceq (@($result.HyperVCanonical.Snapshot.Instances[0].Intents.Software.Items.PlanKey) -join ','))
    Add-CheckResult -Name 'Fractional Container-CPU bleibt ueber Persistenz und JSON-Roundtrip exakt gebunden' -Success (
        $result.DockerFractional.Status -eq 'VALID' -and
        [double]$result.DockerFractional.Snapshot.Instances[0].Intents.ContainerRuntime.Cpu -eq 1.5)
    Add-CheckResult -Name 'Container-CPU akzeptiert exakt zwei Dezimalstellen und blockiert 1.234 vor Providerzugriff' -Success (
        $result.DockerHundredths.Status -eq 'VALID' -and [double]$result.DockerHundredths.Snapshot.Instances[0].Intents.ContainerRuntime.Cpu -eq 1.23 -and
        $result.DockerInvalidCpu.Status -eq 'INVALID' -and $result.DockerInvalidCpu.ReasonCodes -contains 'DESIRED_INSTANCE_CONTAINER_RUNTIME_INTENT_INVALID')
    Add-CheckResult -Name 'Docker-SQL-Konfigurationsstatus bleibt an die deklarierte Provider-Capability gebunden' -Success (
        $result.DockerConfigurationCanonical.Status -eq 'VALID' -and
        $result.DockerConfigurationTampered.Status -eq 'INVALID' -and
        (@($result.DockerConfigurationTampered.ReasonCodes) -join ',') -ceq 'DESIRED_INSTANCE_SQL_CONFIGURATION_INTENT_INVALID')
    Add-CheckResult -Name 'Fehlende oder null Software bleibt fuer Legacy-Snapshots zulaessig' -Success ($legacyMissing.Status -eq 'VALID' -and $legacyNull.Status -eq 'VALID')
    Add-CheckResult -Name 'Manipulierte Software-Projection bleibt mit festem Grund vor Container-Target und Journal blockiert' -Success (@($result.Invalid).Count -eq 10 -and @($result.Invalid | Where-Object { $_.Persisted.Status -ne 'INVALID' -or @($_.Persisted.ReasonCodes) -cne @('DESIRED_INSTANCE_SOFTWARE_INTENT_INVALID') -or $_.Message -notmatch '^EXTERNAL_RUNTIME_RECONCILE_DESIRED_STATE_INVALID' -or -not $_.StateUnchanged -or -not $_.ConnectionUnchanged }).Count -eq 0)
    Add-CheckResult -Name 'Manipulierte Software-Projection bleibt vor Hyper-V-VM, Connection und Journal blockiert' -Success ($result.HyperVMessage -match '^HYPERV_EXTERNAL_RUNTIME_RECONCILE_DESIRED_STATE_INVALID' -and $result.HyperVStateUnchanged -and $result.HyperVConnectionUnchanged)
    $containerContextSource = $containerSource.Substring($containerSource.IndexOf('function Get-LabExternalRuntimeReconcileContext'))
    $hyperVContextSource = $hyperVSource.Substring($hyperVSource.IndexOf('function Get-LabHyperVExternalRuntimeReconcileContext'))
    Add-CheckResult -Name 'Beide External-Runtime-Reconcilepfade validieren Persistenz vor Connection und Hyper-V-Migrationsguard' -Success (
        $containerContextSource.IndexOf('Get-LabPersistedDesiredState') -lt $containerContextSource.IndexOf("Get-Content -LiteralPath `$connectionPath") -and
        $hyperVContextSource.IndexOf('Get-LabPersistedDesiredState') -lt $hyperVContextSource.IndexOf('Get-LabHyperVResourceMigrationLifecycleGuard') -and
        $hyperVContextSource.IndexOf('Get-LabPersistedDesiredState') -lt $hyperVContextSource.IndexOf("Get-Content -LiteralPath `$connectionPath"))
    Add-CheckResult -Name 'External-Runtime-Consumer verwenden beidseitig die validierte persistierte Software-Projektion mit Legacy-Fallback' -Success (
        $containerContextSource -match 'Resolve-LabValidatedPersistedSoftwarePlans -Software \$persistedSoftware' -and
        $hyperVContextSource -match 'Resolve-LabValidatedPersistedSoftwarePlans -Software \$persistedSoftware' -and
        $containerContextSource -match 'Historical snapshots have no software envelope' -and
        $hyperVContextSource -match 'Legacy snapshots predate the closed software envelope')
    Add-CheckResult -Name 'Persistierte Software-Envelopes sperren Apply- und State-Commit gegen nachtraegliche Manifest-Runtimewerte' -Success (
        $containerContextSource -match '\$runtimeResourceGovernorConfig = if \(\$hasPersistedSoftware\) \{ \$null \}' -and
        $containerContextSource -match '\$stateCommitSnapshot = if \(\$hasPersistedSoftware\) \{ \$persisted\.Snapshot \}' -and
        $containerContextSource -match 'ResourceGovernorConfig \$context\.RuntimeResourceGovernorConfig' -and
        $containerContextSource -notmatch 'ResourceGovernorConfig \$context\.ResolvedInstance\.serverConfig' -and
        $containerContextSource -match '\$runtimeInstance\.PSObject\.Properties\.Remove\(''software''\)' -and
        $containerContextSource -match '\$runtimeInstance\.PSObject\.Properties\.Remove\(''serverConfig''\)' -and
        $containerContextSource -match '-ResolvedInstance \$context\.RuntimeInstance' -and
        $containerContextSource -match 'EXTERNAL_RUNTIME_RECONCILE_CONTAINER_RUNTIME_INTENT_MISSING' -and
        $containerContextSource -match 'NotePropertyName collation -NotePropertyValue \(\[string\]\$containerRuntime\.Collation\)' -and
        $containerContextSource -match 'NotePropertyName runtimeResources -NotePropertyValue \(\[PSCustomObject\]@\{ cpu=\[double\]\$containerRuntime\.Cpu; memoryMB=\[int\]\$containerRuntime\.MemoryMB \}\)' -and
        $hyperVContextSource -match '\$runtimeResourceGovernorConfig = if \(\$hasPersistedSoftware\) \{ \$null \}' -and
        $hyperVContextSource -match '\$stateCommitSnapshot = if \(\$hasPersistedSoftware\) \{ \$persisted\.Snapshot \}' -and
        $hyperVContextSource -match 'ResourceGovernorConfig \$context\.RuntimeResourceGovernorConfig' -and
        $hyperVContextSource -notmatch 'ResourceGovernorConfig \$context\.ResolvedInstance\.serverConfig')
}
finally {
    if (Test-Path -LiteralPath $temporaryRoot) { Remove-Item -LiteralPath $temporaryRoot -Recurse -Force }
}

if ($failures.Count -gt 0) {
    Write-Host "`nErgebnis: $passed PASS, $($failures.Count) FAIL" -ForegroundColor Red
    foreach ($failure in $failures) { Write-Host "  - $failure" -ForegroundColor Red }
    exit 1
}

Write-Host "`nErgebnis: $passed PASS, 0 FAIL" -ForegroundColor Green
exit 0
