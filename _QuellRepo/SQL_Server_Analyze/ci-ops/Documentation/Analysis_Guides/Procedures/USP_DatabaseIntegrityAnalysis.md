# [monitor].[USP_DatabaseIntegrityAnalysis]

**Bereich:** Server Health<br>
**Zweck:** Korrelierte Integritätsevidenz aus Datenbankstatus, CHECKDB-Historie, suspect pages, Backups und HADR.<br>
**Beobachtungsart:** Snapshot + retentionbegrenzte Metadatenhistorie<br>
**Kostenklasse:** LOW–MEDIUM

## Entscheidungsfrage und Einsatz

Die Procedure beantwortet die Betriebsfrage: **Welche Metadaten weisen auf Integritätsrisiko, veralteten CHECKDB-Nachweis, suspect pages, beschädigte Backups oder offene HADR-Seitenreparatur hin?** Sie unterstützt die Entscheidung, ob eine Instanzressource oder Konfiguration als belastbare Spur zum Symptom passt und welche unabhängige OS-, Verlaufs- oder Workloadevidenz fehlt.

## Nicht beantwortete Fragen

Die Procedure beantwortet keine vollständige OS-/Hypervisorursache und ohne Delta oder Verlauf keine belastbare Aussage über einen dauerhaften Engpass. Der Zeitvertrag ist im Abschnitt „Zeit- und Scope-Modell“ konkretisiert. Ein Einzelwert gilt daher nur für diesen Scope und Zeitpunkt; er belegt weder eine Ursache noch eine Entwicklung.

## Sicherer Einstieg

```sql
EXEC [monitor].[USP_DatabaseIntegrityAnalysis]
      @DatabaseNames = N'[ExampleDatabase]',
      @MitPageDetails = 0,
      @ResultSetArt = 'CONSOLE';
```

Für vollständige serverweite Evidenz ist auf SQL Server 2019 `VIEW SERVER STATE`, ab SQL Server 2022 `VIEW SERVER PERFORMANCE STATE` erforderlich. Fehlt dieses Recht, bleibt zulässige Teilevidenz sichtbar, der Status lautet jedoch ausdrücklich `AVAILABLE_LIMITED` mit `IsPartial=1`.

Alle `Example*`-Werte im Aufruf sind synthetisch.

## Resultsets und Leserichtung

Der typisierte TABLE-Vertrag registriert `integrity`. Status, Scope und Warnings sind vor den Fachergebnissen zu lesen. CONSOLE dient der interaktiven Triage; RAW und JSON erhalten den technischen Kontext, während TABLE nur die ausdrücklich benannten stabilen Resultsets schreibt. Resultsets mit unterschiedlicher Zeilengranularität dürfen nicht ungeprüft vereinigt oder summiert werden.

## Eine Zeile bedeutet

Je Resultset entspricht eine Zeile einer Datenbank, einer suspect page, Backup-/CHECKDB-Evidenz, HADR-Reparatur oder einem Finding.

## So lesen

Berücksichtigen Sie Datenbankstatus, PAGE_VERIFY, Alter letzter Integritätsprüfung, suspect pages, Backupchecksums und HADR-Reparaturen gemeinsam.

## Warum kann das problematisch sein?

Suspect Pages oder beschädigte Backupevidenz sind konkrete negative Indikatoren möglicher physischer oder inhaltlicher Schäden.

## Wann ist es kein Problem?

Keine negativen Indikatoren beweisen keine Integrität; die Procedure führt keinen vollständigen CHECKDB aus.

## Beispiele und Gegenbeispiele

**Synthetischer Problemfall (`Example*`):** `SuspectPageCount=0` heißt nur „Quelle meldet nichts“. `SuspectPageCount=3` ist konkrete negative Evidenz und verlangt Eskalation, CHECKDB-Strategie, Backupkette und Restore-Test.

**Ähnlich aussehender Gegenfall:** Keine negativen Indikatoren beweisen keine Integrität; die Procedure führt keinen vollständigen CHECKDB aus. Der gleiche Einzelwert kann deshalb bei `ExampleDb` ohne Nutzerauswirkung unkritisch sein, während er bei zeitgleicher SLA-Verletzung eine Vertiefung rechtfertigt.

## Leere oder partielle Ausgabe

Server-DMVs können plattform-, editions- oder berechtigungsbedingt fehlen. NULL und PARTIAL sind dann Evidenzgrenzen, keine Nullmessung.

Für `USP_DatabaseIntegrityAnalysis` gilt zusätzlich: **keine Zeile** bedeutet, dass im sichtbaren und gefilterten Scope kein ausgabefähiger Datensatz entstand. **0** ist ein gemessener Nullwert nur dann, wenn die Quellspalte tatsächlich verfügbar war. **NULL** bedeutet unbekannt, nicht anwendbar oder nicht auflösbar. **PARTIAL/Warning** bedeutet, dass mindestens eine Teilquelle, Datenbank oder Detailstufe fehlt. Ein Limit kann eine nichtleere Quelle vollständig aus dem sichtbaren Ausschnitt verdrängen.

## Eigenlast und Grenzen

| Dimension | Aussage für diese Procedure |
|---|---|
| Kostenklasse | LOW–MEDIUM |
| Standardpfad | Eine `ExampleDatabase`, 35 Tage Backup-/CHECKDB-Metadaten, suspect pages und HADR-Auto-Page-Repair ohne Seitenauflösung. Kein DBCC-Lauf. |
| Teuerster Pfad | Alle sichtbaren Datenbanken, langer Backup-Lookback, `@MitPageDetails = 1` und unbegrenzte Ausgabe bei vielen suspect/repair-Seiten; jede sichtbare Seite wird gezielt über `sys.dm_db_page_info` aufgelöst. |
| Haupttreiber | Zahl gewählter Datenbanken, Backup-/CHECKDB-Metadaten im Lookback sowie suspect- und HADR-Auto-Page-Repair-Zeilen. `@MitPageDetails = 1` fügt für jede sichtbare Seite einen eigenen `sys.dm_db_page_info`-Aufruf hinzu. |
| Skalierung | Metadatenpfad wächst mit Datenbanken und relevanter msdb-Retention. Der optionale Seitenpfad wächst mit suspect-/repair-Seiten und kann zusätzliche Buffer-/Storage-I/O verursachen. |
| Ressourcen | CPU und Katalog-/msdb-I/O für Status, Backupset und suspect pages; optional gezielte Page-Metadaten-I/O über `sys.dm_db_page_info`; kleine temporäre Evidenztabellen. |
| Begrenzungswirkung | Datenbankscope und `@BackupHistoryDays` begrenzen relevante Quellen. `@MaxZeilen` wirkt auf fertige Evidenz; es schützt nicht sicher vor allen Backupaggregationen oder jedem bereits ausgewählten Seitenprobe. `@MitPageDetails = 0` ist die wichtigste Lastgrenze. |
| Locking und Nebenwirkungen | Read-only; kurze Metadatenzugriffe und nicht atomare Runtime-DMVs. Es wird weder CHECKDB noch Growth noch Konfigurationsänderung ausgeführt. |
| Schutzmechanismus | `HA_DR_CURRENT` verlangt laut Klassenkatalog keine High-Impact-Bestätigung; `@HighImpactConfirmed` schaltet die Seitenauflösung nicht. Diese wird ausschließlich durch `@MitPageDetails` opt-in aktiviert. |
| Sicherer Einsatz | Eine `ExampleDatabase`, Seitenauflösung aus und begrenzter Lookback. Page Details erst für eine kleine bereits sichtbare suspect-/repair-Menge und außerhalb der I/O-Spitze aktivieren. |
| Aussagegrenze | Scope- oder Zeilenbegrenzungen können relevante, seltene oder später einsortierte Zeilen ausblenden. Die Aussage bleibt auf das Modell „Snapshot + retentionbegrenzte Metadatenhistorie“, die dokumentierte Granularität und den sichtbaren Quellenscope begrenzt; ein kleines Resultset ist weder automatisch vollständig noch repräsentativ. |

## Technische Vertiefung

[Gemeinsames Execution-, Zeit- und Evidenzmodell](../Technical_Foundations.md)

### Leitfrage

Welche Metadaten weisen auf Integritätsrisiko, veralteten CHECKDB-Nachweis, suspect pages, beschädigte Backups oder offene HADR-Seitenreparatur hin?

### Technischer Hintergrund

Page Verify CHECKSUM erkennt bestimmte Pageänderungen bei Read; `suspect_pages` speichert erkannte Pageereignisse; DBINFO/Property kann Last Good CHECKDB liefern; Backupsets enthalten checksum/damage flags; HADR Auto Page Repair dokumentiert Reparaturversuche.

### Datenkette

`master.sys.databases`, `msdb.dbo.backupset`, `msdb.dbo.suspect_pages`, `sys.dm_db_page_info`, `sys.dm_hadr_auto_page_repair`.

### Source Select

Der historische Kern verbindet verdächtige Seiten mit Datenbank und optionaler AG-Auto-Repair-Evidenz:

```sql
SELECT
      [d].[name] AS [DatabaseName]
    , [sp].[file_id]
    , [sp].[page_id]
    , [sp].[event_type]
    , [sp].[last_update_date]
    , [apr].[page_status]
    , [apr].[modification_time]
FROM [msdb].[dbo].[suspect_pages] AS [sp] WITH (NOLOCK)
JOIN [master].[sys].[databases] AS [d] WITH (NOLOCK)
  ON [d].[database_id] = [sp].[database_id]
LEFT JOIN [sys].[dm_hadr_auto_page_repair] AS [apr] WITH (NOLOCK)
  ON [apr].[database_id] = [sp].[database_id]
 AND [apr].[file_id] = [sp].[file_id]
 AND [apr].[page_id] = [sp].[page_id]
WHERE [d].[name] = N'ExampleDatabase'
  AND [sp].[last_update_date] >= DATEADD(DAY, -30, GETDATE());
```

**Wichtig für die Eigenlast:** Setzen Sie Datenbank und Zeitfenster vor `dm_db_page_info`. Rufen Sie die Seitenmetadaten-DMF nur für die kleine verbleibende Seitenmenge auf; sie ist keine Ersatzprüfung für `DBCC CHECKDB`.

### Zeit- und Scope-Modell

Die Auswertung verbindet historische und aktuelle Metadaten mit unterschiedlicher Retention; sie führt keinen Live-CHECKDB aus.

### Bewertung und Gegenprobe

Priorisieren Sie jede Suspect Page, jedes beschädigte Backup und jede Pending Page Repair hoch. Prüfen Sie Last Good CHECKDB gegen die Policy, die Datenbankgröße und die Backup- und Restorestrategie. Berücksichtigen Sie dabei immer EvidenceLimit.

### Typische Fehlinterpretation

`0` negative Einträge beweist keine Integrität. `RESTORE VERIFYONLY` prüft nicht alle Daten und ersetzt weder CHECKDB noch echten Restore.

### Folgeanalyse

Für die weitere Analyse gelten folgende Schritte und Quellen: Geplanter CHECKDB, Backup Chain, echter Restoretest und Storage-/Errorlog/XE-Korrelation.

## Primärquellen

- [DBCC CHECKDB](https://learn.microsoft.com/en-us/sql/t-sql/database-console-commands/dbcc-checkdb-transact-sql?view=sql-server-ver17)

## Weiterführende Vertiefung

Die folgenden Quellen ergänzen die Produktspezifikation um Praxis- oder Toolingperspektiven. Sie sind keine Grundlage für versions-, Berechtigungs- oder Engineaussagen dieser Seite.

- [Ola Hallengren: SQL Server Integrity Check – betriebliche CHECKDB-Praxis](https://ola.hallengren.com/sql-server-integrity-check.html)

[Technische Detailbeschreibung](../08_Server_Health.md#11-monitorusp_databaseintegrityanalysis)
