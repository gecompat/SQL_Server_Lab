# [monitor].[USP_DataCaptureStatus]

**Bereich:** Infrastruktur<br>
**Zweck:** Zeigt CDC-, Change-Tracking- und weitere Data-Capture-Zustände.<br>
**Beobachtungsart:** Konfigurations- und Runtime-Snapshot<br>
**Kostenklasse:** LOW–MEDIUM

## Entscheidungsfrage und Einsatz

Die Procedure beantwortet die Betriebsfrage: **Welche Change-Capture-Technologien sind aktiviert und grundsätzlich betriebsbereit?** Sie unterstützt die Entscheidung, ob Betriebsbereitschaft, Wiederherstellbarkeit oder verteilte Datenbewegung auffällig ist und welcher zuständige Teilprozess geprüft werden muss.

## Nicht beantwortete Fragen

Die Procedure beantwortet keinen erfolgreichen Restore, Failover oder End-to-End-Datenfluss nur aus Konfigurations- und Historymetadaten. Der Zeitvertrag ist im Abschnitt „Zeit- und Scope-Modell“ konkretisiert. Ein Einzelwert gilt daher nur für diesen Scope und Zeitpunkt; er belegt weder eine Ursache noch eine Entwicklung.

## Sicherer Einstieg

```sql
EXEC [monitor].[USP_DataCaptureStatus]
      @DatabaseNames = N'[ExampleDatabase]',
      @ResultSetArt = 'CONSOLE';
```

Alle `Example*`-Werte im Aufruf sind synthetisch.

## Resultsets und Leserichtung

Der typisierte TABLE-Vertrag registriert `databases`. Status, Scope und Warnings sind vor den Fachergebnissen zu lesen. CONSOLE dient der interaktiven Triage; RAW und JSON erhalten den technischen Kontext, während TABLE nur die ausdrücklich benannten stabilen Resultsets schreibt. Resultsets mit unterschiedlicher Zeilengranularität dürfen nicht ungeprüft vereinigt oder summiert werden.

## Eine Zeile bedeutet

Je Resultset beschreibt eine Zeile eine Datenbank, ein Capture-Feature, einen Job oder eine erfasste Tabelle.

## So lesen

Unterscheiden Sie Featurestatus, Capture-/Cleanup-Job, Retention, Datenbankzustand und Logkontext.

## Warum kann das problematisch sein?

Aktiviertes CDC ohne laufenden Capturejob kann Logrückstand erzeugen; Cleanupfehler lassen Capturetabellen wachsen.

## Wann ist es kein Problem?

Deaktiviertes CDC oder Change Tracking ist normal, wenn die Datenbank das Feature nicht benötigt.

## Beispiele und Gegenbeispiele

**Synthetischer Problemfall (`Example*`):** CDC enabled plus Capturejob disabled ist ein konkreter Fehlerzustand. Prüfen Sie Agentjobs, Logstatus und Featurekonfiguration.

**Ähnlich aussehender Gegenfall:** Deaktiviertes CDC oder Change Tracking ist normal, wenn die Datenbank das Feature nicht benötigt. Der gleiche Einzelwert kann deshalb bei `ExampleDb` ohne Nutzerauswirkung unkritisch sein, während er bei zeitgleicher SLA-Verletzung eine Vertiefung rechtfertigt.

## Leere oder partielle Ausgabe

Ein leerer Historypfad kann Retention/Cleanup, deaktivierte Komponente oder falschen Scope bedeuten; er beweist keine erfolgreiche Ausführung.

Für `USP_DataCaptureStatus` gilt zusätzlich: **keine Zeile** bedeutet, dass im sichtbaren und gefilterten Scope kein ausgabefähiger Datensatz entstand. **0** ist ein gemessener Nullwert nur dann, wenn die Quellspalte tatsächlich verfügbar war. **NULL** bedeutet unbekannt, nicht anwendbar oder nicht auflösbar. **PARTIAL/Warning** bedeutet, dass mindestens eine Teilquelle, Datenbank oder Detailstufe fehlt. Ein Limit kann eine nichtleere Quelle vollständig aus dem sichtbaren Ausschnitt verdrängen.

## Eigenlast und Grenzen

**Quellcode-Hinweis zur Eigenlast:** Die Eigenlast ist mittel; lokale Kandidaten werden je Datenbank auf N+1 begrenzt, anschließend erfolgt ein globales TOP je fachlichem Resultset.

| Dimension | Aussage für diese Procedure |
|---|---|
| Kostenklasse | LOW–MEDIUM |
| Standardpfad | Eine `ExampleDatabase`; CDC-Capture-Instances, Change-Tracking-Tabellen und zugeordnete CDC-Jobs werden als aktueller Konfigurations-/Statussnapshot gelesen. |
| Teuerster Pfad | Alle sichtbaren Datenbanken und unbegrenzte Ausgabe bei vielen erfassten Tabellen. Je CDC-Job wird nur die letzte Outcome-Historyzeile aufgelöst, kein frei wählbares Historyfenster. |
| Haupttreiber | Zahl sichtbarer Datenbanken und aktivierter CDC-/Change-Tracking-Konfigurationen sowie zugehöriger lokaler CDC-Jobs und letzter Historyzeilen. Change-Tabelleninhalte und Replikationsbefehle werden in diesem Statuspfad nicht gelesen. |
| Skalierung | Aufwand wächst mit Datenbanken, CDC-Instances, Change-Tracking-Tabellen und Jobs. Pro Datenbank werden lokal höchstens N+1 Kandidaten je fachlichem Pfad übernommen, anschließend global begrenzt. |
| Ressourcen | CPU und I/O auf Katalogen beziehungsweise msdb-Historie; TempDB für Korrelation und Transfer bei langen Meldungen. |
| Begrenzungswirkung | Datenbankscope begrenzt den Cursor. `@MaxZeilen` steuert lokale N+1-Kandidaten und das globale TOP je Resultset; es ist keine gemeinsame Gesamtgrenze über CDC, CT und Jobs und verhindert nicht jede Katalog-/letzte-History-Suche. |
| Locking und Nebenwirkungen | Read-only; kurze Schema-Stability-Zugriffe auf msdb/Systemkataloge. Jobs, Backups oder Wartung laufen parallel weiter, daher ist das Ergebnis nicht atomar. |
| Schutzmechanismus | `HA_DR_CURRENT` muss freigegeben sein, verlangt laut Klassenkatalog aber keine High-Impact-Bestätigung. `@HighImpactConfirmed` aktiviert hier keinen zusätzlichen Detailpfad. |
| Sicherer Einsatz | Eine `ExampleDatabase` und endliches Limit; Datenbankstatus vor den drei getrennten Fachresultsets lesen. |
| Aussagegrenze | Scope- oder Zeilenbegrenzungen können relevante, seltene oder später einsortierte Zeilen ausblenden. Die Aussage bleibt auf das Modell „Konfigurations- und Runtime-Snapshot“, die dokumentierte Granularität und den sichtbaren Quellenscope begrenzt; ein kleines Resultset ist weder automatisch vollständig noch repräsentativ. |

## Technische Vertiefung

[Gemeinsames Execution-, Zeit- und Evidenzmodell](../Technical_Foundations.md)

### Leitfrage

Welche Change-Capture-Technologien sind aktiviert und grundsätzlich betriebsbereit?

### Technischer Hintergrund

CDC liest Transaction Log asynchron in Change Tables und räumt per Cleanupjob auf. Change Tracking speichert kompakte Änderungsinformationen mit Retention/Auto Cleanup, keine vollständigen historischen Werte. Replication besitzt eigenen Logreader-/Distributionspfad.

### Datenkette

`master.sys.databases`, `msdb.dbo.agent_datetime`, `msdb.dbo.sysjobhistory`, `msdb.dbo.sysjobs`, `sys.change_tracking_databases`, `sys.change_tracking_tables`, `sys.databases`, `sys.schemas`, `sys.sp_executesql`, `sys.tables`.

### Source Select

Der Basisstatus verbindet die Datenbankoption mit den Change-Tracking-Tabellen der ausgewählten Datenbank:

```sql
SELECT
      [d].[name] AS [DatabaseName]
    , [d].[is_cdc_enabled]
    , [ctd].[retention_period]
    , [ctd].[retention_period_units_desc]
FROM [sys].[databases] AS [d] WITH (NOLOCK)
LEFT JOIN [sys].[change_tracking_databases] AS [ctd] WITH (NOLOCK)
  ON [ctd].[database_id] = [d].[database_id]
WHERE [d].[database_id] = DB_ID();

SELECT
      [s].[name] AS [SchemaName]
    , [t].[name] AS [TableName]
    , [ct].[begin_version]
    , CHANGE_TRACKING_MIN_VALID_VERSION([ct].[object_id]) AS [MinValidVersion]
FROM [sys].[change_tracking_tables] AS [ct] WITH (NOLOCK)
JOIN [sys].[tables] AS [t] WITH (NOLOCK)
  ON [t].[object_id] = [ct].[object_id]
JOIN [sys].[schemas] AS [s] WITH (NOLOCK)
  ON [s].[schema_id] = [t].[schema_id]
WHERE [t].[is_ms_shipped] = 0;
```

**Wichtig für die Eigenlast:** Die Datenbankauswahl erfolgt vor dem dynamischen datenbanklokalen Katalogzugriff. Ergänzen Sie Jobhistorie nur für tatsächlich aktivierte CDC-Datenbanken und mit Zeitfenster.

### Zeit- und Scope-Modell

Die Auswertung beschreibt den aktuellen Enablement-/Konfigurationszustand mit begrenzten Job-/LSN-/Versionmarken.

### Bewertung und Gegenprobe

Berücksichtigen Sie Technologie, Captureinstanzen, Jobs, Retention, Min/Max LSN oder Change Tracking Versions und Tabellenabdeckung. Prüfen Sie Consumerposition gegen Mindestversion/MinLSN.

### Typische Fehlinterpretation

`Enabled=1` beweist keinen aktuellen Durchsatz, keine lückenlose Retention und keine funktionierenden Consumer.

### Folgeanalyse

Für die weitere Analyse gelten folgende Schritte und Quellen: `USP_DataCaptureDeepAnalysis`, Agent Jobs und Consumercheckpoint.

## Primärquellen

- [Change Tracking](https://learn.microsoft.com/en-us/sql/relational-databases/track-changes/about-change-tracking-sql-server?view=sql-server-ver17)

[Technische Detailbeschreibung](../07_Infrastructure.md#8-monitorusp_datacapturestatus)
