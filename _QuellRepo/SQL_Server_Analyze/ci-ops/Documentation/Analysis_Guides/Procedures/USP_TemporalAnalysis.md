# [monitor].[USP_TemporalAnalysis]

**Bereich:** Versionsadaptive Spezialanalysen<br>
**Zweck:** Analysiert Temporal-Current-/History-Beziehungen, Retention, Größe, Indizes und Konsistenz.<br>
**Beobachtungsart:** Katalogsnapshot + aktueller Kapazitätszustand<br>
**Kostenklasse:** MEDIUM–HIGH_OPT_IN

## Entscheidungsfrage und Einsatz

Die Procedure beantwortet die Betriebsfrage: **Welche system-versioned Tabellen besitzen welche History-, Period-, Retention-, Größen- und Indexkonfiguration?** Sie unterstützt die Entscheidung, ob das Spezialfeature vorhanden und in einem auffälligen Zustand ist und welches featureeigene Diagnoseverfahren als Nächstes gebraucht wird.

## Nicht beantwortete Fragen

Die Procedure beantwortet keine fachliche Korrektheit der Featurekonfiguration, keine geschützten Inhalte und keine End-to-End-Funktionsprüfung außerhalb sichtbarer Metadaten. Der Zeitvertrag ist im Abschnitt „Zeit- und Scope-Modell“ konkretisiert. Ein Einzelwert gilt daher nur für diesen Scope und Zeitpunkt; er belegt weder eine Ursache noch eine Entwicklung.

## Sicherer Einstieg

```sql
EXEC [monitor].[USP_TemporalAnalysis]
      @DatabaseNames = N'[ExampleDatabase]',
      @HighImpactConfirmed = 1,
      @ResultSetArt = 'CONSOLE';
```

Der Katalog- und Größenpfad ist durchgängig als `CATALOG_DEEP` klassifiziert. Die Bestätigung ist auch für eine einzelne Datenbank erforderlich; sie ist keine Freigabe für einen ungefilterten Cross-Database-Lauf.

Alle `Example*`-Werte im Aufruf sind synthetisch.

## Resultsets und Leserichtung

Der typisierte TABLE-Vertrag registriert `findings`. Status, Scope und Warnings sind vor den Fachergebnissen zu lesen. CONSOLE dient der interaktiven Triage; RAW und JSON erhalten den technischen Kontext, während TABLE nur die ausdrücklich benannten stabilen Resultsets schreibt. Resultsets mit unterschiedlicher Zeilengranularität dürfen nicht ungeprüft vereinigt oder summiert werden.

## Eine Zeile bedeutet

Je Resultset entspricht eine Zeile einer Temporal-Tabelle, History-Beziehung, Retention-/Cleanup-Evidenz, Index-/Kapazitätsinformation oder einem Finding.

## So lesen

Vergleichen Sie Current-/History-Zuordnung, Historygröße, Retention, Konsistenzstatus, Indexierung und Wachstum.

## Warum kann das problematisch sein?

Unbegrenzte oder wirkungslose Retention kann History stark wachsen lassen; ungeeignete Indizes verteuern Zeitabfragen und Cleanup.

## Wann ist es kein Problem?

Große History kann fachlich erforderlich und durch Partitionierung oder Archivierung kontrolliert sein.

## Beispiele und Gegenbeispiele

**Synthetischer Problemfall (`Example*`):** History wächst monatlich stark, Retention ist konfiguriert, Cleanup zeigt aber keine Wirkung: konkreter Betriebsbefund. Prüfen Sie Kapazität, Partitionierung, Cleanup und Pläne.

**Ähnlich aussehender Gegenfall:** Große History kann fachlich erforderlich und durch Partitionierung oder Archivierung kontrolliert sein. Der gleiche Einzelwert kann deshalb bei `ExampleDb` ohne Nutzerauswirkung unkritisch sein, während er bei zeitgleicher SLA-Verletzung eine Vertiefung rechtfertigt.

## Leere oder partielle Ausgabe

Nicht installiert, nicht aktiviert, in der gewählten Datenbank nicht verwendet und nicht abfragbar sind vier verschiedene Zustände.

Für `USP_TemporalAnalysis` gilt zusätzlich: **keine Zeile** bedeutet, dass im sichtbaren und gefilterten Scope kein ausgabefähiger Datensatz entstand. **0** ist ein gemessener Nullwert nur dann, wenn die Quellspalte tatsächlich verfügbar war. **NULL** bedeutet unbekannt, nicht anwendbar oder nicht auflösbar. **PARTIAL/Warning** bedeutet, dass mindestens eine Teilquelle, Datenbank oder Detailstufe fehlt. Ein Limit kann eine nichtleere Quelle vollständig aus dem sichtbaren Ausschnitt verdrängen.

## Eigenlast und Grenzen

| Dimension | Aussage für diese Procedure |
|---|---|
| Kostenklasse | MEDIUM–HIGH_OPT_IN |
| Standardpfad | Eine `ExampleDatabase`, Problemscope und möglichst ein Temporal-Objektfilter; Katalogbeziehungen, approximative Partitionsgröße und History-Indexabdeckung werden gelesen. |
| Teuerster Pfad | Alle sichtbaren Datenbanken ohne Objektfilter und unbegrenzte Ausgabe bei sehr vielen Temporal-/Historytabellen, Partitionen und History-Indizes. Benutzertabellenzeilen werden auch dann nicht gelesen. |
| Haupttreiber | Zahl ausgewählter Datenbanken und Temporal-/Historytabellen, deren Partitionen und History-Indizes. Objektfilter reduzieren diese Katalogmenge früh; Zeilen aus Current- oder Historytabellen werden nicht gelesen. |
| Skalierung | Aufwand wächst mit Temporal-Paaren, ihren Partitionen und History-Indizes. `sys.dm_db_partition_stats` liefert approximative Größen ohne History-Datenscan; dynamisches SQL und Findingregeln laufen je Datenbank. |
| Ressourcen | CPU und Katalog-/Partitionsmetadaten-I/O, dynamischer Compileaufwand und kleine TempDB-/Arbeitstabellen für Temporalpaare, Indizes und Findings. |
| Begrenzungswirkung | Datenbank-/Objektfilter begrenzen Katalog- und Partitionsmetadatenarbeit. `@NurProblematisch` und `@MaxZeilen` wirken erst auf fertige Findings/Detailtabellen und begrenzen die vorgelagerte Inventur nicht. |
| Locking und Nebenwirkungen | Read-only ohne DDL oder Historydatenzugriff; gleichzeitiges `SYSTEM_VERSIONING`-/Index-DDL kann zwischen Katalog- und Größenprobe einen Mischstand erzeugen. |
| Schutzmechanismus | Der Code prüft die Analyseklassen `CATALOG_DEEP`. Verlangt deren Policy ein Gruppengate, ist zusätzlich `@HighImpactConfirmed = 1` nötig; Freigabe und Bestätigung ersetzen keine Scopebegrenzung. |
| Sicherer Einsatz | Eine bekannte `ExampleDatabase`, Problemscope und ein konkretes Temporalobjekt. Trotz `CATALOG_DEEP`-Bestätigung erst Datenbankstatus und Quellenfehler lesen, dann Größe/Indexbefund bewerten. |
| Aussagegrenze | Scope- oder Zeilenbegrenzungen können relevante, seltene oder später einsortierte Zeilen ausblenden. Die Aussage bleibt auf das Modell „Katalogsnapshot + aktueller Kapazitätszustand“, die dokumentierte Granularität und den sichtbaren Quellenscope begrenzt; ein kleines Resultset ist weder automatisch vollständig noch repräsentativ. |

## Technische Vertiefung

[Gemeinsames Execution-, Zeit- und Evidenzmodell](../Technical_Foundations.md)

### Leitfrage

Welche system-versioned Tabellen besitzen welche History-, Period-, Retention-, Größen- und Indexkonfiguration?

### Technischer Hintergrund

Temporal Tables schreiben bei Update/Delete frühere Rowversionen in eine History Table; Period Columns definieren Gültigkeit. System Versioning, Data Consistency Check und Retention steuern Lebenszyklus. Historyzugriffe über `FOR SYSTEM_TIME` benötigen passende Indizes/Partitionierung.

### Datenkette

`sys.columns`, `sys.databases`, `sys.dm_db_partition_stats`, `sys.index_columns`, `sys.indexes`, `sys.periods`, `sys.schemas`, `sys.sp_executesql`, `sys.tables`.

### Source Select

System-versionierte Tabelle, History-Tabelle, Schema und Periodendefinition werden über Katalog-IDs verbunden:

```sql
SELECT
      [s].[name] AS [SchemaName]
    , [t].[name] AS [TableName]
    , [t].[temporal_type_desc]
    , [hs].[name] AS [HistorySchemaName]
    , [ht].[name] AS [HistoryTableName]
    , [p].[start_column_id]
    , [p].[end_column_id]
FROM [sys].[tables] AS [t] WITH (NOLOCK)
JOIN [sys].[schemas] AS [s] WITH (NOLOCK)
  ON [s].[schema_id] = [t].[schema_id]
LEFT JOIN [sys].[tables] AS [ht] WITH (NOLOCK)
  ON [ht].[object_id] = [t].[history_table_id]
LEFT JOIN [sys].[schemas] AS [hs] WITH (NOLOCK)
  ON [hs].[schema_id] = [ht].[schema_id]
LEFT JOIN [sys].[periods] AS [p] WITH (NOLOCK)
  ON [p].[object_id] = [t].[object_id]
WHERE [t].[temporal_type] <> 0
  AND [s].[name] = N'ExampleSchema'
  AND [t].[name] = N'ExampleObject';
```

**Wichtig für die Eigenlast:** Legen Sie Datenbank und Objekt vor History-Größen-, Partition- und Indexanalyse fest. Berücksichtigen Sie `dm_db_partition_stats` erst für die aufgelösten Current-/History-Objekt-IDs.

### Zeit- und Scope-Modell

Die Auswertung beschreibt den aktuellen Schemastand sowie die angesammelten Historydaten innerhalb der fachlichen und technischen Retention.

### Bewertung und Gegenprobe

Berücksichtigen Sie Current und History Table, Period Columns, Retention, Größe und Zeilenanzahl der History Table, Indexierung, Partitionierung und Cleanupstatus. Die Schreibrate und typische Zeitprädikate bestimmen das Design.

### Typische Fehlinterpretation

Große History ist nicht automatisch Problem; sie kann Complianceanforderung sein. Temporal ON beweist keine erfolgreiche Retentionbereinigung.

### Folgeanalyse

Für die weitere Analyse gelten folgende Schritte und Quellen: Object/Index/Partition/Capacity, konkrete Temporal Querypläne und Retentionpolicy.

## Primärquellen

- [Temporal Tables](https://learn.microsoft.com/en-us/sql/relational-databases/tables/temporal-tables?view=sql-server-ver17)

[Technische Detailbeschreibung](../09_Version_Adaptive.md#4-monitorusp_temporalanalysis)
