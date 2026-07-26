# [monitor].[USP_ExtendedEventsTargetRuntime]

**Bereich:** Extended Events<br>
**Zweck:** Zeigt Runtimezustand und optional Daten laufender XE-Targets.<br>
**Beobachtungsart:** Konfigurations- und Runtime-Snapshot<br>
**Kostenklasse:** LOW–HIGH_OPT_IN

## Entscheidungsfrage und Einsatz

Die Procedure beantwortet die Betriebsfrage: **Verliert, begrenzt oder rotiert das Target Ereignisse, und ist es für die gewünschte Historie geeignet?** Sie unterstützt die Entscheidung, ob die konfigurierte Ereignisquelle die gesuchte Situation erfasst hat und welche einzelne Datei, Session oder XML-Struktur anschließend vertieft wird.

## Nicht beantwortete Fragen

Die Procedure beantwortet keine Ereignisse, die nicht konfiguriert, vor Sessionstart aufgetreten oder durch Rollover/Targetgrenzen verloren gegangen sind. Der Zeitvertrag ist im Abschnitt „Zeit- und Scope-Modell“ konkretisiert. Ein Einzelwert gilt daher nur für diesen Scope und Zeitpunkt; er belegt weder eine Ursache noch eine Entwicklung.

## Sicherer Einstieg

```sql
EXEC [monitor].[USP_ExtendedEventsTargetRuntime]
      @MitTargetData = 0,
      @BestaetigeTargetFlush = 0,
      @HighImpactConfirmed = 1,
      @ResultSetArt = 'CONSOLE';
```

Der Aufruf passiert das zwingende `EXTENDED_EVENTS_FORENSICS_DEEP`-Gate, bestätigt aber keinen Target-Flush und liefert daher bewusst nur den deaktivierten Statuspfad. Einen Flush und Targetdaten erst nach eigener Prüfung separat bestätigen; das High-Impact-Gate allein löst keinen Flush aus.

Alle `Example*`-Werte im Aufruf sind synthetisch.

## Resultsets und Leserichtung

Der typisierte TABLE-Vertrag registriert `targets`. Status, Scope und Warnings sind vor den Fachergebnissen zu lesen. CONSOLE dient der interaktiven Triage; RAW und JSON erhalten den technischen Kontext, während TABLE nur die ausdrücklich benannten stabilen Resultsets schreibt. Resultsets mit unterschiedlicher Zeilengranularität dürfen nicht ungeprüft vereinigt oder summiert werden.

## Eine Zeile bedeutet

Eine Zeile entspricht einem Target einer laufenden Session. Optionales Targetdata-Resultset besitzt targetabhängige Struktur.

## So lesen

Prüfen Sie Targettyp, Laufzeitstatus, Pfad, Speicher, Event-/Bufferzähler und Dropped Events.

## Warum kann das problematisch sein?

Dropped Events oder zu kleine Targets bedeuten Evidenzverlust. Das Lesen bestimmter Runtime-Targets kann einen Flush auslösen.

## Wann ist es kein Problem?

Ein kleiner Ringbuffer kann für kurzfristige Ad-hoc-Diagnose passend sein, aber nicht für lange Historie.

## Beispiele und Gegenbeispiele

**Synthetischer Problemfall (`Example*`):** Session läuft, aber viele Events wurden verworfen: ein leeres Spezialresultset ist keine Entwarnung. Prüfen Sie Targetgröße, Eventrate und Event-File-Strategie.

**Ähnlich aussehender Gegenfall:** Ein kleiner Ringbuffer kann für kurzfristige Ad-hoc-Diagnose passend sein, aber nicht für lange Historie. Der gleiche Einzelwert kann deshalb bei `ExampleDb` ohne Nutzerauswirkung unkritisch sein, während er bei zeitgleicher SLA-Verletzung eine Vertiefung rechtfertigt.

## Leere oder partielle Ausgabe

Eine laufende Session kann ohne passendes Ereignis leer sein; außerdem können Target, Dateipfad, Rollover, Flushzustand und Berechtigung die Sicht einschränken.

Für `USP_ExtendedEventsTargetRuntime` gilt zusätzlich: **keine Zeile** bedeutet, dass im sichtbaren und gefilterten Scope kein ausgabefähiger Datensatz entstand. **0** ist ein gemessener Nullwert nur dann, wenn die Quellspalte tatsächlich verfügbar war. **NULL** bedeutet unbekannt, nicht anwendbar oder nicht auflösbar. **PARTIAL/Warning** bedeutet, dass mindestens eine Teilquelle, Datenbank oder Detailstufe fehlt. Ein Limit kann eine nichtleere Quelle vollständig aus dem sichtbaren Ausschnitt verdrängen.

## Eigenlast und Grenzen

**Quellcode-Hinweis zur Eigenlast:** Normalerweise gering, kann aber durch große target_data-Inhalte sowie einen Target-Flush merkbar werden.

| Dimension | Aussage für diese Procedure |
|---|---|
| Kostenklasse | LOW–HIGH_OPT_IN |
| Standardpfad | Inventar-/Runtime-Snapshot mit Session- und Targetfilter; Targetdaten ausgeschaltet oder stark gekürzt. |
| Teuerster Pfad | Viele große Targetdokumente mit `@MitTargetData = 1`, hohem Zeichenbudget und ausdrücklich bestätigtem Target-Flush. |
| Haupttreiber | Zahl laufender Session-/Targetkombinationen und – bei `@MitTargetData = 1` – Größe der jeweiligen `target_data`-XML. Zeichenbudget reduziert die Rückgabebreite; ein bestätigter Flush kann vorher zusätzliche Targetarbeit auslösen. |
| Skalierung | Laufzeit und CPU wachsen mit dem Haupttreiber. Sortierung/Aggregation erhöht Speicher- und gegebenenfalls TempDB-Bedarf; breite Texte/XML sowie viele Zeilen erhöhen Netzwerk- und Clientkosten. Für USP_ExtendedEventsTargetRuntime ist insbesondere die im Datenkettenabschnitt beschriebene Reihenfolge maßgeblich. |
| Ressourcen | CPU und Speicher für XE-Katalog-/Runtimezeilen; bei Targetdata zusätzlich XML-/Stringmaterialisierung und Transfer. |
| Begrenzungswirkung | Session-/Targetfilter reduzieren die Quelle. Eine Zeichenkürzung begrenzt Transfer, nicht zwingend die Erzeugung des Targetdokuments durch die Engine. |
| Locking und Nebenwirkungen | Keine Konfigurationsänderung, aber das Lesen von `sys.dm_xe_session_targets` kann Targetpuffer flushen. Deshalb liest die Procedure diese DMV erst nach `@BestaetigeTargetFlush = 1`; Session- und Targetzustand können sich während des Aufrufs trotzdem ändern. |
| Schutzmechanismus | Der Code prüft die Analyseklassen `EXTENDED_EVENTS_FORENSICS_DEEP`. Verlangt deren Policy ein Gruppengate, ist zusätzlich `@HighImpactConfirmed = 1` nötig; Freigabe und Bestätigung ersetzen keine Scopebegrenzung. |
| Sicherer Einsatz | Eine ExampleSession, `@MitTargetData = 0` und kein Flush; Targetinhalt und Flush nur gezielt mit kleinem Zeichenbudget anfordern. |
| Aussagegrenze | Scope- oder Zeilenbegrenzungen können relevante, seltene oder später einsortierte Zeilen ausblenden. Die Aussage bleibt auf das Modell „Konfigurations- und Runtime-Snapshot“, die dokumentierte Granularität und den sichtbaren Quellenscope begrenzt; ein kleines Resultset ist weder automatisch vollständig noch repräsentativ. |

## Technische Vertiefung

[Gemeinsames Execution-, Zeit- und Evidenzmodell](../Technical_Foundations.md)

### Leitfrage

Verliert, begrenzt oder rotiert das Target Ereignisse, und ist es für die gewünschte Historie geeignet?

### Technischer Hintergrund

Runtime-DMVs liefern Targettyp/-daten, Buffer-/Memory-/Eventcounter und je Version Drop-/Dispatchinformationen. Event File Konfiguration bestimmt Dateigröße/Rollover; Ring Buffer hat XML-/Memorygrenzen.

### Datenkette

`master.sys.databases`, `sys.dm_xe_session_targets`, `sys.dm_xe_sessions`, `sys.sp_executesql`.

### Source Select

Runtime-Targetdaten werden über die Address der laufenden XE-Session mit der Session verbunden:

```sql
SELECT
      [s].[name] AS [SessionName]
    , [t].[target_name]
    , [t].[execution_count]
    , [t].[execution_duration_ms]
    , [t].[target_data]
FROM [sys].[dm_xe_sessions] AS [s] WITH (NOLOCK)
JOIN [sys].[dm_xe_session_targets] AS [t] WITH (NOLOCK)
  ON [t].[event_session_address] = [s].[address]
WHERE [s].[name] = N'ExampleXeSession'
  AND [t].[target_name] IN (N'event_file', N'ring_buffer');
```

**Wichtig für die Eigenlast:** Filtern Sie Session und Targettyp vor der Projektion von `target_data`. Ring-Buffer-XML kann groß sein; aktivieren Sie die Text- und XML-Ausgabe nur für die gezielt ausgewählte Targetzeile.

### Zeit- und Scope-Modell

Die Auswertung beschreibt den aktuellen Runtimezustand und Targetinhalt seit Sessionstart beziehungsweise Rollover.

### Bewertung und Gegenprobe

Berücksichtigen Sie Dropped Events und Buffers, Memory, die File- oder Ring-Buffer-Auslastung, Dispatch Latency, Retention Mode und Eventrate gemeinsam. Das Target muss zur Ereignisrate passen.

### Typische Fehlinterpretation

`0 Drops` beweist keine ausreichende historische Retention; sauberes Rollover kann alte Ereignisse ohne Dropindikator entfernen.

### Folgeanalyse

Passen Sie für die weitere Analyse die Sessionkonfiguration an und validieren Sie die externe Dateiretention, das Monitoring und den Eventreader.

## Primärquellen

- [Extended Events](https://learn.microsoft.com/en-us/sql/relational-databases/extended-events/extended-events?view=sql-server-ver17)

[Technische Detailbeschreibung](../06_Extended_Events.md#5-monitorusp_extendedeventstargetruntime)
