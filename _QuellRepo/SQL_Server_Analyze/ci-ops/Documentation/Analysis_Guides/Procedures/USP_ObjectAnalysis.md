# [monitor].[USP_ObjectAnalysis]

**Bereich:** Object und Index, Orchestrator<br>
**Zweck:** Orchestriert Inventar, Usage, Missing Indexes und optionale Tiefenmodule; das bestehende Inventar enthält capability-adaptive SQL-Server-2025-JSON-Indexmetadaten.<br>
**Beobachtungsart:** nicht atomarer Mix aus Katalog, kumulativen Zählern und optionalem physischem Scan<br>
**Kostenklasse:** LOW–HIGH_OPT_IN

## Entscheidungsfrage und Einsatz

Die Procedure beantwortet die Betriebsfrage: **Welche objektbezogenen Evidenzpfade sollen für einen Scope gemeinsam ausgeführt werden?** Sie unterstützt die Entscheidung, ob ein Struktur- oder Metadatensignal eine workloadbezogene Gegenprüfung rechtfertigt, nicht ob automatisch DDL ausgeführt werden soll.

## Nicht beantwortete Fragen

Die Procedure beantwortet keinen Geschäftsnutzen einer Strukturänderung, keine repräsentative Workload und keine automatische Aussage über den optimalen Index- oder Statistikzustand. Der Zeitvertrag ist im Abschnitt „Zeit- und Scope-Modell“ konkretisiert. Ein Einzelwert gilt daher nur für diesen Scope und Zeitpunkt; er belegt weder eine Ursache noch eine Entwicklung.

## Sicherer Einstieg

```sql
EXEC [monitor].[USP_ObjectAnalysis]
      @DatabaseNames = N'[ExampleDatabase]',
      @FullObjectNames = N'[ExampleSchema].[ExampleTable]',
      @MitObjectInventory = 1,
      @MitIndexUsage = 0,
      @MitMissingIndexes = 0,
      @MaxZeilen = 100,
      @ResultSetArt = 'CONSOLE';
```

Zuerst wird nur das Objektinventar erhoben. Usage, Missing Indexes und die
physischen Tiefenmodule anschließend einzeln aktivieren, weil sie dieselben
Verwenden Sie Filter mit jeweils anderer Quellen- und Zeitsemantik.

Alle `Example*`-Werte im Aufruf sind synthetisch.

## Resultsets und Leserichtung

Der typisierte TABLE-Vertrag registriert `moduleStatus`. Status, Scope und Warnings sind vor den Fachergebnissen zu lesen. CONSOLE dient der interaktiven Triage; RAW und JSON erhalten den technischen Kontext, während TABLE nur die ausdrücklich benannten stabilen Resultsets schreibt. Resultsets mit unterschiedlicher Zeilengranularität dürfen nicht ungeprüft vereinigt oder summiert werden.

## Eine Zeile bedeutet

Die Granularität hängt vom Child ab: Objekt/Index, Indexpartition, Statistik, Rowgroup, Partition oder Finding.

## So lesen

Prüfen Sie zuerst den Childstatus. Folgen Sie danach der Reihenfolge Inventar → Nutzung → konkrete Tiefenanalyse. Interpretieren Sie Befunde verschiedener Children gemeinsam, aber nicht als identische Zeilen.

## Warum kann das problematisch sein?

Ein Missing-Index-Vorschlag ohne Inventar kann Redundanz erzeugen; Fragmentierung ohne Page Count kann unnötige Wartung auslösen.

## Wann ist es kein Problem?

Nicht aktivierte Deep-Module fehlen absichtlich. Sie bedeuten keine partielle Ausführung.

## Beispiele und Gegenbeispiele

**Synthetischer Problemfall (`Example*`):** Inventar zeigt ähnlichen Index, Missing Index schlägt einen neuen vor, Usage zeigt geringe Nutzung: eher Konsolidierung prüfen als blind erstellen. Wiederholen Sie Relevantes Child mit engem Scope.

**Ähnlich aussehender Gegenfall:** Nicht aktivierte Deep-Module fehlen absichtlich. Sie bedeuten keine partielle Ausführung. Der gleiche Einzelwert kann deshalb bei `ExampleDb` ohne Nutzerauswirkung unkritisch sein, während er bei zeitgleicher SLA-Verletzung eine Vertiefung rechtfertigt.

## Leere oder partielle Ausgabe

Bei Katalogpfaden sind Featureabwesenheit, Filter, Offline-/Permission-Scope und tatsächlich fehlende Objekte getrennte Erklärungen.

Für `USP_ObjectAnalysis` gilt zusätzlich: **keine Zeile** bedeutet, dass im sichtbaren und gefilterten Scope kein ausgabefähiger Datensatz entstand. **0** ist ein gemessener Nullwert nur dann, wenn die Quellspalte tatsächlich verfügbar war. **NULL** bedeutet unbekannt, nicht anwendbar oder nicht auflösbar. **PARTIAL/Warning** bedeutet, dass mindestens eine Teilquelle, Datenbank oder Detailstufe fehlt. Ein Limit kann eine nichtleere Quelle vollständig aus dem sichtbaren Ausschnitt verdrängen.

## Eigenlast und Grenzen

| Dimension | Aussage für diese Procedure |
|---|---|
| Kostenklasse | LOW–HIGH_OPT_IN |
| Standardpfad | `GEZIELT` mit Objektinventar, Index Usage und Missing Indexes. Ohne Objektfilter kann auch dieser Default viele Datenbanken/Katalogobjekte berühren; „gezielt“ bezeichnet den Childmodus, nicht automatisch einen engen Eingabescope. |
| Teuerster Pfad | `@Vollanalyse = 1`, alle elf Children und unbegrenzte Zeilen: Kataloge und Index-DMVs werden wiederholt gelesen, Histogramme zerlegt und `sys.dm_db_index_physical_stats` über den freigegebenen Scope ausgeführt. |
| Haupttreiber | Zahl der ausgewählten Datenbanken, Objekte, Indizes, Statistiken und Partitionen; bei Physical Stats zusätzlich Seitenzahl/Scanmodus, bei Statistikverteilung Kandidatenzahl und bis zu 200 Histogrammschritte je Statistik. |
| Skalierung | Children laufen sequenziell und teilen keinen Katalogsnapshot. Dieselben Objekte werden für Inventar, Usage, Operational Stats, Statistics, Partitionen, Columnstore und Design jeweils neu aufgelöst; VOLL vergrößert Scope und Detailarbeit. |
| Ressourcen | Datenbankkatalog- und DMV-CPU, Metadaten-I/O, Arbeitsspeicher/TempDB für Gruppierung sowie optional physischer Indexscan und Histogrammabruf. Kein `msdb`, XEL- oder Samplingpfad. |
| Begrenzungswirkung | `@MaxZeilen` wird an jedes Child übergeben, ist aber kein Gesamtlimit. Je Child kann es früh Kandidaten, erst eine sortierte Ausgabe oder nur den Transfer begrenzen; besonders SchemaDesign scannt den Katalog vor dem Limit. `@LockTimeoutMs` begrenzt Wartezeit, nicht CPU, I/O oder Gesamtdauer. |
| Locking und Nebenwirkungen | Read-only, aber Katalog- und Physical-Stats-Zugriffe können mit DDL konkurrieren. Die Children laufen nicht atomar; Objekt- oder Indexdefinitionen können sich zwischen Resultsets ändern. Der angeforderte `LOCK_TIMEOUT` gilt für den Childlauf; anschließend wird der vorherige Sessionwert wiederhergestellt. |
| Schutzmechanismus | VOLL und ressourcenintensive Children besitzen getrennte Modulschalter und Analyseklassen; `@HighImpactConfirmed` wird an alle weitergereicht. Freigabe erlaubt den Pfad, begrenzt ihn aber nicht. Ein enger `@DatabaseNames`-/`@FullObjectNames`-Scope bleibt erforderlich. |
| Sicherer Einsatz | Eine Datenbank, ein vollständiger Objektname, nur ein Child und `@MaxZeilen = 100`. Erst nach dessen Status gezielt Operational Stats, Histogramm oder Physical Stats mit eigenem Kostenvertrag aktivieren. |
| Aussagegrenze | Die Resultsets kombinieren aktuelle Katalogstruktur, seit Restart kumulative DMVs und optionale physische Momentaufnahmen. Gemeinsame Namen bedeuten nicht gemeinsamen Messzeitpunkt; Limits können pro Child andere Objekte sichtbar machen. |

## Technische Vertiefung

[Gemeinsames Execution-, Zeit- und Evidenzmodell](../Technical_Foundations.md)

### Leitfrage

Welche objektbezogenen Evidenzpfade sollen für einen Scope gemeinsam ausgeführt werden?

### Technischer Hintergrund

Der Orchestrator kombiniert Definition, Usage, Operations, Missing Indexes, Statistics, Partitions, Columnstore sowie optional Physical Stats und Vector-Index-Wartung. Jedes Child behält eigene Quelle, Kosten und Resetsemantik. SQL25-002 benötigt keinen neuen Schalter: Wenn `@MitObjectInventory = 1` und `@MitIndizes = 1` gelten, enthält der vorhandene Childvertrag die versions- und capability-adaptiven JSON-Index-/Pfadfelder.

### Datenkette

Die Datenkette besteht aus frameworkinterner Orchestrierung; die Quellen liegen in den aufgerufenen Childmodulen.

### Source Select

Kein einzelnes Grundselect wird verwendet. Die Procedure orchestriert je nach Schalter `USP_ObjectInventory`, `USP_IndexUsage`, `USP_MissingIndexes`, `USP_IndexOperationalStats`, `USP_Statistics`, `USP_StatisticsDistributionAnalysis`, `USP_Partitions`, `USP_Columnstore`, `USP_IndexPhysicalStats`, `USP_VectorIndexAnalysis` und `USP_SchemaDesignAnalysis`.

**Wichtig für die Eigenlast:** Reichen Sie Datenbank und vollständigen Objektnamen an alle Childmodule weiter und aktivieren Sie nur benötigte Tiefenpfade. Das abschließende Zeilenlimit ersetzt weder den DMF-Objektparameter noch den frühen Katalogscope.

### Zeit- und Scope-Modell

Die Auswertung kombiniert Metadaten, kumulative Zähler und aufrufbezogene physische Scans nicht atomar.

### Bewertung und Gegenprobe

Korrelieren Sie zuerst Childstatus und Kostenoptionen, danach Befunde nach Objekt/Index. Widersprüche sind möglich, etwa Missing-Index-Evidenz neben einem ähnlichen ungenutzten Index.

### Typische Fehlinterpretation

Die Zusammenfassung ist keine DDL-Liste. Ein Childfehler darf nicht als unauffälliges Objekt gelten.

### Folgeanalyse

Führen Sie je Befund das spezialisierte Child mit engem Scope erneut aus. `@MitVectorIndexes = 1` bleibt opt-in und liefert auf älteren Versionen einen expliziten Childstatus statt eines Parserfehlers. JSON-Indexmetadaten werden dagegen über `USP_ObjectInventory` geroutet; Indexpräsenz und Pfadzahl sind keine automatische Health- oder DDL-Empfehlung.

## Primärquellen

- [SQL-Server-Katalogsichten](https://learn.microsoft.com/en-us/sql/relational-databases/system-catalog-views/catalog-views-transact-sql?view=sql-server-ver17)

## Weiterführende Vertiefung

Die folgenden Quellen ergänzen die Produktspezifikation um Praxis- oder Toolingperspektiven. Sie sind keine Grundlage für versions-, Berechtigungs- oder Engineaussagen dieser Seite.

- [SQL Server First Responder Kit – ergänzende, quelloffene Praxiswerkzeuge für Triage](https://github.com/BrentOzarULTD/SQL-Server-First-Responder-Kit)

[Technische Detailbeschreibung](../03_Object_Index.md#12-monitorusp_objectanalysis)

[SQL-Server-2025-JSON-Index-Vertrag](../../Architecture/SQL_Server_2025_JSON_Index_Inventory.md)
