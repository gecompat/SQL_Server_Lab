# Einsatzszenarien und Auswertung

Wenn die passende Procedure noch nicht bekannt ist, verwenden Sie zuerst [Hier beginnen](../Analysis_Guides/Start_Here.md) oder die direkte Suche:

```sql
EXEC [monitor].[USP_AnalysisNavigator]
      @Suchbegriff = N'Etwas ist jetzt langsam';
```

Der Navigator führt keinen der folgenden Analysepfade automatisch aus.

## Akute Langsamkeit

1. `EXEC monitor.USP_CurrentOverview;`
2. `EXEC monitor.USP_CurrentWaits @SampleSeconds=15;`
3. `EXEC monitor.USP_CurrentBlocking;`
4. `EXEC monitor.USP_QueryStats;`

Interpretieren Sie Waits als Wegweiser und nicht als alleinige Ursache. `LOCKING` führt zur Blocking- und Transaktionsanalyse, `STORAGE_DATA_IO` zu File-Latenzen und Read-Mustern, `CPU_SCHEDULER` zu Runnable Queue und Top-CPU-Plänen sowie `MEMORY` zu Grants und Cardinality.

## Wait-Stats-Auswertung

- Aktuelle Tasks beantworten „Was wartet jetzt?“.
- `INSTANCE_DELTA` beantwortet „Wo wurde im Messfenster gewartet?“.
- `INSTANCE_CUMULATIVE` ist nur Langzeitkontext.
- `MEASUREMENT_RESET` bedeutet, dass Sie das Sample verwerfen und erneut messen müssen.
- Bei `IsGenerallyBenign=1` sollten Sie den Wait standardmäßig nicht als Problem priorisieren.
- `DescriptionQuality=FRAMEWORK_CURATED`: Name und Frameworkbeschreibung wurden gegen die dokumentierte Primärquelle geprüft; konkrete hohe Deltas bleiben dennoch im Versions- und Workload-Kontext zu bewerten.

## TempDB

`EXEC monitor.USP_CurrentTempDB;` zeigt aktuelle Nutzung. `EXEC monitor.USP_TempDBConfiguration;` zeigt Datei-/Growth-Konfiguration. Prozentuales Growth und stark ungleiche Datendateien sind Review-Kandidaten, aber keine automatische Änderungsanweisung.

## Server Health

`EXEC monitor.USP_ServerHealthAnalysis;` liefert eine Statusübersicht. Für die Vertiefung stehen `USP_ServerCpuTopology`, `USP_ServerNuma`, `USP_ServerMemory`, `USP_TempDBConfiguration`, `USP_ServerConfiguration`, `USP_OSInformation` und `USP_ServerSecurityConfiguration` zur Verfügung.

## Versionsadaptive Features

`EXEC monitor.USP_ServerFeatureCapabilities;` zeigt `AVAILABLE`, `UNAVAILABLE_VERSION`, `UNAVAILABLE_PLATFORM` oder Fallbackpfade. Nicht verfügbare Zusatzdetails dürfen die allgemeine Diagnose nicht abbrechen.

<!-- BEGIN STATEMENT_KONTEXT -->
## Laufendes Modul und exaktes Statement

Der Standardaufruf ist für die Ad-hoc-Analyse formatiert:

```sql
EXEC [monitor].[USP_CurrentRequests];
```

Die Hauptausgabe zeigt bei persistenten Modulen den vollständig qualifizierten Modulnamen, den exakten über die Request-Offsets abgegrenzten Statementtext, den Zeilenbereich im Batch beziehungsweise Modul und die Byte-Offsets. Ein separates `SQL-Kontext`-Resultset enthält zusätzlich Objekt-IDs, Query-/Plan-Hashes und Handles.

Der vollständige Batch beziehungsweise persistente Modultext und der ursprüngliche Input Buffer sind bewusst opt-in:

```sql
EXEC [monitor].[USP_CurrentRequests]
      @GesamtenSqlTextEinbeziehen = 1
    , @InputBufferEinbeziehen = 1
    , @MaxSqlTextZeichen = 0;
```

`@MaxSqlTextZeichen = 0` oder `NULL` bedeutet vollständige Textausgabe. Ein positiver Wert begrenzt nur die Darstellung, nicht die Statement-Ermittlung.
<!-- END STATEMENT_KONTEXT -->
