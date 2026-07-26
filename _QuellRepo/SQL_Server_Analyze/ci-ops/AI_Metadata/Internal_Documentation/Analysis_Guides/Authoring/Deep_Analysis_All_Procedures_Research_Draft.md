# Draft: technische Research-Matrix für alle öffentlichen Procedures

**Stand:** 19. Juli 2026
**Status:** integriertes Authoring-Archiv; nicht kanonisch
**Inventarbasis:** `Metadata/Inventory/Objects.csv` auf `main` mit 84 öffentlichen Procedures  
**Zweck:** vollständige 84/84-Arbeitsgrundlage und Nachvollziehbarkeit der integrierten Vertiefung

> Die Matrix ist bewusst dichter als die kanonischen didaktischen Guides. Sie dokumentiert die ursprüngliche Research-Abdeckung; für die Anwendung gelten ausschließlich die Seiten unter `../Procedures` und `../Technical_Foundations.md`.

## 1. Abdeckungsdefinition

Für jede Procedure werden mindestens erfasst:

- technischer Mechanismus und primäre Datenherkunft,
- Zeit-, Scope- und Resetmodell,
- fachliche Bewertungsfrage,
- wichtigste Fehlinterpretation oder Aussagegrenze,
- empfohlene Folgeanalyse.

Die spätere Einzelpage muss zusätzlich alle Parameter, Resultsets, Spalten, Datentypen, Berechnungen, Berechtigungen, Kosten, synthetischen Beispiele und Quellen vollständig ausarbeiten.

## 2. Common – 4 Procedures

### Technischer Familienhintergrund

Die Common-Procedures liefern keine klassische Performanceursache, sondern bestimmen Zugriff, Capability, Datenbankscope und sichere Filter. Fehler hier verändern, welche Evidenz nachfolgende Analysen überhaupt sehen. Ein leeres Fachresultset darf daher erst bewertet werden, nachdem Zugriffs- und Capabilitystatus geprüft wurden.

| Procedure | Mechanismus und Datenherkunft | Zeitmodell und Bewertung | Aussagegrenze und Folgeanalyse |
|---|---|---|---|
| `USP_CheckAnalyseAccess` | wertet Framework-Policies, effektiven/originalen Login, Rollen- und Gruppenmitgliedschaft sowie den sysadmin-Bypass aus | aktueller Sicherheitskontext; beantwortet, ob eine Analyseklasse laut Framework ausgeführt werden darf | keine Policy bedeutet laut Frameworkvertrag offen; ein Deny ist kein DMV-Fehler. Danach `USP_CheckFrameworkCapabilities` |
| `USP_CheckFrameworkCapabilities` | verbindet Version, Edition, Featurezustand, formale Berechtigung und einen tatsächlichen Queryability-/Capabilitycheck | aktuelle Umgebung; trennt unterstützt, aktiviert, berechtigt, abfragbar und nutzbar | eine vorhandene Permission garantiert keine lesbare Quelle; Datenbankzustand, Plattform oder Replica-Rolle können begrenzen |
| `USP_PrepareDatabaseCandidates` | erstellt aus expliziter Liste oder Pattern einen sicheren Datenbankscope über Systemkataloge und Frameworkzugriffsregeln | aktuelle Datenbankliste und Zustände | fehlende/offline/gesperrte Datenbanken verkleinern den Scope; Warnungen müssen mit dem Fachresultset gelesen werden |
| `USP_PrepareNameFilters` | normalisiert und validiert Namenlisten in temporäre Filterstrukturen unter case-sensitiver Semantik | aufrufbezogene Eingabeverarbeitung | eine nach Fehler geleerte Filtertabelle darf nie als absichtlich ungefilterter Auftrag interpretiert werden |

## 3. Current State – 10 Procedures

### Technischer Familienhintergrund

Current-State-Procedures lesen überwiegend flüchtige DMVs. Sie zeigen Zustände, die während oder unmittelbar vor dem Aufruf sichtbar waren. Ein einzelner Snapshot beweist weder Dauerhaftigkeit noch Normalverhalten. Session, Request, Task, Worker und Scheduler müssen getrennt werden; parallele Requests können mehrere gleichzeitige Task-Waits besitzen.

| Procedure | Mechanismus und Datenherkunft | Zeitmodell und Bewertung | Aussagegrenze und Folgeanalyse |
|---|---|---|---|
| `USP_CurrentSessions` | korreliert `sys.dm_exec_sessions`, Verbindungen und bei Bedarf Request-/Transaktionskontext | Sessionzustand jetzt; CPU/I/O-Zähler teilweise seit Sessionbeginn | `sleeping` ist bei Pools normal, `sleeping` plus offene Transaktion nicht. Danach `USP_CurrentTransactions` und `USP_CurrentBlocking` |
| `USP_CurrentRequests` | verbindet aktive Requests mit Sessions, Verbindungen, Waiting Tasks, Memory Grants, SQL-/Statementtext, Scheduler- und Transaktionskontext | flüchtiger Requestsnapshot; Zähler seit Requeststart | hohe Elapsed Time ist ohne CPU, Waits und Reads wertarm. Blocking, Grants, Plan und Task-Waits korrelieren |
| `USP_CurrentBlocking` | baut aus blockierenden Sessionbeziehungen und Waiting Tasks Blockingketten bis zum Root Blocker | momentane Kette; kurze Kanten können beim Lesen verschwinden | Opfer und Root Blocker unterscheiden; Rootursache benötigt Transaktions-, Request- und Ressourcenanalyse |
| `USP_CurrentWaits` | liest aktuelle `sys.dm_os_waiting_tasks` sowie kumulative oder gesampelte `sys.dm_os_wait_stats` und ordnet Waitkatalogwissen zu | Tasksnapshot plus Instanzkumulativwert oder Delta | Waittyp ist Symptom; aktuelle Tasks und späteres Sample besitzen unterschiedliche Zeitpunkte. Vertiefung im separaten Wait-Draft |
| `USP_CurrentTransactions` | korreliert aktive Transaktionen, Sessionzustand, Beginn, Logverbrauch und Requestkontext | aktuelle offene Transaktionen und deren bisheriges Alter | lange Transaktion kann geplant sein; kritisch durch Blocking, Log-Reuse-Hemmung, Wachstum oder fehlenden Fortschritt |
| `USP_CurrentMemoryGrants` | liest aktuelle/ausstehende Query Execution Memory Grants und verbindet sie mit Request, Plan-/Textkontext und Nutzung | flüchtiger Grantzustand | großer Grant ist nicht automatisch falsch; wartende Grants, Übergrant, Konkurrenz, Schätzfehler und DOP gemeinsam prüfen |
| `USP_CurrentTempDB` | kombiniert TempDB-Datei-/Space-Usage, Session-/Taskverbrauch, User/Internal Objects und Version Store | aktueller Belegungszustand; Sessionzähler können sich rasch ändern | 90 Prozent belegt nennt keine Ursache; Internal Objects, Version Store und User Objects getrennt verfolgen |
| `USP_CurrentIO` | liest `sys.dm_io_virtual_file_stats`, Dateimetadaten und optional zwei Messpunkte für Datei-I/O-Deltas | kumulativ seit Datei-/Enginezustand oder kurzes Sample | Durchschnitt ohne Operationszahl ist irreführend; aktuelle Latenz, IOPS, Bytes und Waits zusammen bewerten |
| `USP_CurrentLog` | verbindet Logspace, Logdateien, VLF-/Wachstumskontext, `log_reuse_wait_desc`, Transaktionen und versionsabhängige Logmetrik | aktueller Logzustand mit teils kumulativen Metadaten | hohe Nutzung ist Symptom; `ACTIVE_TRANSACTION`, Logbackup, AG/Replication und Kapazität bestimmen Ursache |
| `USP_CurrentOverview` | orchestriert Current-State-Kindmodule und liefert deren Resultsets/Status in definierter Reihenfolge | Mischbild verschiedener Momentaufnahmen und Messarten | Triage, keine Gesamtdiagnose; Childstatus und IsPartial vor Fachwerten lesen |

## 4. Object and Index – 11 Procedures

### Technischer Familienhintergrund

Diese Familie verbindet Katalogmetadaten, kumulative Usage-/Operational-DMVs und optional kostenintensive physische Analysen. Index-, Statistik- und Designbefunde sind Prüfaufträge. Keine einzelne Kennzahl rechtfertigt automatisch DDL.

| Procedure | Mechanismus und Datenherkunft | Zeitmodell und Bewertung | Aussagegrenze und Folgeanalyse |
|---|---|---|---|
| `USP_ObjectInventory` | liest Objekte, Schemas, Tabellen, Indizes, Spalten, Partitionen, Kompression und Größen-/Zeilenschätzungen aus Katalogen und Partition Stats | aktueller Metadatenzustand; Größenwerte je Quelle angenähert oder aktuell | Definition zeigt Existenz, nicht Nutzung oder Nutzen. Danach Usage, Operational Stats und Pläne |
| `USP_IndexUsage` | wertet `sys.dm_db_index_usage_stats` mit Indexdefinition, Schutzmerkmalen und Resetkontext aus | kumulativ seit Initialisierung/Reset der DMV für die Datenbank | null Reads bei kurzem Fenster oder saisonaler Nutzung beweisen Entbehrlichkeit nicht; Constraints und Query Store prüfen |
| `USP_IndexOperationalStats` | nutzt `sys.dm_db_index_operational_stats` für Inserts/Updates, Scans, Page Allocations, Lock-/Latch-Waits und weitere interne Zähler | kumulativ für den sichtbaren Objekt-/Indexzustand | absolute Zähler ohne Aktivitätsnenner sind wertarm; pro DML/Scan/Wait normalisieren |
| `USP_MissingIndexes` | liest Optimizer-Missing-Index-DMVs, gruppiert Schlüssel-/Includevorschläge und berechnet Priorisierungsmetriken | flüchtig seit Restart/Reset; begrenzte DMV-Kapazität | Vorschlag kennt Wartungskosten, bestehende Überschneidungen und reale Selectivity nur begrenzt; Plan und Indexportfolio prüfen |
| `USP_Statistics` | verbindet Statistikdefinition, Spalten, Auto-/User-Created-Flags, `dm_db_stats_properties` und optional Histogrammkontext | aktuelle Statistik plus letzte Aktualisierung/Modification Counter | Alter allein ist keine Qualitätsmetrik; Datenänderung, Sampling, Queryprädikat und Schätzfehler korrelieren |
| `USP_StatisticsDistributionAnalysis` | analysiert Histogrammsteps, EQ/RANGE Rows, Distinct Range Rows, Dichte/Skew und Repositoryheuristiken | aktuelles gespeichertes Histogramm, maximal 200 Steps; abhängig vom letzten Update/Sample | Skew ist kein automatischer Fehler; Parameter, Prädikat, CE, Stichprobe und tatsächliche Workload entscheiden |
| `USP_Partitions` | ordnet Partition Functions, Schemes, Boundary Values, Partitionen, Rowcounts, Kompression und Storage zu | aktueller Metadaten-/Größenzustand | ungleiche Partitiongrößen können absichtlich sein; Sliding Window, Dateigruppen und Zugriffsmuster einbeziehen |
| `USP_Columnstore` | liest Columnstore-Rowgroups, State, Total/Deleted Rows, Delta Stores, Trim Reason und Dictionary-/Segmentkontext | aktueller Rowgroup-Lebenszyklus, beeinflusst durch Loads, Tuple Mover und Reorganisation | hoher Deleted-Anteil allein genügt nicht; Rowgroupgröße, Alter, Ladeprofil, Scanrelevanz und Wartungsfenster prüfen |
| `USP_IndexPhysicalStats` | ruft `sys.dm_db_index_physical_stats` in gewähltem Modus auf und verbindet Page Count, Fragmentierung, Seitendichte und Ebenen | aufrufbezogene physische Messung; LIMITED/SAMPLED/DETAILED mit stark unterschiedlichen Kosten | hohe Fragmentierung bei kleinem Index ist meist irrelevant; Page Count, Dichte, Scans und Wartungskosten bewerten |
| `USP_ObjectAnalysis` | orchestriert Inventar, Usage, Operational, Missing, Statistics, Partition, Columnstore und Physical-Stats-Pfade | Mischbild aus Metadaten, kumulativen Zählern und optionaler Tiefenmessung | Childresultsets besitzen unterschiedliche Reset-/Kostenmodelle; keine pauschale DDL-Automation |
| `USP_SchemaDesignAnalysis` | untersucht Katalogmuster wie Datentypen, Schlüssel, Constraints, Index-/Spaltendesign und normalisierte Findings | aktueller Schemastand | Designheuristik ist kein Beweis für Fehler; Datenmodell, Workload, Semantik und Migrationsrisiko fachlich validieren |

## 5. Plan Cache – 6 Procedures

### Technischer Familienhintergrund

Der Plan Cache ist flüchtig und instanzweit. Statistikwerte gelten pro Cacheeintrag seit dessen Entstehung. Recompile, Eviction, Memory Pressure, Restart und explizites Cache-Clear verkürzen den Beobachtungszeitraum. Cachepläne enthalten normalerweise Estimated-Planinformationen, keine vollständige historische Einzel-Ausführungswahrheit.

| Procedure | Mechanismus und Datenherkunft | Zeitmodell und Bewertung | Aussagegrenze und Folgeanalyse |
|---|---|---|---|
| `USP_QueryStats` | verbindet `sys.dm_exec_query_stats` mit SQL-Text, Statementoffsets, Query-/Plan Hash, Plan und Datenbankkontext | kumulativ je Cacheeintrag | Totalwerte priorisieren kumulative Last, Averagewerte Ausführungsform; beide benötigen Execution Count und Cachealter |
| `USP_QueryHashAnalysis` | gruppiert Cacheeinträge nach Query Hash und Plan Hash, vergleicht Varianten, Last und Planvielfalt | nur aktuell gecachte Varianten | gleicher Query Hash ist keine globale fachliche Identität; fehlende Varianten können bereits evicted sein. Query Store für Historie |
| `USP_PlanCacheHealth` | aggregiert Cache Stores, Planarten, Größen, Use Counts, Single-Use-Ad-hoc-Anteile und Memorykontext | aktueller Cachebestand | viele Single-Use-Pläne können Workloadform widerspiegeln; Ad-hoc-Policy, Parameterisierung und Gesamtmemory prüfen |
| `USP_PlanDetails` | fokussiert einen Plan-/SQL-Handle und liefert Text, Attribute, Plan und zugehörige Statistiken | aktueller Cacheeintrag | Handle ist flüchtig und nach Recompile/Eviction ungültig; keine dauerhafte ID |
| `USP_ShowplanAnalysis` | parst Showplan-XML nach Operatoren, Warnungen, Referenzobjekten/-statistiken, Memory-/Parallelitäts- und Missing-Index-Evidenz | Planstand des gewählten Cache-/Query-Store-Plans | Estimated und Actual Properties unterscheiden; XML-Hinweis ist Evidenz, keine automatische Tuninganweisung |
| `USP_PlanCacheAnalysis` | orchestriert Query Stats, Hash-, Health-, Detail- und Showplanmodule | Mischbild flüchtiger Cachequellen | Modulstatus und Kostenoptionen lesen; historische Regressionen mit Query Store prüfen |

## 6. Query Store – 9 Procedures

### Technischer Familienhintergrund

Query Store persistiert datenbankbezogene Query-, Plan-, Runtime- und optional Waitdaten in Intervallen. Capture Mode, Retention, Cleanup, Größenlimit, Read-only-Zustand, Replica-Konfiguration und Intervallüberlappung bestimmen die Vollständigkeit.

| Procedure | Mechanismus und Datenherkunft | Zeitmodell und Bewertung | Aussagegrenze und Folgeanalyse |
|---|---|---|---|
| `USP_QueryStoreStatus` | liest `sys.database_query_store_options`, Größen-/Capture-/Cleanup- und Wait-Capture-Zustand über ausgewählte Datenbanken | aktueller Konfigurations- und Runtimezustand | READ_WRITE beweist keine vollständige Historie; Retention, Cleanup und Capture Mode mitbewerten |
| `USP_QueryStoreRuntimeStats` | aggregiert Runtimeintervalle je Query/Plan/Ausführungstyp und verbindet Text/Plan | persistierte Intervallwerte im gewählten Fenster | Randintervalle können vollständig eingehen; Average-, Total- und Executionwerte sowie Gewichtung dokumentieren |
| `USP_QueryStoreWaitStats` | aggregiert Query-Store-Waitkategorien je Plan und Intervall | persistierte Kategorien während Queryausführung | keine einzelnen Waittypen/Blocker und keine Compile-Waits; separater Vertiefungsdraft vorhanden |
| `USP_QueryStorePlanChanges` | zählt/vergleich Query-Store-Planzeilen, Plan Hashes, Compile-/Engine-/Compatibility- und Force-Metadaten | persistierter Planlebenszyklus innerhalb Retention | mehrere PlanIds bedeuten nicht automatisch Regression; Runtime je Plan vergleichen |
| `USP_QueryStoreRegressions` | vergleicht Baseline- und Vergleichsfenster für Duration, CPU, Reads, Writes oder Executions | zwei intervalbasierte Zeitfenster | Prozent bei kleiner Stichprobe oder Baseline nahe null ist instabil; Workloadmix und Planwechsel prüfen |
| `USP_QueryStoreForcedPlans` | inventarisiert forced Plans, Force-Typ, Fehler, Compile-/Execution- und Versionskontext | aktueller/persistierter Forcingzustand | forced bedeutet weder aktiv genutzt noch optimal; Fehler, Alter, Upgrade und Alternativpläne prüfen |
| `USP_QueryStoreHints` | liest Query Store Hints, Herkunft und Fehlerstatus ab unterstützter Version | persistierter Hintzustand | fehlerfreier Hint kann veraltet oder schädlich sein; Owner, Begründung und Rücknahmepfad benötigen Governance |
| `USP_QueryStoreAnalysis` | orchestriert Status, Runtime, Waits, PlanChanges, Regressions, Forced Plans, Hints und IQP | mehrere Query-Store-Sichten und Fenster | Childreihenfolge, Wrapperfenster und partielle Datenbanken beachten |
| `USP_IntelligentQueryProcessingAnalysis` | korreliert Version/Compatibility, database-scoped configurations, Query Store, Plan Feedback, Query Variants und Tuning-Evidenz | aktueller Feature-/Konfigurationsstand plus sichtbare persistierte Signale | eligible ist kein Wirksamkeitsbeweis; null Evidenz kann Capture-, Workload- oder Versionsgründe haben |

## 7. Extended Events – 6 Procedures

### Technischer Familienhintergrund

Extended Events liefern nur Ereignisse, die eine aktive Session mit passendem Event/Action-Set tatsächlich erfasst und deren Target noch nicht verworfen oder überschrieben hat. Konfiguration, Runtimezustand und Targetinhalt sind getrennte Ebenen.

| Procedure | Mechanismus und Datenherkunft | Zeitmodell und Bewertung | Aussagegrenze und Folgeanalyse |
|---|---|---|---|
| `USP_ExtendedEventsSessions` | verbindet XE-Katalogsichten für Session/Event/Action/Target/Felder mit Runtime-DMVs | aktuelle Definition und aktueller Laufzustand | konfigurierte Session muss nicht laufen; laufende Session muss nicht das benötigte Event oder Actionfeld erfassen |
| `USP_ExtendedEventsReadEvents` | liest Ring Buffer oder Event File über XE-Funktionen, parst Event-XML und wendet Zeit-/Namensfilter an | erhaltene Ereignisse innerhalb Target-/Rollover-Retention | fehlendes Event beweist kein fehlendes Ereignis; Target, Sessionstart, Pfadzugriff, Rollover und Drops prüfen |
| `USP_ExtendedEventsDeadlocks` | extrahiert Deadlock-XML aus geeigneten XE-Quellen und zerlegt Opfer, Prozesse, Ressourcen und Kanten | historisch soweit Targetdaten vorhanden | Deadlockgraph zeigt einen aufgelösten Zyklus, nicht jedes vorherige Blocking; Victim ist nicht automatisch Verursacher |
| `USP_ExtendedEventsBlockedProcesses` | liest `blocked_process_report`-Events und korreliert Blocker/Blocked, Dauer, Ressource und SQL-Kontext | nur bei konfigurierter Threshold- und Eventerfassung | Blocking unter Threshold oder außerhalb Sessionlaufzeit fehlt; Livezustand kann bereits beendet sein |
| `USP_ExtendedEventsTargetRuntime` | untersucht Runtime-Targets, Speicher-/Datei-/Bufferzustand, Drops und Verarbeitung | aktueller Targetruntimezustand | Drop-/Rollover-Evidenz begrenzt die Historie; Konfiguration allein reicht nicht |
| `USP_ExtendedEventsAnalysis` | orchestriert Session-, Event-, Deadlock-, Blocking- und Targetmodule | Mischbild aus Konfiguration, Runtime und Historie | leere Childresultsets nur zusammen mit Capture- und Targetstatus bewerten |

## 8. Infrastructure – 13 Procedures

### Technischer Familienhintergrund

Die Infrastrukturmodule verbinden Systemdatenbanken, Agent-/Backup-/HADR-/Replication-Metadaten und Runtime-DMVs. Historien sind durch Cleanup und Topologie begrenzt; lokale Sicht ist bei verteilten Komponenten nicht automatisch vollständig.

| Procedure | Mechanismus und Datenherkunft | Zeitmodell und Bewertung | Aussagegrenze und Folgeanalyse |
|---|---|---|---|
| `USP_AgentStatus` | liest SQL Server Agent-/Dienstzustand und grundlegende Agentverfügbarkeit | aktueller Service-/Instanzzustand | Dienst läuft bedeutet nicht, dass Jobs erfolgreich oder Scheduler aktiv sind |
| `USP_AgentJobs` | verbindet `msdb`-Jobs, Steps, Schedules, Activity und History | aktueller Jobzustand plus aufbewahrte Historie | History Cleanup, gerade laufende Steps und Retrylogik können die letzte Statuszeile verzerren |
| `USP_ResourceGovernorAnalysis` | liest Resource-Governor-Konfiguration, Pools, Workload Groups, Klassifier und Runtimecounter | aktuelle Konfiguration plus teils kumulative Runtimewerte | Zuordnung erfolgt bei Login/Klassifizierung; Configwert und `value_in_use`/Runtimezustand unterscheiden |
| `USP_AvailabilityGroups` | korreliert AG-, Replica- und Database-Replica-DMVs, Synczustand und Queues | aktueller lokaler HADR-Snapshot | Primär-/Secondary-Sicht und Berechtigungen beeinflussen Vollständigkeit; SYNCHRONIZED ist kein Latenz-SLA |
| `USP_BackupRecovery` | verbindet Recovery Model, letzte Full/Diff/Log-Backups und `msdb`-Backuphistorie | aufbewahrte Backupmetadaten | Backupzeile beweist weder Lesbarkeit noch Restorefähigkeit; echte Restore-Tests bleiben erforderlich |
| `USP_LogShippingStatus` | liest Log-Shipping-Primary/Secondary/Monitor-Metadaten, letzte Backup/Copy/Restore-Zeit und Schwellen | aktueller Monitorstand mit historischer Zeitmarke | veralteter Monitorserver kann falschen Alarm oder falsche Entwarnung liefern; Jobs und Dateien separat prüfen |
| `USP_ReplicationStatus` | analysiert Publikationen, Subscriptions, Agent-/Distributorstatus und sichtbare Replikationsmetadaten | aktuelle Topologiesicht plus begrenzte History | lokale Instanz sieht verteilte Komponenten möglicherweise nur teilweise; Agent läuft ist kein Beweis für geringe Latenz |
| `USP_DataCaptureStatus` | inventarisiert Change Data Capture, Change Tracking und angrenzende Capturemechanismen | aktueller Enablement-/Konfigurationszustand | aktiviert bedeutet nicht, dass Capture aktuell nachkommt oder Consumer innerhalb Retention liegen |
| `USP_InfrastructureAnalysis` | orchestriert Agent, Resource Governor, AG, Backup, Log Shipping, Replication und Capture | Mischbild aktueller Zustände und Historien | Childstatus, optional nicht konfigurierte Features und Berechtigungen getrennt lesen |
| `USP_BackupChainAnalysis` | rekonstruiert Full/Diff/Log-Ketten über LSNs, Recovery Forks, Database Backup LSN und Zeitfolge | `msdb`-Historie im gewählten Fenster | metadata-konsistente Kette beweist keine vorhandenen/lesbaren Medien; COPY_ONLY, Forks und Cleanup beachten |
| `USP_AvailabilityDeepAnalysis` | vertieft Replica-, Database-, Queue-, Flow-Control-, Cluster- und gegebenenfalls Seeding-/Repair-Evidenz | aktueller verteilungsabhängiger Snapshot | Momentaufnahme zeigt Queuegröße, nicht automatisch Wachstumsrate; zwei Messpunkte oder externe Telemetrie nötig |
| `USP_AgentMonitoringAnalysis` | analysiert Jobs, Ausfälle, Laufzeitabweichungen, Schedules, Alerts, Operators und Mail-/Notificationkontext | History- und Konfigurationsmix | keine Notification beweist nicht, dass kein Fehler vorlag; Operator, Schedule, Mail und Historyretention prüfen |
| `USP_MaintenanceOperations` | zeigt aktuell laufende oder resumable Wartungsoperationen und deren Fortschritt/Status | aktueller Request-/Operationzustand plus persistierte resumable Metadaten | Prozent/Restzeit sind nur bei unterstützten Commands Schätzwerte; pausiert ist nicht beendet |

## 9. Server Health – 17 Procedures

### Technischer Familienhintergrund

Server Health umfasst Topologie, Betriebssystem, Memory, Konfiguration, Integritäts- und Kapazitätsevidenz sowie normalisierte Findings. Viele Werte beschreiben Voraussetzungen oder Risiken, nicht unmittelbar eine aktuelle Performanceursache.

| Procedure | Mechanismus und Datenherkunft | Zeitmodell und Bewertung | Aussagegrenze und Folgeanalyse |
|---|---|---|---|
| `USP_ServerCpuTopology` | liest CPU-, Socket-, Core-, Hyperthread-, Scheduler-, Affinity- und Editionskontext aus SQLOS/Serverproperties | aktueller Start-/Topologiestand | sichtbare/logische CPUs sind nicht automatisch effektiv nutzbare Lizenz-/Workloadkapazität; Affinity und Schedulerstatus prüfen |
| `USP_ServerNuma` | verbindet SQLOS-Nodes, Memory Nodes und Schedulerverteilung | aktueller NUMA-/Schedulerzustand | ungleiche Auslastung in einem Snapshot beweist kein NUMA-Problem; Workloadverteilung und mehrere Samples nötig |
| `USP_ServerMemory` | liest physisches/Prozessmemory, Memory Clerks, Target/Total Server Memory und Memorykonfiguration | aktueller Zustand plus kumulative/seit Start aufgebaute Komponenten | hoher Used Memory ist für SQL Server normal; externen Druck, Grants, Clerks, Paging und Targetabstand bewerten |
| `USP_TempDBConfiguration` | analysiert TempDB-Dateien, Größe, Wachstum, Gleichheit, Pfade, Count und Konfiguration | aktueller Dateimetadatenstand | gleiche Dateigröße ist Voraussetzung, kein Beweis für fehlende Allocation Contention; Runtime mit `USP_CurrentTempDB` |
| `USP_ServerConfiguration` | liest `sys.configurations`, configured/value-in-use, dynamic/advanced Flags und Frameworkbewertung | aktueller Konfigurationsstand | Abweichung vom Default ist nicht automatisch falsch; Workload, Edition und Change Governance einbeziehen |
| `USP_TraceFlags` | inventarisiert globale/sessionbezogene aktive Trace Flags und bekannte Einordnung | aktueller Runtimezustand | aktiv bedeutet nicht, dass Wirkung für jede Datenbank/Query gleich ist; Startupparameter und Version prüfen |
| `USP_StartupParameters` | liest Dienst-/Registry-/Startupinformationen soweit verfügbar | Startkonfiguration der laufenden Instanz | zeigt Parameter, nicht deren betriebliche Begründung; Änderung verlangt Neustart-/Rollbackplanung |
| `USP_OSInformation` | liest Host-/Windows-/Linux-, Virtualisierungs-, Pagefile- und Plattformmetadaten über unterstützte DMVs | aktueller OS-/Startkontext | Gast-OS-Sicht kann Hostengpässe nicht beweisen oder ausschließen; externe Hypervisor-/OS-Telemetrie nötig |
| `USP_ServerSecurityConfiguration` | inventarisiert sicherheitsrelevante Serveroptionen, Logins/Rollen/Endpoints und normalisierte Konfigurationsbefunde | aktueller Sicherheitsmetadatenstand | technische Abweichung ist kein vollständiges Security Audit; Policy, Eigentümer und fachliche Berechtigung fehlen |
| `USP_ServerHealthAnalysis` | orchestriert CPU, NUMA, Memory, TempDB, Config, Flags, Startup, OS und Security | mehrere aktuelle Konfigurations-/Runtime-Sichten | Überblick priorisiert; Childbefund muss im Spezialmodul validiert werden |
| `USP_DatabaseIntegrityAnalysis` | kombiniert letzten guten CHECKDB-Nachweis, Page Verify, `suspect_pages`, beschädigte/ungeprüfte Backupmetadaten und HADR Page Repair | historisch/metadatenbasiert, kein Live-CHECKDB | keine negative Evidenz ist kein Integritätsbeweis; CHECKDB und echter Restore-Test bleiben maßgeblich |
| `USP_DatabaseCapacityAnalysis` | verbindet Datei-/Volumengröße, freie Kapazität, Autogrowth, Max Size und Wachstums-/Findinglogik | aktueller Kapazitätssnapshot, gegebenenfalls abgeleitete Heuristik | ein Snapshot liefert keine Wachstumsrate; Historie und externe Volumeüberwachung ergänzen |
| `USP_PerformanceCounters` | liest `sys.dm_os_performance_counters`, Countertypen, Basecounter und optional Deltas | kumulativ oder gesampelt je Countertyp | Raw Value ohne Countertyp/Base ist oft falsch; Ratio-, Rate- und Snapshotcounter unterschiedlich berechnen |
| `USP_CriticalEngineEvents` | liest system_health/XE-/Ringbuffer-/Diagnostikquellen für kritische Engineereignisse | nur erhaltene Ereignisse und aktueller Diagnostikzustand | fehlendes Event beweist kein störungsfreies System; Sessionretention, Rollover und Rechte prüfen |
| `USP_InternalContentionAnalysis` | sampelt Latch-/Spinlock-/Waiting-Task-/Hot-Resource-Evidenz und normalisiert interne Contention | kurzes Delta plus aktuelle Ressourcen | kurze Stichprobe kann Hotspot verpassen; interne Waits sind versionsabhängig und benötigen wiederholte Bestätigung |
| `USP_BufferPoolAnalysis` | analysiert Buffer Descriptors, Datenbank-/Objekt-/Page-Verteilung, Memory Clerks und Bufferzustand | aktueller Buffer-Pool-Bestand | breiter Buffer-Descriptor-Scan kann teuer sein; Cacheanteil ist keine direkte Hit-Ratio oder Nutzenaussage |
| `USP_DiagnosticFindings` | ruft Kindmodule über definierte Verträge auf und normalisiert Severity, Confidence, Evidence und Limits | Triage über mehrere Messarten | Findings sind keine automatische Root Cause; leeres Resultset nur bei vollständigen Childstatuszeilen interpretieren |

## 10. Version Adaptive and Special Features – 8 Procedures

### Technischer Familienhintergrund

Diese Familie arbeitet capability-first. Objekt- oder Spaltenexistenz, Version, Edition, Compatibility Level, Featurekonfiguration und Berechtigung werden geprüft, bevor optionale Quellen gelesen werden. Nicht verfügbar ist ein erwarteter Zustand, kein Frameworkabbruch.

| Procedure | Mechanismus und Datenherkunft | Zeitmodell und Bewertung | Aussagegrenze und Folgeanalyse |
|---|---|---|---|
| `USP_ServerFeatureCapabilities` | prüft Version, Edition, Engine Edition, Compatibility und Existenz/Lesbarkeit versionsabhängiger Systemobjekte | aktueller Capabilityzustand | unterstützt bedeutet nicht aktiviert oder genutzt; Capability, Configuration und Evidence trennen |
| `USP_SpecialFeatureInventory` | scannt ausgewählte Datenbankkataloge nach besonderen Featureobjekten wie Graph, Ledger, External, Vector, XML oder weiteren versionsabhängigen Typen | aktueller Metadatenbestand | Objekt existiert bedeutet nicht aktive Nutzung oder korrekte Konfiguration; Featureguide vertiefen |
| `USP_InMemoryOltpAnalysis` | analysiert memory-optimized Tabellen, Hash-/Range-Indizes, Bucketverteilung, Memory-/Checkpoint-/Transaction-Evidenz | aktueller Katalog-/Runtimezustand | Hash Collision/Empty Buckets oder Memoryverbrauch nur mit Workload und Datenverteilung bewerten |
| `USP_TemporalAnalysis` | liest system-versioned Tabellen, Historytabellen, Perioden, Retention und Größen-/Indexkontext | aktueller Schemastand plus vorhandene History | Temporal ON beweist keine passende Retention/Indexierung; lange History kann fachlich erforderlich sein |
| `USP_ServiceBrokerAnalysis` | analysiert Broker Enablement, Queues, Services, Contracts, Conversation Endpoints und Transmission Queue | aktueller Queue-/Conversationzustand | Queuewachstum ist Symptom; Activation, Poison Messages, Route, Remote Endpoint und Retention prüfen |
| `USP_FullTextAnalysis` | inventarisiert Full-Text Catalogs/Indexes, Population-/Crawlstatus, Stoplists und sichtbare Fehler-/Fragmentierungsevidenz | aktueller Metadaten-/Populationzustand | IDLE kann fertig oder nicht gestartet bedeuten; Crawl History, Change Tracking und Querybedarf korrelieren |
| `USP_DataCaptureDeepAnalysis` | vertieft CDC, Change Tracking und Replication über Captureinstanzen, LSN-/Retentiongrenzen, Jobs, Sessions und Consumergefährdung | aktueller Zustand plus begrenzte Historie | `min_lsn`/Cleanup kann Consumer überholen; Enablement allein beweist keine lückenlose Verarbeitung |
| `USP_EncryptionAnalysis` | prüft TDE-/Database Encryption State, Zertifikats-/Key-Metadaten und versionsabhängige Verschlüsselungszustände ohne Schlüsselmaterial | aktueller Konfigurations-/Runtimezustand | ENCRYPTED beweist keine vollständige Key-/Backup-/Restore-Governance; Zertifikatsbackup und Restoretest extern prüfen |

## 11. Vollständigkeitszählung

| Familie | Procedures |
|---|---:|
| Common | 4 |
| Current State | 10 |
| Object and Index | 11 |
| Plan Cache | 6 |
| Query Store | 9 |
| Extended Events | 6 |
| Infrastructure | 13 |
| Server Health | 17 |
| Version Adaptive | 8 |
| **Gesamt** | **84** |

## 12. Themenübergreifende technische Kapitel

Die 84 Einzelpages dürfen gemeinsame Grundlagen nicht jeweils widersprüchlich neu erklären. Benötigt werden zentrale Kapitel:

1. SQL Server Execution Model: Session, Request, Task, Worker, Scheduler.
2. Zeitmodelle: Snapshot, kumulativ, Delta, Cacheeintrag, Intervall, Ereignis, Metadaten.
3. Locking, Isolation, Blocking, Deadlocks und Row Versioning.
4. Buffer Pool, 8-KB-Seiten, Read-Ahead, Latches und Storage-I/O.
5. Query Processing, Cardinality Estimation, Statistiken und Showplan.
6. Query Execution Memory, Grants, Sort/Hash und Spills.
7. Transaktionslog, Recovery, VLF, Backups und Logtransport.
8. B-Tree-/Heap-/Columnstore-Strukturen und Wartungswirkungen.
9. Query Store Capture, Intervalle, Cleanup und Plan-/Hint-Governance.
10. Extended Events Session, Event, Action, Predicate, Target, Drop und Rollover.
11. Agent, `msdb`-Historie, HADR, Replication und verteilte Sicht.
12. Capability Detection, Version, Edition und Compatibility Level.

## 13. Historische Integrationsreihenfolge

Die folgende Reihenfolge wurde bei der abgeschlossenen 84/84-Integration verwendet und bleibt als Redaktionsnachweis erhalten:

1. Das damalige Review prüfte Inventar und RAW-Verträge erneut gegen den aktuellen `main`-Stand.
2. Es legte gemeinsame Grundlagenkapitel an.
3. Es vertiefte Current State vollständig.
4. Es vertiefte Object, Index, Statistics und Plan Cache.
5. Es vertiefte Query Store und Extended Events.
6. Es vertiefte Infrastructure und Server Health.
7. Es vertiefte Version Adaptive.
8. Es brachte alle Procedure-Seiten auf den 16-Punkte-Standard.
9. Es erweiterte die statische Dokumentationsvalidierung um RAW-Spalten-, Quellen- und Linkprüfungen.
10. Vor jeder Integration erfolgte ein fachliches und datenschutzbezogenes Review.

## 14. Quellenstrategie

Primäre technische Aussagen sollen aus dem kanonischen T-SQL-Code und offizieller Microsoft-Dokumentation stammen. Besonders wichtige Einstiegspunkte:

- [Dynamic management views and functions](https://learn.microsoft.com/sql/relational-databases/system-dynamic-management-views/system-dynamic-management-views)
- [Query processing architecture guide](https://learn.microsoft.com/sql/relational-databases/query-processing-architecture-guide)
- [SQL Server transaction locking and row versioning guide](https://learn.microsoft.com/sql/relational-databases/sql-server-transaction-locking-and-row-versioning-guide)
- [Monitor performance by using Query Store](https://learn.microsoft.com/sql/relational-databases/performance/monitoring-performance-by-using-the-query-store)
- [Extended Events overview](https://learn.microsoft.com/sql/relational-databases/extended-events/extended-events)
- [SQL Server index architecture and design guide](https://learn.microsoft.com/sql/relational-databases/sql-server-index-design-guide)
- [Statistics](https://learn.microsoft.com/sql/relational-databases/statistics/statistics)
- [Columnstore indexes overview](https://learn.microsoft.com/sql/relational-databases/indexes/columnstore-indexes-overview)
- [Always On availability groups overview](https://learn.microsoft.com/sql/database-engine/availability-groups/windows/overview-of-always-on-availability-groups-sql-server)
- [SQL Server backup and restore](https://learn.microsoft.com/sql/relational-databases/backup-restore/back-up-and-restore-of-sql-server-databases)

Ergänzende Expert:innenquellen dürfen unterschiedliche Praxiserfahrungen erklären, müssen aber als solche gekennzeichnet werden und dürfen offizielle Produktsemantik nicht ersetzen.

## 15. Aussagegrenze dieses Archivs

Diese Matrix weist die ursprüngliche Research-Abdeckung aller 84 Procedures nach, ist aber nicht die kanonische Enddokumentation. Die folgenden Inhalte sind inzwischen in den Procedure-Seiten, Familienguides und technischen Grundlagen integriert:

- vollständigen Spaltenkatalog aus dem tatsächlichen RAW-Vertrag,
- Quellspalte-zu-Ausgabespalte-Mapping,
- genaue Formel- und Filterbeschreibung,
- synthetische Normal-, Problem-, Grenz- und Fehlinterpretationsbeispiele,
- didaktischen Entscheidungsbaum,
- versions- und berechtigungsbezogene Abweichungen,
- überprüfte weiterführende Links je Procedure.
