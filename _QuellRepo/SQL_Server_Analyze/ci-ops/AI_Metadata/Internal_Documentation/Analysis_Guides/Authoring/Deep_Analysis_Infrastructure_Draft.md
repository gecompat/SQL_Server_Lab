# Draft: technische Vertiefung – Infrastructure

**Stand:** 19. Juli 2026
**Status:** integriertes Authoring-Archiv; nicht kanonisch
**Abdeckung:** 13 Procedures aus `07_Infrastructure`

> Infrastrukturdiagnose verbindet lokale Runtime-DMVs, `msdb`-Historie und verteilte Komponenten. Die lokale Instanz kann bei AG, Log Shipping und Replication nur einen Teil der Topologie sehen. History Cleanup, Monitorlatenz und fehlender Remotezugriff müssen als Evidenzgrenzen dokumentiert werden.

## 1. Gemeinsame Zeit- und Topologiemodelle

- Agent-/Backup-/Restore-/Log-Shipping-Historie ist nur so vollständig wie `msdb`-Retention und Cleanup.
- HADR-DMVs sind Momentaufnahmen; Queuegröße ohne Änderungsrate zeigt Bestand, nicht Trend.
- Replication besitzt Publisher, Distributor und Subscriber mit unterschiedlichen lokalen Sichten.
- CDC/Change Tracking besitzen Retentiongrenzen; Consumer können hinter den noch verfügbaren Bereich zurückfallen.
- Ein erfolgreicher Metadatensatz beweist nicht, dass Medium, Netzwerkpfad oder Remoteziel aktuell verwendbar ist.

## 2. Procedures

### `[monitor].[USP_AgentStatus]`

**Leitfrage:** Ist SQL Server Agent auf dieser Plattform vorhanden und läuft der Dienst?

**Technischer Hintergrund:** Agent führt Jobs über einen separaten Dienst und `msdb`-Metadaten aus. Dienstzustand, Startmodus und Plattformverfügbarkeit sind Voraussetzungen, aber noch keine Aussage über Scheduler, Jobowner, Proxies oder einzelne Jobs.

**Datenquellen:** Die Analyse verwendet folgende Datenquellen und Ausführungspfade: `msdb.dbo.sysjobs`, `msdb.dbo.syssessions`, `sys.dm_server_services`.

**Zeit- und Scopemodell:** Die zeitliche und fachliche Aussage ist wie folgt begrenzt: Aktueller Servicezustand; bei Restart/Failover kann der Status wechseln.

**Bewertung und Gegenprobe:** Für die Bewertung und Gegenprobe gelten folgende Prüfschritte: Dienst vorhanden/läuft, Edition/Plattform, Startmodus und Agent-XPs/Erreichbarkeit gemeinsam lesen. Ein bewusst deaktivierter Agent kann in containerisierten oder extern orchestrierten Umgebungen normal sein.

**Typische Fehlinterpretation:** `Running` beweist weder aktive Schedules noch erfolgreiche Jobs. Ein gestoppter Agent erklärt fehlende Ausführungen, aber nicht deren ursprüngliche Ursache.

**Weiterführende Analyse:** Für die weiterführende Analyse gelten folgende Schritte und Quellen: `USP_AgentJobs` und `USP_AgentMonitoringAnalysis`.

### `[monitor].[USP_AgentJobs]`

**Leitfrage:** Welche Jobs sind aktiviert, geplant, aktuell laufend oder zuletzt fehlgeschlagen beziehungsweise ungewöhnlich langsam?

**Technischer Hintergrund:** `msdb.dbo.sysjobs`, Steps, Schedules, Job Activity und History bilden Definition, aktuelle Instanzaktivität und vergangene Outcomes. `sysjobhistory` speichert Job-/Stepzeilen mit integercodierten Datum-/Zeit-/Dauerwerten; laufende Aktivität liegt in `sysjobactivity`.

**Datenquellen:** Die Analyse verwendet folgende Datenquellen und Ausführungspfade: `master.sys.databases`, `msdb.dbo.agent_datetime`, `msdb.dbo.syscategories`, `msdb.dbo.sysjobactivity`, `msdb.dbo.sysjobhistory`, `msdb.dbo.sysjobs`, `msdb.dbo.sysjobschedules`, `msdb.dbo.sysjobsteps`, `msdb.dbo.sysschedules`, `sys.sp_executesql`.

**Zeit- und Scopemodell:** Die zeitliche und fachliche Aussage ist wie folgt begrenzt: Konfigurationssnapshot plus aufbewahrte History. Agentrestart erzeugt neue Sessionkontexte; Cleanup begrenzt Historie.

**Bewertung und Gegenprobe:** Berücksichtigen Sie Jobstatus, aktuellen Step, Run Requested, Start und Stop, Retry, letzte Outcomes, Schedule und typische Laufzeit gemeinsam. Unterscheiden Sie die Jobgesamtzeile von Stepfehlern.

**Typische Fehlinterpretation:** `LastRunOutcome=Succeeded` kann einen später aktuell laufenden/steckenden Lauf überdecken. History kann abgeschnitten sein; lange Dauer muss mit Workloadfenster verglichen werden.

**Weiterführende Analyse:** Für die weiterführende Analyse gelten folgende Schritte und Quellen: `USP_AgentMonitoringAnalysis`, Current Requests/Blocking und Jobstep-/Logoutput.

### `[monitor].[USP_ResourceGovernorAnalysis]`

**Leitfrage:** Wie klassifiziert und begrenzt Resource Governor Sessions und welche Pools/Groups zeigen Druck oder Abweichungen?

**Technischer Hintergrund:** Classifier Function ordnet neue Sessions Workload Groups zu; Groups verweisen auf Resource Pools. Katalogsichten enthalten konfigurierte Werte, Runtime-DMVs `value_in_use` und Counter. CPU Caps, Min/Max Memory, Grant Percentage, Request Limits und External Pools wirken auf unterschiedliche Ressourcen.

**Datenquellen:** Die Analyse verwendet folgende Datenquellen und Ausführungspfade: `master.sys.objects`, `master.sys.schemas`, `sys.dm_exec_sessions`, `sys.dm_resource_governor_configuration`, `sys.dm_resource_governor_resource_pools`, `sys.dm_resource_governor_workload_groups`, `sys.resource_governor_configuration`, `sys.resource_governor_resource_pools`, `sys.resource_governor_workload_groups`.

**Zeit- und Scopemodell:** Die zeitliche und fachliche Aussage ist wie folgt begrenzt: Aktueller Config-/Runtimezustand; Counter meist kumulativ seit Aktivierung/Start. Bereits verbundene Sessions werden durch Classifieränderung nicht automatisch neu klassifiziert.

**Bewertung und Gegenprobe:** Für die Bewertung und Gegenprobe gelten folgende Prüfschritte: Configured vs runtime, Pool/Group-Zuordnung, aktive Requests, Queues, CPU/Memory/Grantlimits und Default/Internal-Kontext lesen. Throttling kann absichtlich sein.

**Typische Fehlinterpretation:** Eine Query in einer Group beweist nicht, dass der Classifier aktuell dieselbe Entscheidung für neue Logins treffen würde. Limits sind nicht alle harte Reservierungen.

**Weiterführende Analyse:** Für die weiterführende Analyse gelten folgende Schritte und Quellen: Current Requests/Memory Grants, Configuration und reproduzierbarer Login-/Classifiertest.

### `[monitor].[USP_AvailabilityGroups]`

**Leitfrage:** Welche AG-Replicas und Availability Databases sind verbunden, synchronisiert und mit welchen Send-/Redoqueues?

**Technischer Hintergrund:** Primär erzeugt Log Records, sendet Logblöcke an Secondaries, diese harden und redoen. Synchroner Commit wartet je Konfiguration auf Bestätigung. Replica-/Database-DMVs liefern Role, Connection, Synchronization State/Health, Send/Redo Queue, Rate und Last Hardened/Redone.

**Datenquellen:** Die Analyse verwendet folgende Datenquellen und Ausführungspfade: `sys.availability_group_listener_ip_addresses`, `sys.availability_group_listeners`, `sys.availability_groups`, `sys.availability_read_only_routing_lists`, `sys.availability_replicas`, `sys.dm_hadr_`, `sys.dm_hadr_availability_replica_states`, `sys.dm_hadr_database_replica_states`, `sys.fn_hadr_is_primary_replica`.

**Zeit- und Scopemodell:** Die zeitliche und fachliche Aussage ist wie folgt begrenzt: Aktueller lokaler Snapshot; Ratewerte können intern über begrenzte Intervalle berechnet werden und schwanken.

**Bewertung und Gegenprobe:** Für die Bewertung und Gegenprobe gelten folgende Prüfschritte: Role, Availability Mode, Failover Mode, Connected State, Sync State, Queue MB, Rate und Zeitmarken kombinieren. Queue/Rate liefert eine grobe Abarbeitungszeit nur bei stabiler Rate.

**Typische Fehlinterpretation:** `SYNCHRONIZED` bedeutet nicht null Latenz oder lesbare Secondary. Queuegröße allein ohne Trend und Workloadrate ist keine Prognose.

**Weiterführende Analyse:** Für die weiterführende Analyse gelten folgende Schritte und Quellen: `USP_AvailabilityDeepAnalysis`, Current Log/I/O und externe Cluster-/Netzwerktelemetrie.

### `[monitor].[USP_BackupRecovery]`

**Leitfrage:** Existieren im sichtbaren Fenster die erwarteten Full-, Differential- und Logbackups für das Recoverymodell?

**Technischer Hintergrund:** `msdb` speichert Backup Sets, Medien-/Dateiinformation, Type, LSNs, Start/Finish, Size/Compression/Checksum und Damageindikatoren. Recovery Model bestimmt, ob eine kontinuierliche Logkette erwartet wird.

**Datenquellen:** Die Analyse verwendet folgende Datenquellen und Ausführungspfade: `msdb.dbo.backupmediafamily`, `msdb.dbo.backupset`, `msdb.dbo.restorehistory`.

**Zeit- und Scopemodell:** Die zeitliche und fachliche Aussage ist wie folgt begrenzt: Historie innerhalb `msdb`-Retention; Datenträger/Dateien werden nicht geöffnet.

**Bewertung und Gegenprobe:** Für die Bewertung und Gegenprobe gelten folgende Prüfschritte: Letzte Backupzeiten gegen RPO/Policy, Recovery Model, CopyOnly, Checksum, Damage, Größe/Dauer und Logbackupkontinuität prüfen. SIMPLE benötigt keine Logbackups, FULL ohne regelmäßige Logbackups verhindert Logtruncation.

**Typische Fehlinterpretation:** Eine erfolgreiche Backup-Historyzeile beweist weder Dateiexistenz noch erfolgreichen Restore. `RESTORE VERIFYONLY` ist ebenfalls kein vollständiger Restoretest.

**Weiterführende Analyse:** Für die weiterführende Analyse gelten folgende Schritte und Quellen: `USP_BackupChainAnalysis`, Database Integrity und regelmäßiger echter Restoretest.

### `[monitor].[USP_LogShippingStatus]`

**Leitfrage:** Erzeugen, kopieren und restaurieren die Log-Shipping-Jobs Backups innerhalb der konfigurierten Schwellen?

**Technischer Hintergrund:** Log Shipping besteht aus Backupjob auf Primary, Copy-/Restorejobs auf Secondary und optional Monitorserver. Monitor-/Primary-/Secondarytabellen halten letzte Datei-/Zeit-/Schwellenwerte. Jede Stufe kann unabhängig zurückliegen.

**Datenquellen:** Die Analyse verwendet folgende Datenquellen und Ausführungspfade: `msdb.dbo.log_shipping_monitor_primary`, `msdb.dbo.log_shipping_monitor_secondary`, `msdb.dbo.log_shipping_primary_databases`, `msdb.dbo.log_shipping_secondary_databases`.

**Zeit- und Scopemodell:** Die zeitliche und fachliche Aussage ist wie folgt begrenzt: Monitor-Metadaten mit eigener Aktualisierungszeit plus Jobhistory. Clock Skew und stale Monitor beeinflussen Interpretation.

**Bewertung und Gegenprobe:** Für die Bewertung und Gegenprobe gelten folgende Prüfschritte: Backup-, Copy- und Restorelatenz getrennt lesen; letzte Dateinamen/Zeiten, Threshold, Alertstatus, Jobzustand und Monitoraktualität korrelieren. Restore Mode/Delay kann absichtlich verzögern.

**Typische Fehlinterpretation:** Ein grüner Monitor kann stale sein. Eine alte Restorezeit ist bei konfiguriertem Delay nicht automatisch Fehler. Dateinamen allein beweisen keine lückenlose LSN-Kette.

**Weiterführende Analyse:** Für die weiterführende Analyse gelten folgende Schritte und Quellen: Agent Jobs, Backup Chain und Secondary-/Shareprüfung.

### `[monitor].[USP_ReplicationStatus]`

**Leitfrage:** Welche Replikationstopologie und Agentzustände sind lokal sichtbar, und gibt es Fehler oder Rückstand?

**Technischer Hintergrund:** Transactional Replication nutzt Log Reader und Distribution Agents; Merge Replication eigene Agents/Sessions. Publisher-, Distributor- und Subscriber-Metadaten liegen auf verschiedenen Servern/Datenbanken. History und Commands bilden begrenzte Zustände/Latenz.

**Datenquellen:** Die Analyse verwendet folgende Datenquellen und Ausführungspfade: `sys.databases`, `sys.sp_executesql`.

**Zeit- und Scopemodell:** Die zeitliche und fachliche Aussage ist wie folgt begrenzt: Verteilte Momentaufnahme plus Distributor-/Agenthistory innerhalb Retention.

**Bewertung und Gegenprobe:** Berücksichtigen Sie Topologierolle, Agentstatus, letzte Aktion und Fehler, undistributed commands, geschätzte Latenz und Zeitmarken gemeinsam. Geben Sie den Remote- oder Distributorzugriff als Partialstatus aus.

**Typische Fehlinterpretation:** `Running` bedeutet nur aktiver Agent, nicht geringe Latenz. Lokale Leere kann fehlende Rolle oder fehlenden Remotezugriff bedeuten.

**Weiterführende Analyse:** Für die weiterführende Analyse gelten folgende Schritte und Quellen: `USP_DataCaptureDeepAnalysis`, Agent Jobs, Log/Distributor-DB-Kapazität und Replication Monitor.

### `[monitor].[USP_DataCaptureStatus]`

**Leitfrage:** Welche Change-Capture-Technologien sind aktiviert und grundsätzlich betriebsbereit?

**Technischer Hintergrund:** CDC liest Transaction Log asynchron in Change Tables und räumt per Cleanupjob auf. Change Tracking speichert kompakte Änderungsinformationen mit Retention/Auto Cleanup, keine vollständigen historischen Werte. Replication besitzt eigenen Logreader-/Distributionspfad.

**Datenquellen:** Die Analyse verwendet folgende Datenquellen und Ausführungspfade: `master.sys.databases`, `msdb.dbo.agent_datetime`, `msdb.dbo.sysjobhistory`, `msdb.dbo.sysjobs`, `sys.change_tracking_databases`, `sys.change_tracking_tables`, `sys.databases`, `sys.schemas`, `sys.sp_executesql`, `sys.tables`.

**Zeit- und Scopemodell:** Die zeitliche und fachliche Aussage ist wie folgt begrenzt: Aktueller Enablement-/Konfigurationszustand mit begrenzten Job-/LSN-/Versionmarken.

**Bewertung und Gegenprobe:** Berücksichtigen Sie Technologie, Captureinstanzen, Jobs, Retention, Min und Max LSN beziehungsweise Change-Tracking-Versionen sowie die Tabellenabdeckung. Prüfen Sie die Consumerposition gegen Mindestversion oder Min LSN.

**Typische Fehlinterpretation:** `Enabled=1` beweist keinen aktuellen Durchsatz, keine lückenlose Retention und keine funktionierenden Consumer.

**Weiterführende Analyse:** Für die weiterführende Analyse gelten folgende Schritte und Quellen: `USP_DataCaptureDeepAnalysis`, Agent Jobs und Consumercheckpoint.

### `[monitor].[USP_InfrastructureAnalysis]`

**Leitfrage:** Welche Infrastrukturmodule sollen als Triage in einem kontrollierten Lauf zusammengeführt werden?

**Technischer Hintergrund:** Der Wrapper orchestriert Agent, Resource Governor, AG, Backup, Log Shipping, Replication und Capture. Nicht konfigurierte Features sollen als Status statt Fehler behandelt werden; Deep Children bleiben opt-in.

**Datenquellen:** Die Analyse verwendet folgende Datenquellen und Ausführungspfade: Frameworkinterne Orchestrierung; Quellen liegen in Childmodulen.

**Zeit- und Scopemodell:** Die zeitliche und fachliche Aussage ist wie folgt begrenzt: Nicht atomare Mischung aus Snapshots und `msdb`-Historien.

**Bewertung und Gegenprobe:** Für die Bewertung und Gegenprobe gelten folgende Prüfschritte: Modulstatus zuerst, dann nur konfigurierte/auffällige Komponenten vertiefen. Ein nicht vorhandenes Feature ist normal, sofern der Scope es nicht erwartet.

**Typische Fehlinterpretation:** Leere Resultsets dürfen nicht familienübergreifend als gesund zusammengefasst werden; jede Quelle besitzt eigene Retention und Berechtigung.

**Weiterführende Analyse:** Für die weiterführende Analyse gelten folgende Schritte und Quellen: Betroffenes Childmodul mit engem Scope.

### `[monitor].[USP_BackupChainAnalysis]`

**Leitfrage:** Ist aus sichtbaren Backupsets eine technisch konsistente Restorekette mit passender Full-/Diff-/Log-LSN-Folge rekonstruierbar?

**Technischer Hintergrund:** Fullbackups definieren Database Backup LSN/Checkpoint; Differentials basieren auf Differential Base; Logbackups decken First/Last LSN und Recovery Forks ab. CopyOnly beeinflusst Differential Base beziehungsweise Logkette unterschiedlich. Restorefolge muss LSN- und Forkkonsistenz wahren.

**Datenquellen:** Die Analyse verwendet folgende Datenquellen und Ausführungspfade: `msdb.dbo.backupset`, `msdb.dbo.restorehistory`.

**Zeit- und Scopemodell:** Die zeitliche und fachliche Aussage ist wie folgt begrenzt: `msdb`-Metadaten im gewählten Fenster; ein zu kurzes Fenster kann die notwendige Basis ausblenden.

**Bewertung und Gegenprobe:** Für die Bewertung und Gegenprobe gelten folgende Prüfschritte: Recovery Fork, Fullbasis, Differential Base, Log First/Last LSN, Gap-/Overlapindikatoren, CopyOnly und Backupzeiten prüfen. Kette je gewünschtem Restorezeitpunkt bewerten.

**Typische Fehlinterpretation:** Metadatenkonsistenz beweist nicht, dass Medien vorhanden, unbeschädigt, entschlüsselbar oder zugreifbar sind. Ein vermeintliches Gap kann durch außerhalb des Fensters liegende Sets entstehen.

**Weiterführende Analyse:** Für die weiterführende Analyse gelten folgende Schritte und Quellen: Echter Restoretest, `USP_BackupRecovery`, Encryption-/Certificate-Governance.

### `[monitor].[USP_AvailabilityDeepAnalysis]`

**Leitfrage:** Warum ist eine AG/Replica nicht gesund, welche Datenbewegungsstufe staut und welche Risiken entstehen?

**Technischer Hintergrund:** Vertiefung kombiniert Cluster-/Replica-/Databasezustand, Send/Redo, Flow Control, Suspend Reason, Seeding, Page Repair und gegebenenfalls Read-only Routing. Logproduktion, Capture, Send, Harden und Redo sind getrennte Pipelineabschnitte.

**Datenquellen:** Die Analyse verwendet folgende Datenquellen und Ausführungspfade: `sys.availability_groups`, `sys.availability_replicas`, `sys.dm_hadr_auto_page_repair`, `sys.dm_hadr_availability_replica_states`, `sys.dm_hadr_cluster`, `sys.dm_hadr_cluster_members`, `sys.dm_hadr_cluster_networks`, `sys.dm_hadr_database_replica_states`, `sys.dm_hadr_physical_seeding_stats`.

**Zeit- und Scopemodell:** Die zeitliche und fachliche Aussage ist wie folgt begrenzt: Aktueller verteilungsabhängiger Snapshot; einige Daten nur auf Primary oder lokalem Replica verfügbar.

**Bewertung und Gegenprobe:** Für die Bewertung und Gegenprobe gelten folgende Prüfschritte: Pipeline lokalisieren: Log Send Queue vs Redo Queue, Rate/Trend, Connected/Suspended, Last Hardened/Redone, Sync Commit Waits, Disk-/Networkkontext. Partialvisibility explizit halten.

**Typische Fehlinterpretation:** Estimated catch-up time aus Queue/aktueller Rate ist bei Rateänderung instabil. `NOT_HEALTHY` ist Folge, nicht Root Cause.

**Weiterführende Analyse:** Für die weiterführende Analyse gelten folgende Schritte und Quellen: Current Log/I/O/Waits, Clusterlog, OS-/Netzwerktelemetrie.

### `[monitor].[USP_AgentMonitoringAnalysis]`

**Leitfrage:** Welche Jobs, Alerts und Benachrichtigungsketten gefährden geplante Betriebsabläufe?

**Technischer Hintergrund:** Die Procedure verbindet Job-/Step-/Schedule-/Historyanalyse mit Alerts, Operators und Database Mail-/Notificationkontext. Laufzeitanomalien benötigen historische Vergleichswerte; Notifications benötigen korrekt verknüpfte Operator-/Mailkonfiguration.

**Datenquellen:** Die Analyse verwendet folgende Datenquellen und Ausführungspfade: `msdb.dbo.agent_datetime`, `msdb.dbo.sysalerts`, `msdb.dbo.sysjobhistory`, `msdb.dbo.sysjobs`, `msdb.dbo.sysjobschedules`, `msdb.dbo.sysmail_allitems`, `msdb.dbo.sysnotifications`, `msdb.dbo.sysoperators`, `msdb.dbo.sysschedules`, `sys.dm_server_services`.

**Zeit- und Scopemodell:** Die zeitliche und fachliche Aussage umfasst einen Konfigurationssnapshot und eine begrenzte Ausführungshistorie.

**Bewertung und Gegenprobe:** Korrelieren Sie Fehlerhäufigkeit, letzten und aktuellen Lauf, typische Dauer, Schedule Miss, Retry, Alertbedingungen, Operatorzeiten und Mailstatus. Priorisieren Sie kritische Jobs nach ihrer Funktion.

**Typische Fehlinterpretation:** Keine Mail bedeutet nicht kein Fehler und ein erfolgreicher Mailtest nicht funktionierende Jobnotification. P95-/Baselinewerte sind bei wenigen Läufen schwach.

**Weiterführende Analyse:** Für die weiterführende Analyse gelten folgende Schritte und Quellen: Agent Jobs, Jobstepoutput, Database Mail Logs und Current State.

### `[monitor].[USP_MaintenanceOperations]`

**Leitfrage:** Welche Wartungsoperationen laufen, sind pausiert/resumable oder blockiert, und wie belastbar ist ihre Fortschrittsanzeige?

**Technischer Hintergrund:** Aktive BACKUP/RESTORE/DBCC/INDEX-Commands erscheinen in Requests; resumable Indexoperationen besitzen persistierte Katalogzeilen mit State, Start/Pause, Prozent und Ressourcenoptionen. Locks, Log, TempDB und I/O können die Laufzeit dominieren.

**Datenquellen:** Die Analyse verwendet folgende Datenquellen und Ausführungspfade: `msdb.dbo.sysjobactivity`, `msdb.dbo.sysjobs`, `msdb.dbo.syssessions`, `sys.databases`, `sys.dm_exec_requests`, `sys.dm_tran_persistent_version_store_stats`, `sys.index_resumable_operations`.

**Zeit- und Scopemodell:** Die zeitliche und fachliche Aussage umfasst einen aktuellen Requestsnapshot und den persistierten Zustand resumierbarer Operationen.

**Bewertung und Gegenprobe:** Für die Bewertung und Gegenprobe gelten folgende Prüfschritte: Command, Status, Percent Complete, Estimated Completion, DOP, Wait/Blocker, Log-/TempDB-/I/O-Kontext und Resume/Pauseoptionen lesen. Pausierte Operation kann weiterhin Speicher/Strukturzustand belegen.

**Typische Fehlinterpretation:** Percent Complete ist nur für unterstützte Commands und nicht linear. Abbruch kann Rollback-/Cleanupkosten verursachen; `PAUSED` ist nicht erfolgreich abgeschlossen.

**Weiterführende Analyse:** Für die weiterführende Analyse gelten folgende Schritte und Quellen: Current Requests/Blocking/IO/Log und operationsspezifischer Runbook.

## 3. Offizielle Primärquellen

- [SQL Server Agent](https://learn.microsoft.com/sql/ssms/agent/sql-server-agent)
- [Resource Governor](https://learn.microsoft.com/sql/relational-databases/resource-governor/resource-governor)
- [Always On availability groups overview](https://learn.microsoft.com/sql/database-engine/availability-groups/windows/overview-of-always-on-availability-groups-sql-server)
- [Monitor availability groups](https://learn.microsoft.com/sql/database-engine/availability-groups/windows/monitor-availability-groups-transact-sql)
- [Backup and restore](https://learn.microsoft.com/sql/relational-databases/backup-restore/back-up-and-restore-of-sql-server-databases)
- [Transaction log backups](https://learn.microsoft.com/sql/relational-databases/backup-restore/transaction-log-backups-sql-server)
- [About log shipping](https://learn.microsoft.com/sql/database-engine/log-shipping/about-log-shipping-sql-server)
- [Replication](https://learn.microsoft.com/sql/relational-databases/replication/sql-server-replication)
- [Change Data Capture](https://learn.microsoft.com/sql/relational-databases/track-changes/about-change-data-capture-sql-server)
- [Change Tracking](https://learn.microsoft.com/sql/relational-databases/track-changes/about-change-tracking-sql-server)
- [Resumable index operations](https://learn.microsoft.com/sql/relational-databases/indexes/perform-index-operations-online)
