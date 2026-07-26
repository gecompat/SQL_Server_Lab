# [monitor].[USP_ServerNuma]

**Bereich:** Server Health<br>
**Zweck:** Zeigt NUMA-Nodes, Schedulerverteilung und Memory-Node-Kontext.<br>
**Beobachtungsart:** Snapshot<br>
**Kostenklasse:** LOW

## Entscheidungsfrage und Einsatz

Die Procedure beantwortet die Betriebsfrage: **Wie sind Scheduler und Memory auf SQLOS-/Hardware-NUMA-Nodes verteilt und gibt es sichtbare Ungleichgewichte?** Sie unterstützt die Entscheidung, ob eine Instanzressource oder Konfiguration als belastbare Spur zum Symptom passt und welche unabhängige OS-, Verlaufs- oder Workloadevidenz fehlt.

## Nicht beantwortete Fragen

Die Procedure beantwortet keine vollständige OS-/Hypervisorursache und ohne Delta oder Verlauf keine belastbare Aussage über einen dauerhaften Engpass. Der Zeitvertrag ist im Abschnitt „Zeit- und Scope-Modell“ konkretisiert. Ein Einzelwert gilt daher nur für diesen Scope und Zeitpunkt; er belegt weder eine Ursache noch eine Entwicklung.

## Sicherer Einstieg

```sql
EXEC [monitor].[USP_ServerNuma]
      @ResultSetArt = 'CONSOLE';
```

Alle `Example*`-Werte im Aufruf sind synthetisch.

## Resultsets und Leserichtung

Der typisierte TABLE-Vertrag registriert `numaNodes`. Status, Scope und Warnings sind vor den Fachergebnissen zu lesen. CONSOLE dient der interaktiven Triage; RAW und JSON erhalten den technischen Kontext, während TABLE nur die ausdrücklich benannten stabilen Resultsets schreibt. Resultsets mit unterschiedlicher Zeilengranularität dürfen nicht ungeprüft vereinigt oder summiert werden.

## Eine Zeile bedeutet

Je Resultset entspricht eine Zeile einem NUMA-/Memory-Node oder einem Scheduler.

## So lesen

Vergleichen Sie Schedulerzahl, Online-/Idle-Zustand, Memory Node, Foreign Memory und Last je Node.

## Warum kann das problematisch sein?

Persistente Asymmetrie kann lokale CPU-Engpässe und Remote-Memory-Zugriffe begünstigen.

## Wann ist es kein Problem?

Momentan unterschiedliche Last je Node ist normal; erst wiederholte Asymmetrie ist belastbar.

## Beispiele und Gegenbeispiele

**Synthetischer Problemfall (`Example*`):** Wenn ein Node dauerhaft voll ausgelastet ist, ein anderer nahezu idle bleibt und Sessions konzentriert sind, müssen Affinity, Verbindungslast, Soft-NUMA und Schedulerwaits geprüft werden.

**Ähnlich aussehender Gegenfall:** Momentan unterschiedliche Last je Node ist normal; erst wiederholte Asymmetrie ist belastbar. Der gleiche Einzelwert kann deshalb bei `ExampleDb` ohne Nutzerauswirkung unkritisch sein, während er bei zeitgleicher SLA-Verletzung eine Vertiefung rechtfertigt.

## Leere oder partielle Ausgabe

Server-DMVs können plattform-, editions- oder berechtigungsbedingt fehlen. NULL und PARTIAL sind dann Evidenzgrenzen, keine Nullmessung.

Für `USP_ServerNuma` gilt zusätzlich: **keine Zeile** bedeutet, dass im sichtbaren und gefilterten Scope kein ausgabefähiger Datensatz entstand. **0** ist ein gemessener Nullwert nur dann, wenn die Quellspalte tatsächlich verfügbar war. **NULL** bedeutet unbekannt, nicht anwendbar oder nicht auflösbar. **PARTIAL/Warning** bedeutet, dass mindestens eine Teilquelle, Datenbank oder Detailstufe fehlt. Ein Limit kann eine nichtleere Quelle vollständig aus dem sichtbaren Ausschnitt verdrängen.

## Eigenlast und Grenzen

| Dimension | Aussage für diese Procedure |
|---|---|
| Kostenklasse | LOW |
| Standardpfad | Aggregiert sichtbare Scheduler je Parent-NUMA-Node und liest anschließend SQLOS- sowie Memory-Nodes. RAW/JSON zeigen beide Granularitäten, TABLE nur `numaNodes`. |
| Teuerster Pfad | Es gibt keinen optionalen Deep-Pfad. Die maximale Quellmenge ist durch Scheduler- und Nodezahl der Instanz begrenzt; auch große Server bleiben gegenüber Workload-DMVs klein. |
| Haupttreiber | Zahl der SQLOS-Scheduler und NUMA-/Memory-Nodes. `scheduler_id >= 1048576` und der DAC-Node werden aus der fachlichen Sicht ausgeschlossen; Memory Nodes sind auf IDs unter 64 begrenzt. |
| Skalierung | Ein vollständiger Scheduler-Snapshot wird nach Parent gruppiert; CPU wächst linear mit der Schedulerzahl, Resultzeilen nur mit Nodes. |
| Ressourcen | Geringe SQLOS-DMV-CPU und kleine Temp-Tabellen. Keine Datenbankkataloge, Historie, XML oder Samplingverbindung. |
| Begrenzungswirkung | Es existiert kein Zeilen-/Scopeparameter, weil eine Teilmenge der NUMA-Topologie irreführend wäre. Ausgabeunterdrückung mit `NONE` spart die Quellerhebung nicht. |
| Locking und Nebenwirkungen | Read-only ohne Nutzdatenlocks. Schedulerlast kann sich zwischen Scheduler- und Nodeabfrage ändern; `RunnablePerScheduler` bleibt ein Momentwert, keine Intervallrate. |
| Schutzmechanismus | Kein Gate und bewusst kein Teil-Scope. Die reale Scheduler-/SQLOS-/Memory-Node-Zahl begrenzt die Quelle konstruktiv; eine künstliche TOP-Auswahl würde die Topologie eher verfälschen als die ohnehin kleine Abfrage sinnvoll schützen. |
| Sicherer Einsatz | CONSOLE direkt verwenden und Runnable-Signale mit wiederholten Messpunkten sowie CPU-/Wait-Evidenz gegenprüfen; ein eigener Scope ist nicht erforderlich. |
| Aussagegrenze | Der Snapshot zeigt SQLOS-Zuordnung und momentane Runnable Tasks, aber weder historische CPU-Sättigung noch VM-vNUMA-/Hosttopologie. Ein einzelner unbalancierter Moment beweist kein dauerhaftes NUMA-Problem. |

## Technische Vertiefung

[Gemeinsames Execution-, Zeit- und Evidenzmodell](../Technical_Foundations.md)

### Leitfrage

Wie sind Scheduler und Memory auf SQLOS-/Hardware-NUMA-Nodes verteilt und gibt es sichtbare Ungleichgewichte?

### Technischer Hintergrund

NUMA hält CPU und lokal angebundenes Memory zusammen. SQLOS-Nodes/Scheduler verteilen Workers; Memory Nodes verwalten Locality. Soft-NUMA kann zusätzliche logische Gruppen erzeugen. Remote Memory Access kann teurer sein.

### Datenkette

`sys.dm_os_memory_nodes`, `sys.dm_os_nodes`, `sys.dm_os_schedulers`.

### Source Select

Scheduler werden nach Parent-Node aggregiert und dem NUMA-Node zugeordnet:

```sql
SELECT
      [n].[node_id]
    , [n].[memory_node_id]
    , [n].[node_state_desc]
    , COUNT_BIG([s].[scheduler_id]) AS [SchedulerCount]
    , SUM(CONVERT(bigint, [s].[runnable_tasks_count])) AS [RunnableTasks]
    , SUM(CONVERT(bigint, [s].[active_workers_count])) AS [ActiveWorkers]
FROM [sys].[dm_os_nodes] AS [n] WITH (NOLOCK)
LEFT JOIN [sys].[dm_os_schedulers] AS [s] WITH (NOLOCK)
  ON [s].[parent_node_id] = [n].[node_id]
 AND [s].[scheduler_id] < 1048576
WHERE [n].[node_state_desc] <> N'ONLINE DAC'
GROUP BY [n].[node_id], [n].[memory_node_id], [n].[node_state_desc];
```

**Wichtig für die Eigenlast:** Interne/DAC-Scheduler an der Quelle ausschließen. `sys.dm_os_memory_nodes` ist eine separate Zeilengranularität und wird nur über Node-IDs interpretiert, nicht ungeprüft mit Schedulerzählern summiert.

### Zeit- und Scope-Modell

Die Auswertung beschreibt den aktuellen Node-/Schedulerzustand; Loadcounter sind Momentaufnahme oder kumulativ je Quelle.

### Bewertung und Gegenprobe

Vergleichen Sie Online/Idle Schedulers, Runnable Tasks, Active Workers, Load Factor, Memory Nodezuordnung und wiederholte Samples. Ein persistentes einseitiges Muster ist relevanter als ein Snapshot.

### Typische Fehlinterpretation

Ungleiche Momentaufnahme ist bei zufälliger Workload normal. Node ID ist kein direkter physischer Socketbeweis bei Soft-NUMA/VM.

### Folgeanalyse

Für die weitere Analyse gelten folgende Schritte und Quellen: `USP_ServerCpuTopology`, Current Requests und Server Memory.

## Primärquellen

- [sys.dm_os_nodes](https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-views/sys-dm-os-nodes-transact-sql?view=sql-server-ver17)

[Technische Detailbeschreibung](../08_Server_Health.md#2-monitorusp_servernuma)
