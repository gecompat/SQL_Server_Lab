# [monitor].[USP_DatabaseConfigurationAnalysis]

**Bereich:** Server Health<br>
**Zweck:** Inventarisiert Datenbankoptionen und trennt lokale Variation von expliziter Profilabweichung.<br>
**Beobachtungsart:** aktueller Cross-Database-Katalogsnapshot<br>
**Kostenklasse:** LOW–MEDIUM

## Entscheidungsfrage und Einsatz

Die Procedure beantwortet: **Welche sichtbaren Datenbank-, Database-Scoped- und Query-Store-Einstellungen unterscheiden sich lokal oder von einem ausdrücklich gelieferten Sollprofil?** Ohne Profil berechnet sie nur lokale Variation. Der häufigste sichtbare Wert ist dabei eine Vergleichsreferenz, kein Sollwert. Mit `@ProfileJson` entstehen zusätzlich `PROFILE_MISMATCH`-Zeilen gegen die vom Aufrufer autoritativ vorgegebenen Werte.

Der Einsatz eignet sich für kontrollierte Inventur, Migrationsvorbereitung und Driftprüfung. RCSI, Statistikoptionen, Parameterisierung, Query Store, Recovery Model, ADR oder andere Einstellungen bleiben workload- und betriebsabhängig. Die Procedure führt kein `ALTER DATABASE` aus und formuliert keine universelle Konfigurationsempfehlung.

## Nicht beantwortete Fragen

Variation beweist weder Fehler noch Performanceursache. Zwei Datenbanken können absichtlich verschieden konfiguriert sein. Ein lokaler Mehrheitswert ist nicht automatisch organisatorischer Standard. Ein Profilwert dokumentiert die Erwartung des Aufrufers, nicht ihre technische Angemessenheit. Die Procedure bewertet keine Lizenzierung, keinen Change-Prozess und keine Anwendungskompatibilität.

Unsichtbare, offline befindliche oder berechtigungsbedingt ausgelassene Datenbanken fehlen. Versionsabhängige Optionen erscheinen nur, wenn ihre Katalogspalte vorhanden ist. Query-Store-Optionen zeigen Zustand und Konfiguration, nicht den Inhalt oder die Workloadwirkung. Secondary-Werte von Database Scoped Configurations werden separat erhalten und nicht mit dem Primärwert vermischt.

## Sicherer Einstieg

```sql
EXEC [monitor].[USP_DatabaseConfigurationAnalysis]
      @DatabaseNames = N'[ExampleDatabaseA],[ExampleDatabaseB]',
      @MaxZeilen = 200,
      @ResultSetArt = 'CONSOLE';
```

Verwenden Sie mit folgendem Aufruf ein ausdrücklich synthetisches Profil:

```sql
EXEC [monitor].[USP_DatabaseConfigurationAnalysis]
      @DatabaseNames = N'[ExampleDatabaseA]',
      @ProfileJson = N'[{"settingScope":"DATABASE","settingName":"AUTO_CLOSE","expectedValue":"OFF"}]',
      @MaxZeilen = 200,
      @ResultSetArt = 'CONSOLE';
```

Versionieren und genehmigen Sie das Profil vor der produktiven Nutzung. Übernehmen Sie dabei die exakten sichtbaren Schreibweisen aus `settings`. Eine Profilabweichung ist Review-Evidenz und kein Änderungsauftrag.

## Resultsets und Leserichtung

Der typisierte Vertrag umfasst `moduleStatus`, `settings`, `drift`, `profile`, `sourceStatus` und `warnings`. Prüfen Sie zuerst Modul- und Quellstatus. Verifizieren Sie danach `profile`, sofern es geliefert wurde. `settings` ist das Rohinventar je Datenbank und Scope. `drift` enthält lokale Variation und explizite Profilabweichung. `warnings` zeigt nicht sichtbare Profileinträge, verweigerte Datenbanken oder Teilquellen.

## Eine Zeile bedeutet

In `settings` bedeutet eine Zeile eine Einstellung einer Datenbank aus genau einer Quellgruppe. In `drift` ist eine Zeile eine Datenbank-Einstellung, die vom lokalen Referenzwert oder expliziten Profilwert abweicht. `MatchingDatabaseCount` beschreibt beim lokalen Vergleich die Zahl sichtbarer Datenbanken mit dem aktuellen Wert; `ComparedDatabaseCount` ist der Nenner dieser Einstellung. In `sourceStatus` ist eine Zeile eine Datenbank-Quellkombination.

## So lesen

`DriftType` trennt `LOCAL_VARIATION` von `PROFILE_MISMATCH`. Berücksichtigen Sie beim lokalen Vergleich `ReferenceValue`, `MatchingDatabaseCount` und `ComparedDatabaseCount` gemeinsam. Bei Gleichstand wählt die Procedure deterministisch nach Wert; dadurch entsteht Stabilität, aber keine fachliche Präferenz. Beim Profilvergleich ist `ExpectedValue` exakt die gelieferte Zeichenfolge, verglichen ohne Groß- und Kleinschreibung. `PROFILE_SETTING_NOT_VISIBLE` kann einen Tippfehler, eine Versionsdifferenz oder fehlende Sichtbarkeit bedeuten.

## Warum kann das problematisch sein?

Unbeabsichtigte Abweichungen können Verhalten, Recovery, Optimierung, Statistikpflege oder Query-Store-Erfassung verändern. Besonders nach Migrationen oder automatisierten Deployments ist ein reproduzierbares Profil hilfreich. Gleichzeitig können pauschale Sollwerte Schaden verursachen, wenn Datenbanken unterschiedliche Workloads, Verfügbarkeitsanforderungen oder Kompatibilitätsziele besitzen.

## Wann ist es kein Problem?

Eine Abweichung kann bewusst und dokumentiert sein. Unterschiedliche Compatibility Levels während einer gestuften Migration, unterschiedliche Recovery Models oder Query-Store-Zustände bei speziellen Datenbanken sind mögliche Gegenbeispiele. Auch lokale Mehrheiten können historisch zufällig entstanden sein. Ohne erwartetes Betriebsprofil gibt die Procedure deshalb nur Variation aus.

## Beispiele und Gegenbeispiele

**Synthetischer Problemfall (`Example*`):** `ExampleDatabaseB` weicht als einzige Datenbank vom freigegebenen Profil `AUTO_CLOSE=OFF` ab, und der Changeverlauf zeigt eine unbeabsichtigte Aktivierung. Das rechtfertigt eine geplante Korrektur mit Rollback, nicht eine automatische DDL-Ausführung.

**Gegenbeispiel:** `ExampleLegacyDatabase` bleibt absichtlich auf einem niedrigeren Compatibility Level, während die Migration getestet wird. Die Variation ist erwartet und sollte dokumentiert, nicht „vereinheitlicht“ werden.

**Nicht entscheidbar:** Ein Profilwert ist nicht sichtbar und die Scoped-Quelle steht auf `DENIED_PERMISSION`. Stellen Sie zuerst die erforderliche Sichtbarkeit her und interpretieren Sie eine fehlende Zeile nicht als fehlende Einstellung.

## Leere oder partielle Ausgabe

Eine leere `drift`-Menge bedeutet: Im sichtbaren Scope wurde keine Variation beziehungsweise Profilabweichung erzeugt. Sie sagt nichts über ausgelassene Datenbanken oder nicht inventarisierte Einstellungen. `AVAILABLE_LIMITED` weist auf eine fehlende Teilquelle hin. Jede Kombination aus Datenbank und Quellgruppe besitzt einen eigenen Status, sodass vorhandene Werte nicht wegen einer anderen fehlenden Quelle verworfen werden.

## Eigenlast und Grenzen

| Dimension | Aussage für diese Procedure |
|---|---|
| Kostenklasse | LOW–MEDIUM |
| Standardpfad | Serverkatalog einmal sowie je sichtbarer Datenbank zwei kleine Konfigurationskataloge. |
| Teuerster Pfad | Alle sichtbaren Datenbanken, unbegrenzte Ausgabe und großes explizites Profil. |
| Haupttreiber | Datenbankzahl und Zahl versionsabhängiger Scoped Configurations. |
| Skalierung | Annähernd linear zur Datenbankzahl; keine Benutzerobjekt- oder Nutzdatenscans. |
| Ressourcen | Katalog-CPU, dynamische Cross-Database-Batches und kleine TempDB-Aggregationen. |
| Begrenzungswirkung | Datenbankfilter wirkt vor lokalen Katalogzugriffen; `@MaxZeilen` begrenzt Ausgabe, nicht Inventur. |
| Locking und Nebenwirkungen | Read-only, `LOCK_TIMEOUT 0`; keine Konfigurationsänderung und keine Persistenz. |
| Schutzmechanismus | Getrennte Quellstatus, versionsadaptive Spaltenprüfung und nur explizites Sollprofil. |
| Sicherer Einsatz | Kleine Datenbankliste, Rohinventar prüfen, Profil separat freigeben. |
| Aussagegrenze | Katalogsnapshot ohne Workloadwirkung, Changehistorie oder universelle Sollwerte. |

## Technische Vertiefung

[Gemeinsames Execution-, Zeit- und Evidenzmodell](../Technical_Foundations.md)

### Leitfrage

Welche sichtbaren Einstellungen variieren, und welche weichen von einem autorisierten Profil ab?

### Technischer Hintergrund

`master.sys.databases` liefert gemeinsame Datenbankoptionen. `sys.database_scoped_configurations` und `sys.database_query_store_options` werden je Kandidat in isolierten dynamischen Batches gelesen. Eine versionsabhängige Option wie Optimized Locking wird nur projiziert, wenn die Katalogspalte sichtbar vorhanden ist. Das Profil ist ein JSON-Array eindeutiger Scope-/Name-Paare.

### Datenkette

`master.sys.databases`, `sys.database_scoped_configurations`, `sys.database_query_store_options`.

### Source Select

Die Konfiguration besteht aus einem serverweiten Datenbankkatalog und datenbanklokalen Konfigurationssichten:

```sql
SELECT
      [d].[name]
    , [d].[compatibility_level]
    , [d].[recovery_model_desc]
    , [d].[is_auto_close_on]
    , [d].[is_auto_shrink_on]
FROM [master].[sys].[databases] AS [d] WITH (NOLOCK)
WHERE [d].[name] = N'ExampleDatabase'
  AND [d].[state] = 0;

-- Erst im Kontext der ausgewählten Datenbank:
SELECT [name], [value], [value_for_secondary]
FROM [sys].[database_scoped_configurations] WITH (NOLOCK);
```

**Wichtig für die Eigenlast:** Filtern Sie die Datenbankliste vor dem Kontextwechsel. Fragen Sie Query Store und zusätzliche versionsabhängige Sichten nur für verbleibende Datenbanken ab; ein globales `TOP` darf nicht vor der fachlichen Datenbankauswahl stehen.

### Zeit- und Scope-Modell

Die Auswertung beschreibt den aktuellen Katalogsnapshot pro Quelle. Zustände können sich zwischen Datenbanken und Quellzugriffen ändern; `CapturedAtUtc` kennzeichnet den Aufruf, nicht eine atomare serverweite Transaktion.

### Bewertung und Gegenprobe

Prüfen Sie Abweichung mit freigegebenem Profil, Changehistorie, Anwendungstest und Workloadevidenz. Klären Sie vor DDL immer Rollback und betroffene Verfügbarkeits-/Recovery-Verträge.

### Typische Fehlinterpretation

Der lokal häufigste Wert ist nicht als Best Practice zu interpretieren. Ebenso stellt eine Profilabweichung keine automatische Reparaturanweisung dar.

### Folgeanalyse

Für die weitere Analyse gelten folgende Schritte und Quellen: Query Store, Statistik-, Recovery- und Verfügbarkeitsmodule sowie der externe Konfigurations-/Changevertrag der Organisation.

## Primärquellen

- [sys.databases](https://learn.microsoft.com/en-us/sql/relational-databases/system-catalog-views/sys-databases-transact-sql?view=sql-server-ver17)
- [sys.database_scoped_configurations](https://learn.microsoft.com/en-us/sql/relational-databases/system-catalog-views/sys-database-scoped-configurations-transact-sql?view=sql-server-ver17)
- [sys.database_query_store_options](https://learn.microsoft.com/en-us/sql/relational-databases/system-catalog-views/sys-database-query-store-options-transact-sql?view=sql-server-ver17)

[Technische Detailbeschreibung](../08_Server_Health.md#19-monitorusp_databaseconfigurationanalysis)
