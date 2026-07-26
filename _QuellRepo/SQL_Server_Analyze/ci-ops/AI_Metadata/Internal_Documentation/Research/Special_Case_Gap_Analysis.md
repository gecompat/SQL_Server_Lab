# Tiefenanalyse fehlender Auswertungen und Spezialfälle

**Analysestand:** 17. Juli 2026  
**Repositorybasis:** Branch main, Commit 2cbd57d1348b6d8a7e945863f2c99a5938e18d39  
**Zielplattform:** SQL Server 2019 und höher  
**Bewertungsziel:** fehlende oder nur teilweise vorhandene Diagnoseauswertungen identifizieren, nach Nutzen, Risiko, Kosten und Bedingtheit priorisieren und als umsetzbaren Backlog beschreiben

> Diese Datei ist die historische Entscheidungs- und Priorisierungsbasis des angegebenen Commits. Die danach umgesetzten P0-/P1-Punkte und ihr aktueller Status stehen in `Documentation/Architecture/Special_Case_Modules.md`, `Metadata/Quality/Special_Case_Gap_Backlog.csv` und `Metadata/Quality/Special_Case_Release_Audit.json`; die nachfolgenden Bestandszahlen und Formulierungen werden als damalige Evidenz nicht rückwirkend umgeschrieben.

## 1. Ergebnis in Kurzform

Das Framework besitzt bereits eine ungewöhnlich breite Basis für zustandslose T-SQL-Diagnose: Live-Requests, Blocking, Waits, Transaktionen, Memory Grants, TempDB, I/O, Log, Objekt- und Indexdiagnose, Showplan, Query Store, Extended Events, Infrastruktur, Serverzustand und versionsadaptive Capability-Erkennung sind vorhanden.

Die größten verbleibenden Lücken liegen nicht bei einem weiteren allgemeinen Request- oder Indexreport. Sie liegen an den Rändern, an denen seltene Vorfälle besonders teuer werden:

1. **Integrität und Korruptionsindizien:** suspect_pages, PAGE_VERIFY, letzter erfolgreicher CHECKDB-Nachweis, beschädigte Backupmetadaten, HADR-Seitenreparatur und kritische system_health-Ereignisse sind noch nicht zu einer Auswertung verbunden.
2. **Kapazität und physischer Speicher:** Datei-, Volume-, Autogrowth- und Freiraumrisiken werden noch nicht als serverweite Prognose korreliert.
3. **Engine-Notfälle:** system_health und sp_server_diagnostics werden nicht domänenspezifisch für Non-Yielding Scheduler, Speicherfehler, Dumps und kritische Zustände ausgewertet.
4. **Performance-Counter:** sys.dm_os_performance_counters fehlt; damit fehlen korrekt typisierte Moment-, Delta-, Rate- und Quotientenwerte.
5. **Moderne Optimizerfunktionen:** PSP, OPPO, Dispatcher-/Variant-Pläne, Plan Feedback, optimiertes Plan Forcing und Automatic Tuning werden nur teilweise oder indirekt erfasst.
6. **Interne Contention und Speicher:** Latch-/Spinlock-Deltas, Hot-Page-Zuordnung, Buffer-Pool-Verteilung und Resource-Monitor-Signale fehlen.
7. **Wiederherstellbarkeit:** Backups werden inventarisiert, aber LSN-Ketten, Forks, Checksum-/Damage-Indikatoren und Restore-Historie noch nicht als belastbare Recovery-Evidenz ausgewertet.
8. **Spezial-Engines:** In-Memory OLTP, Temporal, Service Broker, Full-Text sowie Change Tracking/CDC/lokale Replikation besitzen inzwischen bedingte Fachmodule; Verschlüsselung und weitere nur bei Nutzung relevante Features bleiben offen.
9. **Korrelation:** Einzelbefunde sind breit vorhanden, aber es fehlt eine zentrale Finding-Schicht mit Evidenz, Zeitbezug, Konfidenz und Gegenindizien.
10. **Langzeitbezug:** Baselines, Snapshots, Deltas und Anomalien fehlen bewusst, weil der aktuelle Kern zustandslos ist. Das ist keine versehentliche Lücke, sondern ein späteres, gesondert zu entscheidendes Paket.

Die Datenschutzpräzisierung ändert die fachliche Bewertung: Login-, Benutzer-, Firmen- oder Umgebungswerte in einer berechtigten interaktiven SELECT-Ausgabe sind zulässig und oft erforderlich. Verboten ist ihre Übernahme in herunterladbare oder versionierte Artefakte. Das Framework muss daher nicht seine Live-Diagnose anonymisieren; es muss den Persistenz- und Exportübergang absichern.

## 2. Korrektur früherer Bewertungen

### 2.1 Kein pauschales Ausgabeverbot

Die frühere pauschale Lesart, Identitäts- und Umgebungsdaten dürften nie ausgegeben werden, war fachlich zu weit. Eine Blocking-, Session- oder Sicherheitsdiagnose ohne Login-, Session-, Host-, Datenbank- oder Objektreferenz verliert einen wesentlichen Teil ihres Nutzens. Maßgeblich ist die in Runtime_Data_and_Repository_Privacy.md festgelegte Artefaktgrenze.

### 2.2 Kein seriöser Gesamtabdeckungsprozentsatz

Ein einzelner Prozentwert für die Funktionsabdeckung ist nicht belastbar. Es gibt keine endliche, allgemein anerkannte Grundgesamtheit aller SQL-Server-Diagnosefälle; Edition, Version, Plattform, aktivierte Features und Betriebsmodell verändern sie. Frühere grobe Prozentangaben werden deshalb nicht fortgeführt.

Stattdessen verwendet diese Analyse:

- eine quellenbasierte Capability-Matrix,
- konkrete, im Repository nachweisbare Objekte und Datenquellen,
- eine Trennung von universellen und featureabhängigen Lücken,
- Kosten- und Berechtigungsklassen,
- überprüfbare Abnahmekriterien je Backlogpunkt.

### 2.3 Bereits vorhandene Fähigkeiten nicht doppelt planen

Die erneute Prüfung hat mehrere Bereiche bestätigt, die nicht als fehlend bewertet werden dürfen:

- exakte Statementextraktion aus Request-Offsets,
- optionaler Batch-, Modul- und Input-Buffer-Kontext,
- aktuelle Waits sowie kumulative und innerhalb eines Aufrufs gesampelte Wait-Deltas,
- Index Usage einschließlich separater XTP-Indexnutzung,
- Index Operational und Physical Stats,
- inkrementelle Statistikdetails,
- Columnstore-Rowgroups, Segmente und Dictionaries,
- Showplan-Warnungen, Operatoren, Objekte, Statistiken, Cardinality, Parameter und Memory Grants,
- optionaler letzter tatsächlicher beziehungsweise Live-Plan über dm_exec_query_statistics_xml,
- Query-Store-Laufzeit, Waits, Planwechsel, Regressionen, Forced Plans und Query Store Hints,
- vorhandene XE-Sessions, Targets, Eventfiles, Deadlocks und Blocked-Process-Ereignisse,
- Agent, Resource Governor, Availability Groups, Backups, Log Shipping, Replikation und Data Capture als Infrastrukturgrundlage,
- CPU, NUMA/Scheduler, Memory, TempDB-Konfiguration, Betriebssystem, Trace Flags, Startup-Parameter und Sicherheitskonfiguration,
- Capability-Erkennung für mehrere SQL-Server-2025-Funktionen.

## 3. Methode und Evidenz

### 3.1 Repositoryprüfung

Der maschinenlesbare Objektbestand enthält 78 Frameworkobjekte:

- 63 Stored Procedures,
- 10 Funktionen,
- 5 Views.

Zusätzlich wurden 100 SQL-Dateien, 135 inventarisierte Systemquellen, öffentliche Parameterverträge, Capability-Metadaten, Architektur-, Forschungs- und Qualitätsdokumente sowie die Installerstruktur geprüft.

Gezielte Negativsuchen wurden unter anderem für folgende Quellen und Featurefamilien durchgeführt:

- sys.dm_os_performance_counters,
- sp_server_diagnostics,
- msdb.dbo.suspect_pages,
- sys.dm_os_spinlock_stats und tiefe Latchauswertung,
- sys.dm_os_ring_buffers und sys.dm_os_buffer_descriptors,
- sys.dm_db_page_info und sys.dm_os_volume_stats,
- tiefe In-Memory-OLTP-DMVs,
- Query-Store-Varianten und Plan Feedback,
- Automatic Tuning,
- HADR Auto Page Repair,
- Service Broker, Full-Text und Temporal-Fachauswertungen.

Ein fehlender Texttreffer beweist allein noch keine fachliche Lücke. Jeder Kandidat wurde deshalb gegen vorhandene Orchestratoren, verwandte Resultsets, offizielle Semantik und mögliche indirekte Abdeckung geprüft.

### 3.2 Externe Recherche

Primär wurden aktuelle Microsoft-Learn-Quellen zu den jeweiligen DMVs, Systemtabellen, Stored Procedures und Versionseigenschaften verwendet. Als Funktionsbenchmark wurden außerdem die öffentlich dokumentierten Prüfkataloge des Microsoft SQL Tiger Toolbox BPCheck und des SQL Server First Responder Kit betrachtet. Es wurde kein externer Code übernommen.

Community-Prüfkataloge dienen nur als Gegenprobe auf vergessene Vorfallklassen. Semantik, Berechtigungen, Resetverhalten und Overhead werden aus offiziellen Quellen abgeleitet.

### 3.3 Evidenzbegriffe

| Begriff | Bedeutung |
|---|---|
| Dokumentiert | Direkt aus offizieller Produktdokumentation ableitbar |
| Im Bestand nachgewiesen | In Code, Inventar oder Dokumentation des Repositorys vorhanden |
| Lücke | Relevante Auswertung fehlt oder deckt den Spezialfall nicht hinreichend ab |
| Bedingt | Nur relevant, wenn das zugehörige Feature eingesetzt wird |
| Bewertung | Priorisierung oder Architekturfolgerung aus Bestand und Quellen |

## 4. Prioritäts- und Kostenmodell

### Priorität

| Klasse | Bedeutung |
|---|---|
| P0 | Hoher Schaden oder Diagnoseverlust bei seltenen, kritischen Vorfällen; sollte vor einer breiten produktiven Freigabe geschlossen werden |
| P1 | Hoher operativer Nutzen; nächster Ausbau nach P0 |
| P2 | Wichtig bei Nutzung des jeweiligen Features oder in bestimmten Betriebsmodellen |
| P3 | Strategischer Ausbau, Langzeitkorrelation oder externe Integration |

### Ausführungskosten

| Klasse | Bedeutung |
|---|---|
| LOW | Katalog- oder gezielte DMV-Abfrage; für Standardmodus geeignet |
| MEDIUM | breitere DMV-/msdb-/XE-Auswertung oder kurze Stichprobe; standardmäßig begrenzen |
| HIGH_OPT_IN | potentiell teure Scans, XML-Aufbereitung oder datenbankweite Detailanalyse; nur explizit und nach Deep-Prüfung |
| EXTERNAL | außerhalb eines rein lesenden T-SQL-Kerns, beispielsweise echter Restore-Test oder Hostdiagnose |

Priorität und Kosten sind unabhängig. Eine P0-Auswertung darf teuer sein und muss dann als begrenztes Opt-in-Modul realisiert werden.

## 5. Abdeckungsmatrix

| Bereich | Heutige Abdeckung | Verbleibender Spezialfall | Bewertung |
|---|---|---|---|
| Sessions/Requests | stark | seltene Engine-Notfälle jenseits normaler Requests | P0 über Critical Engine Events |
| Blocking/Locks | stark | interne Latch-/Spinlock- und Hot-Page-Korrelation | P1 |
| Waits/Scheduler | gut | Perf-Counter, Latch-/Spinlock-Deltas, Worker-Erschöpfung als Finding | P0/P1 |
| Memory Grants | stark | Buffer-Pool-Verteilung, Resource-Monitor- und Broker-Signale | P1 |
| TempDB | gut | SQL-2025-Resource-Governance, persistente Engpassentwicklung | P1/P3 |
| Datei-I/O | gut | Volume-Freiraum, Autogrowth-Prognose, Mount-/File-Korrelation | P0 |
| Transaktionslog | gut | Recovery-Kette und Restore-Evidenz | P1 |
| Integrität | gering | Korruptionsindizien und CHECKDB-Evidenz | P0 |
| Plan Cache/Showplan | stark | zentrale IQP-/Feedback-/Variantenauswertung | P1 |
| Query Store | stark | PSP/OPPO, Plan Feedback, Automatic Tuning, Capture-Druck | P1 |
| Indizes/Statistiken | stark | Designkorrektheit, Skew/Histogramm, Grenzwert- und Erschöpfungsfälle | P1 |
| Columnstore | stark | Korrelation mit Speicher- und Ladepfaden | P2 |
| XE | gute generische Basis | domänenspezifischer system_health-Parser | P0 |
| Backup | Grundabdeckung | LSN-Ketten, Forks, Checksum/Damage und Restore-Historie | P1 |
| Availability Groups | Grundabdeckung | Auto Page Repair, Seeding, Cluster/Quorum/Lease, verteilte AG | P1 |
| SQL Agent | Grundabdeckung | Alertabdeckung, Operatorzustand, Schedule-Kollision, Mailgesundheit | P1 |
| In-Memory OLTP | nur Inventar/Indexnutzung | Speicher, Hash-Indizes, Checkpointdateien, Transaktionen | P2 bedingt |
| Temporal | Inventar plus implementierter Deep Dive | Zuordnung, Retention, approximative Kapazität und Indexbaseline; Zeilenkonsistenz bleibt außerhalb des read-only Metadatenmoduls | P2 bedingt |
| Service Broker | Inventar plus implementierter Deep Dive | Queue-Schalter/-Kapazität, Aktivierung, gruppierte Transmission- und Conversation-Zustände ohne Payload | P2 bedingt |
| Full-Text | Inventar plus implementierter Deep Dive | Kataloge/Indizes, aktuelle Populationen, aggregierte Batches, querybare Fragmente, Semantik, Memory Pools und FDHosts ohne Inhalte oder Crawl-Logs | P2 bedingt |
| Historie/Baseline | absichtlich vertagt | Deltas, Trends, Anomalien und Retention | P3, separates Paket |

## 6. P0 – zuerst zu schließende Lücken

### SC-001: Artefakt- und Datenschutzgrenze

**Problem:** Die Runtime-Ausgabe und das Repositoryverbot waren zuvor nicht sauber getrennt. Dadurch drohten entweder unbrauchbar anonymisierte Diagnosen oder versehentlich eingecheckte Echtdaten.

**Umsetzung:**

- verbindlichen Datenflussvertrag beibehalten,
- statische Prüfung für Dokumente, Beispiele, Fixtures und Lieferumfang ergänzen,
- Prüfmeldungen dürfen gefundene Werte nicht wiederholen,
- Export- und Persistenzfunktionen bis zu einer gesonderten Entscheidung nicht als freigegeben behandeln,
- spätere Redaction nicht mit der normalen SELECT-Ausgabe vermischen.

**Abnahme:** Ein synthetischer Testfall wird akzeptiert; ein realistisch markierter Artefaktwert stoppt die Lieferung; dieselbe Informationsklasse bleibt in einem flüchtigen Diagnose-Resultset technisch möglich.

### SC-002: Datenbankintegrität und Korruptionsindizien

**Vorgeschlagenes Modul:** monitor.USP_DatabaseIntegrityAnalysis

**Quellen:**

- msdb.dbo.suspect_pages,
- DATABASEPROPERTYEX mit LastGoodCheckDbTime,
- sys.databases.page_verify_option_desc,
- msdb-Backupmetadaten zu is_damaged und has_backup_checksums,
- sys.dm_hadr_auto_page_repair, sofern verfügbar,
- kritische system_health-Ereignisse,
- optional gezielte sys.dm_db_page_info-Auflösung für bereits identifizierte Seiten.

**Wichtige Grenzen:**

- Eine leere suspect_pages-Tabelle beweist keine fehlerfreie Datenbank.
- LastGoodCheckDbTime beweist nur einen dokumentierten erfolgreichen Lauf, nicht den aktuellen Zustand.
- RESTORE VERIFYONLY prüft Sicherungslesbarkeit und Vollständigkeit, aber nicht die logische Struktur aller Daten.
- Ein echter Restore- und CHECKDB-Test bleibt ein externer Betriebsprozess und darf nicht vom read-only Kern simuliert werden.
- DBCC CHECKDB darf nicht ungefragt ausgeführt werden. Das Framework soll Nachweise und Lücken anzeigen, nicht eigenmächtig eine potentiell schwere Prüfung starten.

**Kosten:** LOW für Metadaten; MEDIUM für system_health; gezielte Seitenauflösung MEDIUM und opt-in.

### SC-003: Datei-, Volume- und Wachstumskapazität

**Vorgeschlagenes Modul:** monitor.USP_DatabaseCapacityAnalysis

**Quellen:**

- sys.master_files und datenbanklokale sys.database_files,
- sys.dm_os_volume_stats,
- FILEPROPERTY für genutzten Datenbankdateiraum,
- sys.dm_io_virtual_file_stats,
- msdb-Backup-/Growth-Historie nur als optionale Evidenz,
- vorhandene Log- und TempDB-Module.

**Auswertung:**

- freier Volume-Speicher gegen mögliches Autogrowth,
- Prozentwachstum versus feste Wachstumsgröße,
- Maxsize, Growth deaktiviert, kleine Wachstumsinkremente und sehr große nächste Growth-Operation,
- mehrere Dateien auf demselben Volume,
- Daten-/Log-/TempDB-Konkurrenz,
- nur bei ausreichender Historie: Wachstumsrate und Zeit bis zur Erschöpfung,
- klare Unterscheidung zwischen Dateifreiraum und Volume-Freiraum.

**False-Positive-Schutz:** Keine pauschalen Grenzwerte ohne Größe, Wachstumsmuster, Plattform und Betriebsreserve. Eine Prognose ohne mindestens zwei belastbare Zeitpunkte muss als Momentaufnahme gekennzeichnet werden.

### SC-004: Kritische Engine-Ereignisse

**Vorgeschlagenes Modul:** monitor.USP_CriticalEngineEvents

**Quellen:**

- vorhandene system_health-Eventfiles,
- optional einmaliger Aufruf von sp_server_diagnostics,
- ergänzend Error Log nur als bewusst aktivierte, begrenzte Quelle.

**Ereignisklassen:**

- Non-Yielding Scheduler,
- schwerwiegende Fehler und Speicherfehler,
- Dumps und Assertions,
- lange Lock-, Latch- und PREEMPTIVE-Waits,
- Deadlocks,
- Connectivity- und Resource-Monitor-Signale,
- Health-Komponenten system, resource, query_processing und io_subsystem.

**Betriebsregeln:**

- vorhandene XE-Infrastruktur nur lesen, nie verändern,
- Eventfile bevorzugen; Runtime-Target nur nach bestehender Bestätigung wegen möglicher Flush-Nebenwirkung,
- sp_server_diagnostics als begrenzter One-Shot-Aufruf; kein endloser Repeat-Modus,
- mindestens fünf Sekunden Ausführungszeit berücksichtigen, wenn vollständige Komponentendaten erwartet werden,
- Error-Log-Text kann sensible Umgebungswerte enthalten und darf nicht als Repositorybeispiel gespeichert werden.

### SC-005: Korrekt typisierte Performance-Counter

**Vorgeschlagenes Modul:** monitor.USP_PerformanceCounters

**Quelle:** sys.dm_os_performance_counters

**Problem:** cntr_value ist ohne cntr_type, Basiszähler und Zeitbezug leicht falsch zu interpretieren. Einige Werte sind Momentaufnahmen, andere benötigen ein Delta, wieder andere eine Quotientenberechnung.

**Umsetzung:**

- ausgewählte Counterfamilien statt ungefilterter Vollausgabe,
- Countertyp und Objektinstanz immer mitführen,
- zwei begrenzte Samples für Rate-/Delta-Counter,
- Basiszähler im selben Sample konsistent zuordnen,
- SQL-Start-/Resetzeit und Sampleintervall ausgeben,
- Kategorien für Buffer Manager, Memory Manager, Access Methods, Databases, SQL Statistics, General Statistics, Locks, Latches, Workload Group und Resource Pool,
- Geben Sie keine universellen Alarmgrenzen als Fakten aus.

**Abnahme:** Tests mit Snapshot-, Delta- und Fraction-Counter zeigen korrekte Einheiten und verhindern Division durch Null oder Mischung verschiedener Samples.

## 7. P1 – hoher operativer Nutzen

### SC-006: Intelligent Query Processing und Plan Feedback

**Vorgeschlagenes Modul:** monitor.USP_IntelligentQueryProcessingAnalysis

Zu korrelieren sind Datenbank-Compatibility-Level, Query-Store-Zustand, PSP-/OPPO-Dispatcher und Varianten, Memory Grant Feedback, DOP Feedback, Cardinality Estimation Feedback, Query Store Hints, Forced Plans, optimiertes Plan Forcing und Automatic-Tuning-Empfehlungen.

Spezialfälle:

- PSP setzt die entsprechende Version und Compatibility Level 160 voraus.
- OPPO ist ein SQL-Server-2025-Spezialfall mit Compatibility Level 170.
- Ein Variant-Plan ist nicht automatisch ein Problem; er kann die beabsichtigte Optimierung sein.
- Feedback kann ausgesetzt, verworfen oder wiederholt angepasst werden.
- Query Store kann read-only, voll oder unter Capture-Druck sein; dann fehlen Evidenzen.
- Optimized Locking verändert die Aussagekraft einfacher Lock-Count-Heuristiken.

Das Modul soll erklären, welches Feature aktiv und welches Problem nachweisbar ist, statt Varianten oder Feedback pauschal als Fehler zu melden.

### SC-007: Interne Contention und Hot Pages

**Vorgeschlagenes Modul:** monitor.USP_InternalContentionAnalysis

Quellen:

- sys.dm_os_waiting_tasks,
- sys.dm_os_latch_stats,
- sys.dm_os_spinlock_stats,
- sys.dm_os_schedulers,
- sys.dm_db_page_info nur für bereits selektierte Page-Ressourcen,
- vorhandene Index-Operational- und TempDB-Auswertungen.

Latch- und Spinlockwerte sind kumulativ. Fachlich belastbare Raten benötigen zwei Samples und die Prüfung auf SQL-Neustart oder Counterreset. Spinlocknamen allein erlauben keine automatische Ursache. Das Resultat muss deshalb Evidenz, Delta, betroffene Scheduler/Tasks und einen Hinweis auf erforderliche Spezialanalyse liefern.

### SC-008: Buffer Pool und tiefer Speicherdruck

**Vorgeschlagenes Modul:** monitor.USP_BufferPoolAnalysis

Quellen:

- sys.dm_os_buffer_descriptors, nur begrenzt und opt-in,
- sys.dm_os_memory_clerks und vorhandene Memory-Auswertung,
- sys.dm_os_ring_buffers beziehungsweise Resource-Monitor-Signale,
- Performance-Counter,
- sys.dm_os_process_memory und sys.dm_os_sys_memory.

Auswertungen:

- Buffer-Pool-Anteile pro Datenbank und Cachetyp,
- saubere Trennung von committed, target, physical available und process working set,
- Stolen-/Plan-/Lock-/Columnstore-/XTP-Anteile,
- Hinweise auf externen versus internen Druck,
- keine automatische Empfehlung für max server memory allein aus einem Einzelwert.

### SC-009: Backupkette und Wiederherstellbarkeitsevidenz

**Vorgeschlagenes Modul:** monitor.USP_BackupChainAnalysis

Die bestehende Backupübersicht sollte um folgende Evidenz erweitert werden:

- Full-, Differential- und Log-LSN-Verknüpfung,
- Recovery Forks und Datenbank-GUID,
- copy_only, is_damaged, has_backup_checksums,
- Verschlüsselungs- und Kompressionsmetadaten,
- Medienfamilien und Stripingvollständigkeit,
- Restore-Historie und Zeit seit letztem nachgewiesenem Restore-Test,
- AG-Backuppräferenz und tatsächlicher Sicherungsort.

Grenzen:

- msdb-Historie kann bereinigt oder unvollständig sein.
- Eine lückenlos erscheinende Metadatenkette beweist keine lesbaren Medien.
- VERIFYONLY ist kein Ersatz für einen echten Restore mit CHECKDB.
- Dateipfade und Mediennamen sind Runtime-Umgebungsdaten und dürfen nicht in Repositoryartefakte kopiert werden.

### SC-010: Schema- und Designkorrektheit

**Vorgeschlagenes Modul:** monitor.USP_SchemaDesignAnalysis

Mögliche Teilprüfungen:

- nicht vertrauenswürdige oder deaktivierte CHECK- und Foreign-Key-Constraints,
- Foreign Keys ohne geeigneten unterstützenden Index,
- hypothetische, deaktivierte, doppelte oder stark überlappende Indizes,
- Indexschlüssel nahe Größen- oder Spaltenlimits,
- Identity- und Sequence-Erschöpfung,
- Heap-Forwarding in Verbindung mit vorhandenen Operational Stats,
- Partitionierungs- und Indexalignment,
- Dateigruppen-/LOB-/FILESTREAM-Sonderfälle,
- persistierte berechnete Spalten, gefilterte Indizes und SET-Option-Abhängigkeiten.

Die Ausgabe darf keine automatische DDL-Freigabe behaupten. Insbesondere Indexüberlappung benötigt Workload-, Constraint-, Include-, Filter-, Sortier- und Write-Cost-Kontext.

### SC-011: Statistikverteilung und Skew

**Vorgeschlagenes Modul:** Erweiterung von monitor.USP_StatisticsAnalysis

Die bestehende Aktualitäts- und Modification-Counter-Analyse ist gut. Für Parameter-Sensitivität fehlen jedoch optionale Histogramm-/Density-Indizien:

- stark ungleiche Histogrammverteilung,
- Ascending-Key-/Out-of-Range-Indizien,
- gefilterte Statistik gegen Prädikatbereich,
- Partitionen mit abweichender Änderungsdynamik,
- Persist Sample und automatisches Sampling im Kontext,
- Korrelation zu PSP/OPPO und Query-Store-Varianten.

DBCC SHOW_STATISTICS oder entsprechende Histogrammquellen dürfen nur nach Objektbegrenzung und opt-in gelesen werden. Skew ist ein Hinweis, kein Beweis für einen schlechten Plan.

### SC-012: Tiefe Availability-Group- und Clusterdiagnose

**Vorgeschlagenes Modul:** monitor.USP_AvailabilityDeepAnalysis

Ergänzungen:

- Auto Page Repair,
- Physical Seeding und Seedingfehler,
- Cluster-/Quorum-/Memberzustand, soweit auf der Plattform verfügbar,
- Lease- und Health-Timeout-Kontext,
- Suspended-/Not-Synchronizing-Ursachen,
- Redo-/Send-Queue mit zeitlicher Entwicklung statt nur Momentwert,
- verteilte Availability Groups,
- Read-Only-Routing-Vollständigkeit,
- Backuppräferenz und tatsächliche Backupaktivität,
- Versions- und Plattformunterschiede, insbesondere Linux und Azure-Ausprägungen.

Ein geschätzter Catch-up-Wert aus einer Momentaufnahme muss als Schätzung gekennzeichnet bleiben.

### SC-013: Agent, Alerts und Benachrichtigungspfad

**Vorgeschlagenes Modul:** monitor.USP_AgentMonitoringAnalysis

Ergänzungen:

- SQL-Agent-Alerts für hohe Schweregrade sowie Fehler 823, 824 und 825,
- Operator- und Failsafe-Konfiguration,
- deaktivierte oder verwaiste Schedules,
- Kollision langer Jobs mit eigenen Startintervallen,
- wiederkehrende Stepfehler, Retry-Schleifen und hängende Ausführungen,
- Proxy-/Credential-Verweise nur als Runtime-Metadaten,
- Database-Mail-Queue und Eventlogzustand,
- fehlende Output-Retention beziehungsweise unkontrolliertes Outputwachstum.

Empfänger-, Konto-, Profil- und Proxybezeichnungen dürfen in der interaktiven Runtime-Ausgabe erscheinen, aber nicht in Beispielen, Tests oder Lieferberichten.

### SC-014: Korrelierte Findings statt isolierter Schwellenwerte

**Vorgeschlagenes Modul:** monitor.USP_DiagnosticFindings

Ein Finding sollte mindestens enthalten:

- Finding-ID und Version,
- Scope und betroffene Komponente,
- Beobachtung mit Einheit und Zeitraum,
- Evidenzquellen,
- Schweregrad und Konfidenz getrennt,
- Gegenindizien und bekannte Grenzen,
- Reset-/Startzeit,
- Berechtigungs- oder Featurelücke,
- empfohlene nächste Messung, nicht automatisch eine Änderungsanweisung.

Beispiel: Hohe PAGEIOLATCH-Waits allein beweisen keinen langsamen Storage. Erst Korrelation mit File-Latenz, betroffenen Requests, Buffer-Pool-Zustand, Volume-Kapazität und Zeitbezug erhöht die Konfidenz.

## 8. P2 – featureabhängige Spezialmodule

### SC-015: In-Memory OLTP

Implementiert als `monitor.USP_InMemoryOltpAnalysis`; Quellen werden nur aktiviert, wenn sichtbare memory-optimized Objekte, Tabellentypen oder eine XTP-Dateigruppe vorhanden sind.

Auswertungen:

- Tabellen- und Indexspeicher,
- Hash-Index-Bucket-Auslastung und lange Chains,
- XTP-Memory-Consumer,
- Checkpoint File Pairs und Merge-/Storagezustand,
- aktive XTP-Transaktionen und Garbage Collection,
- Resource-Governor-Bindung und Out-of-Memory-Risiken.

Umsetzungsgrenzen: Hashketten sind wegen möglicher vollständiger Tabellenscans opt-in und zusätzlich durch `CATALOG_DEEP` geschützt. Checkpointzustand, aktive Transaktionsmenge und Poolwerte sind Momentaufnahmen. Der Defaultpool erlaubt keine datenbankgenaue Attribution. Das Modul liest weder Nutzdaten noch Pfade, GUIDs, SQL-Texte oder Identitätskennungen und leitet keine automatische DDL ab.

### SC-016: Temporal Tables

Implementiert als `monitor.USP_TemporalAnalysis`; abhängige Quellen werden nur aktiviert, wenn sichtbare aktive systemversionierte Temporal Tables vorhanden sind.

Auswertungen:

- Zuordnung Current-/History-Tabelle,
- SYSTEM_TIME-Periodenspalten und Sichtbarkeit,
- approximative History-Größe, Zeilenmenge und Verhältnis zu Current,
- endliche/unendliche Retention und datenbankweiter Cleanup-Schalter,
- sichtbare B-Tree-Indexbaseline mit Periodenende/Periodenstart als führenden Schlüsseln,
- isolierte Quellen- und Berechtigungsfehler.

Umsetzungsgrenzen: Das Modul liest keine Current- oder History-Zeilen und führt weder `DBCC CHECKCONSTRAINTS` noch DDL oder Cleanup aus. Es beweist deshalb keine Periodenüberlappungsfreiheit, keine tatsächliche Hintergrundbereinigung und keine fachlich richtige Retentionsdauer. Nach `SYSTEM_VERSIONING=OFF` liegen zwei unabhängige Tabellen vor; ohne erhaltene Metadatenzuordnung wird kein ehemaliges Paar anhand von Namen oder Strukturen erraten. Größen- und Ratio-Grenzen sind Kontext, keine Defektklassifikation.

### SC-017: Service Broker

Implementiert als `monitor.USP_ServiceBrokerAnalysis`; das unfiltrierte sichtbare Feature-Gate berücksichtigt den Datenbankschalter sowie benutzerdefinierte Queues und Services. Abhängige Quellen werden getrennt behandelt, damit fehlende Server-DMV-Rechte Queue-Katalog, Transmission oder Conversation-Evidenz nicht verwerfen.

Auswertungen:

- gruppierte Transmission-Queue-Metadaten, Alter und `transmission_status`,
- Queue-Schalter, approximative Nachrichtenanzahl und Speicherbelegung,
- Queue-Monitor- und interne Aktivierungszustände,
- aggregierte Conversation-Endpoint-Zustände und abgelaufene Lifetimes,
- isolierte Quellen- und Berechtigungsfehler.

Umsetzungsgrenzen: Der Nachrichtenkörper wird weder referenziert noch ausgegeben. Queue-Nutzdaten, Conversation-Handles, Gruppen-IDs und Schlüsselkennungen bleiben ausgeschlossen; das Modul führt kein `RECEIVE`, `ALTER QUEUE` oder `END CONVERSATION` aus. Ein RECEIVE-OFF-Zustand kann nach fünf Rollbacks durch automatische Poison-Message-Erkennung oder manuell entstehen und beweist deshalb keine konkrete Poison Message. Transmission-Einträge können während normaler Zustellung oder Retention bestehen; Alter, Zeilenzahl und DMV-Zustände bleiben konfigurierbare Prüfhinweise. Routen-, Zertifikats-, Endpunkt- und Fehlerloganalyse werden als kontrollierte nächste Prüfungen genannt, nicht aus sichtbaren Lücken erraten.

### SC-018: Full-Text

Implementiert als `monitor.USP_FullTextAnalysis`; das unfiltrierte sichtbare Feature-Gate berücksichtigt Komponentenstatus, Kataloge, Indizes und semantische Indexspalten. Abhängige datenbankbezogene und serverweite Quellen werden isoliert behandelt.

Auswertungen:

- Index-/Schlüsselindexschalter, Change Tracking und Crawl-Kontext,
- ausschließlich aktuell laufende Full-Text- und semantische Populationen,
- nach Tabelle, Fehlercode und Retryzustand aggregierte ausstehende Batches,
- querybare Fragmente mit Status 4 oder 6 und deren logische Größe,
- semantische Ähnlichkeitspopulation als zweite Phase,
- serverweite Full-Text-Memory-Pools und nach Typ aggregierte FDHosts,
- isolierte Quellen- und Berechtigungsfehler.

Umsetzungsgrenzen: `MANUAL/OFF`, ein ausstehender initialer Crawl und Status 7 sind nicht automatisch Fehler. Eine leere Population-DMV ist weder Abschlussnachweis noch Historie. Laufzeit-, Batch-, Fragment- und Größenwerte sind konfigurierbare Prüfheuristiken ohne universellen Grenzwert. Das Modul liest keine Tabelleninhalte, Keywords, Stopwords, Parser-Eingaben, Schlüsselwerte, Crawl-Logs, Pfade, Batch-IDs, Speicheradressen, FDHost-Namen oder Prozess-IDs und führt kein Full-Text-DDL aus.

### SC-019: Change Tracking, CDC und Replikation vertiefen

Implementiert als `monitor.USP_DataCaptureDeepAnalysis`. Das unfiltrierte sichtbare Feature-Gate trennt Change Tracking, CDC und Replikationsrollen. Schema-/Objektfilter wirken nur auf CT-/CDC-Quelltabellen. Jede abhängige DMV-, msdb- und lokale Distributionsquelle wird isoliert behandelt.

Auswertungen:

- Change-Tracking-MinValidVersion ausschließlich gegen einen optional gelieferten echten Consumer-Wasserstand,
- inkonsistente zukünftige Consumer-Version sowie Auto-Cleanup-Kontext,
- CDC-Capture-Instanzen, Drop-Pending, älteste verfügbare Zeitgrenze und Cleanup-Retention,
- CDC-Logscan-Aggregat und neueste Sitzung, gruppierte Fehler sowie Capture-/Cleanup-Jobs,
- alle sichtbaren lokalen Distributionsdatenbanken mit Distribution-/Log-Reader-/Merge-Agenten, Agenthistorie, undistributed commands, inaktiven Subscriptions, Konflikten und Retries,
- gruppierte lokale Replikationsfehler und explizite Topologie-/Berechtigungsgrenzen.

Umsetzungsgrenzen: Ohne Consumer-Wasserstand wird kein CT-Synchronisationsverlust behauptet. Zeitgesteuertes CDC erhält eine andere Latenzeinordnung als kontinuierliches Capture. Idle-Agenten ohne Rückstand sind kein Fehler. Inaktive Subscription oder Fail/Retry sind Reinitialisierungskandidaten und kein alleiniger Beweis. Ein Remote oder unzugänglicher Distributor wird als Evidenzlücke und niemals als gesunder Zustand behandelt. Das Modul liest keine Change-Zeilen, Replikationsbefehle, Kommentare, Fehlertexte, LSNs, Credentials, Agentjob-Commands oder Konfliktzeilen und führt keine Änderung aus.

### SC-020: Verschlüsselung und Schlüssel-Lifecycle

Auswertungen:

- TDE-Zustand und Verschlüsselungsfortschritt,
- fehlende oder ablaufgefährdete Zertifikats-/Schlüsselabhängigkeiten,
- Backupverschlüsselungsmetadaten,
- Always Encrypted nur als Capability-/Metadatenstatus,
- Ledgerstatus, wenn verwendet.

Private Schlüssel, Kennwörter, Secrets oder geschützte Werte werden niemals ausgegeben.

### SC-021: Externe und programmierbare Features

Featureabhängige Bestands- und Gesundheitsmodule für:

- CLR-Assemblies und UNSAFE/EXTERNAL_ACCESS-Risiken,
- External Scripts und Launchpadstatus,
- PolyBase/External Tables und externe Datenquellen,
- FILESTREAM/FileTable,
- Graph-, XML-, Spatial-, JSON- und SQL-Server-2025-Vector-Indizes,
- externe Bibliotheken und benutzerdefinierte Typen.

Der Defaultpfad sollte zuerst nur eine Featureinventur ausführen und erst danach passende Detailmodule aktivieren.

### SC-022: Wartungsoperationen und abgebrochene Arbeit

Auswertungen:

- resumable Indexoperationen,
- pausierte oder abgebrochene Onlineoperationen,
- lange Rollbacks und Accelerated Database Recovery,
- automatische Statistik- und Indexwartungskollisionen,
- überlappende manuelle Wartungsjobs,
- Log-/TempDB-/AG-Auswirkungen großer Wartungsoperationen.

## 9. P3 – strategische Erweiterungen

### SC-023: Snapshot-, Baseline- und Anomaliepaket

Der zustandslose Kern kann Neustarts, kurze Peaks und Trends nicht rekonstruieren. Ein separates Paket sollte:

- klar definierte Snapshots mit UTC-Zeit, Resetzeit und Quellstatus erfassen,
- 30 Sekunden als typische und höchstens 60 Sekunden als empfohlene Standardfrequenz unterstützen,
- Retention, Partitionierung, Kompression, Löschung und Größenbudget besitzen,
- Differenzen nur innerhalb derselben Resetepoche bilden,
- Baselines nach Tageszeit und Wochentag unterscheiden,
- keine Identitäts- oder SQL-Textdaten ohne eigene Freigabe persistieren,
- einen sicheren Exportvertrag besitzen.

Dieses Paket ist datenschutz- und betriebsseitig eine neue Funktion, nicht nur eine weitere Procedure.

### SC-024: Fleet- und Plattformkorrelation

Cross-Server-Vergleich, Versionsdrift, Konfigurationsdrift und zentrale Historie liegen außerhalb eines einzelnen lokalen T-SQL-Repositorys. Dafür sind Authentisierung, Transport, Mandantentrennung und Aufbewahrung separat zu entwerfen.

### SC-025: Externe Restore-, Storage- und Hosttests

Ein T-SQL-Framework kann Hinweise liefern, aber folgende Beweise nicht vollständig intern erbringen:

- erfolgreicher Restore in isolierter Umgebung mit anschließendem CHECKDB,
- Betriebssystem-, Multipath-, SAN-, Cloud-Disk- und Filesystemdiagnose,
- Netzwerkpfad- und DNS-Analyse,
- Hypervisor-/Container- und Host-CPU-Steal-Zustand,
- Ende-zu-Ende-Anwendungs- und ETL-Laufzeit.

Das Framework soll dafür Evidenzlücken und nächste Prüfschritte ausgeben, aber keine Scheinsicherheit erzeugen.

## 10. Empfohlene Implementierungsreihenfolge

### Welle A – Schutz und kritische Evidenz

1. Datenschutz-/Artefaktprüfung operationalisieren.
2. DatabaseIntegrityAnalysis.
3. DatabaseCapacityAnalysis.
4. CriticalEngineEvents.
5. PerformanceCounters.

### Welle B – Ursachenauflösung

6. IntelligentQueryProcessingAnalysis.
7. InternalContentionAnalysis.
8. BufferPoolAnalysis.
9. BackupChainAnalysis.
10. DiagnosticFindings als Korrelation der vorhandenen und neuen Module.

### Welle C – Betriebs- und Designtiefe

11. SchemaDesignAnalysis und optionale Statistikverteilung.
12. AvailabilityDeepAnalysis.
13. AgentMonitoringAnalysis.
14. automatische Featureinventur für bedingte Module.

### Welle D – bedingte Spezialmodule

15. In-Memory OLTP, Temporal, Service Broker und Full-Text umgesetzt.
16. CDC/Change Tracking/Replikation, Verschlüsselung und externe Features folgen.
17. Wartungsoperationen.

### Welle E – separates Persistenzprojekt

18. Snapshot/Baseline/Anomalie erst nach Datenschutz-, Retention-, Berechtigungs- und Größenentscheidung.

## 11. Querschnittsregeln für alle neuen Module

### Performance

- zunächst Capability und Featureeinsatz prüfen,
- Scope vor XML-, Eventfile-, Page-, Histogramm- oder Buffer-Scans begrenzen,
- Top-N und MaxAnalyseobjekte getrennt halten,
- Deltaquellen mit Sampleintervall, Resetzeit und Abbruchmöglichkeit versehen,
- breite Datenbankläufe explizit schützen,
- keine N-mal wiederholten Server-DMVs pro Datenbank.

### Berechtigungen

- SQL Server 2019 und 2022+ besitzen teils unterschiedliche VIEW-SERVER-STATE-/VIEW-SERVER-PERFORMANCE-STATE-Anforderungen,
- msdb- und HADR-Quellen können zusätzliche Rechte benötigen,
- fehlende Rechte deaktivieren nur das betroffene Teilresultset,
- das Framework vergibt keine Rechte und umgeht keine Zugriffskontrolle.

### Version und Plattform

- Objekt- und Spaltenexistenz vor dynamischer Referenz prüfen,
- SQL-Server-2022-/2025-Funktionen erst nach Capabilityprüfung verwenden,
- Windows-, Linux-, Azure-VM-, Managed-Instance- und Azure-SQL-Einschränkungen nicht vermischen,
- nicht verfügbare Quellen als NOT_SUPPORTED statt als fehlerfreien Zustand melden.

### Aussagequalität

- Momentaufnahme, kumulativer Zähler, Delta und Historie sichtbar unterscheiden,
- keine Kausalität aus einem Einzelindikator ableiten,
- Einheiten und Nenner ausgeben,
- Datenverlust durch DMV-Reset, Plan-Eviction, Query-Store-Cleanup oder msdb-Retention nennen,
- Formulieren Sie Empfehlungen als nächste Prüfung und nicht als automatisch auszuführende Änderung.

### Datenschutz

- reale Runtime-Identitäten dürfen in berechtigten Resultsets erscheinen,
- dieselben Werte dürfen nicht in Dokumentation, Testfixture, Audit oder Lieferpaket übernommen werden,
- Freitext- und Payloadquellen besonders vorsichtig behandeln,
- spätere Persistenz und Exporte benötigen einen eigenen Vertrag.

## 12. Abnahmestrategie

Jedes neue Modul benötigt:

1. einen Capability-Test für unterstützt, nicht unterstützt, deaktiviert und unberechtigt,
2. einen leeren Zustand ohne Fehlalarm,
3. einen synthetisch oder kontrolliert erzeugten positiven Zustand,
4. einen großen Zustand zur Kosten- und Limitprüfung,
5. einen Reset-/Neustartfall bei kumulativen Zählern,
6. einen SQL-Server-2019-, 2022- und 2025-Vertragstest, soweit die Quelle versionsabhängig ist,
7. RAW-, CONSOLE-, NONE- und gegebenenfalls JSON-Vertragstests,
8. Datenschutzprüfung für Beispiele und gespeicherte Testergebnisse,
9. dokumentierte False-Positive- und False-Negative-Grenzen,
10. Integration in Status-, Hilfe-, Inventar- und Installerpfade.

## 13. Quellen

### Offizielle Microsoft-Dokumentation

- Suspect Pages: https://learn.microsoft.com/en-us/sql/relational-databases/system-tables/suspect-pages-transact-sql?view=sql-server-ver17
- DBCC CHECKDB: https://learn.microsoft.com/en-us/sql/t-sql/database-console-commands/dbcc-checkdb-transact-sql?view=sql-server-ver17
- Performance Counters: https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-views/sys-dm-os-performance-counters-transact-sql?view=sql-server-ver17
- sp_server_diagnostics: https://learn.microsoft.com/en-us/sql/relational-databases/system-stored-procedures/sp-server-diagnostics-transact-sql?view=sql-server-ver17
- system_health: https://learn.microsoft.com/en-us/sql/relational-databases/extended-events/use-the-system-health-session?view=sql-server-ver17
- Intelligent Query Processing: https://learn.microsoft.com/en-us/sql/relational-databases/performance/intelligent-query-processing?view=sql-server-ver17
- Intelligent Query Processing Details: https://learn.microsoft.com/en-us/sql/relational-databases/performance/intelligent-query-processing-details?view=sql-server-ver17
- Parameter Sensitive Plan Optimization: https://learn.microsoft.com/en-us/sql/relational-databases/performance/parameter-sensitive-plan-optimization?view=sql-server-ver17
- Optimized Plan Forcing: https://learn.microsoft.com/en-us/sql/relational-databases/performance/optimized-plan-forcing-query-store?view=sql-server-ver17
- Query Store Hints: https://learn.microsoft.com/en-us/sql/relational-databases/performance/query-store-hints?view=sql-server-ver17
- SQL Server 2025 Neuerungen: https://learn.microsoft.com/en-us/sql/sql-server/what-s-new-in-sql-server-2025?view=sql-server-ver17
- TempDB Space Resource Governance: https://learn.microsoft.com/en-us/sql/relational-databases/resource-governor/tempdb-space-resource-governance?view=sql-server-ver17
- Optimized Locking: https://learn.microsoft.com/en-us/sql/relational-databases/performance/optimized-locking?view=sql-server-ver17
- Latch Stats: https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-os-latch-stats-transact-sql?view=sql-server-ver17
- Spinlock Stats: https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-os-spinlock-stats-transact-sql?view=sql-server-ver17
- Page Info: https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-db-page-info-transact-sql?view=sql-server-ver17
- Volume Stats: https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-os-volume-stats-transact-sql?view=sql-server-ver17
- Buffer Descriptors: https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-os-buffer-descriptors-transact-sql?view=sql-server-ver17
- In-Memory OLTP Memory: https://learn.microsoft.com/en-us/sql/relational-databases/in-memory-oltp/monitor-and-troubleshoot-memory-usage?view=sql-server-ver17
- Temporal Tables: https://learn.microsoft.com/en-us/sql/relational-databases/tables/temporal-tables?view=sql-server-ver17
- Full-Text System Views: https://learn.microsoft.com/en-us/sql/relational-databases/search/full-text-search-ddl-functions-stored-procedures-and-views?view=sql-server-ver17
- Full-Text Indexes: https://learn.microsoft.com/en-us/sql/relational-databases/system-catalog-views/sys-fulltext-indexes-transact-sql?view=sql-server-ver17
- Full-Text Fragments: https://learn.microsoft.com/en-us/sql/relational-databases/system-catalog-views/sys-fulltext-index-fragments-transact-sql?view=sql-server-ver17
- Full-Text Population: https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-fts-index-population-transact-sql?view=sql-server-ver17
- Full-Text Outstanding Batches: https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-fts-outstanding-batches-transact-sql?view=sql-server-ver17
- Full-Text Semantic Similarity Population: https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-fts-semantic-similarity-population-transact-sql?view=sql-server-ver17
- Full-Text Memory Pools: https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-fts-memory-pools-transact-sql?view=sql-server-ver17
- Full-Text FDHosts: https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-fts-fdhosts-transact-sql?view=sql-server-ver17
- Backupset: https://learn.microsoft.com/en-us/sql/relational-databases/system-tables/backupset-transact-sql?view=sql-server-ver17
- RESTORE VERIFYONLY: https://learn.microsoft.com/en-us/sql/t-sql/statements/restore-statements-verifyonly-transact-sql?view=sql-server-ver17
- Service Broker Transmission Queue: https://learn.microsoft.com/en-us/sql/relational-databases/system-catalog-views/sys-transmission-queue-transact-sql?view=sql-server-ver17
- Service Broker Queues: https://learn.microsoft.com/en-us/sql/relational-databases/system-catalog-views/sys-service-queues-transact-sql?view=sql-server-ver17
- Service Broker Queue Monitors: https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-broker-queue-monitors-transact-sql?view=sql-server-ver17
- Service Broker Activated Tasks: https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-broker-activated-tasks-transact-sql?view=sql-server-ver17
- Service Broker Conversation Endpoints: https://learn.microsoft.com/en-us/sql/relational-databases/system-catalog-views/sys-conversation-endpoints-transact-sql?view=sql-server-ver17
- Service Broker Poison Messages: https://learn.microsoft.com/en-us/sql/database-engine/service-broker/removing-poison-messages?view=sql-server-ver17
- Service Broker Activation Troubleshooting: https://learn.microsoft.com/en-us/sql/database-engine/service-broker/troubleshooting-activation-stored-procedures?view=sql-server-ver17

### Öffentliche Referenzkataloge

- Microsoft SQL Tiger Toolbox, BPCheck: https://github.com/microsoft/tigertoolbox/blob/master/BPCheck/README.md
- SQL Server First Responder Kit, Checks by Priority: https://github.com/BrentOzarULTD/SQL-Server-First-Responder-Kit/blob/dev/Documentation/sp_Blitz_Checks_by_Priority.md

Die Referenzkataloge wurden nur zum Funktionsvergleich herangezogen. Es wurde kein fremder Quellcode übernommen.
