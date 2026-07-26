# [monitor].[USP_WorkerPressureAnalysis]

**Bereich:** Server Health<br>
**Zweck:** Trennt Worker-Warteschlangen von CPU-Runnable-Queues und korreliert begrenzten Laufzeitkontext.<br>
**Beobachtungsart:** kurzer Scheduler-Delta- und flüchtiger Worker-/Wait-/Request-Snapshot<br>
**Kostenklasse:** LOW–MEDIUM

## Entscheidungsfrage und Einsatz

Die Procedure beantwortet: **Warten Tasks auf einen Worker, warten bereits gebundene Worker auf CPU oder ist im kurzen Sample keine solche Queue sichtbar?** Dafür werden sichtbare Online-Scheduler zweimal beobachtet, Worker sofort je Scheduler aggregiert und `THREADPOOL`, Blocking sowie begrenzte laufende Requests als gleichzeitiger Kontext ergänzt. SQL-, Plan-, Login-, Host- und Programmnamen werden nicht gelesen.

Die Trennung ist zentral: `work_queue_count` beschreibt Tasks, die auf einen Worker warten. `runnable_tasks_count` beschreibt Worker mit gebundener Task, die auf Schedulerzeit warten. Ein positiver Runnable-Wert ist deshalb CPU-Kontext und kein Beleg für Worker-Erschöpfung. Das Summary priorisiert sichtbare Worker-Queues und `THREADPOOL`; es empfiehlt niemals automatisch, `max worker threads` zu ändern.

## Nicht beantwortete Fragen

Ein einsekündiges Sample ist keine Historie. Kurze Bursts vor oder nach dem Aufruf fehlen. Workerzahl und konfigurierte/effective Grenzwerte erklären nicht, welche Workload die Kapazität bindet. Ohne Query-, Plan- oder externen Verlaufskontext werden weder verursachende Statements noch ein dauerhaftes Kapazitätsproblem bewiesen. `AvailableWorkerCapacity` ist ein technischer Kontextwert, kein SLO.

Die Procedure misst keine reine OS-CPU-Auslastung und keine Hypervisor-Sättigung. Ein Runnable-Signal kann durch SQL-Workload, externe CPU-Konkurrenz, Präemption oder andere Faktoren entstehen. Blocking kann Worker binden, muss aber nicht die primäre Ursache sein. Parallelität, lange Requests und Ressourcenengpässe bleiben Hypothesen für Folgeanalysen.

## Sicherer Einstieg

```sql
EXEC [monitor].[USP_WorkerPressureAnalysis]
      @SampleSeconds = 1,
      @MinRequestElapsedMs = 5000,
      @MaxZeilen = 100,
      @ResultSetArt = 'CONSOLE';
```

Für einen synthetisch leeren Requestkontext kann `@MinRequestElapsedMs = 2147483647` verwendet werden. Vermeiden Sie mehrere parallele Sampler. Variieren Sie den Zeitraum erst bei wiederholter Queue-Evidenz und korrelieren Sie anschließend unabhängige CPU-, Wait- und Requestdaten.

## Resultsets und Leserichtung

Der typisierte Vertrag umfasst `moduleStatus`, `summary`, `schedulers`, `waits`, `requests`, `sourceStatus` und `warnings`. Berücksichtigen Sie zuerst `moduleStatus` und `sourceStatus`. Das Scheduler-Resultset ist die Primärevidenz; Worker, Waits und Requests sind unabhängig isolierte Kontextquellen. Prüfen Sie danach `summary`, anschließend auffällige Scheduler und zuletzt den begrenzten Requestkontext. Ein partieller Worker-Scan macht Scheduler-Queues nicht null, begrenzt aber Workerbelegung und Zustandsverteilung.

## Eine Zeile bedeutet

In `summary` bedeutet eine Zeile den gesamten Aufruf. In `schedulers` ist eine Zeile ein sichtbarer Online-Scheduler am zweiten Messpunkt samt optionalem Delta. In `waits` ist eine Zeile ein aggregierter `THREADPOOL`-Waittyp. In `requests` ist eine Zeile ein aktuell sichtbarer Request, der `THREADPOOL`, Blocking oder die Mindestlaufzeit erfüllt. Die Zeilen besitzen verschiedene Granularität und dürfen nicht additiv verbunden werden.

## So lesen

Berücksichtigen Sie `TotalWorkQueueCount` und `ThreadpoolWaitingTaskCount` gemeinsam, aber nicht als identischen Zähler. `MaxWorkQueuePerScheduler` zeigt mögliche Ungleichverteilung. `TotalRunnableTasks` und `MaxRunnablePerScheduler` bilden den getrennten CPU-Pfad. Workerbelegung, fehlgeschlagene Worker-Erzeugung, Blocking und lange Requests sind Kontext. Bei einem Sample zeigen kumulative Schedulerzähler Deltas; `CounterResetDetected=1` macht diese Deltas unbekannt. Gauge-Differenzen wie Runnable- oder Workeränderung dürfen negativ sein.

## Warum kann das problematisch sein?

Wenn Tasks auf Worker warten, können neue Requests verzögert werden, obwohl CPU nicht vollständig ausgelastet erscheint. Lange blockierte oder hochparallele Requests können Worker binden. Runnable-Queues zeigen hingegen, dass vorhandene Worker CPU-Zeit benötigen. Beide Situationen beeinträchtigen Latenz, verlangen aber verschiedene Gegenproben und mögliche Maßnahmen.

## Wann ist es kein Problem?

Ein einzelner Runnable Task oder eine kurze Queue während eines geplanten Bursts ist nicht automatisch ein Kapazitätsproblem. Hohe Workerbelegung ohne Work Queue und ohne `THREADPOOL` ist nur Kontext. Der automatisch berechnete Default von `max worker threads` ist in vielen Installationen angemessen; eine Änderung ohne Root-Cause-Evidenz kann Nebenwirkungen erzeugen.

## Beispiele und Gegenbeispiele

**Synthetischer Problemfall (`Example*`):** Mehrere Samples zeigen `work_queue_count > 0`, gleichzeitige `THREADPOOL`-Waits und viele blockierte `ExampleDatabase`-Requests. Blocking und Parallelität sind als Ursachenhypothesen stark; zuerst Blocker und Workload untersuchen.

**Gegenbeispiel:** `runnable_tasks_count > 0`, aber Work Queue und `THREADPOOL` bleiben null. Das ist CPU-Scheduler-Kontext, kein Workerpoolnachweis.

**Nicht entscheidbar:** Scheduler verfügbar, Worker-DMV verweigert. Queue-Evidenz bleibt gültig, Workerbelegung und Zustandsverteilung sind partiell. Leiten Sie keine Konfigurationsänderung aus dem unvollständigen Bild ab.

## Leere oder partielle Ausgabe

Das Summary wird auch ohne Druck erzeugt. `NO_WORKER_PRESSURE_VISIBLE_IN_SAMPLE` bedeutet nur, dass im begrenzten Fenster keine Worker-Queue sichtbar war. `AVAILABLE_LIMITED` weist auf eine fehlende Kontextquelle hin. Ist die Schedulerquelle selbst verweigert, fehlt die Primärevidenz und der Modulstatus übernimmt deren Fehlerstatus. NULL ist unbekannt, nicht Nullmessung.

## Eigenlast und Grenzen

| Dimension | Aussage für diese Procedure |
|---|---|
| Kostenklasse | LOW–MEDIUM |
| Standardpfad | Zwei Schedulerbeobachtungen über eine Sekunde, ein aggregierter Worker-Scan und kleine Wait-/Request-Snapshots. |
| Teuerster Pfad | 60-Sekunden-Verbindung mit wiederholten Aufrufen und sehr vielen sichtbaren Workern/Requests. |
| Haupttreiber | Workerzahl, Schedulerzahl, aktuelle Requests und parallele Sampler. |
| Skalierung | Worker werden vollständig gelesen, aber sofort je Scheduler aggregiert; Requestausgabe ist Top-N-begrenzt. |
| Ressourcen | SQLOS-DMV-CPU, kleine TempDB-Tabellen und eine wartende Session während des Samples. |
| Begrenzungswirkung | `@MaxZeilen` begrenzt Requestausgabe, nicht Worker- oder Schedulerquellscan. |
| Locking und Nebenwirkungen | Read-only, `LOCK_TIMEOUT 0`; WAITFOR hält eine Verbindung, keine absichtlichen Nutzdatenlocks. |
| Schutzmechanismus | Sample maximal 60 Sekunden, SQL-/Plan-/Clientidentität ausgeschlossen, getrennte Quellstatus. |
| Sicherer Einsatz | Ein Sampler, eine Sekunde, begrenzte Requests; bei Befund zeitlich getrennt wiederholen. |
| Aussagegrenze | Momentaufnahme ohne Historie oder OS-CPU; kein universeller Worker-Schwellenwert und keine automatische Konfigurationsempfehlung. |

## Technische Vertiefung

[Gemeinsames Execution-, Zeit- und Evidenzmodell](../Technical_Foundations.md)

### Leitfrage

Ist im Messfenster Workerbedarf oder eine getrennte CPU-Runnable-Queue sichtbar?

### Technischer Hintergrund

SQLOS bindet Tasks an Worker und Worker an Scheduler. Pending Work Queues entstehen vor Workerzuweisung; Runnable Queues nach Zuweisung beim Warten auf CPU. `sys.dm_os_workers` wird nur aggregiert ausgegeben. `max_workers_count` ist der effektive Enginewert, während `sys.configurations` den konfigurierten Wert einschließlich `0` für automatisch zeigt.

### Datenkette

`sys.dm_os_schedulers`, `sys.dm_os_workers`, `sys.dm_os_sys_info`, `sys.configurations`, `sys.dm_os_waiting_tasks`, `sys.dm_exec_requests`.

### Source Select

Scheduler und vollständig aggregierte Worker werden über `scheduler_address` verbunden:

```sql
WITH [Workers] AS
(
    SELECT
          [w].[scheduler_address]
        , COUNT_BIG(*) AS [WorkerCount]
        , SUM(CASE WHEN [w].[state] = N'RUNNABLE' THEN 1 ELSE 0 END)
          AS [RunnableWorkerCount]
    FROM [sys].[dm_os_workers] AS [w] WITH (NOLOCK)
    GROUP BY [w].[scheduler_address]
)
SELECT
      [s].[scheduler_id]
    , [s].[parent_node_id]
    , [s].[runnable_tasks_count]
    , [s].[work_queue_count]
    , [w].[WorkerCount]
    , [w].[RunnableWorkerCount]
FROM [sys].[dm_os_schedulers] AS [s] WITH (NOLOCK)
LEFT JOIN [Workers] AS [w]
  ON [w].[scheduler_address] = [s].[scheduler_address]
WHERE [s].[scheduler_id] < 1048576
  AND [s].[status] = N'VISIBLE ONLINE';
```

**Wichtig für die Eigenlast:** `dm_os_workers` wird vollständig gelesen, aber sofort je Scheduler aggregiert. THREADPOOL-Waits und auffällige Requests sind getrennte, bereits gefilterte Snapshots; SQL- und Plantexte werden nicht gelesen.

### Zeit- und Scope-Modell

Die Auswertung vergleicht den Schedulerzustand vor und nach dem Sample; Worker, Waits und Requests werden am Sampleende erfasst. Kumulative Zähler können beim Engine-Neustart zurückgesetzt werden. Queues und Workerzahlen sind flüchtige Gauges.

### Bewertung und Gegenprobe

Prüfen Sie Worker Queue und `THREADPOOL` wiederholt. Korrelieren Sie anschließend Blocking, Parallelität, lange Requests und CPU anhand unabhängiger Quellen.

### Typische Fehlinterpretation

Eine Runnable Queue ist nicht ohne weitere Evidenz als Worker-Erschöpfung zu interpretieren. Eine hohe Workerbelegung stellt außerdem keinen unmittelbaren Änderungsauftrag für `max worker threads` dar.

### Folgeanalyse

Für die weitere Analyse gelten folgende Schritte und Quellen: `USP_CurrentBlocking`, `USP_CurrentRequests`, `USP_CurrentWaits`, CPU-Topologie und externe OS-Telemetrie.

## Primärquellen

- [sys.dm_os_schedulers](https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-os-schedulers-transact-sql?view=sql-server-ver17)
- [sys.dm_os_workers](https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-os-workers-transact-sql?view=sql-server-ver17)
- [max worker threads](https://learn.microsoft.com/en-us/sql/database-engine/configure-windows/configure-the-max-worker-threads-server-configuration-option?view=sql-server-ver17)

[Technische Detailbeschreibung](../08_Server_Health.md#18-monitorusp_workerpressureanalysis)
