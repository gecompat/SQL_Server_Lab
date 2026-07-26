# [monitor].[USP_CriticalEngineEvents]

**Bereich:** Server Health<br>
**Zweck:** Liest schwere Engine-Ereignisse aus system_health und optionalen Diagnosequellen.<br>
**Beobachtungsart:** retentionbegrenzte Ereignishistorie + Diagnostiksnapshot<br>
**Kostenklasse:** MEDIUM

## Entscheidungsfrage und Einsatz

Die Procedure beantwortet die Betriebsfrage: **Welche kritischen Engineereignisse sind in system_health, Ring Buffers oder Diagnostikquellen erhalten?** Sie unterstützt die Entscheidung, ob eine Instanzressource oder Konfiguration als belastbare Spur zum Symptom passt und welche unabhängige OS-, Verlaufs- oder Workloadevidenz fehlt.

## Nicht beantwortete Fragen

Die Procedure beantwortet keine vollständige OS-/Hypervisorursache und ohne Delta oder Verlauf keine belastbare Aussage über einen dauerhaften Engpass. Der Zeitvertrag ist im Abschnitt „Zeit- und Scope-Modell“ konkretisiert. Ein Einzelwert gilt daher nur für diesen Scope und Zeitpunkt; er belegt weder eine Ursache noch eine Entwicklung.

## Sicherer Einstieg

```sql
DECLARE @ExampleVonUtc datetime2(7) = DATEADD(HOUR, -24, SYSUTCDATETIME());

EXEC [monitor].[USP_CriticalEngineEvents]
      @VonUtc = @ExampleVonUtc,
      @MitEventXml = 0,
      @MaxZeilen = 100,
      @ResultSetArt = 'CONSOLE';
```

Alle `Example*`-Werte im Aufruf sind synthetisch.

## Resultsets und Leserichtung

Der typisierte TABLE-Vertrag registriert `events`. Status, Scope und Warnings sind vor den Fachergebnissen zu lesen. CONSOLE dient der interaktiven Triage; RAW und JSON erhalten den technischen Kontext, während TABLE nur die ausdrücklich benannten stabilen Resultsets schreibt. Resultsets mit unterschiedlicher Zeilengranularität dürfen nicht ungeprüft vereinigt oder summiert werden.

## Eine Zeile bedeutet

Eine Zeile entspricht einem erfassten Engine-Ereignis; SourceStatus beschreibt die Verfügbarkeit der Quelle.

## So lesen

Vergleichen Sie Eventtyp, Severity, Zeit, Quelle, Wiederholung und Begleitsymptome.

## Warum kann das problematisch sein?

Schwere Fehler, Schedulerprobleme oder Dumps können Engine-, Hardware- oder I/O-Risiken anzeigen.

## Wann ist es kein Problem?

Ein einzelnes altes Ereignis kann bereits behoben sein; aktuelle Wiederholung entscheidet über Dringlichkeit.

## Beispiele und Gegenbeispiele

**Synthetischer Problemfall (`Example*`):** Mehrere Severity-20+-Fehler in kurzer Zeit plus suspect pages sind deutlich kritischer als ein einzelnes altes Ereignis. Prüfen Sie Error Log, Integrität und Infrastruktur.

**Ähnlich aussehender Gegenfall:** Ein einzelnes altes Ereignis kann bereits behoben sein; aktuelle Wiederholung entscheidet über Dringlichkeit. Der gleiche Einzelwert kann deshalb bei `ExampleDb` ohne Nutzerauswirkung unkritisch sein, während er bei zeitgleicher SLA-Verletzung eine Vertiefung rechtfertigt.

## Leere oder partielle Ausgabe

Server-DMVs können plattform-, editions- oder berechtigungsbedingt fehlen. NULL und PARTIAL sind dann Evidenzgrenzen, keine Nullmessung.

Für `USP_CriticalEngineEvents` gilt zusätzlich: **keine Zeile** bedeutet, dass im sichtbaren und gefilterten Scope kein ausgabefähiger Datensatz entstand. **0** ist ein gemessener Nullwert nur dann, wenn die Quellspalte tatsächlich verfügbar war. **NULL** bedeutet unbekannt, nicht anwendbar oder nicht auflösbar. **PARTIAL/Warning** bedeutet, dass mindestens eine Teilquelle, Datenbank oder Detailstufe fehlt. Ein Limit kann eine nichtleere Quelle vollständig aus dem sichtbaren Ausschnitt verdrängen.

## Eigenlast und Grenzen

**Quellcode-Hinweis zur Eigenlast:** Das begrenzte Lesen von Eventfiles besitzt die Kostenklasse MEDIUM; der XML-Transfer ist ein Opt-in.

| Dimension | Aussage für diese Procedure |
|---|---|
| Kostenklasse | MEDIUM |
| Standardpfad | Löst den `system_health`-Eventfilepfad auf, liest bis zu 500 passende schwere Ereignisse aus dessen Rolloverdateien und parst die benötigten XML-Felder. `@MitEventXml = 0` unterdrückt nur die vollständige XML-Ausgabe. |
| Teuerster Pfad | `@MaxZeilen = 0`, vollständige Event-XML und optional `sp_server_diagnostics`; XEL-Rollover-Dateien können vor TOP breit gelesen werden. |
| Haupttreiber | Zahl/Größe der durch den Wildcardpfad erfassten XEL-Rolloverdateien und passende Events im UTC-Fenster. `sp_server_diagnostics` ist ein einzelner zusätzlicher One-Shot-Aufruf. |
| Skalierung | XEL-Lesen kann mit der Rollovermenge wachsen, auch wenn TOP nur wenige neueste Treffer behält. XML wird für die ausgewählten Events immer in Fehler-, Severity-, Komponenten- und Meldungsfelder zerlegt; vollständige XML-Ausgabe erhöht danach primär Speicher/Transfer. |
| Ressourcen | Datei-I/O über das SQL-Server-Dienstkonto, CPU/Speicher für XML-Parsing, TempDB/Transfer für zerlegte Ereignisse. |
| Begrenzungswirkung | Expliziter `@FilePath` und UTC-Fenster bestimmen die relevante Quelle; `@MaxZeilen` ist TOP im gefilterten XEL-CTE, garantiert aber keinen frühen physischen Rollover-Stopp. `@MinErrorSeverity` wirkt erst nach dem TOP/Parsing auf `error_reported`. |
| Locking und Nebenwirkungen | Keine Änderung an XE-Sessions. Filezugriff konkurriert mit Storage-I/O; Runtimequellen sind flüchtig. Ein einmaliger server_diagnostics-Aufruf liest aktuellen Zustand. |
| Schutzmechanismus | Diese Procedure besitzt trotz XEL-Lesen kein High-Impact-Gate. Schutz liefern eine konkrete Quelle, ein enges UTC-Fenster, Severity-/Eventfilter, endliches Limit sowie ausgeschaltete Voll-XML- und Server-Diagnostics-Ausgabe; TOP garantiert dennoch keinen kleinen physischen Rollover-Scan. |
| Sicherer Einsatz | Standardlimit und `@MitEventXml = 0` beibehalten; `sp_server_diagnostics` nur bei konkreter Fragestellung aktivieren und breite XEL-Läufe betrieblich abstimmen. |
| Aussagegrenze | `system_health` enthält nur konfigurierte und noch nicht gerollte Ereignisse. TOP wird vor dem Severityfilter angewandt, sodass viele neuere niedrigere Fehler ältere relevante Fehler aus dem Kandidatenset verdrängen können; der Diagnostics-One-Shot ist ein anderer Messzeitpunkt. |

## Technische Vertiefung

[Gemeinsames Execution-, Zeit- und Evidenzmodell](../Technical_Foundations.md)

### Leitfrage

Welche kritischen Engineereignisse sind in system_health, Ring Buffers oder Diagnostikquellen erhalten?

### Technischer Hintergrund

`system_health` erfasst ausgewählte Errors, Scheduler-/Memory-/Connectivity-/Deadlock- und Diagnoseereignisse. Ring Buffers/`sp_server_diagnostics` liefern Component States und begrenzte Historie. Event XML/Datafelder sind versionsabhängig.

### Datenkette

`sys.fn_xe_file_target_read_file`, `sys.server_event_session_fields`, `sys.server_event_session_targets`, `sys.server_event_sessions`, `sys.sp_server_diagnostics`.

### Source Select

Der XE-Dateipfad liest nur die relevanten System-Health-Events im benötigten Zeitfenster:

```sql
SELECT
      [x].[timestamp_utc]
    , [x].[object_name]
    , TRY_CAST([x].[event_data] AS xml) AS [EventXml]
FROM [sys].[fn_xe_file_target_read_file]
     (@EventFilePattern, NULL, NULL, NULL) AS [x]
WHERE [x].[object_name] IN
      (N'error_reported', N'scheduler_monitor_non_yielding_ring_buffer_recorded')
  AND [x].[timestamp_utc] >= @VonUtc;
```

**Wichtig für die Eigenlast:** Zeitfenster und Eventnamen beim Dateizugriff einschränken, bevor XML zerlegt wird. `sys.sp_server_diagnostics` ist ein separater aktueller Snapshot und keine zweite Dateiquelle.

### Zeit- und Scope-Modell

Die Auswertung berücksichtigt nur erhaltene Ereignisse seit der Session-, Engine- oder Rollovergrenze und den aktuellen Diagnostikstatus.

### Bewertung und Gegenprobe

Korrelieren Sie Eventtyp, Severity und State, Timestamp, Component, Wiederholung sowie gleichzeitige Errorlog-, Betriebssystem- und Clusterereignisse. Behandeln Sie Scheduler Non-Yielding, Memory Error und I/O Stall als unterschiedliche Ereignisklassen.

### Typische Fehlinterpretation

Keine Zeile ist keine Entwarnung. system_health ist bewusst begrenzt und kann Rollover/Targets verlieren.

### Folgeanalyse

Für die weitere Analyse gelten folgende Schritte und Quellen: XE Target Runtime/Read Events, Errorlog, OS/Cluster/Storagediagnostik.

## Primärquellen

- [system_health session](https://learn.microsoft.com/en-us/sql/relational-databases/extended-events/use-the-system-health-session?view=sql-server-ver17)

[Technische Detailbeschreibung](../08_Server_Health.md#14-monitorusp_criticalengineevents)
