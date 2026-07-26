# [monitor].[USP_ExtendedEventsDeadlocks]

**Bereich:** Extended Events<br>
**Zweck:** Zerlegt Deadlockgraphs in Summary, Victims, Processes und Resources.<br>
**Beobachtungsart:** retentionbegrenzte Ereignishistorie<br>
**Kostenklasse:** MEDIUM–HIGH_OPT_IN

## Entscheidungsfrage und Einsatz

Die Procedure beantwortet die Betriebsfrage: **Welche Sessions/Prozesse bildeten einen Deadlockzyklus, welches Opfer wurde gewählt und welche Ressourcen/Kanten waren beteiligt?** Sie unterstützt die Entscheidung, ob die konfigurierte Ereignisquelle die gesuchte Situation erfasst hat und welche einzelne Datei, Session oder XML-Struktur anschließend vertieft wird.

## Nicht beantwortete Fragen

Die Procedure beantwortet keine Ereignisse, die nicht konfiguriert, vor Sessionstart aufgetreten oder durch Rollover/Targetgrenzen verloren gegangen sind. Der Zeitvertrag ist im Abschnitt „Zeit- und Scope-Modell“ konkretisiert. Ein Einzelwert gilt daher nur für diesen Scope und Zeitpunkt; er belegt weder eine Ursache noch eine Entwicklung.

## Sicherer Einstieg

```sql
DECLARE @ExampleVonUtc datetime2(7) = DATEADD(HOUR, -24, SYSUTCDATETIME());

EXEC [monitor].[USP_ExtendedEventsDeadlocks]
      @SourceExtendedEventSessionName = N'system_health',
      @VonUtc = @ExampleVonUtc,
      @MitDeadlockXml = 0,
      @MitProcessDetails = 0,
      @MitResourceDetails = 0,
      @MaxZeilen = 50,
      @HighImpactConfirmed = 1,
      @ResultSetArt = 'CONSOLE';
```

Jeder fachliche Lauf ist als `EXTENDED_EVENTS_FORENSICS_DEEP` geschützt. Die Bestätigung ist trotz engem Zeitfenster erforderlich; sie begrenzt weder die Zahl der Rolloverdateien noch garantiert sie einen frühen Dateifilter.

Alle `Example*`-Werte im Aufruf sind synthetisch.

## Resultsets und Leserichtung

Der typisierte TABLE-Vertrag registriert `deadlocks`. Status, Scope und Warnings sind vor den Fachergebnissen zu lesen. CONSOLE dient der interaktiven Triage; RAW und JSON erhalten den technischen Kontext, während TABLE nur die ausdrücklich benannten stabilen Resultsets schreibt. Resultsets mit unterschiedlicher Zeilengranularität dürfen nicht ungeprüft vereinigt oder summiert werden.

## Eine Zeile bedeutet

Summary-Zeile = Deadlock; Victim-Zeile = Opferprozess; Process-Zeile = Graphprozess; Resource-Zeile = beteiligte Lockressource.

## So lesen

Berücksichtigen Sie Opfer, alle Prozesse, Ressourcen und Zugriffsreihenfolge gemeinsam. Das Opfer ist nicht automatisch der Verursacher.

## Warum kann das problematisch sein?

Deadlock ist zyklisches Warten; SQL Server muss mindestens eine Transaktion abbrechen. Wiederholung erzeugt Fehler, Rollbacks und Durchsatzverlust.

## Wann ist es kein Problem?

Ein einmaliges Ereignis nach seltenem Deployment kann geringere Priorität besitzen als ein minütlich wiederkehrendes Muster.

## Beispiele und Gegenbeispiele

**Synthetischer Problemfall (`Example*`):** Wenn zwei Sessions Objekte in umgekehrter Reihenfolge sperren, müssen eine konsistente Zugriffsreihenfolge, Isolation, Indizes und Transaktionsumfang geprüft werden.

**Ähnlich aussehender Gegenfall:** Ein einmaliges Ereignis nach seltenem Deployment kann geringere Priorität besitzen als ein minütlich wiederkehrendes Muster. Der gleiche Einzelwert kann deshalb bei `ExampleDb` ohne Nutzerauswirkung unkritisch sein, während er bei zeitgleicher SLA-Verletzung eine Vertiefung rechtfertigt.

## Leere oder partielle Ausgabe

Eine laufende Session kann ohne passendes Ereignis leer sein; außerdem können Target, Dateipfad, Rollover, Flushzustand und Berechtigung die Sicht einschränken.

Für `USP_ExtendedEventsDeadlocks` gilt zusätzlich: **keine Zeile** bedeutet, dass im sichtbaren und gefilterten Scope kein ausgabefähiger Datensatz entstand. **0** ist ein gemessener Nullwert nur dann, wenn die Quellspalte tatsächlich verfügbar war. **NULL** bedeutet unbekannt, nicht anwendbar oder nicht auflösbar. **PARTIAL/Warning** bedeutet, dass mindestens eine Teilquelle, Datenbank oder Detailstufe fehlt. Ein Limit kann eine nichtleere Quelle vollständig aus dem sichtbaren Ausschnitt verdrängen.

## Eigenlast und Grenzen

**Quellcode-Hinweis zur Eigenlast:** Die Eigenlast hängt von der Eventdatei und dem XML ab; Maximalzahl und UTC-Filter werden vor der XML-Zerlegung angewandt. Trotzdem können XEL-Dateien vollständig gelesen werden müssen.

| Dimension | Aussage für diese Procedure |
|---|---|
| Kostenklasse | MEDIUM–HIGH_OPT_IN |
| Standardpfad | AUTO liest bis zu 100 `xml_deadlock_report`-Events aus dem `system_health`-Eventfile. Default gibt Deadlock-XML aus und zerlegt zusätzlich Victims, alle Prozesse und Ressourcen – der Default ist bereits eine vollständige Graphanalyse. |
| Teuerster Pfad | Unbegrenzte XEL-Rollovermenge oder großer Ring Buffer ohne Zeitfenster mit vollständiger XML-, Prozess- und Ressourcenausgabe; Ring Buffer benötigt bestätigten Target-Flush. |
| Haupttreiber | Rolloverdateigröße beziehungsweise Ring-Buffer-Größe, Zahl der ausgewählten Deadlocks und Anzahl/Komplexität von Prozess- und Ressourcenknoten je Graph. |
| Skalierung | TOP/UTC wählen Graphen vor dem fachlichen Shredding. Danach wächst CPU annähernd mit allen Victim-, Prozess- und Ressourcenknoten; eingebettete Inputbuf-/Owner-/Waiter-XML erhöht Speicher und Transfer. |
| Ressourcen | Datei-I/O über das SQL-Server-Dienstkonto, CPU/Speicher für XML-Parsing, TempDB/Transfer für zerlegte Ereignisse. |
| Begrenzungswirkung | `@MaxZeilen` begrenzt Deadlockevents vor Graph-Shredding, aber nicht garantiert den physischen XEL-Wildcardscan. `@MitProcessDetails`/`@MitResourceDetails` sparen das jeweilige Shredding; `@MitDeadlockXml = 0` spart primär Ausgabe. |
| Locking und Nebenwirkungen | Keine XE-Konfigurationsänderung. Eventfilelesen konkurriert mit Storage-I/O; Ring-Buffer-Lesen kann erst nach `@BestaetigeTargetFlush = 1` Targetpuffer flushen. Kein `sp_server_diagnostics`-Pfad. |
| Schutzmechanismus | Der Code prüft die Analyseklassen `EXTENDED_EVENTS_FORENSICS_DEEP`. Verlangt deren Policy ein Gruppengate, ist zusätzlich `@HighImpactConfirmed = 1` nötig; Freigabe und Bestätigung ersetzen keine Scopebegrenzung. |
| Sicherer Einsatz | `system_health`, enges UTC-Fenster, 50 Graphen und zunächst nur Summary/Victim; High-Impact bestätigen. Prozesse/Ressourcen für konkrete Deadlock-IDs nachfordern, Ring Buffer nur nach Flushentscheidung. |
| Aussagegrenze | Ein Graph zeigt genau den von SQL Server gewählten Zyklus/Opferzeitpunkt, nicht alle vorausgehenden Warteketten. Objekt-/Indexnamen können fehlen, IDs wiederverwendet werden, und Rollover/Top-N verhindert eine vollständige Häufigkeitsaussage. |

## Technische Vertiefung

[Gemeinsames Execution-, Zeit- und Evidenzmodell](../Technical_Foundations.md)

### Leitfrage

Welche Sessions/Prozesse bildeten einen Deadlockzyklus, welches Opfer wurde gewählt und welche Ressourcen/Kanten waren beteiligt?

### Technischer Hintergrund

Der Lock Monitor erkennt einen Zyklus, wählt anhand Deadlock Priority und Rollbackkosten ein Opfer und erzeugt einen Deadlockgraph. XML enthält Victim List, Process List und Resource List mit Owner-/Waiter-Kanten.

### Datenkette

`sys.dm_xe_session_targets`, `sys.dm_xe_sessions`, `sys.fn_xe_file_target_read_file`, `sys.server_event_session_fields`, `sys.server_event_session_targets`, `sys.server_event_sessions`.

### Source Select

Der zentrale Forensikpfad liest ausschließlich Deadlockevents aus der bereits ausgewählten XEL-Dateimenge:

```sql
SELECT
      [x].[timestamp_utc]
    , [x].[file_name]
    , [x].[file_offset]
    , TRY_CAST([x].[event_data] AS xml) AS [EventXml]
FROM [sys].[fn_xe_file_target_read_file]
     (@EventFilePattern, NULL, NULL, NULL) AS [x]
WHERE [x].[object_name] = N'xml_deadlock_report'
  AND [x].[timestamp_utc] >= @VonUtc
ORDER BY [x].[timestamp_utc] DESC;
```

**Wichtig für die Eigenlast:** Rollovermenge und Zeitfenster begrenzen, bevor Deadlock-XML zerlegt wird. `TOP` nach einer unbeschränkten Dateifunktion reduziert möglicherweise nur Sortierungsausgabe, nicht den gesamten Dateizugriff.

### Zeit- und Scope-Modell

Die Auswertung berücksichtigt einzelne historische Deadlockereignisse, soweit sie im Target erhalten sind.

### Bewertung und Gegenprobe

Lesen Sie den Zyklus vollständig; das Opfer ist nicht automatisch der Verursacher. Bewerten Sie Zugriffsreihenfolge, Lockmodi, Isolation, Indexzugriff, Transaktionsscope und wiederkehrende Query- und Objektmuster.

### Typische Fehlinterpretation

Nur SQL-Text des Opfers zu optimieren kann den Zyklus unverändert lassen. Blocking ohne Zyklus erscheint nicht als Deadlock.

### Folgeanalyse

Verwenden Sie für die weitere Analyse Showplan und Indexanalyse. Prüfen Sie die Transaktionsreihenfolge der Anwendung und gruppieren Sie wiederholte Graphen.

## Primärquellen

- [Extended Events](https://learn.microsoft.com/en-us/sql/relational-databases/extended-events/extended-events?view=sql-server-ver17)

[Technische Detailbeschreibung](../06_Extended_Events.md#3-monitorusp_extendedeventsdeadlocks)
