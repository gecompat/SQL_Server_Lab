# [monitor].[USP_IndexOperationalStats]

**Bereich:** Object und Index<br>
**Zweck:** Zeigt partitionsgenaue DML-, Allocation-, Lock-, Latch- und Zugriffsaktivität.<br>
**Beobachtungsart:** kumulativ seit Struktur-/Instanzreset<br>
**Kostenklasse:** LOW–HIGH_OPT_IN

## Entscheidungsfrage und Einsatz

Die Procedure beantwortet die Betriebsfrage: **Welche internen Zugriffsmuster, Allocations, Locks und Latches erzeugt ein Index?** Sie unterstützt die Entscheidung, ob ein Struktur- oder Metadatensignal eine workloadbezogene Gegenprüfung rechtfertigt, nicht ob automatisch DDL ausgeführt werden soll.

## Nicht beantwortete Fragen

Die Procedure beantwortet keinen Geschäftsnutzen einer Strukturänderung, keine repräsentative Workload und keine automatische Aussage über den optimalen Index- oder Statistikzustand. Der Zeitvertrag ist im Abschnitt „Zeit- und Scope-Modell“ konkretisiert. Ein Einzelwert gilt daher nur für diesen Scope und Zeitpunkt; er belegt weder eine Ursache noch eine Entwicklung.

## Sicherer Einstieg

```sql
EXEC [monitor].[USP_IndexOperationalStats]
      @DatabaseNames = N'[ExampleDatabase]',
      @FullObjectNames = N'[ExampleSchema].[ExampleTable]',
      @NurMitAktivitaet = 1,
      @MaxZeilen = 100,
      @ResultSetArt = 'CONSOLE';
```

`GEZIELT` löst genau ein Objekt auf und übergibt dessen ID an die DMF. Ohne
Objektfilter wäre der Einstieg ungültig; `VOLL` ist ein eigener Deep-Pfad.

Alle `Example*`-Werte im Aufruf sind synthetisch.

## Resultsets und Leserichtung

Der typisierte TABLE-Vertrag registriert `indexOperationalStats`. Status, Scope und Warnings sind vor den Fachergebnissen zu lesen. CONSOLE dient der interaktiven Triage; RAW und JSON erhalten den technischen Kontext, während TABLE nur die ausdrücklich benannten stabilen Resultsets schreibt. Resultsets mit unterschiedlicher Zeilengranularität dürfen nicht ungeprüft vereinigt oder summiert werden.

## Eine Zeile bedeutet

Eine Zeile entspricht einem Index oder Heap **und einer Partition**. Werte verschiedener Partitionen dürfen nur bewusst aggregiert werden.

## So lesen

Vergleichen Sie DML, Allocations, Locks, Latches und Scans. Normalisieren Sie absolute Zähler pro Aktivität, Wait oder Beobachtungszeit.

## Warum kann das problematisch sein?

Viele Page Allocations pro Insert können Split-/Wachstumsdruck anzeigen. Hohe Lock-/Latchzeit kann Parallelität und Durchsatz begrenzen.

## Wann ist es kein Problem?

Hohe absolute Zähler sind bei stark genutzten Indizes normal. Verhältnis, Delta und aktuelle Auswirkung sind entscheidend.

## Beispiele und Gegenbeispiele

**Synthetischer Problemfall (`Example*`):** Eine Million Latch-Waits über ein Jahr kann weniger kritisch sein als 50.000 in fünf Minuten auf derselben Hot Page. Prüfen Sie Live-Waits, Keyverteilung, Plan und Contention.

**Ähnlich aussehender Gegenfall:** Hohe absolute Zähler sind bei stark genutzten Indizes normal. Verhältnis, Delta und aktuelle Auswirkung sind entscheidend. Der gleiche Einzelwert kann deshalb bei `ExampleDb` ohne Nutzerauswirkung unkritisch sein, während er bei zeitgleicher SLA-Verletzung eine Vertiefung rechtfertigt.

## Leere oder partielle Ausgabe

Bei Katalogpfaden sind Featureabwesenheit, Filter, Offline-/Permission-Scope und tatsächlich fehlende Objekte getrennte Erklärungen.

Für `USP_IndexOperationalStats` gilt zusätzlich: **keine Zeile** bedeutet, dass im sichtbaren und gefilterten Scope kein ausgabefähiger Datensatz entstand. **0** ist ein gemessener Nullwert nur dann, wenn die Quellspalte tatsächlich verfügbar war. **NULL** bedeutet unbekannt, nicht anwendbar oder nicht auflösbar. **PARTIAL/Warning** bedeutet, dass mindestens eine Teilquelle, Datenbank oder Detailstufe fehlt. Ein Limit kann eine nichtleere Quelle vollständig aus dem sichtbaren Ausschnitt verdrängen.

## Eigenlast und Grenzen

**Quellcode-Hinweis zur Eigenlast:** GEZIELT ruft die DMF für genau ein zuvor sicher aufgelöstes Objekt auf. VOLL kann alle Heap-/B-Tree-/Columnstore-Rowsets lesen und ist deshalb explizit gruppengeschützt. TOP reduziert nicht zwingend die DMF-Arbeit.

| Dimension | Aussage für diese Procedure |
|---|---|
| Kostenklasse | LOW–HIGH_OPT_IN |
| Standardpfad | `GEZIELT` verlangt genau ein aufgelöstes Objekt und ruft `sys.dm_db_index_operational_stats` mit dessen ObjectId auf; inaktive Partitionen werden standardmäßig ausgeblendet. |
| Teuerster Pfad | `VOLL` über alle Datenbanken/Rowsets, Aktivitätsfilter aus und `@MaxZeilen = 0`. Ein Partitionsfilter ist in VOLL absichtlich ungültig; Scope muss über Datenbank-/Objektpattern erfolgen. |
| Haupttreiber | Zahl der von der DMF betrachteten Heap-/Index-/Partitionsrowsets. Nutzdatenzeilen werden nicht gescannt, aber VOLL muss instanzweite operative Zähler für alle Rowsets des Datenbankscope bereitstellen. |
| Skalierung | GEZIELT skaliert mit Partitionen/Indizes eines Objekts; VOLL mit allen Rowsets je Datenbank. Dynamisches SQL/DMF-Aufruf erfolgt separat pro Kandidatendatenbank. |
| Ressourcen | DMV-CPU, Katalogjoins für Namen/Typen und TempDB/Transfer. Kein Seiteninhaltsscan; die DMF selbst kann bei sehr vielen Rowsets dennoch spürbar sein. |
| Begrenzungswirkung | ObjectId und optional Index-/Partitionsfilter reduzieren GEZIELT früh. `@MaxZeilen` ist TOP in der Resultquery je Datenbank, garantiert aber nicht, dass die DMF nur diese Rowsets intern betrachtet; VOLL bleibt deshalb gatepflichtig. |
| Locking und Nebenwirkungen | Read-only; Katalogabfragen nehmen üblicherweise kurze Schema-Stability-Zugriffe und können mit gleichzeitigem DDL oder Datenbankstatuswechseln konkurrieren. |
| Schutzmechanismus | Der Code prüft die Analyseklassen `INDEX_OPERATIONAL_DEEP`, `OBJECT_ANALYSIS_CURRENT`. Verlangt deren Policy ein Gruppengate, ist zusätzlich `@HighImpactConfirmed = 1` nötig; Freigabe und Bestätigung ersetzen keine Scopebegrenzung. |
| Sicherer Einsatz | Eine `ExampleDatabase`, genau ein `ExampleSchema.ExampleTable`, aktive Rowsets und 100 Zeilen. Erst bei klarer Flottenfrage VOLL separat bestätigen. |
| Aussagegrenze | Zähler sind kumulativ seit Instanzstart beziehungsweise Rowset-/Indexneuanlage und zeigen keine aktuelle Rate. Rebuild, Restart oder Partitionwechsel setzt Vergleichbarkeit zurück; hohe Counts benötigen Laufzeit-/Baselinebezug. |

## Technische Vertiefung

[Gemeinsames Execution-, Zeit- und Evidenzmodell](../Technical_Foundations.md)

### Leitfrage

Welche internen Zugriffsmuster, Allocations, Locks und Latches erzeugt ein Index?

### Technischer Hintergrund

`sys.dm_db_index_operational_stats` liefert Blatt-/Nichtblattoperationen, Range-/Singleton-Lookups, Page Allocations, Lock-/Latch-Waits und weitere Low-Level-Zähler. Diese Zähler spiegeln physische Arbeitsweise wider und ergänzen die gröbere Usage-Sicht.

### Datenkette

`sys.dm_db_index_operational_stats`, `sys.indexes`, `sys.objects`, `sys.schemas`, `sys.sp_executesql`, `sys.tables`.

### Source Select

Die Objekt-ID wird direkt aus Katalogen aufgelöst und als enger DMF-Parameter verwendet:

```sql
DECLARE @TargetObjectId int =
(
    SELECT [o].[object_id]
    FROM [sys].[objects] AS [o] WITH (NOLOCK)
    JOIN [sys].[schemas] AS [s] WITH (NOLOCK)
      ON [s].[schema_id] = [o].[schema_id]
    WHERE [s].[name] = N'ExampleSchema'
      AND [o].[name] = N'ExampleObject'
);

SELECT
      [os].[object_id]
    , [os].[index_id]
    , [os].[partition_number]
    , [os].[leaf_allocation_count]
    , [os].[row_lock_wait_in_ms]
    , [os].[page_latch_wait_in_ms]
FROM [sys].[dm_db_index_operational_stats]
     (DB_ID(), @TargetObjectId, NULL, NULL) AS [os];
```

**Wichtig für die Eigenlast:** Die DMF nie versehentlich mit `NULL` als Objekt-Wildcard aufrufen, wenn ein Zielobjekt erwartet wird. Schema und Objekt müssen vor dem Zugriff eindeutig aufgelöst sein.

### Zeit- und Scope-Modell

Die Zähler sind innerhalb des Lebenszyklus der internen Struktur oder Instanz kumulativ. Die Werte können bei einem Neustart oder einer Strukturänderung zurückgesetzt werden.

### Bewertung und Gegenprobe

Normieren Sie die Zähler anhand der passenden Aktivität, beispielsweise Page Allocations pro Insert, Lockwaitzeit pro Lockwait und Latchwaitzeit pro Zugriff. Hohe absolute Werte sind bei stark genutzten Indizes erwartbar.

### Typische Fehlinterpretation

`leaf_allocation_count` ist nicht identisch mit dokumentiertem Page Split jeder Art. Eine Korrelation mit Fragmentierung/Fillfactor und DML-Muster ist nötig.

### Folgeanalyse

Für die weitere Analyse gelten folgende Schritte und Quellen: `USP_IndexPhysicalStats`, Current Blocking/Waits und konkrete DML-Pläne.

## Primärquellen

- [sys.dm_db_index_operational_stats](https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-views/sys-dm-db-index-operational-stats-transact-sql?view=sql-server-ver17)

## Weiterführende Vertiefung

Die folgenden Quellen ergänzen die Produktspezifikation um Praxis- oder Toolingperspektiven. Sie sind keine Grundlage für versions-, Berechtigungs- oder Engineaussagen dieser Seite.

- [Ola Hallengren: Index and Statistics Maintenance – betriebliche Wartungsperspektive](https://ola.hallengren.com/sql-server-index-and-statistics-maintenance.html)

[Technische Detailbeschreibung](../03_Object_Index.md#3-monitorusp_indexoperationalstats)
