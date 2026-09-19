#Requires -Version 7.2
<#
.SYNOPSIS
    Prueft den privaten deklarativen Instanz-Capability-Vertrag offline.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$failures = [Collections.Generic.List[string]]::new()
$passed = 0
. (Join-Path $PSScriptRoot '../Common/CheckResult.ps1')
Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force
$module = Get-Module SqlServerLab
try {
    $results = & $module {
        function New-AssessmentFixture {
            param($Provider='docker', $Os='linux', $Version='2022', $Drives=@(), $Software=@(), $Network=$null)
            $instance = [PSCustomObject]@{ id='fixture'; provider=$Provider; os=$Os; version=$Version; drives=$Drives; software=$Software; network=$Network; databases=@() }
            $capability = Get-LabProviderCapabilityContract | Where-Object Provider -eq $Provider
            New-LabInstanceIntentSnapshot -Instance $instance -ProviderCapability $capability
        }
        $checks = [ordered]@{}
        $baseline = (New-AssessmentFixture).CapabilityAssessment
        $checks['Docker Linux wird ausschliesslich deklarativ unterstuetzt'] = $baseline.Status -eq 'DECLARED_SUPPORTED' -and $baseline.Contract.EvidenceBoundary -eq 'catalog-and-provider-metadata'
        $checks['Podman besitzt eigenen Metadatenentscheid'] = (New-AssessmentFixture -Provider podman).CapabilityAssessment.Provider.Name -eq 'podman'
        $mixedCase = (New-AssessmentFixture -Provider Docker -Version '2022-cu26').CapabilityAssessment
        $checks['Bestehende gross-/kleinschreibungsunabhaengige Eingaben bleiben gueltig'] = $mixedCase.Provider.Name -ceq 'docker' -and $mixedCase.SqlVersion.Requested -ceq '2022-cu26' -and $mixedCase.SqlVersion.Status -eq 'SUPPORTED'
        $windows = (New-AssessmentFixture -Provider hyperv -Os windows).CapabilityAssessment
        $checks['Hyper-V Windows bindet die vorhandene Network-Capability'] = $windows.Status -eq 'DECLARED_SUPPORTED' -and $windows.Network.RequiredCapability -eq 'managed-lab-network'
        $unsupported = (New-AssessmentFixture -Os windows).CapabilityAssessment
        $checks['Nicht unterstuetztes OS/Providertuple liefert Blocker'] = $unsupported.Status -eq 'DECLARED_UNSUPPORTED' -and $unsupported.BlockerCodes -contains 'OS_PROVIDER_UNSUPPORTED'
        $unknown = (New-AssessmentFixture -Version '2099').CapabilityAssessment
        $checks['Unbekanntes SQL wird ohne erfundene Katalog-ID projektiert'] = $unknown.SqlVersion.Status -eq 'UNKNOWN' -and $null -eq $unknown.SqlVersion.CatalogVersionId -and $unknown.SqlVersion.Requested -eq '2099'
        $cu = (New-AssessmentFixture -Version '2022-CU26').CapabilityAssessment
        $checks['CU verwendet den bestehenden Katalogentscheid'] = $cu.SqlVersion.CatalogVersionId -eq '2022' -and $cu.SqlVersion.Status -eq 'SUPPORTED'
        $deprecated = (New-AssessmentFixture -Version '2017').CapabilityAssessment
        $checks['Deprecation bleibt ohne implizite Freigabe sichtbar'] = $deprecated.SqlVersion.Status -eq 'DEPRECATED' -and $deprecated.BlockerCodes -contains 'SQL_VERSION_POLICY_UNSUPPORTED'
        $absent = (New-AssessmentFixture -Version '').CapabilityAssessment
        $checks['Nicht angeforderte Dimensionen sind NOT_REQUESTED'] = $absent.SqlVersion.Status -eq 'NOT_REQUESTED' -and $absent.Storage.Status -eq 'NOT_REQUESTED' -and $absent.Software.Status -eq 'NOT_REQUESTED'
        $network = (New-AssessmentFixture -Network ([PSCustomObject]@{intent='isolated';exposure='none'})).CapabilityAssessment
        $checks['Deklarierte Einzelcapability ersetzt keinen Network-Tuplevertrag'] = $network.Network.Status -eq 'DECLARED_UNSUPPORTED' -and $network.Network.ReasonCode -eq 'NETWORK_INTENT_PROVIDER_UNSUPPORTED'
        $drives = @([PSCustomObject]@{id='data';hostPath='C:\synthetic-private';containerPath='/synthetic-guest'},[PSCustomObject]@{id='log';containerPath='/synthetic-log'})
        $software = @([PSCustomObject]@{id='sql-python'},[PSCustomObject]@{id='sql-r'})
        $first = (New-AssessmentFixture -Drives $drives -Software $software).CapabilityAssessment
        $second = (New-AssessmentFixture -Drives @($drives[1],$drives[0]) -Software @($software[1],$software[0])).CapabilityAssessment
        $checks['Mengenreihenfolge beeinflusst den Entscheid nicht'] = ($first | ConvertTo-Json -Depth 12 -Compress) -ceq ($second | ConvertTo-Json -Depth 12 -Compress)
        $checks['Software projiziert sortierte erforderliche Capabilities'] = $first.Software.Status -eq 'DECLARED_SUPPORTED' -and ($first.Software.RequiredCapabilities -join ',') -eq 'derived-image-build,software-catalog-planning,sql-external-runtime'
        $blocked = (New-AssessmentFixture -Software @([PSCustomObject]@{id='sql-python';variant='nonexistent'})).CapabilityAssessment
        $checks['Bestehender Softwareresolver bleibt autoritativ'] = $blocked.Software.Status -eq 'DECLARED_UNSUPPORTED' -and $blocked.Software.ReasonCodes -contains 'RUNTIME_COMBINATION_NOT_CATALOGUED'
        $checks['Assessment enthaelt keine Host-/Gastpfade oder freien Softwaredaten'] = ($first | ConvertTo-Json -Depth 12) -notmatch 'synthetic-|GuestPath|hostPath|PlanKey|ArtifactRefs|"Port"|"READY"'
        $injected = (New-AssessmentFixture -Version 'C:\synthetic-secret').CapabilityAssessment
        $checks['Freier SQL-Input wird nicht gespiegelt'] = $null -eq $injected.SqlVersion.Requested -and $injected.SqlVersion.Status -eq 'UNKNOWN'
        foreach ($case in @('extra','major','null','type','blocker','order','os','catalog','authority')) {
            $invalid = $baseline | ConvertTo-Json -Depth 12 | ConvertFrom-Json
            switch ($case) {
                extra { $invalid | Add-Member NoteProperty HostPath 'C:\synthetic-private' }
                major { $invalid.Contract.Version='2.0' }
                null { $invalid=$null }
                type { $invalid.Software.RequiredCapabilities='sql-external-runtime' }
                blocker { $invalid.BlockerCodes=@('SOFTWARE_UNSUPPORTED') }
                order { $invalid.Software.RequiredCapabilities=@('sql-external-runtime','derived-image-build') }
                os { $invalid.OperatingSystem.Name='windows' }
                catalog { $invalid.SqlVersion.CatalogVersionId=$null }
                authority { $invalid.Status='READY' }
            }
            $checks["Ungueltiger Assessment-Fall $case wird abgewiesen"] = -not (Test-LabInstanceCapabilityAssessment -Assessment $invalid)
        }
        # Der reale Reader wird mit synthetischem Run-Transport ausgefuehrt.
        $script:assessmentFixtureRun = [PSCustomObject]@{metadata=[PSCustomObject]@{desiredState=[PSCustomObject]@{Contract=[PSCustomObject]@{Name='SqlServerLab.RunDesiredState';Version='1.0'};Instances=@([PSCustomObject]@{Id='fixture';Provider='docker';Intents=[PSCustomObject]@{Contract=[PSCustomObject]@{Name='SqlServerLab.InstanceIntent';Version='1.0'}}})}}}
        $original = (Get-Command Get-LabRunState).ScriptBlock
        try {
            Set-Item Function:script:Get-LabRunState -Value { param($RunId,$StateRoot) $null=$RunId,$StateRoot; return $script:assessmentFixtureRun }
            $before = $script:assessmentFixtureRun | ConvertTo-Json -Depth 16 -Compress
            $legacy = Get-LabPersistedDesiredState -RunId 'synthetic' -StateRoot 'synthetic'
            $checks['Legacy ohne Assessment bleibt gueltig und unveraendert'] = $legacy.Status -eq 'VALID' -and $before -ceq ($script:assessmentFixtureRun | ConvertTo-Json -Depth 16 -Compress)
            $script:assessmentFixtureRun.metadata.desiredState.Instances[0].Intents | Add-Member NoteProperty CapabilityAssessment $baseline
            $checks['Persistierter Assessment-Vertrag wird gelesen'] = (Get-LabPersistedDesiredState -RunId 'synthetic' -StateRoot 'synthetic').Status -eq 'VALID'
            $baseline.Contract.Version='2.0'
            $before = $script:assessmentFixtureRun | ConvertTo-Json -Depth 16 -Compress
            $rejected = Get-LabPersistedDesiredState -RunId 'synthetic' -StateRoot 'synthetic'
            $checks['Neuer Major wird read-only als INVALID erkannt'] = $rejected.Status -eq 'INVALID' -and $rejected.Reason -eq 'INSTANCE_CAPABILITY_ASSESSMENT_INVALID' -and $before -ceq ($script:assessmentFixtureRun | ConvertTo-Json -Depth 16 -Compress)
        }
        finally { Set-Item Function:script:Get-LabRunState -Value $original; Remove-Variable assessmentFixtureRun -Scope Script }
        $script:capabilityLegacyManifest = [PSCustomObject]@{name='synthetic';instances=@(
            [PSCustomObject]@{id='target';provider='hyperv';version='2022';os='windows';profile='standard';drives=@();software=@();databases=@()},
            [PSCustomObject]@{id='other';provider='hyperv';version='2022';os='windows';profile='standard';drives=@();software=@();databases=@()}
        )}
        $legacySnapshot = New-LabDesiredStateSnapshot -ResolvedLab $script:capabilityLegacyManifest -ProvisioningMode manifest -PersistentData $false
        foreach ($entry in $legacySnapshot.Instances) { $entry.Intents.PSObject.Properties.Remove('CapabilityAssessment') }
        $legacyRebuild = New-LabDesiredStateSnapshot -ResolvedLab $script:capabilityLegacyManifest -ProvisioningMode manifest -PersistentData $false -PreviousSnapshot $legacySnapshot
        $checks['Target-Rebuild bewahrt Legacy-Abwesenheit ohne Retrofit'] = ($legacySnapshot | ConvertTo-Json -Depth 30 -Compress) -ceq ($legacyRebuild | ConvertTo-Json -Depth 30 -Compress)
        $freshSnapshot = New-LabDesiredStateSnapshot -ResolvedLab $script:capabilityLegacyManifest -ProvisioningMode manifest -PersistentData $false
        $freshRebuild = New-LabDesiredStateSnapshot -ResolvedLab $script:capabilityLegacyManifest -ProvisioningMode manifest -PersistentData $false -PreviousSnapshot $freshSnapshot
        $checks['Vorhandenes Assessment bleibt beim Target-Rebuild erhalten'] = $null -ne $freshRebuild.Instances[0].Intents.CapabilityAssessment
        $script:capabilityLegacyRun = [PSCustomObject]@{state='RUNNING';metadata=[PSCustomObject]@{workflowKind='hyperv-lab';desiredState=$legacySnapshot}}
        $originals = @{}
        $substitutes = @{
            'Get-LabRunState' = { param($RunId,$StateRoot) $null=$RunId,$StateRoot; $script:capabilityLegacyRun }
            'Read-LabManifest' = { param($Path) $null=$Path; $script:capabilityLegacyManifest }
            'Get-LabHyperVResourceMigrationLifecycleGuard' = { param($RunId,$StateRoot) $null=$RunId,$StateRoot; [PSCustomObject]@{Allowed=$true} }
            'Get-LabHyperVExternalRuntimeInstanceFingerprint' = { param($Instance) $null=$Instance; throw 'FIXTURE_OTHER_INSTANCE_ACCEPTED' }
            'Get-LabHyperVTestDatabaseInstanceFingerprint' = { param($Instance) $null=$Instance; throw 'FIXTURE_OTHER_INSTANCE_ACCEPTED' }
            'Get-LabHyperVSqlConfigurationInstanceFingerprint' = { param($Instance) $null=$Instance; throw 'FIXTURE_OTHER_INSTANCE_ACCEPTED' }
        }
        try {
            foreach ($entry in $substitutes.GetEnumerator()) {
                $originals[$entry.Key] = (Get-Command $entry.Key).ScriptBlock
                Set-Item "Function:script:$($entry.Key)" -Value $entry.Value
            }
            $before = $script:capabilityLegacyRun | ConvertTo-Json -Depth 30 -Compress
            foreach ($context in @('ExternalRuntime','TestDatabase','SqlConfiguration')) {
                $script:capabilityLegacyManifest.instances[1].profile='standard'
                $reason = ''
                try { & "Get-LabHyperV${context}ReconcileContext" -RunId 'synthetic' -InstanceId 'target' -ManifestPath 'synthetic' -StateRoot 'synthetic' } catch { $reason=$_.Exception.Message }
                $checks["Legacy-Nebeninstanz bleibt im echten $context-Kontext vergleichbar"] = $reason -eq 'FIXTURE_OTHER_INSTANCE_ACCEPTED'
                $script:capabilityLegacyManifest.instances[1].profile='performance'
                $reason = ''
                try { & "Get-LabHyperV${context}ReconcileContext" -RunId 'synthetic' -InstanceId 'target' -ManifestPath 'synthetic' -StateRoot 'synthetic' } catch { $reason=$_.Exception.Message }
                $checks["Echte Nebeninstanzdrift bleibt im $context-Kontext blockiert"] = $reason -like '*OTHER_INSTANCE_CHANGED*'
            }
            $checks['Legacy-Reconcile schreibt den bisherigen Snapshot nicht um'] = $before -ceq ($script:capabilityLegacyRun | ConvertTo-Json -Depth 30 -Compress)
        }
        finally {
            foreach ($entry in $originals.GetEnumerator()) { Set-Item "Function:script:$($entry.Key)" -Value $entry.Value }
            Remove-Variable capabilityLegacyManifest,capabilityLegacyRun -Scope Script
        }
        return $checks
    }
    foreach ($entry in $results.GetEnumerator()) { Add-CheckResult -Name $entry.Key -Success $entry.Value }
}
catch { Add-CheckResult -Name 'Assessment-Pruefung' -Success $false -Message $_.Exception.Message }
Write-Host "Instance Capability Assessment: $passed PASS, $($failures.Count) FAIL"
if ($failures.Count) { exit 1 }
