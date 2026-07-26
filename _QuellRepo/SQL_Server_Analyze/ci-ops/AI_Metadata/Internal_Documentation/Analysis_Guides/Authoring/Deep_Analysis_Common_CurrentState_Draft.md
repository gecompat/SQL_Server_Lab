# Draft: technische Vertiefung – Common und Current State

**Stand:** 19. Juli 2026
**Status:** integriertes Authoring-Archiv; nicht kanonisch
**Abdeckung:** 14 Procedures aus `01_Common` und `02_CurrentState`

> Die Inhalte sind in die 14 kanonischen Procedure-Seiten integriert. Für Parameter- und RAW-Spaltenverträge gelten die kanonischen Einzel- und Familienseiten.

## 1. Gemeinsames Modell

Current-State-Daten entstehen auf unterschiedlichen Ebenen. Eine Session beschreibt den Sicherheits- und Verbindungskontext. Ein Request ist eine aktuell ausgeführte Anforderung. Ein Request kann in mehrere Tasks zerfallen; jede Task wird von einem Worker auf einem SQLOS-Scheduler ausgeführt. Blocking, Waits, Memory Grants und Transaktionen müssen deshalb über Session-, Request- und Taskidentitäten korreliert werden.

Ein Snapshot beantwortet nur, was beim Lesen sichtbar war. Kumulative Session- oder DMV-Zähler beantworten dagegen, was seit Beginn beziehungsweise Reset akkumuliert wurde. Ein Sample ist die Differenz zweier kumulativer Messungen und ist nur gültig, wenn im Messfenster kein Reset oder Restart stattfand.

## 2. Common

### `[monitor].[USP_CheckAnalyseAccess]`

**Leitfrage:** Erlaubt die Frameworkpolicy dem aktuellen Sicherheitskontext die angeforderte Analyseklasse?

**Technischer Hintergrund:** Das Framework besitzt eine zusätzliche Berechtigungsschiene oberhalb der SQL-Server-Quellberechtigungen. Es prüft Original- und Effektivlogin, sysadmin-Bypass sowie sichtbare Login-/Gruppentokens. Existiert für eine Analyseklasse keine Policy, bleibt sie gemäß Frameworkvertrag offen; existieren Policies, muss eine passende erlaubende Mitgliedschaft sichtbar sein.

**Datenquellen:** Die Analyse verwendet folgende Datenquellen und Ausführungspfade: `sys.login_token`.

**Zeit- und Scopemodell:** Die zeitliche und fachliche Aussage ist wie folgt begrenzt: Momentaufnahme des aktuellen Login- und Execution-Kontexts. Gruppenauflösung kann sich durch Token, Impersonation oder Verzeichniszustand vom erwarteten Benutzerbild unterscheiden.

**Bewertung und Gegenprobe:** Für die Bewertung und Gegenprobe gelten folgende Prüfschritte: `IsAllowed`, Policyanzahl, gematchte Gruppen und AccessReason gemeinsam lesen. Ein Deny bei vorhandener Policy und ohne Match ist erwartetes Policyverhalten; SQL-Quellrechte zu erweitern würde die Frameworksperre nicht fachlich lösen.

**Typische Fehlinterpretation:** `IsAllowed=1` beweist nicht, dass die benötigten DMVs tatsächlich lesbar sind. Umgekehrt ist ein leeres Fachresultset kein Beweis für Policy-Deny.

**Weiterführende Analyse:** Für die weiterführende Analyse gelten folgende Schritte und Quellen: `USP_CheckFrameworkCapabilities` trennt anschließend Feature-, Rechte- und Queryabilityprobleme.

### `[monitor].[USP_CheckFrameworkCapabilities]`

**Leitfrage:** Ist ein Analysepfad auf dieser konkreten Instanz nicht nur theoretisch unterstützt, sondern tatsächlich nutzbar?

**Technischer Hintergrund:** Version, Edition, Featurekonfiguration und formale Permission sind verschiedene Ebenen. Die Procedure führt capability-orientierte Prüfungen aus und kann geschützte Testabfragen dynamisch ausführen. Dadurch wird zwischen `supported`, `enabled`, `permitted`, `queryable` und `usable` unterschieden.

**Datenquellen:** Die Analyse verwendet folgende Datenquellen und Ausführungspfade: `sys.sp_executesql`.

**Zeit- und Scopemodell:** Die zeitliche und fachliche Aussage ist wie folgt begrenzt: Aktueller Umgebungszustand; Ergebnisse können sich nach Konfigurationsänderung, Failover, Datenbankstatuswechsel oder Berechtigungsänderung ändern.

**Bewertung und Gegenprobe:** Für die Bewertung und Gegenprobe gelten folgende Prüfschritte: Die Prüfkette in der dokumentierten Reihenfolge lesen. `HasRequiredPermission=1` bei `IsQueryable=0` weist auf eine zusätzliche Laufzeitgrenze hin. `IsFeatureEnabled=0` kann bei bewusst ungenutztem Feature normal sein.

**Typische Fehlinterpretation:** Capability ist kein Nachweis, dass relevante Daten vorhanden sind. Query Store kann nutzbar, aber leer sein; XE kann abfragbar, aber ohne passende Session sein.

**Weiterführende Analyse:** Für die weiterführende Analyse gelten folgende Schritte und Quellen: Nur Fachmodule starten, deren benötigte Quelle nutzbar ist; bei Partialstatus die jeweilige Datenbank/Quelle gezielt prüfen.

### `[monitor].[USP_PrepareDatabaseCandidates]`

**Leitfrage:** Welche Datenbanken gehören tatsächlich zum Cross-Database-Auftrag und dürfen sicher verarbeitet werden?

**Technischer Hintergrund:** Die Procedure bildet aus exakten Namen oder Pattern einen stabilen Kandidatenscope. Sie liest Datenbankstatus aus Systemkatalogen, berücksichtigt Systemdatenbanken, Zugriffsregeln, Online-/User-Access-Zustand und explizite Auswahl. Sie stellt den Scope über eine Temp-Tabelle für aufrufende Module bereit.

**Datenquellen:** Die Analyse verwendet folgende Datenquellen und Ausführungspfade: `master.sys.databases`, `sys.sp_executesql`.

**Zeit- und Scopemodell:** Die zeitliche und fachliche Aussage ist wie folgt begrenzt: Momentaufnahme der Datenbankliste. Zwischen Kandidatenermittlung und späterer dynamischer Abfrage kann eine Datenbank offline gehen, failovern oder gelöscht werden.

**Bewertung und Gegenprobe:** Für die Bewertung und Gegenprobe gelten folgende Prüfschritte: Explizit angeforderte, aber ausgeschlossene Datenbanken müssen als fehlende Evidenz dokumentiert werden. Eine Analyse über neun von zehn angeforderten Datenbanken ist nicht automatisch eine vollständige Entwarnung.

**Typische Fehlinterpretation:** Pattern und explizite Liste dürfen nicht
stillschweigend als derselbe Auftrag behandelt werden. Ein Partialstatus und
Warnings für nicht verfügbare explizite Datenbanken sind fachlich relevant.

**Weiterführende Analyse:** Für die weiterführende Analyse gelten folgende Schritte und Quellen: Warnings und OUTPUT-Status zusammen mit jedem Cross-Database-Resultset lesen.

### `[monitor].[USP_PrepareNameFilters]`

**Leitfrage:** Wurde eine Namenliste syntaktisch eindeutig und unter der case-sensitiven Frameworksemantik aufbereitet?

**Technischer Hintergrund:** Die Procedure ist ein Schutzbaustein für Filter. Quote-/Bracket-aware Parser verhindern, dass Trenner innerhalb korrekt geklammerter Namen falsch zerlegt werden. Validierte Werte werden in Temp-Strukturen geschrieben; ungültige Eingaben führen kontrolliert zu leerem/ungültigem Filterstatus.

**Datenquellen:** Die Analyse verwendet folgende Datenquellen und Ausführungspfade: Frameworkinterne Orchestrierung/Filterlogik; keine eigenständige Systemquelle.

**Zeit- und Scopemodell:** Die zeitliche und fachliche Aussage ist wie folgt begrenzt: Nur für den aktuellen Aufruf; keine Persistenz.

**Bewertung und Gegenprobe:** Für die Bewertung und Gegenprobe gelten folgende Prüfschritte: Case-Sensitivität, Duplikate, leere Elemente und ungültige Quote-/Bracketstruktur explizit behandeln. Ein absichtlich leerer Filter und ein aufgrund von Fehler geleerter Filter müssen unterscheidbar bleiben.

**Typische Fehlinterpretation:** Eine leere Filtertabelle nach `INVALID_PARAMETER` darf nie als Freigabe für eine ungefilterte breite Analyse dienen.

**Weiterführende Analyse:** Für die weiterführende Analyse gelten folgende Schritte und Quellen: Eingabe korrigieren und das aufrufende Fachmodul erneut starten.

## 3. Current State

### Execution- und Zustandsmodell

Ein Worker läuft entweder auf CPU (`RUNNING`), wartet auf eine Ressource/ein Ereignis (`SUSPENDED`) oder ist nach Freigabe ausführbar und wartet auf Schedulerzeit (`RUNNABLE`). Requestlaufzeit besteht daher aus CPU-Zeit, Ressourcen-/Ereigniswartezeit, Runnable-/Signalzeit und weiteren Koordinationsanteilen. Bei Parallelität summieren mehrere Tasks CPU und Waits; Summen können die Wanduhrzeit überschreiten.

### `[monitor].[USP_CurrentSessions]`

**Leitfrage:** Welche Sessions sind verbunden, welchen Kontext besitzen sie und gibt es inaktive Sessions mit fortwirkendem Zustand?

**Technischer Hintergrund:** `sys.dm_exec_sessions` hält den Sitzungskontext, während `sys.dm_exec_connections` Transport-/Verbindungsdaten und `sys.dm_exec_requests` aktuelle Arbeit ergänzt. Sessionzähler wie CPU oder Reads akkumulieren über die Session; Connection Pools können Sessions lange offen und `sleeping` halten.

**Datenquellen:** Die Analyse verwendet folgende Datenquellen und Ausführungspfade: `master.sys.databases`, `sys.databases`, `sys.dm_exec_connections`, `sys.dm_exec_requests`, `sys.dm_exec_sessions`, `sys.dm_exec_sql_text`, `sys.sp_executesql`.

**Zeit- und Scopemodell:** Die zeitliche und fachliche Aussage ist wie folgt begrenzt: Sessionmomentaufnahme mit kumulativen Zählern seit Sessionbeginn. Session-IDs können nach Ende wiederverwendet werden; Uhrzeit und Login-/Connectionkontext gehören zur Identität.

**Bewertung und Gegenprobe:** Für die Bewertung und Gegenprobe gelten folgende Prüfschritte: `sleeping` ohne offene Transaktion ist häufig normal. `sleeping` mit offener Transaktion, Locks oder wachsendem Logverbrauch ist wesentlich kritischer. Hohe kumulative CPU einer alten Poolsession beweist keine aktuelle Last.

**Typische Fehlinterpretation:** `LastRequestEndTime` ist nicht automatisch Transaktionsende. Clientangaben wie Host/Program sind nicht manipulationssicher.

**Weiterführende Analyse:** Für die weiterführende Analyse gelten folgende Schritte und Quellen: `USP_CurrentTransactions`; bei aktiver Arbeit `USP_CurrentRequests`; bei Auswirkungen `USP_CurrentBlocking`.

### `[monitor].[USP_CurrentRequests]`

**Leitfrage:** Was führt SQL Server jetzt aus und wodurch erklärt sich die bisherige Laufzeit?

**Technischer Hintergrund:** `sys.dm_exec_requests` liefert Status, Command, Laufzeit, CPU, Reads/Writes, Blocking, Wait und Plan-/Statementhandles. Sessions/Connections geben Herkunft, Waiting Tasks zeigen parallele Task-Waits, Memory Grants den Workspace-Memory-Zustand. Statementoffsets schneiden aus dem Batchtext das aktuell ausgeführte Statement.

**Datenquellen:** Die Analyse verwendet folgende Datenquellen und Ausführungspfade: `master.sys.databases`, `sys.databases`, `sys.dm_exec_connections`, `sys.dm_exec_input_buffer`, `sys.dm_exec_query_memory_grants`, `sys.dm_exec_requests`, `sys.dm_exec_sessions`, `sys.dm_exec_sql_text`, `sys.dm_os_waiting_tasks`, `sys.dm_resource_governor_resource_pools`, `sys.dm_resource_governor_workload_groups`, `sys.objects`, `sys.schemas`, `sys.sp_executesql`.

**Zeit- und Scopemodell:** Die zeitliche und fachliche Aussage ist wie folgt begrenzt: Flüchtiger Snapshot; Requestzähler gelten seit Requeststart. Ein Request kann zwischen den einzelnen DMV-Lesungen Status oder Taskbild ändern.

**Bewertung und Gegenprobe:** Für die Bewertung und Gegenprobe gelten folgende Prüfschritte: Elapsed, CPU, Reads, Writes, Row Count, Waits, Blocking und Grant zusammen lesen. Hohe Elapsed bei niedriger CPU legt Warten nahe; hohe CPU plus hohe Reads legt datenintensive Arbeit nahe. Bei mehreren Tasks ist der Request-Hauptwait nicht das vollständige Waitbild.

**Typische Fehlinterpretation:** Ein angezeigter SQL-Text kann Batch statt Ursache sein; der aktive Statementausschnitt ist relevanter. `PercentComplete` existiert nur für unterstützte Commands und ist keine universelle Fortschrittsmessung.

**Weiterführende Analyse:** Für die weiterführende Analyse gelten folgende Schritte und Quellen: Blocking → `USP_CurrentBlocking`; Grants → `USP_CurrentMemoryGrants`; I/O → `USP_CurrentIO`; Plan → `USP_ShowplanAnalysis`.

### `[monitor].[USP_CurrentBlocking]`

**Leitfrage:** Welche Session blockiert welche andere Session, und wo liegt der Root Blocker der Kette?

**Technischer Hintergrund:** Blocking entsteht, wenn ein Task einen Lock oder eine andere blockierende Ressource benötigt, die inkompatibel gehalten wird. Die Procedure korreliert Request-/Taskblocker, Sessions, SQL-Kontext und Locks und rekonstruiert Kanten beziehungsweise Ketten. Ein Root Blocker ist die oberste sichtbare Session ohne weiteren sichtbaren Blocker.

**Datenquellen:** Die Analyse verwendet folgende Datenquellen und Ausführungspfade: `master.sys.databases`, `sys.dm_exec_requests`, `sys.dm_exec_sessions`, `sys.dm_exec_sql_text`, `sys.dm_os_waiting_tasks`, `sys.dm_tran_locks`.

**Zeit- und Scopemodell:** Die zeitliche und fachliche Aussage ist wie folgt begrenzt: Momentaufnahme. Ketten können während der Rekonstruktion wachsen, verschwinden oder ihre Root-Session wechseln.

**Bewertung und Gegenprobe:** Für die Bewertung und Gegenprobe gelten folgende Prüfschritte: Anzahl Opfer, längste Wartezeit, Lock-/Ressourcentyp, offene Transaktion und Zustand des Root Blockers gemeinsam bewerten. Ein aktiv arbeitender Root Blocker kann Fortschritt machen; ein sleeping Root Blocker mit alter Transaktion ist verdächtiger.

**Typische Fehlinterpretation:** Die am längsten wartende Session ist nicht automatisch Ursache. `KILL` eines Opfers entfernt den Root Lock nicht; `KILL` des Root Blockers kann langen Rollback und weitere Last auslösen.

**Weiterführende Analyse:** Für die weiterführende Analyse gelten folgende Schritte und Quellen: `USP_CurrentTransactions`, `USP_CurrentRequests`; für Historie Blocked-Process-/Deadlock-XE.

### `[monitor].[USP_CurrentWaits]`

**Leitfrage:** Auf welche Ressourcen oder Ereignisse warten Tasks aktuell, und welche Waits dominierten Instanz oder Sample?

**Technischer Hintergrund:** Die Procedure kombiniert aktuelle Waiting Tasks mit instanzweiten abgeschlossenen Waits und optionalem Delta. Ressource, Signalzeit, Taskparallelität und Waitfamilie gehören zum technischen Modell.

**Datenquellen:** Die Analyse verwendet folgende Datenquellen und Ausführungspfade: `master.sys.databases`, `sys.dm_exec_requests`, `sys.dm_exec_sessions`, `sys.dm_exec_sql_text`, `sys.dm_os_sys_info`, `sys.dm_os_wait_stats`, `sys.dm_os_waiting_tasks`, `sys.sp_executesql`.

**Zeit- und Scopemodell:** Die zeitliche und fachliche Aussage ist wie folgt begrenzt: Tasksnapshot plus kumulativer Kontext oder gültiges Sampledelta. Current Tasks werden vor der optionalen Samplingpause erfasst.

**Bewertung und Gegenprobe:** Für die Bewertung und Gegenprobe gelten folgende Prüfschritte: Waittyp, Dauer, Anzahl, Resource/Signalanteil, Workloadwirkung und zweite Evidenzquelle kombinieren.

**Typische Fehlinterpretation:** Ein Wait ist keine Root Cause und ein hoher kumulativer Wert kein aktuelles Problem.

**Weiterführende Analyse:** Für die weiterführende Analyse gelten folgende Schritte und Quellen: Vollständige Vertiefung in `Deep_Analysis_Documentation_Draft.md`; je Familie Blocking, I/O, Grants, CPU oder HADR weiterverfolgen.

### `[monitor].[USP_CurrentTransactions]`

**Leitfrage:** Welche offenen Transaktionen halten Zustand, Locks oder Lograum länger als erwartet?

**Technischer Hintergrund:** Transaktions-DMVs verbinden Datenbank-/Sessiontransaktionen mit Beginn, Zustand, Logbytes und Session/Request. Commit oder Rollback beendet die logische Transaktion; bis dahin können Locks und die für Recovery benötigte Logkette erhalten bleiben. Eine alte aktive Transaktion kann Logtruncation verhindern.

**Datenquellen:** Die Analyse verwendet folgende Datenquellen und Ausführungspfade: `master.sys.databases`, `sys.dm_exec_requests`, `sys.dm_exec_sessions`, `sys.dm_exec_sql_text`, `sys.dm_tran_active_transactions`, `sys.dm_tran_database_transactions`, `sys.dm_tran_session_transactions`.

**Zeit- und Scopemodell:** Die zeitliche und fachliche Aussage ist wie folgt begrenzt: Aktueller offener Zustand; Alter seit Transaktionsbeginn. Logbytes und Locks können während der Abfrage weiter wachsen.

**Bewertung und Gegenprobe:** Für die Bewertung und Gegenprobe gelten folgende Prüfschritte: Alter, Sessionstatus, Requestfortschritt, Logverbrauch, Blockingopfer und `log_reuse_wait_desc` korrelieren. Lange Batchloads können legitim sein, benötigen aber Kapazitäts- und Fortschrittskontrolle.

**Typische Fehlinterpretation:** `OpenTransactionCount>0` nennt nicht automatisch die äußerste fachliche Transaktion; implizite, verschachtelte oder verteilte Kontexte beachten. Ein Rollback kann ungefähr so teuer wie die bisherige Änderung sein.

**Weiterführende Analyse:** Für die weiterführende Analyse gelten folgende Schritte und Quellen: `USP_CurrentBlocking`, `USP_CurrentLog`, Request/Anwendungs-Transaktionslogik.

### `[monitor].[USP_CurrentMemoryGrants]`

**Leitfrage:** Welche Queries besitzen oder erwarten Workspace Memory für Sorts, Hashes und ähnliche Operatoren?

**Technischer Hintergrund:** Der Optimizer schätzt den benötigten Query Execution Memory Grant aus Plan, Kardinalität, Row Size und DOP. Ein Request kann erst starten beziehungsweise bestimmte Operatoren ausführen, wenn der Grant verfügbar ist. `sys.dm_exec_query_memory_grants` zeigt angefordert, gewährt, genutzt und ideal sowie wartende Grants.

**Datenquellen:** Die Analyse verwendet folgende Datenquellen und Ausführungspfade: `sys.databases`, `sys.dm_exec_query_memory_grants`, `sys.dm_exec_query_resource_semaphores`, `sys.dm_exec_requests`, `sys.dm_exec_sessions`, `sys.dm_exec_sql_text`, `sys.dm_resource_governor_resource_pools`, `sys.dm_resource_governor_workload_groups`.

**Zeit- und Scopemodell:** Die zeitliche und fachliche Aussage ist wie folgt begrenzt: Flüchtiger Zustand. Wartende Grants verschwinden bei Zuteilung/Abbruch; Nutzung verändert sich während der Ausführung.

**Bewertung und Gegenprobe:** Für die Bewertung und Gegenprobe gelten folgende Prüfschritte: Wartedauer, Requested/Granted/Used/Ideal, DOP, Konkurrenz und Planoperatoren zusammen lesen. Große tatsächlich genutzte Grants können korrekt sein; großer ungenutzter Anteil spricht eher für Übergrant oder Schätzfehler.

**Typische Fehlinterpretation:** `GrantedMemory=0` kann vor Start normal kurz sichtbar sein; ein einzelner großer Grant beweist keinen Servermemorymangel. Server Memory und Query Execution Memory sind verwandte, aber nicht identische Ebenen.

**Weiterführende Analyse:** Für die weiterführende Analyse gelten folgende Schritte und Quellen: `USP_CurrentRequests`, `USP_ServerMemory`, Showplan/Statistics und Query Store Runtime.

### `[monitor].[USP_CurrentTempDB]`

**Leitfrage:** Welche TempDB-Komponente verbraucht Platz, und welche Session/Task treibt den Verbrauch?

**Technischer Hintergrund:** TempDB speichert User Objects, Internal Objects für Sort/Hash/Spool/Worktables, Version Store sowie freie/ungeordnete Bereiche. Datei-Space-DMVs und Session-/Task-Space-Usage besitzen unterschiedliche Aggregation. Version Store wird durch zeilenversionsbasierte Isolation und weitere Enginefeatures erzeugt.

**Datenquellen:** Die Analyse verwendet folgende Datenquellen und Ausführungspfade: `sys.database_files`, `sys.dm_db_session_space_usage`, `sys.dm_exec_sessions`, `sys.sp_executesql`.

**Zeit- und Scopemodell:** Die zeitliche und fachliche Aussage ist wie folgt begrenzt: Aktueller Datei-/Datenbankzustand; Session-/Taskzähler seit Request/Sessionaktivität. Version Store kann nach Transaktionsende verzögert bereinigt werden.

**Bewertung und Gegenprobe:** Für die Bewertung und Gegenprobe gelten folgende Prüfschritte: Zuerst Belegungsart trennen, dann Verbraucher und Wachstum prüfen. Internal Objects plus Spillwarnung führt zum Plan; Version Store plus alte Snapshottransaktion zur Transaktionsanalyse; User Objects zu Tempobjekten.

**Typische Fehlinterpretation:** Hohe Gesamtbelegung oder eine große Datei nennt keine Ursache. Freier Platz innerhalb TempDB und freier Volumeplatz sind verschiedene Größen.

**Weiterführende Analyse:** Für die weiterführende Analyse gelten folgende Schritte und Quellen: `USP_CurrentRequests`, `USP_CurrentTransactions`, `USP_TempDBConfiguration`, Showplan.

### `[monitor].[USP_CurrentIO]`

**Leitfrage:** Wie viele I/O-Operationen und Bytes wurden pro Datei verarbeitet, und wie lange dauerten sie?

**Technischer Hintergrund:** `sys.dm_io_virtual_file_stats` liefert kumulative Read-/Writeanzahl, Bytes und Stalls pro Daten-/Logdatei. Aus Differenzen zweier Messungen entstehen aktuelle IOPS, Durchsatz und Latenz. Dateimetadaten lösen Database/File/Type auf.

**Datenquellen:** Die Analyse verwendet folgende Datenquellen und Ausführungspfade: `master.sys.master_files`, `sys.dm_io_virtual_file_stats`.

**Zeit- und Scopemodell:** Die zeitliche und fachliche Aussage ist wie folgt begrenzt: Kumulativ seit Start/Dateizustand oder Sampledelta. Reset, Restart, Dateiwechsel und sehr kleine Nenner begrenzen Vergleichbarkeit.

**Bewertung und Gegenprobe:** Für die Bewertung und Gegenprobe gelten folgende Prüfschritte: Reads und Writes getrennt bewerten; Latenz immer mit Operationszahl, Bytes und Sampledauer lesen. Datenfiles und Logfiles besitzen unterschiedliche I/O-Muster. Parallel sichtbare PAGEIOLATCH/WRITELOG- und Requestwerte erhöhen die Evidenz.

**Typische Fehlinterpretation:** Eine einzelne Operation mit 500 ms erzeugt 500 ms Durchschnitt, aber keine anhaltende Last. DMV-Stall enthält Queueing aus SQL-Sicht, nicht automatisch reine Geräte-Servicezeit.

**Weiterführende Analyse:** Für die weiterführende Analyse gelten folgende Schritte und Quellen: `USP_CurrentRequests`, `USP_CurrentWaits`, `USP_CurrentLog`; externe OS-/Storage-Telemetrie.

### `[monitor].[USP_CurrentLog]`

**Leitfrage:** Wie voll ist das Transaktionslog, warum kann es nicht wiederverwendet werden und welches Risiko entsteht?

**Technischer Hintergrund:** Das Log ist eine sequenzielle Recoverystruktur aus VLFs. Log Records müssen für Commit gehärtet und für Recovery/Backup/HADR/Replication je nach Konfiguration erhalten werden. Space-Usage, Filemetadaten, VLF-Kontext und `log_reuse_wait_desc` erklären verschiedene Ebenen.

**Datenquellen:** Die Analyse verwendet folgende Datenquellen und Ausführungspfade: `master.sys.databases`, `sys.dm_db_log_info`, `sys.dm_db_log_space_usage`, `sys.dm_db_log_stats`, `sys.dm_tran_persistent_version_store_stats`, `sys.sp_executesql`.

**Zeit- und Scopemodell:** Die zeitliche und fachliche Aussage ist wie folgt begrenzt: Aktueller Space-/Reusezustand; Filegröße und VLFs Metadaten, einzelne Zähler kumulativ. Reuse-Wait kann sich nach Backup/Commit rasch ändern.

**Bewertung und Gegenprobe:** Für die Bewertung und Gegenprobe gelten folgende Prüfschritte: Used Percent, absolute freie MB, Wachstumsoption, Volumeplatz und Reuse-Wait zusammen lesen. `ACTIVE_TRANSACTION`, `LOG_BACKUP`, `AVAILABILITY_REPLICA` oder `REPLICATION` führen zu unterschiedlichen Maßnahmen.

**Typische Fehlinterpretation:** Logvergrößerung beseitigt die Reuse-Ursache nicht. Shrink ist keine dauerhafte Lösung und kann VLF-/Autogrowthprobleme verschärfen.

**Weiterführende Analyse:** Für die weiterführende Analyse gelten folgende Schritte und Quellen: `USP_CurrentTransactions`, Backup-/AG-/Replicationmodule, `USP_CurrentIO` für Logfilelatenz.

### `[monitor].[USP_CurrentOverview]`

**Leitfrage:** Welche Current-State-Symptome verdienen als Erstes eine spezialisierte Analyse?

**Technischer Hintergrund:** Der Orchestrator ruft Childmodule mit definierten Schaltern auf und sammelt Resultsets, JSON-/Statusverträge und Fehlergrenzen. Er erzeugt keine neue einheitliche Messmethode; jedes Child behält sein eigenes Zeitmodell.

**Datenquellen:** Die Analyse verwendet folgende Datenquellen und Ausführungspfade: Frameworkinterne Orchestrierung/Filterlogik; keine eigenständige Systemquelle.

**Zeit- und Scopemodell:** Die zeitliche und fachliche Aussage ist wie folgt begrenzt: Nahe beieinanderliegende, aber nicht atomare Momentaufnahmen; Samplingchildren können den Aufruf verlängern.

**Bewertung und Gegenprobe:** Für die Bewertung und Gegenprobe gelten folgende Prüfschritte: Zuerst Modulstatus und Partialflags, dann nur auffällige Children vertiefen. Korrelation ist möglich, wenn dieselbe Session/DB/Datei in mehreren Children erscheint.

**Typische Fehlinterpretation:** Ein unauffälliger Overview beweist nicht, dass zwischen Childaufrufen kein kurzer Vorfall auftrat. Resultsets dürfen nicht so behandelt werden, als stammten sie aus einer gemeinsamen Transaktion.

**Weiterführende Analyse:** Für die weiterführende Analyse gelten folgende Schritte und Quellen: Betroffenes Childmodul mit engeren Filtern erneut ausführen.

## 4. Offizielle Primärquellen

- [SQL Server thread and task architecture guide](https://learn.microsoft.com/en-us/sql/relational-databases/thread-and-task-architecture-guide?view=sql-server-ver17)
- [sys.dm_exec_sessions](https://learn.microsoft.com/sql/relational-databases/system-dynamic-management-views/sys-dm-exec-sessions-transact-sql)
- [sys.dm_exec_requests](https://learn.microsoft.com/sql/relational-databases/system-dynamic-management-views/sys-dm-exec-requests-transact-sql)
- [sys.dm_os_waiting_tasks](https://learn.microsoft.com/sql/relational-databases/system-dynamic-management-objects/sys-dm-os-waiting-tasks-transact-sql)
- [sys.dm_tran_active_transactions](https://learn.microsoft.com/sql/relational-databases/system-dynamic-management-views/sys-dm-tran-active-transactions-transact-sql)
- [sys.dm_exec_query_memory_grants](https://learn.microsoft.com/sql/relational-databases/system-dynamic-management-views/sys-dm-exec-query-memory-grants-transact-sql)
- [TempDB space use](https://learn.microsoft.com/sql/relational-databases/databases/tempdb-database)
- [sys.dm_io_virtual_file_stats](https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-io-virtual-file-stats-transact-sql?view=sql-server-ver17)
- [Transaction log architecture and management guide](https://learn.microsoft.com/sql/relational-databases/sql-server-transaction-log-architecture-and-management-guide)

## 5. Integrationshinweis

Bei der abgeschlossenen Integration wurden gemeinsame Engineerklärungen zentral verlinkt. Die Einzelpages enthalten die procedurespezifische Datenkette, Formeln, RAW-Spalten, Beispiele und Folgeentscheidungen. Dadurch bleibt die Dokumentation ausführlich, ohne denselben technischen Hintergrund widersprüchlich zu duplizieren.
