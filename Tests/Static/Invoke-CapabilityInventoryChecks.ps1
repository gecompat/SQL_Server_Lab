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
Assert-CapabilityInventory ($inventory.ContractVersion -ceq 'SqlServerLab.RepositoryCapabilityInventory/1.0' -and $null -eq $inventory.PSObject.Properties['RecordedAcceptanceMatrix']) 'Standard bleibt Version 1.0 ohne zusaetzliches Matrixfeld'
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
    $absentMatrix=& $tool -RepositoryRoot $fixture -IncludeRecordedAcceptanceMatrix
    Assert-CapabilityInventory ($absentMatrix.RecordedAcceptanceMatrix.Status -ceq 'NOT_PRESENT' -and $absentMatrix.RecordedAcceptanceMatrix.Cells.Count -eq 0) 'Optionale Matrix bleibt bei fehlendem Index geschlossen und leer'
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
    function New-InventoryHistoryRecord {
        param([hashtable]$Changes)
        $row=($validIndex | ConvertFrom-Json -AsHashtable).Records[0]
        foreach($field in $Changes.Keys){$row[$field]=$Changes[$field]}
        $row
    }
    function Write-InventoryHistory {
        param([object[]]$Rows)
        @{ContractVersion=$sourceDocument.ContractVersion;EvidenceBoundary='RECORDED_HISTORY_ONLY';Records=$Rows} | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $indexPath
    }
    $rows=@(
        (New-InventoryHistoryRecord @{}),
        (New-InventoryHistoryRecord @{Result='FAIL';Cleanup='NOT_RECORDED';Reference='https://github.com/gecompat/SQL_Server_Lab/pull/2'}),
        (New-InventoryHistoryRecord @{Date='2026-09-28';Result='FAIL';Cleanup='NOT_RECORDED'}),
        (New-InventoryHistoryRecord @{SourceRevision=('b'*40);Result='FAIL';Cleanup='NOT_RECORDED'}),
        (New-InventoryHistoryRecord @{Platform='linux'}),
        (New-InventoryHistoryRecord @{Provider='podman'}),
        (New-InventoryHistoryRecord @{SqlVersion='2008'}),
        (New-InventoryHistoryRecord @{SqlVersion='2008R2'}),
        (New-InventoryHistoryRecord @{Scope='PACKAGE'}),
        (New-InventoryHistoryRecord @{Scope='NATIVE_LIFECYCLE';Test='Tests/Integration/Invoke-Synthetic.ps1'})
    )
    Write-InventoryHistory $rows
    $default=& $tool -RepositoryRoot $fixture
    $matrixInventory=& $tool -RepositoryRoot $fixture -IncludeRecordedAcceptanceMatrix
    $matrix=$matrixInventory.RecordedAcceptanceMatrix
    Assert-CapabilityInventory ($matrixInventory.ContractVersion -ceq 'SqlServerLab.RepositoryCapabilityInventory/1.1' -and $matrix.Status -ceq 'RECORDED' -and $matrix.Coverage -ceq 'INDEXED_TUPLES_ONLY') 'Opt-in Version 1.1 beschreibt ausschliesslich indexierte Historienzellen'
    $compatible=$matrixInventory.PSObject.Copy();$compatible.PSObject.Properties.Remove('RecordedAcceptanceMatrix');$compatible.ContractVersion=$default.ContractVersion
    Assert-CapabilityInventory (($compatible | ConvertTo-Json -Depth 20 -Compress) -ceq ($default | ConvertTo-Json -Depth 20 -Compress)) 'Alle bisherigen Felder und Semantiken sind auch bei Opt-in unveraendert'
    Assert-CapabilityInventory ($matrix.Cells.Count -eq 7 -and ($matrix.Cells | Measure-Object RecordCount -Sum).Sum -eq 10) 'Exakte Tupel erhalten alle Records und trennen Provider, Plattform und Scope'
    Assert-CapabilityInventory (@($matrix.Cells | Where-Object {$null -eq $_.SqlVersion}).Count -eq 5 -and @($matrix.Cells | Where-Object SqlVersion -CEQ '2008').Count -eq 1 -and @($matrix.Cells | Where-Object SqlVersion -CEQ '2008R2').Count -eq 1) 'Typisiertes null, SQL 2008 und SQL 2008R2 sind drei unterschiedliche Auswahlwerte'
    $conflicting=@($matrix.Cells | Where-Object HistoryConflict)
    Assert-CapabilityInventory ($conflicting.Count -eq 1 -and $conflicting[0].RecordCount -eq 4 -and $conflicting[0].HistoryResults.Count -eq 2) 'Gleicher Tuple-Revision-Test-Datum-Befund markiert Widerspruch ohne Latest-Winner'
    Assert-CapabilityInventory (@($matrix.Cells | Where-Object {$_.CurrentExecutionStatus -cne 'NOT_EXECUTED' -or $_.CurrentReadinessStatus -cne 'NOT_CHECKED' -or $_.ReferenceVerificationStatus -cne 'NOT_VERIFIED' -or $_.EvidenceBoundary -cne 'RECORDED_HISTORY_ONLY'}).Count -eq 0 -and @($matrix.Cells | Where-Object {$_.Scope -ceq 'NATIVE_LIFECYCLE' -and $_.NativeAcceptanceStatus -ceq 'UNKNOWN'}).Count -eq 1 -and @($matrix.Cells | Where-Object {$_.Scope -cin @('STATIC_CONTRACT','PACKAGE') -and $_.NativeAcceptanceStatus -ceq 'NOT_APPLICABLE'}).Count -eq 6) 'Historischer PASS und statische Rows erteilen keine native oder aktuelle Abnahme'
    Assert-CapabilityInventory (@($matrix.Cells.Records | Where-Object CurrentTestPresence -CEQ 'ABSENT').Count -eq 1 -and ($matrix | ConvertTo-Json -Depth 12) -notmatch 'PlanningText|synthetic-private-content') 'Fehlende Tests bleiben Historie; Matrix enthaelt keine freie Planung oder privaten Payload'
    $firstOrder=$matrix | ConvertTo-Json -Depth 12 -Compress
    [array]::Reverse($rows);Write-InventoryHistory $rows
    $reordered=& $tool -RepositoryRoot $fixture -IncludeRecordedAcceptanceMatrix
    Assert-CapabilityInventory (($reordered.RecordedAcceptanceMatrix | ConvertTo-Json -Depth 12 -Compress) -ceq $firstOrder) 'Ordinal sortierte Zellen und vollstaendige Historie sind von Indexreihenfolge unabhaengig'
    Write-InventoryHistory @((New-InventoryHistoryRecord @{}),(New-InventoryHistoryRecord @{Date='2026-09-28';Result='FAIL';Cleanup='NOT_RECORDED'}),(New-InventoryHistoryRecord @{SourceRevision=('b'*40);Result='FAIL';Cleanup='NOT_RECORDED'}))
    $separate=& $tool -RepositoryRoot $fixture -IncludeRecordedAcceptanceMatrix
    Assert-CapabilityInventory (-not $separate.RecordedAcceptanceMatrix.Cells[0].HistoryConflict -and $separate.RecordedAcceptanceMatrix.Cells[0].RecordCount -eq 3) 'Unterschiedliche Daten und Revisionen bleiben widerspruchsfreie separate Historie'
    Write-InventoryHistory @((New-InventoryHistoryRecord @{Test='Tests/Static/Invoke-Ordinal.ps1'}),(New-InventoryHistoryRecord @{Test='Tests/Static/Invoke-ordinal.ps1';Result='FAIL';Cleanup='NOT_RECORDED'}))
    $ordinal=& $tool -RepositoryRoot $fixture -IncludeRecordedAcceptanceMatrix
    Assert-CapabilityInventory (-not $ordinal.RecordedAcceptanceMatrix.Cells[0].HistoryConflict -and $ordinal.RecordedAcceptanceMatrix.Cells[0].RecordCount -eq 2) 'Ordinal unterschiedliche Testidentitaeten werden nicht per Gross-/Kleinschreibungsalias zusammengelegt'
    Write-InventoryHistory @((New-InventoryHistoryRecord @{}),(New-InventoryHistoryRecord @{Cleanup='NOT_REQUIRED';Reference='https://github.com/gecompat/SQL_Server_Lab/pull/2'}))
    $cleanupConflict=& $tool -RepositoryRoot $fixture -IncludeRecordedAcceptanceMatrix
    Assert-CapabilityInventory ($cleanupConflict.RecordedAcceptanceMatrix.Cells[0].HistoryConflict -and $cleanupConflict.RecordedAcceptanceMatrix.Cells[0].HistoryResults.Count -eq 1) 'Abweichendes Cleanup allein markiert denselben historischen Befund als widerspruechlich'
    $bounded=@(1..128 | ForEach-Object {New-InventoryHistoryRecord @{Reference="https://github.com/gecompat/SQL_Server_Lab/pull/$_"}})
    Write-InventoryHistory $bounded
    $maximum=& $tool -RepositoryRoot $fixture -IncludeRecordedAcceptanceMatrix
    Assert-CapabilityInventory ($maximum.RecordedAcceptanceMatrix.Cells[0].RecordCount -eq 128 -and -not $maximum.RecordedAcceptanceMatrix.Cells[0].HistoryConflict) '128 validierte Records bleiben vollstaendig ohne erfundenen Widerspruch'
    Write-InventoryHistory @($bounded+(New-InventoryHistoryRecord @{Reference='https://github.com/gecompat/SQL_Server_Lab/pull/129'}))
    $tooMany=& $tool -RepositoryRoot $fixture -IncludeRecordedAcceptanceMatrix
    Assert-CapabilityInventory ($tooMany.RecordedEvidence.Status -ceq 'INVALID' -and $tooMany.RecordedAcceptanceMatrix.Cells.Count -eq 0) '129 Records werden durch die vorhandene Schemaautoritaet geschlossen abgewiesen'
    $invalidCases=@(
        @{Name='Unbekanntes Payloadfeld';Change={param($row) $row.Secret='synthetic-private-content'}},
        @{Name='Unbekannter Provider';Change={param($row) $row.Provider='synthetic-unknown'}},
        @{Name='Provideralias mit anderer Schreibweise';Change={param($row) $row.Provider='Docker'}},
        @{Name='SQL-Versionsalias mit anderer Schreibweise';Change={param($row) $row.SqlVersion='2008r2'}},
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
        $rejected=& $tool -RepositoryRoot $fixture -IncludeRecordedAcceptanceMatrix
        Assert-CapabilityInventory ($rejected.RecordedEvidence.Status -eq 'INVALID' -and $rejected.RecordedEvidence.Records.Count -eq 0 -and
            $rejected.RecordedAcceptanceMatrix.Cells.Count -eq 0 -and $rejected.RecordedAcceptanceMatrix.Status -ceq 'INVALID' -and
            $rejected.Issues.Code -contains 'EVIDENCE_INDEX_INVALID' -and ($rejected | ConvertTo-Json -Depth 10) -notmatch 'synthetic-private-content') "$($case.Name) wird ohne Payload-Ausgabe abgelehnt"
    }
    Set-Content -LiteralPath $indexPath -Value ('x' * 262145)
    $oversized=& $tool -RepositoryRoot $fixture -IncludeRecordedAcceptanceMatrix
    Assert-CapabilityInventory ($oversized.RecordedEvidence.Status -eq 'INVALID' -and $oversized.RecordedEvidence.Records.Count -eq 0 -and $oversized.RecordedAcceptanceMatrix.Cells.Count -eq 0) 'Uebergrosser Index wird vor JSON-Auswertung abgelehnt'
    Remove-Item -LiteralPath $indexPath
    [IO.Directory]::Delete($qualityRoot)
    Set-Content -LiteralPath (Join-Path $external 'capability-evidence-index.json') -Value 'synthetic-private-content'
    $null=New-Item -ItemType $(if($IsWindows){'Junction'}else{'SymbolicLink'}) -Path $qualityRoot -Target $external
    try {
        Set-Content -LiteralPath (Join-Path $fixture 'SqlServerLab.psm1') -Value '[IO.File]::WriteAllText((Join-Path $PSScriptRoot ''unexpected-import''),''bad'')'
        $redirected=& $tool -RepositoryRoot $fixture -IncludeRecordedAcceptanceMatrix
        Assert-CapabilityInventory ($redirected.Issues.Code -contains 'EVIDENCE_INDEX_REPARSE_POINT_NOT_READ' -and
            $redirected.RecordedAcceptanceMatrix.Cells.Count -eq 0 -and
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
