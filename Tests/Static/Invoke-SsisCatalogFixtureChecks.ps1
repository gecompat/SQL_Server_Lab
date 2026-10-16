#Requires -Version 7.2
[CmdletBinding()]param()
$ErrorActionPreference='Stop'
$repoRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$passed=0;$failed=0
function Check {param([string]$Name,[bool]$Success)if($Success){$script:passed++;Write-Host "PASS $Name"}else{$script:failed++;Write-Host "FAIL $Name"}}
$source=Get-Content -LiteralPath (Join-Path $repoRoot 'Public/New-SqlServerLabSsisCatalogFixture.ps1') -Raw
$componentSource=Get-Content -LiteralPath (Join-Path $repoRoot 'Public/Install-SqlServerLabSsisComponent.ps1') -Raw
$privateSource=Get-Content -LiteralPath (Join-Path $repoRoot 'Private/SsisOwnedInstall.ps1') -Raw
$componentInstallerStart=$privateSource.IndexOf('function Install-LabSsisExistingComponent')
$preparedFixtureStart=$privateSource.IndexOf('function Start-LabSsisOwnedProvisioningRun')
$componentInstallerSource=if($componentInstallerStart -ge 0 -and $preparedFixtureStart -gt $componentInstallerStart){$privateSource.Substring($componentInstallerStart,$preparedFixtureStart-$componentInstallerStart)}else{''}
$acceptanceSource=Get-Content -LiteralPath (Join-Path $repoRoot 'Tests/Integration/Invoke-SsisCatalogFixtureAcceptance.ps1') -Raw
$workflow=Get-Content -LiteralPath (Join-Path $repoRoot '.github/workflows/runtime-smoke-hyperv.yml') -Raw
$manifest=Get-Content -LiteralPath (Join-Path $repoRoot 'SqlServerLab.psd1') -Raw
Check 'Öffentliche SSIS-Cmdlets sind exportiert' ($manifest -match "'Install-SqlServerLabSsisComponent'" -and $manifest -match "'New-SqlServerLabSsisCatalogFixture'" -and $manifest -match "'Remove-SqlServerLabSsisCatalogFixture'")
Check 'Komponentenpfad bindet vorhandenen Run, wartet auf das ISO und installiert nur IS ohne Beschaffung' ($componentSource -match 'Install-LabSsisExistingComponent' -and $componentSource -match 'SupportsShouldProcess' -and $privateSource -match "'/FEATURES=IS'" -and $privateSource -match 'mediaDeadline' -and $privateSource -match 'SSIS_COMPONENT_SETUP_START_FAILED' -and $privateSource -match 'SSIS_COMPONENT_INSTALL_LAUNCHED' -and $privateSource -match 'Get-LabSsisComponentGuestInstallStatus' -and $privateSource -notmatch '(?i)(Invoke-WebRequest|Start-BitsTransfer|winget|choco|Install-Module)')
Check 'Komponentenpfad bindet den bereits laufenden vorhandenen Run vor DVD- und Gastsetup erneut, ohne seinen Lebenszyklus zu starten' ($componentInstallerSource -match 'Get-LabSsisPrerequisiteContext' -and $componentInstallerSource -match 'Invoke-LabSsisPrerequisite' -and $componentInstallerSource -match 'Get-HyperVManagedVM' -and $componentInstallerSource -match '\$context\.Instance\.vmId' -and $componentInstallerSource -match 'SSIS_COMPONENT_VM_BINDING_UNAVAILABLE' -and $componentInstallerSource -notmatch 'Start-HyperVLabEnvironment' -and $componentInstallerSource -match 'Restart-VM' -and $componentInstallerSource -match 'Get-LabSsisInstallGuestProbe')
Check 'Fixture-Cmdlet trennt neuen Prepared-Run und gebundenen vorhandenen Run' ($source -match "ParameterSetName='NewRun'" -and $source -match "ParameterSetName='ExistingRun'" -and $source -match 'Invoke-LabSsisExistingCatalogFixture' -and $source -match 'Invoke-LabSsisPreparedFixtureRun')
Check 'Neuer Run verlangt Prepared-Artifact, gebundene Medienidentität und ShouldProcess' ($source -match 'SupportsShouldProcess' -and $source -match 'hyperv-sql-prepared-sealed' -and $source -match 'ExpectedSqlMediaSha256')
Check 'Neuer Prepared-Run wird vor dem additiven IS-Installer ohne erneute Aktivierungsreconcile eigentumsgebunden gestartet' ($privateSource -match 'Start-HyperVLabEnvironment -RunId \$runId\.ToString\(\) -SkipWindowsActivationReconcile -StateRoot \$StateRoot')
Check 'Prepared-Run wartet nach dem Start auf die gebundene Running-VM, bevor Medien angehängt werden' ($privateSource -match 'SSIS_FIXTURE_VM_START_TIMEOUT' -and $privateSource -match 'Get-HyperVManagedVM -VMName \(\[string\]\$startedLab\.Instance\.vmName\)' -and $privateSource -match 'AddSeconds\(60\)')
Check 'Öffentliche Receipt enthält keine Verbindungs- oder Secretfelder' ($source -match 'ConnectionBinding=\[string\]\$fixture.SourceBinding' -and $source -notmatch '(?i)(Password\s*=|Credential\s*=|Endpoint\s*=|ConnectionString\s*=)')
Check 'Fixture-Cleanup unterscheidet vollständigen Prepared-Run und retained vorhandenen Run' ($source -match 'REMOVE_RUN_TO_CLEANUP' -and $source -match 'REMOVE_OWNED_FIXTURE_TO_CLEANUP' -and $privateSource -match 'Remove-LabSsisExistingCatalogFixture')
Check 'Remote-Acceptance nutzt ausschließlich den öffentlichen Fixture- und Cleanupvertrag' ($acceptanceSource -match 'New-SqlServerLabSsisCatalogFixture' -and $acceptanceSource -match 'Remove-SqlServerLab' -and $acceptanceSource -notmatch '(?i)(Invoke-WebRequest|Start-BitsTransfer|winget|choco|Install-Module)')
Check 'Remote-Acceptance prüft reale Katalogviews, drei Falltypen und Cleanup' ($acceptanceSource -match 'catalog\.executions' -and $acceptanceSource -match 'catalog\.event_messages' -and $acceptanceSource -match 'ExecutionStatus\.Success' -and $acceptanceSource -match 'ExecutionStatus\.Failure' -and $acceptanceSource -match 'ExecutionStatus\.Incomplete' -and $acceptanceSource -match 'CLEANUP_SUCCEEDED')
Check 'Hyper-V-Runner verlangt eine vertrauenswürdige manuelle SSIS-Dispatch-Quelle' ($workflow -match "ssisdb-fixture-acceptance" -and $workflow -match 'SSISDB_FIXTURE_MANUAL_DISPATCH_REQUIRED' -and $workflow -match 'SSISDB_FIXTURE_EXPLICIT_ARTIFACT_REQUIRED' -and $workflow -match 'SSISDB_FIXTURE_EXPLICIT_MEDIA_HASH_REQUIRED')
$module=Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru
$command=Get-Command -Module $module.Name -Name New-SqlServerLabSsisCatalogFixture -ErrorAction SilentlyContinue
Check 'Geladenes Modul veröffentlicht Component-, Fixture- und gezielten Cleanup-Cmdlet' ($null -ne $command -and $command.Parameters.ContainsKey('RunId') -and $command.Parameters.ContainsKey('WhatIf') -and $command.Parameters.ContainsKey('Confirm') -and $null -ne (Get-Command -Module $module.Name -Name Install-SqlServerLabSsisComponent -ErrorAction SilentlyContinue) -and $null -ne (Get-Command -Module $module.Name -Name Remove-SqlServerLabSsisCatalogFixture -ErrorAction SilentlyContinue))
$manifestCases=& $module {
    $json=Get-Content (Join-Path $script:ModuleRoot 'Schemas/example-ssis-catalog-fixture.json') -Raw
    $valid=(Test-LabManifestSchema -Json $json).IsValid
    $value=$json|ConvertFrom-Json
    $base=Join-Path ([IO.Path]::GetTempPath()) 'synthetic-ssis-manifest'
    $resolved=Resolve-ManifestDefaults -Manifest $value -ManifestPath (Join-Path $base 'lab.json')
    $values=@{Schema=$valid;Root=($resolved.instances[0].ssisCatalogFixture.mediaRoot -eq [IO.Path]::GetFullPath((Join-Path $base '../local-media')))}
    foreach($mode in @('linux','old-engine','multiple','extra-field')){
        $item=$json|ConvertFrom-Json
        switch($mode){
            linux{$item.instances[0].provider='docker';$item.instances[0].os='linux'}
            'old-engine'{$item.instances[0].version='2022'}
            multiple{$item.instances+=($json|ConvertFrom-Json).instances[0]}
            'extra-field'{$item.instances[0].ssisCatalogFixture|Add-Member -NotePropertyName password -NotePropertyValue 'SYNTHETIC_FORBIDDEN'}
        }
        $blocked=$false
        try {
            if(-not (Test-LabManifestSchema -Json ($item|ConvertTo-Json -Depth 30)).IsValid){throw 'SCHEMA_REJECTED'}
            $null=Resolve-ManifestDefaults -Manifest $item -ManifestPath (Join-Path $base 'lab.json')
        } catch {$blocked=$true}
        $values[$mode]=$blocked
    }
    $values
}
Check 'SSIS-Manifestbeispiel wird wirklich validiert und relativ zum Manifest aufgelöst' ($manifestCases.Schema -and $manifestCases.Root)
foreach($mode in @('linux','old-engine','multiple','extra-field')){Check "SSIS-Manifest lehnt vor Mutation ab: $mode" $manifestCases[$mode]}
. (Join-Path $repoRoot 'Private/SsisOwnedInstall.ps1')
$transactionCases=& {
    $values=@{}
    $ownedId=[guid]'11111111-1111-1111-1111-111111111111'
    function Start-LabSsisOwnedProvisioningRun {param($RunId,$StateRoot) $events.Add('start');if($RunId -ne $ownedId){throw 'WRONG_RUN'}}
    function Install-SqlServerLabSsisComponent {[CmdletBinding(SupportsShouldProcess)]param($RunId,$InstanceId,$StateRoot,$MediaRoot,$SqlMediaPath,$ExpectedSqlMediaSha256) $events.Add('component');if($mode -eq 'component'){throw 'SYNTHETIC_COMPONENT'}}
    function New-SqlServerLabSsisCatalogFixture {[CmdletBinding(SupportsShouldProcess)]param($RunId,$InstanceId,$StateRoot) $events.Add('fixture');if($mode -in @('fixture','both')){throw 'SYNTHETIC_FIXTURE'};[pscustomobject]@{Status='READY'}}
    function Remove-SqlServerLab {[CmdletBinding(SupportsShouldProcess)]param($RunId,$StateRoot,[switch]$Force) if($RunId -ne $ownedId){throw 'WRONG_CLEANUP_RUN'};$events.Add('cleanup');if($mode -eq 'both'){throw 'SYNTHETIC_CLEANUP'}}
    foreach($mode in @('success','component','fixture','both')){
        $events=[Collections.Generic.List[string]]::new();$caught=$null;$result=$null
        try {$result=Invoke-LabSsisManifestProvision -RunId $ownedId -InstanceId primary -StateRoot synthetic -Intent ([pscustomobject]@{mediaRoot='synthetic';sqlMediaPath='synthetic.iso';expectedSqlMediaSha256=('a'*64)})}catch{$caught=$_}
        $values[$mode]=[pscustomobject]@{Events=($events -join ',');Result=$result;Error=$caught}
    }
    $values
}
Check 'Manifest führt genau Komponenten- und Fixturepfad in Reihenfolge aus' ($transactionCases.success.Events -eq 'start,component,fixture' -and $transactionCases.success.Result.Status -eq 'READY')
Check 'Manifest kompensiert Komponenten- und Fixturefehler ausschließlich am eigenen Run' ($transactionCases.component.Events -eq 'start,component,cleanup' -and $transactionCases.fixture.Events -eq 'start,component,fixture,cleanup')
Check 'Manifest bewahrt Primärfehler und getrennten Cleanup-/Recoverybedarf' ($transactionCases.both.Error.Exception.Message -eq 'SYNTHETIC_FIXTURE' -and $transactionCases.both.Error.Exception.Data['CleanupFailure'] -eq 'SSIS_MANIFEST_RUN_CLEANUP_FAILED' -and $transactionCases.both.Error.Exception.Data['RunId'] -eq '11111111-1111-1111-1111-111111111111')
Write-Host "SSIS CATALOG FIXTURE CHECKS: $passed PASS, $failed FAIL; native NOT_EXECUTED"
if($failed){exit 1}
