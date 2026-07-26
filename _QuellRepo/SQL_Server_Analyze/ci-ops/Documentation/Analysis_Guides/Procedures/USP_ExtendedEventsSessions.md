# [monitor].[USP_ExtendedEventsSessions]

**Bereich:** Extended Events<br>
**Zweck:** Inventarisiert XE-Sessions, Laufzeitstatus, Events, Actions, Targets und Felder.<br>
**Beobachtungsart:** Konfigurations- und Runtime-Snapshot<br>
**Kostenklasse:** LOW–MEDIUM

## Entscheidungsfrage und Einsatz

Die Procedure beantwortet die Betriebsfrage: **Welche XE-Sessions existieren, laufen sie, welche Events/Actions/Predicates und Targets besitzen sie?** Sie unterstützt die Entscheidung, ob die konfigurierte Ereignisquelle die gesuchte Situation erfasst hat und welche einzelne Datei, Session oder XML-Struktur anschließend vertieft wird.

## Nicht beantwortete Fragen

Die Procedure beantwortet keine Ereignisse, die nicht konfiguriert, vor Sessionstart aufgetreten oder durch Rollover/Targetgrenzen verloren gegangen sind. Der Zeitvertrag ist im Abschnitt „Zeit- und Scope-Modell“ konkretisiert. Ein Einzelwert gilt daher nur für diesen Scope und Zeitpunkt; er belegt weder eine Ursache noch eine Entwicklung.

## Sicherer Einstieg

```sql
EXEC [monitor].[USP_ExtendedEventsSessions]
      @ExtendedEventSessionNames = N'ExampleSession',
      @MitEvents = 1,
      @MitActions = 0,
      @MitTargets = 1,
      @MitFeldern = 0,
      @MaxZeilen = 100,
      @ResultSetArt = 'CONSOLE';
```

Dieser Einstieg grenzt das Inventar auf eine synthetisch benannte Session ein.
Er liest Konfiguration und optionalen Laufzeitstatus, aber weder `target_data`
noch XEL-Dateien und löst deshalb keinen Target-Flush aus.

Alle `Example*`-Werte im Aufruf sind synthetisch.

## Resultsets und Leserichtung

Der typisierte TABLE-Vertrag registriert `sessions`. Status, Scope und Warnings sind vor den Fachergebnissen zu lesen. CONSOLE dient der interaktiven Triage; RAW und JSON erhalten den technischen Kontext, während TABLE nur die ausdrücklich benannten stabilen Resultsets schreibt. Resultsets mit unterschiedlicher Zeilengranularität dürfen nicht ungeprüft vereinigt oder summiert werden.

## Eine Zeile bedeutet

Je Resultset entspricht eine Zeile einer Session, einem Event, einer Action, einem Target oder einem konfigurierten Feld.

## So lesen

Prüfen Sie Sessiondefinition, Laufzeitstatus, Events, Actions, Targets, Predicates und Verlustzähler getrennt.

## Warum kann das problematisch sein?

Eine definierte, aber gestoppte Session sammelt nichts. Fehlende Actions begrenzen spätere Korrelation; Dropped Events machen Historie unvollständig.

## Wann ist es kein Problem?

Eine bewusst nur bei Bedarf gestartete Session darf gestoppt sein.

## Beispiele und Gegenbeispiele

**Synthetischer Problemfall (`Example*`):** Deadlockevent vorhanden, aber nur kleiner Ringbuffer: historische Tiefe kann fehlen. Prüfen Sie danach Target Runtime und Events.

**Ähnlich aussehender Gegenfall:** Eine bewusst nur bei Bedarf gestartete Session darf gestoppt sein. Der gleiche Einzelwert kann deshalb bei `ExampleDb` ohne Nutzerauswirkung unkritisch sein, während er bei zeitgleicher SLA-Verletzung eine Vertiefung rechtfertigt.

## Leere oder partielle Ausgabe

Eine laufende Session kann ohne passendes Ereignis leer sein; außerdem können Target, Dateipfad, Rollover, Flushzustand und Berechtigung die Sicht einschränken.

Für `USP_ExtendedEventsSessions` gilt zusätzlich: **keine Zeile** bedeutet, dass im sichtbaren und gefilterten Scope kein ausgabefähiger Datensatz entstand. **0** ist ein gemessener Nullwert nur dann, wenn die Quellspalte tatsächlich verfügbar war. **NULL** bedeutet unbekannt, nicht anwendbar oder nicht auflösbar. **PARTIAL/Warning** bedeutet, dass mindestens eine Teilquelle, Datenbank oder Detailstufe fehlt. Ein Limit kann eine nichtleere Quelle vollständig aus dem sichtbaren Ausschnitt verdrängen.

## Eigenlast und Grenzen

**Quellcode-Hinweis zur Eigenlast:** Die Eigenlast ist gering. Es werden nur Extended-Events-Katalogviews und optional `sys.dm_xe_sessions` gelesen. Targetdaten werden nicht gelesen.

| Dimension | Aussage für diese Procedure |
|---|---|
| Kostenklasse | LOW–MEDIUM |
| Standardpfad | Liest Sessiondefinitionen, laufenden Status sowie standardmäßig Events, Actions und Targets; explizit konfigurierte Felder sind mit `@MitFeldern = 0` aus. `target_data` wird in keinem Pfad dieser Procedure gelesen. |
| Teuerster Pfad | Ungefiltertes Inventar mit allen fünf Detailarten, `@MitFeldern = 1` und `@MaxZeilen = 0`; die Kosten bleiben Katalog-/Runtimekosten und enthalten weder XEL-Lesen noch XML-Parsing von Targetinhalten. |
| Haupttreiber | Anzahl der definierten Sessions und ihrer Events, Actions, Targets und Felder. `sys.dm_xe_sessions` ergänzt nur für aktuell laufende Sessions den Runtimezustand. |
| Skalierung | Jede aktivierte Detailart wird separat aus den `sys.server_event_session_*`-Katalogviews materialisiert und sortiert. Viele Konfigurationselemente erhöhen CPU, Temp-Tabellen- und Transferkosten; nicht die Ereignismenge in den Targets. |
| Ressourcen | Geringe bis mittlere CPU für XE-Katalogviews, den optionalen Join auf `sys.dm_xe_sessions`, Filterung und Ausgabe. Es gibt keinen Targetdata-, XML- oder Datei-I/O-Pfad. |
| Begrenzungswirkung | Exakte Namen und LIKE-Pattern wirken in den Katalogabfragen. `@MaxZeilen` begrenzt jedes Detailresultset separat, nicht die Summe aller Resultsets. Regex wird nach der Materialisierung angewandt; dadurch schützt ein kleines Limit zwar die Menge, kann aber passende, zuvor nicht ausgewählte Zeilen ausblenden. |
| Locking und Nebenwirkungen | Read-only. Die Procedure startet oder stoppt keine XE-Session und liest `sys.dm_xe_session_targets` nicht; deshalb verursacht sie keinen Target-Flush. Katalog und Laufzeitstatus sind nicht atomar und können während des Aufrufs auseinanderlaufen. |
| Schutzmechanismus | Kein Forensik-Gate, weil diese Procedure weder XEL noch `target_data` liest. Session-/Event-/Targetfilter, einzelne `@Mit...`-Schalter und das je Resultset wirkende Limit begrenzen das Inventar; `@MitFeldern = 0` spart die größte optionale Katalogprojektion. |
| Sicherer Einsatz | Eine `ExampleSession`, nicht benötigte Detailarten abschalten und je Resultset ein kleines `@MaxZeilen` verwenden. Für Ereignisinhalt anschließend gezielt `USP_ExtendedEventsReadEvents`; für Targetdaten bewusst `USP_ExtendedEventsTargetRuntime` mit dessen separaten Gates wählen. |
| Aussagegrenze | Die Ausgabe beschreibt Definition und momentanen Laufzeitstatus, nicht die in Targets gespeicherten Ereignisse. Ein fehlendes Event im Inventar heißt „nicht konfiguriert“; ein vorhandenes Event beweist weder Auslösung noch Aufbewahrung. Limits und späte Regexfilter können die sichtbare Konfiguration zusätzlich verkürzen. |

## Technische Vertiefung

[Gemeinsames Execution-, Zeit- und Evidenzmodell](../Technical_Foundations.md)

### Leitfrage

Welche XE-Sessions existieren, laufen sie, welche Events/Actions/Predicates und Targets besitzen sie?

### Technischer Hintergrund

Katalogsichten für Sessions, Events, Actions, Fields und Targets bilden Definitionen; Runtime-DMVs liefern gestartete Sessions und Targetdaten. Eventname allein reicht nicht, wenn für Analyse notwendige Actions wie SQL Text, DatabaseId oder SessionId fehlen.

### Datenkette

`master.sys.databases`, `sys.dm_xe_sessions`, `sys.server_event_session_actions`, `sys.server_event_session_events`, `sys.server_event_session_fields`, `sys.server_event_session_targets`, `sys.server_event_sessions`, `sys.sp_executesql`.

### Source Select

Definition und Laufzeitzustand werden über den Sessionnamen verbunden; Events und Targets sind Childzeilen derselben Definition:

```sql
SELECT
      [ses].[name] AS [SessionName]
    , [dxs].[create_time]
    , [ev].[name] AS [EventName]
    , [t].[target_name]
FROM [sys].[server_event_sessions] AS [ses] WITH (NOLOCK)
LEFT JOIN [sys].[dm_xe_sessions] AS [dxs] WITH (NOLOCK)
  ON [dxs].[name] = [ses].[name]
LEFT JOIN [sys].[server_event_session_events] AS [ev] WITH (NOLOCK)
  ON [ev].[event_session_id] = [ses].[event_session_id]
LEFT JOIN [sys].[server_event_session_targets] AS [t] WITH (NOLOCK)
  ON [t].[event_session_id] = [ses].[event_session_id]
WHERE [ses].[name] = N'ExampleXeSession';
```

**Wichtig für die Eigenlast:** Setzen Sie Sessionname vor Events, Actions, Fields und datenbanklokalen Objektauflösungen. Die synthetische Session `ExampleXeSession` ist nur ein Platzhalter.

### Zeit- und Scope-Modell

Die Auswertung beschreibt die aktuelle Konfiguration und den Runtimezustand; Server- und Sessionstart beeinflussen den Targetinhalt.

### Bewertung und Gegenprobe

Verbinden Sie Definition und Runtime: Prüfen Sie, ob die Session vorhanden ist und läuft, das Event enthalten ist, das Predicate nicht zu eng gefasst ist, ausreichende Actions konfiguriert sind und das Target erreichbar ist. Startup State beschreibt nur das Startverhalten.

### Typische Fehlinterpretation

Eine laufende Session beweist keine vollständige Erfassung. Eine konfigurierte, aber gestoppte Session besitzt möglicherweise alte Targetdaten.

### Folgeanalyse

Für die weitere Analyse gelten folgende Schritte und Quellen: `USP_ExtendedEventsTargetRuntime` und anschließend Eventreader.

## Primärquellen

- [Extended Events](https://learn.microsoft.com/en-us/sql/relational-databases/extended-events/extended-events?view=sql-server-ver17)

[Technische Detailbeschreibung](../06_Extended_Events.md#1-monitorusp_extendedeventssessions)
