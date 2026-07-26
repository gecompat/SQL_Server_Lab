# [monitor].[USP_ObjectInventory]

**Bereich:** Object und Index<br>
**Zweck:** Liefert Objekt- und Indexinventar mit Größe, Zeilen, Partitionierung, Kompression, Definition und capability-adaptiven JSON-Index-/Pfadmetadaten.<br>
**Beobachtungsart:** Katalogsnapshot<br>
**Kostenklasse:** LOW–HIGH_OPT_IN

## Entscheidungsfrage und Einsatz

Die Procedure beantwortet die Betriebsfrage: **Welche Objekte und physischen Zugriffsstrukturen existieren, wie groß sind sie und welche Eigenschaften besitzen sie?** Sie unterstützt die Entscheidung, ob ein Struktur- oder Metadatensignal eine workloadbezogene Gegenprüfung rechtfertigt, nicht ob automatisch DDL ausgeführt werden soll.

## Nicht beantwortete Fragen

Die Procedure beantwortet keinen Geschäftsnutzen einer Strukturänderung, keine repräsentative Workload und keine automatische Aussage über den optimalen Index- oder Statistikzustand. Der Zeitvertrag ist im Abschnitt „Zeit- und Scope-Modell“ konkretisiert. Ein Einzelwert gilt daher nur für diesen Scope und Zeitpunkt; er belegt weder eine Ursache noch eine Entwicklung.

## Sicherer Einstieg

```sql
EXEC [monitor].[USP_ObjectInventory]
      @DatabaseNames = N'[ExampleDatabase]',
      @SchemaNames = N'[ExampleSchema]',
      @ObjectNames = N'[ExampleTable]',
      @ResultSetArt = 'CONSOLE';
```

Alle `Example*`-Werte im Aufruf sind synthetisch.

## Resultsets und Leserichtung

Der typisierte TABLE-Vertrag registriert `objects`. Status, Scope und Warnings sind vor den Fachergebnissen zu lesen. CONSOLE dient der interaktiven Triage; RAW und JSON erhalten den technischen Kontext, während TABLE nur die ausdrücklich benannten stabilen Resultsets schreibt. Resultsets mit unterschiedlicher Zeilengranularität dürfen nicht ungeprüft vereinigt oder summiert werden.

Auf SQL Server 2025 ergänzt `objects` die Felder `IsJsonIndex`,
`OptimizeForArraySearch`, `JsonPathCount`, `JsonPaths`,
`JsonIndexStatusCode` und `JsonIndexEvidenceLimit`. `databaseStatus` trennt
Version, Buildfähigkeit, Pflichtschema, Sichtbarkeit und behandelte
Quellenfehler. Vor SQL Server 2025 lautet der Status
`UNAVAILABLE_VERSION`; die beiden neuen Systemquellen werden dort nicht
referenziert.

## Eine Zeile bedeutet

Eine Inventarzeile beschreibt typischerweise eine Objekt-/Index-Kombination. Objektgesamtwerte können deshalb je Index wiederholt erscheinen.

## So lesen

Berücksichtigen Sie zuerst die Objektgröße und die Zeilenanzahl, danach Indexart, Schlüssel und Includes, Partitionierung, Kompression und Sonderzustände.

## Warum kann das problematisch sein?

Große deaktivierte, hypothetische oder redundante Indizes können Speicher- und Wartungskosten erzeugen. Die Definition allein beweist aber keine Entbehrlichkeit.

## Wann ist es kein Problem?

Gemischte Kompression oder ähnliche Indizes können Teil einer Hot-/Cold-, Constraint- oder Coverage-Strategie sein.

## Beispiele und Gegenbeispiele

**Synthetischer Problemfall (`Example*`):** Zwei Indizes besitzen gleiche Schlüssel, aber einer sichert eine Unique Constraint. Er darf nicht wie ein normaler Duplikatindex behandelt werden. Prüfen Sie Usage, Operational Stats und Pläne.

**Ähnlich aussehender Gegenfall:** Gemischte Kompression oder ähnliche Indizes können Teil einer Hot-/Cold-, Constraint- oder Coverage-Strategie sein. Der gleiche Einzelwert kann deshalb bei `ExampleDb` ohne Nutzerauswirkung unkritisch sein, während er bei zeitgleicher SLA-Verletzung eine Vertiefung rechtfertigt.

## Leere oder partielle Ausgabe

Bei Katalogpfaden sind Featureabwesenheit, Filter, Offline-/Permission-Scope und tatsächlich fehlende Objekte getrennte Erklärungen.

Für JSON-Indizes bedeutet `AVAILABLE_EMPTY_OR_RESTRICTED`, dass im
angeforderten sichtbaren Scope keine Indexzeile entstand. Dieser Zustand
beweist wegen Metadata Visibility keine serverweite Featureabwesenheit.
`AVAILABLE_LIMITED` erhält eine sichtbare Indexdefinition, weist aber eine
fehlende, schemaabweichende oder nicht lesbare Pfadquelle ausdrücklich aus.

Für `USP_ObjectInventory` gilt zusätzlich: **keine Zeile** bedeutet, dass im sichtbaren und gefilterten Scope kein ausgabefähiger Datensatz entstand. **0** ist ein gemessener Nullwert nur dann, wenn die Quellspalte tatsächlich verfügbar war. **NULL** bedeutet unbekannt, nicht anwendbar oder nicht auflösbar. **PARTIAL/Warning** bedeutet, dass mindestens eine Teilquelle, Datenbank oder Detailstufe fehlt. Ein Limit kann eine nichtleere Quelle vollständig aus dem sichtbaren Ausschnitt verdrängen.

## Eigenlast und Grenzen

**Quellcode-Hinweis zur Eigenlast:** Eine gezielte Abfrage einer einzelnen Datenbank besitzt eine geringe bis moderate Eigenlast; Cross-Database-Abfragen und Spaltenlisten werden durch TOP begrenzt.

| Dimension | Aussage für diese Procedure |
|---|---|
| Kostenklasse | LOW–HIGH_OPT_IN |
| Standardpfad | Eine explizit benannte `ExampleDatabase` und ein Objekt im Modus `GEZIELT`; Indizes und Spaltenlisten bleiben auf diesen Kandidatenscope begrenzt. |
| Teuerster Pfad | Cross-Database-`VOLL`, `@MaxZeilen = 0`, alle Objekttypen sowie Index-/Spaltenlisten bei sehr vielen Objekten und Indexspalten. |
| Haupttreiber | Zahl gewählter Datenbanken, Objekte, Indizes, Indexspalten, Partitionen und Allocation Units. Objektfilter reduzieren den dynamischen Katalogpfad früh; Definitionstexte und breite Cross-Database-Inventare erhöhen TempDB- und Transferbedarf. |
| Skalierung | Laufzeit und CPU wachsen mit dem Haupttreiber. Sortierung/Aggregation erhöht Speicher- und gegebenenfalls TempDB-Bedarf; breite Texte/XML sowie viele Zeilen erhöhen Netzwerk- und Clientkosten. Für USP_ObjectInventory ist insbesondere die im Datenkettenabschnitt beschriebene Reihenfolge maßgeblich. |
| Ressourcen | CPU, Katalogseiten und TempDB für Joins/Aggregation; bei breitem Cross-Database-Scope zusätzlicher Compile- und Ergebnistransferaufwand. |
| Begrenzungswirkung | Datenbank-/Objektfilter begrenzen die Quellarbeit. TOP oder MaxZeilen werden häufig nach Katalogjoins und Aggregation angewandt und sind dann nur Ausgabelimits. |
| Locking und Nebenwirkungen | Read-only; Katalogabfragen nehmen üblicherweise kurze Schema-Stability-Zugriffe und können mit gleichzeitigem DDL oder Datenbankstatuswechseln konkurrieren. Der konfigurierte `LOCK_TIMEOUT` gilt auch für die optionalen JSON-Quellen; der vorherige Sessionwert wird wiederhergestellt. |
| Schutzmechanismus | `OBJECT_ANALYSIS_CURRENT` schützt den gezielten Pfad ohne High-Impact-Pflicht. Nur `VOLL` prüft zusätzlich `CATALOG_DEEP` und benötigt `@HighImpactConfirmed = 1`; das Gate ersetzt keine Objekt-/Datenbankgrenze. |
| Sicherer Einsatz | Mit einer ExampleDb und einem ExampleObject starten; erst nach Größenprüfung auf mehrere Datenbanken oder VOLL erweitern. |
| Aussagegrenze | Scope- oder Zeilenbegrenzungen können relevante, seltene oder später einsortierte Zeilen ausblenden. Die Aussage bleibt auf das Modell „Katalogsnapshot“, die dokumentierte Granularität und den sichtbaren Quellenscope begrenzt; ein kleines Resultset ist weder automatisch vollständig noch repräsentativ. |

## Technische Vertiefung

[Gemeinsames Execution-, Zeit- und Evidenzmodell](../Technical_Foundations.md)

### Leitfrage

Welche Objekte und physischen Zugriffsstrukturen existieren, wie groß sind sie und welche Eigenschaften besitzen sie?

### Technischer Hintergrund

Tabellen, Views, Indizes, Spalten, Partitionen, Kompression und Allocation Units bilden mehrere Katalogebenen. Rowcount und reservierte/benutzte Seiten kommen typischerweise aus Partition Stats; Definition und Schutzmerkmale aus Objekt-/Indexkatalogen. Ein Unique Constraint oder Primary Key ist fachlich/relational geschützt, auch wenn ein Index technisch ähnlich zu einem anderen wirkt.

### Datenkette

`master.sys.databases`, `sys.allocation_units`, `sys.columns`, `sys.data_spaces`, `sys.index_columns`, `sys.indexes`, `sys.objects`, `sys.partitions`, `sys.schemas`, `sys.sp_executesql`, `sys.tables` sowie capability-abhängig `sys.json_indexes` und `sys.json_index_paths`.

Jede der beiden JSON-Quellen wird je Zieldatenbank und Procedureaufruf
höchstens einmal gelesen. Die Indexquelle bleibt auf den gewählten
Objektscope begrenzt; die Pfadquelle wird nur zu den bereits materialisierten
JSON-Indizes aggregiert. JSON-Dokumentwerte und Benutzertabellenzeilen werden
nicht gelesen.

### Source Select

Der Größenkern verbindet Objekt, Schema, Tabelle, Index, Partition und Allocation Unit:

```sql
SELECT
      [s].[name] AS [SchemaName]
    , [o].[name] AS [ObjectName]
    , [i].[name] AS [IndexName]
    , [p].[partition_number]
    , SUM([au].[total_pages]) * 8.0 / 1024.0 AS [ReservedMb]
FROM [sys].[objects] AS [o] WITH (NOLOCK)
JOIN [sys].[schemas] AS [s] WITH (NOLOCK)
  ON [s].[schema_id] = [o].[schema_id]
LEFT JOIN [sys].[indexes] AS [i] WITH (NOLOCK)
  ON [i].[object_id] = [o].[object_id]
LEFT JOIN [sys].[partitions] AS [p] WITH (NOLOCK)
  ON [p].[object_id] = [i].[object_id]
 AND [p].[index_id] = [i].[index_id]
LEFT JOIN [sys].[allocation_units] AS [au] WITH (NOLOCK)
  ON [au].[container_id] IN ([p].[hobt_id], [p].[partition_id])
WHERE [s].[name] = N'ExampleSchema'
  AND [o].[name] = N'ExampleObject'
GROUP BY [s].[name], [o].[name], [i].[name], [p].[partition_number];
```

**Wichtig für die Eigenlast:** Filtern Sie Schema und Objekt vor Partitionen, Allocation Units, Spalten und Indexspalten. Summieren Sie wegen mehrerer Allocation Units niemals ungeprüft Zeilen- oder Größenwerte über verschiedene Granularitäten.

### Zeit- und Scope-Modell

Die Auswertung beschreibt den aktuellen Metadaten- und Größenstand. Rowcounts aus DMVs sind für Diagnosezwecke geeignet, aber keine transaktional exakte `COUNT_BIG(*)`-Messung.

### Bewertung und Gegenprobe

Berücksichtigen Sie Größe, Zeilen, Indexart, Schlüssel/Includes, Filter, Partitionierung, Kompression und Schutzmerkmale gemeinsam. Ähnliche Schlüsselreihenfolgen können unterschiedliche Coverage, Sortierung oder Constraints bedienen.

### Typische Fehlinterpretation

Inventar zeigt Existenz, nicht Nutzen, Nutzung oder Redundanz. Eine kleine Tabelle mit vielen Indizes kann andere Trade-offs haben als eine große schreibintensive Tabelle. Insbesondere beweisen ein sichtbarer JSON-Index, seine Pfadzahl oder `OptimizeForArraySearch` weder passende Workloadabdeckung noch Gesundheit oder Rebuildbedarf.

### Folgeanalyse

Für die weitere Analyse gelten folgende Schritte und Quellen: `USP_IndexUsage`, `USP_IndexOperationalStats`, Query Store/Plan Cache und Abhängigkeitsprüfung.

## Primärquellen

- [SQL-Server-Katalogsichten](https://learn.microsoft.com/en-us/sql/relational-databases/system-catalog-views/catalog-views-transact-sql?view=sql-server-ver17)
- [sys.json_indexes (Transact-SQL)](https://learn.microsoft.com/en-us/sql/relational-databases/system-catalog-views/sys-json-indexes-transact-sql?view=sql-server-ver17)
- [sys.json_index_paths (Transact-SQL)](https://learn.microsoft.com/en-us/sql/relational-databases/system-catalog-views/sys-json-index-paths-transact-sql?view=sql-server-ver17)

## Weiterführende Vertiefung

Die folgenden Quellen ergänzen die Produktspezifikation um Praxis- oder Toolingperspektiven. Sie sind keine Grundlage für versions-, Berechtigungs- oder Engineaussagen dieser Seite.

- [Ola Hallengren: Index and Statistics Maintenance – betriebliche Wartungsperspektive](https://ola.hallengren.com/sql-server-index-and-statistics-maintenance.html)

[Technische Detailbeschreibung](../03_Object_Index.md#1-monitorusp_objectinventory)

[SQL-Server-2025-JSON-Index-Vertrag](../../Architecture/SQL_Server_2025_JSON_Index_Inventory.md)
