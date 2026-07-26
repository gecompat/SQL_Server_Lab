# [monitor].[USP_IndexUsage]

**Bereich:** Object und Index<br>
**Zweck:** Zeigt kumulative Read-/Write-Nutzung klassischer und optional In-Memory-Indizes.<br>
**Beobachtungsart:** kumulativ seit Struktur-/Instanzreset<br>
**Kostenklasse:** LOW–HIGH_OPT_IN

## Entscheidungsfrage und Einsatz

Die Procedure beantwortet die Betriebsfrage: **Welche sichtbaren Reads und Writes wurden einem Index seit dem DMV-Reset zugerechnet?** Sie unterstützt die Entscheidung, ob ein Struktur- oder Metadatensignal eine workloadbezogene Gegenprüfung rechtfertigt, nicht ob automatisch DDL ausgeführt werden soll.

## Nicht beantwortete Fragen

Die Procedure beantwortet keinen Geschäftsnutzen einer Strukturänderung, keine repräsentative Workload und keine automatische Aussage über den optimalen Index- oder Statistikzustand. Der Zeitvertrag ist im Abschnitt „Zeit- und Scope-Modell“ konkretisiert. Ein Einzelwert gilt daher nur für diesen Scope und Zeitpunkt; er belegt weder eine Ursache noch eine Entwicklung.

## Sicherer Einstieg

```sql
EXEC [monitor].[USP_IndexUsage]
      @DatabaseNames = N'[ExampleDatabase]',
      @ResultSetArt = 'CONSOLE';
```

Alle `Example*`-Werte im Aufruf sind synthetisch.

## Resultsets und Leserichtung

Der typisierte TABLE-Vertrag registriert `rowstoreIndexes`. Status, Scope und Warnings sind vor den Fachergebnissen zu lesen. CONSOLE dient der interaktiven Triage; RAW und JSON erhalten den technischen Kontext, während TABLE nur die ausdrücklich benannten stabilen Resultsets schreibt. Resultsets mit unterschiedlicher Zeilengranularität dürfen nicht ungeprüft vereinigt oder summiert werden.

## Eine Zeile bedeutet

Eine Zeile entspricht einem Index im sichtbaren DMV-Scope; XTP-Indizes erscheinen in einem separaten Resultset mit eigener Zählersemantik.

## So lesen

Berücksichtigen Sie Resetzeit, Reads, Updates, letzte Nutzung und Schutzmerkmale wie PK, Unique oder Constraint gemeinsam.

## Warum kann das problematisch sein?

Viele Updates ohne Reads bedeuten mögliche Schreib-, Log-, Lock- und Speicherlast ohne sichtbaren Lesebedarf.

## Wann ist es kein Problem?

Kurzes Beobachtungsfenster, saisonale Reports oder Constraintfunktionen machen `0 Reads` unzureichend für eine Löschungsentscheidung.

## Beispiele und Gegenbeispiele

**Synthetischer Problemfall (`Example*`):** 0 Reads, 8 Mio. Updates, 180 Tage Beobachtung: starker Reviewkandidat. 0 Reads, 40 Updates, zwei Stunden seit Restart: praktisch keine belastbare Aussage.

**Bisher dokumentierter Folgeschritt:** Prüfen Sie Query Store, Abhängigkeiten, Constraints und `USP_IndexOperationalStats`. Löschen Sie niemals allein aus dieser DMV einen Index.

**Ähnlich aussehender Gegenfall:** Kurzes Beobachtungsfenster, saisonale Reports oder Constraintfunktionen machen `0 Reads` unzureichend für eine Löschungsentscheidung. Der gleiche Einzelwert kann deshalb bei `ExampleDb` ohne Nutzerauswirkung unkritisch sein, während er bei zeitgleicher SLA-Verletzung eine Vertiefung rechtfertigt.

## Leere oder partielle Ausgabe

Bei Katalogpfaden sind Featureabwesenheit, Filter, Offline-/Permission-Scope und tatsächlich fehlende Objekte getrennte Erklärungen.

Für `USP_IndexUsage` gilt zusätzlich: **keine Zeile** bedeutet, dass im sichtbaren und gefilterten Scope kein ausgabefähiger Datensatz entstand. **0** ist ein gemessener Nullwert nur dann, wenn die Quellspalte tatsächlich verfügbar war. **NULL** bedeutet unbekannt, nicht anwendbar oder nicht auflösbar. **PARTIAL/Warning** bedeutet, dass mindestens eine Teilquelle, Datenbank oder Detailstufe fehlt. Ein Limit kann eine nichtleere Quelle vollständig aus dem sichtbaren Ausschnitt verdrängen.

## Eigenlast und Grenzen

**Quellcode-Hinweis zur Eigenlast:** Die DMV- und Katalogabfrage besitzt eine moderate Eigenlast; Physical-Stats-Scans werden nicht ausgeführt.

| Dimension | Aussage für diese Procedure |
|---|---|
| Kostenklasse | LOW–HIGH_OPT_IN |
| Standardpfad | Eine explizit benannte `ExampleDatabase` und ein Objekt im Modus `GEZIELT`; klassische und optional In-Memory-Indexzähler werden korreliert. |
| Teuerster Pfad | Cross-Database-`VOLL`, unbegrenzte Ausgabe, Memory-Optimized-Pfad und alle sichtbaren Indizes auf einer indexreichen Instanz. Es werden weiterhin keine Physical Stats gelesen. |
| Haupttreiber | Zahl gewählter Datenbanken/Objekte und ihrer klassischen Indizes sowie optional XTP-Indizes. Katalog-/Usage-Stats-Korrelation erfolgt je Datenbank; ein späteres Rankinglimit spart diese Vorarbeit nicht vollständig. |
| Skalierung | Laufzeit und CPU wachsen mit dem Haupttreiber. Sortierung/Aggregation erhöht Speicher- und gegebenenfalls TempDB-Bedarf; breite Texte/XML sowie viele Zeilen erhöhen Netzwerk- und Clientkosten. Für USP_IndexUsage ist insbesondere die im Datenkettenabschnitt beschriebene Reihenfolge maßgeblich. |
| Ressourcen | CPU, Katalogseiten und TempDB für Joins/Aggregation; bei breitem Cross-Database-Scope zusätzlicher Compile- und Ergebnistransferaufwand. |
| Begrenzungswirkung | Datenbank-/Objektfilter begrenzen die Quellarbeit. TOP oder MaxZeilen werden häufig nach Katalogjoins und Aggregation angewandt und sind dann nur Ausgabelimits. |
| Locking und Nebenwirkungen | Read-only; Katalogabfragen nehmen üblicherweise kurze Schema-Stability-Zugriffe und können mit gleichzeitigem DDL oder Datenbankstatuswechseln konkurrieren. |
| Schutzmechanismus | Der gezielte `OBJECT_ANALYSIS_CURRENT`-Pfad braucht keine High-Impact-Bestätigung. `VOLL` prüft zusätzlich `CATALOG_DEEP` und erfordert `@HighImpactConfirmed = 1`. |
| Sicherer Einsatz | Mit einer ExampleDb und einem ExampleObject starten; erst nach Größenprüfung auf mehrere Datenbanken oder VOLL erweitern. |
| Aussagegrenze | Scope- oder Zeilenbegrenzungen können relevante, seltene oder später einsortierte Zeilen ausblenden. Die Aussage bleibt auf das Modell „kumulativ seit Struktur-/Instanzreset“, die dokumentierte Granularität und den sichtbaren Quellenscope begrenzt; ein kleines Resultset ist weder automatisch vollständig noch repräsentativ. |

## Technische Vertiefung

[Gemeinsames Execution-, Zeit- und Evidenzmodell](../Technical_Foundations.md)

### Leitfrage

Welche sichtbaren Reads und Writes wurden einem Index seit dem DMV-Reset zugerechnet?

### Technischer Hintergrund

`sys.dm_db_index_usage_stats` zählt user/system seeks, scans, lookups und updates sowie letzte Zeitpunkte. Ein einzelnes DML-Statement kann mehrere Indexupdates verursachen. Der Zähler erfasst nicht jede semantische Abhängigkeit, etwa Constraintwirkung oder seltene saisonale Reports.

### Datenkette

`sys.dm_db_index_usage_stats`, `sys.dm_db_xtp_index_stats`, `sys.dm_os_sys_info`, `sys.hash_indexes`, `sys.indexes`, `sys.objects`, `sys.partitions`, `sys.schemas`, `sys.sp_executesql`, `sys.tables`.

### Source Select

Die kumulative Nutzungs-DMV wird über Datenbank-, Objekt- und Index-ID mit dem Katalog verbunden:

```sql
SELECT
      [s].[name] AS [SchemaName]
    , [o].[name] AS [ObjectName]
    , [i].[name] AS [IndexName]
    , [us].[user_seeks]
    , [us].[user_scans]
    , [us].[user_lookups]
    , [us].[user_updates]
FROM [sys].[indexes] AS [i] WITH (NOLOCK)
JOIN [sys].[objects] AS [o] WITH (NOLOCK)
  ON [o].[object_id] = [i].[object_id]
JOIN [sys].[schemas] AS [s] WITH (NOLOCK)
  ON [s].[schema_id] = [o].[schema_id]
LEFT JOIN [sys].[dm_db_index_usage_stats] AS [us] WITH (NOLOCK)
  ON [us].[database_id] = DB_ID()
 AND [us].[object_id] = [i].[object_id]
 AND [us].[index_id] = [i].[index_id]
WHERE [s].[name] = N'ExampleSchema'
  AND [o].[name] = N'ExampleObject';
```

**Wichtig für die Eigenlast:** Datenbank und Objekt im Katalogpfad früh eingrenzen. XTP-Indexstatistiken sind ein separater optionaler Zweig; fehlende DMV-Zeilen bedeuten nicht automatisch ungenutzte Indizes.

### Zeit- und Scope-Modell

Die Zähler sind innerhalb des jeweiligen Engine-, Datenbank- oder DMV-Lebenszyklus kumulativ. Neustart, Detach und Attach, Offline und Online sowie andere Ereignisse können den Beobachtungszeitraum verkürzen.

### Bewertung und Gegenprobe

Berücksichtigen Sie Reads, Updates, letzte Nutzung, Uptime oder Resetzeit, Indexgröße und Schutzstatus gemeinsam. Viele Updates ohne Reads über ein ausreichend langes, repräsentatives Fenster kennzeichnen einen Reviewkandidaten, aber keinen Dropbefehl.

### Typische Fehlinterpretation

`0 Reads` bedeutet nur keine in dieser DMV sichtbare Nutzung im Fenster. Prüfen Sie Planforcing, Query Store, Wartung, FK/Unique/PK und Monats-/Jahresworkloads gegen.

### Folgeanalyse

Für die weitere Analyse gelten folgende Schritte und Quellen: `USP_IndexOperationalStats`, Query Store, Dependency-/Constraintreview.

## Primärquellen

- [sys.dm_db_index_usage_stats](https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-views/sys-dm-db-index-usage-stats-transact-sql?view=sql-server-ver17)

## Weiterführende Vertiefung

Die folgenden Quellen ergänzen die Produktspezifikation um Praxis- oder Toolingperspektiven. Sie sind keine Grundlage für versions-, Berechtigungs- oder Engineaussagen dieser Seite.

- [Ola Hallengren: Index and Statistics Maintenance – betriebliche Wartungsperspektive](https://ola.hallengren.com/sql-server-index-and-statistics-maintenance.html)

[Technische Detailbeschreibung](../03_Object_Index.md#2-monitorusp_indexusage)
