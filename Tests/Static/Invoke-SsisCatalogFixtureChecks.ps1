#Requires -Version 7.2
[CmdletBinding()]param()
$ErrorActionPreference='Stop'
$repoRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$passed=0;$failed=0
function Check {param([string]$Name,[bool]$Success)if($Success){$script:passed++;Write-Host "PASS $Name"}else{$script:failed++;Write-Host "FAIL $Name"}}
$source=Get-Content -LiteralPath (Join-Path $repoRoot 'Public/New-SqlServerLabSsisCatalogFixture.ps1') -Raw
$componentSource=Get-Content -LiteralPath (Join-Path $repoRoot 'Public/Install-SqlServerLabSsisComponent.ps1') -Raw
$privateSource=Get-Content -LiteralPath (Join-Path $repoRoot 'Private/SsisOwnedInstall.ps1') -Raw
$manifest=Get-Content -LiteralPath (Join-Path $repoRoot 'SqlServerLab.psd1') -Raw
Check 'Öffentliche SSIS-Cmdlets sind exportiert' ($manifest -match "'Install-SqlServerLabSsisComponent'" -and $manifest -match "'New-SqlServerLabSsisCatalogFixture'" -and $manifest -match "'Remove-SqlServerLabSsisCatalogFixture'")
Check 'Komponentenpfad bindet vorhandenen Run und installiert nur IS ohne Beschaffung' ($componentSource -match 'Install-LabSsisExistingComponent' -and $componentSource -match 'SupportsShouldProcess' -and $privateSource -match "'/FEATURES=IS'" -and $privateSource -notmatch '(?i)(Invoke-WebRequest|Start-BitsTransfer|winget|choco|Install-Module)')
Check 'Komponentenpfad prüft Bindung vor DVD- und Gastsetup und verifiziert Neustart' ($privateSource -match 'Get-LabSsisPrerequisiteContext' -and $privateSource -match 'Invoke-LabSsisPrerequisite' -and $privateSource -match 'Get-HyperVManagedVM' -and $privateSource -match 'Restart-VM' -and $privateSource -match 'Get-LabSsisInstallGuestProbe')
Check 'Fixture-Cmdlet trennt neuen Prepared-Run und gebundenen vorhandenen Run' ($source -match "ParameterSetName='NewRun'" -and $source -match "ParameterSetName='ExistingRun'" -and $source -match 'Invoke-LabSsisExistingCatalogFixture' -and $source -match 'Invoke-LabSsisPreparedFixtureRun')
Check 'Neuer Run verlangt Prepared-Artifact, gebundene Medienidentität und ShouldProcess' ($source -match 'SupportsShouldProcess' -and $source -match 'hyperv-sql-prepared-sealed' -and $source -match 'ExpectedSqlMediaSha256')
Check 'Öffentliche Receipt enthält keine Verbindungs- oder Secretfelder' ($source -match 'ConnectionBinding=\[string\]\$fixture.SourceBinding' -and $source -notmatch '(?i)(Password\s*=|Credential\s*=|Endpoint\s*=|ConnectionString\s*=)')
Check 'Fixture-Cleanup unterscheidet vollständigen Prepared-Run und retained vorhandenen Run' ($source -match 'REMOVE_RUN_TO_CLEANUP' -and $source -match 'REMOVE_OWNED_FIXTURE_TO_CLEANUP' -and $privateSource -match 'Remove-LabSsisExistingCatalogFixture')
$module=Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru
$command=Get-Command -Module $module.Name -Name New-SqlServerLabSsisCatalogFixture -ErrorAction SilentlyContinue
Check 'Geladenes Modul veröffentlicht Component-, Fixture- und gezielten Cleanup-Cmdlet' ($null -ne $command -and $command.Parameters.ContainsKey('RunId') -and $command.Parameters.ContainsKey('WhatIf') -and $command.Parameters.ContainsKey('Confirm') -and $null -ne (Get-Command -Module $module.Name -Name Install-SqlServerLabSsisComponent -ErrorAction SilentlyContinue) -and $null -ne (Get-Command -Module $module.Name -Name Remove-SqlServerLabSsisCatalogFixture -ErrorAction SilentlyContinue))
Write-Host "SSIS CATALOG FIXTURE CHECKS: $passed PASS, $failed FAIL; native NOT_EXECUTED"
if($failed){exit 1}
