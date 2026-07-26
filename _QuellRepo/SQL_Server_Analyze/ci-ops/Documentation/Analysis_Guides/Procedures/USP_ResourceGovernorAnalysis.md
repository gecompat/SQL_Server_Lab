# [monitor].[USP_ResourceGovernorAnalysis]

**Bereich:** Infrastruktur<br>
**Zweck:** Zeigt Resource Pools, Workload Groups, Limits und optional zugeordnete Sessions.<br>
**Beobachtungsart:** Konfigurations- und Runtime-Snapshot<br>
**Kostenklasse:** LOW–MEDIUM

## Entscheidungsfrage und Einsatz

Die Procedure beantwortet die Betriebsfrage: **Wie klassifiziert und begrenzt Resource Governor Sessions und welche Pools/Groups zeigen Druck oder Abweichungen?** Sie unterstützt die Entscheidung, ob Betriebsbereitschaft, Wiederherstellbarkeit oder verteilte Datenbewegung auffällig ist und welcher zuständige Teilprozess geprüft werden muss.

## Nicht beantwortete Fragen

Die Procedure beantwortet keinen erfolgreichen Restore, Failover oder End-to-End-Datenfluss nur aus Konfigurations- und Historymetadaten. Der Zeitvertrag ist im Abschnitt „Zeit- und Scope-Modell“ konkretisiert. Ein Einzelwert gilt daher nur für diesen Scope und Zeitpunkt; er belegt weder eine Ursache noch eine Entwicklung.

## Sicherer Einstieg

```sql
EXEC [monitor].[USP_ResourceGovernorAnalysis]
      @MitSessions = 1,
      @ResultSetArt = 'CONSOLE';
```

Alle `Example*`-Werte im Aufruf sind synthetisch.

## Resultsets und Leserichtung

Der typisierte TABLE-Vertrag registriert `configuration`, `resourcePools`,
`workloadGroups`, `sessions` und `tempdbGovernance`. Status, Scope und Warnings
sind vor den Fachergebnissen zu lesen. CONSOLE dient der interaktiven Triage;
RAW und JSON erhalten den technischen Kontext, während TABLE nur die
ausdrücklich benannten stabilen Resultsets schreibt. Resultsets mit
unterschiedlicher Zeilengranularität dürfen nicht ungeprüft vereinigt oder
summiert werden.

## Eine Zeile bedeutet

Je Resultset beschreibt eine Zeile eine Konfiguration, einen Resource Pool,
eine Workload Group oder eine aktuell zugeordnete Session.
`tempdbGovernance` besitzt genau eine Zeile je sichtbarer Workload Group.

## So lesen

Betrachten Sie Poollimits, Group-Limits, aktuelle Nutzung, Cap-/Min-Werte und
Sessionzuordnung gemeinsam. Für TempDB trennen Sie gespeichertes MB- oder
Prozentlimit, `EffectiveLimitSource`, aktuelle und höchste Datennutzung,
Verletzungszähler und deren `StatisticsStartTime`.

## Warum kann das problematisch sein?

CPU-, Memory- oder Parallelitätslimits können Requests absichtlich drosseln oder Grants begrenzen.

## Wann ist es kein Problem?

Drosselung kann genau das gewünschte Schutzverhalten für andere Workloads sein.

## Beispiele und Gegenbeispiele

**Synthetischer Problemfall (`Example*`):** Eine Query ist langsam, ihrer Gruppe stehen aber nur 20 % CPU zu: zunächst Policywirkung statt schlechten Plan vermuten. Prüfen Sie Classifier, Zuordnung und SLA.

**Ähnlich aussehender Gegenfall:** Drosselung kann genau das gewünschte Schutzverhalten für andere Workloads sein. Der gleiche Einzelwert kann deshalb bei `ExampleDb` ohne Nutzerauswirkung unkritisch sein, während er bei zeitgleicher SLA-Verletzung eine Vertiefung rechtfertigt.

## Leere oder partielle Ausgabe

Ein leerer Historypfad kann Retention/Cleanup, deaktivierte Komponente oder falschen Scope bedeuten; er beweist keine erfolgreiche Ausführung.

Für `USP_ResourceGovernorAnalysis` gilt zusätzlich: **keine Zeile** bedeutet, dass im sichtbaren und gefilterten Scope kein ausgabefähiger Datensatz entstand. **0** ist ein gemessener Nullwert nur dann, wenn die Quellspalte tatsächlich verfügbar war. **NULL** bedeutet unbekannt, nicht anwendbar oder nicht auflösbar. **PARTIAL/Warning** bedeutet, dass mindestens eine Teilquelle, Datenbank oder Detailstufe fehlt. Ein Limit kann eine nichtleere Quelle vollständig aus dem sichtbaren Ausschnitt verdrängen.

## Eigenlast und Grenzen

**Quellcode-Hinweis zur Eigenlast:** Die Eigenlast ist gering bis mittel.

| Dimension | Aussage für diese Procedure |
|---|---|
| Kostenklasse | LOW–MEDIUM |
| Standardpfad | Aktuelle Resource-Governor-Konfiguration und Runtimezustände von Pools/Workload Groups; standardmäßig zusätzlich bis zu 5000 aktuell zugeordnete Sessions. |
| Teuerster Pfad | `@MitSessions = 1` und `@MaxZeilen = 0` auf einer Instanz mit sehr vielen Sessions, Pools und Gruppen. msdb, Datenbankhistory und Cross-Database-Quellen werden nicht gelesen. |
| Haupttreiber | Zahl der Resource Pools/Workload Groups und – im standardmäßig aktiven Sessionspfad – aktuell sichtbarer Sessionzuordnungen. Die Konfigurationsmenge ist klein; viele Sessions dominieren Materialisierung und Transfer. |
| Skalierung | Pool-/Gruppenkonfiguration ist klein; der optionale Sessionpfad wächst mit aktiven Sessions und deren Gruppenzuordnung. |
| Ressourcen | Geringe bis mittlere CPU-/Speicherlast auf Resource-Governor-Katalogen/-DMVs und optional `sys.dm_exec_sessions`; kein History- oder Benutzerdatenscan. |
| Begrenzungswirkung | `@MitSessions = 0` lässt den größten variablen Pfad aus. `@MaxZeilen` wird je ausgegebenem Konfigurations-/Runtime-/Sessionresultset angewandt und ist keine gemeinsame Gesamtgrenze. |
| Locking und Nebenwirkungen | Read-only; kurze Schema-Stability-Zugriffe auf msdb/Systemkataloge. Jobs, Backups oder Wartung laufen parallel weiter, daher ist das Ergebnis nicht atomar. |
| Schutzmechanismus | Kein High-Impact-Gate. `@MitSessions = 0` ist der wirksame Opt-out für den einzigen großen variablen Pfad; `@MaxZeilen` begrenzt die Resultsets separat. Der Default aktiviert Sessions allerdings, daher ist für reine Konfigurationsfragen ein explizites Abschalten sinnvoll. |
| Sicherer Einsatz | Zuerst `@MitSessions = 0` für Konfiguration/Runtime; Sessions nur bei einer konkreten Pool-/Gruppenfrage mit endlichem Limit ergänzen. |
| Aussagegrenze | Scope- oder Zeilenbegrenzungen können relevante, seltene oder später einsortierte Zeilen ausblenden. Die Aussage bleibt auf das Modell „Konfigurations- und Runtime-Snapshot“, die dokumentierte Granularität und den sichtbaren Quellenscope begrenzt; ein kleines Resultset ist weder automatisch vollständig noch repräsentativ. |

## Technische Vertiefung

[Gemeinsames Execution-, Zeit- und Evidenzmodell](../Technical_Foundations.md)

### Leitfrage

Wie klassifiziert und begrenzt Resource Governor Sessions und welche Pools/Groups zeigen Druck oder Abweichungen?

### Technischer Hintergrund

Classifier Function ordnet neue Sessions Workload Groups zu; Groups verweisen auf Resource Pools. Katalogsichten enthalten konfigurierte Werte, Runtime-DMVs `value_in_use` und Counter. CPU Caps, Min/Max Memory, Grant Percentage, Request Limits und External Pools wirken auf unterschiedliche Ressourcen.

### Datenkette

`master.sys.objects`, `master.sys.schemas`, `sys.dm_exec_sessions`,
`sys.dm_resource_governor_configuration`,
`sys.dm_resource_governor_resource_pools`,
`sys.dm_resource_governor_workload_groups`,
`sys.resource_governor_configuration`,
`sys.resource_governor_resource_pools`,
`sys.resource_governor_workload_groups` und – ausschließlich bei relevantem
Prozentlimit – `master.sys.master_files`.

### Source Select

Konfiguration und kumulative Runtime werden über `pool_id` verbunden:

```sql
SELECT
      [p].[pool_id]
    , [p].[name] AS [PoolName]
    , [p].[max_cpu_percent]
    , [p].[max_memory_percent]
    , [rp].[active_session_count]
    , [rp].[active_request_count]
    , [rp].[used_memory_kb]
    , [rp].[out_of_memory_count]
FROM [sys].[resource_governor_resource_pools] AS [p] WITH (NOLOCK)
LEFT JOIN [sys].[dm_resource_governor_resource_pools] AS [rp] WITH (NOLOCK)
  ON [rp].[pool_id] = [p].[pool_id]
WHERE [p].[name] <> N'internal';
```

**Wichtig für die Eigenlast:** Filtern Sie Pool oder Workload Group vor der Sessionzuordnung. Runtimezähler sind klein und kumulativ; SQL-Text und Requests werden nicht breit aufgelöst.

### Zeit- und Scope-Modell

Die Auswertung beschreibt den aktuellen Konfigurations- und Runtimezustand.
TempDB-Peak und Verletzungszähler gelten seit `StatisticsStartTime`, das durch
Serverstart oder `ALTER RESOURCE GOVERNOR RESET STATISTICS` neu gesetzt wird.
Bereits verbundene Sessions werden durch eine Classifieränderung nicht
automatisch neu klassifiziert.

### Bewertung und Gegenprobe

Berücksichtigen Sie Configured vs runtime, Pool/Group-Zuordnung, aktive Requests, Queues, CPU/Memory/Grantlimits und Default/Internal-Kontext. Throttling kann absichtlich sein.

### Typische Fehlinterpretation

Eine Query in einer Group beweist nicht, dass der Classifier aktuell dieselbe Entscheidung für neue Logins treffen würde. Limits sind nicht alle harte Reservierungen.

### Folgeanalyse

Für die weitere Analyse gelten folgende Schritte und Quellen: Current Requests/Memory Grants, Configuration und reproduzierbarer Login-/Classifiertest.

## Primärquellen

- [Resource Governor](https://learn.microsoft.com/en-us/sql/relational-databases/resource-governor/resource-governor?view=sql-server-ver17)
- [TempDB space resource governance](https://learn.microsoft.com/en-us/sql/relational-databases/resource-governor/tempdb-space-resource-governance?view=sql-server-ver17)
- [sys.resource_governor_workload_groups](https://learn.microsoft.com/en-us/sql/relational-databases/system-catalog-views/sys-resource-governor-workload-groups-transact-sql?view=sql-server-ver17)
- [sys.dm_resource_governor_workload_groups](https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-resource-governor-workload-groups-transact-sql?view=sql-server-ver17)

[Technische Detailbeschreibung](../07_Infrastructure.md#3-monitorusp_resourcegovernoranalysis)
