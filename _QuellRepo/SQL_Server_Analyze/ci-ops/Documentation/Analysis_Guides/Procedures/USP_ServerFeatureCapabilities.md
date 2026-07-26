# [monitor].[USP_ServerFeatureCapabilities]

**Bereich:** Versionsadaptive Spezialanalysen<br>
**Zweck:** Zeigt versions-, editions-, plattform- und datenbankbezogene Featurefähigkeiten einschließlich SQL-Server-2025-JSON-Indexmetadaten.<br>
**Beobachtungsart:** Katalogsnapshot<br>
**Kostenklasse:** LOW–MEDIUM

## Entscheidungsfrage und Einsatz

Diese Procedure ist passend, wenn die konkrete Betriebsfrage lautet: **Welche versions-, plattform- und datenbankabhängigen Diagnosepfade kann das Framework auf dieser Instanz verwenden, und welcher Fallback gilt?** Sie prüft Capability-Metadaten für Berechtigungsnamen, ZSTD, Resource Governor, Linux-Host-DMVs, Optimized Locking, Query-Store-Replikainformation sowie optionale Vector- und JSON-Indizes. Eine Capabilityzeile ist eine Routingentscheidung für Diagnosecode, kein Gesundheitsbefund.

## Nicht beantwortete Fragen

Die Procedure beantwortet keine fachliche Korrektheit der Featurekonfiguration, keine geschützten Inhalte und keine End-to-End-Funktionsprüfung außerhalb sichtbarer Metadaten. Der Zeitvertrag ist im Abschnitt „Zeit- und Scope-Modell“ konkretisiert. Ein auffälliger Einzelwert ist eine Beobachtung, aber noch keine Ursache; eine unauffällige Zeile ist keine Garantie für andere Zeitpunkte, Scopes oder unsichtbare Quellen.

Nicht ableitbar sind außerdem tatsächliche Feature-Nutzung, Lizenzberechtigung außerhalb der ausgewiesenen Produktmetadaten, Funktionsfähigkeit eines End-to-End-Szenarios oder zukünftige Verfügbarkeit nach Upgrade/CU. `AVAILABLE` bedeutet, dass der implementierte Probe-Pfad die Capability als vorhanden einstuft; es ersetzt keine Berechtigungsprobe im späteren Aufruf und keine fachliche Validierung.

## Sicherer Einstieg

```sql
EXEC [monitor].[USP_ServerFeatureCapabilities]
      @DatabaseNames = N'[ExampleDatabase]',
      @ResultSetArt = 'CONSOLE';
```

Alle `Example*`-Werte im Aufruf sind synthetisch.

## Resultsets und Leserichtung

RAW und CONSOLE liefern Aufrufstatus, serverweite Capabilities, datenbankbezogene Capabilities, optional Spezialindizes und zuletzt Warnungen. Die Datenbankresultsets sind nicht atomar zum Serverprobe; Statuswechsel während des Datenbankcursors sind möglich. TABLE exportiert ausschließlich das registrierte Resultset `capabilities` und enthält damit weder datenbankbezogene Features noch Spezialindizes. JSON ist für die vollständige maschinelle Hülle geeigneter und enthält `meta`, `capabilities`, `databaseFeatures`, `specialIndexes` und `warnings`.

SQL25-002 ergänzt `JSON_INDEX_METADATA` in `databaseFeatures` und
`IndexFamily = JSON` in `specialIndexes`. Die Detailspalte enthält nur
Array-Suchoption, Pfadanzahl und Disabled-Status. Konkrete SQL/JSON-Pfade
bleiben dem enger gefilterten `USP_ObjectInventory` vorbehalten;
JSON-Dokumentwerte werden in keinem der beiden Pfade gelesen.

## Eine Zeile bedeutet

Im Serverresultset identifiziert `(ScopeName, FeatureName)` eine Capability. Im Datenbankresultset gilt `(DatabaseName, FeatureName)`, im Spezialindexresultset eine konkrete Indexidentität aus Datenbank, Schema, Objekt und Index. Eine Warnungszeile steht für einen fehlgeschlagenen Datenbank- oder Selektionspfad; diese Granularitäten dürfen nicht miteinander gezählt oder gejoint werden, ohne den Resultsettyp zu erhalten.

## So lesen

Berücksichtigen Sie zuerst Gesamtstatus und Warnungen. Danach `AvailabilityStatus`, `LogicPath`, `SourceObject`, `RequiredPermission` und `Detail` als Einheit interpretieren: `UNAVAILABLE_VERSION` oder `UNAVAILABLE_PLATFORM` kann einen dokumentierten Fallback besitzen. Datenbank-Compatibility und `FeatureValue` sind separate Evidenz; die bloße Existenz einer Systemview beweist weder gefüllte Daten noch Zugriffsrecht.

## Warum kann das problematisch sein?

Ein Codepfad kann auf der Hauptversion existieren, aber wegen Plattform, Edition, Build oder Compatibility nicht nutzbar sein.

## Wann ist es kein Problem?

Ein nicht unterstütztes Feature ist kein Fehler, wenn es nicht benötigt wird.

## Beispiele und Gegenbeispiele

**Synthetischer Problemfall (`Example*`):** `ExampleDb` soll einen 2025-spezifischen Diagnosepfad verwenden, die Capability meldet jedoch `UNAVAILABLE_VERSION` oder einen nicht passenden Fallback. Der Aufrufer muss beim kompatiblen Pfad bleiben und darf die neuere Systemspalte nicht statisch referenzieren.

**Ähnlich aussehender Gegenfall:** Eine Linux-spezifische Host-DMV ist auf Windows erwartungsgemäß `UNAVAILABLE_PLATFORM`; der allgemeine OS-/SQL-Prozess-Fallback kann vollständig ausreichen. Das ist keine degradierte Servergesundheit.

## Leere oder partielle Ausgabe

Eine leere Spezialindexmenge kann korrekt bedeuten, dass die Sicht verfügbar ist, aber im gewählten Scope kein entsprechender Index existiert. Fehlt eine explizit angeforderte Datenbank oder scheitert ihr dynamischer Probe, steht dies im Warnungsresultset und `IsPartial` ist maßgeblich. Ein fehlendes datenbankbezogenes Resultset darf nicht aus einem vorhandenen Server-Capability-Resultset als Erfolg abgeleitet werden.

Für `USP_ServerFeatureCapabilities` gilt zusätzlich: **keine Zeile** bedeutet, dass im sichtbaren und gefilterten Scope kein ausgabefähiger Datensatz entstand. **0** ist ein gemessener Nullwert nur dann, wenn die Quellspalte tatsächlich verfügbar war. **NULL** bedeutet unbekannt, nicht anwendbar oder nicht auflösbar. **PARTIAL/Warning** bedeutet, dass mindestens eine Teilquelle, Datenbank oder Detailstufe fehlt. Ein Limit kann eine nichtleere Quelle vollständig aus dem sichtbaren Ausschnitt verdrängen.

## Eigenlast und Grenzen

| Dimension | Aussage für diese Procedure |
|---|---|
| Kostenklasse | LOW–MEDIUM |
| Standardpfad | Eine `ExampleDatabase` mit kleinen server- und datenbankweiten Katalogprobes; standardmäßig werden Plattform, Query-Store-Replikasicht und verfügbare Spezialindexmetadaten geprüft. Es werden keine Benutzerdaten oder Historien gelesen. |
| Teuerster Pfad | Alle sichtbaren Datenbanken mit `@MitSpezialindizes = 1`, `@MitQueryStoreReplicas = 1` und Plattformdetails. Falls die SQL-Server-2025-Sichten vorhanden sind, werden alle sichtbaren Vector- und JSON-Indexzeilen im Scope materialisiert. |
| Haupttreiber | Zahl ausgewählter Datenbanken und – auf unterstützten Builds – Zahl sichtbarer Vector- und JSON-Indizes sowie JSON-Pfadzeilen. Die übrigen Capabilityprobes lesen kleine Katalogmengen beziehungsweise zählen Query-Store-Replikagruppen. |
| Skalierung | Der dynamische Probe wird einmal je Datenbank kompiliert/ausgeführt. Laufzeit wächst annähernd mit der Datenbankanzahl; Spezialindexmaterialisierung und Ergebnistransfer wachsen zusätzlich mit der Zahl entsprechender Indizes. |
| Ressourcen | Vor allem CPU und Katalogseiten, geringe TempDB-/Arbeitstabellenlast sowie dynamischer Compileaufwand je Datenbank. Kein Showplan-, XEL-, Payload- oder Benutzertabellenscan. |
| Begrenzungswirkung | Datenbankliste/-pattern begrenzen den Cursor früh. `@MaxZeilen` wird erst beim Ausgeben jedes fachlichen Resultsets angewandt; es begrenzt weder die Zahl geprüfter Datenbanken noch die zuvor materialisierten Spezialindizes. |
| Locking und Nebenwirkungen | Rein lesende `NOLOCK`-/Katalogprobes; keine Konfigurationsänderung. Parallel laufendes DDL, Upgrade oder Failover kann zwischen Server- und Datenbankprobe ein zeitlich uneinheitliches Ergebnis erzeugen. Der vorherige Session-`LOCK_TIMEOUT` wird nach dem Aufruf wiederhergestellt. |
| Schutzmechanismus | Der Kandidatenpfad nutzt `OBJECT_ANALYSIS_CURRENT`, dessen Katalogeintrag keine High-Impact-Bestätigung verlangt. `@HighImpactConfirmed` schaltet in dieser Procedure keinen zusätzlichen Deep-Pfad frei; der explizite Datenbankscope ist der wirksame Schutz. |
| Sicherer Einsatz | Eine `ExampleDatabase`; bei reiner Serverroutingfrage optionale Spezialindizes und Query-Store-Replikaprobe deaktivieren. Erst nach vollständigem Status auf weitere Datenbanken erweitern. |
| Aussagegrenze | Capability und Systemobjektexistenz sind kein Nutzungs-, Berechtigungs- oder Funktionstest. Ein Outputlimit kann relevante spätere Zeilen verbergen, obwohl alle Quellen bereits gelesen wurden. |

## Technische Vertiefung

[Gemeinsames Execution-, Zeit- und Evidenzmodell](../Technical_Foundations.md)

### Leitfrage

Welche versions-/editionsabhängigen Frameworkpfade sind auf dieser Instanz technisch möglich und lesbar?

### Technischer Hintergrund

Die Procedure verbindet Product Major Version, Edition/Engine Edition, Compatibility und die Existenz versionsabhängiger Systemobjekte/Spalten. Capability-Probes vermeiden Compilefehler durch statische Referenzen auf nicht vorhandene Quellen und führen optionale Abfragen geschützt dynamisch aus.

### Datenkette

`master.sys.all_objects`, `sys.databases`, `sys.dm_os_host_info`, `sys.json_indexes`, `sys.json_index_paths`, `sys.objects`, `sys.query_store_replicas`, `sys.resource_governor_configuration`, `sys.schemas`, `sys.sp_executesql`, `sys.vector_indexes`, `sys.views`.

### Source Select

Der datenbanklokale Capability-Kern prüft aktuelle Versionsmerkmale direkt am Datenbankkatalog:

```sql
-- Dieser Zweig gilt für SQL Server 2025 oder neuer.
SELECT
      [d].[name] AS [DatabaseName]
    , [d].[compatibility_level]
    , [d].[state_desc]
    , [d].[is_optimized_locking_on]
    , CONVERT(int, SERVERPROPERTY(N'ProductMajorVersion')) AS [CurrentMajorVersion]
FROM [sys].[databases] AS [d] WITH (NOLOCK)
WHERE [d].[database_id] = DB_ID();
```

**Wichtig für die Eigenlast:** Legen Sie Datenbankscope vor Katalog-Existenz- und Probezugriffen fest. Die Spalte `is_optimized_locking_on` wird nur im SQL-Server-2025-Pfad kompiliert; versionsspezifische Sichten wie Vector-/JSON-Indizes und Query Store Replicas werden nur nach Versions-, Objekt- und Pflichtspaltenprüfung gelesen. `sys.json_indexes` und `sys.json_index_paths` werden je Zieldatenbank und Aufruf höchstens einmal ausgeführt; die alternative Indexabfrage ohne Pfadquelle ist zum Pfadzweig gegenseitig exklusiv.

### Zeit- und Scope-Modell

Die Auswertung beschreibt den aktuellen Instanz- und Datenbankzustand. Ein Upgrade, ein Compatibilitywechsel, ein Failover oder eine Berechtigungsänderung können das Ergebnis ändern.

### Bewertung und Gegenprobe

Berücksichtigen Sie `AvailabilityStatus`, Objekt-/Viewexistenz, Plattform, Datenbank-Compatibility, benötigte Berechtigung und Fallbackpfad getrennt. Die Procedure besitzt kein generisches `Usable`-Bit; die konkrete Nutzbarkeit ergibt sich erst aus der Capabilityzeile plus Berechtigungs- und Aufrufkontext.

### Typische Fehlinterpretation

Version allein reicht nicht: SQL Server 2025 mit niedriger Compatibility kann Features nicht im Querykontext aktivieren. Objekt vorhanden beweist keine nutzbare Datenlage. Ein sichtbarer JSON-Index und seine Pfadzahl beweisen weder Nutzung noch Gesundheit, Nutzen oder Rebuildbedarf.

### Folgeanalyse

Verwenden Sie den betroffenen Diagnosepfad nur bei passendem `AvailabilityStatus`, Scope und passender Berechtigung. Nutzen Sie andernfalls den ausgewiesenen Fallback und bewahren Sie die Warnungen als Evidenz auf.

## Primärquellen

- [SQL-Server-Katalogsichten](https://learn.microsoft.com/en-us/sql/relational-databases/system-catalog-views/catalog-views-transact-sql?view=sql-server-ver17)
- [sys.json_indexes (Transact-SQL)](https://learn.microsoft.com/en-us/sql/relational-databases/system-catalog-views/sys-json-indexes-transact-sql?view=sql-server-ver17)
- [sys.json_index_paths (Transact-SQL)](https://learn.microsoft.com/en-us/sql/relational-databases/system-catalog-views/sys-json-index-paths-transact-sql?view=sql-server-ver17)

[Technische Detailbeschreibung](../09_Version_Adaptive.md#1-monitorusp_serverfeaturecapabilities)

[SQL-Server-2025-JSON-Index-Vertrag](../../Architecture/SQL_Server_2025_JSON_Index_Inventory.md)
