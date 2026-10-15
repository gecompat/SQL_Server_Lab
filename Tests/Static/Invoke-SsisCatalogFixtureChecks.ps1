#Requires -Version 7.2
[CmdletBinding()]param()
$ErrorActionPreference='Stop'
$repoRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$passed=0;$failed=0
function Check {param([string]$Name,[bool]$Success)if($Success){$script:passed++;Write-Host "PASS $Name"}else{$script:failed++;Write-Host "FAIL $Name"}}
$source=Get-Content -LiteralPath (Join-Path $repoRoot 'Public/New-SqlServerLabSsisCatalogFixture.ps1') -Raw
$componentSource=Get-Content -LiteralPath (Join-Path $repoRoot 'Public/Install-SqlServerLabSsisComponent.ps1') -Raw
$privateSource=Get-Content -LiteralPath (Join-Path $repoRoot 'Private/SsisOwnedInstall.ps1') -Raw
$acceptanceSource=Get-Content -LiteralPath (Join-Path $repoRoot 'Tests/Integration/Invoke-SsisCatalogFixtureAcceptance.ps1') -Raw
$workflow=Get-Content -LiteralPath (Join-Path $repoRoot '.github/workflows/runtime-smoke-hyperv.yml') -Raw
$manifest=Get-Content -LiteralPath (Join-Path $repoRoot 'SqlServerLab.psd1') -Raw
Check 'Öffentliche SSIS-Cmdlets sind exportiert' ($manifest -match "'Install-SqlServerLabSsisComponent'" -and $manifest -match "'New-SqlServerLabSsisCatalogFixture'" -and $manifest -match "'Remove-SqlServerLabSsisCatalogFixture'")
Check 'Komponentenpfad bindet vorhandenen Run und installiert nur IS ohne Beschaffung' ($componentSource -match 'Install-LabSsisExistingComponent' -and $componentSource -match 'SupportsShouldProcess' -and $privateSource -match "'/FEATURES=IS'" -and $privateSource -notmatch '(?i)(Invoke-WebRequest|Start-BitsTransfer|winget|choco|Install-Module)')
Check 'Komponentenpfad startet und wartet auf den gebundenen vorhandenen Run vor DVD- und Gastsetup' ($privateSource -match 'Get-LabSsisPrerequisiteContext' -and $privateSource -match 'Invoke-LabSsisPrerequisite' -and $privateSource -match 'Start-HyperVLabEnvironment -RunId \$RunId\.ToString\(\) -SkipWindowsActivationReconcile -StateRoot \$StateRoot' -and $privateSource -match 'SSIS_COMPONENT_VM_START_TIMEOUT' -and $privateSource -match 'Get-HyperVManagedVM' -and $privateSource -match 'Restart-VM' -and $privateSource -match 'Get-LabSsisInstallGuestProbe')
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
Write-Host "SSIS CATALOG FIXTURE CHECKS: $passed PASS, $failed FAIL; native NOT_EXECUTED"
if($failed){exit 1}
