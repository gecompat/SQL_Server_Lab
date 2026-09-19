#Requires -Version 7.2
<#
.SYNOPSIS
    Prueft Assessment, explizite Entscheidungen und lokale Persistenz offline.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$failures = [System.Collections.Generic.List[string]]::new()
$passed = 0
. (Join-Path $PSScriptRoot '../Common/CheckResult.ps1')
Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force
$module = Get-Module SqlServerLab
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-assessment-' + [guid]::NewGuid().ToString('N'))

try {
    $policy = & $module {
        $cases = @()
        foreach ($status in @('RESOURCE_OK','RESOURCE_WARNING','RESOURCE_INSUFFICIENT_OVERRIDABLE','RESOURCE_HARD_BLOCK')) {
            foreach ($allow in @($false,$true)) {
                $assessment = [PSCustomObject]@{
                    Status=$status; Timestamp='2026-09-19T12:00:00Z'
                    Details=@([PSCustomObject]@{ Category='RAM'; Status=$status; Message='synthetic-host-value'; Value=@{ FreeMB=1024; RequiredMB=4096 } })
                }
                $before = $assessment | ConvertTo-Json -Depth 20 -Compress
                $record = New-LabResourceAssessmentRecord -Assessment $assessment -AllowResourceOvercommit:$allow
                Assert-LabResourceAssessmentRecord -Record $record
                $cases += [PSCustomObject]@{ Status=$status; Allow=$allow; Record=$record; Unchanged=($before -ceq ($assessment | ConvertTo-Json -Depth 20 -Compress)) }
            }
        }
        [PSCustomObject]@{
            Cases=$cases
            Skip=(New-LabResourceAssessmentRecord -SkipAssessment)
            SkipAllow=(New-LabResourceAssessmentRecord -SkipAssessment -AllowResourceOvercommit)
        }
    }
    foreach ($case in $policy.Cases) {
        $expectedAllowed = $case.Status -in @('RESOURCE_OK','RESOURCE_WARNING') -or ($case.Status -eq 'RESOURCE_INSUFFICIENT_OVERRIDABLE' -and $case.Allow)
        $expectedExecution = if ($case.Status -eq 'RESOURCE_INSUFFICIENT_OVERRIDABLE' -and $case.Allow) { 'OVERRIDDEN' } else { 'EXECUTED' }
        Add-CheckResult -Name "Entscheid $($case.Status), Opt-in $($case.Allow)" -Success (
            $case.Record.Allowed -eq $expectedAllowed -and $case.Record.Execution -eq $expectedExecution -and $case.Unchanged -and
            $case.Record.Assessment.Details[0].Status -eq $case.Status)
    }
    Add-CheckResult -Name 'Skip bleibt ungeprueft, auch mit ungenutztem Overcommit-Opt-in' -Success (
        $policy.Skip.Execution -eq 'SKIPPED' -and $policy.SkipAllow.Execution -eq 'SKIPPED' -and
        $null -eq $policy.Skip.Assessment -and $policy.Skip.Status -eq 'NOT_EXECUTED')

    $aggregation = & $module {
        function Test-ProviderAvailability {
            param($Provider)
            [PSCustomObject]@{ Category='Provider'; Status=if($Provider -eq 'podman'){'RESOURCE_HARD_BLOCK'}else{'RESOURCE_OK'}; Message='synthetic'; Value=$null }
        }
        function Test-RamAvailability { [PSCustomObject]@{ Category='RAM'; Status='RESOURCE_INSUFFICIENT_OVERRIDABLE'; Message='synthetic'; Value=1234 } }
        function Test-StorageAvailability { [PSCustomObject]@{ Category='Storage'; Status='RESOURCE_WARNING'; Message='synthetic'; Value=1234 } }
        function Test-PortAvailability { [PSCustomObject]@{ Category='Ports'; Status='RESOURCE_OK'; Message='synthetic'; Value=1 } }
        $ram = Test-SqlServerLabPrerequisite -Provider docker
        $mixed = Test-SqlServerLabPrerequisite -Provider docker,podman
        $mixedRecord = New-LabResourceAssessmentRecord -Assessment $mixed -AllowResourceOvercommit
        function Test-PortAvailability { [PSCustomObject]@{ Category='Ports'; Status='RESOURCE_HARD_BLOCK'; Message='synthetic'; Value=0 } }
        $ports = Test-SqlServerLabPrerequisite -Provider docker
        [PSCustomObject]@{ Ram=$ram; Mixed=$mixed; MixedRecord=$mixedRecord; Ports=$ports }
    }
    Add-CheckResult -Name 'RAM-Unterversorgung erreicht unveraendert den Gesamtstatus' -Success ($aggregation.Ram.Status -eq 'RESOURCE_INSUFFICIENT_OVERRIDABLE')
    Add-CheckResult -Name 'Ein blockierter Provider blockiert den gesamten Multi-Provider-Run trotz Opt-in' -Success (
        $aggregation.Mixed.Status -eq 'RESOURCE_HARD_BLOCK' -and -not $aggregation.MixedRecord.Allowed -and $aggregation.Mixed.Details[0].Category -eq 'Provider/docker')
    Add-CheckResult -Name 'Port-Hardsperre hat Vorrang vor RAM-Unterversorgung' -Success ($aggregation.Ports.Status -eq 'RESOURCE_HARD_BLOCK')

    $portScope = & $module {
        function Test-ProviderAvailability { [PSCustomObject]@{Category='Provider';Status='RESOURCE_OK';Message='synthetic';Value=$null} }
        function Test-RamAvailability { [PSCustomObject]@{Category='RAM';Status='RESOURCE_OK';Message='synthetic';Value=$null} }
        function Test-StorageAvailability { [PSCustomObject]@{Category='Storage';Status='RESOURCE_OK';Message='synthetic';Value=$null} }
        $script:assessmentFixturePortProbes = 0
        function Test-PortAvailability {
            param($Instances)
            $script:assessmentFixturePortProbes++
            [PSCustomObject]@{Category='Ports';Status='RESOURCE_HARD_BLOCK';Message='Synthetisch belegter Container-Hostport';Value=@{Available=0;Required=$Instances.Count}}
        }
        $vm = Test-SqlServerLabPrerequisite -Provider hyperv -Instances @([PSCustomObject]@{provider='hyperv'})
        $vmDefault = Test-SqlServerLabPrerequisite -Provider hyperv
        $vmProfile = Test-SqlServerLabPrerequisite -Provider hyperv -Instances @([PSCustomObject]@{profile='standard'})
        $vmProbes = $script:assessmentFixturePortProbes
        $container = Test-SqlServerLabPrerequisite -Provider docker -Instances @([PSCustomObject]@{provider='docker'})
        $mixed = Test-SqlServerLabPrerequisite -Provider docker,hyperv -Instances @([PSCustomObject]@{provider='docker'},[PSCustomObject]@{provider='hyperv'})
        [PSCustomObject]@{Vm=$vm;VmDefault=$vmDefault;VmProfile=$vmProfile;VmProbes=$vmProbes;Container=$container;Mixed=$mixed}
    }
    Add-CheckResult -Name 'Belegte Container-Hostports sperren kein reines Hyper-V-Assessment' -Success (
        $portScope.Vm.Status -eq 'RESOURCE_OK' -and $portScope.VmDefault.Status -eq 'RESOURCE_OK' -and $portScope.VmProfile.Status -eq 'RESOURCE_OK' -and $portScope.VmProbes -eq 0)
    Add-CheckResult -Name 'Containerport-Sperre bleibt aktiv; Mischmenge zaehlt nur Containerbedarf' -Success (
        $portScope.Container.Status -eq 'RESOURCE_HARD_BLOCK' -and $portScope.Mixed.Status -eq 'RESOURCE_HARD_BLOCK' -and
        @($portScope.Mixed.Details | Where-Object Category -eq 'Ports')[0].Value.Required -eq 1)

    $records = & $module {
        param($Root,$Record)
        $snapshot = New-LabDesiredStateSnapshot -ResolvedLab ([PSCustomObject]@{
            name='assessment-fixture'; instances=@([PSCustomObject]@{ id='primary'; provider='docker'; version='2025'; profile='standard'; databases=@(); drives=@() })
        }) -ProvisioningMode adhoc -PersistentData $false
        $snapshotBefore = $snapshot | ConvertTo-Json -Depth 30 -Compress
        $created = New-LabRunState -StateRoot $Root -Metadata @{ desiredState=$snapshot; resourceAssessment=$Record }
        $path = Join-Path $created.RunDir 'run-state.json'
        $before = [IO.File]::ReadAllBytes($path)
        $state = Get-LabRunState -RunId $created.RunId -StateRoot $Root
        $view = New-LabDesiredState -Run $state -TargetState RUNNING -StateRoot $Root
        $valid = Get-LabPersistedDesiredState -RunId $created.RunId -StateRoot $Root
        $legacy = New-LabRunState -StateRoot $Root
        $legacyPath = Join-Path $legacy.RunDir 'run-state.json'
        $legacyBefore = [IO.File]::ReadAllBytes($legacyPath)
        $legacyState = Get-LabRunState -RunId $legacy.RunId -StateRoot $Root
        $legacyView = New-LabDesiredState -Run $legacyState -TargetState STOPPED -StateRoot $Root
        $invalid = $state | ConvertTo-Json -Depth 30 | ConvertFrom-Json -Depth 30
        $invalid.metadata.resourceAssessment.ReasonCode = 'SENSITIVE_HOST_VALUE'
        [PSCustomObject]@{
            Persisted=$state.metadata.resourceAssessment
            View=$view; DesiredValid=$valid.Status
            SnapshotUnchanged=($snapshotBefore -ceq ($snapshot | ConvertTo-Json -Depth 30 -Compress))
            BytesUnchanged=([Convert]::ToBase64String($before) -ceq [Convert]::ToBase64String([IO.File]::ReadAllBytes($path)))
            Legacy=$legacyView.ResourceAssessment
            LegacyUnchanged=([Convert]::ToBase64String($legacyBefore) -ceq [Convert]::ToBase64String([IO.File]::ReadAllBytes($legacyPath)))
            Invalid=(Get-LabResourceAssessmentSummary -Run $invalid)
        }
    } $tempRoot $policy.Cases[5].Record
    Add-CheckResult -Name 'Vollstaendige Messung und Override werden lokal persistiert' -Success (
        $records.Persisted.Execution -eq 'OVERRIDDEN' -and $records.Persisted.Assessment.Details[0].Value.FreeMB -eq 1024)
    Add-CheckResult -Name 'Projektion bleibt hostwertfrei und Desired-Snapshot 1.0 unveraendert gueltig' -Success (
        $records.View.ResourceAssessment.Execution -eq 'OVERRIDDEN' -and $records.DesiredValid -eq 'VALID' -and $records.SnapshotUnchanged -and
        ($records.View | ConvertTo-Json -Depth 30) -notmatch 'synthetic-host-value|FreeMB|1024|RequiredMB')
    Add-CheckResult -Name 'Read-only Projektion und Legacy-Erkennung sind byteidentisch' -Success (
        $records.BytesUnchanged -and $records.LegacyUnchanged -and $records.Legacy.RecordStatus -eq 'NOT_RECORDED_LEGACY')
    Add-CheckResult -Name 'Ungueltiger Record gibt keine Rohwerte aus' -Success (
        $records.Invalid.RecordStatus -eq 'INVALID_RECORD' -and ($records.Invalid | ConvertTo-Json) -notmatch 'SENSITIVE_HOST_VALUE')
    foreach ($invalidValue in @($null,$false,0,'',@{},'synthetic-invalid-record')) {
        $invalidSummary = & $module {
            param($Value)
            Get-LabResourceAssessmentSummary -Run ([PSCustomObject]@{metadata=[PSCustomObject]@{resourceAssessment=$Value}})
        } $invalidValue
        Add-CheckResult -Name "Vorhandener ungueltiger Record bleibt INVALID_RECORD: $($invalidValue | ConvertTo-Json -Compress)" -Success ($invalidSummary.RecordStatus -eq 'INVALID_RECORD')
    }

    $manifestResult = & $module {
        $manifest = [PSCustomObject]@{ name='assessment-fixture'; instances=@([PSCustomObject]@{id='primary';version='2025';provider='docker'}); resourceOverrides=[PSCustomObject]@{allowResourceOvercommit=$true;skipAssessment=$false} }
        $valid = Test-LabManifestSchema -Json ($manifest | ConvertTo-Json -Depth 10)
        $resolved = Resolve-ManifestDefaults -Manifest $manifest
        $resolvedOverrides = $resolved.resourceOverrides | ConvertTo-Json | ConvertFrom-Json
        $manifest.resourceOverrides.allowResourceOvercommit = 'true'
        $invalid = Test-LabManifestSchema -Json ($manifest | ConvertTo-Json -Depth 10)
        [PSCustomObject]@{Valid=$valid.IsValid; Invalid=$invalid.IsValid; Resolved=$resolvedOverrides}
    }
    Add-CheckResult -Name 'Manifest erlaubt nur boolesches Opt-in und behaelt Skip separat' -Success (
        $manifestResult.Valid -and -not $manifestResult.Invalid -and $manifestResult.Resolved.allowResourceOvercommit -eq $true -and $manifestResult.Resolved.skipAssessment -eq $false)

    foreach ($provider in @('docker','podman','hyperv')) {
        foreach ($mode in @('EXECUTED','SKIPPED','OVERRIDDEN','BLOCKED','HARD_BLOCK')) {
            $creation = & $module {
                param($Root,$ProviderName,$Mode)
                $originalNewRun = (Get-Command New-LabRunState).ScriptBlock
                $script:assessmentFixtureState = $null
                $script:assessmentFixtureProbes = 0
                function Test-SqlServerLabPrerequisite {
                    $script:assessmentFixtureProbes++
                    $status=if($Mode -eq 'HARD_BLOCK'){'RESOURCE_HARD_BLOCK'}elseif($Mode -in @('OVERRIDDEN','BLOCKED')){'RESOURCE_INSUFFICIENT_OVERRIDABLE'}else{'RESOURCE_OK'}
                    [PSCustomObject]@{ Status=$status; Timestamp='2026-09-19T12:00:00Z'; Details=@([PSCustomObject]@{Category='RAM';Status=$status;Message='synthetic';Value=1024}) }
                }
                function New-LabRunState {
                    param($StateRoot,$Metadata,$ProviderSubRuns)
                    $created = & $originalNewRun -StateRoot $StateRoot -Metadata $Metadata -ProviderSubRuns $ProviderSubRuns
                    $script:assessmentFixtureState = Get-LabRunState -RunId $created.RunId -StateRoot $StateRoot
                    throw 'ASSESSMENT_FIXTURE_STATE_BOUNDARY'
                }
                function Test-HyperVAvailable { [PSCustomObject]@{Available=$true} }
                function Get-HyperVImageArtifact { [PSCustomObject]@{artifactId='assessment-fixture';artifactState='SQL_PREPARED_SEALED';sql=[PSCustomObject]@{version='2025';edition='Developer'}} }
                function Get-HyperVManifestFallbackArtifactSelection { [PSCustomObject]@{Selected=(Get-HyperVImageArtifact)} }
                function Test-HyperVImageArtifactEvaluationEligibility { [PSCustomObject]@{Eligible=$true} }
                function Test-HyperVImageArtifactChildValidationEligibility { [PSCustomObject]@{Eligible=$true} }
                function Assert-LabWindowsLocaleImageCapability { }
                function Resolve-LabHyperVNetworkBoundPlan { [PSCustomObject]@{Status='READY';Name='synthetic-network'} }
                function Invoke-LabHyperVNetworkBoundPlan { throw 'UNEXPECTED_PROVIDER_MUTATION' }
                function New-HyperVInstance { throw 'UNEXPECTED_PROVIDER_MUTATION' }
                function New-DockerInstance { throw 'UNEXPECTED_PROVIDER_MUTATION' }
                function New-PodmanInstance { throw 'UNEXPECTED_PROVIDER_MUTATION' }
                function Read-LabManifest {
                    Resolve-ManifestDefaults -Manifest ([PSCustomObject]@{
                        name='assessment-fixture'; instances=@([PSCustomObject]@{id='primary';version='2025';provider='hyperv';os='windows'})
                        resourceOverrides=[PSCustomObject]@{allowResourceOvercommit=($Mode -in @('OVERRIDDEN','HARD_BLOCK'));skipAssessment=($Mode -eq 'SKIPPED')}
                    })
                }
                $password = New-HyperVSqlUnattendedPassword
                $arguments=@{ Version='2025';Provider=$ProviderName;SaPassword=$password;GuestPassword=$password;StateRoot=$Root;NonInteractive=$true }
                if ($ProviderName -eq 'hyperv') {
                    $arguments.Remove('Version'); $arguments.Remove('Provider'); $arguments.Manifest='synthetic-assessment-manifest.json'
                }
                if($ProviderName -ne 'hyperv' -and $Mode -eq 'SKIPPED'){$arguments.SkipAssessment=$true}
                if($ProviderName -ne 'hyperv' -and $Mode -in @('OVERRIDDEN','HARD_BLOCK')){$arguments.AllowResourceOvercommit=$true}
                $errorCode=$null
                try { $null=New-SqlServerLab @arguments } catch { $errorCode=$_.Exception.Message }
                [PSCustomObject]@{State=$script:assessmentFixtureState; Probes=$script:assessmentFixtureProbes; Error=$errorCode}
            } $tempRoot $provider $mode
            if ($mode -eq 'HARD_BLOCK') {
                Add-CheckResult -Name "$provider harte Sperre verhindert State trotz Opt-in" -Success (
                    $null -eq $creation.State -and $creation.Error -match 'RESOURCE_HARD_BLOCK') -Message $creation.Error
            }
            elseif ($mode -eq 'BLOCKED') {
                Add-CheckResult -Name "$provider Unterversorgung blockiert vor State und Provider" -Success (
                    $null -eq $creation.State -and $creation.Error -match 'RESOURCE_OVERCOMMIT_REQUIRES_OPT_IN') -Message $creation.Error
            }
            else {
                Add-CheckResult -Name "$provider $mode persistiert vor erster Providermutation" -Success (
                    $creation.Error -eq 'ASSESSMENT_FIXTURE_STATE_BOUNDARY' -and $creation.State.metadata.resourceAssessment.Execution -eq $mode -and
                    $creation.Probes -eq $(if($mode -eq 'SKIPPED'){0}else{1})) -Message $creation.Error
            }
        }
    }
}
finally {
    $resolvedTemp = [IO.Path]::GetFullPath($tempRoot)
    $allowedParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if ($resolvedTemp.StartsWith($allowedParent, [StringComparison]::OrdinalIgnoreCase) -and (Split-Path $resolvedTemp -Leaf) -like 'sql-lab-assessment-*' -and (Test-Path -LiteralPath $resolvedTemp)) {
        Remove-Item -LiteralPath $resolvedTemp -Recurse -Force
    }
}
Write-Host "Ergebnis: $passed PASS, $($failures.Count) FAIL"
if ($failures.Count) { exit 1 }
exit 0
