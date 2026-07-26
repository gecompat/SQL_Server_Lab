# [monitor].[USP_SchemaDesignAnalysis]

**Bereich:** Object und Index<br>
**Zweck:** Erzeugt normalisierte Findings zu Constraints, Foreign Keys, Indizes und Identity-Risiken.<br>
**Beobachtungsart:** Katalogsnapshot<br>
**Kostenklasse:** MEDIUM–HIGH_OPT_IN

## Entscheidungsfrage und Einsatz

Die Procedure beantwortet die Betriebsfrage: **Welche Schemamuster verdienen ein fachliches Designreview?** Sie unterstützt die Entscheidung, ob ein Struktur- oder Metadatensignal eine workloadbezogene Gegenprüfung rechtfertigt, nicht ob automatisch DDL ausgeführt werden soll.

## Nicht beantwortete Fragen

Die Procedure beantwortet keinen Geschäftsnutzen einer Strukturänderung, keine repräsentative Workload und keine automatische Aussage über den optimalen Index- oder Statistikzustand. Der Zeitvertrag ist im Abschnitt „Zeit- und Scope-Modell“ konkretisiert. Ein Einzelwert gilt daher nur für diesen Scope und Zeitpunkt; er belegt weder eine Ursache noch eine Entwicklung.

## Sicherer Einstieg

```sql
EXEC [monitor].[USP_SchemaDesignAnalysis]
      @DatabaseNames = N'[ExampleDatabase]',
      @HighImpactConfirmed = 1,
      @ResultSetArt = 'CONSOLE';
```

Die Procedure prüft ihren gesamten Ausführungspfad als `CATALOG_DEEP`. Die Bestätigung ist daher bereits für eine einzelne Datenbank nötig und ersetzt weder den engen Scope noch die Prüfung der Datenbankgröße.

Alle `Example*`-Werte im Aufruf sind synthetisch.

## Resultsets und Leserichtung

Der typisierte TABLE-Vertrag registriert `findings`. Status, Scope und Warnings sind vor den Fachergebnissen zu lesen. CONSOLE dient der interaktiven Triage; RAW und JSON erhalten den technischen Kontext, während TABLE nur die ausdrücklich benannten stabilen Resultsets schreibt. Resultsets mit unterschiedlicher Zeilengranularität dürfen nicht ungeprüft vereinigt oder summiert werden.

## Eine Zeile bedeutet

Eine Zeile entspricht einem Designfinding für ein betroffenes und gegebenenfalls verwandtes Objekt.

## So lesen

Berücksichtigen Sie `FindingCode`, Severity, Objekt, Related Object, Metrik, Evidence und `EvidenceLimit` gemeinsam.

## Warum kann das problematisch sein?

Nicht vertrauenswürdige Constraints, fehlende FK-Unterstützung oder fast erschöpfte Identitybereiche können Optimierung, DML und Verfügbarkeit beeinträchtigen.

## Wann ist es kein Problem?

Disabled oder ähnlich wirkende Objekte können Teil eines Lade-, Deployment- oder Constraintdesigns sein.

## Beispiele und Gegenbeispiele

**Synthetischer Problemfall (`Example*`):** Ein FK ohne passenden Index ist besonders relevant, wenn Parent-Änderungen große Childscans und Blocking erzeugen. Bei statischen Tabellen kann die Priorität niedriger sein. Prüfen Sie Usage, Pläne und Änderungsrisiko.

**Ähnlich aussehender Gegenfall:** Disabled oder ähnlich wirkende Objekte können Teil eines Lade-, Deployment- oder Constraintdesigns sein. Der gleiche Einzelwert kann deshalb bei `ExampleDb` ohne Nutzerauswirkung unkritisch sein, während er bei zeitgleicher SLA-Verletzung eine Vertiefung rechtfertigt.

## Leere oder partielle Ausgabe

Bei Katalogpfaden sind Featureabwesenheit, Filter, Offline-/Permission-Scope und tatsächlich fehlende Objekte getrennte Erklärungen.

Für `USP_SchemaDesignAnalysis` gilt zusätzlich: **keine Zeile** bedeutet, dass im sichtbaren und gefilterten Scope kein ausgabefähiger Datensatz entstand. **0** ist ein gemessener Nullwert nur dann, wenn die Quellspalte tatsächlich verfügbar war. **NULL** bedeutet unbekannt, nicht anwendbar oder nicht auflösbar. **PARTIAL/Warning** bedeutet, dass mindestens eine Teilquelle, Datenbank oder Detailstufe fehlt. Ein Limit kann eine nichtleere Quelle vollständig aus dem sichtbaren Ausschnitt verdrängen.

## Eigenlast und Grenzen

| Dimension | Aussage für diese Procedure |
|---|---|
| Kostenklasse | MEDIUM–HIGH_OPT_IN |
| Standardpfad | Eine explizit benannte `ExampleDatabase`; die Procedure prüft dort alle sichtbaren relevanten Constraints, Foreign Keys, Indizes, Identities und Sequences. Einen Objektfilter besitzt sie nicht. |
| Teuerster Pfad | `@DatabaseNames = NULL` über alle sichtbaren Userdatenbanken mit unbegrenzter Ausgabe bei sehr vielen Objekten, FK-Spalten und Indexspalten. Einen VOLL-Schalter gibt es nicht; bereits jeder fachliche Lauf ist `CATALOG_DEEP`. |
| Haupttreiber | Zahl gewählter Datenbanken/Objekte sowie Foreign Keys und -Spalten, Check-/Default-Constraints, Indizes und Identitymetadaten. Jeder Datenbankscope wird dynamisch katalogseitig ausgewertet; Benutzertabellenzeilen werden nicht gescannt. |
| Skalierung | Laufzeit und CPU wachsen mit dem Haupttreiber. Sortierung/Aggregation erhöht Speicher- und gegebenenfalls TempDB-Bedarf; breite Texte/XML sowie viele Zeilen erhöhen Netzwerk- und Clientkosten. Für USP_SchemaDesignAnalysis ist insbesondere die im Datenkettenabschnitt beschriebene Reihenfolge maßgeblich. |
| Ressourcen | CPU, Katalogseiten und TempDB für Joins/Aggregation; bei breitem Cross-Database-Scope zusätzlicher Compile- und Ergebnistransferaufwand. |
| Begrenzungswirkung | Nur Datenbankliste/-pattern begrenzen die Quellarbeit früh. `@MaxZeilen` wirkt nach den Katalogjoins, Signaturbildung und Findingregeln und begrenzt daher ausschließlich die ausgegebenen Findings. |
| Locking und Nebenwirkungen | Read-only; Katalogabfragen nehmen üblicherweise kurze Schema-Stability-Zugriffe und können mit gleichzeitigem DDL oder Datenbankstatuswechseln konkurrieren. |
| Schutzmechanismus | Der Code prüft die Analyseklassen `CATALOG_DEEP`. Verlangt deren Policy ein Gruppengate, ist zusätzlich `@HighImpactConfirmed = 1` nötig; Freigabe und Bestätigung ersetzen keine Scopebegrenzung. |
| Sicherer Einsatz | Mit genau einer `ExampleDatabase` starten, deren Objekt-/Indexanzahl vorab bekannt ist. Da kein Objektfilter existiert, große Datenbanken und mehrere Datenbanken nur nacheinander außerhalb der DDL-Spitze prüfen. |
| Aussagegrenze | Scope- oder Zeilenbegrenzungen können relevante, seltene oder später einsortierte Zeilen ausblenden. Die Aussage bleibt auf das Modell „Katalogsnapshot“, die dokumentierte Granularität und den sichtbaren Quellenscope begrenzt; ein kleines Resultset ist weder automatisch vollständig noch repräsentativ. |

## Technische Vertiefung

[Gemeinsames Execution-, Zeit- und Evidenzmodell](../Technical_Foundations.md)

### Leitfrage

Welche Schemamuster verdienen ein fachliches Designreview?

### Technischer Hintergrund

Die Procedure leitet normalisierte Findings aus Katalogmerkmalen ab, etwa Datentyp-, Schlüssel-, Index-, Nullable-, LOB- oder Constraintkonstellationen. Solche Regeln erkennen technische Gerüche, nicht die vollständige fachliche Semantik.

### Datenkette

`sys.check_constraints`, `sys.foreign_key_columns`, `sys.foreign_keys`, `sys.identity_columns`, `sys.index_columns`, `sys.indexes`, `sys.objects`, `sys.schemas`, `sys.sequences`, `sys.sp_executesql`, `sys.tables`.

### Source Select

Der Foreign-Key-Kern verbindet Constraint, Parent-/Referenztabelle, Schema und Spaltenzuordnung:

```sql
SELECT
      [ps].[name] AS [ParentSchema]
    , [pt].[name] AS [ParentTable]
    , [fk].[name] AS [ForeignKeyName]
    , [rs].[name] AS [ReferencedSchema]
    , [rt].[name] AS [ReferencedTable]
    , [fkc].[constraint_column_id]
    , [fkc].[parent_column_id]
    , [fkc].[referenced_column_id]
FROM [sys].[foreign_keys] AS [fk] WITH (NOLOCK)
JOIN [sys].[tables] AS [pt] WITH (NOLOCK)
  ON [pt].[object_id] = [fk].[parent_object_id]
JOIN [sys].[schemas] AS [ps] WITH (NOLOCK)
  ON [ps].[schema_id] = [pt].[schema_id]
JOIN [sys].[tables] AS [rt] WITH (NOLOCK)
  ON [rt].[object_id] = [fk].[referenced_object_id]
JOIN [sys].[schemas] AS [rs] WITH (NOLOCK)
  ON [rs].[schema_id] = [rt].[schema_id]
JOIN [sys].[foreign_key_columns] AS [fkc] WITH (NOLOCK)
  ON [fkc].[constraint_object_id] = [fk].[object_id]
WHERE [ps].[name] = N'ExampleSchema'
  AND [pt].[name] = N'ExampleObject';
```

**Wichtig für die Eigenlast:** Legen Sie Datenbank und Objekt vor Index-, Constraint-, Identity- und Sequence-Gegenprüfungen fest. Der breite High-Impact-Pfad liest mehrere Katalogbereiche; Findings entstehen erst danach und sind kein DDL-Auftrag.

### Zeit- und Scope-Modell

Die Auswertung beschreibt den aktuellen Metadatenstand; sie enthält keine Runtime- oder Workloadhistorie, sofern diese nicht ausdrücklich angereichert wurde.

### Bewertung und Gegenprobe

Betrachten Sie Severity/Confidence, Objektgröße, Workload, Datenqualität, Abhängigkeiten und Migrationsaufwand zusammen. Ein Finding mit hoher technischer Plausibilität kann fachlich bewusst sein.

### Typische Fehlinterpretation

Heuristik ist kein Beweis. Breite Spalten, fehlender PK oder bestimmter Datentyp können durch externe Verträge oder Stagingzweck begründet sein.

### Folgeanalyse

Für die weitere Analyse gelten folgende Schritte und Quellen: Object Inventory, Querypläne, Datenprofiling und fachliches Schemaowner-Review.

## Primärquellen

- [SQL-Server-Katalogsichten](https://learn.microsoft.com/en-us/sql/relational-databases/system-catalog-views/catalog-views-transact-sql?view=sql-server-ver17)

## Weiterführende Vertiefung

Die folgenden Quellen ergänzen die Produktspezifikation um Praxis- oder Toolingperspektiven. Sie sind keine Grundlage für versions-, Berechtigungs- oder Engineaussagen dieser Seite.

- [SQL Server First Responder Kit – ergänzende, quelloffene Praxiswerkzeuge für Triage](https://github.com/BrentOzarULTD/SQL-Server-First-Responder-Kit)

[Technische Detailbeschreibung](../03_Object_Index.md#11-monitorusp_schemadesignanalysis)
