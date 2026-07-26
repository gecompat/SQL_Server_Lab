# LAB-001 – Reproducible Diagnostic Lab

LAB-001 ist ein ausschließlich synthetisches und hardwareadaptives
SQL-Server-Diagnoselabor. Welle 0 stellt die statischen Verträge, Profile,
Kataloge und die vollständige geplante Procedure-Coverage bereit. Welle 1
implementiert den read-only Preflight und den begrenzten Orchestrator-Core.
Welle 2 ergänzt den ausführbaren Docker-Vertrag für eine einzelne
SQL-Server-2025-Instanz sowie die Baselines `LAB-BASE-001` und
`LAB-BASE-002`. Welle 3 erweitert denselben begrenzten Containerpfad um
38 ausführbare Core-Performance-Szenarien, eine ausdrücklich nicht als
Runtimenachweis ausgewiesene Contract Fixture und eine sequenzielle
SQL-Server-2019-/2022-/2025-Lane. Welle 4 stellt die Docker-Laufzeit für
`CTR-PAIR` und `CTR-TRIPLE` sowie die begrenzte Log-Shipping-Aktion
`LAB-LS-001` bereit. Für Welle 5 ist die Image-Pipeline-Vertragsgrundlage
vorhanden. Das getrennte Docker-/Podman-Quick-Testsystem implementiert den
Lifecycle von Preflight und Installation bis Update, Reset und Destroy.

Der Produktstatus ist `PARTIAL_PRODUCT_FUNCTION`. Die Wellen 2 bis 4 und das
Quick-Testsystem sind als `IMPLEMENTED_ACTIONS_GATE` verfügbar; ihre externen
Laufzeitnachweise bleiben `IMPLEMENTED_EXTERNAL_EVIDENCE_PENDING`. Die
Welle-5-Runtime und die Wellen 6 bis 10 sind nicht implementiert. Ein
vorhandener Codepfad oder ein grüner statischer CI-Lauf wird nicht als realer
Hostnachweis ausgegeben.

## Verzeichnisvertrag

| Pfad | Inhalt |
|---|---|
| `Config` | Generische Beispielkonfigurationen, Image-Lock und konservative Ressourcenprofile. |
| `Contracts` | JSON-Schemata für Konfiguration, Hostfähigkeiten, Topologien, Szenarien, Runbooks, Contract Fixtures, Finding-Erwartungen und veröffentlichbare Evidenz. |
| `Containers` | Portabler Compose-Core, Docker-Override und gemeinsamer Linux-Bootstrap. |
| `Orchestration` | Öffentliche CLI und PowerShell-Modul für Preflight, Status, Containeraufbau, Baselines, Welle-3-Szenarien, Versionsmatrix und begrenztes Cleanup. |
| `QuickTest` | Docker-/Podman-Lifecycle für SQL Server 2019, 2022 und 2025 mit getrenntem lokalem Zustand. |
| `Scenarios/Catalog` | Maschinenlesbarer Szenariokatalog und Procedure-zu-Szenario-Coverage. |
| `Scenarios/Core` | Ausführbare, synthetische Welle-2-Szenarien. |
| `Scenarios/Performance` | 39 Welle-3-Verträge mit gemeinsamen, begrenzten Setup-, Worker-, Observe- und Cleanup-Skripten. |
| `Validation` | Schema-, Parser-, Sicherheits- und Vertragsprüfungen ohne behauptete externe Laufzeitevidenz. |
| `.artifacts`, `.cache`, `.secrets`, `.state` | Ausschließlich lokale, ignorierte Laufzeitpfade. |

Die geplante vollständige Verzeichnisstruktur steht im
[Architekturplan](../Documentation/Architecture/Reproducible_Diagnostic_Lab_Plan.md).
Verzeichnisse späterer Wellen werden erst mit einem fachlich nutzbaren
Artefakt versioniert.

## Lokale Voraussetzungen

Für den nativen Welle-2- oder Welle-3-Lauf sind erforderlich:

- x86-64-Linux mit Docker Engine und Docker Compose;
- cgroup v2 und wirksame Containerlimits;
- eine durch den Preflight mindestens als `HC1_COMPACT` klassifizierte
  Hostkapazität;
- ein ausdrücklich freigegebenes Storage-Ziel für `EPHEMERAL_DATA`;
- eine lokale Konfiguration mit
  `DataClassification = 'LOCAL_RUNTIME_CONFIG'`;
- ausdrückliche lokale EULA-Bestätigung durch
  `AcceptSqlServerEula = $true`;
- ein lokaler, auf einen vollständigen SHA-256-Digest aufgelöster Image-Lock;
- das logische Secret `SQL_SA_PASSWORD` über den konfigurierten Secret-Provider.

Der öffentliche Image-Lock nennt Microsoft-Referenzen für SQL Server 2019,
2022 und 2025, enthält aber absichtlich keine vorgetäuschten Digests. Der
lokale Lock muss je verwendeter Version den tatsächlich aufgelösten Digest mit
`Status = 'LOCKED'` enthalten. `Up` löst die logische Image-ID
versionsbezogen auf und lädt ausschließlich die digestgebundene Referenz.

Das Beispiel-Datafile wird kopiert und nur lokal angepasst:

```powershell
Copy-Item `
    .\Lab\Config\lab.config.example.psd1 `
    .\Lab\Config\lab.config.psd1
```

Lokale Pfade, Hostnamen, Endpunkte, Benutzernamen, Digests, Kapazitätswerte und
Secrets dürfen nicht in die Beispieldateien oder in Git übernommen werden.

## Preflight

```powershell
.\Lab\Orchestration\Invoke-DiagnosticLab.ps1 -Action Preflight
```

Ohne lokale Konfiguration lautet das Ergebnis `NOT_EXECUTABLE` mit dem
Reason Code `LOCAL_CONFIG_REQUIRED`. Der Preflight ermittelt Hostklasse,
Ressourcenreserven, Docker-/Compose-/cgroup-Fähigkeiten, Image-Lock,
Netzkonflikte und logische Secret-Verfügbarkeit. Secretwerte werden nicht
protokolliert.

Die lokalen Zustandsdateien liegen unter `Lab/.state/<LabRunId>` oder unter
einem ausdrücklich übergebenen lokalen State-Root. Sie sind ignoriert und
keine veröffentlichbare Evidenz.

## Welle 2: `Up → Run → Validate → Down`

`Up` führt erneut einen read-only Preflight aus, prüft vor der ersten Mutation
die Compact-Reserven, lädt das digestgebundene Image und erstellt nur
`CTR-SINGLE`:

```powershell
$up = .\Lab\Orchestration\Invoke-DiagnosticLab.ps1 `
    -Action Up `
    -ExecutionMode LINUX_NATIVE `
    -Engine DOCKER `
    -Topology CTR-SINGLE `
    -SqlVersion 2025 `
    -ResourceProfile Compact

$runId = $up.LabRunId
```

Der gemeinsame Compose-Core:

- veröffentlicht keinen Host-Port;
- verwendet ein internes Labnetz;
- begrenzt den Container auf 3 GiB RAM und zwei logische Prozessoren;
- begrenzt SQL Server auf 2 GiB;
- bindet den Datenpfad ausschließlich unter dem freigegebenen
  `EPHEMERAL_DATA`-Ziel;
- versieht Container und Netzwerk mit der Run-ID;
- bezieht das synthetische Secret nur aus dem bestehenden Secret-Provider.

Der Orchestrator baut den eigenständigen Installer aus den kanonischen
SQL-Dateien in den ignorierten Run-State, installiert das Framework in
`LabAnalyze` und misst vor und nach `Up` Hostreserve, effektive Dockerlimits und
tatsächlichen Datenverbrauch. Reale Messwerte bleiben lokal in
`resource-measurements.json`.

### Gesunde Baseline

```powershell
.\Lab\Orchestration\Invoke-DiagnosticLab.ps1 `
    -Action Run `
    -LabRunId $runId `
    -ScenarioId LAB-BASE-001

.\Lab\Orchestration\Invoke-DiagnosticLab.ps1 `
    -Action Validate `
    -LabRunId $runId `
    -ScenarioId LAB-BASE-001
```

`LAB-BASE-001` erstellt ausschließlich die synthetische Datenbank
`Lab001Synthetic`, führt eine kleine deterministische Transaktion aus und
prüft den JSON-/Modulstatusvertrag von `monitor.USP_CurrentOverview`.
Hostabhängige Counter, Laufzeiten, Waits und Pläne sind keine exakten Asserts.

### Eingeschränkte Metadatensicht

```powershell
.\Lab\Orchestration\Invoke-DiagnosticLab.ps1 `
    -Action Run `
    -LabRunId $runId `
    -ScenarioId LAB-BASE-002

.\Lab\Orchestration\Invoke-DiagnosticLab.ps1 `
    -Action Validate `
    -LabRunId $runId `
    -ScenarioId LAB-BASE-002
```

`LAB-BASE-002` verwendet einen synthetischen Datenbankbenutzer ohne Login und
prüft, dass `monitor.USP_CheckFrameworkCapabilities` die fehlende
Metadatensicht strukturiert und ohne unkontrollierten Analyzerabbruch
ausweist. Anzahl und Reihenfolge eingeschränkter Capability-Zeilen werden
nicht fest verdrahtet.

### Cleanup

```powershell
.\Lab\Orchestration\Invoke-DiagnosticLab.ps1 `
    -Action Down `
    -LabRunId $runId `
    -WhatIf

.\Lab\Orchestration\Invoke-DiagnosticLab.ps1 `
    -Action Down `
    -LabRunId $runId
```

Container und Netzwerk werden ausschließlich anhand ihrer vollständigen
registrierten Docker-ID entfernt, nachdem ihre Run-ID-Labels erneut geprüft
wurden. Der Datenordner liegt unter dem freigegebenen Storage-Ziel, trägt einen
Run-ID-Marker und wird erst nach den Docker-Objekten über seinen exakten
registrierten Pfad entfernt. Wildcards, breite Prune-Operationen und
namensbasierte Suche sind ausgeschlossen.

Ein abgebrochener Lauf verwendet `RecoveryCleanup`. Nicht registrierte oder
fremd gelabelte Ressourcen werden nicht entfernt.

## Welle 3: Core-Performance und Versionsmatrix

Welle 3 verwendet weiterhin ausschließlich `CTR-SINGLE` und das
Compact-Ressourcenprofil. Die Szenarien sind in folgende Gruppen gegliedert:

| Gruppe | Szenarien | Assertion-Grenze |
|---|---:|---|
| CPU und Worker | 3 | Aktive begrenzte Worker und Analyzerstatus; keine feste CPU- oder Wait-Zahl. |
| Memory und Resource Governor | 3 | Memory-Grant-, Buffer-Pool- oder Konfigurationsevidenz mit dokumentierter Alternative. |
| TempDB, Log, Capacity und Recovery | 8 | Synthetischer Zustand, begrenztes Wachstum und Recovery-Rollback; kein Storage-Benchmark. |
| Blocking und Deadlocks | 6 | Run-token-gebundene Sessions und XE-Evidenz; der nichtdeterministische Parallelism-Fall bleibt Contract Fixture. |
| Latches | 3 | Tatsächliche Insertaktivität und Indexoptionen; keine universelle Latch-Wait-Schwelle. |
| Plans, Query Store und Standalone-Plananalyse | 9 | Plan-, Statistik- und Query-Store-Verträge ohne feste Plan-ID oder Planform. |
| Indexe, Columnstore und Vector | 5 | Reale synthetische Katalog-/DMV-Evidenz; Vector ausschließlich auf SQL Server 2025. |
| Versionsvertrag | 1 | Sequenzielle, getrennte Runs für Major 15, 16 und 17. |
| Extended Events | 1 | Eigenes synthetisches Ring-Buffer-Gate. |

Jedes Runtime-Szenario verwendet den Seed `1701`, maximal acht Worker und
explizite Setup-, Worker-, Observe- und Cleanup-Timeouts. Vor dem Setup und
nach der Observation wird der exakte synthetische Scope zurückgesetzt. Die
Datenbank `Lab001Wave3` trägt die aktuelle Run-ID als Marker. Cleanup beendet
nur Sessions mit dem daraus abgeleiteten `CONTEXT_INFO`, entfernt nur exakt
benannte Szenarioobjekte und leert ausschließlich die zu dieser synthetischen
Datenbank beziehungsweise den markierten Batches gehörenden Pläne.

Beispiel:

```powershell
.\Lab\Orchestration\Invoke-DiagnosticLab.ps1 `
    -Action Run `
    -LabRunId $runId `
    -ScenarioId LAB-CONC-001

.\Lab\Orchestration\Invoke-DiagnosticLab.ps1 `
    -Action Validate `
    -LabRunId $runId `
    -ScenarioId LAB-CONC-001
```

`LAB-REC-001` startet ausschließlich den anhand vollständiger Docker-ID und
Run-ID-Label geprüften Labcontainer neu. `LAB-DEAD-004` erzeugt absichtlich
keinen vorgetäuschten Runtime-PASS; die Fixture definiert nur zulässige und
unzulässige Evidenz für einen späteren realen Parallelism-Deadlock.

Die vollständige Versionslane wird sequenziell ausgeführt. Jede Version erhält
eine eigene Run-ID, eigene Container-/Netzwerkobjekte und ein abschließendes
Cleanup:

```powershell
.\Lab\Orchestration\Invoke-DiagnosticLab.ps1 `
    -Action RunVersionMatrix `
    -ConfigPath .\Lab\Config\lab.config.psd1 `
    -ScenarioId LAB-VERSION-001
```

Die lokale Konfiguration muss alle drei logischen Image-IDs auf vollständig
digestgebundene Lock-Einträge abbilden. Ein fehlender Host- oder Imagevertrag
ergibt `NOT_EXECUTED`; er wird nicht als bestandener Versionsnachweis gewertet.

## Sichtbare Plattformgrenzen

| Lane | Implementierungsstatus | Externer Nachweis |
|---|---|---|
| Docker auf nativem Linux | `IMPLEMENTED_ACTIONS_GATE` | `NOT_EXECUTED` bis zu einem Lauf auf einem freigegebenen Host |
| Docker in einer Hyper-V-Linux-VM | gemeinsamer Vertrag vorhanden | `NOT_EXECUTED` mit `HYPERV_LINUX_RUNTIME_GATE_REQUIRED` |
| Welle-3-Versionmatrix | `IMPLEMENTED_ACTIONS_GATE` | `NOT_EXECUTED` bis 2019, 2022 und 2025 sequenziell bestanden sind |
| Podman | Welle 9 | `NOT_EXECUTED` |

Die Hyper-V-Linux-Lane wird nicht als erfolgreich ausgewiesen, solange keine
isolierte kompatible VM bereitsteht. Fehlende Plattformfähigkeit ist kein
fachlicher Szenariofehler.

## Validierung

Repositoryunabhängige Prüfungen:

```text
python3 Code/Tests/Static/988_Validate_LAB001_Wave0_Contracts.py --repository-root .
python3 Code/Tests/Static/989_Validate_LAB001_Wave1_Orchestrator.py --repository-root .
python3 Code/Tests/Static/990_Validate_LAB001_Wave2_ContainerBaseline.py --repository-root .
python3 Code/Tests/Static/Validate_LAB001_Wave3_CorePerformance.py --repository-root .
```

Mit PowerShell 7:

```text
pwsh -NoLogo -NoProfile -File Lab/Validation/Invoke-LabValidation.ps1
pwsh -NoLogo -NoProfile -File Lab/Validation/Invoke-LabWave1Tests.ps1
pwsh -NoLogo -NoProfile -File Lab/Validation/Invoke-LabWave2Tests.ps1
pwsh -NoLogo -NoProfile -File Lab/Validation/Invoke-LabWave3Tests.ps1
```

Die PR-CI prüft zusätzlich das zusammengeführte Docker-Compose-Modell und
PSScriptAnalyzer. Sie startet keinen unterdimensionierten SQL-Server-Container
und überschreibt keine Mindesthostklasse. Reale `Up → Run → Validate → Down`-
Nachweise werden ausschließlich über die externen Evidence Gates geführt.

## Datenschutz- und Sicherheitsgrenze

Versionierte Dateien enthalten nur öffentliche Produktbezeichner sowie
synthetische oder logische Werte. Lokale Hostnamen, Benutzeridentitäten,
Endpunkte, IP-Adressen, Gerätebezeichnungen, Seriennummern, Pfade,
Kapazitätsmesswerte, Zugangsdaten und Rohresultate dürfen nicht übernommen
werden.

Rohartefakte können SQL-Text, Pläne, lokale Objektbezeichner oder technische
Laufzeitwerte enthalten. Sie bleiben in ignorierten lokalen Pfaden und werden
nicht automatisch an Commits, Pull Requests oder Workflow-Artefakte
angehängt.

## Öffentliche Produktquellen

- Microsoft (2026): [Docker: Run Containers for SQL Server on Linux](https://learn.microsoft.com/en-us/sql/linux/install-upgrade/quickstart-install-docker?view=sql-server-ver17).
- Microsoft (2026): [SQL Server container images](https://mcr.microsoft.com/product/mssql/server/about).
- Microsoft (2026): [CREATE VECTOR INDEX](https://learn.microsoft.com/en-us/sql/t-sql/statements/create-vector-index-transact-sql?view=sql-server-ver17).
- Microsoft (2026): [TempDB Space Resource Governance](https://learn.microsoft.com/en-us/sql/relational-databases/resource-governor/tempdb-space-resource-governance?view=sql-server-ver17).
- Docker (2026): [Compose file reference](https://docs.docker.com/reference/compose-file/).
- Docker (2026): [Resource constraints](https://docs.docker.com/engine/containers/resource_constraints/).
