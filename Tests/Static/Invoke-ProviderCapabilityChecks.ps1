#Requires -Version 7.2
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$failures = [System.Collections.Generic.List[string]]::new(); $passed = 0
. (Join-Path $PSScriptRoot '..' 'Common' 'CheckResult.ps1')
Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -ErrorAction Stop
$module = Get-Module SqlServerLab
$result = & $module { @(Get-LabProviderCapabilityContract) }
Add-CheckResult -Name 'Capability-Projektion enthält alle Provider sortiert' -Success ((@($result.Provider) -join ',') -eq 'docker,hyperv,podman')
$hyperv = @($result | Where-Object Provider -eq 'hyperv')[0]
Add-CheckResult -Name 'Hyper-V deklariert nur den begrenzten Prepared-Image-Klonpfad' -Success ($hyperv.SqlProvisioningScope -eq 'prepared-image-clone-only' -and @($hyperv.Limitations.SourceKey) -contains 'no-real-windows-sql-e2e-evidence')
$serialized = $result | ConvertTo-Json -Depth 20
Add-CheckResult -Name 'Capability-Vertrag ist serialisierbar und enthält keine Runtimewerte' -Success ($serialized -notmatch 'containerId|connectionString|HostName|\\\\')
$workflow = Get-SqlServerLabWorkflow
Add-CheckResult -Name 'Workflow projiziert dieselbe deklarative Capability-Sicht' -Success ((@($workflow.Host.ProviderCapabilities.Provider) -join ',') -eq 'docker,hyperv,podman')
if ($failures.Count -gt 0) { foreach ($failure in $failures) { Write-Host "FAIL: $failure" -ForegroundColor Red }; exit 1 }
Write-Host "Provider Capability Checks: $passed PASS" -ForegroundColor Green
