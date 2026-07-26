# [monitor].[USP_ServerCpuTopology]

**Bereich:** Server Health<br>
**Zweck:** Zeigt CPU-, Socket-, Core-, Scheduler- und NUMA-Topologie.<br>
**Beobachtungsart:** Snapshot<br>
**Kostenklasse:** LOW

## Entscheidungsfrage und Einsatz

Die Procedure beantwortet die Betriebsfrage: **Welche CPU-, Socket-, Core-, Hyperthread-, Scheduler- und Affinitystruktur sieht SQL Server?** Sie unterstützt die Entscheidung, ob eine Instanzressource oder Konfiguration als belastbare Spur zum Symptom passt und welche unabhängige OS-, Verlaufs- oder Workloadevidenz fehlt.

## Nicht beantwortete Fragen

Die Procedure beantwortet keine vollständige OS-/Hypervisorursache und ohne Delta oder Verlauf keine belastbare Aussage über einen dauerhaften Engpass. Der Zeitvertrag ist im Abschnitt „Zeit- und Scope-Modell“ konkretisiert. Ein Einzelwert gilt daher nur für diesen Scope und Zeitpunkt; er belegt weder eine Ursache noch eine Entwicklung.

## Sicherer Einstieg

```sql
EXEC [monitor].[USP_ServerCpuTopology]
      @ResultSetArt = 'CONSOLE';
```

Alle `Example*`-Werte im Aufruf sind synthetisch.

## Resultsets und Leserichtung

Der typisierte TABLE-Vertrag registriert `cpuTopology`. Status, Scope und Warnings sind vor den Fachergebnissen zu lesen. CONSOLE dient der interaktiven Triage; RAW und JSON erhalten den technischen Kontext, während TABLE nur die ausdrücklich benannten stabilen Resultsets schreibt. Resultsets mit unterschiedlicher Zeilengranularität dürfen nicht ungeprüft vereinigt oder summiert werden.

## Eine Zeile bedeutet

Je Resultset beschreibt eine Zeile eine Topologiezusammenfassung, einen Scheduler oder einen NUMA-Knoten.

## So lesen

Vergleichen Sie logische CPUs, Sockets, Cores, sichtbare/online Scheduler, Soft-NUMA und aktuelle Last.

## Warum kann das problematisch sein?

Unerwartet offline oder hidden Scheduler und ungewöhnliche Topologie können Parallelität, Lizenzierung und Lastverteilung beeinflussen.

## Wann ist es kein Problem?

Soft-NUMA und bestimmte Schedulerzustände können absichtlich von SQL Server erzeugt werden.

## Beispiele und Gegenbeispiele

**Synthetischer Problemfall (`Example*`):** 64 OS-CPUs, aber 32 online sichtbar: Lizenz-, Affinity-, Edition- und VM-Kontext prüfen, nicht sofort Hardwarefehler annehmen. Korrelieren Sie NUMA und OS.

**Ähnlich aussehender Gegenfall:** Soft-NUMA und bestimmte Schedulerzustände können absichtlich von SQL Server erzeugt werden. Der gleiche Einzelwert kann deshalb bei `ExampleDb` ohne Nutzerauswirkung unkritisch sein, während er bei zeitgleicher SLA-Verletzung eine Vertiefung rechtfertigt.

## Leere oder partielle Ausgabe

Server-DMVs können plattform-, editions- oder berechtigungsbedingt fehlen. NULL und PARTIAL sind dann Evidenzgrenzen, keine Nullmessung.

Für `USP_ServerCpuTopology` gilt zusätzlich: **keine Zeile** bedeutet, dass im sichtbaren und gefilterten Scope kein ausgabefähiger Datensatz entstand. **0** ist ein gemessener Nullwert nur dann, wenn die Quellspalte tatsächlich verfügbar war. **NULL** bedeutet unbekannt, nicht anwendbar oder nicht auflösbar. **PARTIAL/Warning** bedeutet, dass mindestens eine Teilquelle, Datenbank oder Detailstufe fehlt. Ein Limit kann eine nichtleere Quelle vollständig aus dem sichtbaren Ausschnitt verdrängen.

## Eigenlast und Grenzen

| Dimension | Aussage für diese Procedure |
|---|---|
| Kostenklasse | LOW |
| Standardpfad | Liest eine `dm_os_sys_info`-Topologiezeile, gruppiert alle regulären Scheduler nach Node/Status und ergänzt SQLOS-Nodes. Keine Option verändert den Quellpfad. |
| Teuerster Pfad | RAW/JSON geben zusätzlich Scheduler- und Nodegrids aus, doch die gleiche kleine DMV-Menge wurde bereits erhoben. Es gibt kein Sample, Cross-Database oder Detailscan. |
| Haupttreiber | Anzahl der Scheduler und Nodes; physische Datenmenge oder Workloadhistorie spielen keine Rolle. Interne Scheduler ab ID 1048576 und der DAC-Node werden ausgeschlossen. |
| Skalierung | Der Scheduler-Scan ist linear, Gruppierung/Sortierung klein. Die Instanzsummary bleibt eine Zeile, Nodes/Schedulergruppen wachsen nur mit Hardware-/SQLOS-Topologie. |
| Ressourcen | Geringe CPU auf drei SQLOS-DMVs und kleine Temp-Tabellen. Kein Katalog-I/O, XML, WAITFOR oder Ergebnistexte. |
| Begrenzungswirkung | Kein `@MaxZeilen`, weil vollständige Topologie benötigt wird. CONSOLE/TABLE zeigen primär `cpuTopology`; RAW/JSON machen die bereits erhobenen Details sichtbar. |
| Locking und Nebenwirkungen | Read-only ohne Nutzdatenlocks. Topologie ist meist stabil, momentane Task-/Runnable-Zähler können sich während der drei Abfragen ändern. |
| Schutzmechanismus | Kein Gate und bewusst kein Zeilenlimit. Der feste Pfad liest eine Topologiezeile sowie die reale Scheduler-/Node-Menge; keine Option öffnet Sampling, Cross-Database- oder Detailfunktionen. |
| Sicherer Einsatz | CONSOLE ist vollständig und kostengünstig. Runnable-Findings nur zusammen mit wiederholter CPU-/Waitmessung und dem NUMA-Child bewerten. |
| Aussagegrenze | SQL Server meldet seine sichtbare Topologie, nicht zwingend die physische Host-/VM-Zuordnung. Ein einzelner Runnable Task ist kein Beweis für CPU-Sättigung; Affinity und Soft-NUMA benötigen Kontext. |

## Technische Vertiefung

[Gemeinsames Execution-, Zeit- und Evidenzmodell](../Technical_Foundations.md)

### Leitfrage

Welche CPU-, Socket-, Core-, Hyperthread-, Scheduler- und Affinitystruktur sieht SQL Server?

### Technischer Hintergrund

SQL Server erstellt SQLOS-Scheduler für sichtbare logische CPUs unter Berücksichtigung von Edition, Lizenz-/Affinitykonfiguration und Onlinezustand. Sockets, NUMA Nodes, Cores und Hyperthreading beeinflussen Parallelität, Lizenzierung und Memorylocality.

### Datenkette

`sys.dm_os_nodes`, `sys.dm_os_schedulers`, `sys.dm_os_sys_info`.

### Source Select

Die momentane Schedulerlast wird nach NUMA-Parent-Node gruppiert und mit dem Nodekatalog verbunden:

```sql
SELECT
      [n].[node_id]
    , [n].[node_state_desc]
    , COUNT_BIG(*) AS [SchedulerCount]
    , SUM(CONVERT(bigint, [s].[runnable_tasks_count])) AS [RunnableTasks]
    , SUM(CONVERT(bigint, [s].[active_workers_count])) AS [ActiveWorkers]
FROM [sys].[dm_os_nodes] AS [n] WITH (NOLOCK)
LEFT JOIN [sys].[dm_os_schedulers] AS [s] WITH (NOLOCK)
  ON [s].[parent_node_id] = [n].[node_id]
 AND [s].[scheduler_id] < 1048576
WHERE [n].[node_state_desc] <> N'ONLINE DAC'
GROUP BY [n].[node_id], [n].[node_state_desc];
```

**Wichtig für die Eigenlast:** DAC- und interne Scheduler bereits an der Quelle ausschließen. Die DMVs sind klein; Werte sind ein flüchtiger Snapshot und keine CPU-Historie.

### Zeit- und Scope-Modell

Die Auswertung beschreibt den aktuellen Instanz-/Startzustand; Hardwarezuweisung in VM/Container kann sich erst nach Neustart vollständig widerspiegeln.

### Bewertung und Gegenprobe

Berücksichtigen Sie Visible und Online Schedulers, Physical und Logical CPU, das Socket-Core-Verhältnis, Hyperthread Ratio, Affinity und Edition gemeinsam. Eine ungleiche Schedulerverfügbarkeit oder eine unerwartete CPU-Anzahl ist ein Konfigurationshinweis.

### Typische Fehlinterpretation

Viele CPUs bedeuten nicht automatisch mehr Queryleistung. MAXDOP, Cost Threshold, NUMA, Lizenzgrenze und Workloadparallelität bestimmen Nutzung.

### Folgeanalyse

Für die weitere Analyse gelten folgende Schritte und Quellen: `USP_ServerNuma`, Performance Counters, Current Requests/Waits.

## Primärquellen

- [sys.dm_os_sys_info](https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-views/sys-dm-os-sys-info-transact-sql?view=sql-server-ver17)

[Technische Detailbeschreibung](../08_Server_Health.md#1-monitorusp_servercputopology)
