# Backlog für zusätzliche Betriebs- und Versionsdiagnosen

Stand: 2026-07-21
Status: `PARTIALLY_IMPLEMENTED` – `OPS-001` bis `OPS-004` sowie `SQL25-001` bis `SQL25-004` sind `IMPLEMENTED_ACTIONS_GATE`
Maschinenlesbarer Backlog: `Metadata/Quality/Future_Enhancement_Backlog.csv`

## Ziel und Abgrenzung

Dieser Vertrag hält implementierte und weiterhin offene Diagnosebereiche fest, die aus dem Abgleich des Frameworkbestands mit Microsoft-Dokumentation, SQL Assessment API, BPCheck, First Responder Kit und Glenn Berrys Diagnostic Information Queries entstanden sind.

Die Einträge ergänzen den zustandslosen Kern. Sie ändern weder den abgeschlossenen Status der bestehenden P0-/P1-/P2-Spezialfallmatrix noch den separat als `IMPLEMENTED_ACTIONS_GATE` abgenommenen ersten SC-023-Snapshot- und Baseline-Slice.

Eine Abweichung oder ein Einzelindikator ist grundsätzlich Evidenz für eine weitere Prüfung und kein automatischer Fehlernachweis. Kein Modul darf Konfigurationen ändern, Logs rotieren, Remoteverbindungen testen, Wartung starten oder DDL ausführen.

## Priorisierte Lücken

| ID | Priorität | Bereich | Umsetzung | Wesentliche Grenze |
|---|---|---|---|---|
| `OPS-001` | P1 | Datenbankkonfiguration und Drift | implementiert: `monitor.USP_DatabaseConfigurationAnalysis` | Abweichung ist nicht automatisch Fehlkonfiguration |
| `OPS-002` | P1 | Worker- und Scheduler-Druck | implementiert: `monitor.USP_WorkerPressureAnalysis` | `THREADPOOL` rechtfertigt nicht automatisch mehr Worker |
| `OPS-003` | P1 | aktuell ausstehende I/O-Requests | implementiert: `monitor.USP_CurrentIO.pendingIo` | einzelner Pending Request beweist keinen Storagefehler |
| `OPS-004` | P1 | SQL-Server- und Agent-Errorlogs | implementiert: `monitor.USP_ErrorLogAnalysis` | begrenztes Lesen; kein Logwechsel und kein Volltext im Default |
| `SQL25-001` | P2 | Vector-Index-Laufzeit | neue Detailanalyse oder Erweiterung der Objektanalyse | Capability, Zustand und Maintenance getrennt bewerten |
| `SQL25-002` | P2 | JSON-Index-Inventar | bestehende Objekt- und Indexinventare erweitert | versionsadaptiv; bewusst keine überdimensionierte Einzel-Procedure |
| `SQL25-003` | P2 | TempDB Resource Governance | Resource-Governor- und TempDB-Module erweitert | gespeichertes/wirksames Limit, Nutzung, Peak, Verletzung und Resetgrenze getrennt |
| `SQL25-004` | P2 | Statistiken auf lesbaren Secondaries | `monitor.USP_Statistics` versionsadaptiv erweitert | aktuelle Replica-Rolle und Statistikherkunft explizit getrennt |
| `SQL25-005` | P2 | Query Store auf Secondary Replicas | Query-Store-Module replica-aware machen | fehlende Replica-Evidenz nicht als gesunden Zustand behandeln |
| `OPS-005` | P2 | Linked Server | neue `monitor.USP_LinkedServerAnalysis` | Remoteverbindungstest ausschließlich opt-in |
| `OPS-006` | P2 | Datenbankportabilität | neue `monitor.USP_DatabasePortabilityAnalysis` | Befunde sind Migrationsrisiken, keine automatische DDL-Anweisung |
| `OPS-007` | P3 | aktive und dormante Cursor | opt-in Ergänzung der Sessionanalyse | begrenzter, aktueller Session-Scope statt Servervollscan |
| `OPS-008` | P2 | `msdb`-Gesundheit und Retention | neue Analyse oder Erweiterung der Betriebsanalyse | zu kurze und zu lange Retention können beide problematisch sein |
| `OPS-009` | P3 | Benutzerobjekte in Systemdatenbanken | leichtes Inventarmodul | keine automatische Löschung oder Verlagerung |

## P1-Umfang

Der folgende P1-Umfang wurde in Welle 2 umgesetzt und durch den synthetischen Drei-Versionen-Vertrag `191` abgenommen.

### OPS-001 – Datenbankkonfiguration und Drift

Quellen: `sys.databases` sowie datenbanklokal `sys.database_scoped_configurations` und `sys.database_query_store_options`; versionsabhängige Spalten werden erst nach Katalogprüfung referenziert.

Mindestens auszuwerten sind Statistikoptionen, `AUTO_CLOSE`, `AUTO_SHRINK`, RCSI und Snapshot Isolation, Parameterisierung, Recovery Model, `PAGE_VERIFY`, ADR, Optimized Locking, Compatibility Level, Collation, Query Store sowie verfügbare Database Scoped Configurations. Der Default vergleicht sichtbare Datenbanken lokal; ein Sollprofil muss ausdrücklich gewählt werden. Fleet-Drift bleibt SC-024.

False-Positive-Grenze: RCSI, forcierte Parameterisierung, asynchrone Statistikaktualisierung und andere Optionen sind workloadabhängige Entscheidungen. Das Modul meldet Zustand, Abweichung und Prüfkontext, aber keine universelle Sollkonfiguration.

### OPS-002 – Worker- und Scheduler-Druck

Quellen: `sys.dm_os_schedulers`, begrenzte Aggregate aus `sys.dm_os_workers`, aktuelle Tasks und Requests sowie korrelierte Waits.

Auszugeben sind mindestens `work_queue_count`, aktive und aktuelle Worker, verfügbare Worker gegenüber dem wirksamen Maximum, sichtbare Warteschlangen, kurze Sample-Deltas sowie Korrelation mit `THREADPOOL`, Blocking und langen Requests.

False-Positive-Grenze: Das Modul darf aus `THREADPOOL` oder hoher Workerauslastung nicht automatisch eine Erhöhung von `max worker threads` ableiten. Lange blockierte oder laufende Batches sind als häufige Gegenhypothese sichtbar zu halten.

### OPS-003 – Pending I/O

`monitor.USP_CurrentIO` erhält ein semantisch benanntes Resultset `pendingIo` auf Basis von `sys.dm_io_pending_io_requests`, korreliert mit `sys.dm_io_virtual_file_stats`, Datenbank, Datei, Scheduler, aktuellen Requests und passenden Waits.

Relevant sind Dauer, Anzahl, wiederholtes Auftreten, Pending im SQL-Server- oder Betriebssystempfad und betroffener Scope. Vollständige Dateipfade gehören nur in ausdrücklich gewählte Detail-/RAW-Ausgaben.

False-Positive-Grenze: Ein einzelner kurzfristiger Pending Request wird nicht als Storageproblem klassifiziert.

### OPS-004 – strukturierte Errorlog-Analyse

Die Analyse liest SQL-Server- und optional Agent-Errorlogs über begrenzte Zeit- und Archivfenster. Der Default liefert Kategorien, Anzahl, ersten und letzten Zeitpunkt sowie Quellstatus. Vollständiger Meldungstext ist opt-in und unterliegt dem bestehenden Ausgabe- und Datenschutzvertrag.

Zu kategorisieren sind unter anderem I/O-Fehler und -Warnungen, lange I/O-Vorgänge, Backup-/Restorefehler, Cache Flushes, häufiges Autogrowth, Dumps/Assertions, Login-/Connectivity-Probleme sowie Agent-, Replikations- und Log-Shipping-Fehler.

Das Modul führt keinen Logwechsel aus. Fehlende Rechte, sehr große Logs und nicht unterstützte Quellen erzeugen einen Partialstatus statt eines Gesamtfehlers.

## SQL-Server-2025-Vertiefungen

### SQL25-001 und SQL25-002 – Vector- und JSON-Indizes

SQL25-001 liefert über `sys.vector_indexes` und
`sys.dm_db_vector_indexes` den getrennten Katalog- und Wartungszustand
vorhandener Vector-Indizes. SQL25-002 integriert `sys.json_indexes` und
`sys.json_index_paths` in `USP_ObjectInventory` und
`USP_ServerFeatureCapabilities`. Alle Referenzen werden vor dynamischer
Verwendung per Versions-, Feature- und Spaltenprüfung abgesichert; jede
fachliche Quelle wird je Datenbank und Procedure höchstens einmal gelesen.
JSON-Dokumentwerte werden nicht erhoben, und die Inventur erzeugt keine
Health- oder DDL-Aussage.

### SQL25-003 – TempDB Resource Governance

`monitor.USP_ResourceGovernorAnalysis` und `monitor.USP_CurrentTempDB` liefern das gemeinsame benannte Resultset `tempdbGovernance`. Es trennt gespeicherte MB-/Prozentlimits, die wirksame Limitquelle, aktuelle und maximale TempDB-Datennutzung, `total_tempdb_data_limit_violation_count` und `statistics_start_time`. MB hat Vorrang; Prozentlimits werden nur bei geeigneter TempDB-Dateikonfiguration als wirksam berechnet. Der Current-State-Orchestrator materialisiert die Resource-Governor-Quellen einmal und reicht sie an `USP_CurrentTempDB` weiter. Nicht konfigurierte Governance ist kein Fehler; eine Verletzung ist ohne Workloadkontext keine Ursachenfeststellung. Version Store und TempDB-Log liegen außerhalb dieser Governance.

### SQL25-004 – Replica-aware Statistics

`monitor.USP_Statistics` erhält `is_temporary`, `replica_role_id`,
`replica_role_desc` und `replica_name` versions- und capability-adaptiv. Die
aktuelle Datenbankrolle wird davon getrennt und mit eigenem Quellenstatus
ausgegeben. Auf SQL Server 2019/2022 werden die neuen Spalten nicht
referenziert. Ab SQL Server 2025 wird ihr Pflichtschema vor Dynamic SQL
geprüft. `sys.stats` wird je Datenbank einmal materialisiert; inkrementelle
Details verwenden diese Materialisierung weiter. Herkunft ist weder aktuelle
Rolle noch Verwendungs-, Health- oder Wartungsnachweis.

### SQL25-005 – Replica-aware Query Store

Query-Store-Auswertungen sollen `sys.query_store_replicas` fachlich verwenden,
statt dessen Existenz nur als Capability zu erkennen. Primary-, Secondary- und
unvollständige Evidenz dürfen nicht vermischt werden.

## Weitere Betriebsanalysen

### OPS-005 – Linked Server

Der Defaultpfad inventarisiert sichtbare Linked Server, Provider, Product, Data Access, RPC/RPC OUT, Collation-Kompatibilität und aktuelle Remote-/OLEDB-Waits. Provideralter und Portabilität werden als Prüfhinweise ausgegeben.

`sp_testlinkedserver` ist ausschließlich ein ausdrücklicher opt-in Pfad: Der Aufruf erzeugt echten Remotezugriff, kann blockieren und externe Systeme oder Authentisierung belasten. Fehlende Testfreigabe ist keine Aussage über Erreichbarkeit.

### OPS-006 – Datenbankportabilität

Quellen sind mindestens `sys.dm_db_persisted_sku_features` und `sys.dm_db_uncontained_entities`. Das Modul unterstützt Editionwechsel, Restore auf eine andere Instanz und Migration, ohne Abhängigkeiten automatisch zu entfernen oder zu ändern.

### OPS-007 – Cursor

`sys.dm_exec_cursors` kann als opt-in Detailquelle Worker Time, Reads, Writes und Dormant Duration zu einem begrenzten Session-Scope liefern. Ein vorhandener Cursor ist kein Problem; Laufzeit, Ressourcenverbrauch, Dormanz und wiederholtes Auftreten liefern den Kontext.

### OPS-008 – `msdb`-Gesundheit

Zu prüfen sind Größe, Wachstum und Retention von Backup-, Restore-, Job-, Database-Mail- und Maintenance-Historien. Das Modul führt keine Bereinigung aus. Kurze Retention kann Forensik verhindern, lange Retention kann unnötiges Wachstum verursachen.

### OPS-009 – Benutzerobjekte in Systemdatenbanken

Ein leichter Inventarpfad meldet sichtbare Benutzerobjekte in `master`, `model` und `msdb`. Der Befund ist ein Wartungs- und Portabilitätsrisiko, aber keine automatische Lösch- oder Verschiebeanweisung.

## Umsetzungsreihenfolge

1. Abgeschlossen: `OPS-001` bis `OPS-004` in Welle 2.
2. Abgeschlossen: `SQL25-001` bis `SQL25-004` als versionsadaptive Slices.
3. Offen: `SQL25-005`.
4. `OPS-005`, `OPS-006` und `OPS-008`.
5. `OPS-007` und `OPS-009` als kleine opt-in beziehungsweise Inventarmodule.

Wenn Historie, Trends und Maintenance-Wirkung wichtiger sind als weitere Momentaufnahmen, ist die alternative nächste Welle der Ausbau des bereits abgenommenen ersten SC-023-Slice um zusätzliche Sammler und Rollups. Dieser Ausbau hat höheren Zeitreihennutzen und benötigt weiterhin einen expliziten Persistenz-, Retention-, Scheduler-, Größenbudget- und Berechtigungsbetrieb.

## Gemeinsame Abnahmekriterien

Jeder Eintrag benötigt:

1. Capability- und Spaltenprüfung vor versionsabhängiger Referenz.
2. Unterstützt-, nicht unterstützt-, deaktiviert-, leer- und unberechtigt-Fälle.
3. kontrollierte positive Evidenz ohne reale Repositorydaten.
4. Scope-, Laufzeit-, Zeilen- und gegebenenfalls Samplegrenzen.
5. SQL-Server-2019-, 2022- und 2025-Vertragstests.
6. RAW-, CONSOLE-, NONE-, JSON- und gegebenenfalls TABLE-Verträge.
7. Partialstatus je isolierter Quelle statt Abbruch des Gesamtmoduls.
8. dokumentierte Reset-, Zeit-, Aggregations- und False-Positive-Grenzen.
9. Integration in Hilfe, Inventar, Installer, Resultsetinventar und Release Gate.
10. manuelle Datenschutzprüfung zusätzlich zum automatisierten Repositorygate.

## Quellen

### Microsoft

- [SQL Assessment API](https://learn.microsoft.com/en-us/sql/tools/sql-assessment-api/sql-assessment-api-overview?view=sql-server-ver17)
- [ALTER DATABASE SCOPED CONFIGURATION](https://learn.microsoft.com/en-us/sql/t-sql/statements/alter-database-scoped-configuration-transact-sql?view=sql-server-ver17)
- [`sys.dm_os_schedulers`](https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-os-schedulers-transact-sql?view=sql-server-ver17)
- [`max worker threads`](https://learn.microsoft.com/en-us/sql/database-engine/configure-windows/configure-the-max-worker-threads-server-configuration-option?view=sql-server-ver17)
- [`sys.dm_io_pending_io_requests`](https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-io-pending-io-requests-transact-sql?view=sql-server-ver17)
- [`sys.sp_readerrorlog`](https://learn.microsoft.com/en-us/sql/relational-databases/system-stored-procedures/sp-readerrorlog-transact-sql?view=sql-server-ver17)
- [`sys.dm_db_vector_indexes`](https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-views/sys-dm-db-vector-indexes-transact-sql?view=sql-server-ver17)
- [`sys.json_indexes`](https://learn.microsoft.com/en-us/sql/relational-databases/system-catalog-views/sys-json-indexes-transact-sql?view=sql-server-ver17)
- [TempDB Space Resource Governance](https://learn.microsoft.com/en-us/sql/relational-databases/resource-governor/tempdb-space-resource-governance?view=sql-server-ver17)
- [Persisted Statistics for Readable Secondary Replicas](https://learn.microsoft.com/en-us/sql/relational-databases/performance/persisted-stats-secondary-replicas?view=sql-server-ver17)
- [Query Store for Secondary Replicas](https://learn.microsoft.com/en-us/sql/relational-databases/performance/query-store-for-secondary-replicas?view=sql-server-ver17)
- [`sys.servers`](https://learn.microsoft.com/en-us/sql/relational-databases/system-catalog-views/sys-servers-transact-sql?view=sql-server-ver17)
- [`sp_testlinkedserver`](https://learn.microsoft.com/en-us/sql/relational-databases/system-stored-procedures/sp-testlinkedserver-transact-sql?view=sql-server-ver17)
- [`sys.dm_db_persisted_sku_features`](https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-db-persisted-sku-features-transact-sql?view=sql-server-ver17)
- [`sys.dm_exec_cursors`](https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-exec-cursors-transact-sql?view=sql-server-ver17)
- [`master`](https://learn.microsoft.com/en-us/sql/relational-databases/databases/master-database?view=sql-server-ver17) und [`msdb`](https://learn.microsoft.com/en-us/sql/relational-databases/databases/msdb-database?view=sql-server-ver17)

### Öffentliche Vergleichskataloge

- [Microsoft SQL Assessment DefaultRuleset](https://github.com/microsoft/sql-server-samples/blob/master/samples/manage/sql-assessment-api/DefaultRuleset.csv)
- [Microsoft BPCheck](https://github.com/microsoft/tigertoolbox/blob/master/BPCheck/README.md)
- [First Responder Kit / sp_Blitz](https://github.com/BrentOzarULTD/SQL-Server-First-Responder-Kit/blob/dev/sp_Blitz.sql)
- [Glenn Berry, Diagnostic Information Queries, Januar 2026](https://glennsqlperformance.com/2026/01/02/sql-server-diagnostic-information-queries-for-january-2026/)

Die Vergleichskataloge dienen ausschließlich der Funktions- und Lückenanalyse. Es wurde kein fremder Quellcode übernommen.
