# [monitor].[USP_VectorIndexAnalysis]

`USP_VectorIndexAnalysis` inventarisiert sichtbare Vector-Indizes auf SQL Server
2025 und korreliert sie mit dem aktuellen Zustand ihrer
Hintergrundwartung. Auf SQL Server 2019 und 2022 bleibt dieselbe Procedure
installierbar und liefert `UNAVAILABLE_VERSION`, ohne die neueren Systemobjekte
zu referenzieren.

## Eine Zeile bedeutet

Eine Zeile in `vectorIndexes` beschreibt genau einen für den aktuellen
Sicherheitskontext sichtbaren Vector-Index. Eine Zeile in `maintenance`
beschreibt die Korrelation desselben Index mit der aktuellen Runtime-DMV.
`findings` enthält nur einen begrenzten Reviewhinweis; es ist weder eine
Wartungsanweisung noch ein historischer Trend.

## So lesen

1. Zuerst `moduleStatus` auf Version, Partialität und `hasMore…` prüfen.
2. Danach in `sourceStatus` Katalog- und Runtimequelle getrennt lesen.
3. `vectorIndexes` für Typ, Distanzmetrik und Disabled-Status verwenden.
4. `maintenance` nur als Momentaufnahme interpretieren.
5. `findings` stets zusammen mit `EvidenceLimit` und
   `RecommendedNextCheck` lesen.

`AVAILABLE_EMPTY`, `NOT_ENABLED`, `UNAVAILABLE_VERSION`,
`UNAVAILABLE_FEATURE`, `DENIED_PERMISSION` und `NOT_RETURNED` sind
unterschiedliche Zustände. Ein leeres fachliches Array ersetzt diese
Unterscheidung nicht.

Der approximative Vector-Index-Pfad ist in SQL Server 2025 ein Previewfeature.
Auch bei Product Major Version 17 können `UNAVAILABLE_FEATURE` oder
`NOT_ENABLED` deshalb korrekt sein, wenn `PREVIEW_FEATURES` nicht aktiviert ist
oder der konkrete Build die beiden Systemobjekte nicht bereitstellt.

## Warum kann das problematisch sein?

Ein fehlgeschlagener Hintergrundtask kann dazu führen, dass Änderungen nicht
planmäßig in die Indexstruktur eingearbeitet werden. Anhaltend hohe ungefähre
Staleness kann zusammen mit hoher DML-Rate, schlechterem Recall oder
Performanceänderungen auf einen Wartungsrückstand hindeuten. Ein deaktivierter
Index kann außerdem erklären, warum eine erwartete approximative Suche nicht
verwendet wird.

## Wann ist es kein Problem?

Erhöhte Staleness während eines Batchloads kann vorübergehend normal sein.
Ein einzelner letzter Taskfehler kann durch einen späteren erfolgreichen Lauf
überholt sein. Eine fehlende DMV-Zeile beweist weder einen defekten Index noch
fehlende Katalogdefinition. Die Procedure empfiehlt deshalb keinen
automatischen Rebuild.

## Sicherer Einstieg

Das Beispiel verwendet ausschließlich synthetische Bezeichner:

```sql
DECLARE @Json nvarchar(max);

EXEC [monitor].[USP_VectorIndexAnalysis]
      @DatabaseNames = N'[ExampleDatabase]'
    , @FullObjectNames = N'[ExampleSchema].[ExampleTable]'
    , @StalenessReviewPercent = 15
    , @MaxZeilen = 100
    , @ResultSetArt = 'NONE'
    , @JsonErzeugen = 1
    , @Json = @Json OUTPUT;

SELECT @Json AS [VectorIndexAnalysisJson];
```

Für einen breiten Cross-Database-Aufruf sollte der Datenbankscope explizit
angegeben werden. `@MaxZeilen = 0` bedeutet unbegrenzt und ist für einen
Ersteinstieg nicht empfohlen.

## Technische Vertiefung

### Leitfrage

Welche Vector-Indizes sind im gewählten Scope sichtbar, welche aktuelle
Wartungsevidenz liefert SQL Server dazu, und welche Quelle ist vollständig
verfügbar?

### Technischer Hintergrund

Die Katalogsicht erbt die öffentlichen Indexspalten aus `sys.indexes` und
ergänzt Vector-Indextyp sowie Distanzmetrik. Die Runtime-DMV liefert
ungefähre Staleness, Key-Space-Nutzung und den letzten Hintergrundtask. Die
Procedure liest ausdrücklich keine internen `build_parameters`.

### Datenkette

Produktversion und Systemobjektschema werden zuerst geprüft. Danach wird
`sys.vector_indexes` einmal je Zieldatenbank in eine lokale Evidenztabelle
materialisiert. `sys.dm_db_vector_indexes` wird ebenfalls einmal gelesen und
lokal über `DatabaseId`, `ObjectId` und `IndexId` korreliert. Sämtliche
Ausgabearten projizieren dieselben lokalen Tabellen.

### Source Select

Das folgende verkürzte Grundmuster zeigt die fachliche Korrelation:

```sql
SELECT
      [v].[object_id]
    , [v].[index_id]
    , [v].[vector_index_type]
    , [v].[distance_metric]
    , [d].[approximate_staleness_percent]
    , [d].[last_background_task_succeeded]
FROM [sys].[vector_indexes] AS [v]
LEFT JOIN [sys].[dm_db_vector_indexes] AS [d]
  ON [d].[object_id]=[v].[object_id]
 AND [d].[index_id]=[v].[index_id];
```

**Wichtig für die Eigenlast:** Die Frameworkprocedure liest die beiden Quellen
nicht mit diesem kombinierten Beispiel mehrfach, sondern materialisiert jede
Quelle höchstens einmal pro Datenbank und Aufruf. Katalogfilter und
`@MaxZeilen` begrenzen Scope beziehungsweise Ausgabe.

### Zeit- und Scope-Modell

`CapturedAtUtc` ist der aufrufweite Erfassungszeitpunkt. Katalog und DMV werden
nicht in einer transaktionalen Momentaufnahme gelesen. Die Runtimewerte sind
aktuell und flüchtig; die Procedure persistiert keinen Verlauf.

### Bewertung und Gegenprobe

Staleness sollte über mehrere Zeitpunkte mit DML-Rate, Taskstatus sowie
messbarem Recall und Suchlaufzeit korreliert werden. Objektgröße und allgemeiner
Indexbestand lassen sich anschließend über `USP_ObjectAnalysis` gegenprüfen.

### Typische Fehlinterpretation

`VECTOR_STALENESS_REVIEW` bedeutet nicht „Index rebuilden“. Der
Standardgrenzwert von 15 Prozent ist ein konfigurierbarer Reviewauslöser, kein
universeller Qualitätsgrenzwert.

### Folgeanalyse

`USP_ObjectAnalysis` ergänzt Objekt- und Indexkontext. Der
`USP_SpecialFeatureInventory`-Pfad eignet sich davor als leichte Inventur
nativer Vector-Spalten.

## Primärquellen

- [sys.vector_indexes](https://learn.microsoft.com/en-us/sql/relational-databases/system-catalog-views/sys-vector-indexes-transact-sql?view=sql-server-ver17)
- [sys.dm_db_vector_indexes](https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-db-vector-indexes-transact-sql?view=sql-server-ver17)
- [CREATE VECTOR INDEX und SQL-Server-2025-Previewvoraussetzung](https://learn.microsoft.com/en-us/sql/t-sql/statements/create-vector-index-transact-sql?view=sql-server-ver17)

[Technische Detailbeschreibung](../../Architecture/SQL_Server_2025_Vector_Index_Analysis.md)  
[Gemeinsames Execution-, Zeit- und Evidenzmodell](../Technical_Foundations.md)
