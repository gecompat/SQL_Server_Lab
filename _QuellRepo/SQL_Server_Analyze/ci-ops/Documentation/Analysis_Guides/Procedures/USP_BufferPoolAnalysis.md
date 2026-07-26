# [monitor].[USP_BufferPoolAnalysis]

**Bereich:** Server Health<br>
**Zweck:** Zeigt Buffer-Pool-Verteilung, Memory Clerks und Pressure-Kontext.<br>
**Beobachtungsart:** Snapshot<br>
**Kostenklasse:** LOW–HIGH_OPT_IN

## Entscheidungsfrage und Einsatz

Die Procedure beantwortet die Betriebsfrage: **Wie verteilt sich der Buffer Pool auf Datenbanken, Objekte und Pagearten, und gibt es Hinweise auf Cache-/Memorydruck?** Sie unterstützt die Entscheidung, ob eine Instanzressource oder Konfiguration als belastbare Spur zum Symptom passt und welche unabhängige OS-, Verlaufs- oder Workloadevidenz fehlt.

## Nicht beantwortete Fragen

Die Procedure beantwortet keine vollständige OS-/Hypervisorursache und ohne Delta oder Verlauf keine belastbare Aussage über einen dauerhaften Engpass. Der Zeitvertrag ist im Abschnitt „Zeit- und Scope-Modell“ konkretisiert. Ein Einzelwert gilt daher nur für diesen Scope und Zeitpunkt; er belegt weder eine Ursache noch eine Entwicklung.

## Sicherer Einstieg

```sql
EXEC [monitor].[USP_BufferPoolAnalysis]
      @MitMemoryClerks = 1,
      @MitBufferPoolVerteilung = 0,
      @ResultSetArt = 'CONSOLE';
```

Alle `Example*`-Werte im Aufruf sind synthetisch.

## Resultsets und Leserichtung

Der typisierte TABLE-Vertrag registriert `memory`. Status, Scope und Warnings sind vor den Fachergebnissen zu lesen. CONSOLE dient der interaktiven Triage; RAW und JSON erhalten den technischen Kontext, während TABLE nur die ausdrücklich benannten stabilen Resultsets schreibt. Resultsets mit unterschiedlicher Zeilengranularität dürfen nicht ungeprüft vereinigt oder summiert werden.

## Eine Zeile bedeutet

Je Resultset beschreibt eine Zeile eine Memoryzusammenfassung, einen Clerk oder eine Datenbank-/Page-Verteilung.

## So lesen

Berücksichtigen Sie Gesamtbuffer, Clerks, Datenbankanteile, Dirty/Clean Pages und Memory Pressure gemeinsam.

## Warum kann das problematisch sein?

Dominante Clerks oder ungewöhnliche Verteilung können Speicher verdrängen; viele Dirty Pages können Checkpoint-/I/O-Druck anzeigen.

## Wann ist es kein Problem?

Eine große aktive Datenbank darf den Buffer Pool dominieren.

## Beispiele und Gegenbeispiele

**Synthetischer Problemfall (`Example*`):** 80 % Buffer für ExampleDatabase ist nicht automatisch schlecht. Problematisch wird es, wenn andere aktive Datenbanken physisch lesen und Memory Pressure besteht. Prüfen Sie Memory, I/O und Query Reads.

**Ähnlich aussehender Gegenfall:** Eine große aktive Datenbank darf den Buffer Pool dominieren. Der gleiche Einzelwert kann deshalb bei `ExampleDb` ohne Nutzerauswirkung unkritisch sein, während er bei zeitgleicher SLA-Verletzung eine Vertiefung rechtfertigt.

## Leere oder partielle Ausgabe

Server-DMVs können plattform-, editions- oder berechtigungsbedingt fehlen. NULL und PARTIAL sind dann Evidenzgrenzen, keine Nullmessung.

Für `USP_BufferPoolAnalysis` gilt zusätzlich: **keine Zeile** bedeutet, dass im sichtbaren und gefilterten Scope kein ausgabefähiger Datensatz entstand. **0** ist ein gemessener Nullwert nur dann, wenn die Quellspalte tatsächlich verfügbar war. **NULL** bedeutet unbekannt, nicht anwendbar oder nicht auflösbar. **PARTIAL/Warning** bedeutet, dass mindestens eine Teilquelle, Datenbank oder Detailstufe fehlt. Ein Limit kann eine nichtleere Quelle vollständig aus dem sichtbaren Ausschnitt verdrängen.

## Eigenlast und Grenzen

| Dimension | Aussage für diese Procedure |
|---|---|
| Kostenklasse | LOW–HIGH_OPT_IN |
| Standardpfad | Memorysummary und begrenzte Clerk-/Semaphore-Sicht ohne Buffer-Pool-Verteilung. |
| Teuerster Pfad | Aktivierte Buffer-Pool-Verteilung auf einer Instanz mit sehr großem Cache; MaxZeilen wirkt erst nach Descriptoraggregation. |
| Haupttreiber | Zahl der Memory-Clerk-Typen und – nur bei aktivierter Verteilung – aller sichtbaren Buffer Descriptors vor der Gruppierung. Memory-/Semaphore-Summary ist klein; ein kleines Ausgabelimit verkürzt den Descriptor-Scan nicht. |
| Skalierung | Laufzeit und CPU wachsen mit dem Haupttreiber. Sortierung/Aggregation erhöht Speicher- und gegebenenfalls TempDB-Bedarf; breite Texte/XML sowie viele Zeilen erhöhen Netzwerk- und Clientkosten. Für USP_BufferPoolAnalysis ist insbesondere die im Datenkettenabschnitt beschriebene Reihenfolge maßgeblich. |
| Ressourcen | SQLOS-DMV-CPU; der optionale Scan von sys.dm_os_buffer_descriptors wächst mit der Zahl gecachter Pages und benötigt Aggregationsspeicher. |
| Begrenzungswirkung | MaxZeilen kürzt die ausgegebenen Gruppen. Bei aktivierter Buffer-Pool-Verteilung wird die Descriptorquelle dennoch vor der Gruppierung breit gelesen. |
| Locking und Nebenwirkungen | Keine Nutzdatenlocks oder Cachebereinigung; der breite Descriptor-Scan verbraucht jedoch CPU/Schedulerzeit auf der beobachteten Instanz. |
| Schutzmechanismus | Kein High-Impact-Gate. Der wichtigste Schutz ist, `@MitBufferPoolVerteilung = 0` zu belassen; nur dadurch entfällt der breite Descriptorpfad. `@MitMemoryClerks` steuert die Clerksicht, während `@MaxZeilen` nach der jeweiligen Aggregation lediglich die Ausgabe kürzt. |
| Sicherer Einsatz | Mit @MitBufferPoolVerteilung=0 starten; Verteilung nur nach Summary und außerhalb der Lastspitze aktivieren. |
| Aussagegrenze | Scope- oder Zeilenbegrenzungen können relevante, seltene oder später einsortierte Zeilen ausblenden. Die Aussage bleibt auf das Modell „Snapshot“, die dokumentierte Granularität und den sichtbaren Quellenscope begrenzt; ein kleines Resultset ist weder automatisch vollständig noch repräsentativ. |

## Technische Vertiefung

[Gemeinsames Execution-, Zeit- und Evidenzmodell](../Technical_Foundations.md)

### Leitfrage

Wie verteilt sich der Buffer Pool auf Datenbanken, Objekte und Pagearten, und gibt es Hinweise auf Cache-/Memorydruck?

### Technischer Hintergrund

Buffer Descriptors repräsentieren gecachte 8-KB-Datenseiten. Verteilung nach Database/File/Page/Object kann Working Set zeigen; Memory Clerks und PLE/Lazy Writes ergänzen Drucksignale. Clean Pages sind verwerfbar, Dirty Pages benötigen Flush.

### Datenkette

`sys.dm_exec_query_resource_semaphores`, `sys.dm_os_buffer_descriptors`, `sys.dm_os_memory_clerks`, `sys.dm_os_process_memory`, `sys.dm_os_sys_memory`.

### Source Select

Der datenbankbezogene Buffer-Pool-Kern entsteht durch Gruppierung der Buffer Descriptors und Zuordnung zur Datenbank:

```sql
SELECT
      [d].[name] AS [DatabaseName]
    , COUNT_BIG(*) AS [CachedPages]
    , COUNT_BIG(*) * 8.0 / 1024.0 AS [CachedMb]
FROM [sys].[dm_os_buffer_descriptors] AS [bd] WITH (NOLOCK)
JOIN [master].[sys].[databases] AS [d] WITH (NOLOCK)
  ON [d].[database_id] = [bd].[database_id]
WHERE [d].[name] = N'ExampleDatabase'
GROUP BY [d].[name];
```

**Wichtig für die Eigenlast:** `sys.dm_os_buffer_descriptors` kann sehr groß sein. Ein Datenbankprädikat reduziert Ergebnis und Aggregation, garantiert aber nicht, dass die Engine die DMV intern nur teilweise materialisiert; deshalb den Detailpfad bewusst verwenden.

### Zeit- und Scope-Modell

Die Auswertung beschreibt den aktuellen Cachebestand; dieser verändert sich fortlaufend durch Reads, Writes, Checkpoints und Memory Pressure.

### Bewertung und Gegenprobe

Berücksichtigen Sie Cached MB und Pages, Dirtyanteil, Datenbank- und Objektanteil, Page Life und Reads, OS- und Prozessdruck sowie Workloadgröße gemeinsam. Ein dominanter Cacheanteil kann ein legitimes Working Set darstellen.

### Typische Fehlinterpretation

Bufferanteil ist keine Hit Ratio und häufig gecacht bedeutet nicht automatisch problematisch. Breiter Descriptor-Scan kann selbst CPU/Memory/I/O-Metadatenlast erzeugen.

### Folgeanalyse

Verwenden Sie für die weitere Analyse Server Memory, Performance Counters sowie Query Reads und Plans. Aktivieren Sie den Deep-Pfad nur kontrolliert.

## Primärquellen

- [sys.dm_os_buffer_descriptors](https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-views/sys-dm-os-buffer-descriptors-transact-sql?view=sql-server-ver17)

[Technische Detailbeschreibung](../08_Server_Health.md#16-monitorusp_bufferpoolanalysis)
