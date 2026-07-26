# [monitor].[USP_CreateExecutionEvidenceJson]

**Bereich:** Plan Cache und Showplan<br>
**Zweck:** Normalisiert bereits erfasste Plan-, STATISTICS-IO-, STATISTICS-TIME- und Statistik-/Histogrammevidenz in ein versioniertes JSON.<br>
**Beobachtungsart:** importierte oder gezielt ergänzte Ausführungsevidenz<br>
**Kostenklasse:** LOW bis HIGH_OPT_IN

## Entscheidungsfrage und Einsatz

Die Procedure ist passend, wenn vorhandene Laufzeitinformationen derselben oder einer nachvollziehbar zugeordneten Ausführung in ein gemeinsames Format überführt werden sollen. Sie führt die analysierte Query niemals aus. Der Standardmodus `DERIVED_ONLY` entfernt konkrete Parameter-, Predicate- und Histogrammgrenzwerte aus dem exportierbaren Ergebnis, nachdem eine mögliche lokale Zuordnung zu Histogrammschritten erfolgt ist.

## Nicht beantwortete Fragen

Das JSON beweist nicht automatisch, dass Plan, IO- und TIME-Meldungen aus derselben Ausführung stammen. Diese Beziehung wird über `SameExecutionConfidence` ausgewiesen. Ein aktueller Statistikzustand beweist zudem nicht, dass derselbe Zustand bei der Plankompilierung vorlag.

## Sicherer Einstieg

```sql
DECLARE @EvidenceJson nvarchar(max);
EXEC [monitor].[USP_CreateExecutionEvidenceJson]
      @StatisticsIoText = N'Table ''ExampleObject''. Scan count 1, logical reads 8, physical reads 0, read-ahead reads 0, lob logical reads 0.'
    , @StatisticsTimeText = N'SQL Server Execution Times: CPU time = 1 ms, elapsed time = 2 ms.'
    , @EvidenzDatenschutzModus = 'DERIVED_ONLY'
    , @ResultSetArt = 'NONE'
    , @Json = @EvidenceJson OUTPUT;
```

`@RawTextHandling = 'INCLUDE'` ist nur zusammen mit `@SensitiveDataConfirmed = 1` und `@IdentifierDatenschutzModus = 'RAW'` zulässig, weil Meldungsrohtext vertrauliche Werte und nicht zuverlässig einzeln anonymisierbare Identifikatoren enthalten kann. `TOKENIZED` erzeugt ausschließlich capture-lokale Tokens; `OMIT` und der Default `DERIVED_ONLY` geben weder Rohgrenzen noch Rohidentifikatoren aus.

## Resultsets und Leserichtung

`captureStatus` beschreibt Umfang, Partialität und Datenschutzmodus. Danach folgen `statisticsIo`, `statisticsTime`, `planStatisticsUsage`, `objectReferences`, optionale aktuelle Statistiken und Histogramme, Predicate-Mappings, Collection-Status und Warnings. TABLE exportiert ausschließlich ausdrücklich benannte Ziele.

## Eine Zeile bedeutet

Die Granularität hängt vom Resultset ab: eine Capture-Zusammenfassung, eine IO-Objektzeile, ein TIME-Block, eine verwendete Statistik, eine Objektreferenz, ein Histogrammschritt oder eine Mappingbeziehung. Diese Zeilen dürfen nicht ohne Statement- und Quellenbezug zusammengeführt werden.

## So lesen

Prüfen Sie zuerst `captureStatus`, `SameExecutionConfidence` und ParseStatus. Berücksichtigen Sie danach IO und TIME auf Statementebene. Bewerten Sie Statistik- und Histogrammevidenz erst mit Compilezeit, Capturezeit und Datenschutzstatus.

## Warum kann das problematisch sein?

Ohne ein gemeinsames Evidenzformat werden Planoperatoren, objektbezogene Reads und Gesamtlaufzeit leicht aus unterschiedlichen Ausführungen vermischt. Rohwerte können außerdem vertrauliche Geschäftsdaten enthalten.

## Wann ist es kein Problem?

Fehlende optionale Statistik- oder Histogrammabschnitte sind im Standardpfad normal. Für viele Planfragen reichen Operator- und Runtime-Counter aus. `NULL` bedeutet unbekannt oder nicht erhoben und nicht gemessene Null.

## Technische Vertiefung

[Gemeinsames Execution-, Zeit- und Evidenzmodell](../Technical_Foundations.md)

### Leitfrage

Welche zusätzliche Ausführungsevidenz ist vorhanden, wie sicher ist ihre Zuordnung und welche Werte dürfen exportiert werden?

### Technischer Hintergrund

`SET STATISTICS IO` und `SET STATISTICS TIME` liefern Meldungstext, kein relationales Resultset. Die Parser sind deshalb best effort und markieren unbekannte oder partielle Formate. Histogrammgrenzwerte und Parameterwerte werden erst nach lokaler Korrelation entfernt oder tokenisiert. Bereits vorhandenes Evidence JSON wird ebenfalls erneut normalisiert und nicht als vorab vertrauenswürdig behandelt.

### Datenkette

Bereits übergebenes Showplan XML, `TVF_ParseStatisticsIoText`, `TVF_ParseStatisticsTimeText`, Plan-Extractor-Funktionen und optional gezielte Statistik-/Histogrammmetadaten.

### Source Select

Die Procedure führt keinen Workload aus. Ein zentraler Extraktionspfad liest Objektbezüge direkt aus bereits übergebenem Showplan-XML:

```sql
SELECT
      [r].[StatementId]
    , [r].[NodeId]
    , [r].[DatabaseName]
    , [r].[SchemaName]
    , [r].[ObjectName]
    , [r].[IndexName]
FROM [monitor].[TVF_ExecutionPlanObjectReferences]
     (@PlanXml, @StatementId) AS [r];
```

**Wichtig für die Eigenlast:** Setzen Sie `@StatementId` vor der XML-Knotenextraktion und aktivieren Sie nur benötigte Evidenzpfade. Führen Sie Histogrammzugriffe erst nach der aus dem Plan abgeleiteten kleinen Statistikmenge aus; `@MaxStatistiken` und `@MaxHistogrammSchritte` begrenzen diese Vertiefung.

### Zeit- und Scope-Modell

Jeder Abschnitt besitzt einen eigenen Capture- oder Compilezeitbezug. Aktuelle Statistics Properties sind nicht rückwirkend der Compilezustand.

### Bewertung und Gegenprobe

Prüfen Sie Same-Execution-Status, Statementzuordnung, Planhash, Capturezeit und Parameterkontext gemeinsam. Bestätigen Sie bei importierter Evidenz die Quellumgebung ausdrücklich.

### Typische Fehlinterpretation

Ein geparster Textblock ist nicht automatisch derselben Planexecution zugeordnet. Ein tokenisierter oder ausgelassener Wert ist auch kein SQL-NULL.

### Folgeanalyse

Für die weitere Analyse gelten folgende Schritte und Quellen: `USP_ExecutionPlanAnalysis`, Query Store Runtime/Regression und gezielte Statistikverteilungsanalyse.

## Primärquellen

- [SET STATISTICS IO](https://learn.microsoft.com/en-us/sql/t-sql/statements/set-statistics-io-transact-sql?view=sql-server-ver17)
- [SET STATISTICS TIME](https://learn.microsoft.com/en-us/sql/t-sql/statements/set-statistics-time-transact-sql?view=sql-server-ver17)

[Technische Detailbeschreibung](../04_Plan_Cache.md#execution-evidence-json)
