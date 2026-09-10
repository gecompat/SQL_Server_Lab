#Requires -Version 7.2
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$repoRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$tool=Join-Path $repoRoot 'Tools/Get-SqlServerLabCapabilityInventory.ps1'
function Assert-CapabilityInventory {param([bool]$Condition,[string]$Name);if(-not $Condition){throw "FAIL: $Name"};Write-Host "PASS: $Name"}
$inventory=& $tool
$manifest=Import-PowerShellDataFile (Join-Path $repoRoot 'SqlServerLab.psd1')
Assert-CapabilityInventory ($inventory.Status -eq 'INVENTORIED' -and $inventory.Issues.Count -eq 0) 'Aktueller Produktquellstand ist inventarisierbar'
Assert-CapabilityInventory ((@($inventory.Exports.Name | Sort-Object) -join '|') -eq (@($manifest.FunctionsToExport | Sort-Object) -join '|') -and @($inventory.Exports | Where-Object Status -ne 'EXPORTED').Count -eq 0) 'Exportinventar entspricht dem geladenen Manifestvertrag'
Assert-CapabilityInventory (@($inventory.Providers).Count -eq 3 -and @($inventory.Providers | Where-Object {-not (Test-Path -LiteralPath (Join-Path $repoRoot $_.Source))}).Count -eq 0) 'Providerverweise behalten ihre echte Gross-/Kleinschreibung'
Assert-CapabilityInventory (-not $inventory.RuntimeEvidence.Assessed -and $inventory.RuntimeEvidence.Status -eq 'NOT_EXECUTED' -and @($inventory.Tests | Where-Object ExecutionStatus -ne 'NOT_EXECUTED').Count -eq 0 -and @($inventory.Providers | Where-Object EvidenceBoundary -ne 'PROVIDER_METADATA_ONLY').Count -eq 0) 'Dateien und Providerdeklarationen werden nie als ausgefuehrte Runtime-Evidence ausgegeben'
Assert-CapabilityInventory (@($inventory.Sources | Where-Object {$_.Source -match '^\.(artifacts|local|state|runtime|secrets|cache)/|^private_Note/' -or [IO.Path]::IsPathRooted($_.Source)}).Count -eq 0) 'Inventar enthaelt nur relative Produktquellen ohne lokale Betriebsroots'
Assert-CapabilityInventory (@($inventory.Sources | Where-Object Kind -eq 'SCHEMA').Count -gt 0 -and @($inventory.Sources | Where-Object Kind -eq 'CATALOG').Count -gt 0 -and @($inventory.Sources | Where-Object Kind -eq 'BROWSER_UI').Count -gt 0 -and @($inventory.PlanningReferences | Where-Object Id -eq 'BASE-001').Count -gt 0) 'Schemas, Kataloge, Browser und bestehende Aufgabenreferenzen sind enthalten'
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-inventory-'+[guid]::NewGuid().ToString('N'))
try {
    $fixture=Join-Path $testRoot 'fixture';$external=Join-Path $testRoot 'external'
    $null=New-Item -ItemType Directory -Path (Join-Path $fixture 'Schemas'),(Join-Path $fixture 'Private'),$external -Force
    Set-Content -LiteralPath (Join-Path $fixture 'Schemas/broken.json') -Value '{ synthetic-private-content'
    $broken=& $tool -RepositoryRoot $fixture
    Assert-CapabilityInventory ($broken.Status -eq 'PARTIAL' -and $broken.Issues.Code -contains 'JSON_PARSE_ERROR' -and ($broken | ConvertTo-Json -Depth 8) -notmatch 'synthetic-private-content') 'Ungueltiges JSON liefert einen sanitisierten Befund'
    Set-Content -LiteralPath (Join-Path $fixture 'SqlServerLab.psd1') -Value "@{RootModule='SqlServerLab.psm1';ModuleVersion='1.0.0';FunctionsToExport=@()}"
    Set-Content -LiteralPath (Join-Path $fixture 'SqlServerLab.psm1') -Value '[IO.File]::WriteAllText((Join-Path $PSScriptRoot ''unexpected-import''),''bad'')'
    Set-Content -LiteralPath (Join-Path $external 'foreign.ps1') -Value 'throw "SHOULD_NOT_LOAD"'
    $link=Join-Path $fixture 'Private/linked'
    $null=New-Item -ItemType $(if($IsWindows){'Junction'}else{'SymbolicLink'}) -Path $link -Target $external
    try {
        $linked=& $tool -RepositoryRoot $fixture
        Assert-CapabilityInventory ($linked.Issues.Code -contains 'REPARSE_POINT_NOT_READ' -and $linked.Issues.Code -contains 'MODULE_INVENTORY_NOT_EXECUTED' -and @($linked.Sources | Where-Object Source -like 'Private/linked/*').Count -eq 0 -and -not (Test-Path -LiteralPath (Join-Path $fixture 'unexpected-import'))) 'Junction/Symlink wird nicht verfolgt und blockiert den indirekten Modulimport'
    }
    finally {Remove-Item -LiteralPath $link -Force}
}
finally {
    $resolved=[IO.Path]::GetFullPath($testRoot);$boundary=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    if(-not $resolved.StartsWith($boundary,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notlike 'sql-lab-inventory-*'){throw 'INVENTORY_TEST_CLEANUP_SCOPE_INVALID'}
    if(Test-Path -LiteralPath $resolved){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
