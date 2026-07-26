# [monitor].[USP_AvailabilityDeepAnalysis]

**Bereich:** Infrastruktur<br>
**Zweck:** Vertieft Availability Groups mit Send-/Redo-Queues, Lag, Cluster- und Replica-Evidenz.<br>
**Beobachtungsart:** verteilter, nicht atomarer Snapshot<br>
**Kostenklasse:** LOW–MEDIUM

## Entscheidungsfrage und Einsatz

Die Procedure beantwortet die Betriebsfrage: **Warum ist eine AG/Replica nicht gesund, welche Datenbewegungsstufe staut und welche Risiken entstehen?** Sie unterstützt die Entscheidung, ob Betriebsbereitschaft, Wiederherstellbarkeit oder verteilte Datenbewegung auffällig ist und welcher zuständige Teilprozess geprüft werden muss.

## Nicht beantwortete Fragen

Die Procedure beantwortet keinen erfolgreichen Restore, Failover oder End-to-End-Datenfluss nur aus Konfigurations- und Historymetadaten. Der Zeitvertrag ist im Abschnitt „Zeit- und Scope-Modell“ konkretisiert. Ein Einzelwert gilt daher nur für diesen Scope und Zeitpunkt; er belegt weder eine Ursache noch eine Entwicklung.

## Sicherer Einstieg

```sql
EXEC [monitor].[USP_AvailabilityDeepAnalysis]
      @MitClusterNetzwerken = 0,
      @ResultSetArt = 'CONSOLE';
```

Alle `Example*`-Werte im Aufruf sind synthetisch.

## Resultsets und Leserichtung

Der typisierte TABLE-Vertrag registriert `replicas`. Status, Scope und Warnings sind vor den Fachergebnissen zu lesen. CONSOLE dient der interaktiven Triage; RAW und JSON erhalten den technischen Kontext, während TABLE nur die ausdrücklich benannten stabilen Resultsets schreibt. Resultsets mit unterschiedlicher Zeilengranularität dürfen nicht ungeprüft vereinigt oder summiert werden.

## Eine Zeile bedeutet

Je Resultset beschreibt eine Zeile eine Replica-/Datenbank-Beziehung, Queue-/Lagmetrik, Clusterkomponente oder ein Finding.

## So lesen

Berücksichtigen Sie Send Queue, Redo Queue, geschätzte Lagzeit, Synchronisierungszustand, Rolle und Trend gemeinsam.

## Warum kann das problematisch sein?

Wachsende Send Queue weist eher auf Transport/Primary hin; wachsende Redo Queue auf Secondary-Redo, I/O oder CPU.

## Wann ist es kein Problem?

Ein kurzer Peak nach großer Transaktion kann sich normal abbauen.

## Beispiele und Gegenbeispiele

**Synthetischer Problemfall (`Example*`):** Send Queue stabil klein, Redo Queue wächst über mehrere Messungen: Fokus auf Secondary-I/O/CPU/Redo statt Netzwerk. Prüfen Sie Counter, Storage und Cluster.

**Ähnlich aussehender Gegenfall:** Ein kurzer Peak nach großer Transaktion kann sich normal abbauen. Der gleiche Einzelwert kann deshalb bei `ExampleDb` ohne Nutzerauswirkung unkritisch sein, während er bei zeitgleicher SLA-Verletzung eine Vertiefung rechtfertigt.

## Leere oder partielle Ausgabe

Eine leere Deep-Sicht kann bedeuten, dass keine AG konfiguriert ist oder dass lokale Rolle, Plattform, Version beziehungsweise Berechtigung Cluster-, Seeding- oder Reparatur-DMVs nicht verfügbar machen. SourceStatus und Partialität sind deshalb Teil des Ergebnisses.

Für `USP_AvailabilityDeepAnalysis` gilt zusätzlich: **keine Zeile** bedeutet, dass im sichtbaren und gefilterten Scope kein ausgabefähiger Datensatz entstand. **0** ist ein gemessener Nullwert nur dann, wenn die Quellspalte tatsächlich verfügbar war. **NULL** bedeutet unbekannt, nicht anwendbar oder nicht auflösbar. **PARTIAL/Warning** bedeutet, dass mindestens eine Teilquelle, Datenbank oder Detailstufe fehlt. Ein Limit kann eine nichtleere Quelle vollständig aus dem sichtbaren Ausschnitt verdrängen.

## Eigenlast und Grenzen

| Dimension | Aussage für diese Procedure |
|---|---|
| Kostenklasse | LOW–MEDIUM |
| Standardpfad | Lokaler HADR-/Clustersnapshot mit `@MitClusterNetzwerken = 0` und Standardlimit. |
| Teuerster Pfad | Unbegrenzte RAW-Ausgabe mit Cluster-Netzwerken über viele AGs, Replicas, Datenbanken, Seeding- und Page-Repair-Zeilen. |
| Haupttreiber | Zahl lokaler AGs, Replicas und Availability-Datenbanken sowie Seeding-, Auto-Page-Repair-, Cluster- und optional Netzwerkzeilen. Ohne AG-/Datenbankfilter wird dieser lokale Gesamtbestand vor den Resultsetlimits erhoben. |
| Skalierung | Laufzeit und CPU wachsen mit dem Haupttreiber. Sortierung/Aggregation erhöht Speicher- und gegebenenfalls TempDB-Bedarf; breite Texte/XML sowie viele Zeilen erhöhen Netzwerk- und Clientkosten. Für USP_AvailabilityDeepAnalysis ist insbesondere die im Datenkettenabschnitt beschriebene Reihenfolge maßgeblich. |
| Ressourcen | Geringe bis mittlere CPU für lokale HADR-/Cluster-DMVs und Temp-Tabellen; kein Remotequery, Nutzdaten-, Log- oder Storage-Scan. |
| Begrenzungswirkung | MaxZeilen begrenzt Resultsets, aber nicht zwingend alle vorab gelesenen HADR-/Clusterzeilen und nie die zeitliche Nicht-Atomarität der Teilquellen. |
| Locking und Nebenwirkungen | Read-only. Zustände ändern sich während der verteilten Erfassung; nicht erreichbare Komponenten liefern partielle Evidenz statt eines konsistenten Gesamtsnapshots. |
| Schutzmechanismus | Kein High-Impact-Gate. `@MitClusterNetzwerken = 0` lässt die optionale Netzwerksicht aus, Schwellen priorisieren Findings und `@MaxZeilen` begrenzt jedes Resultset. Da weder Datenbank- noch AG-Filter existieren, schützt das Limit nicht vor dem vollständigen lokalen HADR-/Cluster-Snapshot. |
| Sicherer Einsatz | Mit `@MitClusterNetzwerken = 0` und Standardlimit beginnen; lokale Rolle dokumentieren und Netzwerkdetails nur bei passender Clusterhypothese aktivieren. |
| Aussagegrenze | Scope- oder Zeilenbegrenzungen können relevante, seltene oder später einsortierte Zeilen ausblenden. Die Aussage bleibt auf das Modell „verteilter, nicht atomarer Snapshot“, die dokumentierte Granularität und den sichtbaren Quellenscope begrenzt; ein kleines Resultset ist weder automatisch vollständig noch repräsentativ. |

## Technische Vertiefung

[Gemeinsames Execution-, Zeit- und Evidenzmodell](../Technical_Foundations.md)

### Leitfrage

Warum ist eine AG/Replica nicht gesund, welche Datenbewegungsstufe staut und welche Risiken entstehen?

### Technischer Hintergrund

Vertiefung kombiniert Cluster-/Replica-/Databasezustand, Send/Redo, Flow Control, Suspend Reason, Seeding, Page Repair und gegebenenfalls Read-only Routing. Logproduktion, Capture, Send, Harden und Redo sind getrennte Pipelineabschnitte.

### Datenkette

`sys.availability_groups`, `sys.availability_replicas`, `sys.dm_hadr_auto_page_repair`, `sys.dm_hadr_availability_replica_states`, `sys.dm_hadr_cluster`, `sys.dm_hadr_cluster_members`, `sys.dm_hadr_cluster_networks`, `sys.dm_hadr_database_replica_states`, `sys.dm_hadr_physical_seeding_stats`.

### Source Select

Das Grundselect zeigt die zentrale AG-Kette von Gruppe über Replikat bis zur lokalen Datenbank-Replikatzustandszeile:

```sql
SELECT
      [ag].[name] AS [AvailabilityGroupName]
    , [ar].[replica_server_name]
    , [ars].[role_desc]
    , [d].[name] AS [DatabaseName]
    , [drs].[synchronization_state_desc]
    , [drs].[log_send_queue_size]
    , [drs].[redo_queue_size]
FROM [sys].[availability_groups] AS [ag] WITH (NOLOCK)
JOIN [sys].[availability_replicas] AS [ar] WITH (NOLOCK)
  ON [ar].[group_id] = [ag].[group_id]
LEFT JOIN [sys].[dm_hadr_availability_replica_states] AS [ars] WITH (NOLOCK)
  ON [ars].[replica_id] = [ar].[replica_id]
LEFT JOIN [sys].[dm_hadr_database_replica_states] AS [drs] WITH (NOLOCK)
  ON [drs].[group_id] = [ag].[group_id]
 AND [drs].[replica_id] = [ar].[replica_id]
LEFT JOIN [master].[sys].[databases] AS [d] WITH (NOLOCK)
  ON [d].[database_id] = [drs].[database_id]
WHERE [ag].[name] = N'ExampleAvailabilityGroup';
```

**Wichtig für die Eigenlast:** Gruppe oder Datenbank vor Physical-Seeding- und Auto-Page-Repair-Historie eingrenzen. Die synthetische Gruppe `ExampleAvailabilityGroup` ist nur ein Platzhalter.

### Zeit- und Scope-Modell

Die Auswertung beschreibt den aktuellen verteilungsabhängigen Snapshot; einige Daten sind nur auf dem Primary oder der lokalen Replica verfügbar.

### Bewertung und Gegenprobe

Lokalisieren Sie die Pipeline anhand von Log Send Queue und Redo Queue, Rate und Trend, Connected und Suspended, Last Hardened und Redone, Sync Commit Waits sowie Disk- und Networkkontext. Kennzeichnen Sie eine partielle Sichtbarkeit ausdrücklich.

### Typische Fehlinterpretation

Estimated catch-up time aus Queue/aktueller Rate ist bei Rateänderung instabil. `NOT_HEALTHY` ist Folge, nicht Root Cause.

### Folgeanalyse

Für die weitere Analyse gelten folgende Schritte und Quellen: Current Log/I/O/Waits, Clusterlog, OS-/Netzwerktelemetrie.

## Primärquellen

- [Always On Availability Groups](https://learn.microsoft.com/en-us/sql/database-engine/availability-groups/windows/monitor-availability-groups-transact-sql?view=sql-server-ver17)

[Technische Detailbeschreibung](../07_Infrastructure.md#10-monitorusp_availabilitydeepanalysis)
