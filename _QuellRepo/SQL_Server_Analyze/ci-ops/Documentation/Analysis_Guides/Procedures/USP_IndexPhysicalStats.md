# [monitor].[USP_IndexPhysicalStats]

**Bereich:** Object und Index<br>
**Zweck:** Misst beim Aufruf physische Rowstore-/Heap-Strukturen wie Page Count, Fragmentierung, Seitendichte, Ebenen, Ghosts und Forwarded Records.<br>
**Beobachtungsart:** aufrufbezogener physischer Strukturzustand<br>
**Kostenklasse:** `HIGH_OPT_IN`

## Entscheidungsfrage und Einsatz

Diese Auswertung beantwortet: **Wie ist ein konkret verdächtiges Heap- oder Rowstore-Indexobjekt physisch aufgebaut, und ist die Strukturgröße groß genug, um Fragmentierung, niedrige Seitendichte oder Forwarded Records als mögliche Mitursache weiterzuprüfen?**

Sie gehört nicht an den Anfang einer pauschalen „alle Indizes warten“-Routine. Ein sinnvoller Einsatz beginnt mit einem benannten Objekt, für das bereits Workloadevidenz vorliegt: relevante Scans, zusätzliche Reads, hohe Cachebelegung, Heap-Lookups oder eine belastbare Wartungsfrage. Der kleinste Pfad ist eine Datenbank, genau ein Objekt, `GEZIELT` und `LIMITED`.

## Nicht beantwortete Fragen

Die Procedure misst keine tatsächliche Indexnutzung, keine Querylaufzeit, keine Planqualität und keinen Nutzen einer Wartungsaktion. Sie entscheidet weder „REORGANIZE oder REBUILD“ noch beweist ein hoher Fragmentierungswert eine Performanceursache. Logvolumen, verfügbare Edition-/Onlineoptionen, Replikation, AG-Auswirkungen, TempDB-Bedarf und Wartungsfenster liegen außerhalb des Resultsets.

Die Messung umfasst physische Statistiken im gewählten Scanmodus. `SAMPLED` ist näherungsweise, und nicht jede Spalte ist für jeden Indextyp, Allocation-Unit-Typ oder Modus anwendbar. `NULL` ist deshalb nicht mit 0 gleichzusetzen.

## Sicherer Einstieg

Der Zugriff ist als `PHYSICAL_STATS_DEEP` geschützt und erfordert sowohl die konfigurierte Analysefreigabe als auch die bewusste Bestätigung. Der Beispielscope ist vollständig synthetisch:

```sql
EXEC [monitor].[USP_IndexPhysicalStats]
      @DatabaseNames = N'[ExampleDatabase]',
      @FullObjectNames = N'[ExampleSchema].[ExampleTable]',
      @AnalyseModus = 'GEZIELT',
      @ScanMode = 'LIMITED',
      @MinPageCount = 1000,
      @MaxZeilen = 1000,
      @LockTimeoutMs = 0,
      @HighImpactConfirmed = 1,
      @ResultSetArt = 'CONSOLE';
```

Prüfen Sie vor dem Aufruf Objektname und Datenbank. `@DatabaseNames = NULL` bedeutet nach dem gemeinsamen Datenbankvertrag nicht „aktuelle Datenbank“, sondern alle sichtbaren, zugreifbaren, online befindlichen Userdatenbanken. Ein breiter Lauf ist daher niemals ein unbemerkter Ersatz für den gezielten Einstieg.

## Resultsets und Leserichtung

- `CONSOLE` liefert genau ein fachliches Resultset aus `indexPhysicalStats`. Bei leerer Menge erscheint eine verständliche Leerzeile, aber kein separates Datenbankstatus-Grid.
- `RAW` liefert Modulstatus, danach einen Status je ausgewählter Datenbank und erst anschließend die physischen Zeilen. Bei mehreren Datenbanken ist diese Reihenfolge entscheidend: `PARTIAL`, `AVAILABLE_LIMITED`, `SKIPPED`, `DENIED_PERMISSION` oder `TIMEOUT` erklären Lücken.
- `TABLE` exportiert ausschließlich das Primärergebnis `indexPhysicalStats` in die zugeordnete lokale Temp-Tabelle. Der Datenbankstatus wird nicht als TABLE-Resultset exportiert.
- JSON enthält `meta`, `indexPhysicalStats` und `databaseStatus`.

Eine leere Fachdatenmenge ohne Statuskontext ist keine Wartungsaussage. Verwenden Sie für Freigaben oder Cross-Database-Läufe deshalb zunächst `RAW` oder JSON.

## Eine Zeile bedeutet

Eine Zeile entspricht einer Kombination aus Datenbank, Objekt, `IndexId`, Partition, `IndexLevel` und `AllocationUnitTypeDesc`, die `sys.dm_db_index_physical_stats` im gewählten Modus liefert. Ein einzelner Index kann daher mehrere Zeilen besitzen:

- je Partition,
- je B-Tree-Ebene,
- je Allocation Unit wie `IN_ROW_DATA`, `LOB_DATA` oder `ROW_OVERFLOW_DATA`.

Werte dürfen nicht ungeprüft über diese Zeilen addiert oder gemittelt werden. Isolieren Sie für die übliche Leaf-Bewertung eines Rowstore-Indexes zuerst die relevante Partition und `IndexLevel = 0`. Bei einem Heap (`IndexId = 0`) gelten andere Strukturmerkmale; insbesondere `ForwardedRecordCount` ist ein Heapkontext und keine allgemeine Indexkennzahl.

## So lesen

1. **Datenbankstatus:** Wurde die beabsichtigte Datenbank tatsächlich analysiert, oder wurde sie ausgelassen, abgelehnt beziehungsweise mit Fehler isoliert?
2. **Identität:** Legen Sie Datenbank, Schema, Objekt, Index, Partition, Ebene und Allocation Unit fest. Vergleichen Sie erst danach die Werte.
3. **Größe als Nenner:** Berücksichtigen Sie zuerst `PageCount` und, soweit passend, `RecordCount`. Ein Prozentwert ohne Größenbezug ist nicht entscheidungsfähig.
4. **Scanmodus:** Berücksichtigen Sie außerdem `ScanMode`. `LIMITED` ist der leichteste Modus, `SAMPLED` liefert eine Stichprobe, `DETAILED` untersucht alle Pages und Ebenen am tiefsten.
5. **Fragmentierung:** Betrachten Sie `AvgFragmentationPercent`, `FragmentCount` und `AvgFragmentSizePages` gemeinsam. Die mögliche Auswirkung hängt von Scanform, Read-Ahead, Storage, Größe und Workload ab.
6. **Seitendichte:** `AvgPageSpaceUsedPercent` zeigt die durchschnittliche Belegung der betrachteten Pages. Niedrige Dichte kann dieselbe Datenmenge auf mehr Pages verteilen und dadurch Buffer-Pool- und I/O-Bedarf erhöhen.
7. **Spezialwerte:** Ghost-/Version-Ghost-Werte nur im MVCC-/Cleanupkontext; Forwarded Records nur beim Heap; `CompressedPageCount` nur dort interpretieren, wo Modus und Struktur den Wert sinnvoll liefern.

## Warum kann das problematisch sein?

Eine große Struktur mit niedriger Seitendichte benötigt für dieselben Datensätze tendenziell mehr Pages. Das kann mehr Logical Reads, Cachebelegung und physische I/O verursachen. Starke logische Fragmentierung kann bei Range Scans zusammenhängendes Read-Ahead erschweren. Viele Forwarded Records in einem häufig gelesenen Heap können zusätzliche Pagezugriffe auslösen.

Die Diagnose selbst kann dabei erheblich sein: Die DMF liest physische Strukturinformationen. `DETAILED` untersucht alle Pages und alle Ebenen, ein breiter `VOLL`-Lauf kann dies über viele Objekte und Datenbanken wiederholen. Das Ergebnislimit greift erst nach dem DMF-Zugriff und schützt nicht vor dieser Quellarbeit.

## Wann ist es kein Problem?

99 Prozent Fragmentierung auf acht Pages besitzt einen sehr kleinen absoluten Scope und wird durch den Default `@MinPageCount = 1000` ohnehin ausgefiltert. Eine große Fragmentierung kann für überwiegende Punkt-Seeks ohne messbare zusätzliche Reads weniger relevant sein. Niedrige Dichte kann beabsichtigt sein, wenn der Fill Factor Insert-/Update-Splits für eine passende Workload reduziert.

Auch mehrere Ergebniszeilen für denselben Index sind kein Duplikatfehler, wenn Partition, Ebene oder Allocation Unit verschieden sind. `NULL` in einer nicht unterstützten Modus-/Strukturkombination ist kein gemessener Nullwert.

## Beispiele und Gegenbeispiele

**Synthetischer Prüfbedarf `ExampleLargeIndex`:** Leafebene einer großen Partition mit `PageCount = 5000000`, `AvgFragmentationPercent = 45` und `AvgPageSpaceUsedPercent = 55`. Beobachtung: große, wenig dicht belegte und fragmentierte Struktur. Mögliche Auswirkung: mehr Pages im Buffer Pool und mehr Arbeit bei Range Scans. Gegenprobe: `USP_IndexUsage`, Query Store und konkrete Pläne müssen zeigen, dass relevante Scans/Reads und eine Geschäftsauswirkung existieren. Bewerten Sie erst danach Wartungsoption, Log-/I/O-Budget und Rollback.

**Unkritischer Gegenfall `ExampleTinyIndex`:** `PageCount = 8` bei ebenfalls 45 Prozent Fragmentierung. Der Prozentwert sieht gleich aus, die absolute Struktur ist aber winzig. Ohne messbare Auswirkung ist eine Wartungsaktion typischerweise teurer als die potenzielle Einsparung.

**Heapfall `ExampleHeap`:** viele `ForwardedRecordCount`-Einträge bei großem `RecordCount` und Plänen mit RID Lookups. Das legt zusätzliche Zugriffe als Hypothese nahe. Derselbe absolute Forwarded-Wert ohne RecordCount, Nutzung und Planbezug ist nicht bewertbar; es gibt keine universelle Prozentgrenze in dieser Procedure.

## Leere oder partielle Ausgabe

Keine Fachzeile kann bedeuten:

- das synthetisch angegebene Zielobjekt existiert nicht oder ist nicht sichtbar,
- `@MinPageCount`, `@MinFragmentationPercent`, Index- oder Partitionsfilter schließen alles aus,
- die Datenbank ist offline, nicht zugreifbar oder vom Scope ausgeschlossen,
- Berechtigung oder Analyseklasse fehlt,
- `LOCK_TIMEOUT` wurde beim Metadaten-/Objektzugriff erreicht,
- der gewählte Struktur-/Moduspfad liefert für die Filterkombination keine Zeile.

Bei mehreren Datenbanken isoliert die Procedure Fehler je Datenbank und kann trotz `PARTIAL` Fachdaten anderer Datenbanken liefern. Daher nie nur die letzte Fachtabelle archivieren, wenn Vollständigkeit relevant ist. Ein gezieltes Objekt, das in einer der ausgewählten Datenbanken fehlt, wird nicht als `NULL`-Wildcard breit analysiert; dieser Schutz verhindert einen unbeabsichtigten Full Scan.

## Eigenlast und Grenzen

| Dimension | Aussage für diese Procedure |
|---|---|
| Kostenklasse | `HIGH_OPT_IN`; selbst der kleine Pfad erfordert die Analyseklasse `PHYSICAL_STATS_DEEP` und `@HighImpactConfirmed = 1`. |
| Standardpfad | Eine Datenbank, ein exakt aufgelöstes Objekt, `GEZIELT`, `LIMITED`, Mindestgröße 1000 Pages und endliche Ausgabe ist der kleinste Pfad; seine reale Last hängt von der Objektgröße ab. |
| Teuerster Pfad | `VOLL` plus `DETAILED` über alle sichtbaren Userdatenbanken, ohne Objekt-/Partitionsfilter, mit `@MinPageCount = 0` und unbegrenzter Ausgabe untersucht sehr große Pagebestände. |
| Haupttreiber | Zahl ausgewählter Datenbanken und Objekte, Page Count, Partitionen, Indexebenen und `ScanMode` |
| Skalierung | primär Page-/I/O-Umfang; zusätzlich CPU für DMF, Katalogjoins, Filter und Sortierung sowie Transfer für breite Resultate |
| Ressourcen | Buffer Pool und physische I/O, CPU, eigener Memory Grant für Sortierung, Metadatenzugriffe und Ergebnistransfer; Abfrageplan ist mit `MAXDOP 1` begrenzt. |
| Begrenzungswirkung | `@ObjectId`, `@IndexId` und `@PartitionNumber` werden im gezielten Pfad an die DMF übergeben und reduzieren deren Scope. Namenspattern in `VOLL`, Mindestseiten, Mindestfragmentierung und `TOP (@MaxZeilen)` wirken erst nach dem DMF-Aufruf. `@MaxZeilen` gilt technisch je Datenbanklauf; die Gesamtausgabe kann bei mehreren Datenbanken darüber liegen. |
| Locking und Nebenwirkungen | Die DMF kann unabhängig vom Modus Intent-Shared-Locks anfordern. Auf einer lesbaren Secondary kann dies mit einem REDO-Thread kollidieren, der einen X-Lock benötigt. Keine DDL- oder Indexwartung; nur eigene Temp-Tabellen werden beschrieben. |
| Schutzmechanismus | Analyseklasse `PHYSICAL_STATS_DEEP`, explizites `@HighImpactConfirmed`, gezielter Modus mit Pflichtobjekt, Datenbankscope und `@LockTimeoutMs`; der Timeout begrenzt Lock-Warten, nicht I/O oder CPU. |
| Sicherer Einsatz | explizite Datenbank und exaktes Objekt, `LIMITED`, niedriges Ergebnislimit, Monitoring der Systemlast; `SAMPLED`/`DETAILED` oder `VOLL` nur mit begründetem Erkenntnisgewinn und geeignetem Betriebsfenster |
| Aussagegrenze | `LIMITED` und `SAMPLED` liefern weniger tiefe beziehungsweise näherungsweise Evidenz. Ein enger Scope kann andere problematische Strukturen nicht ausschließen; ein breiter Scope erhöht umgekehrt die Diagnosekosten massiv. |

## Technische Vertiefung

[Gemeinsames Execution-, Zeit- und Evidenzmodell](../Technical_Foundations.md)

### Leitfrage

Welcher physische Strukturzustand ist für das bereits fachlich verdächtige Objekt sichtbar, und rechtfertigt dessen absolute Größe eine tiefergehende Workload- oder Wartungsbewertung?

### Technischer Hintergrund

`sys.dm_db_index_physical_stats` traversiert Allocation- und Page-Strukturen abhängig von `LIMITED`, `SAMPLED` oder `DETAILED`. Fragmentierung beschreibt die Reihenfolge beziehungsweise Zusammenhängigkeit physischer Strukturen; Page Space Used beschreibt Dichte. Diese Mechanismen können I/O-Verhalten beeinflussen, bleiben aber ohne Workloadbezug Strukturevidenz.

Die Procedure verwendet die DMF ausschließlich lesend. Sie reorganisiert oder rebuildet nichts. Dass der Pfad „read-only“ ist, bedeutet nicht geringe Last: Ein physischer Scan kann mit der Größe des untersuchten Pagebestands wachsen.

### Datenkette

1. `USP_PrepareDatabaseCandidates` bestimmt sichtbare Online-Userdatenbanken, wendet explizite Datenbankfilter an und prüft High-Impact-/Cross-Database-Freigaben.
2. Namensfilter werden validiert. `GEZIELT` verlangt genau ein auflösbares Objekt; fehlt es, wird die DMF nicht mit einem unbeabsichtigten `NULL`-Objektfilter aufgerufen.
3. Pro Datenbank werden Objekt-ID und Katalogbezeichnungen über `sys.objects`, `sys.schemas` und `sys.indexes` aufgelöst.
4. Die DMF erhält Datenbank-ID, gezielte Objekt-ID sowie optionale Index-/Partitions-ID und Scanmodus.
5. Erst auf den gelieferten DMF-Zeilen wirken Mindestpages, Mindestfragmentierung und bei breitem Modus Namenspattern; danach werden die größten Strukturen sortiert und je Datenbank begrenzt.
6. Fehler und Zeilenzahl werden je Datenbank protokolliert, anschließend als CONSOLE, RAW, TABLE oder JSON ausgegeben.

### Source Select

Die kostenentscheidende Struktur ist die gezielte Katalogauflösung vor dem Physical-Stats-Aufruf:

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
      [ps].[object_id]
    , [ps].[index_id]
    , [ps].[partition_number]
    , [ps].[page_count]
    , [ps].[avg_fragmentation_in_percent]
    , [ps].[avg_page_space_used_in_percent]
FROM [sys].[dm_db_index_physical_stats]
     (DB_ID(), @TargetObjectId, NULL, NULL, N'LIMITED') AS [ps]
WHERE [ps].[page_count] >= @MinPageCount;
```

**Wichtig für die Eigenlast:** Objekt-ID, optional Index und Partition vor dem DMF-Aufruf bestimmen. `LIMITED` klein beginnen; Mindestpages und Fragmentierungsfilter wirken erst auf gelieferten DMF-Zeilen und verhindern den physischen Scan nicht.

### Zeit- und Scope-Modell

Die Messung gilt für den physischen Zustand während des Aufrufs. Gleichzeitige DML, Page Splits, Ghost Cleanup oder Wartung können Werte während eines längeren Scans verändern; es gibt keinen transaktional eingefrorenen Strukturzeitpunkt. Es existiert kein kumulativer Resetzähler. Der Scope folgt expliziter Datenbank-, Objekt-, Index- und Partitionsauswahl sowie dem Scanmodus.

### Bewertung und Gegenprobe

Page Count ist der erste Nenner. Bewerten Sie danach Dichte und Fragmentierung auf derselben Partition und Ebene. Nutzung und Auswirkung werden unabhängig über `USP_IndexUsage`, Query Store, konkrete Pläne und I/O- und Cacheevidenz bestätigt. Planen Sie für einen Wartungsentscheid zusätzlich Logwachstum, AG und Replikation, Blocking, Onlinefähigkeit, TempDB, Wartungsfenster und einen beobachtbaren Vorher-Nachher-Effekt ein.

### Typische Fehlinterpretation

Pauschale 5-/30-Prozent-Schwellen sind keine universelle Engineentscheidung. Das Addieren von Pages über Leaf-, Nonleaf- und Allocation-Unit-Zeilen kann doppelte oder fachlich inkompatible Größen erzeugen. Ein niedriger Fill Factor kann beabsichtigt sein. `TOP 100` macht einen vorangegangenen `DETAILED`-Scan nicht klein.

### Folgeanalyse

Für die weitere Analyse gelten folgende Schritte und Quellen: `USP_IndexUsage` für Nutzung, `USP_IndexOperationalStats` für betriebliche Zugriffsmuster, Query Store und `USP_ShowplanAnalysis` für betroffene Queries. Formulieren Sie erst bei bestätigter Auswirkung eine Wartungsstrategie mit Ressourcenbudget und Rollback.

## Primärquellen

- [sys.dm_db_index_physical_stats](https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-db-index-physical-stats-transact-sql?view=sql-server-ver17)
- [Optimieren der Indexwartung](https://learn.microsoft.com/en-us/sql/relational-databases/indexes/reorganize-and-rebuild-indexes?view=sql-server-ver17)

[Technische Detailbeschreibung](../03_Object_Index.md#9-monitorusp_indexphysicalstats)
