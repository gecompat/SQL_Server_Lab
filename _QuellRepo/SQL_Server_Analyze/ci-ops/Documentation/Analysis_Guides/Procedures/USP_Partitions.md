# [monitor].[USP_Partitions]

**Bereich:** Object und Index<br>
**Zweck:** Zeigt partitionsgenaue Größe, Grenzen, Ablage und Kompression.<br>
**Beobachtungsart:** Katalogsnapshot<br>
**Kostenklasse:** LOW–HIGH_OPT_IN

## Entscheidungsfrage und Einsatz

Die Procedure beantwortet die Betriebsfrage: **Wie verteilen Partition Function und Scheme Daten über Partitionen und Storage, und sind Grenzen/Lebenszyklus plausibel?** Sie unterstützt die Entscheidung, ob ein Struktur- oder Metadatensignal eine workloadbezogene Gegenprüfung rechtfertigt, nicht ob automatisch DDL ausgeführt werden soll.

## Nicht beantwortete Fragen

Die Procedure beantwortet keinen Geschäftsnutzen einer Strukturänderung, keine repräsentative Workload und keine automatische Aussage über den optimalen Index- oder Statistikzustand. Der Zeitvertrag ist im Abschnitt „Zeit- und Scope-Modell“ konkretisiert. Ein Einzelwert gilt daher nur für diesen Scope und Zeitpunkt; er belegt weder eine Ursache noch eine Entwicklung.

## Sicherer Einstieg

```sql
EXEC [monitor].[USP_Partitions]
      @DatabaseNames = N'[ExampleDatabase]',
      @ResultSetArt = 'CONSOLE';
```

Alle `Example*`-Werte im Aufruf sind synthetisch.

## Resultsets und Leserichtung

Der typisierte TABLE-Vertrag registriert `partitions`. Status, Scope und Warnings sind vor den Fachergebnissen zu lesen. CONSOLE dient der interaktiven Triage; RAW und JSON erhalten den technischen Kontext, während TABLE nur die ausdrücklich benannten stabilen Resultsets schreibt. Resultsets mit unterschiedlicher Zeilengranularität dürfen nicht ungeprüft vereinigt oder summiert werden.

## Eine Zeile bedeutet

Eine Zeile entspricht einer Partition eines Indexes oder Heaps. Ein Objekt mit mehreren Indizes besitzt entsprechend mehrere Zeilen je Partitionsnummer.

## So lesen

Vergleichen Sie RowCount und Größe je Partition, Grenzintervalle, Filegroup, Kompression und Indexausrichtung.

## Warum kann das problematisch sein?

Ungünstige Grenzen oder nicht ausgerichtete Indizes können Partition Elimination, Switching und Wartung verhindern. Extreme Schieflage kann Hotspots bilden.

## Wann ist es kein Problem?

Leere Randpartitionen und ungleiche Größen sind bei Sliding-Window- oder Hot-/Cold-Design häufig beabsichtigt.

## Beispiele und Gegenbeispiele

**Synthetischer Problemfall (`Example*`):** Eine leere zukünftige Monatspartition ist normal. Eine aktuelle Partition mit 95 % aller Zeilen und fehlender Elimination verlangt Plan-, Statistik- und Designprüfung.

**Ähnlich aussehender Gegenfall:** Leere Randpartitionen und ungleiche Größen sind bei Sliding-Window- oder Hot-/Cold-Design häufig beabsichtigt. Der gleiche Einzelwert kann deshalb bei `ExampleDb` ohne Nutzerauswirkung unkritisch sein, während er bei zeitgleicher SLA-Verletzung eine Vertiefung rechtfertigt.

## Leere oder partielle Ausgabe

Bei Katalogpfaden sind Featureabwesenheit, Filter, Offline-/Permission-Scope und tatsächlich fehlende Objekte getrennte Erklärungen.

Für `USP_Partitions` gilt zusätzlich: **keine Zeile** bedeutet, dass im sichtbaren und gefilterten Scope kein ausgabefähiger Datensatz entstand. **0** ist ein gemessener Nullwert nur dann, wenn die Quellspalte tatsächlich verfügbar war. **NULL** bedeutet unbekannt, nicht anwendbar oder nicht auflösbar. **PARTIAL/Warning** bedeutet, dass mindestens eine Teilquelle, Datenbank oder Detailstufe fehlt. Ein Limit kann eine nichtleere Quelle vollständig aus dem sichtbaren Ausschnitt verdrängen.

## Eigenlast und Grenzen

**Quellcode-Hinweis zur Eigenlast:** Die Procedure aggregiert Katalog- und Allocation-Unit-Daten; VOLL ist gruppengeschützt und begrenzt.

| Dimension | Aussage für diese Procedure |
|---|---|
| Kostenklasse | LOW–HIGH_OPT_IN |
| Standardpfad | Eine explizit benannte `ExampleDatabase` und ein Objekt in `GEZIELT`; Partitions-, Allocation-Unit- und Data-Space-Kataloge werden aggregiert. |
| Teuerster Pfad | Cross-Database-`VOLL`, unbegrenzte Ausgabe und keine Objektfilter bei sehr vielen Partitionen/Allocation Units. |
| Haupttreiber | Zahl gewählter Datenbanken/Objekte sowie Partitionen, Allocation Units, Partition-Scheme-Ziele und Data Spaces. Objektfilter verkleinern die Katalogarbeit; das spätere TOP spart die vorgelagerte Aggregation nicht zuverlässig. |
| Skalierung | Laufzeit und CPU wachsen mit dem Haupttreiber. Sortierung/Aggregation erhöht Speicher- und gegebenenfalls TempDB-Bedarf; breite Texte/XML sowie viele Zeilen erhöhen Netzwerk- und Clientkosten. Für USP_Partitions ist insbesondere die im Datenkettenabschnitt beschriebene Reihenfolge maßgeblich. |
| Ressourcen | CPU, Katalogseiten und TempDB für Joins/Aggregation; bei breitem Cross-Database-Scope zusätzlicher Compile- und Ergebnistransferaufwand. |
| Begrenzungswirkung | Datenbank-/Objektfilter begrenzen die Quellarbeit. TOP oder MaxZeilen werden häufig nach Katalogjoins und Aggregation angewandt und sind dann nur Ausgabelimits. |
| Locking und Nebenwirkungen | Read-only; Katalogabfragen nehmen üblicherweise kurze Schema-Stability-Zugriffe und können mit gleichzeitigem DDL oder Datenbankstatuswechseln konkurrieren. |
| Schutzmechanismus | `GEZIELT` nutzt `OBJECT_ANALYSIS_CURRENT` ohne High-Impact-Pflicht. `VOLL` prüft zusätzlich `CATALOG_DEEP` und erfordert `@HighImpactConfirmed = 1`. |
| Sicherer Einsatz | Mit einer ExampleDb und einem ExampleObject starten; erst nach Größenprüfung auf mehrere Datenbanken oder VOLL erweitern. |
| Aussagegrenze | Scope- oder Zeilenbegrenzungen können relevante, seltene oder später einsortierte Zeilen ausblenden. Die Aussage bleibt auf das Modell „Katalogsnapshot“, die dokumentierte Granularität und den sichtbaren Quellenscope begrenzt; ein kleines Resultset ist weder automatisch vollständig noch repräsentativ. |

## Technische Vertiefung

[Gemeinsames Execution-, Zeit- und Evidenzmodell](../Technical_Foundations.md)

### Leitfrage

Wie verteilen Partition Function und Scheme Daten über Partitionen und Storage, und sind Grenzen/Lebenszyklus plausibel?

### Technischer Hintergrund

Partition Functions übersetzen Boundary Values in Partitionsnummern; RANGE LEFT/RIGHT bestimmt Grenzwertzuordnung. Schemes ordnen Partitionen Filegroups zu. Indizes müssen für Alignment dieselbe Partitionierungslogik passend verwenden.

### Datenkette

`sys.allocation_units`, `sys.data_spaces`, `sys.destination_data_spaces`, `sys.dm_db_partition_stats`, `sys.indexes`, `sys.objects`, `sys.partition_functions`, `sys.partition_range_values`, `sys.partition_schemes`, `sys.partitions`, `sys.schemas`, `sys.sp_executesql`.

### Source Select

Die Partitionskette verbindet Indexpartition, Partitionsschema/-funktion und die unteren beziehungsweise oberen Grenzwerte:

```sql
SELECT
      [s].[name] AS [SchemaName]
    , [o].[name] AS [ObjectName]
    , [i].[name] AS [IndexName]
    , [p].[partition_number]
    , [pf].[name] AS [PartitionFunctionName]
    , [lo].[value] AS [LowerBoundaryValue]
    , [hi].[value] AS [UpperBoundaryValue]
FROM [sys].[objects] AS [o] WITH (NOLOCK)
JOIN [sys].[schemas] AS [s] WITH (NOLOCK)
  ON [s].[schema_id] = [o].[schema_id]
JOIN [sys].[indexes] AS [i] WITH (NOLOCK)
  ON [i].[object_id] = [o].[object_id]
JOIN [sys].[partitions] AS [p] WITH (NOLOCK)
  ON [p].[object_id] = [i].[object_id]
 AND [p].[index_id] = [i].[index_id]
LEFT JOIN [sys].[partition_schemes] AS [ps] WITH (NOLOCK)
  ON [ps].[data_space_id] = [i].[data_space_id]
LEFT JOIN [sys].[partition_functions] AS [pf] WITH (NOLOCK)
  ON [pf].[function_id] = [ps].[function_id]
LEFT JOIN [sys].[partition_range_values] AS [lo] WITH (NOLOCK)
  ON [lo].[function_id] = [pf].[function_id]
 AND [lo].[boundary_id] = [p].[partition_number] - 1
LEFT JOIN [sys].[partition_range_values] AS [hi] WITH (NOLOCK)
  ON [hi].[function_id] = [pf].[function_id]
 AND [hi].[boundary_id] = [p].[partition_number]
WHERE [s].[name] = N'ExampleSchema'
  AND [o].[name] = N'ExampleObject';
```

**Wichtig für die Eigenlast:** Begrenzen Sie Objekt und Index vor Allocation-, Destination-Data-Space- und Boundary-Vertiefung. Ob die untere beziehungsweise obere Grenze inklusive ist, ergibt sich zusätzlich aus `sys.partition_functions.boundary_value_on_right`.

### Zeit- und Scope-Modell

Die Auswertung beschreibt den aktuellen Katalog- und Rowcount-/Spacezustand.

### Bewertung und Gegenprobe

Prüfen Sie Boundary-Reihenfolge, leere Randpartitionen, Größenverteilung, Kompression, Filegroups, aligned/non-aligned Indizes und Sliding-Window-Prozess. Skew kann fachlich erwartbar sein.

### Typische Fehlinterpretation

Viele oder ungleiche Partitionen sind nicht automatisch schlecht. Partitionierung garantiert weder schnellere Queries noch Partition Elimination; Prädikat und Plan entscheiden.

### Folgeanalyse

Für die weitere Analyse gelten folgende Schritte und Quellen: Showplan Partition Elimination, Wartungs-/Switchprozess und Capacityanalyse.

## Primärquellen

- [sys.dm_db_partition_stats](https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-views/sys-dm-db-partition-stats-transact-sql?view=sql-server-ver17)

## Weiterführende Vertiefung

Die folgenden Quellen ergänzen die Produktspezifikation um Praxis- oder Toolingperspektiven. Sie sind keine Grundlage für versions-, Berechtigungs- oder Engineaussagen dieser Seite.

- [Ola Hallengren: Index and Statistics Maintenance – betriebliche Wartungsperspektive](https://ola.hallengren.com/sql-server-index-and-statistics-maintenance.html)

[Technische Detailbeschreibung](../03_Object_Index.md#7-monitorusp_partitions)
