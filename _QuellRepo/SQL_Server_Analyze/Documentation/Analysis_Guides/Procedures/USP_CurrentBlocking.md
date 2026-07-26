# [monitor].[USP_CurrentBlocking]

**Bereich:** Current State<br>
**Zweck:** Rekonstruiert aktuelle Blockingkanten und -ketten bis zum Root Blocker und übersetzt technische Wait-/Lockressourcen in den sichtbaren Datenbank-, Objekt-, Index-, Partitions- oder Seitenkontext.<br>
**Beobachtungsart:** Snapshot<br>
**Kostenklasse:** LOW–HIGH_OPT_IN

## Entscheidungsfrage und Einsatz

Die Procedure beantwortet die Betriebsfrage: **Welche Session blockiert welche andere Session, und wo liegt der Root Blocker der Kette?** Sie unterstützt die Entscheidung, ob das aktuelle Symptom im Erfassungsmoment sichtbar ist und welcher engere Live-, Verlaufs- oder Planpfad als Nächstes sinnvoll ist.

## Nicht beantwortete Fragen

Die Procedure beantwortet keine lückenlose Historie und allein aus einem Snapshot weder Dauerhäufigkeit noch Root Cause oder zukünftige Entwicklung. Der Zeitvertrag ist im Abschnitt „Zeit- und Scope-Modell“ konkretisiert. Ein Einzelwert gilt daher nur für diesen Scope und Zeitpunkt; er belegt weder eine Ursache noch eine Entwicklung.

## Sicherer Einstieg

```sql
EXEC [monitor].[USP_CurrentBlocking]
      @MinWaitMs = 1000,
      @BlockingObjektTiefe = 'STANDARD',
      @ResultSetArt = 'CONSOLE';
```

`STANDARD` ist der ressourcenschonende Default. Die Procedure dedupliziert ausschließlich Ressourcen bereits erkannter Blockingketten und löst höchstens `@MaxObjektAufloesungen` Kandidaten auf.

Verwenden Sie für einen vollständigen Lockkontext folgenden Aufruf:

```sql
EXEC [monitor].[USP_CurrentBlocking]
      @MinWaitMs = 1000,
      @BlockingObjektTiefe = 'DEEP',
      @MaxObjektAufloesungen = 500,
      @HighImpactConfirmed = 1,
      @ResultSetArt = 'RAW';
```

`DEEP` aktiviert zusätzlich `sys.dm_tran_locks` für die beteiligten Sessions und ist über `LOCKS_DEEP` gruppen- und bestätigungsgeschützt.

Tool-Hintergrundabfragen als blockiertes Blatt sind standardmäßig
ausgeblendet. `@ToolHintergrundabfragenEinbeziehen = 1` zeigt auch diese Ketten.
Ein Tool als Zwischen- oder Root-Blocker einer normalen Abfrage bleibt dagegen
immer sichtbar; die normale Kette wird nicht abgeschnitten.

Alle `Example*`-Werte im Aufruf sind synthetisch.

## Resultsets und Leserichtung

Der typisierte TABLE-Vertrag registriert `blockingChains`. Status, Scope und Warnings sind vor den Fachergebnissen zu lesen. CONSOLE dient der interaktiven Triage; RAW und JSON erhalten den technischen Kontext, während TABLE nur die ausdrücklich benannten stabilen Resultsets schreibt. Resultsets mit unterschiedlicher Zeilengranularität dürfen nicht ungeprüft vereinigt oder summiert werden.

Im Overview stammen Sessions, Requests, Connections, Waiting Tasks und
deduplizierter SQL-Text aus dessen gemeinsamem Aufrufsnapshot. Lock- und
Objektauflösung bleiben kandidatenbezogene Childquellen. Ein direkter Aufruf
liest alle benötigten Quellen frisch.

## Eine Zeile bedeutet

Im Kettenresultset beschreibt eine Zeile eine sichtbare Blockingbeziehung mit ihrem Root Blocker. `BlockingResourceName` ist die bestmögliche Übersetzung der weiterhin unverändert ausgegebenen `WaitResource`. Lockdetails besitzen eine eigene Granularität.

Das additive Ketten- und JSON-Schema trägt Version `3`. `BlockingChain` zeigt
die komplette Leserichtung bis zum äußersten Blocker. Die `RootBlocker*`-
Spalten ergänzen Login, Host, Programm, Session-/Requeststatus, offene
Transaktionen und letzte Requestzeiten. `RootBlockerStatementSource` zeigt, ob
der Text aus einem aktiven Request (`ACTIVE_REQUEST`) oder bei einem schlafenden
Root Blocker aus `most_recent_sql_handle` der Verbindung
(`MOST_RECENT_CONNECTION`) stammt. `UNAVAILABLE` und `NOT_REQUESTED` verhindern,
dass ein fehlender beziehungsweise nicht angeforderter Text als fachlicher
Befund fehlinterpretiert wird.

## So lesen

Lesen Sie zuerst `BlockingResourceResolutionStatus`:

- `RESOLVED`: ein fachlicher Name oder eine eindeutig klassifizierte Ressource wurde ermittelt;
- `PARTIAL`: Typ beziehungsweise Datenbank ist bekannt, eine tiefere Zuordnung war nicht möglich;
- `RAW_ONLY`: interne oder versionsabhängige Ressource ohne sichere Namensübersetzung;
- `SKIPPED_LIMIT`: Rohwert vorhanden, aber Kandidatenlimit erreicht;
- `SKIPPED`: Auflösung mit `NONE` deaktiviert;
- `TIMEOUT`: ausschließlich die Anreicherung dieses Kandidaten traf auf einen Lock;
- `DENIED_PERMISSION` oder `ERROR_HANDLED`: ausschließlich diese Anreicherung war nicht lesbar beziehungsweise schlug kontrolliert fehl;
- `INVALID_FORMAT` oder `EMPTY`: Quelle war nicht interpretierbar beziehungsweise leer.

Vergleichen Sie danach `BlockingChain`, Waitzeit, `BlockingResourceName`, Aktivität und Transaktionszustand des Root Blockers. `BlockingOwnerType` kennzeichnet neben Sessions auch die SQL-Server-Sonderblocker `ORPHAN_DTC`, `DEFERRED_RECOVERY`, `LATCH_OWNER_TRANSIENT` und `LATCH_OWNER_UNTRACKED`. Ein `NULL`-Root-Requeststatus ist bei einer sleeping Root-Session möglich und kein Beweis für fehlende Blockerwirkung.

## Warum kann das problematisch sein?

Viele Opfer können von einer einzelnen Root-Session abhängen. Das Beenden eines Opfers beseitigt die gehaltene Ressource nicht.

## Wann ist es kein Problem?

Kurze Lockwartezeiten gehören zur transaktionalen Konsistenz. Kritischer sind wachsende, wiederkehrende Ketten und SLA-Auswirkungen.

## Beispiele und Gegenbeispiele

**Synthetischer Problemfall (`Example*`):** Zehn Sessions warten zwei Minuten auf eine sleeping Session mit offener Transaktion: starke Root-Blocker-Evidenz. Mit `USP_CurrentTransactions` und `USP_CurrentRequests` prüfen; erst danach betriebliche Eingriffe erwägen.

**Ähnlich aussehender Gegenfall:** Kurze Lockwartezeiten gehören zur transaktionalen Konsistenz. Kritischer sind wachsende, wiederkehrende Ketten und SLA-Auswirkungen. Der gleiche Einzelwert kann deshalb bei `ExampleDb` ohne Nutzerauswirkung unkritisch sein, während er bei zeitgleicher SLA-Verletzung eine Vertiefung rechtfertigt.

## Leere oder partielle Ausgabe

Bei Live-DMVs kann der Zustand bereits beendet sein, bevor die Quelle gelesen wird. Eine leere Menge ist deshalb höchstens 'jetzt nicht sichtbar', nicht 'trat nicht auf'.

Für `USP_CurrentBlocking` gilt zusätzlich: **keine Zeile** bedeutet, dass im sichtbaren und gefilterten Scope kein ausgabefähiger Datensatz entstand. **0** ist ein gemessener Nullwert nur dann, wenn die Quellspalte tatsächlich verfügbar war. **NULL** bedeutet unbekannt, nicht anwendbar oder nicht auflösbar. **PARTIAL/Warning** bedeutet, dass mindestens eine Teilquelle, Datenbank oder Detailstufe fehlt. Ein Limit kann eine nichtleere Quelle vollständig aus dem sichtbaren Ausschnitt verdrängen.

## Eigenlast und Grenzen

**Quellcode-Hinweis zur Eigenlast:** Der Standardpfad besitzt eine geringe Eigenlast. `sys.dm_tran_locks` wird nur bei ausdrücklicher Anforderung und nur für beteiligte Sessions gelesen.

| Dimension | Aussage für diese Procedure |
|---|---|
| Kostenklasse | LOW–HIGH_OPT_IN |
| Standardpfad | Gefilterter CONSOLE-Snapshot ohne breite Text- oder Lockdetails; gewöhnlich kurze Laufzeit. |
| Teuerster Pfad | `@MitLockDetails = 1` bei vielen beteiligten Sessions; erst dann wird `sys.dm_tran_locks` für den Kettenscope gelesen. |
| Haupttreiber | Zahl aktuell blockierter Requests/Waiting Tasks und die daraus rekonstruierten Kanten/Ketten. Sessionfilter und Mindestwait verkleinern Kandidaten; SQL-Text-/Input-Buffer-Auflösung verbreitert jede behaltene Session. |
| Skalierung | Laufzeit und CPU wachsen mit dem Haupttreiber. Sortierung/Aggregation erhöht Speicher- und gegebenenfalls TempDB-Bedarf; breite Texte/XML sowie viele Zeilen erhöhen Netzwerk- und Clientkosten. Für USP_CurrentBlocking ist insbesondere die im Datenkettenabschnitt beschriebene Reihenfolge maßgeblich. |
| Ressourcen | CPU und Arbeitsspeicher für DMV-Korrelation und Sortierung; optional TempDB und Ergebnistransfer für Text-/Detailspalten. |
| Begrenzungswirkung | Filter reduzieren die Kandidaten früh, TOP/Zeilenlimits können aber erst nach DMV-Lesung, Join oder Aggregation wirken und begrenzen dann primär die Ausgabe. |
| Locking und Nebenwirkungen | Read-only gegenüber Nutzdaten. Flüchtige DMVs werden nacheinander gelesen; Katalog-/SQL-Textauflösung kann kurze interne Synchronisation verursachen, erzeugt aber keinen atomaren Snapshot. |
| Schutzmechanismus | Der Code prüft die Analyseklassen `LOCKS_DEEP`. Verlangt deren Policy ein Gruppengate, ist zusätzlich `@HighImpactConfirmed = 1` nötig; Freigabe und Bestätigung ersetzen keine Scopebegrenzung. |
| Sicherer Einsatz | Mit `@MitLockDetails = 0` beginnen; LOCKS_DEEP erst für eine bereits sichtbare Blockingkette und möglichst wenige Sessions freigeben. |
| Aussagegrenze | Scope- oder Zeilenbegrenzungen können relevante, seltene oder später einsortierte Zeilen ausblenden. Die Aussage bleibt auf das Modell „Snapshot“, die dokumentierte Granularität und den sichtbaren Quellenscope begrenzt; ein kleines Resultset ist weder automatisch vollständig noch repräsentativ. |

## Technische Vertiefung

[Gemeinsames Execution-, Zeit- und Evidenzmodell](../Technical_Foundations.md)

### Leitfrage

Welche Session blockiert welche andere Session, und wo liegt der Root Blocker der Kette?

### Technischer Hintergrund

Blocking entsteht, wenn ein Task einen Lock oder eine andere blockierende Ressource benötigt, die nicht verfügbar ist. Die Procedure korreliert Request-/Taskblocker, Sessions, SQL-Kontext und – nur in `DEEP` beziehungsweise mit expliziten Lockdetails – Locks.

Die leichte Auflösung interpretiert unter anderem `OBJECT`, `KEY`, `PAGE`, `RID`, `EXTENT`, `HOBT`, `OIB`, `DATABASE`, `FILE`, `APPLICATION`, `XACT`, numerische Page-Ressourcen, Metadata-Varianten und benannte interne Ressourcen. Für Page/RID/Extent wird `sys.dm_db_page_info(..., 'LIMITED')` ausschließlich für die begrenzten Kandidaten verwendet. Objekt-, Index-, Partitions-, Statistik- und Schema-Namen werden nur in den tatsächlich referenzierten Online-Datenbanken nachgeschlagen. Dafür werden bekannte IDs direkt mit `sys.objects`, `sys.schemas` und den weiteren Katalogsichten verbunden; Metadatenfunktionen wie `OBJECT_ID()` oder `OBJECT_NAME()` sind nicht Teil des Ausführungspfads. Das gilt auch bei `database_id = 2`: Eine bekannte TempDB-Objekt-ID wird direkt über `tempdb.sys.objects` aufgelöst.

Im tiefen Pfad kommen `DATABASE`, `FILE`, `OBJECT`, `PAGE`, `KEY`, `RID`, `HOBT`, `EXTENT`, `ALLOCATION_UNIT`, `APPLICATION`, `METADATA`, `XACT`, `OIB`, `ROW_GROUP` und künftige von `sys.dm_tran_locks` gelieferte Typen hinzu. `OIB` wird wie eine HoBt-Ressource behandelt. Bei `ROW_GROUP` und anderen Typen ohne dokumentierte stabile Objekt-ID-Beziehung bleiben Rohbeschreibung, Subtyp und Entity-ID erhalten; das Framework erfindet keine Objektzuordnung.

### Datenkette

`master.sys.databases`, `master.sys.master_files`, `sys.servers`, `sys.dm_exec_requests`, `sys.dm_exec_sessions`, `sys.dm_exec_connections`, `sys.dm_exec_sql_text`, `sys.dm_os_waiting_tasks`, gezielt `sys.dm_db_page_info` sowie im tiefen Pfad `sys.dm_tran_locks`; für die begrenzten Kandidaten außerdem `sys.objects`, `sys.schemas`, `sys.indexes`, `sys.partitions`, `sys.allocation_units` und `sys.stats` der betroffenen Datenbanken.

### Source Select

Das Live-Grundselect verbindet Requests, Sessions und aktuell wartende Tasks; nur echte Blockingkandidaten werden behalten:

```sql
SELECT
      [r].[session_id]
    , [r].[request_id]
    , [r].[blocking_session_id]
    , [r].[wait_type]
    , [r].[wait_resource]
    , [wt].[wait_duration_ms]
    , [s].[status] AS [SessionStatus]
FROM [sys].[dm_exec_requests] AS [r] WITH (NOLOCK)
JOIN [sys].[dm_exec_sessions] AS [s] WITH (NOLOCK)
  ON [s].[session_id] = [r].[session_id]
LEFT JOIN [sys].[dm_os_waiting_tasks] AS [wt] WITH (NOLOCK)
  ON [wt].[session_id] = [r].[session_id]
WHERE [r].[session_id] <> @@SPID
  AND (NULLIF([r].[blocking_session_id], 0) IS NOT NULL
       OR NULLIF([wt].[blocking_session_id], 0) IS NOT NULL)
  AND COALESCE([wt].[wait_duration_ms], [r].[wait_time], 0) >= @MinWaitMs;
```

**Wichtig für die Eigenlast:** Setzen Sie Session-/Waitfilter vor SQL-Text, Lock- und Katalogauflösung. `sys.dm_tran_locks`, `sys.dm_db_page_info` und datenbanklokale Objektauflösung gehören nur in den gezielt bestätigten Detailpfad.

### Zeit- und Scope-Modell

Die Auswertung ist eine Momentaufnahme. Ketten können während der Rekonstruktion wachsen, verschwinden oder ihre Root-Session wechseln.

Die [Toolfilter-Architektur](../../Architecture/Tool_Background_Query_Filtering.md)
beschreibt die metadatengetriebenen `LIKE`-Regeln und die kettenbewahrende
Filterreihenfolge.

### Kosten und Grenzen

- `NONE` überspringt die Namensauflösung vollständig.
- `STANDARD` liest `sys.dm_tran_locks` nicht zusätzlich. Parsing erfolgt im Speicher; Katalog- und Page-Zugriffe sind dedupliziert und standardmäßig auf 100 Ressourcen begrenzt.
- `DEEP` liest Lockzeilen nur für Sessions der bereits erkannten Ketten. Der Pfad kann bei vielen Locks merkliche CPU- und DMV-Kosten verursachen und verlangt deshalb Freigabe und `@HighImpactConfirmed=1`.
- `@MaxObjektAufloesungen` akzeptiert 1 bis 1000. Bei Erreichen des Limits bleiben alle Rohressourcen sichtbar und der Status wird `SKIPPED_LIMIT` beziehungsweise `AVAILABLE_LIMITED`.
- `@MaxZeilen` begrenzt auch die erfassten Lockzeilen. Wer in einem kontrollierten Einzelaufruf wirklich jeden aktuell beobachteten nativen Locktyp sehen muss, kann `@MaxZeilen = 0` verwenden; die Namensauflösung bleibt trotzdem auf höchstens 1000 deduplizierte Kandidaten begrenzt.
- Der Blocking-/Wait-Snapshot wird zuerst in lokalen Temp-Tabellen materialisiert. Erst danach läuft jede deduplizierte Datenbank-, Datei-, Page- oder Kataloganreicherung in einem eigenen Batch mit `LOCK_TIMEOUT 0`. Timeout, fehlende Berechtigung oder Fehler markieren nur diesen Kandidaten; alle weiteren Kandidaten werden trotzdem verarbeitet.
- Die Meta-Zähler `ObjectResolutionResolvedCount`, `ObjectResolutionPartialCount`, `ObjectResolutionRawOnlyCount`, `ObjectResolutionTimeoutCount`, `ObjectResolutionDeniedCount`, `ObjectResolutionErrorCount` und `ObjectResolutionSkippedLimitCount` machen sichtbar, ob einzelne Anreicherungen fehlen. Rohressource und native IDs bleiben in jedem Fall erhalten.
- `NOLOCK` und mehrere flüchtige Quellen bilden keinen transaktional atomaren Snapshot. Eine zweite Messung kann andere Ketten oder Namen zeigen.
- Hashwerte eines `KEY`-Locks lassen sich nicht zuverlässig in den konkreten Schlüsselwert zurückrechnen. Die Auflösung endet deshalb bei Tabelle, Index und Partition.
- Nicht öffentlich dokumentierte oder versionsabhängige interne Ressourcen werden klassifiziert und roh ausgegeben, aber nur bei belastbarer ID-Beziehung auf ein Objekt abgebildet.

### Bewertung und Gegenprobe

Bewerten Sie Anzahl Opfer, längste Wartezeit, Lock-/Ressourcentyp, offene Transaktion und Zustand des Root Blockers gemeinsam. Ein aktiv arbeitender Root Blocker kann Fortschritt machen; ein sleeping Root Blocker mit alter Transaktion ist verdächtiger.

### Typische Fehlinterpretation

Die am längsten wartende Session ist nicht automatisch Ursache. `KILL` eines Opfers entfernt den Root Lock nicht; `KILL` des Root Blockers kann langen Rollback und weitere Last auslösen.

### Folgeanalyse

Verwenden Sie für die weitere Analyse `USP_CurrentTransactions` und `USP_CurrentRequests`. Nutzen Sie für die Historie Blocked-Process- oder Deadlock-Extended-Events.

## Primärquellen

- [sys.dm_exec_requests und Sonderwerte von blocking_session_id](https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-views/sys-dm-exec-requests-transact-sql)
- [sys.dm_tran_locks](https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-views/sys-dm-tran-locks-transact-sql?view=sql-server-ver17)
- [sys.dm_db_page_info](https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-views/sys-dm-db-page-info-transact-sql)

## Weiterführende Vertiefung

Die folgenden Quellen ergänzen die Produktspezifikation um Praxis- oder Toolingperspektiven. Sie sind keine Grundlage für versions-, Berechtigungs- oder Engineaussagen dieser Seite.

- [sp_WhoIsActive – ergänzende Live-Diagnostik und andere Aufbereitung aktueller Aktivität](https://github.com/amachanic/sp_whoisactive)

[Technische Detailbeschreibung](../02_Current_State.md#3-monitorusp_currentblocking)
