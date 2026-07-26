# Draft: technische Vertiefung – Server Health

**Stand:** 19. Juli 2026
**Status:** integriertes Authoring-Archiv; nicht kanonisch
**Abdeckung:** 17 Procedures aus `08_ServerHealth`

> Server Health verbindet Hardware-/SQLOS-Topologie, Memory, TempDB, Konfiguration, Betriebssystem, Security, Integrität, Kapazität, Performance Counter und Engineereignisse. Konfigurationsabweichungen sind Risiken oder Reviewaufträge; sie sind nicht automatisch die Ursache eines aktuellen Vorfalls.

## 1. Gemeinsames Bewertungsmodell

- Topologiewerte erklären verfügbare Scheduler-/NUMA-Struktur, nicht automatisch deren Auslastung.
- SQL Server nutzt Memory absichtlich aggressiv; `used` ist ohne Drucksignale kein Fehler.
- Konfigurationswerte benötigen `value` versus `value_in_use`, Version, Edition und Workloadkontext.
- Keine negative Integritätsevidenz ersetzt keinen aktuellen CHECKDB-/Restoretest.
- Performance Counter besitzen unterschiedliche Countertypen; Raw Values sind nicht einheitlich interpretierbar.
- system_health/XE/Ringbuffer zeigen nur erhaltene Ereignisse.

## 2. Procedures

### `[monitor].[USP_ServerCpuTopology]`

**Leitfrage:** Welche CPU-, Socket-, Core-, Hyperthread-, Scheduler- und Affinitystruktur sieht SQL Server?

**Technischer Hintergrund:** SQL Server erstellt SQLOS-Scheduler für sichtbare logische CPUs unter Berücksichtigung von Edition, Lizenz-/Affinitykonfiguration und Onlinezustand. Sockets, NUMA Nodes, Cores und Hyperthreading beeinflussen Parallelität, Lizenzierung und Memorylocality.

**Datenquellen:** Die Analyse verwendet folgende Datenquellen und Ausführungspfade: `sys.dm_os_nodes`, `sys.dm_os_schedulers`, `sys.dm_os_sys_info`.

**Zeit- und Scopemodell:** Die zeitliche und fachliche Aussage ist wie folgt begrenzt: Aktueller Instanz-/Startzustand; Hardwarezuweisung in VM/Container kann sich erst nach Neustart vollständig widerspiegeln.

**Bewertung und Gegenprobe:** Für die Bewertung und Gegenprobe gelten folgende Prüfschritte: Visible/Online Schedulers, Physical/Logical CPU, Socket/Core-Verhältnis, Hyperthread Ratio, Affinity und Edition gemeinsam lesen. Ungleiche Schedulerverfügbarkeit oder unerwartete CPUzahl ist ein Konfigurationshinweis.

**Typische Fehlinterpretation:** Viele CPUs bedeuten nicht automatisch mehr Queryleistung. MAXDOP, Cost Threshold, NUMA, Lizenzgrenze und Workloadparallelität bestimmen Nutzung.

**Weiterführende Analyse:** Für die weiterführende Analyse gelten folgende Schritte und Quellen: `USP_ServerNuma`, Performance Counters, Current Requests/Waits.

### `[monitor].[USP_ServerNuma]`

**Leitfrage:** Wie sind Scheduler und Memory auf SQLOS-/Hardware-NUMA-Nodes verteilt und gibt es sichtbare Ungleichgewichte?

**Technischer Hintergrund:** NUMA hält CPU und lokal angebundenes Memory zusammen. SQLOS-Nodes/Scheduler verteilen Workers; Memory Nodes verwalten Locality. Soft-NUMA kann zusätzliche logische Gruppen erzeugen. Remote Memory Access kann teurer sein.

**Datenquellen:** Die Analyse verwendet folgende Datenquellen und Ausführungspfade: `sys.dm_os_memory_nodes`, `sys.dm_os_nodes`, `sys.dm_os_schedulers`.

**Zeit- und Scopemodell:** Die zeitliche und fachliche Aussage ist wie folgt begrenzt: Aktueller Node-/Schedulerzustand; Loadcounter sind Momentaufnahme oder kumulativ je Quelle.

**Bewertung und Gegenprobe:** Für die Bewertung und Gegenprobe gelten folgende Prüfschritte: Online/Idle Schedulers, Runnable Tasks, Active Workers, Load Factor, Memory Nodezuordnung und wiederholte Samples vergleichen. Ein persistentes einseitiges Muster ist relevanter als ein Snapshot.

**Typische Fehlinterpretation:** Ungleiche Momentaufnahme ist bei zufälliger Workload normal. Node ID ist kein direkter physischer Socketbeweis bei Soft-NUMA/VM.

**Weiterführende Analyse:** Für die weiterführende Analyse gelten folgende Schritte und Quellen: `USP_ServerCpuTopology`, Current Requests und Server Memory.

### `[monitor].[USP_ServerMemory]`

**Leitfrage:** Hat SQL Server oder das Betriebssystem Memory Pressure, und welche Clerks/Komponenten verwenden Speicher?

**Technischer Hintergrund:** SQL Server Memory Manager balanciert Buffer Pool, Plan Cache, Query Execution Memory und weitere Clerks unter Min/Max Server Memory. OS-/Process-DMVs zeigen physisches Memory, Commit/Pagefile und Process Working Set. Target versus Total Server Memory und Memory Notifications liefern Drucksignale.

**Datenquellen:** Die Analyse verwendet folgende Datenquellen und Ausführungspfade: `sys.configurations`, `sys.dm_exec_query_memory_grants`, `sys.dm_os_memory_clerks`, `sys.dm_os_process_memory`, `sys.dm_os_sys_info`, `sys.dm_os_sys_memory`.

**Zeit- und Scopemodell:** Die zeitliche und fachliche Aussage ist wie folgt begrenzt: Aktueller Zustand; Clerk-/Processwerte verändern sich, einzelne Counter seit Start.

**Bewertung und Gegenprobe:** Für die Bewertung und Gegenprobe gelten folgende Prüfschritte: OS Available/Commit, process physical/virtual low flags, Total/Target, Max Server Memory, locked pages, clerk distribution, pending grants und paging zusammen lesen. Hoher SQL-Memoryverbrauch allein ist erwartbar.

**Typische Fehlinterpretation:** `Available MBytes` oder PLE besitzen keine universellen Einzelgrenzen. Buffer Pool und Query Grants sind unterschiedliche Verbraucher; VM Ballooning kann außerhalb SQL-Sicht liegen.

**Weiterführende Analyse:** Für die weiterführende Analyse gelten folgende Schritte und Quellen: `USP_BufferPoolAnalysis`, Current Memory Grants, Performance Counters und OS/Hypervisor-Telemetrie.

### `[monitor].[USP_TempDBConfiguration]`

**Leitfrage:** Ist TempDB hinsichtlich Dateianzahl, Größe, Growth, Layout und Optionen robust konfiguriert?

**Technischer Hintergrund:** TempDB wird bei jedem Start neu erstellt. Datafiles bilden Allocationkonkurrenz ab; gleich große Dateien begünstigen Proportional Fill. Autogrowth ist Notfallkapazität, kein laufendes Sizingmodell. Version Store, Internal/User Objects verursachen Runtimebelegung.

**Datenquellen:** Die Analyse verwendet folgende Datenquellen und Ausführungspfade: `sys.configurations`, `tempdb.sys.database_files`.

**Zeit- und Scopemodell:** Die zeitliche und fachliche Aussage ist wie folgt begrenzt: Aktueller Katalog-/Dateistand; TempDB-Inhalt seit Engine-Start.

**Bewertung und Gegenprobe:** Für die Bewertung und Gegenprobe gelten folgende Prüfschritte: Datafile Count relativ zu Workload/CPU, gleiche Initialgröße/Growth, absolute Growthgröße, Volumeplatz, Logfile und versionsabhängige Optionen prüfen. Änderungen anhand gemessener Contention statt pauschaler Maximalzahl.

**Typische Fehlinterpretation:** Mehr Dateien lösen nicht jeden PAGELATCH-Wait; zu viele Dateien erhöhen Verwaltung/Recovery/Storage. Gleichheit beweist keine ausreichende Kapazität.

**Weiterführende Analyse:** Für die weiterführende Analyse gelten folgende Schritte und Quellen: `USP_CurrentTempDB`, Internal Contention, Current IO.

### `[monitor].[USP_ServerConfiguration]`

**Leitfrage:** Welche Serveroptionen weichen von Default/Empfehlung ab und welche Werte sind tatsächlich aktiv?

**Technischer Hintergrund:** `sys.configurations` besitzt configured `value` und `value_in_use`, Dynamic/Advanced Flags. Manche Änderungen greifen sofort, andere nach RECONFIGURE oder Restart. Optionen beeinflussen Parallelität, Memory, Security, Remotezugriff und Engineverhalten.

**Datenquellen:** Die Analyse verwendet folgende Datenquellen und Ausführungspfade: `sys.configurations`, `sys.dm_os_sys_info`.

**Zeit- und Scopemodell:** Die zeitliche und fachliche Aussage ist wie folgt begrenzt: Aktueller Konfigurationsstand; einige `value`-Änderungen noch nicht in use.

**Bewertung und Gegenprobe:** Für die Bewertung und Gegenprobe gelten folgende Prüfschritte: Configured/In Use, Is Dynamic, Is Advanced, Version/Edition, Workload und Changegrund gemeinsam lesen. Abweichungen priorisieren, aber nicht automatisch korrigieren.

**Typische Fehlinterpretation:** Default ist nicht immer optimal; bekannte Empfehlung ist nicht universell. Mehrere Optionen interagieren, etwa MAXDOP/Cost Threshold oder Max Memory/OS Reserve.

**Weiterführende Analyse:** Für die weiterführende Analyse gelten folgende Schritte und Quellen: Spezifische Topologie-/Memory-/Securitymodule und kontrolliertes Changeverfahren.

### `[monitor].[USP_TraceFlags]`

**Leitfrage:** Welche globalen oder sessionbezogenen Trace Flags sind aktiv und welche Engineverhaltensänderung ist damit verbunden?

**Technischer Hintergrund:** Trace Flags aktivieren Diagnose- oder Verhaltenspfade auf globaler/sessionbezogener Scope. Manche wurden durch Database Scoped Configurations oder neuere Defaults ersetzt; Supportstatus ist versionsabhängig. Startupparameter können globale Flags früh setzen.

**Datenquellen:** Die Analyse verwendet folgende Datenquellen und Ausführungspfade: Frameworkinterne Orchestrierung; Quellen liegen in Childmodulen.

**Zeit- und Scopemodell:** Die zeitliche und fachliche Aussage ist wie folgt begrenzt: Aktueller Runtimezustand; Sessionflags gelten nur im Kontext, globale bis Deaktivierung/Restart.

**Bewertung und Gegenprobe:** Für die Bewertung und Gegenprobe gelten folgende Prüfschritte: Flagnummer, Scope, Startupbezug, dokumentierter Zweck, Version und aktuelle Notwendigkeit prüfen. Undokumentierte Flags besonders vorsichtig behandeln.

**Typische Fehlinterpretation:** Aktiv heißt nicht, dass jeder Workloadpfad betroffen ist. Ein früher notwendiges Flag kann nach Upgrade redundant oder schädlich sein.

**Weiterführende Analyse:** Für die weiterführende Analyse gelten folgende Schritte und Quellen: `USP_StartupParameters`, Server Configuration und offizielle versionsspezifische Dokumentation.

### `[monitor].[USP_StartupParameters]`

**Leitfrage:** Mit welchen Service-/Engineparametern wurde die Instanz gestartet?

**Technischer Hintergrund:** Startupparameter definieren unter anderem Master Data/Log, Errorlog, Trace Flags und weitere Engineoptionen. Registry-/Service-DMVs liefern konfigurierte Parameter; einige Änderungen benötigen Dienstneustart und können Startfähigkeit beeinflussen.

**Datenquellen:** Die Analyse verwendet folgende Datenquellen und Ausführungspfade: `sys.dm_os_host_info`, `sys.dm_server_registry`.

**Zeit- und Scopemodell:** Die zeitliche und fachliche Aussage ist wie folgt begrenzt: Konfiguration der laufenden Instanz; Wirkung seit letztem Start.

**Bewertung und Gegenprobe:** Für die Bewertung und Gegenprobe gelten folgende Prüfschritte: Parameter, Quelle, Reihenfolge, Pfad-/Flagbedeutung und Abgleich mit Runtime Trace Flags/Errorlog prüfen. Abweichung von Standard kann bewusst sein.

**Typische Fehlinterpretation:** Ein angezeigter Parameter beweist nicht, dass sein Zielpfad gesund oder noch erforderlich ist. Änderungen ohne Recoveryzugang können Instanzstart verhindern.

**Weiterführende Analyse:** Für die weiterführende Analyse gelten folgende Schritte und Quellen: Trace Flags, OS/Filesystem und dokumentiertes Restart-/Rollbackrunbook.

### `[monitor].[USP_OSInformation]`

**Leitfrage:** Welche Betriebssystem-, Host-, Virtualisierungs- und Ressourceninformationen sieht SQL Server?

**Technischer Hintergrund:** Host-/Windows-/Linux-DMVs liefern OS-Version, Hostplattform, Memory/Pagefile, Startzeit und Virtualization/Containerhinweise soweit verfügbar. SQL Server sieht im Gast nicht zwingend Hypervisor-Steal, SAN- oder Hostcontention vollständig.

**Datenquellen:** Die Analyse verwendet folgende Datenquellen und Ausführungspfade: `sys.dm_os_host_info`, `sys.dm_os_process_memory`, `sys.dm_os_sys_memory`, `sys.dm_server_services`.

**Zeit- und Scopemodell:** Die zeitliche und fachliche Aussage ist wie folgt begrenzt: Aktueller Gast-/Instanzkontext; OS-/Engine-Startzeiten können verschieden sein.

**Bewertung und Gegenprobe:** Für die Bewertung und Gegenprobe gelten folgende Prüfschritte: OS/Build Support, VM/Physical, Memory/Commit, Pagefile, Uptime und Instanzbuild korrelieren. Für Performance CPU-, Storage- und Memorytelemetrie außerhalb SQL ergänzen.

**Typische Fehlinterpretation:** Unauffällige Gastwerte schließen Hostengpass nicht aus. Pagefile vorhanden/benutzt ist allein keine SQL-Memorydiagnose.

**Weiterführende Analyse:** Für die weiterführende Analyse gelten folgende Schritte und Quellen: Server CPU/Memory/IO und OS-/Hypervisormonitoring.

### `[monitor].[USP_ServerSecurityConfiguration]`

**Leitfrage:** Welche sicherheitsrelevanten Servereinstellungen und Prinzipal-/Endpointmuster verdienen ein Securityreview?

**Technischer Hintergrund:** Server Principals, Roles und Permissions, Authentication, Endpoints, Service Accounts und Konfigurationsoptionen bilden mehrere Sicherheitsebenen. Metadata Visibility begrenzt die Sicht. Frameworkbefunde sollen die Konfiguration inventarisieren und keine Credentials oder Secrets ausgeben.

**Datenquellen:** Die Analyse verwendet folgende Datenquellen und Ausführungspfade: `sys.configurations`, `sys.dm_server_services`.

**Zeit- und Scopemodell:** Die zeitliche und fachliche Aussage ist wie folgt begrenzt: Aktueller Metadaten-/Konfigurationsstand.

**Bewertung und Gegenprobe:** Verbinden Sie Finding, Scope, Severity und Confidence, betroffene Option oder Rolle sowie die dokumentierte Policy. Prüfen Sie insbesondere `sysadmin`, `CONTROL SERVER`, unsichere Optionen und exponierte Endpoints zusammen mit dem zuständigen Owner und der fachlichen Notwendigkeit.

**Typische Fehlinterpretation:** Technischer Befund ist kein vollständiges Berechtigungsaudit und keine Aussage über organisatorische Genehmigung. Fehlende Sicht darf nicht als fehlende Berechtigung interpretiert werden.

**Weiterführende Analyse:** Für die weiterführende Analyse gelten folgende Schritte und Quellen: Formales Security-/Identityreview, Audit und Change Governance.

### `[monitor].[USP_ServerHealthAnalysis]`

**Leitfrage:** Welche Server-Health-Bereiche sind auffällig und welches Spezialmodul soll als Nächstes laufen?

**Technischer Hintergrund:** Wrapper über CPU, NUMA, Memory, TempDB, Config, Trace Flags, Startup, OS und Security. Er verbindet keine atomare Systemaufnahme; Children können verschiedene Rechte/Quellen haben.

**Datenquellen:** Die Analyse verwendet folgende Datenquellen und Ausführungspfade: Frameworkinterne Orchestrierung; Quellen liegen in Childmodulen.

**Zeit- und Scopemodell:** Die zeitliche und fachliche Aussage ist wie folgt begrenzt: Nicht atomare Folge aktueller Konfigurations-/Runtimeabfragen.

**Bewertung und Gegenprobe:** Für die Bewertung und Gegenprobe gelten folgende Prüfschritte: Childstatus und Partials zuerst, dann Befunde nach Ressource korrelieren. Triagepriorität statt Gesamtgesundheitsscore.

**Typische Fehlinterpretation:** Ein grüner Wrapper beweist keine Lastfreiheit oder Integrität; optionale/gesperrte Children können fehlen.

**Weiterführende Analyse:** Für die weiterführende Analyse gelten folgende Schritte und Quellen: Betroffenes Spezialmodul und Current-State-/Historical-Evidenz.

### `[monitor].[USP_DatabaseIntegrityAnalysis]`

**Leitfrage:** Welche Metadaten weisen auf Integritätsrisiko, veralteten CHECKDB-Nachweis, suspect pages, beschädigte Backups oder offene HADR-Seitenreparatur hin?

**Technischer Hintergrund:** Page Verify CHECKSUM erkennt bestimmte Pageänderungen bei Read; `suspect_pages` speichert erkannte Pageereignisse; DBINFO/Property kann Last Good CHECKDB liefern; Backupsets enthalten checksum/damage flags; HADR Auto Page Repair dokumentiert Reparaturversuche.

**Datenquellen:** Die Analyse verwendet folgende Datenquellen und Ausführungspfade: `master.sys.databases`, `msdb.dbo.backupset`, `msdb.dbo.suspect_pages`, `sys.dm_db_page_info`, `sys.dm_hadr_auto_page_repair`.

**Zeit- und Scopemodell:** Die zeitliche und fachliche Aussage ist wie folgt begrenzt: Historische/aktuelle Metadaten mit unterschiedlicher Retention; kein Live-CHECKDB.

**Bewertung und Gegenprobe:** Priorisieren Sie jede Suspect Page, jedes beschädigte Backup und jede Pending Page Repair hoch. Prüfen Sie Last Good CHECKDB gegen die Policy, die Datenbankgröße sowie die Backup- und Restorestrategie. Berücksichtigen Sie dabei immer `EvidenceLimit`.

**Typische Fehlinterpretation:** `0` negative Einträge beweist keine Integrität. `RESTORE VERIFYONLY` prüft nicht alle Daten und ersetzt weder CHECKDB noch echten Restore.

**Weiterführende Analyse:** Für die weiterführende Analyse gelten folgende Schritte und Quellen: Geplanter CHECKDB, Backup Chain, echter Restoretest und Storage-/Errorlog/XE-Korrelation.

### `[monitor].[USP_DatabaseCapacityAnalysis]`

**Leitfrage:** Wie viel Datei-/Volumeplatz bleibt, wie sind Growth/MaxSize konfiguriert und welche Kapazitätsrisiken sind sichtbar?

**Technischer Hintergrund:** Database Files wachsen innerhalb Volume-/MaxSizegrenzen. Percent Growth erzeugt mit wachsender Datei zunehmend große Schritte; kleine Growthsteps erzeugen häufige Growth Events. Loggrowth/Zero Initialization und Datafile IFI unterscheiden sich.

**Datenquellen:** Die Analyse verwendet folgende Datenquellen und Ausführungspfade: `sys.database_files`, `sys.dm_os_volume_stats`, `sys.sp_executesql`.

**Zeit- und Scopemodell:** Die zeitliche und fachliche Aussage ist wie folgt begrenzt: Aktueller Snapshot. Ohne historische Messpunkte keine Wachstumsrate/Forecast.

**Bewertung und Gegenprobe:** Für die Bewertung und Gegenprobe gelten folgende Prüfschritte: Absolute freie MB und Prozent, Filegröße, Growthtyp/-schritt, MaxSize, Volume Free, Dateityp und geplante Workloadspitzen kombinieren. Autogrowth als Sicherheitsnetz, proaktives Sizing als Betrieb.

**Typische Fehlinterpretation:** Viel freier Platz im File bedeutet nicht freien Volumeplatz; viel Volumeplatz bedeutet nicht passende MaxSize/Growth. Forecast aus einem Snapshot ist Heuristik.

**Weiterführende Analyse:** Für die weiterführende Analyse gelten folgende Schritte und Quellen: Current Log/IO, Backup-/Loadplanung und externes Capacitytrendmonitoring.

### `[monitor].[USP_PerformanceCounters]`

**Leitfrage:** Wie werden SQL-Server-Performance-Counter korrekt als Raw, Ratio, Rate oder Delta interpretiert?

**Technischer Hintergrund:** `sys.dm_os_performance_counters` enthält Counter mit `cntr_type`. Manche sind Momentwerte, manche kumulative Zähler, manche benötigen Basecounter und manche Differenz/Zeit. Instanznamen trennen Total, DB, Buffer Node oder Objektinstanzen.

**Datenquellen:** Die Analyse verwendet folgende Datenquellen und Ausführungspfade: `sys.dm_os_performance_counters`, `sys.dm_os_sys_info`.

**Zeit- und Scopemodell:** Die zeitliche und fachliche Aussage ist wie folgt begrenzt: Aktueller Rawstand oder Frameworksample; Reset typischerweise Engine-Start.

**Bewertung und Gegenprobe:** Prüfen Sie zuerst den Countertyp. Bewerten Sie eine Ratio mit der passenden Base, eine Rate als Delta pro Zeit und kumulative Counter zusammen mit der Uptime. Dokumentieren Sie Instance Name und Units. Verwenden Sie mehrere Counter als zusammenhängende Evidenzkette.

**Typische Fehlinterpretation:** Raw `cntr_value` ist nicht allgemein Prozent oder pro Sekunde. Basecounter aus anderer Instanz/Probe erzeugt falsche Ratio.

**Weiterführende Analyse:** Für die weiterführende Analyse gelten folgende Schritte und Quellen: Server Memory/CPU/IO, Current State und OS-Counter.

### `[monitor].[USP_CriticalEngineEvents]`

**Leitfrage:** Welche kritischen Engineereignisse sind in system_health, Ring Buffers oder Diagnostikquellen erhalten?

**Technischer Hintergrund:** `system_health` erfasst ausgewählte Errors, Scheduler-/Memory-/Connectivity-/Deadlock- und Diagnoseereignisse. Ring Buffers/`sp_server_diagnostics` liefern Component States und begrenzte Historie. Event XML/Datafelder sind versionsabhängig.

**Datenquellen:** Die Analyse verwendet folgende Datenquellen und Ausführungspfade: `sys.fn_xe_file_target_read_file`, `sys.server_event_session_fields`, `sys.server_event_session_targets`, `sys.server_event_sessions`, `sys.sp_server_diagnostics`.

**Zeit- und Scopemodell:** Die zeitliche und fachliche Aussage ist wie folgt begrenzt: Nur erhaltene Ereignisse seit Session-/Engine-/Rollovergrenze; aktueller Diagnostikstatus.

**Bewertung und Gegenprobe:** Für die Bewertung und Gegenprobe gelten folgende Prüfschritte: Eventtyp, Severity/State, Timestamp, Component, Wiederholung und gleichzeitige Errorlog/OS/Clusterereignisse korrelieren. Scheduler non-yielding, Memory Error oder I/O Stall unterschiedlich behandeln.

**Typische Fehlinterpretation:** Keine Zeile ist keine Entwarnung. system_health ist bewusst begrenzt und kann Rollover/Targets verlieren.

**Weiterführende Analyse:** Für die weiterführende Analyse gelten folgende Schritte und Quellen: XE Target Runtime/Read Events, Errorlog, OS/Cluster/Storagediagnostik.

### `[monitor].[USP_InternalContentionAnalysis]`

**Leitfrage:** Welche Latches, Spinlocks, Tasks oder Hot Pages zeigen interne Synchronisationskonkurrenz?

**Technischer Hintergrund:** Latches schützen interne In-Memory-Strukturen/Pages, Spinlocks sehr kurze Critical Sections ohne sofortiges Schlafen. Hohe Konkurrenz erzeugt Waits, Spins/Backoffs oder Schedulerlast. Sampling zweier kumulativer DMVs lokalisiert aktuelle Deltas; Waiting Tasks/Resource Description können Hotspots zeigen.

**Datenquellen:** Die Analyse verwendet folgende Datenquellen und Ausführungspfade: `sys.dm_db_page_info`, `sys.dm_exec_requests`, `sys.dm_os_latch_stats`, `sys.dm_os_spinlock_stats`, `sys.dm_os_sys_info`.

**Zeit- und Scopemodell:** Die zeitliche und fachliche Aussage ist wie folgt begrenzt: Kurzes Sampledelta plus Tasksnapshot; Reset/Restart macht Delta ungültig.

**Bewertung und Gegenprobe:** Für die Bewertung und Gegenprobe gelten folgende Prüfschritte: Delta-Waitzeit/Count, Average, Spin/Backoff, CPU, Resource/Page und wiederholte Samples korrelieren. PAGELATCH an TempDB Allocation unterscheidet sich von B-Tree Last-Page Contention.

**Typische Fehlinterpretation:** Hohe kumulative Latchwerte seit langem Uptime sind kein aktueller Hotspot. Undokumentierte interne Namen/Verhalten können versionsabhängig sein.

**Weiterführende Analyse:** Für die weiterführende Analyse gelten folgende Schritte und Quellen: Current Waits/TempDB/Requests, Page-/Objectauflösung und versionsspezifische Microsoftguidance.

### `[monitor].[USP_BufferPoolAnalysis]`

**Leitfrage:** Wie verteilt sich der Buffer Pool auf Datenbanken, Objekte und Pagearten, und gibt es Hinweise auf Cache-/Memorydruck?

**Technischer Hintergrund:** Buffer Descriptors repräsentieren gecachte 8-KB-Datenseiten. Verteilung nach Database/File/Page/Object kann Working Set zeigen; Memory Clerks und PLE/Lazy Writes ergänzen Drucksignale. Clean Pages sind verwerfbar, Dirty Pages benötigen Flush.

**Datenquellen:** Die Analyse verwendet folgende Datenquellen und Ausführungspfade: `sys.dm_exec_query_resource_semaphores`, `sys.dm_os_buffer_descriptors`, `sys.dm_os_memory_clerks`, `sys.dm_os_process_memory`, `sys.dm_os_sys_memory`.

**Zeit- und Scopemodell:** Die zeitliche und fachliche Aussage ist wie folgt begrenzt: Aktueller Cachebestand; laufend durch Reads, Writes, Checkpoint und Memory Pressure verändert.

**Bewertung und Gegenprobe:** Für die Bewertung und Gegenprobe gelten folgende Prüfschritte: Cached MB/Pages, Dirtyanteil, Datenbank-/Objektanteil, Page Life/Reads, OS-/Processdruck und Workloadgröße kombinieren. Dominanter Cacheanteil kann legitimes Working Set sein.

**Typische Fehlinterpretation:** Bufferanteil ist keine Hit Ratio und häufig gecacht bedeutet nicht automatisch problematisch. Breiter Descriptor-Scan kann selbst CPU/Memory/I/O-Metadatenlast erzeugen.

**Weiterführende Analyse:** Für die weiterführende Analyse gelten folgende Schritte und Quellen: Server Memory, Performance Counters, Query Reads/Plans; Deep-Pfad nur kontrolliert.

### `[monitor].[USP_DiagnosticFindings]`

**Leitfrage:** Welche normalisierten Befunde aus mehreren Spezialmodulen verdienen Priorität und wie stark ist die Evidenz?

**Technischer Hintergrund:** Aggregator ruft Children über definierte JSON-/RAW-Verträge auf und normalisiert Category, Severity, Confidence, Scope, Evidence, EvidenceLimit und Next Check. Er reduziert Detail für Triage und muss Childstatus separat erhalten.

**Datenquellen:** Die Analyse verwendet folgende Datenquellen und Ausführungspfade: `sys.databases`, `sys.sp_executesql`.

**Zeit- und Scopemodell:** Die zeitliche und fachliche Aussage ist wie folgt begrenzt: Mix aus Child-Snapshots, Samples und Historien im selben Lauf.

**Bewertung und Gegenprobe:** Für die Bewertung und Gegenprobe gelten folgende Prüfschritte: Severity und Confidence gemeinsam lesen, SourceModule/Scope zum Detail zurückverfolgen, EvidenceLimit nicht ausblenden. HIGH+LOW verlangt schnelle Validierung, nicht automatische Aktion.

**Typische Fehlinterpretation:** Keine Findings bedeutet nur dann wenig Auffälliges, wenn alle relevanten Children vollständig erfolgreich waren. Normalisierung kann Details bewusst weglassen.

**Weiterführende Analyse:** Für die weiterführende Analyse gelten folgende Schritte und Quellen: SourceModule direkt mit engem Scope aufrufen.

## 3. Offizielle Primärquellen

- [SQL Server thread and task architecture guide](https://learn.microsoft.com/en-us/sql/relational-databases/thread-and-task-architecture-guide?view=sql-server-ver17)
- [Soft-NUMA](https://learn.microsoft.com/sql/database-engine/configure-windows/soft-numa-sql-server)
- [Server memory configuration options](https://learn.microsoft.com/sql/database-engine/configure-windows/server-memory-server-configuration-options)
- [TempDB database](https://learn.microsoft.com/sql/relational-databases/databases/tempdb-database)
- [Server configuration options](https://learn.microsoft.com/sql/database-engine/configure-windows/server-configuration-options-sql-server)
- [DBCC TRACEON](https://learn.microsoft.com/sql/t-sql/database-console-commands/dbcc-traceon-transact-sql)
- [sys.dm_os_host_info](https://learn.microsoft.com/sql/relational-databases/system-dynamic-management-views/sys-dm-os-host-info-transact-sql)
- [DBCC CHECKDB](https://learn.microsoft.com/sql/t-sql/database-console-commands/dbcc-checkdb-transact-sql)
- [suspect_pages](https://learn.microsoft.com/sql/relational-databases/backup-restore/manage-the-suspect-pages-table-sql-server)
- [Database file initialization](https://learn.microsoft.com/sql/relational-databases/databases/database-instant-file-initialization)
- [sys.dm_os_performance_counters](https://learn.microsoft.com/sql/relational-databases/system-dynamic-management-views/sys-dm-os-performance-counters-transact-sql)
- [system_health session](https://learn.microsoft.com/sql/relational-databases/extended-events/use-the-system-health-session)
- [sys.dm_os_latch_stats](https://learn.microsoft.com/sql/relational-databases/system-dynamic-management-views/sys-dm-os-latch-stats-transact-sql)
- [sys.dm_os_buffer_descriptors](https://learn.microsoft.com/sql/relational-databases/system-dynamic-management-views/sys-dm-os-buffer-descriptors-transact-sql)
