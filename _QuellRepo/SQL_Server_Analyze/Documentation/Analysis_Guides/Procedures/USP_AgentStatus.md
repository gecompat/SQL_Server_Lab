# [monitor].[USP_AgentStatus]

**Bereich:** Infrastruktur<br>
**Zweck:** Zeigt Plattformunterstützung, Dienststatus und SQL-Agent-Konfiguration.<br>
**Beobachtungsart:** Snapshot<br>
**Kostenklasse:** LOW

## Entscheidungsfrage und Einsatz

Die Procedure beantwortet die Betriebsfrage: **Ist SQL Server Agent auf dieser Plattform vorhanden und läuft der Dienst?** Sie unterstützt die Entscheidung, ob Betriebsbereitschaft, Wiederherstellbarkeit oder verteilte Datenbewegung auffällig ist und welcher zuständige Teilprozess geprüft werden muss.

## Nicht beantwortete Fragen

Die Procedure beantwortet keinen erfolgreichen Restore, Failover oder End-to-End-Datenfluss nur aus Konfigurations- und Historymetadaten. Der Zeitvertrag ist im Abschnitt „Zeit- und Scope-Modell“ konkretisiert. Ein Einzelwert gilt daher nur für diesen Scope und Zeitpunkt; er belegt weder eine Ursache noch eine Entwicklung.

## Sicherer Einstieg

```sql
EXEC [monitor].[USP_AgentStatus]
      @ResultSetArt = 'CONSOLE';
```

Alle `Example*`-Werte im Aufruf sind synthetisch.

## Resultsets und Leserichtung

Der typisierte TABLE-Vertrag registriert `agentStatus`. Status, Scope und Warnings sind vor den Fachergebnissen zu lesen. CONSOLE dient der interaktiven Triage; RAW und JSON erhalten den technischen Kontext, während TABLE nur die ausdrücklich benannten stabilen Resultsets schreibt. Resultsets mit unterschiedlicher Zeilengranularität dürfen nicht ungeprüft vereinigt oder summiert werden.

## Eine Zeile bedeutet

Je Resultset beschreibt eine Zeile einen Dienst-, Plattform- oder Konfigurationsaspekt des SQL Agents.

## So lesen

Unterscheiden Sie Plattformunterstützung, Dienststatus, Startmodus und Agentkonfiguration.

## Warum kann das problematisch sein?

Ein gestoppter Agent verhindert geplante Backups, Wartung, ETL und Alerts.

## Wann ist es kein Problem?

Auf Plattformen ohne klassischen SQL Agent oder bei bewusst externem Scheduling ist Nichtverfügbarkeit erwartbar.

## Beispiele und Gegenbeispiele

**Synthetischer Problemfall (`Example*`):** Ein gestoppter Agent ist auf einer Instanz mit geplanten Logbackups kritisch. Auf einer agentlosen Plattform muss dagegen der alternative Scheduler dokumentiert werden. Prüfen Sie danach Jobs und Monitoringpfad.

**Ähnlich aussehender Gegenfall:** Auf Plattformen ohne klassischen SQL Agent oder bei bewusst externem Scheduling ist Nichtverfügbarkeit erwartbar. Der gleiche Einzelwert kann deshalb bei `ExampleDb` ohne Nutzerauswirkung unkritisch sein, während er bei zeitgleicher SLA-Verletzung eine Vertiefung rechtfertigt.

## Leere oder partielle Ausgabe

Ein leerer Historypfad kann Retention/Cleanup, deaktivierte Komponente oder falschen Scope bedeuten; er beweist keine erfolgreiche Ausführung.

Für `USP_AgentStatus` gilt zusätzlich: **keine Zeile** bedeutet, dass im sichtbaren und gefilterten Scope kein ausgabefähiger Datensatz entstand. **0** ist ein gemessener Nullwert nur dann, wenn die Quellspalte tatsächlich verfügbar war. **NULL** bedeutet unbekannt, nicht anwendbar oder nicht auflösbar. **PARTIAL/Warning** bedeutet, dass mindestens eine Teilquelle, Datenbank oder Detailstufe fehlt. Ein Limit kann eine nichtleere Quelle vollständig aus dem sichtbaren Ausschnitt verdrängen.

## Eigenlast und Grenzen

**Quellcode-Hinweis zur Eigenlast:** Die Eigenlast ist gering.

| Dimension | Aussage für diese Procedure |
|---|---|
| Kostenklasse | LOW |
| Standardpfad | Ein kleiner Instanzsnapshot aus Agent-Dienstzeile, letzter Agent-Session und zwei Jobzählungen. Die Procedure besitzt keine Scope-, History- oder Zeilenparameter. |
| Teuerster Pfad | Praktisch derselbe feste Pfad auf einer Instanz mit sehr vielen Jobs; nur die beiden `COUNT(*)`-Abfragen über `msdb.dbo.sysjobs` wachsen mit der Jobzahl. |
| Haupttreiber | Praktisch nur die Zahl der Zeilen in `msdb.dbo.sysjobs`, weil sie zweimal aggregiert wird. Dienststatus und letzte Agent-Session sind fest auf eine beziehungsweise `TOP (1)` Zeile begrenzt. |
| Skalierung | Nahezu konstant; lediglich die Jobzählungen wachsen mit `sysjobs`. Es werden keine Jobhistory, Steps oder Meldungstexte gelesen. |
| Ressourcen | Sehr geringe CPU-/Katalog-/msdb-I/O-Last und eine schmale Ergebniszeile; kein relevanter TempDB- oder Transferbedarf. |
| Begrenzungswirkung | Nicht anwendbar: Der Pfad ist bereits auf einen Dienstsnapshot, `TOP (1)` Agent-Session und aggregierte Jobzahlen fest begrenzt. |
| Locking und Nebenwirkungen | Read-only; kurze Schema-Stability-Zugriffe auf msdb/Systemkataloge. Jobs, Backups oder Wartung laufen parallel weiter, daher ist das Ergebnis nicht atomar. |
| Schutzmechanismus | Kein Gate und kein Aufruferlimit. Der Schutz ist konstruktiv: genau eine Dienstzeile, `TOP (1)` für die letzte Agent-Session und zwei reine Jobzählungen; weder Jobsteps noch frei wählbare History werden gelesen. |
| Sicherer Einsatz | Der Default-CONSOLE-Aufruf ist der kleinste fachliche Pfad und kann ohne zusätzliche Scopewahl verwendet werden. |
| Aussagegrenze | Der Snapshot sagt nur, ob Agent unterstützt/erkannt ist, welcher Dienstzustand sichtbar ist und wie viele Jobs aktiviert beziehungsweise deaktiviert sind. Er zeigt weder einzelne Jobprobleme noch Steps, letzte Ausgänge, Laufdauer oder einen Historyzeitraum. |

## Technische Vertiefung

[Gemeinsames Execution-, Zeit- und Evidenzmodell](../Technical_Foundations.md)

### Leitfrage

Ist SQL Server Agent auf dieser Plattform vorhanden und läuft der Dienst?

### Technischer Hintergrund

Agent führt Jobs über einen separaten Dienst und `msdb`-Metadaten aus. Dienstzustand, Startmodus und Plattformverfügbarkeit sind Voraussetzungen, aber noch keine Aussage über Scheduler, Jobowner, Proxies oder einzelne Jobs.

### Datenkette

`msdb.dbo.sysjobs`, `msdb.dbo.syssessions`, `sys.dm_server_services`.

### Source Select

Der Status entsteht aus dem sichtbaren Agent-Dienst und der letzten Agent-Session in `msdb`:

```sql
SELECT
      [svc].[servicename]
    , [svc].[status_desc]
    , [agent].[session_id]
    , [agent].[agent_start_date]
FROM [sys].[dm_server_services] AS [svc] WITH (NOLOCK)
OUTER APPLY
(
    SELECT TOP (1)
          [ss].[session_id]
        , [ss].[agent_start_date]
    FROM [msdb].[dbo].[syssessions] AS [ss] WITH (NOLOCK)
    ORDER BY [ss].[agent_start_date] DESC
) AS [agent]
WHERE [svc].[servicename] LIKE N'SQL Server Agent%';
```

**Wichtig für die Eigenlast:** Die Quellen sind klein. Der Dienstfilter verhindert, dass nicht benötigte SQL-Dienste in die weitere Auswertung gelangen.

### Zeit- und Scope-Modell

Die Auswertung beschreibt den aktuellen Servicezustand; bei Restart/Failover kann der Status wechseln.

### Bewertung und Gegenprobe

Berücksichtigen Sie den Dienstzustand, Edition und Plattform, den Startmodus sowie Agent XPs und Erreichbarkeit gemeinsam. Ein bewusst deaktivierter Agent kann in containerisierten oder extern orchestrierten Umgebungen normal sein.

### Typische Fehlinterpretation

`Running` beweist weder aktive Schedules noch erfolgreiche Jobs. Ein gestoppter Agent erklärt fehlende Ausführungen, aber nicht deren ursprüngliche Ursache.

### Folgeanalyse

Für die weitere Analyse gelten folgende Schritte und Quellen: `USP_AgentJobs` und `USP_AgentMonitoringAnalysis`.

## Primärquellen

- [SQL Server Agent](https://learn.microsoft.com/en-us/ssms/agent/sql-server-agent?view=sql-server-ver17)

[Technische Detailbeschreibung](../07_Infrastructure.md#1-monitorusp_agentstatus)
