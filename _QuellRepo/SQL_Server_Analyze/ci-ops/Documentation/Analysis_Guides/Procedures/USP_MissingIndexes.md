# [monitor].[USP_MissingIndexes]

**Bereich:** Object und Index<br>
**Zweck:** Priorisiert flüchtige Missing-Index-Evidenz und erzeugt einen ausdrücklich unverbindlichen DDL-Entwurf.<br>
**Beobachtungsart:** kumulativ seit Struktur-/Instanzreset<br>
**Kostenklasse:** LOW–MEDIUM

## Entscheidungsfrage und Einsatz

Die Procedure beantwortet die Betriebsfrage: **Welche zusätzlichen Nonclustered-Indexstrukturen hat der Optimizer während Kompilierungen als potenziell kostensenkend eingeschätzt?** Sie unterstützt die Entscheidung, ob ein Struktur- oder Metadatensignal eine workloadbezogene Gegenprüfung rechtfertigt, nicht ob automatisch DDL ausgeführt werden soll.

## Nicht beantwortete Fragen

Die Procedure beantwortet keinen Geschäftsnutzen einer Strukturänderung, keine repräsentative Workload und keine automatische Aussage über den optimalen Index- oder Statistikzustand. Der Zeitvertrag ist im Abschnitt „Zeit- und Scope-Modell“ konkretisiert. Ein Einzelwert gilt daher nur für diesen Scope und Zeitpunkt; er belegt weder eine Ursache noch eine Entwicklung.

## Sicherer Einstieg

```sql
EXEC [monitor].[USP_MissingIndexes]
      @DatabaseNames = N'[ExampleDatabase]',
      @MinUserReads = 10,
      @ResultSetArt = 'CONSOLE';
```

Alle `Example*`-Werte im Aufruf sind synthetisch.

## Resultsets und Leserichtung

Der typisierte TABLE-Vertrag registriert `missingIndexes`. Status, Scope und Warnings sind vor den Fachergebnissen zu lesen. CONSOLE dient der interaktiven Triage; RAW und JSON erhalten den technischen Kontext, während TABLE nur die ausdrücklich benannten stabilen Resultsets schreibt. Resultsets mit unterschiedlicher Zeilengranularität dürfen nicht ungeprüft vereinigt oder summiert werden.

## Eine Zeile bedeutet

Eine Zeile entspricht einer Missing-Index-Gruppe aus den Optimizer-DMVs, nicht einem fertig geprüften Indexdesign.

## So lesen

Prüfen Sie zuerst Reads und Compiles und danach Impact und Improvement Measure. Vergleichen Sie Schlüssel und Includes mit vorhandenen Indizes.

## Warum kann das problematisch sein?

Der Optimizer sieht mögliche Lesekosten, aber nicht vollständig Schreiblast, Speicher, Wartung, Redundanz und fachliche Abhängigkeiten.

## Wann ist es kein Problem?

98 % Impact bei zwei Reads ist plakativ, aber schwach. Ein ähnlicher vorhandener Index kann den Vorschlag überflüssig machen.

## Beispiele und Gegenbeispiele

**Synthetischer Problemfall (`Example*`):** 25 % Impact bei fünf Millionen Reads kann mehr Gesamtnutzen besitzen als 99 % bei einer Ausführung. Prüfen Sie vor DDL immer Inventar, Usage, Querytext, Plan und Write-Last.

**Ähnlich aussehender Gegenfall:** 98 % Impact bei zwei Reads ist plakativ, aber schwach. Ein ähnlicher vorhandener Index kann den Vorschlag überflüssig machen. Der gleiche Einzelwert kann deshalb bei `ExampleDb` ohne Nutzerauswirkung unkritisch sein, während er bei zeitgleicher SLA-Verletzung eine Vertiefung rechtfertigt.

## Leere oder partielle Ausgabe

Bei Katalogpfaden sind Featureabwesenheit, Filter, Offline-/Permission-Scope und tatsächlich fehlende Objekte getrennte Erklärungen.

Für `USP_MissingIndexes` gilt zusätzlich: **keine Zeile** bedeutet, dass im sichtbaren und gefilterten Scope kein ausgabefähiger Datensatz entstand. **0** ist ein gemessener Nullwert nur dann, wenn die Quellspalte tatsächlich verfügbar war. **NULL** bedeutet unbekannt, nicht anwendbar oder nicht auflösbar. **PARTIAL/Warning** bedeutet, dass mindestens eine Teilquelle, Datenbank oder Detailstufe fehlt. Ein Limit kann eine nichtleere Quelle vollständig aus dem sichtbaren Ausschnitt verdrängen.

Missing-Index-DMVs sind flüchtig und begrenzt. Leer kann Reset, fehlende Compiles oder nicht geeignete Queries bedeuten.

## Eigenlast und Grenzen

**Quellcode-Hinweis zur Eigenlast:** DMV-Menge ist intern begrenzt; Join und Sortierung werden durch TOP begrenzt.

| Dimension | Aussage für diese Procedure |
|---|---|
| Kostenklasse | LOW–MEDIUM |
| Standardpfad | Eine explizit benannte `ExampleDatabase`, möglichst ein Objekt und endliches Limit; die intern begrenzten Missing-Index-DMVs werden mit Objektkatalogen verbunden. |
| Teuerster Pfad | Alle sichtbaren Datenbanken, keine Objekt-/Mindestschwelle und `@MaxZeilen = 0`; einen `VOLL`-Modus oder physischen Scan besitzt die Procedure nicht. |
| Haupttreiber | Zahl gewählter Datenbanken und sichtbarer Missing-Index-Detail-/Group-Stats-Zeilen sowie Breite der Spaltenlisten für den DDL-Entwurf. Datenbank-/Objektfilter wirken vor Ranking; das Ausgabelimit ersetzt keine vollständige DMV-Korrelation. |
| Skalierung | Laufzeit und CPU wachsen mit dem Haupttreiber. Sortierung/Aggregation erhöht Speicher- und gegebenenfalls TempDB-Bedarf; breite Texte/XML sowie viele Zeilen erhöhen Netzwerk- und Clientkosten. Für USP_MissingIndexes ist insbesondere die im Datenkettenabschnitt beschriebene Reihenfolge maßgeblich. |
| Ressourcen | CPU, Katalogseiten und TempDB für Joins/Aggregation; bei breitem Cross-Database-Scope zusätzlicher Compile- und Ergebnistransferaufwand. |
| Begrenzungswirkung | Datenbank-/Objektfilter begrenzen die Quellarbeit. TOP oder MaxZeilen werden häufig nach Katalogjoins und Aggregation angewandt und sind dann nur Ausgabelimits. |
| Locking und Nebenwirkungen | Read-only; Katalogabfragen nehmen üblicherweise kurze Schema-Stability-Zugriffe und können mit gleichzeitigem DDL oder Datenbankstatuswechseln konkurrieren. |
| Schutzmechanismus | `MISSING_INDEX_CURRENT` muss freigegeben sein, verlangt laut Klassenkatalog keine High-Impact-Bestätigung. `@HighImpactConfirmed` aktiviert keinen weiteren Pfad; Datenbank-/Objektfilter und Schwellen sind die Schutzgrenzen. |
| Sicherer Einsatz | Mit einer `ExampleDatabase`, einem `ExampleObject`, sinnvollen Mindestreads/-impact und endlichem Limit starten; mehrere Datenbanken anschließend einzeln ergänzen. |
| Aussagegrenze | Scope- oder Zeilenbegrenzungen können relevante, seltene oder später einsortierte Zeilen ausblenden. Die Aussage bleibt auf das Modell „kumulativ seit Struktur-/Instanzreset“, die dokumentierte Granularität und den sichtbaren Quellenscope begrenzt; ein kleines Resultset ist weder automatisch vollständig noch repräsentativ. |

## Technische Vertiefung

[Gemeinsames Execution-, Zeit- und Evidenzmodell](../Technical_Foundations.md)

### Leitfrage

Welche zusätzlichen Nonclustered-Indexstrukturen hat der Optimizer während Kompilierungen als potenziell kostensenkend eingeschätzt?

### Technischer Hintergrund

Missing-Index-DMVs sammeln Gleichheits-, Ungleichheits- und Include-Spalten aus Optimizerentscheidungen. Der oft verwendete Improvement-Wert kombiniert geschätzte Kosten, Impact und Nutzungshäufigkeit; er ist eine Priorisierungsheuristik. Die Engine konsolidiert Vorschläge nicht automatisch mit bestehenden Indizes.

### Datenkette

`sys.dm_db_missing_index_details`, `sys.dm_db_missing_index_group_stats`, `sys.dm_db_missing_index_groups`, `sys.objects`, `sys.schemas`, `sys.sp_executesql`, `sys.tables`.

### Source Select

Die drei Missing-Index-DMVs werden über Group- und Index-Handle verbunden; der Datenbankscope gehört in die erste Kandidatenmenge:

```sql
SELECT
      [mid].[database_id]
    , [mid].[object_id]
    , [mid].[equality_columns]
    , [mid].[inequality_columns]
    , [mid].[included_columns]
    , [migs].[user_seeks]
    , [migs].[user_scans]
    , [migs].[avg_total_user_cost]
    , [migs].[avg_user_impact]
FROM [sys].[dm_db_missing_index_details] AS [mid] WITH (NOLOCK)
JOIN [sys].[dm_db_missing_index_groups] AS [mig] WITH (NOLOCK)
  ON [mig].[index_handle] = [mid].[index_handle]
JOIN [sys].[dm_db_missing_index_group_stats] AS [migs] WITH (NOLOCK)
  ON [migs].[group_handle] = [mig].[index_group_handle]
WHERE [mid].[database_id] = DB_ID()
  AND [migs].[user_seeks] + [migs].[user_scans] >= @MinUserReads;
```

**Wichtig für die Eigenlast:** Filtern Sie Datenbank und Mindestnutzung vor der Objekt- und Schemaauflösung sowie dem DDL-Entwurf. Die DMVs bleiben serverweit flüchtig; ein `TOP` nach der Bewertung reduziert nicht die zugrunde liegende DMV-Menge.

### Zeit- und Scope-Modell

Die Daten sind seit einem Neustart oder Reset flüchtig beziehungsweise kumulativ und auf eine begrenzte Anzahl gespeicherter Gruppen beschränkt. Vorschläge können nach Änderungen am Plan Cache oder an Metadaten verschwinden.

### Bewertung und Gegenprobe

Prüfen Sie Queryhäufigkeit, Kosten, tatsächliche Reads, vorhandene Präfixe und Includes, Selectivity, DML-Kosten, Speicher und Locking. Konsolidieren Sie mehrere Vorschläge nach fachlicher Prüfung zu einem tragfähigen Indexdesign.

### Typische Fehlinterpretation

Ein hoher Improvement-Wert ist keine gemessene Einsparung. Der Vorschlag kennt Write Amplification, andere Queries, Filtered Indexes und vollständige Datenverteilung nur begrenzt.

### Folgeanalyse

Verwenden Sie für die weitere Analyse die betroffenen Pläne, Query Store, `USP_ObjectInventory` und `USP_IndexUsage`. Führen Sie DDL nur nach einem Test und mit einem Rollbackplan aus.

## Primärquellen

- [Missing-Index-DMVs](https://learn.microsoft.com/en-us/sql/relational-databases/indexes/tune-nonclustered-missing-index-suggestions?view=sql-server-ver17)

## Weiterführende Vertiefung

Die folgenden Quellen ergänzen die Produktspezifikation um Praxis- oder Toolingperspektiven. Sie sind keine Grundlage für versions-, Berechtigungs- oder Engineaussagen dieser Seite.

- [Ola Hallengren: Index and Statistics Maintenance – betriebliche Wartungsperspektive](https://ola.hallengren.com/sql-server-index-and-statistics-maintenance.html)

[Technische Detailbeschreibung](../03_Object_Index.md#4-monitorusp_missingindexes)
