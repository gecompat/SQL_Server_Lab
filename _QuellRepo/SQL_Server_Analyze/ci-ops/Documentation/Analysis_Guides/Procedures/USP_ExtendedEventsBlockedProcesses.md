# [monitor].[USP_ExtendedEventsBlockedProcesses]

**Bereich:** Extended Events<br>
**Zweck:** Liest historische Blocked-Process-Reports und zerlegt blockierte sowie blockierende Prozesse.<br>
**Beobachtungsart:** retentionbegrenzte Ereignishistorie<br>
**Kostenklasse:** MEDIUM–HIGH_OPT_IN

## Entscheidungsfrage und Einsatz

Die Procedure beantwortet die Betriebsfrage: **Welche Blockings überschritten den konfigurierten Threshold und wurden als Reports erfasst?** Sie unterstützt die Entscheidung, ob die konfigurierte Ereignisquelle die gesuchte Situation erfasst hat und welche einzelne Datei, Session oder XML-Struktur anschließend vertieft wird.

## Nicht beantwortete Fragen

Die Procedure beantwortet keine Ereignisse, die nicht konfiguriert, vor Sessionstart aufgetreten oder durch Rollover/Targetgrenzen verloren gegangen sind. Der Zeitvertrag ist im Abschnitt „Zeit- und Scope-Modell“ konkretisiert. Ein Einzelwert gilt daher nur für diesen Scope und Zeitpunkt; er belegt weder eine Ursache noch eine Entwicklung.

## Sicherer Einstieg

```sql
DECLARE @ExampleVonUtc datetime2(7) = DATEADD(HOUR, -1, SYSUTCDATETIME());

EXEC [monitor].[USP_ExtendedEventsBlockedProcesses]
      @Quelle = 'AUTO',
      @VonUtc = @ExampleVonUtc,
      @MitReportXml = 0,
      @MitProcessXml = 0,
      @MaxZeilen = 100,
      @HighImpactConfirmed = 1,
      @ResultSetArt = 'CONSOLE';
```

Jeder fachliche Lauf ist als `EXTENDED_EVENTS_FORENSICS_DEEP` geschützt. Die Bestätigung ist für das Gruppengate nötig; Zeitfenster, Quelle und Ereignislimit bleiben die relevanten Schutzgrenzen.

Alle `Example*`-Werte im Aufruf sind synthetisch.

## Resultsets und Leserichtung

Der typisierte TABLE-Vertrag registriert `reports`. Status, Scope und Warnings sind vor den Fachergebnissen zu lesen. CONSOLE dient der interaktiven Triage; RAW und JSON erhalten den technischen Kontext, während TABLE nur die ausdrücklich benannten stabilen Resultsets schreibt. Resultsets mit unterschiedlicher Zeilengranularität dürfen nicht ungeprüft vereinigt oder summiert werden.

## Eine Zeile bedeutet

Summary-Zeile = ein Report; Process-Zeile = blockierte oder blockierende Prozessdarstellung innerhalb dieses Reports.

## So lesen

Vergleichen Sie Konfigurierten Threshold, Waitdauer, Blocker/Blocked, Ressource, Statements und Wiederholungen über Zeit.

## Warum kann das problematisch sein?

Wiederholte Reports derselben Kette zeigen persistierendes Blocking statt eines kurzen Snapshots.

## Wann ist es kein Problem?

Ein einzelner Report knapp über dem Threshold kann ein einmaliger langsamer Vorgang sein.

## Beispiele und Gegenbeispiele

**Synthetischer Problemfall (`Example*`):** Alle fünf Sekunden derselbe Root Blocker über zwei Minuten: starke Evidenz. Korrelieren Sie Live mit `USP_CurrentBlocking` und `USP_CurrentTransactions`.

**Ähnlich aussehender Gegenfall:** Ein einzelner Report knapp über dem Threshold kann ein einmaliger langsamer Vorgang sein. Der gleiche Einzelwert kann deshalb bei `ExampleDb` ohne Nutzerauswirkung unkritisch sein, während er bei zeitgleicher SLA-Verletzung eine Vertiefung rechtfertigt.

## Leere oder partielle Ausgabe

Eine laufende Session kann ohne passendes Ereignis leer sein; außerdem können Target, Dateipfad, Rollover, Flushzustand und Berechtigung die Sicht einschränken.

Für `USP_ExtendedEventsBlockedProcesses` gilt zusätzlich: **keine Zeile** bedeutet, dass im sichtbaren und gefilterten Scope kein ausgabefähiger Datensatz entstand. **0** ist ein gemessener Nullwert nur dann, wenn die Quellspalte tatsächlich verfügbar war. **NULL** bedeutet unbekannt, nicht anwendbar oder nicht auflösbar. **PARTIAL/Warning** bedeutet, dass mindestens eine Teilquelle, Datenbank oder Detailstufe fehlt. Ein Limit kann eine nichtleere Quelle vollständig aus dem sichtbaren Ausschnitt verdrängen.

Threshold 0, fehlende XE-Konfiguration oder abgelaufene Retention erlauben keine Entwarnung.

## Eigenlast und Grenzen

**Quellcode-Hinweis zur Eigenlast:** Die Eigenlast hängt von der Eventdatei und dem XML ab. Die Ergebnismenge ist begrenzt, und ein Vorfilter wird vor der XML-Zerlegung angewandt. XEL-Dateien können dennoch vollständig gelesen werden müssen.

| Dimension | Aussage für diese Procedure |
|---|---|
| Kostenklasse | MEDIUM–HIGH_OPT_IN |
| Standardpfad | AUTO sucht eine Session mit `blocked_process_report`, bevorzugt deren Eventfile und liest bis zu 200 Reports. Report-XML ist standardmäßig in der Summary enthalten, Prozess-XML nicht; beide Prozessseiten werden dennoch strukturiert aus XML extrahiert. |
| Teuerster Pfad | Unbegrenzter XEL-Wildcard- oder großer Ring-Buffer-Pfad ohne Zeitfenster, `@MitReportXml = 1` und `@MitProcessXml = 1`; Ring Buffer benötigt zusätzlich bestätigten Target-Flush. |
| Haupttreiber | XEL-Rollovermenge beziehungsweise Ring-Buffer-Größe, Zahl ausgewählter Reports und XML-Größe der blockierten/blockierenden Prozessknoten. `sys.configurations` liefert nur den aktuellen Blocked-Process-Threshold. |
| Skalierung | Die Quelle wird auf Reports/UTC gefiltert und TOP-begrenzt, danach wird jeder Report in Summary, blockierten und blockierenden Prozess zerlegt. Vollständige Prozess-XML verbreitert Resultat und Transfer, spart bei `0` aber nicht das notwendige Strukturparsing. |
| Ressourcen | Datei-I/O über das SQL-Server-Dienstkonto, CPU/Speicher für XML-Parsing, TempDB/Transfer für zerlegte Ereignisse. |
| Begrenzungswirkung | UTC-Fenster und konkrete Datei/Session sind die wichtigsten Quellgrenzen. `@MaxZeilen` begrenzt Reports vor dem Prozess-Shredding, kann aber das vorgelagerte Lesen aller passenden Rolloverdateien nicht garantieren. XML-Schalter begrenzen hauptsächlich Ausgabe. |
| Locking und Nebenwirkungen | Keine Sessionkonfiguration wird geändert. Eventfilelesen verursacht Storage-I/O; nur Ring-Buffer-Zugriff liest `sys.dm_xe_session_targets` und kann nach `@BestaetigeTargetFlush = 1` Targetpuffer flushen. Es gibt keinen `sp_server_diagnostics`-Aufruf. |
| Schutzmechanismus | Der Code prüft die Analyseklassen `EXTENDED_EVENTS_FORENSICS_DEEP`. Verlangt deren Policy ein Gruppengate, ist zusätzlich `@HighImpactConfirmed = 1` nötig; Freigabe und Bestätigung ersetzen keine Scopebegrenzung. |
| Sicherer Einsatz | Eine bekannte `ExampleSession` oder enges UTC-Fenster, beide XML-Ausgabeschalter aus, `@MaxZeilen = 100` und High-Impact-Bestätigung. Ring Buffer nur nach separater Flushentscheidung. |
| Aussagegrenze | Reports existieren nur bei konfiguriertem Threshold und aktivem Event. Ein Prozess kann im Report bereits beendet sein; gleiche SPID in mehreren Reports ist ohne Zeit/Report-ID nicht dieselbe Ausführung. Rollover und TOP begrenzen historische Vollständigkeit. |

## Technische Vertiefung

[Gemeinsames Execution-, Zeit- und Evidenzmodell](../Technical_Foundations.md)

### Leitfrage

Welche Blockings überschritten den konfigurierten Threshold und wurden als Reports erfasst?

### Technischer Hintergrund

`blocked_process_report` entsteht nur bei positivem Blocked Process Threshold und passender XE-Erfassung. XML enthält Blocked/Blocking Process, Waitresource, Lockmode und SQL-/Inputbufferkontext zum Reportzeitpunkt. Lange Blockings können mehrere Reports erzeugen.

### Datenkette

`sys.configurations`, `sys.dm_xe_session_targets`, `sys.dm_xe_sessions`, `sys.fn_xe_file_target_read_file`, `sys.server_event_session_events`, `sys.server_event_session_fields`, `sys.server_event_session_targets`, `sys.server_event_sessions`.

### Source Select

Der Dateipfad filtert Blocked-Process-Events und Zeit bereits vor der XML-Zerlegung:

```sql
SELECT
      [x].[timestamp_utc]
    , [x].[file_name]
    , [x].[file_offset]
    , TRY_CAST([x].[event_data] AS xml) AS [EventXml]
FROM [sys].[fn_xe_file_target_read_file]
     (@EventFilePattern, NULL, NULL, NULL) AS [x]
WHERE [x].[object_name] = N'blocked_process_report'
  AND [x].[timestamp_utc] >= @VonUtc
ORDER BY [x].[timestamp_utc] DESC;
```

**Wichtig für die Eigenlast:** Legen Sie Session, Eventname und Zeitfenster vor XML-Parsing fest. Ring Buffer nur gezielt verwenden; dessen `target_data` wird als Ganzes materialisiert. Ein optionaler Flush ist eine bewusste Nebenwirkung, keine Filtertechnik.

### Zeit- und Scope-Modell

Die Auswertung berücksichtigt historische Thresholdereignisse während einer aktiven Erfassung; sie bildet keine lückenlose Lockhistorie.

### Bewertung und Gegenprobe

Korrelieren Sie Dauer/Anzahl, Rootblocker, offene Transaktion, Ressourcenmuster und wiederholte Reports derselben Kette. Mehrere Reports nicht ungeprüft als verschiedene Vorfälle zählen.

### Typische Fehlinterpretation

Blocking unter Threshold, vor Sessionstart oder nach Rollover fehlt. Reportzeit ist nicht zwingend Beginn/Ende der Blockierung.

### Folgeanalyse

Verwenden Sie bei einer Reproduktion Current Blocking und Current Transactions. Analysieren Sie Zyklen mit der Deadlockanalyse.

## Primärquellen

- [Extended Events](https://learn.microsoft.com/en-us/sql/relational-databases/extended-events/extended-events?view=sql-server-ver17)

[Technische Detailbeschreibung](../06_Extended_Events.md#4-monitorusp_extendedeventsblockedprocesses)
