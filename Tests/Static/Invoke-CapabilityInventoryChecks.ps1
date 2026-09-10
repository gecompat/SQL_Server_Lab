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
Assert-CapabilityInventory ($inventory.RecordedEvidence.Status -eq 'RECORDED' -and
    @($inventory.RecordedEvidence.Records).Count -gt 0 -and $inventory.RecordedEvidence.ReferenceVerificationStatus -eq 'NOT_VERIFIED' -and
    @($inventory.RecordedEvidence.Records | Where-Object {$_.CurrentExecutionStatus -ne 'NOT_EXECUTED' -or $_.EvidenceBoundary -ne 'RECORDED_HISTORY_ONLY'}).Count -eq 0) 'Historische Nachweise bleiben von aktueller Ausfuehrung getrennt'
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

    Remove-Item -LiteralPath (Join-Path $fixture 'Schemas/broken.json')
    Set-Content -LiteralPath (Join-Path $fixture 'SqlServerLab.psm1') -Value '$script:ModuleLoadErrors=@(); function Get-LabProviderCapabilityContract { @() }'
    $absent=& $tool -RepositoryRoot $fixture
    Assert-CapabilityInventory ($absent.RecordedEvidence.Status -eq 'NOT_PRESENT' -and $absent.RecordedEvidence.Records.Count -eq 0) 'Fehlender optionaler Index erfindet keine Evidence'
    $qualityRoot=Join-Path $fixture 'Documentation/Quality'
    $null=New-Item -ItemType Directory -Path $qualityRoot -Force
    $indexPath=Join-Path $qualityRoot 'capability-evidence-index.json'
    Copy-Item -LiteralPath (Join-Path $repoRoot 'Schemas/capability-evidence-index.schema.json') -Destination (Join-Path $fixture 'Schemas/capability-evidence-index.schema.json')
    $sourceDocument=Get-Content -LiteralPath (Join-Path $repoRoot 'Documentation/Quality/capability-evidence-index.json') -Raw | ConvertFrom-Json -AsHashtable
    $sourceDocument.Records=@($sourceDocument.Records[0])
    $validIndex=$sourceDocument | ConvertTo-Json -Depth 10
    Set-Content -LiteralPath $indexPath -Value $validIndex
    $historical=& $tool -RepositoryRoot $fixture
    Assert-CapabilityInventory ($historical.RecordedEvidence.Status -eq 'RECORDED' -and
        $historical.RecordedEvidence.Records[0].CurrentTestPresence -eq 'ABSENT' -and
        $historical.RecordedEvidence.Records[0].CurrentExecutionStatus -eq 'NOT_EXECUTED') 'Entfernte Tests loeschen historische Ergebnisse nicht und werden nicht als aktuell bestaetigt'
    $fixtureTest=Join-Path $fixture $sourceDocument.Records[0].Test
    $null=New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($fixtureTest)) -Force
    Set-Content -LiteralPath $fixtureTest -Value '# synthetic test source; no execution'
    $present=& $tool -RepositoryRoot $fixture
    Assert-CapabilityInventory ($present.RecordedEvidence.Records[0].CurrentTestPresence -eq 'PRESENT' -and
        -not $present.RuntimeEvidence.Assessed -and $present.Tests[0].ExecutionStatus -eq 'NOT_EXECUTED') 'Vorhandene Testquelle bestaetigt nur die Referenz und fuehrt keinen Test aus'
    $legacyDocument=$validIndex | ConvertFrom-Json -AsHashtable
    $legacyDocument.Records[0].SqlVersion='2008R2'
    $legacyDocument.Records[0].Scope='NATIVE_SQL'
    $legacyDocument.Records[0].Test='Tests/Integration/Invoke-Synthetic.ps1'
    $legacyDocument | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $indexPath
    $legacy=& $tool -RepositoryRoot $fixture
    Assert-CapabilityInventory ($legacy.RecordedEvidence.Status -eq 'RECORDED' -and
        $legacy.RecordedEvidence.Records[0].SqlVersion -ceq '2008R2' -and
        $legacy.RecordedEvidence.Records[0].CurrentExecutionStatus -eq 'NOT_EXECUTED') 'Kanonisches SQL 2008R2 bleibt von SQL 2008 getrennt und erzeugt keine aktuelle Ausfuehrungsbehauptung'
    $invalidCases=@(
        @{Name='Unbekanntes Payloadfeld';Change={param($row) $row.Secret='synthetic-private-content'}},
        @{Name='Unbekannter Provider';Change={param($row) $row.Provider='synthetic-unknown'}},
        @{Name='PASS mit fehlendem Cleanup';Change={param($row) $row.Cleanup='NOT_EXECUTED'}},
        @{Name='Native Scope mit statischem Test';Change={param($row) $row.Scope='NATIVE_LIFECYCLE'}},
        @{Name='Native SQL ohne Version';Change={param($row) $row.Scope='NATIVE_SQL';$row.Test='Tests/Integration/Invoke-Synthetic.ps1'}},
        @{Name='Relative Pfadflucht';Change={param($row) $row.Test='../synthetic-private-content.ps1'}},
        @{Name='Ungebundene Quellrevision';Change={param($row) $row.SourceRevision='main'}},
        @{Name='Ungueltiges Kalenderdatum';Change={param($row) $row.Date='2026-02-30'}},
        @{Name='Fremde Referenz';Change={param($row) $row.Reference='https://example.invalid/synthetic-private-content'}}
    )
    foreach($case in $invalidCases){
        $document=$validIndex | ConvertFrom-Json -AsHashtable
        & $case.Change $document.Records[0]
        $document | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $indexPath
        $rejected=& $tool -RepositoryRoot $fixture
        Assert-CapabilityInventory ($rejected.RecordedEvidence.Status -eq 'INVALID' -and $rejected.RecordedEvidence.Records.Count -eq 0 -and
            $rejected.Issues.Code -contains 'EVIDENCE_INDEX_INVALID' -and ($rejected | ConvertTo-Json -Depth 10) -notmatch 'synthetic-private-content') "$($case.Name) wird ohne Payload-Ausgabe abgelehnt"
    }
    Set-Content -LiteralPath $indexPath -Value ('x' * 262145)
    $oversized=& $tool -RepositoryRoot $fixture
    Assert-CapabilityInventory ($oversized.RecordedEvidence.Status -eq 'INVALID' -and $oversized.RecordedEvidence.Records.Count -eq 0) 'Uebergrosser Index wird vor JSON-Auswertung abgelehnt'
    Remove-Item -LiteralPath $indexPath
    [IO.Directory]::Delete($qualityRoot)
    Set-Content -LiteralPath (Join-Path $external 'capability-evidence-index.json') -Value 'synthetic-private-content'
    $null=New-Item -ItemType $(if($IsWindows){'Junction'}else{'SymbolicLink'}) -Path $qualityRoot -Target $external
    try {
        Set-Content -LiteralPath (Join-Path $fixture 'SqlServerLab.psm1') -Value '[IO.File]::WriteAllText((Join-Path $PSScriptRoot ''unexpected-import''),''bad'')'
        $redirected=& $tool -RepositoryRoot $fixture
        Assert-CapabilityInventory ($redirected.Issues.Code -contains 'EVIDENCE_INDEX_REPARSE_POINT_NOT_READ' -and
            $redirected.RecordedEvidence.Records.Count -eq 0 -and -not (Test-Path -LiteralPath (Join-Path $fixture 'unexpected-import')) -and
            ($redirected | ConvertTo-Json -Depth 10) -notmatch 'synthetic-private-content') 'Umgeleiteter Evidence-Root wird nicht gelesen und blockiert den Modulimport'
    }
    finally {Remove-Item -LiteralPath $qualityRoot -Force}
}
finally {
    $resolved=[IO.Path]::GetFullPath($testRoot);$boundary=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    if(-not $resolved.StartsWith($boundary,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notlike 'sql-lab-inventory-*'){throw 'INVENTORY_TEST_CLEANUP_SCOPE_INVALID'}
    if(Test-Path -LiteralPath $resolved){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
