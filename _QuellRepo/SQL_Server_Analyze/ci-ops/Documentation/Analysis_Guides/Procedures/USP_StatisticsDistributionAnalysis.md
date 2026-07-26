# [monitor].[USP_StatisticsDistributionAnalysis]

**Bereich:** Object und Index<br>
**Zweck:** Analysiert ausgewählte Histogramme auf Skew, dominante Schritte, Tail und Partitionsabweichungen.<br>
**Beobachtungsart:** Katalogsnapshot<br>
**Kostenklasse:** HIGH_OPT_IN

## Entscheidungsfrage und Einsatz

Die Procedure beantwortet die Betriebsfrage: **Welche Datenverteilung bildet das Histogramm ab, und wo können Skew, dominante Werte oder grobe Rangeannahmen Schätzungen erschweren?** Sie unterstützt die Entscheidung, ob ein Struktur- oder Metadatensignal eine workloadbezogene Gegenprüfung rechtfertigt, nicht ob automatisch DDL ausgeführt werden soll.

## Nicht beantwortete Fragen

Die Procedure beantwortet keinen Geschäftsnutzen einer Strukturänderung, keine repräsentative Workload und keine automatische Aussage über den optimalen Index- oder Statistikzustand. Der Zeitvertrag ist im Abschnitt „Zeit- und Scope-Modell“ konkretisiert. Ein Einzelwert gilt daher nur für diesen Scope und Zeitpunkt; er belegt weder eine Ursache noch eine Entwicklung.

## Sicherer Einstieg

```sql
EXEC [monitor].[USP_StatisticsDistributionAnalysis]
      @DatabaseNames = N'[ExampleDatabase]',
      @FullObjectNames = N'[ExampleSchema].[ExampleObject]',
      @AnalyseModus = 'GEZIELT',
      @MaxVerteilungsStatistiken = 10,
      @HighImpactConfirmed = 1,
      @ResultSetArt = 'CONSOLE';
```

Auch der gezielte Pfad ist als `CATALOG_DEEP` klassifiziert. Die Bestätigung ist deshalb technisch erforderlich; Objektfilter und Kandidatengrenze bleiben die eigentlichen Schutzgrenzen für die Quellarbeit.

Alle `Example*`-Werte im Aufruf sind synthetisch.

## Resultsets und Leserichtung

Der typisierte TABLE-Vertrag registriert `findings`. Status, Scope und Warnings sind vor den Fachergebnissen zu lesen. CONSOLE dient der interaktiven Triage; RAW und JSON erhalten den technischen Kontext, während TABLE nur die ausdrücklich benannten stabilen Resultsets schreibt. Resultsets mit unterschiedlicher Zeilengranularität dürfen nicht ungeprüft vereinigt oder summiert werden.

## Eine Zeile bedeutet

Je Resultset beschreibt eine Zeile eine Statistik, eine Verteilungszusammenfassung, eine Partitionsvariation oder ein normalisiertes Finding.

## So lesen

Berücksichtigen Sie zuerst Sample und Modification, danach Dominant Step, Skew, Tail und Partitionsspread. Bewerten Sie Findings erst mit der zugrunde liegenden Verteilung.

## Warum kann das problematisch sein?

Starke Spitzen oder neue Tailwerte können dazu führen, dass ein Plan für häufige Parameter bei seltenen Parametern ungeeignet ist – oder umgekehrt.

## Wann ist es kein Problem?

Skew kann die reale Datenverteilung korrekt beschreiben und bei geeigneten Plänen völlig unkritisch sein.

## Beispiele und Gegenbeispiele

**Synthetischer Problemfall (`Example*`):** Ein Wert umfasst 70 % der Zeilen. Problematisch wird das erst, wenn seltene und häufige Parameter denselben Plan verwenden und stark unterschiedliche Zeilenmengen erzeugen. Vergleichen Sie Query Store und Showplan.

**Ähnlich aussehender Gegenfall:** Skew kann die reale Datenverteilung korrekt beschreiben und bei geeigneten Plänen völlig unkritisch sein. Der gleiche Einzelwert kann deshalb bei `ExampleDb` ohne Nutzerauswirkung unkritisch sein, während er bei zeitgleicher SLA-Verletzung eine Vertiefung rechtfertigt.

## Leere oder partielle Ausgabe

Bei Katalogpfaden sind Featureabwesenheit, Filter, Offline-/Permission-Scope und tatsächlich fehlende Objekte getrennte Erklärungen.

Für `USP_StatisticsDistributionAnalysis` gilt zusätzlich: **keine Zeile** bedeutet, dass im sichtbaren und gefilterten Scope kein ausgabefähiger Datensatz entstand. **0** ist ein gemessener Nullwert nur dann, wenn die Quellspalte tatsächlich verfügbar war. **NULL** bedeutet unbekannt, nicht anwendbar oder nicht auflösbar. **PARTIAL/Warning** bedeutet, dass mindestens eine Teilquelle, Datenbank oder Detailstufe fehlt. Ein Limit kann eine nichtleere Quelle vollständig aus dem sichtbaren Ausschnitt verdrängen.

## Eigenlast und Grenzen

| Dimension | Aussage für diese Procedure |
|---|---|
| Kostenklasse | HIGH_OPT_IN |
| Standardpfad | Eine Datenbank, ein Objekt und höchstens zehn ausgewählte Statistiken; pro Kandidat wird das vorhandene Histogramm numerisch zusammengefasst. |
| Teuerster Pfad | Viele ausgewählte Statistiken/Partitionen; pro Histogramm können bis zu 200 Steps gelesen, aggregiert und bewertet werden. |
| Haupttreiber | Zahl gewählter Datenbanken/Objekte, ausgewählter Statistiken und Partitionen. Für jede Kandidatenstatistik werden die vorhandenen Histogramm-Steps – höchstens 200 je Histogramm – gelesen und numerisch verdichtet. |
| Skalierung | Laufzeit und CPU wachsen mit dem Haupttreiber. Sortierung/Aggregation erhöht Speicher- und gegebenenfalls TempDB-Bedarf; breite Texte/XML sowie viele Zeilen erhöhen Netzwerk- und Clientkosten. Für USP_StatisticsDistributionAnalysis ist insbesondere die im Datenkettenabschnitt beschriebene Reihenfolge maßgeblich. |
| Ressourcen | CPU und Statistik-/Histogramm-Metadaten-I/O sowie Arbeitsspeicher für höchstens 200 Steps je ausgewähltem Histogramm; keine Segment-, Dictionary-, Benutzerdaten- oder XML-Ausgabe. |
| Begrenzungswirkung | Objekt-/Statistikfilter und `@MaxVerteilungsStatistiken` begrenzen Kandidaten vor dem Histogrammzugriff. `@MaxZeilen` wirkt erst auf fertige Findings und begrenzt nicht die Histogrammschritte. |
| Locking und Nebenwirkungen | Read-only mit Katalog-/Strukturzugriffen; parallele DDL-, Load- oder Wartungsaktivität kann kurz kollidieren und inkonsistente Momentbilder erzeugen. |
| Schutzmechanismus | Der Code prüft die Analyseklassen `CATALOG_DEEP`. Verlangt deren Policy ein Gruppengate, ist zusätzlich `@HighImpactConfirmed = 1` nötig; Freigabe und Bestätigung ersetzen keine Scopebegrenzung. |
| Sicherer Einsatz | Eine ExampleDb, ein ExampleObject und wenige Statistiken; erst danach weitere Histogramme oder Partitionen aufnehmen. |
| Aussagegrenze | Scope- oder Zeilenbegrenzungen können relevante, seltene oder später einsortierte Zeilen ausblenden. Die Aussage bleibt auf das Modell „Katalogsnapshot“, die dokumentierte Granularität und den sichtbaren Quellenscope begrenzt; ein kleines Resultset ist weder automatisch vollständig noch repräsentativ. |

## Technische Vertiefung

[Gemeinsames Execution-, Zeit- und Evidenzmodell](../Technical_Foundations.md)

### Leitfrage

Welche Datenverteilung bildet das Histogramm ab, und wo können Skew, dominante Werte oder grobe Rangeannahmen Schätzungen erschweren?

### Technischer Hintergrund

Histogrammsteps speichern `RANGE_HI_KEY`, `EQ_ROWS`, `RANGE_ROWS`, `DISTINCT_RANGE_ROWS` und `AVG_RANGE_ROWS`. Gleichheitsprädikate auf Stepgrenzen und Werte innerhalb einer Range werden unterschiedlich geschätzt. Skew- und Konzentrationskennzahlen des Frameworks sind abgeleitete Prüfwerte.

### Datenkette

`sys.columns`, `sys.databases`, `sys.dm_db_stats_histogram`, `sys.sp_executesql`, `sys.stats_columns`, `sys.types`.

### Source Select

Nach der vorgelagerten Zielauflösung zeigt der direkte Histogrammpfad die führende Statistikspalte und ihre Verteilung:

```sql
SELECT
      [sc].[stats_column_id]
    , [c].[name] AS [LeadingColumnName]
    , [ty].[name] AS [LeadingTypeName]
    , [h].[step_number]
    , [h].[range_high_key]
    , [h].[range_rows]
    , [h].[equal_rows]
    , [h].[distinct_range_rows]
FROM [sys].[stats_columns] AS [sc] WITH (NOLOCK)
JOIN [sys].[columns] AS [c] WITH (NOLOCK)
  ON [c].[object_id] = [sc].[object_id]
 AND [c].[column_id] = [sc].[column_id]
JOIN [sys].[types] AS [ty] WITH (NOLOCK)
  ON [ty].[user_type_id] = [c].[user_type_id]
CROSS APPLY [sys].[dm_db_stats_histogram]
            (@ObjectId, @StatisticsId) AS [h]
WHERE [sc].[object_id] = @ObjectId
  AND [sc].[stats_id] = @StatisticsId
  AND [sc].[stats_column_id] = 1;
```

**Wichtig für die Eigenlast:** `@ObjectId` und `@StatisticsId` stammen aus der zuvor eng begrenzten Kandidatenmenge von `USP_Statistics`. Das Histogramm nie für eine unbeabsichtigt breite Statistikmenge öffnen; konkrete Grenzwerte können fachliche Schlüssel enthalten und bleiben im Default abgeleitet beziehungsweise anonymisiert.

### Zeit- und Scope-Modell

Die Auswertung beschreibt das aktuelle Histogramm der letzten Statistikaktualisierung. Es enthält maximal 200 Steps und basiert gegebenenfalls auf einem Sample statt auf einem Vollscan.

### Bewertung und Gegenprobe

Verbinden Sie dominante EQ-Werte, große Ranges, eine geringe Distinctanzahl, die Samplequote, den Modification Counter und konkrete Parameterwerte. Die Verteilung ist besonders bei Parameter Sensitivity und stark unterschiedlichen Selectivities relevant.

### Typische Fehlinterpretation

Ein Skew-Score ist kein Produktfehler und kein universeller Threshold. Gute Pläne können trotz Skew entstehen; schlechte Schätzungen können ohne sichtbaren starken Skew vorkommen.

### Folgeanalyse

Für die weitere Analyse gelten folgende Schritte und Quellen: Showplan, Query Store PlanChanges/Regressions, gezieltes Statistikupdate nur nach Test.

## Primärquellen

- [sys.dm_db_stats_histogram](https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-views/sys-dm-db-stats-histogram-transact-sql?view=sql-server-ver17)

## Weiterführende Vertiefung

Die folgenden Quellen ergänzen die Produktspezifikation um Praxis- oder Toolingperspektiven. Sie sind keine Grundlage für versions-, Berechtigungs- oder Engineaussagen dieser Seite.

- [Ola Hallengren: Index and Statistics Maintenance – betriebliche Wartungsperspektive](https://ola.hallengren.com/sql-server-index-and-statistics-maintenance.html)

[Technische Detailbeschreibung](../03_Object_Index.md#6-monitorusp_statisticsdistributionanalysis)
