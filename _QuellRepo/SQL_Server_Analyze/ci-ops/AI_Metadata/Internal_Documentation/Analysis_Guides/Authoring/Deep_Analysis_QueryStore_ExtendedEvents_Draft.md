# Draft: technische Vertiefung – Query Store und Extended Events

**Stand:** 19. Juli 2026
**Status:** integriertes Authoring-Archiv; nicht kanonisch
**Abdeckung:** 15 Procedures aus `05_QueryStore` und `06_ExtendedEvents`

> Query Store und Extended Events sind historische Quellen mit grundverschiedener Semantik. Query Store aggregiert Query-/Planruntime in Intervallen. Extended Events speichert einzelne konfigurierte Ereignisse in Targets. Retention, Capture, Cleanup, Rollover und partielle Intervalle müssen in jeder Bewertung sichtbar bleiben.

## 1. Query Store

### Persistenz- und Intervallmodell

Query Store ist datenbankbezogen. Querytext, Queryidentität, Plan, Runtime Stats und Wait Stats werden in getrennten Katalogsichten gespeichert. Runtime- und Waitwerte gehören zu `runtime_stats_interval_id`. Ein Analysefenster schneidet häufig Randintervalle; wenn der Frameworkcode überlappende Intervalle vollständig einbezieht, stammen Teile der Werte vor `@VonUtc` oder nach `@BisUtc`. Capture Mode, Größenlimit, Cleanup, Read-only Reason und Replica-Verhalten begrenzen die Daten.

### `[monitor].[USP_QueryStoreStatus]`

**Leitfrage:** Ist Query Store aktiviert, schreibfähig, ausreichend dimensioniert und für den gewünschten Evidenztyp konfiguriert?

**Technischer Hintergrund:** `sys.database_query_store_options` trennt gewünschten und tatsächlichen Zustand, Operation Mode, Capture Mode, Interval Length, Retention, Current/Max Size, Cleanup und Wait Stats Capture. READ_ONLY kann aus administrativer Konfiguration oder internen Gründen wie Größenlimit entstehen.

**Datenquellen:** Die Analyse verwendet folgende Datenquellen und Ausführungspfade: `sys.database_query_store_options`, `sys.sp_executesql`.

**Zeit- und Scopemodell:** Die zeitliche und fachliche Aussage ist wie folgt begrenzt: Aktueller Zustand je ausgewählter Datenbank. Status sagt nichts über bereits gelöschte oder nie erfasste Historie.

**Bewertung und Gegenprobe:** Für die Bewertung und Gegenprobe gelten folgende Prüfschritte: Actual vs Desired State, Readonly Reason, Current/Max Size, Stale Query Threshold, Cleanup und Capture Mode zusammen lesen. Waitanalyse benötigt aktiviertes Wait Capture.

**Typische Fehlinterpretation:** `READ_WRITE` beweist weder Vollständigkeit noch repräsentative Capture-Auswahl. `OFF` zum Analysezeitpunkt erklärt nicht immer, ob frühere Daten noch vorhanden sind.

**Weiterführende Analyse:** Für die weiterführende Analyse gelten folgende Schritte und Quellen: Vor allen Query-Store-Fachanalysen; bei Problemen Konfiguration/Storage und Capturepolicy prüfen.

### `[monitor].[USP_QueryStoreRuntimeStats]`

**Leitfrage:** Welche Query-/Plan-Kombinationen verursachten im gewählten historischen Fenster Ausführungen, Dauer, CPU, I/O, Memory, TempDB oder Loglast?

**Technischer Hintergrund:** Runtime Stats speichern aggregierte Messwerte je Plan, Intervall und Execution Type. Totalwerte entstehen aus Intervallsummen; globale Averagewerte müssen nach Ausführungszahl gewichtet werden, wenn der Code nicht bereits gewichtete Totals verwendet. Query, Plan und Text werden über IDs verbunden, die nur innerhalb der Query-Store-Datenbank eindeutig sind.

**Datenquellen:** Die Analyse verwendet folgende Datenquellen und Ausführungspfade: `sys.database_query_store_options`, `sys.objects`, `sys.query_store_plan`, `sys.query_store_query`, `sys.query_store_query_text`, `sys.query_store_runtime_stats`, `sys.query_store_runtime_stats_interval`, `sys.schemas`, `sys.sp_executesql`.

**Zeit- und Scopemodell:** Die zeitliche und fachliche Aussage ist wie folgt begrenzt: Persistierte, intervalaggregierte Historie innerhalb Retention. Überlappende Randintervalle können vollständig einbezogen sein.

**Bewertung und Gegenprobe:** Für die Bewertung und Gegenprobe gelten folgende Prüfschritte: Total und Average stets mit Execution Count, PlanId, Execution Type und Zeitspanne lesen. Hohe Total-CPU bei niedriger Average-CPU ist eine kumulative Optimierungschance; hohe Average-Duration bei niedriger CPU verlangt Wait-/Blocking-/I/O-Kontext.

**Typische Fehlinterpretation:** Durchschnittswerte verdecken P95/P99, multimodale Parametergruppen und Ausreißer. Query Store Runtime ist keine Storage-Latenzmessung.

**Weiterführende Analyse:** Für die weiterführende Analyse gelten folgende Schritte und Quellen: `USP_QueryStoreWaitStats`, PlanChanges, Regressions und Showplan.

### `[monitor].[USP_QueryStoreWaitStats]`

**Leitfrage:** Welche groben Waitkategorien dominierten historisch je Query-Store-Plan?

**Technischer Hintergrund:** Query Store ordnet konkrete Waittypen Kategorien zu und speichert Total/Avg/Min/Max je Plan, Intervall und Execution Type. Es erfasst Waits während Queryausführung, nicht Compile-Waits. Der Frameworkcode mittelt gespeicherte Intervallmittelwerte ungewichtet und summiert vollständig einbezogene Überlappungsintervalle.

**Datenquellen:** Die Analyse verwendet folgende Datenquellen und Ausführungspfade: `sys.database_query_store_options`, `sys.query_store_plan`, `sys.query_store_query`, `sys.query_store_query_text`, `sys.query_store_runtime_stats_interval`, `sys.query_store_wait_stats`, `sys.sp_executesql`.

**Zeit- und Scopemodell:** Die zeitliche und fachliche Aussage ist wie folgt begrenzt: Persistierte Waitkategorien innerhalb Retention und aktivem Wait Capture; datenbank-/planbezogen.

**Bewertung und Gegenprobe:** Für die Bewertung und Gegenprobe gelten folgende Prüfschritte: Total, Max, Recorded Rows, Execution Type und Runtime-Ausführungen korrelieren. Kategorien priorisieren den Troubleshootingpfad, liefern aber keinen konkreten Blocker oder Wait Resource.

**Typische Fehlinterpretation:** `RecordedRows` sind Messzeilen, keine Waitanzahl. Die Average-Spalte ist kein execution-weighted Gesamtdurchschnitt.

**Weiterführende Analyse:** Für die weiterführende Analyse gelten folgende Schritte und Quellen: Vollständige Vertiefung in `Deep_Analysis_Documentation_Draft.md`; live mit Current Waits/Requests validieren.

### `[monitor].[USP_QueryStorePlanChanges]`

**Leitfrage:** Welche Queries besitzen mehrere gespeicherte Pläne, und wodurch unterscheiden sich deren Lebenszyklus und Compilekontext?

**Technischer Hintergrund:** `sys.query_store_plan` speichert PlanId, Plan Hash, Engine Version, Compatibility, Compilezeiten, IsParallel, Forced-Status und Plan XML. Mehrere PlanIds können strukturell gleichen Plan Hash besitzen; Recompile oder Kontextänderung kann neue Zeilen erzeugen.

**Datenquellen:** Die Analyse verwendet folgende Datenquellen und Ausführungspfade: `sys.database_query_store_options`, `sys.objects`, `sys.query_store_plan`, `sys.query_store_query`, `sys.query_store_query_text`, `sys.schemas`, `sys.sp_executesql`.

**Zeit- und Scopemodell:** Die zeitliche und fachliche Aussage ist wie folgt begrenzt: Persistierter Planbestand innerhalb Query-Store-Retention; Last Execution zeigt Aktivität, nicht dauerhafte Gültigkeit.

**Bewertung und Gegenprobe:** Für die Bewertung und Gegenprobe gelten folgende Prüfschritte: PlanCount, DistinctPlanHashCount, Compile-/Executionzeit, Engine/Compatibility, Forced-Status und Runtimewerte je Plan vergleichen. Ein neuer Plan ist erst bei abweichender Wirkung relevant.

**Typische Fehlinterpretation:** Mehrere Pläne bedeuten nicht automatisch Parameter Sensitivity oder Regression. Ein alter nie mehr ausgeführter Plan kann historisch, aber aktuell irrelevant sein.

**Weiterführende Analyse:** Für die weiterführende Analyse gelten folgende Schritte und Quellen: Runtime Stats je Plan, Regressions, Forced Plans und Showplanvergleich.

### `[monitor].[USP_QueryStoreRegressions]`

**Leitfrage:** Hat sich eine gewählte Metrik zwischen Baseline- und Vergleichsfenster belastbar verschlechtert?

**Technischer Hintergrund:** Die Procedure aggregiert zwei nicht überlappende Zeiträume und vergleicht Duration, CPU, Reads, Writes oder Executions. Prozentänderung teilt die absolute Änderung durch den Baselinewert; Baseline nahe null macht Prozent instabil. Intervalle können Fenstergrenzen überlappen.

**Datenquellen:** Die Analyse verwendet folgende Datenquellen und Ausführungspfade: `sys.database_query_store_options`, `sys.objects`, `sys.query_store_plan`, `sys.query_store_query`, `sys.query_store_query_text`, `sys.query_store_runtime_stats`, `sys.query_store_runtime_stats_interval`, `sys.schemas`, `sys.sp_executesql`.

**Zeit- und Scopemodell:** Die zeitliche und fachliche Aussage ist wie folgt begrenzt: Zwei persistierte Query-Store-Fenster innerhalb Retention; Defaultvergleich und abgeleitete Baseline müssen im Wrapperkontext dokumentiert sein.

**Bewertung und Gegenprobe:** Für die Bewertung und Gegenprobe gelten folgende Prüfschritte: Baseline/Comparison Executions, PlanCount, absolute Änderung, Prozent, Datenvolumen und Workloadmix gemeinsam lesen. Mindestexecutionzahl passend zur Workload erhöhen.

**Typische Fehlinterpretation:** 900 Prozent bei je einer Ausführung ist schwache Evidenz. Geänderte Parameter-/Datenmengen können Effizienz- statt Planregression vortäuschen.

**Weiterführende Analyse:** Für die weiterführende Analyse gelten folgende Schritte und Quellen: PlanChanges, WaitStats, RuntimeStats und Showplan; kein reflexartiges Planforcing.

### `[monitor].[USP_QueryStoreForcedPlans]`

**Leitfrage:** Welche Pläne werden erzwungen, funktionieren sie technisch und sind sie noch betrieblich begründet?

**Technischer Hintergrund:** Query Store Plan Forcing beeinflusst die Planwahl über gespeicherte Planrepräsentation. Metadaten enthalten Forcing Type, Failure Count/Reason, Compile-/Executionzeit und Version. Schema-/Index-/Engineänderungen können Forcing verhindern oder seine Qualität verändern.

**Datenquellen:** Die Analyse verwendet folgende Datenquellen und Ausführungspfade: `sys.database_query_store_options`, `sys.objects`, `sys.query_store_plan`, `sys.query_store_query`, `sys.query_store_query_text`, `sys.schemas`, `sys.sp_executesql`.

**Zeit- und Scopemodell:** Die zeitliche und fachliche Aussage ist auf den aktuellen Forcingstatus und den persistierten Planlebenszyklus begrenzt.

**Bewertung und Gegenprobe:** Für die Bewertung und Gegenprobe gelten folgende Prüfschritte: Fehler, letzte Nutzung, Runtime im Vergleich zu Alternativen, Engine-/Compatibilitywechsel und Owner/Reviewdatum prüfen. Stabilität kann wichtiger als minimaler Durchschnitt sein.

**Typische Fehlinterpretation:** `IsForcedPlan=1` beweist nicht, dass der Plan aktuell benutzt oder optimal ist. `0` Fehler beweist nur technischen Erfolg, nicht fachlichen Nutzen.

**Weiterführende Analyse:** Für die weiterführende Analyse gelten folgende Schritte und Quellen: Runtime/Regressions/PlanChanges; Änderung nur mit Rollback- und Monitoringplan.

### `[monitor].[USP_QueryStoreHints]`

**Leitfrage:** Welche Query Store Hints greifen auf Queries ein, und schlagen sie fehl oder überdecken sie inzwischen bessere Optimizerentscheidungen?

**Technischer Hintergrund:** Query Store Hints hängen an QueryId und injizieren unterstützte Queryoptionen ohne Textänderung. Source, Hinttext, Failure Reason/Count und Replica Group liefern Governance-/Fehlerkontext. Verfügbarkeit ist versionsabhängig.

**Datenquellen:** Die Analyse verwendet folgende Datenquellen und Ausführungspfade: `sys.query_store_query`, `sys.query_store_query_hints`, `sys.query_store_query_text`, `sys.sp_executesql`.

**Zeit- und Scopemodell:** Die zeitliche und fachliche Aussage ist wie folgt begrenzt: Aktueller persistierter Hintbestand; QueryId ist datenbanklokal.

**Bewertung und Gegenprobe:** Für die Bewertung und Gegenprobe gelten folgende Prüfschritte: Hint, Zielquery, Failure Count, letzte Runtime, Planveränderung, Version/Compatibility und Begründung korrelieren. Jede Intervention benötigt Owner, Reviewdatum und Rücknahmepfad.

**Typische Fehlinterpretation:** Fehlerfrei bedeutet nicht sinnvoll. Nach Upgrade kann ein alter Hint Adaptive/IQP-Verbesserungen verhindern.

**Weiterführende Analyse:** Für die weiterführende Analyse gelten folgende Schritte und Quellen: RuntimeStats, Regressions, PlanChanges und Change-Dokumentation.

### `[monitor].[USP_QueryStoreAnalysis]`

**Leitfrage:** Welche Query-Store-Perspektiven sollen kontrolliert in einem Lauf ausgeführt werden?

**Technischer Hintergrund:** Der Wrapper orchestriert Status, Runtime, Waits, PlanChanges, Regressions, Forced Plans, Hints und IQP. Er übergibt gemeinsame Datenbankscope-/Zeitparameter, aber einzelne Children interpretieren Fenster unterschiedlich.

**Datenquellen:** Die Analyse verwendet folgende Datenquellen und Ausführungspfade: Frameworkinterne Orchestrierung; Quellen liegen in Childmodulen.

**Zeit- und Scopemodell:** Die zeitliche und fachliche Aussage ist wie folgt begrenzt: Nicht atomare Folge persistierter Queries; Childstatus je Datenbank.

**Bewertung und Gegenprobe:** Für die Bewertung und Gegenprobe gelten folgende Prüfschritte: Status zuerst; dann Runtime priorisieren und nur bei Bedarf Wait/Plan/Regression/Intervention vertiefen. Deep-Optionen, Plan XML und viele Datenbanken erhöhen Kosten.

**Typische Fehlinterpretation:** Ein Wrapperfenster kann für Regression als Comparison Window verwendet werden, während Baseline davor abgeleitet wird. Resultsets nicht ohne Childnamen/-status zusammenführen.

**Weiterführende Analyse:** Für die weiterführende Analyse gelten folgende Schritte und Quellen: Betroffenes Child gezielt erneut ausführen.

### `[monitor].[USP_IntelligentQueryProcessingAnalysis]`

**Leitfrage:** Welche IQP-Funktionen sind technisch möglich, konfiguriert und durch sichtbare Query-/Planfeedbacksignale belegt?

**Technischer Hintergrund:** IQP umfasst unter anderem PSP, OPPO, Memory Grant Feedback, DOP/CE Feedback, Adaptive Joins, Deferred Compilation und weitere versions-/compatibilityabhängige Features. Database Scoped Configurations und Query-Store-basierte Feedbacks sind getrennte Ebenen.

**Datenquellen:** Die Analyse verwendet folgende Datenquellen und Ausführungspfade: `sys.database_automatic_tuning_options`, `sys.database_query_store_options`, `sys.database_scoped_configurations`, `sys.databases`, `sys.dm_db_tuning_recommendations`, `sys.query_store_plan_feedback`, `sys.query_store_query_variant`, `sys.sp_executesql`.

**Zeit- und Scopemodell:** Die zeitliche und fachliche Aussage ist wie folgt begrenzt: Aktueller Version-/Compatibility-/Configurationzustand plus persistierte, sichtbare Feedback-/Variantenevidenz.

**Bewertung und Gegenprobe:** Für die Bewertung und Gegenprobe gelten folgende Prüfschritte: `Eligible`, Configuration Value, Query Store State und Evidence Count trennen. Ein Signal führt zur konkreten Query-/Plananalyse, nicht zur pauschalen Aktivierung/Deaktivierung.

**Typische Fehlinterpretation:** `Eligible=1` ist kein Wirksamkeitsbeweis; `EvidenceCount=0` beweist weder fehlendes Problem noch Featureversagen.

**Weiterführende Analyse:** Für die weiterführende Analyse gelten folgende Schritte und Quellen: Query Store Runtime/PlanChanges, Showplan und konkrete Parameterworkload.

## 2. Extended Events

### Erfassungsmodell

Eine XE-Session definiert Events, optionale Actions, Predicates und Targets. Die Katalogsichten zeigen Konfiguration; Runtime-DMVs zeigen nur gestartete Sessions. `ring_buffer` ist speicherbegrenzt, `event_file` rotiert nach Dateigröße/-anzahl. Events können durch Retention Mode oder Druck verloren gehen. Ein Reader sieht nur, was erfasst, behalten und zugreifbar ist.

### `[monitor].[USP_ExtendedEventsSessions]`

**Leitfrage:** Welche XE-Sessions existieren, laufen sie, welche Events/Actions/Predicates und Targets besitzen sie?

**Technischer Hintergrund:** Katalogsichten für Sessions, Events, Actions, Fields und Targets bilden Definitionen; Runtime-DMVs liefern gestartete Sessions und Targetdaten. Eventname allein reicht nicht, wenn für Analyse notwendige Actions wie SQL Text, DatabaseId oder SessionId fehlen.

**Datenquellen:** Die Analyse verwendet folgende Datenquellen und Ausführungspfade: `master.sys.databases`, `sys.dm_xe_sessions`, `sys.server_event_session_actions`, `sys.server_event_session_events`, `sys.server_event_session_fields`, `sys.server_event_session_targets`, `sys.server_event_sessions`, `sys.sp_executesql`.

**Zeit- und Scopemodell:** Die zeitliche und fachliche Aussage ist wie folgt begrenzt: Aktuelle Konfiguration plus Runtimezustand; Serverstart und Sessionstart beeinflussen Targetinhalt.

**Bewertung und Gegenprobe:** Für die Bewertung und Gegenprobe gelten folgende Prüfschritte: Definition und Runtime verbinden: Session vorhanden/läuft, Event enthalten, Predicate nicht zu eng, Actions ausreichend, Target erreichbar. Startup State ist nur Startverhalten.

**Typische Fehlinterpretation:** Eine laufende Session beweist keine vollständige Erfassung. Eine konfigurierte, aber gestoppte Session besitzt möglicherweise alte Targetdaten.

**Weiterführende Analyse:** Für die weiterführende Analyse gelten folgende Schritte und Quellen: `USP_ExtendedEventsTargetRuntime` und anschließend Eventreader.

### `[monitor].[USP_ExtendedEventsReadEvents]`

**Leitfrage:** Welche einzelnen XE-Ereignisse sind im Ring Buffer oder Event File erhalten und erfüllen die Filter?

**Technischer Hintergrund:** `sys.fn_xe_file_target_read_file` liest Event-File-Fragmente; Ring-Buffer-XML stammt aus Runtime-Targetdaten. Event XML enthält Timestamp, Datafelder und Actions mit eventabhängiger Struktur. Parser müssen fehlende Felder tolerieren.

**Datenquellen:** Die Analyse verwendet folgende Datenquellen und Ausführungspfade: `master.sys.databases`, `sys.dm_xe_session_targets`, `sys.dm_xe_sessions`, `sys.fn_xe_file_target_read_file`, `sys.server_event_session_fields`, `sys.server_event_session_targets`, `sys.server_event_sessions`, `sys.sp_executesql`.

**Zeit- und Scopemodell:** Die zeitliche und fachliche Aussage ist wie folgt begrenzt: Einzelereignisse innerhalb erhaltener Targetretention. Event-File-Wildcards, Rollover und UTC-Zeit sind relevant.

**Bewertung und Gegenprobe:** Für die Bewertung und Gegenprobe gelten folgende Prüfschritte: Eventname, Timestamp, Session/Target, Sequence/Datei, Data/Actions und Parsewarnungen lesen. Filter erst nach sicherem Scope anwenden, um falsche Leere zu erkennen.

**Typische Fehlinterpretation:** Keine Zeile bedeutet nicht kein Ereignis: Session/Event/Action, Predicate, Startzeit, Rollover, Drop und Dateizugriff prüfen.

**Weiterführende Analyse:** Für die weiterführende Analyse gelten folgende Schritte und Quellen: Spezialisierte Deadlock-/Blocked-Process-Procedure oder manuelle XML-Vertiefung.

### `[monitor].[USP_ExtendedEventsDeadlocks]`

**Leitfrage:** Welche Sessions/Prozesse bildeten einen Deadlockzyklus, welches Opfer wurde gewählt und welche Ressourcen/Kanten waren beteiligt?

**Technischer Hintergrund:** Der Lock Monitor erkennt einen Zyklus, wählt anhand Deadlock Priority und Rollbackkosten ein Opfer und erzeugt einen Deadlockgraph. XML enthält Victim List, Process List und Resource List mit Owner-/Waiter-Kanten.

**Datenquellen:** Die Analyse verwendet folgende Datenquellen und Ausführungspfade: `sys.dm_xe_session_targets`, `sys.dm_xe_sessions`, `sys.fn_xe_file_target_read_file`, `sys.server_event_session_fields`, `sys.server_event_session_targets`, `sys.server_event_sessions`.

**Zeit- und Scopemodell:** Die zeitliche und fachliche Aussage ist wie folgt begrenzt: Einzelne historische Deadlockereignisse soweit im Target erhalten.

**Bewertung und Gegenprobe:** Für die Bewertung und Gegenprobe gelten folgende Prüfschritte: Zyklus vollständig lesen: Opfer ist nicht automatisch Verursacher. Zugriffsreihenfolge, Lockmodi, Isolation, Indexzugriff, Transaktionsscope und wiederkehrende Query-/Objektmuster bewerten.

**Typische Fehlinterpretation:** Nur SQL-Text des Opfers zu optimieren kann den Zyklus unverändert lassen. Blocking ohne Zyklus erscheint nicht als Deadlock.

**Weiterführende Analyse:** Für die weiterführende Analyse gelten folgende Schritte und Quellen: Showplan/Indexanalyse, Anwendungstransaktionsreihenfolge, wiederholte Graphen gruppieren.

### `[monitor].[USP_ExtendedEventsBlockedProcesses]`

**Leitfrage:** Welche Blockings überschritten den konfigurierten Threshold und wurden als Reports erfasst?

**Technischer Hintergrund:** `blocked_process_report` entsteht nur bei positivem Blocked Process Threshold und passender XE-Erfassung. XML enthält Blocked/Blocking Process, Waitresource, Lockmode und SQL-/Inputbufferkontext zum Reportzeitpunkt. Lange Blockings können mehrere Reports erzeugen.

**Datenquellen:** Die Analyse verwendet folgende Datenquellen und Ausführungspfade: `sys.configurations`, `sys.dm_xe_session_targets`, `sys.dm_xe_sessions`, `sys.fn_xe_file_target_read_file`, `sys.server_event_session_events`, `sys.server_event_session_fields`, `sys.server_event_session_targets`, `sys.server_event_sessions`.

**Zeit- und Scopemodell:** Die zeitliche und fachliche Aussage ist wie folgt begrenzt: Historische Thresholdereignisse während aktiver Capture; keine lückenlose Lockhistorie.

**Bewertung und Gegenprobe:** Für die Bewertung und Gegenprobe gelten folgende Prüfschritte: Dauer/Anzahl, Rootblocker, offene Transaktion, Ressourcenmuster und wiederholte Reports derselben Kette korrelieren. Mehrere Reports nicht ungeprüft als verschiedene Vorfälle zählen.

**Typische Fehlinterpretation:** Blocking unter Threshold, vor Sessionstart oder nach Rollover fehlt. Reportzeit ist nicht zwingend Beginn/Ende der Blockierung.

**Weiterführende Analyse:** Für die weiterführende Analyse gelten folgende Schritte und Quellen: Current Blocking/Transactions bei Reproduktion; Deadlockanalyse bei Zyklen.

### `[monitor].[USP_ExtendedEventsTargetRuntime]`

**Leitfrage:** Verliert, begrenzt oder rotiert das Target Ereignisse, und ist es für die gewünschte Historie geeignet?

**Technischer Hintergrund:** Runtime-DMVs liefern Targettyp/-daten, Buffer-/Memory-/Eventcounter und je Version Drop-/Dispatchinformationen. Event File Konfiguration bestimmt Dateigröße/Rollover; Ring Buffer hat XML-/Memorygrenzen.

**Datenquellen:** Die Analyse verwendet folgende Datenquellen und Ausführungspfade: `master.sys.databases`, `sys.dm_xe_session_targets`, `sys.dm_xe_sessions`, `sys.sp_executesql`.

**Zeit- und Scopemodell:** Die zeitliche und fachliche Aussage ist wie folgt begrenzt: Aktueller Runtimezustand und Targetinhalt seit Sessionstart beziehungsweise Rollover.

**Bewertung und Gegenprobe:** Für die Bewertung und Gegenprobe gelten folgende Prüfschritte: Dropped Events/Buffers, Memory, File/Ring-Buffer-Auslastung, Dispatch Latency, Retention Mode und Eventrate zusammen lesen. Target muss zur Ereignisrate passen.

**Typische Fehlinterpretation:** `0 Drops` beweist keine ausreichende historische Retention; sauberes Rollover kann alte Ereignisse ohne Dropindikator entfernen.

**Weiterführende Analyse:** Für die weiterführende Analyse gelten folgende Schritte und Quellen: Sessionkonfiguration anpassen, externe Dateiretention/Monitoring und Eventreader validieren.

### `[monitor].[USP_ExtendedEventsAnalysis]`

**Leitfrage:** Welche XE-Konfigurations-, Runtime- und Ereignisperspektiven sollen gemeinsam geprüft werden?

**Technischer Hintergrund:** Der Wrapper ruft Sessions, allgemeine Events, Deadlocks, Blocked Processes und Target Runtime auf. Eventlesen kann Datei-I/O und XML-Parsing verursachen; Filter/MaxRows begrenzen den Pfad.

**Datenquellen:** Die Analyse verwendet folgende Datenquellen und Ausführungspfade: Frameworkinterne Orchestrierung; Quellen liegen in Childmodulen.

**Zeit- und Scopemodell:** Die zeitliche und fachliche Aussage ist wie folgt begrenzt: Nicht atomarer Mix aus aktuellem Zustand und Targethistorie.

**Bewertung und Gegenprobe:** Für die Bewertung und Gegenprobe gelten folgende Prüfschritte: Zuerst Session/Targetstatus, erst danach leere/gefüllte Ereignisresultsets bewerten. Spezialevents nach Triage separat vertiefen.

**Typische Fehlinterpretation:** Ein leeres Gesamtbild kann durch deaktivierte Session oder Retention entstehen und ist keine Systemgesundheitsaussage.

**Weiterführende Analyse:** Für die weiterführende Analyse gelten folgende Schritte und Quellen: Child gezielt mit Session, Zeitraum, Eventname und begrenzten Dateien erneut ausführen.

## 3. Offizielle Primärquellen

- [Monitor performance by using the Query Store](https://learn.microsoft.com/sql/relational-databases/performance/monitoring-performance-by-using-the-query-store)
- [sys.database_query_store_options](https://learn.microsoft.com/sql/relational-databases/system-catalog-views/sys-database-query-store-options-transact-sql)
- [sys.query_store_runtime_stats](https://learn.microsoft.com/sql/relational-databases/system-catalog-views/sys-query-store-runtime-stats-transact-sql)
- [sys.query_store_wait_stats](https://learn.microsoft.com/sql/relational-databases/system-catalog-views/sys-query-store-wait-stats-transact-sql)
- [Query Store hints](https://learn.microsoft.com/sql/relational-databases/performance/query-store-hints)
- [Intelligent Query Processing](https://learn.microsoft.com/sql/relational-databases/performance/intelligent-query-processing)
- [Extended Events overview](https://learn.microsoft.com/sql/relational-databases/extended-events/extended-events)
- [Extended Events targets](https://learn.microsoft.com/sql/relational-databases/extended-events/targets-for-extended-events-in-sql-server)
- [sys.fn_xe_file_target_read_file](https://learn.microsoft.com/sql/relational-databases/system-functions/sys-fn-xe-file-target-read-file-transact-sql)
- [SQL Server deadlocks guide](https://learn.microsoft.com/sql/relational-databases/sql-server-deadlocks-guide)
- [blocked process threshold](https://learn.microsoft.com/sql/database-engine/configure-windows/blocked-process-threshold-server-configuration-option)
