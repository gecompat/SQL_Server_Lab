# [monitor].[USP_CurrentMemoryGrants]

**Bereich:** Current State<br>
**Zweck:** Zeigt angeforderte, gewährte und genutzte Query Execution Memory Grants.<br>
**Beobachtungsart:** Snapshot<br>
**Kostenklasse:** LOW–MEDIUM

## Entscheidungsfrage und Einsatz

Die Procedure beantwortet die Betriebsfrage: **Welche Queries besitzen oder erwarten Workspace Memory für Sorts, Hashes und ähnliche Operatoren?** Sie unterstützt die Entscheidung, ob das aktuelle Symptom im Erfassungsmoment sichtbar ist und welcher engere Live-, Verlaufs- oder Planpfad als Nächstes sinnvoll ist.

## Nicht beantwortete Fragen

Die Procedure beantwortet keine lückenlose Historie und allein aus einem Snapshot weder Dauerhäufigkeit noch Root Cause oder zukünftige Entwicklung. Der Zeitvertrag ist im Abschnitt „Zeit- und Scope-Modell“ konkretisiert. Ein Einzelwert gilt daher nur für diesen Scope und Zeitpunkt; er belegt weder eine Ursache noch eine Entwicklung.

## Sicherer Einstieg

```sql
EXEC [monitor].[USP_CurrentMemoryGrants]
      @NurWartende = 1,
      @MitSqlText = 0,
      @MaxZeilen = 100,
      @ResultSetArt = 'CONSOLE';
```

So beginnt die Triage bei tatsächlich wartenden Grants und vermeidet zunächst
SQL-Textmaterialisierung. Für eine Kapazitätssicht auf bereits gewährte Grants
Setzen Sie `@NurWartende` anschließend bewusst auf `0`.

Alle `Example*`-Werte im Aufruf sind synthetisch.

## Resultsets und Leserichtung

Der typisierte TABLE-Vertrag registriert `memoryGrants`. Status, Scope und Warnings sind vor den Fachergebnissen zu lesen. CONSOLE dient der interaktiven Triage; RAW und JSON erhalten den technischen Kontext, während TABLE nur die ausdrücklich benannten stabilen Resultsets schreibt. Resultsets mit unterschiedlicher Zeilengranularität dürfen nicht ungeprüft vereinigt oder summiert werden.

Im Overview stammen Grants, Resource Semaphores, Sessions, Requests,
Workload-Gruppen, Resource Pools und deduplizierter SQL-Text aus derselben
Snapshot-ID. Der Einzelaufruf behält seinen frischen, eigenständigen
Materialisierungspfad.

## Eine Zeile bedeutet

Eine Zeile entspricht einem sichtbaren Memory-Grant-Vorgang einer Query beziehungsweise eines Requests.

## So lesen

Vergleichen Sie `RequestedMemoryMb`, `GrantedMemoryMb`, `UsedMemoryMb`, Wartezeit, Queryzustand und konkurrierende Grants.

## Warum kann das problematisch sein?

Ein großer angeforderter Grant mit `GrantedMemoryMb=0` wartet auf verfügbaren Execution Memory. Viele wartende Requests können einen Stau bilden.

## Wann ist es kein Problem?

Ein großer gewährter und tatsächlich genutzter Grant kann für einen großen Sort oder Hash Join angemessen sein.

## Beispiele und Gegenbeispiele

**Synthetischer Problemfall (`Example*`):** 32 GB angefordert, 0 gewährt, 60 Sekunden `RESOURCE_SEMAPHORE`: Die Query rechnet nicht langsam, sie durfte noch nicht beginnen. Dagegen sind 32 GB gewährt und 28 GB genutzt bei einem geplanten großen Report plausibel.

**Bisher dokumentierter Folgeschritt:** Prüfen Sie Plan, Kardinalität, DOP, Konkurrenz und `USP_ServerMemory`.

**Ähnlich aussehender Gegenfall:** Ein großer gewährter und tatsächlich genutzter Grant kann für einen großen Sort oder Hash Join angemessen sein. Der gleiche Einzelwert kann deshalb bei `ExampleDb` ohne Nutzerauswirkung unkritisch sein, während er bei zeitgleicher SLA-Verletzung eine Vertiefung rechtfertigt.

## Leere oder partielle Ausgabe

Bei Live-DMVs kann der Zustand bereits beendet sein, bevor die Quelle gelesen wird. Eine leere Menge ist deshalb höchstens 'jetzt nicht sichtbar', nicht 'trat nicht auf'.

Für `USP_CurrentMemoryGrants` gilt zusätzlich: **keine Zeile** bedeutet, dass im sichtbaren und gefilterten Scope kein ausgabefähiger Datensatz entstand. **0** ist ein gemessener Nullwert nur dann, wenn die Quellspalte tatsächlich verfügbar war. **NULL** bedeutet unbekannt, nicht anwendbar oder nicht auflösbar. **PARTIAL/Warning** bedeutet, dass mindestens eine Teilquelle, Datenbank oder Detailstufe fehlt. Ein Limit kann eine nichtleere Quelle vollständig aus dem sichtbaren Ausschnitt verdrängen.

## Eigenlast und Grenzen

**Quellcode-Hinweis zur Eigenlast:** Die Eigenlast ist gering; die DMV enthält nur aktuelle Grants und Anforderungen.

| Dimension | Aussage für diese Procedure |
|---|---|
| Kostenklasse | LOW–MEDIUM |
| Standardpfad | Ein Snapshot der aktuell vorhandenen Memory Grants mit Defaultlimit 1000. SQL-Text ist standardmäßig aktiv, wird aber nur für die begrenzte Kandidatenmenge aufgelöst und auf 3000 Zeichen gekürzt. |
| Teuerster Pfad | `@MaxZeilen = 0`, keine Session-/Größenfilter und ungekürzter SQL-Text während sehr vieler gleichzeitig wartender oder gewährter Grants. Zusätzlich werden Workload-Group-, Pool- und Semaphorekontext je Grant korreliert. |
| Haupttreiber | Zahl gleichzeitig wartender/gewährter Grants und ihrer Request-, Semaphore-, Workload-Group- und Poolkorrelationen. Ungekürzter SQL-Text verbreitert jeden behaltenen Kandidaten; Filter und N+1-Limit reduzieren ihn vor der Textauflösung. |
| Skalierung | Die normalerweise kleine DMV-Menge bestimmt die Join- und Sortierarbeit. Breite oder ungekürzte Batchtexte erhöhen Speicher und Transfer; die Procedure liest keine Pläne und keine Benutzertabellen. |
| Ressourcen | CPU und Arbeitsspeicher für Live-DMV-Joins und Sortierung; bei `@MitSqlText = 1` zusätzlicher Plan-Cache-/Textzugriff und Ergebnistransfer. |
| Begrenzungswirkung | Session-, Waiting- und MB-Filter stehen in der Quellabfrage. Intern werden höchstens `@MaxZeilen + 1` Kandidaten materialisiert, um `HasMoreRows` zu bestimmen. Der DMV-/Joinpfad kann für Filter und Sortierung dennoch mehr Quellzeilen untersuchen; `@MaxSqlTextZeichen` begrenzt nur Textbreite. |
| Locking und Nebenwirkungen | Read-only gegenüber Nutzdaten. Flüchtige DMVs werden nacheinander gelesen; Katalog-/SQL-Textauflösung kann kurze interne Synchronisation verursachen, erzeugt aber keinen atomaren Snapshot. |
| Schutzmechanismus | Kein High-Impact-Gate. Session-, Waiting- und Größenfilter sowie das N+1-Kandidatenlimit wirken vor der Textauflösung; `@MitSqlText = 0` und das Zeichenbudget sparen Breite. Das Sortieren/Filtern der sichtbaren Grantquelle bleibt notwendig. |
| Sicherer Einsatz | Bei akuter Grantwartefrage mit `@NurWartende = 1`, endlichem Limit und zunächst `@MitSqlText = 0` beginnen; Text nur für identifizierte Sessions ergänzen. |
| Aussagegrenze | Scope- oder Zeilenbegrenzungen können relevante, seltene oder später einsortierte Zeilen ausblenden. Die Aussage bleibt auf das Modell „Snapshot“, die dokumentierte Granularität und den sichtbaren Quellenscope begrenzt; ein kleines Resultset ist weder automatisch vollständig noch repräsentativ. |

## Technische Vertiefung

[Gemeinsames Execution-, Zeit- und Evidenzmodell](../Technical_Foundations.md)

### Leitfrage

Welche Queries besitzen oder erwarten Workspace Memory für Sorts, Hashes und ähnliche Operatoren?

### Technischer Hintergrund

Der Optimizer schätzt den benötigten Query Execution Memory Grant aus Plan, Kardinalität, Row Size und DOP. Ein Request kann erst starten beziehungsweise bestimmte Operatoren ausführen, wenn der Grant verfügbar ist. `sys.dm_exec_query_memory_grants` zeigt angefordert, gewährt, genutzt und ideal sowie wartende Grants.

### Datenkette

`sys.databases`, `sys.dm_exec_query_memory_grants`, `sys.dm_exec_query_resource_semaphores`, `sys.dm_exec_requests`, `sys.dm_exec_sessions`, `sys.dm_exec_sql_text`, `sys.dm_resource_governor_resource_pools`, `sys.dm_resource_governor_workload_groups`.

### Source Select

Das Grundselect verbindet Grants mit Session, Request und Datenbank; der Wartestatus kann bereits an der Grantquelle gefiltert werden:

```sql
SELECT
      [mg].[session_id]
    , [mg].[request_id]
    , [mg].[requested_memory_kb]
    , [mg].[granted_memory_kb]
    , [mg].[wait_time_ms]
    , [r].[wait_type]
    , [d].[name] AS [DatabaseName]
FROM [sys].[dm_exec_query_memory_grants] AS [mg] WITH (NOLOCK)
JOIN [sys].[dm_exec_sessions] AS [s] WITH (NOLOCK)
  ON [s].[session_id] = [mg].[session_id]
LEFT JOIN [sys].[dm_exec_requests] AS [r] WITH (NOLOCK)
  ON [r].[session_id] = [mg].[session_id]
 AND [r].[request_id] = [mg].[request_id]
LEFT JOIN [sys].[databases] AS [d] WITH (NOLOCK)
  ON [d].[database_id] = [r].[database_id]
WHERE [mg].[grant_time] IS NULL;
```

**Wichtig für die Eigenlast:** `NurWartende` beziehungsweise Sessionfilter vor SQL-Text und Statementextraktion anwenden. Resource-Governor- und Semaphorezeilen sind kleine Zusatzquellen, SQL-Text ist der vermeidbare breite Pfad.

### Zeit- und Scope-Modell

Die Auswertung beschreibt einen flüchtigen Zustand. Wartende Grants verschwinden bei Zuteilung oder Abbruch; die Nutzung verändert sich während der Ausführung.

### Bewertung und Gegenprobe

Berücksichtigen Sie Wartedauer, Requested, Granted, Used und Ideal, DOP, Konkurrenz und Planoperatoren gemeinsam. Große tatsächlich genutzte Grants können korrekt sein; ein großer ungenutzter Anteil spricht eher für einen Übergrant oder einen Schätzfehler.

### Typische Fehlinterpretation

`GrantedMemory=0` kann vor Start normal kurz sichtbar sein; ein einzelner großer Grant beweist keinen Servermemorymangel. Server Memory und Query Execution Memory sind verwandte, aber nicht identische Ebenen.

### Folgeanalyse

Für die weitere Analyse gelten folgende Schritte und Quellen: `USP_CurrentRequests`, `USP_ServerMemory`, Showplan/Statistics und Query Store Runtime.

## Primärquellen

- [sys.dm_exec_query_memory_grants](https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-views/sys-dm-exec-query-memory-grants-transact-sql?view=sql-server-ver17)

## Weiterführende Vertiefung

Die folgenden Quellen ergänzen die Produktspezifikation um Praxis- oder Toolingperspektiven. Sie sind keine Grundlage für versions-, Berechtigungs- oder Engineaussagen dieser Seite.

- [sp_WhoIsActive – ergänzende Live-Diagnostik und andere Aufbereitung aktueller Aktivität](https://github.com/amachanic/sp_whoisactive)

[Technische Detailbeschreibung](../02_Current_State.md#6-monitorusp_currentmemorygrants)
