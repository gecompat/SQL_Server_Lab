# [monitor].[USP_ExtendedEventsReadEvents]

**Bereich:** Extended Events<br>
**Zweck:** Liest erhaltene Extended-Events-Einzelereignisse aus Event Files oder bewusst aus einem Ring Buffer und stellt Zeit, Quelle, häufige Actions/Datafelder sowie optional das Event-XML bereit.<br>
**Beobachtungsart:** begrenzte Ereignishistorie innerhalb der erhaltenen Targetdaten<br>
**Kostenklasse:** `HIGH_OPT_IN`

## Entscheidungsfrage und Einsatz

Diese Auswertung beantwortet: **Welche von einer bestimmten Extended-Events-Session erfassten Ereignisse sind in der noch verfügbaren Targetretention vorhanden und erfüllen den angegebenen Ereignis-/UTC-Zeitfilter?**

Sie eignet sich, wenn ein konkretes Ereignis bereits als Evidenzquelle gewählt wurde: beispielsweise ein Deadlock aus `system_health`, ein Fehlerereignis einer synthetisch benannten Session oder die zeitliche Reihenfolge mehrerer Capture-Ereignisse. Die Procedure ist ein generischer Reader. Für Deadlocks oder Blocked-Process-Reports sind die spezialisierten Procedures anschließend leichter und fachlich enger.

## Nicht beantwortete Fragen

Die Procedure beweist nicht, dass ein nicht gefundenes Ereignis nie stattgefunden hat. Extended Events enthalten nur, was eine laufende Session mit passendem Event, Predicate und Actions erfasst und was das Target noch nicht verworfen oder überschrieben hat. Event Files können durch Rollover fehlen; ein Ring Buffer ist speicherbegrenzt und keine dauerhafte Historie.

Ein generisches `DurationRaw` besitzt ohne Eventmetadaten keine universelle Einheit. Fehlende `SqlText`, `DatabaseName`, `SessionId` oder Loginwerte können bedeuten, dass die Action beziehungsweise das Datafeld für dieses Event nicht existiert oder nicht erfasst wurde. Die Ausgabe ersetzt weder die aktuelle Enginezustandsanalyse noch ein revisionssicheres Audit.

## Sicherer Einstieg

Zeigen Sie zuerst Parameter und Gate ohne Targetzugriff an:

```sql
EXEC [monitor].[USP_ExtendedEventsReadEvents]
      @Hilfe = 1;
```

Der kleinste praktische File-Lauf verwendet ein enges halboffenes UTC-Fenster, einen Eventnamen, eine endliche Zeilenzahl und die konfigurierte Datei des öffentlichen SQL-Server-Systembezeichners `system_health`. Die `Example*`-Variablen sind synthetisch:

```sql
DECLARE @ExampleToUtc datetime2(7) = SYSUTCDATETIME();
DECLARE @ExampleFromUtc datetime2(7) = DATEADD(HOUR, -1, @ExampleToUtc);

EXEC [monitor].[USP_ExtendedEventsReadEvents]
      @SourceExtendedEventSessionName = N'system_health',
      @Quelle = 'EVENT_FILE',
      @EventNames = N'[xml_deadlock_report]',
      @VonUtc = @ExampleFromUtc,
      @BisUtc = @ExampleToUtc,
      @MaxZeilen = 100,
      @MitEventXml = 0,
      @HighImpactConfirmed = 1,
      @ResultSetArt = 'RAW';
```

`RAW` ist hier trotz des allgemeinen CONSOLE-Einstiegs bewusst gewählt: Es zeigt den SourceStatus und unterdrückt bei `@MitEventXml = 0` die XML-Spalte der RAW-Projektion. Der Quellpfad bleibt trotzdem `HIGH_OPT_IN`; Zeit- und Eventfilter garantieren bei einem XEL-Wildcardscan keine proportionale Reduktion der gelesenen Dateien.

Keinen realen `@FilePath` in ungeschützte Dokumentation oder Tickets kopieren. SourceStatus, Event XML, SQL-Text, Login, Host und Clientanwendung können in einer Laufzeitumgebung interne Pfade oder schutzbedürftige Inhalte enthalten.

## Resultsets und Leserichtung

- `RAW` liefert zuerst Modulstatus, danach angereicherte Eventzeilen und zuletzt SourceStatus. Leserichtung: `StatusCode`/`IsPartial` → SourceStatus → Events.
- `CONSOLE` liefert genau ein fachliches Resultset direkt aus der Rohmenge mit `SourceType`, `EventName`, `TimestampUtc`, Datei/Offset und `EventXml`.
- `TABLE` exportiert ausschließlich das Primärergebnis `events` aus derselben Rohmenge in die über `@ResultTablesJson` zugeordnete lokale Temp-Tabelle. SourceStatus wird nicht mitexportiert.
- JSON trennt `meta`, angereicherte `events`, `sources` und `warnings`.

Wichtige Implementierungsgrenze: `@MitEventXml = 0` unterdrückt das vollständige XML in der RAW- und JSON-Projektion, nicht aber seine vorherige Konvertierung und Feldextraktion. CONSOLE und TABLE arbeiten aktuell direkt auf der Rohmenge und enthalten deshalb weiterhin `EventXml`. Verwenden Sie `RAW` mit `@MitEventXml = 0`, wenn der XML-Transfer vermieden werden soll. TABLE ist nicht als XML-freier Export zu interpretieren.

## Eine Zeile bedeutet

Eine Eventzeile entspricht einem im gewählten Target erhaltenen XE-Ereignis. Bei `EVENT_FILE` bilden `FileName` und `FileOffset` die Quellposition; bei `RING_BUFFER` sind beide Werte `NULL`. `TimestampUtc` stammt aus dem Event und wird als UTC behandelt.

Eine SourceStatus-Zeile ist keine Eventzeile. Sie beschreibt Katalog-, File- oder Ring-Buffer-Zugriff, den aufgelösten Pfad, Fehler und Detailhinweise. Mehrere identisch benannte Events sind nicht automatisch Duplikate: Sie können unterschiedliche Zeitpunkte, Sessions, Payloads oder Dateioffsets besitzen.

## So lesen

1. **Gate und Modulstatus:** Prüfen Sie `EXTENDED_EVENTS_FORENSICS_DEEP`, `@HighImpactConfirmed` und eventuelle Berechtigungs- oder Featurefehler.
2. **SourceStatus:** Prüfen Sie, ob `EVENT_FILE` oder `RING_BUFFER` tatsächlich gelesen wurde. Ermitteln Sie außerdem, ob ein Pfad vorhanden, die Session gestartet und das Target lesbar war.
3. **Zeitfenster:** Die Procedure verwendet `TimestampUtc >= @VonUtc` und `TimestampUtc < @BisUtc`. Rechnen Sie die Zeitzone des Symptoms vor dem Vergleich korrekt nach UTC um.
4. **Ereignisidentität:** Halten Sie `EventName`, `SourceType`, Timestamp sowie Datei und Offset fest. Interpretieren Sie erst danach optionale Actions und Datenfelder.
5. **Payloadverfügbarkeit:** `NULL` bei Datenbank, Session, SQL-Text, Wait oder Fehlernummer kann „für dieses Event nicht vorhanden“ bedeuten. Es ist kein gemessener Wert 0.
6. **Eventsemantik:** Bewerten Sie `DurationRaw`, `WaitType`, Severity und ResourceDescription nur gegen die Definition des konkreten Events. Generische Spalten normalisieren Namen, nicht ihre gesamte Semantik.
7. **Vollständigkeit:** Vergleichen Sie Dateiwildcard, Rollover, Event-Session-Konfiguration, Predicate, Capturezeitraum und Zeilenlimit mit dem Untersuchungszeitraum.

## Warum kann das problematisch sein?

Ein erfasstes Ereignis kann eine belastbare zeitliche Spur für Deadlocks, Fehler, lange Operationen oder Enginezustände liefern. Die Payload kann SQL-Text und Korrelationsschlüssel enthalten, mit denen die Auswirkung weiterverfolgt wird. Fehlende Ereignisse können dagegen eine falsche Entwarnung erzeugen, wenn Capture und Retention nicht zuerst geprüft werden.

Auch der Reader selbst kann relevant belasten. `sys.fn_xe_file_target_read_file` muss XEL-Fragmente öffnen und Zeilen liefern; die Procedure konvertiert `event_data` in XML, sortiert nach dem neuesten Timestamp und extrahiert je Event mehrere XML-Pfade. Viele Rollover-Dateien oder große Payloads erzeugen Datei-I/O, CPU, Speicher und Transfer. Der Ring-Buffer-Pfad materialisiert und zerlegt das Target-XML und hat zusätzlich eine bewusste Flush-Nebenwirkung.

## Wann ist es kein Problem?

Ein einzelnes erwartetes Fehler- oder Informationsereignis kann ohne Nutzerwirkung auftreten. Mehrere Events mit ähnlichem Namen können zu normaler Engineaktivität gehören. Ein leeres Ergebnis kann aussagefähig sein, wenn nachweislich die richtige Session mit richtigem Event/Predicate im gesamten Untersuchungsfenster lief, das Target vollständig erhalten und lesbar ist und kein Limit oder Filter passende Ereignisse verdrängt hat.

Selbst dann lautet die Aussage nur: „In dieser geprüften Capturequelle wurde im geprüften Fenster kein passendes Event gefunden.“ Sie lautet nicht: „Das technische Ereignis ist sicher nie eingetreten.“

## Beispiele und Gegenbeispiele

**Synthetischer Fund `ExampleDeadlockEvidence`:** SourceStatus ist `AVAILABLE`; zwei `xml_deadlock_report`-Events liegen innerhalb des bestätigten UTC-Fensters in unterschiedlichen FileOffsets. Beobachtung: Die konfigurierte Session hat zwei Deadlockereignisse erhalten. Nächster Schritt: Verwenden Sie `USP_ExtendedEventsDeadlocks` für Victim, Prozesse und Ressourcen und prüfen Sie den Query- und Transaktionskontext unabhängig. Die Zahl zwei allein erklärt weder Root Cause noch Geschäftsauswirkung.

**Falsche Entwarnung `ExampleEmptyAfterRollover`:** Keine Eventzeile, aber der konfigurierte XEL-Satz beginnt erst nach dem gemeldeten Vorfall. Das Ergebnis sagt nichts über den fehlenden Zeitraum. Rollover-/Retentionkonfiguration und vorhandene Dateien sind die Gegenprobe.

**Ring-Buffer-Gegenfall `ExampleRingBuffer`:** Das gesuchte Event fehlt aus dem aktuellen Ring Buffer. Wenn die Session lange läuft und das Target ältere Einträge überschrieben beziehungsweise ausgelassen hat, ist fehlende XML keine historische Negativaussage. Ein Event File oder eine neu geplante Capture-Session ist für längere Retention geeigneter.

## Leere oder partielle Ausgabe

`AVAILABLE_LIMITED` mit 0 Zeilen bedeutet, dass die gewählte Quelle lesbar war, aber nach dem Filter keine Events in der Rohmenge verblieben. Vor einer Entwarnung prüfen:

- richtige Session und Targetart,
- Sessionstart und tatsächlich konfigurierte Events/Actions/Predicates,
- UTC-Grenzen und halboffenes Enddatum,
- Dateiwildcard, vorhandene Rollover-Dateien und Retention,
- Dateiberechtigung und Lesbarkeit auf dem SQL-Server-Host,
- Eventname, LIKE-/Regexmodus und Zeilenlimit.

`AUTO` bevorzugt Event Files. Ist kein lesbarer Pfad vorhanden, wechselt es nur mit `@BestaetigeTargetFlush = 1` zum Ring Buffer; andernfalls endet es als `AVAILABLE_DISABLED`. Ein expliziter Ring-Buffer-Lauf ohne diese Bestätigung liest `sys.dm_xe_session_targets` nicht.

Bei Regex wird zunächst bis `@MaxZeilen` nach Zeit sortierte Rohmenge gelesen und erst danach in der Temp-Tabelle gelöscht. Dadurch können weniger Zeilen als angefordert zurückkommen; ältere Regex-Treffer außerhalb der vorab begrenzten Rohmenge werden nicht nachgeladen. Für eine Vollständigkeitsbehauptung ist dieser Pfad ungeeignet, solange der Kandidatenscope nicht anderweitig vollständig begrenzt ist.

## Eigenlast und Grenzen

| Dimension | Aussage für diese Procedure |
|---|---|
| Kostenklasse | `HIGH_OPT_IN`; jeder fachliche Quellzugriff prüft `EXTENDED_EVENTS_FORENSICS_DEEP` und `@HighImpactConfirmed = 1`. |
| Standardpfad | Eine konfigurierte `system_health`-Eventdatei, ein Eventname, ein enges UTC-Fenster, 100 Zeilen und RAW ohne XML-Ausgabe ist der kleinste praktische Pfad; auch er kann mehrere Rollover-Dateien berühren. |
| Teuerster Pfad | breiter File-Wildcard ohne Zeit-/Eventfilter, `@MaxZeilen = 0`, große XML-Payloads plus JSON; alternativ ein großer Ring Buffer mit vollständiger XML-Zerlegung und bestätigtem Target-Flush |
| Haupttreiber | Zahl und Größe passender XEL-Dateien, Events und XML-Knoten, Zeit-/Eventselektivität, Sortierung, Payloadbreite und Ring-Buffer-Größe |
| Skalierung | Datei-I/O mit Rolloverbestand; CPU und Speicher mit XML-Konvertierung/-Methoden und Sortierung; Transfer mit Event XML, SQL-Text, JSON und Zeilenzahl |
| Ressourcen | Dateisystem-/Storage-I/O des SQL-Server-Prozesses, CPU, Memory Grant, XML-Speicher, Temp-Strukturen und Netzwerk-/Clienttransfer |
| Begrenzungswirkung | `TOP (@MaxZeilen)` begrenzt zurückgehaltene Rohzeilen, garantiert bei `fn_xe_file_target_read_file` plus `ORDER BY` aber keinen entsprechend kleinen physischen XEL-Scan. Ring-Buffer-XML wird vor der TOP-Auswahl als Targetdaten gelesen. `@MitEventXml = 0` spart nicht die XML-Materialisierung. |
| Locking und Nebenwirkungen | keine Benutzertabellenänderung und `LOCK_TIMEOUT 0`; File-Lesen erzeugt I/O. Das Ausführen von `sys.dm_xe_session_targets` kann gesammelte Sessiondaten auf Disk flushen und wird deshalb separat bestätigt. |
| Schutzmechanismus | Analyseklasse, `@HighImpactConfirmed`, endliches Defaultlimit, Zeit-/Eventfilter sowie zusätzlich `@BestaetigeTargetFlush` für Ring Buffer; kein Byte- oder Dateizahllimit |
| Sicherer Einsatz | zuerst `@Hilfe`, dann enges File-Fenster in RAW, SourceStatus prüfen; Pfadgröße vor breiter Forensik abschätzen und Ring Buffer nur mit bewusst akzeptiertem Flush lesen |
| Aussagegrenze | Capturekonfiguration, Drops, Rollover und Retention begrenzen Historie. TOP/Regex können passende ältere Events verdrängen; generische Feldextraktion ist eventabhängig und kein vollständiger Payloadvertrag. |

## Technische Vertiefung

[Gemeinsames Execution-, Zeit- und Evidenzmodell](../Technical_Foundations.md)

### Leitfrage

Welche Ereignisse wurden von der konkret benannten XE-Session erfasst, sind im gewählten Target noch vorhanden und lassen sich innerhalb des bestätigten UTC-Scope belastbar korrelieren?

### Technischer Hintergrund

Ein Event-File-Target schreibt binäre XEL-Dateien mit Rollover. `sys.fn_xe_file_target_read_file` stellt ihre Eventzeilen bereit. Ein Ring Buffer hält XML im Speicher; die Runtime-DMV liefert Targetdaten, deren Lesen laut Microsoft einen Flush gesammelter Sessiondaten auf Disk erzwingen kann. Beide Targets sind begrenzte Capturequellen, keine vollständige Enginehistorie.

Event XML ist schemaflexibel: Datafelder und Actions hängen vom Event und von der Sessiondefinition ab. Die Procedure toleriert fehlende Knoten und projiziert häufige Felder. Eine fehlende Projektion kann daher nur mit dem Roh-XML und der Eventdefinition eingeordnet werden.

### Datenkette

1. Parameter werden normalisiert; der High-Impact-Pfad wird vor Katalog-, Datei- oder Runtime-Targetzugriff geprüft.
2. Server-XE-Kataloge suchen den konfigurierten `event_file`-Pfad der benannten Session.
3. `AUTO` wählt bevorzugt EVENT_FILE und nur bei bestätigtem Flush ersatzweise RING_BUFFER.
4. Ein `.xel`-Pfad wird in einen `*.xel`-Wildcardpfad umgewandelt; ein Pfad ohne Wildcard erhält `*.xel` angehängt.
5. Filezeilen werden nach Eventname und UTC gefiltert, nach Timestamp/Datei/Offset absteigend sortiert, mit TOP begrenzt und in XML konvertiert.
6. Beim Ring Buffer wird `target_data` einmal als XML gelesen und über `/RingBufferTarget/event` zerlegt; TOP wirkt auf die sortierten Knoten.
7. Regex wirkt nach der Materialisierung. Anschließend werden häufige Data-/Actionknoten für RAW/JSON extrahiert; SourceStatus dokumentiert den Quellenpfad.
8. CONSOLE und TABLE verwenden die Rohmenge, RAW/JSON die angereicherte Projektion.

### Source Select

Das reduzierte Grundselect zeigt den EVENT_FILE-Pfad mit den kostentragenden Prädikaten:

```sql
SELECT TOP (@MaxZeilen)
      [x].[timestamp_utc]
    , [x].[object_name]
    , [x].[file_name]
    , [x].[file_offset]
    , TRY_CAST([x].[event_data] AS xml) AS [EventXml]
FROM [sys].[fn_xe_file_target_read_file]
     (@EventFilePattern, NULL, NULL, NULL) AS [x]
WHERE [x].[timestamp_utc] >= @VonUtc
  AND (@EventName IS NULL OR [x].[object_name] = @EventName)
ORDER BY [x].[timestamp_utc] DESC,
         [x].[file_name] DESC,
         [x].[file_offset] DESC;
```

**Wichtig für die Eigenlast:** Möglichst enger Wildcardpfad, Zeitfenster und Eventname sind wichtiger als `TOP`. XML-Data-/Action-Knoten erst für die materialisierten Kandidaten extrahieren; Regex wirkt später und spart keinen XEL-Lesezugriff.

### Zeit- und Scope-Modell

Jede Zeile ist ein Einzelereignis mit UTC-Timestamp innerhalb der noch vorhandenen Targetretention. `@VonUtc` ist inklusive, `@BisUtc` exklusiv. Die Historiengrenze wird durch Sessionstart, Eventdefinition, Predicate, Dispatch/Flush, mögliche Drops, Ring-Buffer-Kapazität sowie Filegröße, Rollover und externe Dateiaufbewahrung bestimmt. Es gibt keinen Engine-Restart-unabhängigen Vollständigkeitsanspruch.

### Bewertung und Gegenprobe

Bestätigen Sie zuerst SourceStatus und Retentionsscope. Sichern Sie danach Eventtimestamp, Eventtyp und Quellposition. Werten Sie Payloadfelder nur eventbezogen aus. Bestätigen Sie Deadlocks mit dem spezialisierten Parser und betroffenen Query- oder Transaktionsquellen, Fehler mit Error Log, Query Store oder Anwendungstelemetrie und Wait- oder Schedulerereignisse mit Live- oder kumulativer DMV-Evidenz. Eine zweite Quelle muss denselben Zeitraum abdecken.

### Typische Fehlinterpretation

Keine Eventzeile bedeutet nicht „kein Ereignis“. Ein Dateiname ist nicht automatisch die vollständige Rollovermenge. `DurationRaw` ist nicht pauschal Millisekunden. `@MitEventXml = 0` bedeutet in der aktuellen Implementierung nicht „kein XML gelesen“. Ein bestätigter Ring-Buffer-Lauf ist kein nebenwirkungsfreier DMV-Snapshot.

### Folgeanalyse

Verwenden Sie abhängig vom Ereignistyp die folgenden Folgeanalysen:

- Deadlocks: `USP_ExtendedEventsDeadlocks`
- Blocked-Process-Reports: `USP_ExtendedEventsBlockedProcesses`
- Session-/Targetzustand und Drops: `USP_ExtendedEventsSessions` sowie `USP_ExtendedEventsTargetRuntime`
- Queryverlauf: Query Store oder Plananalyse mit Query-/Plan-Hash aus der Payload
- Unzureichende Retention: neue, eng definierte XE-Captureplanung mit geprüftem Speicher-/Filebudget

## Primärquellen

- [sys.fn_xe_file_target_read_file](https://learn.microsoft.com/en-us/sql/relational-databases/system-functions/sys-fn-xe-file-target-read-file-transact-sql?view=sql-server-ver17)
- [sys.dm_xe_session_targets](https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-views/sys-dm-xe-session-targets-transact-sql?view=sql-server-ver17)
- [Targets for Extended Events](https://learn.microsoft.com/en-us/sql/relational-databases/extended-events/targets-for-extended-events-in-sql-server?view=sql-server-ver17)

[Technische Detailbeschreibung](../06_Extended_Events.md#2-monitorusp_extendedeventsreadevents)
