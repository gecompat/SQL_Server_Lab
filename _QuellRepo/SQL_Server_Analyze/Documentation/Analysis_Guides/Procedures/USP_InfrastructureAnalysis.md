# [monitor].[USP_InfrastructureAnalysis]

**Bereich:** Infrastruktur, Orchestrator<br>
**Zweck:** Orchestriert Agent, Resource Governor, HA, Backup, Log Shipping, Replikation und Data Capture.<br>
**Beobachtungsart:** nicht atomarer Mix aus Konfiguration, Runtime und Historie<br>
**Kostenklasse:** LOW–HIGH_OPT_IN

## Entscheidungsfrage und Einsatz

Die Procedure beantwortet die Betriebsfrage: **Welche Infrastrukturmodule sollen als Triage in einem kontrollierten Lauf zusammengeführt werden?** Sie unterstützt die Entscheidung, ob Betriebsbereitschaft, Wiederherstellbarkeit oder verteilte Datenbewegung auffällig ist und welcher zuständige Teilprozess geprüft werden muss.

## Nicht beantwortete Fragen

Die Procedure beantwortet keinen erfolgreichen Restore, Failover oder End-to-End-Datenfluss nur aus Konfigurations- und Historymetadaten. Der Zeitvertrag ist im Abschnitt „Zeit- und Scope-Modell“ konkretisiert. Ein Einzelwert gilt daher nur für diesen Scope und Zeitpunkt; er belegt weder eine Ursache noch eine Entwicklung.

## Sicherer Einstieg

```sql
EXEC [monitor].[USP_InfrastructureAnalysis]
      @DatabaseNames = N'[ExampleDatabase]',
      @MaxZeilen = 100,
      @ResultSetArt = 'CONSOLE';
```

Aktivieren Sie Tiefenmodule nur bei konkreter Fragestellung.

Alle `Example*`-Werte im Aufruf sind synthetisch.

## Resultsets und Leserichtung

Der typisierte TABLE-Vertrag registriert `moduleStatus`. Status, Scope und Warnings sind vor den Fachergebnissen zu lesen. CONSOLE dient der interaktiven Triage; RAW und JSON erhalten den technischen Kontext, während TABLE nur die ausdrücklich benannten stabilen Resultsets schreibt. Resultsets mit unterschiedlicher Zeilengranularität dürfen nicht ungeprüft vereinigt oder summiert werden.

## Eine Zeile bedeutet

Die Granularität hängt vom Child ab: Dienst, Job, Pool, Replica, Datenbank, Backup, Log-Shipping-Paar, Replikationsobjekt oder Capturefeature.

## So lesen

Prüfen Sie zuerst den Childstatus. Unterscheiden Sie nicht verwendete Features von fehlenden Rechten und Fehlern.

## Warum kann das problematisch sein?

Ein leeres Child kann „Feature nicht eingesetzt“ oder „Quelle nicht lesbar“ bedeuten. Beide Aussagen sind fachlich verschieden.

## Wann ist es kein Problem?

Keine AG-Zeilen auf einer Standalone-Instanz sind erwartbar.

## Beispiele und Gegenbeispiele

**Synthetischer Problemfall (`Example*`):** Backupchild partiell, AG-Child unavailable feature: Nur der Backupbereich benötigt Nacharbeit. Führen Sie Auffälliges Child gezielt erneut aus.

**Ähnlich aussehender Gegenfall:** Keine AG-Zeilen auf einer Standalone-Instanz sind erwartbar. Der gleiche Einzelwert kann deshalb bei `ExampleDb` ohne Nutzerauswirkung unkritisch sein, während er bei zeitgleicher SLA-Verletzung eine Vertiefung rechtfertigt.

## Leere oder partielle Ausgabe

Ein leerer Historypfad kann Retention/Cleanup, deaktivierte Komponente oder falschen Scope bedeuten; er beweist keine erfolgreiche Ausführung.

Für `USP_InfrastructureAnalysis` gilt zusätzlich: **keine Zeile** bedeutet, dass im sichtbaren und gefilterten Scope kein ausgabefähiger Datensatz entstand. **0** ist ein gemessener Nullwert nur dann, wenn die Quellspalte tatsächlich verfügbar war. **NULL** bedeutet unbekannt, nicht anwendbar oder nicht auflösbar. **PARTIAL/Warning** bedeutet, dass mindestens eine Teilquelle, Datenbank oder Detailstufe fehlt. Ein Limit kann eine nichtleere Quelle vollständig aus dem sichtbaren Ausschnitt verdrängen.

## Eigenlast und Grenzen

| Dimension | Aussage für diese Procedure |
|---|---|
| Kostenklasse | LOW–HIGH_OPT_IN |
| Standardpfad | Acht Children laufen: Agentstatus/-jobs, Resource Governor, Availability Groups, Backup/Recovery, Log Shipping, Replikation und Data Capture. Das ist eine breite Konfigurations-/Statusrunde, kein einzelner „kleiner“ Query. |
| Teuerster Pfad | Zusätzlich Distributiondetails, Backupketten, tiefe Availability-Evidenz und Agent Monitoring. Dieselben `msdb`-, HA- und Datenbankbereiche werden dabei teilweise in mehreren Children aus anderer Perspektive erneut gelesen. |
| Haupttreiber | Größe von `msdb`-Job-/Backup-/Restorehistorie, Zahl der Datenbanken und Captureobjekte, Replikations-/Distributionsmetadaten sowie AG-Replicas und -Datenbanken. Nicht aktivierte Technologien sind meist günstig, müssen aber zunächst erkannt werden. |
| Skalierung | Die Module laufen sequenziell ohne gemeinsamen Snapshot oder gemeinsamen Quellcache. Mehr aktivierte Children addieren ihre Kosten; ein breiter Datenbankscope wird von mehreren Children separat enumeriert. |
| Ressourcen | Vor allem `msdb`-I/O, Server-/HA-DMVs, Datenbankkataloge, CPU für Aggregation und JSON/Ergebnistransfer. Der Orchestrator enthält weder Sampling noch XEL-/Plan-XML-Parsing. |
| Begrenzungswirkung | `@MaxZeilen` wird je Child weitergereicht, aber nicht an `USP_AgentStatus`, dessen Quelle ohnehin konstant klein ist. Historien- und Statuschildren setzen Limits an unterschiedlichen Stellen; ein kleines Parentlimit verhindert deshalb nicht jede `msdb`-Aggregation oder Datenbankenumeration. |
| Locking und Nebenwirkungen | Read-only und sequenziell. Es werden weder Jobs gestartet noch Backup-, HA-, Replikations- oder Capturekonfigurationen geändert; Status kann sich zwischen den Childaufrufen ändern. `LOCK_TIMEOUT 0` am Parent ist keine globale Laufzeitgrenze für Children. |
| Schutzmechanismus | Die drei tieferen Zusatzmodule sind standardmäßig aus; Distributiondetails besitzen einen eigenen Schalter. `@HighImpactConfirmed` wird nur an Children weitergegeben, die ein Policygate auswerten. Er ersetzt weder Datenbankscope noch Historienlimit. |
| Sicherer Einsatz | Eine Datenbank und kleines `@MaxZeilen` wählen, die vier Opt-ins aus lassen und nicht benötigte Standardchildren explizit deaktivieren. Modulstatus vor fachlichen Resultsets lesen. |
| Aussagegrenze | Ein leerer Child kann „Feature nicht genutzt“, „nicht lokal sichtbar“ oder „Berechtigung/Quelle fehlt“ bedeuten. Wegen getrennten Messzeitpunkten dürfen Job-, Backup- und HA-Zustände nicht als atomarer Infrastrukturzustand zusammeninterpretiert werden. |

## Technische Vertiefung

[Gemeinsames Execution-, Zeit- und Evidenzmodell](../Technical_Foundations.md)

### Leitfrage

Welche Infrastrukturmodule sollen als Triage in einem kontrollierten Lauf zusammengeführt werden?

### Technischer Hintergrund

Der Wrapper orchestriert Agent, Resource Governor, AG, Backup, Log Shipping, Replication und Capture. Nicht konfigurierte Features sollen als Status statt Fehler behandelt werden; Deep Children bleiben opt-in.

### Datenkette

Die Datenkette besteht aus frameworkinterner Orchestrierung; die Quellen liegen in den Childmodulen.

### Source Select

Kein einzelnes Grundselect wird verwendet. Die Procedure orchestriert Agent-, Resource-Governor-, Availability-, Backup-, Log-Shipping-, Replication- und Data-Capture-Module. Die direkten Beziehungen stehen auf den jeweiligen Child-Seiten.

**Wichtig für die Eigenlast:** Aktivieren Sie nur die für das Symptom benötigten Module. Reichen Sie Datenbank- und Zeitfilter an History-Childmodule weiter; ein finales Zeilenlimit spart deren `msdb`-, Distribution- oder HADR-Quellarbeit nicht.

### Zeit- und Scope-Modell

Die Auswertung kombiniert Snapshots und `msdb`-Historien nicht atomar.

### Bewertung und Gegenprobe

Vertiefen Sie Modulstatus zuerst, dann nur konfigurierte/auffällige Komponenten. Ein nicht vorhandenes Feature ist normal, sofern der Scope es nicht erwartet.

### Typische Fehlinterpretation

Leere Resultsets dürfen nicht quellenübergreifend als gesund zusammengefasst werden; jede Quelle besitzt eigene Retention und Berechtigung.

### Folgeanalyse

Führen Sie das betroffene Childmodul mit einem engen Scope aus.

## Primärquellen

- [SQL Server Agent](https://learn.microsoft.com/en-us/ssms/agent/sql-server-agent?view=sql-server-ver17)

[Technische Detailbeschreibung](../07_Infrastructure.md#12-monitorusp_infrastructureanalysis)
