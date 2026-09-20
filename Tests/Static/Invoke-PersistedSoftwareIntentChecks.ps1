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
            param([ValidateSet('docker','hyperv')][string]$Provider, [switch]$IncludeServerConfig)
            $instance = [pscustomobject]@{
                id='primary'; provider=$Provider; os=$(if($Provider -eq 'hyperv'){'windows'}else{'linux'})
                version='2022'; profile='standard'; autostart='off'; databases=@(); drives=@(); networkName=$null
                hyperv=$null; serverConfig=$(if($IncludeServerConfig){[pscustomobject]@{maxDop=4}}else{$null})
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
        $dockerConfigurationDesired = New-TestSoftwareDesiredState docker -IncludeServerConfig
        $dockerRun = New-TestSoftwareRun $dockerDesired docker 'container-lab'
        $hyperVRun = New-TestSoftwareRun $hyperVDesired hyperv 'hyperv-lab'
        $dockerPersisted = Get-LabPersistedDesiredState -RunId $dockerRun.RunId -StateRoot $Root
        $hyperVPersisted = Get-LabPersistedDesiredState -RunId $hyperVRun.RunId -StateRoot $Root
        $dockerConfigurationRun = New-TestSoftwareRun $dockerConfigurationDesired docker 'container-lab'
        $dockerConfigurationPersisted = Get-LabPersistedDesiredState -RunId $dockerConfigurationRun.RunId -StateRoot $Root
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
            DockerConfigurationCanonical=$dockerConfigurationPersisted; DockerConfigurationTampered=$dockerConfigurationTamperedPersisted
            LegacyMissing=(New-TestSoftwareRun $legacyMissing docker 'container-lab'); LegacyNull=(New-TestSoftwareRun $legacyNull docker 'container-lab')
            Invalid=@($invalid); HyperVMessage=$hyperVMessage
            HyperVStateUnchanged=($beforeHyperVState -ceq (Get-Content -LiteralPath (Join-Path $hyperVInvalidRun.RunDir 'run-state.json') -Raw -Encoding utf8))
            HyperVConnectionUnchanged=($beforeHyperVConnection -ceq (Get-Content -LiteralPath $hyperVConnectionPath -Raw -Encoding utf8))
        }
    } $temporaryRoot

    $legacyMissing = & $module { param($run,$root) Get-LabPersistedDesiredState -RunId $run.RunId -StateRoot $root } $result.LegacyMissing $temporaryRoot
    $legacyNull = & $module { param($run,$root) Get-LabPersistedDesiredState -RunId $run.RunId -StateRoot $root } $result.LegacyNull $temporaryRoot
    Add-CheckResult -Name 'Katalog-erzeugte Software-Snapshots überstehen Docker- und Hyper-V-JSON-Roundtrip' -Success ($result.DockerCanonical.Status -eq 'VALID' -and $result.HyperVCanonical.Status -eq 'VALID')
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
