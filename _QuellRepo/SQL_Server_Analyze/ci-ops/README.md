# SQL Server Analyze

---
---
# ⚠️ READ BEFORE USE

## License notice

**NOTICE: This software is NOT Open Source. Use is governed by a custom Community & Attribution License.**

1. **NO RESALE:** Selling or charging for access to this software is strictly prohibited.
2. **ATTRIBUTION REQUIRED:** You must preserve the copyright notice for **gecompat - Gerhard Pisch**.
3. **NO LIABILITY:** Use this software at your own risk. The author is **NOT liable** for any damages, data loss, or business interruptions.

Full legal terms can be found in the [LICENSE.md](./LICENSE.md) file.

---
## Lizenzhinweis

**NOTIZ: SQL Server Analyze ist keine Open-Source-Software. Die Nutzung richtet sich nach der projektspezifischen Community & Attribution License.**

1.  **NO RESALE:** Der Verkauf der Software und das Entgelt für den Zugang zur Software sind untersagt.
2. **ATTRIBUTION REQUIRED:** Der Copyright-Hinweis für **gecompat – Gerhard Pisch** muss erhalten bleiben.
3. **NO LIABILITY:** Die Nutzung erfolgt auf eigenes Risiko; der Autor **haftet nicht** für Schäden, Datenverlust oder Betriebsunterbrechungen.

Maßgeblich ist der vollständige Wortlaut in [LICENSE.md](./LICENSE.md).

# ⚠️ READ BEFORE USE


---
--- 


## Überblick

SQL Server Analyze ist ein T-SQL-basiertes Diagnoseframework für SQL Server ab Version 2019. Es unterstützt Ad-hoc-Analysen laufender Prozesse ebenso wie tiefergehende Untersuchungen von Objekten, Indizes, Ausführungsplänen, Query Store, Extended Events, Serverkonfiguration und Infrastrukturkomponenten.

Das Framework wird in einer frei wählbaren Datenbank im Schema `[monitor]` installiert.

## Schwerpunkte

Der Funktionsumfang umfasst insbesondere folgende Analysebereiche:

- aktuelle Sessions, Requests, Blocking, Waits und Transaktionen
- Memory Grants einschließlich Resource Governor und Resource Semaphores
- exaktes aktuell ausgeführtes Statement anhand der SQL-Server-Offsets
- vollständiger Batch-, Modul- und Input-Buffer-Kontext bei Bedarf
- TempDB-, I/O- und Transaktionslog-Diagnose einschließlich
  SQL-Server-2025-Workload-Group-Limits, aktueller/Peak-Nutzung,
  Verletzungszählern und Resetfenster
- Objekt-, Index-, Statistik-, Partitionierungs- und Columnstore-Analyse einschließlich capability-adaptiver SQL-Server-2025-JSON-Index-/Pfadmetadaten sowie Statistikherkunft auf lesbaren Secondaries
- Plan Cache, Query Hash, Showplan und Plan-Detailanalyse
- Query Store: Laufzeitwerte, Waits, Planwechsel, Regressionen, Forced Plans und Hints
- Extended Events: Sessions, Targets, Deadlocks und Blocked-Process-Ereignisse
- SQL Agent, Resource Governor, Hochverfügbarkeit, Backup, Log Shipping und Replikation
- CPU-, NUMA-, Memory-, TempDB-, Betriebssystem-, Trace-Flag- und Sicherheitskonfiguration
- Spezialfallmodule für Integrität, Datei-/Volumekapazität, typisierte Performance Counter und kritische Engine-Ereignisse
- IQP-, Contention-, Buffer-Pool-, Backupketten-, Schema-, Statistikverteilungs-, Availability- und Agent-/Alert-Evidenz
- normalisierte diagnostische Findings mit Priorität, Konfidenz und expliziter Aussagegrenze
- versionsabhängige Capability-Erkennung, leichtgewichtige Spezialfeature-Inventur sowie isolierte In-Memory-OLTP-, Temporal-Tables-, Service-Broker-, Full-Text- und Data-Capture-/Replikations-Tiefenanalysen
- getrennte External-Runtime- und SQL-CLR-Analyse für Konfiguration, registrierte Objekte, Host- und Laufzeitevidenz ohne Testausführung

## Voraussetzungen

- SQL Server 2019 oder neuer
- getestet mit Installationsdatenbank, Server und `tempdb` mit der Collation `SQL_Latin1_General_CP1_CS_AS`
- ausreichende Leseberechtigungen für die verwendeten DMVs und Systemkataloge
- DDL-Rechte für die einmalige Installation der Frameworkobjekte
- SQLCMD-Modus oder PowerShell, abhängig vom gewählten Installationsweg

Das Framework vergibt selbst keine Benutzer- oder Serverberechtigungen.

## Schnellstart

### Empfohlen für SSMS: eigenständigen Installer erzeugen

```powershell
Set-Location ./Code/Install
./Build-StandaloneInstaller.ps1
```

Dadurch entsteht `Code/Install/generated/Install_All.generated.sql`. In dieser Datei muss der Platzhalter `[DeineDatenbank]` nur einmal am Anfang ersetzt werden. Generierte Build-Artefakte werden nicht versioniert.

Führen Sie die generierte Datei anschließend vollständig in SSMS aus und prüfen Sie die Installation mit
`Code/Tests/Integration/110_Smoke_Test.sql`. Eine vollständige Anleitung
einschließlich Datenbankanlage, Collation-, Versions-, Erfolgs- und
Berechtigungsprüfung steht unter
[`Documentation/Reference/Installation.md`](./Documentation/Reference/Installation.md).

### Alternative: SQLCMD-Installer

Der Include-Weg über `Code/Install/Install_All.sql` bleibt für automatisierte
Installationsabläufe verfügbar. Dafür muss der Datenbankplatzhalter in allen
eingebundenen Dateien ersetzt und in SSMS der SQLCMD-Modus aktiviert werden.

## Erste Aufrufe

Die Beispielaufrufe verwenden absichtlich keine Datenbankqualifizierung:

```sql
EXEC [monitor].[USP_AnalysisNavigator]
      @Suchbegriff = N'Benutzer warten';

EXEC [monitor].[USP_CurrentOverview];

EXEC [monitor].[USP_CurrentRequests]
      @ResultSetArt = 'CONSOLE';

EXEC [monitor].[USP_CurrentRequests]
      @GesamtenSqlTextEinbeziehen = 1
    , @InputBufferEinbeziehen     = 1
    , @MaxSqlTextZeichen          = 0;

EXEC [monitor].[USP_CurrentBlocking];

EXEC [monitor].[USP_CurrentMemoryGrants];

EXEC [monitor].[USP_ObjectAnalysis]
      @SchemaNames = N'dbo'
    , @ObjectNames = N'[ExampleObject]';
```

Für die vollständige Aufrufsammlung siehe:

- [`Code/Examples/040_Schnellreferenz_Aufrufe.sql`](./Code/Examples/040_Schnellreferenz_Aufrufe.sql)
- [`Code/Examples/041_Beispielaufrufe_Alle_Funktionalitaeten.sql`](./Code/Examples/041_Beispielaufrufe_Alle_Funktionalitaeten.sql)
- [`Documentation/Reference/Call_Catalog.md`](./Documentation/Reference/Call_Catalog.md)

## Ausgabearten

Öffentliche Analyse-Procedures verwenden standardmäßig:

```sql
@ResultSetArt = 'CONSOLE'
```

| Ausgabeart | Zweck |
|---|---|
| `CONSOLE` | genau eine lesbare Fachansicht; bei Leere eine verständliche Zeile |
| `RAW` | stabiler technischer Resultset-Vertrag |
| `TABLE` | benannte typisierte Ergebnisse in lokale `#Temp`-Tabellen des Aufrufers |
| `NONE` | keine fachlichen Resultsets, beispielsweise bei reiner JSON-Nutzung |

Für `TABLE` legt der Aufrufer je gewünschtem benannten Ergebnis eine leere
Tabelle mit genau einer beliebigen Seed-Spalte an:

```sql
CREATE TABLE #CurrentRequests_Result ([Dummy] int NULL);

EXEC [monitor].[USP_CurrentRequests]
      @MaxZeilen = 100
    , @ResultSetArt = 'TABLE'
    , @ResultTablesJson = N'{"requests":"#CurrentRequests_Result"}';

SELECT * FROM #CurrentRequests_Result;
```

Unterstützt werden bewusst nur lokale `#Temp`-Tabellen. Eine bereits exakt passende Tabelle wird ergänzt; eine leere Ein-Spalten-Tabelle wird unabhängig von Spaltenname und -typ angepasst. Andere abweichende oder gefüllte Tabellen werden ohne Strukturänderung abgelehnt. Viele Procedures können zusätzlich JSON über `@Json nvarchar(max) OUTPUT` zurückgeben. Alle Ausgabearten werden aus derselben kanonischen Datenbasis erzeugt.

## Filter- und Limitvertrag

- Exakte Mehrfachfilter verwenden Pipe-Listen, beispielsweise `N'[Objekt A]|[Objekt B]'`.
- Pipe und Punkt werden nur außerhalb korrekt geklammerter SQL-Identifier als Trennzeichen interpretiert.
- Patternfilter sind von exakten Listen getrennt und unterstützen `like:`, versionsabhängig auch `regex:` und `regexi:`.
- `@MaxZeilen > 0` begrenzt die Ergebnismenge.
- `@MaxZeilen = 0` oder `NULL` bedeutet keine Ergebnisbegrenzung.
- Negative Grenzwerte sind ungültig.
- Ergebnisumfang, Zahl der Analyseobjekte und Zahl der Datenbanken werden durch getrennte Parameter gesteuert.

## SQL-Statement-Kontext

Bei laufenden Requests wird nicht nur der gesamte Batch angezeigt. Das Framework berücksichtigt `statement_start_offset` und `statement_end_offset`, um das aktuell ausgeführte Statement innerhalb eines Batches oder einer Stored Procedure exakt zu bestimmen.

Zusätzlich stehen – abhängig vom Aufruf – folgende Informationen zur Verfügung:

- qualifizierter Modulname und Modultyp
- Statement-Start- und Endposition
- Statement-Zeilenbereich
- vollständiger Batchtext
- vollständiger Modultext
- Input Buffer
- SQL-, Plan- und Statement-Handles
- Query Hash und Query Plan Hash
- Verschachtelungs-, Scheduler-, Task- und Transaktionskontext

## Repositorystruktur

```text
Code/
├── 00_Setup/
├── 01_Common/
├── 02_CurrentState/
├── 03_ObjectIndex/
├── 04_PlanCache/
├── 05_QueryStore/
├── 06_ExtendedEvents/
├── 07_Infrastructure/
├── 08_ServerHealth/
├── 09_VersionAdaptive/
├── Examples/
├── Install/
└── Tests/

Documentation/
├── Architecture/
├── Analysis_Guides/
├── Operations/
├── Quality/
└── Reference/

Metadata/
├── Inventory/
└── Quality/
```

### Bedeutung

- `Code/` enthält die kanonischen, ausführbaren SQL-Objekte, Installer, Tests und Beispiele.
- `Documentation/` beschreibt Einstieg, Architektur, Funktionsumfang, Verträge, Betrieb und vollständige Komponentenreferenz.
- `Metadata/` enthält maschinenlesbare Objekt-, Parameter-, Systemquellen-, Abhängigkeits- und Capability-Inventare sowie Prüfergebnisse.

## Performance- und Sicherheitsprinzipien

Das Framework folgt den folgenden Betriebs- und Schutzregeln:

- Lesende Diagnosepfade bilden den Standard.
- Ressourcenintensive Katalog-, Plan- und Cross-Database-Analysen sind begrenzt und gesondert steuerbar.
- Systemkataloge werden möglichst direkt und mit begrenztem Blocking-Risiko gelesen.
- Fehlende optionale Quellen führen nach Möglichkeit zu strukturierten Teil- oder Verfügbarkeitsstatus und nicht zum Abbruch unabhängiger Module.
- Versionsabhängige Syntax wird erst nach einer Capability-Prüfung verwendet.
- Dynamisches SQL verwendet validierte Identifier und `QUOTENAME`.
- Resultsets werden nicht automatisch anonymisiert. SQL-Text, Namen, Clientkontext, Pläne, Ereignisse und Histogrammwerte können schutzbedürftige Laufzeitinformationen enthalten.
- Optionale Text-, XML-, Ereignis-, JSON-, TABLE- und Persistenzpfade werden nur im angeforderten Scope verwendet und unterliegen den dokumentierten Aufbewahrungs- und Zugriffsvorgaben.

## Dokumentation

Der aktuelle Inventory-Vertrag umfasst 98 öffentliche Procedures und 68 unterstützende Objekte: acht Views, 27 TVFs, 16 interne Procedures und 17 Tabellen. Jedes der insgesamt 166 Objekte besitzt einen eindeutigen Referenzpfad. Scalar-Valued Functions (SVFs) sind derzeit nicht installiert.

- [Hier beginnen: passende Analyse finden](./Documentation/Analysis_Guides/Start_Here.md)
- [Analysis Navigator – vollständiger Vertrag](./Documentation/Reference/Analysis_Navigator.md)
- [Projektübersicht](./Documentation/README.md)
- [Analysehandbuch](./Documentation/Analysis_Guides/README.md)
- [Installation](./Documentation/Reference/Installation.md)
- [Procedure-Referenz](./Documentation/Reference/Procedure_Reference.md)
- [Detaillierte Referenz aller unterstützenden Frameworkobjekte](./Documentation/Reference/Object_Reference.md)
- [Spezialfallmodule: Evidenz, Kosten und Grenzen](./Documentation/Architecture/Special_Case_Modules.md)
- [SQL-Server-2025-JSON-Index-Inventar](./Documentation/Architecture/SQL_Server_2025_JSON_Index_Inventory.md)
- [SQL-Server-2025-TempDB-Resource-Governance](./Documentation/Architecture/SQL_Server_2025_TempDB_Resource_Governance.md)
- [Resultset-Konventionen](./Documentation/Reference/Resultset_Conventions.md)
- [RAW-, CONSOLE-, TABLE- und JSON-Architektur](./Documentation/Architecture/Output_RAW_CONSOLE_JSON.md)
- [SQL-Text-, Statement-, Batch- und Modulkontext](./Documentation/Architecture/SQL_Text_Statement_Batch_Module.md)
- [Datenschutz und Laufzeitausgaben](./Documentation/Architecture/Runtime_Data_Privacy.md)
- [Vertrag und Betrieb des optionalen Snapshot-/Baseline-Pakets](./Documentation/Architecture/Snapshot_Baseline_Package_Contract.md) ([Betriebsleitfaden](./Documentation/Operations/Snapshot_Baseline_Operations.md))
- [Scope und Grenzen des Frameworks](./Documentation/Reference/Scope_and_Limitations.md)
- [Bekannte Einschränkungen](./Documentation/Quality/Known_Issues.md)
- [Performance- und Risikobewertung](./Documentation/Quality/Performance_and_Risk_Assessment.md)
- [Testmatrix und unterstützte Nachweise](./Documentation/Quality/Test_Matrix.md)
- [Release Notes](./Documentation/Quality/Release_Notes.md)
- [Lab-Lernpfad: Szenarien erkunden](./Lab/Scenarios/LEARNING_PATH.md)

## Qualität und Projektstatus

Der veröffentlichte Bestand besitzt reproduzierbare statische API-, Installer-, Inventar- und Dokumentationsprüfungen. Die fachlichen Laufzeitnachweise und unterstützten Kombinationen stehen in der [Testmatrix](./Documentation/Quality/Test_Matrix.md); `NOT_EXECUTED` ist ausdrücklich kein Testnachweis.

Der frameworkweite Ausgabe-Vertrag 2.0 verarbeitet ohne expliziten Filter alle
sichtbaren Online-Benutzerdatenbanken, fordert eine Bestätigung nur für den
tatsächlich aktivierten High-Impact-Pfad und verwendet für TABLE ausschließlich
`@ResultTablesJson`. Das Resultsetinventar dokumentiert stabile Namen und native
Schemas; alle Exportziele stammen aus derselben Aufrufmaterialisierung.

Die maschinenlesbare Matrix steht ergänzend unter [`Metadata/Quality/Test_Matrix.csv`](./Metadata/Quality/Test_Matrix.csv).
