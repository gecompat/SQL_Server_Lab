# [monitor].[USP_FullTextAnalysis]

**Bereich:** Versionsadaptive Spezialanalysen<br>
**Zweck:** Bewertet sichtbare Full-Text-Kataloge, -Indizes und aggregierte Laufzeitmetadaten ohne indizierte Inhalte, Suchbegriffe, Crawl-Logs, Pfade oder Zustandsänderung.<br>
**Beobachtungsart:** Runtime- und Katalogsnapshot<br>
**Kostenklasse:** MEDIUM–HIGH_OPT_IN

## Entscheidungsfrage und Einsatz

Die Procedure beantwortet die Betriebsfrage: **Wie sind Full-Text Catalogs/Indexes konfiguriert, und laufen Population/Change Tracking ohne sichtbare Fehler oder Rückstand?** Sie unterstützt die Entscheidung, ob das Spezialfeature vorhanden und in einem auffälligen Zustand ist und welches featureeigene Diagnoseverfahren als Nächstes gebraucht wird.

## Nicht beantwortete Fragen

Die Procedure beantwortet keine fachliche Korrektheit der Featurekonfiguration, keine geschützten Inhalte und keine End-to-End-Funktionsprüfung außerhalb sichtbarer Metadaten. Der Zeitvertrag ist im Abschnitt „Zeit- und Scope-Modell“ konkretisiert. Ein Einzelwert gilt daher nur für diesen Scope und Zeitpunkt; er belegt weder eine Ursache noch eine Entwicklung.

## Sicherer Einstieg

```sql
EXEC [monitor].[USP_FullTextAnalysis]
      @DatabaseNames = N'[ExampleDatabase]',
      @NurProblematisch = 1,
      @HighImpactConfirmed = 1,
      @ResultSetArt = 'CONSOLE';
```

Der Full-Text-Katalogpfad ist vollständig als `CATALOG_DEEP` geschützt. Die Bestätigung ist für den engen Aufruf erforderlich; sie erweitert den Scope nicht und erlaubt keinen Zugriff auf indizierte Inhalte.

Alle `Example*`-Werte im Aufruf sind synthetisch.

## Resultsets und Leserichtung

Der typisierte TABLE-Vertrag registriert `findings`. Status, Scope und Warnings sind vor den Fachergebnissen zu lesen. CONSOLE dient der interaktiven Triage; RAW und JSON erhalten den technischen Kontext, während TABLE nur die ausdrücklich benannten stabilen Resultsets schreibt. Resultsets mit unterschiedlicher Zeilengranularität dürfen nicht ungeprüft vereinigt oder summiert werden.

## Eine Zeile bedeutet

Je Resultset entspricht eine Zeile einem Datenbankstatus, isolierten Quellenstatus, Finding, Katalog, Full-Text-Index, einer aktuell laufenden Population, einer aggregierten Batchgruppe, einer semantischen Population, einem Speicherpool oder einer FDHost-Typgruppe.

## So lesen

Prüfen Sie zuerst `StatusCode`, `IsPartial` und `SourceStatus`. Berücksichtigen Sie danach Index-/Schlüsselindexschalter, Crawl-Kontext, aktuelle Populationen und Batches gemeinsam. Fragmentanzahl und logische Größe sind Heuristik- beziehungsweise Kapazitätskontext; Memory Pools und FDHosts sind serverweit und keiner einzelnen Datenbank exklusiv zurechenbar.

## Warum kann das problematisch sein?

Deaktivierte Indizes, abgebrochene Populationen, Batchfehler oder fehlgeschlagene Dokumente können Suchaktualität und Auffindbarkeit begrenzen. Viele querybare Fragmente können die Abfrageleistung verschlechtern. Ein langer Lauf oder eine große Batchzahl beweist jedoch keinen Stillstand.

## Wann ist es kein Problem?

`MANUAL` oder `OFF` beim Change Tracking kann bewusst gewählt sein. Ein initialer Full Crawl kann durch `NO POPULATION` absichtlich ausstehen. Population-, Batch- und FDHost-DMVs sind Momentaufnahmen; Status 7 kann während eines automatischen Merge auftreten. Es existiert kein universeller Fragment- oder Laufzeitgrenzwert.

## Beispiele und Gegenbeispiele

**Synthetischer Problemfall (`Example*`):** Eine Population über dem Altersgrenzwert mit weiter steigendem Fortschritt ist eher ein Kapazitäts- als ein Stillstandsfall. Korrelieren Sie erst bei wiederholt fehlendem Fortschritt zusätzlich Batches, I/O, Log und geschützte Full-Text- und Crawl-Logs in der Laufzeitumgebung. Speichern und übermitteln Sie reale Logdaten oder interne Strukturen nur kontrolliert.

**Ähnlich aussehender Gegenfall:** `MANUAL` oder `OFF` beim Change Tracking kann bewusst gewählt sein. Ein initialer Full Crawl kann durch `NO POPULATION` absichtlich ausstehen. Population-, Batch- und FDHost-DMVs sind Momentaufnahmen; Status 7 kann während eines automatischen Merge auftreten. Es existiert kein universeller Fragment- oder Laufzeitgrenzwert. Der gleiche Einzelwert kann deshalb bei `ExampleDb` ohne Nutzerauswirkung unkritisch sein, während er bei zeitgleicher SLA-Verletzung eine Vertiefung rechtfertigt.

## Leere oder partielle Ausgabe

Nicht installiert, nicht aktiviert, in der gewählten Datenbank nicht verwendet und nicht abfragbar sind vier verschiedene Zustände.

Für `USP_FullTextAnalysis` gilt zusätzlich: **keine Zeile** bedeutet, dass im sichtbaren und gefilterten Scope kein ausgabefähiger Datensatz entstand. **0** ist ein gemessener Nullwert nur dann, wenn die Quellspalte tatsächlich verfügbar war. **NULL** bedeutet unbekannt, nicht anwendbar oder nicht auflösbar. **PARTIAL/Warning** bedeutet, dass mindestens eine Teilquelle, Datenbank oder Detailstufe fehlt. Ein Limit kann eine nichtleere Quelle vollständig aus dem sichtbaren Ausschnitt verdrängen.

Eine leere Population-DMV ist weder Abschlussnachweis noch Historie. Fehlende DMV-Rechte lassen zugängliche Katalog- und Fragmentevidenz gültig; die Procedure kennzeichnet die Lücke über `IsPartial` und `SourceStatus`. `NOT_APPLICABLE_VISIBLE_SCOPE` beweist bei eingeschränkter Metadatensichtbarkeit keine vollständige Abwesenheit.

## Eigenlast und Grenzen

MEDIUM: sichtbare Kataloge, Fragmente und aggregierte Full-Text-DMVs. Es werden keine Tabellenzeilen, Keywords, Stopwords, Parser-Eingaben, Schlüsselwerte, Crawl-Logs oder Pfade gelesen und kein `ALTER FULLTEXT` ausgeführt.

| Dimension | Aussage für diese Procedure |
|---|---|
| Kostenklasse | MEDIUM–HIGH_OPT_IN |
| Standardpfad | Eine `ExampleDatabase`, Problemscope und endliches Limit; Kataloge, Indizes und aktuelle aggregierte Full-Text-Runtimequellen werden einmal gelesen. |
| Teuerster Pfad | Alle sichtbaren Datenbanken ohne Objektfilter und unbegrenzte Ausgabe bei vielen Katalogen, Indizes, Fragmenten, Populationen, Outstanding Batches und semantischen Populationen. |
| Haupttreiber | Zahl gewählter Datenbanken, Full-Text-Kataloge/-Indizes und aktueller Population-, FDHost- und Memory-Pool-Zeilen. Indizierte Dokumente, Suchbegriffe und Crawl-Logs liegen außerhalb des Pfads und skalieren die Abfrage nicht direkt. |
| Skalierung | Quellarbeit wächst mit Full-Text-Objekten, Fragmenten und aktuellen Population-/Batchzeilen. Serverweite Memory-Pool-/FDHost-Quellen bleiben meist klein; Ausgabe und Sortierung wachsen mit allen materialisierten Detailtabellen. |
| Ressourcen | CPU, Katalog-/Full-Text-DMV-I/O, dynamisches SQL je Datenbank und TempDB/Arbeitsspeicher für isolierte Detailtabellen und Findings. Keine indizierten Inhalte oder Crawl-Logs. |
| Begrenzungswirkung | Datenbank-/Objektfilter begrenzen Katalog- und datenbankbezogene DMV-Arbeit. `@NurProblematisch` und `@MaxZeilen` werden erst bei der Ausgabe jedes Resultsets angewandt; sie verhindern das vorherige Lesen/Aggregieren der Full-Text-Quellen nicht. |
| Locking und Nebenwirkungen | Read-only ohne `ALTER FULLTEXT`; Kataloge und flüchtige Runtime-DMVs werden nicht atomar gelesen. Eine laufende Population kann ihren Status zwischen Teilquellen ändern. |
| Schutzmechanismus | Der Code prüft die Analyseklassen `CATALOG_DEEP`. Verlangt deren Policy ein Gruppengate, ist zusätzlich `@HighImpactConfirmed = 1` nötig; Freigabe und Bestätigung ersetzen keine Scopebegrenzung. |
| Sicherer Einsatz | Eine bekannte `ExampleDatabase`, Problemscope und möglichst Objektfilter. Erst Quellenstatus, dann Katalog/Index, Populationen und Batches lesen; serverweite Kapazität zuletzt korrelieren. |
| Aussagegrenze | Scope- oder Zeilenbegrenzungen können relevante, seltene oder später einsortierte Zeilen ausblenden. Die Aussage bleibt auf das Modell „Runtime- und Katalogsnapshot“, die dokumentierte Granularität und den sichtbaren Quellenscope begrenzt; ein kleines Resultset ist weder automatisch vollständig noch repräsentativ. |

## Technische Vertiefung

[Gemeinsames Execution-, Zeit- und Evidenzmodell](../Technical_Foundations.md)

### Leitfrage

Wie sind Full-Text Catalogs/Indexes konfiguriert, und laufen Population/Change Tracking ohne sichtbare Fehler oder Rückstand?

### Technischer Hintergrund

Full-Text Engine tokenisiert sprachabhängig, speichert invertierte Indizes in Catalogs und aktualisiert sie über Full/Incremental/Auto Population. Stoplists, Search Properties und Change Tracking beeinflussen Inhalt. Population DMVs zeigen aktive Crawls/Phasen.

### Datenkette

`sys.dm_fts_fdhosts`, `sys.dm_fts_index_population`, `sys.dm_fts_memory_pools`, `sys.dm_fts_outstanding_batches`, `sys.dm_fts_semantic_similarity_population`, `sys.fulltext_catalogs`, `sys.fulltext_index_columns`, `sys.fulltext_index_fragments`, `sys.fulltext_indexes`, `sys.indexes`, `sys.schemas`, `sys.sp_executesql`, `sys.tables`.

### Source Select

Der Katalogkern verbindet Full-Text-Index, Basistabelle, Schema, Katalog und Key-Index:

```sql
SELECT
      [s].[name] AS [SchemaName]
    , [t].[name] AS [TableName]
    , [fc].[name] AS [FullTextCatalogName]
    , [i].[name] AS [KeyIndexName]
    , [fi].[change_tracking_state_desc]
FROM [sys].[fulltext_indexes] AS [fi] WITH (NOLOCK)
JOIN [sys].[tables] AS [t] WITH (NOLOCK)
  ON [t].[object_id] = [fi].[object_id]
JOIN [sys].[schemas] AS [s] WITH (NOLOCK)
  ON [s].[schema_id] = [t].[schema_id]
LEFT JOIN [sys].[fulltext_catalogs] AS [fc] WITH (NOLOCK)
  ON [fc].[fulltext_catalog_id] = [fi].[fulltext_catalog_id]
LEFT JOIN [sys].[indexes] AS [i] WITH (NOLOCK)
  ON [i].[object_id] = [fi].[object_id]
 AND [i].[index_id] = [fi].[unique_index_id]
WHERE [s].[name] = N'ExampleSchema'
  AND [t].[name] = N'ExampleObject';
```

**Wichtig für die Eigenlast:** Setzen Sie Objektfilter vor Fragment- und Population-DMVs. Berücksichtigen Sie `sys.fulltext_index_fragments` und Outstanding-/Population-Details erst für verbleibende Full-Text-Indizes.

### Zeit- und Scope-Modell

Die Auswertung beschreibt den aktuellen Metadaten- und Populationzustand sowie die begrenzte Crawl- und Errorhistorie.

### Bewertung und Gegenprobe

Korrelieren Sie Catalog/Index, Change Tracking State, Population Type/Status, Start/End, Items processed/failed, Fragmentcount, Language/Stoplist und Base-Table-Änderung. Querybedarf bestimmt Dringlichkeit.

### Typische Fehlinterpretation

`IDLE` kann erfolgreich fertig oder nie gestartet bedeuten. Ein vorhandener Full-Text-Index garantiert keine aktuelle Vollständigkeit oder semantisch passende Wordbreaker.

### Folgeanalyse

Für die weitere Analyse gelten folgende Schritte und Quellen: Full-Text Crawl Logs/Errorlog, Job/Populationstart und konkrete CONTAINS-Query.

## Primärquellen

- [Full-Text Search](https://learn.microsoft.com/en-us/sql/relational-databases/search/full-text-search?view=sql-server-ver17)

[Technische Detailbeschreibung](../09_Version_Adaptive.md#6-monitorusp_fulltextanalysis)
