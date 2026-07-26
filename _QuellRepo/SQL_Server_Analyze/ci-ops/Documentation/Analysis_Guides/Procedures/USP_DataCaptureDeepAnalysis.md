# [monitor].[USP_DataCaptureDeepAnalysis]

**Bereich:** Versionsadaptive Spezialanalysen<br>
**Zweck:** Bewertet Change-Tracking-Versionen, CDC-Capture/Cleanup und lokal erreichbare Replikationsmetadaten, ohne Nutzdaten, Change-Zeilen, Replikationsbefehle oder Konfiguration zu verändern.<br>
**Beobachtungsart:** Snapshot + retentionbegrenzte Metadatenhistorie<br>
**Kostenklasse:** MEDIUM–HIGH_OPT_IN

## Entscheidungsfrage und Einsatz

Die Procedure beantwortet die Betriebsfrage: **Sind CDC, Change Tracking oder Replication nicht nur aktiviert, sondern innerhalb Retention, LSN-/Versiongrenzen und Agentdurchsatz nutzbar?** Sie unterstützt die Entscheidung, ob das Spezialfeature vorhanden und in einem auffälligen Zustand ist und welches featureeigene Diagnoseverfahren als Nächstes gebraucht wird.

## Nicht beantwortete Fragen

Die Procedure beantwortet keine fachliche Korrektheit der Featurekonfiguration, keine geschützten Inhalte und keine End-to-End-Funktionsprüfung außerhalb sichtbarer Metadaten. Der Zeitvertrag ist im Abschnitt „Zeit- und Scope-Modell“ konkretisiert. Ein Einzelwert gilt daher nur für diesen Scope und Zeitpunkt; er belegt weder eine Ursache noch eine Entwicklung.

## Sicherer Einstieg

```sql
EXEC [monitor].[USP_DataCaptureDeepAnalysis]
      @DatabaseNames = N'[ExampleDatabase]',
      @NurProblematisch = 1,
      @HighImpactConfirmed = 1,
      @ResultSetArt = 'CONSOLE';
```

Prüfen Sie einen Change-Tracking-Consumer nur mit seinem echten, zuletzt bestätigten Wasserstand:

```sql
EXEC [monitor].[USP_DataCaptureDeepAnalysis]
      @DatabaseNames = N'[ExampleDatabase]',
      @ChangeTrackingClientVersion = 100,
      @HighImpactConfirmed = 1,
      @ResultSetArt = 'RAW';
```

Der Zahlenwert ist synthetisch. Der Parameter ist datenbankspezifisch und erzwingt genau eine ausgewählte Datenbank. Wasserstände verschiedener Consumer dürfen fachlich nicht vermischt werden.

Beide fachlichen Pfade sind als `CATALOG_DEEP` klassifiziert. Die Bestätigung erfüllt das Gruppengate, ersetzt aber weder den Einzeldatenbank-Scope noch einen fachlich verifizierten Consumer-Wasserstand.

Alle `Example*`-Werte im Aufruf sind synthetisch.

## Resultsets und Leserichtung

Der typisierte TABLE-Vertrag registriert `findings`. Status, Scope und Warnings sind vor den Fachergebnissen zu lesen. CONSOLE dient der interaktiven Triage; RAW und JSON erhalten den technischen Kontext, während TABLE nur die ausdrücklich benannten stabilen Resultsets schreibt. Resultsets mit unterschiedlicher Zeilengranularität dürfen nicht ungeprüft vereinigt oder summiert werden.

## Eine Zeile bedeutet

Je Resultset entspricht eine Zeile einem Datenbankstatus, isolierten Quellenstatus, Finding, einer Change-Tracking-Tabelle, CDC-Capture-Instanz, CDC-Scan-Sitzung, aggregierten CDC-Fehlergruppe, CDC-Jobkonfiguration, lokal sichtbaren Replikationsagenten oder aggregierten Replikationsfehlergruppe.

## So lesen

Prüfen Sie zuerst `StatusCode`, `IsPartial` und `SourceStatus`. Lesen Sie danach die drei Funktionsbereiche getrennt:

- Change Tracking: `ClientVersion` pro Consumer gegen `MinValidVersion` und `CurrentVersion`.
- CDC: Capture-Instanzen, Jobs, aggregierte Scan-Latenz und Fehler gemeinsam.
- Replikation: Agentstatus, lokaler Rückstand, Latenz und Fehler im selben Zeitfenster.

`REPLICATION_TOPOLOGY_NOT_LOCALLY_OBSERVABLE` ist eine Evidenzlücke. Sie darf nie als gesunder Replikationszustand interpretiert werden.

## Warum kann das problematisch sein?

Ein CT-Wasserstand unter `MinValidVersion` kann nicht mehr vollständig inkrementell enumeriert werden. Fehlende oder deaktivierte CDC-Jobs, wiederholte Scanfehler oder anhaltende Capture-Latenz können die Datenbereitstellung verzögern. Hohe undistributed-command-Zahlen, Retry/Fail-Agentstatus und lokale Replikationsfehler können auf einen Zustellrückstand hinweisen.

## Wann ist es kein Problem?

Ohne echten CT-Consumer-Wasserstand ist kein Synchronisationsverlust beweisbar. CDC mit nicht kontinuierlichem Capture kann zwischen geplanten Läufen erwartbar hohe Latenz zeigen. Ein Replikationsagent im Zustand `Idle` ist ohne Rückstand kein Fehler. Einzelne DMV- oder History-Zeilen sind keine lückenlose Zeitreihe.

## Beispiele und Gegenbeispiele

**Synthetischer Problemfall (`Example*`):** Ein CT-Wasserstand unter `MinValidVersion` kann nicht mehr vollständig inkrementell enumeriert werden. Fehlende oder deaktivierte CDC-Jobs, wiederholte Scanfehler oder anhaltende Capture-Latenz können die Datenbereitstellung verzögern. Hohe undistributed-command-Zahlen, Retry/Fail-Agentstatus und lokale Replikationsfehler können auf einen Zustellrückstand hinweisen.

**Ähnlich aussehender Gegenfall:** Ohne echten CT-Consumer-Wasserstand ist kein Synchronisationsverlust beweisbar. CDC mit nicht kontinuierlichem Capture kann zwischen geplanten Läufen erwartbar hohe Latenz zeigen. Ein Replikationsagent im Zustand `Idle` ist ohne Rückstand kein Fehler. Einzelne DMV- oder History-Zeilen sind keine lückenlose Zeitreihe. Der gleiche Einzelwert kann deshalb bei `ExampleDb` ohne Nutzerauswirkung unkritisch sein, während er bei zeitgleicher SLA-Verletzung eine Vertiefung rechtfertigt.

## Leere oder partielle Ausgabe

Nicht installiert, nicht aktiviert, in der gewählten Datenbank nicht verwendet und nicht abfragbar sind vier verschiedene Zustände.

Für `USP_DataCaptureDeepAnalysis` gilt zusätzlich: **keine Zeile** bedeutet, dass im sichtbaren und gefilterten Scope kein ausgabefähiger Datensatz entstand. **0** ist ein gemessener Nullwert nur dann, wenn die Quellspalte tatsächlich verfügbar war. **NULL** bedeutet unbekannt, nicht anwendbar oder nicht auflösbar. **PARTIAL/Warning** bedeutet, dass mindestens eine Teilquelle, Datenbank oder Detailstufe fehlt. Ein Limit kann eine nichtleere Quelle vollständig aus dem sichtbaren Ausschnitt verdrängen.

Eine leere CDC-Scan-DMV kann nach Neustart/Failover oder auf einer AG-Sekundärreplik auftreten. Alle in `msdb` sichtbaren lokalen Distributionsdatenbanken werden getrennt gelesen und in Agent- und Fehlerzeilen ausgewiesen; lokale Distributionstabellen zeigen dennoch keinen Remote Distributor. Fehlende Rechte werden pro Quelle als `AVAILABLE_LIMITED` erhalten; zugängliche andere Evidenz bleibt gültig.

## Eigenlast und Grenzen

MEDIUM: sichtbare Kataloge, kleine CDC-DMVs, msdb-Jobmetadaten und aggregierte lokale Distributionstabellen. Das Modul liest keine `CHANGETABLE`-Ergebnisse, CDC-Change-Table-Zeilen, Replikationscommands, Kommentare, Fehlertexte, LSNs, Credentials oder Agentjob-Commands. Laufzeitnamen bleiben für die Diagnose vollständig sichtbar und sind bei Export oder Weitergabe zu schützen.

| Dimension | Aussage für diese Procedure |
|---|---|
| Kostenklasse | MEDIUM–HIGH_OPT_IN |
| Standardpfad | Eine `ExampleDatabase`, `@NurProblematisch = 1`, 24 Stunden Fehlerlookback und endliches Limit. Change-Tracking-Verlust wird nur bewertet, wenn ein echter Consumer-Wasserstand explizit übergeben wurde. |
| Teuerster Pfad | Alle sichtbaren Datenbanken ohne Objektfilter, sehr langer Fehlerlookback und unbegrenzte Ausgabe; zusätzlich große lokale CDC-/msdb- und Distributionsmetadatenbestände mit vielen Agents und Fehlergruppen. |
| Haupttreiber | Zahl gewählter Datenbanken, Change-Tracking-Tabellen, CDC-Capture-Instanzen/-Jobs und lokal sichtbarer Replikationsobjekte plus deren msdb-Jobhistory im Lookback. Change-Zeilen und Replikationsbefehle werden nicht gelesen. |
| Skalierung | Katalogpfade wachsen mit Datenbanken und erfassten Tabellen; CDC-/Replikationspfade zusätzlich mit Scan-Sessions, Fehlergruppen, Jobs und lokal erreichbaren Agentmetadaten im Lookback. |
| Ressourcen | CPU und Katalog-/msdb-/lokales Distribution-DB-I/O, dynamisches SQL je Datenbank sowie TempDB/Arbeitsspeicher für isolierte Quelltabellen, Aggregation und Findings. |
| Begrenzungswirkung | Datenbank- und Objektfilter begrenzen lokale Katalogarbeit. `@ErrorLookbackHours` begrenzt Fehlerhistorie. `@MaxZeilen` wird erst beim Ausgeben jedes Resultsets angewandt und begrenzt die vorherige Quellenlesung und Findingerzeugung nicht. |
| Locking und Nebenwirkungen | Read-only; keine Change-Table-Zeilen, Replikationscommands oder Agentbefehle werden gelesen. Katalog-, msdb- und lokale Distribution-DB-Zugriffe können mit Cleanup/Agentaktivität zeitlich überlappen; die Teilquellen sind nicht atomar. |
| Schutzmechanismus | Der Code prüft die Analyseklassen `CATALOG_DEEP`. Verlangt deren Policy ein Gruppengate, ist zusätzlich `@HighImpactConfirmed = 1` nötig; Freigabe und Bestätigung ersetzen keine Scopebegrenzung. |
| Sicherer Einsatz | Eine bekannte `ExampleDatabase`, Problemscope und kurzer Lookback. Einen Consumer-Wasserstand nur datenbankspezifisch und fachlich verifiziert übergeben; danach Quellenstatus vor Findings lesen. |
| Aussagegrenze | Scope- oder Zeilenbegrenzungen können relevante, seltene oder später einsortierte Zeilen ausblenden. Die Aussage bleibt auf das Modell „Snapshot + retentionbegrenzte Metadatenhistorie“, die dokumentierte Granularität und den sichtbaren Quellenscope begrenzt; ein kleines Resultset ist weder automatisch vollständig noch repräsentativ. |

## Technische Vertiefung

[Gemeinsames Execution-, Zeit- und Evidenzmodell](../Technical_Foundations.md)

### Leitfrage

Sind CDC, Change Tracking oder Replication nicht nur aktiviert, sondern innerhalb Retention, LSN-/Versiongrenzen und Agentdurchsatz nutzbar?

### Technischer Hintergrund

CDC Capture liest das Transaktionslog in Change Tables; Cleanup verschiebt `min_lsn`. Consumer müssen ihren LSN-Checkpoint vor Cleanup verarbeiten. Change Tracking speichert Versionsmarken; `CHANGE_TRACKING_MIN_VALID_VERSION` bestimmt, ob ein Consumer reinitialisieren muss. Replication nutzt Logreader/Distributoragenten und eigene History.

### Datenkette

`msdb.dbo.agent_datetime`, `msdb.dbo.sysjobhistory`, `msdb.dbo.sysjobs`, `sys.change_tracking_databases`, `sys.change_tracking_tables`, `sys.databases`, `sys.schemas`, `sys.sp_executesql`, `sys.tables`, `cdc.change_tables`, `msdb.dbo.cdc_jobs`, `msdb.dbo.MSdistributiondbs`, `distribution.dbo.MSdistribution_agents`, `distribution.dbo.MSdistribution_history`, `distribution.dbo.MSdistribution_status`, `distribution.dbo.MSsubscriptions`, `distribution.dbo.MSlogreader_agents`, `distribution.dbo.MSlogreader_history`, `distribution.dbo.MSmerge_agents`, `distribution.dbo.MSmerge_sessions`, `distribution.dbo.MSrepl_errors`, `sys.dm_cdc_errors`, `sys.dm_cdc_log_scan_sessions`, `sys.fn_cdc_get_min_lsn`, `sys.fn_cdc_map_lsn_to_time`, `CHANGE_TRACKING_CURRENT_VERSION`, `CHANGE_TRACKING_MIN_VALID_VERSION`.

### Source Select

Die Procedure besitzt getrennte Pfade für Change Tracking, CDC und Replication. Der folgende Katalogkern zeigt die Beziehung der Change-Tracking-Tabellen:

```sql
SELECT
      [s].[name] AS [SchemaName]
    , [t].[name] AS [TableName]
    , [ct].[begin_version]
    , [ct].[cleanup_version]
    , CHANGE_TRACKING_MIN_VALID_VERSION([ct].[object_id]) AS [MinValidVersion]
FROM [sys].[change_tracking_tables] AS [ct] WITH (NOLOCK)
JOIN [sys].[tables] AS [t] WITH (NOLOCK)
  ON [t].[object_id] = [ct].[object_id]
JOIN [sys].[schemas] AS [s] WITH (NOLOCK)
  ON [s].[schema_id] = [t].[schema_id]
WHERE [s].[name] = N'ExampleSchema'
  AND [t].[name] = N'ExampleObject';
```

**Wichtig für die Eigenlast:** Legen Sie Datenbank und Objekt vor CDC-Logscan- und Distribution-Historie fest. Berücksichtigen Sie `sys.dm_cdc_log_scan_sessions`, `sys.dm_cdc_errors` und Distributionstabellen nur im fachlich benötigten, bestätigten Tiefenpfad und mit engem Zeitfenster.

### Zeit- und Scope-Modell

Die Auswertung beschreibt den aktuellen Enablement-, Job-, Session-, LSN- und Versionsstand sowie die begrenzte Historie.

### Bewertung und Gegenprobe

Korrelieren Sie Capture Instance, Start/End LSN, Min/Max, Consumercheckpoint, Cleanup Retention, Log Scan Sessions/Errors, Change Tracking Current/Min Valid Version und Replicationagenten. Bewerten Sie Lag als Abstand und Zeit.

### Typische Fehlinterpretation

Enabled und laufender Job beweisen keine lückenlose Konsumierbarkeit. Wenn Consumercheckpoint älter als Min Valid/Min LSN ist, helfen weitere Reads nicht; Reinitialisierungsstrategie nötig.

### Folgeanalyse

Für die weitere Analyse gelten folgende Schritte und Quellen: Agent Monitoring, Replication, Log/Capacity und Consumerstatus.

## Primärquellen

- [Change Data Capture](https://learn.microsoft.com/en-us/sql/relational-databases/track-changes/about-change-data-capture-sql-server?view=sql-server-ver17)

[Technische Detailbeschreibung](../09_Version_Adaptive.md#7-monitorusp_datacapturedeepanalysis)
