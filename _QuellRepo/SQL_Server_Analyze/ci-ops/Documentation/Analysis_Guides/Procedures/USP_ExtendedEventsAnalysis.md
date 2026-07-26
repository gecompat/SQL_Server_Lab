# [monitor].[USP_ExtendedEventsAnalysis]

**Bereich:** Extended Events, Orchestrator<br>
**Zweck:** Orchestriert Inventar, Targetruntime, generische Events, Deadlocks und Blocked Processes.<br>
**Beobachtungsart:** nicht atomarer Mix aus Runtime-Snapshot und Ereignishistorie<br>
**Kostenklasse:** LOW–HIGH_OPT_IN

## Entscheidungsfrage und Einsatz

Die Procedure beantwortet die Betriebsfrage: **Welche XE-Konfigurations-, Runtime- und Ereignisperspektiven sollen gemeinsam geprüft werden?** Sie unterstützt die Entscheidung, ob die konfigurierte Ereignisquelle die gesuchte Situation erfasst hat und welche einzelne Datei, Session oder XML-Struktur anschließend vertieft wird.

## Nicht beantwortete Fragen

Die Procedure beantwortet keine Ereignisse, die nicht konfiguriert, vor Sessionstart aufgetreten oder durch Rollover/Targetgrenzen verloren gegangen sind. Der Zeitvertrag ist im Abschnitt „Zeit- und Scope-Modell“ konkretisiert. Ein Einzelwert gilt daher nur für diesen Scope und Zeitpunkt; er belegt weder eine Ursache noch eine Entwicklung.

## Sicherer Einstieg

```sql
EXEC [monitor].[USP_ExtendedEventsAnalysis]
      @MitSessionInventar = 1,
      @MitTargetRuntime = 0,
      @MitEvents = 0,
      @MitDeadlocks = 0,
      @MitBlockedProcesses = 0,
      @ResultSetArt = 'CONSOLE';
```

Alle `Example*`-Werte im Aufruf sind synthetisch.

## Resultsets und Leserichtung

Der typisierte TABLE-Vertrag registriert `moduleStatus`. Status, Scope und Warnings sind vor den Fachergebnissen zu lesen. CONSOLE dient der interaktiven Triage; RAW und JSON erhalten den technischen Kontext, während TABLE nur die ausdrücklich benannten stabilen Resultsets schreibt. Resultsets mit unterschiedlicher Zeilengranularität dürfen nicht ungeprüft vereinigt oder summiert werden.

## Eine Zeile bedeutet

Die Granularität hängt vom Child ab: Session, Target, Event, Deadlock, Prozess, Ressource oder Blocked-Process-Report.

## So lesen

Berücksichtigen Sie Inventar und Source-/Targetstatus vor Ereignisparsern. Childstatus bestimmt, ob leere Fachdaten interpretierbar sind.

## Warum kann das problematisch sein?

Deadlock- oder Blockinganalyse ohne verlässliche Quelle kann falsche Entwarnung erzeugen.

## Wann ist es kein Problem?

Nicht aktivierte Event-Children fehlen absichtlich.

## Beispiele und Gegenbeispiele

**Synthetischer Problemfall (`Example*`):** Session gestoppt und Deadlockresultset leer bedeutet „keine Evidenz erfasst“, nicht „keine Deadlocks“. Prüfen Sie Vorhandene XEL-Dateien oder Konfiguration.

**Ähnlich aussehender Gegenfall:** Nicht aktivierte Event-Children fehlen absichtlich. Der gleiche Einzelwert kann deshalb bei `ExampleDb` ohne Nutzerauswirkung unkritisch sein, während er bei zeitgleicher SLA-Verletzung eine Vertiefung rechtfertigt.

## Leere oder partielle Ausgabe

Eine laufende Session kann ohne passendes Ereignis leer sein; außerdem können Target, Dateipfad, Rollover, Flushzustand und Berechtigung die Sicht einschränken.

Für `USP_ExtendedEventsAnalysis` gilt zusätzlich: **keine Zeile** bedeutet, dass im sichtbaren und gefilterten Scope kein ausgabefähiger Datensatz entstand. **0** ist ein gemessener Nullwert nur dann, wenn die Quellspalte tatsächlich verfügbar war. **NULL** bedeutet unbekannt, nicht anwendbar oder nicht auflösbar. **PARTIAL/Warning** bedeutet, dass mindestens eine Teilquelle, Datenbank oder Detailstufe fehlt. Ein Limit kann eine nichtleere Quelle vollständig aus dem sichtbaren Ausschnitt verdrängen.

## Eigenlast und Grenzen

| Dimension | Aussage für diese Procedure |
|---|---|
| Kostenklasse | LOW–HIGH_OPT_IN |
| Standardpfad | Nur `USP_ExtendedEventsSessions` ist aktiviert. Er inventarisiert Definition und Laufzeitstatus mit `@MaxZeilen = 100`, liest aber weder Ereignisdateien noch Targetdaten. |
| Teuerster Pfad | `@MitTargetRuntime`, `@MitEvents`, `@MitDeadlocks` und `@MitBlockedProcesses` gemeinsam: Eventdatei oder Ring Buffer werden je Forensik-Child separat gelesen und XML mehrfach für unterschiedliche Granularitäten zerlegt. Targetruntime kann zusätzlich einen ausdrücklich bestätigten Target-Flush auslösen. |
| Haupttreiber | Größe und Rollover der gewählten XEL-Dateien beziehungsweise des Ring Buffers, Anzahl der Ereignisse im Zeitfenster und XML-Komplexität von Deadlock-/Blocked-Process-Reports. Das Sessioninventar ist gegenüber diesen Pfaden meist klein. |
| Skalierung | Die Children laufen nacheinander und teilen keinen materialisierten Ereignissnapshot. Drei aktivierte Ereignis-Children können dieselbe Quelle daher dreimal lesen und parsen; breite Reports erhöhen CPU, Arbeitsspeicher, TempDB und Transfer. |
| Ressourcen | Im Standard nur XE-Katalog-/Runtime-CPU. Optional kommen Datei-I/O über `sys.fn_xe_file_target_read_file`, Ring-Buffer-/Targetzugriff und XML-Shredding hinzu; `msdb` und Datenbankscans gehören nicht zu diesem Orchestrator. |
| Begrenzungswirkung | Session-/Event-/Targetfilter gelten nicht für jedes Child gleich: Inventarfilter steuern Katalogresultsets, die Forensikchildren verwenden die einzelne `@SourceExtendedEventSessionName`, Quelle, Datei und Zeitgrenzen. `@MaxZeilen` wird an Ereignischildren weitergegeben, begrenzt aber nicht zwingend das vorgelagerte Datei- und XML-Lesen; Targetruntime besitzt kein Parent-Zeilenlimit. |
| Locking und Nebenwirkungen | Keine Nutzdatenänderung. Nur der Targetruntimepfad kann durch das Lesen von `sys.dm_xe_session_targets` einen Flush bewirken; er benötigt deshalb zusätzlich `@BestaetigeTargetFlush = 1`. Die sequenziellen Childresultate sind kein atomarer Ereignissnapshot. |
| Schutzmechanismus | Ereignisforensik und Targetruntime prüfen `EXTENDED_EVENTS_FORENSICS_DEEP` über `@HighImpactConfirmed`. Für Targetruntime ist die Flushbestätigung ein zweites, unabhängiges Gate. Keiner der beiden Schalter ist ein Laufzeit- oder Mengenlimit. |
| Sicherer Einsatz | Zuerst nur das Inventar ausführen. Danach genau ein Forensik-Child, eine `ExampleSession`, einen engen UTC-Zeitraum und ein kleines `@MaxZeilen` wählen; Targetruntime erst nach bewusster Flushentscheidung aktivieren. |
| Aussagegrenze | Ein erfolgreiches Inventar beweist keine Ereigniserfassung. Ein begrenztes Ereignisresultset beschreibt nur die noch vorhandene gewählte Quelle; Rollover, Drops und ein spätes Zeilenlimit können relevante Events unsichtbar machen. Childresultate dürfen wegen getrennter Lesezeitpunkte nicht als transaktional konsistent behandelt werden. |

## Technische Vertiefung

[Gemeinsames Execution-, Zeit- und Evidenzmodell](../Technical_Foundations.md)

### Leitfrage

Welche XE-Konfigurations-, Runtime- und Ereignisperspektiven sollen gemeinsam geprüft werden?

### Technischer Hintergrund

Der Wrapper ruft Sessions, allgemeine Events, Deadlocks, Blocked Processes und Target Runtime auf. Eventlesen kann Datei-I/O und XML-Parsing verursachen; Filter/MaxRows begrenzen den Pfad.

### Datenkette

Die Datenkette besteht aus frameworkinterner Orchestrierung; die Quellen liegen in den Childmodulen.

### Source Select

Kein einzelnes Grundselect wird verwendet. Die Procedure orchestriert `USP_ExtendedEventsSessions`, `USP_ExtendedEventsTargetRuntime`, `USP_ExtendedEventsReadEvents`, `USP_ExtendedEventsDeadlocks` und `USP_ExtendedEventsBlockedProcesses`. Katalog-, Runtime-, Datei- und XML-Quellen bleiben bewusst getrennte Childpfade.

**Wichtig für die Eigenlast:** Berücksichtigen Sie zuerst nur das Sessioninventar. Aktivieren Sie Targetdaten, XEL-Dateien und XML-Forensik gezielt je Session und Zeitfenster; ein spätes Ergebnislimit ersetzt diese Quellbegrenzung nicht.

### Zeit- und Scope-Modell

Die Auswertung kombiniert den aktuellen Zustand und die Targethistorie nicht atomar.

### Bewertung und Gegenprobe

Bewerten Sie zuerst Session/Targetstatus, erst danach leere/gefüllte Ereignisresultsets. Vertiefen Sie Spezialevents nach Triage separat.

### Typische Fehlinterpretation

Ein leeres Gesamtbild kann durch deaktivierte Session oder Retention entstehen und ist keine Systemgesundheitsaussage.

### Folgeanalyse

Führen Sie das Child gezielt mit Session, Zeitraum, Eventname und einer begrenzten Dateimenge erneut aus.

## Primärquellen

- [Extended Events](https://learn.microsoft.com/en-us/sql/relational-databases/extended-events/extended-events?view=sql-server-ver17)

[Technische Detailbeschreibung](../06_Extended_Events.md#6-monitorusp_extendedeventsanalysis)
